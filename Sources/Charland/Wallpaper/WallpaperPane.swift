import SwiftUI
import UniformTypeIdentifiers

/// Impostazioni › Sfondo. In alto lo schermo intero com'è (con la tacca) e, nell'angolo, un pezzo alla misura vera.
/// Sotto: l'interruttore, l'immagine, lo stile (Favo, Lenti, Cannettato) e tutte le sue regolazioni.
struct WallpaperPane: View {
    @Bindable private var settings = WallpaperSettings.shared
    @State private var dropping = false
    /// La larghezza con cui l'anteprima si vede, in punti: si disegna esattamente a quella misura in pixel,
    /// perché un disegno rimpicciolito dopo fa il moiré.
    @State private var shownWidth: CGFloat = 0
    /// Un disegno alla volta: i ritocchi che arrivano intanto ne chiedono uno solo, subito dopo.
    @State private var drawing = false
    @State private var pendingDraw = false
    @State private var drawn: WallpaperDraw?
    @State private var preview = Crossfade()
    @State private var detail = Crossfade()

    /// Due strati: il disegno nuovo sale sopra quello vecchio, che resta pieno sotto finché il nuovo non è opaco
    /// (una dissolvenza fra due viste che sfumano insieme passerebbe per il nero del fondo).
    struct Crossfade {
        var back: CGImage?
        var front: CGImage?
        var opacity: Double = 1
    }

    /// La misura in pixel dello schermo principale: l'anteprima ne ha le proporzioni, il pezzo è a grandezza vera.
    private static var screen: (size: CGSize, scale: CGFloat) {
        guard let screen = NSScreen.screens.first else { return (CGSize(width: 2880, height: 1864), 2) }
        let scale = screen.backingScaleFactor
        return (CGSize(width: screen.frame.width * scale, height: screen.frame.height * scale), scale)
    }

    var body: some View {
        VStack(spacing: 0) {
            screenPreview
                .frame(maxHeight: 270)
                .padding([.horizontal, .top], 20)

            Form {
                Section {
                    Toggle("Sfondo di Charland", isOn: $settings.enabled)
                    Toggle("Su tutte le scrivanie", isOn: $settings.allDesktops)
                        .disabled(!settings.enabled)
                    // Se su questo Mac non è riuscito, lo dice (prima restava un interruttore acceso che non faceva niente).
                    if settings.enabled, settings.allDesktops, let problem = settings.allDesktopsProblem {
                        Text(problem.message).font(.callout).foregroundStyle(.secondary)
                    }
                    // Subito sotto (carpa, 20 novembre 2026): vale per tutti gli stili di vetro, non per uno solo.
                    if settings.style != .none { clearRows }
                }

                Section {
                    LabeledContent("Immagine") {
                        HStack(spacing: 8) {
                            Text(settings.imageName ?? String(localized: "Predefinita"))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Button("Scegli…") { choose() }
                        }
                    }
                }

                Section {
                    Picker("Stile", selection: $settings.style) {
                        Text("Nessuno").tag(WallpaperStyle.none)
                        Text("Cannettato").tag(WallpaperStyle.fluted)
                        Text("Lenti").tag(WallpaperStyle.lenses)
                        Text("Nebbia").tag(WallpaperStyle.fog)
                    }
                    .pickerStyle(.segmented)
                }

                switch settings.style {
                case .none: plainSection
                case .fog: fogSection
                case .lenses: lensSection
                case .fluted: flutedSection
                }
            }
            .formStyle(.grouped)
        }
        .onChange(of: DrawRequest(draw: settings.draw, width: shownWidth), initial: true) { requestDraw() }
        // Pannello in vista o no (finestra coperta o chiusa, altra sezione): l'immagine di partenza si tiene solo se serve.
        .background(WindowVisibilityReader { shown in settings.paneVisible = shown })
        .onAppear { settings.paneVisible = true }
        .onDisappear { settings.paneVisible = false }
    }

    // MARK: - Stili

    private var plainSection: some View {
        Section {
            Toggle("Bagliore", isOn: $settings.plainGlow)
        }
    }

