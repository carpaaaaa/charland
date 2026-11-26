import Foundation
import CharlandCore

/// Il banco di prova della voce: le stesse frasi passano dal motore di OpenWhispr
/// (il suo programma, con Orukeet) e dal motore di Charland, e si confrontano errori e tempi.
/// Le frasi sono dette dalle voci di sistema, così la prova si ripete uguale senza microfono.
@MainActor
enum VoiceBench {
    struct Sentence {
        let language: String
        let voice: String
        let text: String
    }

    static let sentences: [Sentence] = [
        .init(language: "it", voice: "Alice", text: "Domani alle dieci ho il dentista, ricordami di portare le lastre."),
        .init(language: "it", voice: "Eddy (Italian (Italy))", text: "Ho parlato con Rossi e il fornitore: la consegna parte lunedì mattina."),
        .init(language: "it", voice: "Alice", text: "Fai il deploy su Vercel e poi apri una pull request sul branch main."),
        .init(language: "it", voice: "Reed (Italian (Italy))", text: "Il meeting con il team di design è spostato a giovedì alle quindici e trenta."),
        .init(language: "it", voice: "Eddy (Italian (Italy))", text: "Costa venticinque euro al mese e quaranta all'anno, con sette giorni di prova."),
        .init(language: "it", voice: "Alice", text: "Scrivi a Marco che arrivo tra venti minuti, traffico permettendo."),
        .init(language: "it", voice: "Sandy (Italian (Italy))", text: "Non so se convenga usare la finestra nuova o quella vecchia per le impostazioni."),
        .init(language: "it", voice: "Alice", text: "Ricordati di comprare il latte, il pane e sei uova prima delle sette di sera."),
        .init(language: "it", voice: "Shelley (Italian (Italy))", text: "La riunione del team è fissata per il due dicembre."),
        .init(language: "it", voice: "Eddy (Italian (Italy))", text: "Il nuovo portatile ha uno schermo da quindici pollici e pesa un chilo e mezzo."),
        .init(language: "it", voice: "Alice", text: "Aggiungi una cosa da fare: chiamare il commercialista entro venerdì."),
        .init(language: "it", voice: "Reed (Italian (Italy))", text: "Secondo me la versione di ieri era più chiara, ma questa è più corta."),
        .init(language: "it", voice: "Alice", text: "Mandami il preventivo entro stasera, così domattina lo giro al cliente."),
        .init(language: "it", voice: "Sandy (Italian (Italy))", text: "Abbiamo prenotato un tavolo per quattro persone alle otto e mezza."),
        .init(language: "it", voice: "Alice", text: "Ciao Marco, ti confermo l'appuntamento di domani pomeriggio alle quattro."),
        .init(language: "it", voice: "Eddy (Italian (Italy))", text: "Ho finito la prima versione del progetto, te la mando appena torno a casa."),
        .init(language: "it", voice: "Alice", text: "Potresti controllare se il pagamento è arrivato sul conto questa mattina?"),
        .init(language: "it", voice: "Eddy (Italian (Italy))", text: "Stasera non riesco a venire, ho un impegno che non posso spostare."),
        .init(language: "it", voice: "Alice", text: "Il treno parte alle sette e venti dal binario tre, non fare tardi."),
        .init(language: "it", voice: "Eddy (Italian (Italy))", text: "Grazie per la risposta, ci sentiamo la settimana prossima con più calma."),
        .init(language: "it", voice: "Alice", text: "Mi serve una copia del contratto firmato entro la fine del mese."),
        .init(language: "it", voice: "Eddy (Italian (Italy))", text: "Abbiamo deciso di rimandare la presentazione a quando saranno pronti i dati."),
        .init(language: "it", voice: "Alice", text: "Ricordami di chiamare la banca prima di mezzogiorno per sbloccare la carta."),
        .init(language: "it", voice: "Eddy (Italian (Italy))", text: "La nuova casa ha tre camere, due bagni e un giardino piccolo ma comodo."),
        .init(language: "it", voice: "Alice", text: "Secondo te conviene partire venerdì sera oppure sabato mattina presto?"),
        .init(language: "it", voice: "Eddy (Italian (Italy))", text: "Ho letto il documento e ci sono un paio di punti che non mi convincono."),
        .init(language: "it", voice: "Alice", text: "Il medico ha detto di prendere una compressa dopo i pasti per dieci giorni."),
        .init(language: "it", voice: "Eddy (Italian (Italy))", text: "Possiamo vederci al bar sotto l'ufficio, quello con i tavoli fuori."),
        .init(language: "it", voice: "Alice", text: "Devo ancora rispondere a trenta messaggi e sono già le sei di sera."),
        .init(language: "it", voice: "Eddy (Italian (Italy))", text: "Il corriere dovrebbe consegnare il pacco domani tra le nove e mezzogiorno."),
        .init(language: "it", voice: "Alice", text: "Ti scrivo per chiederti se hai ricevuto la fattura che ti ho mandato lunedì."),
        .init(language: "it", voice: "Eddy (Italian (Italy))", text: "Questa frase è più lunga delle altre perché voglio capire come se la cava il motore quando parlo a lungo senza fermarmi mai."),
        .init(language: "it", voice: "Alice", text: "Va bene, facciamo così."),
        .init(language: "it", voice: "Eddy (Italian (Italy))", text: "No, aspetta."),
        .init(language: "it", voice: "Alice", text: "Per favore aggiungi alla lista della spesa pomodori, mozzarella, basilico e olio buono."),
        .init(language: "it", voice: "Eddy (Italian (Italy))", text: "L'incontro con i soci è andato meglio del previsto, ne parliamo a voce."),
        .init(language: "it", voice: "Alice", text: "Non dimenticare di spegnere le luci e chiudere la finestra prima di uscire."),
        .init(language: "it", voice: "Eddy (Italian (Italy))", text: "Domenica andiamo al mare se il tempo regge, altrimenti restiamo in città."),
        .init(language: "en", voice: "Samantha", text: "Please schedule the design review for next Tuesday at three thirty."),
        .init(language: "en", voice: "Daniel", text: "The build failed because the signing certificate expired last week."),
        .init(language: "en", voice: "Reed (English (US))", text: "Send the invoice to the client and copy me on the email."),
        .init(language: "en", voice: "Samantha", text: "I think we should ship the beta before the end of November."),
        .init(language: "en", voice: "Daniel", text: "Open the settings window and turn off the live preview."),
        .init(language: "en", voice: "Samantha", text: "The quick brown fox jumps over the lazy dog near the river bank."),
    ]

