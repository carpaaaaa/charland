import Foundation

/// Lo sfondo su tutte le scrivanie (gli spazi di Mission Control). carpa, 20 novembre 2026: «deve esserci l'opzione
/// per attivarlo su tutti i desktop». `setDesktopImageURL` lo mette solo sullo spazio dove sei: su macOS 27 ogni
/// spazio ha il suo sfondo nel registro di WallpaperAgent (`~/Library/Application Support/com.apple.wallpaper/
/// Store/Index.plist`: `Spaces` › uuid dello spazio, con `Default` e `Displays` › uuid dello schermo, più
/// `Displays` per lo sfondo generale di ogni schermo). Qui si scrive il disegno in tutte le voci `Desktop` e si fa
/// ripartire WallpaperAgent, che rilegge il registro. Provato il 20 novembre 2026 su 78 spazi: tutti col disegno.
///
/// La copia del registro si fa prima di mettere il disegno da qualunque parte (anche solo sullo spazio dove sei) e
/// resta finché lo sfondo di Charland è acceso: spegnendo si rimettono com'erano solo le voci che hanno ancora un
/// nostro disegno. Così tornano anche gli sfondi dinamici, gli aerial e quelli di altre app (WallpaperMachine), che
/// `setDesktopImageURL` non sa rimettere, e non si tocca quello che chi usa il Mac ha cambiato nel frattempo.
enum AllSpaces {
    /// Perché lo sfondo non è arrivato negli altri spazi: si dice nelle Impostazioni (`WallpaperPane`), invece di tacere.
    /// Charland lo prova solo su macOS 27 con uno schermo: su un altro Mac il registro può essere diverso.
    enum Problem: String, Sendable {
        /// Il file del registro non c'è: la versione di macOS tiene gli sfondi altrove.
        case noRegistry
        /// C'è ma Charland non lo può leggere (permessi).
        case unreadable
        /// Si legge ma non ha la forma che Charland conosce.
        case unknownStructure
        /// La scrittura o la ripartenza di WallpaperAgent sono fallite.
        case writeFailed
        /// Scritto, ma dopo la ripartenza WallpaperAgent non lo ha tenuto.
        case agentIgnored
    }
    /// L'ultimo motivo di fallimento di `apply` (letto dopo che ha finito: `apply` gira su un thread di sfondo).
    nonisolated(unsafe) static var lastProblem: Problem?

    /// Solo per le prove (`WallpaperChecks.registryTest`): un registro e una copia finti, e gli spazi di Mission Control.
    struct Sandbox: Sendable { var index: URL; var backup: URL; var spaces: [String] }
    nonisolated(unsafe) static var sandbox: Sandbox?

    static var index: URL {
        sandbox?.index ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/com.apple.wallpaper/Store/Index.plist")
    }
    static var backup: URL { sandbox?.backup ?? WallpaperFiles.folder.appendingPathComponent("spazi-prima.plist") }
    static var hasBackup: Bool { FileManager.default.fileExists(atPath: backup.path) }

    /// Il registro si può usare? Nil se sì; altrimenti il motivo. Lo chiede chi vuole mettere lo sfondo negli altri spazi
    /// prima di cominciare (la copia del registro non si fa senza di lui).
    static func availabilityProblem() -> Problem? {
        let path = index.path
        guard FileManager.default.fileExists(atPath: path) else { return .noRegistry }
        guard FileManager.default.isReadableFile(atPath: path), (try? Data(contentsOf: index)) != nil else { return .unreadable }
        guard read(index) != nil else { return .unknownStructure }
        return nil
    }

    /// Salva il registro com'è, se non c'è già una copia.
    static func backupIfNeeded() {
        guard !hasBackup, FileManager.default.fileExists(atPath: index.path) else { return }
        try? FileManager.default.copyItem(at: index, to: backup)
    }

