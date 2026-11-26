import SwiftUI
import CharlandCore

/// Prepara una volta, all'avvio, quello che macOS crea solo la prima volta che serve:
/// i simboli SF, i caratteri arrotondati, le viste dei contenuti dell'isola. Senza, la prima
/// apertura della musica o della casa perdeva qualche fotogramma.
@MainActor
enum IslandWarmup {
    private static var done = false

    static func run() {
        guard !done else { return }
        done = true
        let song = MusicInfo(title: "White Light", artist: "Marlo Vey", elapsed: 62, duration: 200, isPlaying: true)
        let views: [AnyView] = [
            AnyView(MusicExpanded(info: song).frame(width: 320, height: 104)),
            AnyView(ActivitySlotView(content: .music(song), slot: .leading).frame(width: 26, height: 33)),
            AnyView(ActivitySlotView(content: .music(song), slot: .trailing).frame(width: 26, height: 33)),
            AnyView(HomeExpanded(info: HomeInfo(date: Date(), battery: 80, charging: false, hasLastDictation: true),
                                 tray: TrayStore.shared, act: { _ in }).frame(width: 292, height: 78)),
            // La casa con una pillola in cima (la mascotte al lavoro): la prima volta costava un fotogramma da 34 ms.
            AnyView(HomeExpanded(info: HomeInfo(date: Date(), battery: 80, charging: false, hasLastDictation: true,
                                                pills: [HomePill(id: "agenti", content: .agents(AgentsInfo(
                                                    sessions: [AgentSession(id: "a", kind: .claude, project: "x", since: Date())],
                                                    finished: nil)))]),
                                 tray: TrayStore.shared, act: { _ in }).frame(width: 292, height: 120)),
            AnyView(ProjectChip(name: "Charland")),
            AnyView(HomeSlotView(info: HomeInfo(date: Date(), battery: 80, charging: true, hasLastDictation: false),
                                 slot: .trailing, act: { _ in }).frame(width: 56, height: 33)),
            AnyView(AgentsSlotView(info: AgentsInfo(sessions: [AgentSession(id: "a", kind: .claude, project: "x", since: Date())], finished: nil),
                                   slot: .expanded).frame(width: 300, height: 72)),
            AnyView(TurnTimer(start: Date())),
            AnyView(HStack {
                ForEach(["timer", "checkmark", "xmark", "hand.raised.fill", "sun.max.fill", "speaker.wave.3.fill",
                         "speaker.slash.fill", "tray.and.arrow.down.fill", "cup.and.saucer.fill", "record.circle.fill",
                         "battery.25percent", "battery.100percent.bolt", "gearshape.fill", "arrow.uturn.backward",
                         "infinity", "sparkle", "folder.fill", "cup.and.saucer", "moon.fill", "bed.double.fill"], id: \.self) {
                    Image(systemName: $0).font(.system(size: 17, weight: .semibold))
                }
            }),
            AnyView(DictationLeading(model: IslandModel(metrics: .air15, stageSize: CGSize(width: 10, height: 10)))),
            // La falce della Concentrazione e il suo nome: la prima comparsa senza fotogrammi persi.
            AnyView(FocusGlyphFrame(look: .init(phase: 0.5, scale: 1, tilt: 0, opacity: 1, lit: 1), symbol: nil, tint: "indigo")
                .frame(width: 30, height: 33)),
            AnyView(Text(FocusNames.generic).font(.system(size: 13, weight: .semibold))),
        ]
        for view in views {
            let renderer = ImageRenderer(content: view.environment(\.colorScheme, .dark))
            renderer.scale = 2
            _ = renderer.cgImage
        }
    }
}
