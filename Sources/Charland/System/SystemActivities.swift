import AppKit
import IOKit.ps
import IOKit.pwr_mgt
import ServiceManagement
import CharlandCore
import CharlandKit

// Le attività di sistema dell'isola: mantieni attivo, timer, batteria, registrazione dello schermo.
// Passano tutte dal centro delle attività, come quelle che arrivano dall'API.

/// Mostra o toglie un'attività interna di Charland, con le sue azioni.
@MainActor
enum SystemActivity {
    static func show(_ message: ActivityMessage, actions: ((String) -> Void)? = nil) {
        ActivityCenter.shared.local(message, handler: actions)
    }

    static func end(_ id: String) {
        _ = ActivityCenter.shared.handle(ActivityMessage(op: .end, client: "charland", id: id), from: nil)
    }

    static func message(_ id: String, template: ActivityMessage.Template, title: String) -> ActivityMessage {
        var m = ActivityMessage(op: .upsert, client: "charland", id: id)
        m.template = template
        m.title = title
        return m
    }
}

// MARK: - Mantieni attivo

/// Tiene sveglio il Mac. Finché il coperchio è aperto basta un'asserzione di sistema. A coperchio chiuso passa
/// dall'aiutante di sistema (`CharlandHelper`): installato e approvato una volta in Impostazioni di Sistema, poi
/// nessuna password. L'aiutante rimette il sonno normale da solo quando lo spegni, quando scade il tempo, quando la
/// batteria scende al 10% o se Charland si chiude o cade (la connessione si interrompe). Il Mac non resta mai
/// sveglio per sbaglio. Prima chiedeva la password a ogni accensione: carpa non lo voleva.
///
/// Segue anche il «Keep awake» dell'app di Claude (carpa, 24 novembre 2026: «quando c'è il mantieni attivo o l'awake,
/// Claude deve continuare a lavorare anche col coperchio chiuso»). Quello di Claude ferma solo il sonno per inattività:
/// a coperchio chiuso il Mac dorme lo stesso. Finché Claude lo tiene acceso e un agente di Claude sta lavorando,
/// Charland spegne anche il sonno a coperchio chiuso, e lo rimette due minuti dopo l'ultimo agente.
@MainActor @Observable
final class KeepAwake {
    static let shared = KeepAwake()
    static let activityID = "mantieni-attivo"

    private(set) var active = false
    private(set) var until: Date?
    /// Acceso «finché gli agenti non hanno finito» (carpa: «se mando un prompt a Claude il pc rimane attivo finché
    /// Claude non ha finito tutto il lavoro, compreso quello degli agenti nascosti o sottochat»).
    private(set) var untilAgentsDone = false
    /// Il sonno a coperchio chiuso è davvero spento in questo momento.
    private(set) var closedLidEngaged = false
    /// Chiedere anche il coperchio chiuso quando si accende.
    var closedLid: Bool {
        didSet {
            UserDefaults.standard.set(closedLid, forKey: "keepAwakeClosedLid")
            guard closedLid != oldValue else { return }
            syncClosedLid()
            publish()
        }
    }
    /// Seguire il «Keep awake» dell'app di Claude anche a coperchio chiuso (di serie sì).
    var followClaude: Bool {
        didSet {
            UserDefaults.standard.set(followClaude, forKey: "keepAwakeFollowClaude")
            guard followClaude != oldValue else { return }
            claudeChanged()
        }
    }
    /// In questo momento il coperchio chiuso è chiesto perché Claude sta lavorando col suo «Keep awake» acceso.
    private(set) var followingClaude = false
    /// L'aiutante va approvato una volta in Impostazioni di Sistema prima di poter tenere sveglio il Mac chiuso.
    private(set) var helperNeedsApproval = false

    @ObservationIgnored private var assertion: IOPMAssertionID = 0
    @ObservationIgnored private var helperConnection: NSXPCConnection?
    /// La scadenza chiesta all'aiutante l'ultima volta (0 = nessuna): se cambia gliela si ridice.
    @ObservationIgnored private var helperDeadline: Double = -1
    /// L'ultima riparazione dell'aiutante: al massimo una al minuto, e finché il coperchio chiuso serve si riprova.
    @ObservationIgnored private var lastRepair: Date?
    @ObservationIgnored private var retryTimer: Timer?
    /// Claude ha smesso: il coperchio chiuso resta ancora `agentsGrace`, poi torna il sonno.
    @ObservationIgnored private var claudeGraceTimer: Timer?
    /// Mentre segue Claude, ogni minuto riguarda se Claude c'è ancora (chiusa, o «Keep awake» lasciato a batteria).
    @ObservationIgnored private var claudeCheckTimer: Timer?
    /// L'isola ha già spiegato una volta cosa fare per l'aiutante.
    @ObservationIgnored private var explainedApproval = false
    @ObservationIgnored private var approvalWatch: Task<Void, Never>?
    @ObservationIgnored private var endTimer: Timer?
    /// In modalità agenti: se qualcuno ha lavorato da quando si è acceso, e il timer della quiete.
    @ObservationIgnored private var sawAgents = false
    @ObservationIgnored private var quietTimer: Timer?
    /// Dopo l'ultimo agente, quanto aspetta prima di rimettere il sonno: copre il momento fra la fine di un sotto-agente
    /// in sottofondo e la ripresa della sessione che lo aspettava. Le pause per pensare stanno dentro il turno, che
    /// resta aperto finché Claude non lo chiude.
    static let agentsGrace: TimeInterval = 120
    /// Acceso prima di mandare il messaggio: aspetta che un agente cominci, al massimo dieci minuti.
    static let agentsArmed: TimeInterval = 600