    private var fogSection: some View {
        Section {
            Picker("Colore", selection: $settings.fog.tint) {
                Text("Foto").tag(FogOptions.Tint.photo)
                Text("Grigio").tag(FogOptions.Tint.gray)
            }
            .pickerStyle(.segmented)
            ValueSlider("Misura dei rilievi", value: $settings.fog.size, in: 3...40)
            ValueSlider("Rifrazione", value: $settings.fog.refraction, in: 0...2)
            ValueSlider("Smerigliato", value: $settings.fog.frost, in: 0...1)
            ValueSlider("Velo", value: $settings.fog.veil, in: 0...1)
            ValueSlider("Luce sui rilievi", value: $settings.fog.light, in: 0...1)
            ValueSlider("Dispersione", value: $settings.fog.dispersion, in: 0...1)
            ValueSlider("Togli a sinistra", value: cut($settings.fog.cutLeft, other: settings.fog.cutRight), in: 0...0.9)
            ValueSlider("Togli a destra", value: cut($settings.fog.cutRight, other: settings.fog.cutLeft), in: 0...0.9)
            ValueSlider("Grana", value: $settings.fog.grain, in: 0...1)
            ValueSlider("Luminosità", value: $settings.fog.brightness, in: -0.5...0.5)
            Toggle("Bagliore", isOn: $settings.fog.glow)
            resetButton
        }
    }

    /// La zona senza effetto: si sposta e si ridimensiona sull'anteprima, qui si accende e si sceglie il bordo.
    @ViewBuilder private var clearRows: some View {
        Toggle("Zona senza effetto", isOn: $settings.clear.enabled)
        if settings.clear.enabled {
            ValueSlider("Bordo morbido", value: $settings.clear.feather, in: 0...1)
            ValueSlider("Angoli arrotondati", value: $settings.clear.corners, in: 0...1)
        }
    }

    private var lensSection: some View {
        Section {
            Picker("Forma", selection: $settings.lens.shape) {
                Text("Cupole").tag(LensOptions.Shape.dome)
                Text("Piramidi").tag(LensOptions.Shape.pyramid)
            }
            .pickerStyle(.segmented)
            Picker("Griglia", selection: $settings.lens.grid) {
                Text("Diagonale").tag(LensOptions.Grid.diagonal)
                Text("Quadrata").tag(LensOptions.Grid.square)
                Text("Esagoni").tag(LensOptions.Grid.hex)
            }
            .pickerStyle(.segmented)
            Picker("Colore", selection: $settings.lens.tint) {
                Text("Foto").tag(LensOptions.Tint.photo)
                Text("Grigio").tag(LensOptions.Tint.gray)
            }
            .pickerStyle(.segmented)
            ValueSlider("Celle", value: $settings.lens.cell, in: 6...60)
            ValueSlider("Togli a sinistra", value: cut($settings.lens.cutLeft, other: settings.lens.cutRight), in: 0...0.9)
            ValueSlider("Togli a destra", value: cut($settings.lens.cutRight, other: settings.lens.cutLeft), in: 0...0.9)
            ValueSlider("Rifrazione", value: $settings.lens.refraction, in: 0...2)
            ValueSlider("Miniature", value: $settings.lens.miniatures, in: 0...1)
            ValueSlider("Smerigliato", value: $settings.lens.frost, in: 0...1)
            ValueSlider("Rilievo", value: $settings.lens.relief, in: 0...1)
            ValueSlider("Bordi", value: $settings.lens.seams, in: 0...1)
            ValueSlider("Dispersione", value: $settings.lens.dispersion, in: 0...1)
            ValueSlider("Luce sugli orli", value: $settings.lens.light, in: 0...1)
            ValueSlider("Grana", value: $settings.lens.grain, in: 0...1)
            ValueSlider("Luminosità", value: $settings.lens.brightness, in: -0.5...0.5)
            Toggle("Bagliore", isOn: $settings.lens.glow)
            resetButton
        }
    }

