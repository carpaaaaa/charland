import Foundation
import CharlandCore

/// Lo stato delle sessioni di Claude Code, come lo scrive Claude stesso in `~/.claude/sessions/<processo>.json`:
/// al lavoro, ferma, oppure in attesa di te («waiting», con cosa aspetta). È così che l'isola sa che un agente chiede
/// un permesso o una risposta anche senza ganci collegati, nell'app di Claude come nel terminale.
/// Si legge soltanto, e solo quando un file cambia: a riposo non costa niente.
final class ClaudeSessionsWatcher: @unchecked Sendable {
    let root: URL
    private let queue = DispatchQueue(label: "sessioni-claude", qos: .utility)
    private lazy var watch = FolderWatch(queue: queue) { [weak self] paths in self?.changed(paths) }
    /// Per file: l'ultima sessione letta.
    private var records: [String: ClaudeSessionRecord] = [:]
    private var running = false
    /// La cartella non c'era all'avvio (Claude Code mai usato): si riguarda ogni tanto.
    private var retry: DispatchSourceTimer?
    /// Finché qualche sessione aspetta te, si controlla ogni pochi secondi che il suo processo ci sia ancora.
    private var sweep: DispatchSourceTimer?

    init(root: URL) {
        self.root = root
    }

    func start() {
        queue.async { [self] in
            guard !running else { return }
            running = true
            begin()
        }
    }

    func stop() {
        queue.async { [self] in
            running = false
            watch.stop()
            retry?.cancel()
            retry = nil
            sweep?.cancel()
            sweep = nil
            let gone = records.values.map(\.sessionID)
            records.removeAll()
            DispatchQueue.main.async {
                MainActor.assumeIsolated { for id in gone { AgentAsks.shared.sessionGone(id) } }
            }
        }
    }

    private func begin() {
        guard FileManager.default.fileExists(atPath: root.path) else {
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + 60, repeating: 60, leeway: .seconds(10))
            timer.setEventHandler { [weak self] in
                guard let self, self.running, FileManager.default.fileExists(atPath: self.root.path) else { return }
                self.retry?.cancel()
                self.retry = nil
                self.begin()
            }
            timer.resume()
            retry = timer
            return
        }
        let files = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        for file in files where file.hasSuffix(".json") { read(root.appendingPathComponent(file).path) }
        watch.start(paths: [root.path])
    }

    private func changed(_ paths: [String]) {
        guard running else { return }
        for path in Set(paths) where path.hasSuffix(".json") { read(path) }
    }

    private func read(_ path: String, attempt: Int = 0) {
        guard running else { return }
        let data = FileManager.default.contents(atPath: path)
        // Il file c'è ma non si legge (Claude lo sta riscrivendo in questo istante): si riprova fra un attimo, invece di
        // prendere una scrittura a metà per una sessione chiusa.
        if let data, ClaudeSessionRecord(json: data) == nil, attempt < 4 {
            queue.asyncAfter(deadline: .now() + 0.15) { [weak self] in self?.read(path, attempt: attempt + 1) }
            return
        }
        // Un file sparito, o di un processo che non c'è più (o che ormai è un altro programma): la sessione è chiusa.
        guard let data, let record = ClaudeSessionRecord(json: data), kill(record.pid, 0) == 0 || errno == EPERM,
              ClaudeProcesses.isClaude(record.pid) else {
            if let old = records.removeValue(forKey: path) {
                let id = old.sessionID
                DispatchQueue.main.async { MainActor.assumeIsolated { AgentAsks.shared.sessionGone(id) } }
            }
            scheduleSweep()
            return
        }
        guard records[path] != record else { return }
        // Lo stesso processo con un'altra sessione (una conversazione ripresa): la vecchia è chiusa.
        let replaced = records[path].flatMap { $0.sessionID != record.sessionID ? $0.sessionID : nil }
        records[path] = record
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                if let replaced { AgentAsks.shared.sessionGone(replaced) }
                AgentAsks.shared.sessionChanged(record)
            }
        }
        scheduleSweep()
    }

    /// Una sessione chiusa di forza (o caduta) mentre aspetta una risposta lascia il suo file com'era, e nessuno lo
    /// riscrive più: finché qualcuna aspetta, ogni quattro secondi si guarda se il suo processo c'è ancora. Senza
    /// nessuno in attesa non gira niente.
    private func scheduleSweep() {
        guard records.values.contains(where: \.isWaiting) else {
            sweep?.cancel()
            sweep = nil
            return
        }
        guard sweep == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 4, repeating: 4, leeway: .seconds(1))
        timer.setEventHandler { [weak self] in
            guard let self, self.running else { return }
            for (path, record) in self.records where record.isWaiting && kill(record.pid, 0) != 0 && errno == ESRCH {
                self.records[path] = nil
                let id = record.sessionID
                DispatchQueue.main.async { MainActor.assumeIsolated { AgentAsks.shared.sessionGone(id) } }
            }
            self.scheduleSweep()
        }
        timer.resume()
        sweep = timer
    }
}