    /// La scorciatoia che lo accende e lo spegne; `nil` vuol dire nessuna.
    var combo: KeyCombo? {
        didSet {
            UserDefaults.standard.set(combo.flatMap { try? JSONEncoder().encode($0) }, forKey: "keepAwakeCombo")
            UserDefaults.standard.set(combo == nil, forKey: "keepAwakeComboCleared")
            registerShortcut()
        }
    }
    /// Quanto dura quando si accende con la scorciatoia: 0 vuol dire finché non lo spegni.
    var shortcutDuration: TimeInterval {
        didSet { UserDefaults.standard.set(shortcutDuration, forKey: "keepAwakeShortcutDuration") }
    }
    private static let shortcutID: UInt32 = 4

    private init() {
        let d = UserDefaults.standard
        if let data = d.data(forKey: "keepAwakeCombo"), let saved = try? JSONDecoder().decode(KeyCombo.self, from: data) {
            combo = saved
        } else {
            combo = d.bool(forKey: "keepAwakeComboCleared") ? nil : .keepAwakeDefault
        }
        shortcutDuration = d.object(forKey: "keepAwakeShortcutDuration") as? Double ?? 0
        // Di serie anche a coperchio chiuso (carpa: «voglio che di default funzioni anche con il coperchio chiuso, poi se
        // uno vuole cambiare lo fa da Impostazioni»).
        closedLid = d.object(forKey: "keepAwakeClosedLid") as? Bool ?? true
        followClaude = d.object(forKey: "keepAwakeFollowClaude") as? Bool ?? true
        // Il guardiano delle versioni di prima (uno script con la password) si spegne da solo togliendo il suo segno.
        try? FileManager.default.removeItem(at: CharlandPaths.supportFolder.appendingPathComponent("mantieni-attivo"))
    }

