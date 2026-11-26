import AppKit
import ApplicationServices
import SwiftUI
import CharlandKit
import Carbon.HIToolbox

/// Chiudere le app (carpa, 18 novembre 2026): una scorciatoia che chiude tutte le app aperte, con le eccezioni che scegli
/// («selezioni Claude come eccezione e quella non viene chiusa mai»), e la x rossa che chiude davvero l'app quando chiudi
/// la sua ultima finestra, anche qui con le sue eccezioni.
///
/// Le app si chiudono con la richiesta normale (come ⌘Q): chi ha documenti non salvati chiede prima di chiudersi. Finder e
/// Charland non si chiudono mai.
@MainActor @Observable
final class AppQuitter {
    static let shared = AppQuitter()

    static let claude = "com.anthropic.claudefordesktop"
    /// Mai chiuse, da nessuna delle due funzioni.
    static let never: Set<String> = ["com.apple.finder", "com.apple.loginwindow", Bundle.main.bundleIdentifier ?? ""]

    /// ⌃⌥⌘Q: quattro tasti, difficile premerli per sbaglio.
    static let quitAllDefault = KeyCombo(keyCode: UInt32(kVK_ANSI_Q), modifiers: UInt32(controlKey | optionKey | cmdKey))
    private static let shortcutID: UInt32 = 40

    var quitAllCombo: KeyCombo? {
        didSet {
            guard ready else { return }
            UserDefaults.standard.set(quitAllCombo.flatMap { try? JSONEncoder().encode($0) } ?? Data(), forKey: "quitAllCombo")
            registerShortcut()
        }
    }
    /// Le app che «Chiudi tutte le app» lascia aperte. Di serie Claude, per non chiudere la chat con cui stai lavorando.
    var quitAllExceptions: [String] { didSet { if ready { UserDefaults.standard.set(quitAllExceptions, forKey: "quitAllExceptions") } } }
    /// La x rossa chiude l'app quando chiudi la sua ultima finestra.
    var closeQuits: Bool {
        didSet {
            guard ready else { return }
            UserDefaults.standard.set(closeQuits, forKey: "closeQuits")
            CloseButtonWatcher.shared.setEnabled(closeQuits)
        }
    }
    /// Le app che restano aperte anche chiudendo l'ultima finestra con la x rossa.
    var closeExceptions: [String] { didSet { if ready { UserDefaults.standard.set(closeExceptions, forKey: "closeQuitsExceptions") } } }
    /// Un'altra app tiene già la scorciatoia.
    private(set) var shortcutTaken = false

    @ObservationIgnored private var ready = false

    private init() {
        let d = UserDefaults.standard
        if let data = d.data(forKey: "quitAllCombo") {
            quitAllCombo = data.isEmpty ? nil : try? JSONDecoder().decode(KeyCombo.self, from: data)
        } else {
            quitAllCombo = Self.quitAllDefault
        }
        quitAllExceptions = d.stringArray(forKey: "quitAllExceptions") ?? [Self.claude]
        closeQuits = d.bool(forKey: "closeQuits")
        // Charland si vede nella lista di serie (carpa, 20 novembre 2026: «se metti l'opzione che con la x chiudi l'app,
        // Charland è di serie nelle eccezioni»). Protetta lo è comunque (`never`): chiudendo le sue impostazioni con la x
        // non si chiude mai.
        closeExceptions = d.stringArray(forKey: "closeQuitsExceptions") ?? [Bundle.main.bundleIdentifier ?? "com.charstudio.charland"]
        ready = true
    }

    /// All'avvio: la scorciatoia e, se accesa, la x rossa.
    func start() {
        registerShortcut()
        CloseButtonWatcher.shared.setEnabled(closeQuits)
    }

    func stop() {
        HotkeyCenter.shared.unregister(id: Self.shortcutID)
        CloseButtonWatcher.shared.setEnabled(false)
    }

