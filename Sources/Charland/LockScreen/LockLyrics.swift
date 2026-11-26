import SwiftUI
import CharlandCore

/// Cerca il testo a tempo del brano che suona su LRCLIB (lrclib.net) e lo ricorda.
///
/// Si cerca solo per le app di musica (non per il video di un sito) e solo se l'utente ha acceso «Testo delle canzoni»:
/// alla rete vanno titolo, artista, album e durata, nient'altro. Quando il testo non c'è, o non ha i tempi,
/// la risposta è «niente» e la copertina aperta si ricompone al centro.
@MainActor
final class LyricsService {
    static let shared = LyricsService()

    private var memory: [String: LyricsResult] = [:]
    private var task: Task<Void, Never>?
    private var wanted = ""

    /// Le app per cui ha senso cercare un testo.
    static func isMusicApp(_ bundleID: String?) -> Bool {
        guard let bundleID else { return false }
        return MusicApp.known.contains(bundleID) || bundleID == MusicApp.shared.bundleID
    }

    /// Il testo del brano, quando arriva. Se nel frattempo il brano è cambiato la risposta si butta.
    func lyrics(for snapshot: NowPlayingSnapshot, done: @escaping (LyricsResult) -> Void) {
        let key = LRCLIB.cacheKey(title: snapshot.title, artist: snapshot.artist, duration: snapshot.duration)
        wanted = key
        task?.cancel()
        guard LockSettings.shared.lyrics, Self.isMusicApp(snapshot.app), snapshot.duration > 30, !snapshot.artist.isEmpty else { done(.none); return }
        if let known = memory[key] { done(known); return }
        let saved = Self.load(key)
        if let saved, saved.checked {
            let result = LRCLIB.result(from: saved.record, trackDuration: snapshot.duration)
            memory[key] = result; done(result); return
        }
        // un testo scelto prima del controllo delle versioni si chiede di nuovo, una volta: poteva essere la versione
        // rotta (con «Start A Riot» lo era); se la rete non risponde si tiene quello
        let (title, artist, album, duration) = (snapshot.title, snapshot.artist, snapshot.album, snapshot.duration)
        task = Task {
            let fetched = await Self.fetch(title: title, artist: artist, album: album, duration: duration)
            guard !Task.isCancelled else { return }
            let record = fetched?.record ?? saved?.record
            let result = LRCLIB.result(from: record, trackDuration: duration)
            // una risposta mancata per colpa della rete non si ricorda: al prossimo ascolto si riprova
            if let fetched { Self.save(fetched.record, key: key, checked: fetched.checked) }
            if record != nil { self.memory[key] = result }
            if self.wanted == key { done(result) }
        }
    }

    // MARK: Rete

    private nonisolated static let agent: String = {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
        return "Charland/\(version) (https://charstudio.app)"
    }()

    /// Prima la domanda precisa, poi sempre la ricerca larga: le altre versioni dello stesso brano servono a riconoscere
    /// una versione rotta (`LRCVersions.pick`) e, se la domanda precisa non trova, a trovarne una (la durata più vicina).
    /// Torna un risultato vuoto (senza testi) quando LRCLIB dice che non c'è, `nil` quando la rete non risponde.
    /// `checked` dice se la versione è passata dal controllo (falso se la ricerca larga non ha risposto).
    private nonisolated static func fetch(title: String, artist: String, album: String, duration: Double) async -> (record: LRCLIBRecord, checked: Bool)? {
        func get(_ url: URL?) async -> (Data, Int)? {
            guard let url else { return nil }
            var request = URLRequest(url: url, timeoutInterval: 8)
            request.setValue(agent, forHTTPHeaderField: "User-Agent")
            guard let (data, response) = try? await URLSession.shared.data(for: request), let http = response as? HTTPURLResponse else { return nil }
            return (data, http.statusCode)
        }
        guard let (data, status) = await get(LRCLIB.getURL(title: title, artist: artist, album: album, duration: duration)) else { return nil }
        guard status == 200 || status == 404 else { return nil }
        var exact: LRCLIBRecord?
        if status == 200, let record = try? JSONDecoder().decode(LRCLIBRecord.self, from: data) {
            if record.instrumental == true { return (record, true) }
            if record.syncedLyrics?.isEmpty == false { exact = record }
        }
        var found: [LRCLIBRecord] = [], answered = false
        for url in LRCLIB.searchURLs(title: title, artist: artist) {
            guard let (list, listStatus) = await get(url), listStatus == 200, let records = try? JSONDecoder().decode([LRCLIBRecord].self, from: list) else { continue }
            found += records; answered = true
        }
        // i tempi veri delle parole, se ci sono, e il controllo delle versioni rotte (`LRCVersions.choose`)
        if let exact {
            guard answered else { return (exact.withWordTimes ?? exact, false) }
            let others = LRCLIB.candidates(found, title: title, artist: artist, duration: duration)
            return (LRCVersions.choose(primary: exact, others: others, duration: duration) ?? exact, true)
        }
        guard answered else { return status == 404 ? (LRCLIBRecord(), false) : nil }
        guard let best = LRCLIB.best(found, title: title, artist: artist, duration: duration) else { return (LRCLIBRecord(), true) }
        let others = LRCLIB.candidates(found, title: title, artist: artist, duration: duration)
        return (LRCVersions.choose(primary: best, others: others, duration: duration) ?? best, true)
    }

