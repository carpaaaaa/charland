import AppKit
import CoreImage
import Vision

/// Quello che «Mappa» sa di una copertina: come ritagliarla sullo schermo, la sua versione sfocata, che colori ha.
/// Si prepara una volta per brano, fuori dal thread principale. Vale per qualunque copertina: una foto, un disegno,
/// una scritta.
struct MappaScene: @unchecked Sendable {
    /// Il brano di cui è la scena.
    var key: String
    var cover: NSImage
    /// La copertina data dall'app di musica da cui la scena è nata (anche dopo lo scambio con quella grande del
    /// catalogo). Serve a riconoscere una scena nata dalla copertina sbagliata: il titolo del brano nuovo arriva spesso
    /// prima della sua foto, e in quel momento la «copertina del brano» è ancora quella del brano di prima.
    var source: NSImage
    /// La copertina sfocata, in piccolo: stesa sopra quella nitida la ammorbidisce, così le parole si leggono.
    var soft: NSImage
    /// Larghezza diviso altezza della copertina.
    var aspect: CGFloat
    /// Il punto da tenere in vista (il viso, o dove cade l'occhio), in frazioni della copertina dall'alto a sinistra.
    var focus: CGPoint
    /// Quanto è chiara la copertina, in una griglia `grid` per `grid`, righe dall'alto, da 0 a 1.
    var luma: [Float]
    /// I colori della copertina, dal più presente: fanno il neon del bordo e la luce delle parole.
    var palette: [SIMD3<Double>]
    /// La foto nitida è quella grande del catalogo di Apple (`BigArtwork`), non quella data dall'app di musica.
    var sharp = false

    /// Un segno della copertina di partenza, per le firme di mappe e piani: stesso brano con un'altra copertina vuol
    /// dire colori e inquadrature da rifare.
    var token: String { String(UInt(bitPattern: ObjectIdentifier(source).hashValue), radix: 36) }

    /// Quanti pixel è larga la foto nitida.
    var pixels: Int { cover.representations.map(\.pixelsWide).max() ?? 0 }

    /// La stessa scena con la foto grande del catalogo: colori, punto da tenere in vista, luce e versione sfocata restano
    /// quelli di prima (così bordo, parole e inquadrature non cambiano), cambia solo la foto nitida. Niente se la foto
    /// grande non è più grande o ha altre proporzioni (si deformerebbe).
    func sharpened(with image: CGImage) -> MappaScene? {
        let ratio = CGFloat(image.width) / CGFloat(max(1, image.height))
        guard image.width > pixels, abs(ratio - aspect) < 0.03 else { return nil }
        var scene = self
        scene.cover = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
        scene.sharp = true
        return scene
    }

    static let grid = 40

    /// Il rettangolo della copertina su uno schermo di `size` punti: lo riempie tutto, col punto da tenere in vista
    /// un filo sotto il centro (sopra c'è l'orologio).
    func frame(in size: CGSize) -> CGRect {
        let width = max(size.width, size.height * aspect), height = width / aspect
        let top = min(max(0, focus.y * height - 0.48 * size.height), height - size.height)
        let left = min(max(0, focus.x * width - 0.5 * size.width), width - size.width)
        return CGRect(x: -left, y: -top, width: width, height: height)
    }

    /// Quanto è chiara la copertina in un rettangolo dello schermo, da 0 a 1.
    func light(of rect: CGRect, in size: CGSize) -> Double {
        let f = frame(in: size), g = Self.grid
        guard luma.count == g * g, rect.width > 0, rect.height > 0 else { return 0.5 }
        func cell(_ v: CGFloat, _ origin: CGFloat, _ span: CGFloat) -> Int { min(g - 1, max(0, Int((v - origin) / span * CGFloat(g)))) }
        let x0 = cell(rect.minX, f.minX, f.width), x1 = cell(rect.maxX, f.minX, f.width)
        let y0 = cell(rect.minY, f.minY, f.height), y1 = cell(rect.maxY, f.minY, f.height)
        var sum = 0.0, count = 0.0
        for y in y0...max(y0, y1) { for x in x0...max(x0, x1) { sum += Double(luma[y * g + x]); count += 1 } }
        return count > 0 ? sum / count : 0.5
    }

