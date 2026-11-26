import AppKit
import CharlandCore

/// Le impostazioni della voce.
@MainActor @Observable
final class VoiceSettings {
    static let shared = VoiceSettings()

    var enabled: Bool { didSet { save("voiceEnabled", enabled) } }
    var combo: KeyCombo { didSet { saveCombo("voiceCombo", combo) } }
    var repeatCombo: KeyCombo { didSet { saveCombo("voiceRepeatCombo", repeatCombo) } }
    /// La lingua: "auto" (Orukeet riconosce da solo le 25 lingue europee) o una lingua precisa (`DictationLanguages`).
    var language: String { didSet { save("voiceLanguage", language) } }
    var dictationLanguage: DictationLanguage {
        // per le prove: CHARLAND_LINGUA=ja (una lingua) o apple:it_IT (forza il riconoscimento di Apple)
        if let test = ProcessInfo.processInfo.environment["CHARLAND_LINGUA"] {
            if test.hasPrefix("apple:") {
                let locale = String(test.dropFirst(6))
                return DictationLanguage(code: String(locale.prefix(2)), parakeet: false, appleLocale: locale)
            }
            return DictationLanguages.find(test)
        }
        return DictationLanguages.find(language)
    }
    var cleanup: Bool { didSet { save("voiceCleanup", cleanup) } }
    var liveText: Bool { didSet { save("voiceLiveText", liveText) } }
    var keepHistory: Bool { didSet { save("voiceHistory", keepHistory) } }
    /// Le sostituzioni: quando dici una cosa, ne scrive un'altra («gta 6» diventa «GTA VI»).
    var replacements: [Replacement] {
        didSet { UserDefaults.standard.set(try? JSONEncoder().encode(replacements), forKey: "voiceReplacements") }
    }
    /// Il vocabolario personale: nomi e parole da scrivere esattamente così («Charmail», «Rossi»). Il motore
    /// le favorisce mentre ascolta, e la grafia è sempre quella scritta qui.
    var vocabulary: [String] {
        didSet {
            UserDefaults.standard.set(vocabulary, forKey: "voiceVocabulary")
            cachedSnapshot = nil
        }
    }
    /// I nomi di serie (app, servizi, sigle: `Vocabulary.common`).
    var commonVocabulary: Bool {
        didSet {
            save("voiceCommonVocabulary", commonVocabulary)
            cachedSnapshot = nil
        }
    }
    @ObservationIgnored private var cachedSnapshot: VocabularySnapshot?
    /// Il vocabolario com'è adesso, pronto per il motore.
    var vocabularySnapshot: VocabularySnapshot {
        // per le prove: CHARLAND_VOCABOLARIO="Charmail/Rossi" al posto di quello salvato, «-» per nessuno
        if let test = ProcessInfo.processInfo.environment["CHARLAND_VOCABOLARIO"] {
            if test == "-" { return .empty }
            return VocabularySnapshot(user: test.split(separator: "/").map(String.init), common: commonVocabulary)
        }
        if let cachedSnapshot { return cachedSnapshot }
        let words = vocabulary.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let snapshot = VocabularySnapshot(user: words, common: commonVocabulary)
        cachedSnapshot = snapshot
        return snapshot
    }

    private init() {
        let d = UserDefaults.standard
        enabled = d.object(forKey: "voiceEnabled") as? Bool ?? true
        combo = Self.loadCombo("voiceCombo") ?? .dictationDefault
        repeatCombo = Self.loadCombo("voiceRepeatCombo") ?? .repeatDefault
        // Prima c'erano solo italiano e inglese; dal 17 novembre 2026 si parla in tutte le lingue: «Automatica», una volta.
        var stored = d.string(forKey: "voiceLanguage") ?? "auto"
        if !d.bool(forKey: "voiceLanguageMulti") {
            d.set(true, forKey: "voiceLanguageMulti")
            if stored == "it" || stored == "en" { stored = "auto"; d.set(stored, forKey: "voiceLanguage") }
        }
        language = stored
        cleanup = d.object(forKey: "voiceCleanup") as? Bool ?? true
        liveText = d.object(forKey: "voiceLiveText") as? Bool ?? true
        // Il testo dal vivo è arrivato davvero il 17 novembre 2026: acceso per tutti, una volta.
        if !d.bool(forKey: "voiceLiveTextOn") { d.set(true, forKey: "voiceLiveTextOn"); liveText = true }
        keepHistory = d.object(forKey: "voiceHistory") as? Bool ?? true
        vocabulary = d.stringArray(forKey: "voiceVocabulary") ?? []
        commonVocabulary = d.object(forKey: "voiceCommonVocabulary") as? Bool ?? true
        replacements = d.data(forKey: "voiceReplacements").flatMap { try? JSONDecoder().decode([Replacement].self, from: $0) } ?? []
    }

