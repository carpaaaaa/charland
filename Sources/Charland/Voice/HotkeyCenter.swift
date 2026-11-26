import AppKit
import Carbon.HIToolbox
import CharlandCore

/// Una combinazione di tasti.
struct KeyCombo: Codable, Equatable, Sendable {
    var keyCode: UInt32
    /// Modificatori nel formato delle scorciatoie di sistema.
    var modifiers: UInt32

    /// ⌥Z, tenuto premuto. Fino al 17 novembre 2026 era ⌥X, perché ⌥Z era di OpenWhispr: quel giorno carpa l'ha
    /// tolta e ha scelto ⌥Z anche per Charland.
    static let dictationDefault = KeyCombo(keyCode: UInt32(kVK_ANSI_Z), modifiers: UInt32(optionKey))
    static let assistantDefault = KeyCombo(keyCode: UInt32(kVK_ANSI_C), modifiers: UInt32(optionKey))
    static let translateDefault = KeyCombo(keyCode: UInt32(kVK_ANSI_X), modifiers: UInt32(optionKey | shiftKey))
    static let repeatDefault = KeyCombo(keyCode: UInt32(kVK_ANSI_V), modifiers: UInt32(optionKey | controlKey))
    /// ⌃⌥A: Attivo.
    static let keepAwakeDefault = KeyCombo(keyCode: UInt32(kVK_ANSI_A), modifiers: UInt32(optionKey | controlKey))
    static let escape = KeyCombo(keyCode: UInt32(kVK_Escape), modifiers: 0)

    init(keyCode: UInt32, modifiers: UInt32) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    /// Il «tasto» di una scorciatoia fatta solo di modificatori (⌃⌥ tenuti insieme, senza lettera).
    static let modifiersOnlyKey: UInt32 = 0xFFFF

    /// Solo modificatori, almeno due: ⌃⌥, ⌥⌘…
    static func modifiersOnly(_ modifiers: UInt32) -> KeyCombo {
        KeyCombo(keyCode: modifiersOnlyKey, modifiers: modifiers)
    }

    /// ⌃⌥ tenuti insieme.
    static let controlOption = KeyCombo.modifiersOnly(UInt32(controlKey | optionKey))

    var isModifiersOnly: Bool { keyCode == Self.modifiersOnlyKey }

    /// I modificatori nel formato di AppKit.
    var flags: NSEvent.ModifierFlags {
        var f: NSEvent.ModifierFlags = []
        if modifiers & UInt32(controlKey) != 0 { f.insert(.control) }
        if modifiers & UInt32(optionKey) != 0 { f.insert(.option) }
        if modifiers & UInt32(shiftKey) != 0 { f.insert(.shift) }
        if modifiers & UInt32(cmdKey) != 0 { f.insert(.command) }
        return f
    }

    /// I modificatori di AppKit nel formato delle scorciatoie di sistema.
    static func carbonModifiers(_ flags: NSEvent.ModifierFlags) -> UInt32 {
        var m: UInt32 = 0
        if flags.contains(.command) { m |= UInt32(cmdKey) }
        if flags.contains(.option) { m |= UInt32(optionKey) }
        if flags.contains(.control) { m |= UInt32(controlKey) }
        if flags.contains(.shift) { m |= UInt32(shiftKey) }
        return m
    }

    init(event: NSEvent) {
        keyCode = UInt32(event.keyCode)
        var m: UInt32 = 0
        if event.modifierFlags.contains(.command) { m |= UInt32(cmdKey) }
        if event.modifierFlags.contains(.option) { m |= UInt32(optionKey) }
        if event.modifierFlags.contains(.control) { m |= UInt32(controlKey) }
        if event.modifierFlags.contains(.shift) { m |= UInt32(shiftKey) }
        modifiers = m
    }

    /// Come si scrive: ⌥Z, ⌃⌥V.
    var display: String {
        var s = ""
        if modifiers & UInt32(controlKey) != 0 { s += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { s += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { s += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { s += "⌘" }
        return isModifiersOnly ? s : s + Self.keyName(keyCode)
    }

    static func keyName(_ code: UInt32) -> String {
        switch Int(code) {
        case kVK_Escape: return "esc"
        case kVK_Space: return "␣"
        case kVK_Return: return "↩"
        case kVK_Tab: return "⇥"
        case kVK_Delete: return "⌫"
        case kVK_F1...kVK_F1: return "F1"
        default: break
        }
        // Il carattere che quel tasto produce con la tastiera attuale.
        guard let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
              let pointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return "?" }
        let data = Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue() as Data
        return data.withUnsafeBytes { raw -> String in
            guard let layout = raw.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return "?" }
            var dead: UInt32 = 0
            var length = 0
            var chars = [UniChar](repeating: 0, count: 4)
            let status = UCKeyTranslate(layout, UInt16(code), UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
                                        OptionBits(kUCKeyTranslateNoDeadKeysBit), &dead, 4, &length, &chars)
            guard status == noErr, length > 0 else { return "?" }
            return String(utf16CodeUnits: chars, count: length).uppercased()
        }
    }

    /// Il codice del tasto che scrive un certo carattere con la tastiera attuale
    /// (serve per ⌘V: su tastiere non americane la V può stare altrove).
    static func keyCode(for character: String) -> CGKeyCode? {
        for code in 0..<50 where keyName(UInt32(code)).lowercased() == character.lowercased() {
            return CGKeyCode(code)
        }
        return nil
    }
}

/// Le scorciatoie globali, registrate come scorciatoie di sistema: funzionano in qualsiasi
/// app, danno pressione e rilascio e non chiedono nessun permesso.
@MainActor
final class HotkeyCenter {
    static let shared = HotkeyCenter()

