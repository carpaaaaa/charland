import Foundation

/// I testi delle canzoni per il blocco schermo: righe a tempo, parole a tempo.
///
/// La fonte (LRCLIB) dà quasi sempre il tempo riga per riga. Il tempo di ogni parola lo stimiamo noi dal peso
/// delle sillabe, e lo diciamo (`wordTimingIsReal`), così chi disegna può essere più morbido quando è una stima.

public struct TimedWord: Sendable, Equatable {
    public var text: String
    public var start: Double
    public var duration: Double
    public var end: Double { start + duration }

    public init(text: String, start: Double, duration: Double) {
        self.text = text; self.start = start; self.duration = duration
    }
}

public struct TimedLine: Sendable, Equatable {
    public var start: Double
    public var end: Double
    public var words: [TimedWord]
    /// Quando la fonte dice che la frase è finita (in LRC una riga vuota col suo tempo subito dopo), se lo dice.
    public var closed: Double?
    public var text: String { words.map(\.text).joined(separator: " ") }

    public init(start: Double, end: Double, words: [TimedWord]) {
        self.start = start; self.end = end; self.words = words
    }
}

/// Una riga della colonna: una frase, oppure una pausa strumentale lunga (il filo di luce che si riempie).
public enum LyricRow: Sendable, Equatable {
    case line(TimedLine)
    case pause(start: Double, end: Double)

    public var start: Double {
        switch self { case .line(let l): l.start; case .pause(let s, _): s }
    }
}

public struct Lyrics: Sendable, Equatable {
    public var lines: [TimedLine]
    /// Vero se il tempo delle parole viene dalla fonte; falso se l'abbiamo stimato dal tempo della riga.
    public var wordTimingIsReal: Bool
    public var isEmpty: Bool { lines.isEmpty }
    /// Dove comincia ogni strofa (indici in `lines`), quando la fonte lo dice: LRCLIB lo dice nel testo senza tempi,
    /// con le righe vuote. Vuoto se non si sa: allora le strofe si deducono dai silenzi.
    public var stanzaStarts: [Int] = []

    public init(lines: [TimedLine], wordTimingIsReal: Bool) {
        self.lines = lines; self.wordTimingIsReal = wordTimingIsReal
    }

    /// Le strofe del testo, come intervalli di righe: quelle dette dalla fonte, se ci sono; se no un silenzio più
    /// lungo del solito fra una riga e l'altra apre una strofa nuova. Una strofa troppo lunga per stare sullo schermo
    /// si divide al suo silenzio più lungo.
    public func stanzas(maxLines: Int = 6, maxWords: Int = 30) -> [Range<Int>] {
        guard !lines.isEmpty else { return [] }
        let gaps = (0..<(lines.count - 1)).map { max(0, lines[$0 + 1].start - lines[$0].end) }
        var cuts: Set<Int> = [0]
        let known = stanzaStarts.filter { $0 > 0 && $0 < lines.count }
        cuts.formUnion(known)
        if known.isEmpty, !gaps.isEmpty {
            let usual = gaps.sorted()[gaps.count / 2]
            let wide = max(1.8, usual * 2.4 + 0.4)
            for (i, gap) in gaps.enumerated() where gap >= wide { cuts.insert(i + 1) }
        }
        // un silenzio davvero lungo divide sempre, anche dentro una strofa della fonte
        for (i, gap) in gaps.enumerated() where gap >= Self.longPause + 1 { cuts.insert(i + 1) }
        let edges = cuts.sorted() + [lines.count]
        var queue = (0..<(edges.count - 1)).map { edges[$0]..<edges[$0 + 1] }
        var out: [Range<Int>] = []
        while !queue.isEmpty {
            let range = queue.removeFirst()
            let words = range.reduce(0) { $0 + lines[$1].words.count }
            guard range.count > 1, range.count > maxLines || words > maxWords else { out.append(range); continue }
            // il taglio migliore: un silenzio lungo, e non troppo vicino a un bordo
            var best = range.lowerBound + range.count / 2, bestScore = -1.0
            for i in (range.lowerBound + 1)..<range.upperBound {
                let balance = 1 - abs(Double(i - range.lowerBound) / Double(range.count) - 0.5)
                let score = (gaps[i - 1] + 0.3) * balance
                if score > bestScore { bestScore = score; best = i }
            }
            queue.insert(best..<range.upperBound, at: 0)
            queue.insert(range.lowerBound..<best, at: 0)
        }
        return out
    }

    /// Una pausa conta come riga solo se è lunga: sotto questa soglia la frase cantata resta accesa.
    public static let longPause = 3.2
    /// La pausa comincia un attimo dopo la fine della frase e finisce un attimo prima della prossima.
    static let pauseLead = 1.0, pauseTail = 0.3

    /// Le righe da mostrare, con le pause lunghe in mezzo (anche prima della prima frase).
    public func rows(trackDuration: Double? = nil) -> [LyricRow] {
        var out: [LyricRow] = []
        if let first = lines.first, first.start > Self.longPause + Self.pauseTail {
            out.append(.pause(start: 0, end: first.start - Self.pauseTail))
        }
        for (i, line) in lines.enumerated() {
            out.append(.line(line))
            let next = i + 1 < lines.count ? lines[i + 1].start : trackDuration
            // la fine della frase: quella detta dalla fonte, se la dice; se no una stima prudente
            let end = wordTimingIsReal ? line.end : max(line.end, line.closed ?? Self.sungEnd(line))
            if let next, next - end > Self.longPause {
                out.append(.pause(start: end + Self.pauseLead, end: next - Self.pauseTail))
            }
        }
        return out
    }

