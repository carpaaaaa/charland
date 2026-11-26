import SwiftUI
import CharlandCore

/// Un agente AI che Charland sa riconoscere.
enum AgentKind: Hashable, Sendable {
    case claude
    /// Codex, cioè ChatGPT per scrivere codice: terminale e app Codex.
    case codex
    /// Gemini: Antigravity e Gemini da terminale.
    case gemini
    /// Un'AI qualsiasi, aggiunta dall'API pubblica: il suo nome e il suo colore.
    case custom(name: String, tint: String?)

    var title: String {
        switch self {
        case .claude: "Claude"
        case .codex: "ChatGPT"
        case .gemini: "Gemini"
        case .custom(let name, _): name
        }
    }

    var palette: AgentMascot.Palette {
        switch self {
        case .claude: .claude
        case .codex: .codex
        case .gemini: .gemini
        case .custom(_, let tint): .custom(ActivityCenter.color(tint ?? "white"))
        }
    }

    var shape: AgentMascot.Shape {
        switch self {
        case .claude: .square
        case .codex: .round
        case .gemini: .antenna
        case .custom: .antenna
        }
    }
}

/// Il progetto su cui lavora un agente (il nome della sua cartella), come piccola etichetta: una cartellina e il nome
/// in un carattere arrotondato, su una capsula appena chiara col bordo sottile.
struct ProjectChip: View {
    let name: String

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "folder.fill")
                .font(.system(size: 8.5, weight: .semibold))
                .foregroundStyle(.white.opacity(0.5))
            Text(name)
                .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.88))
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.horizontal, 8)
        .frame(height: 20)
        .background(Capsule().fill(.white.opacity(0.1)))
        .overlay(Capsule().strokeBorder(.white.opacity(0.08), lineWidth: 0.5))
    }
}

/// Un agente al lavoro in questo momento.
struct AgentSession: Identifiable, Equatable {
    let id: String
    var kind: AgentKind
    var project: String?
    var since: Date
}

/// Quello che un agente chiede (una domanda, un permesso), mostrato dentro l'attività degli agenti: una sola attività
/// per loro, anche quando chiedono (carpa, 19 novembre 2026: «non devono esserci due live activity, deve essere in
/// quella di Claude o dell'agente che chiede il permesso o la domanda»).
struct AgentRequest: Equatable {
    /// La chiave nel centro delle attività: lì tornano le azioni toccate.
    var key: String
    var kind: AgentKind
    /// Il testo, i pulsanti, la spiegazione: disegnati come una richiesta dell'API.
    var content: APIContent
    /// L'altezza dell'isola aperta sulla richiesta.
    var height: Double
}

/// Quello che l'isola mostra degli agenti: tutti insieme, con un tempo solo.
struct AgentsInfo: Equatable {
    /// Gli agenti al lavoro, dal turno più vecchio al più nuovo.
    var sessions: [AgentSession]
    /// Tutti hanno appena finito: la spunta per qualche secondo.
    var finished: AgentKind?
    /// Uno di loro ti chiede qualcosa: l'attività mostra la sua richiesta finché non ha risposta.
    var ask: AgentRequest? = nil

    var lead: AgentSession? { sessions.first }
    /// Di chi è la mascotte accanto alla fotocamera: di chi chiede, se no di chi lavora da più tempo.
    var face: AgentKind? { ask?.kind ?? lead?.kind ?? finished }
}

/// Tutti gli agenti al lavoro, da qualunque fonte arrivino (registri di Claude, Codex, Gemini,
/// oppure l'API pubblica), diventano un'attività sola nell'isola, con un tempo solo:
/// quello del turno in corso da più tempo.
@MainActor
final class AgentHub {
    static let shared = AgentHub()
    static let activityID = "agenti"

    private(set) var sessions: [String: AgentSession] = [:]
    /// Le richieste in attesa di te, nell'ordine in cui sono arrivate: si vede la prima, poi la successiva.
    private var requests: [AgentRequest] = []
    private var shown = false
    private var endTask: Task<Void, Never>?

    /// Sotto questa durata la fine del turno non dà il tocco sul trackpad.
    static let noticeMinimum: TimeInterval = 15

    private init() {}

    private var engine: IslandEngine? { IslandHub.shared.primary?.engine }

    /// Un agente chiede qualcosa (o la sua richiesta è cambiata): entra nell'attività degli agenti.
    func setRequest(_ request: AgentRequest) {
        if let index = requests.firstIndex(where: { $0.key == request.key }) {
            guard requests[index] != request else { return }
            requests[index] = request
        } else {
            requests.append(request)
        }
        publish(finished: nil)
    }

