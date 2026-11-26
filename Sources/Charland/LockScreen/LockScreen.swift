import AppKit
import SwiftUI
import IOKit.pwr_mgt
import CharlandCore

/// Il blocco schermo di Charland: i segni sotto l'orologio, il lettore al centro, la copertina aperta col testo.
///
/// Due finestre nello Space del blocco (`LockSpace`), vive per tutta la vita dell'app e mostrate solo a schermo bloccato:
/// - la scena, a tutto schermo, che disegna tutto. A copertina chiusa lascia passare ogni clic (sotto c'è il blocco di macOS);
///   a copertina aperta li prende lei;
/// - una finestrella grande come il lettore, che a copertina chiusa prende i clic sul lettore e basta.
/// Nessuna delle due prende mai la tastiera: quella è della password.
@MainActor
final class LockScreen {
    static let shared = LockScreen()

    let model = LockModel()
    private let watcher = LockWatcher()
    private var space: LockSpace?
    private var stage: LockPanel?
    private var hit: LockPanel?
    private var started = false
    private var active = false
    private var ticker: Timer?
    private var hideTask: Task<Void, Never>?
    private var musicTask: Task<Void, Never>?
    private var seekTask: Task<Void, Never>?
    private var signsAt = Date.distantPast
    private var pausedSince: Date?
    private var agendaStarted = false
    private var previewWindow: NSWindow?
    private var awakeHold: IOPMAssertionID = 0
    /// Quando è stato bloccato lo schermo: da lì si contano i minuti in cui resta acceso con la musica.
    private var lockedAt = Date.distantPast
    /// Il timer che porta avanti i passaggi e, a copertina aperta, il testo. Gira solo quando qualcosa si muove.
    private var frameTimer: Timer?
    private var lastFrame = 0.0
    private var screenObserver: NSObjectProtocol?
    /// Quanti fotogrammi al secondo: quelli dello schermo del blocco (60, o 120 sugli schermi ProMotion).
    private var frameRate = 60.0
    /// Il testo del brano nuovo, arrivato mentre quello di prima sta ancora sfumando.
    private var incoming: (lyrics: Lyrics?, duration: Double)?
    private var pendingSince = Date.distantPast
    /// Per le prove: quanti fotogrammi ha preso un passaggio e quanto è durato il peggiore.
    private var pace = (frames: 0, total: 0.0, worst: 0.0)
    /// Quale fotogramma del passaggio è stato il peggiore: il primo non si vede (prima non si muoveva niente), uno in mezzo sì.
    private var paceWorstAt = 0
    private var textPace = (frames: 0, total: 0.0, worst: 0.0)
    private var shortPace = (frames: 0, total: 0.0, worst: 0.0)
    private var shortWorstAt = 0
    /// Per le prove: quanto lavora il thread principale per un fotogramma, dal timer a quando torna a riposo
    /// (dentro ci sono il ridisegno di SwiftUI e la consegna a Core Animation). Dice se c'è margine per i 120 al secondo.
    private var work = (frames: 0, total: 0.0, worst: 0.0)
    private var frameStart: Double?
    private var workObserver: CFRunLoopObserver?
    private var ticks = 0
    /// Da quanto non veniva premuto un tasto all'ultimo giro: se il numero scende, un tasto è stato premuto.
    private var keyIdle = 0.0
    /// Lo spazio che mette in pausa la musica: un giro svelto che guarda se lo spazio è premuto (sul blocco macOS dice
    /// che un tasto è stato premuto, non quale; lo stato dello spazio invece si legge). `spaceDown` è come era al giro
    /// prima, `spaceIdle` da quanto non si premeva un tasto prima di questo, `spaceAt` quando lo spazio ha fatto pausa:
    /// quel tasto non deve richiudere la copertina.
    private var spaceWatch: Timer?
    private var spaceDown = false
    private var spaceIdle = 0.0
    private var spaceAt = Date.distantPast

    /// In pausa il lettore resta un poco sul blocco, poi rientra nel notch.
    static let pausedLinger: TimeInterval = 120

    private init() {}

    // MARK: Vita

