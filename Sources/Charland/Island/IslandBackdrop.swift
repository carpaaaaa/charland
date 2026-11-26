import SwiftUI
import CharlandCore

/// Il bordo dell'isola come forma di SwiftUI. Il tracciato è già nello spazio della finestra.
struct OutlineShape: Shape {
    var path: Path
    func path(in rect: CGRect) -> Path { path }
}

/// Il fondo dell'isola: vetro vero sotto, velo nero sopra, filo di luce sul bordo.
/// Vetro, velo e ritaglio usano lo stesso tracciato, quindi combaciano sempre.
struct IslandBackdrop: View {
    let model: IslandModel
    let appearance: Appearance
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        let shape = OutlineShape(path: model.outline)
        let frame = model.frame
        let open = frame.openness
        // Il vetro c'è sempre (nell'aspetto Nero e vetro), anche chiuso sotto il velo nero pieno:
        // farlo nascere all'apertura costava fotogrammi. Fermo non costa niente.
        let glassOn = appearance.look == .blackGlass && !reduceTransparency && appearance.glass > 0.01 && open >= 0
        ZStack {
            if glassOn {
                // Vetro trasparente di macOS: piega lo sfondo ai bordi come una lente. Il trucco dell'aspetto attivo
                // (`appearsActive` e `materialActiveAppearance`) è quello di Vorssaint (GPL-3.0-or-later, Copyright (C)
                // 2026 Vorssaint), adattato per Charland.
                // Mai quello smerigliato.
                Color.clear
                    .glassEffect(.clear, in: shape)
                    .environment(\.appearsActive, true)
                    .materialActiveAppearance(.active)
            }
            shape.fill(veil(glassOn: glassOn))
            if glassOn {
                // Un rumore invisibile (al massimo 3 livelli su 255) che toglie le strisce di una
                // sfumatura scura su 8 bit: il passaggio dal nero al vetro resta continuo da vicino.
                Image(decorative: DitherNoise.image, scale: 2)
                    .resizable(resizingMode: .tile)
                    .blendMode(.plusLighter)
                    .mask(shape)
            }
            if glassOn, appearance.rim > 0.01 {
                shape.stroke(rim, lineWidth: 1.6)
                    .mask(shape)
            }
        }
        .frame(width: model.stageSize.width, height: model.stageSize.height)
        // Niente `.shadow` qui: col rumore in `plusLighter` obbliga a disegnare l'isola a parte e il vetro di Apple
        // diventa nero pieno (provato il 17 novembre 2026 su uno sfondo a righe: con l'ombra nero, senza il vetro).
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private var stageHeight: Double { Double(model.stageSize.height) }

    /// Quanto vetro si apre dove finisce il contenuto, rispetto al fondo. Con 0,55 resta circa
    /// metà nero sotto l'ultima riga: il bianco si legge anche su una pagina bianca (almeno 3:1).
    static let legibleShare = 0.58

    /// Quanto nero si toglie in fondo. Con Contrasto aumentato resta più scuro.
    private var release: Double {
        contrast == .increased ? min(appearance.glass, 0.45) : appearance.glass
    }

    /// Il velo nero, dall'alto in basso. Nero pieno solo sulla fascia della fotocamera: il notch
    /// vero resta nascosto. Sotto, una sfumatura lunga e morbida fino al vetro in fondo.
    /// La curva parte piatta (nessun gradino sotto il notch) e arriva piatta (nessuna riga sul bordo).
    /// Mentre l'isola si chiude torna nero pieno prima della fine (`openness` va a zero),
    /// così gli ultimi fotogrammi combaciano con il notch a riposo.
    private func veil(glassOn: Bool) -> LinearGradient {
        guard glassOn else {
            return LinearGradient(colors: [.black, .black], startPoint: .top, endPoint: .bottom)
        }
        let frame = model.frame
        let band = model.metrics.notchHeight
        let height = max(band + 1, frame.shape.height)
        // Una curva sola, dal notch al bordo: liscia ovunque (pendenza zero solo ai due capi,
        // nessun punto fermo in mezzo). Passa per "circa metà nero" dove finisce il contenuto,
        // così scritte e simboli bianchi si leggono anche sopra una pagina bianca, e sotto il
        // contenuto continua a schiarire fino al vetro pulito del labbro.
        // Un filo sotto la fascia resta nero pieno, così il bordo basso del notch vero non si vede.
        let start = band + 2
        let span = max(1, height - start)
        let contentEnd = min(height - 8, max(start + 12, frame.blackUntil))
        // Fino al vetro pulito, come l'ha tarato carpa («Vetro» a 1). Col velo degli slider (0,26 di nero anche in fondo)
        // sullo sfondo scuro il labbro di vetro sembrava nero: «non vedo più il vetro nel notch».
        let amount = frame.openness * release
        let tc = min(0.9, max(0.1, (contentEnd - start) / span))
        let curve = VeilCurve(knee: tc, kneeValue: Self.legibleShare)
        var stops: [Gradient.Stop] = [.init(color: .black, location: 0), .init(color: .black, location: min(1, start / stageHeight))]
        stops.reserveCapacity(36)
        // Sedici fermate per tratto, fitte dove la curva piega: 32 invece di 96, con meno errore (sotto mezzo livello
        // su 255). Si ricalcolano a ogni fotogramma dell'apertura, quindi poche e giuste.
        let perSegment = 16
        for i in 1...(perSegment * 2) {
            let t = i <= perSegment ? tc * Double(i) / Double(perSegment)
                : tc + (1 - tc) * Double(i - perSegment) / Double(perSegment)
            let y = start + span * t
            stops.append(.init(color: .black.opacity(1 - amount * curve.value(t)), location: min(1, y / stageHeight)))
        }
        stops.append(.init(color: .black.opacity(1 - amount), location: 1))
        return LinearGradient(stops: stops, startPoint: .top, endPoint: .bottom)
    }

