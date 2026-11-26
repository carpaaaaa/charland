import AppKit
import SwiftUI
import CharlandCore
import AVFoundation
import EventKit
import IOKit.hid

/// Le prove del Dock da terminale: i numeri letti sul Mac, e i disegni fuori schermo per controllare misure e testi.
@MainActor
enum DockChecks {
    /// `Charland --usage` stampa quello che si legge sul Mac; `Charland --usage vivo` lo chiede anche ai comandi.
    static func printUsage(live: Bool) -> Bool {
        var found = false
        for provider in UsageProviderID.allCases {
            let detected: Bool
            var snapshot: UsageSnapshot
            switch provider {
            case .claude:
                detected = ClaudeUsage.detected
                if detected, live { print("claude: chiedo a", AgentCLI.find("claude")?.path ?? "(comando non trovato)", "→", ClaudeUsage.refreshLive()) }
                snapshot = ClaudeUsage.read()
            case .chatgpt:
                detected = CodexUsage.detected
                snapshot = CodexUsage.read()
                if detected, live {
                    print("chatgpt: chiedo a", AgentCLI.find("codex")?.path ?? "(comando non trovato)")
                    if let fresh = CodexUsage.readLive() {
                        snapshot.windows = fresh.windows
                        snapshot.plan = fresh.plan
                        snapshot.fetched = fresh.fetched
                    } else {
                        print("chatgpt: il comando non ha risposto")
                    }
                }
            case .gemini:
                // Per le prove: una cartella di conversazioni finte al posto di `~/.gemini/tmp`.
                if let fake = ProcessInfo.processInfo.environment["CHARLAND_GEMINI_FINTO"] {
                    detected = true
                    snapshot = GeminiUsage.read(root: URL(fileURLWithPath: fake))
                } else {
                    detected = GeminiUsage.detected
                    snapshot = GeminiUsage.read()
                }
            }
            print("\(provider.title): \(detected ? "trovato" : "non trovato su questo Mac")")
            guard detected else { continue }
            found = true
            if let plan = snapshot.plan { print("   piano: \(plan)") }
            for window in snapshot.windows {
                var line = String(format: "   %@: %.0f%%", window.title, window.percent)
                if let resets = window.resets {
                    line += " · riparte \(UsageText.moment(resets)) (fra \(UsageText.remaining(until: resets)))"
                }
                if let elapsed = window.elapsed() { line += String(format: " · ritmo %.0f%%", elapsed * 100) }
                print(line)
            }
            if let pace = UsageDrawerMetrics.paceText(snapshot) { print("   \(pace.text)") }
            if let cost = snapshot.costToday { print("   prezzo API oggi: \(UsageText.money(cost))") }
            if let tokens = snapshot.tokensToday { print("   token oggi: \(UsageText.compact(tokens))") }
            if let requests = snapshot.requestsToday { print("   risposte oggi: \(requests)") }
            if let fetched = snapshot.fetched {
                print(String(format: "   letti %.0f s fa", Date().timeIntervalSince(fetched)))
            }
            print("   nel Dock: «\(UsageModule.label(for: snapshot, remaining: false))»")
        }
        return found
    }

    // MARK: Disegni

    private static func sample(_ provider: UsageProviderID, now: Date) -> UsageSnapshot {
        switch provider {
        case .claude:
            return UsageSnapshot(windows: [
                UsageWindow(id: "weekly_all", title: String(localized: "Settimana"), percent: 64,
                            resets: now.addingTimeInterval(46 * 3600), length: 7 * 86_400),
                UsageWindow(id: "weekly_scoped:Fable", title: String(localized: "Settimana") + ", Fable", percent: 61,
                            resets: now.addingTimeInterval(46 * 3600), length: 7 * 86_400),
            ], plan: "Ultra", tokensToday: 48_200_000, costToday: 215.4, fetched: now)
        case .chatgpt:
            return UsageSnapshot(windows: [
                UsageWindow(id: "primary", title: String(localized: "Sessione"), percent: 37,
                            resets: now.addingTimeInterval(2.2 * 3600), length: 5 * 3600),
                UsageWindow(id: "secondary", title: String(localized: "Settimana"), percent: 86,
                            resets: now.addingTimeInterval(3.1 * 86_400), length: 7 * 86_400),
            ], plan: "Plus", tokensToday: 1_240_000, fetched: now)
        case .gemini:
            return UsageSnapshot(tokensToday: 312_000, requestsToday: 42, fetched: now)
        }
    }

