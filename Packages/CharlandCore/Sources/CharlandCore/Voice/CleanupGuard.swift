import Foundation

/// Controlla l'uscita del modello che pulisce il testo dettato.
///
/// Un modello a volte risponde invece di pulire, esegue un ordine che c'era nel testo («traduci in inglese…»),
/// tiene la parte sbagliata di una correzione, perde un pezzo o cambia un numero. In quei casi l'uscita si scarta
/// e vale il testo a regole: la dettatura non deve mai dire una cosa diversa da quella detta.
///
/// Come lavora: allinea parola per parola il testo a regole e l'uscita del modello, poi giudica ogni parola tolta
/// e ogni parola aggiunta, invece di contare percentuali su tutto il testo. Così passano le pulizie vere (via le
/// esitazioni e le false partenze, «giovedì no aspetta venerdì» che diventa «venerdì», la punteggiatura rifatta,
/// un errore di battitura corretto) e si fermano le altre. Misurato il 17 novembre 2026 su uscite vere del
/// modello di Apple: 92 buone su 92 accettate (il controllo di prima ne scartava 13), 56 su 58 di quelle che
/// rompono una regola fermate (prima ne passavano 14), 85 coppie scritte a mano tutte giuste.
public enum CleanupGuard {
    public enum Verdict: Sendable, Equatable {
        case accepted
        case rejected(String)

        static func no(_ reason: String) -> Verdict { .rejected(reason) }
    }

    // MARK: Soglie
    public struct Limits: Sendable {
        /// Sotto questo numero di parole non si tollera nessuna parola di contenuto persa.
        public var shortText = 12
        /// Parole di contenuto perse ammesse: 0 se corto, altrimenti 1 + n/30.
        public var dropBase = 1, dropPer = 30
        /// Parole di contenuto aggiunte ammesse: n/25 (quindi 0 sotto le 25 parole).
        public var addPer = 25
        /// Parole di contenuto perse di fila (un pezzo di frase sparito).
        public var maxDropRun = 1
        /// Paroline (≤3 lettere) aggiunte: 2 + n/6. Tolte senza motivo: 2 + n/5.
        public var smallAddBase = 2, smallAddPer = 6
        public var smallDropBase = 2, smallDropPer = 5
        /// Quante parole prima di un «no aspetta» si possono buttare.
        public var correctionSpan = 6
        /// Finestra in cui cercare la ripetizione di una parola tolta.
        public var repeatWindow = 8
        /// Lunghezza: caratteri ≤ ×1.15 + 10, parole ≥ 35% dell'originale.
        public var maxCharRatio = 1.15, maxCharSlack = 10
        public var minWordRatio = 0.35
        public init() {}
    }

    struct Tok {
        var raw: String
        var key: String
        var number = false     // solo cifre
        var atom = false       // URL, mail, nome di file: va tenuto identico
        var special = false    // nome proprio, sigla, camelCase
        var vocab = false      // fa parte di un termine del vocabolario
        var sentenceStart = false
    }

