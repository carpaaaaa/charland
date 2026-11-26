import AppKit

/// Il segno di Charland, «Rugiada» (scelto da carpa il 17 novembre 2026): quattro gocce con la punta verso il corpo,
/// le due in alto grandi e alzate, le due in basso piccole. Lo stesso tracciato dell'icona,
/// in un quadrato di 1024 con la y verso il basso.
enum CharlandMark {
    static let svgPath = "M491.6 542.1L469.1 680.9C469.1 681.3 469.0 681.7 468.9 682.0C462.6 721.7 428.3 751.0 388.0 751.0C342.7 751.0 306.0 714.3 306.0 669.0C306.0 637.4 324.1 608.7 352.5 595.2C352.5 595.2 352.5 595.2 352.5 595.2C352.8 595.0 353.1 594.8 353.5 594.6L480.2 533.6C486.0 530.8 492.6 535.7 491.6 542.1ZM543.8 533.6L670.5 594.6C670.9 594.8 671.2 595.0 671.5 595.2C671.5 595.2 671.5 595.2 671.5 595.2C699.9 608.7 718.0 637.4 718.0 669.0C718.0 714.3 681.3 751.0 636.0 751.0C595.7 751.0 561.4 721.7 555.1 682.0C555.0 681.7 554.9 681.3 554.9 680.9L532.4 542.1C531.4 535.7 538.0 530.8 543.8 533.6ZM468.8 682.1C468.9 682.1 468.9 682.1 468.9 682.0ZM555.2 682.1L555.1 682.0C555.1 682.1 555.1 682.1 555.2 682.1ZM410.8 340.4L488.8 483.4C491.4 488.2 488.6 494.1 483.3 495.1L324.7 526.2C324.4 526.3 324.0 526.4 323.6 526.4C323.6 526.4 323.5 526.4 323.5 526.4L323.5 526.5C323.5 526.5 323.4 526.5 323.4 526.5C323.4 526.5 323.4 526.5 323.4 526.5C323.4 526.5 323.4 526.5 323.4 526.5C323.4 526.5 323.4 526.5 323.4 526.5C323.4 526.5 323.4 526.5 323.4 526.5C323.3 526.5 323.3 526.5 323.3 526.5L323.3 526.5L323.0 526.5C322.8 526.6 322.5 526.6 322.3 526.6C314.4 528.2 306.3 529.0 298.0 529.0C227.3 529.0 170.0 471.7 170.0 401.0C170.0 330.3 227.3 273.0 298.0 273.0C345.3 273.0 388.5 298.9 410.8 340.4ZM854.0 401.0C854.0 471.7 796.7 529.0 726.0 529.0C717.7 529.0 709.6 528.2 701.7 526.6C701.5 526.6 701.2 526.6 701.0 526.5L700.7 526.5L700.7 526.5C700.7 526.5 700.7 526.5 700.6 526.5C700.6 526.5 700.6 526.5 700.6 526.5C700.6 526.5 700.6 526.5 700.6 526.5C700.6 526.5 700.6 526.5 700.6 526.5C700.6 526.5 700.6 526.5 700.6 526.5C700.6 526.5 700.5 526.5 700.5 526.5L700.5 526.4C700.5 526.4 700.4 526.4 700.4 526.4C700.0 526.4 699.6 526.3 699.3 526.2L540.7 495.1C535.4 494.1 532.6 488.2 535.2 483.4L613.2 340.4C635.5 298.9 678.7 273.0 726.0 273.0C796.7 273.0 854.0 330.3 854.0 401.0ZM321.6 526.7C321.8 526.7 322.0 526.7 322.2 526.6C322.0 526.7 321.8 526.7 321.6 526.7ZM702.4 526.7C702.2 526.7 702.0 526.7 701.8 526.6C702.0 526.7 702.2 526.7 702.4 526.7ZM323.3 526.5C323.3 526.5 323.3 526.5 323.3 526.5ZM700.7 526.5L700.7 526.5C700.7 526.5 700.7 526.5 700.7 526.5ZM323.4 526.5L323.3 526.5L323.3 526.5C323.3 526.5 323.3 526.5 323.3 526.5L323.3 526.5L323.3 526.5L323.4 526.5L323.4 526.5L323.5 526.4L323.5 526.4ZM700.5 526.4L700.6 526.5L700.6 526.5L700.7 526.5L700.7 526.5L700.7 526.5C700.7 526.5 700.7 526.5 700.7 526.5L700.7 526.5L700.6 526.5L700.5 526.4Z"

    /// Il tracciato portato in un riquadro alto 1 (y verso l'alto, come AppKit), largo quanto serve.
    nonisolated(unsafe) static let unitPath: CGPath = {
        let raw = parse(svgPath)
        let box = raw.boundingBoxOfPath
        var t = CGAffineTransform(scaleX: 1 / box.height, y: -1 / box.height)
            .translatedBy(x: -box.minX, y: -box.maxY)
        return raw.copy(using: &t) ?? raw
    }()

    /// Larghezza su altezza.
    static var aspect: CGFloat { unitPath.boundingBoxOfPath.width }

    /// Il segno alto `height` punti, come immagine modello: la barra dei menu lo colora da sola
    /// (nero sullo sfondo chiaro, bianco sullo scuro).
    static func templateImage(height: CGFloat) -> NSImage {
        let size = NSSize(width: ceil(height * aspect), height: height)
        let image = NSImage(size: size, flipped: false) { rect in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            let w = height * aspect
            ctx.translateBy(x: (rect.width - w) / 2, y: 0)
            ctx.scaleBy(x: height, y: height)
            ctx.addPath(unitPath)
            ctx.setFillColor(NSColor.black.cgColor)
            ctx.fillPath()
            return true
        }
        image.isTemplate = true
        return image
    }

    /// Legge un tracciato SVG con soli comandi assoluti M, L, C, Q e Z (quelli che scrive CoreGraphics).
    static func parse(_ d: String) -> CGPath {
        let path = CGMutablePath()
        var tokens: [Substring] = []
        var current = ""
        for ch in d {
            if ch.isLetter {
                if !current.isEmpty { tokens.append(Substring(current)); current = "" }
                tokens.append(Substring(String(ch)))
            } else if ch == " " || ch == "," {
                if !current.isEmpty { tokens.append(Substring(current)); current = "" }
            } else {
                current.append(ch)
            }
        }
        if !current.isEmpty { tokens.append(Substring(current)) }
        var i = 0
        func number() -> CGFloat { defer { i += 1 }; return CGFloat(Double(tokens[i]) ?? 0) }
        func point() -> CGPoint { let x = number(); return CGPoint(x: x, y: number()) }
        while i < tokens.count {
            let command = tokens[i]; i += 1
            switch command {
            case "M": path.move(to: point())
            case "L": path.addLine(to: point())
            case "C": let a = point(), b = point(); path.addCurve(to: point(), control1: a, control2: b)
            case "Q": let a = point(); path.addQuadCurve(to: point(), control: a)
            case "Z": path.closeSubpath()
            default: break
            }
        }
        return path
    }
}
