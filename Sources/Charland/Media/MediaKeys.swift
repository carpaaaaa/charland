import AppKit
import CoreAudio
import AudioToolbox
import CharlandCore

/// Il volume dell'uscita audio corrente, attraverso Core Audio.
enum SystemVolume {
    static func outputDevice() -> AudioDeviceID? {
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr,
              device != 0 else { return nil }
        return device
    }

    /// Il simbolo di dove esce il suono, come su iPhone: AirPods (Pro, Max), Beats, cuffie, HomePod, televisore.
    /// `nil` per gli altoparlanti del Mac.
    @MainActor static func outputSymbol() -> String? {
        guard let device = outputDevice() else { return nil }
        // Ogni tasto (anche le ripetizioni tenendo premuto) chiede: due secondi di memoria per dispositivo bastano, e
        // CoreAudio non viene interrogato a raffica sul thread principale.
        let now = CACurrentMediaTime()
        if let cached = cachedOutput, cached.device == device, now - cached.at < 2 { return cached.symbol }
        let symbol = readOutputSymbol(device)
        cachedOutput = (device, symbol, now)
        return symbol
    }

    @MainActor private static var cachedOutput: (device: AudioDeviceID, symbol: String?, at: CFTimeInterval)?

    private static func readOutputSymbol(_ device: AudioDeviceID) -> String? {
        func symbol(_ names: String...) -> String? {
            names.first { NSImage(systemSymbolName: $0, accessibilityDescription: nil) != nil }
        }
        var nameRef: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        let name = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &nameRef) == noErr
            ? (nameRef?.takeRetainedValue() as String? ?? "").lowercased() : ""
        if name.contains("airpods max") { return symbol("airpods.max", "airpodsmax", "headphones") }
        if name.contains("airpods pro") { return symbol("airpods.pro", "airpodspro", "airpods") }
        if name.contains("airpods") { return symbol("airpods.gen3", "airpods") }
        if name.contains("beats") { return symbol("beats.headphones", "headphones") }
        if name.contains("homepod mini") { return symbol("homepod.mini.fill", "homepodmini.fill", "hifispeaker.fill") }
        if name.contains("homepod") { return symbol("homepod.fill", "hifispeaker.fill") }
        var transport = UInt32(0)
        size = UInt32(MemoryLayout<UInt32>.size)
        address.mSelector = kAudioDevicePropertyTransportType
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &transport) == noErr else { return nil }
        // Le casse riconosciute dal nome solo fra i dispositivi senza filo: le casse del Mac si chiamano «MacBook Air
        // Speakers», e con l'audio normale carpa vuole l'altoparlante classico, non le casse.
        let wirelessSpeaker = ["speaker", "soundlink", "jbl", "boom", "sonos", "cassa"].contains(where: name.contains)
        switch transport {
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE:
            return wirelessSpeaker ? symbol("hifispeaker.fill") : symbol("headphones")
        case kAudioDeviceTransportTypeAirPlay:
            return symbol("hifispeaker.fill")
        case kAudioDeviceTransportTypeHDMI, kAudioDeviceTransportTypeDisplayPort:
            return symbol("tv")
        case kAudioDeviceTransportTypeBuiltIn:
            // Le cuffie col filo nella presa del Mac: stessa uscita, sorgente «hdpn».
            var source = UInt32(0)
            size = UInt32(MemoryLayout<UInt32>.size)
            var sourceAddress = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDataSource,
                                                           mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
            if AudioObjectGetPropertyData(device, &sourceAddress, 0, nil, &size, &source) == noErr, source == 0x6864_706E {
                return symbol("headphones")
            }
            return nil
        default:
            return nil
        }
    }

    private static func volumeAddress() -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
                                   mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
    }

    private static func muteAddress() -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyMute, mScope: kAudioDevicePropertyScopeOutput,
                                   mElement: kAudioObjectPropertyElementMain)
    }

    static var level: Double? {
        get {
            guard let device = outputDevice() else { return nil }
            var value = Float32(0)
            var size = UInt32(MemoryLayout<Float32>.size)
            var address = volumeAddress()
            guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr else { return nil }
            return Double(value)
        }
        set {
            guard let newValue, let device = outputDevice() else { return }
            var value = Float32(min(1, max(0, newValue)))
            var address = volumeAddress()
            AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<Float32>.size), &value)
        }
    }

    static var muted: Bool {
        get {
            guard let device = outputDevice() else { return false }
            var value = UInt32(0)
            var size = UInt32(MemoryLayout<UInt32>.size)
            var address = muteAddress()
            guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr else { return false }
            return value != 0
        }
        set {
            guard let device = outputDevice() else { return }
            var value: UInt32 = newValue ? 1 : 0
            var address = muteAddress()
            AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value)
        }
    }
}

