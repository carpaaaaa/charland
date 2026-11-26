import AppKit
import SwiftUI
import CharlandCore

/// Volume e luminosità come su iPhone: una pillola verticale sul bordo sinistro dello schermo, fuori dall'isola
/// (carpa, 17 novembre 2026: «a sinistra proprio identici all'iPhone, il vuoto in vetro e lo slide in bianco»).
///
/// Premendo i tasti esce sottile dal bordo, all'altezza dove su iPhone stanno i tasti del volume. Col puntatore
/// sopra si allarga come sotto il dito (il simbolo in fondo cresce con lei) e si trascina. Oltre il massimo o il minimo si
/// allunga ad elastico e si assottiglia, poi torna a molla. Lasciata stare rientra nel bordo.
@MainActor @Observable
final class SideSliderModel {
    var side: SliderSide = .volume
    /// Il livello mostrato, fra 0 e 1.
    var level = 0.5
    /// Il livello di arrivo: i simboli lo seguono, così la molla che rimbalza vicino allo zero non li fa lampeggiare.
    var target = 0.5
    /// L'elastico oltre i limiti, in punti: positivo sopra il massimo, negativo sotto il minimo.
    var stretch = 0.0
    var muted = false
    /// 0 rientrata nel bordo, 1 fuori.
    var presence = 0.0
    /// 0 sottile (tasti), 1 larga (puntatore sopra).
    var expansion = 0.0
    /// Il sobbalzo di un tasto: oscilla attorno a zero e si spegne.
    var bump = 0.0
    /// Quanto è allungata la goccia (da 0,2 tonda a 1 pillola intera). Insegue la comparsa con una molla sua, in
    /// ritardo e con un piccolo rimbalzo: si allunga come una gelatina, non come una figura che cambia scala.
    var grow = 0.2
    /// Quanto corre il livello (al secondo): il bordo del bianco si ammorbidisce mentre scorre.
    var speed = 0.0
    /// La forma del vetro: la pillola unita al bordo dello schermo finché il collo non si stacca.
    var outline = Path()
    /// Dove esce il suono, come su iPhone: AirPods, cuffie, HomePod. `nil` = altoparlanti del Mac.
    var outputSymbol: String?
}

enum SideSliderMetrics {
    /// Aria fra la pillola e il bordo dello schermo.
    static let margin: CGFloat = 14
    /// Sottile, ma con il simbolo dentro (carpa: «ovviamente devono avere il simbolo se sono luminosità o suono»).
    static let compact = CGSize(width: 28, height: 158)
    static let wide = CGSize(width: 50, height: 176)
    /// La finestra: larga quanto la pillola aperta più l'aria, alta quanto la pillola più l'elastico ai due capi.
    static let window = CGSize(width: 96, height: 176 + 160)
    /// Il centro della pillola, misurato dall'alto dello schermo: dove su iPhone stanno i tasti del volume.
    static let centerFromTop: CGFloat = 0.32

    static func lerp(_ a: CGFloat, _ b: CGFloat, _ t: Double) -> CGFloat { a + (b - a) * CGFloat(t) }

    static func smooth(_ e0: Double, _ e1: Double, _ x: Double) -> Double {
        let t = min(1, max(0, (x - e0) / (e1 - e0)))
        return t * t * (3 - 2 * t)
    }

    /// Quanto è alta mentre nasce: esce dal bordo come una goccia tonda e si allunga fino alla corsa intera; rientrando
    /// si accorcia di nuovo in goccia prima di essere risucchiata.
    static func grow(_ presence: Double) -> Double { 0.2 + 0.8 * smooth(0.1, 0.78, presence) }

    /// Larghezza e lunghezza della pillola (senza elastico), col sobbalzo e la crescita della goccia. Come un liquido che
    /// conserva il volume: quando la goccia è più corta di dove dovrebbe essere si gonfia ai lati, quando la supera si
    /// stringe (al massimo ±15%), e torna giusta quando la molla si ferma.
    @MainActor static func core(_ m: SideSliderModel) -> (width: CGFloat, height: CGFloat) {
        let bump = max(-0.5, min(0.5, m.bump))
        let full = lerp(compact.height, wide.height, m.expansion) * CGFloat(1 + 0.025 * bump)
        let lag = grow(m.presence) / max(0.2, m.grow)
        let volume = min(1.15, max(0.87, pow(lag, 0.4)))
        let w0 = lerp(compact.width, wide.width, m.expansion) * CGFloat(1 + 0.12 * bump) * CGFloat(volume)
        return (w0, max(w0, full * CGFloat(m.grow)))
    }

