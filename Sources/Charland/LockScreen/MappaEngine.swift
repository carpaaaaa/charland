import SwiftUI
import CoreImage
import CoreText
import CharlandCore

/// I temi della copertina aperta sul blocco schermo. Nelle impostazioni si chiamano Simple, Constellation e Dynamic
/// (carpa, 19 novembre 2026: «ci sarà simple constellation e dynamic»); i nomi salvati restano `easy`, `mappa`, `montaggio`.
enum LockTheme: String, CaseIterable, Identifiable {
    /// Simple: la copertina come nell'app Musica, foto, comandi, testo in colonna.
    case easy
    /// Constellation: la copertina a tutto schermo e la canzone che ci disegna sopra una costellazione per strofa.
    case mappa
    /// Dynamic: la copertina a tutto schermo montata come un edit, un'inquadratura per verso, parole che sbattono in scena.
    case montaggio
    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .easy: "Simple"
        case .mappa: "Constellation"
        case .montaggio: "Dynamic"
        }
    }

    /// Quanto dura aprirsi e richiudersi.
    func openSeconds(_ opening: Bool) -> Double {
        switch self {
        case .easy: opening ? 0.6 : 0.4
        case .mappa, .montaggio: opening ? 1.0 : 0.62
        }
    }

    /// Per le prove: `CHARLAND_BLOCCO_TEMA=mappa` forza il tema senza toccare le impostazioni.
    static let forced = ProcessInfo.processInfo.environment["CHARLAND_BLOCCO_TEMA"].flatMap(LockTheme.init(rawValue:))
}

/// L'etichetta di una parola, già disegnata al corpo `body` (quello che avrà a canzone finita): `size` è la sua
/// misura in punti a quel corpo, margini compresi.
struct MappaLabel: @unchecked Sendable {
    var image: CGImage?
    var size: CGSize
    var body: CGFloat
    /// Le lettere una per una, nelle misure dell'etichetta: servono solo nell'attimo in cui la parola viene cantata,
    /// quando ogni lettera si muove per conto suo.
    var glyphs: [MappaGlyph] = []
    /// La sfumatura delle lettere e quella della stella, nei colori della copertina (carpa, 18 novembre 2026: «le
    /// stelle abbiano un po' un gradient e anche le parole seguendo i colori della copertina»). Quella delle lettere
    /// è già nell'immagine; serve qui per le lettere che nascono una per una.
    var ink = Gradient(colors: [.white, .white])
    /// La stella della parola, già disegnata (`MappaStar`).
    var star = MappaStar()
    /// Il margine attorno alle lettere dentro l'immagine, in punti: la sfumatura va da un angolo all'altro delle lettere.
    static let margin: CGFloat = 13

    /// Da dove a dove va la sfumatura dentro un'etichetta grande `size`: di traverso, da in alto a sinistra a in basso a destra.
    static func sweep(_ size: CGSize) -> (from: CGPoint, to: CGPoint) {
        (CGPoint(x: margin, y: margin), CGPoint(x: size.width - margin, y: size.height - margin))
    }
}

/// Una lettera di un'etichetta: il suo contorno, e il punto della linea di base attorno a cui si muove.
struct MappaGlyph: @unchecked Sendable {
    var outline: Path
    var mid: CGFloat
    var base: CGFloat
}

/// Una strofa pronta da disegnare: la sua costellazione, le etichette, dove sta ogni stella sullo schermo e quando
/// se ne va.
struct MappaStanza: @unchecked Sendable {
    var map: SongMap
    var labels: [MappaLabel]
    /// La stella di ogni parola sullo schermo. La scritta sta sotto, centrata, e crescendo si allunga verso il basso:
    /// la stella e le sue linee non si spostano mai.
    var stars: [CGPoint]
    /// Quanto sono grandi le parole su questo schermo rispetto al corpo base (lo schermo, e la strofa rimpicciolita).
    var unit: CGFloat
    /// Quando comincia a sciogliersi: poco prima che cominci la strofa dopo, o qualche secondo dopo la sua fine.
    var leave: Double
    /// Quanto in fretta si scioglie (1 col suo tempo): se la strofa dopo le sta addosso fa prima, così le due
    /// costellazioni non restano una sopra l'altra.
    var quick: Double = 1
    /// Dove si ferma la linea prima di ogni stella, in punti sullo schermo: le stelle grandi la tengono più lontana.
    var gaps: [CGFloat] = []

    /// La linea fra due stelle, dritta, che si ferma un poco prima di ognuna, come nelle carte del cielo.
    /// Da `from` a `to` della sua lunghezza (da 0 a 1), nel verso dalla prima stella alla seconda.
    func line(_ road: SongMap.Road, from: CGFloat = 0, to: CGFloat = 1) -> (a: CGPoint, b: CGPoint)? {
        let a = stars[road.a], b = stars[road.b]
        let dx = b.x - a.x, dy = b.y - a.y, far = hypot(dx, dy)
        let gapA = road.a < gaps.count ? gaps[road.a] : 11 * unit, gapB = road.b < gaps.count ? gaps[road.b] : 11 * unit
        guard far > gapA + gapB + 2 else { return nil }
        let start = gapA / far, span = 1 - (gapA + gapB) / far
        let t0 = start + span * from, t1 = start + span * to
        return (CGPoint(x: a.x + dx * t0, y: a.y + dy * t0), CGPoint(x: a.x + dx * t1, y: a.y + dy * t1))
    }
}

/// Un'immagine da passare da un thread all'altro (`CGImage` non si dichiara `Sendable`, ma non cambia mai).
struct ImageBox: @unchecked Sendable {
    let image: CGImage
    init(_ image: CGImage) { self.image = image }
}

/// Lo stato di «Mappa»: la scena del brano e le mappe delle sue strofe.
@MainActor @Observable
final class MappaState {
    var scene: MappaScene?
    /// La scena del brano di prima, finché dura la dissolvenza.
    var old: MappaScene?
    var sceneT = 1.0
    /// A che punto del giro è la luce del bordo, in giri: avanza più svelta sul battito e sulle parole.
    var spin = 0.0
    /// Il punto della canzone che la mappa disegna, un soffio avanti (`Mappa.lead`). Segue quello detto dall'app che
    /// suona, ma non torna mai indietro di poco: alla pausa certe app dicono un punto appena prima di quello a cui
    /// eravamo arrivati, e l'ultima parola cantata spariva con la sua linea (carpa, 18 novembre 2026: «quando metto in
    /// pausa la costellazione cambia forma»). Torna indietro solo per un salto vero (la barra trascinata, un brano nuovo).
    var time = 0.0
    /// Le pause del brano: a che punto della mappa, e per quanti secondi veri. In pausa quello che è cantato resta
    /// fermo, ma le piccole animazioni già partite (le lettere che salgono, la stella che brilla, la linea appena
    /// percorsa) vanno avanti col tempo vero e si posano, invece di restare congelate a metà; alla ripresa non ripartono.
    /// Una pausa smette di allungarsi dopo `Mappa.holdCap` secondi: da lì non c'è più niente da posare, e la
    /// costellazione non si ridisegna più finché la musica è ferma (il bordo sì: le sue luci girano anche in pausa).
    fileprivate(set) var holds: [(at: Double, length: Double)] = []
    @ObservationIgnored fileprivate var holding = false
    @ObservationIgnored fileprivate var timeFor = ""
    /// L'ultimo rilascio della barra già seguito (`LockModel.seekCount`).
    @ObservationIgnored fileprivate var seenSeek = 0
    /// Quanto è svelto il brano adesso: la velocità della luce del bordo lo insegue piano.
    @ObservationIgnored fileprivate var energy = 0.3
    /// Le strofe del testo che suona, quando sono pronte.
    private(set) var stanzas: [MappaStanza] = []
    /// Tutte le parole del brano in ordine, col punto dello schermo in cui vengono cantate: dice dove si sta cantando.
    @ObservationIgnored private(set) var trail: [(time: Double, point: CGPoint)] = []
    /// Di quale testo, di quale schermo e di quale copertina sono le strofe (`LockModel.rowsStamp`, la misura, e il
    /// brano da cui vengono i colori, o un trattino se sono bianche).
    @ObservationIgnored private(set) var mapStamp = ""

