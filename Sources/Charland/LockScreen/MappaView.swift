import SwiftUI
import CharlandCore

/// «Mappa»: la copertina aperta a tutto schermo, e la canzone che ci disegna sopra una costellazione per strofa.
///
/// - ogni parola cantata è una stella, con la scritta sotto: nasce al suo posto (le lettere salgono una dopo
///   l'altra) e lì resta ferma, dentro lo schermo;
/// - le stelle sono unite da linee dritte e sottili nell'ordine in cui vengono cantate; la voce è un punto di luce
///   che corre lungo la linea e arriva quando la parola viene cantata. Una parola che torna non si ripete: la sua
///   stella e la sua scritta crescono. Una linea già percorsa si rinforza;
/// - finita la strofa la costellazione si scioglie nell'ordine in cui è nata, e la strofa dopo ricomincia da capo;
/// - dove si sta cantando la copertina si schiarisce; il bordo dello schermo è una luce soffusa che gira.
///
/// Si apre dalla foto del lettore: la copertina cresce da lì fino a prendere lo schermo. Come nel resto del blocco,
/// niente animazioni di SwiftUI: ogni numero lo porta avanti il timer di `LockScreen`, e tutto il resto si calcola
/// dal punto della canzone (`MappaMoment`).
struct MappaView: View {
    let model: LockModel
    var L: LockLayout
    /// Negli scatti fuori schermo il vetro di sistema non si disegna.
    var offscreen = false

