import Foundation

/// Un punto del contorno, in punti.
public struct ContourPoint: Sendable, Equatable {
    public var x: Double
    public var y: Double
    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

/// Trova il bordo di un campo scalare (dove vale zero) come linee chiuse.
///
/// Usa i "marching squares" su una griglia fine, ma calcola il campo solo vicino al bordo:
/// prima guarda celle grosse, e scende nel dettaglio solo dove il bordo può passare.
/// Vale perché il campo è una distanza: se al centro di una cella grossa il bordo è più
/// lontano di mezza diagonale, in quella cella il bordo non c'è.
///
/// Gira a ogni fotogramma mentre l'isola si muove, quindi tiene i suoi quaderni di lavoro
/// da una chiamata all'altra: niente memoria nuova per ogni cella, niente griglia da azzerare.
/// Per questo è una classe e non va condivisa fra thread: ognuno il suo tracciatore.
public final class ContourTracer {
    /// Lato della cella fine, in punti. 0,5 = un pixel su uno schermo Retina.
    public var cell: Double
    /// Quante celle fini per lato in una cella grossa.
    public var coarse: Int
    /// Margine di sicurezza sulla distanza (il respiro del bordo deforma appena il campo).
    public var slack: Double
    /// Di quanto la linea semplificata può scostarsi da quella piena, in punti.
    /// 0,05 è un decimo di pixel: i tratti dritti diventano un segmento solo e il Path
    /// passa da migliaia di punti a qualche centinaio. Zero = nessuna semplificazione.
    public var tolerance: Double

    public init(cell: Double = 0.5, coarse: Int = 8, slack: Double = 1.5, tolerance: Double = 0.05) {
        self.cell = cell
        self.coarse = max(1, coarse)
        self.slack = slack
        self.tolerance = tolerance
    }

    // MARK: Quaderni di lavoro

    /// Un nodo della griglia fine: il valore del campo e, per i due lati che partono da lui
    /// (orizzontale verso destra, verticale verso il basso), l'incrocio col bordo se c'è.
    private struct Node {
        var value: Float = 0
        /// Il nodo vale solo se il bollo è quello attuale della sua riga.
        var stamp: UInt32 = 0
        var h: Int32 = -1
        var v: Int32 = -1
    }

    /// Un punto dove il bordo attraversa un lato, e il lato dove il bordo esce dalla cella dopo.
    private struct Crossing {
        var x: Double = 0
        var y: Double = 0
        var next: Int32 = -1
        var visited = false
    }

    /// Solo le righe di nodi di una fila di celle grosse, usate a giro: la griglia intera
    /// non serve mai tutta insieme.
    private var nodes: [Node] = []
    private var rowStamps: [UInt32] = []
    private var stampCounter: UInt32 = 0
    private var crossings: [Crossing] = []
    private var superActive: [Bool] = []
    private var ring: [ContourPoint] = []
    private var keep: [Bool] = []
    private var stack: [Int] = []