    /// Il filo di luce sul bordo: niente sul nero, sale verso il fondo.
    private var rim: LinearGradient {
        let frame = model.frame
        let height = max(1, frame.shape.height)
        let k = frame.openness * appearance.rim
        func at(_ fraction: Double) -> Double { min(1, height * fraction / stageHeight) }
        // Il più chiaro sul bordo basso: è lì che si vede il vetro (con lo 0,08 degli slider spariva).
        return LinearGradient(stops: [
            .init(color: .white.opacity(0), location: 0),
            .init(color: .white.opacity(0), location: at(0.45)),
            .init(color: .white.opacity(0.12 * k), location: at(0.72)),
            .init(color: .white.opacity(0.30 * k), location: at(0.9)),
            .init(color: .white.opacity(0.45 * k), location: at(1.0)),
            .init(color: .white.opacity(0.45 * k), location: 1),
        ], startPoint: .top, endPoint: .bottom)
    }
}

/// La mattonella di rumore per togliere le strisce dalle sfumature. Creata una volta sola.
enum DitherNoise {
    static let image: CGImage = {
        let side = 128
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        var seed: UInt64 = 0x9E37_79B9_7F4A_7C15
        for i in 0..<(side * side) {
            // Generatore semplice e ripetibile: la mattonella è sempre la stessa.
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            let a = UInt8((seed >> 33) % 3)
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            let b = UInt8((seed >> 33) % 2)
            let v = a + b   // da 0 a 3, più spesso al centro
            pixels[i * 4] = v
            pixels[i * 4 + 1] = v
            pixels[i * 4 + 2] = v
            pixels[i * 4 + 3] = 255
        }
        let provider = CGDataProvider(data: Data(pixels) as CFData)!
        return CGImage(width: side, height: side, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: side * 4,
                       space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    }()
}

/// La curva del velo: quanta parte del vetro si apre, da 0 sotto il notch a 1 sul bordo.
/// È una spline cubica monotona che passa per (0, 0), (ginocchio, valore) e (1, 1):
/// parte piatta (nessun gradino sotto il notch), attraversa il ginocchio senza fermarsi
/// (la pendenza lì è la media armonica dei due tratti) e arriva piatta sul bordo.
struct VeilCurve {
    let knee: Double
    let kneeValue: Double

    func value(_ t: Double) -> Double {
        let t = min(1, max(0, t))
        let d0 = kneeValue / knee
        let d1 = (1 - kneeValue) / (1 - knee)
        let mid = 2 * d0 * d1 / (d0 + d1)
        func hermite(_ u: Double, _ y0: Double, _ y1: Double, _ m0: Double, _ m1: Double, _ h: Double) -> Double {
            let u2 = u * u, u3 = u2 * u
            return (2 * u3 - 3 * u2 + 1) * y0 + (u3 - 2 * u2 + u) * h * m0 + (-2 * u3 + 3 * u2) * y1 + (u3 - u2) * h * m1
        }
        if t <= knee {
            return hermite(t / knee, 0, kneeValue, 0, mid, knee)
        }
        return hermite((t - knee) / (1 - knee), kneeValue, 1, mid, 0, 1 - knee)
    }
}