    /// La pillola nella finestra (origine in alto a sinistra) per uno stato.
    @MainActor static func pill(_ m: SideSliderModel) -> CGRect {
        let (w0, h0) = core(m)
        // All'elastico si assottiglia più dell'isola (fino al 20%): il bianco, ritagliato dalla pillola, si schiaccia con lei.
        let thin = min(0.2, abs(m.stretch) / Double(h0) * 0.9)
        let w = w0 * CGFloat(1 - thin)
        let top = window.height / 2 - h0 / 2 - CGFloat(max(0, m.stretch))
        // Esce dal bordo: rientrata sta tutta fuori dallo schermo, a sinistra.
        let x = margin - CGFloat(1 - m.presence) * (w + margin + 8)
        return CGRect(x: x, y: top, width: w, height: h0 + CGFloat(abs(m.stretch)))
    }

    /// Il raggio dell'unione morbida fra la pillola e il bordo. Parte da zero (nascosta non c'è niente, nemmeno un
    /// rigonfiamento), cresce mentre la goccia nasce dal bordo, poi cala mentre la pillola si allontana: il collo regge
    /// finché il raggio supera il doppio della distanza dal bordo, si spezza verso l'85% della comparsa e, rientrando,
    /// si riattacca nello stesso punto e viene riassorbito fino a sparire. Prima partiva già al massimo: al primo
    /// fotogramma il bordo era gonfio di 4 punti, e alla fine del rientro spariva di colpo.
    /// Il raggio resta pieno (40) fino all'86% e cala solo nell'ultimo tratto: il collo si tende per una decina di punti
    /// mentre la pillola rallenta verso il suo posto, e si spezza poco prima che si fermi. Prima calava dal 60%: il
    /// collo reggeva solo per 5 punti di strada, pochi fotogrammi, e rientrando non si vedeva affatto.
    static func blend(_ presence: Double) -> Double {
        40 * smooth(0, 0.28, presence) * (1 - smooth(0.86, 1, presence))
    }

    /// Dove arriva il bordo che si gonfia (x del suo lato destro): a riposo appena fuori dallo schermo; all'inizio della
    /// comparsa spinge dentro di 8 punti, come una goccia che preme dal bordo, e poi rientra.
    static func wallRight(_ presence: Double) -> Double {
        -2 + 10 * smooth(0, 0.2, presence) * (1 - smooth(0.3, 0.72, presence))
    }

    /// Il bianco sale dal fondo come un liquido che riempie il vetro, quando la goccia è quasi diventata pillola; rientrando
    /// si svuota per primo, e il bordo risucchia una goccia di solo vetro. Prima entrava in dissolvenza e per qualche
    /// fotogramma era un grigio sporco sopra il vetro.
    static func fillReveal(_ presence: Double) -> Double { smooth(0.55, 0.95, presence) }

    /// Il simbolo entra un poco dopo il bianco e se ne va un poco prima.
    static func symbolOpacity(_ presence: Double) -> Double { smooth(0.62, 0.92, presence) }

    /// Fin dove si traccia il contorno: un po' oltre il bordo dello schermo, dove sta la forma chiusa del bordo.
    /// Basta per la pillola larga mentre esce (sta tutta a sinistra del bordo, più l'aria): con -40 e la pillola
    /// larga il contorno toccava il limite, veniva scartato e la pillola spariva per qualche fotogramma.
    static let traceMinX: Double = -Double(wide.width * 1.15 + margin + 12)

    /// La zona da tracciare: solo dove la goccia può stare. L'unione morbida non va oltre un quarto del raggio dalle
    /// due forme; il bordo che si gonfia è alto 60 punti attorno al centro e all'inizio sta più a destra della pillola.
    /// Tracciare tutta la finestra costava fino a 3,6 ms nella fase del collo.
    static func traceBounds(pill: CGRect, blend: Double, wallRight: Double) -> (minX: Double, minY: Double, maxX: Double, maxY: Double) {
        let reach = blend * 0.25 + 3
        let wallTop = Double(window.height) / 2 - 30, wallBottom = Double(window.height) / 2 + 30
        // Allineata alla griglia di mezzo punto: i campioni cadono negli stessi punti della finestra intera.
        func down(_ v: Double) -> Double { (v * 2).rounded(.down) / 2 }
        func up(_ v: Double) -> Double { (v * 2).rounded(.up) / 2 }
        return (traceMinX,
                max(0, down(min(Double(pill.minY), wallTop) - reach)),
                min(Double(window.width), up(max(Double(pill.maxX), wallRight) + reach)),
                min(Double(window.height), up(max(Double(pill.maxY), wallBottom) + reach)))
    }

    /// La lunghezza della corsa (senza elastico).
    @MainActor static func length(_ m: SideSliderModel) -> CGFloat { core(m).height }

