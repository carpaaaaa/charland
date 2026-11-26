import AppKit
import SwiftUI
import CharlandCore

/// «In riproduzione»: la musica di qualunque app (Musica, Spotify, Safari, YouTube…) nell'isola.
///
/// Da macOS 15.4 MediaRemote, il servizio di sistema che sa cosa suona, risponde solo ai programmi di Apple.
/// Charland fa girare un suo piccolo lettore (`libCharlandNowPlaying.dylib`, scritto da noi) dentro
/// `/usr/bin/perl`, che è di Apple: il lettore scrive una riga JSON a ogni cambiamento e riceve i comandi su stdin.
/// A riposo aspetta gli avvisi del sistema: nessun controllo periodico. Se cade, ripartiamo con calma.
@MainActor
final class NowPlayingMonitor {
    static let shared = NowPlayingMonitor()
    static let activityID = "musica"

    private var process: Process?
    private var input: FileHandle?
    private var buffer = Data()
    private var restartDelay: TimeInterval = 1
    private var running = false

    /// Lo stato: cosa suona, da dove, a che punto.
    private var title = ""
    private var artist = ""
    private var album = ""
    private var duration: TimeInterval = 0
    private var elapsed: TimeInterval = 0
    private var anchor = Date()
    private var rate: Double = 0
    private var playing = false
    private var app: String?
    private var appName: String?
    private var appIcon: NSImage?
    private var artwork: NSImage?
    private var tint: Color = .white
    private var shown = false
    private var hideTask: Task<Void, Never>?
    /// La copertina grande, per chi la mostra a tutta grandezza (il blocco schermo); nell'isola basta quella piccola.
    private var largeArtwork: NSImage?
    /// Il punto vecchio arrivato con la pausa e quello con cui è stato corretto (vedi `apply`).
    private var pausedFix: (elapsed: Double, stamp: Double, fixed: Double, at: Date)?
    /// Chiamata a ogni cambiamento di quello che suona, per chi non passa dall'isola (il blocco schermo).
    var onChange: (() -> Void)?
    /// Quello che suona adesso, o niente.
    var snapshot: NowPlayingSnapshot? {
        guard running, !title.isEmpty else { return nil }
        return NowPlayingSnapshot(title: title, artist: artist, album: album, duration: duration, elapsed: elapsed, anchor: anchor,
                                  rate: rate, playing: playing, app: app, artwork: largeArtwork ?? artwork, tint: tint)
    }

    /// In pausa l'isola tiene la musica ancora un po', poi la lascia andare.
    static let pausedLinger: TimeInterval = 45

    func start() {
        guard !running else { return }
        running = true
        launch()
    }

    func stop() {
        running = false
        idle = false
        hideTask?.cancel()
        try? input?.close()
        process?.terminate()
        process = nil
        input = nil
        if shown { shown = false; IslandHub.shared.primary?.engine.end(id: Self.activityID) }
        onChange?()
    }

    /// Un comando per l'app che suona: toggle, play, pause, next, previous, seek <secondi>.
    func send(_ command: String) {
        guard let input else { return }
        try? input.write(contentsOf: Data((command + "\n").utf8))
    }

