import SwiftUI
import ApplicationServices
import CharlandCore

// Le tre sezioni che erano vuote fino al 19 novembre 2026 (carpa: «la sezione volume and brightness, la sezione tray e
// agenda e forse altre non hanno nulla»): Volume e luminosità, Vassoio e Calendario (prima Agenda).

// MARK: - Volume e luminosità

/// Impostazioni › Volume e luminosità: la pillola sul bordo sinistro come su iPhone (`SideSlider`).
struct SlidersPane: View {
    @Bindable private var features = Features.shared
    @State private var trusted = AXIsProcessTrusted()

    var body: some View {
        Form {
            Section {
                Toggle("Volume e luminosità sul bordo", isOn: $features.mediaKeys)
            } footer: {
                Text("I tasti del volume e della luminosità fanno uscire una pillola dal bordo sinistro dello schermo, come su iPhone, al posto del riquadro di macOS. Passaci sopra col puntatore e si allarga: trascinala per cambiare il livello. Col suono nelle cuffie o nelle AirPods mostra il loro simbolo.")
            }
            if features.mediaKeys, !trusted {
                Section {
                    PermissionRow(title: PermissionsPane.accessibilityName,
                                  purpose: String(localized: "Per prendere i tasti del volume e della luminosità prima di macOS."),
                                  granted: false,
                                  link: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
                        _ = AXIsProcessTrustedWithOptions(options)
                    }
                }
            }
            Section {
                Toggle("Anche quando il volume lo cambia un'altra app", isOn: $features.sliderExternal)
                LabeledContent("Passi più fini") { KeysLabel(text: "⌥⇧") }
            } header: {
                Text("Quando compare")
            } footer: {
                Text("Le AirPods, il telecomando di una cassa o un'app che cambia il volume fanno comparire la pillola anche senza tasti. Con ⌥⇧ insieme ai tasti il livello si muove a passi quattro volte più piccoli.")
            }
            .disabled(!features.mediaKeys)
            Section {
                LabeledContent("Mostra la pillola") {
                    HStack(spacing: 8) {
                        Button("Volume") { Self.preview(.volume) }
                        Button("Luminosità") { Self.preview(.brightness) }
                    }
                }
            } footer: {
                Text("Per vederla col livello di adesso, senza cambiarlo.")
            }
        }
        .formStyle(.grouped)
        .task {
            while !Task.isCancelled {
                trusted = AXIsProcessTrusted()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    /// La pillola col livello vero, come se avessi premuto un tasto ma senza cambiare niente.
    private static func preview(_ side: SliderSide) {
        switch side {
        case .volume:
            SideSlider.shared.present(side: .volume, level: SystemVolume.level ?? 0, muted: SystemVolume.muted,
                                      output: SystemVolume.outputSymbol())
        case .brightness:
            SideSlider.shared.present(side: .brightness, level: SystemBrightness.level ?? 0.5, muted: false)
        }
    }
}

// MARK: - Vassoio

/// Impostazioni › Vassoio: i file lasciati sul notch (`TrayStore`).
struct TrayPane: View {
    @Bindable private var features = Features.shared
    @Bindable private var tray = TrayStore.shared

    var body: some View {
        Form {
            Section {
                Toggle("Vassoio dei file sul notch", isOn: $features.tray)
            } footer: {
                Text("Trascina un file verso il notch: l'isola si apre e lo tiene nel vassoio, da dove lo trascini dove ti serve. Lasciandolo su «Condividi su AirDrop» parte subito con AirDrop. Il vassoio tiene un riferimento al file, non una copia: se lo sposti o lo cancelli, esce anche dal vassoio. Spento, il notch non prende più i file, nemmeno per AirDrop.")
            }
            if features.tray {
                Section {
                    Picker("Togli i file non fissati", selection: $tray.lifetimeDays) {
                        Text("Dopo 1 giorno").tag(1)
                        Text("Dopo 3 giorni").tag(3)
                        Text("Dopo una settimana").tag(7)
                        Text("Mai").tag(0)
                    }
                } footer: {
                    Text("Nel vassoio stanno fino a \(TrayStore.maxItems) file non fissati: oltre, escono i più vecchi. I fissati non contano, e la scelta vale subito anche per i file già dentro.")
                }
                Section {
                    if tray.items.isEmpty {
                        Text("Il vassoio è vuoto.").foregroundStyle(.secondary)
                    }
                    ForEach(tray.items) { item in
                        TrayPaneRow(item: item)
                    }
                    if tray.items.contains(where: { !$0.pinned }) {
                        Button("Svuota il vassoio") { tray.clear() }
                    }
                } header: {
                    Text("Nel vassoio adesso")
                } footer: {
                    if !tray.items.isEmpty {
                        Text("La puntina tiene un file nel vassoio finché non lo togli tu, o finché il file non sparisce dal Mac. «Svuota il vassoio» lascia i fissati.")
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { tray.prune() }
    }
}

/// Un file del vassoio nelle impostazioni: icona, nome, cartella, puntina e x.
private struct TrayPaneRow: View {
    let item: TrayItem
    private let tray = TrayStore.shared

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: item.path))
                .resizable()
                .frame(width: 24, height: 24)
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: item.name).lineLimit(1).truncationMode(.middle)
                Text(verbatim: (item.path as NSString).deletingLastPathComponent.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                    .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            Button { tray.setPinned(item, !item.pinned) } label: {
                Image(systemName: item.pinned ? "pin.fill" : "pin")
            }
            .buttonStyle(.borderless)
            .help(item.pinned ? String(localized: "Non tenerlo più fisso") : String(localized: "Tienilo nel vassoio"))
            .accessibilityLabel(item.pinned ? String(localized: "Non tenerlo più fisso") : String(localized: "Tienilo nel vassoio"))
            Button { NSWorkspace.shared.activateFileViewerSelecting([item.url]) } label: {
                Image(systemName: "magnifyingglass")
            }
            .buttonStyle(.borderless)
            .help(String(localized: "Mostra nel Finder"))
            .accessibilityLabel(String(localized: "Mostra nel Finder"))
            Button { tray.remove(item) } label: {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .help(String(localized: "Togli dal vassoio"))
            .accessibilityLabel(String(localized: "Togli dal vassoio"))
        }
    }
}

// MARK: - Calendario

/// Impostazioni › Calendario (prima «Agenda», e prima ancora dentro la sezione Dock). Carpa, 19 novembre 2026: «agenda
/// voglio diventi calendar e decidi cosa collegarci, quindi o Apple Calendar o Charcal». Scelta: la fonte è il Calendario
/// del Mac, che c'è su ogni Mac e porta dentro anche gli account Google ed Exchange; Charcal si aggiunge sopra, per chi lo
/// usa, con le sue cose da fare (i suoi eventi sono già quelli del Calendario: da solo darebbe solo le cose da fare).
/// Prima stava tutto nella sezione Dock e si vedeva solo col vassoio del prossimo impegno acceso, mentre lo legge anche il
/// blocco schermo.
struct CalendarPane: View {
    @Bindable private var settings = DockSettings.shared
    @Bindable private var lock = LockSettings.shared
    private let agenda = AgendaStore.shared
    private let charcal = CharcalAgenda.shared
    @State private var charcalToken = ""
    @State private var cliAvailable = false

    var body: some View {
        Form {
            sourcesSection
            calendarsSection
            charcalSection
            whereSection
        }
        .formStyle(.grouped)
        .task {
            agenda.loadCalendarsForSettings()
            while !Task.isCancelled {
                agenda.refreshAccess()
                cliAvailable = charcal.cliTokenAvailable
                try? await Task.sleep(for: .seconds(2))
            }
        }
        .onChange(of: settings.agendaCalendarOn) { _, _ in agenda.loadCalendarsForSettings() }
        .onChange(of: agenda.access) { _, _ in agenda.loadCalendarsForSettings() }
    }

    /// Le due fonti una sotto l'altra, ognuna col suo stato e il suo pulsante.
    private var sourcesSection: some View {
        Section {
            switch agenda.access {
            case .granted where !settings.agendaCalendarOn:
                LabeledContent {
                    Button("Collega") { settings.agendaCalendarOn = true }
                } label: {
                    sourceLabel(String(localized: "Calendario del Mac"), symbol: "calendar", status: String(localized: "Scollegato"))
                }
            case .granted:
                LabeledContent {
                    Button("Scollega") { settings.agendaCalendarOn = false }
                } label: {
                    sourceLabel(String(localized: "Calendario del Mac"), symbol: "calendar", status: String(localized: "Collegato"))
                }
            case .unknown:
                LabeledContent {
                    Button("Collega") {
                        settings.agendaCalendarOn = true
                        agenda.requestAccess()
                    }
                } label: {
                    sourceLabel(String(localized: "Calendario del Mac"), symbol: "calendar", status: String(localized: "Non collegato"))
                }
            case .denied:
                LabeledContent {
                    Button("Apri Impostazioni di Sistema") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                } label: {
                    sourceLabel(String(localized: "Calendario del Mac"), symbol: "calendar", status: String(localized: "Permesso negato"))
                }
            }
            LabeledContent {
                if charcal.connected {
                    Button("Scollega") { charcal.disconnect() }
                }
            } label: {
                HStack(spacing: 8) {
                    Circle().fill(Color(red: CharcalAgenda.accent.0, green: CharcalAgenda.accent.1, blue: CharcalAgenda.accent.2))
                        .frame(width: 9, height: 9)
                        .frame(width: 18)
                    Text(verbatim: "Charcal")
                    Text(charcalStatus).foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("Fonti")
        } footer: {
            Text("Gli eventi vengono dal Calendario del Mac, anche degli account Google ed Exchange che ci hai aggiunto. Se usi Charcal, le sue cose da fare di oggi e di domani si mettono accanto agli eventi, con l'ora o in fondo alla giornata. Charland legge e basta: scollegata una fonte, non la legge più.")
        }
    }

    private var charcalStatus: String {
        switch charcal.state {
        case .connected: String(localized: "Collegato")
        case .offline: String(localized: "Non raggiungibile, riprovo")
        case .connecting: String(localized: "Mi collego…")
        case .invalid: String(localized: "Token non valido")
        case .off: String(localized: "Non collegato")
        }
    }

    /// I calendari del Mac da guardare, a Calendario collegato.
    @ViewBuilder private var calendarsSection: some View {
        if agenda.usingCalendar {
            Section {
                if agenda.calendars.isEmpty {
                    Text("Nessun calendario sul Mac.").foregroundStyle(.secondary)
                }
                ForEach(agenda.calendars, id: \.id) { calendar in
                    Toggle(isOn: Binding(get: { !settings.agendaHiddenCalendars.contains(calendar.id) },
                                         set: { on in
                                             if on { settings.agendaHiddenCalendars.remove(calendar.id) } else { settings.agendaHiddenCalendars.insert(calendar.id) }
                                         })) {
                        HStack(spacing: 8) {
                            Circle().fill(calendar.color).frame(width: 9, height: 9)
                            Text(verbatim: calendar.title)
                            if !calendar.source.isEmpty {
                                Text(verbatim: calendar.source).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            } header: {
                Text("Calendari")
            }
        }
    }

    /// Charcal: il token per collegarlo, o le sue scelte quando è collegato. Il token resta nel Portachiavi.
    private var charcalSection: some View {
        Section {
            if charcal.connected {
                Toggle("Anche le cose senza ora", isOn: $settings.charcalUntimed)
            } else {
                if charcal.state == .invalid {
                    Text("Il token di prima non vale più: incollane uno nuovo.").foregroundStyle(.secondary)
                }
                HStack(spacing: 8) {
                    SecureField("Token API di Charcal", text: $charcalToken, prompt: Text(verbatim: "chc_…"))
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { charcal.connect(token: charcalToken) }
                    Button("Collega") { charcal.connect(token: charcalToken) }
                        .disabled(charcalToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || charcal.state == .connecting)
                    if charcal.state == .connecting { ProgressView().controlSize(.small) }
                }
                if cliAvailable {
                    Button("Usa il token della CLI charcal") { charcal.connectFromCLI() }
                        .disabled(charcal.state == .connecting)
                }
                if let problem = charcal.problem {
                    Text(verbatim: problem).foregroundStyle(.red)
                }
            }
        } header: {
            Text(verbatim: "Charcal")
        } footer: {
            if !charcal.connected {
                Text("Il token si crea in Charcal, Impostazioni › Account › Token API, e resta nel Portachiavi del Mac.")
            }
        }
        // Il campo si svuota solo a collegamento riuscito: dopo un errore il token resta da correggere.
        .onChange(of: charcal.state) { _, state in
            if state == .connected { charcalToken = "" }
        }
    }

    /// Dove si vedono gli impegni, con la strada per accenderli.
    private var whereSection: some View {
        Section {
            LabeledContent {
                Button("Dock…") { SettingsNavigation.shared.section = .dock }
            } label: {
                sourceLabel(String(localized: "Prossimo impegno accanto al Dock"), symbol: "dock.rectangle",
                            status: settings.isOn(.agenda) ? String(localized: "Acceso") : String(localized: "Spento"))
            }
            LabeledContent {
                Button("Blocco schermo…") { SettingsNavigation.shared.section = .lockScreen }
            } label: {
                sourceLabel(String(localized: "Sul blocco schermo"), symbol: "lock.display",
                            status: Features.shared.lockScreen && lock.slots.contains(.agenda) ? String(localized: "Acceso") : String(localized: "Spento"))
            }
            LabeledContent {
                Button("Righello…") { SettingsNavigation.shared.section = .ruler }
            } label: {
                sourceLabel(String(localized: "Righello della giornata sul bordo"), symbol: "ruler",
                            status: RulerSettings.shared.enabled ? String(localized: "Acceso") : String(localized: "Spento"))
            }
        } header: {
            Text("Dove si vede")
        } footer: {
            Text("Un clic sul vassoio del Dock apre la riunione se comincia entro dieci minuti, Charcal se la prossima è una cosa da fare, se no il Calendario.")
        }
    }

    private func sourceLabel(_ title: String, symbol: String, status: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol).foregroundStyle(.secondary).frame(width: 18)
            Text(verbatim: title)
            Text(verbatim: status).foregroundStyle(.secondary)
        }
    }
}
