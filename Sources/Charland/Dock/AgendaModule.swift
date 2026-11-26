import SwiftUI
import AppKit
import EventKit

/// Un evento del Calendario, copiato in un valore semplice: gli oggetti di EventKit restano nel deposito.
struct AgendaEvent: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let start: Date
    let end: Date
    let allDay: Bool
    /// Il colore del suo calendario, in sRGB.
    let red: Double, green: Double, blue: Double
    let location: String?
    /// Il link della riunione (Zoom, Meet, Teams, FaceTime…), se c'è.
    let meeting: URL?
    /// Una cosa da fare di Charcal, non un evento del Calendario. Per le cose il «luogo» è il nome dell'etichetta.
    var task = false
    /// Una cosa da fare con un'ora ma senza durata: passata l'ora è «adesso», non «in corso fino alle».
    var openEnded = false
    /// Una cosa da fare per «stasera», senza un'ora precisa.
    var evening = false
    /// Una cosa da fare con un ultimo giorno (un viaggio): vale tutto il giorno, non è «senza ora».
    var span = false
    /// Una cosa da fare già fatta: solo il righello della giornata le legge (`CharcalAgenda.dayItems`).
    var done = false

    var color: Color { Color(red: red, green: green, blue: blue) }

    func inProgress(at now: Date) -> Bool { !allDay && start <= now && end > now }
}

/// Un calendario del Mac, per scegliere nelle impostazioni quali guardare.
struct AgendaCalendar: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let source: String
    let red: Double, green: Double, blue: Double
    var color: Color { Color(red: red, green: green, blue: blue) }
}

/// Il lettore del Calendario, su una coda sua: EventKit legge in modo sincrono e con molti account (Google, Exchange)
/// può metterci decine di millisecondi, che sul thread principale sarebbero fotogrammi persi. Lo store e il cercatore
/// di link vivono solo su questa coda.
final class AgendaReader: @unchecked Sendable {
    struct Result: Sendable {
        let calendars: [AgendaCalendar]
        let events: [AgendaEvent]
    }

    private let queue = DispatchQueue(label: "charland.agenda", qos: .utility)
    private var store: EKEventStore?
    private var detector: NSDataDetector?

    func reset() { queue.async { self.store = nil } }

    func read(hidden: Set<String>, done: @escaping @Sendable (Result) -> Void) {
        queue.async { [self] in
            if store == nil { store = EKEventStore() }
            guard let store else { return }
            let now = Date()
            let all = store.calendars(for: .event)
            let calendars = all.map { calendar -> AgendaCalendar in
                let color = (calendar.color ?? .gray).usingColorSpace(.sRGB) ?? .gray
                return AgendaCalendar(id: calendar.calendarIdentifier, title: calendar.title, source: calendar.source?.title ?? "",
                                      red: color.redComponent, green: color.greenComponent, blue: color.blueComponent)
            }.sorted { ($0.source, $0.title) < ($1.source, $1.title) }
            let chosen = all.filter { !hidden.contains($0.calendarIdentifier) }
            var events: [AgendaEvent] = []
            if !chosen.isEmpty {
                // Da qualche ora fa (un evento lungo già cominciato) alla fine di domani.
                let calendar = Calendar.current
                let from = now.addingTimeInterval(-12 * 3600)
                let to = calendar.date(byAdding: .day, value: 2, to: calendar.startOfDay(for: now)) ?? now.addingTimeInterval(48 * 3600)
                let predicate = store.predicateForEvents(withStart: from, end: to, calendars: chosen)
                // Giorno per giorno (un evento cominciato ieri vale per oggi); in ogni giorno prima quelli di tutto il
                // giorno, poi per ora. Gli invitati si guardano solo per i primi, dopo averli ordinati.
                let sorted = store.events(matching: predicate)
                    .filter { $0.status != .canceled && $0.endDate > now }
                    .sorted {
                        let a = AgendaText.day(of: $0.startDate, now: now), b = AgendaText.day(of: $1.startDate, now: now)
                        if a != b { return a < b }
                        if $0.isAllDay != $1.isAllDay { return $0.isAllDay }
                        return $0.startDate < $1.startDate
                    }
                for event in sorted where !Self.declined(event) {
                    events.append(value(event))
                    if events.count >= 30 { break }
                }
            }
            done(Result(calendars: calendars, events: events))
        }
    }