    /// Accende. `duration` nil vuol dire finché non lo spegni; `untilAgentsDone` finché gli agenti non hanno finito.
    func start(duration: TimeInterval?, untilAgentsDone agents: Bool = false) {
        stop(quietly: true)
        var id: IOPMAssertionID = 0
        let ok = IOPMAssertionCreateWithName(kIOPMAssertPreventUserIdleSystemSleep as CFString,
                                             IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                             "Charland: mantieni attivo" as CFString, &id)
        guard ok == kIOReturnSuccess else { return }
        assertion = id
        active = true
        // Prima di mostrarsi: la prima comparsa ha già il segno e la riga giuste (e l'avviso del coperchio, che si mostra
        // una volta sola, non va sprecato su una versione sbagliata).
        untilAgentsDone = agents
        until = duration.map { Date().addingTimeInterval($0) }
        if let duration {
            let timer = Timer(timeInterval: duration, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.stop() }
            }
            RunLoop.main.add(timer, forMode: .common)
            endTimer = timer
        }
        syncClosedLid()
        publish()
    }

    /// Accende finché gli agenti non hanno finito tutto, sotto-agenti compresi.
    func startUntilAgentsDone() {
        start(duration: nil, untilAgentsDone: true)
        agentsChanged()
    }

    /// Qualcuno ha cominciato o finito: in modalità agenti decide se restare sveglio.
    func agentsChanged() {
        claudeChanged()
        guard active, untilAgentsDone else { return }
        if AgentHub.shared.anyoneWorking {
            sawAgents = true
            quietTimer?.invalidate()
            quietTimer = nil
            return
        }
        guard quietTimer == nil else { return }
        let wait = sawAgents ? Self.agentsGrace : Self.agentsArmed
        let timer = Timer(timeInterval: wait, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.quietTimer = nil
                guard self.active, self.untilAgentsDone, !AgentHub.shared.anyoneWorking else { return }
                self.stop()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        quietTimer = timer
    }

    func stop(quietly: Bool = false) {
        endTimer?.invalidate()
        endTimer = nil
        quietTimer?.invalidate()
        quietTimer = nil
        untilAgentsDone = false
        sawAgents = false
        if assertion != 0 {
            IOPMAssertionRelease(assertion)
            assertion = 0
        }
        let was = active
        active = false
        until = nil
        // Se nient'altro lo chiede (Claude al lavoro), l'aiutante rimette il sonno normale appena la connessione si chiude.
        syncClosedLid()
        if was, !quietly { SystemActivity.end(Self.activityID) }
    }

    func toggle(duration: TimeInterval?) {
        if active { stop() } else { start(duration: duration) }
    }

    /// Registra la scorciatoia (o la toglie). Si chiama all'avvio e quando cambia.
    func registerShortcut() {
        HotkeyCenter.shared.unregister(id: Self.shortcutID)
        guard let combo else { return }
        HotkeyCenter.shared.register(id: Self.shortcutID, combo: combo, down: { [weak self] in self?.toggleFromShortcut() })
    }

    /// Dalla scorciatoia: un tocco lo accende, un altro lo spegne. Un tocco sul trackpad conferma.
    /// Spegnendo l'icona se ne va e basta (carpa: niente tazza vuota che ricompare).
    func toggleFromShortcut() {
        Haptics.play("done")
        if active {
            stop()
        } else {
            start(duration: shortcutDuration > 0 ? shortcutDuration : nil)
        }
    }

    /// Chiede o lascia il coperchio chiuso secondo quello che serve adesso: Mantieni attivo acceso (col suo
    /// interruttore), oppure Claude al lavoro col suo «Keep awake».
    private func syncClosedLid() {
        if wantsClosedLid {
            engageClosedLid()
        } else {
            approvalWatch?.cancel()
            dropHelper()
            closedLidEngaged = false
            helperNeedsApproval = false
            retryTimer?.invalidate()
            retryTimer = nil
        }
    }

    private var wantsClosedLid: Bool { (active && closedLid) || followingClaude }

    /// La scadenza per l'aiutante: seguendo Claude nessuna (la fine la decide Charland), se no quella di Mantieni attivo.
    private var wantedDeadline: Double { followingClaude ? 0 : (until?.timeIntervalSince1970 ?? 0) }

    /// Spegne il sonno a coperchio chiuso attraverso l'aiutante di sistema. La prima volta lo registra e apre
    /// Impostazioni di Sistema per approvarlo (una volta sola); finché non è approvato resta sveglio solo a
    /// coperchio aperto, senza nessuna finestra della password.
    private func engageClosedLid() {
        guard PrivilegedHelper.installedApp else { return }
        let status = PrivilegedHelper.ensureRegistered()
        guard status == .enabled else {
            // Nessuna finestra di sistema a sorpresa: l'isola si apre e spiega cosa fare, una volta sola.
            helperNeedsApproval = true
            watchApproval()
            publish()
            return
        }
        helperNeedsApproval = false
        if let connection = helperConnection {
            // Già collegato: gli si ridice la scadenza solo se è cambiata.
            guard helperDeadline != wantedDeadline else { return }
            helperDeadline = wantedDeadline
            PrivilegedHelper.request(ConnectionBox(connection), on: true, deadline: wantedDeadline)
            return
        }
        let connection = NSXPCConnection(machServiceName: CharlandHelperInfo.label, options: .privileged)
        connection.remoteObjectInterface = NSXPCInterface(with: CharlandHelperProtocol.self)
        PrivilegedHelper.attachHandlers(connection)
        connection.resume()
        helperConnection = connection
        helperDeadline = wantedDeadline
        PrivilegedHelper.request(ConnectionBox(connection), on: true, deadline: wantedDeadline)
    }

    /// Apre Impostazioni di Sistema › Elementi di login e, finché resta acceso, si accorge da solo dell'approvazione.
    func openApproval() {
        PrivilegedHelper.openApproval()
        watchApproval()
    }

    /// Ogni due secondi, per tre minuti al massimo e solo mentre aspetta: appena l'aiutante è approvato, il
    /// coperchio chiuso si accende da solo.
    private func watchApproval() {
        approvalWatch?.cancel()
        approvalWatch = Task { [weak self] in
            for _ in 0..<90 {
                try? await Task.sleep(for: .seconds(2))
                guard let self, !Task.isCancelled, self.wantsClosedLid else { return }
                if PrivilegedHelper.service.status == .enabled {
                    self.engageClosedLid()
                    return
                }
            }
        }
    }

    func helperReplied(_ ok: Bool, on: Bool) {
        guard on else { return }
        guard ok else {
            dropHelper()
            closedLidEngaged = false
            repairAndRetry()
            publish()
            return
        }
        closedLidEngaged = wantsClosedLid
        retryTimer?.invalidate()
        retryTimer = nil
        publish()
    }

    func helperDropped() {
        guard helperConnection != nil else { return }
        helperConnection = nil
        closedLidEngaged = false
        repairAndRetry()
        publish()
    }

    /// L'aiutante approvato che non risponde, o che cade a metà: quasi sempre launchd lo ha perso perché il pacchetto
    /// dell'app è stato sostituito (installazione, aggiornamento). Lo si rimette a posto e si riprova; se non basta,
    /// finché il coperchio chiuso serve si riprova una volta al minuto (intanto resta sveglio solo a coperchio aperto,
    /// come dice la scritta sotto).
    private func repairAndRetry() {
        guard wantsClosedLid else { return }
        if let lastRepair, Date().timeIntervalSince(lastRepair) < 60 {
            scheduleRetry(after: 60 - Date().timeIntervalSince(lastRepair))
            return
        }
        lastRepair = Date()
        Task { [weak self] in
            let fixed = await PrivilegedHelper.repair()
            guard let self, self.wantsClosedLid, self.helperConnection == nil else { return }
            if fixed { self.engageClosedLid() } else { self.scheduleRetry(after: 60); self.publish() }
        }
    }

    private func scheduleRetry(after delay: TimeInterval) {
        guard retryTimer == nil else { return }
        let timer = Timer(timeInterval: max(delay, 1), repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.retryTimer = nil
                guard self.wantsClosedLid, self.helperConnection == nil else { return }
                self.engageClosedLid()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        retryTimer = timer
    }

    private func dropHelper() {
        helperDeadline = -1
        guard let connection = helperConnection else { return }
        helperConnection = nil
        PrivilegedHelper.request(ConnectionBox(connection), on: false, deadline: 0)
        connection.invalidate()
    }

    // MARK: Il «Keep awake» di Claude

    /// Un agente ha cominciato o finito, o è passato un minuto mentre lo segue: decide se seguire Claude.
    /// Nessun controllo a riposo: si guarda solo quando gli agenti cambiano.
    func claudeChanged() {
        if claudeWantsClosedLid {
            claudeGraceTimer?.invalidate()
            claudeGraceTimer = nil
            guard !followingClaude else { return }
            followingClaude = true
            startClaudeCheck()
            syncClosedLid()
            return
        }
        guard followingClaude else { return }
        // Spento dalle impostazioni: subito.
        guard followClaude else { endFollowingClaude(); return }
        // Agenti finiti, Claude chiusa o il suo «Keep awake» spento: la stessa attesa della mascotte, che copre la pausa
        // fra un sotto-agente che finisce e la sessione che riprende.
        guard claudeGraceTimer == nil else { return }
        let timer = Timer(timeInterval: Self.agentsGrace, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.claudeGraceTimer = nil
                if !self.claudeWantsClosedLid { self.endFollowingClaude() }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        claudeGraceTimer = timer
    }

    /// Claude ha il suo «Keep awake» acceso e un suo agente sta lavorando.
    private var claudeWantsClosedLid: Bool {
        followClaude && AgentHub.shared.claudeWorking && ClaudeAwake.isHeld()
    }

    private func startClaudeCheck() {
        claudeCheckTimer?.invalidate()
        let timer = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.claudeChanged() }
        }
        timer.tolerance = 10
        RunLoop.main.add(timer, forMode: .common)
        claudeCheckTimer = timer
    }

    private func endFollowingClaude() {
        claudeGraceTimer?.invalidate()
        claudeGraceTimer = nil
        claudeCheckTimer?.invalidate()
        claudeCheckTimer = nil
        guard followingClaude else { return }
        followingClaude = false
        syncClosedLid()
        publish()
    }

    private func publish() {
        guard active else { return }
        var m = SystemActivity.message(Self.activityID, template: until == nil ? .status : .countdown,
                                       title: String(localized: "Mantieni attivo"))
        // Sempre il caffè, anche a coperchio chiuso (carpa): il coperchio lo dice la scritta sotto.
        m.symbol = "cup.and.saucer.fill"
        m.tint = "teal"
        let waiting = closedLid && helperNeedsApproval && !closedLidEngaged
        if waiting {
            m.subtitle = String(localized: "Coperchio chiuso: accendi Charland in Elementi di login, una volta sola")
        } else if untilAgentsDone {
            m.subtitle = closedLidEngaged ? String(localized: "Finché gli agenti lavorano, anche a coperchio chiuso")
                : String(localized: "Finché gli agenti lavorano")
        } else {
            m.subtitle = closedLidEngaged ? String(localized: "Anche a coperchio chiuso") : String(localized: "Finché il coperchio è aperto")
        }
        if waiting, !explainedApproval {
            // La prima volta l'isola si apre da sola: così si legge cosa fare invece di vedere finestre di sistema.
            explainedApproval = true
            m.alert = .init(expand: true, haptic: "waiting")
        }
        if let until {
            m.endsAt = until.timeIntervalSince1970
            m.startedAt = Date().timeIntervalSince1970
        } else {
            m.slots = ["trailing": .init(symbol: untilAgentsDone ? "sparkle" : "infinity")]
        }
        m.priority = -1
        var actions: [ActivityMessage.Action] = [.init(id: "stop", title: String(localized: "Spegni"))]
        if waiting {
            actions.append(.init(id: "approve", title: String(localized: "Apri Elementi di login")))
        }
        m.actions = actions
        SystemActivity.show(m) { [weak self] action in
            switch action {
            case "stop": self?.stop()
            case "approve": self?.openApproval()
            default: break
            }
        }
    }

    /// Alla chiusura dell'app: il guardiano rimette il sonno normale.
    func shutdown() {
        claudeGraceTimer?.invalidate()
        claudeGraceTimer = nil
        claudeCheckTimer?.invalidate()
        claudeCheckTimer = nil
        followingClaude = false
        stop(quietly: true)
    }
}

