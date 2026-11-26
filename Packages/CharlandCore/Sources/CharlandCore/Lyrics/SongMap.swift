import Foundation

/// La mappa di una strofa, per il tema «Mappa» del blocco schermo: una costellazione di parole.
///
/// Ogni parola diversa della strofa è una stella, con la sua scritta sotto; due parole cantate di seguito sono unite
/// da una linea dritta. Una parola ripresa più avanti non si ripete: si torna sulla sua stella, che cresce, e una
/// linea già percorsa non si raddoppia: si rinforza. Una parola ripetuta di fila invece ha una stella per ogni
/// volta (carpa, 18 novembre 2026: «mi piace quando riprende una parola già detta, ma non quando si ripete: in "ho
/// fatto la cacca cacca" le due cacche devono essere due stelle diverse, in "ho fatto la cacca fatto" può tornare
/// sul fatto»; «se c'è boom tre volte voglio tre boom diversi»). Se la fila torna, ripassa dalle stesse stelle.
///
/// Le stelle stanno ferme dove nascono (carpa, 18 novembre 2026: «non devono muoversi in giro a caso le parole una
/// volta scritte», «controlla che non escano dallo schermo», «lasciale sempre linee dritte però voglio che le rendi
/// tipo costellazione»): ognuna viene messa a un passo dalla parola cantata prima, in una direzione che cambia, senza
/// coprire le altre e senza uscire dal rettangolo che le viene dato. Se la strofa è troppo grande per starci, si
/// rimpicciolisce tutta insieme (`fit`). Una mappa vale per una strofa sola: finita la strofa la costellazione
/// sparisce e quella dopo ricomincia da capo.
public struct SongMap: Sendable, Equatable {
    public struct Node: Sendable, Equatable {
        /// La parola come si scrive sulla mappa.
        public var text: String
        /// Quando viene cantata, in ordine.
        public var hits: [Double]
        /// Una parola di servizio (un articolo, una congiunzione): torna spesso ma non cresce.
        public var plain: Bool
        /// La stella della parola dentro il rettangolo della strofa (origine in alto a sinistra, nelle sue misure).
        /// La scritta sta sotto, centrata, a `labelTop` dalla stella: crescendo si allunga verso il basso.
        public var x: Double
        public var y: Double
        /// Quanto è larga l'etichetta a corpo base.
        public var width: Double
        /// La frase in cui compare la prima volta.
        public var line: Int
        /// Quanto conta nella canzone, da 0 (una parola qualunque) a 3 (il cuore del ritornello, il titolo): le
        /// parole che contano nascono già più grandi, e più grande è la loro stella.
        public var level: Int = 0

        /// Quante volte è stata cantata fino a `time`, e l'ultima.
        public func sung(at time: Double) -> (count: Int, last: Double)? {
            var count = 0
            for hit in hits { if hit <= time { count += 1 } else { break } }
            return count > 0 ? (count, hits[count - 1]) : nil
        }
    }

    public struct Road: Sendable, Equatable {
        /// Le due parole che unisce (indici in `nodes`), la prima è quella col numero più basso.
        public var a: Int
        public var b: Int
        /// Quando la voce ci è passata, in ordine: il momento in cui arriva alla seconda parola.
        public var passes: [Double]
        /// Le due parole stanno nella stessa frase: se no la strada è un salto fra una frase e l'altra, più tenue.
        public var inLine: Bool
        /// Da che parte gira quando è un salto lungo: 1 o −1, sempre lo stesso per la stessa strada.
        public var bend: Double

        public func passed(at time: Double) -> (count: Int, last: Double)? {
            var count = 0
            for pass in passes { if pass <= time { count += 1 } else { break } }
            return count > 0 ? (count, passes[count - 1]) : nil
        }
    }

    /// Una parola cantata: quando, quale punto, e per che strada ci si arriva dalla parola prima.
    public struct Step: Sendable, Equatable {
        public var time: Double
        public var node: Int
        public var road: Int?
    }

