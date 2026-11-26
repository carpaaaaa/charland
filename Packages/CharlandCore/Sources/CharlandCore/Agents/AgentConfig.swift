import Foundation

/// Collega un agente a Charland aggiungendo i suoi ganci al file di configurazione dell'agente.
/// È pura: riceve il testo attuale del file e restituisce il testo nuovo, così l'app può
/// mostrare le differenze esatte prima di scrivere. Non tocca mai le altre impostazioni.
public enum AgentConfig {
    /// L'evento di Claude Code che serve all'isola, per rispondere da lì: `PermissionRequest`. Scatta nel momento in
    /// cui Claude chiede qualcosa a chi usa il Mac (un comando da approvare, ma anche una scheda di domanda) e corre
    /// insieme alla richiesta dell'app: chi risponde prima vince, quindi l'isola non blocca mai la finestra di Claude.
    /// La decisione di questo gancio è un canale previsto da Claude Code, e vale come la tua.
    /// Tutto il resto (chi lavora, chi ha finito, vedere le richieste) Charland lo legge da sé, senza ganci.
    ///
    /// Niente gancio a fine turno. Il 19 novembre 2026 ce n'è stato uno (`Stop` con `asyncRewake`) che, premuta
    /// nell'isola una risposta del riquadro di fine turno, risvegliava Claude con quella risposta: Claude Code la
    /// consegna però come «evento automatico, NON un messaggio dell'utente, da non prendere per una conferma», e
    /// Claude giustamente non la accetta come risposta tua. È una protezione, non un difetto da aggirare.
    public static let claudeEvents = ["PermissionRequest"]

    /// Gli eventi che le versioni precedenti collegavano: i loro ganci si tolgono quando ci si ricollega.
    static let retiredEvents = ["PreToolUse", "Notification", "Stop", "StopFailure", "SessionStart", "SessionEnd", "UserPromptSubmit"]

    /// Su quali strumenti scatta il gancio di un evento: tutti.
    public static func matcher(for event: String) -> String { "" }

    /// Le opzioni del gancio di un evento.
    static func options(for event: String) -> [String: Any] {
        switch event {
        // La richiesta di permesso aspetta la tua risposta: le si dà tutto il tempo dei ganci.
        case "PermissionRequest": ["timeout": 600]
        default: [:]
        }
    }

    public enum Failure: Error, Equatable {
        /// Il file esiste ma non è JSON valido: non lo si tocca.
        case unreadable
    }

    /// Il comando del gancio. Il percorso è fra virgolette perché può avere spazi. Se il comando non c'è più (l'app
    /// buttata nel cestino senza scollegare) il gancio esce subito con 0, cioè «nessuna decisione»: Claude Code va
    /// avanti come senza ganci, invece di segnalare un errore a ogni permesso. Con `exec` il codice d'uscita resta
    /// quello di `charland`.
    public static func hookCommand(cliPath: String, agent: String) -> String {
        "[ -x \"\(cliPath)\" ] || exit 0; exec \"\(cliPath)\" hook \(agent)"
    }

    static func isOurs(_ command: String) -> Bool {
        command.contains("/charland\" hook ") || command.contains("/charland hook ")
    }

    /// Aggiunge i ganci di Charland. Se ci sono già (anche con un altro percorso, o su eventi che non servono più) li
    /// toglie e li rimette giusti. Del file cambia solo la voce `hooks`: il resto resta com'era, carattere per carattere.
    public static func connect(existing: String?, cliPath: String, agent: String = "claude",
                               events: [String] = claudeEvents) throws -> String {
        let root = try parse(existing)
        var hooks = strip(root["hooks"] as? [String: Any] ?? [:])
        let command = hookCommand(cliPath: cliPath, agent: agent)
        for event in events {
            var groups = hooks[event] as? [[String: Any]] ?? []
            var entry: [String: Any] = ["type": "command", "command": command]
            entry.merge(options(for: event)) { _, new in new }
            groups.append(["matcher": matcher(for: event), "hooks": [entry]])
            hooks[event] = groups
        }
        return try splice(hooks: hooks, into: existing, root: root)
    }

    /// I ganci ci sono, ma non sono quelli di adesso: un altro percorso del comando (l'app è stata spostata) o gli
    /// eventi di una versione precedente. Ricollegando tornano giusti.
    public static func needsRepair(existing: String?, cliPath: String, agent: String = "claude") -> Bool {
        guard isConnected(existing: existing), let fresh = try? connect(existing: existing, cliPath: cliPath, agent: agent),
              let now = try? parse(existing), let then = try? parse(fresh) else { return false }
        return !(now as NSDictionary).isEqual(to: then)
    }

