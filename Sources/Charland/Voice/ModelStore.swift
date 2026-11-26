import Foundation
import CryptoKit
import CharlandCore

/// Un modello vocale. I pesi hanno licenze loro: l'app li scarica dalla fonte ufficiale
/// al primo uso e mostra l'attribuzione nelle informazioni.
struct VoiceModel: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let url: URL
    /// Cartella dentro l'archivio scaricato.
    let extractDir: String
    let megabytes: Int
    let license: String
    let attribution: String

    /// Parakeet TDT 0.6B v3 originale di NVIDIA: in italiano è il più preciso dei due.
    static let parakeetV3 = VoiceModel(
        id: "parakeet-tdt-0.6b-v3-int8",
        title: "Parakeet v3",
        url: URL(string: "https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/sherpa-onnx-nemo-parakeet-tdt-0.6b-v3-int8.tar.bz2")!,
        extractDir: "sherpa-onnx-nemo-parakeet-tdt-0.6b-v3-int8",
        megabytes: 640,
        license: "CC BY 4.0",
        attribution: "NVIDIA Parakeet TDT 0.6B v3")

    /// Orukeet v0.1.0 di Oruk AI: il modello che usa OpenWhispr.
    static let orukeet = VoiceModel(
        id: "orukeet-v0.1.0",
        title: "Orukeet v0.1.0",
        url: URL(string: "https://huggingface.co/oruk/orukeet/resolve/55a984d46f68323301837194ce647c702f55facc/onnx/sherpa-onnx-orukeet-v0.1.0-int8.tar.bz2")!,
        extractDir: "sherpa-onnx-orukeet-v0.1.0-int8",
        megabytes: 641,
        license: "CC BY-SA 4.0",
        attribution: "Orukeet di Oruk AI, adattamento di NVIDIA Parakeet TDT 0.6B v3")

    /// In ordine di preferenza. Nel confronto del 16 novembre 2026 Orukeet ha fatto gli stessi
    /// errori del motore di OpenWhispr ed è stato più veloce di Parakeet v3 originale.
    static let all = [orukeet, parakeetV3]
    static let requiredFiles = ["encoder.int8.onnx", "decoder.int8.onnx", "joiner.int8.onnx", "tokens.txt"]
}

enum ModelStore {
    /// ~/Library/Application Support/Charland/Modelli
    static var root: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let url = base.appendingPathComponent(Identity.supportFolder, isDirectory: true).appendingPathComponent("Modelli", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func folder(_ model: VoiceModel) -> URL {
        root.appendingPathComponent(model.id, isDirectory: true)
    }

    static func isInstalled(_ model: VoiceModel) -> Bool {
        VoiceModel.requiredFiles.allSatisfy { FileManager.default.fileExists(atPath: folder(model).appendingPathComponent($0).path) }
    }

    static func bytes(_ model: VoiceModel) -> Int64 {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder(model), includingPropertiesForKeys: [.fileSizeKey])) ?? []
        return files.reduce(0) { $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
    }

    /// Il modello scelto, o il migliore fra quelli installati.
    static var selected: VoiceModel? {
        get {
            // per le prove: CHARLAND_MODELLO=<id> sceglie il modello senza toccare le impostazioni
            if let id = ProcessInfo.processInfo.environment["CHARLAND_MODELLO"],
               let model = VoiceModel.all.first(where: { $0.id == id }), isInstalled(model) { return model }
            if let id = UserDefaults.standard.string(forKey: "voiceModel"),
               let model = VoiceModel.all.first(where: { $0.id == id }), isInstalled(model) { return model }
            return VoiceModel.all.first(where: isInstalled)
        }
        set { UserDefaults.standard.set(newValue?.id, forKey: "voiceModel") }
    }

    /// L'impronta di `tokens.txt` di Parakeet TDT 0.6B v3 (Orukeet usa gli stessi pezzi).
    static let parakeetV3Tokens = "d58544679ea4bc6ac563d1f545eb7d474bd6cfa467f0a6e2c1dc1c7d37e3c35d"

    /// Il vocabolario dei pezzi del modello (`bpe.vocab`), che serve al motore per favorire le parole del
    /// vocabolario della dettatura. Orukeet lo porta con sé; Parakeet v3 originale no, ma i pezzi sono gli
    /// stessi (stessa impronta di `tokens.txt`): gli si mette accanto la copia che sta dentro l'app.
    static func ensureVocabulary(_ model: VoiceModel) {
        let dest = folder(model).appendingPathComponent("bpe.vocab")
        guard isInstalled(model), !FileManager.default.fileExists(atPath: dest.path),
              let bundled = Bundle.main.url(forResource: "parakeet-v3.bpe", withExtension: "vocab"),
              sha256(of: folder(model).appendingPathComponent("tokens.txt")) == parakeetV3Tokens else { return }
        try? FileManager.default.copyItem(at: bundled, to: dest)
    }

    static func remove(_ model: VoiceModel) {
        try? FileManager.default.removeItem(at: folder(model))
    }

