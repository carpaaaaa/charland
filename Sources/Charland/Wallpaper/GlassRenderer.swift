import AppKit
import simd

/// I due vetri dello sfondo (carpa, 20 novembre 2026, con due foto di riferimento: un ritratto a retino di punti di
/// vetro e un vetro cannettato blu notte; «completamente customizzabile»).

/// Lenti: un vetro tutto a piccole lenti (carpa, 20 novembre 2026, con un riferimento «Glass Morphism»: un pannello di
/// vetro stampato a cupolette che sfoca la foto in una griglia di puntini). Parte limpido come il Liquid Glass di Apple
/// («sempre partendo dal liquid glass, poi potendolo rendere più frosted»): ogni lente è nitida in mezzo e piega
/// l'immagine verso l'orlo, con la dispersione e il filo di luce del Cannettato. Smerigliato la rende lattiginosa,
/// Rilievo scurisce gli orli e accende il centro delle lenti, come i puntini del vetro stampato.
struct LensOptions: Sendable, Hashable, Codable {
    // I valori di serie sono le regolazioni di carpa del 20 novembre 2026 (carpa: «le impostazioni che ho io per
    // fluted, lenses e foggy siano quelle default»). «Valori di serie» nelle Impostazioni torna qui.
    enum Grid: String, CaseIterable, Sendable, Codable { case diagonal, square, hex }
    enum Tint: String, CaseIterable, Sendable, Codable { case photo, gray }
    /// Cupole: lenti tonde. Piramidi: punte di diamante a facce piane (come il vetro «Refraction» del riferimento).
    enum Shape: String, CaseIterable, Sendable, Codable { case dome, pyramid }
    var cell: Double = 16.419443973120078
    var shape: Shape = .dome
    /// Quanto vetro togliere a sinistra e a destra (frazioni dello schermo): lì resta l'immagine intatta (carpa:
    /// «quando selezioni coverage puoi togliere sia da destra che da sinistra»).
    var cutLeft: Double = 0
    var cutRight: Double = 0
    var grid: Grid = .diagonal
    var refraction: Double = 0
    var frost: Double = 0
    var relief: Double = 0
    var light: Double = 0
    var dispersion: Double = 0.9433071805524361
    var grain: Double = 1
    var brightness: Double = 0
    var tint: Tint = .photo
    var glow = false
    /// Ogni lente mostra una piccola copia capovolta dell'immagine intorno, come un vetro a lenti vero: il soggetto si
    /// ripete in ogni lente (carpa: «questo effetto manca un po' anche a lenses»). 0: le cupolette limpide.
    var miniatures: Double = 1
    /// La riga fra un blocchetto e l'altro (carpa, 20 novembre 2026: «vedo il bordo dei blocchetti quando è su sfondo
    /// bianco, permetti di regolarlo e a zero si tolga»). 0,5 è la riga di prima; a zero le lenti si toccano senza riga
    /// (il lucido e l'ombra della cupola restano, con Luce sugli orli e Rilievo).
    var seams: Double = 0

    init() {}
    /// Tutti i numeri sono numeri (un NaN salvato farebbe cadere l'app a ogni avvio).
    var isFinite: Bool {
        [cell, cutLeft, cutRight, refraction, frost, relief, light, dispersion, grain, brightness, miniatures, seams].allSatisfy(\.isFinite)
    }
    /// Le scelte salvate da una versione con meno campi restano: i campi che mancano prendono il valore di serie.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = LensOptions()
        miniatures = try c.decodeIfPresent(Double.self, forKey: .miniatures) ?? d.miniatures
        // Senza la chiave le Lenti sono state salvate prima della 1.3.1: lì la riga c'è sempre stata (0,5), anche se il
        // valore di serie ora è 0.
        seams = try c.decodeIfPresent(Double.self, forKey: .seams) ?? 0.5
        shape = try c.decodeIfPresent(Shape.self, forKey: .shape) ?? d.shape
        // Fino alla 1.2 c'era solo «coverage» (quanto vetro, da destra): diventa il taglio a sinistra.
        let legacy = try decoder.container(keyedBy: LegacyKeys.self)
        let oldCoverage = try legacy.decodeIfPresent(Double.self, forKey: .coverage)
        cutLeft = try c.decodeIfPresent(Double.self, forKey: .cutLeft) ?? oldCoverage.map { 1 - $0 } ?? d.cutLeft
        cutRight = try c.decodeIfPresent(Double.self, forKey: .cutRight) ?? d.cutRight
        cell = try c.decodeIfPresent(Double.self, forKey: .cell) ?? d.cell
        grid = try c.decodeIfPresent(Grid.self, forKey: .grid) ?? d.grid
        refraction = try c.decodeIfPresent(Double.self, forKey: .refraction) ?? d.refraction
        frost = try c.decodeIfPresent(Double.self, forKey: .frost) ?? d.frost
        relief = try c.decodeIfPresent(Double.self, forKey: .relief) ?? d.relief
        light = try c.decodeIfPresent(Double.self, forKey: .light) ?? d.light
        dispersion = try c.decodeIfPresent(Double.self, forKey: .dispersion) ?? d.dispersion
        grain = try c.decodeIfPresent(Double.self, forKey: .grain) ?? d.grain
        brightness = try c.decodeIfPresent(Double.self, forKey: .brightness) ?? d.brightness
        tint = try c.decodeIfPresent(Tint.self, forKey: .tint) ?? d.tint
        glow = try c.decodeIfPresent(Bool.self, forKey: .glow) ?? d.glow
    }
}

