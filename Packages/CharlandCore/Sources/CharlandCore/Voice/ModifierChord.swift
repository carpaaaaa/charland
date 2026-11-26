import Foundation

/// Una scorciatoia fatta solo di modificatori, come ⌃⌥ tenuti insieme: niente lettera.
///
/// Il sistema non sa registrarla come scorciatoia, quindi la si riconosce dai cambi dei modificatori. La regola:
/// il gesto comincia quando i modificatori premuti diventano esattamente quelli scelti, e finisce quando se ne
/// lascia uno. Se intanto si preme un altro tasto (⌃⌥A per Mantieni attivo, ⌃⌥← per spostare una finestra) o si
/// aggiunge un altro modificatore, quei modificatori servivano a un'altra scorciatoia: niente dettatura, e si
/// riarma solo dopo averli lasciati. È pura: riceve i modificatori e il tempo, restituisce cosa fare.
public struct ModifierChord: Sendable, Equatable {
    public enum Action: Sendable, Equatable {
        /// Premuti esattamente i modificatori scelti.
        case down
        /// Lasciati, senza altri tasti in mezzo.
        case up
        /// Servivano a un'altra scorciatoia: annullare.
        case other
    }

    /// I modificatori scelti, come insieme di bit (gli stessi delle scorciatoie di sistema o di AppKit: basta che
    /// chi chiama usi sempre lo stesso formato).
    public let target: UInt
    public private(set) var held = false
    /// Mentre era tenuto è arrivato un altro tasto: il rilascio non vale.
    public private(set) var spoiled = false
    /// Dopo un'altra scorciatoia i modificatori vanno lasciati prima di poter ricominciare.
    public private(set) var needsRelease = false
    /// Da quando è tenuto.
    public private(set) var since = 0.0

    public init(target: UInt) {
        self.target = target
    }

    /// I modificatori premuti sono cambiati. `secondsSinceInput` sono i secondi dall'ultimo tasto o clic del Mac,
    /// letti dal sistema: se sono meno del tempo tenuto, nel mezzo è stato premuto qualcosa (anche un tasto che
    /// un'altra app ha preso per sé, che come evento non si vede).
    public mutating func flags(_ bits: UInt, now: Double, secondsSinceInput: Double? = nil) -> Action? {
        let containsTarget = bits & target == target
        if needsRelease {
            if !containsTarget { needsRelease = false }
            return nil
        }
        if !held {
            if bits == target {
                held = true
                spoiled = false
                since = now
                return .down
            }
            // altri modificatori insieme a quelli scelti (⌃⌥⇧ premuti in un altro ordine): è un'altra scorciatoia
            if containsTarget { needsRelease = true }
            return nil
        }
        guard bits != target else { return nil }
        held = false
        let wasSpoiled = spoiled
        spoiled = false
        if containsTarget {
            // si è aggiunto un modificatore: ⌃⌥⇧ è un'altra scorciatoia
            needsRelease = true
            return wasSpoiled ? nil : .other
        }
        if wasSpoiled { return nil }
        if let seconds = secondsSinceInput, seconds < now - since - 0.005 { return .other }
        return .up
    }

    /// Un altro tasto o un clic mentre i modificatori sono tenuti.
    public mutating func otherInput() -> Action? {
        guard held, !spoiled else { return nil }
        spoiled = true
        return .other
    }

    /// Ancora tenuto e pulito: nessun altro tasto da quando è cominciato.
    public func isClean(now: Double, secondsSinceInput: Double? = nil) -> Bool {
        guard held, !spoiled else { return false }
        if let seconds = secondsSinceInput, seconds < now - since - 0.005 { return false }
        return true
    }
}
