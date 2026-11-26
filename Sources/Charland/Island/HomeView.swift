import SwiftUI
import IOKit.ps
import CharlandCore

/// La casa: quello che si apre passando sopra il notch quando non c'è nessuna attività.
/// Ai lati della fotocamera il meteo e Mantieni attivo (la tazzina); sotto, Detta, Timer, Musica e Impostazioni.
enum Home {
    static let activity = activity(trayRow: false, pills: false)

    /// La casa è più alta quando mostra anche le attività in corso e la fila del vassoio.
    static func activity(trayRow: Bool, pills: Bool) -> IslandActivity {
        IslandActivity(id: IslandState.homeID, priority: -10, leadingWidth: 54, trailingWidth: 56,
                       expandedWidth: 340, expandedHeight: 78 + (trayRow ? 78 : 0) + (pills ? 42 : 0), allowsMinimal: false)
    }

    /// La casa giusta per adesso: con le attività in corso, e con la fila del vassoio se ci sono
    /// file o se un file sta arrivando.
    @MainActor
    static var current: IslandActivity {
        let tray = TrayStore.shared
        let pills = !(IslandHub.shared.primary?.engine.state.activities.isEmpty ?? true)
        return activity(trayRow: (Features.shared.tray && !tray.isEmpty) || tray.dropping, pills: pills)
    }

    enum Action: String {
        case dictate, paste, settings, timer, awake, music, weather
    }

    /// Quale fila di scelte è aperta nella casa.
    enum Panel: Equatable { case none, timer, awake }

    /// Cosa fanno i pulsanti della casa.
    @MainActor
    static func perform(_ action: String) {
        switch Action(rawValue: action) {
        case .dictate?:
            DictationController.shared.startHandsFreeFromIsland()
        case .paste?:
            IslandHub.shared.primary?.engine.send(.collapse)
            DictationController.shared.repeatLast()
        case .settings?:
            IslandHub.shared.primary?.engine.send(.collapse)
            AppServices.shared.showSettings()
        case .timer?:
            HomeUI.shared.panel = HomeUI.shared.panel == .timer ? .none : .timer
        case .awake?:
            if KeepAwake.shared.active {
                KeepAwake.shared.stop()
            } else {
                HomeUI.shared.panel = HomeUI.shared.panel == .awake ? .none : .awake
            }
        case .music?:
            HomeUI.shared.panel = .none
            NowPlayingMonitor.shared.openInIsland()
        case .weather?:
            IslandHub.shared.primary?.engine.send(.collapse)
            WeatherStore.shared.openFromIsland()
        case nil:
            if action.hasPrefix("open:") {
                // Una pillola: apre quell'attività.
                IslandHub.shared.primary?.engine.send(.expand(id: String(action.dropFirst(5))))
            } else if action.hasPrefix("timer:"), let seconds = Double(action.dropFirst(6)) {
                HomeUI.shared.panel = .none
                IslandHub.shared.primary?.engine.send(.collapse)
                TimerCenter.shared.start(seconds: seconds)
            } else if action == "awake-agents" {
                HomeUI.shared.panel = .none
                IslandHub.shared.primary?.engine.send(.collapse)
                KeepAwake.shared.startUntilAgentsDone()
            } else if action.hasPrefix("awake:") {
                HomeUI.shared.panel = .none
                IslandHub.shared.primary?.engine.send(.collapse)
                let value = Double(action.dropFirst(6)) ?? 0
                KeepAwake.shared.start(duration: value > 0 ? value : nil)
            }
        }
    }
}

/// Lo stato della casa che non dura: quale fila di scelte è aperta. Si chiude con l'isola.
@MainActor @Observable
final class HomeUI {
    static let shared = HomeUI()
    var panel: Home.Panel = .none
}

enum HomeLegacy {
    static func unused() {}
}

/// Un'attività in corso, come pillola in cima alla casa.
struct HomePill: Equatable, Identifiable {
    let id: String
    let content: ActivityContent
}

struct HomeInfo: Equatable {
    var date: Date
    var battery: Int?
    var charging: Bool
    /// Risparmio energetico acceso: la batteria è gialla, come su iPhone.
    var lowPower = false
    var hasLastDictation: Bool
    var pills: [HomePill] = []