    /// Tutti gli eventi fra due istanti, anche quelli già finiti: il righello della giornata (`DayRulerStore`) mostra
    /// anche la mattina passata. Nell'ordine in cui cominciano.
    func readRange(from: Date, to: Date, hidden: Set<String>, done: @escaping @Sendable ([AgendaEvent]) -> Void) {
        queue.async { [self] in
            if store == nil { store = EKEventStore() }
            guard let store else { return }
            let chosen = store.calendars(for: .event).filter { !hidden.contains($0.calendarIdentifier) }
            guard !chosen.isEmpty else { done([]); return }
            let predicate = store.predicateForEvents(withStart: from, end: to, calendars: chosen)
            let events = store.events(matching: predicate)
                .filter { $0.status != .canceled && !Self.declined($0) }
                .sorted { $0.startDate < $1.startDate }
                .prefix(80)
                .map { value($0) }
            done(Array(events))
        }
    }

    private static func declined(_ event: EKEvent) -> Bool {
        event.attendees?.first { $0.isCurrentUser }?.participantStatus == .declined
    }

    private func value(_ event: EKEvent) -> AgendaEvent {
        let color = (event.calendar?.color ?? .gray).usingColorSpace(.sRGB) ?? .gray
        let title = (event.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let location = event.location?.trimmingCharacters(in: .whitespacesAndNewlines)
        let meeting = meeting(for: event)
        return AgendaEvent(id: event.calendarItemIdentifier + "|\(event.startDate.timeIntervalSince1970)",
                           title: title.isEmpty ? String(localized: "Senza titolo") : title,
                           start: event.startDate, end: event.endDate, allDay: event.isAllDay,
                           red: color.redComponent, green: color.greenComponent, blue: color.blueComponent,
                           // Un luogo che è solo il link della riunione non si scrive: c'è il pulsante «Partecipa».
                           location: location?.isEmpty == false && link(in: location ?? "") == nil ? location : nil,
                           meeting: meeting)
    }

    /// Il link della riunione: quello dell'evento, o il primo link di una piattaforma nota nel luogo o nelle note.
    private func meeting(for event: EKEvent) -> URL? {
        if let url = event.url, Self.isMeeting(url) { return url }
        return link(in: [event.location, event.notes].compactMap { $0 }.joined(separator: "\n"))
    }

    private static let meetingHosts = ["zoom.us", "meet.google.com", "teams.microsoft.com", "teams.live.com", "webex.com",
                                       "whereby.com", "facetime.apple.com", "meet.jit.si", "around.co", "gotomeeting.com"]

    private static func isMeeting(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased(), url.scheme?.hasPrefix("http") == true else { return false }
        return meetingHosts.contains { host == $0 || host.hasSuffix("." + $0) }
    }

    private func link(in text: String) -> URL? {
        guard !text.isEmpty else { return nil }
        if detector == nil { detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) }
        guard let detector else { return nil }
        for match in detector.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            if let url = match.url, Self.isMeeting(url) { return url }
        }
        return nil
    }
}

/// Gli eventi di oggi e di domani, dal Calendario del Mac (EventKit: anche Google o Exchange, se sono nel Calendario).
/// Il permesso si chiede solo quando lo chiedi tu, da Impostazioni o toccando il modulo: mai finestre a sorpresa.
@MainActor @Observable
final class AgendaStore {
    static let shared = AgendaStore()

    enum Access: Equatable { case unknown, denied, granted }

    private(set) var access: Access = .unknown
    /// Gli eventi del Calendario e le cose di Charcal insieme, nell'ordine in cui si mostrano.
    private(set) var events: [AgendaEvent] = []
    @ObservationIgnored private var calendarEvents: [AgendaEvent] = []
    /// I calendari del Mac, per scegliere nelle impostazioni quali guardare.
    private(set) var calendars: [AgendaCalendar] = []

