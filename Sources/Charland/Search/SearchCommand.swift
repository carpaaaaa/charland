import AppKit
import FoundationModels

/// Le azioni scritte nella barra (carpa, 23 novembre 2026: «ho chiesto all'AI di aprirmi Pinterest su Safari, non l'ha
/// fatto»): «apri Pinterest su Safari», «open youtube in chrome», «aprimi Note», «vai su github.com». Diventano una
/// riga in cima, già scelta: Invio e si apre. Le stesse due azioni le può usare anche il modello di «Chiedi» quando la
/// frase è più libera (`SearchOpenWebsiteTool`, `SearchOpenAppTool`).
@MainActor
enum SearchCommand {
    /// I verbi, dal più lungo: «mi puoi aprire» prima di «aprire».
    private static let verbs = [
        "mi puoi aprire", "puoi aprirmi", "puoi aprire", "mi apri", "aprimi", "apri", "apra", "vai su", "vai a", "portami su",
        "portami a", "lancia", "avvia", "can you open", "please open", "open up", "open", "launch", "go to", "take me to", "start",
    ]
    private static let fillers = ["per favore", "per piacere", "grazie", "please", "thanks", "thank you"]
    /// I browser, come si chiamano a voce e come si chiama l'app.
    private static let browsers: [(said: String, app: [String])] = [
        ("google chrome", ["google chrome"]), ("chrome", ["google chrome", "chrome"]), ("safari", ["safari"]),
        ("firefox", ["firefox"]), ("arc", ["arc"]), ("edge", ["microsoft edge"]), ("opera", ["opera gx", "opera"]),
        ("brave", ["brave browser", "brave"]), ("orion", ["orion"]), ("vivaldi", ["vivaldi"]), ("zen", ["zen", "zen browser"]),
    ]
    /// I siti che tutti chiamano per nome: si aprono subito, senza passare dal primo risultato di una ricerca.
    private static let sites: [String: String] = [
        "pinterest": "https://www.pinterest.com", "youtube": "https://www.youtube.com", "instagram": "https://www.instagram.com",
        "facebook": "https://www.facebook.com", "x": "https://x.com", "twitter": "https://x.com", "tiktok": "https://www.tiktok.com",
        "reddit": "https://www.reddit.com", "linkedin": "https://www.linkedin.com", "github": "https://github.com",
        "gmail": "https://mail.google.com", "google": "https://www.google.com", "netflix": "https://www.netflix.com",
        "whatsapp": "https://web.whatsapp.com", "chatgpt": "https://chatgpt.com", "claude": "https://claude.ai",
        "wikipedia": "https://www.wikipedia.org", "google maps": "https://maps.google.com", "amazon": "https://www.amazon.com",
        "spotify": "https://open.spotify.com", "twitch": "https://www.twitch.tv", "figma": "https://www.figma.com",
    ]

    /// Un'azione, se il testo lo è. Prudente, perché la riga va in cima già scelta e Invio la esegue: solo un'app
    /// installata, un sito noto, un indirizzo scritto o, con un browser installato nominato, un sito qualunque («apri
    /// repubblica su safari»). «open source license», «start here», «vai a Napoli in treno» non sono azioni.
    /// `strict` (Chiedi, dove la frase può essere una domanda): niente sito qualunque nemmeno col browser.
    static func parse(_ text: String, strict: Bool = false) -> SearchResult? {
        guard let phrase = split(text) else { return nil }
        let folded = SearchText.fold(phrase.target)
        // Con un browser nominato (anche se non c'è) si vuole il sito, non l'app.
        if !phrase.browserNamed, let app = SearchCatalog.shared.app(named: folded) {
            return SearchResult(id: "azione", kind: .action, title: String(localized: "Apri \(app.name)"),
                                subtitle: String(localized: "ricerca.app"), url: URL(fileURLWithPath: app.path),
                                label: String(localized: "Azione"))
        }
        // Un sito noto vince sull'app dell'iPhone con lo stesso nome: «apri pinterest» apre pinterest.com (prima, con
        // Pinterest sull'iPhone, non usciva niente: né l'azione né la riga dell'iPhone). L'app dell'iPhone resta sotto,
        // come riga sua (`iPhoneTarget`).
        let lucky = phrase.browser != nil && !strict ? luckySite(phrase.target) : nil
        guard let site = knownSite(phrase.target) ?? lucky else { return nil }
        let name = displayName(phrase.target)
        if let browser = phrase.browser {
            return SearchResult(id: "azione", kind: .action, title: String(localized: "Apri \(name) in \(browser.name)"),
                                subtitle: site.absoluteString, url: site, value: browser.path, label: String(localized: "Azione"))
        }
        return SearchResult(id: "azione", kind: .action, title: String(localized: "Apri \(name)"), subtitle: site.absoluteString,
                            url: site, label: String(localized: "Azione"))
    }

