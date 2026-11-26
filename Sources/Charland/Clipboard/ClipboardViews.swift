import AppKit
import Carbon.HIToolbox
import SwiftUI

/// Il menu degli appunti e l'anteprima accanto, in una finestra sola: un vetro solo con la forma della goccia
/// (`ClipMenuShape.outline`), nero in alto come il notch e sempre più vetro scendendo, il filo di luce dove comincia il
/// vetro, un'ombra morbida. I contenuti stanno alla loro misura vera e la forma li ritaglia mentre nasce.
struct ClipboardMenuView: View {
    let shape: ClipMenuShape
    let state: ClipMenuState
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        let outline = OutlineShape(path: shape.outline)
        let box = shape.outline.boundingRect
        ZStack(alignment: .topLeading) {
            // Il vetro in un riquadro grande quanto la forma, non quanto la finestra: con la forma lontana dall'angolo
            // della finestra il vetro di sistema scuriva un rettangolo intero, dall'inizio della forma al bordo della
            // finestra (provato il 17 novembre 2026: solo vetro, rettangolo; vetro nel suo riquadro, niente).
            if box.width > 0, box.height > 0 {
                CharlandGlassFill(shape: OutlineShape(path: shape.outline.offsetBy(dx: -box.minX, dy: -box.minY)),
                                  veil: AnyShapeStyle(veil(in: box)), rim: AnyShapeStyle(rim(in: box)))
                    .frame(width: box.width, height: box.height)
                    .offset(x: box.minX, y: box.minY)
            }
            ZStack(alignment: .topLeading) {
                ClipPanelContent(state: state)
                    .frame(width: ClipMetrics.width, height: shape.contentHeight, alignment: .top)
                    .offset(x: shape.panel.minX, y: shape.panel.minY + CGFloat(1 - shape.reveal) * -6)
                    .opacity(shape.reveal)
                    .allowsHitTesting(shape.reveal > 0.5)
            }
            .clipShape(outline)
            // L'anteprima: un vetro suo accanto al menu, che compare e scompare in dissolvenza (carpa, 18 novembre 2026:
            // «un classico fade smooth»). Stesso vetro e stesso raggio del menu.
            if shape.previewShown, shape.previewGlass > 0.001 {
                let frame = shape.previewFrame
                let card = RoundedRectangle(cornerRadius: ClipMetrics.radius, style: .continuous)
                ZStack(alignment: .top) {
                    CharlandGlassFill(shape: card, veil: AnyShapeStyle(previewVeil), rim: AnyShapeStyle(previewRim))
                    ClipPreviewCard(state: state)
                        .frame(width: frame.width, height: frame.height, alignment: .top)
                        .opacity(shape.previewGlass > 0 ? shape.previewReveal / shape.previewGlass : 0)
                }
                .frame(width: frame.width, height: frame.height)
                .clipShape(card)
                .opacity(shape.previewGlass)
                .offset(x: frame.minX, y: frame.minY)
                .allowsHitTesting(false)
            }
        }
        .frame(width: shape.size.width, height: shape.size.height, alignment: .topLeading)
        .shadow(color: .black.opacity(0.2), radius: 14, y: 6)
        .environment(\.colorScheme, .dark)
    }

    /// Il velo dell'anteprima: scuro in alto come il menu sotto la ricerca, un poco più chiaro in fondo.
    private var previewVeil: LinearGradient {
        let floor = contrast == .increased ? 0.86 : 0.6
        return LinearGradient(colors: [.black.opacity(0.9), .black.opacity(floor)], startPoint: .top, endPoint: .bottom)
    }

    /// Il filo di luce dell'anteprima, come sul bordo del menu.
    private var previewRim: LinearGradient {
        LinearGradient(colors: [.white.opacity(CharlandGlass.rimTop * 0.6), .white.opacity(CharlandGlass.rimBottom + 0.08)],
                       startPoint: .top, endPoint: .bottom)
    }

    /// La y della finestra come punto della sfumatura disegnata nel riquadro `box`.
    private func unit(_ y: CGFloat, _ box: CGRect) -> CGFloat { box.height > 0 ? min(1, max(0, (y - box.minY) / box.height)) : 0 }

    /// Dal nero pieno sulla barra (dove nasce la goccia) a un vetro scuro in fondo: il testo bianco si legge anche sopra
    /// una pagina bianca. Con Contrasto aumentato resta più scuro.
    private func veil(in box: CGRect) -> LinearGradient {
        let top = shape.panel.minY + ClipMetrics.header
        let bottom = shape.panel.maxY
        let floor = contrast == .increased ? 0.86 : 0.55
        return LinearGradient(stops: [
            .init(color: .black, location: 0),
            .init(color: .black.opacity(0.95), location: unit(top, box)),
            .init(color: .black.opacity(0.95 - (0.95 - floor) * 0.55), location: unit(top + (bottom - top) * 0.5, box)),
            .init(color: .black.opacity(floor), location: unit(bottom, box)),
            .init(color: .black.opacity(floor), location: 1),
        ], startPoint: .top, endPoint: .bottom)
    }

    /// Il filo di luce come nel notch: niente sul nero, il più chiaro dove comincia il vetro, più tenue in fondo.
    private func rim(in box: CGRect) -> LinearGradient {
        let top = shape.panel.minY + ClipMetrics.header
        let bottom = shape.panel.maxY
        return LinearGradient(stops: [
            .init(color: .white.opacity(0), location: 0),
            .init(color: .white.opacity(0.04), location: unit(top, box)),
            .init(color: .white.opacity(CharlandGlass.rimTop * 0.8), location: unit(top + (bottom - top) * 0.6, box)),
            .init(color: .white.opacity(CharlandGlass.rimBottom + 0.08), location: unit(bottom, box)),
            .init(color: .white.opacity(CharlandGlass.rimBottom + 0.08), location: 1),
        ], startPoint: .top, endPoint: .bottom)
    }
}

