import Foundation

/// Quanto è costato Claude (carpa: «il prezzo API e i token utilizzati, oggi, 7 giorni, 30 giorni, e anche l'usage»).
///
/// I token vengono dai registri di Claude Code in `~/.claude/projects` (ogni risposta porta modello, ora e token;
/// la stessa risposta compare su più righe e si conta una volta, per id). Il prezzo è quello delle API, per milione di
/// token, dalla tabella ufficiale: per chi ha un abbonamento è un'equivalenza, non una spesa. L'utilizzo del piano
/// (sessione di 5 ore, settimana) è quello che Claude Code tiene in `~/.claude.json`.
///
/// I registri degli ultimi 30 giorni sono qualche GB: la prima lettura gira in sottofondo, poi si leggono solo le
/// righe nuove.
enum AgentPricing {
    /// Dollari per milione di token: ingresso, uscita, scrittura in cache (5 minuti, 1 ora), lettura dalla cache.
    struct Price: Sendable {
        let input, output, write5m, write1h, read: Double
    }

    /// Dalla tabella dei prezzi di Anthropic (novembre 2026). Le scritture in cache costano 1,25 volte l'ingresso a
    /// 5 minuti e 2 volte a 1 ora; le letture 0,1 volte, tranne dove la tabella dice altro (Fable 5.2 e 5.1, Opus 5.5,
    /// Sonnet 5.5). L'ordine conta: i nomi più lunghi prima («opus-5-5» prima di «opus-5»).
    private static let table: [(String, Price)] = [
        ("fable-5-2", Price(input: 8, output: 40, write5m: 10, write1h: 16, read: 0.20)),
        ("mythos-5-2", Price(input: 8, output: 40, write5m: 10, write1h: 16, read: 0.20)),
        ("fable-5-1", Price(input: 10, output: 50, write5m: 12.5, write1h: 20, read: 0.25)),
        ("mythos-5-1", Price(input: 10, output: 50, write5m: 12.5, write1h: 20, read: 0.25)),
        ("fable-5", Price(input: 10, output: 50, write5m: 12.5, write1h: 20, read: 1)),
        ("mythos", Price(input: 10, output: 50, write5m: 12.5, write1h: 20, read: 1)),
        ("opus-5-5", Price(input: 4, output: 20, write5m: 5, write1h: 8, read: 0.20)),
        ("opus-5", Price(input: 5, output: 25, write5m: 6.25, write1h: 10, read: 0.5)),
        ("opus-4-8", Price(input: 5, output: 25, write5m: 6.25, write1h: 10, read: 0.5)),
        ("opus-4-7", Price(input: 5, output: 25, write5m: 6.25, write1h: 10, read: 0.5)),
        ("opus-4-6", Price(input: 5, output: 25, write5m: 6.25, write1h: 10, read: 0.5)),
        ("opus-4-5", Price(input: 5, output: 25, write5m: 6.25, write1h: 10, read: 0.5)),
        ("opus", Price(input: 15, output: 75, write5m: 18.75, write1h: 30, read: 1.5)),
        ("sonnet-5-5", Price(input: 2, output: 10, write5m: 2.5, write1h: 4, read: 0.10)),
        ("sonnet-5", Price(input: 2, output: 10, write5m: 2.5, write1h: 4, read: 0.2)),
        ("sonnet", Price(input: 3, output: 15, write5m: 3.75, write1h: 6, read: 0.3)),
        ("haiku-5-5", Price(input: 0.10, output: 0.50, write5m: 0.125, write1h: 0.2, read: 0.01)),
        ("haiku-4-5", Price(input: 1, output: 5, write5m: 1.25, write1h: 2, read: 0.1)),
        ("haiku", Price(input: 0.8, output: 4, write5m: 1, write1h: 1.6, read: 0.08)),
    ]

    static func price(for model: String) -> Price? {
        let m = model.lowercased()
        return table.first { m.contains($0.0) }?.1
    }

    /// Il nome da mostrare: «Fable 5.2», «Opus 5.5», «Sonnet 4.5».
    static func displayName(_ model: String) -> String {
        let parts = model.lowercased().replacingOccurrences(of: "claude-", with: "").split(separator: "-")
        // La famiglia è la parola (anche dopo i numeri, come in «3-5-haiku»); i numeri brevi sono la versione, le date no.
        guard let family = parts.first(where: { Int($0) == nil }) else { return model }
        let numbers = parts.filter { $0.count <= 2 && Int($0) != nil }
        let name = family.prefix(1).uppercased() + family.dropFirst()
        return numbers.isEmpty ? name : name + " " + numbers.joined(separator: ".")
    }
}