    func start() {
        guard !started else { return }
        started = true
        watcher.onLock = { [weak self] in self?.lock() }
        watcher.onUnlock = { [weak self] in self?.unlock() }
        watcher.onDisplay = { [weak self] awake in self?.model.awake = awake; self?.kick() }
        NowPlayingMonitor.shared.onChange = { [weak self] in self?.musicChanged() }
        screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.screensChanged() }
        }
        watcher.start()
    }

    // MARK: Movimento

    /// Accende il timer dei fotogrammi, se non gira già. Si spegne da solo quando non c'è più niente da muovere.
    private func watchWork() {
        guard workObserver == nil, ProcessInfo.processInfo.environment["CHARLAND_BLOCCO_REGISTRO"] != nil else { return }
        // l'ultimo a girare prima del riposo, dopo la consegna di Core Animation
        let observer = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeWaiting.rawValue, true, CFIndex.max) { [weak self] _, _ in
            MainActor.assumeIsolated {
                guard let self, let start = self.frameStart else { return }
                self.frameStart = nil
                let spent = CACurrentMediaTime() - start
                self.work.frames += 1; self.work.total += spent; self.work.worst = max(self.work.worst, spent)
            }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
        workObserver = observer
    }

    private func workNote() -> String {
        guard work.frames > 0 else { return "" }
        defer { work = (0, 0, 0) }
        return String(format: " | lavoro medio %.1f ms, peggiore %.1f ms", work.total / Double(work.frames) * 1000, work.worst * 1000)
    }

    private func kick() {
        guard frameTimer == nil else { return }
        watchWork()
        lastFrame = CACurrentMediaTime()
        let timer = Timer(timeInterval: 1.0 / frameRate, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.frame() } }
        RunLoop.main.add(timer, forMode: .common)
        frameTimer = timer
    }

    private func frame() {
        let now = CACurrentMediaTime()
        ticks &+= 1
        // sugli schermi a 120 il passo doppio serve solo ai passaggi: a copertina ferma (testo che scorre, luci) bastano 60
        if frameRate > 90, ticks % 2 == 1, !model.inMotion { return }
        if workObserver != nil { frameStart = now }
        let raw = now - lastFrame
        let dt = min(0.05, max(0.001, raw))
        lastFrame = now
        var busy = model.advance(dt)
        turnLyrics()
        if let stepsFile = Self.stepsFile, model.openT > 0, model.openT < 1 || pace.frames > 0 {
            let z = MappaView.zoom(model.openT, opening: model.open)
            stepsFile.write(Data(String(format: "%.4f %@ %d %.2f %.4f %.4f %.4f %.2f\n", now, model.open ? "A" : "C", pace.frames + 1, raw * 1000, model.openT, Double(z),
                                        MappaView.late(model.openT, opening: model.open), Double(MappaView.corner(z))).utf8))
        }
        if model.openT > 0, model.openT < 1 {
            pace.frames += 1; pace.total += raw
            if raw > pace.worst { pace.worst = raw; paceWorstAt = pace.frames }
        } else if pace.frames > 0 {
            note(String(format: "passaggio %@: %d fotogrammi, medio %.1f ms, peggiore %.1f ms (il numero %d)", model.open ? "aperta" : "chiusa",
                        pace.frames, pace.total / Double(pace.frames) * 1000, pace.worst * 1000, paceWorstAt) + workNote())
            pace = (0, 0, 0); paceWorstAt = 0
        }
        // il lettore che compare o se ne va, la pausa che si posa: passaggi brevi a copertina aperta
        let short = model.openT == 1 && ((model.hoverT > 0 && model.hoverT < 1) || model.hoverS != (model.hover ? 1 : 0) || model.hoverV != 0
            || (model.playT > 0 && model.playT < 1))
        if short {
            shortPace.frames += 1; shortPace.total += raw
            if raw > shortPace.worst { shortPace.worst = raw; shortWorstAt = shortPace.frames }
        } else if shortPace.frames > 0 {
            note(String(format: "passaggio lettore/pausa: %d fotogrammi, medio %.1f ms, peggiore %.1f ms (il numero %d)", shortPace.frames,
                        shortPace.total / Double(shortPace.frames) * 1000, shortPace.worst * 1000, shortWorstAt) + workNote())
            shortPace = (0, 0, 0); shortWorstAt = 0
        }
        if model.textT > 0, model.textT < 1 {
            textPace.frames += 1; textPace.total += raw; textPace.worst = max(textPace.worst, raw)
        } else if textPace.frames > 0 {
            note(String(format: "passaggio testo %@: %d fotogrammi, medio %.1f ms, peggiore %.1f ms", model.wantsColumn ? "acceso" : "spento",
                        textPace.frames, textPace.total / Double(textPace.frames) * 1000, textPace.worst * 1000) + workNote())
            textPace = (0, 0, 0)
        } else if work.frames >= 150, model.openT == 1 {
            // a copertina ferma: ogni due secondi e mezzo circa
            note("copertina ferma, " + (model.wantsColumn ? "col testo" : "senza testo") + workNote())
        }
        if model.openT > 0 {
            stepLive(dt)
            // a copertina aperta il testo scorre e la foto respira: il timer resta acceso finché lo schermo è acceso
            if model.awake { busy = true }
        }
        if !busy { frameTimer?.invalidate(); frameTimer = nil }
    }

    /// Per le prove (`CHARLAND_BLOCCO_PASSI=<file>`): a ogni fotogramma dell'apertura e della chiusura (e al primo dopo),
    /// l'ora, aperta o chiusa, il numero del fotogramma, quanto è durato, `openT`, la crescita della foto, quanto si vede
    /// quello che arriva tardi e il raggio degli angoli. Serve a capire in quale punto del passaggio cade un fotogramma lungo.
    private static let stepsFile = ProcessInfo.processInfo.environment["CHARLAND_BLOCCO_PASSI"].flatMap { path -> FileHandle? in
        FileManager.default.createFile(atPath: path, contents: nil)
        return FileHandle(forWritingAtPath: path)
    }

    /// Per le prove (`CHARLAND_BLOCCO_SINCRO=<file>`): ogni quarto di secondo, l'ora vera, il punto della canzone che
    /// Charland calcola e quello che disegnano i temi a tutto schermo. Si confronta con quello che dice l'app che suona.
    private static let syncFile = ProcessInfo.processInfo.environment["CHARLAND_BLOCCO_SINCRO"].flatMap { path -> FileHandle? in
        FileManager.default.createFile(atPath: path, contents: nil)
        return FileHandle(forWritingAtPath: path)
    }
    private var syncAt = 0.0

    private func stepLive(_ dt: Double, snap: Bool = false) {
        if let file = Self.syncFile, Date().timeIntervalSince1970 - syncAt >= 0.25 {
            syncAt = Date().timeIntervalSince1970
            file.write(Data(String(format: "%.3f %.3f %.3f %d\n", syncAt, model.position(at: Date()), model.mappa.time, model.playing ? 1 : 0).utf8))
        }
        dropLooseDrag()
        Mappa.step(model, dt, frame: model.direct ? previewWindow.flatMap { w in w.contentView.map { w.convertToScreen($0.frame) } } : stage?.frame)
        Montaggio.step(model, dt)
        // in pausa il respiro della foto e lo sfondo si fermano
        if model.playing { model.live.clock += dt }
        // al cambio brano il testo di prima resta fermo dov'era mentre sfuma; col testo spento non c'è niente da muovere.
        // La costellazione non usa la colonna: il suo punto della canzone lo porta avanti `Mappa.step`
        guard model.textShown, model.wantsColumn || model.textT > 0, !Mappa.uses else { return }
        model.live.step(dt, time: model.position(at: Date()), rows: model.rows, rowFallback: 52 * model.layout.k * 1.64, snap: snap)
    }

    /// Il cambio del testo: quello del brano di prima sfuma, poi si svuota, poi entra quello nuovo, se è arrivato.
    private func turnLyrics() {
        guard !model.textShown, model.lyricsT == 0 else { return }
        if !model.rows.isEmpty { model.lyrics = nil; model.rows = []; model.live.reset(rows: 0) }
        guard let next = incoming else { return }
        incoming = nil
        model.lyricsPending = false
        guard let lyrics = next.lyrics else { return }
        model.lyrics = lyrics
        model.rows = lyrics.rows(trackDuration: next.duration)
        model.live.reset(rows: model.rows.count)
        model.textShown = true
        stepLive(0, snap: true)
    }

    func stop() {
        guard started else { return }
        started = false
        watcher.stop()
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        screenObserver = nil
        NowPlayingMonitor.shared.onChange = nil
        ticker?.invalidate(); ticker = nil
        spaceWatch?.invalidate(); spaceWatch = nil
        hideTask?.cancel(); musicTask?.cancel()
        active = false
        LockGuard.shared.disarm()
        agendaStarted = false
        updateAwakeHold()
        stage?.orderOut(nil); hit?.orderOut(nil)
        stage = nil; hit = nil
        space?.close(); space = nil
    }

    /// Lo schermo del blocco: quello principale, dove macOS mette l'accesso (il primo dell'elenco, quello con la barra
    /// dei menu). Non quello col notch, né quello dove sta la tastiera: con un monitor esterno come principale il blocco
    /// con la password è là.
    private static var screen: NSScreen? { NSScreen.screens.first ?? NSScreen.main }

    /// Gli schermi sono cambiati (un monitor collegato o staccato, un'altra risoluzione): a blocco fuori, tutto si rimette a misura.
    private func screensChanged() {
        guard active, !model.direct, let screen = Self.screen else { return }
        build(on: screen)
        placeHit()
        note("schermi cambiati: ora \(Int(model.size.width)) x \(Int(model.size.height))")
        kick()
    }

    /// Il notch in punti dall'alto a sinistra dello schermo (senza notch: una tacca finta al centro, da cui far nascere il lettore).
    private static func notch(of screen: NSScreen) -> CGRect {
        let w = screen.frame.width
        if screen.safeAreaInsets.top > 0, let l = screen.auxiliaryTopLeftArea, let r = screen.auxiliaryTopRightArea {
            return CGRect(x: l.width, y: 0, width: max(120, w - l.width - r.width), height: screen.safeAreaInsets.top)
        }
        return CGRect(x: w / 2 - 102, y: -34, width: 204, height: 34)
    }

    private func build(on screen: NSScreen) {
        let frame = screen.frame
        if stage == nil {
            guard let space = LockSpace() else { return }
            self.space = space
            let panel = LockPanel(frame: frame)
            let host = FirstMouseHostingView(rootView: LockStage(model: model))
            host.sizingOptions = []
            host.frame = CGRect(origin: .zero, size: frame.size)
            host.autoresizingMask = [.width, .height]
            panel.contentView = host
            space.adopt(panel)
            stage = panel

            let small = LockPanel(frame: CGRect(x: 0, y: 0, width: 440, height: 180))
            small.ignoresMouseEvents = false
            let view = LockHitView(frame: CGRect(x: 0, y: 0, width: 440, height: 180))
            view.autoresizingMask = [.width, .height]
            small.contentView = view
            space.adopt(small)
            hit = small
        }
        stage?.setFrame(frame, display: false)
        model.size = frame.size
        model.notch = Self.notch(of: screen)
        // il passo del movimento segue lo schermo; se cambia, il timer riparte col passo nuovo
        // (per le prove si può forzare con `CHARLAND_BLOCCO_HZ`)
        let forced = Double(ProcessInfo.processInfo.environment["CHARLAND_BLOCCO_HZ"] ?? "")
        let rate = min(120, max(30, forced ?? Double(max(60, screen.maximumFramesPerSecond))))
        if rate != frameRate { frameRate = rate; frameTimer?.invalidate(); frameTimer = nil }
    }

    // MARK: Blocco e sblocco

    /// Per le prove sul blocco vero: con `CHARLAND_BLOCCO_REGISTRO=<file>` scrive cosa succede e quando.
    private func note(_ text: String) {
        guard let path = ProcessInfo.processInfo.environment["CHARLAND_BLOCCO_REGISTRO"] else { return }
        let line = String(format: "%.2f  %@\n", Date().timeIntervalSince1970.truncatingRemainder(dividingBy: 100000), text)
        if let handle = FileHandle(forWritingAtPath: path) { handle.seekToEndOfFile(); handle.write(Data(line.utf8)); try? handle.close() }
        else { try? Data(line.utf8).write(to: URL(fileURLWithPath: path)) }
    }

    private func lock() {
        hideTask?.cancel()
        guard let screen = Self.screen else { return }
        build(on: screen)
        guard let stage else { return }
        active = true
        lockedAt = Date()
        model.leaving = false
        model.open = false; model.shown = false; model.hover = false; model.seeking = nil
        model.awake = watcher.displayAwake
        stage.ignoresMouseEvents = true
        refreshSigns(force: true)
        musicChanged()
        model.settle()
        turnLyrics()
        // il paracadute: se nel blocco di prima era scattato, lo Space torna visibile; poi si riarma (`LockGuard`)
        if let space {
            if LockGuard.shared.didFire { space.reveal(); note("paracadute: lo Space del blocco torna visibile") }
            LockGuard.shared.arm(space.hider)
        }
        stage.orderFrontRegardless()
        note("blocco: scena fuori (visibile \(stage.isVisible)), musica \(model.music?.title ?? "nessuna"), segni \(model.signs.count)")
        // per provare il paracadute: `CHARLAND_BLOCCO_STALLO=<dopo quanti secondi>|<per quanti>` ferma il thread principale
        if let stall = ProcessInfo.processInfo.environment["CHARLAND_BLOCCO_STALLO"]?.split(separator: "|").compactMap({ Double($0) }), stall.count == 2 {
            DispatchQueue.main.asyncAfter(deadline: .now() + stall[0]) { [weak self] in
                self?.note("prova: thread principale fermo per \(stall[1]) s")
                Thread.sleep(forTimeInterval: stall[1])
                self?.note("prova: thread principale ripartito (paracadute scattato: \(LockGuard.shared.didFire))")
            }
        }
        // un attimo dopo, tutto entra: i segni e il lettore salgono appena e si accendono
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
            guard let self, self.active else { return }
            self.model.shown = true
            self.placeHit()
            self.kick()
        }
        startTicker()
    }

    private func unlock() {
        guard active else { return }
        active = false
        LockGuard.shared.disarm()
        ticker?.invalidate(); ticker = nil
        spaceWatch?.invalidate(); spaceWatch = nil
        // tutto sfuma e basta, senza muoversi (carpa, 18 novembre 2026: niente volo verso il notch); poi le finestre
        // spariscono dalla scrivania e lo stato si rimette a posto di nascosto
        model.leaving = true; model.hover = false
        kick()
        stage?.ignoresMouseEvents = true
        hit?.orderOut(nil)
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(260))
            guard !Task.isCancelled, let self, !self.active else { return }
            self.stage?.orderOut(nil)
            self.model.open = false; self.model.shown = false; self.model.leaving = false
            self.model.settle()
            Mappa.release(self.model)
            self.updateAwakeHold()
            self.note("sblocco: finestre rientrate (scena visibile \(self.stage?.isVisible ?? false), clic visibile \(self.hit?.isVisible ?? false))")
        }
    }

    // MARK: Musica

    private func musicChanged() {
        guard active else { return }
        let snapshot = LockSettings.shared.player ? NowPlayingMonitor.shared.snapshot : nil
        if let snapshot {
            musicTask?.cancel()
            let newTrack = snapshot.trackKey != model.music?.trackKey
            let newArt = snapshot.artwork !== model.music?.artwork
            if snapshot.playing { pausedSince = nil } else if pausedSince == nil { pausedSince = Date() }
            // una pausa o una ripresa mentre l'app non ha ancora preso il punto scelto: il punto resta dov'era arrivato
            // (in pausa tornava al punto del rilascio, alla ripresa sarebbe saltato avanti di tutta la pausa)
            if model.seekReleased != nil, let before = model.music, before.playing != snapshot.playing {
                let now = Date()
                model.seeking = model.position(at: now)
                model.seekReleased = now
            }
            // la barra trascinata resta finché l'app non ha preso il punto nuovo: un avviso col punto vecchio (arriva
            // spesso subito dopo il rilascio) la faceva tornare indietro per un attimo, e mentre la si trascina un
            // avviso qualunque la toglieva da sotto il dito
            if model.seeking == nil || newTrack || seekTaken(snapshot) { seekTask?.cancel(); model.seeking = nil }
            // il brano di prima si scioglie in quello nuovo
            if newTrack, model.music != nil {
                model.oldArtwork = model.music?.artwork; model.oldBackdrop = model.backdrop; model.oldShade = model.shade
                model.oldLights = model.lights
                model.trackT = 0
            }
            model.music = snapshot
            if newArt { makeBackdrop(snapshot.artwork, key: snapshot.trackKey) }
            Mappa.ensure(model)
            if newTrack {
                // il testo di prima sfuma; quello nuovo entra quando arriva. Intanto la foto non si sposta:
                // se il brano di prima aveva il testo, è probabile che ce l'abbia anche questo
                incoming = nil
                model.textShown = false
                model.lyricsPending = LockSettings.shared.lyrics && LyricsService.isMusicApp(snapshot.app)
                pendingSince = Date()
                LyricsService.shared.lyrics(for: snapshot) { [weak self] result in
                    guard let self, self.model.music?.trackKey == snapshot.trackKey else { return }
                    if case .synced(let lyrics) = result { self.incoming = (lyrics, snapshot.duration) } else { self.incoming = (nil, 0) }
                    self.turnLyrics()
                    self.kick()
                }
            }
            let linger = pausedSince.map { Date().timeIntervalSince($0) < Self.pausedLinger } ?? true
            setPresent(linger)
        } else {
            setPresent(false)
        }
        updateAwakeHold()
        kick()
    }

    private func setPresent(_ present: Bool) {
        if present {
            guard !model.present else { return }
            model.present = true
            placeHit()
        } else {
            guard model.present else { return }
            model.present = false; model.open = false; model.hover = false
            stage?.ignoresMouseEvents = !model.direct
            // Una barra trascinata in questo momento non riceverà più il rilascio (la finestrella dei clic se ne va):
            // la si lascia adesso. Senza, barra e testo restavano fermi sul punto del dito fino al cambio di brano
            // (`dropLooseDrag` guarda solo a copertina aperta).
            seekTask?.cancel()
            model.seeking = nil
            (hit?.contentView as? LockHitView)?.endScrub()
            hit?.orderOut(nil)
            // il tempo di sfumare, poi si svuota
            musicTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(800))
                guard !Task.isCancelled, let self, !self.model.present else { return }
                self.model.music = nil; self.model.backdrop = nil; self.model.lyrics = nil; self.model.rows = []
                self.model.textShown = false; self.model.lyricsPending = false; self.incoming = nil
                self.model.live.reset(rows: 0)
            }
        }
    }

    /// La copertina piccola e sfocata che fa da sfondo alla copertina aperta: si sfoca un'immagine minuscola e la si ingrandisce.
    private func makeBackdrop(_ image: NSImage?, key: String) {
        guard let image else { model.backdrop = nil; model.shade = LockModel.baseShade; model.lights = []; return }
        let box = IconBox(image)
        Task.detached(priority: .userInitiated) {
            guard let blurred = Self.blurred(box.image) else { return }
            let shade = Self.shade(for: blurred)
            let palette = LockLights.palette(for: box.image)
            let out = IconBox(blurred)
            await MainActor.run {
                let me = LockScreen.shared
                guard me.model.music?.trackKey == key else { return }
                me.model.backdrop = out.image; me.model.shade = shade
                me.model.lights = LockLights.lights(for: palette)
            }
        }
    }

    /// Quanto nero mettere sopra lo sfondo perché il bianco resti bianco: si guarda quanto è chiara la copertina sfocata
    /// dove cadono il testo (a destra) e titolo e comandi (in basso al centro), e la si porta al massimo a un terzo
    /// di luce. Una copertina scura resta com'è. (Una copertina mezza bianca lasciava il testo bianco su un grigio medio.)
    nonisolated static func shade(for backdrop: NSImage) -> Double {
        let side = 40
        guard let cg = backdrop.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let ctx = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return LockModel.baseShade }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: side, height: side))
        guard let data = ctx.data else { return LockModel.baseShade }
        let pixels = data.bindMemory(to: UInt8.self, capacity: side * side * 4)
        // la prima riga dei dati è la cima dell'immagine
        func light(_ xs: ClosedRange<Double>, _ ys: ClosedRange<Double>) -> Double {
            var sum = 0.0, count = 0.0
            for y in Int(ys.lowerBound * Double(side))..<Int(ys.upperBound * Double(side)) {
                for x in Int(xs.lowerBound * Double(side))..<Int(xs.upperBound * Double(side)) {
                    let i = (y * side + x) * 4
                    sum += 0.2126 * Double(pixels[i]) + 0.7152 * Double(pixels[i + 1]) + 0.0722 * Double(pixels[i + 2])
                    count += 1
                }
            }
            return count > 0 ? sum / count / 255 : 0
        }
        // le due zone, nelle misure dello sfondo ingrandito a tutto schermo; in basso c'è già il velo, che aiuta
        let text = light(0.47...0.88, 0.37...0.69)
        let controls = light(0.36...0.64, 0.65...0.75) * 0.75
        let bright = max(text, controls)
        return min(0.74, max(LockModel.baseShade, 1 - 0.3 / max(0.01, bright)))
    }

    nonisolated static func blurred(_ image: NSImage) -> NSImage? {
        let side = 120
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let ctx = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        let w = CGFloat(cg.width), h = CGFloat(cg.height), box = CGFloat(side), scale = max(box / max(1, w), box / max(1, h))
        ctx.draw(cg, in: CGRect(x: (box - w * scale) / 2, y: (box - h * scale) / 2, width: w * scale, height: h * scale))
        guard let small = ctx.makeImage() else { return nil }
        let rect = CGRect(x: 0, y: 0, width: side, height: side)
        let ci = CIImage(cgImage: small).clampedToExtent().applyingGaussianBlur(sigma: 7)
            .applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 1.3]).cropped(to: rect)
        guard let out = CIContext().createCGImage(ci, from: rect) else { return nil }
        return NSImage(cgImage: out, size: NSSize(width: side, height: side))
    }

    /// Mentre la musica suona lo schermo bloccato resta acceso: macOS lo spegnerebbe pochi secondi dopo il blocco
    /// (visto il 18 novembre 2026). Di serie per sempre; nelle impostazioni si può scegliere dopo quanti minuti dal
    /// blocco lasciarlo spegnere, oppure «come macOS» (allora resta acceso solo a copertina aperta, che spenta non
    /// serve). In pausa, senza musica o sbloccato lo schermo torna a spegnersi quando vuole lui. A coperchio chiuso
    /// lo schermo è spento comunque: questo non tiene sveglio il Mac.
    private func updateAwakeHold() {
        let minutes = LockSettings.shared.awakeMinutes
        let within = minutes == 0 || (minutes > 0 && Date().timeIntervalSince(lockedAt) < Double(minutes) * 60)
        let want = active && !model.direct && model.present && model.playing && (minutes < 0 ? model.open : within)
        if want, awakeHold == 0 {
            var id: IOPMAssertionID = 0
            let ok = IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                                 "Charland: copertina aperta sul blocco schermo" as CFString, &id)
            if ok == kIOReturnSuccess { awakeHold = id; note("schermo tenuto acceso") }
        } else if !want, awakeHold != 0 {
            IOPMAssertionRelease(awakeHold); awakeHold = 0; note("schermo lasciato libero")
        }
    }

    // MARK: Comandi

    /// Apre o richiude la copertina: si preme la foto.
    func toggleOpen() {
        guard model.shown, model.present else { return }
        keyIdle = KeyActivity.secondsSinceLastKey
        model.open.toggle()
        if model.open {
            // col testo o senza, come dice l'impostazione; poi c'è il tasto del testo
            model.lyricsOn = LockSettings.shared.lyricsAtOpen
            Mappa.ensure(model)
            // la foto è già al suo posto quando la copertina compare: non scivola mentre sfuma
            model.textT = model.wantsColumn ? 1 : 0
            stepLive(0, snap: true)
        }
        kick()
        note(model.open ? "copertina aperta" : "copertina richiusa")
        model.hover = false
        stage?.ignoresMouseEvents = !(model.open || model.direct)
        if model.open { hit?.orderOut(nil) } else { placeHit() }
        updateAwakeHold()
    }

    /// Il tasto del testo sotto la foto: accende o spegne il testo per questa volta.
    func toggleLyrics() {
        guard model.hasText || model.lyricsPending else { return }
        model.lyricsOn.toggle()
        note(model.lyricsOn ? "testo acceso" : "testo spento")
        if model.lyricsOn { stepLive(0, snap: true) }
        kick()
    }

    func command(_ name: String) {
        NowPlayingMonitor.shared.send(name)
    }

    /// Per le prove con la musica finta: pausa o ripresa, come la manderebbe il sistema (il punto della canzone fermo
    /// dove si è fermata). Con `CHARLAND_BLOCCO_PAUSA_INDIETRO=<secondi>` il punto detto alla pausa resta indietro di
    /// tanto, come fanno certe app: la costellazione non deve tornare indietro.
    /// Per le prove: la musica finta passa a un altro brano, come col mix della modalità DJ (che spesso fa partire il
    /// brano nuovo già avanti). Il testo arriva poco dopo, come dalla rete.
    fileprivate func fakeChange(_ spec: String) {
        let parts = spec.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        guard let old = model.music else { return }
        let art = parts.count > 1 ? NSImage(contentsOfFile: parts[1]) : nil
        let lyrics = parts.count > 2 ? (try? String(contentsOfFile: parts[2], encoding: .utf8)).map { LRC.parse($0, trackDuration: 200) } : nil
        let start = parts.count > 3 ? Double(parts[3]) ?? 0 : 0
        let snapshot = NowPlayingSnapshot(title: "Notte chiara", artist: "Altri Mari", album: "Notte chiara", duration: 200, elapsed: start, anchor: Date(), rate: 1,
                                          playing: true, app: MusicApp.appleMusic, artwork: art ?? old.artwork, tint: .white)
        model.oldArtwork = old.artwork; model.oldBackdrop = model.backdrop; model.oldShade = model.shade; model.oldLights = model.lights
        model.trackT = 0
        model.music = snapshot
        makeBackdrop(snapshot.artwork, key: snapshot.trackKey)
        Mappa.ensure(model)
        incoming = nil
        model.textShown = false
        model.lyricsPending = true
        pendingSince = Date()
        note("cambio brano finto")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { [weak self] in
            guard let self, self.model.music?.trackKey == snapshot.trackKey else { return }
            self.incoming = (lyrics, 200)
            self.turnLyrics()
            self.kick()
        }
        kick()
    }

    fileprivate func fakeToggle() {
        guard var music = model.music else { return }
        let now = Date()
        music.elapsed = music.position(at: now)
        music.anchor = now
        music.playing.toggle()
        music.rate = music.playing ? 1 : 0
        if !music.playing, let back = Double(ProcessInfo.processInfo.environment["CHARLAND_BLOCCO_PAUSA_INDIETRO"] ?? "") { music.elapsed -= back }
        model.music = music
        note(music.playing ? "musica ripartita" : "musica in pausa")
        updateAwakeHold()
        kick()
    }

    /// Porta la canzone a un punto. La barra resta lì finché l'app che suona non conferma (o al massimo un secondo e mezzo).
    func seek(to seconds: Double) {
        model.seeking = seconds
        model.seekReleased = Date()
        model.seekCount &+= 1
        NowPlayingMonitor.shared.send("seek \(seconds)")
        seekTask?.cancel()
        seekTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(1500))
            // se nel frattempo si è ripresa la barra (`seekReleased` torna vuoto) la si lascia sotto il dito
            guard !Task.isCancelled, self?.model.seekReleased != nil else { return }
            self?.model.seeking = nil
        }
    }

    /// Da quando la barra risulta trascinata col tasto del mouse già su.
    private var looseSince: CFTimeInterval?

    /// Un trascinamento rimasto a metà (la finestrella tolta o la vista sparita prima del rilascio): se il tasto del mouse
    /// è su da più di 0,4 secondi senza che il rilascio sia arrivato, la barra torna all'app. Senza, testo e costellazione
    /// restavano fermi sul punto del dito finché non cambiava brano. Il margine lascia arrivare il rilascio vero.
    private func dropLooseDrag() {
        guard model.seeking != nil, model.seekReleased == nil, NSEvent.pressedMouseButtons & 1 == 0 else { looseSince = nil; return }
        let now = CACurrentMediaTime()
        guard let since = looseSince else { looseSince = now; return }
        guard now - since > 0.4 else { return }
        looseSince = nil
        model.seeking = nil
        (hit?.contentView as? LockHitView)?.endScrub()
    }

    /// L'app che suona ha preso il punto scelto con la barra lasciata: il suo punto adesso è vicino a quello che ci aspettiamo.
    private func seekTaken(_ snapshot: NowPlayingSnapshot) -> Bool {
        guard model.seekReleased != nil else { return false }
        let now = Date()
        return abs(snapshot.position(at: now) - model.position(at: now)) < 1.0
    }

    func setHover(_ hover: Bool) {
        guard model.hover != hover else { return }
        model.hover = hover
        kick()
    }

    /// La finestrella dei clic segue il lettore: fuori solo a copertina chiusa, con la musica.
    private func placeHit() {
        guard let hit, let stage, active, !model.direct else { return }
        guard model.shown, model.present, !model.open else { hit.orderOut(nil); return }
        let c = model.layout.card, f = stage.frame
        hit.setFrame(CGRect(x: f.minX + c.minX, y: f.maxY - c.maxY, width: c.width, height: c.height), display: false)
        hit.orderFrontRegardless()
    }

    // MARK: Lo spazio

    /// Il giro dello spazio c'è solo quando serve: blocco attivo, schermo acceso, musica nel lettore, opzione accesa.
    private func updateSpaceWatch() {
        let want = active && model.awake && model.present && model.music != nil && LockSettings.shared.spacePlays && !model.direct
        if want, spaceWatch == nil {
            spaceDown = CGEventSource.keyState(.combinedSessionState, key: 49)
            spaceIdle = KeyActivity.secondsSinceLastKey
            spaceWatch = Timer.scheduledTimer(withTimeInterval: 1.0 / 40, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.watchSpace() }
            }
        } else if !want, let timer = spaceWatch {
            timer.invalidate(); spaceWatch = nil
        }
    }

    /// Quaranta volte al secondo: lo spazio appena premuto mette in pausa o fa ripartire la musica. Non mentre si scrive
    /// la password: se un altro tasto è stato premuto da poco, lo spazio è parte della password e si lascia stare.
    private func watchSpace() {
        let down = CGEventSource.keyState(.combinedSessionState, key: 49)
        let idle = KeyActivity.secondsSinceLastKey
        if down, !spaceDown {
            if spaceIdle > 1.2 {
                spaceAt = Date()
                command("toggle")
                note("spazio: " + (model.playing ? "pausa" : "riprendi"))
            } else {
                note("spazio durante la scrittura: lasciato stare")
            }
        }
        spaceDown = down
        // da quanto non si premeva un tasto prima di quello di adesso: si aggiorna solo a tasti alzati
        if !down { spaceIdle = idle }
    }

    // MARK: Giro lento

    private func startTicker() {
        ticker?.invalidate()
        ticker = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    private func tick() {
        guard active, model.awake else { return }
        // i minuti scelti per lo schermo acceso possono essere passati
        updateAwakeHold()
        // al primo tasto la copertina aperta si richiude: sotto c'è il campo della password
        // (si guarda se il tempo dall'ultimo tasto è sceso, non quanto vale: un tasto può arrivare con un po' di ritardo)
        let idle = KeyActivity.secondsSinceLastKey
        // lo spazio che ha appena messo in pausa (o fatto ripartire) la musica non richiude la copertina
        let spaced = Date().timeIntervalSince(spaceAt) < 0.6 || (LockSettings.shared.spacePlays && CGEventSource.keyState(.combinedSessionState, key: 49))
        if model.open, !model.direct, idle + 0.15 < keyIdle, !spaced { note("tasto visto"); toggleOpen() }
        keyIdle = idle
        updateSpaceWatch()
        // a copertina aperta i tempi della barra compaiono quando il puntatore è sulla colonna della foto
        if model.open, !Mappa.uses, let stage {
            let p = NSEvent.mouseLocation, f = stage.frame
            let a = model.layout.art(open: true, text: model.wantsColumn)
            let zone = CGRect(x: a.minX - 20, y: a.minY - 10, width: a.width + 40, height: a.height + 210)
            let inside = zone.contains(CGPoint(x: p.x - f.minX, y: f.maxY - p.y))
            if inside != model.hover { model.hover = inside; kick() }
        }
        // un testo che non arriva: dopo un po' la foto torna al centro (se poi arriva, si rifà posto)
        if model.lyricsPending, Date().timeIntervalSince(pendingSince) > 2.5 { model.lyricsPending = false; kick() }
        if let since = pausedSince, model.present, Date().timeIntervalSince(since) > Self.pausedLinger { setPresent(false) }
        refreshSigns()
    }

    // MARK: Segni

    private func refreshSigns(force: Bool = false) {
        let now = Date()
        guard force || now.timeIntervalSince(signsAt) > 20 else { return }
        signsAt = now
        let slots = LockSettings.shared.slots
        if slots.contains(.weather) { WeatherStore.shared.ensureFresh() }
        if slots.contains(.claude) { UsageStore.shared.refresh(maxAge: UsageStore.glanceAge) }
        if slots.contains(.agenda), !agendaStarted { agendaStarted = true; AgendaStore.shared.start() }
        let signs = slots.compactMap { Self.sign($0, now: now) }
        if signs != model.signs { model.signs = signs }
    }

    /// Il segno di un posto, o niente se non c'è niente da dire (la fila resta al centro con quelli che ci sono).
    static func sign(_ kind: LockSignKind, now: Date) -> LockSign? {
        switch kind {
        case .weather:
            guard let w = WeatherStore.shared.current else { return nil }
            return LockSign(kind: kind, symbol: w.symbol, text: "\(Int(w.temperature.rounded()))°")
        case .claude:
            guard let snapshot = UsageStore.shared.snapshots[.claude],
                  let window = snapshot.windows.first(where: { $0.id == "five_hour" }) ?? snapshot.headline else { return nil }
            return LockSign(kind: kind, ring: window.percent / 100, text: "\(Int(window.percent.rounded()))%")
        case .agenda:
            guard let event = AgendaStore.shared.next(at: now) else { return nil }
            let minutes = Int((event.start.timeIntervalSince(now) / 60).rounded(.up))
            let when = event.allDay ? String(localized: "Oggi") : event.start.formatted(date: .omitted, time: .shortened)
            // sul blocco i titoli li legge chiunque passi: di serie si vede solo l'ora
            let text = LockSettings.shared.showsTitles ? event.title : when
            if minutes > 0, minutes < 60 { return LockSign(kind: kind, ring: 1 - Double(minutes) / 60, ringText: "\(minutes)", text: text) }
            return LockSign(kind: kind, symbol: "calendar", text: text)
        case .battery:
            guard let power = HomeInfo.cachedPower ?? HomeInfo.power() else { return nil }
            let step = power.level > 87 ? 100 : power.level > 62 ? 75 : power.level > 37 ? 50 : power.level > 12 ? 25 : 0
            return LockSign(kind: kind, symbol: power.charging ? "battery.100percent.bolt" : "battery.\(step)percent", text: "\(power.level)%")
        case .agent:
            let hub = AgentHub.shared
            guard hub.anyoneWorking else { return nil }
            let first = hub.sessions.values.min { $0.since < $1.since }
            let minutes = max(1, Int(now.timeIntervalSince(first?.since ?? now) / 60))
            return LockSign(kind: kind, spinning: true, text: "\(first?.kind.title ?? "AI"), \(minutes) min")
        case .none:
            return nil
        }
    }

    // MARK: Prova in finestra

    /// Il blocco in una finestra sulla scrivania, in piccolo: per guardarlo e toccarlo senza bloccare lo schermo
    /// (`Charland --blocco`). Usa la musica vera che sta suonando; il vetro vede la finestra, non il blocco vero.
    func showPreview(scale: CGFloat = 0.6) {
        guard let screen = Self.screen else { return }
        let env = ProcessInfo.processInfo.environment
        model.direct = true
        model.size = screen.frame.size
        model.notch = Self.notch(of: screen)
        // un altro schermo, per finta: `CHARLAND_BLOCCO_SCHERMO=1920x1080`
        var scale = scale
        if let other = LockChecks.screenSize(env["CHARLAND_BLOCCO_SCHERMO"]) {
            model.size = other
            model.notch = LockChecks.notch(for: other)
            scale = min(0.6, 1040 / other.width)
        }
        if let rate = Double(env["CHARLAND_BLOCCO_HZ"] ?? "") { frameRate = min(120, max(30, rate)) }
        active = true
        if let photo = env["CHARLAND_BLOCCO_OROLOGIO"] { showClockTest(photo, env: env); return }
        refreshSigns(force: true)
        // la prova del paracadute in finestra: invece di nascondere lo Space (che qui non c'è) scrive nel registro
        // quando la sentinella scatta; il thread principale si ferma come in `lock()`
        if let stall = env["CHARLAND_BLOCCO_STALLO"]?.split(separator: "|").compactMap({ Double($0) }), stall.count == 2 {
            let path = env["CHARLAND_BLOCCO_REGISTRO"]
            LockGuard.shared.arm(LockGuard.Hider {
                let line = String(format: "%.2f  paracadute scattato (sentinella)\n", Date().timeIntervalSince1970.truncatingRemainder(dividingBy: 100000))
                if let path, let handle = FileHandle(forWritingAtPath: path) { handle.seekToEndOfFile(); handle.write(Data(line.utf8)); try? handle.close() }
            })
            note("prova: paracadute armato")
            DispatchQueue.main.asyncAfter(deadline: .now() + stall[0]) { [weak self] in
                self?.note("prova: thread principale fermo per \(stall[1]) s")
                Thread.sleep(forTimeInterval: stall[1])
                self?.note("prova: thread principale ripartito (paracadute scattato: \(LockGuard.shared.didFire))")
            }
        }
        if env["CHARLAND_BLOCCO_FINTO"] == nil { NowPlayingMonitor.shared.onChange = { [weak self] in self?.musicChanged() } }
        if env["CHARLAND_BLOCCO_FINTO"] != nil {
            // dati di fantasia al posto della musica vera, per le prove e le immagini
            LockChecks.fill(model, artwork: env["CHARLAND_BLOCCO_COPERTINA"], text: env["CHARLAND_BLOCCO_FINTO"] != "senza",
                            long: env["CHARLAND_BLOCCO_FINTO"] == "lungo")
        } else { musicChanged() }
        if env["CHARLAND_BLOCCO_GIRO"] == "pausa" || env["CHARLAND_BLOCCO_GIRO"] == "lettore" {
            // «pausa»: apre la copertina e fa quello che fa una persona col lettore: il puntatore si muove (compare il
            // lettore), pausa col lettore fuori, il puntatore si muove a canzone ferma, la canzone riparte; poi richiude
            // e chiude la prova. «lettore»: copertina aperta senza lettore fino a 7 s, col lettore sempre fuori da 7 a 15
            let pause: [(Double, Int)] = [(1.6, 0), (6.0, 3), (7.2, 4), (11.0, 3), (12.4, 4), (16.0, 3), (19.5, 0), (21.5, 1)]
            let card: [(Double, Int)] = [(1.6, 0)] + stride(from: 7.0, through: 13.0, by: 1.0).map { ($0, 3) } + [(17.0, 0), (19.0, 1)]
            let steps = env["CHARLAND_BLOCCO_GIRO"] == "pausa" ? pause : card
            for (at, action) in steps {
                DispatchQueue.main.asyncAfter(deadline: .now() + at) { [weak self] in
                    guard let self else { return }
                    switch action {
                    case 0: self.toggleOpen()
                    case 3: Mappa.poke(self.model); self.note("puntatore mosso"); self.kick()
                    case 4: self.fakeToggle()
                    default: NSApp.terminate(nil)
                    }
                }
            }
        } else if env["CHARLAND_BLOCCO_GIRO"] == "aperta" {
            // apre la copertina e la lascia aperta per `CHARLAND_BLOCCO_DURATA` secondi (di serie 24), poi richiude e chiude la prova
            let hold = Double(env["CHARLAND_BLOCCO_DURATA"] ?? "") ?? 24
            // il cambio brano: `CHARLAND_BLOCCO_CAMBIO=<secondi>|<copertina>|<testo.lrc>|<da che punto parte>`
            if let change = env["CHARLAND_BLOCCO_CAMBIO"], let at = Double(change.split(separator: "|").first ?? "") {
                DispatchQueue.main.asyncAfter(deadline: .now() + at) { [weak self] in self?.fakeChange(change) }
            }
            for (at, action) in [(1.6, 0), (1.6 + hold, 0), (3.2 + hold, 1)] {
                DispatchQueue.main.asyncAfter(deadline: .now() + at) { [weak self] in
                    if action == 0 { self?.toggleOpen() } else { NSApp.terminate(nil) }
                }
            }
        } else if env["CHARLAND_BLOCCO_GIRO"] != nil {
            // un giro da solo: apre la copertina, accende il testo, lo spegne, richiude, e chiude la prova
            for (at, action) in [(2.4, 0), (4.8, 2), (8.8, 2), (10.6, 0), (12.6, 1)] {
                DispatchQueue.main.asyncAfter(deadline: .now() + at) { [weak self] in
                    switch action {
                    case 0: self?.toggleOpen()
                    case 2: self?.toggleLyrics()
                    default: NSApp.terminate(nil)
                    }
                }
            }
        }
        // a grandezza vera (`CHARLAND_BLOCCO_SCALA=1`) la prova copre lo schermo come il blocco: costa quanto costa lì
        let full = env["CHARLAND_BLOCCO_SCALA"] == "1"
        if full { scale = 1 }
        let size = CGSize(width: model.size.width * scale, height: model.size.height * scale)
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: full ? [.borderless] : [.titled, .closable, .miniaturizable],
                              backing: .buffered, defer: false)
        window.title = String(localized: "Blocco schermo (prova)")
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: LockPreview(model: model, scale: scale))
        if full { window.setFrame(screen.frame, display: false) } else { window.center() }
        // nel giro automatico la finestra non ruba la tastiera a chi sta lavorando
        if env["CHARLAND_BLOCCO_GIRO"] != nil { window.orderFrontRegardless() } else { window.makeKeyAndOrderFront(nil); NSApp.activate() }
        previewWindow = window
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { _ in
            MainActor.assumeIsolated { NSApp.terminate(nil) }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.model.shown = true; self?.kick() }
        startTicker()
    }
}