    /// Se un contorno è quello della pillola (col collo finché regge). A collo spezzato il rigonfiamento del bordo resta
    /// un secondo contorno, nascosto appena fuori dallo schermo (sporge al massimo mezzo punto): lasciato nella forma,
    /// il Liquid Glass calcola la lente su tutto l'ingombro, la fa più larga di mezza pillola e le due lenti dei fianchi
    /// si incontrano al centro, con una cucitura verticale a metà del vetro (carpa, 19 novembre 2026: «una linea al
    /// centro come se fosse tagliato a metà il vetro»). Provato su una tavola: basta anche un quadratino lontano nella
    /// stessa forma per spaccarla, e la pillola da sola è pulita come una `Capsule`. La pillola è dentro il suo contorno
    /// (il minimo morbido non è mai più grande della capsula), quindi l'ingombro di quel contorno ne contiene il centro;
    /// il rigonfiamento a collo spezzato sta tutto a sinistra della pillola e non lo contiene.
    static func holdsPill(_ loop: [ContourPoint], _ pill: CGRect) -> Bool {
        var minX = Double.infinity, maxX = -Double.infinity, minY = Double.infinity, maxY = -Double.infinity
        for p in loop {
            minX = min(minX, p.x); maxX = max(maxX, p.x)
            minY = min(minY, p.y); maxY = max(maxY, p.y)
        }
        let cx = Double(pill.midX), cy = Double(pill.midY)
        return minX <= cx && cx <= maxX && minY <= cy && cy <= maxY
    }
}

/// Il campo della goccia: la pillola (una capsula) e un punto del bordo dello schermo (una forma chiusa appena fuori
/// dalla finestra, perché il tracciatore tiene solo i contorni chiusi), uniti con un minimo morbido come le gocce dell'isola.
struct SideSliderField: ScalarField {
    let pill: CGRect
    let blend: Double
    let height: Double
    /// Il lato destro del bordo che si gonfia (vedi `SideSliderMetrics.wallRight`).
    var wallRight = -2.0

    func value(x: Double, y: Double) -> Double {
        let capsule = Self.roundedBox(x - Double(pill.midX), y - Double(pill.midY), Double(pill.width) / 2, Double(pill.height) / 2,
                                      min(Double(pill.width), Double(pill.height)) / 2)
        // Il punto del bordo da cui nasce, come il tasto del volume su iPhone: un rigonfiamento corto appena fuori dalla
        // finestra, all'altezza del centro della pillola. Un muro alto quanto la finestra faceva un velo lungo tutto il
        // fianco (con la cima ondulata) invece di un collo.
        let wall = Self.roundedBox(x - (wallRight - 12), y - height / 2, 12, 30, 12)
        guard blend > 0.0001 else { return min(capsule, wall) }
        let h = max(blend - abs(capsule - wall), 0) / blend
        return min(capsule, wall) - h * h * blend * 0.25
    }

    /// Zero: capsula e rigonfiamento sono distanze vere, e il minimo morbido quadratico ha per pendenza una media pesata
    /// delle loro (pesi fra 0 e 1 che sommano a 1), quindi non cresce mai più in fretta di una distanza. Dichiarare un
    /// quarto del raggio allargava la fascia di ricerca fino a 18 punti nella fase del collo: contorno fino a 4,7 ms.
    var distortion: Double? { 0 }

    static func roundedBox(_ px: Double, _ py: Double, _ hx: Double, _ hy: Double, _ r: Double) -> Double {
        let qx = abs(px) - hx + r
        let qy = abs(py) - hy + r
        return hypot(max(qx, 0), max(qy, 0)) + min(max(qx, qy), 0) - r
    }
}

@MainActor
final class SideSlider {
    static let shared = SideSlider()
    let model = SideSliderModel()

    private var panel: IslandPanel?
    /// Lo Space dell'isola in cui è entrata la finestra (`IslandHub.spaceToken`): se cambia, la finestra si rifà.
    private var panelSpace = 0
    private lazy var clock = FrameClock { [weak self] link in self?.frame(link) }
    private var clockRunning = false
    private var lastTimestamp: CFTimeInterval = 0

