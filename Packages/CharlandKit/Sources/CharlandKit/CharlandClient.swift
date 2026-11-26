import Foundation

/// Un cliente per il socket locale di Charland.
///
///     let client = CharlandClient()
///     try client.connect()
///     var m = ActivityMessage(op: .upsert, client: "backup", id: "notte")
///     m.template = .progress
///     m.title = "Backup"
///     m.progress = 0.4
///     _ = try client.send(m)
///
/// Se Charland è chiusa, `connect` fallisce subito con `notRunning`: chi chiama va avanti
/// come se niente fosse.
public final class CharlandClient: @unchecked Sendable {
    public enum Failure: Error, CustomStringConvertible {
        case notRunning
        case io(String)
        case rejected(String)

        public var description: String {
            switch self {
            case .notRunning: "Charland non è aperta"
            case .io(let why): "errore di comunicazione: \(why)"
            case .rejected(let why): why
            }
        }
    }

    private var fd: Int32 = -1
    private var buffer = Data()

    public init() {}

    deinit { close() }

    public func connect(path: String = CharlandPaths.socket.path) throws {
        close()
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw Failure.io("socket") }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard bytes.count < capacity else {
            Darwin.close(descriptor)
            throw Failure.io("percorso del socket troppo lungo")
        }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: bytes)
        }
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard result == 0 else {
            Darwin.close(descriptor)
            throw Failure.notRunning
        }
        // Scrivere su un socket chiuso non deve uccidere il processo.
        var on: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        fd = descriptor
    }

    public var isConnected: Bool { fd >= 0 }

    public func close() {
        if fd >= 0 { Darwin.close(fd) }
        fd = -1
        buffer.removeAll()
    }

    /// Manda un messaggio e aspetta la risposta.
    @discardableResult
    public func send(_ message: ActivityMessage, timeout: Double = 5) throws -> ServerReply {
        var data = try ActivitySchema.encode(message)
        data.append(0x0A)
        try write(data)
        // Le risposte hanno `ok`; gli eventi arrivati nel frattempo si tengono da parte.
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            guard let reply = try readReply(timeout: max(0.01, deadline.timeIntervalSinceNow)) else {
                throw Failure.io("nessuna risposta")
            }
            if reply.ok != nil {
                if reply.ok == false { throw Failure.rejected(reply.error ?? "rifiutato") }
                return reply
            }
            pendingEvents.append(reply)
        }
    }

    private var pendingEvents: [ServerReply] = []

    /// Butta gli eventi arrivati prima dell'ultima risposta. Serve quando un messaggio nuovo cambia quello che si vede:
    /// un tocco arrivato prima era per la schermata di prima.
    public func dropPendingEvents() {
        pendingEvents.removeAll()
    }

    /// Aspetta il prossimo evento (un'azione toccata, un'attività chiusa). `nil` se scade il tempo.
    public func nextEvent(timeout: Double) throws -> ServerReply? {
        if !pendingEvents.isEmpty { return pendingEvents.removeFirst() }
        return try readReply(timeout: timeout)
    }

    private func write(_ data: Data) throws {
        guard fd >= 0 else { throw Failure.notRunning }
        var sent = 0
        try data.withUnsafeBytes { raw in
            while sent < raw.count {
                let n = Darwin.write(fd, raw.baseAddress!.advanced(by: sent), raw.count - sent)
                if n <= 0 { throw Failure.io("scrittura") }
                sent += n
            }
        }
    }

    private func readReply(timeout: Double) throws -> ServerReply? {
        guard fd >= 0 else { throw Failure.notRunning }
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            if let newline = buffer.firstIndex(of: 0x0A) {
                let line = buffer[buffer.startIndex..<newline]
                buffer.removeSubrange(buffer.startIndex...newline)
                if line.isEmpty { continue }
                return try JSONDecoder().decode(ServerReply.self, from: Data(line))
            }
            let remaining = deadline.timeIntervalSinceNow
            if remaining <= 0 { return nil }
            var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let ready = poll(&descriptor, 1, Int32(min(remaining, 3600) * 1000))
            if ready == 0 { return nil }
            if ready < 0 {
                if errno == EINTR { continue }
                throw Failure.io("attesa")
            }
            var chunk = [UInt8](repeating: 0, count: 4096)
            let n = read(fd, &chunk, chunk.count)
            if n <= 0 { throw Failure.io("connessione chiusa") }
            buffer.append(contentsOf: chunk[0..<n])
        }
    }
}