    /// La richiesta ha avuto risposta, o non serve più.
    func clearRequest(_ key: String) {
        guard requests.contains(where: { $0.key == key }) else { return }
        requests.removeAll { $0.key == key }
        publish(finished: nil)
    }

    /// La richiesta che l'attività mostra adesso.
    var requestKey: String? { requests.first?.key }

    func hasRequest(_ key: String) -> Bool { requests.contains { $0.key == key } }

    /// Un agente è al lavoro (o ha cominciato un turno nuovo).
    func working(_ id: String, kind: AgentKind, project: String?, since: Date) {
        if sessions[id] == nil { Self.trace("al lavoro: \(id)") }
        sessions[id] = AgentSession(id: id, kind: kind, project: project, since: since)
        publish(finished: nil)
    }

    /// Un agente ha finito il turno.
    func finished(_ id: String, duration: TimeInterval) {
        if helpers.remove(id) != nil {
            Self.trace("sotto-agente finito: \(id)")
            KeepAwake.shared.agentsChanged()
        }
        guard let session = sessions.removeValue(forKey: id) else { return }
        Self.trace("finito: \(id) dopo \(Int(duration)) s")
        publish(finished: duration >= Self.noticeMinimum ? session.kind : nil)
    }

    /// I sotto-agenti al lavoro (anche quelli lanciati in sottofondo, che continuano dopo la fine del turno della
    /// sessione). Non sono righe dell'isola: contano per sapere quando tutto il lavoro è finito davvero.
    private(set) var helpers: Set<String> = []

    func helperWorking(_ id: String) {
        guard helpers.insert(id).inserted else { return }
        Self.trace("sotto-agente al lavoro: \(id)")
        KeepAwake.shared.agentsChanged()
    }

    /// `CHARLAND_TRACE=1`: chi comincia e chi finisce, per le prove.
    private static let tracing = ProcessInfo.processInfo.environment["CHARLAND_TRACE"] != nil
    private static func trace(_ text: String) {
        guard tracing else { return }
        print("[agenti] \(text)")
        fflush(stdout)
    }

    /// Qualcuno lavora ancora: una sessione nel mezzo di un turno o un sotto-agente.
    var anyoneWorking: Bool { !sessions.isEmpty || !helpers.isEmpty }

    /// Claude lavora: una sua sessione nel mezzo di un turno, o un sotto-agente (arrivano dai ganci di Claude Code).
    var claudeWorking: Bool { sessions.values.contains { $0.kind == .claude } || !helpers.isEmpty }

    func removeAll(where match: (AgentSession) -> Bool) {
        let before = sessions.count
        sessions = sessions.filter { !match($0.value) }
        if sessions.count != before { publish(finished: nil) }
    }

    private func publish(finished: AgentKind?) {
        KeepAwake.shared.agentsChanged()
        guard let engine else { return }
        let ordered = sessions.values.sorted { $0.since < $1.since }
        let ask = requests.first
        if let finished { Haptics.play("done") }
        if ordered.isEmpty, ask == nil {
            guard shown else { return }
            if let finished {
                // Tutti hanno finito: la spunta per un attimo, poi l'attività se ne va.
                engine.update(id: Self.activityID, content: .agents(AgentsInfo(sessions: [], finished: finished)))
                endTask?.cancel()
                endTask = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(4))
                    guard let self, !Task.isCancelled, self.sessions.isEmpty else { return }
                    self.shown = false
                    self.engine?.end(id: Self.activityID)
                }
            } else {
                shown = false
                engine.end(id: Self.activityID)
            }
            return
        }
        endTask?.cancel()
        let info = AgentsInfo(sessions: ordered, finished: nil, ask: ask)
        let rows = Double(min(ordered.count, 4))
        // Nella goccia staccata (quando qualcosa di più urgente sta al centro) va la mascotte da sola, senza tempo.
        // Con una richiesta in attesa l'attività passa davanti alle altre e si apre larga quanto la richiesta.
        let activity = ask.map {
            IslandActivity(id: Self.activityID, priority: 5, leadingWidth: 34, trailingWidth: NeedsYou.trailingWidth,
                           expandedWidth: 372, expandedHeight: $0.height)
        } ?? IslandActivity(id: Self.activityID, priority: 1, leadingWidth: 34, trailingWidth: 46,
                            expandedWidth: 300, expandedHeight: 46 + rows * 26)
        if shown {
            engine.update(id: Self.activityID, content: .agents(info))
            engine.send(.updated(activity))
        } else {
            shown = true
            engine.show(activity, content: .agents(info))
        }
    }
}

/// Gli agenti nell'isola: a sinistra la mascotte di chi lavora da più tempo, a destra un tempo solo.
/// Aperta: il tempo grande e, sotto, ogni agente con il suo progetto (la mascotte resta solo in alto a sinistra).
struct AgentsSlotView: View {
    let info: AgentsInfo
    let slot: ContentSlot
    @Environment(\.islandInteractive) private var interactive

