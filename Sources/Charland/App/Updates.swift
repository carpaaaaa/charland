import AppKit
import Combine
import Sparkle
import SwiftUI
import CharlandCore

/// Gli aggiornamenti di Charland, con Sparkle. Sparkle legge `appcast.xml` dal sito (`SUFeedURL` nell'Info.plist),
/// controlla la firma Ed25519 del DMG con la chiave pubblica che l'app ha dentro (`SUPublicEDKey`) e lo installa.
///
/// Solo le build ufficiali (compilate con `CHARLAND_OFFICIAL`, firmate dal maintainer) creano l'updater. Le build
/// compilate da chi sviluppa non cercano aggiornamenti e non toccano il feed ufficiale.
@MainActor
final class Updates {
    static let shared = Updates()

    private var controller: SPUStandardUpdaterController?
    private let delegate = UpdatesDelegate()
    private let reminders = UpdateReminders()

    var updater: SPUUpdater? { controller?.updater }

    /// Accende Sparkle. Solo nelle build ufficiali e dall'app vera: le scene dimostrative non cercano aggiornamenti.
    func start() {
        #if CHARLAND_OFFICIAL
        guard controller == nil, Bundle.main.bundleURL.pathExtension == "app" else { return }
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: delegate, userDriverDelegate: reminders)
        #endif
    }

    func checkNow() {
        controller?.checkForUpdates(nil)
    }

}

/// Il delegato di Sparkle: non cambia il comportamento di serie.
final class UpdatesDelegate: NSObject, SPUUpdaterDelegate {}

/// L'aggiornamento trovato dal controllo di ogni giorno lo annuncia l'isola, non una finestra (carpa, 19 novembre 2026:
/// «tutti quelli con l'app devono poter aggiornare l'app facilmente»). Charland sta sempre dietro le altre app: la
/// finestra di Sparkle comparirebbe sotto le loro finestre, o rubando il fuoco mentre scrivi (un Invio premuto lì
/// installerebbe). Sparkle lo prevede coi promemoria gentili: per i controlli in sottofondo la finestra non si apre, la
/// tacca dice «Charland 1.0.1 è pronta» con «Aggiorna», e «Aggiorna» porta in primo piano la finestra di Sparkle con
/// le novità e il tasto per installare (scarica, installa e riapre Charland da sola). «Più tardi» o niente: il
/// controllo del giorno dopo lo ricorda. «Cerca aggiornamenti…» nelle impostazioni apre la finestra subito, come prima.
final class UpdateReminders: NSObject, SPUStandardUserDriverDelegate {
    static let activityID = "aggiornamento"

    var supportsGentleScheduledUpdateReminders: Bool { true }

    /// Lo annuncia l'isola anche a Charland appena aperta (all'accesso al Mac): una finestra che ruba il fuoco lì non la
    /// vuole nessuno. Senza isola invece la
    /// finestra la mostra Sparkle, perché un aggiornamento deve poter arrivare sempre.
    func standardUserDriverShouldHandleShowingScheduledUpdate(_ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool) -> Bool {
        MainActor.assumeIsolated { !Self.islandShowsNotices }
    }

    @MainActor static var islandShowsNotices: Bool {
        IslandHub.shared.primary != nil
    }

    func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState) {
        // `true`: la finestra la mostra Sparkle (controllo a mano, o dopo «Aggiorna»), l'isola non serve.
        guard !handleShowingUpdate else { return }
        let version = update.displayVersionString
        MainActor.assumeIsolated { Self.announce(version: version) }
    }

    func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        MainActor.assumeIsolated { SystemActivity.end(Self.activityID) }
    }

    func standardUserDriverWillFinishUpdateSession() {
        MainActor.assumeIsolated { SystemActivity.end(Self.activityID) }
    }

    @MainActor static func announce(version: String) {
        var m = SystemActivity.message(activityID, template: .status, title: String(localized: "Charland \(version) è pronta"))
        m.subtitle = String(localized: "Si installa in pochi secondi e si riapre da sola")
        m.symbol = "arrow.down.circle.fill"
        m.tint = "teal"
        // Come gli altri avvisi con un tasto da premere: resta il tempo di leggerlo e decidere.
        m.ttl = 12
        m.alert = .init(expand: true, haptic: "waiting")
        m.actions = [.init(id: "aggiorna", title: String(localized: "Aggiorna")),
                     .init(id: "dopo", title: String(localized: "Più tardi"))]
        SystemActivity.show(m) { action in
            SystemActivity.end(activityID)
            guard action == "aggiorna" else { return }
            // La finestra di Sparkle in primo piano, con le novità e «Installa».
            NSApp.activate()
            Updates.shared.checkNow()
        }
    }
}

/// La sezione Aggiornamenti delle impostazioni (in Informazioni).
struct UpdatesSection: View {
    @State private var model = UpdatesModel()

    var body: some View {
        Section {
            if model.available {
                LabeledContent(String(localized: "Versione \(Identity.version)")) {
                    Button("Cerca aggiornamenti…") { Updates.shared.checkNow() }
                        .disabled(!model.canCheck)
                }
                Toggle("Controlla da sola ogni giorno", isOn: $model.automaticChecks)
                Toggle("Scarica e installa da sola", isOn: $model.automaticDownloads)
                    .disabled(!model.automaticChecks)
            } else {
                Text("In questa copia gli aggiornamenti sono spenti.").foregroundStyle(.secondary)
            }
        } header: {
            Text("Aggiornamenti")
        }
    }
}

@MainActor
@Observable
final class UpdatesModel {
    private(set) var available = false
    private(set) var canCheck = false
    var automaticChecks = false {
        didSet { if Updates.shared.updater?.automaticallyChecksForUpdates != automaticChecks { Updates.shared.updater?.automaticallyChecksForUpdates = automaticChecks } }
    }
    var automaticDownloads = false {
        didSet { if Updates.shared.updater?.automaticallyDownloadsUpdates != automaticDownloads { Updates.shared.updater?.automaticallyDownloadsUpdates = automaticDownloads } }
    }
    @ObservationIgnored private var watch: AnyCancellable?

    init() {
        guard let updater = Updates.shared.updater else { return }
        available = true
        automaticChecks = updater.automaticallyChecksForUpdates
        automaticDownloads = updater.automaticallyDownloadsUpdates
        watch = updater.publisher(for: \.canCheckForUpdates)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] value in self?.canCheck = value }
    }
}
