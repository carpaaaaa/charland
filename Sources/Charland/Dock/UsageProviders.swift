import AppKit
import SwiftUI
import CharlandKit

/// L'utilizzo degli agenti AI accanto al Dock (carpa, 17 novembre 2026: «la possibilità di vedere l'usage degli agenti
/// AI come Claude, ChatGPT, Gemini, e scegliere quale vedere anche direttamente lì nel Dock»).
///
/// Charland non legge credenziali e non parla con nessun server: guarda quello che gli agenti lasciano sul Mac e, per
/// i numeri freschi, lo chiede al loro stesso comando da terminale (`claude`, `codex`), che risponde senza consumare
/// token. Provato il 17 novembre 2026:
/// - Claude: `claude -p /usage` non fa nessun turno (0 token) e aggiorna `cachedUsageUtilization` in `~/.claude.json`,
///   con percentuale e ora di ripartenza di ogni limite;
/// - ChatGPT: `codex app-server` risponde a `account/rateLimits/read` con i limiti del piano; senza il comando restano
///   gli ultimi limiti scritti nei registri in `~/.codex/sessions`;
/// - Gemini: da terminale tiene i token di ogni risposta in `~/.gemini/tmp`, ma nessuna percentuale.
enum UsageProviderID: String, CaseIterable, Identifiable, Sendable, Codable {
    case claude, chatgpt, gemini

    var id: String { rawValue }

    var title: String {
        switch self {
        case .claude: "Claude"
        case .chatgpt: "ChatGPT"
        case .gemini: "Gemini"
        }
    }

    /// Lo stesso agente come lo conosce l'isola: da lì vengono colori e forma della mascotte.
    var kind: AgentKind {
        switch self {
        case .claude: .claude
        case .chatgpt: .codex
        case .gemini: .gemini
        }
    }

    /// Le app da aprire con «Apri», dalla prima che c'è.
    var appBundleIDs: [String] {
        switch self {
        case .claude: ["com.anthropic.claudefordesktop"]
        case .chatgpt: ["com.openai.chat", "com.openai.codex"]
        // Gemini da terminale non ha un'app sua da aprire.
        case .gemini: []
        }
    }

    /// Cosa manca quando non si trova sul Mac.
    var missingHint: String {
        switch self {
        case .claude: String(localized: "Serve Claude Code su questo Mac.")
        case .chatgpt: String(localized: "Serve Codex su questo Mac.")
        case .gemini: String(localized: "Serve Gemini da terminale su questo Mac.")
        }
    }
}

/// Un limite del piano: quanto è pieno e quando riparte.
struct UsageWindow: Equatable, Sendable, Identifiable {
    var id: String
    var title: String
    /// Quanto è stato usato, da 0 a 100.
    var percent: Double
    var resets: Date?
    /// Quanto dura la finestra (5 ore, una settimana): serve per il ritmo.
    var length: TimeInterval?

    /// Dove dovresti essere adesso andando a passo costante, da 0 a 1. `nil` se la finestra non ha una durata nota.
    func elapsed(at now: Date = Date()) -> Double? {
        guard let resets, let length, length > 0 else { return nil }
        return min(1, max(0, 1 - resets.timeIntervalSince(now) / length))
    }

    /// A questo ritmo: la percentuale all'ora della ripartenza, e se si arriva al 100% prima, quando.
    func projection(at now: Date = Date()) -> (atReset: Double, runsOut: Date?)? {
        guard let resets, let length, let elapsed = elapsed(at: now), elapsed > 0.04, percent > 0 else { return nil }
        let atReset = percent / elapsed
        guard atReset > 100 else { return (atReset, nil) }
        let start = resets.addingTimeInterval(-length)
        return (atReset, start.addingTimeInterval(length * elapsed * 100 / percent))
    }
}

/// Quello che si sa di un agente in questo momento.
struct UsageSnapshot: Equatable, Sendable {
    var windows: [UsageWindow] = []
    var plan: String?
    var tokensToday: Int?
    /// Quanto sarebbero costati i token di oggi alle tariffe delle API.
    var costToday: Double?
    var requestsToday: Int?
    /// Quando i limiti sono stati chiesti all'agente.
    var fetched: Date?

    /// Il limite più vicino a riempirsi: è quello che mostra l'anello nel Dock.
    var headline: UsageWindow? { windows.max { $0.percent < $1.percent } }

    var isEmpty: Bool { windows.isEmpty && tokensToday == nil && requestsToday == nil }
}

