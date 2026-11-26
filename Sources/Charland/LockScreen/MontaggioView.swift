import SwiftUI
import CharlandCore

/// La scena del Montaggio, dentro la finestra di `MappaView` (che fa l'apertura dalla foto del lettore, l'orologio e
/// il lettore): la copertina inquadrata, il velo, le parole, il lampo dei tagli, le bande da cinema e la grana.
///
/// Costa poco alla scheda video: la copertina è un'immagine sola che si sposta e si ingrandisce, il velo è
/// un'immagine già disegnata, le parole sono immagini già pronte, la grana è una piastrella che salta di posto.
struct MontaggioScene: View {
    let model: LockModel
    var thumb: CGRect
    var z: CGFloat
    /// Quanto si vedono parole, bande e grana: arrivano nella seconda parte dell'apertura e se ne vanno per prime.
    var late: Double
    /// Mentre la copertina si apre le parole ci sono già, trasparenti quanto basta per non vedersi (`MappaView`).
    var warm: Double
    /// Il testo acceso, da 0 a 1.
    var words: Double

    var body: some View {
        let size = model.size, k = model.layout.k
        let mappa = model.mappa, state = model.montaggio
        let time = mappa.time
        let still = Montaggio.still
        // la copertina ferma: per «Riduci movimento» o per l'opzione «Sfondo fermo» (le parole entrano comunque)
        let calm = still || LockSettings.shared.montaggioStill
        // con «Sfondo fermo» la copertina è intera, a tutto schermo e sfocata come nella Costellazione: niente tagli,
        // niente bande, niente lampi (carpa, 19 novembre 2026: «un po' blurrato come in costellazione e bello full screen»)
        let fixed = LockSettings.shared.montaggioStill
        // il piano del brano che suona: al cambio brano quello vecchio non va sulla copertina nuova
        let plan = Montaggio.fits(model) ? state.plan : nil
        let holds = mappa.holds
        let moment = plan.map { MontaggioMoment(plan: $0, time: time, k: k, still: calm, holds: holds) }
        // la copertina si posa a tutto schermo prima che arrivino velo e tremolii
        let settle = Double(LockModel.ease((z - 0.45) / 0.55))
        let play = LockModel.ease(model.playT)
        let mix = LockModel.ease(mappa.sceneT)
        let lift = max(late, warm)
        // la camera a mano: respira col tempo della musica (`live.clock` è fermo in pausa), più il tremolio dei colpi
        let hand = calm ? .zero : Self.hand(model.live.clock, k: Double(k))
        let shake = moment?.shake ?? .zero
        let bar = fixed ? 0 : size.height * Montaggio.bars * CGFloat(LockModel.ease(late))
        // il lettore di vetro compare in basso al centro finché il puntatore si muove: le parole salgono quel tanto che
        // basta per non finirci sotto, senza arrivare all'orologio (visto sul blocco vero, 19 novembre 2026: «solo»
        // dietro il vetro del lettore)
        let rise = lifted(plan: plan, moment: moment)
        // il cambio brano: quello che se ne va resta fermo sotto, il nuovo entra sopra quando il suo piano è pronto
        let leaving = state.leaving
        let cross = leaving.map { l in l.shownAt.map { LockModel.ease((state.tick - $0) / 0.9) } ?? 0 } ?? 1
        let goneWords = leaving.map { 1 - LockModel.ease((state.tick - $0.at) / 0.35) } ?? 0
        let announce = state.announce
        // mentre il brano nuovo si presenta, il suo testo aspetta
        let quiet = announce?.cut.map { time < $0.fade + 0.25 } ?? (announce != nil)

        ZStack(alignment: .topLeading) {
            Color.black
            // la copertina trema e respira; il velo no, se no al bordo resta una striscia di copertina senza velo.
            // Quella che se ne va sta sotto, intera, e la nuova le si posa sopra: passando dal nero, a metà della
            // dissolvenza tutto si scuriva
            ZStack(alignment: .topLeading) {
                if let leaving {
                    photo(leaving.scene, rect: leaving.rect, fixed: fixed)
                } else if let old = mappa.old, mix < 1 {
                    // (se la nuova non c'è, perché il brano non ha copertina, quella che se ne va sfuma da sé)
                    cover(old, plan: nil, moment: nil, calm: calm, fixed: fixed).opacity(mappa.scene == nil ? 1 - mix : 1)
                }
                if let scene = mappa.scene, scene.key != leaving?.scene.key {
                    cover(scene, plan: plan, moment: moment, calm: calm, fixed: fixed).opacity(leaving != nil ? cross : (mappa.old == nil ? 1 : mix))
                }
            }
            .offset(x: (shake.width + hand.width) * settle, y: (shake.height + hand.height) * settle)
            if let shade = state.shade {
                Image(decorative: shade, scale: 1).resizable().interpolation(.medium)
                    .frame(width: size.width, height: size.height)
                    .opacity(settle)
            }
            // in pausa un filo più scuro
            if play < 1 { Color.black.opacity(0.12 * (1 - play) * settle) }
            // lo stacco al nero del titolo
            if moment?.inTitle == true, words > 0 { Color(white: 0.024).opacity(lift * words) }
            // le parole del brano che se ne va, ferme al loro ultimo istante, sfumano in un attimo
            if let leaving, goneWords > 0 {
                MontaggioWords(plan: leaving.plan, moment: MontaggioMoment(plan: leaving.plan, time: leaving.time, k: k, still: true),
                               inks: leaving.inks, time: leaving.time, still: true)
                    .frame(width: size.width, height: size.height)
                    .opacity(goneWords * lift)
            }
            // le parole tremano con la copertina. I titoli di testa non sono il testo: si vedono anche col testo spento
            // o senza testo, con la copertina
            if let plan, let moment, words > 0 || moment.inOpening, !quiet {
                MontaggioWords(plan: plan, moment: moment, inks: state.inks, time: time, still: still, holds: holds)
                    .frame(width: size.width, height: size.height)
                    .opacity((moment.inOpening ? LockModel.ease(model.trackT) * LockModel.ease(model.textT) : words) * lift * cross)
                    .offset(x: (shake.width + hand.width) * settle, y: (shake.height + hand.height) * settle - rise)
            }
            // l'annuncio del brano nuovo: artista e titolo, come i titoli di testa. Se il brano nuovo non ha testo al
            // centro arriva la copertina grande, e l'annuncio le lascia il posto
            if let card = announce?.cut, let inks = announce?.inks, model.textT > 0.01 {
                let show = MontaggioPlan(cuts: [], shots: [], title: nil, opening: card, veil: 0)
                MontaggioWords(plan: show, moment: MontaggioMoment(plan: show, time: time, k: k, still: true, holds: holds),
                               inks: [-2: inks], time: time, still: still, holds: holds)
                    .frame(width: size.width, height: size.height)
                    .opacity(lift * LockModel.ease(model.textT))
                    .offset(x: (shake.width + hand.width) * settle, y: (shake.height + hand.height) * settle - rise)
            }

            // il lampo del taglio: un attimo di luce calda che si spegne subito
            if let moment, !still, !fixed, moment.cutAge >= 0, moment.cutAge < 0.3, late > 0 {
                Color(red: 1, green: 0.98, blue: 0.94).opacity(0.24 * exp(-moment.cutAge / 0.06) * late)
            }
            // le bande da cinema, che entrano dai bordi. Ci sono dal primo fotogramma (alte zero): una vista che nasce a
            // metà dell'apertura costa un fotogramma lungo proprio lì
            Color.black.frame(width: size.width, height: bar)
            Color.black.frame(width: size.width, height: bar).offset(y: size.height - bar)
            if lift > 0.003 {
                // senza movimento la grana sta ferma
                MontaggioGrain(tile: state.grain.first, tick: still ? 0 : state.tick, size: size)
                    .opacity((still ? 0.06 : 0.11) * lift)
            }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .clipped()
        .allowsHitTesting(false)
    }

    /// La camera a mano: un respiro di pochi punti, fatto di due onde per lato.
    static func hand(_ clock: Double, k: Double) -> CGSize {
        let x: Double = sin(clock * 0.9) * 3 + sin(clock * 2.3) * 1.5
        let y: Double = cos(clock * 0.7) * 2.5 + sin(clock * 1.9) * 1.2
        return CGSize(width: x * k, height: y * k)
    }

    /// Di quanto salgono le parole mentre il lettore di vetro è fuori.
    private func lifted(plan: MontaggioPlan?, moment: MontaggioMoment?) -> CGFloat {
        // con la stessa molla del lettore che sale (`hoverS`), così parole, lettore e copertina si muovono insieme
        let hover = min(1, max(0, model.hoverS))
        guard let plan, let moment, hover > 0 else { return 0 }
        let list: [MontaggioWord]
        if moment.inTitle { list = plan.title?.words ?? [] }
        else if moment.line >= 0, moment.line < plan.cuts.count { list = plan.cuts[moment.line].words }
        else if moment.inOpening { list = plan.opening?.words ?? [] }
        else { list = [] }
        guard let low = list.map({ $0.base + $0.size * 0.24 }).max(), let high = list.map({ $0.base - $0.size * 0.78 }).min() else { return 0 }
        let k = model.layout.k
        let need = low - (model.layout.card.minY - 18 * k)
        let room = high - model.size.height * 0.27
        return max(0, min(need, room)) * CGFloat(hover)
    }

    /// La copertina nell'inquadratura in corso: si stringe piano per tutta l'inquadratura e dà il colpo sulle parole
    /// forti. Aprendo cresce dalla foto del lettore fino all'inquadratura (`Montaggio.coverRect`).
    private func cover(_ scene: MappaScene, plan: MontaggioPlan?, moment: MontaggioMoment?, calm: Bool, fixed: Bool) -> some View {
        let r = Montaggio.coverRect(scene, plan: plan, moment: moment, calm: calm, fixed: fixed, z: z, thumb: thumb, size: model.size, k: model.layout.k)
        return photo(scene, rect: r, fixed: fixed)
    }

    /// Una copertina in un rettangolo: nitida, e con lo sfondo fermo con sopra la sua versione sfocata quanto nella
    /// Costellazione (`MappaBackdrop.softness`), che arriva mentre la copertina si posa.
    private func photo(_ scene: MappaScene, rect r: CGRect, fixed: Bool) -> some View {
        let settle = Double(LockModel.ease((z - 0.45) / 0.55))
        return ZStack {
            Image(nsImage: scene.cover).resizable().interpolation(.high)
            if fixed { Image(nsImage: scene.soft).resizable().interpolation(.high).opacity(MappaBackdrop.softness * settle) }
        }
        .frame(width: r.width, height: r.height)
        .offset(x: r.minX, y: r.minY)
    }
}

/// Le parole del verso in corso (o la parola dello stacco del titolo), stese in una volta sola.
///
/// Una parola sbatte in scena: arriva un poco più grande e si posa in 0,16 s, con due copie che la seguono come il
/// mosso di un edit; la parola grande lascia l'eco del contorno, tre copie che si allargano e si spengono.
struct MontaggioWords: View {
    var plan: MontaggioPlan
    var moment: MontaggioMoment
    var inks: [Int: [MontaggioInk]]
    var time: Double
    var still: Bool
    /// Le pause del brano: le parole che stavano sbattendo in scena si posano anche in pausa.
    var holds: [(at: Double, length: Double)] = []

