import SwiftUI
import AppKit

/// Quello che si può mettere accanto al Dock (carpa, 17 novembre 2026: «aggiungi sistema e prossimo impegno, sempre
/// customizzabile in settings cosa mettere nel Dock, e qualcosa di originale»). Ogni modulo è un vassoio di vetro a
/// capsula, alto come il Dock, con dentro uno o più anelli; passandoci sopra si apre il suo cassetto.
enum DockModuleID: String, CaseIterable, Identifiable, Sendable, Codable {
    case usage, agenda, system, dictation

    var id: String { rawValue }

    var title: String {
        switch self {
        case .usage: String(localized: "Agenti AI")
        case .agenda: String(localized: "Prossimo impegno")
        case .system: String(localized: "Sistema")
        case .dictation: String(localized: "Dettatura")
        }
    }

    var symbol: String {
        switch self {
        case .usage: "gauge.with.needle"
        case .agenda: "calendar"
        case .system: "cpu"
        case .dictation: "waveform"
        }
    }

    /// Il colore del suo quadratino nelle impostazioni, come le sezioni di Impostazioni di Sistema.
    var tint: Color {
        switch self {
        case .usage: .purple
        case .agenda: .red
        case .system: .gray
        case .dictation: .orange
        }
    }

    var detail: String {
        switch self {
        case .usage: String(localized: "Quanto hai usato Claude e ChatGPT, e quando riparte.")
        case .agenda: String(localized: "Il prossimo evento del Calendario, col conto alla rovescia.")
        case .system: String(localized: "Processore, memoria e disco, con l'andamento degli ultimi minuti.")
        case .dictation: String(localized: "Detta con un clic, le parole di oggi e le ultime dettature.")
        }
    }
}

/// Un posto nel vassoio: un anello e, accanto, un numero o un testo che si apre e si chiude.
struct DockCell: Equatable, Identifiable {
    var id: String
    /// Quanto è largo il testo accanto all'anello (zero: niente testo).
    var label: CGFloat
    /// Quanto è aperto il testo: 0 solo l'anello, 1 anello e testo.
    var open: Double
}

/// Dove sta ogni cosa in un vassoio. Le stesse misure servono al disegno, alla forma del vetro e a capire su quale
/// anello sta il puntatore.
struct DockRowLayout: Equatable {
    var cells: [DockCell]
    var height: CGFloat

    static let ringGap: CGFloat = 8
    static let labelGap: CGFloat = 7
    /// Aria dopo il testo, prima dell'anello seguente o del capo tondo del vassoio.
    static let labelTail: CGFloat = 6

    var pad: CGFloat { (height * 0.17).rounded() }
    var ring: CGFloat { height - 2 * pad }
    var fontSize: CGFloat { max(11, (height * 0.27).rounded()) }
    /// A capsula: col raggio pari a metà altezza, un anello tondo ai capi è concentrico con il bordo (il raggio
    /// dell'anello più il margine fa proprio metà altezza). Un rettangolo tondo non lo sarebbe.
    var corner: CGFloat { height / 2 }

    func cellWidth(_ cell: DockCell) -> CGFloat {
        cell.label > 0 ? ring + CGFloat(cell.open) * (Self.labelGap + cell.label + Self.labelTail) : ring
    }

    var width: CGFloat {
        guard !cells.isEmpty else { return 0 }
        return 2 * pad + cells.reduce(0) { $0 + cellWidth($1) } + CGFloat(cells.count - 1) * Self.ringGap
    }

    /// Il bordo sinistro dell'anello di una cella.
    func x(of id: String) -> CGFloat {
        var x = pad
        for cell in cells {
            if cell.id == id { return x }
            x += cellWidth(cell) + Self.ringGap
        }
        return x
    }

    func open(_ id: String) -> Double { cells.first { $0.id == id }?.open ?? 0 }

    /// La zona che risponde al puntatore per una cella: l'anello, il suo testo e mezzo spazio ai lati.
    func hitFrame(_ id: String) -> CGRect {
        guard let cell = cells.first(where: { $0.id == id }) else { return .zero }
        return CGRect(x: x(of: id) - Self.ringGap / 2, y: 0, width: cellWidth(cell) + Self.ringGap, height: height)
    }

    func cell(at x: CGFloat) -> String? {
        cells.first { hitFrame($0.id).minX <= x && x < hitFrame($0.id).maxX }?.id
    }
}