    private var handlers: [UInt32: (down: () -> Void, up: () -> Void)] = [:]
    private var references: [UInt32: EventHotKeyRef] = [:]
    /// Le scorciatoie fatte solo di modificatori (⌃⌥): non sono scorciatoie di sistema, si ascoltano a parte.
    private var holds: [UInt32: ModifierHold] = [:]
    private var installed = false
    private static let signature: OSType = 0x4348_4C44 // "CHLD"

    private init() {}

    /// Registra una scorciatoia. Restituisce `false` se un'altra app la tiene già o, per una scorciatoia di soli
    /// modificatori, se manca il permesso di Accessibilità che serve ad ascoltarla. `other` si chiama quando una
    /// scorciatoia di soli modificatori serviva in realtà a un'altra (⌃⌥ + un tasto).
    @discardableResult
    func register(id: UInt32, combo: KeyCombo, down: @escaping () -> Void, up: @escaping () -> Void = {},
                  other: @escaping () -> Void = {}) -> Bool {
        install()
        unregister(id: id)
        if combo.isModifiersOnly {
            let hold = ModifierHold(target: combo.flags, down: down, up: up, other: other)
            hold.start()
            holds[id] = hold
            return AXIsProcessTrusted()
        }
        var reference: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: Self.signature, id: id)
        let status = RegisterEventHotKey(combo.keyCode, combo.modifiers, hotKeyID, GetEventDispatcherTarget(), 0, &reference)
        guard status == noErr, let reference else { return false }
        references[id] = reference
        handlers[id] = (down, up)
        return true
    }

    func unregister(id: UInt32) {
        if let reference = references.removeValue(forKey: id) { UnregisterEventHotKey(reference) }
        handlers[id] = nil
        holds.removeValue(forKey: id)?.stop()
    }

    func unregisterAll() {
        for id in Array(references.keys) + Array(holds.keys) { unregister(id: id) }
    }

    /// La scorciatoia di soli modificatori è ancora tenuta, senza altri tasti da quando è cominciata.
    func isHeldClean(id: UInt32) -> Bool {
        holds[id]?.isClean ?? false
    }

    fileprivate func fire(id: UInt32, pressed: Bool) {
        // Una scorciatoia di sistema di Charland (⌃⌥A, ⌃⌥V) mentre si tengono ⌃⌥: quei modificatori erano per lei.
        if pressed { for hold in holds.values { hold.otherInput() } }
        guard let handler = handlers[id] else { return }
        if pressed { handler.down() } else { handler.up() }
    }

    private func install() {
        guard !installed else { return }
        installed = true
        var types = [EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
                     EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))]
        InstallEventHandler(GetEventDispatcherTarget(), { _, event, _ -> OSStatus in
            guard let event else { return noErr }
            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                                           MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            guard status == noErr else { return status }
            let pressed = GetEventKind(event) == UInt32(kEventHotKeyPressed)
            let id = hotKeyID.id
            // Le scorciatoie arrivano sul thread principale.
            MainActor.assumeIsolated {
                HotkeyCenter.shared.fire(id: id, pressed: pressed)
            }
            return noErr
        }, 2, &types, nil, nil)
    }
}


/// Ascolta una scorciatoia fatta solo di modificatori (⌃⌥ tenuti insieme): i cambi dei modificatori e gli altri
/// tasti, in tutte le app. La regola è in `ModifierChord`.
///
/// Si ascolta con un'intercettazione degli eventi di sessione che lascia passare tutto, su un thread suo, e non con
/// un monitor di AppKit: il monitor non vede i tasti che un'altra app prende come scorciatoia (provato il 17
/// novembre 2026: ⌃⌥K non arrivava), e allora ⌃⌥ di una scorciatoia di un'altra app faceva partire la dettatura.
/// Serve Accessibilità, la stessa che serve a scrivere il testo. Come per volume e luminosità, se il permesso
/// viene tolto l'intercettazione si chiude subito (tenuta aperta, il sistema può bloccare tastiera e mouse).
@MainActor
final class ModifierHold {
    private var chord: ModifierChord
    private let down: () -> Void
    private let up: () -> Void
    private let other: () -> Void
    private var tap: CFMachPort?
    private var watchdog: DispatchSourceTimer?

