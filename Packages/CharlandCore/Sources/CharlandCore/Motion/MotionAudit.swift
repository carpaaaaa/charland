import Foundation

/// Il controllo del movimento, fotogramma per fotogramma.
/// Carpa vede un saltino di un fotogramma: contare i fotogrammi persi non basta.
/// Qui si misura quello che si vede davvero: il bordo della forma e la presenza dei contenuti.
public enum MotionAudit {
    public enum Kind: String, Sendable {
        /// Un valore cambia di colpo in un fotogramma, senza che i fotogrammi vicini lo annuncino.
        case jump
        /// Qualcosa si muove ancora dopo che il movimento è dichiarato finito.
        case tail
        /// Un contenuto esce dalla forma quando tutto è fermo.
        case clipped
        /// Il contenitore di un contenuto cambia misura mentre è visibile.
        case resized
        /// Il movimento dura più di 2 secondi.
        case tooLong
        /// La forma resta identica per un fotogramma mentre prima e dopo corre: un inciampo.
        case stall
    }

    public struct Finding: Sendable, CustomStringConvertible {
        public var kind: Kind
        public var frame: Int
        public var track: String
        public var detail: String

        public init(kind: Kind, frame: Int, track: String, detail: String) {
            self.kind = kind
            self.frame = frame
            self.track = track
            self.detail = detail
        }

        public var description: String { "[\(kind.rawValue)] fotogramma \(frame), \(track): \(detail)" }
    }

    /// Quello che si misura di un fotogramma.
    public struct Sample: Sendable {
        public var minX: Double
        public var maxX: Double
        public var maxY: Double
        public var area: Double
        public var loops: Int
        public var layers: [ContentLayer]
        public var drip: DripState?
    }

    public static func sample(_ frame: IslandFrame, tracer: ContourTracer = ContourTracer(cell: 0.5)) -> Sample {
        let loops = tracer.trace(frame.shape)
        var minX = Double.infinity, maxX = -Double.infinity, maxY = -Double.infinity, area = 0.0
        for loop in loops {
            var twice = 0.0
            for (i, p) in loop.enumerated() {
                let q = loop[(i + 1) % loop.count]
                twice += p.x * q.y - q.x * p.y
                minX = min(minX, p.x)
                maxX = max(maxX, p.x)
                maxY = max(maxY, p.y)
            }
            area += abs(twice) / 2
        }
        // La goccia staccata vola fuori dall'isola: conta anche lei, così il distacco non sembra un salto.
        if let drip = frame.drip, !drip.attached {
            maxY = max(maxY, drip.headY + drip.headRadius)
            area += Double.pi * (drip.headRadius * drip.headRadius + drip.tailRadius * drip.tailRadius)
        }
        return Sample(minX: minX, maxX: maxX, maxY: maxY, area: area, loops: loops.count,
                      layers: frame.layers, drip: frame.drip)
    }

