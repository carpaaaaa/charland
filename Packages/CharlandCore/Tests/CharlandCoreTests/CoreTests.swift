import Testing
import Foundation
@testable import CharlandCore

@Suite("Molle")
struct SpringTests {
    @Test("arriva sul bersaglio e si ferma esattamente lì")
    func converges() {
        var a = Animated(0)
        a.target = 100
        var steps = 0
        while a.step(dt: 1.0 / 60.0) { steps += 1 }
        #expect(a.value == 100)
        #expect(a.velocity == 0)
        #expect(steps < 120, "una molla dell'isola non dura più di 2 secondi")
    }

    @Test("un passo lungo equivale a due passi corti", arguments: [0.5, 0.82, 1.0, 1.4])
    func exact(damping: Double) {
        let s = Spring(response: 0.42, damping: damping)
        var v1 = 0.0, x1 = 0.0
        s.step(value: &x1, velocity: &v1, target: 50, dt: 0.02)
        var v2 = 0.0, x2 = 0.0
        s.step(value: &x2, velocity: &v2, target: 50, dt: 0.01)
        s.step(value: &x2, velocity: &v2, target: 50, dt: 0.01)
        #expect(abs(x1 - x2) < 1e-9)
        #expect(abs(v1 - v2) < 1e-7)
    }

    @Test("resta stabile anche con un fotogramma lunghissimo")
    func stable() {
        let s = Spring.shape
        var x = 0.0, v = 0.0
        s.step(value: &x, velocity: &v, target: 10, dt: 5)
        #expect(abs(x - 10) < 0.001)
    }
}

@Suite("Elastico")
struct RubberBandTests {
    @Test("la formula di UIScrollView")
    func formula() {
        // (1 - 1/(x·0,55/d + 1))·d con x = 100, d = 200
        let expected = (1 - 1 / (100 * 0.55 / 200 + 1)) * 200
        #expect(abs(RubberBand.offset(overshoot: 100, dimension: 200) - expected) < 1e-12)
        #expect(RubberBand.offset(overshoot: -100, dimension: 200) == -expected)
    }

    @Test("cresce sempre ma non supera mai la misura")
    func bounded() {
        var last = 0.0
        for x in stride(from: 0.0, through: 5000, by: 25) {
            let v = RubberBand.offset(overshoot: x, dimension: 120)
            #expect(v >= last)
            #expect(v < 120)
            last = v
        }
    }

    @Test("dentro la corsa il livello passa com'è; si assottiglia al massimo del 12%")
    func level() {
        #expect(RubberBand.level(0.4) == 0.4)
        #expect(RubberBand.level(1.5) > 1)
        #expect(RubberBand.level(1.5) < 1.5)
        #expect(RubberBand.level(-0.5) < 0)
        #expect(RubberBand.thinning(stretch: 999, dimension: 100) == 0.12)
    }
}

@Suite("Forma")
struct FieldTests {
    let m = IslandMetrics.air15

    @Test("a riposo è il notch: una sola linea chiusa, delle sue misure")
    func rest() {
        let shape = IslandShape.resting(m)
        let field = IslandField(shape)
        #expect(field.value(x: 0, y: 10) < 0)
        #expect(field.value(x: 0, y: m.notchHeight + 3) > 0)
        #expect(field.value(x: m.halfNotch + 20, y: 10) > 0)
        let loops = ContourTracer().trace(shape)
        #expect(loops.count == 1)
        let xs = loops[0].map(\.x), ys = loops[0].map(\.y)
        #expect(abs(ys.max()! - m.notchHeight) < 0.05)
        #expect(abs(xs.max()! - (m.halfNotch + IslandShape.restFlare)) < 0.3)
        #expect(abs(xs.min()! + (m.halfNotch + IslandShape.restFlare)) < 0.3)
        #expect(ys.min()! >= -0.3)
    }

