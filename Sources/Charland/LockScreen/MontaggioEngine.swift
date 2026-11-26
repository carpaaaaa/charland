import SwiftUI
import CoreText
import CharlandCore

/// «Montaggio»: il Mac monta un edit della canzone sopra la copertina (carpa, 19 novembre 2026: «che sembri quasi un
/// edit», «deve andare virale sui social e deve essere bello»).
///
/// - ogni verso è un'inquadratura nuova della copertina (il campo largo, un dettaglio, un primo piano), con un taglio
///   netto quando il verso comincia: l'inizio dei versi è l'unico tempo esatto che dà LRCLIB, quindi i tagli cadono lì
///   e mai sulle singole parole, che sono stimate;
/// - le parole sbattono in scena una alla volta, quella che conta di più del verso grande e le altre piccole sopra e
///   sotto; sulle parole forti la scena dà un colpo di zoom, trema appena e lascia l'eco del contorno;
/// - bande da cinema, grana, e la prima volta che arriva il titolo uno stacco al nero con una parola sola al centro;
/// - nelle parti senza testo le inquadrature cambiano ogni due battute del tempo plausibile del brano.
///
/// Come la Costellazione si apre crescendo dalla foto del lettore e ne riusa la finestra, l'orologio e il lettore
/// (`MappaView`); qui c'è solo la scena. Niente animazioni di SwiftUI: tutto si calcola dal punto della canzone
/// (`MappaState.time`, che porta avanti `Mappa.step`), e le scritte sono immagini disegnate una volta poco prima che
/// servano: comporre il testo a ogni fotogramma costa.

/// Una parola del montaggio, al suo posto sullo schermo (in punti, y in giù).
struct MontaggioWord: Sendable {
    var text: String
    var start: Double
    var duration: Double
    /// Quanto conta nella canzone (`SongMap.levels`), da 0 a 3: dal 2 in su dà il colpo e il tremolio.
    var level: Int
    /// È la parola grande del verso: lascia l'eco del contorno.
    var big: Bool
    var x: CGFloat
    var base: CGFloat
    var width: CGFloat
    var size: CGFloat
    /// La sfumatura dentro le lettere, dal colore di partenza a quello d'arrivo (vuota: bianco caldo). Solo sulle
    /// parole importanti, la grande di ogni verso e quelle dello stacco del titolo (carpa, 19 novembre 2026: «il
    /// gradient in base alla copertina sul testo però solo sulle parole importanti»).
    var tint: [SIMD3<Double>] = []
    /// Il centro attorno a cui scala quando sbatte in scena.
    var mid: CGPoint { CGPoint(x: x + width / 2, y: base - size * 0.36) }
}

/// Un verso: quando comincia, quando finisce l'ultima parola, quando comincia il prossimo.
struct MontaggioCut: Sendable {
    var start: Double
    var end: Double
    var next: Double
    var words: [MontaggioWord]
    /// Le parole si spengono poco dopo la fine del verso, o al taglio del verso dopo se arriva prima.
    var fade: Double { min(next, end + 1.6) }
}

/// Un'inquadratura: da quando, su che punto della copertina (in frazioni dall'alto a sinistra), quanto stretta.
struct MontaggioShot: Sendable {
    var time: Double
    var focus: CGPoint
    var zoom: CGFloat
}

/// Lo stacco al nero del titolo: le sue parole una alla volta, ognuna da sola al centro.
struct MontaggioTitle: Sendable {
    var line: Int
    var start: Double
    var end: Double
    var words: [MontaggioWord]
    /// Fino a quando si vede ogni parola: fino alla parola dopo, l'ultima fino alla fine dello stacco.
    var until: [Double]
}

/// Il piano del montaggio di un brano, per uno schermo: versi impaginati, inquadrature, stacco del titolo.
struct MontaggioPlan: Sendable {
    var cuts: [MontaggioCut]
    var shots: [MontaggioShot]
    var title: MontaggioTitle?
    /// I titoli di testa: l'artista piccolo e il titolo grande durante l'intro, prima che si canti (o nei primi
    /// secondi, se il brano un testo non ce l'ha). Niente se il canto comincia subito.
    var opening: MontaggioCut?
    /// Le stesse due righe, impaginate, per l'annuncio quando il brano cambia a copertina aperta (vuote se non suona
    /// un'app di musica).
    var card: [MontaggioWord] = []
    /// Il velo sopra la copertina: quanto basta perché le parole bianche si leggano.
    var veil: Double
}

/// Le scritte di una parola, già disegnate: piena con l'ombra, e il solo contorno per l'eco. `box` è il rettangolo
/// dell'immagine rispetto al punto (x, linea di base) della parola, in punti.
struct MontaggioInk: @unchecked Sendable {
    var fill: CGImage?
    var outline: CGImage?
    var box: CGRect
}

@MainActor @Observable
final class MontaggioState {
    private(set) var plan: MontaggioPlan?
    /// Le scritte già disegnate, per verso (−1 il titolo). Si preparano i versi vicini a quello che suona.
    private(set) var inks: [Int: [MontaggioInk]] = [:]
    /// Di quale testo, schermo e copertina è il piano.
    @ObservationIgnored private(set) var stamp = ""
    @ObservationIgnored fileprivate var planning = ""
    @ObservationIgnored fileprivate var inking: Set<Int> = []
    /// Il velo già disegnato (nero, più scuro in alto e ai bordi), per uno schermo e un livello.
    @ObservationIgnored private(set) var shade: CGImage?
    @ObservationIgnored fileprivate var shadeFor = ""
    /// Il tempo vero da quando la copertina è aperta: fa girare la grana anche in pausa.
    @ObservationIgnored fileprivate(set) var tick = 0.0
    /// La piastrella di grana, disegnata una volta.
    @ObservationIgnored private(set) lazy var grain: [CGImage] = Montaggio.grainTiles()

    /// Il brano che si sta seguendo: quando cambia comincia la transizione.
    @ObservationIgnored fileprivate var track = ""
    /// L'ultimo istante disegnato del brano seguito e la sua inquadratura: servono a fermare il brano che se ne va.
    @ObservationIgnored fileprivate var lastTime = 0.0
    @ObservationIgnored fileprivate var lastRect: CGRect?

    /// Il brano che se ne va, fermo all'ultimo istante (carpa, 19 novembre 2026: «curare attentamente la transizione
    /// tra una canzone e l'altra, ora è un po' macchinosa», anche col mix della modalità DJ di Apple Music e Spotify).
    /// La copertina resta sulla sua inquadratura, le parole sfumano; la copertina nuova entra sopra quando il suo piano è
    /// pronto (`shownAt`), senza passare dal nero.
    struct Leaving {
        var plan: MontaggioPlan
        var time: Double
        var rect: CGRect
        var scene: MappaScene
        var inks: [Int: [MontaggioInk]]
        /// Quando è cambiato il brano e quando è comparsa la copertina nuova, in `tick`.
        var at: Double
        var shownAt: Double?
    }
    fileprivate(set) var leaving: Leaving?