extension LockScreen {
    /// Prova dell'orologio (`CHARLAND_BLOCCO_OROLOGIO=<foto> Charland --blocco`): il nostro orologio di vetro sopra un
    /// ritaglio della foto del blocco vero, spostato in giù di `CHARLAND_BLOCCO_OROLOGIO_GIU` punti così sta sotto quello
    /// di macOS e si confrontano a occhio. La foto è a due pixel per punto e parte da `..._DX`, `..._DY` punti.
    fileprivate func showClockTest(_ photo: String, env: [String: String]) {
        guard let image = NSImage(contentsOfFile: photo), let rep = image.representations.first, let screen = Self.screen else { NSApp.terminate(nil); return }
        func number(_ key: String) -> CGFloat { CGFloat(Double(env[key] ?? "") ?? 0) }
        let size = CGSize(width: CGFloat(rep.pixelsWide) / 2, height: CGFloat(rep.pixelsHigh) / 2)
        let dx = number("CHARLAND_BLOCCO_OROLOGIO_DX"), dy = number("CHARLAND_BLOCCO_OROLOGIO_DY"), down = number("CHARLAND_BLOCCO_OROLOGIO_GIU")
        let panel = LockPanel(frame: CGRect(x: screen.frame.midX - size.width / 2, y: screen.frame.maxY - size.height - 60, width: size.width, height: size.height))
        panel.level = .floating
        let view = ZStack(alignment: .topLeading) {
            Image(nsImage: image).resizable().frame(width: size.width, height: size.height)
            LockClock(size: screen.frame.size).offset(x: -dx, y: down - dy)
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .clipped()
        .environment(\.colorScheme, .dark)
        panel.contentView = NSHostingView(rootView: view)
        panel.orderFrontRegardless()
        previewWindow = panel
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { NSApp.terminate(nil) }
    }
}

/// La scena del blocco rimpicciolita dentro una finestra, sopra un fondo scuro al posto dello sfondo del blocco.
struct LockPreview: View {
    let model: LockModel
    var scale: CGFloat