    var body: some View {
        let state = model.mappa
        let size = model.size
        let z = Self.zoom(model.openT, opening: model.open)
        let thumb = CGRect(x: L.card.minX + 14, y: L.card.minY + 14, width: 64, height: 64)
        let window = LockOpenView.mix(thumb, CGRect(origin: .zero, size: size), z)
        let corner = Self.corner(z)
        // la costellazione e il bordo arrivano dopo, quando la copertina ha quasi preso lo schermo, e se ne vanno prima
        let late = Self.late(model.openT, opening: model.open)
        let hover = model.hoverS
        // la mappa c'è col testo acceso, ed è quella del testo che suona
        // e sparisce quando il testo si spegne col suo tasto, mentre al suo posto arriva la copertina grande (`textT`)
        let words = LockModel.ease(model.lyricsT) * LockModel.ease(model.trackT) * LockModel.ease(model.textT)
        // le strofe sono quelle del testo che suona, impaginate per questo schermo
        let ready = state.mapStamp.hasPrefix("\(model.rowsStamp)|\(size.width)x\(size.height)|") && !state.stanzas.isEmpty
            && state.stanzasFor == model.music?.trackKey
        // la mappa sta un soffio avanti alla canzone: una parola ci mette un decimo di secondo a diventare leggibile,
        // e deve esserlo quando la si sente, non dopo (carpa: «a volte c'è un po' di delay con il testo»). Il punto lo
        // porta avanti `Mappa.step`, che non lo lascia tornare indietro di poco
        let time = state.time
        let moment = ready ? MappaMoment(stanzas: state.stanzas, trail: state.trail, time: time) : nil
        let palette = state.scene?.palette ?? [SIMD3(1, 1, 1)]
        // Quello che arriva «tardi» (costellazione, luce della voce, bordo, orologio, lettore) c'è già dal primo
        // fotogramma dell'apertura, trasparente quanto basta per non vedersi: se nascesse quando `late` si stacca da
        // zero, le sue immagini verrebbero preparate tutte in quel fotogramma, a metà del movimento (misurato: il
        // fotogramma 17 di 53 durava da 20 a 30 ms, sul blocco vero fino a 72). Al primo fotogramma niente si muove
        // ancora e non si vede.
        let moving = model.openT > 0 && model.openT < 1
        let warm: Double = moving && model.open ? 0.004 : 0

        ZStack(alignment: .topLeading) {
            ZStack(alignment: .topLeading) {
                if Montaggio.active {
                    // il Montaggio: stessa finestra, stesso orologio, stesso lettore; cambia la scena
                    MontaggioScene(model: model, thumb: thumb, z: z, late: late, warm: warm, words: words)
                } else {
                    MappaBackdrop(model: model, thumb: thumb, z: z, voice: moment?.glow.map { ($0, max(words * late, warm)) })
                    if let moment, words > 0 {
                        MappaChart(stanzas: state.stanzas, moment: moment, time: time, holds: state.holds, play: LockModel.ease(model.playT),
                                   intro: late, warm: warm, palette: palette)
                            .frame(width: size.width, height: size.height)
                            .opacity(words)
                            .allowsHitTesting(false)
                    }
                    // la costellazione del brano che se ne va: ferma, si scioglie stella dopo stella
                    if let leaving = state.leaving {
                        let gone = max(0, state.now - leaving.at)
                        MappaChart(stanzas: leaving.stanzas, moment: MappaMoment(stanzas: leaving.stanzas, trail: leaving.trail, time: leaving.time),
                                   time: leaving.time, holds: [(at: leaving.time, length: gone)], play: 0, intro: late, palette: leaving.palette)
                            .frame(width: size.width, height: size.height)
                            .allowsHitTesting(false)
                    }
                }
                // senza testo (il brano non ce l'ha, o è spento col suo tasto) la copertina grande al centro, sopra lo
                // sfondo sfocato e sotto bordo e orologio (carpa, 19 novembre 2026: «quando il testo non c'è aggiungi
                // semplicemente la cover abbastanza in grande al centro dello schermo, lasciando tutto l'effetto»)
                MappaCenterCover(model: model)
                    .opacity((1 - LockModel.ease(model.textT)) * max(late, warm))
                // il bordo luminoso, nei due temi (carpa, 19 novembre 2026: «voglio il bordo luminoso anche qui»), se acceso
                if LockSettings.shared.edge {
                    MappaNeon(model: model)
                        .opacity(max(late, warm))
                }
                // l'orologio sta dentro la finestra, sempre acceso, allo stesso posto di quello di macOS: mentre la
                // copertina sale gli passa dietro, e l'orologio resta intero (dentro la finestra è il nostro, fuori
                // quello di macOS). Prima compariva alla fine, e a metà salita il bordo della foto lo tagliava
                LockClock(size: size, flat: offscreen)
            }
            .frame(width: size.width, height: size.height, alignment: .topLeading)
            // la finestra: la scena si vede da un rettangolo dagli angoli tondi grande quanto la finestra, spostato
            // al suo posto. Un rettangolo arrotondato che riempie la sua vista il sistema lo ritaglia da solo, senza
            // maschera: la forma disegnata a mano di prima era una maschera a tutto schermo anche a copertina aperta
            .offset(x: -window.minX, y: -window.minY)
            .frame(width: window.width, height: window.height, alignment: .topLeading)
            .clipShape(RoundedRectangle(cornerRadius: max(0, corner), style: .continuous))
            .offset(x: window.minX, y: window.minY)
            .frame(width: size.width, height: size.height, alignment: .topLeading)
            .contentShape(Rectangle())
            .onTapGesture { LockScreen.shared.toggleOpen() }

            // finché è una lastra che si stacca dal lettore la copertina ha un filo di luce sul bordo
            MappaWindow(rect: window, radius: corner)
                .stroke(Color.white.opacity(0.2 * Double(1 - z)), lineWidth: 1)
                .allowsHitTesting(false)

            // il lettore: lo stesso della copertina chiusa e allo stesso posto, compare finché il puntatore si muove.
            // Sale con la stessa molla con cui la copertina grande gli fa posto
            MappaCard(model: model, offscreen: offscreen)
                .opacity(max(min(1, hover) * late, warm))
                .offset(y: (1 - hover) * 14 * model.layout.k)
                .allowsHitTesting(model.hover && model.open)
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .opacity(model.openT > 0 ? 1 : 0)
    }

    /// Quanta parte dell'apertura la foto resta ferma prima di crescere (due fotogrammi su 54).
    static let hold = 0.04

    /// Da 0 (la foto del lettore) a 1 (tutto lo schermo), da quanto è compiuto il passaggio. È una molla senza
    /// rimbalzo: parte da ferma, prende subito velocità e si posa piano, sia aprendo sia tornando alla foto (la
    /// curva di prima partiva alla velocità massima: la foto scattava via dal lettore). Aprendo, per i primi due
    /// fotogrammi la foto resta ferma: in quel momento si prepara tutta la scena, e il fotogramma lungo che ne
    /// viene cade prima che qualcosa si muova.
    static func zoom(_ t: Double, opening: Bool) -> CGFloat {
        guard !Mappa.still else { return t > 0 ? 1 : 0 }
        return CGFloat(opening ? settle((t - hold) / (1 - hold), pull: 7.5) : 1 - settle(1 - t, pull: 7))
    }

    /// Una molla senza rimbalzo, da 0 a 1 mentre `x` va da 0 a 1: più `pull` è alto, prima arriva.
    static func settle(_ x: Double, pull: Double) -> Double {
        let u = min(1, max(0, x))
        return (1 - (1 + pull * u) * exp(-pull * u)) / (1 - (1 + pull) * exp(-pull))
    }

    /// Quanto si vedono la costellazione e il bordo: aprendo arrivano nella seconda parte, con calma; richiudendo
    /// se ne vanno per primi, nel primo terzo, e solo dopo la foto torna al lettore.
    static func late(_ t: Double, opening: Bool) -> Double {
        guard !Mappa.still else { return t > 0 ? 1 : 0 }
        return opening ? LockModel.ease(((t - hold) / (1 - hold) - 0.3) / 0.6) : 1 - LockModel.ease((1 - t) / 0.3)
    }

    /// Il raggio degli angoli della finestra: quello della foto del lettore alla partenza, più largo mentre cresce
    /// (la lastra resta la stessa cosa a ogni misura), e zero quando tocca i bordi dello schermo.
    static func corner(_ z: CGFloat) -> CGFloat {
        (16 + 16 * z) * CGFloat(1 - LockModel.ease(Double(z - 0.9) / 0.1))
    }
}

/// La copertina grande al centro, quando il testo non c'è: nitida (la grande del catalogo, se è arrivata), con gli
/// angoli tondi e un'ombra morbida, sotto l'orologio. Grande fin quasi al fondo dello schermo; quando compare il
/// lettore (puntatore che si muove) si stringe e sale per lasciargli posto. Quando il testo arriva si fa da parte.
struct MappaCenterCover: View {
    let model: LockModel

