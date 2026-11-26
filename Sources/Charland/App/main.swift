import AppKit
import SwiftUI
import CharlandCore

// Charland: l'isola dinamica per i Mac con il notch.
//
// Opzioni da terminale:
//   --demo <scena>        recita una scena con dati finti (giro, stati, gocce, volume, voce, agente, varianti)
//   --selftest            prova il movimento senza schermo ed esce con 0 se è tutto a posto
//   --official            dice se è la build ufficiale (aggiornamenti automatici accesi) o una build di sviluppo
//   --snapshot <cartella> fotografa ogni stato dell'isola in una cartella
//   --render <cartella>   disegna ogni stato fuori schermo (senza il vetro di sistema)
//   --bench-voice <file>  confronta il motore vocale con quello di OpenWhispr e scrive il risultato
//   --dictate-file <file> fa passare file audio dalla catena della dettatura e stampa testo e tempi
//   --import-openwhispr   copia il modello Orukeet già scaricato da OpenWhispr
//   --serve               accende i servizi senza aprire la finestra
//   --dock                accende solo i widget accanto al Dock, senza isola (con --impostazioni apre la sezione Dock)
//   --appunti            accende solo la farfalla e lo storico degli appunti, senza isola
//   --agenti             accende solo l'osservatore delle sessioni di Claude, senza isola (con CHARLAND_TRACE=1 dice chi lavora)
//   --voce                apre solo la sezione Voce delle impostazioni, senza isola e senza servizi
//   --sezione <nome>      apre le impostazioni su una sezione (general, appearance, voice…), senza isola né servizi
//   --usage               stampa l'utilizzo degli agenti AI letto sul Mac (con `vivo` lo chiede ai loro comandi)
//   --render-dock <cart.> disegna vassoio e cassetto fuori schermo (senza il vetro di sistema)
//   --render-righello <c.> disegna il righello della giornata fuori schermo, con una giornata inventata
//   --render-blocco <cart.> [--copertina <file>] disegna il blocco schermo fuori schermo con dati di fantasia
//   --prova-scena         prova fuori schermo che la scena del blocco segua il brano e la sua copertina
//   --blocco              il blocco schermo in una finestra di prova, con la musica vera
//   --permessi            stampa i permessi che macOS dà a questa copia e a quale app li attribuisce
//   --notchless           finge un Mac senza notch
//   --look nero|vetro     sceglie l'aspetto per questa esecuzione
//   --stay                dopo la scena resta aperta

let arguments = CommandLine.arguments
func option(_ name: String) -> String? {
    guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else { return nil }
    return arguments[index + 1]
}

if arguments.contains("--selftest") {
    exit(SelfTest.run() ? 0 : 1)
}

if arguments.contains("--official") {
    // Che build è: «official» (aggiornamenti automatici accesi, quella firmata dal maintainer) o «development».
    #if CHARLAND_OFFICIAL
    print("official")
    #else
    print("development")
    #endif
    exit(0)
}

if let index = arguments.firstIndex(of: "--explain") {
    // Prova la spiegazione dei comandi con il modello di Apple.
    let commands = Array(arguments[(index + 1)...])
    let done = DispatchSemaphore(value: 0)
    Task.detached {
        for command in commands {
            let start = Date()
            let text = await CommandExplainer.explain(command, budget: 6)
            print(String(format: "%.0f ms | %@\n   %@", Date().timeIntervalSince(start) * 1000, command, text ?? "(nessuna spiegazione)"))
        }
        done.signal()
    }
    done.wait()
    exit(0)
}

if let out = option("--render-guide") {
    // La guida dell'aiutante disegnata fuori schermo, per controllare testi e a capo.
    MainActor.assumeIsolated {
        let view = HelperGuide(status: .requiresApproval) {}
            .padding(20).frame(width: 520).background(Color(nsColor: .windowBackgroundColor))
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        if let image = renderer.nsImage, let tiff = image.tiffRepresentation,
           let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: out))
            print("guida:", out)
        }
    }
    exit(0)
}

if CommandLine.arguments.contains("--helper-register") {
    // Registra l'aiutante (come fa l'app la prima volta che serve) e dice lo stato: di solito «da approvare».
    print("aiutante:", PrivilegedHelper.describe(PrivilegedHelper.ensureRegistered()))
    exit(0)
}

if CommandLine.arguments.contains("--helper-status") {
    // Lo stato dell'aiutante di sistema del coperchio chiuso: registrato, da approvare, attivo.
    print("aiutante:", PrivilegedHelper.describe(PrivilegedHelper.service.status))
    exit(0)
}