    /// L'ultima lettura della batteria, aggiornata da `BatteryMonitor` quando il sistema avvisa. Leggerla da IOKit a
    /// ogni apertura costava tempo sul thread principale proprio prima del primo fotogramma.
    @MainActor static var cachedPower: (level: Int, charging: Bool)?

    @MainActor
    static func now() -> HomeInfo {
        // La casa si apre: il meteo in alto a sinistra si richiede se è vecchio (in sottofondo, la casa non aspetta).
        WeatherStore.shared.ensureFresh()
        let power = cachedPower ?? Self.power()
        var pills: [HomePill] = []
        if let engine = IslandHub.shared.primary?.engine {
            for activity in engine.state.activities.prefix(3) {
                if let content = engine.model.contents[activity.id] { pills.append(HomePill(id: activity.id, content: content)) }
            }
        }
        // Il giorno, non l'istante: si mostra solo quello, e così una casa uguale resta uguale (niente ridisegni).
        return HomeInfo(date: Calendar.current.startOfDay(for: Date()), battery: power?.level, charging: power?.charging ?? false,
                        lowPower: ProcessInfo.processInfo.isLowPowerModeEnabled,
                        hasLastDictation: DictationController.shared.history.first != nil, pills: pills)
    }

    /// Batteria interna, se c'è.
    static func power() -> (level: Int, charging: Bool)? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for source in list {
            guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                  let current = description[kIOPSCurrentCapacityKey] as? Int,
                  let maximum = description[kIOPSMaxCapacityKey] as? Int, maximum > 0 else { continue }
            let charging = (description[kIOPSIsChargingKey] as? Bool) ?? false
            return (Int((Double(current) / Double(maximum) * 100).rounded()), charging)
        }
        return nil
    }
}

struct HomeSlotView: View {
    let info: HomeInfo
    let slot: ContentSlot
    let act: (String) -> Void

    var body: some View {
        switch slot {
        case .leading:
            WeatherCorner(act: act)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .trailing:
            // Mantieni attivo, al posto della batteria che macOS mostra già nella barra dei menu (carpa, 18 novembre 2026).
            // Un clic apre le scelte sotto; acceso, lo spegne.
            AwakeCorner { act(Home.Action.awake.rawValue) }
                .frame(maxWidth: .infinity, alignment: .trailing)
        case .expanded:
            HomeExpanded(info: info, tray: TrayStore.shared, act: act)
        default:
            EmptyView()
        }
    }

    static func batterySymbol(_ level: Int, charging: Bool) -> String {
        Self.symbolFor(level, charging: charging)
    }

    static func symbolFor(_ level: Int, charging: Bool) -> String {
        if charging { return "battery.100percent.bolt" }
        switch level {
        case ..<13: return "battery.0percent"
        case ..<38: return "battery.25percent"
        case ..<63: return "battery.50percent"
        case ..<88: return "battery.75percent"
        default: return "battery.100percent"
        }
    }
}

/// La casa aperta: sopra la fila del vassoio (se ci sono file), sotto i tre pulsanti.
/// Mentre trascini un file sopra l'isola, al posto dei pulsanti c'è la zona dove lasciarlo.
struct HomeExpanded: View {
    let info: HomeInfo
    let tray: TrayStore
    let act: (String) -> Void
    private var ui: HomeUI { .shared }
    private var awake: KeepAwake { .shared }

