import Foundation
import SherpaOnnx

/// Un riconoscitore vocale di sherpa-onnx (Parakeet TDT o Orukeet), tutto sul Mac.
/// Non è sicuro fra thread: lo usa un solo thread per volta, quello del motore.
///
/// Con la libreria modificata da Charland (Scripts/compila-sherpa.sh) e un modello che porta il suo
/// `bpe.vocab`, lo stesso modello in memoria legge l'audio in due modi: la passata sicura di sempre (greedy) e
/// la ricerca a fascio che favorisce le parole del vocabolario. L'analisi dell'audio, la parte che costa, si fa
/// una volta sola.
final class SherpaRecognizer {
    private let recognizer: OpaquePointer
    let modelFolder: String
    let threads: Int32
    /// Questo riconoscitore sa favorire le parole del vocabolario.
    let boosts: Bool
    /// I caratteri che il modello sa scrivere: una parola con altri caratteri non si può favorire.
    private let alphabet: Set<Character>

    struct Output {
        /// La passata sicura.
        var text: String
        /// La passata col vocabolario, se c'è stata.
        var boosted: String?
        /// Tempo di calcolo in secondi.
        var seconds: Double
    }

    enum Failure: Error, CustomStringConvertible {
        case missingFile(String)
        case cannotCreate
        var description: String {
            switch self {
            case .missingFile(let f): "manca il file del modello: \(f)"
            case .cannotCreate: "il motore non è riuscito a caricare il modello"
            }
        }
    }

    /// La libreria ha la modifica di Charland (due letture della stessa analisi)?
    static var hasTwoDecoders: Bool { version.contains("charland") }

    /// `modelFolder` contiene encoder.int8.onnx, decoder.int8.onnx, joiner.int8.onnx e tokens.txt; con
    /// `bpe.vocab` accanto si possono favorire le parole del vocabolario.
    init(modelFolder: String, threads: Int32 = 4) throws {
        self.modelFolder = modelFolder
        self.threads = threads
        let files = ["encoder.int8.onnx", "decoder.int8.onnx", "joiner.int8.onnx", "tokens.txt"]
        for f in files where !FileManager.default.fileExists(atPath: modelFolder + "/" + f) {
            throw Failure.missingFile(f)
        }
        let vocab = modelFolder + "/bpe.vocab"
        boosts = Self.hasTwoDecoders && FileManager.default.fileExists(atPath: vocab)
        alphabet = boosts ? Self.alphabet(tokens: modelFolder + "/tokens.txt") : []

        var held: [UnsafeMutablePointer<CChar>] = []
        func c(_ s: String) -> UnsafePointer<CChar> {
            let p = strdup(s)!
            held.append(p)
            return UnsafePointer(p)
        }
        defer { held.forEach { free($0) } }

        var config = SherpaOnnxOfflineRecognizerConfig()
        config.feat_config.sample_rate = 16000
        config.feat_config.feature_dim = 80
        config.model_config.transducer.encoder = c(modelFolder + "/encoder.int8.onnx")
        config.model_config.transducer.decoder = c(modelFolder + "/decoder.int8.onnx")
        config.model_config.transducer.joiner = c(modelFolder + "/joiner.int8.onnx")
        config.model_config.tokens = c(modelFolder + "/tokens.txt")
        config.model_config.num_threads = threads
        config.model_config.provider = c("cpu")
        config.model_config.model_type = c("nemo_transducer")
        config.model_config.debug = 0
        if boosts {
            // Con la libreria modificata un flusso senza parole resta greedy; uno con le parole si legge
            // nei due modi dalla stessa analisi (vedi `transcribe`).
            config.decoding_method = c("modified_beam_search")
            config.max_active_paths = 4
            config.hotwords_score = 1.5
            config.model_config.modeling_unit = c("bpe")
            config.model_config.bpe_vocab = c(vocab)
        } else {
            config.decoding_method = c("greedy_search")
        }
        guard let r = SherpaOnnxCreateOfflineRecognizer(&config) else { throw Failure.cannotCreate }
        recognizer = r
    }

    deinit {
        SherpaOnnxDestroyOfflineRecognizer(recognizer)
    }

    /// Tutti i caratteri che compaiono nei pezzi del modello.
    private static func alphabet(tokens path: String) -> Set<Character> {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return [] }
        var out = Set<Character>()
        for line in text.split(whereSeparator: \.isNewline) {
            guard let token = line.split(separator: " ").first, !token.hasPrefix("<") else { continue }
            for ch in token where ch != "▁" { out.insert(ch) }
        }
        return out
    }

    /// Tiene solo le righe che il modello sa scrivere per intero. Una parola con caratteri che non conosce
    /// verrebbe tagliata a metà, e favorirebbe un pezzo qualunque.
    func usable(_ hotwords: String) -> String {
        hotwords.split(separator: "/").filter { line in
            // «parola :punteggio»: si guarda solo la parola
            let phrase = line.split(separator: " ").filter { !$0.hasPrefix(":") }
            return !phrase.isEmpty && phrase.allSatisfy { $0.allSatisfy(alphabet.contains) }
        }.joined(separator: "/")
    }

    /// Trascrive audio mono a 16 kHz, campioni fra -1 e 1. Con `hotwords` (e un riconoscitore che le sa
    /// favorire) restituisce anche la passata col vocabolario.
    func transcribe(_ samples: [Float], hotwords: String = "") -> Output {
        let start = DispatchTime.now().uptimeNanoseconds
        let words = boosts ? usable(hotwords) : ""
        let created = words.isEmpty ? SherpaOnnxCreateOfflineStream(recognizer)
                                    : SherpaOnnxCreateOfflineStreamWithHotwords(recognizer, words)
        guard !samples.isEmpty, let stream = created else {
            if let created { SherpaOnnxDestroyOfflineStream(created) }
            return Output(text: "", boosted: nil, seconds: 0)
        }
        defer { SherpaOnnxDestroyOfflineStream(stream) }
        samples.withUnsafeBufferPointer { buffer in
            SherpaOnnxAcceptWaveformOffline(stream, 16000, buffer.baseAddress, Int32(buffer.count))
        }
        SherpaOnnxDecodeOfflineStream(recognizer, stream)
        var text = ""
        var safe = ""
        if let result = SherpaOnnxGetOfflineStreamResult(stream) {
            if let t = result.pointee.text { text = String(cString: t) }
            // Con le parole, la libreria modificata mette qui la passata sicura della stessa analisi.
            if let l = result.pointee.lang { safe = String(cString: l) }
            SherpaOnnxDestroyOfflineRecognizerResult(result)
        }
        let seconds = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        safe = safe.trimmingCharacters(in: .whitespacesAndNewlines)
        if words.isEmpty { return Output(text: text, boosted: nil, seconds: seconds) }
        return Output(text: safe, boosted: text, seconds: seconds)
    }

    static var version: String { String(cString: SherpaOnnxGetVersionStr()) }
}
