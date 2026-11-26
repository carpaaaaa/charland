import SwiftUI
import CharlandCore

/// La radice di quello che si vede nella finestra dell'isola.
struct IslandStageView: View {
    let model: IslandModel
    let appearance: Appearance

    var body: some View {
        // Le viste dell'isola restano vive anche a riposo, ferme: non costano niente e alla
        // prima apertura non vanno create (crearle in quel momento faceva saltare fotogrammi).
        // A riposo il bordo è vuoto, quindi non si disegna niente.
        ZStack(alignment: .topLeading) {
            IslandBackdrop(model: model, appearance: appearance)
            IslandHitArea(model: model)
            IslandContents(model: model)
        }
        .frame(width: model.stageSize.width, height: model.stageSize.height, alignment: .topLeading)
        .environment(\.colorScheme, .dark)
        // I pulsanti leggono da qui l'hover deciso dal puntatore vero (`IslandHover`).
        .environment(model)
        // I file trascinati li riceve la finestra in AppKit (`IslandPanel`, `TrayDropTarget`): con `.onDrop` qui
        // SwiftUI rifaceva i conti dell'isola a ogni movimento del mouse e il trascinamento aspettava, a scatti.
    }
}

/// Il tocco vale solo dentro la forma: premere schiaccia appena l'isola, come un tasto. È una vista a parte perché
/// legge il bordo, che cambia a ogni fotogramma: letto dalla radice, ricostruiva la radice e il gesto ogni volta.
struct IslandHitArea: View {
    let model: IslandModel

    var body: some View {
        Color.clear
            .contentShape(OutlineShape(path: model.outline))
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in model.onPress(true) }
                    .onEnded { value in
                        model.onPress(false)
                        if abs(value.translation.width) < 6, abs(value.translation.height) < 6 { model.onTap() }
                    }
            )
    }
}

/// Riceve i file lasciati sopra l'isola, dentro la forma e solo mentre la zona del vassoio è aperta. Sta in AppKit:
/// a ogni movimento del trascinamento il sistema chiede «posso lasciarlo qui?» e aspetta la risposta, quindi la
/// risposta deve essere immediata (un controllo sulla forma, nessun ridisegno se non cambia niente).
@MainActor
final class TrayDropTarget {
    private let model: IslandModel

    init(model: IslandModel) { self.model = model }

    /// Il punto del trascinamento nelle coordinate della finestra dell'isola, con l'origine in alto.
    private func inside(_ sender: NSDraggingInfo, window: NSWindow) -> Bool {
        let p = sender.draggingLocation
        return model.hitTest(CGPoint(x: p.x, y: window.frame.height - p.y))
    }

    func update(_ sender: NSDraggingInfo, window: NSWindow) -> NSDragOperation {
        let tray = TrayStore.shared
        var zone: TrayZone?
        if tray.dropping && inside(sender, window: window) {
            let p = sender.draggingLocation
            zone = tray.airdropRect.contains(CGPoint(x: p.x, y: window.frame.height - p.y)) ? .airdrop : .tray
        }
        if zone != tray.zone { tray.zone = zone }
        return zone == nil ? [] : .copy
    }

    func exit() {
        if TrayStore.shared.zone != nil { TrayStore.shared.zone = nil }
    }

    func accepts(_ sender: NSDraggingInfo, window: NSWindow) -> Bool {
        TrayStore.shared.dropping && inside(sender, window: window)
    }

    /// Gli indirizzi si leggono subito dagli appunti del trascinamento: niente caricamenti a pezzi.
    func perform(_ sender: NSDraggingInfo) -> Bool {
        let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self],
                                                         options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        guard !urls.isEmpty else {
            model.onDrop(false)
            return false
        }
        if TrayStore.shared.zone == .airdrop {
            // Dritto ad AirDrop: nel vassoio non entra e l'isola si chiude. La finestra di AirDrop si apre appena finito il
            // trascinamento (aprirla dentro la consegna del file la faceva aspettare il sistema).
            NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
            model.onDrop(false)
            DispatchQueue.main.async { MainActor.assumeIsolated { TrayStore.shared.airDrop(urls) } }
            return true
        }
        TrayStore.shared.add(urls)
        NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
        model.onDrop(true)
        return true
    }
}

/// Raccoglie gli indirizzi dei file che arrivano uno alla volta, da thread diversi.
final class URLCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var urls: [URL] = []
    private var remaining: Int
    private let done: @Sendable ([URL]) -> Void

    init(expected: Int, done: @escaping @Sendable ([URL]) -> Void) {
        remaining = expected
        self.done = done
    }

    func add(_ url: URL?) {
        lock.lock()
        if let url { urls.append(url) }
        remaining -= 1
        let finished = remaining == 0
        let result = urls
        lock.unlock()
        if finished { done(result) }
    }
}

