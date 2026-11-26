import SwiftUI
import AppKit
import Security

/// Le cose da fare di Charcal (l'altra app di Char Studio) nel prossimo impegno, accanto agli eventi del Calendario:
/// quelle di oggi e di domani, lette dall'API di Charcal con il token personale (`chc_…`, Charcal › Impostazioni ›
/// Account › Token API). Il token sta nel Portachiavi del Mac, mai nelle impostazioni; Charland legge e basta.
@MainActor @Observable
final class CharcalAgenda {
    static let shared = CharcalAgenda()

    enum State: Equatable {
        /// Non collegato.
        case off
        /// Sta controllando un token appena incollato.
        case connecting
        case connected
        /// Collegato, ma l'ultima lettura non è riuscita (niente rete): restano le cose lette prima.
        case offline
        /// Il server ha rifiutato il token (revocato o rifatto in Charcal).
        case invalid
    }

    private(set) var state: State = .off
    /// Le cose di oggi e di domani, già nella forma degli eventi del Calendario.
    private(set) var items: [AgendaEvent] = []
    /// Perché l'ultimo collegamento non è riuscito, da scrivere nelle impostazioni.
    private(set) var problem: String?

    static let base = URL(string: "https://charcal.charstudio.app")!
    static let appBundle = "com.carpa.charcal"
    /// Dove la CLI `charcal` tiene il suo token: si legge solo se lo chiedi tu con il pulsante nelle impostazioni.
    static let cliConfig = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".config/charcal/config.json")

    @ObservationIgnored private var token: String?
    @ObservationIgnored private var active = false
    @ObservationIgnored private var loading = false
    @ObservationIgnored private var lastLoad = Date.distantPast
    @ObservationIgnored private var folders: [String: Folder] = [:]
    @ObservationIgnored private var foldersLoaded = Date.distantPast

    private struct Folder {
        let name: String
        let color: (Double, Double, Double)
    }

    private init() {
        token = CharcalKeychain.read()
        state = token == nil ? .off : .connected
    }

    /// Ci sono cose di Charcal da mostrare (anche lette prima di perdere la rete).
    var connected: Bool { state == .connected || state == .offline }

    var cliTokenAvailable: Bool { FileManager.default.fileExists(atPath: Self.cliConfig.path) }

    // MARK: Vita

    func start() {
        active = true
        refresh(look: true)
    }

    func stop() {
        active = false
        // Riacceso subito dopo deve rileggere, non aspettare la pausa fra una lettura e l'altra.
        lastLoad = .distantPast
        if !items.isEmpty {
            items = []
            AgendaStore.shared.charcalChanged()
        }
    }

    /// Rilegge se è passato abbastanza: tre quarti di minuto quando guardi (cassetto, Dock appena salito), quattro
    /// minuti se no. Le modifiche fatte in Charcal arrivano così senza tenere aperta una connessione.
    func refresh(look: Bool) {
        guard active, token != nil, state != .invalid, !loading else { return }
        guard Date().timeIntervalSince(lastLoad) > (look ? 45 : 240) else { return }
        load()
    }

    // MARK: Collegamento

    /// Controlla il token sul server (`/v1/me`) e solo se vale lo mette nel Portachiavi.
    func connect(token raw: String) {
        let candidate = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !candidate.isEmpty, state != .connecting else { return }
        problem = nil
        let before = state
        state = .connecting
        Task {
            do {
                var request = Self.request("v1/me", token: candidate)
                request.httpMethod = "GET"
                _ = try await Self.fetch(request)
                guard CharcalKeychain.save(candidate) else {
                    self.problem = String(localized: "Il Portachiavi non ha accettato il token.")
                    self.state = before == .connecting ? .off : before
                    return
                }
                self.token = candidate
                self.state = .connected
                self.lastLoad = .distantPast
                self.foldersLoaded = .distantPast
                self.folders = [:]
                if self.active { self.load() }
                AgendaStore.shared.charcalChanged()
                DockBar.shared.dataChanged()
                DayRulerStore.shared.sourcesChanged()
            } catch CharcalFailure.unauthorized {
                self.problem = String(localized: "Charcal non riconosce questo token.")
                self.state = self.token == nil ? .off : .invalid
            } catch {
                self.problem = String(localized: "Charcal non risponde. Controlla la connessione e riprova.")
                self.state = self.token == nil ? .off : before
            }
        }
    }

    /// Prende il token che la CLI `charcal` ha già su questo Mac (dopo un tuo clic, mai da solo).
    func connectFromCLI() {
        guard let data = try? Data(contentsOf: Self.cliConfig),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = object["token"] as? String, !token.isEmpty else {
            problem = String(localized: "La CLI charcal non ha ancora un token.")
            return
        }
        connect(token: token)
    }

    func disconnect() {
        CharcalKeychain.delete()
        token = nil
        state = .off
        problem = nil
        folders = [:]
        foldersLoaded = .distantPast
        if !items.isEmpty { items = [] }
        AgendaStore.shared.charcalChanged()
        // Il vassoio cambia anche senza cose da togliere: senza fonti torna a dire «Tocca per collegarlo».
        DockBar.shared.dataChanged()
        DayRulerStore.shared.sourcesChanged()
    }

    // MARK: Lettura

    private func load() {
        guard let token, !loading else { return }
        loading = true
        lastLoad = Date()
        let now = Date()
        let calendar = Calendar.current
        let today = Self.dayString(now)
        let tomorrow = Self.dayString(calendar.date(byAdding: .day, value: 1, to: now) ?? now.addingTimeInterval(86_400))
        let needFolders = Date().timeIntervalSince(foldersLoaded) > 3600
        Task {
            defer { self.loading = false }
            // Dopo ogni attesa: se nel frattempo il token è cambiato (scollegato, o collegato un altro account) o il
            // modulo è stato spento, la risposta non vale più.
            @MainActor func current() -> Bool { self.token == token && self.active }
            do {
                if needFolders {
                    // Le etichette servono solo per nomi e colori: se non arrivano restano quelle di prima, e le cose si
                    // leggono lo stesso.
                    let data = try? await Self.fetch(Self.request("v1/folders", token: token))
                    guard current() else { return }
                    if let data {
                        self.folders = Self.decodeFolders(data)
                        self.foldersLoaded = Date()
                    }
                }
                let data = try await Self.fetch(Self.request("v1/items", token: token,
                                                             query: [URLQueryItem(name: "from", value: today),
                                                                     URLQueryItem(name: "to", value: tomorrow)]))
                guard current() else { return }
                let items = Self.decodeItems(data, folders: self.folders, now: Date())
                self.state = .connected
                if items != self.items {
                    self.items = items
                    AgendaStore.shared.charcalChanged()
                }
            } catch CharcalFailure.unauthorized {
                guard current() else { return }
                self.state = .invalid
                self.items = []
                AgendaStore.shared.charcalChanged()
            } catch {
                // Niente rete o server lento: restano le cose di prima, si riprova alla prossima occhiata.
                guard current() else { return }
                if self.state == .connected { self.state = .offline }
            }
            DockBar.shared.dataChanged()
        }
    }

    /// Le cose di un giorno solo per il righello della giornata (`DayRulerStore`): anche quelle già passate e, se
    /// `includeDone`, quelle fatte (l'API dà solo le aperte: le fatte arrivano da `view=completed`, filtrate sul giorno).
    /// `nil` se Charcal non è collegato o se la lettura non riesce: chi chiama tiene quelle di prima.
    func dayItems(_ day: Date, includeDone: Bool) async -> [AgendaEvent]? {
        guard let token, state != .invalid else { return nil }
        let text = Self.dayString(day)
        do {
            if Date().timeIntervalSince(foldersLoaded) > 3600 {
                let data = try? await Self.fetch(Self.request("v1/folders", token: token))
                guard self.token == token else { return nil }
                if let data {
                    folders = Self.decodeFolders(data)
                    foldersLoaded = Date()
                }
            }
            let open = try await Self.fetch(Self.request("v1/items", token: token,
                                                         query: [URLQueryItem(name: "from", value: text),
                                                                 URLQueryItem(name: "to", value: text)]))
            guard self.token == token else { return nil }
            var items = Self.decodeItems(open, folders: folders, now: nil)
            if includeDone {
                // Le fatte non fermano il resto: senza, il righello mostra comunque le aperte.
                if let data = try? await Self.fetch(Self.request("v1/items", token: token,
                                                                 query: [URLQueryItem(name: "view", value: "completed")])) {
                    guard self.token == token else { return nil }
                    let start = Calendar.current.startOfDay(for: day)
                    let ids = Set(items.map(\.id))
                    items += Self.decodeItems(data, folders: folders, now: nil, done: true)
                        .filter { !ids.contains($0.id) && Calendar.current.isDate($0.start, inSameDayAs: start) && !$0.span }
                }
            }
            return items
        } catch {
            return nil
        }
    }

    // MARK: Rete

    private enum CharcalFailure: Error { case unauthorized, failed }

    private static func request(_ path: String, token: String, query: [URLQueryItem] = []) -> URLRequest {
        var components = URLComponents(url: base.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { components.queryItems = query }
        var request = URLRequest(url: components.url!, timeoutInterval: 12)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.waitsForConnectivity = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration)
    }()

    private static func fetch(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw CharcalFailure.failed }
        // Solo 401 vuol dire token rifiutato: un 403 può arrivare anche dalla protezione di Cloudflare con un token
        // buono, e trattarlo da token sbagliato scollegava fino al prossimo incolla.
        if http.statusCode == 401 { throw CharcalFailure.unauthorized }
        guard (200..<300).contains(http.statusCode) else { throw CharcalFailure.failed }
        return data
    }

    // MARK: Dal JSON agli eventi

    private struct RawFolder: Decodable {
        let id: String
        let name: String
        let color: String?
        let deleted: Bool?
    }

    private struct RawItem: Decodable {
        let id: String
        let title: String
        let folderId: String?
        let day: String?
        let endDay: String?
        let time: String?
        let duration: Int?
        let evening: Bool?
        let completedAt: Double?
        let deleted: Bool?
    }

    private static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }

    private static func decodeFolders(_ data: Data) -> [String: Folder] {
        struct Body: Decodable { let folders: [RawFolder] }
        guard let body = try? decoder().decode(Body.self, from: data) else { return [:] }
        var out: [String: Folder] = [:]
        for folder in body.folders where folder.deleted != true {
            out[folder.id.lowercased()] = Folder(name: folder.name, color: color(folder.color))
        }
        return out
    }

    /// Le cose aperte, con un giorno, nella forma degli eventi: con un'ora diventano un evento a quell'ora (un quarto
    /// d'ora se non hanno durata), senza ora valgono per tutta la giornata, «stasera» per la sera.
    /// Una cosa che non si legge (un campo nuovo, un valore strano) si salta: le altre restano.
    private struct Lossy<T: Decodable>: Decodable {
        let value: T?
        init(from decoder: Decoder) throws { value = try? T(from: decoder) }
    }

    /// `now` nil: anche le cose già passate (il righello della giornata). `done`: solo le cose fatte, invece delle aperte.
    private static func decodeItems(_ data: Data, folders: [String: Folder], now: Date?, done: Bool = false) -> [AgendaEvent] {
        struct Body: Decodable { let items: [Lossy<RawItem>] }
        guard let body = try? decoder().decode(Body.self, from: data) else { return [] }
        let calendar = Calendar.current
        var out: [AgendaEvent] = []
        for item in body.items.compactMap(\.value) where (item.completedAt != nil) == done && item.deleted != true {
            guard let dayText = item.day, let day = date(dayText) else { continue }
            let folder = item.folderId.flatMap { folders[$0.lowercased()] }
            let tint = folder?.color ?? accent
            let title = item.title.trimmingCharacters(in: .whitespacesAndNewlines)
            let name = title.isEmpty ? String(localized: "Senza titolo") : title
            let id = "charcal|" + item.id.lowercased()
            if let endText = item.endDay, let last = date(endText) {
                // Con un ultimo giorno l'ora non conta (lo dice l'API): su più giorni (un viaggio) vale per ogni giorno
                // fino all'ultimo compreso.
                let end = calendar.date(byAdding: .day, value: 1, to: max(last, day)) ?? day
                out.append(AgendaEvent(id: id, title: name, start: day, end: end, allDay: true,
                                       red: tint.0, green: tint.1, blue: tint.2, location: folder?.name, meeting: nil,
                                       task: true, span: true))
            } else if let timeText = item.time, let start = time(timeText, on: day) {
                // Senza durata vale un quarto d'ora («adesso»); con una durata, quella vera, anche se breve.
                let minutes = item.duration ?? 0
                let end = start.addingTimeInterval(Double(minutes > 0 ? minutes : 15) * 60)
                out.append(AgendaEvent(id: id, title: name, start: start, end: end, allDay: false,
                                       red: tint.0, green: tint.1, blue: tint.2, location: folder?.name, meeting: nil,
                                       task: true, openEnded: minutes <= 0))
            } else {
                let end = calendar.date(byAdding: .day, value: 1, to: day) ?? day.addingTimeInterval(86_400)
                out.append(AgendaEvent(id: id, title: name, start: day, end: end, allDay: true,
                                       red: tint.0, green: tint.1, blue: tint.2, location: folder?.name, meeting: nil,
                                       task: true, evening: item.evening == true))
            }
        }
        if done { for index in out.indices { out[index].done = true } }
        guard let now else { return out }
        return out.filter { $0.end > now }
    }

    private static let dayFormat: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    /// Le date di Charcal sono «ora locale di chi le ha scritte»: si leggono nel fuso di questo Mac.
    static func dayString(_ date: Date) -> String {
        dayFormat.timeZone = .current
        return dayFormat.string(from: date)
    }

    private static func date(_ text: String) -> Date? {
        dayFormat.timeZone = .current
        return dayFormat.date(from: text).map { Calendar.current.startOfDay(for: $0) }
    }

    private static func time(_ text: String, on day: Date) -> Date? {
        let parts = text.split(separator: ":").compactMap { Int($0) }
        guard parts.count >= 2, (0..<24).contains(parts[0]), (0..<60).contains(parts[1]) else { return nil }
        return Calendar.current.date(bySettingHour: parts[0], minute: parts[1], second: 0, of: day)
    }

    /// L'Amarena di Charcal nella versione scura (il Dock è sempre vetro scuro): per le cose senza etichetta.
    static let accent = (1.0, 157.0 / 255, 178.0 / 255)

    /// I colori delle etichette: le chiavi di Charcal nelle tinte scure di sistema, o il colore scelto a mano.
    private static func color(_ key: String?) -> (Double, Double, Double) {
        guard let key = key?.lowercased() else { return (0.6, 0.6, 0.62) }
        if key.hasPrefix("#"), key.count == 7, let value = Int(key.dropFirst(), radix: 16) {
            return (Double((value >> 16) & 0xFF) / 255, Double((value >> 8) & 0xFF) / 255, Double(value & 0xFF) / 255)
        }
        switch key {
        case "rosso": return (1.0, 0.27, 0.23)
        case "arancio": return (1.0, 0.62, 0.04)
        case "giallo": return (1.0, 0.84, 0.04)
        case "verde": return (0.19, 0.82, 0.35)
        case "menta": return (0.39, 0.90, 0.89)
        case "azzurro": return (0.39, 0.82, 1.0)
        case "blu": return (0.04, 0.52, 1.0)
        case "viola": return (0.75, 0.35, 0.95)
        case "rosa": return (1.0, 0.22, 0.37)
        case "marrone": return (0.67, 0.56, 0.41)
        default: return (0.6, 0.6, 0.62)
        }
    }

    // MARK: Prove

    /// Per le prove fuori schermo: due cose finte, senza rete.
    func useSample(now: Date) {
        state = .connected
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        items = [
            AgendaEvent(id: "charcal|1", title: "Send the proposal", start: now.addingTimeInterval(150 * 60),
                        end: now.addingTimeInterval(165 * 60), allDay: false, red: Self.accent.0, green: Self.accent.1, blue: Self.accent.2,
                        location: "Work", meeting: nil, task: true, openEnded: true),
            AgendaEvent(id: "charcal|2", title: "Buy bread", start: today,
                        end: calendar.date(byAdding: .day, value: 1, to: today) ?? today, allDay: true,
                        red: 0.19, green: 0.82, blue: 0.35, location: "Home", meeting: nil, task: true),
        ]
    }
}

