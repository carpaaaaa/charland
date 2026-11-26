import AppKit
import simd

/// L'immagine di partenza dello sfondo, letta una volta (ridotta a 4096 px di lato: basta per uno schermo da 5K senza
/// effetti e non pesa troppo).
struct WallpaperSource: @unchecked Sendable {
    let image: CGImage

    init?(url: URL) {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                        kCGImageSourceThumbnailMaxPixelSize: 4096,
                                        kCGImageSourceCreateThumbnailWithTransform: true]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        self.image = image
    }

    init(image: CGImage) { self.image = image }
}

/// La zona senza effetto (carpa, 20 novembre 2026: «in ogni wallpaper puoi scegliere con un rettangolo
/// ridimensionabile una sezione da togliere, per non mettere l'effetto dentro quella sezione»). Il rettangolo è in
/// frazioni dello schermo (0…1), così vale per ogni schermo e per l'anteprima; dentro si vede l'immagine com'è.
struct ClearArea: Sendable, Hashable, Codable {
    var enabled = false
    var x = 0.32, y = 0.3, width = 0.36, height = 0.2
    /// Il bordo morbido, da 0 (netto) a 1 (molto sfumato).
    var feather = 0.25
    /// Gli angoli: 0 a 90 gradi, 0,5 lo smusso di prima, 1 il doppio (carpa, 20 novembre 2026: «fai che possa essere
    /// anche con i bordi a 90 gradi, non solo smussati»).
    var corners = 0.5

    var isFinite: Bool { [x, y, width, height, feather, corners].allSatisfy(\.isFinite) }

    /// Il raggio degli angoli per un rettangolo `w` x `h` su una tela il cui lato corto è `side` (pixel della tela o
    /// punti dell'anteprima: lo stesso smusso in proporzione).
    func cornerRadius(width w: CGFloat, height h: CGFloat, side: CGFloat) -> CGFloat {
        // Mai più della metà del lato corto: oltre, il rettangolo non sarebbe più un rettangolo.
        min(CGFloat(min(max(corners, 0), 1)) * 2 * (min(w, h) * 0.08 + side * 0.006), min(w, h) / 2)
    }

    /// Il rettangolo tenuto dentro lo schermo e non più piccolo del 3%.
    var clamped: ClearArea {
        var c = self
        c.width = min(max(width, 0.03), 1)
        c.height = min(max(height, 0.03), 1)
        c.x = min(max(x, 0), 1 - c.width)
        c.y = min(max(y, 0), 1 - c.height)
        c.feather = min(max(feather, 0), 1)
        c.corners = min(max(corners, 0), 1)
        return c
    }
}

extension ClearArea {
    /// Le scelte salvate da una versione con meno campi restano: i campi che mancano prendono il valore di serie (nella
    /// 1.3 non c'erano gli angoli). Nell'estensione, così resta l'inizializzatore coi campi.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = ClearArea()
        self.init(enabled: try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? d.enabled,
                  x: try c.decodeIfPresent(Double.self, forKey: .x) ?? d.x,
                  y: try c.decodeIfPresent(Double.self, forKey: .y) ?? d.y,
                  width: try c.decodeIfPresent(Double.self, forKey: .width) ?? d.width,
                  height: try c.decodeIfPresent(Double.self, forKey: .height) ?? d.height,
                  feather: try c.decodeIfPresent(Double.self, forKey: .feather) ?? d.feather,
                  corners: try c.decodeIfPresent(Double.self, forKey: .corners) ?? d.corners)
    }
}

/// Gli strumenti comuni dei disegni dello sfondo: pixel, copertura, bagliore, zona senza effetto.
enum WallpaperPixels {

    // MARK: - Zona senza effetto