    @ObservationIgnored private let reader = AgendaReader()
    @ObservationIgnored private var observer: NSObjectProtocol?
    @ObservationIgnored private var active = false
    @ObservationIgnored private var lastLoad = Date.distantPast
    @ObservationIgnored private var reloadPending = false
    @ObservationIgnored private var checkingAccess = false
    @ObservationIgnored private var loading = false
    @ObservationIgnored private var loadAgain = false

    private init() {
        refreshAccess()
    }

    private nonisolated static func currentAccess() -> Access {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess: .granted
        case .notDetermined: .unknown
        default: .denied
        }
    }

    /// Si leggono gli eventi del Calendario: c'è il permesso e non l'hai scollegato in Impostazioni › Calendario.
    var usingCalendar: Bool { access == .granted && DockSettings.shared.agendaCalendarOn }

    func start() {
        active = true
        refreshAccess()
        if usingCalendar {
            connect()
            load()
        }
        CharcalAgenda.shared.start()
    }

    func stop() {
        active = false
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        reader.reset()
        calendarEvents = []
        events = []
        CharcalAgenda.shared.stop()
    }

    /// C'è da dove leggere: il Calendario col permesso, o Charcal collegato.
    var hasSource: Bool { usingCalendar || CharcalAgenda.shared.connected }

    /// Calendario collegato o scollegato nelle impostazioni: scollegato smette di leggerlo e toglie i suoi eventi.
    func calendarChoiceChanged() {
        guard active else { return }
        if usingCalendar {
            connect()
            lastLoad = .distantPast
            load()
        } else {
            if let observer { NotificationCenter.default.removeObserver(observer) }
            observer = nil
            calendarEvents = []
            rebuild()
        }
        DockBar.shared.dataChanged()
        DayRulerStore.shared.sourcesChanged()
    }

    /// Le cose di Charcal sono cambiate (lette, collegato, scollegato, o la scelta di quelle senza ora).
    func charcalChanged() {
        guard active else { return }
        rebuild()
    }

    /// Unisce le due fonti. Giorno per giorno: prima gli eventi di tutto il giorno, poi tutto quello che ha un'ora, in
    /// fondo le cose di Charcal senza ora (sono tante e non devono spingere fuori dal cassetto gli impegni veri).
    private func rebuild() {
        let now = Date()
        let charcal = CharcalAgenda.shared
        var all = calendarEvents
        if charcal.connected {
            let tasks = charcal.items.filter { !$0.allDay || $0.span || DockSettings.shared.charcalUntimed }
            // Chi ha messo anche il calendario di Charcal (il suo feed) nel Calendario vedrebbe tutto due volte: vince la
            // cosa di Charcal, che sa di essere una cosa da fare.
            func key(_ event: AgendaEvent) -> String {
                event.title.lowercased() + "|" + String(Int(event.allDay ? Calendar.current.startOfDay(for: event.start).timeIntervalSince1970
                                                              : (event.start.timeIntervalSince1970 / 60).rounded() * 60))
            }
            let keys = Set(charcal.items.map(key))
            all = all.filter { !keys.contains(key($0)) } + tasks
        }
        func rank(_ event: AgendaEvent) -> Int { event.allDay ? (event.task ? 2 : 0) : 1 }
        let merged = all.filter { $0.end > now }.sorted {
            let a = AgendaText.day(of: $0.start, now: now), b = AgendaText.day(of: $1.start, now: now)
            if a != b { return a < b }
            if rank($0) != rank($1) { return rank($0) < rank($1) }
            if $0.start != $1.start { return $0.start < $1.start }
            return $0.title < $1.title
        }
        guard merged != events else { return }
        events = merged
        DockBar.shared.dataChanged()
    }

    /// Rilegge se è passato più di un minuto, e guarda se l'accesso è cambiato nel frattempo (da Impostazioni di
    /// Sistema). Chiedere lo stato del permesso al sistema può fermare il thread per decine di millisecondi: si chiede
    /// in sottofondo.
    func refresh(look: Bool = false) {
        refreshAccess()
        if active { CharcalAgenda.shared.refresh(look: look) }
        guard usingCalendar, active, Date().timeIntervalSince(lastLoad) > 60 else { return }
        load()
    }

    /// Impostazioni › Calendario aperta: l'elenco dei calendari serve anche se niente legge gli impegni in questo momento
    /// (vassoio del Dock e segno del blocco spenti). Prima l'elenco si vedeva solo nella sezione Dock, a vassoio acceso.
    func loadCalendarsForSettings() {
        guard usingCalendar, calendars.isEmpty || !active else { return }
        load()
    }

    /// Rilegge subito (una scelta dei calendari cambiata nelle impostazioni).
    func refreshNow() {
        lastLoad = .distantPast
        refresh()
        DayRulerStore.shared.sourcesChanged()
    }

    /// Solo lo stato del permesso: le impostazioni lo guardano mentre sono aperte (lo puoi cambiare in Impostazioni di
    /// Sistema senza passare di qui).
    func refreshAccess() {
        guard !checkingAccess else { return }
        checkingAccess = true
        DispatchQueue.global(qos: .utility).async {
            let now = Self.currentAccess()
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    let shared = AgendaStore.shared
                    shared.checkingAccess = false
                    guard now != shared.access else { return }
                    shared.access = now
                    if shared.usingCalendar, shared.active {
                        shared.connect()
                        shared.load()
                    }
                    DockBar.shared.dataChanged()
                    // Il righello della giornata guarda lo stesso permesso.
                    DayRulerStore.shared.sourcesChanged()
                }
            }
        }
    }

    /// Chiede il permesso: solo dopo un tuo clic.
    func requestAccess() {
        guard access == .unknown else { return }
        let store = EKEventStore()
        Task { @MainActor in
            let granted = (try? await store.requestFullAccessToEvents()) ?? false
            self.access = granted ? .granted : .denied
            self.refreshAccess()
            if self.usingCalendar, self.active {
                self.connect()
                self.load()
            }
            DockBar.shared.dataChanged()
        }
    }

    private func connect() {
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleReload() }
        }
    }

    /// Un cambiamento nel Calendario arriva spesso a raffiche: si rilegge una volta, un attimo dopo.
    private func scheduleReload() {
        guard !reloadPending else { return }
        reloadPending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.reloadPending = false
                self.lastLoad = .distantPast
                if self.active, self.usingCalendar { self.load() }
            }
        }
    }

    private func load() {
        // Una richiesta arrivata a lettura in corso non si perde: si rilegge appena questa finisce. Prima, togliendo
        // due calendari di fila nelle impostazioni, il secondo restava visibile fino alla lettura dopo.
        guard !loading else { loadAgain = true; return }
        loading = true
        lastLoad = Date()
        reader.read(hidden: DockSettings.shared.agendaHiddenCalendars) { result in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    let shared = AgendaStore.shared
                    shared.loading = false
                    let again = shared.loadAgain
                    shared.loadAgain = false
                    // Scollegato mentre leggeva: niente di quello che è arrivato si mostra.
                    guard shared.usingCalendar else { return }
                    defer { if again { shared.load() } }
                    // L'elenco dei calendari serve anche a Impostazioni › Calendario quando niente legge gli impegni
                    // (`loadCalendarsForSettings`): prima si buttava via e la sezione diceva «Nessun calendario sul Mac».
                    if shared.calendars != result.calendars { shared.calendars = result.calendars }
                    guard shared.active else { return }
                    if shared.calendarEvents != result.events {
                        shared.calendarEvents = result.events
                        shared.rebuild()
                    }
                }
            }
        }
    }

    /// Il prossimo evento con un'ora (quello in corso, se c'è).
    func next(at now: Date) -> AgendaEvent? {
        let timed = events.lazy.filter { !$0.allDay && $0.end > now }
        guard let first = timed.first else { return nil }
        // Una cosa da fare senza durata, la cui ora è passata, resta «adesso» per un quarto d'ora: non deve coprire una
        // riunione che comincia in quel quarto d'ora.
        if first.openEnded, first.start <= now,
           let meeting = timed.dropFirst().first(where: { !$0.openEnded && $0.start < first.end }) {
            return meeting
        }
        return first
    }

    /// Per le prove fuori schermo: eventi finti.
    func useSample(now: Date) {
        access = .granted
        func event(_ title: String, _ minutes: Double, _ length: Double, _ color: (Double, Double, Double), location: String? = nil,
                   meeting: String? = nil, allDay: Bool = false) -> AgendaEvent {
            AgendaEvent(id: title, title: title, start: now.addingTimeInterval(minutes * 60),
                        end: now.addingTimeInterval((minutes + length) * 60), allDay: allDay,
                        red: color.0, green: color.1, blue: color.2, location: location, meeting: meeting.flatMap(URL.init(string:)))
        }
        calendarEvents = [
            event("Design review", 12, 30, (0.98, 0.42, 0.36), meeting: "https://meet.google.com/abc-defg-hij"),
            event("Lunch", 95, 60, (0.30, 0.78, 0.46), location: "Corner Café"),
            event("Call with Sam", 240, 30, (0.36, 0.58, 1.0)),
            event("Gym", 60 * 18, 90, (0.75, 0.48, 0.95), location: "Main Street 3"),
        ]
        rebuild()
    }
}