    struct Row {
        var engine: String
        var index: Int
        var text: String
        var seconds: Double
        var score: WordErrorRate.Score
    }

    static var cacheFolder: URL {
        let url = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(Identity.bundleID, isDirectory: true).appendingPathComponent("banco-voce", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Fa dire le frasi alle voci di sistema e restituisce l'audio a 16 kHz.
    static func prepareAudio() -> [[Float]] {
        var out: [[Float]] = []
        for (index, sentence) in sentences.enumerated() {
            let file = cacheFolder.appendingPathComponent(String(format: "frase-%02d.aiff", index))
            if !FileManager.default.fileExists(atPath: file.path) {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/say")
                process.arguments = ["-v", sentence.voice, "-o", file.path, sentence.text]
                try? process.run()
                process.waitUntilExit()
            }
            out.append((try? AudioCapture.load(file: file)) ?? [])
        }
        return out
    }

    static func run(report path: String) async {
        let audio = prepareAudio()
        var rows: [Row] = []
        var notes: [String] = []

        // 1. Il motore di OpenWhispr, così com'è: il suo programma con il suo modello.
        if let reference = await OpenWhisprReference.start() {
            _ = try? await reference.transcribe(audio[0])   // riscaldamento, come in OpenWhispr
            for (i, samples) in audio.enumerated() where !samples.isEmpty {
                let start = DispatchTime.now().uptimeNanoseconds
                let text = (try? await reference.transcribe(samples)) ?? ""
                let seconds = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9
                rows.append(Row(engine: "OpenWhispr (Orukeet)", index: i, text: text, seconds: seconds,
                                score: WordErrorRate.score(reference: sentences[i].text, hypothesis: text)))
            }
            reference.stop()
        } else {
            notes.append("OpenWhispr non è installata o il suo motore non è partito: manca il riferimento.")
        }

        // 2. Il motore di Charland, nel suo processo a parte, con ogni modello installato.
        for model in VoiceModel.all where ModelStore.isInstalled(model) {
            let client = VoiceEngineClient.shared
            client.shutdown()
            do {
                let loadSeconds = try await client.load(modelFolder: ModelStore.folder(model).path)
                notes.append(String(format: "Charland carica %@ in %.2f s.", model.title, loadSeconds))
                _ = try await client.transcribe(audio[0])
                for (i, samples) in audio.enumerated() where !samples.isEmpty {
                    let out = try await client.transcribe(samples)
                    rows.append(Row(engine: "Charland (\(model.title))", index: i, text: out.text, seconds: out.totalSeconds,
                                    score: WordErrorRate.score(reference: sentences[i].text, hypothesis: out.text)))
                }
            } catch {
                notes.append("Charland con \(model.title): \(error)")
            }
        }
        if let status = await VoiceEngineClient.shared.status() {
            notes.append("Motore di Charland: sherpa-onnx \(status.version), rete chiusa: \(status.networkClosed ? "sì" : "NO"), vocabolario nel motore: \(status.boosts ? "sì" : "no").")
        }
        VoiceEngineClient.shared.shutdown()
        notes.append("Provato e scartato: aggiungere 0,3 s di silenzio prima e dopo la frase non riduce gli errori, anzi ne aggiunge qualcuno.")

        write(rows: rows, audio: audio, notes: notes, to: path)
    }

    private static func write(rows: [Row], audio: [[Float]], notes: [String], to path: String) {
        var lines: [String] = []
        lines.append("# Confronto della voce")
        lines.append("")
        let formatter = DateFormatter()
        formatter.dateFormat = "d MMMM yyyy, HH:mm"
        formatter.locale = Locale(identifier: "it_IT")
        lines.append("Fatto il \(formatter.string(from: Date())) su questo Mac, con `Charland --bench-voice`.")
        lines.append("")
        lines.append("Le stesse \(sentences.count) frasi (\(sentences.filter { $0.language == "it" }.count) in italiano, \(sentences.filter { $0.language == "en" }.count) in inglese), dette dalle voci di sistema, passano da ogni motore. Gli errori sono contati per parola, senza badare a maiuscole e punteggiatura, e con i numeri in cifre (\"alle dieci\" e \"alle 10\" valgono uguale). I tempi vanno dall'invio dell'audio al testo.")
        lines.append("")
        lines.append("Limite di questa prova: le voci di sistema sono pulite e senza rumore, e pronunciano male le parole inglesi dentro le frasi italiane. Serve a confrontare i motori alla pari, non a dire quanto sbagliano con una voce vera.")
        lines.append("")
        lines.append("| Motore | Errori in italiano | Errori in inglese | Tempo medio | Tempo peggiore |")
        lines.append("|---|---|---|---|---|")
        let engines = rows.map(\.engine).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        for engine in engines {
            let mine = rows.filter { $0.engine == engine }
            func rate(_ language: String) -> String {
                let subset = mine.filter { sentences[$0.index].language == language }
                let errors = subset.reduce(0) { $0 + $1.score.errors }
                let words = subset.reduce(0) { $0 + $1.score.words }
                return words == 0 ? "" : String(format: "%d su %d parole (%.1f%%)", errors, words, Double(errors) / Double(words) * 100)
            }
            let times = mine.map(\.seconds)
            let mean = times.reduce(0, +) / Double(max(1, times.count))
            lines.append("| \(engine) | \(rate("it")) | \(rate("en")) | \(String(format: "%.0f ms", mean * 1000)) | \(String(format: "%.0f ms", (times.max() ?? 0) * 1000)) |")
        }
        lines.append("")
        for note in notes { lines.append("- \(note)") }
        lines.append("")
        lines.append("## Frase per frase")
        lines.append("")
        for (i, sentence) in sentences.enumerated() {
            let seconds = Double(audio[i].count) / VoiceEngineConstants.sampleRate
            lines.append(String(format: "**%d.** %@ (%.1f s, voce %@)", i + 1, sentence.text, seconds, sentence.voice))
            lines.append("")
            for row in rows where row.index == i {
                let mark = row.score.errors == 0 ? "giusta" : "\(row.score.errors) errori"
                lines.append("- \(row.engine): \(row.text) (\(mark), \(String(format: "%.0f ms", row.seconds * 1000)))")
            }
            lines.append("")
        }
        try? lines.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)
        print(lines.prefix(14).joined(separator: "\n"))
    }
}

/// Il motore di OpenWhispr, avviato così com'è dalla sua cartella: lo stesso programma,
/// lo stesso modello e gli stessi parametri che usa l'app. Non tocca OpenWhispr.
final class OpenWhisprReference: @unchecked Sendable {
    private let process: Process
    private let port: Int

