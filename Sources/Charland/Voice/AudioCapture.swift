import AVFoundation
import CoreAudio
import CharlandCore

/// Ascolta il microfono solo mentre detti e produce audio mono a 16 kHz per il motore.
/// L'audio resta in memoria e viene buttato dopo la trascrizione: non si salva mai.
final class AudioCapture: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private let lock = NSLock()
    private var samples: [Float] = []
    private var running = false
    private let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: VoiceEngineConstants.sampleRate, channels: 1, interleaved: false)!

    /// Volume grezzo percepito (0...1), chiamato dal thread dell'audio a ogni blocco.
    var onLevel: (@Sendable (Double, Double) -> Void)?
    /// Ogni pezzo di audio a 16 kHz appena arriva (per il riconoscimento di Apple, che ascolta in diretta).
    /// Si imposta dal thread principale mentre il thread dell'audio lo legge: per questo passa dal lucchetto.
    var onSamples: (@Sendable ([Float]) -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return samplesHandler }
        set { lock.lock(); samplesHandler = newValue; lock.unlock() }
    }
    private var samplesHandler: (@Sendable ([Float]) -> Void)?

    enum Failure: Error { case noInput, denied }

    static var permission: AVAuthorizationStatus { AVCaptureDevice.authorizationStatus(for: .audio) }

    static func requestPermission() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }

    /// Solo per le prove: con CHARLAND_MICROFONO_FINTO=<file audio> l'ascolto legge quel file al ritmo reale invece
    /// del microfono (il testo dal vivo si prova senza parlare).
    private var fakeTimer: Timer?

    private func startFake(_ path: String) throws {
        let file = try Self.load(file: URL(fileURLWithPath: path))
        lock.lock()
        samples.removeAll(keepingCapacity: true)
        lock.unlock()
        running = true
        var offset = 0
        let chunk = 1600   // un decimo di secondo
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] t in
            guard let self, offset < file.count else { t.invalidate(); return }
            let end = min(file.count, offset + chunk)
            let piece = Array(file[offset..<end])
            offset = end
            var sum: Float = 0
            for v in piece { sum += v * v }
            self.onLevel?(Double(sqrt(sum / Float(max(1, piece.count)))) * 6, 0.1)
            self.lock.lock()
            self.samples.append(contentsOf: piece)
            self.lock.unlock()
            self.onSamples?(piece)
        }
        RunLoop.main.add(timer, forMode: .common)
        fakeTimer = timer
    }

    // MARK: Microfono pronto

    /// La presa è montata e il motore dell'audio è preparato per questo ingresso.
    private var prepared = false
    private var preparedFormat: AVAudioFormat?
    private var preparedDevice = AudioDeviceID(0)
    private var configurationObserver: NSObjectProtocol?

    /// Prepara il microfono senza accenderlo: la presa è montata e il motore dell'audio è pronto, ma il microfono
    /// resta spento (il sistema non lo segna in uso: niente pallino arancione). Al tasto basta accenderlo, e il
    /// primo suono arriva dopo una cinquantina di millisecondi invece di duecento: l'attacco della prima parola
    /// non si perde più. Misurato sul MacBook Air: primo campione a +48 ms dal tasto, contro +100/+320.
    ///
    /// Con un microfono Bluetooth non si prepara niente: certe cuffie passano alla modalità chiamata (e la musica
    /// peggiora) appena qualcuno tocca il loro ingresso.
    func warmUp() {
        guard !running, ProcessInfo.processInfo.environment["CHARLAND_MICROFONO_FINTO"] == nil,
              Self.permission == .authorized else { return }
        if configurationObserver == nil {
            // cambia il microfono o il suo formato: quello preparato non vale più
            configurationObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange,
                                                                           object: engine, queue: .main) { [weak self] _ in
                guard let self else { return }
                self.prepared = false
                if self.running { self.recoverIfStopped(attempt: 0) } else { self.warmUp() }
            }
        }
        let device = Self.defaultInputDevice()
        guard !Self.isBluetooth(device) else {
            prepared = false
            return
        }
        if prepared, device == preparedDevice { return }
        guard mount(device: device) else { return }
        engine.prepare()
        prepared = true
    }

    /// Il microfono o il suo formato sono cambiati a dettatura in corso (AirPods collegati o tolti, un altro ingresso
    /// scelto): il motore dell'audio si ferma da solo, e la dettatura andava avanti muta, col solo audio di prima del
    /// cambio. Se è davvero fermo si rimonta la presa sull'ingresso nuovo e si riparte: l'audio già raccolto resta.
    /// Se gira ancora non si tocca niente.
    private func recoverIfStopped(attempt: Int) {
        guard running, fakeTimer == nil, !engine.isRunning else { return }
        if mount(device: Self.defaultInputDevice()) {
            engine.prepare()
            if (try? engine.start()) != nil {
                if DictationController.tracing { print("[voce] microfono cambiato a dettatura in corso: ripartito"); fflush(stdout) }
                return
            }
        }
        // L'ingresso nuovo a volte non è pronto subito: altri due tentativi, poi resta l'audio raccolto fin lì.
        guard attempt < 2 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.recoverIfStopped(attempt: attempt + 1) }
    }

    /// Monta la presa sull'ingresso com'è adesso.
    private func mount(device: AudioDeviceID) -> Bool {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { return false }
        converter = AVAudioConverter(from: format, to: target)
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            self?.consume(buffer)
        }
        preparedFormat = format
        preparedDevice = device
        return true
    }

    static func defaultInputDevice() -> AudioDeviceID {
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id)
        return id
    }

    static func isBluetooth(_ device: AudioDeviceID) -> Bool {
        var value = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyTransportType,
                                                 mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr else { return false }
        return value == kAudioDeviceTransportTypeBluetooth || value == kAudioDeviceTransportTypeBluetoothLE
    }

    func start() throws {
        guard !running else { return }
        if let fake = ProcessInfo.processInfo.environment["CHARLAND_MICROFONO_FINTO"] {
            try startFake(fake)
            return
        }
        guard Self.permission == .authorized else { throw Failure.denied }
        let asked = DispatchTime.now().uptimeNanoseconds
        firstBuffer = asked
        waitingFirst = DictationController.tracing
        lock.lock()
        samples.removeAll(keepingCapacity: true)
        samples.reserveCapacity(16000 * 30)
        lock.unlock()
        // Se il microfono era già preparato (ed è ancora quello) basta accenderlo; se no si monta tutto adesso.
        let device = Self.defaultInputDevice()
        let warm = prepared && device == preparedDevice && engine.inputNode.outputFormat(forBus: 0) == preparedFormat
        if !warm {
            guard mount(device: device) else { throw Failure.noInput }
            engine.prepare()
        }
        do {
            try engine.start()
        } catch {
            // quello preparato non valeva più (microfono staccato nel frattempo): si rimonta e si riprova una volta
            prepared = false
            guard mount(device: Self.defaultInputDevice()) else { throw Failure.noInput }
            engine.prepare()
            try engine.start()
        }
        running = true
        if DictationController.tracing {
            print(String(format: "[voce] microfono acceso in %.0f ms%@", Double(DispatchTime.now().uptimeNanoseconds - asked) / 1e6,
                         warm ? " (era già preparato)" : ""))
            fflush(stdout)
        }
    }

    /// Per le tracce: quando è stato chiesto il microfono, e se si aspetta ancora il primo suono.
    private var firstBuffer: UInt64 = 0
    private var waitingFirst = false

    /// Ferma l'ascolto e restituisce tutto l'audio raccolto.
    func stop() -> [Float] {
        guard running else { return [] }
        if let fakeTimer {
            fakeTimer.invalidate()
            self.fakeTimer = nil
        } else {
            // Spegnere il motore dell'audio libera quello che era stato preparato: lo si prepara di nuovo subito,
            // così la prossima dettatura parte veloce. Il microfono intanto è spento.
            engine.stop()
            prepared = false
        }
        running = false
        lock.lock()
        let out = samples
        samples.removeAll(keepingCapacity: false)
        lock.unlock()
        warmUp()
        return out
    }

    /// L'audio raccolto finora, senza fermarsi: serve al testo dal vivo.
    func snapshot() -> [Float] {
        lock.lock()
        defer { lock.unlock() }
        return samples
    }

    /// L'audio da un certo campione in poi: quello che non è ancora finito in un pezzo trascritto.
    func snapshot(from index: Int) -> [Float] {
        lock.lock()
        defer { lock.unlock() }
        return index >= samples.count ? [] : Array(samples[max(0, index)...])
    }

    /// Solo gli ultimi secondi: per il testo dal vivo non serve copiare tutto.
    func snapshot(lastSeconds: Double) -> [Float] {
        lock.lock()
        defer { lock.unlock() }
        let count = Int(lastSeconds * 16000)
        return samples.count <= count ? samples : Array(samples.suffix(count))
    }

    private func consume(_ buffer: AVAudioPCMBuffer) {
        guard let converter, buffer.frameLength > 0 else { return }
        if waitingFirst {
            waitingFirst = false
            print(String(format: "[voce] primo suono %.0f ms dopo il tasto (%.0f Hz, %d canali, blocchi da %d)",
                         Double(DispatchTime.now().uptimeNanoseconds - firstBuffer) / 1e6, buffer.format.sampleRate,
                         Int(buffer.format.channelCount), Int(buffer.frameLength)))
            fflush(stdout)
        }
        if let channel = buffer.floatChannelData?[0] {
            var sum: Float = 0
            let n = Int(buffer.frameLength)
            for i in 0..<n { sum += channel[i] * channel[i] }
            let rms = Double((sum / Float(n)).squareRoot())
            onLevel?(LevelSmoother.perceived(rms: rms), Double(n) / buffer.format.sampleRate)
        }
        let ratio = target.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }
        var fed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if fed {
                status.pointee = .noDataNow
                return nil
            }
            fed = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, out.frameLength > 0, let data = out.floatChannelData?[0] else { return }
        let piece = Array(UnsafeBufferPointer(start: data, count: Int(out.frameLength)))
        lock.lock()
        samples.append(contentsOf: piece)
        lock.unlock()
        onSamples?(piece)
    }

    /// Legge un file audio e lo porta a 16 kHz mono: serve al banco di prova, che fa passare
    /// frasi registrate dalla stessa catena del microfono.
    static func load(file url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: VoiceEngineConstants.sampleRate, channels: 1, interleaved: false)!
        guard let source = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)) else { return [] }
        try file.read(into: source)
        guard let converter = AVAudioConverter(from: file.processingFormat, to: target) else { return [] }
        let capacity = AVAudioFrameCount(Double(file.length) * target.sampleRate / file.processingFormat.sampleRate) + 1024
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return [] }
        var fed = false
        converter.convert(to: out, error: nil) { _, status in
            if fed {
                status.pointee = .endOfStream
                return nil
            }
            fed = true
            status.pointee = .haveData
            return source
        }
        guard let data = out.floatChannelData?[0] else { return [] }
        return Array(UnsafeBufferPointer(start: data, count: Int(out.frameLength)))
    }
}
