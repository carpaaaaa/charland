import SwiftUI

// Il segno della dettatura di Charcal («Tre», scelto da carpa il 10 novembre su una tavola di tre):
// tre barre a capi tondi, alta quella al centro, e un punto per lato. Ripreso da Charcal (Carta.swift).

enum VoiceMark {
    /// `unit` è l'altezza di riferimento (il segno è largo 0,69 unità e alto 0,4); `grow` da 0 a 1 fa crescere la barra
    /// al centro dal punto, `reach` da 0 a 1 fa uscire le barre ai lati e poi i punti; `weight` ingrossa i tratti nelle
    /// misure piccole.
    static func draw(in context: GraphicsContext, center: CGPoint, unit: CGFloat, grow: CGFloat = 1, reach: CGFloat = 1,
                     dot: CGFloat = 0.1, weight: CGFloat = 1) {
        let ink = GraphicsContext.Shading.foreground
        let base = dot * unit
        let thick = 0.085 * unit * weight
        let gap = 0.15 * unit
        func bar(_ x: CGFloat, width: CGFloat, height: CGFloat) {
            guard width > 0.25, height > 0.25 else { return }
            context.fill(Path(roundedRect: CGRect(x: center.x + x - width / 2, y: center.y - height / 2, width: width, height: height),
                              cornerRadius: width / 2, style: .continuous), with: ink)
        }
        bar(0, width: base + (thick - base) * grow, height: base + (0.4 * unit - base) * grow)
        guard reach > 0.01 else { return }
        let side = min(1, reach / 0.7)
        let points = min(1, max(0, (reach - 0.5) / 0.5))
        for direction in [-1.0, 1.0] {
            bar(direction * gap * side, width: thick, height: thick + (0.2 * unit - thick) * side)
            bar(direction * 2 * gap * side, width: thick * points, height: thick * points)
        }
    }
}

/// Il segno della voce fermo, nel colore del testo, grande `size`.
struct VoiceGlyph: View {
    var size: CGFloat
    var weight: CGFloat = 1.1

    var body: some View {
        Canvas { context, canvas in
            VoiceMark.draw(in: context, center: CGPoint(x: canvas.width / 2, y: canvas.height / 2),
                           unit: canvas.width / 0.74, weight: weight)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}