    private var flutedSection: some View {
        Section {
            Picker("Canne", selection: $settings.fluted.profile) {
                Text("Lastre").tag(FlutedOptions.Profile.flat)
                Text("Tonde").tag(FlutedOptions.Profile.round)
                Text("A punta").tag(FlutedOptions.Profile.pointed)
                Text("Specchio").tag(FlutedOptions.Profile.mirror)
            }
            .pickerStyle(.segmented)
            Picker("Colore", selection: $settings.fluted.tint) {
                Text("Foto").tag(FlutedOptions.Tint.photo)
                Text("Notte").tag(FlutedOptions.Tint.night)
                Text("Grigio").tag(FlutedOptions.Tint.gray)
            }
            .pickerStyle(.segmented)
            ValueSlider("Larghezza delle canne", value: $settings.fluted.width, in: 10...140)
            ValueSlider("Togli a sinistra", value: cut($settings.fluted.cutLeft, other: settings.fluted.cutRight), in: 0...0.9)
            ValueSlider("Togli a destra", value: cut($settings.fluted.cutRight, other: settings.fluted.cutLeft), in: 0...0.9)
            ValueSlider("Irregolarità", value: $settings.fluted.irregularity, in: 0...1)
            ValueSlider("Ripetizione", value: $settings.fluted.repetition, in: 0...1)
            ValueSlider("Rotazione", value: $settings.fluted.angle, in: -90...90,
                        slider: magnetic($settings.fluted.angle, stops: [-90, 0, 90], minorStops: [-45, 45]), degrees: true)
            ValueSlider("Curvatura", value: $settings.fluted.curve, in: 0...1)
            ValueSlider("Onde", value: $settings.fluted.waves, in: 0.5...6)
                .disabled(settings.fluted.curve < 0.01)
            ValueSlider("Rifrazione", value: $settings.fluted.refraction, in: 0...2)
            ValueSlider("Dispersione", value: $settings.fluted.dispersion, in: 0...1)
            ValueSlider("Strascico", value: $settings.fluted.smear, in: 0...1)
            ValueSlider("Smerigliato", value: $settings.fluted.frost, in: 0...1)
            ValueSlider("Luce sugli orli", value: $settings.fluted.light, in: 0...1)
            ValueSlider("Grana", value: $settings.fluted.grain, in: 0...1)
            ValueSlider("Contrasto", value: $settings.fluted.contrast, in: 0...1)
            ValueSlider("Luminosità", value: $settings.fluted.brightness, in: -0.5...0.5)
            Toggle("Bagliore", isOn: $settings.fluted.glow)
            resetButton
        }
    }

    /// Un cursore con le calamite: vicino a una tacca ci si attacca, con lo scatto del trackpad (carpa: «quando ruoti
    /// i fluted devi avere a 90 gradi una sorta di aiuto che te lo rifaccia mettere, un po' di magnetismo»).
    /// Presa di 4 gradi sulle tacche principali, 2 su quelle a metà.
    private func magnetic(_ value: Binding<Double>, stops: [Double], minorStops: [Double] = []) -> Binding<Double> {
        Binding(get: { value.wrappedValue }, set: { new in
            let stop = stops.first { abs($0 - new) <= 4 } ?? minorStops.first { abs($0 - new) <= 2 }
            guard let stop else { value.wrappedValue = new; return }
            guard value.wrappedValue != stop else { return }
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
            value.wrappedValue = stop
        })
    }

    /// Un taglio non può mangiare l'altro: insieme lasciano sempre almeno il 5% di vetro.
    private func cut(_ value: Binding<Double>, other: Double) -> Binding<Double> {
        Binding(get: { value.wrappedValue }, set: { value.wrappedValue = min($0, max(0, 0.95 - other)) })
    }

    /// «Valori di serie» e, sotto, la tua regolazione salvata: Salva se non ce n'è una, se c'è Usa e Sovrascrivi.
    @ViewBuilder private var resetButton: some View {
        HStack {
            Spacer()
            Button("Valori di serie") { settings.resetStyle() }
        }
        LabeledContent("La tua regolazione") {
            HStack(spacing: 8) {
                if settings.hasSavedStyle {
                    Button("Usa") { settings.useSavedStyle() }
                    Button("Sovrascrivi") { settings.saveStyle() }
                } else {
                    Button("Salva") { settings.saveStyle() }
                }
            }
            // Uguali a quella salvata: niente da usare né da sovrascrivere.
            .disabled(settings.matchesSavedStyle)
        }
    }

    // MARK: - Anteprima

