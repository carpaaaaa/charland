import SwiftUI
import CoreText

/// L'orologio che Charland disegna a copertina aperta, dove quello di macOS resta sotto lo sfondo: deve essere
/// identico a quello che ognuno ha sul proprio blocco (carpa, 18 novembre 2026: «l'orologio deve essere sempre in
/// vetro identico a quello default Apple che ogni persona ha»).
///
/// Misurato sul blocco vero di macOS 27.3 (schermo 1710 x 1107) sovrapponendo i contorni alla foto:
/// - le cifre sono nel carattere dell'orologio di sistema (`ADTNumeric.ttc`, famiglia «.SF Soft Numeric»), col peso che
///   l'utente ha scelto in Impostazioni di Sistema; macOS li tiene in `com.apple.loginwindow`, `ClockFontIdentifier`
///   («soft») e `ClockFontWeight` (313,9 da carpa);
/// - corpo 155 punti (il 14% dell'altezza dello schermo), centrate, linea di base a 263 punti dall'alto. Cresce con
///   l'altezza: sul blocco vero a 1920 x 1080 e a 2560 x 1440 il corpo misurato è 150,5 e 201, quello previsto 151,2 e 201,6;
/// - la data è nel carattere di sistema, peso medio, corpo 31, bianca al 62%, linea di base a 129 punti.
struct LockClock: View {
    var size: CGSize
    /// Senza vetro: per gli scatti fuori schermo (dove il vetro di sistema non si disegna) e per l'orologio finto delle prove.
    var flat = false

    var body: some View {
        TimelineView(.everyMinute) { context in
            let h = size.height / 1107
            let digits = LockClockFace.outline(LockClockFace.time(context.date), size: 155 * h, centerX: size.width / 2, baseline: 263 * h)
            let box = digits.boundingRect.insetBy(dx: -10, dy: -10)
            let shape = LockClockShape(outline: digits.offsetBy(dx: -box.minX, dy: -box.minY))
            ZStack(alignment: .topLeading) {
                Text(LockClockFace.day(context.date))
                    .font(.system(size: 31 * h, weight: .medium))
                    .foregroundStyle(.white.opacity(0.62))
                    .fixedSize()
                    .frame(width: size.width)
                    // la linea di base a 129 punti: il rigo del carattere di sistema comincia 0,952 corpi sopra
                    // (sul blocco vero le lettere cadono sulle stesse righe di pixel di quelle di macOS)
                    .offset(y: (129 - 31 * 0.952) * h)
                Group {
                    if flat {
                        shape.fill(.white.opacity(0.5))
                    } else {
                        LockClockGlass(shape: shape)
                    }
                }
                .frame(width: box.width, height: box.height)
                .offset(x: box.minX, y: box.minY)
            }
            .frame(width: size.width, height: size.height, alignment: .topLeading)
        }
        .allowsHitTesting(false)
    }
}

/// Il vetro delle cifre, come quello dell'orologio di macOS: vetro vero che piega quello che ha dietro, un velo
/// chiaro (sul nero le cifre di Apple sono un grigio medio, 95 su 255, non trasparenti) e la luce sui bordi che
/// guardano in su e in giù. Sui fianchi dritti Apple non mette niente: misurato sul gambo dell'«1».
struct LockClockGlass: View {
    var shape: LockClockShape
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    /// Per le prove: `CHARLAND_BLOCCO_OROLOGIO_VETRO` = `clear`, `regular`, `chiaro`; il velo con `..._VELO`.
    private static let variant = ProcessInfo.processInfo.environment["CHARLAND_BLOCCO_OROLOGIO_VETRO"] ?? "clear"
    /// Quanto bianco c'è nel vetro delle cifre.
    static let veil = Double(ProcessInfo.processInfo.environment["CHARLAND_BLOCCO_OROLOGIO_VELO"] ?? "") ?? 0.25

