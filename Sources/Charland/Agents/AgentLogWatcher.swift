import Foundation
import CoreServices
import CharlandCore

/// Guarda una cartella con gli avvisi del sistema sui file. A riposo non costa niente: nessun
/// timer, si sveglia solo quando un file cambia.
final class FolderWatch: @unchecked Sendable {
    private var stream: FSEventStreamRef?
    private let handler: @Sendable ([String]) -> Void
    private let queue: DispatchQueue

    init(queue: DispatchQueue, handler: @escaping @Sendable ([String]) -> Void) {
        self.queue = queue
        self.handler = handler
    }

    func start(paths: [String]) {
        let existing = paths.filter { FileManager.default.fileExists(atPath: $0) }
        guard stream == nil, !existing.isEmpty else { return }
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, paths, _, _ in
            guard let info else { return }
            let watch = Unmanaged<FolderWatch>.fromOpaque(info).takeUnretainedValue()
            let list = Unmanaged<CFArray>.fromOpaque(paths).takeUnretainedValue() as? [String] ?? []
            watch.handler(Array(list.prefix(count)))
        }
        let flags = UInt32(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagNoDefer)
        guard let created = FSEventStreamCreate(kCFAllocatorDefault, callback, &context, existing as CFArray,
                                                FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.25, flags) else { return }
        FSEventStreamSetDispatchQueue(created, queue)
        FSEventStreamStart(created)
        stream = created
    }

    func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }
}

/// Si collega da solo a ogni sessione di un agente che scrive un registro riga per riga:
/// Claude Code (`~/.claude/projects`) e Codex, cioè ChatGPT (`~/.codex/sessions`).
/// Legge solo le righe nuove e non scrive niente nelle impostazioni degli agenti.
final class AgentLogWatcher<Tracker: AgentLogTracker>: @unchecked Sendable {
    let kind: AgentKind
    let root: URL
    /// Controlla che il processo della sessione sia ancora acceso (Claude Code, vedi `ClaudeLiveness`).
    let checksProcesses: Bool
    /// Dopo quanto silenzio un turno non è più mostrato come al lavoro.
    static var idleLimit: TimeInterval { 10 * 60 }
    /// Ogni quanto si guarda se i processi ci sono ancora, mentre qualcuno è mostrato al lavoro.
    private static var processCheck: TimeInterval { 3 }

    private let queue: DispatchQueue
    private lazy var watch = FolderWatch(queue: queue) { [weak self] paths in self?.changed(paths) }
    private var files: [String: FileState] = [:]
    private var idleTimer: DispatchSourceTimer?
    private var running = false
    /// L'ultimo elenco dei processi, per non rileggerlo per ogni registro all'avvio.
    private var processes: (at: Date, list: [ClaudeProcess])?

    private struct FileState {
        var offset: UInt64 = 0
        var partial = Data()
        var tracker = Tracker()
        var shown = false
        /// Il registro di un sotto-agente (`<sessione>/subagents/`): conta come lavoro, ma non è una riga dell'isola.
        var helper = false
        /// Tolto dal controllo del silenzio a turno ancora aperto: solo così può tornare al lavoro senza un messaggio
        /// nuovo. Un turno mai chiuso per altri motivi (terminale chiuso, crollo) resta fuori.
        var droppedByIdle = false
        /// Quante volte di fila il suo processo non c'era.
        var deadChecks = 0
        /// L'ultima domanda detta al centro delle domande, e lo strumento in corso.
        var askReported: AgentAsk?
        var toolReported: String?
    }

    init(kind: AgentKind, root: URL, checksProcesses: Bool = false) {
        self.kind = kind
        self.root = root
        self.checksProcesses = checksProcesses
        queue = DispatchQueue(label: "registri-\(kind.title)", qos: .utility)
    }

    /// La sessione di questo registro ha ancora il suo processo. Senza controllo, o con un registro che non si sa a chi
    /// appartenga, sì.
    private func alive(_ path: String, fresh: Bool) -> Bool {
        guard checksProcesses, let session = ClaudeLiveness.session(ofLog: path) else { return true }
        if fresh || processes.map({ Date().timeIntervalSince($0.at) > 1 }) ?? true {
            processes = (Date(), ClaudeProcesses.snapshot())
        }
        return ClaudeLiveness.isAlive(sessionID: session.sessionID, projectDir: session.projectDir, processes: processes?.list ?? [])
    }

