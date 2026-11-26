import SwiftUI

/// Il righello della giornata (carpa, 23 novembre 2026: «una sorta di righello che si può attivare o meno, che
/// rappresenta le ore del giorno attuale: andando col cursore tutto a sinistra al centro esce fuori, collegato al
/// calendario o a Charcal, e lì vedi tutta la giornata direttamente dal desktop», «un'impostazione così che si possa un
/// po' customizzare, attivare, disattivare»).

/// Da che parte dello schermo esce.
enum RulerSide: String, CaseIterable, Identifiable {
    case left, right
    var id: String { rawValue }
    var title: LocalizedStringKey { self == .left ? "Sinistra" : "Destra" }
}

/// Quanto è alto da aperto, rispetto allo schermo.
enum RulerHeight: String, CaseIterable, Identifiable {
    case compact, medium, tall
    var id: String { rawValue }
    var title: LocalizedStringKey {
        switch self {
        case .compact: "Bassa"
        case .medium: "Media"
        case .tall: "Alta"
        }
    }
    var fraction: CGFloat {
        switch self {
        case .compact: 0.5
        case .medium: 0.66
        case .tall: 0.82
        }
    }
}

/// Quanto tenere il puntatore sul bordo prima che esca: più lungo, meno aperture per sbaglio.
enum RulerDelay: String, CaseIterable, Identifiable {
    case quick, moment, long
    var id: String { rawValue }
    var title: LocalizedStringKey {
        switch self {
        case .quick: "Subito"
        case .moment: "Dopo un attimo"
        case .long: "Dopo mezzo secondo"
        }
    }
    var seconds: Double {
        switch self {
        case .quick: 0.12
        case .moment: 0.3
        case .long: 0.55
        }
    }
}

@MainActor @Observable
final class RulerSettings {
    static let shared = RulerSettings()

    /// Acceso di serie: non prende tasti e non cambia niente del Mac, esce solo spingendo il puntatore contro il bordo.
    var enabled: Bool { didSet { guard ready else { return }; save(enabled, "rulerEnabled"); DayRuler.shared.apply() } }
    var side: RulerSide { didSet { guard ready else { return }; save(side.rawValue, "rulerSide"); DayRuler.shared.layoutChanged() } }
    var height: RulerHeight { didSet { guard ready else { return }; save(height.rawValue, "rulerHeight"); DayRuler.shared.layoutChanged() } }
    var delay: RulerDelay { didSet { guard ready else { return }; save(delay.rawValue, "rulerDelay") } }
    /// Da chiuso, la tacca sottile sul bordo (come il notch girato di lato). Spenta, sul bordo non c'è niente finché non
    /// ci arrivi col puntatore.
    var tabVisible: Bool { didSet { guard ready else { return }; save(tabVisible, "rulerTab"); DayRuler.shared.layoutChanged() } }
    /// Le ore che mostra sempre. Un impegno fuori da queste ore (o l'ora di adesso) allarga il righello da solo.
    var startHour: Int { didSet { guard ready else { return }; save(startHour, "rulerStartHour"); DayRuler.shared.contentChanged() } }
    var endHour: Int { didSet { guard ready else { return }; save(endHour, "rulerEndHour"); DayRuler.shared.contentChanged() } }
    /// Cosa mostra. Le fonti vere (Calendario collegato, Charcal col token) si scelgono in Impostazioni › Calendario.
    var calendarEvents: Bool { didSet { guard ready else { return }; save(calendarEvents, "rulerCalendar"); DayRulerStore.shared.sourcesChanged() } }
    var charcalTasks: Bool { didSet { guard ready else { return }; save(charcalTasks, "rulerCharcal"); DayRulerStore.shared.sourcesChanged() } }
    /// Le cose di Charcal già fatte oggi, spuntate e sbiadite al loro posto.
    var doneTasks: Bool { didSet { guard ready else { return }; save(doneTasks, "rulerDone"); DayRulerStore.shared.sourcesChanged() } }
    /// Gli eventi di tutto il giorno e le cose senza ora, in una fila sopra le ore.
    var allDay: Bool { didSet { guard ready else { return }; save(allDay, "rulerAllDay"); DayRulerStore.shared.sourcesChanged() } }

    static let startRange = 0...12
    static let endRange = 13...24

    /// Con `@Observable` i `didSet` scattano anche dentro `init`: lì non devono salvare né riaccendere niente.
    @ObservationIgnored private var ready = false

    private init() {
        let d = UserDefaults.standard
        enabled = d.object(forKey: "rulerEnabled") as? Bool ?? true
        side = RulerSide(rawValue: d.string(forKey: "rulerSide") ?? "") ?? .left
        height = RulerHeight(rawValue: d.string(forKey: "rulerHeight") ?? "") ?? .tall
        delay = RulerDelay(rawValue: d.string(forKey: "rulerDelay") ?? "") ?? .quick
        tabVisible = d.object(forKey: "rulerTab") as? Bool ?? true
        startHour = min(Self.startRange.upperBound, max(Self.startRange.lowerBound, d.object(forKey: "rulerStartHour") as? Int ?? 7))
        endHour = min(Self.endRange.upperBound, max(Self.endRange.lowerBound, d.object(forKey: "rulerEndHour") as? Int ?? 24))
        calendarEvents = d.object(forKey: "rulerCalendar") as? Bool ?? true
        charcalTasks = d.object(forKey: "rulerCharcal") as? Bool ?? true
        doneTasks = d.object(forKey: "rulerDone") as? Bool ?? true
        allDay = d.object(forKey: "rulerAllDay") as? Bool ?? true
        ready = true
    }

