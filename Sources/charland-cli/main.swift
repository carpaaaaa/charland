import AppKit
import Foundation
import CharlandKit

// charland: il comando da terminale di Charland.
//
//   charland post --id build --title "Build" --progress 0.4 --status "Compilo"
//   charland update --id build --progress 0.9
//   charland end --id build
//   charland watch --title "Build" -- npm run build
//   charland status
//   charland hook claude        (lo chiama il gancio dei permessi degli agenti)
//   charland shell-init zsh     (stampa il collegamento per zsh)
//
// Se Charland è chiusa, i comandi non fanno niente ed escono con 0: uno script
// non deve fallire perché l'isola non c'è.

var args = Array(CommandLine.arguments.dropFirst())

@MainActor func fail(_ message: String, code: Int32 = 2) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(code)
}

@MainActor func value(_ name: String) -> String? {
    guard let index = args.firstIndex(of: name), index + 1 < args.count else { return nil }
    return args[index + 1]
}

@MainActor func flag(_ name: String) -> Bool { args.contains(name) }

let usage = """
charland: mostra attività nell'isola di Charland.

  charland post   --id <id> --title <testo> [opzioni]   crea o aggiorna un'attività
  charland update --id <id> [opzioni]                   cambia solo quello che gli dai (stesse opzioni di post)
  charland end    --id <id>                             chiude
  charland list                                         elenca le attività aperte da te
  charland watch  [--title <testo>] -- <comando>        segue un comando e ne mostra l'avanzamento
  charland agent --name <AI> --start|--done [--project P] [--tint colore]
                                                        la tua AI nell'isola, insieme a Claude, ChatGPT, Gemini
  charland agent --name <AI> -- <comando>               la segna al lavoro finché il comando gira
  charland timer <durata> [--title testo]               un timer nell'isola: 90s, 10m, 1h
  charland status                                       dice se Charland è aperta
  charland json '<messaggio>'                           manda un messaggio JSON così com'è
  charland shell-init zsh                               collegamento per zsh (comandi lunghi)

Opzioni di post e update:
  --template progress|countdown|status   (predefinito: progress se c'è --progress, altrimenti status)
  --progress <0...1>      --status <testo>       --subtitle <testo>
  --symbol <SF Symbol>    --tint <colore>        --priority <-1...2>
  --ends-in <secondi>     --ttl <secondi>        --client <nome>
  --expand                apre l'isola            --haptic done|waiting|error
"""

@MainActor func connect() -> CharlandClient? {
    let client = CharlandClient()
    do {
        try client.connect()
        return client
    } catch {
        return nil
    }
}

/// `post` crea o sostituisce l'attività intera; `update` cambia solo quello che gli dai (`partial`).
@MainActor func buildUpsert(partial: Bool = false) -> ActivityMessage {
    guard let id = value("--id") else { fail("manca --id") }
    var m = ActivityMessage(op: .upsert, client: value("--client") ?? "charland", id: id)
    if partial { m.partial = true }
    m.title = value("--title") ?? (partial ? nil : id)
    m.subtitle = value("--subtitle")
    m.status = value("--status")
    m.symbol = value("--symbol")
    m.tint = value("--tint")
    if let p = value("--progress") {
        guard let number = Double(p) else { fail("--progress vuole un numero fra 0 e 1") }
        m.progress = number > 1 ? number / 100 : number
    }
    if let seconds = value("--ends-in").flatMap(Double.init) {
        m.endsAt = Date().timeIntervalSince1970 + seconds
        m.startedAt = Date().timeIntervalSince1970
    }
    m.priority = value("--priority").flatMap(Int.init)
    m.ttl = value("--ttl").flatMap(Double.init)
    if let t = value("--template") {
        guard let template = ActivityMessage.Template(rawValue: t) else { fail("modello sconosciuto: \(t)") }
        m.template = template
    } else if !partial {
        m.template = m.endsAt != nil ? .countdown : (m.progress != nil ? .progress : .status)
    }
    if let symbol = m.symbol, NSImage(systemSymbolName: symbol, accessibilityDescription: nil) == nil {
        FileHandle.standardError.write(Data("charland: il simbolo «\(symbol)» non esiste fra gli SF Symbols: l'isola mostrerà un punto.\n".utf8))
    }
    if flag("--expand") || value("--haptic") != nil {
        m.alert = .init(expand: flag("--expand") ? true : nil, haptic: value("--haptic"))
    }
    return m
}

