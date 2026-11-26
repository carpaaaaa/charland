import Foundation
import CharlandKit

/// Il socket locale dell'API: ~/Library/Application Support/Charland/api.sock.
/// Lo può aprire solo il tuo utente (permessi 0600, cartella 0700). Ogni riga è un messaggio
/// JSON; la risposta e gli eventi (un'azione toccata) tornano sullo stesso canale.
final class APIServer: @unchecked Sendable {
    /// Una connessione aperta, a cui si possono mandare eventi.
    final class Connection: @unchecked Sendable, Hashable {
        let fd: Int32
        fileprivate var source: DispatchSourceRead?
        fileprivate var buffer = Data()
        fileprivate var closed = false
        private let queue: DispatchQueue

        fileprivate init(fd: Int32, queue: DispatchQueue) {
            self.fd = fd
            self.queue = queue
        }

        /// Manda una risposta o un evento. Si può chiamare da qualsiasi thread.
        func send(_ reply: ServerReply) {
            let data = reply.line()
            queue.async { [self] in
                guard !closed else { return }
                data.withUnsafeBytes { raw in
                    var sent = 0
                    while sent < raw.count {
                        let n = write(fd, raw.baseAddress!.advanced(by: sent), raw.count - sent)
                        if n <= 0 { break }
                        sent += n
                    }
                }
            }
        }

        static func == (a: Connection, b: Connection) -> Bool { a === b }
        func hash(into hasher: inout Hasher) { hasher.combine(ObjectIdentifier(self)) }
    }

    private let queue = DispatchQueue(label: "api-socket")
    private var listener: DispatchSourceRead?
    private var listenFD: Int32 = -1
    private var connections: Set<Connection> = []
    private let path: String
    /// Chiamata sul thread principale per ogni messaggio valido.
    private let onMessage: @MainActor (ActivityMessage, Connection) -> ServerReply
    private let onClose: @MainActor (Connection) -> Void
    /// Al massimo 40 messaggi al secondo per connessione.
    private static let burst = 40

    init(path: String = CharlandPaths.socket.path,
         onMessage: @escaping @MainActor (ActivityMessage, Connection) -> ServerReply,
         onClose: @escaping @MainActor (Connection) -> Void) {
        self.path = path
        self.onMessage = onMessage
        self.onClose = onClose
    }

    func start() throws {
        let folder = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        chmod(folder, 0o700)
        unlink(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw CocoaError(.fileWriteUnknown) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
            close(fd)
            throw CocoaError(.fileWriteInvalidFileName)
        }
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
        // Il socket nasce già chiuso agli altri utenti.
        let oldMask = umask(0o177)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        umask(oldMask)
        guard bound == 0, listen(fd, 16) == 0 else {
            close(fd)
            throw CocoaError(.fileWriteNoPermission)
        }
        chmod(path, 0o600)
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL, 0) | O_NONBLOCK)
        listenFD = fd
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.accept() }
        source.resume()
        listener = source
    }

    func stop() {
        queue.sync {
            listener?.cancel()
            listener = nil
            if listenFD >= 0 { close(listenFD) }
            listenFD = -1
            for connection in connections { shut(connection, notify: false) }
            connections.removeAll()
        }
        unlink(path)
    }

    private func accept() {
        while true {
            let fd = Darwin.accept(listenFD, nil, nil)
            guard fd >= 0 else { return }
            // Solo lo stesso utente: il socket è 0600, e qui si controlla di nuovo.
            var uid: uid_t = 0
            var gid: gid_t = 0
            guard getpeereid(fd, &uid, &gid) == 0, uid == getuid() else {
                close(fd)
                continue
            }
            var on: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
            let connection = Connection(fd: fd, queue: queue)
            let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
            source.setEventHandler { [weak self, weak connection] in
                guard let self, let connection else { return }
                self.read(connection)
            }
            source.resume()
            connection.source = source
            connections.insert(connection)
        }
    }

    private var windowStart = Date()
    private var windowCount: [ObjectIdentifier: Int] = [:]

    private func read(_ connection: Connection) {
        var chunk = [UInt8](repeating: 0, count: 8192)
        let n = Darwin.read(connection.fd, &chunk, chunk.count)
        guard n > 0 else {
            shut(connection, notify: true)
            connections.remove(connection)
            return
        }
        connection.buffer.append(contentsOf: chunk[0..<n])
        // Una riga più lunga del massimo non è un messaggio valido: si chiude.
        if connection.buffer.count > ActivitySchema.maxBytes * 4, connection.buffer.firstIndex(of: 0x0A) == nil {
            connection.send(ServerReply(ok: false, error: "messaggio troppo lungo"))
            shut(connection, notify: true)
            connections.remove(connection)
            return
        }
        while let newline = connection.buffer.firstIndex(of: 0x0A) {
            let line = Data(connection.buffer[connection.buffer.startIndex..<newline])
            connection.buffer.removeSubrange(connection.buffer.startIndex...newline)
            guard !line.isEmpty else { continue }
            if Date().timeIntervalSince(windowStart) > 1 {
                windowStart = Date()
                windowCount.removeAll()
            }
            let key = ObjectIdentifier(connection)
            windowCount[key, default: 0] += 1
            guard windowCount[key, default: 0] <= Self.burst else {
                connection.send(ServerReply(ok: false, error: "troppi messaggi: al massimo \(Self.burst) al secondo"))
                continue
            }
            do {
                let message = try ActivitySchema.decode(line)
                let handler = onMessage
                Task { @MainActor in
                    connection.send(handler(message, connection))
                }
            } catch {
                connection.send(ServerReply(ok: false, error: "\(error)"))
            }
        }
    }

    private func shut(_ connection: Connection, notify: Bool) {
        guard !connection.closed else { return }
        connection.closed = true
        connection.source?.cancel()
        connection.source = nil
        close(connection.fd)
        if notify {
            let handler = onClose
            Task { @MainActor in handler(connection) }
        }
    }
}