    var body: some View {
        VStack(spacing: 8) {
            if !info.pills.isEmpty {
                HStack(spacing: 8) {
                    ForEach(info.pills) { pill in
                        ActivityPill(pill: pill) { act("open:\(pill.id)") }
                    }
                }
                .frame(height: 34)
                .transition(.blurReplace)
            }
            if Features.shared.tray, !tray.isEmpty {
                TrayRow(store: tray)
                    .transition(.blurReplace)
            }
            Group {
                if tray.dropping {
                    TrayDropZones(zone: tray.zone, tall: tray.isEmpty)
                        .frame(height: tray.isEmpty ? 140 : 66)
                        .transition(.blurReplace)
                } else {
                    switch ui.panel {
                    case .timer: timerChoices
                    case .awake: awakeChoices
                    case .none: tiles
                    }
                }
            }
            .frame(height: tray.dropping && tray.isEmpty ? 140 : 66)
            .animation(.spring(response: 0.3, dampingFraction: 0.86), value: ui.panel)
            .animation(.spring(response: 0.32, dampingFraction: 0.86), value: tray.dropping)
        }
        .padding(.top, 6)
        // Una fila che arriva o se ne va (pillole, vassoio) sposta le altre con la stessa molla del bordo dell'isola:
        // prima le tessere saltavano subito al posto nuovo mentre il bordo era ancora a metà, e venivano tagliate.
        .animation(.spring(response: 0.42 * Appearance.shared.calm, dampingFraction: 0.82), value: info.pills.count)
        .animation(.spring(response: 0.42 * Appearance.shared.calm, dampingFraction: 0.82), value: tray.isEmpty)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private var tiles: some View {
        HStack(spacing: 8) {
            HomeTile(symbol: nil, title: String(localized: "Detta")) { act(Home.Action.dictate.rawValue) }
            HomeTile(symbol: "timer", title: String(localized: "Timer")) { act(Home.Action.timer.rawValue) }
            // La riproduzione sempre a un clic, al posto di Mantieni attivo (che è salito in alto a destra).
            HomeTile(symbol: "music.note", title: String(localized: "Musica")) { act(Home.Action.music.rawValue) }
            HomeTile(symbol: "gearshape.fill", title: String(localized: "Impostazioni")) { act(Home.Action.settings.rawValue) }
        }
        .transition(.blurReplace)
    }

    private var timerChoices: some View {
        HStack(spacing: 6) {
            ForEach(TimerCenter.presets, id: \.seconds) { preset in
                ChoiceChip(title: preset.label) { act("timer:\(Int(preset.seconds))") }
            }
            ChoiceChip(symbol: "xmark") { act(Home.Action.timer.rawValue) }
        }
        .transition(.blurReplace)
    }

    private var awakeChoices: some View {
        HStack(spacing: 6) {
            ChoiceChip(title: "30 min") { act("awake:1800") }
            ChoiceChip(title: "1 h") { act("awake:3600") }
            ChoiceChip(title: "2 h") { act("awake:7200") }
            // Senza scadenza: il segno dell'infinito al posto della parola. Il coperchio chiuso si sceglie in Impostazioni.
            ChoiceChip(symbol: "infinity") { act("awake:0") }
                .help(String(localized: "Sempre"))
                .accessibilityLabel(String(localized: "Sempre"))
            // Finché gli agenti non hanno finito tutto, sotto-agenti compresi: la mascotte batte sui tasti sotto il puntatore.
            ChoiceChip(mascot: true) { act("awake-agents") }
                .help(String(localized: "Finché gli agenti lavorano"))
                .accessibilityLabel(String(localized: "Finché gli agenti lavorano"))
        }
        .transition(.blurReplace)
    }
}

/// Un'attività in corso in cima alla casa: il suo segno e il suo tempo. Un tocco la apre.
struct ActivityPill: View {
    let pill: HomePill
    let open: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: open) {
            HStack(spacing: 8) {
                glyph.frame(width: 30, height: 20)
                detail
            }
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background { GlassPlate(shape: Capsule(), hovered: hovering) }
            .contentShape(Capsule())
        }
        .buttonStyle(TilePress())
        .islandHover($hovering)
    }

    @ViewBuilder private var glyph: some View {
        switch pill.content {
        case .agents(let info):
            if let face = info.face {
                // al lavoro anche qui: aprendo l'isola la mascotte continua a battere sulla tastiera
                AgentMascot(palette: face.palette, shape: face.shape, working: info.lead != nil, pixel: 1)
            }
        case .api(let c):
            Image(systemName: c.symbol).font(.system(size: 13, weight: .semibold)).inked(c.tint)
        case .music(let m):
            Artwork(info: m, corner: 5).frame(width: 20, height: 20)
        case .timer:
            Image(systemName: "timer").font(.system(size: 13, weight: .semibold)).inked(.orange)
        default:
            Image(systemName: "circle.fill").font(.system(size: 6)).foregroundStyle(.white.opacity(0.5))
        }
    }

    @ViewBuilder private var detail: some View {
        Group {
            switch pill.content {
            case .agents(let info):
                if info.ask != nil { Text("Ti aspetta") } else if let lead = info.lead { TurnTimer(start: lead.since) } else { Text("Fatto") }
            case .api(let c):
                if c.template == .countdown, let end = c.endsAt {
                    LiveCountdown(end: end).inked(c.tint)
                } else if c.recording, let start = c.startedAt {
                    TurnTimer(start: start)
                } else if c.template == .progress {
                    Text("\(Int(c.progress * 100))%")
                } else {
                    Text(c.title).lineLimit(1)
                }
            case .music(let m):
                Text(m.title).lineLimit(1)
            case .timer(let t):
                LiveCountdown(end: t.end).inked(.orange)
            default:
                EmptyView()
            }
        }
        .font(.system(size: 13, weight: .semibold, design: .rounded))
        .monospacedDigit()
        .foregroundStyle(.white)
        .lineLimit(1)
    }
}