/// La luminosità dello schermo del Mac. Usa una funzione privata del sistema, cercata a
/// runtime: se manca, la luminosità si spegne e l'app continua a funzionare.
enum SystemBrightness {
    private typealias Getter = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    private typealias Setter = @convention(c) (CGDirectDisplayID, Float) -> Int32

    nonisolated(unsafe) private static let handle: UnsafeMutableRawPointer? =
        dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY)
    private static let getter: Getter? = handle.flatMap { dlsym($0, "DisplayServicesGetBrightness") }.map { unsafeBitCast($0, to: Getter.self) }
    private static let setter: Setter? = handle.flatMap { dlsym($0, "DisplayServicesSetBrightness") }.map { unsafeBitCast($0, to: Setter.self) }

    static var isAvailable: Bool { getter != nil && setter != nil && level != nil }

    static var level: Double? {
        get {
            guard let getter else { return nil }
            var value: Float = 0
            guard getter(CGMainDisplayID(), &value) == 0 else { return nil }
            return Double(value)
        }
        set {
            guard let newValue, let setter else { return }
            _ = setter(CGMainDisplayID(), Float(min(1, max(0, newValue))))
        }
    }
}

/// I tasti di volume e luminosità, presi prima del sistema: il riquadro di Apple non compare
/// e lo slider lo disegna l'isola. Si accende solo se la funzione è accesa nelle impostazioni.
///
/// Sicurezza: se il permesso viene tolto mentre l'ascolto è attivo, tastiera e mouse possono
/// bloccarsi (difetto noto di macOS, senza correzione). Per questo l'ascolto controlla il
/// permesso ogni secondo e si chiude subito, e la funzione che riceve i tasti fa pochissimo lavoro.
@MainActor
final class MediaKeys {
    static let shared = MediaKeys()

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var tapThread: Thread?
    private var watchdog: DispatchSourceTimer?
    private var side: SliderSide = .volume
    private var volumeListener: AudioObjectPropertyListenerBlock?
    private var lastKeyTime: CFTimeInterval = 0
    private(set) var isActive = false

    private static let activeFlag = "mediaKeysActive"
    /// Le cadute di fila con l'ascolto attivo, ognuna entro pochi minuti dall'avvio dell'ascolto.
    private static let crashCountKey = "mediaKeysCrashes"
    private static let traceKeys = ProcessInfo.processInfo.environment["CHARLAND_SLIDER"] != nil

    private init() {}

    private var island: IslandController? { IslandHub.shared.primary }

    /// Se l'ultima volta l'app non si è chiusa bene mentre l'ascolto era attivo, non riparte da sola.
    static var crashedWhileActive: Bool { UserDefaults.standard.bool(forKey: activeFlag) }

    /// Dopo una caduta con l'ascolto attivo: vero solo alla seconda di fila (un giro di cadute all'avvio, quello da cui
    /// la protezione difende). Una caduta sola, anche per tutt'altro (la farfalla del 20 novembre 2026), o un'uscita
    /// forzata non spengono più volume e luminosità (carpa: «gli slider del volume e brightness voglio siano on di
    /// default»: sparivano dopo una caduta e restavano spenti). Il conto torna a zero dopo 5 minuti d'ascolto o a
    /// un'uscita pulita.
    static func noteCrash() -> Bool {
        let count = UserDefaults.standard.integer(forKey: crashCountKey) + 1
        UserDefaults.standard.set(count >= 2 ? 0 : count, forKey: crashCountKey)
        return count >= 2
    }

    func setEnabled(_ enabled: Bool) {
        if enabled { start() } else { stop() }
    }

