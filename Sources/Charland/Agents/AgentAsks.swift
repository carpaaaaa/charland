import AppKit
import CharlandCore
import CharlandKit

/// Le domande degli agenti nell'isola (carpa, 19 novembre 2026: «quando un agente chiede nella sua chat una domanda o
/// una conferma esca direttamente nell'isola… deve funzionare sempre»).
///
/// Due fonti, tutte e due senza configurare niente:
/// - il registro della sessione (`AgentLogWatcher`): la scheda di domanda, il piano da approvare, la domanda con cui
///   finisce un turno (il riquadro di fine turno dell'app di Claude o l'ultima frase);
/// - lo stato che Claude scrive di sé (`ClaudeSessionsWatcher`): «aspetta un permesso», «aspetta una risposta».
///
/// Da qui la domanda si vede e un clic porta alla sessione che l'ha fatta. Con i ganci collegati la stessa richiesta
/// arriva anche dal gancio dei permessi, e allora ci si risponde dall'isola: quella vince su questa, che fa da rete.
@MainActor
final class AgentAsks {
    static let shared = AgentAsks()

    /// Quello che si vede nell'isola per una domanda.
    private struct Shown: Equatable {
        var kind: AgentAsk.Kind
        var text: String
        /// Le risposte del riquadro di fine turno che l'isola può premere nella finestra di Claude: diventano i suoi
        /// pulsanti. Vuoto: un pulsante solo, «Rispondi», che apre la conversazione.
        var options: [String] = []

        /// La stessa domanda, con o senza pulsanti. I pulsanti dipendono da cose che possono arrivare dopo (lo stato
        /// della sessione con il suo indirizzo, il permesso di Accessibilità) e non la rendono un'altra domanda.
        /// Il 19 novembre 2026 l'app di Claude ha rilanciato il processo di una sessione ferma: Charland ha letto il
        /// registro prima dello stato, ha segnato la domanda come già vista senza pulsanti, e un secondo dopo, coi
        /// pulsanti, l'ha presa per nuova e l'ha rimessa nell'isola (carpa: «rimane lì e continua a ripetermela»).
        func same(as other: Shown?) -> Bool {
            guard let other else { return false }
            return kind == other.kind && text == other.text
        }
    }

    /// Come si presenta nell'isola quello che la sessione chiede. Le risposte del riquadro di fine turno si offrono
    /// come pulsanti solo se Charland le può premere davvero: sessione dell'app di Claude (ha un indirizzo) e permesso
    /// di Accessibilità.
    private func look(_ ask: AgentAsk, in session: Session) -> Shown {
        var look = Shown(kind: ask.kind, text: Self.text(for: ask))
        if ask.kind == .followUp, !ask.options.isEmpty, session.record?.desktopLink != nil, ClaudeWindow.canPress {
            look.options = Array(ask.options.prefix(ActivitySchema.maxOptions))
        }
        return look
    }

    private struct Session {
        var kind: AgentKind = .claude
        var project: String?
        var logPath: String?
        var logAsk: AgentAsk?
        /// Il comando dell'unico strumento in corso (con più strumenti insieme non si sa quale aspetta).
        var openTool: String?
        var record: ClaudeSessionRecord?
        /// Nell'isola adesso, messa da qui.
        var shown: Shown?
        /// Già vista: aperta, ignorata o scaduta. Non torna finché non cambia.
        var handled: Shown?
        /// Tolta dall'isola solo per un momento (la sessione ha ripreso a lavorare per un messaggio automatico, e il
        /// riquadro di fine turno è ancora lì): quando torna ferma, la domanda rientra senza riaprire l'isola.
        var paused: Shown?
        var pending: Task<Void, Never>?
        var expiry: Task<Void, Never>?
        var peek: Task<Void, Never>?
    }

    private var sessions: [String: Session] = [:]
    /// Claude Code scrive lo stato delle sue sessioni (lo fanno le versioni di adesso): allora una scheda di domanda
    /// vale solo finché la sessione dice che aspetta.
    private var claudeWritesState = false