/// I contenuti, ognuno nella sua cornice fissa, ritagliati dal bordo dell'isola.
/// Opacità, scala e sfocatura vengono dal motore, fotogramma per fotogramma.
struct IslandContents: View {
    let model: IslandModel

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(model.frame.layers, id: \.key) { layer in
                let look = layer.look
                // Si tocca il contenuto aperto e la fila delle altre attività sotto di lui; aperta sulla musica, anche la
                // copertina (o la nota) e l'onda ai lati della fotocamera.
                let artwork = (layer.slot == .leading || layer.slot == .trailing) && model.expandedID == layer.id
                    && Self.isMusic(model.contents[layer.id])
                // Nella casa aperta la tazzina di Mantieni attivo in alto a destra e il meteo in alto a sinistra.
                let corner = (layer.slot == .trailing || layer.slot == .leading) && layer.id == IslandState.homeID
                    && model.expandedID == IslandState.homeID
                // Aperta su una domanda o un permesso di un agente, la mascotte accanto alla fotocamera porta all'app.
                let asking = layer.slot == .leading && model.expandedID == layer.id && Self.isAsking(model.contents[layer.id])
                let live = (layer.slot == .expanded || layer.slot == .switcher || artwork || corner || asking) && look.opacity > 0.5
                // Le attività aperte senza pulsanti (agenti, timer, avanzamento) lasciano passare il clic all'isola sotto:
                // così anche un clic sul tempo grande porta alla casa, e l'isola si schiaccia appena come un tasto.
                let passThrough = layer.slot == .expanded && Self.withoutControls(model.contents[layer.id])
                // La goccia sinistra è lo specchio di quella destra: le viste la disegnano uguale.
                SlotContent(model: model, slot: layer.slot == .minimalLeading ? .minimal : layer.slot, id: layer.id)
                    .frame(width: layer.frame.width, height: layer.frame.height)
                    .scaleEffect(look.scale)
                    .blur(radius: look.blur)
                    .opacity(look.opacity)
                    .offset(x: model.originX + layer.frame.x, y: layer.frame.y)
                    // Solo il contenuto aperto ha pulsanti; il resto lascia passare il tocco all'isola.
                    // Cliccabile da metà della comparsa: aspettare il 90% faceva perdere il primo clic appena aperta.
                    // Lo stesso vale per l'hover (`IslandHover`): quello che sfuma via non si accende.
                    .modifier(TapToIsland(enabled: layer.slot == .expanded && layer.id != IslandState.homeID && !passThrough,
                                          model: model))
                    .allowsHitTesting(live && !passThrough)
                    .environment(\.islandInteractive, live)
                    .environment(\.islandShown, look.opacity > 0.01)
            }
        }
        .frame(width: model.stageSize.width, height: model.stageSize.height, alignment: .topLeading)
        .clipShape(OutlineShape(path: model.outline))
    }

    /// Aperta su un agente (al lavoro, o che chiede qualcosa), la mascotte accanto alla fotocamera porta alla sua finestra.
    static func isAsking(_ content: ActivityContent?) -> Bool {
        switch content {
        case .api(let api)?: api.isAgent
        case .agents(let info)?: info.lead != nil || info.ask != nil
        default: false
        }
    }

    static func isMusic(_ content: ActivityContent?) -> Bool {
        if case .music? = content { return true }
        return false
    }

    /// Contenuti che aperti non hanno niente da premere.
    static func withoutControls(_ content: ActivityContent?) -> Bool {
        switch content {
        // Gli agenti non hanno niente da premere finché nessuno chiede: con una richiesta ci sono i suoi pulsanti.
        case .agents(let info)?: info.ask == nil
        case .timer?, .agent?, .progress?: true
        default: false
        }
    }
}

/// Un clic sul contenuto aperto di un'attività, fuori dai suoi pulsanti, vale come un clic sull'isola (porta alla casa).
/// Il bersaglio sta dietro il contenuto: un `onTapGesture` sopra rubava il clic ai pulsanti («Spegni» portava alla casa
/// invece di spegnere, provato il 17 novembre 2026).
struct TapToIsland: ViewModifier {
    let enabled: Bool
    let model: IslandModel