    // MARK: Memoria su disco

    private nonisolated static var folder: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent(Bundle.main.bundleIdentifier ?? "com.charstudio.charland").appendingPathComponent("testi", isDirectory: true)
    }
    private nonisolated static func file(_ key: String) -> URL {
        let name = key.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? String($0) : "_" }.joined()
        return folder.appendingPathComponent(String(name.prefix(120)) + ".json")
    }
    /// `rule` è la regola con cui è stata scelta la versione: senza (i testi salvati prima del 19 novembre 2026) o più
    /// vecchia di `currentRule`, il testo si chiede di nuovo una volta.
    private struct Saved: Codable { var at: Date; var synced: String?; var instrumental: Bool?; var duration: Double?; var plain: String?; var rule: Int? }
    /// 2: controllo delle versioni (`LRCVersions.pick`). 3: tempi veri delle parole (`LyricsFile`), 19 novembre 2026 sera.
    private nonisolated static let currentRule = 3

    private static func load(_ key: String) -> (record: LRCLIBRecord, checked: Bool)? {
        guard let data = try? Data(contentsOf: file(key)), let saved = try? JSONDecoder().decode(Saved.self, from: data) else { return nil }
        // un «non c'è» vale una settimana: i testi si aggiungono col tempo
        if (saved.synced ?? "").isEmpty, Date().timeIntervalSince(saved.at) > 7 * 86400 { return nil }
        let record = LRCLIBRecord(duration: saved.duration, instrumental: saved.instrumental, plainLyrics: saved.plain, syncedLyrics: saved.synced)
        // un brano strumentale o senza testo non ha versioni da controllare
        let checked = (saved.rule ?? 0) >= currentRule || saved.instrumental == true || (saved.synced ?? "").isEmpty
        return (record, checked)
    }
    private static func save(_ record: LRCLIBRecord, key: String, checked: Bool) {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let saved = Saved(at: Date(), synced: record.syncedLyrics, instrumental: record.instrumental, duration: record.duration, plain: record.plainLyrics,
                          rule: checked ? currentRule : nil)
        try? JSONEncoder().encode(saved).write(to: file(key), options: .atomic)
    }
}

// MARK: - La colonna del testo

/// Il testo a destra della foto, come in Musica: la riga cantata bianca e a fuoco, le altre attenuate e sfocate,
/// ogni parola che si accende mentre viene cantata. Le pause lunghe sono un filo di luce che si riempie (niente puntini).
///
/// Niente animazioni di SwiftUI: il punto della canzone, lo scorrere e il fuoco di ogni riga arrivano da `LockLive`,
/// che `LockScreen` porta avanti a ogni fotogramma col suo timer.
struct LockLyricsColumn: View {
    let model: LockModel