    /// Quanto dura, a orecchio, una sillaba cantata piano.
    static let slowSyllable = 0.7

    /// Fin dove si può star certi che una frase coi tempi stimati sia finita. La fine stimata delle parole arriva spesso
    /// troppo presto, perché la stima non sa quando il cantante tiene le note: una pausa che partiva da lì spegneva la
    /// riga mentre la si cantava ancora (su 79 canzoni coi tempi veri di JamendoLyrics, il 51% delle pause partiva prima
    /// della fine della frase, di un secondo e mezzo a metà). Si prende il più tardi fra la fine stimata e un canto
    /// lento, 0,7 secondi per sillaba: lì le pause partite presto scendono al 19%, e restano mostrate tre pause vere su
    /// quattro. Se dopo non resta una pausa lunga, la riga resta accesa fino alla prossima.
    static func sungEnd(_ line: TimedLine) -> Double {
        let weight = line.words.reduce(0) { $0 + WordTiming.weight($1.text) }
        return max(line.end, line.start + weight * slowSyllable)
    }

    /// L'indice della riga in corso a un certo istante (−1 prima di tutto). `lead` la fa partire un filo prima.
    public static func index(of rows: [LyricRow], at time: Double, lead: Double = 0.12) -> Int {
        var index = -1
        for (i, row) in rows.enumerated() {
            let start: Double
            switch row { case .line(let l): start = l.start - lead; case .pause(let s, _): start = s }
            if time >= start { index = i } else { break }
        }
        return index
    }
}

public enum LRC {
    /// Legge un testo in formato LRC (`[mm:ss.xx] frase`, anche con più tempi sulla stessa riga e con i tempi
    /// delle parole `<mm:ss.xx>`). Le righe vuote col tempo sono il segno di una pausa: chiudono la frase prima.
    public static func parse(_ text: String, trackDuration: Double? = nil) -> Lyrics {
        struct Entry { var time: Double; var body: String }
        var entries: [Entry] = []
        for raw in text.split(whereSeparator: \.isNewline) {
            var rest = Substring(raw).drop(while: { $0 == " " || $0 == "\t" })
            var times: [Double] = []
            while let (time, after) = leadingTag(rest, open: "[", close: "]") { times.append(time); rest = after.drop(while: { $0 == " " }) }
            guard !times.isEmpty else { continue }
            let body = rest.trimmingCharacters(in: .whitespaces)
            for t in times { entries.append(Entry(time: t, body: body)) }
        }
        entries.sort { $0.time < $1.time }

        // quanto tempo ha ogni riga cantata e quanto pesa (in sillabe): serve a capire a che passo si canta lì attorno
        var room: [Int: Int] = [:], measures: [(available: Double, weight: Double)] = []
        for (i, entry) in entries.enumerated() where !entry.body.isEmpty {
            let next = i + 1 < entries.count ? entries[i + 1].time : (trackDuration.map { max($0, entry.time + 1) } ?? entry.time + 5)
            let texts = entry.body.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            room[i] = measures.count
            measures.append((max(0.3, next - entry.time), texts.reduce(0) { $0 + WordTiming.weight($1) }))
        }

        var lines: [TimedLine] = []
        var real = false, estimated = false
        for (i, entry) in entries.enumerated() where !entry.body.isEmpty {
            let next = i + 1 < entries.count ? entries[i + 1].time : (trackDuration.map { max($0, entry.time + 1) } ?? entry.time + 5)
            let available = max(0.3, next - entry.time)
            if let words = taggedWords(entry.body, lineStart: entry.time, lineEnd: entry.time + available), !words.isEmpty {
                real = true
                lines.append(TimedLine(start: entry.time, end: words[words.count - 1].end, words: words))
            } else {
                let texts = entry.body.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
                guard !texts.isEmpty else { continue }
                estimated = true
                let words = WordTiming.estimate(texts, start: entry.time, available: available, pace: room[i].flatMap { WordTiming.pace(at: $0, lines: measures) })
                lines.append(TimedLine(start: entry.time, end: words[words.count - 1].end, words: words))
            }
            if i + 1 < entries.count, entries[i + 1].body.isEmpty { lines[lines.count - 1].closed = entries[i + 1].time }
        }
        return Lyrics(lines: lines, wordTimingIsReal: real && !estimated)
    }

    /// Un tempo fra due segni in testa alla stringa: `[01:23.45]` o `<01:23.45>`. Le etichette come `[ar:Nome]` non lo sono.
    static func leadingTag(_ s: Substring, open: Character, close: Character) -> (Double, Substring)? {
        guard s.first == open, let end = s.firstIndex(of: close) else { return nil }
        let inside = s[s.index(after: s.startIndex)..<end]
        guard let time = seconds(inside) else { return nil }
        return (time, s[s.index(after: end)...])
    }