    func body(content: Content) -> some View {
        content.background {
            if enabled {
                // Lo stesso gesto del fondo dell'isola: premendo l'isola si schiaccia appena, come un tasto.
                Color.clear
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { _ in model.onPress(true) }
                            .onEnded { value in
                                model.onPress(false)
                                if abs(value.translation.width) < 6, abs(value.translation.height) < 6 { model.onTap() }
                            }
                    )
            }
        }
    }
}

/// Un tempo solo: quando l'attività è aperta, il tempo piccolo accanto alla fotocamera sfuma via.
struct OneClock: ViewModifier {
    let hidden: Bool
    func body(content: Content) -> some View {
        content
            .opacity(hidden ? 0 : 1)
            .blur(radius: hidden ? 4 : 0)
            .animation(.easeOut(duration: 0.18), value: hidden)
    }
}

extension ContentLayer {
    var key: String { "\(slot.rawValue):\(id)" }
}

/// Sceglie la vista giusta per un posto e un contenuto.
struct SlotContent: View {
    let model: IslandModel
    let slot: ContentSlot
    let id: String

    var body: some View {
        if slot == .switcher {
            // Dentro un'attività aperta: le altre attività in corso, come pillole.
            ActivitySwitcher(model: model, ids: id.split(separator: "|").map(String.init))
        } else {
            content
        }
    }

    @ViewBuilder private var content: some View {
        switch id {
        case "dictation":
            switch slot {
            case .leading: DictationLeading(model: model)
            case .trailing: VoiceLine(model: model)
            case .lip: LiveTextView(model: model)
            default: EmptyView()
            }
        case SliderSide.volume.rawValue, SliderSide.brightness.rawValue:
            SliderPill(model: model)
        default:
            if case .agents(let info)? = model.contents[id] {
                AgentsSlotView(info: info, slot: slot)
                    .modifier(OneClock(hidden: slot == .trailing && model.expandedID == id))
            } else if case .music(let info)? = model.contents[id] {
                MusicSlotView(info: info, slot: slot) { action in model.onAction(action, id) }
            } else if case .home(let info)? = model.contents[id] {
                HomeSlotView(info: info, slot: slot) { action in model.onAction(action, id) }
            } else if case .api(let content)? = model.contents[id] {
                APISlotView(content: content, slot: slot) { action in model.onAction(action, id) }
                    .modifier(OneClock(hidden: slot == .trailing && model.expandedID == id
                        && (content.template == .countdown || content.recording || content.isAgent)))
            } else if let content = model.contents[id] {
                ActivitySlotView(content: content, slot: slot)
            }
        }
    }
}

/// Un'attività in uno dei suoi quattro aspetti.
struct ActivitySlotView: View, Equatable {
    let content: ActivityContent
    let slot: ContentSlot

    var body: some View {
        switch (content, slot) {
        case (.music(let info), .leading):
            Artwork(info: info, corner: 6).frame(width: 21, height: 21)
        case (.music(let info), .trailing):
            Image(systemName: "waveform")
                .font(.system(size: 13, weight: .semibold))
                .symbolEffect(.variableColor.iterative.dimInactiveLayers, isActive: info.isPlaying)
                .foregroundStyle(.white)
        case (.music(let info), .minimal):
            Artwork(info: info, corner: 9).padding(4)
        case (.music(let info), .expanded):
            MusicExpanded(info: info)

        case (.timer(let info), .leading):
            Image(systemName: "timer").font(.system(size: 13, weight: .semibold)).inked(.orange)
        case (.timer(let info), .trailing):
            LiveCountdown(end: info.end)
                .font(.system(size: 13, weight: .semibold, design: .rounded)).monospacedDigit()
                .inked(.orange)
        case (.timer(let info), .minimal):
            TimerRing(info: info).padding(5)
        case (.timer(let info), .expanded):
            VStack(spacing: 6) {
                Text(info.label).font(.system(size: 14, weight: .medium)).foregroundStyle(.secondary)
                LiveCountdown(end: info.end)
                    .font(.system(size: 44, weight: .semibold, design: .rounded)).monospacedDigit()
                    .inked(.orange)
            }

        case (.agent(let info), .leading):
            Image(systemName: "sparkle").font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
        case (.agent(let info), .trailing):
            AgentBadge(info: info)
        case (.agent(let info), .minimal):
            AgentBadge(info: info, inDrop: true)
        case (.agent(let info), .expanded):
            AgentExpanded(info: info)

        case (.progress(let info), .leading):
            Image(systemName: info.symbol).font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
        case (.progress(let info), .trailing), (.progress(let info), .minimal):
            ProgressRing(fraction: info.fraction).padding(slot == .minimal ? 5 : 6)
        case (.progress(let info), .expanded):
            VStack(spacing: 10) {
                Text(info.title).font(.system(size: 16, weight: .semibold)).foregroundStyle(.white)
                ProgressView(value: info.fraction).tint(.white)
                if !info.status.isEmpty {
                    Text(info.status).font(.system(size: 13, weight: .medium)).foregroundStyle(.secondary)
                }
            }
        case (.api, _):
            EmptyView()
        default:
            EmptyView()
        }
    }
}

