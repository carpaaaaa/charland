import Foundation

/// Divide un testo lungo in gruppi di frasi intere, per il modello che lo pulisce: un modello piccolo lavora
/// meglio e più in fretta su pezzi corti, e se un pezzo va storto si perde solo quello.
public enum TextChunker {
    public struct Chunk: Equatable, Sendable {
        /// Le frasi del pezzo, senza spazi ai lati.
        public var text: String
        /// Quello che c'era fra questo pezzo e il successivo (uno spazio, un a capo): si rimette com'era.
        public var separator: String

        public init(text: String, separator: String) {
            self.text = text
            self.separator = separator
        }
    }

    /// I pezzi del testo: frasi intere, al massimo `maxWords` parole l'uno. Una frase più lunga del limite si
    /// taglia alle virgole, e solo se non ne ha si taglia fra due parole.
    public static func chunks(_ text: String, maxWords: Int = 55) -> [Chunk] {
        var out: [Chunk] = []
        var current = ""
        var words = 0
        var pending = ""   // lo spazio fra la frase prima e quella che arriva
        func close(separator: String) {
            guard !current.isEmpty else { return }
            out.append(Chunk(text: current, separator: separator))
            current = ""
            words = 0
        }
        for unit in units(text, maxWords: maxWords) {
            let count = unit.text.split(whereSeparator: \.isWhitespace).count
            // un a capo chiude sempre il pezzo: i capoversi restano separati
            if !current.isEmpty, words + count > maxWords || pending.contains("\n") {
                close(separator: pending)
            } else if !current.isEmpty {
                current += pending
            }
            current += unit.text
            words += count
            pending = unit.separator
        }
        close(separator: pending)
        return out
    }

    /// Rimette insieme i pezzi con quello che c'era in mezzo.
    public static func join(_ chunks: [Chunk]) -> String {
        var out = ""
        for (i, chunk) in chunks.enumerated() {
            out += chunk.text
            if i < chunks.count - 1 { out += chunk.separator.isEmpty ? " " : chunk.separator }
        }
        return out
    }

    /// Le frasi (o i pezzi di frase, se una frase è troppo lunga) con lo spazio che le segue.
    static func units(_ text: String, maxWords: Int) -> [Chunk] {
        var sentences: [Chunk] = []
        var start = text.startIndex
        var i = text.startIndex
        func push(end: String.Index, next: String.Index) {
            let body = text[start..<end].trimmingCharacters(in: .whitespacesAndNewlines)
            if !body.isEmpty { sentences.append(Chunk(text: body, separator: String(text[end..<next]))) }
            start = next
        }
        while i < text.endIndex {
            let c = text[i]
            let after = text.index(after: i)
            let closes = ".?!…".contains(c) && (after == text.endIndex || text[after].isWhitespace)
            if closes || c.isNewline {
                // la frase finisce dopo il segno; lo spazio che segue è il separatore
                let end = c.isNewline ? i : after
                var next = end
                while next < text.endIndex, text[next].isWhitespace { next = text.index(after: next) }
                push(end: end, next: next)
                i = next
            } else {
                i = after
            }
        }
        push(end: text.endIndex, next: text.endIndex)

        // le frasi troppo lunghe si tagliano alle virgole, poi fra due parole
        var out: [Chunk] = []
        for sentence in sentences {
            let parts = split(sentence.text, maxWords: maxWords)
            for (k, part) in parts.enumerated() {
                out.append(Chunk(text: part, separator: k == parts.count - 1 ? sentence.separator : " "))
            }
        }
        return out
    }

    static func split(_ sentence: String, maxWords: Int) -> [String] {
        let words = sentence.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard words.count > maxWords else { return [sentence] }
        var out: [String] = []
        var current: [String] = []
        var lastComma: Int?   // dove finisce l'ultimo inciso dentro `current`
        for word in words {
            current.append(word)
            if let last = word.last, ",;:".contains(last) { lastComma = current.count }
            guard current.count >= maxWords else { continue }
            // si chiude alla virgola più vicina, se non lascia un pezzo troppo corto
            let cut = lastComma.flatMap { $0 >= maxWords / 3 ? $0 : nil } ?? current.count
            out.append(current[..<cut].joined(separator: " "))
            current = Array(current[cut...])
            lastComma = nil
        }
        if !current.isEmpty { out.append(current.joined(separator: " ")) }
        return out
    }
}
