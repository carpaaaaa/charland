import AppKit
import UniformTypeIdentifiers
import CharlandCore

/// Gli stili dello sfondo, tutti di vetro e dalla stessa immagine. Il Favo (1.1 e 1.2) è stato tolto il 20 novembre
/// 2026 (carpa: «toglierei honeycomb e metterei un altro effetto vetro per essere coerente»): chi lo aveva scelto
/// passa alla Nebbia.
enum WallpaperStyle: String, CaseIterable, Identifiable, Sendable {
    /// Nessun effetto: solo l'immagine, a tutto schermo (carpa: «l'opzione none, ovvero senza effetto di nulla»).
    case none
    case fluted, lenses, fog
    var id: String { rawValue }

    /// Dal valore salvato, anche quello del Favo che non c'è più.
    init?(saved: String) {
        if saved == "honeycomb" { self = .fog } else if let s = WallpaperStyle(rawValue: saved) { self = s } else { return nil }
    }
}

/// Tutto quello che cambia il disegno.
struct WallpaperDraw: Hashable, Sendable {
    var style: WallpaperStyle
    var fog: FogOptions
    var lens: LensOptions
    var fluted: FlutedOptions
    /// La zona senza effetto, uguale per tutti gli stili.
    var clear: ClearArea
    /// Il bagliore con «Nessuno».
    var plainGlow: Bool
    var image: Int

    /// Cambia tutto il disegno insieme (stile, tavolozza, griglia, colore, immagine): si passa con una dissolvenza.
    /// I cursori invece ridisegnano sul posto.
    func isWholeChange(from old: WallpaperDraw) -> Bool {
        style != old.style || image != old.image || plainGlow != old.plainGlow || clear.enabled != old.clear.enabled
            || fog.tint != old.fog.tint || fog.glow != old.fog.glow
            || lens.grid != old.lens.grid || lens.tint != old.lens.tint || lens.glow != old.lens.glow || lens.shape != old.lens.shape
            || fluted.profile != old.fluted.profile || fluted.tint != old.fluted.tint || fluted.glow != old.fluted.glow
    }
}

/// Il disegno di uno stile. `scale` è la densità dello schermo (le misure sono in pixel Retina); `shrink` sotto 1
/// rimpicciolisce tutto in proporzione, per l'anteprima.
enum WallpaperRenderer {
    static func render(_ source: WallpaperSource, _ draw: WallpaperDraw, canvas: CGSize, region: CGRect? = nil,
                       scale: CGFloat, shrink: CGFloat = 1) -> CGImage? {
        let s = scale * shrink
        let image: CGImage?
        switch draw.style {
        case .none:
            return PlainRenderer.render(source.image, canvas: canvas, region: region, glow: draw.plainGlow, spread: shrink)
        case .fog:
            image = GlassRenderer.fog(source, options: draw.fog, canvas: canvas, region: region, scale: s, glowSpread: shrink)
        case .lenses:
            image = GlassRenderer.lenses(source, options: draw.lens, canvas: canvas, region: region, scale: s, glowSpread: shrink)
        case .fluted:
            image = GlassRenderer.fluted(source, options: draw.fluted, canvas: canvas, region: region, scale: s, glowSpread: shrink)
        }
        guard let image, draw.clear.enabled else { return image }
        let glow = draw.style == .fog ? draw.fog.glow : draw.style == .lenses ? draw.lens.glow : draw.fluted.glow
        return WallpaperPixels.applyClear(draw.clear, effect: image, source: source.image, canvas: canvas, region: region,
                                          glow: glow, spread: shrink)
    }
}

/// Impostazioni › Sfondo: lo sfondo di Charland sulla scrivania. Si disegna alla misura di ogni schermo e si dà a
/// macOS: poi resta fermo e non costa niente.
///
/// Fluidità (carpa, 20 novembre 2026: «rendi lo switch e la modifica degli esagoni il più smooth possibile»; poi
/// rivisto con un agente Sonnet):
/// - mentre muovi un cursore lo spazio dove sei segue dal vivo: un disegno al massimo ogni 0,25 s, scritto in TIFF
///   (5 ms contro 150-400 del PNG) e passato con la dissolvenza di macOS;
/// - gli altri spazi solo a regolazione finita (1,5 s dopo l'ultimo ritocco), perché vuol dire far ripartire
///   WallpaperAgent, che lascia lo schermo grigio per circa 0,3 s: lo copre `WallpaperCurtain`. Quel passaggio non si
///   interrompe (gira in `transition`): un ritocco che arriva intanto aspetta che la tenda sia sparita;
/// - accendere passa con la dissolvenza di macOS, spegnere con la tenda che sfuma sullo sfondo di prima.
@MainActor @Observable
final class WallpaperSettings {
    static let shared = WallpaperSettings()

    private enum Keys {
        static let enabled = "wallpaperEnabled", imageName = "wallpaperImageName", fog = "wallpaperFog", clear = "wallpaperClear"
        static let previous = "wallpaperPrevious", allDesktops = "wallpaperAllDesktops", settled = "wallpaperSettled"
        static let style = "wallpaperStyle", lens = "wallpaperLens", fluted = "wallpaperFluted", plainGlow = "wallpaperPlainGlow"
        static let applied = "wallpaperApplied"
        static let savedFog = "wallpaperSavedFog", savedLens = "wallpaperSavedLens", savedFluted = "wallpaperSavedFluted"
    }