if CommandLine.arguments.contains("--helper-repair") || CommandLine.arguments.contains("--helper-repair-force") {
    // Se l'aiutante è approvato ma launchd non lo ha (succede dopo ogni installazione), lo rimette a posto e dice
    // passo per passo cosa ha fatto. È la stessa riparazione che Charland fa da sola all'avvio.
    let done = DispatchSemaphore(value: 0)
    Task.detached {
        let force = CommandLine.arguments.contains("--helper-repair-force")
        _ = await PrivilegedHelper.repair(force: force) { print("aiutante:", $0); fflush(stdout) }
        done.signal()
    }
    done.wait()
    exit(0)
}

if CommandLine.arguments.contains("--claude-awake") {
    // Il «Keep awake» dell'app di Claude è acceso in questo momento?
    print("keep awake di Claude:", ClaudeAwake.isHeld() ? "acceso" : "spento")
    exit(0)
}

if let ask = option("--trova-in-claude") {
    // Per le prove: la risposta di un riquadro di fine turno si troverebbe nella finestra di Claude com'è adesso, anche
    // se sta su un'altra scrivania? `--trova-in-claude <domanda> <pulsante> [conversazione]`: con la conversazione dice
    // anche se la sua riga si vede nella barra laterale o sta in un gruppo chiuso. Non preme niente.
    let rest = Array(arguments.drop { $0 != ask }.dropFirst())
    print(ClaudeWindow.probe(label: rest.first ?? "", ask: ask, conversation: rest.count > 1 ? rest[1] : nil))
    exit(0)
}

// Le prove che agiscono con i permessi di Charland (premere in Claude, scrivere i ganci, portare davanti un'app)
// esistono solo nelle build di debug: in Release un altro processo non deve poterle usare.
#if DEBUG
if let ask = option("--premi-in-claude") {
    // Per le prove: preme davvero la risposta di un riquadro di fine turno nella finestra di Claude, come un tocco
    // nell'isola. `--premi-in-claude <domanda> <pulsante> <conversazione> <sessione>`. Manda una risposta vera.
    let rest = Array(arguments.drop { $0 != ask }.dropFirst())
    guard rest.count >= 3 else { print("servono domanda, pulsante, conversazione e sessione"); exit(2) }
    let sent = ClaudeWindow.pressForTest(label: rest[0], ask: ask, conversation: rest[1], session: rest[2])
    print(sent ? "arrivata: la sessione ha ripreso" : "non arrivata (dettagli in \(CharlandPathsLog.url.path))")
    exit(sent ? 0 : 1)
}
#endif

if arguments.contains("--ganci") {
    // Il collegamento con Claude Code, come dalla scheda Agenti: da solo dice lo stato e le righe che cambierebbero;
    // «collega» e «scollega» scrivono (con la copia del file com'era accanto).
    let state = AgentLink.read()
    if state == .unreadable {
        print("il file delle impostazioni di Claude Code c'è ma non si legge: non lo tocco |", AgentLink.settingsURL.path)
        exit(1)
    }
    let old = state.text
    let connected = AgentConfig.isConnected(existing: old)
    let repair = AgentConfig.needsRepair(existing: old, cliPath: AgentLink.cliPath)
    print("ganci:", connected ? (repair ? "collegati, da aggiornare" : "collegati") : "non collegati", "|", AgentLink.settingsURL.path)
    let disconnect = arguments.contains("scollega")
    do {
        let new = disconnect ? try AgentConfig.disconnect(existing: old) : try AgentConfig.connect(existing: old, cliPath: AgentLink.cliPath)
        for line in AgentConfig.diff(old: old, new: new) { print(line) }
        #if DEBUG
        if arguments.contains("collega") || disconnect {
            try AgentLink.write(new)
            print(disconnect ? "scollegati" : "collegati")
        }
        #endif
    } catch {
        print("il file delle impostazioni di Claude Code non si legge: non lo tocco")
        exit(1)
    }
    exit(0)
}

if arguments.contains("--usage") {
    exit(MainActor.assumeIsolated { DockChecks.printUsage(live: arguments.contains("vivo")) } ? 0 : 1)
}

#if DEBUG
if let bundle = option("--davanti") {
    // Per le prove: porta davanti un'app accesa come fa la mascotte (anche nascosta o ridotta nel Dock), `AppFront`.
    MainActor.assumeIsolated {
        _ = NSApplication.shared
        if let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundle).first {
            AppFront.bring(app)
            RunLoop.main.run(until: Date().addingTimeInterval(1.5))
            print("fatto")
        } else {
            print("non è accesa")
        }
    }
    exit(0)
}
#endif

if let session = option("--dove-agente") {
    // Per le prove: dove porterebbe la mascotte di una sessione di Claude (`AgentFocus`).
    let rest = arguments.drop { $0 != session }.dropFirst().first.flatMap { $0.hasPrefix("--") ? nil : $0 }
    print(AgentFocus.describe(sessionID: session, folder: rest))
    exit(0)
}

if arguments.contains("--permessi") {
    MainActor.assumeIsolated { DockChecks.printPermissions() }
    exit(0)
}