enum UsageText {
    /// «2 g 4 h», «3 h 12 min», «8 min»: quanto manca alla ripartenza.
    static func remaining(until date: Date, from now: Date = Date()) -> String {
        let seconds = max(0, date.timeIntervalSince(now))
        let minutes = Int((seconds / 60).rounded(.up))
        if minutes >= 24 * 60 {
            let days = minutes / (24 * 60), hours = (minutes % (24 * 60)) / 60
            return hours == 0 ? String(localized: "\(days) g") : String(localized: "\(days) g \(hours) h")
        }
        if minutes >= 60 {
            let hours = minutes / 60, rest = minutes % 60
            return rest == 0 ? String(localized: "\(hours) h") : String(localized: "\(hours) h \(rest) min")
        }
        return String(localized: "\(max(1, minutes)) min")
    }

    /// «gio 14:59», oppure solo l'ora se è oggi.
    static func moment(_ date: Date, now: Date = Date()) -> String {
        if Calendar.current.isDate(date, inSameDayAs: now) { return date.formatted(.dateTime.hour().minute()) }
        return date.formatted(.dateTime.weekday(.abbreviated).hour().minute())
    }

    static func compact(_ value: Int) -> String {
        value.formatted(.number.notation(.compactName).precision(.fractionLength(0...1)))
    }

    /// Dollari, scritti allo stesso modo in ogni lingua: «$215», «$4.20».
    static func money(_ value: Double) -> String {
        "$" + value.formatted(.number.precision(.fractionLength(value >= 100 ? 0 : 2)))
    }

    /// Il titolo di una finestra dalla sua durata in minuti: «Sessione» (5 ore), «Settimana», «Mese».
    static func title(minutes: Int) -> String {
        switch minutes {
        case ..<1: return String(localized: "Limite")
        case 1...360: return String(localized: "Sessione")
        case 361...1500: return String(localized: "Giorno")
        case 1501...11_000: return String(localized: "Settimana")
        default: return String(localized: "Mese")
        }
    }

    /// Le date degli agenti hanno fino a 6 decimali, che il lettore di Apple può rifiutare: senza decimali si leggono sempre.
    static func date(_ text: String) -> Date? {
        let plain = text.replacingOccurrences(of: #"\.\d+"#, with: "", options: .regularExpression)
        return ISO8601DateFormatter().date(from: plain)
    }
}

// MARK: - Comandi da terminale

/// Trova ed esegue i comandi degli agenti. Mai le credenziali: è il comando dell'agente a parlare col suo servizio.
enum AgentCLI {
    private static let home = FileManager.default.homeDirectoryForCurrentUser

    /// Dove può stare un comando: le cartelle solite di chi installa a mano, con npm, bun, volta o Homebrew (anche
    /// quello nella cartella personale), e quelle di nvm, la versione più nuova prima.
    static func find(_ name: String) -> URL? {
        let fm = FileManager.default
        var folders = [".local/bin", ".claude/local", "homebrew/bin", ".bun/bin", ".volta/bin", ".npm-global/bin", "bin"]
            .map { home.appendingPathComponent($0) }
        folders += ["/opt/homebrew/bin", "/usr/local/bin"].map { URL(fileURLWithPath: $0) }
        let nvm = home.appendingPathComponent(".nvm/versions/node")
        if let versions = try? fm.contentsOfDirectory(at: nvm, includingPropertiesForKeys: [.contentModificationDateKey]) {
            let sorted = versions.sorted {
                let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return a > b
            }
            folders += sorted.map { $0.appendingPathComponent("bin") }
        }
        for folder in folders {
            let url = folder.appendingPathComponent(name)
            if fm.isExecutableFile(atPath: url.path) { return url }
        }
        return nil
    }

    /// Un ambiente pulito: niente di quello che Charland ha ereditato da chi l'ha aperta (un terminale, un altro
    /// agente) deve cambiare con quale accesso risponde il comando.
    static func environment(for tool: URL) -> [String: String] {
        let inherited = ProcessInfo.processInfo.environment
        var env: [String: String] = [
            "HOME": home.path,
            // Accanto al comando, poi dove Homebrew e gli installatori mettono `node`: un `claude` o un `codex` installato
            // con npm comincia con `#!/usr/bin/env node`, e senza queste cartelle da un'app aperta dal Finder non partiva.
            "PATH": [tool.deletingLastPathComponent().path, tool.resolvingSymlinksInPath().deletingLastPathComponent().path,
                     "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"].joined(separator: ":"),
            "LANG": "en_US.UTF-8",
            "TERM": "dumb",
        ]
        for key in ["USER", "LOGNAME", "TMPDIR", "SHELL"] {
            if let value = inherited[key] { env[key] = value }
        }
        return env
    }

