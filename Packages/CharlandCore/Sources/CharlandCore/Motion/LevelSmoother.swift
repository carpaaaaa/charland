import Foundation

/// Ammorbidisce il volume della voce: sale in fretta (attacco 30 ms) e scende piano (rilascio 180 ms),
/// così la linea della voce segue le parole senza tremare.
public struct LevelSmoother: Sendable {
    public var attack: Double
    public var release: Double
    public private(set) var level: Double = 0

    public init(attack: Double = 0.030, release: Double = 0.180) {
        self.attack = attack
        self.release = release
    }

    /// `input` è il volume grezzo fra 0 e 1; `dt` il tempo passato dall'ultimo campione.
    @discardableResult
    public mutating func feed(_ input: Double, dt: Double) -> Double {
        let target = min(1, max(0, input))
        let tau = target > level ? attack : release
        let k = 1 - exp(-max(0, dt) / max(0.0001, tau))
        level += (target - level) * k
        if level < 0.0005 { level = 0 }
        return level
    }

    public mutating func reset() { level = 0 }

    /// Da ampiezza RMS (0...1) a livello percepito: la voce normale sta attorno a 0,02-0,2 di RMS,
    /// quindi si lavora in decibel fra -50 e -12.
    public static func perceived(rms: Double) -> Double {
        guard rms > 0 else { return 0 }
        let db = 20 * log10(rms)
        return min(1, max(0, (db + 50) / 38))
    }
}