enum AgendaText {
    static func time(_ date: Date) -> String { date.formatted(.dateTime.hour().minute()) }

    /// Il giorno in cui un evento conta: quello in cui comincia, o oggi se è cominciato prima.
    static func day(of start: Date, now: Date) -> Date { Calendar.current.startOfDay(for: max(start, now)) }

    static func isTomorrow(_ date: Date, now: Date) -> Bool {
        guard let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: now) else { return false }
        return Calendar.current.isDate(date, inSameDayAs: tomorrow)
    }

    /// Quando, in breve: «in corso, fino alle 16:00», «fra 12 min», «alle 15:30», «domani alle 9:00».
    static func when(_ event: AgendaEvent, now: Date) -> String {
        if event.task, event.allDay, !event.span {
            let tomorrow = isTomorrow(event.start, now: now)
            if event.evening { return tomorrow ? String(localized: "domani sera") : String(localized: "stasera") }
            return tomorrow ? String(localized: "domani") : String(localized: "in giornata")
        }
        if event.allDay { return String(localized: "Tutto il giorno") }
        if event.openEnded, event.inProgress(at: now) { return String(localized: "adesso") }
        if event.inProgress(at: now) { return String(localized: "in corso, fino alle \(time(event.end))") }
        let minutes = Int((event.start.timeIntervalSince(now) / 60).rounded(.up))
        if minutes < 60 { return minutes <= 0 ? String(localized: "adesso") : String(localized: "fra \(minutes) min") }
        if Calendar.current.isDate(event.start, inSameDayAs: now) { return String(localized: "alle \(time(event.start))") }
        if isTomorrow(event.start, now: now) { return String(localized: "domani alle \(time(event.start))") }
        return event.start.formatted(.dateTime.weekday(.abbreviated).hour().minute())
    }

    /// Da che ora a che ora, a parole (niente trattini).
    static func range(_ event: AgendaEvent) -> String {
        if event.task, event.allDay, !event.span { return event.evening ? String(localized: "Stasera") : String(localized: "In giornata") }
        if event.openEnded { return String(localized: "alle \(time(event.start))") }
        return event.allDay ? String(localized: "Tutto il giorno") : String(localized: "dalle \(time(event.start)) alle \(time(event.end))")
    }

    /// I minuti che mancano all'inizio (o alla fine, se è in corso) quando sono meno di un'ora; se no niente.
    static func minutesLeft(_ event: AgendaEvent, now: Date) -> Int? {
        if event.openEnded, event.inProgress(at: now) { return nil }
        let target = event.inProgress(at: now) ? event.end : event.start
        let minutes = Int((target.timeIntervalSince(now) / 60).rounded(.up))
        return minutes >= 0 && minutes < 60 ? minutes : nil
    }
}

