import SwiftUI

/// L'atmosfera della copertina aperta: luci sfocate nei colori della copertina, grandi e piccole, che si muovono piano
/// mentre il brano suona (carpa, 18 novembre 2026: «particelle blurrate del colore dell'artwork che si muovono un po'
/// per creare ambience durante l'ascolto»). In pausa si fermano dove sono e si abbassano.
///
/// Costa poco: ogni colore è un'immagine sola di un disco sfumato, disegnata una volta al cambio brano; a ogni
/// fotogramma le luci si spostano e basta. Niente sfocature dal vivo. Si sommano al fondo come luce (non lo coprono
/// come vernice: una macchia chiara stesa sopra sembrava una ditata grigia).
/// Sono luci piatte e sfumate: niente riflessi, niente contorni, niente sfere.
struct LockAmbience: View {
    let model: LockModel

    var body: some View {
        let mix = LockModel.ease(model.trackT)
        let strength = 0.45 + 0.55 * LockModel.ease(model.playT)
        ZStack {
            // al cambio brano le luci di prima si sciolgono in quelle nuove
            if !model.oldLights.isEmpty, mix < 1 { LockAmbienceField(model: model, lights: model.oldLights, strength: strength * (1 - mix)) }
            if !model.lights.isEmpty { LockAmbienceField(model: model, lights: model.lights, strength: strength * (model.oldLights.isEmpty ? 1 : mix)) }
        }
        .frame(width: model.size.width, height: model.size.height)
        .clipped()
        .allowsHitTesting(false)
    }
}

private struct LockAmbienceField: View {
    let model: LockModel
    var lights: [LockLight]
    var strength: Double

    var body: some View {
        // `clock` scorre solo mentre suona; con «Riduci movimento» le luci restano ferme
        let t = LockMote.still ? 0 : model.live.clock
        let size = model.size, k = model.layout.k
        ZStack {
            ForEach(LockMote.all.indices, id: \.self) { i in
                let mote = LockMote.all[i]
                let light = lights[mote.color % lights.count]
                let side = mote.size * k
                Image(nsImage: light.image)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: side, height: side)
                    .opacity(light.gain(mote.glow) * mote.breath(at: t) * strength)
                    .blendMode(.plusLighter)
                    .position(mote.point(at: t, in: size))
            }
        }
        .frame(width: size.width, height: size.height)
    }
}

/// Un colore della copertina, pronto da accendere: il suo disco sfumato e quanta luce fa.
struct LockLight {
    var image: NSImage
    var luma: Double

    init(_ color: SIMD3<Double>) {
        image = LockLights.disc(color)
        luma = 0.2126 * color.x + 0.7152 * color.y + 0.0722 * color.z
    }

    /// Quanto accenderla perché al centro aggiunga `glow` di luce e non di più: un bianco va tenuto basso,
    /// un rosso scuro può salire. Così il testo bianco resta bianco qualunque sia la copertina.
    func gain(_ glow: Double) -> Double { min(0.6, glow / max(0.1, luma)) }
}

/// Una luce: dove sta, quanto è grande, quanto si muove e in quanto tempo.
struct LockMote {
    /// Il centro, in frazioni dello schermo.
    var u: Double, v: Double
    /// Il diametro in punti, sullo schermo delle misure.
    var size: CGFloat
    /// Quanta luce aggiunge al centro (da 0 a 1).
    var glow: Double
    var color: Int
    /// Di quanto si sposta, in frazioni dello schermo, e in quanti secondi fa un giro.
    var ax: Double, ay: Double
    var px: Double, py: Double
    var phase: Double

    func point(at t: Double, in size: CGSize) -> CGPoint {
        CGPoint(x: (u + ax * sin(2 * .pi * t / px + phase)) * size.width,
                y: (v + ay * cos(2 * .pi * t / py + phase * 1.7)) * size.height)
    }

    /// Respira appena: non sparisce mai.
    func breath(at t: Double) -> Double { 0.8 + 0.2 * sin(2 * .pi * t / (px * 0.43) + phase * 2.3) }