    private func save(_ key: String, _ value: Any) { UserDefaults.standard.set(value, forKey: key) }
    private func saveCombo(_ key: String, _ combo: KeyCombo) {
        UserDefaults.standard.set(try? JSONEncoder().encode(combo), forKey: key)
    }
    private static func loadCombo(_ key: String) -> KeyCombo? {
        UserDefaults.standard.data(forKey: key).flatMap { try? JSONDecoder().decode(KeyCombo.self, from: $0) }
    }
}

/// Una dettatura finita, con i suoi tempi.
struct DictationRecord: Identifiable, Sendable {
    let id = UUID()
    var date = Date()
    var raw: String
    var text: String
    var outcome: TextInserter.Outcome
    var cleanupSource: ModelCleaner.Result.Source
    var audioSeconds: Double
    /// Dal rilascio del tasto al testo trascritto.
    var transcribeSeconds: Double
    var cleanSeconds: Double
    /// Dal rilascio del tasto al testo nel campo.
    var totalSeconds: Double
}

/// Il regista della dettatura: lega il tasto, il microfono, il motore, la pulizia,
/// l'isola e l'inserimento del testo.
@MainActor @Observable
final class DictationController {
    static let shared = DictationController()

    enum Phase: Equatable { case idle, listening, working }
    private(set) var phase: Phase = .idle
    private(set) var history: [DictationRecord] = []
    private(set) var lastError: String?

    @ObservationIgnored private let capture = AudioCapture()
    @ObservationIgnored private let inserter = TextInserter()
    @ObservationIgnored private var interpreter = PressInterpreter()
    @ObservationIgnored private var smoother = LevelSmoother()
    @ObservationIgnored private var tickTimer: Timer?
    @ObservationIgnored private var clockTimer: Timer?
    @ObservationIgnored private var startedAt = Date()
    @ObservationIgnored private var handsFree = false
    /// Quanto ci mette di solito la pulizia: serve a far atterrare la goccia quando il testo è pronto.
    @ObservationIgnored private var usualCleanSeconds = 0.65

    /// `CHARLAND_VOCE=1`: scrive nel terminale i pezzi chiusi mentre si parla e i tempi di ogni dettatura.
    nonisolated static let tracing = ProcessInfo.processInfo.environment["CHARLAND_VOCE"] != nil

    private static let dictationID: UInt32 = 1
    private static let escapeID: UInt32 = 2
    private static let repeatID: UInt32 = 3

    private var settings: VoiceSettings { .shared }
    private var island: IslandController? { IslandHub.shared.primary }

    private init() {
        capture.onLevel = { [weak self] level, dt in
            Task { @MainActor in self?.level(level, dt: dt) }
        }
    }

    // MARK: Accensione

    /// Registra i tasti. Chiamata all'avvio e quando cambiano le impostazioni.
    func start() {
        HotkeyCenter.shared.unregister(id: Self.dictationID)
        HotkeyCenter.shared.unregister(id: Self.repeatID)
        guard settings.enabled else { return }
        let combo = settings.combo
        let ok = HotkeyCenter.shared.register(id: Self.dictationID, combo: combo,
                                              down: { [weak self] in self?.keyDown() }, up: { [weak self] in self?.keyUp() },
                                              other: { [weak self] in self?.otherKey() })
        if ok {
            lastError = nil
        } else if combo.isModifiersOnly {
            lastError = String(localized: "Per usare \(combo.display) da soli serve Accessibilità: concedila qui sopra.")
        } else {
            lastError = String(localized: "Il tasto \(combo.display) è già usato da un'altra app.")
        }
        HotkeyCenter.shared.register(id: Self.repeatID, combo: settings.repeatCombo, down: { [weak self] in self?.repeatLast() })
        // Il microfono preparato (ma spento): al tasto parte subito e l'attacco della prima parola non si perde.
        capture.warmUp()
    }