    /// Restituisce le linee chiuse del bordo dentro il rettangolo dato.
    /// Con questo verso l'interno della forma resta sempre dallo stesso lato.
    public func trace<F: ScalarField>(_ field: F, minX: Double, minY: Double, maxX: Double, maxY: Double) -> [[ContourPoint]] {
        let cell = self.cell
        let nx = max(1, Int(((maxX - minX) / cell).rounded(.up)))
        let ny = max(1, Int(((maxY - minY) / cell).rounded(.up)))
        let stride = nx + 1
        let cnx = (nx + coarse - 1) / coarse
        let cny = (ny + coarse - 1) / coarse
        let coarseSize = Double(coarse) * cell
        // Un campo che dichiara di quanto si scosta da una distanza vera usa il doppio di quello scarto,
        // più un filo per gli arrotondamenti: se il campo resta entro `d` da uno 1-Lipschitz, un centro
        // con |valore| > mezza diagonale + 2d non ha bordi nella sua cella. Senza respiro il margine quasi
        // sparisce; con il respiro forte della dettatura (fino a 1,5 punti) si allarga oltre il margine
        // fisso, che lì non bastava (anche nel tracciatore di prima). Senza dichiarazione resta il margine scelto.
        var slack = self.slack
        var proven = false
        if let distortion = field.distortion {
            slack = 2 * distortion + 0.05
            proven = true
        }
        let reach = coarseSize * 0.7072 + slack
        // Dentro una cella grossa si scende a quarti, saltando quelli lontani: fino a quadratini
        // di 2 × 2 celle quando il margine è stretto, altrimenti un livello solo.
        let leaf = proven && coarse >= 4 ? 2 : max(1, coarse / 2)
        // Sopra, gruppi di 4 × 4 celle grosse: l'interno e il fuori lontani si saltano con un conto solo.
        // Senza garanzia il margine qui è più largo, perché su distanze grandi il respiro pesa di più.
        let group = 4
        let groupReach = Double(group) * coarseSize * 0.7072 * (proven ? 1.0002 : 1.25) + slack
        let rows = coarse + 1

        // I quaderni passano in variabili locali: niente accessi alla classe nei giri stretti.
        var nodes = Self.take(&self.nodes)
        var rowStamps = Self.take(&self.rowStamps)
        var crossings = Self.take(&self.crossings)
        var superActive = Self.take(&self.superActive)
        defer {
            self.nodes = nodes
            self.rowStamps = rowStamps
            self.crossings = crossings
            self.superActive = superActive
        }
        if nodes.count < rows * stride { nodes = [Node](repeating: Node(), count: rows * stride) }
        if rowStamps.count < rows { rowStamps = [UInt32](repeating: 0, count: rows) }
        crossings.removeAll(keepingCapacity: true)
        let groupsX = (cnx + group - 1) / group
        if superActive.count < groupsX { superActive = [Bool](repeating: false, count: groupsX) }

        /// Un bollo nuovo per una riga che cambia proprietario: i suoi nodi vecchi non valgono più.
        func freshStamp() -> UInt32 {
            if stampCounter == .max {
                // Dopo quattro miliardi di righe si ricomincia da capo, azzerando tutto una volta.
                for k in nodes.indices { nodes[k].stamp = 0 }
                for k in rowStamps.indices { rowStamps[k] = 0 }
                stampCounter = 0
            }
            stampCounter += 1
            return stampCounter
        }

        for cj in 0..<cny {
            let j0 = cj * coarse
            let j1 = min(ny, j0 + coarse)
            // Le righe nuove di questa fila. La prima è in comune con la fila sopra e resta.
            for j in (cj == 0 ? j0 : j0 + 1)...j1 {
                rowStamps[j % rows] = freshStamp()
            }
            if cj % group == 0 {
                let gj0 = j0
                let gj1 = min(ny, gj0 + group * coarse)
                let gy = minY + (Double(gj0) + Double(gj1)) * 0.5 * cell
                for g in 0..<groupsX {
                    let gi0 = g * group * coarse
                    let gi1 = min(nx, gi0 + group * coarse)
                    let gx = minX + (Double(gi0) + Double(gi1)) * 0.5 * cell
                    superActive[g] = abs(field.value(x: gx, y: gy)) <= groupReach
                }
            }

            /// Nodi e celle di un quadratino (i bordi sono in comune con i vicini).
            func march(_ i0: Int, _ j0: Int, _ i1: Int, _ j1: Int) {
                for j in j0...j1 {
                    let y = minY + Double(j) * cell
                    let base = (j % rows) * stride
                    let stamp = rowStamps[j % rows]
                    for i in i0...i1 where nodes[base + i].stamp != stamp {
                        nodes[base + i] = Node(value: Float(field.value(x: minX + Double(i) * cell, y: y)),
                                               stamp: stamp, h: -1, v: -1)
                    }
                }

                for j in j0..<j1 {
                    let top = (j % rows) * stride
                    let bottom = ((j + 1) % rows) * stride
                    let y0 = minY + Double(j) * cell
                    for i in i0..<i1 {
                        let a = nodes[top + i].value          // alto sinistra
                        let b = nodes[top + i + 1].value      // alto destra
                        let c = nodes[bottom + i + 1].value   // basso destra
                        let d = nodes[bottom + i].value       // basso sinistra
                        let ina = a < 0, inb = b < 0, inc = c < 0, ind = d < 0
                        if ina == inb, inb == inc, inc == ind { continue }
                        let x0 = minX + Double(i) * cell

                        /// L'incrocio di un lato: lo crea al primo uso, poi lo ritrova dal nodo.
                        func crossing(_ side: Int) -> Int {
                            let index: Int
                            let vertical: Bool
                            switch side {
                            case 0: index = top + i; vertical = false
                            case 1: index = top + i + 1; vertical = true
                            case 2: index = bottom + i; vertical = false
                            default: index = top + i; vertical = true
                            }
                            let existing = vertical ? nodes[index].v : nodes[index].h
                            if existing >= 0 { return Int(existing) }
                            let made = crossings.count
                            crossings.append(Crossing())
                            if vertical { nodes[index].v = Int32(made) } else { nodes[index].h = Int32(made) }
                            return made
                        }
                        // I quattro lati in senso orario: 0 alto, 1 destra, 2 basso, 3 sinistra.
                        // Un segmento va dal lato dove il bordo "esce" (da dentro a fuori)
                        // a quello dove "entra"; del lato d'uscita serve anche il punto.
                        func link(_ out: Int, _ into: Int) {
                            let t: Double
                            let px: Double, py: Double
                            switch out {
                            case 0: // alto: da (i,j) a (i+1,j)
                                t = Double(a / (a - b))
                                px = x0 + t * cell; py = y0
                            case 1: // destra: da (i+1,j) a (i+1,j+1)
                                t = Double(b / (b - c))
                                px = x0 + cell; py = y0 + t * cell
                            case 2: // basso: da (i+1,j+1) a (i,j+1)
                                t = Double(c / (c - d))
                                px = x0 + cell - t * cell; py = y0 + cell
                            default: // sinistra: da (i,j+1) a (i,j)
                                t = Double(d / (d - a))
                                px = x0; py = y0 + cell - t * cell
                            }
                            let from = crossing(out)
                            let to = crossing(into)
                            crossings[from].x = px
                            crossings[from].y = py
                            crossings[from].next = Int32(to)
                        }

                        if ina == inc, inb == ind {
                            // Sella: decide il centro della cella.
                            // Centro dentro: ogni uscita va all'entrata successiva in senso orario.
                            // Centro fuori: va all'entrata precedente.
                            let centerInside = (a + b + c + d) < 0
                            if ina {
                                if centerInside { link(0, 1); link(2, 3) } else { link(0, 3); link(2, 1) }
                            } else {
                                if centerInside { link(1, 2); link(3, 0) } else { link(1, 0); link(3, 2) }
                            }
                        } else {
                            var out = 0, into = 0
                            if ina != inb { if ina { out = 0 } else { into = 0 } }
                            if inb != inc { if inb { out = 1 } else { into = 1 } }
                            if inc != ind { if inc { out = 2 } else { into = 2 } }
                            if ind != ina { if ind { out = 3 } else { into = 3 } }
                            link(out, into)
                        }
                    }
                }
            }

            /// Scende a quarti finché i quadratini sono piccoli, saltando quelli dove il bordo
            /// di sicuro non passa (stessa regola delle celle grosse, con la loro mezza diagonale).
            func visit(_ i0: Int, _ j0: Int, _ i1: Int, _ j1: Int, size: Int) {
                if size <= leaf {
                    march(i0, j0, i1, j1)
                    return
                }
                let half = size / 2
                let halfReach = Double(half) * cell * 0.7072 + slack
                var sj0 = j0
                while sj0 < j1 {
                    let sj1 = min(j1, sj0 + half)
                    var si0 = i0
                    while si0 < i1 {
                        let si1 = min(i1, si0 + half)
                        let sx = minX + (Double(si0) + Double(si1)) * 0.5 * cell
                        let sy = minY + (Double(sj0) + Double(sj1)) * 0.5 * cell
                        if abs(field.value(x: sx, y: sy)) <= halfReach {
                            visit(si0, sj0, si1, sj1, size: half)
                        }
                        si0 = si1
                    }
                    sj0 = sj1
                }
            }

            for ci in 0..<cnx where superActive[ci / group] {
                let i0 = ci * coarse
                let i1 = min(nx, i0 + coarse)
                let cx = minX + (Double(i0) + Double(i1)) * 0.5 * cell
                let cy = minY + (Double(j0) + Double(j1)) * 0.5 * cell
                if abs(field.value(x: cx, y: cy)) > reach { continue }
                visit(i0, j0, i1, j1, size: coarse)
            }
        }

        // Cuce i segmenti in linee chiuse.
        var found: [(count: Int, loop: [ContourPoint])] = []
        var raw = Self.take(&ring)
        defer { ring = raw }
        for start in crossings.indices where !crossings[start].visited && crossings[start].next >= 0 {
            raw.removeAll(keepingCapacity: true)
            var key = start
            var closed = false
            while !crossings[key].visited, crossings[key].next >= 0 {
                crossings[key].visited = true
                raw.append(ContourPoint(x: crossings[key].x, y: crossings[key].y))
                key = Int(crossings[key].next)
                if key == start {
                    closed = true
                    break
                }
            }
            // I granelli più piccoli di mezzo punto quadrato sono resti di un collo più sottile
            // di un pixel: non si disegnano.
            if closed, raw.count >= 3, abs(Self.signedArea(raw)) >= 0.5 {
                found.append((raw.count, simplified(raw)))
            }
        }
        // Ordine stabile: la linea più grande per prima (contata prima di semplificarla).
        found.sort { $0.count > $1.count }
        return found.map(\.loop)
    }