    func start() {
        queue.async { [self] in
            guard !running else { return }
            running = true
            scanRecent()
            watch.start(paths: [root.path])
        }
    }

    func stop() {
        queue.async { [self] in
            running = false
            watch.stop()
            idleTimer?.cancel()
            idleTimer = nil
            let shown = files.filter(\.value.shown).map(\.key)
            files.removeAll()
            let kind = kind
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    for path in shown { AgentHub.shared.finished(Self.key(kind, path), duration: 0) }
                    AgentAsks.shared.logsStopped(kind: kind)
                }
            }
        }
    }

    private func changed(_ paths: [String]) {
        guard running else { return }
        for path in Set(paths) where path.hasSuffix(".jsonl") { read(path) }
    }

    /// All'avvio: i registri toccati negli ultimi minuti, per sapere chi sta lavorando adesso.
    private func scanRecent() {
        let cutoff = Date().addingTimeInterval(-Self.idleLimit)
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.contentModificationDateKey],
                                                              options: [.skipsHiddenFiles]) else { return }
        for case let file as URL in enumerator where file.pathExtension == "jsonl" {
            let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            if modified > cutoff { read(file.path) }
        }
    }

    private func read(_ path: String) {
        // Nella cartella dei sotto-agenti contano solo i loro registri (`agent-*.jsonl`), non i diari dei flussi.
        if path.contains("/subagents/"), !(path as NSString).lastPathComponent.hasPrefix("agent-") { return }
        guard let handle = FileHandle(forReadingAtPath: path) else { return }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        if files[path] == nil || (files[path]?.offset ?? 0) > size {
            // Un registro mai visto: la coda, allargata all'indietro finché contiene l'inizio del turno.
            var state = Self.initialState(handle: handle, size: size, helper: path.contains("/subagents/"))
            state.shown = state.tracker.working
                && state.tracker.lastActivity.map { Date().timeIntervalSince($0) < Self.idleLimit } == true
            // Un turno rimasto aperto da una sessione che non c'è più (Claude chiuso a metà, Mac riavviato): non è al
            // lavoro. Può tornarci se il registro ricomincia a scrivere.
            if state.shown, !alive(path, fresh: false) {
                state.shown = false
                state.droppedByIdle = true
            }
            reportAsk(path, state: &state)
            files[path] = state
            if state.shown { report(path, state: state, ended: nil) }
            scheduleIdleCheck()
            return
        }
        var state = files[path]!
        guard size > state.offset else { return }
        try? handle.seek(toOffset: state.offset)
        let data = (try? handle.read(upToCount: Int(min(size - state.offset, 16 << 20)))) ?? Data()
        state.offset += UInt64(data.count)
        var buffer = state.partial + data
        var changes: [TranscriptTracker.Change] = []
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = Data(buffer[buffer.startIndex..<newline])
            buffer.removeSubrange(buffer.startIndex...newline)
            if let change = state.tracker.feed(line) { changes.append(change) }
        }
        state.partial = buffer
        let freshLines = !data.isEmpty
        for change in changes {
            switch change {
            case .started:
                state.shown = true
                state.droppedByIdle = false
                report(path, state: state, ended: nil)
            case .ended(_, let duration):
                if state.shown { report(path, state: state, ended: duration) }
                state.shown = false
            }
        }
        // Un turno tolto dopo dieci minuti di silenzio (un comando lungo, un pensiero lungo) che ricomincia a scrivere
        // torna al lavoro: prima restava fuori fino al messaggio successivo, e Mantieni attivo poteva spegnersi a metà.
        if freshLines, state.droppedByIdle, !state.shown, state.tracker.working,
           state.tracker.lastActivity.map({ Date().timeIntervalSince($0) < Self.idleLimit }) == true {
            state.shown = true
            state.droppedByIdle = false
            report(path, state: state, ended: nil)
        }
        reportAsk(path, state: &state)
        files[path] = state
        scheduleIdleCheck()
    }

    /// Quello che la sessione sta chiedendo (una scheda di domanda, un piano, la domanda di fine turno) e lo strumento
    /// in corso, verso il centro delle domande: solo quando cambiano. I registri dei sotto-agenti non chiedono a te.
    private func reportAsk(_ path: String, state: inout FileState) {
        guard !state.helper else { return }
        let ask = state.tracker.ask
        let tools = state.tracker.openTools
        // Con uno strumento solo in corso è lui che aspetta; con più d'uno non si sa quale.
        let tool = tools.count == 1 ? tools[0].summary : nil
        guard ask != state.askReported || tool != state.toolReported else { return }
        state.askReported = ask
        state.toolReported = tool
        let kind = kind
        let project = state.tracker.project
        let session = state.tracker.sessionID ?? ClaudeLiveness.session(ofLog: path)?.sessionID
            ?? ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                AgentAsks.shared.logChanged(sessionID: session, kind: kind, project: project, logPath: path, ask: ask, openTool: tool)
            }
        }
    }

    private static func initialState(handle: FileHandle, size: UInt64, helper: Bool) -> FileState {
        var window: UInt64 = 1 << 20
        while true {
            let start = size > window ? size - window : 0
            try? handle.seek(toOffset: start)
            let data = (try? handle.read(upToCount: Int(size - start))) ?? Data()
            var state = FileState()
            state.helper = helper
            state.tracker = Tracker(sidechainLog: helper)
            state.offset = size
            var lines = data.split(separator: 0x0A, omittingEmptySubsequences: false)
            state.partial = Data(lines.removeLast())
            if start > 0, !lines.isEmpty { lines.removeFirst() }
            for line in lines { _ = state.tracker.feed(Data(line)) }
            if state.tracker.turnStart != nil || start == 0 || window >= 32 << 20 { return state }
            window *= 8
        }
    }

    /// Solo finché qualcuno è al lavoro: chi tace da troppo non lo è più, e (per Claude) nemmeno chi non ha più il suo
    /// processo. Ogni minuto, ogni 3 secondi se si controllano i processi.
    private func scheduleIdleCheck() {
        guard files.values.contains(where: \.shown) else {
            idleTimer?.cancel()
            idleTimer = nil
            return
        }
        guard idleTimer == nil else { return }
        let every = checksProcesses ? Self.processCheck : 60
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + every, repeating: every, leeway: .milliseconds(checksProcesses ? 500 : 5000))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            var looked = false
            for (path, var state) in self.files where state.shown {
                let quiet = state.tracker.lastActivity.map { Date().timeIntervalSince($0) } ?? .infinity
                if quiet > Self.idleLimit {
                    state.shown = false
                    state.droppedByIdle = true
                    self.files[path] = state
                    self.report(path, state: state, ended: 0)
                    continue
                }
                guard self.checksProcesses else { continue }
                // Due controlli di fila senza processo e il registro fermo: l'app di Claude rilancia il processo quando
                // cambi modello o sforzo, e per un attimo non c'è.
                let isAlive = self.alive(path, fresh: !looked)
                looked = true
                state.deadChecks = isAlive ? 0 : state.deadChecks + 1
                if state.deadChecks >= 2, quiet > Self.processCheck {
                    state.shown = false
                    state.droppedByIdle = true
                    state.deadChecks = 0
                    self.report(path, state: state, ended: 0)
                }
                self.files[path] = state
            }
            self.scheduleIdleCheck()
        }
        timer.resume()
        idleTimer = timer
    }

    static func key(_ kind: AgentKind, _ path: String) -> String { "\(kind.title):\(path)" }

    /// Verso il centro degli agenti, sul thread principale.
    private func report(_ path: String, state: FileState, ended: TimeInterval?) {
        let key = Self.key(kind, path)
        let kind = kind
        let project = state.tracker.project
        let since = state.tracker.turnStart ?? Date()
        let helper = state.helper
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                if helper {
                    if ended != nil { AgentHub.shared.finished(key, duration: 0) } else { AgentHub.shared.helperWorking(key) }
                } else if let ended {
                    AgentHub.shared.finished(key, duration: ended)
                } else {
                    AgentHub.shared.working(key, kind: kind, project: project, since: since)
                }
            }
        }
    }
}

