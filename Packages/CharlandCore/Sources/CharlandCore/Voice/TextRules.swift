import Foundation

/// La pulizia a regole: istantanea, sempre uguale, non dipende da nessun modello.
/// Toglie le esitazioni e le parole doppie, sistema spazi e maiuscole, e traduce
/// la punteggiatura dettata. È anche la rete di sicurezza se il modello non c'è o rifiuta.
public enum TextRules {
    public struct Options: Sendable {
        public var removeFillers = true
        public var spokenPunctuation = true
        public var capitalize = true
        /// "Alla lettera" (Xcode, terminali): niente maiuscole forzate, niente punto finale.
        public var literal = false
        /// Il testo è in italiano: si rimettono gli apostrofi che il motore a volte perde («l ultima»).
        public var italian = false
        public init() {}
    }

    static let fillers: Set<String> = ["em", "ehm", "ehmm", "uhm", "uhmm", "mmm", "mh", "um", "uh", "uhh", "umm", "hmm", "erm"]

    /// Punteggiatura dettata. Dalla più lunga alla più corta, così "punto e virgola" vince su "punto".
    static let spoken: [(words: [String], symbol: String)] = [
        (["punto", "interrogativo"], "?"), (["punto", "esclamativo"], "!"), (["punto", "e", "virgola"], ";"),
        (["due", "punti"], ":"), (["a", "capo"], "\n"), (["nuova", "riga"], "\n"), (["virgola"], ","),
        (["question", "mark"], "?"), (["exclamation", "mark"], "!"), (["exclamation", "point"], "!"),
        (["new", "line"], "\n"), (["new", "paragraph"], "\n\n"), (["semicolon"], ";"), (["comma"], ","),
    ]

    /// Parole dopo le quali "punto" è una parola normale ("a che punto", "il punto").
    static let beforePunto: Set<String> = ["il", "un", "al", "del", "dal", "nel", "sul", "questo", "quel", "che", "ogni",
                                           "qualche", "certo", "primo", "secondo", "terzo", "ultimo", "buon", "stesso", "the", "a", "this", "that", "some", "certain", "good"]

    /// «A capo di» qualcosa, detto dopo una di queste parole, è la frase normale («Marco è a capo del progetto»), non
    /// il comando. Servono tutte e due le cose: dopo il comando una frase può benissimo cominciare con «Di solito».
    static let beforeCapo: Set<String> = ["è", "era", "sono", "sei", "siamo", "siete", "erano", "sarà", "sarò", "saranno", "essere",
                                          "stato", "stata", "stati", "state", "c'è", "c’è", "messo", "messa", "mettere", "resta", "rimane",
                                          "rimasto", "rimasta", "torna", "più", "ancora", "sempre", "già"]
    static let afterCapo: Set<String> = ["di", "del", "dello", "della", "dei", "degli", "delle"]
    /// «Due punti» contati («per due punti», «i due punti principali», «due punti percentuali»), non i due punti.
    static let beforeDuePunti: Set<String> = ["per", "di", "a", "i", "quei", "questi", "altri", "su", "in", "tra", "fra", "con", "dei", "ai",
                                              "sui", "nei", "dai", "primi", "ultimi", "solo", "soli", "almeno", "circa"]
    static let afterDuePunti: Set<String> = ["percentuali", "percentuale"]

    static func isNumberWord(_ word: String) -> Bool {
        !word.isEmpty && (word.allSatisfy(\.isNumber) || NumberWords.value(word) != nil)
    }

    /// La punteggiatura dettata che in questo punto è una frase normale: resta scritta com'è.
    static func isOrdinary(_ entry: [String], in words: [String], at i: Int, previous: String?) -> Bool {
        let next = i + entry.count < words.count ? bare(words[i + entry.count]) : nil
        let previous = previous.map(bare)
        switch entry {
        case ["a", "capo"]:
            guard let previous, let next, beforeCapo.contains(previous) else { return false }
            return afterCapo.contains(next) || next.hasPrefix("dell'") || next.hasPrefix("dell’")
        case ["virgola"]:
            // fra due numeri è la virgola dei decimali («tre virgola cinque»)
            guard let previous, let next else { return false }
            return isNumberWord(previous) && isNumberWord(next)
        case ["due", "punti"]:
            if let previous, beforeDuePunti.contains(previous) { return true }
            if let next, afterDuePunti.contains(next) { return true }
            return false
        default:
            return false
        }
    }

