import SwiftUI
import EventKit

/// La giornata che il righello mostra: gli impegni con un'ora e quelli di tutto il giorno, più da dove vengono.
struct RulerDay: Equatable {
    enum Source: Equatable {
        /// C'è almeno una fonte da leggere.
        case ready
        /// Il Calendario non ha ancora il permesso (si chiede col pulsante, mai da solo).
        case calendarUnknown
        /// Il permesso del Calendario è negato e Charcal non c'è.
        case calendarDenied
        /// Tutto scollegato o spento nelle impostazioni.
        case none
    }

    var day: Date
    var timed: [AgendaEvent]
    var allDay: [AgendaEvent]
    var source: Source
    /// Quali pulsanti mettere in fondo.
    var calendarOn: Bool
    var charcalOn: Bool

    static let empty = RulerDay(day: Calendar.current.startOfDay(for: Date()), timed: [], allDay: [], source: .none,
                                calendarOn: false, charcalOn: false)
}

/// Legge la giornata di oggi per il righello, a parte dal prossimo impegno del Dock: quello guarda solo avanti
/// (`AgendaStore` toglie gli eventi finiti), il righello mostra anche la mattina passata e le cose già fatte.
///
/// Niente timer: si legge quando il puntatore arriva sul bordo e quando il righello si apre, se è passato abbastanza.
/// Le fonti e i calendari scelti sono quelli di Impostazioni › Calendario.
@MainActor
final class DayRulerStore {
    static let shared = DayRulerStore()

    private(set) var day = RulerDay.empty

    private let reader = AgendaReader()
    private var calendarEvents: [AgendaEvent] = []
    private var charcalItems: [AgendaEvent] = []
    private var lastCalendar = Date.distantPast
    private var lastCharcal = Date.distantPast
    private var loadedDay = Date.distantPast
    private var calendarLoading = false
    private var charcalLoading = false
    private var observer: NSObjectProtocol?
    private var active = false

    private var settings: RulerSettings { .shared }

    private init() {}