@MainActor func send(_ message: ActivityMessage) {
    do {
        try ActivitySchema.validate(message)
    } catch {
        fail("\(error)")
    }
    guard let client = connect() else { exit(0) }
    do {
        let reply = try client.send(message)
        // Charland dice di no (un aggiornamento senza attività, un cliente non permesso): lo si dice.
        if reply.ok == false { fail(reply.error ?? "Charland non l'ha accettato", code: 1) }
    } catch {
        fail("\(error)", code: 1)
    }
}

guard let command = args.first else {
    print(usage)
    exit(0)
}
args.removeFirst()

switch command {
case "post":
    send(buildUpsert())

case "update":
    send(buildUpsert(partial: true))

case "end":
    guard let id = value("--id") else { fail("manca --id") }
    send(ActivityMessage(op: .end, client: value("--client") ?? "charland", id: id))

case "status":
    guard let client = connect() else {
        print("Charland non è aperta.")
        exit(1)
    }
    if let reply = try? client.send(ActivityMessage(op: .hello, client: "charland")) {
        print("\(reply.name ?? "Charland") \(reply.version ?? "") è aperta.")
    }

case "list":
    guard let client = connect() else { exit(1) }
    if let reply = try? client.send(ActivityMessage(op: .list, client: value("--client") ?? "charland")) {
        print((reply.ids ?? []).joined(separator: "\n"))
    }

case "json":
    guard let raw = args.first, let data = raw.data(using: .utf8) else { fail("manca il messaggio") }
    do {
        send(try ActivitySchema.decode(data))
    } catch {
        fail("\(error)")
    }

case "watch":
    Watch.run()

case "agent":
    AgentCommand.run()

case "timer":
    TimerCommand.run()

case "hook":
    AgentHook.run(agent: args.first ?? "claude")

case "shell-init":
    ShellHook.printInit(shell: args.first ?? "zsh")

case "_shell-begin":
    ShellHook.begin()

case "_shell-end":
    ShellHook.end()

case "help", "--help", "-h":
    print(usage)

default:
    fail("comando sconosciuto: \(command)\n\n" + usage)
}

// MARK: - watch

