import Testing
import Foundation
@testable import CharlandCore

/// Le forme su cui si misura il tracciatore: la casa aperta e un giro intero di movimenti.
enum TracerFixtures {
    static let m = IslandMetrics.air15

    /// La casa aperta con le pillole delle attività e la fila del vassoio: la forma più grande.
    static func home(glassLip: Double = 30) -> IslandShape {
        var state = IslandState()
        state.setHome(IslandActivity(id: IslandState.homeID, priority: -10, leadingWidth: 54, trailingWidth: 56,
                                     expandedWidth: 340, expandedHeight: 78 + 78 + 42, allowsMinimal: false))
        state.handle(.pointerEntered, now: 0)
        var tuning = IslandTuning()
        tuning.glassLip = glassLip
        return IslandLayout.shape(for: state.mode, state: state, metrics: m, tuning: tuning)
    }

    /// A metà dell'apertura dal compatto con la seconda goccia: il corpo corre e la goccia rientra.
    static func midTransition() -> IslandShape {
        var state = IslandState()
        var motion = IslandMotion(metrics: m)
        state.handle(.started(IslandActivity(id: "musica", leadingWidth: 26, trailingWidth: 26, expandedWidth: 320, expandedHeight: 104)), now: 0)
        state.handle(.started(IslandActivity(id: "timer", priority: -1, leadingWidth: 22, trailingWidth: 44)), now: 0)
        motion.apply(state.mode, state: state)
        for _ in 0..<90 { motion.step(dt: 1.0 / 60.0) }
        state.handle(.expand(id: "musica"), now: motion.now)
        motion.apply(state.mode, state: state)
        for _ in 0..<7 { motion.step(dt: 1.0 / 60.0) }
        return motion.shape
    }

    /// Un giro con tutto: gocce, apertura, casa, slider con l'elastico, dettatura col respiro,
    /// pressione e goccia che cola. Una forma ogni `every` fotogrammi.
    static func tour(every: Int) -> [IslandShape] {
        var state = IslandState()
        state.setHome(IslandActivity(id: IslandState.homeID, priority: -10, leadingWidth: 54, trailingWidth: 56,
                                     expandedWidth: 340, expandedHeight: 198, allowsMinimal: false))
        var motion = IslandMotion(metrics: m)
        var shapes: [IslandShape] = []
        var frame = 0
        func run(_ frames: Int, _ each: (inout IslandMotion, Int) -> Void = { _, _ in }) {
            for f in 0..<frames {
                each(&motion, f)
                motion.step(dt: 1.0 / 60.0)
                frame += 1
                if frame % every == 0 { shapes.append(motion.shape) }
            }
        }
        func send(_ event: IslandEvent) {
            state.handle(event, now: motion.now)
            motion.apply(state.mode, state: state)
        }
        send(.started(IslandActivity(id: "musica", leadingWidth: 26, trailingWidth: 26, expandedWidth: 320, expandedHeight: 104)))
        run(60)
        send(.started(IslandActivity(id: "timer", priority: -1, leadingWidth: 22, trailingWidth: 44)))
        run(70)
        send(.expand(id: "musica"))
        run(60)
        send(.collapse)
        run(60)
        send(.pointerEntered)
        run(60)
        motion.setPressed(true)
        run(10)
        motion.setPressed(false)
        send(.pointerExited)
        send(.tick)
        send(.collapse)
        run(60)
        send(.transientBegan(.slider(.volume)))
        run(50) { motion, f in motion.setEdgeStretch(left: 0, right: Double(min(f, 25)) * 0.8) }
        motion.setEdgeStretch(left: 0, right: 0)
        send(.transientEnded)
        run(40)
        send(.transientBegan(.dictation(style: .soffio, liveText: true, handsFree: false)))
        run(70) { motion, f in motion.setWave(amplitude: 1.5 * abs(sin(Double(f) * 0.3))) }
        motion.setWave(amplitude: 0)
        motion.startDrip(toX: -220, toY: 520)
        send(.transientEnded)
        run(50)
        return shapes
    }
}

