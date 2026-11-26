import AppKit

/// Un risultato della ricerca, come lo mostra la barra.
struct SearchResult: Identifiable, Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case app, iphoneApp, file, folder, calculation, link, web, ask, action
    }

    /// Stabile fra una lettera e l'altra: la selezione resta sulla stessa riga mentre scrivi.
    let id: String
    var kind: Kind
    var title: String
    var subtitle: String
    /// L'app, il file, la pagina da aprire.
    var url: URL?
    /// Il risultato di un calcolo, la domanda da fare.
    var value: String?
    /// La parola a destra: «App», «Cartella», il tipo del file.
    var label: String
    var score: Double = 0
}

/// Le parole come si confrontano: minuscole, senza accenti.
enum SearchText {
    static func fold(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
    }

    /// Le parole di un nome, anche quelle attaccate (`CapCut` → «cap», «cut»; `iMovie` → «i», «movie»).
    static func words(_ name: String) -> [String] {
        var words: [String] = []
        var current = ""
        var previous: Character?
        for character in name {
            if !(character.isLetter || character.isNumber) {
                if !current.isEmpty { words.append(current) }
                current = ""
            } else {
                if let previous, character.isUppercase, previous.isLowercase, !current.isEmpty {
                    words.append(current)
                    current = ""
                }
                current.append(character)
            }
            previous = character
        }
        if !current.isEmpty { words.append(current) }
        return words.map(fold)
    }

    /// Quanto `query` (già piegata) somiglia a `target` (già piegato), con le sue parole e iniziali. `nil` se no.
    /// In ordine: uguale, inizio del nome, inizio di una parola, iniziali («vsc» per Visual Studio Code), dentro il nome,
    /// lettere in ordine con dei buchi.
    static func score(_ query: String, target: String, words: [String], initials: String) -> Double? {
        guard !query.isEmpty, !target.isEmpty else { return nil }
        if target == query { return 1000 }
        if target.hasPrefix(query) { return 900 - Double(min(60, target.count - query.count)) * 2 }
        // Più parole nella ricerca: ognuna deve cominciare una parola del nome.
        let parts = query.split(separator: " ").map(String.init)
        if parts.count > 1 {
            var total = 0.0
            for part in parts {
                guard let index = words.firstIndex(where: { $0.hasPrefix(part) }) else { return nil }
                total += 700 - Double(index) * 15
            }
            return total / Double(parts.count)
        }
        if let index = words.firstIndex(where: { $0.hasPrefix(query) }) { return 720 - Double(index) * 20 }
        if query.count >= 2, initials.hasPrefix(query) { return 620 - Double(initials.count - query.count) * 5 }
        if target.contains(query) { return 420 - Double(min(40, target.count - query.count)) }
        // Lettere in ordine: «chrm» trova Chrome. Più sono vicine e più in alto.
        guard query.count >= 2, let spread = subsequenceSpread(query, in: target) else { return nil }
        return max(60, 260 - Double(spread) * 12)
    }

    /// Quante lettere in mezzo ci sono fra la prima e l'ultima, se `query` sta dentro `target` in ordine.
    private static func subsequenceSpread(_ query: String, in target: String) -> Int? {
        var q = query.makeIterator()
        guard var wanted = q.next() else { return nil }
        var first: Int?
        for (index, character) in target.enumerated() where character == wanted {
            if first == nil { first = index }
            guard let next = q.next() else { return index - (first ?? index) - (query.count - 1) }
            wanted = next
        }
        return nil
    }
}

/// Un'app installata.
struct SearchApp: Sendable {
    let path: String
    /// Il nome che vede chi usa il Mac (`Calcolatrice`) e quello del pacchetto (`Calculator`).
    let name: String
    let altName: String?
    let folded: String
    let foldedAlt: String?
    let words: [String]
    let initials: String
    let bundleID: String?
    /// Un'app dell'iPhone (Duplicazione iPhone): `path` è il suo segnaposto, che serve solo per l'icona.
    var iPhone = false
    /// Il nome nelle altre lingue scelte sul Mac (carpa ha il Mac in inglese con l'italiano come seconda lingua:
    /// «impostazioni» deve trovare System Settings, «calcolatrice» Calculator).
    var others: [String] = []
    var foldedOthers: [String] = []
    var othersWords: [[String]] = []

