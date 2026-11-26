import AppKit
import SwiftUI
import CharlandCore

/// Il righello della giornata sul bordo dello schermo (Impostazioni › Righello). Chiuso è una tacca sottile a metà del
/// bordo, come un notch girato di lato (la forma della vecchia linguetta degli agenti, che carpa aveva voluto «molto più
/// sottile»); spingendo il puntatore contro il bordo lì vicino la tacca si allunga e si gonfia fino al pannello, e dentro
/// compaiono le ore di oggi con gli impegni al loro posto e la linea dell'ora di adesso. Tolto il puntatore torna tacca.
///
/// Esce sullo schermo dove arriva il puntatore, purché quel bordo sia un bordo vero (nessuno schermo accanto da quella
/// parte). Niente timer da chiuso: costa solo un ascolto del puntatore, come l'isola e la pillola del volume.
@MainActor @Observable
final class DayRulerModel {
    /// 0 tacca, 1 aperto.
    var expansion = 0.0
    var outline = Path()
    /// La forma di adesso: dove sta nella finestra (origine in alto a sinistra).
    var panelRect: CGRect = .zero
    var side: RulerSide = .left
    var tabVisible = true
    var window = CGSize(width: 340, height: 640)
    var panel = CGSize(width: RulerMetrics.contentWidth, height: 520)
    var day = RulerDay.empty
    var now = Date()
}

enum RulerMetrics {
    /// I contenuti, e il labbro di vetro pulito oltre i contenuti dal lato dello schermo (come sotto l'isola).
    static let contentWidth: CGFloat = 292
    static let lip: CGFloat = 18
    static var shapeWidth: CGFloat { contentWidth + lip }
    /// Chiuso: un notch girato di lato, sottilissimo.
    static let tab = CGSize(width: 5, height: 76)
    static let openCorner: CGFloat = 26
    static let pad: CGFloat = 16
    /// Lo spazio della finestra oltre la forma aperta, per l'elastico della forma, le orecchie e l'ombra.
    static let room: CGFloat = 30
    /// La fascia del bordo che apre: alta così, centrata a metà schermo.
    static let triggerHeight: CGFloat = 220

    static func smooth(_ e0: Double, _ e1: Double, _ x: Double) -> Double {
        let t = min(1, max(0, (x - e0) / (e1 - e0)))
        return t * t * (3 - 2 * t)
    }

    static func lerp(_ a: CGFloat, _ b: CGFloat, _ t: Double) -> CGFloat { a + (b - a) * CGFloat(t) }

    /// Il raggio degli angoli verso lo schermo e quello delle orecchie concave contro il bordo, come il notch.
    static func corner(_ e: Double) -> CGFloat { lerp(2.5, openCorner, smooth(0, 1, e)) }
    static func flare(_ e: Double) -> CGFloat { lerp(4, 12, smooth(0, 1, e)) }

    /// I contenuti entrano a forma quasi fatta e se ne vanno per primi.
    static func contentOpacity(_ e: Double) -> Double { smooth(0.74, 1, e) }

    /// Quanto è alto il pannello aperto su uno schermo: la parte scelta dello schermo, dentro lo spazio libero.
    static func panelHeight(on screen: NSScreen, _ height: RulerHeight) -> CGFloat {
        let usable = screen.visibleFrame.height - 24
        return min(usable, max(380, (screen.frame.height * height.fraction).rounded()))
    }

    static func window(panelHeight: CGFloat) -> CGSize {
        CGSize(width: shapeWidth + room, height: (panelHeight * 1.1).rounded() + room * 2)
    }

    /// La forma, attaccata al bordo sinistro della finestra (x = 0): un rettangolo che entra oltre il bordo con gli
    /// angoli verso lo schermo arrotondati, più le due orecchie concave dove incontra il bordo (un quadrato meno un
    /// cerchio, come nell'isola). Per il bordo destro si specchia.
    static func path(width w: CGFloat, height h: CGFloat, centerY cy: CGFloat, corner: CGFloat, flare: CGFloat) -> Path {
        let r = max(0, min(corner, w / 2, h / 2))
        let f = max(0, min(flare, w - r))
        let top = cy - h / 2, bottom = cy + h / 2
        let outside: CGFloat = -24
        var p = Path()
        p.move(to: CGPoint(x: outside, y: top - f))
        p.addLine(to: CGPoint(x: 0, y: top - f))
        if f > 0.01 {
            p.addArc(tangent1End: CGPoint(x: 0, y: top), tangent2End: CGPoint(x: w, y: top), radius: f)
        } else {
            p.addLine(to: CGPoint(x: 0, y: top))
        }
        p.addArc(tangent1End: CGPoint(x: w, y: top), tangent2End: CGPoint(x: w, y: bottom), radius: r)
        p.addArc(tangent1End: CGPoint(x: w, y: bottom), tangent2End: CGPoint(x: 0, y: bottom), radius: r)
        if f > 0.01 {
            p.addArc(tangent1End: CGPoint(x: 0, y: bottom), tangent2End: CGPoint(x: 0, y: bottom + f), radius: f)
        } else {
            p.addLine(to: CGPoint(x: 0, y: bottom))
        }
        p.addLine(to: CGPoint(x: 0, y: bottom + f))
        p.addLine(to: CGPoint(x: outside, y: bottom + f))
        p.closeSubpath()
        return p
    }
}