/// Gemini non scrive un registro riga per riga che si possa leggere: Antigravity salva le
/// conversazioni in piccoli database, Gemini da terminale riscrive un file intero.
/// Qui conta che il file si scriva: lavora finché i file cambiano, ha finito dopo qualche
/// secondo di quiete.
final class ActivityWatcher: @unchecked Sendable {
    let kind: AgentKind
    let roots: [URL]
    let accepts: @Sendable (String) -> Bool
    /// Dopo quanti secondi di quiete il turno è finito.
    let quiet: TimeInterval

    private let queue: DispatchQueue
    private lazy var watch = FolderWatch(queue: queue) { [weak self] paths in self?.changed(paths) }
    private var sessions: [String: (since: Date, last: Date)] = [:]
    private var timer: DispatchSourceTimer?

    init(kind: AgentKind, roots: [URL], quiet: TimeInterval = 10, accepts: @escaping @Sendable (String) -> Bool) {
        self.kind = kind
        self.roots = roots
        self.quiet = quiet
        self.accepts = accepts
        queue = DispatchQueue(label: "attivita-\(kind.title)", qos: .utility)
    }

    func start() {
        queue.async { [self] in watch.start(paths: roots.map(\.path)) }
    }

    func stop() {
        queue.async { [self] in
            watch.stop()
            timer?.cancel()
            timer = nil
            let keys = sessions.keys.map { "\(kind.title):\($0)" }
            sessions.removeAll()
            DispatchQueue.main.async {
                MainActor.assumeIsolated { for key in keys { AgentHub.shared.finished(key, duration: 0) } }
            }
        }
    }