/// Ricerca, elenco, piede.
struct ClipPanelContent: View {
    let state: ClipMenuState

    var body: some View {
        VStack(spacing: 0) {
            ClipSearchField(state: state).frame(height: ClipMetrics.header)
            ClipList(state: state).frame(maxHeight: .infinity)
            ClipFooter(state: state).frame(height: ClipMetrics.footer)
        }
    }
}

/// Il campo di ricerca: il cursore è già dentro, si scrive e l'elenco si filtra. Frecce, Invio ed Esc li prende il menu.
struct ClipSearchField: View {
    @Bindable var state: ClipMenuState
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white.opacity(0.5))
            TextField("", text: $state.query, prompt: Text("Cerca negli appunti").foregroundStyle(.white.opacity(0.36)))
                .textFieldStyle(.plain)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.white)
                .focused($focused)
            if !state.query.isEmpty {
                Button { state.query = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.45))
                }
                .buttonStyle(.plain)
                .transition(.opacity.combined(with: .scale(scale: 0.8)))
            }
        }
        .padding(.leading, 12)
        .padding(.trailing, 10)
        .frame(height: 32)
        // Una pillola sua, col raggio delle righe (22 − 6 = 16): prima lente e scritta galleggiavano sul nero.
        .background {
            RoundedRectangle(cornerRadius: ClipMetrics.rowRadius, style: .continuous)
                .fill(.white.opacity(focused ? 0.09 : 0.06))
                .overlay(RoundedRectangle(cornerRadius: ClipMetrics.rowRadius, style: .continuous)
                    .strokeBorder(.white.opacity(0.07), lineWidth: 0.5))
        }
        .padding(.horizontal, ClipMetrics.inset)
        .padding(.top, 4)
        .animation(.spring(response: 0.26, dampingFraction: 0.86), value: state.query.isEmpty)
        // Il cursore lo mette anche `ClipboardMenu.focusSearch` col campo di AppKit: alla seconda apertura SwiftUI da
        // solo non lo rimetteva (`focused` era ancora vero) e le lettere andavano perse.
        .onChange(of: state.focus) { focused = true }
        .onAppear { focused = true }
    }
}

/// L'elenco: i fissati in cima, una riga sottile, poi il resto dal più recente.
struct ClipList: View {
    let state: ClipMenuState