    /// Lo sfondo di Charland sulla scrivania. Spento di serie: lo sfondo è di chi usa il Mac.
    var enabled: Bool {
        didSet {
            guard enabled != oldValue else { return }
            UserDefaults.standard.set(enabled, forKey: Keys.enabled)
            // Accendere o spegnere è un tentativo nuovo anche per gli altri spazi (revisione Sonnet).
            allDesktopsProblem = nil
            lastSettleFailure = .distantPast
            if enabled { changed() } else { stopApplying(); runTransition { await $0.restore() } }
        }
    }
    /// Su tutte le scrivanie (gli spazi di Mission Control), non solo su quella dove sei (`AllSpaces`).
    var allDesktops: Bool {
        didSet {
            guard allDesktops != oldValue else { return }
            UserDefaults.standard.set(allDesktops, forKey: Keys.allDesktops)
            // Accendere o spegnere è un tentativo nuovo: il vecchio fallimento non conta più.
            allDesktopsProblem = nil
            lastSettleFailure = .distantPast
            guard enabled else { return }
            if allDesktops {
                // Il disegno dello spazio dove sei è già quello giusto: basta portarlo negli altri.
                if !current.isEmpty, !isEditing, current.values.allSatisfy({ FileManager.default.fileExists(atPath: $0.path) }) {
                    scheduleSettle(after: 0.2)
                } else {
                    requestApply()
                }
            } else {
                // Un ritocco in corso continua: il suo file vero aspetta che gli altri spazi siano tornati com'erano.
                settleTask?.cancel()
                settleTask = nil
                runTransition { me in
                    await me.leaveOtherSpaces()
                    me.hideLiveIfIdle()
                }
            }
        }
    }
    // Ogni regolazione ridisegna solo se cambia davvero (un campo numerico o una calamita riassegnano lo stesso valore).
    var style: WallpaperStyle { didSet { guard style != oldValue else { return }; UserDefaults.standard.set(style.rawValue, forKey: Keys.style); changed() } }

    /// Il bagliore con «Nessuno».
    var plainGlow: Bool { didSet { guard plainGlow != oldValue else { return }; UserDefaults.standard.set(plainGlow, forKey: Keys.plainGlow); changed() } }

    // Vetri
    var lens: LensOptions { didSet { guard lens != oldValue else { return }; Self.save(lens, Keys.lens); changed() } }
    var fluted: FlutedOptions { didSet { guard fluted != oldValue else { return }; Self.save(fluted, Keys.fluted); changed() } }
    var fog: FogOptions { didSet { guard fog != oldValue else { return }; Self.save(fog, Keys.fog); changed() } }
    /// La zona senza effetto (per tutti gli stili tranne Nessuno).
    var clear: ClearArea { didSet { guard clear != oldValue else { return }; Self.save(clear, Keys.clear); changed() } }

    /// Il nome del file scelto da chi usa il Mac; nil: l'immagine predefinita.
    private(set) var imageName: String?
    /// Sale a ogni immagine nuova: l'anteprima e la cache lo usano per sapere che è cambiata.
    private(set) var imageVersion = 0

    var draw: WallpaperDraw {
        WallpaperDraw(style: style, fog: fog, lens: lens, fluted: fluted, clear: clear, plainGlow: plainGlow, image: imageVersion)
    }

    private var cached: (version: Int, source: WallpaperSource)?
    /// Il pannello delle impostazioni si vede: l'immagine di partenza resta pronta per i ritocchi.
    var paneVisible = false {
        didSet { if !paneVisible { releaseIfIdle() } }
    }
    private var imageRequest: UUID?
    private var screensObserver: NSObjectProtocol?
    private var spaceObserver: NSObjectProtocol?
    private var lastRepair = Date.distantPast
    private var screenSignature = ""
    /// Perché lo sfondo non è arrivato negli altri spazi (nil: tutto bene). Lo mostra `WallpaperPane`.
    private(set) var allDesktopsProblem: AllSpaces.Problem?
    /// L'ultimo passo negli altri spazi fallito: per qualche minuto non si riprova da soli (ogni tentativo fa ripartire
    /// WallpaperAgent, e su un Mac dove non tiene il disegno sarebbe un lampo continuo).
    private var lastSettleFailure = Date.distantPast
    /// Un passo che scrive gli altri spazi è in coda o in corso (fra `scheduleSettle` e la fine della sua tenda).
    private var settlingCount = 0
    private var settling: Bool { settlingCount > 0 }

    /// L'attesa prima del passo a regolazione finita (si annulla a ogni ritocco; il passo vero no).
    private var settleTask: Task<Void, Never>?
    /// Spegnere, lasciare gli altri spazi, scriverli: un passaggio alla volta, mai interrotto, e il giro aspetta.
    private var transition: Task<Void, Never>?
    /// Lo sfondo dal vivo (`WallpaperLiveLayer`): il giro che ridisegna mentre regoli, e il file vero a fine regolazione.
    private var liveLoop: Task<Void, Never>?
    private var liveDirty = false
    private var finalTask: Task<Void, Never>?
    private var lastLive: WallpaperDraw?
    private var isEditing: Bool { liveLoop != nil || liveDirty || finalTask != nil }
    /// I disegni dati a macOS per lo spazio dove sei, per schermo.
    private var current: [String: URL] = [:]
    /// I disegni scritti negli altri spazi (salvati: dopo un riavvio dell'app non vanno buttati).
    private var settled: [String: URL] = [:]

    private init() {
        let d = UserDefaults.standard
        enabled = d.bool(forKey: Keys.enabled)
        allDesktops = d.bool(forKey: Keys.allDesktops)
        style = d.string(forKey: Keys.style).flatMap(WallpaperStyle.init(saved:)) ?? .fluted
        fog = (Self.load(Keys.fog) as FogOptions?).flatMap { $0.isFinite ? $0 : nil } ?? FogOptions()
        clear = (Self.load(Keys.clear) as ClearArea?).flatMap { $0.isFinite ? $0.clamped : nil } ?? ClearArea()
        plainGlow = d.bool(forKey: Keys.plainGlow)
        lens = (Self.load(Keys.lens) as LensOptions?).flatMap { $0.isFinite ? $0 : nil } ?? LensOptions()
        fluted = (Self.load(Keys.fluted) as FlutedOptions?).flatMap { $0.isFinite ? $0 : nil } ?? FlutedOptions()
        savedFog = (Self.load(Keys.savedFog) as FogOptions?).flatMap { $0.isFinite ? $0 : nil }
        savedLens = (Self.load(Keys.savedLens) as LensOptions?).flatMap { $0.isFinite ? $0 : nil }
        savedFluted = (Self.load(Keys.savedFluted) as FlutedOptions?).flatMap { $0.isFinite ? $0 : nil }
        imageName = FileManager.default.fileExists(atPath: WallpaperFiles.customImage?.path ?? "") ? d.string(forKey: Keys.imageName) : nil
    }

    private static func save<T: Encodable>(_ value: T, _ key: String) {
        if let data = try? JSONEncoder().encode(value) { UserDefaults.standard.set(data, forKey: key) }
    }
    private static func load<T: Decodable>(_ key: String) -> T? {
        UserDefaults.standard.data(forKey: key).flatMap { try? JSONDecoder().decode(T.self, from: $0) }
    }