    /// `mm:ss`, `mm:ss.xx`, `mm:ss.xxx`, `mm:ss:xx`.
    static func seconds(_ s: Substring) -> Double? {
        let parts = s.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2 || parts.count == 3, let minutes = Int(parts[0]), minutes >= 0 else { return nil }
        if parts.count == 3 {
            guard let sec = Int(parts[1]), let frac = Int(parts[2]), sec >= 0, frac >= 0 else { return nil }
            return Double(minutes) * 60 + Double(sec) + Double(frac) / pow(10, Double(parts[2].count))
        }
        guard let sec = Double(parts[1]), sec >= 0, parts[1].allSatisfy({ $0.isNumber || $0 == "." }) else { return nil }
        return Double(minutes) * 60 + sec
    }

    /// Le parole coi loro tempi, se la riga li porta (`<00:12.30>parola <00:12.80>parola`).
    static func taggedWords(_ body: String, lineStart: Double, lineEnd: Double) -> [TimedWord]? {
        guard body.contains("<") else { return nil }
        var pieces: [(time: Double, text: String)] = []
        var rest = Substring(body)
        var pending = lineStart
        var buffer = ""
        var found = false
        while !rest.isEmpty {
            if rest.first == "<", let (time, after) = leadingTag(rest, open: "<", close: ">") {
                if !buffer.trimmingCharacters(in: .whitespaces).isEmpty { pieces.append((pending, buffer.trimmingCharacters(in: .whitespaces))) }
                buffer = ""; pending = time; rest = after; found = true
            } else { buffer.append(rest.removeFirst()) }
        }
        if !buffer.trimmingCharacters(in: .whitespaces).isEmpty { pieces.append((pending, buffer.trimmingCharacters(in: .whitespaces))) }
        guard found, !pieces.isEmpty else { return nil }
        var words: [TimedWord] = []
        for (i, piece) in pieces.enumerated() {
            let end = i + 1 < pieces.count ? pieces[i + 1].time : min(lineEnd, piece.time + 1.6)
            // un pezzo può contenere più parole: si dividono il suo tempo secondo il peso
            let texts = piece.text.split(separator: " ").map(String.init)
            words += WordTiming.spread(texts, start: piece.time, duration: max(0.08, end - piece.time), hold: i + 1 == pieces.count)
        }
        return words
    }
}

public enum WordTiming {
    /// Quanto dura, a orecchio, una sillaba cantata.
    static let syllable = 0.27
    /// Quando alla riga resta molto più tempo di quanto serve per cantarla, la frase finisce prima e il resto è pausa.
    static let stretch = 1.4

    /// Stima il tempo di ogni parola dentro una riga di cui si sa solo l'inizio e quanto tempo ha a disposizione.
    /// - Parameter pace: quanto dura una sillaba nelle righe lì attorno (`pace(at:lines:)`), se si sa. Una riga con
    ///   meno sillabe delle vicine nello stesso tempo non le canta più piano: finisce prima e poi c'è il respiro.
    ///   Senza questo le sue parole venivano stese fino alla riga dopo e arrivavano in ritardo (carpa, 18 novembre
    ///   2026: «a volte c'è un po' di delay con il testo»). Non rallenta mai rispetto alla stima senza.
    public static func estimate(_ texts: [String], start: Double, available: Double, pace: Double? = nil) -> [TimedWord] {
        let weight = texts.reduce(0) { $0 + Self.weight($1) }
        let natural = weight * syllable + 0.2
        let room = max(0.3, available - 0.12)
        var duration = min(room, max(min(room, natural), min(room, natural * stretch)))
        if let pace { duration = min(duration, max(0.3, weight * pace * 1.05 + 0.1)) }
        return spread(texts, start: start, duration: duration, hold: true)
    }

    /// A che passo si canta attorno a una riga, in secondi per sillaba: fra le righe vicine (tre prima, tre dopo, lei
    /// compresa) si guarda quanto tempo hanno per sillaba, e si prende un valore basso (il terzo più stretto su dieci):
    /// le righe più piene sono quelle cantate senza pause, e dicono il passo vero. Niente se non ci sono righe.
    public static func pace(at index: Int, lines: [(available: Double, weight: Double)]) -> Double? {
        func ratios(_ range: Range<Int>) -> [Double] {
            range.compactMap { lines[$0].weight >= 2 ? lines[$0].available / lines[$0].weight : nil }.sorted()
        }
        guard lines.indices.contains(index) else { return nil }
        var near = ratios(max(0, index - 3)..<min(lines.count, index + 4))
        // poche righe attorno: si guarda tutta la canzone
        if near.count < 3 { near = ratios(0..<lines.count) }
        guard !near.isEmpty else { return nil }
        return min(0.45, max(0.11, near[Int(Double(near.count - 1) * 0.3)]))
    }

    /// Divide una durata fra le parole secondo il peso; l'ultima tiene la nota un po' di più.
    static func spread(_ texts: [String], start: Double, duration: Double, hold: Bool) -> [TimedWord] {
        guard !texts.isEmpty else { return [] }
        var weights = texts.map(weight)
        if hold { weights[weights.count - 1] *= 1.3 }
        let total = weights.reduce(0, +)
        var t = start
        return zip(texts, weights).map { text, w in
            let d = duration * w / total
            defer { t += d }
            return TimedWord(text: text, start: t, duration: d)
        }
    }

