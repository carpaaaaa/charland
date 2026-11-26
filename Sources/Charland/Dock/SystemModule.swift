import SwiftUI
import AppKit
import Darwin

/// Processore, memoria e disco, letti dai contatori del Mac (niente esce dal Mac, nessun permesso). Come docktor, ma
/// con gli anelli di Charland: un anello per misura col suo simbolo, e il numero di quella scelta.
@MainActor @Observable
final class SystemStats {
    static let shared = SystemStats()

    enum Metric: String, CaseIterable, Identifiable, Sendable {
        case cpu, memory, disk
        var id: String { rawValue }
        var title: String {
            switch self {
            case .cpu: String(localized: "Processore")
            case .memory: String(localized: "Memoria")
            case .disk: String(localized: "Disco")
            }
        }
        var symbol: String {
            switch self {
            case .cpu: "cpu"
            case .memory: "memorychip"
            case .disk: "internaldrive"
            }
        }
    }

    /// I numeri che si disegnano: il processore occupato da 0 a 1 e com'è andato negli ultimi minuti, la memoria, il
    /// disco. Si pubblicano solo mentre il Dock li mostra (e il grafico solo col cassetto aperto): ogni numero nuovo fa
    /// ripartire le molle degli anelli e ridisegna vassoio e cassetto, anche fuori dallo schermo. Misurato il 17
    /// novembre: 6,7% di processore a riposo col Dock nascosto. Nascosto, le letture continuano ogni 3 s per il
    /// grafico, senza toccare niente che si vede.
    private(set) var cpu = 0.0
    private(set) var history: [(time: Date, value: Double)] = []
    private(set) var memoryUsed: UInt64 = 0
    let memoryTotal = ProcessInfo.processInfo.physicalMemory
    private(set) var diskUsed: Int64 = 0
    private(set) var diskTotal: Int64 = 0
    /// Almeno due letture del processore: prima il numero non vuol dire niente.
    private(set) var ready = false

    // Le letture vere, che non si vedono finché non si pubblicano.
    @ObservationIgnored private var rawCPU = 0.0
    @ObservationIgnored private var rawHistory: [(time: Date, value: Double)] = []
    @ObservationIgnored private var rawMemory: UInt64 = 0
    @ObservationIgnored private var rawDiskUsed: Int64 = 0
    @ObservationIgnored private var rawDiskTotal: Int64 = 0
    @ObservationIgnored private var rawReady = false
    @ObservationIgnored private var visible = false

    @ObservationIgnored private let host = mach_host_self()
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var previous: (busy: UInt64, total: UInt64)?
    @ObservationIgnored private var lastDisk = Date.distantPast
    @ObservationIgnored private var fast = false
    @ObservationIgnored private var wasWide = false

    /// Quanto tempo racconta il grafico del processore.
    static let span: TimeInterval = 120

    private init() {}

    func value(_ metric: Metric) -> Double {
        switch metric {
        case .cpu: cpu
        case .memory: memoryTotal > 0 ? Double(memoryUsed) / Double(memoryTotal) : 0
        case .disk: diskTotal > 0 ? Double(diskUsed) / Double(diskTotal) : 0
        }
    }

    /// Acceso: una lettura ogni tre secondi (il grafico degli ultimi due minuti è pronto quando lo guardi), una al
    /// secondo mentre il suo cassetto è aperto. Costa qualche microsecondo; spento non gira niente.
    func start() {
        guard timer == nil else { return }
        sample()
        schedule()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        previous = nil
        rawReady = false
        rawHistory = []
        ready = false
        history = []
    }

    /// Il Dock mostra i vassoi (o no): da qui si decide se i numeri nuovi si disegnano.
    func setVisible(_ on: Bool) {
        guard on != visible else { return }
        visible = on
        if on { publish() }
    }

    func setFast(_ on: Bool) {
        guard on != fast else { return }
        fast = on
        guard timer != nil else { return }
        if on { sample() }
        schedule()
    }

    /// Le letture vere diventano quelle che si disegnano, solo se cambia quello che si legge (il numero intero): un
    /// processore che passa da 12,3% a 12,4% non ridisegna niente. Col cassetto aperto tutto, anche il grafico.
    private func publish() {
        func percent(_ v: Double) -> Int { Int((v * 100).rounded()) }
        if fast || percent(cpu) != percent(rawCPU) { cpu = rawCPU }
        if ready != rawReady { ready = rawReady }
        let total = Double(max(1, memoryTotal))
        if fast || percent(Double(memoryUsed) / total) != percent(Double(rawMemory) / total) { memoryUsed = rawMemory }
        if diskUsed != rawDiskUsed { diskUsed = rawDiskUsed }
        if diskTotal != rawDiskTotal { diskTotal = rawDiskTotal }
        if fast || history.isEmpty { history = rawHistory }
    }

