import Testing
import Foundation
@testable import CharlandKit

@Suite("Schema dell'API")
struct SchemaTests {
    func upsert(_ edit: (inout ActivityMessage) -> Void = { _ in }) -> ActivityMessage {
        var m = ActivityMessage(op: .upsert, client: "build", id: "b1")
        m.template = .progress
        m.title = "Build"
        m.progress = 0.4
        edit(&m)
        return m
    }

    @Test("un avanzamento valido passa, e va e torna dal JSON identico")
    func roundTrip() throws {
        let m = upsert { $0.symbol = "hammer.fill"; $0.tint = "blue"; $0.status = "Compilo" }
        let data = try ActivitySchema.encode(m)
        #expect(try ActivitySchema.decode(data) == m)
    }

    @Test("tre righe di terminale bastano: JSON scritto a mano")
    func handwritten() throws {
        let json = #"{"v":1,"op":"upsert","client":"build","id":"b1","template":"progress","title":"Build","progress":0.5}"#
        let m = try ActivitySchema.decode(Data(json.utf8))
        #expect(m.progress == 0.5)
    }

    @Test("rifiuta quello che esce dalle regole")
    func rejects() {
        func bad(_ m: ActivityMessage) -> Bool { (try? ActivitySchema.validate(m)) == nil }
        #expect(bad(upsert { $0.v = 2 }))
        #expect(bad(upsert { $0.title = nil }))
        #expect(bad(upsert { $0.progress = 1.5 }))
        #expect(bad(upsert { $0.progress = nil }))
        #expect(bad(upsert { $0.tint = "#ff0000" }))
        #expect(bad(upsert { $0.symbol = "<script>" }))
        #expect(bad(upsert { $0.ttl = 9 * 3600 }), "al massimo 8 ore")
        #expect(bad(upsert { $0.priority = 9 }))
        #expect(bad(upsert { $0.client = "a/b" }))
        #expect(bad(upsert { $0.title = String(repeating: "x", count: 61) }))
        #expect(bad(upsert { $0.title = "ciao\u{07}" }))
        #expect(bad(upsert { $0.actions = [.init(id: "a", title: "A"), .init(id: "b", title: "B"), .init(id: "c", title: "C")] }), "al massimo due azioni")
        #expect(bad(upsert { $0.actions = [.init(id: "a", title: "A"), .init(id: "a", title: "B")] }))
        #expect(bad(upsert { $0.alert = .init(haptic: "boom") }))
        #expect(bad(upsert { $0.slots = ["sopra": .init(text: "x")] }))
        #expect(bad(upsert { $0.template = .countdown }), "il conto alla rovescia vuole endsAt")
        #expect(bad(upsert { $0.template = .approval }), "l'approvazione vuole il comando")
        #expect(bad(ActivityMessage(op: .end, client: "build")), "chiudere vuole l'id")
    }

    @Test("un messaggio più grande di 4 KB non passa")
    func size() {
        var m = ActivityMessage(op: .upsert, client: "build", id: "b1")
        m.template = .custom
        m.title = "x"
        let json = "{\"v\":1,\"op\":\"upsert\",\"client\":\"build\",\"id\":\"b1\",\"template\":\"status\",\"title\":\"x\",\"junk\":\"" + String(repeating: "a", count: 5000) + "\"}"
        #expect(throws: ActivitySchema.Invalid.tooLarge(json.utf8.count)) { try ActivitySchema.decode(Data(json.utf8)) }
    }

    @Test("conto alla rovescia e approvazione validi")
    func templates() throws {
        var c = ActivityMessage(op: .upsert, client: "forno", id: "pizza")
        c.template = .countdown
        c.title = "Pizza"
        c.endsAt = Date().timeIntervalSince1970 + 600
        try ActivitySchema.validate(c)
        var a = ActivityMessage(op: .upsert, client: "claude-code", id: "s1")
        a.template = .approval
        a.title = "charland"
        a.command = "rm -rf build/"
        a.detail = "Cancella la cartella build."
        try ActivitySchema.validate(a)
        try ActivitySchema.validate(ActivityMessage(op: .hello, client: "x"))
    }
}

@Suite("Lettura dell'avanzamento")
struct ProgressTests {
    @Test("percentuali dei programmi più comuni")
    func percentages() {
        #expect(ProgressParser.fraction(in: "Downloading… 45%") == 0.45)
        #expect(ProgressParser.fraction(in: " 12.5% [=====>      ] 3.2MB/s") == 0.125)
        #expect(ProgressParser.fraction(in: "frame= 1200 fps= 60 progress 100 %") == 1.0)
        #expect(ProgressParser.fraction(in: "curl: 10% then 80%") == 0.8, "vale l'ultima")
        #expect(ProgressParser.fraction(in: "niente qui") == nil)
        #expect(ProgressParser.fraction(in: "errore 404%") == nil)
    }

    @Test("contatori n/m")
    func counters() {
        #expect(ProgressParser.fraction(in: "[12/340] Compiling Foo.swift") == 12.0 / 340.0)
        #expect(ProgressParser.fraction(in: "Step (3/4) : RUN npm install") == 0.75)
        #expect(ProgressParser.fraction(in: "aggiornato il 16/11/2026") == nil, "una data non è un avanzamento")
        #expect(ProgressParser.fraction(in: "usr/local/bin 3/2") == nil)
    }

    @Test("righe riscritte con il ritorno a capo e colori")
    func stream() {
        var p = ProgressParser()
        #expect(p.feed("Scarico\r 10%") == .init(fraction: nil, line: "Scarico"))
        #expect(p.feed("\r 55%\r\u{1B}[32m 90%\u{1B}[0m\n") == .init(fraction: 0.9, line: "90%"))
        #expect(p.feed("Fatto\n") == .init(fraction: 0.9, line: "Fatto"))
        #expect(p.fraction == 0.9)
    }
}

@Suite("Aggiornamento parziale")
struct PartialUpdateTests {
    @Test("un aggiornamento parziale passa senza modello né titolo")
    func validatesWithoutTitle() throws {
        var m = ActivityMessage(op: .upsert, client: "charland", id: "timer-1")
        m.partial = true
        m.alert = .init(expand: true)
        try ActivitySchema.validate(m)
    }

    @Test("unito all'attività di prima tiene quello che non cambia e non tiene l'avviso")
    func mergeKeepsFields() {
        var base = ActivityMessage(op: .upsert, client: "charland", id: "timer-1")
        base.template = .countdown
        base.title = "Pasta"
        base.endsAt = 1_000
        base.tint = "orange"
        base.alert = .init(haptic: "done")
        var change = ActivityMessage(op: .upsert, client: "charland", id: "timer-1")
        change.partial = true
        change.subtitle = "quasi pronta"
        change.alert = .init(expand: true)
        let merged = change.merged(onto: base)
        #expect(merged.template == .countdown)
        #expect(merged.title == "Pasta")
        #expect(merged.endsAt == 1_000)
        #expect(merged.tint == "orange")
        #expect(merged.subtitle == "quasi pronta")
        #expect(merged.alert == .init(expand: true))
        #expect(merged.partial == nil)
    }
}