    public var nodes: [Node]
    public var roads: [Road]
    public var steps: [Step]
    /// Quando comincia la prima parola e quando finisce l'ultima.
    public var start: Double
    public var end: Double
    /// Di quanto la strofa è stata rimpicciolita per stare nel suo rettangolo (1 se ci stava): vale per i posti, già
    /// rimpiccioliti, e per il corpo delle parole, che chi disegna deve moltiplicare per questo numero.
    public var fit: Double

    public var isEmpty: Bool { nodes.isEmpty }

    /// Quante volte è percorsa la strada più battuta.
    public var busiest: Int

    /// Il corpo base di un'etichetta e quanto cresce a ogni grado (tre gradi al massimo).
    public static let baseSize = 34.0, growth = 15.0, maxGrowth = 3

    /// Quanti gradi sopra il corpo base sta una parola cantata `count` volte in questa strofa: quelli che le spettano
    /// per quanto conta nella canzone (carpa, 18 novembre 2026: «le parole importanti o che vengono evidenziate nella
    /// canzone appaiano più grandi e anche la stella di conseguenza»), più uno quando torna dentro la stessa strofa.
    /// Le parole di servizio restano piccole.
    public func rank(of node: Node, count: Int) -> Int {
        node.plain ? 0 : min(Self.maxGrowth, node.level + (count > 1 ? 1 : 0))
    }

    /// Il corpo di una parola cantata `count` volte in questa strofa.
    public func size(of node: Node, count: Int) -> Double {
        Self.baseSize + Self.growth * Double(rank(of: node, count: count))
    }

    // MARK: Le parole che contano

    /// Quanto conta ogni parola nella canzone, da 1 a 3 (chi non c'è vale 0), per chiave (`key`). Contano: quante
    /// volte torna rispetto alla parola che torna di più (il ritornello), se sta nel titolo, se chiude i versi (la
    /// rima, la nota tenuta), se sta da sola o quasi nel suo verso, se nel testo è gridata (maiuscole, punto
    /// esclamativo). Le parole di servizio non contano mai. Poche arrivano in cima: se no niente spicca.
    public static func levels(lines: [TimedLine], title: String = "", wordTimingIsReal: Bool = false) -> [String: Int] {
        struct Tally { var count = 0, ends = 0, alone = 0, loud = 0 }
        var tally: [String: Tally] = [:]
        for line in lines {
            let keys = line.words.map { key($0.text) }
            let told = keys.filter { !$0.isEmpty }.count
            let last = keys.lastIndex { !$0.isEmpty }
            // un verso tutto in maiuscolo non grida: è scritto così
            let shouted = !line.words.allSatisfy { $0.text == $0.text.uppercased() }
            for (w, word) in line.words.enumerated() where !keys[w].isEmpty && !isPlain(keys[w]) {
                var t = tally[keys[w]] ?? Tally()
                t.count += 1
                if w == last, told > 1 { t.ends += 1 }
                if told <= 2 || (wordTimingIsReal && word.end - word.start > 1.1) { t.alone += 1 }
                if isLoud(word.text, caps: shouted) { t.loud += 1 }
                tally[keys[w]] = t
            }
        }
        let most = max(4, tally.values.map(\.count).max() ?? 1)
        var named = Set<String>()
        var bare = title
        for cut in [" (", " [", " - ", " feat", " ft."] { if let r = bare.range(of: cut, options: .caseInsensitive) { bare = String(bare[..<r.lowerBound]) } }
        for word in bare.split(whereSeparator: { $0 == " " || $0 == "-" || $0 == "/" }) { let k = key(String(word)); if !k.isEmpty, !isPlain(k) { named.insert(k) } }

        var scores: [(key: String, score: Double)] = []
        for (k, t) in tally {
            var score = 2.2 * pow(Double(t.count - 1) / Double(most - 1), 0.7)
            if named.contains(k) { score += 1.6 }
            if t.count > 1 { score += 0.5 * Double(t.ends) / Double(t.count) }
            if t.alone > 0 { score += 0.8 }
            if t.loud > 0 { score += 0.8 }
            scores.append((k, score))
        }
        scores.sort { $0.score != $1.score ? $0.score > $1.score : $0.key < $1.key }
        // in cima ci stanno in pochi: una parola ogni dodici al terzo grado, una ogni cinque dal secondo in su
        let third = max(2, scores.count / 12), second = max(5, scores.count / 5)
        var out: [String: Int] = [:]
        for (place, entry) in scores.enumerated() {
            var level = entry.score >= 2.6 ? 3 : entry.score >= 1.6 ? 2 : entry.score >= 0.8 ? 1 : 0
            if level == 3, place >= third { level = 2 }
            if level == 2, place >= second { level = 1 }
            if level > 0 { out[entry.key] = level }
        }
        return out
    }