    /// L'annuncio del brano nuovo, come un DJ che lo presenta: l'artista piccolo e il titolo grande entrano quando la
    /// copertina nuova compare, restano due secondi e mezzo, e intanto il testo aspetta. Le parole hanno i tempi della
    /// canzone (`cut`), così in pausa si fermano anche loro.
    struct Announce {
        var key: String
        var cut: MontaggioCut?
        var inks: [MontaggioInk]?
    }
    fileprivate(set) var announce: Announce?

    /// - Parameter keepInks: le parole sono le stesse di prima (cambia solo la copertina): le scritte già disegnate
    ///   restano, se no al taglio la prima parola arriverebbe qualche fotogramma in ritardo.
    fileprivate func set(_ plan: MontaggioPlan?, stamp: String, keepInks: Bool = false) {
        self.plan = plan
        self.stamp = stamp
        if !keepInks { inks = [:]; inking = [] }
    }

    fileprivate func store(_ inks: [MontaggioInk], line: Int, stamp: String) {
        inking.remove(line)
        guard stamp == self.stamp else { return }
        self.inks[line] = inks
    }

    fileprivate func evict(keeping lines: Set<Int>) {
        for key in inks.keys where !lines.contains(key) { inks[key] = nil }
    }

    fileprivate func setShade(_ image: CGImage?, key: String) { shade = image; shadeFor = key }
}

/// Un istante del montaggio, calcolato dal punto della canzone senza ricordare niente: saltando nel brano è subito
/// quello giusto.
struct MontaggioMoment {
    /// Il verso in corso (−1 prima del primo).
    var line = -1
    /// L'inquadratura in corso, da quanti secondi, e quanto dura.
    var shot = 0
    var sinceShot = 0.0
    var shotSpan = 4.0
    var inTitle = false
    /// Si vedono i titoli di testa (prima del primo verso).
    var inOpening = false
    /// Secondi dall'ultimo taglio (cambio d'inquadratura, entrata o uscita dallo stacco del titolo).
    var cutAge = 9.0
    /// Il colpo di zoom delle parole forti, e il tremolio (in punti).
    var punch = 0.0
    var shake = CGSize.zero

    /// Da quanti secondi veri è successo quello che nella canzone succede a `moment`: il tempo della canzone più le
    /// pause venute dopo (`MappaState.holds`). Così in pausa il lampo, il colpo e le parole che sbattono si posano
    /// invece di restare a metà; alla ripresa non ripartono.
    static func age(_ moment: Double, time: Double, holds: [(at: Double, length: Double)]) -> Double {
        var age = time - moment
        for hold in holds where hold.at >= moment { age += hold.length }
        return age
    }

    init(plan: MontaggioPlan, time: Double, k: CGFloat, still: Bool, holds: [(at: Double, length: Double)] = []) {
        // il verso in corso
        var lo = 0, hi = plan.cuts.count
        while lo < hi { let mid = (lo + hi) / 2; if plan.cuts[mid].start <= time { lo = mid + 1 } else { hi = mid } }
        line = lo - 1
        // l'inquadratura in corso
        lo = 0; hi = plan.shots.count
        while lo < hi { let mid = (lo + hi) / 2; if plan.shots[mid].time <= time { lo = mid + 1 } else { hi = mid } }
        shot = max(0, lo - 1)
        if !plan.shots.isEmpty {
            let from = plan.shots[shot].time
            sinceShot = from.isFinite ? time - from : time
            let to = shot + 1 < plan.shots.count ? plan.shots[shot + 1].time : (from.isFinite ? from + 5 : 5)
            shotSpan = max(0.5, to - (from.isFinite ? from : 0))
            cutAge = from.isFinite ? Self.age(from, time: time, holds: holds) : 9
        }
        if let opening = plan.opening, line < 0 { inOpening = time < opening.fade + 0.25 }
        if let title = plan.title {
            inTitle = time >= title.start && time < title.end
            if inTitle { cutAge = min(cutAge, Self.age(title.start, time: time, holds: holds)) }
            else if time >= title.end { cutAge = min(cutAge, Self.age(title.end, time: time, holds: holds)) }
        }
        guard !still else { return }
        // il colpo e il tremolio: le parole forti del verso in corso e di quello prima (un colpo che cade a fine verso
        // finisce dopo il taglio)
        var sx = 0.0, sy = 0.0
        for index in [line - 1, line] where index >= 0 && index < plan.cuts.count {
            for (i, word) in plan.cuts[index].words.enumerated() where word.level >= 2 {
                let a = Self.age(word.start, time: time, holds: holds)
                guard a >= 0, a < 0.9 else { continue }
                punch += 0.03 * exp(-a / 0.18)
                let amp = 7 * Double(k) * exp(-a / 0.09), seed = Double(index * 31 + i)
                sx += amp * sin(a * 95 + seed); sy += amp * cos(a * 81 + seed * 2)
            }
        }
        punch = min(0.05, punch)
        // più colpi insieme non scoprono il bordo della copertina (il margine è 18 punti, la mano ne prende 4,5)
        let far = hypot(sx, sy), most = 12 * Double(k)
        if far > most { sx *= most / far; sy *= most / far }
        shake = CGSize(width: sx, height: sy)
    }
}

@MainActor
enum Montaggio {
    static var active: Bool { LockSettings.shared.theme == .montaggio }
    static var still: Bool { Mappa.still }

    /// Lo stesso carattere della Costellazione: Helvetica, lettere strette di un filo.
    nonisolated static let face = Mappa.face
    nonisolated static let tracking = Mappa.tracking
    /// Il bianco caldo delle parole.
    nonisolated static let ink = CGColor(srgbRed: 246 / 255, green: 244 / 255, blue: 240 / 255, alpha: 1)
    /// Quanto sono alte le bande da cinema, in frazioni dell'altezza dello schermo.
    nonisolated static let bars: CGFloat = 0.072
    /// Gli ingrandimenti delle inquadrature di dettaglio, a giro.
    nonisolated static let zooms: [CGFloat] = [1.6, 1.25, 1.7, 1.12, 1.55, 1.65]

    // MARK: Un passo

