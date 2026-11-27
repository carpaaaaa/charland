import Foundation
import Testing
@testable import CharlandCore

// Testi inventati, come negli altri test: nessun testo di canzoni vere.

/// Un file come quelli di lrc.red: tutto due spazi più a destra di LRCLIB, le parole due spazi più in là di `words:`,
/// le parole lunghe divise in sillabe (senza spazio in coda), un metadato dopo `lines:` che non è una riga.
private let redFile = """
version: '1.0'

metadata:
  title: "Luce bianca"
  artist: "Le Onde"
  duration_ms: 125000

lines:
  - text: "Resta ancora un minuto"
    start_ms: 1200
    end_ms: 3600
    words:
      - text: "Res"
        start_ms: 1200
        end_ms: 1400
      - text: "ta "
        start_ms: 1400
        end_ms: 1650
      - text: "ancora "
        start_ms: 1650
        end_ms: 2300
      - text: "un "
        start_ms: 2300
        end_ms: 2500
      - text: "minuto"
        start_ms: 2500
        end_ms: 3600
  - text: "Don't stop"
    start_ms: 8000
    end_ms: 9000
    words:
      - text: "Don't "
        start_ms: 8000
        end_ms: 8500
      - text: 'stop'
        start_ms: 8500
        end_ms: 9000
"""

@Test func lrcRedFileGivesWordsWithSyllablesJoined() throws {
    let lrc = try #require(LyricsFile.lrc(redFile))
    let lyrics = LRC.parse(lrc, trackDuration: 125)
    #expect(lyrics.wordTimingIsReal)
    #expect(lyrics.lines.count == 2)
    // «Res» + «ta» sono una parola sola, che parte dalla prima sillaba
    #expect(lyrics.lines[0].words.map(\.text) == ["Resta", "ancora", "un", "minuto"])
    #expect(zip(lyrics.lines[0].words.map(\.start), [1.2, 1.65, 2.3, 2.5]).allSatisfy { abs($0 - $1) < 0.006 })
    // la frase finisce dove lo dice il file, non alla riga dopo
    #expect(abs((lyrics.lines[0].closed ?? 0) - 3.6) < 0.006)
    #expect(lyrics.lines[1].words.map(\.text) == ["Don't", "stop"])
}

@Test func theLastPartOfALineIsAWordEvenWithoutASpace() throws {
    // «minuto» chiude la riga senza spazio: non si attacca a «Don't» della riga dopo
    let lrc = try #require(LyricsFile.lrc(redFile))
    #expect(lrc.contains(">minuto\n"))
}

@Test func aLineOnlyFileIsUsedOnlyWhenAsked() {
    let lines = """
    version: '1.0'
    lines:
      - text: "Luce bianca sopra i tetti"
        start_ms: 1000
        end_ms: 3000
      - text: "La città si spegne piano"
        start_ms: 4000
        end_ms: 6000
      - text: "Resta ancora un minuto qui"
        start_ms: 7000
        end_ms: 9000
    """
    #expect(LyricsFile.lrc(lines) == nil)
    let lrc = LyricsFile.lrc(lines, wordsRequired: false)
    #expect(lrc?.hasPrefix("[00:01.00] Luce bianca sopra i tetti") == true)
    let hit = LRCRed.Hit(isrc: "ITABC2600001", title: "Luce bianca", artist: "Le Onde", duration: 125)
    #expect(LRCRed.record(file: lines, hit: hit)?.words == false)
    #expect(LRCRed.record(file: redFile, hit: hit)?.words == true)
    #expect(LRCRed.record(file: "version: '1.0'\nlines:\n", hit: hit) == nil)
}

@Test func lrcRedSearchDecodes() throws {
    let json = """
    {"hits":[{"isrc":"ITABC2600001","title":"Luce bianca","artist":"Le Onde","album":"Tetti","year":2026,"duration":125.4,
    "cover":"https://lrc.red/s/ITABC2600001.webp","color":"#e9a615"}],"next":"p24"}
    """
    let hits = try #require(LRCRed.hits(Data(json.utf8)))
    #expect(hits == [LRCRed.Hit(isrc: "ITABC2600001", title: "Luce bianca", artist: "Le Onde", duration: 125.4)])
    #expect(LRCRed.lyricsfileURL(isrc: "ITABC2600001")?.absoluteString == "https://lrc.red/s/ITABC2600001.lyricsfile.yaml")
    // un codice che non è un ISRC non diventa un indirizzo
    #expect(LRCRed.lyricsfileURL(isrc: "../search") == nil)
}

