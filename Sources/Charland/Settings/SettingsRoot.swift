import SwiftUI
import CharlandCore

/// Le sezioni dell'app, come in Impostazioni di Sistema.
enum SettingsSection: String, CaseIterable, Identifiable {
    case general, appearance, voice, shortcuts, search, sliders, dock, lockScreen, wallpaper, agents, calendar, ruler, tray, clipboard, quitApps, api, permissions, support, about
    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .general: "Generale"
        case .appearance: "Aspetto"
        case .voice: "Voce"
        case .shortcuts: "Scorciatoie"
        case .search: "Ricerca"
        // Una chiave sua: in inglese la barra laterale va in title case come le altre voci («Volume & Brightness»),
        // mentre «Volume e luminosità» negli interruttori resta «Volume and brightness».
        case .sliders: "sezione.volume"
        case .dock: "Dock"
        case .lockScreen: "Blocco schermo"
        case .wallpaper: "Sfondo"
        case .agents: "Agenti"
        case .calendar: "Calendario"
        case .ruler: "Righello"
        case .tray: "Vassoio"
        case .clipboard: "Appunti"
        case .quitApps: "Chiusura app"
        case .api: "API"
        case .permissions: "Permessi"
        case .support: "Supporto"
        case .about: "Informazioni"
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .appearance: "circle.lefthalf.filled"
        case .voice: "waveform"
        case .shortcuts: "command"
        case .search: "magnifyingglass"
        case .sliders: "speaker.wave.2"
        case .dock: "dock.rectangle"
        case .lockScreen: "lock.display"
        case .wallpaper: "hexagon"
        case .agents: "sparkle"
        case .calendar: "calendar"
        case .ruler: "ruler"
        case .tray: "tray"
        case .clipboard: "doc.on.clipboard"
        case .quitApps: "xmark.app"
        case .api: "curlybraces"
        case .permissions: "hand.raised"
        case .support: "lifepreserver"
        case .about: "info.circle"
        }
    }
}

struct SettingsRoot: View {
    @Bindable private var navigation = SettingsNavigation.shared

    var body: some View {
        let section = navigation.section
        NavigationSplitView {
            List(SettingsSection.allCases, selection: $navigation.section) { item in
                Label(item.title, systemImage: item.symbol).tag(item)
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 210, max: 240)
        } detail: {
            Group {
                switch section ?? .appearance {
                case .general: GeneralPane()
                case .appearance: AppearancePane()
                case .voice: VoicePane()
                case .shortcuts: ShortcutsPane()
                case .search: SearchPane()
                case .dock: DockPane()
                case .lockScreen: LockScreenPane()
                case .wallpaper: WallpaperPane()
                case .agents: AgentsPane()
                case .calendar: CalendarPane()
                case .ruler: RulerPane()
                case .sliders: SlidersPane()
                case .tray: TrayPane()
                case .clipboard: ClipboardPane()
                case .quitApps: QuitAppsPane()
                case .api: APIPane()
                case .permissions: PermissionsPane()
                case .support: SupportPane()
                case .about: AboutPane()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        // Al primo avvio la scelta della città del meteo.
        .modifier(WeatherSetupPresenter())
    }
}