    var body: some View {
        let pinned = state.pinned, recent = state.recent
        if pinned.isEmpty, recent.isEmpty {
            ClipEmpty(searching: !state.query.isEmpty)
                .transition(.opacity)
        } else {
            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(pinned.enumerated()), id: \.element.id) { index, item in
                            ClipRow(item: item, index: index, state: state)
                        }
                        if !pinned.isEmpty, !recent.isEmpty {
                            Rectangle()
                                .fill(.white.opacity(0.08))
                                .frame(height: 1)
                                .padding(.horizontal, 12)
                                .frame(height: ClipMetrics.divider)
                        }
                        ForEach(Array(recent.enumerated()), id: \.element.id) { index, item in
                            ClipRow(item: item, index: pinned.count + index, state: state)
                        }
                    }
                    .padding(.vertical, ClipMetrics.listPadding)
                    .padding(.horizontal, ClipMetrics.inset)
                }
                .scrollIndicators(.automatic)
                .onChange(of: state.scrollTarget) {
                    guard let id = state.selected else { return }
                    proxy.scrollTo(id)
                }
            }
        }
    }
}

/// Una voce: il suo segno (l'app da cui viene, la miniatura, il colore, l'icona del file), una riga di testo, e a destra
/// la puntina se è fissata e, tenendo premuto ⌘, il numero per sceglierla.
struct ClipRow: View {
    let item: ClipItem
    let index: Int
    let state: ClipMenuState