    private init(process: Process, port: Int) {
        self.process = process
        self.port = port
    }

    static func start() async -> OpenWhisprReference? {
        let binary = "/Applications/OpenWhispr.app/Contents/Resources/bin/sherpa-onnx-ws-darwin-arm64"
        let model = OpenWhisprImport.cachedModelFolder.path
        guard FileManager.default.isExecutableFile(atPath: binary), OpenWhisprImport.hasModel else { return nil }
        let port = 6480 + Int.random(in: 0..<200)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        // Gli stessi argomenti di OpenWhispr (parakeetWsServer.js).
        process.arguments = [
            "--encoder=\(model)/encoder.int8.onnx", "--decoder=\(model)/decoder.int8.onnx", "--joiner=\(model)/joiner.int8.onnx",
            "--tokens=\(model)/tokens.txt", "--model-type=nemo_transducer", "--port=\(port)",
            "--num-threads=\(VoiceEngineClient.defaultThreads)", "--num-work-threads=3",
        ]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        // Il server scrive un log.txt nella cartella in cui parte: lo si manda nella cache.
        process.currentDirectoryURL = await VoiceBench.cacheFolder
        do { try process.run() } catch { return nil }
        let reference = OpenWhisprReference(process: process, port: port)
        // Aspetta che il modello sia caricato e il server risponda.
        for _ in 0..<80 {
            try? await Task.sleep(for: .milliseconds(250))
            if !process.isRunning { return nil }
            if (try? await reference.transcribe([Float](repeating: 0, count: 8000))) != nil { return reference }
        }
        reference.stop()
        return nil
    }

    func stop() {
        if process.isRunning { process.terminate() }
    }

    /// Protocollo del server di sherpa-onnx: [int32 frequenza][int32 byte dell'audio][campioni float32].
    func transcribe(_ samples: [Float]) async throws -> String {
        let task = URLSession.shared.webSocketTask(with: URL(string: "ws://127.0.0.1:\(port)")!)
        task.maximumMessageSize = 64 << 20
        task.resume()
        defer { task.cancel(with: .normalClosure, reason: nil) }
        var message = Data()
        var rate = Int32(16000).littleEndian
        var bytes = Int32(samples.count * 4).littleEndian
        withUnsafeBytes(of: &rate) { message.append(contentsOf: $0) }
        withUnsafeBytes(of: &bytes) { message.append(contentsOf: $0) }
        samples.withUnsafeBufferPointer { message.append(Data(buffer: $0)) }
        try await task.send(.data(message))
        let reply = try await task.receive()
        try? await task.send(.string("Done"))
        let raw: String
        switch reply {
        case .string(let s): raw = s
        case .data(let d): raw = String(decoding: d, as: UTF8.self)
        @unknown default: raw = ""
        }
        if let data = raw.data(using: .utf8), let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let text = json["text"] as? String {
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