    /// Il nome, piegato, che corrisponde a `folded` fra tutti quelli che ha.
    func isNamed(_ query: String) -> Bool { folded == query || foldedAlt == query || foldedOthers.contains(query) }

    func namePrefixed(_ query: String) -> Bool {
        folded.hasPrefix(query) || (foldedAlt?.hasPrefix(query) ?? false) || foldedOthers.contains { $0.hasPrefix(query) }
    }
}

/// Le app del Mac, in memoria: cercarle costa meno di un millisecondo a ogni lettera.
///
/// Si leggono in sottofondo all'accensione della funzione e di nuovo, al massimo una volta al minuto, quando la barra
/// si apre (un'app installata da poco compare alla seconda apertura). Le cartelle delle app di macOS, quella dell'utente
/// e un livello di sottocartelle (le suite come «DaVinci Resolve» stanno in una cartella loro).
@MainActor
final class SearchCatalog {
    static let shared = SearchCatalog()

    private(set) var apps: [SearchApp] = [] {
        // Anche i nomi nell'altra lingua: un iPhone in italiano chiama «Note» quella che sul Mac in inglese è Notes.
        didSet { macNames = Set(apps.filter { !$0.iPhone }.flatMap { [$0.folded] + ($0.foldedAlt.map { [$0] } ?? []) + $0.foldedOthers }) }
    }
    /// I nomi delle app per Mac: l'app dell'iPhone con lo stesso nome (Safari, Note, WhatsApp) non si mostra. Dalla barra
    /// non si potrebbe nemmeno aprire: si passa dalla ricerca di macOS, che mette prima l'app per Mac.
    private var macNames: Set<String> = []
    private var builtAt: CFTimeInterval = -1000
    private var building = false

    private init() {}