    var body: some View {
        let live = model.live
        let k = model.layout.k
        let size = 52 * k
        let box = model.layout.lyrics.size
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(model.rows.enumerated()), id: \.offset) { index, row in
                let focus = index < live.focus.count ? live.focus[index] : 0
                let distance = abs(index - live.current)
                let far = distance > 1
                // le righe lontane sono fuori dalla colonna: stanno al loro posto ma non si disegnano
                let drawn = distance <= 8
                let base = far ? 0.18 : 0.3
                let isCurrent = index == live.current
                // una riga si ridisegna solo se è quella cantata (o lo diventa, o smette di esserlo)
                LockLyricRow(row: row, index: index, stamp: model.rowsStamp, time: isCurrent ? live.time : 0, isCurrent: isCurrent, size: size)
                    .equatable()
                    .opacity(drawn ? base + (1 - base) * focus : 0)
                    .blur(radius: drawn ? (1 - focus) * (far ? 4.4 : 2.2) : 0)
                    .scaleEffect(0.95 + 0.05 * focus, anchor: .leading)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { live.heights[index] = $0 }
            }
        }
        // il testo è alto quanto è lungo il brano; la colonna no: è una finestra fissa su di lui.
        // (Con una cornice elastica la colonna si allungava su tutto il testo, e con lei la sfumatura dei bordi:
        // la riga cantata finiva nel tratto che sfuma e restava a un terzo del bianco. Visto il 18 novembre 2026
        // sul blocco vero; col testo di prova, corto, non succedeva.)
        .fixedSize(horizontal: false, vertical: true)
        // la riga cantata sta sempre alla stessa altezza
        .offset(y: 150 * k - live.scroll)
        .frame(width: box.width, height: box.height, alignment: .topLeading)
        .mask {
            LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.15),
                                   .init(color: .black, location: 0.72), .init(color: .clear, location: 1)], startPoint: .top, endPoint: .bottom)
        }
    }
}

struct LockLyricRow: View, Equatable {
    var row: LyricRow
    var index: Int
    /// Quale testo: cambia quando cambiano le righe.
    var stamp: Int
    var time: Double
    var isCurrent: Bool
    var size: CGFloat

    nonisolated static func == (a: LockLyricRow, b: LockLyricRow) -> Bool {
        a.index == b.index && a.stamp == b.stamp && a.time == b.time && a.isCurrent == b.isCurrent && a.size == b.size
    }

    /// Quanto è accesa una parola della riga cantata prima di essere cantata: si legge già, ma il bianco pieno è di quelle cantate.
    private static let unsung = 0.7

    var body: some View {
        Group {
            switch row {
            case .line(let line):
                // impaginata sempre allo stesso modo, parola per parola: quando diventa quella cantata non cambia né altezza né a capo
                LockFlow(spacing: size * 0.24, lineSpacing: size * 0.06) {
                    ForEach(Array(line.words.enumerated()), id: \.offset) { _, word in
                        let sung = isCurrent ? min(1, max(0, (time - word.start) / max(0.05, word.duration))) : 1
                        Text(word.text)
                            .font(.system(size: size, weight: .bold)).tracking(-size * 0.016)
                            .foregroundStyle(.white)
                            .opacity(Self.unsung + (1 - Self.unsung) * sung)
                            .fixedSize()
                    }
                }
            case .pause(let start, let end):
                let q = isCurrent ? min(1, max(0, (time - start) / max(0.1, end - start))) : 0
                Capsule().fill(.white.opacity(0.26))
                    .overlay(alignment: .leading) { Capsule().fill(.white).frame(width: max(4, 140 * q)) }
                    .frame(width: 140, height: 4)
                    .padding(.vertical, size * 0.42)
            }
        }
        .padding(.vertical, size * 0.25)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Le parole in fila, che vanno a capo quando la riga è piena.
struct LockFlow: Layout {
    var spacing: CGFloat
    var lineSpacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(proposal.width ?? .infinity, subviews)
        return CGSize(width: rows.map(\.width).max() ?? 0, height: rows.reduce(0) { $0 + $1.height } + lineSpacing * CGFloat(max(0, rows.count - 1)))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(bounds.width, subviews) {
            var x = bounds.minX
            for index in row.items {
                let s = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y + (row.height - s.height) / 2), proposal: .unspecified)
                x += s.width + spacing
            }
            y += row.height + lineSpacing
        }
    }

    private struct Row { var items: [Int] = []; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func arrange(_ width: CGFloat, _ subviews: Subviews) -> [Row] {
        var rows: [Row] = [], row = Row()
        for index in subviews.indices {
            let s = subviews[index].sizeThatFits(.unspecified)
            let w = row.items.isEmpty ? s.width : row.width + spacing + s.width
            if !row.items.isEmpty, w > width { rows.append(row); row = Row(items: [index], width: s.width, height: s.height) }
            else { row.items.append(index); row.width = w; row.height = max(row.height, s.height) }
        }
        if !row.items.isEmpty { rows.append(row) }
        return rows
    }
}