/// Una scelta della casa: un tempo o un simbolo, con lo stesso raggio delle tessere.
struct ChoiceChip: View {
    var title: String? = nil
    var symbol: String? = nil
    /// La mascotte di Claude al posto della parola: «finché gli agenti lavorano».
    var mascot = false
    var highlighted = false
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Group {
                if let title {
                    Text(title).font(.system(size: 13, weight: .semibold, design: .rounded)).lineLimit(1).minimumScaleFactor(0.8)
                } else if let symbol {
                    Image(systemName: symbol).font(.system(size: 14, weight: .semibold))
                } else if mascot {
                    AgentMascot(palette: AgentKind.claude.palette, shape: AgentKind.claude.shape, working: hovering, pixel: 1)
                }
            }
            .foregroundStyle(highlighted ? Color.black : .white)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background {
                GlassPlate(shape: RoundedRectangle(cornerRadius: 16, style: .continuous), hovered: hovering, highlighted: highlighted)
                    .animation(.spring(response: 0.3, dampingFraction: 0.86), value: highlighted)
            }
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(TilePress())
        .islandHover($hovering)
    }
}

/// Un pulsante della casa. Raggio 16: è il raggio dell'isola aperta (30) meno l'aria ai lati (14).
/// Mantieni attivo nell'angolo in alto a destra della casa: la tazzina, piena e bianca quando è acceso.
struct AwakeCorner: View {
    let action: () -> Void
    @State private var hovering = false
    private var awake: KeepAwake { .shared }

    var body: some View {
        Button(action: action) {
            Image(systemName: awake.active ? "cup.and.saucer.fill" : "cup.and.saucer")
                .font(.system(size: 13, weight: .semibold))
                .contentTransition(.symbolEffect(.replace))
                .foregroundStyle(awake.active ? Color.black : .white)
                .frame(width: 30, height: 24)
                .background {
                    Capsule().fill(awake.active ? Color.white : Color.white.opacity(hovering ? 0.17 : 0))
                        .animation(.hover(hovering), value: hovering)
                        .animation(.spring(response: 0.3, dampingFraction: 0.86), value: awake.active)
                }
                .contentShape(Capsule())
        }
        .buttonStyle(TilePress())
        .islandHover($hovering, name: "awake")
        .help(String(localized: "Mantieni attivo"))
        .accessibilityLabel(String(localized: "Mantieni attivo"))
    }
}

