import Foundation
import Testing
@testable import CharlandCore

// Testi inventati, come negli altri test: nessun testo di canzoni vere.

private let words = ["luce bianca sopra i tetti", "la città si spegne piano", "resta ancora un minuto qui",
                     "corro dietro alle tue scarpe", "nel silenzio della sera", "dimmi dove vanno i treni"]

/// Una canzone inventata di `count` righe, una ogni 3,2 s da 5 s; il ritornello torna ogni sei righe.
private func song(_ count: Int = 36) -> [(Double, String)] {
    (0..<count).map { i -> (Double, String) in
        let time: Double = 5 + 3.2 * Double(i)
        let text: String = i % 6 == 0 ? "Luce bianca sopra i tetti" : words[i % words.count] + " \(i)"
        return (time, text)
    }
}

/// Un rumore fisso, diverso per ogni `seed`: due sincronizzazioni fatte a mano non coincidono mai al centesimo.
private func jitter(_ i: Int, _ seed: Int, _ amount: Double) -> Double {
    let x = sin(Double(i * 7919 + seed * 104_729)) * 43758.5453
    return (x - x.rounded(.down) - 0.5) * 2 * amount
}

private func lrc(_ lines: [(Double, String)]) -> String {
    lines.map { t, s in String(format: "[%02d:%05.2f] %@", Int(t) / 60, t - Double(Int(t) / 60 * 60), s) }.joined(separator: "\n")
}

private func record(_ id: Int, _ lines: [(Double, String)], duration: Double = 125) -> LRCLIBRecord {
    LRCLIBRecord(id: id, trackName: "Luce bianca", artistName: "Le Onde", duration: duration, syncedLyrics: lrc(lines))
}

/// Una sincronizzazione fatta da qualcun altro: stessi versi, tempi giusti a meno di `amount`.
private func other(_ seed: Int, amount: Double = 0.2, shift: Double = 0) -> [(Double, String)] {
    song().enumerated().map { i, l in (l.0 + jitter(i, seed, amount) + shift, l.1) }
}

/// La versione rotta: alcune righe spostate di 2-3,5 s, come «Start A Riot» su LRCLIB.
private func broken() -> [(Double, String)] {
    var s = song()
    for (i, d) in [(3, -2.5), (9, 2.0), (15, -2.4), (21, 2.6), (27, -2.2), (33, 3.0)] { s[i].0 += d }
    return s.sorted { $0.0 < $1.0 }
}

@Test func versionsGroupCopies() {
    var copy = song()
    copy = copy.enumerated().map { i, l in (l.0 + jitter(i, 9, 0.03), l.1) }
    var withBlank = lrc(song())
    withBlank += "\n[02:00.00] "
    let list = [record(1, song()), record(2, copy), LRCLIBRecord(id: 3, duration: 125, syncedLyrics: withBlank), record(4, other(5))]
    let fams = LRCVersions.families(list)
    #expect(fams.count == 2)
    #expect(fams[0].copies == 3)
}

@Test func versionsReplaceABrokenOneEvenIfMostCopied() {
    // la rotta ha sei copie, le due giuste una sola ciascuna: contano le sincronizzazioni, non le copie
    let copies = (10..<15).map { record($0, broken()) }
    let picked = LRCVersions.pick(primary: record(1, broken()), among: copies + [record(20, other(1)), record(21, other(2))])
    #expect(picked?.id == 20 || picked?.id == 21)
}

@Test func versionsKeepAGoodOne() {
    let picked = LRCVersions.pick(primary: record(1, other(7, amount: 0.15)), among: [record(20, other(1)), record(21, other(2)), record(22, broken())])
    #expect(picked?.id == 1)
}

@Test func versionsIgnoreAnotherEdition() {
    // le altre sono un'altra edizione (intro più lunga di 8,46 s): non votano, anche se la data ha qualche difetto
    let picked = LRCVersions.pick(primary: record(1, broken()), among: [record(20, other(1, shift: 8.46)), record(21, other(2, shift: 8.46))])
    #expect(picked?.id == 1)
}

@Test func versionsKeepTheOnlyOne() {
    #expect(LRCVersions.pick(primary: record(1, broken()), among: [])?.id == 1)
    #expect(LRCVersions.pick(primary: nil, among: [record(2, song())]) == nil)
}