    private func schedule() {
        timer?.invalidate()
        let interval: TimeInterval = fast ? 1 : 3
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sample() }
        }
        timer.tolerance = fast ? 0.1 : 1
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func sample() {
        let now = Date()
        if let ticks = cpuTicks() {
            if let previous, ticks.total > previous.total {
                rawCPU = min(1, max(0, Double(ticks.busy &- previous.busy) / Double(ticks.total &- previous.total)))
                rawReady = true
                rawHistory.append((now, rawCPU))
                rawHistory.removeAll { now.timeIntervalSince($0.time) > Self.span + 4 }
            }
            previous = ticks
        }
        if let used = memoryInUse() { rawMemory = used }
        if now.timeIntervalSince(lastDisk) > 60 {
            lastDisk = now
            refreshDisk()
        }
        guard visible else { return }
        publish()
        // A 100% il numero ha una cifra in più: il vassoio deve fargli posto.
        let wide = Metric.allCases.contains { value($0) >= 0.995 }
        if wide != wasWide {
            wasWide = wide
            DockBar.shared.dataChanged()
        }
    }

    /// I tic del processore dall'accensione: occupato (utente, sistema, bassa priorità) e in tutto.
    private func cpuTicks() -> (busy: UInt64, total: UInt64)? {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics(host, HOST_CPU_LOAD_INFO, $0, &count) }
        }
        guard result == KERN_SUCCESS else { return nil }
        let user = UInt64(info.cpu_ticks.0), system = UInt64(info.cpu_ticks.1)
        let idle = UInt64(info.cpu_ticks.2), nice = UInt64(info.cpu_ticks.3)
        return (user + system + nice, user + system + nice + idle)
    }

    /// La memoria usata come la conta Monitoraggio Attività: memoria delle app, più quella fissa, più quella compressa.
    private func memoryInUse() -> UInt64? {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics64(host, HOST_VM_INFO64, $0, &count) }
        }
        guard result == KERN_SUCCESS else { return nil }
        let page = UInt64(getpagesize())
        let app = UInt64(stats.internal_page_count) - min(UInt64(stats.internal_page_count), UInt64(stats.purgeable_count))
        return (app + UInt64(stats.wire_count) + UInt64(stats.compressor_page_count)) * page
    }

    /// Per i disegni di prova: due letture vere e un grafico finto degli ultimi due minuti.
    func primeForChecks() {
        sample()
        usleep(250_000)
        sample()
        readDisk()
        let now = Date()
        var points: [(time: Date, value: Double)] = []
        for i in 0..<40 {
            let wave: Double = 0.14 * sin(Double(i) / 4)
            let spike: Double = i % 7 == 0 ? 0.2 : 0
            points.append((time: now.addingTimeInterval(-Double(39 - i) * 3), value: 0.18 + wave + spike))
        }
        rawHistory = points
        rawCPU = points.last?.value ?? rawCPU
        visible = true
        fast = true
        publish()
    }

    /// Il disco di avvio: lo spazio libero è quello che il Mac considera disponibile per le cose importanti (conta anche
    /// quello che può liberare da solo), come lo mostra il Finder.
    private func readDisk() {
        guard let reading = Self.diskReading() else { return }
        rawDiskTotal = reading.total
        rawDiskUsed = reading.used
    }

    /// Lo spazio del disco si chiede fuori dal thread principale: «disponibile per le cose importanti» fa lavorare il
    /// sistema per decine di millisecondi (25 misurati il 18 novembre 2026), e lì era un fotogramma perso ogni minuto.
    private func refreshDisk() {
        DispatchQueue.global(qos: .utility).async {
            guard let reading = Self.diskReading() else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    let stats = SystemStats.shared
                    stats.rawDiskTotal = reading.total
                    stats.rawDiskUsed = reading.used
                    if stats.visible { stats.publish() }
                }
            }
        }
    }

    private nonisolated static func diskReading() -> (total: Int64, used: Int64)? {
        let values = try? URL(fileURLWithPath: "/").resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey])
        guard let total = values?.volumeTotalCapacity, total > 0 else { return nil }
        let free = values?.volumeAvailableCapacityForImportantUsage ?? 0
        return (Int64(total), max(0, Int64(total) - free))
    }

    /// «11,9 GB», «246 GB», «1,2 TB»: una cifra decimale sotto i cento, nessuna sopra. La memoria in unità da 1024
    /// (come la conta il Mac), il disco da 1000 (come il Finder).
    static func memory(_ bytes: UInt64) -> String { format(Double(bytes), base: 1024) }

    static func file(_ bytes: Int64) -> String { format(Double(bytes), base: 1000) }

    private static func format(_ bytes: Double, base: Double) -> String {
        let gb = bytes / (base * base * base)
        let (value, unit) = gb >= 1000 ? (gb / base, "TB") : (gb, "GB")
        return value.formatted(.number.precision(.fractionLength(0...(value >= 100 ? 0 : 1)))) + " " + unit
    }
}

