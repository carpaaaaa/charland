import Foundation
import Testing
@testable import CharlandCore

private let sample = """
[00:00.80] Resta ancora un minuto qui
[00:04.30] la città si spegne piano
[00:07.80] e io conto le finestre accese
[00:11.80] luce bianca sopra i tetti
[00:15.20] luce bianca dentro me
[00:18.60] portami dove non fa rumore
[00:22.60] resta ancora, resta qui
[00:26.00] luce bianca, resta qui
"""

private func map(_ text: String = sample, width: Double = 1450, height: Double = 640, title: String = "") -> SongMap {
    let lines = LRC.parse(text, trackDuration: 40).lines
    return SongMap(lines: lines, width: width, height: height, levels: SongMap.levels(lines: lines, title: title)) { Double($0.count) * 15 }
}

/// L'ingombro di ogni parola attorno alla sua stella (la stella sopra, la scritta sotto) al corpo che avrà alla fine,
/// già rimpicciolito come la strofa.
private func boxes(_ m: SongMap) -> [(text: String, minX: Double, maxX: Double, minY: Double, maxY: Double)] {
    m.nodes.map { node in
        let box = SongMap.box(width: node.width, size: m.size(of: node, count: node.hits.count))
        return (node.text, node.x - box.left * m.fit, node.x + box.right * m.fit, node.y - box.up * m.fit, node.y + box.down * m.fit)
    }
}

@Test func aWordThatComesBackIsTheSamePoint() {
    let m = map()
    let resta = m.nodes.filter { $0.text == "resta" }
    #expect(resta.count == 1)
    #expect(resta[0].hits.count == 4)
    // «Resta» con la maiuscola e «resta,» con la virgola sono la stessa parola
    #expect(m.nodes.contains { $0.text == "Resta" || $0.text == "resta," } == false)
    #expect(m.steps.count == 38)
}

@Test func aRoadTakenTwiceIsOneRoadThatWidens() {
    let m = map()
    let luce = m.nodes.firstIndex { $0.text == "luce" }!, bianca = m.nodes.firstIndex { $0.text == "bianca" }!
    let roads = m.roads.filter { ($0.a == luce && $0.b == bianca) || ($0.a == bianca && $0.b == luce) }
    #expect(roads.count == 1)
    #expect(roads[0].passes.count == 3)
    #expect(roads[0].passed(at: 12.5)?.count == 1)
    #expect(roads[0].passed(at: 5) == nil)
}