/// Cannettato: canne di vetro come il Liquid Glass di Apple (carpa, 20 novembre 2026: «deve proprio sembrare liquid
/// glass come quello di Apple»): vetro limpido, l'immagine nitida in mezzo alla canna e piegata forte solo verso
/// l'orlo (la lente), i colori che si separano sugli orli, un filo di luce sui bordi rivolti alla luce, un'ombra
/// sottile dove le canne si toccano e i colori un po' più vivi dietro il vetro. Smerigliato e grana restano a scelta.
struct FlutedOptions: Sendable, Hashable, Codable {
    // I valori di serie sono le regolazioni di carpa del 20 novembre 2026 (carpa: «le impostazioni che ho io per
    // fluted, lenses e foggy siano quelle default»). «Valori di serie» nelle Impostazioni torna qui.
    /// Tonde: cilindri, la lente su tutta la canna. A punta: due facce piane, la canna sdoppia. Lastre: piatte in
    /// mezzo con l'orlo curvo, come i vetri di Apple. Specchio: lo spostamento cresce in modo lineare da un orlo
    /// all'altro della canna, come il vetro cannettato di Photoshop (una sfumatura per canna come mappa di
    /// spostamento): l'immagine si ripete, stretta, in tante canne di fila (carpa, con un ritratto «Mirror Effect»).
    enum Profile: String, CaseIterable, Sendable, Codable { case round, pointed, flat, mirror }
    enum Tint: String, CaseIterable, Sendable, Codable { case photo, night, gray }
    var width: Double = 57.252859459326736
    /// Gradi, da −90 a 90: 0 canne in piedi, 90 coricate (carpa: «permetti anche di curvarlo o ruotarlo», con un
    /// riferimento a canne orizzontali che ondeggiano).
    var angle: Double = 0
    /// Quanto le canne si piegano (0 dritte) e quante onde fanno da un bordo all'altro dello schermo (0,5 è un arco).
    var curve: Double = 0
    var waves: Double = 0.5
    /// Quanto vetro togliere ai due lati della traversa delle canne (frazioni): lì resta l'immagine intatta, come nel
    /// riferimento «Mirror Effect». Con le canne in piedi sono sinistra e destra.
    var cutLeft: Double = 0
    var cutRight: Double = 0
    /// Con Specchio: ogni canna mostra l'immagine spostata indietro di questa frazione di canna rispetto alla canna
    /// prima, così lo stesso soggetto si ripete in fila quasi a grandezza normale (come nel riferimento).
    var repetition: Double = 0.01984360388228609
    /// Canne di larghezze diverse, come un vetro fatto a mano (il riferimento blu con la grana).
    var irregularity: Double = 0
    var refraction: Double = 2
    /// La separazione dei colori sugli orli.
    var dispersion: Double = 0
    /// L'immagine tirata lungo le canne, come nel riferimento.
    var smear: Double = 0
    var frost: Double = 0
    var light: Double = 0
    var grain: Double = 0.264937261396811
    var contrast: Double = 0
    var brightness: Double = 0
    var profile: Profile = .round
    var tint: Tint = .photo
    var glow = true

    init() {}
    /// Tutti i numeri sono numeri (un NaN salvato farebbe cadere l'app a ogni avvio).
    var isFinite: Bool {
        [width, angle, curve, waves, cutLeft, cutRight, repetition, irregularity, refraction, dispersion, smear, frost, light, grain,
         contrast, brightness].allSatisfy(\.isFinite)
    }
    /// Le scelte salvate da una versione con meno campi restano: i campi che mancano prendono il valore di serie.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = FlutedOptions()
        width = try c.decodeIfPresent(Double.self, forKey: .width) ?? d.width
        angle = try c.decodeIfPresent(Double.self, forKey: .angle) ?? d.angle
        curve = try c.decodeIfPresent(Double.self, forKey: .curve) ?? d.curve
        waves = try c.decodeIfPresent(Double.self, forKey: .waves) ?? d.waves
        // Fino alla 1.2 c'era solo «coverage» (quanto vetro, da destra): diventa il taglio a sinistra.
        let legacy = try decoder.container(keyedBy: LegacyKeys.self)
        let oldCoverage = try legacy.decodeIfPresent(Double.self, forKey: .coverage)
        cutLeft = try c.decodeIfPresent(Double.self, forKey: .cutLeft) ?? oldCoverage.map { 1 - $0 } ?? d.cutLeft
        cutRight = try c.decodeIfPresent(Double.self, forKey: .cutRight) ?? d.cutRight
        repetition = try c.decodeIfPresent(Double.self, forKey: .repetition) ?? d.repetition
        irregularity = try c.decodeIfPresent(Double.self, forKey: .irregularity) ?? d.irregularity
        refraction = try c.decodeIfPresent(Double.self, forKey: .refraction) ?? d.refraction
        dispersion = try c.decodeIfPresent(Double.self, forKey: .dispersion) ?? d.dispersion
        smear = try c.decodeIfPresent(Double.self, forKey: .smear) ?? d.smear
        frost = try c.decodeIfPresent(Double.self, forKey: .frost) ?? d.frost
        light = try c.decodeIfPresent(Double.self, forKey: .light) ?? d.light
        grain = try c.decodeIfPresent(Double.self, forKey: .grain) ?? d.grain
        contrast = try c.decodeIfPresent(Double.self, forKey: .contrast) ?? d.contrast
        brightness = try c.decodeIfPresent(Double.self, forKey: .brightness) ?? d.brightness
        profile = try c.decodeIfPresent(Profile.self, forKey: .profile) ?? d.profile
        tint = try c.decodeIfPresent(Tint.self, forKey: .tint) ?? d.tint
        glow = try c.decodeIfPresent(Bool.self, forKey: .glow) ?? d.glow
    }
}