/// Fa girare una riparazione dell'aiutante alla volta: chi arriva mentre una è in corso aspetta quella.
private actor HelperRepairGate {
    static let shared = HelperRepairGate()
    private var running: Task<Bool, Never>?

    func run(_ work: @escaping @Sendable () async -> Bool) async -> Bool {
        if let running { return await running.value }
        let task = Task { await work() }
        running = task
        let result = await task.value
        running = nil
        return result
    }
}

// MARK: - Il «Keep awake» di Claude

/// Il «Keep computer awake while Claude works» dell'app di Claude: un'asserzione di sistema tenuta dal processo di
/// Claude (nel registro di `pmset` si chiama «Electron»). Ferma solo il sonno per inattività. Si legge con
/// `IOPMCopyAssertionsByProcess`, senza permessi, e solo quando gli agenti cambiano.
enum ClaudeAwake {
    static let bundleIDs: Set<String> = ["com.anthropic.claudefordesktop"]
    /// I tipi che tengono sveglio il sistema (non quelli che tengono acceso solo lo schermo, come «Capturing»).
    /// Coi nomi che usa `pmset -g assertions` (le costanti di IOKit sono macro CFSTR e non arrivano in Swift).
    static let types: Set<String> = ["PreventUserIdleSystemSleep", "NoIdleSleepAssertion", "PreventSystemSleep"]