    /// Mette il disegno in ogni spazio: per ogni schermo il suo (`files`, per UUID dello schermo), per le voci senza
    /// schermo e per gli schermi senza disegno quello dello schermo principale (`fallback`). Falso se non ha scritto
    /// niente (registro mancante, struttura diversa da quella provata, scrittura o ripartenza fallite).
    ///
    /// Ogni voce diventa «individual» (scrivania e salvaschermo separati, come la scrive macOS per un'immagine). Le voci
    /// «linked» (un contenuto solo per tutte e due, com'è lo sfondo di serie) WallpaperAgent le legge da `Linked`:
    /// lì un `Desktop` aggiunto non si vede e ripartendo sparisce (carpa, 20 novembre 2026: «non mi mette più i walls
    /// su tutti i desktops»; gli altri spazi erano tornati allo sfondo di serie, in voci «linked»). Gli spazi che il
    /// registro non ha più (WallpaperAgent toglie quelli rimasti senza voci) si aggiungono da Mission Control.
    @discardableResult
    static func apply(files: [String: URL], fallback: URL) -> Bool {
        lastProblem = nil
        if let problem = availabilityProblem() { lastProblem = problem; return false }
        guard let root = read(index) else { lastProblem = .unreadable; return false }
        let spaces = (root["Spaces"] as? NSMutableDictionary) ?? NSMutableDictionary()
        root["Spaces"] = spaces
        for uuid in missionControlSpaces() where spaces[uuid] == nil {
            let displays = NSMutableDictionary()
            for key in files.keys { displays[key] = NSMutableDictionary() }
            spaces[uuid] = NSMutableDictionary(dictionary: ["Default": NSMutableDictionary(), "Displays": displays])
        }
        guard spaces.count > 0 else { lastProblem = .unknownStructure; return false }
        let options = imageOptions(in: root)
        // La copia segue le scelte fatte dopo (uno sfondo messo da Impostazioni di Sistema su un altro spazio mentre
        // Charland era acceso): spegnendo torna quella, non lo sfondo di prima. Non le voci che WallpaperAgent ha
        // rimesso di serie: lì nella copia resta lo sfondo vero di prima.
        let saved = read(backup)
        var savedChanged = false
        func put(_ value: NSMutableDictionary, display: String?, path: [String]) {
            if let saved, value.count > 0, !(value["Desktop"].map(isOurs) ?? false), !isDefaultReset(value), let copy = deepCopy(value) {
                set(copy, at: path, in: saved)
                savedChanged = true
            }
            makeIndividual(value)
            value["Desktop"] = desktopEntry(url: display.flatMap { files[$0] } ?? fallback, options: options)
        }
        var written = 0
        for case let (uuid as String, space as NSMutableDictionary) in spaces {
            if let def = space["Default"] as? NSMutableDictionary { put(def, display: nil, path: ["Spaces", uuid, "Default"]); written += 1 }
            if let displays = space["Displays"] as? NSMutableDictionary {
                for case let (key as String, value as NSMutableDictionary) in displays {
                    put(value, display: key, path: ["Spaces", uuid, "Displays", key]); written += 1
                }
            }
        }
        guard written > 0 else { lastProblem = .unknownStructure; return false }
        // Lo sfondo generale di ogni schermo, anche di uno che il registro non ha ancora (un monitor collegato dopo).
        let general = (root["Displays"] as? NSMutableDictionary) ?? NSMutableDictionary()
        root["Displays"] = general
        for key in files.keys where general[key] == nil { general[key] = NSMutableDictionary() }
        for case let (key as String, value as NSMutableDictionary) in general { put(value, display: key, path: ["Displays", key]) }
        // «Su tutte le scrivanie e schermi»: se chi usa il Mac ha scelto uno sfondo così in Impostazioni di Sistema, la
        // voce vale per tutti gli spazi e ha la precedenza sulle altre. Quella di solo salvaschermo (`idle`) resta com'è.
        // È una voce sola: con due schermi prende il disegno del principale, e sull'altro si vede quello riscalato
        // (stesso vetro sulla stessa immagine). Le voci di ogni spazio tengono il disegno del loro schermo.
        if let all = root["AllSpacesAndDisplays"] as? NSMutableDictionary, usesWallpaper(all) {
            put(all, display: nil, path: ["AllSpacesAndDisplays"])
        }
        if savedChanged, let saved { _ = write(saved, to: backup) }
        guard write(root, to: index) else { lastProblem = .writeFailed; return false }
        guard restartAgent() else { lastProblem = .writeFailed; return false }
        return true
    }

    /// La voce ha uno sfondo della scrivania (un `Desktop`, o un contenuto «linked» per scrivania e salvaschermo
    /// insieme): non una voce di solo salvaschermo.
    private static func usesWallpaper(_ entry: NSDictionary) -> Bool {
        if entry["Desktop"] != nil { return true }
        return (entry["Type"] as? String) == "linked" && entry["Linked"] != nil
    }