    /// Una cartella tutta di Charland da cui lanciare i comandi: gli agenti ricordano da dove vengono chiamati, e così
    /// ne ricordano una sola.
    static var workFolder: URL {
        let folder = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.charstudio.charland/agenti")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    /// Esegue un comando e ne restituisce l'uscita. `input` viene scritto e poi chiuso; allo scadere del tempo il
    /// comando viene fermato. `until` può fermarlo prima, appena l'uscita contiene quello che serve.
    static func run(_ tool: URL, _ arguments: [String], input: String? = nil, keepInputOpen: Bool = false,
                    timeout: TimeInterval, until: (@Sendable (String) -> Bool)? = nil) -> String? {
        let process = Process()
        process.executableURL = tool
        process.arguments = arguments
        process.environment = environment(for: tool)
        process.currentDirectoryURL = workFolder
        // In fondo alla fila: il comando di Claude lavora qualche secondo, e non deve togliere fotogrammi a nessuno.
        process.qualityOfService = .utility
        let output = Pipe(), stdin = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = stdin
        let collected = Collected()
        let done = DispatchSemaphore(value: 0)
        output.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                done.signal()
                return
            }
            collected.append(data)
            if let until, until(collected.text) { done.signal() }
        }
        // Se il comando muore subito, scrivergli non deve far cadere Charland (il segnale di «tubo rotto»).
        _ = fcntl(stdin.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        do { try process.run() } catch {
            output.fileHandleForReading.readabilityHandler = nil
            try? stdin.fileHandleForWriting.close()
            try? output.fileHandleForReading.close()
            return nil
        }
        if let input { try? stdin.fileHandleForWriting.write(contentsOf: Data(input.utf8)) }
        if !keepInputOpen { try? stdin.fileHandleForWriting.close() }
        _ = done.wait(timeout: .now() + timeout)
        output.fileHandleForReading.readabilityHandler = nil
        try? stdin.fileHandleForWriting.close()
        if process.isRunning {
            process.terminate()
            // Un comando che ignora il segnale non deve restare in giro.
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) { if process.isRunning { kill(process.processIdentifier, SIGKILL) } }
        }
        return collected.text
    }

    private final class Collected: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()
        func append(_ more: Data) { lock.lock(); data.append(more); lock.unlock() }
        var text: String { lock.lock(); defer { lock.unlock() }; return String(decoding: data, as: UTF8.self) }
    }
}

// MARK: - Claude

enum ClaudeUsage {
    private static let config = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude.json")

    static var detected: Bool { FileManager.default.fileExists(atPath: config.path) }