    func registerShortcut() {
        HotkeyCenter.shared.unregister(id: Self.shortcutID)
        guard let combo = quitAllCombo else { shortcutTaken = false; return }
        shortcutTaken = !HotkeyCenter.shared.register(id: Self.shortcutID, combo: combo, down: { AppQuitter.shared.quitAll() })
    }

    /// Le app che «Chiudi tutte le app» chiuderebbe adesso.
    var quittableNow: [NSRunningApplication] {
        NSWorkspace.shared.runningApplications.filter { app in
            guard app.activationPolicy == .regular, !app.isTerminated, let id = app.bundleIdentifier else { return false }
            return !Self.never.contains(id) && !quitAllExceptions.contains(id)
        }
    }

    /// Chiude tutte le app aperte tranne le eccezioni, poi lo dice nell'isola.
    func quitAll() {
        let apps = quittableNow
        apps.forEach { $0.terminate() }
        var m = SystemActivity.message("chiudi-app", template: .status,
                                       title: apps.isEmpty ? String(localized: "Niente da chiudere") : String(localized: "Chiuse \(apps.count) app"))
        m.symbol = "xmark.app.fill"
        m.slots = ["trailing": .init(text: "\(apps.count)")]
        m.ttl = Features.noticeTTL
        m.alert = .init(haptic: "done")
        SystemActivity.show(m)
    }

    /// La x rossa: l'app si chiude se non è fra le eccezioni.
    func shouldQuitOnClose(_ app: NSRunningApplication) -> Bool {
        guard closeQuits, app.activationPolicy == .regular, let id = app.bundleIdentifier else { return false }
        return !Self.never.contains(id) && !closeExceptions.contains(id)
    }
}

// MARK: - La x rossa

/// Guarda i clic sul pulsante rosso delle finestre. Dopo il clic, se l'app non ha più finestre (nessuna aperta, nessuna
/// ridotta nel Dock, nessuna su un'altra scrivania), la chiude. Guarda di nuovo per qualche secondo: una finestra con un
/// documento non salvato chiede prima «Salvare?», e si chiude solo dopo la risposta.
///
/// Il pulsante sotto il puntatore lo dice l'Accessibilità (serve il permesso, che Charland ha già per il Dock). Le domande
/// all'Accessibilità possono aspettare un'app occupata: si fanno fuori dal thread principale, con un tempo massimo.
@MainActor
final class CloseButtonWatcher {
    static let shared = CloseButtonWatcher()

    private var monitor: Any?
    private let queue = DispatchQueue(label: "charland.chiudi-app", qos: .userInitiated)

    func setEnabled(_ on: Bool) {
        if on, monitor == nil {
            monitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { _ in
                let point = NSEvent.mouseLocation
                MainActor.assumeIsolated { CloseButtonWatcher.shared.clicked(at: point) }
            }
        } else if !on, let current = monitor {
            NSEvent.removeMonitor(current)
            monitor = nil
        }
    }