    /// Un filo più morbida della molla rapida (0,18): premendo i tasti di fila gli scatti si fondono in un movimento solo.
    private var level = Animated(0.5, spring: Spring(response: 0.24, damping: 1), restDistance: 0.0005, restSpeed: 0.005)
    /// L'elastico, come frazione della corsa. Poco rimbalzo: tornando non deve allungarsi dall'altra parte.
    private var overshoot = Animated(0, spring: Spring(response: 0.32, damping: 0.74), restDistance: 0.0005, restSpeed: 0.005)
    /// Un filo più lenta di prima (0,38): la goccia che nasce, si allunga e si stacca deve avere il tempo di leggersi.
    private var presence = Animated(0, spring: SideSlider.appearSpring, restDistance: 0.001, restSpeed: 0.01)
    private static let appearSpring = Spring(response: 0.46, damping: 0.8)
    /// Rientrando niente rimbalzo e un filo più morbida: la goccia viene risucchiata, non lanciata dentro il bordo.
    private static let hideSpring = Spring(response: 0.5, damping: 0.94)
    /// L'allungamento della goccia, a gelatina (vedi `SideSliderModel.grow`).
    private var growth = Animated(0.2, spring: Spring(response: 0.3, damping: 0.6), restDistance: 0.0005, restSpeed: 0.005)
    /// Il collo col bordo c'era al fotogramma prima: quando si spezza, la pillola trema come una goccia appena staccata.
    private var wasAttached = false
    private var expansion = Animated(0, spring: Spring(response: 0.34, damping: 0.78), restDistance: 0.001, restSpeed: 0.01)
    /// Il sobbalzo di ogni tasto: una spinta su una molla vivace, che oscilla una volta e si ferma.
    private var bump = Animated(0, spring: Spring(response: 0.28, damping: 0.5), restDistance: 0.001, restSpeed: 0.01)
    private let tracer = ContourTracer()
    /// L'ultimo scatto (sedicesimi) toccato trascinando: a ogni scatto nuovo un tic sul trackpad.
    private var lastStep = -1
    /// Fino a quando l'elastico resta tirato (vedi `present`), e quanto: un quinto della corsa, che l'elastico frena a
    /// circa 14 punti. Resta tirato finché il tasto è giù (`keyReleased`), almeno `pullMinimum` perché un tocco rapido
    /// si veda, e al massimo `pullHold` se il rilascio non arriva. La prima ripetizione di un tasto tenuto arriva dopo
    /// circa 0,4 s: con una tirata di 0,16 s la pillola si allungava, tornava e si riallungava.
    private var pullUntil: CFTimeInterval = 0
    private var pullStarted: CFTimeInterval = 0
    private static let pullAmount = 0.2
    private static let pullHold = 0.8
    private static let pullMinimum = 0.14

    private var hideTimer: Timer?
    private var hovering = false
    private(set) var dragging = false
    private var dragStart = 0.0
    /// Il trascinamento è partito davvero (più di due punti): un clic fermo non scrive niente nel sistema.
    private var dragMoved = false
    private var atLimit = false
    /// Lo schermo dove sta la pillola: anche l'orologio dei fotogrammi va preso da lì.
    private var screen: NSScreen?
    private var globalMonitor: Any?
    private var localMonitor: Any?

    /// Quanto resta fuori dopo l'ultimo tasto, e dopo che il puntatore se n'è andato.
    private static let holdAfterKey = 1.5
    private static let holdAfterHover = 0.9

    // MARK: Dai tasti

    /// Un tasto premuto (o il volume cambiato da un'altra app). `kick` è la spinta dell'elastico quando si
    /// preme oltre il limite (frazione della corsa, col segno).
    func present(side: SliderSide, level newLevel: Double, kick: Double = 0, muted: Bool, output: String? = nil) {
        endStaleDrag()
        // Mentre la trascini comanda la mano: gli avvisi del volume che cambia sono i nostri.
        guard !dragging else {
            model.muted = muted
            return
        }
        let hidden = presence.target == 0 && presence.value < 0.05
        // Il righello della giornata sullo stesso bordo si fa da parte: la pillola uscirebbe sopra di lui.
        DayRuler.shared.yieldToSlider()
        if hidden || side != model.side { level.snap(to: newLevel) }
        model.side = side
        model.muted = muted
        model.outputSymbol = side == .volume ? output : nil
        if presence.target != 1 { presence.spring = Self.appearSpring }
        // Già fuori: ogni tasto la fa sobbalzare appena. Alla comparsa no, c'è già la goccia che nasce.
        level.target = newLevel
        if kick != 0 {
            // La molla viene tirata verso l'allungamento per un decimo di secondo e poi lasciata: parte piano, si allunga
            // e torna. Prima si metteva di colpo a 24 punti in un fotogramma (il «saltino brutto» premendo giù col muto
            // o su al massimo), e anche con una spinta secca il primo fotogramma faceva metà della strada. Tenendo
            // premuto al limite ogni ripetizione rinnova la tirata: resta allungata finché non lasci, come su iPhone.
            overshoot.target = kick > 0 ? Self.pullAmount : -Self.pullAmount
            pullStarted = CACurrentMediaTime()
            pullUntil = pullStarted + Self.pullHold * Self.slowMotion
        }
        presence.target = 1
        ensurePanel()
        watchPointer()
        scheduleHide(after: Self.holdAfterKey)
        run()
    }

    /// Il tasto del volume o della luminosità si è alzato: la tirata finisce (dopo il minimo, perché un tocco si veda).
    func keyReleased() {
        guard overshoot.target != 0, !dragging else { return }
        pullUntil = min(pullUntil, max(CACurrentMediaTime(), pullStarted + Self.pullMinimum * Self.slowMotion))
    }