    private func changed(_ paths: [String]) {
        let now = Date()
        for path in paths where accepts(path) {
            // Il database e il suo diario sono la stessa conversazione.
            let id = path.replacingOccurrences(of: "-wal", with: "").replacingOccurrences(of: "-shm", with: "")
            if var session = sessions[id] {
                session.last = now
                sessions[id] = session
            } else {
                sessions[id] = (now, now)
                let key = "\(kind.title):\(id)"
                let kind = kind
                let project = ((id as NSString).deletingLastPathComponent as NSString).lastPathComponent
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        AgentHub.shared.working(key, kind: kind, project: project == "conversations" ? nil : project, since: now)
                    }
                }
            }
        }
        scheduleCheck()
    }

    /// Ogni due secondi, solo finché qualcuno lavora: dopo la quiete, il turno è finito.
    private func scheduleCheck() {
        guard !sessions.isEmpty, timer == nil else { return }
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 2, repeating: 2, leeway: .milliseconds(500))
        t.setEventHandler { [weak self] in
            guard let self else { return }
            let now = Date()
            for (id, session) in self.sessions where now.timeIntervalSince(session.last) > self.quiet {
                self.sessions[id] = nil
                let key = "\(self.kind.title):\(id)"
                let duration = session.last.timeIntervalSince(session.since)
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { AgentHub.shared.finished(key, duration: duration) }
                }
            }
            if self.sessions.isEmpty {
                self.timer?.cancel()
                self.timer = nil
            }
        }
        t.resume()
        timer = t
    }
}

/// Tutti gli osservatori degli agenti.
@MainActor
enum AgentWatchers {
    static var home: URL { FileManager.default.homeDirectoryForCurrentUser }

    static let claude = AgentLogWatcher<TranscriptTracker>(
        kind: .claude,
        root: ProcessInfo.processInfo.environment["CHARLAND_CLAUDE_PROJECTS"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? home.appendingPathComponent(".claude/projects", isDirectory: true),
        checksProcesses: true)
    static let codex = AgentLogWatcher<CodexTracker>(
        kind: .codex,
        root: ProcessInfo.processInfo.environment["CHARLAND_CODEX_SESSIONS"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? home.appendingPathComponent(".codex/sessions", isDirectory: true))
    static let gemini = ActivityWatcher(
        kind: .gemini,
        roots: [home.appendingPathComponent(".gemini/antigravity/conversations", isDirectory: true),
                home.appendingPathComponent(".gemini/tmp", isDirectory: true)],
        accepts: { path in
            (path.contains("/antigravity/conversations/") && (path.hasSuffix(".db") || path.hasSuffix(".db-wal")))
                || (path.contains("/.gemini/tmp/") && path.contains("/chats/") && path.hasSuffix(".json"))
        })

    /// Lo stato che Claude Code scrive di ogni sua sessione: al lavoro, ferma, in attesa di te.
    static let claudeSessions = ClaudeSessionsWatcher(
        root: ProcessInfo.processInfo.environment["CHARLAND_CLAUDE_SESSIONS"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? home.appendingPathComponent(".claude/sessions", isDirectory: true))

    static func start() {
        claude.start()
        codex.start()
        gemini.start()
        claudeSessions.start()
    }

    static func stop() {
        claude.stop()
        codex.stop()
        gemini.stop()
        claudeSessions.stop()
    }
}
