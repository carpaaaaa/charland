import Foundation

/// Taglia una dettatura lunga in pezzi, nelle pause.
///
/// Il motore vocale legge tutto l'audio insieme, e il costo cresce molto più in fretta della durata: un minuto
/// costa 2 secondi, cinque minuti ne costano 26 e 8 GB di memoria, e sbaglia di più. A pezzi di una quindicina
/// di secondi il costo torna in proporzione alla durata, e i pezzi finiti si trascrivono mentre parli: al
/// rilascio resta solo l'ultimo.
public enum AudioSegmenter {
    public static let sampleRate = 16000.0

    public struct Cut: Equatable, Sendable {
        /// Il campione dove tagliare.
        public var index: Int
        /// Lì c'è una pausa vera, non un attimo fra due parole.
        public var pause: Bool
    }

    /// Se l'audio è più lungo di `longest` secondi, il punto più silenzioso fra `shortest` e `longest`.
    public static func cut(_ samples: [Float], shortest: Double = 9, longest: Double = 17, window: Double = 0.2) -> Cut? {
        let hop = 160   // 10 ms
        let lo = Int(shortest * sampleRate), hi = Int(longest * sampleRate)
        guard samples.count > hi, lo < hi else { return nil }
        let firstHop = lo / hop, lastHop = hi / hop
        let width = max(1, Int(window * sampleRate) / hop)
        guard lastHop - firstHop > width else { return nil }

        // l'energia di ogni centesimo di secondo, e la finestra più silenziosa
        var energy = [Float](repeating: 0, count: lastHop - firstHop)
        samples.withUnsafeBufferPointer { buffer in
            for h in firstHop..<lastHop {
                var sum: Float = 0
                for i in (h * hop)..<((h + 1) * hop) { sum += buffer[i] * buffer[i] }
                energy[h - firstHop] = sum
            }
        }
        var running = energy[0..<width].reduce(0, +)
        var best = running, bestStart = 0
        for start in 1...(energy.count - width) {
            running += energy[start + width - 1] - energy[start - 1]
            // a parità si preferisce tagliare più avanti: pezzi più lunghi, più contesto per il motore
            if running <= best { best = running; bestStart = start }
        }
        let index = (firstHop + bestStart) * hop + width * hop / 2
        // l'energia della finestra scelta si ricalcola da capo: la somma che scorre accumula errori di
        // arrotondamento, e nel silenzio assoluto può scendere sotto zero
        let quietest = max(0, energy[bestStart..<(bestStart + width)].reduce(0, +))
        let quiet = (quietest / Float(width * hop)).squareRoot()
        var total: Float = 0
        samples.withUnsafeBufferPointer { buffer in
            for i in 0..<hi { total += buffer[i] * buffer[i] }
        }
        let level = (total / Float(hi)).squareRoot()
        return Cut(index: index, pause: quiet < max(0.0015, level * 0.2))
    }

    /// C'è della voce: almeno un decimo di secondo ha un volume da parlato, non da stanza silenziosa.
    public static func isAudible(_ samples: [Float], threshold: Float = 0.01) -> Bool {
        let window = 1600
        guard samples.count >= window * 4 else { return false }
        var loud = false
        samples.withUnsafeBufferPointer { buffer in
            var start = 0
            while start + window <= buffer.count, !loud {
                var sum: Float = 0
                for i in start..<(start + window) { sum += buffer[i] * buffer[i] }
                if (sum / Float(window)).squareRoot() > threshold { loud = true }
                start += window
            }
        }
        return loud
    }

    public struct Segment: Equatable, Sendable {
        public var range: Range<Int>
        /// Dopo questo pezzo c'è una pausa vera (l'ultimo finisce sempre con una pausa).
        public var pauseAfter: Bool
    }

    /// Tutto l'audio a pezzi: per un file, o per quello che resta al rilascio.
    public static func split(_ samples: [Float], shortest: Double = 9, longest: Double = 17) -> [Segment] {
        var out: [Segment] = []
        var start = 0
        while start < samples.count {
            // basta guardare fino al limite, più un campione per sapere che l'audio continua
            let rest = Array(samples[start..<min(samples.count, start + Int(longest * sampleRate) + 1)])
            guard let cut = cut(rest, shortest: shortest, longest: longest) else {
                out.append(Segment(range: start..<samples.count, pauseAfter: true))
                break
            }
            out.append(Segment(range: start..<(start + cut.index), pauseAfter: cut.pause))
            start += cut.index
        }
        return out
    }

    public struct Part: Equatable, Sendable {
        public var text: String
        public var pauseAfter: Bool
        public init(text: String, pauseAfter: Bool) {
            self.text = text
            self.pauseAfter = pauseAfter
        }
    }

    /// Rimette insieme i testi dei pezzi. Il motore chiude ogni pezzo con un punto e apre il successivo con la
    /// maiuscola: dove il taglio è caduto in mezzo a una frase (nessuna pausa vera) il punto si toglie e la
    /// maiuscola pure, se `lowercase` dice che quella parola in mezzo a una frase va minuscola (una parola
    /// comune, non un nome).
    public static func join(_ parts: [Part], lowercase: (String) -> Bool) -> String {
        var out = ""
        var glue = false   // il pezzo prima è finito in mezzo a una frase
        for part in parts {
            var text = part.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            if glue {
                let first = text.prefix { !$0.isWhitespace }
                let word = first.trimmingCharacters(in: .punctuationCharacters)
                if let initial = word.first, initial.isUppercase, word.dropFirst().allSatisfy({ !$0.isUppercase }), lowercase(word) {
                    text = text.prefix(1).lowercased() + text.dropFirst()
                }
            }
            glue = !part.pauseAfter
            if glue, text.hasSuffix("."), !text.hasSuffix("..") { text.removeLast() }
            out += (out.isEmpty ? "" : " ") + text
        }
        return out
    }
}