/// Le misure dei testi, ricordate: il vassoio le chiede a ogni fotogramma mentre si muove.
@MainActor
enum DockText {
    private static var widths: [String: CGFloat] = [:]

    /// Il carattere dei numeri del vassoio (arrotondato, cifre larghe uguali) o, con `rounded` falso, quello di sistema
    /// dei titoli.
    static func font(size: CGFloat, weight: NSFont.Weight = .semibold, rounded: Bool = true) -> NSFont {
        guard rounded else { return NSFont.systemFont(ofSize: size, weight: weight) }
        let base = NSFont.monospacedDigitSystemFont(ofSize: size, weight: weight)
        guard let design = base.fontDescriptor.withDesign(.rounded) else { return base }
        return NSFont(descriptor: design, size: size) ?? base
    }

    static func width(_ text: String, size: CGFloat, weight: NSFont.Weight = .semibold, rounded: Bool = true) -> CGFloat {
        guard !text.isEmpty else { return 0 }
        let key = "\(size)|\(weight.rawValue)|\(rounded)|\(text)"
        if let known = widths[key] { return known }
        let width = ((text as NSString).size(withAttributes: [.font: font(size: size, weight: weight, rounded: rounded)]).width).rounded(.up)
        if widths.count > 400 { widths.removeAll() }
        widths[key] = width
        return width
    }
}

enum UsageTone {
    /// Bianco finché c'è margine; ambra dall'80%, rosso dal 95%: gli stessi punti in cui avvisa l'isola. Sul numero
    /// arrotondato, quello che si legge: «80%» non resta bianco perché in realtà è 79,6.
    @MainActor static func color(used raw: Double) -> Color {
        // Con «Tutto vetro» niente ambra né rosso: resta il numero a dire quanto manca.
        if Glassy.on { return .white }
        let percent = raw.rounded()
        if percent >= 95 { return red }
        if percent >= 80 { return amber }
        return .white
    }

    static let amber = Color(red: 1.0, green: 0.74, blue: 0.30)
    static let red = Color(red: 1.0, green: 0.42, blue: 0.36)
    /// Gli stessi, che con «Tutto vetro» diventano bianchi.
    @MainActor static var amberInk: Color { Glassy.flat(amber) }
    @MainActor static var redInk: Color { Glassy.flat(red) }
}

// MARK: - Il modulo

/// Quello che il Dock chiede a ogni modulo. I dati stanno nei loro depositi (`UsageStore`, `SystemStats`,
/// `AgendaStore`, `DictationStats`); il modulo dice al vassoio quanto è largo, cosa fa un clic e quando rinfrescarsi.
@MainActor
protocol DockModule: AnyObject {
    var id: DockModuleID { get }
    /// Niente da mostrare (nessun agente sul Mac, nessuna misura scelta): il vassoio non esce.
    var isEmpty: Bool { get }
    /// Le celle a riposo, con le larghezze dei testi e quale è aperto.
    func cells(height: CGFloat, now: Date) -> [DockCell]
    /// La cella che il cassetto mostra quando si apre.
    var defaultFocus: String? { get }
    /// L'altezza del cassetto mostrando `focus`.
    func drawerHeight(focus: String?, now: Date) -> CGFloat
    /// Acceso nelle impostazioni (e il Dock acceso): comincia a raccogliere i suoi dati. Spento, si ferma tutto.
    func setActive(_ on: Bool)
    /// Il Dock è salito (`look` falso) o il cassetto si apre (`look` vero): numeri freschi, se servono.
    func refresh(look: Bool)
    func tap(_ cell: String?)
    /// La rotella sopra il modulo passa all'elemento seguente. `false` se non c'è niente da scorrere.
    func scroll(_ step: Int) -> Bool
    /// Il testo dipende dall'ora (il conto alla rovescia): va ridisegnato ogni minuto mentre si vede.
    var needsClock: Bool { get }
}

extension DockModule {
    func scroll(_ step: Int) -> Bool { false }
    var needsClock: Bool { false }
}

// MARK: - Pezzi comuni

/// Un anello tondo con dentro un segno: quanto è pieno parte da mezzogiorno e gira in senso orario.
struct DockRing<Content: View>: View {
    /// Quanto disegnare, da 0 a 1; `nil` se non c'è niente da misurare (resta solo la traccia).
    let fraction: Double?
    var color: Color = .white
    let size: CGFloat
    var hovered = false
    /// Le misure che cambiano di continuo (il processore ogni pochi secondi) non scorrono: ogni scorrimento sono decine
    /// di fotogrammi ridisegnati, e col Dock sempre visibile diventavano un consumo continuo.
    var animated = true
    @ViewBuilder var content: () -> Content

