import AppKit
import SwiftUI
import CharlandCore

/// L'isola su uno schermo: la finestra fissa, il motore e il velo per la goccia in volo.
@MainActor
final class IslandController {
    let geometry: ScreenGeometry
    private var dropTarget: TrayDropTarget?
    let model: IslandModel
    let engine: IslandEngine
    let panel: IslandPanel
    private let host: FirstMouseHostingView<IslandStageView>
    private let flight: FlightOverlay

    init(screen: NSScreen, space: OverlaySpace?, simulateNotchless: Bool = false) {
        geometry = ScreenGeometry(screen: screen, simulateNotchless: simulateNotchless)
        let stage = geometry.stageFrame
        model = IslandModel(metrics: geometry.metrics, stageSize: stage.size)
        model.pointerDriven = true
        engine = IslandEngine(model: model)
        panel = IslandPanel(frame: stage)
        host = FirstMouseHostingView(rootView: IslandStageView(model: model, appearance: .shared))
        dropTarget = TrayDropTarget(model: model)
        panel.dropTarget = dropTarget
        host.sizingOptions = []
        host.frame = CGRect(origin: .zero, size: stage.size)
        host.autoresizingMask = [.width, .height]
        panel.contentView = host
        flight = FlightOverlay(screenFrame: geometry.frame, level: panel.level)
        engine.attach(to: host)
        engine.setShowsOthers(Features.shared.showsOthers)
        engine.setPlaybackID(Features.shared.opensPlayback ? NowPlayingMonitor.activityID : nil)
        model.onPress = { [engine] down in engine.setPressed(down) }
        model.onTap = { [engine] in
            switch engine.mode {
            case .rest, .compact:
                engine.refreshHome(.home(HomeInfo.now()))
                engine.send(.expand(id: nil))
            // Aperta su un'attività, un clic porta alla casa (dettatura, timer, vassoio restano a un clic anche quando
            // passando sopra si apre l'attività). Mai su una richiesta di permesso: lì un clic sbagliato la nasconderebbe.
            case .expanded(let id) where id != IslandState.homeID && ActivityCenter.shared.expandedApproval == nil:
                engine.refreshHome(.home(HomeInfo.now()))
                engine.send(.expand(id: IslandState.homeID))
            // Aperta sulla casa, un clic non la chiude: si chiude quando il puntatore se ne va.
            case .expanded: break
            case .transient(.dictation, _): DictationController.shared.stopFromIsland()
            default: break
            }
        }
        // Le azioni e i cambi di stato passano da un punto solo: così valgono anche per le isole
        // ricreate quando cambiano gli schermi.
        model.onAction = { action, activity in IslandActions.handle(action: action, activity: activity) }
        model.hitTest = { [engine] point in engine.hitTest(point, margin: 4) }
        engine.onModeChange = { _ in IslandActions.modeChanged() }
        engine.setHome(Home.current, content: .home(HomeInfo.now()))
        model.onDrop = { [weak self] dropped in self?.endDropMode(dropped: dropped) }
        engine.onDrip = { [flight, geometry] drip in
            flight.show(drip, notchCenterX: geometry.notchCenterX)
        }
        // Prima di comparire la finestra entra nello Space dell'isola: così i gesti fra
        // scrivanie non la trascinano via.
        space?.adopt(panel)
        space?.adopt(flight.panel)
        panel.orderFrontRegardless()
        // La finestra della goccia si prepara adesso, una volta: crearla al primo volo costava fotogrammi.
        flight.warmUp()
    }

    // MARK: Vassoio

    /// Un file trascinato si avvicina al notch: l'isola si apre sulla casa con la zona dove lasciarlo.
    func beginDropMode() {
        let tray = TrayStore.shared
        // Vassoio spento in Impostazioni › Vassoio: il file passa sopra il notch e l'isola non si apre.
        guard Features.shared.tray, !tray.dropping else { return }
        tray.prune()
        tray.dropping = true
        panel.ignoresMouseEvents = false
        engine.refreshHome(.home(HomeInfo.now()))
        engine.setHome(Home.current, content: .home(HomeInfo.now()))
        engine.send(.expand(id: IslandState.homeID))
        IslandHaptics.open()
        watchDragEnd()
    }

    /// Il trascinamento è finito o si è allontanato.
    func endDropMode(dropped: Bool) {
        let tray = TrayStore.shared
        guard tray.dropping else { return }
        PointerTracker.dragEnded()
        tray.dropping = false
        tray.targeted = false
        dragTimer?.invalidate()
        dragTimer = nil
        engine.setHome(Home.current, content: .home(HomeInfo.now()))
        if dropped {
            // Il file è appena arrivato: la casa resta aperta col vassoio finché il puntatore non se ne va.
            engine.refresh()
            onDropped?()
        } else {
            engine.send(.collapse)
            // La finestra torna trasparente ai clic e ai trascinamenti subito: finché dura il trascinamento il
            // puntatore non la rimette a posto (`PointerTracker` si ferma prima), e la finestra dell'isola, invisibile
            // ma larga, si prendeva i file lasciati sulle finestre che ha sotto.
            panel.ignoresMouseEvents = true
        }
    }

    /// Chiamata quando un file è stato lasciato nell'isola.
    var onDropped: (() -> Void)?
    private var dragTimer: Timer?