/// Le chiavi di prima, lette solo per non perdere le scelte salvate.
private enum LegacyKeys: String, CodingKey { case coverage }

/// Nebbia: un vetro stampato a piccoli rilievi che sfoca e frantuma l'immagine (carpa, 20 novembre 2026, con un
/// riferimento «Foggy glass effect»). La superficie è un rumore liscio a tre ottave: ogni rilievo piega l'immagine e
/// prende un filo di luce; Smerigliato la sfoca, Velo la fa lattiginosa.
struct FogOptions: Sendable, Hashable, Codable {
    // I valori di serie sono le regolazioni di carpa del 20 novembre 2026 (carpa: «le impostazioni che ho io per
    // fluted, lenses e foggy siano quelle default»). «Valori di serie» nelle Impostazioni torna qui.
    enum Tint: String, CaseIterable, Sendable, Codable { case photo, gray }
    var size: Double = 9.182338186551789
    var refraction: Double = 2
    var frost: Double = 0.18580589196080127
    var veil: Double = 0
    var light: Double = 0
    var dispersion: Double = 0.3447688302241876
    var grain: Double = 0.0638617065701559
    var brightness: Double = 0
    var cutLeft: Double = 0
    var cutRight: Double = 0
    var tint: Tint = .photo
    var glow = false

    init() {}
    var isFinite: Bool {
        [size, refraction, frost, veil, light, dispersion, grain, brightness, cutLeft, cutRight].allSatisfy(\.isFinite)
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = FogOptions()
        size = try c.decodeIfPresent(Double.self, forKey: .size) ?? d.size
        refraction = try c.decodeIfPresent(Double.self, forKey: .refraction) ?? d.refraction
        frost = try c.decodeIfPresent(Double.self, forKey: .frost) ?? d.frost
        veil = try c.decodeIfPresent(Double.self, forKey: .veil) ?? d.veil
        light = try c.decodeIfPresent(Double.self, forKey: .light) ?? d.light
        dispersion = try c.decodeIfPresent(Double.self, forKey: .dispersion) ?? d.dispersion
        grain = try c.decodeIfPresent(Double.self, forKey: .grain) ?? d.grain
        brightness = try c.decodeIfPresent(Double.self, forKey: .brightness) ?? d.brightness
        cutLeft = try c.decodeIfPresent(Double.self, forKey: .cutLeft) ?? d.cutLeft
        cutRight = try c.decodeIfPresent(Double.self, forKey: .cutRight) ?? d.cutRight
        tint = try c.decodeIfPresent(Tint.self, forKey: .tint) ?? d.tint
        glow = try c.decodeIfPresent(Bool.self, forKey: .glow) ?? d.glow
    }
}

enum GlassRenderer {

    // MARK: - Nebbia

    static func fog(_ source: WallpaperSource, options o: FogOptions, canvas: CGSize, region: CGRect? = nil, scale: CGFloat = 2,
                    glowSpread: CGFloat = 1) -> CGImage? {
        let k = Float(scale / 2)
        let S = Float(max(2, o.size)) * k
        let blur = mix(1.2 * k, 34 * k, Float(o.frost))
        guard let buf = Cover(source.image, canvas: canvas, unit: max(1, blur * 0.6)) else { return nil }
        let refr = Float(o.refraction), light = Float(o.light), veil = Float(o.veil), grain = Float(o.grain)
        let bright = Float(o.brightness), gray = o.tint == .gray
        let spread = Float(o.dispersion) * S * 0.12
        let W = Float(canvas.width)
        // Ogni taglio vale solo se c'è (con 0 nessun bordo, nemmeno per un arrotondamento).
        let start = o.cutLeft > 0.001 ? W * Float(o.cutLeft) : -.infinity
        let end = o.cutRight > 0.001 ? W * Float(1 - o.cutRight) : .infinity
        let partial = o.cutLeft > 0.001 || o.cutRight > 0.001
        // Nelle parti tolte l'immagine è nitida: un buffer suo a piena risoluzione (quello del vetro è ridotto quanto
        // la sfocatura e la farebbe a blocchi).
        let sharp = partial ? Cover(source.image, canvas: canvas, unit: max(1, 1.2 * k)) : nil
        let toLight = SIMD2<Float>(-0.6, -0.8)
        let e = S * 0.3
        // La superficie: tre ottave di rumore liscio, la più grande pesa di più.
        // Le creste (1 − |2n − 1|) fanno i rilievi a puntini del vetro stampato invece di onde morbide.
        @Sendable @inline(__always) func height(_ x: Float, _ y: Float) -> Float {
            let a = noise2(x / S, y / S), b = noise2(x / (S * 0.45) + 37.1, y / (S * 0.45) + 11.7)
            let c = noise2(x / (S * 0.2) + 91.3, y / (S * 0.2) + 53.9)
            return (1 - abs(2 * a - 1)) * 0.55 + (1 - abs(2 * b - 1)) * 0.3 + c * 0.15
        }
        return Pixels.render(canvas: canvas, region: region, glow: o.glow ? Float(glowSpread) : nil) { x, y in
            let px = SIMD2(x, y)
            var c: SIMD3<Float>
            if partial, x < start || x >= end {
                c = (sharp ?? buf).sample(px)
            } else {
                let h0 = height(x, y)
                let g = SIMD2(height(x + e, y) - h0, height(x, y + e) - h0) * (S / e)
                let disp = g * (refr * S * 1.4)
                let fringe = spread * (g * g).sum().squareRoot()
                if fringe > 0.25 {
                    let dir = g / max((g * g).sum().squareRoot(), 1e-4)
                    let r = buf.soft(px + disp - dir * fringe, blur: blur), gg = buf.soft(px + disp, blur: blur)
                    let b = buf.soft(px + disp + dir * fringe, blur: blur)
                    c = SIMD3(r.x, gg.y, b.z)
                } else {
                    c = buf.soft(px + disp, blur: blur)
                }
                let l0 = luma(c)
                c = SIMD3(repeating: l0) + (c - SIMD3(repeating: l0)) * 1.08
                // Luce: i rilievi rivolti in alto a sinistra più chiari, gli altri in ombra, un riflesso sulle creste.
                let facing = -(g * toLight).sum()
                c *= 1 + facing * light * 0.22
                c += SIMD3(repeating: pow(max(0, facing), 2) * light * 0.16)
                // Velo: il vetro diventa lattiginoso.
                c = mix(c, c * 0.82 + 0.16, veil)
            }
            c += SIMD3(repeating: bright)
            if gray { c = SIMD3(repeating: luma(c)) }
            if grain > 0.001 { c += SIMD3(repeating: grainNoise(x, y) * grain * 0.14) }
            return simd_clamp(c, SIMD3(repeating: 0), SIMD3(repeating: 1))
        }
    }