    var body: some View {
        ZStack {
            if reduceTransparency {
                shape.fill(.white.opacity(0.86))
            } else {
                glass
                shape.fill(.white.opacity(Self.veil))
                // la luce dall'alto e quella di rimbalzo dal basso: un filo netto sul bordo e un chiarore che sfuma dentro
                // (misurato su Apple, dal bordo verso dentro: 236, 135, 119, 111, 105, 103, 99 su un fondo di 95)
                ForEach([1.0, -1.0], id: \.self) { side in
                    edgeLight(shift: 3.0 * side, blur: 1.1).opacity(0.07)
                    edgeLight(shift: 1.4 * side, blur: 0.45).opacity(0.16)
                    edgeLight(shift: 0.6 * side, blur: 0).opacity(1)
                }
            }
        }
    }

    @ViewBuilder private var glass: some View {
        switch Self.variant {
        case "regular":
            Color.clear.glassEffect(.regular, in: shape).environment(\.appearsActive, true).materialActiveAppearance(.active)
        case "chiaro":
            Color.clear.glassEffect(.regular, in: shape).environment(\.appearsActive, true).materialActiveAppearance(.active)
                .environment(\.colorScheme, .light)
        default:
            Color.clear.glassEffect(.clear, in: shape).environment(\.appearsActive, true).materialActiveAppearance(.active)
        }
    }

    /// La parte della forma che resta scoperta spostandone una copia di `shift` punti in verticale: una falce lungo
    /// i bordi che guardano in su (shift positivo) o in giù (negativo), che si assottiglia dove il bordo gira in verticale.
    private func edgeLight(shift: CGFloat, blur: CGFloat) -> some View {
        ZStack {
            shape.fill(.white)
            shape.offset(y: shift).fill(.black).blendMode(.destinationOut)
        }
        .compositingGroup()
        .blur(radius: blur)
        .clipShape(shape)
    }
}

/// Il contorno delle cifre, nelle misure della vista che lo contiene.
struct LockClockShape: Shape {
    var outline: Path
    func path(in rect: CGRect) -> Path { outline }
}

/// Il carattere dell'orologio del blocco di macOS, col peso scelto dall'utente.
@MainActor
enum LockClockFace {
    private static let domain = "com.apple.loginwindow" as CFString

    /// Quale carattere: «soft» è quello di serie.
    static var identifier: String {
        (CFPreferencesCopyAppValue("ClockFontIdentifier" as CFString, domain) as? String) ?? "soft"
    }

    /// Il peso, da 1 a 1000 (l'asse `wght` del carattere).
    static var weight: Double {
        let value = CFPreferencesCopyAppValue("ClockFontWeight" as CFString, domain)
        if let number = value as? NSNumber { return number.doubleValue }
        if let string = value as? String, let number = Double(string) { return number }
        return 400
    }

    /// Le famiglie di `ADTNumeric.ttc`, per come macOS le chiama nelle sue impostazioni. Di certo si conosce solo
    /// «soft» (visto il 18 novembre 2026); le altre sono dedotte dai nomi delle famiglie.
    private static let families: [(key: String, face: String)] = [
        ("slabsoft", ".ADTSlabSoftNumeric-Regular"), ("slab", ".ADTSlabNumeric-Regular"),
        ("newyorksoft", ".NewYorkSoftNumeric-Regular"), ("serifsoft", ".NewYorkSoftNumeric-Regular"),
        ("newyork", ".NewYorkNumeric-Regular"), ("serif", ".NewYorkNumeric-Regular"),
        ("railrounded", ".SFRailRoundedNumeric-Regular"), ("rail", ".SFRailNumeric-Regular"),
        ("stencil", ".SFStencilNumeric-Regular"), ("rounded", ".SFRoundedNumeric-Regular"),
        ("soft", ".SFSoftNumeric-Regular"), ("sf", ".SFNumeric-Regular"),
    ]

    private static var faces: [String: CTFontDescriptor]?