@Suite("Tracciatore: stesso contorno di prima")
struct TracerEquivalenceTests {
    /// Quanto la linea semplificata si scosta da quella piena: ogni punto pieno dalla sua corda
    /// e, al contrario, tre punti di ogni corda dal tratto pieno che sostituisce.
    /// Le due linee devono partire dallo stesso punto.
    static func deviation(full: [ContourPoint], simple: [ContourPoint]) -> (forward: Double, back: Double) {
        func distance(_ p: ContourPoint, _ a: ContourPoint, _ b: ContourPoint) -> Double {
            let abx = b.x - a.x, aby = b.y - a.y
            let length = abx * abx + aby * aby
            let t = length > 0 ? min(1, max(0, ((p.x - a.x) * abx + (p.y - a.y) * aby) / length)) : 0
            return hypot(p.x - a.x - t * abx, p.y - a.y - t * aby)
        }
        let n = full.count
        guard simple.first == full.first else { return (.infinity, .infinity) }
        var forward = 0.0, back = 0.0
        var j = 0
        for s in simple.indices {
            let a = simple[s]
            let b = simple[(s + 1) % simple.count]
            var e = j + 1
            if s + 1 < simple.count {
                while e < n, full[e] != b { e += 1 }
                if e == n { return (.infinity, .infinity) }
            } else {
                e = n
            }
            for t in j...e { forward = max(forward, distance(full[t % n], a, b)) }
            for f in [0.25, 0.5, 0.75] {
                let p = ContourPoint(x: a.x + (b.x - a.x) * f, y: a.y + (b.y - a.y) * f)
                var nearest = Double.infinity
                for t in j..<e { nearest = min(nearest, distance(p, full[t % n], full[(t + 1) % n])) }
                back = max(back, nearest)
            }
            j = e
        }
        return (forward, back)
    }

    @Test("stessi punti di prima, poi semplificati entro il ventesimo di punto")
    func sameOutline() {
        let legacy = LegacyContourTracer()
        let exact = ContourTracer(tolerance: 0)
        let tracer = ContourTracer()
        let shapes = TracerFixtures.tour(every: 9)
            + [TracerFixtures.home(), TracerFixtures.home(glassLip: 0), TracerFixtures.midTransition()]
        var worstForward = 0.0, worstBack = 0.0, worstArea = 0.0
        var oldPoints = 0, newPoints = 0, mismatched = 0
        for (index, shape) in shapes.enumerated() {
            let old = legacy.trace(shape)
            let full = exact.trace(shape)
            let simple = tracer.trace(shape)
            #expect(old.count == full.count && full.count == simple.count, "forma \(index): \(old.count) \(full.count) \(simple.count)")
            guard old.count == full.count, full.count == simple.count else { continue }
            for (k, loop) in full.enumerated() {
                // Stessi punti nello stesso verso: cambia solo da dove parte la linea.
                guard let match = old.first(where: { $0.count == loop.count && $0.contains(loop[0]) }),
                      let offset = match.firstIndex(of: loop[0]) else {
                    mismatched += 1
                    continue
                }
                if !loop.indices.allSatisfy({ match[(offset + $0) % match.count] == loop[$0] }) { mismatched += 1 }
                let d = Self.deviation(full: loop, simple: simple[k])
                worstForward = max(worstForward, d.forward)
                worstBack = max(worstBack, d.back)
                let a0 = ContourTracer.signedArea(match), a1 = ContourTracer.signedArea(simple[k])
                #expect(a0.sign == a1.sign, "forma \(index): il verso è cambiato")
                worstArea = max(worstArea, abs(a1 - a0) / abs(a0))
                oldPoints += match.count
                newPoints += simple[k].count
            }
        }
        print(String(format: "[confronto] %d forme: scarto massimo %.4f pt (corde %.4f pt), area %.5f%%, punti %d -> %d",
                     shapes.count, worstForward, worstBack, worstArea * 100, oldPoints, newPoints))
        #expect(mismatched == 0, "\(mismatched) linee non hanno gli stessi punti di prima")
        #expect(worstForward <= 0.05 + 1e-9)
        #expect(worstBack <= 0.05 + 1e-9)
        #expect(newPoints * 5 < oldPoints, "la semplificazione deve togliere almeno quattro punti su cinque")
    }

