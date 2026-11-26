import SwiftUI
import AVFoundation
import ApplicationServices
import FoundationModels
import CharlandCore
import CharlandKit

/// La sezione delle impostazioni da mostrare. Si sceglie anche da fuori: l'isola che dice «prepara la dettatura»
/// apre la finestra già sulla Voce.
@MainActor @Observable
final class SettingsNavigation {
    static let shared = SettingsNavigation()
    var section: SettingsSection? = .appearance
}

/// Gli scaricamenti dei modelli vocali, condivisi fra la guida e l'elenco dei modelli.
@MainActor @Observable
final class ModelDownloads {
    static let shared = ModelDownloads()

    private(set) var progress: [String: Double] = [:]
    private(set) var message: String?
    /// Cambia a ogni modello installato o tolto: chi lo guarda si ridisegna.
    private(set) var revision = 0

    func download(_ model: VoiceModel) {
        guard progress[model.id] == nil else { return }
        progress[model.id] = 0
        message = nil
        Task {
            do {
                try await ModelStore.download(model) { fraction in
                    Task { @MainActor in
                        if ModelDownloads.shared.progress[model.id] != nil { ModelDownloads.shared.progress[model.id] = fraction }
                    }
                }
            } catch {
                message = String(localized: "Lo scaricamento non è riuscito. Controlla la rete e riprova.")
            }
            progress[model.id] = nil
            revision += 1
        }
    }

    /// Il modello che OpenWhispr ha già scaricato: si copia, senza rete.
    func importFromOpenWhispr() {
        do {
            try OpenWhisprImport.importModel()
            ModelStore.ensureVocabulary(.orukeet)
            message = nil
        } catch {
            message = String(localized: "L'importazione non è riuscita.")
        }
        revision += 1
    }

    func changed() { revision += 1 }
}

/// Che cosa serve perché la dettatura funzioni, e che cosa manca adesso.
@MainActor
enum DictationSetup {
    enum Step: CaseIterable {
        /// Il modello vocale scaricato.
        case model
        /// Il permesso del microfono.
        case microphone
        /// Il permesso per scrivere nelle altre app.
        case accessibility
    }

    static func isDone(_ step: Step) -> Bool {
        // per le prove: CHARLAND_PREPARAZIONE=modello,microfono,accessibilita finge che quei passi manchino
        if let pretend = ProcessInfo.processInfo.environment["CHARLAND_PREPARAZIONE"] {
            let name = switch step {
            case .model: "modello"
            case .microphone: "microfono"
            case .accessibility: "accessibilita"
            }
            if pretend.contains(name) { return false }
        }
        return switch step {
        case .model: ModelStore.selected != nil
        case .microphone: AudioCapture.permission == .authorized
        case .accessibility: AXIsProcessTrusted()
        }
    }

    private static var paneWindow: NSWindow?

