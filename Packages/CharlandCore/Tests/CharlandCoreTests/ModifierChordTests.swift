import Testing
@testable import CharlandCore

@Suite("Voce: scorciatoia di soli modificatori")
struct ModifierChordTests {
    // bit di prova: ⌃ = 1, ⌥ = 2, ⇧ = 4, ⌘ = 8
    let control: UInt = 1, option: UInt = 2, shift: UInt = 4, command: UInt = 8

    @Test("⌃ e poi ⌥: comincia quando ci sono tutti e due, finisce lasciandone uno")
    func hold() {
        var c = ModifierChord(target: control | option)
        #expect(c.flags(control, now: 0) == nil)
        #expect(c.flags(control | option, now: 0.05) == .down)
        #expect(c.isClean(now: 0.5))
        #expect(c.flags(control, now: 1.2) == .up)
        #expect(c.flags(0, now: 1.25) == nil)
        // e si ricomincia
        #expect(c.flags(option, now: 2) == nil)
        #expect(c.flags(control | option, now: 2.05) == .down)
    }

    @Test("un tasto mentre si tiene ⌃⌥ (⌃⌥A): annulla, e il rilascio non scrive niente")
    func chordWithKey() {
        var c = ModifierChord(target: control | option)
        #expect(c.flags(control | option, now: 0) == .down)
        #expect(c.otherInput() == .other)
        #expect(c.otherInput() == nil)
        #expect(!c.isClean(now: 0.2))
        #expect(c.flags(option, now: 0.3) == nil)
        #expect(c.flags(0, now: 0.35) == nil)
        #expect(c.flags(control | option, now: 1) == .down)
    }

    @Test("un tasto preso da un'altra app non arriva come evento: lo dice il tempo dall'ultimo tasto")
    func hiddenKey() {
        var c = ModifierChord(target: control | option)
        #expect(c.flags(control | option, now: 10) == .down)
        // 0,4 s dall'ultimo tasto, tenuto per 0,9 s: il tasto è arrivato nel mezzo
        #expect(!c.isClean(now: 10.9, secondsSinceInput: 0.4))
        #expect(c.flags(control, now: 10.9, secondsSinceInput: 0.4) == .other)
        // l'ultimo tasto era prima di cominciare: va bene
        #expect(c.flags(control | option, now: 20) == .down)
        #expect(c.flags(0, now: 21, secondsSinceInput: 3) == .up)
    }

    @Test("un modificatore in più è un'altra scorciatoia, anche quando torna a ⌃⌥")
    func extraModifier() {
        var c = ModifierChord(target: control | option)
        #expect(c.flags(control | option, now: 0) == .down)
        #expect(c.flags(control | option | shift, now: 0.1) == .other)
        // lasciato ⇧ con ⌃⌥ ancora giù: non ricomincia da sola
        #expect(c.flags(control | option, now: 0.2) == nil)
        #expect(c.flags(option, now: 0.3) == nil)
        #expect(c.flags(control | option, now: 0.4) == .down)
    }

    @Test("⇧ premuto prima di ⌃⌥ e lasciato per primo: non comincia")
    func otherOrder() {
        var c = ModifierChord(target: control | option)
        #expect(c.flags(shift, now: 0) == nil)
        #expect(c.flags(shift | control | option, now: 0.05) == nil)
        #expect(c.flags(control | option, now: 0.2) == nil)
        #expect(c.flags(0, now: 0.3) == nil)
        #expect(c.flags(control | option, now: 1) == .down)
    }

    @Test("solo uno dei due, o con ⌘, non conta")
    func partial() {
        var c = ModifierChord(target: control | option)
        #expect(c.flags(option, now: 0) == nil)
        #expect(c.flags(0, now: 0.5) == nil)
        #expect(c.flags(command | control | option, now: 1) == nil)
        #expect(!c.held)
    }
}
