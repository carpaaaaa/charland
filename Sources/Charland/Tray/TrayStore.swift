import AppKit
import QuickLookThumbnailing
import SwiftUI
import UniformTypeIdentifiers

/// Un file nel vassoio. Il vassoio tiene un riferimento al file, non una copia.
struct TrayItem: Identifiable, Equatable, Codable {
    var id = UUID()
    var path: String
    var added: Date
    var pinned = false

    var url: URL { URL(fileURLWithPath: path) }
    var name: String { (path as NSString).lastPathComponent }
}

/// Il vassoio: i file lasciati sopra l'isola. Le schede non fissate si tolgono da sole dopo il tempo scelto in
/// Impostazioni › Vassoio (tre giorni di serie).
@MainActor @Observable
final class TrayStore {
    static let shared = TrayStore()

    private(set) var items: [TrayItem] = [] {
        didSet {
            // La fila del vassoio sta nella casa solo se ci sono file: quando compare o sparisce, l'isola aperta
            // cambia altezza insieme alle tessere.
            // Non durante `init` (il `prune` iniziale): lì `Home.current` rientrerebbe in `TrayStore.shared`.
            if ready, oldValue.isEmpty != items.isEmpty { IslandHub.shared.homeChanged() }
        }
    }
    @ObservationIgnored private var ready = false
    /// Un file sta passando sopra l'isola: la casa mostra la zona dove lasciarlo.
    var dropping = false
    /// Dove andrebbe il file sotto il puntatore: nel vassoio o dritto ad AirDrop.
    var zone: TrayZone?
    /// Il file sotto il puntatore è dentro la zona del vassoio.
    var targeted: Bool {
        get { zone == .tray }
        set { zone = newValue ? .tray : nil }
    }
    /// Il riquadro della zona AirDrop nella finestra dell'isola (origine in alto), per sapere dove cade il file. Cambia a
    /// ogni fotogramma dell'apertura e nessuna vista lo legge: fuori dall'osservazione.
    @ObservationIgnored var airdropRect: CGRect = .zero

    static let maxItems = 12
    /// Dopo quanti giorni escono le schede non fissate: 1, 3 (di serie) o 7; 0 = mai (Impostazioni › Vassoio).
    var lifetimeDays: Int {
        didSet {
            UserDefaults.standard.set(lifetimeDays, forKey: "trayLifetimeDays")
            prune()
        }
    }

    @ObservationIgnored private var icons: [String: NSImage] = [:]
    /// Le anteprime vere (la foto, la prima pagina del PDF, un fotogramma del video), quando Quick Look sa farle.
    @ObservationIgnored private var thumbnails: [String: NSImage] = [:]
    @ObservationIgnored private var loading: Set<String> = []
    @ObservationIgnored private var thumbnailRequested: Set<String> = []
    /// Cresce quando arriva un'icona: le schede la leggono per ridisegnarsi.
    private(set) var iconsReady = 0
    /// L'icona generica del documento, mentre quella vera si prepara.
    @ObservationIgnored private lazy var placeholder: NSImage = Self.shrink(NSWorkspace.shared.icon(for: .data))

    private init() {
        lifetimeDays = UserDefaults.standard.object(forKey: "trayLifetimeDays") as? Int ?? 3
        if let data = UserDefaults.standard.data(forKey: "trayItems"),
           let saved = try? JSONDecoder().decode([TrayItem].self, from: data) {
            items = saved
        }
        prune()
        ready = true
    }

    var isEmpty: Bool { items.isEmpty }

    func add(_ urls: [URL]) {
        prune()
        for url in urls where url.isFileURL {
            // lo stesso file rilasciato di nuovo torna in cima e resta fissato se lo era
            let pinned = items.first { $0.path == url.path }?.pinned ?? false
            items.removeAll { $0.path == url.path }
            // rilasciato di nuovo può essere cambiato: l'anteprima si rifà
            forget(url.path)
            items.insert(TrayItem(path: url.path, added: Date(), pinned: pinned), at: 0)
        }
        // Oltre il limite escono le schede più vecchie non fissate. I fissati non contano: prima, con dodici fissati, il
        // file appena lasciato era l'unico non fissato e usciva subito, senza dire niente.
        while items.filter({ !$0.pinned }).count > Self.maxItems, let index = items.lastIndex(where: { !$0.pinned }) {
            forget(items[index].path)
            items.remove(at: index)
        }
        save()
    }

    func remove(_ item: TrayItem) {
        forget(item.path)
        items.removeAll { $0.id == item.id }
        save()
    }

    /// Fissa o sfissa un file: fissato resta nel vassoio finché non lo togli tu (Impostazioni › Vassoio).
    func setPinned(_ item: TrayItem, _ pinned: Bool) {
        guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        items[index].pinned = pinned
        save()
    }

