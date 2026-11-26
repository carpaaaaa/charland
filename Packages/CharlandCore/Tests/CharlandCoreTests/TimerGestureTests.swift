import Testing
import CoreGraphics
@testable import CharlandCore

@Suite("Barra dei menu: timer trascinato")
struct TimerGestureTests {
    @Test("vicino al punto premuto si annulla, poi un minuto ogni 20 punti")
    func firstTier() {
        #expect(TimerGesture.minutes(forDistance: 10) == nil)
        #expect(TimerGesture.minutes(forDistance: 30) == nil)
        #expect(TimerGesture.minutes(forDistance: 31) == 1)
        #expect(TimerGesture.minutes(forDistance: 30 + 20) == 2)
        #expect(TimerGesture.minutes(forDistance: 30 + 14 * 20) == 15)
    }

    @Test("dopo i 15 minuti si sale di cinque, dopo l'ora di un quarto, fino a quattro ore")
    func laterTiers() {
        let afterFirst: CGFloat = 30 + 14 * 20
        #expect(TimerGesture.minutes(forDistance: afterFirst + 33) == 20)
        #expect(TimerGesture.minutes(forDistance: afterFirst + 9 * 33) == 60)
        #expect(TimerGesture.minutes(forDistance: afterFirst + 9 * 33 + 15) == 75)
        #expect(TimerGesture.minutes(forDistance: 5000) == 240)
    }

    @Test("la soglia del trascinamento si misura dal punto premuto")
    func threshold() {
        let press = CGPoint(x: 100, y: 100)
        #expect(!TimerGesture.dragBegan(press: press, current: CGPoint(x: 105, y: 104)))
        #expect(TimerGesture.dragBegan(press: press, current: CGPoint(x: 100, y: 91)))
    }

    @Test("la rotella aggiunge e toglie minuti senza uscire dai limiti")
    func wheel() {
        let press = CGPoint(x: 0, y: 0)
        #expect(TimerGesture.minutes(press: press, current: CGPoint(x: 0, y: -31), extra: 4) == 5)
        #expect(TimerGesture.minutes(press: press, current: CGPoint(x: 0, y: -31), extra: -9) == 1)
        #expect(TimerGesture.minutes(press: press, current: CGPoint(x: 0, y: -5000), extra: 400) == 480)
        #expect(TimerGesture.minutes(press: press, current: CGPoint(x: 0, y: -10), extra: 4) == nil)
    }

    @Test("le durate si leggono come in Filo")
    func labels() {
        #expect(TimerGesture.label(minutes: 25) == "25 min")
        #expect(TimerGesture.label(minutes: 60) == "1 h")
        #expect(TimerGesture.label(minutes: 145) == "2 h 25 min")
    }
}