    @Test("il contorno sta sul bordo al centesimo di punto")
    func accuracy() {
        var shape = IslandShape.resting(m)
        shape.left = 190
        shape.right = 190
        shape.height = 150
        shape.radius = 30
        let field = IslandField(shape)
        let loop = ContourTracer().trace(shape)[0]
        // Lontano dal taglio in alto, dove il campo ha uno spigolo.
        let worst = loop.filter { $0.y > 2 }.map { abs(field.value(x: $0.x, y: $0.y)) }.max()!
        #expect(worst < 0.02)
    }

    @Test("la goccia staccata è una seconda linea; col collo è una sola")
    func split() {
        var state = IslandState()
        state.handle(.started(IslandActivity(id: "a")), now: 0)
        state.handle(.started(IslandActivity(id: "b")), now: 0)
        let apart = IslandLayout.shape(for: state.mode, state: state, metrics: m)
        #expect(ContourTracer().trace(apart).count == 2)

        // A riposo la goccia non gonfia il corpo: il bordo destro del corpo è dove deve.
        let body = ContourTracer().trace(apart)[0]
        #expect(abs(body.map(\.x).max()! - (apart.right + apart.flare)) < 0.3)

        var joined = apart
        joined[.minimal].x -= 7
        joined[.minimal].blend = 22
        #expect(ContourTracer().trace(joined).count == 1)
    }

    @Test("il contorno fine e quello a celle grosse coincidono")
    func narrowBand() {
        var shape = IslandShape.resting(m)
        shape.left = 160
        shape.right = 200
        shape.height = 120
        shape.radius = 26
        shape.wave = 2.5
        shape.wavePhase = 1.1
        let fast = ContourTracer(cell: 0.5, coarse: 8).trace(shape)
        let full = ContourTracer(cell: 0.5, coarse: 1, slack: 1000).trace(shape)
        #expect(fast.count == full.count)
        #expect(fast[0].count == full[0].count)
    }
}

@Suite("Stati")
struct MachineTests {
    @Test("la priorità decide chi sta nel posto compatto; a parità vince l'ultimo")
    func priority() {
        var s = IslandState()
        #expect(s.mode == .rest)
        s.handle(.started(IslandActivity(id: "musica", priority: 1)), now: 0)
        #expect(s.mode == .compact(primary: "musica", secondary: nil))
        s.handle(.started(IslandActivity(id: "timer", priority: 1)), now: 1)
        #expect(s.mode == .compact(primary: "timer", secondary: "musica"))
        s.handle(.started(IslandActivity(id: "agente", priority: 5)), now: 2)
        #expect(s.mode == .compact(primary: "agente", secondary: "timer", tertiary: "musica"), "la terza va nella goccia a sinistra")
        s.handle(.ended(id: "agente"), now: 3)
        #expect(s.mode == .compact(primary: "timer", secondary: "musica"))
    }

    @Test("l'anteprima da puntatore si chiude 0,4 s dopo l'uscita, non prima")
    func hover() {
        var s = IslandState()
        s.handle(.started(IslandActivity(id: "musica")), now: 0)
        s.handle(.pointerEntered, now: 1)
        #expect(s.mode == .expanded(id: "musica"))
        s.handle(.pointerExited, now: 2)
        s.handle(.tick, now: 2.3)
        #expect(s.mode == .expanded(id: "musica"))
        s.handle(.pointerEntered, now: 2.35)
        s.handle(.tick, now: 3)
        #expect(s.mode == .expanded(id: "musica"), "rientrando il puntatore annulla la chiusura")
        s.handle(.pointerExited, now: 3)
        s.handle(.tick, now: 3.41)
        #expect(s.mode == .compact(primary: "musica", secondary: nil))
    }