    func clear() {
        for item in items where !item.pinned { forget(item.path) }
        items.removeAll { !$0.pinned }
        save()
    }

    /// Icona e anteprima di un file che esce dal vassoio. Anche «anteprima già chiesta»: senza, lo stesso file
    /// rimesso nel vassoio restava con la sola icona fino al riavvio.
    private func forget(_ path: String) {
        icons[path] = nil
        thumbnails[path] = nil
        thumbnailRequested.remove(path)
    }

    /// Il file sta su un disco che adesso non è collegato (`/Volumes/<disco>/…` senza il suo disco).
    static func volumeMissing(_ path: String) -> Bool {
        let parts = path.split(separator: "/")
        guard parts.count >= 2, parts[0] == "Volumes" else { return false }
        return !FileManager.default.fileExists(atPath: "/Volumes/\(parts[1])")
    }

    /// Toglie le schede dei file spariti e quelle vecchie non fissate.
    func prune() {
        let now = Date()
        let before = items.count
        items.removeAll { item in
            // Un file fissato su un disco non collegato in questo momento resta: prima, con Charland accesa al login
            // prima del disco esterno (o a disco espulso), i fissati di quel disco sparivano per sempre.
            let missing = !FileManager.default.fileExists(atPath: item.path) && !(item.pinned && Self.volumeMissing(item.path))
            let old = lifetimeDays > 0 && now.timeIntervalSince(item.added) > Double(lifetimeDays) * 24 * 3600
            let gone = missing || (!item.pinned && old)
            if gone { forget(item.path) }
            return gone
        }
        if items.count != before { save() }
    }

    /// Quello che mostra una scheda: l'anteprima vera se Quick Look la sa fare (carpa, 18 novembre 2026: «voglio si veda
    /// la preview del file tipo dell'immagine»), se no l'icona del file. Tutto si prepara fuori dal thread principale:
    /// leggerlo qui, mentre l'isola si apre, costava fotogrammi. Finché non c'è niente, l'icona generica.
    func preview(for item: TrayItem) -> TrayPreview {
        let path = item.path
        if let thumbnail = thumbnails[path] { return TrayPreview(image: thumbnail, thumbnail: true, fills: Self.fills(path)) }
        if thumbnailRequested.insert(path).inserted {
            // 96 punti a scala 2: abbastanza nitida per la scheda (al massimo 44 punti) anche su Retina.
            let request = QLThumbnailGenerator.Request(fileAt: item.url, size: CGSize(width: 96, height: 96), scale: 2,
                                                       representationTypes: .thumbnail)
            QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { representation, _ in
                guard let box = representation.map({ IconBox($0.nsImage) }) else { return }
                Task { @MainActor in
                    let store = TrayStore.shared
                    guard store.items.contains(where: { $0.path == path }) else { return }
                    store.thumbnails[path] = box.image
                    store.iconsReady += 1
                }
            }
        }
        if let cached = icons[path] { return TrayPreview(image: cached, thumbnail: false, fills: false) }
        if loading.insert(path).inserted {
            Task.detached(priority: .userInitiated) {
                let image = IconBox(Self.shrink(NSWorkspace.shared.icon(forFile: path)))
                await MainActor.run {
                    let store = TrayStore.shared
                    store.icons[path] = image.image
                    store.loading.remove(path)
                    store.iconsReady += 1
                }
            }
        }
        return TrayPreview(image: placeholder, thumbnail: false, fills: false)
    }

    /// Foto e video riempiono il quadrato (come nella libreria di Foto); documenti e PDF si vedono interi.
    nonisolated static func fills(_ path: String) -> Bool {
        guard let type = UTType(filenameExtension: (path as NSString).pathExtension) else { return false }
        return type.conforms(to: .image) || type.conforms(to: .movie)
    }

    // MARK: Condivisione

    /// AirDrop dritto, senza passare dal vassoio: il file lasciato sulla zona AirDrop, o «Condividi tutto» › AirDrop.
    func airDrop(_ urls: [URL]) {
        guard !urls.isEmpty, let service = NSSharingService(named: .sendViaAirDrop) else { return }
        // La finestra di AirDrop è di Charland: senza attivarla resterebbe dietro l'app davanti.
        NSApp.activate()
        service.perform(withItems: urls)
    }

