import AppKit
import CharlandCore

/// La barra dei menu di Charland: il menu dell'app, Modifica e Finestra, come ogni app del Mac.
///
/// Charland nasce senza storyboard, quindi senza menu: senza il menu Modifica ⌘V, ⌘C, ⌘X, ⌘A e ⌘Z non arrivano a nessun
/// campo di testo delle impostazioni (carpa non riusciva a incollare il token di Charcal). Le voci di Modifica non hanno
/// un destinatario: vanno a chi ha il cursore, il campo di testo attivo.
@MainActor
enum MainMenu {
    static func install() {
        let name = Identity.name
        let bar = NSMenu()

        let app = NSMenu(title: name)
        app.addItem(withTitle: String(localized: "Informazioni su \(name)"),
                    action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        let updates = NSMenuItem(title: String(localized: "Cerca aggiornamenti…"), action: #selector(MenuActions.checkForUpdates(_:)), keyEquivalent: "")
        updates.target = MenuActions.shared
        app.addItem(updates)
        app.addItem(.separator())
        let settings = NSMenuItem(title: String(localized: "Impostazioni…"), action: #selector(MenuActions.showSettings(_:)), keyEquivalent: ",")
        settings.target = MenuActions.shared
        app.addItem(settings)
        app.addItem(.separator())
        app.addItem(withTitle: String(localized: "Nascondi \(name)"), action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let others = app.addItem(withTitle: String(localized: "Nascondi altre"),
                                 action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        others.keyEquivalentModifierMask = [.command, .option]
        app.addItem(withTitle: String(localized: "Mostra tutte"), action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        app.addItem(.separator())
        app.addItem(withTitle: String(localized: "Esci da \(name)"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        bar.addItem(submenu(app))

        let edit = NSMenu(title: String(localized: "Modifica"))
        // Chiave sua: «Annulla» dei pulsanti in inglese è «Cancel», qui è «Undo».
        edit.addItem(withTitle: String(localized: "menu.undo", defaultValue: "Annulla"), action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: String(localized: "Ripristina"), action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: String(localized: "Taglia"), action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: String(localized: "Copia"), action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: String(localized: "Incolla"), action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: String(localized: "Seleziona tutto"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        bar.addItem(submenu(edit))

        let window = NSMenu(title: String(localized: "Finestra"))
        window.addItem(withTitle: String(localized: "Chiudi"), action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        window.addItem(withTitle: String(localized: "Riduci a icona"), action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        bar.addItem(submenu(window))
        NSApp.windowsMenu = window

        NSApp.mainMenu = bar
    }

    private static func submenu(_ menu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: menu.title, action: nil, keyEquivalent: "")
        item.submenu = menu
        return item
    }
}

/// Il destinatario delle voci di menu che non sono di AppKit.
@MainActor
final class MenuActions: NSObject {
    static let shared = MenuActions()

    @objc func showSettings(_ sender: Any?) {
        AppServices.shared.showSettings()
    }

    @objc func checkForUpdates(_ sender: Any?) {
        Updates.shared.checkNow()
    }
}