    @Test("con l'opzione, passando sopra si apre l'attività in corso; senza, la casa; mai quelle di sottofondo")
    func hoverOpensActivity() {
        let home = IslandActivity(id: IslandState.homeID, priority: -10, allowsMinimal: false)
        var s = IslandState()
        s.setHome(home)
        s.handle(.started(IslandActivity(id: "agenti", priority: 1)), now: 0)
        s.handle(.pointerEntered, now: 1)
        #expect(s.mode == .expanded(id: IslandState.homeID), "di serie si apre la casa")
        s.handle(.collapse, now: 2)

        s.hoverOpensActivity = true
        s.handle(.pointerEntered, now: 3)
        #expect(s.mode == .expanded(id: "agenti"))
        #expect(s.expandedByHover, "aperta dal puntatore: si chiude quando esce")
        s.handle(.pointerExited, now: 4)
        s.handle(.tick, now: 4.5)
        #expect(s.mode == .compact(primary: "agenti", secondary: nil))

        // Un clic porta alla casa anche con l'opzione accesa.
        s.handle(.pointerEntered, now: 5)
        s.handle(.expand(id: IslandState.homeID), now: 5.2)
        #expect(s.mode == .expanded(id: IslandState.homeID))
        s.handle(.collapse, now: 6)

        // Mantieni attivo (priorità negativa) da solo: si apre la casa.
        s.handle(.ended(id: "agenti"), now: 7)
        s.handle(.started(IslandActivity(id: "attivo", priority: -1)), now: 7)
        s.handle(.pointerEntered, now: 8)
        #expect(s.mode == .expanded(id: IslandState.homeID))
        s.handle(.collapse, now: 9)

        // Con un timer accanto vince il timer, anche se Mantieni attivo è arrivato dopo.
        s.handle(.started(IslandActivity(id: "timer", priority: 0)), now: 10)
        s.handle(.pointerEntered, now: 11)
        #expect(s.mode == .expanded(id: "timer"))
    }

    @Test("con qualcosa in riproduzione si apre la riproduzione anche con «Apri la casa»; un agente resta davanti con «Apri l'attività»")
    func hoverOpensPlayback() {
        let home = IslandActivity(id: IslandState.homeID, priority: -10, allowsMinimal: false)
        var s = IslandState()
        s.setHome(home)
        s.playbackID = "musica"
        s.handle(.pointerEntered, now: 0)
        #expect(s.mode == .expanded(id: IslandState.homeID), "senza musica la casa")
        s.handle(.collapse, now: 1)

        s.handle(.started(IslandActivity(id: "musica", priority: 0)), now: 2)
        s.handle(.started(IslandActivity(id: "agenti", priority: 1)), now: 2)
        s.handle(.pointerEntered, now: 3)
        #expect(s.mode == .expanded(id: "musica"), "con «Apri la casa» la musica prende il posto della casa")
        s.handle(.collapse, now: 4)

        s.hoverOpensActivity = true
        s.handle(.pointerEntered, now: 5)
        #expect(s.mode == .expanded(id: "agenti"), "con «Apri l'attività» resta davanti la più importante")
        s.handle(.collapse, now: 6)

        s.hoverOpensActivity = false
        s.playbackID = nil
        s.handle(.pointerEntered, now: 7)
        #expect(s.mode == .expanded(id: IslandState.homeID), "con l'opzione spenta la casa")
    }

    @Test("le altre attività dentro quella aperta si possono nascondere")
    func hidesOthers() {
        var s = IslandState()
        s.handle(.started(IslandActivity(id: "musica", priority: 0)), now: 0)
        s.handle(.started(IslandActivity(id: "agenti", priority: 1)), now: 0)
        #expect(s.others(than: "agenti") == ["musica"])
        s.showsOthers = false
        #expect(s.others(than: "agenti").isEmpty)
    }

    @Test("lo slider rientra 1,4 s dopo l'ultimo tasto")
    func slider() {
        var s = IslandState()
        s.handle(.transientBegan(.slider(.volume)), now: 0)
        s.handle(.tick, now: 1.0)
        #expect(s.mode == .transient(.slider(.volume), under: nil))
        s.handle(.transientBegan(.slider(.volume)), now: 1.0)
        s.handle(.tick, now: 2.3)
        #expect(s.mode == .transient(.slider(.volume), under: nil))
        s.handle(.tick, now: 2.41)
        #expect(s.mode == .rest)
    }

