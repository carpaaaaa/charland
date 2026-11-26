import AppKit
import SwiftUI
import CharlandCore

/// Il gesto di Filo sull'icona di Charland nella barra dei menu: premi e trascina in giù, la distanza dice i minuti
/// (la rotella aggiunge o toglie un minuto alla volta), lasci e il timer vola nell'isola. Riportando la goccia
/// vicino all'icona si annulla. Il timer resta a parte: niente calendario, niente attività altrove.
///
/// Da macOS 26 la barra dei menu si tiene il trascinamento sugli elementi di stato: all'app arriva solo una coppia
/// pressione/rilascio nello stesso istante, mai un trascinamento. Il gesto quindi si legge dallo stato fisico del
/// mouse (`pressedMouseButtons`, `mouseLocation`), che non passa dalla coda degli eventi e non chiede permessi.
@MainActor
final class TimerDrag {
    private var panel: IslandPanel?
    /// Lo Space dell'isola in cui è entrata la finestra (`IslandHub.spaceToken`): se cambia, la finestra si rifà.
    private var panelSpace = 0
    private var host: NSHostingView<TimerDropView>?
    private let scene = TimerDropScene()
    private var panelOrigin: CGPoint = .zero
    private var poll: Timer?
    private var scrollMonitor: Any?
    private var scrollAccum: CGFloat = 0
    private var scrollMinutes = 0
    private var minutes: Int?
    private var began = false
    private var press: CGPoint = .zero
    private var anchor: CGPoint = .zero
    private var screen: NSScreen?
    private var startedAt = Date.distantPast
    private var onFinish: ((Bool) -> Void)?
    /// Il colore dell'icona nella barra (bianco sulla barra scura, nero su quella chiara) e quanto è alta: la farfalla
    /// di gocce che la sostituisce dev'essere identica.
    private var glyph: Color = .white
    var iconHeight: CGFloat = 15
    /// Sta cominciando un gesto nuovo: un timer di prima che atterra adesso non chiede il nome (il campo prenderebbe
    /// la tastiera a metà del trascinamento).
    private var startingGesture = false
    /// Chiamata quando il gesto comincia e finisce: l'icona si spegne un poco mentre la goccia è fuori.
    var onDragging: ((Bool) -> Void)?

    private static let maxDuration: TimeInterval = 15 * 60

    var isTracking: Bool { poll != nil }

    /// Prepara la finestra della goccia una volta: crearla al primo gesto costava fotogrammi.
    func warmUp(on screen: NSScreen?) {
        guard let screen else { return }
        _ = ensurePanel(for: screen)
    }