    @ObservationIgnored fileprivate var charting = ""
    @ObservationIgnored fileprivate var preparing = ""
    /// La copertina da cui si sta preparando la scena di `preparing`.
    @ObservationIgnored fileprivate var preparingArt: NSImage?
    @ObservationIgnored fileprivate var kept: [MappaScene] = []
    /// Il brano senza copertina per cui si aspetta di togliere la scena del brano di prima, e l'attesa.
    @ObservationIgnored fileprivate var bareFor = ""
    @ObservationIgnored fileprivate var bare: Task<Void, Never>?
    /// Il brano che la mappa sta seguendo: quando cambia, la costellazione di prima si scioglie (`leaving`).
    @ObservationIgnored fileprivate var followed = ""
    /// La costellazione del brano che se ne va (carpa, 19 novembre 2026: «e poi transizione costellazione»): ferma al
    /// suo ultimo istante, si scioglie nell'ordine in cui è nata mentre la copertina nuova entra. Lo scioglimento conta
    /// come una pausa lunga quanto il tempo passato (`holds`), così le parole che nel brano vecchio venivano dopo non
    /// compaiono.
    struct Leaving {
        var stanzas: [MappaStanza]
        var trail: [(time: Double, point: CGPoint)]
        var time: Double
        var palette: [SIMD3<Double>]
        /// Quando è cambiato il brano, in `now`.
        var at: Double
    }
    fileprivate(set) var leaving: Leaving?

    /// Per quale brano si è già chiesta la copertina grande, e la copertina grande arrivata (`BigArtwork`).
    @ObservationIgnored fileprivate var sharpFor = ""
    /// La copertina dell'app usata come confronto nella richiesta, e il numero della richiesta più recente.
    @ObservationIgnored fileprivate var sharpArt: NSImage?
    @ObservationIgnored fileprivate var sharpToken = 0
    @ObservationIgnored fileprivate var sharp: (key: String, image: CGImage)?
    @ObservationIgnored fileprivate var pointer = CGPoint.zero
    @ObservationIgnored fileprivate var movedAt = -10.0
    @ObservationIgnored fileprivate(set) var now = 0.0
    /// Il bordo che gira: quello che non cambia per una misura dello schermo, e i colori della copertina lungo il giro.
    @ObservationIgnored private var edgeFor: (size: CGSize, notch: CGRect)?
    @ObservationIgnored private var edgeShape: MappaEdge?
    @ObservationIgnored private var tintFor = ""
    @ObservationIgnored private var tint: [SIMD3<Float>] = []
    /// Cambiano quando si rifanno il bordo o i colori: entrano nella chiave del fotogramma.
    @ObservationIgnored private var edgeVersion = 0
    @ObservationIgnored private var tintVersion = 0
    /// Il bordo dell'ultimo fotogramma disegnato, e per quali numeri: chiesto due volte nello stesso fotogramma si
    /// calcola una volta sola.
    @ObservationIgnored private var paintedFor: [Int] = []
    @ObservationIgnored private var painted: MappaEdge.Frame?
    /// La macchia di luce della voce, disegnata una volta.
    @ObservationIgnored private(set) lazy var spot: NSImage? = Mappa.spot()

    /// Di quale brano sono le strofe: al cambio brano, finché arriva il testo nuovo, quelle vecchie non si disegnano
    /// col punto del brano nuovo (comparivano per un attimo, deboli, parole di un'altra strofa del brano di prima).
    @ObservationIgnored private(set) var stanzasFor = ""

    fileprivate func set(_ stanzas: [MappaStanza], stamp: String, for track: String = "") {
        trail = stanzas.flatMap { stanza in stanza.map.steps.map { (time: $0.time, point: stanza.stars[$0.node]) } }
        mapStamp = stamp
        stanzasFor = track
        self.stanzas = stanzas
    }

    /// Il bordo dello schermo nelle sue misure: il contorno, l'alone in piccolo, il filo a pezzi. Si prepara una volta.
    func edge(size: CGSize, notch: CGRect) -> MappaEdge? {
        if edgeShape == nil || edgeFor?.size != size || edgeFor?.notch != notch {
            edgeShape = MappaEdge(size: size, notch: notch)
            edgeFor = (size, notch)
            edgeVersion &+= 1
        }
        return edgeShape
    }

    /// I colori della copertina lungo il giro dello schermo, uno che sfuma nell'altro.
    func tint(_ scene: MappaScene?) -> [SIMD3<Float>] {
        let key = scene?.key ?? "-"
        if key != tintFor || tint.isEmpty { tint = MappaEdge.tint(scene?.palette ?? []); tintFor = key; tintVersion &+= 1 }
        return tint
    }

    /// Il bordo di questo fotogramma: i colori girati di `hue` gradi, le due luci di `spin` giri, accesi quanto `level`.
    func edgeFrame(size: CGSize, notch: CGRect, hue: Double, spin: Double, level: Double, still: Bool) -> MappaEdge.Frame? {
        guard let edge = edge(size: size, notch: notch) else { return nil }
        let colors = tint(scene)
        let steps = Double(MappaEdge.steps)
        let shift = (Int((hue / 360 * steps).rounded()), Int((spin * steps).rounded()))
        let key = [shift.0, shift.1, Int((level * 1000).rounded()), still ? 1 : 0, edgeVersion, tintVersion]
        if key != paintedFor || painted == nil { painted = edge.paint(colors: colors, hue: shift.0, spin: shift.1, level: Float(level), still: still); paintedFor = key }
        return painted
    }
}

/// Il bordo dello schermo: una luce soffusa nei colori della copertina che gira attorno allo schermo, notch compreso,
/// con due luci una di fronte all'altra che corrono col passo del brano, e il filo sottile che si accende dove passano.
///
/// Prima erano tre immagini a tutto schermo (l'alone, la ruota dei colori e le due luci, queste due grandi quanto la
/// diagonale e girate a ogni fotogramma) fatte da maschera l'una all'altra: sei passaggi a tutto schermo a ogni
/// fotogramma, da soli 8 ms di scheda video su 16,7 (misurato con Instruments il 18 novembre 2026). Bastava poco in
/// più, il lettore di vetro che compare o la pausa, e il blocco perdeva fotogrammi (carpa: «lagga un bel po'»).
/// Ora l'alone si calcola qui in piccolo (un pixel ogni `cell` punti: è tutto sfumato) con una tabella per i colori e
/// una per le luci, e diventa un'immagine sola, già colorata; il filo è una fila di pezzi corti, ognuno del suo colore.
/// Stesso aspetto, nessuna maschera.
struct MappaEdge {
    /// Quanti punti per pixel ha la griglia dell'alone: 4 sullo schermo del portatile; sugli schermi grandi di più, così
    /// il conto di ogni fotogramma resta sui 130 mila pixel (l'alone più stretto è sfumato su 9 punti: non si vede).
    static func cell(for size: CGSize) -> CGFloat {
        max(4, (size.width * size.height / 130_000).squareRoot().rounded(.up))
    }
    /// In quanti passi è diviso un giro: abbastanza fini che la luce scivoli senza scatti.
    static let steps = 4096
    /// Quanto è largo il filo.
    static let lineWidth: CGFloat = 2.2

    let size: CGSize
    let width: Int, height: Int
    /// L'alone in ogni pixel della griglia, da 0 a 1.
    let halo: [Float]
    /// A che punto del giro attorno al centro dello schermo sta ogni pixel, in `steps`esimi (0 a destra, in senso orario).
    let turn: [UInt16]
    /// Il filo: il contorno come linea spezzata fitta (`pieceSize` punti per pezzo, l'ultimo uguale al primo) e il
    /// punto del giro di ogni pezzo. Un tratto è un pezzo continuo di questa linea: due tratti di fila hanno l'estremo
    /// in comune esatto, e dove si toccano il filo non ha né puntini né buchi (coi pezzi ritagliati dal contorno gli
    /// estremi non combaciavano al millesimo, e a ogni giuntura c'era un puntino più chiaro).
    let points: [CGPoint]
    let pieceTurns: [Int]
    static let pieceSize = 4

