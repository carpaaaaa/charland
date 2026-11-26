import Foundation

/// Lo schema delle attività di Charland, versione 1.
///
/// Le regole sono quelle delle Live Activities di Apple: stessi nomi delle regioni
/// (compactLeading, compactTrailing, minimal, expanded), durata massima 8 ore,
/// messaggi di 4 KB al massimo, due azioni al massimo. Niente HTML, niente indirizzi
/// aperti senza permesso: un'attività è fatta solo di testo, simboli e numeri.
public struct ActivityMessage: Codable, Sendable, Equatable {
    public enum Operation: String, Codable, Sendable {
        /// Crea l'attività o la aggiorna, se esiste già.
        case upsert
        /// Chiude l'attività.
        case end
        /// Saluta e chiede nome e versione dell'app.
        case hello
        /// Elenca le attività di questo cliente.
        case list
    }

    public enum Template: String, Codable, Sendable, CaseIterable {
        /// Un avanzamento da 0 a 1 (una build, un'esportazione).
        case progress
        /// Un conto alla rovescia fino a `endsAt`.
        case countdown
        /// Uno stato in poche parole.
        case status
        /// Una richiesta da approvare o rifiutare (gli agenti).
        case approval
        /// Posti fissi riempiti a piacere: `leading`, `trailing`, `minimal`, `center`, `bottom`.
        case custom
    }

    public struct Slot: Codable, Sendable, Equatable {
        public var symbol: String?
        public var text: String?
        public var progress: Double?
        public init(symbol: String? = nil, text: String? = nil, progress: Double? = nil) {
            self.symbol = symbol
            self.text = text
            self.progress = progress
        }
    }

    public struct Action: Codable, Sendable, Equatable {
        public var id: String
        public var title: String
        public init(id: String, title: String) {
            self.id = id
            self.title = title
        }
    }

    public struct Alert: Codable, Sendable, Equatable {
        /// Apre l'isola per mostrare l'attività.
        public var expand: Bool?
        /// Un tocco sul trackpad: `done`, `waiting` o `error`.
        public var haptic: String?
        public var sound: Bool?
        public init(expand: Bool? = nil, haptic: String? = nil, sound: Bool? = nil) {
            self.expand = expand
            self.haptic = haptic
            self.sound = sound
        }
    }

    public var v: Int
    public var op: Operation
    /// Chi manda: il nome con cui l'utente riconosce il cliente ("xcode", "backup").
    public var client: String
    /// Identificativo dell'attività, unico per cliente.
    public var id: String?
    public var template: Template?
    public var title: String?
    public var subtitle: String?
    /// Nome di un SF Symbol.
    public var symbol: String?
    /// Un colore per nome: white, blue, green, orange, red, yellow, purple, pink, teal.
    public var tint: String?
    public var progress: Double?
    public var status: String?
    /// Secondi dal 1970.
    public var endsAt: Double?
    public var startedAt: Double?
    /// Per `approval`: il comando esatto da approvare e una spiegazione in parole semplici.
    public var command: String?
    public var detail: String?
    public var slots: [String: Slot]?
    public var actions: [Action]?
    public var alert: Alert?
    /// Da -1 (poco importante) a 2 (urgente). Chi ha la priorità più alta sta nel posto compatto.
    public var priority: Int?
    /// Dopo quanti secondi l'attività si chiude da sola. Al massimo 8 ore.
    public var ttl: Double?
    /// Per `approval`: offre anche "Approva sempre".
    public var allowAlways: Bool?
    /// L'app che ospita chi manda (identificativo del pacchetto): serve a saltare alla finestra
    /// giusta e a stare zitti se la stai già guardando.
    public var origin: String?
    /// Un agente AI: il suo nome. L'attività entra in quella degli agenti (Claude, ChatGPT,
    /// Gemini…), con la mascotte nel colore `tint` e un tempo solo per tutti.
    /// `status` "working" lo segna al lavoro, "done" o `op: end` lo toglie.
    public var agent: String?
    /// Con `upsert`: aggiorna solo i campi presenti di un'attività che esiste già, gli altri restano com'erano
    /// (come `charland update`). Senza, un `upsert` sostituisce l'attività intera, come in ActivityKit.
    public var partial: Bool?

    public init(op: Operation, client: String, id: String? = nil) {
        v = ActivitySchema.version
        self.op = op
        self.client = client
        self.id = id
    }