    private func save(_ value: Any, _ key: String) { UserDefaults.standard.set(value, forKey: key) }

    /// L'ora scritta come nel menu delle impostazioni: «7:00», «24:00» (mezzanotte a fine giornata).
    static func hourTitle(_ hour: Int) -> String {
        hour == 24 ? String(localized: "Mezzanotte") : String(format: "%d:00", hour)
    }
}

/// Impostazioni › Righello.
struct RulerPane: View {
    @Bindable private var settings = RulerSettings.shared
    @Bindable private var dock = DockSettings.shared
    private let agenda = AgendaStore.shared
    private let charcal = CharcalAgenda.shared

    var body: some View {
        Form {
            Section {
                Toggle("Righello della giornata sul bordo", isOn: $settings.enabled)
            } footer: {
                Text("Spingi il puntatore contro il bordo dello schermo, a metà altezza: esce un righello con le ore di oggi, gli eventi del Calendario e le cose da fare di Charcal al loro posto, e una linea sull'ora di adesso. Togli il puntatore e rientra. Un clic su un impegno apre il Calendario, Charcal o la riunione che sta per cominciare.")
            }
            Group {
                Section {
                    Picker("Lato", selection: $settings.side) {
                        ForEach(RulerSide.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    Picker("Altezza", selection: $settings.height) {
                        ForEach(RulerHeight.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    Picker("Si apre", selection: $settings.delay) {
                        ForEach(RulerDelay.allCases) { Text($0.title).tag($0) }
                    }
                    Toggle("Tacca sul bordo quando è chiuso", isOn: $settings.tabVisible)
                } header: {
                    Text("Dove e come")
                } footer: {
                    Text("Senza la tacca il bordo resta pulito: il righello esce lo stesso, nello stesso punto. Se il puntatore si ferma spesso sul bordo per sbaglio, fallo aprire dopo un attimo.")
                }
                Section {
                    Picker("Dalle", selection: $settings.startHour) {
                        ForEach(Array(RulerSettings.startRange), id: \.self) { Text(verbatim: RulerSettings.hourTitle($0)).tag($0) }
                    }
                    Picker("Alle", selection: $settings.endHour) {
                        ForEach(Array(RulerSettings.endRange), id: \.self) { Text(verbatim: RulerSettings.hourTitle($0)).tag($0) }
                    }
                } header: {
                    Text("Ore")
                } footer: {
                    Text("Un impegno prima o dopo queste ore, o l'ora di adesso, allarga il righello da solo.")
                }
                Section {
                    Toggle(isOn: $settings.calendarEvents) {
                        sourceLabel(String(localized: "Eventi del Calendario"), status: calendarStatus)
                    }
                    Toggle(isOn: $settings.charcalTasks) {
                        sourceLabel(String(localized: "Cose da fare di Charcal"), status: charcal.connected ? nil : String(localized: "Non collegato"))
                    }
                    Toggle("Anche le cose già fatte", isOn: $settings.doneTasks)
                        .disabled(!settings.charcalTasks)
                    Toggle("Tutto il giorno e senza ora, in alto", isOn: $settings.allDay)
                    LabeledContent {
                        Button("Calendario…") { SettingsNavigation.shared.section = .calendar }
                    } label: {
                        Text("Fonti e calendari")
                    }
                } header: {
                    Text("Cosa mostra")
                } footer: {
                    Text("Il Calendario, i calendari da guardare e il token di Charcal si scelgono in Impostazioni › Calendario: valgono anche per il Dock e il blocco schermo. Le cose fatte sono quelle di Charcal spuntate oggi.")
                }
                Section {
                    LabeledContent {
                        Button("Mostra") { DayRuler.shared.preview() }
                    } label: {
                        Text("Prova il righello")
                    }
                } footer: {
                    Text("Esce sullo schermo di questa finestra e rientra da solo dopo qualche secondo, se non ci vai sopra.")
                }
            }
            .disabled(!settings.enabled)
        }
        .formStyle(.grouped)
        .task { agenda.refreshAccess() }
    }

    private var calendarStatus: String? {
        switch agenda.access {
        case .granted: dock.agendaCalendarOn ? nil : String(localized: "Scollegato")
        case .unknown: String(localized: "Non collegato")
        case .denied: String(localized: "Permesso negato")
        }
    }

    private func sourceLabel(_ title: String, status: String?) -> some View {
        HStack(spacing: 8) {
            Text(verbatim: title)
            if let status { Text(verbatim: status).foregroundStyle(.secondary) }
        }
    }
}