    @Test("a riposo e senza attività il puntatore non apre niente")
    func noAccidentalOpen() {
        var s = IslandState()
        s.handle(.pointerEntered, now: 0)
        #expect(s.mode == .rest)
    }

    @Test("con la casa, passare sopra il notch a riposo la apre, e uscendo si chiude")
    func homeOnHover() {
        var s = IslandState()
        s.setHome(IslandActivity(id: IslandState.homeID, leadingWidth: 50, trailingWidth: 54, expandedWidth: 300, expandedHeight: 76))
        s.handle(.pointerEntered, now: 0)
        #expect(s.mode == .expanded(id: IslandState.homeID))
        s.handle(.pointerExited, now: 1)
        s.handle(.tick, now: 1.41)
        #expect(s.mode == .rest)
        // Anche con un'attività in corso si apre la casa; un clic sull'attività apre lei.
        s.handle(.started(IslandActivity(id: "musica")), now: 2)
        s.handle(.pointerEntered, now: 3)
        #expect(s.mode == .expanded(id: IslandState.homeID))
        s.handle(.expand(id: "musica"), now: 3.5)
        #expect(s.mode == .expanded(id: "musica"))
        // Un clic a riposo apre la casa.
        var t = IslandState()
        t.setHome(IslandActivity(id: IslandState.homeID))
        t.handle(.expand(id: nil), now: 0)
        #expect(t.mode == .expanded(id: IslandState.homeID))
    }

    @Test("un'attività che finisce mentre è aperta chiude l'isola")
    func endWhileExpanded() {
        var s = IslandState()
        s.handle(.started(IslandActivity(id: "a")), now: 0)
        s.handle(.expand(id: nil), now: 0)
        s.handle(.ended(id: "a"), now: 1)
        #expect(s.mode == .rest)
    }

    @Test("un'attività che finisce sotto il puntatore lascia la casa aperta, non chiude sotto la mano")
    func endUnderPointer() {
        var s = IslandState()
        s.setHome(IslandActivity(id: IslandState.homeID, priority: -10, allowsMinimal: false))
        s.hoverOpensActivity = true
        s.handle(.started(IslandActivity(id: "timer")), now: 0)
        s.handle(.pointerEntered, now: 1)
        #expect(s.mode == .expanded(id: "timer"))
        s.handle(.ended(id: "timer"), now: 2)
        #expect(s.mode == .expanded(id: IslandState.homeID))
        s.handle(.pointerExited, now: 3)
        s.handle(.tick, now: 3.5)
        #expect(s.mode == .rest, "uscito il puntatore si chiude come sempre")
    }
}

@Suite("Movimento senza saltini")
struct MotionTests {
    let m = IslandMetrics.air15

