import Foundation

/// Interpreta il tasto della dettatura: tenuto premuto si detta, doppia pressione per le mani libere.
/// È pura: riceve pressioni e rilasci con il loro tempo e restituisce cosa fare.
public struct PressInterpreter: Sendable {
    public enum Action: Sendable, Equatable {
        /// Comincia ad ascoltare (l'isola si affaccia subito).
        case start
        /// Finisci e scrivi il testo.
        case commit
        /// Butta via: pressione troppo corta, o il tasto serviva ad altro.
        case cancel
        /// Passa alle mani libere: si continua ad ascoltare senza tenere premuto.
        case handsFree
    }

    public enum Phase: Sendable, Equatable {
        case idle
        /// Tasto giù, si ascolta.
        case holding(since: Double)
        /// Rilasciato dopo un tocco breve: si aspetta l'eventuale seconda pressione.
        case awaitingSecond(until: Double)
        case handsFree
    }

    /// Sotto questa durata una pressione è un tocco, non una dettatura.
    public var tapThreshold: Double
    /// Entro quanto deve arrivare la seconda pressione.
    public var doubleWindow: Double
    public private(set) var phase: Phase = .idle

    public init(tapThreshold: Double = 0.25, doubleWindow: Double = 0.35) {
        self.tapThreshold = tapThreshold
        self.doubleWindow = doubleWindow
    }

    public mutating func down(now: Double) -> Action? {
        switch phase {
        case .idle:
            phase = .holding(since: now)
            return .start
        case .holding:
            // Ripetizione del tasto tenuto premuto: niente.
            return nil
        case .awaitingSecond(let until):
            if now <= until {
                phase = .handsFree
                return .handsFree
            }
            phase = .holding(since: now)
            return .start
        case .handsFree:
            // Nelle mani libere una pressione ferma e scrive.
            phase = .idle
            return .commit
        }
    }

    public mutating func up(now: Double) -> Action? {
        switch phase {
        case .holding(let since):
            if now - since >= tapThreshold {
                phase = .idle
                return .commit
            }
            // Un tocco: l'ascolto continua, forse arriva la seconda pressione.
            phase = .awaitingSecond(until: now + doubleWindow)
            return nil
        default:
            return nil
        }
    }

    /// Il tempo che passa: scaduta l'attesa della seconda pressione, il tocco singolo si annulla.
    public mutating func tick(now: Double) -> Action? {
        if case .awaitingSecond(let until) = phase, now > until {
            phase = .idle
            return .cancel
        }
        return nil
    }

    /// Mentre il tasto è giù si preme un altro tasto (Fn + F5, per esempio): il tasto
    /// serviva da modificatore, quindi niente dettatura.
    public mutating func otherKey() -> Action? {
        if case .holding = phase {
            phase = .idle
            return .cancel
        }
        return nil
    }

    /// Esc: annulla in qualsiasi momento.
    public mutating func escape() -> Action? {
        if phase == .idle { return nil }
        phase = .idle
        return .cancel
    }

    /// Le mani libere cominciate senza tasto (dal pulsante nell'isola).
    public mutating func forceHandsFree() { phase = .handsFree }

    /// Torna a riposo senza azioni (la dettatura è stata fermata da fuori).
    public mutating func reset() { phase = .idle }

    /// Quando controllare di nuovo con `tick`.
    public var deadline: Double? {
        if case .awaitingSecond(let until) = phase { return until }
        return nil
    }
}
