import Foundation

/// Quello che serve sapere di un registro di un agente, qualunque agente sia.
public protocol AgentLogTracker: Sendable {
    init()
    /// Per il registro di un sotto-agente: chi non li distingue lo legge come gli altri.
    init(sidechainLog: Bool)
    var sessionID: String? { get }
    var project: String? { get }
    var working: Bool { get }
    var turnStart: Date? { get }
    var lastActivity: Date? { get }
    /// Quello che l'agente sta chiedendo adesso, se il registro lo dice.
    var ask: AgentAsk? { get }
    /// Gli strumenti chiesti e non ancora tornati.
    var openTools: [TranscriptTracker.OpenTool] { get }
    mutating func feed(_ line: Data) -> TranscriptTracker.Change?
}

extension AgentLogTracker {
    public init(sidechainLog: Bool) { self.init() }
    public var openTools: [TranscriptTracker.OpenTool] { [] }
}

extension TranscriptTracker: AgentLogTracker {}

/// Segue un turno di Codex (ChatGPT) leggendo il registro che Codex scrive da sé
/// (`~/.codex/sessions/AAAA/MM/GG/rollout-*.jsonl`): lo usano sia il terminale sia l'app Codex.
/// Il registro segna l'inizio e la fine del turno in modo esplicito (`task_started`, `task_complete`).
public struct CodexTracker: AgentLogTracker {
    public private(set) var sessionID: String?
    public private(set) var cwd: String?
    public private(set) var working = false
    public private(set) var turnStart: Date?
    public private(set) var lastActivity: Date?
    /// Il registro di Codex non porta richieste coi pulsanti: niente da mostrare.
    public var ask: AgentAsk? { nil }

    public init() {}

    public var project: String? {
        cwd.map { ($0 as NSString).lastPathComponent }.flatMap { $0.isEmpty ? nil : $0 }
    }

    public mutating func feed(_ line: Data) -> TranscriptTracker.Change? {
        guard !line.isEmpty, let json = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { return nil }
        let when = TranscriptTracker.date(json["timestamp"])
        if let when { lastActivity = max(lastActivity ?? when, when) }
        let type = json["type"] as? String
        let payload = json["payload"] as? [String: Any] ?? [:]
        if type == "session_meta" || type == "turn_context" {
            if let path = payload["cwd"] as? String, !path.isEmpty { cwd = path }
            if type == "session_meta", let id = (payload["session_id"] as? String) ?? (payload["id"] as? String) { sessionID = id }
            return nil
        }
        guard type == "event_msg" else { return nil }
        switch payload["type"] as? String {
        case "task_started":
            let start = when ?? Date()
            working = true
            turnStart = start
            return .started(start)
        case "task_complete", "turn_aborted":
            guard working else { return nil }
            let end = when ?? Date()
            working = false
            return .ended(end, duration: max(0, end.timeIntervalSince(turnStart ?? end)))
        default:
            return nil
        }
    }
}