@MainActor enum Watch {
    static func run() {
        guard let split = args.firstIndex(of: "--"), split + 1 < args.count else { fail("uso: charland watch [--title T] -- <comando>") }
        let commandLine = Array(args[(split + 1)...])
        args = Array(args[..<split])
        let id = value("--id") ?? "watch-\(getpid())"
        let title = value("--title") ?? (commandLine.first.map { ($0 as NSString).lastPathComponent } ?? "comando")
        let clientName = value("--client") ?? "charland"
        let client = connect()

        func post(progress: Double?, status: String, done: Int32? = nil) {
            guard let client else { return }
            var m = ActivityMessage(op: .upsert, client: clientName, id: id)
            m.title = String(title.prefix(60))
            m.symbol = value("--symbol") ?? "terminal.fill"
            m.status = String(status.prefix(80))
            if let done {
                m.template = .status
                m.status = done == 0 ? "done" : "Errore \(done)"
                m.subtitle = String(title.prefix(80))
                m.tint = done == 0 ? "green" : "red"
                m.alert = .init(haptic: done == 0 ? "done" : "error")
                m.ttl = 6
            } else if let progress {
                m.template = .progress
                m.progress = progress
            } else {
                m.template = .status
                m.status = "working"
                m.subtitle = String(status.prefix(80))
            }
            _ = try? client.send(m)
        }

        // Un terminale finto fra noi e il comando: così i programmi tengono le loro barre
        // di avanzamento, che senza terminale spengono.
        var master: Int32 = 0
        var slave: Int32 = 0
        let interactive = isatty(STDOUT_FILENO) == 1
        var size = winsize()
        if interactive { _ = ioctl(STDOUT_FILENO, TIOCGWINSZ, &size) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = commandLine
        let readHandle: FileHandle
        if interactive, openpty(&master, &slave, nil, nil, &size) == 0 {
            let slaveHandle = FileHandle(fileDescriptor: slave, closeOnDealloc: true)
            process.standardOutput = slaveHandle
            process.standardError = slaveHandle
            readHandle = FileHandle(fileDescriptor: master, closeOnDealloc: true)
        } else {
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            readHandle = pipe.fileHandleForReading
        }
        post(progress: nil, status: title)
        do {
            try process.run()
        } catch {
            post(progress: nil, status: "", done: 127)
            fail("non riesco ad avviare: \(commandLine.joined(separator: " "))", code: 127)
        }
        if interactive { close(slave) }

        var parser = ProgressParser()
        var lastSent = Date.distantPast
        var lastFraction: Double?
        while true {
            let data = readHandle.availableData
            if data.isEmpty { break }
            FileHandle.standardOutput.write(data)
            guard let update = parser.feed(String(decoding: data, as: UTF8.self)) else { continue }
            // Al massimo sei aggiornamenti al secondo, e solo se cambia qualcosa.
            let changed = update.fraction != lastFraction
            if changed, Date().timeIntervalSince(lastSent) > 0.16 {
                lastSent = Date()
                lastFraction = update.fraction
                post(progress: update.fraction, status: update.line)
            }
        }
        process.waitUntilExit()
        post(progress: nil, status: "", done: process.terminationStatus)
        exit(process.terminationStatus)
    }
}

// MARK: - Ganci degli agenti

/// Il gancio di Claude Code e di Codex per le richieste di permesso (`PermissionRequest`): riceve la richiesta sullo
/// standard input, la porta nell'isola e aspetta la tua scelta. Vale anche per le schede di domanda
/// (`AskUserQuestion`), che per Claude Code sono richieste di permesso con la risposta dentro.
///
/// A turno finito non fa niente. Per qualche ora, il 19 novembre 2026, ha portato nell'isola i pulsanti del riquadro
/// di fine turno e risvegliato Claude con la risposta premuta (`Stop` con `asyncRewake`, codice 2): Claude Code
/// consegna quel risveglio come «evento automatico, NON un messaggio dell'utente», e Claude non lo prende per una
/// tua risposta. Quella strada è chiusa di proposito: non va riaperta con un testo più convincente.
///
/// Il gancio corre insieme alla finestra dell'agente: vale la prima risposta, da una parte o dall'altra (provato il
/// 19 novembre 2026 con Claude Code 2.1.326 nella modalità dell'app di Claude). Se rispondi nella finestra, Claude
/// Code non ferma il gancio (resta appeso fino alla fine della sessione): se ne accorge lui leggendo il registro
/// della sessione, e toglie la richiesta dall'isola.
/// Se Charland è chiusa esce subito senza decidere: l'agente chiede nella sua finestra come sempre.
/// Tutto il resto (chi lavora, chi ha finito, le domande di fine turno) Charland lo legge da sé, senza ganci.
@MainActor enum AgentHook {
    static func run(agent: String) {
        let input = FileHandle.standardInput.readDataToEndOfFile()
        guard let json = try? JSONSerialization.jsonObject(with: input) as? [String: Any] else { exit(0) }
        // Solo le richieste di permesso. Gli altri eventi (anche la fine del turno) li collegavano le versioni
        // precedenti: una sessione ancora aperta con quei ganci li lancia, e qui escono subito.
        guard json["hook_event_name"] as? String == "PermissionRequest" else { exit(0) }
        let tool = json["tool_name"] as? String ?? ""
        // Un piano da approvare si legge nella finestra dell'agente: l'isola lo annuncia da sé.
        if tool == "ExitPlanMode" { exit(0) }
        let toolInput = json["tool_input"] as? [String: Any] ?? [:]
        let session = String((json["session_id"] as? String ?? "sessione").prefix(60))
        let cwd = json["cwd"] as? String ?? FileManager.default.currentDirectoryPath
        let project = String((cwd as NSString).lastPathComponent.prefix(50))
        let isCodex = agent.lowercased().hasPrefix("codex")
        let clientName = isCodex ? "codex" : "claude-code"
        let agentTitle = isCodex ? "Codex" : "Claude Code"

        // Una scheda di domanda a scelta multipla, o senza scelte: si risponde nella finestra dell'agente (l'isola la
        // annuncia da sé). Si decide prima di collegarsi.
        let questions = toolInput["questions"] as? [[String: Any]] ?? []
        if tool == "AskUserQuestion" {
            let simple = !questions.isEmpty && questions.allSatisfy { question in
                (question["multiSelect"] as? Bool) != true && !((question["question"] as? String) ?? "").isEmpty
                    && !((question["options"] as? [[String: Any]]) ?? []).isEmpty
            }
            guard simple else { exit(0) }
        }
        guard let client = connect() else { exit(0) }
        // Per un sotto-agente la richiesta sta nel suo registro, non in quello della sessione.
        var transcript = TranscriptWatch(path: (json["agent_transcript_path"] as? String) ?? (json["transcript_path"] as? String),
                                         tool: tool, input: toolInput)

        /// `CHARLAND_HOOK_LOG=<file>`: cosa fa il gancio e quando, per le prove.
        let logPath = ProcessInfo.processInfo.environment["CHARLAND_HOOK_LOG"]
        func log(_ text: String) {
            guard let logPath, let handle = FileHandle(forWritingAtPath: logPath) ?? {
                FileManager.default.createFile(atPath: logPath, contents: nil)
                return FileHandle(forWritingAtPath: logPath)
            }() else { return }
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            let now = Date().timeIntervalSince1970
            let seconds = Int(now) % 86400 + TimeZone.current.secondsFromGMT()
            let clock = String(format: "%02d:%02d:%02d.%03d", (seconds / 3600) % 24, (seconds / 60) % 60, seconds % 60, Int((now - floor(now)) * 1000))
            handle.write(Data("\(clock) [gancio \(getpid())] \(text)\n".utf8))
        }
        log("richiesta di \(tool) per la sessione \(session)")

        func base() -> ActivityMessage {
            var m = ActivityMessage(op: .upsert, client: clientName, id: session)
            m.template = .approval
            m.title = project.isEmpty ? agentTitle : project
            m.subtitle = agentTitle
            m.symbol = "sparkle"
            m.priority = 2
            // L'app da cui gira la sessione: il terminale, l'editor o l'app di Claude.
            m.origin = ProcessInfo.processInfo.environment["__CFBundleIdentifier"]
            return m
        }

        /// Toglie la richiesta dall'isola ed esce senza decidere: l'agente va avanti con la sua finestra.
        func leave(_ why: String = "esco") -> Never {
            log(why)
            _ = try? client.send(ActivityMessage(op: .end, client: clientName, id: session), timeout: 1)
            exit(0)
        }

        /// Scrive la decisione per l'agente, toglie la richiesta dall'isola ed esce.
        func decide(_ decision: [String: Any]) -> Never {
            let output: [String: Any] = ["hookSpecificOutput": ["hookEventName": "PermissionRequest", "decision": decision]]
            if let data = try? JSONSerialization.data(withJSONObject: output) {
                FileHandle.standardOutput.write(data)
            }
            leave("deciso dall'isola: \(decision["behavior"] ?? "")")
        }

        // Poco meno del tempo massimo dei ganci (600 s).
        let deadline = Date().addingTimeInterval(570)

        /// Aspetta un tuo tocco nell'isola. Esce da sé se la richiesta ha avuto risposta altrove, se Charland la chiude
        /// o si spegne, o se il tempo scade.
        func nextAction() -> String {
            while Date() < deadline {
                let reply: ServerReply?
                do {
                    reply = try client.nextEvent(timeout: 1)
                } catch {
                    // Charland si è spenta: nessuno risponderà da lì.
                    log("Charland non risponde più")
                    exit(0)
                }
                guard let reply else {
                    if transcript.answered() { leave("risposta data altrove (registro)") }
                    continue
                }
                if reply.event == "ended" {
                    log("chiusa da Charland")
                    exit(0)
                }
                if reply.event == "action", let action = reply.action {
                    log("tocco: \(action)")
                    return action
                }
            }
            leave("tempo scaduto")
        }

        if tool == "AskUserQuestion" {
            // Una domanda dell'agente: esce nell'isola con le sue scelte e si risponde da lì (carpa, 18 novembre 2026).
            var answers: [String: String] = [:]
            for (index, question) in questions.enumerated() {
                let text = question["question"] as? String ?? ""
                let labels = (question["options"] as? [[String: Any]] ?? []).compactMap { $0["label"] as? String }
                var m = base()
                m.status = "question"
                m.command = String(text.prefix(400))
                if questions.count > 1 { m.subtitle = "\(agentTitle) · \(index + 1)/\(questions.count)" }
                m.alert = .init(expand: true, haptic: index == 0 ? "waiting" : nil)
                m.actions = labels.prefix(ActivitySchema.maxOptions).enumerated().map {
                    .init(id: "opt:\($0.offset)", title: String($0.element.prefix(60)))
                }
                guard (try? client.send(m)) != nil else { exit(0) }
                // Un secondo tocco sulla domanda di prima, arrivato prima che questa comparisse, non è la risposta a questa.
                client.dropPendingEvents()
                var chosen: String?
                while chosen == nil {
                    let action = nextAction()
                    // Vuole leggerla nella finestra dell'agente: il gancio non decide, la scheda è là.
                    if action == "jump" { leave("va alla finestra dell'agente") }
                    // L'ha vista e la toglie dall'isola: la scheda resta nella finestra dell'agente.
                    if action == "dismiss" { leave("tolta dall'isola senza rispondere") }
                    if action.hasPrefix("opt:"), let pick = Int(action.dropFirst(4)), labels.indices.contains(pick) {
                        chosen = labels[pick]
                    }
                }
                answers[text] = chosen
            }
            // La risposta: le domande com'erano, più le scelte fatte (testo della domanda → etichetta scelta).
            var updated = toolInput
            updated["answers"] = answers
            decide(["behavior": "allow", "updatedInput": updated])
        }

        var m = base()
        m.command = describe(tool: tool, input: toolInput)
        m.alert = .init(expand: true, haptic: "waiting")
        m.allowAlways = json["permission_suggestions"] != nil
        guard (try? client.send(m)) != nil else { exit(0) }
        while true {
            switch nextAction() {
            case "allow":
                decide(["behavior": "allow"])
            case "always":
                var decision: [String: Any] = ["behavior": "allow"]
                // "Sempre": si rimandano all'agente i suoi stessi suggerimenti.
                if !isCodex, let suggestions = json["permission_suggestions"] { decision["updatedPermissions"] = suggestions }
                decide(decision)
            case "deny":
                decide(["behavior": "deny", "message": "Rifiutato dall'isola di Charland."])
            case "jump":
                // Vuole guardarla nella finestra dell'agente: là la richiesta è ancora aperta.
                leave("va alla finestra dell'agente")
            case "dismiss":
                // L'ha vista e la toglie dall'isola senza decidere: resta da approvare nella finestra dell'agente.
                leave("tolta dall'isola senza rispondere")
            default:
                continue
            }
        }
    }