/// I numeri di un periodo.
struct AgentPeriodStats: Equatable, Sendable {
    var input = 0, output = 0, cacheWrite = 0, cacheRead = 0
    var cost = 0.0
    /// Costo per modello, dal più caro.
    var models: [(name: String, cost: Double, tokens: Int)] = []

    var tokens: Int { input + output + cacheWrite + cacheRead }

    static func == (a: AgentPeriodStats, b: AgentPeriodStats) -> Bool {
        a.input == b.input && a.output == b.output && a.cacheWrite == b.cacheWrite && a.cacheRead == b.cacheRead
            && a.cost == b.cost && a.models.map(\.name) == b.models.map(\.name)
    }
}

/// L'utilizzo del piano come lo tiene Claude Code: percentuale e quando riparte.
struct PlanUsage: Equatable, Sendable {
    struct Window: Equatable, Sendable {
        var title: String
        var percent: Double
        var resets: Date?
    }
    var windows: [Window] = []
}

enum AgentPeriod: String, CaseIterable, Identifiable, Sendable {
    case today, week, month
    var id: String { rawValue }
    var title: String {
        switch self {
        case .today: String(localized: "Oggi")
        case .week: String(localized: "7 giorni")
        case .month: String(localized: "30 giorni")
        }
    }
    /// Quanti giorni indietro, contando oggi.
    var days: Int {
        switch self {
        case .today: 1
        case .week: 7
        case .month: 30
        }
    }
}

/// Legge i registri in sottofondo e tiene i numeri. Un solo lettore, su una coda sua.
final class AgentStatsStore: @unchecked Sendable {
    static let shared = AgentStatsStore()

    /// Una risposta, in 28 byte: il giorno, il modello come posto nell'elenco `models`, i token.
    ///
    /// Prima ogni risposta teneva il suo identificativo e il nome del modello come testo (41.000 risposte in 30 giorni:
    /// una dozzina di MB sempre in memoria, più una cache in JSON che a ogni avvio si rileggeva creando decine di MB di
    /// oggetti di passaggio). Ora la chiave è un numero ricavato dall'identificativo e la cache è un file a righe fisse.
    private struct Entry {
        var day: Int32
        var model: UInt16
        var input: UInt32 = 0, output: UInt32 = 0, write5m: UInt32 = 0, write1h: UInt32 = 0, read: UInt32 = 0
    }

    private let queue = DispatchQueue(label: "charland.agent-stats", qos: .utility)
    private var entries: [UInt64: Entry] = [:]
    /// I nomi dei modelli visti, e il posto di ognuno.
    private var models: [String] = []
    private var modelIndex: [String: UInt16] = [:]

    private func index(of model: String) -> UInt16 {
        if let known = modelIndex[model] { return known }
        let index = UInt16(truncatingIfNeeded: models.count)
        models.append(model)
        modelIndex[model] = index
        return index
    }

