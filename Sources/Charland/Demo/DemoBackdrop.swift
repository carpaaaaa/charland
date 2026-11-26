import AppKit

/// Un fondo di prova sotto l'isola: un'immagine a tutta larghezza in cima allo schermo,
/// sotto l'isola e sopra le finestre. Serve solo nelle scene, per guardare il vetro su colori veri.
@MainActor
enum DemoBackdrop {
    static func show(image: NSImage, on screen: CGRect) -> NSWindow {
        let height: CGFloat = 420
        let frame = CGRect(x: screen.minX, y: screen.maxY - height, width: screen.width, height: height)
        let window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 1)
        window.isOpaque = true
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.collectionBehavior = [.canJoinAllSpaces, .stationary]
        let view = NSImageView(frame: CGRect(origin: .zero, size: frame.size))
        view.image = image
        view.imageScaling = .scaleAxesIndependently
        // Riempie la larghezza mantenendo le proporzioni: si vede la parte alta dell'immagine.
        let ratio = image.size.width / max(1, image.size.height)
        let fullHeight = frame.width / ratio
        view.frame = CGRect(x: 0, y: frame.height - fullHeight, width: frame.width, height: fullHeight)
        let container = NSView(frame: CGRect(origin: .zero, size: frame.size))
        container.addSubview(view)
        window.contentView = container
        window.setFrame(frame, display: true)
        window.orderFrontRegardless()
        return window
    }
}