    /// La pillola è fuori, o sta ancora uscendo o rientrando: il righello della giornata non si apre sopra di lei.
    var isOut: Bool { presence.target > 0 || presence.value > 0.02 }

    /// Le funzioni spente: rientra subito.
    func dismiss() {
        presence.spring = Self.hideSpring
        presence.target = 0
        expansion.target = 0
        hideTimer?.invalidate()
        run()
    }

    // MARK: Col puntatore

    func dragBegan() {
        dragging = true
        dragMoved = false
        lastStep = -1
        dragStart = level.target
        atLimit = false
        hideTimer?.invalidate()
    }

    /// Un rilascio perso (la finestra uscita dallo schermo sotto il dito): senza il tasto premuto il trascinamento
    /// è finito, se no `dragging` resterebbe vero e la pillola non tornerebbe più.
    private func endStaleDrag() {
        if dragging, NSEvent.pressedMouseButtons & 1 == 0 { dragEnded() }
    }

    /// `dy` in punti, verso il basso positivo (come SwiftUI).
    func dragChanged(_ dy: CGFloat) {
        if !dragging { dragBegan() }
        if !dragMoved {
            guard abs(dy) > 2 else { return }
            dragMoved = true
        }
        let length = Double(SideSliderMetrics.length(model))
        // Oltre la corsa al massimo di un'altra corsa intera: l'elastico resta dentro la finestra.
        let raw = min(2, max(-1, dragStart - Double(dy) / length))
        let clamped = min(1, max(0, raw))
        level.snap(to: clamped)
        overshoot.snap(to: raw > 1 ? raw - 1 : raw < 0 ? raw : 0)
        // Al limite un tocco netto, come il tic dell'iPhone; in mezzo un tic leggero a ogni sedicesimo (gli scatti dei tasti).
        let limit = raw >= 1 || raw <= 0
        if limit, !atLimit, Appearance.shared.haptics {
            NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
        }
        let step = Int((clamped * 16).rounded())
        if step != lastStep, lastStep >= 0, !limit { Haptics.tick() }
        lastStep = step
        atLimit = limit
        switch model.side {
        case .volume:
            if SystemVolume.muted, clamped > 0 { SystemVolume.muted = false; model.muted = false }
            SystemVolume.level = clamped
        case .brightness:
            SystemBrightness.level = clamped
        }
        run()
    }

    func dragEnded() {
        dragging = false
        overshoot.target = 0
        if !hovering { scheduleHide(after: Self.holdAfterHover) }
        run()
    }

    // MARK: Finestra

