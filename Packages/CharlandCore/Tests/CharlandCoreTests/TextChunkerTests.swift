import Testing
@testable import CharlandCore

@Suite("Voce: testo lungo a pezzi per la pulizia")
struct TextChunkerTests {
    @Test("un testo corto resta un pezzo solo, uguale a prima")
    func short() {
        let text = "Domani alle dieci ho il dentista. Ricordami di portare le lastre!"
        let chunks = TextChunker.chunks(text)
        #expect(chunks.count == 1)
        #expect(TextChunker.join(chunks) == text)
        #expect(TextChunker.chunks("").isEmpty)
        #expect(TextChunker.chunks("   ").isEmpty)
    }

    @Test("un testo lungo diventa gruppi di frasi intere sotto il limite, e torna com'era")
    func long() {
        let sentences = (1...12).map { "Questa è la frase numero \($0), con qualche parola in più per farla lunga." }
        let text = sentences.joined(separator: " ")
        let chunks = TextChunker.chunks(text, maxWords: 40)
        #expect(chunks.count >= 4)
        let longest = chunks.map { $0.text.split(separator: " ").count }.max() ?? 0
        #expect(longest <= 40)
        let whole = chunks.filter { $0.text.hasSuffix(".") }.count
        #expect(whole == chunks.count)
        #expect(TextChunker.join(chunks) == text)
    }

    @Test("gli a capo restano dove sono e separano sempre i pezzi")
    func paragraphs() {
        let text = "Primo capoverso. Ancora primo.\n\nSecondo capoverso.\nTerza riga senza punto"
        let chunks = TextChunker.chunks(text)
        #expect(chunks.map(\.text) == ["Primo capoverso. Ancora primo.", "Secondo capoverso.", "Terza riga senza punto"])
        #expect(TextChunker.join(chunks) == text)
    }

    @Test("una frase lunghissima senza punti si taglia alle virgole, se no fra due parole")
    func runOn() {
        let withCommas = (1...30).map { "parola\($0) e ancora parola, poi" }.joined(separator: " ")
        let chunks = TextChunker.chunks(withCommas, maxWords: 30)
        #expect(chunks.count >= 4)
        let endsAtComma = chunks.dropLast().filter { $0.text.hasSuffix(",") }.count
        #expect(endsAtComma == chunks.count - 1)
        #expect(TextChunker.join(chunks) == withCommas)

        let plain = (1...100).map { "parola\($0)" }.joined(separator: " ")
        let cut = TextChunker.chunks(plain, maxWords: 30)
        #expect(cut.count == 4)
        #expect(TextChunker.join(cut) == plain)
    }

    @Test("i numeri con il punto e le sigle non chiudono la frase")
    func dots() {
        let text = "Costa 29.90 euro su example.com e basta."
        #expect(TextChunker.chunks(text).count == 1)
    }
}
