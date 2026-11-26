import Foundation
import CharlandCore

/// Parla con il motore vocale, che gira in un processo a parte.
/// Il modello si carica al primo uso; dopo qualche minuto di riposo la connessione si chiude
/// e il processo del motore muore, liberando la memoria del modello.
@MainActor
final class VoiceEngineClient {
    static let shared = VoiceEngineClient()

    private var connection: NSXPCConnection?
    private var idleTimer: Timer?
    private(set) var loadedModel: String?
    /// Dopo quanti secondi di riposo il motore si spegne.
    var idleSeconds: TimeInterval = 300

    struct Output: Sendable {
        /// La passata sicura.
        var text: String
        /// La passata che favorisce il vocabolario, se c'è stata.
        var boosted: String?
        /// Secondi di calcolo dentro il motore.
        var engineSeconds: Double
        /// Secondi totali, andata e ritorno compresi.
        var totalSeconds: Double
    }

    struct Status: Sendable {
        var version: String
        var model: String
        var networkClosed: Bool
        /// Il motore sa favorire le parole del vocabolario (libreria modificata e modello col suo `bpe.vocab`).
        var boosts: Bool
    }

    enum Failure: Error, CustomStringConvertible {
        case unavailable(String)
        case loadFailed(String)
        var description: String {
            switch self {
            case .unavailable(let why): "il motore vocale non risponde: \(why)"
            case .loadFailed(let why): "il modello non si carica: \(why)"
            }
        }
    }

    private init() {}

    private func connect() -> NSXPCConnection {
        if let connection { return connection }
        let c = NSXPCConnection(serviceName: Identity.voiceServiceID)
        c.remoteObjectInterface = NSXPCInterface(with: VoiceEngineProtocol.self)
        // Questi avvisi arrivano su un thread del sistema, non su quello principale, e quindi in ritardo: valgono
        // solo se parlano ancora del collegamento in uso. Dopo uno spegnimento seguito subito da una riaccensione
        // l'avviso del collegamento vecchio staccava quello nuovo e gli faceva ricaricare il modello.
        let id = ObjectIdentifier(c)
        c.invalidationHandler = { @Sendable [weak self] in
            Task { @MainActor in
                guard let self, self.connection.map(ObjectIdentifier.init) == id else { return }
                self.connection = nil
                self.loadedModel = nil
            }
        }
        c.interruptionHandler = { @Sendable [weak self] in
            // Il motore è caduto: alla prossima dettatura riparte da solo e ricarica il modello.
            Task { @MainActor in
                guard let self, self.connection.map(ObjectIdentifier.init) == id else { return }
                self.loadedModel = nil
            }
        }
        c.resume()
        connection = c
        return c
    }

    private func touch() {
        idleTimer?.invalidate()
        let timer = Timer(timeInterval: idleSeconds, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.shutdown() }
        }
        RunLoop.main.add(timer, forMode: .common)
        idleTimer = timer
    }

    /// Spegne il motore: la memoria del modello torna libera.
    func shutdown() {
        idleTimer?.invalidate()
        idleTimer = nil
        connection?.invalidate()
        connection = nil
        loadedModel = nil
    }

    /// Una chiamata al motore. Le risposte arrivano su un thread del sistema: per questo
    /// questa funzione non appartiene al thread principale.
    nonisolated private static func call<T: Sendable>(
        _ box: ConnectionBox,
        _ body: @escaping @Sendable (VoiceEngineProtocol, @escaping @Sendable (T) -> Void) -> Void
    ) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            let once = Once()
            let proxy = box.connection.remoteObjectProxyWithErrorHandler { error in
                if once.claim() { continuation.resume(throwing: Failure.unavailable(error.localizedDescription)) }
            } as? VoiceEngineProtocol
            guard let proxy else {
                if once.claim() { continuation.resume(throwing: Failure.unavailable("nessun motore")) }
                return
            }
            body(proxy) { value in
                if once.claim() { continuation.resume(returning: value) }
            }
        }
    }

    /// Carica un modello (se non è già quello caricato). Restituisce i secondi impiegati.
    @discardableResult
    func load(modelFolder: String, threads: Int = VoiceEngineClient.defaultThreads) async throws -> Double {
        touch()
        if loadedModel == modelFolder { return 0 }
        // Il motore butta il modello vecchio prima di caricare il nuovo: se il caricamento fallisce non ne ha più
        // nessuno. Senza questa riga qui restava segnato quello di prima, e tornando a quello ogni dettatura
        // falliva con «nessun modello caricato» fino allo spegnimento del motore.
        loadedModel = nil
        let box = ConnectionBox(connect())
        let result: LoadReply = try await Self.call(box) { proxy, reply in
            proxy.load(modelFolder: modelFolder, threads: threads) { ok, detail in reply(LoadReply(ok: ok, detail: detail)) }
        }
        guard result.ok else { throw Failure.loadFailed(result.detail) }
        loadedModel = modelFolder
        return Double(result.detail) ?? 0
    }

    /// Trascrive. Con `hotwords` (le parole del vocabolario nel formato del motore) arriva anche la passata che
    /// le favorisce, letta dalla stessa analisi dell'audio.
    func transcribe(_ samples: [Float], hotwords: String = "") async throws -> Output {
        touch()
        let box = ConnectionBox(connect())
        let data = samples.withUnsafeBufferPointer { Data(buffer: $0) }
        let start = DispatchTime.now().uptimeNanoseconds
        let result: TranscribeReply = try await Self.call(box) { proxy, reply in
            proxy.transcribe(samples: data, hotwords: hotwords) { text, boosted, seconds in
                reply(TranscribeReply(text: text, boosted: boosted, seconds: seconds))
            }
        }
        if result.seconds < 0 { throw Failure.loadFailed("nessun modello caricato") }
        let total = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9
        return Output(text: result.text, boosted: result.boosted.isEmpty ? nil : result.boosted,
                      engineSeconds: result.seconds, totalSeconds: total)
    }

    func status() async -> Status? {
        let box = ConnectionBox(connect())
        return try? await Self.call(box) { proxy, reply in
            proxy.status { version, model, closed, boosts in
                reply(Status(version: version, model: model, networkClosed: closed, boosts: boosts))
            }
        }
    }

    private struct LoadReply: Sendable { var ok: Bool; var detail: String }
    private struct TranscribeReply: Sendable { var text: String; var boosted: String; var seconds: Double }

    /// Quanti thread dare al motore: tre quarti dei processori, al massimo 4.
    nonisolated static var defaultThreads: Int {
        max(1, min(4, ProcessInfo.processInfo.activeProcessorCount * 3 / 4))
    }
}

/// La connessione al motore, da passare fuori dal thread principale.
/// NSXPCConnection si può usare da qualsiasi thread.
struct ConnectionBox: @unchecked Sendable {
    let connection: NSXPCConnection
    init(_ connection: NSXPCConnection) { self.connection = connection }
}

/// Garantisce che una risposta venga usata una volta sola.
final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if done { return false }
        done = true
        return true
    }
}