    /// Dati di fantasia (in inglese) per agenti e calendario; i moduli li mostrano al posto di quelli veri.
    static func useSamples(now: Date) {
        UsageStore.shared.useSample(Dictionary(uniqueKeysWithValues: UsageProviderID.allCases.map { ($0, sample($0, now: now)) }))
        CharcalAgenda.shared.useSample(now: now)
        AgendaStore.shared.useSample(now: now)
    }

    /// Vassoi e cassetti di ogni modulo disegnati fuori schermo, con numeri di prova (agenti e calendario) e veri
    /// (sistema), su un fondo scuro e su uno chiaro. I riquadri rossi sono le altezze calcolate dei cassetti: se il
    /// contenuto ne esce, si vede.
    static func render(folder: String) {
        let out = URL(fileURLWithPath: folder)
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let now = Date()
        useSamples(now: now)
        SystemStats.shared.primeForChecks()
        UsageDrawerMetrics.refreshApps()
        let bar = DockBar.shared
        let height: CGFloat = 49

        func platter(_ id: DockModuleID, height: CGFloat = 49) -> some View {
            let layout = DockRowLayout(cells: bar.module(id)?.cells(height: height, now: now) ?? [], height: height)
            return DockModulePlatter(id: id, layout: layout, hovered: nil, now: now)
                .background(Capsule().fill(.black.opacity(0.55)))
                .overlay(Capsule().stroke(.white.opacity(0.22), lineWidth: 1))
        }

        for (name, backdrop) in [("scuro", Color(white: 0.12)), ("chiaro", Color(white: 0.93))] {
            let board = VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 10) { ForEach(DockModuleID.allCases) { platter($0) } }
                HStack(spacing: 10) {
                    platter(.usage, height: 64)
                    platter(.agenda, height: 40)
                }
            }
            .padding(24)
            .background(backdrop)
            .environment(\.colorScheme, .dark)
            write(board, to: out.appendingPathComponent("vassoi-\(name).png"), scale: 3)
        }

        for id in DockModuleID.allCases {
            guard let module = bar.module(id) else { continue }
            let drawerHeight = module.drawerHeight(focus: module.defaultFocus, now: now)
            let framed = ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: DockBarMetrics.drawerCorner, style: .continuous).fill(.black.opacity(0.62))
                    .frame(width: DockDrawerMetrics.width, height: drawerHeight)
                DockModuleDrawer(id: id, focus: module.defaultFocus, now: now)
                    .frame(width: DockDrawerMetrics.width, alignment: .topLeading)
                    .border(.red.opacity(0.35), width: 0.5)
            }
            .padding(20)
            .background(Color(white: 0.2))
            .environment(\.colorScheme, .dark)
            write(framed, to: out.appendingPathComponent("cassetto-\(id.rawValue).png"), scale: 2)
            print("cassetto \(id.rawValue): altezza calcolata \(drawerHeight)")
        }
        _ = height
        // Un vassoio che sparisce, fotogramma per fotogramma, con le stesse funzioni del Dock vero: l'ultimo della fila
        // e il primo (quello accanto al Dock). Niente deve restare staccato dal vicino negli ultimi istanti.
        let usageLayout = DockRowLayout(cells: bar.module(.usage)?.cells(height: height, now: now) ?? [], height: height)
        let systemLayout = DockRowLayout(cells: bar.module(.system)?.cells(height: height, now: now) ?? [], height: height)
        let steps: [Double] = [1, 0.7, 0.45, 0.3, 0.2, 0.12, 0.08, 0.05, 0.03, 0.015, 0.005]
        func frames(fading index: Int) -> some View {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(steps, id: \.self) { p in
                    let tracer = ContourTracer()
                    let layouts = [usageLayout, systemLayout]
                    var cursor: CGFloat = 0
                    var before = 0.0
                    let rows = layouts.enumerated().map { i, layout -> DockRowState in
                        let presence = i == index ? p : 1
                        let (x, width) = DockBar.place(full: layout.width, presence: presence, right: true, cursor: &cursor, before: &before)
                        return DockRowState(id: i == 0 ? .usage : .system, layout: layout, x: x, width: width, presence: presence, press: 0)
                    }
                    let shape = DockBar.outline(rows: rows, height: height, e: 0, tall: 0, focus: nil, centerX: 0,
                                                drawer: .zero, slide: 0, tracer: tracer).path
                    HStack(spacing: 10) {
                        Text(String(format: "%.3f", p)).font(.system(size: 10).monospacedDigit()).foregroundStyle(.white.opacity(0.6))
                            .frame(width: 40, alignment: .trailing)
                        ZStack(alignment: .topLeading) {
                            shape.fill(Color.white.opacity(0.14))
                            shape.stroke(Color.white.opacity(0.7), lineWidth: 0.75)
                        }
                        .frame(width: usageLayout.width + systemLayout.width + 40, height: height, alignment: .topLeading)
                        .offset(x: 10)
                    }
                }
            }
        }
        write(HStack(alignment: .top, spacing: 30) { frames(fading: 1); frames(fading: 0) }
                .padding(20).background(Color(red: 0.16, green: 0.18, blue: 0.5)),
              to: out.appendingPathComponent("sparizione.png"), scale: 2)

        // L'anteprima delle impostazioni, larga come nella finestra.
        write(DockPreview().frame(width: 560).padding(20).background(Color(white: 0.16)),
              to: out.appendingPathComponent("anteprima.png"), scale: 2)
        print("disegni in", out.path)
    }

    /// `Charland --permessi`: quello che macOS concede a questa copia, e a quale app lo attribuisce. Lanciata dal
    /// terminale di un'altra app (Claude, Terminale) i permessi valgono per quell'app, non per Charland: il Calendario
    /// non chiede niente e Charland non compare in Impostazioni di Sistema. Si prova con
    /// `open -W -n --stdout <file> -a Charland.app --args --permessi`.
    static func printPermissions() {
        func name(_ status: AVAuthorizationStatus) -> String {
            switch status {
            case .authorized: "concesso"
            case .denied: "negato"
            case .restricted: "limitato"
            default: "mai chiesto"
            }
        }
        func name(_ status: EKAuthorizationStatus) -> String {
            switch status {
            case .fullAccess: "concesso"
            case .writeOnly: "solo scrittura"
            case .denied: "negato"
            case .restricted: "limitato"
            default: "mai chiesto"
            }
        }
        func name(_ access: IOHIDAccessType) -> String {
            switch access {
            case kIOHIDAccessTypeGranted: "concesso"
            case kIOHIDAccessTypeDenied: "negato"
            default: "mai chiesto"
            }
        }
        print("processo:", ProcessInfo.processInfo.processIdentifier, Bundle.main.bundlePath)
        print("responsabile:", responsibleApp() ?? "sconosciuto")
        print("accessibilità:", AXIsProcessTrusted() ? "concesso" : "no")
        print("microfono:", name(AVCaptureDevice.authorizationStatus(for: .audio)))
        print("calendario:", name(EKEventStore.authorizationStatus(for: .event)))
        print("monitoraggio input:", name(IOHIDCheckAccess(kIOHIDRequestTypeListenEvent)))
        fflush(stdout)
    }

    /// L'app a cui macOS attribuisce i permessi di questo processo (funzione privata di sistema, solo per la prova).
    private static func responsibleApp() -> String? {
        typealias Responsible = @convention(c) (pid_t) -> pid_t
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_get_pid_responsible_for_pid") else { return nil }
        let pid = unsafeBitCast(symbol, to: Responsible.self)(getpid())
        var buffer = [CChar](repeating: 0, count: 4096)
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return "\(pid) " + String(decoding: buffer.prefix(Int(length)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    /// La sezione Dock delle impostazioni in una finestra sua, per guardarla mentre gira la Charland installata
    /// (`Charland --dock --impostazioni`).
    private static var paneWindow: NSWindow?

    static func showPane() {
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 620, height: 640),
                              styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        window.title = "Dock"
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: DockPane())
        window.setContentSize(CGSize(width: 620, height: 640))
        window.center()
        window.orderFrontRegardless()
        paneWindow = window
        print("finestra delle impostazioni:", window.windowNumber); fflush(stdout)
    }

    private static func write(_ view: some View, to url: URL, scale: CGFloat) {
        let renderer = ImageRenderer(content: view)
        renderer.scale = scale
        guard let image = renderer.nsImage, let tiff = image.tiffRepresentation,
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: url)
    }
}