    var body: some View {
        ZStack(alignment: .topLeading) {
            LinearGradient(colors: [Color(red: 0.05, green: 0.16, blue: 0.13), Color(red: 0.02, green: 0.04, blue: 0.05), Color(red: 0.10, green: 0.28, blue: 0.22)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            // il notch e l'orologio di macOS, finti, per vedere le misure
            Rectangle().fill(.black)
                .frame(width: model.notch.width, height: model.notch.height)
                .clipShape(UnevenRoundedRectangle(bottomLeadingRadius: 13, bottomTrailingRadius: 13))
                .offset(x: model.notch.minX, y: model.notch.minY)
            // con «Mappa» l'orologio finto resta, come quello vero sul blocco: la copertina gli passa sopra
            LockClock(size: model.size, flat: true).opacity(Mappa.uses ? 1 : 1 - LockModel.ease(model.openT))
            LockStage(model: model)
        }
        .frame(width: model.size.width, height: model.size.height, alignment: .topLeading)
        .scaleEffect(scale, anchor: .topLeading)
        .frame(width: model.size.width * scale, height: model.size.height * scale, alignment: .topLeading)
        .clipped()
    }
}

// MARK: - I clic sul lettore, a copertina chiusa

/// La finestrella grande come il lettore: sa dove stanno la foto, i tre tasti e la barra, e dice a `LockScreen` cosa è stato premuto.
final class LockHitView: NSView {
    private var area: NSTrackingArea?
    private var scrubbing = false

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area { removeTrackingArea(area) }
        let fresh = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(fresh)
        area = fresh
    }

    override func mouseEntered(with event: NSEvent) { LockScreen.shared.setHover(true) }
    override func mouseExited(with event: NSEvent) { if !scrubbing { LockScreen.shared.setHover(false) } }

    /// La barra coi tempi ai lati (38 punti ciascuno): dal punto del clic al punto della canzone.
    private func scrubTime(_ x: CGFloat) -> Double {
        let duration = LockScreen.shared.model.music?.duration ?? 0
        return duration * Double(min(1, max(0, (x - 14 - 38) / (412 - 76))))
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let lock = LockScreen.shared
        if CGRect(x: 8, y: 8, width: 76, height: 76).contains(p) { lock.toggleOpen(); return }
        if p.y >= 118, p.y <= 172 {
            if p.x >= 122, p.x < 178 { lock.command("previous") }
            else if p.x >= 190, p.x < 250 { lock.command("toggle") }
            else if p.x >= 262, p.x < 318 { lock.command("next") }
            return
        }
        if p.y >= 84, p.y < 116, (lock.model.music?.duration ?? 0) > 0 {
            scrubbing = true
            lock.setHover(true)
            lock.model.seeking = scrubTime(p.x)
        }
    }

    /// Il trascinamento è finito senza rilascio (`LockScreen.dropLooseDrag`).
    func endScrub() { scrubbing = false }

    override func mouseDragged(with event: NSEvent) {
        guard scrubbing else { return }
        LockScreen.shared.model.seeking = scrubTime(convert(event.locationInWindow, from: nil).x)
    }

    override func mouseUp(with event: NSEvent) {
        guard scrubbing else { return }
        scrubbing = false
        let lock = LockScreen.shared
        if let to = lock.model.seeking { lock.seek(to: to) }
        if !bounds.contains(convert(event.locationInWindow, from: nil)) { lock.setHover(false) }
    }
}

// MARK: - Scatti fuori schermo

/// Disegna il blocco fuori schermo con dati di fantasia, per guardare le misure senza bloccare lo schermo
/// (`Charland --render-blocco <cartella> [copertina]`). Il vetro di sistema qui non si disegna.
@MainActor
enum LockChecks {
    static func render(folder: String, artwork path: String?) {
        let dir = URL(fileURLWithPath: folder)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let model = LockModel()
        model.direct = true
        // le misure di un altro schermo: `CHARLAND_BLOCCO_SCHERMO=1920x1080`
        if let other = screenSize(ProcessInfo.processInfo.environment["CHARLAND_BLOCCO_SCHERMO"]) {
            model.size = other
            model.notch = notch(for: other)
        }
        fill(model, artwork: path, text: true, rate: 0)
        let lyrics = sampleLyrics
        model.shown = true

        func shot(_ name: String, present: Bool, open: Bool, text: Bool, hover: Bool = false, lyricsOn: Bool = true, long: Bool = false, clock: Double = 0) {
            model.live.clock = clock
            let lyrics = fileLyrics ?? (long ? longLyrics : lyrics)
            model.present = present; model.open = open; model.hover = hover
            model.lyricsOn = lyricsOn; model.textShown = text; model.lyricsPending = false
            model.lyrics = text ? lyrics : nil
            model.rows = text ? lyrics.rows(trackDuration: 200) : []
            model.settle()
            Mappa.fill(model)
            Montaggio.fill(model, all: true)
            model.live.reset(rows: model.rows.count)
            // l'istante dello scatto si può scegliere: `CHARLAND_BLOCCO_ISTANTE=<secondi>`
            let instant = Double(ProcessInfo.processInfo.environment["CHARLAND_BLOCCO_ISTANTE"] ?? "") ?? (long ? 62.9 : 6.9)
            model.live.step(0, time: instant, rows: model.rows, rowFallback: 52 * model.layout.k * 1.64, snap: true)
            Mappa.place(model, at: instant)
            let view = ZStack(alignment: .topLeading) {
                LinearGradient(colors: [Color(red: 0.05, green: 0.16, blue: 0.13), Color(red: 0.02, green: 0.04, blue: 0.05), Color(red: 0.10, green: 0.28, blue: 0.22)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                LockClock(size: model.size, flat: true).opacity(open ? 0 : 1)
                fakeLogin(model.size).opacity(open ? 0 : 1)
                LockStage(model: model, offscreen: true)
            }
            .frame(width: model.size.width, height: model.size.height)
            let renderer = ImageRenderer(content: view)
            renderer.scale = 1
            guard let image = renderer.nsImage, let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
                  let data = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.86]) else { print("scatto \(name) non riuscito"); return }
            try? data.write(to: dir.appendingPathComponent(name + ".jpg"))
            print(name)
        }
        shot("1-quiete", present: false, open: false, text: false)
        shot("2-lettore", present: true, open: false, text: true)
        shot("3-lettore-puntatore", present: true, open: false, text: true, hover: true)
        shot("4-aperta-testo", present: true, open: true, text: true)
        shot("5-aperta-senza-testo", present: true, open: true, text: false)
        shot("6-aperta-testo-spento", present: true, open: true, text: true, lyricsOn: false)
        shot("7-aperta-testo-lungo", present: true, open: true, text: true, long: true)
        // le luci dell'atmosfera qualche secondo dopo: si vede di quanto si sono mosse
        shot("8-luci-dopo-12s", present: true, open: true, text: true, lyricsOn: false, clock: 12)
        shot("9-luci-dopo-24s", present: true, open: true, text: true, long: true, clock: 24)
    }