// MARK: - Pezzi

/// La copertina: l'immagine vera se c'è, altrimenti due campiture piatte.
struct Artwork: View {
    let info: MusicInfo
    let corner: CGFloat

    var body: some View {
        // Con «Tutto vetro» la copertina è una lastra: in bianco e nero, col filo di luce sul bordo.
        let glass = Glassy.covers
        Group {
            if let image = info.artwork {
                Image(nsImage: glass ? GlassCover.image(for: image) : image).resizable().aspectRatio(contentMode: .fill)
            } else if let a = info.tintA, let b = info.tintB {
                GeometryReader { geo in
                    ZStack(alignment: .bottomLeading) {
                        if glass { Color.white.opacity(0.16) } else { a }
                        (glass ? Color.white.opacity(0.3) : b).frame(width: geo.size.width * 0.62, height: geo.size.height * 0.62)
                    }
                }
            } else if let icon = info.appIcon {
                // senza copertina (molti siti non la mandano): l'icona dell'app che suona
                Image(nsImage: icon).resizable().aspectRatio(contentMode: .fit).padding(1)
                    .saturation(glass ? 0 : 1).opacity(glass ? 0.85 : 1)
            } else {
                // senza copertina: una nota su un fondo neutro, niente colori inventati
                GeometryReader { geo in
                    ZStack {
                        Color.white.opacity(0.14)
                        Image(systemName: "music.note")
                            .font(.system(size: geo.size.height * 0.5, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.8))
                    }
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
        .overlay {
            if glass {
                RoundedRectangle(cornerRadius: corner, style: .continuous).strokeBorder(Glassy.rim, lineWidth: 0.7)
            }
        }
    }
}

/// La copertina accanto alla fotocamera e nelle gocce ai lati: un disco che gira mentre suona, oppure la copertina
/// ferma con gli angoli tondi, come si sceglie in Impostazioni (carpa, 18 novembre 2026). Senza una copertina vera
/// resta il segno fermo: l'icona di un'app che gira non sembra un disco.
struct MusicCover: View {
    let info: MusicInfo
    let corner: CGFloat

    var body: some View {
        if Features.shared.musicCover == .disc, let image = info.artwork {
            SpinningDisc(image: Glassy.covers ? GlassCover.image(for: image) : image, playing: info.isPlaying, glass: Glassy.covers)
        } else {
            Artwork(info: info, corner: corner)
        }
    }
}

struct TimerRing: View {
    let info: TimerInfo
    @Environment(\.islandShown) private var shown

    var body: some View {
        // L'anello avanza solo mentre si vede: nascosto (un'altra attività al centro, l'isola chiusa) non sveglia l'app.
        TimelineView(.periodic(from: .now, by: shown ? 1 : 3600)) { context in
            let left = max(0, info.end.timeIntervalSince(context.date))
            ProgressRing(fraction: info.total > 0 ? left / info.total : 0, tint: .orange)
        }
    }
}

/// Un arco sottile. Mai un pallino che pulsa.
struct ProgressRing: View {
    var fraction: Double
    var tint: Color = .white

    var body: some View {
        ZStack {
            Circle().stroke(Glassy.flat(tint).opacity(0.22), lineWidth: 2.5)
            Circle().trim(from: 0, to: min(1, max(0, fraction)))
                .stroke(Glassy.ink(tint), style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
    }
}

struct AgentBadge: View {
    let info: AgentInfo
    /// Nella goccia staccata «Needs you» non ci sta: lì resta la stellina dell'agente.
    var inDrop = false

    var body: some View {
        switch info.phase {
        case .working:
            // Un arco sottile che gira sul bordo.
            SpinArc().padding(6)
        case .waiting where inDrop:
            Image(systemName: "sparkle").font(.system(size: 12, weight: .semibold)).foregroundStyle(.white)
        case .waiting:
            NeedsYouLabel()
        case .done:
            Image(systemName: "checkmark").font(.system(size: 12, weight: .bold)).inked(.green)
        }
    }
}

struct AgentExpanded: View {
    let info: AgentInfo

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "sparkle").font(.system(size: 13, weight: .semibold))
                Text(info.project).font(.system(size: 15, weight: .semibold))
                Spacer()
                Text(info.agent).font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
            }
            if !info.explanation.isEmpty {
                Text(info.explanation).font(.system(size: 15, weight: .medium)).lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if !info.command.isEmpty {
                Text(info.command).font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Spacer(minLength: 0)
            HStack(spacing: 8) {
                KeyHint(keys: "⌘↩", label: String(localized: "Approva"), prominent: true)
                KeyHint(keys: "⌘⌫", label: String(localized: "Rifiuta"), prominent: false)
                KeyHint(keys: "⌘⌥↩", label: String(localized: "Sempre"), prominent: false)
            }
        }
        .foregroundStyle(.white)
    }
}

struct KeyHint: View {
    let keys: String
    let label: String
    let prominent: Bool

    var body: some View {
        HStack(spacing: 6) {
            Text(label).font(.system(size: 13, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.75)
            if !keys.isEmpty {
                Text(keys).font(.system(size: 11, weight: .medium, design: .rounded)).opacity(0.6)
            }
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, minHeight: 30)
        .foregroundStyle(prominent ? .black : .white)
        .background {
            if prominent || !Glassy.on { Capsule().fill(prominent ? Color.white : Color.white.opacity(0.14)) } else { GlassPlate(shape: Capsule()) }
        }
    }
}

/// La musica in riproduzione nei suoi quattro aspetti: copertina a sinistra della fotocamera, onda nel colore della
/// copertina a destra; aperta, titolo, barra che scorre da sola e comandi veri.
struct MusicSlotView: View {
    let info: MusicInfo
    let slot: ContentSlot
    let act: (String) -> Void

    var body: some View {
        switch slot {
        case .leading:
            if info.idle {
                // Niente in riproduzione: la nota apre l'app della musica scelta in Impostazioni (carpa, 18 novembre
                // 2026), con lo stesso aspetto della tazzina di Mantieni attivo nell'angolo opposto della casa.
                CornerButton(symbol: "music.note", help: String(localized: "Apri \(MusicApp.shared.name)")) { act("music:launch") }
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                // Con l'isola aperta sulla musica la copertina accanto alla fotocamera si preme: apre l'app che suona su
                // quella canzone (carpa, 18 novembre 2026). Chiusa, il clic resta all'isola (`IslandContents`).
                Button { act("music:open") } label: {
                    MusicCover(info: info, corner: 6).frame(width: 21, height: 21)
                }
                .buttonStyle(TilePress())
                .help(String(localized: "Apri l'app che suona"))
            }
        case .trailing:
            // Aperta, l'onda in alto a destra si preme: porta davanti quello che suona (la scheda di YouTube, l'app della
            // musica). Chiusa, il clic resta all'isola (`IslandContents`). Senza niente in riproduzione apre l'app scelta.
            MusicSourceButton(info: info) { act(info.idle ? "music:launch" : "music:front") }
                .frame(maxWidth: .infinity, alignment: .trailing)
        case .minimal:
            // Nella goccia a destra o a sinistra (non è l'attività principale) la copertina gira come un disco mentre
            // suona, oppure resta ferma con gli angoli tondi: la stessa scelta che vale accanto alla fotocamera.
            MusicCover(info: info, corner: 9).padding(4)
        case .expanded:
            MusicExpanded(info: info, act: act)
        default:
            EmptyView()
        }
    }
}

/// L'onda della musica in alto a destra, che aperta si preme come la tazzina della casa.
struct MusicSourceButton: View {
    let info: MusicInfo
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            // Un piccolo equalizzatore che batte mentre suona (in pausa, cinque puntini).
            EqualizerBars(playing: info.isPlaying && !info.idle, color: Glassy.flat(info.tint), glass: Glassy.on,
                          seed: Self.seed(info), position: info.position(at: .now))
                .frame(width: EqualizerBars.size.width, height: EqualizerBars.size.height)
                .opacity(info.isPlaying ? 1 : 0.5)
                .frame(width: 30, height: 24)
                .background {
                    Capsule().fill(Color.white.opacity(hovering ? 0.17 : 0))
                        .animation(.hover(hovering), value: hovering)
                }
                .contentShape(Capsule())
        }
        .buttonStyle(TilePress())
        .islandHover($hovering, name: "musica-sorgente")
        .help(info.idle ? String(localized: "Apri \(MusicApp.shared.name)") : String(localized: "Mostra cosa suona"))
    }

    /// Un numero per brano, uguale a ogni avvio: sceglie il tempo e i colpi dell'equalizzatore.
    static func seed(_ info: MusicInfo) -> Int {
        var hash = 5381
        for unit in (info.title + "|" + info.artist).utf8 { hash = (hash &* 33) &+ Int(unit) }
        return hash
    }
}

/// La copertina come un disco: tonda, col foro al centro, che gira in senso orario. Gira Core Animation fuori dall'app
/// (come `SpinArc`), quindi non sveglia l'app a ogni fotogramma; in pausa si ferma dov'è e riparte da lì.
struct SpinningDisc: NSViewRepresentable {
    let image: NSImage
    let playing: Bool
    /// Con «Tutto vetro» il disco ha il filo di luce sul bordo.
    var glass = false

    func makeNSView(context: Context) -> SpinningDiscView { SpinningDiscView() }
    func updateNSView(_ view: SpinningDiscView, context: Context) { view.update(image: image, playing: playing, glass: glass) }
}

final class SpinningDiscView: NSView {
    private let disc = CALayer()
    private let hole = CAShapeLayer()
    private let rim = CAShapeLayer()
    private var image: NSImage?
    private var playing = false

    /// Un giro ogni quattro secondi: un 33 giri vero (1,8 s) in una goccia di 18 punti sembrava frenetico.
    private static let turn: CFTimeInterval = 4

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        disc.masksToBounds = true
        disc.contentsGravity = .resizeAspectFill
        layer?.addSublayer(disc)
        hole.fillColor = NSColor.black.cgColor
        hole.strokeColor = NSColor.white.withAlphaComponent(0.2).cgColor
        hole.lineWidth = 0.5
        layer?.addSublayer(hole)
        rim.fillColor = nil
        rim.strokeColor = NSColor.white.withAlphaComponent(0.34).cgColor
        rim.lineWidth = 0.7
        rim.isHidden = true
        layer?.addSublayer(rim)
    }

    required init?(coder: NSCoder) { fatalError("non usato") }

    /// Solo da guardare: i clic passano all'isola sotto.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func update(image: NSImage, playing: Bool, glass: Bool = false) {
        if image !== self.image {
            self.image = image
            disc.contents = image
        }
        if rim.isHidden == glass { rim.isHidden = !glass }
        if playing != self.playing {
            self.playing = playing
            spin()
        }
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let side = min(bounds.width, bounds.height)
        disc.bounds = CGRect(x: 0, y: 0, width: side, height: side)
        disc.position = CGPoint(x: bounds.midX, y: bounds.midY)
        disc.cornerRadius = side / 2
        disc.contentsScale = window?.backingScaleFactor ?? 2
        let r = max(1.5, side * 0.11)
        hole.frame = bounds
        hole.path = CGPath(ellipseIn: CGRect(x: bounds.midX - r, y: bounds.midY - r, width: 2 * r, height: 2 * r), transform: nil)
        rim.frame = bounds
        rim.path = CGPath(ellipseIn: CGRect(x: bounds.midX - side / 2, y: bounds.midY - side / 2, width: side, height: side)
            .insetBy(dx: 0.35, dy: 0.35), transform: nil)
        CATransaction.commit()
        spin()
    }

