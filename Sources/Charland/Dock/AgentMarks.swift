import SwiftUI
import AppKit
import UniformTypeIdentifiers
import CharlandCore

/// Il segno di ogni agente dentro il suo anello.
///
/// Charland non contiene i loghi di Anthropic e di OpenAI (verificato il 17 novembre 2026): le regole sui marchi di
/// Anthropic chiedono un permesso scritto per qualunque uso dei suoi loghi, quelle di OpenAI permettono il Blossom solo
/// com'è fornito da loro, bianco o nero, accettando i loro termini. Di serie quindi c'è la mascotte di Charland; chi
/// usa l'app può mettere il simbolo che vuole (per esempio il logo ufficiale, scaricato da sé) in Impostazioni › Dock.
/// Il file resta suo, in `~/Library/Application Support/Charland/Segni`.
/// Eccezione dichiarata: la mascotte arancione dell'agente Claude (`ClaudeMascot.swift`) è ridisegnata da quella che
/// Claude Code stampa nel terminale. Non è coperta dalla GPL (vedi TRADEMARKS.md) e si toglie se il titolare lo chiede.
@MainActor @Observable
final class AgentMarks {
    static let shared = AgentMarks()

    struct Mark {
        let image: NSImage
        /// Tutto scuro (un logo nero): si disegna bianco, come un simbolo di sistema. Gli altri con i loro colori.
        let template: Bool
        /// Quanta parte dell'immagine occupa il disegno vero, e di quanto il suo centro è spostato dal centro
        /// dell'immagine (in frazioni del lato). I loghi ufficiali hanno attorno lo spazio vuoto che chiede chi li fa
        /// (il Blossom di OpenAI ne ha metà): il file non si ritaglia, si disegna più grande in modo che il disegno vero
        /// abbia la misura giusta, e lo spazio vuoto resta com'è, invisibile.
        let fill: CGFloat
        let center: CGPoint
    }

    private(set) var marks: [UsageProviderID: Mark] = [:]

    static let types: [UTType] = [.svg, .pdf, .png, .jpeg, .heic, .tiff]