/// Un simbolo da premere ai lati della fotocamera (la nota della musica, il meteo): come la tazzina, una capsula che si
/// accende al passaggio.
struct CornerButton: View {
    let symbol: String
    var multicolor = false
    var dim = false
    var help: String = ""
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .symbolRenderingMode(multicolor && !Glassy.on ? .multicolor : .monochrome)
                .contentTransition(.symbolEffect(.replace))
                .foregroundStyle(Glassy.on && !dim ? Glassy.ink : AnyShapeStyle(.white.opacity(dim ? 0.45 : 1)))
                .frame(width: 30, height: 24)
                .background {
                    Capsule().fill(Color.white.opacity(hovering ? 0.17 : 0))
                        .animation(.hover(hovering), value: hovering)
                }
                .contentShape(Capsule())
        }
        .buttonStyle(TilePress())
        .islandHover($hovering, name: symbol)
        .help(help)
        .accessibilityLabel(help)
    }
}

/// Il meteo nell'angolo in alto a sinistra della casa, al posto del giorno (carpa, 18 novembre 2026: «non la data ma il
/// simbolino del meteo, tipo sole pioggia»). Un clic apre Meteo; senza una città scelta apre la scelta in Impostazioni.
struct WeatherCorner: View {
    let act: (String) -> Void
    private var weather: WeatherStore { .shared }

    var body: some View {
        let now = weather.current
        CornerButton(symbol: now?.symbol ?? "cloud.sun.fill", multicolor: now != nil && weather.colored, dim: now == nil,
                     help: weather.summary) {
            act(Home.Action.weather.rawValue)
        }
    }
}

struct HomeTile: View {
    /// `nil` è il segno della dettatura di Charcal.
    let symbol: String?
    let title: String
    var enabled = true
    /// Acceso (mantieni attivo in corso): tessera bianca, simbolo nero.
    var highlighted = false
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                if let symbol {
                    Image(systemName: symbol).font(.system(size: 17, weight: .semibold)).frame(height: 22)
                } else {
                    VoiceGlyph(size: 24, weight: 1.2).frame(height: 22)
                }
                Text(title).font(.system(size: 12, weight: .semibold)).lineLimit(1)
            }
            .foregroundStyle(highlighted ? Color.black : .white.opacity(enabled ? 1 : 0.35))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // Un fondo scuro leggero sotto il chiaro: la tessera porta il suo contrasto anche sul vetro.
            .background {
                GlassPlate(shape: RoundedRectangle(cornerRadius: 16, style: .continuous), hovered: hovering && enabled,
                           highlighted: highlighted)
                    .animation(.spring(response: 0.3, dampingFraction: 0.86), value: highlighted)
            }
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(TilePress())
        .disabled(!enabled)
        .islandHover($hovering, name: title)
    }
}

extension Animation {
    /// L'hover: si accende quasi subito, si spegne un filo più morbido.
    static func hover(_ on: Bool) -> Animation { on ? .easeOut(duration: 0.1) : .easeOut(duration: 0.24) }
}

/// Un numero per ogni pulsante con l'hover: crescono, quindi il più recente è il più alto.
@MainActor
enum IslandHoverID {
    private static var last = 0
    static func next() -> Int { last += 1; return last }
}

extension View {
    /// L'hover di un pulsante dell'isola, deciso dal puntatore vero (vedi `IslandModel.hovered`).
    /// Fuori dall'isola (anteprime nelle impostazioni) resta l'hover di SwiftUI.
    /// `outset` allarga il riquadro per chi ha pezzi che sporgono (la x delle schede del vassoio).
    func islandHover(_ hovering: Binding<Bool>, name: String = "", outset: CGFloat = 0) -> some View {
        modifier(IslandHover(hovering: hovering, name: name, outset: outset))
    }
}

extension EnvironmentValues {
    /// Il contenuto si può toccare: aperto e comparso almeno a metà. Quello che sta sfumando non accende l'hover.
    @Entry var islandInteractive = true
    /// Il contenuto si vede (anche solo un poco). I tempi che scorrono e le barre che avanzano girano solo allora: le
    /// viste dell'isola restano vive anche nascoste, e ognuna col suo orologio svegliava l'app ogni secondo per niente
    /// (misurato il 18 novembre 2026: sette tempi che scorrevano con uno solo in vista).
    @Entry var islandShown = true
}

/// L'ultimo riquadro misurato, tenuto fuori dallo stato: cambia a ogni fotogramma dell'apertura e non deve ridisegnare.
final class HoverRect {
    var rect: CGRect?
}

