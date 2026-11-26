import AppKit
import SwiftUI

/// Impostazioni › Appunti: lo storico, quante voci tiene, se incolla subito, le scorciatoie, cancella.
struct ClipboardPane: View {
    @Bindable private var settings = ClipboardSettings.shared
    @State private var confirming = false

    var body: some View {
        Form {
            Section {
                Toggle("Storico degli appunti", isOn: $settings.enabled)
                Toggle("Incolla subito nell'app in primo piano", isOn: $settings.pasteOnSelect)
                    .disabled(!settings.enabled)
                Picker("Quanti ne ricorda", selection: $settings.limit) {
                    ForEach(ClipboardSettings.limits, id: \.self) { Text(verbatim: "\($0)").tag($0) }
                }
                .disabled(!settings.enabled)
            } footer: {
                Text("Un clic sulla farfalla nella barra dei menu apre gli appunti; trascinarla in giù fa un timer; ⌥ clic apre l'isola. Le password copiate dai gestori non vengono ricordate.")
            }
            ClipboardShortcutsSection(title: "Scorciatoie")
            Section {
                Button("Cancella lo storico…", role: .destructive) { confirming = true }
                    .disabled(!ClipboardHistory.shared.hasStoredHistory)
                    .confirmationDialog("Cancellare lo storico degli appunti?", isPresented: $confirming) {
                        Button("Cancella, tieni i fissati", role: .destructive) {
                            ClipboardHistory.shared.clear(includingPinned: false)
                        }
                        Button("Cancella anche i fissati", role: .destructive) {
                            ClipboardHistory.shared.clear(includingPinned: true)
                        }
                    }
            } footer: {
                Text("Prima di cancellare chiede se tenere le voci fissate.")
            }
        }
        .formStyle(.grouped)
    }
}

/// Le scorciatoie degli appunti: in Appunti e in Scorciatoie, le stesse. Apri vale in tutte le app; le altre solo col
/// menu aperto, e si cambiano col loro registratore.
struct ClipboardShortcutsSection: View {
    @Bindable private var settings = ClipboardSettings.shared
    /// «Appunti» in Scorciatoie, «Scorciatoie» dentro la sezione Appunti.
    var title: LocalizedStringKey = "Appunti"

    var body: some View {
        Section {
            LabeledContent("Apri") { ClipShortcutRecorder(combo: $settings.openCombo, global: true) }
            if settings.openTaken, settings.enabled {
                Label(takenText, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
            }
            LabeledContent("Fissa") { ClipShortcutRecorder(combo: $settings.pinCombo) }
            LabeledContent("Elimina") { ClipShortcutRecorder(combo: $settings.deleteCombo) }
            LabeledContent("Anteprima") { ClipShortcutRecorder(combo: $settings.previewCombo) }
            LabeledContent("Cancella") { KeysLabel(text: ClipboardSettings.clearCombo.display) }
            LabeledContent("Scegli") { KeysLabel(text: "⌘1 … ⌘9") }
            LabeledContent("Incolla senza formattazione") { KeysLabel(text: "⇧↩") }
        } header: {
            Text(title)
        } footer: {
            Text("Apri vale in tutte le app; le altre mentre il menu degli appunti è aperto.")
        }
    }

    private var takenText: String {
        let maccy = !NSRunningApplication.runningApplications(withBundleIdentifier: "org.p0deje.Maccy").isEmpty
        return maccy ? String(localized: "La tiene Maccy: chiudilo o scegline un'altra.")
            : String(localized: "La tiene un'altra app: scegline un'altra.")
    }
}

/// Registra una combinazione: un clic, poi i tasti (serve almeno un modificatore). La x la toglie.
struct ClipShortcutRecorder: View {
    @Binding var combo: KeyCombo?
    /// Apri è una scorciatoia di sistema: mentre si registra va tolta, se no scatta al posto di essere registrata.
    var global = false
    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        HStack(spacing: 6) {
            Button(recording ? String(localized: "Premi i tasti…") : (combo?.display ?? String(localized: "Nessuna"))) { toggle() }
                .monospaced()
            if combo != nil, !recording {
                Button { combo = nil } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .help(String(localized: "Togli la scorciatoia"))
            }
        }
        .onDisappear { stop() }
    }

    private func toggle() {
        if recording { stop(); return }
        recording = true
        if global { ClipboardMenu.shared.pauseShortcut() }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let new = KeyCombo(event: event)
            if new.modifiers != 0, event.keyCode != 53 { combo = new }
            stop()
            return nil
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if recording {
            recording = false
            if global { ClipboardMenu.shared.registerShortcut() }
        }
    }
}