    /// A ogni fotogramma a copertina aperta: il piano del brano se manca, le scritte dei versi vicini, la grana.
    static func step(_ model: LockModel, _ dt: Double) {
        guard active else { return }
        let state = model.montaggio
        state.tick += dt
        transition(model)
        plan(model)
        ink(model)
        // l'ultimo istante e l'inquadratura del brano che suona: se cambia, il brano che se ne va resta fermo lì
        if fits(model), let plan = state.plan, let scene = model.mappa.scene, model.openT > 0 {
            let time = model.mappa.time, k = model.layout.k
            let calm = still || LockSettings.shared.montaggioStill
            let moment = MontaggioMoment(plan: plan, time: time, k: k, still: calm, holds: model.mappa.holds)
            state.lastTime = time
            state.lastRect = coverRect(scene, plan: plan, moment: moment, calm: calm, fixed: LockSettings.shared.montaggioStill,
                                       z: MappaView.zoom(model.openT, opening: model.open), thumb: thumb(model), size: model.size, k: k)
        }
    }

    /// La foto del lettore, da cui la copertina cresce aprendosi (la stessa di `MappaView`).
    static func thumb(_ model: LockModel) -> CGRect {
        let card = model.layout.card
        return CGRect(x: card.minX + 14, y: card.minY + 14, width: 64, height: 64)
    }

    /// Il cambio brano: ferma quello che se ne va, aspetta il piano del nuovo, poi lo fa entrare e lo annuncia.
    private static func transition(_ model: LockModel) {
        let state = model.montaggio
        let key = model.music?.trackKey ?? ""
        if key != state.track {
            let scenes = [model.mappa.scene, model.mappa.old].compactMap { $0 }
            if !state.track.isEmpty, !key.isEmpty, model.openT > 0, let plan = state.plan, made(state.stamp, for: state.track),
               let rect = state.lastRect, let scene = scenes.first(where: { $0.key == state.track }) {
                state.leaving = MontaggioState.Leaving(plan: plan, time: state.lastTime, rect: rect, scene: scene, inks: state.inks, at: state.tick)
                state.announce = MontaggioState.Announce(key: key)
            } else {
                state.leaving = nil; state.announce = nil
            }
            state.track = key
            state.lastRect = nil
        }
        guard var leaving = state.leaving else { return }
        // il piano del brano nuovo è pronto: la copertina nuova entra, e parte l'annuncio
        if leaving.shownAt == nil, fits(model), let plan = state.plan {
            leaving.shownAt = state.tick
            state.leaving = leaving
            let time = model.mappa.time
            let opening = plan.opening.map { time < $0.fade - 1.2 } ?? false
            // nell'intro ci sono già i titoli di testa; senza la carta (non un'app di musica) niente annuncio
            if opening || plan.card.isEmpty { state.announce = nil }
            else if var announce = state.announce, announce.key == key {
                // l'artista quando la copertina nuova è già quasi tutta lì, il titolo quando la dissolvenza è finita
                let words = plan.card.enumerated().map { i, w -> MontaggioWord in
                    var w = w; w.start = time + (i == plan.card.count - 1 ? 0.85 : 0.5); return w
                }
                announce.cut = MontaggioCut(start: time + 0.5, end: time + 1.4, next: time + 3.0, words: words)
                state.announce = announce
                let stamp = key
                Task.detached(priority: .userInitiated) {
                    let inks = words.map { Montaggio.draw($0) }
                    await MainActor.run {
                        if var a = model.montaggio.announce, a.key == stamp { a.inks = inks; model.montaggio.announce = a }
                    }
                }
            }
        }
        // finita la dissolvenza (o se la copertina nuova non arriva, o la copertina si chiude) il brano vecchio se ne va
        let done = leaving.shownAt.map { state.tick - $0 > 1.0 } ?? (state.tick - leaving.at > 6)
        if done || model.openT == 0 { state.leaving = nil }
        if let cut = state.announce?.cut, model.mappa.time > cut.fade + 0.3 || model.openT == 0 { state.announce = nil }
    }

    /// Il rettangolo della copertina per un'inquadratura, com'è disegnato: sfondo fermo (la copertina intera), oppure
    /// l'inquadratura del piano che si stringe e dà il colpo; aprendo cresce dalla foto del lettore.
    static func coverRect(_ scene: MappaScene, plan: MontaggioPlan?, moment: MontaggioMoment?, calm: Bool, fixed: Bool,
                          z: CGFloat, thumb: CGRect, size: CGSize, k: CGFloat) -> CGRect {
        if fixed { return LockOpenView.mix(thumb, scene.frame(in: size), z) }
        var focus = scene.focus, zoom: CGFloat = 1
        if let plan, let moment, moment.shot < plan.shots.count {
            let shot = plan.shots[moment.shot]
            focus = shot.focus
            let push = calm ? 0 : 0.05 * min(1, moment.sinceShot / moment.shotSpan)
            zoom = shot.zoom * CGFloat(1 + push) * CGFloat(1 + moment.punch)
        }
        // aprendo, la copertina cresce dalla foto verso il campo largo e poi va dolcemente all'inquadratura in corso:
        // un taglio a metà apertura non fa saltare la lastra
        let wide = frame(scene, size: size, focus: scene.focus, zoom: 1, margin: 18 * k)
        let shot = frame(scene, size: size, focus: focus, zoom: zoom, margin: 18 * k)
        let target = z >= 1 ? shot : LockOpenView.mix(wide, shot, CGFloat(LockModel.ease((z - 0.45) / 0.55)))
        return LockOpenView.mix(thumb, target, z)
    }

    /// Prepara il piano del testo che suona, se non c'è già. Fuori dal thread principale.
    static func plan(_ model: LockModel) {
        let state = model.montaggio
        // la scena della copertina sta arrivando: il piano usa i suoi punti di dettaglio, si aspetta lei
        if let music = model.music, model.mappa.scene?.key != music.trackKey {
            // ...tranne quando non arriverà: il brano non ha copertina e la scena di quello prima è già andata via
            // (`Mappa.retire`). Prima qui si aspettava per sempre, e di quel brano non usciva nemmeno una parola.
            guard music.artwork == nil, model.mappa.scene == nil else { return }
        }
        let stamp = stampOf(model)
        guard state.stamp != stamp, state.planning != stamp else { return }
        let input = inputs(model).input
        state.planning = stamp
        Task.detached(priority: .userInitiated) {
            let plan = Montaggio.make(input)
            await MainActor.run {
                let state = model.montaggio
                if state.planning == stamp { state.planning = "" }
                guard Montaggio.stampOf(model) == stamp else { return }
                var plan = plan
                // lo stesso brano (è arrivato il testo, o la copertina grande che lascia stringere di più): le
                // inquadrature già cominciate restano quelle di prima, le nuove valgono da qui in avanti. Così entra
                // subito, senza che l'inquadratura in corso cambi di colpo
                if let old = state.plan, let key = model.mappa.scene?.key, Montaggio.made(state.stamp, for: key) {
                    let time = model.mappa.time
                    plan.shots = old.shots.filter { $0.time <= time } + plan.shots.filter { $0.time > time }
                }
                // se cambia solo la copertina le parole sono le stesse: le scritte già pronte restano
                let onlySharper = state.stamp.replacingOccurrences(of: Montaggio.sharpMark, with: "") == stamp.replacingOccurrences(of: Montaggio.sharpMark, with: "")
                state.set(plan, stamp: stamp, keepInks: onlySharper); Montaggio.shade(model)
            }
        }
    }