    /// Mette l'immagine com'è dentro la zona libera, con un bordo morbido centrato sul bordo del rettangolo (metà
    /// dentro, metà fuori: la zona libera è quella disegnata). `effect` è il pezzo `region` della tela (tutta la tela
    /// se nil). `glow`: l'effetto ha il bagliore, e lo ha anche l'immagine nella zona. Si disegna e si fonde solo il
    /// riquadro della zona.
    static func applyClear(_ area: ClearArea, effect: CGImage, source: CGImage, canvas: CGSize, region: CGRect?,
                           glow: Bool = false, spread: CGFloat = 1) -> CGImage? {
        let a = area.clamped
        let rect = (region ?? CGRect(origin: .zero, size: canvas)).integral
        let w = effect.width, h = effect.height
        let zx = CGFloat(a.x) * canvas.width, zy = CGFloat(a.y) * canvas.height
        let zw = CGFloat(a.width) * canvas.width, zh = CGFloat(a.height) * canvas.height
        let side = min(canvas.width, canvas.height)
        let fade = Float(1 + a.feather * Double(side) * 0.03)
        let radius = Float(a.cornerRadius(width: zw, height: zh, side: side))
        // Il riquadro toccato (zona più metà sfumatura), in pixel del pezzo.
        let pad = CGFloat(fade) + 1
        let x0 = max(0, Int((zx - pad - rect.minX).rounded(.down))), x1 = min(w, Int((zx + zw + pad - rect.minX).rounded(.up)))
        let y0 = max(0, Int((zy - pad - rect.minY).rounded(.down))), y1 = min(h, Int((zy + zh + pad - rect.minY).rounded(.up)))
        guard x1 > x0, y1 > y0, var out = bytes(of: effect) else { return effect }
        let box = CGRect(x: rect.minX + CGFloat(x0), y: rect.minY + CGFloat(y0), width: CGFloat(x1 - x0), height: CGFloat(y1 - y0))
        let bw = x1 - x0, bh = y1 - y0
        guard let plain = PlainRenderer.render(source, canvas: canvas, region: box, glow: glow, spread: spread),
              let under = pixels(of: plain, width: bw, height: bh) else { return effect }
        let cx = Float(zx + zw / 2), cy = Float(zy + zh / 2)
        let hx = Float(zw / 2), hy = Float(zh / 2)
        let ox = Float(rect.minX), oy = Float(rect.minY)
        for y in y0..<y1 {
            for x in x0..<x1 {
                // Distanza con segno dal rettangolo arrotondato (negativa dentro).
                let qx = abs(Float(x) + 0.5 + ox - cx) - (hx - radius), qy = abs(Float(y) + 0.5 + oy - cy) - (hy - radius)
                let outside = (max(qx, 0) * max(qx, 0) + max(qy, 0) * max(qy, 0)).squareRoot()
                let d = outside + min(max(qx, qy), 0) - radius
                let m = 1 - smoothstep(-fade, fade, d)
                guard m > 0.002 else { continue }
                let i = (y * w + x) * 4, j = ((y - y0) * bw + (x - x0)) * 4
                for ch in 0..<3 {
                    out[i + ch] = UInt8(Float(out[i + ch]) * (1 - m) + Float(under[j + ch]) * m + 0.5)
                }
            }
        }
        return makeImage(out, width: w, height: h)
    }

    /// I byte RGBA di un'immagine fatta da noi (letti dai suoi dati, senza ridisegnarla); per le altre, ridisegnata.
    private static func bytes(of image: CGImage) -> [UInt8]? {
        if image.bitsPerPixel == 32, image.bytesPerRow == image.width * 4, image.bitsPerComponent == 8,
           image.alphaInfo == .noneSkipLast, let data = image.dataProvider?.data, let base = CFDataGetBytePtr(data),
           CFDataGetLength(data) >= image.width * image.height * 4 {
            return Array(UnsafeBufferPointer(start: base, count: image.width * image.height * 4))
        }
        return pixels(of: image, width: image.width, height: image.height)
    }

    // MARK: - Bagliore

    /// Un quarto della misura, solo le parti chiare, tre passate di sfocatura sempre più larghe, sommate al 36%.
    /// `spread` sotto 1 stringe l'alone per un disegno rimpicciolito.
    static func addGlow(_ px: inout [UInt8], width W: Int, height H: Int, spread: Float = 1) {
        let qw = max(1, W / 4), qh = max(1, H / 4)
        var a = [Float](repeating: 0, count: qw * qh * 3)
        for y in 0..<qh {
            for x in 0..<qw {
                var s = SIMD3<Float>(repeating: 0), n: Float = 0
                for dy in 0..<4 {
                    let sy = min(H - 1, y * 4 + dy)
                    for dx in 0..<4 {
                        let sx = min(W - 1, x * 4 + dx), i = (sy * W + sx) * 4
                        s += SIMD3(Float(px[i]), Float(px[i + 1]), Float(px[i + 2])); n += 1
                    }
                }
                s /= n * 255
                s *= smoothstep(0.18, 0.85, s.max())
                let o = (y * qw + x) * 3
                a[o] = s.x; a[o + 1] = s.y; a[o + 2] = s.z
            }
        }
        var b = a
        for pass in 1...3 {
            blur(a, into: &b, qw, qh, dx: Float(pass) * spread, dy: 0)
            blur(b, into: &a, qw, qh, dx: 0, dy: Float(pass) * spread)
        }
        let glow = a
        // Somma, leggendo il quarto di misura con l'interpolazione bilineare.
        px.withUnsafeMutableBufferPointer { dst in
            let target = Target(base: dst.baseAddress!)
            DispatchQueue.concurrentPerform(iterations: H) { y in
                let base = target.base
                let fy = min(max((Float(y) + 0.5) / 4 - 0.5, 0), Float(qh - 1))
                let y0 = Int(fy), y1 = min(qh - 1, y0 + 1), ty = fy - Float(y0)
                for x in 0..<W {
                    let fx = min(max((Float(x) + 0.5) / 4 - 0.5, 0), Float(qw - 1))
                    let x0 = Int(fx), x1 = min(qw - 1, x0 + 1), tx = fx - Float(x0)
                    let i = (y * W + x) * 4
                    for ch in 0..<3 {
                        let v00 = glow[(y0 * qw + x0) * 3 + ch], v10 = glow[(y0 * qw + x1) * 3 + ch]
                        let v01 = glow[(y1 * qw + x0) * 3 + ch], v11 = glow[(y1 * qw + x1) * 3 + ch]
                        let v = (v00 * (1 - tx) + v10 * tx) * (1 - ty) + (v01 * (1 - tx) + v11 * tx) * ty
                        base[i + ch] = UInt8(clamping: Int(Float(base[i + ch]) + v * 0.36 * 255 + 0.5))
                    }
                }
            }
        }
    }