    var body: some View {
        Canvas(opaque: false, rendersAsynchronously: false) { context, _ in
            if moment.inTitle, let title = plan.title {
                guard let set = inks[-1] else { return }
                for (i, word) in title.words.enumerated() where i < set.count && time < title.until[i] {
                    draw(word, set[i], age: MontaggioMoment.age(word.start, time: time, holds: holds), alpha: 1, in: &context)
                }
                return
            }
            // i titoli di testa, nell'intro
            if moment.inOpening, let opening = plan.opening, let set = inks[-2] {
                let out = 1 - min(1, max(0, (time - opening.fade) / 0.25))
                for (i, word) in opening.words.enumerated() where i < set.count {
                    draw(word, set[i], age: MontaggioMoment.age(word.start, time: time, holds: holds), alpha: out, in: &context)
                }
                return
            }
            guard moment.line >= 0, moment.line < plan.cuts.count, let set = inks[moment.line] else { return }
            let cut = plan.cuts[moment.line]
            let out = 1 - min(1, max(0, (time - cut.fade) / 0.25))
            guard out > 0 else { return }
            let lift = balance(cut)
            for (i, word) in cut.words.enumerated() where i < set.count {
                draw(word, set[i], age: MontaggioMoment.age(word.start, time: time, holds: holds), alpha: out, dy: lift, in: &context)
            }
        }
    }