    /// Questo aggiornamento parziale sopra l'attività `base`: i campi presenti vincono, gli altri restano.
    /// L'avviso (`alert`) vale solo per questo messaggio e non resta.
    public func merged(onto base: ActivityMessage) -> ActivityMessage {
        var m = base
        m.op = .upsert
        m.template = template ?? base.template
        m.title = title ?? base.title
        m.subtitle = subtitle ?? base.subtitle
        m.symbol = symbol ?? base.symbol
        m.tint = tint ?? base.tint
        m.progress = progress ?? base.progress
        m.status = status ?? base.status
        m.endsAt = endsAt ?? base.endsAt
        m.startedAt = startedAt ?? base.startedAt
        m.command = command ?? base.command
        m.detail = detail ?? base.detail
        m.slots = slots ?? base.slots
        m.actions = actions ?? base.actions
        m.alert = alert
        m.priority = priority ?? base.priority
        m.ttl = ttl ?? base.ttl
        m.allowAlways = allowAlways ?? base.allowAlways
        m.origin = origin ?? base.origin
        m.agent = agent ?? base.agent
        m.partial = nil
        return m
    }
}

public enum ActivitySchema {
    public static let version = 1
    /// Un messaggio non supera i 4 KB, come le Live Activities.
    public static let maxBytes = 4096
    public static let maxSeconds: Double = 8 * 3600
    public static let maxActions = 2
    /// Una domanda (`approval` con stato `question`) porta le sue scelte come azioni: fino a quattro, con etichette
    /// più lunghe di un pulsante.
    public static let maxOptions = 4
    public static let tints: Set<String> = ["white", "blue", "green", "orange", "red", "yellow", "purple", "pink", "teal", "gray"]
    public static let haptics: Set<String> = ["done", "waiting", "error"]
    public static let slotNames: Set<String> = ["leading", "trailing", "minimal", "center", "bottom"]

    public enum Invalid: Error, Equatable, CustomStringConvertible {
        case version(Int)
        case tooLarge(Int)
        case missing(String)
        case bad(String, String)

        public var description: String {
            switch self {
            case .version(let v): "versione \(v) non supportata: questa è la \(ActivitySchema.version)"
            case .tooLarge(let n): "messaggio di \(n) byte: il massimo è \(ActivitySchema.maxBytes)"
            case .missing(let field): "manca il campo \(field)"
            case .bad(let field, let why): "campo \(field) non valido: \(why)"
            }
        }
    }

    /// Legge e controlla un messaggio arrivato come riga di JSON.
    public static func decode(_ data: Data) throws -> ActivityMessage {
        guard data.count <= maxBytes else { throw Invalid.tooLarge(data.count) }
        let message: ActivityMessage
        do {
            message = try JSONDecoder().decode(ActivityMessage.self, from: data)
        } catch let error as DecodingError {
            throw Invalid.bad("json", describe(error))
        }
        try validate(message)
        return message
    }