    /// All'avvio: la finestra e il suo vetro si creano adesso, non al primo tasto (crearli lì costava fotogrammi proprio
    /// mentre la goccia nasceva). Compare trasparente un istante e torna via.
    func warmUp() {
        ensurePanel()
        guard let panel else { return }
        panel.alphaValue = 0
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.presence.target == 0 else { panel.alphaValue = 1; return }
                panel.orderOut(nil)
                panel.alphaValue = 1
            }
        }
    }

    private func ensurePanel() {
        let screen = IslandHub.shared.primary.flatMap { island in
            NSScreen.screens.first { $0.frame == island.geometry.frame }
        } ?? NSScreen.main ?? NSScreen.screens.first
        guard let screen else { return }
        self.screen = screen
        let size = SideSliderMetrics.window
        let frame = CGRect(x: screen.frame.minX,
                           y: screen.frame.maxY - screen.frame.height * SideSliderMetrics.centerFromTop - size.height / 2,
                           width: size.width, height: size.height)
        if panel == nil || panelSpace != IslandHub.shared.spaceToken {
            // Una finestra rimasta nello Space di prima (isola spenta e riaccesa) non compare
            // più: si rifà.
            panel?.close()
            let panel = IslandPanel(frame: frame)
            let host = FirstMouseHostingView(rootView: SideSliderView(model: model, slider: self))
            host.sizingOptions = []
            host.frame = CGRect(origin: .zero, size: size)
            panel.contentView = host
            // Nello Space dell'isola, prima di comparire: i gesti fra scrivanie non la trascinano via.
            panelSpace = IslandHub.shared.adopt(panel)
            self.panel = panel
        }
        if panel?.frame != frame { panel?.setFrame(frame, display: false) }
        // Solo se non c'è già: riportarla davanti a ogni tasto faceva lavorare il server delle finestre per niente.
        if panel?.isVisible != true { panel?.orderFrontRegardless() }
    }

    /// Il puntatore, finché la pillola è fuori: sopra la pillola si allarga e prende i clic, fuori lascia passare
    /// tutto. Come per l'isola, lo segue un ascolto globale: `onHover` in una finestra che non prende la tastiera
    /// arriva solo ogni tanto.
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
    }

    private func stopWatchingPointer() {
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        globalMonitor = nil
        localMonitor = nil
    }

    private func pointerMoved() {
        endStaleDrag()
        // Mentre la trascini la pillola resta aperta e prende i clic anche se il puntatore scivola fuori.
        guard let panel, !dragging else { return }
        let mouse = NSEvent.mouseLocation
        let pill = SideSliderMetrics.pill(model)
        let screenPill = CGRect(x: panel.frame.minX + pill.minX, y: panel.frame.maxY - pill.maxY,
                                width: pill.width, height: pill.height)
        // Un po' d'aria attorno, più larga quando è già aperta: non si richiude per un pixel.
        let inside = presence.target == 1 && screenPill.insetBy(dx: hovering ? -14 : -8, dy: hovering ? -14 : -8).contains(mouse)
        guard inside != hovering else { return }
        hovering = inside
        panel.ignoresMouseEvents = !inside
        expansion.target = inside ? 1 : 0
        if inside {
            hideTimer?.invalidate()
        } else if !dragging {
            scheduleHide(after: Self.holdAfterHover)
        }
        run()
    }

    private func scheduleHide(after seconds: TimeInterval) {
        hideTimer?.invalidate()
        let timer = Timer(timeInterval: seconds * Self.slowMotion, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.hovering, !self.dragging else { return }
                self.presence.spring = Self.hideSpring
                self.presence.target = 0
                self.expansion.target = 0
                self.run()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        hideTimer = timer
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
            print(String(format: "[lato] fotogramma lungo %.0f ms, fuori=%.2f", (now - lastTimestamp) * 1000, presence.value)); fflush(stdout)
        }
        let dt = (lastTimestamp == 0 ? link.duration : min(now - lastTimestamp, link.duration * 1.25)) / Self.slowMotion
        lastTimestamp = now
        var moving = false
        if overshoot.target != 0, !dragging, CACurrentMediaTime() > pullUntil { overshoot.target = 0 }
        moving = level.step(dt: dt) || moving
        if !dragging { moving = overshoot.step(dt: dt) || moving }
        // Una tirata ancora in corso tiene acceso l'orologio: arrivata e ferma, va comunque lasciata allo scadere.
        if overshoot.target != 0, !dragging { moving = true }
        moving = presence.step(dt: dt) || moving
        growth.target = SideSliderMetrics.grow(presence.value)
        moving = growth.step(dt: dt) || moving
        moving = expansion.step(dt: dt) || moving
        moving = bump.step(dt: dt) || moving
        publish()
        // Il collo appena spezzato dà una spinta al sobbalzo: l'orologio non si ferma proprio adesso.
        moving = moving || !bump.isSettled
        guard !moving else { return }
        clock.stop()
        clockRunning = false
        if presence.value == 0 {
            // Rientrata: la finestra esce dallo schermo e smette di ascoltare il puntatore.
            panel?.orderOut(nil)
            panel?.ignoresMouseEvents = true
            hovering = false
            dragging = false
            stopWatchingPointer()
        }
    }

    private func publish() {
        let length = Double(SideSliderMetrics.lerp(SideSliderMetrics.compact.height, SideSliderMetrics.wide.height, expansion.value))
        model.level = level.value
        model.stretch = RubberBand.offset(overshoot: overshoot.value * length, dimension: length)
        model.presence = presence.value
        model.expansion = expansion.value
        model.bump = bump.value
        model.grow = growth.value
        model.speed = level.velocity
        model.target = level.target
        // La forma del vetro: pillola e bordo uniti finché il collo regge. Si ricalcola solo qui, cioè solo mentre
        // qualcosa si muove: a riposo l'orologio è fermo e il contorno resta quello.
        let traceStart = CACurrentMediaTime()
        let pill = SideSliderMetrics.pill(model)
        let size = SideSliderMetrics.window
        let blend = SideSliderMetrics.blend(presence.value)
        let wallRight = SideSliderMetrics.wallRight(presence.value)
        let field = SideSliderField(pill: pill, blend: blend, height: Double(size.height), wallRight: wallRight)
        // Il collo regge finché il raggio supera il doppio della distanza fra pillola e bordo.
        let attached = blend > 2 * (Double(pill.minX) - wallRight)
        if wasAttached, !attached, presence.target == 1 { bump.velocity = -7 }
        wasAttached = attached
        let zone = SideSliderMetrics.traceBounds(pill: pill, blend: blend, wallRight: wallRight)
        var path = Path()
        for loop in tracer.trace(field, minX: zone.minX, minY: zone.minY, maxX: zone.maxX, maxY: zone.maxY) {
            guard let first = loop.first, SideSliderMetrics.holdsPill(loop, pill) else { continue }
            path.move(to: CGPoint(x: first.x, y: first.y))
            for p in loop.dropFirst() { path.addLine(to: CGPoint(x: p.x, y: p.y)) }
            path.closeSubpath()
        }
        model.outline = path
        if Self.trace {
            print(String(format: "[lato] contorno %.2f ms", (CACurrentMediaTime() - traceStart) * 1000))
            print(String(format: "[lato] %.4f livello=%.3f elastico=%.1f fuori=%.2f larga=%.2f sobbalzo=%.3f", CACurrentMediaTime(),
                         model.level, model.stretch, model.presence, model.expansion, model.bump))
            fflush(stdout)
        }
    }

    private static let trace = ProcessInfo.processInfo.environment["CHARLAND_SLIDER"] != nil
    /// Per le prove: `CHARLAND_LENTO=8` rallenta le molle otto volte, così la goccia si fotografa fotogramma per fotogramma.
    private static let slowMotion = max(1, Double(ProcessInfo.processInfo.environment["CHARLAND_LENTO"] ?? "") ?? 1)
}

