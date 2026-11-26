import SwiftUI
import CharlandCore

/// Aspetto: l'isola vera, alla sua misura, sopra lo sfondo viola del sito.
/// Ogni regolazione si vede subito qui e nell'isola in cima allo schermo.
struct AppearancePane: View {
    @Bindable private var appearance = Appearance.shared
    @State private var preview = PreviewIsland()
    @State private var scene: PreviewScene = .music
    /// L'anteprima si vede davvero: sezione aperta e finestra non coperta. Se no si ferma: animata dietro
    /// le altre finestre rubava fotogrammi all'isola vera (30 in ritardo a ogni file trascinato nel vassoio).
    @State private var visible = true

    var body: some View {
        VStack(spacing: 0) {
            LivePreview(preview: preview, active: visible)
                .background(WindowVisibilityReader { shown in
                    guard shown != visible else { return }
                    visible = shown
                    if shown { preview.show(scene) } else { preview.stop() }
                })
                .frame(height: 250)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .padding([.horizontal, .top], 20)

            Picker("", selection: $scene) {
                ForEach(PreviewScene.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 20)
            .padding(.top, 14)

            Form {
                Section {
                    Picker("Aspetto", selection: $appearance.look) {
                        Text("Nero e vetro").tag(IslandLook.blackGlass)
                        Text("Solo nero").tag(IslandLook.black)
                    }
                    if appearance.look == .blackGlass {
                        LabeledContent("Vetro in basso") {
                            Slider(value: $appearance.glass, in: 0.2...1)
                        }
                        LabeledContent("Luce sul bordo") {
                            Slider(value: $appearance.rim, in: 0...1.6)
                        }
                    }
                } header: {
                    Text("Isola")
                } footer: {
                    if appearance.look == .blackGlass {
                        Text("Sotto la fotocamera l'isola resta nera come il notch e scendendo diventa di vetro: «Vetro in basso» dice quanto, «Luce sul bordo» quanto si vede il filo di luce che la disegna.")
                    }
                }
                Section {
                    Toggle("Tutto vetro", isOn: $appearance.fullGlass)
                    if appearance.fullGlass {
                        Toggle("Copertine a colori", isOn: $appearance.glassKeepsCovers)
                    }
                } footer: {
                    Text("Nel notch e nei widget del Dock spariscono i colori: simboli, numeri, anelli e mascotte diventano di vetro, e i vassoi del Dock sono più trasparenti.")
                }
                Section {
                    LabeledContent("Molle") {
                        HStack {
                            Text("Vivaci").foregroundStyle(.secondary)
                            Slider(value: $appearance.calm, in: 0.7...1.5)
                            Text("Calme").foregroundStyle(.secondary)
                        }
                    }
                    Picker("Dettatura", selection: $appearance.dictationStyle) {
                        Text("Soffio").tag(DictationStyle.soffio)
                        Text("Ciglio").tag(DictationStyle.ciglio)
                        Text("Orizzonte").tag(DictationStyle.orizzonte)
                    }
                } header: {
                    Text("Movimento")
                } footer: {
                    Text("Le molle vivaci rimbalzano un poco, quelle calme arrivano morbide. «Dettatura» è come si muove l'isola mentre parli: guardala nell'anteprima, scheda Dettatura.")
                }
                // «Suoni» c'era fino al 19 novembre 2026 ma non era collegato a niente: tolto, con la sua proprietà.
                Section {
                    Toggle("Tocchi sul trackpad", isOn: $appearance.haptics)
                } footer: {
                    Text("Un tocco sul trackpad quando l'isola si apre sotto il puntatore, quando un'attività ti chiede qualcosa o finisce, e quando uno slider arriva in fondo.")
                }
            }
            .formStyle(.grouped)
        }
        .onAppear { preview.show(scene) }
        .onDisappear {
            visible = false
            preview.stop()
        }
        .onChange(of: scene) { _, new in preview.show(new) }
        .onChange(of: appearance.look) { _, _ in preview.refresh(scene) }
        .onChange(of: appearance.glass) { _, _ in preview.touch() }
        .onChange(of: appearance.rim) { _, _ in preview.touch() }
        .onChange(of: appearance.calm) { _, _ in preview.replay(scene) }
        .onChange(of: appearance.dictationStyle) { _, _ in
            scene = .dictation
            preview.replay(.dictation)
        }
    }
}

/// Le scene dell'anteprima. Lo slider non c'è più: volume e luminosità escono dal bordo sinistro dello schermo, non
/// dall'isola (tolto il 17 novembre 2026).
enum PreviewScene: String, CaseIterable, Identifiable {
    case rest, music, dictation, agent
    var id: String { rawValue }
    var title: LocalizedStringKey {
        switch self {
        case .rest: "Riposo"
        case .music: "Musica"
        case .dictation: "Dettatura"
        case .agent: "Agente"
        }
    }
}

/// Un'isola in più, tutta per l'anteprima: stesso motore e stesse viste di quella vera.
@MainActor @Observable
final class PreviewIsland {
    let model: IslandModel
    let engine: IslandEngine
    private var voiceTask: Task<Void, Never>?

    init() {
        let metrics = IslandHub.shared.primary?.geometry.metrics ?? .air15
        model = IslandModel(metrics: metrics, stageSize: CGSize(width: 560, height: 250))
        engine = IslandEngine(model: model)
    }

    private let music = IslandActivity(id: "musica", priority: 1, leadingWidth: 26, trailingWidth: 26, expandedWidth: 320, expandedHeight: 104)
    private let agent = IslandActivity(id: "agente", priority: 5, leadingWidth: 22, trailingWidth: NeedsYou.trailingWidth,
                                       expandedWidth: 372, expandedHeight: 138)