    // MARK: - Lenti

    /// `scale` è la densità dello schermo: le misure sono in pixel Retina, come per il favo.
    static func lenses(_ source: WallpaperSource, options o: LensOptions, canvas: CGSize, region: CGRect? = nil, scale: CGFloat = 2,
                       glowSpread: CGFloat = 1) -> CGImage? {
        let k = Float(scale / 2)
        let C = Float(max(4, o.cell)) * k
        let frost = Float(o.frost)
        let blur = mix(1.2 * k, C * 1.6, frost)
        guard let buf = Cover(source.image, canvas: canvas, unit: max(1, blur * 0.6)) else { return nil }
        let refr = Float(o.refraction), relief = Float(o.relief), light = Float(o.light)
        // Dispersione: un orlo colorato di pochi pixel, non una copia rossa e una blu (carpa: «troppo rgb, glitchy»).
        let spread = Float(o.dispersion) * C * 0.035
        let grain = Float(o.grain), bright = Float(o.brightness), grid = o.grid, gray = o.tint == .gray
        // Miniature: oltre allo spostamento della cupola, il punto si legge capovolto attorno al centro della lente,
        // da 1:1 a tre volte più largo (l'immagine rimpicciolita in ogni lente).
        // Da 1,4 a 4: sotto 1 la lente mostrerebbe un colore solo (il punto dove la copia si capovolge).
        let mini: Float = o.miniatures < 0.02 ? 0 : 1.4 + Float(o.miniatures) * 2.6
        let pyramid = o.shape == .pyramid
        // Estensione: un orlo dritto, a un multiplo della cella; a sinistra l'immagine com'è.
        let partial = o.cutLeft > 0.001 || o.cutRight > 0.001
        let start = o.cutLeft > 0.001 ? ((Float(canvas.width) * Float(o.cutLeft)) / C).rounded(.down) * C : -.infinity
        let end = o.cutRight > 0.001 ? ((Float(canvas.width) * Float(1 - o.cutRight)) / C).rounded(.up) * C : .infinity
        let sharp = partial ? Cover(source.image, canvas: canvas, unit: max(1, 1.2 * k)) : nil
        let toLight = SIMD2<Float>(-0.6, -0.8)
        // Diagonale: la griglia quadrata girata di 45 gradi, come nel riferimento.
        let angle: Float = grid == .diagonal ? .pi / 4 : 0
        let ca = cos(angle), sa = sin(angle)
        let seamWidth = max(0.8, 1.1 * k)
        // Smerigliato: niente righe nette fra le lenti e meno lucido sugli orli.
        let sheen = light * (1 - frost * 0.6)
        // Bordi: la riga fra le celle (l'ombra e, nelle piramidi, il filo di luce sull'orlo della cella). 0,5 quella di
        // sempre, 1 il doppio, 0 nessuna. Il lucido e il rilievo della cupola restano: li regolano Luce e Rilievo.
        let seams = Float(max(0, o.seams)) * 2
        let seamStrength = min(0.95, 0.3 * (0.4 + light) * (1 - frost * 0.85) * seams)
        return Pixels.render(canvas: canvas, region: region, glow: o.glow ? Float(glowSpread) : nil) { x, y in
            let px = SIMD2(x, y)
            if partial, x < start || x >= end {
                var c = (sharp ?? buf).sample(px) + SIMD3(repeating: bright)
                if gray { c = SIMD3(repeating: luma(c)) }
                if grain > 0.001 { c += SIMD3(repeating: grainNoise(x, y) * grain * 0.14) }
                return simd_clamp(c, SIMD3(repeating: 0), SIMD3(repeating: 1))
            }
            var q: SIMD2<Float>
            var edge: Float
            // La direzione della faccia, per le piramidi (la normale della faccia su cui cade il punto).
            var facet = SIMD2<Float>(0, 0)
            // Distanza dallo spigolo fra due facce, per il filo di luce delle piramidi.
            var ridgeDist: Float = .infinity
            if grid == .hex {
                let r3: Float = 1.7320508
                let p = px / C
                let ax = p.x.rounded(.down) + 0.5, ay = (p.y / r3).rounded(.down) + 0.5
                let bx = (p.x - 0.5).rounded(.down) + 0.5, by = ((p.y - 1) / r3).rounded(.down) + 0.5
                let h1 = SIMD2(p.x - ax, p.y - ay * r3), h2 = SIMD2(p.x - (bx + 0.5), p.y - (by + 0.5) * r3)
                let hq = (h1 * h1).sum() < (h2 * h2).sum() ? h1 : h2
                q = hq * C
                let aq = abs(hq)
                edge = (0.5 - max(aq.x * 0.5 + aq.y * 0.8660254, aq.x)) * C
                if pyramid {
                    let angle = atan2(hq.y, hq.x)
                    let sector = (angle / 1.0471976).rounded() * 1.0471976
                    facet = SIMD2(cos(sector), sin(sector))
                    // Gli spigoli stanno a metà fra due normali (±30 gradi dalla normale della faccia).
                    ridgeDist = (hq * hq).sum().squareRoot() * C * abs(sin(abs(angle - sector) - 0.5235988))
                }
            } else {
                let pr = SIMD2(ca * px.x + sa * px.y, -sa * px.x + ca * px.y)
                let qr = pr - ((pr / C).rounded(.down) + 0.5) * C
                q = SIMD2(ca * qr.x - sa * qr.y, sa * qr.x + ca * qr.y)
                edge = 0.5 * C - max(abs(qr.x), abs(qr.y))
                if pyramid {
                    let fr: SIMD2<Float> = abs(qr.x) > abs(qr.y) ? SIMD2(qr.x < 0 ? -1 : 1, 0) : SIMD2(0, qr.y < 0 ? -1 : 1)
                    facet = SIMD2(ca * fr.x - sa * fr.y, sa * fr.x + ca * fr.y)
                    // Gli spigoli sono le diagonali del quadrato, nel suo sistema (girato con la griglia).
                    ridgeDist = abs(abs(qr.x) - abs(qr.y)) * 0.7071068
                }
            }
            let len = (q * q).sum().squareRoot()
            let rr = len / (C * 0.5)
            // La cupoletta: piana in mezzo, sempre più inclinata verso l'orlo; la deviazione cresce come nel Cannettato.
            // Piramidi: ogni faccia è piana, inclinata uguale: sposta l'immagine di un tanto fisso verso la sua normale.
            let tilt: Float = pyramid ? 0.6 : min(rr, 1)
            let bend = tilt / max(0.2, (1 - tilt * tilt * 0.96).squareRoot())
            let dir = pyramid ? facet : (len > 1e-3 ? q / len : SIMD2<Float>(0, 0))
            let disp = bend * refr * C * 0.3
            var c: SIMD3<Float>
            let base = px - q * mini
            let fringe = spread * tilt * tilt
            if fringe > 0.25 {
                let r = buf.soft(base + dir * (disp - fringe), blur: blur)
                let g = buf.soft(base + dir * disp, blur: blur)
                let b = buf.soft(base + dir * (disp + fringe), blur: blur)
                c = SIMD3(r.x, g.y, b.z)
            } else {
                c = buf.soft(base + dir * disp, blur: blur)
            }
            let l0 = luma(c)
            c = SIMD3(repeating: l0) + (c - SIMD3(repeating: l0)) * 1.12
            c = c * 1.03 + 0.015
            // Rilievo: orli scuri e centro che raccoglie la luce.
            c *= mix(1, 0.2, relief * smoothstep(0.25, 1.15, rr))
            c += SIMD3(repeating: relief * 0.3 * smoothstep(0.55, 0, rr) * l0)
            // Il filo di luce sugli orli rivolti in alto a sinistra, l'ombra sugli altri, la riga fra le lenti.
            let facing = max(0, (dir * toLight).sum())
            if pyramid {
                // Ogni faccia ha la sua luce: le facce verso la luce più chiare, le altre in ombra; un filo sugli spigoli.
                c *= 1 + (facing - 0.35) * sheen * 0.45
                // Il filo sugli spigoli della piramide resta; quello sull'orlo della cella segue i Bordi.
                let ridge = ridgeDist / seamWidth, rim = edge / seamWidth
                c += SIMD3(repeating: max(exp(-ridge * ridge), exp(-rim * rim) * min(1, seams)) * sheen * 0.08)
            } else {
                let rim = smoothstep(0.55, 1, tilt)
                c += SIMD3(repeating: rim * rim * sheen * (0.1 + 0.45 * facing) * (1 - relief * 0.5))
                c *= 1 - smoothstep(0.35, 0.95, tilt) * (1 - facing) * sheen * 0.2
            }
            let e = edge / seamWidth
            c *= 1 - exp(-e * e) * seamStrength
            // Smerigliato: un velo lattiginoso.
            c = mix(c, c * 0.86 + 0.1, frost * 0.3)
            c += SIMD3(repeating: bright)
            if gray { c = SIMD3(repeating: luma(c)) }
            if grain > 0.001 { c += SIMD3(repeating: grainNoise(x, y) * grain * 0.14) }
            return simd_clamp(c, SIMD3(repeating: 0), SIMD3(repeating: 1))
        }
    }