    /// Quello che si disegna in un fotogramma: l'alone già colorato e il filo, a tratti di un colore solo (rosso,
    /// verde, blu e quanto si vede). Un tratto unisce i pezzi da `from` a `to` (escluso) che hanno quasi lo stesso
    /// colore: i pezzi sono circa 940, i tratti un quarto. Disegnarli tutti uno per uno costava sul thread principale
    /// (visto sul blocco vero col campionatore: il filo era un terzo del lavoro).
    struct Frame {
        var glow: CGImage?
        var line: [(from: Int, to: Int, color: SIMD4<Float>)]
    }
    /// Di quanto possono scostarsi i colori dei pezzi dentro un tratto, già moltiplicati per quanto si vedono: meno
    /// di tre livelli su 255, non si vede.
    static let lineTolerance: Float = 0.01

    init?(size: CGSize, notch: CGRect) {
        guard size.width > 0, size.height > 0 else { return nil }
        self.size = size
        let outline = Mappa.outline(size: size, notch: notch)
        let cell = Self.cell(for: size)
        let w = Int((size.width / cell).rounded(.up)), h = Int((size.height / cell).rounded(.up))
        width = w; height = h
        // l'alone di sempre (il contorno sfumato tre volte), rimpicciolito alla griglia
        var halo = [Float](repeating: 0, count: w * h)
        if let image = Mappa.halo(outline, size: size)?.cgImage(forProposedRect: nil, context: nil, hints: nil),
           let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                               bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
            ctx.interpolationQuality = .high
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            if let data = ctx.data {
                let bytes = data.bindMemory(to: UInt8.self, capacity: w * h * 4)
                for i in 0..<(w * h) { halo[i] = Float(bytes[i * 4 + 3]) / 255 }
            }
        }
        self.halo = halo
        // il punto del giro di ogni pixel, attorno al centro dello schermo (la y va in giù: si gira in senso orario)
        var turn = [UInt16](repeating: 0, count: w * h)
        let cx = Double(size.width) / 2, cy = Double(size.height) / 2
        let sx = Double(size.width) / Double(w), sy = Double(size.height) / Double(h)
        for y in 0..<h {
            for x in 0..<w {
                turn[y * w + x] = UInt16(Self.step(atan2((Double(y) + 0.5) * sy - cy, (Double(x) + 0.5) * sx - cx)))
            }
        }
        self.turn = turn
        // il filo: pezzi corti (sei punti circa) di una linea spezzata con un punto ogni punto e mezzo
        let dense = Self.flatten(outline)
        var lengths = [CGFloat](repeating: 0, count: dense.count)
        for i in 1..<max(1, dense.count) { lengths[i] = lengths[i - 1] + hypot(dense[i].x - dense[i - 1].x, dense[i].y - dense[i - 1].y) }
        let total = lengths.last ?? 0
        let count = max(240, Int((total / 6).rounded()))
        let steps = count * Self.pieceSize
        var points: [CGPoint] = [], j = 0
        for k in 0...steps {
            let at = total * CGFloat(k) / CGFloat(steps)
            while j + 1 < dense.count - 1, lengths[j + 1] < at { j += 1 }
            let span = j + 1 < dense.count ? lengths[j + 1] - lengths[j] : 0
            let f = span > 0 ? (at - lengths[j]) / span : 0
            let a = dense[j], b = dense[min(j + 1, dense.count - 1)]
            points.append(CGPoint(x: a.x + (b.x - a.x) * f, y: a.y + (b.y - a.y) * f))
        }
        if let first = points.first { points[points.count - 1] = first }
        self.points = points
        pieceTurns = (0..<count).map { k in
            let mid = points[k * Self.pieceSize + Self.pieceSize / 2]
            return Self.step(atan2(Double(mid.y) - cy, Double(mid.x) - cx))
        }
    }

    /// Un contorno come linea spezzata: le linee così come sono, le curve in sedici passi.
    static func flatten(_ path: Path) -> [CGPoint] {
        var out: [CGPoint] = [], last = CGPoint.zero, start = CGPoint.zero
        path.forEach { element in
            switch element {
            case .move(let to):
                out.append(to); last = to; start = to
            case .line(let to):
                out.append(to); last = to
            case .quadCurve(let to, let c):
                for i in 1...16 {
                    let t = CGFloat(i) / 16, u = 1 - t
                    out.append(CGPoint(x: u * u * last.x + 2 * u * t * c.x + t * t * to.x, y: u * u * last.y + 2 * u * t * c.y + t * t * to.y))
                }
                last = to
            case .curve(let to, let c1, let c2):
                for i in 1...16 {
                    let t = CGFloat(i) / 16, u = 1 - t
                    let a = u * u * u, b = 3 * u * u * t, c = 3 * u * t * t, d = t * t * t
                    out.append(CGPoint(x: a * last.x + b * c1.x + c * c2.x + d * to.x, y: a * last.y + b * c1.y + c * c2.y + d * to.y))
                }
                last = to
            case .closeSubpath:
                out.append(start); last = start
            }
        }
        // via i punti doppi: un tratto lungo zero non ha direzione
        var clean: [CGPoint] = []
        for p in out where clean.last.map({ hypot($0.x - p.x, $0.y - p.y) > 0.01 }) ?? true { clean.append(p) }
        return clean
    }

    /// La linea di un tratto, dal pezzo `from` al pezzo `to` (escluso).
    func line(from: Int, to: Int) -> Path {
        Path { path in
            let a = from * Self.pieceSize, b = min(points.count - 1, to * Self.pieceSize)
            guard a < b else { return }
            path.move(to: points[a])
            for i in (a + 1)...b { path.addLine(to: points[i]) }
        }
    }

    /// Un angolo (in radianti, da `atan2`) in passi del giro, da 0 a `steps` − 1.
    static func step(_ angle: Double) -> Int {
        var t = angle / (2 * .pi)
        if t < 0 { t += 1 }
        return min(steps - 1, Int(t * Double(steps)))
    }

    /// I colori della copertina lungo il giro, uno che sfuma nell'altro (bianco senza colori).
    static func tint(_ palette: [SIMD3<Double>]) -> [SIMD3<Float>] {
        let colors = palette.isEmpty ? [SIMD3<Double>(1, 1, 1)] : palette
        let n = Double(colors.count)
        return (0..<steps).map { s in
            let at = (Double(s) + 0.5) / Double(steps) * n, i = Int(at) % colors.count, f = at - Double(Int(at))
            let c = colors[i] * (1 - f) + colors[(i + 1) % colors.count] * f
            return SIMD3<Float>(Float(min(1, max(0, c.x))), Float(min(1, max(0, c.y))), Float(min(1, max(0, c.z))))
        }
    }

    /// Le due luci lungo il giro, una di fronte all'altra: ognuna ha la testa netta e una coda lunga che sfuma, come
    /// una cometa che gira in senso orario. Da 0 a 1.
    static let lights: [Float] = (0..<steps).map { s in
        let turn = (Double(s) + 0.5) / Double(steps)
        var light = 0.0
        for head in [0.0, 0.5] {
            // quanto è indietro rispetto alla testa
            var behind = head - turn
            behind -= behind.rounded(.down)
            let tail = behind < 0.5 ? exp(-behind / 0.12) : 0
            let ahead = 1 - behind
            let nose = ahead < 0.5 ? exp(-(ahead / 0.022) * (ahead / 0.022)) : 0
            light = max(light, tail, nose)
        }
        return Float(light)
    }

    /// Un fotogramma: i colori girati di `hue` passi, le luci di `spin` passi. Il chiarore di fondo tutto attorno
    /// (0,3, o 0,7 senza movimento), le due luci sopra, il filo dove passano le luci (o tenue tutto attorno senza
    /// movimento). Come prima: il bordo si somma alla luce della scena.
    func paint(colors: [SIMD3<Float>], hue: Int, spin: Int, level: Float, still: Bool) -> Frame {
        let mask = Self.steps - 1
        let base: Float = still ? 0.7 : 0.3
        let count = width * height
        var bytes = [UInt8](repeating: 0, count: count * 4)
        guard colors.count == Self.steps else { return Frame(glow: nil, line: []) }
        Self.lights.withUnsafeBufferPointer { lights in
            colors.withUnsafeBufferPointer { colors in
                halo.withUnsafeBufferPointer { halo in
                    turn.withUnsafeBufferPointer { turn in
                        bytes.withUnsafeMutableBufferPointer { out in
                            for p in 0..<count {
                                let glow = halo[p]
                                guard glow > 0.001 else { continue }
                                let t = Int(turn[p])
                                let light = still ? 0 : lights[(t &- spin) & mask]
                                // quanto si vede, e il colore già moltiplicato per quello (come le maschere di prima)
                                let alpha = min(1, glow * (base + light) * level)
                                let c = colors[(t &- hue) & mask] * (alpha * 255)
                                out[p * 4] = UInt8(c.x); out[p * 4 + 1] = UInt8(c.y); out[p * 4 + 2] = UInt8(c.z); out[p * 4 + 3] = UInt8(alpha * 255)
                            }
                        }
                    }
                }
            }
        }
        let glow = CGDataProvider(data: Data(bytes) as CFData).flatMap {
            CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                    bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue), provider: $0, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
        }
        // il colore di ogni pezzo, poi i pezzi di fila quasi uguali uniti in un tratto (col loro colore medio)
        let tints = pieceTurns.map { t -> SIMD4<Float> in
            let c = colors[(t &- hue) & mask]
            let light = still ? 0.4 : Self.lights[(t &- spin) & mask]
            return SIMD4(c.x, c.y, c.z, min(1, light * 0.85 * level))
        }
        func lit(_ c: SIMD4<Float>) -> SIMD4<Float> { SIMD4(c.x * c.w, c.y * c.w, c.z * c.w, c.w) }
        var line: [(from: Int, to: Int, color: SIMD4<Float>)] = []
        var start = 0
        while start < tints.count {
            let first = lit(tints[start])
            var end = start + 1, sum = first
            while end < tints.count {
                let next = lit(tints[end])
                let gap = next - first
                guard max(abs(gap.x), abs(gap.y), abs(gap.z), abs(gap.w)) < Self.lineTolerance else { break }
                sum += next; end += 1
            }
            let mean = sum / Float(end - start)
            // si torna al colore pieno e a quanto si vede
            if mean.w > 0.004 { line.append((start, end, SIMD4(mean.x / mean.w, mean.y / mean.w, mean.z / mean.w, mean.w))) }
            start = end
        }
        return Frame(glow: glow, line: line)
    }
}

