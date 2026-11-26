import Foundation

/// Un campo scalare: negativo dentro la forma, positivo fuori, zero sul bordo.
public protocol ScalarField {
    func value(x: Double, y: Double) -> Double
    /// Di quanto al massimo il campo si scosta da una distanza vera (una funzione che non cambia
    /// più in fretta della strada percorsa). `nil` = non si sa: il tracciatore usa il suo margine.
    var distortion: Double? { get }
}

extension ScalarField {
    public var distortion: Double? { nil }
}

/// Il campo di distanza dell'isola: corpo, raccordi in alto e gocce sono UNA forma sola,
/// unita con un minimo morbido. Da questo campo nascono il contorno che si disegna,
/// il ritaglio dei contenuti, il vetro e il controllo del puntatore: una sola verità.
///
/// Coordinate: x = 0 al centro del notch, y = 0 sul bordo alto dello schermo, y verso il basso.
public struct IslandField: ScalarField, Sendable {
    @usableFromInline let minX: Double
    @usableFromInline let maxX: Double
    @usableFromInline let bottom: Double
    @usableFromInline let radius: Double
    @usableFromInline let flare: Double
    @usableFromInline let wave: Double
    @usableFromInline let wavePhase: Double
    /// Le gocce visibili, col raggio già stretto dentro le loro misure.
    @usableFromInline let blobs: [Blob]
    // Misure ricavate una volta sola qui, non a ogni punto: il campo si calcola decine di
    // migliaia di volte per fotogramma. Sono gli stessi conti di prima, quindi gli stessi numeri.
    @usableFromInline let bodyCX: Double
    @usableFromInline let bodyHX: Double
    @usableFromInline let bodyCY: Double
    @usableFromInline let bodyHY: Double
    @usableFromInline let waveSpan: Double
    @usableFromInline let leftFlare: Flare
    @usableFromInline let rightFlare: Flare
    /// Quanto il corpo continua sopra lo schermo, così il bordo alto non si vede mai.
    @usableFromInline static let overshoot = 40.0
    /// Di quanto il contorno si chiude sopra il bordo dello schermo.
    public static let topClip = 0.25

    public init(_ shape: IslandShape) {
        // La pressione schiaccia appena la forma: più larga di poco, più bassa di poco.
        let squash = shape.press
        minX = -(shape.left + squash * 1.5)
        maxX = shape.right + squash * 1.5
        bottom = shape.height - squash * 1.2
        let halfW = (maxX - minX) / 2
        radius = max(0, min(shape.radius, halfW, bottom))
        flare = max(0, shape.flare)
        wave = shape.wave
        wavePhase = shape.wavePhase
        // Un solo passaggio, e nessun array se non c'è nessuna goccia (il caso più comune).
        var visible: [Blob] = []
        if shape.blobs.contains(where: \.isVisible) {
            visible.reserveCapacity(shape.blobs.count)
            for var b in shape.blobs where b.isVisible {
                b.radius = min(b.radius, b.halfWidth, b.halfHeight)
                visible.append(b)
            }
        }
        blobs = visible
        let top = -Self.overshoot
        bodyCX = (minX + maxX) / 2
        bodyHX = (maxX - minX) / 2
        bodyCY = (top + bottom) / 2
        bodyHY = (bottom - top) / 2
        waveSpan = max(1, maxX - minX)
        leftFlare = Flare(edge: minX, sign: -1, flare: flare)
        rightFlare = Flare(edge: maxX, sign: 1, flare: flare)
    }

    /// Un raccordo rovesciato in alto: un quadratino meno un cerchio, con le misure già pronte.
    @usableFromInline
    struct Flare: Sendable {
        @usableFromInline let squareX: Double
        @usableFromInline let squareY: Double
        @usableFromInline let squareHX: Double
        @usableFromInline let squareHY: Double
        @usableFromInline let circleX: Double
        @usableFromInline let radius: Double

        /// `sign` è -1 per il lato sinistro, +1 per il destro.
        init(edge: Double, sign: Double, flare f: Double) {
            // Il quadratino entra di 2 punti nel corpo, così l'unione non lascia fessure.
            let x0 = sign < 0 ? edge - f : edge - 2
            let x1 = sign < 0 ? edge + 2 : edge + f
            let top = -IslandField.overshoot
            squareX = (x0 + x1) / 2
            squareY = (top + f) / 2
            squareHX = (x1 - x0) / 2
            squareHY = (f - top) / 2
            circleX = edge + sign * f
            radius = f
        }

        /// `min(d, raccordo)`, senza calcolare il raccordo quando di sicuro non scende sotto `d`.
        @inlinable
        func lowered(_ d: Double, x: Double, y: Double) -> Double {
            let qx = abs(x - squareX) - squareHX
            let qy = abs(y - squareY) - squareHY
            // Il quadratino non vale mai meno di max(qx, qy), e il raccordo mai meno del quadratino:
            // lontano dagli angoli in alto basta un confronto, senza radici.
            if max(qx, qy) >= d { return d }
            let ox = max(qx, 0)
            let oy = max(qy, 0)
            let square = (ox * ox + oy * oy).squareRoot() + min(max(qx, qy), 0)
            if square >= d { return d }
            let circle = ((x - circleX) * (x - circleX) + (y - radius) * (y - radius)).squareRoot() - radius
            return min(d, max(square, -circle))
        }
    }