    // MARK: - Cannettato

    static func fluted(_ source: WallpaperSource, options o: FlutedOptions, canvas: CGSize, region: CGRect? = nil, scale: CGFloat = 2,
                       glowSpread: CGFloat = 1) -> CGImage? {
        let k = Float(scale / 2)
        let F = Float(max(4, o.width)) * k
        // Limpido di serie: un'ombra di sfocatura solo per non far vedere i pixel dell'immagine ingrandita.
        let blur = mix(1.2 * k, F * 0.9, Float(o.frost))
        guard let buf = Cover(source.image, canvas: canvas, unit: max(1, blur * 0.6)) else { return nil }
        let a = Float(o.angle) * .pi / 180
        let dir = SIMD2(cos(a), sin(a)), perp = SIMD2(-dir.y, dir.x)
        // Curvatura: le canne seguono un'onda lungo la loro direzione; `span` è il lato lungo della tela, così
        // l'anteprima rimpicciolita ha le stesse onde dello schermo.
        let span = Float(max(canvas.width, canvas.height))
        let kw = 2 * Float.pi * Float(o.waves) / span
        let amp = Float(o.curve) * span * 0.12
        let refr = Float(o.refraction), light = Float(o.light), grain = Float(o.grain), smear = Float(o.smear)
        // Dispersione: un orlo colorato di pochi pixel, solo dove il vetro è inclinato (carpa: «troppo rgb, glitchy»).
        let spread = Float(o.dispersion) * F * 0.04
        let contrast = Float(o.contrast), bright = Float(o.brightness)
        let profile = o.profile, tint = o.tint
        // La luce viene da in alto a sinistra, come nei vetri di Apple.
        let toLight = SIMD2<Float>(-0.6, -0.8)
        let seam = max(0.8, 1.1 * k)
        let bevel: Float = 0.26
        // Estensione: le canne cominciano a un orlo di canna, a quella frazione dello schermo lungo la loro traversa.
        let corners = [SIMD2<Float>(0, 0), SIMD2(Float(canvas.width), 0), SIMD2(0, Float(canvas.height)),
                       SIMD2(Float(canvas.width), Float(canvas.height))].map { ($0 * dir).sum() }
        // Senza la curvatura: l'inizio delle canne (e la loro numerazione, per la Ripetizione) non salta quando si piegano.
        let lo = corners.min() ?? 0, hi = corners.max() ?? 0
        let partial = o.cutLeft > 0.001 || o.cutRight > 0.001
        let repetition = Float(o.repetition)
        let irregular = Float(o.irregularity)
        // La numerazione delle canne (Ripetizione) parte sempre dal primo orlo; i tagli valgono solo se ci sono:
        // con l'Irregolarità le canne vanno un poco oltre gli angoli e un bordo a «nessun taglio» le taglierebbe.
        let anchor = ((lo + (hi - lo) * Float(o.cutLeft)) / F).rounded(.down) * F
        let start = o.cutLeft > 0.001 ? anchor : -.infinity
        let end = o.cutRight > 0.001 ? ((hi - (hi - lo) * Float(o.cutRight)) / F).rounded(.up) * F : .infinity
        let sharp = partial ? Cover(source.image, canvas: canvas, unit: max(1, 1.2 * k)) : nil
        let stretch = 1 + contrast * 1.5
        @Sendable func finish(_ input: SIMD3<Float>, _ x: Float, _ y: Float) -> SIMD3<Float> {
            var c = input
            switch tint {
            case .night:
                let L = min(max((luma(c) - 0.5) * stretch + 0.5 + bright, 0), 1)
                let high = mix(SIMD3(0.17, 0.24, 0.45), SIMD3(0.86, 0.86, 0.89), smoothstep(0.35, 1, L))
                c = mix(SIMD3(0.02, 0.03, 0.09), high, smoothstep(0, 0.45, L))
            case .gray:
                let L = min(max((luma(c) - 0.5) * stretch + 0.5 + bright, 0), 1)
                c = SIMD3(repeating: L * 0.95 + 0.02)
            case .photo:
                c = (c - 0.5) * stretch + 0.5 + bright
            }
            if grain > 0.001 { c += SIMD3(repeating: grainNoise(x, y) * grain * 0.14) }
            return simd_clamp(c, SIMD3(repeating: 0), SIMD3(repeating: 1))
        }
        return Pixels.render(canvas: canvas, region: region, glow: o.glow ? Float(glowSpread) : nil) { x, y in
            let px = SIMD2(x, y)
            let t = (px * perp).sum()
            let straight = (px * dir).sum() + amp * sin(kw * t)
            // Irregolarità: la traversa si stira e si stringe piano piano, così le canne cambiano larghezza (la
            // deformazione cresce sempre: le canne non si accavallano).
            let fx = irregular > 0.001 ? straight + irregular * F * 0.9 * (smoothNoise(straight / (F * 2.3)) - 0.5) : straight
            let u = (fx / F) - (fx / F).rounded(.down) - 0.5
            // Fuori dall'estensione: l'immagine com'è.
            if partial, fx < start || fx >= end { return finish((sharp ?? buf).sample(px), x, y) }
            // La normale della canna piegata (di traverso alla canna) e la sua tangente.
            var n = dir + perp * (amp * kw * cos(kw * t))
            n /= max((n * n).sum().squareRoot(), 1e-4)
            let tangent = SIMD2(-n.y, n.x)
            let side: Float = u < 0 ? -1 : 1
            // Quanto è inclinata la superficie (0 in piano, verso 1 sull'orlo) e quanto devia la luce: per un vetro
            // curvo la deviazione cresce in fretta verso l'orlo, come la tangente dell'angolo.
            let tilt: Float
            switch profile {
            case .round: tilt = min(abs(u) * 2, 1)
            case .pointed: tilt = 0.6
            case .flat: tilt = smoothstep(0.5 - bevel, 0.5, abs(u)) * 0.98 + (abs(u) > 0.5 - bevel ? 0.02 : 0)
            case .mirror: tilt = smoothstep(0.36, 0.5, abs(u))
            }
            let bend = tilt / max(0.2, (1 - tilt * tilt * 0.96).squareRoot())
            // Specchio: dritto da −2,5 a +2,5 larghezze di canna per Rifrazione 1 (l'immagine stretta fino a sei volte).
            // Ripetizione, con ogni forma: ogni canna mostra l'immagine spostata indietro rispetto a quella prima.
            let strip = (fx / F).rounded(.down) - anchor / F
            var disp: Float = profile == .mirror ? u * F * refr * 2.5 : side * bend * refr * F * 0.22
            disp -= strip * F * repetition
            func look(_ d: Float) -> SIMD3<Float> {
                let sp = px + n * d
                guard smear > 0.01 else { return buf.soft(sp, blur: blur) }
                let reach = smear * F * 3
                var acc = SIMD3<Float>(repeating: 0)
                for i in -3...3 { acc += buf.sample(sp + tangent * (Float(i) / 3 * reach)) }
                return acc / 7
            }
            var c: SIMD3<Float>
            let fringe = spread * tilt * tilt
            if fringe > 0.25 {
                // Sugli orli i colori si separano di pochi pixel: il rosso un po' indietro, il blu un po' avanti.
                let r = look(disp - side * fringe), g = look(disp), b = look(disp + side * fringe)
                c = SIMD3(r.x, g.y, b.z)
            } else {
                c = look(disp)
            }
            // Dietro il vetro i colori sono un po' più vivi e più chiari.
            let l0 = luma(c)
            c = SIMD3(repeating: l0) + (c - SIMD3(repeating: l0)) * 1.12
            c = c * 1.03 + 0.015
            // Luce: un filo chiaro sull'orlo rivolto alla luce (più debole sugli altri), un velo più scuro appena
            // dentro l'orlo in ombra, una riga scura dove due canne si toccano.
            let facing = max(0, ((n * side) * toLight).sum() / 1)
            let rim = smoothstep(0.55, 1, tilt)
            c += SIMD3(repeating: rim * rim * light * (0.12 + 0.5 * facing))
            c *= 1 - smoothstep(0.35, 0.95, tilt) * (1 - facing) * light * 0.22
            let edge = (0.5 - abs(u)) * F / seam
            c *= 1 - exp(-edge * edge) * 0.35 * (0.4 + light)
            return finish(c, x, y)
        }
    }

