import Foundation

/// Segue un turno di Claude Code leggendo il registro che Claude scrive da sé
/// (`~/.claude/projects/<cartella>/<sessione>.jsonl`), una riga JSON alla volta.
/// Non serve configurare niente: è così che Charland si collega da sola a ogni sessione,
/// nel terminale, nell'app di Claude o nell'editor.
///
/// Un turno comincia quando scrivi un messaggio e finisce quando Claude risponde con la fine
/// del turno (`end_turn`) o quando lo interrompi.
public struct TranscriptTracker: Sendable {
    public enum Change: Sendable, Equatable {
        /// È cominciato un turno (o ne è cominciato uno nuovo mentre l'altro era in corso).
        case started(Date)
        /// Il turno è finito, dopo tanti secondi.
        case ended(Date, duration: TimeInterval)
    }

    public private(set) var sessionID: String?
    public private(set) var cwd: String?
    public private(set) var working = false
    public private(set) var turnStart: Date?
    public private(set) var lastActivity: Date?
    /// Il registro di un sotto-agente (`<sessione>/subagents/agent-*.jsonl`): lì ogni riga è «di lato», e il suo turno
    /// va dal compito ricevuto alla sua fine del turno. Serve per sapere quando tutto il lavoro è finito davvero.
    public var followsSidechain = false
    /// L'ultimo strumento chiesto da un sotto-agente: i sotto-agenti dei flussi finiscono consegnando il risultato con
    /// `StructuredOutput`, e la loro ultima riga è la ricevuta di quello, non una fine del turno.
    private var lastTool: String?

    /// Uno strumento chiesto e non ancora tornato.
    public struct OpenTool: Sendable, Equatable {
        public var id: String
        public var name: String
        /// Il comando in una riga, come lo vedrebbe chi lo approva.
        public var summary: String
    }

    /// Quello che l'agente sta chiedendo adesso, secondo il registro: una scheda di domanda o un piano ancora senza
    /// risposta, oppure la domanda coi pulsanti con cui è finito l'ultimo turno. Sparisce col messaggio successivo.
    public private(set) var ask: AgentAsk?
    /// Gli strumenti chiesti e non ancora tornati, nell'ordine in cui sono stati chiesti: quando la sessione dice di
    /// aspettare un permesso, è uno di questi.
    public private(set) var openTools: [OpenTool] = []
    /// La domanda del riquadro di fine turno dell'app di Claude, tenuta da parte finché il turno non finisce.
    private var turnAsk: AgentAsk?

    public init() {}

    public init(sidechainLog: Bool) {
        followsSidechain = sidechainLog
    }

    /// Il nome del progetto: l'ultima cartella del percorso di lavoro.
    public var project: String? {
        cwd.map { ($0 as NSString).lastPathComponent }.flatMap { $0.isEmpty ? nil : $0 }
    }

    nonisolated(unsafe) private static let isoFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    nonisolated(unsafe) private static let iso: ISO8601DateFormatter = ISO8601DateFormatter()

    static func date(_ value: Any?) -> Date? {
        guard let text = value as? String else { return nil }
        return isoFractional.date(from: text) ?? iso.date(from: text)
    }

    /// Legge una riga del registro. Restituisce un cambiamento se la riga apre o chiude un turno.
    @discardableResult
    public mutating func feed(_ line: Data) -> Change? {
        guard !line.isEmpty, let json = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { return nil }
        if let id = json["sessionId"] as? String { sessionID = id }
        if let path = json["cwd"] as? String, !path.isEmpty { cwd = path }
        let when = Self.date(json["timestamp"])
        if let when { lastActivity = max(lastActivity ?? when, when) }
        // Nel registro della sessione le righe dei sotto-agenti contano come attività, ma non aprono e non chiudono il
        // turno. Nel registro del sotto-agente invece sono il suo turno.
        if json["isSidechain"] as? Bool == true, !followsSidechain { return nil }
        let type = json["type"] as? String
        let message = json["message"] as? [String: Any]

        if followsSidechain, type == "assistant", let blocks = message?["content"] as? [[String: Any]],
           let tool = blocks.last(where: { $0["type"] as? String == "tool_use" })?["name"] as? String {
            lastTool = tool
        }
        if !followsSidechain, type == "assistant", let blocks = message?["content"] as? [[String: Any]] {
            noteAsks(in: blocks, stop: message?["stop_reason"] as? String, at: when)
        }
        if type == "user", json["isMeta"] as? Bool != true, let message {
            if !followsSidechain { noteResults(in: message["content"]) }
            switch Self.prompt(in: message["content"]) {
            case .prompt:
                let start = when ?? Date()
                working = true
                turnStart = start
                lastTool = nil
                // Hai scritto: quello che chiedeva ha avuto la sua risposta.
                ask = nil
                turnAsk = nil
                openTools.removeAll()
                return .started(start)
            case .interrupted:
                ask = nil
                turnAsk = nil
                openTools.removeAll()
                return finish(at: when)
            case .other:
                // Un sotto-agente di un flusso ha consegnato il suo risultato: ha finito. Se la consegna è stata respinta
                // (`is_error`, per esempio uno schema sbagliato) riprova, e lavora ancora.
                if followsSidechain, working, lastTool == "StructuredOutput",
                   let blocks = message["content"] as? [[String: Any]],
                   blocks.contains(where: { $0["type"] as? String == "tool_result" && $0["is_error"] as? Bool != true }) {
                    return finish(at: when)
                }
                return nil
            }
        }
        if type == "assistant", working, let message, let stop = message["stop_reason"] as? String {
            // Nella sessione conta solo la fine del turno. Un sotto-agente finisce anche con un errore dell'API
            // (`stop_sequence`) o col limite di token: tutto tranne la richiesta di uno strumento.
            if stop == "end_turn" || (followsSidechain && stop != "tool_use" && stop != "pause_turn") {
                return finish(at: when)
            }
            // Un errore dell'API (rete assente, server irraggiungibile) chiude il turno anche nella sessione: Claude scrive
            // una risposta sua con `isApiErrorMessage` (`stop_sequence`) e si ferma. Prima l'isola restava al lavoro per
            // dieci minuti. Se chiede uno strumento (connessione persa a metà risposta) riprova da sé: lavora ancora.
            if json["isApiErrorMessage"] as? Bool == true, stop != "tool_use", stop != "pause_turn" {
                return finish(at: when)
            }
        }
        return nil
    }

