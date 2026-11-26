import Testing
@testable import CharlandCore

@Suite("Voce: controllo dell'uscita del modello che pulisce")
struct CleanupGuardTests {
    @Test("ogni coppia scritta a mano ha il verdetto giusto", arguments: CleanupGuardCases.all)
    func handMade(_ c: CleanupGuardCases.Case) {
        let verdict = CleanupGuard.check(original: c.rules, cleaned: CleanupGuard.tidy(c.out, original: c.rules),
                                         vocabulary: c.vocabulary, language: c.language)
        #expect((verdict == .accepted) == c.accept, "\(c.id): \(verdict)")
    }

    @Test("una parola del vocabolario comparsa dove non era stata detta ferma tutto")
    func insertedTerm() {
        let rules = "La scritta va sopra e cambia, poi fa un effetto un po' glitchy."
        #expect(CleanupGuard.check(original: rules, cleaned: rules + " GTA VI.", vocabulary: ["GTA VI"]) != .accepted)
        #expect(CleanupGuard.check(original: rules, cleaned: "La scritta va sopra e cambia. Poi fa un effetto un po' glitchy.", vocabulary: ["GTA VI"]) == .accepted)
    }
}