    /// Recita una sequenza di stati a 60 fotogrammi al secondo e cerca i difetti.
    /// I fotogrammi formano un solo nastro continuo: così si vedono anche i salti
    /// che nascono nell'istante stesso del cambio di stato.
    func play(_ script: [(IslandEvent, hold: Double)], expectSettled: Bool = true) -> [MotionAudit.Finding] {
        var state = IslandState()
        var motion = IslandMotion(metrics: m)
        var findings: [MotionAudit.Finding] = []
        let dt = 1.0 / 60.0
        var tape = [MotionAudit.sample(motion.frame)]
        for (index, (event, hold)) in script.enumerated() {
            state.handle(event, now: motion.now)
            motion.apply(state.mode, state: state)
            var settledAfter: Int?
            let frames = max(1, Int(hold / dt))
            let first = tape.count
            for f in 1...frames {
                let moving = motion.step(dt: dt)
                tape.append(MotionAudit.sample(motion.frame))
                if !moving, settledAfter == nil { settledAfter = f }
            }
            if expectSettled {
                if let settledAfter {
                    if Double(settledAfter) * dt > 2.0 {
                        findings.append(.init(kind: .tooLong, frame: first, track: "passo \(index)", detail: "\(settledAfter) fotogrammi"))
                    }
                    // Dopo la fine dichiarata niente deve più muoversi.
                    let rest = Array(tape[(first + settledAfter - 1)...])
                    findings += MotionAudit.check(rest, settledFrom: 0).filter { $0.kind == .tail }.map {
                        .init(kind: $0.kind, frame: first + $0.frame, track: "passo \(index) · \($0.track)", detail: $0.detail)
                    }
                } else {
                    findings.append(.init(kind: .tooLong, frame: first, track: "passo \(index)", detail: "non si è fermato in \(hold) s"))
                }
                findings += MotionAudit.checkClipping(motion.frame).map {
                    .init(kind: $0.kind, frame: tape.count - 1, track: "passo \(index) · \($0.track)", detail: $0.detail)
                }
            }
        }
        findings += MotionAudit.check(tape)
        return findings
    }

    @Test("riposo, compatto, due gocce, espanso, e ritorno")
    func fullTour() {
        let music = IslandActivity(id: "musica", leadingWidth: 28, trailingWidth: 28, expandedWidth: 360, expandedHeight: 124)
        let timer = IslandActivity(id: "timer", priority: 0, leadingWidth: 24, trailingWidth: 44)
        let findings = play([
            (.started(music), 2.2),
            (.started(timer), 2.2),
            (.expand(id: "musica"), 2.2),
            (.collapse, 2.2),
            (.ended(id: "timer"), 2.2),
            (.ended(id: "musica"), 2.2),
        ])
        #expect(findings.isEmpty, "\(findings.map(\.description).joined(separator: "\n"))")
    }

    @Test("slider e dettatura in tutte le varianti")
    func transients() {
        var script: [(IslandEvent, hold: Double)] = [
            (.transientBegan(.slider(.volume)), 2.2),
            (.transientEnded, 2.2),
            (.transientBegan(.slider(.brightness)), 2.2),
            (.transientEnded, 2.2),
        ]
        for style in DictationStyle.allCases {
            script.append((.transientBegan(.dictation(style: style, liveText: false, handsFree: false)), 2.2))
            script.append((.transientBegan(.dictation(style: style, liveText: true, handsFree: false)), 2.2))
            script.append((.transientEnded, 2.2))
        }
        let findings = play(script)
        #expect(findings.isEmpty, "\(findings.map(\.description).joined(separator: "\n"))")
    }

    @Test("interrompere un movimento a metà non fa salti")
    func interrupted() {
        let music = IslandActivity(id: "musica", expandedWidth: 360, expandedHeight: 124)
        let script: [(IslandEvent, hold: Double)] = [
            (.started(music), 0.12),
            (.expand(id: nil), 0.10),
            (.collapse, 0.08),
            (.expand(id: nil), 0.15),
            (.ended(id: "musica"), 2.2),
        ]
        // Nei passi interrotti il movimento non si ferma: conta solo che non ci siano salti.
        let findings = play(script, expectSettled: false)
        #expect(findings.isEmpty, "\(findings.map(\.description).joined(separator: "\n"))")
    }