    /// Segue il gesto a partire dalla pressione sull'icona. `completion(false)`: era solo un clic.
    func track(from button: NSStatusBarButton, completion: @escaping (Bool) -> Void) {
        guard !isTracking, let window = button.window else { completion(false); return }
        // Se il tasto non è più premuto quando arriva l'azione, è stato un clic secco.
        guard NSEvent.pressedMouseButtons & 1 != 0 else { completion(false); return }
        let b = button.bounds
        anchor = window.convertPoint(toScreen: button.convert(NSPoint(x: b.midX, y: b.midY), to: nil))
        glyph = Self.glyphColor(for: button)
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(anchor) }) ?? NSScreen.main else {
            completion(false); return
        }
        self.screen = screen
        press = NSEvent.mouseLocation
        began = false
        scrollAccum = 0
        scrollMinutes = 0
        minutes = nil
        startedAt = Date()
        onFinish = completion
        // La finestra della goccia va a schermo subito, alla pressione, quasi invisibile: il primo fotogramma di una
        // finestra a tutto schermo costa circa 40 ms, e pagato all'inizio del trascinamento faceva saltare la goccia
        // proprio mentre la tiri giù (carpa, 20 novembre 2026: «quando la prendo e tiro giù, in quell'istante lagga»).
        // Opacità minima e non zero: a zero la finestra non è davvero pronta.
        // Con la goccia di prima ancora in volo (o di ritorno all'icona) la finestra è sua: non si tocca, se no la goccia
        // spariva a metà strada (revisione Sonnet).
        if !scene.isBusy {
            let early = ensurePanel(for: screen)
            early.alphaValue = 0.01
            early.orderFrontRegardless()
            scene.prepare(on: screen)
        }
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self, self.began else { return event }
            self.scrollAccum += event.scrollingDeltaY
            while self.scrollAccum >= 15 { self.scrollMinutes += 1; self.scrollAccum -= 15 }
            while self.scrollAccum <= -15 { self.scrollMinutes -= 1; self.scrollAccum += 15 }
            self.update(mouse: NSEvent.mouseLocation)
            return nil
        }
        let timer = Timer(timeInterval: 1.0 / 120.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        poll = timer
    }

    private func tick() {
        let down = NSEvent.pressedMouseButtons & 1 != 0
        guard down, Date().timeIntervalSince(startedAt) < Self.maxDuration else { finishTracking(); return }
        let mouse = NSEvent.mouseLocation
        if !began, TimerGesture.dragBegan(press: press, current: mouse) {
            began = true
            begin()
        }
        if began { update(mouse: mouse) }
    }

    private func finishTracking() {
        poll?.invalidate()
        poll = nil
        if let scrollMonitor { NSEvent.removeMonitor(scrollMonitor) }
        scrollMonitor = nil
        let didDrag = began
        began = false
        if didDrag {
            end()
        } else if !scene.isBusy {
            panel?.orderOut(nil)
            scene.unprepare()
        }
        let completion = onFinish
        onFinish = nil
        completion?(didDrag)
    }

    private func ensurePanel(for screen: NSScreen) -> IslandPanel {
        if let panel, panel.frame == screen.frame, panelSpace == IslandHub.shared.spaceToken { return panel }
        panel?.close()
        let panel = IslandPanel(frame: screen.frame)
        // Nello Space dell'isola, prima di comparire: sulle scrivanie normali la finestra, tenuta nascosta a lungo,
        // finiva legata a quelle di quando era nata e su una nuova non si vedeva più (né filo né goccia).
        panelSpace = IslandHub.shared.adopt(panel)
        let host = NSHostingView(rootView: TimerDropView(model: scene.model, appearance: .shared))
        host.sizingOptions = []
        host.frame = CGRect(origin: .zero, size: screen.frame.size)
        host.autoresizingMask = [.width, .height]
        panel.contentView = host
        scene.model.size = screen.frame.size
        self.panel = panel
        self.host = host
        return panel
    }

    private func begin() {
        guard let screen else { return }
        let t0 = CACurrentMediaTime()
        let panel = ensurePanel(for: screen)
        let t1 = CACurrentMediaTime()
        panelOrigin = screen.frame.origin
        Haptics.tick()
        let t2 = CACurrentMediaTime()
        startingGesture = true
        scene.begin(anchor: CGPoint(x: anchor.x - panelOrigin.x, y: anchor.y - panelOrigin.y), size: screen.frame.size,
                    iconHeight: iconHeight, glyph: glyph, screen: screen)
        startingGesture = false
        let t3 = CACurrentMediaTime()
        panel.orderFrontRegardless()
        // Piena al giro dopo: in questo SwiftUI ha già preso la scena nuova, così non si vede mai un fotogramma vecchio.
        DispatchQueue.main.async { panel.alphaValue = 1 }
        let t4 = CACurrentMediaTime()
        // L'icona si spegne quando la farfalla di gocce identica è già al suo posto: lo scambio non si vede, e da lì
        // la farfalla si fonde nel pallino.
        onDragging?(true)
        if Self.trace {
            let t5 = CACurrentMediaTime()
            print(String(format: "[filo] presa: finestra %.1f ms, vibrazione %.1f, scena %.1f, in vista %.1f, icona %.1f, dalla pressione %.0f ms",
                         (t1 - t0) * 1000, (t2 - t1) * 1000, (t3 - t2) * 1000, (t4 - t3) * 1000, (t5 - t4) * 1000,
                         Date().timeIntervalSince(startedAt) * 1000)); fflush(stdout)
        }
    }

    private static let trace = ProcessInfo.processInfo.environment["CHARLAND_SLIDER"] != nil

    private func update(mouse: CGPoint) {
        scene.target = CGPoint(x: mouse.x - panelOrigin.x, y: mouse.y - panelOrigin.y)
        let new = TimerGesture.minutes(press: press, current: mouse, extra: scrollMinutes)
        // Solo quando i minuti cambiano: rifare testi e misure 120 volte al secondo era lavoro buttato.
        guard new != minutes else { return }
        if new != nil { Haptics.tick() }
        minutes = new
        scene.setInfo(minutes: new, ends: new.map { Date().addingTimeInterval(TimeInterval($0 * 60)) })
    }

    private func end() {
        let chosen = minutes
        minutes = nil
        let panel = self.panel
        guard let chosen else {
            // La goccia risale nel pallino, il pallino torna farfalla e lì riappare l'icona vera.
            scene.retract(icon: { [weak self] in self?.onDragging?(false) }) {
                panel?.orderOut(nil)
            }
            return
        }
        // Il timer conta dal rilascio; parte davvero quando la goccia entra nell'isola.
        let released = Date()
        scene.fly(to: islandPoint(), icon: { [weak self] in self?.onDragging?(false) }, landed: { [weak self] in
            let seconds = TimeInterval(chosen * 60) - Date().timeIntervalSince(released)
            let id = TimerCenter.shared.start(seconds: max(1, seconds))
            Haptics.play("done")
            // Se acceso in Generale, scende dal notch il campo per dargli un nome.
            if Features.shared.timerNames, self?.startingGesture != true { TimerNamer.shared.ask(for: id) }
        }, completion: {
            panel?.orderOut(nil)
        })
    }

    /// Per le scene dimostrative: lo stesso gesto recitato lungo dei punti dello schermo (un punto ogni `step`
    /// secondi), poi il rilascio. Non tocca il mouse vero.
    func rehearse(anchor: CGPoint, path: [CGPoint], step: Double, glyph: Color = .white) async {
        guard !isTracking else { return }
        self.anchor = anchor
        self.glyph = glyph
        screen = NSScreen.screens.first { $0.frame.contains(anchor) } ?? NSScreen.main
        press = anchor
        scrollMinutes = 0
        minutes = nil
        begin()
        for point in path {
            update(mouse: point)
            try? await Task.sleep(for: .seconds(step))
        }
        end()
    }

    /// Il colore con cui la barra dei menu disegna l'icona: bianco sulla barra scura, nero (appena trasparente) su quella chiara.
    static func glyphColor(for view: NSView) -> Color {
        view.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? .white : .black.opacity(0.85)
    }

    /// Dove entra la goccia: il centro del notch sullo schermo dell'isola, se è lo stesso del gesto;
    /// altrimenti il centro in alto dello schermo del gesto.
    private func islandPoint() -> CGPoint {
        guard let screen else { return .zero }
        if let geometry = IslandHub.shared.primary?.geometry, geometry.frame == screen.frame {
            let y = geometry.frame.maxY - CGFloat(geometry.metrics.notchHeight) / 2
            return CGPoint(x: geometry.notchCenterX - panelOrigin.x, y: y - panelOrigin.y)
        }
        return CGPoint(x: screen.frame.width / 2, y: screen.frame.height - 12)
    }
}
