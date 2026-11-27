import SwiftUI
import CharlandCore

/// I segni sotto l'orologio del blocco: solo segno e valore, quattro posti (carpa, 18 novembre 2026: «widget metti segni»).
enum LockSignKind: String, CaseIterable, Identifiable {
    case weather = "meteo", claude, agenda = "impegno", battery = "batteria", agent = "agente", none = "vuoto"
    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .weather: "Meteo"
        case .claude: "Utilizzo di Claude"
        case .agenda: "Prossimo impegno"
        case .battery: "Batteria"
        case .agent: "Agente al lavoro"
        case .none: "Niente"
        }
    }
}

struct LockSign: Identifiable, Equatable {
    var kind: LockSignKind
    /// Un simbolo di sistema, oppure un anello (pieno da 0 a 1) con dentro un numero o un simbolo.
    var symbol: String?
    var ring: Double?
    var ringText: String?
    var spinning = false
    var text: String
    var id: String { kind.rawValue }
}

/// Le scelte del blocco schermo, a parte l'interruttore generale che sta in `Features`.
@MainActor @Observable
final class LockSettings {
    static let shared = LockSettings()

    var slots: [LockSignKind] { didSet { UserDefaults.standard.set(slots.map(\.rawValue), forKey: "lockSigns") } }
    /// Il lettore al centro quando c'è musica.
    var player: Bool { didSet { UserDefaults.standard.set(player, forKey: "lockPlayer") } }
    /// Il testo delle canzoni: per cercarlo si mandano titolo, artista e durata a lrclib.net e, se lì mancano i tempi delle parole, a lrc.red.
    var lyrics: Bool { didSet { UserDefaults.standard.set(lyrics, forKey: "lockLyrics") } }
    /// I titoli degli impegni sul blocco. Spenti di serie: sul blocco li legge chiunque passi.
    var showsTitles: Bool { didSet { UserDefaults.standard.set(showsTitles, forKey: "lockShowsTitles") } }

    /// Le luci sfocate nei colori della copertina, dietro la copertina aperta.
    var ambience: Bool { didSet { UserDefaults.standard.set(ambience, forKey: "lockAmbience") } }

    /// La copertina si apre già col testo, oppure senza: poi c'è il tasto del testo. Di serie senza
    /// (carpa, 18 novembre 2026: «di default voglio che il testo non si apra subito»).
    var opensWithLyrics: Bool {
        didSet {
            UserDefaults.standard.set(opensWithLyrics, forKey: "lockOpensWithLyrics")
            lyricsChoiceMade = true
        }
    }
    /// «Col testo» o «Senza testo» è stato scelto almeno una volta da chi usa il Mac (la preferenza esiste).
    private(set) var lyricsChoiceMade: Bool

    /// Con la musica che suona, per quanto lo schermo bloccato resta acceso: 0 sempre (di serie), un numero di minuti,
    /// oppure −1 «come macOS» (si spegne dopo pochi secondi, e resta acceso solo a copertina aperta).
    /// carpa, 18 novembre 2026: «appena spegni il computer col tasto rimane attivo se il coperchio è aperto, all'infinito;
    /// è un'opzione, di default rimane attivo quando c'è la musica; nelle impostazioni puoi mettere che dopo un tot si spegne».
    var awakeMinutes: Int { didSet { UserDefaults.standard.set(awakeMinutes, forKey: "lockAwakeMinutes") } }
    static let awakeChoices = [0, 1, 5, 15, 30, 60, -1]

    /// Il tema della copertina aperta.
    var theme: LockTheme { didSet { UserDefaults.standard.set(theme.rawValue, forKey: "lockTheme") } }

    /// Nel Montaggio la copertina resta ferma dentro ogni inquadratura: niente camera a mano, niente spinta in avanti,
    /// niente colpi né tremolii; restano i tagli fra un verso e l'altro e le parole che entrano (carpa, 19 novembre 2026:
    /// «voglio che si possa mettere lo sfondo fermo, non farlo muovere continuamente»). Acceso di serie (carpa, 19
    /// novembre 2026: «abbia lo sfondo fermo di default quando installi l'applicazione»).
    var montaggioStill: Bool { didSet { UserDefaults.standard.set(montaggioStill, forKey: "lockMontaggioStill") } }