    /// Dove sta la copertina grande: il quadrato e quanto si vede (0 col testo acceso).
    ///
    /// Due posti, senza lettore (fin quasi al fondo) e col lettore (sopra di lui), e fra i due una linea dritta: misura
    /// e posizione cambiano insieme e alla stessa andatura, quella della molla del lettore (`hoverS`). Prima si
    /// calcolava il fondo e da lì la misura, che stava ferma al suo massimo per il primo quarto del passaggio e poi
    /// partiva di colpo (fino a 42 punti a fotogramma): un gomito nel movimento, e al ritorno lo stesso al contrario.
    static func place(_ model: LockModel) -> (rect: CGRect, bare: Double) {
        let size = model.size, L = model.layout, k = L.k
        func square(bottom: CGFloat) -> CGRect {
            let top = size.height * 0.285
            let side = max(0, min(bottom - top, size.width * 0.44, size.height * 0.6))
            return CGRect(x: size.width / 2 - side / 2, y: (top + bottom) / 2 - side / 2, width: side, height: side)
        }
        let rest = square(bottom: size.height * 0.94), up = square(bottom: L.card.minY - 24 * k)
        let h = CGFloat(model.hoverS)
        let side = rest.width + (up.width - rest.width) * h
        let mid = CGPoint(x: rest.midX + (up.midX - rest.midX) * h, y: rest.midY + (up.midY - rest.midY) * h)
        return (CGRect(x: mid.x - side / 2, y: mid.y - side / 2, width: max(0, side), height: max(0, side)), 1 - LockModel.ease(model.textT))
    }

    var body: some View {
        let size = model.size, k = model.layout.k
        let (rect, bare) = Self.place(model)
        let side = rect.width
        if let scene = model.mappa.scene, side > 40, bare > 0.001 {
            let shape = RoundedRectangle(cornerRadius: 22 * k, style: .continuous)
            Image(nsImage: scene.cover).resizable().interpolation(.high).aspectRatio(contentMode: .fill)
                .frame(width: side, height: side)
                .clipShape(shape)
                .overlay(shape.stroke(Color.white.opacity(0.12), lineWidth: 1))
                .shadow(color: .black.opacity(0.45), radius: 38 * k, y: 16 * k)
                .scaleEffect(0.96 + 0.04 * bare)
                .position(x: rect.midX, y: rect.midY)
                .frame(width: size.width, height: size.height)
                .allowsHitTesting(false)
        }
    }
}

/// La finestra da cui si vede la scena mentre si apre: un rettangolo dagli angoli tondi che cresce dalla foto.
struct MappaWindow: Shape {
    var rect: CGRect
    var radius: CGFloat
    func path(in bounds: CGRect) -> Path { Path(roundedRect: rect, cornerRadius: max(0, radius), style: .continuous) }
}

enum MappaColors {
    static func color(_ c: SIMD3<Double>) -> Color { Color(red: c.x, green: c.y, blue: c.z) }

    /// Il colore del nastro in un punto del suo cammino (da 0, l'inizio della strofa, a 1, la fine): i colori della
    /// copertina uno dopo l'altro, schiariti perché facciano luce.
    static func ribbon(_ palette: [SIMD3<Double>], at t: Double, white: Double = 0.3) -> Color {
        guard palette.count > 1 else { return light(palette, white: white) }
        let spot = min(0.9999, max(0, t)) * Double(palette.count - 1), i = Int(spot), f = spot - Double(i)
        let c = palette[i] * (1 - f) + palette[i + 1] * f
        return color(c * (1 - white) + SIMD3(white, white, white))
    }

