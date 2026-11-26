import SwiftUI
import AVFoundation
import ApplicationServices
import ServiceManagement
import CharlandCore
import CharlandKit
import CoreLocation
import EventKit

/// Le funzioni che si accendono e si spengono. Spenta, una funzione non carica niente.
@MainActor @Observable
final class Features {
    static let shared = Features()

    var api: Bool { didSet { UserDefaults.standard.set(api, forKey: "featureAPI"); apply() } }
    var agents: Bool { didSet { UserDefaults.standard.set(agents, forKey: "featureAgents"); apply() } }
    /// Volume e luminosità sul bordo, come su iPhone: accesi di serie (carpa, 18 novembre 2026). Prendono i tasti prima
    /// del sistema solo con l'Accessibilità concessa; se l'app cade due volte di fila mentre li ascolta si spengono da
    /// soli (`AppServices`, `MediaKeys.noteCrash`).
    var mediaKeys: Bool { didSet { UserDefaults.standard.set(mediaKeys, forKey: "featureMediaKeys"); apply() } }
    /// La musica in riproduzione nell'isola, da qualunque app.
    var music: Bool { didSet { UserDefaults.standard.set(music, forKey: "featureMusic"); apply() } }
    /// Nell'isola aperta sulla musica la linea del tempo si trascina avanti e indietro (carpa, 18 novembre 2026: «come
    /// opzione da poter rimuovere»). Spenta, la linea si guarda soltanto.
    var musicScrub: Bool { didSet { UserDefaults.standard.set(musicScrub, forKey: "featureMusicScrub") } }
    /// La farfalla nella barra dei menu, col timer da trascinare.
    var menuBar: Bool { didSet { UserDefaults.standard.set(menuBar, forKey: "featureMenuBar"); apply() } }
    /// Dopo aver lasciato la goccia, il campo per dare un nome al timer.
    var timerNames: Bool { didSet { UserDefaults.standard.set(timerNames, forKey: "featureTimerNames") } }
    /// Cosa suona quando un timer finisce.
    var timerSound: TimerSound { didSet { TimerSound.current = timerSound } }
    /// Passando sopra il notch si apre l'attività in corso (un agente al lavoro, un timer) invece della casa.
    var hoverOpensActivity: Bool { didSet { UserDefaults.standard.set(hoverOpensActivity, forKey: "featureHoverOpensActivity") } }
    /// Con qualcosa in riproduzione passando sopra il notch si apre la riproduzione invece della casa. Acceso di serie
    /// (carpa, 18 novembre 2026).
    var opensPlayback: Bool {
        didSet {
            UserDefaults.standard.set(opensPlayback, forKey: "featureOpensPlayback")
            let id = opensPlayback ? NowPlayingMonitor.activityID : nil
            IslandHub.shared.islands.forEach { $0.engine.setPlaybackID(id) }
        }
    }
    /// Dentro un'attività aperta le altre in corso come pillole, per passare dall'una all'altra. Acceso di serie, com'era.
    var showsOthers: Bool {
        didSet {
            UserDefaults.standard.set(showsOthers, forKey: "featureShowsOthers")
            IslandHub.shared.islands.forEach { $0.engine.setShowsOthers(showsOthers) }
        }
    }
    /// Il nome della cartella dove lavora l'agente, come etichetta nell'isola (carpa: «di default
    /// attiva, ma metti l'opzione per toglierla»).
    var projectNames: Bool { didSet { UserDefaults.standard.set(projectNames, forKey: "featureProjectNames") } }
    /// Le domande e i permessi degli agenti nell'isola (carpa, 19 novembre 2026: «quando un agente chiede nella sua
    /// chat una domanda o una conferma esca direttamente nell'isola»). Acceso di serie.
    var agentAsks: Bool {
        didSet {
            UserDefaults.standard.set(agentAsks, forKey: "featureAgentAsks")
            AgentAsks.shared.settingsChanged()
        }
    }
    /// L'attività «Schermo registrato o condiviso» mentre registri o condividi lo schermo. Spenta di serie: macOS mostra
    /// già il suo segno nella barra dei menu (carpa, 17 novembre 2026: «la sto già odiando, rendila opzionale»).
    var recordingAlert: Bool { didSet { UserDefaults.standard.set(recordingAlert, forKey: RecordingMonitor.settingKey); apply() } }
    /// La Concentrazione di macOS nell'isola: un momento quando la accendi e quando la spegni (carpa, 19 novembre 2026).
    /// Accesa di serie.
    var focus: Bool { didSet { UserDefaults.standard.set(focus, forKey: FocusMonitor.settingKey); apply() } }
    /// Quanto resta nell'isola un avviso che se ne va da solo (Claude al 90%, batteria, caricatore, app chiuse), in
    /// secondi. Tre di serie (carpa, 18 novembre 2026: «la durata sia customizzabile e di default sia 3s»).
    var noticeSeconds: Double { didSet { UserDefaults.standard.set(noticeSeconds, forKey: "noticeSeconds") } }
    /// La copertina della musica accanto alla fotocamera e nelle gocce ai lati: un disco che gira o la copertina ferma.
    var musicCover: MusicCoverStyle { didSet { UserDefaults.standard.set(musicCover.rawValue, forKey: "musicCoverStyle") } }
    /// Charland sul blocco schermo: i segni sotto l'orologio e, con la musica, il lettore (carpa, 18 novembre 2026).
    /// Usa funzioni private del sistema cercate a runtime: se mancano non compare niente e il resto continua.
    var lockScreen: Bool { didSet { UserDefaults.standard.set(lockScreen, forKey: "featureLockScreen"); apply() } }
    /// Il vassoio dei file sul notch (Impostazioni › Vassoio, 19 novembre 2026). Acceso di serie, com'era. Spento, un file
    /// trascinato verso il notch non apre l'isola e la casa non mostra la fila del vassoio.
    var tray: Bool { didSet { UserDefaults.standard.set(tray, forKey: "featureTray") } }
    /// La pillola del volume compare anche quando il volume lo cambia un'altra app o le AirPods, non solo coi tasti.
    var sliderExternal: Bool { didSet { UserDefaults.standard.set(sliderExternal, forKey: "sliderExternalVolume") } }