@MainActor
final class AgendaModule: DockModule {
    let id = DockModuleID.agenda
    private let store = AgendaStore.shared

    var isEmpty: Bool { false }
    var needsClock: Bool { true }
    var defaultFocus: String? { "next" }

    static let maxText: CGFloat = 132

    func cells(height: CGFloat, now: Date) -> [DockCell] {
        let lines = Self.lines(now: now)
        let width = max(DockText.width(lines.title, size: 13, weight: .semibold, rounded: false),
                        lines.subtitle.map { DockText.width($0, size: 11, weight: .medium, rounded: false) } ?? 0)
        return [DockCell(id: "next", label: min(Self.maxText, width), open: 1)]
    }

    /// Le due righe accanto all'anello.
    static func lines(now: Date) -> (title: String, subtitle: String?) {
        let store = AgendaStore.shared
        if store.hasSource {
            guard let next = store.next(at: now) else { return (String(localized: "Niente in agenda"), nil) }
            return (next.title, AgendaText.when(next, now: now))
        }
        switch store.access {
        case .denied: return (String(localized: "Calendario"), String(localized: "Accesso negato"))
        case .granted: return (String(localized: "Prossimo impegno"), String(localized: "Niente di collegato"))
        case .unknown: return (String(localized: "Calendario"), String(localized: "Tocca per collegarlo"))
        }
    }

