import SwiftUI
import CoreGraphics

/// Come sono fatte le stelle della costellazione. Di serie «luce»; le altre servono a confrontarle sugli scatti
/// (`CHARLAND_BLOCCO_STELLA=atlante|scintilla`).
///
/// Prima la stella era una sola forma piatta a quattro punte, di 6 punti accanto a parole da 34, ricalcolata a ogni
/// fotogramma: si leggeva «parole unite da fili» e non «stelle» (carpa, 19 novembre 2026: «migliora le stelline,
/// così non mi fa impazzire»).
enum MappaStarStyle: String {
    /// Una stella vera vista al telescopio: un punto bianco netto, un alone stretto nel colore della copertina e due
    /// raggi sottili a croce, più lunghi in orizzontale (sotto c'è la scritta). Quelle che contano hanno anche due
    /// raggi corti di traverso; le parole di servizio sono stelle piccole.
    case luce
    /// Le carte del cielo stampate: un disco piatto grande quanto la magnitudine, un anello attorno alle stelle che contano.
    case atlante
    /// La stella a quattro punte di prima, coi lati curvi e la vita sottile, e un punto di luce al centro.
    case scintilla

    nonisolated static let current = ProcessInfo.processInfo.environment["CHARLAND_BLOCCO_STELLA"].flatMap(MappaStarStyle.init(rawValue:)) ?? .luce
}

/// La stella di una parola, disegnata una volta al corpo che la parola avrà alla fine (come la sua scritta): i raggi,
/// che si allungano quando arriva la voce e respirano piano mentre la canzone va, e il cuore col suo alone. Per ogni
/// fotogramma restano due immagini da stendere, niente forme da riempire né filtri.
struct MappaStar: @unchecked Sendable {
    var rays: CGImage?
    var core: CGImage?
    /// Il lato delle due immagini, in punti al corpo finale.
    var raysSide: CGFloat = 0
    var coreSide: CGFloat = 0
    /// Fin dove arriva la stella che si vede, dal centro, in punti al corpo base: le linee si fermano lì.
    var reach: CGFloat = 11
    /// La sua luce si somma a quella di sotto (luce, scintilla); se no è inchiostro (atlante).
    var adds = true

    private static let dots: CGFloat = 3

    /// - Parameters:
    ///   - grade: quanto conta la parola, da 0 a 3: più conta, più la stella è grande e luminosa.
    ///   - plain: una parola di servizio: stella piccola.
    ///   - light: il colore della copertina nel punto del cielo dove sta la stella, pieno.
    ///   - pale: lo stesso, schiarito.
    nonisolated static func make(style: MappaStarStyle, grade: Double, plain: Bool, light: SIMD3<Double>, pale: SIMD3<Double>) -> MappaStar {
        let g = CGFloat(min(3, max(0, grade))), small: CGFloat = plain ? 0.72 : 1
        switch style {
        case .luce:
            let small: CGFloat = plain ? 0.55 : 1
            let heart = (2.6 + 0.9 * g) * small
            let bloom = heart * 6.5
            // larghi in orizzontale; in verticale corti, perché la scritta sta 15 punti sotto la stella
            let wide = (15 + 7.5 * g) * small, tall = min(13.5, (9 + 2.6 * g) * small)
            let width = heart * 0.7
            let raysSide = (wide + 2) * 2
            let rays = image(side: raysSide) { ctx in
                for (length, angle) in [(wide, 0.0), (tall, CGFloat.pi / 2)] {
                    // ogni raggio due volte: largo e tenue (la sua luce), poi sottile e chiaro
                    spike(ctx, length: length, width: width * 3.2, angle: angle, light: light, pale: pale, strength: 0.22)
                    spike(ctx, length: length, width: width, angle: angle, light: light, pale: pale, strength: 1)
                }
                if g >= 1.5 {
                    let cross = wide * 0.42
                    spike(ctx, length: cross, width: width * 0.75, angle: .pi / 4, light: light, pale: pale, strength: 0.5)
                    spike(ctx, length: cross, width: width * 0.75, angle: -.pi / 4, light: light, pale: pale, strength: 0.5)
                }
            }
            let coreSide = bloom * 2
            let core = image(side: coreSide) { ctx in
                // l'alone stretto, nel colore della copertina: una luce, non una sfera
                glow(ctx, radius: bloom, stops: [(light, 0.5, 0), (light, 0.2, 0.25), (light, 0.06, 0.55), (light, 0, 1)])
                // il cuore: bianco e netto, col bordo appena sfumato
                glow(ctx, radius: heart * 2.2, stops: [(pale, 0.75, 0), (pale, 0.25, 0.55), (pale, 0, 1)])
                ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
                ctx.fillEllipse(in: CGRect(x: -heart, y: -heart, width: heart * 2, height: heart * 2))
            }
            return MappaStar(rays: rays, core: core, raysSide: raysSide, coreSide: coreSide, reach: (11 + 2.2 * g) * small, adds: true)

        case .atlante:
            let radius = (2.3 + 1.55 * g) * small
            let ring = g >= 1.8 && !plain
            let outer = ring ? radius + 3.4 : radius + 0.5
            let coreSide = outer * 2 + 2
            let core = image(side: coreSide) { ctx in
                if let gradient = gradient([(pale, 1, 0), (light, 1, 1)]) {
                    ctx.saveGState()
                    ctx.addEllipse(in: CGRect(x: -radius, y: -radius, width: radius * 2, height: radius * 2))
                    ctx.clip()
                    ctx.drawLinearGradient(gradient, start: CGPoint(x: -radius, y: -radius), end: CGPoint(x: radius, y: radius), options: [])
                    ctx.restoreGState()
                }
                if ring {
                    ctx.setStrokeColor(CGColor(srgbRed: pale.x, green: pale.y, blue: pale.z, alpha: 0.85))
                    ctx.setLineWidth(0.9)
                    ctx.strokeEllipse(in: CGRect(x: -(radius + 2.9), y: -(radius + 2.9), width: (radius + 2.9) * 2, height: (radius + 2.9) * 2))
                }
            }
            return MappaStar(rays: nil, core: core, raysSide: 0, coreSide: coreSide, reach: outer + 5, adds: false)

        case .scintilla:
            let tall = min(12.5, (6.5 + 3.8 * g) * small), wide = (6.5 + 3.8 * g) * small * 0.86
            let raysSide = max(tall, wide) * 2 + 2
            let rays = image(side: raysSide) { ctx in
                let bend: CGFloat = 0.1
                let path = CGMutablePath()
                path.move(to: CGPoint(x: 0, y: tall))
                path.addQuadCurve(to: CGPoint(x: wide, y: 0), control: CGPoint(x: wide * bend, y: tall * bend))
                path.addQuadCurve(to: CGPoint(x: 0, y: -tall), control: CGPoint(x: wide * bend, y: -tall * bend))
                path.addQuadCurve(to: CGPoint(x: -wide, y: 0), control: CGPoint(x: -wide * bend, y: -tall * bend))
                path.addQuadCurve(to: CGPoint(x: 0, y: tall), control: CGPoint(x: -wide * bend, y: tall * bend))
                path.closeSubpath()
                if let gradient = gradient([(pale, 1, 0), (light, 0.9, 1)]) {
                    ctx.saveGState()
                    ctx.addPath(path)
                    ctx.clip()
                    ctx.drawLinearGradient(gradient, start: CGPoint(x: -wide, y: tall), end: CGPoint(x: wide, y: -tall), options: [])
                    ctx.restoreGState()
                }
            }
            let heart = (1.1 + 0.3 * g) * small, bloom = wide * 1.1
            let coreSide = bloom * 2
            let core = image(side: coreSide) { ctx in
                glow(ctx, radius: bloom, stops: [(light, 0.26, 0), (light, 0.07, 0.45), (light, 0, 1)])
                ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
                ctx.fillEllipse(in: CGRect(x: -heart, y: -heart, width: heart * 2, height: heart * 2))
            }
            return MappaStar(rays: rays, core: core, raysSide: raysSide, coreSide: coreSide, reach: max(11, wide * 0.8), adds: true)
        }
    }