    /// Ferma tutto quello che si muove: i giri della voce, e l'isola torna a riposo.
    func stop() {
        voiceTask?.cancel()
        voiceTask = nil
        engine.setVoiceLevel(0)
        engine.send(.transientEnded)
        engine.send(.collapse)
    }

    func show(_ scene: PreviewScene) {
        voiceTask?.cancel()
        engine.setVoiceLevel(0)
        engine.send(.transientEnded)
        engine.send(.collapse)
        for id in ["musica", "agente"] where scene != .music || id != "musica" {
            if scene == .agent, id == "agente" { continue }
            engine.end(id: id)
        }
        switch scene {
        case .rest:
            break
        case .music:
            engine.show(music, content: .music(MusicInfo(title: "White Light", artist: "Marlo Vey", elapsed: 62, duration: 200, isPlaying: true,
                                                         tintA: Color(red: 0.86, green: 0.12, blue: 0.18), tintB: Color(red: 0.10, green: 0.04, blue: 0.08))))
            engine.send(.expand(id: "musica"))
        case .dictation:
            model.voice = VoiceState()
            engine.send(.transientBegan(.dictation(style: Appearance.shared.dictationStyle, liveText: false, handsFree: false)))
            voiceTask = Task { [weak self] in
                var smoother = LevelSmoother()
                let envelope = DemoDirector.testEnvelope()
                while !Task.isCancelled {
                    for value in envelope {
                        if Task.isCancelled { return }
                        self?.engine.setVoiceLevel(smoother.feed(value, dt: 1.0 / 60.0))
                        try? await Task.sleep(for: .seconds(1.0 / 60.0))
                    }
                    try? await Task.sleep(for: .seconds(0.5))
                }
            }
        case .agent:
            engine.show(agent, content: .agent(AgentInfo(project: "charland", agent: "Claude Code", phase: .waiting,
                                                         command: "rm -rf build/ && xcodebuild -scheme Charland",
                                                         explanation: String(localized: "Cancella la cartella build e ricompila l'app. Rischio basso."))))
            engine.send(.expand(id: "agente"))
        }
    }

    /// Stesso stato, misure ricalcolate (cambio di aspetto).
    func refresh(_ scene: PreviewScene) {
        engine.refresh()
        IslandHub.shared.islands.forEach { $0.engine.refresh() }
    }

    /// Ridisegna senza muovere niente (vetro, luce).
    func touch() {
        engine.refresh()
    }

    /// Chiude e riapre, per far vedere le molle.
    func replay(_ scene: PreviewScene) {
        show(.rest)
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(0.45))
            self?.show(scene)
        }
    }
}

/// L'isola dell'anteprima sopra lo sfondo viola del sito.
struct LivePreview: View {
    let preview: PreviewIsland
    var active = true

    var body: some View {
        ZStack(alignment: .top) {
            PreviewWallpaper()
            // Una barra dei menu accennata, per dare la misura.
            Rectangle().fill(.black.opacity(0.18)).frame(height: preview.model.metrics.notchHeight)
            NotchCutout(metrics: preview.model.metrics)
            // Ferma, l'isola dell'anteprima non si disegna: niente vetro né simboli animati dietro le quinte.
            if active {
                IslandStageView(model: preview.model, appearance: .shared)
                    .background(EngineHost(engine: preview.engine))
            }
        }
        .frame(maxWidth: .infinity)
        .clipped()
    }
}

/// Il notch vero, disegnato nell'anteprima perché lì sotto non c'è l'hardware.
struct NotchCutout: View {
    let metrics: IslandMetrics

    var body: some View {
        UnevenRoundedRectangle(bottomLeadingRadius: 9, bottomTrailingRadius: 9)
            .fill(.black)
            .frame(width: metrics.notchWidth, height: metrics.notchHeight)
    }
}

/// Dice se la finestra che contiene questa vista si vede (non coperta, non ridotta a icona).
/// Adattato da `WindowVisibilityReader` di Vorssaint (GPL-3.0-or-later, Copyright (C) 2026 Vorssaint).
struct WindowVisibilityReader: NSViewRepresentable {
    let onChange: (Bool) -> Void

    func makeNSView(context: Context) -> VisibilityView {
        let view = VisibilityView()
        view.onChange = onChange
        return view
    }

    func updateNSView(_ view: VisibilityView, context: Context) { view.onChange = onChange }

    final class VisibilityView: NSView {
        var onChange: ((Bool) -> Void)?
        private var observer: NSObjectProtocol?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let observer { NotificationCenter.default.removeObserver(observer) }
            observer = nil
            guard let window else { return }
            observer = NotificationCenter.default.addObserver(forName: NSWindow.didChangeOcclusionStateNotification,
                                                              object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, let window = self.window else { return }
                    self.onChange?(window.occlusionState.contains(.visible))
                }
            }
        }
    }
}

/// Aggancia il motore dell'anteprima a una vista vera, da cui prende il display link.
struct EngineHost: NSViewRepresentable {
    let engine: IslandEngine

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        engine.attach(to: view)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

/// Lo sfondo dell'anteprima: un viola sfumato, tagliato in alto, dove su uno schermo vero sta il notch.
struct PreviewWallpaper: View {
    var body: some View {
        GeometryReader { geo in
            Group {
                LinearGradient(colors: [Color(red: 0.30, green: 0.16, blue: 0.55), Color(red: 0.12, green: 0.05, blue: 0.26)],
                               startPoint: .top, endPoint: .bottom)
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .top)
            .clipped()
        }
    }
}