    private var screenPreview: some View {
        let size = Self.screen.size
        return ZStack {
            Color.black
            if let back = preview.back {
                Image(decorative: back, scale: Self.screen.scale).resizable().interpolation(.high)
            }
            if let front = preview.front {
                Image(decorative: front, scale: Self.screen.scale).resizable().interpolation(.high)
                    .opacity(preview.opacity)
            }
        }
        .aspectRatio(size.width / size.height, contentMode: .fit)
        .background(GeometryReader { geo in
            Color.clear
                .onAppear { shownWidth = geo.size.width }
                .onChange(of: geo.size.width) { _, width in shownWidth = width }
        })
        .overlay(alignment: .top) {
            // La tacca, per dare la misura (12,6% della larghezza come sul MacBook Air).
            GeometryReader { geo in
                UnevenRoundedRectangle(bottomLeadingRadius: 5, bottomTrailingRadius: 5)
                    .fill(.black)
                    .frame(width: geo.size.width * 0.126, height: geo.size.width * 0.0225)
                    .frame(maxWidth: .infinity)
            }
        }
        .overlay {
            // La zona senza effetto, da spostare e ridimensionare con il puntatore.
            if settings.clear.enabled, settings.style != .none {
                ClearAreaEditor(area: $settings.clear)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            // Il pezzo a grandezza vera si toglie mentre c'è la zona da muovere: starebbe sotto il puntatore.
            if detail.front != nil, !(settings.clear.enabled && settings.style != .none) {
                // Raggio 10 dentro un angolo da 18 a 8 punti dal bordo: angoli concentrici.
                ZStack {
                    if let back = detail.back { Image(decorative: back, scale: Self.screen.scale) }
                    if let front = detail.front { Image(decorative: front, scale: Self.screen.scale).opacity(detail.opacity) }
                }
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.white.opacity(0.35), lineWidth: 1))
                .shadow(color: .black.opacity(0.35), radius: 8, y: 3)
                .padding(8)
            }
        }
        .overlay {
            if dropping {
                ZStack {
                    Color.black.opacity(0.55)
                    Text("Lascia qui l'immagine").font(.headline).foregroundStyle(.white)
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .onDrop(of: [.fileURL], isTargeted: $dropping) { providers in
            guard let provider = providers.first else { return false }
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                Task { @MainActor in WallpaperSettings.shared.useImage(at: url) }
            }
            return true
        }
    }

    private struct DrawRequest: Equatable { let draw: WallpaperDraw; let width: CGFloat }

    /// Chiede un disegno: se uno è in corso, ne segue uno solo con l'ultimo stato (l'anteprima segue il cursore a ogni
    /// passo senza accodare disegni vecchi).
    private func requestDraw() {
        guard !drawing else { pendingDraw = true; return }
        drawing = true
        Task { @MainActor in
            await redraw()
            drawing = false
            if pendingDraw {
                pendingDraw = false
                requestDraw()
            }
        }
    }

    /// Ridisegna anteprima e pezzo fuori dal thread principale. Quando cambia tutto il disegno (stile, tavolozza,
    /// griglia, colore, immagine, alla prima apparizione) c'è la dissolvenza; i cursori ridisegnano sul posto.
    private func redraw() async {
        guard shownWidth > 0, let source = await settings.source() else { return }
        let (full, scale) = Self.screen
        let draw = settings.draw
        // L'anteprima è lo schermo intero rimpicciolito: celle, canne, sfocature e alone in proporzione.
        let width = (shownWidth * scale).rounded()
        let k = width / full.width
        let canvas = CGSize(width: width, height: (full.height * k).rounded())
        // Il pezzo alla misura vera, dal centro dello schermo.
        let piece = CGRect(x: ((full.width - 128 * scale) / 2).rounded(), y: ((full.height - 84 * scale) / 2).rounded(),
                           width: 128 * scale, height: 84 * scale)
        let images = await Task.detached(priority: .userInitiated) { () -> (CGImage?, CGImage?) in
            (WallpaperRenderer.render(source, draw, canvas: canvas, scale: scale, shrink: k),
             WallpaperRenderer.render(source, draw, canvas: full, region: piece, scale: scale))
        }.value
        let whole = drawn.map { draw.isWholeChange(from: $0) } ?? true
        drawn = draw
        if whole {
            var instant = Transaction()
            instant.disablesAnimations = true
            withTransaction(instant) {
                preview = Crossfade(back: preview.front, front: images.0, opacity: 0)
                detail = Crossfade(back: detail.front, front: images.1, opacity: 0)
            }
            // Un fotogramma con il nuovo trasparente, poi sale.
            try? await Task.sleep(for: .milliseconds(20))
            withAnimation(.easeInOut(duration: 0.3)) {
                preview.opacity = 1
                detail.opacity = 1
            }
        } else {
            preview.front = images.0
            detail.front = images.1
        }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            MainActor.assumeIsolated { WallpaperSettings.shared.useImage(at: url) }
        }
    }
}

