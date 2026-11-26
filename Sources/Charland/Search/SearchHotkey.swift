import AppKit
import Carbon.HIToolbox
import CoreGraphics

/// Prende la scorciatoia della ricerca (di serie ⌘spazio) prima di macOS.
///
/// Su macOS 27 ⌘spazio apre l'app «Siri AI» (`com.apple.campo`) con una scorciatoia di sistema, e una scorciatoia
/// registrata da un'app (`RegisterEventHotKey`) non la batte mai. Un'intercettazione degli eventi di sessione messa in
/// testa sì: provato il 23 novembre 2026 su macOS 27.3, con l'intercettazione accesa ⌘spazio arriva a Charland e la bolla
/// di Siri non si apre; senza, si apre come sempre. Quindi non si tocca nessuna impostazione di sistema: se Charland si
/// chiude, cade o la funzione si spegne, l'intercettazione sparisce con lei e ⌘spazio torna subito a macOS.
///
/// Serve Accessibilità (la stessa della dettatura e dei tasti del volume). Senza, la scorciatoia si registra come le
/// altre di Charland: va bene per una scorciatoia libera (⌥spazio), non per ⌘spazio, che resta a macOS; la sezione
/// delle impostazioni lo dice. Come per gli altri ascolti dei tasti, se il permesso viene tolto l'intercettazione si
/// chiude subito: tenuta aperta, il sistema può bloccare la tastiera.
///
/// Con la «Secure Keyboard Entry» accesa (un campo password, il Terminale con l'opzione) macOS non passa i tasti a
/// nessuna intercettazione: in quei momenti ⌘spazio apre la ricerca di macOS. È voluto dal sistema e non si aggira.
@MainActor
final class SearchHotkey {
    static let shared = SearchHotkey()

    enum Status: Equatable {
        /// Spenta (funzione spenta o app bloccata).
        case off
        /// Intercettazione attiva: la scorciatoia è di Charland anche se macOS la usa.
        case active
        /// Senza Accessibilità, registrata come scorciatoia normale (funziona solo se nessun altro la tiene).
        case registered
        /// Senza Accessibilità e già presa da qualcun altro (⌘spazio: la ricerca di macOS).
        case needsAccessibility
    }

    /// Il segno che Charland mette sui tasti che manda lei (⌘spazio per aprire apposta la ricerca di macOS): li lascia
    /// passare.
    nonisolated static let ownTag: Int64 = 0x4348_4C44_5352  // "CHLDSR"

    private var tap: CFMachPort?
    private var watchdog: Timer?
    private var onPress: (() -> Void)?
    private var combo = SearchSettings.comboDefault
    private var carbonRegistered = false
    /// Mentre si registra una scorciatoia nuova: niente si riaccende da solo (il controllo di ogni secondo rimetteva la
    /// scorciatoia vecchia sotto il registratore).
    private var paused = false
    /// Il registratore delle impostazioni: con l'intercettazione accesa riceve da lei la combinazione premuta, anche
    /// quelle che macOS si tiene (⌘spazio arriverebbe a Siri prima che a un ascolto dell'app).
    private var onRecord: ((KeyCombo) -> Void)?
    /// Un numero solo suo: il 40 era già di «Chiudi tutte le app» (`AppQuitter`), e registrare l'una toglieva l'altra.
    private static let carbonID: UInt32 = 50

    private init() {}

    /// Accende (o riaccende con una scorciatoia nuova). `press` arriva sul thread principale a ogni pressione.
    func start(combo: KeyCombo, press: @escaping () -> Void) {
        // Una scorciatoia nuova senza Accessibilità: la vecchia, registrata come scorciatoia normale, va tolta prima.
        if combo != self.combo { unregisterCarbon() }
        self.combo = combo
        onPress = press
        Self.state.configure(keyCode: Int64(combo.keyCode), flags: Self.cgFlags(combo.modifiers))
        install()
        if watchdog == nil {
            // Ogni secondo: permesso tolto, si chiude; concesso dopo, si accende; sospesa dal sistema, si riaccende.
            let timer = Timer(timeInterval: 1, repeats: true) { _ in
                MainActor.assumeIsolated { SearchHotkey.shared.check() }
            }
            timer.tolerance = 0.3
            RunLoop.main.add(timer, forMode: .common)
            watchdog = timer
        }
    }

