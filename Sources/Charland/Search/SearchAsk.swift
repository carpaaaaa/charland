import Foundation
import FoundationModels
import QuartzCore

/// «Chiedi»: la risposta dentro la barra, col modello di Apple sul Mac (lo stesso della pulizia della dettatura). Niente
/// chiavi, niente account, niente costi, niente che esca dal Mac. Le domande successive nella stessa apertura della barra
/// continuano la stessa conversazione; chiusa la barra, si ricomincia.
///
/// Il modello grande di Private Cloud Compute (macOS 27) qui non si usa: risulta disponibile, ma senza l'autorizzazione
/// gestita `com.apple.developer.private-cloud-compute` (da chiedere ad Apple) la prima domanda ferma l'app con un errore
/// fatale. Provato il 23 novembre 2026: Charland si chiudeva premendo Invio su «Chiedi».
@MainActor
final class SearchAsk {
    static let shared = SearchAsk()

    private var session: LanguageModelSession?
    private var task: Task<Void, Never>?

    private init() {}

    /// C'è il modello. Chiederlo costa qualche millisecondo (passa dal sistema): la risposta vale 30 secondi, così la barra
    /// non la richiede a ogni lettera.
    static var isAvailable: Bool {
        let now = CACurrentMediaTime()
        if let cached = availability, now - cached.at < 30 { return cached.value }
        var value = false
        if case .available = SystemLanguageModel.default.availability { value = true }
        availability = (value, now)
        return value
    }

    private static var availability: (value: Bool, at: CFTimeInterval)?

    /// Prepara il modello mentre si scrive la domanda: la prima parola della risposta arriva prima.
    func prewarm() {
        guard session == nil, Self.isAvailable else { return }
        let session = Self.makeSession()
        self.session = session
        session.prewarm()
    }

    /// Fa la domanda. `update` riceve il testo fin qui e se ha finito; con un errore il testo è `nil`.
    func ask(_ question: String, update: @escaping @MainActor (String?, Bool) -> Void) {
        task?.cancel()
        Self.currentQuestion = question
        guard Self.isAvailable else { update(nil, true); return }
        if session == nil || session?.isResponding == true { session = Self.makeSession() }
        guard let session else { update(nil, true); return }
        task = Task { @MainActor in
            do {
                var last = ""
                for try await snapshot in session.streamResponse(to: question) {
                    if Task.isCancelled { return }
                    last = snapshot.content
                    update(last, false)
                }
                if Task.isCancelled { return }
                update(last, true)
            } catch {
                if !Task.isCancelled { update(nil, true) }
            }
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
    }

    /// Barra chiusa: la conversazione finisce.
    func reset() {
        cancel()
        session = nil
    }

    /// La domanda in corso: gli strumenti la guardano per non usare un browser che nessuno ha nominato.
    private(set) static var currentQuestion = ""

    private static func makeSession() -> LanguageModelSession {
        // Istruzioni in inglese per tutti, con la risposta nella lingua di chi scrive. Provato il 23 novembre 2026 con
        // istruzioni in italiano: a «aprimi Pinterest su Safari» il modello rispondeva «Ho aperto Pinterest su Safari»
        // senza chiamare lo strumento, cioè senza aprire niente; in inglese chiama lo strumento ogni volta.
        let instructions = "You answer questions typed into a Mac search bar and you can act on this Mac with tools. IMPORTANT: whenever the user asks, in any language, to open, show or go to a website or web service, you MUST call the openWebsite tool; whenever they ask to open or launch an app, you MUST call the openApp tool. Never say you opened something unless you called the tool. After the tool runs, say in one short sentence, in the language of the user, what you opened. For other questions, answer directly in the language of the user: lead with the answer, at most about 120 words unless the question clearly needs more, simple Markdown (bold, short lists) allowed. Never invent facts: if you are not sure, say so."
        // Due azioni: aprire un sito (anche in un browser scelto) e aprire un'app (carpa: «ho chiesto all'AI di aprirmi
        // Pinterest su Safari, non l'ha fatto»).
        return LanguageModelSession(model: SystemLanguageModel.default, tools: [SearchOpenWebsiteTool(), SearchOpenAppTool()],
                                    instructions: instructions)
    }
}