    /// Quello che Claude Code ha in cache: i limiti del piano e quando li ha chiesti.
    static func read(now: Date = Date()) -> UsageSnapshot {
        guard let data = try? Data(contentsOf: config),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return UsageSnapshot() }
        return parse(object, now: now)
    }

    static func parse(_ object: [String: Any], now: Date) -> UsageSnapshot {
        var snapshot = UsageSnapshot()
        snapshot.plan = (object["oauthAccount"] as? [String: Any])?["planDisplayName"] as? String
        guard let cached = object["cachedUsageUtilization"] as? [String: Any],
              let utilization = cached["utilization"] as? [String: Any] else { return snapshot }
        if let ms = (cached["fetchedAtMs"] as? NSNumber)?.doubleValue { snapshot.fetched = Date(timeIntervalSince1970: ms / 1000) }

        if let limits = utilization["limits"] as? [[String: Any]], !limits.isEmpty {
            // La forma nuova: un elenco di limiti, ognuno col suo gruppo e, se riguarda un modello solo, il suo nome.
            for limit in limits {
                guard let percent = (limit["percent"] as? NSNumber)?.doubleValue else { continue }
                let kind = limit["kind"] as? String ?? ""
                let group = limit["group"] as? String ?? kind
                let model = ((limit["scope"] as? [String: Any])?["model"] as? [String: Any])?["display_name"] as? String
                let (base, length) = family(group: group, kind: kind)
                let title = model.map { String(localized: "\(base), \($0)") } ?? base
                snapshot.windows.append(UsageWindow(id: kind + (model.map { ":" + $0 } ?? ""), title: title, percent: percent,
                                                    resets: (limit["resets_at"] as? String).flatMap(UsageText.date), length: length))
            }
        } else {
            // La forma di prima: una voce per finestra.
            let names: [(String, String, TimeInterval)] = [
                ("five_hour", String(localized: "Sessione"), 5 * 3600),
                ("seven_day", String(localized: "Settimana"), 7 * 86_400),
                ("seven_day_opus", String(localized: "Settimana, Opus"), 7 * 86_400),
                ("seven_day_sonnet", String(localized: "Settimana, Sonnet"), 7 * 86_400),
            ]
            for (key, title, length) in names {
                guard let window = utilization[key] as? [String: Any],
                      let percent = (window["utilization"] as? NSNumber)?.doubleValue else { continue }
                snapshot.windows.append(UsageWindow(id: key, title: title, percent: percent,
                                                    resets: (window["resets_at"] as? String).flatMap(UsageText.date), length: length))
            }
        }
        var seen: [String: Int] = [:]
        snapshot.windows = snapshot.windows.map { window in
            var window = rolled(window, now: now)
            // Due limiti con lo stesso nome restano distinti: servono identificativi unici per le righe e per gli avvisi.
            seen[window.id, default: 0] += 1
            if let count = seen[window.id], count > 1 { window.id += "#\(count)" }
            return window
        }
        return snapshot
    }

    private static func family(group: String, kind: String) -> (String, TimeInterval?) {
        let name = (group + " " + kind).lowercased()
        if name.contains("week") || name.contains("seven_day") { return (String(localized: "Settimana"), 7 * 86_400) }
        if name.contains("session") || name.contains("five_hour") || name.contains("hour") { return (String(localized: "Sessione"), 5 * 3600) }
        if name.contains("month") { return (String(localized: "Mese"), 30 * 86_400) }
        if name.contains("day") || name.contains("daily") { return (String(localized: "Giorno"), 86_400) }
        return (String(localized: "Limite"), nil)
    }

    /// Una finestra già ripartita da quando è stata letta: riparte da zero, con la prossima scadenza.
    static func rolled(_ window: UsageWindow, now: Date) -> UsageWindow {
        guard let resets = window.resets, resets <= now else { return window }
        var next = window
        next.percent = 0
        if let length = window.length, length > 0 {
            let periods = (now.timeIntervalSince(resets) / length).rounded(.down) + 1
            next.resets = resets.addingTimeInterval(periods * length)
        } else {
            next.resets = nil
        }
        return next
    }

    /// Se un giorno `/usage` non fosse più un comando, la domanda finirebbe al modello e costerebbe token a ogni
    /// lettura: la prima volta che succede (un turno fatto) Charland smette di chiedere, finché Claude Code non cambia versione.
    private static let blockedKey = "dockClaudeUsageBlocked"

    /// Chiede a Claude Code l'utilizzo di adesso: `/usage` non fa nessun turno (zero token) e riscrive la cache.
    /// Qualche secondo, tutto del comando `claude`: senza server MCP, senza le impostazioni dell'utente, senza registro.
    static func refreshLive() -> Bool {
        guard let tool = AgentCLI.find("claude") else { return false }
        let version = ((try? tool.resolvingSymlinksInPath().resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
            .map { "\(Int($0.timeIntervalSince1970))" }) ?? "?"
        guard UserDefaults.standard.string(forKey: blockedKey) != version else { return false }
        let before = read().fetched
        let output = AgentCLI.run(tool, ["-p", "/usage", "--output-format", "json", "--no-session-persistence", "--max-turns", "0",
                                         "--setting-sources", "project", "--strict-mcp-config", "--mcp-config", #"{"mcpServers":{}}"#],
                                  timeout: 45)
        if let output, let object = try? JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any],
           let turns = (object["num_turns"] as? NSNumber)?.intValue, turns > 0 {
            UserDefaults.standard.set(version, forKey: blockedKey)
            return false
        }
        guard let after = read().fetched else { return false }
        return before.map { after > $0 } ?? true
    }
}

// MARK: - ChatGPT (Codex)

enum CodexUsage {
    private static let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
    private static let sessions = root.appendingPathComponent("sessions")

    static var detected: Bool { FileManager.default.fileExists(atPath: root.path) }

    /// Gli ultimi limiti scritti nei registri: ogni risposta li porta con sé.
    static func read(now: Date = Date()) -> UsageSnapshot {
        var snapshot = UsageSnapshot()
        for file in recentFiles(limit: 6) {
            if let (limits, stamp) = lastLimits(in: file) {
                apply(limits: limits, to: &snapshot, now: now)
                snapshot.fetched = stamp
                break
            }
        }
        return snapshot
    }

