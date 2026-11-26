import Foundation

// Il motore vocale di Charland. Gira come servizio XPC dentro l'app:
// carica il modello al primo uso e muore quando l'app chiude la connessione,
// così la memoria del modello torna libera dopo qualche minuto di riposo.

final class Engine: NSObject, VoiceEngineProtocol, @unchecked Sendable {
    private let queue = DispatchQueue(label: "motore-vocale", qos: .userInitiated)
    private var recognizer: SherpaRecognizer?

    func load(modelFolder: String, threads: Int, reply: @escaping @Sendable (Bool, String) -> Void) {
        queue.async {
            if let current = self.recognizer, current.modelFolder == modelFolder, current.threads == Int32(threads) {
                reply(true, "già caricato")
                return
            }
            let start = Date()
            do {
                self.recognizer = nil
                self.recognizer = try SherpaRecognizer(modelFolder: modelFolder, threads: Int32(threads))
                reply(true, String(format: "%.2f", Date().timeIntervalSince(start)))
            } catch {
                reply(false, "\(error)")
            }
        }
    }

    func transcribe(samples: Data, hotwords: String, reply: @escaping @Sendable (String, String, Double) -> Void) {
        queue.async {
            guard let recognizer = self.recognizer else {
                reply("", "", -1)
                return
            }
            let count = samples.count / MemoryLayout<Float>.size
            var floats = [Float](repeating: 0, count: count)
            _ = floats.withUnsafeMutableBytes { samples.copyBytes(to: $0) }
            let out = recognizer.transcribe(floats, hotwords: hotwords)
            reply(out.text, out.boosted ?? "", out.seconds)
        }
    }

    func unload(reply: @escaping @Sendable () -> Void) {
        queue.async {
            self.recognizer = nil
            reply()
        }
    }

    func status(reply: @escaping @Sendable (String, String, Bool, Bool) -> Void) {
        queue.async {
            reply(SherpaRecognizer.version, self.recognizer?.modelFolder ?? "", NetworkLock.engaged,
                  self.recognizer?.boosts ?? false)
        }
    }
}

final class ServiceDelegate: NSObject, NSXPCListenerDelegate {
    let engine = Engine()

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        connection.exportedInterface = NSXPCInterface(with: VoiceEngineProtocol.self)
        connection.exportedObject = engine
        connection.resume()
        return true
    }
}

// Prima di tutto: la rete si chiude, prima ancora di caricare un modello.
NetworkLock.engage()
let delegate = ServiceDelegate()
let listener = NSXPCListener.service()
listener.delegate = delegate
listener.resume()
