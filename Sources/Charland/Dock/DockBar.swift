import AppKit
import SwiftUI
import CharlandCore

/// I widget di Charland accanto al Dock (carpa, 17 novembre 2026: «voglio che andiamo a customizzare anche il Dock»,
/// «con questo fantastico Liquid Glass e animazioni ultra fluide»; il riferimento è docktor).
///
/// Ogni modulo è un vassoio di vetro a capsula, alto come il Dock, staccato di qualche punto dal suo fianco o dal
/// vassoio vicino; i moduli stanno a sinistra o a destra del Dock, nell'ordine scelto, e salgono e scendono con lui
/// (il riquadro del Dock si legge dall'Accessibilità a ogni fotogramma mentre si muove: `DockTracker`). Col puntatore
/// sopra un vassoio, da lui si stacca una goccia che sale e si apre nel suo cassetto, con lo stesso campo liquido degli
/// slider e dell'isola; passando a un altro vassoio dello stesso lato il cassetto scivola sopra di lui.
struct DockTarget: Equatable {
    var side: DockSide
    var module: DockModuleID
    var cell: String?
}

/// Un vassoio come si disegna in questo fotogramma.
struct DockRowState: Equatable, Identifiable {
    var id: DockModuleID
    var layout: DockRowLayout
    /// Il bordo sinistro rispetto al bordo del gruppo vicino al Dock (a sinistra del Dock è negativo).
    var x: CGFloat
    /// La larghezza in questo fotogramma: cresce e cala quando il modulo si accende o si spegne.
    var width: CGFloat
    var presence: Double
    /// Premuto: 1 mentre il clic è giù. Come il vetro interattivo di Apple il vassoio si gonfia appena sotto il dito e
    /// lasciato torna con un piccolo rimbalzo (la molla passa un poco sotto lo zero).
    var press: Double = 0

    /// Quanto cresce premuto: abbastanza da sentirlo sotto il dito, non tanto da spostare il resto.
    static let pressGrow = 0.08

    /// Mentre compare o sparisce il vassoio è anche più basso: nasce dal vicino come una gocciolina tonda e cresce in
    /// tutte e due le direzioni, e sparendo torna gocciolina prima di essere risucchiato. Solo in larghezza restava un
    /// bastoncino verticale staccato negli ultimi fotogrammi.
    var heightScale: CGFloat { CGFloat(0.35 + 0.65 * DockBarMetrics.smooth(0, 0.7, presence)) }

    /// Quanto è alto adesso: mai più che largo, così negli ultimi istanti è un puntino tondo che rientra nel vicino.
    /// Più alto che largo sporgeva dal capo tondo del vicino come un taglio piatto con due orecchiette.
    var plateHeight: CGFloat { min(layout.height * heightScale, max(0, width)) }
}

@MainActor @Observable
final class DockSideModel {
    let side: DockSide
    var rows: [DockRowState] = []
    /// Di quanto è spostato tutto il disegno rispetto alla sua tela: è l'unica cosa che cambia mentre i vassoi salgono e
    /// scendono col Dock, e uno spostamento non costa niente (la forma del vetro resta la stessa).
    var shift: CGSize = .zero
    var outline = Path()
    /// Il cassetto, rispetto al bordo del gruppo vicino al Dock (sta sopra: y negativa).
    var drawer: CGRect = .zero
    /// La goccia (o il cassetto, a goccia arrivata) come si disegna adesso: serve al filo di luce, che si accende in alto.
    var drop: CGRect = .zero
    var expansion = 0.0
    var lift = 0.0
    /// Riduci movimento: il cassetto compare in dissolvenza al suo posto invece di salire come una goccia.
    var calm = false
    /// Il cassetto è un vetro suo, al suo posto, che compare e basta (di serie, o con Riduci movimento): niente goccia
    /// che sale dal vassoio. I vassoi restano liquidi come sono.
    var plain = true
    var hovered: DockTarget?
    var focus: DockModuleID?
    var focusCell: String?
    var now = Date()
    var window = CGSize(width: 700, height: DockBarMetrics.windowHeight)

    init(side: DockSide) { self.side = side }

    /// Dove sta, nella tela, il bordo del gruppo vicino al Dock (in alto, a filo dei vassoi).
    var canvas: CGPoint {
        CGPoint(x: side == .right ? DockBarMetrics.margin : window.width - DockBarMetrics.margin, y: DockBarMetrics.canvasY)
    }
}

enum DockBarMetrics {
    /// Aria fra il Dock e il primo vassoio, fra un vassoio e l'altro, e fra il vassoio e il cassetto.
    static let gap: CGFloat = 8
    static let drawerGap: CGFloat = 10
    /// Posto accanto al gruppo nella finestra: il cassetto, centrato sul suo vassoio, può sporgere fin qui.
    static let margin: CGFloat = 170
    static let canvasY: CGFloat = 400
    static let windowHeight: CGFloat = 480
    static let drawerCorner: CGFloat = 26

    static func lerp(_ a: CGFloat, _ b: CGFloat, _ t: Double) -> CGFloat { a + (b - a) * CGFloat(t) }

    static func smooth(_ e0: Double, _ e1: Double, _ x: Double) -> Double {
        let t = min(1, max(0, (x - e0) / (e1 - e0)))
        return t * t * (3 - 2 * t)
    }

    /// Il raggio dell'unione fra vassoio e goccia: zero a riposo (il vassoio è solo un vassoio), pieno mentre la
    /// goccia sale, poi cala e il collo si spezza quando la goccia è ancora tonda, prima che si apra nel cassetto.
    static func blend(_ e: Double) -> Double {
        30 * smooth(0, 0.18, e) * (1 - smooth(0.44, 0.72, e))
    }

    /// I contenuti del cassetto entrano a forma quasi fatta e se ne vanno per primi.
    /// Il contenuto è ritagliato dal vetro, quindi può nascere dentro la goccia mentre si apre, sfocato, invece di
    /// comparire a forma già fatta: come il vetro di Apple quando un pulsante diventa un menu.
    /// Parte a metà apertura: con 0,6 il testo arrivava quasi mezzo secondo dopo il puntatore, i menu di vetro di
    /// Apple lo mostrano entro un quarto di secondo.
    static func contentOpacity(_ e: Double) -> Double { smooth(0.5, 1, e) }
}

/// Il campo di un lato: i vassoi (capsule, distanze vere) e la goccia che diventa cassetto, unita con un minimo morbido
/// solo al vassoio da cui nasce. Con gli altri vassoi resta un minimo netto: a 8 punti di distanza il ponte liquido
/// li avrebbe incollati alla goccia.
struct DockBarField: ScalarField {
    let plates: [CGRect]
    /// Per ogni vassoio, il raggio dell'unione morbida col vassoio prima di lui (verso il Dock): un vassoio che sta
    /// comparendo esce dal vicino come una goccia che si stacca, e il collo si spezza prima che sia grande del tutto.
    /// Zero per i vassoi già al loro posto.
    var buds: [Double] = []
    let focus: Int?
    let drop: CGRect
    let dropRadius: Double
    let blend: Double

    /// Il minimo morbido di due distanze vere: resta una distanza (non cresce mai più in fretta della strada).
    static func smoothMin(_ a: Double, _ b: Double, _ k: Double) -> Double {
        guard k > 0.0001 else { return min(a, b) }
        let h = max(k - abs(a - b), 0) / k
        return min(a, b) - h * h * k * 0.25
    }

    static func capsule(_ r: CGRect, _ x: Double, _ y: Double, radius: Double? = nil) -> Double {
        let half = Double(min(r.width, r.height)) / 2
        return SideSliderField.roundedBox(x - Double(r.midX), y - Double(r.midY), Double(r.width) / 2, Double(r.height) / 2,
                                          min(radius ?? half, half))
    }

    func value(x: Double, y: Double) -> Double {
        var trays = Double.greatestFiniteMagnitude
        var focused = Double.greatestFiniteMagnitude
        for (index, plate) in plates.enumerated() {
            let d = Self.capsule(plate, x, y)
            if index == focus { focused = d }
            let bud = index < buds.count ? buds[index] : 0
            trays = index > 0 && bud > 0.0001 ? Self.smoothMin(trays, d, bud) : min(trays, d)
        }
        guard drop.width > 0.5, drop.height > 0.5 else { return trays }
        let b = Self.capsule(drop, x, y, radius: dropRadius)
        let liquid = focused < .greatestFiniteMagnitude ? Self.smoothMin(focused, b, blend) : b
        return min(trays, liquid)
    }

    var distortion: Double? { 0 }
}

@MainActor
final class DockBar {
    static let shared = DockBar()

