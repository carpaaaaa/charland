import AppKit
import ApplicationServices
import CharlandKit

// La Concentrazione di macOS (Non disturbare, Sonno, Lavoro…) nell'isola: un momento quando si accende e uno quando si
// spegne, come su iPhone (carpa, 19 novembre 2026: «come live activity devi anche mettere quando si mette il focus»).
//
// Come si legge, misurato su macOS 27.3 accendendo e spegnendo Non disturbare vero (19 novembre 2026):
// - il servizio della Concentrazione (`DNDStateService` in DoNotDisturb.framework) parla solo con le app di Apple: a
//   un'app senza i loro permessi interni `donotdisturbd` chiude la connessione («XPC connection without any valid
//   entitlements»), lo scrive il registro di sistema;
// - `_NSDoNotDisturbEnabledNotification` e `…Disabled…`, che usano le altre app del notch, su macOS 27 non arrivano più;
//   nessuna notifica Darwin candidata, nessuna preferenza cambia; i file in ~/Library/DoNotDisturb chiedono l'accesso
//   completo al disco;
// - quello che funziona è l'icona della Concentrazione nella barra dei menu (`com.apple.menuextra.focusmode`), letta con
//   l'Accessibilità che Charland ha già per la dettatura: compare 0,2 s dopo l'accensione (e macOS manda un avviso di
//   accessibilità in quel momento), allo spegnimento si sbiadisce dopo 0,18 s (colore da 0,9 a 0,45 di opacità) e
//   sparisce solo 6 s dopo. Lo sbiadirsi non manda avvisi: mentre è accesa la si guarda due volte al secondo;
// - il nome: se la si accende dal Centro di Controllo, il suo interruttore (`controlcenter-focus-modes…`) cambia
//   descrizione in «Do Not Disturb» (o il nome del modo) un decimo di secondo prima che compaia l'icona. Accesa in un
//   altro modo (tasto, iPhone, orario) il nome non si può sapere: l'isola dice «Focus» («Full immersion»), come il
//   Centro di Controllo.
// Vale con l'icona della barra su «Mostra quando è attiva» (di serie) o «Mostra sempre» (lì conta lo sbiadirsi). Con
// «Non mostrare mai» non c'è niente da leggere e l'isola resta zitta.
@MainActor
final class FocusMonitor {
    static let shared = FocusMonitor()
    static let activityID = "concentrazione"
    /// Lo spento è un momento a sé: se il nome è ancora nell'isola, «Spento» prende il suo posto con il passaggio di
    /// consegne delle attività (e viceversa). Con lo stesso momento l'ala destra si restringeva con la parola dentro (la prova di sé lo
    /// segnala come contenitore che cambia misura mentre si vede).
    static let offActivityID = "concentrazione-spenta"
    static let settingKey = "featureFocus"

    private(set) var active = false
    private var started = false
    /// Il processo che tiene le icone della barra (MenuBarAgent su macOS 27, il Centro di Controllo prima) e il suo osservatore.
    private var barPID: pid_t = 0
    private var barObserver: AXObserver?
    private var centerPID: pid_t = 0
    private var centerObserver: AXObserver?
    /// L'icona della Concentrazione trovata l'ultima volta, e un'altra icona accesa con cui confrontarne il colore.
    private var focusItem: AXUIElement?
    private var referenceItem: AXUIElement?
    private var poll: Timer?
    private var retry: Timer?
    private var checkPending = false
    private var workspaceObservers: [NSObjectProtocol] = []
    /// Il nome letto dall'interruttore del Centro di Controllo, e quando.
    private var heardName: (name: String, at: Date)?
    /// Il nome mostrato all'accensione: lo stesso allo spegnimento.
    private var shownName: String?
    /// Il momento nell'isola e fin quando: si chiude solo se c'è (se no il registro delle attività scrive chiusure a vuoto).
    private static var showing: (id: String, until: Date)?

    static let barApps = ["com.apple.MenuBarAgent", "com.apple.controlcenter"]
    static let focusIdentifier = "com.apple.menuextra.focusmode"
    nonisolated static let trace = ProcessInfo.processInfo.environment["CHARLAND_CONCENTRAZIONE_TRACCIA"] != nil

