import AppKit
import CharlandCore
import CharlandKit

/// Una stella su GitHub, chiesta piano dopo ogni aggiornamento (carpa, 26 novembre 2026: «un reminder come su Oriel,
/// poco invasivo, che però ricordi di lasciare una stella su GitHub, magari a ogni aggiornamento»).
///
/// L'isola si apre una volta, qualche secondo dopo l'avvio di una versione nuova, con «Una stella» (su GitHub), «Un caffè» e
/// «Non chiedere». Mai alla prima installazione, mai due volte per la stessa versione, mai dopo una delle due scelte. Se la si
/// ignora se ne va da sola e torna all'aggiornamento dopo. Solo nelle build ufficiali: una copia compilata da sé, o un
/// fork, non chiede stelle per questo repository.
@MainActor
enum StarAsk {
    static let activityID = "stella"
    static let repository = URL(string: "https://github.com/carpaaaaa/charland")!
    static let coffee = URL(string: "https://buymeacoffee.com/charstudio")!

    private static let doneKey = "starAskDone"
    private static let lastVersionKey = "starAskLastVersion"

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
        guard forced || StarAskRule.shouldAsk(previous: previous, current: Identity.version, done: defaults.bool(forKey: doneKey)) else { return }
        #if !CHARLAND_OFFICIAL
        guard forced else { return }
        #endif
        // Dopo che l'isola si è sistemata, e lontano dagli avvisi dell'avvio.
        DispatchQueue.main.asyncAfter(deadline: .now() + (forced ? 2 : 8)) { show() }
    }

    /// Tre tasti, come su Oriel più il caffè (carpa, 26 novembre 2026: «metti anche buymeacoffee di fianco alla
    /// stellina»): stella, caffè e «Non chiedere». È un'attività interna: il limite di due tasti dell'API non vale,
    /// l'isola li mette su due righe.
    static var actions: [ActivityMessage.Action] {
        [.init(id: "stella", title: String(localized: "Una stella")),
         .init(id: "caffe", title: String(localized: "Un caffè")),
         .init(id: "mai", title: String(localized: "Non chiedere"))]
    }

    static func show() {
        var m = SystemActivity.message(activityID, template: .status, title: String(localized: "Ti piace Charland?"))
        m.subtitle = String(localized: "Una stella su GitHub aiuta altri a trovarla")
        m.symbol = "star.fill"
        m.tint = "yellow"
        // Poco invasiva: niente tocco sul trackpad né suono, e se ne va da sola.
        m.ttl = 16
        m.alert = .init(expand: true)
        m.actions = actions
        SystemActivity.show(m) { action in
            SystemActivity.end(activityID)
            switch action {
            case "stella":
                UserDefaults.standard.set(true, forKey: doneKey)
                NSWorkspace.shared.open(repository)
            case "caffe":
                UserDefaults.standard.set(true, forKey: doneKey)
                NSWorkspace.shared.open(coffee)
            case "mai":
                UserDefaults.standard.set(true, forKey: doneKey)
            default:
                break
            }
        }
    }
}