    var body: some View {
        let line = max(2.5, (size * 0.085).rounded())
        ZStack {
            Circle().stroke(.white.opacity(hovered ? 0.26 : 0.16), lineWidth: line)
            if let fraction, fraction > 0.004 {
                Circle()
                    .trim(from: 0, to: max(0.012, min(1, fraction)))
                    .stroke(Glassy.ink(color), style: StrokeStyle(lineWidth: line, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(animated ? .spring(response: 0.7, dampingFraction: 0.86) : nil, value: fraction)
            }
            content()
        }
        .padding(line / 2)
        .frame(width: size, height: size)
        .scaleEffect(hovered ? 1.07 : 1)
        .animation(.spring(response: 0.26, dampingFraction: 0.7), value: hovered)
    }
}

/// Il testo accanto a un anello: esce da dietro l'anello mentre il vassoio gli fa posto.
struct DockLabel: View {
    let text: String
    let layout: DockRowLayout
    let cell: String
    var color: Color = .white
    /// Come per l'anello: i numeri che cambiano di continuo si sostituiscono e basta.
    var animated = true

    var body: some View {
        let open = layout.open(cell)
        Text(verbatim: text)
            .font(.system(size: layout.fontSize, weight: .semibold, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(Glassy.ink(color))
            .contentTransition(animated ? .numericText() : .identity)
            .animation(animated ? .snappy(duration: 0.35) : nil, value: text)
            .lineLimit(1)
            .fixedSize()
            .frame(height: layout.height)
            .opacity(DockBarMetrics.smooth(0.3, 0.95, open))
            .blur(radius: 3 * (1 - DockBarMetrics.smooth(0.2, 0.9, open)))
            .offset(x: layout.x(of: cell) + layout.ring + DockRowLayout.labelGap - 8 * CGFloat(1 - open))
    }
}

/// Le misure comuni dei cassetti: ogni riga ha un'altezza fissa, così la forma del vetro sa quanto crescere prima che
/// i contenuti compaiano.
enum DockDrawerMetrics {
    static let width: CGFloat = 292
    /// Il margine, il raggio del cassetto (`DockBarMetrics.drawerCorner`) e quello dei pulsanti in fondo vanno insieme:
    /// 26 meno 14 fa 12, così il pulsante è concentrico con gli angoli bassi del cassetto.
    static let pad: CGFloat = 14
    static let buttonCorner: CGFloat = 12
    static let header: CGFloat = 24
    static let footer: CGFloat = 30
    static let gap: CGFloat = 14
    static let figure: CGFloat = 36
}

/// La testata di un cassetto: il segno, il titolo, un'etichetta facoltativa e, se sta leggendo, l'anello che gira.
struct DrawerHeader<Mark: View>: View {
    let title: String
    var chip: String?
    var busy = false
    @ViewBuilder var mark: () -> Mark

    var body: some View {
        HStack(spacing: 8) {
            mark()
            Text(verbatim: title).font(.system(size: 16, weight: .semibold)).lineLimit(1)
            if let chip {
                Text(verbatim: chip)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.7))
                    .padding(.horizontal, 7)
                    .frame(height: 18)
                    .background(Capsule().fill(.white.opacity(0.1)))
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            if busy {
                SpinArc().frame(width: 14, height: 14).opacity(0.7).transition(.opacity)
            }
        }
        .frame(height: DockDrawerMetrics.header)
        .animation(.easeOut(duration: 0.2), value: busy)
    }
}

/// Il pulsante in fondo a un cassetto, concentrico con i suoi angoli.
struct DrawerButton: View {
    let title: String
    var prominent = false
    let action: () -> Void

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: DockDrawerMetrics.buttonCorner, style: .continuous)
        Button(action: action) {
            Text(verbatim: title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(prominent ? Color.black : .white)
                .frame(maxWidth: .infinity, minHeight: DockDrawerMetrics.footer, maxHeight: DockDrawerMetrics.footer)
                .background(shape.fill(prominent ? Color.white : Color.white.opacity(0.1)))
                .contentShape(shape)
        }
        .buttonStyle(TilePress())
    }
}

/// Un numero con il suo nome sopra.
struct DrawerFigure: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(verbatim: title).font(.system(size: 11, weight: .semibold)).foregroundStyle(.white.opacity(0.55)).lineLimit(1)
            Text(verbatim: value)
                .font(.system(size: 16, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
                .contentTransition(.numericText())
                .animation(.snappy(duration: 0.3), value: value)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: DockDrawerMetrics.figure)
    }
}

/// Una barra sottile, piena quanto `fraction`, con una tacca facoltativa.
struct DrawerBar: View {
    let fraction: Double
    var color: Color = .white
    var tick: Double?

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.12)).frame(height: 6)
                if fraction >= 0.005 {
                    Capsule().fill(Glassy.ink(color))
                        .frame(width: max(6, w * min(1, fraction)), height: 6)
                        .animation(.spring(response: 0.6, dampingFraction: 0.86), value: fraction)
                }
                if let tick, tick > 0.01, tick < 0.99 {
                    Capsule().fill(.white)
                        .frame(width: 2, height: 10)
                        .overlay(Capsule().stroke(.black.opacity(0.35), lineWidth: 1))
                        .offset(x: min(w - 2, max(0, w * tick - 1)))
                }
            }
            .frame(height: 10)
        }
        .frame(height: 10)
    }
}