@Test func aWordRepeatedInARowGetsAStarEachTime() {
    // «boom boom boom»: tre stelle diverse, in tre posti diversi, unite una all'altra
    let m = map("[00:01.00] senti il boom boom boom\n[00:05.00] dentro la notte\n")
    let booms = m.nodes.indices.filter { m.nodes[$0].text == "boom" }
    #expect(booms.count == 3)
    #expect(Set(booms.map { "\(m.nodes[$0].x)|\(m.nodes[$0].y)" }).count == 3)
    #expect(booms.allSatisfy { m.nodes[$0].hits.count == 1 })
    #expect(m.roads.contains { $0.a == booms[0] && $0.b == booms[1] })
    #expect(m.roads.contains { $0.a == booms[1] && $0.b == booms[2] })
    // nessun passo resta sulla stessa stella
    for k in 1..<m.steps.count { #expect(m.steps[k].node != m.steps[k - 1].node) }
}

@Test func aWordTakenUpAgainLaterGoesBackToItsStar() {
    // «ho fatto la torta fatto»: il secondo «fatto» non è di fila, torna sulla stella del primo
    let m = map("[00:01.00] io ho fatto la torta fatto\n")
    let fatto = m.nodes.filter { $0.text == "fatto" }
    #expect(fatto.count == 1)
    #expect(fatto[0].hits.count == 2)
    #expect(m.nodes.count == 5)
    #expect(m.steps.count == 6)
}

@Test func aRowThatComesBackWalksTheSameStars() {
    // «la torta torta» due volte: la seconda volta ripassa dalle stesse due stelle, non ne aggiunge
    let m = map("[00:01.00] ho fatto la torta torta\n[00:05.00] ho fatto la torta torta\n")
    let torte = m.nodes.indices.filter { m.nodes[$0].text == "torta" }
    #expect(torte.count == 2)
    #expect(torte.allSatisfy { m.nodes[$0].hits.count == 2 })
    let between = m.roads.first { $0.a == torte[0] && $0.b == torte[1] }
    #expect(between?.passes.count == 2)
    // anche a cavallo di due righe una fila resta una fila
    let across = map("[00:01.00] senti il boom\n[00:03.00] boom dentro me\n")
    #expect(across.nodes.filter { $0.text == "boom" }.count == 2)
}

@Test func serviceWordsDoNotGrow() {
    #expect(SongMap.isPlain("e"))
    #expect(SongMap.isPlain("the"))
    #expect(!SongMap.isPlain("luce"))
    let m = map()
    // «i» torna, ma è un articolo: resta al corpo base, anche quando torna nella strofa
    let article = m.nodes.first { $0.text == "i" }!
    #expect(article.plain && article.level == 0)
    #expect(m.size(of: article, count: 4) == SongMap.baseSize)
    // non cresce all'infinito
    let resta = m.nodes.first { $0.text == "resta" }!
    #expect(m.size(of: resta, count: 40) <= SongMap.baseSize + Double(SongMap.maxGrowth) * SongMap.growth)
}

@Test func theWordsThatMatterAreBornBigger() {
    let lines = LRC.parse(sample, trackDuration: 40).lines
    let levels = SongMap.levels(lines: lines)
    // «resta» torna quattro volte, «luce» e «bianca» tre: contano più di «città», detta una volta
    #expect((levels["resta"] ?? 0) >= 2)
    #expect((levels["luce"] ?? 0) >= 1)
    #expect(levels["città"] == nil)
    // le parole di servizio non contano mai
    #expect(levels["la"] == nil && levels["e"] == nil)
    let m = map()
    let resta = m.nodes.first { $0.text == "resta" }!, city = m.nodes.first { $0.text == "città" }!
    // nasce già grande, alla prima volta che viene cantata
    #expect(m.size(of: resta, count: 1) > m.size(of: city, count: 1))
    #expect(m.size(of: city, count: 1) == SongMap.baseSize)
    // e tornando nella stessa strofa prende un grado in più, fino al massimo
    #expect(m.size(of: resta, count: 2) >= m.size(of: resta, count: 1))
}

@Test func theTitleCounts() {
    let lines = LRC.parse(sample, trackDuration: 40).lines
    let plain = SongMap.levels(lines: lines), named = SongMap.levels(lines: lines, title: "Finestre accese (Remastered 2011)")
    #expect(plain["finestre"] == nil)
    #expect((named["finestre"] ?? 0) >= 2)
    #expect((named["accese"] ?? 0) >= 2)
    // quello che sta fra parentesi nel titolo non è il titolo
    #expect(named["remastered"] == nil)
}

@Test func aShoutedWordCounts() {
    let lines = LRC.parse("[00:01.00] piano piano e poi FORTE\n[00:05.00] resta qui con me\n[00:09.00] ancora!\n", trackDuration: 20).lines
    let levels = SongMap.levels(lines: lines)
    #expect((levels["forte"] ?? 0) >= 1)
    #expect((levels["ancora"] ?? 0) >= 1)
    #expect(levels["resta"] == nil)
}

@Test func fewWordsReachTheTop() {
    // una canzone dove tutto torna allo stesso modo: non possono essere tutte al massimo
    var text = ""
    let verse = ["luce bianca sopra tetti", "vento freddo dentro strade", "notte lunga senza sonno", "fuoco lento sotto pelle", "mare scuro contro scogli"]
    for round in 0..<6 { for (i, line) in verse.enumerated() { text += String(format: "[%02d:%02d.00] %@\n", (round * 20 + i * 4) / 60, (round * 20 + i * 4) % 60, line) } }
    let levels = SongMap.levels(lines: LRC.parse(text, trackDuration: 130).lines)
    #expect(levels.values.filter { $0 == 3 }.count <= 2)
    #expect(levels.values.filter { $0 >= 2 }.count <= 5)
}

@Test func labelsKeepTheEnglishI() {
    #expect(SongMap.label("I'm") == "I'm")
    #expect(SongMap.label("Resta,") == "resta")
    #expect(SongMap.key("Don't") == "dont")
    #expect(SongMap.key("...") == "")
}

@Test func noLabelCoversAnother() {
    let all = boxes(map())
    for i in all.indices {
        for j in all.indices where j > i {
            let a = all[i], b = all[j]
            let apart = a.maxX <= b.minX || b.maxX <= a.minX || a.maxY <= b.minY || b.maxY <= a.minY
            #expect(apart, "\(a.text) copre \(b.text)")
        }
    }
}

@Test func everyWordStaysInsideItsRectangle() {
    // una strofa normale, una stretta e una enorme: nessuna parola esce, nemmeno al corpo che avrà da cresciuta
    var long = ""
    for line in 0..<14 {
        let words = (0..<6).map { "parola\(line * 6 + $0)" }.joined(separator: " ")
        long += String(format: "[%02d:%02d.00] %@\n", line * 4 / 60, line * 4 % 60, words)
    }
    for (text, width, height) in [(sample, 1450.0, 640.0), (sample, 700.0, 300.0), (long, 1450.0, 640.0)] {
        let m = map(text, width: width, height: height)
        #expect(m.fit > 0 && m.fit <= 1)
        for box in boxes(m) {
            #expect(box.minX >= -0.5 && box.maxX <= width + 0.5, "\(box.text) esce di lato")
            #expect(box.minY >= -0.5 && box.maxY <= height + 0.5, "\(box.text) esce in alto o in basso")
        }
    }
    // quella enorme è stata rimpicciolita, quella normale no
    #expect(map(long).fit < 1)
    #expect(map().fit == 1)
}

@Test func theConstellationSpreadsOut() {
    // le stelle non stanno in fila come un testo: occupano una buona parte del rettangolo, in largo e in alto
    let m = map()
    let xs = m.nodes.map(\.x), ys = m.nodes.map(\.y)
    #expect((xs.max()! - xs.min()!) > 1450 * 0.5)
    #expect((ys.max()! - ys.min()!) > 640 * 0.4)
    // due parole cantate di seguito stanno a un passo l'una dall'altra, non ai due capi dello schermo
    let resta = m.nodes.first { $0.text == "resta" }!, ancora = m.nodes.first { $0.text == "ancora" }!
    #expect(abs(resta.x - ancora.x) + abs(resta.y - ancora.y) < 520)
}

@Test func theSameSongGivesTheSameMap() {
    #expect(map() == map())
}

@Test func theCurrentStepFollowsTheTime() {
    let m = map()
    #expect(m.step(at: 0) == -1)
    #expect(m.step(at: 0.81) == 0)
    #expect(m.step(at: 1000) == m.steps.count - 1)
    #expect(m.start == 0.8)
    #expect(m.end > 26)
}

@Test func aRoadWalkedAgainGetsStronger() {
    var text = ""
    for round in 0..<8 { text += String(format: "[00:%02d.00] luce bianca sopra\n", round * 4) }
    let m = map(text)
    #expect(m.wear(count: 1) == 0)
    #expect(m.wear(count: m.busiest) == 1)
}

// MARK: - Le strofe

@Test func aLongSilenceOpensANewStanza() {
    // due gruppi di tre righe vicine, con otto secondi di silenzio in mezzo
    let lyrics = LRC.parse("""
    [00:01.00] uno due tre
    [00:03.00] quattro cinque sei
    [00:05.00] sette otto nove
    [00:15.00] dieci undici dodici
    [00:17.00] tredici quattordici quindici
    [00:19.00] sedici diciassette diciotto
    """, trackDuration: 30)
    #expect(lyrics.stanzas() == [0..<3, 3..<6])
}

@Test func theSourceStanzasWin() {
    var lyrics = LRC.parse("""
    [00:01.00] uno due tre
    [00:03.00] quattro cinque sei
    [00:05.00] sette otto nove
    [00:07.00] dieci undici dodici
    """, trackDuration: 20)
    lyrics.stanzaStarts = LRCLIB.stanzaStarts(plain: "uno due tre\n\nquattro cinque sei\nsette otto nove\n\ndieci undici dodici\n", lineCount: 4)
    #expect(lyrics.stanzaStarts == [0, 1, 3])
    #expect(lyrics.stanzas() == [0..<1, 1..<3, 3..<4])
    // se le righe non sono tante quante quelle a tempo non ci si fida
    #expect(LRCLIB.stanzaStarts(plain: "uno\n\ndue\n", lineCount: 4).isEmpty)
}

@Test func aStanzaTooLongIsCut() {
    var text = ""
    for line in 0..<20 { text += String(format: "[00:%02d.00] una riga di cinque parole\n", line * 2) }
    let stanzas = LRC.parse(text, trackDuration: 60).stanzas()
    #expect(stanzas.count >= 3)
    #expect(stanzas.allSatisfy { $0.count <= 7 })
    // tutte le righe, una volta sola, in ordine
    #expect(stanzas.flatMap { Array($0) } == Array(0..<20))
}
