import SwiftUI
import AppKit
import CharlandCore
import CharlandKit

/// Un'attività arrivata dall'API, in uno dei suoi quattro aspetti.
/// È fatta solo di posti fissi: testo, simboli e numeri. Niente HTML.
struct APISlotView: View {
    let content: APIContent
    let slot: ContentSlot
    let act: (String) -> Void
    @Environment(\.islandInteractive) private var interactive

    var body: some View {
        if content.isAgent, content.template != .approval || slot != .expanded {
            agent
        } else {
            standard
        }
    }

    /// Un agente: la mascotte a sinistra della fotocamera, il tempo del turno a destra.
    @ViewBuilder private var agent: some View {
        let working = content.badge == .working
        switch slot {
        case .leading:
            let mascot = AgentMascot(palette: content.client == "codex" ? .codex : .claude,
                                     shape: content.client == "codex" ? .round : .square, working: working)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            // Aperta su una domanda o su una richiesta di permesso la mascotte si preme: porta davanti l'app dove
            // l'agente sta chiedendo, per leggerla meglio (carpa, 18 novembre 2026). Chiusa, il clic resta all'isola.
            if interactive {
                Button { act("jump") } label: { mascot.contentShape(Rectangle()) }
                    .buttonStyle(TilePress())
            } else {
                mascot
            }
        case .minimal where content.badge == .waiting || content.template == .approval:
            // Nella goccia la parola non ci sta: c'è la mascotte di chi chiede, ferma, come nell'attività degli agenti.
            GeometryReader { geo in
                let pixel = AgentMascot.pixelFitting(circle: min(geo.size.width, geo.size.height))
                AgentMascot(palette: content.client == "codex" ? .codex : .claude,
                            shape: content.client == "codex" ? .round : .square, working: false, pixel: pixel)
                    .offset(x: -pixel)
                    .frame(width: geo.size.width, height: geo.size.height)
            }
        case .trailing, .minimal:
            Group {
                if content.badge == .done {
                    Image(systemName: content.failed ? "xmark" : "checkmark")
                        .font(.system(size: 12, weight: .bold))
                        .inked(content.failed ? .red : .green)
                        .transition(.push(from: .bottom))
                } else if content.badge == .waiting || content.template == .approval {
                    NeedsYouLabel().transition(.push(from: .bottom))
                } else if let start = content.startedAt {
                    TurnTimer(start: start).transition(.push(from: .bottom))
                } else {
                    AgentBadge(info: AgentInfo(project: content.title, agent: content.client, phase: .working))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: slot == .minimal ? .center : .trailing)
            .animation(NeedsYou.spring, value: NeedsYou.key(waiting: content.badge == .waiting || content.template == .approval,
                                                            done: content.badge == .done))
        case .expanded:
            // Aperta: il tempo grande e, sotto, i progetti su cui sta lavorando.
            VStack(spacing: 4) {
                if working, let start = content.startedAt {
                    TurnTimer(start: start, size: 32)
                } else {
                    Text(content.status).font(.system(size: 17, weight: .semibold)).foregroundStyle(.white)
                }
                Text(content.title).font(.system(size: 14, weight: .medium)).foregroundStyle(.white.opacity(0.65))
                    .lineLimit(1).truncationMode(.middle)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // Niente da premere: il clic passa all'isola (porta alla casa).
            .allowsHitTesting(false)
        default:
            EmptyView()
        }
    }

    @ViewBuilder private var standard: some View {
        switch slot {
        case .leading:
            if let custom = content.slots["leading"] {
                SlotPiece(slot: custom, tint: content.tint)
            } else if content.lowPower {
                LowPowerGlyph(level: content.progress)
            } else if content.focus {
                FocusGlyph(on: content.focusOn, symbol: content.symbol == "moon.fill" ? nil : content.symbol, tint: content.focusTint)
            } else {
                Image(systemName: content.symbol).font(.system(size: 13, weight: .semibold)).inked(content.tint)
            }
        case .trailing:
            if content.lowPower, let text = content.slots["trailing"]?.text {
                LowPowerLabel(text: text)
            } else if content.focus, let text = content.slots["trailing"]?.text {
                FocusLabel(text: text, on: content.focusOn, tint: content.focusTint)
            } else if let custom = content.slots["trailing"] {
                SlotPiece(slot: custom, tint: content.tint)
            } else {
                trailing
            }
        case .minimal:
            if let custom = content.slots["minimal"] {
                SlotPiece(slot: custom, tint: content.tint).padding(4)
            } else if content.template == .progress {
                ProgressRing(fraction: content.progress, tint: content.tint).padding(5)
            } else {
                Image(systemName: content.symbol).font(.system(size: 12, weight: .semibold)).inked(content.tint)
            }
        case .expanded:
            expanded
        default:
            EmptyView()
        }
    }

    @ViewBuilder private var trailing: some View {
        switch content.template {
        case .progress:
            ProgressRing(fraction: content.progress, tint: content.tint).padding(7)
        case .countdown:
            if let end = content.endsAt {
                LiveCountdown(end: end)
                    .font(.system(size: 13, weight: .semibold, design: .rounded)).monospacedDigit()
                    .inked(content.tint)
            }
        case .approval:
            AgentBadge(info: AgentInfo(project: content.title, agent: content.client, phase: content.phase))
        case .status, .custom:
            if content.recording, let start = content.startedAt {
                TurnTimer(start: start)
            } else if content.failed {
                Image(systemName: "xmark").font(.system(size: 12, weight: .bold)).inked(.red)
            } else if let badge = content.badge {
                AgentBadge(info: AgentInfo(project: content.title, agent: content.client, phase: badge))
            }
        }
    }

    @ViewBuilder private var expanded: some View {
        switch content.template {
        case .approval where content.question:
            // Una domanda dell'agente: il testo e, sotto, le scelte, due per riga. Un clic risponde.
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Text(content.title).font(.system(size: 15, weight: .semibold))
                    Spacer()
                    Text(content.subtitle.isEmpty ? content.client : content.subtitle)
                        .font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                    // «L'ho vista»: la richiesta di un agente si toglie dall'isola senza rispondere, e resta nella sua chat.
                    if content.isAgent { DismissButton { act("dismiss") } }
                }
                Text(content.command).font(.system(size: 15, weight: .medium)).lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Spacer(minLength: 0)
                VStack(spacing: 8) {
                    ForEach(Array(stride(from: 0, to: content.actions.count, by: 2)), id: \.self) { start in
                        HStack(spacing: 8) {
                            ForEach(content.actions[start..<min(start + 2, content.actions.count)], id: \.id) { action in
                                Button { act(action.id) } label: {
                                    // «Rispondi» (porta alla sessione) è l'azione di una domanda letta dal registro.
                                    KeyHint(keys: "", label: action.title,
                                            prominent: action.id == "jump" && content.actions.first?.id == "jump")
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
            }
            .foregroundStyle(.white)
        case .approval:
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Text(content.title).font(.system(size: 15, weight: .semibold))
                    Spacer()
                    Text(content.subtitle.isEmpty ? content.client : content.subtitle)
                        .font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                    // «L'ho vista»: la richiesta di un agente si toglie dall'isola senza rispondere, e resta nella sua chat.
                    if content.isAgent { DismissButton { act("dismiss") } }
                }
                if !content.detail.isEmpty || content.risk != nil {
                    // Cosa fa, in parole semplici, e quanto rischia.
                    (Text(content.detail.isEmpty ? "" : content.detail + " ")
                        + Text(Self.riskLabel(content.risk)).foregroundStyle(Glassy.on ? Color.white.opacity(0.7) : Self.riskColor(content.risk)))
                        .font(.system(size: 15, weight: .medium)).lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                Text(content.command).font(.system(size: 12, weight: .medium, design: content.detail.isEmpty && content.client == "charland" ? .default : .monospaced))
                    .foregroundStyle(content.detail.isEmpty ? .primary : .secondary).lineLimit(content.detail.isEmpty ? 2 : 1)
                    .truncationMode(.middle).frame(maxWidth: .infinity, alignment: .leading)
                Spacer(minLength: 0)
                HStack(spacing: 8) {
                    ForEach(Array(content.actions.enumerated()), id: \.offset) { index, action in
                        Button { act(action.id) } label: {
                            KeyHint(keys: Self.keys(for: action.id), label: action.title, prominent: index == 0)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .foregroundStyle(.white)
        case .countdown:
            VStack(spacing: 6) {
                // Le scritte lasciano passare il clic (porta alla casa); solo i pulsanti lo prendono.
                Group {
                    Text(content.title).font(.system(size: 14, weight: .medium)).foregroundStyle(.white.opacity(0.65))
                    if let end = content.endsAt {
                        LiveCountdown(end: end)
                            .font(.system(size: 40, weight: .semibold, design: .rounded)).monospacedDigit()
                            .inked(content.tint)
                    }
                }
                .allowsHitTesting(false)
                if !content.actions.isEmpty {
                    HStack(spacing: 8) {
                        ForEach(Array(content.actions.enumerated()), id: \.offset) { index, action in
                            Button { act(action.id) } label: {
                                KeyHint(keys: "", label: action.title, prominent: index == 0)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        default:
            VStack(spacing: 9) {
                Text(content.slots["center"]?.text ?? content.title)
                    .font(.system(size: 16, weight: .semibold)).foregroundStyle(.white).lineLimit(1)
                    .allowsHitTesting(false)
                if content.template == .progress {
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(.white.opacity(0.2))
                            Capsule().fill(Glassy.ink(content.tint)).frame(width: max(5, geo.size.width * min(1, max(0, content.progress))))
                        }
                    }
                    .frame(height: 5)
                }
                if content.recording, let start = content.startedAt {
                    TurnTimer(start: start, size: 30).foregroundStyle(.white).allowsHitTesting(false)
                }
                let line = content.slots["bottom"]?.text ?? (content.status.isEmpty ? content.subtitle : content.status)
                if !line.isEmpty {
                    Text(line).font(.system(size: 13, weight: .medium)).foregroundStyle(.white.opacity(0.6)).lineLimit(1)
                        .allowsHitTesting(false)
                }
                if !content.actions.isEmpty {
                    HStack(spacing: 8) {
                        ForEach(Array(content.actions.enumerated()), id: \.offset) { index, action in
                            Button { act(action.id) } label: {
                                KeyHint(keys: "", label: action.title, prominent: index == 0)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .padding(.top, 4)
        }
    }

    static func riskLabel(_ risk: CommandRisk.Level?) -> String {
        switch risk {
        case .low?: String(localized: "Rischio basso.")
        case .medium?: String(localized: "Rischio medio.")
        case .high?: String(localized: "Rischio alto.")
        case nil: ""
        }
    }

    static func riskColor(_ risk: CommandRisk.Level?) -> Color {
        switch risk {
        case .low?: .green
        case .medium?: .yellow
        case .high?: .red
        case nil: .white
        }
    }

    static func keys(for action: String) -> String {
        switch action {
        case "allow": "⌘↩"
        case "deny": "⌘⌫"
        case "always": "⌘⌥↩"
        default: ""
        }
    }
}

/// La «x» di una richiesta di un agente: la toglie dall'isola senza rispondere (carpa, 19 novembre 2026: «l'ho vista,
/// la lascio in chat su Claude o un'altra AI, ma non voglio rispondere da lì»). L'agente continua ad aspettare nella
/// sua finestra.
struct DismissButton: View {
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 8.5, weight: .bold))
                .foregroundStyle(.white.opacity(hovering ? 0.95 : 0.6))
                .frame(width: 20, height: 20)
                .background(Circle().fill(.white.opacity(hovering ? 0.24 : 0.14)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .islandHover($hovering)
        .help(String(localized: "Togli dall'isola"))
    }
}

/// Un posto riempito a piacere: un simbolo, un testo corto o un anello di avanzamento.
struct SlotPiece: View {
    let slot: ActivityMessage.Slot
    let tint: Color

    var body: some View {
        if let progress = slot.progress {
            ProgressRing(fraction: progress, tint: tint).padding(6)
        } else if let symbol = slot.symbol {
            Image(systemName: symbol).font(.system(size: 13, weight: .semibold)).inked(tint)
        } else if let text = slot.text {
            Text(text).font(.system(size: 13, weight: .semibold, design: .rounded)).monospacedDigit()
                .inked(tint).lineLimit(1).minimumScaleFactor(0.7)
        }
    }
}


/// La batteria gialla del Risparmio energetico, disegnata: entra vuota, si riempie con una molla fino al livello vero
/// e un riflesso di luce la attraversa una volta. Nessun battito che si ripete.
struct LowPowerGlyph: View {
    let level: Double
    @State private var fill: Double = 0
    @State private var sheen: CGFloat = -0.6
    @State private var lit = false

    var body: some View {
        HStack(spacing: 1.2) {
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 3.4, style: .continuous)
                    .strokeBorder(Glassy.flat(.yellow).opacity(lit ? 0.75 : 0.4), lineWidth: 1.3)
                RoundedRectangle(cornerRadius: 1.9, style: .continuous)
                    .fill(Glassy.ink(Color.yellow))
                    .frame(width: max(1.5, 20 * fill))
                    .padding(2.3)
                    .overlay(alignment: .leading) {
                        // il riflesso: una banda chiara che passa da sinistra a destra
                        GeometryReader { geo in
                            LinearGradient(colors: [.clear, .white.opacity(0.85), .clear], startPoint: .leading, endPoint: .trailing)
                                .frame(width: 7)
                                .offset(x: geo.size.width * sheen)
                                .blendMode(.plusLighter)
                        }
                        .mask(RoundedRectangle(cornerRadius: 1.9, style: .continuous).padding(2.3)
                            .frame(width: max(1.5, 20 * fill) + 4.6, alignment: .leading))
                    }
            }
            .frame(width: 26.5, height: 13.5)
            Capsule().fill(Glassy.flat(.yellow).opacity(lit ? 0.75 : 0.4)).frame(width: 2, height: 5)
        }
        .scaleEffect(lit ? 1 : 0.85)
        .task {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) { lit = true }
            try? await Task.sleep(for: .milliseconds(180))
            withAnimation(.spring(response: 0.75, dampingFraction: 0.82)) { fill = max(0.12, min(1, level)) }
            try? await Task.sleep(for: .milliseconds(520))
            withAnimation(.easeInOut(duration: 0.65)) { sheen = 1.3 }
        }
    }
}

/// «Needs you» al posto della mano gialla, quando un agente chiede un permesso o fa una domanda (carpa, 19 novembre 2026:
/// scelta fra quattro strade su una tavola, dopo «la manina nel notch è orribile»; la stessa parola è nel sito). Prende il
/// posto del tempo: il tempo esce in alto, la parola entra dal basso (`push`) mentre l'ala destra dell'isola si allarga
/// quanto la parola (`NeedsYou.trailingWidth`). Di vetro come l'inchiostro dell'isola, senza il giallo di prima.
struct NeedsYouLabel: View {
    var body: some View {
        Text(NeedsYou.text)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(Glassy.ink)
            .lineLimit(1)
            .fixedSize()
    }
}

enum NeedsYou {
    /// In inglese «Needs you». La chiave non è «Ti aspetta», che è già il testo grande dell'isola aperta («Waiting for you»).
    static var text: String {
        String(localized: "Tocca a te", comment: "Nell'isola chiusa, al posto del tempo, quando un agente chiede un permesso o fa una domanda")
    }
    /// Lo stesso carattere della vista, per misurarla.
    static var font: NSFont { .systemFont(ofSize: 13, weight: .semibold) }
    /// L'ala destra di un'attività che chiede: larga quanto la parola, più due punti d'aria.
    static var trailingWidth: Double { ceil((text as NSString).size(withAttributes: [.font: font]).width) + 2 }
    /// La molla del cambio fra tempo, parola e spunta.
    static let spring = Animation.spring(response: 0.42, dampingFraction: 0.86)
    static func key(waiting: Bool, done: Bool) -> Int { done ? 2 : waiting ? 1 : 0 }
}

/// La parola del Risparmio energetico: entra scivolando e mettendosi a fuoco, un attimo dopo la batteria.
struct LowPowerLabel: View {
    let text: String
    @State private var shown = false

    var body: some View {
        Text(text)
            .font(.system(size: 13, weight: .semibold, design: .rounded))
            .inked(.yellow)
            .lineLimit(1)
            .fixedSize()
            .opacity(shown ? 1 : 0)
            .blur(radius: shown ? 0 : 5)
            .offset(x: shown ? 0 : -10)
            .frame(maxWidth: .infinity, alignment: .trailing)
            .task {
                try? await Task.sleep(for: .milliseconds(240))
                withAnimation(.spring(response: 0.45, dampingFraction: 0.85)) { shown = true }
            }
    }
}