    func stop() {
        HotkeyCenter.shared.unregister(id: Self.dictationID)
        HotkeyCenter.shared.unregister(id: Self.repeatID)
        HotkeyCenter.shared.unregister(id: Self.escapeID)
        cancel()
    }

    // MARK: Tasto

    private func keyDown() {
        handle(interpreter.down(now: CACurrentMediaTime()))
        scheduleTick()
    }

    private func keyUp() {
        let action = interpreter.up(now: CACurrentMediaTime())
        // Un tocco di ⌃⌥ più breve dell'attesa: non era cominciato niente, e niente comincia (a meno che non
        // arrivi la seconda pressione delle mani libere).
        if action == nil, pendingBegin != nil {
            pendingBegin?.invalidate()
            pendingBegin = nil
        }
        handle(action)
        scheduleTick()
    }

    /// I modificatori della scorciatoia (⌃⌥) servivano a un'altra: ⌃⌥A, ⌃⌥← di un'altra app.
    private func otherKey() {
        pendingBegin?.invalidate()
        pendingBegin = nil
        handle(interpreter.otherKey())
        scheduleTick()
    }

    /// Con una scorciatoia di soli modificatori si aspetta un attimo prima di cominciare: se intanto arriva un
    /// tasto, ⌃⌥ era per un'altra scorciatoia e l'isola non si affaccia nemmeno. Con una lettera (⌥Z) comincia subito.
    @ObservationIgnored private var pendingBegin: Timer?
    static let modifiersOnlyDelay = 0.15