    private func start() {
        guard !isActive, AXIsProcessTrusted() else { return }
        let mask = CGEventMask(1 << 14) // NX_SYSDEFINED: i tasti speciali
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                          eventsOfInterest: mask, callback: mediaKeyCallback, userInfo: nil) else { return }
        self.tap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        self.source = source
        // Un thread tutto suo: l'ascolto non aspetta mai il thread principale.
        tapThread = Self.runOnOwnThread(source)
        isActive = true
        UserDefaults.standard.set(true, forKey: Self.activeFlag)
        DispatchQueue.main.asyncAfter(deadline: .now() + 300) {
            MainActor.assumeIsolated {
                if MediaKeys.shared.isActive { UserDefaults.standard.set(0, forKey: Self.crashCountKey) }
            }
        }
        watchdog = Self.makeWatchdog(for: tap)
        listenToVolume()
    }

    /// Il thread dell'ascolto. È fuori dal thread principale: per questo la funzione non ne fa parte.
    nonisolated private static func runOnOwnThread(_ source: CFRunLoopSource?) -> Thread {
        let box = TapBox(source: source)
        let thread = Thread {
            CFRunLoopAddSource(CFRunLoopGetCurrent(), box.source, .commonModes)
            CFRunLoopRun()
        }
        thread.name = "tasti-speciali"
        thread.qualityOfService = .userInteractive
        thread.start()
        return thread
    }

    /// Ogni secondo, su un thread di sfondo: se il permesso è stato tolto l'ascolto si chiude subito,
    /// prima che il sistema blocchi tastiera e mouse; se il sistema l'ha sospeso, si riaccende.
    nonisolated private static func makeWatchdog(for tap: CFMachPort) -> DispatchSourceTimer {
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .userInitiated))
        timer.schedule(deadline: .now() + 1, repeating: 1)
        let tapBox = PortBox(port: tap)
        timer.setEventHandler {
            if !AXIsProcessTrusted() {
                CGEvent.tapEnable(tap: tapBox.port, enable: false)
                CFMachPortInvalidate(tapBox.port)
                DispatchQueue.main.async { MainActor.assumeIsolated { MediaKeys.shared.stop() } }
            } else if !CGEvent.tapIsEnabled(tap: tapBox.port) {
                CGEvent.tapEnable(tap: tapBox.port, enable: true)
            }
        }
        timer.resume()
        return timer
    }

    func stop() {
        watchdog?.cancel()
        watchdog = nil
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        tap = nil
        source = nil
        tapThread?.cancel()
        tapThread = nil
        SideSlider.shared.dismiss()
        if isActive {
            UserDefaults.standard.set(false, forKey: Self.activeFlag)
            UserDefaults.standard.set(0, forKey: Self.crashCountKey)
        }
        isActive = false
    }

    // MARK: Tasti

    enum Key: Int32 {
        case volumeUp = 0, volumeDown = 1, brightnessUp = 2, brightnessDown = 3, mute = 7
    }

    /// Chiamata sul thread principale per ogni pressione (non per i rilasci).
    fileprivate func pressed(_ key: Key, fine: Bool) {
        let started = CACurrentMediaTime()
        defer {
            if Self.traceKeys { print(String(format: "[tasto] %.2f ms", (CACurrentMediaTime() - started) * 1000)); fflush(stdout) }
        }
        let step = fine ? 1.0 / 64.0 : 1.0 / 16.0
        switch key {
        case .volumeUp, .volumeDown:
            side = .volume
            guard let current = SystemVolume.level else { return }
            let wanted = current + (key == .volumeUp ? step : -step)
            if SystemVolume.muted, key == .volumeUp { SystemVolume.muted = false }
            apply(current: current, wanted: wanted) { SystemVolume.level = $0 }
        case .mute:
            side = .volume
            SystemVolume.muted.toggle()
            present(level: SystemVolume.level ?? 0)
        case .brightnessUp, .brightnessDown:
            side = .brightness
            guard let current = SystemBrightness.level else { return }
            let wanted = current + (key == .brightnessUp ? step : -step)
            apply(current: current, wanted: wanted) { SystemBrightness.level = $0 }
        }
    }

    private func apply(current: Double, wanted: Double, set: (Double) -> Void) {
        let clamped = min(1, max(0, wanted))
        if clamped != current { set(clamped) }
        var kick = 0.0
        if wanted > 1.0001 || wanted < -0.0001 {
            // Oltre il limite: la pillola si allunga con resistenza e torna a molla.
            kick = wanted > 1 ? 0.32 : -0.32
            if Appearance.shared.haptics { NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now) }
        }
        present(level: clamped, kick: kick)
    }

    /// Mostra lo slider sul bordo sinistro (vedi `SideSlider`) e fa scorrere il riempimento verso il livello nuovo.
    private func present(level: Double, kick: Double = 0) {
        lastKeyTime = CACurrentMediaTime()
        SideSlider.shared.present(side: side, level: level, kick: kick, muted: side == .volume && SystemVolume.muted,
                                  output: side == .volume ? SystemVolume.outputSymbol() : nil)
    }

    // MARK: Cambi che non passano dai tasti

    /// Il volume cambiato dagli AirPods o da un'altra app: lo slider compare anche per quelli.
    private func listenToVolume() {
        guard volumeListener == nil, let device = SystemVolume.outputDevice() else { return }
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
                                                 mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
        let block: AudioObjectPropertyListenerBlock = { _, _ in
            Task { @MainActor in
                let me = MediaKeys.shared
                // Se il cambio è nostro (un tasto appena premuto) lo slider c'è già.
                // Spento in Impostazioni › Volume e luminosità: la pillola esce solo coi tasti.
                guard me.isActive, Features.shared.sliderExternal, CACurrentMediaTime() - me.lastKeyTime > 0.3,
                      let level = SystemVolume.level else { return }
                me.side = .volume
                me.present(level: level)
            }
        }
        volumeListener = block
        AudioObjectAddPropertyListenerBlock(device, &address, DispatchQueue.main, block)
    }
}

