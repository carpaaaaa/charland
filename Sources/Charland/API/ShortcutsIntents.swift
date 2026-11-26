import AppIntents
import CharlandKit

// Le azioni di Comandi Rapidi: così anche chi non programma può mostrare un'attività nell'isola.

struct ShowActivityIntent: AppIntent {
    static let title: LocalizedStringResource = "Mostra nell'isola"
    static let description = IntentDescription("Mostra o aggiorna un'attività nell'isola di Charland.")
    static let openAppWhenRun = false

    @Parameter(title: "Nome") var name: String
    @Parameter(title: "Titolo") var activityTitle: String
    @Parameter(title: "Avanzamento", description: "Da 0 a 100.") var percent: Double?
    @Parameter(title: "Stato") var status: String?
    @Parameter(title: "Simbolo", description: "Il nome di un SF Symbol.") var symbol: String?

    @MainActor
    func perform() async throws -> some IntentResult {
        var m = ActivityMessage(op: .upsert, client: "comandi-rapidi", id: name)
        m.title = String(activityTitle.prefix(60))
        m.status = status.map { String($0.prefix(80)) }
        m.symbol = symbol
        if let percent {
            m.template = .progress
            m.progress = min(1, max(0, percent / 100))
        } else {
            m.template = .status
        }
        try ActivitySchema.validate(m)
        _ = ActivityCenter.shared.handle(m, from: nil)
        return .result()
    }
}

struct EndActivityIntent: AppIntent {
    static let title: LocalizedStringResource = "Chiudi nell'isola"
    static let description = IntentDescription("Chiude un'attività mostrata nell'isola di Charland.")
    static let openAppWhenRun = false

    @Parameter(title: "Nome") var name: String

    @MainActor
    func perform() async throws -> some IntentResult {
        _ = ActivityCenter.shared.handle(ActivityMessage(op: .end, client: "comandi-rapidi", id: name), from: nil)
        return .result()
    }
}

struct CharlandShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: ShowActivityIntent(), phrases: ["Mostra nell'isola di \(.applicationName)"],
                    shortTitle: "Mostra nell'isola", systemImageName: "capsule.tophalf.filled")
    }
}
