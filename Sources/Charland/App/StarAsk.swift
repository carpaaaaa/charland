import AppKit
import CharlandCore
import CharlandKit

/// Una stella su GitHub e un caffè, chiesti dopo ogni aggiornamento (carpa, 26 novembre 2026: «un reminder come su
/// Oriel, poco invasivo, che però ricordi di lasciare una stella su GitHub, a ogni aggiornamento», poi «togli don't ask
/// again, voglio che ogni aggiornamento appaia e sia comunque facile da togliere» e «deve restare finché premi not now»).
///
/// Qualche secondo dopo l'avvio di una versione nuova l'isola si apre con «Ti piace Charland?» e tre tasti: «Una stella»
/// (apre il repository), «Un caffè» (apre buymeacoffee) e «Non ora». Poi si stringe a una stellina nel notch, come le
/// altre attività, e resta lì finché non si preme uno dei tre: l'isola chiude ogni attività dopo 8 ore, quindi la si
/// ripropone allo scadere e al prossimo avvio. Mai alla prima installazione. Solo nelle build ufficiali: una copia
/// compilata da sé, o un fork, non chiede stelle per questo repository.
@MainActor
enum StarAsk {
    static let activityID = "stella"
    static let repository = URL(string: "https://github.com/carpaaaaa/charland")!
    static let coffee = URL(string: "https://buymeacoffee.com/charstudio")!

    private static let lastVersionKey = "starAskLastVersion"
    /// Mostrata e non ancora chiusa con uno dei tre tasti.
    private static let pendingKey = "starAskPending"
    private static var refresh: DispatchWorkItem?

    /// All'avvio, dopo i servizi. Ricorda la versione di adesso; se prima ce n'era un'altra, è un aggiornamento.
    /// `firstRun`: Charland non era mai partita su questo Mac. Le copie della 1.6 e di prima non hanno ancora salvato la
    /// versione: se non è la prima volta, vale come un aggiornamento da una versione precedente.
    static func checkAfterLaunch(firstRun: Bool) {
        let defaults = UserDefaults.standard
        let previous = defaults.string(forKey: lastVersionKey) ?? (firstRun ? nil : "precedente")
        defaults.set(Identity.version, forKey: lastVersionKey)
        #if DEBUG
        // Per le prove: `CHARLAND_STELLA=1` la mostra a ogni avvio, anche nelle build di sviluppo.
        let forced = ProcessInfo.processInfo.environment["CHARLAND_STELLA"] == "1"
        #else
        let forced = false
        #endif
        let updated = StarAskRule.shouldAsk(previous: previous, current: Identity.version)
        guard forced || updated || defaults.bool(forKey: pendingKey) else { return }
        #if !CHARLAND_OFFICIAL
        guard forced else { return }
        #endif
        // Dopo che l'isola si è sistemata, e lontano dagli avvisi dell'avvio.
        DispatchQueue.main.asyncAfter(deadline: .now() + (forced ? 2 : 8)) { show() }
    }

    /// Tre tasti: è un'attività interna, il limite di due tasti dell'API non vale.
    static var actions: [ActivityMessage.Action] {
        [.init(id: "stella", title: String(localized: "Una stella")),
         .init(id: "caffe", title: String(localized: "Un caffè")),
         .init(id: "nonora", title: String(localized: "Non ora"))]
    }

    static func show(expand: Bool = true) {
        UserDefaults.standard.set(true, forKey: pendingKey)
        var m = SystemActivity.message(activityID, template: .status, title: String(localized: "Ti piace Charland?"))
        m.subtitle = String(localized: "Una stella su GitHub aiuta altri a trovarla")
        m.symbol = "star.fill"
        m.tint = "yellow"
        // Poco invasiva: niente tocco sul trackpad né suono. Si apre una volta, poi resta piccola nel notch.
        m.ttl = ActivitySchema.maxSeconds
        if expand { m.alert = .init(expand: true) }
        m.actions = actions
        SystemActivity.show(m) { action in
            close()
            switch action {
            case "stella": NSWorkspace.shared.open(repository)
            case "caffe": NSWorkspace.shared.open(coffee)
            default: break
            }
        }
        // Allo scadere delle 8 ore, se nessuno l'ha chiusa, torna (senza aprirsi di nuovo da sola).
        refresh?.cancel()
        let again = DispatchWorkItem { if UserDefaults.standard.bool(forKey: pendingKey) { show(expand: false) } }
        refresh = again
        DispatchQueue.main.asyncAfter(deadline: .now() + ActivitySchema.maxSeconds - 30, execute: again)
    }

    private static func close() {
        UserDefaults.standard.set(false, forKey: pendingKey)
        refresh?.cancel()
        refresh = nil
        SystemActivity.end(activityID)
    }
}
