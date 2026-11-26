import Foundation

/// Il vocabolario della dettatura: nomi e parole che vanno scritti esattamente così («ChatGPT», «Charmail»).
///
/// Il motore legge due volte la stessa analisi dell'audio: una passata sicura, quella di sempre, e una che
/// favorisce le parole del vocabolario. La seconda da sola sbaglia più della prima sulle parole normali e ogni
/// tanto mette un termine dove non c'era: per questo si tiene la prima, e dalla seconda si prendono solo i pezzi
/// che portano un termine del vocabolario e che somigliano a quello che c'era (`merge`).
/// Poi la grafia: «test flight» e «chat gpt» diventano «TestFlight» e «ChatGPT» (`canonicalize`), e una parola
/// che non esiste a un passo da un termine («Outrook») diventa il termine (`nearMisses`).
public enum Vocabulary {
    // MARK: Chiavi

    /// La chiave di una parola: minuscole, senza accenti, solo lettere e cifre. «Wi-Fi», «wifi» e «WIFI» hanno
    /// la stessa chiave.
    public static func key(_ text: String) -> String {
        String(text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .filter { $0.isLetter || $0.isNumber })
    }

    struct Term {
        var written: String
        var key: String
    }

    /// I termini con la loro chiave, senza doppioni (vince il primo: quelli di chi usa l'app stanno davanti).
    static func terms(_ list: [String]) -> [Term] {
        var seen = Set<String>()
        var out: [Term] = []
        for raw in list {
            let written = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            let key = Self.key(written)
            guard key.count >= 2, seen.insert(key).inserted else { continue }
            out.append(Term(written: written, key: key))
        }
        return out
    }

    // MARK: Parole per il motore

    /// Le parole da favorire, nel formato del motore: una per riga (qui separate da «/»), col suo punteggio.
    /// Quelle scritte da chi usa l'app pesano di più di quelle di serie. `encodable` dice se il motore sa
    /// scrivere una parola con i suoi pezzi (un termine in giapponese, per un modello europeo, no).
    public static func hotwords(user: [String], common: [String], userScore: Double = 2.0, commonScore: Double = 1.5,
                                limit: Int = 600, encodable: (String) -> Bool = { _ in true }) -> String {
        var seen = Set<String>()
        var lines: [String] = []
        func add(_ list: [String], score: Double) {
            for raw in list {
                // «/» separa le righe e «:» introduce il punteggio: dentro una parola non possono stare.
                let words = raw.replacingOccurrences(of: "/", with: " ")
                    .split(whereSeparator: { $0 == " " || $0.isNewline || $0 == "\t" })
                    .map { $0.drop { $0 == ":" || $0 == "#" || $0 == "@" } }
                    .filter { !$0.isEmpty }
                let phrase = words.joined(separator: " ")
                let key = Self.key(phrase)
                guard key.count >= 2, lines.count < limit, encodable(phrase), seen.insert(key).inserted else { continue }
                lines.append(phrase + " :" + String(format: "%.1f", score))
            }
        }
        add(user, score: userScore)
        add(common, score: commonScore)
        return lines.joined(separator: "/")
    }

    // MARK: Pezzi

    /// Una parola del testo: com'è scritta (con la punteggiatura attaccata), la sua chiave, e se resta attaccata
    /// alla successiva (l'apostrofo di «sull'App Store»).
    struct Piece: Equatable {
        var text: String
        var key: String
        var glued: Bool
    }

    static func pieces(_ text: String) -> [Piece] {
        var out: [Piece] = []
        for word in text.split(whereSeparator: { $0 == " " || $0 == "\t" || $0.isNewline }) {
            // «sull'App» sono due parole: l'apostrofo chiude la prima.
            var start = word.startIndex
            var i = word.startIndex
            while i < word.endIndex {
                let next = word.index(after: i)
                if word[i] == "'" || word[i] == "’", i > word.startIndex, next < word.endIndex,
                   word[word.index(before: i)].isLetter, word[next].isLetter || word[next].isNumber {
                    let part = String(word[start..<next])
                    out.append(Piece(text: part, key: key(part), glued: true))
                    start = next
                }
                i = next
            }
            let part = String(word[start...])
            out.append(Piece(text: part, key: key(part), glued: false))
        }
        return out
    }

