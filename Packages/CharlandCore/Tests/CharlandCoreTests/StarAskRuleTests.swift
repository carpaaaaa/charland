import Testing
@testable import CharlandCore

@Suite("Stella su GitHub: quando chiederla")
struct StarAskRuleTests {
    @Test("dopo un aggiornamento sì, alla prima installazione e a versione uguale no")
    func rule() {
        #expect(StarAskRule.shouldAsk(previous: "1.6", current: "1.7", done: false))
        #expect(!StarAskRule.shouldAsk(previous: nil, current: "1.7", done: false))
        #expect(!StarAskRule.shouldAsk(previous: "", current: "1.7", done: false))
        #expect(!StarAskRule.shouldAsk(previous: "1.7", current: "1.7", done: false))
    }

    @Test("dopo una scelta non chiede più, nemmeno agli aggiornamenti dopo")
    func done() {
        #expect(!StarAskRule.shouldAsk(previous: "1.6", current: "1.7", done: true))
    }
}