    /// Quello che serve per fare il piano, e la sua firma.
    struct Input: @unchecked Sendable {
        var lyrics: Lyrics?
        var size: CGSize
        var title: String
        var scene: MappaScene?
        var tempo: Double
        var pixels: CGFloat
        var artist: String = ""
        /// Suona un'app di musica: solo lì i titoli di testa (nei siti il titolo è spesso «Artista - Titolo»).
        var music = true
        /// Lo stacco al nero del titolo. Spento con «Sfondo fermo» (carpa, 19 novembre 2026: «ci sono alcune parole che
        /// fanno spegnere lo sfondo dietro, è una parola sul nero, togli questa funzione»): lì le parole del titolo
        /// entrano come le altre, sulla copertina.
        var titleCard = true
    }

    /// La firma del piano che serve adesso: il testo, lo schermo, la copertina del brano che suona. Si guarda a ogni
    /// fotogramma, quindi costa poco; il resto si prepara solo quando cambia.
    fileprivate static func stampOf(_ model: LockModel) -> String {
        let scene = model.mappa.scene.flatMap { $0.key == model.music?.trackKey ? $0 : nil }
        let lyrics = model.lyrics != nil && !model.rows.isEmpty
        // prima del brano, la copertina da cui è nata la scena: stesso brano con un'altra copertina vuol dire altri
        // punti di dettaglio, e il piano si rifà. Il brano resta in fondo: `made` guarda la fine della firma.
        // «Sfondo fermo» cambia il piano (niente stacco del titolo): sta in testa, perché la fine è del brano
        return "\(LockSettings.shared.montaggioStill ? "fermo|" : "")\(lyrics ? model.rowsStamp : 0)|\(model.size.width)x\(model.size.height)|\(scene?.token ?? "0")|\(scene.map { $0.key + ($0.sharp ? Self.sharpMark : "") } ?? "-")"
    }

    /// Nella firma del piano, dopo il brano: la copertina è quella grande.
    nonisolated static let sharpMark = "#nitida"

    /// Il piano è fatto per il brano `key`, con la copertina piccola o con quella grande. Si guarda la fine della firma
    /// per intero: la chiave del brano contiene anche lei delle «|».
    fileprivate static func made(_ stamp: String, for key: String) -> Bool {
        stamp.hasSuffix("|" + key) || stamp.hasSuffix("|" + key + sharpMark)
    }

    /// Il piano è di questo brano: al cambio brano, finché quello nuovo non è pronto, la scena non usa il vecchio.
    static func fits(_ model: LockModel) -> Bool {
        // un brano senza copertina, con la scena di quello prima già andata via: il piano è il suo se ha la sua firma
        if model.mappa.scene == nil, let music = model.music, music.artwork == nil {
            return !model.montaggio.stamp.isEmpty && model.montaggio.stamp == stampOf(model)
        }
        return made(model.montaggio.stamp, for: model.mappa.scene?.key ?? "-") && model.mappa.scene?.key == model.music?.trackKey
    }

    fileprivate static func inputs(_ model: LockModel) -> (stamp: String, input: Input) {
        let scene = model.mappa.scene.flatMap { $0.key == model.music?.trackKey ? $0 : nil }
        let lyrics = model.lyrics.flatMap { model.rows.isEmpty ? nil : $0 }
        let title = model.music?.title ?? "", artist = model.music?.artist ?? ""
        let pixels = CGFloat(scene?.pixels ?? 0)
        let stamp = stampOf(model)
        return (stamp, Input(lyrics: lyrics, size: model.size, title: title, scene: scene, tempo: Mappa.tempo(title: title, artist: artist), pixels: pixels, artist: artist,
                             music: LyricsService.isMusicApp(model.music?.app), titleCard: !LockSettings.shared.montaggioStill))
    }

    /// Disegna le scritte del verso in corso e dei due dopo (e del titolo, se sta per arrivare), e lascia andare le altre.
    static func ink(_ model: LockModel) {
        let state = model.montaggio
        guard let plan = state.plan, !plan.cuts.isEmpty || plan.opening != nil else { return }
        if plan.cuts.isEmpty {
            // senza testo restano solo i titoli di testa
            if state.inks[-2] == nil, !state.inking.contains(-2), let words = plan.opening?.words { prepare(words, line: -2, model: model) }
            return
        }
        let time = model.mappa.time
        let current = MontaggioMoment(plan: plan, time: time, k: 1, still: true).line
        var want = Set((max(0, current)...min(plan.cuts.count - 1, max(0, current) + 2)))
        if let title = plan.title, title.line >= current - 1, title.line <= current + 2 { want.insert(-1) }
        if plan.opening != nil, current < 0 { want.insert(-2) }
        state.evict(keeping: want.union(state.inking))
        let stamp = state.stamp
        for line in want where state.inks[line] == nil && !state.inking.contains(line) {
            state.inking.insert(line)
            let words = line == -2 ? plan.opening?.words ?? [] : line < 0 ? plan.title?.words ?? [] : plan.cuts[line].words
            Task.detached(priority: .userInitiated) {
                let inks = words.map { Montaggio.draw($0) }
                await MainActor.run { model.montaggio.store(inks, line: line, stamp: stamp) }
            }
        }
    }

    private static func prepare(_ words: [MontaggioWord], line: Int, model: LockModel) {
        let state = model.montaggio, stamp = state.stamp
        state.inking.insert(line)
        Task.detached(priority: .userInitiated) {
            let inks = words.map { Montaggio.draw($0) }
            await MainActor.run { model.montaggio.store(inks, line: line, stamp: stamp) }
        }
    }

    /// Per gli scatti e le prove con dati di fantasia: piano e scritte subito, senza aspettare. `all` disegna le
    /// scritte di tutti i versi (solo per gli scatti: un brano vero ne ha troppi).
    static func fill(_ model: LockModel, all: Bool = false) {
        guard active else { return }
        let state = model.montaggio
        let (stamp, input) = inputs(model)
        if state.stamp != stamp { state.set(make(input), stamp: stamp) }
        shade(model)
        guard all, let plan = state.plan else { return }
        for (line, cut) in plan.cuts.enumerated() where state.inks[line] == nil { state.store(cut.words.map { draw($0) }, line: line, stamp: stamp) }
        if let title = plan.title, state.inks[-1] == nil { state.store(title.words.map { draw($0) }, line: -1, stamp: stamp) }
        if let opening = plan.opening, state.inks[-2] == nil { state.store(opening.words.map { draw($0) }, line: -2, stamp: stamp) }
    }

