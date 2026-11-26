import AppKit
import SwiftUI
import CharlandCore

/// Le misure della barra. Raggi concentrici: le righe hanno il raggio della barra meno l'aria ai lati (26 − 8 = 18).
enum SearchMetrics {
    static let fieldHeight: CGFloat = 52
    static let radius: CGFloat = 26
    static let inset: CGFloat = 8
    static let rowRadius: CGFloat = radius - inset
    static let row: CGFloat = 46
    static let listPadding: CGFloat = 8
    static let maxWidth: CGFloat = 680
    /// Aria fra il fondo del notch e la barra, a goccia staccata.
    static let gapBelowNotch: CGFloat = 10
    /// Aria attorno per l'ombra.
    static let margin: CGFloat = 40
    static let maxRows = 8
    /// La goccia appena uscita dal notch: tonda, larga così.
    static let dropSize: CGFloat = 30

    static func smooth(_ e0: Double, _ e1: Double, _ x: Double) -> Double {
        let t = min(1, max(0, (x - e0) / (e1 - e0)))
        return t * t * (3 - 2 * t)
    }

    static func lerp(_ a: CGFloat, _ b: CGFloat, _ t: Double) -> CGFloat { a + (b - a) * CGFloat(t) }

    /// Quanto è cresciuta la goccia: esce tonda dal notch e si apre fino alla barra intera.
    static func grow(_ presence: Double) -> Double { 0.12 + 0.88 * smooth(0.04, 0.8, presence) }

    /// L'unione morbida col notch: regge il collo mentre la barra scende e lo lascia spezzare poco prima che si fermi
    /// (come gli appunti dalla barra dei menu e lo slider dal bordo).
    static func blend(_ presence: Double) -> Double { 30 * smooth(0, 0.25, presence) * (1 - smooth(0.8, 1, presence)) }

    /// Di quanto il notch «spinge» fuori la goccia: all'inizio si gonfia sotto il suo bordo, poi rientra (sopra il bordo
    /// il vetro non si disegna, quindi a riposo non si vede).
    static func push(_ presence: Double) -> Double { -2 + 10 * smooth(0, 0.18, presence) * (1 - smooth(0.3, 0.74, presence)) }

    /// I contenuti entrano quando la goccia è quasi barra, ed escono per primi.
    static func reveal(_ presence: Double) -> Double { smooth(0.58, 0.92, presence) }

    static func listHeight(rows: Int) -> CGFloat { rows == 0 ? 0 : CGFloat(rows) * row + 2 * listPadding }
}

/// Da dove esce la barra e dove si ferma, nelle coordinate della sua finestra (origine in alto a sinistra).
struct SearchLayout: Equatable {
    /// La finestra, nelle coordinate dello schermo di AppKit.
    var window: CGRect
    /// Il centro del bordo basso del notch (o della pillola dell'isola sui Mac senza notch): lì nasce la goccia.
    var anchor: CGPoint
    /// La y del bordo basso del notch: sopra non si disegna niente, è il notch.
    var wall: CGFloat
    /// Quanto è largo il notch: il rigonfiamento da cui esce la goccia non lo supera.
    var notchWidth: CGFloat
    /// Il campo, fermo al suo posto, appena sotto il notch.
    var field: CGRect
    /// Quanto può scendere l'elenco su questo schermo, con la barra sotto il notch.
    var maxList: CGFloat
    /// Lo spazio fra il fondo del campo e il fondo dello schermo (meno un margine): con l'isola aperta la barra scende e
    /// le righe che ci stanno sono meno.
    var roomBelow: CGFloat

    /// La parte della finestra dove il vetro si vede: sotto il notch.
    var visible: CGRect { CGRect(x: 0, y: wall, width: window.width, height: max(0, window.height - wall)) }

    var maxRows: Int { max(1, min(SearchMetrics.maxRows, Int((maxList - 2 * SearchMetrics.listPadding) / SearchMetrics.row))) }
}

/// Il campo della goccia: la barra (con l'elenco) e il rigonfiamento del bordo del notch, uniti col minimo morbido
/// delle gocce dell'isola. Distanze vere: lo scarto dichiarato è zero (vedi `SideSliderField`).
struct SearchField: ScalarField {
    let body: CGRect
    let bodyRadius: Double
    let bump: CGRect
    let blend: Double

    func value(x: Double, y: Double) -> Double {
        let d = SideSliderField.roundedBox(x - Double(body.midX), y - Double(body.midY), Double(body.width) / 2,
                                           Double(body.height) / 2, bodyRadius)
        guard bump.width > 0 else { return d }
        let b = SideSliderField.roundedBox(x - Double(bump.midX), y - Double(bump.midY), Double(bump.width) / 2,
                                           Double(bump.height) / 2, 12)
        return ClipField.smoothMin(d, b, blend)
    }

    var distortion: Double? { 0 }
}

/// La forma, fotogramma per fotogramma: la guarda solo il fondo, così l'elenco non si ridisegna mentre la goccia si muove.
@MainActor @Observable
final class SearchShape {
    var size: CGSize = .zero
    var outline = Path()
    var visible: CGRect = .zero
    /// Il campo fermo e l'elenco alla sua misura piena: i contenuti stanno lì, la forma li ritaglia.
    var field: CGRect = .zero
    var list: CGRect = .zero
    var listHeight: CGFloat = 0
    var reveal = 0.0
    var listReveal = 0.0
    /// Quanto è ancora nera (1) o già vetro (0), in alto e in basso: la goccia nasce nera come il notch (carpa: «il notch è
    /// nero, voglio che l'animazione parta dal nero») e diventa vetro mentre scende e si apre, prima in basso, lontano dal
    /// notch, poi in alto. Rientrando torna nera prima di sparire dentro di lui.
    var inkTop = 0.0
    var inkBottom = 0.0
    /// Riduci movimento: niente goccia, la barra compare al suo posto in dissolvenza.
    var calm = false
    var calmPresence = 1.0
}

/// La risposta di «Chiedi».
struct SearchAnswer: Equatable {
    var question: String
    var text: String = ""
    var done = false
    var failed = false
}

/// Lo stato della barra che non cambia a ogni fotogramma.
@MainActor @Observable
final class SearchModel {
    var query = "" {
        didSet {
            guard query != oldValue else { return }
            SearchBar.shared.queryChanged()
        }
    }
    var results: [SearchResult] = []
    var selected: String?
    /// Cresce quando la tastiera sposta la selezione: l'elenco la porta in vista.
    var scrollTarget = 0
    var answer: SearchAnswer?
    var command = false
    var option = false
    var focus = 0
    var maxRows = SearchMetrics.maxRows
    /// La barra vuota mostra le ultime cose aperte da qui (senza selezione: Invio a barra vuota non apre niente).
    var showingRecents = false
    /// Un attimo dopo aver copiato un calcolo.
    var copiedID: String?

    var selectedResult: SearchResult? { results.first { $0.id == selected } }
}

/// La barra di ricerca di Charland (carpa, 23 novembre 2026: prima «che esca dal Dock», poi «no, voglio che esca dal
/// notch»): ⌘spazio (o la scorciatoia scelta) la fa uscire dal notch come una goccia di vetro, nera dove è ancora
/// attaccata a lui, che scende, si stacca e si apre nel campo; i risultati crescono dal campo verso il basso, il migliore
/// subito sotto di lui. Prende la tastiera senza attivare Charland, come Spotlight: l'app in cui lavori resta davanti.
///
/// Cerca le app (catalogo in memoria, `SearchCatalog`), file e cartelle (indice di Spotlight, `SearchFiles`), fa i calcoli
/// (`SearchCalculator`), apre indirizzi, cerca sul web e risponde alle domande col modello di Apple (`SearchAsk`). Impara
/// cosa scegli (`SearchMemory`).
///
/// Casi pensati: più schermi (esce dal notch, o dalla pillola dell'isola, dello schermo col puntatore), Mac senza notch,
/// barra dei menu nascosta e app a schermo intero (finestra nello Space dell'isola), l'isola aperta o che si apre e si
/// chiude mentre la barra è fuori (la barra esce dal suo fondo e si sposta con lei, `targetBottom`), Riduci movimento e
/// Riduci trasparenza,
/// contrasto aumentato, scrittura con i metodi di input (giapponese, cinese: Invio e frecce restano al metodo mentre
/// compone), tasti scritti prima che la barra sia visibile (la tastiera è sua dal primo istante), schermo che si spegne,
/// scrivania cambiata, schermi collegati o tolti.
@MainActor
final class SearchBar {
    static let shared = SearchBar()
    let shape = SearchShape()
    let model = SearchModel()

