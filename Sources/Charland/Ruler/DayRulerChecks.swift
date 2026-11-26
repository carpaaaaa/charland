import AppKit
import SwiftUI

/// Il righello disegnato fuori schermo (`Charland --render-righello <cartella>`): una giornata inventata, sui due lati,
/// sopra uno sfondo scuro e uno chiaro, più gli stati senza impegni e senza fonti. Il vetro di sistema fuori schermo non
/// c'è: al suo posto il velo nero com'è nell'app, così si giudica la leggibilità.
@MainActor
enum DayRulerChecks {
    static func render(folder: String) {
        let out = URL(fileURLWithPath: folder)
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let calendar = Calendar.current
        // Le 15:40 di oggi: metà giornata passata, metà da venire.
        let now = calendar.date(bySettingHour: 15, minute: 40, second: 0, of: Date()) ?? Date()
        DayRulerStore.shared.useSample(now: now)
        let sample = DayRulerStore.shared.day
        // L'altezza vera sullo schermo principale, con la scelta di serie (Alta).
        let height = NSScreen.main.map { RulerMetrics.panelHeight(on: $0, .tall) } ?? 760
        let size = CGSize(width: RulerMetrics.contentWidth, height: height)

        func board(_ day: RulerDay, side: RulerSide, backdrop: Color) -> some View {
            let left = side == .left
            let shape = UnevenRoundedRectangle(topLeadingRadius: left ? 0 : RulerMetrics.openCorner,
                                               bottomLeadingRadius: left ? 0 : RulerMetrics.openCorner,
                                               bottomTrailingRadius: left ? RulerMetrics.openCorner : 0,
                                               topTrailingRadius: left ? RulerMetrics.openCorner : 0, style: .continuous)
            return ZStack(alignment: left ? .leading : .trailing) {
                backdrop
                shape
                    .fill(LinearGradient(stops: [.init(color: .black, location: 0), .init(color: .black.opacity(0.86), location: 0.3),
                                                 .init(color: .black.opacity(0.5), location: 0.92), .init(color: .black.opacity(0.3), location: 1)],
                                         startPoint: left ? .leading : .trailing, endPoint: left ? .trailing : .leading))
                    .frame(width: RulerMetrics.shapeWidth, height: size.height)
                RulerContent(day: day, now: now, side: side, size: size, startHour: 7, endHour: 24)
                    .frame(width: RulerMetrics.shapeWidth, alignment: left ? .leading : .trailing)
            }
            .frame(width: RulerMetrics.shapeWidth + 60, height: size.height + 40)
            .environment(\.colorScheme, .dark)
        }

        for (name, backdrop) in [("scuro", Color(white: 0.14)), ("chiaro", Color(white: 0.94))] {
            write(board(sample, side: .left, backdrop: backdrop), to: out.appendingPathComponent("righello-sinistra-\(name).png"))
        }
        write(board(sample, side: .right, backdrop: Color(white: 0.14)), to: out.appendingPathComponent("righello-destra.png"))
        var free = sample
        free.timed = []
        free.allDay = []
        write(board(free, side: .left, backdrop: Color(white: 0.14)), to: out.appendingPathComponent("righello-libero.png"))
        var unlinked = sample
        unlinked.timed = []
        unlinked.allDay = []
        unlinked.source = .calendarUnknown
        write(board(unlinked, side: .left, backdrop: Color(white: 0.14)), to: out.appendingPathComponent("righello-da-collegare.png"))
        print(out.path)
    }

    private static func write(_ view: some View, to url: URL) {
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        guard let image = renderer.nsImage, let tiff = image.tiffRepresentation,
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: url)
    }
}
