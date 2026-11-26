import SwiftUI
import AppKit

/// Le parole dettate oggi, contate da Charland (la dettatura tiene le ultime solo in memoria). Si contano mentre il
/// modulo è acceso; il conto riparte a mezzanotte e resta fra un avvio e l'altro.
@MainActor @Observable
final class DictationStats {
    static let shared = DictationStats()

    private(set) var wordsToday = 0
    private(set) var countToday = 0

    @ObservationIgnored private var lastCounted: UUID?
    @ObservationIgnored private var active = false
    /// Cresce a ogni accensione: un ascolto rimasto da un'accensione precedente si accorge di essere vecchio e non si
    /// riarma (spegnere e riaccendere ne lasciava due).
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var day = ""

    private static let dayKey = "dockDictationDay", wordsKey = "dockDictationWords", countKey = "dockDictationCount"

    private init() {
        let d = UserDefaults.standard
        day = d.string(forKey: Self.dayKey) ?? ""
        wordsToday = d.integer(forKey: Self.wordsKey)
        countToday = d.integer(forKey: Self.countKey)
        rollDay()
    }

    func start() {
        guard !active else { return }
        active = true
        generation += 1
        // Quelle già in memoria sono state contate quando sono nate (o il modulo era spento): si parte dalla prossima.
        lastCounted = DictationController.shared.history.first?.id
        rollDay()
        observe()
    }

    func stop() { active = false }

    private func observe() {
        guard active else { return }
        let mine = generation
        withObservationTracking {
            _ = DictationController.shared.history.first?.id
            _ = DictationController.shared.phase
            _ = VoiceSettings.shared.enabled
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self, self.generation == mine else { return }
                self.update()
                self.observe()
            }
        }
    }

    private func update() {
        guard active else { return }
        defer { DockBar.shared.dataChanged() }
        guard let first = DictationController.shared.history.first, first.id != lastCounted else { return }
        lastCounted = first.id
        rollDay()
        guard Calendar.current.isDateInToday(first.date) else { return }
        wordsToday += Self.words(first.text)
        countToday += 1
        save()
    }

    /// Dopo mezzanotte, anche senza dettature nuove (lo chiama il Dock a ogni minuto mentre si vede).
    func rollDayIfNeeded() {
        guard active else { return }
        let before = day
        rollDay()
        if day != before { DockBar.shared.dataChanged() }
    }

    /// A mezzanotte il conto riparte.
    private func rollDay() {
        let today = Self.dayString(Date())
        guard today != day else { return }
        day = today
        wordsToday = 0
        countToday = 0
        save()
    }

    private func save() {
        let d = UserDefaults.standard
        d.set(day, forKey: Self.dayKey)
        d.set(wordsToday, forKey: Self.wordsKey)
        d.set(countToday, forKey: Self.countKey)
    }

    private static func dayString(_ date: Date) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return "\(c.year ?? 0)-\(c.month ?? 0)-\(c.day ?? 0)"
    }

    static func words(_ text: String) -> Int {
        let spaced = text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count
        // Cinese e giapponese non mettono spazi: lì conta i caratteri, come fanno loro.
        let ideographs = text.unicodeScalars.filter { (0x3040...0x30FF).contains($0.value) || (0x4E00...0x9FFF).contains($0.value) }.count
        return ideographs > spaced * 2 ? ideographs : spaced
    }

    /// Quanto tempo hai risparmiato, in minuti: scrivere a mano va a circa 40 parole al minuto, parlare a circa 130.
    var savedMinutes: Int { Int((Double(wordsToday) / 40 - Double(wordsToday) / 130).rounded()) }
}

@MainActor
final class DictationModule: DockModule {
    let id = DockModuleID.dictation
    private let stats = DictationStats.shared
    private var controller: DictationController { .shared }

    var isEmpty: Bool { false }
    var defaultFocus: String? { "dictate" }

    func cells(height: CGFloat, now: Date) -> [DockCell] {
        let size = max(11, (height * 0.27).rounded())
        return [DockCell(id: "dictate", label: DockText.width(Self.label, size: size), open: 1)]
    }

    /// «Detta» a riposo, «Ferma» mentre ascolta (un clic scrive), niente mentre prepara il testo.
    static var label: String {
        guard VoiceSettings.shared.enabled else { return String(localized: "Spenta") }
        switch DictationController.shared.phase {
        case .idle: return String(localized: "Detta")
        case .listening: return String(localized: "Ferma")
        case .working: return String(localized: "Scrivo")
        }
    }

