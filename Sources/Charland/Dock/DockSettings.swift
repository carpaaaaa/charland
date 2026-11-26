import SwiftUI
import ApplicationServices
import UniformTypeIdentifiers

/// Da che parte del Dock sta un modulo.
enum DockSide: String, CaseIterable, Identifiable, Sendable, Codable {
    case left, right
    var id: String { rawValue }
    var title: String {
        switch self {
        case .left: String(localized: "Sinistra")
        case .right: String(localized: "Destra")
        }
    }
}

/// Dove sta un modulo e se si vede. L'ordine dell'elenco è l'ordine dal Dock verso fuori, lato per lato.
struct DockPlacement: Codable, Equatable, Identifiable, Sendable {
    var id: DockModuleID
    var side: DockSide
    var shown: Bool
}

/// Le scelte del Dock: tutto si accende e si spegne da qui (carpa: «voglio che sia tutto disattivabile o attivabile
/// in settings», «sempre customizzabile cosa mettere nel Dock»). Spento, non resta niente in piedi: né le finestre, né
/// la lettura del Dock, né gli ascolti del puntatore, né i dati dei moduli.
@MainActor @Observable
final class DockSettings {
    static let shared = DockSettings()

    /// I widget di vetro accanto al Dock.
    var enabled: Bool { didSet { save(enabled, "dockBar"); changed() } }
    /// Restano al loro posto anche quando il Dock a scomparsa si nasconde.
    var pinned: Bool { didSet { save(pinned, "dockBarPinned"); changed() } }
    /// Col cassetto di un widget aperto il Dock a scomparsa resta su (`DockHold`). Acceso di serie (carpa, 18 novembre 2026).
    var holdsDock: Bool { didSet { save(holdsDock, "dockBarHoldsDock"); if !holdsDock { DockHold.hold(false) } } }
    /// Il cassetto nasce dal vassoio come una goccia che sale e si stacca. Spento di serie (carpa, 18 novembre 2026:
    /// «non abbia questa animazione vetrosa liquida ma appaia semplicemente»): il cassetto compare al suo posto.
    var liquidDrawer: Bool { didSet { save(liquidDrawer, "dockDrawerLiquid"); changed() } }
    /// Quali moduli, da che parte, in che ordine.
    var placements: [DockPlacement] {
        didSet {
            if let data = try? JSONEncoder().encode(placements) { UserDefaults.standard.set(data, forKey: "dockPlacements") }
            changed()
        }
    }

    // Agenti AI
    /// Gli agenti che non vuoi vedere, anche se sul Mac ci sono.
    var hidden: Set<UsageProviderID> {
        didSet { UserDefaults.standard.set(hidden.map(\.rawValue).sorted(), forKey: "dockUsageHidden"); changed() }
    }
    /// Quello scelto: il suo numero sta scritto nel Dock.
    var selected: UsageProviderID { didSet { UserDefaults.standard.set(selected.rawValue, forKey: "dockUsageSelected"); changed() } }
    /// Mostra quanto resta invece di quanto hai usato.
    var showRemaining: Bool { didSet { save(showRemaining, "dockUsageRemaining"); changed() } }
    /// Chiede i numeri freschi ai comandi degli agenti (`claude`, `codex`).
    var live: Bool { didSet { save(live, "dockUsageLive"); changed() } }
    /// Avvisa nell'isola all'80% e al 95%.
    var alerts: Bool { didSet { save(alerts, "dockUsageAlerts"); changed() } }

    // Sistema
    var systemMetrics: Set<SystemStats.Metric> {
        didSet { UserDefaults.standard.set(systemMetrics.map(\.rawValue).sorted(), forKey: "dockSystemMetrics"); changed() }
    }
    var systemSelected: SystemStats.Metric {
        didSet { UserDefaults.standard.set(systemSelected.rawValue, forKey: "dockSystemSelected"); changed() }
    }

    // Prossimo impegno
    /// Gli eventi del Calendario nel prossimo impegno. Spento, Charland non legge il Calendario anche se ha il permesso
    /// (il permesso di macOS un'app non può toglierselo da sola): con Charcal collegato restano solo le sue cose.
    var agendaCalendarOn: Bool {
        didSet {
            save(agendaCalendarOn, "dockAgendaCalendar")
            AgendaStore.shared.calendarChoiceChanged()
        }
    }
    /// I calendari da non guardare.
    var agendaHiddenCalendars: Set<String> {
        didSet {
            UserDefaults.standard.set(agendaHiddenCalendars.sorted(), forKey: "dockAgendaHidden")
            AgendaStore.shared.refreshNow()
        }
    }