    /// Una passata gaussiana a cinque prese, lungo x o lungo y, con passo `dx`/`dy`.
    private static func blur(_ src: [Float], into dst: inout [Float], _ w: Int, _ h: Int, dx: Float, dy: Float) {
        let offsets: [Float] = [0, 1.3846, 3.2308], weights: [Float] = [0.227027, 0.3162162, 0.0702703]
        @Sendable @inline(__always) func at(_ x: Float, _ y: Float, _ ch: Int) -> Float {
            let fx = min(max(x, 0), Float(w - 1)), fy = min(max(y, 0), Float(h - 1))
            let x0 = Int(fx), y0 = Int(fy), x1 = min(w - 1, x0 + 1), y1 = min(h - 1, y0 + 1)
            let tx = fx - Float(x0), ty = fy - Float(y0)
            let v00 = src[(y0 * w + x0) * 3 + ch], v10 = src[(y0 * w + x1) * 3 + ch]
            let v01 = src[(y1 * w + x0) * 3 + ch], v11 = src[(y1 * w + x1) * 3 + ch]
            return (v00 * (1 - tx) + v10 * tx) * (1 - ty) + (v01 * (1 - tx) + v11 * tx) * ty
        }
        dst.withUnsafeMutableBufferPointer { buffer in
            let out = FloatTarget(base: buffer.baseAddress!)
            DispatchQueue.concurrentPerform(iterations: h) { y in
                for x in 0..<w {
                    for ch in 0..<3 {
                        var s = src[(y * w + x) * 3 + ch] * weights[0]
                        for k in 1...2 {
                            let ox = dx * offsets[k], oy = dy * offsets[k]
                            s += (at(Float(x) + ox, Float(y) + oy, ch) + at(Float(x) - ox, Float(y) - oy, ch)) * weights[k]
                        }
                        out.base[(y * w + x) * 3 + ch] = s
                    }
                }
            }
        }
    }

    private struct Target: @unchecked Sendable { let base: UnsafeMutablePointer<UInt8> }
    private struct FloatTarget: @unchecked Sendable { let base: UnsafeMutablePointer<Float> }

    // MARK: - Pixel

    /// Dove disegnare l'immagine in un buffer ridotto di `unit` (con la prima riga in alto): centrata sul centro della
    /// tela, perché il pixel i del buffer copra la tela da i·unit a (i+1)·unit; un poco più grande quando serve,
    /// perché copra anche l'ultima colonna e l'ultima riga del buffer (arrotondate in su) invece di lasciarle nere.
    static func coverRect(_ image: CGImage, canvas: CGSize, unit: CGFloat, bufferWidth w: Int, bufferHeight h: Int) -> CGRect {
        let iw = CGFloat(image.width), ih = CGFloat(image.height)
        let vw = canvas.width / unit, vh = canvas.height / unit
        let k = max(vw / iw, vh / ih, (2 * CGFloat(w) - vw) / iw, (2 * CGFloat(h) - vh) / ih)
        let dw = iw * k, dh = ih * k
        return CGRect(x: (vw - dw) / 2, y: (vh - dh) / 2, width: dw, height: dh)
    }

    /// I pixel RGBA in sRGB, con la prima riga in alto.
    static func pixels(of image: CGImage, width: Int, height: Int, rect: CGRect? = nil) -> [UInt8]? {
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let ok = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let ctx = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.interpolationQuality = .high
            ctx.setFillColor(CGColor(gray: 0, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
            // CGContext ha l'origine in basso: la riga 0 del buffer è comunque quella in alto dell'immagine.
            let r = rect ?? CGRect(x: 0, y: 0, width: width, height: height)
            ctx.draw(image, in: CGRect(x: r.minX, y: CGFloat(height) - r.maxY, width: r.width, height: r.height))
            return true
        }
        return ok ? bytes : nil
    }

    static func makeImage(_ bytes: [UInt8], width: Int, height: Int) -> CGImage? {
        guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    // MARK: - Strumenti

    static func luma(_ c: SIMD3<Float>) -> Float { 0.2126 * c.x + 0.7152 * c.y + 0.0722 * c.z }

    @inline(__always)
    static func smoothstep(_ a: Float, _ b: Float, _ x: Float) -> Float {
        guard b != a else { return x < a ? 0 : 1 }
        let t = min(max((x - a) / (b - a), 0), 1)
        return t * t * (3 - 2 * t)
    }
}