    private init() {
        let d = UserDefaults.standard
        api = d.object(forKey: "featureAPI") as? Bool ?? true
        agents = d.object(forKey: "featureAgents") as? Bool ?? true
        mediaKeys = d.object(forKey: "featureMediaKeys") as? Bool ?? true
        menuBar = d.object(forKey: "featureMenuBar") as? Bool ?? true
        // Spento di serie (carpa, 20 novembre 2026: «name the timer after dropping it sia off di default»): chi l'ha
        // acceso a mano lo tiene.
        timerNames = d.object(forKey: "featureTimerNames") as? Bool ?? false
        timerSound = TimerSound.current
        music = d.object(forKey: "featureMusic") as? Bool ?? true
        musicScrub = d.object(forKey: "featureMusicScrub") as? Bool ?? true
        hoverOpensActivity = d.object(forKey: "featureHoverOpensActivity") as? Bool ?? true
        opensPlayback = d.object(forKey: "featureOpensPlayback") as? Bool ?? true
        showsOthers = d.object(forKey: "featureShowsOthers") as? Bool ?? true
        projectNames = d.object(forKey: "featureProjectNames") as? Bool ?? true
        agentAsks = d.object(forKey: "featureAgentAsks") as? Bool ?? true
        recordingAlert = d.bool(forKey: RecordingMonitor.settingKey)
        focus = d.object(forKey: FocusMonitor.settingKey) as? Bool ?? true
        noticeSeconds = Self.clampNotice(d.object(forKey: "noticeSeconds") as? Double ?? Self.noticeDefault)
        musicCover = MusicCoverStyle(rawValue: d.string(forKey: "musicCoverStyle") ?? "") ?? .disc
        lockScreen = d.object(forKey: "featureLockScreen") as? Bool ?? true
        tray = d.object(forKey: "featureTray") as? Bool ?? true
        sliderExternal = d.object(forKey: "sliderExternalVolume") as? Bool ?? true
    }

    nonisolated static let noticeDefault = 3.0
    nonisolated static let noticeRange = 1.0...15.0
    nonisolated static func clampNotice(_ seconds: Double) -> Double { min(noticeRange.upperBound, max(noticeRange.lowerBound, seconds)) }
    /// La durata di un avviso, letta anche fuori dal thread principale (chi la chiede sta componendo un messaggio).
    nonisolated static var noticeTTL: Double {
        clampNotice(UserDefaults.standard.object(forKey: "noticeSeconds") as? Double ?? noticeDefault)
    }

    func apply() {
        if api || agents { ActivityCenter.shared.start() } else { ActivityCenter.shared.stop() }
        // Claude si collega da solo leggendo i suoi registri: nessuna impostazione da cambiare.
        if agents { AgentWatchers.start() } else { AgentWatchers.stop() }
        // Chi ha collegato Claude Code con una versione precedente (altri ganci, un altro percorso) torna a posto da sé.
        if agents { AgentLink.repairIfNeeded() }
        MediaKeys.shared.setEnabled(mediaKeys)
        MenuBarItem.shared.setShown(menuBar)
        if music { NowPlayingMonitor.shared.start() } else { NowPlayingMonitor.shared.stop() }
        if recordingAlert { RecordingMonitor.shared.start() } else { RecordingMonitor.shared.stop() }
        if focus { FocusMonitor.shared.start() } else { FocusMonitor.shared.stop() }
        if lockScreen { LockScreen.shared.start() } else { LockScreen.shared.stop() }
    }
}

/// Come si vede la copertina della musica nell'isola chiusa.
enum MusicCoverStyle: String, CaseIterable, Identifiable {
    /// Tonda, col foro al centro, gira mentre suona.
    case disc
    /// La copertina com'è, ferma, con gli angoli tondi.
    case still
    var id: String { rawValue }
    var title: String {
        switch self {
        case .disc: String(localized: "Disco che gira")
        case .still: String(localized: "Copertina ferma")
        }
    }
}

// MARK: - Generale

