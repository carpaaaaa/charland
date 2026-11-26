import AppKit
import CharlandCore

/// Il vocabolario com'è in questo momento: i termini (prima quelli di chi usa l'app, poi quelli di serie) e le
/// stesse parole nel formato del motore.
struct VocabularySnapshot: Sendable, Equatable {
    var terms: [String]
    var hotwords: String

    static let empty = VocabularySnapshot(terms: [], hotwords: "")

    init(terms: [String], hotwords: String) {
        self.terms = terms
        self.hotwords = hotwords
    }

    init(user: [String], common: Bool) {
        let common = common ? Vocabulary.common : []
        terms = user + common
        hotwords = Vocabulary.hotwords(user: user, common: common)
    }
}

/// Le parole che il dizionario del Mac conosce, in italiano, in inglese e nella lingua della dettatura.
/// Serve a due cose: una parola che non esiste, a una lettera da un termine del vocabolario, è quel termine
/// scritto male; e una parola comune in mezzo a una frase non vuole la maiuscola.
@MainActor
enum WordKnowledge {
    private static var cache: [String: Bool] = [:]

    static var languages: [String] {
        var list = ["it", "en"]
        let code = VoiceSettings.shared.dictationLanguage.code
        if code != "auto", !list.contains(code) { list.append(code) }
        return list
    }

    static func isKnown(_ word: String) -> Bool {
        // Una lettera sola o una sigla non sono parole del dizionario.
        guard word.count >= 2 else { return false }
        if let known = cache[word] { return known }
        let checker = NSSpellChecker.shared
        let available = Set(checker.availableLanguages.map { String($0.prefix(2)) })
        var known = false
        for language in languages where available.contains(language) {
            let miss = checker.checkSpelling(of: word, startingAt: 0, language: language, wrap: false,
                                             inSpellDocumentWithTag: 0, wordCount: nil)
            if miss.location == NSNotFound { known = true; break }
        }
        if cache.count > 4000 { cache.removeAll() }
        cache[word] = known
        return known
    }
}

/// Dal suono al testo: il motore (passata sicura più passata col vocabolario), l'unione delle due, la grafia.
@MainActor
enum Recognition {
    struct Result: Sendable {
        /// Quello che ha scritto la passata sicura, senza vocabolario.
        var raw: String
        /// Il testo con i termini del vocabolario al loro posto.
        var text: String
        /// Secondi di calcolo dentro il motore.
        var engineSeconds: Double
    }

    /// Un pezzo di audio (fino a una ventina di secondi).
    static func piece(_ samples: [Float], vocabulary: VocabularySnapshot) async throws -> Result {
        var out = try await VoiceEngineClient.shared.transcribe(samples, hotwords: vocabulary.hotwords)
        var seconds = out.engineSeconds
        if out.text.isEmpty, AudioSegmenter.isAudible(samples) {
            // C'è voce ma il motore non ha scritto niente: succede con una voce che parte di colpo, senza un
            // attimo di silenzio prima. Con un cuscino di silenzio ai due lati quasi sempre la sente (11 casi su
            // 12 nelle prove). Sempre no: sulle frasi normali il cuscino aggiunge qualche errore.
            let cushion = [Float](repeating: 0, count: Int(0.6 * VoiceEngineConstants.sampleRate))
            out = try await VoiceEngineClient.shared.transcribe(cushion + samples + cushion, hotwords: vocabulary.hotwords)
            seconds += out.engineSeconds
            if DictationController.tracing { print("[voce] frase vuota, riprovata col cuscino di silenzio: \(out.text)"); fflush(stdout) }
        }
        return Result(raw: out.text, text: spell(out.text, boosted: out.boosted, vocabulary: vocabulary),
                      engineSeconds: seconds)
    }

    /// I termini del vocabolario al loro posto: presi dalla seconda passata dove li ha sentiti, poi la grafia.
    static func spell(_ safe: String, boosted: String?, vocabulary: VocabularySnapshot) -> String {
        guard !vocabulary.terms.isEmpty else { return safe }
        var text = safe
        if let boosted {
            text = Vocabulary.merge(base: safe, boosted: boosted, terms: vocabulary.terms, isKnownWord: WordKnowledge.isKnown)
        }
        let merged = text
        text = Vocabulary.canonicalize(text, terms: vocabulary.terms)
        text = Vocabulary.nearMisses(text, terms: vocabulary.terms, isKnownWord: WordKnowledge.isKnown)
        if DictationController.tracing, text != safe {
            print("[voce] vocabolario | sicura: \(safe) | con le parole: \(boosted ?? "(nessuna)") | unione: \(merged) | finale: \(text)")
            fflush(stdout)
        }
        return text
    }