    /// Il comando esatto, come lo vedrebbe l'utente nel terminale.
    static func describe(tool: String, input: [String: Any]) -> String {
        let text: String
        if let command = input["command"] as? String {
            text = command
        } else if let path = input["file_path"] as? String {
            text = "\(tool) \(path)"
        } else if let url = input["url"] as? String {
            text = "\(tool) \(url)"
        } else if let data = try? JSONSerialization.data(withJSONObject: input, options: [.sortedKeys]),
                  let json = String(data: data, encoding: .utf8), json != "{}" {
            text = "\(tool) \(json)"
        } else {
            text = tool
        }
        let cleaned = text.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\t", with: " ")
        return String(cleaned.filter { $0.unicodeScalars.allSatisfy { $0.value >= 0x20 } }.prefix(1000))
    }
}

/// Guarda il registro della sessione per sapere se una richiesta ha già avuto risposta altrove. Trova la riga in cui
/// l'agente chiede lo strumento (stesso nome, stessi argomenti) e poi cerca il risultato di quella richiesta: quando
/// c'è, tu hai risposto nella finestra dell'agente (approvato, rifiutato o interrotto).
struct TranscriptWatch {
    let path: String?
    let tool: String
    let input: NSDictionary
    /// La richiesta nel registro, quando la si è trovata.
    private(set) var toolUseID: String?
    /// Da dove si legge: all'inizio l'ultimo pezzo del registro, poi solo quello che si aggiunge.
    private var offset: UInt64 = 0
    private var lastSize: UInt64 = 0
    private var looks = 0
    private var began = false
    /// Dopo qualche giro senza trovare la richiesta si smette di cercarla: resta lo stato della sessione a dire se è
    /// stata chiusa altrove.
    private var gaveUp = false

