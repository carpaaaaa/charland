import SwiftUI
import AppKit

/// Il modulo dell'utilizzo degli agenti AI: un anello per agente col suo segno al centro, attorno quanto è pieno il
/// limite più vicino, e accanto all'agente scelto il suo numero. Un clic sceglie, la rotella passa all'altro.
@MainActor
final class UsageModule: DockModule {
    let id = DockModuleID.usage
    private var settings: DockSettings { .shared }

    var isEmpty: Bool { settings.providers.isEmpty }

    /// L'agente scelto, se è fra quelli da mostrare; se no il primo.
    var selected: UsageProviderID? {
        let providers = settings.providers
        return providers.contains(settings.selected) ? settings.selected : providers.first
    }

    func cells(height: CGFloat, now: Date) -> [DockCell] {
        let size = max(11, (height * 0.27).rounded())
        let chosen = selected
        return settings.providers.map { provider in
            let text = Self.label(for: UsageStore.shared.snapshots[provider], remaining: settings.showRemaining)
            return DockCell(id: provider.rawValue, label: DockText.width(text, size: size), open: provider == chosen ? 1 : 0)
        }
    }

    var defaultFocus: String? { selected?.rawValue }

    func drawerHeight(focus: String?, now: Date) -> CGFloat {
        guard let provider = focus.flatMap(UsageProviderID.init(rawValue:)) ?? selected else { return 120 }
        return UsageDrawerMetrics.height(provider: provider, snapshot: UsageStore.shared.snapshots[provider], now: now)
    }

    func setActive(_ on: Bool) {
        UsageStore.shared.setAlerts(on && settings.alerts)
        if on {
            UsageDrawerMetrics.refreshApps()
            UsageStore.shared.refresh(maxAge: UsageStore.glanceAge)
        }
    }

    func refresh(look: Bool) {
        UsageDrawerMetrics.refreshApps()
        UsageStore.shared.refresh(maxAge: look ? UsageStore.lookAge : UsageStore.glanceAge)
    }

    func tap(_ cell: String?) {
        guard let provider = cell.flatMap(UsageProviderID.init(rawValue:)), settings.selected != provider else { return }
        Haptics.tick()
        settings.selected = provider
    }

    func scroll(_ step: Int) -> Bool {
        let providers = settings.providers
        guard providers.count > 1, let current = selected, let index = providers.firstIndex(of: current) else { return false }
        tap(providers[(index + step + providers.count) % providers.count].rawValue)
        return true
    }

    /// Il numero nel Dock: la percentuale del limite più vicino, oppure i token di oggi se l'agente non ha percentuali.
    static func label(for snapshot: UsageSnapshot?, remaining: Bool) -> String {
        guard let snapshot else { return "" }
        if let headline = snapshot.headline {
            let used = min(100, max(0, headline.percent))
            return "\(Int((remaining ? 100 - used : used).rounded()))%"
        }
        if let tokens = snapshot.tokensToday { return UsageText.compact(tokens) }
        return ""
    }
}

// MARK: - Vassoio

struct UsagePlatter: View {
    let layout: DockRowLayout
    let hovered: String?
    private let store = UsageStore.shared
    private let settings = DockSettings.shared

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(layout.cells) { cell in
                if let provider = UsageProviderID(rawValue: cell.id) {
                    let snapshot = store.snapshots[provider]
                    let headline = snapshot?.headline
                    let used = min(100, max(0, headline?.percent ?? 0))
                    let text = UsageModule.label(for: snapshot, remaining: settings.showRemaining)
                    DockRing(fraction: headline.map { _ in (settings.showRemaining ? 100 - used : used) / 100 },
                             color: UsageTone.color(used: used), size: layout.ring, hovered: hovered == cell.id) {
                        AgentMarkView(provider: provider, size: (layout.ring * 0.5).rounded())
                            .opacity(headline == nil && snapshot?.tokensToday == nil ? 0.72 : 1)
                    }
                    .offset(x: layout.x(of: cell.id), y: layout.pad)
                    .accessibilityElement()
                    .accessibilityLabel(Text(verbatim: "\(provider.title) \(text)"))
                    DockLabel(text: text, layout: layout, cell: cell.id, color: UsageTone.color(used: used))
                }
            }
        }
    }
}

// MARK: - Cassetto

enum UsageDrawerMetrics {
    static let window: CGFloat = 49
    static let pace: CGFloat = 16
    static let empty: CGFloat = 36

    @MainActor static func height(provider: UsageProviderID, snapshot: UsageSnapshot?, now: Date = Date()) -> CGFloat {
        let m = DockDrawerMetrics.self
        var h = m.pad * 2 + m.header
        let windows = snapshot?.windows ?? []
        if windows.isEmpty {
            h += m.gap + empty
        } else {
            h += m.gap + CGFloat(windows.count) * window + CGFloat(windows.count - 1) * 12
            if paceText(snapshot, now: now) != nil { h += 10 + pace }
        }
        if snapshot?.tokensToday != nil { h += m.gap + m.figure }
        if appURL(provider) != nil { h += m.gap + m.footer }
        return h
    }

    /// La frase sul ritmo, per il limite più vicino: dove arrivi alla ripartenza andando avanti così. Detta come il
    /// resto del cassetto: quanto avrai usato, o quanto ti resterà.
    static func paceText(_ snapshot: UsageSnapshot?, remaining: Bool = false, now: Date = Date()) -> (text: String, warning: Bool)? {
        guard let headline = snapshot?.headline, headline.percent < 100, let projection = headline.projection(at: now) else { return nil }
        if let runsOut = projection.runsOut {
            return (String(localized: "A questo ritmo finisce \(UsageText.moment(runsOut, now: now))"), true)
        }
        let atReset = Int(projection.atReset.rounded())
        return (remaining ? String(localized: "A questo ritmo ti resta il \(100 - atReset)%")
                : String(localized: "A questo ritmo arrivi al \(atReset)%"), false)
    }