struct IslandHover: ViewModifier {
    @Binding var hovering: Bool
    let name: String
    var outset: CGFloat = 0
    @Environment(IslandModel.self) private var model: IslandModel?
    @Environment(\.islandInteractive) private var interactive
    @State private var id = IslandHoverID.next()
    @State private var last = HoverRect()

    func body(content: Content) -> some View {
        if let model, model.pointerDriven {
            content
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global).insetBy(dx: -outset, dy: -outset) } action: { rect in
                    last.rect = rect
                    model.setHoverRegion(id, interactive ? rect : nil)
                    HoverTrace.region(name, rect)
                }
                .onChange(of: interactive) { _, now in model.setHoverRegion(id, now ? last.rect : nil) }
                .onDisappear { model.setHoverRegion(id, nil) }
                .onChange(of: model.hovered == id, initial: true) { _, on in
                    hovering = on
                    HoverTrace.change(name, on)
                }
        } else {
            content.onHover { hovering = $0 }
        }
    }
}

/// Con CHARLAND_HOVER scrive quando l'hover cambia e dove stanno i pulsanti: serve a misurare il ritardo.
@MainActor
enum HoverTrace {
    static let on = ProcessInfo.processInfo.environment["CHARLAND_HOVER"] != nil
    static func change(_ name: String, _ inside: Bool) {
        guard on, !name.isEmpty else { return }
        let p = NSEvent.mouseLocation
        print(String(format: "[hover] %.4f %@ %@ x=%.1f y=%.1f", CACurrentMediaTime(), name, inside ? "on" : "off", p.x, p.y))
        fflush(stdout)
    }
    /// Il centro del pulsante sullo schermo, in coordinate Quartz (origine in alto a sinistra).
    static func region(_ name: String, _ rect: CGRect) {
        guard on, !name.isEmpty, let stage = IslandHub.shared.primary?.geometry.stageFrame else { return }
        let mainHeight = NSScreen.screens.first?.frame.height ?? 0
        print(String(format: "[tessera] %@ %.1f %.1f %.1f %.1f", name, stage.minX + rect.midX,
                     mainHeight - (stage.maxY - rect.midY), rect.width, rect.height))
        fflush(stdout)
    }
}

/// Premendo, il pulsante si schiaccia appena.
struct TilePress: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.95 : 1)
            .animation(.spring(response: 0.22, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

/// Dove vanno le azioni toccate nell'isola: la casa le gestisce da sé, le altre vanno
/// all'attività che le ha mandate.
@MainActor
enum IslandActions {
    static func handle(action: String, activity: String) {
        if action.hasPrefix("music:") {
            switch action {
            case "music:open": NowPlayingMonitor.shared.openApp()
            case "music:launch": NowPlayingMonitor.shared.openMusicApp()
            case "music:front": NowPlayingMonitor.shared.showSource()
            case "music:toggle":
                if NowPlayingMonitor.shared.idle { NowPlayingMonitor.shared.playFromIdle() } else { NowPlayingMonitor.shared.send("toggle") }
            case "music:next": NowPlayingMonitor.shared.send("next")
            case "music:previous": NowPlayingMonitor.shared.send("previous")
            default:
                if action.hasPrefix("music:seek:") { NowPlayingMonitor.shared.send("seek " + action.dropFirst("music:seek:".count)) }
            }
            return
        }
        if activity == IslandState.homeID {
            Home.perform(action)
        } else {
            ActivityCenter.shared.perform(action: action, on: activity)
        }
    }

    static func modeChanged() {
        ActivityCenter.shared.islandModeChanged()
        if let mode = IslandHub.shared.primary?.engine.mode { NowPlayingMonitor.shared.islandModeChanged(mode) }
        if case .expanded(IslandState.homeID)? = IslandHub.shared.primary?.engine.mode {} else {
            HomeUI.shared.panel = .none
        }
    }
}

/// I tocchi sul trackpad dell'isola.
@MainActor
enum IslandHaptics {
    /// L'isola si apre sotto il puntatore: un tocco netto, come un tasto.
    static func open() {
        guard Appearance.shared.haptics else { return }
        NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
    }
}