    /// I limiti chiesti al comando `codex`: lo stesso canale che usa la sua app.
    static func readLive(now: Date = Date()) -> UsageSnapshot? {
        guard let tool = AgentCLI.find("codex") else { return nil }
        let hello = #"{"method":"initialize","id":0,"params":{"clientInfo":{"name":"charland","title":"Charland","version":"1.0.0"}}}"#
        let ask = #"{"method":"initialized","params":{}}"# + "\n" + #"{"method":"account/rateLimits/read","id":1}"#
        let output = AgentCLI.run(tool, ["app-server"], input: hello + "\n" + ask + "\n", keepInputOpen: true, timeout: 20) { text in
            // La risposta alla domanda numero 1, riuscita o no (non la 10 o la 12 di un altro messaggio).
            // E arrivata fino in fondo alla riga: un pezzo a metà non si legge.
            text.hasSuffix("\n") && (text.contains(#""id":1,"result""#) || text.contains(#""id":1,"error""#))
        }
        guard let output else { return nil }
        for line in output.split(separator: "\n") {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  (object["id"] as? NSNumber)?.intValue == 1,
                  let result = object["result"] as? [String: Any],
                  let limits = result["rateLimits"] as? [String: Any] else { continue }
            var snapshot = UsageSnapshot()
            apply(limits: limits, to: &snapshot, now: now)
            snapshot.fetched = now
            return snapshot
        }
        return nil
    }

    /// I limiti hanno due forme: nei registri `used_percent`, `window_minutes`, `resets_at`; dal comando le stesse voci
    /// scritte `usedPercent`, `windowDurationMins`, `resetsAt`.
    static func apply(limits: [String: Any], to snapshot: inout UsageSnapshot, now: Date) {
        func number(_ dict: [String: Any], _ keys: String...) -> Double? {
            for key in keys { if let value = (dict[key] as? NSNumber)?.doubleValue { return value } }
            return nil
        }
        snapshot.windows = []
        for slot in ["primary", "secondary"] {
            guard let window = limits[slot] as? [String: Any],
                  let percent = number(window, "used_percent", "usedPercent") else { continue }
            let minutes = Int(number(window, "window_minutes", "windowDurationMins") ?? 0)
            let resets = number(window, "resets_at", "resetsAt").map { Date(timeIntervalSince1970: $0) }
            let item = UsageWindow(id: slot, title: UsageText.title(minutes: minutes), percent: percent, resets: resets,
                                   length: minutes > 0 ? Double(minutes) * 60 : nil)
            snapshot.windows.append(ClaudeUsage.rolled(item, now: now))
        }
        if let plan = (limits["plan_type"] ?? limits["planType"]) as? String, !plan.isEmpty {
            snapshot.plan = planName(plan)
        }
    }

    static func planName(_ raw: String) -> String {
        switch raw.lowercased() {
        case "prolite": "Pro Lite"
        case "edu": "Edu"
        default: raw.prefix(1).uppercased() + raw.dropFirst()
        }
    }

    // MARK: Registri

    /// I registri più recenti: le cartelle sono anno/mese/giorno, si scende dalle ultime.
    private static func recentFiles(limit: Int) -> [URL] {
        let fm = FileManager.default
        func children(_ url: URL) -> [URL] {
            ((try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? [])
                .sorted { $0.lastPathComponent > $1.lastPathComponent }
        }
        var found: [URL] = []
        for year in children(sessions) {
            for month in children(year) {
                for day in children(month) {
                    let logs = children(day).filter { $0.pathExtension == "jsonl" }
                    found += logs
                    if found.count >= limit { return Array(found.prefix(limit)) }
                }
            }
        }
        return found
    }

    /// L'ultima riga con i limiti, cercata nella coda del registro.
    private static func lastLimits(in file: URL) -> ([String: Any], Date)? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: size > 600_000 ? size - 600_000 : 0)
        guard let data = try? handle.readToEnd() else { return nil }
        let marker = Data(#""rate_limits""#.utf8)
        for line in data.split(separator: 0x0A).reversed() where line.range(of: marker) != nil {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  let payload = object["payload"] as? [String: Any],
                  let limits = payload["rate_limits"] as? [String: Any] else { continue }
            let stamp = (object["timestamp"] as? String).flatMap(UsageText.date) ?? Date()
            return (limits, stamp)
        }
        return nil
    }
}

// MARK: - Gemini

enum GeminiUsage {
    private static let chats = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".gemini/tmp")

    /// Gemini da terminale tiene le conversazioni in `~/.gemini/tmp`. Antigravity non lascia niente da leggere.
    static var detected: Bool { FileManager.default.fileExists(atPath: chats.path) }

    /// I token e le risposte di oggi. Gemini non scrive sul Mac nessuna percentuale del piano.
    static func read(now: Date = Date(), root: URL? = nil) -> UsageSnapshot {
        var snapshot = UsageSnapshot()
        let fm = FileManager.default
        let today = Calendar.current.startOfDay(for: now)
        guard let walker = fm.enumerator(at: root ?? chats, includingPropertiesForKeys: [.contentModificationDateKey],
                                         options: [.skipsHiddenFiles]) else { return snapshot }
        var tokens = 0, requests = 0, any = false
        for case let url as URL in walker where url.pathExtension == "json" && url.deletingLastPathComponent().lastPathComponent == "chats" {
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            guard modified >= today, let data = try? Data(contentsOf: url),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let messages = object["messages"] as? [[String: Any]] else { continue }
            for message in messages where message["type"] as? String == "gemini" {
                guard let stamp = (message["timestamp"] as? String).flatMap(UsageText.date), stamp >= today else { continue }
                requests += 1
                any = true
                if let total = ((message["tokens"] as? [String: Any])?["total"] as? NSNumber)?.intValue { tokens += total }
            }
        }
        if any {
            snapshot.tokensToday = tokens
            snapshot.requestsToday = requests
        }
        // Niente «letto adesso»: Gemini non ha limiti da rinfrescare, e un'ora che cambia a ogni lettura farebbe
        // sembrare nuova una lettura identica.
        return snapshot
    }
}

// MARK: - Tutto insieme

/// Tiene i numeri di ogni agente. Le letture girano in sottofondo; i numeri freschi si chiedono solo quando qualcuno
/// guarda (il Dock sale, il cassetto si apre) e mai più spesso di qualche minuto.
@MainActor @Observable
final class UsageStore {
    static let shared = UsageStore()