    /// Il velo per questo schermo e questo piano: si ridisegna solo se cambiano.
    static func shade(_ model: LockModel) {
        let state = model.montaggio
        guard let plan = state.plan else { return }
        let key = "\(model.size.width)x\(model.size.height)|\(Int(plan.veil * 100))"
        guard key != state.shadeFor else { return }
        state.setShade(veil(size: model.size, level: plan.veil), key: key)
    }

    // MARK: Il piano

    nonisolated static func make(_ input: Input) -> MontaggioPlan {
        let size = input.size
        let k = min(size.width / 1710, size.height / 1107)
        let scene = input.scene
        // le inquadrature di dettaglio: dove la copertina ha più forma. Una copertina piccola non si stringe troppo
        // (si vedrebbero i pixel), ma un poco sì: senza dettagli non c'è montaggio
        let points = scene.map { details($0) } ?? []
        let focus = scene?.focus ?? CGPoint(x: 0.5, y: 0.5)
        let base = scene?.frame(in: size).width ?? size.width
        let cap = input.pixels > 0 ? min(1.75, max(input.pixels < 600 ? 1.12 : 1.35, input.pixels * 2.4 / (base * 2))) : 1.75
        var detailIndex = 0
        func detailShot(at time: Double, _ n: Int) -> MontaggioShot {
            guard !points.isEmpty else { return MontaggioShot(time: time, focus: focus, zoom: min(cap, 1.3)) }
            let p = points[detailIndex % points.count]
            detailIndex += 1
            return MontaggioShot(time: time, focus: p, zoom: min(cap, zooms[n % zooms.count]))
        }
        let wide = { (time: Double) in MontaggioShot(time: time, focus: focus, zoom: 1) }

        let lines = singable((input.lyrics?.lines ?? []).filter { !$0.words.isEmpty })
        let levels = SongMap.levels(lines: lines, title: input.title, wordTimingIsReal: input.lyrics?.wordTimingIsReal ?? false)
        let palette = scene?.palette ?? []
        // le composizioni a giro, da un punto diverso per ogni brano (sempre lo stesso per lo stesso brano)
        var seed = 5381
        for unit in input.title.utf8 { seed = (seed &* 33) &+ Int(unit) }
        let order = Composition.order
        var cuts: [MontaggioCut] = []
        for (i, line) in lines.enumerated() {
            let next = i + 1 < lines.count ? lines[i + 1].start : Double.infinity
            var words = layout(line, levels: levels, size: size, k: k, style: order[(i + abs(seed % order.count)) % order.count])
            let tint = gradient(palette, line: i)
            for w in words.indices where words[w].big { words[w].tint = tint }
            cuts.append(MontaggioCut(start: line.start, end: line.words.last.map(\.end) ?? line.end, next: next, words: words))
        }

        // un taglio a ogni verso; nelle parti senza testo uno ogni due battute
        let period = max(3.2, min(6.5, 60 / max(60, input.tempo) * 8))
        var shots: [MontaggioShot] = [wide(-.infinity)]
        func fillGap(from: Double, to: Double) {
            var t = from + period
            while t < to - max(1.2, period * 0.6) { shots.append(shots.count % 3 == 0 ? wide(t) : detailShot(at: t, shots.count)); t += period }
        }
        if cuts.isEmpty { fillGap(from: 0, to: 60 * 30) }
        for (i, cut) in cuts.enumerated() {
            if i == 0 { fillGap(from: 0, to: cut.start) }
            shots.append(i % 3 == 0 ? wide(cut.start) : detailShot(at: cut.start, i))
            fillGap(from: cut.end + 1.6 - period, to: cut.next.isFinite ? cut.next : cut.end + 60 * 10)
        }

        var title = input.titleCard ? titleCard(lines: lines, title: input.title, size: size, k: k) : nil
        if let line = title?.line { let tint = gradient(palette, line: line); for w in title!.words.indices { title!.words[w].tint = tint } }
        // i titoli di testa, se l'intro lascia tempo (o se il testo non c'è)
        let firstLine = cuts.first?.start ?? 9
        var opening: MontaggioCut?
        // senza testo i titoli di testa no: al centro c'è la copertina grande (`MappaCenterCover`)
        if input.music, !cuts.isEmpty, firstLine >= 5, var card = openingCard(title: input.title, artist: input.artist, size: size, k: k, until: firstLine) {
            let tint = gradient(palette, line: 0)
            for w in card.words.indices where card.words[w].big { card.words[w].tint = tint }
            opening = card
        }
        // il velo: le copertine chiare ne vogliono di più, perché il bianco resti bianco
        let veil = scene.map { min(0.5, max(0.26, $0.shade(in: size) * 0.6)) } ?? 0.32
        // la carta dell'annuncio: le stesse righe dei titoli di testa, con la sfumatura
        var card: [MontaggioWord] = []
        if input.music, var words = openingCard(title: input.title, artist: input.artist, size: size, k: k, until: 30)?.words {
            let tint = gradient(palette, line: 0)
            for w in words.indices where words[w].big { words[w].tint = tint }
            card = words
        }
        return MontaggioPlan(cuts: cuts, shots: shots, title: title, opening: opening, card: card, veil: veil)
    }

    /// Come si impagina un verso. Cambia da un verso all'altro, come in un edit (carpa, 19 novembre 2026: «tutte e 5»,
    /// fra cui le composizioni che cambiano): al centro, a sinistra, a destra, e la parola grande enorme a tutta larghezza.
    enum Composition: CaseIterable {
        case center, left, right, huge
        /// Il giro: mai due uguali di fila, e la parola enorme fra le due di lato.
        nonisolated static let order: [Composition] = [.center, .left, .huge, .right]
    }

    /// I titoli di testa: l'artista piccolo (entra al secondo 0,6) e sotto il titolo grande con la sfumatura (al secondo
    /// 1,2), al centro; restano fino a mezzo secondo prima che si canti.
    nonisolated static func openingCard(title: String, artist: String, size: CGSize, k: CGFloat, until: Double) -> MontaggioCut? {
        var bare = title
        for cut in [" (", " [", " - ", " feat", " ft."] { if let r = bare.range(of: cut, options: .caseInsensitive) { bare = String(bare[..<r.lowerBound]) } }
        bare = bare.trimmingCharacters(in: .whitespaces)
        guard !bare.isEmpty, until > 2.6 else { return nil }
        let small = 44 * k
        let artistText = artist.trimmingCharacters(in: .whitespaces)
        let px = min(210 * k, size.width * 0.8 * 100 / max(1, measure(bare, size: 100)))
        let width = measure(bare, size: px)
        let base = size.height * 0.64
        var words: [MontaggioWord] = []
        if !artistText.isEmpty {
            let aw = measure(artistText, size: small)
            words.append(MontaggioWord(text: artistText, start: 0.6, duration: 0.5, level: 0, big: false, x: size.width / 2 - aw / 2, base: base - px * 0.86 - 22 * k, width: aw, size: small))
        }
        words.append(MontaggioWord(text: bare, start: 1.2, duration: 1, level: 3, big: true, x: size.width / 2 - width / 2, base: base, width: width, size: px))
        // `fade` è il più presto fra la riga dopo e la fine più 1,6: la fine così cade mezzo secondo prima del canto
        return MontaggioCut(start: 0.6, end: until - 2.1, next: until, words: words)
    }