    /// All'avvio dell'app: ridisegna quando cambiano gli schermi (un monitor collegato riceve il suo disegno) e
    /// rimette lo sfondo se nel frattempo uno schermo ha perso il nostro file.
    func start() {
        guard screensObserver == nil else { return }
        screenSignature = Self.screenSignature()
        screensObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                                                 object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { WallpaperSettings.shared.screensChanged() }
        }
        spaceObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification,
                                                                          object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { WallpaperSettings.shared.spaceChanged() }
        }
        guard enabled else { return }
        current = WallpaperFiles.latestDrawings()
        let saved = UserDefaults.standard.dictionary(forKey: Keys.settled) as? [String: String] ?? [:]
        settled = saved.compactMapValues { path in FileManager.default.fileExists(atPath: path) ? URL(fileURLWithPath: path) : nil }
        // Disegno da rifare: manca un file, o le impostazioni sono cambiate dopo l'ultimo file dato a macOS (l'app è
        // uscita a metà di un ritocco).
        if !allScreensHaveOurs() || UserDefaults.standard.string(forKey: Keys.applied) != appliedKey {
            changed()
        } else if allDesktops, current != settled || AllSpaces.needsRepair(files: current) {
            // Anche se i disegni sono gli stessi: WallpaperAgent può aver rimesso lo sfondo di serie negli altri spazi.
            scheduleSettle(after: 2, force: true)
        }
    }

    /// Cambiando scrivania: se uno spazio non ha il disegno (WallpaperAgent a volte rimette lo sfondo di serie, in voci
    /// «linked»), si riscrivono tutti, al massimo una volta al minuto (carpa, 20 novembre 2026: «se attivo li rimette
    /// per tutti in automatico se era spuntato il toggle»).
    private func spaceChanged() {
        guard enabled, allDesktops, !isEditing, settleTask == nil, !settling, !current.isEmpty,
              Date().timeIntervalSince(lastSettleFailure) > 300, Date().timeIntervalSince(lastRepair) > 60,
              AllSpaces.needsRepair(files: current) else { return }
        lastRepair = Date()
        scheduleSettle(after: 0.5, force: true)
    }

    /// Schermi collegati o cambiati (anche la risoluzione): si ridisegna alla misura nuova. Solo se cambiano davvero:
    /// macOS manda lo stesso avviso quando il Dock compare o si nasconde, e Charland cambia il nascondi-Dock da sé
    /// tenendo su il Dock sopra un widget. Ogni volta lo sfondo si ridisegnava (mezza risoluzione, poi piena) e
    /// WallpaperAgent ripartiva: «quando vado sul dock in hover su un widget e poi esco si muove, flickera» (carpa, 20
    /// novembre 2026; riprodotto cambiando il nascondi-Dock: disegno nuovo dopo 4 s, WallpaperAgent ripartito dopo 7).
    private func screensChanged() {
        let now = Self.screenSignature()
        guard now != screenSignature else { return }
        screenSignature = now
        guard enabled else { return }
        changed()
    }

    /// Quali schermi e a che misura in pixel: quello che decide il disegno. Il riquadro libero dal Dock non conta.
    private static func screenSignature() -> String {
        NSScreen.screens.map { screen in
            "\(WallpaperFiles.displayID(screen)) \(Int(screen.frame.width))x\(Int(screen.frame.height))@\(screen.backingScaleFactor)"
        }.joined(separator: "|")
    }

    /// Le impostazioni del disegno, stabili fra un avvio e l'altro (il numero dell'immagine no, il suo nome sì).
    private var appliedKey: String {
        var d = draw
        d.image = 0
        // L'immagine predefinita ha un nome suo: cambiandola (il viola fino alla 1.2, la figura sul rosso dalla 1.3) chi
        // la usa riceve il disegno nuovo al primo avvio.
        return String(describing: d) + "|" + (imageName ?? "predefinita:bagliore-1.6")
    }

    /// Un ritocco: si vede subito nello sfondo dal vivo; il file vero arriva quando ti fermi.
    private func changed() {
        guard enabled else { return }
        liveDirty = true
        settleTask?.cancel()
        finalTask?.cancel()
        finalTask = nil
        guard liveLoop == nil else { return }
        liveLoop = Task { [weak self] in
            // Non aspetta la tenda degli altri spazi: lo sfondo dal vivo è solo una finestra sopra. Il file vero sì.
            while let self, self.liveDirty, self.enabled, !Task.isCancelled {
                self.liveDirty = false
                await self.drawLive()
            }
            guard let self, !Task.isCancelled else { return }
            self.liveLoop = nil
            self.scheduleFinal()
        }
    }

    /// Un fotogramma dello sfondo dal vivo, a mezza risoluzione: segue il cursore (pochi centesimi di secondo).
    private func drawLive() async {
        guard let source = await source() else { return }
        let draw = draw
        let screens = NSScreen.screens.map { screen in
            (id: WallpaperFiles.displayID(screen), scale: screen.backingScaleFactor,
             size: CGSize(width: (screen.frame.width * screen.backingScaleFactor / 2).rounded(),
                          height: (screen.frame.height * screen.backingScaleFactor / 2).rounded()))
        }
        let images = await Task.detached(priority: .userInitiated) { () -> [String: LiveImage] in
            var out: [String: LiveImage] = [:]
            for screen in screens {
                if let image = WallpaperRenderer.render(source, draw, canvas: screen.size, scale: screen.scale, shrink: 0.5) {
                    out[screen.id] = LiveImage(image: image)
                }
            }
            return out
        }.value
        guard enabled, !Task.isCancelled, !images.isEmpty else { return }
        let whole = lastLive.map { draw.isWholeChange(from: $0) } ?? true
        lastLive = draw
        WallpaperLiveLayer.shared.show(images.mapValues(\.image), fade: whole ? 0.35 : 0)
    }

    private struct LiveImage: @unchecked Sendable { let image: CGImage }

    /// Fermo da un attimo: il disegno a piena risoluzione va nello sfondo dal vivo, il file vero a macOS sotto, e lo
    /// sfondo dal vivo sparisce quando sotto c'è la stessa immagine (dopo la dissolvenza di macOS, che resta coperta).
    private func scheduleFinal() {
        finalTask?.cancel()
        finalTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard let self, !Task.isCancelled, self.enabled, self.liveLoop == nil, !self.liveDirty else { return }
            await self.transition?.value
            // Immagine illeggibile (file sparito): niente sfondo dal vivo lasciato sopra.
            guard let source = await self.source() else { self.finalTask = nil; WallpaperLiveLayer.shared.hide(); return }
            let draw = self.draw
            let screens = NSScreen.screens.map { screen in
                (id: WallpaperFiles.displayID(screen), scale: screen.backingScaleFactor,
                 size: CGSize(width: screen.frame.width * screen.backingScaleFactor, height: screen.frame.height * screen.backingScaleFactor))
            }
            let stamp = Int(Date().timeIntervalSince1970 * 1000)
            let made = await Task.detached(priority: .userInitiated) { () -> [String: (url: URL, image: LiveImage)] in
                var out: [String: (url: URL, image: LiveImage)] = [:]
                for screen in screens {
                    guard let image = WallpaperRenderer.render(source, draw, canvas: screen.size, scale: screen.scale),
                          let url = WallpaperFiles.write(image, name: "favo-\(screen.id.prefix(8))-\(stamp)") else { continue }
                    out[screen.id] = (url, LiveImage(image: image))
                }
                return out
            }.value
            guard !Task.isCancelled, self.enabled, self.liveLoop == nil, !self.liveDirty, !made.isEmpty else {
                WallpaperFiles.remove(made.values.map(\.url))
                // Disegno fallito senza ritocchi nuovi (disco pieno): niente sfondo dal vivo lasciato sopra.
                if !Task.isCancelled, self.liveLoop == nil, !self.liveDirty {
                    WallpaperLiveLayer.shared.hide()
                    self.finalTask = nil
                }
                return
            }
            if WallpaperLiveLayer.shared.isShown { WallpaperLiveLayer.shared.show(made.mapValues(\.image.image)) }
            let given = self.giveToMacOS(made.mapValues(\.url))
            UserDefaults.standard.set(self.appliedKey, forKey: Keys.applied)
            // La dissolvenza di macOS sotto lo sfondo dal vivo, poi via.
            try? await Task.sleep(for: .seconds(1.2))
            guard !Task.isCancelled, self.liveLoop == nil, !self.liveDirty else { return }
            guard given else {
                // macOS non l'ha preso (schermo bloccato, WallpaperAgent fermo): lo sfondo dal vivo resta e si riprova.
                self.finalTask = nil
                try? await Task.sleep(for: .seconds(3))
                if self.enabled, !self.isEditing { self.scheduleFinal() }
                return
            }
            self.finalTask = nil
            // Su tutte le scrivanie lo sfondo dal vivo (una finestra che sta su tutti gli spazi) resta finché anche gli
            // altri spazi hanno il disegno: prima spariva qui, e riaccendendo gli altri spazi mostravano lo sfondo di
            // prima per qualche secondo (carpa, 20 novembre 2026: «quando lo riattivi non si mette subito su all
            // desktop»). Lo toglie `scheduleSettle`.
            if self.allDesktops {
                self.scheduleSettle(after: 1.5)
            } else {
                WallpaperLiveLayer.shared.hide()
                self.scheduleSettle(after: 1.5)
                self.releaseIfIdle()
            }
        }
    }

    private func setSettled(_ files: [String: URL]) {
        settled = files
        UserDefaults.standard.set(files.mapValues(\.path), forKey: Keys.settled)
    }

    // MARK: - Immagine

    /// Usa un'immagine scelta: la legge e la copia nella cartella di Charland fuori dal thread principale.
    func useImage(at url: URL) {
        let request = UUID()
        imageRequest = request
        Task {
            let source = await Task.detached(priority: .userInitiated) { () -> WallpaperSource? in
                guard let source = WallpaperSource(url: url), (try? WallpaperFiles.storeCustomImage(from: url)) != nil else { return nil }
                return source
            }.value
            // Due immagini scelte di fila: vale l'ultima.
            guard imageRequest == request else { return }
            guard let source else { NSSound.beep(); return }
            imageName = url.lastPathComponent
            UserDefaults.standard.set(imageName, forKey: Keys.imageName)
            imageVersion += 1
            cached = (imageVersion, source)
            changed()
        }
    }

    // MARK: - La tua regolazione

    /// Una regolazione salvata per ogni vetro, sotto «Valori di serie» (carpa, 20 novembre 2026: «per ogni vetro tu possa
    /// salvare una configurazione: se non c'è una salvata il tasto Salva, poi sovrascriverla e salvarne un'altra al posto
    /// di quella»). Una sola per vetro; Nessuno non ne ha (ha solo il bagliore).
    private(set) var savedFog: FogOptions?
    private(set) var savedLens: LensOptions?
    private(set) var savedFluted: FlutedOptions?

    /// C'è una regolazione salvata per il vetro scelto.
    var hasSavedStyle: Bool {
        switch style {
        case .none: false
        case .fog: savedFog != nil
        case .lenses: savedLens != nil
        case .fluted: savedFluted != nil
        }
    }

    /// Le regolazioni di adesso sono già quelle salvate (Usa e Sovrascrivi non farebbero niente).
    var matchesSavedStyle: Bool {
        switch style {
        case .none: false
        case .fog: savedFog == fog
        case .lenses: savedLens == lens
        case .fluted: savedFluted == fluted
        }
    }

    /// Salva le regolazioni di adesso come la tua, al posto di quella che c'era.
    func saveStyle() {
        switch style {
        case .none: break
        case .fog: savedFog = fog; Self.save(fog, Keys.savedFog)
        case .lenses: savedLens = lens; Self.save(lens, Keys.savedLens)
        case .fluted: savedFluted = fluted; Self.save(fluted, Keys.savedFluted)
        }
    }

    /// Rimette la tua regolazione salvata (passa dalla stessa via dei ritocchi: lo sfondo cambia dal vivo).
    func useSavedStyle() {
        switch style {
        case .none: break
        case .fog: if let savedFog { fog = savedFog }
        case .lenses: if let savedLens { lens = savedLens }
        case .fluted: if let savedFluted { fluted = savedFluted }
        }
    }

    /// I valori di serie dello stile scelto.
    func resetStyle() {
        switch style {
        case .none: plainGlow = false
        case .fog: fog = FogOptions()
        case .lenses: lens = LensOptions()
        case .fluted: fluted = FlutedOptions()
        }
    }

    /// Torna all'immagine predefinita.
    func useDefaultImage() {
        WallpaperFiles.removeCustomImage()
        imageName = nil
        UserDefaults.standard.removeObject(forKey: Keys.imageName)
        imageVersion += 1
        changed()
    }

    /// L'immagine di partenza, letta una volta per versione (fuori dal thread principale).
    func source() async -> WallpaperSource? {
        let version = imageVersion
        if let cached, cached.version == version { return cached.source }
        let url = (imageName != nil ? WallpaperFiles.customImage : nil) ?? WallpaperFiles.defaultImage
        guard let url else { return nil }
        let source = await Task.detached(priority: .userInitiated) { WallpaperSource(url: url) }.value
        if let source, version == imageVersion { cached = (version, source) }
        return source
    }

    // MARK: - Scrivania

    /// Sfondo fermo e pannello chiuso: via l'immagine di partenza decodificata (fino a 43 MB) e quello che serviva ai
    /// ritocchi. Da lì lo sfondo è solo un file che macOS mostra: Charland non tiene niente in memoria per lui
    /// (carpa: «una volta che c'è il wallpaper non deve più pesare»).
    func releaseIfIdle() {
        guard !paneVisible, !isEditing, settleTask == nil else { return }
        cached = nil
        lastLive = nil
        // I buffer dei disegni sono già liberati, ma malloc li tiene da parte per riusarli («Malloc Large (empty)»:
        // 143 MB dopo un ridisegno, misurato il 20 novembre 2026): si restituiscono subito al sistema.
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1))
            guard !self.isEditing, !self.paneVisible else { return }
            malloc_zone_pressure_relief(nil, 0)
        }
    }

    /// Chiede un disegno nuovo: passa dalla stessa via dei ritocchi (una sola via, nessuna gara fra due giri).
    private func requestApply() { changed() }

    private func stopApplying() {
        settleTask?.cancel()
        settleTask = nil
        liveLoop?.cancel()
        liveLoop = nil
        liveDirty = false
        finalTask?.cancel()
        finalTask = nil
        lastLive = nil
        // Durante la scrittura degli altri spazi lo sfondo dal vivo fa da tenda (WallpaperAgent sta ripartendo): va via
        // a passo finito, prima che il ripristino cominci.
        if settling { runTransition { $0.hideLiveIfIdle() } } else { WallpaperLiveLayer.shared.hide() }
    }

    /// Via lo sfondo dal vivo rimasto sopra mentre gli altri spazi ricevevano il disegno, se un ritocco non lo sta usando.
    private func hideLiveIfIdle() {
        guard !isEditing else { return }
        WallpaperLiveLayer.shared.hide()
    }

    /// Un passaggio dopo quello prima, se ce n'era uno. Gira in un compito suo: non si interrompe a metà tenda.
    private func runTransition(_ body: @escaping @MainActor (WallpaperSettings) async -> Void) {
        let before = transition
        transition = Task { [weak self] in
            await before?.value
            guard let self else { return }
            await body(self)
        }
    }

    /// I disegni a macOS per lo spazio dove sei, dopo aver salvato (la prima volta) il registro com'era.
    @discardableResult
    private func giveToMacOS(_ files: [String: URL]) -> Bool {
        // Il registro degli sfondi com'era, prima di toccare qualunque spazio: spegnendo torna tutto com'era.
        AllSpaces.backupIfNeeded()
        var previous = UserDefaults.standard.dictionary(forKey: Keys.previous) as? [String: String] ?? [:]
        var allGiven = true
        for screen in NSScreen.screens {
            let id = WallpaperFiles.displayID(screen)
            guard let url = files[id] else { continue }
            // Riserva, se la copia del registro mancasse: lo sfondo di prima di ogni schermo.
            if previous[id] == nil, let old = NSWorkspace.shared.desktopImageURL(for: screen), !WallpaperFiles.isOurs(old) {
                previous[id] = old.absoluteString
            }
            if !Self.show(url, on: screen) { allGiven = false }
        }
        UserDefaults.standard.set(previous, forKey: Keys.previous)
        current = files
        // macOS tiene il file per l'indirizzo: ogni disegno ha un nome nuovo; si tengono quello dello spazio dove sei
        // e quello scritto negli altri spazi.
        WallpaperFiles.removeDrawings(except: Set(current.values).union(settled.values))
        return allGiven
    }

    /// A regolazione finita: il disegno anche negli altri spazi (se serve) e via i file vecchi.
    private func scheduleSettle(after seconds: Double, force: Bool = false) {
        settleTask?.cancel()
        guard enabled else { return }
        settleTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard let self, !Task.isCancelled, self.enabled, !self.isEditing else { return }
            let files = self.current
            // Senza la copia del registro non si può nemmeno cominciare: se manca perché il registro non c'è o non si
            // legge, lo si dice; se è solo che il disegno non è ancora stato dato a macOS, si aspetta.
            if self.allDesktops, !files.isEmpty, !AllSpaces.hasBackup {
                AllSpaces.backupIfNeeded()
                if !AllSpaces.hasBackup { self.allDesktopsProblem = AllSpaces.availabilityProblem() ?? .writeFailed }
            }
            guard self.allDesktops, AllSpaces.hasBackup, !files.isEmpty, force || files != self.settled,
                  Date().timeIntervalSince(self.lastSettleFailure) > (force ? 300 : 60),
                  let main = self.mainDrawing(files) else {
                // `settled` lo azzerano solo `leaveOtherSpaces` e `restore`, quando il registro è davvero rimesso.
                WallpaperFiles.removeDrawings(except: Set(self.current.values).union(self.settled.values))
                self.settleTask = nil
                self.hideLiveIfIdle()
                self.releaseIfIdle()
                return
            }
            // Segnati subito: un disegno che arrivasse intanto non deve buttarli.
            let old = self.settled
            self.setSettled(files)
            self.settlingCount += 1
            self.lastRepair = Date()
            self.runTransition { me in
                defer { me.settlingCount -= 1 }
                guard me.enabled, me.allDesktops else { me.setSettled(old); me.hideLiveIfIdle(); return }
                // Dopo almeno 1,5 s WallpaperAgent ha finito di scrivere il suo registro: la nostra scrittura non si
                // perde. Se lo riscrive lo stesso, un secondo tentativo.
                let ok = await Self.underCurtain(showing: files, during: { AllSpaces.apply(files: files, fallback: main) },
                                                 verify: { AllSpaces.points(to: files) })
                if ok {
                    me.allDesktopsProblem = nil
                } else {
                    me.setSettled(old)
                    // Fuori dal registro: il motivo che ha detto `apply`; scritto ma non tenuto da WallpaperAgent: l'altro.
                    me.allDesktopsProblem = AllSpaces.lastProblem ?? .agentIgnored
                    me.lastSettleFailure = Date()
                }
                WallpaperFiles.removeDrawings(except: Set(me.current.values).union(me.settled.values))
                // Sotto la tenda appena sparita c'era lo sfondo dal vivo con la stessa immagine: ora c'è dappertutto.
                me.hideLiveIfIdle()
                me.releaseIfIdle()
            }
            self.settleTask = nil
        }
    }

    /// Spegnendo: le voci del registro che hanno ancora un nostro disegno tornano com'erano nella copia, con la tenda
    /// che sfuma dal disegno allo sfondo di prima. Senza copia, lo sfondo salvato di ogni schermo (con la
    /// dissolvenza di macOS). Non si chiede a macOS che sfondo c'è adesso: su macOS 27 `desktopImageURL(for:)`
    /// risponde con quello generale dello schermo e non con quello dello spazio.
    private func restore() async {
        guard !enabled else { return }
        let showing = current.isEmpty ? WallpaperFiles.latestDrawings() : current
        var restored = false
        if AllSpaces.hasBackup {
            restored = await Self.underCurtain(showing: showing) { AllSpaces.restore(keepBackup: false) }
        }
        if !restored {
            let previous = UserDefaults.standard.dictionary(forKey: Keys.previous) as? [String: String] ?? [:]
            for screen in NSScreen.screens {
                guard let old = previous[WallpaperFiles.displayID(screen)].flatMap(URL.init(string:)) else { continue }
                try? NSWorkspace.shared.setDesktopImageURL(old, for: screen, options: [:])
            }
        }
        guard !enabled else { return }
        UserDefaults.standard.removeObject(forKey: Keys.previous)
        current = [:]
        // Se il registro non si è potuto rimettere, gli altri spazi puntano ancora ai nostri file: restano.
        if restored || settled.isEmpty {
            setSettled([:])
            WallpaperFiles.removeDrawings(except: [])
        } else {
            WallpaperFiles.removeDrawings(except: Set(settled.values))
        }
    }

    /// «Su tutte le scrivanie» spento: gli altri spazi tornano com'erano; lo spazio dove sei riprende il disegno sotto
    /// la tenda, così sfumando non si vede cambiare niente.
    private func leaveOtherSpaces() async {
        guard enabled, !allDesktops else { return }
        let old = settled
        setSettled([:])
        guard AllSpaces.hasBackup, !old.isEmpty else { return }
        let showing = current.isEmpty ? WallpaperFiles.latestDrawings() : current
        let ok = await Self.underCurtain(showing: showing, during: { AllSpaces.restore(keepBackup: true) }, after: {
            for screen in NSScreen.screens {
                if let url = showing[WallpaperFiles.displayID(screen)] { Self.show(url, on: screen) }
            }
        })
        if !ok { setSettled(old) }
        WallpaperFiles.removeDrawings(except: Set(current.values).union(settled.values))
    }

    // MARK: - Strumenti

    @discardableResult
    private static func show(_ url: URL, on screen: NSScreen) -> Bool {
        (try? NSWorkspace.shared.setDesktopImageURL(url, for: screen, options: [
            .imageScaling: NSImageScaling.scaleProportionallyUpOrDown.rawValue, .allowClipping: true,
        ])) != nil
    }

    /// La tenda sopra lo sfondo mentre WallpaperAgent riparte (`during`), poi `after` sotto la tenda, poi la tenda
    /// sfuma in 0,45 s. Misurato con `--prova-tenda`: grigio da 0,2 a 0,4 s dopo la ripartenza, sfondo di nuovo pieno a
    /// 0,5 s; si aspetta 1,1 s per stare larghi. Se `during` fallisce (niente da scrivere) la tenda va via subito. Se
    /// `verify` dice che WallpaperAgent ha riscritto il suo stato sopra il nostro, un secondo tentativo sotto la stessa
    /// tenda.
    static func underCurtain(showing files: [String: URL], during: @escaping @Sendable () -> Bool,
                             verify: (@Sendable () -> Bool)? = nil, after: (() -> Void)? = nil) async -> Bool {
        // Leggere e scrivere il registro (78 spazi) e far ripartire WallpaperAgent costa centinaia di millisecondi:
        // fuori dal thread principale, così un cursore preso in mano intanto non si pianta.
        let during = { await Task.detached(priority: .userInitiated) { during() }.value }
        let verify = verify.map { check in { await Task.detached(priority: .userInitiated) { check() }.value } }
        // Con lo sfondo dal vivo già sopra (lo stesso disegno, su tutti gli spazi) la tenda non serve: sarebbe una
        // finestra in più che nasce sopra l'immagine, a rischio di un fotogramma vuoto.
        let curtain = WallpaperLiveLayer.shared.isShown ? WallpaperCurtain() : await WallpaperCurtain.make(showing: files)
        curtain.show()
        // Un paio di fotogrammi perché la tenda sia davvero a schermo prima del grigio.
        try? await Task.sleep(for: .milliseconds(50))
        guard await during() else {
            await curtain.fadeOut(seconds: 0.2)
            return false
        }
        try? await Task.sleep(for: .seconds(1.1))
        if let verify, !(await verify()) {
            guard await during() else { await curtain.fadeOut(seconds: 0.45); return false }
            try? await Task.sleep(for: .seconds(1.1))
            guard await verify() else { await curtain.fadeOut(seconds: 0.45); return false }
        }
        if let after {
            after()
            // La dissolvenza di macOS sotto la tenda.
            try? await Task.sleep(for: .seconds(0.7))
        }
        await curtain.fadeOut(seconds: 0.45)
        return true
    }

    private func mainDrawing(_ files: [String: URL]) -> URL? {
        NSScreen.screens.first.flatMap { files[WallpaperFiles.displayID($0)] } ?? files.values.first
    }

    /// Ogni schermo ha già un nostro disegno (si guardano i file e non macOS, per lo stesso motivo di `restore`).
    private func allScreensHaveOurs() -> Bool {
        let drawings = WallpaperFiles.latestDrawings()
        return NSScreen.screens.allSatisfy { drawings[WallpaperFiles.displayID($0)] != nil }
    }
}

