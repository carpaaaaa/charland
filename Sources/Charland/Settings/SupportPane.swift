import SwiftUI
import CharlandCore

/// Impostazioni › Supporto (18 novembre 2026): gli stessi due moduli della pagina Supporto del sito, «qualcosa non va»
/// e «manca qualcosa», più il link alla pagina e al changelog. Le segnalazioni vanno al server di Charcal
/// (`/v1/reports`, lo stesso dei moduli di Charcal) con `app: "charland"`, così arrivano con l'oggetto «Bug Charland» o
/// «Idea Charland». Partono solo quando premi Invia; versione, build e lingua sempre (lo dice anche la pagina Privacy),
/// modello del Mac e macOS solo se lasci acceso l'interruttore. I testi si fermano a 4000 caratteri come sul server.
enum SupportLinks {
    static let site = URL(string: "https://charland.charstudio.app")!
    static let support = URL(string: "https://charland.charstudio.app/support")!
    static let changelog = URL(string: "https://charland.charstudio.app/changelog")!
    static let reports = URL(string: "https://charcal.charstudio.app/v1/reports")!
    static let email = "support@charstudio.app"
}

struct SupportPane: View {
    enum Kind: String, CaseIterable, Identifiable { case bug, idea; var id: String { rawValue } }

    @State private var kind: Kind = .bug
    @State private var what = ""
    @State private var expected = ""
    @State private var steps = ""
    @State private var frequency = ""
    @State private var email = ""
    @State private var includeSystem = true
    @State private var sending = false
    @State private var message: String?
    @State private var sent = false

    private var frequencies: [(String, LocalizedStringKey)] {
        kind == .bug ? [("always", "Sempre"), ("sometimes", "A volte"), ("once", "Una volta")]
                     : [("daily", "Ogni giorno"), ("weekly", "Ogni settimana"), ("sometimes", "Ogni tanto")]
    }

    var body: some View {
        Form {
            Section {
                Picker("Tipo", selection: $kind) {
                    Text("Segnala un problema").tag(Kind.bug)
                    Text("Proponi un'idea").tag(Kind.idea)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .onChange(of: kind) { frequency = ""; message = nil; sent = false }
            } footer: {
                Text("Lo leggiamo tutto. Se lasci l'email ti rispondiamo.")
            }

            Section {
                field(kind == .bug ? "Cosa è successo?" : "Cosa vorresti che facesse Charland?", text: $what, lines: 4, optional: false)
                if kind == .bug {
                    field("Cosa ti aspettavi?", text: $expected, lines: 2)
                    field("Come si rifà?", text: $steps, lines: 3)
                } else {
                    field("A cosa ti servirebbe?", text: $expected, lines: 2)
                }
                Picker(kind == .bug ? "Quanto spesso succede?" : "Quanto spesso la useresti?", selection: $frequency) {
                    Text("Non so").tag("")
                    ForEach(frequencies, id: \.0) { Text($0.1).tag($0.0) }
                }
                TextField("La tua email, se vuoi una risposta", text: $email, prompt: Text("nome@esempio.it"))
                    .textContentType(.emailAddress)
                Toggle("Includi macOS e modello del Mac", isOn: $includeSystem)
            }

            Section {
                HStack {
                    if let message { Text(message).foregroundStyle(sent ? .green : .secondary) }
                    Spacer()
                    if sending { ProgressView().controlSize(.small) }
                    Button("Invia") { Task { await send() } }
                        .keyboardShortcut(.return, modifiers: .command)
                        .disabled(sending || what.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }

            Section("Altro") {
                Link(destination: SupportLinks.changelog) { Label("Vedi le novità", systemImage: "sparkles") }
                Link(destination: SupportLinks.support) { Label("Pagina Supporto", systemImage: "lifepreserver") }
                Link(destination: URL(string: "mailto:\(SupportLinks.email)")!) { Label("Scrivi a support@charstudio.app", systemImage: "envelope") }
            }
        }
        .formStyle(.grouped)
    }

    private func field(_ title: LocalizedStringKey, text: Binding<String>, lines: Int, optional: Bool = true) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(title)
                if optional { Text("Facoltativo").foregroundStyle(.tertiary) }
            }
            TextEditor(text: text)
                .font(.body)
                .onChange(of: text.wrappedValue) { _, nuovo in
                    if nuovo.count > Self.maxLength { text.wrappedValue = String(nuovo.prefix(Self.maxLength)) }
                }
                .frame(minHeight: CGFloat(lines) * 18 + 10)
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
    }

    /// Lo stesso limite del server (`/v1/reports`): oltre risponde 400.
    static let maxLength = 4000

    private func send() async {
        guard !sending else { return }
        let address = email.trimmingCharacters(in: .whitespacesAndNewlines)
        if !address.isEmpty, address.range(of: #"^[^\s@]+@[^\s@]+\.[^\s@]{2,}$"#, options: .regularExpression) == nil {
            sent = false
            message = String(localized: "Controlla l'email.")
            return
        }
        sending = true
        message = String(localized: "Invio…")
        sent = false
        defer { sending = false }
        var body: [String: String] = [
            "app": "charland", "source": "app", "kind": kind.rawValue,
            "what": what.trimmingCharacters(in: .whitespacesAndNewlines),
            "expected": expected.trimmingCharacters(in: .whitespacesAndNewlines),
            "steps": kind == .bug ? steps.trimmingCharacters(in: .whitespacesAndNewlines) : "",
            "frequency": frequency,
            "email": email.trimmingCharacters(in: .whitespacesAndNewlines),
            "app_version": Identity.version,
            "build": Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "",
            "language": Locale.current.language.languageCode?.identifier ?? "",
        ]
        if includeSystem {
            let v = ProcessInfo.processInfo.operatingSystemVersion
            body["system"] = "macOS \(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
            body["device"] = Self.model
        }
        var request = URLRequest(url: SupportLinks.reports, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONEncoder().encode(body.filter { !$0.value.isEmpty })
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            switch status {
            case 200...299:
                sent = true
                message = String(localized: "Grazie! L'abbiamo ricevuto.")
                what = ""; expected = ""; steps = ""; frequency = ""
            case 429:
                message = String(localized: "Troppe segnalazioni da questo Mac. Riprova fra un po'.")
            default:
                message = String(localized: "Non è partito. Controlla la rete e riprova.")
            }
        } catch {
            message = String(localized: "Non è partito. Controlla la rete e riprova.")
        }
    }

    /// Il modello del Mac (per esempio Mac17,4).
    static var model: String {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        var buffer = [CChar](repeating: 0, count: max(size, 1))
        sysctlbyname("hw.model", &buffer, &size, nil, 0)
        return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}