    /// La sfumatura della parola grande di un verso: due colori della copertina, il primo schiarito, il secondo più
    /// carico; da un verso all'altro si sposta lungo i colori, così la canzone non è tutta dello stesso colore. Con una
    /// copertina di un colore solo va dal chiaro al pieno. Senza colori, bianco.
    nonisolated static func gradient(_ palette: [SIMD3<Double>], line: Int) -> [SIMD3<Double>] {
        guard !palette.isEmpty else { return [] }
        let at = (Double(line) * 0.29).truncatingRemainder(dividingBy: 1)
        let other = at + 0.45 > 1 ? at - 0.45 : at + 0.45
        return [MappaColors.sky(palette, at: at, white: 0.55), MappaColors.sky(palette, at: other, white: 0.16)]
    }

    /// Quante parole ha cantato il verso negli ultimi quattro secondi, da 0 a 1: la luce del bordo corre più svelta
    /// dove il brano è fitto.
    static func density(_ model: LockModel, at time: Double) -> Double {
        guard let plan = model.montaggio.plan else { return 0 }
        var count = 0
        for cut in plan.cuts where cut.end > time - 4 && cut.start <= time {
            count += cut.words.reduce(0) { $0 + ($1.start <= time && $1.start > time - 4 ? 1 : 0) }
        }
        return min(1, Double(count) / 12)
    }

    /// Impagina un verso: la parola che conta di più (con la vicina, se conta uguale) grande su una riga sua, le altre
    /// piccole sopra e sotto, tutto centrato sotto l'orologio. Se il verso è lungo, tutto si rimpicciolisce insieme.
    nonisolated static func layout(_ line: TimedLine, levels: [String: Int], size: CGSize, k: CGFloat, style: Composition = .center) -> [MontaggioWord] {
        let words = line.words
        let level = words.map { w -> Int in let key = SongMap.key(w.text); return SongMap.isPlain(key) ? 0 : levels[key] ?? 0 }
        let top = level.max() ?? 0
        var a = top >= 2 ? (level.firstIndex(of: top) ?? 0) : (level.lastIndex(of: top) ?? words.count - 1)
        var b = a
        if top >= 2, b + 1 < words.count, level[b + 1] >= top { b += 1 }
        // se nessuna parola conta più delle altre, la grande è l'ultima che non sia di servizio: quella in rima, che il
        // cantante tiene («call» e non «tryna» in «I've been tryna call»); se sono tutte di servizio, la più lunga
        if top == 0, words.count > 1 {
            if let last = words.indices.last(where: { let key = SongMap.key(words[$0].text); return !key.isEmpty && !SongMap.isPlain(key) }) { a = last; b = last }
            else if let longest = words.indices.max(by: { words[$0].text.count < words[$1].text.count }) { a = longest; b = longest }
        }

        let maxWidth = size.width * (style == .huge ? 0.9 : style == .center ? 0.84 : 0.78), gap = 10 * k
        // la riga grande con le gambe (g, p, q, y, j) vuole più aria sotto, se no toccano la riga piccola dopo
        let bigText = words[a...b].map { shown($0.text, big: true) }.joined(separator: " ")
        let legs: CGFloat = bigText.rangeOfCharacter(from: CharacterSet(charactersIn: "gjpqyçQ")) != nil ? 0.25 : 0.1
        func advance(_ row: (range: Range<Int>, size: CGFloat, big: Bool)) -> CGFloat { row.big ? row.size * (0.74 + legs) : row.size * 1.06 }
        func rows(scale: CGFloat) -> [(range: Range<Int>, size: CGFloat, big: Bool)] {
            var out: [(range: Range<Int>, size: CGFloat, big: Bool)] = []
            let small = (style == .huge ? 56 : 72) * k * scale
            func wrap(_ range: Range<Int>) {
                var start = range.lowerBound
                while start < range.upperBound {
                    var end = start + 1
                    while end < range.upperBound, measure(words[start...end].map { shown($0.text, big: false) }.joined(separator: " "), size: small) <= maxWidth { end += 1 }
                    out.append((start..<end, small, false))
                    start = end
                }
            }
            wrap(0..<a)
            out.append((a..<(b + 1), min((style == .huge ? 340 : 250) * k, maxWidth * 100 / max(1, measure(bigText, size: 100))) * scale, true))
            wrap((b + 1)..<words.count)
            return out
        }
        func height(_ r: [(range: Range<Int>, size: CGFloat, big: Bool)]) -> CGFloat {
            r.reduce(0) { $0 + advance($1) } + gap * CGFloat(max(0, r.count - 1))
        }
        let room = size.height * (0.89 - 0.31)
        var laid = rows(scale: 1)
        let total = height(laid)
        if total > room { laid = rows(scale: room / total) }
        let h = height(laid)
        var y = max(size.height * 0.31, min(size.height * 0.89 - h, size.height * 0.63 - h / 2))
        var out: [MontaggioWord] = []
        for row in laid {
            let base = y + row.size * (row.big ? 0.74 : 0.8)
            let texts = row.range.map { shown(words[$0].text, big: row.big) }
            let space = measure(" ", size: row.size)
            let rowWidth = measure(texts.joined(separator: " "), size: row.size)
            var x: CGFloat
            switch style {
            case .left: x = size.width * 0.08
            case .right: x = size.width * 0.92 - rowWidth
            case .center, .huge: x = size.width / 2 - rowWidth / 2
            }
            for (n, i) in row.range.enumerated() {
                let w = measure(texts[n], size: row.size)
                // ogni parola entra quando viene cantata, mai prima (carpa, 19 novembre 2026: «il testo sempre a tempo»)
                out.append(MontaggioWord(text: texts[n], start: words[i].start, duration: words[i].duration, level: level[i], big: row.big,
                                         x: x, base: base, width: w, size: row.size))
                x += w + space
            }
            y += advance(row) + gap
        }
        return out
    }

