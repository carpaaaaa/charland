import SwiftUI

/// La mascotte di un agente al computer, a pixel quadrati, girata di tre quarti verso destra:
/// il fianco sinistro in ombra, gli occhi verso destra, e alla sua destra un portatile con lo
/// schermo dritto e acceso rivolto verso di lei, che le illumina appena la faccia.
/// Tutte e due le manine stanno verso il portatile: mentre lavora battono sulla tastiera e ogni tanto
/// sbatte gli occhi; quando aspetta o ha finito sta ferma, le mani sui tasti, e lo schermo si spegne.
/// Claude ha la sua mascotte arancione (ridisegnata a mano da quella che Claude Code stampa nel
/// terminale); ChatGPT è verde e tonda, Gemini azzurra e viola con l'antenna, le altre AI nel loro colore.
struct AgentMascot: View {
    struct Palette: Equatable {
        var body: Color
        var shade: Color
        var lit: Color
        /// Il portatile: coperchio, base, schermo acceso e spento. E gli occhi: `nil` sono due fori.
        var lid = Color(red: 0.62, green: 0.62, blue: 0.66)
        var base = Color(red: 0.47, green: 0.47, blue: 0.50)
        var screenOn = Color(red: 0.62, green: 0.82, blue: 1.0)
        var screenOff = Color(red: 0.30, green: 0.30, blue: 0.33)
        var eyes: Color? = .black
        /// Un filo di luce in cima al corpo, come il bordo di una lastra.
        var rim: Color? = nil
        /// La luce scende dall'alto: ogni riga di pixel è un poco più tenue di quella sopra (1 = uguali).
        var fade = 1.0

        /// Di vetro (con «Tutto vetro»): bianco più o meno trasparente al posto dei colori, il fianco in ombra più
        /// tenue, lo schermo acceso che è la cosa più chiara, gli occhi due fori.
        static let glass = Palette(body: .white.opacity(0.62), shade: .white.opacity(0.36), lit: .white.opacity(0.88),
                                   lid: .white.opacity(0.52), base: .white.opacity(0.34), screenOn: .white.opacity(0.98),
                                   screenOff: .white.opacity(0.24), eyes: nil, rim: .white.opacity(0.95), fade: 0.5)

        static let claude = Palette(body: Color(red: 0.851, green: 0.467, blue: 0.341),
                                    shade: Color(red: 0.690, green: 0.365, blue: 0.263),
                                    lit: Color(red: 0.925, green: 0.620, blue: 0.510))
        static let codex = Palette(body: Color(red: 0.063, green: 0.639, blue: 0.498),
                                   shade: Color(red: 0.035, green: 0.470, blue: 0.365),
                                   lit: Color(red: 0.400, green: 0.820, blue: 0.690))
        static let gemini = Palette(body: Color(red: 0.300, green: 0.550, blue: 0.960),
                                    shade: Color(red: 0.470, green: 0.380, blue: 0.920),
                                    lit: Color(red: 0.640, green: 0.770, blue: 1.000))
        static func custom(_ tint: Color) -> Palette {
            Palette(body: tint, shade: tint.mix(with: .black, by: 0.3), lit: tint.mix(with: .white, by: 0.35))
        }
    }

    enum Shape: Equatable {
        /// Il corpo squadrato di Claude.
        case square
        /// Angoli smussati.
        case round
        /// Un'antenna in cima.
        case antenna
    }

    var palette: Palette = .claude
    var shape: Shape = .square
    var working: Bool
    /// Lato di un pixel, in punti. 1,5 sono 3 pixel veri sullo schermo Retina: bordi netti.
    var pixel: CGFloat = 1.5

    static let lid = Color(red: 0.62, green: 0.62, blue: 0.66)
    static let base = Color(red: 0.47, green: 0.47, blue: 0.50)
    static let screenOn = Color(red: 0.62, green: 0.82, blue: 1.0)
    static let screenOff = Color(red: 0.30, green: 0.30, blue: 0.33)

    static let columns = 20
    static let rows = 11

    /// Il pixel più grande, a mezzi punti (pixel veri su Retina, quindi bordi netti), con cui la mascotte sta tutta
    /// dentro un cerchio di questo diametro con un filo d'aria. Il disegno visibile occupa 18 × 10 celle: centrato,
    /// il suo angolo sta a √(9² + 5²) ≈ 10,3 pixel dal centro. Nella goccia dell'isola (26,5 punti) viene 1.
    static func pixelFitting(circle diameter: CGFloat, air: CGFloat = 2) -> CGFloat {
        let p = (diameter / 2 - air) / 10.3
        return max(0.5, min(1.5, (p * 2).rounded(.down) / 2))
    }
    /// Un passo dell'animazione; ogni 19 passi sbatte gli occhi.
    static let step = 0.16
    static let blinkEvery = 19
    /// Le due manine battono ognuna col suo ritmo (carpa: «una indipendente dall'altra, non nello stesso identico
    /// modo»): due sequenze diverse e non speculari, così a volte batte una, a volte l'altra, a volte tutte e due.
    /// Una voce per passo, 1 = alzata.
    static let nearHand: [Bool] = [0, 1, 0, 1, 1, 0, 1, 0, 0, 1, 0, 1, 0, 1, 1, 0, 1, 0, 1].map { $0 == 1 }
    static let farHand: [Bool] = [1, 0, 0, 1, 0, 1, 1, 0, 1, 0, 0, 1, 1, 0, 1, 0, 0, 1, 0].map { $0 == 1 }