    /// Lo spazio, a schermo bloccato con la musica, la mette in pausa e la fa ripartire, in tutti gli stili (carpa,
    /// 19 novembre 2026: «quando premi spazio nella lock screen si blocca la musica, è un'opzione on di default»).
    var spacePlays: Bool { didSet { UserDefaults.standard.set(spacePlays, forKey: "lockSpacePlays") } }

    /// Il bordo luminoso a copertina aperta, in tutti e tre gli stili (carpa, 19 novembre 2026: «voglio il bordo
    /// luminoso anche in quello simple e voglio che sia disattivabile o attivabile per tutte le versioni»). Acceso di serie.
    var edge: Bool { didSet { UserDefaults.standard.set(edge, forKey: "lockEdge") } }

    /// Aprendo la copertina il testo c'è o no. In «Mappa» le parole sono la scena: ci sono, a meno che chi usa
    /// il Mac non abbia scelto «Senza testo» di suo.
    /// È anche quello che mostra il selettore nelle impostazioni: prima il selettore leggeva `opensWithLyrics` e su
    /// un'installazione nuova diceva «Senza testo» mentre Constellation e Dynamic aprivano col testo (e premere
    /// «Senza testo», già scelto, non faceva niente).
    var lyricsAtOpen: Bool {
        theme != .easy && !lyricsChoiceMade ? true : opensWithLyrics
    }

    static let defaultSlots: [LockSignKind] = [.weather, .claude, .agenda, .battery]

    private init() {
        let d = UserDefaults.standard
        let saved = (d.stringArray(forKey: "lockSigns") ?? []).compactMap(LockSignKind.init(rawValue:))
        slots = saved.count == 4 ? saved : Self.defaultSlots
        player = d.object(forKey: "lockPlayer") as? Bool ?? true
        lyrics = d.object(forKey: "lockLyrics") as? Bool ?? true
        showsTitles = d.object(forKey: "lockShowsTitles") as? Bool ?? false
        opensWithLyrics = d.object(forKey: "lockOpensWithLyrics") as? Bool ?? false
        lyricsChoiceMade = d.object(forKey: "lockOpensWithLyrics") != nil
        ambience = d.object(forKey: "lockAmbience") as? Bool ?? true
        // di serie Dynamic (carpa, 19 novembre 2026: «voglio che sia quella di default quando installi l'applicazione»)
        theme = LockTheme.forced ?? d.string(forKey: "lockTheme").flatMap(LockTheme.init(rawValue:)) ?? .montaggio
        awakeMinutes = d.object(forKey: "lockAwakeMinutes") as? Int ?? 0
        montaggioStill = d.object(forKey: "lockMontaggioStill") == nil ? true : d.bool(forKey: "lockMontaggioStill")
        spacePlays = d.object(forKey: "lockSpacePlays") as? Bool ?? true
        // `bool(forKey:)` legge anche «NO» passato da riga di comando (`-lockEdge NO`, per le prove)
        edge = d.object(forKey: "lockEdge") == nil ? true : d.bool(forKey: "lockEdge")
    }
}

/// Lo stato del blocco schermo di Charland, quello che la vista disegna.
@MainActor @Observable
final class LockModel {
    /// Le finestre sono fuori e gli elementi al loro posto. Falso mentre entrano o escono (dal notch, verso il notch).
    var shown = false
    /// Lo schermo si sta sbloccando: tutto sfuma insieme, senza muoversi.
    var leaving = false
    /// Il lettore è fuori (c'è musica). Quando la musica finisce sfuma, poi `music` si svuota.
    var present = false
    /// La copertina aperta: foto grande, testo, sfondo. Si apre premendo la foto del lettore.
    var open = false
    var music: NowPlayingSnapshot?
    /// La copertina sfocata e piccola, per lo sfondo della copertina aperta.
    var backdrop: NSImage?
    var lyrics: Lyrics?
    var rows: [LyricRow] = [] { didSet { rowsStamp &+= 1 } }
    /// Cambia ogni volta che cambiano le righe: alle righe del testo basta guardare questo per sapere se sono le stesse.
    private(set) var rowsStamp = 0
    var signs: [LockSign] = []
    /// Il puntatore è sul lettore: compaiono i tempi della barra.
    var hover = false
    /// Lo schermo è acceso: da spento non si anima niente.
    var awake = true
    /// Il punto scelto trascinando la barra, finché l'app che suona non conferma.
    var seeking: Double? { didSet { seekReleased = nil } }
    /// Quando la barra è stata lasciata (niente mentre la si trascina): da lì la canzone riparte dal punto scelto
    /// mentre l'app che suona conferma. Prima il punto restava fermo fino alla conferma, e testo e costellazione si
    /// fermavano per qualche decimo di secondo prima di saltare avanti.
    @ObservationIgnored var seekReleased: Date?
    /// Quante volte la barra è stata lasciata: chi segue la canzone lo confronta per accorgersi di un salto anche quando
    /// un clic secco sta tutto fra due fotogrammi.
    @ObservationIgnored var seekCount = 0
    var size = CGSize(width: 1710, height: 1107)
    /// Il notch, in punti dall'alto a sinistra dello schermo.
    var notch = CGRect(x: 753, y: 0, width: 204, height: 34)