@MainActor
final class DayRuler {
    static let shared = DayRuler()
    let model = DayRulerModel()

    private var panel: IslandPanel?
    /// Lo Space dell'isola in cui è entrata la finestra (`IslandHub.spaceToken`): se cambia, la finestra si rifà.
    private var panelSpace = 0
    private var screen: NSScreen?
    private lazy var clock = FrameClock { [weak self] link in self?.frame(link) }
    private var clockRunning = false
    private var lastTimestamp: CFTimeInterval = 0

    /// In larghezza subito, in altezza a gelatina: si allunga come una goccia, non cambia scala.
    private var expansion = Animated(0, spring: DayRuler.widthSpring, restDistance: 0.001, restSpeed: 0.01)
    private var tall = Animated(0, spring: DayRuler.heightSpring, restDistance: 0.001, restSpeed: 0.01)
    private static let widthSpring = Spring(response: 0.42, damping: 0.8)
    private static let heightSpring = Spring(response: 0.36, damping: 0.7)
    /// Riduci movimento: niente elastico, la forma arriva e basta.
    private static let calmSpring = Spring(response: 0.28, damping: 1)

    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var hovering = false
    /// Aperto da Impostazioni › Prova: non si richiude subito perché il puntatore è altrove.
    private var previewing = false
    private var closeTimer: Timer?
    private var dwellTimer: Timer?
    private var minuteTimer: Timer?
    private var screenObserver: NSObjectProtocol?
    private var started = false
    private var enabled = false
    /// La giornata è cambiata mentre la forma si muoveva: si mette quando si ferma (ridisegnare tutto il pannello a metà
    /// apertura faceva un fotogramma lungo nella linguetta degli agenti).
    private var pendingData = false

    private var settings: RulerSettings { .shared }

    var isOpen: Bool { hovering }

    // MARK: Vita

    func start() {
        started = true
        apply()
        if ProcessInfo.processInfo.environment["CHARLAND_RIGHELLO_APERTO"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { DayRuler.shared.preview(hold: 30) }
        }
    }

    func stop() {
        started = false
        setEnabled(false)
    }

    /// Acceso se l'app è partita, l'interruttore è acceso e la prova non è finita.
    func apply() {
        setEnabled(started && settings.enabled)
    }