    /// Core Animation toglie le animazioni quando il livello esce dall'albero: rientrando, il disco riparte.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        spin()
    }

    private func spin() {
        guard window != nil else { return }
        if disc.animation(forKey: "gira") == nil {
            let turn = CABasicAnimation(keyPath: "transform.rotation.z")
            turn.fromValue = 0
            // In senso orario: negli strati di AppKit l'asse y sale, quindi l'angolo scende.
            turn.toValue = -2 * Double.pi
            turn.duration = Self.turn
            turn.repeatCount = .infinity
            turn.isRemovedOnCompletion = false
            disc.add(turn, forKey: "gira")
        }
        if playing {
            // Riparte dall'angolo in cui si era fermato.
            guard disc.speed == 0 else { return }
            let paused = disc.timeOffset
            disc.speed = 1
            disc.timeOffset = 0
            disc.beginTime = 0
            disc.beginTime = disc.convertTime(CACurrentMediaTime(), from: nil) - paused
        } else {
            guard disc.speed != 0 else { return }
            let now = disc.convertTime(CACurrentMediaTime(), from: nil)
            disc.speed = 0
            disc.timeOffset = now
        }
    }
}

struct MusicExpanded: View {
    let info: MusicInfo
    var act: (String) -> Void = { _ in }

    /// Dove sta il dito mentre si trascina la linea del tempo (da 0 a 1).
    @State private var dragging: Double?
    /// L'ultimo spostamento chiesto: la linea resta lì finché l'app che suona non conferma, se no tornava indietro per
    /// un attimo e poi saltava avanti.
    @State private var seek: Seek?
    @Environment(\.islandShown) private var shown