    private func scheduleBegin() {
        pendingBegin?.invalidate()
        let timer = Timer(timeInterval: Self.modifiersOnlyDelay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.pendingBegin = nil
                guard case .holding = self.interpreter.phase else { return }
                // un tasto premuto nel frattempo, anche se un'altra app l'ha preso per sé come scorciatoia
                guard HotkeyCenter.shared.isHeldClean(id: Self.dictationID) else {
                    self.handle(self.interpreter.otherKey())
                    return
                }
                self.begin()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        pendingBegin = timer
    }

    private func scheduleTick() {
        tickTimer?.invalidate()
        guard let deadline = interpreter.deadline else { return }
        let timer = Timer(timeInterval: max(0.01, deadline - CACurrentMediaTime() + 0.01), repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.handle(self.interpreter.tick(now: CACurrentMediaTime()))
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        tickTimer = timer
    }

    private func handle(_ action: PressInterpreter.Action?) {
        switch action {
        case .start:
            // Il testo di prima si sta ancora preparando: questa pressione non comincia niente, e non deve lasciare
            // traccia nell'interprete. Prima un tocco breve in quel momento restava «in attesa della seconda
            // pressione» e 0,35 s dopo annullava: `cancel` riportava tutto a riposo con la scrittura ancora in corso,
            // e la dettatura dopo restava col microfono acceso e senza testo (la fine di quella vecchia le chiudeva
            // l'isola e le rimetteva la fase a riposo, così il rilascio non faceva più niente).
            // (Solo `.working`: mentre si ascolta una pressione arrivata un attimo dopo la finestra del doppio tocco
            // deve restare «tenuta», perché il suo rilascio è quello che scrive.)
            guard phase != .working else { interpreter.reset(); return }
            if settings.combo.isModifiersOnly { scheduleBegin() } else { begin() }
        case .commit:
            pendingBegin?.invalidate()
            pendingBegin = nil
            commit()
        case .cancel:
            pendingBegin?.invalidate()
            pendingBegin = nil
            cancel()
        case .handsFree:
            // con ⌃⌥ il primo tocco non aveva ancora fatto cominciare niente
            pendingBegin?.invalidate()
            pendingBegin = nil
            if phase == .idle { begin() }
            enterHandsFree()
        case nil: break
        }
    }

    // MARK: Ascolto

    private func begin() {
        guard phase == .idle else { return }
        // Manca qualcosa? L'isola lo dice e porta al punto dove sistemarlo: senza, il tasto sembrava non fare niente.
        guard DictationSetup.isDone(.model), let model = ModelStore.selected else {
            lastError = String(localized: "Nessun modello vocale installato.")
            DictationSetup.explain(.model)
            _ = interpreter.escape()
            return
        }
        if !DictationSetup.isDone(.microphone), ProcessInfo.processInfo.environment["CHARLAND_MICROFONO_FINTO"] == nil {
            lastError = String(localized: "Il microfono non è disponibile.")
            DictationSetup.explain(.microphone)
            _ = interpreter.escape()
            return
        }
        lastError = nil
        handsFree = false
        smoother.reset()
        startedAt = Date()
        // L'isola si affaccia subito, prima ancora che il microfono sia pronto.
        island?.model.voice = VoiceState()
        island?.model.voiceLevel = 0
        sendShape()
        startClock()
        phase = .listening
        do {
            try capture.start()
        } catch {
            lastError = String(localized: "Il microfono non è disponibile.")
            finishIsland()
            phase = .idle
            _ = interpreter.escape()
            return
        }
        // Esc annulla, ma il tasto è nostro solo mentre si detta.
        HotkeyCenter.shared.register(id: Self.escapeID, combo: .escape, down: { [weak self] in
            guard let self else { return }
            self.handle(self.interpreter.escape())
        })
        // Intanto che parli si caricano il modello vocale e quello della pulizia.
        ModelStore.ensureVocabulary(model)
        let folder = ModelStore.folder(model).path
        if let locale = settings.dictationLanguage.appleLocale {
            startApple(locale: locale)
        } else {
            capture.onSamples = nil
            startLiveText(folder: folder)
        }
        let tone = CleanupTone.forApp(NSWorkspace.shared.frontmostApplication?.bundleIdentifier)
        let language = settings.dictationLanguage
        let wantsCleanup = settings.cleanup
        Task {
            _ = try? await VoiceEngineClient.shared.load(modelFolder: folder)
            if wantsCleanup { ModelCleaner.prewarm(tone: tone, language: language) }
        }
    }

    /// La forma dell'isola mentre detti: ali ai lati della fotocamera, il tempo a mani libere, e sotto lo spazio per
    /// le parole solo quando ce ne sono (prima non si apre una lastra vuota).
    private func sendShape() {
        let words = settings.liveText && !(island?.model.voice.liveText.isEmpty ?? true)
        island?.engine.send(.transientBegan(.dictation(style: Appearance.shared.dictationStyle, liveText: words, handsFree: handsFree)))
    }

    /// Le parole dal vivo: senza il punto finale che il motore mette a ogni ripresa (la frase non è finita),
    /// con le sostituzioni. La prima parola allunga l'isola.
    private func showLive(_ raw: String) {
        guard phase == .listening, let island else { return }
        var text = Replacements.apply(raw.trimmingCharacters(in: .whitespacesAndNewlines), settings.replacements)
        while let last = text.last, ".?!…。？！".contains(last) { text.removeLast() }
        guard !text.isEmpty, text != island.model.voice.liveText else { return }
        let first = island.model.voice.liveText.isEmpty
        island.model.voice.liveText = text
        if first { sendShape() }
    }

    // MARK: Testo dal vivo

    private var liveTask: Task<Void, Never>?
    /// La trascrizione in corso: i pezzi già finiti e la coda (solo col motore nostro, non con quello di Apple).
    @ObservationIgnored private var transcript: LiveTranscript?
    /// Quanto audio si ritrascrive per le parole dal vivo: le ultime frasi bastano, e il costo resta fisso.
    static let liveWindow: Double = 10

    /// Mentre parli, ogni mezzo secondo circa: se c'è un pezzo abbastanza lungo lo si chiude e lo si trascrive
    /// (al rilascio resterà solo la coda); se no, col testo dal vivo acceso, il motore ritrascrive gli ultimi
    /// secondi e l'isola mostra le parole sotto la fotocamera.
    private func startLiveText(folder: String) {
        liveTask?.cancel()
        // Ogni pezzo chiuso mentre parli viene anche finito (regole e pulizia): al rilascio resta solo l'ultimo.
        let context = polishContext()
        let transcript = LiveTranscript(capture: capture, vocabulary: context.vocabulary) { text, more in
            await DictationController.polish(text, context, more: more)
        }
        self.transcript = transcript
        let live = settings.liveText
        liveTask = Task { [weak self] in
            _ = try? await VoiceEngineClient.shared.load(modelFolder: folder)
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(450))
                guard let self, !Task.isCancelled, self.phase == .listening else { return }
                guard let text = await transcript.step(live: live, window: Self.liveWindow),
                      !Task.isCancelled, self.phase == .listening else { continue }
                self.showLive(text)
            }
        }
    }