if arguments.contains("--prova-scena") {
    // La scena del blocco schermo segue il brano e la sua copertina (`LockChecks.sceneCheck`): fuori schermo, senza
    // musica vera; esce con 0 se è tutto a posto.
    Task { @MainActor in exit(await LockChecks.sceneCheck() ? 0 : 1) }
    RunLoop.main.run()
}

if let folder = option("--render-blocco") {
    MainActor.assumeIsolated {
        _ = NSApplication.shared
        LockChecks.render(folder: folder, artwork: option("--copertina"))
    }
    exit(0)
}

if arguments.contains("--prova-tenda") {
    // La tenda dello sfondo sopra la ripartenza di WallpaperAgent (`WallpaperChecks.curtainTest`).
    MainActor.assumeIsolated {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        Task { @MainActor in
            await WallpaperChecks.curtainTest()
            exit(0)
        }
        app.run()
    }
}

if arguments.contains("--prova-registro") {
    // Lo sfondo su tutte le scrivanie contro registri di WallpaperAgent finti (`WallpaperChecks.registryTest`).
    exit(WallpaperChecks.registryTest() ? 0 : 1)
}

if let out = option("--render-sfondo") {
    // Lo sfondo di Charland (Impostazioni › Sfondo) in un PNG, senza toccare la scrivania (`WallpaperChecks`).
    exit(WallpaperChecks.render(to: out) ? 0 : 1)
}

if let folder = option("--render-dock") {
    MainActor.assumeIsolated {
        _ = NSApplication.shared
        DockChecks.render(folder: folder)
    }
    exit(0)
}

if let folder = option("--render-righello") {
    // Il righello della giornata con una giornata inventata, fuori schermo (`DayRulerChecks`).
    MainActor.assumeIsolated {
        _ = NSApplication.shared
        DayRulerChecks.render(folder: folder)
    }
    exit(0)
}

if arguments.contains("--side-check") {
    // La goccia dello slider: la fascia stretta del contorno deve dare lo stesso bordo della griglia intera.
    exit(MainActor.assumeIsolated { SideSliderCheck.run() } ? 0 : 1)
}

if arguments.contains("--levels") {
    // Legge volume e luminosità senza cambiarli: prova che le due strade funzionano su questo Mac.
    print("volume:", SystemVolume.level.map { String(format: "%.3f", $0) } ?? "non letto", "| muto:", SystemVolume.muted)
    print("luminosità:", SystemBrightness.level.map { String(format: "%.3f", $0) } ?? "non letta")
    exit(0)
}

if let folder = option("--render") {
    // Scatti fuori schermo: non serve nemmeno accendere l'app.
    MainActor.assumeIsolated {
        _ = NSApplication.shared
        if let look = option("--look") { Appearance.shared.look = look == "nero" ? .black : .blackGlass }
        Snapshots.render(folder: folder, metrics: arguments.contains("--notchless") ? .notchless(screenWidth: 1710) : .air15)
    }
    exit(0)
}

MainActor.assumeIsolated {
    // Niente ripristino delle finestre. Dopo un crash macOS chiede «riaprire le finestre?» con un avviso modale che
    // arriva prima di applicationDidFinishLaunching: finché nessuno lo clicca l'isola, la dettatura e i servizi non
    // partono, e un'app che vive nel notch quell'avviso spesso non lo fa nemmeno vedere (19 novembre 2026, dopo un
    // crash di prova: Charland ferma con l'avviso aperto dietro un video a tutto schermo). Charland non ha finestre da
    // ripristinare: le apre da sé. Va scritto prima di NSApplication.run, che legge la preferenza all'avvio.
    UserDefaults.standard.set(true, forKey: "ApplePersistenceIgnoreState")
    let app = NSApplication.shared
    let delegate = AppDelegate()
    delegate.serveOnly = arguments.contains("--serve")
    delegate.demoScene = option("--demo")
    delegate.snapshotFolder = option("--snapshot")
    delegate.stay = arguments.contains("--stay")
    delegate.simulateNotchless = arguments.contains("--notchless")
    delegate.reportPath = option("--report")
    delegate.benchReport = option("--bench-voice")
    delegate.importOpenWhispr = arguments.contains("--import-openwhispr")
    delegate.dockOnly = arguments.contains("--dock")
    delegate.lockOnly = arguments.contains("--blocco")
    delegate.clipboardOnly = arguments.contains("--appunti")
    delegate.agentsOnly = arguments.contains("--agenti")
    delegate.voiceOnly = arguments.contains("--voce")
    delegate.settingsSection = option("--sezione")
    if let index = arguments.firstIndex(of: "--dictate-file") {
        delegate.dictateFiles = Array(arguments[(index + 1)...]).filter { !$0.hasPrefix("--") }
    }
    if let look = option("--look") {
        Appearance.shared.look = look == "nero" ? .black : .blackGlass
    }
    app.delegate = delegate
    // Tenuto vivo per tutta la vita dell'app.
    AppDelegate.shared = delegate
    app.run()
}
