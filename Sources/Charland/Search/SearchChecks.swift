import AppKit

/// Per le prove: `Charland --ricerca` accende solo la barra di ricerca, senza isola, accanto alla Charland installata
/// (spegnere prima la ricerca in quella installata, se no le due intercettazioni si contendono la scorciatoia). Da
/// terminale si comanda con la notifica `com.charstudio.charland.ricerca`: `apri`, `chiudi`, `scrivi:<testo>`, `invio`,
/// `su`, `giu`, `esc`, `stato` (stampa righe, selezione e misure), `iphone:<nome>` (la ricerca di macOS col nome
/// scritto, senza confermare). `CHARLAND_RICERCA=1` scrive le tracce.
@MainActor
enum SearchTest {
    static func start() {
        NSApp.setActivationPolicy(.accessory)
        SearchBar.shared.start()
        // Accanto alla Charland installata la scorciatoia resta sua: le due intercettazioni se la contenderebbero, e un
        // ⌘spazio vero di chi usa il Mac aprirebbe la copia di prova (`CHARLAND_RICERCA_SENZA_SCORCIATOIA=1`).
        if ProcessInfo.processInfo.environment["CHARLAND_RICERCA_SENZA_SCORCIATOIA"] != nil { SearchHotkey.shared.stop() }
        DistributedNotificationCenter.default().addObserver(forName: Notification.Name("com.charstudio.charland.ricerca"),
                                                            object: nil, queue: .main) { note in
            let command = note.object as? String ?? ""
            MainActor.assumeIsolated { run(command) }
        }
        print("[ricerca] pronta: scorciatoia \(SearchSettings.shared.combo.display), stato \(SearchSettings.shared.hotkey)")
        fflush(stdout)
    }

    private static func run(_ command: String) {
        let bar = SearchBar.shared
        switch command {
        case "apri": if !bar.isOpen { bar.open() }
        case "chiudi": bar.close(animated: true)
        case "invio": key(36)
        case "su": key(126)
        case "giu": key(125)
        case "esc": key(53)
        case "stato": report()
        default:
            if command.hasPrefix("scrivi:") { bar.model.query = String(command.dropFirst(7)) }
            // `comando:<lettera>`: ⌘ e la lettera, dentro questa copia sola (mai all'app davanti).
            if command.hasPrefix("comando:"), let letter = command.dropFirst(8).first {
                let codes: [Character: UInt16] = ["q": 12, "w": 13, "h": 4, "m": 46, "c": 8, "v": 9, "a": 0, "1": 18, "2": 19]
                key(codes[letter] ?? 0, characters: String(letter), flags: .command)
            }
            // `analizza:<testo>`: cosa diventerebbe la frase (azione, calcolo), senza aprire niente.
            if command.hasPrefix("analizza:") {
                let text = String(command.dropFirst(9))
                let action = SearchCommand.parse(text).map { "\($0.title) · \($0.subtitle)" } ?? "nessuna"
                let strict = SearchCommand.parse(text, strict: true) != nil ? "sì" : "no"
                let calc = SearchCalculator.evaluate(text)?.display ?? "no"
                print("[ricerca] «\(text)» azione: \(action) | per Chiedi: \(strict) | calcolo: \(calc)")
                fflush(stdout)
            }
            // `iphone:<nome>`: apre la ricerca di macOS e ci scrive il nome, senza confermare.
            if command.hasPrefix("iphone:") { SearchLaunch.openIPhoneApp(named: String(command.dropFirst(7)), confirm: false) }
        }
    }

    /// Un tasto come lo riceverebbe la barra.
    private static func key(_ code: UInt16, characters: String = "", flags: NSEvent.ModifierFlags = []) {
        guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                                           windowNumber: 0, context: nil, characters: characters, charactersIgnoringModifiers: characters,
                                           isARepeat: false, keyCode: code) else { return }
        NSApp.postEvent(event, atStart: false)
    }

    private static func report() {
        let bar = SearchBar.shared
        let model = bar.model
        print("[ricerca] aperta=\(bar.isOpen) testo=«\(model.query)» scelta=\(model.selected ?? "nessuna") righe=\(model.results.count)")
        for result in model.results { print("   \(result.id == model.selected ? "›" : " ") \(result.kind) \(result.title) · \(result.subtitle) · \(Int(result.score))") }
        if let answer = model.answer { print("   risposta (fatta=\(answer.done), errore=\(answer.failed)): \(answer.text.prefix(400))") }
        print("   forma \(bar.shape.outline.boundingRect) campo \(bar.shape.field) elenco \(bar.shape.listHeight)")
        print("   puntatore \(bar.pointerReport)")
        fflush(stdout)
    }
}