    func drawerHeight(focus: String?, now: Date) -> CGFloat {
        let m = DockDrawerMetrics.self
        var h = m.pad * 2 + m.header + m.gap + m.figure
        let recent = DictationDrawer.recent
        if !recent.isEmpty {
            h += m.gap + DictationDrawer.sectionTitle + CGFloat(recent.count) * DictationDrawer.row
        }
        return h + m.gap + m.footer
    }

    func setActive(_ on: Bool) {
        if on { stats.start() } else { stats.stop() }
    }

    func refresh(look: Bool) { stats.rollDayIfNeeded() }

    func tap(_ cell: String?) {
        Self.toggle()
    }

    /// Un clic: comincia ad ascoltare a mani libere (il testo va nel campo dove stai scrivendo: il Dock non prende la
    /// tastiera), un altro clic ferma e scrive. Con la dettatura spenta apre le impostazioni della voce.
    static func toggle() {
        guard VoiceSettings.shared.enabled else {
            AppServices.shared.showSettings()
            return
        }
        switch DictationController.shared.phase {
        case .idle:
            DictationController.shared.startHandsFreeFromIsland()
            DockBar.shared.closeDrawers()
        case .listening:
            DictationController.shared.stopFromIsland()
        case .working:
            break
        }
    }
}

// MARK: - Vassoio

struct DictationPlatter: View {
    let layout: DockRowLayout
    let hovered: String?
    private let controller = DictationController.shared

    var body: some View {
        let listening = controller.phase == .listening
        let enabled = VoiceSettings.shared.enabled
        ZStack(alignment: .topLeading) {
            DockRing(fraction: listening ? 1 : nil, color: UsageTone.redInk, size: layout.ring, hovered: hovered == "dictate") {
                if controller.phase == .working {
                    SpinArc().frame(width: layout.ring * 0.42, height: layout.ring * 0.42)
                } else {
                    VoiceGlyph(size: (layout.ring * 0.55).rounded())
                        .foregroundStyle(listening ? UsageTone.redInk : .white.opacity(enabled ? 0.95 : 0.5))
                }
            }
            .offset(x: layout.x(of: "dictate"), y: layout.pad)
            DockLabel(text: DictationModule.label, layout: layout, cell: "dictate",
                      color: listening ? UsageTone.redInk : .white.opacity(enabled ? 1 : 0.6))
        }
        .animation(.snappy(duration: 0.3), value: controller.phase)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }
}

// MARK: - Cassetto

struct DictationDrawer: View {
    static let sectionTitle: CGFloat = 22
    static let row: CGFloat = 44
    private let stats = DictationStats.shared
    private let controller = DictationController.shared
    @State private var copied: UUID?

    /// Le ultime tre dettature, se le vuoi vedere qui (in una condivisione dello schermo potrebbero essere private).
    @MainActor static var recent: [DictationRecord] {
        guard DockSettings.shared.dictationShowText else { return [] }
        return Array(DictationController.shared.history.prefix(3))
    }

    var body: some View {
        let m = DockDrawerMetrics.self
        let voice = VoiceSettings.shared
        VStack(alignment: .leading, spacing: 0) {
            DrawerHeader(title: String(localized: "Dettatura"), chip: voice.enabled ? voice.combo.display : nil,
                         busy: controller.phase == .working) {
                VoiceGlyph(size: 18)
            }
            HStack(alignment: .top, spacing: 18) {
                DrawerFigure(title: String(localized: "Parole oggi"), value: stats.wordsToday.formatted())
                DrawerFigure(title: String(localized: "Tempo risparmiato"), value: String(localized: "\(stats.savedMinutes) min"))
            }
            .padding(.top, m.gap)
            let recent = Self.recent
            if !recent.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    Text("Ultime")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.55))
                        .frame(height: Self.sectionTitle, alignment: .topLeading)
                    ForEach(recent) { record in row(record) }
                }
                .padding(.top, m.gap)
            }
            DrawerButton(title: !voice.enabled ? String(localized: "Accendi la dettatura")
                         : controller.phase == .listening ? String(localized: "Ferma e scrivi") : String(localized: "Detta"),
                         prominent: voice.enabled) {
                DictationModule.toggle()
            }
            .padding(.top, m.gap)
        }
    }

    /// Una dettatura: un clic la copia negli appunti.
    private func row(_ record: DictationRecord) -> some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(record.text, forType: .string)
            Haptics.tick()
            copied = record.id
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { if copied == record.id { copied = nil } }
        } label: {
            HStack(alignment: .center, spacing: 8) {
                Text(verbatim: record.text)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.85))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: copied == record.id ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(copied == record.id ? 0.95 : 0.4))
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: 16)
            }
            .frame(height: Self.row)
            .contentShape(Rectangle())
        }
        .buttonStyle(TilePress())
        .help(String(localized: "Copia"))
    }
}
