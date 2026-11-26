import Foundation
import NaturalLanguage
import Speech

/// Una lingua della dettatura e chi la sa trascrivere.
///
/// Lo schema viene da OpenWhispr (MIT, © OpenWhispr Team, `src/config/languageRegistry.json`): «Automatica» più
/// le lingue una per una, ognuna col motore che la conosce. Le 25 lingue europee le trascrive Parakeet (Orukeet,
/// che riconosce da solo la lingua); le altre, dove OpenWhispr usa Whisper, qui le trascrive il riconoscimento
/// vocale di Apple, sul Mac: niente modelli da scaricare noi, e dà già le parole dal vivo.
struct DictationLanguage: Identifiable, Hashable, Sendable {
    /// Il codice salvato nelle impostazioni: "auto", "it", "en", "zh-CN"…
    let code: String
    /// La sa Parakeet (con «Automatica» la riconosce da solo).
    let parakeet: Bool
    /// Il locale del riconoscimento di Apple, per le lingue che Parakeet non sa.
    let appleLocale: String?

    var id: String { code }
    var isAuto: Bool { code == "auto" }

    /// Il nome nella lingua dell'interfaccia: «Giapponese», «Japanese».
    var name: String {
        if isAuto { return String(localized: "Automatica") }
        let identifier = code.replacingOccurrences(of: "-", with: "_")
        let name = Locale.current.localizedString(forIdentifier: identifier) ?? code
        return name.prefix(1).uppercased() + name.dropFirst()
    }

    /// Il nome per il modello che pulisce il testo, sempre in italiano.
    var italianName: String {
        Locale(identifier: "it").localizedString(forIdentifier: code.replacingOccurrences(of: "-", with: "_")) ?? code
    }

    /// Le regole a voce («virgola», «punto», «ehm») sono italiane e inglesi: per le altre lingue le fa il modello.
    var spokenRules: Bool { isAuto || code == "it" || code == "en" }
}

enum DictationLanguages {
    static let auto = DictationLanguage(code: "auto", parakeet: true, appleLocale: nil)

    /// Le lingue di Parakeet v3, come nell'elenco di OpenWhispr (l'inglese americano e britannico qui sono uno).
    static let parakeet: [DictationLanguage] = ["it", "en", "es", "fr", "de", "pt", "nl", "pl", "ru", "uk", "ro", "cs",
                                                "sk", "sl", "hr", "bg", "el", "hu", "fi", "sv", "da", "et", "lv", "lt", "mt"]
        .map { DictationLanguage(code: $0, parakeet: true, appleLocale: nil) }

    /// Le altre lingue di OpenWhispr che il riconoscimento di Apple sa fare su questo sistema, col loro locale.
    /// Quelle che Apple non sa (afrikaans, armeno, persiano…) non si offrono.
    static let apple: [DictationLanguage] = [
        ("zh-CN", "zh_CN"), ("zh-TW", "zh_TW"), ("yue", "yue_CN"), ("ja", "ja_JP"), ("ko", "ko_KR"), ("ar", "ar_SA"),
        ("he", "he_IL"), ("hi", "hi_IN"), ("tr", "tr_TR"), ("th", "th_TH"), ("vi", "vi_VN"), ("id", "id_ID"),
        ("ms", "ms_MY"), ("ca", "ca_ES"), ("no", "nb_NO"), ("ta", "ta_IN"), ("mr", "mr_IN"), ("kn", "kn_IN"),
        ("ne", "ne_IN"), ("ur", "ur_IN"), ("bn", "bn_IN"), ("gu", "gu_IN"), ("te", "te_IN"), ("ml", "ml_IN"),
    ].map { DictationLanguage(code: $0.0, parakeet: false, appleLocale: $0.1) }

    static var all: [DictationLanguage] { [auto] + parakeet + apple }

    static func find(_ code: String) -> DictationLanguage {
        all.first { $0.code == code } ?? auto
    }

    /// Le regole a voce («virgola», «ehm») si applicano solo all'italiano e all'inglese. Con «Automatica» si guarda
    /// la lingua del testo trascritto: in tedesco «um» è una parola, in spagnolo «punto» anche.
    /// Il testo è in italiano (lingua scelta, o riconosciuta con «Automatica»): valgono le regole dell'italiano,
    /// come gli apostrofi che il motore a volte perde.
    static func isItalian(_ language: DictationLanguage, text: String) -> Bool {
        guard language.isAuto else { return language.code == "it" }
        return NLLanguageRecognizer.dominantLanguage(for: text) == .italian
    }

    static func spokenRules(for language: DictationLanguage, text: String) -> Bool {
        guard language.isAuto else { return language.spokenRules }
        guard let detected = NLLanguageRecognizer.dominantLanguage(for: text) else { return true }
        return detected == .italian || detected == .english
    }
}

/// Il riconoscimento vocale di Apple per una dettatura: riceve l'audio mentre parli, manda le parole dal vivo e
/// al rilascio dà il testo finale. Usa `DictationTranscriber` (punteggiatura, pensato per dettare) e, per le lingue
/// che sa solo l'altro, `SpeechTranscriber`.
final class AppleDictation: @unchecked Sendable {
    private let lock = NSLock()
    private var analyzer: SpeechAnalyzer?
    private var continuation: AsyncStream<AnalyzerInput>.Continuation?
    private var converter: AVAudioConverter?
    private var format: AVAudioFormat?
    private var results: Task<String, Never>?
    private var finished = ""
    /// L'audio arrivato prima che il riconoscimento fosse pronto: non si perde l'inizio della frase.
    private var pending: [Float] = []
    private var cancelled = false
    private var startTask: Task<Void, Never>?
    /// L'avvio non è riuscito (lingua che non si scarica, sistema che non la sa).
    private(set) var failed = false
    private let source = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
    /// Le parole dal vivo: il testo finito più quello che sta cambiando.
    var onLive: (@Sendable (String) -> Void)?