@Test func theRightTrackOnLrcRed() {
    let hits = [
        LRCRed.Hit(isrc: "ITABC2600009", title: "Luce bianca (Acoustic)", artist: "Le Onde", duration: 125.2),
        LRCRed.Hit(isrc: "ITABC2600002", title: "Luce bianca", artist: "Le Onde, Mare", duration: 128.5),
        LRCRed.Hit(isrc: "ITABC2600001", title: "Luce bianca (feat. Mare)", artist: "Le Onde, Mare", duration: 125.6),
        LRCRed.Hit(isrc: "ITABC2600003", title: "Luce bianca", artist: "Altri", duration: 125),
    ]
    // titolo senza code, primo artista, durata entro 2 s: la versione acustica, l'altra edizione e l'altro artista no
    #expect(LRCRed.best(hits, title: "Luce bianca", artist: "Le Onde & Mare", duration: 125)?.isrc == "ITABC2600001")
    // un'edizione più lunga di 3 s ha i tempi spostati: meglio nessun testo da lì
    #expect(LRCRed.best([hits[1]], title: "Luce bianca", artist: "Le Onde", duration: 125) == nil)
    #expect(LRCRed.best(hits, title: "Mare d'inverno", artist: "Le Onde", duration: 125) == nil)
    #expect(LRCRed.searchURL(title: "Luce bianca (feat. Mare)", artist: "Le Onde & Mare")?.query == "q=Luce%20bianca%20Le%20Onde")
}

@Test func theLrclibLayoutStillReadsTheSame() throws {
    // il formato di LRCLIB (parole allo stesso rientro di `words:`, `plain:` dopo le righe) dà lo stesso risultato
    let lrclib = """
    version: '1.0'
    lines:
    - text: Resta ancora un minuto
      start_ms: 1200
      end_ms: 3600
      words:
      - text: 'Resta '
        start_ms: 1200
      - text: 'ancora '
        start_ms: 1650
      - text: 'un '
        start_ms: 2300
      - text: minuto
        start_ms: 2500
    - text: Don't stop
      start_ms: 8000
      end_ms: 9000
      words:
      - text: 'Don''t '
        start_ms: 8000
      - text: "stop"
        start_ms: 8500
    plain: |
      Resta ancora un minuto
      Don't stop
    """
    #expect(LyricsFile.lrc(lrclib) == LyricsFile.lrc(redFile))
}

/// Solo a mano, coi file veri di lrc.red raccolti fuori dal progetto (che qui non si mettono):
/// `CHARLAND_LRCRED_DIR=<cartella coi .yaml> CHARLAND_LRCRED_OUT=<file> swift test --filter lrcRedOnRealFiles`.
/// Per ogni file scrive le parole lette coi loro tempi, da confrontare con un'altra lettura.
@Test func lrcRedOnRealFiles() throws {
    let env = ProcessInfo.processInfo.environment
    guard let dir = env["CHARLAND_LRCRED_DIR"], let outPath = env["CHARLAND_LRCRED_OUT"] else { return }
    var out: [String: [[String: Double]]] = [:]
    for name in try FileManager.default.contentsOfDirectory(atPath: dir).sorted() where name.hasSuffix(".yaml") {
        let text = try String(contentsOfFile: dir + "/" + name, encoding: .utf8)
        guard let lrc = LyricsFile.lrc(text) else { out[name] = []; continue }
        let lyrics = LRC.parse(lrc, trackDuration: nil)
        out[name] = lyrics.lines.flatMap { $0.words.map { [$0.text: $0.start] } }
    }
    try JSONSerialization.data(withJSONObject: out, options: [.sortedKeys]).write(to: URL(fileURLWithPath: outPath))
}