/// Le misure e i tempi di «Mappa», e i punti in cui `LockScreen` lo chiama.
@MainActor
enum Mappa {
    static var active: Bool { LockSettings.shared.theme == .mappa }
    /// I temi a tutto schermo (Costellazione e Montaggio): usano la scena della copertina, il punto della canzone che
    /// non torna indietro di poco, il lettore che compare col puntatore e l'apertura dalla foto del lettore.
    static var uses: Bool { LockSettings.shared.theme != .easy }
    /// Il bordo luminoso a copertina aperta, in tutti gli stili se acceso nelle impostazioni.
    static var edge: Bool { LockSettings.shared.edge }
    /// Serve la scena della copertina: ai temi a tutto schermo, e in Simple per i colori del bordo.
    static var needsScene: Bool { uses || edge }
    static var still: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    /// Le lettere strette di un filo, come nei manifesti svizzeri. Helvetica, sempre (carpa, 18 novembre 2026).
    nonisolated static let tracking = -0.022
    nonisolated static let face = "Helvetica-Bold"
    /// Di quanto la mappa anticipa il punto della canzone, in secondi: il tempo che una parola ci mette a comparire.
    nonisolated static let lead = 0.12
    /// Di quanto il punto detto dall'app può stare indietro senza che la mappa torni indietro, in secondi: oltre è un
    /// salto vero. Mentre suona poco (la mappa resta ferma finché la canzone non la raggiunge); a canzone ferma di più,
    /// perché lì l'unico salto vero è la barra trascinata, che va dritta al punto comunque.
    nonisolated static let backTolerance = 1.2
    nonisolated static let pausedTolerance = 6.0
    /// Dopo quanti secondi di pausa le piccole animazioni sono tutte posate.
    nonisolated static let holdCap = 8.0