    static func join(_ pieces: [Piece]) -> String {
        var out = ""
        for (i, piece) in pieces.enumerated() {
            out += piece.text
            if i < pieces.count - 1, !piece.glued { out += " " }
        }
        return out
    }

    /// Dove stanno i termini fra i pezzi: «Chat» «GPT» vale come «ChatGPT», «App» «Store» come «App Store».
    static func occurrences(in pieces: [Piece], of terms: [Term]) -> [Range<Int>] {
        let keys = Set(terms.map(\.key))
        let longest = terms.map(\.key.count).max() ?? 0
        var out: [Range<Int>] = []
        for i in pieces.indices {
            var joined = ""
            for j in i..<min(pieces.count, i + 6) {
                guard !pieces[j].key.isEmpty else { break }
                joined += pieces[j].key
                if joined.count > longest { break }
                if keys.contains(joined) { out.append(i..<(j + 1)) }
            }
        }
        return out
    }

    // MARK: Unione delle due passate

    /// Tiene `base` (la passata sicura) e prende da `boosted` (quella col vocabolario) solo i pezzi cambiati che
    /// portano un termine e che somigliano a quello che c'era: «c'è GPT» diventa «ChatGPT», ma un «YouTube»
    /// comparso al posto di «un team» no, e una parola normale scritta peggio nella seconda passata nemmeno.
    /// `isKnownWord` dice se una parola esiste nel dizionario: per sostituire parole vere il termine deve
    /// somigliare di più («link» non diventa «LinkedIn»).
    public static func merge(base: String, boosted: String, terms list: [String],
                             isKnownWord: (String) -> Bool = { _ in false }) -> String {
        let terms = Self.terms(list)
        let a = pieces(base), b = pieces(boosted)
        guard !terms.isEmpty, !a.isEmpty, !b.isEmpty else { return base }
        let hits = occurrences(in: b, of: terms)
        guard !hits.isEmpty, let raw = Diff.operations(a.map(\.key), b.map(\.key)) else { return base }
        let ops = wholeTerms(raw, hits)
        var out: [Piece] = []
        var changed = false
        for op in ops {
            guard !op.equal, let core = accepted(op, a, b, hits, isKnownWord) else {
                out.append(contentsOf: a[op.a])
                continue
            }
            // attorno al termine le parole restano quelle della passata sicura
            out.append(contentsOf: a[op.a.lowerBound..<core.a.lowerBound])
            out.append(contentsOf: b[core.b])
            out.append(contentsOf: a[core.a.upperBound..<op.a.upperBound])
            changed = true
        }
        return changed ? join(out) : base
    }

    /// Un termine scritto in due parole può cadere a cavallo fra un pezzo cambiato e uno rimasto uguale: «c'è Gpt»
    /// contro «Chat GPT» cambia solo «c'è» in «Chat», perché «gpt» c'è in tutte e due. Il cambio si allarga a
    /// tutto il termine, così si giudica (e si prende) «Chat GPT» intero al posto di «c'è Gpt».
    static func wholeTerms(_ ops: [Diff.Operation], _ hits: [Range<Int>]) -> [Diff.Operation] {
        // le parti uguali, una parola per volta, per poterle unire a un cambio vicino
        var atoms: [Diff.Operation] = []
        for op in ops {
            if op.equal {
                for k in 0..<op.a.count {
                    atoms.append(Diff.Operation(a: (op.a.lowerBound + k)..<(op.a.lowerBound + k + 1),
                                                b: (op.b.lowerBound + k)..<(op.b.lowerBound + k + 1), equal: true))
                }
            } else {
                atoms.append(op)
            }
        }
        for hit in hits.sorted(by: { $0.lowerBound < $1.lowerBound }) {
            let touching = atoms.indices.filter { atoms[$0].b.overlaps(hit) }
            guard let first = touching.first, let last = touching.last, first < last,
                  touching.contains(where: { !atoms[$0].equal }) else { continue }
            let merged = Diff.Operation(a: atoms[first].a.lowerBound..<atoms[last].a.upperBound,
                                        b: atoms[first].b.lowerBound..<atoms[last].b.upperBound, equal: false)
            atoms.replaceSubrange(first...last, with: [merged])
        }
        return atoms
    }