    func stop() {
        watchdog?.invalidate()
        watchdog = nil
        removeTap()
        unregisterCarbon()
        onPress = nil
        Self.state.configure(keyCode: -1, flags: 0)
        setStatus(.off)
    }

    /// Mentre si registra una scorciatoia nuova nelle impostazioni la vecchia non deve scattare (e non deve sparire
    /// prima di arrivare al registratore).
    func pause(_ paused: Bool) {
        self.paused = paused
        Self.state.setPaused(paused)
        if paused {
            unregisterCarbon()
        } else {
            onRecord = nil
            if onPress != nil { install() }
        }
    }

    /// Registra la prossima combinazione con l'intercettazione (se c'è): `true` se la prenderà lei.
    func record(_ done: @escaping (KeyCombo) -> Void) -> Bool {
        onRecord = done
        Self.state.setRecording(tap != nil)
        return tap != nil
    }

    fileprivate func pressed() {
        onPress?()
    }

    fileprivate func recorded(keyCode: Int64, flags: UInt64) {
        var modifiers: UInt32 = 0
        if flags & CGEventFlags.maskCommand.rawValue != 0 { modifiers |= UInt32(cmdKey) }
        if flags & CGEventFlags.maskAlternate.rawValue != 0 { modifiers |= UInt32(optionKey) }
        if flags & CGEventFlags.maskControl.rawValue != 0 { modifiers |= UInt32(controlKey) }
        if flags & CGEventFlags.maskShift.rawValue != 0 { modifiers |= UInt32(shiftKey) }
        let done = onRecord
        onRecord = nil
        done?(KeyCombo(keyCode: UInt32(keyCode), modifiers: modifiers))
    }

    /// Una scorciatoia accettabile: un tasto che non scrive (spazio, Invio, Tab, F1…F20) con ⌘, ⌃ o ⌥, oppure una lettera
    /// con almeno due fra ⌘ ⌃ ⌥. L'intercettazione la toglie a tutte le app: ⌘C o ⌘V non si devono poter scegliere, e
    /// sulla tastiera italiana ⌥ con una lettera scrive @, #, [ …
    static func acceptable(_ combo: KeyCombo) -> Bool {
        SearchTapState.acceptable(keyCode: Int64(combo.keyCode), flags: cgFlags(combo.modifiers))
    }

    private func install() {
        guard !paused else { return }
        if AXIsProcessTrusted() {
            unregisterCarbon()
            if tap == nil { createTap() }
            setStatus(tap != nil ? .active : .needsAccessibility)
        } else {
            removeTap()
            if !carbonRegistered {
                carbonRegistered = HotkeyCenter.shared.register(id: Self.carbonID, combo: combo,
                                                                down: { SearchHotkey.shared.pressed() })
            }
            // ⌘spazio lo tiene comunque macOS: registrata o no, senza Accessibilità non arriva.
            let taken = !carbonRegistered || combo == SearchSettings.comboDefault
            setStatus(taken ? .needsAccessibility : .registered)
        }
    }

    private func check() {
        guard onPress != nil, !paused else { return }
        if !AXIsProcessTrusted() {
            if tap != nil { removeTap() }
            install()
        } else if let tap {
            if !CGEvent.tapIsEnabled(tap: tap) { CGEvent.tapEnable(tap: tap, enable: true) }
        } else {
            install()
        }
    }