    private(set) var snapshots: [UsageProviderID: UsageSnapshot] = [:]
    /// Gli agenti che su questo Mac hanno lasciato qualcosa da leggere.
    private(set) var detected: [UsageProviderID] = []
    /// Chi sta chiedendo i numeri freschi in questo momento.
    private(set) var refreshing: Set<UsageProviderID> = []

    @ObservationIgnored private let queue = DispatchQueue(label: "charland.usage", qos: .utility)
    @ObservationIgnored private var lastLocal = Date.distantPast
    @ObservationIgnored private var lastTokens = Date.distantPast
    /// Una lettura è in corso: chi chiede intanto viene servito alla fine, con l'età più stretta fra quelle chieste.
    @ObservationIgnored private var reading = false
    @ObservationIgnored private var waitingAge: TimeInterval?
    @ObservationIgnored private var lastLive: [UsageProviderID: Date] = [:]
    /// Quante volte di fila il comando di un agente non ha risposto: ogni volta si aspetta il doppio prima di riprovare.
    @ObservationIgnored private var failures: [UsageProviderID: Int] = [:]
    @ObservationIgnored private var alertTimer: Timer?

    /// Quanto possono essere vecchi i numeri quando il Dock sale, e quando apri il cassetto. Chiedere a Claude costa
    /// qualche secondo di processore al suo comando: non si fa a ogni sguardo.
    static let glanceAge: TimeInterval = 10 * 60
    static let lookAge: TimeInterval = 2 * 60

    private init() {
        detected = Self.detect()
    }

    private nonisolated static func detect() -> [UsageProviderID] {
        UsageProviderID.allCases.filter {
            switch $0 {
            case .claude: ClaudeUsage.detected
            case .chatgpt: CodexUsage.detected
            case .gemini: GeminiUsage.detected
            }
        }
    }

    /// Rilegge quello che c'è sul Mac e poi, se i limiti sono più vecchi di `maxAge`, li chiede agli agenti. Sempre in
    /// quest'ordine: quanto sono vecchi lo dice solo la lettura (Claude Code può averli già aggiornati per conto suo).
    func refresh(maxAge: TimeInterval) {
        guard !reading else {
            waitingAge = min(waitingAge ?? maxAge, maxAge)
            return
        }
        let now = Date()
        guard now.timeIntervalSince(lastLocal) > 4 || snapshots.isEmpty else {
            askLive(maxAge: maxAge)
            return
        }
        lastLocal = now
        reading = true
        queue.async { [weak self] in
            let found = Self.detect()
            var read: [UsageProviderID: UsageSnapshot] = [:]
            for provider in found {
                switch provider {
                case .claude: read[provider] = ClaudeUsage.read()
                case .chatgpt: read[provider] = CodexUsage.read()
                case .gemini: read[provider] = GeminiUsage.read()
                }
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if self.detected != found {
                        self.detected = found
                        DockBar.shared.dataChanged()
                    }
                    for (provider, snapshot) in read { self.merge(snapshot, for: provider, live: false) }
                    self.readTokens()
                    self.reading = false
                    let age = min(self.waitingAge ?? maxAge, maxAge)
                    self.waitingAge = nil
                    self.askLive(maxAge: age)
                }
            }
        }
    }

