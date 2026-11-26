import Testing
@testable import CharlandCore

/// Tre attività visibili insieme: una al centro, una nella goccia a destra, una in quella a sinistra
/// (carpa, 17 novembre 2026). Ognuna entra ed esce con lo stacco liquido.
@Suite("Tre attività: centro e due gocce")
struct IslandDropsTests {
    let m = IslandMetrics.air15
    let home = IslandActivity(id: IslandState.homeID, priority: -10, allowsMinimal: false)

    // MARK: Stati

    @Test("la seconda va a destra, la terza a sinistra, la quarta resta nella casa")
    func order() {
        var s = IslandState()
        s.handle(.started(IslandActivity(id: "agenti", priority: 1)), now: 0)
        s.handle(.started(IslandActivity(id: "attivo", priority: -1)), now: 1)
        #expect(s.mode == .compact(primary: "agenti", secondary: "attivo", tertiary: nil))
        // Un timer passa davanti a Mantieni attivo: lui a destra, Mantieni attivo scivola a sinistra.
        s.handle(.started(IslandActivity(id: "timer", priority: 0)), now: 2)
        #expect(s.mode == .compact(primary: "agenti", secondary: "timer", tertiary: "attivo"))
        #expect(s.visibleIDs == ["agenti", "timer", "attivo"])
        // La quarta non si vede: c'è già una goccia per lato.
        s.handle(.started(IslandActivity(id: "musica", priority: -1)), now: 3)
        #expect(s.mode == .compact(primary: "agenti", secondary: "timer", tertiary: "musica"))
        // Finisce il timer: tutti salgono di un posto.
        s.handle(.ended(id: "timer"), now: 4)
        #expect(s.mode == .compact(primary: "agenti", secondary: "musica", tertiary: "attivo"))
    }

    @Test("chi non sa stare in una goccia cede il posto al successivo")
    func noMinimal() {
        var s = IslandState()
        s.handle(.started(IslandActivity(id: "registrazione", priority: 2)), now: 0)
        s.handle(.started(IslandActivity(id: "risparmio", priority: 1, allowsMinimal: false)), now: 1)
        s.handle(.started(IslandActivity(id: "timer", priority: 0)), now: 2)
        s.handle(.started(IslandActivity(id: "attivo", priority: -1)), now: 3)
        #expect(s.mode == .compact(primary: "registrazione", secondary: "timer", tertiary: "attivo"))
    }

    @Test("passando sopra una goccia si apre la sua attività, anche se è di sottofondo; senza l'opzione la casa")
    func hoverDrop() {
        var s = IslandState()
        s.setHome(home)
        s.hoverOpensActivity = true
        s.handle(.started(IslandActivity(id: "agenti", priority: 1)), now: 0)
        s.handle(.started(IslandActivity(id: "timer", priority: 0)), now: 0)
        s.handle(.started(IslandActivity(id: "attivo", priority: -1)), now: 0)

        s.handle(.pointerEnteredDrop(id: "attivo"), now: 1)
        #expect(s.mode == .expanded(id: "attivo"))
        #expect(s.expandedByHover)
        s.handle(.pointerExited, now: 2)
        s.handle(.tick, now: 2.5)
        #expect(s.mode == .compact(primary: "agenti", secondary: "timer", tertiary: "attivo"))

        s.handle(.pointerEnteredDrop(id: "timer"), now: 3)
        #expect(s.mode == .expanded(id: "timer"))
        s.handle(.collapse, now: 4)

        // Al centro l'attività principale.
        s.handle(.pointerEntered, now: 5)
        #expect(s.mode == .expanded(id: "agenti"))
        s.handle(.collapse, now: 6)

        // Con «Apri la casa» ogni parte dell'isola apre la casa.
        s.hoverOpensActivity = false
        s.handle(.pointerEnteredDrop(id: "timer"), now: 7)
        #expect(s.mode == .expanded(id: IslandState.homeID))
    }

