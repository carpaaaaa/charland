import Foundation
import Testing
@testable import CharlandCore

/// I testi di prova sono inventati: nessun testo di canzoni vere nei test.
private let sample = """
[ar:Le Onde]
[ti:Luce bianca]
[00:01.20] Resta ancora un minuto qui
[00:04.70] la città si spegne piano
[00:08.20]
[00:19.60] Luce bianca sopra i tetti
"""

@Test func lrcReadsLinesAndSkipsLabels() {
    let lyrics = LRC.parse(sample, trackDuration: 30)
    #expect(lyrics.lines.count == 3)
    #expect(lyrics.lines[0].text == "Resta ancora un minuto qui")
    #expect(abs(lyrics.lines[0].start - 1.2) < 0.001)
    #expect(abs(lyrics.lines[2].start - 19.6) < 0.001)
    #expect(lyrics.wordTimingIsReal == false)
}

@Test func lrcTimeFormats() {
    #expect(LRC.seconds("01:02") == 62)
    #expect(abs((LRC.seconds("01:02.5") ?? 0) - 62.5) < 0.0001)
    #expect(abs((LRC.seconds("00:07.125") ?? 0) - 7.125) < 0.0001)
    #expect(abs((LRC.seconds("00:07:50") ?? 0) - 7.5) < 0.0001)
    #expect(LRC.seconds("ar:Nome") == nil)
    #expect(LRC.seconds("length:03:20") == nil)
}

@Test func lrcSeveralTimesOnOneLine() {
    let lyrics = LRC.parse("[00:10.00][00:30.00] ritornello che torna\n[00:20.00] strofa nel mezzo", trackDuration: 40)
    #expect(lyrics.lines.map(\.text) == ["ritornello che torna", "strofa nel mezzo", "ritornello che torna"])
}

@Test func wordsStayInsideTheirLineAndInOrder() {
    let lyrics = LRC.parse(sample, trackDuration: 30)
    for (i, line) in lyrics.lines.enumerated() {
        let next = i + 1 < lyrics.lines.count ? lyrics.lines[i + 1].start : 30
        #expect(line.words.first?.start == line.start)
        #expect(line.end <= next)
        var t = line.start
        for word in line.words {
            #expect(abs(word.start - t) < 0.0001)
            #expect(word.duration > 0.05)
            t = word.end
        }
        #expect(abs(line.end - t) < 0.0001)
    }
}

@Test func anEmptyTimedLineEndsThePhraseBefore() {
    // la seconda frase ha tempo fino a 8,2 (la riga vuota), non fino a 19,6
    let lyrics = LRC.parse(sample, trackDuration: 30)
    #expect(lyrics.lines[1].end <= 8.2)
}

@Test func aPhraseWithLotsOfRoomEndsEarly() {
    // quattro parole corte e venti secondi a disposizione: la frase non si spalma su tutti e venti
    let words = WordTiming.estimate(["resta", "ancora", "un", "poco"], start: 10, available: 20)
    #expect(words.last!.end < 14)
    // con poco tempo invece lo usa quasi tutto, senza uscirne
    let tight = WordTiming.estimate(["resta", "ancora", "un", "poco"], start: 10, available: 1.5)
    #expect(tight.last!.end <= 11.5)
    #expect(tight.last!.end > 11.2)
}

@Test func longerWordsTakeLonger() {
    let words = WordTiming.estimate(["a", "dimenticare", "te"], start: 0, available: 3)
    #expect(words[1].duration > words[0].duration * 2)
    #expect(WordTiming.weight("dimenticare") == 5)
    #expect(WordTiming.weight("qui,") > WordTiming.weight("qui"))
    #expect(WordTiming.weight("...") == 1)
}

@Test func realWordTimesAreKept() {
    let lyrics = LRC.parse("[00:10.00] <00:10.00>Luce <00:10.80>bianca <00:11.90>sopra i tetti\n[00:15.00] <00:15.00>fine", trackDuration: 20)
    #expect(lyrics.wordTimingIsReal)
    let words = lyrics.lines[0].words
    #expect(words.map(\.text) == ["Luce", "bianca", "sopra", "i", "tetti"])
    #expect(abs(words[1].start - 10.8) < 0.001)
    #expect(abs(words[0].duration - 0.8) < 0.001)
    #expect(abs(words[2].start - 11.9) < 0.001)
    #expect(words[4].end <= 15)
}