    // MARK: - Strumenti

    @inline(__always) private static func luma(_ c: SIMD3<Float>) -> Float { 0.2126 * c.x + 0.7152 * c.y + 0.0722 * c.z }
    @inline(__always) private static func mix(_ a: Float, _ b: Float, _ t: Float) -> Float { a + (b - a) * t }
    @inline(__always) private static func mix(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ t: Float) -> SIMD3<Float> { a + (b - a) * t }
    @inline(__always) private static func smoothstep(_ a: Float, _ b: Float, _ x: Float) -> Float {
        guard b != a else { return x < a ? 0 : 1 }
        let t = min(max((x - a) / (b - a), 0), 1)
        return t * t * (3 - 2 * t)
    }

    /// La grana: la somma di due rumori bianchi interi (distribuzione a triangolo, da −1 a 1). Interi e non `fract`
    /// di un prodotto: quello si ripeteva a piastrelle di 50 pixel e perdeva precisione oltre i 2000.
    @inline(__always) static func grainNoise(_ x: Float, _ y: Float) -> Float {
        let ix = UInt32(truncatingIfNeeded: Int(x)), iy = UInt32(truncatingIfNeeded: Int(y))
        return white(ix, iy) + white(ix &+ 7919, iy &+ 104_729) - 1
    }
    /// Un rumore liscio a due dimensioni, da 0 a 1.
    @inline(__always) static func noise2(_ x: Float, _ y: Float) -> Float {
        let ix = x.rounded(.down), iy = y.rounded(.down)
        let fx = x - ix, fy = y - iy
        let u = fx * fx * (3 - 2 * fx), v = fy * fy * (3 - 2 * fy)
        let x0 = UInt32(truncatingIfNeeded: Int(ix)), y0 = UInt32(truncatingIfNeeded: Int(iy))
        let a = white(x0, y0), b = white(x0 &+ 1, y0), c = white(x0, y0 &+ 1), d = white(x0 &+ 1, y0 &+ 1)
        return (a + (b - a) * u) + ((c + (d - c) * u) - (a + (b - a) * u)) * v
    }