    // MARK: Liste
    static let fillers: Set<String> = [
        // it
        "allora", "cioe", "tipo", "praticamente", "diciamo", "insomma", "ecco", "beh", "be", "boh", "mah", "vabbe",
        "ehm", "em", "eh", "ah", "oh", "mmm", "mh", "dunque", "ok", "okay",
        // en
        "um", "uh", "uhm", "er", "erm", "hmm", "like", "so", "well", "basically", "literally", "right",
        // es
        "pues", "bueno", "este",
        // fr
        "euh", "ben", "bah", "alors", "voila", "genre", "hein", "bon",
        // de
        "ahm", "also", "halt", "naja", "sozusagen", "quasi",
    ]
    static let fillerPhrases: [[String]] = [
        ["in", "pratica"], ["come", "dire"], ["nel", "senso"], ["you", "know"], ["i", "mean"], ["kind", "of"], ["sort", "of"],
        ["o", "sea"], ["es", "que"], ["du", "coup"], ["en", "fait"], ["tu", "vois"], ["tu", "sais"], ["na", "ja"],
    ]
    /// Segnali di autocorrezione: quello che viene prima si può buttare.
    static func cues(_ lang: String) -> [[String]] {
        var c: [[String]] = [
            ["no", "aspetta"], ["anzi", "no"], ["no", "scusa"], ["cioe", "no"], ["volevo", "dire"], ["mi", "correggo"],
            ["anzi"], ["scusa"], ["scusami"], ["aspetta"], ["intendevo"],
            ["no", "wait"], ["wait", "no"], ["no", "sorry"], ["i", "meant"], ["i", "mean"], ["scratch", "that"], ["or", "rather"],
            ["sorry"], ["actually"], ["wait"], ["correction"],
            ["no", "espera"], ["mejor", "dicho"], ["quiero", "decir"], ["perdon"], ["digo"],
            ["non", "attends"], ["je", "veux", "dire"], ["pardon"], ["plutot"], ["enfin"],
            ["nein", "warte"], ["ich", "meine"], ["entschuldigung"], ["beziehungsweise"], ["quatsch"], ["warte"], ["nein"],
            ["no", "no"],
        ]
        // «no» da solo è un segnale solo dove non è anche un «nessuno» (in inglese e spagnolo lo è).
        if lang != "en" && lang != "es" { c.append(["no"]) }
        if lang == "fr" || lang == "auto" { c.append(["non"]) }
        return c.sorted { $0.count > $1.count }
    }
    static let negations: Set<String> = [
        "non", "mai", "senza", "nessuno", "nessuna", "niente", "nulla", "no",
        "not", "never", "without", "none", "nothing", "cannot",
        "nunca", "sin", "nada", "ningun", "ninguna", "tampoco",
        "pas", "jamais", "sans", "rien", "aucun", "aucune",
        "nicht", "kein", "keine", "keinen", "keinem", "keiner", "nie", "niemals", "ohne", "nichts",
    ]
    /// Parole che non si possono togliere nemmeno una volta: cambiano il senso o il registro.
    /// Verbi modali, parole di dubbio, parolacce (il modello di Apple tende a toglierle da solo).
    static let neverDrop: Set<String> = [
        "posso", "puoi", "puo", "possiamo", "potete", "possono", "devo", "devi", "deve", "dobbiamo", "dovete", "devono",
        "voglio", "vuoi", "vuole", "vogliamo", "volete", "vogliono", "forse", "magari", "probabilmente", "quasi", "solo", "soltanto",
        "can", "could", "must", "should", "may", "might", "would", "will", "maybe", "perhaps", "probably", "almost", "only",
        "kann", "kannst", "konnen", "muss", "musst", "mussen", "soll", "sollst", "sollen", "darf", "vielleicht", "nur",
        "peux", "peut", "pouvons", "dois", "doit", "devons", "veux", "veut", "voulons", "seulement",
        "puedo", "puedes", "puede", "podemos", "debo", "debes", "debe", "quiero", "quieres", "quiere", "quizas",
        "cazzo", "cazzi", "cazzata", "merda", "stronzo", "stronza", "stronzi", "minchia", "vaffanculo", "fanculo", "coglione",
        "coglioni", "puttana", "fottuto", "incazzato", "incazzata", "fuck", "fucking", "fucked", "shit", "shitty", "damn",
        "bitch", "asshole", "bullshit", "crap", "mierda", "joder", "puta", "merde", "putain", "scheisse", "verdammt",
    ]
    static let openers = ["ecco", "certo", "certamente", "sure", "here is", "here's", "of course", "il testo", "testo pulito",
                          "ho corretto", "i have", "i've", "output", "cleaned", "testo:", "trascritto", "transcript", "risposta",
                          "mi dispiace", "i'm sorry", "i am sorry", "i can't", "i cannot", "non posso", "as an ai", "sono un"]

    // MARK: Spezzare in parole
    static func fold(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
    }

    static func isAtom(_ chunk: String) -> Bool {
        if chunk.contains("@") || chunk.contains("://") || chunk.lowercased().hasPrefix("www.") { return true }
        // parola.parola (nome di file, dominio), con almeno una lettera per parte: «layout.tsx», «charstudio.app/x»
        guard chunk.contains(".") || chunk.contains("/") || chunk.contains("_") else { return false }
        let parts = chunk.split(whereSeparator: { $0 == "." || $0 == "/" || $0 == "_" })
        guard parts.count >= 2 else { return false }
        return parts.allSatisfy { $0.contains(where: \.isLetter) }
    }

