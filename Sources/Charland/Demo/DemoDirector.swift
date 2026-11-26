import AppKit
import AVFoundation
import SwiftUI
import CharlandCore
import CharlandKit

/// La regia: recita le scene dell'isola con dati finti, senza toccare dati veri.
/// Serve a provare il movimento e a registrare il video di lancio.
@MainActor
final class DemoDirector {
    let island: IslandController
    private var smoother = LevelSmoother()

    /// Quanto restano aperte le scene ferme (casa, musica).
    var hold: Double = 4

    init(island: IslandController) {
        self.island = island
    }

    static let scenes = ["giro", "stati", "gocce", "volume", "voce", "agente", "varianti", "casa", "musica", "claude", "sistema", "filo", "agenti", "vassoio", "risparmio", "inriproduzione", "dalvivo", "tre", "concentrazione"]

    private var engine: IslandEngine { island.engine }

    private let music = IslandActivity(id: "musica", priority: 1, leadingWidth: 26, trailingWidth: 26,
                                       expandedWidth: 320, expandedHeight: 104)
    private let timer = IslandActivity(id: "timer", priority: 0, leadingWidth: 22, trailingWidth: 44,
                                       expandedWidth: 300, expandedHeight: 96)
    private let agent = IslandActivity(id: "agente", priority: 5, leadingWidth: 22, trailingWidth: 26,
                                       expandedWidth: 372, expandedHeight: 138)

    private var song: MusicInfo {
        MusicInfo(title: "White Light", artist: "Marlo Vey", elapsed: 62, duration: 200, isPlaying: true,
                  tintA: Color(red: 0.86, green: 0.12, blue: 0.18), tintB: Color(red: 0.10, green: 0.04, blue: 0.08))
    }