    /// Un rumore liscio a una dimensione, da 0 a 1.
    @inline(__always) static func smoothNoise(_ x: Float) -> Float {
        let i = x.rounded(.down), f = x - i
        let a = white(UInt32(truncatingIfNeeded: Int(i)), 99), b = white(UInt32(truncatingIfNeeded: Int(i) + 1), 99)
        return a + (b - a) * (f * f * (3 - 2 * f))
    }
    @inline(__always) private static func white(_ x: UInt32, _ y: UInt32) -> Float {
        var h = (x &* 0x8DA6_B343) ^ (y &* 0xD816_3841)
        h ^= h >> 16; h &*= 0x7FEB_352D; h ^= h >> 15; h &*= 0x846C_A68B; h ^= h >> 16
        return Float(h >> 8) / Float(1 << 24)
    }

    /// L'immagine in copertura sullo schermo, ridotta di `unit`: si legge in pixel della tela, con l'interpolazione
    /// bilineare, e `soft` fa la media di nove prese (la sfocatura morbida della tavola, `imgS`).
    /// Tenuta in byte RGBA così come escono da CoreGraphics (un quarto della memoria dei numeri decimali: a schermo
    /// intero erano 90 MB per un disegno).
    struct Cover: Sendable {
        let pixels: [UInt8]
        let w: Int, h: Int
        let unit: Float