    /// Una parola gridata nel testo: seguita da un punto esclamativo, o (se `caps`) tutta in maiuscolo.
    static func isLoud(_ word: String, caps: Bool) -> Bool {
        if word.contains("!") { return true }
        guard caps else { return false }
        let letters = word.filter(\.isLetter)
        return letters.count > 1 && letters == letters.uppercased() && letters != letters.lowercased()
    }

    /// Quanto è battuta una strada percorsa `count` volte, da 0 (una volta sola) a 1 (la più battuta della canzone).
    public func wear(count: Int) -> Double {
        min(1, Double(max(0, count - 1)) / Double(max(5, busiest) - 1))
    }

    /// L'ultima parola cantata fino a `time` (−1 prima di tutto).
    public func step(at time: Double) -> Int {
        var lo = 0, hi = steps.count
        while lo < hi { let mid = (lo + hi) / 2; if steps[mid].time <= time { lo = mid + 1 } else { hi = mid } }
        return lo - 1
    }

    // MARK: Costruzione

    /// - Parameters:
    ///   - lines: le frasi della strofa, coi tempi delle parole.
    ///   - measure: quanto è larga una scritta a corpo base (`baseSize`).
    ///   - width, height: il rettangolo in cui la strofa deve stare tutta, nelle stesse misure del corpo base.
    ///   - levels: quanto conta ogni parola nella canzone (`levels(lines:title:)`, fatto sul testo intero).
    public init(lines: [TimedLine], width: Double, height: Double, levels: [String: Int] = [:], measure: (String) -> Double) {
        var nodes: [Node] = [], roads: [Road] = [], steps: [Step] = []
        var index: [String: [Int]] = [:], roadIndex: [Int: Int] = [:]
        var previous: (node: Int, line: Int)?
        // a che punto di una fila della stessa parola siamo (0 se la parola prima era un'altra)
        var run = (key: "", place: 0)
        var end = 0.0
        for (l, line) in lines.enumerated() {
            for word in line.words {
                let key = Self.key(word.text)
                guard !key.isEmpty else { continue }
                // la prima di una fila è la stella di quella parola; la seconda di fila una stella sua, e così via.
                // Così una parola ripetuta di fila non ricade mai sulla stessa stella, e una ripresa dopo ci torna
                run = key == run.key ? (key, run.place + 1) : (key, 0)
                let known = index[key] ?? []
                let node: Int
                if run.place < known.count { node = known[run.place] } else {
                    node = nodes.count
                    index[key, default: []].append(node)
                    let text = Self.label(word.text)
                    let plain = Self.isPlain(key)
                    nodes.append(Node(text: text, hits: [], plain: plain, x: 0, y: 0, width: measure(text), line: l, level: plain ? 0 : min(Self.maxGrowth, levels[key] ?? 0)))
                }
                nodes[node].hits.append(word.start)
                var road: Int?
                if let previous, previous.node != node {
                    let a = min(previous.node, node), b = max(previous.node, node), id = a * 100_000 + b
                    if let known = roadIndex[id] { road = known } else {
                        road = roads.count
                        roadIndex[id] = roads.count
                        roads.append(Road(a: a, b: b, passes: [], inLine: previous.line == l, bend: Self.chance(a * 31 + b, 7) < 0.5 ? -1 : 1))
                    }
                    roads[road!].passes.append(word.start)
                }
                steps.append(Step(time: word.start, node: node, road: road))
                previous = (node, l)
                end = max(end, word.end)
            }
        }
        self.nodes = nodes; self.roads = roads; self.steps = steps; self.end = end
        start = steps.first?.time ?? 0
        busiest = roads.map(\.passes.count).max() ?? 1
        fit = 1
        arrange(width: width, height: height)
    }