    /// Una domanda di fine turno più vecchia di così, alla prima lettura, non si mostra (Charland appena riaccesa).
    static let freshFollowUp: TimeInterval = 120
    /// Quanto resta nell'isola una domanda di fine turno senza risposta.
    static let followUpLife: TimeInterval = 10 * 60
    /// Dopo quanto l'isola aperta su una domanda di fine turno si richiude da sola (resta la mano accanto alla fotocamera).
    static let peekSeconds: TimeInterval = 9
    /// Un attimo prima di mostrare un permesso o una scheda: se i ganci sono collegati, arriva la richiesta a cui si
    /// può rispondere, e l'isola non cambia contenuto sotto gli occhi.
    static let grace: TimeInterval = 0.45
    /// Lo stesso attimo per la domanda di fine turno, a sessione ormai ferma.
    static let followUpGrace: TimeInterval = 0.45

    private init() {}

    private static let tracing = ProcessInfo.processInfo.environment["CHARLAND_TRACE"] != nil
    private static func trace(_ text: @autoclosure () -> String) {
        guard tracing else { return }
        print("\(ActivityCenter.clock()) [domande] \(text())")
        fflush(stdout)
    }

    // MARK: Le fonti

    /// Dal registro: cosa chiede adesso la sessione (o niente), e quale strumento è in corso.
    func logChanged(sessionID: String, kind: AgentKind, project: String?, logPath: String, ask: AgentAsk?, openTool: String?) {
        var session = sessions[sessionID] ?? Session()
        session.kind = kind
        session.project = project ?? session.project
        session.logPath = logPath
        // Una domanda di fine turno vecchia, vista per la prima volta: è storia, non si mostra.
        if let ask, ask.kind == .followUp, session.logAsk != ask, let at = ask.at, Date().timeIntervalSince(at) > Self.freshFollowUp {
            session.handled = look(ask, in: session)
        }
        session.logAsk = ask
        session.openTool = openTool
        sessions[sessionID] = session
        evaluate(sessionID)
    }

    /// I registri non si leggono più (funzione spenta): via le loro domande.
    func logsStopped(kind: AgentKind) {
        for (id, session) in sessions where session.kind == kind && session.logPath != nil {
            sessions[id]?.logAsk = nil
            sessions[id]?.openTool = nil
            evaluate(id)
        }
    }

    /// Dallo stato che Claude scrive di sé.
    func sessionChanged(_ record: ClaudeSessionRecord) {
        claudeWritesState = true
        var session = sessions[record.sessionID] ?? Session()
        session.record = record
        if session.project == nil, let cwd = record.cwd { session.project = (cwd as NSString).lastPathComponent }
        sessions[record.sessionID] = session
        Self.trace("stato di \(record.sessionID): \(record.status ?? "-") \(record.waitingFor ?? "")")
        // Ha smesso di aspettare, o è ripartita: se nell'isola c'è la richiesta arrivata dal gancio, hai risposto nell'app.
        ActivityCenter.shared.agentAnsweredElsewhere(sessionID: record.sessionID, record: record)
        evaluate(record.sessionID)
    }

    func sessionGone(_ sessionID: String) {
        guard sessions[sessionID] != nil else { return }
        Self.trace("sessione chiusa: \(sessionID)")
        sessions[sessionID]?.record = nil
        // Senza processo non c'è più nessuno che aspetta.
        sessions[sessionID]?.logAsk = nil
        ActivityCenter.shared.agentAnsweredElsewhere(sessionID: sessionID, record: nil)
        evaluate(sessionID)
        if sessions[sessionID]?.shown == nil { sessions[sessionID] = nil }
    }

    /// La sessione di Claude con questo identificativo, se è accesa.
    func record(for sessionID: String?) -> ClaudeSessionRecord? {
        sessionID.flatMap { sessions[$0]?.record }
    }

    /// L'interruttore «Domande e permessi nell'isola» è cambiato.
    func settingsChanged() {
        for id in Array(sessions.keys) { evaluate(id) }
    }

    // MARK: Dall'isola