    /// Il peso di una parola: le sillabe stimate (gruppi di vocali), almeno una, più un respiro dopo la punteggiatura.
    public static func weight(_ word: String) -> Double {
        let vowels: Set<Character> = ["a", "e", "i", "o", "u", "y", "à", "á", "â", "ä", "è", "é", "ê", "ë", "ì", "í", "î", "ï", "ò", "ó", "ô", "ö", "ù", "ú", "û", "ü"]
        var groups = 0
        var inVowels = false
        var letters = 0
        for ch in word.lowercased() {
            if ch.isLetter || ch.isNumber { letters += 1 }
            let isVowel = vowels.contains(ch)
            if isVowel && !inVowels { groups += 1 }
            inVowels = isVowel
        }
        // lingue senza vocali latine (o sigle): si va a lettere
        var w = groups > 0 ? Double(groups) : max(1, Double(letters) / 2.5)
        if letters > 0, let last = word.last, ",;:.!?…".contains(last) { w += 0.35 }
        return max(1, w)
    }
}

// MARK: - LRCLIB

/// Una risposta di LRCLIB (lrclib.net): la fonte libera dei testi a tempo.
public struct LRCLIBRecord: Decodable, Sendable, Equatable {
    public var id: Int?
    public var trackName: String?
    public var artistName: String?
    public var albumName: String?
    public var duration: Double?
    public var instrumental: Bool?
    public var plainLyrics: String?
    public var syncedLyrics: String?
    /// Il testo con i tempi veri di ogni parola, quando LRCLIB li ha (`LyricsFile`). Nuovo su LRCLIB a novembre 2026.
    public var lyricsfile: String?

    public init(id: Int? = nil, trackName: String? = nil, artistName: String? = nil, albumName: String? = nil, duration: Double? = nil,
                instrumental: Bool? = nil, plainLyrics: String? = nil, syncedLyrics: String? = nil, lyricsfile: String? = nil) {
        self.id = id; self.trackName = trackName; self.artistName = artistName; self.albumName = albumName
        self.duration = duration; self.instrumental = instrumental; self.plainLyrics = plainLyrics; self.syncedLyrics = syncedLyrics
        self.lyricsfile = lyricsfile
    }

    /// Lo stesso brano col testo che si userà: quello coi tempi delle parole, se c'è (`LyricsFile.lrc`), se no quello riga per riga.
    public var withWordTimes: LRCLIBRecord? {
        guard instrumental != true, let file = lyricsfile, let lrc = LyricsFile.lrc(file) else { return nil }
        var copy = self
        copy.syncedLyrics = lrc
        copy.lyricsfile = nil
        return copy
    }
}

/// Il campo `lyricsfile` di LRCLIB: per ogni riga l'inizio e la fine, e l'inizio di ogni parola. È un piccolo YAML
/// sempre uguale (`lines:`, poi `- text:`, `start_ms:`, `end_ms:`, `words:` con `- text:` e `start_ms:`), letto qui
/// riga per riga senza una libreria.
///
/// Perché conta: senza, i tempi delle parole dentro la riga Charland li stima, e in Dynamic, dove una parola compare
/// solo quando arriva, la stima si vede. Provato il 19 novembre 2026 contro l'audio delle anteprime di 18 brani di carpa
/// (con «I Really Want to Stay at Your House» che carpa trovava «tutto off sync»): errore mediano delle parole da 0,21 s
/// con la stima a 0,075 s coi tempi veri, parole entro 0,3 s dal 66% all'86%, 13 brani meglio e 3 peggio. Ancorati al
/// punto della versione riga per riga andavano peggio (0,15 s, 9 meglio e 6 peggio): si usano così come sono.
public enum LyricsFile {
    /// Il testo in LRC con le parole a tempo (`[mm:ss.xx] <mm:ss.xx>parola <mm:ss.xx>parola`), più una riga vuota alla fine
    /// detta di ogni frase quando dopo c'è silenzio. `nil` se non ci sono parole a tempo.
    public static func lrc(_ file: String) -> String? {
        struct Line { var start: Double?; var end: Double?; var text = ""; var words: [(String, Double?)] = [] }
        var lines: [Line] = []
        var inWords = false
        for raw in file.split(separator: "\n", omittingEmptySubsequences: false) {
            let row = String(raw)
            if !row.hasPrefix(" "), !row.hasPrefix("-"), row.contains(":"), !lines.isEmpty, !row.hasPrefix("lines:") { break }
            if row.hasPrefix("- text:") { lines.append(Line(text: value(row, "- text:"))); inWords = false; continue }
            guard !lines.isEmpty else { continue }
            if row.hasPrefix("  words:") { inWords = true; continue }
            if row.hasPrefix("  - text:") { lines[lines.count - 1].words.append((value(row, "  - text:"), nil)); continue }
            if row.hasPrefix("    start_ms:"), inWords, !lines[lines.count - 1].words.isEmpty {
                lines[lines.count - 1].words[lines[lines.count - 1].words.count - 1].1 = millis(row, "    start_ms:"); continue
            }
            if row.hasPrefix("  start_ms:"), !inWords { lines[lines.count - 1].start = millis(row, "  start_ms:"); continue }
            if row.hasPrefix("  end_ms:"), !inWords { lines[lines.count - 1].end = millis(row, "  end_ms:"); continue }
        }
        var out: [String] = [], timed = 0
        for (i, line) in lines.enumerated() {
            guard let start = line.start else { continue }
            var body = ""
            for (text, at) in line.words {
                let clean = text.filter { !"<>[]".contains($0) }.trimmingCharacters(in: .whitespaces)
                guard !clean.isEmpty else { continue }
                if let at { body += (body.isEmpty ? "" : " ") + "<\(stamp(at))>" + clean; timed += 1 }
                else { body += (body.isEmpty ? "" : " ") + clean }
            }
            if body.isEmpty { body = line.text.filter { !"<>[]".contains($0) } }
            guard !body.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            out.append("[\(stamp(start))] " + body)
            // la fine detta della frase, se prima della riga dopo resta silenzio
            let next = lines[(i + 1)...].first { $0.start != nil }?.start ?? .infinity
            if let end = line.end, end > start, next - end > 0.3 { out.append("[\(stamp(end))]") }
        }
        return timed >= 3 ? out.joined(separator: "\n") : nil
    }

