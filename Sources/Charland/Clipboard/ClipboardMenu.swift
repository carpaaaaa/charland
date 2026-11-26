import AppKit
import SwiftUI
import CharlandCore

/// Le misure del menu degli appunti. Raggi concentrici: le righe hanno il raggio del menu meno l'aria ai lati
/// (22 − 6 = 16, lo stesso delle tessere dell'isola).
enum ClipMetrics {
    static let width: CGFloat = 344
    static let radius: CGFloat = 22
    static let inset: CGFloat = 6
    static let rowRadius: CGFloat = radius - inset
    static let header: CGFloat = 46
    static let row: CGFloat = 34
    static let footer: CGFloat = 42
    static let listPadding: CGFloat = 4
    static let divider: CGFloat = 9
    static let empty: CGFloat = 96
    static let maxRows = 12
    /// Aria fra la barra dei menu e il menu, a goccia staccata.
    static let gap: CGFloat = 7
    static let previewWidth: CGFloat = 300
    static let previewGap: CGFloat = 10
    static let previewMin: CGFloat = 56
    static let previewMax: CGFloat = 440
    /// Aria attorno per l'ombra.
    static let margin: CGFloat = 34

    static var maxHeight: CGFloat { header + CGFloat(maxRows) * row + divider + 2 * listPadding + footer }

    static func smooth(_ e0: Double, _ e1: Double, _ x: Double) -> Double {
        let t = min(1, max(0, (x - e0) / (e1 - e0)))
        return t * t * (3 - 2 * t)
    }

    static func lerp(_ a: CGFloat, _ b: CGFloat, _ t: Double) -> CGFloat { a + (b - a) * CGFloat(t) }

    /// Quanto è cresciuta la goccia: esce tonda dalla barra e si apre fino al menu intero.
    static func grow(_ presence: Double) -> Double { 0.12 + 0.88 * smooth(0.04, 0.8, presence) }

    /// Il raggio dell'unione morbida con la barra dei menu: parte da zero, regge il collo mentre il menu scende al suo
    /// posto e lo lascia spezzare poco prima che si fermi (come lo slider dal bordo e l'isola dal notch).
    static func blend(_ presence: Double) -> Double { 34 * smooth(0, 0.25, presence) * (1 - smooth(0.84, 1, presence)) }

    /// Il fondo del rigonfiamento della barra (sopra la finestra, quindi nascosto a riposo): all'inizio spinge in giù
    /// come una goccia che preme, poi rientra.
    static func wallBottom(_ presence: Double) -> Double { -2 + 9 * smooth(0, 0.18, presence) * (1 - smooth(0.3, 0.74, presence)) }

    /// I contenuti entrano quando la goccia è quasi menu, ed escono per primi.
    static func reveal(_ presence: Double) -> Double { smooth(0.6, 0.94, presence) }

}

/// Il campo della goccia: il menu e il rigonfiamento della barra sopra la farfalla, uniti con il minimo
/// morbido delle gocce dell'isola. Tutte distanze vere: lo scarto dichiarato è zero (vedi `SideSliderField`).
struct ClipField: ScalarField {
    let panel: CGRect
    let panelRadius: Double
    let wallX: Double
    let wallBottom: Double
    let blend: Double

    func value(x: Double, y: Double) -> Double {
        var d = SideSliderField.roundedBox(x - Double(panel.midX), y - Double(panel.midY), Double(panel.width) / 2,
                                           Double(panel.height) / 2, panelRadius)
        let wall = SideSliderField.roundedBox(x - wallX, y - (wallBottom - 14), 16, 14, 12)
        return Self.smoothMin(d, wall, blend)
    }

    var distortion: Double? { 0 }

    static func smoothMin(_ a: Double, _ b: Double, _ k: Double) -> Double {
        guard k > 0.0001 else { return min(a, b) }
        let h = max(k - abs(a - b), 0) / k
        return min(a, b) - h * h * k * 0.25
    }
}

/// La forma del menu, fotogramma per fotogramma: la guarda solo il fondo, così l'elenco non si ridisegna mentre la
/// goccia si muove.
@MainActor @Observable
final class ClipMenuShape {
    var size: CGSize = .zero
    var outline = Path()
    /// Dove stanno i contenuti (a goccia ferma, cioè la loro misura vera) e quanto si vedono.
    var panel: CGRect = .zero
    var contentHeight: CGFloat = 200
    var reveal = 0.0
    var preview: CGRect = .zero
    var previewOnLeft = true
    var previewReveal = 0.0
    var previewShown = false
    /// Il vetro dell'anteprima: un riquadro suo accanto al menu che compare e scompare in dissolvenza (carpa, 18 novembre
    /// 2026: «un classico fade smooth», non più la goccia che usciva dal fianco). Segue il bordo alto del menu.
    var previewFrame: CGRect = .zero
    var previewGlass = 0.0
}

/// Lo stato del menu che non cambia a ogni fotogramma.
@MainActor @Observable
final class ClipMenuState {
    var query = "" {
        didSet {
            guard query != oldValue else { return }
            selected = visible.first?.id
            scrollTarget += 1
            ClipboardMenu.shared.relayout()
        }
    }
    var selected: UUID?
    /// Cresce quando la tastiera sposta la selezione: l'elenco la porta in vista.
    var scrollTarget = 0
    var command = false
    var option = false
    /// ⌥ + Cancella armato: il secondo clic cancella anche i fissati.
    var confirmAll = false
    var previewOn = false
    var focus = 0