    /// Tutto un audio: a pezzi nelle pause se è lungo, così il costo resta in proporzione alla durata.
    static func whole(_ samples: [Float], vocabulary: VocabularySnapshot) async throws -> Result {
        var parts: [AudioSegmenter.Part] = []
        var raws: [String] = []
        var seconds = 0.0
        for segment in AudioSegmenter.split(samples) {
            let done = try await Self.piece(Array(samples[segment.range]), vocabulary: vocabulary)
            parts.append(.init(text: done.text, pauseAfter: segment.pauseAfter))
            raws.append(done.raw)
            seconds += done.engineSeconds
        }
        return Result(raw: raws.filter { !$0.isEmpty }.joined(separator: " "), text: join(parts, vocabulary: vocabulary),
                      engineSeconds: seconds)
    }

    /// Rimette insieme i testi dei pezzi (vedi `AudioSegmenter.join`): la maiuscola a metà frase si toglie solo
    /// alle parole comuni, mai a un nome o a un termine del vocabolario.
    static func join(_ parts: [AudioSegmenter.Part], vocabulary: VocabularySnapshot) -> String {
        AudioSegmenter.join(parts) { word in
            word.count > 1 && WordKnowledge.isKnown(word.lowercased())
                && Vocabulary.present(in: word, terms: vocabulary.terms).isEmpty
        }
    }
}

/// La trascrizione di una dettatura mentre va. I pezzi finiti (una quindicina di secondi l'uno, tagliati nelle
/// pause) si trascrivono e si puliscono mentre parli; al rilascio resta da fare solo la coda. Così anche una
/// dettatura di cinque minuti arriva subito, e il motore non si trova mai in mano un audio lungo tutto insieme.
@MainActor
final class LiveTranscript {
    /// Finisce il testo di un pezzo (regole, sostituzioni, pulizia col modello). Il secondo valore dice che dopo
    /// ne arriverà un altro.
    typealias Polish = @MainActor (String, Bool) async -> DictationController.Polished

    private let capture: AudioCapture
    private let vocabulary: VocabularySnapshot
    private let polish: Polish?
    private var parts: [AudioSegmenter.Part] = []
    private var raws: [String] = []
    /// I pezzi già finiti (regole e pulizia), per posto.
    private var finished: [Int: DictationController.Polished] = [:]
    /// Campioni già finiti nei pezzi chiusi.
    private var consumed = 0
    private var engineSeconds = 0.0
    /// Il lavoro in corso col motore: uno per volta, in fila.
    private var queue: Task<Void, Never>?
    /// La pulizia dei pezzi: una per volta, in fila, senza fermare il motore.
    private var polishQueue: Task<Void, Never>?
    private var cancelled = false
    /// Quanti pezzi sono già stati trascritti mentre si parlava.
    private(set) var closedPieces = 0

    init(capture: AudioCapture, vocabulary: VocabularySnapshot, polish: Polish? = nil) {
        self.capture = capture
        self.vocabulary = vocabulary
        self.polish = polish
    }

    /// La dettatura è stata annullata o è finita: quello che è ancora in fila non serve più.
    func cancel() {
        cancelled = true
    }

    /// Mette in fila un lavoro dopo quello in corso.
    private func inLine<T: Sendable>(_ work: @escaping @MainActor () async -> T) async -> T {
        let previous = queue
        let task = Task { @MainActor in
            await previous?.value
            return await work()
        }
        queue = Task { _ = await task.value }
        return await task.value
    }

    /// Mette in fila la pulizia di un pezzo appena trascritto.
    private func polishLater(_ index: Int, more: Bool) {
        guard let polish else { return }
        let text = parts[index].text
        let previous = polishQueue
        polishQueue = Task { @MainActor in
            await previous?.value
            guard !self.cancelled else { return }
            self.finished[index] = await polish(text, more)
        }
    }