    /// La stessa linea chiusa con meno punti: parte dal punto più a sinistra (così l'inizio
    /// non salta da un fotogramma all'altro) e toglie i punti che distano meno di `tolerance`
    /// dalla corda fra i vicini rimasti (Douglas-Peucker). Il verso non cambia.
    private func simplified(_ loop: [ContourPoint]) -> [ContourPoint] {
        let n = loop.count
        var first = 0
        for k in 1..<n where loop[k].x < loop[first].x || (loop[k].x == loop[first].x && loop[k].y < loop[first].y) {
            first = k
        }
        guard tolerance > 0 else {
            return first == 0 ? loop : Array(loop[first...] + loop[..<first])
        }

        // Il punto più lontano dall'inizio fa da secondo ancoraggio: due metà aperte.
        var far = 0
        var farDistance = -1.0
        let p0 = loop[first]
        for k in 0..<n {
            let q = loop[(first + k) % n]
            let dd = (q.x - p0.x) * (q.x - p0.x) + (q.y - p0.y) * (q.y - p0.y)
            if dd > farDistance { farDistance = dd; far = k }
        }
        var keep = Self.take(&self.keep)
        var stack = Self.take(&self.stack)
        defer {
            self.keep = keep
            self.stack = stack
        }
        keep.removeAll(keepingCapacity: true)
        keep.append(contentsOf: repeatElement(false, count: n + 1))
        keep[0] = true
        keep[far] = true
        keep[n] = true
        stack.removeAll(keepingCapacity: true)
        stack.append(0); stack.append(far)
        stack.append(far); stack.append(n)
        let limit = tolerance * tolerance
        while let hi = stack.popLast(), let lo = stack.popLast() {
            guard hi - lo > 1 else { continue }
            let a = loop[(first + lo) % n]
            let b = loop[(first + hi) % n]
            let abx = b.x - a.x, aby = b.y - a.y
            let length = abx * abx + aby * aby
            var worst = -1.0
            var worstIndex = lo
            for k in (lo + 1)..<hi {
                let p = loop[(first + k) % n]
                var dx = p.x - a.x, dy = p.y - a.y
                if length > 0 {
                    let t = min(1, max(0, (dx * abx + dy * aby) / length))
                    dx -= t * abx
                    dy -= t * aby
                }
                let dd = dx * dx + dy * dy
                if dd > worst { worst = dd; worstIndex = k }
            }
            if worst > limit {
                keep[worstIndex] = true
                stack.append(lo); stack.append(worstIndex)
                stack.append(worstIndex); stack.append(hi)
            }
        }
        var out: [ContourPoint] = []
        out.reserveCapacity(n / 8 + 8)
        for k in 0..<n where keep[k] { out.append(loop[(first + k) % n]) }
        // Una linea sottilissima potrebbe ridursi a un segmento: allora resta intera.
        if out.count < 3 { return Array(loop[first...] + loop[..<first]) }
        return out
    }