    public static func clean(_ input: String, options: Options = Options()) -> String {
        var words = input.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        guard !words.isEmpty else { return "" }

        if options.removeFillers {
            words = words.filter { !fillers.contains(bare($0)) }
        }

        // Parole doppie per esitazione ("il il gatto"). I numeri, in cifre o in lettere ("tre tre otto"), e le
        // parole lunghe ripetute apposta ("molto molto") si lasciano.
        var deduped: [String] = []
        for word in words {
            if let last = deduped.last, bare(last) == bare(word), bare(word).count <= 3, !bare(word).isEmpty,
               NumberWords.value(bare(word)) == nil || bare(word) == "un" || bare(word) == "una",
               last == bare(last) || last.lowercased() == word.lowercased() {
                continue
            }
            deduped.append(word)
        }
        words = deduped
        if options.removeFillers { words = dropRepeatedPhrases(words) }

        if options.spokenPunctuation {
            words = applySpokenPunctuation(words)
        }

        var text = words.joined(separator: " ")
        // Spazi attorno alla punteggiatura e agli a capo.
        for mark in [",", ".", ";", ":", "?", "!"] {
            text = text.replacingOccurrences(of: " " + mark, with: mark)
        }
        text = text.replacingOccurrences(of: " \n", with: "\n").replacingOccurrences(of: "\n ", with: "\n")
        while text.contains(",,") { text = text.replacingOccurrences(of: ",,", with: ",") }
        text = text.replacingOccurrences(of: ",.", with: ".").replacingOccurrences(of: ".,", with: ".")
        while text.contains("  ") { text = text.replacingOccurrences(of: "  ", with: " ") }
        text = text.trimmingCharacters(in: .whitespaces)
        while let first = text.first, ",;:".contains(first) { text.removeFirst(); text = text.trimmingCharacters(in: .whitespaces) }

        if options.italian { text = italianElisions(text) }

        if options.capitalize, !options.literal {
            text = capitalizeSentences(text)
        }
        return text
    }

    /// Una frase corta detta due volte di fila è una falsa partenza: «leggi su Charmail leggi su Charmail» resta
    /// una volta sola. Non vale per i numeri (un numero di telefono si ripete) né se in mezzo finisce una frase.
    static func dropRepeatedPhrases(_ words: [String]) -> [String] {
        var out = words
        var i = 0
        while i < out.count {
            var removed = false
            for n in stride(from: 4, through: 2, by: -1) where i + 2 * n <= out.count {
                let first = out[i..<(i + n)], second = out[(i + n)..<(i + 2 * n)]
                let keys = first.map(bare)
                guard keys == second.map(bare), keys.joined().count >= 6, !keys.contains(where: \.isEmpty),
                      !keys.allSatisfy({ NumberWords.value($0) != nil }),
                      !first.contains(where: { $0.last.map { ".?!…".contains($0) } ?? false }) else { continue }
                out.removeSubrange(i..<(i + n))
                removed = true
                break
            }
            if !removed { i += 1 }
        }
        return out
    }

    /// Parole tronche che da sole in italiano non esistono: se il motore le stacca dalla parola dopo, manca
    /// l'apostrofo («l ultima», «dell altro», «sull isola»).
    static let elided: Set<String> = ["l", "dell", "all", "nell", "sull", "dall", "quell", "coll"]
    /// Dopo «d» l'apostrofo si rimette solo davanti a queste: una «d» da sola può essere una lettera.
    static let afterD: Set<String> = ["accordo", "altra", "altro", "altronde", "ora", "un", "una", "uno", "estate", "inverno", "oro",
                                      "argento", "aria", "acqua", "arte", "oggi", "ogni", "origine", "uso", "urgenza", "esempio",
                                      "anni", "età", "italia", "europa", "amore"]
    /// Dopo «c»: «c è», «c era».
    static let afterC: Set<String> = ["è", "era", "erano", "entra", "entrano"]