    // MARK: Disegno

    /// Un'immagine quadrata di `side` punti con l'origine al centro.
    private nonisolated static func image(side: CGFloat, _ draw: (CGContext) -> Void) -> CGImage? {
        let px = Int((side * dots).rounded(.up))
        guard px > 0, let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.translateBy(x: CGFloat(px) / 2, y: CGFloat(px) / 2)
        ctx.scaleBy(x: dots, y: dots)
        draw(ctx)
        return ctx.makeImage()
    }

    private nonisolated static func gradient(_ stops: [(color: SIMD3<Double>, alpha: Double, at: CGFloat)]) -> CGGradient? {
        CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                   colors: stops.map { CGColor(srgbRed: $0.color.x, green: $0.color.y, blue: $0.color.z, alpha: $0.alpha) } as CFArray,
                   locations: stops.map(\.at))
    }

    /// Una luce rotonda che sfuma, attorno al centro.
    private nonisolated static func glow(_ ctx: CGContext, radius: CGFloat, stops: [(color: SIMD3<Double>, alpha: Double, at: CGFloat)]) {
        guard let gradient = gradient(stops) else { return }
        ctx.drawRadialGradient(gradient, startCenter: .zero, startRadius: 0, endCenter: .zero, endRadius: radius, options: [])
    }

    /// Un raggio: un ago sottile da una punta all'altra passando dal centro, bianco in mezzo, nel colore della
    /// copertina più in là, trasparente in punta.
    private nonisolated static func spike(_ ctx: CGContext, length: CGFloat, width: CGFloat, angle: CGFloat, light: SIMD3<Double>, pale: SIMD3<Double>, strength: Double) {
        let white = SIMD3<Double>(1, 1, 1), s = strength
        guard let gradient = gradient([(light, 0, 0), (light, 0.35 * s, 0.14), (light, 0.7 * s, 0.32), (pale, 0.95 * s, 0.45), (white, s, 0.5),
                                       (pale, 0.95 * s, 0.55), (light, 0.7 * s, 0.68), (light, 0.35 * s, 0.86), (light, 0, 1)]) else { return }
        ctx.saveGState()
        ctx.rotate(by: angle)
        let path = CGMutablePath()
        path.move(to: CGPoint(x: -length, y: 0))
        path.addQuadCurve(to: CGPoint(x: 0, y: width), control: CGPoint(x: -length * 0.18, y: width * 0.35))
        path.addQuadCurve(to: CGPoint(x: length, y: 0), control: CGPoint(x: length * 0.18, y: width * 0.35))
        path.addQuadCurve(to: CGPoint(x: 0, y: -width), control: CGPoint(x: length * 0.18, y: -width * 0.35))
        path.addQuadCurve(to: CGPoint(x: -length, y: 0), control: CGPoint(x: -length * 0.18, y: -width * 0.35))
        path.closeSubpath()
        ctx.addPath(path)
        ctx.clip()
        ctx.drawLinearGradient(gradient, start: CGPoint(x: -length, y: 0), end: CGPoint(x: length, y: 0), options: [])
        ctx.restoreGState()
    }
}
