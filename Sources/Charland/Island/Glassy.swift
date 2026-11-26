import SwiftUI
import AppKit

/// «Tutto vetro» (carpa, 18 novembre 2026: «i loghi del notch diventano tutti in vetro ultra clean, come il Claude che
/// lavora al pc; dentro il notch non ci sono più i colori, è tutto vetro. Stessa cosa per il Dock»).
///
/// Acceso in Impostazioni › Aspetto, toglie ogni colore dall'isola e dai widget del Dock: simboli, numeri, anelli,
/// mascotte e copertine diventano di vetro, cioè bianchi e un poco trasparenti, più pieni in alto dove prendono la luce
/// e più tenui in basso, con un filo chiaro sul bordo delle lastre.
///
/// È vetro disegnato, non il Liquid Glass di sistema: sul nero del notch non c'è niente da piegare, e un vetro vero per
/// ogni simbolo vorrebbe dire una copia dello sfondo per ognuno, ricalcolata a ogni fotogramma. Così fermo non costa
/// niente. Il vetro vero resta quello dell'isola e dei vassoi, sotto.
@MainActor
enum Glassy {
    /// Acceso. Letto dentro il disegno di una vista, la vista si ridisegna quando cambia.
    static var on: Bool { Appearance.shared.fullGlass }
    /// Anche le copertine diventano lastre di vetro (si può lasciarle a colori).
    static var covers: Bool { on && !Appearance.shared.glassKeepsCovers }

    /// L'inchiostro di vetro per simboli, numeri e anelli: bianco che prende luce dall'alto.
    static let ink = AnyShapeStyle(LinearGradient(stops: [.init(color: .white, location: 0),
                                                           .init(color: .white.opacity(0.9), location: 0.45),
                                                           .init(color: .white.opacity(0.6), location: 1)],
                                                  startPoint: .top, endPoint: .bottom))
    /// Lo stesso, più tenue: per quello che prima era un colore spento (una traccia, un testo secondario).
    static let faint = AnyShapeStyle(LinearGradient(colors: [.white.opacity(0.62), .white.opacity(0.36)],
                                                    startPoint: .top, endPoint: .bottom))
    /// Il filo di luce sul bordo di una lastra: acceso in alto, quasi spento in basso.
    static let rim = LinearGradient(colors: [.white.opacity(0.42), .white.opacity(0.07)], startPoint: .top, endPoint: .bottom)

    /// Il colore di sempre, oppure l'inchiostro di vetro.
    static func ink(_ color: Color) -> AnyShapeStyle { on ? ink : AnyShapeStyle(color) }
    static func ink<S: ShapeStyle>(_ style: S) -> AnyShapeStyle { on ? ink : AnyShapeStyle(style) }
    /// Per chi vuole un colore pieno (uno strato di Core Animation, un anello): bianco.
    static func flat(_ color: Color) -> Color { on ? .white : color }
}

extension View {
    /// Il colore di sempre, o di vetro con «Tutto vetro».
    func inked(_ color: Color) -> some View { foregroundStyle(Glassy.ink(color)) }
}

/// Il fondo di una tessera, di una pillola o di un pulsante dell'isola. Di serie il fondo scuro con un velo chiaro;
/// con «Tutto vetro» una lastra: chiara in alto, quasi niente in basso, col filo di luce sul bordo.
struct GlassPlate<S: InsettableShape>: View {
    let shape: S
    var hovered = false
    /// Accesa (Mantieni attivo in corso, il pulsante principale): bianca piena in tutti e due gli aspetti.
    var highlighted = false

    var body: some View {
        if highlighted {
            shape.fill(Color.white)
        } else if Glassy.on {
            shape.fill(LinearGradient(colors: [.white.opacity(hovered ? 0.24 : 0.13), .white.opacity(hovered ? 0.12 : 0.04)],
                                      startPoint: .top, endPoint: .bottom))
                .overlay(shape.strokeBorder(Glassy.rim, lineWidth: 0.8))
                .animation(.hover(hovered), value: hovered)
        } else {
            shape.fill(Color.black.opacity(0.22))
                .overlay(shape.fill(Color.white.opacity(hovered ? 0.17 : 0.09))
                    .animation(.hover(hovered), value: hovered))
        }
    }
}

/// Le copertine come lastre di vetro: in bianco e nero, un poco trasparenti, con la luce che scende dall'alto. Si
/// preparano una volta per copertina (sono due o tre in tutto: quella che suona, piccola e grande).
@MainActor
enum GlassCover {
    private static var made: [(source: NSImage, glass: NSImage)] = []

    static func image(for source: NSImage) -> NSImage {
        if let hit = made.first(where: { $0.source === source }) { return hit.glass }
        let glass = render(source) ?? source
        made.append((source, glass))
        if made.count > 4 { made.removeFirst(made.count - 4) }
        return glass
    }

    private static func render(_ image: NSImage) -> NSImage? {
        let side = 240
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let gray = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                                   space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue),
              let out = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        // Riempie il quadrato senza schiacciare: si ritaglia il lato più lungo.
        let w = CGFloat(cg.width), h = CGFloat(cg.height)
        let scale = CGFloat(side) / max(1, min(w, h))
        let fit = CGRect(x: (CGFloat(side) - w * scale) / 2, y: (CGFloat(side) - h * scale) / 2, width: w * scale, height: h * scale)
        gray.interpolationQuality = .high
        gray.draw(cg, in: fit)
        guard let mono = gray.makeImage() else { return nil }
        let full = CGRect(x: 0, y: 0, width: side, height: side)
        // Una lastra appena chiara, e sopra la copertina in bianco e nero, un poco trasparente.
        out.setFillColor(CGColor(gray: 1, alpha: 0.10))
        out.fill(full)
        out.setAlpha(0.74)
        out.draw(mono, in: full)
        out.setAlpha(1)
        // La luce: chiara in alto, niente a metà, un'ombra leggera in fondo.
        let space = CGColorSpaceCreateDeviceRGB()
        let colors = [CGColor(red: 1, green: 1, blue: 1, alpha: 0.26), CGColor(red: 1, green: 1, blue: 1, alpha: 0),
                      CGColor(red: 0, green: 0, blue: 0, alpha: 0.2)] as CFArray
        if let sheen = CGGradient(colorsSpace: space, colors: colors, locations: [0, 0.5, 1]) {
            out.drawLinearGradient(sheen, start: CGPoint(x: 0, y: side), end: .zero, options: [])
        }
        guard let result = out.makeImage() else { return nil }
        return NSImage(cgImage: result, size: NSSize(width: side, height: side))
    }
}
