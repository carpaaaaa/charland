import AppKit
import SwiftUI
import CharlandCore
import CharlandKit

/// Il contenuto di un'attività arrivata dall'API, pronto da disegnare.
struct APIContent: Equatable {
    var template: ActivityMessage.Template
    var client: String
    var title: String
    var subtitle: String = ""
    var symbol: String
    var tint: Color
    var progress: Double = 0
    var status: String = ""
    var endsAt: Date?
    var total: TimeInterval = 0
    var command: String = ""
    var detail: String = ""
    var slots: [String: ActivityMessage.Slot] = [:]
    var actions: [ActivityMessage.Action] = []
    /// Per le approvazioni: lo stato della sessione dell'agente.
    var phase: AgentInfo.Phase = .working
    /// Lo stato come distintivo (arco che gira, mano, spunta), quando l'attività lo dichiara.
    var badge: AgentInfo.Phase?
    var failed = false
    /// L'app che ospita chi manda.
    var origin: String?
    /// Per le approvazioni degli agenti: quanto rischia il comando, deciso a regole.
    var risk: CommandRisk.Level?
    /// Quando è cominciato il turno o il lavoro: il tempo a destra della fotocamera parte da qui.
    var startedAt: Date?
    /// Una registrazione in corso: a destra il tempo che sale.
    var recording = false
    /// Il Risparmio energetico appena acceso: la batteria gialla entra con un rimbalzo.
    var lowPower = false
    /// La Concentrazione di macOS appena accesa o spenta (`FocusMonitor`): la falce a sinistra, il nome a destra.
    var focus = false
    var focusOn = false
    /// Il colore del modo per nome («indigo», «mint»): la falce passa da lui al grigio quando si spegne.
    var focusTint = "indigo"
    /// Una domanda di un agente, con le scelte come pulsanti (non un comando da approvare).
    var question = false

    /// Un agente AI: a sinistra la sua mascotte, a destra il tempo del turno.
    var isAgent: Bool { ["claude-code", "codex"].contains(client) }
}

/// Il centro delle attività: riceve i messaggi dell'API (socket, comando da terminale,
/// Comandi Rapidi, indirizzo charland://), li controlla e li porta nell'isola.
@MainActor @Observable
final class ActivityCenter {
    static let shared = ActivityCenter()

    struct Entry {
        var message: ActivityMessage
        weak var connection: APIServer.Connection?
        var expiry: Timer?
        /// Un conto alla rovescia che scende sotto l'ora (o le dieci ore) stringe il suo lato dell'isola.
        var resize: Timer?
        /// Quando è arrivata: una risposta data altrove dopo questo momento la chiude.
        var posted = Date()
        /// La richiesta di un agente arrivata dal suo gancio: da qui le si risponde, e il gancio aspetta sul suo canale.
        var fromHook = false
        /// Quando è arrivata la sessione era ferma ad aspettarti (un permesso, una scheda). Se no è una domanda di fine
        /// turno: la sessione è a riposo, e la domanda cade quando riparte.
        var wasWaiting = true
    }

    /// Le ultime attività, per il registro nelle impostazioni.
    struct LogLine: Identifiable {
        let id = UUID()
        var date = Date()
        var client: String
        var text: String
    }

    private(set) var log: [LogLine] = []
    private(set) var pendingClients: [String] = []
    @ObservationIgnored private var entries: [String: Entry] = [:]
    /// Le azioni delle attività interne di Charland (timer, mantieni attivo, registrazione).
    @ObservationIgnored private var localHandlers: [String: (String) -> Void] = [:]
    @ObservationIgnored private var queued: [String: [(ActivityMessage, APIServer.Connection?)]] = [:]
    @ObservationIgnored private var server: APIServer?
    /// Le richieste degli agenti a cui hai appena risposto da qui: quando il gancio le chiude, non tornano come domanda.
    @ObservationIgnored private var answered: Set<String> = []

    /// Chi può mostrare attività senza chiedere: il comando `charland`, il terminale e Comandi Rapidi
    /// fanno parte dell'app.
    static let builtIn: Set<String> = ["charland", "terminale", "comandi-rapidi", "claude-code", "codex"]

    private var island: IslandController? { IslandHub.shared.primary }

    private init() {}

    var isRunning: Bool { server != nil }