    /// Per le prove: un testo a tempo letto da un file (`CHARLAND_BLOCCO_TESTO=<file.lrc>`), al posto di quello inventato.
    static let fileLyrics: Lyrics? = ProcessInfo.processInfo.environment["CHARLAND_BLOCCO_TESTO"]
        .flatMap { try? String(contentsOfFile: $0, encoding: .utf8) }.map { LRC.parse($0, trackDuration: 200) }

    /// Testo inventato: nessun testo di canzoni vere negli scatti e nelle prove.
    static let sampleLyrics = LRC.parse("[00:01.20] Resta ancora un minuto qui\n[00:04.70] la città si spegne piano\n[00:08.20] e io conto le finestre accese\n[00:11.90] come stelle a portata di mano\n[00:19.60] Luce bianca sopra i tetti\n[00:23.60] portami dove non fa rumore", trackDuration: 200)

    /// «1920x1080» -> misure dello schermo.
    static func screenSize(_ text: String?) -> CGSize? {
        guard let parts = text?.lowercased().split(separator: "x"), parts.count == 2, let w = Double(parts[0]), let h = Double(parts[1]), w > 300, h > 300 else { return nil }
        return CGSize(width: w, height: h)
    }

    /// Un notch finto per gli schermi dei portatili (stretti e alti come quelli coi notch), niente per gli altri.
    static func notch(for size: CGSize) -> CGRect {
        let portable = size.width / size.height < 1.57 && size.width < 2100
        return CGRect(x: size.width / 2 - 102, y: portable ? 0 : -34, width: 204, height: 34)
    }

