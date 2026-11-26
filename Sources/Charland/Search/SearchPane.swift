import AppKit
import Combine
import SwiftUI

/// Impostazioni › Ricerca: l'interruttore della barra che esce dal notch, la scorciatoia, cosa cerca.
struct SearchPane: View {
    @Bindable private var settings = SearchSettings.shared
    @State private var trusted = AXIsProcessTrusted()
    @State private var forgotten = false
    private let timer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        Form {
            Section {
                Toggle("Ricerca di Charland", isOn: $settings.enabled)
            } footer: {
                Text("Al posto della ricerca di macOS: con la scorciatoia la barra esce dal notch come una goccia di vetro e cerca app, file, calcoli e web, o risponde alle tue domande. Spenta, la scorciatoia torna a macOS com'era.")
            }
            if settings.enabled, settings.hotkey == .needsAccessibility {
                Section {
                    PermissionRow(title: PermissionsPane.accessibilityName,
                                  purpose: String(localized: "Per prendere la scorciatoia prima di macOS e far uscire la barra dal notch."),
                                  granted: false,
                                  link: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
                        _ = AXIsProcessTrustedWithOptions(options)
                    }
                } footer: {
                    if settings.combo == SearchSettings.comboDefault {
                        Text("Finché manca, \(settings.combo.display) apre ancora la ricerca di macOS.")
                    }
                }
            }
            Section {
                LabeledContent("Scorciatoia") {
                    HStack(spacing: 8) {
                        SearchShortcutRecorder(combo: $settings.combo)
                        if settings.combo != SearchSettings.comboDefault {
                            Button("ricerca.ripristina") { settings.combo = SearchSettings.comboDefault }
                                .buttonStyle(.borderless)
                        }
                    }
                }
                LabeledContent("ricerca.prova") {
                    Button("Apri la ricerca") { SearchBar.shared.open() }
                        .disabled(!settings.enabled)
                }
            } footer: {
                Text("Con \(SearchSettings.comboDefault.display) la ricerca di macOS resta raggiungibile dalla riga Chiedi con ⌥↩. Se vuoi tenerle tutte e due, scegli un'altra scorciatoia, per esempio ⌥␣.")
            }
            Section {
                Toggle("App", isOn: $settings.apps)
                Toggle("App dell'iPhone", isOn: $settings.iphoneApps)
                Toggle("File e cartelle", isOn: $settings.files)
                Toggle("Calcoli", isOn: $settings.calculator)
                Toggle("Cerca sul web", isOn: $settings.web)
                if settings.web {
                    Picker("Motore di ricerca", selection: $settings.engine) {
                        ForEach(SearchEngine.allCases) { Text(verbatim: $0.name).tag($0) }
                    }
                }
                Toggle("Chiedi", isOn: $settings.ask)
                    .disabled(!SearchAsk.isAvailable)
            } header: {
                Text("Cosa cerca")
            } footer: {
                Text(askFooter)
            }
            Section {
                Button("Dimentica le scelte") {
                    SearchMemory.shared.forget()
                    forgotten = true
                }
                .disabled(forgotten || SearchMemory.shared.isEmpty)
            } footer: {
                Text("La barra impara cosa apri: le app e i file che scegli spesso salgono in cima, e ricorda cosa avevi scelto scrivendo le stesse lettere. Resta su questo Mac.")
            }
            Section {
                LabeledContent("Scegli") { KeysLabel(text: "↑ ↓  ⌘1 … ⌘9") }
                LabeledContent("Mostra nel Finder") { KeysLabel(text: "⌘↩") }
                LabeledContent("Chiedi a Siri") { KeysLabel(text: "⌥↩") }
                LabeledContent("Svuota, poi chiudi") { KeysLabel(text: "esc") }
            } header: {
                Text("Tasti")
            }
        }
        .formStyle(.grouped)
        .onReceive(timer) { _ in
            let now = AXIsProcessTrusted()
            if now != trusted { trusted = now }
        }
    }

    private var askFooter: String {
        guard SearchAsk.isAvailable else {
            return String(localized: "Chiedi usa il modello di Apple, che su questo Mac non è disponibile (Apple Intelligence spenta o in preparazione).")
        }
        return String(localized: "Chiedi risponde col modello di Apple sul Mac, senza mandare niente in rete. I file si cercano nell'indice di Spotlight, nella tua cartella Inizio.")
    }
}

/// Registra la scorciatoia della ricerca: un clic, poi i tasti. Serve ⌘ o ⌃ (o ⌥spazio): con ⇧ o ⌥ e una lettera
/// l'intercettazione toglierebbe un carattere a tutte le app. Con l'intercettazione accesa la combinazione la prende lei
/// (anche ⌘spazio, che altrimenti aprirebbe Siri prima di arrivare qui); senza, un ascolto della finestra.
struct SearchShortcutRecorder: View {
    @Binding var combo: KeyCombo
    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        Button(recording ? String(localized: "Premi i tasti…") : combo.display) { toggle() }
            .monospaced()
            .onDisappear { stop() }
            // Se la finestra perde la tastiera (⌘Tab in un'altra app) il registratore si spegne: le combinazioni premute
            // altrove non devono finire qui, né essere tolte all'app che le riceve.
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { _ in stop() }
    }

    private func toggle() {
        if recording { stop(); return }
        recording = true
        SearchHotkey.shared.pause(true)
        _ = SearchHotkey.shared.record { new in
            if SearchHotkey.acceptable(new) { combo = new }
            stop()
        }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let new = KeyCombo(event: event)
            if event.keyCode == 53 { stop(); return nil }
            if SearchHotkey.acceptable(new) { combo = new }
            stop()
            return nil
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if recording {
            recording = false
            SearchHotkey.shared.pause(false)
        }
    }
}
