import AppKit
import SwiftUI
import CharlandCore

/// Fotografa ogni stato dell'isola dallo schermo vero (`screencapture`), così negli scatti
/// c'è anche il vetro: uno scatto fuori schermo non lo avrebbe.
@MainActor
enum Snapshots {
    static func run(folder: String) async {
        guard let island = IslandHub.shared.primary else { return }
        let engine = island.engine
        let dir = URL(fileURLWithPath: folder, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let song = MusicInfo(title: "White Light", artist: "Marlo Vey", elapsed: 62, duration: 200, isPlaying: false,
                             tintA: Color(red: 0.86, green: 0.12, blue: 0.18), tintB: Color(red: 0.10, green: 0.04, blue: 0.08))
        let music = IslandActivity(id: "musica", priority: 1, leadingWidth: 26, trailingWidth: 26, expandedWidth: 320, expandedHeight: 104)
        let timer = IslandActivity(id: "timer", leadingWidth: 22, trailingWidth: 44, expandedWidth: 300, expandedHeight: 96)
        let agent = IslandActivity(id: "agente", priority: 5, leadingWidth: 22, trailingWidth: NeedsYou.trailingWidth, expandedWidth: 372, expandedHeight: 138)

        func shot(_ name: String) async {
            try? await Task.sleep(for: .seconds(1.3))
            let r = island.captureRect
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            process.arguments = ["-x", "-R", "\(Int(r.minX)),\(Int(r.minY)),\(Int(r.width)),\(Int(r.height))",
                                 dir.appendingPathComponent(name + ".png").path]
            try? process.run()
            process.waitUntilExit()
        }

        engine.show(music, content: .music(song))
        await shot("01-compatto")
        engine.show(timer, content: .timer(TimerInfo(label: "Pasta", end: .now + 299, total: 300)))
        await shot("02-due-gocce")
        engine.end(id: "timer")
        engine.send(.expand(id: "musica"))
        await shot("03-espanso")
        engine.send(.collapse)
        engine.end(id: "musica")
        try? await Task.sleep(for: .seconds(0.8))

        island.model.slider = SliderState(side: .volume, level: 0.62)
        engine.send(.transientBegan(.slider(.volume)))
        await shot("04-volume")
        island.model.slider.overshoot = 0.5
        island.model.slider.level = 1
        await shot("05-volume-elastico")
        engine.send(.transientEnded)
        island.model.slider = SliderState(side: .brightness, level: 0.35)
        engine.send(.transientBegan(.slider(.brightness)))
        await shot("06-luminosita")
        engine.send(.transientEnded)
        try? await Task.sleep(for: .seconds(0.8))

        for (index, style) in DictationStyle.allCases.enumerated() {
            island.model.voice = VoiceState()
            island.model.voiceLevel = 0.7
            engine.send(.transientBegan(.dictation(style: style, liveText: false, handsFree: false)))
            engine.setVoiceLevel(0.7)
            await shot("0\(7 + index)-dettatura-\(style.rawValue)")
            engine.setVoiceLevel(0)
            engine.send(.transientEnded)
            try? await Task.sleep(for: .seconds(0.7))
        }
        island.model.voice = VoiceState(liveText: String(localized: "Domani alle dieci ho il dentista, ricordami"))
        island.model.voiceLevel = 0.5
        engine.send(.transientBegan(.dictation(style: .soffio, liveText: true, handsFree: false)))
        engine.setVoiceLevel(0.5)
        await shot("10-testo-dal-vivo")
        engine.setVoiceLevel(0)
        engine.send(.transientEnded)
        try? await Task.sleep(for: .seconds(0.7))

        engine.show(agent, content: .agent(AgentInfo(project: "charland", agent: "Claude Code", phase: .waiting,
                                                     command: "rm -rf build/ && xcodebuild -scheme Charland",
                                                     explanation: String(localized: "Cancella la cartella build e ricompila l'app. Rischio basso."))))
        engine.send(.expand(id: "agente"))
        await shot("11-agente")
        engine.send(.collapse)
        engine.end(id: "agente")
        try? await Task.sleep(for: .seconds(0.8))
    }

    /// Disegna ogni stato fuori schermo, sopra lo sfondo predefinito di Charland.
    /// Serve quando lo schermo non si può fotografare (coperchio chiuso, schermo bloccato).
    /// Il vetro di sistema qui non c'è: dove il velo è trasparente si vede lo sfondo com'è,
    /// senza la rifrazione. Forma, misure, velo, luce e contenuti sono quelli veri.
    static func render(folder: String, metrics: IslandMetrics = .air15) {
        let dir = URL(fileURLWithPath: folder, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        GlassChecks.render(into: dir)
        let size = CGSize(width: 820, height: 360)
        let model = IslandModel(metrics: metrics, stageSize: size)
        let engine = IslandEngine(model: model)
        // Lo sfondo predefinito di Charland, non quello della scrivania di chi lancia la prova: gli scatti finiscono nei
        // documenti e nelle segnalazioni, e lo sfondo della scrivania può essere un'immagine non nostra.
        let wallpaper = WallpaperFiles.defaultImage.flatMap { NSImage(contentsOf: $0) }

        func settle(_ seconds: Double = 2.4) {
            for _ in 0..<Int(seconds * 60) { engine.advance(by: 1.0 / 60.0) }
        }
        func shot(_ name: String) {
            let view = ZStack(alignment: .top) {
                if let wallpaper {
                    Image(nsImage: wallpaper).resizable().aspectRatio(contentMode: .fill)
                        .frame(width: 1710, height: 1107, alignment: .top)
                        .frame(width: size.width, height: size.height, alignment: .top)
                        .clipped()
                } else {
                    LinearGradient(colors: [Color(white: 0.8), Color(white: 0.45)], startPoint: .top, endPoint: .bottom)
                }
                if metrics.hasNotch { NotchCutout(metrics: metrics) }
                IslandStageView(model: model, appearance: .shared)
            }
            .frame(width: size.width, height: size.height)
            let renderer = ImageRenderer(content: view)
            renderer.scale = 2
            guard let image = renderer.cgImage else { print("scatto fallito: \(name)"); return }
            let rep = NSBitmapImageRep(cgImage: image)
            try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent(name + ".png"))
        }

        let song = MusicInfo(title: "White Light", artist: "Marlo Vey", elapsed: 62, duration: 200, isPlaying: false,
                             tintA: Color(red: 0.86, green: 0.12, blue: 0.18), tintB: Color(red: 0.10, green: 0.04, blue: 0.08))
        let music = IslandActivity(id: "musica", priority: 1, leadingWidth: 26, trailingWidth: 26, expandedWidth: 320, expandedHeight: 104)
        let timer = IslandActivity(id: "timer", leadingWidth: 22, trailingWidth: 44, expandedWidth: 300, expandedHeight: 96)
        let agent = IslandActivity(id: "agente", priority: 5, leadingWidth: 22, trailingWidth: NeedsYou.trailingWidth, expandedWidth: 372, expandedHeight: 138)

        engine.setHome(Home.activity, content: .home(HomeInfo(date: Date(), battery: 76, charging: false, hasLastDictation: true)))
        engine.send(.pointerEntered); settle(0.15); shot("00a-casa-che-si-apre")
        settle(); shot("00b-casa")
        HomeUI.shared.panel = .timer; settle(0.6); shot("00c-casa-timer")
        HomeUI.shared.panel = .awake; settle(0.6); shot("00d-casa-attivo")
        HomeUI.shared.panel = .none
        engine.send(.pointerExited); engine.send(.collapse); settle()

        engine.show(music, content: .music(song)); settle(); shot("01-compatto")
        engine.show(timer, content: .timer(TimerInfo(label: "Pasta", end: .now + 299, total: 300)))
        settle(0.2); shot("02a-goccia-che-nasce")
        settle(0.12); shot("02b-collo")
        settle(); shot("02c-due-gocce")
        engine.end(id: "timer"); settle()
        engine.send(.expand(id: "musica")); settle(0.15); shot("03a-apertura")
        settle(); shot("03b-espanso")
        engine.send(.collapse); engine.end(id: "musica"); settle()

        model.slider = SliderState(side: .volume, level: 0.62)
        engine.send(.transientBegan(.slider(.volume))); settle(1.0); shot("04-volume")
        engine.setSlider(SliderState(side: .volume, level: 1, overshoot: 0.5)); settle(0.02); shot("05-volume-elastico")
        engine.setSlider(SliderState(side: .volume, level: 0, muted: true)); settle(0.02); shot("05b-muto")
        engine.send(.transientEnded); settle()
        model.slider = SliderState(side: .brightness, level: 0.35)
        engine.send(.transientBegan(.slider(.brightness))); settle(1.0); shot("06-luminosita")
        engine.send(.transientEnded); settle()

        for (index, style) in DictationStyle.allCases.enumerated() {
            model.voice = VoiceState()
            model.voiceLevel = 0.8
            engine.send(.transientBegan(.dictation(style: style, liveText: false, handsFree: index == 2)))
            engine.setVoiceLevel(0.8); settle(1.2)
            shot("0\(7 + index)-dettatura-\(style.rawValue)")
            engine.setVoiceLevel(0); engine.send(.transientEnded); settle()
        }
        model.voice = VoiceState(liveText: String(localized: "Domani alle dieci ho il dentista, ricordami"))
        model.voiceLevel = 0.5
        engine.send(.transientBegan(.dictation(style: .soffio, liveText: true, handsFree: false)))
        engine.setVoiceLevel(0.5); settle(1.2); shot("10-testo-dal-vivo")
        engine.setVoiceLevel(0); engine.send(.transientEnded); settle()

        engine.show(agent, content: .agent(AgentInfo(project: "charland", agent: "Claude Code", phase: .waiting,
                                                     command: "rm -rf build/ && xcodebuild -scheme Charland",
                                                     explanation: String(localized: "Cancella la cartella build e ricompila l'app. Rischio basso."))))
        engine.send(.expand(id: "agente")); settle(); shot("11-agente")
        engine.send(.collapse); engine.end(id: "agente"); settle()

        // La stella su GitHub chiesta dopo un aggiornamento (StarAsk), come la mostra il centro delle attività.
        var star = SystemActivity.message(StarAsk.activityID, template: .status, title: String(localized: "Ti piace Charland?"))
        star.subtitle = String(localized: "Una stella su GitHub aiuta altri a trovarla")
        star.symbol = "star.fill"; star.tint = "yellow"
        star.actions = StarAsk.actions
        let starActivity = ActivityCenter.activity(key: "charland/stella", message: star)
        engine.show(starActivity, content: .api(ActivityCenter.content(for: star)))
        engine.send(.expand(id: starActivity.id)); settle(); shot("11b-stella")
        engine.send(.collapse); engine.end(id: starActivity.id); settle()

        // Riproduzione vuota (tessera Musica con niente in riproduzione): la nota in alto a sinistra.
        let idle = MusicInfo(title: "", artist: "", elapsed: 0, duration: 0, isPlaying: false, appName: MusicApp.shared.name, idle: true)
        engine.show(music, content: .music(idle)); engine.send(.expand(id: "musica")); settle(); shot("12-musica-vuota")
        engine.send(.collapse); engine.end(id: "musica"); settle()

        // La casa col meteo in alto a sinistra (un tempo di prova, che non si salva) e il vassoio con le anteprime.
        WeatherStore.shared.showForPreview(WeatherStore.Now(symbol: "cloud.sun.rain.fill", temperature: 14, place: "Milano", fetched: Date()))
        let files = (ProcessInfo.processInfo.environment["CHARLAND_RENDER_FILES"] ?? "").split(separator: ":").map { URL(fileURLWithPath: String($0)) }
        let tray = TrayStore.shared
        if !files.isEmpty {
            tray.add(files)
            for item in tray.items { _ = tray.preview(for: item) }
            // Le anteprime di Quick Look arrivano in sottofondo: un attimo di ciclo principale per riceverle.
            RunLoop.main.run(until: Date().addingTimeInterval(2.5))
        }
        engine.setHome(Home.current, content: .home(HomeInfo(date: Date(), battery: 76, charging: false, hasLastDictation: true)))
        engine.send(.pointerEntered); settle(); shot("13-casa-meteo-vassoio")
        tray.dropping = true
        engine.setHome(Home.current, content: .home(HomeInfo(date: Date(), battery: 76, charging: false, hasLastDictation: true)))
        settle(0.8); shot("14-rilascia-o-airdrop")
        tray.zone = .airdrop; settle(0.5); shot("15-airdrop-scelto")
        for url in files { if let item = tray.items.first(where: { $0.path == url.path }) { tray.remove(item) } }
        tray.zone = nil
        engine.setHome(Home.current, content: .home(HomeInfo(date: Date(), battery: 76, charging: false, hasLastDictation: true)))
        settle(0.8); shot("16-rilascia-o-airdrop-vassoio-vuoto")
        tray.dropping = false
        print("scatti in \(dir.path)")
    }
}
