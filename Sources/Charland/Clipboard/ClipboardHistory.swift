import AppKit
import CharlandCore
import Carbon.HIToolbox
import CryptoKit
import ImageIO
import Observation

/// Una cosa copiata, come la ricorda lo storico degli appunti. Il contenuto vero (tutti i formati che l'app aveva messo
/// negli appunti) sta su disco, in un file per voce: qui solo quello che serve a mostrarla, cercarla e ordinarla.
struct ClipItem: Codable, Identifiable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable { case text, link, color, image, file }

    let id: UUID
    var kind: Kind
    /// Una riga sola, già pulita: quella che si vede nel menu.
    var title: String
    /// Il testo intero (fino a `ClipboardHistory.textLimit`), per cercare e per l'anteprima.
    var text: String?
    /// I file copiati dal Finder, come percorsi.
    var files: [String]?
    var width: Int?
    var height: Int?
    /// L'app che era davanti quando è stata copiata.
    var app: String?
    var appName: String?
    var first: Date
    var last: Date
    var count: Int
    var pinned: Bool
    /// Per riconoscere la stessa cosa copiata due volte: il testo, i file o l'immagine, non la formattazione.
    var signature: String
}

/// Le impostazioni dello storico degli appunti, con le sue scorciatoie (le stesse di Maccy di serie: carpa lo usava).
@MainActor @Observable
final class ClipboardSettings {
    static let shared = ClipboardSettings()

    /// Acceso: Charland ricorda quello che copi e il clic sulla farfalla apre il menu. Spento: niente ascolto, e il clic
    /// apre la casa dell'isola come prima.
    var enabled: Bool { didSet { guard ready else { return }; UserDefaults.standard.set(enabled, forKey: "clipboardEnabled"); ClipboardHistory.shared.apply() } }
    /// Scegliendo una voce la incolla subito nell'app in primo piano (con ⌥ solo copia, e viceversa).
    var pasteOnSelect: Bool { didSet { guard ready else { return }; UserDefaults.standard.set(pasteOnSelect, forKey: "clipboardPaste") } }
    /// Quante voci tiene, oltre a quelle fissate.
    var limit: Int { didSet { guard ready else { return }; UserDefaults.standard.set(limit, forKey: "clipboardLimit"); ClipboardHistory.shared.trim() } }

    var openCombo: KeyCombo? { didSet { guard ready else { return }; Self.store(openCombo, "clipboardOpenCombo"); ClipboardMenu.shared.registerShortcut() } }
    var pinCombo: KeyCombo? { didSet { guard ready else { return }; Self.store(pinCombo, "clipboardPinCombo") } }
    var deleteCombo: KeyCombo? { didSet { guard ready else { return }; Self.store(deleteCombo, "clipboardDeleteCombo") } }
    var previewCombo: KeyCombo? { didSet { guard ready else { return }; Self.store(previewCombo, "clipboardPreviewCombo") } }

    /// La scorciatoia per aprire è tenuta da un'altra app (Maccy, finché resta acceso, tiene ⇧⌘C).
    var openTaken = false
    /// Con `@Observable` i `didSet` scattano anche dentro `init`: lì non devono salvare né registrare niente (la
    /// scorciatoia chiedeva `shared` mentre `shared` si stava creando, e l'app si fermava).
    @ObservationIgnored private var ready = false

    /// ⇧⌘C apre, ⌥P fissa, ⌥⌫ elimina: come Maccy. ⌘Y per l'anteprima, come Quick Look nel Finder (⌥spazio sul Mac
    /// di carpa lo prende un'altra scorciatoia di sistema prima di Charland).
    static let openDefault = KeyCombo(keyCode: UInt32(kVK_ANSI_C), modifiers: UInt32(cmdKey | shiftKey))
    static let pinDefault = KeyCombo(keyCode: UInt32(kVK_ANSI_P), modifiers: UInt32(optionKey))
    static let deleteDefault = KeyCombo(keyCode: UInt32(kVK_Delete), modifiers: UInt32(optionKey))
    static let previewDefault = KeyCombo(keyCode: UInt32(kVK_ANSI_Y), modifiers: UInt32(cmdKey))
    /// Cancella lo storico (non i fissati): fissa, ⌥⌘⌫ come in Maccy.
    static let clearCombo = KeyCombo(keyCode: UInt32(kVK_Delete), modifiers: UInt32(optionKey | cmdKey))

    static let limits = [50, 100, 200, 500, 1000]