    func refreshIfNeeded() {
        guard !building, CACurrentMediaTime() - builtAt > 60 else { return }
        building = true
        DispatchQueue.global(qos: .userInitiated).async {
            let mac = Self.scan()
            let iPhone = Self.scanIPhone()
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    let catalog = SearchCatalog.shared
                    catalog.apps = mac + iPhone
                    catalog.builtAt = CACurrentMediaTime()
                    catalog.building = false
                    SearchIcons.shared.warm(mac.map(\.path))
                    // Le icone delle app dell'iPhone costano di più (circa 60 ms l'una): dopo, con calma.
                    SearchIcons.shared.warm(iPhone.map(\.path), quality: .background)
                }
            }
        }
    }

    func app(at path: String) -> SearchApp? { apps.first { $0.path == path } }

    /// C'è un'app per Mac con questo nome: aprendo l'app dell'iPhone con lo stesso nome dalla ricerca di macOS verrebbe
    /// prima lei, quindi lì non si conferma da soli.
    func hasMacApp(named name: String) -> Bool {
        let folded = SearchText.fold(name)
        return apps.contains { !$0.iPhone && $0.isNamed(folded) }
    }

    /// L'app per Mac che si chiama così (già piegato, anche nell'altra lingua del Mac): uguale, o l'unica il cui nome
    /// comincia così (almeno tre lettere).
    func app(named folded: String) -> SearchApp? {
        let mac = apps.filter { !$0.iPhone }
        if let exact = mac.first(where: { $0.isNamed(folded) }) { return exact }
        guard folded.count >= 3 else { return nil }
        let prefixed = mac.filter { $0.namePrefixed(folded) }
        return prefixed.count == 1 ? prefixed[0] : nil
    }

    /// La riga di un'app dell'iPhone (la stessa che dà `match`).
    func iPhoneResult(_ app: SearchApp, score: Double = 0) -> SearchResult {
        SearchResult(id: "iphone:" + (app.bundleID ?? app.path), kind: .iphoneApp, title: app.name,
                     subtitle: String(localized: "App per iPhone"), url: URL(fileURLWithPath: app.path), value: app.bundleID,
                     label: "iPhone", score: score)
    }

    /// L'app dell'iPhone che si chiama così (già piegato): uguale, o l'unica il cui nome comincia così.
    func iPhoneApp(named folded: String) -> SearchApp? {
        guard SearchSettings.shared.iphoneApps else { return nil }
        let phone = apps.filter { $0.iPhone && !macNames.contains($0.folded) }
        if let exact = phone.first(where: { $0.folded == folded }) { return exact }
        guard folded.count >= 3 else { return nil }
        let prefixed = phone.filter { $0.folded.hasPrefix(folded) }
        return prefixed.count == 1 ? prefixed[0] : nil
    }

    /// C'è ancora, e non ha un'app per Mac con lo stesso nome (che fra i recenti la renderebbe un doppione).
    func hasIPhoneApp(id: String) -> Bool {
        apps.contains { $0.iPhone && !macNames.contains($0.folded) && "iphone:" + ($0.bundleID ?? $0.path) == id }
    }

    /// Le app aperte salgono un poco. L'elenco si legge una volta all'apertura della barra (`noteOpened`): chiederlo a
    /// ogni lettera costava millisecondi.
    private var runningBundles: Set<String> = []

    func noteOpened() {
        runningBundles = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
    }

    /// Le app dell'iPhone che macOS conosce per Duplicazione iPhone (le stesse che trova la ricerca di macOS). Non sono
    /// file che si possono leggere: stanno come «segnaposto remoti» nel registro delle app, protetti, e le domande normali
    /// del registro le nascondono. `LSApplicationRecord.remotePlaceholderEnumerator` (funzione interna, cercata a runtime:
    /// se un giorno manca, semplicemente non compaiono) le elenca con nome e identificativo: 170 in 30 ms su questo Mac.
    nonisolated private static func scanIPhone() -> [SearchApp] {
        guard let records = NSClassFromString("LSApplicationRecord") as AnyObject?,
              records.responds(to: NSSelectorFromString("remotePlaceholderEnumerator")),
              let enumerator = records.perform(NSSelectorFromString("remotePlaceholderEnumerator"))?.takeUnretainedValue() as? NSEnumerator
        else { return [] }
        var found: [SearchApp] = []
        var seen = Set<String>()
        // Ogni nome si chiede solo se il record lo conosce: una chiave che non c'è (un'altra versione di macOS) farebbe
        // un'eccezione che Swift non ferma, e l'app si chiuderebbe a ogni avvio.
        func read(_ record: NSObject, _ key: String) -> Any? {
            record.responds(to: NSSelectorFromString(key)) ? record.value(forKey: key) : nil
        }
        while let record = enumerator.nextObject() as? NSObject {
            guard let bundle = read(record, "bundleIdentifier") as? String, seen.insert(bundle).inserted,
                  let url = read(record, "URL") as? URL else { continue }
            let name = (read(record, "localizedName") as? String) ?? url.deletingPathExtension().lastPathComponent
            guard !name.isEmpty else { continue }
            let words = SearchText.words(name)
            found.append(SearchApp(path: url.path, name: name, altName: nil, folded: SearchText.fold(name), foldedAlt: nil,
                                   words: words, initials: String(words.compactMap(\.first)), bundleID: bundle, iPhone: true))
        }
        return found
    }

    nonisolated private static func scan() -> [SearchApp] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let roots = ["/Applications", "/System/Applications", "/System/Applications/Utilities", "/Applications/Utilities",
                     home + "/Applications", "/System/Library/CoreServices/Applications"]
        // La stessa app per due strade (un collegamento, una cartella che contiene sé stessa: su questo Mac
        // `/Applications/Applications` è `/Applications`) si riconosce dal file vero, non dal percorso; due copie della
        // stessa app dal suo identificativo, e vince quella più in alto.
        var seenFiles = Set<String>()
        var seenBundles = Set<String>()
        var found: [SearchApp] = []
        let languages = otherLanguages()
        func add(_ path: String) {
            var info = stat()
            guard stat(path, &info) == 0, seenFiles.insert("\(info.st_dev):\(info.st_ino)").inserted,
                  let app = makeApp(path, languages: languages) else { return }
            if let bundle = app.bundleID, !seenBundles.insert(bundle).inserted { return }
            found.append(app)
        }
        let fm = FileManager.default
        var folders: [String] = []
        // Prima le app che stanno direttamente nelle cartelle delle app, poi quelle un livello sotto.
        for root in roots {
            guard let items = try? fm.contentsOfDirectory(atPath: root) else { continue }
            for item in items.sorted() where !item.hasPrefix(".") {
                let path = root + "/" + item
                if item.hasSuffix(".app") {
                    add(path)
                } else {
                    var folder: ObjCBool = false
                    if fm.fileExists(atPath: path, isDirectory: &folder), folder.boolValue { folders.append(path) }
                }
            }
        }
        // Il Finder non sta in nessuna delle cartelle delle app.
        add("/System/Library/CoreServices/Finder.app")
        // Un livello sotto: le suite («Adobe…», «DaVinci Resolve») tengono le app in una cartella loro.
        for path in folders {
            guard let inner = try? fm.contentsOfDirectory(atPath: path) else { continue }
            for sub in inner.sorted() where sub.hasSuffix(".app") { add(path + "/" + sub) }
        }
        return found
    }

    /// Le altre lingue scelte sul Mac, oltre alla prima (i nomi in quella li dà già il Finder): «it-US» → «it».
    nonisolated private static func otherLanguages() -> [String] {
        let codes = Locale.preferredLanguages.map { Locale(identifier: $0).language.languageCode?.identifier ?? $0 }
        var seen = Set(codes.prefix(1))
        return codes.dropFirst().filter { seen.insert($0).inserted }
    }

    /// Il nome dell'app nelle altre lingue: dalla tabella con tutte le lingue delle app di Apple (`InfoPlist.loctable`)
    /// o dal file della lingua delle altre (`it.lproj/InfoPlist.strings`).
    nonisolated private static func localizedNames(_ path: String, languages: [String]) -> [String] {
        guard !languages.isEmpty else { return [] }
        let resources = path + "/Contents/Resources"
        let table = NSDictionary(contentsOfFile: resources + "/InfoPlist.loctable") as? [String: Any]
        return languages.compactMap { language in
            let strings = table?[language] as? [String: Any]
                ?? NSDictionary(contentsOfFile: resources + "/\(language).lproj/InfoPlist.strings") as? [String: Any]
            let name = (strings?["CFBundleDisplayName"] as? String) ?? (strings?["CFBundleName"] as? String)
            return name.map { $0.trimmingCharacters(in: .whitespaces) }.flatMap { $0.isEmpty ? nil : $0 }
        }
    }

    nonisolated private static func makeApp(_ path: String, languages: [String]) -> SearchApp? {
        let fm = FileManager.default
        var name = fm.displayName(atPath: path)
        if name.hasSuffix(".app") { name = String(name.dropLast(4)) }
        guard !name.isEmpty else { return nil }
        let bundle = Bundle(path: path)
        let info = bundle?.infoDictionary
        // Le app che non si aprono da sole (aiutanti, agenti senza finestra) non servono nella ricerca.
        if info?["LSUIElement"] as? Bool == true || (info?["LSUIElement"] as? String) == "1" {
            if !path.hasPrefix("/Applications") { return nil }
        }
        if info?["LSBackgroundOnly"] as? Bool == true { return nil }
        let fileName = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        let bundleName = info?["CFBundleName"] as? String
        let alt = [fileName, bundleName].compactMap { $0 }.first { SearchText.fold($0) != SearchText.fold(name) }
        let words = SearchText.words(name) + (alt.map(SearchText.words) ?? [])
        let initials = String(SearchText.words(name).compactMap(\.first))
        var app = SearchApp(path: path, name: name, altName: alt, folded: SearchText.fold(name), foldedAlt: alt.map(SearchText.fold),
                            words: words, initials: initials, bundleID: bundle?.bundleIdentifier)
        var known = Set([app.folded] + (app.foldedAlt.map { [$0] } ?? []))
        for other in localizedNames(path, languages: languages) where known.insert(SearchText.fold(other)).inserted {
            app.others.append(other)
            app.foldedOthers.append(SearchText.fold(other))
            app.othersWords.append(SearchText.words(other))
        }
        return app
    }

    /// Le app che corrispondono, col punteggio della corrispondenza e di quello che hai scelto prima.
    func match(_ query: String, limit: Int) -> [SearchResult] {
        let q = SearchText.fold(query).trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return [] }
        let running = runningBundles
        let iPhoneOn = SearchSettings.shared.iphoneApps
        var hits: [SearchResult] = []
        for app in apps where !app.iPhone || (iPhoneOn && !macNames.contains(app.folded)) {
            let main = SearchText.score(q, target: app.folded, words: app.words, initials: app.initials)
            let alt = app.foldedAlt.flatMap { SearchText.score(q, target: $0, words: app.words, initials: app.initials) }.map { $0 - 30 }
            // Il nome nell'altra lingua del Mac: «impostazioni» trova System Settings, e sotto si legge il nome italiano.
            var other: (score: Double, name: String)?
            for (index, folded) in app.foldedOthers.enumerated() {
                let words = app.othersWords[index]
                // Solo corrispondenze vere (uguale, inizio, parola, iniziali, dentro): con le lettere sparse «term» trovava
                // Anteprima e «saf» Scambio File Bluetooth.
                guard let s = SearchText.score(q, target: folded, words: words, initials: String(words.compactMap(\.first))),
                      s >= 400, s - 30 > (other?.score ?? -1) else { continue }
                other = (s - 30, app.others[index])
            }
            guard var score = [main, alt, other?.score].compactMap({ $0 }).max() else { continue }
            if app.iPhone {
                let id = "iphone:" + (app.bundleID ?? app.path)
                score += SearchMemory.shared.boost(id: id, query: q)
                hits.append(iPhoneResult(app, score: score + 25))
                continue
            }
            let id = "app:" + app.path
            score += SearchMemory.shared.boost(id: id, query: q)
            if let bundle = app.bundleID, running.contains(bundle) { score += 25 }
            let byOther = other.map { $0.score > (main ?? -1) && $0.score > (alt ?? -1) } ?? false
            hits.append(SearchResult(id: id, kind: .app, title: app.name, subtitle: byOther ? other!.name : Self.subtitle(app),
                                     url: URL(fileURLWithPath: app.path), label: String(localized: "ricerca.app"), score: score + 40))
        }
        return Array(hits.sorted { $0.score > $1.score }.prefix(limit))
    }

    private static func subtitle(_ app: SearchApp) -> String {
        let folder = (app.path as NSString).deletingLastPathComponent
        if folder == "/Applications" || folder.hasPrefix("/System/") { return app.altName ?? "" }
        return (folder as NSString).abbreviatingWithTildeInPath
    }
}