    /// «apri Nicegram»: l'app dell'iPhone che la frase chiede, se non c'è un'app per Mac con quel nome e non si è nominato
    /// un browser. La barra la mette in cima come riga dell'iPhone: la ricerca del catalogo, con «apri» davanti, non la
    /// trovava.
    /// `exact` (Chiedi, dove la frase può essere una domanda): solo il nome intero, «open ins» non apre Instagram.
    static func iPhoneTarget(_ text: String, exact: Bool = false) -> SearchApp? {
        guard SearchSettings.shared.apps, let phrase = split(text), !phrase.browserNamed else { return nil }
        let folded = SearchText.fold(phrase.target)
        guard SearchCatalog.shared.app(named: folded) == nil, let app = SearchCatalog.shared.iPhoneApp(named: folded) else { return nil }
        return !exact || app.folded == folded ? app : nil
    }

    /// Esegue la riga d'azione.
    static func perform(_ result: SearchResult) {
        guard let url = result.url else { return }
        if url.isFileURL {
            DockLaunch.open(url)
        } else {
            SearchLaunch.open(web: url, in: result.value.map { URL(fileURLWithPath: $0) })
        }
    }

    /// Per lo strumento del modello: apre un sito, nel browser chiesto se c'è. Risponde con quello che ha fatto.
    static func openSite(_ site: String, browser: String) -> String {
        let target = site.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty, let url = knownSite(target) ?? luckySite(target) else {
            return "Could not understand which website to open."
        }
        // Il modello a volte aggiunge «Safari» anche quando nessuno l'ha chiesto: vale solo un browser nominato nella
        // domanda, come parola intera («edge» non è in «knowledge»).
        var app: (name: String, path: String)?
        if let entry = browserEntry(SearchText.fold(browser)), let last = entry.said.split(separator: " ").last,
           words(SearchAsk.currentQuestion).contains(String(last)) {
            app = installed(entry)
        }
        SearchLaunch.open(web: url, in: app.map { URL(fileURLWithPath: $0.path) })
        return "Opened \(url.absoluteString)" + (app.map { " in \($0.name)" } ?? "") + "."
    }

    /// Per lo strumento del modello: apre un'app installata.
    static func openApp(_ name: String) -> String {
        guard let app = SearchCatalog.shared.app(named: SearchText.fold(name)) else {
            return "There is no app called \(name) on this Mac."
        }
        DockLaunch.open(URL(fileURLWithPath: app.path))
        return "Opened \(app.name)."
    }

    // MARK: Lettura della frase

    private struct Phrase {
        /// Il bersaglio com'è stato scritto (maiuscole comprese: un indirizzo con un percorso le distingue).
        var target: String
        var browser: (name: String, path: String)?
        var browserNamed = false
    }

    private static let joiners: Set<String> = ["su", "in", "con", "on", "with", "using", "nel", "col"]
    private static let articles: [[String]] = [["il", "sito", "di"], ["il", "sito"], ["sito"], ["the", "website"], ["website"],
                                               ["the", "site"], ["the", "app"], ["l'app"], ["app"]]

    /// Parola per parola sul testo vero: le parole si confrontano piegate (minuscole, senza accenti), il bersaglio resta
    /// com'è scritto. Riempitivi e verbi valgono solo come parole intere («thanksgiving.com» resta intero).
    private static func split(_ text: String) -> Phrase? {
        var tokens = text.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        while var last = tokens.last, let end = last.last, "?!.,;".contains(end) {
            last.removeLast()
            if last.isEmpty { tokens.removeLast() } else { tokens[tokens.count - 1] = last }
        }
        var folded = tokens.map(SearchText.fold)
        for filler in fillers.map({ $0.split(separator: " ").map(String.init) }) {
            var i = 0
            while i + filler.count <= folded.count {
                if Array(folded[i..<(i + filler.count)]) == filler {
                    folded.removeSubrange(i..<(i + filler.count))
                    tokens.removeSubrange(i..<(i + filler.count))
                } else {
                    i += 1
                }
            }
        }
        guard let verb = verbs.map({ $0.split(separator: " ").map(String.init) })
            .first(where: { folded.count > $0.count && Array(folded.prefix($0.count)) == $0 }) else { return nil }
        tokens.removeFirst(verb.count)
        folded.removeFirst(verb.count)
        if let article = articles.first(where: { folded.count > $0.count && Array(folded.prefix($0.count)) == $0 }) {
            tokens.removeFirst(article.count)
            folded.removeFirst(article.count)
        }
        var browser: (name: String, path: String)?
        var named = false
        if let j = folded.lastIndex(where: { joiners.contains($0) }), j > 0 {
            let tail = folded[(j + 1)...].filter { $0 != "browser" }.joined(separator: " ")
            if let entry = browserEntry(tail) {
                // Nominato ma non installato: si apre nel browser di serie.
                browser = installed(entry)
                named = true
                tokens.removeSubrange(j...)
            }
        }
        let target = tokens.joined(separator: " ")
        guard !target.isEmpty, target.count <= 60 else { return nil }
        return Phrase(target: target, browser: browser, browserNamed: named)
    }