    /// La chiave di una parola: minuscola, senza punteggiatura. «Resta,» e «resta» sono la stessa parola.
    public static func key(_ word: String) -> String {
        String(word.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
    }

    /// Come si scrive sulla mappa: senza la punteggiatura attorno, minuscola (tranne l'«I» inglese).
    public static func label(_ word: String) -> String {
        let edges = CharacterSet.punctuationCharacters.union(.symbols).union(.whitespaces)
        let bare = word.trimmingCharacters(in: edges)
        if bare == "I" || bare.hasPrefix("I'") || bare.hasPrefix("I’") { return bare }
        return bare.lowercased()
    }

    /// Le parole di servizio delle lingue più cantate: tornano di continuo e non dicono niente della canzone.
    public static func isPlain(_ key: String) -> Bool {
        key.count <= 2 || plainWords.contains(key)
    }

    static let plainWords: Set<String> = [
        // italiano
        "che", "non", "con", "per", "una", "uno", "gli", "del", "della", "dei", "delle", "nel", "nella", "sul", "sulla", "dal", "dalla", "come", "più", "piu",
        "sono", "sei", "era", "mio", "mia", "tuo", "tua", "suo", "sua", "qui", "poi", "già", "gia", "tra", "fra", "anche", "quando", "dove", "cosa", "chi",
        // inglese
        "the", "and", "you", "your", "that", "this", "with", "for", "but", "not", "are", "was", "all", "its", "im", "dont", "cant", "ill", "ive", "youre",
        "they", "them", "she", "her", "his", "him", "our", "out", "got", "get", "can", "will", "just", "what", "when", "have", "has", "had", "from", "yeah", "ooh", "oh",
        // spagnolo, francese, portoghese, tedesco
        "que", "los", "las", "una", "por", "con", "del", "como", "pero", "muy", "les", "des", "est", "pas", "pour", "dans", "sur", "avec", "mais", "qui",
        "não", "nao", "uma", "com", "para", "mas", "der", "die", "das", "und", "ist", "ich", "nicht", "ein", "eine", "mit", "auf",
    ]

    /// Un numero fra 0 e 1 che dipende solo dai due interi: la stessa canzone dà sempre la stessa mappa.
    static func chance(_ n: Int, _ salt: Int) -> Double {
        var x = UInt64(truncatingIfNeeded: n) &* 0x9E3779B97F4A7C15 &+ UInt64(truncatingIfNeeded: salt) &* 0xBF58476D1CE4E5B9
        x ^= x >> 31; x = x &* 0x94D049BB133111EB; x ^= x >> 29
        return Double(x % 100_000) / 100_000
    }

    // MARK: Disposizione

    /// Dalla stella alla cima della scritta, quanto spazio prende la stella sopra di sé, e il margine che ogni
    /// parola tiene attorno, a corpo base.
    public static let labelTop = 15.0, starRise = 11.0, margin = 13.0

    /// L'ingombro di una parola attorno alla sua stella, al corpo `size`: la stella sopra, la scritta sotto.
    public static func box(width: Double, size: Double) -> (left: Double, right: Double, up: Double, down: Double) {
        (width * size / baseSize / 2, width * size / baseSize / 2, starRise, labelTop + size)
    }

    /// Mette le stelle al loro posto, una dopo l'altra nell'ordine in cui compaiono: ognuna a un passo dalla parola
    /// cantata subito prima, in una direzione che gira un poco a ogni passo, dove non copre nessuna delle altre, non
    /// esce dal rettangolo e, se si può, senza che la sua linea passi sopra un'altra scritta. Le parole che torneranno
    /// prendono subito il posto che serve al corpo che avranno alla fine. Se la strofa non ci sta, si riprova tutta
    /// più in piccolo.
    private mutating func arrange(width: Double, height: Double) {
        let n = nodes.count
        guard n > 0, width > 10, height > 10 else { return }
        let sizes = nodes.map { size(of: $0, count: $0.hits.count) }
        // chi viene cantato subito prima della prima volta di ogni parola
        var before = [Int](repeating: -1, count: n), seen = Set<Int>()
        for (k, step) in steps.enumerated() where !seen.contains(step.node) {
            seen.insert(step.node)
            if k > 0 { before[step.node] = steps[k - 1].node }
        }
        // le linee che ogni stella avrà con quelle venute prima di lei
        var links = [[Int]](repeating: [], count: n)
        for road in roads { links[max(road.a, road.b)].append(min(road.a, road.b)) }
        for scale in [1.0, 0.9, 0.8, 0.72, 0.64, 0.57, 0.5, 0.44, 0.38] {
            // più tentativi, a passo largo e a passo normale: resta la costellazione che si legge meglio, cioè quella
            // con meno linee che si incrociano o passano sopra una scritta, e a parità la più distesa
            var best: (spots: [(x: Double, y: Double)], tangle: Double, span: Double)?
            for seed in 0..<14 {
                guard let spots = Self.walk(nodes: nodes, sizes: sizes, before: before, links: links, seed: seed, spread: seed % 2 == 0 ? 1.3 : 1,
                                            width: width / scale, height: height / scale) else { continue }
                let tangle = tangles(spots, sizes: sizes)
                let xs = spots.map(\.x), ys = spots.map(\.y)
                let span = (xs.max()! - xs.min()!) * (ys.max()! - ys.min()! + 80)
                if best == nil || tangle < best!.tangle - 1e-9 || (abs(tangle - best!.tangle) < 1e-9 && span > best!.span) { best = (spots, tangle, span) }
            }
            if let best {
                fit = scale
                for i in 0..<n { nodes[i].x = best.spots[i].x * scale; nodes[i].y = best.spots[i].y * scale }
                return
            }
        }
        // non ci sta nemmeno piccolissima (non dovrebbe succedere: le strofe sono corte): in fila, pur di non uscire
        fit = 0.3
        for i in 0..<n {
            nodes[i].x = width * (0.1 + 0.8 * Double(i % 8) / 7)
            nodes[i].y = height * (0.1 + 0.8 * Double(i / 8) / Double(max(1, (n - 1) / 8)))
        }
    }

    /// Quanto è ingarbugliata una disposizione: le coppie di linee che si incrociano, più le linee che passano sopra
    /// la scritta di un'altra parola (che pesano di più: lì non si legge).
    private func tangles(_ spots: [(x: Double, y: Double)], sizes: [Double]) -> Double {
        func side(_ p: (x: Double, y: Double), _ q: (x: Double, y: Double), _ r: (x: Double, y: Double)) -> Double { (q.x - p.x) * (r.y - p.y) - (q.y - p.y) * (r.x - p.x) }
        var total = 0.0
        for (k, one) in roads.enumerated() {
            let a = spots[one.a], b = spots[one.b]
            for other in roads[(k + 1)...] where other.a != one.a && other.a != one.b && other.b != one.a && other.b != one.b {
                let c = spots[other.a], d = spots[other.b]
                if side(c, d, a) * side(c, d, b) < 0 && side(a, b, c) * side(a, b, d) < 0 { total += 1 }
            }
            for j in nodes.indices where j != one.a && j != one.b {
                let box = Self.box(width: nodes[j].width, size: sizes[j])
                let left = spots[j].x - box.left, right = spots[j].x + box.right, top = spots[j].y + Self.labelTop * 0.6, bottom = spots[j].y + box.down
                // la linea a campioni fitti: le scritte sono larghe almeno una ventina di punti
                let far = max(1, hypot(b.x - a.x, b.y - a.y)), count = max(2, Int(far / 9))
                for s in 1..<count {
                    let t = Double(s) / Double(count), x = a.x + (b.x - a.x) * t, y = a.y + (b.y - a.y) * t
                    if x > left && x < right && y > top && y < bottom { total += 1.6; break }
                }
            }
        }
        return total
    }

    /// Un tentativo di disposizione in un rettangolo: i posti delle stelle, o niente se una parola non trova posto.
    private static func walk(nodes: [Node], sizes: [Double], before: [Int], links: [[Int]], seed: Int, spread: Double, width: Double, height: Double) -> [(x: Double, y: Double)]? {
        let n = nodes.count
        let boxes = (0..<n).map { box(width: nodes[$0].width, size: sizes[$0]) }
        func rnd(_ a: Int, _ salt: Int) -> Double { chance(a &+ seed &* 7919, salt) }
        var spots = [(x: Double, y: Double)](repeating: (0, 0), count: n)
        func inside(_ i: Int, _ x: Double, _ y: Double) -> Bool {
            x - boxes[i].left >= 0 && x + boxes[i].right <= width && y - boxes[i].up >= 0 && y + boxes[i].down <= height
        }
        func clear(_ i: Int, _ x: Double, _ y: Double, upTo placed: Int) -> Bool {
            for j in 0..<placed {
                let apartX = x - boxes[i].left - margin >= spots[j].x + boxes[j].right || spots[j].x - boxes[j].left - margin >= x + boxes[i].right
                let apartY = y - boxes[i].up - margin >= spots[j].y + boxes[j].down || spots[j].y - boxes[j].up - margin >= y + boxes[i].down
                if !apartX && !apartY { return false }
            }
            return true
        }
        /// Il tratto da `a` a `b` entra nel rettangolo? (Liang e Barsky)
        func enters(_ ax: Double, _ ay: Double, _ bx: Double, _ by: Double, left: Double, right: Double, top: Double, bottom: Double) -> Bool {
            var t0 = 0.0, t1 = 1.0
            let dx = bx - ax, dy = by - ay
            for (p, q) in [(-dx, ax - left), (dx, right - ax), (-dy, ay - top), (dy, bottom - ay)] {
                if abs(p) < 1e-9 { if q < 0 { return false } } else {
                    let r = q / p
                    if p < 0 { if r > t1 { return false }; t0 = max(t0, r) } else { if r < t0 { return false }; t1 = min(t1, r) }
                }
            }
            return t0 < t1
        }
        /// La linea da una stella a un punto passa sopra la scritta di un'altra parola?
        func crosses(from a: Int, toX x: Double, toY y: Double, upTo placed: Int) -> Bool {
            for j in 0..<placed where j != a {
                if enters(spots[a].x, spots[a].y, x, y, left: spots[j].x - boxes[j].left - 4, right: spots[j].x + boxes[j].right + 4,
                          top: spots[j].y + labelTop * 0.5, bottom: spots[j].y + boxes[j].down) { return true }
            }
            return false
        }
        /// Le linee già tracciate, come coppie di stelle.
        var lines: [(a: Int, b: Int)] = []
        /// Due tratti si tagliano?
        func cut(_ ax: Double, _ ay: Double, _ bx: Double, _ by: Double, _ line: (a: Int, b: Int)) -> Bool {
            let c = spots[line.a], d = spots[line.b]
            func side(_ px: Double, _ py: Double, _ qx: Double, _ qy: Double, _ rx: Double, _ ry: Double) -> Double { (qx - px) * (ry - py) - (qy - py) * (rx - px) }
            let d1 = side(c.x, c.y, d.x, d.y, ax, ay), d2 = side(c.x, c.y, d.x, d.y, bx, by)
            let d3 = side(ax, ay, bx, by, c.x, c.y), d4 = side(ax, ay, bx, by, d.x, d.y)
            return d1 * d2 < 0 && d3 * d4 < 0
        }
        /// Quante linee già tracciate passerebbero sopra la scritta della parola `i` messa in quel punto.
        func covered(_ i: Int, _ x: Double, _ y: Double) -> Int {
            lines.filter { enters(spots[$0.a].x, spots[$0.a].y, spots[$0.b].x, spots[$0.b].y, left: x - boxes[i].left - 4, right: x + boxes[i].right + 4,
                                  top: y - starRise * 0.6, bottom: y + boxes[i].down) }.count
        }
        var heading = (rnd(n, 3) - 0.5) * 0.9
        for i in 0..<n {
            if i == 0 {
                // la prima stella: verso sinistra, a un'altezza che cambia da una strofa all'altra
                var placed = false
                for attempt in 0..<40 where !placed {
                    let x = width * (0.1 + 0.28 * rnd(attempt, 17 + n)), y = height * (0.12 + 0.6 * rnd(attempt, 29 + n))
                    if inside(0, x, y) { spots[0] = (x, y); placed = true }
                }
                if !placed { return nil }
                continue
            }
            let from = before[i] >= 0 ? before[i] : i - 1
            let step = ((boxes[from].right + boxes[i].left) * 0.7 + 78 + 64 * rnd(i, 5)) * spread
            var best: (x: Double, y: Double, score: Double, turn: Double)?
            for reach in [1.0, 1.35, 0.8, 1.8, 2.4] {
                for k in 0..<18 {
                    // prima le svolte dolci, poi quelle strette, da una parte e dall'altra
                    let turn = (Double(k / 2) * 0.36 + 0.2 + 0.3 * rnd(i * 19 + k, 7)) * (k % 2 == 0 ? 1 : -1) * (rnd(i, 11) < 0.5 ? 1 : -1)
                    let angle = heading + turn
                    // una costellazione è larga più che alta: i passi in verticale sono più corti
                    let x = spots[from].x + cos(angle) * step * reach, y = spots[from].y + sin(angle) * step * reach * 0.72
                    guard inside(i, x, y), clear(i, x, y, upTo: i) else { continue }
                    var score = -abs(turn) * 26 + 34 * rnd(i * 23 + k, 13) - (reach - 1) * (reach - 1) * 70
                    // le sue linee non passano sopra le altre scritte, non tagliano quelle già tracciate, e nessuna
                    // di quelle le passa sopra: una costellazione si legge se le linee non si incrociano
                    for j in links[i] {
                        if crosses(from: j, toX: x, toY: y, upTo: i) { score -= j == from ? 160 : 110 }
                        for line in lines where line.a != j && line.b != j && cut(spots[j].x, spots[j].y, x, y, line) { score -= 80 }
                    }
                    score -= Double(covered(i, x, y)) * 140
                    if best == nil || score > best!.score { best = (x, y, score, turn) }
                }
                if let best, best.score > -100 { break }
            }
            guard let found = best else { return nil }
            spots[i] = (found.x, found.y)
            heading += found.turn
            for j in links[i] { lines.append((j, i)) }
        }
        // la costellazione al centro del rettangolo
        var minX = Double.infinity, maxX = -Double.infinity, minY = Double.infinity, maxY = -Double.infinity
        for i in 0..<n {
            minX = min(minX, spots[i].x - boxes[i].left); maxX = max(maxX, spots[i].x + boxes[i].right)
            minY = min(minY, spots[i].y - boxes[i].up); maxY = max(maxY, spots[i].y + boxes[i].down)
        }
        let dx = (width - (minX + maxX)) / 2, dy = (height - (minY + maxY)) / 2
        return spots.map { ($0.x + dx, $0.y + dy) }
    }
}