    /// Solo la sezione Voce in una finestra sua, senza accendere il resto dell'app: per guardarla durante le prove
    /// (`Charland --voce`).
    static func showPane() {
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 650, height: 760),
                              styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        window.title = "Voce"
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: VoicePane())
        window.setContentSize(CGSize(width: 650, height: 760))
        window.center()
        window.orderFrontRegardless()
        paneWindow = window
        print("finestra della voce:", window.windowNumber); fflush(stdout)
    }

    static var missing: [Step] { Step.allCases.filter { !isDone($0) } }
    static var isReady: Bool { missing.isEmpty }

    static func openSystemSettings(_ step: Step) {
        let link: String
        switch step {
        case .model: return
        case .microphone: link = "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
        case .accessibility: link = "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        }
        if let url = URL(string: link) { NSWorkspace.shared.open(url) }
    }

    /// Chiede il permesso come lo chiede il sistema la prima volta; se è già stato negato, apre le Impostazioni.
    static func request(_ step: Step) {
        switch step {
        case .model: break
        case .microphone:
            if AudioCapture.permission == .notDetermined {
                Task { _ = await AudioCapture.requestPermission() }
            } else {
                openSystemSettings(.microphone)
            }
        case .accessibility:
            // Il sistema mostra il suo avviso con il pulsante che porta alla riga giusta.
            _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
            openSystemSettings(.accessibility)
        }
    }

    /// Hai premuto il tasto ma manca qualcosa: l'isola lo dice e porta al punto dove sistemarlo. Senza, la
    /// dettatura sembrava semplicemente non funzionare.
    static func explain(_ step: Step) {
        var m: ActivityMessage
        let button: String
        switch step {
        case .model:
            m = SystemActivity.message("dettatura-da-preparare", template: .status, title: String(localized: "Manca il modello vocale"))
            m.subtitle = String(localized: "Si scarica una volta, poi detti anche senza rete")
            button = String(localized: "Prepara la dettatura")
        case .microphone:
            m = SystemActivity.message("dettatura-da-preparare", template: .status, title: String(localized: "Serve il microfono"))
            m.subtitle = String(localized: "Charland ascolta solo mentre tieni premuto il tasto")
            button = String(localized: "Consenti il microfono")
        case .accessibility:
            m = SystemActivity.message("dettatura-da-preparare", template: .status, title: String(localized: "Testo copiato negli appunti"))
            m.subtitle = String(localized: "Per scriverlo da sola a Charland serve Accessibilità")
            button = String(localized: "Prepara la dettatura")
        }
        m.symbol = "waveform"
        m.tint = "orange"
        m.ttl = 9
        m.alert = .init(expand: true, haptic: "waiting")
        m.actions = [.init(id: "prepara", title: button)]
        SystemActivity.show(m) { action in
            guard action == "prepara" else { return }
            SystemActivity.end("dettatura-da-preparare")
            if step == .microphone, AudioCapture.permission == .notDetermined {
                request(.microphone)
            } else {
                AppServices.shared.showSettings(section: .voice)
            }
        }
    }
}

// MARK: - Guida

/// La preparazione della dettatura, in cima alla sezione Voce: tre cose da fare una volta, ognuna col suo
/// pulsante, e quando è tutto a posto un campo per provarla subito (carpa: «quando uno installa l'app sia chiaro
/// come installare il tutto per rendere la dettatura funzionante»).
struct DictationSetupGuide: View {
    @Bindable var settings: VoiceSettings
    private let downloads = ModelDownloads.shared
    @State private var microphoneReady = DictationSetup.isDone(.microphone)
    @State private var accessibility = DictationSetup.isDone(.accessibility)
    @State private var sample = ""

    private var modelReady: Bool {
        _ = downloads.revision
        return DictationSetup.isDone(.model)
    }

    var body: some View {
        let ready = modelReady && microphoneReady && accessibility
        Section {
            if ready {
                readyRows
            } else {
                modelStep
                microphoneStep
                accessibilityStep
            }
        } header: {
            Text(ready ? "Dettatura" : "Prepara la dettatura")
        } footer: {
            if ready {
                Text("Tieni premuto \(settings.combo.display) mentre parli: quando lasci, il testo viene scritto dove stai lavorando. Due pressioni veloci per le mani libere, esc per annullare. La voce non lascia mai il Mac.")
            } else {
                Text("Tre cose, una volta sola. Poi tieni premuto \(settings.combo.display), parla, e il testo compare dove stai scrivendo. La voce non lascia mai il Mac.")
            }
        }
        .task {
            // i permessi si concedono fuori dall'app: si ricontrolla finché questa sezione è aperta
            while !Task.isCancelled {
                microphoneReady = DictationSetup.isDone(.microphone)
                let granted = DictationSetup.isDone(.accessibility)
                // Accessibilità appena concessa: una scorciatoia di soli modificatori (⌃⌥) si ascolta solo da ora.
                if granted, !accessibility { DictationController.shared.start() }
                accessibility = granted
                try? await Task.sleep(for: .seconds(1.2))
            }
        }
    }

    // MARK: Pronta