    /// Le domande dentro una risposta dell'agente: la scheda di domanda, il piano da approvare, il riquadro di fine
    /// turno; e, a turno finito, la domanda con cui si chiude il testo.
    private mutating func noteAsks(in blocks: [[String: Any]], stop: String?, at when: Date?) {
        for block in blocks where block["type"] as? String == "tool_use" {
            guard let id = block["id"] as? String, let name = block["name"] as? String else { continue }
            let input = block["input"] as? [String: Any] ?? [:]
            if !openTools.contains(where: { $0.id == id }) {
                openTools.append(OpenTool(id: id, name: name, summary: AgentAsk.describe(tool: name, input: input)))
                if openTools.count > 32 { openTools.removeFirst(openTools.count - 32) }
            }
            switch name {
            case "AskUserQuestion":
                let questions = input["questions"] as? [[String: Any]] ?? []
                let labels = (questions.first?["options"] as? [[String: Any]] ?? []).compactMap { $0["label"] as? String }
                ask = AgentAsk(kind: .question, text: questions.first?["question"] as? String ?? "", options: labels,
                               count: max(1, questions.count), toolUseID: id, at: when)
            case "ExitPlanMode":
                ask = AgentAsk(kind: .plan, text: "", toolUseID: id, at: when)
            default:
                // Il riquadro di fine turno dell'app di Claude (`mcp__ccd_turn__wrap_up`): la domanda e i suoi pulsanti
                // di risposta. Senza pulsanti di risposta non è una richiesta da mostrare (carpa, 19 novembre 2026:
                // «si attivi solo quando chiede qualcosa coi pulsanti»).
                guard name.hasSuffix("__wrap_up"),
                      let question = (input["ask"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !question.isEmpty
                else { continue }
                let labels = (input["actions"] as? [[String: Any]] ?? []).compactMap { $0["label"] as? String }
                    .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
                guard !labels.isEmpty else { continue }
                turnAsk = AgentAsk(kind: .followUp, text: String(question.prefix(400)), options: labels, at: when)
            }
        }
        guard stop == "end_turn" else { return }
        // Il turno è finito: vale la domanda del riquadro, quella coi pulsanti. Una domanda scritta solo nel testo non
        // ha pulsanti, e l'isola la lascia stare.
        if let turnAsk { ask = turnAsk }
    }

    /// I risultati degli strumenti: chi è tornato non aspetta più, e se era una domanda ha avuto la sua risposta.
    private mutating func noteResults(in content: Any?) {
        guard let blocks = content as? [[String: Any]] else { return }
        for block in blocks where block["type"] as? String == "tool_result" {
            guard let id = block["tool_use_id"] as? String else { continue }
            openTools.removeAll { $0.id == id }
            if ask?.toolUseID == id { ask = nil }
        }
    }

    private mutating func finish(at when: Date?) -> Change? {
        guard working else { return nil }
        let end = when ?? Date()
        let duration = turnStart.map { end.timeIntervalSince($0) } ?? 0
        working = false
        return .ended(end, duration: max(0, duration))
    }

    enum PromptKind { case prompt, interrupted, other }

    /// Un messaggio tuo apre un turno; i risultati degli strumenti e i messaggi di servizio no.
    static func prompt(in content: Any?) -> PromptKind {
        func classify(_ text: String) -> PromptKind {
            let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if t.hasPrefix("[Request interrupted") { return .interrupted }
            if t.isEmpty || t.hasPrefix("<local-command") || t.hasPrefix("<command-") || t.hasPrefix("Caveat:")
                || t.hasPrefix("<system-reminder>") { return .other }
            return .prompt
        }
        if let text = content as? String { return classify(text) }
        guard let blocks = content as? [[String: Any]] else { return .other }
        if blocks.contains(where: { $0["type"] as? String == "tool_result" }) { return .other }
        let texts = blocks.filter { $0["type"] as? String == "text" }.compactMap { $0["text"] as? String }
        if texts.contains(where: { classify($0) == .interrupted }) { return .interrupted }
        if texts.contains(where: { classify($0) == .prompt }) { return .prompt }
        // Un messaggio con solo un'immagine è comunque un messaggio tuo.
        return blocks.contains(where: { $0["type"] as? String == "image" }) ? .prompt : .other
    }
}