    static func isHeld() -> Bool {
        var raw: Unmanaged<CFDictionary>?
        guard IOPMCopyAssertionsByProcess(&raw) == kIOReturnSuccess,
              let byProcess = raw?.takeRetainedValue() as? [NSNumber: [[String: Any]]] else { return false }
        for (pid, assertions) in byProcess {
            guard assertions.contains(where: { types.contains($0["AssertType"] as? String ?? "") }),
                  let id = NSRunningApplication(processIdentifier: pid.int32Value)?.bundleIdentifier,
                  bundleIDs.contains(id) else { continue }
            return true
        }
        return false
    }
}

// MARK: - Risparmio energetico

/// Quando si accende il Risparmio energetico, l'isola lo dice con un momento compatto, come la campanella del
/// silenzioso su iPhone: la batteria gialla che si riempie e la parola. Spegnendolo non compare niente.
/// Si sveglia solo con l'avviso del sistema: nessun controllo periodico.
@MainActor
final class LowPowerMonitor {
    static let shared = LowPowerMonitor()
    static let activityID = "risparmio-energetico"
    private var observer: NSObjectProtocol?
    private var was = ProcessInfo.processInfo.isLowPowerModeEnabled

    func start() {
        guard observer == nil else { return }
        was = ProcessInfo.processInfo.isLowPowerModeEnabled
        observer = NotificationCenter.default.addObserver(forName: Notification.Name.NSProcessInfoPowerStateDidChange,
                                                          object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { LowPowerMonitor.shared.changed() }
        }
    }

    func stop() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
    }

    private func changed() {
        let now = ProcessInfo.processInfo.isLowPowerModeEnabled
        defer { was = now }
        guard now != was else { return }
        if now { Self.announce() } else { SystemActivity.end(Self.activityID) }
    }

    /// Il momento dell'isola (anche per la scena dimostrativa).
    static func announce() {
        let level = HomeInfo.power()?.level ?? 50
        var m = SystemActivity.message(activityID, template: .status, title: String(localized: "Risparmio energetico"))
        m.status = "lowpower"
        m.symbol = HomeSlotView.symbolFor(level, charging: false)
        m.progress = Double(level) / 100
        m.tint = "yellow"
        m.slots = ["trailing": .init(text: String(localized: "Risparmio"))]
        // La batteria ci mette un paio di secondi a riempirsi: l'avviso non dura meno.
        m.ttl = max(2.4, Features.noticeTTL)
        m.alert = .init(haptic: "done")
        SystemActivity.show(m)
    }
}

/// L'aiutante di sistema visto da Charland: registrazione con SMAppService e chiamate XPC. Le chiusure delle
/// risposte nascono qui, fuori dal thread principale, perché XPC le chiama dal suo thread.
enum PrivilegedHelper {
    nonisolated static var service: SMAppService { SMAppService.daemon(plistName: CharlandHelperInfo.plistName) }

    /// Solo l'app installata in Applicazioni registra l'aiutante: le build di sviluppo no.
    nonisolated static var installedApp: Bool {
        let path = Bundle.main.bundlePath
        return path.hasPrefix("/Applications/") || path.hasPrefix(NSHomeDirectory() + "/Applications/")
    }

    nonisolated static func ensureRegistered() -> SMAppService.Status {
        let s = service
        if s.status == .notRegistered || s.status == .notFound { try? s.register() }
        return s.status
    }

    nonisolated static func openApproval() { SMAppService.openSystemSettingsLoginItems() }

    /// All'avvio di Charland: se l'aiutante è approvato lo sveglia un istante. Appena parte rimette il sonno
    /// normale, così un sonno rimasto spento da un crollo (di Charland o del Mac) torna a posto da solo. Se non risponde
    /// lo ripara subito: dopo un'installazione o un aggiornamento è proprio il momento in cui launchd lo ha perso.
    nonisolated static func wake() {
        guard installedApp, service.status == .enabled else { return }
        Task.detached { _ = await repair() }
    }