    /// Un lato del Dock: la sua finestra, il suo disegno, le sue molle.
    @MainActor
    final class Side {
        let side: DockSide
        let model: DockSideModel
        var panel: IslandPanel?
        /// Lo Space dell'isola in cui è entrata la finestra (`IslandHub.spaceToken`): se cambia, la finestra si rifà.
        var panelSpace = 0
        var presence: [DockModuleID: Animated] = [:]
        var press: [DockModuleID: Animated] = [:]
        var expansion = Animated(0, spring: DockBar.openSpring, restDistance: 0.001, restSpeed: 0.01)
        /// L'altezza del cassetto insegue l'apertura con una molla sua, a gelatina: si allunga, non cambia scala.
        var tall = Animated(0, spring: DockBar.tallSpring, restDistance: 0.001, restSpeed: 0.01)
        var drawerHeight = Animated(220, spring: DockBar.heightSpring, restDistance: 0.05, restSpeed: 0.5)
        /// Il centro del cassetto, rispetto al bordo del gruppo: scivola quando passi a un altro vassoio.
        var drawerCenter = Animated(0, spring: Spring(response: 0.38, damping: 0.86), restDistance: 0.05, restSpeed: 0.5)
        var drawerOpen = false
        var anchorX: CGFloat?
        /// I vassoi e il cassetto nelle coordinate dello schermo di AppKit, per il puntatore.
        var plateRects: [DockModuleID: CGRect] = [:]
        var drawerRect: CGRect = .zero
        var shapeKey: [Double] = []
        /// I moduli accesi che non ci stanno (lo schermo finisce prima): non escono, e `retarget` non li rimette fuori.
        var overflow: Set<DockModuleID> = []
        /// Il cassetto si è appena aperto su un vassoio: il suo centro va messo lì subito, non fatto scivolare da dov'era.
        var needsCenterSnap = false
        /// Un tracciatore per lato: tiene i suoi quaderni fra un fotogramma e l'altro, e due lati che si muovono insieme
        /// (un cassetto si chiude di là mentre l'altro si apre di qua) con uno solo se li rubavano a vicenda.
        let tracer = ContourTracer()
        /// I moduli che si vedono o stanno uscendo, nell'ordine dal Dock verso fuori.
        var order: [DockModuleID] = []

        init(_ side: DockSide) {
            self.side = side
            model = DockSideModel(side: side)
        }
    }

    let modules: [DockModuleID: any DockModule] = [
        .usage: UsageModule(), .agenda: AgendaModule(), .system: SystemModule(), .dictation: DictationModule(),
    ]
    let sides: [DockSide: Side] = [.left: Side(.left), .right: Side(.right)]

    private let tracker = DockTracker.shared
    private var screen: NSScreen?
    private lazy var clock = FrameClock { [weak self] link in self?.frame(link) }
    private var clockRunning = false
    private var lastTimestamp: CFTimeInterval = 0

    /// `start` l'ha chiamata l'app; `active` vuol dire che è anche acceso nelle impostazioni, con almeno un modulo.
    private var started = false
    private var active = false
    private var activeModules: Set<DockModuleID> = []

    /// Tiene su i vassoi quando il Dock è nascosto: col puntatore sopra, col cassetto aperto, o se hai scelto che
    /// restino sempre visibili. Scendendo niente rimbalzo: scivolano sotto il bordo.
    private var hold = Animated(0, spring: Spring(response: 0.38, damping: 0.9), restDistance: 0.001, restSpeed: 0.01)
    private var opens: [String: Animated] = [:]
    /// La larghezza del testo accanto a ogni anello, a molla: quando il testo cambia («Detta» e «Ferma», 9% e 10%) il
    /// vassoio si allarga o si stringe morbido invece di scattare.
    private var labelWidths: [String: Animated] = [:]
    fileprivate static let openSpring = Spring(response: 0.42, damping: 0.82)
    fileprivate static let tallSpring = Spring(response: 0.36, damping: 0.7)
    fileprivate static let heightSpring = Spring(response: 0.36, damping: 0.84)
    /// Con Riduci movimento ogni molla diventa questa: breve e senza rimbalzo, il vetro cambia senza dondolare.
    private static let calmSpring = Spring(response: 0.26, damping: 1)
    /// Il cassetto semplice: compare e scompare in fretta, senza rimbalzo.
    private static let plainOpen = Spring(response: 0.24, damping: 1)
    private static let plainClose = Spring(response: 0.2, damping: 1)
    /// Il cassetto compare al suo posto, senza goccia: scelto in Impostazioni (di serie) o con Riduci movimento.
    private var plainDrawer: Bool { reduceMotion || !settings.liquidDrawer }
    private static let closeSpring = Spring(response: 0.4, damping: 0.94)
    private static let labelSpring = Spring(response: 0.38, damping: 0.76)
    private static let presenceSpring = Spring(response: 0.44, damping: 0.8)
    /// Giù svelta e piena, su con un rimbalzo: il vetro che cede e torna.
    private static let pressDown = Spring(response: 0.16, damping: 0.86)
    private static let pressUp = Spring(response: 0.42, damping: 0.5)

    /// Di quanto il Dock salito sta sopra il bordo dello schermo: si impara guardandolo, e si ricorda.
    private var shownGap: CGFloat = CGFloat(UserDefaults.standard.double(forKey: "dockShownGap"))
    private var lift = 0.0
    private var wasLifted = false
    /// I vassoi si vedono (anche solo un poco): i numeri del sistema si disegnano solo allora.
    private var shown = false
    private var trackedBottom: CGFloat = -1

    /// All'accensione vassoi e cassetti si disegnano una volta al loro posto, a finestre trasparenti: la prima salita
    /// vera trova vetro, anelli e testi già pronti. 2 = si sta scaldando, 1 = torna al suo posto vero, 0 = fatto.
    private var warming = 0
    private var warmUntil: CFTimeInterval = 0

    private var hovering = false
    private var hover: DockTarget?
    private var openTimer: Timer?
    private var closeTimer: Timer?
    private var tickTimer: Timer?
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var scrollMonitor: Any?
    private var lastPointerMove: CFTimeInterval = 0
    /// L'ultimo sguardo ai numeri dei moduli senza puntatore sopra (`tick`).
    private var lastGlance: CFTimeInterval = 0
    /// Mentre il puntatore è sui vassoi (o gira la prova) il sistema non deve raggruppare i timer dell'app per
    /// risparmiare: l'attesa prima di aprire il cassetto e quella prima di chiuderlo devono durare quanto scritto.
    private var activity: NSObjectProtocol?
    private var scrollSum: CGFloat = 0
    private var lastScroll: CFTimeInterval = 0
    private var screenObserver: NSObjectProtocol?
    private var motionObserver: NSObjectProtocol?
    /// Riduci movimento (Impostazioni di Sistema › Accessibilità › Schermo): niente gocce, niente scivolate né rimbalzi,
    /// il cassetto compare e scompare in dissolvenza al suo posto, come fa macOS con i suoi menu.
    private var reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    private func motion(_ spring: CharlandCore.Spring) -> CharlandCore.Spring { reduceMotion ? Self.calmSpring : spring }

    private static let trace = ProcessInfo.processInfo.environment["CHARLAND_DOCK"] != nil
    private static let slowMotion = max(1, Double(ProcessInfo.processInfo.environment["CHARLAND_LENTO"] ?? "") ?? 1)
    /// Di quanti fotogrammi anticipare la posizione del Dock (`CHARLAND_DOCK_ANTICIPO` per le prove).
    private static let leadFrames = Double(ProcessInfo.processInfo.environment["CHARLAND_DOCK_ANTICIPO"] ?? "") ?? 1
    /// Per le prove: i vassoi restano su anche col Dock nascosto, senza toccare la scelta salvata (`CHARLAND_DOCK_FISSO=1`).
    private static let forcePinned = ProcessInfo.processInfo.environment["CHARLAND_DOCK_FISSO"] != nil
    /// Per le prove: un giro fra i cassetti senza muovere il puntatore di chi usa il Mac (`CHARLAND_DOCK_GIRO=1`).
    private static let tourRequested = ProcessInfo.processInfo.environment["CHARLAND_DOCK_GIRO"] != nil
    /// `CHARLAND_DOCK_GIRO=<secondi>` aspetta tanto prima di cominciare (1 o niente: subito). Nell'app intera i primi
    /// secondi dopo l'avvio sono pieni di lavoro d'altri (isola, comandi degli agenti, modello della voce): per misurare
    /// il Dock a regime si parte dopo.
    private static let tourDelay = max(0, (Double(ProcessInfo.processInfo.environment["CHARLAND_DOCK_GIRO"] ?? "") ?? 0) - 1)
    private var touring = false
    /// Durante la prova: moduli nascosti per un momento (senza toccare le scelte salvate), per vedere la goccia che si
    /// stacca dal vicino quando ricompaiono.
    private var tourHidden: Set<DockModuleID> = []
    private var tourStarted = false
    private var pinned: Bool { settings.pinned || Self.forcePinned }
    /// Per le prove: il cassetto di un modulo resta aperto anche senza puntatore (`CHARLAND_DOCK_APERTO=agenda`).
    private static let forceOpen: DockModuleID? = ProcessInfo.processInfo.environment["CHARLAND_DOCK_APERTO"].map {
        DockModuleID(rawValue: $0) ?? .usage
    }

    private var settings: DockSettings { .shared }

    // MARK: Accensione

    func start() {
        // L'ultima volta Charland si è chiusa col Dock tenuto su da un cassetto: torna a scomparsa.
        DockHold.restoreAfterCrash()
        started = true
        apply()
        if Self.trace { Self.watchMainThread() }
    }

    /// Per le prove (`CHARLAND_DOCK=1`): un thread a parte bussa al thread principale ogni 20 ms e scrive quando la
    /// risposta tarda più di 50 ms. Così si vedono anche i blocchi a Dock fermo, quando non c'è nessun fotogramma da
    /// contare.
    private nonisolated static func watchMainThread() {
        let thread = Thread {
            while true {
                let sent = CACurrentMediaTime()
                let done = DispatchSemaphore(value: 0)
                DispatchQueue.main.async { done.signal() }
                done.wait()
                let late = CACurrentMediaTime() - sent
                if late > 0.05 {
                    print(String(format: "[dockbar] %.3f thread principale fermo %.0f ms", sent, late * 1000)); fflush(stdout)
                }
                usleep(20_000)
            }
        }
        thread.name = "charland.dock.guardia"
        thread.start()
    }

    func stop() {
        started = false
        apply()
    }