    func drawerHeight(focus: String?, now: Date) -> CGFloat { AgendaDrawer.height(now: now) }

    func setActive(_ on: Bool) {
        if on { store.start() } else { store.stop() }
    }

    func refresh(look: Bool) { store.refresh(look: look) }

    func tap(_ cell: String?) {
        if store.hasSource {
            let now = Date()
            let next = store.next(at: now)
            // Una riunione che sta per cominciare (o è cominciata): il clic ti porta dentro.
            if let next, let link = next.meeting, next.start.timeIntervalSince(now) < 10 * 60 {
                DockLaunch.open(link)
            } else if next?.task == true || (next == nil && !store.usingCalendar) {
                Self.openCharcal()
            } else {
                Self.openCalendar()
            }
        } else {
            switch store.access {
            case .denied: Self.openPrivacy()
            case .unknown: store.requestAccess()
            // Calendario scollegato e Charcal no: si sceglie in Impostazioni › Calendario.
            case .granted: AppServices.shared.showSettings(section: .calendar)
            }
        }
        DockBar.shared.closeDrawers()
    }

    static func openCalendar() {
        DockLaunch.open(bundle: "com.apple.iCal")
    }

    /// L'app Charcal se c'è sul Mac, se no la sua pagina.
    static func openCharcal() {
        DockLaunch.open(bundle: CharcalAgenda.appBundle, fallback: CharcalAgenda.base)
    }

    static func openPrivacy() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars") { DockLaunch.open(url) }
    }
}

// MARK: - Vassoio

struct AgendaPlatter: View {
    let layout: DockRowLayout
    let hovered: String?
    let now: Date
    private let store = AgendaStore.shared

    var body: some View {
        let next = store.hasSource ? store.next(at: now) : nil
        let lines = AgendaModule.lines(now: now)
        let minutes = next.flatMap { AgendaText.minutesLeft($0, now: now) }
        let urgent = next.map { !$0.inProgress(at: now) && (minutes ?? 99) <= 5 } ?? false
        ZStack(alignment: .topLeading) {
            DockRing(fraction: fraction(next), color: urgent ? UsageTone.amberInk : (next?.color ?? .white), size: layout.ring,
                     hovered: hovered == "next") {
                if let minutes {
                    Text(verbatim: "\(minutes)")
                        .font(.system(size: (layout.ring * 0.38).rounded(), weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .contentTransition(.numericText(countsDown: true))
                        .animation(.snappy(duration: 0.4), value: minutes)
                } else {
                    Image(systemName: next?.task == true ? "checkmark.circle" : "calendar")
                        .font(.system(size: (layout.ring * 0.36).rounded(), weight: .semibold))
                        .foregroundStyle(.white.opacity(store.hasSource ? 0.92 : 0.6))
                }
            }
            .offset(x: layout.x(of: "next"), y: layout.pad)
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: lines.title)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
                if let subtitle = lines.subtitle {
                    Text(verbatim: subtitle)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(urgent ? UsageTone.amberInk : .white.opacity(0.6))
                        .lineLimit(1)
                        .contentTransition(.numericText(countsDown: true))
                        .animation(.snappy(duration: 0.4), value: subtitle)
                }
            }
            .frame(width: AgendaModule.maxText, height: layout.height, alignment: .leading)
            .frame(width: layout.cells.first?.label ?? 0, alignment: .leading)
            .clipped()
            .offset(x: layout.x(of: "next") + layout.ring + DockRowLayout.labelGap)
        }
        .accessibilityElement(children: .combine)
    }