    /// Ogni voce di ogni spazio (`Default` e ogni schermo) mostra uno dei disegni `files` (dopo la ripartenza:
    /// WallpaperAgent non ha riscritto il suo stato sopra). Si contano le voci e non i `Desktop`: una voce tornata
    /// «linked» non ha `Desktop`, e contando solo quelli sembrava tutto a posto con uno spazio solo col disegno.
    static func points(to files: [String: URL]) -> Bool {
        guard !files.isEmpty, let root = read(index), let spaces = root["Spaces"] as? NSDictionary else { return false }
        let names = Set(files.values.map(\.lastPathComponent))
        var total = 0, matching = 0
        func check(_ value: Any?) {
            guard let entry = value as? NSDictionary else { return }
            total += 1
            if let desktop = entry["Desktop"], let url = imageURL(of: desktop), names.contains(where: { url.hasSuffix($0) }) { matching += 1 }
        }
        for case let space as NSDictionary in spaces.allValues {
            check(space["Default"])
            if let displays = space["Displays"] as? NSDictionary { for value in displays.allValues { check(value) } }
        }
        if let all = root["AllSpacesAndDisplays"] as? NSDictionary, usesWallpaper(all) { check(all) }
        return total > 0 && matching == total
    }

    /// Qualche spazio ha perso il disegno senza che chi usa il Mac abbia scelto altro: una voce rimessa di serie da
    /// WallpaperAgent, o un nostro disegno vecchio. Uno sfondo scelto in Impostazioni di Sistema su uno spazio non
    /// conta: la riparazione automatica non lo calpesta.
    static func needsRepair(files: [String: URL]) -> Bool {
        guard !files.isEmpty, let root = read(index), let spaces = root["Spaces"] as? NSDictionary else { return false }
        let names = Set(files.values.map(\.lastPathComponent))
        func lost(_ value: Any?) -> Bool {
            guard let entry = value as? NSDictionary else { return false }
            if isDefaultReset(entry) { return true }
            guard let desktop = entry["Desktop"], isOurs(desktop), let url = imageURL(of: desktop) else { return false }
            return !names.contains(where: { url.hasSuffix($0) })
        }
        for case let space as NSDictionary in spaces.allValues {
            if lost(space["Default"]) { return true }
            if let displays = space["Displays"] as? NSDictionary, displays.allValues.contains(where: lost) { return true }
        }
        // Anche la voce «su tutte le scrivanie e schermi», se l'avevamo presa: rimessa di serie va ripresa, una scelta
        // di chi usa il Mac no (revisione Sonnet).
        if let all = root["AllSpacesAndDisplays"] as? NSDictionary, usesWallpaper(all), lost(all) { return true }
        return false
    }

    /// Ogni voce che mostra un nostro disegno torna com'era nella copia, intera (anche «linked», col salvaschermo); se
    /// nella copia c'era già un nostro disegno o la voce mancava (uno spazio nato dopo), torna lo sfondo di serie col
    /// salvaschermo che ha. Le altre voci restano come sono. `keepBackup`: la copia serve ancora (lo sfondo resta acceso sullo
    /// spazio dove sei). Falso se la scrittura o la ripartenza falliscono: la copia allora resta.
    @discardableResult
    static func restore(keepBackup: Bool) -> Bool {
        guard let old = read(backup), let root = read(index) else { return false }
        var changed = 0
        // Su tutto l'albero, alla stessa posizione nella copia: anche `SystemDefault` e `AllSpacesAndDisplays`, dove
        // macOS scrive da solo (il 20 novembre 2026 c'era un nostro disegno in `SystemDefault`).
        func merge(_ target: NSMutableDictionary, _ source: NSDictionary?) {
            // Su una copia delle chiavi: il dizionario cambia mentre lo si percorre.
            for case let key as String in target.allKeys {
                guard let child = target[key] as? NSMutableDictionary else { continue }
                guard let desktop = child["Desktop"], isOurs(desktop) else {
                    merge(child, source?[key] as? NSDictionary)
                    continue
                }
                if let old = source?[key] as? NSDictionary, !(old["Desktop"].map(isOurs) ?? false) {
                    target[key] = old.mutableCopy()
                } else {
                    // Mai una voce «individual» senza `Desktop`: lo sfondo di serie, col salvaschermo che aveva.
                    child.removeObject(forKey: "Desktop")
                    child["Linked"] = child["Idle"] ?? defaultIdle()
                    child.removeObject(forKey: "Idle")
                    child["Type"] = "linked"
                }
                changed += 1
            }
        }
        merge(root, old)
        // Lo sfondo generale di uno schermo che il registro non aveva (l'abbiamo aggiunto per un monitor collegato
        // dopo): si toglie, invece di lasciare una voce «linked» in più (revisione Sonnet).
        if let general = root["Displays"] as? NSMutableDictionary {
            let before = old["Displays"] as? NSDictionary
            for case let key as String in general.allKeys where before?[key] == nil {
                if let entry = general[key] as? NSDictionary, isDefaultReset(entry) || entry.count == 0 { general.removeObject(forKey: key) }
            }
            if general.count == 0, old["Displays"] == nil { root.removeObject(forKey: "Displays") }
        }
        if changed > 0 {
            guard write(root, to: index), restartAgent() else { return false }
        }
        if !keepBackup { try? FileManager.default.removeItem(at: backup) }
        return true
    }