    private func stopLiveText() {
        liveTask?.cancel()
        liveTask = nil
    }

    /// Il modo di finire il testo adesso: l'app in primo piano decide il tono.
    private func polishContext() -> PolishContext {
        PolishContext(tone: CleanupTone.forApp(NSWorkspace.shared.frontmostApplication?.bundleIdentifier),
                      language: settings.dictationLanguage, cleanup: settings.cleanup,
                      replacements: settings.replacements, vocabulary: settings.vocabularySnapshot)
    }

    // MARK: Riconoscimento di Apple

    /// La dettatura in corso col riconoscimento di Apple (lingue fuori da Parakeet), se c'è.
    @ObservationIgnored private var apple: AppleDictation?

    /// L'audio va in diretta al riconoscimento di Apple, che manda già le parole dal vivo.
    private func startApple(locale: String) {
        let session = AppleDictation()
        if settings.liveText {
            session.onLive = { text in
                Task { @MainActor in
                    DictationController.shared.showLive(text)
                }
            }
        }
        apple = session
        capture.onSamples = { session.feed($0) }
        session.begin(locale: locale)
        // la prima volta il sistema scarica la lingua: l'isola dice che si sta preparando, e l'audio aspetta
        let name = settings.dictationLanguage.name
        Task {
            guard !(await AppleDictation.isInstalled(locale)) else { return }
            await MainActor.run {
                let me = DictationController.shared
                guard me.phase == .listening, me.island?.model.voice.liveText.isEmpty ?? false else { return }
                me.island?.model.voice.liveText = String(localized: "Preparo \(name)…")
                me.sendShape()
            }
        }
    }

    private func enterHandsFree() {
        guard phase == .listening else { return }
        handsFree = true
        island?.model.voice.handsFree = true
        sendShape()
    }

    /// Il tempo a sinistra della fotocamera, un secondo alla volta, da quando si comincia a parlare.
    private func startClock() {
        clockTimer?.invalidate()
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.phase == .listening else { return }
                self.island?.model.voice.elapsed = Date().timeIntervalSince(self.startedAt)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        clockTimer = timer
    }

    private func level(_ raw: Double, dt: Double) {
        guard phase == .listening else { return }
        island?.engine.setVoiceLevel(smoother.feed(raw, dt: dt))
    }

    private func finishIsland() {
        clockTimer?.invalidate()
        clockTimer = nil
        HotkeyCenter.shared.unregister(id: Self.escapeID)
        island?.engine.setVoiceLevel(0)
        island?.engine.send(.transientEnded)
    }

    func cancel() {
        // Si annulla solo mentre si ascolta. Col testo già in preparazione (`.working`) la scrittura va fino in
        // fondo da sola: fermarla a metà lasciava il suo lavoro in corso con la fase già a riposo.
        guard phase == .listening else { return }
        interpreter.reset()
        stopLiveText()
        transcript?.cancel()
        transcript = nil
        ModelCleaner.cool()
        capture.onSamples = nil
        if let session = apple { apple = nil; Task { await session.cancel() } }
        _ = capture.stop()
        finishIsland()
        phase = .idle
    }

    // MARK: Rilascio

