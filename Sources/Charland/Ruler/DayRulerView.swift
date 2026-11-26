import SwiftUI
import AppKit

/// Il righello sul bordo: vetro di Charland col velo scuro (nero come il notch contro il bordo, vetro pulito nel labbro
/// verso lo schermo) e dentro la giornata.
struct DayRulerView: View {
    let model: DayRulerModel
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        let outline = OutlineShape(path: model.outline)
        let rect = model.panelRect
        let e = model.expansion
        let left = model.side == .left
        let shown = RulerMetrics.contentOpacity(e)
        let settings = RulerSettings.shared
        ZStack(alignment: .topLeading) {
            // Chiuso e senza tacca la finestra non c'è nemmeno (`DayRuler.settledClosed`); mentre rientra il vetro resta
            // fino all'ultimo fotogramma.
            if model.tabVisible || e > 0.002 {
                CharlandGlassFill(shape: outline, veil: AnyShapeStyle(veil(rect)), rim: AnyShapeStyle(rim(rect)))
            }
            RulerContent(day: model.day, now: model.now, side: model.side, size: model.panel,
                         startHour: settings.startHour, endHour: settings.endHour)
                .equatable()
                .frame(width: model.panel.width, height: model.panel.height, alignment: .topLeading)
                // Mai a zero del tutto: una vista che compare a metà movimento costa un fotogramma proprio lì.
                .opacity(max(0.001, shown))
                .scaleEffect(0.96 + 0.04 * shown, anchor: left ? .leading : .trailing)
                .offset(x: left ? rect.minX : rect.maxX - model.panel.width, y: rect.midY - model.panel.height / 2)
                .allowsHitTesting(e > 0.9)
        }
        .frame(width: model.window.width, height: model.window.height, alignment: .topLeading)
        .shadow(color: .black.opacity(CharlandGlass.shadowOpacity * e), radius: CharlandGlass.shadowRadius,
                y: CharlandGlass.shadowY)
        .environment(\.colorScheme, .dark)
    }

    private func unit(_ x: CGFloat) -> UnitPoint {
        UnitPoint(x: x / max(1, model.window.width), y: 0.5)
    }

    /// Il velo dal bordo verso lo schermo, con la curva dell'isola girata di lato: nero pieno contro il bordo (come la
    /// fascia del notch), poi una sfumatura lunga che dove finiscono gli impegni è circa metà nero (il bianco si legge
    /// anche sopra una pagina bianca) e nel labbro arriva al vetro pulito che carpa ha tarato per l'isola. Chiudendosi
    /// torna nero pieno, così gli ultimi fotogrammi combaciano con la tacca.
    private func veil(_ rect: CGRect) -> LinearGradient {
        let left = model.side == .left
        let from = unit(left ? rect.minX : rect.maxX), to = unit(left ? rect.maxX : rect.minX)
        let w = max(1, Double(rect.width))
        let band = 14.0
        let textEnd = w - Double(RulerMetrics.lip) - 14
        let amount = model.expansion * release
        guard amount > 0.001, w > band + 24 else {
            return LinearGradient(colors: [.black, .black], startPoint: from, endPoint: to)
        }
        let start = band / w
        let knee = min(0.9, max(0.1, (textEnd - band) / (w - band)))
        let curve = VeilCurve(knee: knee, kneeValue: IslandBackdrop.legibleShare)
        var stops: [Gradient.Stop] = [.init(color: .black, location: 0), .init(color: .black, location: start)]
        stops.reserveCapacity(36)
        let perSegment = 16
        for i in 1...(perSegment * 2) {
            let t = i <= perSegment ? knee * Double(i) / Double(perSegment)
                : knee + (1 - knee) * Double(i - perSegment) / Double(perSegment)
            stops.append(.init(color: .black.opacity(1 - amount * curve.value(t)), location: start + (1 - start) * t))
        }
        return LinearGradient(stops: stops, startPoint: from, endPoint: to)
    }

    /// Quanto nero si toglie nel labbro: la regolazione «Vetro» dell'isola, più scuro con Contrasto aumentato.
    private var release: Double {
        let glass = Appearance.shared.look == .black ? 0 : Appearance.shared.glass
        return contrast == .increased ? min(glass, 0.45) : glass
    }

    /// Il filo di luce: niente contro il bordo (è nero, come il notch), più chiaro dove si vede il vetro.
    private func rim(_ rect: CGRect) -> LinearGradient {
        let left = model.side == .left
        let k = model.expansion * Appearance.shared.rim
        return LinearGradient(stops: [
            .init(color: .white.opacity(0), location: 0),
            .init(color: .white.opacity(0), location: 0.4),
            .init(color: .white.opacity(0.12 * k), location: 0.7),
            .init(color: .white.opacity(0.30 * k), location: 0.9),
            .init(color: .white.opacity(0.45 * k), location: 1),
        ], startPoint: unit(left ? rect.minX : rect.maxX), endPoint: unit(left ? rect.maxX : rect.minX))
    }
}