    private init() {
        let d = UserDefaults.standard
        enabled = d.object(forKey: "clipboardEnabled") as? Bool ?? true
        pasteOnSelect = d.object(forKey: "clipboardPaste") as? Bool ?? true
        limit = d.object(forKey: "clipboardLimit") as? Int ?? 200
        openCombo = Self.load("clipboardOpenCombo", default: Self.openDefault)
        pinCombo = Self.load("clipboardPinCombo", default: Self.pinDefault)
        deleteCombo = Self.load("clipboardDeleteCombo", default: Self.deleteDefault)
        previewCombo = Self.load("clipboardPreviewCombo", default: Self.previewDefault)
        ready = true
    }

    private static func store(_ combo: KeyCombo?, _ key: String) {
        UserDefaults.standard.set(combo.flatMap { try? JSONEncoder().encode($0) }, forKey: key)
        UserDefaults.standard.set(combo == nil, forKey: key + "Cleared")
    }

    private static func load(_ key: String, default value: KeyCombo) -> KeyCombo? {
        let d = UserDefaults.standard
        if let data = d.data(forKey: key), let saved = try? JSONDecoder().decode(KeyCombo.self, from: data) { return saved }
        return d.bool(forKey: key + "Cleared") ? nil : value
    }
}

/// Lo storico degli appunti, come Maccy: ogni mezzo secondo guarda se gli appunti sono cambiati (il conteggio dei
/// cambi costa niente e non chiede permessi), e se sì ricorda quello che c'è. Non ricorda le cose segnate come
/// riservate o passeggere (password dei gestori, la dettatura di Charland che incolla e rimette gli appunti com'erano),
/// né quello che copi dalle app delle password.
@MainActor @Observable
final class ClipboardHistory {
    static let shared = ClipboardHistory()

    /// Dalla più recente alla più vecchia.
    private(set) var items: [ClipItem] = []

    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var lastChange = NSPasteboard.general.changeCount
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var loaded = false

    /// Il segno che Charland mette sugli appunti che scrive lei, rimettendo una voce dello storico: non va ricordata di
    /// nuovo come se l'avessi copiata tu.
    static let marker = NSPasteboard.PasteboardType("com.charstudio.charland.clipboard")

    /// Chi segna gli appunti da non ricordare (lo standard di nspasteboard.org, più i gestori di password che non lo usano).
    private static let skipped: Set<String> = [
        marker.rawValue,
        "org.nspasteboard.TransientType", "org.nspasteboard.ConcealedType", "org.nspasteboard.AutoGeneratedType",
        "com.agilebits.onepassword", "de.petermaurer.TransientPasteboardType", "com.typeit4me.clipping",
        "Pasteboard generator type", "net.antelle.keeweb",
    ]

    /// Le app delle password: quello che si copia lì non si ricorda mai.
    private static let skippedApps: Set<String> = [
        "com.apple.Passwords", "com.apple.keychainaccess", "com.1password.1password", "com.agilebits.onepassword7",
        "com.bitwarden.desktop", "com.lastpass.LastPass", "com.dashlane.dashlanephonefinal", "org.keepassxc.keepassxc",
        "in.sinew.Enpass-Desktop", "com.nordpass.macos.NordPass",
    ]

    /// I formati che si tengono. Solo questi: leggere tutti i formati di un'app (Excel, Figma) li fa generare uno per uno
    /// e può bloccare per secondi.
    private static let kept: [String] = [
        "public.utf8-plain-text", "public.rtf", "public.html", "public.png", "public.tiff", "public.jpeg", "public.heic",
        "public.file-url", "public.url", "public.url-name", "com.apple.flat-rtfd",
    ]
    private static let imageTypes = ["public.png", "public.tiff", "public.jpeg", "public.heic"]

    /// Fino a quanto testo si tiene in memoria per cercare e per l'anteprima.
    static let textLimit = 50_000
    /// Oltre questo peso le immagini non si tengono (il testo sì).
    private static let byteLimit = 40_000_000

    private init() {}

    // MARK: Accensione

    /// All'avvio e quando cambia l'interruttore.
    func apply() {
        if ClipboardSettings.shared.enabled { start() } else { stop() }
        ClipboardMenu.shared.registerShortcut()
    }