    /// Anche le cose di Charcal senza un'ora (quelle «in giornata» e «stasera»), in fondo alla giornata.
    var charcalUntimed: Bool {
        didSet {
            save(charcalUntimed, "dockCharcalUntimed")
            AgendaStore.shared.charcalChanged()
        }
    }

    // Dettatura
    /// Il testo delle ultime dettature nel cassetto (in una condivisione dello schermo potrebbe essere privato).
    var dictationShowText: Bool { didSet { save(dictationShowText, "dockDictationText"); changed() } }

    static let defaultPlacements: [DockPlacement] = [
        DockPlacement(id: .usage, side: .right, shown: true),
        DockPlacement(id: .system, side: .right, shown: true),
        DockPlacement(id: .agenda, side: .left, shown: true),
        DockPlacement(id: .dictation, side: .left, shown: true),
    ]

    private init() {
        let d = UserDefaults.standard
        enabled = d.object(forKey: "dockBar") as? Bool ?? true
        pinned = d.object(forKey: "dockBarPinned") as? Bool ?? false
        holdsDock = d.object(forKey: "dockBarHoldsDock") as? Bool ?? true
        liquidDrawer = d.object(forKey: "dockDrawerLiquid") as? Bool ?? false
        var list = (d.data(forKey: "dockPlacements")).flatMap { try? JSONDecoder().decode([DockPlacement].self, from: $0) }
            ?? Self.defaultPlacements
        if d.data(forKey: "dockPlacements") == nil {
            // Dalla prima versione (solo gli agenti): il lato e l'interruttore di allora.
            if let side = d.string(forKey: "dockBarSide").flatMap(DockSide.init(rawValue:)), let index = list.firstIndex(where: { $0.id == .usage }) {
                list[index].side = side
            }
            if let usage = d.object(forKey: "dockUsage") as? Bool, let index = list.firstIndex(where: { $0.id == .usage }) {
                list[index].shown = usage
            }
        }
        // Un modulo scritto due volte (un file rovinato) vale una volta sola.
        var seen: Set<DockModuleID> = []
        list = list.filter { seen.insert($0.id).inserted }
        // Un modulo nuovo, aggiunto dopo che le scelte erano state salvate, si accoda spento.
        for id in DockModuleID.allCases where !list.contains(where: { $0.id == id }) {
            list.append(DockPlacement(id: id, side: .right, shown: false))
        }
        placements = list
        hidden = Set((d.stringArray(forKey: "dockUsageHidden") ?? []).compactMap(UsageProviderID.init(rawValue:)))
        selected = UsageProviderID(rawValue: d.string(forKey: "dockUsageSelected") ?? "") ?? .claude
        showRemaining = d.object(forKey: "dockUsageRemaining") as? Bool ?? false
        live = d.object(forKey: "dockUsageLive") as? Bool ?? true
        alerts = d.object(forKey: "dockUsageAlerts") as? Bool ?? true
        systemMetrics = Set((d.stringArray(forKey: "dockSystemMetrics") ?? ["cpu", "memory", "disk"]).compactMap(SystemStats.Metric.init(rawValue:)))
        systemSelected = SystemStats.Metric(rawValue: d.string(forKey: "dockSystemSelected") ?? "") ?? .cpu
        agendaHiddenCalendars = Set(d.stringArray(forKey: "dockAgendaHidden") ?? [])
        agendaCalendarOn = d.object(forKey: "dockAgendaCalendar") as? Bool ?? true
        charcalUntimed = d.object(forKey: "dockCharcalUntimed") as? Bool ?? true
        dictationShowText = d.object(forKey: "dockDictationText") as? Bool ?? true
    }

    private func save(_ value: Bool, _ key: String) { UserDefaults.standard.set(value, forKey: key) }
    private func changed() { DockBar.shared.settingsChanged() }

    /// Acceso: il Dock acceso e il modulo messo a vista.
    func isOn(_ id: DockModuleID) -> Bool {
        enabled && placements.contains { $0.id == id && $0.shown }
    }