@MainActor
final class SystemModule: DockModule {
    let id = DockModuleID.system
    private var settings: DockSettings { .shared }
    private let stats = SystemStats.shared

    var metrics: [SystemStats.Metric] { SystemStats.Metric.allCases.filter { settings.systemMetrics.contains($0) } }
    var isEmpty: Bool { metrics.isEmpty }

    var selected: SystemStats.Metric? {
        metrics.contains(settings.systemSelected) ? settings.systemSelected : metrics.first
    }

    func cells(height: CGFloat, now: Date) -> [DockCell] {
        let size = max(11, (height * 0.27).rounded())
        let chosen = selected
        // Larga almeno come «88%»: fra 5% e 95% il vassoio non cambia misura; solo a 100% si allarga (con la molla).
        let least = DockText.width("88%", size: size)
        return metrics.map { metric in
            DockCell(id: metric.rawValue, label: max(least, DockText.width(Self.label(metric), size: size)), open: metric == chosen ? 1 : 0)
        }
    }

    var defaultFocus: String? { selected?.rawValue }

    func drawerHeight(focus: String?, now: Date) -> CGFloat {
        let m = DockDrawerMetrics.self
        var h = m.pad * 2 + m.header
        for metric in metrics {
            h += (metric == metrics.first ? m.gap : 12) + (metric == .cpu ? SystemDrawer.cpuHeight : SystemDrawer.rowHeight)
        }
        return h + m.gap + m.footer
    }

    func setActive(_ on: Bool) {
        if on { stats.start() } else { stats.stop() }
    }

    func refresh(look: Bool) {}

    func tap(_ cell: String?) {
        guard let metric = cell.flatMap(SystemStats.Metric.init(rawValue:)), settings.systemSelected != metric else { return }
        Haptics.tick()
        settings.systemSelected = metric
    }

    func scroll(_ step: Int) -> Bool {
        let list = metrics
        guard list.count > 1, let current = selected, let index = list.firstIndex(of: current) else { return false }
        tap(list[(index + step + list.count) % list.count].rawValue)
        return true
    }

    /// Il cassetto è aperto su questo modulo: letture più fitte.
    func drawerOpen(_ open: Bool) { stats.setFast(open) }

    /// Il numero di una misura.
    static func label(_ metric: SystemStats.Metric) -> String {
        "\(Int((SystemStats.shared.value(metric) * 100).rounded()))%"
    }
}

// MARK: - Vassoio

struct SystemPlatter: View {
    let layout: DockRowLayout
    let hovered: String?
    private let stats = SystemStats.shared

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(layout.cells) { cell in
                if let metric = SystemStats.Metric(rawValue: cell.id) {
                    let value = stats.value(metric)
                    let color = UsageTone.color(used: value * 100)
                    DockRing(fraction: stats.ready || metric != .cpu ? value : nil, color: color, size: layout.ring,
                             hovered: hovered == cell.id, animated: false) {
                        Image(systemName: metric.symbol)
                            .font(.system(size: (layout.ring * 0.36).rounded(), weight: .semibold))
                            .foregroundStyle(.white.opacity(0.92))
                    }
                    .offset(x: layout.x(of: cell.id), y: layout.pad)
                    .accessibilityElement()
                    .accessibilityLabel(Text(verbatim: "\(metric.title) \(SystemModule.label(metric))"))
                    DockLabel(text: SystemModule.label(metric), layout: layout, cell: cell.id, color: color, animated: false)
                }
            }
        }
    }
}

// MARK: - Cassetto

struct SystemDrawer: View {
    static let cpuHeight: CGFloat = 18 + 6 + 46
    static let rowHeight: CGFloat = 49
    private let stats = SystemStats.shared
    private let settings = DockSettings.shared