    /// Il colore del cielo in un punto della sua sfumatura (da 0 a 1): i colori della copertina uno dopo l'altro,
    /// dal più presente, portati alla piena luce (un colore scuro della copertina darebbe una parola spenta: visto
    /// con «After Hours», dove le parole in mezzo allo schermo venivano grigie) e schiariti verso il bianco. Senza
    /// colori, bianco.
    static func sky(_ palette: [SIMD3<Double>], at t: Double, white: Double) -> SIMD3<Double> {
        guard !palette.isEmpty else { return SIMD3(1, 1, 1) }
        func lit(_ c: SIMD3<Double>) -> SIMD3<Double> { c / max(0.05, c.max()) }
        var c = lit(palette[0])
        if palette.count > 1 {
            let spot = min(0.9999, max(0, t)) * Double(palette.count - 1), i = Int(spot), f = spot - Double(i)
            c = lit(palette[i]) * (1 - f) + lit(palette[i + 1]) * f
        }
        let w = min(1, max(0, white))
        return c * (1 - w) + SIMD3(w, w, w)
    }

    /// La luce delle parole e delle strade: il colore più presente della copertina, schiarito verso il bianco.
    static func light(_ palette: [SIMD3<Double>], white: Double = 0.4) -> Color {
        guard let c = palette.first else { return .white }
        return color(c * (1 - white) + SIMD3(white, white, white))
    }
}

// MARK: - La copertina

/// La copertina a tutto schermo: nitida sotto, ammorbidita e in penombra sopra, e attorno alla voce di nuovo chiara.
/// Dalla foto del lettore cresce fino a riempire lo schermo; al cambio brano quella di prima si scioglie in quella nuova.
struct MappaBackdrop: View {
    let model: LockModel
    var thumb: CGRect
    var z: CGFloat
    /// Dove si sta cantando e quanto si vede la luce.
    var voice: (point: CGPoint, level: Double)?
    /// Quanto è ammorbidita la copertina sotto la mappa: tanto, perché le parole si leggano anche su una copertina
    /// piena di scritte (visto sul blocco vero con «Western Dream»: le parole si perdevano fra le lettere).
    static let softness = 0.84

    var body: some View {
        let state = model.mappa
        let size = model.size, k = model.layout.k
        let mix = LockModel.ease(state.sceneT)
        let play = LockModel.ease(model.playT)
        let settle = Double(LockModel.ease((z - 0.45) / 0.55))
        ZStack(alignment: .topLeading) {
            Color.black
            // la copertina che se ne va resta intera sotto e la nuova le si posa sopra: passando dal nero, a metà del
            // cambio brano tutto si scuriva
            // (se la nuova non c'è, perché il brano non ha copertina, quella che se ne va sfuma da sé)
            if let old = state.old, mix < 1 { cover(old, size, soft: settle).opacity(state.scene == nil ? 1 - mix : 1) }
            if let scene = state.scene { cover(scene, size, soft: settle).opacity(state.old == nil ? 1 : mix) }
            // il velo: quanto basta perché il bianco resti bianco; in pausa un filo in più
            Color.black.opacity(((state.scene?.shade(in: size) ?? 0.56) + 0.1 * (1 - play)) * settle)
            // il nero dell'isola che scende dal notch e sfuma: tiene leggibile l'orologio
            LinearGradient(stops: [.init(color: .black.opacity(0.62), location: 0), .init(color: .black.opacity(0.3), location: 0.14),
                                   .init(color: .black.opacity(0.08), location: 0.3), .init(color: .clear, location: 0.42)], startPoint: .top, endPoint: .bottom)
                .opacity(settle)
            // la luce della voce: lì attorno la copertina torna chiara
            if let scene = state.scene, let voice, voice.level > 0.001, let spot = state.spot {
                let r = scene.frame(in: size)
                // solo il quadrato della macchia, non tutto lo schermo: la maschera costa quanto la sua misura, e
                // con lo schermo intero da ridisegnare a ogni fotogramma (il bordo che gira) pesava
                let side = 640 * k
                let box = CGRect(x: voice.point.x - side / 2, y: voice.point.y - side / 2, width: side, height: side)
                // la stessa copertina, appena più a fuoco e senza velo: dove si canta la scena si schiarisce
                ZStack {
                    Image(nsImage: scene.cover).resizable().interpolation(.medium)
                    Image(nsImage: scene.soft).resizable().interpolation(.high).opacity(0.5)
                }
                    .frame(width: r.width, height: r.height)
                    .offset(x: r.minX - box.minX, y: r.minY - box.minY)
                    .frame(width: side, height: side, alignment: .topLeading)
                    .clipped()
                    // una macchia già disegnata che si sposta con la voce: un gradiente ricalcolato a ogni
                    // fotogramma lo disegnava il processore
                    .mask { Image(nsImage: spot).resizable() }
                    .opacity(voice.level * (0.6 + 0.4 * play))
                    .offset(x: box.minX, y: box.minY)
            }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .clipped()
        .allowsHitTesting(false)
    }

    /// La copertina al suo posto: dalla foto del lettore a tutto lo schermo, nitida, con sopra la sua versione sfocata.
    private func cover(_ scene: MappaScene, _ size: CGSize, soft: Double) -> some View {
        let r = LockOpenView.mix(thumb, scene.frame(in: size), z)
        return ZStack {
            Image(nsImage: scene.cover).resizable().interpolation(.high)
            Image(nsImage: scene.soft).resizable().interpolation(.high).opacity(MappaBackdrop.softness * soft)
        }
        .frame(width: r.width, height: r.height)
        .offset(x: r.minX, y: r.minY)
    }
}

// MARK: - Le strofe

/// Le strofe, disegnate in una volta sola: il nastro, la voce, le parole. Di solito una, due mentre quella di prima
/// si scioglie.
struct MappaChart: View {
    var stanzas: [MappaStanza]
    var moment: MappaMoment
    var time: Double
    /// Le pause del brano (`MappaState.holds`): le piccole animazioni contano anche il tempo passato in pausa.
    var holds: [(at: Double, length: Double)] = []
    /// 1 mentre suona, 0 in pausa: la luce della voce in viaggio si spegne in pausa e si riaccende alla ripresa.
    var play: Double = 1
    /// Quanto è aperta la copertina, da 0 a 1: la strofa si accende a cascata, dalla voce verso fuori.
    var intro: Double
    /// Mentre la copertina si apre le scritte già cantate si disegnano comunque, trasparenti quanto basta per non
    /// vedersi: così le loro immagini sono pronte dal primo fotogramma e non tutte insieme quando la mappa compare.
    var warm: Double = 0
    var palette: [SIMD3<Double>]

