import Foundation

/// `Charland --prova-registro`: lo sfondo su tutte le scrivanie (`AllSpaces`) contro registri di WallpaperAgent FINTI,
/// di forme che su questo Mac non ci sono: due schermi, un monitor nuovo, uno sfondo scelto da chi usa il Mac, «su tutte
/// le scrivanie e schermi» di Impostazioni di Sistema, un registro vuoto, una struttura sconosciuta, un file che non si
/// legge. Si fa su file in una cartella temporanea (`AllSpaces.sandbox`): non tocca il registro vero né ripartire
/// WallpaperAgent. Per ogni caso si guarda che il disegno arrivi in ogni spazio, che la verifica dica la verità, che
/// spegnendo tutto torni com'era, e che dove non si può lo si dica con il motivo giusto senza scrivere niente.
/// Serve perché la funzione è provata dal vivo solo su macOS 27 con uno schermo (20 novembre 2026).
extension WallpaperChecks {
    static func registryTest() -> Bool {
        var failures = 0
        func check(_ name: String, _ body: () -> String?) {
            if let problem = body() { failures += 1; print("ERRORE \(name): \(problem)") } else { print("OK     \(name)") }
        }

        let displayA = "AAAAAAAA-0000-4000-8000-000000000001", displayB = "BBBBBBBB-0000-4000-8000-000000000002"
        let ours = [displayA: URL(string: "file:///Users/test/Library/Application%20Support/Charland/Sfondo/favo-AAAAAAAA-1.heic")!]
        let oursTwo = ours.merging([displayB: URL(string: "file:///Users/test/Library/Application%20Support/Charland/Sfondo/favo-BBBBBBBB-1.heic")!]) { a, _ in a }
        let main = ours[displayA]!

        // MARK: Costruttori di voci, come le scrive macOS

        let moment = Date(timeIntervalSince1970: 1_700_000_000)
        func content(_ provider: String, _ url: String?) -> NSDictionary {
            var configuration = Data()
            if let url {
                configuration = (try? PropertyListSerialization.data(fromPropertyList: ["type": "imageFile", "url": ["relative": url]],
                                                                      format: .binary, options: 0)) ?? Data()
            }
            let choice: NSDictionary = ["Configuration": configuration, "Files": NSArray(), "Provider": provider]
            return ["Choices": NSArray(object: choice), "EncodedOptionValues": Data([1, 2, 3]), "Shuffle": "$null"]
        }
        func slot(_ provider: String, _ url: String?) -> NSDictionary { ["Content": content(provider, url), "LastSet": moment, "LastUse": moment] }
        func individual(_ url: String) -> NSDictionary {
            ["Type": "individual", "Desktop": slot("com.apple.wallpaper.choice.image", url), "Idle": slot("default", nil)]
        }
        func dynamic() -> NSDictionary {
            ["Type": "individual", "Desktop": slot("com.apple.wallpaper.choice.dynamic", nil), "Idle": slot("default", nil)]
        }
        func linked() -> NSDictionary { ["Type": "linked", "Linked": slot("default", nil)] }
        func idleOnly() -> NSDictionary { ["Type": "idle", "Idle": slot("default", nil)] }
        func space(_ entry: NSDictionary, displays: [String]) -> NSDictionary {
            ["Default": entry, "Displays": NSDictionary(objects: displays.map { _ in entry }, forKeys: displays as [NSCopying])]
        }
        let userImage = "file:///Users/test/Pictures/mia.jpg", otherImage = "file:///Users/test/Pictures/altra.jpg"

        // MARK: Cartella e registro di un caso

        struct Case {
            var dir: URL
            var index: URL { dir.appendingPathComponent("Index.plist") }
            var backup: URL { dir.appendingPathComponent("spazi-prima.plist") }
        }
        func makeCase(_ registry: NSDictionary?, raw: Data? = nil, spaces: [String]) -> Case {
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("charland-registro-\(UUID().uuidString)")
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let c = Case(dir: dir)
            if let raw { try? raw.write(to: c.index) }
            if let registry, let data = try? PropertyListSerialization.data(fromPropertyList: registry, format: .binary, options: 0) {
                try? data.write(to: c.index)
            }
            // La copia come la fa `giveToMacOS` prima di toccare qualcosa.
            AllSpaces.sandbox = AllSpaces.Sandbox(index: c.index, backup: c.backup, spaces: spaces)
            AllSpaces.backupIfNeeded()
            return c
        }
        func load(_ url: URL) -> NSDictionary? {
            guard let data = try? Data(contentsOf: url) else { return nil }
            return (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? NSDictionary
        }
        func urlOf(_ desktop: Any?) -> String? {
            guard let content = (desktop as? NSDictionary)?["Content"] as? NSDictionary, let choices = content["Choices"] as? NSArray,
                  let data = (choices.firstObject as? NSDictionary)?["Configuration"] as? Data,
                  let config = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? NSDictionary else { return nil }
            return (config["url"] as? NSDictionary)?["relative"] as? String
        }
        func isOurs(_ entry: Any?) -> Bool { (urlOf((entry as? NSDictionary)?["Desktop"]) ?? "").contains("/Sfondo/favo-") }
        /// Ogni voce di ogni spazio e ogni schermo: individual e col nostro disegno.
        func allEntriesOurs(_ root: NSDictionary) -> String? {
            guard let spaces = root["Spaces"] as? NSDictionary, spaces.count > 0 else { return "nessuno spazio nel registro" }
            for case let (uuid as String, value as NSDictionary) in spaces {
                guard isOurs(value["Default"]) else { return "lo spazio \(uuid.prefix(8)) non ha il disegno in Default" }
                guard (value["Default"] as? NSDictionary)?["Type"] as? String == "individual" else { return "Default di \(uuid.prefix(8)) non è individual" }
                for case let (display as String, entry as NSDictionary) in (value["Displays"] as? NSDictionary) ?? [:] {
                    guard isOurs(entry) else { return "lo spazio \(uuid.prefix(8)) non ha il disegno sullo schermo \(display.prefix(8))" }
                }
            }
            return nil
        }
        func noOursLeft(_ root: NSDictionary) -> Bool {
            func walk(_ v: Any) -> Bool {
                guard let d = v as? NSDictionary else { return true }
                for case let (key as String, item) in d {
                    if key == "Desktop" { if isOurs(["Desktop": item]) { return false } } else if !walk(item) { return false }
                }
                return true
            }
            return walk(root)
        }
        defer { AllSpaces.sandbox = nil }

        // 1. Come sul Mac di carpa, con un solo schermo: voci «linked» di serie in più spazi.
        check("un schermo, 3 spazi «linked» di serie") {
            let reg: NSDictionary = ["AllSpacesAndDisplays": idleOnly(), "SystemDefault": linked(),
                                     "Displays": [displayA: linked()],
                                     "Spaces": ["": space(individual(userImage), displays: [displayA]),
                                                "S1": space(linked(), displays: [displayA]), "S2": space(linked(), displays: [displayA])]]
            let c = makeCase(reg, spaces: ["S1", "S2"])
            guard AllSpaces.apply(files: ours, fallback: main) else { return "apply ha fallito: \(String(describing: AllSpaces.lastProblem))" }
            guard let now = load(c.index) else { return "registro illeggibile dopo" }
            if let p = allEntriesOurs(now) { return p }
            guard AllSpaces.points(to: ours) else { return "points(to:) dice di no" }
            guard isOurs((now["Displays"] as? NSDictionary)?[displayA]) else { return "lo sfondo generale dello schermo non ha il disegno" }
            guard (now["AllSpacesAndDisplays"] as? NSDictionary)?["Type"] as? String == "idle" else { return "AllSpacesAndDisplays di solo salvaschermo è stato toccato" }
            guard AllSpaces.restore(keepBackup: false), let back = load(c.index) else { return "il ripristino è fallito" }
            guard noOursLeft(back) else { return "dopo il ripristino resta un nostro disegno" }
            return back.isEqual(to: reg as! [AnyHashable: Any]) ? nil : "dopo il ripristino il registro non è com'era"
        }

        // 2. Due schermi, due spazi: ogni schermo il suo disegno.
        check("due schermi, ognuno il suo disegno") {
            let reg: NSDictionary = ["AllSpacesAndDisplays": idleOnly(), "Displays": [displayA: linked(), displayB: linked()],
                                     "Spaces": ["": space(linked(), displays: [displayA, displayB]), "S1": space(linked(), displays: [displayA, displayB])]]
            let c = makeCase(reg, spaces: ["S1"])
            guard AllSpaces.apply(files: oursTwo, fallback: main) else { return "apply ha fallito: \(String(describing: AllSpaces.lastProblem))" }
            guard let now = load(c.index) else { return "registro illeggibile dopo" }
            if let p = allEntriesOurs(now) { return p }
            let s1 = ((now["Spaces"] as? NSDictionary)?["S1"] as? NSDictionary)?["Displays"] as? NSDictionary
            guard (urlOf((s1?[displayA] as? NSDictionary)?["Desktop"]) ?? "").contains("favo-AAAAAAAA"),
                  (urlOf((s1?[displayB] as? NSDictionary)?["Desktop"]) ?? "").contains("favo-BBBBBBBB") else { return "ogni schermo non ha il suo disegno" }
            guard AllSpaces.points(to: oursTwo) else { return "points(to:) dice di no" }
            guard AllSpaces.restore(keepBackup: false), let back = load(c.index), noOursLeft(back), back.isEqual(to: reg as! [AnyHashable: Any]) else { return "il ripristino non lo rimette com'era" }
            return nil
        }

        // 3. Un monitor che il registro non conosce ancora (collegato dopo): il disegno gli arriva lo stesso.
        check("monitor nuovo, non ancora nel registro") {
            let reg: NSDictionary = ["Displays": [displayA: linked()], "Spaces": ["": space(linked(), displays: [displayA])]]
            let c = makeCase(reg, spaces: [])
            guard AllSpaces.apply(files: oursTwo, fallback: main), let now = load(c.index) else { return "apply ha fallito: \(String(describing: AllSpaces.lastProblem))" }
            guard isOurs((now["Displays"] as? NSDictionary)?[displayB]) else { return "lo sfondo generale del monitor nuovo non c'è" }
            guard isOurs(((now["Spaces"] as? NSDictionary)?[""] as? NSDictionary)?["Default"]) else { return "il Default dello spazio non ha il disegno" }
            guard AllSpaces.points(to: oursTwo) else { return "points(to:) dice di no" }
            guard AllSpaces.restore(keepBackup: false), let back = load(c.index) else { return "il ripristino è fallito" }
            guard (back["Displays"] as? NSDictionary)?[displayB] == nil else { return "spegnendo resta una voce in più per il monitor nuovo" }
            return back.isEqual(to: reg as! [AnyHashable: Any]) ? nil : "dopo il ripristino il registro non è com'era"
        }

        // 3b. «Tutte le scrivanie e schermi» di tipo «linked» con un'immagine scelta da chi usa il Mac.
        check("«tutte le scrivanie e schermi» di tipo linked, scelta di chi usa il Mac") {
            let linkedImage: NSDictionary = ["Type": "linked", "Linked": slot("com.apple.wallpaper.choice.image", userImage)]
            let reg: NSDictionary = ["AllSpacesAndDisplays": linkedImage, "Spaces": ["S1": space(linked(), displays: [displayA])]]
            let c = makeCase(reg, spaces: [])
            guard AllSpaces.apply(files: ours, fallback: main), let now = load(c.index) else { return "apply ha fallito" }
            guard isOurs(now["AllSpacesAndDisplays"]) else { return "la voce linked non è stata presa" }
            guard !AllSpaces.needsRepair(files: ours) else { return "dopo apply vuole ancora riparare" }
            guard AllSpaces.restore(keepBackup: false), let back = load(c.index) else { return "il ripristino è fallito" }
            return back.isEqual(to: reg as! [AnyHashable: Any]) ? nil : "la scelta «linked» non è tornata com'era"
        }

        // 3c. Spegnere solo «Su tutte le scrivanie» (lo sfondo resta acceso): la copia resta, la scelta torna.
        check("spegnere solo «Su tutte le scrivanie»: la copia resta e la scelta torna") {
            let reg: NSDictionary = ["AllSpacesAndDisplays": individual(userImage), "Spaces": ["S1": space(linked(), displays: [displayA])]]
            let c = makeCase(reg, spaces: [])
            guard AllSpaces.apply(files: ours, fallback: main) else { return "apply ha fallito" }
            guard AllSpaces.restore(keepBackup: true), let back = load(c.index) else { return "il ripristino è fallito" }
            guard AllSpaces.hasBackup else { return "la copia del registro è sparita" }
            return urlOf((back["AllSpacesAndDisplays"] as? NSDictionary)?["Desktop"]) == userImage ? nil : "la scelta «tutte le scrivanie» non è tornata"
        }

        // 3d. La riparazione vede anche la voce «tutte le scrivanie e schermi» tornata di serie.
        check("la riparazione vede «tutte le scrivanie e schermi» tornata di serie") {
            let reg: NSDictionary = ["AllSpacesAndDisplays": linked(), "Spaces": ["S1": space(individual(userImage), displays: [displayA])]]
            _ = makeCase(reg, spaces: [])
            return AllSpaces.needsRepair(files: ours) ? nil : "non vede la voce tornata di serie"
        }

        // 4. «Su tutte le scrivanie e schermi» scelto in Impostazioni di Sistema: ha la precedenza, e va preso.
        check("«tutte le scrivanie e schermi» di Impostazioni di Sistema") {
            let reg: NSDictionary = ["AllSpacesAndDisplays": individual(userImage), "Displays": [displayA: individual(userImage)],
                                     "Spaces": [:] as NSDictionary]
            let c = makeCase(reg, spaces: ["S1", "S2"])
            guard AllSpaces.apply(files: ours, fallback: main), let now = load(c.index) else { return "apply ha fallito: \(String(describing: AllSpaces.lastProblem))" }
            guard isOurs(now["AllSpacesAndDisplays"]) else { return "la voce «tutte le scrivanie» non ha il disegno" }
            if let p = allEntriesOurs(now) { return p }
            guard AllSpaces.points(to: ours) else { return "points(to:) dice di no" }
            guard AllSpaces.restore(keepBackup: false), let back = load(c.index), noOursLeft(back) else { return "il ripristino lascia un nostro disegno" }
            guard urlOf((back["AllSpacesAndDisplays"] as? NSDictionary)?["Desktop"]) == userImage else { return "lo sfondo scelto da chi usa il Mac non è tornato" }
            let spaces = back["Spaces"] as? NSDictionary
            for case let (uuid as String, entry as NSDictionary) in spaces ?? [:] where entry["Default"] != nil {
                guard (entry["Default"] as? NSDictionary)?["Type"] as? String == "linked" else { return "lo spazio \(uuid) creato da noi non torna «linked»" }
            }
            return nil
        }

        // 5. Un registro senza `Spaces`: gli spazi si prendono da Mission Control.
        check("registro senza Spaces, spazi da Mission Control") {
            let reg: NSDictionary = ["Displays": [displayA: linked()], "SystemDefault": linked()]
            let c = makeCase(reg, spaces: ["S1", "S2"])
            guard AllSpaces.apply(files: ours, fallback: main), let now = load(c.index) else { return "apply ha fallito: \(String(describing: AllSpaces.lastProblem))" }
            if let p = allEntriesOurs(now) { return p }
            return AllSpaces.points(to: ours) ? nil : "points(to:) dice di no"
        }

        // 6. Dynamic wallpaper (o aerial) di chi usa il Mac: spegnendo torna tale e quale.
        check("sfondo dinamico di sistema: torna com'era") {
            let reg: NSDictionary = ["Displays": [displayA: dynamic()], "Spaces": ["": space(dynamic(), displays: [displayA]), "S1": space(dynamic(), displays: [displayA])]]
            let c = makeCase(reg, spaces: ["S1"])
            guard AllSpaces.apply(files: ours, fallback: main) else { return "apply ha fallito" }
            guard AllSpaces.restore(keepBackup: false), let back = load(c.index) else { return "il ripristino è fallito" }
            return back.isEqual(to: reg as! [AnyHashable: Any]) ? nil : "lo sfondo dinamico non è tornato com'era"
        }

        // 7. Uno sfondo cambiato da chi usa il Mac su un altro spazio mentre Charland è acceso: si rispetta spegnendo.
        check("sfondo scelto in Impostazioni su uno spazio, mentre è acceso") {
            let reg: NSDictionary = ["Displays": [displayA: individual(userImage)],
                                     "Spaces": ["S1": space(individual(userImage), displays: [displayA]), "S2": space(individual(userImage), displays: [displayA])]]
            let c = makeCase(reg, spaces: ["S1", "S2"])
            guard AllSpaces.apply(files: ours, fallback: main), let raw = try? Data(contentsOf: c.index),
                  let mid = (try? PropertyListSerialization.propertyList(from: raw, options: .mutableContainersAndLeaves, format: nil)) as? NSMutableDictionary,
                  let spaces = mid["Spaces"] as? NSMutableDictionary, let s2 = spaces["S2"] as? NSMutableDictionary else { return "apply o lettura falliti" }
            // chi usa il Mac sceglie un'altra immagine sullo spazio S2 (la voce non è più nostra)
            s2["Default"] = individual(otherImage); s2["Displays"] = [displayA: individual(otherImage)] as NSDictionary
            guard let data = try? PropertyListSerialization.data(fromPropertyList: mid, format: .binary, options: 0), (try? data.write(to: c.index)) != nil else { return "scrittura della prova fallita" }
            guard AllSpaces.apply(files: ours, fallback: main) else { return "il secondo apply ha fallito" }
            guard AllSpaces.restore(keepBackup: false), let back = load(c.index), noOursLeft(back) else { return "il ripristino lascia un nostro disegno" }
            let b = back["Spaces"] as? NSDictionary
            guard urlOf(((b?["S2"] as? NSDictionary)?["Default"] as? NSDictionary)?["Desktop"]) == otherImage else { return "la scelta fatta in Impostazioni non è tornata" }
            guard urlOf(((b?["S1"] as? NSDictionary)?["Default"] as? NSDictionary)?["Desktop"]) == userImage else { return "lo spazio S1 non è tornato com'era" }
            return nil
        }

        // 8. Il riparatore non scambia una scelta di chi usa il Mac per un registro da riparare.
        check("la riparazione lascia stare gli sfondi scelti da chi usa il Mac") {
            let reg: NSDictionary = ["Spaces": ["S1": space(individual(userImage), displays: [displayA])]]
            _ = makeCase(reg, spaces: [])
            return AllSpaces.needsRepair(files: ours) ? "vuole riparare uno sfondo scelto da chi usa il Mac" : nil
        }
        check("la riparazione rimette uno spazio tornato di serie") {
            let reg: NSDictionary = ["Spaces": ["S1": space(linked(), displays: [displayA])]]
            _ = makeCase(reg, spaces: [])
            return AllSpaces.needsRepair(files: ours) ? nil : "non vede uno spazio tornato allo sfondo di serie"
        }

        // 9. I casi in cui non si può: motivo giusto e niente scritto.
        func refuses(_ name: String, _ problem: AllSpaces.Problem, registry: NSDictionary? = nil, raw: Data? = nil, missing: Bool = false, spaces: [String] = []) {
            check(name) {
                let c = makeCase(registry, raw: raw, spaces: spaces)
                if missing { try? FileManager.default.removeItem(at: c.index) }
                let before = try? Data(contentsOf: c.index)
                guard !AllSpaces.apply(files: ours, fallback: main) else { return "ha detto di riuscire" }
                guard AllSpaces.lastProblem == problem else { return "motivo \(String(describing: AllSpaces.lastProblem)) invece di \(problem)" }
                let after = try? Data(contentsOf: c.index)
                return before == after ? nil : "ha scritto nel registro pur dicendo di non poter"
            }
        }
        refuses("registro che non c'è", .noRegistry, missing: true)
        refuses("file che non è un registro", .unknownStructure, raw: Data("non sono un plist".utf8))
        refuses("struttura sconosciuta, niente spazi", .unknownStructure, registry: ["Foo": ["Bar": 1] as NSDictionary])
        check("registro che non si può leggere (permessi)") {
            let reg: NSDictionary = ["Spaces": ["S1": space(linked(), displays: [displayA])]]
            let c = makeCase(reg, spaces: [])
            try? FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: c.index.path)
            defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: c.index.path) }
            guard !AllSpaces.apply(files: ours, fallback: main) else { return "ha detto di riuscire" }
            return AllSpaces.lastProblem == .unreadable ? nil : "motivo \(String(describing: AllSpaces.lastProblem)) invece di unreadable"
        }

        print(failures == 0 ? "Tutti i casi passano." : "\(failures) casi falliti.")
        return failures == 0
    }
}