    /// Come si scrive una parola: senza parentesi e virgolette attorno; la parola grande anche senza punteggiatura.
    nonisolated static func shown(_ text: String, big: Bool) -> String {
        var edges = CharacterSet(charactersIn: "()[]{}\"“”«»")
        if big { edges.formUnion(.punctuationCharacters) ; edges.remove(charactersIn: "'’") }
        let bare = text.trimmingCharacters(in: edges.union(.whitespaces))
        return bare.isEmpty ? text : bare
    }

    /// Una riga che nel testo ha meno tempo di quanto serve per cantarla (meno di 80 ms a sillaba: è un tempo sbagliato
    /// del testo, come in «Start A Riot» su LRCLIB, nove sillabe in mezzo secondo) non diventa un'inquadratura sua: sarebbe
    /// un taglio lampo con le parole che sbattono tutte insieme, e lo stacco del titolo potrebbe cadere lì. Sta nella
    /// stessa inquadratura della riga dopo, con le parole ognuna al suo tempo. Mai più di 16 parole in un'inquadratura.
    nonisolated static func singable(_ lines: [TimedLine]) -> [TimedLine] {
        var out: [TimedLine] = []
        var previous: TimedLine?
        for line in lines {
            if let before = previous, var last = out.last, last.words.count + line.words.count <= 16 {
                let weight = before.words.reduce(0) { $0 + WordTiming.weight($1.text) }
                if weight >= 4, line.start - before.start < weight * 0.08 {
                    last.words += line.words
                    last.end = max(last.end, line.end)
                    last.closed = line.closed
                    out[out.count - 1] = last
                    previous = line
                    continue
                }
            }
            out.append(line)
            previous = line
        }
        return out
    }

    /// Lo stacco del titolo: il primo verso in cui c'è una parola del titolo, e le parole del titolo di fila da lì (al
    /// massimo tre), ognuna da sola al centro. Se nel testo il titolo non c'è, niente stacco.
    nonisolated static func titleCard(lines: [TimedLine], title: String, size: CGSize, k: CGFloat) -> MontaggioTitle? {
        var bare = title
        for cut in [" (", " [", " - ", " feat", " ft."] { if let r = bare.range(of: cut, options: .caseInsensitive) { bare = String(bare[..<r.lowerBound]) } }
        let named = Set(bare.split(whereSeparator: { $0 == " " || $0 == "-" || $0 == "/" }).map { SongMap.key(String($0)) }.filter { !$0.isEmpty && !SongMap.isPlain($0) })
        guard !named.isEmpty else { return nil }
        for (l, line) in lines.enumerated() {
            guard let first = line.words.firstIndex(where: { named.contains(SongMap.key($0.text)) }) else { continue }
            var last = first
            while last + 1 < line.words.count, last - first < 2, named.contains(SongMap.key(line.words[last + 1].text)) || SongMap.isPlain(SongMap.key(line.words[last + 1].text)) && last + 2 < line.words.count && named.contains(SongMap.key(line.words[last + 2].text)) {
                last += 1
            }
            while last > first, !named.contains(SongMap.key(line.words[last].text)) { last -= 1 }
            let picked = Array(line.words[first...last])
            let end = (picked.last?.end ?? line.start) + 0.3
            guard end - picked[0].start < 4 else { continue }
            let words = picked.map { w -> MontaggioWord in
                let text = shown(w.text, big: true)
                let px = min(260 * k, size.width * 0.62 * 100 / max(1, measure(text, size: 100)))
                let width = measure(text, size: px)
                return MontaggioWord(text: text, start: w.start, duration: w.duration, level: 3, big: true, x: size.width / 2 - width / 2, base: size.height * 0.62, width: width, size: px)
            }
            let until = words.indices.map { $0 + 1 < words.count ? words[$0 + 1].start : end }
            return MontaggioTitle(line: l, start: picked[0].start, end: end, words: words, until: until)
        }
        return nil
    }

    /// I punti della copertina con più forma, dalla griglia della sua luce: dove le inquadrature di dettaglio si posano.
    nonisolated static func details(_ scene: MappaScene) -> [CGPoint] {
        let g = MappaScene.grid
        guard scene.luma.count == g * g else { return [] }
        var energy = [Float](repeating: 0, count: g * g)
        for y in 1..<(g - 1) { for x in 1..<(g - 1) {
            let i = y * g + x
            energy[i] = hypot(scene.luma[i + 1] - scene.luma[i - 1], scene.luma[i + g] - scene.luma[i - g])
        } }
        var soft = [Float](repeating: 0, count: g * g)
        for y in 0..<g { for x in 0..<g {
            var sum: Float = 0, n: Float = 0
            for dy in -3...3 { for dx in -3...3 { let yy = y + dy, xx = x + dx; if yy >= 0, yy < g, xx >= 0, xx < g { sum += energy[yy * g + xx]; n += 1 } } }
            soft[y * g + x] = sum / n
        } }
        var picks: [(x: Int, y: Int)] = []
        for _ in 0..<6 {
            var best: Float = -1, at: (x: Int, y: Int)?
            for y in 6..<(g - 6) { for x in 6..<(g - 6) where soft[y * g + x] > best {
                if picks.contains(where: { hypot(Double($0.x - x), Double($0.y - y)) < Double(g) * 0.2 }) { continue }
                best = soft[y * g + x]; at = (x, y)
            } }
            guard let at, best > 0.004 else { break }
            picks.append(at)
        }
        return picks.map { CGPoint(x: (CGFloat($0.x) + 0.5) / CGFloat(g), y: (CGFloat($0.y) + 0.5) / CGFloat(g)) }
    }

    /// Il rettangolo della copertina per un'inquadratura: riempie lo schermo con un margine per il tremolio, e tiene il
    /// punto scelto al centro quanto può senza scoprire i bordi.
    nonisolated static func frame(_ scene: MappaScene, size: CGSize, focus: CGPoint, zoom: CGFloat, margin: CGFloat) -> CGRect {
        let base = scene.frame(in: size)
        let fit = max((size.width + 2 * margin) / base.width, (size.height + 2 * margin) / base.height, 1)
        let w = base.width * fit * zoom, h = base.height * fit * zoom
        var x = size.width / 2 - focus.x * w, y = size.height * 0.5 - focus.y * h
        x = min(-margin, max(size.width - w + margin, x)); y = min(-margin, max(size.height - h + margin, y))
        return CGRect(x: x, y: y, width: w, height: h)
    }

    // MARK: Le scritte