    static var still: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    /// Tre nuvole grandi e lente, cinque luci medie, cinque più piccole che girano un po' di più (mai puntini:
    /// la più piccola è larga 150 punti). Messe a mano, non a caso: così la scena è composta e non cambia da
    /// un'apertura all'altra. Vanno piano: le più svelte fanno una ventina di punti al secondo.
    static let all: [LockMote] = [
        LockMote(u: 0.15, v: 0.36, size: 860, glow: 0.11, color: 0, ax: 0.05, ay: 0.05, px: 71, py: 89, phase: 0.4),
        LockMote(u: 0.83, v: 0.60, size: 920, glow: 0.11, color: 1, ax: 0.05, ay: 0.05, px: 83, py: 67, phase: 2.1),
        LockMote(u: 0.50, v: 0.95, size: 780, glow: 0.10, color: 2, ax: 0.06, ay: 0.04, px: 61, py: 97, phase: 4.0),

        LockMote(u: 0.07, v: 0.74, size: 400, glow: 0.12, color: 1, ax: 0.05, ay: 0.07, px: 53, py: 67, phase: 1.2),
        LockMote(u: 0.37, v: 0.22, size: 340, glow: 0.10, color: 2, ax: 0.06, ay: 0.05, px: 59, py: 47, phase: 3.3),
        LockMote(u: 0.67, v: 0.36, size: 380, glow: 0.12, color: 3, ax: 0.06, ay: 0.06, px: 49, py: 71, phase: 5.1),
        LockMote(u: 0.93, v: 0.26, size: 320, glow: 0.11, color: 0, ax: 0.04, ay: 0.07, px: 67, py: 55, phase: 0.9),
        LockMote(u: 0.44, v: 0.64, size: 360, glow: 0.11, color: 3, ax: 0.07, ay: 0.05, px: 57, py: 77, phase: 2.7),

        LockMote(u: 0.25, v: 0.55, size: 190, glow: 0.12, color: 2, ax: 0.07, ay: 0.08, px: 43, py: 51, phase: 0.2),
        LockMote(u: 0.61, v: 0.80, size: 160, glow: 0.12, color: 0, ax: 0.08, ay: 0.06, px: 39, py: 59, phase: 1.9),
        LockMote(u: 0.87, v: 0.84, size: 210, glow: 0.11, color: 3, ax: 0.06, ay: 0.08, px: 47, py: 41, phase: 3.8),
        LockMote(u: 0.74, v: 0.17, size: 150, glow: 0.10, color: 1, ax: 0.07, ay: 0.06, px: 51, py: 43, phase: 5.6),
        LockMote(u: 0.12, v: 0.90, size: 170, glow: 0.11, color: 0, ax: 0.07, ay: 0.07, px: 41, py: 53, phase: 4.4),
    ]
}

enum LockLights {
    /// Le luci di una copertina: i suoi colori, ciascuno col suo disco.
    static func lights(for palette: [SIMD3<Double>]) -> [LockLight] { palette.map(LockLight.init) }