    /// L'app di un agente, se è installata: quello che ha trovato l'ultima `refreshApps`. Il disegno e la misura del
    /// cassetto leggono da qui, quindi vedono sempre la stessa risposta.
    @MainActor static func appURL(_ provider: UsageProviderID) -> URL? { apps[provider] ?? nil }

    /// Cerca le app degli agenti. Costa (il sistema va a guardare fra le app): una volta al minuto al massimo, e mai
    /// mentre si disegna.
    @MainActor static func refreshApps() {
        let now = CACurrentMediaTime()
        guard now - appsRead > 60 else { return }
        appsRead = now
        for provider in UsageProviderID.allCases {
            apps[provider] = provider.appBundleIDs.lazy.compactMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }.first
        }
    }

    @MainActor private static var apps: [UsageProviderID: URL?] = [:]
    @MainActor private static var appsRead: CFTimeInterval = -1000
}

/// Il cassetto degli agenti: quello sotto il puntatore, i suoi limiti con la ripartenza e il ritmo, i token di oggi.
/// Niente selettore qui dentro: gli anelli del vassoio sono già la scelta.
struct UsageDrawer: View {
    let focus: String?
    let now: Date
    private let store = UsageStore.shared
    private let settings = DockSettings.shared

    var body: some View {
        let provider = focus.flatMap(UsageProviderID.init(rawValue:)) ?? settings.selected
        let snapshot = store.snapshots[provider]
        let remaining = settings.showRemaining
        let m = DockDrawerMetrics.self
        VStack(alignment: .leading, spacing: 0) {
            DrawerHeader(title: provider.title, chip: snapshot?.plan, busy: store.refreshing.contains(provider)) {
                AgentMarkView(provider: provider, size: 16)
            }
            let windows = snapshot?.windows ?? []
            if windows.isEmpty {
                Text(snapshot == nil ? String(localized: "Leggo i numeri…")
                     : provider == .gemini ? String(localized: "Gemini non scrive sul Mac i limiti del piano.")
                     : String(localized: "Nessun limite da leggere per ora."))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.55))
                    .frame(maxWidth: .infinity, minHeight: UsageDrawerMetrics.empty, maxHeight: UsageDrawerMetrics.empty, alignment: .leading)
                    .padding(.top, m.gap)
            } else {
                VStack(spacing: 12) {
                    ForEach(windows) { window in
                        UsageWindowRow(window: window, remaining: remaining, now: now).frame(height: UsageDrawerMetrics.window)
                    }
                }
                .padding(.top, m.gap)
                if let pace = UsageDrawerMetrics.paceText(snapshot, remaining: remaining, now: now) {
                    Text(pace.text)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(pace.warning ? UsageTone.amberInk : .white.opacity(0.62))
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, minHeight: UsageDrawerMetrics.pace, maxHeight: UsageDrawerMetrics.pace, alignment: .leading)
                        .padding(.top, 10)
                }
            }
            if let tokens = snapshot?.tokensToday {
                HStack(alignment: .top, spacing: 18) {
                    DrawerFigure(title: String(localized: "Token oggi"), value: UsageText.compact(tokens))
                    if let cost = snapshot?.costToday {
                        DrawerFigure(title: String(localized: "Prezzo API"), value: UsageText.money(cost))
                    } else if let requests = snapshot?.requestsToday {
                        DrawerFigure(title: String(localized: "Risposte oggi"), value: "\(requests)")
                    }
                }
                .padding(.top, m.gap)
            }
            if let url = UsageDrawerMetrics.appURL(provider) {
                DrawerButton(title: String(localized: "Apri \(provider.title)")) {
                    DockLaunch.open(url)
                    DockBar.shared.closeDrawers()
                }
                .padding(.top, m.gap)
            }
        }
    }
}

/// Un limite: nome e percentuale, la barra con la tacca del ritmo, quando riparte e quanto manca.
struct UsageWindowRow: View {
    let window: UsageWindow
    let remaining: Bool
    let now: Date

    var body: some View {
        let used = min(100, max(0, window.percent))
        let shown = remaining ? 100 - used : used
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text(window.title).font(.system(size: 13, weight: .medium)).foregroundStyle(.white.opacity(0.82)).lineLimit(1)
                Spacer(minLength: 6)
                Text(verbatim: "\(Int(shown.rounded()))%")
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(UsageTone.color(used: used))
                    .contentTransition(.numericText())
                    .animation(.snappy(duration: 0.3), value: shown)
            }
            .frame(height: 18)
            // La barra dice la stessa cosa del numero (usato o rimasto), con una tacca dove saresti andando a passo
            // costante: usato sotto la tacca, o rimasto sopra, vuol dire che hai margine.
            DrawerBar(fraction: shown / 100, color: UsageTone.color(used: used),
                      tick: window.elapsed(at: now).map { remaining ? 1 - $0 : $0 })
                .padding(.top, 4)
            HStack {
                if let resets = window.resets {
                    Text("Riparte \(UsageText.moment(resets, now: now))")
                    Spacer(minLength: 6)
                    Text("fra \(UsageText.remaining(until: resets, from: now))")
                }
            }
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.white.opacity(0.5))
            .lineLimit(1)
            .frame(height: 14)
            .padding(.top, 3)
        }
    }
}