    /// Fissati in cima, poi il resto, dal più recente; filtrati dalla ricerca.
    var pinned: [ClipItem] { filtered.filter(\.pinned) }
    var recent: [ClipItem] { filtered.filter { !$0.pinned } }
    var visible: [ClipItem] { pinned + recent }

    private var filtered: [ClipItem] {
        let items = ClipboardHistory.shared.items
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return items }
        return items.filter { item in
            let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
            if item.title.range(of: q, options: options) != nil { return true }
            if let text = item.text, text.range(of: q, options: options) != nil { return true }
            if let files = item.files, files.contains(where: { $0.range(of: q, options: options) != nil }) { return true }
            return item.appName?.range(of: q, options: options) != nil
        }
    }

    var selectedItem: ClipItem? {
        guard let selected else { return nil }
        return ClipboardHistory.shared.items.first { $0.id == selected }
    }
}

/// Il menu degli appunti: un clic sulla farfalla (senza trascinare) o la scorciatoia Apri. Esce dalla barra dei menu
/// sotto la farfalla come una goccia, col vetro di Charland (nero in alto, vetro in basso), e prende la tastiera senza
/// attivare Charland: l'app in cui lavori resta davanti e la voce scelta si incolla lì.
@MainActor
final class ClipboardMenu {
    static let shared = ClipboardMenu()
    let shape = ClipMenuShape()
    let state = ClipMenuState()

    private var panel: ClipboardPanel?
    /// Lo Space dell'isola in cui è entrata la finestra (`IslandHub.spaceToken`): se cambia, la finestra si rifà.
    private var panelSpace = 0
    private lazy var clock = FrameClock { [weak self] link in self?.frame(link) }
    private var clockRunning = false
    private var lastTimestamp: CFTimeInterval = 0
    private let tracer = ContourTracer()

    private var presence = Animated(0, spring: ClipboardMenu.appearSpring, restDistance: 0.001, restSpeed: 0.01)
    /// La crescita a gelatina: insegue la comparsa in ritardo e con un piccolo rimbalzo.
    private var growth = Animated(0.12, spring: ClipboardMenu.growSpring, restDistance: 0.0005, restSpeed: 0.005)
    private var height = Animated(200, spring: Spring(response: 0.32, damping: 0.86), restDistance: 0.3, restSpeed: 3)
    private var previewPresence = Animated(0, spring: ClipboardMenu.previewSpring, restDistance: 0.001, restSpeed: 0.01)
    private var previewHeight = Animated(160, spring: Spring(response: 0.3, damping: 0.86), restDistance: 0.3, restSpeed: 3)
    /// Il tremolio della goccia appena staccata dalla barra.
    private var tremble = Animated(0, spring: Spring(response: 0.28, damping: 0.5), restDistance: 0.001, restSpeed: 0.01)
    private var wasAttached = false

    private static let appearSpring = Spring(response: 0.44, damping: 0.8)
    /// Rientrando niente rimbalzo: viene risucchiato nella barra, non lanciato.
    private static let hideSpring = Spring(response: 0.34, damping: 0.95)
    private static let growSpring = Spring(response: 0.3, damping: 0.62)
    /// Anche la crescita rientra senza rimbalzo: con quella a gelatina la goccia, ormai piccola, tornava a gonfiarsi un
    /// poco prima di sparire.
    private static let growHideSpring = Spring(response: 0.26, damping: 1.0)
    /// L'anteprima in dissolvenza: senza rimbalzo, un quarto di secondo.
    private static let previewSpring = Spring(response: 0.26, damping: 1)
    /// Chiudendo il menu l'anteprima rientra prima di lui, così è già dentro il menu quando lui sale nella barra.
    private static let previewHideSpring = Spring(response: 0.18, damping: 1)
    /// La goccia che rientra è tutta dentro la barra: da qui in poi la coda delle molle non si vede più.
    private var outOfSight = false

    private var screen: NSScreen?
    private var anchorX: CGFloat = 0
    private var finalX: CGFloat = 0
    private var previewX: CGFloat = 0
    private var monitors: [Any] = []
    private var closedAt = Date.distantPast
    /// Spenta a mano: l'anteprima non torna da sola finché il menu non si riapre.
    private var previewDismissed = false
    private var observingTermination = false
    private(set) var isOpen = false

    private static let shortcutID: UInt32 = 30
    private static let slowMotion = max(1, Double(ProcessInfo.processInfo.environment["CHARLAND_LENTO"] ?? "") ?? 1)
    private static let trace = ProcessInfo.processInfo.environment["CHARLAND_APPUNTI"] != nil

    // MARK: Scorciatoia

