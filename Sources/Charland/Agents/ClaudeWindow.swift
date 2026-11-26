import AppKit
import ApplicationServices
import CharlandCore

/// Le finestre di un'app, anche quelle su un'altra scrivania: l'elemento di una finestra si crea dal suo numero (la
/// tecnica usata anche da AltTab, GPL-3.0; il codice qui è scritto per Charland). L'elenco normale dell'Accessibilità dà solo le finestre della scrivania in cui sei, e
/// l'app di Claude a tutto schermo sta quasi sempre su una sua.
@_silgen_name("_AXUIElementCreateWithRemoteToken")
private func _AXUIElementCreateWithRemoteToken(_ data: CFData) -> Unmanaged<AXUIElement>?

/// Preme al posto tuo un pulsante nella finestra dell'app di Claude (carpa, 19 novembre 2026: «Sì, prova»).
///
/// Serve per le risposte del riquadro di fine turno. Claude non offre un modo per mandare una risposta a una sessione
/// da fuori, e quella che arriva da un gancio la marca (giustamente) come «non è un messaggio dell'utente». Il
/// pulsante vero, premuto nella sua finestra, manda invece un messaggio normale: è la tua risposta, data dall'isola.
///
/// Come: con l'Accessibilità si legge la finestra, si cerca la domanda e subito dopo il pulsante col titolo esatto,
/// e lo si preme. Se la finestra mostra un'altra conversazione si preme la sua riga nella barra laterale, come un
/// clic, e a cosa fatta si torna su quella di prima allo stesso modo.
///
/// **Claude non viene mai davanti** (carpa: «approvi o risponda e basta senza per forza aprirti Claude in primo
/// piano… se vuoi portare Claude in primo piano c'è Apri o premi la mascotte»). Per questo niente indirizzo
/// `claude://`: l'app di Claude, ricevuto un indirizzo, mostra la finestra e la porta davanti (nel suo codice,
/// `open-url` fa `show()` e `focus()`). Se domanda, pulsante o riga della conversazione non ci sono, non si preme
/// niente e la richiesta torna nell'isola.
///
/// **Con la finestra che non si vede** (Claude a tutto schermo su un'altra scrivania) l'app la rallenta: i clic
/// arrivano con secondi di ritardo, e i cambi si leggono ancora più tardi. Per questo si aspetta a lungo, e alla
/// conversazione di prima si torna solo quando la sessione ha davvero ripreso a lavorare (il suo stato in
/// `~/.claude/sessions` passa a «busy»): il 19 novembre un ritorno premuto troppo presto è finito in coda prima della
/// risposta, e la risposta si è persa.
enum ClaudeWindow {
    static let bundle = "com.anthropic.claudefordesktop"

    /// Charland può leggere e premere nelle finestre delle altre app (permesso di Accessibilità).
    static var canPress: Bool { AXIsProcessTrusted() }

    private struct Node {
        enum Kind { case button, text, heading }
        var kind: Kind
        var text: String
        var element: AXUIElement
        /// Nella barra degli strumenti della conversazione mostrata (il suo titolo, il pulsante per rinominarla).
        var inToolbar: Bool
    }

    private static let queue = DispatchQueue(label: "finestra-di-claude", qos: .userInitiated)

    /// Quanto si aspetta che la conversazione giusta compaia, e che la sessione riparta dopo il clic. Con la finestra
    /// visibile bastano pochi decimi; su un'altra scrivania anche dieci secondi.
    static let switchWait: TimeInterval = 25
    static let replyWait: TimeInterval = 30

    /// Preme la risposta `label` alla domanda `ask` nella conversazione che nella barra laterale si chiama
    /// `conversation` (`nil`: solo se è già quella mostrata) e che in Claude Code è la sessione `session`. `done`
    /// arriva sul thread principale: `true` se la risposta è arrivata alla sessione.
    static func reply(label: String, ask: String, conversation: String?, session: String,
                      done: @escaping @MainActor (Bool) -> Void) {
        queue.async {
            let sent = press(label: label, ask: ask, conversation: conversation, session: session)
            DispatchQueue.main.async { MainActor.assumeIsolated { done(sent) } }
        }
    }