    /// L'aiutante risponde davvero. Impostazioni di Sistema lo dà per approvato anche quando launchd non lo ha più:
    /// succede ogni volta che il pacchetto dell'app viene tolto e rimesso (`Scripts/build.sh install`, aggiornamento di
    /// Sparkle), e fino al riavvio del Mac il coperchio chiuso non funzionava. Il 23 novembre 2026 il Mac di carpa ha
    /// dormito tutta la notte con Mantieni attivo acceso: installazione alle 22:32, aiutante sparito da launchd.
    nonisolated static func reachable(timeout: TimeInterval = 3) async -> Bool {
        guard service.status == .enabled else { return false }
        return await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let once = Once()
            let connection = NSXPCConnection(machServiceName: CharlandHelperInfo.label, options: .privileged)
            connection.remoteObjectInterface = NSXPCInterface(with: CharlandHelperProtocol.self)
            connection.resume()
            let box = ConnectionBox(connection)
            let finish: @Sendable (Bool) -> Void = { ok in
                guard once.claim() else { return }
                box.connection.invalidate()
                continuation.resume(returning: ok)
            }
            guard let proxy = box.connection.remoteObjectProxyWithErrorHandler({ _ in finish(false) })
                    as? CharlandHelperProtocol else { finish(false); return }
            proxy.status { _, _ in finish(true) }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { finish(false) }
        }
    }

    /// Rimette in launchd l'aiutante approvato che non risponde: lo toglie e lo registra da capo. Provato il 24 novembre
    /// 2026: una nuova registrazione sopra quella vecchia non serve a niente (nessun errore, launchd resta vuoto); tolto e
    /// registrato torna in launchd, e macOS non chiede di approvarlo di nuovo. Subito dopo averlo tolto però la
    /// registrazione viene rifiutata («Operation not permitted»): si riprova per qualche secondo. Dice se alla fine
    /// risponde. `log` per `--helper-repair`.
    /// `force` (solo per le prove, `--helper-repair-force`): lo toglie e lo rimette anche se risponde.
    nonisolated static func repair(force: Bool = false, log: (@Sendable (String) -> Void)? = nil) async -> Bool {
        // Una alla volta: all'avvio possono chiederla insieme `wake()` e il primo agente, e due «togli e rimetti»
        // intrecciati lascerebbero l'aiutante tolto.
        await HelperRepairGate.shared.run { await repairNow(force: force, log: log) }
    }

    nonisolated private static func repairNow(force: Bool, log: (@Sendable (String) -> Void)?) async -> Bool {
        guard installedApp else { log?("non è la copia in Applicazioni"); return false }
        log?("stato: \(describe(service.status))")
        guard service.status == .enabled else { return false }
        if !force, await reachable() { log?("risponde"); return true }
        log?("approvato ma non risponde: lo tolgo e lo registro da capo")
        do { try await service.unregister(); log?("tolto") } catch { log?("togliendo: \(error.localizedDescription)") }
        for attempt in 1...20 {
            try? await Task.sleep(for: .milliseconds(500))
            do {
                try service.register()
                log?("registrato al tentativo \(attempt)")
                break
            } catch {
                if attempt == 20 { log?("registrazione: \(error.localizedDescription)") }
            }
        }
        log?("stato: \(describe(service.status))")
        let ok = await reachable()
        log?(ok ? "ora risponde" : "non risponde")
        return ok
    }

    nonisolated static func describe(_ status: SMAppService.Status) -> String {
        switch status {
        case .enabled: "attivo"
        case .requiresApproval: "da approvare in Impostazioni di Sistema"
        case .notRegistered: "non registrato"
        case .notFound: "non trovato nel pacchetto"
        @unknown default: "sconosciuto"
        }
    }

    nonisolated static func attachHandlers(_ connection: NSXPCConnection) {
        connection.invalidationHandler = { Task { @MainActor in KeepAwake.shared.helperDropped() } }
        connection.interruptionHandler = { Task { @MainActor in KeepAwake.shared.helperDropped() } }
    }

    nonisolated static func request(_ box: ConnectionBox, on: Bool, deadline: Double) {
        let proxy = box.connection.remoteObjectProxyWithErrorHandler { _ in
            Task { @MainActor in KeepAwake.shared.helperReplied(false, on: on) }
        } as? CharlandHelperProtocol
        proxy?.setClosedLidAwake(on, deadline: deadline) { ok in
            Task { @MainActor in KeepAwake.shared.helperReplied(ok, on: on) }
        }
    }
}

// MARK: - Timer

/// I timer dell'isola: conto alla rovescia, "Ferma" e "+1 min", e alla fine un avviso che si vede,
/// si sente e si tocca.
@MainActor
final class TimerCenter {
    static let shared = TimerCenter()
    private var timers: [String: (end: Date, title: String, started: Date, fire: Timer)] = [:]

    static let presets: [(label: String, seconds: TimeInterval)] = [
        ("1 min", 60), ("5 min", 300), ("10 min", 600), ("25 min", 1500), ("1 h", 3600),
    ]

    /// `id` quando arriva dal comando `charland timer`: così `charland update` e `charland end` lo ritrovano.
    /// Restituisce l'id, per dargli un nome dopo (`rename`).
    @discardableResult
    func start(seconds: TimeInterval, title: String = String(localized: "Timer"), id: String? = nil) -> String {
        let id = id ?? "timer-\(Int(Date().timeIntervalSince1970 * 10))-\(UInt16.random(in: 0...UInt16.max))"
        schedule(id: id, end: Date().addingTimeInterval(seconds), title: title)
        return id
    }

    /// Il nome scritto dopo aver lasciato la goccia: l'isola lo mostra sopra il tempo, e l'avviso di fine lo dice.
    func rename(id: String, title: String) {
        guard let timer = timers[id] else { return }
        schedule(id: id, end: timer.end, title: title, started: timer.started)
    }


    /// Tutti fermi, senza avviso.
    func cancelAll() {
        for id in Array(timers.keys) { cancel(id: id) }
    }

    /// Ferma un timer senza l'avviso di fine. `false` se non c'è.
    @discardableResult
    func cancel(id: String) -> Bool {
        guard let timer = timers.removeValue(forKey: id) else { return false }
        timer.fire.invalidate()
        SystemActivity.end(id)
        return true
    }

