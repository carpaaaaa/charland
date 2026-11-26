import AppKit
import CharlandCore

/// Segue il puntatore senza chiedere nessun permesso e senza poter bloccare nessun clic.
/// Finché il puntatore non è sulla forma dell'isola, la finestra lascia passare tutto:
/// la barra dei menu sotto resta sempre cliccabile.
@MainActor
final class PointerTracker {
    private var globalMonitor: Any?
    private var localMonitor: Any?
    /// Lo stato del puntatore per ogni isola. È legato all'isola, non allo schermo: un'isola
    /// ricreata (cambio di schermo, risveglio) riparte da zero invece di ereditare uno stato vecchio.
    private var gates: [ObjectIdentifier: HoverGate] = [:]
    private var dwellTimer: Timer?
    private unowned let hub: IslandHub

    init(hub: IslandHub) {
        self.hub = hub
    }

    // MARK: File trascinati

    private var buttonMonitor: Any?
    /// Il numero degli appunti del trascinamento alla fine dell'ultimo trascinamento: un numero
    /// diverso vuol dire che ne è cominciato uno nuovo. Si prende al rilascio e non alla pressione,
    /// perché alcune app preparano il file prima ancora che arrivi l'avviso della pressione.
    private var dragChangeCount = NSPasteboard(name: .drag).changeCount
    private var fileDrag = false

