import SwiftUI
import CharlandCore

/// L'aspetto dell'isola.
enum IslandLook: String, CaseIterable, Identifiable {
    /// Sopra nero, sotto vetro: il predefinito.
    case blackGlass
    /// Tutto nero come il notch.
    case black
    var id: String { rawValue }
}

/// Le regolazioni che carpa tara a occhio. Stanno in UserDefaults e valgono subito, senza riavvii.
@MainActor @Observable
final class Appearance {
    static let shared = Appearance()

    var look: IslandLook { didSet { save("look", look.rawValue) } }
    /// Quanto vetro resta in basso: 0 = nero pieno, 1 = vetro pulito.
    var glass: Double { didSet { save("glass", glass) } }
    /// Quanta luce ha il filo sul bordo.
    var rim: Double { didSet { save("rim", rim) } }
    /// Molle: sotto 1 più vivaci, sopra 1 più calme.
    var calm: Double { didSet { save("calm", calm) } }
    var haptics: Bool { didSet { save("haptics", haptics) } }
    var dictationStyle: DictationStyle { didSet { save("dictationStyle", dictationStyle.rawValue) } }
    /// «Tutto vetro» (carpa, 18 novembre 2026): nel notch e nei widget del Dock spariscono i colori, segni e mascotte
    /// diventano di vetro. Spento di serie. Chi disegna lo legge da `Glassy`.
    var fullGlass: Bool { didSet { save("fullGlass", fullGlass); DockBar.shared.settingsChanged() } }
    /// Con «Tutto vetro» le copertine degli album restano a colori invece di diventare lastre di vetro.
    var glassKeepsCovers: Bool { didSet { save("glassKeepsCovers", glassKeepsCovers) } }

    private init() {
        let d = UserDefaults.standard
        look = IslandLook(rawValue: d.string(forKey: "look") ?? "") ?? .blackGlass
        glass = d.object(forKey: "glass") as? Double ?? 0.92
        rim = d.object(forKey: "rim") as? Double ?? 1
        calm = d.object(forKey: "calm") as? Double ?? 1
        haptics = d.object(forKey: "haptics") as? Bool ?? true
        dictationStyle = DictationStyle(rawValue: d.string(forKey: "dictationStyle") ?? "") ?? .soffio
        fullGlass = d.bool(forKey: "fullGlass")
        glassKeepsCovers = d.bool(forKey: "glassKeepsCovers")
    }

    private func save(_ key: String, _ value: Any) {
        UserDefaults.standard.set(value, forKey: key)
    }
}

/// Lo stato dello slider di volume o luminosità.
struct SliderState: Equatable {
    var side: SliderSide = .volume
    /// Il livello vero, fra 0 e 1.
    var level: Double = 0.5
    /// Quanto si è spinto oltre il limite (negativo sotto lo zero, positivo sopra il massimo).
    var overshoot: Double = 0
    var muted = false
}

/// Lo stato della voce mentre detti.
struct VoiceState: Equatable {
    var liveText: String = ""
    var handsFree = false
    var elapsed: TimeInterval = 0
    /// Rilasciato il tasto, Charland sta preparando il testo: le parole restano e un riflesso le attraversa.
    var processing = false
    /// Il testo è pronto e parte: le parole si condensano nella goccia che cola.
    var condensing = false
}

/// Quello che le viste dell'isola leggono. Cambiano a ogni fotogramma solo `frame` e `outline`:
/// il resto cambia quando cambia davvero, così a riposo non si ridisegna niente.
@MainActor @Observable
final class IslandModel {
    var frame: IslandFrame
    /// Il bordo dell'isola nello spazio della finestra.
    var outline = Path()
    var metrics: IslandMetrics
    var stageSize: CGSize
    /// x del centro del notch dentro la finestra.
    var originX: CGFloat
    /// `false` a riposo: non si disegna niente, il notch vero basta.
    var isVisible = false

    var contents: [String: ActivityContent] = [:]
    /// L'attività aperta in questo momento: aperta, il tempo piccolo accanto alla fotocamera
    /// sfuma via, perché sotto c'è già quello grande (un tempo solo).
    var expandedID: String?
    var slider = SliderState()
    var voice = VoiceState()
    /// Il volume della voce, ammorbidito, fra 0 e 1. Sta fuori da `voice` perché cambia decine di volte al secondo:
    /// dentro, ogni campione ridisegnava anche il tempo e il testo dal vivo (che rimisura le parole).
    var voiceLevel: Double = 0

    // MARK: Hover
    //
    // L'hover dei pulsanti dell'isola non lo decide SwiftUI: in una finestra che non prende mai la tastiera
    // `onHover` riceve il puntatore solo ogni tanto (misurato il 17 novembre 2026: tessere saltate del tutto,
    // «Timer» acceso 150 punti oltre il suo bordo, «Settings» rimasto acceso sopra tre tessere). Lo decide
    // `PointerTracker`, che vede ogni movimento: ogni pulsante registra il suo riquadro (`IslandHover`) e a ogni
    // movimento vince quello sotto il puntatore.