/// Le icone delle righe, già pronte e già piccole. L'icona che dà macOS ha dentro tutte le misure fino a 1024 punti, e
/// SwiftUI la ridisegnava dalla più grande: la prima comparsa dell'elenco costava fino a 80 ms. Qui ognuna si disegna una
/// volta, in sottofondo, in un'immagine di 64 pixel (la riga la mostra a 30 punti).
@MainActor @Observable
final class SearchIcons {
    static let shared = SearchIcons()
    @ObservationIgnored private let cache = NSCache<NSString, NSImage>()
    @ObservationIgnored private var pending = Set<String>()
    /// Cresce quando arrivano icone nuove: le righe che aspettavano la loro si ridisegnano.
    private(set) var version = 0

    private init() { cache.countLimit = 800 }

    /// L'icona già pronta, o `nil` (e allora si prepara in sottofondo): una riga non la disegna mai lei.
    func cached(_ path: String) -> NSImage? {
        _ = version
        if let image = cache.object(forKey: path as NSString) { return image }
        warm([path])
        return nil
    }

    func icon(for path: String) -> NSImage {
        if let image = cache.object(forKey: path as NSString) { return image }
        let image = Self.render(path)
        cache.setObject(image, forKey: path as NSString)
        return image
    }

    /// L'icona di un file o di un'app in 64 pixel. Si può chiamare da qualunque thread (il contesto grafico è suo).
    nonisolated static func render(_ path: String, pixels: Int = 64) -> NSImage {
        // Un'app raggiunta da un collegamento (Safari in /Applications porta dentro il sistema) avrebbe la freccina
        // degli alias nell'angolo: l'icona si prende dall'app vera.
        let real = path.hasSuffix(".app") ? URL(fileURLWithPath: path).resolvingSymlinksInPath().path : path
        let icon = NSWorkspace.shared.icon(forFile: real)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return icon }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        icon.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels), from: .zero, operation: .copy, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        guard let image = context.makeImage() else { return icon }
        return NSImage(cgImage: image, size: NSSize(width: pixels / 2, height: pixels / 2))
    }

    /// L'app che apre le pagine web: la sua icona va sulla riga di un indirizzo. Si cerca all'apertura della barra, non
    /// mentre si disegna la riga.
    private(set) var browserPath: String?

    func noteOpened() {
        browserPath = URL(string: "https://example.com").flatMap { NSWorkspace.shared.urlForApplication(toOpen: $0) }?.path
        if let browserPath, !has(browserPath) { warm([browserPath]) }
    }

    func store(_ image: NSImage, for path: String) {
        cache.setObject(image, forKey: path as NSString)
        pending.remove(path)
    }

    func has(_ path: String) -> Bool { cache.object(forKey: path as NSString) != nil }

    /// In sottofondo: le icone delle app si preparano tutte, una volta.
    func warm(_ paths: [String], quality: DispatchQoS.QoSClass = .utility) {
        let missing = paths.filter { !has($0) && !pending.contains($0) }
        guard !missing.isEmpty else { return }
        pending.formUnion(missing)
        DispatchQueue.global(qos: quality).async {
            let images = missing.map { path in (path, SearchIconBox(image: SearchIcons.render(path))) }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    for (path, box) in images { SearchIcons.shared.store(box.image, for: path) }
                    SearchIcons.shared.version += 1
                }
            }
        }
    }
}