    /// Quanto dura lo sciogliersi di una strofa: ogni parola ci mette poco, ma partono una dopo l'altra.
    static let melt = 0.5, meltEach = 0.38

    /// Un numero fra 0 e 1, sempre lo stesso per ogni stella: il passo e l'attacco del suo respiro.
    static func phase(_ i: Int) -> Double { Double(UInt32(truncatingIfNeeded: (i &+ 1) &* 2_654_435_761) % 1000) / 1000 }

    var body: some View {
        Canvas(opaque: false, rendersAsynchronously: false) { context, size in
            for index in [moment.index - 1, moment.index] where index >= 0 && index < stanzas.count {
                let stanza = stanzas[index]
                // una strofa già sciolta non si disegna più
                guard age(stanza.leave) < Self.melt + Self.meltEach + 0.05 else { continue }
                draw(stanza, current: index == moment.index, in: &context)
            }
        }
    }

    /// Da quanti secondi veri è successo quello che nella canzone succede a `moment`: il tempo della canzone più le
    /// pause venute dopo. Le piccole animazioni (lettere, stelle che brillano, linee appena percorse, lo sciogliersi)
    /// contano questo, così in pausa si posano invece di restare a metà; negativo se deve ancora succedere.
    private func age(_ moment: Double) -> Double {
        var age = time - moment
        for hold in holds where hold.at >= moment { age += hold.length }
        return age
    }

    /// Quanto è sciolta una parola (o il tratto di nastro che ci arriva): la strofa si scioglie nell'ordine in cui è nata.
    private func melted(_ stanza: MappaStanza, node: Int) -> Double {
        let out = age(stanza.leave)
        guard out > 0 else { return 0 }
        let share = Double(node) / Double(max(1, stanza.map.nodes.count - 1))
        return MappaMath.ease((out - share * Self.melt * stanza.quick) / (Self.meltEach * stanza.quick))
    }