    var body: some View {
        let selected = state.selected == item.id
        Button {
            ClipboardMenu.shared.choose(item.id, flags: NSEvent.modifierFlags)
        } label: {
            HStack(spacing: 10) {
                ClipGlyph(item: item)
                    .frame(width: 22, height: 22)
                    .opacity(selected ? 1 : 0.62)
                // Titolo e tempo in una fila loro senza spazi di serie: fra il testo tagliato e il tempo restano dieci
                // punti, non trenta (lo spazio della fila grande si sommava due volte attorno al vuoto).
                HStack(spacing: 0) {
                    title
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white.opacity(selected ? 1 : 0.56))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .layoutPriority(1)
                    Spacer(minLength: 10)
                    trailing
                        .fixedSize()
                }
            }
            .padding(.horizontal, 10)
            .frame(height: ClipMetrics.row)
            // Niente pillola sotto la voce scelta (carpa, 18 novembre 2026: «più clean»): si accende lei, segno e testo
            // pieni, e le altre restano attenuate.
            .animation(.easeOut(duration: 0.12), value: selected)
            .contentShape(RoundedRectangle(cornerRadius: ClipMetrics.rowRadius, style: .continuous))
        }
        .buttonStyle(ClipRowPress())
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { ClipboardMenu.shared.rowFrame(item.id, $0) }
        .onDisappear { ClipboardMenu.shared.rowFrame(item.id, nil) }
        .contextMenu { menu }
        .id(item.id)
        .transition(.asymmetric(insertion: .opacity, removal: .opacity.combined(with: .scale(scale: 0.96))))
        .accessibilityLabel(accessibilityText)
    }

    @ViewBuilder private var title: some View {
        switch item.kind {
        case .image:
            HStack(spacing: 5) {
                Text("Immagine")
                if let w = item.width, let h = item.height {
                    Text(verbatim: "\(w)×\(h)").foregroundStyle(.white.opacity(0.42)).monospacedDigit()
                }
            }
        case .file:
            HStack(spacing: 5) {
                Text(verbatim: item.title)
                if let files = item.files, files.count > 1 {
                    Text(verbatim: "+\(files.count - 1)").foregroundStyle(.white.opacity(0.42)).monospacedDigit()
                }
            }
        case .link:
            // Il sito in chiaro e il resto dell'indirizzo attenuato: si riconosce a colpo d'occhio di che pagina si tratta.
            let parts = Self.splitLink(Self.shortLink(item.title))
            Text(verbatim: parts.host) + Text(verbatim: parts.rest).foregroundStyle(.white.opacity(0.42))
        case .color:
            Text(verbatim: item.title.uppercased()).monospaced()
        case .text:
            Text(verbatim: item.title)
        }
    }

    @ViewBuilder private var trailing: some View {
        HStack(spacing: 6) {
            if item.pinned {
                Image(systemName: "pin.fill")
                    .font(.system(size: 9, weight: .semibold))
                    .rotationEffect(.degrees(40))
                    .foregroundStyle(.white.opacity(0.42))
            }
            if state.command, index < 9 {
                // Come un tastino: tenendo ⌘ si vede subito quale numero sceglie la voce.
                Text(verbatim: "⌘\(index + 1)")
                    .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.7))
                    .padding(.horizontal, 5)
                    .frame(height: 17)
                    .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(.white.opacity(0.1)))
                    .transition(.opacity)
            } else if !item.pinned, let age = Self.age(item.last) {
                // Da quanto tempo è stata copiata, corto: «5 min», «2 h», «3 g».
                Text(verbatim: age)
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.white.opacity(0.34))
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.12), value: state.command)
    }

    @ViewBuilder private var menu: some View {
        let settings = ClipboardSettings.shared
        Button("Incolla") { ClipboardMenu.shared.choose(item.id, paste: true, plain: false) }
        Button("Copia") { ClipboardMenu.shared.choose(item.id, paste: false, plain: false) }
        if item.kind == .text || item.kind == .link {
            Button("Incolla senza formattazione") { ClipboardMenu.shared.choose(item.id, paste: true, plain: true) }
        }
        Divider()
        Button(item.pinned ? "Togli dai fissati" : "Fissa") { ClipboardMenu.shared.togglePin(item.id) }
            .keyboardShortcut(settings.pinCombo?.swiftUIShortcut)
        Button("Anteprima") { ClipboardMenu.shared.preview(item.id) }
            .keyboardShortcut(settings.previewCombo?.swiftUIShortcut)
        Divider()
        Button("Elimina", role: .destructive) { ClipboardMenu.shared.delete(item.id) }
            .keyboardShortcut(settings.deleteCombo?.swiftUIShortcut)
    }

    private var accessibilityText: String {
        switch item.kind {
        case .image: String(localized: "Immagine")
        default: item.title
        }
    }

    /// Il sito e il resto dell'indirizzo (dalla prima barra, dal punto di domanda o dal cancelletto).
    static func splitLink(_ link: String) -> (host: String, rest: String) {
        guard let cut = link.firstIndex(where: { $0 == "/" || $0 == "?" || $0 == "#" }) else { return (link, "") }
        return (String(link[..<cut]), String(link[cut...]))
    }

    /// Da quanto tempo, in una parola corta e nella lingua del Mac: minuti, ore o giorni. Sotto il minuto niente.
    static func age(_ date: Date, now: Date = Date()) -> String? {
        let seconds = now.timeIntervalSince(date)
        guard seconds >= 60 else { return nil }
        let unit: Duration.UnitsFormatStyle.Unit = seconds < 3600 ? .minutes : seconds < 86_400 ? .hours : .days
        return Duration.seconds(seconds).formatted(.units(allowed: [unit], width: .narrow, maximumUnitCount: 1,
                                                          fractionalPart: .hide(rounded: .down)))
    }

    /// L'indirizzo senza «https://» e senza la barra finale: si legge prima.
    static func shortLink(_ s: String) -> String {
        var t = s
        for prefix in ["https://", "http://"] where t.hasPrefix(prefix) { t.removeFirst(prefix.count) }
        if t.hasPrefix("www.") { t.removeFirst(4) }
        if t.hasSuffix("/") { t.removeLast() }
        return t
    }
}

/// Premendo, la riga si schiaccia appena (le tessere dell'isola al 95%, una riga larga meno).
struct ClipRowPress: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.spring(response: 0.2, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

/// Il segno a sinistra di una voce.
struct ClipGlyph: View {
    let item: ClipItem
    private var thumbs: ClipThumbnails { .shared }

    var body: some View {
        switch item.kind {
        case .image:
            if let image = thumbs.image(item.id, pixels: 88) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 22, height: 22)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(.white.opacity(0.16), lineWidth: 0.5))
            } else {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(.white.opacity(0.08))
                    .overlay(Image(systemName: "photo").font(.system(size: 10, weight: .semibold)).foregroundStyle(.white.opacity(0.5)))
            }
        case .color:
            Circle()
                .fill(Color(nsColor: ClipboardHistory.color(item.title) ?? .clear))
                .frame(width: 15, height: 15)
                .overlay(Circle().stroke(.white.opacity(0.3), lineWidth: 1))
        case .file:
            if let path = item.files?.first, let icon = thumbs.fileIcon(path) {
                Image(nsImage: icon).resizable().frame(width: 20, height: 20)
            } else {
                Image(systemName: "doc").font(.system(size: 12, weight: .semibold)).foregroundStyle(.white.opacity(0.5))
            }
        case .text, .link:
            if let icon = thumbs.appIcon(item.app) {
                Image(nsImage: icon).resizable().frame(width: 18, height: 18)
            } else {
                Image(systemName: item.kind == .link ? "link" : "text.alignleft")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.5))
            }
        }
    }
}

