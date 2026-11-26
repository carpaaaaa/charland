import AppKit
import SwiftUI
import QuartzCore
import CharlandCore

/// Il motore dell'isola su uno schermo: riceve gli eventi, fa avanzare le molle a ogni
/// fotogramma e pubblica il risultato. Il display link gira solo mentre qualcosa si muove:
/// a riposo non c'è nessun timer acceso.
@MainActor
final class IslandEngine: NSObject {
    let model: IslandModel
    private(set) var state = IslandState()
    private var motion: IslandMotion
    private let tracer = ContourTracer()
    private var link: CADisplayLink?
    private weak var hostView: NSView?
    private var lastTimestamp: CFTimeInterval = 0
    private var deadlineTimer: Timer?
    /// Chiamata quando cambia lo stato dell'isola (compatto, espanso, riposo).
    var onModeChange: ((IslandMode) -> Void)?
    /// Chiamata a ogni fotogramma con la goccia in volo (o `nil`), per il velo a tutto schermo.
    var onDrip: ((DripState?) -> Void)?
    /// Statistiche dei fotogrammi, per le misure.
    private(set) var stats = FrameStats()
    var recorder: MotionRecorder?

    struct FrameStats {
        var frames = 0
        var publishes = 0
        var skipped = 0
        var worstInterval: Double = 0
        var late = 0
        var traceSeconds: Double = 0
        var lateMoments: [String] = []
        var start = CACurrentMediaTime()
        mutating func reset() { self = FrameStats() }
    }

    init(model: IslandModel) {
        self.model = model
        motion = IslandMotion(metrics: model.metrics)
        super.init()
    }

    func attach(to view: NSView) {
        hostView = view
    }

    /// La casa: quello che si apre passando sopra il notch senza attività.
    func setHome(_ activity: IslandActivity, content: ActivityContent) {
        state.setHome(activity)
        model.contents[activity.id] = content
    }

    /// Aggiorna il contenuto della casa (giorno, batteria, attività in corso) prima di aprirla.
    func refreshHome(_ content: ActivityContent) {
        model.contents[IslandState.homeID] = content
        state.setHome(Home.current)
    }

    /// Con la casa aperta, le attività che arrivano o finiscono si vedono subito nelle sue pillole, e il vassoio che si
    /// riempie o si svuota ne cambia l'altezza (carpa, 22 novembre 2026: tolti i file le tessere salivano e nel notch
    /// restava uno spazio vuoto).
    func refreshOpenHome() {
        guard model.expandedID == IslandState.homeID else { return }
        refreshHome(.home(HomeInfo.now()))
        refresh()
    }

    /// Cosa apre il puntatore: la casa o l'attività in corso (l'impostazione «Passando sopra apri l'attività in corso»).
    func setHoverOpensActivity(_ on: Bool) {
        if state.hoverOpensActivity != on { state.hoverOpensActivity = on }
    }

    /// Con qualcosa in riproduzione passando sopra si apre lei invece della casa (`nil`: opzione spenta).
    func setPlaybackID(_ id: String?) {
        if state.playbackID != id { state.playbackID = id }
    }

    /// Le altre attività come pillole dentro quella aperta. Cambiata con l'isola aperta, la forma si rifà subito.
    func setShowsOthers(_ on: Bool) {
        guard state.showsOthers != on else { return }
        state.showsOthers = on
        refresh()
    }

    var mode: IslandMode { state.mode }
    var isMoving: Bool { link != nil }
    /// Il puntatore è sopra l'isola.
    var pointerInside: Bool { state.pointerInside }

    // MARK: Eventi

    func send(_ event: IslandEvent) {
        let now = CACurrentMediaTime()
        if Self.traceFrames, "\(event)" != "tick" { print("[evento] \(event)".prefix(120)); fflush(stdout) }
        let before = state.mode
        state.handle(event, now: now)
        applyMode()
        scheduleDeadline()
        if state.mode != before { onModeChange?(state.mode) }
    }

    /// Aggiorna o crea un'attività con il suo contenuto.
    func show(_ activity: IslandActivity, content: ActivityContent) {
        model.contents[activity.id] = content
        send(.started(activity))
        refreshOpenHome()
    }

    func update(id: String, content: ActivityContent) {
        guard model.contents[id] != nil else { return }
        model.contents[id] = content
        refreshOpenHome()
    }

    func end(id: String) {
        send(.ended(id: id))
        refreshOpenHome()
        // Il contenuto resta finché la sua uscita non è finita: lo toglie `publish`.
    }

    func setVoiceLevel(_ level: Double) {
        model.voiceLevel = level
        // Il bordo basso respira appena con la voce: al massimo un punto e mezzo.
        motion.setWave(amplitude: min(1.5, level * 1.5))
        startLink()
    }