    func start() {
        guard !started else { return }
        started = true
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            workspaceObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { note in
                let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                guard let bundle = app?.bundleIdentifier, FocusMonitor.barApps.contains(bundle) else { return }
                // Il processo della barra è ripartito: si riaggancia, senza annunciare niente.
                MainActor.assumeIsolated { FocusMonitor.shared.reattach() }
            })
        }
        reattach()
    }

    func stop() {
        guard started else { return }
        started = false
        workspaceObservers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        workspaceObservers = []
        detach()
        retry?.invalidate()
        retry = nil
        poll?.invalidate()
        poll = nil
        active = false
        if let shown = Self.showing, Date() < shown.until { SystemActivity.end(shown.id) }
        Self.showing = nil
    }

    // MARK: Aggancio

    /// Si aggancia alla barra e legge lo stato senza annunciarlo (all'avvio, o dopo una ripartenza di macOS).
    private func reattach() {
        detach()
        guard started else { return }
        guard AXIsProcessTrusted(), let bar = Self.barProcess() else {
            // Senza Accessibilità (o con la barra non ancora pronta) riprova ogni tanto: un controllo da niente.
            scheduleRetry()
            return
        }
        retry?.invalidate()
        retry = nil
        barPID = bar
        barObserver = Self.observe(pid: bar, notifications: [kAXCreatedNotification, kAXUIElementDestroyedNotification,
                                                             kAXLayoutChangedNotification, kAXMovedNotification])
        if let center = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.controlcenter").first?.processIdentifier {
            centerPID = center
            centerObserver = Self.observe(pid: center, notifications: [kAXTitleChangedNotification])
        }
        active = read() ?? false
        updatePolling()
        note("agganciata alla barra (pid \(bar)), concentrazione \(active ? "accesa" : "spenta")")
    }

    private func detach() {
        for observer in [barObserver, centerObserver].compactMap({ $0 }) {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        }
        barObserver = nil
        centerObserver = nil
        focusItem = nil
        referenceItem = nil
    }

    private func scheduleRetry() {
        guard retry == nil else { return }
        let timer = Timer(timeInterval: 20, repeats: true) { _ in
            MainActor.assumeIsolated {
                let monitor = FocusMonitor.shared
                if AXIsProcessTrusted(), Self.barProcess() != nil { monitor.reattach() }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        retry = timer
    }

    private static func observe(pid: pid_t, notifications: [String]) -> AXObserver? {
        var observer: AXObserver?
        guard AXObserverCreate(pid, { _, element, notification, _ in
            MainActor.assumeIsolated { FocusMonitor.shared.heard(element, notification as String) }
        }, &observer) == .success, let observer else { return nil }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.3)
        for name in notifications { AXObserverAddNotification(observer, app, name as CFString, nil) }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        return observer
    }

    // MARK: Eventi

    /// Un avviso di accessibilità: un cambio nella barra (si guarda di nuovo, raccogliendo gli avvisi vicini) o
    /// l'interruttore della Concentrazione nel Centro di Controllo che cambia nome.
    private func heard(_ element: AXUIElement, _ notification: String) {
        if notification == kAXTitleChangedNotification as String,
           let id = Self.string(element, "AXIdentifier"), id.hasPrefix("controlcenter-focus-modes"),
           let name = Self.string(element, kAXDescriptionAttribute as String), !name.isEmpty, !FocusNames.isGeneric(name) {
            heardName = (name, Date())
            note("il Centro di Controllo dice «\(name)»")
        }
        scheduleCheck()
    }

    private func scheduleCheck() {
        guard !checkPending else { return }
        checkPending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
            guard let self else { return }
            self.checkPending = false
            self.check()
        }
    }

    private func check() {
        guard started, let now = read() else { return }
        updatePolling()
        guard now != active else { return }
        active = now
        if now {
            // Il nome sentito dal Centro di Controllo vale solo se è di questo momento.
            if let heard = heardName, Date().timeIntervalSince(heard.at) < 3 { shownName = heard.name } else { shownName = nil }
        }
        note(now ? "accesa (\(shownName ?? "nome non noto"))" : "spenta")
        Self.announce(on: now, name: shownName)
    }

    /// Finché l'icona è nella barra la si guarda due volte al secondo: sbiadirsi (spenta) e riaccendersi non mandano
    /// avvisi. Con l'icona su «Mostra quando è attiva» vuol dire mentre è accesa e per i 6 s in cui resta sbiadita; con
    /// «Mostra sempre», sempre (due domande al secondo all'icona già trovata, un costo da niente).
    private func updatePolling() {
        if focusItem != nil { startPolling() } else { stopPolling() }
    }

    private func startPolling() {
        guard poll == nil else { return }
        let timer = Timer(timeInterval: 0.5, repeats: true) { _ in
            MainActor.assumeIsolated { FocusMonitor.shared.check() }
        }
        timer.tolerance = 0.1
        RunLoop.main.add(timer, forMode: .common)
        poll = timer
    }

    private func stopPolling() {
        poll?.invalidate()
        poll = nil
    }

    // MARK: Lettura

    /// Accesa, spenta, o `nil` se non si può sapere (niente Accessibilità, barra che non risponde).
    private func read() -> Bool? {
        guard AXIsProcessTrusted() else { return nil }
        // La via corta: l'icona già trovata e quella di confronto, due domande sole.
        if let item = focusItem, let alpha = Self.alpha(item) {
            return Self.lit(alpha, reference: referenceItem.flatMap(Self.alpha))
        }
        // A Mac bloccato (o a barra che si sta rifacendo) le icone non ci sono: non vuol dire spenta, vuol dire «non so».
        // Senza questo, con la Concentrazione accesa, ogni blocco annunciava «Spento» e ogni sblocco di nuovo il nome.
        guard let items = Self.menuExtras(pid: barPID), !items.isEmpty else { return nil }
        var focus: AXUIElement?
        var reference: (item: AXUIElement, alpha: Double)?
        for item in items {
            if Self.string(item, "AXIdentifier") == Self.focusIdentifier {
                focus = item
            } else if let alpha = Self.alpha(item), alpha > (reference?.alpha ?? 0) {
                reference = (item, alpha)
            }
        }
        focusItem = focus
        referenceItem = reference?.item
        guard let focus else { return false }
        guard let alpha = Self.alpha(focus) else { return true }
        return Self.lit(alpha, reference: reference?.alpha)
    }

    /// Accesa se l'icona non è sbiadita rispetto alle altre della barra (0,9 contro 0,9 accesa, 0,45 contro 0,9 spenta).
    nonisolated static func lit(_ alpha: Double, reference: Double?) -> Bool {
        alpha >= (reference ?? 0.9) * 0.75
    }

    /// Il processo che tiene le icone di sistema della barra dei menu.
    private static func barProcess() -> pid_t? {
        for bundle in barApps {
            guard let pid = NSRunningApplication.runningApplications(withBundleIdentifier: bundle).first?.processIdentifier else { continue }
            if let items = menuExtras(pid: pid), !items.isEmpty { return pid }
        }
        return nil
    }

    /// Le icone della barra: su macOS 27 ogni icona sta dentro un gruppo di MenuBarAgent, prima erano dirette.
    private static func menuExtras(pid: pid_t) -> [AXUIElement]? {
        guard pid != 0 else { return nil }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.3)
        guard let bar = element(app, "AXExtrasMenuBar") else { return nil }
        var items: [AXUIElement] = []
        for child in children(bar) {
            if string(child, "AXIdentifier") != nil {
                items.append(child)
            } else {
                items.append(contentsOf: children(child).filter { string($0, "AXIdentifier") != nil })
            }
        }
        return items
    }

    /// L'opacità del colore dell'icona, dalla sua descrizione per l'accessibilità.
    nonisolated static func alpha(_ element: AXUIElement) -> Double? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, "AXAttributedDescription" as CFString, &value) == .success, let value,
              CFGetTypeID(value) == CFAttributedStringGetTypeID() else { return nil }
        let text = value as! CFAttributedString
        guard CFAttributedStringGetLength(text) > 0,
              let color = CFAttributedStringGetAttribute(text, 0, "AXForegroundColor" as CFString, nil),
              CFGetTypeID(color) == CGColor.typeID else { return nil }
        return Double((color as! CGColor).alpha)
    }

    nonisolated static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    nonisolated static func element(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success, let value,
              CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    nonisolated static func children(_ element: AXUIElement) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value) == .success else { return [] }
        return value as? [AXUIElement] ?? []
    }

    private func note(_ text: String) {
        guard Self.trace else { return }
        print("\(ActivityCenter.clock()) [concentrazione] \(text)")
        fflush(stdout)
    }

    // MARK: Il momento nell'isola

    /// Il momento compatto: il simbolo a sinistra, il nome (o «Spento») a destra. Anche per la scena dimostrativa.
    static func announce(on: Bool, name: String?) {
        let title = name ?? FocusNames.generic
        let style = FocusNames.style(for: name)
        var m = SystemActivity.message(on ? activityID : offActivityID, template: .status, title: title)
        m.status = on ? "focus-on" : "focus-off"
        // La falce disegnata va con «moon.fill», che resta il segno nelle pillole della casa.
        m.symbol = style.symbol ?? "moon.fill"
        m.tint = style.tint
        m.slots = ["trailing": .init(text: on ? title : String(localized: "Spento"))]
        // La falce ci mette quasi un secondo ad aprirsi: l'avviso non dura meno di così.
        m.ttl = on ? max(2.6, Features.noticeTTL) : max(2.2, Features.noticeTTL - 0.4)
        if on { m.alert = .init(haptic: "done") }
        // Prima entra il nuovo, poi esce l'altro, nello stesso istante: così un'altra attività in una goccia (la musica)
        // resta dov'è. Nell'ordine opposto tornava al centro per un fotogramma e il bordo saltava di 27 punti (la prova di
        // sé, «Full immersion sopra la musica»).
        SystemActivity.show(m)
        let other = on ? offActivityID : activityID
        if let shown = showing, shown.id == other, Date() < shown.until { SystemActivity.end(other) }
        showing = (on ? activityID : offActivityID, Date().addingTimeInterval(m.ttl ?? 0))
    }
}