    private var panel: SearchPanel?
    /// Lo Space dell'isola in cui è entrata la finestra (`IslandHub.spaceToken`): se cambia, la finestra si rifà.
    private var panelSpace = 0
    private lazy var clock = FrameClock { [weak self] link in self?.frame(link) }
    private var clockRunning = false
    private var lastTimestamp: CFTimeInterval = 0
    private let tracer = ContourTracer()

    private var presence = Animated(0, spring: SearchBar.appearSpring, restDistance: 0.001, restSpeed: 0.01)
    private var growth = Animated(0.12, spring: SearchBar.growSpring, restDistance: 0.0005, restSpeed: 0.005)
    private var listHeight = Animated(0, spring: SearchBar.listSpring, restDistance: 0.3, restSpeed: 3)
    private var tremble = Animated(0, spring: Spring(response: 0.28, damping: 0.5), restDistance: 0.001, restSpeed: 0.01)
    /// Di quanto l'isola aperta scende sotto il notch: la barra si sposta giù di tanto, con la molla della forma
    /// dell'isola, così si muovono insieme.
    private var descent = Animated(0, spring: .shape, restDistance: 0.05, restSpeed: 0.5)
    /// L'isola dello schermo dove è uscita la barra.
    private weak var island: IslandController?
    private var wasAttached = false
    private var outOfSight = false
    /// L'elenco è già comparso in questa apertura (`publish`).
    private var listSettled = false

    private static let appearSpring = Spring(response: 0.46, damping: 0.8)
    /// Rientrando niente rimbalzo: viene risucchiata nel notch, non lanciata.
    private static let hideSpring = Spring(response: 0.32, damping: 0.95)
    private static let growSpring = Spring(response: 0.3, damping: 0.62)
    private static let growHideSpring = Spring(response: 0.24, damping: 1.0)
    private static let listSpring = Spring(response: 0.32, damping: 0.86)
    private static let listHideSpring = Spring(response: 0.16, damping: 1.0)
    private static let calmSpring = Spring(response: 0.22, damping: 1)

    private var layout: SearchLayout?
    private var monitors: [Any] = []
    private var observers: [NSObjectProtocol] = []
    private var closedAt = Date.distantPast
    private var started = false
    private(set) var isOpen = false
    private var reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    /// Le righe, nelle coordinate della finestra: per il puntatore (in una finestra che non attiva l'app l'hover di
    /// SwiftUI non arriva).
    private var rowFrames: [String: CGRect] = [:]
    /// La misura vera della risposta, per l'altezza dell'elenco.
    private var answerHeight: CGFloat = 120
    private var fileHits: [SearchFiles.Hit] = []
    private var fileQuery = ""
    /// La selezione l'hai spostata tu (frecce, puntatore): l'arrivo dei file non te la toglie. A ogni lettera nuova si
    /// riparte dal risultato migliore (prima restava sulla riga vecchia anche quando un'altra era salita in cima).
    private var userMoved = false
    /// Cresce a ogni apertura: un'attesa partita in un'apertura (la chiusura dopo aver copiato un calcolo, l'ascolto
    /// dell'isola) non tocca quella dopo.
    private var session = 0
    /// I tasti scritti mentre la barra si richiude: la finestra resta chiave finché la goccia non è rientrata, e quelle
    /// lettere si perdevano. Si ripassano all'app di prima appena la finestra se ne va.
    private var lateKeys: [CGEvent] = []
    private var lateMonitor: Any?

    private static let trace = ProcessInfo.processInfo.environment["CHARLAND_RICERCA"] != nil
    private static let slowMotion = max(1, Double(ProcessInfo.processInfo.environment["CHARLAND_LENTO"] ?? "") ?? 1)
    /// Per le prove mentre qualcuno usa il Mac: la barra compare senza prendere la tastiera, così le lettere che sta
    /// scrivendo restano nella sua app (`CHARLAND_RICERCA_SENZA_TASTIERA=1`; il 23 novembre una prova ne aveva prese).
    private static let noKeyboard = ProcessInfo.processInfo.environment["CHARLAND_RICERCA_SENZA_TASTIERA"] != nil

    private var settings: SearchSettings { .shared }

    private init() {}

    // MARK: Accensione

    /// L'app accende i servizi: la barra c'è solo se è accesa nelle impostazioni.
    func start() {
        started = true
        apply()
    }

    func stop() {
        started = false
        apply()
    }

    /// Una scelta cambiata nelle impostazioni.
    func apply() {
        let on = started && settings.enabled
        if on {
            SearchHotkey.shared.start(combo: settings.combo) { SearchBar.shared.toggle() }
            SearchCatalog.shared.refreshIfNeeded()
            warmUp()
        } else {
            SearchHotkey.shared.stop()
            if isOpen { close(animated: false) }
        }
    }

    func sourcesChanged() {
        guard isOpen else { return }
        queryChanged()
    }

    // MARK: Apri e chiudi

    func toggle() {
        if isOpen { close(animated: true); return }
        open()
    }

    func open() {
        guard settings.enabled, !isOpen else { return }
        SearchCatalog.shared.refreshIfNeeded()
        SearchCatalog.shared.noteOpened()
        SearchIcons.shared.noteOpened()
        reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        session += 1
        userMoved = false
        lateKeys = []
        if let lateMonitor { NSEvent.removeMonitor(lateMonitor) }
        lateMonitor = nil
        let layout = makeLayout()
        let reopening = panel?.isVisible == true && presence.value > 0.02 && self.layout == layout
        self.layout = layout
        let panel = ensurePanel()
        if panel.frame != layout.window { panel.setFrame(layout.window, display: false) }

        shape.size = layout.window.size
        shape.visible = layout.visible
        shape.field = layout.field
        shape.calm = reduceMotion
        model.maxRows = layout.maxRows
        model.answer = nil
        model.copiedID = nil
        model.command = false
        model.option = false
        isOpen = true
        if model.query.isEmpty { queryChanged() } else { model.query = "" }

        presence.spring = reduceMotion ? Self.calmSpring : Self.appearSpring
        growth.spring = Self.growSpring
        listHeight.spring = Self.listSpring
        outOfSight = false
        if !reopening {
            presence.snap(to: 0)
            growth.snap(to: 0.12)
            listHeight.snap(to: 0)
            tremble.snap(to: 0)
            wasAttached = true
        }
        presence.target = 1
        // Se l'isola è aperta la goccia esce dal suo fondo, non dal notch, e da lì in poi la segue.
        descent.snap(to: islandDescent(layout))
        fitRows()
        publish()

        panel.alphaValue = 1
        panel.ignoresMouseEvents = true
        // La tastiera subito, prima che la goccia sia visibile: le lettere scritte di corsa dopo ⌘spazio arrivano qui.
        if Self.noKeyboard { panel.orderFrontRegardless() } else { panel.makeKeyAndOrderFront(nil) }
        model.focus += 1
        focusField()
        DispatchQueue.main.async { SearchBar.shared.focusField() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { SearchBar.shared.focusField() }
        installMonitors()
        watchIsland()
        Haptics.tick()
        note("aperta: notch \(layout.anchor) campo=\(layout.field) finestra=\(layout.window)")
        run()
    }

    /// Esc a barra vuota, un clic fuori, ⌘spazio di nuovo: rientra nel notch dalla stessa strada.
    func close(animated: Bool, why: String = "") {
        guard isOpen else { return }
        note("chiusa: \(why)")
        isOpen = false
        closedAt = Date()
        removeMonitors()
        SearchFiles.cancel()
        SearchAsk.shared.reset()
        guard let panel else { return }
        panel.ignoresMouseEvents = true
        guard animated, panel.isVisible else { finish(); return }
        if panel.isKeyWindow, lateMonitor == nil {
            lateMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                SearchBar.shared.handleKey(event) ? nil : event
            }
        }
        presence.spring = reduceMotion ? Self.calmSpring : Self.hideSpring
        growth.spring = Self.growHideSpring
        listHeight.spring = Self.listHideSpring
        presence.target = 0
        listHeight.target = 0
        run()
    }