    private static var folder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(Identity.supportFolder).appendingPathComponent("Segni")
    }

    private init() {
        for provider in UsageProviderID.allCases { load(provider) }
    }

    func mark(for provider: UsageProviderID) -> Mark? { marks[provider] }

    /// Mette un'immagine scelta da chi usa l'app come segno di un agente. `false` se il file non si legge come immagine.
    @discardableResult
    func set(_ source: URL, for provider: UsageProviderID) -> Bool {
        // Solo file sul Mac: un'immagine trascinata da una pagina web arriverebbe come indirizzo da scaricare.
        guard source.isFileURL else { return false }
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        guard let image = NSImage(contentsOf: source) else { return false }
        let fm = FileManager.default
        try? fm.createDirectory(at: Self.folder, withIntermediateDirectories: true)
        let ext = source.pathExtension.lowercased()
        // I disegni (SVG, PDF) restano come sono, nitidi a ogni misura; le foto si riducono a 256 punti, che bastano
        // per un anello e non tengono in memoria un'immagine enorme.
        let data: Data?
        let outExt: String
        if ext == "svg" || ext == "pdf" {
            data = try? Data(contentsOf: source)
            outExt = ext
        } else {
            data = Self.png(image, side: 256)
            outExt = "png"
        }
        guard let data else { return false }
        // Prima si scrive accanto, poi si sostituisce: se qualcosa va storto il segno di prima resta.
        let temporary = Self.folder.appendingPathComponent(".\(provider.rawValue)-\(UUID().uuidString).\(outExt)")
        do { try data.write(to: temporary) } catch { return false }
        removeFiles(provider)
        do {
            try fm.moveItem(at: temporary, to: Self.folder.appendingPathComponent("\(provider.rawValue).\(outExt)"))
        } catch {
            try? fm.removeItem(at: temporary)
            return false
        }
        load(provider)
        return marks[provider] != nil
    }

    private static func png(_ image: NSImage, side: Int) -> Data? {
        let size = image.size
        guard size.width > 0, size.height > 0 else { return nil }
        let scale = min(1, CGFloat(side) / max(size.width, size.height))
        let width = max(1, Int(size.width * scale)), height = max(1, Int(size.height * scale))
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: CGRect(x: 0, y: 0, width: width, height: height))
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])
    }

    func remove(_ provider: UsageProviderID) {
        removeFiles(provider)
        marks[provider] = nil
    }

    private func files(_ provider: UsageProviderID) -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: Self.folder, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.deletingPathExtension().lastPathComponent == provider.rawValue }
    }

    private func removeFiles(_ provider: UsageProviderID) {
        for file in files(provider) { try? FileManager.default.removeItem(at: file) }
    }

    private func load(_ provider: UsageProviderID) {
        guard let file = files(provider).first(where: { !$0.lastPathComponent.hasPrefix(".") }), let image = NSImage(contentsOf: file) else {
            marks[provider] = nil
            return
        }
        let bounds = Self.contentBounds(image)
        marks[provider] = Mark(image: image, template: Self.isDark(image), fill: bounds.fill, center: bounds.center)
    }

    /// Dove sta il disegno nell'immagine: il riquadro dei punti non trasparenti, misurato su una copia di 96 punti.
    private static func contentBounds(_ image: NSImage) -> (fill: CGFloat, center: CGPoint) {
        let side = 96
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0) else { return (1, .zero) }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor.clear.set()
        CGRect(x: 0, y: 0, width: side, height: side).fill()
        image.draw(in: CGRect(x: 0, y: 0, width: side, height: side))
        NSGraphicsContext.restoreGraphicsState()
        var minX = side, minY = side, maxX = -1, maxY = -1
        for y in 0..<side {
            for x in 0..<side where (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.1 {
                minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        guard maxX >= minX, maxY >= minY else { return (1, .zero) }
        let width = CGFloat(maxX - minX + 1), height = CGFloat(maxY - minY + 1)
        let fill = max(0.2, min(1, max(width, height) / CGFloat(side)))
        let center = CGPoint(x: (CGFloat(minX) + width / 2) / CGFloat(side) - 0.5, y: (CGFloat(minY) + height / 2) / CGFloat(side) - 0.5)
        return (fill, center)
    }

    /// Scuro vuol dire che i suoi punti visibili sono quasi neri e che ha un fondo trasparente (un logo, non una foto
    /// scura, che diventerebbe un quadrato bianco): misurato su una copia piccola.
    private static func isDark(_ image: NSImage) -> Bool {
        let side = 24
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0) else { return false }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: CGRect(x: 0, y: 0, width: side, height: side))
        NSGraphicsContext.restoreGraphicsState()
        var luminance = 0.0, weight = 0.0, clear = 0
        for y in 0..<side {
            for x in 0..<side {
                guard let color = rep.colorAt(x: x, y: y) else { continue }
                if color.alphaComponent < 0.5 { clear += 1 }
                guard color.alphaComponent > 0.3 else { continue }
                luminance += (0.2126 * color.redComponent + 0.7152 * color.greenComponent + 0.0722 * color.blueComponent) * color.alphaComponent
                weight += color.alphaComponent
            }
        }
        return weight > 0 && clear > side * side / 10 && luminance / weight < 0.28
    }
}

/// Il segno di un agente: l'immagine scelta da chi usa l'app, se c'è, se no la mascotte di Charland.
struct AgentMarkView: View {
    let provider: UsageProviderID
    /// Quanto è grande il segno (la mascotte ha la sua misura a pixel).
    var size: CGFloat = 17
    private let marks = AgentMarks.shared

    var body: some View {
        if let mark = marks.mark(for: provider) {
            // L'immagine intera, ingrandita perché il disegno vero sia grande `size` e centrato.
            let canvas = size / mark.fill
            Image(nsImage: mark.image)
                // Con «Tutto vetro» anche un segno a colori si disegna dalla sua sagoma, di vetro.
                .renderingMode(mark.template || Glassy.on ? .template : .original)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .foregroundStyle(Glassy.ink(Color.white))
                .frame(width: canvas, height: canvas)
                .offset(x: -mark.center.x * canvas, y: -mark.center.y * canvas)
                .frame(width: size, height: size)
                .accessibilityHidden(true)
        } else {
            // Un filo più piccola dell'anello (carpa, 18 novembre 2026: «così che stia bene all'interno del cerchio»).
            MascotFace(kind: provider.kind, pixel: size >= 15 ? 1.25 : 1)
        }
    }
}