struct GeneralPane: View {
    @Bindable private var features = Features.shared
    @Bindable private var voice = VoiceSettings.shared
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        Form {
            Section {
                Toggle("Apri all'accensione del Mac", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, on in
                        do {
                            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                        } catch {
                            launchAtLogin = SMAppService.mainApp.status == .enabled
                        }
                    }
            }
            Section {
                Toggle("Anche a coperchio chiuso", isOn: Binding(get: { KeepAwake.shared.closedLid },
                                                                set: { KeepAwake.shared.closedLid = $0 }))
                Toggle("Quando Claude tiene sveglio il Mac", isOn: Binding(get: { KeepAwake.shared.followClaude },
                                                                          set: { KeepAwake.shared.followClaude = $0 }))
                if KeepAwake.shared.closedLid || KeepAwake.shared.followClaude { HelperStatusRow() }
            } header: {
                Text("Mantieni attivo")
            } footer: {
                Text("La prima volta Charland installa un piccolo aiutante di sistema: lo approvi una volta in Impostazioni di Sistema e poi non chiede più la password. Il sonno normale torna da solo quando lo spegni, quando scade il tempo, con la batteria al 10% o se Charland si chiude. Con la mascotte resta attivo finché gli agenti lavorano, sotto-agenti compresi, e si spegne due minuti dopo l'ultimo. Con «Quando Claude tiene sveglio il Mac», se nell'app di Claude è acceso «Keep computer awake», Claude continua a lavorare anche a coperchio chiuso, e il Mac torna a dormire due minuti dopo che ha finito.")
            }
            Section {
                // Una scelta e non un interruttore (carpa, 17 novembre 2026: «deve esserci l'opzione per far sì che
                // la Dynamic Island ti entri subito nelle live activities oppure nella pagina principale»).
                Picker("Passando sopra il notch", selection: $features.hoverOpensActivity) {
                    Text("Apri l'attività").tag(true)
                    Text("Apri la casa").tag(false)
                }
                .pickerStyle(.segmented)
                Toggle("Con la musica apri la riproduzione", isOn: $features.opensPlayback)
                Toggle("Mostra le altre attività dentro un'attività", isOn: $features.showsOthers)
            } header: {
                Text("Isola")
            } footer: {
                if features.hoverOpensActivity {
                    Text("Con un'attività in corso (un agente al lavoro, un timer) si apre subito lei, e passando sopra una goccia staccata si apre l'attività di quella goccia. La casa resta a un clic sull'isola aperta. Si vedono fino a tre attività: una ai lati della fotocamera, una nella goccia a destra e una in quella a sinistra.")
                } else if features.opensPlayback {
                    Text("Si apre la casa, con in cima le attività in corso; con qualcosa in riproduzione si apre la riproduzione, e la casa resta a un clic. Si vedono fino a tre attività: una ai lati della fotocamera, una nella goccia a destra e una in quella a sinistra.")
                } else {
                    Text("Si apre sempre la casa, con in cima le attività in corso. Si vedono fino a tre attività: una ai lati della fotocamera, una nella goccia a destra e una in quella a sinistra.")
                }
            }
            Section {
                LabeledContent("Durata degli avvisi") {
                    HStack(spacing: 10) {
                        Slider(value: $features.noticeSeconds, in: Features.noticeRange, step: 0.5)
                            .frame(width: 180)
                        Text(verbatim: features.noticeSeconds.formatted(.number.precision(.fractionLength(0...1))) + " s")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(width: 44, alignment: .trailing)
                    }
                }
            } header: {
                Text("Avvisi")
            } footer: {
                Text("Quanto restano nell'isola gli avvisi che se ne vanno da soli: un agente vicino al limite, la batteria scarica, il caricatore collegato, un timer finito.")
            }
            WeatherSettingsSection()
            Section("Funzioni") {
                Toggle("Dettatura", isOn: $voice.enabled)
                    .onChange(of: voice.enabled) { _, _ in DictationController.shared.start() }
                Toggle("Volume e luminosità", isOn: $features.mediaKeys)
                Toggle("Agenti", isOn: $features.agents)
                Toggle("API per le altre app", isOn: $features.api)
                Toggle("Musica in riproduzione", isOn: $features.music)
                if features.music {
                    MusicAppPicker()
                    Picker("Copertina nell'isola", selection: $features.musicCover) {
                        ForEach(MusicCoverStyle.allCases) { style in Text(style.title).tag(style) }
                    }
                    Toggle("Sposta la canzone trascinando la linea del tempo", isOn: $features.musicScrub)
                    // macOS mostra già la musica nella sua barra dei menu: con l'isola si vedrebbe due volte (carpa,
                    // 18 novembre 2026: «aggiungi il consiglio … per non avere il doppione»).
                    LabeledContent {
                        Button("Apri Barra dei menu") {
                            if let url = URL(string: "x-apple.systempreferences:com.apple.ControlCenter-Settings.extension") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                    } label: {
                        Text("Per non vedere la musica due volte, togli «In riproduzione» dalla barra dei menu di macOS: Impostazioni di Sistema › Barra dei menu.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
                Toggle("Avviso quando registri o condividi lo schermo", isOn: $features.recordingAlert)
                Toggle("Avviso quando accendi o spegni Full immersion", isOn: $features.focus)
            }
            Section {
                Toggle("Farfalla nella barra dei menu", isOn: $features.menuBar)
                Toggle("Dai un nome al timer dopo averlo lasciato", isOn: $features.timerNames)
                LabeledContent("Suono alla fine") {
                    HStack(spacing: 8) {
                        Picker("Suono alla fine", selection: $features.timerSound) {
                            ForEach(TimerSound.allCases) { sound in Text(sound.title).tag(sound) }
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                        .fixedSize()
                        Button("Ascolta") { previewSound() }
                            .disabled(features.timerSound == .off)
                    }
                }
            } header: {
                Text("Barra dei menu")
            } footer: {
                Text("Trascinala in giù per un timer: più scendi, più minuti. Lasciala e il timer va nell'isola, dove puoi scrivergli un nome. Un clic apre l'isola. La sveglia suona finché non la fermi dall'isola, al massimo un minuto.")
            }
        }
        .formStyle(.grouped)
    }

    /// Fa sentire il suono scelto: la sveglia per tre secondi, l'altro una volta.
    private func previewSound() {
        switch features.timerSound {
        case .alarm: AlarmPlayer.shared.preview()
        case .chime: NSSound(named: "Glass")?.play()
        case .off: break
        }
    }
}

/// L'aiutante del coperchio chiuso: lo stato, e finché non è approvato una guida in tre passi che dice cosa fare
/// perché il Mac non chieda più la password (carpa: «voglio che l'app ti dica cosa fare per non far apparire ste robe»).
struct HelperStatusRow: View {
    @State private var status = PrivilegedHelper.service.status
    /// Risponde davvero: «approvato» in Impostazioni di Sistema non basta (dopo un'installazione launchd lo perde).
    /// `nil` finché non si è chiesto.
    @State private var answering: Bool?
    @State private var repairing = false

    var body: some View {
        Group {
            if status == .enabled, answering == false {
                LabeledContent("Aiutante di sistema") {
                    HStack(spacing: 8) {
                        Label("Non risponde", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        Button(repairing ? "Riparo…" : "Ripara") { repair() }.disabled(repairing)
                    }
                }
            } else if status == .enabled {
                LabeledContent("Aiutante di sistema") {
                    Label("Attivo: niente più password", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                }
            } else {
                HelperGuide(status: status) {
                    if PrivilegedHelper.installedApp { status = PrivilegedHelper.ensureRegistered() }
                    PrivilegedHelper.openApproval()
                }
            }
        }
        .task {
            while !Task.isCancelled {
                status = PrivilegedHelper.service.status
                // Una domanda vera all'aiutante quando diventa approvato (o all'apertura), non ogni due secondi.
                // Se tiene già il coperchio chiuso risponde di sicuro: niente domanda.
                if status == .enabled, answering == nil {
                    answering = KeepAwake.shared.closedLidEngaged ? true : await PrivilegedHelper.reachable()
                    if answering == false { repair() }
                } else if status != .enabled {
                    answering = nil
                }
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    private func repair() {
        guard !repairing else { return }
        repairing = true
        Task {
            answering = await PrivilegedHelper.repair()
            status = PrivilegedHelper.service.status
            repairing = false
        }
    }
}

/// Cosa fare, una volta sola, perché il coperchio chiuso non chieda la password.
struct HelperGuide: View {
    let status: SMAppService.Status
    let open: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Una volta sola, e poi niente più password")
                .font(.system(size: 13, weight: .semibold))
            Text("Per tenere sveglio il Mac chiuso Charland usa un piccolo aiutante di sistema. Va approvato una volta:")
                .font(.system(size: 12)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 6) {
                step(1, String(localized: "Premi «Apri Elementi di login» qui sotto."))
                step(2, String(localized: "In «Consenti in background» accendi Charland."))
                step(3, String(localized: "Se il Mac chiede la password o Touch ID, è l'ultima volta."))
            }
            Text("L'avviso «Elementi in background aggiunti» di macOS è proprio questo aiutante. Quando è approvato, qui compare «Attivo».")
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Apri Elementi di login", action: open)
                .buttonStyle(.borderedProminent)
                .disabled(!PrivilegedHelper.installedApp)
            if !PrivilegedHelper.installedApp {
                Text("Funziona solo con Charland installata in Applicazioni.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    private func step(_ n: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(n)").font(.system(size: 11, weight: .bold, design: .rounded)).monospacedDigit()
                .frame(width: 18, height: 18)
                .background(Circle().fill(.quaternary))
            Text(text).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Le sostituzioni della dettatura: quando dici una cosa ne scrive un'altra («gta 6» diventa «GTA VI»).
struct ReplacementsSection: View {
    @Bindable var settings: VoiceSettings

    var body: some View {
        Section {
            ForEach($settings.replacements) { $rule in
                HStack(spacing: 8) {
                    TextField("Quando dici", text: $rule.spoken, prompt: Text("gta 6"))
                        .textFieldStyle(.roundedBorder)
                    Image(systemName: "arrow.right").foregroundStyle(.tertiary)
                    TextField("Scrive", text: $rule.written, prompt: Text("GTA VI"))
                        .textFieldStyle(.roundedBorder)
                    Button {
                        settings.replacements.removeAll { $0.id == rule.id }
                    } label: {
                        Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                    .help(String(localized: "Togli"))
                }
                .labelsHidden()
            }
            Button {
                settings.replacements.append(Replacement(spoken: "", written: ""))
            } label: {
                Label("Aggiungi una sostituzione", systemImage: "plus")
            }
            .buttonStyle(.borderless)
        } header: {
            Text("Sostituzioni")
        } footer: {
            Text("Quando dici la parola a sinistra, scrive quella a destra. Vale anche se il motore la scrive in un altro modo: «gta sei», «Gta6», «GTA 6.» diventano tutti «GTA VI».")
        }
    }
}

/// La lingua della dettatura, come in OpenWhispr: «Automatica», le lingue europee (Orukeet) e le altre che il
/// riconoscimento vocale di Apple sa fare su questo Mac. Scegliendone una che manca, il sistema la scarica.
struct LanguagePicker: View {
    @Bindable var settings: VoiceSettings
    @State private var apple: [DictationLanguage] = []
    @State private var status: String?
    @State private var preparing = false

    var body: some View {
        Picker("Lingua", selection: $settings.language) {
            Text(DictationLanguages.auto.name).tag("auto")
            Section("Lingue europee") {
                ForEach(DictationLanguages.parakeet.sorted { $0.name < $1.name }) { Text($0.name).tag($0.code) }
            }
            if !apple.isEmpty {
                Section("Altre lingue, con il riconoscimento di Apple") {
                    ForEach(apple.sorted { $0.name < $1.name }) { Text($0.name).tag($0.code) }
                }
            }
        }
        .task {
            var found: [DictationLanguage] = []
            for language in DictationLanguages.apple {
                if let locale = language.appleLocale, await AppleDictation.isSupported(locale) { found.append(language) }
            }
            apple = found
        }
        .onChange(of: settings.language) { _, code in prepare(code) }
        if let status {
            HStack(spacing: 6) {
                if preparing { ProgressView().controlSize(.small) }
                Text(status).foregroundStyle(.secondary).font(.callout)
            }
        } else if settings.dictationLanguage.isAuto {
            Text("Riconosce da sola italiano, inglese, spagnolo, francese, tedesco e altre 20 lingue europee.")
                .foregroundStyle(.secondary).font(.callout)
        }
    }

    /// Una lingua di Apple che non c'è ancora: la scarica il sistema, sul Mac. Poi resta lì.
    private func prepare(_ code: String) {
        let language = DictationLanguages.find(code)
        guard let locale = language.appleLocale else { status = nil; return }
        preparing = true
        status = String(localized: "Preparo \(language.name)…")
        Task {
            do {
                try await AppleDictation.prepare(locale)
                status = String(localized: "\(language.name) è pronta, anche senza rete.")
            } catch {
                status = String(localized: "\(language.name) non si può scaricare adesso. Riprova con la rete.")
            }
            preparing = false
        }
    }
}

// MARK: - Voce

struct VoicePane: View {
    @Bindable private var settings = VoiceSettings.shared
    private let dictation = DictationController.shared
    private let downloads = ModelDownloads.shared
    @State private var trial: DictationRecord?
    @State private var trying = false

    var body: some View {
        Form {
            // Prima di tutto: cosa serve perché funzioni, e quando è pronta un campo per provarla.
            DictationSetupGuide(settings: settings)

            Section {
                LabeledContent("Tasto") {
                    ShortcutRecorder(combo: $settings.combo, allowsModifiersOnly: true)
                }
                LanguagePicker(settings: settings)
                Toggle("Pulisci il testo", isOn: $settings.cleanup)
                if settings.cleanup { CleanupAvailabilityNote() }
                Toggle("Tieni le ultime dettature", isOn: $settings.keepHistory)
            } footer: {
                if let error = dictation.lastError {
                    Text(error).foregroundStyle(.red)
                } else {
                    Text("Il tasto può essere una combinazione come ⌥Z o anche solo ⌃⌥: fai clic, premili insieme e lasciali.")
                }
            }

            VocabularySection(settings: settings)

            ReplacementsSection(settings: settings)

            Section("Modello") {
                let _ = downloads.revision
                ForEach(VoiceModel.all) { model in
                    ModelRow(model: model, progress: downloads.progress[model.id], selected: ModelStore.selected == model,
                             select: { ModelStore.selected = model; downloads.changed() },
                             download: { downloads.download(model) },
                             remove: { ModelStore.remove(model); downloads.changed() })
                }
                if OpenWhisprImport.hasModel, !ModelStore.isInstalled(.orukeet) {
                    Button("Importa da OpenWhispr") { importFromOpenWhispr() }
                }
                if let message = downloads.message { Text(message).foregroundStyle(.secondary) }
            }

            Section {
                Button(trying ? String(localized: "Sto provando…") : String(localized: "Prova con una frase")) { tryPhrase() }
                    .disabled(trying || ModelStore.selected == nil)
                if let trial {
                    Text(trial.text).font(.system(size: 15, weight: .medium)).textSelection(.enabled)
                    LabeledContent("Trascrizione") { Text("\(Int(trial.transcribeSeconds * 1000)) ms").monospacedDigit() }
                    if settings.cleanup {
                        LabeledContent("Pulizia") { Text("\(Int(trial.cleanSeconds * 1000)) ms").monospacedDigit() }
                    }
                }
            } header: {
                Text("Prova del motore")
            } footer: {
                Text("Charland fa leggere una frase a una voce del Mac, senza farla sentire, e la trascrive col modello scelto: per vedere quanto è preciso e quanto ci mette, senza parlare.")
            }

            if !dictation.history.isEmpty {
                Section("Ultime dettature") {
                    ForEach(dictation.history.prefix(8)) { record in
                        Text(record.text).lineLimit(2).textSelection(.enabled)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private func importFromOpenWhispr() {
        downloads.importFromOpenWhispr()
        let found = OpenWhisprImport.readSettings()
        if let language = found.language { settings.language = DictationLanguages.all.contains { $0.code == language } ? language : "auto" }
    }

    private func tryPhrase() {
        trying = true
        Task {
            let folder = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent(Identity.bundleID)
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let file = folder.appendingPathComponent("prova-\(settings.language).aiff")
            if !FileManager.default.fileExists(atPath: file.path) {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/say")
                process.arguments = settings.language == "en"
                    ? ["-v", "Samantha", "-o", file.path, "Um, remind me to call the dentist tomorrow at ten and bring the x-rays."]
                    : ["-v", "Alice", "-o", file.path, "Ehm, ricordami di chiamare il dentista domani alle dieci e di portare le lastre."]
                try? process.run()
                process.waitUntilExit()
            }
            trial = await DictationController.shared.runFile(file, cleanup: settings.cleanup)
            trying = false
        }
    }
}

struct ModelRow: View {
    let model: VoiceModel
    let progress: Double?
    let selected: Bool
    let select: () -> Void
    let download: () -> Void
    let remove: () -> Void

    var body: some View {
        let installed = ModelStore.isInstalled(model)
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(model.title).font(.system(size: 14, weight: .medium))
                Text(installed ? ByteCountFormatter.string(fromByteCount: ModelStore.bytes(model), countStyle: .file) : "\(model.megabytes) MB")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Spacer()
            if let progress {
                ProgressView(value: progress).frame(width: 120)
            } else if installed {
                if selected {
                    Image(systemName: "checkmark").foregroundStyle(.tint).fontWeight(.semibold)
                } else {
                    Button("Usa", action: select)
                }
                Button("Togli", role: .destructive, action: remove)
            } else {
                Button("Scarica", action: download)
            }
        }
    }
}

// MARK: - Agenti

/// Il collegamento con Claude Code: un gancio nelle sue impostazioni (`~/.claude/settings.json`), quello delle
/// richieste di permesso, che porta a `charland hook claude`. Serve solo per rispondere dall'isola: vedere le domande
/// funziona senza.
enum AgentLink {
    static var settingsURL: URL {
        ProcessInfo.processInfo.environment["CHARLAND_CLAUDE_SETTINGS"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/settings.json")
    }

    static var cliPath: String {
        Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/\(Identity.cli)").path
    }

    /// Il file delle impostazioni com'è adesso. «Non c'è» e «c'è ma non si legge» sono cose diverse: sul secondo non
    /// si scrive, perché collegare partendo da niente sostituirebbe tutto quello che contiene.
    enum Current: Equatable {
        case missing
        case unreadable
        case text(String)

        var text: String? {
            if case .text(let text) = self { return text }
            return nil
        }
    }

    /// Dove sta davvero il file: se `settings.json` è un collegamento (chi tiene le impostazioni in una cartella sua)
    /// si legge e si scrive il file a cui punta, e il collegamento resta.
    private static var target: URL { settingsURL.resolvingSymlinksInPath() }

    static func read() -> Current {
        guard FileManager.default.fileExists(atPath: target.path) else { return .missing }
        guard let data = FileManager.default.contents(atPath: target.path), let text = String(data: data, encoding: .utf8) else {
            return .unreadable
        }
        return .text(text)
    }

    static func current() -> String? { read().text }

    static var isConnected: Bool { AgentConfig.isConnected(existing: current()) }

    /// Scrive il file nuovo, dopo aver messo accanto una copia di com'era.
    static func write(_ text: String) throws {
        try FileManager.default.createDirectory(at: settingsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: target.path) {
            let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
            try FileManager.default.copyItem(at: target, to: settingsURL.deletingLastPathComponent()
                .appendingPathComponent("settings.json.prima-di-charland-\(stamp)"))
        }
        try text.write(to: target, atomically: true, encoding: .utf8)
    }

    /// Già collegato, ma con i ganci di una versione precedente o col percorso di un'app che si è spostata: li rimette
    /// giusti. Non collega chi non l'ha chiesto. Solo dall'app installata: una copia di prova non riscrive il percorso.
    @MainActor static func repairIfNeeded() {
        guard !repaired, Bundle.main.bundlePath.hasPrefix("/Applications/") else { return }
        repaired = true
        // Solo su un file che si legge: se manca o non si legge non c'è niente da riparare.
        guard let old = read().text else { return }
        guard AgentConfig.needsRepair(existing: old, cliPath: cliPath),
              let new = try? AgentConfig.connect(existing: old, cliPath: cliPath) else { return }
        try? write(new)
    }

    @MainActor private static var repaired = false
}

struct AgentsPane: View {
    @Bindable private var features = Features.shared
    @State private var preview: [String] = []
    @State private var pending: String?
    /// Il file com'era quando si sono calcolate le righe da mostrare, e cosa si stava facendo: se nel frattempo cambia,
    /// si ricalcola invece di scriverci sopra.
    @State private var pendingBase: AgentLink.Current?
    @State private var pendingDisconnect = false
    @State private var connected = false
    @State private var message: String?
    @State private var codexCopied = false

    private var settingsURL: URL { AgentLink.settingsURL }
    private var cliPath: String { AgentLink.cliPath }

    var body: some View {
        Form {
            Section {
                Toggle("Agenti al lavoro nell'isola", isOn: $features.agents)
                Toggle("Mostra la cartella in cui lavora", isOn: $features.projectNames)
                Toggle("Domande e permessi nell'isola", isOn: $features.agentAsks)
            } header: {
                Text("Nell'isola")
            } footer: {
                Text("Claude Code e Codex al lavoro compaiono nell'isola, col nome della cartella del progetto accanto; spento, Charland non li segue più. Quando un agente ti chiede un permesso o ti fa una domanda con dei pulsanti, la richiesta esce lì, dentro la sua attività: si vede anche senza collegare niente; con Claude Code collegato qui sotto rispondi coi suoi pulsanti. La «x» la toglie senza rispondere.")
            }
            Section {
                LabeledContent(connected ? String(localized: "Collegato") : String(localized: "Non collegato")) {
                    if connected {
                        Button("Scollega") { prepare(disconnect: true) }
                    } else {
                        Button("Collega") { prepare(disconnect: false) }
                    }
                }
                if pending != nil {
                    // Le differenze esatte, prima di scrivere qualsiasi cosa.
                    Text(settingsURL.path).font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary)
                    ScrollView {
                        Text(preview.joined(separator: "\n"))
                            .font(.system(size: 11, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                    .frame(height: 170)
                    HStack {
                        Button("Annulla") { pending = nil }
                        Spacer()
                        Button("Scrivi") { write() }.buttonStyle(.borderedProminent)
                    }
                }
                if let message { Text(message).foregroundStyle(.secondary) }
            } header: {
                Text("Claude Code")
            } footer: {
                Text("Collegato, nell'isola trovi i pulsanti di Claude (Approva, Rifiuta, le scelte di una domanda) e Claude va avanti con la tua risposta. La sua finestra resta com'è: vale la prima risposta, da una parte o dall'altra.")
            }
            Section {
                LabeledContent("Comando del gancio") {
                    Button(codexCopied ? String(localized: "Copiato") : String(localized: "Copia")) {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(AgentConfig.hookCommand(cliPath: cliPath, agent: "codex"), forType: .string)
                        codexCopied = true
                        Task { try? await Task.sleep(for: .seconds(1.5)); codexCopied = false }
                    }
                }
            } header: {
                Text(verbatim: "Codex")
            } footer: {
                Text("Codex non si collega da solo: copia il comando e mettilo come gancio PermissionRequest nelle impostazioni di Codex. Da lì le sue richieste di permesso si approvano anche dall'isola.")
            }
        }
        .formStyle(.grouped)
        .onAppear { reload() }
    }

    private func current() -> String? { AgentLink.current() }

    private func reload() {
        connected = AgentLink.isConnected
    }

    private func prepare(disconnect: Bool) {
        message = nil
        // Il gancio punta al comando dentro l'app: aperta dal DMG o da Download, il percorso sparirebbe con lei.
        if !disconnect, !Bundle.main.bundlePath.hasPrefix("/Applications/") {
            message = String(localized: "Prima sposta Charland nella cartella Applicazioni: il collegamento punta all'app, e da qui sparirebbe con lei.")
            return
        }
        let base = AgentLink.read()
        do {
            // Un file che c'è ma non si legge (permessi, caratteri rotti) non si tocca: partire da niente lo
            // sostituirebbe con le sole righe dei ganci.
            if base == .unreadable { throw AgentConfig.Failure.unreadable }
            let old = base.text
            let new = disconnect ? try AgentConfig.disconnect(existing: old) : try AgentConfig.connect(existing: old, cliPath: cliPath)
            preview = AgentConfig.diff(old: old, new: new)
            pending = new
            pendingBase = base
            pendingDisconnect = disconnect
        } catch {
            pending = nil
            message = String(localized: "Il file delle impostazioni di Claude Code non si legge: non lo tocco.")
        }
    }

    /// Scrive solo dopo il sì, e prima fa una copia del file com'era.
    private func write() {
        guard let pending else { return }
        // Il file è cambiato da quando hai visto le righe (Claude Code lo riscrive spesso): si rifà il conto e lo si
        // rimostra, invece di scrivere sopra quella modifica.
        guard AgentLink.read() == pendingBase else {
            prepare(disconnect: pendingDisconnect)
            if self.pending != nil { message = String(localized: "Il file è cambiato nel frattempo: queste sono le righe aggiornate.") }
            return
        }
        do {
            try AgentLink.write(pending)
            ActivityCenter.shared.setClient("claude-code", allowed: true)
            message = String(localized: "Fatto. Una copia del file com'era è accanto all'originale.")
        } catch {
            message = String(localized: "Non sono riuscito a scrivere il file.")
        }
        self.pending = nil
        reload()
    }
}

// MARK: - API

struct APIPane: View {
    private let center = ActivityCenter.shared
    @Bindable private var features = Features.shared
    @State private var refresh = 0

    private var cliPath: String {
        Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/\(Identity.cli)").path
    }

    var body: some View {
        Form {
            Section {
                Toggle("API per le altre app", isOn: $features.api)
                LabeledContent("Socket") {
                    Text(CharlandPaths.socket.path).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                }
                Button("Manda un'attività di prova") { sendTest() }
            } footer: {
                Text("L'attività di prova compare nell'isola per sei secondi, come quelle che mandano le altre app.")
            }
            Section {
                CopyRow(text: "sudo mkdir -p /usr/local/bin && sudo ln -sf \"\(cliPath)\" /usr/local/bin/\(Identity.cli)")
                CopyRow(text: "\(Identity.cli) watch --title \"Build\" -- npm run build")
                CopyRow(text: "eval \"$(\(Identity.cli) shell-init zsh)\"")
            } header: {
                Text("Comando da terminale")
            } footer: {
                Text("La prima riga mette il comando charland nel Terminale (chiede la password del Mac). La seconda mostra nell'isola un comando mentre gira, finché non finisce. La terza, nel tuo .zshrc, fa comparire nell'isola i comandi che durano più di dieci secondi.")
            }
            Section("App autorizzate") {
                let clients = center.knownClients
                if clients.isEmpty {
                    Text("Nessuna").foregroundStyle(.secondary)
                }
                ForEach(clients, id: \.name) { client in
                    LabeledContent(client.name) {
                        Toggle("", isOn: Binding(get: { client.allowed }, set: { center.setClient(client.name, allowed: $0); refresh += 1 }))
                            .labelsHidden()
                        Button("Dimentica") { center.setClient(client.name, allowed: nil); refresh += 1 }
                    }
                }
                .id(refresh)
            }
            Section("Ultime attività") {
                if center.log.isEmpty { Text("Nessuna").foregroundStyle(.secondary) }
                ForEach(center.log.prefix(10)) { line in
                    LabeledContent(line.client) { Text(line.text).lineLimit(1) }
                }
            }
        }
        .formStyle(.grouped)
    }

    private func sendTest() {
        var m = ActivityMessage(op: .upsert, client: "charland", id: "prova")
        m.template = .progress
        m.title = String(localized: "Attività di prova")
        m.progress = 0.6
        m.symbol = "hammer.fill"
        m.ttl = 6
        _ = center.handle(m, from: nil)
    }
}

struct CopyRow: View {
    let text: String

    var body: some View {
        HStack {
            Text(text).font(.system(size: 11, design: .monospaced)).lineLimit(2).textSelection(.enabled)
            Spacer()
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            } label: {
                Image(systemName: "doc.on.doc")
            }
            .buttonStyle(.borderless)
            .help(String(localized: "Copia"))
            .accessibilityLabel(String(localized: "Copia"))
        }
    }
}

// MARK: - Permessi

struct PermissionsPane: View {
    @State private var microphone = AVCaptureDevice.authorizationStatus(for: .audio)
    @State private var accessibility = AXIsProcessTrusted()
    @State private var inputMonitoring = CGPreflightListenEventAccess()
    @State private var calendar = EKEventStore.authorizationStatus(for: .event)
    @State private var location = PermissionsPane.locationManager.authorizationStatus
    @State private var timer: Timer?

    /// Uno solo, tenuto vivo: chiede il permesso della posizione (se no «Concedi» apriva un pannello dove Charland non c'è
    /// ancora) e ne legge lo stato, invece di crearne uno nuovo a ogni controllo.
    static let locationManager = CLLocationManager()

    /// Il nome del permesso cambia con la versione di macOS. Su macOS 27.3 il pannello Accessibilità delle app è vuoto:
    /// chi controlla le altre app (Charland, AltTab, Claude…) sta in «System & App Protection Override», con «Control your
    /// entire Mac and all apps» (visto il 26 novembre 2026 sul Mac di carpa, dopo il passaggio alla build ufficiale).
    static var accessibilityName: String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        if v.majorVersion == 27, v.minorVersion < 3 { return "Device Control and Data Access" }
        if v.majorVersion >= 27 { return "System & App Protection Override" }
        return String(localized: "Accessibilità")
    }

    static var accessibilityPurpose: String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        let uso = String(localized: "Per scrivere il testo dettato, prendere i tasti del volume e della luminosità, seguire il Dock e riconoscere la x rossa delle finestre.")
        guard v.majorVersion >= 27, v.minorVersion >= 3 || v.majorVersion > 27 else { return uso }
        return uso + " " + String(localized: "Premi Concedi e poi Apri Impostazioni di Sistema: in Privacy e sicurezza › System & App Protection Override Charland deve avere «Control your entire Mac and all apps». Il pannello Accessibilità resta vuoto, è normale.")
    }

    /// Dove portare chi preme Concedi: su macOS 27.3 il pannello Accessibilità è vuoto, meglio Privacy e sicurezza.
    static var accessibilityLink: String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        if v.majorVersion > 27 || (v.majorVersion == 27 && v.minorVersion >= 3) { return "x-apple.systempreferences:com.apple.preference.security?Privacy" }
        return "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
    }

    var body: some View {
        Form {
            Section {
                PermissionRow(title: String(localized: "Microfono"),
                              purpose: String(localized: "Per ascoltarti mentre tieni premuto il tasto della dettatura."),
                              granted: microphone == .authorized,
                              link: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
                    Task {
                        _ = await AudioCapture.requestPermission()
                        microphone = AVCaptureDevice.authorizationStatus(for: .audio)
                    }
                }
                PermissionRow(title: Self.accessibilityName,
                              purpose: Self.accessibilityPurpose,
                              granted: accessibility,
                              link: Self.accessibilityLink) {
                    let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
                    _ = AXIsProcessTrustedWithOptions(options)
                }
                PermissionRow(title: String(localized: "Monitoraggio input"),
                              purpose: String(localized: "Per sentire il tasto della dettatura e i tasti del volume e della luminosità da qualunque app."),
                              granted: inputMonitoring,
                              link: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") {
                    _ = CGRequestListenEventAccess()
                }
                PermissionRow(title: String(localized: "Calendario"),
                              purpose: String(localized: "Per il prossimo impegno accanto al Dock e sul blocco schermo."),
                              granted: calendar == .fullAccess,
                              link: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars") {
                    AgendaStore.shared.requestAccess()
                }
                PermissionRow(title: String(localized: "Localizzazione"),
                              purpose: String(localized: "Per il meteo della città dove sei, se in Generale la città è automatica."),
                              granted: ![.notDetermined, .denied, .restricted].contains(location),
                              link: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices") {
                    if location == .notDetermined { Self.locationManager.requestWhenInUseAuthorization() }
                }
            } footer: {
                Text("Charland chiede ogni permesso solo quando serve, e senza funziona tutto il resto. Si cambiano in Impostazioni di Sistema › Privacy e sicurezza. Se installi Charland da un'altra fonte (per esempio una copia compilata da te al posto di quella scaricata), macOS la vede come un'app nuova e i permessi vanno dati di nuovo.")
            }
            Section {
                HelperStatusRow()
            } header: {
                Text("Mantieni attivo a coperchio chiuso")
            }
        }
        .formStyle(.grouped)
        .onAppear {
            // Si ricontrolla solo mentre questa sezione è aperta.
            timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { _ in
                Task { @MainActor in
                    microphone = AVCaptureDevice.authorizationStatus(for: .audio)
                    accessibility = AXIsProcessTrusted()
                    inputMonitoring = CGPreflightListenEventAccess()
                    calendar = EKEventStore.authorizationStatus(for: .event)
                    location = Self.locationManager.authorizationStatus
                }
            }
        }
        .onDisappear {
            timer?.invalidate()
            timer = nil
        }
    }
}

struct PermissionRow: View {
    let title: String
    let purpose: String
    let granted: Bool
    let link: String
    let request: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 14, weight: .medium))
                Text(purpose).font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Spacer()
            if granted {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            } else {
                Button("Concedi") {
                    request()
                    if let url = URL(string: link) { NSWorkspace.shared.open(url) }
                }
            }
        }
    }
}

// MARK: - Informazioni

struct AboutPane: View {
    /// «1.0.1 (2)»: la versione e il numero di build, come in Informazioni su di macOS.
    static var versionText: String {
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        return build.map { "\(Identity.version) (\($0))" } ?? Identity.version
    }

    var body: some View {
        Form {
            Section {
                LabeledContent(Identity.name) { Text(verbatim: Self.versionText).monospacedDigit() }
                LabeledContent("Char Studio") { Link(Identity.site, destination: URL(string: "https://\(Identity.site)")!) }
            }
            UpdatesSection()
            Section {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Charland").font(.system(size: 14, weight: .medium))
                    Text("Free software, GPL-3.0 or later. No warranty.").font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Link("Source code on GitHub", destination: URL(string: "https://github.com/carpaaaaa/charland")!)
                ForEach(Credits.all, id: \.name) { credit in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(credit.name).font(.system(size: 14, weight: .medium))
                        Text(credit.detail).font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                }
                if let texts = Credits.fullTexts {
                    Button("Testi completi delle licenze") { NSWorkspace.shared.open(texts) }
                }
            } header: {
                Text("Licenze e attribuzioni")
            }
        }
        .formStyle(.grouped)
    }
}

enum Credits {
    struct Credit {
        let name: String
        let detail: String
    }

    static let all: [Credit] = [
        Credit(name: "Vorssaint", detail: "GPL-3.0-or-later · " + String(localized: "parti del codice (Space dell'isola e del blocco schermo, scrittura del testo, vetro attivo) sono adattate dal suo")),
        Credit(name: "AltTab", detail: "GPL-3.0 · " + String(localized: "la tecnica per trovare le finestre su altre scrivanie")),
        Credit(name: "mediaremote-adapter", detail: "BSD-3-Clause · " + String(localized: "la tecnica per leggere «In riproduzione»")),
        Credit(name: "sherpa-onnx", detail: "Apache License 2.0 · k2-fsa · " + String(localized: "con una modifica di Charland per il vocabolario della dettatura")),
        Credit(name: "ONNX Runtime", detail: "MIT License · Microsoft"),
        Credit(name: "Orukeet v0.1.0", detail: "CC BY-SA 4.0 · Oruk AI · " + String(localized: "adattamento di NVIDIA Parakeet TDT 0.6B v3")),
        Credit(name: "Parakeet TDT 0.6B v3", detail: "CC BY 4.0 · NVIDIA · " + String(localized: "convertito e quantizzato da k2-fsa")),
        Credit(name: "OpenWhispr", detail: "MIT License · " + String(localized: "il riferimento per la dettatura e per il confronto dei motori")),
        Credit(name: "Sparkle", detail: "MIT License · " + String(localized: "gli aggiornamenti dell'app")),
        Credit(name: "MET Norway", detail: "CC BY 4.0 · " + String(localized: "le previsioni del tempo, dall'istituto meteorologico norvegese")),
        Credit(name: "LRCLIB", detail: "lrclib.net · " + String(localized: "i testi a tempo delle canzoni")),
    ]

    /// I testi interi delle licenze (Apache 2.0 chiede di distribuirli con l'app), in `Terze parti.txt`.
    static var fullTexts: URL? { Bundle.main.url(forResource: "Terze parti", withExtension: "txt") }
}
