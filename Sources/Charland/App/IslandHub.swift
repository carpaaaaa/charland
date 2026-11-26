import AppKit
import CharlandCore

/// Tiene un'isola per ogni schermo e sceglie quella dove mostrare le attività:
/// lo schermo con il notch se c'è, altrimenti quello principale.
@MainActor
final class IslandHub {
    static let shared = IslandHub()

    private(set) var islands: [IslandController] = []
    private var space: OverlaySpace?
    var simulateNotchless = false
    /// Quante volte è nato lo Space dell'isola.
    private var spaceBirths = 0

    private init() {}

    /// Quale Space dell'isola c'è adesso: 0 se non ce n'è. Chi tiene una finestra a lungo (la goccia del timer, gli
    /// appunti, il nome del timer) si ricorda il numero che ha avuto da `adopt` e la rifà se cambia: una finestra
    /// rimasta in uno Space distrutto non compare più.
    var spaceToken: Int { space == nil ? 0 : spaceBirths }

    func start() {
        guard space == nil else { return }
        space = OverlaySpace()
        if space != nil { spaceBirths += 1 }
        rebuild()
        guard screensObserver == nil else { return }
        screensObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                                                 object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.rebuild() }
        }
    }

    private var screensObserver: NSObjectProtocol?

    /// Una finestra che deve restare ferma come l'isola nei gesti fra scrivanie (lo slider sul bordo).
    /// Va chiamata prima che la finestra compaia la prima volta. Risponde con `spaceToken` (0: niente Space, la
    /// finestra resta normale).
    ///
    /// Anche la goccia del timer, gli appunti e il nome del timer ci stanno: una finestra «su tutte le scrivanie»
    /// tenuta nascosta a lungo restava legata alle scrivanie di quando era nata, e su una scrivania nuova (o dopo un
    /// cambio di scrivanie) non compariva più, senza nessun errore: carpa (22 novembre 2026) tirava giù la farfalla e
    /// non vedeva né il filo né gli appunti, mentre l'isola, che sta qui dentro, c'era.
    @discardableResult
    func adopt(_ window: NSWindow) -> Int {
        guard let space else { return 0 }
        space.adopt(window)
        return spaceToken
    }

    /// L'isola principale.
    var primary: IslandController? {
        islands.first { $0.geometry.metrics.hasNotch } ?? islands.first
    }

    /// Qualcosa che la casa mostra è cambiato (il vassoio si è riempito o svuotato): con la casa aperta, l'isola si
    /// adegua subito, con la stessa molla delle tessere.
    func homeChanged() {
        for island in islands { island.engine.refreshOpenHome() }
    }

    /// Ricostruisce le isole quando gli schermi cambiano (collegato un monitor, cambio di risoluzione, risveglio).
    func rebuild() {
        // A isole spente un monitor collegato non deve farle rinascere.
        guard space != nil else { return }
        let current = NSScreen.screens.map { ScreenGeometry(screen: $0, simulateNotchless: simulateNotchless) }
        if current == islands.map(\.geometry) { return }
        if ProcessInfo.processInfo.environment["CHARLAND_TRACE"] != nil { print("[schermi] isole ricreate"); fflush(stdout) }
        // Le attività in corso (musica, agenti, timer, quelle dell'API) passano all'isola nuova. Chi le pubblica
        // ricorda di averle già mostrate e da lì in poi le aggiorna soltanto: nell'isola appena creata, vuota, quegli
        // aggiornamenti cadevano nel nulla, e collegando un monitor la musica spariva dal notch finché non si fermava.
        let carried: [(IslandActivity, ActivityContent)] = primary.map { old in
            old.engine.state.activities.compactMap { activity in old.model.contents[activity.id].map { (activity, $0) } }
        } ?? []
        islands.forEach { $0.close() }
        islands = NSScreen.screens.map { IslandController(screen: $0, space: space, simulateNotchless: simulateNotchless) }
        if let engine = primary?.engine {
            for (activity, content) in carried { engine.show(activity, content: content) }
        }
        onRebuild?()
    }

    /// Dopo che le isole sono state ricreate: chi aveva messo agganci su quelle vecchie li rimette (`AppServices`).
    var onRebuild: (() -> Void)?

    func stop() {
        islands.forEach { $0.close() }
        islands = []
        space?.close()
        space = nil
    }
}