    private func createTap() {
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue) | CGEventMask(1 << CGEventType.keyUp.rawValue)
        // In testa: prima di ogni altra intercettazione e prima delle scorciatoie di sistema.
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                          eventsOfInterest: mask, callback: searchTapCallback, userInfo: nil) else { return }
        self.tap = tap
        Self.runOnOwnThread(CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0))
        CGEvent.tapEnable(tap: tap, enable: true)
        Self.state.setTap(tap)
    }

    private func removeTap() {
        guard let tap else { return }
        Self.state.setTap(nil)
        CGEvent.tapEnable(tap: tap, enable: false)
        // invalidata la porta, il suo thread resta senza niente da ascoltare e finisce da solo
        CFMachPortInvalidate(tap)
        self.tap = nil
    }

    private func unregisterCarbon() {
        guard carbonRegistered else { return }
        HotkeyCenter.shared.unregister(id: Self.carbonID)
        carbonRegistered = false
    }

    private func setStatus(_ status: Status) {
        if SearchSettings.shared.hotkey != status { SearchSettings.shared.hotkey = status }
    }

    /// I modificatori delle scorciatoie di sistema nel formato di CGEvent.
    nonisolated static func cgFlags(_ carbon: UInt32) -> UInt64 {
        var f: UInt64 = 0
        if carbon & UInt32(cmdKey) != 0 { f |= CGEventFlags.maskCommand.rawValue }
        if carbon & UInt32(optionKey) != 0 { f |= CGEventFlags.maskAlternate.rawValue }
        if carbon & UInt32(controlKey) != 0 { f |= CGEventFlags.maskControl.rawValue }
        if carbon & UInt32(shiftKey) != 0 { f |= CGEventFlags.maskShift.rawValue }
        return f
    }

    /// Il thread dell'intercettazione: non aspetta mai il thread principale, così scrivere non rallenta mai.
    nonisolated private static func runOnOwnThread(_ source: CFRunLoopSource?) {
        let box = SearchSourceBox(source: source)
        let thread = Thread {
            CFRunLoopAddSource(CFRunLoopGetCurrent(), box.source, .commonModes)
            CFRunLoopRun()
        }
        thread.name = "tasto-ricerca"
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    /// Apre la ricerca di macOS apposta (la riga «Chiedi a Siri»): un ⌘spazio finto col segno di Charland, che
    /// l'intercettazione lascia passare.
    nonisolated static func openSystemSearch() {
        let source = CGEventSource(stateID: .hidSystemState)
        // Il segno del tasto Command sinistro, come per il ⌘V della dettatura.
        let flags = CGEventFlags(rawValue: CGEventFlags.maskCommand.rawValue | 0x8)
        for down in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_Space), keyDown: down) else { continue }
            event.flags = flags
            event.setIntegerValueField(.eventSourceUserData, value: ownTag)
            event.post(tap: .cghidEventTap)
        }
    }

    // MARK: Stato condiviso col thread dell'intercettazione

    nonisolated fileprivate static let state = SearchTapState()
}

private struct SearchSourceBox: @unchecked Sendable { let source: CFRunLoopSource? }

/// Quello che la funzione dell'intercettazione deve sapere, letto sul suo thread: quale tasto, quali modificatori, se
/// la pressione è cominciata da noi (il suo rilascio va tenuto anche lui, se no l'app davanti riceve un rilascio senza
/// pressione).
final class SearchTapState: @unchecked Sendable {
    private let lock = NSLock()
    private var keyCode: Int64 = -1
    private var flags: UInt64 = 0
    private var paused = false
    private var recording = false
    /// Il tasto preso dal registratore: il suo rilascio va tenuto anche lui.
    private var recordedKey: Int64 = -1
    private var held = false
    /// Quando è cominciata la pressione presa: un rilascio che non arriva mai (intercettazione sospesa, Secure Input
    /// cominciato nel mezzo) non deve far togliere per sempre il rilascio dello spazio a tutte le app.
    private var heldSince: CFAbsoluteTime = 0
    private var tap: CFMachPort?

    private static let relevant = CGEventFlags.maskCommand.rawValue | CGEventFlags.maskAlternate.rawValue
        | CGEventFlags.maskControl.rawValue | CGEventFlags.maskShift.rawValue

    /// La regola di `SearchHotkey.acceptable`, nei termini di CGEvent (la usa anche il registratore sul suo thread).
    static func acceptable(keyCode code: Int64, flags: UInt64) -> Bool {
        let strong = [CGEventFlags.maskCommand, .maskControl, .maskAlternate].filter { flags & $0.rawValue != 0 }.count
        let functionKeys: Set<Int64> = [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111, 105, 107, 113, 106, 64, 79, 80, 90]
        let silent = [49, 36, 48].contains(code) || functionKeys.contains(code)
        return silent ? strong >= 1 : strong >= 2
    }

