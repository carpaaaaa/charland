import Foundation
import Darwin

/// Chiude la rete per tutto il processo del motore vocale.
/// Non è una promessa: dopo questa chiamata il sistema rifiuta ogni connessione di questo
/// processo, quindi la voce non può uscire dal Mac nemmeno per errore.
enum NetworkLock {
    nonisolated(unsafe) private(set) static var engaged = false

    @discardableResult
    static func engage() -> Bool {
        typealias Initializer = @convention(c) (UnsafePointer<CChar>, UInt64, UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> Int32
        // sandbox_init con un profilo scritto qui: tutto permesso, tranne la rete.
        // (Il profilo di sistema "no-network" su macOS 27 fa uccidere il processo: provato.)
        // La funzione è cercata a runtime: se un giorno mancasse, il motore lo dichiara
        // invece di chiudersi.
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "sandbox_init") else { return false }
        let initialize = unsafeBitCast(symbol, to: Initializer.self)
        var message: UnsafeMutablePointer<CChar>?
        let result = "(version 1)(allow default)(deny network*)".withCString { initialize($0, 0, &message) }
        engaged = result == 0 && verify()
        return engaged
    }

    /// Prova davvero ad aprire una connessione: deve fallire.
    static func verify() -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return true }
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(443).bigEndian
        address.sin_addr.s_addr = inet_addr("1.1.1.1")
        let flags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        // Rete chiusa: la connessione viene rifiutata subito con "operazione non permessa".
        return result != 0 && errno == EPERM
    }
}
