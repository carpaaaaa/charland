import Foundation

/// Decide quando il puntatore "vuole" l'isola.
/// L'anteprima si apre solo se il puntatore resta sull'isola circa 120 ms oppure rallenta
/// sotto i 300 punti al secondo: chi sta solo andando alla barra dei menu passa veloce
/// e non apre niente.
public struct HoverGate: Sendable {
    public enum Decision: Sendable, Equatable {
        case none
        case entered
        case exited
    }

    public var dwell: Double
    public var slowSpeed: Double
    /// Rallentare apre solo dopo questa permanenza sull'isola.
    public var minimumSlowStay = 0.06
    public private(set) var isOpen = false
    private var insideSince: Double?
    private var lastX = 0.0
    private var lastY = 0.0
    private var lastTime: Double?

    public init(dwell: Double = 0.12, slowSpeed: Double = 300) {
        self.dwell = dwell
        self.slowSpeed = slowSpeed
    }

    /// Un movimento del puntatore. `inside` dice se è sopra la forma dell'isola.
    public mutating func pointer(inside: Bool, x: Double, y: Double, now: Double) -> Decision {
        defer {
            lastX = x
            lastY = y
            lastTime = now
        }
        guard inside else {
            insideSince = nil
            if isOpen {
                isOpen = false
                return .exited
            }
            return .none
        }
        if isOpen { return .none }
        if insideSince == nil { insideSince = now }
        // Rallenta sull'isola: la vuole. Serve un campione precedente recente per misurare.
        if let lastTime, now > lastTime, now - lastTime < 0.25 {
            let speed = hypot(x - lastX, y - lastY) / (now - lastTime)
            // Rallentare conta solo dopo un po' di permanenza: chi passa veloce e si ferma per un
            // fotogramma proprio sul notch non la apre.
            if speed < slowSpeed, now - (insideSince ?? now) >= minimumSlowStay {
                isOpen = true
                return .entered
            }
        }
        if let since = insideSince, now - since >= dwell {
            isOpen = true
            return .entered
        }
        return .none
    }

    /// Da chiamare quando scade l'attesa: il puntatore si è fermato sull'isola senza altri movimenti.
    public mutating func tick(now: Double) -> Decision {
        guard !isOpen, let since = insideSince, now - since >= dwell else { return .none }
        isOpen = true
        return .entered
    }

    /// Quando controllare di nuovo, se il puntatore non si muove più.
    public var pendingCheck: Double? {
        guard !isOpen, let since = insideSince else { return nil }
        return since + dwell
    }

    /// L'isola è già aperta sotto il puntatore (per esempio dopo aver lasciato un file).
    public mutating func forceOpen() {
        isOpen = true
        insideSince = nil
    }

    public mutating func reset() {
        isOpen = false
        insideSince = nil
        lastTime = nil
    }
}