    /// Il pulsante sotto il puntatore.
    var hovered: Int?
    /// Vero nell'isola sullo schermo; falso nelle anteprime (lì la finestra è normale e `onHover` funziona).
    @ObservationIgnored var pointerDriven = false
    /// Il puntatore nelle coordinate della finestra (origine in alto), `nil` fuori dall'isola.
    @ObservationIgnored var pointer: CGPoint?
    @ObservationIgnored private var hoverRegions: [Int: CGRect] = [:]

    func setHoverRegion(_ id: Int, _ rect: CGRect?) {
        guard hoverRegions[id] != rect else { return }
        hoverRegions[id] = rect
        resolveHover()
    }

    /// Chi è sotto il puntatore adesso. Solo con l'isola aperta: chiudendosi, l'hover si spegne subito.
    func resolveHover() {
        var found: Int?
        if let p = pointer, expandedID != nil {
            // Il più recente vince: mentre una fila cambia, le scelte nuove stanno sopra le tessere che escono.
            for (id, rect) in hoverRegions where rect.contains(p) && id > (found ?? .min) { found = id }
        }
        if hovered != found { hovered = found }
    }

    /// Cosa succede quando si tocca l'isola. Li collega chi possiede l'isola.
    @ObservationIgnored var onTap: () -> Void = {}
    @ObservationIgnored var onPress: (Bool) -> Void = { _ in }
    /// Il punto (in coordinate della finestra, origine in alto) è sopra l'isola?
    @ObservationIgnored var hitTest: (CGPoint) -> Bool = { _ in false }
    /// Un file è stato lasciato nell'isola (`true`) o il trascinamento è finito senza file.
    @ObservationIgnored var onDrop: (Bool) -> Void = { _ in }
    /// Azioni dei contenuti (comandi della musica, approvazioni): prima il nome dell'azione, poi l'attività.
    @ObservationIgnored var onAction: (String, String) -> Void = { _, _ in }

    init(metrics: IslandMetrics, stageSize: CGSize) {
        self.metrics = metrics
        self.stageSize = stageSize
        originX = stageSize.width / 2
        frame = IslandFrame(shape: .resting(metrics), layers: [], drip: nil, openness: 0)
    }
}

/// Il contenuto di un'attività: i dati che le viste mostrano.
enum ActivityContent: Equatable {
    case music(MusicInfo)
    case timer(TimerInfo)
    case agent(AgentInfo)
    case progress(ProgressInfo)
    /// Un'attività arrivata dall'API aperta.
    case api(APIContent)
    /// La casa.
    case home(HomeInfo)
    /// Tutti gli agenti al lavoro, con un tempo solo.
    case agents(AgentsInfo)
}

struct MusicInfo: Equatable {
    var title: String
    var artist: String
    var elapsed: TimeInterval
    var duration: TimeInterval
    var isPlaying: Bool
    /// Due colori per una copertina finta nelle scene dimostrative; `artwork` vince se c'è. Senza niente, una nota.
    var tintA: Color? = nil
    var tintB: Color? = nil
    var artwork: NSImage?
    /// Quando valeva `elapsed`, e a che velocità scorre: il punto giusto si calcola senza aggiornamenti.
    var anchor: Date = .now
    var rate: Double = 0
    /// Il colore della copertina, schiarito: l'onda e la barra lo prendono.
    var tint: Color = .white
    /// Da dove suona: «Spotify», «Safari». E la sua icona, quando un sito non manda la copertina.
    var appName: String?
    var appIcon: NSImage?
    /// La riproduzione vuota, aperta dalla tessera Musica con niente in riproduzione: la nota al posto della copertina
    /// apre l'app della musica scelta, e ▶︎ fa ripartire l'ultimo lettore.
    var idle = false

    /// Il punto del brano adesso.
    func position(at date: Date) -> TimeInterval {
        let t = elapsed + date.timeIntervalSince(anchor) * rate
        return duration > 0 ? min(max(0, t), duration) : max(0, t)
    }

    static func == (a: MusicInfo, b: MusicInfo) -> Bool {
        a.title == b.title && a.artist == b.artist && a.elapsed == b.elapsed && a.duration == b.duration
            && a.isPlaying == b.isPlaying && a.artwork === b.artwork && a.anchor == b.anchor && a.rate == b.rate
            && a.tint == b.tint && a.appName == b.appName && a.appIcon === b.appIcon && a.idle == b.idle
    }
}

struct TimerInfo: Equatable {
    var label: String
    var end: Date
    var total: TimeInterval
}

struct AgentInfo: Equatable {
    enum Phase: Equatable { case working, waiting, done }
    var project: String
    var agent: String
    var phase: Phase
    var command: String = ""
    var explanation: String = ""
}

struct ProgressInfo: Equatable {
    var title: String
    var symbol: String
    var fraction: Double
    var status: String = ""
}