    /// Un file trascinato da un'altra app vicino al notch apre la zona del vassoio.
    private func watchFileDrags() {
        buttonMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp]) { [weak self] event in
            MainActor.assumeIsolated {
                guard let self else { return }
                if event.type == .leftMouseUp {
                    self.dragChangeCount = NSPasteboard(name: .drag).changeCount
                }
                self.fileDrag = false
            }
        }
    }

    /// Il trascinamento è finito sopra l'isola: lì il rilascio non arriva come avviso globale.
    static func dragEnded() {
        current?.dragChangeCount = NSPasteboard(name: .drag).changeCount
        current?.fileDrag = false
    }

    private static weak var current: PointerTracker?

    /// Tiene l'isola aperta mentre sta sullo schermo un foglio nato da lei (la condivisione del vassoio): per sceglierci
    /// dentro il puntatore esce dall'isola, che non deve chiudersi sotto il foglio. Lasciato, se il puntatore è fuori
    /// l'isola si chiude come sempre.
    static var holdOpen = false {
        didSet { if oldValue, !holdOpen { current?.releaseHold() } }
    }
    private var heldExits: Set<ObjectIdentifier> = []

    private func releaseHold() {
        for island in hub.islands where heldExits.contains(ObjectIdentifier(island)) {
            island.engine.setPressed(false)
            island.engine.send(.pointerExited)
        }
        heldExits.removeAll()
    }

    /// Il trascinamento in corso porta file? Lo si capisce dagli appunti del trascinamento,
    /// cambiati dopo la pressione del tasto.
    private func checkFileDrag() -> Bool {
        if fileDrag { return true }
        guard NSEvent.pressedMouseButtons & 1 != 0 else { return false }
        let board = NSPasteboard(name: .drag)
        guard board.changeCount != dragChangeCount, board.types?.contains(.fileURL) == true else { return false }
        fileDrag = true
        return true
    }

    /// La zona vicino al notch dove un file trascinato apre il vassoio. Una volta aperto, la zona è tutta l'isola
    /// più un margine: l'isola aperta col vassoio è più alta della zona d'ingresso, e scendendo verso «Rilascia qui»
    /// si usciva dalla zona, l'isola si chiudeva sotto il file e si riapriva, a scatti, e il file non entrava.
    private func nearNotch(_ location: CGPoint, _ island: IslandController) -> Bool {
        let g = island.geometry
        if abs(location.x - g.notchCenterX) < 240 && g.frame.maxY - location.y < 150 { return true }
        guard TrayStore.shared.dropping else { return false }
        let stage = g.stageFrame
        let point = CGPoint(x: location.x - stage.minX, y: stage.maxY - location.y)
        return island.engine.hitTest(point, margin: 36)
    }

    func start() {
        guard globalMonitor == nil else { return }
        Self.current = self
        watchFileDrags()
        let mask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged]
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] _ in
            MainActor.assumeIsolated { self?.moved() }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            MainActor.assumeIsolated { self?.moved() }
            return event
        }
    }

    func stop() {
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let buttonMonitor { NSEvent.removeMonitor(buttonMonitor) }
        buttonMonitor = nil
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        globalMonitor = nil
        localMonitor = nil
        dwellTimer?.invalidate()
    }

    private static let trace = ProcessInfo.processInfo.environment["CHARLAND_TRACE"] != nil

    private func moved() {
        let location = NSEvent.mouseLocation
        let now = CACurrentMediaTime()
        // Le isole che non ci sono più non tengono stato. Si controlla solo se i conti non tornano: questo codice gira
        // a ogni movimento del puntatore, ovunque sullo schermo, e creare un insieme ogni volta era lavoro buttato.
        if gates.count > hub.islands.count {
            let alive = Set(hub.islands.map(ObjectIdentifier.init))
            gates = gates.filter { alive.contains($0.key) }
        }
        if Self.trace { print(String(format: "[puntatore] %.0f %.0f", location.x, location.y)); fflush(stdout) }
        if checkFileDrag() {
            for island in hub.islands {
                // Durante un trascinamento nessun pulsante è sotto il puntatore: niente tessere rimaste accese dopo.
                if island.model.pointer != nil {
                    island.model.pointer = nil
                    island.model.resolveHover()
                }
                if nearNotch(location, island) {
                    island.beginDropMode()
                } else if TrayStore.shared.dropping {
                    island.endDropMode(dropped: false)
                }
            }
            return
        }
        for island in hub.islands {
            let stage = island.geometry.stageFrame
            let id = ObjectIdentifier(island)
            var gate = gates[id] ?? HoverGate()
            // Lontano dalla finestra dell'isola non c'è niente da calcolare.
            let near = stage.insetBy(dx: -4, dy: -4).contains(location)
            let point = CGPoint(x: location.x - stage.minX, y: stage.maxY - location.y)
            let inside = near && island.engine.hitTest(point, margin: 2)
            // Solo quando cambia: assegnarlo a ogni movimento, ovunque sullo schermo, era lavoro inutile per AppKit.
            if !TrayStore.shared.dropping, island.panel.ignoresMouseEvents == inside { island.panel.ignoresMouseEvents = !inside }
            // L'hover dei pulsanti segue ogni movimento, senza aspettare SwiftUI.
            if inside || island.model.pointer != nil {
                island.model.pointer = inside ? point : nil
                island.model.resolveHover()
            }
            if !near, !gate.isOpen, gate.pendingCheck == nil { continue }
            handle(gate.pointer(inside: inside, x: Double(location.x), y: Double(location.y), now: now), island)
            gates[id] = gate
            if let check = gate.pendingCheck { scheduleDwell(at: check) }
        }
    }

    /// L'isola si è aperta sotto il puntatore senza passare dal controllo (un file appena lasciato):
    /// da adesso, quando il puntatore se ne va, si chiude.
    func adoptOpen(_ island: IslandController) {
        var gate = gates[ObjectIdentifier(island)] ?? HoverGate()
        gate.forceOpen()
        gates[ObjectIdentifier(island)] = gate
        island.engine.send(.pointerEntered)
    }

    private func handle(_ decision: HoverGate.Decision, _ island: IslandController) {
        if Self.trace, decision != .none { print("[puntatore] \(decision), prima: \(island.engine.mode)"); fflush(stdout) }
        switch decision {
        case .none: break
        case .entered:
            heldExits.remove(ObjectIdentifier(island))
            let before = island.engine.mode
            // La casa si aggiorna a ogni apertura: giorno, batteria, attività in corso.
            island.engine.refreshHome(.home(HomeInfo.now()))
            island.engine.setHoverOpensActivity(Features.shared.hoverOpensActivity)
            island.engine.setPlaybackID(Features.shared.opensPlayback ? NowPlayingMonitor.activityID : nil)
            // Sopra una goccia staccata si apre l'attività di quella goccia (con «Apri l'attività in corso»).
            if let drop = island.engine.dropUnder(island.model.pointer) {
                island.engine.send(.pointerEnteredDrop(id: drop))
            } else {
                island.engine.send(.pointerEntered)
            }
            // Si è aperta sotto il puntatore: un tocco sul trackpad.
            if case .expanded = island.engine.mode, island.engine.mode != before { IslandHaptics.open() }
        case .exited:
            if Self.holdOpen {
                heldExits.insert(ObjectIdentifier(island))
                return
            }
            island.engine.setPressed(false)
            island.engine.send(.pointerExited)
        }
    }

    /// Il puntatore si è fermato sull'isola: senza altri movimenti serve un timer, uno solo.
    private func scheduleDwell(at time: Double) {
        dwellTimer?.invalidate()
        let timer = Timer(timeInterval: max(0.005, time - CACurrentMediaTime()), repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let now = CACurrentMediaTime()
                for island in self.hub.islands {
                    guard var gate = self.gates[ObjectIdentifier(island)] else { continue }
                    self.handle(gate.tick(now: now), island)
                    self.gates[ObjectIdentifier(island)] = gate
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        dwellTimer = timer
    }
}
