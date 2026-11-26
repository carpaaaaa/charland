import Foundation

/// Una cosa che un agente chiede a chi usa il Mac, letta dal registro della sessione o dal suo stato: Charland la
/// mostra nell'isola anche senza ganci collegati (carpa, 19 novembre 2026: «deve funzionare sempre»).
public struct AgentAsk: Sendable, Equatable {
    public enum Kind: String, Sendable, Equatable {
        /// Una scheda di domanda con le sue scelte (`AskUserQuestion`): il turno è fermo finché non rispondi.
        case question
        /// Un piano pronto da approvare (`ExitPlanMode`).
        case plan
        /// Uno strumento che aspetta il permesso.
        case permission
        /// Il turno è finito con una domanda coi pulsanti: il riquadro di fine turno dell'app di Claude.
        case followUp
    }

    public var kind: Kind
    /// La domanda, o il comando che aspetta il permesso. Vuoto se non si sa.
    public var text: String
    /// Le scelte proposte, se ci sono.
    public var options: [String]
    /// Quante domande porta la scheda (di solito una).
    public var count: Int
    /// Lo strumento che ha fatto la domanda: quando torna il suo risultato, la domanda è chiusa.
    public var toolUseID: String?
    /// Quando è stata fatta, dal registro.
    public var at: Date?

    public init(kind: Kind, text: String, options: [String] = [], count: Int = 1, toolUseID: String? = nil, at: Date? = nil) {
        self.kind = kind
        self.text = text
        self.options = options
        self.count = count
        self.toolUseID = toolUseID
        self.at = at
    }

    /// La domanda con cui finisce un testo, se finisce con una domanda: l'ultima frase dell'ultimo paragrafo, ripulita
    /// dalla marcatura. Un testo che finisce dentro un blocco di codice non è una domanda.
    public static func closingQuestion(in text: String) -> String? {
        let lines = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        guard let index = lines.lastIndex(where: { !$0.isEmpty }) else { return nil }
        // Un numero dispari di recinti di codice prima dell'ultima riga: è codice.
        let fences = lines[..<index].filter { $0.hasPrefix("```") }.count
        if fences % 2 == 1 || lines[index].hasPrefix("```") { return nil }
        var last = lines[index]
        // La marcatura in coda (grassetto, corsivo, virgolette, parentesi) non conta.
        while let tail = last.last, "*_`\"'»”)] ".contains(tail) { last.removeLast() }
        guard last.hasSuffix("?") || last.hasSuffix("？") else { return nil }
        // La marcatura in testa: titoli, elenchi, citazioni.
        while let head = last.first, "#>-*•_ ".contains(head) { last.removeFirst() }
        last = last.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "__", with: "")
            .replacingOccurrences(of: "`", with: "")
        // L'ultima frase: dopo l'ultimo punto fermo seguito da uno spazio (l'ultimo carattere è il punto di domanda).
        let body = last.dropLast()
        var start = body.startIndex
        var i = body.startIndex
        while i < body.endIndex {
            let next = body.index(after: i)
            if ".!?…".contains(body[i]), next < body.endIndex, body[next] == " " { start = body.index(after: next) }
            i = next
        }
        let sentence = last[start...].trimmingCharacters(in: .whitespaces)
        // Una frase di una parola sola («Ok?») dice poco: allora tutta la riga.
        let chosen = sentence.count >= 12 ? sentence : last
        guard chosen.count >= 2 else { return nil }
        return String(chosen.prefix(400))
    }

    /// Il comando di uno strumento in una riga, come lo vedrebbe chi lo approva.
    public static func describe(tool: String, input: [String: Any]) -> String {
        let text: String
        if let command = input["command"] as? String {
            text = command
        } else if let path = input["file_path"] as? String {
            text = "\(tool) \(path)"
        } else if let url = input["url"] as? String {
            text = "\(tool) \(url)"
        } else {
            text = tool
        }
        let cleaned = text.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\t", with: " ")
        return String(cleaned.filter { $0.unicodeScalars.allSatisfy { $0.value >= 0x20 } }.prefix(300))
    }
}

/// Una sessione di Claude Code come la scrive Claude stesso in `~/.claude/sessions/<processo>.json`: chi è, e se sta
/// lavorando, è ferma o aspetta te. Charland la legge soltanto.
public struct ClaudeSessionRecord: Sendable, Equatable {
    public var pid: Int32
    public var sessionID: String
    /// `idle`, `busy` oppure `waiting`.
    public var status: String?
    /// Con `waiting`: cosa aspetta («permission prompt», «input needed», «sandbox request», «dialog open»…).
    public var waitingFor: String?
    /// Quando è cambiato lo stato, in secondi dal 1970.
    public var statusUpdatedAt: Double?
    public var cwd: String?
    /// Da dove gira: `claude-desktop` per l'app di Claude, `cli` per il terminale, `claude-vscode`…
    public var entrypoint: String?
    /// Nell'app di Claude: l'identificativo della sessione nell'app (`local_…`), per aprirla con il suo indirizzo.
    public var hostSessionID: String?
    public var name: String?

    public init?(json data: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let pid = object["pid"] as? Int, let session = object["sessionId"] as? String, !session.isEmpty else { return nil }
        self.pid = Int32(pid)
        sessionID = session
        status = object["status"] as? String
        waitingFor = object["waitingFor"] as? String
        statusUpdatedAt = (object["statusUpdatedAt"] as? Double).map { $0 / 1000 }
        cwd = object["cwd"] as? String
        entrypoint = object["entrypoint"] as? String
        hostSessionID = object["hostSessionId"] as? String
        name = object["name"] as? String
    }

    /// Aspetta te: un permesso, una risposta.
    public var isWaiting: Bool { status == "waiting" }

    /// L'indirizzo che apre questa sessione nell'app di Claude, se gira lì.
    public var desktopLink: URL? {
        guard let host = hostSessionID, host.hasPrefix("local_"), host.count <= 70,
              host.dropFirst(6).allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }) else { return nil }
        return URL(string: "claude://code/continue?session=\(host)")
    }
}