@Test func longPausesBecomeRows() {
    let lyrics = LRC.parse(sample, trackDuration: 30)
    let rows = lyrics.rows(trackDuration: 30)
    // frase, frase, pausa lunga, frase, pausa di coda
    #expect(rows.count == 5)
    guard case .pause(let s, let e) = rows[2] else { Issue.record("manca la pausa"); return }
    #expect(s > lyrics.lines[1].end && e < 19.6)
    #expect(Lyrics.index(of: rows, at: 0) == -1)
    #expect(Lyrics.index(of: rows, at: 1.15) == 0)
    #expect(Lyrics.index(of: rows, at: 5) == 1)
    #expect(Lyrics.index(of: rows, at: 15) == 2)
    #expect(Lyrics.index(of: rows, at: 20) == 3)
}

@Test func aPauseNeverStartsWhileTheLineMayStillBeSung() {
    // sei sillabe: cantate piano (0,7 s l'una) arrivano a 5,2 s, ben oltre la fine stimata delle parole
    let lyrics = LRC.parse("[00:01.00] resta qui stanotte\n[00:21.00] dopo", trackDuration: 30)
    let rows = lyrics.rows(trackDuration: 30)
    guard case .pause(let s, _) = rows[1] else { Issue.record("manca la pausa"); return }
    #expect(lyrics.lines[0].end < 4)
    #expect(s >= 1 + 6 * 0.7)
}

@Test func anEmptyTimedLineSaysWhereThePhraseEnds() {
    let lyrics = LRC.parse("[00:01.00] resta qui stanotte\n[00:02.50]\n[00:21.00] dopo", trackDuration: 30)
    #expect(lyrics.lines[0].closed == 2.5)
    #expect(lyrics.lines[1].closed == nil)
    guard case .pause(let s, _) = lyrics.rows(trackDuration: 30)[1] else { Issue.record("manca la pausa"); return }
    // la fine detta dalla fonte vale più della stima prudente
    #expect(s < 1 + 6 * 0.7)
}

@Test func aShortGapAfterASlowLineKeepsTheLineLit() {
    // la riga dopo arriva a 8,5 s: cantata piano la frase arriva a 7,3 s, quindi non resta una pausa lunga in mezzo
    let lyrics = LRC.parse("[00:01.00] resta qui stanotte con me\n[00:09.50] dopo", trackDuration: 20)
    let rows = lyrics.rows(trackDuration: 20)
    guard rows.count > 1, case .line = rows[1] else { Issue.record("la riga doveva restare accesa fino alla prossima"); return }
}

@Test func anIntroBecomesAPause() {
    let lyrics = LRC.parse("[00:12.00] prima frase dopo l'intro\n[00:15.00] seconda", trackDuration: 20)
    let rows = lyrics.rows(trackDuration: 20)
    guard case .pause(let s, let e) = rows[0] else { Issue.record("manca l'intro"); return }
    #expect(s == 0 && e < 12)
    #expect(Lyrics.index(of: rows, at: 3) == 0)
}

@Test func lrclibQuestions() {
    let url = LRCLIB.getURL(title: "Luce bianca", artist: "Le Onde", album: "Notte & giorno", duration: 200.6)
    let s = url?.absoluteString ?? ""
    #expect(s.hasPrefix("https://lrclib.net/api/get?"))
    #expect(s.contains("track_name=Luce%20bianca"))
    #expect(s.contains("album_name=Notte%20%26%20giorno"))
    #expect(s.contains("duration=201"))
    #expect(LRCLIB.searchURL(title: "Luce bianca (feat. Qualcuno)", artist: "Le Onde")?.absoluteString.contains("track_name=Luce%20bianca&") == true)
}

@Test func titlesAreComparedWithoutTheirTails() {
    #expect(LRCLIB.clean("Luce bianca (feat. Qualcuno)") == "Luce bianca")
    #expect(LRCLIB.clean("Luce bianca - Remastered 2011") == "Luce bianca")
    #expect(LRCLIB.clean("Luce bianca (Live)") == "Luce bianca")
    #expect(LRCLIB.clean("Bianca - Luce") == "Bianca - Luce")
    #expect(LRCLIB.key("Lucè Bianca!") == LRCLIB.key("luce bianca"))
    #expect(LRCLIB.cacheKey(title: "Luce bianca", artist: "Le Onde", duration: 200.4) == "leonde|lucebianca|200")
}