    @ViewBuilder private var readyRows: some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill").font(.system(size: 20)).foregroundStyle(.green)
            VStack(alignment: .leading, spacing: 2) {
                Text("La dettatura è pronta").font(.system(size: 14, weight: .semibold))
                Text("Modello vocale, microfono e Accessibilità sono a posto.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
        TextField("Campo di prova", text: $sample, prompt: Text("Fai clic qui, tieni premuto \(settings.combo.display) e di' qualcosa"), axis: .vertical)
            .lineLimit(2...5)
            .textFieldStyle(.roundedBorder)
            .labelsHidden()
    }

    // MARK: Passi

    private var modelStep: some View {
        let model = VoiceModel.all[0]
        let progress = downloads.progress[model.id]
        return SetupStep(number: 1, done: modelReady,
                         title: String(localized: "Modello vocale"),
                         detail: modelReady ? String(localized: "Scaricato: trasforma la voce in testo, sul Mac.")
                                            : String(localized: "Il motore che trasforma la voce in testo, tutto sul Mac. Si scarica una volta: \(model.megabytes) MB.")) {
            if let progress {
                VStack(alignment: .trailing, spacing: 3) {
                    ProgressView(value: progress).frame(width: 130)
                    Text("\(Int(progress * 100))%").font(.system(size: 11)).monospacedDigit().foregroundStyle(.secondary)
                }
            } else if OpenWhisprImport.hasModel {
                Button("Usa quello di OpenWhispr") { downloads.importFromOpenWhispr() }
                    .buttonStyle(.borderedProminent)
            } else {
                Button("Scarica") { downloads.download(model) }
                    .buttonStyle(.borderedProminent)
            }
        } note: {
            if let message = downloads.message { Text(message).foregroundStyle(.red) }
        }
    }

    private var microphoneStep: some View {
        let status = AudioCapture.permission
        let denied = status == .denied || status == .restricted
        return SetupStep(number: 2, done: microphoneReady,
                         title: String(localized: "Microfono"),
                         detail: String(localized: "Charland ascolta solo mentre tieni premuto il tasto della dettatura.")) {
            Button(denied ? String(localized: "Apri Impostazioni") : String(localized: "Consenti")) {
                DictationSetup.request(.microphone)
            }
            .buttonStyle(.borderedProminent)
        } note: {
            if denied {
                Text("Il permesso era stato negato: in Privacy e sicurezza › Microfono accendi Charland.")
            }
        }
    }

    private var accessibilityStep: some View {
        SetupStep(number: 3, done: accessibility,
                  title: PermissionsPane.accessibilityName,
                  detail: String(localized: "Serve a scrivere il testo nel campo dove stai lavorando, in qualunque app.")) {
            Button("Apri Impostazioni") { DictationSetup.request(.accessibility) }
                .buttonStyle(.borderedProminent)
        } note: {
            Text("In Privacy e sicurezza › \(PermissionsPane.accessibilityName) accendi Charland nell'elenco. Se non c'è, aggiungila col pulsante +.")
        }
    }
}

/// Un passo della guida: numero o spunta, cosa serve e perché, e il pulsante per farlo.
struct SetupStep<Action: View, Note: View>: View {
    let number: Int
    let done: Bool
    let title: String
    let detail: String
    @ViewBuilder var action: Action
    @ViewBuilder var note: Note

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                if done {
                    Image(systemName: "checkmark.circle.fill").font(.system(size: 20)).foregroundStyle(.green)
                } else {
                    Circle().fill(.quaternary)
                    Text("\(number)").font(.system(size: 12, weight: .bold, design: .rounded)).monospacedDigit()
                }
            }
            .frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 14, weight: .medium))
                Text(detail).font(.system(size: 12)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if !done {
                    note.font(.system(size: 11)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            if !done { action }
        }
        .padding(.vertical, 3)
    }
}

// MARK: - Vocabolario

/// Il vocabolario della dettatura: i nomi e le parole da scrivere esattamente così. Il motore li riconosce
/// mentre ascolta («c'è GPT» diventa «ChatGPT») e la grafia resta quella scritta qui.
struct VocabularySection: View {
    @Bindable var settings: VoiceSettings
    @State private var draft = ""
    @State private var showCommon = false