@Test func versionsRepairLinesButKeepThePlaceInTheSong() {
    // la sana sta tutta 0,3 s dopo: prende il posto della rotta riga per riga, ma resta dove stava la rotta
    let picked = LRCVersions.pick(primary: record(1, broken()), among: [record(20, other(1, amount: 0.05, shift: 0.3)), record(21, other(2, amount: 0.05, shift: 0.3))])
    let lines = LRC.parse(picked?.syncedLyrics ?? "").lines
    let truth = song()
    #expect(lines.count == truth.count)
    // le righe spostate della rotta sono tornate al loro posto, e nessuna è finita 0,3 s dopo
    #expect(zip(lines, truth).allSatisfy { abs($0.start - $1.0) < 0.12 })
}

@Test func shiftedMovesEveryTime() {
    #expect(LRCVersions.shifted("[00:01.00] a <00:01.50>b\n[01:00.25] c", by: -0.5) == "[00:00.50] a <00:01.00>b\n[00:59.75] c")
    #expect(LRCVersions.shifted("[00:00.20] a", by: -0.5) == "[00:00.00] a")
}

@Test func versionsSpotLinesThatCannotBeSung() {
    let rows = LRCVersions.rows("[00:10.00] corro dietro alle tue scarpe nella sera\n[00:10.40] la città si spegne\n[00:14.00] fine")
    #expect(LRCVersions.impossible(rows) == 1)
    // le righe a tempo con le parole <mm:ss.xx> si leggono senza i tempi dentro
    #expect(LRCVersions.rows("[00:01.00] <00:01.00>luce <00:01.40>bianca")[0].key == "lucebianca")
}

@Test func versionsChorusPairsWithItsOwnRepeat() {
    // la seconda versione non ha il primo ritornello: il secondo non deve appaiarsi col primo
    let a = LRCVersions.rows(lrc(song()))
    let b = LRCVersions.rows(lrc(Array(song().dropFirst())))
    let pairs = LRCVersions.match(a, b)
    #expect(pairs.allSatisfy { abs(a[$0.0].time - b[$0.1].time) < 0.01 })
}

@Test func lrclibSearchesTheFirstArtistToo() {
    #expect(LRCLIB.firstArtist("Duckwrth & Shaboozey") == "Duckwrth")
    #expect(LRCLIB.firstArtist("Carl Brave x Franco126") == "Carl Brave")
    #expect(LRCLIB.firstArtist("Hugel feat. Taio Cruz") == "Hugel")
    #expect(LRCLIB.firstArtist("Coez") == "Coez")
    #expect(LRCLIB.searchURLs(title: "Luce bianca", artist: "Le Onde").count == 1)
    let urls = LRCLIB.searchURLs(title: "Luce bianca", artist: "Le Onde & Gli Altri")
    #expect(urls.count == 2)
    #expect(urls[1].absoluteString.contains("artist_name=Le%20Onde") && !urls[1].absoluteString.contains("Altri"))
}


private let wordFile = """
version: '1.0'
metadata:
  title: Luce bianca
  artist: Le Onde
  duration_ms: 125000
lines:
- text: Resta ancora un minuto qui
  start_ms: 1200
  end_ms: 3600
  words:
  - text: 'Resta '
    start_ms: 1200
  - text: 'ancora '
    start_ms: 1650
  - text: 'un '
    start_ms: 2300
  - text: 'minuto '
    start_ms: 2500
  - text: qui
    start_ms: 3100
- text: Don't stop
  start_ms: 8000
  end_ms: 9000
  words:
  - text: 'Don''t '
    start_ms: 8000
  - text: "stop"
    start_ms: 8500
plain: |
  Resta ancora un minuto qui
  Don't stop
"""

/// Un file delle parole coi tempi della versione rotta (righe spostate di 2-3,5 s), parola per parola.
private func brokenWordFile() -> String {
    var out = "version: '1.0'\nlines:\n"
    for (t, text) in broken() {
        out += "- text: \(text)\n  start_ms: \(Int(t * 1000))\n  end_ms: \(Int(t * 1000) + 1500)\n  words:\n"
        for (k, w) in text.split(separator: " ").enumerated() { out += "  - text: '\(w) '\n    start_ms: \(Int(t * 1000) + k * 250)\n" }
    }
    return out + "plain: |\n  x\n"
}

