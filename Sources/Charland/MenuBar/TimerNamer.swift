import AppKit
import SwiftUI

/// Il nome del timer, dopo aver lasciato la goccia (carpa: «la possibilità di scrivere una descrizione dopo il rilascio
/// della goccia, così che anche nel notch abbia un nome quel timer»). Una capsula di vetro scende dal notch col cursore
/// già dentro: Invio salva, Esc salta, un clic altrove salva quello che c'è scritto. Se non scrivi niente risale da sola.
/// Prende la tastiera senza attivare Charland, come Spotlight: l'app in cui stavi lavorando resta davanti.
/// Si accende e si spegne in Generale (`Features.timerNames`), spento di serie.
@MainActor
final class TimerNamer {
    static let shared = TimerNamer()
    let model = TimerNamerModel()

    private var panel: TimerNamerPanel?
    private var panelSpace = 0
    private var timerID: String?
    private var idle: Timer?
    private var closing = false

    static let size = CGSize(width: 320, height: 76)
    /// Senza scrivere niente, dopo quanto risale.
    private static let idleSeconds: TimeInterval = 8

    func ask(for id: String) {
        // Un altro timer lasciato mentre scrivi il nome del primo: quel nome si salva, non si perde.
        if panel?.isVisible == true, !closing { commit() }
        guard let panel = ensurePanel() else { return }
        timerID = id
        closing = false
        model.text = ""
        panel.makeKeyAndOrderFront(nil)
        withAnimation(.spring(response: 0.36, dampingFraction: 0.8)) { model.shown = true }
        model.focus += 1
        // Il cursore entra anche se il campo nasce dopo la richiesta: un secondo tentativo al giro successivo.
        DispatchQueue.main.async { TimerNamer.shared.model.focus += 1 }
        idle?.invalidate()
        let timer = Timer(timeInterval: Self.idleSeconds, repeats: false) { _ in
            MainActor.assumeIsolated {
                let namer = TimerNamer.shared
                if namer.model.text.trimmingCharacters(in: .whitespaces).isEmpty { namer.dismiss() }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        idle = timer
    }

    /// Invio, o un clic altrove: salva il nome se c'è.
    func commit() {
        let name = model.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let id = timerID, !name.isEmpty { TimerCenter.shared.rename(id: id, title: String(name.prefix(40))) }
        dismiss()
    }

    /// Esc, o il tempo scaduto senza scrivere: risale senza nome.
    func dismiss() {
        guard !closing, panel?.isVisible == true else { return }
        closing = true
        idle?.invalidate()
        idle = nil
        timerID = nil
        withAnimation(.spring(response: 0.3, dampingFraction: 0.9)) { model.shown = false }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.28) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.closing else { return }
                self.panel?.orderOut(nil)
                self.closing = false
            }
        }
    }

    /// La finestra ha perso la tastiera (un clic altrove): vale come Invio.
    fileprivate func resigned() {
        guard !closing, panel?.isVisible == true else { return }
        commit()
    }

    private func ensurePanel() -> TimerNamerPanel? {
        guard let island = IslandHub.shared.primary else { return nil }
        let g = island.geometry
        let size = Self.size
        // Appena sotto il notch, al centro.
        let frame = CGRect(x: g.notchCenterX - size.width / 2,
                           y: g.frame.maxY - CGFloat(g.metrics.notchHeight) - 6 - size.height,
                           width: size.width, height: size.height)
        if panel == nil || panelSpace != IslandHub.shared.spaceToken {
            panel?.close()
            let panel = TimerNamerPanel(frame: frame)
            // Nello Space dell'isola, prima di comparire (vedi `IslandHub.adopt`).
            panelSpace = IslandHub.shared.adopt(panel)
            let host = NSHostingView(rootView: TimerNamerView(model: model,
                                                              commit: { TimerNamer.shared.commit() },
                                                              cancel: { TimerNamer.shared.dismiss() }))
            host.sizingOptions = []
            host.frame = CGRect(origin: .zero, size: size)
            panel.contentView = host
            self.panel = panel
        }
        if panel?.frame != frame { panel?.setFrame(frame, display: false) }
        return panel
    }
}

@MainActor @Observable
final class TimerNamerModel {
    var text = ""
    var shown = false
    /// Cresce a ogni richiesta: il campo prende il cursore.
    var focus = 0
}

/// La finestra del nome: senza bordo, sopra tutto come l'isola, e l'unica di Charland che prende la tastiera senza
/// attivare l'app.
final class TimerNamerPanel: NSPanel {
    init(frame: CGRect) {
        super.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        isMovable = false
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = false
        isReleasedWhenClosed = false
        animationBehavior = .none
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// Il vetro trasparente vero anche qui (vedi `IslandPanel`).
    @objc func _hasActiveAppearanceIgnoringKeyFocus() -> Bool { true }

    override func cancelOperation(_ sender: Any?) {
        MainActor.assumeIsolated { TimerNamer.shared.dismiss() }
    }

    override func resignKey() {
        super.resignKey()
        MainActor.assumeIsolated { TimerNamer.shared.resigned() }
    }
}

/// La capsula: il segno del timer, il campo, il tasto Invio. Vetro di Charland col velo più scuro (come il notch dove
/// c'è il contenuto): il testo bianco si legge anche sopra una pagina bianca.
struct TimerNamerView: View {
    @Bindable var model: TimerNamerModel
    let commit: () -> Void
    let cancel: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "timer")
                .font(.system(size: 14, weight: .semibold))
                .inked(.orange)
            TextField(String(localized: "Nome del timer"), text: $model.text)
                .textFieldStyle(.plain)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .focused($focused)
                .onSubmit(commit)
                .onExitCommand(perform: cancel)
            Text("↩")
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(model.text.isEmpty ? 0.3 : 0.7))
        }
        .padding(.horizontal, 16)
        .frame(width: 296, height: 44)
        .background {
            CharlandGlassFill(shape: Capsule(), veil: AnyShapeStyle(Color.black.opacity(0.62)))
        }
        .shadow(color: .black.opacity(CharlandGlass.shadowOpacity), radius: CharlandGlass.shadowRadius, y: CharlandGlass.shadowY)
        .environment(\.colorScheme, .dark)
        // Scende dal notch e ci risale.
        .scaleEffect(model.shown ? 1 : 0.7, anchor: .top)
        .offset(y: model.shown ? 0 : -18)
        .opacity(model.shown ? 1 : 0)
        .frame(width: TimerNamer.size.width, height: TimerNamer.size.height, alignment: .top)
        .padding(.top, 4)
        .onChange(of: model.focus) { focused = true }
        .onAppear { focused = true }
    }
}