    /// Cerca i difetti in una sequenza di fotogrammi presi a passo costante.
    /// `settledFrom` è il primo fotogramma dopo la fine dichiarata del movimento.
    public static func check(_ samples: [Sample], settledFrom: Int? = nil, dt: Double = 1.0 / 60.0) -> [Finding] {
        var findings: [Finding] = []
        guard samples.count >= 3 else { return findings }

        // Il fotogramma in cui la goccia arriva nel cursore e sparisce: lì il bordo basso
        // torna di colpo all'isola, ed è voluto (la goccia è già rimpicciolita fino a zero).
        var landings = Set<Int>()
        for i in 1..<samples.count where samples[i - 1].drip != nil && samples[i].drip == nil {
            landings.insert(i)
        }

        func audit(_ name: String, _ values: [Double], floor: Double, ratio: Double = 4, skip: Set<Int> = []) {
            var deltas = [0.0]
            for i in 1..<values.count { deltas.append(values[i] - values[i - 1]) }
            for i in 1..<values.count where !skip.contains(i) {
                let d = abs(deltas[i])
                guard d > floor else { continue }
                let before = abs(deltas[i - 1])
                let after = i + 1 < values.count ? abs(deltas[i + 1]) : before
                if d > ratio * max(before, after) + floor {
                    findings.append(Finding(kind: .jump, frame: i, track: name,
                                            detail: String(format: "salto di %.2f (prima %.2f, dopo %.2f)", deltas[i], before, after)))
                }
            }
            if let settledFrom, settledFrom < values.count {
                for i in (settledFrom + 1)..<values.count where abs(values[i] - values[settledFrom]) > 0.001 {
                    findings.append(Finding(kind: .tail, frame: i, track: name,
                                            detail: String(format: "si muove ancora di %.3f", values[i] - values[settledFrom])))
                    break
                }
            }
        }

        // Fotogramma congelato: identico al precedente, con il movimento in corsa prima e dopo.
        // Il salto non lo vede (la differenza è zero), ma l'occhio sì.
        func moved(_ a: Sample, _ b: Sample) -> Bool {
            max(abs(b.minX - a.minX), abs(b.maxX - a.maxX), abs(b.maxY - a.maxY)) > 0.3 || abs(b.area - a.area) > 30
        }
        if samples.count >= 4 {
            for i in 2..<(samples.count - 1) {
                let a = samples[i - 1], b = samples[i]
                guard a.minX == b.minX, a.maxX == b.maxX, a.maxY == b.maxY, a.area == b.area else { continue }
                if moved(samples[i - 2], a), moved(b, samples[i + 1]) {
                    findings.append(Finding(kind: .stall, frame: i, track: "forma", detail: "ferma un fotogramma in mezzo al movimento"))
                }
            }
        }

        audit("bordo sinistro", samples.map(\.minX), floor: 0.6)
        audit("bordo destro", samples.map(\.maxX), floor: 0.6)
        audit("bordo basso", samples.map(\.maxY), floor: 0.6, skip: landings)
        audit("area", samples.map(\.area), floor: 40, skip: landings)

        // Contenuti: presenza continua e cornice ferma mentre sono visibili.
        var keys: [String] = []
        for s in samples {
            for l in s.layers where !keys.contains("\(l.slot.rawValue):\(l.id)") {
                keys.append("\(l.slot.rawValue):\(l.id)")
            }
        }
        for key in keys {
            var presence: [Double] = []
            var lastFrame: IslandRect?
            for (i, s) in samples.enumerated() {
                let layer = s.layers.first { "\($0.slot.rawValue):\($0.id)" == key }
                presence.append(layer?.presence ?? 0)
                if let layer, layer.presence > 0.05 {
                    if let lastFrame, lastFrame != layer.frame,
                       abs(lastFrame.width - layer.frame.width) > 0.01 || abs(lastFrame.height - layer.frame.height) > 0.01 {
                        findings.append(Finding(kind: .resized, frame: i, track: key,
                                                detail: "il contenitore cambia misura mentre si vede"))
                    }
                    lastFrame = layer.frame
                } else {
                    lastFrame = nil
                }
            }
            audit("presenza \(key)", presence, floor: 0.1)
        }

        if let settledFrom, Double(settledFrom) * dt > 2.0 {
            findings.append(Finding(kind: .tooLong, frame: settledFrom, track: "durata",
                                    detail: String(format: "%.2f s", Double(settledFrom) * dt)))
        }
        return findings
    }

    /// A movimento finito ogni contenuto deve stare dentro la forma.
    /// I contenuti compatti sono simboli centrati: conta la parte centrale della cornice.
    /// Quelli espansi hanno gli angoli arrotondati, concentrici con l'isola: conta il punto
    /// più esterno dell'angolo arrotondato, non lo spigolo vuoto.
    public static func checkClipping(_ frame: IslandFrame, innerRadius: Double = 16) -> [Finding] {
        let field = IslandField(frame.shape)
        var findings: [Finding] = []
        for layer in frame.layers where layer.presence > 0.5 {
            let f = layer.frame
            let insetX: Double
            let insetY: Double
            if layer.slot == .expanded {
                insetX = innerRadius * 0.293
                insetY = innerRadius * 0.293
            } else {
                insetX = f.width * 0.2
                insetY = f.height * 0.2
            }
            let corners = [(f.x + insetX, f.y + insetY), (f.maxX - insetX, f.y + insetY),
                           (f.x + insetX, f.maxY - insetY), (f.maxX - insetX, f.maxY - insetY)]
            for (x, y) in corners where field.value(x: x, y: max(0.5, y)) > 0.25 {
                findings.append(Finding(kind: .clipped, frame: 0, track: "\(layer.slot.rawValue):\(layer.id)",
                                        detail: String(format: "il punto (%.1f, %.1f) esce dalla forma", x, y)))
                break
            }
        }
        return findings
    }
}