    /// Toglie i ganci di Charland e lascia tutto il resto com'era.
    public static func disconnect(existing: String?) throws -> String {
        let root = try parse(existing)
        guard let all = root["hooks"] as? [String: Any] else { return try splice(hooks: nil, into: existing, root: root, untouched: true) }
        let hooks = strip(all)
        return try splice(hooks: hooks.isEmpty ? nil : hooks, into: existing, root: root)
    }

    /// I ganci senza quelli di Charland, evento per evento; un evento rimasto senza ganci sparisce.
    private static func strip(_ hooks: [String: Any]) -> [String: Any] {
        var hooks = hooks
        for (event, value) in hooks {
            guard let list = value as? [[String: Any]] else { continue }
            let groups = list.compactMap { withoutOurs($0) }
            hooks[event] = groups.isEmpty ? nil : groups
        }
        return hooks
    }

    public static func isConnected(existing: String?) -> Bool {
        guard let root = try? parse(existing), let hooks = root["hooks"] as? [String: Any] else { return false }
        return hooks.values.contains { value in
            (value as? [[String: Any]] ?? []).contains { group in
                (group["hooks"] as? [[String: Any]] ?? []).contains { isOurs($0["command"] as? String ?? "") }
            }
        }
    }

    /// Le righe che cambiano fra il file di adesso e quello nuovo, con "+" e "-" davanti.
    public static func diff(old: String?, new: String) -> [String] {
        let a = (old ?? "").components(separatedBy: "\n")
        let b = new.components(separatedBy: "\n")
        // Sottosequenza comune più lunga: i file di configurazione sono piccoli.
        var table = Array(repeating: Array(repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in stride(from: a.count - 1, through: 0, by: -1) {
            for j in stride(from: b.count - 1, through: 0, by: -1) {
                table[i][j] = a[i] == b[j] ? table[i + 1][j + 1] + 1 : max(table[i + 1][j], table[i][j + 1])
            }
        }
        var out: [String] = []
        var i = 0, j = 0
        while i < a.count, j < b.count {
            if a[i] == b[j] {
                i += 1
                j += 1
            } else if table[i + 1][j] >= table[i][j + 1] {
                out.append("- " + a[i])
                i += 1
            } else {
                out.append("+ " + b[j])
                j += 1
            }
        }
        while i < a.count { out.append("- " + a[i]); i += 1 }
        while j < b.count { out.append("+ " + b[j]); j += 1 }
        return out.filter { $0 != "- " && $0 != "+ " }
    }

    private static func withoutOurs(_ group: [String: Any]) -> [String: Any]? {
        var group = group
        let kept = (group["hooks"] as? [[String: Any]] ?? []).filter { !isOurs($0["command"] as? String ?? "") }
        if kept.isEmpty { return nil }
        group["hooks"] = kept
        return group
    }

    private static func parse(_ text: String?) throws -> [String: Any] {
        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [:] }
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw Failure.unreadable }
        return object
    }

    // MARK: Il testo del file