private struct TapBox: @unchecked Sendable { let source: CFRunLoopSource? }
private struct PortBox: @unchecked Sendable { let port: CFMachPort }

/// Sottotipo e `data1` di un evento NX_SYSDEFINED, letti dai campi del CGEvent: gli stessi valori
/// che darebbero `NSEvent.subtype` e `NSEvent.data1` (provato creando l'evento con NSEvent).
private let systemDefinedSubtypeField = CGEventField(rawValue: 99)!
private let systemDefinedData1Field = CGEventField(rawValue: 149)!

/// La funzione che riceve i tasti speciali. Fa il minimo: capisce quale tasto è,
/// lo passa al thread principale e lo toglie al sistema.
///
/// Niente `NSEvent(cgEvent:)` qui: gira sul thread dell'ascolto, e per il Blocco maiuscole AppKit
/// chiede al sistema delle lingue di tastiera, che pretende il thread principale e fa crollare l'app.
private func mediaKeyCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent,
                              refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    guard type.rawValue == 14, event.getIntegerValueField(systemDefinedSubtypeField) == 8 else {
        return Unmanaged.passUnretained(event)
    }
    let data = Int(truncatingIfNeeded: event.getIntegerValueField(systemDefinedData1Field))
    let code = Int32((data & 0xFFFF_0000) >> 16)
    guard let key = MediaKeys.Key(rawValue: code) else { return Unmanaged.passUnretained(event) }
    let flags = event.flags
    // Le combinazioni con ⌘ e ⌃, e ⌥ da solo, restano al sistema.
    let option = flags.contains(.maskAlternate)
    let shift = flags.contains(.maskShift)
    if flags.contains(.maskCommand) || flags.contains(.maskControl) || (option && !shift) {
        return Unmanaged.passUnretained(event)
    }
    let down = ((data & 0xFF00) >> 8) == 0x0A
    if down {
        let fine = option && shift
        DispatchQueue.main.async {
            MainActor.assumeIsolated { MediaKeys.shared.pressed(key, fine: fine) }
        }
    } else {
        // Il tasto si alza: l'elastico tirato oltre il limite può tornare.
        DispatchQueue.main.async {
            MainActor.assumeIsolated { SideSlider.shared.keyReleased() }
        }
    }
    // Pressione e rilascio vengono tolti tutti e due, così il riquadro di Apple non compare.
    return nil
}
