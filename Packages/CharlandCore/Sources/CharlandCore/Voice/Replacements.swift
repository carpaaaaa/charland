import Foundation

/// Una sostituzione della dettatura: quando dici `spoken`, scrive `written` («gta 6» diventa «GTA VI»).
/// Come gli «snippet» di OpenWhispr.
public struct Replacement: Codable, Equatable, Sendable, Identifiable {
    public var id = UUID()
    public var spoken: String
    public var written: String

    public init(spoken: String, written: String) {
        self.spoken = spoken
        self.written = written
    }
}

/// Applica le sostituzioni a un testo trascritto.
///
/// Si confrontano parole intere, una per una, senza guardare maiuscole e accenti: «gta 6» vale per «Gta 6.» e per
/// «GTA6» (lettere e cifre attaccate contano come due parole), ma non per «gta 60», «gta 6.5» o «g t a 6». I numeri
/// scritti in lettere valgono quando la regola è una frase con dentro un numero («gta sei»); una regola fatta solo di
/// un numero non tocca «sei» o «six». In cinese, giapponese e simili, dove non ci sono spazi, ogni carattere è una
/// parola. La punteggiatura attorno resta com'è.
public enum Replacements {
    enum Kind { case word, digits, ideograph }

    struct Token {
        var range: Range<String.Index>
        var key: String
        var kind: Kind
        /// Il valore se è un numero, in cifre o in lettere.
        var number: Int?
    }

    public static func isIdeograph(_ c: Character) -> Bool {
        guard let s = c.unicodeScalars.first?.value else { return false }
        return (0x4E00...0x9FFF).contains(s) || (0x3400...0x4DBF).contains(s) || (0x3040...0x30FF).contains(s)
            || (0xF900...0xFAFF).contains(s) || (0x20000...0x2A6DF).contains(s)
    }

    static func tokens(_ text: String) -> [Token] {
        var out: [Token] = []
        var start: String.Index?
        var kind: Kind = .word
        func close(at end: String.Index) {
            guard let s = start else { return }
            let raw = String(text[s..<end])
            let folded = raw.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            out.append(Token(range: s..<end, key: folded, kind: kind,
                             number: kind == .digits ? Int(folded) : (kind == .word ? NumberWords.value(folded) : nil)))
            start = nil
        }
        var i = text.startIndex
        while i < text.endIndex {
            let c = text[i]
            if isIdeograph(c) {
                close(at: i)
                start = i
                kind = .ideograph
                close(at: text.index(after: i))
            } else if c.isNumber || c.isLetter {
                let k: Kind = c.isNumber ? .digits : .word
                // lettere e cifre attaccate («gta6») sono due parole
                if start != nil, k != kind { close(at: i) }
                if start == nil { start = i; kind = k }
            } else {
                close(at: i)
            }
            i = text.index(after: i)
        }
        close(at: text.endIndex)
        return out
    }

    struct Rule {
        var tokens: [Token]
        var written: String
        /// La regola è una frase con dentro almeno una parola che non è un numero.
        var hasWords: Bool
        /// Quando la frase scritta contiene quella detta («mia mail» diventa «mia mail: nome@posta.it»): a quanti
        /// caratteri dall'inizio della scritta ricompare la detta. Vuoto per tutte le altre regole.
        var inside: [Int] = []
    }

    static func rule(_ r: Replacement) -> Rule? {
        let tokens = tokens(r.spoken)
        guard !tokens.isEmpty, !r.written.isEmpty else { return nil }
        var rule = Rule(tokens: tokens, written: r.written, hasWords: tokens.contains { $0.number == nil })
        let written = Self.tokens(r.written)
        if written.count >= tokens.count {
            for j in 0...(written.count - tokens.count)
            where tokens.indices.allSatisfy({ same(written[j + $0], tokens[$0], numbers: rule.hasWords) }) {
                rule.inside.append(r.written.distance(from: r.written.startIndex, to: written[j].range.lowerBound))
            }
        }
        return rule
    }

    /// La frase scritta di questa regola c'è già, identica, attorno alla parola trovata: restituisce dove finisce.
    /// Le sostituzioni si applicano più di una volta allo stesso testo (dopo le regole e dopo la pulizia): senza
    /// questo controllo la seconda passata riscriveva dentro la prima («mia mail: mia mail: nome@posta.it…»).
    static func existing(_ rule: Rule, in text: String, at match: String.Index) -> String.Index? {
        for offset in rule.inside {
            guard let start = text.index(match, offsetBy: -offset, limitedBy: text.startIndex),
                  text[start...].hasPrefix(rule.written) else { continue }
            return text.index(start, offsetBy: rule.written.count)
        }
        return nil
    }

    static func same(_ text: Token, _ rule: Token, numbers: Bool) -> Bool {
        if text.key == rule.key { return true }
        if numbers, let a = text.number, let b = rule.number { return a == b }
        return false
    }

    /// Dopo una cifra, «,5», «.5» o «-0» continuano il numero: non è la fine della parola.
    static func continuesNumber(_ text: String, after index: String.Index) -> Bool {
        guard index < text.endIndex, ".,-".contains(text[index]) else { return false }
        let next = text.index(after: index)
        return next < text.endIndex && text[next].isNumber
    }

    public static func apply(_ text: String, _ replacements: [Replacement]) -> String {
        let rules = replacements.compactMap(rule).sorted { $0.tokens.count > $1.tokens.count }
        guard !rules.isEmpty else { return text }
        let words = tokens(text)
        guard !words.isEmpty else { return text }
        var result = ""
        var cursor = text.startIndex
        var i = 0
        while i < words.count {
            var matched: Rule?
            for rule in rules where i + rule.tokens.count <= words.count {
                var ok = true
                for (k, wanted) in rule.tokens.enumerated() where !same(words[i + k], wanted, numbers: rule.hasWords) {
                    ok = false
                    break
                }
                guard ok else { continue }
                let first = words[i], last = words[i + rule.tokens.count - 1]
                // parole intere: niente lettere o cifre attaccate prima o dopo (tranne fra ideogrammi)
                if first.kind != .ideograph, first.range.lowerBound > text.startIndex {
                    let before = text[text.index(before: first.range.lowerBound)]
                    if before.isLetter || before.isNumber, !isIdeograph(before) { continue }
                }
                if last.kind != .ideograph, last.range.upperBound < text.endIndex {
                    let after = text[last.range.upperBound]
                    if after.isLetter || after.isNumber, !isIdeograph(after) { continue }
                }
                if last.kind == .digits, continuesNumber(text, after: last.range.upperBound) { continue }
                matched = rule
                break
            }
            // Già scritta: resta com'è, e nessun'altra regola la riscrive da dentro.
            if let rule = matched, let end = existing(rule, in: text, at: words[i].range.lowerBound) {
                i += 1
                while i < words.count, words[i].range.lowerBound < end { i += 1 }
                continue
            }
            if let rule = matched {
                result += text[cursor..<words[i].range.lowerBound]
                result += rule.written
                cursor = words[i + rule.tokens.count - 1].range.upperBound
                i += rule.tokens.count
            } else {
                i += 1
            }
        }
        result += text[cursor...]
        return result
    }
}