// MARK: - Vassoio e cassetto, per modulo

/// Il contenuto di un vassoio, secondo il modulo.
struct DockModulePlatter: View {
    let id: DockModuleID
    let layout: DockRowLayout
    let hovered: String?
    let now: Date

    var body: some View {
        Group {
            switch id {
            case .usage: UsagePlatter(layout: layout, hovered: hovered)
            case .agenda: AgendaPlatter(layout: layout, hovered: hovered, now: now)
            case .system: SystemPlatter(layout: layout, hovered: hovered)
            case .dictation: DictationPlatter(layout: layout, hovered: hovered)
            }
        }
        .frame(width: layout.width, height: layout.height, alignment: .topLeading)
        .foregroundStyle(.white)
    }
}

/// Il contenuto di un cassetto, secondo il modulo.
struct DockModuleDrawer: View {
    let id: DockModuleID
    let focus: String?
    let now: Date

    var body: some View {
        Group {
            switch id {
            case .usage: UsageDrawer(focus: focus, now: now)
            case .agenda: AgendaDrawer(now: now)
            case .system: SystemDrawer()
            case .dictation: DictationDrawer()
            }
        }
        .padding(DockDrawerMetrics.pad)
        .frame(width: DockDrawerMetrics.width, alignment: .topLeading)
        .foregroundStyle(.white)
    }
}

/// Apre un'app o un link dal Dock e lo porta davanti.
///
/// I pannelli del Dock non attivano Charland (non prendono la tastiera: chi sta scrivendo resta dov'era). Ma da macOS 14
/// l'attivazione è cooperativa: un'app non attiva che ne apre un'altra la lascia dietro le finestre di prima, e «Apri
/// Claude» apriva Claude senza farlo vedere. Al clic Charland si attiva un istante e cede il posto all'app che apre;
/// un'app già aperta riporta su anche le sue finestre.
@MainActor
enum DockLaunch {
    static func open(_ url: URL) {
        let app: URL? = url.isFileURL ? url : NSWorkspace.shared.urlForApplication(toOpen: url)
        NSApp.activate()
        if let bundle = app.flatMap({ Bundle(url: $0)?.bundleIdentifier }) {
            NSApp.yieldActivation(toApplicationWithBundleIdentifier: bundle)
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        if url.isFileURL {
            NSWorkspace.shared.openApplication(at: url, configuration: configuration) { running, _ in
                guard let pid = running?.processIdentifier else { return }
                DispatchQueue.main.async {
                    // Nascosta o con le finestre ridotte nel Dock: la sua finestra torna su (`AppFront`).
                    MainActor.assumeIsolated {
                        guard let running = NSRunningApplication(processIdentifier: pid) else { return }
                        AppFront.restoreWindows(of: running)
                    }
                }
            }
        } else {
            NSWorkspace.shared.open(url, configuration: configuration) { _, _ in }
        }
    }

    /// Un'app per identificativo; se non c'è, `fallback` (per esempio il suo sito).
    static func open(bundle: String, fallback: URL? = nil) {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) {
            open(url)
        } else if let fallback {
            open(fallback)
        }
    }
}