    func side(of id: DockModuleID) -> DockSide { placements.first { $0.id == id }?.side ?? .right }

    /// I moduli accesi di un lato, dal Dock verso fuori.
    func modules(on side: DockSide) -> [DockModuleID] {
        guard enabled else { return [] }
        return placements.filter { $0.side == side && $0.shown }.map(\.id)
    }

    func setShown(_ id: DockModuleID, _ shown: Bool) {
        guard let index = placements.firstIndex(where: { $0.id == id }) else { return }
        placements[index].shown = shown
    }

    func setSide(_ id: DockModuleID, _ side: DockSide) {
        guard let index = placements.firstIndex(where: { $0.id == id }) else { return }
        placements[index].side = side
    }

    /// Gli agenti da mostrare: quelli trovati sul Mac, meno quelli spenti.
    var providers: [UsageProviderID] { UsageStore.shared.detected.filter { !hidden.contains($0) } }

    func isShown(_ provider: UsageProviderID) -> Bool { !hidden.contains(provider) }

    func setShown(_ provider: UsageProviderID, _ shown: Bool) {
        if shown { hidden.remove(provider) } else { hidden.insert(provider) }
    }
}

// MARK: - Impostazioni

/// La sezione Dock delle impostazioni: in cima il Dock com'è adesso, poi cosa metterci e dove, poi i dettagli di ogni
/// modulo acceso.
struct DockPane: View {
    @Bindable private var settings = DockSettings.shared
    private let store = UsageStore.shared
    private let agenda = AgendaStore.shared
    private let charcal = CharcalAgenda.shared
    @State private var trusted = AXIsProcessTrusted()

