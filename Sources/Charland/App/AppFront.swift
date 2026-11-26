import AppKit
import ApplicationServices

/// Porta davanti un'app come un clic sulla sua icona nel Dock: anche se era nascosta o con le finestre ridotte nel Dock
/// (carpa, 18 novembre 2026: «se l'app è minimizzata la mascotte non la porta in primo piano; deve farlo con tutto,
/// anche ChatGPT, Gemini, la musica e il resto»).
///
/// Tre cose, in quest'ordine:
/// 1. Charland si attiva un istante e cede il posto all'app: i pannelli di Charland non attivano l'app, e da macOS 14
///    un'app non attiva che ne attiva un'altra la lascia dietro le finestre di prima;
/// 2. l'app riceve la «riapertura», la stessa del clic sull'icona nel Dock: le app di sistema rimettono su una finestra
///    ridotta, quelle fatte con Electron (Claude, ChatGPT) mostrano la loro;
/// 3. con l'Accessibilità, se l'app non ha ancora una finestra visibile, si riapre la finestra ridotta (quella col titolo
///    cercato, se c'è) e si porta su. `activate` da solo non tocca le finestre ridotte: per questo prima la mascotte
///    portava davanti un'app senza niente da vedere.
@MainActor
enum AppFront {
    static func bring(_ app: NSRunningApplication, titled title: String? = nil, reopen: Bool = true) {
        app.unhide()
        NSApp.activate()
        NSApp.yieldActivation(to: app)
        if reopen, let url = app.bundleURL {
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, _ in }
        } else {
            _ = app.activate(from: .current, options: [])
        }
        restoreWindows(of: app, titled: title)
    }

    /// Solo il punto 3: per chi ha già attivato l'app per conto suo (uno script, l'apertura di un'app appena lanciata).
    static func restoreWindows(of app: NSRunningApplication, titled title: String? = nil) {
        app.unhide()
        let pid = app.processIdentifier
        DispatchQueue.global(qos: .userInitiated).async {
            // L'app riaperta può metterci un attimo a rispondere, e la sua finestra a rientrare da sola: si guarda subito
            // e di nuovo poco dopo, e si fa solo quello che manca.
            for delay in [0.0, 0.35] {
                if delay > 0 { Thread.sleep(forTimeInterval: delay) }
                if restore(pid: pid, titled: title) { return }
            }
        }
    }

    /// Riapre e porta su la finestra giusta. `true` se l'app ha adesso una finestra visibile davanti.
    private nonisolated static func restore(pid: pid_t, titled title: String?) -> Bool {
        guard AXIsProcessTrusted() else { return false }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.4)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement], !windows.isEmpty else { return false }
        func string(_ window: AXUIElement, _ name: String) -> String? {
            var v: CFTypeRef?
            return AXUIElementCopyAttributeValue(window, name as CFString, &v) == .success ? v as? String : nil
        }
        func minimized(_ window: AXUIElement) -> Bool {
            var v: CFTypeRef?
            return AXUIElementCopyAttributeValue(window, kAXMinimizedAttribute as CFString, &v) == .success && (v as? Bool) == true
        }
        let standard = windows.filter { string($0, kAXSubroleAttribute) == kAXStandardWindowSubrole as String }
        var target: AXUIElement?
        if let title, !title.isEmpty {
            target = standard.first { string($0, kAXTitleAttribute)?.localizedCaseInsensitiveContains(title) == true }
        }
        if target == nil {
            // Con una finestra già visibile non c'è niente da riaprire: ci pensa l'attivazione.
            if standard.contains(where: { !minimized($0) }) { return true }
            target = standard.first(where: minimized)
        }
        guard let target else { return false }
        if minimized(target) {
            AXUIElementSetAttributeValue(target, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
        }
        AXUIElementSetAttributeValue(target, kAXMainAttribute as CFString, kCFBooleanTrue)
        AXUIElementPerformAction(target, kAXRaiseAction as CFString)
        // L'app davanti anche dall'Accessibilità: vale anche se nel frattempo l'attivazione ceduta è scaduta.
        AXUIElementSetAttributeValue(app, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
        return true
    }
}
