import AppKit
import SwiftUI

/// La barra in una finestra sola: un vetro solo con la forma della goccia (`SearchShape.outline`), il campo e l'elenco
/// alla loro misura vera ritagliati dalla forma mentre nasce, niente sopra il bordo del notch.
struct SearchBarView: View {
    let shape: SearchShape
    let model: SearchModel
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        let box = shape.outline.boundingRect
        ZStack(alignment: .topLeading) {
            // Il vetro in un riquadro grande quanto la forma, non quanto la finestra (vedi `ClipboardMenuView`).
            if box.width > 0, box.height > 0 {
                CharlandGlassFill(shape: OutlineShape(path: shape.outline.offsetBy(dx: -box.minX, dy: -box.minY)),
                                  rimStrength: 1 - shape.inkTop, veil: AnyShapeStyle(veil(in: box)))
                    .frame(width: box.width, height: box.height)
                    .offset(x: box.minX, y: box.minY)
            }
            ZStack(alignment: .topLeading) {
                // La riga sottile fra campo ed elenco, dalla parte dell'elenco.
                Rectangle()
                    .fill(.white.opacity(0.09))
                    .frame(width: max(0, shape.field.width - 2 * 18), height: 1)
                    .offset(x: shape.field.minX + 18, y: shape.field.maxY - 1)
                    .opacity(shape.listReveal)
                SearchFieldRow(model: model)
                    .frame(width: shape.field.width, height: shape.field.height)
                    .offset(x: shape.field.minX, y: shape.field.minY - CGFloat(1 - shape.reveal) * 6)
                    .opacity(shape.reveal)
                SearchListArea(model: model)
                    .frame(width: shape.list.width, height: shape.list.height, alignment: .top)
                    .offset(x: shape.list.minX, y: shape.list.minY)
                    .opacity(shape.listReveal * shape.reveal)
                    .allowsHitTesting(shape.listReveal > 0.5)
            }
            .frame(width: shape.size.width, height: shape.size.height, alignment: .topLeading)
            .clipShape(OutlineShape(path: shape.outline))
        }
        .frame(width: shape.size.width, height: shape.size.height, alignment: .topLeading)
        .shadow(color: .black.opacity(0.22), radius: 16, y: 6)
        // Niente sopra il bordo del notch: lì la goccia è ancora «dentro» di lui.
        .mask(alignment: .topLeading) {
            Rectangle()
                .frame(width: max(0, shape.visible.width), height: max(0, shape.visible.height))
                .offset(x: shape.visible.minX, y: shape.visible.minY)
        }
        // Riduci movimento: compare al suo posto, in dissolvenza, salendo di un niente.
        .opacity(shape.calm ? shape.calmPresence : 1)
        .offset(y: shape.calm ? -CGFloat(1 - shape.calmPresence) * 6 : 0)
        .environment(\.colorScheme, .dark)
    }

    /// Più scuro dei vassoi: il testo bianco si legge anche sopra una pagina bianca. Con Aumenta contrasto di più. Mentre
    /// nasce è nera come il notch, in alto più a lungo che in basso (`SearchShape.inkTop`, `inkBottom`).
    private func veil(in box: CGRect) -> LinearGradient {
        let base = contrast == .increased ? 0.74 : 0.56
        let top = base + (1 - base) * shape.inkTop
        let bottom = base + (1 - base) * shape.inkBottom
        return LinearGradient(colors: [.black.opacity(top), .black.opacity(bottom)], startPoint: .top, endPoint: .bottom)
    }
}

/// Il campo: la lente (la scintilla quando stai chiedendo), il testo, la x per svuotarlo.
struct SearchFieldRow: View {
    @Bindable var model: SearchModel
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: model.answer != nil ? "sparkle" : "magnifyingglass")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.white.opacity(0.6))
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 22)
            TextField("", text: $model.query, prompt: Text(placeholder).foregroundStyle(.white.opacity(0.38)))
                .textFieldStyle(.plain)
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(.white)
                .focused($focused)
                .accessibilityLabel(Text("Cerca o chiedi"))
            if !model.query.isEmpty {
                Button { model.query = ""; SearchBar.shared.focusField() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.42))
                }
                .buttonStyle(.plain)
                .transition(.opacity.combined(with: .scale(scale: 0.8)))
                .accessibilityLabel(Text("Svuota"))
            }
        }
        .padding(.leading, 18)
        .padding(.trailing, 16)
        .animation(.spring(response: 0.26, dampingFraction: 0.86), value: model.query.isEmpty)
        // Il cursore lo mette anche `SearchBar.focusField` col campo di AppKit: alla seconda apertura SwiftUI da solo non
        // lo rimetteva e le lettere andavano perse (lo stesso degli appunti).
        .onChange(of: model.focus) { focused = true }
        .onAppear { focused = true }
    }

    private var placeholder: String {
        model.answer != nil ? String(localized: "Fai un'altra domanda") : String(localized: "Cerca o chiedi")
    }
}

