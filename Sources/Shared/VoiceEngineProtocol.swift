import Foundation

/// Il contratto fra l'app e il motore vocale, che gira in un processo a parte (servizio XPC).
/// Così l'isola resta leggera, e un crash del motore non la chiude.
@objc protocol VoiceEngineProtocol {
    /// Carica un modello. Risponde con `true` e il tempo impiegato, oppure `false` e il motivo.
    func load(modelFolder: String, threads: Int, reply: @escaping @Sendable (Bool, String) -> Void)
    /// Trascrive audio mono a 16 kHz (campioni Float32).
    ///
    /// `hotwords` sono le parole del vocabolario da favorire, una per riga separate da «/», ognuna col suo
    /// punteggio («ChatGPT :1.5/Charmail :2.0»); vuoto per la sola passata sicura. Risponde con il testo della
    /// passata sicura, quello della passata col vocabolario (vuoto se non c'è stata) e i secondi di calcolo.
    func transcribe(samples: Data, hotwords: String, reply: @escaping @Sendable (String, String, Double) -> Void)
    /// Libera il modello dalla memoria.
    func unload(reply: @escaping @Sendable () -> Void)
    /// Stato del motore: versione, modello caricato, se la rete è davvero chiusa, e se sa favorire il vocabolario.
    func status(reply: @escaping @Sendable (String, String, Bool, Bool) -> Void)
}

enum VoiceEngineConstants {
    static let sampleRate = 16000.0
}