    /// La scena prende i clic da sola (prova in finestra, scatti): sul blocco vero li prende la finestrella del lettore.
    var direct = false

    // Quanto è compiuto ogni passaggio, da 0 a 1. Li porta avanti un timer nostro (`LockScreen.step`): nelle finestre
    // del blocco l'orologio delle animazioni di SwiftUI non gira bene (18 novembre 2026: animazioni ferme a metà, a scatti).
    /// Charland sul blocco: 0 nascosto, 1 fuori.
    var shownT = 0.0
    /// Il lettore.
    var presentT = 0.0
    /// La copertina aperta: è una dissolvenza fra le due viste, niente voli (carpa: «chill, con un fade, semplice»).
    var openT = 0.0
    /// Lo sblocco: tutto sfuma.
    var leaveT = 0.0
    /// 1 mentre suona, 0 in pausa.
    var playT = 1.0
    var hoverT = 0.0
    /// Il lettore a copertina aperta (Constellation e Dynamic), come una molla senza rimbalzo: parte piano, arriva
    /// morbido, e se il puntatore cambia idea a metà riparte da dov'è con la sua velocità, senza salti. Ci vanno dietro
    /// insieme il lettore che sale, la copertina grande senza testo che si stringe e le parole di Dynamic che salgono.
    /// Prima seguivano `hoverT`, che fa tutto in 0,2 s: la copertina perdeva il 42% della misura in 12 fotogrammi
    /// (carpa, 19 novembre 2026: «curi bene la transizione tra l'album full screen e quando muovo il cursore… rendi il
    /// tutto smooth»).
    var hoverS = 0.0
    @ObservationIgnored var hoverV = 0.0
    /// Quanto è lenta la molla del lettore, in secondi: arriva al 90% in circa due terzi di questo tempo, al 99% poco dopo.
    /// Se ne va con più calma di come arriva.
    nonisolated static let hoverIn = 0.5, hoverOut = 0.62
    /// La dissolvenza dal brano di prima a quello nuovo.
    var trackT = 1.0
    /// La copertina e lo sfondo del brano di prima, finché dura la dissolvenza.
    var oldArtwork: NSImage?
    var oldBackdrop: NSImage?
    /// Le luci dell'atmosfera, una per colore della copertina, e quelle del brano di prima finché dura la dissolvenza.
    var lights: [LockLight] = []
    var oldLights: [LockLight] = []
    /// Quanto nero va sopra lo sfondo mentre suona: di più sulle copertine chiare, così il testo bianco resta bianco.
    var shade = LockModel.baseShade
    var oldShade = LockModel.baseShade
    nonisolated static let baseShade = 0.36