    var body: some View {
        // I fotogrammi si disegnano una volta sola e li fa scorrere Core Animation, fuori dall'app:
        // mentre un agente lavora l'animazione non costa quasi niente.
        MascotLayer(palette: Glassy.on ? .glass : palette, shape: shape, working: working, pixel: pixel)
            .frame(width: CGFloat(Self.columns) * pixel + 2, height: CGFloat(Self.rows) * pixel + 2)
            .accessibilityHidden(true)
    }

    /// Un fotogramma: ogni manina giù o su, gli occhi aperti o chiusi.
    static func frame(palette: Palette, shape: Shape, working: Bool, nearUp: Bool, farUp: Bool, eyesOpen: Bool,
                      pixel: CGFloat, scale: CGFloat) -> CGImage? {
        let width = Int((CGFloat(columns) * pixel + 2) * scale)
        let height = Int((CGFloat(rows) * pixel + 2) * scale)
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        // Coordinate con l'origine in alto, in punti.
        ctx.translateBy(x: 0, y: CGFloat(height))
        ctx.scaleBy(x: scale, y: -scale)
        let p = pixel
        func cg(_ color: Color) -> CGColor { NSColor(color).usingColorSpace(.deviceRGB)?.cgColor ?? NSColor(color).cgColor }
        // Ogni pezzo sostituisce quello sotto invece di sommarsi: con i colori trasparenti del vetro una manina sopra
        // la tastiera non diventa più chiara di tutte e due.
        ctx.setBlendMode(.copy)
        func fill(_ col: Int, _ row: Int, _ color: Color, width: Int = 1, height: Int = 1) {
            guard palette.fade < 1 else {
                ctx.setFillColor(cg(color))
                ctx.fill(CGRect(x: 1 + CGFloat(col) * p, y: 1 + CGFloat(row) * p, width: CGFloat(width) * p, height: CGFloat(height) * p))
                return
            }
            // Di vetro: riga per riga, più piena in alto dove prende la luce e più tenue verso il fondo.
            for line in row..<(row + height) {
                let k = 1 - (1 - palette.fade) * Double(line) / Double(rows - 1)
                ctx.setFillColor(cg(color.opacity(k)))
                ctx.fill(CGRect(x: 1 + CGFloat(col) * p, y: 1 + CGFloat(line) * p, width: CGFloat(width) * p, height: p))
            }
        }
        func clear(_ col: Int, _ row: Int) {
            ctx.clear(CGRect(x: 1 + CGFloat(col) * p, y: 1 + CGFloat(row) * p, width: p, height: p))
        }
        fill(2, 1, palette.shade, width: 2, height: 7)
        fill(4, 1, palette.body, width: 9, height: 7)
        switch shape {
        case .square: break
        case .round:
            clear(2, 1); clear(12, 1); clear(2, 7); clear(12, 7)
        case .antenna:
            fill(8, 0, palette.lit)
        }
        if working { fill(12, 2, palette.lit, width: 1, height: 5) }
        if let rim = palette.rim {
            fill(shape == .round ? 5 : 4, 1, rim, width: shape == .round ? 7 : 9, height: 1)
        }
        if eyesOpen {
            if let eyes = palette.eyes {
                fill(8, 3, eyes, width: 1, height: 2)
                fill(11, 3, eyes, width: 1, height: 2)
            } else {
                clear(8, 3); clear(8, 4); clear(11, 3); clear(11, 4)
            }
        } else {
            // Occhi chiusi: il corpo copre gli occhi (nessun buco da riempire).
        }
        fill(3, 8, palette.shade, width: 1, height: 2)
        fill(5, 8, palette.body, width: 1, height: 2)
        fill(9, 8, palette.shade, width: 1, height: 2)
        fill(11, 8, palette.body, width: 1, height: 2)
        fill(12, 8, palette.base, width: 8, height: 1)
        let screen = working ? palette.screenOn : palette.screenOff
        fill(17, 1, palette.lid, width: 3, height: 1)
        fill(17, 2, screen, width: 1, height: 6)
        fill(18, 2, palette.lid, width: 2, height: 6)
        // Tutte e due le manine verso il portatile (carpa, 17 novembre): quella lontana è in ombra, una riga più su
        // e un pixel più avanti, come vista di tre quarti; quella vicina si disegna dopo, davanti. Quando la vicina
        // si alza e la lontana preme, la vicina la copre e della lontana resta la punta: è dietro.
        fill(13, working && farUp ? 5 : 6, palette.shade, width: 3, height: 1)
        fill(13, working && nearUp ? 6 : 7, palette.body, width: 2, height: 1)
        return ctx.makeImage()
    }
}

