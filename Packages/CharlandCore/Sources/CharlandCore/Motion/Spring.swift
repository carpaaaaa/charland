import Foundation

/// Una molla smorzata, risolta in forma esatta: stabile con qualsiasi passo di tempo,
/// quindi un fotogramma lungo non la fa esplodere né saltare.
/// `response` e `damping` hanno lo stesso significato di `spring(response:dampingFraction:)`.
public struct Spring: Sendable, Equatable {
    public var response: Double
    public var damping: Double

    public init(response: Double, damping: Double) {
        self.response = max(0.01, response)
        self.damping = max(0.01, damping)
    }

    /// La molla della forma dell'isola (valori di partenza, li tara carpa).
    public static let shape = Spring(response: 0.42, damping: 0.82)
    /// Più vivace: il ritorno dell'elastico degli slider.
    public static let lively = Spring(response: 0.30, damping: 0.62)
    /// Rapida e senza rimbalzo: contenuti che escono, valori che inseguono.
    public static let quick = Spring(response: 0.18, damping: 1.0)

    /// Avanza di `dt` secondi verso `target`.
    public func step(value: inout Double, velocity: inout Double, target: Double, dt: Double) {
        guard dt > 0 else { return }
        let w0 = 2 * Double.pi / response
        let y0 = value - target
        let v0 = velocity
        let y: Double
        let v: Double
        if damping < 0.9999 {
            let a = damping * w0
            let wd = w0 * (1 - damping * damping).squareRoot()
            let e = exp(-a * dt)
            let c = cos(wd * dt)
            let s = sin(wd * dt)
            let b = (v0 + a * y0) / wd
            y = e * (y0 * c + b * s)
            v = e * (v0 * c - ((a * v0 + w0 * w0 * y0) / wd) * s)
        } else if damping <= 1.0001 {
            let e = exp(-w0 * dt)
            let k = v0 + w0 * y0
            y = e * (y0 + k * dt)
            v = e * (v0 - w0 * k * dt)
        } else {
            let root = (damping * damping - 1).squareRoot()
            let r1 = -w0 * (damping - root)
            let r2 = -w0 * (damping + root)
            let c2 = (v0 - r1 * y0) / (r2 - r1)
            let c1 = y0 - c2
            let e1 = exp(r1 * dt)
            let e2 = exp(r2 * dt)
            y = c1 * e1 + c2 * e2
            v = c1 * r1 * e1 + c2 * r2 * e2
        }
        value = target + y
        velocity = v
    }
}

/// Un numero guidato da una molla. È il mattone di tutto il movimento:
/// ogni cosa che si vede nell'isola è funzione di un insieme di questi.
public struct Animated: Sendable, Equatable {
    public var value: Double
    public var velocity: Double
    public var target: Double
    public var spring: Spring
    /// Sotto queste soglie il valore si considera arrivato e viene messo esattamente sul bersaglio,
    /// così non restano code dopo la fine.
    public var restDistance: Double
    public var restSpeed: Double

    public init(_ value: Double, spring: Spring = .shape, restDistance: Double = 0.01, restSpeed: Double = 0.2) {
        self.value = value
        self.velocity = 0
        self.target = value
        self.spring = spring
        self.restDistance = restDistance
        self.restSpeed = restSpeed
    }

    public var isSettled: Bool { value == target && velocity == 0 }

    /// Porta subito sul valore, senza animazione.
    public mutating func snap(to newValue: Double) {
        value = newValue
        target = newValue
        velocity = 0
    }

    /// Avanza di `dt`. Restituisce `true` se si sta ancora muovendo.
    @discardableResult
    public mutating func step(dt: Double) -> Bool {
        if isSettled { return false }
        spring.step(value: &value, velocity: &velocity, target: target, dt: dt)
        if abs(value - target) < restDistance, abs(velocity) < restSpeed {
            value = target
            velocity = 0
            return false
        }
        return true
    }
}