/// Legge l'avanzamento dall'uscita di un programma: percentuali e contatori "[12/340]".
/// Serve a `charland watch -- <comando>`.
public struct ProgressParser: Sendable {
    public struct Update: Sendable, Equatable {
        /// Avanzamento fra 0 e 1, se la riga ne ha uno.
        public var fraction: Double?
        /// L'ultima riga non vuota, ripulita.
        public var line: String
    }

    private var carry = ""
    public private(set) var fraction: Double?

    public init() {}

    /// Dà in pasto un pezzo di uscita. Restituisce l'ultimo aggiornamento, se c'è una riga nuova.
    public mutating func feed(_ text: String) -> Update? {
        carry += text
        // Le barre di avanzamento riscrivono la riga con un ritorno a capo senza nuova riga.
        var parts = carry.components(separatedBy: CharacterSet(charactersIn: "\r\n"))
        carry = parts.removeLast()
        var last: Update?
        for part in parts {
            let line = Self.strip(part).trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            if let f = Self.fraction(in: line) { fraction = f }
            last = Update(fraction: fraction, line: String(line.prefix(80)))
        }
        return last
    }

    /// Toglie i codici di colore e di movimento del cursore.
    static func strip(_ text: String) -> String {
        var out = ""
        var iterator = text.unicodeScalars.makeIterator()
        while let scalar = iterator.next() {
            if scalar == "\u{1B}" {
                guard let next = iterator.next() else { break }
                if next == "[" {
                    while let c = iterator.next() {
                        if (0x40...0x7E).contains(c.value) { break }
                    }
                }
                continue
            }
            if scalar.value < 0x20, scalar != "\t" { continue }
            out.unicodeScalars.append(scalar)
        }
        return out
    }

    /// L'avanzamento scritto in una riga: l'ultima percentuale, oppure un contatore "n/m".
    public static func fraction(in line: String) -> Double? {
        let scalars = Array(line.unicodeScalars)
        var found: Double?
        var i = 0
        while i < scalars.count {
            guard scalars[i].properties.numericType != nil, scalars[i].isASCII else { i += 1; continue }
            var j = i
            var number = ""
            while j < scalars.count, (scalars[j].isASCII && scalars[j].properties.numericType != nil) || scalars[j] == "." {
                number.unicodeScalars.append(scalars[j])
                j += 1
            }
            var k = j
            while k < scalars.count, scalars[k] == " " { k += 1 }
            if k < scalars.count, scalars[k] == "%", let value = Double(number), value >= 0, value <= 100 {
                found = value / 100
            } else if j < scalars.count, scalars[j] == "/" {
                // Un contatore "n/m": conta solo fra parentesi quadre o tonde, o seguito da uno spazio,
                // per non scambiare una data o un percorso per un avanzamento.
                var m = j + 1
                var total = ""
                while m < scalars.count, scalars[m].isASCII, scalars[m].properties.numericType != nil {
                    total.unicodeScalars.append(scalars[m])
                    m += 1
                }
                let before = i > 0 ? scalars[i - 1] : " "
                let after = m < scalars.count ? scalars[m] : " "
                if let n = Double(number), let t = Double(total), t > 0, n <= t, !number.contains("."),
                   "[( ".unicodeScalars.contains(before), "]) ".unicodeScalars.contains(after) {
                    found = n / t
                }
                j = max(j, m)
            }
            i = max(j, i + 1)
        }
        return found
    }
}