    init(path: String?, tool: String, input: [String: Any]) {
        self.path = path.map { ($0 as NSString).expandingTildeInPath }
        self.tool = tool
        self.input = input as NSDictionary
    }

    mutating func answered() -> Bool {
        guard !gaveUp, let path, let handle = FileHandle(forReadingAtPath: path) else { return false }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        if !began {
            began = true
            // La richiesta è nelle ultime righe: basta l'ultimo pezzo.
            offset = size > (2 << 20) ? size - (2 << 20) : 0
        }
        // Si rilegge solo se il registro è cresciuto; finché la richiesta non si è trovata, qualche giro in più.
        guard size != lastSize || (toolUseID == nil && looks < 4) else { return false }
        lastSize = size
        guard size > offset else { return false }
        try? handle.seek(toOffset: offset)
        guard let data = try? handle.read(upToCount: Int(min(size - offset, 8 << 20))), !data.isEmpty else { return false }
        looks += 1
        if toolUseID == nil {
            // L'ultima richiesta di questo strumento con questi argomenti; se gli argomenti nel registro sono scritti
            // in un altro modo, dopo qualche giro vale l'ultima richiesta di questo strumento.
            var sameName: [String] = []
            for line in data.split(separator: 0x0A) where line.count < (4 << 20) {
                guard let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                      object["type"] as? String == "assistant", object["isSidechain"] as? Bool != true,
                      let blocks = (object["message"] as? [String: Any])?["content"] as? [[String: Any]] else { continue }
                for block in blocks where block["type"] as? String == "tool_use" && block["name"] as? String == tool {
                    guard let id = block["id"] as? String else { continue }
                    sameName.append(id)
                    if let found = block["input"] as? NSDictionary, found == input { toolUseID = id }
                }
            }
            if toolUseID == nil, looks >= 3 {
                // Solo una richiesta ancora aperta: una vecchia con lo stesso strumento ha già il suo risultato, e
                // prenderla farebbe sparire dall'isola una richiesta che aspetta ancora.
                toolUseID = sameName.last { data.range(of: Data("\"tool_use_id\":\"\($0)\"".utf8)) == nil }
                if toolUseID == nil, looks >= 4 {
                    gaveUp = true
                    return false
                }
            }
        }
        guard let id = toolUseID else { return false }
        // Il risultato porta l'identificativo della richiesta. Da qui in poi si legge solo quello che si aggiunge
        // (con un margine: una riga può arrivare a pezzi).
        let needle = Data("\"tool_use_id\":\"\(id)\"".utf8)
        if data.range(of: needle) != nil { return true }
        offset = size > 512 ? size - 512 : 0
        return false
    }
}

// MARK: - zsh

/// Il collegamento per la shell: i comandi più lunghi di 10 secondi si vedono nell'isola,
/// e alla fine avvisano.
@MainActor enum ShellHook {
    static let threshold = 10