    private func commit() {
        guard phase == .listening else { return }
        let released = DispatchTime.now().uptimeNanoseconds
        stopLiveText()
        let samples = capture.stop()
        capture.onSamples = nil
        let appleSession = apple
        apple = nil
        let transcript = transcript
        self.transcript = nil
        let context = polishContext()
        let vocabulary = context.vocabulary
        phase = .working
        island?.engine.setVoiceLevel(0)
        island?.model.voice.processing = true
        let audioSeconds = Double(samples.count) / VoiceEngineConstants.sampleRate
        // Meno di un quarto di secondo di audio non è una frase.
        guard audioSeconds > 0.25, let model = ModelStore.selected else {
            if let appleSession { Task { await appleSession.cancel() } }
            finishIsland()
            phase = .idle
            return
        }
        // Il cursore si cerca fuori dal thread principale, mentre il motore trascrive.
        let caretLookup = Task { await CaretLocator.locateInBackground() }
        let language = context.language
        let folder = ModelStore.folder(model).path

        Task {
            func elapsed() -> Double { Double(DispatchTime.now().uptimeNanoseconds - released) / 1e9 }
            defer {
                transcript?.cancel()
                ModelCleaner.cool()
            }
            do {
                let out: (text: String, seconds: Double)
                /// Il testo con i termini del vocabolario al loro posto.
                let recognized: String
                if let appleSession {
                    out = (await appleSession.finish(), elapsed())
                    if out.text.isEmpty, appleSession.failed {
                        // la lingua non si è potuta preparare (di solito manca la rete): lo si dice, niente sparisce in silenzio
                        self.finishIsland()
                        self.phase = .idle
                        var m = SystemActivity.message("lingua-non-pronta", template: .status,
                                                       title: String(localized: "\(language.name) non è pronta"))
                        m.subtitle = String(localized: "Serve la rete la prima volta, per scaricarla")
                        m.symbol = "globe"
                        m.tint = "orange"
                        m.ttl = Features.noticeTTL
                        SystemActivity.show(m)
                        return
                    }
                    // anche col riconoscimento di Apple i termini del vocabolario prendono la loro grafia
                    recognized = Recognition.spell(out.text, boosted: nil, vocabulary: vocabulary)
                } else {
                    // i pezzi già trascritti mentre parlavi, più la coda
                    func recognize() async throws -> Recognition.Result {
                        try await VoiceEngineClient.shared.load(modelFolder: folder)
                        if let transcript { return try await transcript.finish(samples) }
                        return try await Recognition.whole(samples, vocabulary: vocabulary)
                    }
                    let parakeet: Recognition.Result
                    do {
                        parakeet = try await recognize()
                    } catch {
                        // Il motore è caduto o non ha più il modello proprio sull'ultimo pezzo: prima tutta la dettatura
                        // andava persa, anche i minuti già trascritti. Si riaccende (riparte da solo) e si riprova una volta.
                        if Self.tracing { print("[voce] il motore ha fallito (\(error)): lo riaccendo e riprovo"); fflush(stdout) }
                        VoiceEngineClient.shared.shutdown()
                        parakeet = try await recognize()
                    }
                    out = (parakeet.raw, parakeet.engineSeconds)
                    recognized = parakeet.text
                }
                let transcribed = elapsed()
                // Niente da scrivere (solo un'esitazione, o silenzio).
                guard !Self.rules(recognized, context).isEmpty else {
                    self.finishIsland()
                    self.phase = .idle
                    return
                }
                // Il testo cola: una goccia scende dall'isola fino al cursore, poi si incolla.
                // Senza pulizia parte subito. Con la pulizia parte in modo da atterrare quando
                // il testo sarà pronto: così non resta mai ferma ad aspettare.
                let target = await caretLookup.value
                let willClean = context.cleanup && context.tone != .literal && ModelCleaner.isAvailable
                let flight = IslandMotion.dripDuration
                let dripDelay = willClean ? max(0, self.usualCleanSeconds - flight) : 0
                let landing = Task { @MainActor in
                    try? await Task.sleep(for: .seconds(dripDelay))
                    // Le parole si condensano e la goccia si stacca dal fondo dell'isola ancora aperta; solo dopo
                    // l'isola rientra. Chiudendola subito il bordo tagliava il testo in un fotogramma.
                    let words = !(self.island?.model.voice.liveText.isEmpty ?? true)
                    if words { self.island?.model.voice.condensing = true }
                    if let island = self.island {
                        let screen = island.geometry.frame
                        let point = target?.point ?? CGPoint(x: island.geometry.notchCenterX, y: screen.maxY - 240)
                        island.drip(to: point)
                    }
                    let hold = words ? 0.12 : 0
                    try? await Task.sleep(for: .seconds(hold))
                    self.finishIsland()
                    try? await Task.sleep(for: .seconds(max(0, flight - hold)))
                }
                // I pezzi chiusi mentre parlavi sono già finiti: qui si aspetta solo l'ultimo. Senza pezzi (il
                // riconoscimento di Apple) si finisce tutto adesso.
                let result: Polished
                if let done = await transcript?.polished() { result = done } else { result = await Self.polish(recognized, context) }
                if result.source == .model {
                    self.usualCleanSeconds = self.usualCleanSeconds * 0.7 + result.seconds * 0.3
                }
                await landing.value
                let outcome = await self.inserter.insert(result.text)
                let record = DictationRecord(raw: out.text, text: result.text, outcome: outcome, cleanupSource: result.source,
                                             audioSeconds: audioSeconds, transcribeSeconds: transcribed,
                                             cleanSeconds: result.seconds, totalSeconds: elapsed())
                self.remember(record)
                if Self.tracing {
                    print(String(format: "[voce] %.1f s di audio, %d pezzi già pronti, testo %.0f ms dopo il rilascio, pulizia %.0f ms (%@), nel campo dopo %.0f ms",
                                 audioSeconds, transcript?.closedPieces ?? 0, transcribed * 1000, result.seconds * 1000,
                                 result.source.rawValue, record.totalSeconds * 1000))
                    print("[voce] grezzo: \(out.text)")
                    print("[voce] finale: \(result.text)")
                    fflush(stdout)
                }
                if outcome == .noField || outcome == .secure || outcome == .notAllowed {
                    // Non c'è dove scrivere: il testo non va perso, resta copiabile.
                    self.lastError = outcome == .notAllowed
                        ? String(localized: "Manca il permesso per scrivere nelle altre app.")
                        : nil
                }
                if outcome == .notAllowed {
                    // Senza Accessibilità Charland non può scrivere nel campo: il testo va negli appunti, e
                    // l'isola dice come dare il permesso.
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(result.text, forType: .string)
                    DictationSetup.explain(.accessibility)
                }
            } catch {
                self.lastError = "\(error)"
                self.finishIsland()
            }
            self.phase = .idle
        }
    }