    @Test("il campo dà gli stessi numeri di prima, al bit")
    func sameField() {
        var shapes = TracerFixtures.tour(every: 23) + [TracerFixtures.home(), TracerFixtures.midTransition()]
        // Anche il respiro con la goccia attaccata e una goccia senza fusione.
        var odd = TracerFixtures.home()
        odd.wave = 2.5
        odd.wavePhase = 0.7
        odd.press = 0.6
        odd[.minimal] = Blob(x: odd.right + 6, y: 16, halfWidth: 12, halfHeight: 12, radius: 30, blend: 0)
        odd[.drip] = Blob(x: 4, y: odd.height + 3, halfWidth: 6, halfHeight: 11, radius: 6, blend: 18)
        shapes.append(odd)
        var compared = 0
        for shape in shapes {
            let old = LegacyIslandField(shape), new = IslandField(shape)
            let b = shape.bounds(margin: 40)
            var y = b.minY - 20
            while y < b.maxY {
                var x = b.minX
                while x < b.maxX {
                    let a = old.value(x: x, y: y), c = new.value(x: x, y: y)
                    if a.bitPattern != c.bitPattern {
                        Issue.record("(\(x), \(y)): \(a) prima, \(c) adesso")
                        return
                    }
                    compared += 1
                    x += 0.97
                }
                y += 1.13
            }
        }
        #expect(compared > 500_000)
    }

    @Test("col margine stretto (senza respiro) trova le stesse linee della griglia intera")
    func tightBandMatchesFullGrid() {
        /// Lo stesso campo, ma senza dire di quanto si scosta: il tracciatore non stringe niente.
        struct Hidden: ScalarField {
            let field: IslandField
            func value(x: Double, y: Double) -> Double { field.value(x: x, y: y) }
        }
        let fast = ContourTracer(tolerance: 0)
        let full = ContourTracer(coarse: 1, slack: 1000, tolerance: 0)
        var breathing = TracerFixtures.home()
        breathing.wave = 0.3
        breathing.wavePhase = 2
        for shape in [TracerFixtures.home(), TracerFixtures.midTransition(), breathing] + TracerFixtures.tour(every: 160) {
            let b = shape.bounds()
            let a = fast.trace(IslandField(shape), minX: b.minX, minY: b.minY, maxX: b.maxX, maxY: b.maxY)
            let c = full.trace(Hidden(field: IslandField(shape)), minX: b.minX, minY: b.minY, maxX: b.maxX, maxY: b.maxY)
            #expect(a == c)
        }
    }

    @Test("con il respiro della voce, da piano a fortissimo, la fascia stretta trova le stesse linee della griglia intera")
    func waveSweepMatchesFullGrid() {
        struct Hidden: ScalarField {
            let field: IslandField
            func value(x: Double, y: Double) -> Double { field.value(x: x, y: y) }
        }
        let fast = ContourTracer(tolerance: 0)
        let full = ContourTracer(coarse: 1, slack: 1000, tolerance: 0)
        // Tutte le forme del giro (compatta, dettatura stretta, casa, gocce), col respiro forte: sopra 0,725 il
        // margine fisso di prima non bastava. Fino al massimo che la voce può dare (1,5 punti), due fasi.
        for base in TracerFixtures.tour(every: 53) + [TracerFixtures.home(), TracerFixtures.midTransition()] {
            for wave in [0.8, 1.5] {
                for phase in [0.0, 3.9] {
                    var shape = base
                    shape.wave = wave
                    shape.wavePhase = phase
                    let b = shape.bounds()
                    let a = fast.trace(IslandField(shape), minX: b.minX, minY: b.minY, maxX: b.maxX, maxY: b.maxY)
                    let c = full.trace(Hidden(field: IslandField(shape)), minX: b.minX, minY: b.minY, maxX: b.maxX, maxY: b.maxY)
                    #expect(a == c, "respiro \(wave), fase \(phase)")
                }
            }
        }
    }

    @Test("lo stesso tracciatore usato di fila dà sempre lo stesso contorno")
    func reuse() {
        // I quaderni di lavoro passano da una forma all'altra: grande, piccola, di nuovo grande.
        let tracer = ContourTracer()
        let shapes = TracerFixtures.tour(every: 23)
        let fresh = shapes.map { ContourTracer().trace($0) }
        for _ in 0..<2 {
            for (shape, expected) in zip(shapes, fresh) {
                #expect(tracer.trace(shape) == expected)
            }
        }
    }
}

/// Conta quante volte si calcola il campo.
final class Counter: @unchecked Sendable { var value = 0 }
struct CountingField: ScalarField {
    let field: IslandField
    let counter: Counter
    func value(x: Double, y: Double) -> Double {
        counter.value += 1
        return field.value(x: x, y: y)
    }
    var distortion: Double? { field.distortion }
}