    /// Un browser da come lo si chiama («chrome», «google chrome», «opera gx»).
    private static func browserEntry(_ said: String) -> (said: String, app: [String])? {
        let s = said.trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty else { return nil }
        return browsers.first { s == $0.said || s.hasPrefix($0.said + " ") || $0.app.contains(s) }
    }

    private static func installed(_ entry: (said: String, app: [String])) -> (name: String, path: String)? {
        for candidate in entry.app {
            if let app = SearchCatalog.shared.apps.first(where: { !$0.iPhone && $0.folded == candidate }) {
                return (app.name, app.path)
            }
        }
        return nil
    }

    private static func words(_ text: String) -> Set<String> {
        Set(SearchText.fold(text).split(whereSeparator: { !($0.isLetter || $0.isNumber) }).map(String.init))
    }

    /// Le estensioni dei file: «contratto.pdf» o «readme.md» sono file da cercare, non siti.
    static let fileExtensions: Set<String> = ["md", "txt", "pdf", "jpg", "jpeg", "png", "heic", "gif", "doc", "docx", "xls", "xlsx",
                                              "ppt", "pptx", "swift", "js", "ts", "py", "json", "zip", "mov", "mp4", "mp3", "wav",
                                              "key", "pages", "numbers", "csv", "html", "rtf", "psd", "ai", "sketch", "fig", "dmg"]

    /// Un indirizzo scritto (con o senza https) o uno dei siti noti.
    static func knownSite(_ target: String) -> URL? {
        let t = target.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return nil }
        let lower = t.lowercased()
        if lower.hasPrefix("http://") || lower.hasPrefix("https://") { return URL(string: t) }
        if !t.contains(" "), lower.range(of: #"^[a-z0-9-]+(\.[a-z0-9-]+)*\.[a-z]{2,24}(/.*)?$"#, options: .regularExpression) != nil {
            let host = lower.split(separator: "/").first.map(String.init) ?? lower
            let ext = host.split(separator: ".").last.map(String.init) ?? ""
            guard !fileExtensions.contains(ext) else { return nil }
            return URL(string: "https://" + t)
        }
        if let known = sites[SearchText.fold(t)] { return URL(string: known) }
        return nil
    }

    /// Il primo risultato di una ricerca («!ducky» di DuckDuckGo porta dritto lì): solo quando si è chiesto
    /// esplicitamente di aprire qualcosa in un browser, o lo ha deciso il modello.
    private static func luckySite(_ target: String) -> URL? {
        var parts = URLComponents(string: "https://duckduckgo.com/")!
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "+&=")
        parts.percentEncodedQueryItems = [URLQueryItem(name: "q", value: ("!ducky " + target).addingPercentEncoding(withAllowedCharacters: allowed))]
        return parts.url
    }

    /// I siti noti come si scrivono («Open Youtube» era brutto).
    private static let siteNames: [String: String] = [
        "youtube": "YouTube", "tiktok": "TikTok", "linkedin": "LinkedIn", "github": "GitHub", "chatgpt": "ChatGPT",
        "whatsapp": "WhatsApp", "google maps": "Google Maps", "x": "X",
    ]

    /// «pinterest» → «Pinterest», «youtube» → «YouTube», «github.com» resta com'è.
    private static func displayName(_ target: String) -> String {
        if let name = siteNames[SearchText.fold(target)] { return name }
        if target.contains(".") { return target }
        return target.split(separator: " ").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
    }
}

/// Lo strumento del modello per aprire un sito.
struct SearchOpenWebsiteTool: Tool {
    let name = "openWebsite"
    let description = "Opens a website in the browser on this Mac. Call it whenever the user asks to open, show or go to a website or web service (for example Pinterest, YouTube, github.com), optionally in a specific browser."

    @Generable
    struct Arguments {
        @Guide(description: "The website: its name, like Pinterest, or its address, like pinterest.com")
        var site: String
        @Guide(description: "The browser the user asked for, like Safari or Chrome. Empty if the user did not name one.")
        var browser: String
    }

    @concurrent func call(arguments: Arguments) async throws -> String {
        await MainActor.run { SearchCommand.openSite(arguments.site, browser: arguments.browser) }
    }
}

/// Lo strumento del modello per aprire un'app.
struct SearchOpenAppTool: Tool {
    let name = "openApp"
    let description = "Opens an app installed on this Mac. Call it whenever the user asks to open or launch an app (for example Notes, Calendar, Spotify)."

    @Generable
    struct Arguments {
        @Guide(description: "The name of the app, like Notes or Spotify")
        var app: String
    }

    @concurrent func call(arguments: Arguments) async throws -> String {
        await MainActor.run { SearchCommand.openApp(arguments.app) }
    }
}