/// Niente da mostrare: la farfalla, appena accennata.
struct ClipEmpty: View {
    let searching: Bool

    var body: some View {
        VStack(spacing: 9) {
            Image(nsImage: CharlandMark.templateImage(height: 17))
                .renderingMode(.template)
                .foregroundStyle(.white.opacity(0.28))
            Text(searching ? "Nessun risultato" : "Niente di copiato")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white.opacity(0.5))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Il piede: Cancella (con ⌥ diventa Cancella tutto, che chiede conferma) e le impostazioni.
struct ClipFooter: View {
    let state: ClipMenuState

    var body: some View {
        let empty = ClipboardHistory.shared.items.isEmpty
        let unpinned = ClipboardHistory.shared.items.contains { !$0.pinned }
        HStack(spacing: 6) {
            ClipFooterButton(title: clearTitle, destructive: state.confirmAll) {
                ClipboardMenu.shared.clear(fromButton: true)
            }
            .disabled(state.option ? empty : !unpinned)
            .animation(.spring(response: 0.26, dampingFraction: 0.86), value: clearTitle)
            Spacer()
            ClipFooterButton(symbol: "gearshape.fill") { ClipboardMenu.shared.openSettings() }
                .help(String(localized: "Impostazioni"))
        }
        .padding(.horizontal, ClipMetrics.inset + 2)
        .padding(.bottom, 4)
    }

    private var clearTitle: String {
        if state.confirmAll { return String(localized: "Conferma") }
        return state.option ? String(localized: "Cancella tutto") : String(localized: "Cancella")
    }
}

struct ClipFooterButton: View {
    var title: String? = nil
    var symbol: String? = nil
    var destructive = false
    let action: () -> Void
    @State private var hovering = false
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        Button(action: action) {
            Group {
                if let title {
                    Text(title).font(.system(size: 12, weight: .semibold)).contentTransition(.opacity)
                } else if let symbol {
                    Image(systemName: symbol).font(.system(size: 12, weight: .semibold))
                }
            }
            .foregroundStyle(destructive ? Color(red: 1, green: 0.42, blue: 0.4) : .white.opacity(enabled ? 0.78 : 0.3))
            .padding(.horizontal, title == nil ? 0 : 12)
            .frame(minWidth: 28, minHeight: 28)
            .background {
                Capsule()
                    .fill(destructive ? Color.red.opacity(0.18) : .white.opacity(hovering && enabled ? 0.14 : 0.07))
                    .animation(.hover(hovering), value: hovering)
            }
            .contentShape(Capsule())
        }
        .buttonStyle(ClipRowPress())
        .onHover { hovering = $0 }
    }
}

// MARK: - Anteprima

/// L'anteprima della voce scelta, accanto al menu. Misura la sua altezza naturale: la forma della goccia la segue.
struct ClipPreviewCard: View {
    let state: ClipMenuState