@Test func lyricsFileGivesRealWordTimes() throws {
    let lrc = try #require(LyricsFile.lrc(wordFile))
    let lyrics = LRC.parse(lrc, trackDuration: 125)
    #expect(lyrics.wordTimingIsReal)
    #expect(lyrics.lines.count == 2)
    #expect(lyrics.lines[0].words.map(\.text) == ["Resta", "ancora", "un", "minuto", "qui"])
    #expect(zip(lyrics.lines[0].words.map(\.start), [1.2, 1.65, 2.3, 2.5, 3.1]).allSatisfy { abs($0 - $1) < 0.006 })
    // la frase finisce dove lo dice il file, non alla riga dopo
    #expect(abs((lyrics.lines[0].closed ?? 0) - 3.6) < 0.006)
    #expect(abs(lyrics.lines[0].words.last!.end - 3.6) < 0.006)
    #expect(lyrics.lines[1].words.map(\.text) == ["Don't", "stop"])
}

@Test func lyricsFileWithoutWordsIsNotUsed() {
    #expect(LyricsFile.lrc("version: '1.0'\nlines:\n- text: Luce bianca\n  start_ms: 1000\n  end_ms: 2000\nplain: |\n  Luce bianca") == nil)
}

@Test func chooseStartsFromRealWordTimes() {
    var exact = record(1, song())
    exact.lyricsfile = nil
    var worded = record(30, other(3, amount: 0.05))
    worded.lyricsfile = wordFile
    let picked = LRCVersions.choose(primary: exact, others: [worded, record(20, other(1)), record(21, other(2))], duration: 125)
    #expect(picked?.id == 30)
    #expect(picked?.syncedLyrics?.contains("<00:01.65>ancora") == true)
    // un file delle parole rotto non si usa, e non sposta niente: resta la versione data
    var brokenWords = record(31, broken())
    brokenWords.lyricsfile = brokenWordFile()
    #expect(LRCVersions.choose(primary: exact, others: [brokenWords, record(20, other(1)), record(21, other(2))], duration: 125)?.id == 1)
    // un brano con le parole a tempo ma di un'altra durata (un'altra edizione) non si usa
    worded.duration = 140
    #expect(LRCVersions.choose(primary: exact, others: [worded], duration: 125)?.id == 1)
}

/// Solo a mano, coi testi veri raccolti fuori dal progetto (che qui non si mettono):
/// `CHARLAND_LRCLIB_DIR=<cartella con cache/, lrclib/, tutti/> CHARLAND_LRCLIB_OUT=<file> swift test --filter versionsOnRealLibrary`.
/// Per ogni brano scrive se la versione data si cambierebbe e con quale voce.
@Test func versionsOnRealLibrary() throws {
    let env = ProcessInfo.processInfo.environment
    guard let dir = env["CHARLAND_LRCLIB_DIR"], let outPath = env["CHARLAND_LRCLIB_OUT"] else { return }
    struct Saved: Decodable { var synced: String?; var duration: Double? }
    let fm = FileManager.default
    var out: [String] = []
    for name in try fm.contentsOfDirectory(atPath: dir + "/cache").sorted() where name.hasSuffix(".json") {
        let key = String(name.dropLast(5))
        guard let saved = try? JSONDecoder().decode(Saved.self, from: Data(contentsOf: URL(fileURLWithPath: dir + "/cache/" + name))),
              let synced = saved.synced, !synced.isEmpty else { continue }
        let listPath = [dir + "/lrclib/" + name, dir + "/tutti/" + name].first { fm.fileExists(atPath: $0) }
        guard let listPath, let list = try? JSONDecoder().decode([LRCLIBRecord].self, from: Data(contentsOf: URL(fileURLWithPath: listPath))) else { continue }
        let want = Double(key.split(separator: "_").last ?? "") ?? saved.duration ?? 0
        let near = list.filter { r in r.duration.map { abs($0 - want) <= 4 } ?? true }
        let primary = LRCLIBRecord(duration: saved.duration, syncedLyrics: synced)
        let began = Date()
        let picked = LRCVersions.choose(primary: primary, others: near, duration: want)
        let ms = Date().timeIntervalSince(began) * 1000
        let fams = LRCVersions.families([primary] + near).count
        let changed = picked?.syncedLyrics != synced
        if let text = picked?.syncedLyrics {
            try? fm.createDirectory(atPath: outPath + ".lrc", withIntermediateDirectories: true)
            try? text.write(toFile: outPath + ".lrc/" + key + ".lrc", atomically: true, encoding: .utf8)
        }
        out.append("\(key)\t\(changed ? (text(picked).contains("<") ? "PAROLE" : "CAMBIA") : "resta")\t\(changed ? String(picked?.id ?? -1) : "-")\t\(fams)\t\(String(format: "%.0f", ms))")
    }
    try out.joined(separator: "\n").write(toFile: outPath, atomically: true, encoding: .utf8)
}

private func text(_ r: LRCLIBRecord?) -> String { r?.syncedLyrics ?? "" }