    /// Il cuore di un pezzo cambiato, se va preso: tolte ai lati le parole quasi uguali (che restano quelle sicure),
    /// deve restare un termine, poco altro, e una somiglianza con quello che sostituisce.
    static func accepted(_ op: Diff.Operation, _ a: [Piece], _ b: [Piece], _ hits: [Range<Int>],
                         _ isKnownWord: (String) -> Bool) -> (a: Range<Int>, b: Range<Int>)? {
        var ra = op.a, rb = op.b
        // niente dal nulla e niente che sparisce: un termine comparso dove non c'era niente è inventato
        guard !ra.isEmpty, !rb.isEmpty else { return nil }
        func inTerm(_ j: Int) -> Bool { hits.contains { $0.contains(j) } }
        while ra.count > 1, rb.count > 1, !inTerm(rb.lowerBound),
              similarity(a[ra.lowerBound].key, b[rb.lowerBound].key) >= 0.75 {
            ra = (ra.lowerBound + 1)..<ra.upperBound
            rb = (rb.lowerBound + 1)..<rb.upperBound
        }
        while ra.count > 1, rb.count > 1, !inTerm(rb.upperBound - 1),
              similarity(a[ra.upperBound - 1].key, b[rb.upperBound - 1].key) >= 0.75 {
            ra = ra.lowerBound..<(ra.upperBound - 1)
            rb = rb.lowerBound..<(rb.upperBound - 1)
        }
        let covered = rb.filter(inTerm).count
        guard covered > 0, rb.count - covered <= 2, ra.count <= rb.count + 3 else { return nil }
        let before = a[ra].map(\.key).joined(), after = b[rb].map(\.key).joined()
        // un termine molto più lungo di quello che sostituisce è una parola vera allungata («link», «LinkedIn»)
        guard !before.isEmpty, Double(after.count) <= Double(before.count) * 1.6 else { return nil }
        // parole che esistono tutte nel dizionario si cambiano solo se il termine somiglia davvero
        let real = a[ra].allSatisfy { isKnownWord($0.text.trimmingCharacters(in: CharacterSet.letters.inverted)) }
        guard similarity(before, after) >= (real ? 0.6 : 0.45) else { return nil }
        return (ra, rb)
    }

    // MARK: Grafia

    struct Word {
        var range: Range<String.Index>
        var key: String
    }

    /// Le parole del testo come gruppi di lettere e cifre, con la loro posizione.
    static func words(_ text: String) -> [Word] {
        var out: [Word] = []
        var start: String.Index?
        var i = text.startIndex
        while i < text.endIndex {
            let c = text[i]
            if c.isLetter || c.isNumber {
                if start == nil { start = i }
            } else if let s = start {
                out.append(Word(range: s..<i, key: key(String(text[s..<i]))))
                start = nil
            }
            i = text.index(after: i)
        }
        if let s = start { out.append(Word(range: s..<text.endIndex, key: key(String(text[s...])))) }
        return out
    }

    /// Fra due parole c'è solo uno spazio, un trattino, un punto o un apostrofo: possono essere la stessa parola
    /// scritta staccata («test flight», «Wi-Fi», «Next.js»).
    static func lightGap(_ text: String, _ a: Word, _ b: Word) -> Bool {
        let gap = text[a.range.upperBound..<b.range.lowerBound]
        guard gap.count == 1, let c = gap.first else { return false }
        return c == " " || c == "-" || c == "." || c == "'" || c == "’"
    }

    /// Lettere sole che sono parole vere: «i cloud provider» non è «iCloud provider».
    static let loneWords: Set<String> = ["a", "e", "i", "o", "y"]