// MARK: - Contenuto

/// La giornata: intestazione, la fila di tutto il giorno, il righello con le ore e gli impegni, i pulsanti.
/// Non cambia mentre la forma si muove: con `equatable()` SwiftUI non la ridisegna a ogni fotogramma.
struct RulerContent: View, Equatable {
    let day: RulerDay
    let now: Date
    let side: RulerSide
    let size: CGSize
    let startHour: Int
    let endHour: Int

    static let header: CGFloat = 42
    static let chips: CGFloat = 24
    static let footer: CGFloat = 30
    static let gap: CGFloat = 12

    var body: some View {
        let pad = RulerMetrics.pad
        let showChips = day.source == .ready && !day.allDay.isEmpty
        let timelineHeight = size.height - pad * 2 - Self.header - (showChips ? Self.chips + 10 : 0) - Self.gap * 2 - Self.footer
        VStack(alignment: .leading, spacing: 0) {
            header
                .frame(height: Self.header, alignment: .topLeading)
            if showChips {
                RulerChips(events: day.allDay)
                    .frame(height: Self.chips)
                    .padding(.top, 10)
            }
            RulerTimeline(day: day, now: now, side: side, startHour: startHour, endHour: endHour)
                .frame(width: size.width - pad * 2, height: max(80, timelineHeight))
                .padding(.top, Self.gap)
            footer
                .frame(height: Self.footer)
                .padding(.top, Self.gap)
        }
        .padding(pad)
        .foregroundStyle(.white)
        .frame(width: size.width, height: size.height, alignment: .topLeading)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: Self.weekday(day.day))
                    .font(.system(size: 17, weight: .semibold))
                Text(verbatim: day.day.formatted(.dateTime.day().month(.wide)))
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(.white.opacity(0.55))
            }
            Spacer(minLength: 8)
            if day.source == .ready {
                Text(verbatim: count)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.55))
                    .lineLimit(1)
            }
        }
    }

    /// «Lunedì», con la maiuscola anche in italiano.
    static func weekday(_ date: Date) -> String {
        let name = date.formatted(.dateTime.weekday(.wide))
        return name.prefix(1).uppercased() + name.dropFirst()
    }

    /// Quante cose ci sono oggi (le fatte non contano).
    private var count: String {
        let n = (day.timed + day.allDay).filter { !$0.done }.count
        return n == 1 ? String(localized: "1 impegno") : String(localized: "\(n) impegni")
    }

    @ViewBuilder private var footer: some View {
        HStack(spacing: 6) {
            switch day.source {
            case .ready:
                if day.calendarOn {
                    RulerButton(title: String(localized: "Calendario")) {
                        AgendaModule.openCalendar()
                        DayRuler.shared.closeAfterAction()
                    }
                }
                if day.charcalOn {
                    RulerButton(title: "Charcal") {
                        AgendaModule.openCharcal()
                        DayRuler.shared.closeAfterAction()
                    }
                }
            case .calendarUnknown:
                RulerButton(title: String(localized: "Collega il Calendario"), prominent: true) {
                    DockSettings.shared.agendaCalendarOn = true
                    AgendaStore.shared.requestAccess()
                }
            case .calendarDenied:
                RulerButton(title: String(localized: "Apri Impostazioni di Sistema"), prominent: true) {
                    AgendaModule.openPrivacy()
                    DayRuler.shared.closeAfterAction()
                }
            case .none:
                RulerButton(title: String(localized: "Impostazioni"), prominent: true) {
                    let settings = RulerSettings.shared
                    AppServices.shared.showSettings(section: settings.calendarEvents || settings.charcalTasks ? .calendar : .ruler)
                    DayRuler.shared.closeAfterAction()
                }
            }
        }
    }
}