    /// Un numero di 64 bit dall'identificativo di una risposta (FNV-1a): uguale a ogni avvio, e con qualche decina di
    /// migliaia di risposte due identificativi diversi non danno mai lo stesso numero.
    private static func key(_ bytes: UnsafeRawBufferPointer) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in bytes { hash = (hash ^ UInt64(byte)) &* 0x0000_0100_0000_01b3 }
        return hash
    }
    private static func key(_ text: String) -> UInt64 {
        var text = text
        return text.withUTF8 { key(UnsafeRawBufferPointer($0)) }
    }
    private var offsets: [String: UInt64] = [:]
    /// Chi aspetta i numeri, e se una lettura è già in coda: le richieste che arrivano mentre legge (ogni 15 secondi
    /// durante la prima lettura, che dura di più) aspettano quella invece di ripeterla.
    private let lock = NSLock()
    private var waiting: [@MainActor @Sendable ([AgentPeriod: AgentPeriodStats], PlanUsage) -> Void] = []
    private var queued = false
    private let isoFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private let iso = ISO8601DateFormatter()
    private static let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects")
    private static let config = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude.json")
    private static let usageMarker = Data("\"usage\"".utf8)
    private static let assistantMarker = Data("\"assistant\"".utf8)

    /// Legge le righe nuove e restituisce i numeri dei tre periodi e l'utilizzo del piano, sul thread principale.
    /// C'è già la cache dei conti: leggere le righe nuove costa pochi secondi.
    static var hasCache: Bool {
        FileManager.default.fileExists(atPath: cacheURL.path) || FileManager.default.fileExists(atPath: legacyURL.path)
    }

    func refresh(_ done: @escaping @MainActor @Sendable ([AgentPeriod: AgentPeriodStats], PlanUsage) -> Void) {
        lock.lock()
        waiting.append(done)
        let start = !queued
        queued = true
        lock.unlock()
        guard start else { return }
        queue.async { [self] in
            loadCache()
            scan()
            saveCache()
            let stats = Dictionary(uniqueKeysWithValues: AgentPeriod.allCases.map { ($0, summary(for: $0)) })
            let usage = readPlanUsage()
            lock.lock()
            let callbacks = waiting
            waiting = []
            queued = false
            lock.unlock()
            DispatchQueue.main.async { MainActor.assumeIsolated { for done in callbacks { done(stats, usage) } } }
        }
    }

    // MARK: Registri

    private static func dayIndex(_ date: Date) -> Int {
        let start = Calendar.current.startOfDay(for: date)
        return Int((start.timeIntervalSinceReferenceDate / 86_400).rounded())
    }

    private func scan() {
        let fm = FileManager.default
        let horizon = Date().addingTimeInterval(-31 * 86_400)
        guard let walker = fm.enumerator(at: Self.root, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
                                         options: [.skipsHiddenFiles]) else { return }
        for case let url as URL in walker where url.pathExtension == "jsonl" {
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            guard let modified = values?.contentModificationDate, modified > horizon,
                  let size = values?.fileSize else { continue }
            let path = url.path
            let start = offsets[path] ?? 0
            if UInt64(size) < start { offsets[path] = 0 }   // riscritto da capo
            guard UInt64(size) > (offsets[path] ?? 0) else { continue }
            read(path)
        }
        // Fuori dai 30 giorni non serve più niente.
        let oldest = Int32(Self.dayIndex(Date()) - 31)
        if entries.values.contains(where: { $0.day < oldest }) { entries = entries.filter { $0.value.day >= oldest } }
    }

    /// Legge un registro dal punto dove si era fermato, a pezzi da 4 MB, riga per riga, sui byte: le righe con i token
    /// sono riconosciute con una ricerca diretta, e di ognuna si legge solo il necessario (modello, id, ora, token).
    /// Leggere ogni riga intera come JSON, con dentro risposte enormi, costava 25 secondi di CPU e centinaia di MB.
    private func read(_ path: String) {
        guard let handle = FileHandle(forReadingAtPath: path) else { return }
        defer { try? handle.close() }
        var offset = offsets[path] ?? 0
        try? handle.seek(toOffset: offset)
        var carry = Data()
        while true {
            // Gli oggetti temporanei si liberano a ogni pezzo: su una coda di sottofondo restavano fino alla fine.
            let more: Bool = autoreleasepool {
                guard let chunk = try? handle.read(upToCount: 4 << 20), !chunk.isEmpty else { return false }
                offset += UInt64(chunk.count)
                var data = carry
                data.append(chunk)
                var consumed = 0
                data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                    guard let base = raw.baseAddress else { return }
                    var start = 0
                    while start < raw.count, let nl = memchr(base + start, 0x0A, raw.count - start) {
                        let end = base.distance(to: UnsafeRawPointer(nl))
                        if end > start { take(UnsafeRawBufferPointer(start: base + start, count: end - start)) }
                        start = end + 1
                    }
                    consumed = start
                }
                carry = consumed < data.count ? data.subdata(in: consumed..<data.count) : Data()
                return true
            }
            if !more { break }
        }
        // L'ultima riga a metà (il registro si sta scrivendo) si rilegge la prossima volta.
        let newOffset = offset - UInt64(carry.count)
        if newOffset != offsets[path] { offsets[path] = newOffset; changed = true }
    }

    private static let assistantKey = Array(#""type":"assistant""#.utf8)
    private static let usageKey = Array(#""usage":{"input_tokens""#.utf8)
    private static let modelKey = Array(#""message":{"model":""#.utf8)
    private static let idKey = Array(#""id":""#.utf8)
    private static let timestampKey = Array(#""timestamp":""#.utf8)

    /// Dove compare `needle` in `hay` a partire da `from`; `last` cerca l'ultima volta.
    private static func find(_ needle: [UInt8], in hay: UnsafeRawBufferPointer, from: Int = 0, last: Bool = false) -> Int? {
        guard let base = hay.baseAddress, from < hay.count else { return nil }
        var found: Int?
        var at = from
        while at < hay.count {
            guard let hit = needle.withUnsafeBytes({ memmem(base + at, hay.count - at, $0.baseAddress, $0.count) }) else { break }
            let index = base.distance(to: UnsafeRawPointer(hit))
            found = index
            if !last { break }
            at = index + 1
        }
        return found
    }

    /// La stringa fra `start` e le prossime virgolette.
    private static func string(in hay: UnsafeRawBufferPointer, at start: Int) -> String? {
        guard let base = hay.baseAddress, start < hay.count,
              let quote = memchr(base + start, 0x22, hay.count - start) else { return nil }
        let end = base.distance(to: UnsafeRawPointer(quote))
        return String(decoding: UnsafeRawBufferPointer(start: base + start, count: end - start), as: UTF8.self)
    }

    private func take(_ line: UnsafeRawBufferPointer) {
        // Chiavi vere, non testo: dentro le stringhe del registro le virgolette sono precedute da «\».
        guard let usageAt = Self.find(Self.usageKey, in: line, last: true),
              Self.find(Self.assistantKey, in: line) != nil,
              let modelAt = Self.find(Self.modelKey, in: line),
              let model = Self.string(in: line, at: modelAt + Self.modelKey.count), !model.hasPrefix("<"),
              let stampAt = Self.find(Self.timestampKey, in: line, last: true),
              let stamp = Self.string(in: line, at: stampAt + Self.timestampKey.count),
              let date = parseDate(stamp) else { return }
        // L'identificativo si legge sui byte, senza farne un testo: serve solo il suo numero.
        let id: UInt64
        if let idAt = Self.find(Self.idKey, in: line, from: modelAt), let base = line.baseAddress,
           let quote = memchr(base + idAt + Self.idKey.count, 0x22, line.count - idAt - Self.idKey.count) {
            let start = idAt + Self.idKey.count
            id = Self.key(UnsafeRawBufferPointer(start: base + start, count: base.distance(to: UnsafeRawPointer(quote)) - start))
        } else {
            id = Self.key(stamp + model)
        }
        // Il blocco dei token: dalla sua graffa a quella che lo chiude (dentro ci sono solo numeri e oggetti).
        let open = usageAt + #""usage":"#.utf8.count
        var depth = 0
        var close = open
        let bytes = line.bindMemory(to: UInt8.self)
        while close < bytes.count {
            if bytes[close] == 0x7B { depth += 1 } else if bytes[close] == 0x7D { depth -= 1; if depth == 0 { break } }
            close += 1
        }
        guard close < bytes.count,
              let usage = try? JSONSerialization.jsonObject(with: Data(bytes[open...close])) as? [String: Any] else { return }
        func int(_ key: String, in dict: [String: Any]) -> UInt32 {
            UInt32(clamping: (dict[key] as? NSNumber)?.intValue ?? 0)
        }
        var entry = Entry(day: Int32(Self.dayIndex(date)), model: index(of: model))
        entry.input = int("input_tokens", in: usage)
        entry.output = int("output_tokens", in: usage)
        entry.read = int("cache_read_input_tokens", in: usage)
        let written = int("cache_creation_input_tokens", in: usage)
        if let split = usage["cache_creation"] as? [String: Any] {
            entry.write1h = int("ephemeral_1h_input_tokens", in: split)
            entry.write5m = written > entry.write1h ? written - entry.write1h : 0
        } else {
            entry.write5m = written
        }
        // La stessa risposta su più righe: vale quella con più uscita (l'ultima, a risposta finita).
        if let old = entries[id], old.output >= entry.output { return }
        entries[id] = entry
        changed = true
    }

    // MARK: Memoria fra un avvio e l'altro

    /// I conti già fatti: all'avvio si leggono solo le righe nuove, non 5 GB da capo.
    private static let folder: URL = {
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Charland", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }()
    /// La cache di adesso: un file a righe fisse (un'intestazione in JSON con modelli e registri, poi 36 byte per risposta).
    private static let cacheURL = folder.appendingPathComponent("agent-stats.bin")
    /// La cache di prima, in JSON: si legge una volta sola, per non rifare la lettura di tutti i registri.
    private static let legacyURL = folder.appendingPathComponent("agent-stats.json")
    private static let magic: UInt32 = 0x3253_4843   // «CHS2»
    private static let recordSize = 36
    private var loaded = false
    private var changed = false
    private var lastSave: Date?

    private struct Header: Codable {
        var offsets: [String: UInt64]
        var models: [String]
        var count: Int
    }

    private struct Legacy: Codable {
        var version = 1
        var offsets: [String: UInt64]
        /// id → [giorno, ingresso, uscita, scrittura 5 min, scrittura 1 ora, lettura]
        var entries: [String: [Int]]
        var models: [String: String]
    }

    private func loadCache() {
        guard !loaded else { return }
        loaded = true
        if loadBinary() { return }
        // La prima volta dopo l'aggiornamento: dalla cache in JSON, che poi non serve più a questa versione.
        autoreleasepool {
            guard let data = try? Data(contentsOf: Self.legacyURL), let saved = try? JSONDecoder().decode(Legacy.self, from: data),
                  saved.version == 1 else { return }
            offsets = saved.offsets
            entries.reserveCapacity(saved.entries.count)
            for (id, v) in saved.entries where v.count == 6 {
                var e = Entry(day: Int32(clamping: v[0]), model: index(of: saved.models[id] ?? ""))
                e.input = UInt32(clamping: v[1]); e.output = UInt32(clamping: v[2]); e.write5m = UInt32(clamping: v[3])
                e.write1h = UInt32(clamping: v[4]); e.read = UInt32(clamping: v[5])
                entries[Self.key(id)] = e
            }
            changed = true
        }
    }

    /// Il file a righe fisse: «CHS2», la lunghezza dell'intestazione, l'intestazione in JSON, poi una riga per risposta
    /// (chiave, giorno, modello, cinque conti di token), tutto coi byte nell'ordine del Mac.
    private func loadBinary() -> Bool {
        guard let data = try? Data(contentsOf: Self.cacheURL, options: .mappedIfSafe), data.count >= 8 else { return false }
        return data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Bool in
            guard raw.loadUnaligned(fromByteOffset: 0, as: UInt32.self) == Self.magic else { return false }
            let headerSize = Int(raw.loadUnaligned(fromByteOffset: 4, as: UInt32.self))
            guard headerSize > 0, raw.count >= 8 + headerSize,
                  let header = try? JSONDecoder().decode(Header.self, from: Data(raw[8..<(8 + headerSize)])),
                  header.count >= 0, raw.count >= 8 + headerSize + header.count * Self.recordSize else { return false }
            offsets = header.offsets
            models = header.models
            modelIndex = Dictionary(models.enumerated().map { ($0.element, UInt16($0.offset)) }, uniquingKeysWith: { first, _ in first })
            entries.reserveCapacity(header.count)
            var at = 8 + headerSize
            for _ in 0..<header.count {
                var e = Entry(day: raw.loadUnaligned(fromByteOffset: at + 8, as: Int32.self),
                              model: raw.loadUnaligned(fromByteOffset: at + 12, as: UInt16.self))
                e.input = raw.loadUnaligned(fromByteOffset: at + 16, as: UInt32.self)
                e.output = raw.loadUnaligned(fromByteOffset: at + 20, as: UInt32.self)
                e.write5m = raw.loadUnaligned(fromByteOffset: at + 24, as: UInt32.self)
                e.write1h = raw.loadUnaligned(fromByteOffset: at + 28, as: UInt32.self)
                e.read = raw.loadUnaligned(fromByteOffset: at + 32, as: UInt32.self)
                entries[raw.loadUnaligned(fromByteOffset: at, as: UInt64.self)] = e
                at += Self.recordSize
            }
            return true
        }
    }

    /// Al massimo una volta al minuto (la prima volta subito, dopo la lettura completa): riscriverla a ogni giro, con
    /// una sessione di Claude attiva, voleva dire qualche MB ogni 15 secondi.
    private func saveCache() {
        guard changed, lastSave.map({ Date().timeIntervalSince($0) > 60 }) ?? true else { return }
        changed = false
        lastSave = Date()
        // I registri cancellati non servono più.
        offsets = offsets.filter { FileManager.default.fileExists(atPath: $0.key) }
        guard let header = try? JSONEncoder().encode(Header(offsets: offsets, models: models, count: entries.count)) else { return }
        var data = Data(capacity: 8 + header.count + entries.count * Self.recordSize)
        func put<T>(_ value: T) { withUnsafeBytes(of: value) { data.append(contentsOf: $0) } }
        put(Self.magic)
        put(UInt32(header.count))
        data.append(header)
        for (key, e) in entries {
            put(key); put(e.day); put(e.model); put(UInt16(0))
            put(e.input); put(e.output); put(e.write5m); put(e.write1h); put(e.read)
        }
        try? data.write(to: Self.cacheURL, options: .atomic)
    }

    private func summary(for period: AgentPeriod) -> AgentPeriodStats {
        let first = Int32(Self.dayIndex(Date()) - (period.days - 1))
        var stats = AgentPeriodStats()
        // Si somma per modello (sono una manciata) e i prezzi si cercano una volta per modello, non per risposta.
        struct Sum { var input = 0, output = 0, write5m = 0, write1h = 0, read = 0 }
        var sums = [Sum](repeating: Sum(), count: models.count)
        for entry in entries.values where entry.day >= first {
            let m = Int(entry.model)
            guard m < sums.count else { continue }
            sums[m].input += Int(entry.input)
            sums[m].output += Int(entry.output)
            sums[m].write5m += Int(entry.write5m)
            sums[m].write1h += Int(entry.write1h)
            sums[m].read += Int(entry.read)
        }
        var byModel: [String: (cost: Double, tokens: Int)] = [:]
        for (m, sum) in sums.enumerated() {
            let tokens = sum.input + sum.output + sum.write5m + sum.write1h + sum.read
            guard tokens > 0 else { continue }
            stats.input += sum.input
            stats.output += sum.output
            stats.cacheWrite += sum.write5m + sum.write1h
            stats.cacheRead += sum.read
            var cost = 0.0
            if let p = AgentPricing.price(for: models[m]) {
                cost = (Double(sum.input) * p.input + Double(sum.output) * p.output + Double(sum.write5m) * p.write5m
                        + Double(sum.write1h) * p.write1h + Double(sum.read) * p.read) / 1_000_000
            }
            stats.cost += cost
            let name = AgentPricing.displayName(models[m])
            byModel[name, default: (0, 0)].cost += cost
            byModel[name, default: (0, 0)].tokens += tokens
        }
        stats.models = byModel.map { (name: $0.key, cost: $0.value.cost, tokens: $0.value.tokens) }.sorted { $0.cost > $1.cost }
        return stats
    }

    /// Le date dei registri hanno 3 decimali, quelle dell'utilizzo 6 («…00.189096+00:00»), che il lettore di Apple
    /// può rifiutare: senza decimali si leggono sempre.
    private func parseDate(_ text: String) -> Date? {
        if let date = isoFractional.date(from: text) { return date }
        let plain = text.replacingOccurrences(of: #"\.\d+"#, with: "", options: .regularExpression)
        return iso.date(from: plain)
    }

    // MARK: Piano

    private var lastUsage = PlanUsage()
    private var configDate: Date?

    /// Riletto solo se `~/.claude.json` è cambiato; se in quel momento è a metà scrittura resta l'ultimo valore buono;
    /// le finestre già ripartite non si mostrano (la percentuale vecchia non vale più).
    private func readPlanUsage() -> PlanUsage {
        let modified = (try? Self.config.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        if modified == nil || modified != configDate, let fresh = parsePlanUsage() {
            lastUsage = fresh
            configDate = modified
        }
        var usage = lastUsage
        usage.windows = usage.windows.filter { ($0.resets ?? .distantFuture) > Date() }
        return usage
    }

    private func parsePlanUsage() -> PlanUsage? {
        guard let data = try? Data(contentsOf: Self.config),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let cached = object["cachedUsageUtilization"] as? [String: Any],
              let utilization = cached["utilization"] as? [String: Any] else { return nil }
        var usage = PlanUsage()
        let names: [(String, String)] = [
            ("five_hour", String(localized: "Sessione")),
            ("seven_day", String(localized: "Settimana")),
            ("seven_day_opus", String(localized: "Settimana, Opus")),
            ("seven_day_sonnet", String(localized: "Settimana, Sonnet")),
        ]
        for (key, title) in names {
            guard let window = utilization[key] as? [String: Any],
                  let percent = (window["utilization"] as? NSNumber)?.doubleValue else { continue }
            let resets = (window["resets_at"] as? String).flatMap(parseDate)
            usage.windows.append(.init(title: title, percent: percent, resets: resets))
        }
        return usage
    }
}

// MARK: - Codex

/// I prezzi API di OpenAI per milione di token: ingresso, ingresso in cache, uscita. Per gpt-5.6 sono quelli dopo il
/// taglio del 30 luglio 2026, da fonti pubbliche concordi (non dalla pagina di OpenAI, che non è leggibile da qui).
/// gpt-6-astra non ha ancora un prezzo pubblico: i suoi token si contano, il costo no.
enum OpenAIPricing {
    private static let table: [(String, (input: Double, cached: Double, output: Double))] = [
        ("gpt-5.6-sol", (4, 0.40, 20)),
        ("gpt-5.6-terra", (2, 0.20, 12)),
        ("gpt-5.6-luna", (0.20, 0.02, 1.20)),
    ]

    static func price(for model: String) -> (input: Double, cached: Double, output: Double)? {
        let m = model.lowercased()
        return table.first { m.contains($0.0) }?.1
    }

    static func displayName(_ model: String) -> String {
        model.replacingOccurrences(of: "gpt-", with: "GPT-").replacingOccurrences(of: "-", with: " ")
    }
}

/// I token di ChatGPT dai registri di Codex (`~/.codex/sessions`): ogni evento `token_count` porta il totale della
/// sessione, e la differenza col precedente è il consumo di quel turno (così i doppioni non contano). L'utilizzo del
/// piano è nei `rate_limits` dell'ultimo evento, finché la finestra non è ripartita.
final class CodexStatsStore: @unchecked Sendable {
    static let shared = CodexStatsStore()

    private struct FileState {
        var offset: UInt64 = 0
        var input = 0, cached = 0, written = 0, output = 0
        var model = ""
    }
    private struct Bucket {
        var input = 0, cached = 0, written = 0, output = 0
    }

    private let queue = DispatchQueue(label: "charland.codex-stats", qos: .utility)
    private var files: [String: FileState] = [:]
    /// «giorno|modello» → token.
    private var buckets: [String: Bucket] = [:]
    private var lastLimits: (date: Date, windows: [PlanUsage.Window])?
    private let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private let plainISO = ISO8601DateFormatter()
    private static let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/sessions")

    func refresh(_ done: @escaping @MainActor ([AgentPeriod: AgentPeriodStats], PlanUsage) -> Void) {
        queue.async { [self] in
            scan()
            let stats = Dictionary(uniqueKeysWithValues: AgentPeriod.allCases.map { ($0, summary(for: $0)) })
            var usage = PlanUsage()
            // Solo finestre ancora valide: dopo la ripartenza la percentuale vecchia non vale più.
            if let limits = lastLimits { usage.windows = limits.windows.filter { ($0.resets ?? .distantFuture) > Date() } }
            DispatchQueue.main.async { MainActor.assumeIsolated { done(stats, usage) } }
        }
    }

    private static func dayIndex(_ date: Date) -> Int {
        Int((Calendar.current.startOfDay(for: date).timeIntervalSinceReferenceDate / 86_400).rounded())
    }

    private func scan() {
        let horizon = Date().addingTimeInterval(-31 * 86_400)
        guard let walker = FileManager.default.enumerator(at: Self.root, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
                                                          options: [.skipsHiddenFiles]) else { return }
        for case let url as URL in walker where url.pathExtension == "jsonl" {
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            guard let modified = values?.contentModificationDate, modified > horizon, let size = values?.fileSize else { continue }
            var state = files[url.path] ?? FileState()
            if UInt64(size) < state.offset { state = FileState() }   // riscritto da capo
            guard UInt64(size) > state.offset, let handle = FileHandle(forReadingAtPath: url.path) else { continue }
            try? handle.seek(toOffset: state.offset)
            let data = (try? handle.readToEnd()) ?? Data()
            try? handle.close()
            // Solo righe intere: l'ultima a metà si rilegge la prossima volta.
            guard let lastNewline = data.lastIndex(of: 0x0A) else { continue }
            let whole = data[data.startIndex...lastNewline]
            state.offset += UInt64(whole.count)
            autoreleasepool {
                for line in whole.split(separator: 0x0A) where line.count > 20 {
                    take(Data(line), into: &state)
                }
            }
            files[url.path] = state
        }
        let oldest = Self.dayIndex(Date()) - 31
        buckets = buckets.filter { (Int($0.key.split(separator: "|").first ?? "") ?? 0) >= oldest }
    }

    private func take(_ line: Data, into state: inout FileState) {
        let isTurn = line.range(of: Data(#""turn_context""#.utf8)) != nil
        let isCount = line.range(of: Data(#""token_count""#.utf8)) != nil
        guard isTurn || isCount,
              let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let payload = object["payload"] as? [String: Any] else { return }
        if isTurn, let model = payload["model"] as? String { state.model = model; return }
        guard payload["type"] as? String == "token_count",
              let stamp = object["timestamp"] as? String,
              let date = iso.date(from: stamp) ?? plainISO.date(from: stamp) else { return }
        func int(_ key: String, _ dict: [String: Any]) -> Int { (dict[key] as? NSNumber)?.intValue ?? 0 }
        if let info = payload["info"] as? [String: Any], let total = info["total_token_usage"] as? [String: Any] {
            let input = int("input_tokens", total), cached = int("cached_input_tokens", total)
            let written = int("cache_write_input_tokens", total), output = int("output_tokens", total)
            // Un totale che scende è una sessione ripartita: conta da zero.
            let restarted = input < state.input || output < state.output
            let key = "\(Self.dayIndex(date))|\(state.model)"
            var bucket = buckets[key] ?? Bucket()
            bucket.input += restarted ? input : input - state.input
            bucket.cached += restarted ? cached : max(0, cached - state.cached)
            bucket.written += restarted ? written : max(0, written - state.written)
            bucket.output += restarted ? output : output - state.output
            buckets[key] = bucket
            state.input = input; state.cached = cached; state.written = written; state.output = output
        }
        if let limits = payload["rate_limits"] as? [String: Any], lastLimits.map({ date > $0.date }) ?? true {
            var windows: [PlanUsage.Window] = []
            for key in ["secondary", "primary"] {
                guard let window = limits[key] as? [String: Any],
                      let percent = (window["used_percent"] as? NSNumber)?.doubleValue else { continue }
                let minutes = (window["window_minutes"] as? NSNumber)?.intValue ?? 0
                let resets = (window["resets_at"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
                let title = minutes == 0 ? String(localized: "Limite")
                    : minutes <= 300 ? String(localized: "Sessione") : minutes >= 10_080 ? String(localized: "Settimana")
                    : String(localized: "\(minutes / 60) ore")
                windows.append(.init(title: title, percent: percent, resets: resets))
            }
            lastLimits = (date, windows.sorted { $0.title == String(localized: "Sessione") && $1.title != String(localized: "Sessione") })
        }
    }

    private func summary(for period: AgentPeriod) -> AgentPeriodStats {
        let first = Self.dayIndex(Date()) - (period.days - 1)
        var stats = AgentPeriodStats()
        var byModel: [String: (cost: Double, tokens: Int)] = [:]
        for (key, b) in buckets {
            let parts = key.split(separator: "|", maxSplits: 1)
            guard let day = Int(parts.first ?? ""), day >= first else { continue }
            let model = parts.count > 1 ? String(parts[1]) : ""
            let fresh = max(0, b.input - b.cached)
            stats.input += fresh
            stats.cacheRead += b.cached
            stats.cacheWrite += b.written
            stats.output += b.output
            var cost = 0.0
            if let p = OpenAIPricing.price(for: model) {
                // OpenAI non fa pagare le scritture in cache: ingresso nuovo, ingresso in cache, uscita.
                cost = (Double(fresh) * p.input + Double(b.cached) * p.cached + Double(b.output) * p.output) / 1_000_000
            }
            stats.cost += cost
            let name = OpenAIPricing.displayName(model.isEmpty ? "ChatGPT" : model)
            byModel[name, default: (0, 0)].cost += cost
            byModel[name, default: (0, 0)].tokens += b.input + b.output
        }
        stats.models = byModel.map { (name: $0.key, cost: $0.value.cost, tokens: $0.value.tokens) }.sorted { $0.cost > $1.cost }
        return stats
    }
}