    func play(_ scene: String) async {
        switch scene {
        case "stati": await states()
        case "gocce": await drops()
        case "volume": await sliders()
        case "voce": await voice(style: Appearance.shared.dictationStyle)
        case "varianti": await variants()
        case "agente": await agentScene()
        case "casa":
            island.engine.refreshHome(.home(HomeInfo.now()))
            island.engine.send(.expand(id: nil))
            await pause(hold)
            island.engine.send(.collapse)
            await pause(1)
        case "claude":
            var m = ActivityMessage(op: .upsert, client: "claude-code", id: "demo")
            m.template = .status
            m.title = "charland"
            m.status = "working"
            m.startedAt = Date().timeIntervalSince1970 - 74
            _ = ActivityCenter.shared.handle(m, from: nil)
            await pause(hold)
            if ProcessInfo.processInfo.environment["CHARLAND_EXPAND"] != nil {
                engine.send(.expand(id: "claude-code/demo"))
                await pause(hold)
            }
            m.status = "done"
            m.alert = .init(haptic: "done")
            m.ttl = 3
            _ = ActivityCenter.shared.handle(m, from: nil)
            await pause(3.5)
        case "dalvivo":
            // il testo dal vivo con il microfono finto (CHARLAND_MICROFONO_FINTO): si annulla alla fine, niente
            // viene scritto nell'app in primo piano
            DictationController.shared.start()
            DictationController.shared.startHandsFreeFromIsland()
            await pause(hold)
            // con CHARLAND_NON_SCRIVERE si arriva fino alla goccia che cola, senza scrivere niente; se no si annulla
            if ProcessInfo.processInfo.environment["CHARLAND_NON_SCRIVERE"] != nil {
                DictationController.shared.stopFromIsland()
                await pause(3)
            } else {
                DictationController.shared.cancel()
                await pause(1)
            }
        case "inriproduzione":
            // la musica vera di questo Mac (se qualcosa suona): compatta, aperta, pausa e play dall'isola
            NowPlayingMonitor.shared.start()
            await pause(2.5)
            engine.send(.expand(id: NowPlayingMonitor.activityID))
            await pause(hold)
            IslandActions.handle(action: "music:toggle", activity: NowPlayingMonitor.activityID)
            await pause(1.5)
            IslandActions.handle(action: "music:toggle", activity: NowPlayingMonitor.activityID)
            await pause(1.5)
            engine.send(.collapse)
            await pause(1.5)
            NowPlayingMonitor.shared.stop()
        case "risparmio":
            LowPowerMonitor.announce()
            await pause(4)
        case "concentrazione":
            // La Concentrazione senza toccare quella vera: Non disturbare si accende, l'avviso se ne va; si spegne; poi
            // accesa e spenta mentre è ancora nell'isola (la falce cala da dov'è). `CHARLAND_CONCENTRAZIONE=sonno` prova
            // il Sonno, `=nessuno` la Concentrazione di cui non si sa il nome.
            let which = ProcessInfo.processInfo.environment["CHARLAND_CONCENTRAZIONE"]
            let name: String? = which == "sonno" ? FocusNames.sleep : which == "nessuno" ? nil : FocusNames.doNotDisturb
            FocusMonitor.announce(on: true, name: name)
            await pause(4)
            FocusMonitor.announce(on: false, name: name)
            await pause(3.5)
            FocusMonitor.announce(on: true, name: name)
            await pause(1.1)
            FocusMonitor.announce(on: false, name: name)
            await pause(3.5)
        case "vassoio":
            // un file che arriva nel vassoio: zona di rilascio, file sopra la zona, rilascio, scheda che entra.
            // Il file di prova si toglie alla fine: il vassoio è lo stesso dell'app vera.
            let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("Prova del vassoio.pdf")
            FileManager.default.createFile(atPath: url.path, contents: Data("%PDF-1.4\n".utf8))
            island.beginDropMode()
            await pause(1.2)
            TrayStore.shared.targeted = true
            await pause(0.8)
            TrayStore.shared.add([url])
            island.endDropMode(dropped: true)
            await pause(hold)
            engine.send(.collapse)
            await pause(1.2)
            if let item = TrayStore.shared.items.first(where: { $0.path == url.path }) { TrayStore.shared.remove(item) }
            try? FileManager.default.removeItem(at: url)
        case "agenti":
            // gli agenti come arrivano dai registri veri: compatta, aperta (tempo grande e righe senza mascotte),
            // poi la casa con la pillola, dove la mascotte continua a lavorare
            AgentHub.shared.working("demo-claude", kind: .claude, project: "charland", since: Date().addingTimeInterval(-74))
            await pause(2)
            engine.send(.expand(id: AgentHub.activityID))
            await pause(hold)
            engine.send(.collapse)
            await pause(1.2)
            engine.refreshHome(.home(HomeInfo.now()))
            engine.send(.expand(id: nil))
            await pause(hold)
            engine.send(.collapse)
            await pause(1)
            AgentHub.shared.finished("demo-claude", duration: 1)
            await pause(1.5)
        case "filo":
            // il gesto di Filo sulla farfalla nella barra dei menu: il timer vola nell'isola
            MenuBarItem.shared.setShown(true)
            await pause(1)
            await MenuBarItem.shared.rehearse()
            await pause(hold)
            engine.send(.expand(id: nil))
            await pause(hold)
            engine.send(.collapse)
            await pause(1.5)
        case "sistema":
            TimerCenter.shared.start(seconds: 6, title: "Pasta")
            await pause(1.5)
            engine.send(.expand(id: nil))
            await pause(2)
            engine.send(.collapse)
            await pause(4)
            var battery = SystemActivity.message(BatteryMonitor.activityID, template: .status, title: "Batteria al 20%")
            battery.symbol = "battery.25percent"
            battery.tint = "orange"
            battery.slots = ["trailing": .init(text: "20%")]
            battery.subtitle = "Collega il caricatore"
            battery.ttl = 4
            battery.alert = .init(expand: true)
            SystemActivity.show(battery)
            await pause(4.5)
            var rec = SystemActivity.message(RecordingMonitor.activityID, template: .status, title: "Schermo registrato o condiviso")
            rec.symbol = "record.circle.fill"
            rec.tint = "red"
            rec.status = "recording"
            rec.startedAt = Date().timeIntervalSince1970 - 12
            rec.actions = [.init(id: "stop", title: "Ferma la registrazione")]
            SystemActivity.show(rec)
            await pause(hold)
            SystemActivity.end(RecordingMonitor.activityID)
            await pause(1)
        case "musicacompatta":
            // la musica che suona, a isola chiusa: copertina a sinistra, onda a destra (per le immagini)
            engine.show(music, content: .music(song))
            await pause(hold)
            engine.end(id: "musica")
            await pause(1)
        case "musicadisco":
            // un agente al lavoro al centro e la musica nella goccia: la copertina gira come un disco (per le immagini)
            AgentHub.shared.working("demo-disco", kind: .claude, project: "charland", since: Date().addingTimeInterval(-74))
            await pause(1.2)
            engine.show(music, content: .music(song))
            await pause(hold)
            engine.end(id: "musica")
            await pause(0.6)
            AgentHub.shared.finished("demo-disco", duration: 1)
            await pause(1.6)
        case "tre":
            await three()
        case "goccia-claude":
            await claudeInDrop()
        case "musica":
            engine.show(music, content: .music(song))
            engine.send(.expand(id: "musica"))
            await pause(hold)
            engine.end(id: "musica")
            await pause(1)
        default: await tour()
        }
    }