/// Un pulsante in fondo al righello, concentrico con gli angoli del pannello (26 meno i 16 di margine).
struct RulerButton: View {
    let title: String
    var prominent = false
    let action: () -> Void

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: RulerMetrics.openCorner - RulerMetrics.pad, style: .continuous)
        Button(action: action) {
            Text(verbatim: title)
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)
                .foregroundStyle(prominent ? Color.black : .white)
                .frame(maxWidth: .infinity, minHeight: RulerContent.footer, maxHeight: RulerContent.footer)
                .background(shape.fill(prominent ? Color.white : Color.white.opacity(0.1)))
                .contentShape(shape)
        }
        .buttonStyle(TilePress())
    }
}

/// Gli eventi di tutto il giorno e le cose senza ora, in una fila: quante ne stanno intere, poi «+N».
struct RulerChips: View {
    let events: [AgendaEvent]

    var body: some View {
        ViewThatFits(in: .horizontal) {
            row(3)
            row(2)
            row(1)
        }
    }

    private func row(_ shown: Int) -> some View {
        HStack(spacing: 5) {
            ForEach(events.prefix(shown), id: \.id) { chip($0) }
            if events.count > shown {
                Text(verbatim: "+\(events.count - min(shown, events.count))")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.6))
                    .fixedSize()
            }
            Spacer(minLength: 0)
        }
    }

    private func chip(_ event: AgendaEvent) -> some View {
        Button { RulerActions.open(event) } label: {
            HStack(spacing: 5) {
                RulerMarker(event: event, length: 10)
                Text(verbatim: event.title)
                    .font(.system(size: 11, weight: .medium))
                    .strikethrough(event.done)
                    .lineLimit(1)
                    .frame(maxWidth: 118, alignment: .leading)
                    .fixedSize()
            }
            .padding(.horizontal, 8)
            .frame(height: RulerContent.chips)
            .background(Capsule().fill(.white.opacity(0.09)))
            .opacity(event.done ? 0.5 : 1)
            .contentShape(Capsule())
        }
        .buttonStyle(TilePress())
    }
}

/// Il segno di un impegno: una barretta col colore del calendario per gli eventi, un cerchietto per le cose da fare
/// (pieno con la spunta se è fatta). Come nel cassetto del prossimo impegno.
struct RulerMarker: View {
    let event: AgendaEvent
    let length: CGFloat

    var body: some View {
        Group {
            if event.task {
                if event.done {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Glassy.ink(event.color))
                } else {
                    Circle().strokeBorder(Glassy.flat(event.color), lineWidth: 1.5)
                        .frame(width: 9, height: 9)
                }
            } else if event.allDay {
                Circle().fill(Glassy.ink(event.color)).frame(width: 7, height: 7)
            } else {
                Capsule().fill(Glassy.ink(event.color)).frame(width: 3, height: length)
            }
        }
        .frame(width: 10)
    }
}

enum RulerActions {
    /// Un clic su un impegno: la riunione se comincia entro dieci minuti (o è in corso), Charcal per le cose da fare,
    /// il Calendario per gli eventi.
    @MainActor static func open(_ event: AgendaEvent) {
        let now = Date()
        if let link = event.meeting, event.end > now, event.start.timeIntervalSince(now) < 10 * 60 {
            DockLaunch.open(link)
        } else if event.task {
            AgendaModule.openCharcal()
        } else {
            AgendaModule.openCalendar()
        }
        DayRuler.shared.closeAfterAction()
    }
}

// MARK: - Il righello

/// Le ore di oggi in verticale, con le tacche ogni quarto d'ora come su un righello, gli impegni al loro posto e la linea
/// di adesso. Le ore già passate sono più tenui. Dal lato del bordo le ore, dall'altro gli impegni.
struct RulerTimeline: View {
    let day: RulerDay
    let now: Date
    let side: RulerSide
    let startHour: Int
    let endHour: Int