    private static func value(_ row: String, _ key: String) -> String {
        var v = String(row.dropFirst(key.count)).trimmingCharacters(in: .whitespaces)
        if v.count >= 2, v.hasPrefix("'"), v.hasSuffix("'") {
            v = String(v.dropFirst().dropLast()).replacingOccurrences(of: "''", with: "'")
        } else if v.count >= 2, v.hasPrefix("\""), v.hasSuffix("\""),
                  let data = v.data(using: .utf8), let s = try? JSONDecoder().decode(String.self, from: data) {
            v = s
        }
        return v
    }

    private static func millis(_ row: String, _ key: String) -> Double? {
        Double(row.dropFirst(key.count).trimmingCharacters(in: .whitespaces)).map { $0 / 1000 }
    }

    static func stamp(_ t: Double) -> String {
        let cs = Int((max(0, t) * 100).rounded())
        return String(format: "%02d:%02d.%02d", cs / 6000, cs / 100 % 60, cs % 100)
    }
}

public enum LyricsResult: Sendable, Equatable {
    case synced(Lyrics)
    /// Brano strumentale, o testo che esiste ma senza tempi: sul blocco si mostra la copertina al centro.
    case none
}

public enum LRCLIB {
    public static let host = "https://lrclib.net"

    /// La domanda precisa: titolo, artista, album e durata (LRCLIB vuole la durata entro due secondi).
    public static func getURL(title: String, artist: String, album: String?, duration: Double?) -> URL? {
        var c = URLComponents(string: host + "/api/get")
        var items = [URLQueryItem(name: "track_name", value: title), URLQueryItem(name: "artist_name", value: artist)]
        if let album, !album.isEmpty { items.append(URLQueryItem(name: "album_name", value: album)) }
        if let duration, duration > 0 { items.append(URLQueryItem(name: "duration", value: String(Int(duration.rounded())))) }
        c?.queryItems = items
        return c?.url
    }

    /// La ricerca larga, quando la domanda precisa non trova niente (album diverso, durata diversa).
    public static func searchURL(title: String, artist: String) -> URL? {
        var c = URLComponents(string: host + "/api/search")
        c?.queryItems = [URLQueryItem(name: "track_name", value: clean(title)), URLQueryItem(name: "artist_name", value: artist)]
        return c?.url
    }

    /// Le ricerche larghe da fare: col nome dell'artista com'è e, se sono più artisti («A & B», «A feat. B»), anche col
    /// primo da solo. Una ricerca dà al massimo 20 voci, e le versioni giuste di un brano possono stare sotto un nome solo
    /// (con «Start A Riot» di «Duckwrth & Shaboozey» una sincronizzazione giusta era sotto «Duckwrth», un'altra sotto «Shaboozey»).
    public static func searchURLs(title: String, artist: String) -> [URL] {
        var urls = [searchURL(title: title, artist: artist)]
        let first = firstArtist(artist)
        if !first.isEmpty, key(first) != key(artist) { urls.append(searchURL(title: title, artist: first)) }
        return urls.compactMap { $0 }
    }

    /// Il primo nome di un artista composto: «Duckwrth & Shaboozey» → «Duckwrth».
    public static func firstArtist(_ artist: String) -> String {
        let parts = artist.replacingOccurrences(of: #"\s*(,|&|\+|;|/|\bx\b|\bfeat\.?|\bft\.?|\bwith\b|\band\b|\be\b)\s*"#, with: "\u{1}",
                                                options: [.regularExpression, .caseInsensitive])
        return parts.split(separator: "\u{1}").first.map { $0.trimmingCharacters(in: .whitespaces) } ?? artist
    }

    /// Le voci di una ricerca che sono davvero il brano: hanno i tempi, il titolo è lo stesso, l'artista anche (o lo
    /// contiene), la durata entro `tolerance`.
    public static func candidates(_ records: [LRCLIBRecord], title: String, artist: String, duration: Double?, tolerance: Double = 4) -> [LRCLIBRecord] {
        let wantTitle = key(title), wantArtist = key(artist), wantFirst = key(firstArtist(artist))
        return records.filter { r in
            guard let synced = r.syncedLyrics, !synced.isEmpty, key(r.trackName ?? "") == wantTitle else { return false }
            let a = key(r.artistName ?? "")
            guard !a.isEmpty, a == wantArtist || a.contains(wantArtist) || wantArtist.contains(a) || (!wantFirst.isEmpty && a.contains(wantFirst)) else { return false }
            if let duration, duration > 0, let d = r.duration { return abs(d - duration) <= tolerance }
            return true
        }
    }