    /// Porta ogni passaggio verso il suo arrivo di `dt` secondi. Torna vero se qualcosa si sta ancora muovendo.
    func advance(_ dt: Double) -> Bool {
        var moving = false
        func go(_ value: inout Double, to target: Double, seconds: Double) {
            guard value != target else { return }
            let step = dt / seconds
            value = target > value ? min(target, value + step) : max(target, value - step)
            moving = true
        }
        go(&shownT, to: shown ? 1 : 0, seconds: 0.4)
        go(&presentT, to: present ? 1 : 0, seconds: 0.35)
        let wantOpen = open && present
        go(&openT, to: wantOpen ? 1 : 0, seconds: LockSettings.shared.theme.openSeconds(wantOpen))
        go(&leaveT, to: leaving ? 1 : 0, seconds: 0.18)
        go(&playT, to: playing ? 1 : 0, seconds: 0.4)
        go(&hoverT, to: hover ? 1 : 0, seconds: 0.2)
        if Mappa.still {
            // con «Riduci movimento» come prima: una dissolvenza breve, niente molla
            let eased = Self.ease(hoverT)
            if hoverS != eased { hoverS = eased; moving = true }
            hoverV = 0
        } else if spring(&hoverS, &hoverV, to: hover ? 1 : 0, response: hover ? Self.hoverIn : Self.hoverOut, dt: dt) {
            moving = true
        }
        go(&trackT, to: 1, seconds: 0.55)
        go(&textT, to: wantsColumn ? 1 : 0, seconds: 0.7)
        go(&lyricsT, to: textShown && hasText ? 1 : 0, seconds: 0.35)
        go(&buttonT, to: hasText || lyricsPending ? 1 : 0, seconds: 0.3)
        if trackT == 1, oldArtwork != nil || oldBackdrop != nil || !oldLights.isEmpty { oldArtwork = nil; oldBackdrop = nil; oldLights = [] }
        return moving
    }

    /// Una molla senza rimbalzo (smorzamento critico) verso `target`, fatta avanzare di `dt` col suo conto esatto: stabile
    /// a ogni passo, anche quando un fotogramma tarda. Torna vero se si sta ancora muovendo.
    func spring(_ value: inout Double, _ velocity: inout Double, to target: Double, response: Double, dt: Double) -> Bool {
        guard value != target || velocity != 0 else { return false }
        let w = 2 * Double.pi / response
        let x = value - target, c = velocity + w * x, e = exp(-w * dt)
        let nx = (x + c * dt) * e, nv = (velocity - w * c * dt) * e
        if abs(nx) < 0.0005, abs(nv) < 0.005 { value = target; velocity = 0 } else { value = target + nx; velocity = nv }
        return true
    }

    /// Un passaggio è in corso (qualcosa non è ancora arrivato): è quando serve il passo pieno dello schermo.
    var inMotion: Bool {
        shownT != (shown ? 1 : 0) || presentT != (present ? 1 : 0) || openT != (open && present ? 1 : 0) || leaveT != (leaving ? 1 : 0)
            || textT != (wantsColumn ? 1 : 0) || lyricsT != (textShown && hasText ? 1 : 0) || trackT != 1 || hoverT != (hover ? 1 : 0)
            || hoverS != (hover ? 1 : 0) || hoverV != 0
    }

    /// Tutto subito al suo arrivo (scatti fuori schermo, schermo spento).
    func settle() { _ = advance(100) }

    /// Parte piano e arriva piano.
    static func ease(_ t: Double) -> Double { let x = min(1, max(0, t)); return x * x * (3 - 2 * x) }

    var hasMusic: Bool { music != nil && LockSettings.shared.player }
    var hasText: Bool { lyrics != nil && !rows.isEmpty }
    /// Il testo è acceso: lo decide l'impostazione quando si apre la copertina, poi il tasto del testo sotto la foto.
    var lyricsOn = false
    /// Il testo di questo brano si sta ancora cercando: nel frattempo la foto resta dov'è.
    var lyricsPending = false
    /// Le righe in colonna sono quelle del brano che suona. Falso al cambio brano, mentre quelle di prima sfumano.
    var textShown = false
    /// La foto sta a sinistra e lascia il posto al testo.
    var wantsColumn: Bool { lyricsOn && (hasText || lyricsPending) }
    /// 0 foto al centro senza testo, 1 foto a sinistra col testo.
    var textT = 0.0
    /// Quanto si vede la colonna del testo.
    var lyricsT = 0.0
    /// Quanto si vede il tasto del testo: c'è solo se il brano un testo ce l'ha.
    var buttonT = 0.0
    var playing: Bool { music?.playing ?? false }
    /// Si anima solo quando serve: fuori, a schermo acceso.
    var isLive: Bool { shown && awake }

    func position(at date: Date) -> Double {
        guard let seeking else { return music?.position(at: date) ?? 0 }
        // trascinando, il punto sta sotto il dito; lasciata la barra, la canzone riparte da lì col suo passo
        guard let released = seekReleased, let music, music.playing else { return seeking }
        let p = seeking + max(0, date.timeIntervalSince(released)) * max(0, music.rate)
        return music.duration > 0 ? min(p, music.duration) : p
    }

