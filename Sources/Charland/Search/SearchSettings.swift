import AppKit
import Carbon.HIToolbox

/// Il motore per «Cerca sul web».
enum SearchEngine: String, CaseIterable, Identifiable, Sendable {
    case google, duckDuckGo, bing, ecosia

    var id: String { rawValue }

    var name: String {
        switch self {
        case .google: "Google"
        case .duckDuckGo: "DuckDuckGo"
        case .bing: "Bing"
        case .ecosia: "Ecosia"
        }
    }

    func url(for query: String) -> URL? {
        var parts: URLComponents
        switch self {
        case .google: parts = URLComponents(string: "https://www.google.com/search")!
        case .duckDuckGo: parts = URLComponents(string: "https://duckduckgo.com/")!
        case .bing: parts = URLComponents(string: "https://www.bing.com/search")!
        case .ecosia: parts = URLComponents(string: "https://www.ecosia.org/search")!
        }
        // Il «+» va scritto come %2B: lasciato com'è il motore lo legge come spazio («c++» diventava «c»).
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "+&=")
        parts.percentEncodedQueryItems = [URLQueryItem(name: "q", value: query.addingPercentEncoding(withAllowedCharacters: allowed))]
        return parts.url
    }
}

/// Impostazioni › Ricerca (carpa, 23 novembre 2026: «un custom searchbar, quella con search or ask ⌘spazio, che esca
/// direttamente dal Dock e sia attivabile o disattivabile dalle impostazioni, così se uno vuole la default tiene quella»;
/// poi, lo stesso giorno: «no, voglio che esca dal notch»).
///
/// Spenta di serie: chi installa Charland si ritrova ⌘spazio com'era. Accesa, Charland prende la scorciatoia prima di
/// macOS (`SearchHotkey`) e la barra esce dal notch (`SearchBar`); spenta di nuovo, ⌘spazio torna subito a Siri.
@MainActor @Observable
final class SearchSettings {
    static let shared = SearchSettings()

    var enabled: Bool { didSet { guard ready else { return }; save(enabled, "searchEnabled"); SearchBar.shared.apply() } }
    /// La scorciatoia: di serie ⌘spazio, quella della ricerca di macOS. Si può spostare (⌥spazio) per tenere le due.
    var combo: KeyCombo {
        didSet {
            guard ready else { return }
            UserDefaults.standard.set(try? JSONEncoder().encode(combo), forKey: "searchCombo")
            SearchBar.shared.apply()
        }
    }
    var apps: Bool { didSet { guard ready else { return }; save(apps, "searchApps"); SearchBar.shared.sourcesChanged() } }
    /// Le app dell'iPhone di Duplicazione iPhone (carpa: «non trova le app dell'iPhone, in quello default se cerco
    /// Nicegram c'è il simboletto dell'iPhone e la posso aprire direttamente»).
    var iphoneApps: Bool { didSet { guard ready else { return }; save(iphoneApps, "searchIPhoneApps"); SearchBar.shared.sourcesChanged() } }
    var files: Bool { didSet { guard ready else { return }; save(files, "searchFiles"); SearchBar.shared.sourcesChanged() } }
    var calculator: Bool { didSet { guard ready else { return }; save(calculator, "searchCalculator"); SearchBar.shared.sourcesChanged() } }
    var web: Bool { didSet { guard ready else { return }; save(web, "searchWeb"); SearchBar.shared.sourcesChanged() } }
    var ask: Bool { didSet { guard ready else { return }; save(ask, "searchAsk"); SearchBar.shared.sourcesChanged() } }
    var engine: SearchEngine { didSet { guard ready else { return }; UserDefaults.standard.set(engine.rawValue, forKey: "searchEngine") } }

    /// Come sta la scorciatoia adesso (non si salva): la mostra la sezione delle impostazioni.
    var hotkey: SearchHotkey.Status = .off

    static let comboDefault = KeyCombo(keyCode: UInt32(kVK_Space), modifiers: UInt32(cmdKey))

    /// Con `@Observable` i `didSet` scattano anche dentro `init`: lì non devono salvare né riaccendere niente.
    @ObservationIgnored private var ready = false

    private init() {
        let d = UserDefaults.standard
        enabled = d.object(forKey: "searchEnabled") as? Bool ?? false
        combo = d.data(forKey: "searchCombo").flatMap { try? JSONDecoder().decode(KeyCombo.self, from: $0) } ?? Self.comboDefault
        apps = d.object(forKey: "searchApps") as? Bool ?? true
        iphoneApps = d.object(forKey: "searchIPhoneApps") as? Bool ?? true
        files = d.object(forKey: "searchFiles") as? Bool ?? true
        calculator = d.object(forKey: "searchCalculator") as? Bool ?? true
        web = d.object(forKey: "searchWeb") as? Bool ?? true
        ask = d.object(forKey: "searchAsk") as? Bool ?? true
        engine = d.string(forKey: "searchEngine").flatMap(SearchEngine.init(rawValue:)) ?? .google
        ready = true
    }

    private func save(_ value: Bool, _ key: String) {
        UserDefaults.standard.set(value, forKey: key)
    }
}