    /// Quanto nero mettere sopra la copertina perché le parole bianche restino bianche: si guarda quanto è chiara
    /// dove sta la mappa e la si porta al massimo a un quarto di luce (come `LockScreen.shade(for:)` per Easy).
    func shade(in size: CGSize) -> Double {
        let band = CGRect(x: size.width * 0.08, y: size.height * 0.32, width: size.width * 0.84, height: size.height * 0.6)
        return min(0.8, max(0.52, 1 - 0.2 / max(0.01, light(of: band, in: size))))
    }

    private static let context = CIContext(options: [.cacheIntermediates: false])

    /// Prepara la scena di una copertina. Chiede a Vision dove sono i visi: mai sul thread principale.
    nonisolated static func make(_ image: NSImage, key: String) -> MappaScene? {
        guard let source = image.cgImage(forProposedRect: nil, context: nil, hints: nil), source.width > 8, source.height > 8 else { return nil }
        let handler = VNImageRequestHandler(cgImage: source, options: [:])
        let faces = VNDetectFaceRectanglesRequest()
        let eye = VNGenerateAttentionBasedSaliencyImageRequest()
        try? handler.perform([faces, eye])

        // il viso più grande, in frazioni dall'alto a sinistra; senza visi, dove cade l'occhio
        let face = (faces.results ?? []).map(\.boundingBox).max { $0.width * $0.height < $1.width * $1.height }
        var focus = CGPoint(x: 0.5, y: 0.5)
        if let face { focus = CGPoint(x: face.midX, y: 1 - face.midY) }
        else if let boxes = eye.results?.first?.salientObjects, let first = boxes.first {
            let all = boxes.dropFirst().reduce(first.boundingBox) { $0.union($1.boundingBox) }
            focus = CGPoint(x: all.midX, y: 1 - all.midY)
        }

        let full = CIImage(cgImage: source)
        let extent = full.extent, side = max(extent.width, extent.height)
        // la versione sfocata, in piccolo
        let shrink = min(1, 420 / side)
        let blurred = full.clampedToExtent().applyingGaussianBlur(sigma: side * 0.022).cropped(to: extent)
            .transformed(by: CGAffineTransform(scaleX: shrink, y: shrink))
        let box = CGRect(x: 0, y: 0, width: (extent.width * shrink).rounded(.down), height: (extent.height * shrink).rounded(.down))
        guard let softImage = context.createCGImage(blurred, from: box) else { return nil }

        // la luminosità, in una griglia
        let g = grid
        let small = full.transformed(by: CGAffineTransform(scaleX: CGFloat(g) / extent.width, y: CGFloat(g) / extent.height))
        var pixels = [UInt8](repeating: 0, count: g * g * 4)
        context.render(small, toBitmap: &pixels, rowBytes: g * 4, bounds: CGRect(x: 0, y: 0, width: g, height: g), format: .RGBA8,
                       colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        var luma = [Float](repeating: 0, count: g * g)
        // la prima riga dei dati è la cima dell'immagine
        for i in 0..<(g * g) { luma[i] = (0.2126 * Float(pixels[i * 4]) + 0.7152 * Float(pixels[i * 4 + 1]) + 0.0722 * Float(pixels[i * 4 + 2])) / 255 }

        return MappaScene(key: key, cover: image, source: image, soft: NSImage(cgImage: softImage, size: NSSize(width: softImage.width, height: softImage.height)),
                          aspect: extent.width / extent.height, focus: focus, luma: luma, palette: LockLights.palette(for: image))
    }
}