    var layout: LockLayout { LockLayout(size: size, notch: notch) }
    let live = LockLive()
    /// Lo stato del tema «Mappa».
    let mappa = MappaState()
    /// Lo stato del tema «Montaggio».
    let montaggio = MontaggioState()
}

/// Le misure del blocco, in punti dall'alto a sinistra. Quelle di macOS sono prese dalla foto del blocco vero
/// (18 novembre 2026, macOS 27.3, schermo 1710 x 1107): cifre dell'orologio fra 148 e 268, avatar a 183 dal fondo.
struct LockLayout {
    var size: CGSize
    var notch: CGRect

    /// Quanto è grande questo schermo rispetto a quello delle misure.
    var k: CGFloat { min(size.width / 1710, size.height / 1107) }
    var midX: CGFloat { size.width / 2 }

    /// Quanto è alto questo schermo rispetto a quello delle misure: l'orologio di macOS cresce con l'altezza.
    var h: CGFloat { size.height / 1107 }

    // Le misure di macOS sono prese sul blocco vero a tre altezze (1080, 1107 e 1440 punti; le due in 16:9 facendo
    // copiare allo schermo del Mac uno schermo finto, 18 novembre 2026):
    // - l'orologio cresce con l'altezza: corpo 14%, linea di base al 23,76%;
    // - la riga della password sta al 6,4% dell'altezza dal fondo; il nome 31 punti sopra, l'avatar 25 punti sopra il
    //   nome, e l'avatar è largo il 5,06% dell'altezza. Quindi la cima dell'avatar sta a (0,1147 x altezza + 56) punti dal fondo.

    /// Quanto crescono i segni: seguono l'orologio, ma senza diventare né minuscoli né enormi.
    var signScale: CGFloat { min(1.6, max(0.85, h)) }

    /// Quanto crescono barra, comandi e tasto del testo a copertina aperta: sugli schermi grandi seguono la foto,
    /// su quelli piccoli restano grandi quanto serve per premerli.
    var controlScale: CGFloat { min(2, max(1, k)) }

    /// La fila dei segni, sotto l'orologio di sistema, alla stessa distanza in proporzione.
    /// Su uno schermo basso si stringe sopra il lettore, che resta al suo posto sopra l'accesso.
    var signsY: CGFloat { min(319 * h, card.minY - 34) }

    /// Dove comincia l'avatar dell'accesso (924 punti su uno schermo alto 1107).
    var avatarTop: CGFloat { size.height * 980 / 1107 - 56 }

    /// Il lettore: una lastra al centro, venti punti sopra l'avatar dell'accesso.
    var card: CGRect { CGRect(x: midX - 220, y: avatarTop - 20 - 180, width: 440, height: 180) }
    static let cardRadius: CGFloat = 30

    /// La foto: nel lettore, grande a sinistra (col testo), grande al centro (senza testo).
    func art(open: Bool, text: Bool) -> CGRect {
        guard open else { return CGRect(x: card.minX + 14, y: card.minY + 14, width: 64, height: 64) }
        if text { let s = 520 * k; return CGRect(x: midX - 705 * k, y: openTop + 18 * k, width: s, height: s) }
        let s = 560 * k
        return CGRect(x: midX - s / 2, y: openTop, width: s, height: s)
    }
    func artRadius(open: Bool) -> CGFloat { open ? 30 * k : 16 }
    /// Da dove comincia la copertina aperta: sotto il nostro orologio.
    var openTop: CGFloat { 300 * size.height / 1107 }

    struct Label { var origin: CGPoint; var scale: CGFloat }
    /// Titolo e artista: `width` è la larghezza della scritta a grandezza naturale, per centrarla quando serve.
    func title(open: Bool, text: Bool, width: CGFloat) -> Label {
        guard open else { return Label(origin: CGPoint(x: card.minX + 92, y: card.minY + 21), scale: 1) }
        let a = art(open: true, text: text), s = 1.6 * k
        return Label(origin: CGPoint(x: text ? a.minX : a.midX - width * s / 2, y: a.maxY + 26 * k), scale: s)
    }
    func artist(open: Bool, text: Bool, width: CGFloat) -> Label {
        guard open else { return Label(origin: CGPoint(x: card.minX + 92, y: card.minY + 44), scale: 1) }
        let a = art(open: true, text: text), s = 1.3 * k
        return Label(origin: CGPoint(x: text ? a.minX : a.midX - width * s / 2, y: a.maxY + 63 * k), scale: s)
    }
    /// Quanto può essere larga una scritta prima di essere troncata, a grandezza naturale.
    func labelWidth(open: Bool, text: Bool, scale: CGFloat) -> CGFloat {
        open ? (art(open: true, text: text).width - (text ? 40 * k : 0)) / scale : 300
    }