    @Test("una goccia che non c'è più non apre niente di strano")
    func hoverStaleDrop() {
        var s = IslandState()
        s.setHome(home)
        s.hoverOpensActivity = true
        s.handle(.started(IslandActivity(id: "agenti", priority: 1)), now: 0)
        s.handle(.pointerEnteredDrop(id: "finita"), now: 1)
        #expect(s.mode == .expanded(id: "agenti"), "un'attività sparita: vale l'apertura dal centro")
    }

    // MARK: Forma

    @Test("la goccia sinistra è lo specchio di quella destra, e a riposo le tre forme sono staccate")
    func mirrored() {
        var s = IslandState()
        let a = IslandActivity(id: "a", leadingWidth: 30, trailingWidth: 30)
        s.handle(.started(a), now: 0)
        s.handle(.started(IslandActivity(id: "b")), now: 0)
        s.handle(.started(IslandActivity(id: "c")), now: 0)
        let shape = IslandLayout.shape(for: s.mode, state: s, metrics: m)
        let right = shape[.minimal], left = shape[.minimalLeading]
        #expect(right.isVisible && left.isVisible)
        #expect(abs(right.x + left.x) < 0.0001, "con le ali uguali le gocce sono simmetriche")
        #expect(right.y == left.y && right.halfWidth == left.halfWidth)
        let loops = ContourTracer().trace(shape)
        #expect(loops.count == 3, "corpo e due gocce, staccati")
        // A riposo le gocce non gonfiano il corpo da nessuno dei due lati.
        let body = loops.first { loop in loop.map(\.x).min()! < 0 && loop.map(\.x).max()! > 0 }!
        #expect(abs(body.map(\.x).max()! - (shape.right + shape.flare)) < 0.3, "destra \(body.map(\.x).max()!) contro \(shape.right + shape.flare)")
        #expect(abs(body.map(\.x).min()! + (shape.left + shape.flare)) < 0.3, "sinistra \(body.map(\.x).min()!) contro \(-(shape.left + shape.flare))")

        // Le cornici dei contenuti stanno dentro le gocce.
        let frames = IslandLayout.frames(for: s.mode, state: s, metrics: m)
        #expect(abs(frames.minimalLeading.midX - left.x) < 0.0001)
        #expect(abs(frames.minimal.midX - right.x) < 0.0001)
    }

    @Test("con ali diverse la goccia sinistra segue il bordo sinistro")
    func asymmetric() {
        var s = IslandState()
        s.handle(.started(IslandActivity(id: "a", leadingWidth: 34, trailingWidth: 46)), now: 0)
        s.handle(.started(IslandActivity(id: "b")), now: 0)
        s.handle(.started(IslandActivity(id: "c")), now: 0)
        let shape = IslandLayout.shape(for: s.mode, state: s, metrics: m)
        let t = IslandTuning()
        let r = (m.notchHeight - t.minimalInset * 2) / 2
        #expect(abs(shape[.minimalLeading].x + (shape.left + t.minimalGap + r)) < 0.0001)
        #expect(abs(shape[.minimal].x - (shape.right + t.minimalGap + r)) < 0.0001)
    }

    // MARK: Movimento

    /// Recita gli eventi a 60 fotogrammi al secondo e restituisce i fotogrammi e i difetti trovati.
    func play(_ script: [(IslandEvent, hold: Double)]) -> (tape: [MotionAudit.Sample], findings: [MotionAudit.Finding]) {
        var state = IslandState()
        var motion = IslandMotion(metrics: m)
        let dt = 1.0 / 60.0
        var tape = [MotionAudit.sample(motion.frame)]
        var findings: [MotionAudit.Finding] = []
        for (index, (event, hold)) in script.enumerated() {
            state.handle(event, now: motion.now)
            motion.apply(state.mode, state: state)
            for _ in 0..<max(1, Int(hold / dt)) {
                motion.step(dt: dt)
                tape.append(MotionAudit.sample(motion.frame))
            }
            if hold >= 2 {
                if motion.isMoving { findings.append(.init(kind: .tooLong, frame: tape.count - 1, track: "passo \(index)", detail: "ancora in movimento")) }
                findings += MotionAudit.checkClipping(motion.frame)
            }
        }
        findings += MotionAudit.check(tape)
        return (tape, findings)
    }