    /// L'anello: per un evento in corso quanto ne è passato; nell'ultima ora prima di uno nuovo si riempie man mano
    /// che si avvicina; se no resta vuoto.
    private func fraction(_ next: AgendaEvent?) -> Double? {
        guard let next else { return nil }
        if next.inProgress(at: now) {
            return now.timeIntervalSince(next.start) / max(60, next.end.timeIntervalSince(next.start))
        }
        let left = next.start.timeIntervalSince(now)
        return left < 3600 ? 1 - left / 3600 : nil
    }
}

// MARK: - Cassetto

struct AgendaDrawer: View {
    let now: Date
    private let store = AgendaStore.shared

    static let featured: CGFloat = 56
    static let row: CGFloat = 36
    static let separator: CGFloat = 26
    static let message: CGFloat = 40
    static let maxRows = 4

    /// Più alto di così il cassetto uscirebbe dalla sua finestra (il posto sopra il vassoio).
    static let maxHeight: CGFloat = 380

    /// Il prossimo, poi gli altri (al massimo quattro, e quanti ne stanno), con una riga col nome del giorno dove il
    /// giorno cambia. Restituisce anche l'altezza: misura e disegno usano lo stesso piano.
    @MainActor static func plan(now: Date) -> (next: AgendaEvent?, rest: [AgendaEvent], height: CGFloat) {
        let m = DockDrawerMetrics.self
        let store = AgendaStore.shared
        var h = m.pad * 2 + m.header + m.gap + m.gap + m.footer
        guard store.hasSource else { return (nil, [], h + message) }
        let next = store.next(at: now)
        if let next {
            h += featured
            if next.meeting != nil { h += 10 + m.footer }
        }
        var rest: [AgendaEvent] = []
        var day = next.map { AgendaText.day(of: $0.start, now: now) } ?? Calendar.current.startOfDay(for: now)
        for event in store.events where event.id != next?.id && event.end > now {
            guard rest.count < maxRows else { break }
            let eventDay = AgendaText.day(of: event.start, now: now)
            let extra = row + (eventDay != day ? separator : 0) + (rest.isEmpty && next != nil ? 6 : 0)
            guard h + extra <= maxHeight else { break }
            h += extra
            day = eventDay
            rest.append(event)
        }
        if next == nil, rest.isEmpty { h += message }
        return (next, rest, h)
    }

    @MainActor static func height(now: Date) -> CGFloat { plan(now: now).height }

    var body: some View {
        let m = DockDrawerMetrics.self
        VStack(alignment: .leading, spacing: 0) {
            DrawerHeader(title: now.formatted(.dateTime.weekday(.wide).day().month(.wide))) {
                Image(systemName: "calendar").font(.system(size: 14, weight: .semibold)).frame(width: 18)
            }
            .padding(.bottom, m.gap)
            if store.hasSource {
                list
                footer.padding(.top, m.gap)
            } else {
                switch store.access {
                case .granted:
                    message(String(localized: "Calendario scollegato e Charcal non collegato: scegli nelle impostazioni del Dock."))
                case .denied:
                    message(String(localized: "Charland non ha il permesso di leggere il Calendario."))
                case .unknown:
                    message(String(localized: "Collega il Calendario per vedere qui il prossimo impegno. Charland lo legge e basta."))
                }
                DrawerButton(title: store.access == .denied ? String(localized: "Apri Impostazioni di Sistema")
                             : store.access == .granted ? String(localized: "Impostazioni del Dock")
                             : String(localized: "Collega il Calendario"), prominent: store.access != .denied) {
                    AgendaModule().tap(nil)
                }
                .padding(.top, m.gap)
            }
        }
    }

