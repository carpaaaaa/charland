import AppKit

/// Lo sfondo dal vivo mentre lo regoli (carpa, 20 novembre 2026: «voglio che si veda in real time nello sfondo la
/// modifica che stai facendo; ora ogni volta si deve ricaricare, con anche un'animazione orribile»). Ogni ritocco
/// passava da un file nuovo e dalla dissolvenza di macOS. Ora, finché muovi un cursore, il disegno va in una finestra
/// per schermo al livello della scrivania (come la tenda: sopra lo sfondo, sotto le icone) e si cambia sul posto,
/// senza animazioni. A regolazione finita il file vero va a macOS sotto questa finestra, che poi sparisce: sotto c'è
/// già la stessa immagine. I cambi interi (stile, tavolozza, immagine, accensione) passano con una dissolvenza breve.
@MainActor
final class WallpaperLiveLayer {
    static let shared = WallpaperLiveLayer()
    private var windows: [String: NSWindow] = [:]

    var isShown: Bool { !windows.isEmpty }

    /// Mette le immagini (per UUID dello schermo; manca uno schermo: quella del principale). `fade` sopra zero:
    /// dissolvenza dall'immagine di prima, o dallo sfondo vero se la finestra non c'era.
    func show(_ images: [String: CGImage], fade: Double = 0) {
        guard let fallback = images.values.first else { return }
        let screens = NSScreen.screens
        let ids = Set(screens.map(WallpaperFiles.displayID))
        for (id, window) in windows where !ids.contains(id) { window.orderOut(nil); window.close(); windows[id] = nil }
        for screen in screens {
            let id = WallpaperFiles.displayID(screen)
            let image = images[id] ?? fallback
            if let window = windows[id], let layer = window.contentView?.layer {
                CATransaction.begin()
                if fade > 0 {
                    let transition = CATransition()
                    transition.type = .fade
                    transition.duration = fade
                    transition.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                    layer.add(transition, forKey: "contents")
                } else {
                    CATransaction.setDisableActions(true)
                }
                layer.contents = image
                CATransaction.commit()
                if window.frame != screen.frame { window.setFrame(screen.frame, display: true) }
            } else {
                let window = WallpaperCurtain.desktopWindow(image, frame: screen.frame)
                windows[id] = window
                // L'immagine nello strato prima che la finestra vada a schermo (niente fotogramma vuoto).
                CATransaction.flush()
                if fade > 0 {
                    window.alphaValue = 0
                    window.orderFrontRegardless()
                    NSAnimationContext.runAnimationGroup { context in
                        context.duration = fade
                        context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                        window.animator().alphaValue = 1
                    }
                } else {
                    window.orderFrontRegardless()
                    window.displayIfNeeded()
                }
            }
        }
    }

    /// Via di colpo: va chiamato quando sotto c'è già la stessa immagine.
    func hide() {
        for window in windows.values { window.orderOut(nil); window.close() }
        windows = [:]
    }
}