    /// Finché la parola grande non è arrivata, le piccole già entrate stanno a metà altezza della composizione, invece
    /// che sole in alto con un buco sotto; quando la grande arriva scattano al loro posto in un attimo (0,12 s), come
    /// in un edit. Si spostano solo in verticale: allineate a sinistra o a destra restano allineate. Quando una parola
    /// apre una riga nuova il centro cambia: ci si arriva scivolando nello stesso attimo, non di colpo (Sonnet, 19
    /// novembre 2026: mezza riga di salto in un fotogramma).
    private func balance(_ cut: MontaggioCut) -> CGFloat {
        guard let landing = cut.words.filter(\.big).map(\.start).min() else { return 0 }
        let since = MontaggioMoment.age(landing, time: time, holds: holds)
        guard since < 0.12 else { return 0 }
        let small = cut.words.filter { !$0.big && $0.start < landing }
        func middle(_ list: ArraySlice<MontaggioWord>) -> CGFloat {
            let top = list.map { $0.base - $0.size * 0.78 }.min() ?? 0, bottom = list.map { $0.base + $0.size * 0.22 }.max() ?? 0
            return (top + bottom) / 2
        }
        let whole = middle(cut.words[...])
        // gli scostamenti dopo ogni parola entrata: si va dal precedente al nuovo in 0,12 s dall'entrata
        var offset: CGFloat = 0, entered = 0
        for (i, word) in small.enumerated() {
            let age = MontaggioMoment.age(word.start, time: time, holds: holds)
            guard age >= 0 else { break }
            let target = whole - middle(small[...i])
            offset = entered == 0 ? target : offset + (target - offset) * CGFloat(LockModel.ease(age / 0.12))
            entered += 1
        }
        guard entered > 0 else { return 0 }
        return since < 0 ? offset : offset * CGFloat(1 - LockModel.ease(since / 0.12))
    }