    /// L'unica scorciatoia di soli modificatori accesa (quella della dettatura): la funzione che riceve gli eventi
    /// non ha contesto, la trova qui.
    fileprivate static weak var current: ModifierHold?
    nonisolated fileprivate static let relevant: NSEvent.ModifierFlags = [.control, .option, .shift, .command]

    init(target: NSEvent.ModifierFlags, down: @escaping () -> Void, up: @escaping () -> Void, other: @escaping () -> Void) {
        chord = ModifierChord(target: target.intersection(Self.relevant).rawValue)
        self.down = down
        self.up = up
        self.other = other
    }

    func start() {
        stop()
        guard AXIsProcessTrusted() else { return }
        let mask = CGEventMask(1 << CGEventType.flagsChanged.rawValue) | CGEventMask(1 << CGEventType.keyDown.rawValue)
        // In testa: un'altra app che intercetta i tasti (e si tiene ⌃⌥ più una lettera) li toglierebbe prima di noi.
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                          eventsOfInterest: mask, callback: modifierTapCallback, userInfo: nil) else { return }
        self.tap = tap
        Self.current = self
        Self.runOnOwnThread(CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0))
        CGEvent.tapEnable(tap: tap, enable: true)
        watchdog = Self.makeWatchdog(for: tap)
    }

    func stop() {
        watchdog?.cancel()
        watchdog = nil
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            // invalidata la porta, il suo thread resta senza niente da ascoltare e finisce da solo
            CFMachPortInvalidate(tap)
        }
        tap = nil
        if Self.current === self { Self.current = nil }
    }

    var isClean: Bool {
        chord.isClean(now: ProcessInfo.processInfo.systemUptime)
    }

    func otherInput() {
        if chord.otherInput() == .other { other() }
    }

    /// Il sistema ha sospeso l'intercettazione (una risposta lenta, un attimo di troppo): si riaccende.
    fileprivate func reenable() {
        if let tap, AXIsProcessTrusted() { CGEvent.tapEnable(tap: tap, enable: true) }
    }

    fileprivate func handle(isFlags: Bool, bits: UInt, key: Int) {
        let action = isFlags ? chord.flags(bits, now: ProcessInfo.processInfo.systemUptime) : chord.otherInput()
        if DictationController.tracing, isFlags || action != nil || ProcessInfo.processInfo.environment["CHARLAND_TASTI"] != nil {
            print("[tasto] \(isFlags ? "cambio" : "tasto \(key)") modificatori \(bits) → \(action.map { "\($0)" } ?? "niente")")
            fflush(stdout)
        }
        switch action {
        case .down: down()
        case .up: up()
        case .other: other()
        case nil: break
        }
    }

    /// Il thread dell'intercettazione: non aspetta mai il thread principale, così scrivere non rallenta mai.
    nonisolated private static func runOnOwnThread(_ source: CFRunLoopSource?) {
        let box = HoldSourceBox(source: source)
        let thread = Thread {
            CFRunLoopAddSource(CFRunLoopGetCurrent(), box.source, .commonModes)
            CFRunLoopRun()
        }
        thread.name = "tasto-dettatura"
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    /// Ogni secondo: permesso tolto, si chiude subito; sospesa dal sistema, si riaccende.
    nonisolated private static func makeWatchdog(for tap: CFMachPort) -> DispatchSourceTimer {
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .userInitiated))
        timer.schedule(deadline: .now() + 1, repeating: 1)
        let box = HoldPortBox(port: tap)
        timer.setEventHandler {
            if !AXIsProcessTrusted() {
                CGEvent.tapEnable(tap: box.port, enable: false)
                CFMachPortInvalidate(box.port)
                DispatchQueue.main.async { MainActor.assumeIsolated { ModifierHold.current?.stop() } }
            } else if !CGEvent.tapIsEnabled(tap: box.port) {
                CGEvent.tapEnable(tap: box.port, enable: true)
            }
        }
        timer.resume()
        return timer
    }
}

private struct HoldSourceBox: @unchecked Sendable { let source: CFRunLoopSource? }
private struct HoldPortBox: @unchecked Sendable { let port: CFMachPort }

/// Riceve gli eventi sul thread dell'intercettazione. Fa il minimo: legge tipo e modificatori, passa al thread
/// principale e lascia andare l'evento com'era.
private func modifierTapCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent,
                                 refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        if DictationController.tracing { print("[tasto] intercettazione sospesa dal sistema (\(type.rawValue))"); fflush(stdout) }
        DispatchQueue.main.async { MainActor.assumeIsolated { ModifierHold.current?.reenable() } }
        return Unmanaged.passUnretained(event)
    }
    let isFlags = type == .flagsChanged
    // i bit dei modificatori di CGEvent sono gli stessi di AppKit
    let bits = UInt(event.flags.rawValue) & ModifierHold.relevant.rawValue
    let key = Int(event.getIntegerValueField(.keyboardEventKeycode))
    DispatchQueue.main.async { MainActor.assumeIsolated { ModifierHold.current?.handle(isFlags: isFlags, bits: bits, key: key) } }
    return Unmanaged.passUnretained(event)
}