    /// Tutti i file del vassoio, per «Condividi tutto». Quelli spariti nel frattempo restano fuori.
    var shareableURLs: [URL] {
        items.map(\.url).filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// Un'icona a più misure ridotta a una sola bitmap da 68 pixel (34 punti su Retina): disegnarla costa poco.
    nonisolated static func shrink(_ icon: NSImage, side: Int = 68) -> NSImage {
        guard let cg = icon.cgImage(forProposedRect: nil, context: nil,
                                    hints: [.ctm: AffineTransform(scale: CGFloat(side) / max(1, icon.size.width))]),
              let ctx = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return icon }
        ctx.interpolationQuality = .high
        // riempie il quadrato tagliando al centro: una copertina larga (un video) non si schiaccia
        let w = CGFloat(cg.width), h = CGFloat(cg.height), box = CGFloat(side)
        let scale = max(box / max(1, w), box / max(1, h))
        ctx.draw(cg, in: CGRect(x: (box - w * scale) / 2, y: (box - h * scale) / 2, width: w * scale, height: h * scale))
        guard let small = ctx.makeImage() else { return icon }
        return NSImage(cgImage: small, size: NSSize(width: side / 2, height: side / 2))
    }

    private func save() {
        UserDefaults.standard.set(try? JSONEncoder().encode(items), forKey: "trayItems")
    }
}

/// Porta un'immagine dal thread di sfondo al principale (è creata lì e poi solo letta).
struct IconBox: @unchecked Sendable {
    let image: NSImage
    init(_ image: NSImage) { self.image = image }
}

/// Dove cade un file trascinato sopra l'isola aperta.
enum TrayZone: Equatable {
    /// «Rilascia qui»: resta nel vassoio.
    case tray
    /// «Condividi su AirDrop»: parte subito con AirDrop e nel vassoio non entra.
    case airdrop
}

/// L'immagine di una scheda: anteprima vera o icona.
struct TrayPreview {
    let image: NSImage
    let thumbnail: Bool
    /// L'anteprima riempie il quadrato (foto, video) invece di vedersi intera.
    let fills: Bool
}

/// La fila dei file nel vassoio, con «Condividi tutto» in fondo. Ogni scheda si trascina fuori dove vuoi. Una scheda
/// nuova entra crescendo, una tolta esce sfumando.
struct TrayRow: View {
    let store: TrayStore

    var body: some View {
        let _ = store.iconsReady
        HStack(spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(store.items) { item in
                        TrayCard(item: item, preview: store.preview(for: item)) { store.remove(item) }
                            .transition(.asymmetric(insertion: .scale(scale: 0.5).combined(with: .opacity),
                                                    removal: .opacity.combined(with: .scale(scale: 0.8))))
                    }
                }
                // La x dell'ultima scheda sporge di 4 punti: un filo d'aria a destra perché non venga tagliata.
                .padding(.trailing, 6)
                .animation(.spring(response: 0.38, dampingFraction: 0.78), value: store.items)
            }
            .scrollClipDisabled()
            // Sopra e sotto la x può uscire; ai lati no, se no le schede scorrerebbero sotto «Condividi tutto».
            .mask(Rectangle().padding(.vertical, -10))
            ShareAllTile(store: store)
        }
        .frame(height: 70)
    }
}

/// Una scheda del vassoio: l'anteprima (o l'icona) e il nome. Passandoci sopra compare la x per toglierla.
struct TrayCard: View {
    let item: TrayItem
    let preview: TrayPreview
    let remove: () -> Void
    @State private var hovering = false

    var body: some View {
        VStack(spacing: 4) {
            image.frame(height: 40)
            Text(item.name).font(.system(size: 10.5, weight: .semibold)).foregroundStyle(.white)
                .lineLimit(1).truncationMode(.middle)
        }
        .padding(.horizontal, 6)
        .frame(width: 66, height: 66)
        .background {
            RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.white.opacity(hovering ? 0.14 : 0.08))
                .animation(.hover(hovering), value: hovering)
        }
        .overlay(alignment: .topTrailing) {
            if hovering {
                Button(action: remove) {
                    Image(systemName: "xmark").font(.system(size: 8, weight: .bold)).foregroundStyle(.white)
                        .frame(width: 16, height: 16)
                        .background(Color.black.opacity(0.7), in: Circle())
                }
                .buttonStyle(.plain)
                .offset(x: 4, y: -4)
                .transition(.scale(scale: 0.6).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.24, dampingFraction: 0.8), value: hovering)
        // Il riquadro dell'hover include la x, che sporge di 4 punti: passandoci sopra la scheda resta accesa.
        .islandHover($hovering, outset: 6)
        .onDrag { NSItemProvider(contentsOf: item.url) ?? NSItemProvider() }
        .help(item.path)
    }

    /// Foto e video in un quadrato pieno dagli angoli tondi; PDF e documenti interi, col loro bordo; le icone come sono.
    /// Raggio 8: la scheda (14) meno l'aria ai lati (6).
    @ViewBuilder private var image: some View {
        if preview.thumbnail && preview.fills {
            Image(nsImage: preview.image).resizable().interpolation(.high).aspectRatio(contentMode: .fill)
                .frame(width: 40, height: 40)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        } else if preview.thumbnail {
            Image(nsImage: preview.image).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
                .frame(maxWidth: 44, maxHeight: 40)
                .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
                .shadow(color: .black.opacity(0.25), radius: 1.5, y: 0.5)
        } else {
            Image(nsImage: preview.image).resizable().interpolation(.high).frame(width: 34, height: 34)
        }
    }
}