    /// Area con segno: positiva per i bordi esterni, negativa per i buchi (o viceversa, ma coerente).
    public static func signedArea(_ loop: [ContourPoint]) -> Double {
        var twice = 0.0
        for (i, p) in loop.enumerated() {
            let q = loop[(i + 1) % loop.count]
            twice += p.x * q.y - q.x * p.y
        }
        return twice / 2
    }

    private var lastShape: IslandShape?
    private var lastSettings: (Double, Int, Double, Double)?
    private var lastLoops: [[ContourPoint]] = []

    /// Il bordo dell'isola per una forma data.
    public func trace(_ shape: IslandShape) -> [[ContourPoint]] {
        // Mentre un contenuto entra o esce a isola ferma il motore ridisegna la stessa forma:
        // il contorno è quello di prima.
        let settings = (cell, coarse, slack, tolerance)
        if let lastShape, let lastSettings, lastShape == shape, lastSettings == settings { return lastLoops }
        let b = shape.bounds()
        let loops = trace(IslandField(shape), minX: b.minX, minY: b.minY, maxX: b.maxX, maxY: b.maxY)
        lastShape = shape
        lastSettings = settings
        lastLoops = loops
        return loops
    }

    /// Prende un quaderno lasciando al suo posto uno vuoto, così resta uno solo a possederlo
    /// e le modifiche non fanno copie.
    private static func take<T>(_ array: inout [T]) -> [T] {
        let taken = array
        array = []
        return taken
    }
}
