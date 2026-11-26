import Foundation
@testable import CharlandCore

/// Il tracciatore com'era fino al 17 novembre, copiato tale e quale.
/// Serve solo ai test: il contorno nuovo deve restare questo, al ventesimo di punto.
struct LegacyContourTracer: Sendable {
    var cell: Double
    var coarse: Int
    var slack: Double

    init(cell: Double = 0.5, coarse: Int = 8, slack: Double = 1.5) {
        self.cell = cell
        self.coarse = max(1, coarse)
        self.slack = slack
    }

    func trace<F: ScalarField>(_ field: F, minX: Double, minY: Double, maxX: Double, maxY: Double) -> [[ContourPoint]] {
        let nx = max(1, Int(((maxX - minX) / cell).rounded(.up)))
        let ny = max(1, Int(((maxY - minY) / cell).rounded(.up)))
        let stride = nx + 1
        var values = [Float](repeating: .nan, count: stride * (ny + 1))
        let cnx = (nx + coarse - 1) / coarse
        let cny = (ny + coarse - 1) / coarse
        let coarseSize = Double(coarse) * cell
        let reach = coarseSize * 0.7072 + slack

        var segments: [Int: (end: Int, point: ContourPoint)] = [:]
        segments.reserveCapacity(2048)
        var startPoints: [Int: ContourPoint] = [:]
        startPoints.reserveCapacity(2048)

        for cj in 0..<cny {
            for ci in 0..<cnx {
                let i0 = ci * coarse
                let j0 = cj * coarse
                let i1 = min(nx, i0 + coarse)
                let j1 = min(ny, j0 + coarse)
                let cx = minX + (Double(i0) + Double(i1)) * 0.5 * cell
                let cy = minY + (Double(j0) + Double(j1)) * 0.5 * cell
                if abs(field.value(x: cx, y: cy)) > reach { continue }

                for j in j0...j1 {
                    let y = minY + Double(j) * cell
                    for i in i0...i1 {
                        let index = j * stride + i
                        if values[index].isNaN {
                            values[index] = Float(field.value(x: minX + Double(i) * cell, y: y))
                        }
                    }
                }

                for j in j0..<j1 {
                    for i in i0..<i1 {
                        let a = values[j * stride + i]
                        let b = values[j * stride + i + 1]
                        let c = values[(j + 1) * stride + i + 1]
                        let d = values[(j + 1) * stride + i]
                        let ina = a < 0, inb = b < 0, inc = c < 0, ind = d < 0
                        if ina == inb, inb == inc, inc == ind { continue }

                        var ins: [(order: Int, key: Int, point: ContourPoint)] = []
                        var outs: [(order: Int, key: Int, point: ContourPoint)] = []
                        let x0 = minX + Double(i) * cell
                        let y0 = minY + Double(j) * cell

                        func cross(_ order: Int, _ from: Float, _ to: Float, _ fromIn: Bool, _ toIn: Bool) {
                            guard fromIn != toIn else { return }
                            let t = Double(from / (from - to))
                            let key: Int
                            let p: ContourPoint
                            switch order {
                            case 0:
                                key = (j * stride + i) * 2
                                p = ContourPoint(x: x0 + t * cell, y: y0)
                            case 1:
                                key = (j * stride + i + 1) * 2 + 1
                                p = ContourPoint(x: x0 + cell, y: y0 + t * cell)
                            case 2:
                                key = ((j + 1) * stride + i) * 2
                                p = ContourPoint(x: x0 + cell - t * cell, y: y0 + cell)
                            default:
                                key = (j * stride + i) * 2 + 1
                                p = ContourPoint(x: x0, y: y0 + cell - t * cell)
                            }
                            if toIn { ins.append((order, key, p)) } else { outs.append((order, key, p)) }
                        }
                        cross(0, a, b, ina, inb)
                        cross(1, b, c, inb, inc)
                        cross(2, c, d, inc, ind)
                        cross(3, d, a, ind, ina)

                        if outs.count == 1, ins.count == 1 {
                            segments[outs[0].key] = (ins[0].key, ins[0].point)
                            startPoints[outs[0].key] = outs[0].point
                        } else if outs.count == 2, ins.count == 2 {
                            let centerInside = (a + b + c + d) < 0
                            for o in outs {
                                let wanted = centerInside ? (o.order + 1) % 4 : (o.order + 3) % 4
                                if let target = ins.first(where: { $0.order == wanted }) {
                                    segments[o.key] = (target.key, target.point)
                                    startPoints[o.key] = o.point
                                }
                            }
                        }
                    }
                }
            }
        }

        var loops: [[ContourPoint]] = []
        var remaining = segments
        while let (startKey, _) = remaining.first {
            var loop: [ContourPoint] = []
            var key = startKey
            var closed = false
            while let next = remaining.removeValue(forKey: key) {
                if let p = startPoints[key] { loop.append(p) }
                key = next.end
                if key == startKey {
                    closed = true
                    break
                }
            }
            if closed, loop.count >= 3, abs(ContourTracer.signedArea(loop)) >= 0.5 {
                loops.append(loop)
            }
        }
        loops.sort { $0.count > $1.count }
        return loops
    }

    func trace(_ shape: IslandShape) -> [[ContourPoint]] {
        let b = shape.bounds()
        return trace(LegacyIslandField(shape), minX: b.minX, minY: b.minY, maxX: b.maxX, maxY: b.maxY)
    }
}