    /// Aggiorna lo slider. Oltre i limiti l'isola si allunga insieme alla pillola.
    func setSlider(_ slider: SliderState) {
        model.slider = slider
        let length = IslandTuning().sliderLength
        let stretch = abs(RubberBand.offset(overshoot: slider.overshoot * length, dimension: length))
        motion.setEdgeStretch(left: slider.side == .brightness ? stretch : 0, right: slider.side == .volume ? stretch : 0)
        startLink()
    }

    func setPressed(_ pressed: Bool) {
        motion.setPressed(pressed)
        startLink()
    }

    /// Fa colare la goccia verso un punto dello schermo (coordinate AppKit, origine in basso).
    func startDrip(toScreenPoint point: CGPoint, screenFrame: CGRect, notchCenterX: CGFloat) {
        let x = Double(point.x - notchCenterX)
        let y = Double(screenFrame.maxY - point.y)
        motion.startDrip(toX: x, toY: y)
        startLink()
    }

    private func applyMode() {
        let appearance = Appearance.shared
        motion.calm = appearance.calm
        var tuning = IslandTuning()
        tuning.glassLip = appearance.look == .blackGlass ? 30 : 0
        motion.tuning = tuning
        motion.apply(state.mode, state: state)
        if case .expanded(let id) = state.mode {
            if model.expandedID != id { model.expandedID = id; model.resolveHover() }
        } else if model.expandedID != nil {
            model.expandedID = nil
            model.resolveHover()
        }
        model.isVisible = true
        startLink()
    }

    /// Riapplica lo stato corrente dopo un cambio di regolazioni.
    func refresh() {
        applyMode()
    }