    /// Mentre la zona è aperta, controlla cinque volte al secondo se il tasto del mouse è stato
    /// lasciato: un trascinamento finito sopra l'isola non manda altri avvisi.
    private func watchDragEnd() {
        dragTimer?.invalidate()
        let timer = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, NSEvent.pressedMouseButtons & 1 == 0 else { return }
                // Lasciato fuori dalla zona: si chiude. Se il file è stato preso, l'ha già chiusa la consegna.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    MainActor.assumeIsolated { self.endDropMode(dropped: false) }
                }
                self.dragTimer?.invalidate()
                self.dragTimer = nil
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        dragTimer = timer
    }

    /// Fa colare la goccia verso un punto dello schermo.
    func drip(to point: CGPoint) {
        flight.prepare()
        engine.startDrip(toScreenPoint: point, screenFrame: geometry.frame, notchCenterX: geometry.notchCenterX)
    }

    /// Il rettangolo dell'isola aperta sullo schermo, per gli scatti.
    var captureRect: CGRect {
        let stage = geometry.stageFrame
        // screencapture usa coordinate con l'origine in alto a sinistra dello schermo principale.
        let mainHeight = NSScreen.screens.first?.frame.height ?? geometry.frame.height
        return CGRect(x: stage.minX, y: mainHeight - stage.maxY, width: stage.width, height: stage.height)
    }

    func close() {
        panel.orderOut(nil)
        flight.panel.orderOut(nil)
    }
}

/// La vista dell'isola accetta il primo clic anche se la finestra non ha il fuoco:
/// l'isola non ruba mai il fuoco all'app in cui stai lavorando.
final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Il velo trasparente a tutto schermo dove vola la goccia della dettatura.
/// Sta acceso solo durante il volo: a riposo è fuori dallo schermo e non costa niente.
@MainActor
final class FlightOverlay {
    let panel: IslandPanel
    private let layer = CAShapeLayer()
    private let screenFrame: CGRect
    private var visible = false

    init(screenFrame: CGRect, level: NSWindow.Level) {
        self.screenFrame = screenFrame
        panel = IslandPanel(frame: screenFrame)
        panel.level = level
        let view = NSView(frame: CGRect(origin: .zero, size: screenFrame.size))
        view.wantsLayer = true
        layer.fillColor = NSColor.black.cgColor
        layer.frame = view.bounds
        // Coordinate con l'origine in alto, come l'isola.
        layer.isGeometryFlipped = true
        view.layer?.addSublayer(layer)
        panel.contentView = view
    }

    /// Comparire la prima volta crea la superficie della finestra: si fa all'avvio, non al primo volo.
    func warmUp() {
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        DispatchQueue.main.async { [panel] in
            panel.orderOut(nil)
            panel.alphaValue = 1
        }
    }

    /// Porta il velo sullo schermo prima del volo, così il primo fotogramma è già pronto.
    func prepare() {
        guard !visible else { return }
        visible = true
        panel.orderFrontRegardless()
    }

    func show(_ drip: DripState?, notchCenterX: CGFloat) {
        // Senza goccia e già vuoto: niente da fare (arriva a ogni fotogramma dell'isola).
        if drip == nil, !visible, layer.path == nil { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        guard let drip, !drip.attached else {
            layer.path = nil
            if drip == nil, visible {
                visible = false
                panel.orderOut(nil)
            }
            return
        }
        let ox = notchCenterX - screenFrame.minX
        layer.path = Self.teardrop(head: CGPoint(x: ox + drip.headX, y: drip.headY), headRadius: drip.headRadius,
                                   tail: CGPoint(x: ox + drip.tailX, y: drip.tailY), tailRadius: drip.tailRadius)
    }

    /// Una goccia: due cerchi uniti dalle loro tangenti esterne.
    static func teardrop(head: CGPoint, headRadius: CGFloat, tail: CGPoint, tailRadius: CGFloat) -> CGPath {
        let path = CGMutablePath()
        let dx = head.x - tail.x
        let dy = head.y - tail.y
        let distance = max(0.001, hypot(dx, dy))
        if distance > 0.5 {
            // Angolo delle tangenti esterne fra due cerchi di raggio diverso.
            let ratio = max(-1, min(1, (headRadius - tailRadius) / distance))
            let base = atan2(dy, dx)
            let spread = acos(ratio)
            let a1 = base + spread
            let a2 = base - spread
            path.move(to: CGPoint(x: head.x + cos(a1) * headRadius, y: head.y + sin(a1) * headRadius))
            path.addLine(to: CGPoint(x: tail.x + cos(a1) * tailRadius, y: tail.y + sin(a1) * tailRadius))
            path.addLine(to: CGPoint(x: tail.x + cos(a2) * tailRadius, y: tail.y + sin(a2) * tailRadius))
            path.addLine(to: CGPoint(x: head.x + cos(a2) * headRadius, y: head.y + sin(a2) * headRadius))
            path.closeSubpath()
        }
        path.addEllipse(in: CGRect(x: head.x - headRadius, y: head.y - headRadius, width: headRadius * 2, height: headRadius * 2))
        path.addEllipse(in: CGRect(x: tail.x - tailRadius, y: tail.y - tailRadius, width: tailRadius * 2, height: tailRadius * 2))
        return path
    }
}
