import Foundation

/// Un processo di Claude Code acceso: la sessione, quando è scritta negli argomenti, e la cartella del registro che
/// corrisponde alla sua cartella di lavoro (`~/.claude/projects/<cartella>`).
public struct ClaudeProcess: Sendable, Equatable {
    public var sessionID: String?
    public var projectDir: String

    public init(sessionID: String?, projectDir: String) {
        self.sessionID = sessionID
        self.projectDir = projectDir
    }
}

/// Se una sessione di Claude Code è ancora viva. Il registro dice solo come è andato il turno: se Claude viene chiuso a
/// metà (finestra chiusa, sessione fermata, Mac riavviato) la fine del turno non arriva mai e l'isola lo mostrava al
/// lavoro per dieci minuti (carpa, 18 novembre 2026: «nella dynamic island continua a lavorare anche se non sta
/// lavorando e Claude è chiuso»). Claude non tiene aperto il registro: la prova di vita sono i suoi processi.
public enum ClaudeLiveness {
    /// Il nome della cartella dei registri per una cartella di lavoro: Claude Code mette «-» al posto di ogni carattere
    /// che non è una lettera o una cifra (`/Users/alice/Desktop` diventa `-Users-alice-Desktop`).
    public static func projectDir(forCwd cwd: String) -> String {
        String(cwd.unicodeScalars.map { scalar -> Character in
            let ascii = scalar.isASCII && (CharacterSet.alphanumerics.contains(scalar))
            return ascii ? Character(scalar) : "-"
        })
    }

    /// È Claude Code: l'eseguibile si chiama `claude` (app di Claude, editor, installazione a sé, dove il file vero può
    /// chiamarsi col numero di versione ma il nome con cui parte resta `claude`), oppure Node che fa girare il pacchetto.
    public static func isClaude(executable: String, arguments: [String]) -> Bool {
        if (executable as NSString).lastPathComponent == "claude" { return true }
        if let first = arguments.first, (first as NSString).lastPathComponent == "claude" { return true }
        if executable.contains("/claude/versions/") { return true }
        return arguments.prefix(3).contains { $0.contains("@anthropic-ai/claude-code") || $0.contains("/claude-code/cli") }
    }

    /// La sessione scritta negli argomenti: `--resume=<id>`, `--resume <id>`, `-r <id>`, `--session-id <id>`. Con
    /// `--fork-session` il registro nuovo ha un altro nome, quindi nessuna: vale la cartella di lavoro.
    public static func sessionID(fromArguments arguments: [String]) -> String? {
        if arguments.contains("--fork-session") { return nil }
        var index = arguments.startIndex
        while index < arguments.endIndex {
            let argument = arguments[index]
            for flag in ["--resume", "--session-id"] where argument.hasPrefix(flag + "=") {
                let value = String(argument.dropFirst(flag.count + 1))
                if looksLikeSession(value) { return value }
            }
            if ["--resume", "-r", "--session-id"].contains(argument), index + 1 < arguments.endIndex {
                let value = arguments[index + 1]
                if looksLikeSession(value) { return value }
            }
            index += 1
        }
        return nil
    }

    private static func looksLikeSession(_ value: String) -> Bool { UUID(uuidString: value) != nil }

    /// Viva se un processo ha proprio quella sessione negli argomenti. Altrimenti viva solo se nella stessa cartella c'è
    /// un processo senza sessione scritta (Claude da terminale, `--continue`): potrebbe essere lei. Un processo che ha
    /// un'altra sessione negli argomenti non la tiene viva: con tre sessioni nella stessa cartella, chiuderne una la
    /// toglie dall'isola anche se le altre lavorano.
    public static func isAlive(sessionID: String, projectDir: String, processes: [ClaudeProcess]) -> Bool {
        if processes.contains(where: { $0.sessionID == sessionID }) { return true }
        return processes.contains { $0.sessionID == nil && $0.projectDir == projectDir }
    }

    /// Sessione e cartella di un registro: `<cartella>/<sessione>.jsonl`, oppure quello di un sotto-agente
    /// `<cartella>/<sessione>/subagents/agent-*.jsonl`, che vive e muore con la sua sessione.
    public static func session(ofLog path: String) -> (sessionID: String, projectDir: String)? {
        let parts = (path as NSString).pathComponents
        if let sub = parts.lastIndex(of: "subagents"), sub >= 2 {
            return (parts[sub - 1], parts[sub - 2])
        }
        guard parts.count >= 2, path.hasSuffix(".jsonl") else { return nil }
        let name = ((parts[parts.count - 1]) as NSString).deletingPathExtension
        return (name, parts[parts.count - 2])
    }
}