    let agents = IslandActivity(id: "agenti", priority: 1, leadingWidth: 34, trailingWidth: 46, expandedWidth: 300, expandedHeight: 98)
    let timer = IslandActivity(id: "timer", priority: 0, leadingWidth: 22, trailingWidth: 44)
    let awake = IslandActivity(id: "attivo", priority: -1, leadingWidth: 22, trailingWidth: 24)

    @Test("tre attività entrano, si apre, si chiude, ed escono, senza saltini")
    func tour() {
        let result = play([
            (.started(agents), 2.2),
            (.started(awake), 2.2),
            (.started(timer), 2.2),          // il timer prende la destra, Mantieni attivo scivola a sinistra
            (.expand(id: "agenti"), 2.2),
            (.collapse, 2.2),
            (.ended(id: "timer"), 2.2),      // Mantieni attivo torna a destra, la sinistra rientra
            (.ended(id: "attivo"), 2.2),
            (.ended(id: "agenti"), 2.2),
        ])
        #expect(result.findings.isEmpty, "\(result.findings.map(\.description).joined(separator: "\n"))")
    }

    @Test("la goccia sinistra si stacca col collo: prima attaccata, poi da sola")
    func leftSplits() {
        let result = play([(.started(agents), 2.2), (.started(timer), 2.2), (.started(awake), 2.2)])
        // Durante l'ultimo passo: due linee (corpo col collo a sinistra, goccia destra) e poi tre.
        let last = Array(result.tape.suffix(Int(2.2 * 60)))
        let firstThree = last.firstIndex { $0.loops == 3 }
        #expect(firstThree != nil, "alla fine la goccia sinistra è staccata")
        if let firstThree {
            #expect(firstThree > 3, "per qualche fotogramma è ancora attaccata al corpo")
            #expect(last[..<firstThree].allSatisfy { $0.loops == 2 }, "finché è attaccata: corpo più goccia destra")
            #expect(last[firstThree...].allSatisfy { $0.loops == 3 }, "staccata non si riattacca")
        }
        // Cresce verso sinistra: il punto più a sinistra della forma si allarga.
        #expect(last.last!.minX < last.first!.minX - 20)
        #expect(result.findings.isEmpty, "\(result.findings.map(\.description).joined(separator: "\n"))")
    }

    @Test("rientrando la goccia sinistra si riattacca e sparisce nel corpo")
    func leftReabsorbs() {
        let result = play([(.started(agents), 2.2), (.started(timer), 2.2), (.started(awake), 2.2), (.ended(id: "attivo"), 2.2)])
        let last = Array(result.tape.suffix(Int(2.2 * 60)))
        #expect(last.first!.loops == 3)
        #expect(last.contains { $0.loops == 2 })
        #expect(last.last!.loops == 2, "resta solo corpo più goccia destra")
        #expect(result.findings.isEmpty, "\(result.findings.map(\.description).joined(separator: "\n"))")
    }

    @Test("un aggiornamento dell'attività in una goccia non la riattacca al corpo")
    func updateKeepsDropApart() {
        var state = IslandState()
        var motion = IslandMotion(metrics: m)
        for a in [agents, timer, awake] {
            state.handle(.started(a), now: motion.now)
            motion.apply(state.mode, state: state)
            for _ in 0..<130 { motion.step(dt: 1.0 / 60.0) }
        }
        #expect(ContourTracer().trace(motion.shape).count == 3)
        for _ in 0..<5 {
            state.handle(.updated(agents), now: motion.now)
            motion.apply(state.mode, state: state)
            for _ in 0..<12 {
                motion.step(dt: 1.0 / 60.0)
                #expect(ContourTracer().trace(motion.shape).count == 3)
            }
        }
    }