    /// I nostri disegni che il registro mostra ancora, in qualunque spazio (percorsi).
    static func referencedDrawings() -> Set<String> {
        guard let root = read(index) else { return [] }
        var out = Set<String>()
        visitDesktops(root) { desktop in
            guard let text = imageURL(of: desktop), text.contains("/Sfondo/favo-"), let url = URL(string: text) else { return }
            out.insert(url.standardizedFileURL.path)
        }
        return out
    }

    // MARK: - Registro

    /// Una voce che WallpaperAgent ha rimesso di serie («linked» col fornitore `default`), non una scelta di chi usa il Mac.
    private static func isDefaultReset(_ value: NSDictionary) -> Bool {
        guard (value["Type"] as? String) == "linked", let content = (value["Linked"] as? NSDictionary)?["Content"] as? NSDictionary,
              let choices = content["Choices"] as? NSArray, choices.count > 0 else { return false }
        return choices.allSatisfy { (($0 as? NSDictionary)?["Provider"] as? String) == "default" }
    }

    /// Una copia vera (anche dei dizionari dentro), da scrivere nella copia del registro.
    private static func deepCopy(_ value: NSDictionary) -> NSMutableDictionary? {
        guard let data = try? PropertyListSerialization.data(fromPropertyList: value, format: .binary, options: 0) else { return nil }
        return (try? PropertyListSerialization.propertyList(from: data, options: .mutableContainersAndLeaves, format: nil)) as? NSMutableDictionary
    }

    /// Mette `value` a quel percorso, creando i dizionari che mancano.
    private static func set(_ value: Any, at path: [String], in root: NSMutableDictionary) {
        guard let last = path.last else { return }
        var node = root
        for key in path.dropLast() {
            if let next = node[key] as? NSMutableDictionary { node = next } else {
                let next = NSMutableDictionary()
                node[key] = next
                node = next
            }
        }
        node[last] = value
    }

    /// Una voce «linked» (o di un altro tipo) diventa «individual»: il salvaschermo resta quello che aveva.
    private static func makeIndividual(_ value: NSMutableDictionary) {
        guard (value["Type"] as? String) != "individual" else { return }
        if value["Idle"] == nil { value["Idle"] = value["Linked"] ?? defaultIdle() }
        value.removeObject(forKey: "Linked")
        value["Type"] = "individual"
    }

    /// Il salvaschermo di serie, come lo scrive macOS.
    private static func defaultIdle() -> NSDictionary {
        let choice: NSDictionary = ["Configuration": Data(), "Files": NSArray(), "Provider": "default"]
        let content: NSDictionary = ["Choices": NSArray(object: choice), "EncodedOptionValues": "$null", "Shuffle": "$null"]
        let now = Date()
        return ["Content": content, "LastSet": now, "LastUse": now]
    }