    func registerShortcut() {
        let settings = ClipboardSettings.shared
        HotkeyCenter.shared.unregister(id: Self.shortcutID)
        guard settings.enabled, let combo = settings.openCombo else { settings.openTaken = false; return }
        let ok = HotkeyCenter.shared.register(id: Self.shortcutID, combo: combo, down: { ClipboardMenu.shared.toggle(from: nil) })
        settings.openTaken = !ok
        // Tenuta da un'altra app (Maccy): appena quella si chiude, la prende Charland.
        if !ok, !observingTermination {
            observingTermination = true
            NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didTerminateApplicationNotification,
                                                              object: nil, queue: .main) { _ in
                MainActor.assumeIsolated {
                    if ClipboardSettings.shared.openTaken { ClipboardMenu.shared.registerShortcut() }
                }
            }
        }
    }

    /// Mentre si registra una scorciatoia nelle impostazioni, quella vecchia non deve scattare.
    func pauseShortcut() { HotkeyCenter.shared.unregister(id: Self.shortcutID) }

    // MARK: Apri e chiudi

    func toggle(from button: NSStatusBarButton?) {
        if isOpen { close(animated: true); return }
        // Il clic che ha appena chiuso il menu (fuori dal menu, sulla farfalla) non lo riapre.
        guard Date().timeIntervalSince(closedAt) > 0.25 else { return }
        open(from: button ?? MenuBarItem.shared.anchorButton)
    }

    private func open(from button: NSStatusBarButton?) {
        guard ClipboardSettings.shared.enabled else { return }
        ClipboardHistory.shared.start()
        // Dove nasce: sotto la farfalla; senza farfalla, sotto il notch dello schermo col puntatore.
        var anchor: CGFloat
        var screen: NSScreen?
        if let button, let window = button.window {
            let b = button.bounds
            anchor = window.convertPoint(toScreen: button.convert(NSPoint(x: b.midX, y: b.midY), to: nil)).x
            screen = NSScreen.screens.first { $0.frame.contains(window.frame.origin) } ?? window.screen
        } else {
            let mouse = NSEvent.mouseLocation
            screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
            anchor = screen?.frame.midX ?? 0
        }
        guard let screen else { return }
        self.screen = screen
        let f = screen.frame
        // Il bordo basso della barra dei menu. Con la barra che si nasconde il sistema non la riserva: lì vale la
        // finestra dell'icona.
        let wallY: CGFloat
        if screen.visibleFrame.maxY < f.maxY - 1 {
            wallY = screen.visibleFrame.maxY
        } else if let window = button?.window {
            wallY = window.frame.minY
        } else {
            wallY = f.maxY - max(24, screen.safeAreaInsets.top)
        }
        let w = ClipMetrics.width, p = ClipMetrics.previewWidth
        let panelMinX = min(max(anchor - w / 2, f.minX + 8), f.maxX - 8 - w)
        let left = panelMinX - ClipMetrics.previewGap - p >= f.minX + 8
        let previewMinX = left ? panelMinX - ClipMetrics.previewGap - p : panelMinX + w + ClipMetrics.previewGap
        let minX = max(f.minX, min(panelMinX, previewMinX) - ClipMetrics.margin)
        let maxX = min(f.maxX, max(panelMinX + w, previewMinX + p) + ClipMetrics.margin)
        let height = ClipMetrics.gap + max(ClipMetrics.maxHeight, ClipMetrics.previewMax) + ClipMetrics.margin
        let frame = CGRect(x: minX, y: wallY - height, width: maxX - minX, height: height)
        anchorX = anchor - minX
        finalX = panelMinX - minX
        previewX = previewMinX - minX
        shape.size = frame.size
        shape.previewOnLeft = left

        let panel = ensurePanel()
        if panel.frame != frame { panel.setFrame(frame, display: false) }

        state.query = ""
        state.selected = state.visible.first?.id
        state.confirmAll = false
        state.previewOn = false
        state.command = false
        state.option = false
        state.scrollTarget += 1
        previewDismissed = false
        self.height.snap(to: Double(targetHeight()))
        presence.spring = Self.appearSpring
        growth.spring = Self.growSpring
        previewPresence.spring = Self.previewSpring
        outOfSight = false
        presence.snap(to: 0)
        growth.snap(to: 0.12)
        previewPresence.snap(to: 0)
        tremble.snap(to: 0)
        wasAttached = true
        presence.target = 1
        publish()

        isOpen = true
        panel.alphaValue = 1
        panel.ignoresMouseEvents = false
        panel.makeKeyAndOrderFront(nil)
        state.focus += 1
        DispatchQueue.main.async { ClipboardMenu.shared.focusSearch() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { ClipboardMenu.shared.focusSearch() }
        ClipThumbnails.shared.warm(Array(state.visible.prefix(40)))
        installMonitors()
        // L'anteprima non parte da sola all'apertura: si apre quando il puntatore entra in una voce (carpa, 18 novembre
        // 2026: «si attivi solo quando effettivamente salgo in hover col cursore su una copia, non prima», e poi «appena
        // sali sopra alla cosa copiata, non con delay»).
        hoveredRow = nil
        Haptics.tick()
        run()
    }

    /// Esc, un clic fuori, la farfalla di nuovo: rientra nella barra dalla stessa strada.
    func close(animated: Bool) {
        guard isOpen else { return }
        isOpen = false
        closedAt = Date()
        removeMonitors()
        guard let panel else { return }
        panel.ignoresMouseEvents = true
        guard animated, panel.isVisible else { finish(); return }
        presence.spring = Self.hideSpring
        growth.spring = Self.growHideSpring
        previewPresence.spring = Self.previewHideSpring
        presence.target = 0
        previewPresence.target = 0
        run()
    }

    /// Scelta una voce: il menu sparisce in fretta, come un menu vero, e la tastiera torna subito all'app di prima;
    /// poi, se va incollata, un ⌘V finto arriva a quell'app.
    private func dismissForPaste() {
        isOpen = false
        closedAt = Date()
        removeMonitors()
        guard let panel else { pasteIfNeeded(); return }
        panel.ignoresMouseEvents = true
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.12
            panel.animator().alphaValue = 0
        }, completionHandler: {
            MainActor.assumeIsolated {
                ClipboardMenu.shared.finish()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) {
                    MainActor.assumeIsolated { ClipboardMenu.shared.pasteIfNeeded() }
                }
            }
        })
    }

    private var pasteAfterClose = false

    private func pasteIfNeeded() {
        guard pasteAfterClose else { return }
        pasteAfterClose = false
        guard AXIsProcessTrusted(), ProcessInfo.processInfo.environment["CHARLAND_NON_SCRIVERE"] == nil else { return }
        Self.postCommandV()
    }

    private func finish() {
        clock.stop()
        clockRunning = false
        presence.snap(to: 0)
        previewPresence.snap(to: 0)
        panel?.orderOut(nil)
        panel?.alphaValue = 1
        shape.previewShown = false
        state.previewOn = false
    }

    /// Il cursore nel campo di ricerca, anche se SwiftUI non lo rimette: il campo vero di AppKit sotto il TextField.
    private func focusSearch() {
        guard isOpen, let panel, let root = panel.contentView else { return }
        let field = Self.textField(in: root)
        if Self.trace {
            print("[appunti] fuoco: key=\(panel.isKeyWindow) primo=\(String(describing: panel.firstResponder.map { type(of: $0) })) campo=\(field.map { String(describing: type(of: $0)) } ?? "nessuno")")
            fflush(stdout)
        }
        guard let field else { return }
        if panel.firstResponder !== field.currentEditor() { panel.makeFirstResponder(field) }
    }

    private static func textField(in view: NSView) -> NSTextField? {
        if let field = view as? NSTextField, field.isEditable { return field }
        for sub in view.subviews { if let field = textField(in: sub) { return field } }
        return nil
    }

    /// All'accensione: finestra, vetro e righe si preparano adesso, fuori dallo schermo, non al primo clic (la prima
    /// apertura costava fotogrammi da 50 ms mentre la goccia nasceva).
    func warmUp() {
        // Anche con la finestra vecchia, se lo Space dell'isola è cambiato (blocco e sblocco): si rifà e si scalda adesso.
        guard panel == nil || panelSpace != IslandHub.shared.spaceToken, !isOpen, let screen = NSScreen.main else { return }
        let panel = ensurePanel()
        let size = CGSize(width: ClipMetrics.width + 2 * ClipMetrics.margin, height: ClipMetrics.maxHeight + ClipMetrics.margin)
        panel.setFrame(CGRect(x: screen.frame.minX - size.width - 100, y: screen.frame.minY, width: size.width, height: size.height), display: false)
        shape.size = size
        finalX = ClipMetrics.margin
        anchorX = finalX + ClipMetrics.width / 2
        height.snap(to: Double(targetHeight()))
        presence.snap(to: 1)
        growth.snap(to: 1)
        publish()
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            MainActor.assumeIsolated {
                let menu = ClipboardMenu.shared
                guard !menu.isOpen else { return }
                menu.panel?.orderOut(nil)
                menu.panel?.alphaValue = 1
                menu.presence.snap(to: 0)
                menu.growth.snap(to: 0.12)
                menu.publish()
            }
        }
    }

    private func ensurePanel() -> ClipboardPanel {
        if let panel, panelSpace == IslandHub.shared.spaceToken { return panel }
        // Lo Space dell'isola è nato o morto da quando c'è la finestra: quella vecchia non comparirebbe più.
        panel?.close()
        let panel = ClipboardPanel(frame: CGRect(x: 0, y: 0, width: 400, height: 400))
        // Nello Space dell'isola, prima di comparire: sulle scrivanie normali la finestra, tenuta nascosta a lungo,
        // finiva legata a quelle di quando era nata e su una nuova non si vedeva più (22 novembre 2026).
        panelSpace = IslandHub.shared.adopt(panel)
        let host = NSHostingView(rootView: ClipboardMenuView(shape: shape, state: state))
        host.sizingOptions = []
        host.frame = CGRect(origin: .zero, size: panel.frame.size)
        host.autoresizingMask = [.width, .height]
        panel.contentView = host
        panel.onResign = { ClipboardMenu.shared.close(animated: true) }
        self.panel = panel
        return panel
    }

    // MARK: Ascolto

    private func installMonitors() {
        removeMonitors()
        // I tasti: prima delle scorciatoie del menu, poi il campo di ricerca.
        if let m = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { event in
            ClipboardMenu.shared.handleKey(event) ? nil : event
        }) { monitors.append(m) }
        if let m = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged, handler: { event in
            ClipboardMenu.shared.modifiersChanged(event.modifierFlags)
            return event
        }) { monitors.append(m) }
        // Il puntatore: sopra il menu prende i clic, fuori li lascia passare alle finestre sotto.
        if let m = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .scrollWheel], handler: { event in
            ClipboardMenu.shared.pointerMoved(hover: event.type == .mouseMoved)
            return event
        }) { monitors.append(m) }
        if let m = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved, handler: { _ in
            MainActor.assumeIsolated { ClipboardMenu.shared.pointerMoved(hover: true) }
        }) { monitors.append(m) }
        // Un clic in un'altra app (o sulla scrivania, o sulla barra) chiude.
        if let m = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown], handler: { _ in
            MainActor.assumeIsolated { ClipboardMenu.shared.close(animated: true) }
        }) { monitors.append(m) }
        // E un clic fuori dal menu che arriva a Charland stessa: la finestra del menu è molto più grande del menu (tiene
        // il posto per l'anteprima e per l'altezza massima), e nella parte vuota il clic restava a lei senza fare niente
        // quando il puntatore ci era arrivato senza che la finestra se ne accorgesse (carpa: «cliccando fuori da quel
        // rettangolo si chiuda»). Vale anche per l'isola e le altre finestre di Charland.
        if let m = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown], handler: { event in
            ClipboardMenu.shared.clickedInApp(event) ? nil : event
        }) { monitors.append(m) }
        modifiersChanged(NSEvent.modifierFlags)
        pointerMoved(hover: false)
    }

    private func removeMonitors() {
        for m in monitors { NSEvent.removeMonitor(m) }
        monitors.removeAll()
    }

    private func modifiersChanged(_ flags: NSEvent.ModifierFlags) {
        let command = flags.contains(.command), option = flags.contains(.option)
        if state.command != command { state.command = command }
        if state.option != option {
            state.option = option
            if !option { state.confirmAll = false }
        }
    }

    /// Il puntatore. Sopra il menu prende i clic, fuori li lascia passare alle finestre sotto. E decide lui l'hover delle
    /// righe: in una finestra che prende la tastiera senza attivare Charland l'hover di SwiftUI non arriva (come
    /// nell'isola, vedi `PointerTracker`), quindi ogni riga dice dov'è (`rowFrame`) e vince quella sotto il puntatore.
    /// Solo quando il puntatore si muove davvero: se a muoversi è l'elenco (la tastiera che scorre, la rotella) la
    /// riga che passa sotto il puntatore fermo non ruba la selezione.
    private func pointerMoved(hover: Bool) {
        guard isOpen, let panel else { return }
        let mouse = NSEvent.mouseLocation
        let origin = panel.frame.origin, h = panel.frame.height
        func screenRect(_ r: CGRect) -> CGRect { CGRect(x: origin.x + r.minX, y: origin.y + h - r.maxY, width: r.width, height: r.height) }
        let overPanel = screenRect(shape.panel.insetBy(dx: -4, dy: -4)).contains(mouse)
        var inside = overPanel
        if shape.previewShown { inside = inside || screenRect(shape.previewFrame.insetBy(dx: -4, dy: -4)).contains(mouse) }
        if panel.ignoresMouseEvents == inside { panel.ignoresMouseEvents = !inside }
        guard hover, shape.reveal > 0.5 else { return }
        let point = CGPoint(x: mouse.x - origin.x, y: origin.y + h - mouse.y)
        let list = CGRect(x: shape.panel.minX, y: shape.panel.minY + ClipMetrics.header, width: shape.panel.width,
                          height: shape.panel.height - ClipMetrics.header - ClipMetrics.footer)
        guard overPanel, list.contains(point), let id = rowFrames.first(where: { $0.value.contains(point) })?.key else {
            leftRows()
            return
        }
        self.hover(id)
    }

    /// Un clic arrivato a una finestra di Charland mentre il menu è aperto. Dentro il menu (o l'anteprima) passa; fuori
    /// chiude il menu. Nella parte vuota della finestra del menu il clic si ferma lì (`true`); nelle altre finestre di
    /// Charland prosegue dopo la chiusura.
    private func clickedInApp(_ event: NSEvent) -> Bool {
        guard isOpen, let panel else { return false }
        guard event.window === panel else {
            close(animated: true)
            return false
        }
        let point = CGPoint(x: event.locationInWindow.x, y: panel.frame.height - event.locationInWindow.y)
        var inside = shape.panel.insetBy(dx: -2, dy: -2).contains(point)
        if shape.previewShown, shape.previewGlass > 0.05 { inside = inside || shape.previewFrame.contains(point) }
        if inside { return false }
        close(animated: true)
        return true
    }

    /// Dove sta ogni riga nella finestra (le righe pigre fuori vista se ne vanno da sole).
    private var rowFrames: [UUID: CGRect] = [:]

    func rowFrame(_ id: UUID, _ rect: CGRect?) { rowFrames[id] = rect }

    // MARK: Tastiera

    private func handleKey(_ event: NSEvent) -> Bool {
        guard isOpen else { return false }
        let combo = KeyCombo(event: event)
        let settings = ClipboardSettings.shared
        if let c = settings.pinCombo, c == combo { pinSelected(); return true }
        if let c = settings.deleteCombo, c == combo { deleteSelected(); return true }
        if let c = settings.previewCombo, c == combo { togglePreview(); return true }
        if let c = settings.openCombo, c == combo { close(animated: true); return true }
        if combo == ClipboardSettings.clearCombo { clear(); return true }
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        switch Int(event.keyCode) {
        case 125: move(flags.contains(.command) ? .max : 1); return true
        case 126: move(flags.contains(.command) ? .min : -1); return true
        case 121: move(ClipMetrics.maxRows); return true
        case 116: move(-ClipMetrics.maxRows); return true
        case 119: move(.max); return true
        case 115: move(.min); return true
        case 36, 76:
            if let id = state.selected { choose(id, flags: flags) }
            return true
        case 53:
            if !state.query.isEmpty { state.query = "" } else { close(animated: true) }
            return true
        case 48:
            return true
        default:
            break
        }
        if flags == .command {
            // ⌘1…⌘9: la voce in quella posizione.
            let digits: [Int: Int] = [18: 0, 19: 1, 20: 2, 21: 3, 23: 4, 22: 5, 26: 6, 28: 7, 25: 8]
            if let n = digits[Int(event.keyCode)] {
                let items = state.visible
                if n < items.count { choose(items[n].id, flags: []) }
                return true
            }
            if event.charactersIgnoringModifiers == "," { openSettings(); return true }
        }
        return false
    }

    private func move(_ delta: Int) {
        let items = state.visible
        guard !items.isEmpty else { return }
        let current = items.firstIndex { $0.id == state.selected } ?? -1
        let next: Int
        switch delta {
        case Int.max: next = items.count - 1
        case Int.min: next = 0
        default: next = min(items.count - 1, max(0, current + delta))
        }
        guard items[next].id != state.selected else { return }
        state.selected = items[next].id
        state.scrollTarget += 1
        selectionChanged()
    }

    /// La selezione è cambiata: se l'anteprima è aperta la segue. Con la tastiera non si apre da sola: solo il
    /// puntatore fermo su una voce la apre (`hover`).
    func selectionChanged() {
        if state.previewOn { relayoutPreview() }
    }

    /// La voce sotto il puntatore. Entrando in una voce (anche quella già scelta) l'anteprima si apre subito, senza
    /// attesa; spenta a mano con la scorciatoia, resta spenta finché il menu non si riapre.
    func hover(_ id: UUID) {
        guard isOpen else { return }
        let entered = hoveredRow != id
        hoveredRow = id
        if state.selected != id {
            state.selected = id
            selectionChanged()
        }
        if entered, !state.previewOn, !previewDismissed { setPreview(true) }
    }

    /// Il puntatore non è più su una voce (l'anteprima già aperta resta, e passando a un'altra voce la segue).
    private func leftRows() {
        hoveredRow = nil
    }

    /// La voce sotto il puntatore adesso, se c'è.
    private var hoveredRow: UUID?

    // MARK: Azioni

    /// Rimette la voce negli appunti e, se è acceso (o con ⌥ quando è spento), la incolla nell'app davanti.
    /// Con ⇧ solo il testo, senza formattazione.
    func choose(_ id: UUID, flags: NSEvent.ModifierFlags) {
        var paste = ClipboardSettings.shared.pasteOnSelect
        if flags.contains(.option) { paste.toggle() }
        choose(id, paste: paste, plain: flags.contains(.shift))
    }

    func choose(_ id: UUID, paste: Bool, plain: Bool) {
        guard ClipboardHistory.shared.restore(id, plain: plain) else { return }
        pasteAfterClose = paste
        dismissForPaste()
    }

    func pinSelected() {
        guard let id = state.selected else { return }
        togglePin(id)
    }

    func togglePin(_ id: UUID) {
        withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) { ClipboardHistory.shared.togglePin(id) }
        Haptics.tick()
        state.scrollTarget += 1
        relayout()
    }

    func deleteSelected() {
        guard let id = state.selected else { return }
        delete(id)
    }

    func delete(_ id: UUID) {
        let items = state.visible
        if state.selected == id, let index = items.firstIndex(where: { $0.id == id }) {
            let rest = items.filter { $0.id != id }
            state.selected = rest.isEmpty ? nil : rest[min(index, rest.count - 1)].id
        }
        withAnimation(.spring(response: 0.3, dampingFraction: 0.88)) { ClipboardHistory.shared.delete(id) }
        relayout()
        if state.previewOn {
            if state.selected == nil { setPreview(false) } else { relayoutPreview() }
        }
    }

    /// Cancella: senza ⌥ tutto tranne i fissati, subito; con ⌥ anche i fissati, al secondo clic.
    func clear(fromButton: Bool = false) {
        if fromButton, state.option {
            guard state.confirmAll else { state.confirmAll = true; return }
            state.confirmAll = false
            withAnimation(.spring(response: 0.34, dampingFraction: 0.9)) { ClipboardHistory.shared.clear(includingPinned: true) }
        } else {
            withAnimation(.spring(response: 0.34, dampingFraction: 0.9)) { ClipboardHistory.shared.clear(includingPinned: false) }
        }
        Haptics.play("done")
        state.selected = state.visible.first?.id
        setPreview(false)
        relayout()
    }

    func togglePreview() {
        if state.previewOn { previewDismissed = true }
        setPreview(!state.previewOn)
    }

    func preview(_ id: UUID) {
        state.selected = id
        setPreview(true)
    }

    private func setPreview(_ on: Bool) {
        guard on != state.previewOn || on else { return }
        if on, state.selectedItem == nil { return }
        state.previewOn = on
        if on {
            shape.previewShown = true
            if previewPresence.value < 0.01 { previewHeight.snap(to: previewHeight.target) }
        }
        previewPresence.target = on ? 1 : 0
        run()
    }

    func openSettings() {
        close(animated: true)
        AppServices.shared.showSettings(section: .clipboard)
    }

    // MARK: Misure

    /// L'altezza del menu per quello che c'è da mostrare adesso.
    func targetHeight() -> CGFloat {
        let pinned = state.pinned.count, recent = state.recent.count
        let rows = pinned + recent
        let list: CGFloat
        if rows == 0 {
            list = ClipMetrics.empty
        } else {
            list = CGFloat(min(rows, ClipMetrics.maxRows)) * ClipMetrics.row + 2 * ClipMetrics.listPadding
                + (pinned > 0 && recent > 0 ? ClipMetrics.divider : 0)
        }
        return ClipMetrics.header + list + ClipMetrics.footer
    }

    /// Le voci sono cambiate (ricerca, fissate, eliminate): il menu si allunga o si accorcia a molla.
    func relayout() {
        guard isOpen else { return }
        let target = Double(targetHeight())
        guard height.target != target else { return }
        height.target = target
        run()
    }

    /// L'altezza naturale del contenuto dell'anteprima, misurata dalla vista.
    func previewMeasured(_ natural: CGFloat) {
        let target = Double(min(ClipMetrics.previewMax, max(ClipMetrics.previewMin, natural)))
        guard abs(previewHeight.target - target) > 0.5 else { return }
        // Mentre nasce prende subito la misura giusta; dopo cambia a molla.
        if previewPresence.value < 0.05 { previewHeight.snap(to: target) } else { previewHeight.target = target }
        run()
    }

    private func relayoutPreview() {
        run()
    }

    // MARK: Fotogrammi

    private func run() {
        guard !clockRunning else { return }
        clockRunning = true
        lastTimestamp = 0
        clock.start(on: screen)
    }

    private func frame(_ link: CADisplayLink) {
        let now = link.targetTimestamp
        if Self.trace, lastTimestamp != 0, now - lastTimestamp > link.duration * 1.5 {
            print(String(format: "[appunti] fotogramma lungo %.0f ms p=%.2f q=%.2f", (now - lastTimestamp) * 1000,
                         presence.value, previewPresence.value)); fflush(stdout)
        }
        let dt = (lastTimestamp == 0 ? link.duration : min(now - lastTimestamp, link.duration * 1.25)) / Self.slowMotion
        lastTimestamp = now
        var moving = presence.step(dt: dt)
        growth.target = ClipMetrics.grow(presence.value)
        moving = growth.step(dt: dt) || moving
        moving = height.step(dt: dt) || moving
        moving = previewPresence.step(dt: dt) || moving
        moving = previewHeight.step(dt: dt) || moving
        moving = tremble.step(dt: dt) || moving
        publish()
        // Rientrando: appena la goccia è tutta dentro la barra (e l'anteprima dentro il menu) la finestra se ne va. Prima
        // si aspettava che ogni molla fosse ferma e un mozzicone restava appeso sotto la farfalla per quasi mezzo
        // secondo, poi spariva di colpo (18 novembre 2026).
        if !isOpen, presence.target == 0, outOfSight, previewPresence.value <= 0.0005 {
            clock.stop()
            clockRunning = false
            finish()
            return
        }
        guard !moving else { return }
        clock.stop()
        clockRunning = false
        if previewPresence.value == 0 { shape.previewShown = false }
        if presence.value == 0, !isOpen { finish() }
    }

    private func publish() {
        let start = CACurrentMediaTime()
        let p = presence.value
        let w = ClipMetrics.width
        let fullHeight = CGFloat(height.value)
        // La goccia: tonda all'uscita dalla barra, poi si apre in larghezza e in altezza fino al menu. Come un liquido
        // conserva il volume: più larga quando è in ritardo sulla sua crescita, più stretta quando la supera.
        let k = (growth.value - 0.12) / 0.88
        let lag = ClipMetrics.grow(p) / max(0.12, growth.value)
        let volume = CGFloat(min(1.1, max(0.9, pow(lag, 0.4))))
        let t = CGFloat(max(-0.6, min(0.6, tremble.value)))
        let width = max(30, ClipMetrics.lerp(30, w, k)) * volume * (1 + 0.012 * t)
        let h = max(22, ClipMetrics.lerp(22, fullHeight, pow(max(0, k), 1.2))) * (1 - 0.018 * t)
        var top = ClipMetrics.lerp(-6, ClipMetrics.gap, ClipMetrics.smooth(0.12, 0.92, p))
        // Rientrando, quando ormai è una gocciolina, sale tutta dentro la barra (il bordo alto della finestra). Prima si
        // fermava alla misura minima col bordo alto a −6: 16 punti restavano appesi sotto la farfalla.
        let closing = presence.target == 0
        if closing {
            let lift = 1 - ClipMetrics.smooth(0, 0.3, max(0, k))
            top -= CGFloat(lift) * (top + h)
        }
        outOfSight = closing && top + h <= 0.5
        let cx = ClipMetrics.lerp(anchorX, finalX + w / 2, ClipMetrics.smooth(0, 1, k))
        let panel = CGRect(x: cx - width / 2, y: top, width: width, height: h)
        let radius = min(Double(ClipMetrics.radius), Double(width) / 2, Double(h) / 2)
        let blend = ClipMetrics.blend(p)
        let wallBottom = ClipMetrics.wallBottom(p)
        // Il collo regge finché il raggio supera il doppio della distanza fra menu e barra; spezzandosi, il menu trema.
        let attached = blend > 2 * (Double(top) - wallBottom)
        if wasAttached, !attached, presence.target == 1 { tremble.velocity = -6 }
        wasAttached = attached

        // L'anteprima: al suo posto accanto al menu, in dissolvenza; segue il bordo alto del menu, così chiudendo sale con
        // lui mentre sparisce. Non fa più parte della goccia: il contorno è solo il menu.
        let q = previewPresence.value
        let finalPreview = CGRect(x: previewX, y: ClipMetrics.gap, width: ClipMetrics.previewWidth, height: CGFloat(previewHeight.value))

        // A goccia ferma il contorno è un rettangolo arrotondato: si traccia il campo solo mentre c'è un collo.
        let settled = blend == 0 && wallBottom <= -2
        var path = Path()
        if settled {
            path.addRoundedRect(in: panel, cornerSize: CGSize(width: radius, height: radius), style: .circular)
        } else {
            let field = ClipField(panel: panel, panelRadius: radius, wallX: Double(anchorX), wallBottom: wallBottom, blend: blend)
            let reach = blend * 0.25 + 3
            let minX = min(Double(panel.minX), Double(anchorX) - 16), maxX = max(Double(panel.maxX), Double(anchorX) + 16)
            let maxY = Double(panel.maxY)
            for loop in tracer.trace(field, minX: minX - reach, minY: min(wallBottom - 30, Double(panel.minY)) - reach, maxX: maxX + reach, maxY: maxY + reach) {
                guard let first = loop.first else { continue }
                path.move(to: CGPoint(x: first.x, y: first.y))
                for point in loop.dropFirst() { path.addLine(to: CGPoint(x: point.x, y: point.y)) }
                path.closeSubpath()
            }
        }
        shape.outline = path
        shape.panel = CGRect(x: finalX, y: ClipMetrics.gap, width: w, height: fullHeight)
        shape.contentHeight = fullHeight
        shape.reveal = ClipMetrics.reveal(p)
        shape.preview = finalPreview
        shape.previewFrame = finalPreview.offsetBy(dx: 0, dy: panel.minY - ClipMetrics.gap)
        shape.previewGlass = ClipMetrics.smooth(0, 0.85, q) * ClipMetrics.reveal(p)
        shape.previewReveal = ClipMetrics.smooth(0.15, 1, q) * ClipMetrics.reveal(p)
        if Self.trace {
            print(String(format: "[appunti] contorno %.2f ms p=%.3f q=%.3f collo=%@", (CACurrentMediaTime() - start) * 1000, p, q,
                         attached ? "sì" : "no"))
            fflush(stdout)
        }
    }

    // MARK: Incolla

    private static func postCommandV() {
        let source = CGEventSource(stateID: .combinedSessionState)
        let key = KeyCombo.keyCode(for: "v") ?? 9
        // Il segno del tasto Command sinistro: senza, le app fatte con Flutter ignorano il ⌘V finto (vedi `TextInserter`).
        let flags = CGEventFlags(rawValue: CGEventFlags.maskCommand.rawValue | 0x8)
        for down in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: down) else { continue }
            event.flags = flags
            event.post(tap: .cghidEventTap)
        }
    }
}