/// I file dello sfondo: ~/Library/Application Support/Charland/Sfondo. I disegni si chiamano `favo-…` per tutti gli
/// stili (il nome serve a riconoscerli, anche nel registro di WallpaperAgent).
enum WallpaperFiles {
    static var folder: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let url = base.appendingPathComponent(Identity.supportFolder, isDirectory: true).appendingPathComponent("Sfondo", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// L'immagine di chi accende lo sfondo senza sceglierne una: un bagliore rosso su nero, generato per Charland.
    static var defaultImage: URL? { Bundle.main.url(forResource: "sfondo-predefinito", withExtension: "jpg") }

    /// L'immagine scelta, se c'è.
    static var customImage: URL? {
        (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil))?
            .first { $0.lastPathComponent.hasPrefix("immagine.") }
    }

    static func storeCustomImage(from url: URL) throws {
        let ext = url.pathExtension.isEmpty ? "img" : url.pathExtension.lowercased()
        let dest = folder.appendingPathComponent("immagine.\(ext)")
        let temp = folder.appendingPathComponent("arrivo-\(UUID().uuidString).\(ext)")
        try FileManager.default.copyItem(at: url, to: temp)
        removeCustomImage()
        try FileManager.default.moveItem(at: temp, to: dest)
    }

    static func removeCustomImage() {
        if let url = customImage { try? FileManager.default.removeItem(at: url) }
    }

