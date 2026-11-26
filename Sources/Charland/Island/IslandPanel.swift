import AppKit

/// La finestra dell'isola: trasparente, senza bordo, sopra la barra dei menu.
/// Non prende mai il fuoco e lascia passare i clic finché il puntatore non è sulla forma.
final class IslandPanel: NSPanel {
    init(frame: CGRect) {
        super.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        // Sopra la barra dei menu, sotto i menu aperti e le finestre di sistema.
        level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        isMovable = false
        hidesOnDeactivate = false
        ignoresMouseEvents = true
        // I movimenti sopra l'isola arrivano anche alla finestra non attiva: il tracker li vede tutti.
        acceptsMouseMovedEvents = true
        isReleasedWhenClosed = false
        animationBehavior = .none
        isExcludedFromWindowsMenu = true
        setFrame(frame, display: false)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// Idea di Vorssaint (GPL-3.0-or-later, Copyright (C) 2026 Vorssaint), adattata per Charland.
    ///
    /// Il vetro trasparente vero, con la lente sui bordi, macOS lo disegna solo nelle finestre
    /// attive; in una finestra che non prende mai la tastiera lo disegna smerigliato e grigio.
    /// Questa risposta (una domanda interna di AppKit, provata il 17 novembre 2026 su macOS 27.3)
    /// gli fa disegnare l'aspetto attivo senza che l'isola prenda la tastiera. Se un giorno Apple
    /// la cambia, il vetro torna smerigliato e basta: niente si rompe.
    @objc func _hasActiveAppearanceIgnoringKeyFocus() -> Bool { true }

    // MARK: File trascinati

    /// Chi risponde ai file trascinati sopra l'isola (solo la finestra dell'isola ne ha uno).
    var dropTarget: TrayDropTarget? {
        didSet {
            if dropTarget != nil { registerForDraggedTypes([.fileURL]) } else { unregisterDraggedTypes() }
        }
    }

    @objc func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        dropTarget?.update(sender, window: self) ?? []
    }

    @objc func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        dropTarget?.update(sender, window: self) ?? []
    }

    @objc func draggingExited(_ sender: NSDraggingInfo?) {
        dropTarget?.exit()
    }

    @objc func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        dropTarget?.accepts(sender, window: self) ?? false
    }

    @objc func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        dropTarget?.perform(sender) ?? false
    }

    /// Nessun aggiornamento periodico a mouse fermo: si risponde solo quando il puntatore si muove.
    @objc func wantsPeriodicDraggingUpdates() -> Bool { false }
}

/// Adattato da `NotchOverlaySpace` di Vorssaint (GPL-3.0-or-later, Copyright (C) 2026 Vorssaint), tradotto e
/// modificato per Charland. Vedi THIRD_PARTY_LICENSES.md.
///
/// Uno Space tutto dell'isola: una finestra che ci entra prima di comparire non appartiene
/// a nessuna scrivania, quindi i gesti fra scrivanie non la trascinano via, come la barra dei menu.
/// Usa funzioni private del sistema, cercate a runtime: se mancano, l'isola resta una
/// finestra normale su tutte le scrivanie e l'app continua a funzionare.
@MainActor
final class OverlaySpace {
    private typealias Connection = UInt32
    private typealias MainConnection = @convention(c) () -> Connection
    private typealias Create = @convention(c) (Connection, Int32, CFDictionary?) -> UInt64
    private typealias ShowHide = @convention(c) (Connection, CFArray) -> Int32
    private typealias Move = @convention(c) (Connection, CFArray, CFArray) -> Void
    private typealias Destroy = @convention(c) (Connection, UInt64) -> Void

    private let connection: Connection
    private let space: UInt64
    private let hideSpaces: ShowHide
    private let removeWindows: Move
    private let addWindows: Move
    private let destroySpace: Destroy
    private var members: Set<Int> = []
    private var closed = false

    init?() {
        func find(_ name: String) -> UnsafeMutableRawPointer? {
            dlsym(UnsafeMutableRawPointer(bitPattern: -2), name)
        }
        guard let main = find("CGSMainConnectionID"), let create = find("CGSSpaceCreate"),
              let show = find("CGSShowSpaces"), let hide = find("CGSHideSpaces"),
              let add = find("CGSAddWindowsToSpaces"), let remove = find("CGSRemoveWindowsFromSpaces"),
              let destroy = find("CGSSpaceDestroy") else { return nil }
        let connection = unsafeBitCast(main, to: MainConnection.self)()
        guard connection != 0 else { return nil }
        // Il valore 1 è l'unico con cui il Finder non disegna le icone della scrivania qui dentro.
        let space = unsafeBitCast(create, to: Create.self)(connection, 1, nil)
        guard space != 0 else { return nil }
        self.connection = connection
        self.space = space
        hideSpaces = unsafeBitCast(hide, to: ShowHide.self)
        addWindows = unsafeBitCast(add, to: Move.self)
        removeWindows = unsafeBitCast(remove, to: Move.self)
        destroySpace = unsafeBitCast(destroy, to: Destroy.self)
        _ = unsafeBitCast(show, to: ShowHide.self)(connection, [NSNumber(value: space)] as CFArray)
    }

    /// Va chiamata prima che la finestra compaia la prima volta.
    func adopt(_ window: NSWindow) {
        guard !closed, window.windowNumber > 0, members.insert(window.windowNumber).inserted else { return }
        addWindows(connection, [NSNumber(value: window.windowNumber)] as CFArray, [NSNumber(value: space)] as CFArray)
    }

    /// Le finestre escono prima che lo Space venga distrutto: una finestra rimasta
    /// senza Space non comparirebbe più.
    func close() {
        guard !closed else { return }
        closed = true
        if !members.isEmpty {
            removeWindows(connection, members.map { NSNumber(value: $0) } as CFArray, [NSNumber(value: space)] as CFArray)
            members.removeAll()
        }
        _ = hideSpaces(connection, [NSNumber(value: space)] as CFArray)
        destroySpace(connection, space)
    }
}
