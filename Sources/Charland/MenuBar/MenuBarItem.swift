import AppKit
import CharlandCore

/// L'icona di Charland nella barra dei menu, la farfalla «Rugiada».
/// - Trascinata in giù: un timer, col gesto di Filo; lasciandola il timer vola nell'isola.
/// - Un clic, senza trascinare: il menu degli appunti, come Maccy (`ClipboardMenu`). Con lo storico spento, o con ⌥,
///   apre l'isola sulla casa (si richiude da sola se il puntatore non ci va).
/// - Tasto destro: timer veloci, Mantieni attivo, impostazioni, esci.
@MainActor
final class MenuBarItem: NSObject {
    static let shared = MenuBarItem()

    private var item: NSStatusItem?
    private let drag = TimerDrag()
    /// Quanto è alta la farfalla nella barra: 13 punti (carpa, 17 novembre: a 15 era troppo grande). La farfalla di
    /// gocce che la sostituisce nel gesto usa la stessa misura.
    static let iconHeight: CGFloat = 13
    private var closeTask: Task<Void, Never>?

    var isShown: Bool { item != nil }

    /// La farfalla, per far nascere da lì il menu degli appunti anche quando lo apre la scorciatoia.
    var anchorButton: NSStatusBarButton? { item?.button }

    func setShown(_ on: Bool) {
        if on, item == nil { show() } else if !on, let item { NSStatusBar.system.removeStatusItem(item); self.item = nil }
    }

    private func show() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.autosaveName = "CharlandStatusItem"
        guard let button = item.button else { return }
        button.image = CharlandMark.templateImage(height: Self.iconHeight)
        button.imagePosition = .imageOnly
        button.setAccessibilityLabel(Identity.name)
        button.toolTip = String(localized: "Clic per gli appunti, trascina in giù per un timer")
        button.target = self
        button.action = #selector(pressed)
        button.sendAction(on: [.leftMouseDown, .rightMouseDown])
        // Mentre la farfalla è fusa nel pallino l'icona non c'è: la sostituisce una farfalla di gocce identica che si
        // fonde e poi rinasce, quindi l'icona si spegne e si riaccende di colpo, nello stesso punto e con la stessa forma.
        // Prima restava lì appena spenta, con un pallino al centro.
        drag.onDragging = { [weak button] on in button?.alphaValue = on ? 0 : 1 }
        self.item = item
        drag.iconHeight = Self.iconHeight
        drag.warmUp(on: button.window?.screen ?? NSScreen.main)
    }

    @objc private func pressed() {
        guard let event = NSApp.currentEvent, let button = item?.button else { return }
        if event.type == .rightMouseDown || event.modifierFlags.contains(.control) {
            showMenu(from: button)
            return
        }
        // ⌘ trascina l'icona per spostarla nella barra: lo fa il sistema.
        if event.modifierFlags.contains(.command) { return }
        // Col menu degli appunti aperto, la farfalla lo richiude e basta: niente gesto del timer sotto il menu.
        if ClipboardMenu.shared.isOpen {
            ClipboardMenu.shared.close(animated: true)
            return
        }
        let option = event.modifierFlags.contains(.option)
        drag.track(from: button) { [weak self, weak button] dragged in
            guard !dragged else { return }
            // Il clic secco: gli appunti; con ⌥ (o con lo storico spento) la casa dell'isola.
            if ClipboardSettings.shared.enabled, !option {
                ClipboardMenu.shared.toggle(from: button)
            } else {
                self?.toggleIsland()
            }
        }
    }

    /// Un clic apre la casa dell'isola; un altro la chiude. Se il puntatore non ci arriva entro
    /// qualche secondo, si richiude da sola.
    private func toggleIsland() {
        guard let island = IslandHub.shared.primary else { return }
        let engine = island.engine
        closeTask?.cancel()
        if case .expanded = engine.mode {
            engine.send(.collapse)
            return
        }
        engine.refreshHome(.home(HomeInfo.now()))
        engine.send(.expand(id: nil))
        IslandHaptics.open()
        let stage = island.geometry.stageFrame
        closeTask = Task { [weak engine] in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled, let engine, case .expanded = engine.mode else { return }
            if !stage.contains(NSEvent.mouseLocation) { engine.send(.collapse) }
        }
    }

    private func showMenu(from button: NSStatusBarButton) {
        let menu = NSMenu()
        let timers = NSMenu()
        for preset in TimerCenter.presets {
            let entry = NSMenuItem(title: preset.label, action: #selector(startPreset(_:)), keyEquivalent: "")
            entry.target = self
            entry.representedObject = preset.seconds
            timers.addItem(entry)
        }
        let timerItem = NSMenuItem(title: String(localized: "Timer"), action: nil, keyEquivalent: "")
        timerItem.submenu = timers
        menu.addItem(timerItem)
        let awake = NSMenuItem(title: String(localized: "Mantieni attivo"), action: #selector(toggleAwake), keyEquivalent: "")
        awake.target = self
        awake.state = KeepAwake.shared.active ? .on : .off
        menu.addItem(awake)
        menu.addItem(.separator())
        let settings = NSMenuItem(title: String(localized: "Impostazioni…"), action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)
        let quit = NSMenuItem(title: String(localized: "Esci da Charland"), action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 6), in: button)
    }

    /// Per le scene dimostrative: tira giù un timer di 25 minuti con una curva morbida, si ferma un attimo e lascia.
    func rehearse() async {
        guard let button = item?.button, let window = button.window else { return }
        let b = button.bounds
        let anchor = window.convertPoint(toScreen: button.convert(NSPoint(x: b.midX, y: b.midY), to: nil))
        let distance: CGFloat = 30 + 14 * 20 + 2 * 33 + 10
        var path: [CGPoint] = []
        let steps = 96
        for i in 1...steps {
            let t = CGFloat(i) / CGFloat(steps)
            let e = t * t * (3 - 2 * t)
            path.append(CGPoint(x: anchor.x - 70 * sin(e * .pi / 2), y: anchor.y - distance * e))
        }
        path += Array(repeating: path.last ?? anchor, count: 50)
        await drag.rehearse(anchor: anchor, path: path, step: 1.0 / 60.0, glyph: TimerDrag.glyphColor(for: button))
    }

    @objc private func startPreset(_ sender: NSMenuItem) {
        guard let seconds = sender.representedObject as? TimeInterval else { return }
        TimerCenter.shared.start(seconds: seconds)
    }

    @objc private func toggleAwake() { KeepAwake.shared.toggleFromShortcut() }
    @objc private func openSettings() { AppServices.shared.showSettings() }
    @objc private func quit() { NSApp.terminate(nil) }
}
