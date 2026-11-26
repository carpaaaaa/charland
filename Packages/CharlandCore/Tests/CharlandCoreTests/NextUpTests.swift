import Foundation
import Testing
@testable import CharlandCore

@Suite("Calendario nel Dock: la prossima cosa")
struct NextUpTests {
    private let cal = Calendar(identifier: .gregorian)
    private func day(_ m: Int, _ d: Int) -> Date { cal.date(from: DateComponents(year: 2026, month: m, day: d))! }

    @Test("una cosa a un'ora il 30: si vede quella")
    func timedLater() {
        #expect(NextUp.choose(days: [day(11, 30)], timed: [true], timedPick: 0) == 0)
    }

    @Test("a un'ora l'1, senza ora il 30: si vede quella senza ora")
    func untimedNearer() {
        // L'elenco è per giorno: prima il 30 (senza ora), poi l'1 (con un'ora).
        #expect(NextUp.choose(days: [day(11, 30), day(12, 1)], timed: [false, true], timedPick: 1) == 0)
    }

    @Test("lo stesso giorno: prima quella con un'ora")
    func sameDayTimedFirst() {
        #expect(NextUp.choose(days: [day(11, 30), day(11, 30)], timed: [false, true], timedPick: 1) == 1)
    }

    @Test("oggi solo senza ora, domani con un'ora: oggi")
    func todayUntimed() {
        #expect(NextUp.choose(days: [day(11, 26), day(11, 27)], timed: [false, true], timedPick: 1) == 0)
    }

    @Test("niente: niente")
    func empty() {
        #expect(NextUp.choose(days: [], timed: [], timedPick: nil) == nil)
    }
}
