import AppKit
import os
import Synchronization

/// Il paracadute del blocco schermo (proposto dalla sessione «Charland e sito: analisi lancio» il 19 novembre 2026;
/// carpa: «Sì, fallo»).
///
/// Sul blocco le finestre di Charland stanno sopra quella di loginwindow (`LockSpace`, `LockPanel`). Se il thread
/// principale di Charland si fermasse lì sopra, la scena resterebbe ferma davanti a orologio e password finché il
/// processo non muore. Per questo:
/// - mentre il Mac è bloccato il thread principale batte quattro volte al secondo (`beat`);
/// - una sentinella su un thread suo guarda il battito due volte al secondo, solo a schermo acceso e dopo qualche
///   secondo dal risveglio (i timer possono ripartire in ritardo, e a schermo spento macOS li rallenta);
/// - se il battito manca da `silence`, la sentinella nasconde lo Space del blocco con una chiamata diretta al server
///   delle finestre, che non passa dal thread principale: tornano orologio e password di macOS;
/// - se dopo `lastResort` le finestre di Charland sono ancora sopra il blocco, chiude Charland: il server delle
///   finestre toglie da solo le finestre di un processo che non c'è più.
/// Al blocco dopo lo Space torna visibile (`LockScreen.lock`).
final class LockGuard: @unchecked Sendable {
    static let shared = LockGuard()

    /// Dopo quanto silenzio del thread principale, a schermo acceso, si toglie lo Space del blocco.
    static let silence: UInt64 = 4_000_000_000
    /// Quanto aspettare dopo che lo schermo si è acceso (o il paracadute armato) prima di contare.
    static let warmup: UInt64 = 3_000_000_000
    /// Se dopo averlo tolto le finestre sono ancora sopra il blocco, dopo quanto si chiude Charland.
    static let lastResort: UInt64 = 2_000_000_000
    /// Lo strato della finestra del blocco di macOS: una finestra nostra da qui in su lo copre.
    static let loginLayer = 2004

    private let beat = Atomic<UInt64>(0)
    private let armed = Atomic<Bool>(false)
    private let fired = Atomic<Bool>(false)
    private let hider = Mutex<Hider?>(nil)
    private let queue = DispatchQueue(label: "com.charstudio.charland.paracadute", qos: .userInteractive)
    private let log = Logger(subsystem: "com.charstudio.charland", category: "paracadute")
    /// Solo sul thread principale (si toccano in `arm` e `disarm`, che sono del thread principale).
    nonisolated(unsafe) private var heart: Timer?
    nonisolated(unsafe) private var sentinel: DispatchSourceTimer?
    /// Finché il paracadute è armato Charland non va a riposo (App Nap): a riposo macOS rallenta i timer, e con la
    /// musica in pausa il battito è l'unico rimasto. Un battito rallentato oltre `silence` farebbe scattare il
    /// paracadute su un'app sana. Il Mac può comunque dormire.
    nonisolated(unsafe) private var activity: NSObjectProtocol?
    /// Solo sulla coda della sentinella.
    nonisolated(unsafe) private var awakeSince: UInt64?
    nonisolated(unsafe) private var firedAt: UInt64?

    /// Come nascondere lo Space del blocco senza il thread principale (`LockSpace.hider`). Il blocco è `@Sendable`:
    /// così non appartiene al thread principale anche se nasce lì (un blocco del thread principale chiamato dalla
    /// sentinella fa chiudere l'app al primo giro: provato).
    struct Hider: Sendable {
        let run: @Sendable () -> Void
    }

    private static func now() -> UInt64 { DispatchTime.now().uptimeNanoseconds }

    /// Il paracadute è scattato in questo blocco: lo Space è nascosto.
    var didFire: Bool { fired.load(ordering: .relaxed) }

    /// Il Mac si è bloccato e la scena sta per uscire: comincia il battito, la sentinella guarda.
    @MainActor func arm(_ hide: Hider) {
        hider.withLock { $0 = hide }
        beat.store(Self.now(), ordering: .relaxed)
        fired.store(false, ordering: .relaxed)
        armed.store(true, ordering: .relaxed)
        if activity == nil {
            activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiatedAllowingIdleSystemSleep], reason: "Blocco schermo di Charland")
        }
        heart?.invalidate()
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in self?.pulse() }
        RunLoop.main.add(timer, forMode: .common)
        heart = timer
        if sentinel == nil {
            let source = DispatchSource.makeTimerSource(queue: queue)
            source.schedule(deadline: .now() + 0.5, repeating: 0.5, leeway: .milliseconds(50))
            // `@Sendable`: la sentinella gira sulla sua coda, non sul thread principale in cui nasce questo blocco
            source.setEventHandler { @Sendable [weak self] in self?.watch() }
            source.resume()
            sentinel = source
        }
    }

    /// Il Mac si è sbloccato: niente più battito, la sentinella si ferma.
    @MainActor func disarm() {
        armed.store(false, ordering: .relaxed)
        heart?.invalidate(); heart = nil
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
        activity = nil
    }

    @MainActor private func pulse() {
        beat.store(Self.now(), ordering: .relaxed)
    }

    /// La sentinella, sulla sua coda.
    private func watch() {
        guard armed.load(ordering: .relaxed) else { awakeSince = nil; firedAt = nil; return }
        let t = Self.now()
        // a schermo spento i timer di Charland possono essere rallentati da macOS: non si conta
        guard CGDisplayIsAsleep(CGMainDisplayID()) == 0 else { awakeSince = nil; return }
        let since = awakeSince ?? t
        awakeSince = since
        guard t &- since > Self.warmup else { return }
        let quiet = t &- min(t, beat.load(ordering: .relaxed))
        guard quiet > Self.silence else { return }
        if !fired.load(ordering: .relaxed) {
            fired.store(true, ordering: .relaxed)
            firedAt = t
            log.error("thread principale fermo da \(quiet / 1_000_000) ms sul blocco: tolgo lo Space del blocco")
            hider.withLock { $0 }?.run()
            return
        }
        if let at = firedAt, t &- at > Self.lastResort, coversLogin() {
            log.fault("le finestre di Charland sono ancora sopra il blocco: chiudo Charland")
            _exit(75)
        }
    }

    /// Una finestra di Charland è a schermo sopra la finestra del blocco di macOS.
    private func coversLogin() -> Bool {
        let me = getpid()
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else { return false }
        return list.contains { ($0[kCGWindowOwnerPID as String] as? Int32) == me && (($0[kCGWindowLayer as String] as? Int) ?? 0) >= Self.loginLayer }
    }
}