@Suite("Tracciatore: misure", .serialized)
struct TracerBenchTests {
    /// Tempo medio per chiamata, in millisecondi.
    /// Il migliore di cinque giri: toglie il rumore delle altre app.
    static func time(_ n: Int, _ body: () -> Int) -> (ms: Double, sink: Int) {
        var sink = 0
        var best = Double.infinity
        let clock = ContinuousClock()
        for _ in 0..<5 {
            let d = clock.measure {
                for _ in 0..<n { sink &+= body() }
            }
            let seconds = Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
            best = min(best, seconds * 1000 / Double(n))
        }
        return (best, sink)
    }

    @Test("tempi del vecchio e del nuovo tracciatore",
          .enabled(if: ProcessInfo.processInfo.environment["CHARLAND_BENCH"] != nil))
    func bench() {
        let legacy = LegacyContourTracer()
        let tracer = ContourTracer()
        let cases: [(String, IslandShape)] = [
            ("casa aperta", TracerFixtures.home()),
            ("a metà apertura", TracerFixtures.midTransition()),
            ("compatto", IslandLayout.shape(for: .compact(primary: "a", secondary: nil),
                                            state: { var s = IslandState(); s.handle(.started(IslandActivity(id: "a")), now: 0); return s }(),
                                            metrics: TracerFixtures.m)),
        ]
        let n = 100
        for (name, shape) in cases {
            let b = shape.bounds()
            let oldCount = Counter(), newCount = Counter()
            _ = legacy.trace(CountingField(field: IslandField(shape), counter: oldCount), minX: b.minX, minY: b.minY, maxX: b.maxX, maxY: b.maxY)
            _ = tracer.trace(CountingField(field: IslandField(shape), counter: newCount), minX: b.minX, minY: b.minY, maxX: b.maxX, maxY: b.maxY)
            print("[banco] \(name): valori del campo \(oldCount.value) -> \(newCount.value)")
            let field = IslandField(shape)
            let perEval = Self.time(20) {
                var s = 0.0
                for k in 0..<10_000 { s += field.value(x: b.minX + Double(k % 400), y: Double(k / 400) * 9) }
                return s < 0 ? 1 : 0
            }
            print(String(format: "[banco] %@: un valore del campo %.1f ns", name, perEval.ms * 1e6 / 10_000))
            _ = legacy.trace(shape)
            _ = tracer.trace(shape)
            let old = Self.time(n) { legacy.trace(shape).reduce(0) { $0 + $1.count } }
            // Senza la memoria dell'ultima forma: ogni giro rifà tutto, come a ogni fotogramma in corsa.
            let new = Self.time(n) {
                let bounds = shape.bounds()
                return tracer.trace(IslandField(shape), minX: bounds.minX, minY: bounds.minY,
                                    maxX: bounds.maxX, maxY: bounds.maxY).reduce(0) { $0 + $1.count }
            }
            let cached = Self.time(n) { tracer.trace(shape).count }
            print(String(format: "[banco] %@: stessa forma di prima %.4f ms", name, cached.ms))
            let oldPoints = legacy.trace(shape).map(\.count)
            let newPoints = tracer.trace(shape).map(\.count)
            print(String(format: "[banco] %@: vecchio %.3f ms, nuovo %.3f ms (x%.1f); punti %@ -> %@ (%d %d)",
                         name, old.ms, new.ms, old.ms / max(new.ms, 1e-9),
                         "\(oldPoints)", "\(newPoints)", old.sink % 7, new.sink % 7))
        }

        // Il passo delle molle più il fotogramma, come li chiama il motore.
        var motion = IslandMotion(metrics: TracerFixtures.m)
        var state = IslandState()
        state.handle(.started(IslandActivity(id: "musica")), now: 0)
        state.handle(.started(IslandActivity(id: "timer", priority: -1)), now: 0)
        motion.apply(state.mode, state: state)
        var open = false
        let steps = Self.time(20_000) {
            if !motion.step(dt: 1.0 / 60.0) {
                // Sempre in movimento: apre e chiude a turno.
                open.toggle()
                state.handle(open ? .expand(id: nil) : .collapse, now: motion.now)
                motion.apply(state.mode, state: state)
            }
            return motion.frame.layers.count
        }
        print(String(format: "[banco] passo + fotogramma: %.4f ms (%d)", steps.ms, steps.sink % 7))
    }
}