    @Test("interrompere a metà lo stacco a sinistra non fa salti")
    func interrupted() {
        let result = play([
            (.started(agents), 2.2), (.started(timer), 2.2),
            (.started(awake), 0.1), (.ended(id: "attivo"), 0.12), (.started(awake), 0.08),
            (.expand(id: "agenti"), 0.15), (.collapse, 2.2),
        ])
        let jumps = result.findings.filter { $0.kind != .tooLong && $0.kind != .clipped }
        #expect(jumps.isEmpty, "\(jumps.map(\.description).joined(separator: "\n"))")
    }
}

/// Le attività si vedono anche dentro l'isola aperta: sotto l'attività aperta, le altre come pillole.
@Suite("Le altre attività dentro l'isola aperta")
struct IslandSwitcherTests {
    let m = IslandMetrics.air15

    @Test("aperta un'attività, le altre stanno nella fila sotto; da sola niente fila; nella casa ci pensano le sue pillole")
    func others() {
        var s = IslandState()
        s.setHome(IslandActivity(id: IslandState.homeID, priority: -10, allowsMinimal: false))
        s.handle(.started(IslandActivity(id: "agenti", priority: 1, expandedHeight: 98)), now: 0)
        s.handle(.expand(id: "agenti"), now: 0)
        let alone = IslandLayout.frames(for: s.mode, state: s, metrics: m)
        #expect(alone.switcherIDs.isEmpty && alone.switcher == .zero)
        let aloneHeight = IslandLayout.shape(for: s.mode, state: s, metrics: m).height

        s.handle(.started(IslandActivity(id: "timer", priority: 0)), now: 1)
        s.handle(.started(IslandActivity(id: "attivo", priority: -1)), now: 2)
        s.handle(.started(IslandActivity(id: "musica", priority: -1)), now: 3)
        s.handle(.started(IslandActivity(id: "quinta", priority: -2)), now: 4)
        let frames = IslandLayout.frames(for: s.mode, state: s, metrics: m)
        #expect(frames.switcherIDs == ["timer", "musica", "attivo"], "al massimo tre, nell'ordine dell'isola")
        let shape = IslandLayout.shape(for: s.mode, state: s, metrics: m)
        #expect(abs(shape.height - aloneHeight - IslandTuning().switcherHeight) < 0.0001, "l'isola si allunga della fila")
        #expect(frames.switcher.y >= frames.expanded.maxY, "sotto il contenuto aperto")
        #expect(frames.blackUntil >= frames.switcher.maxY, "le pillole stanno sul nero")

        s.handle(.expand(id: IslandState.homeID), now: 5)
        #expect(IslandLayout.frames(for: s.mode, state: s, metrics: m).switcherIDs.isEmpty)
    }

    @Test("la fila entra con l'isola, cambia quando cambiano le attività e non esce dalla forma")
    func motion() {
        var state = IslandState()
        var motion = IslandMotion(metrics: m)
        let dt = 1.0 / 60.0
        var tape = [MotionAudit.sample(motion.frame)]
        let events: [IslandEvent] = [
            .started(IslandActivity(id: "agenti", priority: 1, leadingWidth: 34, trailingWidth: 46, expandedWidth: 300, expandedHeight: 98)),
            .started(IslandActivity(id: "timer", priority: 0, leadingWidth: 22, trailingWidth: 44)),
            .expand(id: "agenti"),
            .started(IslandActivity(id: "attivo", priority: -1, leadingWidth: 22, trailingWidth: 24)),
            .expand(id: "timer"),
            .collapse,
        ]
        for event in events {
            state.handle(event, now: motion.now)
            motion.apply(state.mode, state: state)
            for _ in 0..<132 {
                motion.step(dt: dt)
                tape.append(MotionAudit.sample(motion.frame))
            }
            #expect(MotionAudit.checkClipping(motion.frame).isEmpty, "\(event)")
            if case .expanded(let id) = state.mode {
                let row = motion.frame.layers.filter { $0.slot == .switcher && $0.presence > 0.99 }
                #expect(row.map(\.id) == [state.others(than: id).joined(separator: "|")])
            }
        }
        let findings = MotionAudit.check(tape)
        #expect(findings.isEmpty, "\(findings.map(\.description).joined(separator: "\n"))")
    }
}
