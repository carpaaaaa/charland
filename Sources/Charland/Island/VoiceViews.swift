import SwiftUI
import CharlandCore

/// A sinistra della fotocamera: il tempo che passa. Il segno della voce sta solo a destra, dove si muove (carpa: «a
/// sinistra non voglio il simbolo, c'è già a destra che si muove»).
struct DictationLeading: View {
    let model: IslandModel

    var body: some View {
        Text(Self.clock(model.voice.elapsed))
            .font(.system(size: 12, weight: .semibold, design: .rounded)).monospacedDigit()
            .foregroundStyle(.white.opacity(0.72))
            .contentTransition(.numericText())
            .animation(.smooth(duration: 0.3), value: model.voice.elapsed)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, 4)
    }

    static func clock(_ t: TimeInterval) -> String {
        let s = Int(t)
        return "\(s / 60):" + String(format: "%02d", s % 60)
    }
}

/// La voce a destra della fotocamera, come quando si detta in Charcal (`VoiceMorph` di Charcal, portato qui; carpa:
/// «quella linea che si muove come eq non mi piace per niente, voglio qualcosa più simile a quando si detta con
/// Charcal»). Un punto si divide in tre, i tre punti diventano barre che seguono la voce, ognuna col suo respiro, mai
/// tutte insieme; finito di parlare tornano punti e si aprono in un anello di otto con la grandezza che gira, mentre
/// Charland prepara il testo. Tutto a molla verso dove deve stare: passare da una forma all'altra è sempre continuo.
struct VoiceLine: View {
    let model: IslandModel
    @State private var motion = DictationMotion()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let thinking = model.voice.processing
        let level = model.voiceLevel
        TimelineView(.animation(minimumInterval: 1.0 / 120.0)) { timeline in
            Canvas { context, size in
                motion.advance(to: timeline.date, thinking: thinking, level: level, reduceMotion: reduceMotion)
                motion.draw(in: &context, size: size)
            }
        }
        .foregroundStyle(.white)
        .accessibilityHidden(true)
    }
}

/// Le misure della forma, in frazioni dell'altezza, le stesse di Charcal.
private enum DictationShape {
    static let dot: Double = 0.1
    static let gap: Double = 0.14
    static let barWidth: Double = 0.105
    static let barGap: Double = 0.16
    static let barTall: Double = 0.36
    static let ringRadius: Double = 0.25
    static let ringSmall: Double = 0.03
    static let ringLarge: Double = 0.145
    static let motes = 8
}

/// Una misura che segue il suo bersaglio a molla.
private struct Sprung {
    var value = 0.0
    var speed = 0.0

    mutating func step(to target: Double, stiffness: Double, damping: Double, dt: Double) {
        speed += (stiffness * (target - value) - damping * speed) * dt
        value += speed * dt
    }
}

private struct Mote {
    var x = Sprung(), y = Sprung(), width = Sprung(), height = Sprung()
}

final class DictationMotion {
    private var motes = Array(repeating: Mote(), count: DictationShape.motes)
    private var voice = Sprung()
    private var lastDate: Date?
    private var thinking = false
    private var phaseDate = Date()
    private var started: Date?
    private var clock = 0.0

    func advance(to date: Date, thinking new: Bool, level: Double, reduceMotion: Bool) {
        if started == nil { started = date }
        if new != thinking {
            thinking = new
            phaseDate = date
        }
        let elapsed = lastDate.map { date.timeIntervalSince($0) } ?? 0
        lastDate = date
        let dt = min(max(elapsed, 0), 1.0 / 30)
        clock += dt
        let since = date.timeIntervalSince(thinking ? phaseDate : (started ?? date))
        // Due passi per fotogramma: a 120 Hz come a 60 la molla si comporta uguale.
        for _ in 0..<2 { step(dt: dt / 2, since: since, level: level, soft: reduceMotion) }
    }

    private func step(dt: Double, since: Double, level: Double, soft: Bool) {
        voice.step(to: min(1, max(0, level * 1.5)), stiffness: 420, damping: 34, dt: dt)
        let move = soft ? (k: 300.0, c: 36.0) : (k: 240.0, c: 22.0)
        let size = soft ? (k: 340.0, c: 38.0) : (k: 300.0, c: 26.0)
        for index in motes.indices {
            let target = self.target(index, since: since, soft: soft)
            motes[index].x.step(to: target.x, stiffness: move.k, damping: move.c, dt: dt)
            motes[index].y.step(to: target.y, stiffness: move.k, damping: move.c, dt: dt)
            motes[index].width.step(to: target.width, stiffness: size.k, damping: size.c, dt: dt)
            motes[index].height.step(to: target.height, stiffness: size.k, damping: size.c, dt: dt)
        }
    }