    func configure(keyCode: Int64, flags: UInt64) {
        lock.lock(); defer { lock.unlock() }
        self.keyCode = keyCode
        self.flags = flags
        held = false
    }

    func setPaused(_ on: Bool) {
        lock.lock(); defer { lock.unlock() }
        paused = on
        if !on { recording = false }
        held = false
    }

    func setRecording(_ on: Bool) {
        lock.lock(); defer { lock.unlock() }
        recording = on
    }

    func setTap(_ port: CFMachPort?) {
        lock.lock(); defer { lock.unlock() }
        tap = port
    }

    var currentTap: CFMachPort? {
        lock.lock(); defer { lock.unlock() }
        return tap
    }

    enum Decision { case pass, swallow, press, record }

    func decide(down: Bool, keyCode code: Int64, flags eventFlags: UInt64, autorepeat: Bool, tag: Int64) -> Decision {
        lock.lock(); defer { lock.unlock() }
        guard tag != SearchHotkey.ownTag else { return .pass }
        let now = CFAbsoluteTimeGetCurrent()
        if held, now - heldSince > 3 { held = false }
        // Il registratore delle impostazioni: la prima combinazione con ⌘ o ⌃ (o ⌥spazio) è sua, compresa ⌘spazio.
        if recording, down, !autorepeat {
            if Self.acceptable(keyCode: code, flags: eventFlags & Self.relevant) {
                recording = false
                recordedKey = code
                return .record
            }
        }
        if !down, code == recordedKey {
            recordedKey = -1
            return .swallow
        }
        guard keyCode >= 0, !paused, code == keyCode else { return .pass }
        if down {
            // La ripetizione di una pressione presa resta presa anche se nel frattempo si è lasciato ⌘.
            if autorepeat { return held ? .swallow : .pass }
            // Modificatori esatti: ⇧⌘spazio o ⌥⌘spazio (la finestra di ricerca del Finder) restano di chi li usa. Uno
            // spazio normale vuol dire che la pressione di prima è finita, anche se il suo rilascio non si è visto.
            guard eventFlags & Self.relevant == flags else { held = false; return .pass }
            held = true
            heldSince = now
            return .press
        }
        // Il rilascio arriva spesso coi modificatori già lasciati: conta solo che la pressione fosse nostra.
        guard held else { return .pass }
        held = false
        return .swallow
    }
}

/// Riceve gli eventi sul thread dell'intercettazione. Fa il minimo: decide, passa la pressione al thread principale e
/// toglie l'evento, oppure lo lascia andare com'era.
private func searchTapCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent,
                               refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        if let tap = SearchHotkey.state.currentTap, AXIsProcessTrusted() { CGEvent.tapEnable(tap: tap, enable: true) }
        return Unmanaged.passUnretained(event)
    }
    guard type == .keyDown || type == .keyUp else { return Unmanaged.passUnretained(event) }
    let decision = SearchHotkey.state.decide(down: type == .keyDown,
                                             keyCode: event.getIntegerValueField(.keyboardEventKeycode),
                                             flags: event.flags.rawValue,
                                             autorepeat: event.getIntegerValueField(.keyboardEventAutorepeat) != 0,
                                             tag: event.getIntegerValueField(.eventSourceUserData))
    switch decision {
    case .pass:
        return Unmanaged.passUnretained(event)
    case .swallow:
        return nil
    case .press:
        DispatchQueue.main.async { MainActor.assumeIsolated { SearchHotkey.shared.pressed() } }
        return nil
    case .record:
        let code = event.getIntegerValueField(.keyboardEventKeycode), flags = event.flags.rawValue
        DispatchQueue.main.async { MainActor.assumeIsolated { SearchHotkey.shared.recorded(keyCode: code, flags: flags) } }
        return nil
    }
}