    /// Come si finisce il testo di questa dettatura: il tono dell'app in cui si scrive, la lingua, se pulire,
    /// le sostituzioni e il vocabolario.
    struct PolishContext: Sendable {
        var tone: CleanupTone
        var language: DictationLanguage
        var cleanup: Bool
        var replacements: [Replacement]
        var vocabulary: VocabularySnapshot
    }

    /// Un testo finito, e da dove viene.
    struct Polished: Sendable {
        var text: String
        var source: ModelCleaner.Result.Source
        var seconds: Double
    }

    /// Le regole, istantanee: esitazioni, punteggiatura dettata, apostrofi, maiuscole, sostituzioni.
    static func rules(_ recognized: String, _ context: PolishContext) -> String {
        var options = TextRules.Options()
        options.literal = context.tone == .literal
        // «virgola», «punto», «ehm» valgono in italiano e in inglese: nelle altre lingue ci pensa il modello
        // (in tedesco «um» è una parola, non un'esitazione)
        let spoken = DictationLanguages.spokenRules(for: context.language, text: recognized)
        options.spokenPunctuation = spoken
        options.removeFillers = spoken
        options.italian = DictationLanguages.isItalian(context.language, text: recognized)
        return Replacements.apply(TextRules.clean(recognized, options: options), context.replacements)
    }

    /// Le regole e poi, se è accesa, la pulizia col modello. Vale per un pezzo di una dettatura in corso (`more`:
    /// ne arriverà un altro), per tutta la dettatura e per le prove con un file.
    static func polish(_ recognized: String, _ context: PolishContext, more: Bool = false) async -> Polished {
        let rules = rules(recognized, context)
        guard context.cleanup, !rules.isEmpty else { return Polished(text: rules, source: .rules, seconds: 0) }
        let result = await ModelCleaner.clean(rules, tone: context.tone, language: context.language,
                                              keep: keep(in: rules, replacements: context.replacements, vocabulary: context.vocabulary),
                                              more: more)
        // se il modello avesse toccato una parola sostituita o un termine, li si rimette
        let text = Vocabulary.canonicalize(Replacements.apply(result.text, context.replacements), terms: context.vocabulary.terms)
        return Polished(text: text, source: result.source, seconds: result.seconds)
    }