/// L'elenco, o la risposta di «Chiedi».
struct SearchListArea: View {
    let model: SearchModel

    var body: some View {
        if model.answer != nil {
            SearchAnswerView(model: model)
                .padding(.horizontal, SearchMetrics.inset)
                .padding(.vertical, SearchMetrics.listPadding)
                .transition(.opacity)
        } else {
            SearchList(model: model)
        }
    }
}

/// Le righe, dal campo in giù: il risultato migliore subito sotto il campo.
struct SearchList: View {
    let model: SearchModel

    var body: some View {
        let rows = Array(model.results.prefix(model.maxRows).enumerated())
        VStack(spacing: 0) {
            ForEach(rows, id: \.element.id) { index, result in
                SearchRow(result: result, index: index, model: model)
            }
        }
        .padding(.vertical, SearchMetrics.listPadding)
        .padding(.horizontal, SearchMetrics.inset)
        // Le righe cambiano di colpo a ogni lettera, come in Spotlight: con la dissolvenza la riga vecchia e quella nuova
        // restavano una sopra l'altra per qualche fotogramma («Photos» sotto «Safari»). L'altezza la anima la forma.
        .transaction { $0.animation = nil }
    }
}

/// Una riga: il segno (l'icona dell'app o del file, un simbolo per calcolo, web e Chiedi), titolo e sotto la cartella o
/// il tipo, a destra cosa fa Invio. Niente pillola sotto la riga scelta, come negli appunti (carpa, 18 novembre 2026:
/// «più clean»): si accende lei, le altre restano attenuate.
struct SearchRow: View {
    let result: SearchResult
    let index: Int
    let model: SearchModel

    var body: some View {
        let selected = model.selected == result.id
        Button {
            SearchBar.shared.choose(result.id, flags: NSEvent.modifierFlags)
        } label: {
            HStack(spacing: 12) {
                SearchGlyph(result: result)
                    .frame(width: 30, height: 30)
                    .opacity(selected ? 1 : 0.72)
                VStack(alignment: .leading, spacing: 1) {
                    title
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white.opacity(selected ? 1 : 0.62))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if !subtitle.isEmpty {
                        Text(verbatim: subtitle)
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(.white.opacity(selected ? 0.5 : 0.34))
                            .lineLimit(1)
                            .truncationMode(.head)
                    }
                }
                .layoutPriority(1)
                Spacer(minLength: 10)
                trailing.fixedSize()
            }
            .padding(.horizontal, 10)
            .frame(height: SearchMetrics.row)
            .contentShape(RoundedRectangle(cornerRadius: SearchMetrics.rowRadius, style: .continuous))
            .animation(.easeOut(duration: 0.12), value: selected)
        }
        .buttonStyle(SearchRowPress())
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { SearchBar.shared.rowFrame(result.id, $0) }
        .onDisappear { SearchBar.shared.rowFrame(result.id, nil) }
        .accessibilityLabel(Text(verbatim: result.title))
        .accessibilityHint(Text(verbatim: result.label))
    }

    @ViewBuilder private var title: some View {
        switch result.kind {
        case .calculation:
            Text(verbatim: "= " + result.title).monospacedDigit()
        case .ask:
            Text(verbatim: result.title)
        default:
            Text(verbatim: result.title)
        }
    }

    private var subtitle: String {
        switch result.kind {
        case .iphoneApp:
            return model.command ? String(localized: "Apri Duplicazione iPhone") : result.subtitle
        case .ask:
            return model.option ? String(localized: "Chiedi a Siri") : String(localized: "Chiedi al modello di Apple")
        case .calculation:
            return model.copiedID == result.id ? String(localized: "Copiato") : result.subtitle
        default:
            return result.subtitle
        }
    }

    @ViewBuilder private var trailing: some View {
        let selected = model.selected == result.id
        HStack(spacing: 8) {
            if model.command, index < 9, model.answer == nil {
                // Tenendo ⌘ si vede quale numero sceglie la riga.
                Text(verbatim: "⌘\(index + 1)")
                    .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.7))
                    .padding(.horizontal, 5)
                    .frame(height: 17)
                    .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(.white.opacity(0.1)))
            } else if selected {
                Text(verbatim: hint)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.55))
            } else {
                Text(verbatim: result.label)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.3))
                    .lineLimit(1)
            }
        }
        .animation(.easeOut(duration: 0.12), value: model.command)
    }

    /// Cosa fa Invio su questa riga (con ⌘ o ⌥ tenuti, cosa fa con loro).
    private var hint: String {
        switch result.kind {
        case .app, .file, .folder:
            return model.command ? String(localized: "Mostra nel Finder ↩") : String(localized: "Apri ↩")
        case .iphoneApp, .action:
            return String(localized: "Apri ↩")
        case .calculation: return String(localized: "Copia ↩")
        case .link, .web: return String(localized: "Apri ↩")
        case .ask: return model.option ? String(localized: "Siri ↩") : String(localized: "Chiedi ↩")
        }
    }
}