    private func clicked(at point: CGPoint) {
        guard AXIsProcessTrusted(), let screen = NSScreen.screens.first else { return }
        // Le nostre finestre che lasciano passare i clic (l'isola, i widget): sotto di loro c'è l'app vera.
        let passThrough = Set(NSApp.windows.filter { $0.isVisible && $0.ignoresMouseEvents }.map { CGWindowID($0.windowNumber) })
        // Dalle coordinate di AppKit (origine in basso) a quelle dell'Accessibilità (origine in alto).
        let x = Float(point.x), y = Float(screen.frame.maxY - point.y)
        queue.async {
            guard !Self.skipsHitTest(x: x, y: y, passThrough: passThrough), let pid = Self.closeButtonOwner(x: x, y: y) else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let app = NSRunningApplication(processIdentifier: pid), AppQuitter.shared.shouldQuitOnClose(app) else { return }
                    CloseButtonWatcher.shared.watch(app)
                }
            }
        }
    }

    /// Dopo il clic si guarda tre volte: subito dopo l'animazione di chiusura, poi per dare tempo a «Salvare?».
    private func watch(_ app: NSRunningApplication) {
        let pid = app.processIdentifier
        for delay in [0.45, 1.5, 4.0] {
            queue.asyncAfter(deadline: .now() + delay) {
                guard Self.hasNoWindows(pid: pid) else { return }
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated,
                              AppQuitter.shared.shouldQuitOnClose(app) else { return }
                        app.terminate()
                    }
                }
            }
        }
    }

    /// Sotto il punto c'è la barra dei menu o una finestra di Charland: lì niente x rosse, e la domanda
    /// all'Accessibilità non va fatta. Su macOS 27 le voci della barra le disegna il sistema in una finestra sola
    /// («Menubar», livello 24): un clic sulla farfalla del timer arriva qui come clic su un'altra app, e la domanda
    /// finiva a Charland stessa, che AppKit risponderebbe su questo thread insieme al thread principale. Non regge: le
    /// cadute del 20 novembre 2026 erano tutte lì, in `accessibilityHitTest` (carpa: «quando tiro giù la farfalla per
    /// il timer o la premo a volte crasha»). Dalla finestra e non da una striscia fissa: con la barra nascosta, e sugli
    /// schermi senza barra, le x rosse in cima restano buone.
    nonisolated private static func skipsHitTest(x: Float, y: Float, passThrough: Set<CGWindowID>) -> Bool {
        let point = CGPoint(x: CGFloat(x), y: CGFloat(y))
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        // Dalla più in alto: la prima che contiene il punto e prende i clic.
        for info in list {
            guard let number = info[kCGWindowNumber as String] as? CGWindowID, !passThrough.contains(number),
                  (info[kCGWindowAlpha as String] as? Double ?? 1) > 0.01,
                  let dict = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: dict), bounds.contains(point) else { continue }
            let layer = info[kCGWindowLayer as String] as? Int
            return (info[kCGWindowOwnerPID as String] as? pid_t) == getpid() || layer == menuBarLayer || layer == statusLayer
        }
        return false
    }

    nonisolated private static let menuBarLayer = Int(CGWindowLevelForKey(.mainMenuWindow))
    nonisolated private static let statusLayer = Int(CGWindowLevelForKey(.statusWindow))

    /// Il proprietario del pulsante rosso sotto il punto, se lì c'è un pulsante rosso.
    nonisolated private static func closeButtonOwner(x: Float, y: Float) -> pid_t? {
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.3)
        var element: AXUIElement?
        guard AXUIElementCopyElementAtPosition(system, x, y, &element) == .success, let element else { return nil }
        var subrole: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &subrole)
        guard (subrole as? String) == kAXCloseButtonSubrole else { return nil }
        var pid: pid_t = 0
        guard AXUIElementGetPid(element, &pid) == .success, pid != getpid() else { return nil }
        return pid
    }

    /// L'app non ha più finestre vere: nessuna fra quelle che dice l'Accessibilità (comprese le ridotte nel Dock) e
    /// nessuna fra quelle del sistema, che vede anche le altre scrivanie. Nel dubbio, non si chiude.
    nonisolated private static func hasNoWindows(pid: pid_t) -> Bool {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.5)
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value)
        guard result == .success || result == .noValue else { return false }
        if let windows = value as? [AXUIElement], windows.contains(where: isRealWindow) { return false }
        // Le finestre sulle altre scrivanie l'Accessibilità non sempre le dice: le chiede al sistema.
        let all = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        let others = all.contains { info in
            guard (info[kCGWindowOwnerPID as String] as? pid_t) == pid, (info[kCGWindowLayer as String] as? Int) == 0,
                  (info[kCGWindowAlpha as String] as? Double ?? 1) > 0.01,
                  let bounds = info[kCGWindowBounds as String] as? [String: Any],
                  let width = bounds["Width"] as? Double, let height = bounds["Height"] as? Double else { return false }
            // Le finestrelle che molte app tengono nascoste sono piccole: contano solo quelle grandi come una finestra.
            return width >= 160 && height >= 100
        }
        return !others
    }

    nonisolated private static func isRealWindow(_ window: AXUIElement) -> Bool {
        var subrole: CFTypeRef?
        AXUIElementCopyAttributeValue(window, kAXSubroleAttribute as CFString, &subrole)
        let kind = subrole as? String
        return kind == kAXStandardWindowSubrole || kind == kAXDialogSubrole
    }
}