    /// Quanto è larga una scritta a corpo base: serve alla disposizione della mappa.
    nonisolated static func measure(_ text: String) -> Double {
        let size = SongMap.baseSize
        let font = CTFontCreateWithName(face as CFString, size, nil)
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: font, .kern: tracking * size]))
        return CTLineGetTypographicBounds(line, nil, nil, nil) - tracking * size
    }

    /// Disegna una volta sola l'etichetta di ogni parola, al corpo che avrà alla fine, con la sua ombra e la sua
    /// sfumatura: comporre il testo a ogni fotogramma per cento parole costava più di un fotogramma intero.
    ///
    /// La sfumatura è una sola per tutto il cielo: i colori della copertina, dal più presente, vanno da sinistra a
    /// destra dello schermo (e un filo dall'alto in basso), e ogni parola e ogni stella prende il pezzo che le tocca
    /// dove sta. Così la costellazione intera cambia colore con ordine, non a coriandoli. Le parole che contano
    /// hanno più colore, le altre restano quasi bianche. Senza tavolozza (`palette` vuota) è tutto bianco.
    /// - Parameter place: dove sta la stella di una parola lungo la sfumatura del cielo (da 0 a 1), e quanto è larga
    ///   la sua scritta nella stessa misura.
    nonisolated static func labels(for map: SongMap, palette: [SIMD3<Double>] = [], place: (Int) -> (at: Double, wide: Double) = { _ in (0.5, 0.1) }) -> [MappaLabel] {
        let dots: CGFloat = 2, pad: CGFloat = MappaLabel.margin * 2
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        return map.nodes.enumerated().map { index, node in
            let size = CGFloat(map.size(of: node, count: node.hits.count))
            // i due colori della parola, e quelli (più carichi) della sua stella
            let rank = Double(map.rank(of: node, count: node.hits.count))
            // dentro una parola la sfumatura si deve vedere anche su una copertina di un colore solo: oltre a
            // cambiare tinta, parte più chiara e arriva più carica
            let spot = place(index), half = max(0.2, spot.wide * 0.8)
            let pale = 0.6 - 0.075 * rank
            let from = MappaColors.sky(palette, at: spot.at - half, white: pale + 0.14), to = MappaColors.sky(palette, at: spot.at + half, white: pale - 0.12)
            let ink = Gradient(colors: [MappaColors.color(from), MappaColors.color(to)])
            // la stella prende il colore del cielo dove sta, pieno per la luce e schiarito per il cuore
            let star = MappaStar.make(style: MappaStarStyle.current, grade: rank, plain: node.plain,
                                      light: MappaColors.sky(palette, at: spot.at, white: 0.16), pale: MappaColors.sky(palette, at: spot.at, white: 0.66))
            let middle = (from + to) / 2
            let font = CTFontCreateWithName(face as CFString, size * dots, nil)
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: node.text, attributes: [
                .font: font, .kern: CGFloat(tracking) * size * dots, .foregroundColor: CGColor(srgbRed: middle.x, green: middle.y, blue: middle.z, alpha: 1)]))
            var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
            let width = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, &leading))
            let w = Int((width + pad * 2).rounded(.up)), h = Int((ascent + descent + pad * 2).rounded(.up))
            guard w > 0, h > 0, let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                                     bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return MappaLabel(image: nil, size: .zero, body: size, star: star) }
            // l'ombra perché si legga su qualunque copertina
            ctx.setShadow(offset: CGSize(width: 0, height: -3), blur: 18, color: CGColor(gray: 0, alpha: 0.85))
            ctx.textPosition = CGPoint(x: pad, y: pad + descent)
            CTLineDraw(line, ctx)
            // le lettere una per una, al corpo vero: stessa linea di base e stessi margini dell'immagine
            let small = CTFontCreateWithName(face as CFString, size, nil)
            let thin = CTLineCreateWithAttributedString(NSAttributedString(string: node.text, attributes: [.font: small, .kern: CGFloat(tracking) * size]))
            let margin = pad / dots, rise = ascent / dots
            var glyphs: [MappaGlyph] = []
            for run in (CTLineGetGlyphRuns(thin) as? [CTRun]) ?? [] {
                let count = CTRunGetGlyphCount(run)
                var ids = [CGGlyph](repeating: 0, count: count), spots = [CGPoint](repeating: .zero, count: count), steps = [CGSize](repeating: .zero, count: count)
                CTRunGetGlyphs(run, CFRange(location: 0, length: count), &ids)
                CTRunGetPositions(run, CFRange(location: 0, length: count), &spots)
                CTRunGetAdvances(run, CFRange(location: 0, length: count), &steps)
                guard let runFont = (CTRunGetAttributes(run) as NSDictionary)[kCTFontAttributeName] else { continue }
                for i in 0..<count {
                    var move = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: margin + spots[i].x, ty: margin + rise - spots[i].y)
                    guard let outline = CTFontCreatePathForGlyph(runFont as! CTFont, ids[i], &move) else { continue }
                    glyphs.append(MappaGlyph(outline: Path(outline), mid: margin + spots[i].x + steps[i].width / 2, base: margin + rise))
                }
            }
            let box = CGSize(width: CGFloat(w) / dots, height: CGFloat(h) / dots)
            // la sfumatura, dentro le lettere: da un angolo all'altro della scritta, nelle misure dell'etichetta
            if !palette.isEmpty, !glyphs.isEmpty,
               let gradient = CGGradient(colorsSpace: space, colors: [CGColor(srgbRed: from.x, green: from.y, blue: from.z, alpha: 1),
                                                                      CGColor(srgbRed: to.x, green: to.y, blue: to.z, alpha: 1)] as CFArray, locations: [0, 1]) {
                ctx.saveGState()
                ctx.setShadow(offset: .zero, blur: 0, color: nil)
                ctx.translateBy(x: 0, y: CGFloat(h))
                ctx.scaleBy(x: dots, y: -dots)
                let letters = CGMutablePath()
                for glyph in glyphs { letters.addPath(glyph.outline.cgPath) }
                ctx.addPath(letters)
                ctx.clip()
                let ends = MappaLabel.sweep(box)
                ctx.drawLinearGradient(gradient, start: ends.from, end: ends.to, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
                ctx.restoreGState()
            }
            return MappaLabel(image: ctx.makeImage(), size: box, body: size, glyphs: glyphs, ink: ink, star: star)
        }
    }

    // MARK: La scena e la mappa del brano

    /// Prepara la scena del brano che suona, se non c'è già.
    static func ensure(_ model: LockModel) {
        guard needsScene, let music = model.music else { return }
        let state = model.mappa
        let key = music.trackKey
        guard let art = music.artwork else { retire(model, key: key); return }
        state.bare?.cancel(); state.bare = nil; state.bareFor = ""
        sharpen(model, music)
        // Pronta, o in preparazione, per questo brano e per questa copertina. Conta anche la copertina: il titolo del
        // brano nuovo arriva spesso prima della sua foto, e la scena nata in quel momento ha la foto del brano di prima.
        // Guardando solo il brano quella scena restava per tutta la canzone (copertina, colori e bordo sbagliati).
        if let scene = state.scene, scene.key == key, scene.source === art { return }
        if state.preparing == key, state.preparingArt === art { return }
        if let ready = state.kept.first(where: { $0.key == key && $0.source === art }) { show(ready, in: model); return }
        state.preparing = key
        state.preparingArt = art
        let box = IconBox(art)
        Task.detached(priority: .userInitiated) {
            let scene = MappaScene.make(box.image, key: key)
            await MainActor.run {
                let state = model.mappa
                if state.preparing == key, state.preparingArt === box.image { state.preparing = ""; state.preparingArt = nil }
                // nel frattempo il brano o la sua copertina sono cambiati: questa scena non serve più
                guard let scene, model.music?.trackKey == key, model.music?.artwork === box.image else { return }
                state.kept = Array((state.kept.filter { $0.key != key } + [scene]).suffix(3))
                show(scene, in: model)
            }
        }
    }

    /// Il brano che suona non ha copertina: la scena del brano di prima se ne va (restava per tutta la canzone, e in
    /// Dynamic il testo non usciva mai perché il piano aspettava una scena che non sarebbe arrivata). Non subito: fra
    /// un brano e l'altro la copertina manca spesso per un attimo, e togliendola al volo si passerebbe dal nero.
    private static func retire(_ model: LockModel, key: String) {
        let state = model.mappa
        guard let scene = state.scene, scene.key != key, state.bareFor != key else { return }
        state.bareFor = key
        state.bare?.cancel()
        state.bare = Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            let state = model.mappa
            guard !Task.isCancelled, let music = model.music, music.trackKey == key, music.artwork == nil,
                  let scene = state.scene, scene.key != key else { return }
            state.old = scene
            state.scene = nil
            state.sceneT = 0
        }
    }

    /// Chiede la copertina grande del brano al catalogo di Apple, una volta per brano, solo per le app di musica e solo
    /// negli stili a tutto schermo (in Simple la copertina non si ingrandisce). Quando arriva prende il posto di quella
    /// piccola con la stessa dissolvenza del cambio brano.
    private static func sharpen(_ model: LockModel, _ music: NowPlayingSnapshot) {
        let state = model.mappa, key = music.trackKey
        // nelle prove con la musica finta (`CHARLAND_BLOCCO_FINTO`) niente rete: il brano non esiste
        guard uses, LyricsService.isMusicApp(music.app), music.duration > 30, !music.artist.isEmpty,
              ProcessInfo.processInfo.environment["CHARLAND_BLOCCO_FINTO"] == nil else { return }
        // Una volta per brano e per copertina. Stesso brano con un'altra copertina: la richiesta di prima aveva per
        // confronto la copertina del brano precedente, si rifà (e il suo «non c'è» non vale).
        if state.sharpFor == key, state.sharpArt === music.artwork { return }
        let again = state.sharpFor == key
        state.sharpFor = key
        state.sharpArt = music.artwork
        state.sharpToken &+= 1
        let token = state.sharpToken
        let (title, artist, album, duration) = (music.title, music.artist, music.album, music.duration)
        // la copertina dell'app, per scartare quella di un'altra uscita dello stesso brano (una raccolta, un singolo)
        let reference = music.artwork?.cgImage(forProposedRect: nil, context: nil, hints: nil).map(ImageBox.init)
        Task.detached(priority: .utility) {
            // Il titolo del brano nuovo arriva spesso un attimo prima della sua copertina: si aspetta, e si parte solo
            // se questa è ancora la richiesta più recente. Con la copertina del brano di prima come confronto il
            // catalogo non trovava niente di somigliante, e quel «non c'è» restava scritto per una settimana.
            try? await Task.sleep(for: .milliseconds(1200))
            guard await MainActor.run(body: { model.mappa.sharpToken == token }) else { return }
            guard let image = await BigArtwork.image(title: title, artist: artist, album: album, duration: duration, like: reference?.image,
                                                     retry: again) else { return }
            let box = ImageBox(image)
            await MainActor.run {
                let state = model.mappa
                guard model.music?.trackKey == key, state.sharpToken == token else { return }
                state.sharp = (key, box.image)
                // la stessa foto, più nitida, con lo stesso fuoco e le stesse proporzioni: si scambia sul posto, senza
                // dissolvenza (passando dal nero la foto si scuriva, e in Dynamic si vedevano due inquadrature)
                if let scene = state.scene, scene.key == key, !scene.sharp, scene.source === state.sharpArt,
                   let better = scene.sharpened(with: box.image) {
                    state.scene = better
                    state.kept = state.kept.map { $0.key == key ? better : $0 }
                }
            }
        }
    }

    /// Allo sblocco: via le scene tenute da parte e la copertina grande (fino a 23 MB l'una); quella del brano che suona
    /// si rifà dal disco al prossimo blocco.
    static func release(_ model: LockModel) {
        let state = model.mappa
        state.kept = []
        state.old = nil
        state.sharp = nil
        state.sharpFor = ""
        state.sharpArt = nil
        state.sharpToken &+= 1
        state.bare?.cancel(); state.bare = nil; state.bareFor = ""
        if state.scene?.sharp == true { state.scene = nil }
    }

    private static func show(_ scene: MappaScene, in model: LockModel) {
        let state = model.mappa
        guard state.scene?.key != scene.key || state.scene?.source !== scene.source else { return }
        // la copertina grande, se è già arrivata
        let scene = state.sharp.flatMap { $0.key == scene.key && !scene.sharp ? scene.sharpened(with: $0.image) : nil } ?? scene
        state.old = state.scene
        state.scene = scene
        state.sceneT = state.old == nil ? 1 : 0
        // il bordo e i suoi colori si disegnano adesso, non al primo fotogramma dell'apertura
        _ = state.edge(size: model.size, notch: model.notch)
        _ = state.tint(scene)
        _ = state.spot
    }

    /// Il rettangolo in cui stanno le parole: sotto l'orologio, sopra il fondo, coi margini ai lati.
    nonisolated static func region(_ size: CGSize) -> CGRect {
        CGRect(x: size.width * 0.08, y: size.height * 0.35, width: size.width * 0.84, height: size.height * 0.55)
    }

    /// Divide il testo in strofe e dispone la costellazione di ognuna nel suo rettangolo.
    /// - Parameters:
    ///   - title: il titolo del brano: le sue parole contano (nascono più grandi).
    ///   - palette: i colori della copertina, per la sfumatura di parole e stelle; vuota, tutto bianco.
    nonisolated static func stanzas(of lyrics: Lyrics, size: CGSize, title: String = "", palette: [SIMD3<Double>] = []) -> [MappaStanza] {
        let k = min(size.width / 1710, size.height / 1107), room = region(size)
        let levels = SongMap.levels(lines: lyrics.lines, title: title, wordTimingIsReal: lyrics.wordTimingIsReal)
        var out: [MappaStanza] = []
        for range in lyrics.stanzas() {
            let map = SongMap(lines: Array(lyrics.lines[range]), width: Double(room.width / k), height: Double(room.height / k), levels: levels, measure: measure)
            guard !map.isEmpty else { continue }
            let stars = map.nodes.map { CGPoint(x: room.minX + CGFloat($0.x) * k, y: room.minY + CGFloat($0.y) * k) }
            let unit = k * CGFloat(map.fit)
            let drawn = labels(for: map, palette: palette) { i in
                let across = Double((stars[i].x - room.minX) / room.width), down = Double((stars[i].y - room.minY) / room.height)
                let wide = map.nodes[i].width * map.size(of: map.nodes[i], count: map.nodes[i].hits.count) / SongMap.baseSize * Double(unit / room.width)
                return (0.06 + 0.72 * across + 0.16 * down, wide)
            }
            out.append(MappaStanza(map: map, labels: drawn, stars: stars, unit: unit, leave: 0, gaps: drawn.map { $0.star.reach * unit }))
        }
        for i in out.indices {
            let next = i + 1 < out.count ? out[i + 1].map.start : Double.infinity
            // la costellazione finita resta in cielo finché la strofa dopo non sta per cominciare (sei secondi al
            // massimo, se poi c'è solo musica); l'ultima parola si deve comunque vedere un attimo
            let last = out[i].map.steps.last?.time ?? out[i].map.end
            out[i].leave = max(last + 0.5, min(next - 1.0, out[i].map.end + 6))
            out[i].quick = min(1, max(0.35, (next - out[i].leave) / 0.95))
        }
        return out
    }

    /// Prepara le strofe del testo che suona, se non ci sono già. Fuori dal thread principale: impaginare e disegnare
    /// le etichette di un brano intero prende qualche decimo di secondo.
    static func chart(_ model: LockModel) {
        guard active else { return }
        let state = model.mappa
        guard let lyrics = model.lyrics, !model.rows.isEmpty else {
            if !state.stanzas.isEmpty { state.set([], stamp: "") }
            return
        }
        // la tavolozza della copertina sta arrivando: le etichette si disegnano una volta sola, coi suoi colori
        // (anche quando una scena del brano c'è già ma se ne sta preparando un'altra, dalla copertina giusta)
        if let key = model.music?.trackKey, state.preparing == key { return }
        let size = model.size, title = model.music?.title ?? "", track = model.music?.trackKey ?? ""
        let (stamp, palette) = stamp(model)
        guard state.mapStamp != stamp, state.charting != stamp else { return }
        state.charting = stamp
        Task.detached(priority: .userInitiated) {
            let stanzas = Mappa.stanzas(of: lyrics, size: size, title: title, palette: palette)
            await MainActor.run {
                let state = model.mappa
                if state.charting == stamp { state.charting = "" }
                if Mappa.stamp(model).stamp == stamp { state.set(stanzas, stamp: stamp, for: track) }
            }
        }
    }

    /// Di che cosa sono fatte le strofe pronte: il testo, lo schermo, e la copertina da cui vengono i colori (se è
    /// quella del brano che suona: se no le parole restano bianche finché non arriva la sua).
    private static func stamp(_ model: LockModel) -> (stamp: String, palette: [SIMD3<Double>]) {
        let scene = model.mappa.scene
        let mine = scene != nil && scene?.key == model.music?.trackKey
        // nella firma anche la copertina di partenza: stesso brano con un'altra copertina vuol dire altri colori
        return ("\(model.rowsStamp)|\(model.size.width)x\(model.size.height)|\(mine ? scene!.token + "|" + scene!.key : "-")", mine ? scene!.palette : [])
    }

    /// Per gli scatti e le prove con dati di fantasia: scena e strofe subito, senza aspettare.
    static func fill(_ model: LockModel) {
        guard needsScene else { return }
        let state = model.mappa
        if let music = model.music, let art = music.artwork, state.scene?.key != music.trackKey, let scene = MappaScene.make(art, key: music.trackKey) {
            state.old = nil; state.scene = scene; state.sceneT = 1
        }
        guard active else { return }
        if let lyrics = model.lyrics, !model.rows.isEmpty {
            let (stamp, palette) = stamp(model)
            if state.mapStamp != stamp { state.set(stanzas(of: lyrics, size: model.size, title: model.music?.title ?? "", palette: palette), stamp: stamp, for: model.music?.trackKey ?? "") }
        } else { state.set([], stamp: "") }
    }

    /// Per gli scatti: la mappa a un punto della canzone, senza pause.
    static func place(_ model: LockModel, at seconds: Double) {
        let state = model.mappa
        state.time = seconds + lead
        state.holds = []
        state.holding = false
        state.timeFor = model.music?.trackKey ?? ""
    }

    // MARK: Un passo

    /// Un passo, a ogni fotogramma a copertina aperta: il punto della canzone, il lettore che compare finché il
    /// puntatore si muove, la luce del bordo che gira.
    /// - Parameter frame: dove sta la scena sullo schermo (in punti dello schermo, origine in basso), per il puntatore.
    static func step(_ model: LockModel, _ dt: Double, frame: CGRect?) {
        guard uses else {
            // in Simple c'è solo il bordo: la scena che arriva (i suoi colori) e la luce che gira col passo del brano
            guard edge else { return }
            let state = model.mappa
            if state.sceneT < 1 { state.sceneT = min(1, state.sceneT + dt / 0.9); if state.sceneT == 1 { state.old = nil } }
            turn(model, dt, dense: 0)
            return
        }
        let state = model.mappa
        // il cambio brano: la costellazione di prima resta ferma e si scioglie (prima del passo, che porta il punto
        // della canzone sul brano nuovo)
        let key = model.music?.trackKey ?? ""
        if key != state.followed {
            if active, !state.followed.isEmpty, !key.isEmpty, model.openT > 0, !state.stanzas.isEmpty {
                let frozen = state.time
                // ogni strofa che c era comincia a sciogliersi adesso, col suo passo: quanto la dissolvenza della copertina
                let stanzas = state.stanzas.map { stanza -> MappaStanza in
                    var s = stanza
                    if s.leave > frozen { s.leave = frozen; s.quick = 1 }
                    return s
                }
                state.leaving = MappaState.Leaving(stanzas: stanzas, trail: state.trail, time: frozen, palette: state.scene?.palette ?? [], at: state.now)
            } else {
                state.leaving = nil
            }
            state.followed = key
        }
        if let leaving = state.leaving, state.now - leaving.at > 1.2 || model.openT == 0 { state.leaving = nil }
        follow(model, dt)
        let time = state.time
        state.now += dt
        pace(dt, open: model.openT == 1)
        trace(model, time)
        traceCard(model)
        if state.sceneT < 1 { state.sceneT = min(1, state.sceneT + dt / 0.9); if state.sceneT == 1 { state.old = nil } }
        chart(model)

        let p = NSEvent.mouseLocation
        if abs(p.x - state.pointer.x) + abs(p.y - state.pointer.y) > 1.5 { state.pointer = p; if dt > 0 { state.movedAt = state.now } }
        if model.open, dt > 0 {
            let want = state.now - state.movedAt < 2.6
            if want != model.hover { model.hover = want }
        }

        var dense = 0.0
        if model.wantsColumn {
            dense = min(1, Double(state.trail.reduce(0) { $0 + ($1.time <= time && $1.time > time - 4 ? 1 : 0) }) / 12)
            // nel Montaggio le parole sono quelle dei suoi versi
            if Montaggio.active { dense = Montaggio.density(model, at: time) }
        }
        turn(model, dt, dense: dense)
    }

    /// La luce del bordo gira attorno allo schermo, più svelta dove il brano è più svelto e più fitto di parole (`dense`,
    /// da 0 a 1), più lenta dove respira. La velocità cambia piano: niente colpi a ogni battito (lampeggiava e vibrava tutto).
    private static func turn(_ model: LockModel, _ dt: Double, dense: Double) {
        let state = model.mappa
        var energy = 0.1
        if let music = model.music, model.playing {
            let quick = (tempo(title: music.title, artist: music.artist) - 96) / 32
            energy = 0.5 + 0.35 * quick + 0.95 * dense
        }
        state.energy += (energy - state.energy) * (1 - exp(-dt / 2.4))
        if !still, dt > 0 { state.spin = (state.spin + dt * 0.05 * state.energy).truncatingRemainder(dividingBy: 1) }
    }

    /// Porta avanti il punto della canzone che la mappa disegna (`MappaState.time`) e le pause (`MappaState.holds`).
    private static func follow(_ model: LockModel, _ dt: Double) {
        let state = model.mappa
        let said = model.position(at: Date()) + lead
        let key = model.music?.trackKey ?? ""
        // Un brano nuovo o un salto vero: le pause di prima non contano più. Sul blocco il salto lo fa solo la barra
        // trascinata (`seeking`), e lì si va sempre dritti al punto. A canzone ferma il punto non va avanti da solo:
        // se l'app lo dice indietro anche di qualche secondo è la pausa detta male, non un salto
        let tolerance = model.playing ? backTolerance : pausedTolerance
        // (mentre la barra si trascina; lasciata, la canzone riparte dal punto scelto e va solo avanti)
        let dragging = model.seeking != nil && model.seekReleased == nil
        // un rilascio nuovo, anche di un clic secco che non si è mai visto trascinare: dritti al punto scelto
        let released = model.seekCount != state.seenSeek
        state.seenSeek = model.seekCount
        let jump = key != state.timeFor || released || (dragging && abs(said - state.time) > 0.01) || abs(said - state.time) > tolerance
        if jump { state.timeFor = key; state.holds = []; state.holding = false }
        // al salto e quando la copertina si apre (dt zero) dritti al punto; se no solo in avanti
        if jump || dt == 0 || said > state.time, state.time != said { state.time = said }
        guard dt > 0 else { return }
        if model.playing {
            state.holding = false
        } else {
            if !state.holding {
                state.holding = true
                state.holds = Array((state.holds + [(at: state.time, length: 0)]).suffix(16))
            }
            if let last = state.holds.last, last.length < holdCap { state.holds[state.holds.count - 1].length = min(holdCap, last.length + dt) }
        }
    }

    /// Per le prove: come se il puntatore si fosse mosso adesso (il lettore compare).
    static func poke(_ model: LockModel) { model.mappa.movedAt = model.mappa.now }

    /// Il tempo del brano, in battiti al minuto. Charland non ascolta l'audio del Mac (servirebbe il permesso di
    /// registrare l'audio di sistema): è lo stesso tempo plausibile, scelto per ogni brano, su cui batte
    /// l'equalizzatore dell'isola, così le due cose vanno insieme.
    static func tempo(title: String, artist: String) -> Double {
        var hash = 5381
        for unit in (title + "|" + artist).utf8 { hash = (hash &* 33) &+ Int(unit) }
        return EqualizerPattern(seed: hash).tempo
    }

    /// Per le prove (`CHARLAND_BLOCCO_REGISTRO=<file>`): il passo dei fotogrammi a copertina aperta e ferma, ogni
    /// centoventi fotogrammi. Sul blocco vero è questo che dice se la mappa va liscia.
    private static var paced = (frames: 0, total: 0.0, worst: 0.0)
    private static let paceFile = ProcessInfo.processInfo.environment["CHARLAND_BLOCCO_REGISTRO"]
    private static func pace(_ dt: Double, open: Bool) {
        guard let paceFile, open, dt > 0 else { return }
        paced.frames += 1; paced.total += dt; paced.worst = max(paced.worst, dt)
        guard paced.frames >= 120 else { return }
        let line = String(format: "%.2f  mappa ferma: 120 fotogrammi, medio %.1f ms, peggiore %.1f ms\n", Date().timeIntervalSince1970.truncatingRemainder(dividingBy: 100000),
                          paced.total / 120 * 1000, paced.worst * 1000)
        paced = (0, 0, 0)
        if let handle = FileHandle(forWritingAtPath: paceFile) { handle.seekToEndOfFile(); handle.write(Data(line.utf8)); try? handle.close() }
        else { try? Data(line.utf8).write(to: URL(fileURLWithPath: paceFile)) }
    }

    /// Per le prove (`CHARLAND_BLOCCO_POSIZIONI=<file>`): a ogni fotogramma, dove sta sullo schermo la prima parola
    /// della strofa in corso e dove cade la luce. La parola non deve muoversi affatto; la luce poco e piano.
    private static let traceFile = ProcessInfo.processInfo.environment["CHARLAND_BLOCCO_POSIZIONI"].flatMap { path -> FileHandle? in
        FileManager.default.createFile(atPath: path, contents: nil)
        return FileHandle(forWritingAtPath: path)
    }
    private static func trace(_ model: LockModel, _ time: Double) {
        guard let traceFile, model.openT == 1, !model.mappa.stanzas.isEmpty else { return }
        let state = model.mappa
        let moment = MappaMoment(stanzas: state.stanzas, trail: state.trail, time: time)
        guard moment.index >= 0, let first = state.stanzas[moment.index].stars.first else { return }
        let glow = moment.glow ?? .zero
        // quante stelle si vedono nella strofa in corso: se cambia senza che la canzone vada avanti, la figura ha cambiato forma
        let lit = state.stanzas[moment.index].map.nodes.reduce(0) { $0 + ($1.sung(at: time) != nil ? 1 : 0) }
        // lo stesso col punto detto dall'app così com'è: dove sarebbe la mappa se seguisse quello
        let said = model.position(at: Date()) + lead
        let saidMoment = MappaMoment(stanzas: state.stanzas, trail: state.trail, time: said)
        let saidLit = saidMoment.index >= 0 ? state.stanzas[saidMoment.index].map.nodes.reduce(0) { $0 + ($1.sung(at: said) != nil ? 1 : 0) } : 0
        traceFile.write(Data(String(format: "%.3f %.2f %.2f %.2f %.2f %.4f %d %d %d %d %.3f %d %d\n", time, first.x, first.y, glow.x, glow.y, state.spin,
                                    moment.index, moment.step, lit, model.playing ? 1 : 0, said, saidMoment.index, saidLit).utf8))
    }

    /// Per le prove (`CHARLAND_BLOCCO_LETTORE=<file>`): a ogni fotogramma a copertina aperta, il tempo, quanto è fuori
    /// il lettore, dove sta la copertina grande senza testo (x, y, lato) e quanto si vede il lettore. Serve a vedere il
    /// passaggio copertina grande → lettore: niente salti di posto né di misura da un fotogramma all'altro.
    private static let cardFile = ProcessInfo.processInfo.environment["CHARLAND_BLOCCO_LETTORE"].flatMap { path -> FileHandle? in
        FileManager.default.createFile(atPath: path, contents: nil)
        return FileHandle(forWritingAtPath: path)
    }
    private static func traceCard(_ model: LockModel) {
        guard let cardFile, model.openT == 1 else { return }
        let (r, bare) = MappaCenterCover.place(model)
        let late = MappaView.late(model.openT, opening: model.open)
        cardFile.write(Data(String(format: "%.4f %.4f %.2f %.2f %.2f %.3f %.3f\n", CACurrentMediaTime(), model.hoverS, r.midX, r.midY, r.width, bare,
                                    min(1, model.hoverS) * late).utf8))
    }

    // MARK: Il bordo

    /// Il contorno dello schermo, appena dentro il bordo. Parte dal centro del notch (da sotto), gira in senso orario
    /// e ci torna: è la strada che il tempo del brano percorre. Senza notch parte dal centro del bordo alto.
    nonisolated static func outline(size: CGSize, notch: CGRect) -> Path {
        let inset: CGFloat = 2, top: CGFloat = 13, low: CGFloat = 7
        let box = CGRect(origin: .zero, size: size).insetBy(dx: inset, dy: inset)
        let hasNotch = notch.maxY > 6 && notch.minY >= 0
        let l = notch.minX - inset, r = notch.maxX + inset, b = notch.maxY + inset
        let lip: CGFloat = 5, belly: CGFloat = 10
        var path = Path()
        if hasNotch {
            path.move(to: CGPoint(x: box.midX, y: b))
            path.addArc(tangent1End: CGPoint(x: r, y: b), tangent2End: CGPoint(x: r, y: b - belly), radius: belly)
            path.addArc(tangent1End: CGPoint(x: r, y: box.minY), tangent2End: CGPoint(x: r + lip, y: box.minY), radius: lip)
        } else {
            path.move(to: CGPoint(x: box.midX, y: box.minY))
        }
        path.addArc(tangent1End: CGPoint(x: box.maxX, y: box.minY), tangent2End: CGPoint(x: box.maxX, y: box.minY + top), radius: top)
        path.addArc(tangent1End: CGPoint(x: box.maxX, y: box.maxY), tangent2End: CGPoint(x: box.maxX - low, y: box.maxY), radius: low)
        path.addArc(tangent1End: CGPoint(x: box.minX, y: box.maxY), tangent2End: CGPoint(x: box.minX, y: box.maxY - low), radius: low)
        path.addArc(tangent1End: CGPoint(x: box.minX, y: box.minY), tangent2End: CGPoint(x: box.minX + top, y: box.minY), radius: top)
        if hasNotch {
            path.addArc(tangent1End: CGPoint(x: l, y: box.minY), tangent2End: CGPoint(x: l, y: box.minY + lip), radius: lip)
            path.addArc(tangent1End: CGPoint(x: l, y: b), tangent2End: CGPoint(x: l + belly, y: b), radius: belly)
            path.addLine(to: CGPoint(x: box.midX, y: b))
        } else {
            path.addLine(to: CGPoint(x: box.midX, y: box.minY))
        }
        return path
    }

    /// La macchia di luce della voce: un disco pieno al centro che sfuma a zero al bordo. Fa da maschera alla
    /// copertina chiara, e si sposta con la voce.
    nonisolated static func spot() -> NSImage? {
        let side = 160
        guard let ctx = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!, colors: [CGColor(gray: 1, alpha: 0.42), CGColor(gray: 1, alpha: 0.2), CGColor(gray: 1, alpha: 0.06), CGColor(gray: 1, alpha: 0)] as CFArray,
                                        locations: [0, 0.4, 0.75, 1]) else { return nil }
        let mid = CGPoint(x: side / 2, y: side / 2)
        ctx.drawRadialGradient(gradient, startCenter: mid, startRadius: 0, endCenter: mid, endRadius: CGFloat(side) / 2, options: [])
        guard let image = ctx.makeImage() else { return nil }
        return NSImage(cgImage: image, size: NSSize(width: side, height: side))
    }

    /// L'alone del bordo: il contorno sfumato tre volte (stretto vicino al filo, medio, largo che entra nello schermo),
    /// bianco, in piccolo. Lo si colora poi coi colori della copertina. Disegnato una volta: sfocare un contorno a
    /// tutto schermo a ogni fotogramma costerebbe.
    nonisolated static func halo(_ outline: Path, size: CGSize) -> NSImage? {
        let scale: CGFloat = 0.5
        let w = Int(size.width * scale), h = Int(size.height * scale)
        guard w > 0, h > 0, let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                                 bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        // la vista ha la y in giù, il disegno in su
        ctx.translateBy(x: 0, y: CGFloat(h)); ctx.scaleBy(x: scale, y: -scale)
        ctx.setStrokeColor(CGColor(gray: 1, alpha: 1))
        ctx.setLineWidth(7)
        ctx.addPath(outline.cgPath)
        ctx.strokePath()
        guard let line = ctx.makeImage() else { return nil }
        let box = CGRect(x: 0, y: 0, width: w, height: h)
        let base = CIImage(cgImage: line)
        func glow(_ sigma: Double, _ gain: CGFloat) -> CIImage {
            base.applyingGaussianBlur(sigma: sigma * scale).cropped(to: box)
                .applyingFilter("CIColorMatrix", parameters: ["inputRVector": CIVector(x: gain, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 0, y: gain, z: 0, w: 0),
                                                              "inputBVector": CIVector(x: 0, y: 0, z: gain, w: 0), "inputAVector": CIVector(x: 0, y: 0, z: 0, w: gain)])
        }
        let sum = glow(9, 2.2).applyingFilter("CIAdditionCompositing", parameters: [kCIInputBackgroundImageKey: glow(32, 5.4)])
            .applyingFilter("CIAdditionCompositing", parameters: [kCIInputBackgroundImageKey: glow(96, 8)])
        guard let image = CIContext().createCGImage(sum, from: box) else { return nil }
        return NSImage(cgImage: image, size: size)
    }
}