@Test func theBestResultHasTimesTheSameTitleAndTheClosestLength() {
    let records = [
        LRCLIBRecord(id: 1, trackName: "Luce bianca", artistName: "Le Onde", albumName: "A", duration: 230, instrumental: false, plainLyrics: "x", syncedLyrics: "[00:01.00] troppo lunga"),
        LRCLIBRecord(id: 2, trackName: "Luce bianca", artistName: "Le Onde", albumName: "B", duration: 201, instrumental: false, plainLyrics: "x", syncedLyrics: nil),
        LRCLIBRecord(id: 3, trackName: "Luce bianca (Live)", artistName: "Le Onde", albumName: "C", duration: 202, instrumental: false, plainLyrics: "x", syncedLyrics: "[00:01.00] quella giusta"),
        LRCLIBRecord(id: 4, trackName: "Luce nera", artistName: "Le Onde", albumName: "D", duration: 200, instrumental: false, plainLyrics: "x", syncedLyrics: "[00:01.00] altro brano"),
        LRCLIBRecord(id: 5, trackName: "Luce bianca", artistName: "Altri", albumName: "E", duration: 200, instrumental: false, plainLyrics: "x", syncedLyrics: "[00:01.00] altro artista"),
    ]
    #expect(LRCLIB.best(records, title: "Luce bianca", artist: "Le Onde", duration: 200)?.id == 3)
    #expect(LRCLIB.best(records, title: "Luce bianca", artist: "Le Onde", duration: 100) == nil)
}

@Test func resultsWithoutTimesAreNoLyrics() {
    #expect(LRCLIB.result(from: nil, trackDuration: 200) == .none)
    #expect(LRCLIB.result(from: LRCLIBRecord(id: 1, trackName: "x", artistName: "y", albumName: nil, duration: 200, instrumental: true, plainLyrics: nil, syncedLyrics: nil), trackDuration: 200) == .none)
    #expect(LRCLIB.result(from: LRCLIBRecord(id: 1, trackName: "x", artistName: "y", albumName: nil, duration: 200, instrumental: false, plainLyrics: "solo parole", syncedLyrics: nil), trackDuration: 200) == .none)
    if case .synced(let lyrics) = LRCLIB.result(from: LRCLIBRecord(id: 1, trackName: "x", artistName: "y", albumName: nil, duration: 200, instrumental: false, plainLyrics: nil, syncedLyrics: "[00:01.00] una frase"), trackDuration: 200) {
        #expect(lyrics.lines.count == 1)
    } else { Issue.record("dovevano esserci i testi") }
}

@Test func lrclibJSONDecodes() throws {
    let json = #"{"id":7,"trackName":"Luce bianca","artistName":"Le Onde","albumName":"Notte","duration":200.0,"instrumental":false,"plainLyrics":"a\nb","syncedLyrics":"[00:01.00] a\n[00:03.00] b"}"#
    let record = try JSONDecoder().decode(LRCLIBRecord.self, from: Data(json.utf8))
    #expect(record.id == 7 && record.duration == 200)
    #expect(LRCLIB.result(from: record, trackDuration: nil) != .none)
}

// MARK: - Il passo delle righe vicine

@Test func aLineWithFewerSyllablesEndsEarlierThanItsNeighbours() {
    // quattro righe ogni quattro secondi: tre piene (dieci sillabe) e una corta (quattro), cantate allo stesso passo.
    // La corta non si stende fino alla riga dopo: finisce prima, e poi c'è il respiro
    let text = """
    [00:00.00] resta ancora qui con me stanotte
    [00:04.00] luce bianca sopra tutti i tetti
    [00:08.00] resta ancora
    [00:12.00] porta via la notte dentro me
    [00:16.00] resta ancora qui con me stanotte
    """
    let lines = LRC.parse(text, trackDuration: 20).lines
    let full = lines[1].end - lines[1].start, short = lines[2].end - lines[2].start
    #expect(full > 3.2)
    #expect(short < 2.2)
    // e l'ultima parola della riga corta comincia presto, non a ridosso della riga dopo
    #expect(lines[2].words[1].start < 9.2)
}

@Test func thePaceNeverSlowsALineDown() {
    let texts = ["resta", "ancora", "un", "poco"]
    for available in [0.8, 1.5, 3.0, 8.0, 20.0] {
        let plain = WordTiming.estimate(texts, start: 10, available: available)
        for pace in [0.11, 0.2, 0.3, 0.45] {
            let paced = WordTiming.estimate(texts, start: 10, available: available, pace: pace)
            #expect(paced[paced.count - 1].end <= plain[plain.count - 1].end + 1e-9)
            #expect(paced[0].start == 10)
        }
    }
}

@Test func thePaceComesFromTheTightLinesNearby() {
    // righe piene a 0,2 secondi per sillaba, e una con una pausa lunga dopo
    let lines: [(available: Double, weight: Double)] = [(2.0, 10), (2.0, 10), (9.0, 10), (2.0, 10), (2.2, 10)]
    let pace = WordTiming.pace(at: 2, lines: lines)!
    #expect(pace >= 0.19 && pace <= 0.23)
    // una riga sola: il suo tempo è tutto quello che si sa
    #expect(WordTiming.pace(at: 0, lines: [(3.0, 6)]) == 0.45)
    #expect(WordTiming.pace(at: 0, lines: []) == nil)
}