    func start() {
        guard !active else { return }
        active = true
        // Un evento cambiato nel Calendario: la prossima occhiata rilegge (o subito, se il righello è aperto).
        observer = NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                let store = DayRulerStore.shared
                store.lastCalendar = .distantPast
                if DayRuler.shared.isOpen { store.refresh() }
            }
        }
        refresh()
    }

    func stop() {
        active = false
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        reader.reset()
        calendarEvents = []
        charcalItems = []
        lastCalendar = .distantPast
        lastCharcal = .distantPast
        loadedDay = .distantPast
        day = .empty
    }

    /// Una scelta cambiata nelle impostazioni: si rilegge tutto.
    func sourcesChanged() {
        lastCalendar = .distantPast
        lastCharcal = .distantPast
        guard active else { return }
        refresh()
    }

    private var calendarOn: Bool { settings.calendarEvents && AgendaStore.shared.usingCalendar }
    private var charcalOn: Bool { settings.charcalTasks && CharcalAgenda.shared.connected }

    /// Rilegge quello che è vecchio: il Calendario dopo un minuto (o se è cambiato), Charcal dopo 45 secondi.
    func refresh() {
        guard active else { return }
        AgendaStore.shared.refreshAccess()
        let now = Date()
        let today = Calendar.current.startOfDay(for: now)
        if today != loadedDay {
            // Passata la mezzanotte: la giornata di ieri non vale più.
            loadedDay = today
            calendarEvents = []
            charcalItems = []
            lastCalendar = .distantPast
            lastCharcal = .distantPast
        }
        if calendarOn, !calendarLoading, now.timeIntervalSince(lastCalendar) > 60 { loadCalendar(today) }
        if charcalOn, !charcalLoading, now.timeIntervalSince(lastCharcal) > 45 { loadCharcal(today) }
        rebuild()
    }

    private func loadCalendar(_ today: Date) {
        calendarLoading = true
        lastCalendar = Date()
        let end = Calendar.current.date(byAdding: .day, value: 1, to: today) ?? today.addingTimeInterval(86_400)
        reader.readRange(from: today, to: end, hidden: DockSettings.shared.agendaHiddenCalendars) { events in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    let store = DayRulerStore.shared
                    store.calendarLoading = false
                    guard store.active, store.loadedDay == today else { return }
                    store.calendarEvents = events
                    store.rebuild()
                }
            }
        }
    }

    private func loadCharcal(_ today: Date) {
        charcalLoading = true
        lastCharcal = Date()
        let done = settings.doneTasks
        Task {
            let items = await CharcalAgenda.shared.dayItems(today, includeDone: done)
            charcalLoading = false
            guard active, loadedDay == today else { return }
            if let items { charcalItems = items }
            rebuild()
        }
    }

    /// Unisce le due fonti come il prossimo impegno: chi ha anche il calendario di Charcal nel Calendario vedrebbe le
    /// cose due volte, e vince quella di Charcal, che sa di essere una cosa da fare.
    private func rebuild() {
        let today = loadedDay == .distantPast ? Calendar.current.startOfDay(for: Date()) : loadedDay
        let calendarOn = self.calendarOn, charcalOn = self.charcalOn
        var all: [AgendaEvent] = calendarOn ? calendarEvents : []
        if charcalOn {
            func key(_ event: AgendaEvent) -> String {
                event.title.lowercased() + "|" + String(Int(event.allDay ? Calendar.current.startOfDay(for: event.start).timeIntervalSince1970
                                                              : (event.start.timeIntervalSince1970 / 60).rounded() * 60))
            }
            let keys = Set(charcalItems.map(key))
            all = all.filter { !keys.contains(key($0)) }
            all += charcalItems.filter { settings.doneTasks || !$0.done }
        }
        let timed = all.filter { !$0.allDay }.sorted {
            if $0.start != $1.start { return $0.start < $1.start }
            return $0.end > $1.end
        }
        // In alto prima gli eventi di tutto il giorno, poi le cose senza ora; le fatte in fondo.
        func rank(_ event: AgendaEvent) -> Int { event.done ? 3 : event.task ? (event.span ? 1 : 2) : 0 }
        let allDay = settings.allDay ? all.filter(\.allDay).sorted {
            if rank($0) != rank($1) { return rank($0) < rank($1) }
            return $0.title < $1.title
        } : []
        let source: RulerDay.Source
        if calendarOn || charcalOn {
            source = .ready
        } else if settings.calendarEvents, AgendaStore.shared.access == .unknown {
            source = .calendarUnknown
        } else if settings.calendarEvents, AgendaStore.shared.access == .denied {
            source = .calendarDenied
        } else {
            source = .none
        }
        let next = RulerDay(day: today, timed: timed, allDay: allDay, source: source, calendarOn: calendarOn, charcalOn: charcalOn)
        guard next != day else { return }
        day = next
        DayRuler.shared.dataChanged()
    }

    // MARK: Prove

    /// Una giornata inventata, per i disegni fuori schermo (`Charland --render-righello`).
    func useSample(now: Date) {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        func at(_ hour: Double) -> Date { today.addingTimeInterval(hour * 3600) }
        func event(_ title: String, _ start: Double, _ end: Double, _ color: (Double, Double, Double), task: Bool = false,
                   done: Bool = false, location: String? = nil, meeting: String? = nil) -> AgendaEvent {
            var item = AgendaEvent(id: title, title: title, start: at(start), end: at(end), allDay: false,
                                   red: color.0, green: color.1, blue: color.2, location: location,
                                   meeting: meeting.flatMap(URL.init(string:)), task: task, openEnded: task && end - start <= 0.25)
            item.done = done
            return item
        }
        let red = (0.98, 0.42, 0.36), green = (0.30, 0.78, 0.46), blue = (0.36, 0.58, 1.0), violet = (0.75, 0.48, 0.95)
        let pink = CharcalAgenda.accent
        var allDayTask = AgendaEvent(id: "bread", title: "Buy bread", start: today, end: at(24), allDay: true,
                                     red: green.0, green: green.1, blue: green.2, location: "Home", meeting: nil, task: true)
        allDayTask.done = false
        loadedDay = today
        day = RulerDay(day: today, timed: [
            event("Gym", 7.5, 8.5, violet, location: "Main Street 3"),
            event("Reply to Marta", 9, 9.25, pink, task: true, done: true),
            event("Design review", 10, 11, red, meeting: "https://meet.google.com/abc-defg-hij"),
            event("Call with Sam", 10.5, 11.25, blue),
            event("Lunch", 13, 14, green, location: "Corner Café"),
            event("Send the proposal", 15.5, 15.75, pink, task: true),
            event("Focus: site copy", 16, 18, blue),
            event("Dinner with Ale", 20.5, 22.5, violet),
        ], allDay: [
            AgendaEvent(id: "birthday", title: "Giulia's birthday", start: today, end: at(24), allDay: true,
                        red: red.0, green: red.1, blue: red.2, location: nil, meeting: nil),
            allDayTask,
        ], source: .ready, calendarOn: true, charcalOn: true)
    }
}