    nonisolated static let labelWidth: CGFloat = 32
    nonisolated static let axisGap: CGFloat = 6
    nonisolated static let longTick: CGFloat = 9
    nonisolated static let eventsGap: CGFloat = 8
    /// Sopra e sotto, perché l'ora in cima e quella in fondo non vengano tagliate a metà.
    nonisolated static let inset: CGFloat = 7
    nonisolated static let minBlock: CGFloat = 20
    static let nowRed = Color(red: 1, green: 0.27, blue: 0.23)

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            let layout = Layout(day: day, now: now, side: side, size: size, startHour: startHour, endHour: endHour)
            ZStack(alignment: .topLeading) {
                ticks(layout)
                labels(layout)
                // La linea sta dietro agli impegni (si vede attraverso il loro fondo, i titoli restano leggibili); pallino
                // ed etichetta davanti a tutto.
                if let nowY = layout.nowY { nowStroke(layout, y: nowY) }
                ForEach(layout.blocks) { block in
                    RulerBlock(event: block.event, height: block.height, width: block.width, now: now)
                        .offset(x: block.x, y: block.y)
                }
                if day.source != .ready || day.timed.isEmpty {
                    // Nella metà lontana dalla linea di adesso: sopra la linea rossa il testo non si leggerebbe.
                    let middle = layout.nowY.map { $0 < size.height / 2 ? size.height * 0.68 : size.height * 0.32 } ?? size.height / 2
                    message
                        .frame(width: layout.eventsMaxX - layout.eventsMinX)
                        .position(x: (layout.eventsMinX + layout.eventsMaxX) / 2, y: middle)
                        .allowsHitTesting(false)
                }
                if let nowY = layout.nowY { nowMarker(layout, y: nowY) }
            }
            .frame(width: size.width, height: size.height, alignment: .topLeading)
        }
    }

    // MARK: Disegno

    private func ticks(_ layout: Layout) -> some View {
        Canvas { context, _ in
            let axisX = layout.axisX
            let direction: CGFloat = layout.left ? 1 : -1
            var axis = Path()
            axis.move(to: CGPoint(x: axisX, y: layout.y(of: layout.low)))
            axis.addLine(to: CGPoint(x: axisX, y: layout.y(of: layout.high)))
            context.stroke(axis, with: .color(.white.opacity(0.14)), lineWidth: 1)
            // La parte già passata del giorno, più piena: si vede a colpo d'occhio quanto ne resta.
            if let nowY = layout.nowY, nowY > layout.y(of: layout.low) {
                var done = Path()
                done.move(to: CGPoint(x: axisX, y: layout.y(of: layout.low)))
                done.addLine(to: CGPoint(x: axisX, y: nowY))
                context.stroke(done, with: .color(.white.opacity(0.32)), lineWidth: 1.5)
            }
            let step = layout.perHour >= 34 ? 0.25 : layout.perHour >= 16 ? 0.5 : 1
            var t = layout.low
            while t <= layout.high + 0.0001 {
                let y = layout.y(of: t)
                let hour = abs(t - t.rounded()) < 0.001
                let half = !hour && abs(t * 2 - (t * 2).rounded()) < 0.001
                let length: CGFloat = hour ? Self.longTick : half ? 5.5 : 3
                let past = layout.nowHours.map { t < $0 } ?? false
                let alpha = (hour ? 0.55 : half ? 0.32 : 0.2) * (past ? 0.5 : 1)
                var tick = Path()
                tick.move(to: CGPoint(x: axisX, y: y))
                tick.addLine(to: CGPoint(x: axisX + direction * length, y: y))
                context.stroke(tick, with: .color(.white.opacity(alpha)), lineWidth: hour ? 1.2 : 1)
                t += step
            }
        }
        .allowsHitTesting(false)
    }

    private func labels(_ layout: Layout) -> some View {
        let every = layout.perHour >= 15 ? 1 : 2
        let hours = Array(Int(layout.low.rounded(.up))...Int(layout.high.rounded(.down))).filter { $0 % every == 0 }
        return ForEach(hours, id: \.self) { hour in
            let y = layout.y(of: Double(hour))
            // Vicino all'ora di adesso l'etichetta lascia il posto a quella rossa.
            let hidden = layout.nowY.map { abs($0 - y) < 11 } ?? false
            let past = layout.nowHours.map { Double(hour) < $0 } ?? false
            Text(verbatim: Self.hourLabel(hour))
                .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.white.opacity(past ? 0.32 : 0.6))
                .lineLimit(1)
                .frame(width: Self.labelWidth, alignment: layout.left ? .trailing : .leading)
                .position(x: layout.labelCenterX, y: y)
                .opacity(hidden ? 0 : 1)
        }
        .allowsHitTesting(false)
    }

    private func nowStroke(_ layout: Layout, y: CGFloat) -> some View {
        let lineEnd = layout.left ? layout.eventsMaxX : layout.eventsMinX
        return Path { path in
            path.move(to: CGPoint(x: layout.axisX, y: y))
            path.addLine(to: CGPoint(x: lineEnd, y: y))
        }
        .stroke(Glassy.flat(Self.nowRed), lineWidth: 1.2)
        .allowsHitTesting(false)
    }

    private func nowMarker(_ layout: Layout, y: CGFloat) -> some View {
        let red = Glassy.flat(Self.nowRed)
        return ZStack(alignment: .topLeading) {
            Circle().fill(red)
                .frame(width: 7, height: 7)
                .position(x: layout.axisX, y: y)
            Text(verbatim: AgendaText.time(now))
                .font(.system(size: 10.5, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(Glassy.on ? Color.black : .white)
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, 5)
                .frame(height: 16)
                .background(Capsule().fill(red))
                .frame(width: Self.labelWidth + 4, alignment: layout.left ? .trailing : .leading)
                .position(x: layout.labelCenterX, y: y)
        }
        .allowsHitTesting(false)
    }

    @ViewBuilder private var message: some View {
        let text: String = switch day.source {
        case .ready: day.allDay.isEmpty ? String(localized: "Giornata libera") : String(localized: "Niente con un orario, oggi")
        case .calendarUnknown: String(localized: "Collega il Calendario per vedere qui la tua giornata. Charland lo legge e basta.")
        case .calendarDenied: String(localized: "Charland non ha il permesso di leggere il Calendario.")
        case .none: String(localized: "Niente di collegato: scegli il Calendario o Charcal nelle impostazioni.")
        }
        Text(verbatim: text)
            .font(.system(size: 12.5, weight: .medium))
            .foregroundStyle(.white.opacity(0.55))
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 12)
    }

    /// «07» con le 24 ore, «7 AM» con le 12 (come chiede la lingua del Mac); la mezzanotte in fondo è «00».
    static func hourLabel(_ hour: Int) -> String {
        let h = hour % 24
        if uses24Hours { return String(format: "%02d", h) }
        let twelve = h % 12 == 0 ? 12 : h % 12
        return "\(twelve) \(h < 12 ? Calendar.current.amSymbol : Calendar.current.pmSymbol)"
    }

    static let uses24Hours: Bool = {
        let format = DateFormatter.dateFormat(fromTemplate: "j", options: 0, locale: .current) ?? "H"
        return !format.contains("a")
    }()

    // MARK: Misure

    /// Dove sta tutto: le ore mostrate, i punti per ora, le colonne degli impegni che si accavallano.
    struct Layout {
        let left: Bool
        let low: Double
        let high: Double
        let perHour: CGFloat
        let axisX: CGFloat
        let labelCenterX: CGFloat
        let eventsMinX: CGFloat
        let eventsMaxX: CGFloat
        let nowHours: Double?
        let nowY: CGFloat?
        var blocks: [Block] = []

        struct Block: Identifiable {
            let event: AgendaEvent
            let x: CGFloat
            let y: CGFloat
            let width: CGFloat
            let height: CGFloat
            var id: String { event.id }
        }

        func y(of hours: Double) -> CGFloat { RulerTimeline.inset + CGFloat(hours - low) * perHour }

        init(day: RulerDay, now: Date, side: RulerSide, size: CGSize, startHour: Int, endHour: Int) {
            left = side == .left
            let calendar = Calendar.current
            func hours(_ date: Date) -> Double {
                if date <= day.day { return 0 }
                guard calendar.isDate(date, inSameDayAs: day.day) else { return 24 }
                let c = calendar.dateComponents([.hour, .minute, .second], from: date)
                return Double(c.hour ?? 0) + Double(c.minute ?? 0) / 60 + Double(c.second ?? 0) / 3600
            }
            // Le ore scelte, allargate per gli impegni che escono e per l'ora di adesso.
            var low = Double(min(startHour, endHour - 1)), high = Double(endHour)
            for event in day.timed {
                low = min(low, hours(event.start).rounded(.down))
                high = max(high, hours(event.end).rounded(.up))
            }
            let today = calendar.isDate(now, inSameDayAs: day.day)
            let nowHours = today ? hours(now) : nil
            if let nowHours {
                low = min(low, nowHours.rounded(.down))
                high = max(high, min(24, (nowHours + 1 / 60).rounded(.up)))
            }
            low = max(0, low)
            high = min(24, max(high, low + 3))
            self.low = low
            self.high = high
            self.nowHours = nowHours
            let perHour = max(1, (size.height - RulerTimeline.inset * 2) / CGFloat(high - low))
            self.perHour = perHour

            let labelWidth = RulerTimeline.labelWidth
            let minX: CGFloat, maxX: CGFloat
            if left {
                labelCenterX = labelWidth / 2
                let axis = labelWidth + RulerTimeline.axisGap
                axisX = axis
                minX = axis + RulerTimeline.longTick + RulerTimeline.eventsGap
                maxX = size.width
            } else {
                labelCenterX = size.width - labelWidth / 2
                let axis = size.width - labelWidth - RulerTimeline.axisGap
                axisX = axis
                minX = 0
                maxX = axis - RulerTimeline.longTick - RulerTimeline.eventsGap
            }
            eventsMinX = minX
            eventsMaxX = maxX
            let lowValue = low
            nowY = nowHours.map { RulerTimeline.inset + CGFloat($0 - lowValue) * perHour }

            // Colonne: gli impegni che si accavallano si dividono la larghezza, come nel Calendario.
            struct Placed { let event: AgendaEvent; let top: CGFloat; let bottom: CGFloat; let column: Int }
            var cluster: [Placed] = []
            var columnsEnd: [CGFloat] = []
            var clusterEnd = -CGFloat.infinity
            var out: [Block] = []
            let width = maxX - minX
            func flush() {
                let columns = max(1, columnsEnd.count)
                let columnWidth = width / CGFloat(columns)
                for item in cluster {
                    out.append(Block(event: item.event, x: minX + CGFloat(item.column) * columnWidth, y: item.top,
                                     width: columnWidth - (columns > 1 ? 3 : 0), height: item.bottom - item.top))
                }
                cluster.removeAll()
                columnsEnd.removeAll()
                clusterEnd = -.infinity
            }
            func y(_ h: Double) -> CGFloat { RulerTimeline.inset + CGFloat(h - lowValue) * perHour }
            for event in day.timed {
                let top = y(hours(event.start))
                let bottom = max(top + RulerTimeline.minBlock, y(hours(event.end)))
                if !cluster.isEmpty, top >= clusterEnd - 0.5 { flush() }
                let column: Int
                if let free = columnsEnd.firstIndex(where: { $0 <= top + 0.5 }) {
                    column = free
                    columnsEnd[free] = bottom
                } else {
                    column = columnsEnd.count
                    columnsEnd.append(bottom)
                }
                cluster.append(Placed(event: event, top: top, bottom: bottom, column: column))
                clusterEnd = max(clusterEnd, bottom)
            }
            flush()
            blocks = out
        }
    }
}