    private func draw(_ stanza: MappaStanza, current: Bool, in context: inout GraphicsContext) {
        let map = stanza.map, unit = stanza.unit
        let tint = MappaColors.light(palette), pale = MappaColors.light(palette, white: 0.72)
        var thin = StrokeStyle(lineWidth: 1, lineCap: .round)
        let voice = current ? moment.voice : nil
        // la parola su cui la voce si è posata: la sua stella resta sveglia finché la voce non riparte verso la prossima
        // (prima, con la voce ferma su una parola, non si vedeva più dove si stava cantando)
        var resting: (node: Int, level: Double)?
        if current, moment.step >= 0, moment.step < map.steps.count {
            resting = (map.steps[moment.step].node, 1 - Double(moment.going?.progress ?? 0))
        }

        // le linee: dritte e sottili, da stella a stella, come nelle carte del cielo. Una linea ripercorsa è più
        // marcata; quella appena percorsa resta accesa un momento
        for road in map.roads {
            guard let passed = road.passed(at: time), let ends = stanza.line(road) else { continue }
            let gone: Double = melted(stanza, node: max(road.a, road.b))
            guard gone < 1 else { continue }
            let wear: Double = map.wear(count: passed.count)
            let hot: Double = exp(-max(0, age(passed.last)) / 1.6)
            // la figura della costellazione è fatta dalle linee con cui le stelle sono nate; quelle che tornano a
            // una stella che c'era già sono corde più tenui, così dove si incrociano la figura resta leggibile
            let born: Double = road.passes[0] <= (map.nodes[max(road.a, road.b)].hits.first ?? 0) + 0.001 ? 1 : 0.55
            let alpha: Double = (0.5 * born + 0.2 * wear + 0.3 * hot) * (1 - gone) * intro
            var path = Path()
            path.move(to: ends.a); path.addLine(to: ends.b)
            thin.lineWidth = CGFloat(1.3 + 1.1 * wear + 0.5 * hot) * unit
            context.stroke(path, with: .color(pale.opacity(alpha)), style: thin)
        }

        // la voce in viaggio: la linea si traccia dietro di lei, e in punta c'è un punto di luce con la sua scia. In
        // pausa la linea tracciata fin lì resta, il punto di luce si spegne (fermo a metà strada sembrava un errore)
        if current, let going = moment.going, going.progress > 0.012 {
            let road = map.roads[going.road], forward = going.from == road.a
            let reach = going.progress
            func piece(_ from: CGFloat, _ to: CGFloat) -> Path? {
                guard let ends = forward ? stanza.line(road, from: from, to: to) : stanza.line(road, from: 1 - to, to: 1 - from) else { return nil }
                var path = Path()
                path.move(to: ends.a); path.addLine(to: ends.b)
                return path
            }
            if road.passed(at: time) == nil, let path = piece(0, reach) {
                thin.lineWidth = 1.3 * unit
                context.stroke(path, with: .color(pale.opacity(0.6 * intro)), style: thin)
            }
            if play > 0.01 {
                context.drawLayer { layer in
                    layer.blendMode = .plusLighter
                    layer.opacity = play
                    layer.addFilter(.shadow(color: tint.opacity(0.95), radius: 8 * unit))
                    let tail: CGFloat = 0.3, pieces = 6
                    for part in 0..<pieces {
                        let f0 = CGFloat(part) / CGFloat(pieces), f1 = CGFloat(part + 1) / CGFloat(pieces)
                        let from = max(0, reach - tail * (1 - f0)), to = max(0, reach - tail * (1 - f1))
                        guard to > from, let path = piece(from, to) else { continue }
                        var style = thin
                        style.lineWidth = (0.9 + 2.4 * f1) * unit
                        layer.stroke(path, with: .color(.white.opacity(Double(f1 * f1) * intro)), style: style)
                    }
                }
            }
        }

        // le stelle e le loro scritte, ferme al loro posto. La scritta è già disegnata (con la sua ombra) e cresce
        // verso il basso; nell'attimo in cui la parola viene cantata si disegnano le sue lettere una per una
        for i in map.nodes.indices where i < stanza.labels.count {
            let node = map.nodes[i], label = stanza.labels[i], star = stanza.stars[i]
            guard let image = label.image, let sung = node.sung(at: time) else { continue }
            let gone: Double = melted(stanza, node: i)
            guard gone < 1 else { continue }
            let since: Double = age(sung.last)
            let hot: Double = exp(-max(0, since) / 1.1)
            let first = sung.count == 1
            // a ogni ritorno cresce con una molla: va un filo oltre e si posa
            let grown: Double = first ? 1 : MappaMath.spring(since, speed: 13, damping: 0.55)
            let before = map.size(of: node, count: sung.count - 1), after = map.size(of: node, count: sung.count)
            let body: Double = before + (after - before) * grown
            let points: CGFloat = CGFloat(body) * unit
            // aprendo, la costellazione si accende a cascata dalla voce verso fuori
            let reach: Double = voice.map { min(1, Double(hypot(star.x - $0.x, star.y - $0.y) / (900 * unit))) } ?? 0
            let lit: Double = MappaMath.ease(intro * 1.7 - reach * 0.7)
            // a riposo le parole restano accese quasi del tutto (col colore, più tenui venivano spente), e quelle che
            // contano di più lo sono fino in fondo
            let rank: Double = (after - SongMap.baseSize) / SongMap.growth
            let alpha: Double = max(warm, min(1, 0.84 + 0.05 * rank + 0.3 * hot) * lit * (1 - gone))
            guard alpha > 0.002, points > 3 else { continue }

            // la stella (`MappaStar`): grande e luminosa quanto conta la parola. Quando arriva la voce i raggi si
            // allungano e il cuore si accende, poi si posano; finché la voce resta sulla parola la stella resta sveglia;
            // mentre la canzone va i raggi respirano piano, ognuno col suo passo (in pausa si fermano: il tempo della
            // canzone non avanza). Sono due immagini già pronte, stese sommando la luce: niente forme né filtri
            let spark = label.star
            let grow = points / label.body
            let glint: Double = exp(-max(0, since) / 0.3)
            let awake: Double = resting?.node == i ? resting?.level ?? 0 : 0
            let breath: Double = Mappa.still ? 1 : 1 + 0.07 * sin(time * 2 * .pi / (2.8 + 1.7 * Self.phase(i)) + 2 * .pi * Self.phase(i * 7 + 3))
            let flare = CGFloat((1 + 0.8 * glint + 0.16 * awake) * breath) * grow
            let heart = CGFloat(1 + 0.3 * glint + 0.12 * awake) * grow
            var sky = context
            if spark.adds { sky.blendMode = .plusLighter }
            sky.opacity = min(1, alpha + 0.2 * hot)
            if let rays = spark.rays {
                let side = spark.raysSide * flare
                sky.draw(Image(decorative: rays, scale: 1), in: CGRect(x: star.x - side / 2, y: star.y - side / 2, width: side, height: side))
            }
            if let core = spark.core {
                let side = spark.coreSide * heart
                let box = CGRect(x: star.x - side / 2, y: star.y - side / 2, width: side, height: side)
                sky.draw(Image(decorative: core, scale: 1), in: box)
                // il lampo: lo stesso cuore una seconda volta, sommato
                let flash = max(hot, 0.4 * awake) * alpha
                if flash > 0.03 {
                    var lit = context
                    lit.blendMode = .plusLighter
                    lit.opacity = 0.75 * flash
                    lit.draw(Image(decorative: core, scale: 1), in: box)
                }
            }

            // la scritta, sotto la stella
            // l'immagine ha un margine attorno alle lettere (13 punti al corpo pieno) e un filo d'aria sopra le maiuscole
            let air = (13 + 0.05 * label.body) * grow
            let box = CGRect(x: star.x - label.size.width * grow / 2, y: star.y + CGFloat(SongMap.labelTop) * unit - air + CGFloat(gone) * 6 * unit,
                             width: label.size.width * grow, height: label.size.height * grow)
            if since < 0.72, !label.glyphs.isEmpty {
                // la prima volta le lettere salgono una dopo l'altra, con una molla; a ogni ritorno le attraversa un'onda
                let gap: Double = min(0.034, 0.2 / Double(label.glyphs.count))
                let sweep = MappaLabel.sweep(label.size)
                context.drawLayer { layer in
                    layer.addFilter(.shadow(color: tint.opacity(0.85 * hot), radius: points * 0.42))
                    layer.translateBy(x: box.minX, y: box.minY)
                    layer.scaleBy(x: grow, y: grow)
                    for (g, glyph) in label.glyphs.enumerated() {
                        let u: Double = since - Double(g) * gap
                        // la prima volta una lettera nasce al suo turno; a un ritorno c'è già tutta e aspetta l'onda
                        // (saltarla faceva sparire la scritta e rinascere lettera per lettera: «rest» al posto di «resta»)
                        if first && u <= 0 { continue }
                        var scale: Double = 1, drop: Double = 0, show: Double = 1
                        if first {
                            let s = MappaMath.spring(u, speed: 21, damping: 0.5)
                            scale = 0.5 + 0.5 * s; drop = (1 - s) * 0.42; show = min(1, u / 0.07)
                        } else if u > 0 {
                            drop = -exp(-u * 8.5) * sin(u * 21) * 0.2; scale = 1 + 0.1 * exp(-u * 7)
                        }
                        var letter = layer
                        letter.translateBy(x: glyph.mid, y: glyph.base + CGFloat(drop) * label.body)
                        letter.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
                        letter.translateBy(x: -glyph.mid, y: -glyph.base)
                        letter.opacity = alpha * show
                        // la stessa sfumatura dell'immagine: il punto di partenza segue la lettera nel suo salto, non si vede
                        letter.fill(glyph.outline, with: .linearGradient(label.ink, startPoint: sweep.from, endPoint: sweep.to))
                    }
                }
            } else {
                var layer = context
                layer.opacity = alpha
                if hot > 0.05 { layer.addFilter(.shadow(color: tint.opacity(0.85 * hot), radius: points * 0.42)) }
                layer.draw(Image(decorative: image, scale: 1), in: box)
            }
        }
    }
}

// MARK: - Il neon

/// Il bordo dello schermo: una luce soffusa nei colori della copertina che gira attorno allo schermo, notch compreso
/// (carpa, 18 novembre 2026: «una luce soffusa che gira attorno allo schermo e va più o meno veloce in base al beat e
/// prende i colori della copertina»). Sono due luci una di fronte all'altra, con la coda lunga; tutto attorno resta
/// un chiarore tenue. Il filo sottile sul bordo si accende solo dove passa la luce.
///
/// Ogni fotogramma lo calcola `MappaEdge`: un'immagine piccola dell'alone già colorata, e il colore di ogni pezzo del
/// filo. Qui si stendono sopra la scena e si sommano alla sua luce, senza maschere (con le maschere di prima il bordo
/// da solo costava mezzo fotogramma di scheda video).
struct MappaNeon: View {
    let model: LockModel