    var body: some View {
        Section {
            if !settings.vocabulary.isEmpty {
                FlowLayout(spacing: 6) {
                    ForEach(settings.vocabulary, id: \.self) { word in
                        WordChip(word: word) { settings.vocabulary.removeAll { $0 == word } }
                    }
                }
                .padding(.vertical, 2)
            }
            HStack(spacing: 8) {
                TextField("Aggiungi", text: $draft, prompt: Text("Un nome o una parola, come la vuoi scritta"))
                    .textFieldStyle(.roundedBorder)
                    .labelsHidden()
                    .onSubmit(add)
                Button("Aggiungi", action: add)
                    .disabled(Vocabulary.key(draft).count < 2)
            }
            Toggle("Nomi comuni di app e servizi", isOn: $settings.commonVocabulary)
            if settings.commonVocabulary {
                DisclosureGroup("Vedi i \(Vocabulary.common.count) nomi", isExpanded: $showCommon) {
                    Text(Vocabulary.common.joined(separator: " · "))
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .font(.system(size: 12))
            }
        } header: {
            Text("Vocabolario")
        } footer: {
            Text("Nomi di persone, prodotti, sigle: tutto quello che la dettatura deve scrivere esattamente così. Il motore li riconosce già mentre ascolta, anche in mezzo a una frase in italiano: «c'è GPT» diventa «ChatGPT», «test flight» diventa «TestFlight».")
        }
    }

    /// Aggiunge le parole scritte nel campo: più d'una se separate da virgole.
    private func add() {
        let words = draft.split(whereSeparator: { $0 == "," || $0 == ";" || $0.isNewline })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { Vocabulary.key($0).count >= 2 }
        guard !words.isEmpty else { return }
        var list = settings.vocabulary
        for word in words where !list.contains(where: { Vocabulary.key($0) == Vocabulary.key(word) }) {
            list.append(word)
        }
        settings.vocabulary = list
        draft = ""
    }
}

/// Una parola del vocabolario, come etichetta che si toglie con la x.
struct WordChip: View {
    let word: String
    let remove: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 5) {
            Text(word).font(.system(size: 12, weight: .medium)).lineLimit(1)
            Button(action: remove) {
                Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
                    .foregroundStyle(hovering ? .primary : .tertiary)
            }
            .buttonStyle(.plain)
            .help(String(localized: "Togli"))
        }
        .padding(.leading, 10).padding(.trailing, 8).padding(.vertical, 5)
        .background(Capsule().fill(.quaternary.opacity(hovering ? 1 : 0.6)))
        .overlay(Capsule().strokeBorder(.quaternary))
        .onHover { hovering = $0 }
    }
}

/// Mette le etichette una accanto all'altra e va a capo quando la riga è piena.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        return CGSize(width: proposal.width ?? rows.width, height: rows.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let rows = arrange(width: bounds.width, subviews: subviews)
        for (index, point) in rows.points.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + point.x, y: bounds.minY + point.y), proposal: .unspecified)
        }
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> (points: [CGPoint], width: CGFloat, height: CGFloat) {
        var points: [CGPoint] = []
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, widest: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            points.append(CGPoint(x: x, y: y))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            widest = max(widest, x - spacing)
        }
        return (points, widest, y + rowHeight)
    }
}

// MARK: - Pulizia

/// Perché la pulizia col modello di Apple non c'è, se non c'è: così non resta un interruttore acceso che non fa
/// niente senza dirlo.
struct CleanupAvailabilityNote: View {
    var body: some View {
        if let reason = Self.reason {
            Label(reason, systemImage: "info.circle")
                .font(.system(size: 12)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    static var reason: String? {
        switch SystemLanguageModel.default.availability {
        case .available: return nil
        case .unavailable(.appleIntelligenceNotEnabled):
            return String(localized: "La pulizia usa Apple Intelligence, che su questo Mac è spenta. Accendila in Impostazioni di Sistema › Apple Intelligence e Siri; finché è spenta il testo viene sistemato solo con le regole di Charland.")
        case .unavailable(.modelNotReady):
            return String(localized: "Il Mac sta ancora scaricando il modello di Apple Intelligence: fino ad allora il testo viene sistemato solo con le regole di Charland.")
        case .unavailable:
            return String(localized: "Questo Mac non ha Apple Intelligence: il testo viene sistemato con le regole di Charland, senza il modello.")
        }
    }
}