    func start() {
        load()
        guard timer == nil else { return }
        // Quello che c'era già negli appunti prima di accendere non si ricorda: solo le copie da qui in poi.
        lastChange = NSPasteboard.general.changeCount
        let timer = Timer(timeInterval: 0.5, repeats: true) { _ in
            MainActor.assumeIsolated { ClipboardHistory.shared.poll() }
        }
        timer.tolerance = 0.1
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { ClipboardMenu.shared.warmUp() }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        ClipboardMenu.shared.close(animated: false)
        // Un salvataggio in attesa si scrive adesso: uscendo (o aggiornando l'app) entro 0,6 s da una cancellazione
        // restava su disco l'indice vecchio, e lo storico cancellato tornava all'avvio dopo.
        if saveTask != nil { saveNow() }
    }

    /// C'è uno storico salvato su disco, anche se adesso è spento e non è stato caricato.
    var hasStoredHistory: Bool {
        !items.isEmpty || (!loaded && FileManager.default.fileExists(atPath: Self.indexURL.path))
    }

    // MARK: Ascolto

    private func poll() {
        let board = NSPasteboard.general
        guard board.changeCount != lastChange else { return }
        lastChange = board.changeCount
        guard let entries = Self.read(board) else { return }
        let front = NSWorkspace.shared.frontmostApplication
        if let bundle = front?.bundleIdentifier, Self.skippedApps.contains(bundle) { return }
        guard var item = Self.describe(entries) else { return }
        item.app = front?.bundleIdentifier
        item.appName = front?.localizedName
        remember(item, entries: entries)
    }

    /// I formati da tenere di ogni elemento degli appunti, o `nil` se gli appunti vanno ignorati.
    private static func read(_ board: NSPasteboard) -> [[String: Data]]? {
        guard let pasteboardItems = board.pasteboardItems, !pasteboardItems.isEmpty else { return nil }
        for item in pasteboardItems where item.types.contains(where: { skipped.contains($0.rawValue) }) { return nil }
        var entries: [[String: Data]] = []
        var total = 0
        for item in pasteboardItems.prefix(100) {
            let types = Set(item.types.map(\.rawValue))
            var entry: [String: Data] = [:]
            for type in kept where types.contains(type) {
                // Il PNG basta: il TIFF dello stesso disegno pesa dieci volte tanto.
                if type == "public.tiff", entry["public.png"] != nil || types.contains("public.png") { continue }
                if let data = item.data(forType: NSPasteboard.PasteboardType(type)) {
                    entry[type] = data
                    total += data.count
                }
            }
            if !entry.isEmpty { entries.append(entry) }
        }
        if total > byteLimit {
            // Troppo pesante: si tiene il testo, se c'è, e si lasciano le immagini.
            entries = entries.map { $0.filter { !imageTypes.contains($0.key) && $0.key != "com.apple.flat-rtfd" } }.filter { !$0.isEmpty }
        }
        return entries.isEmpty ? nil : entries
    }