/// Il muso della mascotte di un agente, la stessa dell'isola vista di fronte: a pixel quadrati, nel suo colore.
struct MascotFace: View {
    @Environment(\.displayScale) private var displayScale
    let kind: AgentKind
    /// Il lato di un pixel in punti: 1,5 sono tre pixel veri su uno schermo Retina.
    var pixel: CGFloat = 1.5

    static let columns = 11
    static let rows = 10

    var body: some View {
        let palette = Glassy.on ? AgentMascot.Palette.glass : kind.palette
        let shape = kind.shape
        Canvas { context, size in
            let p = pixel
            // I bordi delle celle cadono sui pixel veri dello schermo: con un lato che non è un numero intero di pixel
            // (1,25 punti sono 2,5 pixel) le celle diventano di 2 e 3 pixel alternate, ma restano nette.
            let scale = max(1, displayScale)
            func snap(_ v: CGFloat) -> CGFloat { (v * scale).rounded() / scale }
            let ox = snap((size.width - CGFloat(Self.columns) * p) / 2)
            let oy = snap((size.height - CGFloat(Self.rows) * p) / 2)
            func cell(_ col: Int, _ row: Int, _ w: Int, _ h: Int) -> CGRect {
                let x0 = ox + snap(CGFloat(col) * p), x1 = ox + snap(CGFloat(col + w) * p)
                let y0 = oy + snap(CGFloat(row) * p), y1 = oy + snap(CGFloat(row + h) * p)
                return CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
            }
            func fill(_ col: Int, _ row: Int, _ color: Color, w: Int = 1, h: Int = 1) {
                guard palette.fade < 1 else {
                    context.fill(Path(cell(col, row, w, h)), with: .color(color))
                    return
                }
                // Di vetro: più piena in alto, più tenue verso il fondo (come la mascotte dell'isola).
                for line in row..<(row + h) {
                    let k = 1 - (1 - palette.fade) * Double(line) / Double(Self.rows - 1)
                    context.fill(Path(cell(col, line, w, 1)), with: .color(color.opacity(k)))
                }
            }
            // Il corpo: il fianco sinistro in ombra, come nell'isola.
            switch shape {
            case .round:
                fill(1, 1, palette.shade, w: 1, h: 7); fill(0, 2, palette.shade, w: 1, h: 5)
                fill(2, 1, palette.body, w: 8, h: 7); fill(10, 2, palette.body, w: 1, h: 5)
            case .square, .antenna:
                fill(0, 1, palette.shade, w: 2, h: 7)
                fill(2, 1, palette.body, w: 9, h: 7)
            }
            if shape == .antenna { fill(6, 0, palette.lit) }
            if let rim = palette.rim {
                // Al posto della prima riga del corpo, non sopra: il Canvas somma i colori trasparenti.
                context.blendMode = .copy
                fill(shape == .round ? 3 : 2, 1, rim, w: shape == .round ? 6 : 9)
                context.blendMode = .normal
            }
            // Gli occhi: neri, oppure (di vetro) due fori da cui si vede il vassoio sotto.
            context.blendMode = palette.eyes == nil ? .clear : .normal
            fill(5, 3, palette.eyes ?? .black, h: 2)
            fill(8, 3, palette.eyes ?? .black, h: 2)
            context.blendMode = .normal
            // Le zampe.
            fill(1, 8, palette.shade, h: 2)
            fill(3, 8, palette.body, h: 2)
            fill(7, 8, palette.shade, h: 2)
            fill(9, 8, palette.body, h: 2)
        }
        .frame(width: CGFloat(Self.columns) * pixel + 1, height: CGFloat(Self.rows) * pixel + 1)
        .accessibilityHidden(true)
    }
}