    func wave(open: Bool, text: Bool) -> CGPoint {
        guard open else { return CGPoint(x: card.maxX - 14 - 22, y: card.minY + 38) }
        let a = art(open: true, text: text)
        return CGPoint(x: a.maxX - 22, y: a.maxY + 36 * k)
    }
    func scrub(open: Bool, text: Bool) -> CGRect {
        guard open else { return CGRect(x: card.minX + 14, y: card.minY + 94, width: 412, height: 16) }
        let a = art(open: true, text: text)
        return CGRect(x: a.minX, y: a.maxY + 108 * k, width: a.width, height: 16)
    }
    func controls(open: Bool, text: Bool) -> CGRect {
        guard open else { return CGRect(x: card.midX - 94, y: card.minY + 122, width: 188, height: 46) }
        let a = art(open: true, text: text)
        return CGRect(x: a.midX - 94, y: a.maxY + 138 * k, width: 188, height: 46)
    }

    /// La colonna del testo, a destra della foto.
    var lyrics: CGRect { CGRect(x: midX - 55 * k, y: openTop - 4, width: 810 * k, height: 650 * size.height / 1107) }
}

/// Quello che cambia a ogni fotogramma a copertina aperta: il punto della canzone e lo scorrere del testo.
/// Sta a parte dal modello così a ridisegnarsi sessanta volte al secondo è solo chi lo guarda (la colonna del testo, la foto).
@MainActor @Observable
final class LockLive {
    /// Il punto della canzone, in secondi.
    var time = 0.0
    /// Un tempo che scorre sempre, per il respiro della copertina e l'onda.
    var clock = 0.0
    /// La riga cantata (−1 prima di tutto).
    var current = -1
    /// Quanto è «a fuoco» ogni riga, da 0 a 1.
    var focus: [Double] = []
    /// Di quanto è scorsa la colonna.
    var scroll = 0.0
    /// L'altezza misurata di ogni riga.
    var heights: [Int: CGFloat] = [:]
    /// Le righe sono state misurate e la colonna è già andata al suo posto: da lì in poi insegue.
    @ObservationIgnored private var placed = false

    func reset(rows: Int) { focus = Array(repeating: 0, count: rows); scroll = 0; current = -1; heights = [:]; placed = false }

    func top(of index: Int, fallback: CGFloat) -> CGFloat {
        guard index > 0 else { return 0 }
        return (0..<index).reduce(0) { $0 + (heights[$1] ?? fallback) }
    }

    /// Un passo: la riga cantata si mette a fuoco, le altre si spengono, la colonna scorre fin lì. Tutto con un inseguimento morbido.
    func step(_ dt: Double, time: Double, rows: [LyricRow], rowFallback: CGFloat, snap: Bool = false) {
        self.time = time
        if focus.count != rows.count { focus = Array(repeating: 0, count: rows.count) }
        let index = Lyrics.index(of: rows, at: time)
        if index != current { current = index }
        // finché le righe non sono misurate non c'è niente da inseguire: si va dritti al posto, senza scivolare
        let snap = snap || !placed
        if heights.count >= rows.count { placed = true }
        let follow = snap ? 1 : 1 - exp(-dt / 0.13)
        for i in focus.indices {
            let target = i == index ? 1.0 : 0.0
            if abs(focus[i] - target) > 0.002 { focus[i] += (target - focus[i]) * follow } else if focus[i] != target { focus[i] = target }
        }
        let target = Double(top(of: max(index, 0), fallback: rowFallback))
        let glide = snap ? 1 : 1 - exp(-dt / 0.16)
        if abs(scroll - target) > 0.3 { scroll += (target - scroll) * glide } else if scroll != target { scroll = target }
    }
}