    static func isOurs(_ url: URL) -> Bool {
        url.isFileURL && url.standardizedFileURL.path.hasPrefix(folder.standardizedFileURL.path) && url.lastPathComponent.hasPrefix("favo-")
    }

    /// Scrive il disegno in HEIC (qualità 0,9): circa 50 ms e 5 MB a 3420 x 2214, contro i 22 MB del TIFF che serviva
    /// quando ogni passo del cursore scriveva un file. Ora dal vivo c'è `WallpaperLiveLayer` e il file si scrive solo a
    /// regolazione finita; i formati di macOS lo leggono come gli sfondi di Apple.
    static func write(_ image: CGImage, name: String) -> URL? {
        let url = folder.appendingPathComponent(name).appendingPathExtension("heic")
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.heic.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
        return CGImageDestinationFinalize(dest) ? url : nil
    }

    static func remove(_ urls: [URL]) {
        for url in urls { try? FileManager.default.removeItem(at: url) }
    }

    /// L'ultimo disegno di ogni schermo collegato, per UUID dello schermo (il nome del file ne tiene le prime 8 cifre).
    @MainActor
    static func latestDrawings() -> [String: URL] {
        let urls = ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.lastPathComponent.hasPrefix("favo-") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        var out: [String: URL] = [:]
        for screen in NSScreen.screens {
            let id = displayID(screen)
            if let url = urls.last(where: { $0.lastPathComponent.hasPrefix("favo-\(id.prefix(8))-") }) { out[id] = url }
        }
        return out
    }