    /// Le parole che il modello che pulisce deve lasciare come sono: solo quelle che nel testo ci sono davvero.
    /// (Con un elenco fisso, a volte il modello ne aggiungeva una in fondo alla frase.)
    static func keep(in text: String, replacements: [Replacement], vocabulary: VocabularySnapshot) -> [String] {
        let written = replacements.map(\.written).filter { !$0.isEmpty && text.localizedCaseInsensitiveContains($0) }
        let terms = Vocabulary.present(in: text, terms: vocabulary.terms)
        var seen = Set<String>()
        return (written + terms).filter { seen.insert($0.lowercased()).inserted }
    }

    private func remember(_ record: DictationRecord) {
        guard settings.keepHistory else {
            history = [record]
            return
        }
        history.insert(record, at: 0)
        if history.count > 30 { history.removeLast(history.count - 30) }
    }

    /// Fa passare un file audio dalla stessa catena della dettatura (motore, regole, pulizia),
    /// senza microfono e senza scrivere da nessuna parte. È la "prova con una frase".
    func runFile(_ url: URL, cleanup: Bool, tone: CleanupTone = .natural) async -> DictationRecord? {
        guard let model = ModelStore.selected, let samples = try? AudioCapture.load(file: url), !samples.isEmpty else { return nil }
        ModelStore.ensureVocabulary(model)
        let start = DispatchTime.now().uptimeNanoseconds
        func elapsed() -> Double { Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9 }
        do {
            let language = settings.dictationLanguage
            let vocabulary = settings.vocabularySnapshot
            let begun = DispatchTime.now().uptimeNanoseconds
            let out: (text: String, seconds: Double)
            let recognized: String
            if let locale = language.appleLocale {
                // le lingue fuori da Parakeet: il riconoscimento di Apple, con tutto il file in una volta
                let session = AppleDictation()
                try await session.start(locale: locale)
                session.feed(samples)
                out = (await session.finish(), 0)
                recognized = Recognition.spell(out.text, boosted: nil, vocabulary: vocabulary)
            } else {
                try await VoiceEngineClient.shared.load(modelFolder: ModelStore.folder(model).path)
                let parakeet = try await Recognition.whole(samples, vocabulary: vocabulary)
                out = (parakeet.raw, parakeet.engineSeconds)
                recognized = parakeet.text
            }
            let transcribed = Double(DispatchTime.now().uptimeNanoseconds - begun) / 1e9
            let context = PolishContext(tone: tone, language: language, cleanup: cleanup, replacements: settings.replacements,
                                        vocabulary: vocabulary)
            if cleanup { ModelCleaner.prewarm(tone: tone, language: language) }
            let result = await Self.polish(recognized, context)
            ModelCleaner.cool()
            return DictationRecord(raw: out.text, text: result.text, outcome: .noField, cleanupSource: result.source,
                                   audioSeconds: Double(samples.count) / VoiceEngineConstants.sampleRate,
                                   transcribeSeconds: transcribed, cleanSeconds: result.seconds,
                                   totalSeconds: transcribed + result.seconds)
        } catch {
            lastError = "\(error)"
            return nil
        }
    }

    /// Dal pulsante "Detta" nella casa: si ascolta senza tenere premuto, finché non tocchi
    /// l'isola o premi il tasto.
    func startHandsFreeFromIsland() {
        guard phase == .idle else { return }
        interpreter.forceHandsFree()
        begin()
        guard phase == .listening else {
            interpreter.reset()
            return
        }
        enterHandsFree()
    }

    /// Un tocco sull'isola mentre detti: ferma e scrive.
    func stopFromIsland() {
        guard phase == .listening else { return }
        interpreter.reset()
        commit()
    }

    /// "Rimetti l'ultima": incolla di nuovo l'ultima dettatura, se è finita nel posto sbagliato.
    func repeatLast() {
        // Uno alla volta: due incolla vicini si fotografavano gli appunti a vicenda, e alla fine negli appunti
        // restava il testo dettato al posto di quello che c'era.
        guard phase == .idle, !repeating, let last = history.first else { return }
        repeating = true
        Task {
            _ = await inserter.insert(last.text)
            repeating = false
        }
    }
    @ObservationIgnored private var repeating = false
}