    private func schedule(id: String, end: Date, title: String, started: Date = Date()) {
        timers[id]?.fire.invalidate()
        let fire = Timer(timeInterval: max(0.1, end.timeIntervalSinceNow), repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.finished(id) }
        }
        RunLoop.main.add(fire, forMode: .common)
        timers[id] = (end, title, started, fire)
        var m = SystemActivity.message(id, template: .countdown, title: title)
        m.endsAt = end.timeIntervalSince1970
        m.startedAt = started.timeIntervalSince1970
        m.symbol = "timer"
        m.tint = "orange"
        m.actions = [.init(id: "stop", title: String(localized: "Ferma")), .init(id: "more", title: "+1 min")]
        SystemActivity.show(m) { [weak self] action in
            guard let self, let timer = self.timers[id] else { return }
            switch action {
            case "stop":
                timer.fire.invalidate()
                self.timers[id] = nil
                SystemActivity.end(id)
            case "more":
                self.schedule(id: id, end: timer.end.addingTimeInterval(60), title: timer.title, started: timer.started)
            default: break
            }
        }
    }

    private func finished(_ id: String) {
        guard let timer = timers.removeValue(forKey: id) else { return }
        var m = SystemActivity.message(id, template: .status, title: timer.title)
        m.status = "done"
        m.symbol = "timer"
        m.tint = "orange"
        m.alert = .init(expand: true, haptic: "done")
        // Il suono scelto in Generale (carpa: «suono di notifica come una sveglia oppure di poterlo togliere»).
        switch TimerSound.current {
        case .alarm:
            // Suona finché non la fermi dall'isola; da sola smette dopo un minuto, e l'avviso se ne va con lei.
            m.ttl = AlarmPlayer.limit
            m.actions = [.init(id: "stop", title: String(localized: "Ferma"))]
            AlarmPlayer.shared.start(id: id)
            // Ferma chiude l'avviso, e la sveglia smette con lui (`AlarmPlayer.ended`).
            SystemActivity.show(m) { action in
                guard action == "stop" else { return }
                SystemActivity.end(id)
            }
        case .chime:
            m.ttl = Features.noticeTTL
            SystemActivity.show(m)
            NSSound(named: "Glass")?.play()
        case .off:
            m.ttl = Features.noticeTTL
            SystemActivity.show(m)
        }
    }
}

/// Cosa suona quando un timer finisce.
enum TimerSound: String, CaseIterable, Identifiable {
    /// Come la sveglia dell'iPhone: si ripete finché non la fermi (al massimo un minuto).
    case alarm
    /// Un suono solo.
    case chime
    /// Niente: solo l'isola che si apre e il tocco sul trackpad.
    case off

    var id: String { rawValue }

    var title: String {
        switch self {
        case .alarm: String(localized: "Sveglia")
        case .chime: String(localized: "Un suono")
        case .off: String(localized: "Nessuno")
        }
    }

    @MainActor static var current: TimerSound {
        get { TimerSound(rawValue: UserDefaults.standard.string(forKey: "timerSound") ?? "") ?? .alarm }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "timerSound") }
    }
}

/// La sveglia: il suono «Radar» dell'iPhone, che il Mac ha fra i suoi toni, in ripetizione. Se un giorno non c'è più,
/// il suono «Glass» di sistema.
@MainActor
final class AlarmPlayer {
    static let shared = AlarmPlayer()
    static let limit: Double = 60
    private static let radar = URL(fileURLWithPath:
        "/System/Library/PrivateFrameworks/ToneLibrary.framework/Versions/A/Resources/Ringtones/Radar.m4r")

    private var sound: NSSound?
    private var stopTimer: Timer?
    /// I timer finiti che stanno suonando: il suono è uno, smette quando non ne resta nessuno. Così, con due timer
    /// finiti insieme, fermarne uno non zittisce l'altro.
    private var ringing: Set<String> = []

    /// Una sveglia vera sta suonando (la prova delle impostazioni non la interrompe).
    var isRinging: Bool { !ringing.isEmpty }

    /// La sveglia di un timer finito.
    func start(id: String) {
        ringing.insert(id)
        if sound?.isPlaying != true { play(for: Self.limit) }
    }

    /// L'avviso di quel timer se n'è andato.
    func ended(id: String) {
        guard ringing.remove(id) != nil, ringing.isEmpty else { return }
        stopSound()
    }

    /// La prova dalle impostazioni: qualche secondo, mai sopra una sveglia vera.
    func preview(seconds: Double = 3) {
        guard !isRinging else { return }
        play(for: seconds)
    }

    /// Tutto zitto (Charland si chiude).
    func stop() {
        ringing.removeAll()
        stopSound()
    }

    private func play(for seconds: Double) {
        stopSound()
        let sound = NSSound(contentsOf: Self.radar, byReference: true) ?? NSSound(named: "Glass")
        sound?.loops = true
        sound?.play()
        self.sound = sound
        let timer = Timer(timeInterval: seconds, repeats: false) { _ in
            MainActor.assumeIsolated { AlarmPlayer.shared.stop() }
        }
        RunLoop.main.add(timer, forMode: .common)
        stopTimer = timer
    }

    private func stopSound() {
        sound?.stop()
        sound = nil
        stopTimer?.invalidate()
        stopTimer = nil
    }
}

// MARK: - Batteria

/// La batteria: quando scende al 20% e al 10% (a batteria) e quando colleghi il caricatore.
/// Si sveglia solo quando il sistema avvisa di un cambiamento: nessun controllo periodico.
@MainActor
final class BatteryMonitor {
    static let shared = BatteryMonitor()
    static let activityID = "batteria"