    private func target(_ index: Int, since: Double, soft: Bool) -> (x: Double, y: Double, width: Double, height: Double) {
        let dot = DictationShape.dot
        if !thinking {
            guard index < 3 else { return (0, 0, 0, 0) }
            // Prima un punto solo, che si divide dopo un istante, come in Charcal.
            guard since > 0.1 else { return index == 0 ? (0, 0, dot, dot) : (0, 0, 0, 0) }
            let side = Double(index) - 1
            let loud = voice.value
            // Ogni barra ha il suo respiro: si inseguono e non salgono mai tutte insieme.
            let pulse = soft ? 0.8 : 0.62 + 0.38 * sin(clock * [7.1, 9.3, 8.2][index] + Double(index) * 1.7)
            let tall = dot + (DictationShape.barTall - dot) * loud * pulse
            let width = dot + (DictationShape.barWidth - dot) * min(1, loud * 3)
            let spread = DictationShape.gap + (DictationShape.barGap - DictationShape.gap) * min(1, loud * 3)
            return (side * spread, 0, width, tall)
        }
        // I tre punti si allargano e restano interi finché l'anello non li prende; gli altri nascono uno alla volta.
        // Il gruppo gira piano, e la grandezza gira più in fretta.
        let reveal = index < 3 ? 1 : min(1, max(0, (since - 0.1 - Double(index) * 0.05) / 0.24))
        let share = Double(index) / Double(DictationShape.motes) * 2 * .pi
        let spin = soft ? 0 : clock * 0.8
        let angle = share + spin - .pi / 2
        let wave = 0.5 + 0.5 * cos(share - (soft ? 0 : clock * 2.4))
        let ring = DictationShape.ringSmall + (DictationShape.ringLarge - DictationShape.ringSmall) * pow(wave, 1.5)
        let hold = index < 3 ? dot * max(0, 1 - since / 0.5) : 0
        let side = max(ring * reveal, hold)
        let radius = DictationShape.ringRadius * (0.35 + 0.65 * reveal)
        return (cos(angle) * radius, sin(angle) * radius, side, side)
    }

    func draw(in context: inout GraphicsContext, size: CGSize) {
        // la misura di riferimento è l'altezza della fascia, con un tetto: le barre restano proporzionate al segno a sinistra
        let unit = min(size.height, 34)
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let ink = GraphicsContext.Shading.foreground
        for mote in motes {
            let width = max(0, mote.width.value) * unit, height = max(0, mote.height.value) * unit
            guard width > 0.25, height > 0.25 else { continue }
            let rect = CGRect(x: center.x + mote.x.value * unit - width / 2, y: center.y + mote.y.value * unit - height / 2,
                              width: width, height: height)
            context.fill(Path(roundedRect: rect, cornerRadius: min(width, height) / 2, style: .continuous), with: ink)
        }
    }
}

/// Le parole mentre parli. Corte stanno al centro; lunghe restano ancorate a destra (si legge l'ultima cosa detta) e
/// sfumano a sinistra, senza puntini. Ogni nuova parola entra scorrendo, mai a scatti. Al rilascio restano lì e un
/// riflesso le attraversa mentre Charland prepara il testo.
struct LiveTextView: View {
    let model: IslandModel
    private static let font = NSFont.systemFont(ofSize: 14, weight: .medium)

    var body: some View {
        GeometryReader { geo in
            let text = model.voice.liveText
            let width = ceil((text as NSString).size(withAttributes: [.font: Self.font]).width)
            let overflow = width > geo.size.width
            // Il testo nuovo prende subito il posto del vecchio (niente dissolvenza fra due righe): scorre solo la
            // posizione, così le parole già dette restano ferme e si spostano insieme.
            let x = overflow ? geo.size.width - width : (geo.size.width - width) / 2
            let voice = model.voice
            Text(text)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.white.opacity(voice.processing ? 0.82 : 1))
                .lineLimit(1)
                .fixedSize()
                .contentTransition(.identity)
                .overlay {
                    if voice.processing, !voice.condensing {
                        Sheen().mask(Text(text).font(.system(size: 14, weight: .medium)).fixedSize())
                    }
                }
                .offset(x: x)
                .frame(width: geo.size.width, height: geo.size.height, alignment: .leading)
                .mask {
                    // la parte che esce a sinistra sfuma, invece dei tre puntini
                    LinearGradient(stops: [.init(color: overflow ? .clear : .black, location: 0),
                                           .init(color: .black, location: overflow ? 0.12 : 0)],
                                   startPoint: .leading, endPoint: .trailing)
                }
                // al via le parole si condensano nella goccia: si stringono verso il centro e sfumano
                .scaleEffect(voice.condensing ? 0.86 : 1, anchor: .bottom)
                .opacity(voice.condensing ? 0 : 1)
                .blur(radius: voice.condensing ? 3 : 0)
                .animation(.smooth(duration: 0.26), value: x)
                .animation(.easeOut(duration: 0.25), value: voice.processing)
                .animation(.easeIn(duration: 0.14), value: voice.condensing)
        }
        .clipped()
    }
}

/// Un riflesso che passa sulle parole, da sinistra a destra, mentre il testo si prepara.
struct Sheen: View {
    @State private var phase: CGFloat = -0.35

    var body: some View {
        GeometryReader { geo in
            LinearGradient(colors: [.clear, .white.opacity(0.95), .clear], startPoint: .leading, endPoint: .trailing)
                .frame(width: max(40, geo.size.width * 0.28))
                .offset(x: geo.size.width * phase)
                .blendMode(.plusLighter)
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: false)) { phase = 1.1 }
        }
    }
}