// MARK: - Impostazioni

/// Impostazioni › Chiusura app.
struct QuitAppsPane: View {
    @Bindable private var quitter = AppQuitter.shared
    @State private var trusted = AXIsProcessTrusted()

    var body: some View {
        Form {
            Section {
                LabeledContent("Scorciatoia") {
                    OptionalShortcutRecorder(combo: $quitter.quitAllCombo, hotkeyID: 40) { AppQuitter.shared.registerShortcut() }
                }
                if quitter.shortcutTaken {
                    Text("Un'altra app usa già questa scorciatoia: scegline un'altra.").font(.callout).foregroundStyle(.secondary)
                }
                AppExceptionList(title: String(localized: "Non chiudere mai"), ids: $quitter.quitAllExceptions)
            } header: {
                Text("Chiudi tutte le app")
            } footer: {
                Text("Chiude tutte le app aperte tranne Finder, Charland e quelle qui sopra. Le app con documenti non salvati chiedono prima di chiudersi.")
            }
            Section {
                Toggle("Chiudi l'app con la x rossa", isOn: $quitter.closeQuits)
                if quitter.closeQuits {
                    AppExceptionList(title: String(localized: "Restano aperte"), ids: $quitter.closeExceptions)
                    if !trusted {
                        PermissionRow(title: PermissionsPane.accessibilityName,
                                      purpose: String(localized: "Per riconoscere il pulsante rosso delle finestre."),
                                      granted: false,
                                      link: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                            let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
                            _ = AXIsProcessTrustedWithOptions(options)
                        }
                    }
                }
            } header: {
                Text("La x rossa")
            } footer: {
                Text("Chiudendo con il pulsante rosso l'ultima finestra di un'app, l'app si chiude davvero invece di restare aperta nel Dock. Se ha ancora finestre ridotte o su altre scrivanie resta aperta.")
            }
        }
        .formStyle(.grouped)
        .onAppear { trusted = AXIsProcessTrusted() }
    }
}

/// Un elenco di app con l'icona, da cui togliere e a cui aggiungere (fra quelle aperte o dalla cartella Applicazioni).
struct AppExceptionList: View {
    let title: String
    @Binding var ids: [String]

    var body: some View {
        LabeledContent(title) {
            Menu("Aggiungi") {
                ForEach(candidates, id: \.self) { id in
                    Button { ids.append(id) } label: {
                        Label { Text(Self.name(id)) } icon: { if let icon = Self.icon(id) { Image(nsImage: icon) } }
                    }
                }
                if !candidates.isEmpty { Divider() }
                Button("Altra app…") { chooseOther() }
            }
            .fixedSize()
        }
        ForEach(ids, id: \.self) { id in
            HStack(spacing: 8) {
                if let icon = Self.icon(id) { Image(nsImage: icon) }
                Text(Self.name(id))
                Spacer()
                Button { ids.removeAll { $0 == id } } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .help(String(localized: "Togli"))
            }
        }
    }

    /// Le app aperte adesso che non sono già nell'elenco.
    private var candidates: [String] {
        let running = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap(\.bundleIdentifier)
            .filter { !ids.contains($0) && !AppQuitter.never.contains($0) }
        return Array(Set(running)).sorted { Self.name($0).localizedCaseInsensitiveCompare(Self.name($1)) == .orderedAscending }
    }

    private func chooseOther() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowsMultipleSelection = true
        panel.prompt = String(localized: "Aggiungi")
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            if let id = Bundle(url: url)?.bundleIdentifier, !ids.contains(id) { ids.append(id) }
        }
    }

    static func name(_ id: String) -> String {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { return id }
        return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }

    static func icon(_ id: String) -> NSImage? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { return nil }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        icon.size = NSSize(width: 18, height: 18)
        return icon
    }
}