    private var source: CFRunLoopSource?
    private var lastLevel: Int?
    private var lastCharging: Bool?
    /// Le soglie già avvisate in questa scarica.
    private var warned: Set<Int> = []

    func start() {
        guard source == nil else { return }
        let callback: IOPowerSourceCallbackType = { _ in
            MainActor.assumeIsolated { BatteryMonitor.shared.changed() }
        }
        guard let created = IOPSNotificationCreateRunLoopSource(callback, nil)?.takeRetainedValue() else { return }
        CFRunLoopAddSource(CFRunLoopGetMain(), created, .commonModes)
        source = created
        if let power = HomeInfo.power() {
            HomeInfo.cachedPower = power
            lastLevel = power.level
            lastCharging = power.charging || Self.onAC
        }
    }

    func stop() {
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        source = nil
        HomeInfo.cachedPower = nil
    }

    static var onAC: Bool {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String? else { return false }
        return type == kIOPMACPowerKey
    }

    private func changed() {
        guard let power = HomeInfo.power() else { return }
        HomeInfo.cachedPower = power
        let plugged = power.charging || Self.onAC
        defer {
            lastLevel = power.level
            lastCharging = plugged
        }
        if plugged {
            warned.removeAll()
            if lastCharging == false {
                // Caricatore collegato: la batteria con il fulmine, per un attimo.
                var m = SystemActivity.message(Self.activityID, template: .status, title: String(localized: "In carica"))
                m.symbol = "battery.100percent.bolt"
                m.tint = "green"
                m.slots = ["trailing": .init(text: "\(power.level)%")]
                m.ttl = Features.noticeTTL
                m.alert = .init(haptic: "done")
                SystemActivity.show(m)
            }
            return
        }
        for threshold in [20, 10] where power.level <= threshold && !warned.contains(threshold) {
            warned.insert(threshold)
            var m = SystemActivity.message(Self.activityID, template: .status,
                                           title: String(localized: "Batteria al \(power.level)%"))
            m.symbol = threshold == 10 ? "battery.0percent" : "battery.25percent"
            m.tint = threshold == 10 ? "red" : "orange"
            m.slots = ["trailing": .init(text: "\(power.level)%")]
            m.subtitle = String(localized: "Collega il caricatore")
            m.priority = 2
            m.ttl = Features.noticeTTL
            m.alert = .init(expand: true, haptic: threshold == 10 ? "error" : "waiting")
            SystemActivity.show(m)
            if threshold == 10, KeepAwake.shared.active { KeepAwake.shared.stop() }
        }
    }
}

// MARK: - Registrazione dello schermo

/// Lo schermo registrato o condiviso (lo strumento di macOS, QuickTime, una chiamata).
/// Lo dice una funzione interna del sistema, cercata a runtime: se manca, la funzione si spegne.
/// Si controlla ogni due secondi con tolleranza, e si mostra solo dopo due controlli di fila,
/// così uno screenshot non la fa comparire per un attimo.
@MainActor
final class RecordingMonitor {
    static let shared = RecordingMonitor()
    static let activityID = "registrazione"
    /// La scelta nelle impostazioni (Generale, Funzioni). Spenta di serie.
    static let settingKey = "featureRecordingAlert"
    static var enabled: Bool { UserDefaults.standard.bool(forKey: settingKey) }

    private typealias Present = @convention(c) () -> Bool
    private static let present: Present? = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGSIsScreenWatcherPresent")
        .map { unsafeBitCast($0, to: Present.self) }

    private var timer: Timer?
    private var streak = 0
    private var since: Date?
    private var shown = false

    static var isAvailable: Bool { present != nil }

    func start() {
        guard Self.enabled, timer == nil, Self.present != nil else { return }
        let t = Timer(timeInterval: 2, repeats: true) { _ in
            MainActor.assumeIsolated { RecordingMonitor.shared.check() }
        }
        t.tolerance = 1
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        if shown { SystemActivity.end(Self.activityID) }
        shown = false
        streak = 0
        since = nil
    }

    private func check() {
        let on = Self.present?() ?? false
        if on {
            streak += 1
            if since == nil { since = Date().addingTimeInterval(-2) }
            if streak >= 2, !shown {
                shown = true
                var m = SystemActivity.message(Self.activityID, template: .status,
                                               title: String(localized: "Schermo registrato o condiviso"))
                m.symbol = "record.circle.fill"
                m.tint = "red"
                m.status = "recording"
                m.startedAt = (since ?? Date()).timeIntervalSince1970
                m.actions = [.init(id: "stop", title: String(localized: "Ferma la registrazione"))]
                SystemActivity.show(m) { action in
                    if action == "stop" { RecordingMonitor.stopSystemRecording() }
                }
            }
        } else {
            streak = 0
            since = nil
            if shown {
                shown = false
                SystemActivity.end(Self.activityID)
            }
        }
    }

    /// ⌘⌃Esc: la scorciatoia di macOS che ferma la registrazione dello schermo.
    static func stopSystemRecording() {
        let source = CGEventSource(stateID: .combinedSessionState)
        for down in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: 53, keyDown: down) else { continue }
            event.flags = [.maskCommand, .maskControl]
            event.post(tap: .cghidEventTap)
        }
    }
}