/// I nomi della Concentrazione come li scrive macOS, nella lingua del Mac: dalle tabelle del Centro di Controllo e di
/// DoNotDisturb (le stesse che usa il sistema), così «Do Not Disturb» si riconosce in ogni lingua.
enum FocusNames {
    private static let controlCenterTable = "/System/Library/CoreServices/ControlCenter.app/Contents/Resources/Focus.loctable"
    private static let modesTable = "/System/Library/PrivateFrameworks/DoNotDisturb.framework/Versions/A/Resources/Localizable.loctable"

    private static func table(_ path: String) -> [String: [String: String]] {
        guard let data = FileManager.default.contents(atPath: path),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return [:] }
        return plist.compactMapValues { $0 as? [String: String] }
    }

    private static func preferred(_ table: [String: [String: String]]) -> [String: String] {
        let language = Bundle.preferredLocalizations(from: Array(table.keys), forPreferences: Locale.preferredLanguages).first
        return language.flatMap { table[$0] } ?? table["en"] ?? [:]
    }

    /// «Focus» nella lingua del Mac (in italiano «Full immersion»), come nel Centro di Controllo.
    static let generic: String = preferred(table(controlCenterTable))["Focus"] ?? String(localized: "Full immersion")
    /// Tutti i modi in cui il Centro di Controllo scrive «Focus»: quando l'interruttore dice così, non c'è un nome.
    private static let generics: Set<String> = Set(table(controlCenterTable).values.compactMap { $0["Focus"] }).union([generic])
    /// Nome in qualsiasi lingua → chiave del modo (MODE_NAME_SLEEP…).
    private static let modeKeys: [String: String] = {
        var map: [String: String] = [:]
        for strings in table(modesTable).values {
            for (key, value) in strings where key.hasPrefix("MODE_NAME_") { map[value] = key }
        }
        return map
    }()

    static func isGeneric(_ name: String) -> Bool { generics.contains(name) }

    /// Il nome di Non disturbare nella lingua del Mac (per la scena dimostrativa).
    static var doNotDisturb: String { preferred(table(modesTable))["MODE_NAME_DEFAULT"] ?? "Do Not Disturb" }
    static var sleep: String { preferred(table(modesTable))["MODE_NAME_SLEEP"] ?? "Sleep" }

    /// Il simbolo e il colore di un modo noto. `symbol` nil: la falce disegnata (Non disturbare, i modi creati da chi usa
    /// il Mac, di cui il simbolo non si può leggere, e quando il nome non si sa).
    static func style(for name: String?) -> (symbol: String?, tint: String) {
        guard let name, let key = modeKeys[name] else { return (nil, "indigo") }
        let symbol: String?
        switch key {
        case "MODE_NAME_SLEEP": symbol = "bed.double.fill"
        case "MODE_NAME_DRIVING": symbol = "car.fill"
        case "MODE_NAME_WORK": symbol = "person.lanyardcard.fill"
        case "MODE_NAME_PERSONAL": symbol = "person.fill"
        case "MODE_NAME_READING": symbol = "book.fill"
        case "MODE_NAME_GAMING": symbol = "gamecontroller.fill"
        case "MODE_NAME_MINDFULNESS": symbol = "figure.mind.and.body"
        case "MODE_NAME_FITNESS": symbol = "figure.run"
        default: symbol = nil
        }
        let valid = symbol.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil) == nil ? nil : $0 }
        return (valid, key == "MODE_NAME_SLEEP" ? "mint" : "indigo")
    }
}