        init?(_ image: CGImage, canvas: CGSize, unit: Float) {
            let w = max(1, Int((Float(canvas.width) / unit).rounded(.up))), h = max(1, Int((Float(canvas.height) / unit).rounded(.up)))
            let rect = WallpaperPixels.coverRect(image, canvas: canvas, unit: CGFloat(unit), bufferWidth: w, bufferHeight: h)
            guard let bytes = WallpaperPixels.pixels(of: image, width: w, height: h, rect: rect) else { return nil }
            pixels = bytes
            self.w = w; self.h = h; self.unit = unit
        }

        @inline(__always) func sample(_ p: SIMD2<Float>) -> SIMD3<Float> {
            let fx = min(max(p.x / unit - 0.5, 0), Float(w - 1)), fy = min(max(p.y / unit - 0.5, 0), Float(h - 1))
            let x0 = Int(fx), y0 = Int(fy), x1 = min(w - 1, x0 + 1), y1 = min(h - 1, y0 + 1)
            let tx = fx - Float(x0), ty = fy - Float(y0)
            @inline(__always) func px(_ i: Int) -> SIMD3<Float> {
                SIMD3(Float(pixels[i]), Float(pixels[i + 1]), Float(pixels[i + 2]))
            }
            let a = px((y0 * w + x0) * 4), b = px((y0 * w + x1) * 4), c = px((y1 * w + x0) * 4), d = px((y1 * w + x1) * 4)
            let top = a + (b - a) * tx
            return (top + ((c + (d - c) * tx) - top) * ty) * (1 / 255)
        }

        @inline(__always) func soft(_ p: SIMD2<Float>, blur b: Float) -> SIMD3<Float> {
            let o = b * 0.7
            var s = SIMD3<Float>(repeating: 0)
            for dy in -1...1 { for dx in -1...1 { s += sample(p + SIMD2(Float(dx), Float(dy)) * o) } }
            return s / 9
        }
    }
}

/// «Nessuno»: l'immagine in copertura sullo schermo (come «riempi lo schermo» di macOS), senza effetti; a richiesta
/// col bagliore del favo (carpa: «con l'opzione none rimanga l'opzione glow»).
enum PlainRenderer {
    static func render(_ image: CGImage, canvas: CGSize, region: CGRect?, glow: Bool = false, spread: CGFloat = 1) -> CGImage? {
        let rect = (region ?? CGRect(origin: .zero, size: canvas)).integral
        let w = Int(rect.width), h = Int(rect.height)
        guard w > 0, h > 0 else { return nil }
        let iw = CGFloat(image.width), ih = CGFloat(image.height)
        let k = max(canvas.width / iw, canvas.height / ih)
        let dw = iw * k, dh = ih * k
        let left = (canvas.width - dw) / 2 - rect.minX, top = (canvas.height - dh) / 2 - rect.minY
        guard var bytes = WallpaperPixels.pixels(of: image, width: w, height: h, rect: CGRect(x: left, y: top, width: dw, height: dh)) else { return nil }
        if glow { WallpaperPixels.addGlow(&bytes, width: w, height: h, spread: Float(spread)) }
        return WallpaperPixels.makeImage(bytes, width: w, height: h)
    }
}

/// Disegna una tela pixel per pixel, a righe in parallelo, e ne restituisce il pezzo `region`.
enum Pixels {
    /// `glow`: il bagliore del favo, con quella larghezza (nil: niente bagliore).
    static func render(canvas: CGSize, region: CGRect?, glow: Float? = nil, _ color: @Sendable (Float, Float) -> SIMD3<Float>) -> CGImage? {
        let W = Int(canvas.width.rounded()), H = Int(canvas.height.rounded())
        let rect = (region ?? CGRect(x: 0, y: 0, width: W, height: H)).integral
        let ow = Int(rect.width), oh = Int(rect.height), ox = Int(rect.minX), oy = Int(rect.minY)
        guard ow > 0, oh > 0 else { return nil }
        var out = [UInt8](repeating: 255, count: ow * oh * 4)
        out.withUnsafeMutableBufferPointer { buffer in
            let target = Target(base: buffer.baseAddress!)
            DispatchQueue.concurrentPerform(iterations: oh) { row in
                let y = Float(oy + row) + 0.5
                let line = target.base + row * ow * 4
                for col in 0..<ow {
                    let c = color(Float(ox + col) + 0.5, y)
                    line[col * 4] = byte(c.x)
                    line[col * 4 + 1] = byte(c.y)
                    line[col * 4 + 2] = byte(c.z)
                }
            }
        }
        if let glow { WallpaperPixels.addGlow(&out, width: ow, height: oh, spread: glow) }
        guard let provider = CGDataProvider(data: Data(out) as CFData) else { return nil }
        return CGImage(width: ow, height: oh, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: ow * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    private struct Target: @unchecked Sendable { let base: UnsafeMutablePointer<UInt8> }

    /// Un canale in byte; un NaN (che `Int()` farebbe cadere) diventa nero.
    @inline(__always) private static func byte(_ v: Float) -> UInt8 {
        guard v.isFinite else { return 0 }
        return UInt8(Int(min(max(v, 0), 1) * 255 + 0.5))
    }
}