    var body: some View {
        switch slot {
        case .leading:
            if let ask = info.ask {
                // Chiede qualcosa: la mascotte è la sua, e premuta porta alla conversazione dove ha chiesto.
                let mascot = AgentMascot(palette: ask.kind.palette, shape: ask.kind.shape, working: info.lead != nil)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                if interactive {
                    Button { ActivityCenter.shared.perform(action: "jump", on: ask.key) } label: { mascot.contentShape(Rectangle()) }
                        .buttonStyle(TilePress())
                        .help(String(localized: "Mostra dove lavora"))
                } else {
                    mascot
                }
            } else if let lead = info.lead {
                let mascot = AgentMascot(palette: lead.kind.palette, shape: lead.kind.shape, working: true)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                // Con l'isola aperta sugli agenti la mascotte si preme: porta davanti la finestra dove lavora (carpa, 18
                // novembre 2026). Chiusa, il clic resta all'isola.
                if interactive {
                    Button { AgentFocus.bring(lead) } label: { mascot.contentShape(Rectangle()) }
                        .buttonStyle(TilePress())
                        .help(String(localized: "Mostra dove lavora"))
                } else {
                    mascot
                }
            } else if let done = info.finished {
                AgentMascot(palette: done.palette, shape: done.shape, working: false)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        case .minimal:
            // La mascotte da sola nella goccia: il tempo c'è quando l'agente torna al centro o si apre. Intera dentro il
            // cerchio (carpa, 17 novembre: «esce un po' dal cerchio»): a pixel 1,5 era larga 32 punti in una goccia di
            // 26,5 e lo schermo del portatile usciva dal bordo. Il pixel si sceglie sul diametro e il disegno visibile
            // (colonne 2-19 della griglia) si centra.
            GeometryReader { geo in
                let pixel = AgentMascot.pixelFitting(circle: min(geo.size.width, geo.size.height))
                Group {
                    if let ask = info.ask {
                        AgentMascot(palette: ask.kind.palette, shape: ask.kind.shape, working: info.lead != nil, pixel: pixel)
                    } else if let lead = info.lead {
                        AgentMascot(palette: lead.kind.palette, shape: lead.kind.shape, working: true, pixel: pixel)
                    } else if let done = info.finished {
                        AgentMascot(palette: done.palette, shape: done.shape, working: false, pixel: pixel)
                    }
                }
                .offset(x: -pixel)
                .frame(width: geo.size.width, height: geo.size.height)
            }
        case .trailing:
            Group {
                if info.ask != nil {
                    // Ti aspetta: «Needs you» al posto del tempo (prima una mano gialla), l'ala si allarga per lei.
                    NeedsYouLabel().transition(.push(from: .bottom))
                } else if let lead = info.lead {
                    TurnTimer(start: lead.since).transition(.push(from: .bottom))
                } else {
                    Image(systemName: "checkmark").font(.system(size: 12, weight: .bold)).inked(.green)
                        .transition(.push(from: .bottom))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
            .animation(NeedsYou.spring, value: NeedsYou.key(waiting: info.ask != nil, done: info.ask == nil && info.lead == nil))
        case .expanded where info.ask != nil:
            // La richiesta, con i suoi pulsanti: le azioni tornano al centro delle attività, che sa a chi rispondere.
            if let ask = info.ask {
                APISlotView(content: ask.content, slot: .expanded) { action in
                    ActivityCenter.shared.perform(action: action, on: ask.key)
                }
            }
        case .expanded:
            VStack(spacing: 6) {
                if let lead = info.lead {
                    TurnTimer(start: lead.since, size: 30)
                } else {
                    Text("Fatto").font(.system(size: 17, weight: .semibold)).foregroundStyle(.white)
                }
                VStack(spacing: 4) {
                    ForEach(info.sessions.prefix(4)) { session in
                        // niente mascotte nelle righe: c'è già, animata, in alto a sinistra
                        HStack(spacing: 8) {
                            // Il nome dell'AI, il progetto come etichetta (carpa: il nome della cartella le piace, ma
                            // non scritto in fila come testo grigio) e il tempo di quella sessione.
                            Text(session.kind.title).font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                                .fixedSize()
                            if Features.shared.projectNames, let project = session.project { ProjectChip(name: project) }
                            Spacer(minLength: 0)
                            TurnTimer(start: session.since, size: 13).foregroundStyle(.white.opacity(0.6))
                                .fixedSize()
                        }
                        .frame(height: 22)
                    }
                }
                .padding(.horizontal, 18)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .padding(.top, 2)
        default:
            EmptyView()
        }
    }
}