    /// Il risultato migliore di una ricerca: ha i tempi, il titolo è lo stesso e la durata è la più vicina (entro `tolerance`).
    public static func best(_ records: [LRCLIBRecord], title: String, artist: String, duration: Double?, tolerance: Double = 4) -> LRCLIBRecord? {
        let candidates = candidates(records, title: title, artist: artist, duration: duration, tolerance: tolerance)
        guard let duration, duration > 0 else { return candidates.first }
        return candidates.min { abs(($0.duration ?? .infinity) - duration) < abs(($1.duration ?? .infinity) - duration) }
    }

    public static func result(from record: LRCLIBRecord?, trackDuration: Double?) -> LyricsResult {
        guard let record, record.instrumental != true, let synced = record.syncedLyrics, !synced.isEmpty else { return .none }
        var lyrics = LRC.parse(synced, trackDuration: trackDuration ?? record.duration)
        lyrics.stanzaStarts = stanzaStarts(plain: record.plainLyrics, lineCount: lyrics.lines.count)
        return lyrics.isEmpty ? .none : .synced(lyrics)
    }

    /// Dove comincia ogni strofa, letto dal testo senza tempi: lì le strofe sono separate da una riga vuota.
    /// Vale solo se le righe sono tante quante quelle del testo a tempo: se no non si sa quale è quale.
    public static func stanzaStarts(plain: String?, lineCount: Int) -> [Int] {
        guard let plain else { return [] }
        var starts: [Int] = [], count = 0, fresh = true
        for raw in plain.split(separator: "\n", omittingEmptySubsequences: false) {
            if raw.trimmingCharacters(in: .whitespaces).isEmpty { fresh = true; continue }
            if fresh { starts.append(count); fresh = false }
            count += 1
        }
        return count == lineCount && starts.count > 1 ? starts : []
    }

    /// Il titolo senza le code che cambiano da un servizio all'altro: «(feat. …)», «- Remastered 2011», «(Live)».
    public static func clean(_ title: String) -> String {
        var s = title
        for pattern in [#"\s*[\(\[][^\)\]]*(feat|ft\.|with|remaster|version|edit|live|mono|stereo|deluxe|bonus)[^\)\]]*[\)\]]"#,
                        #"\s+-\s+.*(remaster|version|edit|live|mono|stereo|single|deluxe|bonus).*$"#,
                        #"\s+(feat|ft)\.?\s+.*$"#] {
            s = s.replacingOccurrences(of: pattern, with: "", options: [.regularExpression, .caseInsensitive])
        }
        return s.trimmingCharacters(in: .whitespaces)
    }

    /// La chiave per confrontare due nomi: senza code, minuscole, senza accenti né punteggiatura.
    public static func key(_ s: String) -> String {
        let folded = clean(s).folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
        return String(folded.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }).lowercased()
    }

    /// La chiave del brano per la memoria dei testi già cercati.
    public static func cacheKey(title: String, artist: String, duration: Double?) -> String {
        "\(key(artist))|\(key(title))|\(Int((duration ?? 0).rounded()))"
    }
}

// MARK: - Le versioni di un brano su LRCLIB

/// Su LRCLIB lo stesso brano ha spesso molte voci, quasi tutte copie di poche sincronizzazioni fatte a mano, e la domanda
/// precisa (`/api/get`) dà la più copiata, anche quando è sbagliata. Con «Start A Riot» (carpa, 19 novembre 2026: «il
/// testo è molto buggato, o è prima o è dopo») la più copiata aveva 13 righe su 73 spostate da 1 a 4 secondi e righe da
/// cantare in mezzo secondo, mentre due sincronizzazioni fatte da altri andavano d'accordo fra loro.
///
/// Qui le copie si raggruppano (contano le sincronizzazioni, non le copie) e la versione data si cambia solo quando è
/// chiaramente rotta e un'altra è chiaramente sana. Si riparano le righe, non la posizione di tutto il testo: se tutto il
/// testo è avanti o indietro lo dice solo l'audio (provato il 19 novembre sulle anteprime: la mediana delle versioni
/// sembrava aiutare, e con un'altra misura dell'inizio peggiorava).
public enum LRCVersions {
    struct Row: Equatable {
        var time: Double
        var key: String
        /// Sillabe stimate (`WordTiming.weight`).
        var weight: Double
        /// Tempo fino alla riga dopo, righe vuote comprese.
        var room: Double
    }

    struct Family {
        var record: LRCLIBRecord
        var rows: [Row]
        var copies: Int
    }

    /// Meno di 80 ms a sillaba non si canta (12,5 sillabe al secondo: il rap più veloce sta sotto le 11).
    static let fastest = 0.08
    /// Due voci sono la stessa sincronizzazione (copia, anche ritoccata o con una riga vuota in più) se, tolto lo
    /// spostamento, quasi tutte le righe stanno entro un decimo.
    static let copyTolerance = 0.1
    /// Spostata in blocco di più: è un'altra edizione del brano (un'intro diversa), non vota.
    static let otherEdition = 2.0
    /// Una riga è smentita quando almeno due altre sincronizzazioni, d'accordo fra loro entro mezzo secondo, la mettono a
    /// più di un secondo da dove sta.
    static let agree = 0.5, wrong = 1.0