/// La mascotte come livello di Core Animation: i fotogrammi scorrono nel sistema, non nell'app.
struct MascotLayer: NSViewRepresentable {
    let palette: AgentMascot.Palette
    let shape: AgentMascot.Shape
    let working: Bool
    let pixel: CGFloat

    func makeNSView(context: Context) -> MascotLayerView { MascotLayerView() }

    func updateNSView(_ view: MascotLayerView, context: Context) {
        view.configure(palette: palette, shape: shape, working: working, pixel: pixel)
    }
}

final class MascotLayerView: NSView {
    private var key: String?
    private let sprite = CALayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        sprite.magnificationFilter = .nearest
        sprite.contentsGravity = .resize
        layer?.addSublayer(sprite)
    }

    required init?(coder: NSCoder) { fatalError("non usato") }

    /// Solo da guardare: un clic sulla mascotte arriva all'isola (che si apre), non a questa vista di AppKit.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        sprite.frame = bounds
        CATransaction.commit()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        key = nil
    }

    private var params: (AgentMascot.Palette, AgentMascot.Shape, Bool, CGFloat)?

    /// Core Animation toglie le animazioni quando il livello esce dall'albero (l'isola che si apre, una finestra
    /// nuova): rientrando, se la mascotte lavora e l'animazione non c'è più, si rimette.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil, let params, params.2, sprite.animation(forKey: "batte") == nil else { return }
        key = nil
        configure(palette: params.0, shape: params.1, working: params.2, pixel: params.3)
    }

    func configure(palette: AgentMascot.Palette, shape: AgentMascot.Shape, working: Bool, pixel: CGFloat) {
        params = (palette, shape, working, pixel)
        let scale = window?.backingScaleFactor ?? 2
        let newKey = "\(palette.body.description)|\(shape)|\(working)|\(pixel)|\(scale)"
        guard newKey != key || (working && sprite.animation(forKey: "batte") == nil) else { return }
        key = newKey
        sprite.contentsScale = scale
        sprite.removeAllAnimations()
        var cache: [Int: CGImage] = [:]
        func frame(near: Bool, far: Bool, eyes: Bool) -> CGImage? {
            let key = (near ? 1 : 0) | (far ? 2 : 0) | (eyes ? 4 : 0)
            if let image = cache[key] { return image }
            let image = AgentMascot.frame(palette: palette, shape: shape, working: working, nearUp: near, farUp: far,
                                          eyesOpen: eyes, pixel: pixel, scale: scale)
            cache[key] = image
            return image
        }
        guard working else {
            sprite.contents = frame(near: false, far: false, eyes: true)
            return
        }
        // 19 passi da 0,16 s: ogni manina segue la sua sequenza, al primo passo sbatte gli occhi.
        var values: [CGImage] = []
        for tick in 0..<AgentMascot.blinkEvery {
            if let image = frame(near: AgentMascot.nearHand[tick], far: AgentMascot.farHand[tick], eyes: tick != 0) {
                values.append(image)
            }
        }
        sprite.contents = values.last
        let animation = CAKeyframeAnimation(keyPath: "contents")
        animation.values = values
        animation.calculationMode = .discrete
        animation.duration = AgentMascot.step * Double(AgentMascot.blinkEvery)
        animation.repeatCount = .infinity
        animation.isRemovedOnCompletion = false
        sprite.add(animation, forKey: "batte")
    }
}

/// Un conto alla rovescia che scorre solo mentre si vede (vedi `islandShown`).
struct LiveCountdown: View {
    let end: Date
    @Environment(\.islandShown) private var shown

    var body: some View {
        let now = Date.now
        // Mai a capo: «1:59:59» in uno spazio stretto si rimpicciolisce appena invece di spezzarsi in due righe.
        Text(timerInterval: now...max(now, end), pauseTime: shown ? nil : now, countsDown: true)
            .lineLimit(1)
            .minimumScaleFactor(0.75)
    }
}

/// La mascotte di Claude, per chi la usa con il suo nome.
struct ClaudeMascot: View {
    var walking: Bool
    var pixel: CGFloat = 1.5
    var body: some View { AgentMascot(palette: .claude, shape: .square, working: walking, pixel: pixel) }
}

/// Il tempo del turno in corso, che sale da solo: m:ss, oppure h:mm:ss oltre l'ora.
struct TurnTimer: View {
    let start: Date
    var size: CGFloat = 13
    @Environment(\.islandShown) private var shown

    var body: some View {
        // Scorre solo mentre si vede: nascosto resta fermo e non sveglia l'app a ogni secondo.
        Text(timerInterval: start...Date.distantFuture, pauseTime: shown ? nil : start, countsDown: false)
            .font(.system(size: size, weight: .semibold, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(.white)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
    }
}