    enum Failure: Error { case unsupported, notInstalled }

    /// Il modulo giusto per un locale: quello della dettatura se lo sa, se no quello generico.
    static func module(for identifier: String) async -> (any SpeechModule)? {
        let locale = Locale(identifier: identifier)
        if let match = await DictationTranscriber.supportedLocale(equivalentTo: locale) {
            return DictationTranscriber(locale: match, contentHints: [], transcriptionOptions: [.punctuation],
                                        reportingOptions: [.volatileResults], attributeOptions: [])
        }
        if let match = await SpeechTranscriber.supportedLocale(equivalentTo: locale) {
            return SpeechTranscriber(locale: match, transcriptionOptions: [], reportingOptions: [.volatileResults],
                                     attributeOptions: [])
        }
        return nil
    }

    /// La lingua c'è già sul Mac (se no la prima dettatura aspetta lo scarico)?
    static func isInstalled(_ identifier: String) async -> Bool {
        let locale = Locale(identifier: identifier)
        let installed = await DictationTranscriber.installedLocales + SpeechTranscriber.installedLocales
        return installed.contains { $0.identifier(.bcp47) == locale.identifier(.bcp47) || $0.identifier == locale.identifier }
    }

    /// Fa partire l'ascolto senza aspettare: l'audio che arriva intanto resta in coda e non si perde.
    func begin(locale: String) {
        startTask = Task {
            do { try await self.start(locale: locale) } catch {
                self.lock.withLock { self.failed = true }
            }
        }
    }

    /// Il sistema sa questa lingua?
    static func isSupported(_ identifier: String) async -> Bool {
        await module(for: identifier) != nil
    }

    /// Scarica la lingua se manca (lo fa il sistema). Da chiamare quando la si sceglie.
    static func prepare(_ identifier: String) async throws {
        guard let module = await module(for: identifier) else { throw Failure.unsupported }
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [module]) {
            try await request.downloadAndInstall()
        }
    }

    /// Comincia ad ascoltare.
    func start(locale identifier: String) async throws {
        guard let module = await Self.module(for: identifier) else { throw Failure.unsupported }
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [module]) {
            // la lingua non c'era ancora: si scarica adesso, e questa dettatura aspetta
            try await request.downloadAndInstall()
        }
        // annullata mentre si scaricava: niente riconoscitore lasciato acceso
        if lock.withLock({ cancelled }) { return }
        let analyzer = SpeechAnalyzer(modules: [module])
        let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module]) ?? source
        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        let backlog: [Float] = lock.withLock {
            self.analyzer = analyzer
            self.format = format
            self.converter = AVAudioConverter(from: source, to: format)
            self.continuation = continuation
            self.finished = ""
            let waiting = pending
            pending = []
            return waiting
        }
        if !backlog.isEmpty { feed(backlog) }
        let live = onLive
        let texts: AsyncThrowingStream<(String, Bool), Error> = Self.texts(of: module)
        results = Task { [weak self] in
            var done = ""
            do {
                for try await (text, isFinal) in texts {
                    if isFinal {
                        done += text
                        self?.lock.withLock { self?.finished = done }
                        live?(done)
                    } else {
                        live?(done + text)
                    }
                }
            } catch {}
            return done
        }
        try await analyzer.start(inputSequence: stream)
    }

    /// I testi dei risultati, uguali per i due moduli: (testo, è definitivo).
    private static func texts(of module: any SpeechModule) -> AsyncThrowingStream<(String, Bool), Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    if let dictation = module as? DictationTranscriber {
                        for try await r in dictation.results { continuation.yield((String(r.text.characters), r.isFinal)) }
                    } else if let speech = module as? SpeechTranscriber {
                        for try await r in speech.results { continuation.yield((String(r.text.characters), r.isFinal)) }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Un pezzo di audio a 16 kHz, mono, dal microfono. Si può chiamare da qualunque thread.
    func feed(_ samples: [Float]) {
        lock.lock()
        defer { lock.unlock() }
        guard !cancelled else { return }
        guard let continuation else {
            pending.append(contentsOf: samples)
            return
        }
        guard let converter, let format, !samples.isEmpty,
              let input = AVAudioPCMBuffer(pcmFormat: source, frameCapacity: AVAudioFrameCount(samples.count)) else { return }
        input.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { input.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
        let ratio = format.sampleRate / source.sampleRate
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(Double(samples.count) * ratio) + 32) else { return }
        var fed = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true
            status.pointee = .haveData
            return input
        }
        if error == nil, output.frameLength > 0 { continuation.yield(AnalyzerInput(buffer: output)) }
    }

    /// Fine dell'audio: aspetta il testo definitivo.
    func finish() async -> String {
        // se la lingua si stava ancora scaricando, si aspetta: l'audio è in coda e arriva tutto
        await startTask?.value
        let (continuation, analyzer) = lock.withLock {
            let pair = (self.continuation, self.analyzer)
            self.continuation = nil
            return pair
        }
        continuation?.finish()
        try? await analyzer?.finalizeAndFinishThroughEndOfInput()
        let text = await results?.value ?? ""
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Annulla senza aspettare.
    func cancel() async {
        let (continuation, analyzer) = lock.withLock {
            cancelled = true
            pending = []
            let pair = (self.continuation, self.analyzer)
            self.continuation = nil
            return pair
        }
        continuation?.finish()
        await analyzer?.cancelAndFinishNow()
        results?.cancel()
    }
}