    /// Che cosa è, come si chiama in una riga, e la sua impronta.
    private static func describe(_ entries: [[String: Data]]) -> ClipItem? {
        let now = Date()
        func make(_ kind: ClipItem.Kind, title: String, signature: String) -> ClipItem {
            ClipItem(id: UUID(), kind: kind, title: title, first: now, last: now, count: 1, pinned: false, signature: signature)
        }
        let files = entries.compactMap { $0["public.file-url"].flatMap { String(data: $0, encoding: .utf8) } }
            .compactMap { URL(string: $0) }.filter(\.isFileURL)
        if !files.isEmpty {
            var item = make(.file, title: files[0].lastPathComponent, signature: hash("file", Data(files.map(\.path).joined(separator: "\n").utf8)))
            item.files = files.map(\.path)
            return item
        }
        let first = entries[0]
        let string = text(of: first)
        let trimmed = string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if let imageType = imageTypes.first(where: { first[$0] != nil }), let data = first[imageType],
           trimmed.isEmpty || link(trimmed) != nil {
            var item = make(.image, title: String(localized: "Immagine"), signature: hash("image", data))
            if let source = CGImageSourceCreateWithData(data as CFData, nil),
               let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] {
                item.width = props[kCGImagePropertyPixelWidth] as? Int
                item.height = props[kCGImagePropertyPixelHeight] as? Int
            }
            return item
        }
        guard !trimmed.isEmpty, let string else { return nil }
        let kind: ClipItem.Kind = color(trimmed) != nil ? .color : link(trimmed) != nil ? .link : .text
        var item = make(kind, title: oneLine(trimmed), signature: hash("text", Data(string.utf8)))
        item.text = String(string.prefix(textLimit))
        return item
    }

    private static func text(of entry: [String: Data]) -> String? {
        if let data = entry["public.utf8-plain-text"], let s = String(data: data, encoding: .utf8) { return s }
        if let data = entry["public.rtf"], let a = NSAttributedString(rtf: data, documentAttributes: nil) { return a.string }
        if let data = entry["public.url"], let s = String(data: data, encoding: .utf8) { return s }
        return nil
    }

    /// Una riga: spazi e a capo diventano uno spazio solo, al massimo 300 caratteri.
    static func oneLine(_ s: String) -> String {
        let collapsed = s.prefix(1200).split(whereSeparator: { $0.isWhitespace || $0.isNewline }).joined(separator: " ")
        return String(collapsed.prefix(300))
    }

    /// Un indirizzo web da solo (niente spazi).
    static func link(_ s: String) -> URL? {
        guard s.count < 2048, !s.contains(where: { $0.isWhitespace }),
              let url = URL(string: s), let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme), url.host != nil
        else { return nil }
        return url
    }

    /// Un colore scritto come #RGB, #RRGGBB o #RRGGBBAA.
    static func color(_ s: String) -> NSColor? {
        guard s.hasPrefix("#"), [4, 7, 9].contains(s.count) else { return nil }
        var hex = String(s.dropFirst())
        guard hex.allSatisfy(\.isHexDigit) else { return nil }
        if hex.count == 3 { hex = hex.map { "\($0)\($0)" }.joined() }
        guard let value = UInt64(hex, radix: 16) else { return nil }
        let rgba = hex.count == 8 ? value : (value << 8) | 0xFF
        return NSColor(srgbRed: CGFloat((rgba >> 24) & 0xFF) / 255, green: CGFloat((rgba >> 16) & 0xFF) / 255,
                       blue: CGFloat((rgba >> 8) & 0xFF) / 255, alpha: CGFloat(rgba & 0xFF) / 255)
    }

    private static func hash(_ kind: String, _ data: Data) -> String {
        var hasher = SHA256()
        hasher.update(data: Data(kind.utf8))
        hasher.update(data: data)
        return hasher.finalize().prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    private func remember(_ new: ClipItem, entries: [[String: Data]]) {
        if let index = items.firstIndex(where: { $0.signature == new.signature }) {
            // Già la più recente: niente da fare (succede quando un'app rimette negli appunti quello che c'era).
            if index == 0 { return }
            var item = items.remove(at: index)
            item.last = new.last
            item.count += 1
            item.app = new.app
            item.appName = new.appName
            items.insert(item, at: 0)
            // La formattazione può essere diversa: si tiene quella più fresca.
            Self.writeData(entries, id: item.id)
        } else {
            items.insert(new, at: 0)
            Self.writeData(entries, id: new.id)
            ClipThumbnails.shared.warm([new])
        }
        trim()
        saveSoon()
    }

    // MARK: Azioni

    /// Rimette la voce negli appunti (con tutti i suoi formati, o solo il testo) e la porta in cima.
    @discardableResult
    func restore(_ id: UUID, plain: Bool) -> Bool {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return false }
        let item = items[index]
        let board = NSPasteboard.general
        if plain, let text = item.text ?? item.files?.joined(separator: "\n") {
            board.clearContents()
            let entry = NSPasteboardItem()
            entry.setString(text, forType: .string)
            entry.setData(Data(), forType: Self.marker)
            board.writeObjects([entry])
        } else {
            guard let entries = Self.readData(id: id) else { return false }
            board.clearContents()
            let objects = entries.map { entry -> NSPasteboardItem in
                let object = NSPasteboardItem()
                for (type, data) in entry { object.setData(data, forType: NSPasteboard.PasteboardType(type)) }
                object.setData(Data(), forType: Self.marker)
                return object
            }
            board.writeObjects(objects)
        }
        lastChange = board.changeCount
        var moved = items.remove(at: index)
        moved.last = Date()
        moved.count += 1
        items.insert(moved, at: 0)
        saveSoon()
        return true
    }

    func togglePin(_ id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].pinned.toggle()
        trim()
        saveSoon()
    }

    func delete(_ id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items.remove(at: index)
        Self.removeData(id: id)
        ClipThumbnails.shared.forget(id)
        saveSoon()
    }

    /// Cancella lo storico; i fissati restano, a meno di `includingPinned`.
    func clear(includingPinned: Bool) {
        // Anche a storico spento: quello salvato si carica adesso. Prima, spento all'avvio, qui non c'era niente da
        // cancellare e i file restavano sul disco senza un modo per toglierli (chi lo spegne perché ha copiato
        // qualcosa di riservato è proprio chi vuole cancellarlo).
        load()
        let gone = items.filter { includingPinned || !$0.pinned }
        items.removeAll { includingPinned || !$0.pinned }
        for item in gone {
            Self.removeData(id: item.id)
            ClipThumbnails.shared.forget(item.id)
        }
        // Via anche i file rimasti senza voce nell'indice (un'uscita a metà di una scrittura), e l'indice subito.
        let kept = Set(items.map(\.id))
        Self.disk.async { Self.removeOrphans(keeping: kept) }
        saveNow()
    }

    /// Oltre il limite se ne vanno le più vecchie non fissate.
    func trim() {
        let limit = ClipboardSettings.shared.limit
        var kept = 0
        var gone: [UUID] = []
        items.removeAll { item in
            if item.pinned { return false }
            kept += 1
            if kept > limit { gone.append(item.id); return true }
            return false
        }
        guard !gone.isEmpty else { return }
        for id in gone {
            Self.removeData(id: id)
            ClipThumbnails.shared.forget(id)
        }
        saveSoon()
    }

    // MARK: Disco

    nonisolated static var folder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("\(Identity.supportFolder)/Appunti", isDirectory: true)
    }
    private nonisolated static var indexURL: URL { folder.appendingPathComponent("storico.json") }
    nonisolated static func dataURL(_ id: UUID) -> URL { folder.appendingPathComponent(id.uuidString + ".plist") }

    private func load() {
        guard !loaded else { return }
        loaded = true
        guard let data = try? Data(contentsOf: Self.indexURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        items = ((try? decoder.decode([ClipItem].self, from: data)) ?? []).sorted { $0.last > $1.last }
        ClipThumbnails.shared.warm(items)
    }

    /// Tutto quello che tocca il disco passa da questa coda, in ordine: prima erano lavori staccati uno dall'altro, e
    /// una cancellazione poteva arrivare prima della scrittura dello stesso file (che restava lì per sempre) o un
    /// indice vecchio finire sopra uno nuovo.
    private nonisolated static let disk = DispatchQueue(label: "charland.appunti.disco", qos: .utility)
    @ObservationIgnored private var saveSequence = 0
    /// L'ultimo indice scritto. Solo sulla coda `disk`.
    private nonisolated(unsafe) static var writtenSequence = 0

    /// Salva l'indice poco dopo l'ultimo cambio, in sottofondo.
    private func saveSoon() {
        saveTask?.cancel()
        saveSequence += 1
        let snapshot = items, sequence = saveSequence
        saveTask = Task.detached(priority: .utility) {
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            ClipboardHistory.disk.async { ClipboardHistory.writeIndex(snapshot, sequence: sequence) }
        }
    }

    /// Salva l'indice adesso e aspetta che sia scritto: dopo una cancellazione e prima di chiudere.
    private func saveNow() {
        saveTask?.cancel()
        saveTask = nil
        saveSequence += 1
        let snapshot = items, sequence = saveSequence
        Self.disk.sync { Self.writeIndex(snapshot, sequence: sequence) }
    }

    private nonisolated static func writeIndex(_ snapshot: [ClipItem], sequence: Int) {
        // Un indice più vecchio di quello già scritto non lo copre.
        guard sequence > writtenSequence else { return }
        writtenSequence = sequence
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        guard let data = try? encoder.encode(snapshot) else { return }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? data.write(to: indexURL, options: .atomic)
    }

    /// I file dei contenuti che nessuna voce usa più.
    private nonisolated static func removeOrphans(keeping kept: Set<UUID>) {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        for file in files where file.pathExtension == "plist" {
            guard let id = UUID(uuidString: file.deletingPathExtension().lastPathComponent), !kept.contains(id) else { continue }
            try? FileManager.default.removeItem(at: file)
        }
    }

    private static func writeData(_ entries: [[String: Data]], id: UUID) {
        disk.async {
            guard let data = try? PropertyListSerialization.data(fromPropertyList: entries, format: .binary, options: 0) else { return }
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try? data.write(to: dataURL(id), options: .atomic)
        }
    }

    nonisolated static func readData(id: UUID) -> [[String: Data]]? {
        guard let data = try? Data(contentsOf: dataURL(id)) else { return nil }
        return (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [[String: Data]]
    }

    private static func removeData(id: UUID) {
        disk.async { try? FileManager.default.removeItem(at: dataURL(id)) }
    }
}

/// Le miniature delle immagini copiate e le icone di app e file, fatte in sottofondo e tenute in memoria.
@MainActor @Observable
final class ClipThumbnails {
    static let shared = ClipThumbnails()

    private(set) var images: [String: NSImage] = [:]
    @ObservationIgnored private var pending: Set<String> = []
    private(set) var icons: [String: NSImage] = [:]

    /// La miniatura di un'immagine copiata, larga al massimo `pixels`. `nil` finché non è pronta.
    func image(_ id: UUID, pixels: Int) -> NSImage? {
        let key = "\(id.uuidString)-\(pixels)"
        if let image = images[key] { return image }
        guard !pending.contains(key) else { return nil }
        pending.insert(key)
        Task.detached(priority: .userInitiated) {
            let cg = ClipThumbnails.render(id: id, pixels: pixels)
            await MainActor.run {
                let thumbs = ClipThumbnails.shared
                thumbs.pending.remove(key)
                if let cg { thumbs.images[key] = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height)) }
            }
        }
        return nil
    }

    private nonisolated static func render(id: UUID, pixels: Int) -> CGImage? {
        guard let entries = ClipboardHistory.readData(id: id), let entry = entries.first,
              let data = ["public.png", "public.tiff", "public.jpeg", "public.heic"].lazy.compactMap({ entry[$0] }).first,
              let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: pixels,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    func forget(_ id: UUID) {
        images = images.filter { !$0.key.hasPrefix(id.uuidString) }
    }

    /// L'icona dell'app da cui viene una voce, se è già pronta. Mai letta mentre si disegna: la prima lettura di
    /// un'icona dal disco costa decine di millisecondi, e otto app diverse facevano un fotogramma da 112 ms proprio
    /// quando comparivano le righe. Mancante, si prepara in sottofondo e la riga si aggiorna da sola.
    func appIcon(_ bundle: String?) -> NSImage? {
        guard let bundle else { return nil }
        if let icon = icons["app:" + bundle] { return icon }
        warm(apps: [bundle], files: [])
        return nil
    }

    func fileIcon(_ path: String) -> NSImage? {
        if let icon = icons["file:" + path] { return icon }
        warm(apps: [], files: [path])
        return nil
    }

    /// Prepara in sottofondo le icone di queste voci (all'avvio, a ogni copia, all'apertura del menu): già disegnate
    /// alla misura giusta, così il primo fotogramma del menu non decodifica niente.
    func warm(_ items: [ClipItem]) {
        warm(apps: items.compactMap(\.app), files: items.compactMap { $0.files?.first })
    }

    private func warm(apps: [String], files: [String]) {
        let keys = Array(Set(apps.map { "app:" + $0 } + files.map { "file:" + $0 })).filter { icons[$0] == nil && !pending.contains($0) }
        guard !keys.isEmpty else { return }
        pending.formUnion(keys)
        Task.detached(priority: .utility) {
            var made: [(String, CGImage)] = []
            for key in keys {
                if let cg = ClipThumbnails.renderIcon(key) { made.append((key, cg)) }
            }
            let ready = made
            await MainActor.run {
                let thumbs = ClipThumbnails.shared
                for key in keys { thumbs.pending.remove(key) }
                for (key, cg) in ready { thumbs.icons[key] = NSImage(cgImage: cg, size: NSSize(width: 22, height: 22)) }
            }
        }
    }

    /// L'icona disegnata a 44 × 44 pixel (22 punti su Retina), già decodificata.
    private nonisolated static func renderIcon(_ key: String) -> CGImage? {
        let workspace = NSWorkspace.shared
        let path: String
        if key.hasPrefix("app:") {
            guard let url = workspace.urlForApplication(withBundleIdentifier: String(key.dropFirst(4))) else { return nil }
            path = url.path
        } else {
            path = String(key.dropFirst(5))
        }
        let icon = workspace.icon(forFile: path)
        var rect = CGRect(x: 0, y: 0, width: 44, height: 44)
        guard let source = icon.cgImage(forProposedRect: &rect, context: nil, hints: nil),
              let ctx = CGContext(data: nil, width: 44, height: 44, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(source, in: CGRect(x: 0, y: 0, width: 44, height: 44))
        return ctx.makeImage()
    }
}