/// Un istante di «Mappa»: quale strofa si sta cantando, dove sta la voce lungo il nastro, dove cade la luce.
///
/// Si calcola tutto dal punto della canzone, senza ricordare niente: saltando avanti o indietro nel brano è subito
/// quello giusto. Le parole non si muovono mai: qui si muovono solo la voce e la luce.
struct MappaMoment {
    /// La strofa in corso (−1 prima della prima).
    var index: Int
    /// L'ultima parola cantata nella strofa (−1 se non è ancora cominciata).
    var step: Int
    /// Dove sta la voce: sulla stella della parola cantata, o in viaggio verso la prossima.
    var voice: CGPoint?
    /// La linea che la voce sta percorrendo verso la prossima stella, da quale stella, e a che punto è.
    var going: (road: Int, from: Int, progress: CGFloat)?
    /// Dove cade la luce sulla copertina: la zona dove si sta cantando, non la singola parola.
    var glow: CGPoint?

    init(stanzas: [MappaStanza], trail: [(time: Double, point: CGPoint)], time: Double) {
        index = -1; step = -1
        for (i, stanza) in stanzas.enumerated() { if stanza.map.start - 0.35 <= time { index = i } else { break } }
        if index >= 0 {
            let stanza = stanzas[index], map = stanza.map
            step = map.step(at: time)
            if step >= 0 {
                voice = stanza.stars[map.steps[step].node]
                if step + 1 < map.steps.count, let road = map.steps[step + 1].road {
                    // la voce resta sulla parola finché viene cantata e riparte nell'ultima metà del suo tempo, mai prima
                    let next = map.steps[step + 1], trip = min(0.6, (next.time - map.steps[step].time) * 0.55)
                    let f = MappaMath.ease((time - (next.time - trip)) / max(0.05, trip))
                    if f > 0 {
                        let from = map.steps[step].node, r = map.roads[road]
                        going = (road, from, CGFloat(f))
                        let a = stanza.stars[from], b = stanza.stars[from == r.a ? r.b : r.a]
                        voice = CGPoint(x: a.x + (b.x - a.x) * CGFloat(f), y: a.y + (b.y - a.y) * CGFloat(f))
                    }
                }
            }
        }
        // dove si sta cantando: la media dei posti delle parole, pesate a campana sul tempo. Si contano tutte le
        // parole del brano e i pesi cambiano piano: nessuna entra o esce dal conto di colpo (la prima versione
        // guardava solo una finestra di tempo, e a ogni parola che ci entrava la luce saltava)
        var x = 0.0, y = 0.0, total = 0.0
        for entry in trail {
            let d = (entry.time - time) / 1.7
            guard abs(d) < 60 else { continue }
            let w = exp(-d * d / 2) + 0.002 * exp(-d * d / 72)
            x += Double(entry.point.x) * w; y += Double(entry.point.y) * w; total += w
        }
        if total > 1e-9 { glow = CGPoint(x: x / total, y: y / total) }
    }
}

enum MappaMath {
    static func ease(_ t: Double) -> Double { let x = min(1, max(0, t)); return x * x * (3 - 2 * x) }

    /// Una molla vera, da 0 a 1 in `t` secondi dalla partenza: va oltre e torna (meno `damping`, più rimbalza).
    static func spring(_ t: Double, speed: Double, damping: Double) -> Double {
        guard t > 0 else { return 0 }
        let wobble = speed * (1 - damping * damping).squareRoot()
        return 1 - exp(-damping * speed * t) * (cos(wobble * t) + damping * speed / wobble * sin(wobble * t))
    }
}