    var body: some View {
        Form {
            Section {
                DockPreview()
                    .listRowInsets(EdgeInsets())
            }
            Section {
                Toggle("Widget accanto al Dock", isOn: $settings.enabled)
                if settings.enabled {
                    Toggle("Resta visibile quando il Dock si nasconde", isOn: $settings.pinned)
                    if DockHold.available {
                        Toggle("Tieni su il Dock mentre usi un cassetto", isOn: $settings.holdsDock)
                    }
                    Picker("Apertura del cassetto", selection: $settings.liquidDrawer) {
                        Text("Semplice").tag(false)
                        Text("A goccia").tag(true)
                    }
                }
            } footer: {
                Text("Vassoi di vetro alti come il Dock, che salgono e scendono con lui. Passaci sopra per aprire il cassetto.")
            }
            if settings.enabled, !trusted {
                Section {
                    PermissionRow(title: PermissionsPane.accessibilityName,
                                  purpose: String(localized: "Per sapere dov'è il Dock e seguirlo quando si muove."),
                                  granted: false,
                                  link: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
                        _ = AXIsProcessTrustedWithOptions(options)
                    }
                }
            }
            if settings.enabled {
                Section {
                    ForEach(settings.placements) { placement in
                        PlacementRow(placement: placement)
                    }
                    .onMove { from, to in settings.placements.move(fromOffsets: from, toOffset: to) }
                } header: {
                    Text("Nel Dock")
                } footer: {
                    Text("Trascina per cambiare l'ordine: il primo di ogni lato sta accanto al Dock.")
                }
                if settings.isOn(.usage) { usageSection }
                if settings.isOn(.system) { systemSection }
                if settings.isOn(.agenda) { calendarLinkSection }
                if settings.isOn(.dictation) { dictationSection }
            }
        }
        .formStyle(.grouped)
        .task {
            store.refresh(maxAge: UsageStore.glanceAge)
            while !Task.isCancelled {
                trusted = AXIsProcessTrusted()
                agenda.refreshAccess()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    private var usageSection: some View {
        Section {
            ForEach(UsageProviderID.allCases) { provider in
                ProviderRow(provider: provider, found: store.detected.contains(provider),
                            shown: Binding(get: { settings.isShown(provider) }, set: { settings.setShown(provider, $0) }))
            }
            Picker("Nel Dock", selection: $settings.showRemaining) {
                Text("Quanto hai usato").tag(false)
                Text("Quanto resta").tag(true)
            }
            Toggle("Numeri sempre freschi", isOn: $settings.live)
            Toggle("Avvisa nell'isola vicino al limite", isOn: $settings.alerts)
        } header: {
            Text("Agenti AI")
        } footer: {
            Text("Charland non legge le tue credenziali: chiede l'utilizzo ai comandi di Claude e di Codex già installati sul Mac, che rispondono senza consumare token. Tocca il quadratino accanto a un agente per mettere il simbolo che preferisci; Charland non contiene i loghi di Anthropic e di OpenAI.")
        }
    }

    private var systemSection: some View {
        Section {
            ForEach(SystemStats.Metric.allCases) { metric in
                Toggle(isOn: Binding(get: { settings.systemMetrics.contains(metric) },
                                     set: { on in
                                         if on { settings.systemMetrics.insert(metric) } else { settings.systemMetrics.remove(metric) }
                                     })) {
                    Label(metric.title, systemImage: metric.symbol)
                }
            }
        } header: {
            Text("Sistema")
        } footer: {
            Text("Letti dal Mac, niente esce. Tocca un anello nel Dock per scegliere quale numero scrivere accanto.")
        }
    }

    /// Il prossimo impegno legge dal Calendario del Mac e da Charcal, che si collegano in Impostazioni › Calendario (prima
    /// stavano qui, visibili solo a vassoio acceso). Qui resta da dove legge e la strada per cambiarlo.
    private var calendarLinkSection: some View {
        Section {
            LabeledContent {
                Button("Calendario…") { SettingsNavigation.shared.section = .calendar }
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Legge da")
                    Text(verbatim: sources).font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("Prossimo impegno")
        }
    }

    private var sources: String {
        var list: [String] = []
        if agenda.usingCalendar { list.append(String(localized: "Calendario del Mac")) }
        if charcal.connected { list.append("Charcal") }
        return list.isEmpty ? String(localized: "Niente di collegato") : ListFormatter.localizedString(byJoining: list)
    }

    private var dictationSection: some View {
        Section {
            Toggle("Mostra il testo delle ultime dettature", isOn: $settings.dictationShowText)
        } header: {
            Text("Dettatura")
        } footer: {
            Text("Un clic sul vassoio comincia a dettare a mani libere nel campo dove stai scrivendo, un altro clic scrive. Nel cassetto le parole di oggi, il tempo risparmiato e le ultime dettature: un clic le copia.")
        }
    }
}

/// Un modulo nell'elenco «Nel Dock»: il suo simbolo, cosa fa, da che parte, acceso o spento.
private struct PlacementRow: View {
    let placement: DockPlacement
    private let settings = DockSettings.shared

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: placement.id.symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 26, height: 26)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(placement.id.tint.gradient))
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: placement.id.title).font(.system(size: 13, weight: .medium))
                Text(verbatim: placement.id.detail).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            Picker("Lato", selection: Binding(get: { placement.side }, set: { settings.setSide(placement.id, $0) })) {
                ForEach(DockSide.allCases) { side in Text(side.title).tag(side) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .disabled(!placement.shown)
            Toggle("", isOn: Binding(get: { placement.shown }, set: { settings.setShown(placement.id, $0) }))
                .labelsHidden()
        }
        .contextMenu {
            Button("Sposta prima") { move(-1) }
            Button("Sposta dopo") { move(1) }
        }
    }

    /// Prima o dopo fra quelli dello stesso lato: l'ordine conta lato per lato.
    private func move(_ step: Int) {
        let list = settings.placements
        guard let index = list.firstIndex(where: { $0.id == placement.id }) else { return }
        var target = index + step
        while list.indices.contains(target), list[target].side != placement.side { target += step }
        guard list.indices.contains(target) else { return }
        settings.placements.swapAt(index, target)
    }
}

private struct ProviderRow: View {
    let provider: UsageProviderID
    let found: Bool
    @Binding var shown: Bool
    private let marks = AgentMarks.shared
    @State private var targeted = false

