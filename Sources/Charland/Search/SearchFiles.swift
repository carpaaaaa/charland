import AppKit
import CoreServices

/// File e cartelle, dall'indice di Spotlight: la stessa fonte della ricerca di macOS, nessun indice nostro.
///
/// Una domanda sincrona (`MDQuery`) su una coda a parte, mai sul thread principale: di solito costa qualche decina di
/// millisecondi, con un disco grande e occupato anche qualche centinaio. Ogni lettera nuova fa partire una domanda
/// nuova e le risposte vecchie si buttano (`generation`). Si cerca nella cartella dell'utente (dove stanno i suoi
/// documenti, iCloud Drive compreso), mai nelle cartelle di sistema; le app le trova già il catalogo.
enum SearchFiles {
    struct Hit: Sendable {
        let path: String
        let name: String
        let folder: Bool
        let kind: String
        let lastUsed: Date?
    }

    private static let queue = DispatchQueue(label: "charland.ricerca.file", qos: .userInitiated)
    private nonisolated(unsafe) static var generation = 0
    private static let lock = NSLock()

    /// Cerca e risponde sul thread principale (solo se nel frattempo non è partita un'altra ricerca).
    @MainActor
    static func search(_ query: String, limit: Int, delay: TimeInterval, done: @escaping @MainActor ([Hit]) -> Void) {
        let mine = bump()
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= 2 else { return }
        queue.asyncAfter(deadline: .now() + delay) {
            guard current == mine else { return }
            let hits = run(trimmed, limit: limit)
            guard current == mine else { return }
            // Le icone si preparano qui, fuori dal thread principale: chiederle mentre si disegna la riga costava un
            // fotogramma a ogni file nuovo.
            let icons = hits.map { hit in (hit.path, SearchIconBox(image: SearchIcons.render(hit.path))) }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    for (path, box) in icons where !SearchIcons.shared.has(path) { SearchIcons.shared.store(box.image, for: path) }
                    guard current == mine else { return }
                    done(hits)
                }
            }
        }
    }

    /// Le ricerche in corso non servono più (barra chiusa, testo cancellato).
    static func cancel() { _ = bump() }

    private static func bump() -> Int {
        lock.lock(); defer { lock.unlock() }
        generation += 1
        return generation
    }

    private static var current: Int {
        lock.lock(); defer { lock.unlock() }
        return generation
    }

    /// Le parole della ricerca, ognuna dentro il nome; niente app (le trova il catalogo), niente file di sistema.
    private static func run(_ query: String, limit: Int) -> [Hit] {
        let tokens = query.split(whereSeparator: { $0.isWhitespace }).map { token in
            // Nel linguaggio delle domande di Spotlight `*` è un jolly e `"` chiude la parola: si tolgono.
            token.replacingOccurrences(of: "\\", with: "").replacingOccurrences(of: "\"", with: "").replacingOccurrences(of: "*", with: "")
        }.filter { !$0.isEmpty }
        guard !tokens.isEmpty else { return [] }
        var clauses = tokens.map { "kMDItemDisplayName == \"*\($0)*\"cd" }
        clauses.append("kMDItemContentType != \"com.apple.application-bundle\"")
        let text = clauses.joined(separator: " && ")
        guard let spotlight = MDQueryCreate(kCFAllocatorDefault, text as CFString, nil, nil) else { return [] }
        MDQuerySetSearchScope(spotlight, [kMDQueryScopeHome] as CFArray, 0)
        // Ampio: le cose nascoste (Libreria, `node_modules`) si tolgono dopo, e con un limite stretto per una parola corta
        // («log», «index») potevano restare solo quelle.
        MDQuerySetMaxCount(spotlight, 450)
        guard MDQueryExecute(spotlight, CFOptionFlags(kMDQuerySynchronous.rawValue)) else { return [] }
        let count = MDQueryGetResultCount(spotlight)
        var hits: [Hit] = []
        hits.reserveCapacity(count)
        for index in 0..<count {
            guard let raw = MDQueryGetResultAtIndex(spotlight, index) else { continue }
            let item = Unmanaged<MDItem>.fromOpaque(raw).takeUnretainedValue()
            guard let path = MDItemCopyAttribute(item, kMDItemPath) as? String, !hidden(path) else { continue }
            let name = MDItemCopyAttribute(item, kMDItemDisplayName) as? String ?? (path as NSString).lastPathComponent
            let type = MDItemCopyAttribute(item, kMDItemContentType) as? String ?? ""
            let kind = MDItemCopyAttribute(item, kMDItemKind) as? String ?? ""
            let used = MDItemCopyAttribute(item, kMDItemLastUsedDate) as? Date
                ?? MDItemCopyAttribute(item, kMDItemContentModificationDate) as? Date
            hits.append(Hit(path: path, name: name, folder: type == "public.folder" || type == "com.apple.mount-point",
                            kind: kind, lastUsed: used))
        }
        // In alto i nomi che cominciano con la ricerca, poi quelli dove comincia una parola, poi gli altri; a parità,
        // quello usato più di recente. Le cartelle troppo in fondo valgono un poco meno.
        let folded = SearchText.fold(query)
        func rank(_ hit: Hit) -> Double {
            let name = SearchText.fold(hit.name)
            var score = SearchText.score(folded, target: name, words: SearchText.words(hit.name),
                                         initials: String(SearchText.words(hit.name).compactMap(\.first))) ?? 200
            if let used = hit.lastUsed {
                let days = max(0, -used.timeIntervalSinceNow / 86_400)
                score += 120 * pow(0.5, days / 30)
            }
            score -= Double(max(0, hit.path.split(separator: "/").count - 6)) * 6
            return score
        }
        return Array(hits.map { ($0, rank($0)) }.sorted { $0.1 > $1.1 }.prefix(limit).map(\.0))
    }

    /// Cose che nessuno cerca: cartelle nascoste, la Libreria, le dipendenze dei progetti, l'interno dei pacchetti, i
    /// pezzi delle compilazioni («term» dava solo file di Python dentro Homebrew, «system settings» file `.o` e
    /// `.swiftdeps`).
    private static func hidden(_ path: String) -> Bool {
        // iCloud Drive e i servizi come Dropbox stanno dentro la Libreria, ma sono documenti veri.
        let cloud = path.contains("/Library/Mobile Documents/") || path.contains("/Library/CloudStorage/")
        if path.contains("/.") || (path.contains("/Library/") && !cloud) || path.contains("/node_modules/") { return true }
        if path.contains(".app/") || path.contains(".xcodeproj/") || path.contains(".photoslibrary/") { return true }
        if path.contains("/DerivedData/") || path.contains("/Pods/") || path.contains(".noindex/") { return true }
        if path.contains("/homebrew/") || path.contains("/Homebrew/") || path.contains("/__pycache__/")
            || path.contains("/site-packages/") || path.contains("/Build/Intermediates") { return true }
        let ext = (path as NSString).pathExtension.lowercased()
        return buildExtensions.contains(ext)
    }

    private static let buildExtensions: Set<String> = ["o", "pyc", "pyo", "swiftdeps", "swiftmodule", "swiftdoc", "swiftsourceinfo",
                                                       "swiftconstvalues", "dia", "hmap"]

    /// Il percorso corto per la riga: la cartella che contiene, dalla casa dell'utente (`~/Documenti/Lavoro`).
    static func shortPath(_ path: String) -> String {
        let folder = (path as NSString).deletingLastPathComponent
        var short = (folder as NSString).abbreviatingWithTildeInPath
        short = short.replacingOccurrences(of: "~/Library/Mobile Documents/com~apple~CloudDocs", with: "iCloud Drive")
        let parts = short.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count > 4 else { return short }
        return parts.prefix(2).joined(separator: "/") + "/…/" + parts.suffix(2).joined(separator: "/")
    }

    static func result(_ hit: Hit, boost: Double) -> SearchResult {
        let id = "file:" + hit.path
        return SearchResult(id: id, kind: hit.folder ? .folder : .file, title: hit.name, subtitle: shortPath(hit.path),
                            url: URL(fileURLWithPath: hit.path),
                            label: hit.folder ? String(localized: "Cartella") : (hit.kind.isEmpty ? String(localized: "File") : hit.kind),
                            score: boost)
    }
}
