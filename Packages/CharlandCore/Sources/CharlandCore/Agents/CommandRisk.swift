import Foundation

/// Quanto rischia un comando che un agente chiede di eseguire.
/// È deciso a regole, non da un modello: un modello piccolo può dire "rischio basso"
/// di `curl … | sh` (provato). Il modello spiega cosa fa il comando, le regole dicono quanto rischia.
public enum CommandRisk {
    public enum Level: Int, Sendable, Comparable, CaseIterable {
        case low = 0
        case medium = 1
        case high = 2
        public static func < (a: Level, b: Level) -> Bool { a.rawValue < b.rawValue }
    }

    /// Comandi che non cambiano niente.
    static let readOnly: Set<String> = [
        "ls", "cat", "head", "tail", "grep", "rg", "find", "pwd", "echo", "which", "wc", "sort", "uniq", "diff", "file", "stat",
        "du", "df", "ps", "top", "date", "whoami", "env", "printenv", "tree", "less", "more", "jq", "awk", "sed", "cut", "tr",
        "xcodebuild", "swift", "make", "cargo", "go", "tsc", "eslint", "prettier", "pytest", "jest", "vitest", "node", "python",
        "python3", "ruby", "open", "say", "sw_vers", "uname", "xcrun", "xcodegen", "test", "true", "false", "cd", "sleep",
    ]

    /// Comandi che ne lanciano un altro: il rischio è quello del comando lanciato.
    static let launchers: Set<String> = ["env", "nice", "nohup", "time", "command", "builtin", "exec", "caffeinate", "xargs"]

    public static func assess(_ command: String) -> Level {
        let text = command.lowercased()
        var level = Level.low

        func has(_ pattern: String) -> Bool {
            text.range(of: pattern, options: .regularExpression) != nil
        }

        // Rischio alto: cose che non si disfano, o che eseguono codice arrivato dalla rete.
        let high = [
            #"(curl|wget|fetch)\b[^|;&]*\|\s*(sudo\s+)?(ba|z|fi)?sh\b"#,          // scarica ed esegue
            #"\bsudo\b"#,
            // cancella fuori dal progetto: anche `/*`, `"$HOME"` e `${HOME}/`
            #"\brm\s+(-[a-z]*r[a-z]*f|-[a-z]*f[a-z]*r|-r\s+-f|-f\s+-r)[a-z]*\s+["']?(/|~|\$\{?home\}?|\.\.|\*)["']?(\s|/|\*|$)"#,
            #"\bshred\b"#,
            #"\bsimctl\s+(erase|delete)\b"#,                                      // svuota o cancella i simulatori
            #"\bgit\s+push\b[^;&|]*(--force|-f\b|--force-with-lease)"#,
            #"\bgit\s+(reset\s+--hard|clean\s+-[a-z]*f|checkout\s+--\s|branch\s+-d)"#,
            #"\bgit\s+filter-(branch|repo)\b"#,
            #"\b(dd|mkfs|diskutil\s+(erase|partition)|fdisk)\b"#,
            #"\bchmod\s+(-r\s+)?(777|a\+rwx)"#,
            #"\bchown\s+-r\b"#,
            #":\(\)\s*\{"#,                                                       // fork bomb
            #">\s*/dev/(sd|disk|rdisk)"#,
            #"\b(drop\s+(table|database)|truncate\s+table|delete\s+from)\b"#,
            #"\b(npm|pnpm|yarn)\s+publish\b|\bcargo\s+publish\b|\bgem\s+push\b"#,
            #"\b(vercel|wrangler)\b[^;&|]*(--prod|deploy)"#,
            #"\bsecurity\s+(delete|dump|find-generic-password|find-internet-password)"#,
            #"\bdefaults\s+delete\b|\blaunchctl\s+(unload|remove|bootout)"#,
            #"\b(shutdown|reboot|halt)\b"#,
            #"\bkillall\b|\bpkill\s+-9"#,
            #"\.(ssh|aws|gnupg)/|\bid_(rsa|ed25519)\b|\.env\b[^;&|]*(curl|nc|scp)"#,
        ]
        if high.contains(where: has) { return .high }

        // Rischio medio: cambia file, installa, manda qualcosa fuori.
        let medium = [
            #"\brm\b"#, #"\bmv\b"#, #"\bgit\s+(push|commit|merge|rebase|stash|pull|checkout|switch|restore|tag|add)\b"#,
            #"\b(npm|pnpm|yarn|bun)\s+(install|add|remove|uninstall|update|i)\b"#, #"\b(pip|pip3|uv)\s+(install|uninstall)\b"#,
            #"\bbrew\s+(install|uninstall|upgrade|tap)\b"#, #"\b(curl|wget|scp|rsync|ssh|nc)\b"#, #"\bgh\s+(pr|issue|release|repo)\s+(create|merge|close|delete|edit)"#,
            #"\bdocker\s+(run|rm|rmi|compose|build|push)\b"#, #"\bchmod\b|\bchown\b"#, #"\bdefaults\s+write\b"#,
            #"\b(kill|pkill)\b"#, #">\s*[^&\s]"#, #"\btee\b"#, #"\bsed\s+-i\b"#, #"\bosascript\b"#, #"\blaunchctl\b"#,
            #"^(edit|write|multiedit|notebookedit)\b"#,
            // Comandi «di sola lettura» che cambiano o cancellano, e comandi dentro un altro comando: fino al
            // 19 novembre 2026 si guardava solo la prima parola e `find . -delete` usciva a rischio basso.
            #"\bfind\b[^;&|]*\s-(delete|exec|execdir|ok|okdir)\b"#, #"\bsed\b[^;&|]*\s(-[a-z]*i[a-z]*\b|--in-place)"#,
            #"\$\("#, "`", #"\bsimctl\s+(uninstall|install|terminate|privacy|keychain)\b"#,
        ]
        if medium.contains(where: has) { level = .medium }

        // Se ogni pezzo del comando è di sola lettura, il rischio è basso; altrimenti, nel dubbio, medio.
        if level == .low {
            let pieces = text.components(separatedBy: CharacterSet(charactersIn: ";|&\n")).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            let allKnown = pieces.allSatisfy { piece in
                // `FOO=1 comando`, `env FOO=1 comando`, `nice -n 5 comando`: conta il comando vero, non chi lo lancia.
                var parts = piece.split(separator: " ").map(String.init)
                while let head = parts.first {
                    if head.range(of: #"^[a-z_][a-z0-9_]*="#, options: .regularExpression) != nil {
                        parts.removeFirst()
                    } else if launchers.contains((head as NSString).lastPathComponent), parts.count > 1 {
                        parts.removeFirst()
                        while let option = parts.first, option.hasPrefix("-") || Int(option) != nil { parts.removeFirst() }
                    } else {
                        break
                    }
                }
                // solo assegnazioni, o il lanciatore da solo con le sue opzioni
                guard let first = parts.first else { return true }
                let piece = parts.joined(separator: " ")
                let name = (first as NSString).lastPathComponent
                if name == "git" {
                    return piece.range(of: #"^git\s+(status|diff|log|show|branch(\s|$)|remote\s+-v|rev-parse|describe|blame|ls-files)"#, options: .regularExpression) != nil
                }
                if ["read", "glob", "grep", "ls", "webfetch", "websearch", "task", "todowrite"].contains(name) { return true }
                return readOnly.contains(name)
            }
            if !allKnown { level = .medium }
        }
        return level
    }
}