    /// Mette (o toglie, con `nil`) la voce `hooks` nel testo del file senza riscrivere il resto: chi ha ordinato e
    /// impaginato le sue impostazioni le ritrova uguali, e le differenze mostrate prima di scrivere sono solo i ganci.
    /// Se il testo non si lascia innestare (non dovrebbe succedere con un JSON valido) si riscrive il file intero.
    private static func splice(hooks: [String: Any]?, into existing: String?, root: [String: Any], untouched: Bool = false) throws -> String {
        let text = existing ?? ""
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            guard let hooks else { return "{}\n" }
            return "{\n  \"hooks\": " + pretty(hooks, indent: "  ") + "\n}\n"
        }
        if untouched { return text }
        if let spliced = spliceText(hooks: hooks, into: text) { return spliced }
        var root = root
        root["hooks"] = hooks
        let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        return String(decoding: data, as: UTF8.self) + "\n"
    }

    /// Un membro dell'oggetto di primo livello, come posizioni nel testo.
    private struct Member {
        var key: String
        var start: Int
        var valueStart: Int
        var valueEnd: Int
    }

    private static func spliceText(hooks: [String: Any]?, into text: String) -> String? {
        let bytes = Array(text.utf8)
        var i = 0
        func skipSpace() { while i < bytes.count, [0x20, 0x09, 0x0A, 0x0D].contains(bytes[i]) { i += 1 } }
        /// Salta una stringa (con le sue sequenze di escape) e ne restituisce il testo grezzo.
        func string() -> String? {
            guard i < bytes.count, bytes[i] == 0x22 else { return nil }
            let begin = i
            i += 1
            while i < bytes.count {
                if bytes[i] == 0x5C { i += 2; continue }
                if bytes[i] == 0x22 {
                    i += 1
                    let raw = Data(bytes[begin..<i])
                    return (try? JSONSerialization.jsonObject(with: raw, options: [.fragmentsAllowed])) as? String
                }
                i += 1
            }
            return nil
        }
        /// Salta un valore qualsiasi.
        func value() -> Bool {
            guard i < bytes.count else { return false }
            switch bytes[i] {
            case 0x22:
                return string() != nil
            case 0x7B, 0x5B:
                var depth = 0
                while i < bytes.count {
                    switch bytes[i] {
                    case 0x22: if string() == nil { return false }; continue
                    case 0x7B, 0x5B: depth += 1
                    case 0x7D, 0x5D:
                        depth -= 1
                        if depth == 0 { i += 1; return true }
                    default: break
                    }
                    i += 1
                }
                return false
            default:
                let begin = i
                while i < bytes.count, ![0x2C, 0x7D, 0x5D, 0x20, 0x09, 0x0A, 0x0D].contains(bytes[i]) { i += 1 }
                return i > begin
            }
        }

        skipSpace()
        guard i < bytes.count, bytes[i] == 0x7B else { return nil }
        let open = i
        i += 1
        var members: [Member] = []
        var close = -1
        while true {
            skipSpace()
            guard i < bytes.count else { return nil }
            if bytes[i] == 0x7D { close = i; break }
            let start = i
            guard let key = string() else { return nil }
            skipSpace()
            guard i < bytes.count, bytes[i] == 0x3A else { return nil }
            i += 1
            skipSpace()
            let valueStart = i
            guard value() else { return nil }
            members.append(Member(key: key, start: start, valueStart: valueStart, valueEnd: i))
            skipSpace()
            guard i < bytes.count else { return nil }
            if bytes[i] == 0x2C { i += 1; continue }
            if bytes[i] == 0x7D { close = i; break }
            return nil
        }
        func slice(_ range: Range<Int>) -> String { String(decoding: bytes[range], as: UTF8.self) }
        // Il rientro del file: gli spazi davanti alla prima voce.
        var indent = "  "
        if let first = members.first {
            var j = first.start
            while j > open + 1, bytes[j - 1] == 0x20 || bytes[j - 1] == 0x09 { j -= 1 }
            if j > 0, bytes[j - 1] == 0x0A { indent = slice(j..<first.start) }
        }
        let index = members.firstIndex { $0.key == "hooks" }
        if let hooks {
            let body = pretty(hooks, indent: indent)
            if let index {
                let m = members[index]
                return slice(0..<m.valueStart) + body + slice(m.valueEnd..<bytes.count)
            }
            if let last = members.last {
                return slice(0..<last.valueEnd) + ",\n" + indent + "\"hooks\": " + body + slice(last.valueEnd..<bytes.count)
            }
            return slice(0..<open + 1) + "\n" + indent + "\"hooks\": " + body + "\n" + slice(close..<bytes.count)
        }
        guard let index else { return text }
        let m = members[index]
        if index + 1 < members.count {
            // Via la voce con la sua virgola, fino all'inizio della voce dopo.
            return slice(0..<m.start) + slice(members[index + 1].start..<bytes.count)
        }
        if index > 0 {
            // Era l'ultima: via anche la virgola che la precede.
            return slice(0..<members[index - 1].valueEnd) + slice(m.valueEnd..<bytes.count)
        }
        return slice(0..<open + 1) + slice(close..<bytes.count)
    }

    /// Un valore JSON impaginato come fa Claude Code: due punti attaccati alla chiave, chiavi in ordine, rientri del file.
    private static func pretty(_ value: Any, indent: String, level: Int = 1) -> String {
        let pad = String(repeating: indent, count: level)
        let inner = String(repeating: indent, count: level + 1)
        if let object = value as? [String: Any] {
            if object.isEmpty { return "{}" }
            let lines = object.keys.sorted().map { inner + quote($0) + ": " + pretty(object[$0]!, indent: indent, level: level + 1) }
            return "{\n" + lines.joined(separator: ",\n") + "\n" + pad + "}"
        }
        if let array = value as? [Any] {
            if array.isEmpty { return "[]" }
            return "[\n" + array.map { inner + pretty($0, indent: indent, level: level + 1) }.joined(separator: ",\n") + "\n" + pad + "]"
        }
        if let text = value as? String { return quote(text) }
        if let number = value as? NSNumber {
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return number.boolValue ? "true" : "false" }
            return number.stringValue
        }
        if value is NSNull { return "null" }
        return "null"
    }

    private static func quote(_ text: String) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: text, options: [.fragmentsAllowed, .withoutEscapingSlashes])) ?? Data("\"\"".utf8)
        return String(decoding: data, as: UTF8.self)
    }
}
