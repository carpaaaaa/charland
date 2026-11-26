import Testing
@testable import CharlandCore

@Suite("Stella su GitHub: quando chiederla")
struct StarAskRuleTests {
    @Test("dopo ogni aggiornamento sì, alla prima installazione e a versione uguale no")
    func rule() {
        #expect(StarAskRule.shouldAsk(previous: "1.6", current: "1.7"))
        #expect(StarAskRule.shouldAsk(previous: "1.7", current: "1.8"))
        #expect(!StarAskRule.shouldAsk(previous: nil, current: "1.7"))
        #expect(!StarAskRule.shouldAsk(previous: "", current: "1.7"))
        #expect(!StarAskRule.shouldAsk(previous: "1.7", current: "1.7"))
    }
}