    private func draw(_ word: MontaggioWord, _ ink: MontaggioInk, age a: Double, alpha: Double, dy: CGFloat = 0, in context: inout GraphicsContext) {
        guard a >= 0, alpha > 0, let fill = ink.fill else { return }
        let rect = ink.box.offsetBy(dx: word.x, dy: word.base + dy)
        let mid = CGPoint(x: word.mid.x, y: word.mid.y + dy)
        func place(_ image: CGImage, scale: CGFloat, opacity: Double) {
            guard opacity > 0.003 else { return }
            var layer = context
            layer.opacity = opacity
            layer.translateBy(x: mid.x, y: mid.y)
            layer.scaleBy(x: scale, y: scale)
            layer.translateBy(x: -mid.x, y: -mid.y)
            layer.draw(Image(decorative: image, scale: 1), in: rect)
        }
        // senza movimento le parole compaiono e basta
        if still { place(fill, scale: 1, opacity: min(1, a / 0.2) * alpha); return }
        let k = 1 - pow(1 - min(1, a / 0.16), 3)
        let s = CGFloat(1.2 - 0.2 * k), show = min(1, a / 0.05) * alpha
        if a < 0.16 {
            for j in [2, 1] { place(fill, scale: s + 0.07 * CGFloat(j) * CGFloat(1 - k), opacity: show * 0.24 / Double(j)) }
        }
        if word.big, a < 0.8, let outline = ink.outline {
            let e = 1 - pow(1 - a / 0.8, 3)
            for j in 1...3 { place(outline, scale: 1 + 0.075 * CGFloat(j) * CGFloat(e), opacity: 0.5 * (1 - e) * (1 - 0.24 * Double(j)) * alpha) }
        }
        place(fill, scale: s, opacity: show)
    }
}

/// La grana: una piastrella di grigi a caso stesa su tutto lo schermo in sovrapposizione, che salta di posto
/// ventiquattro volte al secondo come la pellicola. Cambia solo il posto, mai l'immagine: niente da ridisegnare.
struct MontaggioGrain: View {
    var tile: CGImage?
    var tick: Double
    var size: CGSize

    var body: some View {
        if let tile {
            let frame = Int(tick * 24)
            let side: CGFloat = 96
            let ox = CGFloat((frame &* 37) % 96), oy = CGFloat((frame &* 53) % 96)
            Image(decorative: tile, scale: 2).resizable(resizingMode: .tile)
                .frame(width: size.width + side, height: size.height + side)
                .offset(x: -ox, y: -oy)
                .blendMode(.overlay)
                .allowsHitTesting(false)
        }
    }
}