    /// Un passo mentre parli: se la coda è abbastanza lunga chiude un pezzo, lo trascrive e lo manda a pulire;
    /// se no, con `live`, ritrascrive gli ultimi secondi e restituisce le parole da mostrare nell'isola.
    func step(live: Bool, window: Double) async -> String? {
        await inLine {
            let pending = self.capture.snapshot(from: self.consumed)
            if let cut = AudioSegmenter.cut(pending) {
                let segment = Array(pending[..<cut.index])
                self.consumed += cut.index
                if let piece = try? await Recognition.piece(segment, vocabulary: self.vocabulary) {
                    self.parts.append(.init(text: piece.text, pauseAfter: cut.pause))
                    self.raws.append(piece.raw)
                    self.engineSeconds += piece.engineSeconds
                    self.closedPieces += 1
                    self.polishLater(self.parts.count - 1, more: true)
                    if DictationController.tracing {
                        print(String(format: "[voce] pezzo %d chiuso: %.1f s di audio in %.0f ms%@ | %@", self.parts.count,
                                     Double(cut.index) / VoiceEngineConstants.sampleRate, piece.engineSeconds * 1000,
                                     cut.pause ? ", in una pausa" : ", in mezzo alla frase", piece.text))
                        fflush(stdout)
                    }
                } else {
                    // il motore non ha risposto: il pezzo torna in coda e si riprova al rilascio
                    self.consumed -= cut.index
                }
                return nil
            }
            guard live else { return nil }
            let audio = self.capture.snapshot(lastSeconds: window)
            guard Double(audio.count) / VoiceEngineConstants.sampleRate > 0.5 else { return nil }
            return (try? await Recognition.piece(audio, vocabulary: self.vocabulary))?.text
        }
    }

    /// Al rilascio: aspetta il passo in corso, trascrive quello che resta (e lo manda a pulire) e restituisce
    /// tutto il testo riconosciuto.
    func finish(_ all: [Float]) async throws -> Recognition.Result {
        let outcome: Swift.Result<Recognition.Result, Error> = await inLine {
            let first = self.parts.count, firstRaw = self.raws.count
            do {
                let rest = Array(all[min(self.consumed, all.count)...])
                for segment in AudioSegmenter.split(rest) {
                    let done = try await Recognition.piece(Array(rest[segment.range]), vocabulary: self.vocabulary)
                    self.parts.append(.init(text: done.text, pauseAfter: segment.pauseAfter))
                    self.raws.append(done.raw)
                    self.engineSeconds += done.engineSeconds
                }
                self.consumed = all.count
                for index in first..<self.parts.count { self.polishLater(index, more: index < self.parts.count - 1) }
                return .success(Recognition.Result(raw: self.raws.filter { !$0.isEmpty }.joined(separator: " "),
                                                   text: Recognition.join(self.parts, vocabulary: self.vocabulary),
                                                   engineSeconds: self.engineSeconds))
            } catch {
                // Un tentativo fallito a metà non lascia pezzi: chi riprova (`DictationController.commit`) non li raddoppia.
                self.parts.removeSubrange(first...)
                self.raws.removeSubrange(firstRaw...)
                return .failure(error)
            }
        }
        return try outcome.get()
    }

    /// Il testo finito: aspetta la pulizia dei pezzi ancora in fila (di solito solo l'ultimo) e li rimette insieme.
    /// `nil` se questa trascrizione non finisce i pezzi da sé.
    func polished() async -> DictationController.Polished? {
        guard polish != nil else { return nil }
        let start = Date()
        await polishQueue?.value
        var texts: [AudioSegmenter.Part] = []
        var source: ModelCleaner.Result.Source = .rules
        for (index, part) in parts.enumerated() {
            let done = finished[index]
            texts.append(.init(text: done?.text ?? part.text, pauseAfter: part.pauseAfter))
            // conta il pezzo andato meglio: basta un pezzo pulito dal modello perché il testo lo sia
            if done?.source == .model { source = .model } else if source == .rules, let other = done?.source { source = other }
        }
        return DictationController.Polished(text: Recognition.join(texts, vocabulary: vocabulary), source: source,
                                            seconds: Date().timeIntervalSince(start))
    }
}