/// Il campo dell'isola com'era fino al 17 novembre, copiato tale e quale (con i conti rifatti a ogni punto).
struct LegacyIslandField: ScalarField, Sendable {
    let minX: Double
    let maxX: Double
    let bottom: Double
    let radius: Double
    let flare: Double
    let wave: Double
    let wavePhase: Double
    let blobs: [Blob]
    /// Quanto il corpo continua sopra lo schermo, così il bordo alto non si vede mai.
    static let overshoot = 40.0
    /// Di quanto il contorno si chiude sopra il bordo dello schermo.
    static let topClip = 0.25

    init(_ shape: IslandShape) {
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
        blobs = shape.blobs.filter(\.isVisible)
    }

    func value(x: Double, y: Double) -> Double {
        var d = body(x: x, y: y)
        // Le gocce si fondono solo con il corpo. I raccordi in alto si aggiungono dopo, senza
        // fusione: altrimenti una goccia vicina si attacca anche al raccordo e fra i due
        // si chiude una sacca vuota che lampeggia per qualche fotogramma.
        for b in blobs {
            let bd = Self.roundedBox(px: x - b.x, py: y - b.y, hx: b.halfWidth, hy: b.halfHeight,
                                     r: min(b.radius, b.halfWidth, b.halfHeight))
            d = Self.smoothMin(d, bd, k: b.blend)
        }
        if flare > 0.01 {
            d = min(d, flareField(x: x, y: y, edge: minX, sign: -1))
            d = min(d, flareField(x: x, y: y, edge: maxX, sign: 1))
        }
        // Tutto quello che sta sopra lo schermo non esiste: il contorno si chiude un quarto
        // di punto sopra il bordo, fuori dalla finestra, così la riga y = 0 resta piena
        // e le punte dei raccordi arrivano fino in fondo.
        return max(d, -y - Self.topClip)
    }

    /// Il corpo: un rettangolo attaccato al bordo alto, con gli angoli in basso arrotondati
    /// e il bordo basso che può respirare con la voce.
    func body(x: Double, y: Double) -> Double {
        var yy = y
        if wave != 0 {
            // Sposta solo la fascia più bassa, e sfuma a zero verso gli angoli,
            // così gli angoli restano quelli di sempre.
            let span = maxX - minX
            let u = (x - minX) / max(1, span)
            let window = Self.smoothstep(0.04, 0.26, u) * Self.smoothstep(0.04, 0.26, 1 - u)
            let lift = Self.smoothstep(bottom - 16, bottom, y)
            let ripple = sin(u * 5.2 + wavePhase) * 0.6 + sin(u * 9.7 - wavePhase * 1.3) * 0.4
            yy = y - wave * ripple * window * lift
        }
        let cx = (minX + maxX) / 2
        let hx = (maxX - minX) / 2
        let top = -Self.overshoot
        let cy = (top + bottom) / 2
        let hy = (bottom - top) / 2
        return Self.roundedBox(px: x - cx, py: yy - cy, hx: hx, hy: hy, r: radius)
    }

    /// Un raccordo rovesciato in alto: un quadratino meno un cerchio.
    /// `sign` è -1 per il lato sinistro, +1 per il destro.
    func flareField(x: Double, y: Double, edge: Double, sign: Double) -> Double {
        let f = flare
        // Il quadratino entra di 2 punti nel corpo, così l'unione non lascia fessure.
        let x0 = sign < 0 ? edge - f : edge - 2
        let x1 = sign < 0 ? edge + 2 : edge + f
        let top = -Self.overshoot
        let square = Self.box(px: x - (x0 + x1) / 2, py: y - (top + f) / 2,
                              hx: (x1 - x0) / 2, hy: (f - top) / 2)
        let cx = edge + sign * f
        let circle = ((x - cx) * (x - cx) + (y - f) * (y - f)).squareRoot() - f
        return max(square, -circle)
    }

    // MARK: Mattoni

    static func box(px: Double, py: Double, hx: Double, hy: Double) -> Double {
        let qx = abs(px) - hx
        let qy = abs(py) - hy
        let ox = max(qx, 0)
        let oy = max(qy, 0)
        return (ox * ox + oy * oy).squareRoot() + min(max(qx, qy), 0)
    }

    static func roundedBox(px: Double, py: Double, hx: Double, hy: Double, r: Double) -> Double {
        let qx = abs(px) - hx + r
        let qy = abs(py) - hy + r
        let ox = max(qx, 0)
        let oy = max(qy, 0)
        return (ox * ox + oy * oy).squareRoot() + min(max(qx, qy), 0) - r
    }

    /// Minimo morbido quadratico: sotto `k` di distanza le due forme si fondono con un collo.
    static func smoothMin(_ a: Double, _ b: Double, k: Double) -> Double {
        guard k > 0.0001 else { return min(a, b) }
        let h = max(k - abs(a - b), 0) / k
        return min(a, b) - h * h * k * 0.25
    }

    static func smoothstep(_ e0: Double, _ e1: Double, _ x: Double) -> Double {
        let t = min(1, max(0, (x - e0) / (e1 - e0)))
        return t * t * (3 - 2 * t)
    }

    /// Il puntatore è sull'isola? `margin` allarga la zona sensibile.
    func contains(x: Double, y: Double, margin: Double = 0) -> Bool {
        value(x: x, y: y) <= margin
    }
}