    /// Gli spazi delle scrivanie in Mission Control (non quelli delle app a tutto schermo), per UUID; quello principale è "".
    private static func missionControlSpaces() -> [String] {
        if let sandbox { return sandbox.spaces }
        guard let config = CFPreferencesCopyAppValue("SpacesDisplayConfiguration" as CFString, "com.apple.spaces" as CFString) as? [String: Any],
              let data = config["Management Data"] as? [String: Any], let monitors = data["Monitors"] as? [[String: Any]] else { return [] }
        return monitors.flatMap { monitor in
            (monitor["Spaces"] as? [[String: Any]] ?? []).compactMap { space in
                (space["type"] as? Int ?? 0) == 0 ? space["uuid"] as? String : nil
            }
        }
    }

    private static func read(_ url: URL) -> NSMutableDictionary? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return (try? PropertyListSerialization.propertyList(from: data, options: .mutableContainersAndLeaves, format: nil)) as? NSMutableDictionary
    }

    private static func write(_ root: NSDictionary, to url: URL) -> Bool {
        guard let data = try? PropertyListSerialization.data(fromPropertyList: root, format: .binary, options: 0) else { return false }
        return (try? data.write(to: url, options: .atomic)) != nil
    }

    /// WallpaperAgent rilegge il registro solo ripartendo. Con -9 non fa in tempo a riscriverlo col suo stato.
    /// Uscita 1 di killall vuol dire che non era acceso: rileggerà il registro quando parte.
    private static func restartAgent() -> Bool {
        if sandbox != nil { return true }
        let kill = Process()
        kill.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        kill.arguments = ["-9", "WallpaperAgent"]
        guard (try? kill.run()) != nil else { return false }
        kill.waitUntilExit()
        return kill.terminationStatus == 0 || kill.terminationStatus == 1
    }

    /// Una voce `Desktop` con un'immagine, come la scrive macOS.
    private static func desktopEntry(url: URL, options: Data) -> NSMutableDictionary {
        let config: [String: Any] = ["type": "imageFile", "url": ["relative": url.absoluteString]]
        let configData = (try? PropertyListSerialization.data(fromPropertyList: config, format: .binary, options: 0)) ?? Data()
        let choice: NSDictionary = ["Configuration": configData, "Files": NSArray(), "Provider": "com.apple.wallpaper.choice.image"]
        let content: NSDictionary = ["Choices": NSArray(object: choice), "EncodedOptionValues": options, "Shuffle": "$null"]
        let now = Date()
        return ["Content": content, "LastSet": now, "LastUse": now]
    }

    /// Le opzioni di una voce con un nostro disegno (le ha scritte macOS con «riempi lo schermo»), o quelle di serie
    /// («Crop»). Mai quelle di un'altra voce qualunque: potrebbero essere «adatta», con le bande nere.
    private static func imageOptions(in root: NSDictionary) -> Data {
        var found: Data?
        visitDesktops(root) { desktop in
            guard found == nil, isOurs(desktop), let content = (desktop as? NSDictionary)?["Content"] as? NSDictionary,
                  let data = content["EncodedOptionValues"] as? Data else { return }
            found = data
        }
        if let found { return found }
        let fill: [String: Any] = ["values": ["placement": ["picker": ["_0": ["id": "Crop"]]]]]
        return (try? PropertyListSerialization.data(fromPropertyList: fill, format: .binary, options: 0)) ?? Data()
    }

    /// Ogni voce `Desktop` del registro, dovunque stia.
    private static func visitDesktops(_ value: Any, _ body: (Any) -> Void) {
        guard let dict = value as? NSDictionary else { return }
        for case let (key as String, item) in dict {
            if key == "Desktop" { body(item) } else { visitDesktops(item, body) }
        }
    }

    private static func imageURL(of desktop: Any) -> String? {
        guard let content = (desktop as? NSDictionary)?["Content"] as? NSDictionary, let choices = content["Choices"] as? NSArray else { return nil }
        for choice in choices {
            guard let data = (choice as? NSDictionary)?["Configuration"] as? Data,
                  let config = try? PropertyListSerialization.propertyList(from: data, format: nil) as? NSDictionary,
                  let url = (config["url"] as? NSDictionary)?["relative"] as? String else { continue }
            return url
        }
        return nil
    }

    /// La voce `Desktop` mostra un nostro disegno.
    private static func isOurs(_ desktop: Any) -> Bool {
        guard let url = imageURL(of: desktop) else { return false }
        return url.contains("/Sfondo/favo-")
    }
}