    /// Scarica un modello dalla sua fonte ufficiale e lo scompatta.
    static func download(_ model: VoiceModel, progress: @escaping @Sendable (Double) -> Void) async throws {
        let (archive, response) = try await URLSession.shared.download(from: model.url, delegate: DownloadProgress(progress))
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw CocoaError(.fileReadUnknown) }
        let work = root.appendingPathComponent("scarico-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        process.arguments = ["-xjf", archive.path, "-C", work.path]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw CocoaError(.fileReadCorruptFile) }
        let extracted = work.appendingPathComponent(model.extractDir, isDirectory: true)
        try? FileManager.default.removeItem(at: folder(model))
        try FileManager.default.moveItem(at: extracted, to: folder(model))
        ensureVocabulary(model)
    }

    static func sha256(of url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try? handle.read(upToCount: 4 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

private final class DownloadProgress: NSObject, URLSessionTaskDelegate, Sendable {
    let report: @Sendable (Double) -> Void
    init(_ report: @escaping @Sendable (Double) -> Void) { self.report = report }

    func urlSession(_ session: URLSession, didCreateTask task: URLSessionTask) {
        let report = report
        let observation = task.progress.observe(\.fractionCompleted) { progress, _ in report(progress.fractionCompleted) }
        objc_setAssociatedObject(task, "avanzamento", observation, .OBJC_ASSOCIATION_RETAIN)
    }
}

/// Importa da OpenWhispr, se è installata: lingua, modo e il modello già scaricato.
/// Legge solo le chiavi delle impostazioni: quelle con chiavi o token non le guarda nemmeno.
enum OpenWhisprImport {
    struct Settings: Equatable {
        var language: String?
        var activationMode: String?
        var model: String?
        var hotkey: String?
    }

    static var supportFolder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("open-whispr")
    }

    static var cachedModelFolder: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".cache/openwhispr/parakeet-models/orukeet-v0.1.0")
    }

    static var isInstalled: Bool {
        FileManager.default.fileExists(atPath: supportFolder.appendingPathComponent(".env").path)
            || FileManager.default.fileExists(atPath: "/Applications/OpenWhispr.app")
    }

    static var hasModel: Bool {
        FileManager.default.fileExists(atPath: cachedModelFolder.appendingPathComponent("encoder.int8.onnx").path)
    }

    static func readSettings() -> Settings {
        guard let text = try? String(contentsOf: supportFolder.appendingPathComponent(".env"), encoding: .utf8) else { return Settings() }
        return parse(text)
    }

    static func parse(_ text: String) -> Settings {
        var settings = Settings()
        let secret = ["KEY", "TOKEN", "SECRET", "PASSWORD", "AUTH", "CREDENTIAL"]
        for line in text.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.hasPrefix("#"), let equals = trimmed.firstIndex(of: "=") else { continue }
            let key = String(trimmed[..<equals]).trimmingCharacters(in: .whitespaces)
            // Mai le righe con chiavi o token, nemmeno per sbaglio. Fa eccezione solo il nome del tasto.
            let isHotkey = key == "DICTATION_KEY" || key == "DICTATION_HOTKEY"
            if !isHotkey, secret.contains(where: { key.uppercased().contains($0) }) { continue }
            let value = String(trimmed[trimmed.index(after: equals)...]).trimmingCharacters(in: CharacterSet(charactersIn: " \"'"))
            switch key {
            case "DICTATION_LANGUAGE": settings.language = value
            case "ACTIVATION_MODE": settings.activationMode = value
            case "PARAKEET_MODEL": settings.model = value
            case "DICTATION_KEY", "DICTATION_HOTKEY": settings.hotkey = value
            default: break
            }
        }
        return settings
    }

    enum Failure: Error { case missing, corrupted(String) }

    /// Copia il modello Orukeet già scaricato da OpenWhispr, controllando ogni file con
    /// l'impronta del suo `download-manifest.json`. L'originale non viene spostato né toccato.
    static func importModel() throws {
        guard hasModel else { throw Failure.missing }
        let source = cachedModelFolder
        let dest = ModelStore.folder(.orukeet)
        var expected: [String: String] = [:]
        if let data = try? Data(contentsOf: source.appendingPathComponent("download-manifest.json")),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let files = json["files"] as? [[String: Any]] {
            for file in files {
                if let path = file["path"] as? String, let sha = file["sha256"] as? String { expected[path] = sha }
            }
        }
        let staging = ModelStore.root.appendingPathComponent("importazione-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: staging) }
        for name in try FileManager.default.contentsOfDirectory(atPath: source.path) where name != "download-manifest.json" {
            let from = source.appendingPathComponent(name)
            let to = staging.appendingPathComponent(name)
            try FileManager.default.copyItem(at: from, to: to)
            if let sha = expected[name], ModelStore.sha256(of: to) != sha {
                throw Failure.corrupted(name)
            }
        }
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.moveItem(at: staging, to: dest)
    }
}
