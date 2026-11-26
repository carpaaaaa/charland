import AppKit
import CharlandCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static var shared: AppDelegate?

    var demoScene: String?
    var snapshotFolder: String?
    var reportPath: String?
    var stay = false
    var simulateNotchless = false
    var benchReport: String?
    var importOpenWhispr = false
    var dictateFiles: [String] = []
    /// Solo i servizi, senza finestra: per le prove da terminale.
    var serveOnly = false
    /// Solo i widget accanto al Dock, senza isola: per provarli mentre gira la Charland installata.
    var dockOnly = false
    /// Solo il blocco schermo, in una finestra di prova (`--blocco`).
    var lockOnly = false
    /// Solo la farfalla e lo storico degli appunti, senza isola: per provarli mentre gira la Charland installata.
    var clipboardOnly = false
    /// Solo la barra di ricerca (`--ricerca`), senza isola: per provarla accanto alla Charland installata.
    var searchOnly = false
    /// Solo l'osservatore delle sessioni di Claude, senza isola: per provare chi risulta al lavoro accanto alla Charland
    /// installata (`CHARLAND_TRACE=1 Charland --agenti`, con `CHARLAND_CLAUDE_PROJECTS` per una cartella di prova).
    var agentsOnly = false
    /// Solo la sezione Voce delle impostazioni in una finestra, senza isola e senza servizi: per guardarla.
    var voiceOnly = false
    /// Le impostazioni aperte su una sezione, in primo piano, senza isola e senza servizi: per guardarle
    /// come le vede chi le usa (`--sezione general`).
    var settingsSection: String?

    /// Le prove da terminale: niente Dock, niente finestra alla riapertura. `--serve` non è una prova: è Charland
    /// vera riaccesa senza aprire la finestra. Prima contava qui, e l'app girava senza icona nel Dock: la finestra
    /// delle impostazioni non diventava mai attiva, con interruttori e selezione grigi invece che nel colore
    /// dell'accento (carpa, 17 novembre 2026).
    private var isScripted: Bool { lockOnly || dockOnly || clipboardOnly || searchOnly || agentsOnly || voiceOnly || settingsSection != nil || demoScene != nil || snapshotFolder != nil || benchReport != nil || importOpenWhispr || !dictateFiles.isEmpty }

    private var terminationSource: DispatchSourceSignal?

    /// Chiusa dal terminale (pkill, l'installazione di una versione nuova): si chiude bene,
    /// come da menu, così non sembra un crash e nessuna funzione si spegne per prudenza.
    private func handleTerminationSignal() {
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler { NSApp.terminate(nil) }
        source.resume()
        terminationSource = source
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        handleTerminationSignal()
        // Nelle scene dimostrative l'app non compare nel Dock né nella barra dei menu:
        // il video resta pulito.
        NSApp.setActivationPolicy(isScripted ? .accessory : .regular)
        // Senza menu Modifica nessun campo di testo riceve ⌘V, ⌘C, ⌘A: vale anche per le finestre di prova.
        MainMenu.install()
        Thrift.apply()
        if clipboardOnly {
            ClipboardTest.start()
            return
        }
        if searchOnly {
            SearchTest.start()
            return
        }
        if agentsOnly {
            AgentWatchers.claude.start()
            // Anche lo stato delle sessioni: con `CHARLAND_TRACE` si legge cosa uscirebbe nell'isola come domanda.
            AgentWatchers.claudeSessions.start()
            return
        }
        if lockOnly {
            // il blocco schermo in una finestra, con la musica vera: si guarda e si tocca senza bloccare lo schermo
            NowPlayingMonitor.shared.start()
            // `--blocco vero`: solo il blocco schermo, quello vero (aspetta che lo schermo si blocchi), senza il resto dell'app
            if CommandLine.arguments.contains("vero") { LockScreen.shared.start() } else { LockScreen.shared.showPreview() }
            return
        }
        if dockOnly {
            DockBar.shared.start()
            if CommandLine.arguments.contains("--impostazioni") { DockChecks.showPane() }
            // Per le immagini (`CHARLAND_DOCK_DEMO=1`): dati di fantasia al posto dei tuoi, riapplicati ogni secondo
            // perché le letture vere non li coprano.
            if ProcessInfo.processInfo.environment["CHARLAND_DOCK_DEMO"] != nil {
                Task {
                    for _ in 0..<90 {
                        DockChecks.useSamples(now: Date())
                        try? await Task.sleep(for: .seconds(1))
                    }
                }
            }
            return
        }
        if voiceOnly {
            DictationSetup.showPane()
            return
        }
        if let name = settingsSection {
            NSApp.setActivationPolicy(ProcessInfo.processInfo.environment["CHARLAND_POLITICA"] == "accessory" ? .accessory : .regular)
            AppServices.shared.showSettings(section: SettingsSection(rawValue: name) ?? .general)
            return
        }
        let hub = IslandHub.shared
        hub.simulateNotchless = simulateNotchless
        hub.start()
        // Simboli, caratteri e viste dell'isola pronti prima della prima apertura.
        if snapshotFolder == nil, benchReport == nil, dictateFiles.isEmpty, !importOpenWhispr { IslandWarmup.run() }

        if importOpenWhispr {
            do {
                try OpenWhisprImport.importModel()
                print("Orukeet importato in \(ModelStore.folder(.orukeet).path)")
                print("Impostazioni di OpenWhispr: \(OpenWhisprImport.readSettings())")
            } catch {
                print("Importazione fallita: \(error)")
            }
            NSApp.terminate(nil)
        } else if !dictateFiles.isEmpty {
            Task {
                print("modello di Apple disponibile:", ModelCleaner.isAvailable)
                for path in dictateFiles {
                    for cleanup in [false, true] {
                        guard let r = await DictationController.shared.runFile(URL(fileURLWithPath: path), cleanup: cleanup) else {
                            print("fallita: \(path) \(DictationController.shared.lastError ?? "")")
                            continue
                        }
                        print(String(format: "%@ | audio %.1f s | motore %.0f ms | pulizia %.0f ms (%@) | totale %.0f ms",
                                     cleanup ? "con pulizia" : "senza pulizia", r.audioSeconds, r.transcribeSeconds * 1000,
                                     r.cleanSeconds * 1000, r.cleanupSource.rawValue, r.totalSeconds * 1000))
                        print("   grezzo: \(r.raw)")
                        print("   finale: \(r.text)")
                    }
                }
                NSApp.terminate(nil)
            }
        } else if let benchReport {
            Task { await VoiceBench.run(report: benchReport); NSApp.terminate(nil) }
        } else if let folder = snapshotFolder {
            Task { await Snapshots.run(folder: folder); NSApp.terminate(nil) }
        } else if let scene = demoScene {
            Task { await runDemo(scene) }
        } else {
            // La finestra si apre al primo avvio o quando apri Charland tu; al login no:
            // l'isola c'è già, e una finestra a ogni accensione sarebbe solo d'intralcio.
            let firstRun = !UserDefaults.standard.bool(forKey: "settingsShownOnce")
            let showWindow = !serveOnly && (firstRun || !Self.launchedAtLogin)
            if showWindow { UserDefaults.standard.set(true, forKey: "settingsShownOnce") }
            LegacyCleanup.run()
            Updates.shared.start()
            AppServices.shared.start(showWindow: showWindow)
        }
    }

    /// Aperta dal sistema all'accensione, come elemento di login.
    static var launchedAtLogin: Bool {
        guard let event = NSAppleEventManager.shared().currentAppleEvent,
              event.eventID == AEEventID(kAEOpenApplication) else { return false }
        return event.paramDescriptor(forKeyword: AEKeyword(keyAEPropData))?.enumCodeValue == OSType(keyAELaunchedAsLogInItem)
    }

    private func runDemo(_ scene: String) async {
        guard let island = IslandHub.shared.primary else { NSApp.terminate(nil); return }
        // Anche durante le scene il puntatore apre l'isola: chi guarda può provarla.
        let pointer = PointerTracker(hub: .shared)
        pointer.start()
        defer { pointer.stop() }
        let recorder = MotionRecorder()
        island.engine.recorder = recorder
        island.engine.resetStats()
        let director = DemoDirector(island: island)
        if let hold = ProcessInfo.processInfo.environment["CHARLAND_HOLD"].flatMap(Double.init) { director.hold = hold }
        // Un fondo di prova sotto l'isola, per giudicare il vetro su colori veri.
        var backdrop: NSWindow?
        if let path = ProcessInfo.processInfo.environment["CHARLAND_BACKDROP"], let image = NSImage(contentsOfFile: path) {
            backdrop = DemoBackdrop.show(image: image, on: island.geometry.frame)
            try? await Task.sleep(for: .seconds(0.6))
        }
        defer { backdrop?.orderOut(nil) }
        await director.play(scene)
        if let reportPath {
            Report.write(to: reportPath, scene: scene, engine: island.engine, recorder: recorder)
        }
        if !stay { NSApp.terminate(nil) }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !isScripted { AppServices.shared.showSettings() }
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        AppServices.shared.stop()
        IslandHub.shared.stop()
    }
}

/// I numeri di una scena: fotogrammi, ritardi, costo del contorno, difetti del movimento.
enum Report {
    @MainActor
    static func write(to path: String, scene: String, engine: IslandEngine, recorder: MotionRecorder) {
        let stats = engine.stats
        let findings = recorder.findings()
        var lines: [String] = []
        lines.append("scena: \(scene)")
        lines.append("fotogrammi: \(stats.frames)")
        lines.append("fotogrammi in ritardo: \(stats.late)")
        lines.append("disegni: \(stats.publishes), chiamate doppie saltate: \(stats.skipped), campioni: \(recorder.samples.count)")
        for moment in stats.lateMoments { lines.append("  in ritardo: " + moment) }
        lines.append(String(format: "intervallo peggiore: %.1f ms", stats.worstInterval * 1000))
        lines.append(String(format: "contorno, media per fotogramma: %.2f ms", stats.frames > 0 ? stats.traceSeconds / Double(stats.frames) * 1000 : 0))
        lines.append("difetti del movimento: \(findings.count)")
        for f in findings { lines.append("  " + f.description) }
        try? lines.joined(separator: "\n").appending("\n").write(toFile: path, atomically: true, encoding: .utf8)
    }
}