    /// Un disco di luce di un colore solo: pieno al centro, che cala come una campana e arriva a zero al bordo.
    static func disc(_ c: SIMD3<Double>) -> NSImage {
        let side = 192
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let ctx = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return NSImage() }
        let steps = 28
        var colors: [CGColor] = [], stops: [CGFloat] = []
        let floor = exp(-2.6)
        for i in 0...steps {
            let t = Double(i) / Double(steps)
            // una campana larga: niente nocciolo acceso al centro, e a zero al bordo senza gradino
            let bell = (exp(-2.6 * t * t) - floor) / (1 - floor)
            let alpha = bell * (1 - t * t * t * t)
            colors.append(CGColor(srgbRed: c.x, green: c.y, blue: c.z, alpha: alpha))
            stops.append(CGFloat(t))
        }
        guard let gradient = CGGradient(colorsSpace: space, colors: colors as CFArray, locations: stops) else { return NSImage() }
        let mid = CGPoint(x: side / 2, y: side / 2)
        ctx.drawRadialGradient(gradient, startCenter: mid, startRadius: 0, endCenter: mid, endRadius: CGFloat(side) / 2, options: [])
        guard let image = ctx.makeImage() else { return NSImage() }
        return NSImage(cgImage: image, size: NSSize(width: side, height: side))
    }

    /// Quattro colori della copertina, dal più presente: si contano i colori vivi per tinta (dodici spicchi) e si
    /// prendono i più pesanti, schiariti quanto basta per fare luce. Una copertina in bianco e nero dà luci bianche e grigie.
    nonisolated static func palette(for image: NSImage) -> [SIMD3<Double>] {
        let gray: [SIMD3<Double>] = [SIMD3(0.96, 0.96, 0.96), SIMD3(0.78, 0.78, 0.80), SIMD3(0.90, 0.90, 0.92), SIMD3(0.66, 0.66, 0.70)]
        let side = 32
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let ctx = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return gray }
        ctx.interpolationQuality = .medium
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: side, height: side))
        guard let data = ctx.data else { return gray }
        let pixels = data.bindMemory(to: UInt8.self, capacity: side * side * 4)

        var sums = [SIMD3<Double>](repeating: .zero, count: 12)
        var weights = [Double](repeating: 0, count: 12)
        var vivid = 0.0, all = 0.0
        for i in 0..<(side * side) {
            let c = SIMD3(Double(pixels[i * 4]), Double(pixels[i * 4 + 1]), Double(pixels[i * 4 + 2])) / 255
            let hi = max(c.x, c.y, c.z), lo = min(c.x, c.y, c.z), span = hi - lo
            let saturation = hi > 0 ? span / hi : 0
            all += 1
            guard saturation > 0.2, hi > 0.16 else { continue }
            var hue: Double
            if hi == c.x { hue = (c.y - c.z) / span } else if hi == c.y { hue = 2 + (c.z - c.x) / span } else { hue = 4 + (c.x - c.y) / span }
            if hue < 0 { hue += 6 }
            let slot = min(11, Int(hue * 2))
            let weight = saturation * (0.3 + hi)
            sums[slot] += c * weight
            weights[slot] += weight
            vivid += 1
        }
        // quasi tutto grigio: è una copertina in bianco e nero
        guard vivid / max(1, all) > 0.08 else { return gray }

        let total = weights.reduce(0, +)
        let order = weights.indices.sorted { weights[$0] > weights[$1] }
        var palette: [SIMD3<Double>] = []
        for slot in order where weights[slot] > total * 0.06 && palette.count < 4 {
            palette.append(bright(sums[slot] / weights[slot]))
        }
        guard let first = palette.first else { return gray }
        // pochi colori: si aggiungono vicini di tinta del primo, vivi quanto lui (schiarirlo verso il bianco dava macchie grigie)
        let turns: [Double] = [16, -14, 30]
        var next = 0
        while palette.count < 4 {
            palette.append(turned(first, by: turns[next % turns.count]))
            next += 1
        }
        return palette
    }

    /// Lo stesso colore con la tinta girata di qualche grado.
    private nonisolated static func turned(_ c: SIMD3<Double>, by degrees: Double) -> SIMD3<Double> {
        let hi = max(c.x, c.y, c.z), lo = min(c.x, c.y, c.z), span = hi - lo
        guard span > 0 else { return c }
        var hue: Double
        if hi == c.x { hue = (c.y - c.z) / span } else if hi == c.y { hue = 2 + (c.z - c.x) / span } else { hue = 4 + (c.x - c.y) / span }
        hue = (hue * 60 + degrees).truncatingRemainder(dividingBy: 360)
        if hue < 0 { hue += 360 }
        let h = hue / 60, i = Int(h) % 6, f = h - Double(Int(h))
        let p = lo, q = hi - span * f, t = lo + span * f
        switch i {
        case 0: return SIMD3(hi, t, p)
        case 1: return SIMD3(q, hi, p)
        case 2: return SIMD3(p, hi, t)
        case 3: return SIMD3(p, q, hi)
        case 4: return SIMD3(t, p, hi)
        default: return SIMD3(hi, p, q)
        }
    }

    /// Lo stesso colore, portato abbastanza in alto da fare luce su un fondo scuro.
    private nonisolated static func bright(_ c: SIMD3<Double>) -> SIMD3<Double> {
        let hi = max(c.x, c.y, c.z)
        guard hi > 0 else { return SIMD3(0.9, 0.9, 0.9) }
        let lifted = c * (max(hi, 0.86) / hi)
        // un filo più vivo
        let mean = (lifted.x + lifted.y + lifted.z) / 3
        let vivid = SIMD3(mean, mean, mean) + (lifted - SIMD3(mean, mean, mean)) * 1.12
        return SIMD3(min(1, max(0, vivid.x)), min(1, max(0, vivid.y)), min(1, max(0, vivid.z)))
    }
}