    @inlinable
    public func value(x: Double, y: Double) -> Double {
        var d = body(x: x, y: y)
        // Le gocce si fondono solo con il corpo. I raccordi in alto si aggiungono dopo, senza
        // fusione: altrimenti una goccia vicina si attacca anche al raccordo e fra i due
        // si chiude una sacca vuota che lampeggia per qualche fotogramma.
        for b in blobs {
            let qx = abs(x - b.x) - b.halfWidth + b.radius
            let qy = abs(y - b.y) - b.halfHeight + b.radius
            // La goccia non vale mai meno di max(qx, qy) - r: se così resta più in là del raggio
            // di fusione, il minimo morbido restituirebbe d tale e quale. Si salta la radice.
            let least = max(qx, qy) - b.radius
            if b.blend > 0.0001 ? least - d > b.blend : least >= d { continue }
            let ox = max(qx, 0)
            let oy = max(qy, 0)
            let bd = (ox * ox + oy * oy).squareRoot() + min(max(qx, qy), 0) - b.radius
            d = Self.smoothMin(d, bd, k: b.blend)
        }
        if flare > 0.01 {
            d = leftFlare.lowered(d, x: x, y: y)
            d = rightFlare.lowered(d, x: x, y: y)
        }
        // Tutto quello che sta sopra lo schermo non esiste: il contorno si chiude un quarto
        // di punto sopra il bordo, fuori dalla finestra, così la riga y = 0 resta piena
        // e le punte dei raccordi arrivano fino in fondo.
        return max(d, -y - Self.topClip)
    }

    /// Il corpo: un rettangolo attaccato al bordo alto, con gli angoli in basso arrotondati
    /// e il bordo basso che può respirare con la voce.
    @inlinable
    func body(x: Double, y: Double) -> Double {
        var yy = y
        if wave != 0 {
            // Sposta solo la fascia più bassa, e sfuma a zero verso gli angoli,
            // così gli angoli restano quelli di sempre.
            let lift = Self.smoothstep(bottom - 16, bottom, y)
            // Sopra la fascia bassa il respiro vale zero: niente seni da calcolare.
            if lift > 0 {
                let u = (x - minX) / waveSpan
                let window = Self.smoothstep(0.04, 0.26, u) * Self.smoothstep(0.04, 0.26, 1 - u)
                let ripple = sin(u * 5.2 + wavePhase) * 0.6 + sin(u * 9.7 - wavePhase * 1.3) * 0.4
                yy = y - wave * ripple * window * lift
            }
        }
        return Self.roundedBox(px: x - bodyCX, py: yy - bodyCY, hx: bodyHX, hy: bodyHY, r: radius)
    }

    // MARK: Mattoni

    @inlinable
    static func box(px: Double, py: Double, hx: Double, hy: Double) -> Double {
        let qx = abs(px) - hx
        let qy = abs(py) - hy
        let ox = max(qx, 0)
        let oy = max(qy, 0)
        return (ox * ox + oy * oy).squareRoot() + min(max(qx, qy), 0)
    }

    @inlinable
    static func roundedBox(px: Double, py: Double, hx: Double, hy: Double, r: Double) -> Double {
        let qx = abs(px) - hx + r
        let qy = abs(py) - hy + r
        let ox = max(qx, 0)
        let oy = max(qy, 0)
        return (ox * ox + oy * oy).squareRoot() + min(max(qx, qy), 0) - r
    }

    /// Minimo morbido quadratico: sotto `k` di distanza le due forme si fondono con un collo.
    @inlinable
    static func smoothMin(_ a: Double, _ b: Double, k: Double) -> Double {
        guard k > 0.0001 else { return min(a, b) }
        let h = max(k - abs(a - b), 0) / k
        return min(a, b) - h * h * k * 0.25
    }

    @inlinable
    static func smoothstep(_ e0: Double, _ e1: Double, _ x: Double) -> Double {
        let t = min(1, max(0, (x - e0) / (e1 - e0)))
        return t * t * (3 - 2 * t)
    }

    /// Corpo, gocce (minimo morbido), raccordi e taglio in alto sono tutte distanze vere o non
    /// crescono più in fretta di una distanza. Solo il respiro sposta il bordo basso, al massimo
    /// della sua ampiezza: il campo resta entro `wave` da una distanza vera.
    public var distortion: Double? { abs(wave) }

    /// Il puntatore è sull'isola? `margin` allarga la zona sensibile.
    public func contains(x: Double, y: Double, margin: Double = 0) -> Bool {
        value(x: x, y: y) <= margin
    }
}