/// Un impegno sul righello: il fondo nel colore del calendario, il segno, titolo e ora. Quelli finiti e le cose fatte
/// sbiadiscono; quello in corso ha il filo del suo colore.
struct RulerBlock: View {
    let event: AgendaEvent
    let height: CGFloat
    let width: CGFloat
    let now: Date

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: min(7, height / 2), style: .continuous)
        let past = event.end <= now
        let current = event.inProgress(at: now) && !event.openEnded
        let compact = height < 34
        Button { RulerActions.open(event) } label: {
            HStack(alignment: compact ? .center : .top, spacing: 6) {
                RulerMarker(event: event, length: compact ? max(8, height - 10) : max(12, min(height - 12, 40)))
                    .padding(.top, compact ? 0 : 1)
                if compact {
                    Text(verbatim: event.title)
                        .font(.system(size: 11.5, weight: .semibold))
                        .strikethrough(event.done)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    // In una colonna stretta (impegni accavallati) l'ora lascia il posto al titolo: sta già sul righello.
                    if width >= 150 {
                        Text(verbatim: AgendaText.time(event.start))
                            .font(.system(size: 10.5, weight: .medium))
                            .monospacedDigit()
                            .foregroundStyle(.white.opacity(0.6))
                            .lineLimit(1)
                            .fixedSize()
                    }
                } else {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(verbatim: event.title)
                            .font(.system(size: 12, weight: .semibold))
                            .strikethrough(event.done)
                            .lineLimit(height > 54 ? 2 : 1)
                        Text(verbatim: [AgendaText.range(event), event.location].compactMap { $0 }.joined(separator: " · "))
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundStyle(.white.opacity(0.6))
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
            }
            .padding(.horizontal, 7)
            .padding(.vertical, compact ? 0 : 6)
            .frame(width: max(0, width), height: height, alignment: compact ? .leading : .topLeading)
            .background(shape.fill(Glassy.on ? AnyShapeStyle(Color.white.opacity(0.1)) : AnyShapeStyle(event.color.opacity(0.24))))
            .overlay {
                if current { shape.strokeBorder(Glassy.ink(event.color), lineWidth: 1) }
            }
            .clipShape(shape)
            .opacity(past || event.done ? 0.5 : 1)
            .contentShape(shape)
        }
        .buttonStyle(TilePress())
        .help(Text(verbatim: [event.title, AgendaText.range(event), event.location].compactMap { $0 }.joined(separator: "\n")))
    }
}
