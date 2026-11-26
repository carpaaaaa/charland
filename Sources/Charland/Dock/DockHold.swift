import AppKit

/// Tiene su il Dock a scomparsa mentre è aperto il cassetto di un widget (carpa, 18 novembre 2026: «quando ci salgo col
/// cursore su quella sezione il dock non deve scomparire perché se no lascia solo i widget attivi»).
///
/// macOS abbassa il Dock appena il puntatore sale sopra la sua cima, cioè entrando nel cassetto, e da fuori non lo si
/// tiene su in modo pulito (eventi finti al Dock lo lasciano bloccato su). Per il
/// tempo del cassetto si spegne il «nascondi automaticamente» con la funzione di CoreDock che usa anche ⌥⌘D (il Dock non
/// si riavvia e non si muove: è già su), e alla chiusura si riaccende: col puntatore fuori il Dock scende, coi vassoi.
/// Se Charland cade col Dock tenuto su, al prossimo avvio lo rimette a scomparsa (`restoreAfterCrash`).
@MainActor
enum DockHold {
    private typealias Getter = @convention(c) () -> DarwinBoolean
    private typealias Setter = @convention(c) (DarwinBoolean) -> Void

    private static let library = dlopen("/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices", RTLD_NOW)
    private static let getAutohide: Getter? = dlsym(library, "CoreDockGetAutoHideEnabled").map { unsafeBitCast($0, to: Getter.self) }
    private static let setAutohide: Setter? = dlsym(library, "CoreDockSetAutoHideEnabled").map { unsafeBitCast($0, to: Setter.self) }

    /// Segnato prima di spegnere la scomparsa e tolto dopo averla riaccesa: se resta, Charland è caduta nel mezzo.
    private static let heldKey = "dockAutohideHeld"
    private(set) static var holding = false
    private static var terminateObserver: NSObjectProtocol?

    static var available: Bool { getAutohide != nil && setAutohide != nil }

    static func hold(_ on: Bool) {
        guard let getAutohide, let setAutohide else { return }
        if on {
            guard !holding, DockSettings.shared.holdsDock, getAutohide().boolValue else { return }
            UserDefaults.standard.set(true, forKey: heldKey)
            holding = true
            setAutohide(false)
            watchTermination()
        } else {
            guard holding else { return }
            holding = false
            setAutohide(true)
            UserDefaults.standard.removeObject(forKey: heldKey)
        }
    }

    /// All'avvio: se l'ultima volta Charland si è chiusa col Dock tenuto su, il Dock torna a scomparsa.
    static func restoreAfterCrash() {
        guard UserDefaults.standard.bool(forKey: heldKey), let setAutohide else { return }
        setAutohide(true)
        UserDefaults.standard.removeObject(forKey: heldKey)
    }

    /// Uscendo da Charland col cassetto aperto, il Dock torna com'era.
    private static func watchTermination() {
        guard terminateObserver == nil else { return }
        terminateObserver = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification,
                                                                   object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { DockHold.hold(false) }
        }
    }
}