    private struct Seek: Equatable {
        var target: TimeInterval
        var at: Date
    }

    /// Il punto da mostrare: quello trascinato, quello appena chiesto o quello vero.
    private func shownPosition(at date: Date) -> TimeInterval {
        if let dragging { return dragging * info.duration }
        let actual = info.position(at: date)
        if let seek {
            let since = date.timeIntervalSince(seek.at)
            let expected = min(info.duration, seek.target + (info.isPlaying ? since : 0))
            if since < 2, abs(actual - expected) > 1.5 { return expected }
        }
        return actual
    }

    private func fraction(_ x: CGFloat, _ width: CGFloat) -> Double { width > 0 ? Double(min(1, max(0, x / width))) : 0 }

    var body: some View {
        if info.idle { idleBody } else { playingBody }
    }

    /// La riproduzione vuota: stesso posto e stessi comandi della riproduzione vera, così aprirla non salta. ▶︎ fa ripartire
    /// l'ultimo lettore (o l'app della musica scelta); avanti e indietro aspettano che ci sia qualcosa.
    private var idleBody: some View {
        VStack(spacing: 9) {
            VStack(spacing: 1) {
                Text("Niente in riproduzione").font(.system(size: 16, weight: .semibold)).foregroundStyle(.white).lineLimit(1)
                Text(info.appName ?? "").font(.system(size: 13, weight: .medium)).foregroundStyle(.white.opacity(0.6)).lineLimit(1)
            }
            .padding(.horizontal, 24)
            Capsule().fill(.white.opacity(0.2)).frame(height: 5)
                .padding(.horizontal, 22)
                .frame(height: 15)
            HStack(spacing: 30) {
                MusicButton(symbol: "backward.fill", size: 17) {}.opacity(0.3).disabled(true)
                MusicButton(symbol: "play.fill", size: 22) { act("music:toggle") }
                MusicButton(symbol: "forward.fill", size: 17) {}.opacity(0.3).disabled(true)
            }
        }
        .padding(.top, 4)
    }