    func start() {
        guard server == nil else { return }
        let server = APIServer(onMessage: { [weak self] message, connection in
            self?.handle(message, from: connection) ?? ServerReply(ok: false, error: "chiusa")
        }, onClose: { [weak self] connection in self?.closed(connection) })
        do {
            try server.start()
            self.server = server
        } catch {
            note("charland", "Il socket dell'API non parte: \(error.localizedDescription)")
        }
    }

    /// Chi aveva mandato una richiesta se n'è andato senza chiuderla (il gancio è stato fermato, è scaduto, è caduto):
    /// nessuno ascolta più la risposta, quindi la richiesta sparisce invece di restare nell'isola con due pulsanti morti.
    private func closed(_ connection: APIServer.Connection) {
        for (key, entry) in entries where entry.fromHook && entry.connection === connection {
            note(entry.message.client, "chiusa senza risposta: \(entry.message.title ?? key)")
            remove(key)
        }
    }

    // MARK: Domande degli agenti

    private static let agentClients: Set<String> = ["claude-code", "codex"]

    /// Nell'isola c'è la richiesta di questa sessione arrivata dal gancio (quella a cui si risponde da qui).
    func hasHookRequest(client: String, sessionID: String) -> Bool {
        entries["\(client)/\(String(sessionID.prefix(60)))"]?.fromHook == true
    }

    /// Una domanda letta dal registro o dallo stato della sessione (`AgentAsks`): si vede, e le sue due azioni («jump»,
    /// «dismiss») tornano a chi l'ha messa. Non prende il posto di una richiesta arrivata dal gancio.
    func agentNotice(_ message: ActivityMessage, handler: @escaping (String) -> Void) {
        let k = key(message)
        guard entries[k]?.fromHook != true else { return }
        local(message, handler: handler)
    }

    func clearAgentNotice(client: String, sessionID: String) {
        let k = "\(client)/\(sessionID)"
        guard localHandlers[k] != nil, entries[k]?.fromHook != true else { return }
        remove(k)
    }

    /// Lo stato della sessione è cambiato (`nil`: la sessione non c'è più). La richiesta arrivata dal gancio ha avuto la
    /// sua risposta nell'app dell'agente se, dopo il suo arrivo, la sessione è ripartita, oppure aspettava e non aspetta
    /// più. Il gancio resta appeso finché la sessione non finisce: lo si congeda da qui.
    func agentAnsweredElsewhere(sessionID: String, record: ClaudeSessionRecord?) {
        for client in Self.agentClients {
            let k = "\(client)/\(String(sessionID.prefix(60)))"
            guard let entry = entries[k], entry.fromHook else { continue }
            if let record {
                guard let at = record.statusUpdatedAt, Date(timeIntervalSince1970: at) > entry.posted,
                      record.status == "busy" || (entry.wasWaiting && !record.isWaiting) else { continue }
            }
            note(client, "\(record == nil ? "sessione chiusa" : "risposto altrove"): \(entry.message.title ?? k)")
            remove(k)
        }
    }

    /// L'isola ha cambiato stato: le scorciatoie delle approvazioni seguono.
    func islandModeChanged() {
        refreshShortcuts()
    }

    // MARK: Scorciatoie delle approvazioni

    private static let allowID: UInt32 = 20
    private static let denyID: UInt32 = 21
    private static let alwaysID: UInt32 = 22
    @ObservationIgnored private var shortcutsOn = false

    /// ⌘↩ approva, ⌘⌫ rifiuta, ⌘⌥↩ approva sempre. Le scorciatoie sono nostre solo mentre
    /// un'approvazione è aperta nell'isola: appena si chiude tornano alle altre app.
    private func refreshShortcuts() {
        let wanted = expandedApproval != nil
        guard wanted != shortcutsOn else { return }
        shortcutsOn = wanted
        let center = HotkeyCenter.shared
        if wanted {
            center.register(id: Self.allowID, combo: KeyCombo(keyCode: 36, modifiers: 0x0100), down: { [weak self] in self?.shortcut("allow") })
            center.register(id: Self.denyID, combo: KeyCombo(keyCode: 51, modifiers: 0x0100), down: { [weak self] in self?.shortcut("deny") })
            center.register(id: Self.alwaysID, combo: KeyCombo(keyCode: 36, modifiers: 0x0100 | 0x0800), down: { [weak self] in self?.shortcut("always") })
        } else {
            center.unregister(id: Self.allowID)
            center.unregister(id: Self.denyID)
            center.unregister(id: Self.alwaysID)
        }
    }