/// «Condividi tutto» in fondo alla fila: il foglio di condivisione di macOS con tutti i file del vassoio (AirDrop,
/// Messaggi, Mail e il resto), per mandarne tanti insieme (carpa, 18 novembre 2026).
struct ShareAllTile: View {
    let store: TrayStore
    @State private var hovering = false
    @State private var anchor = ShareAnchor.Box()

    var body: some View {
        Button {
            TrayShare.showPicker(urls: store.shareableURLs, from: anchor.view)
        } label: {
            VStack(spacing: 4) {
                Image(systemName: "square.and.arrow.up").font(.system(size: 17, weight: .semibold)).frame(height: 40)
                Text("Condividi tutto").font(.system(size: 10.5, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.85)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 4)
            .frame(width: 66, height: 66)
            .background {
                RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.black.opacity(0.22))
                    .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color.white.opacity(hovering ? 0.17 : 0.09))
                        .animation(.hover(hovering), value: hovering))
            }
            .background(ShareAnchor(box: anchor))
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(TilePress())
        .islandHover($hovering, name: "condividi-tutto")
        .help(String(localized: "Condividi tutto"))
    }
}

/// Una vista AppKit vuota dietro «Condividi tutto»: il foglio di condivisione di macOS si appoggia a una vista vera.
struct ShareAnchor: NSViewRepresentable {
    final class Box {
        weak var view: NSView?
    }
    let box: Box

    func makeNSView(context: Context) -> AnchorView {
        let view = AnchorView()
        box.view = view
        return view
    }

    func updateNSView(_ view: AnchorView, context: Context) { box.view = view }

    final class AnchorView: NSView {
        /// Solo un appoggio: i clic passano al pulsante.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

/// Il foglio di condivisione nato dall'isola. Mentre è aperto l'isola resta aperta sotto di lui (`PointerTracker.holdOpen`):
/// per sceglierci dentro il puntatore esce dall'isola, e chiudendola il foglio resterebbe appeso nel vuoto.
@MainActor
final class TrayShare: NSObject, NSSharingServicePickerDelegate {
    private static let shared = TrayShare()

    static func showPicker(urls: [URL], from view: NSView?) {
        guard !urls.isEmpty, let view, view.window != nil else { return }
        let picker = NSSharingServicePicker(items: urls)
        picker.delegate = shared
        PointerTracker.holdOpen = true
        picker.show(relativeTo: view.bounds, of: view, preferredEdge: .minY)
    }

    nonisolated func sharingServicePicker(_ sharingServicePicker: NSSharingServicePicker, didChoose service: NSSharingService?) {
        let chosen = service != nil
        MainActor.assumeIsolated {
            PointerTracker.holdOpen = false
            // La finestra del servizio scelto (AirDrop, Mail…) è di Charland: davanti, se no resta dietro l'app attiva.
            if chosen { NSApp.activate() }
        }
    }
}

/// La zona dove lasciare un file mentre lo trascini sopra l'isola, divisa in due (carpa, 18 novembre 2026): «Rilascia qui»
/// tiene il file nel vassoio, «Condividi su AirDrop», un poco più stretta, lo manda subito con AirDrop.
struct TrayDropZones: View {
    let zone: TrayZone?
    let tall: Bool

    var body: some View {
        GeometryReader { geo in
            let gap: CGFloat = 8
            let wide = ((geo.size.width - gap) * 0.56).rounded()
            HStack(spacing: gap) {
                TrayDropTile(symbol: "tray.and.arrow.down.fill", title: String(localized: "Rilascia qui"),
                             targeted: zone == .tray, tall: tall, size: 20)
                    .frame(width: wide)
                TrayDropTile(symbol: "dot.radiowaves.left.and.right", title: String(localized: "Condividi su AirDrop"),
                             targeted: zone == .airdrop, tall: tall, size: 17)
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { TrayStore.shared.airdropRect = $0 }
            }
        }
    }
}

struct TrayDropTile: View {
    let symbol: String
    let title: String
    let targeted: Bool
    let tall: Bool
    let size: CGFloat

    var body: some View {
        VStack(spacing: tall ? 8 : 5) {
            Image(systemName: symbol).font(.system(size: size, weight: .semibold))
            Text(title).font(.system(size: size > 18 ? 13 : 12, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.8)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.white.opacity(targeted ? 0.18 : 0.09), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .scaleEffect(targeted ? 1.02 : 1)
        .animation(.spring(response: 0.25, dampingFraction: 0.8), value: targeted)
    }
}
