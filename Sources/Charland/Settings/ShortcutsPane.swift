import SwiftUI
import CharlandCore

/// Scorciatoie: tutte le scorciatoie di Charland in un posto, quelle che si cambiano con il
/// loro registratore.
struct ShortcutsPane: View {
    @Bindable private var voice = VoiceSettings.shared
    @Bindable private var awake = KeepAwake.shared

    var body: some View {
        Form {
            Section {
                LabeledContent("Detta tenendo premuto") {
                    ShortcutRecorder(combo: $voice.combo, allowsModifiersOnly: true)
                }
                LabeledContent("Mani libere") { KeysLabel(text: String(localized: "Doppia pressione")) }
                LabeledContent("Annulla") { KeysLabel(text: "esc") }
                LabeledContent("Rimetti l'ultima dettatura") {
                    ShortcutRecorder(combo: $voice.repeatCombo)
                }
            } header: {
                Text("Dettatura")
            } footer: {
                Text("Tieni premuta la scorciatoia mentre parli: quando la lasci, il testo viene scritto. Può essere anche solo ⌃⌥: premili insieme e lasciali.")
            }
            Section {
                LabeledContent("Accendi e spegni") {
                    OptionalShortcutRecorder(combo: $awake.combo)
                }
                Picker("Con la scorciatoia dura", selection: $awake.shortcutDuration) {
                    Text("30 min").tag(1800.0)
                    Text("1 h").tag(3600.0)
                    Text("2 h").tag(7200.0)
                    Text("Sempre").tag(0.0)
                }
            } header: {
                Text("Mantieni attivo")
            }
            Section {
                LabeledContent("Chiudi tutte le app") {
                    OptionalShortcutRecorder(combo: Bindable(AppQuitter.shared).quitAllCombo, hotkeyID: 40) {
                        AppQuitter.shared.registerShortcut()
                    }
                }
            } header: {
                Text("App")
            } footer: {
                Text("Le eccezioni si scelgono in Chiusura app.")
            }
            ClipboardShortcutsSection()
            Section {
                LabeledContent("Approva") { KeysLabel(text: "⌘↩") }
                LabeledContent("Rifiuta") { KeysLabel(text: "⌘⌫") }
                LabeledContent("Approva sempre") { KeysLabel(text: "⌘⌥↩") }
            } header: {
                Text("Agenti")
            } footer: {
                Text("Valgono solo mentre una richiesta è aperta nell'isola.")
            }
            Section("Volume e luminosità") {
                LabeledContent("Volume e luminosità") { KeysLabel(text: String(localized: "Tasti del Mac")) }
                LabeledContent("Passi più fini") { KeysLabel(text: "⌥⇧") }
            }
        }
        .formStyle(.grouped)
    }
}

/// Un tasto o una combinazione, scritto come sui tasti.
struct KeysLabel: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 12, weight: .medium, design: .rounded))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}

/// Registra una combinazione nuova: un clic, poi premi i tasti. Serve almeno un modificatore,
/// perché un tasto da solo ruberebbe una lettera a tutte le app. Con `allowsModifiersOnly` vale anche una
/// combinazione di soli modificatori, almeno due (⌃⌥): si premono insieme e si lasciano, senza lettera.
struct ShortcutRecorder: View {
    @Binding var combo: KeyCombo
    var allowsModifiersOnly = false
    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        Button(recording ? String(localized: "Premi i tasti…") : combo.display) { toggle() }
            .monospaced()
            .onDisappear { stop() }
    }

    private func toggle() {
        if recording { stop(); return }
        recording = true
        // Mentre si sceglie, i tasti vecchi non devono scattare.
        DictationController.shared.stop()
        let relevant: NSEvent.ModifierFlags = [.control, .option, .shift, .command]
        var peak: NSEvent.ModifierFlags = []
        let mask: NSEvent.EventTypeMask = allowsModifiersOnly ? [.keyDown, .flagsChanged] : [.keyDown]
        monitor = NSEvent.addLocalMonitorForEvents(matching: mask) { event in
            if event.type == .flagsChanged {
                let held = event.modifierFlags.intersection(relevant)
                if held.isEmpty {
                    // lasciati tutti senza una lettera: almeno due modificatori diventano la scorciatoia
                    let count = [NSEvent.ModifierFlags.control, .option, .shift, .command].filter { peak.contains($0) }.count
                    if count >= 2 {
                        combo = .modifiersOnly(KeyCombo.carbonModifiers(peak))
                        stop()
                    }
                    peak = []
                } else {
                    peak.formUnion(held)
                }
                return event
            }
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
            DictationController.shared.start()
        }
    }
}

/// Come `ShortcutRecorder`, ma la scorciatoia si può anche togliere.
struct OptionalShortcutRecorder: View {
    @Binding var combo: KeyCombo?
    /// La scorciatoia da sospendere mentre registri e da rimettere dopo: di serie Mantieni attivo.
    var hotkeyID: UInt32 = 4
    var reregister: () -> Void = { KeepAwake.shared.registerShortcut() }
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
        HotkeyCenter.shared.unregister(id: hotkeyID)
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
            reregister()
        }
    }
}