    /// Per i disegni di prova: numeri finti al posto di quelli veri.
    func useSample(_ sample: [UsageProviderID: UsageSnapshot]) {
        snapshots = sample
        detected = UsageProviderID.allCases.filter { sample[$0] != nil }
    }

    /// Chiede i limiti ai comandi degli agenti, se sono vecchi e se il widget è acceso: spento, non parte niente.
    private func askLive(maxAge: TimeInterval) {
        let settings = DockSettings.shared
        guard settings.live, settings.isOn(.usage) else { return }
        let now = Date()
        // Solo gli agenti che vuoi vedere: uno spento nelle impostazioni non viene interrogato.
        for provider in settings.providers where provider != .gemini && !refreshing.contains(provider) {
            // Un tentativo ogni due minuti al massimo; se il comando non risponde (non c'è, non hai fatto l'accesso)
            // si aspetta ogni volta il doppio, fino a un'ora.
            let patience = min(3600, Self.lookAge * pow(2, Double(failures[provider] ?? 0)))
            if let last = lastLive[provider], now.timeIntervalSince(last) < patience { continue }
            guard now.timeIntervalSince(snapshots[provider]?.fetched ?? .distantPast) > maxAge else { continue }
            lastLive[provider] = now
            refreshing.insert(provider)
            // Fuori dalla coda delle letture: il comando di Claude lavora qualche secondo, e intanto i numeri che sono
            // già sul Mac devono poter arrivare.
            DispatchQueue.global(qos: .utility).async { [weak self] in
                var fresh: UsageSnapshot?
                switch provider {
                case .claude: if ClaudeUsage.refreshLive() { fresh = ClaudeUsage.read() }
                case .chatgpt: fresh = CodexUsage.readLive()
                case .gemini: break
                }
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        self.refreshing.remove(provider)
                        self.failures[provider] = fresh == nil ? (self.failures[provider] ?? 0) + 1 : 0
                        if let fresh { self.merge(fresh, for: provider, live: true) }
                    }
                }
            }
        }
    }

    /// I token e il prezzo API di oggi per Claude e ChatGPT vengono dai lettori dei registri della scheda degli agenti:
    /// gli stessi numeri, contati una volta sola. Al massimo ogni mezzo minuto.
    private func readTokens() {
        let now = Date()
        guard now.timeIntervalSince(lastTokens) > 30 else { return }
        lastTokens = now
        let shown = DockSettings.shared.providers
        if shown.contains(.claude) {
            AgentStatsStore.shared.refresh { [weak self] stats, _ in self?.setTokens(.claude, stats[.today]) }
        }
        if shown.contains(.chatgpt) {
            CodexStatsStore.shared.refresh { [weak self] stats, _ in self?.setTokens(.chatgpt, stats[.today]) }
        }
    }

    private func setTokens(_ provider: UsageProviderID, _ today: AgentPeriodStats?) {
        guard let today else { return }
        // Zero (dopo mezzanotte, prima del primo messaggio) vuol dire niente da mostrare, non il numero di ieri.
        let tokens: Int? = today.tokens > 0 ? today.tokens : nil
        let cost: Double? = today.cost > 0 ? today.cost : nil
        var snapshot = snapshots[provider] ?? UsageSnapshot()
        guard snapshot.tokensToday != tokens || snapshot.costToday != cost else { return }
        snapshot.tokensToday = tokens
        snapshot.costToday = cost
        snapshots[provider] = snapshot
        DockBar.shared.dataChanged()
    }

    /// Una lettura nuova sopra quella che c'è.
    /// - I limiti: vincono i più freschi. Una lettura senza limiti (il file di Claude letto a metà scrittura, registri
    ///   senza l'ultima riga buona) o più vecchia di quella che c'è non cancella quelli buoni.
    /// - I token di oggi: per Claude e ChatGPT arrivano da `readTokens` e qui non si toccano; Gemini li porta con la
    ///   sua lettura, che vale così com'è (anche vuota: a mezzanotte il conto riparte).
    private func merge(_ new: UsageSnapshot, for provider: UsageProviderID, live: Bool) {
        var merged = new
        if let old = snapshots[provider] {
            // Limiti senza la data di lettura (se un giorno Claude Code smettesse di scriverla) valgono come nuovi.
            let newer = new.fetched.map { $0 >= (old.fetched ?? .distantPast) } ?? true
            if !old.windows.isEmpty, new.windows.isEmpty || !newer {
                merged.windows = old.windows.map { ClaudeUsage.rolled($0, now: Date()) }
                merged.fetched = old.fetched
                merged.plan = old.plan ?? new.plan
            }
            if merged.plan == nil { merged.plan = old.plan }
            if live || provider != .gemini {
                merged.tokensToday = old.tokensToday
                merged.costToday = old.costToday
                merged.requestsToday = old.requestsToday
            }
        }
        guard snapshots[provider] != merged else { return }
        snapshots[provider] = merged
        UsageAlerts.check(provider, merged)
        DockBar.shared.dataChanged()
    }

    // MARK: Avvisi

    /// Con gli avvisi accesi i numeri si rinfrescano anche a Dock nascosto, ma solo mentre un agente sta lavorando:
    /// a Mac fermo non parte niente.
    func setAlerts(_ on: Bool) {
        // Solo se cambia: una scelta nel Dock passa di qui, e il timer non deve ripartire da capo ogni volta.
        guard on != (alertTimer != nil) else { return }
        alertTimer?.invalidate()
        alertTimer = nil
        guard on else { return }
        let timer = Timer(timeInterval: 20 * 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !AgentHub.shared.sessions.isEmpty else { return }
                self.refresh(maxAge: 15 * 60)
            }
        }
        timer.tolerance = 120
        RunLoop.main.add(timer, forMode: .common)
        alertTimer = timer
    }
}