    var body: some View {
        HStack(spacing: 10) {
            well
            VStack(alignment: .leading, spacing: 2) {
                Text(provider.title).font(.system(size: 14, weight: .medium))
                if !found {
                    Text(provider.missingHint).font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Toggle("", isOn: found ? $shown : .constant(false)).labelsHidden().disabled(!found)
        }
    }

    /// Il segno dell'agente: un clic per scegliere un'immagine, o trascinala qui. Senza, la mascotte di Charland.
    private var well: some View {
        let custom = marks.mark(for: provider) != nil
        return Button(action: choose) {
            ZStack {
                Circle().fill(Color.black.opacity(0.85))
                Circle().stroke(targeted ? Color.accentColor : .white.opacity(0.18), lineWidth: targeted ? 2 : 1)
                AgentMarkView(provider: provider, size: 16)
            }
            .frame(width: 32, height: 32)
            .overlay(alignment: .topTrailing) {
                if custom {
                    Button { marks.remove(provider) } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 12))
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, .gray)
                    }
                    .buttonStyle(.plain)
                    .offset(x: 4, y: -4)
                    .help(String(localized: "Torna alla mascotte"))
                }
            }
        }
        .buttonStyle(.plain)
        .opacity(found ? 1 : 0.5)
        .help(String(localized: "Scegli il simbolo di \(provider.title), o trascina qui un'immagine"))
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first else { return false }
            return marks.set(url, for: provider)
        } isTargeted: { targeted = $0 }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = AgentMarks.types
        panel.allowsMultipleSelection = false
        panel.message = String(localized: "Scegli il simbolo di \(provider.title)")
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            MainActor.assumeIsolated { _ = AgentMarks.shared.set(url, for: provider) }
        }
    }
}

/// Il Dock dentro le impostazioni: gli stessi vassoi, con i dati veri, ai due lati di un Dock finto.
struct DockPreview: View {
    private let settings = DockSettings.shared

    var body: some View {
        let height: CGFloat = 49
        let now = Date()
        GeometryReader { geo in
            let left = platters(.left, height: height, now: now)
            let right = platters(.right, height: height, now: now)
            let dockWidth: CGFloat = 5 * 33 + 4 * 6 + 16
            let total = left.width + right.width + dockWidth + 32
            ZStack {
                LinearGradient(colors: [Color(red: 0.10, green: 0.11, blue: 0.16), Color(red: 0.19, green: 0.15, blue: 0.24)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                HStack(spacing: 8) {
                    left.view
                    // Un pezzo di Dock finto, per dare la misura.
                    HStack(spacing: 6) {
                        ForEach(0..<5, id: \.self) { _ in
                            RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.white.opacity(0.16)).frame(width: 33, height: 33)
                        }
                    }
                    .padding(.horizontal, 8)
                    .frame(height: height)
                    .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(.white.opacity(0.10)))
                    .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(.white.opacity(0.14), lineWidth: 1))
                    right.view
                }
                // Alla sua misura vera e poi rimpicciolito per starci: senza, l'eccesso usciva tutto da una parte.
                .fixedSize()
                .scaleEffect(min(1, geo.size.width / max(1, total)))
                .frame(width: geo.size.width, height: geo.size.height)
                .opacity(settings.enabled ? 1 : 0.35)
                .animation(.spring(response: 0.4, dampingFraction: 0.82), value: settings.placements)
            }
        }
        .frame(height: 120)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .environment(\.colorScheme, .dark)
    }

    /// I vassoi di un lato, dal Dock verso fuori (a sinistra quindi al contrario).
    private func platters(_ side: DockSide, height: CGFloat, now: Date) -> (view: AnyView, width: CGFloat) {
        let ids = settings.modules(on: side).filter { DockBar.shared.module($0)?.isEmpty == false }
        let layouts = ids.compactMap { id in
            DockBar.shared.module(id).map { (id, DockRowLayout(cells: $0.cells(height: height, now: now), height: height)) }
        }
        let ordered = side == .left ? Array(layouts.reversed()) : layouts
        // Ogni vassoio più lo spazio che lo separa dal vicino (o dal Dock).
        let width = layouts.reduce(0) { $0 + $1.1.width + 8 }
        let view = HStack(spacing: 8) {
            ForEach(ordered, id: \.0) { id, layout in
                DockModulePlatter(id: id, layout: layout, hovered: nil, now: now)
                    .background(Capsule().fill(.black.opacity(0.5)))
                    .overlay(Capsule().stroke(.white.opacity(0.18), lineWidth: 1))
                    .transition(.scale(scale: 0.8).combined(with: .opacity))
            }
        }
        return (AnyView(view), width)
    }
}