    /// Le facce dell'orologio, lette una volta sola dal file di sistema.
    private static func face(_ name: String) -> CTFontDescriptor? {
        if faces == nil {
            let url = URL(fileURLWithPath: "/System/Library/Fonts/ADTNumeric.ttc") as CFURL
            var found: [String: CTFontDescriptor] = [:]
            let wanted = Set(families.map(\.face))
            for descriptor in (CTFontManagerCreateFontDescriptorsFromURL(url) as? [CTFontDescriptor]) ?? [] {
                if let ps = CTFontDescriptorCopyAttribute(descriptor, kCTFontNameAttribute) as? String, wanted.contains(ps) { found[ps] = descriptor }
            }
            faces = found
        }
        return faces?[name]
    }

    static func font(size: CGFloat) -> CTFont {
        let id = identifier.lowercased().filter { $0.isLetter }
        let name = families.first { id.contains($0.key) }?.face ?? ".SFSoftNumeric-Regular"
        if let descriptor = face(name) ?? face(".SFSoftNumeric-Regular") {
            // 'wght'
            let weighted = CTFontDescriptorCreateCopyWithVariation(descriptor, NSNumber(value: 2003265652), CGFloat(min(1000, max(1, weight))))
            return CTFontCreateWithFontDescriptor(weighted, size, nil)
        }
        // un macOS senza quei caratteri: il più vicino fra quelli pubblici
        let fallback = NSFont.systemFont(ofSize: size, weight: .light)
        return (fallback.fontDescriptor.withDesign(.rounded).flatMap { NSFont(descriptor: $0, size: size) } ?? fallback) as CTFont
    }

    private static var cached: (key: String, path: Path)?

    /// Il contorno di un testo nel carattere dell'orologio: centrato su `centerX` (sul suo ingombro, non sull'inchiostro,
    /// come fa macOS), con la linea di base a `baseline` dall'alto.
    static func outline(_ text: String, size: CGFloat, centerX: CGFloat, baseline: CGFloat) -> Path {
        let key = "\(text)|\(size)|\(centerX)|\(baseline)|\(identifier)|\(weight)"
        if let cached, cached.key == key { return cached.path }
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: font(size: size)]))
        let advance = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        let glyphs = CGMutablePath()
        for run in (CTLineGetGlyphRuns(line) as? [CTRun]) ?? [] {
            let count = CTRunGetGlyphCount(run)
            var ids = [CGGlyph](repeating: 0, count: count), places = [CGPoint](repeating: .zero, count: count)
            CTRunGetGlyphs(run, CFRange(location: 0, length: count), &ids)
            CTRunGetPositions(run, CFRange(location: 0, length: count), &places)
            guard let runFont = (CTRunGetAttributes(run) as NSDictionary)[kCTFontAttributeName] else { continue }
            for i in 0..<count {
                // dal sistema di CoreText (y in su) a quello della vista (y in giù), con la linea di base al suo posto
                var move = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: centerX - advance / 2 + places[i].x, ty: baseline - places[i].y)
                if let glyph = CTFontCreatePathForGlyph(runFont as! CTFont, ids[i], &move) { glyphs.addPath(glyph) }
            }
        }
        let path = Path(glyphs)
        cached = (key, path)
        return path
    }

    private static let clock: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("jmm")
        return formatter
    }()

    /// L'ora come sul blocco: ore e minuti, senza «AM» e «PM».
    static func time(_ date: Date) -> String {
        var text = clock.string(from: date)
        for symbol in [clock.amSymbol, clock.pmSymbol].compactMap({ $0 }) where !symbol.isEmpty { text = text.replacingOccurrences(of: symbol, with: "") }
        return text.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\u{202F}\u{00A0}")))
    }

    /// La data come sul blocco: «Wed 18 Nov».
    static func day(_ date: Date) -> String {
        date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)).replacingOccurrences(of: ",", with: "")
    }
}