    var body: some View {
        let state = model.mappa
        let size = model.size
        let play = LockModel.ease(model.playT)
        let level = min(1, 0.6 + 0.26 * play)
        // i colori fanno il giro dello schermo in una quarantina di secondi; la luce gira col suo passo
        let still = Mappa.still
        let frame = state.edgeFrame(size: size, notch: model.notch, hue: still ? 0 : model.live.clock * 9, spin: still ? 0 : state.spin,
                                    level: level, still: still)
        let edge = state.edge(size: size, notch: model.notch)
        ZStack {
            if let glow = frame?.glow {
                Image(decorative: glow, scale: 1).resizable().interpolation(.medium)
                    .frame(width: size.width, height: size.height)
                    .blendMode(.plusLighter)
            }
            if let line = frame?.line, !line.isEmpty, let edge {
                Canvas(opaque: false, rendersAsynchronously: false) { context, _ in
                    // i tratti si toccano di testa: sommati, dove si toccano il filo resta pieno, senza puntini
                    context.blendMode = .plusLighter
                    let style = StrokeStyle(lineWidth: MappaEdge.lineWidth, lineCap: .butt, lineJoin: .round)
                    for run in line where run.to <= edge.pieceTurns.count {
                        let c = run.color
                        context.stroke(edge.line(from: run.from, to: run.to), with: .color(Color(red: Double(c.x), green: Double(c.y), blue: Double(c.z)).opacity(Double(c.w))), style: style)
                    }
                }
                .frame(width: size.width, height: size.height)
                .blendMode(.plusLighter)
            }
        }
        .frame(width: size.width, height: size.height)
        .allowsHitTesting(false)
    }
}

// MARK: - Il lettore

/// Il lettore di vetro, lo stesso della copertina chiusa e allo stesso posto: sulla mappa compare solo finché il
/// puntatore si muove. La foto richiude la copertina.
struct MappaCard: View {
    let model: LockModel
    var offscreen: Bool