    static var folder: URL {
        let url = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.charstudio.charland", isDirectory: true).appendingPathComponent("shell", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func printInit(shell: String) {
        guard shell == "zsh" else { fail("per ora c'è solo zsh") }
        let path = CommandLine.arguments[0].hasPrefix("/") ? CommandLine.arguments[0] : "charland"
        print("""
        # Charland: i comandi più lunghi di \(threshold) secondi si vedono nell'isola.
        # Aggiungi a ~/.zshrc:  eval "$(charland shell-init zsh)"
        zmodload zsh/datetime
        autoload -Uz add-zsh-hook
        _charland_preexec() {
          _charland_start=$EPOCHSECONDS
          ( "\(path)" _shell-begin "$$" "$1" & ) >/dev/null 2>&1
        }
        _charland_precmd() {
          local code=$?
          if [[ -n "$_charland_start" ]]; then
            "\(path)" _shell-end "$$" "$code" "$(( EPOCHSECONDS - _charland_start ))" >/dev/null 2>&1
            unset _charland_start
          fi
        }
        add-zsh-hook preexec _charland_preexec
        add-zsh-hook precmd _charland_precmd
        """)
    }

    static func begin() {
        guard args.count >= 2 else { exit(0) }
        let marker = folder.appendingPathComponent(args[0])
        try? Data(args[1].utf8).write(to: marker)
        sleep(UInt32(threshold))
        // Se il comando è ancora in corso (il segno c'è ancora ed è lo stesso), compare nell'isola.
        guard let still = try? String(contentsOf: marker, encoding: .utf8), still == args[1], let client = connect() else { exit(0) }
        var m = ActivityMessage(op: .upsert, client: "terminale", id: "shell-\(args[0])")
        m.template = .status
        m.title = String(args[1].prefix(60))
        m.symbol = "terminal.fill"
        m.status = "working"
        m.origin = ProcessInfo.processInfo.environment["__CFBundleIdentifier"]
        _ = try? client.send(m)
        exit(0)
    }