    private func pause(_ seconds: Double) async {
        try? await Task.sleep(for: .seconds(seconds))
    }

    /// Tutto di fila: è la scena del video di circa 20 secondi.
    func tour() async {
        await pause(0.6)
        await states()
        await pause(0.4)
        await drops()
        await pause(0.4)
        await sliders()
        await pause(0.4)
        await voice(style: Appearance.shared.dictationStyle)
        await pause(0.8)
    }

    /// Riposo, compatto, espanso e ritorno.
    func states() async {
        engine.show(music, content: .music(song))
        await pause(1.5)
        engine.send(.expand(id: "musica"))
        await pause(2.0)
        engine.send(.collapse)
        await pause(1.1)
        engine.end(id: "musica")
        await pause(0.9)
    }

    /// La divisione in due gocce e il riassorbimento.
    func drops() async {
        engine.show(music, content: .music(song))
        await pause(1.0)
        engine.show(timer, content: .timer(TimerInfo(label: "Pasta", end: .now + 299, total: 300)))
        await pause(1.8)
        engine.end(id: "timer")
        await pause(1.1)
        engine.end(id: "musica")
        await pause(0.9)
    }

    /// Tre attività insieme: Claude al centro, un timer nella goccia a destra, Mantieni attivo in quella a sinistra.
    /// Ogni goccia si stacca dall'isola e ci rientra; passando sopra la goccia sinistra si apre la sua attività.
    func three() async {
        let hoverWas = engine.state.hoverOpensActivity
        engine.setHoverOpensActivity(true)
        defer { engine.setHoverOpensActivity(hoverWas) }
        let timerActivity = IslandActivity(id: "timer-tre", priority: 0, leadingWidth: 22, trailingWidth: 44,
                                           expandedWidth: 300, expandedHeight: 96)
        let timerContent = ActivityContent.timer(TimerInfo(label: "Pasta", end: .now + 299, total: 300))
        // Mantieni attivo com'è davvero (stessa attività di sistema, priorità di sottofondo), senza tenere sveglio il Mac.
        var awake = SystemActivity.message("mantieni-attivo-tre", template: .status, title: String(localized: "Mantieni attivo"))
        awake.symbol = "cup.and.saucer.fill"
        awake.subtitle = String(localized: "Anche a coperchio chiuso")
        awake.slots = ["trailing": .init(symbol: "infinity")]
        awake.priority = -1

        AgentHub.shared.working("demo-tre", kind: .claude, project: "charland", since: Date().addingTimeInterval(-74))
        await pause(1.8)
        engine.show(timerActivity, content: timerContent)          // la goccia destra si stacca
        await pause(hold)
        SystemActivity.show(awake)                                 // la goccia sinistra si stacca
        await pause(hold)
        // sopra la goccia sinistra: si apre lei (la scelta si rimette qui: il puntatore vero, se passa sull'isola
        // durante la scena, la riporta a quella delle impostazioni)
        engine.setHoverOpensActivity(true)
        engine.send(.pointerEnteredDrop(id: "charland/mantieni-attivo-tre"))
        await pause(hold)
        engine.send(.pointerExited)
        await pause(1.4)
        engine.end(id: "timer-tre")                                // Mantieni attivo passa a destra, la sinistra rientra
        await pause(hold)
        engine.show(timerActivity, content: timerContent)          // il timer riprende la destra, la sinistra si stacca di nuovo
        await pause(hold)
        SystemActivity.end("mantieni-attivo-tre")
        await pause(1.2)
        engine.end(id: "timer-tre")
        await pause(1.2)
        AgentHub.shared.finished("demo-tre", duration: 1)
        await pause(1.6)
    }