    @Test("un contenuto nuovo ferma la forma solo se era già ferma")
    func holdOnlyWhenStill() {
        let music = IslandActivity(id: "musica", expandedWidth: 360, expandedHeight: 124)
        let dt = 1.0 / 60.0
        var state = IslandState()
        var motion = IslandMotion(metrics: m)

        // Da ferma: il primo passo aspetta, così la vista nuova nasce a isola immobile.
        state.handle(.started(music), now: 0)
        motion.apply(state.mode, state: state)
        let atRest = motion.shape
        let held = motion.step(dt: dt)
        #expect(held)
        #expect(motion.shape == atRest, "da ferma la forma aspetta un passo")
        motion.step(dt: dt)
        #expect(motion.shape != atRest)

        // In corsa: si apre mentre la forma compatta rimbalza ancora. Nessun fotogramma congelato.
        for _ in 0..<5 { motion.step(dt: dt) }
        #expect(motion.isMoving)
        state.handle(.expand(id: nil), now: motion.now)
        motion.apply(state.mode, state: state)
        #expect(motion.frame.layers.contains { $0.slot == .expanded }, "la vista nuova nasce lo stesso, in corsa")
        var previous = motion.shape
        for f in 0..<20 {
            motion.step(dt: dt)
            let current = motion.shape
            #expect(current != previous, "fotogramma \(f) congelato a metà corsa")
            previous = current
        }

        // Lo stesso con la voce che fa respirare il bordo: il testo dal vivo arriva in corsa.
        var voice = IslandMotion(metrics: m)
        var dictation = IslandState()
        dictation.handle(.transientBegan(.dictation(style: .soffio, liveText: false, handsFree: false)), now: 0)
        voice.apply(dictation.mode, state: dictation)
        for _ in 0..<90 { voice.step(dt: dt) }
        voice.setWave(amplitude: 1.2)
        for _ in 0..<3 { voice.step(dt: dt) }
        dictation.handle(.transientBegan(.dictation(style: .soffio, liveText: true, handsFree: false)), now: voice.now)
        voice.apply(dictation.mode, state: dictation)
        let breathing = voice.shape
        voice.step(dt: dt)
        #expect(voice.shape != breathing, "il respiro non si ferma quando arriva il testo")
    }

    @Test("la casa si apre e si chiude senza saltini")
    func homeTour() {
        var state = IslandState()
        state.setHome(IslandActivity(id: IslandState.homeID, leadingWidth: 50, trailingWidth: 54, expandedWidth: 300, expandedHeight: 76))
        var motion = IslandMotion(metrics: m)
        var tape = [MotionAudit.sample(motion.frame)]
        for event in [IslandEvent.pointerEntered, .collapse] {
            state.handle(event, now: motion.now)
            motion.apply(state.mode, state: state)
            for _ in 0..<130 {
                motion.step(dt: 1.0 / 60.0)
                tape.append(MotionAudit.sample(motion.frame))
            }
        }
        let findings = MotionAudit.check(tape)
        #expect(findings.isEmpty, "\(findings.map(\.description).joined(separator: "\n"))")
    }

    @Test("la goccia parte senza gonfiare il bordo")
    func dripStart() {
        var motion = IslandMotion(metrics: m)
        var state = IslandState()
        state.handle(.transientBegan(.dictation(style: .soffio, liveText: false, handsFree: false)), now: 0)
        motion.apply(state.mode, state: state)
        for _ in 0..<90 { motion.step(dt: 1.0 / 60.0) }
        var tape = [MotionAudit.sample(motion.frame)]
        motion.startDrip(toX: -220, toY: 520)
        state.handle(.transientEnded, now: motion.now)
        motion.apply(state.mode, state: state)
        for _ in 0..<60 {
            motion.step(dt: 1.0 / 60.0)
            tape.append(MotionAudit.sample(motion.frame))
        }
        let jumps = MotionAudit.check(tape).filter { $0.kind == .jump }
        #expect(jumps.isEmpty, "\(jumps.map(\.description).joined(separator: "\n"))")
    }