    /// Una scelta cambiata nelle impostazioni, o un elemento scelto nel Dock.
    func settingsChanged() {
        apply()
        guard active else { return }
        // «Tutto vetro» o il modo del cassetto possono essere cambiati: la forma si ridisegna.
        for side in sides.values {
            if side.model.plain != plainDrawer { side.model.plain = plainDrawer }
            side.shapeKey = []
        }
        retarget()
        run()
    }

    /// Numeri nuovi: le larghezze dei testi e l'altezza del cassetto possono cambiare.
    func dataChanged() {
        guard active else { return }
        retarget()
        run()
    }

    func module(_ id: DockModuleID) -> (any DockModule)? { modules[id] }

    private func apply() {
        let on = started && settings.enabled && DockModuleID.allCases.contains { settings.isOn($0) }
        // Ogni modulo raccoglie i suoi dati solo se è acceso: spento non gira niente.
        let wanted = on ? Set(DockModuleID.allCases.filter { settings.isOn($0) }) : []
        for id in DockModuleID.allCases where wanted.contains(id) != activeModules.contains(id) {
            modules[id]?.setActive(wanted.contains(id))
        }
        activeModules = wanted
        if on { UsageStore.shared.setAlerts(settings.isOn(.usage) && settings.alerts) }
        guard on != active else { return }
        active = on
        if on {
            tracker.start { [weak self] in self?.run() }
            watchPointer()
            screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                                                    object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    for side in self.sides.values { side.anchorX = nil }
                    self.tracker.kick()
                    self.run()
                }
            }
            motionObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.motionChanged() }
            }
            motionChanged()
            retarget()
            for side in sides.values {
                ensurePanel(side)
                // La finestra resta sempre davanti, col disegno sotto il bordo dello schermo: farla comparire a ogni
                // salita del Dock costava tre fotogrammi proprio mentre i vassoi dovevano partire con lui.
                side.panel?.alphaValue = 0
                side.panel?.orderFrontRegardless()
            }
            warming = 2
            warmUntil = CACurrentMediaTime() + 0.5
            run()
        } else {
            tracker.stop()
            stopWatchingPointer()
            if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
            screenObserver = nil
            if let motionObserver { NSWorkspace.shared.notificationCenter.removeObserver(motionObserver) }
            motionObserver = nil
            [openTimer, closeTimer, tickTimer].forEach { $0?.invalidate() }
            openTimer = nil; closeTimer = nil; tickTimer = nil
            clock.stop()
            clockRunning = false
            warming = 0
            hovering = false
            hover = nil
            hold.snap(to: 0)
            lift = 0
            wasLifted = false
            setShown(false)
            holdActivity(false)
            DockHold.hold(false)
            (modules[.system] as? SystemModule)?.drawerOpen(false)
            for side in sides.values {
                side.panel?.orderOut(nil)
                side.panel?.alphaValue = 1
                side.panel?.ignoresMouseEvents = true
                side.drawerOpen = false
                side.shapeKey = []
                side.expansion.snap(to: 0)
                side.tall.snap(to: 0)
                for id in side.presence.keys { side.presence[id]?.snap(to: 0) }
                side.anchorX = nil
                side.model.hovered = nil
                side.model.expansion = 0
                side.model.lift = 0
            }
        }
    }

    /// Le molle puntano allo stato di adesso: quali moduli ci sono e dove, quale testo è aperto, quanto è alto il
    /// cassetto.
    private func retarget() {
        let now = sides[.right]?.model.now ?? Date()
        for side in sides.values {
            let shown = settings.modules(on: side.side).filter { modules[$0]?.isEmpty == false && !tourHidden.contains($0) }
            for id in DockModuleID.allCases {
                let target: Double = shown.contains(id) && !side.overflow.contains(id) ? 1 : 0
                var spring = side.presence[id] ?? Animated(0, spring: Self.presenceSpring, restDistance: 0.001, restSpeed: 0.01)
                spring.spring = motion(Self.presenceSpring)
                spring.target = target
                side.presence[id] = spring
            }
            // Nell'ordine delle impostazioni: quelli accesi, e quelli che stanno ancora uscendo.
            side.order = settings.placements.map(\.id).filter { id in
                settings.side(of: id) == side.side && (shown.contains(id) || (side.presence[id]?.value ?? 0) > 0.001)
            }
            // Un modulo che non c'è più (o è passato all'altro lato) col cassetto aperto: il cassetto si chiude.
            if let focus = side.model.focus, !shown.contains(focus), side.drawerOpen || side.expansion.value > 0.05 {
                closeDrawer(side)
            }
            if let focus = side.model.focus, let module = modules[focus] {
                let height = Double(module.drawerHeight(focus: side.model.focusCell, now: now))
                if side.expansion.value < 0.05 { side.drawerHeight.snap(to: height) } else { side.drawerHeight.target = height }
            }
        }
        for module in modules.values {
            for cell in module.cells(height: 49, now: now) {
                let key = module.id.rawValue + "." + cell.id
                var spring = opens[key] ?? Animated(cell.open, spring: Self.labelSpring, restDistance: 0.001, restSpeed: 0.01)
                spring.target = cell.open
                opens[key] = spring
                var width = labelWidths[key] ?? Animated(Double(cell.label), spring: Self.labelSpring, restDistance: 0.05, restSpeed: 0.5)
                width.target = Double(cell.label)
                labelWidths[key] = width
            }
        }
        if hover != nil, !hoverStillValid() { leave() }
    }

    private func hoverStillValid() -> Bool {
        guard let hover else { return true }
        return settings.isOn(hover.module) && settings.side(of: hover.module) == hover.side
    }

    /// Riduci movimento acceso o spento: le molle che restano impostate (altezza del cassetto) cambiano subito, le altre
    /// alla prossima mossa; la forma si ridisegna.
    private func motionChanged() {
        reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        for side in sides.values {
            side.tall.spring = motion(Self.tallSpring)
            side.drawerHeight.spring = motion(Self.heightSpring)
            if side.model.calm != reduceMotion { side.model.calm = reduceMotion }
            if side.model.plain != plainDrawer { side.model.plain = plainDrawer }
            side.shapeKey = []
        }
        run()
    }

    /// Il clic va giù o su sopra un vassoio.
    func press(_ side: DockSide, _ module: DockModuleID, down: Bool) {
        guard let side = sides[side] else { return }
        var spring = side.press[module] ?? Animated(0, spring: Self.pressDown, restDistance: 0.001, restSpeed: 0.01)
        spring.spring = down ? Self.pressDown : motion(Self.pressUp)
        spring.target = down ? 1 : 0
        side.press[module] = spring
        run()
    }

    func tap(_ module: DockModuleID, cell: String?) {
        note("tocco \(module.rawValue) \(cell ?? "")")
        modules[module]?.tap(cell)
    }

    /// Chiude i cassetti aperti (dopo un'azione: aprire un'app, partecipare a una riunione, dettare).
    func closeDrawers() {
        openTimer?.invalidate()
        openTimer = nil
        closeTimer?.invalidate()
        closeTimer = nil
        for side in sides.values where side.drawerOpen || side.expansion.target != 0 { closeDrawer(side) }
        hovering = false
        hover = nil
        for side in sides.values {
            side.model.hovered = nil
            side.panel?.ignoresMouseEvents = true
        }
    }

    // MARK: Finestra

    private func ensurePanel(_ side: Side) {
        // Una finestra rimasta nello Space di prima (isola spenta e riaccesa) non compare
        // più: si rifà (22 novembre 2026, stesso difetto della goccia del timer).
        guard side.panel == nil || side.panelSpace != IslandHub.shared.spaceToken else { return }
        side.panel?.close()
        let size = side.model.window
        let panel = IslandPanel(frame: CGRect(origin: .zero, size: size))
        let host = FirstMouseHostingView(rootView: DockSideView(model: side.model, bar: self))
        host.sizingOptions = []
        host.frame = CGRect(origin: .zero, size: size)
        panel.contentView = host
        // Nello Space dell'isola, prima di comparire: i gesti fra scrivanie non la trascinano via.
        side.panelSpace = IslandHub.shared.adopt(panel)
        side.panel = panel
    }

    /// La finestra di un lato è larga quanto i suoi vassoi più il posto per il cassetto. Cambia solo quando i vassoi
    /// non ci stanno più (o avanzano di molto), e mai a ogni fotogramma.
    private func fitWindow(_ side: Side, groupWidth: CGFloat) {
        let needed = groupWidth + 2 * DockBarMetrics.margin + 40
        let current = side.model.window.width
        guard needed > current || (needed < current - 240 && lift == 0) else { return }
        let size = CGSize(width: max(needed, 2 * DockBarMetrics.margin + 200).rounded(), height: DockBarMetrics.windowHeight)
        side.model.window = size
        side.panel?.contentView?.frame = CGRect(origin: .zero, size: size)
        side.anchorX = nil
        side.shapeKey = []
    }

    // MARK: Puntatore

    /// Un ascolto globale, come per l'isola e gli slider: in una finestra che non prende la tastiera `onHover` arriva
    /// solo ogni tanto. Serve anche a svegliare la lettura del Dock quando il puntatore va verso il bordo.
    private func watchPointer() {
        guard globalMonitor == nil else { return }
        let mask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged]
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] _ in
            MainActor.assumeIsolated { self?.pointerMoved() }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            MainActor.assumeIsolated { self?.pointerMoved() }
            return event
        }
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            MainActor.assumeIsolated { self?.scrolled(event) ?? false } ? nil : event
        }
    }

    private func stopWatchingPointer() {
        [globalMonitor, localMonitor, scrollMonitor].forEach { if let monitor = $0 { NSEvent.removeMonitor(monitor) } }
        globalMonitor = nil
        localMonitor = nil
        scrollMonitor = nil
    }

    private func pointerMoved() {
        let mouse = NSEvent.mouseLocation
        lastPointerMove = CACurrentMediaTime()
        // La lettura del Dock si sveglia solo dove il Dock può muoversi: sul bordo basso (dove il puntatore lo fa
        // salire) e, quando è fuori, attorno a lui (ingrandimento, discesa). Altrove il puntatore non costa niente.
        if let screen {
            let top = sides.values.flatMap { $0.plateRects.values }.map(\.maxY).max() ?? screen.frame.minY
            let band: CGFloat = lift > 0 ? top - screen.frame.minY + 70 : 4
            if mouse.y <= screen.frame.minY + band, mouse.y >= screen.frame.minY - 1,
               mouse.x >= screen.frame.minX, mouse.x <= screen.frame.maxX { tracker.kick() }
        } else {
            tracker.kick()
        }
        // Durante il giro di prova il puntatore vero non comanda: chi usa il Mac può muoverlo senza rompere la prova.
        if touring { return }
        guard lift > 0.6, warming == 0, let screen else {
            if hovering { leave() }
            return
        }
        // Trascinando un file o una finestra verso il Dock i cassetti non si aprono al passaggio.
        if !hovering, NSEvent.pressedMouseButtons != 0 { return }
        // Su quale vassoio, e su quale anello: ogni vassoio risponde fino al bordo dello schermo sotto di lui.
        var target: DockTarget?
        for side in sides.values {
            for (id, rect) in side.plateRects where (side.presence[id]?.value ?? 0) > 0.6 {
                let zone = CGRect(x: rect.minX - DockBarMetrics.gap / 2, y: screen.frame.minY - 2,
                                  width: rect.width + DockBarMetrics.gap, height: rect.maxY - screen.frame.minY + 8)
                guard zone.contains(mouse) else { continue }
                let row = side.model.rows.first { $0.id == id }
                target = DockTarget(side: side.side, module: id, cell: row?.layout.cell(at: mouse.x - rect.minX))
            }
        }
        // Il cassetto aperto, con un po' d'aria e il ponte fra lui e il suo vassoio.
        var inDrawer: Side?
        for side in sides.values where side.drawerOpen || side.expansion.value > 0.3 {
            guard let focus = side.model.focus, let plate = side.plateRects[focus] else { continue }
            // Il ponte è solo lo spazio sopra il vassoio, fino al cassetto: più largo copriva le icone del Dock accanto.
            let bridge = CGRect(x: plate.minX, y: plate.maxY, width: plate.width, height: max(0, side.drawerRect.minY - plate.maxY))
            if side.drawerRect.insetBy(dx: -14, dy: -14).contains(mouse) || bridge.contains(mouse) { inDrawer = side }
        }
        for side in sides.values {
            let hovered = target?.side == side.side ? target : nil
            if side.model.hovered != hovered { side.model.hovered = hovered }
            // Fuori dalla forma i clic passano subito a quello che c'è sotto (il Dock è lì accanto), anche se il
            // cassetto aspetta ancora un attimo prima di chiudersi.
            side.panel?.ignoresMouseEvents = !(hovered != nil || inDrawer === side)
        }
        if let target {
            closeTimer?.invalidate()
            closeTimer = nil
            if !hovering {
                hovering = true
                hover = target
                enter(target)
            } else if target != hover {
                let previous = hover
                hover = target
                moved(from: previous, to: target)
            }
        } else if inDrawer != nil {
            closeTimer?.invalidate()
            closeTimer = nil
        } else if hovering, closeTimer == nil {
            // Solo passato sopra, senza cassetto aperto: si lascia subito, e l'attesa dell'apertura non scatta più.
            guard sides.values.contains(where: { $0.drawerOpen || $0.expansion.value > 0.05 }) else {
                leave()
                return
            }
            let timer = Timer(timeInterval: 0.32 * Self.slowMotion, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.leave() }
            }
            RunLoop.main.add(timer, forMode: .common)
            closeTimer = timer
        }
    }

    private func holdActivity(_ on: Bool) {
        if on, activity == nil {
            activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiatedAllowingIdleSystemSleep], reason: "Dock di Charland in uso")
        } else if !on, let current = activity {
            ProcessInfo.processInfo.endActivity(current)
            activity = nil
        }
    }

    private func note(_ what: String) {
        guard Self.trace else { return }
        print(String(format: "[dockbar] %.3f %@", CACurrentMediaTime(), what)); fflush(stdout)
    }

    /// Il puntatore arriva su un vassoio: un attimo di attesa (passando sopra per andare altrove il cassetto non
    /// scatta), poi si apre il suo cassetto.
    private func enter(_ target: DockTarget) {
        note("puntatore su \(target.module.rawValue)")
        holdActivity(true)
        refreshNow()
        openTimer?.invalidate()
        let timer = Timer(timeInterval: 0.14, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let hover = self.hover else { return }
                self.openDrawer(hover)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        openTimer = timer
        run()
    }

    /// Da un vassoio (o da un anello) all'altro mentre il puntatore resta sopra.
    private func moved(from previous: DockTarget?, to target: DockTarget) {
        guard let side = sides[target.side] else { return }
        if previous?.side != target.side, let old = previous.flatMap({ sides[$0.side] }) {
            // All'altro lato del Dock: si chiude di là e, se era aperto, si apre di qua subito (stai già guardando).
            // Se non era ancora aperto, ci pensa l'attesa già partita, che apre dove sta il puntatore.
            let wasOpen = old.drawerOpen || old.expansion.value > 0.3
            closeDrawer(old)
            if wasOpen { openDrawer(target) }
            return
        }
        guard side.drawerOpen else { return }
        if side.model.focus != target.module || (target.cell != nil && side.model.focusCell != target.cell) {
            focus(side, on: target)
        }
    }

    private func leave() {
        note("puntatore via")
        if !touring { holdActivity(false) }
        closeTimer?.invalidate()
        closeTimer = nil
        openTimer?.invalidate()
        openTimer = nil
        hovering = false
        hover = nil
        for side in sides.values {
            side.model.hovered = nil
            side.panel?.ignoresMouseEvents = true
            closeDrawer(side)
        }
    }

    /// Il cassetto di un lato mostra un modulo (e, per gli agenti, l'anello sotto il puntatore).
    private func focus(_ side: Side, on target: DockTarget) {
        guard let module = modules[target.module] else { return }
        let changedModule = side.model.focus != target.module
        if changedModule {
            if side.model.focus == .system { (modules[.system] as? SystemModule)?.drawerOpen(false) }
            if target.module == .system { (modules[.system] as? SystemModule)?.drawerOpen(true) }
            // I numeri freschi si chiedono a cassetto aperto e fermo: arrivati a metà apertura ridisegnavano tutto
            // proprio mentre la goccia saliva.
            let id = target.module, which = side.side
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, let side = self.sides[which], side.model.focus == id, side.drawerOpen else { return }
                    self.modules[id]?.refresh(look: true)
                }
            }
        }
        side.model.focus = target.module
        side.model.focusCell = target.cell ?? module.defaultFocus
        side.drawerHeight.target = Double(module.drawerHeight(focus: side.model.focusCell, now: side.model.now))
        run()
    }

    private func openDrawer(_ target: DockTarget) {
        openTimer = nil
        guard let side = sides[target.side], hovering || Self.forceOpen != nil, !side.drawerOpen,
              let module = modules[target.module], !module.isEmpty else { return }
        note("cassetto di \(target.module.rawValue): si apre")
        let wasClosed = side.expansion.value < 0.05
        side.model.focus = nil
        focus(side, on: target)
        if wasClosed {
            side.drawerHeight.snap(to: side.drawerHeight.target)
            side.needsCenterSnap = true
        }
        side.drawerOpen = true
        side.expansion.spring = plainDrawer ? Self.plainOpen : motion(Self.openSpring)
        side.expansion.target = 1
        side.tall.target = 1
        // Il puntatore sta per salire nel cassetto, sopra la cima del Dock: il Dock resta su finché il cassetto è aperto.
        DockHold.hold(true)
        startTicking()
        Haptics.tick()
        run()
    }

    private func closeDrawer(_ side: Side) {
        if side.model.focus == .system { (modules[.system] as? SystemModule)?.drawerOpen(false) }
        if side.drawerOpen || side.expansion.target != 0 {
            note("cassetto: si chiude")
            side.drawerOpen = false
            side.expansion.spring = plainDrawer ? Self.plainClose : motion(Self.closeSpring)
            side.expansion.target = 0
            side.tall.target = 0
        }
        updateDockHold()
        run()
    }

    /// Nessun cassetto aperto: il Dock torna a scomparsa (e col puntatore fuori scende, coi vassoi).
    private func updateDockHold() {
        if !sides.values.contains(where: { $0.drawerOpen }) { DockHold.hold(false) }
    }

    /// La rotella sopra un vassoio passa all'elemento seguente del suo modulo.
    private func scrolled(_ event: NSEvent) -> Bool {
        guard hovering, let hover, hover.module == .usage || hover.module == .system, let module = modules[hover.module] else { return false }
        let now = CACurrentMediaTime()
        if now - lastScroll > 0.6 { scrollSum = 0 }
        let delta = abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) ? -event.scrollingDeltaX : event.scrollingDeltaY
        scrollSum += event.hasPreciseScrollingDeltas ? delta : delta * 12
        guard abs(scrollSum) >= 14, now - lastScroll > 0.16 else { return true }
        let step = scrollSum > 0 ? -1 : 1
        scrollSum = 0
        lastScroll = now
        return module.scroll(step)
    }

    // MARK: Giro di prova

    /// Un giro fra i cassetti, come lo farebbe il puntatore: il primo vassoio di destra, il secondo, poi il primo e il
    /// secondo di sinistra, poi via; poi una pressione su un vassoio. Ogni passo scrive l'ora, per ritrovarlo nel video.
    private func runTour() {
        touring = true
        holdActivity(true)
        let right = settings.modules(on: .right).filter { modules[$0]?.isEmpty == false }
        let left = settings.modules(on: .left).filter { modules[$0]?.isEmpty == false }
        var steps: [(TimeInterval, () -> Void)] = []
        var t: TimeInterval = 0.6
        func go(_ side: DockSide, _ module: DockModuleID) {
            let target = DockTarget(side: side, module: module, cell: nil)
            steps.append((t, { [weak self] in
                guard let self else { return }
                self.note("giro: \(module.rawValue)")
                if !self.hovering {
                    self.hovering = true
                    self.hover = target
                    self.enter(target)
                } else {
                    let previous = self.hover
                    self.hover = target
                    self.moved(from: previous, to: target)
                }
                for s in self.sides.values { s.model.hovered = s.side == side ? target : nil }
            }))
            t += 1.6
        }
        for module in right { go(.right, module) }
        for module in left { go(.left, module) }
        steps.append((t, { [weak self] in self?.note("giro: via"); self?.leave() }))
        t += 1.6
        if let first = right.first ?? left.first {
            let side: DockSide = right.isEmpty ? .left : .right
            steps.append((t, { [weak self] in self?.note("giro: premuto"); self?.press(side, first, down: true) }))
            steps.append((t + 0.25, { [weak self] in self?.note("giro: lasciato"); self?.press(side, first, down: false) }))
            t += 1.2
        }
        if right.count > 1 {
            let last = right[right.count - 1]
            steps.append((t, { [weak self] in self?.note("giro: via \(last.rawValue)"); self?.tourHidden = [last]; self?.retarget(); self?.run() }))
            steps.append((t + 1.4, { [weak self] in self?.note("giro: torna \(last.rawValue)"); self?.tourHidden = []; self?.retarget(); self?.run() }))
            t += 3
            // Anche il primo, quello accanto al Dock: sparendo si fonde nel secondo, che scivola al suo posto.
            let first = right[0]
            steps.append((t, { [weak self] in self?.note("giro: via \(first.rawValue)"); self?.tourHidden = [first]; self?.retarget(); self?.run() }))
            steps.append((t + 1.4, { [weak self] in self?.note("giro: torna \(first.rawValue)"); self?.tourHidden = []; self?.retarget(); self?.run() }))
            t += 3
        }
        steps.append((t, { [weak self] in
            self?.note("giro: fine")
            self?.touring = false
            self?.holdActivity(false)
        }))
        tourSteps = steps
        tourIndex = 0
        scheduleTourStep(after: 0)
    }

    /// Un passo alla volta, ognuno col suo timer preciso: programmati tutti insieme all'inizio, i più lontani potevano
    /// slittare di quasi un secondo (il sistema raggruppa le attese lunghe) e due passi finivano insieme.
    private var tourSteps: [(TimeInterval, () -> Void)] = []
    private var tourIndex = 0

    private func scheduleTourStep(after previous: TimeInterval) {
        guard tourIndex < tourSteps.count else { return }
        let time = tourSteps[tourIndex].0
        let timer = Timer(timeInterval: max(0, time - previous) * Self.slowMotion, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.tourIndex < self.tourSteps.count else { return }
                let (time, step) = self.tourSteps[self.tourIndex]
                self.tourIndex += 1
                step()
                self.scheduleTourStep(after: time)
            }
        }
        timer.tolerance = 0
        RunLoop.main.add(timer, forMode: .common)
    }

    // MARK: Ora

    /// L'ora dei moduli (il conto alla rovescia del prossimo impegno, i tempi che mancano nei cassetti) si aggiorna
    /// solo mentre qualcosa si vede, e solo quando cambia il minuto.
    private func startTicking() {
        guard tickTimer == nil else { return }
        let timer = Timer(timeInterval: 10, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        timer.tolerance = 2
        RunLoop.main.add(timer, forMode: .common)
        tickTimer = timer
    }

    private func stopTicking() {
        tickTimer?.invalidate()
        tickTimer = nil
    }

    private func tick() {
        let visible = lift > 0.5 || sides.values.contains { $0.drawerOpen }
        guard visible else { stopTicking(); return }
        refreshNow()
        // Un Dock sempre visibile (senza scomparsa automatica, o con «Resta visibile») non «sale» mai una seconda
        // volta: i moduli prendevano i numeri all'avvio e poi mai più (utilizzo fermo anche dopo che il limite era
        // ripartito, impegni di ieri dopo mezzanotte, Charcal mai riletto). Uno sguardo al minuto, solo se qualcuno
        // sta usando il Mac; ogni modulo ha già il suo freno.
        let moment = CACurrentMediaTime()
        if moment - lastGlance > 60, moment - lastPointerMove < 300 {
            lastGlance = moment
            for id in activeModules { modules[id]?.refresh(look: false) }
        }
        // Un puntatore dimenticato sul cassetto non tiene svegli i comandi degli agenti tutta la notte.
        if sides.values.contains(where: { $0.drawerOpen && $0.model.focus == .usage }), CACurrentMediaTime() - lastPointerMove < 300 {
            modules[.usage]?.refresh(look: true)
        }
    }

    private func refreshNow() {
        let now = Date()
        let minute = Int(now.timeIntervalSince1970 / 60)
        guard let model = sides[.right]?.model, Int(model.now.timeIntervalSince1970 / 60) != minute else { return }
        for side in sides.values { side.model.now = now }
        DictationStats.shared.rollDayIfNeeded()
        retarget()
        run()
    }

    // MARK: Fotogrammi

    private func run() {
        guard active, !clockRunning else { return }
        clockRunning = true
        lastTimestamp = 0
        clock.start(on: screen)
    }

    private func frame(_ link: CADisplayLink) {
        let now = link.targetTimestamp
        if Self.trace, lastTimestamp != 0, now - lastTimestamp > link.duration * 1.5 {
            print(String(format: "[dockbar] %.3f fotogramma lungo %.0f ms (salita %.2f)", now, (now - lastTimestamp) * 1000, lift))
            fflush(stdout)
        }
        let dt = (lastTimestamp == 0 ? link.duration : min(now - lastTimestamp, link.duration * 1.25)) / Self.slowMotion
        lastTimestamp = now

        let dock = tracker.snapshot()
        tracker.acknowledge()
        if let forced = Self.forceOpen, warming == 0, lift > 0.9, let side = sides[settings.side(of: forced)], !side.drawerOpen {
            hovering = true
            hover = DockTarget(side: side.side, module: forced, cell: nil)
            openDrawer(hover!)
        }
        if warming == 2 {
            if CACurrentMediaTime() < warmUntil {
                hold.snap(to: 1)
                for side in sides.values {
                    side.expansion.snap(to: 1); side.tall.snap(to: 1)
                    if side.model.focus == nil, let first = settings.modules(on: side.side).first {
                        side.model.focus = first
                        side.model.focusCell = modules[first]?.defaultFocus
                    }
                }
            } else {
                warming = 1
                hold.snap(to: pinned ? 1 : 0)
                for side in sides.values {
                    side.expansion.snap(to: 0); side.tall.snap(to: 0)
                    // Se i vassoi si vedono subito (Dock fisso, o «resta visibile») nascono adesso, a finestra visibile.
                    for id in side.presence.keys { side.presence[id]?.snap(to: 0) }
                }
            }
        } else if warming == 1 {
            // Il disegno è tornato sotto il bordo nel fotogramma prima: adesso le finestre possono tornare visibili.
            warming = 0
            for side in sides.values { side.panel?.alphaValue = 1 }
        }
        // I vassoi vanno su e giù col Dock, attaccati a lui (carpa: «quando si abbassa il Dock si devono abbassare anche
        // le cose laterali»): scendono nello stesso istante, anche col cassetto che sta ancora rientrando (prima
        // aspettavano che fosse rientrato e restavano su da soli). Restano su senza il Dock solo col puntatore sopra di
        // loro o nel cassetto, se no il cassetto non si potrebbe usare: macOS abbassa il Dock appena il puntatore sale
        // sopra la sua cima, e tenerlo su da fuori non si può. E se hai scelto
        // «Resta visibile», o nelle prove.
        if warming != 2 {
            hold.target = pinned || hovering || Self.forceOpen != nil ? 1 : 0
        }

        var moving = hold.step(dt: dt)
        for (key, var spring) in opens where !spring.isSettled {
            moving = spring.step(dt: dt) || moving
            opens[key] = spring
        }
        for (key, var spring) in labelWidths where !spring.isSettled {
            moving = spring.step(dt: dt) || moving
            labelWidths[key] = spring
        }
        for side in sides.values {
            for id in side.presence.keys {
                if var spring = side.presence[id] {
                    moving = spring.step(dt: dt) || moving
                    side.presence[id] = spring
                }
            }
            for id in side.press.keys {
                if var spring = side.press[id], !spring.isSettled {
                    moving = spring.step(dt: dt) || moving
                    side.press[id] = spring
                }
            }
            moving = side.expansion.step(dt: dt) || moving
            moving = side.tall.step(dt: dt) || moving
            moving = side.drawerHeight.step(dt: dt) || moving
            moving = side.drawerCenter.step(dt: dt) || moving
        }
        // Il Dock è già un fotogramma avanti quando i vassoi arrivano sullo schermo: la sua posizione si anticipa di
        // quel tanto, con la velocità delle ultime due letture. Misurato sul video: senza, 7 punti di ritardo a metà.
        let lead = dock.moving ? CGFloat(dock.age + link.duration * Self.leadFrames) : 0
        publish(dock.reading, velocity: dock.velocity, lead: lead, dockMoving: dock.moving)
        setShown(lift > 0.001 && warming == 0)
        // `publish` può aver cambiato dove devono arrivare i vassoi (non c'è più posto) o il cassetto (il suo centro).
        let unsettled = sides.values.contains { side in
            side.presence.values.contains { !$0.isSettled } || !side.drawerCenter.isSettled
        }
        moving = moving || dock.moving || warming != 0 || unsettled
        guard !moving else { return }
        clock.stop()
        clockRunning = false
        let lifted = lift > 0.5
        if lifted, Self.tourRequested, !tourStarted {
            tourStarted = true
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.tourDelay) { [weak self] in
                MainActor.assumeIsolated { self?.runTour() }
            }
        }
        if lifted, tickTimer == nil { startTicking() }
        if lifted, !wasLifted {
            // Il Dock è salito e si è fermato: uno sguardo ai numeri, senza aspettare il puntatore. Non prima: mentre
            // sale non si fa nient'altro.
            refreshNow()
            lastGlance = CACurrentMediaTime()
            for id in activeModules { modules[id]?.refresh(look: false) }
            startTicking()
        }
        wasLifted = lifted
        // Sotto il bordo: da nascoste le finestre possono rimettersi dove serve senza che si veda.
        if lift <= 0.001 { for side in sides.values { side.anchorX = nil } }
    }

    private func setShown(_ on: Bool) {
        guard on != shown else { return }
        shown = on
        SystemStats.shared.setVisible(on)
    }

    private func publish(_ reading: DockReading?, velocity: CGFloat, lead: CGFloat, dockMoving: Bool) {
        guard let reading, reading.horizontal, let primary = NSScreen.screens.first else {
            // Il Dock non si legge più (Accessibilità tolta, Dock riavviato) o è su un fianco: i vassoi se ne vanno,
            // non restano disegnati dov'erano.
            if hovering { leave() }
            lift = 0
            DockHold.hold(false)
            for side in sides.values {
                for id in side.presence.keys { side.presence[id]?.snap(to: 0) }
                side.expansion.snap(to: 0)
                side.tall.snap(to: 0)
                side.drawerOpen = false
                side.plateRects = [:]
                let away = CGSize(width: side.model.shift.width, height: side.model.window.height)
                if side.model.shift != away { side.model.shift = away }
                if side.model.expansion != 0 { side.model.expansion = 0 }
                if side.model.lift != 0 { side.model.lift = 0 }
                side.anchorX = nil
            }
            return
        }
        // Dall'Accessibilità (origine in alto) ad AppKit (origine in basso).
        let flip = primary.frame.maxY
        let probe = CGPoint(x: reading.list.midX, y: flip - reading.list.minY + 2)
        let screen = NSScreen.screens.first { $0.frame.contains(probe) }
            ?? NSScreen.screens.min { abs($0.frame.midX - probe.x) < abs($1.frame.midX - probe.x) } ?? primary
        if screen != self.screen {
            self.screen = screen
            for side in sides.values { side.anchorX = nil }
            // I fotogrammi si contano sullo schermo dove sta il Dock.
            if clockRunning { clock.start(on: screen) }
        }
        let bottom = flip - screen.frame.minY          // il bordo basso dello schermo, nelle coordinate dell'Accessibilità
        if bottom != trackedBottom {
            trackedBottom = bottom
            tracker.setScreenBottom(bottom)
        }
        let height = reading.plateHeight

        // Quanto sale il Dock quando è fuori: si impara la prima volta che lo si vede fermo e salito.
        let gapNow = bottom - reading.list.minY
        if gapNow > 20, gapNow <= reading.list.height + 40, velocity == 0, !dockMoving, abs(gapNow - shownGap) > 0.5 {
            shownGap = gapNow
            UserDefaults.standard.set(Double(gapNow), forKey: "dockShownGap")
        }
        let gap = shownGap > 20 ? shownGap : reading.list.height + 10
        let restTop = bottom - gap + reading.plateTop
        // Nascosto sta dove sta il vassoio del Dock nascosto: appena sotto il bordo. Così «salita zero» vuol dire
        // davvero nascosto.
        let hiddenTop = bottom + reading.plateTop
        // Mai oltre i due capi della corsa: l'anticipo non fa rimbalzare i vassoi a fine salita.
        let liveTop = min(bottom + reading.plateTop, max(restTop, reading.list.minY + reading.plateTop + velocity * lead))
        let holdTop = hiddenTop + (restTop - hiddenTop) * CGFloat(hold.value)
        let top = max(restTop - 1, min(liveTop, holdTop))
        var lift = Double(min(1, max(0, (hiddenTop - top) / (hiddenTop - restTop))))
        if lift < 0.005 { lift = 0 }
        self.lift = lift

        for side in sides.values {
            layout(side, reading: reading, screen: screen, flip: flip, top: top, height: height, lift: lift)
        }
    }

    /// Un lato: dove sta ogni vassoio, la finestra, il cassetto, la forma del vetro.
    private func layout(_ side: Side, reading: DockReading, screen: NSScreen, flip: CGFloat, top: CGFloat, height: CGFloat, lift: Double) {
        let right = side.side == .right
        let edge = right ? reading.list.maxX + DockBarMetrics.gap : reading.list.minX - DockBarMetrics.gap
        let room = right ? screen.frame.maxX - 6 - edge : edge - (screen.frame.minX + 6)
        let now = side.model.now

        // I vassoi in fila dal Dock verso fuori; quelli che non ci stanno più non escono.
        var rows: [DockRowState] = []
        var cursor: CGFloat = 0
        var used: CGFloat = 0
        var before = 0.0
        for id in side.order {
            guard let module = modules[id] else { continue }
            var cells = module.cells(height: height, now: now)
            for index in cells.indices {
                let key = id.rawValue + "." + cells[index].id
                cells[index].open = opens[key]?.value ?? cells[index].open
                if let width = labelWidths[key] { cells[index].label = CGFloat(width.value) }
            }
            let rowLayout = DockRowLayout(cells: cells, height: height)
            let full = rowLayout.width
            // Un vassoio spento (o tolto, che sta ancora uscendo) non occupa posto: prima il suo spazio restava contato e
            // uno acceso dopo di lui poteva restare fuori fino al minuto seguente. Chi c'è già ha qualche punto di margine
            // in più di chi deve entrare, così mentre un testo cambia larghezza al limite non entra ed esce a ogni
            // fotogramma.
            let wanted = settings.isOn(id) && settings.side(of: id) == side.side && !module.isEmpty && !tourHidden.contains(id)
            if wanted {
                let slack: CGFloat = side.presence[id]?.target == 1 ? 6 : -6
                let fits = used + full <= room + slack
                if fits { side.overflow.remove(id) } else { side.overflow.insert(id) }
                if !fits, side.presence[id]?.target == 1 { side.presence[id]?.target = 0 }
                if fits, side.presence[id]?.target == 0 { side.presence[id]?.target = 1 }
                if fits { used += full + DockBarMetrics.gap }
            }
            let p = max(0, side.presence[id]?.value ?? 0)
            let (x, width) = Self.place(full: full, presence: p, right: right, cursor: &cursor, before: &before)
            rows.append(DockRowState(id: id, layout: rowLayout, x: x, width: width, presence: p, press: side.press[id]?.value ?? 0))
        }
        fitWindow(side, groupWidth: rows.reduce(0) { $0 + $1.layout.width + DockBarMetrics.gap })

        // La finestra: ferma mentre i vassoi si vedono, si rimette al suo posto solo da nascosta.
        let size = side.model.window
        let canvas = side.model.canvas
        let anchorFor = edge - canvas.x
        if side.anchorX == nil || abs(anchorFor - side.anchorX!) > 150 { side.anchorX = anchorFor.rounded() }
        let frame = CGRect(x: side.anchorX!, y: screen.frame.minY, width: size.width, height: size.height)
        if side.panel?.frame != frame { side.panel?.setFrame(frame, display: false) }
        // Al pixel dello schermo: fermo a mezzo pixel il filo di luce e i numeri venivano sfocati.
        let pixel = max(1, screen.backingScaleFactor)
        func px(_ v: CGFloat) -> CGFloat { (v * pixel).rounded() / pixel }
        let shift = CGSize(width: px(edge - (frame.minX + canvas.x)), height: px(size.height - (flip - top - screen.frame.minY) - canvas.y))
        let plateY = flip - top - height
        side.plateRects = Dictionary(rows.map { ($0.id, CGRect(x: edge + $0.x, y: plateY, width: $0.width, height: height)) },
                                     uniquingKeysWith: { first, _ in first })

        // Il cassetto: centrato sul vassoio che mostra, dentro lo schermo.
        let e = side.expansion.value
        let drawerSize = CGSize(width: DockDrawerMetrics.width, height: CGFloat(side.drawerHeight.value))
        if let focus = side.model.focus, let row = rows.first(where: { $0.id == focus }) {
            // Sul centro del vassoio intero, non di quello che sta crescendo: il cassetto non scivola mentre nasce.
            var center = right ? row.x + row.layout.width / 2 : row.x + row.width - row.layout.width / 2
            let screenLeft = edge + center - drawerSize.width / 2
            if screenLeft < screen.frame.minX + 8 { center += screen.frame.minX + 8 - screenLeft }
            if screenLeft + drawerSize.width > screen.frame.maxX - 8 { center -= screenLeft + drawerSize.width - (screen.frame.maxX - 8) }
            if side.needsCenterSnap || (e < 0.02 && !side.drawerOpen) || reduceMotion {
                side.drawerCenter.snap(to: Double(center))
                side.needsCenterSnap = false
            } else {
                side.drawerCenter.target = Double(center)
            }
        }
        let centerX = CGFloat(side.drawerCenter.value)
        let drawer = CGRect(x: centerX - drawerSize.width / 2, y: -DockBarMetrics.drawerGap - drawerSize.height,
                            width: drawerSize.width, height: drawerSize.height)
        side.drawerRect = CGRect(x: edge + drawer.minX, y: plateY + height + DockBarMetrics.drawerGap,
                                 width: drawer.width, height: drawer.height)

        // La forma: si ricalcola solo se è cambiato qualcosa che la riguarda.
        let focusIndex = rows.firstIndex { $0.id == side.model.focus }
        // Scivolando da un vassoio all'altro il cassetto si allunga appena nel verso del movimento e si abbassa di
        // conseguenza, come un liquido che corre; fermo torna com'era.
        let plain = plainDrawer
        let slide = plain ? 0 : (side.drawerCenter.velocity / 2600).rounded(toPlaces: 3)
        // Col cassetto semplice la forma liquida è fatta solo dei vassoi: aprire, chiudere e far scivolare il cassetto
        // non la cambia, quindi non si ritraccia (prima: un contorno nuovo a ogni fotogramma dell'apertura).
        var key = plain ? [Double(height)]
            : [Double(height), e, side.tall.value, side.drawerHeight.value, Double(centerX), Double(focusIndex ?? -1), slide]
        for row in rows { key += [Double(row.x), Double(row.width), row.press, row.presence] }
        if key != side.shapeKey {
            side.shapeKey = key
            let shape = Self.outline(rows: rows, height: height, e: plain ? 0 : e, tall: side.tall.value, focus: focusIndex,
                                centerX: centerX, drawer: drawerSize, slide: slide, tracer: side.tracer, calm: plain,
                                bounds: (screen.frame.minX + 2 - edge)...(screen.frame.maxX - 2 - edge))
            side.model.outline = shape.path.offsetBy(dx: canvas.x, dy: canvas.y)
            if !plain, side.model.drop != shape.drop { side.model.drop = shape.drop }
        }
        if plain {
            // Il cassetto al suo posto: lo disegna la vista come un vetro a parte.
            let drop = e > 0.0005 && focusIndex != nil ? drawer : .zero
            if side.model.drop != drop { side.model.drop = drop }
        }
        if side.model.rows != rows { side.model.rows = rows }
        if side.model.shift != shift { side.model.shift = shift }
        if side.model.drawer != drawer { side.model.drawer = drawer }
        if side.model.expansion != e { side.model.expansion = e }
        if side.model.lift != lift { side.model.lift = lift }
    }

    /// Dove va un vassoio nella fila, dal Dock verso fuori. Lo spazio che lo separa dal vicino si apre e si chiude con
    /// lui (e con quanto c'è prima, `before`: la presenza più alta finora), così un vassoio che compare si stacca dal
    /// fianco del vicino e uno che sparisce ci rientra. Con lo spazio fisso si ritirava verso un punto staccato di 8
    /// punti e negli ultimi fotogrammi restava un bastoncino da solo.
    static func place(full: CGFloat, presence p: Double, right: Bool, cursor: inout CGFloat, before: inout Double) -> (x: CGFloat, width: CGFloat) {
        let width = max(0, full * CGFloat(min(1.08, p)))
        let lead = DockBarMetrics.gap * CGFloat(min(1, p, before))
        let x = right ? cursor + lead : -(cursor + lead) - width
        cursor += lead + width
        before = max(before, p)
        return (x, width)
    }

    /// Il vetro di un lato: i vassoi, e la goccia che esce in alto da quello scelto, sale, si stacca e si apre nel
    /// cassetto.
    /// Con `calm` (Riduci movimento) la goccia non c'è: `drop` è il cassetto intero al suo posto, che la vista disegna a
    /// parte in dissolvenza. `bounds` è lo schermo, nelle stesse coordinate: la goccia non ne esce nemmeno scivolando.
    static func outline(rows: [DockRowState], height: CGFloat, e: Double, tall: Double, focus: Int?,
                         centerX: CGFloat, drawer: CGSize, slide: Double, tracer: ContourTracer, calm: Bool = false,
                         bounds: ClosedRange<CGFloat>? = nil) -> (path: Path, drop: CGRect) {
        let m = DockBarMetrics.self
        let plates = rows.map { row -> CGRect in
            let tall = min(height * row.heightScale, row.width)
            let plate = CGRect(x: row.x, y: (height - tall) / 2, width: row.width, height: tall)
            let grow = CGFloat(DockRowState.pressGrow * row.press) / 2
            return plate.insetBy(dx: -plate.width * grow, dy: -plate.height * grow)
        }
        var drop = CGRect.zero
        var radius = 0.0
        if calm, e > 0.0005, let focus, plates.indices.contains(focus), plates[focus].width > 1 {
            drop = CGRect(x: centerX - drawer.width / 2, y: -m.drawerGap - drawer.height, width: drawer.width, height: drawer.height)
        } else if e > 0.0005, let focus, plates.indices.contains(focus), plates[focus].width > 1 {
            // Parte da dentro il vassoio, tonda e larga poco più di un anello; sale gonfiandosi come un palloncino (il
            // collo col vassoio resta stretto), si stacca e si squadra nel cassetto. L'altezza insegue con la sua molla,
            // ma all'inizio non corre avanti: una goccia lunga e stretta sembrava un dito.
            let plate = plates[focus]
            let grow = m.smooth(0.06, 0.9, e)
            let startWidth = max(8, min(plate.width - 12, max(height - 12, plate.width * 0.5)))
            let stretch = CGFloat(min(0.1, abs(slide)))
            let w = m.lerp(startWidth, drawer.width, grow) * (1 + stretch)
            let bottom = m.lerp(height - 6, -m.drawerGap, m.smooth(0, 0.55, e))
            let h = max(8, m.lerp(height - 12, drawer.height, max(0, min(tall, grow * 1.12 + 0.02))) * (1 - stretch * 0.5))
            let cx = m.lerp(plate.midX, centerX, grow)
            drop = CGRect(x: cx - w / 2, y: bottom - h, width: w, height: h)
            // Allungata dalla scivolata (o oltre il centro per il rimbalzo della molla) poteva uscire dallo schermo di
            // qualche punto per qualche fotogramma.
            if let bounds, w < bounds.upperBound - bounds.lowerBound {
                drop.origin.x = min(max(drop.minX, bounds.lowerBound), bounds.upperBound - w)
            }
            let round = Double(min(w, h)) / 2
            radius = round + (Double(m.drawerCorner) - round) * m.smooth(0.5, 1, e)
        }
        let blend = calm ? 0 : m.blend(e)
        // Un vassoio che compare nasce dal vicino verso il Dock: unione morbida finché non è quasi grande del tutto. Il
        // raggio si spegne anche negli ultimi istanti di un vassoio che sparisce, così quando esce dall'elenco non resta
        // un rigonfiamento che scompare di colpo.
        let buds = rows.map { 22 * (1 - m.smooth(0.45, 0.95, $0.presence)) * m.smooth(0, 0.2, $0.presence) }
        // Nel campo solo i vassoi che hanno una misura: uno largo zero diventava un punto nell'angolo del gruppo, e con
        // l'unione morbida un codino in cima al vassoio vicino.
        let kept = plates.indices.filter { plates[$0].width > 1 }
        // L'unione col vicino è morbida se uno dei due sta entrando o uscendo: anche il primo vassoio, quello accanto al
        // Dock, sparendo si fonde nel secondo invece di restare da solo.
        let joins = kept.indices.map { k in k == 0 ? 0 : max(buds[kept[k]], buds[kept[k - 1]]) }
        let field = DockBarField(plates: kept.map { plates[$0] }, buds: joins,
                                 focus: focus.flatMap { kept.firstIndex(of: $0) }, drop: calm ? .zero : drop, dropRadius: radius, blend: blend)
        let reach = max(blend, buds.max() ?? 0) * 0.25 + 3
        func down(_ v: Double) -> Double { (v * 2).rounded(.down) / 2 }
        func up(_ v: Double) -> Double { (v * 2).rounded(.up) / 2 }
        var union = plates.filter { $0.width > 1 }.reduce(CGRect.null) { $0.union($1) }
        if !drop.isEmpty, !calm { union = union.union(drop) }
        guard !union.isNull else { return (Path(), drop) }
        var path = Path()
        for loop in tracer.trace(field, minX: down(Double(union.minX) - reach), minY: down(Double(union.minY) - reach),
                                 maxX: up(Double(union.maxX) + reach), maxY: up(Double(union.maxY) + reach)) {
            guard let first = loop.first else { continue }
            path.move(to: CGPoint(x: first.x, y: first.y))
            for point in loop.dropFirst() { path.addLine(to: CGPoint(x: point.x, y: point.y)) }
            path.closeSubpath()
        }
        return (path, drop)
    }
}