    private func finish() {
        clock.stop()
        clockRunning = false
        if let lateMonitor { NSEvent.removeMonitor(lateMonitor) }
        lateMonitor = nil
        defer { replayLateKeys() }
        presence.snap(to: 0)
        growth.snap(to: 0.12)
        listHeight.snap(to: 0)
        panel?.orderOut(nil)
        panel?.alphaValue = 1
        model.answer = nil
        model.results = []
        model.selected = nil
        rowFrames = [:]
    }

    /// Le lettere scritte mentre la goccia rientrava arrivano all'app che ora ha di nuovo la tastiera.
    private func replayLateKeys() {
        let keys = lateKeys
        lateKeys = []
        guard !keys.isEmpty, AXIsProcessTrusted() else { return }
        let mine = session
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) {
            // Riaperta nel frattempo: quelle lettere non sono per lei.
            guard MainActor.assumeIsolated({ SearchBar.shared.session == mine && !SearchBar.shared.isOpen }) else { return }
            for down in keys {
                down.post(tap: .cghidEventTap)
                if let up = down.copy() {
                    up.type = .keyUp
                    up.post(tap: .cghidEventTap)
                }
            }
        }
    }

    /// Il cursore nel campo, anche se SwiftUI non lo rimette: il campo vero di AppKit sotto il TextField.
    func focusField() {
        guard isOpen, let panel, let root = panel.contentView, let field = Self.textField(in: root) else { return }
        if panel.firstResponder !== field.currentEditor() { panel.makeFirstResponder(field) }
    }

    private static func textField(in view: NSView) -> NSTextField? {
        if let field = view as? NSTextField, field.isEditable { return field }
        for sub in view.subviews { if let field = textField(in: sub) { return field } }
        return nil
    }

    /// All'accensione: finestra, vetro e righe si preparano adesso, fuori dallo schermo, non al primo ⌘spazio.
    private func warmUp() {
        guard panel == nil || panelSpace != IslandHub.shared.spaceToken, !isOpen, let screen = NSScreen.main else { return }
        let panel = ensurePanel()
        let size = CGSize(width: SearchMetrics.maxWidth + 2 * SearchMetrics.margin, height: 420)
        panel.setFrame(CGRect(x: screen.frame.minX - size.width - 200, y: screen.frame.minY, width: size.width, height: size.height),
                       display: false)
        let field = CGRect(x: SearchMetrics.margin, y: 42, width: SearchMetrics.maxWidth, height: SearchMetrics.fieldHeight)
        layout = SearchLayout(window: panel.frame, anchor: CGPoint(x: field.midX, y: 32), wall: 32, notchWidth: 180,
                              field: field, maxList: 280, roomBelow: 280)
        shape.size = size
        shape.visible = layout!.visible
        shape.field = field
        // Un elenco pieno con ogni tipo di riga: SwiftUI prepara qui le righe che servono al primo ⌘spazio (la prima
        // comparsa dell'elenco costava un fotogramma).
        let finder = URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app")
        model.results = [
            SearchResult(id: "prova.calc", kind: .calculation, title: SearchCalculator.format(12_345.5), subtitle: "1+1", value: "2", label: "Calcolo"),
            SearchResult(id: "prova.app", kind: .app, title: "Finder", subtitle: "", url: finder, label: "App"),
            SearchResult(id: "prova.cartella", kind: .folder, title: "Charland", subtitle: "~", url: URL(fileURLWithPath: NSHomeDirectory()), label: "Cartella"),
            SearchResult(id: "prova.web", kind: .web, title: "Charland", subtitle: "Google", label: "Web"),
            SearchResult(id: "prova.chiedi", kind: .ask, title: "Charland", subtitle: "", value: "Charland", label: "Chiedi"),
        ]
        model.selected = "prova.app"
        presence.snap(to: 1)
        growth.snap(to: 1)
        shape.listHeight = SearchMetrics.listHeight(rows: model.results.count)
        listHeight.snap(to: Double(shape.listHeight))
        publish()
        panel.alphaValue = 0
        // Trasparente ma presente: su un monitor a sinistra di quello principale non deve prendersi i clic.
        panel.ignoresMouseEvents = true
        panel.orderFrontRegardless()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            MainActor.assumeIsolated {
                let bar = SearchBar.shared
                guard !bar.isOpen else { return }
                bar.panel?.orderOut(nil)
                bar.panel?.alphaValue = 1
                bar.model.results = []
                bar.model.selected = nil
                bar.shape.listHeight = 0
                bar.presence.snap(to: 0)
                bar.growth.snap(to: 0.12)
                bar.listHeight.snap(to: 0)
                bar.layout = nil
            }
        }
    }

    private func ensurePanel() -> SearchPanel {
        if let panel, panelSpace == IslandHub.shared.spaceToken { return panel }
        // Lo Space dell'isola è nato o morto da quando c'è la finestra: quella vecchia non comparirebbe più.
        panel?.close()
        let panel = SearchPanel(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        panelSpace = IslandHub.shared.adopt(panel)
        let host = FirstMouseHostingView(rootView: SearchBarView(shape: shape, model: model))
        host.sizingOptions = []
        host.frame = CGRect(origin: .zero, size: panel.frame.size)
        host.autoresizingMask = [.width, .height]
        panel.contentView = host
        panel.onResign = { SearchBar.shared.resigned() }
        self.panel = panel
        return panel
    }

    /// La barra ha perso la tastiera: un clic in un'altra app, un'app che si è messa davanti. Si chiude.
    private func resigned() {
        guard isOpen else { return }
        // Il clic che arriva sulla barra stessa (una riga) la fa tornare chiave da sola: si aspetta un attimo.
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                let bar = SearchBar.shared
                guard bar.isOpen, bar.panel?.isKeyWindow != true else { return }
                bar.close(animated: true, why: "tastiera persa")
            }
        }
    }

    // MARK: Dove esce

    /// Il notch dello schermo dove stai lavorando (quello col puntatore): la sua isola se c'è, se no le misure lette dal
    /// sistema. Sui Mac senza notch l'isola è una pillola al centro della barra dei menu, alta quanto lei: si esce da lì.
    private func makeLayout() -> SearchLayout {
        let m = SearchMetrics.self
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main ?? NSScreen.screens.first else {
            return SearchLayout(window: .zero, anchor: .zero, wall: 0, notchWidth: 0, field: .zero, maxList: 0, roomBelow: 0)
        }
        island = IslandHub.shared.islands.first { $0.geometry.frame == screen.frame }
        let geometry = island?.geometry ?? ScreenGeometry(screen: screen)
        let f = screen.frame
        let notchHeight = CGFloat(geometry.metrics.notchHeight)
        let notchWidth = CGFloat(geometry.metrics.notchWidth)
        let wall = f.maxY - notchHeight
        let anchorX = geometry.notchCenterX
        let w = min(m.maxWidth, f.width - 48)
        let midX = min(max(anchorX, f.minX + 24 + w / 2), f.maxX - 24 - w / 2)
        let field = CGRect(x: midX - w / 2, y: wall - m.gapBelowNotch - m.fieldHeight, width: w, height: m.fieldHeight)
        // Fino a poco sopra il fondo dello schermo (il Dock, se c'è, può restare sotto: la barra sta sopra di lui).
        let roomBelow = field.minY - (f.minY + 24)
        let maxList = max(m.listHeight(rows: 1), min(m.listHeight(rows: m.maxRows), roomBelow))

        // La finestra: dal bordo alto dello schermo (il collo nasce dentro il notch) al fondo dell'elenco più lungo, più
        // il posto per scendere sotto l'isola aperta e l'aria per l'ombra ai lati e sotto.
        var box = field.union(CGRect(x: field.minX, y: field.minY - maxList - Self.maxDescent, width: w, height: maxList + Self.maxDescent))
        box = box.union(CGRect(x: anchorX - notchWidth / 2 - 20, y: wall, width: notchWidth + 40, height: f.maxY - wall))
        box = box.insetBy(dx: -m.margin, dy: -m.margin)
        box = CGRect(x: box.minX, y: box.minY, width: box.width, height: f.maxY - box.minY).intersection(f).integral

        func canvas(_ r: CGRect) -> CGRect { CGRect(x: r.minX - box.minX, y: box.maxY - r.maxY, width: r.width, height: r.height) }
        return SearchLayout(window: box, anchor: CGPoint(x: anchorX - box.minX, y: box.maxY - wall), wall: box.maxY - wall,
                            notchWidth: notchWidth, field: canvas(field), maxList: maxList, roomBelow: roomBelow)
    }

    /// Quante righe stanno sotto il campo con la barra dov'è adesso (più giù se l'isola è aperta): su uno schermo basso
    /// l'elenco non deve finire sotto il bordo. Se cambia, l'elenco si rifà.
    private func fitRows() {
        guard let layout else { return }
        let m = SearchMetrics.self
        let room = layout.roomBelow - CGFloat(descent.target)
        let rows = max(1, min(m.maxRows, Int((min(layout.maxList, room) - 2 * m.listPadding) / m.row)))
        guard rows != model.maxRows else { return }
        model.maxRows = rows
        if model.answer == nil { queryChanged() } else { relayout() }
    }

    /// Quanto può scendere la barra sotto l'isola aperta: la finestra dell'isola è alta 360 punti.
    private static let maxDescent: CGFloat = 330

    /// Di quanto l'isola, quando avrà finito di muoversi, scende sotto il notch dentro la larghezza della barra.
    private func islandDescent(_ layout: SearchLayout) -> Double {
        guard let island, island.engine.mode != .rest else { return 0 }
        let notch = island.geometry.metrics.notchHeight
        let bottom = island.engine.targetBottom(within: Double(layout.field.width) / 2 + 8)
        return min(Double(Self.maxDescent), max(0, bottom - notch))
    }

    /// Ogni volta che l'isola si muove (si apre sotto il puntatore, cambia attività, si chiude) la barra guarda dove andrà
    /// a finire e si sposta con lei. Si riascolta a ogni cambio, finché la barra è aperta.
    private func watchIsland() {
        guard isOpen, let island else { return }
        let mine = session
        withObservationTracking {
            _ = island.model.outline
            _ = island.model.isVisible
        } onChange: {
            DispatchQueue.main.async { MainActor.assumeIsolated { SearchBar.shared.islandChanged(session: mine) } }
        }
    }

    /// Un ascolto per apertura: quelli rimasti da un'apertura vecchia (l'isola ferma mentre la barra era chiusa) si
    /// spengono qui invece di moltiplicarsi.
    private func islandChanged(session mine: Int) {
        guard isOpen, mine == session, let layout else { return }
        let target = islandDescent(layout)
        if abs(target - descent.target) > 0.5 {
            note(String(format: "isola: la barra va %.0f punti sotto il notch", target))
            descent.spring = reduceMotion ? Self.calmSpring : .shape
            descent.target = target
            fitRows()
            run()
        }
        watchIsland()
    }

    // MARK: Ricerca

    func queryChanged() {
        guard isOpen else { return }
        let query = model.query.trimmingCharacters(in: .whitespacesAndNewlines)
        // Con la risposta aperta si scrive la domanda dopo: la risposta resta finché non premi Invio (domanda nuova) o
        // Esc (si torna ai risultati di quello che hai scritto).
        guard model.answer == nil else { return }
        guard !query.isEmpty else {
            SearchFiles.cancel()
            fileHits = []
            fileQuery = ""
            let recents = settings.apps || settings.files ? SearchMemory.shared.recents(limit: min(5, model.maxRows)) : []
            model.showingRecents = !recents.isEmpty
            setResults(recents, keepSelection: false, select: false)
            return
        }
        model.showingRecents = false
        // I file della ricerca di prima restano finché arrivano quelli nuovi, se il testo è solo cresciuto: niente righe
        // che spariscono e tornano a ogni lettera.
        if !query.lowercased().hasPrefix(fileQuery.lowercased()) || fileQuery.isEmpty { fileHits = [] }
        userMoved = false
        rebuild(query, keepSelection: false)
        if settings.files, query.count >= 2 {
            SearchFiles.search(query, limit: 12, delay: 0.07) { hits in
                let bar = SearchBar.shared
                guard bar.isOpen, bar.model.query.trimmingCharacters(in: .whitespacesAndNewlines) == query else { return }
                bar.fileHits = hits
                bar.fileQuery = query
                bar.rebuild(query, keepSelection: true)
            }
        } else {
            SearchFiles.cancel()
            fileHits = []
        }
        if settings.ask, query.count >= 3, SearchAsk.isAvailable { SearchAsk.shared.prewarm() }
    }

    /// Mette insieme le righe: il calcolo o l'indirizzo in testa, poi app e file per punteggio, in fondo web e Chiedi.
    private func rebuild(_ query: String, keepSelection: Bool) {
        let started = CACurrentMediaTime()
        defer { if Self.trace { note(String(format: "righe per «%@» in %.2f ms", query, (CACurrentMediaTime() - started) * 1000)) } }
        var fixed: [SearchResult] = []
        var top: [SearchResult] = []
        // «apri Pinterest su Safari»: l'azione in cima, già scelta. «apri Nicegram»: la riga dell'app dell'iPhone (sotto
        // l'azione, se il nome è anche un sito noto).
        if let action = SearchCommand.parse(query) { top.append(action) }
        if let phone = SearchCommand.iPhoneTarget(query) { top.append(SearchCatalog.shared.iPhoneResult(phone)) }
        if settings.calculator, let calc = SearchCalculator.evaluate(query) {
            top.append(SearchResult(id: "calc", kind: .calculation, title: calc.display, subtitle: query, value: calc.display,
                                    label: String(localized: "Calcolo")))
        }
        if let link = Self.link(in: query) {
            top.append(SearchResult(id: "link", kind: .link, title: link.host ?? link.absoluteString,
                                    subtitle: link.absoluteString, url: link, label: String(localized: "Sito")))
        }
        if settings.web, let url = settings.engine.url(for: query) {
            fixed.append(SearchResult(id: "web", kind: .web, title: String(localized: "Cerca «\(query)» sul web"),
                                      subtitle: settings.engine.name, url: url, label: String(localized: "Web")))
        }
        if settings.ask, SearchAsk.isAvailable {
            fixed.append(SearchResult(id: "ask", kind: .ask, title: query, subtitle: String(localized: "Chiedi"), value: query,
                                      label: String(localized: "Chiedi")))
        }
        let room = max(1, model.maxRows - fixed.count - top.count)
        var found: [SearchResult] = []
        if settings.apps { found += SearchCatalog.shared.match(query, limit: room) }
        if settings.files {
            let q = SearchText.fold(query)
            found += fileHits.enumerated().map { index, hit in
                let boost = SearchMemory.shared.boost(id: "file:" + hit.path, query: q)
                var r = SearchFiles.result(hit, boost: boost)
                let words = SearchText.words(r.title)
                let match = SearchText.score(q, target: SearchText.fold(r.title), words: words,
                                             initials: String(words.compactMap(\.first))) ?? 150
                // Un file mai aperto da qui viene dopo le app che corrispondono bene, come in Spotlight: «settings» dava
                // sei cartelle «Settings» dei progetti e Impostazioni di Sistema restava fuori dall'elenco. Fra file con
                // lo stesso punteggio resta l'ordine di `SearchFiles` (i più usati di recente prima): l'ordinamento
                // non è stabile.
                r.score = boost + match - (boost > 0 ? 0 : 350) - Double(index) * 0.01
                return r
            }
        }
        found.sort { $0.score > $1.score }
        // Una riga già in cima (l'app dell'iPhone di «apri Nicegram») non si ripete sotto: due righe con lo stesso id
        // confonderebbero l'elenco.
        let topIDs = Set(top.map(\.id))
        found.removeAll { topIDs.contains($0.id) }
        let rows = Array((top + found.prefix(room) + fixed).prefix(model.maxRows))
        setResults(rows, keepSelection: keepSelection, select: true)
    }

    private func setResults(_ rows: [SearchResult], keepSelection: Bool, select: Bool) {
        let previous = model.selected
        if model.results != rows { model.results = rows }
        if keepSelection, userMoved, let previous, rows.contains(where: { $0.id == previous }) {
            // La riga scelta con le frecce resta scelta anche se arriva un file nuovo.
        } else {
            model.selected = select ? rows.first?.id : nil
        }
        relayout()
    }

    /// L'altezza dell'elenco cambia (righe nuove, una risposta che si allunga): la forma la insegue con la sua molla.
    func relayout() {
        guard let layout else { return }
        let target: CGFloat
        let room = min(layout.maxList, max(SearchMetrics.listHeight(rows: 1), layout.roomBelow - CGFloat(descent.target)))
        if model.answer != nil {
            target = min(room, max(84, answerHeight))
        } else {
            target = min(room, SearchMetrics.listHeight(rows: min(model.results.count, model.maxRows)))
        }
        shape.listHeight = target
        if isOpen, presence.value > 0.8 || reduceMotion { listHeight.target = Double(target) }
        run()
    }

    func answerMeasured(_ height: CGFloat) {
        guard abs(height - answerHeight) > 0.5 else { return }
        answerHeight = height
        relayout()
    }

    /// Un indirizzo scritto a mano: `apple.com`, `https://…`, `localhost:3000`.
    private static func link(in text: String) -> URL? {
        let t = text.trimmingCharacters(in: .whitespaces)
        guard !t.contains(" "), t.count >= 4 else { return nil }
        if t.hasPrefix("http://") || t.hasPrefix("https://") { return URL(string: t) }
        if t.hasPrefix("localhost") { return URL(string: "http://" + t) }
        let pattern = #"^[a-z0-9-]+(\.[a-z0-9-]+)*\.[a-z]{2,24}(:[0-9]{2,5})?(/.*)?$"#
        guard t.lowercased().range(of: pattern, options: .regularExpression) != nil else { return nil }
        // Un nome di file («Studio.md», «foto.jpg») non è un sito.
        let ext = (t.split(separator: "/").first.map(String.init) ?? t).split(separator: ".").last.map { $0.lowercased() } ?? ""
        guard !SearchCommand.fileExtensions.contains(ext) else { return nil }
        return URL(string: "https://" + t)
    }

    // MARK: Scelta

    func choose(_ id: String, flags: NSEvent.ModifierFlags = []) {
        guard let result = model.results.first(where: { $0.id == id }) else { return }
        let query = model.query
        switch result.kind {
        case .app, .file, .folder:
            guard let url = result.url else { return }
            SearchMemory.shared.remember(result, query: query)
            if flags.contains(.command) {
                SearchLaunch.reveal(url)
            } else if result.kind == .app {
                DockLaunch.open(url)
            } else {
                SearchLaunch.open(document: url)
            }
            close(animated: true)
        case .action:
            SearchCommand.perform(result)
            close(animated: true, why: "azione")
        case .iphoneApp:
            SearchMemory.shared.remember(result, query: query)
            openIPhone(result, flags: flags)
        case .link, .web:
            guard let url = result.url else { return }
            SearchLaunch.open(web: url)
            close(animated: true)
        case .calculation:
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(result.value ?? result.title, forType: .string)
            model.copiedID = result.id
            Haptics.tick()
            let mine = session
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
                MainActor.assumeIsolated {
                    guard SearchBar.shared.session == mine else { return }
                    SearchBar.shared.close(animated: true, why: "calcolo copiato")
                }
            }
        case .ask:
            if flags.contains(.option) {
                askSiri(result.value ?? query)
            } else {
                ask(result.value ?? query)
            }
        }
    }

    /// Un'app dell'iPhone: si passa dalla ricerca di macOS (`SearchLaunch.openIPhoneApp`), ⌘ apre Duplicazione iPhone.
    private func openIPhone(_ result: SearchResult, flags: NSEvent.ModifierFlags) {
        // Subito via: la bolla di macOS deve prendere la tastiera, e le lettere del nome devono arrivare a lei.
        close(animated: false, why: "app dell'iPhone")
        if flags.contains(.command) {
            DockLaunch.open(bundle: "com.apple.ScreenContinuity")
        } else {
            SearchLaunch.openIPhoneApp(named: result.title, confirm: !SearchCatalog.shared.hasMacApp(named: result.title))
        }
    }

    private func ask(_ question: String) {
        let q = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        // Un comando sicuro («aprimi Pinterest su Safari», «apri Note») si fa subito, senza passare dal modello. Prudente:
        // una domanda che comincia con «open» o «vai a» resta una domanda (lì decide il modello coi suoi strumenti).
        if let action = SearchCommand.parse(q, strict: true) {
            SearchCommand.perform(action)
            close(animated: true, why: "azione da Chiedi")
            return
        }
        // «apri Nicegram» chiesto a Chiedi: il modello non sa aprire le app dell'iPhone, la barra sì.
        if let phone = SearchCommand.iPhoneTarget(q, exact: true) {
            let result = SearchCatalog.shared.iPhoneResult(phone)
            SearchMemory.shared.remember(result, query: q)
            openIPhone(result, flags: [])
            return
        }
        model.answer = SearchAnswer(question: q)
        // Il campo si svuota per la domanda dopo (la domanda si legge già in cima alla risposta): prima restava scritta,
        // compariva due volte e per chiedere altro bisognava cancellarla a mano. Esc la rimette nel campo.
        model.query = ""
        answerHeight = 120
        relayout()
        SearchAsk.shared.ask(q) { text, done in
            let bar = SearchBar.shared
            guard bar.isOpen, bar.model.answer?.question == q else { return }
            var answer = bar.model.answer ?? SearchAnswer(question: q)
            if let text { answer.text = text } else { answer.failed = true }
            answer.done = done
            bar.model.answer = answer
        }
    }

    /// «Chiedi a Siri» (⌥↩ sulla riga Chiedi): la barra si chiude e si apre quella di macOS con la domanda già scritta.
    private func askSiri(_ question: String) {
        close(animated: false)
        SearchLaunch.openSiri(with: question)
    }

    // MARK: Ascolto

    private func installMonitors() {
        removeMonitors()
        if let m = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { event in
            SearchBar.shared.handleKey(event) ? nil : event
        }) { monitors.append(m) }
        if let m = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged, handler: { event in
            SearchBar.shared.modifiersChanged(event.modifierFlags)
            return event
        }) { monitors.append(m) }
        if let m = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .scrollWheel], handler: { event in
            SearchBar.shared.pointerMoved(hover: event.type == .mouseMoved)
            return event
        }) { monitors.append(m) }
        if let m = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved, handler: { _ in
            MainActor.assumeIsolated { SearchBar.shared.pointerMoved(hover: true) }
        }) { monitors.append(m) }
        // Un clic in un'altra app, sulla scrivania, sul Dock o nella barra dei menu chiude.
        if let m = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown], handler: { _ in
            MainActor.assumeIsolated { SearchBar.shared.close(animated: true, why: "clic fuori") }
        }) { monitors.append(m) }
        // E un clic in un'altra finestra di Charland (l'isola, i vassoi del Dock, gli appunti).
        if let m = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown], handler: { event in
            if event.window !== SearchBar.shared.panel { SearchBar.shared.close(animated: true, why: "clic in Charland") }
            return event
        }) { monitors.append(m) }
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.screensDidSleepNotification, NSWorkspace.sessionDidResignActiveNotification,
                     NSWorkspace.activeSpaceDidChangeNotification] {
            let why = name.rawValue
            observers.append(workspace.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { SearchBar.shared.close(animated: false, why: why) }
            })
        }
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                                                object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { SearchBar.shared.close(animated: false, why: "schermi cambiati") }
        })
        modifiersChanged(NSEvent.modifierFlags)
        pointerMoved(hover: false)
    }

    private func removeMonitors() {
        for m in monitors { NSEvent.removeMonitor(m) }
        monitors.removeAll()
        let workspace = NSWorkspace.shared.notificationCenter
        for o in observers {
            workspace.removeObserver(o)
            NotificationCenter.default.removeObserver(o)
        }
        observers.removeAll()
    }

    private func modifiersChanged(_ flags: NSEvent.ModifierFlags) {
        let command = flags.contains(.command), option = flags.contains(.option)
        if model.command != command { model.command = command }
        if model.option != option { model.option = option }
    }

    /// Il puntatore: sopra la barra prende i clic, fuori li lascia passare (la finestra copre anche la barra dei menu
    /// attorno al notch). E sceglie la riga sotto di
    /// lui, ma solo quando si muove davvero: se a muoversi è l'elenco la riga che passa sotto il puntatore fermo non ruba
    /// la selezione.
    private func pointerMoved(hover: Bool) {
        guard isOpen, let panel else { return }
        let mouse = NSEvent.mouseLocation
        let origin = panel.frame.origin, h = panel.frame.height
        let point = CGPoint(x: mouse.x - origin.x, y: origin.y + h - mouse.y)
        let inside = shape.outline.boundingRect.insetBy(dx: -4, dy: -4).contains(point) && shape.visible.contains(point)
        if panel.ignoresMouseEvents == inside { panel.ignoresMouseEvents = !inside }
        guard hover, inside, shape.listReveal > 0.5, model.answer == nil,
              let id = rowFrames.first(where: { $0.value.contains(point) })?.key, id != model.selected else { return }
        model.selected = id
        userMoved = true
    }

    func rowFrame(_ id: String, _ rect: CGRect?) { rowFrames[id] = rect }

    /// Per le prove (`stato`): dov'è il puntatore rispetto alla barra e se la finestra prende i clic.
    var pointerReport: String {
        guard let panel else { return "niente finestra" }
        let mouse = NSEvent.mouseLocation
        let point = CGPoint(x: mouse.x - panel.frame.minX, y: panel.frame.maxY - mouse.y)
        let inside = shape.outline.boundingRect.insetBy(dx: -4, dy: -4).contains(point) && shape.visible.contains(point)
        let row = rowFrames.first { $0.value.contains(point) }?.key ?? "nessuna"
        return "\(point) dentro=\(inside) prende-clic=\(!panel.ignoresMouseEvents) riga=\(row)"
    }

    // MARK: Tastiera

    private func handleKey(_ event: NSEvent) -> Bool {
        guard isOpen else {
            // Si sta richiudendo ma ha ancora la tastiera: la lettera si tiene e si ripassa all'app di prima.
            // Solo le lettere: Invio, Esc, frecce e tasti ripetuti non si ripassano (un Invio tenuto premuto avrebbe
            // confermato qualcosa nell'app appena aperta).
            let control: Set<UInt16> = [36, 76, 53, 48, 51, 117, 123, 124, 125, 126]
            if panel?.isVisible == true, panel?.isKeyWindow == true {
                if !event.isARepeat, !control.contains(event.keyCode),
                   event.modifierFlags.intersection([.command, .control]).isEmpty, let copy = event.cgEvent?.copy() {
                    lateKeys.append(copy)
                }
                return true
            }
            return false
        }
        // Mentre un metodo di input compone (giapponese, cinese, gli accenti tenuti premuti) Invio, frecce ed Esc sono suoi.
        if let editor = panel?.firstResponder as? NSTextView, editor.hasMarkedText() { return false }
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        let away = 125       // giù: il risultato dopo (l'elenco scende dal campo)
        let back = 126
        switch Int(event.keyCode) {
        case 53:
            if let answer = model.answer {
                // Indietro ai risultati della domanda (o di quello che hai cominciato a scrivere dopo).
                SearchAsk.shared.cancel()
                model.answer = nil
                if model.query.isEmpty { model.query = answer.question } else { queryChanged() }
            } else if !model.query.isEmpty {
                model.query = ""
            } else {
                close(animated: true)
            }
            return true
        case 36, 76:
            // Invio tenuto premuto non ripete l'azione (copiare di nuovo, rifare la domanda, aprire due volte).
            if event.isARepeat { return true }
            if let answer = model.answer {
                // Invio con la risposta aperta: una domanda nuova nella stessa conversazione. A campo vuoto, dopo un
                // errore, riprova la stessa (lo promette il messaggio d'errore: il campo ora si svuota dopo ogni domanda).
                if !model.query.trimmingCharacters(in: .whitespaces).isEmpty {
                    ask(model.query)
                } else if answer.failed {
                    ask(answer.question)
                }
                return true
            }
            if let id = model.selected ?? (model.query.isEmpty ? nil : model.results.first?.id) {
                choose(id, flags: flags)
            }
            return true
        case away:
            move(flags.contains(.command) ? .max : 1)
            return true
        case back:
            move(flags.contains(.command) ? .min : -1)
            return true
        case 48:
            move(flags.contains(.shift) ? -1 : 1)
            return true
        default:
            break
        }
        if flags == .control {
            if event.charactersIgnoringModifiers == "n" { move(1); return true }
            if event.charactersIgnoringModifiers == "p" { move(-1); return true }
        }
        // Con una tastiera non latina (russa, greca) il carattere è «й», ma il menu usa lo stesso il tasto della Q: si
        // guarda il tasto. Con le latine il carattere (su Dvorak la Q sta altrove).
        let latin = event.charactersIgnoringModifiers.map { $0.allSatisfy(\.isASCII) } ?? false
        let byKey: [UInt16: String] = [12: "q", 4: "h", 46: "m", 13: "w"]
        let menuKey = latin ? event.charactersIgnoringModifiers?.lowercased() : byKey[event.keyCode]
        if flags.contains(.command), let key = menuKey, ["q", "h", "m", "w"].contains(key) {
            // La barra ha la tastiera ma l'app davanti resta l'altra: ⌘Q chiudeva Charland (isola e dettatura comprese),
            // ⌘H la nascondeva. ⌘W chiude la barra; ⌘Q, ⌘H e ⌘M non fanno niente, come in Spotlight.
            if key == "w" { close(animated: true, why: "⌘W") }
            return true
        }
        if flags == .command {
            // ⌘1…⌘9: la riga in quella posizione, contando dal campo.
            let digits: [Int: Int] = [18: 0, 19: 1, 20: 2, 21: 3, 23: 4, 22: 5, 26: 6, 28: 7, 25: 8]
            if let n = digits[Int(event.keyCode)], model.answer == nil {
                if n < model.results.count { choose(model.results[n].id) }
                return true
            }
            if event.charactersIgnoringModifiers == "," {
                close(animated: false)
                AppServices.shared.showSettings(section: .search)
                return true
            }
            // ⌘C senza testo scelto nel campo, con la risposta aperta: copia la risposta.
            if event.charactersIgnoringModifiers == "c", let answer = model.answer, !answer.text.isEmpty,
               let editor = panel?.firstResponder as? NSTextView, editor.selectedRange().length == 0 {
                copyAnswer()
                return true
            }
        }
        return false
    }

    func copyAnswer() {
        guard let text = model.answer?.text, !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        model.copiedID = "answer"
        Haptics.tick()
    }

    private func move(_ delta: Int) {
        let items = model.results
        guard !items.isEmpty, model.answer == nil else { return }
        let current = items.firstIndex { $0.id == model.selected }
        let next: Int
        switch delta {
        case Int.max: next = items.count - 1
        case Int.min: next = 0
        default:
            if let current {
                next = min(items.count - 1, max(0, current + delta))
            } else {
                next = delta > 0 ? 0 : items.count - 1
            }
        }
        guard items[next].id != model.selected else { return }
        model.selected = items[next].id
        model.scrollTarget += 1
        userMoved = true
    }

    // MARK: Fotogrammi

    private func run() {
        guard !(clockRunning && clock.isRunning), let layout else { return }
        lastTimestamp = 0
        let screen = NSScreen.screens.first { $0.frame.intersects(layout.window) }
        clock.start(on: screen)
        // Senza schermi (un attimo durante un cambio di monitor) l'orologio non parte: non va segnato acceso, se no la
        // chiusura animata non finirebbe mai.
        clockRunning = clock.isRunning
        if !clockRunning, !isOpen { finish() }
    }

    private func frame(_ link: CADisplayLink) {
        let now = link.targetTimestamp
        if Self.trace, lastTimestamp != 0, now - lastTimestamp > link.duration * 1.5 {
            print(String(format: "[ricerca] fotogramma lungo %.0f ms p=%.2f", (now - lastTimestamp) * 1000, presence.value)); fflush(stdout)
        }
        let dt = (lastTimestamp == 0 ? link.duration : min(now - lastTimestamp, link.duration * 1.25)) / Self.slowMotion
        lastTimestamp = now
        var moving = presence.step(dt: dt)
        growth.target = reduceMotion ? 1 : SearchMetrics.grow(presence.value)
        if reduceMotion, presence.target == 1 { growth.snap(to: 1) }
        moving = growth.step(dt: dt) || moving
        // L'elenco cresce solo a barra quasi ferma: prima la goccia, poi le righe.
        if isOpen, presence.value > 0.8 || reduceMotion, listHeight.target != Double(shape.listHeight) {
            listHeight.target = Double(shape.listHeight)
        }
        moving = listHeight.step(dt: dt) || moving
        moving = tremble.step(dt: dt) || moving
        moving = descent.step(dt: dt) || moving
        publish()
        // La forma è cambiata sotto il puntatore fermo (la barra che si apre, l'elenco che si allunga, l'isola che la
        // sposta): si ricontrolla se la finestra deve prendere i clic. Prima lo si guardava solo quando il puntatore si
        // muoveva, e un clic sulla barra appena aperta finiva all'app sotto e la chiudeva.
        if isOpen { pointerMoved(hover: false) }
        if !isOpen, presence.target == 0, outOfSight || (reduceMotion && presence.value <= 0.001) {
            finish()
            return
        }
        guard !moving else { return }
        clock.stop()
        clockRunning = false
        if presence.value == 0, !isOpen { finish() }
    }

    private func publish() {
        let started = CACurrentMediaTime()
        defer {
            let spent = (CACurrentMediaTime() - started) * 1000
            if Self.trace, spent > 2 { note(String(format: "forma in %.2f ms", spent)) }
        }
        guard let layout else { return }
        let m = SearchMetrics.self
        let p = presence.value
        // Sotto l'isola aperta, se lo è: campo, elenco e bordo da cui nasce la goccia scendono insieme.
        let down = CGFloat(descent.value)
        let final = layout.field.offsetBy(dx: 0, dy: down)
        let wall = layout.wall + down
        shape.field = final
        shape.visible = CGRect(x: 0, y: wall, width: layout.window.width, height: max(0, layout.window.height - wall))
        let list = CGFloat(max(0, listHeight.value))
        // Le righe entrano mentre l'elenco cresce la prima volta, ed escono con lui alla chiusura. Una volta dentro restano
        // piene: prima, a ogni elenco che si allungava mentre scrivi (3 recenti → 8 righe alla prima lettera), tutto
        // l'elenco scendeva quasi a zero e tornava, un lampo a ogni lettera.
        let growing = m.smooth(0.25, 1, Double(list / max(1, shape.listHeight)))
        if !isOpen || shape.listHeight < 1 { listSettled = false } else if growing >= 0.999 { listSettled = true }
        shape.listReveal = listSettled ? 1 : growing
        shape.list = CGRect(x: final.minX, y: final.maxY, width: final.width, height: shape.listHeight)

        /// La barra con l'elenco sotto, alto quanto è arrivato.
        func extend(_ r: CGRect) -> CGRect { CGRect(x: r.minX, y: r.minY, width: r.width, height: r.height + list) }

        if reduceMotion {
            // Al suo posto, in dissolvenza: niente goccia, niente collo.
            var path = Path()
            path.addRoundedRect(in: extend(final), cornerSize: CGSize(width: m.radius, height: m.radius), style: .circular)
            shape.outline = path
            shape.calm = true
            shape.calmPresence = p
            shape.inkTop = 0
            shape.inkBottom = 0
            shape.reveal = m.smooth(0.2, 1, p)
            outOfSight = p <= 0.001
            return
        }
        shape.calm = false
        shape.calmPresence = 1

        // La goccia: tonda all'uscita dal notch, poi si apre fino al campo. Come un liquido conserva il volume: più larga
        // quando è in ritardo sulla sua crescita, più stretta quando la supera.
        let k = max(0, (growth.value - 0.12) / 0.88)
        let lag = m.grow(p) / max(0.12, growth.value)
        let volume = CGFloat(min(1.1, max(0.9, pow(lag, 0.4))))
        let t = CGFloat(max(-0.6, min(0.6, tremble.value)))
        let width = max(m.dropSize, m.lerp(m.dropSize, final.width, k)) * volume * (1 + 0.012 * t)
        let height = max(m.dropSize, m.lerp(m.dropSize, final.height, pow(k, 0.8))) * (1 - 0.02 * t)
        // Il centro parte dal bordo del notch (mezza goccia ancora dentro) e scende al centro del campo.
        let travel = m.smooth(0, 1, min(1, k * 1.15))
        var center = CGPoint(x: m.lerp(layout.anchor.x, final.midX, travel), y: m.lerp(wall + 4, final.midY, travel))
        // Rientrando, quando ormai è una gocciolina, sale tutta dentro il notch.
        let closing = presence.target == 0
        if closing { center.y -= CGFloat(1 - m.smooth(0, 0.3, k)) * (height / 2 + 6) }
        var drop = CGRect(x: center.x - width / 2, y: center.y - height / 2, width: width, height: height)
        // Mai fuori dalla finestra di lato (un notch vicino al bordo di uno schermo stretto).
        if drop.minX < 2 { drop.origin.x = 2 }
        if drop.maxX > layout.window.width - 2, drop.width < layout.window.width - 4 { drop.origin.x = layout.window.width - 2 - drop.width }
        let body = extend(drop)
        let radius = Double(min(m.radius, body.width / 2, body.height / 2))

        // Il rigonfiamento del bordo del notch: spinge fuori la goccia e regge il collo. Mai più largo del notch.
        let push = CGFloat(m.push(p))
        let blend = m.blend(p)
        let bumpWidth = min(40, max(20, layout.notchWidth - 24))
        let bump = CGRect(x: layout.anchor.x - bumpWidth / 2, y: wall + push - 28, width: bumpWidth, height: 28)
        let gap = drop.minY - wall
        let attached = blend > 2 * Double(gap - push)
        if wasAttached, !attached, presence.target == 1 { tremble.velocity = 6 }
        wasAttached = attached
        // Nasce nera come il notch e diventa vetro mentre si apre: prima in basso, poi in alto, dove resta attaccata al nero
        // più a lungo. Si legge la crescita, non il tempo: rientrando torna nera allo stesso modo.
        shape.inkBottom = 1 - m.smooth(0.3, 0.85, min(1, k))
        shape.inkTop = 1 - m.smooth(0.5, 1, min(1, k))
        outOfSight = closing && drop.maxY <= wall + 0.5

        // A goccia ferma il contorno è un rettangolo arrotondato: si traccia il campo solo mentre c'è un collo.
        var path = Path()
        if blend < 0.01, push <= -1.9 {
            path.addRoundedRect(in: body, cornerSize: CGSize(width: radius, height: radius), style: .circular)
        } else {
            let field = SearchField(body: body, bodyRadius: radius, bump: bump, blend: blend)
            let reach = CGFloat(blend * 0.25 + 3)
            let union = body.union(bump).insetBy(dx: -reach, dy: -reach)
            for loop in tracer.trace(field, minX: (Double(union.minX) * 2).rounded(.down) / 2, minY: (Double(union.minY) * 2).rounded(.down) / 2,
                                     maxX: (Double(union.maxX) * 2).rounded(.up) / 2, maxY: (Double(union.maxY) * 2).rounded(.up) / 2) {
                guard let first = loop.first else { continue }
                path.move(to: CGPoint(x: first.x, y: first.y))
                for point in loop.dropFirst() { path.addLine(to: CGPoint(x: point.x, y: point.y)) }
                path.closeSubpath()
            }
        }
        shape.outline = path
        // Il testo entra quando la goccia è quasi larga quanto la barra: prima si leggeva un pezzo di «Cerca o chiedi»
        // tagliato dal bordo della goccia che si allargava.
        shape.reveal = m.reveal(p) * m.smooth(0.72, 0.96, min(1, k))
    }

    private func note(_ what: String) {
        guard Self.trace else { return }
        print(String(format: "[ricerca] %.3f %@", CACurrentMediaTime(), what)); fflush(stdout)
    }
}