    var body: some View {
        let c = model.layout.card
        let shape = RoundedRectangle(cornerRadius: LockLayout.cardRadius, style: .continuous)
        let music = model.music
        let mix = LockModel.ease(model.trackT)
        ZStack(alignment: .topLeading) {
            Group { if offscreen { shape.fill(Color(white: 0.1).opacity(0.86)) } else { CharlandGlassFill(shape: shape) } }
                .frame(width: c.width, height: c.height)
                .shadow(color: .black.opacity(CharlandGlass.shadowOpacity), radius: CharlandGlass.shadowRadius, y: CharlandGlass.shadowY)
            LockArtwork(image: music?.artwork, old: model.oldArtwork, mix: mix, radius: 16)
                .frame(width: 64, height: 64)
                .contentShape(Rectangle())
                .onTapGesture { LockScreen.shared.toggleOpen() }
                .offset(x: 14, y: 14)
            Text(music?.title ?? "").font(.system(size: 17, weight: .semibold)).foregroundStyle(.white).lineLimit(1)
                .frame(width: 262, alignment: .leading).opacity(mix).offset(x: 92, y: 21)
            Text(music?.artist ?? "").font(.system(size: 14, weight: .medium)).foregroundStyle(.white.opacity(0.62)).lineLimit(1)
                .frame(width: 262, alignment: .leading).opacity(mix).offset(x: 92, y: 44)
            // il tasto del testo, in alto a destra: c'è solo se il brano un testo ce l'ha
            LockLyricsButton(on: model.wantsColumn)
                .opacity(LockModel.ease(model.buttonT))
                .allowsHitTesting(model.buttonT > 0.5)
                .offset(x: c.width - 14 - 42, y: 25)
            LockScrubber(model: model, width: 412, interactive: true)
                .offset(x: 14, y: 94)
            LockControls(playing: model.playing, interactive: true)
                .offset(x: c.width / 2 - 94, y: 122)
        }
        .frame(width: c.width, height: c.height, alignment: .topLeading)
        .offset(x: c.minX, y: c.minY)
    }
}
