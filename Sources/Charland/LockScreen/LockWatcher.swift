import AppKit

/// Sa quando lo schermo è bloccato, quando si sblocca e quando lo schermo si spegne.
///
/// Gli avvisi `com.apple.screenIsLocked` / `screenIsUnlocked` non sono un'API promessa da Apple e quello di sblocco a
/// volte arriva tardi: finché siamo bloccati ricontrolliamo lo stato della sessione ogni mezzo secondo, così le
/// finestre del blocco non restano mai sulla scrivania.
@MainActor
final class LockWatcher {
    var onLock: (() -> Void)?
    var onUnlock: (() -> Void)?
    /// Lo schermo si è spento o riacceso: da spento non si anima niente.
    var onDisplay: ((_ awake: Bool) -> Void)?

    private(set) var isLocked = false
    private(set) var displayAwake = true
    private var poll: Timer?
    private var observers: [NSObjectProtocol] = []

    static var sessionIsLocked: Bool {
        ((CGSessionCopyCurrentDictionary() as? [String: Any])?["CGSSessionScreenIsLocked"] as? Bool) ?? false
    }

    func start() {
        guard observers.isEmpty else { return }
        let dnc = DistributedNotificationCenter.default()
        observers.append(dnc.addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.setLocked(true) }
        })
        observers.append(dnc.addObserver(forName: .init("com.apple.screenIsUnlocked"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.setLocked(false) }
        })
        let wnc = NSWorkspace.shared.notificationCenter
        observers.append(wnc.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.setAwake(false) }
        })
        observers.append(wnc.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.setAwake(true) }
        })
        // Un altro utente ha preso lo schermo: per noi è come uno sblocco, le finestre rientrano.
        observers.append(wnc.addObserver(forName: NSWorkspace.sessionDidResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.setLocked(false) }
        })
        if Self.sessionIsLocked { setLocked(true) }
    }

    func stop() {
        let dnc = DistributedNotificationCenter.default(), wnc = NSWorkspace.shared.notificationCenter
        for o in observers { dnc.removeObserver(o); wnc.removeObserver(o) }
        observers.removeAll()
        poll?.invalidate(); poll = nil
        if isLocked { isLocked = false; onUnlock?() }
    }

    private func setLocked(_ locked: Bool) {
        guard locked != isLocked else { return }
        isLocked = locked
        poll?.invalidate(); poll = nil
        if locked {
            onLock?()
            poll = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.isLocked, !Self.sessionIsLocked else { return }
                    self.setLocked(false)
                }
            }
        } else {
            onUnlock?()
        }
    }

    private func setAwake(_ awake: Bool) {
        guard awake != displayAwake else { return }
        displayAwake = awake
        onDisplay?(awake)
    }
}

/// Dice se da poco è stato premuto un tasto, senza sapere quale: serve a richiudere la copertina aperta
/// appena si comincia a scrivere la password (provato a schermo bloccato il 18 novembre 2026).
enum KeyActivity {
    static var secondsSinceLastKey: Double {
        CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .keyDown)
    }
}
