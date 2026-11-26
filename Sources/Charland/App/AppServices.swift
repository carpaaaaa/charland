import AppKit
import SwiftUI
import ServiceManagement
import CharlandCore

/// I servizi dell'app vera (non delle scene dimostrative): finestra delle impostazioni,
/// voce, tasti, agenti, agenda, API. Ognuno si accende solo se la sua funzione è accesa.
@MainActor
final class AppServices {
    static let shared = AppServices()
    private var settingsWindow: NSWindow?
    private var started = false
    private lazy var pointer = PointerTracker(hub: .shared)

    private init() {}

    func start(showWindow: Bool = true) {
        guard !started else { return }
        started = true
        enableLoginItemOnFirstRun()
        pointer.start()
        TrayStore.shared.prune()
        wireIslands()
        // Le isole si ricreano quando cambiano gli schermi: l'aggancio va rimesso su quelle nuove (prima, dopo aver
        // collegato un monitor, un file lasciato nel vassoio non teneva più aperta la casa).
        IslandHub.shared.onRebuild = { [weak self] in self?.wireIslands() }
        DictationController.shared.start()
        // Se l'app è caduta due volte di fila mentre ascoltava i tasti speciali (entro pochi minuti dall'avvio), quella
        // funzione resta spenta finché non la riaccendi tu. Una caduta sola non la spegne più.
        if MediaKeys.crashedWhileActive {
            UserDefaults.standard.set(false, forKey: "mediaKeysActive")
            if MediaKeys.noteCrash() { Features.shared.mediaKeys = false }
        }
        Features.shared.apply()
        // Lo storico degli appunti (clic sulla farfalla) e la sua scorciatoia, se acceso.
        ClipboardHistory.shared.apply()
        BatteryMonitor.shared.start()
        RecordingMonitor.shared.start()
        LowPowerMonitor.shared.start()
        KeepAwake.shared.registerShortcut()
        // Chiudi tutte le app (scorciatoia) e la x rossa che chiude.
        AppQuitter.shared.start()
        // Lo slider sul bordo pronto prima del primo tasto: la goccia nasce senza fotogrammi persi.
        SideSlider.shared.warmUp()
        PrivilegedHelper.wake()
        // I widget accanto al Dock: si accendono solo se sono accesi nelle impostazioni.
        DockBar.shared.start()
        // La barra di ricerca che esce dal Dock (Impostazioni › Ricerca): prende ⌘spazio solo se è accesa.
        // Il righello della giornata sul bordo (Impostazioni › Righello): solo un ascolto del puntatore finché non esce.
        DayRuler.shared.start()
        // Lo sfondo di Charland (Impostazioni › Sfondo): ridisegna se cambiano gli schermi.
        WallpaperSettings.shared.start()
        // La finestra si apre sulla Voce finché la dettatura non è pronta: la prima cosa che si vede è la
        // guida che dice cosa manca.
        if showWindow { showSettings(section: VoiceSettings.shared.enabled && !DictationSetup.isReady ? .voice : nil) }
    }


    /// Un file appena lasciato: la casa resta aperta col vassoio finché il puntatore non se ne va.
    private func wireIslands() {
        for island in IslandHub.shared.islands {
            island.onDropped = { [weak self, weak island] in
                guard let self, let island else { return }
                self.pointer.adoptOpen(island)
            }
        }
    }

    func stop() {
        IslandHub.shared.onRebuild = nil
        pointer.stop()
        AppQuitter.shared.stop()
        DockBar.shared.stop()
        DayRuler.shared.stop()
        KeepAwake.shared.shutdown()
        BatteryMonitor.shared.stop()
        RecordingMonitor.shared.stop()
        LowPowerMonitor.shared.stop()
        FocusMonitor.shared.stop()
        NowPlayingMonitor.shared.stop()
        LockScreen.shared.stop()
        AgentWatchers.stop()
        // I timer prima della sveglia: uno che scadesse dopo il blocco la farebbe suonare per un minuto.
        TimerCenter.shared.cancelAll()
        AlarmPlayer.shared.stop()
        WeatherStore.shared.stop()
        AgendaStore.shared.stop()
        MediaKeys.shared.stop()
        MenuBarItem.shared.setShown(false)
        ClipboardHistory.shared.stop()
        ActivityCenter.shared.stop()
        DictationController.shared.stop()
        VoiceEngineClient.shared.shutdown()
        // Tutte le scorciatoie, anche quelle che nessuno qui sopra toglieva (Mantieni attivo, lo storico degli appunti):
        // restavano vive dopo lo stop, e ⇧⌘C riapriva il menu e ricominciava a registrare le copie.
        HotkeyCenter.shared.unregisterAll()
        started = false
    }

    /// Al primo avvio dell'app installata, Charland si aggiunge agli elementi di login: si apre
    /// da sola a ogni accensione. Una volta sola: se poi la spegni in Generale, resta spenta.
    /// Le build di sviluppo (fuori da Applicazioni) non si registrano.
    private func enableLoginItemOnFirstRun() {
        let key = "loginItemDefaultApplied"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        let path = Bundle.main.bundlePath
        let installed = path.hasPrefix("/Applications/") || path.hasPrefix(NSHomeDirectory() + "/Applications/")
        guard installed else { return }
        do {
            if SMAppService.mainApp.status != .enabled {
                try SMAppService.mainApp.register()
            }
            UserDefaults.standard.set(true, forKey: key)
        } catch {
            // Riprova al prossimo avvio.
        }
    }

    /// Apre la finestra delle impostazioni; con `section`, già su quella sezione.
    func showSettings(section: SettingsSection? = nil) {
        if let section { SettingsNavigation.shared.section = section }
        if settingsWindow == nil {
            let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 860, height: 600),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                                  backing: .buffered, defer: false)
            window.title = Identity.name
            window.titlebarAppearsTransparent = true
            window.toolbarStyle = .unified
            window.isReleasedWhenClosed = false
            window.contentViewController = NSHostingController(rootView: SettingsRoot())
            window.setContentSize(CGSize(width: 860, height: 600))
            window.center()
            window.setFrameAutosaveName("impostazioni")
            settingsWindow = window
        }
        // Un'app senza icona nel Dock non diventa mai l'app attiva: la finestra resterebbe inattiva, coi controlli
        // grigi. Con la finestra aperta Charland è un'app normale.
        if NSApp.activationPolicy() != .regular { NSApp.setActivationPolicy(.regular) }
        NSApp.activate()
        settingsWindow?.makeKeyAndOrderFront(nil)
    }
}