    /// Quanto è larga una scritta a un corpo, con le lettere strette.
    nonisolated static func measure(_ text: String, size: CGFloat) -> CGFloat {
        let font = CTFontCreateWithName(face as CFString, size, nil)
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: font, .kern: CGFloat(tracking) * size]))
        return CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil)) - CGFloat(tracking) * size
    }

    /// Disegna una parola: piena, bianca calda, con un'ombra morbida che la stacca da qualunque copertina; e, se è la
    /// parola grande, anche il solo contorno per l'eco. A due pixel per punto.
    nonisolated static func draw(_ word: MontaggioWord) -> MontaggioInk {
        let dots: CGFloat = 2, size = word.size
        let font = CTFontCreateWithName(face as CFString, size * dots, nil)
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: word.text, attributes: [.font: font, .kern: CGFloat(tracking) * size * dots, .foregroundColor: ink]))
        var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
        let width = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, &leading))
        let pad = 34 * dots
        let w = Int((width + pad * 2).rounded(.up)), h = Int((ascent + descent + pad * 2).rounded(.up))
        let box = CGRect(x: -pad / dots, y: -(ascent + pad) / dots, width: CGFloat(w) / dots, height: CGFloat(h) / dots)
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        guard w > 0, h > 0, let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                                 bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return MontaggioInk(fill: nil, outline: nil, box: box) }
        // due ombre: una stretta che disegna il bordo delle lettere sulle copertine chiare o piene di scritte, una
        // larga e morbida che le stacca dal fondo
        ctx.setShadow(offset: CGSize(width: 0, height: -1 * dots), blur: 5 * dots, color: CGColor(gray: 0, alpha: 0.55))
        ctx.textPosition = CGPoint(x: pad, y: pad + descent)
        CTLineDraw(line, ctx)
        ctx.setShadow(offset: CGSize(width: 0, height: -2 * dots), blur: 26 * dots, color: CGColor(gray: 0, alpha: 0.4))
        ctx.textPosition = CGPoint(x: pad, y: pad + descent)
        CTLineDraw(line, ctx)
        // le lettere come forme: per la sfumatura dentro e per il contorno dell'eco
        let letters = CGMutablePath()
        if word.big || word.tint.count == 2 {
            for run in (CTLineGetGlyphRuns(line) as? [CTRun]) ?? [] {
                let count = CTRunGetGlyphCount(run)
                var ids = [CGGlyph](repeating: 0, count: count), spots = [CGPoint](repeating: .zero, count: count)
                CTRunGetGlyphs(run, CFRange(location: 0, length: count), &ids)
                CTRunGetPositions(run, CFRange(location: 0, length: count), &spots)
                for i in 0..<count {
                    var move = CGAffineTransform(translationX: pad + spots[i].x, y: pad + descent + spots[i].y)
                    if let path = CTFontCreatePathForGlyph(font, ids[i], &move) { letters.addPath(path) }
                }
            }
        }
        // la sfumatura: sopra il bianco con l'ombra, dentro le lettere, di traverso da in alto a sinistra
        let colors = word.tint.map { CGColor(srgbRed: $0.x, green: $0.y, blue: $0.z, alpha: 1) }
        if colors.count == 2, !letters.isEmpty, let gradient = CGGradient(colorsSpace: space, colors: colors as CFArray, locations: [0, 1]) {
            ctx.saveGState()
            ctx.setShadow(offset: .zero, blur: 0, color: nil)
            ctx.addPath(letters)
            ctx.clip()
            ctx.drawLinearGradient(gradient, start: CGPoint(x: pad, y: pad + descent + ascent), end: CGPoint(x: pad + width, y: pad),
                                   options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
            ctx.restoreGState()
        }
        let fill = ctx.makeImage()
        var outline: CGImage?
        if word.big, let edge = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
            // il contorno: le lettere ripassate con un filo, nel primo colore della sfumatura (o bianco)
            edge.addPath(letters)
            edge.setStrokeColor(colors.first ?? ink)
            edge.setLineWidth(1.6 * dots)
            edge.strokePath()
            outline = edge.makeImage()
        }
        return MontaggioInk(fill: fill, outline: outline, box: box)
    }

    /// Il velo in piccolo (è tutto sfumato): nero uniforme, più scuro in alto (l'orologio) e verso i bordi.
    nonisolated static func veil(size: CGSize, level: Double) -> CGImage? {
        let scale: CGFloat = 0.25
        let w = Int(size.width * scale), h = Int(size.height * scale)
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        guard w > 0, h > 0, let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                                 bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let W = CGFloat(w), H = CGFloat(h)
        ctx.setFillColor(CGColor(gray: 0, alpha: level))
        ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))
        // in alto (il disegno ha la y in su)
        if let top = CGGradient(colorsSpace: space, colors: [CGColor(gray: 0, alpha: 0.55), CGColor(gray: 0, alpha: 0)] as CFArray, locations: [0, 1]) {
            ctx.drawLinearGradient(top, start: CGPoint(x: 0, y: H), end: CGPoint(x: 0, y: H * 0.6), options: [])
        }
        // una fascia appena più scura dietro le parole (dal 31 all'89% dell'altezza), di più sulle copertine chiare
        let band = 0.1 + 0.6 * max(0, level - 0.3)
        if let middle = CGGradient(colorsSpace: space, colors: [CGColor(gray: 0, alpha: 0), CGColor(gray: 0, alpha: band), CGColor(gray: 0, alpha: band), CGColor(gray: 0, alpha: 0)] as CFArray,
                                   locations: [0, 0.3, 0.75, 1]) {
            ctx.drawLinearGradient(middle, start: CGPoint(x: 0, y: H * 0.75), end: CGPoint(x: 0, y: H * 0.04), options: [])
        }
        if let edge = CGGradient(colorsSpace: space, colors: [CGColor(gray: 0, alpha: 0), CGColor(gray: 0, alpha: 0.45)] as CFArray, locations: [0, 1]) {
            let mid = CGPoint(x: W / 2, y: H * 0.45)
            ctx.drawRadialGradient(edge, startCenter: mid, startRadius: H * 0.35, endCenter: mid, endRadius: W * 0.7, options: [.drawsAfterEndLocation])
        }
        return ctx.makeImage()
    }

    /// La piastrella di grana: grigi a caso, da stendere sopra la scena in sovrapposizione.
    nonisolated static func grainTiles() -> [CGImage] {
        let side = 192
        var seed: UInt64 = 0x9E3779B97F4A7C15
        return (0..<1).compactMap { _ in
            var bytes = [UInt8](repeating: 255, count: side * side * 4)
            for i in 0..<(side * side) {
                seed = seed &* 6364136223846793005 &+ 1442695040888963407
                let v = UInt8(truncatingIfNeeded: seed >> 56)
                bytes[i * 4] = v; bytes[i * 4 + 1] = v; bytes[i * 4 + 2] = v
            }
            return CGDataProvider(data: Data(bytes) as CFData).flatMap {
                CGImage(width: side, height: side, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: side * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue), provider: $0, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
            }
        }
    }
}