    /// La versione da usare: `primary` (la risposta di `/api/get`, o la migliore della ricerca), a meno che sia chiaramente
    /// rotta (almeno tre fra righe impossibili da cantare e righe smentite dalle altre) e fra le altre della stessa edizione
    /// ce ne sia una con al massimo un terzo dei suoi difetti.
    public static func pick(primary: LRCLIBRecord?, among records: [LRCLIBRecord]) -> LRCLIBRecord? {
        guard let primary, primary.instrumental != true, primary.syncedLyrics?.isEmpty == false else { return primary }
        let all = families([primary] + records)
        guard let mine = all.first, all.count >= 2 else { return primary }
        var pool = [mine]
        for f in all.dropFirst() {
            if let rel = relation(mine.rows, f.rows), abs(rel.shift) <= otherEdition { pool.append(f) }
        }
        guard pool.count >= 2 else { return primary }
        let flaws = pool.indices.map { defects(of: $0, in: pool) }
        guard flaws[0] >= 3 else { return primary }
        var best = 1
        for i in 2..<pool.count {
            if flaws[i] < flaws[best] || (flaws[i] == flaws[best] && pool[i].copies > pool[best].copies) { best = i }
        }
        guard flaws[best] * 3 <= flaws[0] else { return primary }
        // la versione sana prende il posto della rotta riga per riga, ma il testo resta dove stava nel brano: se l'altra
        // sta tutta un po' più avanti o indietro, chi ha ragione lo dice solo l'audio («Enemy», 19 novembre: cambiando
        // versione senza questo, nell'anteprima l'errore saliva da 0,13 a 0,30 s, perché l'altra stava 0,27 s dopo)
        var chosen = pool[best].record
        if let rel = relation(mine.rows, pool[best].rows), abs(rel.shift) >= 0.01, let synced = chosen.syncedLyrics {
            chosen.syncedLyrics = shifted(synced, by: -rel.shift)
        }
        return chosen
    }

    /// Il testo LRC con tutti i tempi (delle righe e delle parole) spostati di `delta` secondi, mai sotto zero.
    public static func shifted(_ synced: String, by delta: Double) -> String {
        guard let re = try? NSRegularExpression(pattern: #"([\[<])(\d+):(\d+(?:\.\d+)?)([\]>])"#) else { return synced }
        let ns = synced as NSString
        var out = "", last = 0
        for m in re.matches(in: synced, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            let minutes = Double(ns.substring(with: m.range(at: 2))) ?? 0, seconds = Double(ns.substring(with: m.range(at: 3))) ?? 0
            let t = max(0, minutes * 60 + seconds + delta)
            let cs = Int((t * 100).rounded())
            out += ns.substring(with: m.range(at: 1)) + String(format: "%02d:%02d.%02d", cs / 6000, cs / 100 % 60, cs % 100) + ns.substring(with: m.range(at: 4))
            last = m.range.location + m.range.length
        }
        return out + ns.substring(from: last)
    }

    /// La versione da usare fra la risposta della domanda precisa (`primary`) e le altre voci dello stesso brano già
    /// filtrate (`LRCLIB.candidates`): se una ha i tempi veri delle parole (prima `primary`, poi quella con la durata più
    /// vicina, entro 2 s) si parte da lei; poi il controllo delle versioni rotte (`pick`).
    public static func choose(primary: LRCLIBRecord?, others: [LRCLIBRecord], duration: Double?) -> LRCLIBRecord? {
        if primary?.instrumental == true { return primary }
        let pool = (primary.map { [$0] } ?? []) + others.sorted {
            guard let duration, duration > 0 else { return false }
            return abs(($0.duration ?? .infinity) - duration) < abs(($1.duration ?? .infinity) - duration)
        }
        let worded = pool.lazy.filter { r in
            guard let duration, duration > 0, let d = r.duration else { return true }
            return abs(d - duration) <= 2
        }.compactMap(\.withWordTimes).first
        if let worded, pick(primary: worded, among: others)?.syncedLyrics == worded.syncedLyrics { return worded }
        // il file delle parole ha difetti: non si usa, neanche per il punto in cui mettere il testo (con «Enemy», il 19
        // novembre, il file stava tutto 0,7 s dopo e la versione che lo sostituiva ereditava il ritardo)
        return pick(primary: primary, among: others) ?? primary
    }

    /// Le righe cantate di un testo LRC, ognuna col tempo che ha fino alla riga dopo.
    static func rows(_ synced: String) -> [Row] {
        var entries: [(time: Double, body: String)] = []
        for raw in synced.split(whereSeparator: \.isNewline) {
            var rest = Substring(raw).drop(while: { $0 == " " || $0 == "\t" })
            var times: [Double] = []
            while let (time, after) = LRC.leadingTag(rest, open: "[", close: "]") { times.append(time); rest = after.drop(while: { $0 == " " }) }
            guard !times.isEmpty else { continue }
            let body = String(rest).replacingOccurrences(of: "<[^>]*>", with: " ", options: .regularExpression)
            for t in times { entries.append((t, body)) }
        }
        entries.sort { $0.time < $1.time }
        var out: [Row] = []
        for (i, entry) in entries.enumerated() {
            let words = entry.body.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            guard !words.isEmpty else { continue }
            let next = i + 1 < entries.count ? entries[i + 1].time : .infinity
            out.append(Row(time: entry.time, key: lineKey(entry.body), weight: words.reduce(0) { $0 + WordTiming.weight($1) }, room: next - entry.time))
        }
        return out
    }

    /// Il testo di una riga per confrontarla con le altre versioni: minuscole, senza accenti né punteggiatura.
    static func lineKey(_ s: String) -> String {
        let folded = s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
        return String(folded.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }).lowercased()
    }

