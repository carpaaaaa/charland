import Foundation

/// Le misure del notch e dello schermo, lette dal sistema.
/// Tutte le coordinate dell'isola sono in punti, con x = 0 al centro del notch,
/// y = 0 sul bordo alto dello schermo e y che cresce verso il basso.
public struct IslandMetrics: Sendable, Equatable {
    /// Larghezza del notch vero (o della pillola finta sui Mac senza notch).
    public var notchWidth: Double
    /// Altezza del notch: è anche l'altezza della fascia della fotocamera, sempre nera.
    public var notchHeight: Double
    public var screenWidth: Double
    public var hasNotch: Bool

    public init(notchWidth: Double, notchHeight: Double, screenWidth: Double, hasNotch: Bool = true) {
        self.notchWidth = notchWidth
        self.notchHeight = notchHeight
        self.screenWidth = screenWidth
        self.hasNotch = hasNotch
    }

    /// MacBook Air 15" M5 di carpa: notch 185 × 33,5 su 1710 punti.
    public static let air15 = IslandMetrics(notchWidth: 185, notchHeight: 33.5, screenWidth: 1710)
    /// Mac senza notch: una pillola finta in alto al centro.
    public static func notchless(screenWidth: Double, menuBarHeight: Double = 24) -> IslandMetrics {
        IslandMetrics(notchWidth: 150, notchHeight: menuBarHeight, screenWidth: screenWidth, hasNotch: false)
    }

    public var halfNotch: Double { notchWidth / 2 }
}

/// Una goccia: un rettangolo arrotondato che si fonde con il corpo attraverso un collo liquido.
public struct Blob: Sendable, Equatable {
    public var x: Double
    public var y: Double
    public var halfWidth: Double
    public var halfHeight: Double
    public var radius: Double
    /// Raggio di fusione: quanto da lontano la goccia "sente" il corpo.
    /// Il collo esiste finché la distanza fra le due superfici è minore di metà di questo valore.
    public var blend: Double

    public init(x: Double = 0, y: Double = 0, halfWidth: Double = 0, halfHeight: Double = 0, radius: Double = 0, blend: Double = 0) {
        self.x = x
        self.y = y
        self.halfWidth = halfWidth
        self.halfHeight = halfHeight
        self.radius = radius
        self.blend = blend
    }

    /// Una goccia che non si vede: sta dentro il corpo, con misura zero.
    public static let hidden = Blob()
    public var isVisible: Bool { halfWidth > 0.05 && halfHeight > 0.05 }
}

/// I ruoli fissi delle gocce. Avere posti fissi rende ogni fotogramma un semplice vettore di numeri.
public enum BlobSlot: Int, CaseIterable, Sendable {
    /// La seconda attività, staccata a destra.
    case minimal = 0
    /// La goccia della dettatura che cola verso il cursore.
    case drip = 1
    /// La protuberanza che va incontro al file trascinato.
    case magnet = 2
    /// La terza attività, staccata a sinistra: lo specchio di `minimal`.
    case minimalLeading = 3
}

/// La forma dell'isola in un istante. È un valore puro: la disegna `IslandField`.
public struct IslandShape: Sendable, Equatable {
    /// Bordo sinistro e destro del corpo, come distanza dal centro del notch (entrambi positivi).
    public var left: Double
    public var right: Double
    /// Bordo basso del corpo.
    public var height: Double
    /// Raggio degli angoli in basso.
    public var radius: Double
    /// Raggio dei due raccordi rovesciati in alto.
    public var flare: Double
    /// Ampiezza del respiro del bordo basso (punti). Zero = bordo dritto.
    public var wave: Double
    /// Fase del respiro, avanza col tempo mentre c'è voce.
    public var wavePhase: Double
    /// Schiacciamento da pressione: 0 a riposo, 1 premuto.
    public var press: Double
    public var blobs: [Blob]

    public init(left: Double, right: Double, height: Double, radius: Double, flare: Double,
                wave: Double = 0, wavePhase: Double = 0, press: Double = 0,
                blobs: [Blob] = Array(repeating: .hidden, count: BlobSlot.allCases.count)) {
        self.left = left
        self.right = right
        self.height = height
        self.radius = radius
        self.flare = flare
        self.wave = wave
        self.wavePhase = wavePhase
        self.press = press
        self.blobs = blobs
    }

    public subscript(slot: BlobSlot) -> Blob {
        get { blobs[slot.rawValue] }
        set { blobs[slot.rawValue] = newValue }
    }

    /// La forma a riposo: esattamente il notch.
    public static func resting(_ m: IslandMetrics) -> IslandShape {
        IslandShape(left: m.halfNotch, right: m.halfNotch, height: m.notchHeight,
                    radius: IslandShape.restRadius, flare: IslandShape.restFlare)
    }

    /// Angoli in basso del notch vero.
    public static let restRadius = 9.0
    /// A riposo non ci sono raccordi: crescono da zero quando l'isola si apre,
    /// così non compaiono di colpo accanto al notch.
    public static let restFlare = 0.0

    /// Il rettangolo che contiene tutta la forma, con un margine.
    public func bounds(margin: Double = 6) -> (minX: Double, minY: Double, maxX: Double, maxY: Double) {
        var minX = -left - flare
        var maxX = right + flare
        var maxY = height + abs(wave)
        for b in blobs where b.isVisible {
            minX = min(minX, b.x - b.halfWidth - b.blend * 0.25)
            maxX = max(maxX, b.x + b.halfWidth + b.blend * 0.25)
            maxY = max(maxY, b.y + b.halfHeight + b.blend * 0.25)
        }
        return (minX - margin, -0.5, maxX + margin, maxY + margin)
    }
}

// MARK: - Vettore

extension IslandShape {
    /// Quanti numeri descrivono una forma.
    public static let scalarCount = 8 + BlobSlot.allCases.count * 6

    /// La forma come vettore di numeri, per animarla con una molla per numero.
    public var scalars: [Double] {
        // Spazio riservato prima, e un numero alla volta: un solo array, niente array di passaggio.
        var out: [Double] = []
        out.reserveCapacity(Self.scalarCount)
        out.append(left); out.append(right); out.append(height); out.append(radius)
        out.append(flare); out.append(wave); out.append(wavePhase); out.append(press)
        for b in blobs {
            out.append(b.x); out.append(b.y); out.append(b.halfWidth)
            out.append(b.halfHeight); out.append(b.radius); out.append(b.blend)
        }
        return out
    }

    public init(scalars s: [Double]) {
        precondition(s.count == Self.scalarCount)
        var blobs: [Blob] = []
        blobs.reserveCapacity(BlobSlot.allCases.count)
        var i = 8
        for _ in BlobSlot.allCases {
            blobs.append(Blob(x: s[i], y: s[i + 1], halfWidth: max(0, s[i + 2]), halfHeight: max(0, s[i + 3]),
                              radius: max(0, s[i + 4]), blend: max(0, s[i + 5])))
            i += 6
        }
        self.init(left: s[0], right: s[1], height: s[2], radius: max(0, s[3]), flare: max(0, s[4]),
                  wave: s[5], wavePhase: s[6], press: s[7], blobs: blobs)
    }

    /// Nome di ogni numero, per i resoconti del controllo del movimento.
    public static let scalarNames: [String] = {
        var names = ["left", "right", "height", "radius", "flare", "wave", "wavePhase", "press"]
        for slot in BlobSlot.allCases {
            for part in ["x", "y", "halfWidth", "halfHeight", "radius", "blend"] {
                names.append("\(slot).\(part)")
            }
        }
        return names
    }()
}