/// Il token di Charcal nel Portachiavi del Mac (una password generica dell'app). Mai finestre del Portachiavi: se una
/// copia firmata diversamente non può leggerlo, risulta semplicemente non collegato.
enum CharcalKeychain {
    private static let service = "com.charstudio.charland.charcal"
    private static let account = "api-token"

    private static var base: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    /// Le richieste che non devono mai aprire la finestra del Portachiavi.
    private static var silent: [String: Any] {
        var query = base
        query[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUISkip
        return query
    }

    static func read() -> String? {
        var query = silent
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data, let token = String(data: data, encoding: .utf8), !token.isEmpty else { return nil }
        return token
    }

    @discardableResult
    static func save(_ token: String) -> Bool {
        let data = Data(token.utf8)
        let update: [String: Any] = [kSecValueData as String: data]
        let status = SecItemUpdate(silent as CFDictionary, update as CFDictionary)
        if status == errSecSuccess { return true }
        // Non trovato, o scritto da una copia firmata diversamente che questa non può aggiornare: si toglie e si rifà.
        if status != errSecItemNotFound { SecItemDelete(silent as CFDictionary) }
        var add = base
        add[kSecValueData as String] = data
        add[kSecAttrLabel as String] = "Charland: token di Charcal"
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    static func delete() {
        SecItemDelete(silent as CFDictionary)
    }
}