    private var playingBody: some View {
        VStack(spacing: 9) {
            // Copertina e onda restano ai lati della fotocamera: qui sotto, titolo, barra e comandi.
            // Titolo e artista non si premono: l'app della musica si apre solo dalla copertina in alto a sinistra (carpa,
            // 19 novembre 2026: «quando premo l'album in alto a sinistra, lì mi deve aprire l'app della musica. Solo
            // lì»). Prima erano un pulsante largo quanto l'isola e un clic quasi ovunque nel lettore apriva Musica.
            // La forma resta: un clic sul titolo non fa niente, invece di cadere sul fondo e portare alla casa.
            VStack(spacing: 1) {
                Text(info.title).font(.system(size: 16, weight: .semibold)).foregroundStyle(.white).lineLimit(1)
                Text([info.artist, info.appName].compactMap { $0?.isEmpty == false ? $0 : nil }.joined(separator: " · "))
                    .font(.system(size: 13, weight: .medium)).foregroundStyle(.white.opacity(0.6)).lineLimit(1)
            }
            .padding(.horizontal, 24)
            .contentShape(Rectangle())
            // la barra scorre da sola mentre suona: si ridisegna solo così, aperta. Le dirette non hanno durata:
            // al posto della barra vuota la parola «In diretta».
            if info.duration <= 0 {
                Text("In diretta")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(Glassy.ink(info.tint.opacity(0.9)))
                    .frame(height: 15)
            } else {
            // Scorre solo mentre la riproduzione è aperta e si vede: chiusa, la barra non c'è e l'app non si sveglia.
            TimelineView(.periodic(from: .now, by: info.isPlaying && shown ? 0.5 : 3600)) { context in
                let position = shownPosition(at: context.date)
                HStack(spacing: 8) {
                    Text(Self.clock(position))
                    GeometryReader { geo in
                        let bar = ZStack(alignment: .leading) {
                            Capsule().fill(.white.opacity(0.2))
                            Capsule().fill(Glassy.ink(info.tint))
                                .frame(width: geo.size.width * (info.duration > 0 ? min(1, position / info.duration) : 0))
                                // trascinando segue il puntatore senza ritardo
                                .animation(dragging == nil ? .linear(duration: 0.5) : nil, value: position)
                        }
                        // presa, la linea si ingrossa un poco come su iPhone
                        .scaleEffect(x: 1, y: dragging == nil ? 1 : 1.6)
                        .animation(.spring(response: 0.25, dampingFraction: 0.8), value: dragging == nil)
                        if Features.shared.musicScrub {
                            // Si trascina avanti e indietro (anche un tocco porta il brano lì). La presa è più alta della
                            // linea, che è di 5 punti: l'impaginazione non cambia.
                            bar
                                .padding(.vertical, 9)
                                .contentShape(Rectangle())
                                .gesture(
                                    DragGesture(minimumDistance: 0)
                                        .onChanged { value in
                                            guard info.duration > 0 else { return }
                                            dragging = fraction(value.location.x, geo.size.width)
                                        }
                                        .onEnded { value in
                                            guard info.duration > 0, geo.size.width > 0 else { dragging = nil; return }
                                            let target = info.duration * fraction(value.location.x, geo.size.width)
                                            seek = Seek(target: target, at: Date())
                                            dragging = nil
                                            act("music:seek:\(Int(target))")
                                        }
                                )
                                .padding(.vertical, -9)
                        } else {
                            bar
                        }
                    }
                    .frame(height: 5)
                    Text(info.duration > 0 ? Self.clock(info.duration) : "")
                }
                .font(.system(size: 11, weight: .semibold, design: .rounded)).monospacedDigit()
                .foregroundStyle(.white.opacity(0.6))
            }
            .padding(.horizontal, 22)
            }
            HStack(spacing: 30) {
                MusicButton(symbol: "backward.fill", size: 17) { act("music:previous") }
                MusicButton(symbol: info.isPlaying ? "pause.fill" : "play.fill", size: 22) { act("music:toggle") }
                MusicButton(symbol: "forward.fill", size: 17) { act("music:next") }
            }
        }
        .padding(.top, 4)
    }