    private func shortcut(_ action: String) {
        guard let key = expandedApproval, let message = entries[key]?.message else { return }
        let content = Self.content(for: message)
        // La richiesta di permesso per un cliente nuovo ha azioni sue: la prima approva, la seconda rifiuta.
        if let match = content.actions.first(where: { $0.id == action }) {
            perform(action: match.id, on: key)
        } else if action == "allow", let first = content.actions.first {
            perform(action: first.id, on: key)
        } else if action == "deny", content.actions.count > 1 {
            perform(action: content.actions[1].id, on: key)
        }
    }

    func stop() {
        server?.stop()
        server = nil
        for key in Array(entries.keys) { remove(key) }
    }

    // MARK: Permessi dei clienti

    private var decisions: [String: Bool] {
        get { UserDefaults.standard.dictionary(forKey: "apiClients") as? [String: Bool] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: "apiClients") }
    }

    var knownClients: [(name: String, allowed: Bool)] {
        decisions.map { ($0.key, $0.value) }.sorted { $0.name < $1.name }
    }

    func setClient(_ name: String, allowed: Bool?) {
        var d = decisions
        d[name] = allowed
        decisions = d
        pendingClients.removeAll { $0 == name }
        if allowed == true {
            for (message, connection) in queued.removeValue(forKey: name) ?? [] { _ = apply(message, from: connection) }
        } else {
            queued[name] = nil
        }
        remove("charland/permesso-\(name)")
    }

    private func isAllowed(_ client: String) -> Bool? {
        if Self.builtIn.contains(client) { return true }
        return decisions[client]
    }

    // MARK: Messaggi

    func handle(_ message: ActivityMessage, from connection: APIServer.Connection?) -> ServerReply {
        switch message.op {
        case .hello:
            return ServerReply(ok: true, name: Identity.name, version: Identity.version)
        case .list:
            let prefix = message.client + "/"
            return ServerReply(ok: true, ids: entries.keys.filter { $0.hasPrefix(prefix) }.map { String($0.dropFirst(prefix.count)) }.sorted())
        case .end where message.agent != nil:
            AgentHub.shared.finished(agentKey(message), duration: 0)
            return ServerReply(ok: true)
        case .end where message.client == "charland" && TimerCenter.shared.cancel(id: message.id ?? ""):
            return ServerReply(ok: true)
        case .end:
            // La richiesta di un agente la chiude solo il gancio che l'ha mandata. Con due richieste della stessa
            // sessione (sotto-agenti in parallelo) la seconda ha preso il posto della prima: quando la prima se ne va
            // non deve portarsi via quella che si vede.
            if let entry = entries[key(message)], entry.fromHook, let owner = entry.connection, let connection, owner !== connection {
                return ServerReply(ok: true)
            }
            remove(key(message))
            note(message.client, "chiude \(message.id ?? "")")
            return ServerReply(ok: true)
        case .upsert:
            // Con «Domande e permessi nell'isola» spento il gancio di un agente non mostra niente: l'agente chiede
            // nella sua finestra, come senza Charland.
            if Self.agentClients.contains(message.client), message.template == .approval,
               !(Features.shared.agents && Features.shared.agentAsks) {
                return ServerReply(ok: false, error: "le domande degli agenti nell'isola sono spente")
            }
            switch isAllowed(message.client) {
            case true?:
                var message = message
                if message.partial == true {
                    // `charland update`: solo i campi che cambiano, sopra l'attività che c'è già.
                    guard let base = entries[key(message)]?.message else {
                        return ServerReply(ok: false, error: "nessuna attività con id «\(message.id ?? "")» da aggiornare")
                    }
                    message = message.merged(onto: base)
                    do { try ActivitySchema.validate(message) } catch {
                        return ServerReply(ok: false, error: "\(error)")
                    }
                    if let handler = localHandlers[key(message)] {
                        // un'attività interna (un timer): resta sua, con le sue azioni
                        local(message, handler: handler)
                        return ServerReply(ok: true)
                    }
                    return apply(message, from: connection)
                }
                if message.agent != nil { return applyAgent(message) }
                // Un timer dal terminale: lo prende il gestore dei timer, che sa fermarlo,
                // aggiungere un minuto e suonare alla fine anche se il comando è già uscito.
                if message.client == "charland", message.template == .countdown, message.id?.hasPrefix("timer-") == true,
                   let end = message.endsAt {
                    TimerCenter.shared.start(seconds: max(1, end - Date().timeIntervalSince1970),
                                             title: message.title ?? String(localized: "Timer"), id: message.id)
                    return ServerReply(ok: true)
                }
                return apply(message, from: connection)
            case false?:
                return ServerReply(ok: false, error: "questo cliente non ha il permesso di mostrare attività")
            case nil:
                // Un cliente nuovo: prima si chiede all'utente. L'attività aspetta.
                queued[message.client, default: []].append((message, connection))
                if queued[message.client]?.count ?? 0 > 8 { queued[message.client]?.removeFirst() }
                askPermission(for: message.client)
                return ServerReply(ok: true)
            }
        }
    }

    private func key(_ message: ActivityMessage) -> String { "\(message.client)/\(message.id ?? "")" }

    /// Un'attività interna di Charland, con chi risponde alle sue azioni.
    func local(_ message: ActivityMessage, handler: ((String) -> Void)?) {
        if let handler { localHandlers[key(message)] = handler }
        _ = apply(message, from: nil)
    }

    private func agentKey(_ message: ActivityMessage) -> String { "api:\(message.client)/\(message.id ?? "")" }

    /// Un'AI aggiunta dall'API: entra nell'attività degli agenti, con un tempo solo per tutti.
    private func applyAgent(_ message: ActivityMessage) -> ServerReply {
        let key = agentKey(message)
        let name = message.agent ?? message.client
        if message.status == "done" || message.status == "error" {
            let start = AgentHub.shared.sessions[key]?.since ?? Date()
            AgentHub.shared.finished(key, duration: Date().timeIntervalSince(start))
        } else {
            let since = message.startedAt.map { Date(timeIntervalSince1970: $0) } ?? AgentHub.shared.sessions[key]?.since ?? Date()
            AgentHub.shared.working(key, kind: .custom(name: name, tint: message.tint), project: message.title, since: since)
        }
        note(message.client, "\(name): \(message.status ?? "working")")
        return ServerReply(ok: true)
    }

    private func askPermission(for client: String) {
        guard !pendingClients.contains(client) else { return }
        pendingClients.append(client)
        var ask = ActivityMessage(op: .upsert, client: "charland", id: "permesso-\(client)")
        ask.template = .approval
        ask.title = client
        ask.command = String(localized: "«\(client)» vuole mostrare attività nell'isola.")
        ask.symbol = "app.badge"
        ask.priority = 2
        ask.alert = .init(expand: true)
        ask.actions = [.init(id: "client-allow:\(client)", title: String(localized: "Consenti")),
                       .init(id: "client-deny:\(client)", title: String(localized: "Rifiuta"))]
        _ = apply(ask, from: nil)
    }

    private func apply(_ message: ActivityMessage, from connection: APIServer.Connection?) -> ServerReply {
        guard let island else { return ServerReply(ok: false, error: "nessuno schermo") }
        let k = key(message)
        let isNew = entries[k] == nil
        entries[k]?.expiry?.invalidate()
        entries[k]?.resize?.invalidate()
        // Una seconda richiesta della stessa sessione, da un altro gancio, mentre la prima aspetta: l'isola ne mostra
        // una per sessione, quindi la prima si congeda (resta da decidere nella finestra dell'agente) invece di
        // aspettare un tocco che andrebbe all'altra.
        if let connection, let old = entries[k], old.fromHook, let previous = old.connection, previous !== connection {
            previous.send(ServerReply(event: "ended", id: old.message.id))
        }
        var entry = Entry(message: message, connection: connection ?? entries[k]?.connection)
        // La richiesta di un agente arrivata dal suo gancio: ci si risponde da qui. Prende il posto della domanda letta
        // dal registro per la stessa sessione (e il suo gestore), che resta a fare da rete.
        let agentRequest = Self.agentClients.contains(message.client) && message.template == .approval
        if agentRequest, connection != nil {
            entry.fromHook = true
            // Senza lo stato della sessione (Codex, o Claude che non lo scrive) vale la regola di chi aspetta.
            entry.wasWaiting = AgentAsks.shared.record(for: message.id).map(\.isWaiting) ?? true
            localHandlers[k] = nil
            AgentAsks.shared.hookPosted(sessionID: message.id ?? "")
        }
        let ttl = min(message.ttl ?? ActivitySchema.maxSeconds, ActivitySchema.maxSeconds)
        let timer = Timer(timeInterval: ttl, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.remove(k) }
        }
        RunLoop.main.add(timer, forMode: .common)
        entry.expiry = timer
        entry.resize = scheduleResize(k, message: message)
        entries[k] = entry

        let content = Self.content(for: message)
        let activity = Self.activity(key: k, message: message)
        // Quello che si apre nell'isola: l'attività stessa, oppure quella degli agenti se è una loro richiesta.
        var islandID = k
        if agentRequest {
            // Una sola attività per gli agenti (carpa, 19 novembre 2026: «non devono esserci due live activity»): la
            // domanda o il permesso stanno dentro quella di chi chiede, non in una seconda accanto.
            islandID = AgentHub.activityID
            AgentHub.shared.setRequest(AgentRequest(key: k, kind: message.client == "codex" ? .codex : .claude,
                                                    content: content, height: activity.expandedHeight))
            if isNew { note(message.client, "\(message.title ?? k)") }
        } else {
            // Un messaggio che non è una richiesta, sulla chiave di una richiesta: la richiesta non c'è più.
            AgentHub.shared.clearRequest(k)
            if isNew {
                island.engine.show(activity, content: .api(content))
                note(message.client, "\(message.title ?? k)")
            } else {
                island.engine.update(id: k, content: .api(content))
                island.engine.send(.updated(activity))
            }
        }
        // Silenzio se stai già guardando l'app da cui arriva: lì la cosa la vedi già. Non vale per le domande e i
        // permessi degli agenti (carpa, 19 novembre 2026: «deve funzionare sempre»): l'app di Claude davanti non vuol
        // dire che stai guardando proprio quella sessione, ne tiene aperte tante.
        let looking = !agentRequest && message.origin != nil
            && NSWorkspace.shared.frontmostApplication?.bundleIdentifier == message.origin
        if let alert = message.alert, !looking {
            if alert.expand == true { island.engine.send(.expand(id: islandID)) }
            if let haptic = alert.haptic { Haptics.play(haptic) }
        }
        // Una domanda non è un comando: niente spiegazione e niente rischio.
        if message.template == .approval, message.status != "question", message.client != "charland", (message.detail ?? "").isEmpty,
           let command = message.command {
            explain(command, for: k)
        }
        // `CHARLAND_TEST_ONLY=<titolo>`: la prova automatica decide solo per le richieste con quel titolo (la cartella
        // della sessione di prova), mai per quelle vere che arrivano nel frattempo.
        // Solo nelle build di debug: una variabile d'ambiente non deve poter approvare comandi al posto di chi usa il Mac.
        #if DEBUG
        let testOnly = ProcessInfo.processInfo.environment["CHARLAND_TEST_ONLY"]
        if message.template == .approval, testOnly == nil || testOnly == message.title,
           let decision = ProcessInfo.processInfo.environment["CHARLAND_TEST_DECIDE"] {
            // Solo per le prove automatiche: decide da sé. La variabile vale solo se è nell'ambiente dell'app.
            // Più scelte separate da una virgola («allow,opt:1»): a una domanda va quella che comincia con «opt:», a un
            // permesso l'altra.
            let choices = decision.split(separator: ",").map(String.init)
            let question = message.status == "question"
            let pick = choices.first { $0.hasPrefix("opt:") == question } ?? decision
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                if message.client == "charland", let first = message.actions?.first {
                    self?.perform(action: decision == "deny" ? (message.actions?.last?.id ?? first.id) : first.id, on: k)
                } else {
                    self?.perform(action: pick, on: k)
                }
            }
        }
        #endif
        refreshShortcuts()
        return ServerReply(ok: true)
    }

    /// Aggiunge all'approvazione una frase semplice che dice cosa fa il comando e quanto rischia.
    private func explain(_ command: String, for key: String) {
        Task { [weak self] in
            guard let text = await CommandExplainer.explain(command), let self,
                  var entry = self.entries[key], entry.message.template == .approval, entry.message.command == command else { return }
            entry.message.detail = String(text.prefix(400))
            self.entries[key] = entry
            if AgentHub.shared.hasRequest(key) {
                AgentHub.shared.setRequest(AgentRequest(key: key, kind: entry.message.client == "codex" ? .codex : .claude,
                                                        content: Self.content(for: entry.message),
                                                        height: Self.activity(key: key, message: entry.message).expandedHeight))
            } else {
                self.island?.engine.update(id: key, content: .api(Self.content(for: entry.message)))
                self.island?.engine.send(.updated(Self.activity(key: key, message: entry.message)))
            }
            self.note(entry.message.client, "spiegazione: \(text)")
        }
    }

    /// Quando il tempo che resta perde una cifra (da «1:00:00» a «59:59», da «10:00:00» a «9:59:59»)
    /// il lato destro dell'isola si stringe, un attimo dopo il cambio: mai più stretto della scritta.
    private func scheduleResize(_ key: String, message: ActivityMessage) -> Timer? {
        guard message.template == .countdown, let end = message.endsAt else { return nil }
        let remaining = end - Date().timeIntervalSince1970
        guard let step = [36_000.0, 3_600].first(where: { remaining + Self.countdownMargin >= $0 }) else { return nil }
        let wait = remaining - (step - 1.5)
        guard wait > 0 else { return nil }
        let timer = Timer(timeInterval: wait, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, var entry = self.entries[key] else { return }
                self.island?.engine.send(.updated(Self.activity(key: key, message: entry.message)))
                entry.resize = self.scheduleResize(key, message: entry.message)
                self.entries[key] = entry
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        return timer
    }

    /// Il tempo si legge arrotondato per eccesso: un secondo di scorta prima di stringere.
    private static let countdownMargin = 1.0

    /// Larghezza del tempo accanto alla fotocamera (SF Rounded semibold 13, cifre a spaziatura fissa):
    /// «59:59» 38,9 punti, «1:59:59» 51,6, «10:00:00» 60,3.
    static func countdownWidth(remaining: TimeInterval) -> Double {
        let r = remaining + countdownMargin
        if r >= 36_000 { return 64 }
        if r >= 3_600 { return 56 }
        return 44
    }

    private func remove(_ key: String, byUser: Bool = false) {
        guard let entry = entries.removeValue(forKey: key) else { return }
        localHandlers[key] = nil
        if entry.fromHook { AgentAsks.shared.hookEnded(sessionID: entry.message.id ?? "", byUser: byUser || answered.remove(key) != nil) }
        entry.expiry?.invalidate()
        entry.resize?.invalidate()
        if AgentHub.shared.hasRequest(key) { AgentHub.shared.clearRequest(key) } else { island?.engine.end(id: key) }
        entry.connection?.send(ServerReply(event: "ended", id: entry.message.id))
        refreshShortcuts()
        // La sveglia di un timer finito smette con il suo avviso, comunque se ne vada (Ferma, scadenza, `charland end`).
        if key.hasPrefix("charland/") { AlarmPlayer.shared.ended(id: String(key.dropFirst("charland/".count))) }
    }

    /// L'utente ha toccato un'azione (o ha premuto la sua scorciatoia).
    func perform(action: String, on key: String) {
        if action.hasPrefix("client-allow:") {
            setClient(String(action.dropFirst("client-allow:".count)), allowed: true)
            return
        }
        if action.hasPrefix("client-deny:") {
            setClient(String(action.dropFirst("client-deny:".count)), allowed: false)
            return
        }
        guard let entry = entries[key] else { return }
        if let handler = localHandlers[key] {
            handler(action)
            refreshShortcuts()
            return
        }
        // Le azioni tornano al cliente sullo stesso canale.
        entry.connection?.send(ServerReply(event: "action", id: entry.message.id, action: action))
        note(entry.message.client, "\(entry.message.title ?? key): \(action)")
        if entry.fromHook { answered.insert(key) }
        if action == "jump" {
            // La sessione dove lavora l'agente: per Claude Code l'identificativo dell'attività è la sessione, e nell'app
            // di Claude si apre proprio quella conversazione. Davanti davvero: da un pannello che non attiva Charland
            // l'app si aprirebbe dietro le altre.
            let message = entry.message
            let kind: AgentKind = message.client == "codex" ? .codex : .claude
            if Self.agentClients.contains(message.client) {
                AgentAsks.shared.open(sessionID: message.id, kind: kind, folder: message.title, origin: message.origin)
            } else if let origin = message.origin {
                DockLaunch.open(bundle: origin)
            }
        }
        if entry.message.template == .approval {
            island?.engine.send(.collapse)
        }
        refreshShortcuts()
    }

    /// L'attività aperta in questo momento, se è un'approvazione: serve alle scorciatoie.
    var expandedApproval: String? {
        // Solo quelle a cui si risponde da qui: una domanda letta dal registro ha un pulsante che porta alla sessione, e
        // non deve togliere ⌘↩ all'app in cui stai scrivendo.
        guard case .expanded(let open)? = island?.engine.mode else { return nil }
        // Le richieste degli agenti stanno dentro la loro attività: aperta quella, vale la richiesta che mostra.
        let id = open == AgentHub.activityID ? AgentHub.shared.requestKey ?? open : open
        guard entries[id]?.message.template == .approval, localHandlers[id] == nil else { return nil }
        return id
    }

    /// L'ora con i millesimi, per le tracce.
    nonisolated static func clock() -> String {
        let now = Date().timeIntervalSince1970
        let seconds = Int(now) % 86400 + TimeZone.current.secondsFromGMT()
        return String(format: "%02d:%02d:%02d.%03d", (seconds / 3600) % 24, (seconds / 60) % 60, seconds % 60, Int((now - floor(now)) * 1000))
    }

    private func note(_ client: String, _ text: String) {
        if ProcessInfo.processInfo.environment["CHARLAND_TRACE"] != nil {
            print("\(Self.clock()) [api] \(client): \(text) | isola: \(island.map { "\($0.engine.mode)" } ?? "-")")
            fflush(stdout)
        }
        log.insert(LogLine(client: client, text: text), at: 0)
        if log.count > 40 { log.removeLast(log.count - 40) }
    }

    // MARK: Da messaggio a isola

    static func activity(key: String, message m: ActivityMessage) -> IslandActivity {
        if ["claude-code", "codex"].contains(m.client) {
            // Mascotte a sinistra, tempo a destra; aperta mostra il progetto e il tempo grande,
            // oppure l'approvazione.
            // Una domanda è alta quanto le sue scelte: due per riga.
            let question = m.template == .approval && m.status == "question"
            let rows = Double(((question ? questionActions(m).count : m.actions?.count ?? 2) + 1) / 2)
            // Il testo della domanda sta su due righe; una domanda lunga ne prende una terza.
            let third: Double = question && (m.command?.count ?? 0) > 84 ? 19 : 0
            return IslandActivity(id: key, priority: (m.priority ?? 0) + (m.template == .approval ? 3 : 1),
                                  leadingWidth: 34,
                                  trailingWidth: m.template == .approval || m.status == "waiting" ? NeedsYou.trailingWidth : 46,
                                  expandedWidth: m.template == .approval ? 372 : 300,
                                  expandedHeight: question ? 98 + rows * 38 + third : (m.template == .approval ? 138 : 92),
                                  // Un tempo solo: le sessioni di Claude non occupano la goccia staccata.
                                  allowsMinimal: m.template == .approval)
        }
        let trailing: Double
        switch m.template {
        case .countdown: trailing = countdownWidth(remaining: (m.endsAt ?? 0) - Date().timeIntervalSince1970)
        case .status: trailing = m.slots?["trailing"]?.text != nil ? 44 : m.status == "waiting" ? NeedsYou.trailingWidth : 24
        case .custom: trailing = m.slots?["trailing"]?.text != nil ? 48 : 24
        case .approval: trailing = NeedsYou.trailingWidth   // «Needs you» al posto della mano
        default: trailing = 24
        }
        if m.client == "charland", m.status == "recording" {
            return IslandActivity(id: key, priority: 2, leadingWidth: 22, trailingWidth: 46, expandedWidth: 320, expandedHeight: 104)
        }
        if m.client == "charland", m.status == "focus-on" || m.status == "focus-off" {
            // come il Risparmio energetico: un momento compatto, l'ala destra larga quanto il nome (o «Spento»)
            return IslandActivity(id: key, priority: 2, leadingWidth: 30,
                                  trailingWidth: FocusLabel.width(for: m.slots?["trailing"]?.text ?? ""),
                                  expandedWidth: 320, expandedHeight: 86, allowsMinimal: false)
        }
        if m.client == "charland", m.status == "lowpower" {
            // come la campanella del silenzioso su iPhone: un momento compatto, largo quanto la parola
            return IslandActivity(id: key, priority: 2, leadingWidth: 30, trailingWidth: 92, expandedWidth: 320, expandedHeight: 64,
                                  allowsMinimal: false)
        }
        let expandedHeight: Double
        switch m.template {
        case .approval: expandedHeight = m.client == "charland" ? 104 : 138
        case .countdown: expandedHeight = (m.actions?.isEmpty == false) ? 128 : 96
        default: expandedHeight = m.status?.isEmpty == false || m.subtitle?.isEmpty == false ? 86 : 64
        }
        return IslandActivity(id: key, priority: (m.priority ?? 0) + (m.template == .approval ? 3 : 0),
                              leadingWidth: 22, trailingWidth: trailing,
                              expandedWidth: m.template == .approval ? 372 : 320, expandedHeight: expandedHeight)
    }

    /// I pulsanti di una domanda di un agente: le sue scelte e, se c'è posto, «Apri», che porta alla sua finestra
    /// (per scrivere una risposta diversa da quelle proposte). Una domanda letta dal registro porta già le sue azioni.
    static func questionActions(_ m: ActivityMessage) -> [ActivityMessage.Action] {
        var actions = m.actions ?? []
        if agentClients.contains(m.client), !actions.isEmpty, actions.count < ActivitySchema.maxOptions,
           actions.allSatisfy({ $0.id.hasPrefix("opt:") }) {
            actions.append(.init(id: "jump", title: String(localized: "Apri")))
        }
        return actions
    }

    static func content(for m: ActivityMessage) -> APIContent {
        let template = m.template ?? .status
        let defaultSymbol: String
        switch template {
        case .progress: defaultSymbol = "arrow.down.circle.fill"
        case .countdown: defaultSymbol = "timer"
        case .status: defaultSymbol = "circle.fill"
        case .approval: defaultSymbol = "sparkle"
        case .custom: defaultSymbol = "square.grid.2x2.fill"
        }
        var content = APIContent(template: template, client: m.client, title: m.title ?? "", symbol: m.symbol ?? defaultSymbol,
                                 tint: color(m.tint))
        content.subtitle = m.subtitle ?? ""
        content.progress = m.progress ?? 0
        content.status = m.status ?? ""
        if let end = m.endsAt {
            content.endsAt = Date(timeIntervalSince1970: end)
            content.total = max(1, end - (m.startedAt ?? Date().timeIntervalSince1970))
        }
        content.command = m.command ?? ""
        content.detail = m.detail ?? ""
        content.slots = m.slots ?? [:]
        content.actions = m.template == .approval && m.status == "question" ? questionActions(m) : m.actions ?? []
        content.origin = m.origin
        content.startedAt = m.startedAt.map { Date(timeIntervalSince1970: $0) }
        if template == .approval {
            content.phase = .waiting
            content.badge = .waiting
            content.question = m.status == "question"
            if !content.question, m.client != "charland", let command = m.command { content.risk = CommandRisk.assess(command) }
            if content.actions.isEmpty {
                content.actions = [.init(id: "allow", title: String(localized: "Approva")), .init(id: "deny", title: String(localized: "Rifiuta"))]
                if m.allowAlways == true { content.actions.append(.init(id: "always", title: String(localized: "Sempre"))) }
            }
        } else {
            // Quattro stati hanno un nome fisso e un distintivo: chi manda non scrive testo, lo scrive l'isola.
            switch m.status {
            case "working": content.badge = .working; content.status = String(localized: "Sta lavorando")
            case "waiting": content.badge = .waiting; content.status = String(localized: "Ti aspetta")
            case "done": content.badge = .done; content.status = String(localized: "Fatto")
            case "error": content.badge = .done; content.failed = true; content.status = String(localized: "Errore")
            case "recording": content.recording = true; content.status = ""
            case "lowpower": content.lowPower = true; content.status = ""
            case "focus-on", "focus-off":
                content.focus = true
                content.focusOn = m.status == "focus-on"
                content.focusTint = m.tint ?? "indigo"
                content.status = content.focusOn ? String(localized: "Acceso") : String(localized: "Spento")
            default: break
            }
            content.phase = content.badge ?? .working
        }
        return content
    }

    nonisolated static func color(_ name: String?) -> Color {
        switch name {
        case "blue": .blue
        case "green": .green
        case "orange": .orange
        case "red": .red
        case "yellow": .yellow
        case "purple": .purple
        case "pink": .pink
        case "teal": .teal
        case "indigo": FocusPalette.color("indigo", lit: 1)
        case "mint": FocusPalette.color("mint", lit: 1)
        case "gray": .gray
        default: .white
        }
    }
}

/// I tocchi sul trackpad: un linguaggio breve. Uno per "fatto", due per "ti aspetto",
/// tre corti per "errore". Sono un segnale in più, mai l'unico.
@MainActor
enum Haptics {
    /// Uno scatto solo e leggero, come le tacche di un cursore.
    static func tick() {
        guard Appearance.shared.haptics else { return }
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
    }

    static func play(_ name: String) {
        guard Appearance.shared.haptics else { return }
        let count = name == "done" ? 1 : name == "waiting" ? 2 : 3
        let gap = name == "error" ? 0.07 : 0.13
        for i in 0..<count {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * gap) {
                NSHapticFeedbackManager.defaultPerformer.perform(name == "error" ? .generic : .levelChange, performanceTime: .now)
            }
        }
    }
}