    /// Butta i disegni vecchi, tranne `keep` e quelli che il registro di WallpaperAgent mostra ancora in qualche spazio
    /// (con «Su tutte le scrivanie» spento ogni spazio dove hai ritoccato tiene il suo).
    static func removeDrawings(except keep: Set<URL>) {
        let keepPaths = Set(keep.map(\.standardizedFileURL.path)).union(AllSpaces.referencedDrawings())
        for url in (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        where url.lastPathComponent.hasPrefix("favo-") && !keepPaths.contains(url.standardizedFileURL.path) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// Un nome stabile per lo schermo (l'UUID del display), per ricordare lo sfondo di prima di ognuno.
    @MainActor
    static func displayID(_ screen: NSScreen) -> String {
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
              let uuid = CGDisplayCreateUUIDFromDisplayID(number.uint32Value)?.takeRetainedValue(),
              let text = CFUUIDCreateString(nil, uuid) as String? else { return "schermo" }
        return text
    }
}

/// `Charland --render-sfondo <file.png>`: lo sfondo in un PNG, senza toccare la scrivania. Opzioni:
/// `--stile cannettato|lenti|nebbia|nessuno`, `--mie` (le regolazioni salvate), `--immagine <file>` (di serie il viola),
/// `--misura 2880x1864`, `--pezzo x,y,l,a` (solo un pezzo della tela, a grandezza vera), `--zona x,y,l,a` (zona senza
/// effetto, in frazioni), `--togli a,b` (vetro tolto a sinistra e a destra), `--bagliore`, `--grana`, `--rifrazione`,
/// `--smerigliato`, `--luce`, `--dispersione`. Lenti: `--celle`, `--esagoni`, `--piramidi`, `--rilievo`, `--miniature`.
/// Cannettato: `--canne`, `--angolo`, `--colore`, `--curva`, `--onde`, `--strascico`, `--specchio`, `--ripetizione`,
/// `--irregolarita`. Lenti: `--bordi`. Nebbia: `--celle` (misura dei rilievi), `--velo`.
enum WallpaperChecks {
    /// `Charland --prova-tenda`: riscrive l'ultimo disegno in tutti gli spazi e fa ripartire WallpaperAgent sotto la
    /// tenda, come a regolazione finita. Stampa i tempi: il grigio della ripartenza deve cadere dentro la tenda.
    @MainActor
    static func curtainTest() async {
        let files = WallpaperFiles.latestDrawings()
        guard let main = files.values.first else { print("Nessun disegno da rimettere"); return }
        let start = Date()
        print("tenda su")
        let ok = await WallpaperSettings.underCurtain(showing: files) {
            print(String(format: "WallpaperAgent riparte a %.2f s", Date().timeIntervalSince(start)))
            return AllSpaces.apply(files: files, fallback: main)
        }
        print(String(format: "tenda sparita a %.2f s, scrittura %@, registro col disegno %@", Date().timeIntervalSince(start),
                     ok ? "riuscita" : "fallita", AllSpaces.points(to: files) ? "sì" : "no"))
    }

    static func render(to path: String) -> Bool {
        let args = CommandLine.arguments
        func value(_ name: String) -> String? { args.firstIndex(of: name).flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil } }
        var draw = WallpaperDraw(style: .fluted, fog: FogOptions(), lens: LensOptions(), fluted: FlutedOptions(), clear: ClearArea(),
                                 plainGlow: false, image: 0)
        // `--mie`: le regolazioni salvate da chi usa il Mac (Lenti e Cannettato come nelle Impostazioni).
        if args.contains("--mie") {
            let d = UserDefaults.standard
            if let data = d.data(forKey: "wallpaperLens"), let v = try? JSONDecoder().decode(LensOptions.self, from: data) { draw.lens = v }
            if let data = d.data(forKey: "wallpaperFluted"), let v = try? JSONDecoder().decode(FlutedOptions.self, from: data) { draw.fluted = v }
            if let data = d.data(forKey: "wallpaperFog"), let v = try? JSONDecoder().decode(FogOptions.self, from: data) { draw.fog = v }
        }
        switch value("--stile") {
        case "lenti": draw.style = .lenses
        case "cannettato": draw.style = .fluted
        case "nessuno": draw.style = .none
        case "nebbia", "favo": draw.style = .fog
        default: break
        }
        if let c = value("--celle").flatMap(Double.init) { draw.lens.cell = c; draw.fog.size = c }
        if args.contains("--bagliore") { draw.plainGlow = true; draw.lens.glow = true; draw.fluted.glow = true; draw.fog.glow = true }
        if let v = value("--velo").flatMap(Double.init) { draw.fog.veil = v }
        // `--zona x,y,l,a`: la zona senza effetto, in frazioni dello schermo.
        if let r = value("--zona")?.split(separator: ",").compactMap({ Double($0) }), r.count == 4 {
            draw.clear = ClearArea(enabled: true, x: r[0], y: r[1], width: r[2], height: r[3])
        }
        if let v = value("--angoli").flatMap(Double.init) { draw.clear.corners = v }
        if let v = value("--morbido").flatMap(Double.init) { draw.clear.feather = v }
        if args.contains("--esagoni") { draw.lens.grid = .hex }
        if let w = value("--canne").flatMap(Double.init) { draw.fluted.width = w }
        if let a = value("--angolo").flatMap(Double.init) { draw.fluted.angle = a }
        if let t = value("--colore").flatMap(FlutedOptions.Tint.init(rawValue:)) { draw.fluted.tint = t }
        if let g = value("--grana").flatMap(Double.init) { draw.lens.grain = g; draw.fluted.grain = g; draw.fog.grain = g }
        if let v = value("--curva").flatMap(Double.init) { draw.fluted.curve = v }
        if let v = value("--onde").flatMap(Double.init) { draw.fluted.waves = v }
        if let v = value("--strascico").flatMap(Double.init) { draw.fluted.smear = v }
        if let v = value("--rifrazione").flatMap(Double.init) { draw.fluted.refraction = v; draw.lens.refraction = v; draw.fog.refraction = v }
        if let v = value("--smerigliato").flatMap(Double.init) { draw.fluted.frost = v; draw.lens.frost = v; draw.fog.frost = v }
        if let v = value("--rilievo").flatMap(Double.init) { draw.lens.relief = v }
        if let v = value("--miniature").flatMap(Double.init) { draw.lens.miniatures = v }
        if let v = value("--bordi").flatMap(Double.init) { draw.lens.seams = v }
        if args.contains("--piramidi") { draw.lens.shape = .pyramid }
        if let v = value("--irregolarita").flatMap(Double.init) { draw.fluted.irregularity = v }
        // `--togli a,b`: quanto togliere a sinistra e a destra (frazioni).
        if let t = value("--togli")?.split(separator: ",").compactMap({ Double($0) }), t.count == 2 {
            draw.fluted.cutLeft = t[0]; draw.fluted.cutRight = t[1]; draw.lens.cutLeft = t[0]; draw.lens.cutRight = t[1]
            draw.fog.cutLeft = t[0]; draw.fog.cutRight = t[1]
        }
        if args.contains("--specchio") { draw.fluted.profile = .mirror }
        if let v = value("--ripetizione").flatMap(Double.init) { draw.fluted.repetition = v }
        if let v = value("--luce").flatMap(Double.init) { draw.fluted.light = v; draw.lens.light = v; draw.fog.light = v }
        if let v = value("--ombra").flatMap(Double.init) { draw.fluted.shadow = v }
        if let v = value("--dispersione").flatMap(Double.init) { draw.fluted.dispersion = v; draw.lens.dispersion = v; draw.fog.dispersion = v }
        var size = CGSize(width: 2880, height: 1864)
        if let m = value("--misura")?.split(separator: "x").compactMap({ Double($0) }), m.count == 2 { size = CGSize(width: m[0], height: m[1]) }
        var region: CGRect?
        if let r = value("--pezzo")?.split(separator: ",").compactMap({ Double($0) }), r.count == 4 { region = CGRect(x: r[0], y: r[1], width: r[2], height: r[3]) }
        guard let url = value("--immagine").map({ URL(fileURLWithPath: $0) }) ?? WallpaperFiles.defaultImage,
              let source = WallpaperSource(url: url) else { print("Immagine non leggibile"); return false }
        let start = Date()
        guard let image = WallpaperRenderer.render(source, draw, canvas: size, region: region, scale: 2) else { print("Disegno fallito"); return false }
        let ms = Int(Date().timeIntervalSince(start) * 1000)
        let out = URL(fileURLWithPath: path)
        guard let dest = CGImageDestinationCreateWithURL(out as CFURL, UTType.png.identifier as CFString, 1, nil) else { return false }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { return false }
        print("Stile \(draw.style.rawValue): \(image.width) x \(image.height) in \(ms) ms -> \(out.path)")
        return true
    }
}
