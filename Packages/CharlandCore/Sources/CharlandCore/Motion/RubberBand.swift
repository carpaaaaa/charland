import Foundation

/// L'elastico dei bordi, con la formula di UIScrollView:
/// oltre il limite lo spostamento rallenta e tende a `dimension` senza mai raggiungerla.
public enum RubberBand {
    public static let coefficient = 0.55

    /// Di quanto si sposta davvero una cosa trascinata di `overshoot` oltre il limite.
    public static func offset(overshoot: Double, dimension: Double, coefficient: Double = RubberBand.coefficient) -> Double {
        guard dimension > 0 else { return 0 }
        let x = abs(overshoot)
        let moved = (1 - 1 / (x * coefficient / dimension + 1)) * dimension
        return overshoot < 0 ? -moved : moved
    }

    /// Un livello da slider: dentro 0...1 passa com'è, fuori viene frenato dall'elastico.
    /// `dimension` è la lunghezza della pillola, nella stessa unità del livello (1 = tutta la corsa).
    public static func level(_ raw: Double, dimension: Double = 1) -> Double {
        if raw < 0 { return offset(overshoot: raw, dimension: dimension) }
        if raw > 1 { return 1 + offset(overshoot: raw - 1, dimension: dimension) }
        return raw
    }

    /// Quanto si assottiglia la pillola mentre si allunga oltre il limite: fino al 12%.
    public static func thinning(stretch: Double, dimension: Double) -> Double {
        guard dimension > 0 else { return 0 }
        return min(0.12, abs(stretch) / dimension * 0.6)
    }
}