/// La finestra del menu: senza bordo, sopra tutto come l'isola, prende la tastiera senza attivare Charland (come il
/// nome del timer e Spotlight). Il vetro trasparente vero anche qui (vedi `IslandPanel`).
final class ClipboardPanel: NSPanel {
    var onResign: (@MainActor () -> Void)?

    init(frame: CGRect) {
        super.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        isMovable = false
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = false
        isReleasedWhenClosed = false
        animationBehavior = .none
        isExcludedFromWindowsMenu = true
        acceptsMouseMovedEvents = true
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    @objc func _hasActiveAppearanceIgnoringKeyFocus() -> Bool { true }

    override func resignKey() {
        super.resignKey()
        MainActor.assumeIsolated { onResign?() }
    }
}

/// Per le prove: `Charland --appunti` accende solo la farfalla e lo storico, senza isola, accanto alla Charland
/// installata. `CHARLAND_APPUNTI_APRI=1` apre il menu all'avvio. Da terminale si comanda con una notifica:
/// `com.charstudio.charland.appunti` con `apri`, `chiudi`, `anteprima`, `fissa`, `elimina`.
@MainActor
enum ClipboardTest {
    static func start() {
        MenuBarItem.shared.setShown(true)
        ClipboardHistory.shared.apply()
        DistributedNotificationCenter.default().addObserver(forName: Notification.Name("com.charstudio.charland.appunti"),
                                                            object: nil, queue: .main) { note in
            let command = note.object as? String ?? ""
            MainActor.assumeIsolated {
                let menu = ClipboardMenu.shared
                switch command {
                case "apri": if !menu.isOpen { menu.toggle(from: nil) }
                case "chiudi": menu.close(animated: true)
                case "anteprima": menu.togglePreview()
                case "fissa": menu.pinSelected()
                case "elimina": menu.deleteSelected()
                default: break
                }
            }
        }
        if ProcessInfo.processInfo.environment["CHARLAND_APPUNTI_APRI"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { ClipboardMenu.shared.toggle(from: nil) }
        }
    }
}