struct SearchIconBox: @unchecked Sendable { let image: NSImage }

/// Quello che hai scelto prima: le app e i file che apri spesso salgono, e ricorda cosa avevi scelto scrivendo le
/// stesse lettere (scrivi «s» e scegli Safari: la volta dopo Safari è il primo con «s», come Spotlight).
///
/// Sta nelle preferenze, piccolo: al massimo 300 voci e 400 inizi di ricerca.
@MainActor
final class SearchMemory {
    static let shared = SearchMemory()

    private struct Entry: Codable {
        var count: Double
        var last: Date
        var title: String
        var kind: String
        var path: String?
    }

    private struct Stored: Codable {
        var entries: [String: Entry] = [:]
        var prefixes: [String: String] = [:]
    }

    private var stored = Stored()
    private static let key = "searchMemory"

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.key), let saved = try? JSONDecoder().decode(Stored.self, from: data) {
            stored = saved
        }
    }

    /// Quanto sale un risultato: quante volte l'hai scelto (pesano meno le scelte vecchie: dimezzano ogni due settimane)
    /// e, molto, se l'avevi scelto scrivendo proprio questo.
    func boost(id: String, query: String) -> Double {
        var boost = 0.0
        if let entry = stored.entries[id] {
            let days = max(0, -entry.last.timeIntervalSinceNow / 86_400)
            boost += 70 * log2(1 + entry.count) * pow(0.5, days / 14)
        }
        if stored.prefixes[String(query.prefix(8))] == id { boost += 380 }
        return boost
    }

    func remember(_ result: SearchResult, query: String) {
        guard [.app, .iphoneApp, .file, .folder].contains(result.kind) else { return }
        var entry = stored.entries[result.id] ?? Entry(count: 0, last: Date(), title: result.title, kind: "\(result.kind)", path: result.url?.path)
        entry.count += 1
        entry.last = Date()
        entry.title = result.title
        stored.entries[result.id] = entry
        let q = SearchText.fold(query).trimmingCharacters(in: .whitespaces)
        if !q.isEmpty {
            for length in 1...min(8, q.count) { stored.prefixes[String(q.prefix(length))] = result.id }
        }
        trim()
        save()
    }

    /// Le ultime cose aperte da qui, per la barra vuota: solo quelle che esistono ancora.
    func recents(limit: Int) -> [SearchResult] {
        let fm = FileManager.default
        return stored.entries.sorted { $0.value.last > $1.value.last }
            .prefix(24)
            .compactMap { id, entry -> SearchResult? in
                // Il segnaposto di un'app dell'iPhone non si può leggere: vale se il catalogo la conosce ancora.
                if entry.kind == "iphoneApp" {
                    guard SearchSettings.shared.iphoneApps, SearchCatalog.shared.hasIPhoneApp(id: id), let path = entry.path else { return nil }
                    return SearchResult(id: id, kind: .iphoneApp, title: entry.title, subtitle: String(localized: "App per iPhone"),
                                        url: URL(fileURLWithPath: path), value: String(id.dropFirst("iphone:".count)), label: "iPhone")
                }
                // Al massimo 24 controlli sul disco: un volume di rete staccato può far aspettare ognuno.
                guard let path = entry.path, fm.fileExists(atPath: path) else { return nil }
                let url = URL(fileURLWithPath: path)
                switch entry.kind {
                case "app":
                    return SearchResult(id: id, kind: .app, title: entry.title, subtitle: "", url: url, label: String(localized: "ricerca.app"))
                case "folder":
                    return SearchResult(id: id, kind: .folder, title: entry.title, subtitle: SearchFiles.shortPath(path), url: url,
                                        label: String(localized: "Cartella"))
                default:
                    return SearchResult(id: id, kind: .file, title: entry.title, subtitle: SearchFiles.shortPath(path), url: url,
                                        label: String(localized: "File"))
                }
            }
            .prefix(limit).map { $0 }
    }

    var isEmpty: Bool { stored.entries.isEmpty }

    func forget() {
        stored = Stored()
        UserDefaults.standard.removeObject(forKey: Self.key)
    }

    private func trim() {
        if stored.entries.count > 300 {
            let keep = stored.entries.sorted { $0.value.last > $1.value.last }.prefix(300)
            stored.entries = Dictionary(uniqueKeysWithValues: keep.map { ($0.key, $0.value) })
        }
        if stored.prefixes.count > 400 {
            stored.prefixes = stored.prefixes.filter { stored.entries[$0.value] != nil }
            if stored.prefixes.count > 400 { stored.prefixes = Dictionary(uniqueKeysWithValues: stored.prefixes.filter { $0.key.count <= 4 }.map { ($0.key, $0.value) }) }
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(stored) { UserDefaults.standard.set(data, forKey: Self.key) }
    }
}