    /// L'accesso di macOS per finta (avatar, nome, riga della password), dove sta sul blocco vero secondo le misure
    /// prese a tre altezze. Serve a vedere negli scatti che il lettore non gli finisce sopra.
    static func fakeLogin(_ size: CGSize) -> some View {
        let avatar = size.height * 56 / 1107
        let top = LockLayout(size: size, notch: .zero).avatarTop
        return ZStack(alignment: .top) {
            Circle().fill(.white.opacity(0.5)).frame(width: avatar, height: avatar)
            Text(verbatim: "Carpa").font(.system(size: 13, weight: .semibold)).foregroundStyle(.white.opacity(0.7)).offset(y: avatar + 17)
            Text(verbatim: "Touch ID or Enter Password").font(.system(size: 11)).foregroundStyle(.white.opacity(0.45)).offset(y: avatar + 49)
        }
        .frame(width: size.width, alignment: .top)
        .offset(y: top)
        .allowsHitTesting(false)
    }

    /// Lo stesso testo inventato ripetuto per una cinquantina di righe: un brano vero è lungo così, e certi difetti
    /// (la maschera della colonna che si allungava su tutto il testo e spegneva la riga cantata) si vedono solo così.
    static let longLyrics: Lyrics = {
        let lines = ["Resta ancora un minuto qui", "la città si spegne piano", "e io conto le finestre accese",
                     "come stelle a portata di mano", "Luce bianca sopra i tetti", "portami dove non fa rumore"]
        var text: [String] = []
        for i in 0..<48 {
            let seconds = i * 4
            let stamp = String(format: "[%02d:%02d.20] ", seconds / 60, seconds % 60)
            text.append(stamp + lines[i % lines.count])
        }
        return LRC.parse(text.joined(separator: "\n"), trackDuration: 200)
    }()