    /// La sessione ha ripreso a lavorare dopo `moment`: la risposta le è arrivata. Si legge lo stato che Claude Code
    /// scrive da sé, che non dipende da quanto l'app rallenta la finestra.
    private static func resumed(_ session: String, after moment: Date) -> Bool {
        let folder = ProcessInfo.processInfo.environment["CHARLAND_CLAUDE_SESSIONS"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/sessions", isDirectory: true)
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        for file in files where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file), let record = ClaudeSessionRecord(json: data), record.sessionID == session
            else { continue }
            return record.status == "busy" && (record.statusUpdatedAt ?? 0) >= moment.timeIntervalSince1970 - 0.5
        }
        return false
    }

    private static func press(label: String, ask: String, conversation: String?, session: String) -> Bool {
        guard canPress, let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundle).first else {
            note("niente da fare: \(canPress ? "Claude non è aperta" : "manca il permesso di Accessibilità")")
            return false
        }
        let root = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(root, 2)
        // L'app di Claude è fatta con Electron: l'albero dei contenuti si accende solo se glielo si chiede.
        _ = AXUIElementSetAttributeValue(root, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        let windows = self.windows(of: app.processIdentifier, root: root)
        var nodes = collect(windows)
        let start = shown(in: nodes)

        let began = Date()
        func ms(_ from: Date) -> String { "\(Int(Date().timeIntervalSince(from) * 1000)) ms" }

        // Già sulla conversazione giusta (o non si sa quale sia: allora vale solo se la domanda è sullo schermo).
        if conversation == nil || start == conversation, let target = find(label: label, ask: ask, in: nodes) {
            let pressedAt = Date()
            let press = tap(target)
            guard press != .refused else {
                note("«\(label)» per «\(ask.prefix(60))»: pressione rifiutata")
                return false
            }
            let sent = wait(Self.replyWait) { resumed(session, after: pressedAt) }
            note("«\(label)» per «\(ask.prefix(60))»: premuto\(press == .late ? " (in ritardo)" : ""), " + (sent ? "Claude ha ripreso dopo \(ms(pressedAt))" : "Claude non ha ripreso in \(Int(Self.replyWait)) s"))
            return sent
        }
        guard let conversation else {
            note("«\(label)» per «\(ask.prefix(60))»: non premuto, conversazione sconosciuta (finestre: \(windows.count), mostrata: \(start ?? "?"))")
            return false
        }
        // Una sessione avviata da un'altra sessione sta dentro il gruppo di quella, spesso chiuso: lo si apre come un
        // clic, e a cosa fatta lo si richiude (`opened`).
        var opened: [String] = []
        var found = row(named: conversation, in: nodes)
        if found == nil { (found, opened) = reveal(conversation, windows: windows, nodes: &nodes) }
        guard let line = found else {
            close(opened, windows: windows)
            note("«\(label)» per «\(ask.prefix(60))»: non premuto, riga di «\(conversation)» non trovata nella barra laterale"
                 + (opened.isEmpty ? "" : " nemmeno aprendo \(opened.count) gruppi") + " (finestre: \(windows.count), mostrata: \(start ?? "?"))")
            if logging { dump(nodes) }
            return false
        }
        // Un'altra conversazione: la sua riga nella barra laterale, come un clic. Claude resta dov'è.
        guard tap(line) != .refused else {
            close(opened, windows: windows)
            note("«\(label)»: la riga di «\(conversation)» non si lascia premere")
            return false
        }
        var target: AXUIElement?
        var reached = false
        _ = wait(Self.switchWait) {
            nodes = collect(windows)
            // Si preme solo a conversazione giusta sullo schermo: mai il pulsante di un'altra.
            reached = shown(in: nodes) == conversation
            if reached { target = find(label: label, ask: ask, in: nodes) }
            return target != nil
        }
        let route = " passando da «\(start ?? "?")» a «\(conversation)» (\(ms(began)))"
        /// Torna sulla conversazione di prima. Solo quando non c'è più niente in coda per quella giusta.
        func goBack() -> Bool {
            guard let start, start != conversation, let line = row(named: start, in: collect(windows)) else { return false }
            return tap(line) != .refused
        }
        guard let target else {
            // Non c'è niente da premere: si torna subito, se la conversazione era cambiata davvero. Se non è nemmeno
            // cambiata, il clic sulla riga può essere ancora in coda e un ritorno lo seguirebbe: meglio lasciare stare.
            let back = reached && goBack()
            // I gruppi aperti si richiudono solo tornati indietro: se il clic sulla riga è ancora in coda, la
            // conversazione può cambiare dopo, e la sua riga resta in vista.
            if back { close(opened, windows: windows) }
            note("«\(label)» per «\(ask.prefix(60))»: \(reached ? "pulsante non trovato" : "la conversazione non è cambiata")" + route + (back ? ", poi ritorno" : ""))
            if logging { dump(nodes) }
            return false
        }
        let pressedAt = Date()
        let press = tap(target)
        guard press != .refused else {
            let back = goBack()
            if back { close(opened, windows: windows) }
            note("«\(label)»: pressione rifiutata" + route + (back ? ", poi ritorno" : ""))
            return false
        }
        // Si torna indietro solo a risposta arrivata: un ritorno premuto prima finirebbe in coda davanti al clic.
        let sent = wait(Self.replyWait) { resumed(session, after: pressedAt) }
        let back = sent && goBack()
        if back { close(opened, windows: windows) }
        note("«\(label)» per «\(ask.prefix(60))»: premuto\(press == .late ? " (in ritardo)" : "")" + route + ", "
             + (sent ? "Claude ha ripreso dopo \(ms(pressedAt))" + (back ? ", poi ritorno" : ", ritorno non riuscito")
                     : "Claude non ha ripreso in \(Int(Self.replyWait)) s: resta su questa conversazione"))
        return sent
    }

    private enum Press { case done, late, refused }

    /// Preme come un clic. Con l'app di Claude dietro un'altra app o su un'altra scrivania la pressione può arrivare
    /// dopo che l'Accessibilità ha smesso di aspettare la risposta (`cannotComplete`): non è un rifiuto, il clic è in
    /// coda e arriva lo stesso. Prima Charland diceva «Non è partita» mentre la risposta stava arrivando a Claude.
    private static func tap(_ element: AXUIElement) -> Press {
        switch AXUIElementPerformAction(element, kAXPressAction as CFString) {
        case .success: return .done
        case .cannotComplete: return .late
        default: return .refused
        }
    }

    /// Ripete `check` ogni quarto di secondo finché è vero o finché passano `seconds`.
    private static func wait(_ seconds: TimeInterval, until check: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        repeat {
            if check() { return true }
            Thread.sleep(forTimeInterval: 0.25)
        } while Date() < deadline
        return check()
    }

    /// Per le prove (`Charland --premi-in-claude <domanda> <pulsante> <conversazione> <sessione>`): preme davvero, con
    /// la stessa strada di un tocco nell'isola, e scrive il registro delle pressioni anche se è spento. Manda una
    /// risposta vera alla sessione: solo con l'ok di carpa.
    static func pressForTest(label: String, ask: String, conversation: String, session: String) -> Bool {
        forceLog = true
        return press(label: label, ask: ask, conversation: conversation, session: session)
    }

    /// Per le prove (`Charland --trova-in-claude <domanda> <pulsante>`): dice cosa troverebbe nella finestra di Claude
    /// com'è adesso, senza premere niente e senza cambiare conversazione.
    static func probe(label: String, ask: String, conversation: String? = nil) -> String {
        guard canPress else { return "manca il permesso di Accessibilità" }
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundle).first else { return "Claude non è aperta" }
        let root = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(root, 2)
        _ = AXUIElementSetAttributeValue(root, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        let start = Date()
        let usual = (attribute(root, kAXWindowsAttribute) as? [AXUIElement])?.count ?? 0
        let windows = self.windows(of: app.processIdentifier, root: root)
        let nodes = collect(windows)
        let key = String(plain(ask).prefix(40))
        let question = nodes.contains { $0.kind == .text && plain($0.text).contains(key) }
        let found = find(label: label, ask: ask, in: nodes) != nil
        let rows = nodes.filter { $0.kind == .button && !$0.inToolbar }.count
        return "finestre: \(windows.count) (col metodo normale \(usual)) | letti \(nodes.count) fra testi e pulsanti in "
            + "\(Int(Date().timeIntervalSince(start) * 1000)) ms | conversazione mostrata: \(shown(in: nodes) ?? "non riconosciuta") | "
            + "pulsanti fuori dalla barra degli strumenti: \(rows) | domanda sullo schermo: \(question ? "sì" : "no") | "
            + "pulsante dopo la domanda: \(found ? "sì" : "no")" + sidebar(conversation, in: nodes)
    }

    /// Per la prova: se la riga della conversazione si vede nella barra laterale, o in quale gruppo chiuso potrebbe stare.
    private static func sidebar(_ conversation: String?, in nodes: [Node]) -> String {
        guard let conversation else { return "" }
        if row(named: conversation, in: nodes) != nil { return " | riga di «\(conversation)»: in vista" }
        let closed = groups(in: nodes, open: false).map(\.toggle)
        let list = closed.map { "«\($0.parent)»\($0.needsInput ? " (aspetta te)" : "")" }.joined(separator: ", ")
        return " | riga di «\(conversation)»: non in vista" + (closed.isEmpty ? ", nessun gruppo chiuso" : ", gruppi chiusi da aprire: \(list)")
    }

    // MARK: Lettura della finestra

    private static func attribute(_ element: AXUIElement, _ name: String) -> AnyObject? {
        var value: AnyObject?
        return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
    }

    /// Le finestre normali dell'app, su qualunque scrivania. Prima dal numero dell'elemento (anche le scrivanie che non
    /// vedi), poi l'elenco normale per quelle che il primo modo non avesse trovato.
    private static func windows(of pid: pid_t, root: AXUIElement) -> [AXUIElement] {
        var found: [AXUIElement] = []
        var token = Data(count: 20)
        token.replaceSubrange(0..<4, with: withUnsafeBytes(of: pid) { Data($0) })
        token.replaceSubrange(4..<8, with: withUnsafeBytes(of: Int32(0)) { Data($0) })
        token.replaceSubrange(8..<12, with: withUnsafeBytes(of: Int32(0x636f636f)) { Data($0) })
        for id: UInt64 in 0..<1000 {
            token.replaceSubrange(12..<20, with: withUnsafeBytes(of: id) { Data($0) })
            guard let element = _AXUIElementCreateWithRemoteToken(token as CFData)?.takeRetainedValue() else { continue }
            if attribute(element, kAXSubroleAttribute) as? String == kAXStandardWindowSubrole { found.append(element) }
        }
        var usual = attribute(root, kAXWindowsAttribute) as? [AXUIElement] ?? []
        if usual.isEmpty, let main = attribute(root, kAXMainWindowAttribute), CFGetTypeID(main) == AXUIElementGetTypeID() {
            usual = [main as! AXUIElement]
        }
        for window in usual where !found.contains(where: { CFEqual($0, window) }) { found.append(window) }
        return found
    }

    /// I testi, i titoli e i pulsanti delle finestre, nell'ordine in cui si leggono.
    private static func collect(_ windows: [AXUIElement]) -> [Node] {
        var nodes: [Node] = []
        var visited = 0
        func walk(_ element: AXUIElement, depth: Int, inToolbar: Bool) {
            guard depth < 90, visited < 20_000 else { return }
            visited += 1
            let role = attribute(element, kAXRoleAttribute) as? String ?? ""
            func text() -> String {
                for name in [kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute] {
                    if let value = attribute(element, name) as? String, !value.isEmpty { return value }
                }
                return ""
            }
            switch role {
            case kAXButtonRole: nodes.append(Node(kind: .button, text: text(), element: element, inToolbar: inToolbar))
            case "AXHeading": nodes.append(Node(kind: .heading, text: text(), element: element, inToolbar: inToolbar))
            case kAXStaticTextRole:
                if let value = attribute(element, kAXValueAttribute) as? String, !value.isEmpty {
                    nodes.append(Node(kind: .text, text: value, element: element, inToolbar: inToolbar))
                }
            default: break
            }
            for child in attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? [] {
                walk(child, depth: depth + 1, inToolbar: inToolbar || role == kAXToolbarRole)
            }
        }
        for window in windows { walk(window, depth: 0, inToolbar: false) }
        return nodes
    }

    private static func plain(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ").lowercased()
    }

    /// Il pulsante della risposta: quello col titolo esatto che viene subito dopo il testo della domanda. Senza la
    /// domanda sullo schermo non si preme niente (un pulsante con lo stesso nome può stare ovunque).
    private static func find(label: String, ask: String, in nodes: [Node]) -> AXUIElement? {
        let wanted = plain(label)
        let key = String(plain(ask).prefix(40))
        guard !wanted.isEmpty, key.count >= 4,
              let question = nodes.lastIndex(where: { $0.kind == .text && plain($0.text).contains(key) }) else { return nil }
        // Il riquadro sta sotto la domanda: i suoi pulsanti sono i primi che seguono.
        let after = nodes[(question + 1)...].prefix(40)
        return after.first { $0.kind == .button && plain($0.text) == wanted }?.element
    }

    /// La conversazione mostrata: il titolo nella barra degli strumenti della sessione.
    private static func shown(in nodes: [Node]) -> String? {
        nodes.first { $0.kind == .heading && $0.inToolbar && !$0.text.isEmpty }?.text
    }

    /// La riga di una conversazione nella barra laterale: un pulsante che si chiama come lei (a volte con lo stato
    /// dopo, «… In esecuzione») e che dentro ha il nome esatto. Se due righe hanno lo stesso nome non si sceglie.
    private static func row(named name: String, in nodes: [Node]) -> AXUIElement? {
        var matches: [AXUIElement] = []
        for (index, node) in nodes.enumerated() where node.kind == .button && !node.inToolbar {
            guard node.text == name || node.text.hasPrefix(name + " ") else { continue }
            if nodes[(index + 1)...].prefix(3).contains(where: { $0.kind == .text && $0.text == name }) { matches.append(node.element) }
        }
        return matches.count == 1 ? matches[0] : nil
    }

    // MARK: Gruppi delle sessioni avviate da un'altra sessione

    /// Il pulsante che apre o chiude il gruppo delle sessioni avviate da un'altra sessione. Nella barra laterale sta
    /// sotto la riga di quella sessione e finisce col suo nome: chiuso «Mostra 1 sessione annidata, 1 richiede input
    /// <nome>», aperto «Nascondi sessioni annidate <nome>» (in inglese «Show…» e «Hide…»).
    struct GroupToggle: Equatable {
        /// La sessione che ha avviato quelle del gruppo.
        var parent: String
        var open: Bool
        /// Dentro c'è una sessione che aspetta te.
        var needsInput: Bool
    }

    /// Riconosce il pulsante di un gruppo dal suo titolo, fra i nomi delle conversazioni che si leggono nella barra.
    static func groupToggle(_ title: String, names: Set<String>) -> GroupToggle? {
        let lower = plain(title)
        guard lower.contains("annidat") || lower.contains("nested") else { return nil }
        let open: Bool
        if lower.hasPrefix("nascondi ") || lower.hasPrefix("hide ") {
            open = true
        } else if lower.hasPrefix("mostra ") || lower.hasPrefix("show ") {
            open = false
        } else {
            return nil
        }
        // Il nome più lungo con cui finisce il titolo: «… input Testo a tempo» non deve fermarsi a «tempo».
        guard let parent = names.filter({ !$0.isEmpty && title.hasSuffix(" " + $0) }).max(by: { $0.count < $1.count })
        else { return nil }
        return GroupToggle(parent: parent, open: open, needsInput: lower.contains("input"))
    }

    private static func groups(in nodes: [Node], open: Bool) -> [(toggle: GroupToggle, element: AXUIElement)] {
        let names = Set(nodes.filter { $0.kind == .text && $0.text.count < 200 }.map(\.text))
        return nodes.compactMap { node in
            guard node.kind == .button, !node.inToolbar, let toggle = groupToggle(node.text, names: names), toggle.open == open
            else { return nil }
            return (toggle, node.element)
        }
    }

    /// Apre i gruppi chiusi finché compare la riga di `conversation`: prima quelli con una sessione che aspetta te,
    /// poi gli altri, anche uno dentro l'altro. Restituisce la riga (se c'è) e i gruppi aperti, da richiudere.
    private static func reveal(_ conversation: String, windows: [AXUIElement], nodes: inout [Node]) -> (AXUIElement?, [String]) {
        var opened: [String] = []
        for _ in 0..<6 {
            let closed = groups(in: nodes, open: false).filter { !opened.contains($0.toggle.parent) }
            guard let group = closed.first(where: { $0.toggle.needsInput }) ?? closed.first else { break }
            opened.append(group.toggle.parent)
            guard tap(group.element) != .refused else { continue }
            var line: AXUIElement?
            // Con la finestra su un'altra scrivania i clic arrivano tardi: si aspetta come per il cambio di conversazione.
            _ = wait(Self.switchWait) {
                nodes = collect(windows)
                line = row(named: conversation, in: nodes)
                return line != nil || groups(in: nodes, open: true).contains { $0.toggle.parent == group.toggle.parent }
            }
            if let line { return (line, opened) }
        }
        return (nil, opened)
    }

    /// Richiude i gruppi aperti da `reveal`, dall'ultimo: la barra laterale torna com'era.
    private static func close(_ parents: [String], windows: [AXUIElement]) {
        guard !parents.isEmpty else { return }
        let open = groups(in: collect(windows), open: true)
        for parent in parents.reversed() {
            if let group = open.first(where: { $0.toggle.parent == parent }) {
                _ = tap(group.element)
            }
        }
    }

    // MARK: Registro delle prove

    /// `defaults write com.charstudio.charland logPressioni -bool true`: cosa ha trovato e fatto, in
    /// `~/Library/Application Support/Charland/pressioni.log`. Spento di serie.
    private static var logging: Bool { forceLog || UserDefaults.standard.bool(forKey: "logPressioni") }
    nonisolated(unsafe) private static var forceLog = false

    private static func note(_ text: String) {
        guard logging else { return }
        let url = CharlandPathsLog.url
        let line = "\(ActivityCenter.clock()) \(text)\n"
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            handle.write(Data(line.utf8))
        } else {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? Data(line.utf8).write(to: url)
        }
    }

    /// Quando non trova il pulsante: la coda della finestra, per capire com'è fatta.
    private static func dump(_ nodes: [Node]) {
        for node in nodes.suffix(70) {
            let mark = node.kind == .button ? "[pulsante]" : node.kind == .heading ? "[titolo]  " : "          "
            note("   \(mark) \(node.text.prefix(90).replacingOccurrences(of: "\n", with: " "))")
        }
    }
}

/// Dove sta il registro delle pressioni.
enum CharlandPathsLog {
    static var url: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Charland", isDirectory: true).appendingPathComponent("pressioni.log")
    }
}
