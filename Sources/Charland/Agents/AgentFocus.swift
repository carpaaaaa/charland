import AppKit
import ApplicationServices
import CharlandCore

/// Porta davanti la finestra dove lavora un agente (carpa, 18 novembre 2026: «se premi sulla mascotte ti porta nella
/// finestra dove Claude lavora, in primo piano»).
///
/// Si cerca il processo dell'agente (per Claude la sessione negli argomenti, per gli altri il nome e la cartella), poi
/// si risale ai suoi padri fino all'app con le finestre: l'app di Claude, il Terminale, iTerm, un editor. Nel Terminale e
/// in iTerm si sceglie anche la scheda giusta, dal terminale del processo; nelle altre app si porta su la finestra che
/// ha nel titolo il nome della cartella. Se il processo non si trova, si apre l'app da cui era arrivato l'agente.
/// L'app di Claude non ha un indirizzo per aprire una sessione precisa: si porta davanti la sua finestra.
@MainActor
enum AgentFocus {
    /// Una sessione dell'isola: «Claude:<registro>», «ChatGPT:<registro>», «api:<cliente>/<id>».
    static func bring(_ session: AgentSession) {
        let id = session.id
        guard let colon = id.firstIndex(of: ":") else { return }
        let path = String(id[id.index(after: colon)...])
        switch session.kind {
        case .claude:
            let log = ClaudeLiveness.session(ofLog: path)
            // Nell'app di Claude la sessione ha un indirizzo suo: si apre proprio quella conversazione.
            if let record = AgentAsks.shared.record(for: log?.sessionID), let link = record.desktopLink {
                DockLaunch.open(link)
                return
            }
            bring(kind: .claude, sessionID: log?.sessionID, projectDir: log?.projectDir, folder: session.project, origin: nil,
                  pid: AgentAsks.shared.record(for: log?.sessionID)?.pid)
        default:
            bring(kind: session.kind, sessionID: nil, projectDir: nil, folder: session.project, origin: nil)
        }
    }

    /// `pid`: il processo della sessione, quando lo si sa già (Claude lo scrive nel suo stato).
    static func bring(kind: AgentKind, sessionID: String?, projectDir: String?, folder: String?, origin: String?,
                      pid known: pid_t? = nil) {
        DispatchQueue.global(qos: .userInitiated).async {
            let pid: pid_t?
            switch kind {
            case .claude: pid = known ?? ClaudeProcesses.pid(claudeSession: sessionID, projectDir: projectDir, folder: folder)
            case .codex: pid = ClaudeProcesses.pid(named: "codex", folder: folder)
            case .gemini: pid = ClaudeProcesses.pid(named: "gemini", folder: folder)
            case .custom: pid = nil
            }
            let tty = pid.flatMap(ClaudeProcesses.tty)
            let host = pid.flatMap(hostPID)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    if let host, let app = NSRunningApplication(processIdentifier: host) {
                        show(app, tty: tty, folder: folder)
                    } else if let bundle = origin ?? fallbackBundle(kind) {
                        DockLaunch.open(bundle: bundle)
                    }
                }
            }
        }
    }

    /// Per le prove (`Charland --dove-agente <sessione> [cartella]`): dice cosa troverebbe, senza portare niente davanti.
    nonisolated static func describe(sessionID: String, folder: String?) -> String {
        guard let pid = ClaudeProcesses.pid(claudeSession: sessionID, projectDir: nil, folder: folder) else { return "nessun processo" }
        let host = hostPID(pid)
        let name = host.flatMap { NSRunningApplication(processIdentifier: $0)?.bundleIdentifier } ?? "-"
        return "processo \(pid), app \(name) (\(host.map(String.init) ?? "-")), terminale \(ClaudeProcesses.tty(pid) ?? "nessuno")"
    }

    /// Il primo padre che è un'app con le finestre (non un aiutante dell'app né la shell).
    private nonisolated static func hostPID(_ pid: pid_t) -> pid_t? {
        var current = pid
        for _ in 0..<12 {
            if let app = NSRunningApplication(processIdentifier: current), app.activationPolicy == .regular { return current }
            guard let parent = ClaudeProcesses.parent(current) else { return nil }
            current = parent
        }
        return nil
    }

    private static func fallbackBundle(_ kind: AgentKind) -> String? {
        switch kind {
        case .claude: "com.anthropic.claudefordesktop"
        case .codex: "com.openai.codex"
        default: nil
        }
    }

    private static func show(_ app: NSRunningApplication, tty: String?, folder: String?) {
        let bundle = app.bundleIdentifier ?? ""
        // Nel Terminale e in iTerm la scheda giusta, dal suo terminale: lo script porta anche davanti l'app.
        if let tty, let script = tabScript(bundle: bundle, tty: tty) {
            NSApp.activate()
            NSApp.yieldActivation(toApplicationWithBundleIdentifier: bundle)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", script]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try? process.run()
            // Se tutte le sue finestre erano ridotte nel Dock, una torna su.
            AppFront.restoreWindows(of: app)
            return
        }
        // Le altre app (l'app di Claude, ChatGPT, un editor): davanti come col clic sull'icona nel Dock, anche se era
        // ridotta, con su la finestra che ha nel titolo il nome della cartella.
        AppFront.bring(app, titled: folder)
    }

    private static func tabScript(bundle: String, tty: String) -> String? {
        let safe = tty.filter { $0.isLetter || $0.isNumber || $0 == "/" }
        switch bundle {
        case "com.apple.Terminal":
            return """
            tell application "Terminal"
              repeat with w in windows
                repeat with t in tabs of w
                  if tty of t is "\(safe)" then
                    set miniaturized of w to false
                    set selected of t to true
                    set index of w to 1
                    activate
                    return
                  end if
                end repeat
              end repeat
              activate
            end tell
            """
        case "com.googlecode.iterm2":
            return """
            tell application "iTerm2"
              repeat with w in windows
                repeat with t in tabs of w
                  repeat with s in sessions of t
                    if tty of s is "\(safe)" then
                      select w
                      select t
                      select s
                      activate
                      return
                    end if
                  end repeat
                end repeat
              end repeat
              activate
            end tell
            """
        default:
            return nil
        }
    }
}