/// Aprire quello che hai scelto davanti a tutto: Charland non è l'app attiva (la barra non la attiva), e da macOS 14
/// un'app non attiva apre le altre dietro le finestre di prima. Come `DockLaunch`: Charland si attiva un istante, cede il
/// posto all'app che apre e la apre con `activates`.
@MainActor
enum SearchLaunch {
    static func open(document url: URL) {
        let app = NSWorkspace.shared.urlForApplication(toOpen: url)
        yield(to: app)
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.open([url], withApplicationAt: app ?? URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app"),
                                configuration: configuration) { _, _ in }
    }

    static func open(web url: URL) {
        open(web: url, in: nil)
    }

    /// Una pagina nel browser chiesto («apri Pinterest su Safari») o, senza, in quello di serie.
    static func open(web url: URL, in browser: URL?) {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        if let browser {
            yield(to: browser)
            NSWorkspace.shared.open([url], withApplicationAt: browser, configuration: configuration) { _, _ in }
        } else {
            yield(to: NSWorkspace.shared.urlForApplication(toOpen: url))
            NSWorkspace.shared.open(url, configuration: configuration) { _, _ in }
        }
    }

    /// ⌘↩: il Finder con l'elemento scelto.
    static func reveal(_ url: URL) {
        yield(to: URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app"))
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private static func yield(to app: URL?) {
        NSApp.activate()
        if let bundle = app.flatMap({ Bundle(url: $0)?.bundleIdentifier }) {
            NSApp.yieldActivation(toApplicationWithBundleIdentifier: bundle)
        }
    }

    /// La ricerca di macOS, con la domanda scritta dentro appena compare la sua bolla. Se la bolla non compare (Siri
    /// spenta, la scorciatoia cambiata) non si scrive niente: le lettere finirebbero nell'app davanti.
    static func openSiri(with question: String) {
        SearchHotkey.openSystemSearch()
        let text = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        Task { @MainActor in
            guard await waitForSiri() != nil else { return }
            try? await Task.sleep(for: .milliseconds(90))
            replaceText(with: text)
        }
    }

    /// Le app dell'iPhone (Duplicazione iPhone): macOS le apre solo dalle app di Apple (Duplicazione iPhone accetta l'ordine
    /// «apri questa app» soltanto con l'autorizzazione privata `com.apple.private.screencontinuity.app-launch`; aprire il
    /// segnaposto dà «manca l'eseguibile»). Si passa dalla ricerca di macOS: si apre, ci si scrive il nome e, quando sul
    /// Mac non c'è un'app con lo stesso nome (che verrebbe prima), si conferma da soli appena compaiono i risultati.
    /// Senza la bolla si apre Duplicazione iPhone.
    static func openIPhoneApp(named name: String, confirm: Bool) {
        SearchHotkey.openSystemSearch()
        Task { @MainActor in
            guard await waitForSiri() != nil else {
                DockLaunch.open(bundle: "com.apple.ScreenContinuity")
                return
            }
            try? await Task.sleep(for: .milliseconds(90))
            replaceText(with: name)
            guard confirm else { return }
            // Il tempo di aggiornare i risultati (la ricerca di macOS mette l'app dell'iPhone in cima: «Nicegram — From
            // iPhone»), poi Invio, solo se la bolla è ancora lì.
            try? await Task.sleep(for: .milliseconds(550))
            guard siriBubble() != nil else { return }
            press(36)
        }
    }

    /// La bolla tiene il testo della ricerca di prima: si seleziona tutto e si scrive sopra.
    private static func replaceText(with text: String) {
        press(KeyCombo.keyCode(for: "a") ?? 0, command: true)
        type(text)
    }

    /// Aspetta la bolla di Siri (al massimo un secondo e mezzo) e ne dà il riquadro.
    private static func waitForSiri() async -> CGRect? {
        for _ in 0..<30 {
            try? await Task.sleep(for: .milliseconds(50))
            if let bubble = siriBubble() { return bubble }
        }
        return nil
    }

    /// La bolla di Siri: una finestra dell'app «Siri AI», al livello dei menu, visibile e larga come una bolla (aprendosi
    /// passa un istante da una finestra a tutto schermo, che non conta). Quando non si usa resta in elenco ma trasparente.
    private static func siriBubble() -> CGRect? {
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
        for window in list {
            let owner = window[kCGWindowOwnerName as String] as? String ?? ""
            let alpha = window[kCGWindowAlpha as String] as? Double ?? 0
            guard owner.localizedCaseInsensitiveContains("siri"), alpha > 0.01, (window[kCGWindowLayer as String] as? Int ?? 0) > 0,
                  let bounds = window[kCGWindowBounds as String] as? [String: Any],
                  let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary), rect.width > 300, rect.width < 900,
                  alpha > 0.5 else { continue }
            return rect
        }
        return nil
    }

    /// Scrive il testo nell'app davanti con tasti finti che portano i caratteri veri (niente appunti toccati). A pezzi
    /// che non spezzano mai un carattere (un'emoji sono due unità), e senza modificatori: ⌥ ancora tenuto dopo ⌥↩ li
    /// avrebbe cambiati.
    private static func type(_ text: String) {
        let source = CGEventSource(stateID: .hidSystemState)
        var chunk: [UniChar] = []
        func send() {
            guard !chunk.isEmpty else { return }
            for down in [true, false] {
                guard let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: down) else { continue }
                event.flags = []
                event.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: chunk)
                event.setIntegerValueField(.eventSourceUserData, value: SearchHotkey.ownTag)
                event.post(tap: .cghidEventTap)
            }
            chunk = []
        }
        for character in text {
            let units = Array(String(character).utf16)
            if chunk.count + units.count > 16 { send() }
            chunk += units
        }
        send()
    }

    /// Un tasto (Invio per confermare, ⌘A per selezionare tutto nella bolla di Siri).
    private static func press(_ key: CGKeyCode, command: Bool = false) {
        let source = CGEventSource(stateID: .hidSystemState)
        for down in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: down) else { continue }
            event.flags = command ? CGEventFlags(rawValue: CGEventFlags.maskCommand.rawValue | 0x8) : []
            event.setIntegerValueField(.eventSourceUserData, value: SearchHotkey.ownTag)
            event.post(tap: .cghidEventTap)
        }
    }
}

/// La finestra della barra: senza bordo, sopra tutto come l'isola, prende la tastiera senza attivare Charland (come gli
/// appunti, il nome del timer e Spotlight). Il vetro trasparente vero anche qui (vedi `IslandPanel`).
final class SearchPanel: NSPanel {
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