    private func setEnabled(_ on: Bool) {
        guard on != enabled else { return }
        enabled = on
        if on {
            DayRulerStore.shared.start()
            model.day = DayRulerStore.shared.day
            placeHome()
            watchPointer()
            // Schermi collegati, staccati, risoluzione cambiata: torna sul bordo giusto.
            screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                                                    object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { DayRuler.shared.layoutChanged() }
            }
        } else {
            stopWatchingPointer()
            if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
            screenObserver = nil
            closeTimer?.invalidate(); closeTimer = nil
            dwellTimer?.invalidate(); dwellTimer = nil
            minuteTimer?.invalidate(); minuteTimer = nil
            clock.stop()
            clockRunning = false
            hovering = false
            previewing = false
            pendingData = false
            expansion.snap(to: 0)
            tall.snap(to: 0)
            panel?.ignoresMouseEvents = true
            panel?.orderOut(nil)
            DayRulerStore.shared.stop()
        }
    }

    /// Lato, altezza o tacca cambiati (o gli schermi): si chiude subito e si rimette a posto.
    func layoutChanged() {
        guard enabled else { return }
        closeTimer?.invalidate(); closeTimer = nil
        dwellTimer?.invalidate(); dwellTimer = nil
        minuteTimer?.invalidate(); minuteTimer = nil
        hovering = false
        previewing = false
        clock.stop()
        clockRunning = false
        expansion.snap(to: 0)
        tall.snap(to: 0)
        placeHome()
    }

    /// Le ore da mostrare sono cambiate: le legge la vista, basta ridisegnare (lo fa già da sola).
    func contentChanged() {}

    /// La giornata letta è cambiata.
    func dataChanged() {
        guard enabled else { return }
        if clockRunning {
            pendingData = true
        } else if model.day != DayRulerStore.shared.day {
            model.day = DayRulerStore.shared.day
        }
    }

    /// La pillola del volume o della luminosità esce dallo stesso bordo: il righello rientra.
    func yieldToSlider() {
        guard hovering, settings.side == .left else { return }
        close()
    }

    /// Impostazioni › Prova: esce sullo schermo della finestra delle impostazioni e rientra da solo dopo qualche secondo,
    /// se il puntatore non ci va sopra.
    func preview(hold: Double = 4) {
        guard enabled else { return }
        let window = NSApp.windows.first { $0.isVisible && $0.isKeyWindow } ?? NSApp.windows.first { $0.isVisible && !($0 is NSPanel) }
        let target = window?.screen ?? homeScreen
        guard let target else { return }
        previewing = true
        open(on: target)
        closeTimer?.invalidate()
        let timer = Timer(timeInterval: hold, repeats: false) { _ in
            MainActor.assumeIsolated {
                let ruler = DayRuler.shared
                ruler.closeTimer = nil
                guard ruler.previewing else { return }
                ruler.previewing = false
                if !ruler.pointerInsideOpen(NSEvent.mouseLocation) { ruler.close() }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        closeTimer = timer
    }

    /// Dopo un clic su un impegno o un pulsante: il righello rientra mentre si apre l'app.
    func closeAfterAction() {
        guard hovering else { return }
        close()
    }

    // MARK: Finestra

    /// Lo schermo di casa: quello dell'isola principale (col notch), dove sta la tacca da chiuso.
    private var homeScreen: NSScreen? {
        IslandHub.shared.primary.flatMap { island in NSScreen.screens.first { $0.frame == island.geometry.frame } }
            ?? NSScreen.main ?? NSScreen.screens.first
    }

    private func placeHome() {
        model.side = settings.side
        model.tabVisible = settings.tabVisible
        guard let home = homeScreen else { return }
        screen = home
        ensurePanel()
        publish()
        panel?.ignoresMouseEvents = true
        if settings.tabVisible {
            if panel?.isVisible != true { panel?.orderFrontRegardless() }
        } else {
            panel?.orderOut(nil)
        }
    }

    private func ensurePanel() {
        guard let screen else { return }
        let panelHeight = RulerMetrics.panelHeight(on: screen, settings.height)
        let size = RulerMetrics.window(panelHeight: panelHeight)
        let x = settings.side == .left ? screen.frame.minX : screen.frame.maxX - size.width
        let frame = CGRect(x: x, y: (screen.frame.midY - size.height / 2).rounded(), width: size.width, height: size.height)
        model.side = settings.side
        if model.window != size { model.window = size }
        let content = CGSize(width: RulerMetrics.contentWidth, height: panelHeight)
        if model.panel != content { model.panel = content }
        if panel == nil || panelSpace != IslandHub.shared.spaceToken {
            // Una finestra rimasta nello Space di prima (isola spenta e riaccesa) non compare
            // più: si rifà.
            panel?.close()
            let panel = IslandPanel(frame: frame)
            let host = FirstMouseHostingView(rootView: DayRulerView(model: model))
            host.sizingOptions = []
            host.frame = CGRect(origin: .zero, size: size)
            host.autoresizingMask = [.width, .height]
            panel.contentView = host
            // Nello Space dell'isola, prima di comparire: i gesti fra scrivanie non la trascinano via.
            panelSpace = IslandHub.shared.adopt(panel)
            self.panel = panel
        }
        if panel?.frame != frame { panel?.setFrame(frame, display: false) }
    }

    // MARK: Puntatore

    /// Un ascolto globale, come per l'isola e gli slider: `onHover` in una finestra che non prende la tastiera arriva
    /// solo ogni tanto.
    private func watchPointer() {
        guard globalMonitor == nil else { return }
        let mask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged]
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { _ in
            MainActor.assumeIsolated { DayRuler.shared.pointerMoved() }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { event in
            MainActor.assumeIsolated { DayRuler.shared.pointerMoved() }
            return event
        }
    }

    private func stopWatchingPointer() {
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        globalMonitor = nil
        localMonitor = nil
    }

    /// La fascia che apre su uno schermo: stretta contro il bordo (il puntatore ci arriva solo spinto fino in fondo),
    /// a metà altezza.
    private func trigger(on screen: NSScreen) -> CGRect {
        let band: CGFloat = settings.tabVisible ? RulerMetrics.tab.width + 3 : 3
        let h = RulerMetrics.triggerHeight
        let x = settings.side == .left ? screen.frame.minX : screen.frame.maxX - band
        return CGRect(x: x, y: screen.frame.midY - h / 2, width: band, height: h)
    }

    /// Il bordo è vero: da quella parte, a quell'altezza, non c'è un altro schermo dove il puntatore passerebbe.
    private func freeEdge(_ screen: NSScreen, y: CGFloat) -> Bool {
        let probe = settings.side == .left ? CGPoint(x: screen.frame.minX - 1, y: y) : CGPoint(x: screen.frame.maxX + 1, y: y)
        return !NSScreen.screens.contains { $0 != screen && $0.frame.contains(probe) }
    }

    /// Lo schermo dove il puntatore sta spingendo contro il bordo del righello, se c'è.
    private func triggeringScreen(_ mouse: CGPoint) -> NSScreen? {
        NSScreen.screens.first { trigger(on: $0).contains(mouse) && freeEdge($0, y: mouse.y) }
    }

    /// Aperto, la zona che lo tiene aperto: la forma intera, labbro compreso, più un margine.
    private func pointerInsideOpen(_ mouse: CGPoint) -> Bool {
        guard let panel else { return false }
        let f = panel.frame
        let w = RulerMetrics.shapeWidth, h = model.panel.height
        let x = settings.side == .left ? f.minX : f.maxX - w - 16
        return CGRect(x: x, y: f.midY - h / 2 - 16, width: w + 16, height: h + 32).contains(mouse)
    }

    private func pointerMoved() {
        guard enabled else { return }
        let mouse = NSEvent.mouseLocation
        if hovering, let panel {
            // Aperto, la finestra prende i clic solo sopra il pannello: attorno lascia passare tutto.
            let f = panel.frame, r = model.panelRect
            let overPanel = CGRect(x: f.minX + r.minX, y: f.maxY - r.maxY, width: r.width, height: r.height).contains(mouse)
            if panel.ignoresMouseEvents == overPanel { panel.ignoresMouseEvents = !overPanel }
            if pointerInsideOpen(mouse) {
                previewing = false
                closeTimer?.invalidate()
                closeTimer = nil
            } else if !previewing, closeTimer == nil {
                let timer = Timer(timeInterval: 0.35, repeats: false) { _ in
                    MainActor.assumeIsolated {
                        let ruler = DayRuler.shared
                        ruler.closeTimer = nil
                        // Se nel frattempo il puntatore è tornato dentro, resta aperto.
                        if !ruler.pointerInsideOpen(NSEvent.mouseLocation) { ruler.close() }
                    }
                }
                RunLoop.main.add(timer, forMode: .common)
                closeTimer = timer
            }
            return
        }
        guard triggeringScreen(mouse) != nil else {
            dwellTimer?.invalidate()
            dwellTimer = nil
            return
        }
        // Non si apre trascinando (una barra di scorrimento, un file, il bordo di una finestra), né sopra la pillola del
        // volume che esce dallo stesso bordo; e serve un attimo di sosta, non un passaggio.
        guard dwellTimer == nil, NSEvent.pressedMouseButtons == 0,
              settings.side == .right || !SideSlider.shared.isOut else { return }
        // Intanto si legge la giornata: quando si apre è già pronta.
        DayRulerStore.shared.refresh()
        let timer = Timer(timeInterval: settings.delay.seconds, repeats: false) { _ in
            MainActor.assumeIsolated {
                let ruler = DayRuler.shared
                ruler.dwellTimer = nil
                guard ruler.enabled, !ruler.hovering, NSEvent.pressedMouseButtons == 0,
                      let target = ruler.triggeringScreen(NSEvent.mouseLocation) else { return }
                ruler.open(on: target)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        dwellTimer = timer
    }

    // MARK: Aprire e chiudere

    private func open(on target: NSScreen) {
        if screen != target || panel == nil || panelSpace != IslandHub.shared.spaceToken {
            screen = target
            if !clockRunning {
                // Su un altro schermo si riparte dalla tacca.
                expansion.snap(to: 0)
                tall.snap(to: 0)
            }
        }
        ensurePanel()
        if !clockRunning, model.day != DayRulerStore.shared.day {
            model.day = DayRulerStore.shared.day
            pendingData = false
        }
        model.now = Date()
        publish()
        if panel?.isVisible != true { panel?.orderFrontRegardless() }
        hovering = true
        panel?.ignoresMouseEvents = false
        let calm = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        expansion.spring = calm ? Self.calmSpring : Self.widthSpring
        tall.spring = calm ? Self.calmSpring : Self.heightSpring
        expansion.target = 1
        tall.target = 1
        Haptics.tick()
        DayRulerStore.shared.refresh()
        startMinuteTimer()
        run()
    }

    private func close() {
        closeTimer?.invalidate()
        closeTimer = nil
        hovering = false
        previewing = false
        panel?.ignoresMouseEvents = true
        expansion.target = 0
        tall.target = 0
        minuteTimer?.invalidate()
        minuteTimer = nil
        run()
    }

    /// Aperto, la linea dell'ora scorre: un controllo ogni dieci secondi, che ridisegna solo quando cambia il minuto.
    private func startMinuteTimer() {
        minuteTimer?.invalidate()
        let timer = Timer(timeInterval: 10, repeats: true) { _ in
            MainActor.assumeIsolated {
                let ruler = DayRuler.shared
                let now = Date()
                let calendar = Calendar.current
                guard !calendar.isDate(now, equalTo: ruler.model.now, toGranularity: .minute) else { return }
                if !calendar.isDate(now, inSameDayAs: ruler.model.now) { DayRulerStore.shared.refresh() }
                if !ruler.clockRunning { ruler.model.now = now }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        minuteTimer = timer
    }

    /// La forma si è fermata chiusa: senza tacca la finestra sparisce, e se era uscita su un altro schermo torna a casa.
    private func settledClosed() {
        guard !hovering else { return }
        if !settings.tabVisible {
            panel?.orderOut(nil)
        }
        if let home = homeScreen, screen != home {
            screen = home
            ensurePanel()
            publish()
        }
    }

    // MARK: Fotogrammi

    private func run() {
        guard !clockRunning else { return }
        clockRunning = true
        lastTimestamp = 0
        clock.start(on: screen)
    }

    private static let traceFrames = ProcessInfo.processInfo.environment["CHARLAND_FOTOGRAMMI"] != nil
    private var frames = 0
    private var slowFrames = 0

    private func frame(_ link: CADisplayLink) {
        let now = link.targetTimestamp
        if Self.traceFrames, lastTimestamp != 0, now - lastTimestamp > link.duration * 1.5 {
            slowFrames += 1
            print(String(format: "[righello] %.0f ms, aperto %.2f verso %.0f", (now - lastTimestamp) * 1000, expansion.value,
                         expansion.target)); fflush(stdout)
        }
        let dt = lastTimestamp == 0 ? link.duration : min(now - lastTimestamp, link.duration * 1.25)
        lastTimestamp = now
        var moving = expansion.step(dt: dt)
        moving = tall.step(dt: dt) || moving
        publish()
        if Self.traceFrames { frames += 1 }
        guard !moving else { return }
        clock.stop()
        clockRunning = false
        if Self.traceFrames {
            print("[righello] fermo \(hovering ? "aperto" : "chiuso"): \(frames) fotogrammi, \(slowFrames) in ritardo"); fflush(stdout)
            frames = 0
            slowFrames = 0
        }
        if pendingData {
            pendingData = false
            if model.day != DayRulerStore.shared.day { model.day = DayRulerStore.shared.day }
        }
        if hovering {
            let now = Date()
            if !Calendar.current.isDate(now, equalTo: model.now, toGranularity: .minute) { model.now = now }
        } else {
            settledClosed()
        }
    }

    private func publish() {
        let size = model.window
        let e = expansion.value
        let tab = RulerMetrics.tab
        let w = RulerMetrics.lerp(tab.width, RulerMetrics.shapeWidth, RulerMetrics.smooth(0, 1, e))
        let h = max(w, RulerMetrics.lerp(tab.height, model.panel.height, tall.value))
        let centerY = size.height / 2
        var path = RulerMetrics.path(width: w, height: h, centerY: centerY, corner: RulerMetrics.corner(e),
                                     flare: RulerMetrics.flare(e))
        let left = settings.side == .left
        if !left { path = path.applying(CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: size.width, ty: 0)) }
        model.outline = path
        model.expansion = e
        model.panelRect = CGRect(x: left ? 0 : size.width - w, y: centerY - h / 2, width: w, height: h)
    }
}