    static func clock(_ t: TimeInterval) -> String {
        let s = Int(t.rounded())
        return "\(s / 60):" + String(format: "%02d", s % 60)
    }
}

/// Un comando della musica: il simbolo, che si schiaccia un poco premendo.
struct MusicButton: View {
    let symbol: String
    let size: CGFloat
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .semibold))
                .contentTransition(.symbolEffect(.replace))
                .foregroundStyle(.white)
                .frame(width: 44, height: 34)
                .background(Circle().fill(.white.opacity(hovering ? 0.12 : 0)).frame(width: 38, height: 38)
                    .animation(.hover(hovering), value: hovering))
                .contentShape(Rectangle())
        }
        .buttonStyle(TilePress())
        .islandHover($hovering)
    }
}

/// Un arco sottile che gira, animato da Core Animation fuori dall'app. Prima girava con un orologio a 30 Hz:
/// tremava accanto all'isola a 60 e svegliava l'app per tutto il tempo che un agente lavorava.
struct SpinArc: NSViewRepresentable {
    func makeNSView(context: Context) -> SpinArcView { SpinArcView() }
    func updateNSView(_ view: SpinArcView, context: Context) {}
}

final class SpinArcView: NSView {
    private let arc = CAShapeLayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        arc.fillColor = nil
        arc.strokeColor = NSColor.white.cgColor
        arc.lineWidth = 2
        arc.lineCap = .round
        arc.strokeEnd = 0.28
        layer?.addSublayer(arc)
    }

    required init?(coder: NSCoder) { fatalError("non usato") }

    /// Solo da guardare: i clic passano all'isola sotto.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        arc.frame = bounds
        let side = max(0, min(bounds.width, bounds.height) - arc.lineWidth)
        arc.path = CGPath(ellipseIn: CGRect(x: (bounds.width - side) / 2, y: (bounds.height - side) / 2, width: side, height: side),
                          transform: nil)
        CATransaction.commit()
        spin()
    }

    /// Core Animation toglie le animazioni quando il livello esce dall'albero: rientrando, l'arco riparte.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        spin()
    }

    private func spin() {
        guard window != nil, arc.animation(forKey: "gira") == nil else { return }
        let turn = CABasicAnimation(keyPath: "transform.rotation.z")
        turn.fromValue = 0
        // In senso orario: negli strati di AppKit l'asse y sale, quindi l'angolo scende.
        turn.toValue = -2 * Double.pi
        turn.duration = 1.4
        turn.repeatCount = .infinity
        turn.isRemovedOnCompletion = false
        arc.add(turn, forKey: "gira")
    }
}