    /// Rimette gli apostrofi che il motore ha perso: «l ultima» diventa «l'ultima», «c è» diventa «c'è».
    /// Vale solo per le parole in minuscolo: una «L» maiuscola può essere una lettera detta apposta.
    static func italianElisions(_ text: String) -> String {
        var words = text.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        var i = 0
        while i + 1 < words.count {
            let word = words[i], next = bare(words[i + 1])
            let vowel = next.first.map { "aeiouàèéìòùh".contains($0) } ?? false
            let join: Bool
            if elided.contains(word) { join = vowel } else if word == "d" { join = afterD.contains(next) } else if word == "c" { join = afterC.contains(next) } else { join = false }
            if join {
                words[i] = word + "'" + words[i + 1]
                words.remove(at: i + 1)
            }
            i += 1
        }
        return words.joined(separator: " ")
    }

    /// La parola senza punteggiatura attaccata, in minuscolo.
    static func bare(_ word: String) -> String {
        word.lowercased().trimmingCharacters(in: CharacterSet.punctuationCharacters.union(.symbols))
    }

    static func applySpokenPunctuation(_ words: [String]) -> [String] {
        var out: [String] = []
        var i = 0
        while i < words.count {
            var matched = false
            for entry in spoken {
                let n = entry.words.count
                guard i + n <= words.count else { continue }
                let slice = words[i..<(i + n)].map(bare)
                guard slice == entry.words else { continue }
                if isOrdinary(entry.words, in: words, at: i, previous: out.last) { continue }
                // "virgola" e simili attaccati a una parola precedente la chiudono.
                if let last = out.popLast() {
                    out.append(stripTrailingPunctuation(last) + entry.symbol)
                } else {
                    out.append(entry.symbol)
                }
                i += n
                matched = true
                break
            }
            if matched { continue }
            // "punto" da solo vale come punteggiatura solo in fondo o prima di un a capo,
            // e mai dopo un articolo ("il punto", "a che punto").
            if bare(words[i]) == "punto" || bare(words[i]) == "period" || bare(words[i]) == "full" && i + 1 < words.count && bare(words[i + 1]) == "stop" {
                let isFullStop = bare(words[i]) == "full"
                let nextIndex = i + (isFullStop ? 2 : 1)
                let atEnd = nextIndex >= words.count
                let beforeBreak = !atEnd && (bare(words[nextIndex]) == "a" && nextIndex + 1 < words.count && bare(words[nextIndex + 1]) == "capo")
                let previous = out.last.map(bare) ?? ""
                if (atEnd || beforeBreak), !previous.isEmpty, !beforePunto.contains(previous) {
                    let last = out.removeLast()
                    out.append(stripTrailingPunctuation(last) + ".")
                    i = nextIndex
                    continue
                }
            }
            out.append(words[i])
            i += 1
        }
        return out
    }

    static func stripTrailingPunctuation(_ word: String) -> String {
        var w = word
        while let last = w.last, ",.;:".contains(last) { w.removeLast() }
        return w
    }

    static func capitalizeSentences(_ text: String) -> String {
        var out = ""
        var capitalizeNext = true
        var pendingStop = false
        for ch in text {
            if capitalizeNext, ch.isLetter {
                out.append(contentsOf: String(ch).uppercased())
                capitalizeNext = false
            } else {
                out.append(ch)
                if ch.isLetter || ch.isNumber { capitalizeNext = false }
            }
            if ch == "\n" {
                capitalizeNext = true
            } else if ch == "." || ch == "?" || ch == "!" {
                pendingStop = true
            } else if pendingStop {
                // la frase è finita solo se dopo il segno c'è uno spazio: «mario.rossi@example.com», «layout.tsx»
                // e «2.4.1» non sono fine frase
                if ch.isWhitespace { capitalizeNext = true }
                pendingStop = false
            }
        }
        return out
    }
}