    /// Scrive i termini con la loro grafia: «chat gpt», «Chat GPT» e «chatgpt» diventano «ChatGPT», «test flight»
    /// diventa «TestFlight». Vale solo quando le lettere sono proprio quelle: non indovina.
    public static func canonicalize(_ text: String, terms list: [String]) -> String {
        let terms = Self.terms(list)
        guard !terms.isEmpty else { return text }
        var byKey: [String: String] = [:]
        for term in terms { byKey[term.key] = term.written }
        let longest = terms.map(\.key.count).max() ?? 0
        let words = Self.words(text)
        var result = ""
        var cursor = text.startIndex
        var i = 0
        while i < words.count {
            var found: (count: Int, written: String)?
            var joined = ""
            var k = 0
            while i + k < words.count, k < 6 {
                if k > 0, !lightGap(text, words[i + k - 1], words[i + k]) { break }
                joined += words[i + k].key
                k += 1
                if joined.count > longest { break }
                guard let written = byKey[joined] else { continue }
                if k > 1 {
                    // parole staccate: il termine deve avere almeno quattro lettere, e nessun pezzo può essere
                    // una parola di una lettera sola
                    guard joined.count >= 4, !words[i..<(i + k)].contains(where: { loneWords.contains($0.key) }) else { continue }
                }
                found = (k, written)
            }
            if let found {
                let range = words[i].range.lowerBound..<words[i + found.count - 1].range.upperBound
                result += text[cursor..<range.lowerBound]
                result += found.written
                cursor = range.upperBound
                i += found.count
            } else {
                i += 1
            }
        }
        result += text[cursor...]
        return result
    }

    /// Una parola che non esiste, a un passo da un termine, è quel termine scritto male: «OpenAy» è «OpenAI»,
    /// «C at GPT» è «ChatGPT». Prudente apposta: stessa iniziale, una lettera di differenza (due se la parola è
    /// lunga), e dentro ci dev'essere almeno una parola che il dizionario non conosce; le parole vere restano.
    public static func nearMisses(_ text: String, terms list: [String], isKnownWord: (String) -> Bool) -> String {
        let all = Self.terms(list)
        let terms = all.filter { $0.key.count >= 5 }
        guard !terms.isEmpty else { return text }
        let exact = Set(all.map(\.key))
        let words = Self.words(text)
        var result = ""
        var cursor = text.startIndex
        var i = 0
        while i < words.count {
            var best: (count: Int, written: String, distance: Int)?
            var joined = ""
            var k = 0
            while i + k < words.count, k < 3 {
                if k > 0, !lightGap(text, words[i + k - 1], words[i + k]) { break }
                // una parola che è già un termine non si tocca e non si allarga («Vercel e» non è «Vercel»)
                if exact.contains(words[i + k].key) { break }
                joined += words[i + k].key
                k += 1
                guard joined.count >= 5, !exact.contains(joined) else { continue }
                let span = words[i..<(i + k)].map { String(text[$0.range]) }
                // dentro ci vuole una parola sconosciuta, e nessuna parola vera di una certa lunghezza
                guard span.contains(where: { !isKnownWord($0) }) else { continue }
                if k > 1, span.contains(where: { $0.count >= 4 && isKnownWord($0) }) { continue }
                for term in terms where term.key.first == joined.first {
                    let longer = max(term.key.count, joined.count)
                    let allowed = longer >= 9 ? 2 : 1
                    guard abs(term.key.count - joined.count) <= allowed else { continue }
                    let d = distance(joined, term.key, limit: allowed)
                    guard d <= allowed else { continue }
                    if best == nil || d < best!.distance { best = (k, term.written, d) }
                }
            }
            if let best {
                let range = words[i].range.lowerBound..<words[i + best.count - 1].range.upperBound
                result += text[cursor..<range.lowerBound]
                result += best.written
                cursor = range.upperBound
                i += best.count
            } else {
                i += 1
            }
        }
        result += text[cursor...]
        return result
    }

    /// I termini che compaiono nel testo, con la loro grafia: sono quelli da dire al modello che pulisce.
    public static func present(in text: String, terms list: [String]) -> [String] {
        let terms = Self.terms(list)
        guard !terms.isEmpty else { return [] }
        let keys = Self.words(text).map(\.key)
        var found: [String] = []
        for term in terms {
            var hit = false
            for i in keys.indices where !hit {
                var joined = ""
                for j in i..<min(keys.count, i + 6) {
                    joined += keys[j]
                    if joined == term.key { hit = true; break }
                    if joined.count >= term.key.count { break }
                }
            }
            if hit { found.append(term.written) }
        }
        return found
    }

    // MARK: Somiglianza