private extension Double {
    func rounded(toPlaces places: Int) -> Double {
        let scale = pow(10, Double(places))
        return (self * scale).rounded() / scale
    }
}

/// Un lato del Dock: un vetro solo (quello di Charland), con dentro i vassoi e, sopra, il cassetto di quello scelto.
struct DockSideView: View {
    let model: DockSideModel
    let bar: DockBar
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        let e = model.expansion
        // Col cassetto semplice il testo arriva insieme al vetro, non dopo.
        let shown = model.plain ? DockBarMetrics.smooth(0.1, 0.85, e) : DockBarMetrics.contentOpacity(e)
        let canvas = model.canvas
        let right = model.side == .right
        // Mentre segue il Dock cambiano solo salita e spostamento: li legge una vista a parte, così questo disegno (vetro,
        // vassoi, cassetti) non si ricalcola a ogni fotogramma della salita.
        DockLift(model: model) {
        ZStack(alignment: .topLeading) {
            CharlandGlassFill(shape: OutlineShape(path: model.outline), veil: veil(canvas: canvas), rim: rim(canvas: canvas))
            // Il cassetto semplice (di serie, e con Riduci movimento): un vetro suo, al suo posto, che compare e basta.
            // Sale di un niente mentre compare, come un menu; con Riduci movimento solo la dissolvenza.
            if model.plain {
                CharlandGlassFill(shape: RoundedRectangle(cornerRadius: DockBarMetrics.drawerCorner, style: .continuous),
                                  veil: AnyShapeStyle(Color.black.opacity(drawerVeil)))
                    .frame(width: model.drop.width, height: model.drop.height)
                    .scaleEffect(model.calm ? 1 : 0.97 + 0.03 * DockBarMetrics.smooth(0, 1, e), anchor: .bottom)
                    .offset(x: canvas.x + model.drop.minX, y: canvas.y + model.drop.minY)
                    .opacity(DockBarMetrics.smooth(0, 0.7, e))
            }
            ForEach(model.rows) { row in
                let appear = DockBarMetrics.smooth(0.55, 1, row.presence)
                // Il contenuto sta attaccato al lato del Dock e cresce appena da lì, uguale ai due lati: a sinistra prima
                // seguiva il bordo esterno e gli anelli scivolavano verso fuori insieme al vassoio.
                DockModulePlatter(id: row.id, layout: row.layout,
                                  hovered: model.hovered?.module == row.id ? model.hovered?.cell : nil, now: model.now)
                    .overlay(alignment: .topLeading) { taps(row) }
                    .scaleEffect(model.calm ? 1 : 0.9 + 0.1 * appear, anchor: right ? .leading : .trailing)
                    .frame(width: row.width, height: row.plateHeight, alignment: right ? .leading : .trailing)
                    .clipShape(Capsule())
                    .scaleEffect(1 + DockRowState.pressGrow * row.press)
                    .opacity(appear)
                    .offset(x: canvas.x + row.x, y: canvas.y + (row.layout.height - row.plateHeight) / 2)
            }
            // I cassetti ci sono sempre, invisibili finché sono chiusi: crearli all'apertura costava cinque fotogrammi
            // proprio mentre la goccia partiva. Passando da un vassoio all'altro si scambiano in dissolvenza. Tutti
            // ritagliati dalla forma del vetro: niente esce mai dalla goccia.
            ZStack(alignment: .topLeading) {
            ForEach(model.rows) { row in
                let active = model.focus == row.id
                DockModuleDrawer(id: row.id, focus: active ? model.focusCell : nil, now: model.now)
                    .animation(.spring(response: 0.36, dampingFraction: 0.86), value: model.focusCell)
                    .frame(width: model.drawer.width, height: model.drawer.height, alignment: .topLeading)
                    .clipped()
                    // La misura del cassetto la porta già la sua molla, fotogramma per fotogramma: l'animazione del
                    // cambio di vassoio qui sotto non deve addolcirla una seconda volta.
                    .transaction { $0.animation = nil }
                    .opacity(active ? shown : 0)
                    // Passando a un altro vassoio quello di prima se ne va in fretta sfocandosi e il nuovo entra subito
                    // dopo mettendosi a fuoco: i due testi non si sovrappongono mai.
                    .blur(radius: active ? 0 : 5)
                    .animation(active ? .easeOut(duration: 0.24).delay(0.05) : .easeIn(duration: 0.1), value: model.focus)
                    .scaleEffect(model.calm ? 1 : (model.plain ? 0.97 + 0.03 * DockBarMetrics.smooth(0, 1, e) : 0.96 + 0.04 * shown),
                                 anchor: .bottom)
                    .blur(radius: !model.plain && active && shown > 0 ? 8 * (1 - shown) : 0)
                    .offset(x: canvas.x + model.drawer.minX, y: canvas.y + model.drawer.minY)
                    .allowsHitTesting(active && e > 0.9)
            }
            }
            .frame(width: model.window.width, height: model.window.height, alignment: .topLeading)
            .mask {
                ZStack(alignment: .topLeading) {
                    OutlineShape(path: model.outline)
                    if model.plain {
                        RoundedRectangle(cornerRadius: DockBarMetrics.drawerCorner, style: .continuous)
                            .frame(width: model.drop.width, height: model.drop.height)
                            .offset(x: canvas.x + model.drop.minX, y: canvas.y + model.drop.minY)
                    }
                }
                .frame(width: model.window.width, height: model.window.height, alignment: .topLeading)
            }
        }
        .frame(width: model.window.width, height: model.window.height, alignment: .topLeading)
        }
        .environment(\.colorScheme, .dark)
    }

    /// Il velo del cassetto: un po' più scuro di quello degli slider, i numeri bianchi si leggono anche su una pagina
    /// bianca. Con Aumenta contrasto più scuro ancora.
    private var drawerVeil: Double { 0.6 + (contrast == .increased ? 0.14 : 0) }

    /// Il velo: più scuro solo nel cassetto, che si scurisce aprendosi; i vassoi restano come sono. Un velo unico su tutta
    /// la forma scuriva anche i vassoi accanto a ogni apertura, e il vetro di Apple non cambia luce quando un vicino si
    /// trasforma.
    private func veil(canvas: CGPoint) -> AnyShapeStyle {
        let boost = contrast == .increased ? 0.14 : 0
        // Con «Tutto vetro» i vassoi sono più trasparenti: si vede il vetro, non il velo.
        let base = Glassy.on ? 0.14 : 0.36
        let tray = Color.black.opacity(base + boost)
        // Si scurisce solo a goccia staccata: mentre è ancora attaccata al vassoio il cambio di velo si vedeva come una
        // riga di traverso sul collo.
        let drawer = Color.black.opacity(base + (0.6 - base) * DockBarMetrics.smooth(0.45, 1, model.expansion) + boost)
        let height = max(1, model.window.height)
        func at(_ y: CGFloat) -> CGFloat { min(1, max(0, y / height)) }
        return AnyShapeStyle(LinearGradient(stops: [.init(color: drawer, location: 0), .init(color: drawer, location: at(canvas.y - 6)),
                                                    .init(color: tray, location: at(canvas.y)), .init(color: tray, location: 1)],
                                            startPoint: .top, endPoint: .bottom))
    }

    /// Il filo di luce come nel vetro di Apple: acceso in alto e spento in basso su ogni forma, i vassoi e la goccia (o il
    /// cassetto). Un gradiente solo su tutta la finestra lasciava i vassoi, in fondo, quasi senza filo.
    private func rim(canvas: CGPoint) -> AnyShapeStyle {
        let height = max(1, model.window.height)
        let tray = model.rows.first?.layout.height ?? 49
        func at(_ y: CGFloat) -> CGFloat { min(1, max(0, y / height)) }
        let bright = Color.white.opacity(CharlandGlass.rimTop), dim = Color.white.opacity(CharlandGlass.rimBottom)
        var stops: [Gradient.Stop] = []
        // Solo con la goccia già sopra i vassoi: dentro il vassoio (i primi fotogrammi) i punti del gradiente sarebbero
        // fuori ordine.
        if model.expansion > 0.001, model.drop.height > 1, model.drop.minY < -1, !model.plain {
            stops += [.init(color: bright, location: at(canvas.y + model.drop.minY)),
                      .init(color: dim, location: at(canvas.y + min(model.drop.maxY, -1)))]
        }
        stops += [.init(color: bright, location: at(canvas.y)), .init(color: dim, location: at(canvas.y + tray))]
        return AnyShapeStyle(LinearGradient(stops: stops, startPoint: .top, endPoint: .bottom))
    }

    /// Un tocco su un anello: il vassoio si gonfia mentre il clic è giù, e lasciato il modulo decide cosa fare
    /// (scegliere l'agente, dettare, aprire il Calendario). Un trascinamento oltre qualche punto non conta come clic.
    private func taps(_ row: DockRowState) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach(row.layout.cells) { cell in
                let frame = row.layout.hitFrame(cell.id)
                Color.clear
                    .contentShape(Rectangle())
                    .frame(width: frame.width, height: frame.height)
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { _ in
                                if row.press < 0.5 { bar.press(model.side, row.id, down: true) }
                            }
                            .onEnded { value in
                                bar.press(model.side, row.id, down: false)
                                if hypot(value.translation.width, value.translation.height) < 6 { bar.tap(row.id, cell: cell.id) }
                            }
                    )
                    .offset(x: frame.minX)
            }
        }
    }
}

/// Salita e ombra di un lato: le uniche cose che cambiano mentre i vassoi seguono il Dock. Stanno in una vista a parte
/// perché leggerle nel disegno del lato lo faceva ricalcolare tutto a ogni fotogramma.
private struct DockLift<Content: View>: View {
    let model: DockSideModel
    @ViewBuilder var content: Content

    var body: some View {
        content
            .shadow(color: .black.opacity(CharlandGlass.shadowOpacity * model.lift), radius: CharlandGlass.shadowRadius, y: CharlandGlass.shadowY)
            // Tutto il disegno si sposta insieme: mentre segue il Dock non cambia nient'altro.
            .offset(model.shift)
    }
}