    /// Apre l'app che sta suonando.
    /// Apre l'app che suona. Musica e Spotify proprio sulla canzone in riproduzione (carpa, 18 novembre 2026: «aprire
    /// l'app musica su quella canzone che sta andando»): Musica la mostra con `reveal current track`, Spotify apre la
    /// pagina della traccia. Serve l'Automazione, che macOS chiede al primo clic; negata, si apre solo l'app.
    func openApp() {
        guard let app else { return }
        let script: String
        switch app {
        case "com.apple.Music":
            script = "tell application id \"com.apple.Music\"\nactivate\nreveal current track\nend tell"
        case "com.spotify.client":
            script = "tell application id \"com.spotify.client\"\nactivate\nset u to spotify url of current track\nend tell\nopen location u"
        default:
            Self.open(app)
            return
        }
        // L'attivazione si cede prima: lo `activate` dello script, chiesto da un'app in secondo piano, non basta più.
        NSApp.activate()
        NSApp.yieldActivation(toApplicationWithBundleIdentifier: app)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", script]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        p.terminationHandler = { ended in
            let failed = ended.terminationStatus != 0
            Task { @MainActor in
                if failed { Self.open(app); return }
                // Lo script attiva l'app ma non rimette su una finestra ridotta nel Dock: ci pensa `AppFront`.
                if let running = NSRunningApplication.runningApplications(withBundleIdentifier: app).first {
                    AppFront.restoreWindows(of: running)
                }
            }
        }
        do { try p.run() } catch { Self.open(app) }
    }

    /// In alto a destra nella riproduzione aperta (carpa, 18 novembre 2026: «se premo in alto a destra voglio che in primo
    /// piano mi porti la schermata di quello che è in play come il video yt o la musica»): porta davanti la finestra di
    /// quello che suona. Nei browser la scheda giusta, trovata col titolo (YouTube mette il titolo del video nella
    /// scheda), con AppleScript come fa `openApp`; nelle altre app la finestra col titolo della canzone, con
    /// l'Accessibilità; se non si trova, l'app davanti.
    func showSource() {
        guard let app else { return }
        IslandHub.shared.primary?.engine.send(.collapse)
        let needle = title
        if app == "com.apple.Music" || app == "com.spotify.client" {
            openApp()
            return
        }
        if let script = Self.tabScript(app: app, title: needle) {
            NSApp.activate()
            NSApp.yieldActivation(toApplicationWithBundleIdentifier: app)
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            p.arguments = ["-e", script]
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            p.terminationHandler = { ended in
                guard ended.terminationStatus != 0 else { return }
                Task { @MainActor in Self.raiseWindow(app: app, title: needle) }
            }
            do { try p.run() } catch { Self.raiseWindow(app: app, title: needle) }
            return
        }
        Self.raiseWindow(app: app, title: needle)
    }

    /// Lo script che porta davanti la scheda del browser col titolo di quello che suona. Safari e i browser fatti come
    /// Chrome (Chrome, Brave, Edge, Vivaldi, Opera) sanno dire i titoli delle schede; gli altri no.
    private static func tabScript(app: String, title: String) -> String? {
        let needle = title.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        guard !needle.isEmpty else { return nil }
        switch app {
        case "com.apple.Safari", "com.apple.SafariTechnologyPreview":
            return """
            tell application id "\(app)"
                repeat with w in windows
                    repeat with t in tabs of w
                        if name of t contains "\(needle)" then
                            set current tab of w to t
                            set miniaturized of w to false
                            set index of w to 1
                            activate
                            return
                        end if
                    end repeat
                end repeat
                activate
            end tell
            """
        case "com.google.Chrome", "com.brave.Browser", "com.microsoft.edgemac", "com.vivaldi.Vivaldi", "com.operasoftware.Opera":
            return """
            tell application id "\(app)"
                repeat with w in windows
                    set i to 0
                    repeat with t in tabs of w
                        set i to i + 1
                        if title of t contains "\(needle)" then
                            set active tab index of w to i
                            set minimized of w to false
                            set index of w to 1
                            activate
                            return
                        end if
                    end repeat
                end repeat
                activate
            end tell
            """
        default:
            return nil
        }
    }

    /// La finestra dell'app col titolo di quello che suona (un lettore video, un'app di podcast), alzata con
    /// l'Accessibilità; senza, l'app davanti con la sua finestra di sempre.
    private static func raiseWindow(app: String, title: String) {
        guard let running = NSRunningApplication.runningApplications(withBundleIdentifier: app).first else {
            open(app)
            return
        }
        // Davanti come col clic sull'icona nel Dock, con su la finestra che ha nel titolo quello che suona.
        AppFront.bring(running, titled: title.isEmpty ? nil : title)
    }

    private static func open(_ bundleID: String) {
        // Ceduta l'attivazione, come «Apri Charcal» nel Dock: da sola, da un'app in secondo piano, l'app restava dietro.
        DockLaunch.open(bundle: bundleID)
    }

    private func launch() {
        guard running, process == nil,
              let dylib = Bundle.main.privateFrameworksURL?.appendingPathComponent("libCharlandNowPlaying.dylib"),
              let script = Bundle.main.url(forResource: "nowplaying", withExtension: "pl"),
              FileManager.default.fileExists(atPath: dylib.path) else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        p.arguments = [script.path, dylib.path]
        let out = Pipe(), inp = Pipe()
        p.standardOutput = out
        p.standardInput = inp
        p.standardError = FileHandle.nullDevice
        out.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            // Niente dati vuol dire che il lettore ha chiuso: l'ascolto va staccato, o Foundation continua a chiamarlo
            // a vuoto senza sosta (un nucleo al 100% dopo aver spento la musica nelle impostazioni, o a ogni caduta).
            if data.isEmpty { handle.readabilityHandler = nil; return }
            Task { @MainActor in NowPlayingMonitor.shared.received(data) }
        }
        p.terminationHandler = { ended in
            let id = ObjectIdentifier(ended)
            Task { @MainActor in NowPlayingMonitor.shared.ended(id) }
        }
        // Scrivere a un lettore appena caduto non deve chiudere Charland (SIGPIPE): la scrittura fallisce e basta.
        _ = fcntl(inp.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        // Una mezza riga del lettore di prima non deve mangiarsi la prima di questo.
        buffer.removeAll(keepingCapacity: true)
        do { try p.run() } catch { return }
        process = p
        input = inp.fileHandleForWriting
    }

    private func ended(_ id: ObjectIdentifier) {
        // un lettore vecchio che finisce dopo un riavvio non deve staccare quello nuovo
        guard let process, ObjectIdentifier(process) == id else { return }
        self.process = nil
        input = nil
        guard running else { return }
        // ripartire, ma con calma se cade di continuo
        let delay = restartDelay
        restartDelay = min(restartDelay * 2, 60)
        Task {
            try? await Task.sleep(for: .seconds(delay))
            NowPlayingMonitor.shared.launch()
        }
    }

    private func received(_ data: Data) {
        // Una riga arrivata dopo lo spegnimento non rimette la musica nell'isola (nessuno la toglierebbe più).
        guard running, !data.isEmpty else { return }
        buffer.append(data)
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<newline]
            buffer.removeSubrange(buffer.startIndex...newline)
            guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
            // L'attesa prima di ripartire torna corta solo quando arriva una lettura vera: «ready» esce prima della
            // prima lettura, e un lettore che cadeva proprio lì ripartiva ogni secondo per sempre.
            if object["type"] as? String == "info" { restartDelay = 1; apply(object) }
        }
    }

    private func apply(_ o: [String: Any]) {
        let wasPlaying = playing, before = (title, artist, album)
        title = o["title"] as? String ?? ""
        artist = o["artist"] as? String ?? (o["album"] as? String ?? "")
        album = o["album"] as? String ?? ""
        duration = (o["duration"] as? NSNumber)?.doubleValue ?? 0
        let saidElapsed = (o["elapsed"] as? NSNumber)?.doubleValue, saidStamp = (o["timestamp"] as? NSNumber)?.doubleValue
        elapsed = saidElapsed ?? 0
        if let saidStamp { anchor = Date(timeIntervalSince1970: saidStamp) } else { anchor = Date() }
        playing = (o["playing"] as? NSNumber)?.boolValue ?? false
        let saidRate = (o["rate"] as? NSNumber)?.doubleValue
        rate = playing ? max(0.01, saidRate ?? 1) : 0
        // Alla pausa può arrivare il «fermo» prima del punto aggiornato: il punto e l'ora sono ancora quelli di quando
        // suonava, col suo passo. Preso così com'è, il punto tornava indietro di tutto il tempo suonato da allora (il
        // testo e la costellazione del blocco tornavano indietro): lo si porta avanti fino ad adesso, che è dove la
        // musica si è fermata. Se in pausa ritorna lo stesso punto vecchio (un altro avviso, la copertina), resta
        // quello già corretto.
        if !playing, (title, artist, album) == before, let saidRate, saidRate > 0, let saidElapsed, let saidStamp {
            if wasPlaying {
                let now = Date()
                elapsed = saidElapsed + max(0, now.timeIntervalSince(anchor)) * saidRate
                if duration > 0 { elapsed = min(elapsed, duration) }
                anchor = now
                pausedFix = (saidElapsed, saidStamp, elapsed, now)
            } else if let fix = pausedFix, fix.elapsed == saidElapsed, fix.stamp == saidStamp {
                elapsed = fix.fixed; anchor = fix.at
            }
        }
        if playing || (title, artist, album) != before { pausedFix = nil }
        let newApp = o["app"] as? String
        if newApp != app {
            app = newApp
            // l'icona dell'app che suona: al posto della copertina quando un sito non la manda
            appIcon = newApp.flatMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }
                .map { TrayStore.shrink(NSWorkspace.shared.icon(forFile: $0.path), side: 64) }
        }
        appName = (o["appName"] as? String) ?? app.flatMap { id in
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: id).map { FileManager.default.displayName(atPath: $0.path).replacingOccurrences(of: ".app", with: "") }
        }
        if let art = o["artwork"] as? String {
            artworkGeneration += 1
            if art.isEmpty { artwork = nil; largeArtwork = nil; tint = .white } else { decodeArtwork(art, generation: artworkGeneration) }
        }
        onChange?()
        publish()
    }

    /// La copertina e il suo colore si preparano fuori dal thread principale.
    /// Ogni copertina arrivata (o tolta) ha il suo numero: una che finisce di prepararsi dopo una più nuova si butta.
    /// Saltando brani in fretta, la copertina grande di prima poteva arrivare per ultima e restare sul brano nuovo.
    private var artworkGeneration = 0

    private func decodeArtwork(_ base64: String, generation: Int) {
        Task.detached(priority: .userInitiated) {
            guard let data = Data(base64Encoded: base64), let image = NSImage(data: data) else { return }
            let small = TrayStore.shrink(image, side: 120)
            let color = NowPlayingMonitor.averageColor(small)
            let box = IconBox(small)
            // la copertina com'è arrivata (di solito 600 punti), ridotta solo se è enorme
            let pixels = image.representations.map(\.pixelsWide).max() ?? Int(image.size.width)
            let largeBox = IconBox(pixels > 1600 ? TrayStore.shrink(image, side: 1400) : image)
            await MainActor.run {
                let me = NowPlayingMonitor.shared
                guard me.artworkGeneration == generation else { return }
                me.artwork = box.image
                me.largeArtwork = largeBox.image
                me.tint = color
                me.onChange?()
                me.publish()
            }
        }
    }

    /// Il colore medio della copertina, schiarito perché si legga sul nero.
    nonisolated static func averageColor(_ image: NSImage) -> Color {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let ctx = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return .white }
        ctx.interpolationQuality = .medium
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        guard let p = ctx.data?.assumingMemoryBound(to: UInt8.self) else { return .white }
        var (r, g, b) = (Double(p[0]) / 255, Double(p[1]) / 255, Double(p[2]) / 255)
        // abbastanza chiaro da leggersi sul nero: si alza verso il bianco fino a una luminosità minima
        let lum = 0.2126 * r + 0.7152 * g + 0.0722 * b
        if lum < 0.55 { let k = (0.55 - lum) / max(0.01, 1 - lum); r += (1 - r) * k; g += (1 - g) * k; b += (1 - b) * k }
        return Color(red: r, green: g, blue: b)
    }

    private var info: MusicInfo {
        MusicInfo(title: title, artist: artist, elapsed: elapsed, duration: duration, isPlaying: playing,
                  artwork: artwork, anchor: anchor, rate: rate, tint: tint, appName: appName, appIcon: appIcon)
    }

    private func publish() {
        guard let engine = IslandHub.shared.primary?.engine else { return }
        guard !title.isEmpty else {
            hideTask?.cancel()
            // La riproduzione vuota resta aperta finché la guardi: niente che suona è proprio quello che mostra.
            if idle { engine.update(id: Self.activityID, content: .music(idleInfo)); return }
            if shown { shown = false; engine.end(id: Self.activityID) }
            return
        }
        // Qualcosa è arrivato mentre la riproduzione era vuota: diventa quella vera, nello stesso posto.
        idle = false
        hideTask?.cancel()
        if !playing {
            // in pausa resta un poco, poi se ne va
            hideTask = Task {
                try? await Task.sleep(for: .seconds(Self.pausedLinger))
                guard !Task.isCancelled else { return }
                let me = NowPlayingMonitor.shared
                if !me.playing, me.shown { me.shown = false; IslandHub.shared.primary?.engine.end(id: Self.activityID) }
            }
            // una canzone mai partita mentre Charland era aperta non compare in pausa
            guard shown else { return }
        }
        if shown {
            engine.update(id: Self.activityID, content: .music(info))
        } else {
            shown = true
            engine.show(Self.activity, content: .music(info))
        }
    }

    private static let activity = IslandActivity(id: activityID, priority: 0, leadingWidth: 26, trailingWidth: 26,
                                                 expandedWidth: 330, expandedHeight: 116)

    /// Quanto si aspetta che l'ultimo lettore riparta, prima di far partire l'app della musica scelta.
    private static let resumeWait: TimeInterval = 2

    /// La riproduzione vuota è nell'isola (vedi `MusicInfo.idle`).
    private(set) var idle = false

    private var idleInfo: MusicInfo {
        MusicInfo(title: "", artist: "", elapsed: 0, duration: 0, isPlaying: false, appName: MusicApp.shared.name, idle: true)
    }

    /// La tessera Musica della casa (carpa, 18 novembre 2026: «quando premi su music nel notch vada direttamente dove c'è
    /// il player anche se nulla sta andando»): apre subito la riproduzione nell'isola. Una canzone in pausa da tanto (già
    /// uscita dall'isola) torna dentro, in pausa; con niente da mostrare si apre la riproduzione vuota, con la nota che
    /// apre l'app della musica e ▶︎ per ripartire.
    func openInIsland() {
        guard let engine = IslandHub.shared.primary?.engine else { return }
        if shown {
            engine.send(.expand(id: Self.activityID))
            return
        }
        if !title.isEmpty {
            shown = true
            engine.show(Self.activity, content: .music(info))
            engine.send(.expand(id: Self.activityID))
            // In pausa resta quanto di solito, poi se ne va.
            hideTask?.cancel()
            hideTask = Task {
                try? await Task.sleep(for: .seconds(Self.pausedLinger))
                guard !Task.isCancelled else { return }
                let me = NowPlayingMonitor.shared
                if !me.playing, me.shown { me.shown = false; IslandHub.shared.primary?.engine.end(id: Self.activityID) }
            }
            return
        }
        hideTask?.cancel()
        idle = true
        shown = true
        engine.show(Self.activity, content: .music(idleInfo))
        engine.send(.expand(id: Self.activityID))
    }

    /// ▶︎ nella riproduzione vuota: riparte l'ultimo lettore (quello che macOS ricorda); se in due secondi nessuno
    /// risponde parte l'app della musica scelta.
    func playFromIdle() {
        send("play")
        Task {
            try? await Task.sleep(for: .seconds(Self.resumeWait))
            let me = NowPlayingMonitor.shared
            guard me.idle else { return }
            MusicApp.shared.play()
        }
    }

    /// La nota della riproduzione vuota: apre l'app della musica scelta.
    func openMusicApp() {
        IslandHub.shared.primary?.engine.send(.collapse)
        MusicApp.shared.open()
    }

    /// L'isola ha cambiato stato: la riproduzione vuota vive solo finché è aperta, poi se ne va (chiusa non c'è niente da
    /// mostrare, e passando sopra il notch deve tornare la casa).
    func islandModeChanged(_ mode: IslandMode) {
        guard idle else { return }
        if case .expanded(Self.activityID) = mode { return }
        idle = false
        shown = false
        IslandHub.shared.primary?.engine.end(id: Self.activityID)
    }
}

/// Quello che suona, tutto in un colpo: per chi lo mostra fuori dall'isola (il blocco schermo).
struct NowPlayingSnapshot {
    var title: String
    var artist: String
    var album: String
    var duration: TimeInterval
    var elapsed: TimeInterval
    var anchor: Date
    var rate: Double
    var playing: Bool
    /// L'app che suona (identificativo), se si sa.
    var app: String?
    var artwork: NSImage?
    var tint: Color

    /// Il punto della canzone a un certo istante: quello detto dal sistema, portato avanti col suo passo.
    func position(at date: Date) -> TimeInterval {
        let p = elapsed + date.timeIntervalSince(anchor) * rate
        return duration > 0 ? min(max(0, p), duration) : max(0, p)
    }

    /// Cambia quando cambia il brano, non quando cambia il punto o la pausa.
    var trackKey: String { "\(artist)|\(title)|\(album)|\(Int(duration.rounded()))" }
}
