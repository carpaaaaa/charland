import AppKit
import ApplicationServices

/// Trova il cursore del testo nell'app in primo piano, attraverso l'Accessibilità.
/// Serve a far colare la goccia nel punto giusto. Se non lo trova restituisce `nil`
/// e la goccia scende dritta.
enum CaretLocator {
    /// Come `locate()`, ma fuori dal thread principale: la domanda all'Accessibilità aspetta
    /// l'altra app, e sul thread principale bloccherebbe l'isola mentre si muove.
    static func locateInBackground() async -> Target? {
        await Task.detached(priority: .userInitiated) { locate() }.value
    }

    struct Target: Sendable {
        /// Il punto del cursore in coordinate AppKit (origine in basso a sinistra).
        var point: CGPoint
        /// `true` se è il cursore vero, `false` se è solo l'angolo del campo.
        var exact: Bool
        /// Il campo è protetto (password): non ci si scrive.
        var secure: Bool
    }

    static func focusedElement() -> AXUIElement? {
        guard AXIsProcessTrusted() else { return nil }
        let system = AXUIElementCreateSystemWide()
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    static func locate() -> Target? {
        guard let element = focusedElement() else { return nil }
        let secure = string(element, kAXSubroleAttribute) == (kAXSecureTextFieldSubrole as String)
        let mainHeight = NSScreen.screens.first?.frame.height ?? 0

        // Il cursore vero: il rettangolo dell'intervallo selezionato.
        var rangeValue: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rangeValue) == .success,
           let rangeValue {
            var boundsValue: CFTypeRef?
            if AXUIElementCopyParameterizedAttributeValue(element, kAXBoundsForRangeParameterizedAttribute as CFString,
                                                          rangeValue, &boundsValue) == .success,
               let boundsValue, CFGetTypeID(boundsValue) == AXValueGetTypeID() {
                var rect = CGRect.zero
                if AXValueGetValue(boundsValue as! AXValue, .cgRect, &rect), rect.height > 1, rect.minX.isFinite, rect.minY.isFinite,
                   !(rect.origin == .zero) {
                    return Target(point: CGPoint(x: rect.minX, y: mainHeight - rect.midY), exact: true, secure: secure)
                }
            }
        }

        // Riserva: l'angolo in alto a sinistra del campo.
        var positionValue: CFTypeRef?
        var sizeValue: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionValue) == .success,
           AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeValue) == .success,
           let positionValue, let sizeValue,
           CFGetTypeID(positionValue) == AXValueGetTypeID(), CFGetTypeID(sizeValue) == AXValueGetTypeID() {
            var origin = CGPoint.zero
            var size = CGSize.zero
            AXValueGetValue(positionValue as! AXValue, .cgPoint, &origin)
            AXValueGetValue(sizeValue as! AXValue, .cgSize, &size)
            if size.width > 4, size.height > 4 {
                return Target(point: CGPoint(x: origin.x + 14, y: mainHeight - (origin.y + min(18, size.height / 2))),
                              exact: false, secure: secure)
            }
        }
        return nil
    }

    static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }
}