/// Un cursore con accanto il suo numero da 1 a 100, che si può anche scrivere (carpa, 20 novembre 2026: «tutte le
/// impostazioni oltre allo slider abbiano un numero da 1 a 100 che si possa anche scrivere»). La Rotazione mostra i
/// gradi (da −90 a 90, 0 al centro: da 1 a 100 il centro sarebbe 51). `sliderValue` è il binding del cursore (per
/// esempio con le calamite); il numero scritto va dritto al valore, senza calamite.
struct ValueSlider: View {
    let title: LocalizedStringKey
    @Binding var value: Double
    var sliderValue: Binding<Double>?
    let range: ClosedRange<Double>
    var degrees = false

    init(_ title: LocalizedStringKey, value: Binding<Double>, in range: ClosedRange<Double>,
         slider: Binding<Double>? = nil, degrees: Bool = false) {
        self.title = title
        _value = value
        self.range = range
        self.sliderValue = slider
        self.degrees = degrees
    }

    var body: some View {
        LabeledContent {
            HStack(spacing: 10) {
                Slider(value: sliderValue ?? $value, in: range).labelsHidden()
                NumberField(value: $value, range: range, degrees: degrees)
            }
        } label: {
            Text(title)
        }
    }
}

/// Il numero di un cursore. Si applica mentre scrivi (lo sfondo segue subito); Invio conferma, mette il numero in
/// ordine ed esce dal campo. Se il cursore si muove mentre il campo è attivo ma non stai scrivendo, il numero lo segue.
struct NumberField: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    var degrees = false
    @State private var text = ""
    /// Il testo l'hai cambiato tu (e non ancora confermato): solo allora si applica.
    @State private var edited = false
    @FocusState private var focused: Bool

    private var shown: String {
        guard value.isFinite else { return degrees ? "0" : "1" }
        if degrees { return String(Int(value.rounded())) }
        let span = range.upperBound - range.lowerBound
        guard span > 0 else { return "1" }
        return String(Int((1 + (min(max(value, range.lowerBound), range.upperBound) - range.lowerBound) / span * 99).rounded()))
    }

    /// Il valore del cursore per un numero scritto, o nil se non è un numero.
    private func parsed(_ text: String) -> Double? {
        let cleaned = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
            .replacingOccurrences(of: "°", with: "")
        guard let number = Double(cleaned), number.isFinite else { return nil }
        if degrees { return min(max(number, range.lowerBound), range.upperBound) }
        let n = min(max(number, 1), 100)
        return range.lowerBound + (n - 1) / 99 * (range.upperBound - range.lowerBound)
    }

    var body: some View {
        TextField("", text: $text)
            .textFieldStyle(.roundedBorder)
            .multilineTextAlignment(.trailing)
            .monospacedDigit()
            .frame(width: 46)
            .focused($focused)
            .onAppear { text = shown }
            .onChange(of: text) { _, new in
                guard focused, new != shown else { return }
                edited = true
                if let v = parsed(new), v != value { value = v }
            }
            .onChange(of: value) { if !edited { text = shown } }
            .onSubmit { finish(); focused = false }
            .onChange(of: focused) { _, now in if !now { finish() } }
    }

    private func finish() {
        if edited, let v = parsed(text), v != value { value = v }
        edited = false
        text = shown
    }
}