    /// Le voci raggruppate per sincronizzazione: la prima voce di ogni gruppo lo rappresenta (quindi `primary`, se viene
    /// per prima, rappresenta il suo).
    static func families(_ records: [LRCLIBRecord]) -> [Family] {
        var out: [Family] = []
        var seen = Set<Int>()
        for r in records {
            if let id = r.id { guard seen.insert(id).inserted else { continue } }
            guard r.instrumental != true, let synced = r.syncedLyrics, !synced.isEmpty else { continue }
            let rows = rows(synced)
            guard rows.count >= 6 else { continue }
            if let k = out.firstIndex(where: { isCopy($0.rows, rows) }) { out[k].copies += 1 }
            else { out.append(Family(record: r, rows: rows, copies: 1)) }
        }
        return out
    }

    static func isCopy(_ a: [Row], _ b: [Row]) -> Bool {
        guard let rel = relation(a, b), abs(rel.shift) <= copyTolerance else { return false }
        let close = rel.pairs.filter { abs(b[$0.1].time - a[$0.0].time - rel.shift) <= copyTolerance }.count
        return Double(close) >= 0.85 * Double(min(a.count, b.count))
    }

    /// Lo spostamento in blocco di `b` rispetto ad `a` e le righe in comune; `nil` se in comune ce ne sono poche.
    static func relation(_ a: [Row], _ b: [Row]) -> (shift: Double, pairs: [(Int, Int)])? {
        let pairs = match(a, b)
        guard pairs.count >= max(6, min(a.count, b.count) / 2) else { return nil }
        return (median(pairs.map { b[$0.1].time - a[$0.0].time }), pairs)
    }

    /// Le righe uguali di due versioni, in ordine. Prima l'accordo più lungo sul testo; poi di nuovo, preferendo fra le
    /// righe uguali (i ritornelli) quelle che stanno allo stesso punto, così un ritornello non si appaia col ritornello dopo.
    static func match(_ a: [Row], _ b: [Row]) -> [(Int, Int)] {
        let first = align(a, b, shift: nil)
        guard first.count >= 3 else { return first }
        return align(a, b, shift: median(first.map { b[$0.1].time - a[$0.0].time }))
    }

    private static func align(_ a: [Row], _ b: [Row], shift: Double?) -> [(Int, Int)] {
        let n = a.count, m = b.count
        guard n > 0, m > 0 else { return [] }
        let width = m + 1
        var score = [Double](repeating: 0, count: (n + 1) * width)
        func gain(_ i: Int, _ j: Int) -> Double? {
            guard !a[i].key.isEmpty, a[i].key == b[j].key else { return nil }
            guard let shift else { return 1 }
            return 1 + 0.5 * max(0, 1 - abs(b[j].time - a[i].time - shift) / 3)
        }
        for i in 1...n {
            for j in 1...m {
                var v = max(score[(i - 1) * width + j], score[i * width + j - 1])
                if let g = gain(i - 1, j - 1) { v = max(v, score[(i - 1) * width + j - 1] + g) }
                score[i * width + j] = v
            }
        }
        var out: [(Int, Int)] = []
        var i = n, j = m
        while i > 0, j > 0 {
            if let g = gain(i - 1, j - 1), abs(score[i * width + j] - (score[(i - 1) * width + j - 1] + g)) < 1e-9 {
                out.append((i - 1, j - 1)); i -= 1; j -= 1
            } else if score[(i - 1) * width + j] >= score[i * width + j - 1] { i -= 1 } else { j -= 1 }
        }
        return out.reversed()
    }

    /// I difetti di una versione: righe che non si possono cantare nel tempo che hanno, più righe smentite dalle altre
    /// sincronizzazioni (almeno due d'accordo fra loro).
    static func defects(of index: Int, in pool: [Family]) -> Int {
        let f = pool[index]
        var votes: [Int: [Double]] = [:]
        for (k, o) in pool.enumerated() where k != index {
            guard let rel = relation(f.rows, o.rows), abs(rel.shift) <= otherEdition else { continue }
            for (i, j) in rel.pairs { votes[i, default: []].append(o.rows[j].time - rel.shift) }
        }
        var contradicted = 0
        for (i, v) in votes where v.count >= 2 {
            let sorted = v.sorted()
            var group: [Double] = []
            for (s, low) in sorted.enumerated() {
                let g = sorted[s...].prefix { $0 <= low + agree }
                if g.count > group.count { group = Array(g) }
            }
            if group.count >= 2, abs(f.rows[i].time - median(group)) > wrong { contradicted += 1 }
        }
        return impossible(f.rows) + contradicted
    }

    static func impossible(_ rows: [Row]) -> Int {
        rows.filter { $0.weight >= 4 && $0.room < $0.weight * fastest }.count
    }

    static func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let s = values.sorted()
        return s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
    }
}