    private func scheduleDeadline() {
        deadlineTimer?.invalidate()
        deadlineTimer = nil
        guard let deadline = state.nextDeadline else { return }
        let delay = max(0.01, deadline - CACurrentMediaTime())
        let timer = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.send(.tick) }
        }
        RunLoop.main.add(timer, forMode: .common)
        deadlineTimer = timer
    }

    // MARK: Fotogrammi

    private func startLink() {
        if link != nil {
            idleFrames = 0
            needsPublish = true
            return
        }
        guard let view = hostView else {
            publish(moving: motion.isMoving)
            return
        }
        let link = view.displayLink(target: self, selector: #selector(tick(_:)))
        link.add(to: .main, forMode: .common)
        self.link = link
        lastTimestamp = 0
        idleFrames = 0
        // Niente disegno qui: il primo passo arriva al prossimo fotogramma e disegna lui.
        // Disegnare anche adesso voleva dire due disegni nello stesso fotogramma.
    }

    /// Fotogrammi consecutivi senza movimento: dopo mezzo secondo l'orologio si spegne.
    /// Così uno slider che scorre o la voce che arriva a scatti non lo accendono e spengono di continuo.
    private var idleFrames = 0
    private static let idleGrace = 30

    private func stopLink() {
        link?.invalidate()
        link = nil
    }

    @objc private func tick(_ link: CADisplayLink) {
        // Il tempo del fotogramma che verrà mostrato, non di quello appena passato.
        let now = link.targetTimestamp
        let dt = lastTimestamp == 0 ? link.duration : now - lastTimestamp
        // A volte la stessa schermata chiama due volte: il secondo giro non mostrerebbe niente di nuovo.
        if lastTimestamp != 0, dt < link.duration * 0.25 {
            stats.skipped += 1
            return
        }
        if lastTimestamp != 0 {
            stats.frames += 1
            stats.worstInterval = max(stats.worstInterval, dt)
            if dt > link.duration * 1.5 {
                stats.late += 1
                stats.lateMoments.append(String(format: "%.0f ms a %.2f s, %@", dt * 1000, now - stats.start, "\(state.mode)"))
                // Con CHARLAND_FOTOGRAMMI ogni fotogramma in ritardo si scrive subito: per misurare dal vivo.
                if Self.traceFrames { print(String(format: "[fotogramma] %.0f ms, %@", dt * 1000, "\(state.mode)")); fflush(stdout) }
            }
        }
        lastTimestamp = now
        // Un fotogramma arrivato in ritardo non fa saltare l'animazione in avanti: avanza di un
        // passo normale. Un istante di rallentamento non si vede, uno scatto sì.
        let moving = motion.step(dt: min(dt, link.duration * 1.25))
        if moving || idleFrames == 0 || needsPublish {
            // Si disegna mentre si muove, e una volta ancora quando si ferma (l'ultimo fotogramma esatto).
            publish(moving: moving)
            needsPublish = false
        }
        if moving {
            idleFrames = 0
        } else {
            idleFrames += 1
            if idleFrames > Self.idleGrace { stopLink() }
        }
    }

    /// Un cambiamento arrivato mentre l'orologio era acceso ma fermo: va disegnato al prossimo passo.
    private var needsPublish = false

    /// Avanza a mano, senza schermo: per i test, gli scatti e le misure.
    func advance(by dt: Double) {
        let moving = motion.step(dt: dt)
        publish(moving: moving)
    }

    private func publish(moving: Bool) {
        stats.publishes += 1
        let frame = motion.frame
        let resting = state.mode == .rest && !moving
        model.frame = frame
        if resting {
            model.outline = Path()
            model.isVisible = false
            // A riposo si liberano i contenuti delle attività finite.
            var alive = Set(state.activities.map(\.id))
            alive.insert(IslandState.homeID)
            // Solo se c'è davvero qualcosa da togliere: riscriverlo comunque ridisegnava tutti i contenuti.
            if model.contents.keys.contains(where: { !alive.contains($0) }) {
                model.contents = model.contents.filter { alive.contains($0.key) }
            }
        } else {
            let start = CACurrentMediaTime()
            model.outline = outline(for: frame.shape)
            stats.traceSeconds += CACurrentMediaTime() - start
        }
        onDrip?(frame.drip)
        recorder?.record(frame, at: CACurrentMediaTime())
    }

    private func outline(for shape: IslandShape) -> Path {
        let loops = tracer.trace(shape)
        let ox = Double(model.originX)
        var path = Path()
        for loop in loops {
            guard let first = loop.first else { continue }
            path.move(to: CGPoint(x: ox + first.x, y: first.y))
            for p in loop.dropFirst() {
                path.addLine(to: CGPoint(x: ox + p.x, y: p.y))
            }
            path.closeSubpath()
        }
        return path
    }

    /// L'attività della goccia staccata sotto il puntatore (coordinate della finestra, origine in alto), se ce n'è una.
    /// Si guarda la forma di arrivo, come per `hitTest`, con un margine di qualche punto attorno alla goccia.
    func dropUnder(_ point: CGPoint?, margin: Double = 4) -> String? {
        guard let point, case .compact(_, let secondary, let tertiary) = state.mode else { return nil }
        let shape = motion.targetShape
        let x = Double(point.x - model.originX), y = Double(point.y)
        for (id, slot) in [(secondary, BlobSlot.minimal), (tertiary, BlobSlot.minimalLeading)] {
            guard let id else { continue }
            let b = shape[slot]
            guard b.isVisible else { continue }
            if abs(x - b.x) <= b.halfWidth + margin, abs(y - b.y) <= b.halfHeight + margin { return id }
        }
        return nil
    }

    /// Fin dove scende l'isola quando avrà finito di muoversi, in punti dal bordo alto dello schermo, guardando solo quello
    /// che sta entro `halfWidth` dal centro del notch: la barra di ricerca, che esce dal notch, si mette sotto (carpa, 23
    /// novembre 2026: «la barra deve capire se è aperto o chiuso il notch e muoversi di conseguenza»). La forma di arrivo,
    /// non quella di questo fotogramma: così la barra parte insieme all'isola invece di inseguirla.
    func targetBottom(within halfWidth: Double) -> Double {
        let shape = motion.targetShape
        var bottom = shape.height
        for blob in shape.blobs where blob.isVisible && abs(blob.x) - blob.halfWidth < halfWidth {
            bottom = max(bottom, blob.y + blob.halfHeight)
        }
        return bottom
    }

    /// Il puntatore (in coordinate della finestra, origine in alto) è sull'isola?
    func hitTest(_ point: CGPoint, margin: Double = 0) -> Bool {
        let field = IslandField(motion.targetShape)
        return field.contains(x: Double(point.x - model.originX), y: Double(point.y), margin: margin)
    }

    func resetStats() { stats.reset() }
    private static let traceFrames = ProcessInfo.processInfo.environment["CHARLAND_FOTOGRAMMI"] != nil
}

/// Registra ogni fotogramma su file, una riga JSON per fotogramma: è il campionamento
/// che cerca i saltini su quello che gira davvero sullo schermo.
@MainActor
final class MotionRecorder {
    private(set) var samples: [MotionAudit.Sample] = []
    private(set) var times: [Double] = []

    func record(_ frame: IslandFrame, at time: Double) {
        samples.append(MotionAudit.sample(frame))
        times.append(time)
    }

    func findings() -> [MotionAudit.Finding] {
        MotionAudit.check(samples)
    }
}