    /// Dal gancio è arrivata la richiesta a cui si può rispondere: prende il posto della nostra.
    func hookPosted(sessionID: String) {
        sessions[sessionID]?.pending?.cancel()
        sessions[sessionID]?.pending = nil
        sessions[sessionID]?.peek?.cancel()
        sessions[sessionID]?.expiry?.cancel()
        sessions[sessionID]?.shown = nil
    }

    /// La richiesta del gancio se n'è andata. Se l'hai chiusa tu (una risposta, o la mascotte per andare all'app) quello
    /// che la sessione aspetta l'hai già visto; se è caduto il gancio, torna la nostra a fare da rete.
    func hookEnded(sessionID: String, byUser: Bool) {
        guard var session = sessions[sessionID] else { return }
        if byUser, let ask = current(session) { session.handled = look(ask, in: session) }
        sessions[sessionID] = session
        evaluate(sessionID)
    }

    /// Un clic su una nostra domanda: «jump» apre la sessione, «dismiss» la toglie.
    private func acted(_ action: String, sessionID: String) {
        guard var session = sessions[sessionID] else { return }
        // Una risposta del riquadro di fine turno: il pulsante vero, nella finestra di Claude.
        var reply: (label: String, ask: String, conversation: String?)?
        if action.hasPrefix("opt:"), let pick = Int(action.dropFirst(4)), let shown = session.shown, shown.kind == .followUp,
           shown.options.indices.contains(pick), let ask = session.logAsk {
            reply = (shown.options[pick], ask.text, session.record?.name)
        }
        guard action == "jump" || action == "dismiss" || reply != nil else { return }
        Self.trace("tocco su \(sessionID): \(action)")
        session.handled = session.shown
        sessions[sessionID] = session
        hide(sessionID)
        if action == "jump" { open(sessionID: sessionID, kind: session.kind, folder: session.project) }
        guard let reply, let look = session.shown else { return }
        // Claude resta dov'è: davanti lo porti tu, con «Apri» o con la mascotte (carpa, 19 novembre 2026).
        ClaudeWindow.reply(label: reply.label, ask: reply.ask, conversation: reply.conversation, session: sessionID) { [weak self] sent in
            Self.trace("risposta «\(reply.label)» a \(sessionID): \(sent ? "arrivata, Claude ha ripreso" : "non arrivata, torna nell'isola")")
            if !sent { self?.retry(sessionID, look: look) }
        }
    }

    /// La risposta non è partita: la richiesta torna nell'isola com'era, con l'avviso. Claude non si apre da solo.
    private func retry(_ sessionID: String, look: Shown) {
        guard var session = sessions[sessionID], session.logAsk.map({ self.look($0, in: session) })?.same(as: look) == true else { return }
        session.handled = nil
        sessions[sessionID] = session
        show(sessionID, look: look, alert: true, failed: true)
    }

    /// Porta davanti la sessione: nell'app di Claude con il suo indirizzo (si apre proprio quella conversazione), altrove
    /// la finestra o la scheda del terminale dove gira.
    func open(sessionID: String?, kind: AgentKind, folder: String?, origin: String? = nil) {
        let record = record(for: sessionID)
        if let link = record?.desktopLink {
            Self.trace("apro \(link.absoluteString)")
            DockLaunch.open(link)
            return
        }
        let projectDir = sessionID.flatMap { sessions[$0]?.logPath }.flatMap { ClaudeLiveness.session(ofLog: $0)?.projectDir }
        AgentFocus.bring(kind: kind, sessionID: sessionID, projectDir: projectDir, folder: folder, origin: origin,
                         pid: record?.pid)
    }

    // MARK: Cosa mostrare

    /// Quello che la sessione chiede adesso, mettendo insieme registro e stato.
    private func current(_ session: Session, now: Date = Date()) -> AgentAsk? {
        // Una scheda di domanda o un piano: il turno è fermo lì. Con lo stato di Claude a disposizione vale finché dice
        // che aspetta (un registro rimasto a metà da una sessione chiusa non chiede più niente).
        if let ask = session.logAsk, ask.kind == .question || ask.kind == .plan {
            if claudeWritesState, session.kind == .claude {
                if session.record?.isWaiting == true { return ask }
            } else if ask.at.map({ now.timeIntervalSince($0) < 30 * 60 }) ?? true {
                return ask
            }
        }
        if let record = session.record, record.isWaiting {
            let at = record.statusUpdatedAt.map { Date(timeIntervalSince1970: $0) }
            switch record.waitingFor {
            case "permission prompt":
                return AgentAsk(kind: .permission, text: session.openTool ?? "", at: at)
            case "sandbox request":
                return AgentAsk(kind: .permission, text: String(localized: "Un comando chiede di usare la rete"), at: at)
            case "input needed":
                return AgentAsk(kind: .question, text: "", at: at)
            default:
                // «dialog open» e simili: una finestra che hai aperto tu nel terminale.
                return nil
            }
        }
        if let ask = session.logAsk, ask.kind == .followUp {
            // La domanda di fine turno vale a turno finito davvero: fra l'ultima frase e la fine passano un paio di
            // secondi. Finché la sessione dice di essere al lavoro si aspetta.
            if claudeWritesState, session.kind == .claude, let record = session.record, record.status != "idle" { return nil }
            return ask
        }
        return nil
    }

    private func evaluate(_ sessionID: String) {
        guard var session = sessions[sessionID] else { return }
        let want = Features.shared.agents && Features.shared.agentAsks ? current(session) : nil
        guard let want else {
            session.pending?.cancel()
            session.pending = nil
            if let ask = session.logAsk, ask.kind == .followUp, session.record?.status != "idle" {
                // La domanda di fine turno c'è ancora, la sessione lavora per un momento (un avviso automatico, un
                // messaggio di un'altra sessione): resta com'era, tolta o in attesa di rientrare. Il 19 novembre
                // tornava come «vecchia» e non rientrava più, mentre in Claude il riquadro restava.
                if let shown = session.shown { session.paused = shown }
            } else {
                session.handled = nil
                session.paused = nil
            }
            sessions[sessionID] = session
            if session.shown != nil { hide(sessionID) }
            return
        }
        let look = look(want, in: session)
        if look.same(as: session.handled) || look == session.shown { return }
        if look.same(as: session.paused) {
            // Rientra com'era, senza aprire l'isola né il tocco: l'avevi già vista.
            session.paused = nil
            sessions[sessionID] = session
            show(sessionID, look: look, alert: false)
            return
        }
        session.paused = nil
        // Già nell'isola con la richiesta del gancio, a cui si risponde: non la si copre.
        if ActivityCenter.shared.hasHookRequest(client: Self.client(session.kind), sessionID: sessionID) { return }
        // La stessa attesa detta peggio: la risposta è già nel registro ma lo stato dice ancora «aspetta» per un attimo.
        // Resta quello che c'è, finché lo stato non cambia.
        if let shown = session.shown, shown.kind == look.kind, want.text.isEmpty { return }
        if session.shown != nil {
            // La stessa attesa, detta meglio (il registro è arrivato dopo lo stato): si aggiorna senza altri avvisi.
            session.pending?.cancel()
            session.pending = nil
            sessions[sessionID] = session
            show(sessionID, look: look, alert: false)
            return
        }
        guard session.pending == nil else { return }
        let wait = want.kind == .followUp ? Self.followUpGrace : Self.grace
        session.pending = Task { [weak self] in
            if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
            guard let self, !Task.isCancelled, var session = self.sessions[sessionID] else { return }
            session.pending = nil
            self.sessions[sessionID] = session
            // Nel frattempo può essere cambiato tutto: si rifà il conto.
            guard Features.shared.agents, Features.shared.agentAsks, let now = self.current(session) else { return }
            let look = self.look(now, in: session)
            guard !look.same(as: session.handled),
                  !ActivityCenter.shared.hasHookRequest(client: Self.client(session.kind), sessionID: sessionID) else { return }
            // Una domanda di fine turno vista per la prima volta quando era già vecchia (Charland appena ripartita) è
            // già segnata come vista da `logChanged`: qui non serve un altro controllo dell'età, che scartava anche
            // quelle rimesse dopo un turno automatico.
            self.show(sessionID, look: look, alert: true)
        }
        sessions[sessionID] = session
    }

    private func show(_ sessionID: String, look: Shown, alert: Bool, failed: Bool = false) {
        guard var session = sessions[sessionID] else { return }
        let agentTitle = session.kind.title
        var m = ActivityMessage(op: .upsert, client: Self.client(session.kind), id: String(sessionID.prefix(60)))
        m.template = .approval
        m.status = "question"
        let project = Features.shared.projectNames ? session.project : nil
        m.title = String((project?.isEmpty == false ? project! : agentTitle).prefix(60))
        // Una risposta che non è partita lo dice al posto del nome dell'agente.
        m.subtitle = failed ? String(localized: "Non è partita: usa Apri") : agentTitle
        m.symbol = "sparkle"
        m.command = String(look.text.prefix(1200))
        m.priority = 2
        if look.options.isEmpty {
            // Un pulsante solo, che porta alla conversazione; per toglierla senza rispondere c'è la «x» in alto.
            m.actions = [.init(id: "jump", title: String(localized: "Rispondi"))]
        } else {
            // Le risposte del riquadro di fine turno: premuta una, Charland preme quel pulsante nella finestra di Claude.
            // Se sono meno di quattro il centro delle attività aggiunge «Apri», che porta alla conversazione.
            m.actions = look.options.enumerated().map { .init(id: "opt:\($0.offset)", title: String($0.element.prefix(60))) }
        }
        if alert { m.alert = .init(expand: true, haptic: failed ? "error" : "waiting") }
        session.shown = look
        sessions[sessionID] = session
        Self.trace("\(alert ? "mostro" : "aggiorno") \(sessionID): \(look.kind.rawValue) «\(look.text.prefix(80))»")
        ActivityCenter.shared.agentNotice(m) { [weak self] action in self?.acted(action, sessionID: sessionID) }

        sessions[sessionID]?.expiry?.cancel()
        sessions[sessionID]?.peek?.cancel()
        guard look.kind == .followUp else { return }
        // Il turno è già finito e non c'è fretta: l'isola si richiude da sola dopo poco (resta la mano), e la domanda
        // se ne va dopo dieci minuti senza risposta.
        let key = "\(Self.client(session.kind))/\(String(sessionID.prefix(60)))"
        if alert {
            sessions[sessionID]?.peek = Task {
                try? await Task.sleep(for: .seconds(Self.peekSeconds))
                // Solo se l'isola è ancora aperta su questa domanda (dentro l'attività degli agenti) e non la stai toccando.
                guard !Task.isCancelled, let engine = IslandHub.shared.primary?.engine,
                      AgentHub.shared.requestKey == key else { return }
                if case .expanded(let id) = engine.mode, id == AgentHub.activityID, !engine.pointerInside { engine.send(.collapse) }
            }
        }
        sessions[sessionID]?.expiry = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.followUpLife))
            guard let self, !Task.isCancelled, self.sessions[sessionID]?.shown == look else { return }
            self.sessions[sessionID]?.handled = look
            self.hide(sessionID)
        }
    }

    private func hide(_ sessionID: String) {
        guard let session = sessions[sessionID] else { return }
        sessions[sessionID]?.expiry?.cancel()
        sessions[sessionID]?.peek?.cancel()
        guard session.shown != nil else { return }
        sessions[sessionID]?.shown = nil
        Self.trace("tolgo \(sessionID)")
        ActivityCenter.shared.clearAgentNotice(client: Self.client(session.kind), sessionID: String(sessionID.prefix(60)))
    }

    static func client(_ kind: AgentKind) -> String { kind == .codex ? "codex" : "claude-code" }

    /// La frase che si legge nell'isola.
    private static func text(for ask: AgentAsk) -> String {
        switch ask.kind {
        case .question:
            if ask.text.isEmpty { return String(localized: "Ha una domanda per te.") }
            return ask.count > 1 ? String(localized: "\(ask.text) (e altre \(ask.count - 1))") : ask.text
        case .plan:
            return String(localized: "Il piano è pronto: lo approvi?")
        case .permission:
            return ask.text.isEmpty ? String(localized: "Chiede un permesso.") : String(localized: "Chiede il permesso: \(ask.text)")
        case .followUp:
            return ask.text
        }
    }
}