    /// Quanto si somigliano due chiavi, fra 0 e 1 (1 = uguali).
    static func similarity(_ a: String, _ b: String) -> Double {
        let longer = max(a.count, b.count)
        guard longer > 0 else { return 1 }
        return 1 - Double(distance(a, b, limit: longer)) / Double(longer)
    }

    /// Lettere da cambiare, aggiungere o togliere per passare da una chiave all'altra. Oltre `limit` non conta
    /// più: restituisce `limit + 1`.
    static func distance(_ a: String, _ b: String, limit: Int) -> Int {
        let x = Array(a), y = Array(b)
        if abs(x.count - y.count) > limit { return limit + 1 }
        if x.isEmpty { return y.count }
        if y.isEmpty { return x.count }
        var previous = Array(0...y.count)
        for i in 1...x.count {
            var current = [i] + Array(repeating: 0, count: y.count)
            var rowMin = current[0]
            for j in 1...y.count {
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + (x[i - 1] == y[j - 1] ? 0 : 1))
                rowMin = min(rowMin, current[j])
            }
            if rowMin > limit { return limit + 1 }
            previous = current
        }
        return previous[y.count]
    }
}

/// Il confronto fra due file di parole: quali restano uguali e quali cambiano.
enum Diff {
    struct Operation: Equatable {
        var a: Range<Int>
        var b: Range<Int>
        var equal: Bool
    }

    /// Le operazioni per passare da `a` a `b`, in ordine. `nil` se i testi sono troppo lunghi e troppo diversi
    /// per confrontarli (non succede con una dettatura: le due passate dicono quasi le stesse parole).
    static func operations(_ a: [String], _ b: [String], limit: Int = 4_000_000) -> [Operation]? {
        // inizio e fine uguali si saltano: resta da confrontare solo il mezzo
        var head = 0
        while head < a.count, head < b.count, a[head] == b[head] { head += 1 }
        var tail = 0
        while tail < a.count - head, tail < b.count - head, a[a.count - 1 - tail] == b[b.count - 1 - tail] { tail += 1 }
        let n = a.count - head - tail, m = b.count - head - tail
        guard n * m <= limit else { return nil }

        // la sottosequenza comune più lunga del mezzo
        var table = [Int32](repeating: 0, count: (n + 1) * (m + 1))
        if n > 0, m > 0 {
            for i in stride(from: n - 1, through: 0, by: -1) {
                for j in stride(from: m - 1, through: 0, by: -1) {
                    table[i * (m + 1) + j] = a[head + i] == b[head + j]
                        ? table[(i + 1) * (m + 1) + j + 1] + 1
                        : max(table[(i + 1) * (m + 1) + j], table[i * (m + 1) + j + 1])
                }
            }
        }
        var pairs: [(Int, Int)] = (0..<head).map { ($0, $0) }
        var i = 0, j = 0
        while i < n, j < m {
            if a[head + i] == b[head + j] {
                pairs.append((head + i, head + j))
                i += 1
                j += 1
            } else if table[(i + 1) * (m + 1) + j] >= table[i * (m + 1) + j + 1] {
                i += 1
            } else {
                j += 1
            }
        }
        pairs.append(contentsOf: (0..<tail).map { (a.count - tail + $0, b.count - tail + $0) })

        var ops: [Operation] = []
        var ia = 0, ib = 0
        func push(_ op: Operation) {
            if op.equal, let last = ops.last, last.equal, last.a.upperBound == op.a.lowerBound, last.b.upperBound == op.b.lowerBound {
                ops[ops.count - 1] = Operation(a: last.a.lowerBound..<op.a.upperBound, b: last.b.lowerBound..<op.b.upperBound, equal: true)
            } else {
                ops.append(op)
            }
        }
        for (pa, pb) in pairs {
            if pa > ia || pb > ib { push(Operation(a: ia..<pa, b: ib..<pb, equal: false)) }
            push(Operation(a: pa..<(pa + 1), b: pb..<(pb + 1), equal: true))
            ia = pa + 1
            ib = pb + 1
        }
        if ia < a.count || ib < b.count { push(Operation(a: ia..<a.count, b: ib..<b.count, equal: false)) }
        return ops
    }
}
