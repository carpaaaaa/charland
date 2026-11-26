import AppKit
import SwiftUI

/// Scatti di prova per «Tutto vetro» e per l'equalizzatore, fuori schermo: gli strati di Core Animation (mascotte,
/// disco, barre) lo scatto di SwiftUI non li disegna, quindi qui si disegnano a mano con le stesse funzioni dell'app.
/// Li scrive `Charland --render <cartella>` accanto agli altri.
@MainActor
enum GlassChecks {
    static func render(into dir: URL) {
        mascots(dir.appendingPathComponent("vetro-mascotte.png"))
        cover(dir.appendingPathComponent("vetro-copertina.png"))
        equalizer(dir.appendingPathComponent("vetro-equalizzatore.png"))
    }

    private static func canvas(_ width: Int, _ height: Int, _ draw: (CGContext) -> Void) -> CGImage? {
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        draw(ctx)
        return ctx.makeImage()
    }

    private static func write(_ image: CGImage?, to url: URL) {
        guard let image, let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { return }
        try? data.write(to: url)
    }

    /// La mascotte coi colori e di vetro, al lavoro e ferma, sul nero del notch e su un fondo chiaro (il vassoio del Dock).
    private static func mascots(_ url: URL) {
        let zoom: CGFloat = 8
        let cell = CGSize(width: 34 * zoom, height: 20 * zoom)
        let palettes: [AgentMascot.Palette] = [.claude, .glass, .codex, .glass]
        let shapes: [AgentMascot.Shape] = [.square, .square, .round, .round]
        write(canvas(Int(cell.width) * 4, Int(cell.height) * 3) { ctx in
            ctx.interpolationQuality = .none
            for row in 0..<3 {
                for col in 0..<4 {
                    let rect = CGRect(x: CGFloat(col) * cell.width, y: CGFloat(2 - row) * cell.height, width: cell.width, height: cell.height)
                    ctx.setFillColor(row == 2 ? CGColor(red: 0.42, green: 0.45, blue: 0.56, alpha: 1) : CGColor(gray: 0, alpha: 1))
                    ctx.fill(rect)
                    guard let frame = AgentMascot.frame(palette: palettes[col], shape: shapes[col], working: row != 1,
                                                        nearUp: row == 0, farUp: false, eyesOpen: true, pixel: 1.5, scale: 2) else { continue }
                    let w = CGFloat(frame.width) / 2 * zoom, h = CGFloat(frame.height) / 2 * zoom
                    ctx.draw(frame, in: CGRect(x: rect.midX - w / 2, y: rect.midY - h / 2, width: w, height: h))
                }
            }
        }, to: url)
    }

    /// Una copertina a colori e la sua lastra di vetro, sul nero.
    private static func cover(_ url: URL) {
        let source = NSImage(size: NSSize(width: 240, height: 240), flipped: false) { rect in
            NSGradient(colors: [NSColor(red: 0.9, green: 0.2, blue: 0.25, alpha: 1), NSColor(red: 0.15, green: 0.1, blue: 0.5, alpha: 1)])?
                .draw(in: rect, angle: 60)
            NSColor(white: 1, alpha: 0.9).setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 70, dy: 70)).fill()
            return true
        }
        let glass = GlassCover.image(for: source)
        write(canvas(560, 280) { ctx in
            ctx.setFillColor(CGColor(gray: 0, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: 560, height: 280))
            for (index, image) in [source, glass].enumerated() {
                guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { continue }
                let rect = CGRect(x: 20 + CGFloat(index) * 280, y: 20, width: 240, height: 240)
                ctx.saveGState()
                ctx.addPath(CGPath(roundedRect: rect, cornerWidth: 54, cornerHeight: 54, transform: nil))
                ctx.clip()
                ctx.draw(cg, in: rect)
                ctx.restoreGState()
            }
        }, to: url)
    }

    /// Le barre dell'equalizzatore lungo le due battute, un fotogramma ogni mezzo battito, per due brani diversi.
    private static func equalizer(_ url: URL) {
        let columns = 16, zoom: CGFloat = 6
        let cell = CGSize(width: 30 * zoom, height: 22 * zoom)
        write(canvas(Int(cell.width) * columns, Int(cell.height) * 2) { ctx in
            ctx.setFillColor(CGColor(gray: 0, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: cell.width * CGFloat(columns), height: cell.height * 2))
            for (row, seed) in [1234, 98765].enumerated() {
                let pattern = EqualizerPattern(seed: seed)
                let levels = (0..<EqualizerBars.bars).map { pattern.levels(bar: $0) }
                for col in 0..<columns {
                    let sample = col * EqualizerPattern.samplesPerBeat / 2 + 1
                    let origin = CGPoint(x: CGFloat(col) * cell.width, y: CGFloat(1 - row) * cell.height)
                    for bar in 0..<EqualizerBars.bars {
                        let h = (3 + (EqualizerBars.size.height - 3) * CGFloat(levels[bar][sample])) * zoom
                        let w = EqualizerBars.barWidth * zoom
                        let x = origin.x + (cell.width - EqualizerBars.size.width * zoom) / 2 + CGFloat(bar) * (EqualizerBars.barWidth + EqualizerBars.gap) * zoom
                        let rect = CGRect(x: x, y: origin.y + (cell.height - h) / 2, width: w, height: h)
                        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
                        ctx.addPath(CGPath(roundedRect: rect, cornerWidth: w / 2, cornerHeight: min(w, h) / 2, transform: nil))
                        ctx.fillPath()
                    }
                }
            }
        }, to: url)
    }
}
