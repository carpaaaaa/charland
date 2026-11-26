import AppKit
import CharlandCore

/// Le misure del notch di uno schermo, lette dal sistema.
/// Gli schermi si riconoscono per numero, mai per nome: in macOS 27 il nome è cambiato.
struct ScreenGeometry: Equatable {
    var displayID: CGDirectDisplayID
    var frame: CGRect
    var metrics: IslandMetrics
    /// Centro del notch in coordinate dello schermo (x).
    var notchCenterX: CGFloat

    /// Regolazione fine dell'altezza: sul MacBook Air M5 il notch vero è circa un punto
    /// più alto di quello che dice macOS.
    static var heightTrim: CGFloat {
        CGFloat(UserDefaults.standard.object(forKey: "notchHeightTrim") as? Double ?? 0)
    }

    init(screen: NSScreen, simulateNotchless: Bool = false) {
        displayID = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
        frame = screen.frame
        let top = screen.safeAreaInsets.top
        if !simulateNotchless, top > 0,
           let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            let width = screen.frame.width - left.width - right.width
            metrics = IslandMetrics(notchWidth: Double(width), notchHeight: Double(top + Self.heightTrim),
                                    screenWidth: Double(screen.frame.width))
            notchCenterX = screen.frame.minX + left.width + width / 2
        } else {
            let bar = max(22, screen.frame.maxY - screen.visibleFrame.maxY)
            metrics = .notchless(screenWidth: Double(screen.frame.width), menuBarHeight: Double(bar))
            notchCenterX = screen.frame.midX
        }
    }

    /// La finestra fissa dell'isola: non cambia mai misura, dentro si muove la forma.
    var stageFrame: CGRect {
        let width = min(frame.width, 820)
        let height: CGFloat = 360
        return CGRect(x: notchCenterX - width / 2, y: frame.maxY - height, width: width, height: height)
    }
}