/// Il segno di una riga.
struct SearchGlyph: View {
    let result: SearchResult

    var body: some View {
        switch result.kind {
        case .app, .file, .folder:
            icon(result.url?.path, fallback: result.kind == .folder ? "folder" : result.kind == .app ? "app" : "doc")
        case .iphoneApp:
            // L'icona dell'app com'è sull'iPhone, col segno dell'iPhone in un angolo (come nella ricerca di macOS).
            icon(result.url?.path, fallback: "iphone")
                .overlay(alignment: .bottomTrailing) {
                    Image(systemName: "iphone")
                        .font(.system(size: 7.5, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 13, height: 13)
                        .background(Circle().fill(Color.black.opacity(0.78)))
                        .overlay(Circle().strokeBorder(.white.opacity(0.35), lineWidth: 0.5))
                        .offset(x: 3, y: 3)
                }
        case .link:
            // L'icona del browser che aprirà la pagina.
            icon(SearchIcons.shared.browserPath, fallback: "safari")
        case .action:
            // L'app che si apre, o il browser che aprirà la pagina.
            if let url = result.url, url.isFileURL {
                icon(url.path, fallback: "app")
            } else {
                icon(result.value ?? SearchIcons.shared.browserPath, fallback: "safari")
            }
        case .calculation: symbol("equal")
        case .web: symbol("globe")
        case .ask: symbol("sparkle")
        }
    }

    /// L'icona già pronta; finché non lo è (si prepara in sottofondo) un simbolo al suo posto, mai un disegno che
    /// fermi la riga.
    @ViewBuilder private func icon(_ path: String?, fallback: String) -> some View {
        if let path, let image = SearchIcons.shared.cached(path) {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
        } else {
            symbol(fallback)
        }
    }

    private func symbol(_ name: String) -> some View {
        Image(systemName: name)
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(Glassy.ink(.white))
            .frame(width: 30, height: 30)
            .background(GlassPlate(shape: RoundedRectangle(cornerRadius: 9, style: .continuous)))
    }
}

/// Premuta, la riga cede appena, come le righe degli appunti.
struct SearchRowPress: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(.spring(response: 0.2, dampingFraction: 0.8), value: configuration.isPressed)
    }
}

/// La risposta: la domanda in alto, la risposta che arriva parola per parola, in fondo copia e cosa fanno i tasti.
struct SearchAnswerView: View {
    let model: SearchModel

    var body: some View {
        if let answer = model.answer {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "sparkle")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.5))
                    Text(verbatim: answer.question)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.5))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 8)
                    Text("Sul Mac")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(.white.opacity(0.3))
                }
                .frame(height: 16)
                ScrollView(.vertical) {
                    content(answer)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                            // Domanda, risposta, piede, spazi: l'altezza che servirebbe senza scorrere.
                            SearchBar.shared.answerMeasured(height + 16 + 10 + 22 + 10 + 2 * SearchMetrics.listPadding)
                        }
                }
                .scrollIndicators(.automatic)
                HStack(spacing: 14) {
                    if answer.done, !answer.text.isEmpty {
                        Button { SearchBar.shared.copyAnswer() } label: {
                            Label(model.copiedID == "answer" ? String(localized: "Copiato") : String(localized: "Copia"),
                                  systemImage: model.copiedID == "answer" ? "checkmark" : "doc.on.doc")
                                .font(.system(size: 11.5, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.7))
                        }
                        .buttonStyle(.plain)
                    }
                    Spacer()
                    Text("↩ domanda nuova   esc indietro")
                        .font(.system(size: 10.5, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.3))
                }
                .frame(height: 22)
            }
            .padding(.horizontal, 10)
        }
    }

    @ViewBuilder private func content(_ answer: SearchAnswer) -> some View {
        if answer.failed {
            Text("Il modello non ha risposto. Riprova con Invio, o chiedi a Siri con ⌥↩ dalla riga Chiedi.")
                .font(.system(size: 13.5, weight: .medium))
                .foregroundStyle(.white.opacity(0.62))
        } else if answer.text.isEmpty {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small).tint(.white)
                Text("Sto pensando…")
                    .font(.system(size: 13.5, weight: .medium))
                    .foregroundStyle(.white.opacity(0.5))
            }
        } else {
            Text(Self.markdown(answer.text))
                .font(.system(size: 13.5, weight: .regular))
                .foregroundStyle(.white.opacity(0.92))
                .lineSpacing(3)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Grassetto, corsivo, codice e link dal Markdown semplice del modello; gli a capo restano.
    static func markdown(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
    }
}
