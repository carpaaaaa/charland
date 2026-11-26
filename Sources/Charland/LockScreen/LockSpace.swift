import AppKit

/// Lo Space dove vivono le finestre di Charland sul blocco schermo.
///
/// Costruito sullo schema di `NotchOverlaySpace` di Vorssaint (GPL-3.0-or-later, Copyright (C) 2026 Vorssaint),
/// adattato e modificato per Charland. Vedi THIRD_PARTY_LICENSES.md.
///
/// Provato il 18 novembre 2026 su macOS 27.3:
/// - una finestra si vede sul blocco solo in uno Space con livello assoluto da 300 in su;
/// - 300 è quello giusto: da 301 in su si resta accesi sopra il velo nero con cui macOS spegne lo schermo;
/// - dentro il livello 300 decide lo strato della finestra: il blocco di macOS è una finestra sola allo strato 2004,
///   quindi le nostre (strato dello schermo protetto, vedi `LockPanel`) le stanno sopra.
///
/// Sono funzioni private del sistema, cercate a runtime: se ne manca una lo Space non nasce,
/// sul blocco non compare niente e il resto dell'app continua.
@MainActor
final class LockSpace {
    static let level: Int32 = 300

    private typealias MainConnection = @convention(c) () -> Int32
    private typealias Create = @convention(c) (Int32, Int32, CFDictionary?) -> UInt64
    private typealias SetLevel = @convention(c) (Int32, UInt64, Int32) -> Int32
    private typealias ShowHide = @convention(c) (Int32, CFArray) -> Int32
    private typealias AddWindows = @convention(c) (Int32, UInt64, CFArray, Int32) -> Int32
    private typealias Destroy = @convention(c) (Int32, UInt64) -> Void

    private let connection: Int32
    private let space: UInt64
    private let addWindows: AddWindows
    private let hideSpaces: ShowHide
    private let showSpaces: ShowHide
    private let destroySpace: Destroy
    private var members: Set<Int> = []
    private var closed = false

    init?() {
        guard let sky = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_NOW) else { return nil }
        func find(_ name: String) -> UnsafeMutableRawPointer? { dlsym(sky, name) }
        guard let main = find("SLSMainConnectionID"), let create = find("SLSSpaceCreate"),
              let setLevel = find("SLSSpaceSetAbsoluteLevel"), let show = find("SLSShowSpaces"), let hide = find("SLSHideSpaces"),
              let add = find("SLSSpaceAddWindowsAndRemoveFromSpaces"), let destroy = find("SLSSpaceDestroy") else { return nil }
        let connection = unsafeBitCast(main, to: MainConnection.self)()
        guard connection != 0 else { return nil }
        let space = unsafeBitCast(create, to: Create.self)(connection, 1, nil)
        guard space != 0 else { return nil }
        self.connection = connection
        self.space = space
        addWindows = unsafeBitCast(add, to: AddWindows.self)
        hideSpaces = unsafeBitCast(hide, to: ShowHide.self)
        showSpaces = unsafeBitCast(show, to: ShowHide.self)
        destroySpace = unsafeBitCast(destroy, to: Destroy.self)
        // Su macOS 27 i valori di ritorno di queste funzioni non dicono niente (cambiano a ogni chiamata anche quando
        // tutto va bene): non li guardiamo.
        _ = unsafeBitCast(setLevel, to: SetLevel.self)(connection, space, Self.level)
        _ = unsafeBitCast(show, to: ShowHide.self)(connection, [NSNumber(value: space)] as CFArray)
    }

    /// Porta una finestra nello Space del blocco. Va chiamata una volta sola per finestra, prima di mostrarla:
    /// le finestre restano vive e si mostrano o nascondono, non si ricreano a ogni blocco.
    func adopt(_ window: NSWindow) {
        guard !closed, window.windowNumber > 0, members.insert(window.windowNumber).inserted else { return }
        _ = addWindows(connection, space, [NSNumber(value: window.windowNumber)] as CFArray, 7)
    }

    /// Come nascondere lo Space senza passare dal thread principale: per il paracadute (`LockGuard`), quando il thread
    /// principale è fermo. È una sola chiamata al server delle finestre, coi numeri già presi qui.
    var hider: LockGuard.Hider {
        let call = SpaceCall(connection: connection, space: space, function: hideSpaces)
        return LockGuard.Hider { call.run() }
    }

    /// Una chiamata al server delle finestre già pronta, da fare da un altro thread.
    private struct SpaceCall: @unchecked Sendable {
        let connection: Int32
        let space: UInt64
        let function: ShowHide
        func run() { _ = function(connection, [NSNumber(value: space)] as CFArray) }
    }

    /// Lo Space torna visibile, dopo che il paracadute l'aveva nascosto.
    func reveal() {
        guard !closed else { return }
        _ = showSpaces(connection, [NSNumber(value: space)] as CFArray)
    }

    func close() {
        guard !closed else { return }
        closed = true
        _ = hideSpaces(connection, [NSNumber(value: space)] as CFArray)
        destroySpace(connection, space)
        members.removeAll()
    }
}

/// Una finestra di Charland sul blocco: trasparente, senza bordo, non prende mai la tastiera
/// (la tastiera sul blocco è della password, sempre).
final class LockPanel: NSPanel {
    init(frame: CGRect) {
        super.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        // Lo strato dello schermo protetto: sopra la finestra del blocco (2004), sotto il velo dello spegnimento.
        level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        isMovable = false
        hidesOnDeactivate = false
        ignoresMouseEvents = true
        acceptsMouseMovedEvents = true
        isReleasedWhenClosed = false
        animationBehavior = .none
        isExcludedFromWindowsMenu = true
        setFrame(frame, display: false)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// Come l'isola: il vetro vero macOS lo disegna solo nelle finestre attive; questa risposta glielo fa disegnare
    /// attivo senza prendere la tastiera. Se Apple la cambia, il vetro torna smerigliato e basta.
    @objc func _hasActiveAppearanceIgnoringKeyFocus() -> Bool { true }
}