/// Il rettangolo della zona senza effetto sull'anteprima: si trascina dal centro e si ridimensiona dagli angoli. Le
/// misure sono in frazioni dell'anteprima, quindi dello schermo; ogni passo ridisegna lo sfondo dal vivo.
struct ClearAreaEditor: View {
    @Binding var area: ClearArea
    /// Dove e da che rettangolo è partito il trascinamento: un gesto nuovo (anche dopo uno interrotto, senza fine)
    /// riparte da dove si trova il rettangolo adesso.
    @State private var origin: (at: CGPoint, area: ClearArea)?

    private func from(_ g: DragGesture.Value) -> ClearArea {
        if let origin, origin.at == g.startLocation { return origin.area }
        origin = (g.startLocation, area)
        return area
    }

    var body: some View {
        GeometryReader { geo in
            let W = max(geo.size.width, 1), H = max(geo.size.height, 1)
            let a = area.clamped
            let rect = CGRect(x: a.x * W, y: a.y * H, width: a.width * W, height: a.height * H)
            // Lo stesso smusso del disegno, in proporzione all'anteprima (a 0 gli angoli sono vivi).
            let radius = a.cornerRadius(width: rect.width, height: rect.height, side: min(W, H))
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: radius, style: .circular)
                    .fill(.white.opacity(0.08))
                    .overlay(RoundedRectangle(cornerRadius: radius, style: .circular)
                        .strokeBorder(.white.opacity(0.9), style: StrokeStyle(lineWidth: 1.5, dash: [5, 4])))
                    .frame(width: rect.width, height: rect.height)
                    .contentShape(Rectangle())
                    .offset(x: rect.minX, y: rect.minY)
                    .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("zona"))
                        .onChanged { g in
                            let s = from(g)
                            var n = s
                            n.x = s.x + Double(g.translation.width / W)
                            n.y = s.y + Double(g.translation.height / H)
                            area = n.clamped
                        }
                        .onEnded { _ in origin = nil })
                ForEach(0..<4, id: \.self) { corner in
                    let left = corner % 2 == 0, top = corner < 2
                    Circle()
                        .fill(.white)
                        .overlay(Circle().strokeBorder(.black.opacity(0.25), lineWidth: 0.5))
                        .frame(width: 11, height: 11)
                        .shadow(color: .black.opacity(0.3), radius: 2, y: 1)
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                        .offset(x: (left ? rect.minX : rect.maxX) - 12, y: (top ? rect.minY : rect.maxY) - 12)
                        .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("zona"))
                            .onChanged { g in
                                let s = from(g)
                                area = Self.resize(s, dx: Double(g.translation.width / W), dy: Double(g.translation.height / H),
                                                   left: left, top: top)
                            }
                            .onEnded { _ in origin = nil })
                }
            }
            .coordinateSpace(name: "zona")
        }
    }

    /// Sposta l'angolo scelto e tiene fermo quello opposto; mai più piccolo del 3% né fuori dallo schermo.
    static func resize(_ s: ClearArea, dx: Double, dy: Double, left: Bool, top: Bool) -> ClearArea {
        var n = s
        let minimum = 0.03
        if left {
            let x = min(max(s.x + dx, 0), s.x + s.width - minimum)
            n.width = s.x + s.width - x; n.x = x
        } else {
            n.width = min(max(s.width + dx, minimum), 1 - s.x)
        }
        if top {
            let y = min(max(s.y + dy, 0), s.y + s.height - minimum)
            n.height = s.y + s.height - y; n.y = y
        } else {
            n.height = min(max(s.height + dy, minimum), 1 - s.y)
        }
        return n.clamped
    }
}

extension AllSpaces.Problem {
    /// La frase nelle Impostazioni quando lo sfondo non arriva negli altri spazi.
    var message: String {
        switch self {
        case .noRegistry, .unknownStructure:
            String(localized: "Questa versione di macOS tiene gli sfondi in un modo che Charland non conosce: lo sfondo resta sulla scrivania dove sei.")
        case .unreadable:
            String(localized: "Charland non riesce a leggere gli sfondi di sistema di questo Mac: lo sfondo resta sulla scrivania dove sei.")
        case .writeFailed:
            String(localized: "Charland non è riuscito a scrivere gli sfondi di sistema di questo Mac: lo sfondo resta sulla scrivania dove sei.")
        case .agentIgnored:
            String(localized: "macOS non ha tenuto lo sfondo sulle altre scrivanie: resta sulla scrivania dove sei.")
        }
    }
}