    /// Con il Calendario collegato lo apre; con solo Charcal propone di collegare anche il Calendario (o apre Charcal,
    /// se il permesso è stato negato).
    @ViewBuilder private var footer: some View {
        if store.usingCalendar {
            DrawerButton(title: String(localized: "Apri Calendario")) {
                AgendaModule.openCalendar()
                DockBar.shared.closeDrawers()
            }
        } else if store.access == .unknown {
            DrawerButton(title: String(localized: "Collega il Calendario")) {
                DockSettings.shared.agendaCalendarOn = true
                store.requestAccess()
            }
        } else {
            // Solo Charcal: il Calendario negato o scollegato apposta.
            DrawerButton(title: String(localized: "Apri Charcal")) {
                AgendaModule.openCharcal()
                DockBar.shared.closeDrawers()
            }
        }
    }

    /// Il segno a sinistra: una barretta col colore del calendario per gli eventi, un cerchietto (da spuntare in Charcal)
    /// per le cose da fare. Sempre nello stesso spazio, così i titoli restano in colonna.
    private func marker(_ event: AgendaEvent, featured: Bool) -> some View {
        ZStack {
            if event.task {
                Circle().strokeBorder(Glassy.flat(event.color), lineWidth: featured ? 2 : 1.6)
                    .frame(width: featured ? 12 : 10, height: featured ? 12 : 10)
            } else {
                Capsule().fill(Glassy.ink(event.color)).frame(width: featured ? 4 : 3, height: featured ? 40 : 24)
            }
        }
        .frame(width: 12)
    }

    private func message(_ text: String) -> some View {
        Text(verbatim: text)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.white.opacity(0.6))
            .lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, minHeight: Self.message, maxHeight: Self.message, alignment: .leading)
    }

    @ViewBuilder private var list: some View {
        let plan = Self.plan(now: now)
        if let next = plan.next {
            featured(next)
            if let link = next.meeting {
                DrawerButton(title: String(localized: "Partecipa"), prominent: true) {
                    DockLaunch.open(link)
                    DockBar.shared.closeDrawers()
                }
                .padding(.top, 10)
            }
        }
        if plan.next == nil, plan.rest.isEmpty {
            message(String(localized: "Niente in agenda oggi e domani."))
        }
        if !plan.rest.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                let start = plan.next.map { AgendaText.day(of: $0.start, now: now) } ?? Calendar.current.startOfDay(for: now)
                ForEach(Array(plan.rest.enumerated()), id: \.element.id) { index, event in
                    let day = AgendaText.day(of: event.start, now: now)
                    let previous = index == 0 ? start : AgendaText.day(of: plan.rest[index - 1].start, now: now)
                    if day != previous {
                        Text(verbatim: AgendaText.isTomorrow(day, now: now) ? String(localized: "Domani")
                             : Calendar.current.isDate(day, inSameDayAs: now) ? String(localized: "Oggi")
                             : day.formatted(.dateTime.weekday(.wide)))
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.5))
                            .frame(height: Self.separator, alignment: .bottomLeading)
                            .padding(.bottom, 4)
                            .frame(height: Self.separator, alignment: .bottomLeading)
                    }
                    row(event)
                }
            }
            .padding(.top, plan.next == nil ? 0 : 6)
        }
    }

    private func featured(_ event: AgendaEvent) -> some View {
        HStack(alignment: .center, spacing: 10) {
            marker(event, featured: true)
            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: event.title).font(.system(size: 15, weight: .semibold)).lineLimit(1)
                Text(verbatim: [AgendaText.range(event), event.location].compactMap { $0 }.joined(separator: " · "))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.55))
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            Text(verbatim: AgendaText.when(event, now: now))
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.85))
                .padding(.horizontal, 8)
                .frame(height: 20)
                .background(Capsule().fill(.white.opacity(0.1)))
                .lineLimit(1)
                .fixedSize()
                .contentTransition(.numericText(countsDown: true))
                .animation(.snappy(duration: 0.4), value: AgendaText.when(event, now: now))
        }
        .frame(height: Self.featured)
    }

    private func row(_ event: AgendaEvent) -> some View {
        HStack(alignment: .center, spacing: 10) {
            marker(event, featured: false)
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: event.title).font(.system(size: 13, weight: .medium)).lineLimit(1)
                Text(verbatim: [AgendaText.range(event), event.location].compactMap { $0 }.joined(separator: " · "))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.5))
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .frame(height: Self.row)
    }
}