    /// Riempie il modello con dati di fantasia: un brano inventato, la sua copertina, i quattro segni.
    static func fill(_ model: LockModel, artwork path: String?, text: Bool, rate: Double = 1, long: Bool = false) {
        let sampleLyrics = fileLyrics ?? (long ? longLyrics : sampleLyrics)
        let art = path.flatMap { NSImage(contentsOfFile: $0) } ?? sampleArt()
        // la musica finta parte da `CHARLAND_BLOCCO_ISTANTE` secondi, se c'è
        let start = rate == 0 ? 6.9 : Double(ProcessInfo.processInfo.environment["CHARLAND_BLOCCO_ISTANTE"] ?? "") ?? 0.4
        model.music = NowPlayingSnapshot(title: "Luce bianca", artist: "Le Onde", album: "Luce bianca", duration: 200, elapsed: start, anchor: Date(), rate: rate,
                                         playing: true, app: MusicApp.appleMusic, artwork: art, tint: .white)
        model.backdrop = LockScreen.blurred(art)
        model.shade = model.backdrop.map { LockScreen.shade(for: $0) } ?? LockModel.baseShade
        model.lights = LockLights.lights(for: LockLights.palette(for: art))
        model.lyrics = text ? sampleLyrics : nil
        model.rows = text ? sampleLyrics.rows(trackDuration: 200) : []
        model.textShown = text
        model.signs = [LockSign(kind: .weather, symbol: "cloud.sun.fill", text: "12°"), LockSign(kind: .claude, ring: 0.64, text: "64%"),
                       LockSign(kind: .agenda, ring: 0.78, ringText: "13", text: "14:30"), LockSign(kind: .battery, symbol: "battery.75percent", text: "82%")]
        model.present = true
        Mappa.fill(model)
        Montaggio.fill(model)
    }

    /// La copertina finta: disegnata una volta sola in un'immagine di pixel, come le copertine vere. Prima era un disegno
    /// che macOS rifaceva a ogni misura nuova (`NSImage(size:flipped:drawingHandler:)`): mentre la copertina cresceva lo
    /// rifaceva a ogni fotogramma sul thread principale, e nelle prove l'apertura e la chiusura sembravano a scatti
    /// (fotogrammi da 55 a 86 ms) che con una copertina vera non ci sono (19 novembre 2026, misurato).
    private static func sampleArt() -> NSImage {
        let side = 600
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8, samplesPerPixel: 4,
                                         hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: rep) else { return NSImage(size: NSSize(width: side, height: side)) }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        NSGradient(colors: [NSColor(red: 0.95, green: 0.2, blue: 0.16, alpha: 1), NSColor(red: 0.25, green: 0.02, blue: 0.04, alpha: 1)])?
            .draw(in: NSRect(x: 0, y: 0, width: side, height: side), angle: -60)
        NSGraphicsContext.restoreGraphicsState()
        let image = NSImage(size: NSSize(width: side, height: side))
        image.addRepresentation(rep)
        return image
    }
}