/// Vicino al limite l'isola lo dice una volta: all'80% e al 95% di ogni finestra.
@MainActor
enum UsageAlerts {
    static let thresholds: [Double] = [80, 95]
    /// Le soglie già annunciate, per finestra: «agente.limite.ora della ripartenza» → soglia.
    private static let key = "dockUsageAlertsSeen"

    static func check(_ provider: UsageProviderID, _ snapshot: UsageSnapshot) {
        let settings = DockSettings.shared
        guard settings.alerts, settings.isOn(.usage) else { return }
        var seen = UserDefaults.standard.dictionary(forKey: key) as? [String: Double] ?? [:]
        var changed = false
        for window in snapshot.windows {
            guard let resets = window.resets else { continue }
            // L'ora arrotondata, non troncata: la ripartenza di Claude oscilla di qualche millisecondo attorno all'ora
            // piena (13:59:59,998 e 14:00:00,189 nello stesso giorno), e troncando sarebbero due finestre diverse.
            let id = "\(provider.rawValue).\(window.id).\(Int((resets.timeIntervalSince1970 / 3600).rounded()))"
            let reached = thresholds.last { window.percent.rounded() >= $0 } ?? 0
            guard reached > (seen[id] ?? 0) else { continue }
            seen[id] = reached
            changed = true
            announce(provider, window, level: reached)
        }
        guard changed else { return }
        // Le finestre già ripartite non servono più: l'ultima parte della chiave è l'ora della ripartenza.
        let hour = Int(Date().timeIntervalSince1970 / 3600)
        seen = seen.filter { (Int($0.key.split(separator: ".").last ?? "") ?? 0) >= hour - 1 }
        UserDefaults.standard.set(seen, forKey: key)
    }

    private static func announce(_ provider: UsageProviderID, _ window: UsageWindow, level: Double) {
        guard ActivityCenter.shared.isRunning else { return }
        var message = ActivityMessage(op: .upsert, client: "charland", id: "utilizzo-\(provider.rawValue)")
        message.template = .progress
        message.title = String(localized: "\(provider.title) al \(Int(window.percent.rounded()))%")
        message.subtitle = window.resets.map { String(localized: "\(window.title), riparte \(UsageText.moment($0))") } ?? window.title
        message.progress = min(1, window.percent / 100)
        message.symbol = level >= 95 ? "exclamationmark.triangle.fill" : "gauge.with.needle.fill"
        message.tint = level >= 95 ? "red" : "orange"
        message.alert = .init(expand: true, haptic: level >= 95 ? "error" : "waiting")
        // Quanto resta lo decide chi usa l'app (Generale › Isola › Durata degli avvisi, tre secondi di serie).
        message.ttl = Features.noticeTTL
        _ = ActivityCenter.shared.handle(message, from: nil)
    }
}
