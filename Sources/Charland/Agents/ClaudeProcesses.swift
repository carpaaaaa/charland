import Darwin
import Foundation
import CharlandCore

/// I processi di Claude Code accesi adesso, letti dal sistema (libproc e `KERN_PROCARGS2`): eseguibile, argomenti e
/// cartella di lavoro. Solo quelli dell'utente; costa qualche millisecondo e si chiede solo mentre l'isola mostra Claude
/// al lavoro (vedi `AgentLogWatcher`).
enum ClaudeProcesses {
    /// I processi già guardati che non sono Claude: per un minuto non si riguardano. Un numero di processo non torna
    /// in uso così in fretta (il sistema li dà in fila), e i processi di Claude già trovati si rileggono sempre.
    private static let lock = NSLock()
    nonisolated(unsafe) private static var rejected: Set<pid_t> = []
    nonisolated(unsafe) private static var rejectedSince = Date.distantPast

    static func snapshot() -> [ClaudeProcess] {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(count) + 64)
        let filled = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        guard filled > 0 else { return [] }
        let me = getuid()
        var found: [ClaudeProcess] = []
        // Un posto solo per i percorsi, e il primo vaglio sui byte: i processi sono centinaia e quasi nessuno è Claude.
        // Fare un testo per ognuno (con un posto nuovo ogni volta) costava una quindicina di millisecondi a giro, ogni
        // tre secondi per tutto il tempo che un agente lavora (misurato il 18 novembre 2026).
        var buffer = [UInt8](repeating: 0, count: 4 * Int(MAXPATHLEN))
        lock.lock()
        if Date().timeIntervalSince(rejectedSince) > 60 {
            rejected.removeAll(keepingCapacity: true)
            rejectedSince = Date()
        }
        let skip = rejected
        lock.unlock()
        var others: [pid_t] = []
        defer {
            if !others.isEmpty {
                lock.lock()
                rejected.formUnion(others)
                lock.unlock()
            }
        }
        for pid in pids.prefix(Int(filled)) where pid > 0 && !skip.contains(pid) {
            let path: String? = buffer.withUnsafeMutableBytes { raw in
                let length = Int(proc_pidpath(pid, raw.baseAddress, UInt32(raw.count)))
                guard length > 0, memmem(raw.baseAddress, length, "claude", 6) != nil || memmem(raw.baseAddress, length, "node", 4) != nil
                else { return nil }
                return String(decoding: UnsafeRawBufferPointer(start: raw.baseAddress, count: length), as: UTF8.self)
            }
            guard let path else {
                others.append(pid)
                continue
            }
            guard owner(pid) == me, let arguments = arguments(pid),
                  ClaudeLiveness.isClaude(executable: path, arguments: arguments), let cwd = workingDirectory(pid) else { continue }
            found.append(ClaudeProcess(sessionID: ClaudeLiveness.sessionID(fromArguments: arguments),
                                       projectDir: ClaudeLiveness.projectDir(forCwd: cwd)))
        }
        return found
    }

    /// Il processo di un agente, per portarne davanti la finestra: per Claude quello con la sessione negli argomenti (o,
    /// se nessuno la scrive, uno della stessa cartella senza sessione); per gli altri (`codex`, `gemini`) uno col nome
    /// dell'eseguibile che lavora in una cartella con quel nome. Costa qualche millisecondo: si chiede solo a un clic.
    static func pid(claudeSession sessionID: String?, projectDir: String?, folder: String? = nil) -> pid_t? {
        var fallback: pid_t?
        for pid in allPIDs() {
            guard let path = path(pid), path.contains("claude") || path.contains("node"), owner(pid) == getuid(),
                  let arguments = arguments(pid), ClaudeLiveness.isClaude(executable: path, arguments: arguments) else { continue }
            let session = ClaudeLiveness.sessionID(fromArguments: arguments)
            if let sessionID, session == sessionID { return pid }
            if session == nil, fallback == nil, let cwd = workingDirectory(pid) {
                if let projectDir, ClaudeLiveness.projectDir(forCwd: cwd) == projectDir { fallback = pid }
                if projectDir == nil, let folder, (cwd as NSString).lastPathComponent == folder { fallback = pid }
            }
        }
        return fallback
    }

    static func pid(named name: String, folder: String?) -> pid_t? {
        var any: pid_t?
        for pid in allPIDs() {
            guard let path = path(pid), (path as NSString).lastPathComponent.lowercased().contains(name), owner(pid) == getuid() else { continue }
            guard let folder else { return pid }
            if let cwd = workingDirectory(pid), (cwd as NSString).lastPathComponent == folder { return pid }
            if any == nil { any = pid }
        }
        return any
    }

    /// Questo processo è davvero Claude Code. Un file di stato può restare dopo un crash o un riavvio, e il suo numero
    /// di processo finire a un programma qualsiasi: senza questo controllo quella sessione sembrerebbe ancora viva.
    static func isClaude(_ pid: pid_t) -> Bool {
        guard let path = path(pid) else { return false }
        if path.lowercased().contains("claude") { return true }
        guard path.contains("node"), let arguments = arguments(pid) else { return false }
        return ClaudeLiveness.isClaude(executable: path, arguments: arguments)
    }

    /// Il processo padre.
    static func parent(_ pid: pid_t) -> pid_t? {
        var info = proc_bsdshortinfo()
        let size = Int32(MemoryLayout<proc_bsdshortinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDT_SHORTBSDINFO, 0, &info, size) == size, info.pbsi_ppid > 1 else { return nil }
        return pid_t(info.pbsi_ppid)
    }

    /// Il terminale del processo («/dev/ttys003»), se ne ha uno.
    static func tty(_ pid: pid_t) -> String? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size, info.e_tdev != UInt32.max, info.e_tdev != 0,
              let name = devname(dev_t(bitPattern: info.e_tdev), S_IFCHR) else { return nil }
        return "/dev/" + String(cString: name)
    }

    private static func allPIDs() -> [pid_t] {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(count) + 64)
        let filled = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        return filled > 0 ? pids.prefix(Int(filled)).filter { $0 > 0 } : []
    }

    private static func path(_ pid: pid_t) -> String? {
        var buffer = [UInt8](repeating: 0, count: 4 * Int(MAXPATHLEN))
        return buffer.withUnsafeMutableBytes { raw in
            let length = Int(proc_pidpath(pid, raw.baseAddress, UInt32(raw.count)))
            return length > 0 ? String(decoding: UnsafeRawBufferPointer(start: raw.baseAddress, count: length), as: UTF8.self) : nil
        }
    }

    private static func owner(_ pid: pid_t) -> uid_t? {
        var info = proc_bsdshortinfo()
        let size = Int32(MemoryLayout<proc_bsdshortinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDT_SHORTBSDINFO, 0, &info, size) == size else { return nil }
        return info.pbsi_uid
    }

    private static func workingDirectory(_ pid: pid_t) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        return withUnsafeBytes(of: info.pvi_cdir.vip_path) { raw in
            let bytes = raw.bindMemory(to: UInt8.self)
            let end = bytes.firstIndex(of: 0) ?? bytes.endIndex
            return String(decoding: bytes[..<end], as: UTF8.self)
        }
    }

    /// Gli argomenti con cui è partito: `KERN_PROCARGS2` dà il numero degli argomenti, il percorso dell'eseguibile e poi
    /// gli argomenti separati da zeri.
    private static func arguments(_ pid: pid_t) -> [String]? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return nil }
        let argc = buffer.withUnsafeBytes { $0.load(as: Int32.self) }
        var index = MemoryLayout<Int32>.size
        // Il percorso dell'eseguibile, poi gli zeri di riempimento.
        while index < size, buffer[index] != 0 { index += 1 }
        while index < size, buffer[index] == 0 { index += 1 }
        var result: [String] = []
        while index < size, result.count < Int(argc) {
            let start = index
            while index < size, buffer[index] != 0 { index += 1 }
            result.append(String(decoding: buffer[start..<index], as: UTF8.self))
            index += 1
        }
        return result
    }
}