/// La pillola. Il vetro trasparente (con la lente sui bordi, come nell'isola) segue la forma della goccia: pillola e
/// collo verso il bordo mentre nasce o rientra. Sopra il vetro un velo scuro tiene il contrasto anche su una pagina
/// bianca e un filo di luce disegna il bordo. Dentro la pillola il bianco sale dal basso col bordo dritto, appena
/// ammorbidito mentre scorre, e il simbolo in fondo diventa scuro dove il bianco lo copre, come su iPhone.
struct SideSliderView: View {
    let model: SideSliderModel
    let slider: SideSlider

    var body: some View {
        let pill = SideSliderMetrics.pill(model)
        let length = SideSliderMetrics.length(model)
        let shownLevel = max(0, min(1, model.side == .volume && model.muted ? 0 : model.level))
        // Il bianco dipende dal livello, non dal segno dell'elastico: rientrando la molla rimbalza oltre lo zero, e
        // letto come «sopra il massimo» quel rimbalzo riempiva di bianco una pillola a volume zero. Al massimo è tutta
        // bianca (anche l'elastico in alto); a metà, se la pillola si allunga in basso, il bianco cresce con lei e il
        // suo bordo resta fermo.
        let reveal = CGFloat(SideSliderMetrics.fillReveal(model.presence))
        let fill: CGFloat = (shownLevel >= 0.999 ? pill.height
            : shownLevel <= 0.001 ? 0
            : CGFloat(shownLevel) * length + CGFloat(max(0, -model.stretch))) * reveal
        // Mentre il livello corre il bordo del bianco si sfuma per qualche punto: il movimento si legge, fermo è netto.
        // Appena percettibile: più forte, a ogni scatto dei tasti il bordo si sfumava e tornava netto, e sembrava tremare.
        let soft = fill == 0 ? 0 : min(2.5, CGFloat(abs(model.speed)) * length * 0.012)
        let outline = OutlineShape(path: model.outline)
        ZStack(alignment: .topLeading) {
            // Il vetro di Charland (`CharlandGlass`): lo stesso dell'isola e della goccia della farfalla.
            CharlandGlassFill(shape: outline)
            content(pill: pill, fill: fill, soft: soft)
        }
        .frame(width: SideSliderMetrics.window.width, height: SideSliderMetrics.window.height, alignment: .topLeading)
        // Un'ombra morbida come su iPhone: sopra una pagina bianca il bordo del bianco si legge lo stesso.
        .shadow(color: .black.opacity(CharlandGlass.shadowOpacity), radius: CharlandGlass.shadowRadius, y: CharlandGlass.shadowY)
        .environment(\.colorScheme, .dark)
    }

    private func content(pill: CGRect, fill: CGFloat, soft: CGFloat) -> some View {
        ZStack(alignment: .bottom) {
            VStack(spacing: 0) {
                LinearGradient(colors: [.white.opacity(0), .white], startPoint: .top, endPoint: .bottom)
                    .frame(height: soft)
                Rectangle().fill(.white).frame(height: fill)
            }
            // Il simbolo occupa tutta la pillola (in fondo): così la maschera del bianco si misura sulla pillola.
            let icon = symbol.frame(width: pill.width, height: pill.height, alignment: .bottom)
            icon.foregroundStyle(.white.opacity(0.92))
            icon.foregroundStyle(Color(white: 0.32))
                .mask(alignment: .bottom) { Rectangle().frame(height: fill) }
        }
        .frame(width: pill.width, height: pill.height)
        .clipShape(Capsule())
        .contentShape(Capsule())
        .gesture(
            // In coordinate della finestra: con l'elastico la pillola si sposta sotto il puntatore, e misurato su di
            // lei il trascinamento tremolava.
            DragGesture(minimumDistance: 0, coordinateSpace: .global)
                .onChanged { value in slider.dragChanged(value.translation.height) }
                .onEnded { _ in slider.dragEnded() }
        )
        .offset(x: pill.minX, y: pill.minY)
    }