    var body: some View {
        let m = DockDrawerMetrics.self
        let metrics = SystemStats.Metric.allCases.filter { settings.systemMetrics.contains($0) }
        VStack(alignment: .leading, spacing: 0) {
            DrawerHeader(title: String(localized: "Sistema")) {
                Image(systemName: "cpu").font(.system(size: 14, weight: .semibold)).frame(width: 18)
            }
            ForEach(metrics) { metric in
                Group {
                    switch metric {
                    case .cpu: cpu
                    case .memory:
                        row(metric, left: String(localized: "\(SystemStats.memory(stats.memoryUsed)) usati"),
                            right: String(localized: "di \(SystemStats.memory(stats.memoryTotal))"))
                    case .disk:
                        row(metric, left: String(localized: "\(SystemStats.file(max(0, stats.diskTotal - stats.diskUsed))) liberi"),
                            right: String(localized: "di \(SystemStats.file(stats.diskTotal))"))
                    }
                }
                .padding(.top, metric == metrics.first ? m.gap : 12)
            }
            DrawerButton(title: String(localized: "Apri Monitoraggio Attività")) {
                DockLaunch.open(bundle: "com.apple.ActivityMonitor")
                DockBar.shared.closeDrawers()
            }
            .padding(.top, m.gap)
        }
    }

    private func title(_ metric: SystemStats.Metric) -> some View {
        let value = stats.value(metric) * 100
        return HStack(alignment: .firstTextBaseline) {
            Text(metric.title).font(.system(size: 13, weight: .medium)).foregroundStyle(.white.opacity(0.82))
            Spacer(minLength: 6)
            Text(verbatim: "\(Int(value.rounded()))%")
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(UsageTone.color(used: value))
                .contentTransition(.numericText())
                .animation(.snappy(duration: 0.3), value: Int(value.rounded()))
        }
        .frame(height: 18)
    }

    private var cpu: some View {
        VStack(alignment: .leading, spacing: 6) {
            title(.cpu)
            CPUGraph(points: stats.history, now: Date())
                .frame(height: 46)
        }
        .frame(height: Self.cpuHeight)
    }

    private func row(_ metric: SystemStats.Metric, left: String, right: String) -> some View {
        let value = stats.value(metric)
        return VStack(alignment: .leading, spacing: 0) {
            title(metric)
            DrawerBar(fraction: value, color: UsageTone.color(used: value * 100)).padding(.top, 4)
            HStack {
                Text(verbatim: left)
                Spacer(minLength: 6)
                Text(verbatim: right)
            }
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.white.opacity(0.5))
            .lineLimit(1)
            .frame(height: 14)
            .padding(.top, 3)
        }
        .frame(height: Self.rowHeight)
    }
}

/// L'andamento del processore negli ultimi due minuti: una linea morbida con un velo sotto, il presente a destra. La
/// scala segue il picco (almeno fino al 40%): a riposo la linea non è un filo schiacciato sul fondo.
struct CPUGraph: View {
    let points: [(time: Date, value: Double)]
    let now: Date

    var body: some View {
        Canvas { context, size in
            // La linea di base, così il grafico vuoto non è un buco.
            context.fill(Path(CGRect(x: 0, y: size.height - 1, width: size.width, height: 1)), with: .color(.white.opacity(0.12)))
            let span = SystemStats.span
            let visible = points.filter { now.timeIntervalSince($0.time) <= span + 4 }
            guard visible.count > 1 else { return }
            let ceiling = min(1, max(0.4, ((visible.map(\.value).max() ?? 0) * 1.15 * 10).rounded(.up) / 10))
            func point(_ sample: (time: Date, value: Double)) -> CGPoint {
                let x = size.width * CGFloat(1 - now.timeIntervalSince(sample.time) / span)
                let y = (size.height - 2) * CGFloat(1 - min(1, sample.value / ceiling)) + 1
                return CGPoint(x: x, y: y)
            }
            let all = visible.map(point)
            var line = Path()
            line.move(to: all[0])
            for i in 1..<all.count {
                let a = all[i - 1], b = all[i]
                let mid = CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
                line.addQuadCurve(to: mid, control: a)
                if i == all.count - 1 { line.addQuadCurve(to: b, control: b) }
            }
            var area = line
            area.addLine(to: CGPoint(x: all[all.count - 1].x, y: size.height))
            area.addLine(to: CGPoint(x: all[0].x, y: size.height))
            area.closeSubpath()
            context.fill(area, with: .linearGradient(Gradient(colors: [.white.opacity(0.22), .white.opacity(0)]),
                                                     startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))
            context.stroke(line, with: .color(.white.opacity(0.9)), style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
        }
        .accessibilityHidden(true)
    }
}