    static func end() {
        guard args.count >= 3 else { exit(0) }
        let marker = folder.appendingPathComponent(args[0])
        let commandText = (try? String(contentsOf: marker, encoding: .utf8)) ?? ""
        try? FileManager.default.removeItem(at: marker)
        guard (Int(args[2]) ?? 0) >= threshold, let client = connect() else { exit(0) }
        let code = Int(args[1]) ?? 0
        var m = ActivityMessage(op: .upsert, client: "terminale", id: "shell-\(args[0])")
        m.template = .status
        m.title = String(commandText.prefix(60))
        m.symbol = "terminal.fill"
        m.status = code == 0 ? "done" : "error"
        m.tint = code == 0 ? "green" : "red"
        m.alert = .init(haptic: code == 0 ? "done" : "error")
        m.ttl = 6
        m.origin = ProcessInfo.processInfo.environment["__CFBundleIdentifier"]
        _ = try? client.send(m)
        exit(0)
    }
}

// MARK: - agent

/// La tua AI nell'isola: entra nell'attività degli agenti, con un tempo solo per tutti.
@MainActor enum AgentCommand {
    static func message(_ status: String) -> ActivityMessage {
        guard let name = value("--name") else { fail("manca --name") }
        var m = ActivityMessage(op: .upsert, client: value("--client") ?? "charland", id: value("--id") ?? name)
        m.template = .status
        m.agent = String(name.prefix(30))
        m.title = String((value("--project") ?? (FileManager.default.currentDirectoryPath as NSString).lastPathComponent).prefix(60))
        m.status = status
        m.tint = value("--tint")
        return m
    }

    static func run() {
        if let split = args.firstIndex(of: "--"), split + 1 < args.count {
            let command = Array(args[(split + 1)...])
            args = Array(args[..<split])
            send(message("working"))
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = command
            do { try process.run() } catch {
                send(message("done"))
                fail("non riesco ad avviare: \(command.joined(separator: " "))", code: 127)
            }
            process.waitUntilExit()
            send(message("done"))
            exit(process.terminationStatus)
        }
        if flag("--done") { send(message("done")) } else { send(message("working")) }
    }
}

// MARK: - timer

/// Un timer nell'isola, con il conto alla rovescia e l'avviso alla fine.
@MainActor enum TimerCommand {
    static func seconds(_ text: String) -> Double? {
        let t = text.lowercased().trimmingCharacters(in: .whitespaces)
        if let n = Double(t) { return n * 60 }
        let units: [(String, Double)] = [("h", 3600), ("m", 60), ("s", 1)]
        for (suffix, k) in units where t.hasSuffix(suffix) {
            if let n = Double(t.dropLast()) { return n * k }
        }
        return nil
    }

    static func run() {
        guard let first = args.first, let duration = seconds(first), duration >= 1, duration <= 8 * 3600 else {
            fail("uso: charland timer <durata> (90s, 10m, 1h; al massimo 8 ore)")
        }
        var m = ActivityMessage(op: .upsert, client: "charland",
                                id: value("--id") ?? "timer-\(Int(Date().timeIntervalSince1970))-\(UInt16.random(in: 0...UInt16.max))")
        m.template = .countdown
        m.title = String((value("--title") ?? "Timer").prefix(60))
        m.endsAt = Date().timeIntervalSince1970 + duration
        m.startedAt = Date().timeIntervalSince1970
        m.symbol = "timer"
        m.tint = "orange"
        m.actions = [.init(id: "stop", title: "Ferma")]
        send(m)
    }
}