    @Test("la goccia cola fino al bersaglio e poi sparisce")
    func drip() {
        var motion = IslandMotion(metrics: m)
        var state = IslandState()
        state.handle(.transientBegan(.dictation(style: .soffio, liveText: false, handsFree: false)), now: 0)
        motion.apply(state.mode, state: state)
        for _ in 0..<60 { motion.step(dt: 1.0 / 60.0) }
        motion.startDrip(toX: -220, toY: 520)
        var sawDetached = false
        var last: DripState?
        var maxStep = 0.0
        for _ in 0..<40 {
            motion.step(dt: 1.0 / 60.0)
            if let d = motion.frame.drip {
                if let last { maxStep = max(maxStep, hypot(d.headX - last.headX, d.headY - last.headY)) }
                if !d.attached { sawDetached = true }
                last = d
            }
        }
        #expect(sawDetached)
        #expect(motion.frame.drip == nil)
        #expect(!motion.shape[.drip].isVisible)
        #expect(abs((last?.headX ?? 0) + 220) < 12 && abs((last?.headY ?? 0) - 520) < 12)
        #expect(maxStep < 90, "la goccia non deve teletrasportarsi")
    }
}

@Suite("Puntatore")
struct HoverTests {
    @Test("chi passa veloce verso la barra dei menu non apre niente")
    func passingThrough() {
        var gate = HoverGate()
        // 1500 punti al secondo, 80 ms dentro l'isola.
        var decisions: [HoverGate.Decision] = []
        for i in 0..<6 {
            decisions.append(gate.pointer(inside: true, x: Double(i) * 25, y: 10, now: Double(i) / 60))
        }
        decisions.append(gate.pointer(inside: false, x: 200, y: 60, now: 6.0 / 60))
        #expect(decisions.allSatisfy { $0 == .none })
    }

    @Test("chi rallenta sull'isola la apre dopo 60 ms, prima del tempo di sosta")
    func slowingDown() {
        var gate = HoverGate()
        #expect(gate.pointer(inside: true, x: 0, y: 10, now: 0) == .none)
        #expect(gate.pointer(inside: true, x: 30, y: 10, now: 1.0 / 60) == .none)
        #expect(gate.pointer(inside: true, x: 32, y: 10, now: 2.0 / 60) == .none, "33 ms sono troppo pochi")
        #expect(gate.pointer(inside: true, x: 34, y: 10, now: 4.0 / 60) == .entered)
        #expect(gate.pointer(inside: false, x: 300, y: 80, now: 1) == .exited)
    }

    @Test("un passaggio veloce con una sosta di un fotogramma sul notch non la apre")
    func fastPassWithHiccup() {
        var gate = HoverGate()
        _ = gate.pointer(inside: false, x: -100, y: 5, now: 0)
        #expect(gate.pointer(inside: true, x: -20, y: 5, now: 0.016) == .none)
        #expect(gate.pointer(inside: true, x: 0, y: 5, now: 0.032) == .none)
        #expect(gate.pointer(inside: true, x: 0, y: 5, now: 0.048) == .none, "fermo un fotogramma: troppo presto")
        #expect(gate.pointer(inside: false, x: 100, y: 5, now: 0.064) == .none)
    }

    @Test("chi si ferma di colpo apre dopo 120 ms, grazie al timer")
    func stopping() {
        var gate = HoverGate()
        _ = gate.pointer(inside: false, x: -40, y: 10, now: 0)
        #expect(gate.pointer(inside: true, x: 0, y: 10, now: 0.01) == .none)
        #expect(gate.tick(now: 0.08) == .none)
        #expect(gate.pendingCheck == 0.13)
        #expect(gate.tick(now: 0.135) == .entered)
    }
}

@Suite("Voce: livello")
struct LevelTests {
    @Test("sale in fretta e scende piano")
    func attackRelease() {
        var s = LevelSmoother()
        for _ in 0..<3 { s.feed(1, dt: 1.0 / 60) }
        #expect(s.level > 0.75, "dopo 50 ms è quasi su")
        for _ in 0..<3 { s.feed(0, dt: 1.0 / 60) }
        #expect(s.level > 0.5, "dopo altri 50 ms è ancora a metà")
        for _ in 0..<120 { s.feed(0, dt: 1.0 / 60) }
        #expect(s.level == 0, "nel silenzio torna piatta")
    }
}
