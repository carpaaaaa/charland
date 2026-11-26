import AppKit

/// La tenda dello sfondo: una finestra per schermo, al livello della scrivania (sopra le finestre dello sfondo di
/// WindowManager, sotto le icone della scrivania e il fondo del tutto schermo), che mostra il disegno mentre
/// WallpaperAgent riparte. Senza, ogni ripartenza lascia lo schermo grigio scuro per circa 0,3 s (misurato il 20
/// novembre 2026 fotografando la finestra dello sfondo a raffica). Poi sfuma: se sotto c'è lo stesso disegno non si
/// vede niente, se c'è lo sfondo di prima (spegnendo) è una dissolvenza.
@MainActor
final class WallpaperCurtain {
    private var windows: [NSWindow] = []

    /// Le immagini si decodificano fuori dal thread principale (un TIFF da 22 MB per schermo) e la tenda nasce già
    /// disegnata: deve essere a schermo prima che WallpaperAgent riparta.
    static func make(showing files: [String: URL]) async -> WallpaperCurtain {
        let screens = NSScreen.screens.map { (frame: $0.frame, url: files[WallpaperFiles.displayID($0)] ?? files.values.first) }
        let urls = Array(Set(screens.compactMap(\.url)))
        let decoded = await Task.detached(priority: .userInitiated) { () -> [URL: Decoded] in
            var out: [URL: Decoded] = [:]
            for url in urls {
                guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                      let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary) else { continue }
                out[url] = Decoded(image: image)
            }
            return out
        }.value
        let curtain = WallpaperCurtain()
        for screen in screens {
            guard let url = screen.url, let image = decoded[url]?.image else { continue }
            curtain.add(image, frame: screen.frame)
        }
        return curtain
    }

    private struct Decoded: @unchecked Sendable { let image: CGImage }

    private func add(_ image: CGImage, frame: NSRect) {
        windows.append(Self.desktopWindow(image, frame: frame))
    }

    /// Una finestra al livello della scrivania che mostra `image` a tutto schermo (la usa anche lo sfondo dal vivo).
    static func desktopWindow(_ image: CGImage, frame: NSRect) -> NSWindow {
        let window = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        // −2147483623: subito sopra le finestre «Wallpaper» (−2147483624), sotto «Fullscreen Backdrop» (−2147483622)
        // e le icone della scrivania (−2147483603).
        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)))
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenNone]
        // Trasparente sotto l'immagine: se la finestra arriva a schermo un fotogramma prima del suo strato, si vede lo
        // sfondo vero che c'è sotto (lo stesso disegno, o quello di un attimo prima) e non il nero (carpa, 20 novembre
        // 2026: «a volte quando modifico diventa lo schermo nero per un attimo e poi si applica lo sfondo»).
        window.isOpaque = false
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.backgroundColor = .clear
        window.isReleasedWhenClosed = false
        window.animationBehavior = .none
        // Vista che ospita il suo strato (prima `layer`, poi `wantsLayer`): AppKit non lo ridisegna sopra.
        let view = NSView(frame: NSRect(origin: .zero, size: frame.size))
        let layer = CALayer()
        layer.contents = image
        layer.contentsGravity = .resize
        view.layer = layer
        view.wantsLayer = true
        window.contentView = view
        window.setFrame(frame, display: false)
        return window
    }

    func show() {
        // L'immagine nello strato prima che la finestra vada a schermo.
        CATransaction.flush()
        for window in windows {
            window.alphaValue = 1
            window.orderFrontRegardless()
            window.displayIfNeeded()
        }
    }

    func fadeOut(seconds: Double) async {
        guard !windows.isEmpty else { return }
        let windows = windows
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = seconds
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                for window in windows { window.animator().alphaValue = 0 }
            }, completionHandler: { done.resume() })
        }
        for window in windows { window.orderOut(nil); window.close() }
        self.windows = []
    }
}