/// Errori per parola (WER): quante parole sbagliate, mancanti o in più rispetto al testo atteso.
public enum WordErrorRate {
    public struct Score: Sendable {
        public var errors: Int
        public var words: Int
        public var rate: Double { words == 0 ? 0 : Double(errors) / Double(words) }
    }

    /// Confronta senza maiuscole e senza punteggiatura, e con i numeri in cifre:
    /// "alle dieci" e "alle 10" sono la stessa frase, come "venti nove" e "29".
    public static func normalize(_ text: String) -> [String] {
        let words = text.lowercased()
            .replacingOccurrences(of: "’", with: "'")
            .components(separatedBy: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "'")).inverted)
            .filter { !$0.isEmpty }
        var out: [String] = []
        for word in words {
            guard let value = NumberWords.value(word) else {
                out.append(word)
                continue
            }
            // "venti" seguito da "nove" è 29.
            if let last = out.last, let previous = Int(last), previous >= 20, previous < 100, previous % 10 == 0, value > 0, value < 10 {
                out[out.count - 1] = String(previous + value)
            } else {
                out.append(String(value))
            }
        }
        return out
    }

    public static func score(reference: String, hypothesis: String) -> Score {
        let r = normalize(reference)
        let h = normalize(hypothesis)
        guard !r.isEmpty else { return Score(errors: h.count, words: 0) }
        var previous = Array(0...h.count)
        for i in 1...r.count {
            var current = [i] + Array(repeating: 0, count: h.count)
            if !h.isEmpty {
                for j in 1...h.count {
                    let cost = r[i - 1] == h[j - 1] ? 0 : 1
                    current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + cost)
                }
            }
            previous = current
        }
        return Score(errors: previous[h.count], words: r.count)
    }
}

/// I numeri scritti a parole, in italiano e in inglese, fino a 999.
public enum NumberWords {
    static let units: [String: Int] = [
        "zero": 0, "uno": 1, "un": 1, "una": 1, "due": 2, "tre": 3, "tré": 3, "quattro": 4, "cinque": 5, "sei": 6, "sette": 7, "otto": 8, "nove": 9,
        "dieci": 10, "undici": 11, "dodici": 12, "tredici": 13, "quattordici": 14, "quindici": 15, "sedici": 16,
        "diciassette": 17, "diciotto": 18, "diciannove": 19,
        "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7, "eight": 8, "nine": 9, "ten": 10,
        "eleven": 11, "twelve": 12, "thirteen": 13, "fourteen": 14, "fifteen": 15, "sixteen": 16, "seventeen": 17,
        "eighteen": 18, "nineteen": 19,
    ]
    static let tens: [(String, Int)] = [
        ("venti", 20), ("trenta", 30), ("quaranta", 40), ("cinquanta", 50), ("sessanta", 60), ("settanta", 70), ("ottanta", 80), ("novanta", 90),
        ("twenty", 20), ("thirty", 30), ("forty", 40), ("fifty", 50), ("sixty", 60), ("seventy", 70), ("eighty", 80), ("ninety", 90),
    ]

    /// Il valore di una parola, se è un numero: "ventinove" dà 29, "15" dà 15, "casa" dà nil.
    public static func value(_ word: String) -> Int? {
        if let n = Int(word) { return n }
        if let n = units[word] { return n }
        var rest = Substring(word)
        var total = 0
        if rest.hasPrefix("cento") {
            total += 100
            rest = rest.dropFirst(5)
            if rest.isEmpty { return total }
        }
        for (name, n) in tens {
            // "ventuno", "ventotto": la vocale finale cade davanti a uno e otto.
            let stem = name.hasSuffix("i") || name.hasSuffix("a") ? String(name.dropLast()) : name
            if rest.hasPrefix(name) {
                let tail = String(rest.dropFirst(name.count))
                if tail.isEmpty { return total + n }
                if let u = units[tail], u < 10 { return total + n + u }
            } else if rest.hasPrefix(stem), stem != name {
                let tail = String(rest.dropFirst(stem.count))
                if tail == "uno" || tail == "otto" { return total + n + (units[tail] ?? 0) }
            }
        }
        if total > 0, let u = units[String(rest)] { return total + u }
        return nil
    }
}