    public static func encode(_ message: ActivityMessage) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(message)
        guard data.count <= maxBytes else { throw Invalid.tooLarge(data.count) }
        return data
    }

    public static func validate(_ m: ActivityMessage) throws {
        guard m.v == version else { throw Invalid.version(m.v) }
        try text("client", m.client, max: 40, required: true)
        guard m.client.allSatisfy({ $0.isLetter || $0.isNumber || "-_. ".contains($0) }) else {
            throw Invalid.bad("client", "solo lettere, cifre, spazi, punto, trattino")
        }
        switch m.op {
        case .hello, .list:
            return
        case .end:
            guard let id = m.id, !id.isEmpty else { throw Invalid.missing("id") }
            try text("id", id, max: 80, required: true)
            return
        case .upsert:
            break
        }
        guard let id = m.id, !id.isEmpty else { throw Invalid.missing("id") }
        try text("id", id, max: 80, required: true)
        // Un aggiornamento parziale porta solo quello che cambia: modello e titolo restano quelli di prima.
        let partial = m.partial == true
        guard let template = m.template ?? (partial ? .status : nil) else { throw Invalid.missing("template") }
        try text("title", m.title, max: 60, required: !partial)
        try text("subtitle", m.subtitle, max: 80)
        try text("status", m.status, max: 80)
        try text("command", m.command, max: 1200)
        try text("detail", m.detail, max: 400)
        if let symbol = m.symbol { try checkSymbol("symbol", symbol) }
        if let tint = m.tint, !tints.contains(tint) { throw Invalid.bad("tint", "uno fra \(tints.sorted().joined(separator: ", "))") }
        if let p = m.progress, !(0...1).contains(p) { throw Invalid.bad("progress", "fra 0 e 1") }
        if let priority = m.priority, !(-1...2).contains(priority) { throw Invalid.bad("priority", "fra -1 e 2") }
        if let ttl = m.ttl, !(1...maxSeconds).contains(ttl) { throw Invalid.bad("ttl", "fra 1 secondo e 8 ore") }
        if let actions = m.actions {
            let question = template == .approval && m.status == "question"
            let most = question ? maxOptions : maxActions
            guard actions.count <= most else { throw Invalid.bad("actions", "al massimo \(most)") }
            for action in actions {
                try text("actions.id", action.id, max: 30, required: true)
                try text("actions.title", action.title, max: question ? 60 : 24, required: true)
            }
            guard Set(actions.map(\.id)).count == actions.count else { throw Invalid.bad("actions", "identificativi doppi") }
        }
        if m.agent != nil { try text("agent", m.agent, max: 30, required: true) }
        if let origin = m.origin {
            guard origin.count <= 100, origin.allSatisfy({ ($0.isLetter && $0.isASCII) || $0.isNumber || $0 == "." || $0 == "-" }) else {
                throw Invalid.bad("origin", "l'identificativo di un'app")
            }
        }
        if let haptic = m.alert?.haptic, !haptics.contains(haptic) { throw Invalid.bad("alert.haptic", "done, waiting o error") }
        if let slots = m.slots {
            for (name, slot) in slots {
                guard slotNames.contains(name) else { throw Invalid.bad("slots", "posto sconosciuto: \(name)") }
                try text("slots.\(name).text", slot.text, max: name == "center" || name == "bottom" ? 120 : 12)
                if let symbol = slot.symbol { try checkSymbol("slots.\(name).symbol", symbol) }
                if let p = slot.progress, !(0...1).contains(p) { throw Invalid.bad("slots.\(name).progress", "fra 0 e 1") }
            }
        }
        // I campi che un modello richiede, in un aggiornamento parziale, li ha già l'attività di prima:
        // si controlla il risultato unito, dopo.
        if partial { return }
        switch template {
        case .progress:
            guard m.progress != nil else { throw Invalid.missing("progress") }
        case .countdown:
            guard let end = m.endsAt else { throw Invalid.missing("endsAt") }
            let now = Date().timeIntervalSince1970
            guard end > now - 60, end < now + maxSeconds else { throw Invalid.bad("endsAt", "entro 8 ore da adesso") }
        case .approval:
            guard let command = m.command, !command.isEmpty else { throw Invalid.missing("command") }
        case .status, .custom:
            break
        }
    }

    private static func text(_ field: String, _ value: String?, max: Int, required: Bool = false) throws {
        guard let value else {
            if required { throw Invalid.missing(field) }
            return
        }
        if required, value.trimmingCharacters(in: .whitespaces).isEmpty { throw Invalid.missing(field) }
        if value.count > max { throw Invalid.bad(field, "al massimo \(max) caratteri") }
        // Niente marcatura e niente caratteri di controllo: solo testo.
        if value.unicodeScalars.contains(where: { $0.value < 0x20 && $0 != "\n" && $0 != "\t" }) {
            throw Invalid.bad(field, "caratteri di controllo")
        }
    }

    private static func checkSymbol(_ field: String, _ value: String) throws {
        guard !value.isEmpty, value.count <= 60,
              value.allSatisfy({ ($0.isLetter && $0.isASCII) || $0.isNumber || $0 == "." }) else {
            throw Invalid.bad(field, "il nome di un SF Symbol")
        }
    }

    private static func describe(_ error: DecodingError) -> String {
        switch error {
        case .keyNotFound(let key, _): "manca \(key.stringValue)"
        case .typeMismatch(_, let context), .valueNotFound(_, let context), .dataCorrupted(let context):
            context.codingPath.map(\.stringValue).joined(separator: ".") + " " + context.debugDescription
        @unknown default: "non leggibile"
        }
    }
}

/// La risposta di Charland a un messaggio, o un evento che arriva sullo stesso canale.
public struct ServerReply: Codable, Sendable, Equatable {
    public var ok: Bool?
    public var error: String?
    public var name: String?
    public var version: String?
    public var ids: [String]?
    /// "action" quando l'utente tocca un'azione, "ended" quando l'attività si chiude.
    public var event: String?
    public var id: String?
    public var action: String?

    public init(ok: Bool? = nil, error: String? = nil, name: String? = nil, version: String? = nil, ids: [String]? = nil,
                event: String? = nil, id: String? = nil, action: String? = nil) {
        self.ok = ok
        self.error = error
        self.name = name
        self.version = version
        self.ids = ids
        self.event = event
        self.id = id
        self.action = action
    }

    public func line() -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var data = (try? encoder.encode(self)) ?? Data("{\"ok\":false}".utf8)
        data.append(0x0A)
        return data
    }
}

/// Dove sta il socket di Charland.
public enum CharlandPaths {
    public static let appName = "Charland"

    public static var supportFolder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent(appName, isDirectory: true)
    }

    /// ~/Library/Application Support/Charland/api.sock
    public static var socket: URL { supportFolder.appendingPathComponent("api.sock") }
}