    static func tokens(_ text: String) -> [Tok] {
        let text = text.replacingOccurrences(of: "’", with: "'").replacingOccurrences(of: "‘", with: "'")
        var out: [Tok] = []
        var sentenceStart = true
        let trim = CharacterSet(charactersIn: ".,;:!?()[]\"'«»“”…-–—*")
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            sentenceStart = true
            for chunkSub in line.split(whereSeparator: { $0 == " " || $0 == "\t" }) {
                let chunk = String(chunkSub)
                let core = chunk.trimmingCharacters(in: trim)
                let endsSentence = chunk.last.map { ".?!…".contains($0) } ?? false
                if core.isEmpty { if endsSentence { sentenceStart = true }; continue }
                if isAtom(core) {
                    out.append(Tok(raw: core, key: core.lowercased(), atom: true, sentenceStart: sentenceStart))
                    sentenceStart = endsSentence
                    continue
                }
                // parole: lettere di fila o cifre di fila; l'apostrofo e il resto separano
                var current = ""
                var digits = false
                var first = true
                func close() {
                    guard !current.isEmpty else { return }
                    var t = Tok(raw: current, key: fold(current), number: digits, sentenceStart: sentenceStart && first)
                    if !digits {
                        let chars = Array(current)
                        let upperInside = chars.dropFirst().contains(where: \.isUppercase)
                        let upperFirst = chars.first?.isUppercase ?? false
                        if chars.count >= 2, upperInside { t.special = true }
                        else if chars.count >= 2, upperFirst, !t.sentenceStart { t.special = true }
                    }
                    out.append(t)
                    current = ""
                    first = false
                }
                for ch in core {
                    if ch.isNumber {
                        if !current.isEmpty, !digits { close() }
                        digits = true
                        current.append(ch)
                    } else if ch.isLetter {
                        if !current.isEmpty, digits { close() }
                        digits = false
                        current.append(ch)
                    } else {
                        close()
                    }
                }
                close()
                sentenceStart = endsSentence
            }
        }
        return out
    }

    /// Termini del vocabolario: una parola sola («ChatGPT») o più («GTA VI»). Le sequenze uguali diventano una parola sola.
    static func markVocab(_ toks: [Tok], _ vocab: [[String]]) -> [Tok] {
        guard !vocab.isEmpty else { return toks }
        var out: [Tok] = []
        var i = 0
        let sorted = vocab.sorted { $0.count > $1.count }
        while i < toks.count {
            var hit = false
            for term in sorted where !term.isEmpty && i + term.count <= toks.count {
                if (0..<term.count).allSatisfy({ toks[i + $0].key == term[$0] }) {
                    var t = toks[i]
                    t.raw = toks[i..<(i + term.count)].map(\.raw).joined(separator: " ")
                    t.key = term.joined()
                    t.vocab = true
                    t.special = true
                    t.number = false
                    out.append(t)
                    i += term.count
                    hit = true
                    break
                }
            }
            if !hit { out.append(toks[i]); i += 1 }
        }
        return out
    }

    /// «test flight» ↔ «testflight», «chat gpt» ↔ «chatgpt»: due parole attaccate che dall'altra parte sono una.
    static func mergePairs(_ a: [Tok], against b: [Tok]) -> [Tok] {
        let bKeys = Set(b.map(\.key))
        let aKeys = Set(a.map(\.key))
        var out: [Tok] = []
        var i = 0
        while i < a.count {
            if i + 1 < a.count, !a[i].atom, !a[i + 1].atom {
                let joined = a[i].key + a[i + 1].key
                if joined.count >= 5, bKeys.contains(joined), !aKeys.contains(joined) {
                    var t = a[i]
                    t.raw = a[i].raw + " " + a[i + 1].raw
                    t.key = joined
                    t.special = a[i].special || a[i + 1].special
                    t.vocab = a[i].vocab || a[i + 1].vocab
                    t.number = false
                    out.append(t)
                    i += 2
                    continue
                }
            }
            out.append(a[i])
            i += 1
        }
        return out
    }

    static func levenshtein(_ a: [Character], _ b: [Character], max: Int) -> Int {
        if abs(a.count - b.count) > max { return max + 1 }
        var prev = Array(0...b.count)
        for i in 1...Swift.max(1, a.count) where a.count > 0 {
            var cur = [i] + Array(repeating: 0, count: b.count)
            if !b.isEmpty {
                for j in 1...b.count {
                    cur[j] = Swift.min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
                }
            }
            prev = cur
        }
        return prev[b.count]
    }

    /// 2 = uguali, 1 = quasi uguali (errore di battitura, desinenza), 0 = diverse.
    static func similarity(_ a: Tok, _ b: Tok) -> Int {
        if a.key == b.key { return 2 }
        if a.atom || b.atom { return 0 }
        if a.number || b.number {
            // «dieci» ↔ «10»
            if a.number != b.number {
                let word = a.number ? b.key : a.key
                let digits = a.number ? a.key : b.key
                if let v = NumberWords.value(word), let d = Int(digits), v == d { return 1 }
            }
            return 0
        }
        let x = Array(a.key), y = Array(b.key)
        let shorter = min(x.count, y.count)
        guard shorter >= 4 else { return 0 }
        let allowed = shorter <= 7 ? 1 : 2
        if levenshtein(x, y, max: allowed) <= allowed { return 1 }
        var prefix = 0
        while prefix < shorter, x[prefix] == y[prefix] { prefix += 1 }
        if prefix >= max(4, Int((Double(shorter) * 0.6).rounded(.up))) { return 1 }
        return 0
    }

    /// Allineamento in ordine: per ogni parola di A l'indice della parola di B a cui corrisponde (o nil).
    static func align(_ a: [Tok], _ b: [Tok]) -> [Int?] {
        let n = a.count, m = b.count
        guard n > 0, m > 0 else { return Array(repeating: nil, count: n) }
        var score = Array(repeating: Array(repeating: 0, count: m + 1), count: n + 1)
        for i in 1...n {
            for j in 1...m {
                var best = max(score[i - 1][j], score[i][j - 1])
                let s = similarity(a[i - 1], b[j - 1])
                if s > 0 { best = max(best, score[i - 1][j - 1] + (s == 2 ? 4 : 3)) }
                score[i][j] = best
            }
        }
        var map: [Int?] = Array(repeating: nil, count: n)
        var i = n, j = m
        while i > 0, j > 0 {
            let s = similarity(a[i - 1], b[j - 1])
            if s > 0, score[i][j] == score[i - 1][j - 1] + (s == 2 ? 4 : 3) {
                map[i - 1] = j - 1
                i -= 1; j -= 1
            } else if score[i][j] == score[i - 1][j] {
                i -= 1
            } else {
                j -= 1
            }
        }
        return map
    }

    static func phraseHits(_ toks: [Tok], _ phrases: [[String]]) -> [Range<Int>] {
        var hits: [Range<Int>] = []
        var i = 0
        while i < toks.count {
            var matched = false
            for p in phrases where i + p.count <= toks.count {
                if (0..<p.count).allSatisfy({ toks[i + $0].key == p[$0] }) {
                    hits.append(i..<(i + p.count))
                    i += p.count
                    matched = true
                    break
                }
            }
            if !matched { i += 1 }
        }
        return hits
    }

    // MARK: Il controllo
    public static func check(original: String, cleaned: String, vocabulary: [String] = [], language: String = "auto",
                             limits: Limits = Limits()) -> Verdict {
        let out = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !out.isEmpty else { return .no("vuoto") }
        let lowOut = out.lowercased(), lowIn = original.lowercased().trimmingCharacters(in: .whitespaces)
        if lowOut.contains("</") || lowOut.contains("<trascritto") || lowOut.contains("<transcript") || lowOut.contains("<testo")
            || lowOut.contains("```") || lowOut.contains("**") {
            return .no("etichette nell'uscita")
        }
        let headIn = String(lowIn.prefix(80))
        for o in openers where lowOut.hasPrefix(o) && !headIn.contains(o) { return .no("risponde invece di pulire (\(o))") }
        if Double(out.count) > Double(original.count) * limits.maxCharRatio + Double(limits.maxCharSlack) { return .no("troppo lungo") }

        let vocabKeys = vocabulary.map { tokens($0).map(\.key) }.filter { !$0.isEmpty }
        var a = markVocab(tokens(original), vocabKeys)
        var b = markVocab(tokens(out), vocabKeys)
        a = mergePairs(a, against: b)
        b = mergePairs(b, against: a)
        // un termine del vocabolario scritto attaccato dopo la fusione
        let vocabJoined = Set(vocabKeys.map { $0.joined() })
        for i in b.indices where vocabJoined.contains(b[i].key) { b[i].vocab = true; b[i].special = true }
        for i in a.indices where vocabJoined.contains(a[i].key) { a[i].vocab = true }
        guard !a.isEmpty else { return .no("originale vuoto") }
        if Double(b.count) < Double(a.count) * limits.minWordRatio { return .no("troppo corto") }

        let map = align(a, b)
        var bMatched = Array(repeating: false, count: b.count)
        for case let j? in map { bMatched[j] = true }

        // -- parole di A libere di sparire: segnali di correzione (se tolti) e quello che li precede, riempitivi
        var free = Array(repeating: false, count: a.count)
        var cueTok = Array(repeating: false, count: a.count)
        for r in phraseHits(a, cues(language)) {
            // vale solo se il segnale stesso è stato tolto
            guard r.allSatisfy({ map[$0] == nil }) else { continue }
            for k in r { free[k] = true; cueTok[k] = true }
            var k = r.lowerBound - 1
            var left = limits.correctionSpan
            while k >= 0, left > 0, !cueTok[k] { free[k] = true; k -= 1; left -= 1 }
        }
        for r in phraseHits(a, fillerPhrases) where r.allSatisfy({ map[$0] == nil }) { for k in r { free[k] = true } }
        for i in a.indices where fillers.contains(a[i].key) && !a[i].special { free[i] = true }

        // -- dopo un «no aspetta» tolto, quello che segue è la versione giusta: deve esserci
        for r in phraseHits(a, cues(language)) where r.allSatisfy({ cueTok[$0] }) {
            var k = r.upperBound
            var looked = 0
            while k < a.count, looked < 3 {
                if !cueTok[k], !fillers.contains(a[k].key) {
                    looked += 1
                    if map[k] == nil, a[k].number || a[k].special || a[k].atom || a[k].key.count >= 4 {
                        return .no("tenuta la parte sbagliata della correzione: manca \(a[k].raw)")
                    }
                }
                k += 1
            }
        }

        // -- coppie nello stesso buco: «fa» → «facendo», «ha» → «hanno» (una parolina che cambia forma)
        var pairedA = Array(repeating: false, count: a.count)
        var pairedB = Array(repeating: false, count: b.count)
        do {
            // per ogni parola di B non allineata, i confini del buco in A
            var prevA = -1
            var jStart = 0
            let matchedPairs = a.indices.compactMap { i in map[i].map { (i, $0) } }
            var bounds: [(aLo: Int, aHi: Int, bLo: Int, bHi: Int)] = []
            for (i, j) in matchedPairs {
                bounds.append((prevA + 1, i, jStart, j))
                prevA = i; jStart = j + 1
            }
            bounds.append((prevA + 1, a.count, jStart, b.count))
            for g in bounds {
                for j in g.bLo..<g.bHi where !pairedB[j] && !b[j].number && !b[j].atom && !b[j].special && !b[j].vocab
                    && !negations.contains(b[j].key) {
                    for i in g.aLo..<g.aHi where !pairedA[i] && !free[i] && !a[i].number && !a[i].atom && !a[i].special
                        && !negations.contains(a[i].key) {
                        let x = a[i].key, y = b[j].key
                        if x.count >= 2, y.count >= 2, x != y, y.hasPrefix(x) || x.hasPrefix(y) {
                            pairedA[i] = true; pairedB[j] = true
                            break
                        }
                    }
                }
            }
        }

        // -- parole tolte
        var contentDrops: [String] = []
        var smallDrops = 0
        var run = 0, maxRun = 0
        for i in a.indices {
            if map[i] != nil { run = 0; continue }
            if free[i] || pairedA[i] { continue }
            // ripetizione o falsa partenza: la stessa parola c'è lì vicino ed è rimasta, oppure una quasi uguale
            // viene DOPO (chi parla si corregge in avanti: «le ultime l'ultima» → resta «l'ultima»)
            var repeated = false
            let lo = max(0, i - limits.repeatWindow), hi = min(a.count - 1, i + limits.repeatWindow)
            for j in lo...hi where j != i && map[j] != nil {
                let s = similarity(a[i], a[j])
                if s == 2 || (s == 1 && j > i) { repeated = true; break }
                if s == 1, j < i, !a[i].number {
                    return .no("tenuta la prima versione: «\(a[j].raw)» al posto di «\(a[i].raw)»")
                }
            }
            if !repeated, i + 1 < a.count, a[i].key.count >= 2, !a[i].number, a[i + 1].key.count > a[i].key.count,
               a[i + 1].key.hasPrefix(a[i].key) {
                repeated = true   // «ana analizzami»
            }
            if repeated { continue }
            if a[i].number { return .no("numero perso: \(a[i].raw)") }
            if a[i].atom { return .no("indirizzo perso: \(a[i].raw)") }
            if a[i].special { return .no("nome perso: \(a[i].raw)") }
            if negations.contains(a[i].key) { return .no("negazione persa: \(a[i].raw)") }
            if neverDrop.contains(a[i].key) { return .no("parola che cambia il senso persa: \(a[i].raw)") }
            if a[i].key.count <= 3 { smallDrops += 1; continue }
            contentDrops.append(a[i].raw)
            run += 1
            maxRun = max(maxRun, run)
        }

        // -- parole cambiate (allineate ma non identiche)
        for i in a.indices {
            guard let j = map[i], a[i].key != b[j].key else { continue }
            if b[j].vocab { continue }                       // corretta verso il vocabolario: va bene
            if a[i].special { return .no("nome cambiato: \(a[i].raw) → \(b[j].raw)") }
            if b[j].special { return .no("nome nuovo: \(a[i].raw) → \(b[j].raw)") }
            if negations.contains(a[i].key) != negations.contains(b[j].key) { return .no("negazione cambiata: \(a[i].raw) → \(b[j].raw)") }
        }

        // -- parole aggiunte
        let firstMatched = bMatched.firstIndex(of: true) ?? b.count
        let lastMatched = bMatched.lastIndex(of: true) ?? -1
        var contentAdds: [String] = []
        var smallAdds = 0
        var edgeAdds = 0
        for j in b.indices where !bMatched[j] && !pairedB[j] {
            if b[j].number { return .no("numero nuovo: \(b[j].raw)") }
            if b[j].atom { return .no("indirizzo nuovo: \(b[j].raw)") }
            if b[j].vocab { return .no("termine del vocabolario inserito: \(b[j].raw)") }
            if b[j].special { return .no("nome nuovo: \(b[j].raw)") }
            if negations.contains(b[j].key) { return .no("negazione aggiunta: \(b[j].raw)") }
            let edge = j < firstMatched || j > lastMatched
            if edge {
                edgeAdds += 1
                if b[j].key.count >= 4 { return .no("aggiunta in testa o in coda: \(b[j].raw)") }
                if edgeAdds >= 2 { return .no("aggiunta in testa o in coda") }
            }
            if b[j].key.count <= 3 { smallAdds += 1 } else { contentAdds.append(b[j].raw) }
        }

        // -- la pulizia non crea mai una parola doppia («le ultime ultime mail»)
        func doubles(_ t: [Tok]) -> Int {
            guard t.count >= 2 else { return 0 }
            return (1..<t.count).filter { t[$0].key == t[$0 - 1].key && t[$0].key.count >= 3 && !t[$0].number }.count
        }
        if doubles(b) > doubles(a) { return .no("parola doppia creata") }

        let nA = a.count, nB = b.count
        let dropAllowed = nA < limits.shortText ? 0 : limits.dropBase + nA / limits.dropPer
        let addAllowed = nB / limits.addPer
        if contentDrops.count > dropAllowed { return .no("parole perse: \(contentDrops.joined(separator: ", "))") }
        if maxRun > limits.maxDropRun { return .no("frase persa: \(contentDrops.joined(separator: ", "))") }
        if contentAdds.count > addAllowed { return .no("parole aggiunte: \(contentAdds.joined(separator: ", "))") }
        if smallAdds > limits.smallAddBase + nB / limits.smallAddPer { return .no("troppe paroline aggiunte") }
        if smallDrops > limits.smallDropBase + nA / limits.smallDropPer { return .no("troppe paroline tolte") }
        return .accepted
    }

    // MARK: Controllo mentre l'uscita arriva (streaming)

    /// Da chiamare a ogni pezzo che arriva. Dice subito se l'uscita sta andando male (risposta, traduzione,
    /// numero inventato, termine del vocabolario inserito, testo che non finisce più): in quel caso si può
    /// fermare il modello e usare il testo a regole senza aspettare la fine.
    /// Non sostituisce `check`, che va comunque fatto sull'uscita completa.
    public static func earlyCheck(original: String, partial: String, vocabulary: [String] = [], language: String = "auto",
                                  limits: Limits = Limits()) -> Verdict {
        let out = partial.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !out.isEmpty else { return .accepted }
        let lowOut = out.lowercased(), lowIn = original.lowercased().trimmingCharacters(in: .whitespaces)
        if lowOut.contains("</") || lowOut.contains("<trascritto") || lowOut.contains("<transcript") || lowOut.contains("```") {
            return .no("etichette nell'uscita")
        }
        let headIn = String(lowIn.prefix(80))
        for o in openers where lowOut.hasPrefix(o + " ") && !headIn.contains(o) { return .no("risponde invece di pulire (\(o))") }
        if Double(out.count) > Double(original.count) * limits.maxCharRatio + Double(limits.maxCharSlack) { return .no("troppo lungo") }

        let vocabKeys = vocabulary.map { tokens($0).map(\.key) }.filter { !$0.isEmpty }
        var a = markVocab(tokens(original), vocabKeys)
        var b = markVocab(tokens(out), vocabKeys)
        // l'ultima parola può essere a metà: non si giudica
        if let last = partial.last, last.isLetter || last.isNumber, !b.isEmpty { b.removeLast() }
        guard b.count >= 3 else { return .accepted }
        a = mergePairs(a, against: b)
        b = mergePairs(b, against: a)
        let vocabJoined = Set(vocabKeys.map { $0.joined() })
        for i in b.indices where vocabJoined.contains(b[i].key) { b[i].vocab = true }
        let map = align(a, b)
        var matched = Array(repeating: false, count: b.count)
        for case let j? in map { matched[j] = true }
        // numeri e termini del vocabolario che nell'originale non ci sono (l'ultimo no: può essere ancora a metà riga)
        for j in b.indices.dropLast() where !matched[j] {
            if b[j].number { return .no("numero nuovo: \(b[j].raw)") }
            if b[j].vocab { return .no("termine del vocabolario inserito: \(b[j].raw)") }
        }
        // le parole arrivate finora devono venire dall'originale
        let hits = matched.filter { $0 }.count
        let content = b.indices.filter { b[$0].key.count >= 4 }
        let contentMiss = content.filter { !matched[$0] }.count
        if b.count >= 4, Double(hits) < Double(b.count) * 0.5 { return .no("le parole non vengono dall'originale") }
        if content.count >= 3, contentMiss * 2 > content.count { return .no("le parole non vengono dall'originale") }
        return .accepted
    }

    /// Ripulisce l'uscita prima del controllo: spazi, virgolette attorno, a capo che l'originale non aveva.
    public static func tidy(_ output: String, original: String) -> String {
        var s = output.trimmingCharacters(in: .whitespacesAndNewlines)
        let quotes = CharacterSet(charactersIn: "\"“”«»")
        if let f = s.unicodeScalars.first, quotes.contains(f), let o = original.unicodeScalars.first, !quotes.contains(o) {
            s = s.trimmingCharacters(in: quotes)
        }
        if !original.contains("\n") {
            s = s.replacingOccurrences(of: "\n", with: " ")
            while s.contains("  ") { s = s.replacingOccurrences(of: "  ", with: " ") }
        }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