    var body: some View {
        if let item = state.selectedItem {
            ClipPreviewContent(item: item)
                .frame(width: ClipMetrics.previewWidth, alignment: .topLeading)
                .fixedSize(horizontal: false, vertical: true)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { ClipboardMenu.shared.previewMeasured($0) }
                .id(item.id)
                .transition(.opacity)
                .animation(.easeOut(duration: 0.14), value: item.id)
        }
    }
}

struct ClipPreviewContent: View {
    let item: ClipItem
    private var thumbs: ClipThumbnails { .shared }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            content
            meta
        }
        .padding(14)
    }

    @ViewBuilder private var content: some View {
        switch item.kind {
        case .image:
            if let image = thumbs.image(item.id, pixels: 640) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: 300)
                    .clipShape(RoundedRectangle(cornerRadius: ClipMetrics.radius - 14, style: .continuous))
            } else {
                RoundedRectangle(cornerRadius: ClipMetrics.radius - 14, style: .continuous)
                    .fill(.white.opacity(0.06))
                    .frame(height: 160)
            }
            if let w = item.width, let h = item.height {
                Text(verbatim: "\(w) × \(h)")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.white.opacity(0.7))
            }
        case .color:
            let color = ClipboardHistory.color(item.title) ?? .clear
            RoundedRectangle(cornerRadius: ClipMetrics.radius - 14, style: .continuous)
                .fill(Color(nsColor: color))
                .frame(height: 110)
                .overlay(RoundedRectangle(cornerRadius: ClipMetrics.radius - 14, style: .continuous).stroke(.white.opacity(0.15), lineWidth: 1))
            Text(verbatim: item.title.uppercased())
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
        case .file:
            VStack(alignment: .leading, spacing: 8) {
                ForEach((item.files ?? []).prefix(6), id: \.self) { path in
                    HStack(spacing: 10) {
                        Group {
                            if let icon = thumbs.fileIcon(path) { Image(nsImage: icon).resizable() } else { Image(systemName: "doc") }
                        }
                        .frame(width: 28, height: 28)
                        Text(verbatim: (path as NSString).lastPathComponent)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                if let first = item.files?.first {
                    Text(verbatim: (first as NSString).deletingLastPathComponent.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.5))
                        .lineLimit(3)
                }
            }
        case .link, .text:
            let text = item.text ?? item.title
            Text(verbatim: String(text.prefix(2500)))
                .font(Self.looksLikeCode(text) ? .system(size: 11.5, design: .monospaced) : .system(size: 12.5))
                .lineSpacing(2)
                .foregroundStyle(.white.opacity(0.92))
                .lineLimit(20)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var meta: some View {
        HStack(spacing: 6) {
            if let icon = thumbs.appIcon(item.app) {
                Image(nsImage: icon).resizable().frame(width: 14, height: 14)
            }
            if let name = item.appName {
                Text(verbatim: name).lineLimit(1)
                Text(verbatim: "·")
            }
            Text(item.last, format: .relative(presentation: .named))
        }
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(.white.opacity(0.48))
    }

    /// Codice: righe rientrate o segni da programma. Allora si mostra a spaziatura fissa.
    static func looksLikeCode(_ s: String) -> Bool {
        let sample = s.prefix(1500)
        let lines = sample.split(separator: "\n", omittingEmptySubsequences: false)
        let indented = lines.filter { $0.hasPrefix("  ") || $0.hasPrefix("\t") }.count
        if lines.count >= 3, indented * 3 >= lines.count { return true }
        let marks = ["{", "};", "=>", "func ", "def ", "const ", "import ", "</"]
        return marks.filter { sample.contains($0) }.count >= 2
    }
}

extension KeyCombo {
    /// La stessa combinazione per i menu di SwiftUI (si vede accanto alle voci del menu col tasto destro).
    var swiftUIShortcut: KeyboardShortcut? {
        guard !isModifiersOnly else { return nil }
        let key: KeyEquivalent
        switch Int(keyCode) {
        case kVK_Delete: key = .delete
        case kVK_Space: key = .space
        case kVK_Return: key = .return
        case kVK_Tab: key = .tab
        case kVK_Escape: key = .escape
        default:
            let name = KeyCombo.keyName(keyCode).lowercased()
            guard name.count == 1, let c = name.first else { return nil }
            key = KeyEquivalent(c)
        }
        var modifiers: SwiftUI.EventModifiers = []
        let f = flags
        if f.contains(.command) { modifiers.insert(.command) }
        if f.contains(.option) { modifiers.insert(.option) }
        if f.contains(.control) { modifiers.insert(.control) }
        if f.contains(.shift) { modifiers.insert(.shift) }
        return KeyboardShortcut(key, modifiers: modifiers)
    }
}