    /// Claude al lavoro nella goccia staccata: a destra con un timer più importante al centro, poi anche a sinistra
    /// quando arriva una terza attività. Serve a guardare la mascotte dentro il cerchio della goccia.
    func claudeInDrop() async {
        let timerActivity = IslandActivity(id: "timer-goccia", priority: 5, leadingWidth: 22, trailingWidth: 44,
                                           expandedWidth: 300, expandedHeight: 96)
        let timerContent = ActivityContent.timer(TimerInfo(label: "Pasta", end: .now + 299, total: 300))
        let urgent = IslandActivity(id: "urgente-goccia", priority: 9, leadingWidth: 22, trailingWidth: 44,
                                    expandedWidth: 300, expandedHeight: 96)
        AgentHub.shared.working("demo-goccia", kind: .claude, project: "charland", since: Date().addingTimeInterval(-74))
        await pause(1.2)
        engine.show(timerActivity, content: timerContent)          // Claude va nella goccia destra
        await pause(hold)
        engine.show(urgent, content: timerContent)                 // il timer a destra, Claude a sinistra
        await pause(hold)
        engine.end(id: "urgente-goccia")
        engine.end(id: "timer-goccia")
        await pause(1.2)
        AgentHub.shared.finished("demo-goccia", duration: 1)
        await pause(1.6)
    }

    /// Lo slider del volume con l'elastico, poi la luminosità dal lato opposto.
    func sliders() async {
        island.model.slider = SliderState(side: .volume, level: 0.55)
        engine.send(.transientBegan(.slider(.volume)))
        await pause(0.5)
        await ramp(from: 0.55, to: 1.0, seconds: 0.5)
        // Oltre il massimo: la pillola si allunga con resistenza e torna a molla.
        await overshoot(peak: 0.5, seconds: 0.55)
        await pause(0.25)
        await ramp(from: 1.0, to: 0.0, seconds: 0.8)
        await overshoot(peak: -0.4, seconds: 0.5)
        island.model.slider.muted = true
        await pause(0.5)
        island.model.slider.muted = false
        await ramp(from: 0.0, to: 0.4, seconds: 0.4)
        engine.send(.transientEnded)
        await pause(0.7)

        island.model.slider = SliderState(side: .brightness, level: 0.3)
        engine.send(.transientBegan(.slider(.brightness)))
        await pause(0.4)
        await ramp(from: 0.3, to: 0.85, seconds: 0.7)
        await pause(0.4)
        engine.send(.transientEnded)
        await pause(0.8)
    }

    private func ramp(from: Double, to: Double, seconds: Double) async {
        let frames = max(1, Int(seconds * 60))
        for i in 0...frames {
            let u = Double(i) / Double(frames)
            let eased = u * u * (3 - 2 * u)
            var slider = island.model.slider
            slider.level = from + (to - from) * eased
            slider.overshoot = 0
            engine.setSlider(slider)
            await pause(1.0 / 60.0)
        }
    }

    private func overshoot(peak: Double, seconds: Double) async {
        let frames = max(1, Int(seconds * 60))
        // Spinta oltre il limite, poi ritorno con una molla più vivace.
        for i in 0...frames {
            let u = Double(i) / Double(frames)
            var slider = island.model.slider
            slider.overshoot = peak * sin(u * .pi / 2)
            engine.setSlider(slider)
            await pause(1.0 / 60.0)
        }
        var back = Animated(peak, spring: .lively)
        back.target = 0
        while back.step(dt: 1.0 / 60.0) {
            var slider = island.model.slider
            slider.overshoot = back.value
            engine.setSlider(slider)
            await pause(1.0 / 60.0)
        }
        var rest = island.model.slider
        rest.overshoot = 0
        engine.setSlider(rest)
    }