    /// Come su iPhone: il sole piccolo sotto metà luminosità e grande sopra; l'altoparlante con le onde che si
    /// accendono col volume, barrato a zero o col muto; le AirPods o le cuffie quando il suono esce da lì.
    private var symbolName: String {
        if model.side == .brightness { return model.target < 0.5 ? "sun.min.fill" : "sun.max.fill" }
        if model.muted || model.target <= 0.001 { return "speaker.slash.fill" }
        return model.outputSymbol ?? "speaker.wave.3.fill"
    }

    private var symbol: some View {
        let name = symbolName
        let waves = model.side == .volume && name == "speaker.wave.3.fill"
        return Image(systemName: name, variableValue: waves ? model.level : nil)
            // Fra un simbolo e l'altro (muto, sole piccolo e grande) si trasforma invece di cambiare di colpo.
            .contentTransition(.symbolEffect(.replace))
            .animation(.snappy(duration: 0.28), value: name)
            .font(.system(size: 17, weight: .semibold))
            // Sempre visibile: piccolo nella pillola sottile, pieno in quella larga; il sole cresce un poco con la luce.
            .scaleEffect((0.7 + 0.3 * model.expansion) * (model.side == .brightness ? 0.92 + 0.12 * model.level : 1), anchor: .bottom)
            .padding(.bottom, 9 + 7 * model.expansion)
            .opacity(SideSliderMetrics.symbolOpacity(model.presence))
    }
}

/// La prova che la fascia stretta non perde pezzi della goccia: per ogni stato (comparsa, larghezza, elastico, sobbalzo)
/// il contorno stretto deve essere identico a quello della griglia intera. `Charland --side-check`.
@MainActor
enum SideSliderCheck {
    struct Hidden: ScalarField {
        let field: SideSliderField
        func value(x: Double, y: Double) -> Double { field.value(x: x, y: y) }
    }

    static func run() -> Bool {
        let fast = ContourTracer(tolerance: 0)
        let full = ContourTracer(coarse: 1, slack: 1000, tolerance: 0)
        let size = SideSliderMetrics.window
        let model = SideSliderModel()
        var checked = 0, wrong = 0, split = 0
        for presence in stride(from: 0.0, through: 1.04, by: 0.02) {
            for expansion in [0.0, 0.5, 1.0] {
                for stretch in [-40.0, 0, 40] {
                    for bump in [0.0, 0.5] {
                      for jelly in [0.85, 1.0, 1.15] {
                        model.grow = min(1.2, SideSliderMetrics.grow(presence) * jelly)
                        model.presence = presence
                        model.expansion = expansion
                        model.stretch = stretch
                        model.bump = bump
                        let pill = SideSliderMetrics.pill(model)
                        let blend = SideSliderMetrics.blend(presence), wallRight = SideSliderMetrics.wallRight(presence)
                        let field = SideSliderField(pill: pill, blend: blend, height: Double(size.height), wallRight: wallRight)
                        // Il tracciato stretto nella stessa zona che usa l'app, quello pieno su tutta la finestra.
                        let zone = SideSliderMetrics.traceBounds(pill: pill, blend: blend, wallRight: wallRight)
                        let a = fast.trace(field, minX: zone.minX, minY: zone.minY, maxX: zone.maxX, maxY: zone.maxY)
                        let b = full.trace(Hidden(field: field), minX: SideSliderMetrics.traceMinX, minY: 0, maxX: Double(size.width), maxY: Double(size.height))
                        checked += 1
                        if a != b {
                            wrong += 1
                            print("diverso: comparsa \(presence), larga \(expansion), elastico \(stretch), sobbalzo \(bump), gelatina \(jelly)")
                        }
                        // Il vetro prende un contorno solo, sempre quello della pillola: nessun fotogramma senza vetro e
                        // nessun rigonfiamento nascosto che allarga la lente (la cucitura a metà del 19 novembre).
                        let kept = a.filter { SideSliderMetrics.holdsPill($0, pill) }.count
                        if kept != 1 {
                            wrong += 1
                            print("contorni tenuti \(kept) di \(a.count): comparsa \(presence), larga \(expansion), elastico \(stretch), sobbalzo \(bump), gelatina \(jelly)")
                        }
                        if a.count > 1 { split += 1 }
                      }
                    }
                }
            }
        }
        print("goccia: \(checked) stati, \(wrong) diversi (\(split) col rigonfiamento staccato, tolto dal vetro)")
        return wrong == 0
    }
}