    /// La dettatura: l'isola si affaccia, la linea segue una voce di prova, poi la goccia cola.
    func voice(style: DictationStyle, target: CGPoint? = nil, drip: Bool = true) async {
        island.model.voice = VoiceState()
        island.model.voiceLevel = 0
        smoother.reset()
        engine.send(.transientBegan(.dictation(style: style, liveText: false, handsFree: false)))
        let envelope = Self.testEnvelope()
        for value in envelope {
            engine.setVoiceLevel(smoother.feed(value, dt: 1.0 / 60.0))
            await pause(1.0 / 60.0)
        }
        // Rilascio: la linea si spegne, il testo cola.
        for _ in 0..<10 {
            engine.setVoiceLevel(smoother.feed(0, dt: 1.0 / 60.0))
            await pause(1.0 / 60.0)
        }
        engine.setVoiceLevel(0)
        if drip {
            var caret = target
            if caret == nil { caret = await CaretLocator.locateInBackground()?.point }
            let screen = island.geometry.frame
            // Senza cursore la goccia scende dritta.
            let point = caret ?? CGPoint(x: island.geometry.notchCenterX, y: screen.maxY - 260)
            island.drip(to: point)
            await pause(0.12)
        }
        engine.send(.transientEnded)
        await pause(1.0)
    }

    /// Le tre varianti della dettatura, una dopo l'altra, per sceglierne una.
    func variants() async {
        for style in DictationStyle.allCases {
            await voice(style: style, drip: false)
            await pause(0.5)
        }
    }

    /// Un agente che lavora, aspetta l'approvazione e finisce.
    func agentScene() async {
        var info = AgentInfo(project: "charland", agent: "Claude Code", phase: .working)
        engine.show(agent, content: .agent(info))
        await pause(1.6)
        info.phase = .waiting
        var asking = agent
        asking.trailingWidth = NeedsYou.trailingWidth   // «Needs you» al posto del tempo: l'ala si allarga
        engine.send(.updated(asking))
        info.command = "rm -rf build/ && xcodebuild -scheme Charland"
        info.explanation = String(localized: "Cancella la cartella build e ricompila l'app. Rischio basso.")
        engine.update(id: "agente", content: .agent(info))
        engine.send(.expand(id: "agente"))
        await pause(2.6)
        info.phase = .done
        info.command = ""
        info.explanation = ""
        engine.send(.updated(agent))
        engine.update(id: "agente", content: .agent(info))
        engine.send(.collapse)
        await pause(1.4)
        engine.end(id: "agente")
        await pause(0.9)
    }

    /// Il volume di una frase detta dalla voce di sistema, un valore per fotogramma a 60 Hz.
    /// Se la voce non c'è, una frase finta con la stessa cadenza.
    static func testEnvelope() -> [Double] {
        if let real = sayEnvelope(), real.count > 30 { return real }
        var out: [Double] = []
        for i in 0..<170 {
            let t = Double(i) / 60
            let syllable = max(0, sin(t * 11.5)) * (0.55 + 0.45 * sin(t * 2.1 + 0.6))
            let gap = (t > 1.15 && t < 1.4) || t > 2.6 ? 0.0 : 1.0
            out.append(min(1, syllable * gap))
        }
        return out
    }

    private static func sayEnvelope() -> [Double]? {
        let folder = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(Identity.bundleID, isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("frase-di-prova.aiff")
        if !FileManager.default.fileExists(atPath: file.path) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/say")
            process.arguments = ["-v", "Alice", "-o", file.path, "Domani alle dieci ho il dentista, ricordami di portare le lastre."]
            do {
                try process.run()
                process.waitUntilExit()
            } catch {
                return nil
            }
        }
        guard let audio = try? AVAudioFile(forReading: file),
              let buffer = AVAudioPCMBuffer(pcmFormat: audio.processingFormat, frameCapacity: AVAudioFrameCount(audio.length)),
              (try? audio.read(into: buffer)) != nil,
              let channel = buffer.floatChannelData?[0] else { return nil }
        let rate = audio.processingFormat.sampleRate
        let window = Int(rate / 60)
        guard window > 0 else { return nil }
        var out: [Double] = []
        var index = 0
        let count = Int(buffer.frameLength)
        while index + window <= count {
            var sum = 0.0
            for i in index..<(index + window) {
                let v = Double(channel[i])
                sum += v * v
            }
            out.append(LevelSmoother.perceived(rms: (sum / Double(window)).squareRoot()))
            index += window
        }
        return out
    }
}
