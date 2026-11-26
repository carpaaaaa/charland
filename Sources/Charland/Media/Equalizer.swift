import SwiftUI
import AppKit

/// Il piccolo equalizzatore a destra della fotocamera mentre la musica suona (carpa, 18 novembre 2026: «a destra un
/// piccolo equalizzatore che va a tempo con la musica»).
///
/// Cinque barrette che battono come una canzone: le due basse sui colpi di cassa, le medie sul rullante, l'ultima sui
/// piatti. Charland non ascolta l'audio del Mac (servirebbe il permesso di registrare l'audio di sistema, con la sua
/// richiesta): il tempo non è quello vero della canzone, è un tempo plausibile scelto per ogni brano, e la fase segue il
/// punto del brano, così in pausa le barre si fermano e alla ripresa ripartono da dov'erano.
///
/// Le muove Core Animation fuori dall'app, come il disco e l'arco degli agenti: mentre suona l'app non si sveglia mai.
struct EqualizerBars: NSViewRepresentable {
    let playing: Bool
    /// Il colore della copertina (o bianco).
    let color: Color
    /// Con «Tutto vetro» le barre sono di vetro: bianche, più tenui in basso.
    var glass = false
    /// Un numero che cambia da brano a brano: sceglie il tempo e il disegno dei colpi.
    var seed: Int = 0
    /// Il punto del brano adesso, in secondi.
    var position: TimeInterval = 0

    static let bars = 5
    static let barWidth: CGFloat = 2.5
    static let gap: CGFloat = 2
    static let size = CGSize(width: CGFloat(bars) * barWidth + CGFloat(bars - 1) * gap, height: 15)

    func makeNSView(context: Context) -> EqualizerView { EqualizerView() }

    func updateNSView(_ view: EqualizerView, context: Context) {
        view.update(playing: playing, color: NSColor(color), glass: glass, seed: seed, position: position)
    }
}

final class EqualizerView: NSView {
    private var bars: [CAGradientLayer] = []
    private var playing = false
    private var seed = 0
    private var position: TimeInterval = 0
    private var tint: NSColor = .white
    private var glass = false
    /// Quando valeva `position`.
    private var positionAt = CACurrentMediaTime()

    /// Quanto è alta una barra ferma: un puntino.
    private static let rest: CGFloat = 3

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        for _ in 0..<EqualizerBars.bars {
            let bar = CAGradientLayer()
            bar.cornerRadius = EqualizerBars.barWidth / 2
            bar.masksToBounds = true
            bar.startPoint = CGPoint(x: 0.5, y: 1)
            bar.endPoint = CGPoint(x: 0.5, y: 0)
            layer?.addSublayer(bar)
            bars.append(bar)
        }
        paint()
    }

    required init?(coder: NSCoder) { fatalError("non usato") }

    /// Solo da guardare: i clic passano al pulsante sotto.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override var intrinsicContentSize: NSSize { EqualizerBars.size }

    func update(playing: Bool, color: NSColor, glass: Bool, seed: Int, position: TimeInterval) {
        if color != tint || glass != self.glass {
            tint = color
            self.glass = glass
            paint()
        }
        self.position = position
        positionAt = CACurrentMediaTime()
        guard playing != self.playing || seed != self.seed else { return }
        self.playing = playing
        self.seed = seed
        animate(restart: true)
    }

    private func paint() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let top = tint.usingColorSpace(.sRGB) ?? tint
        for bar in bars {
            bar.colors = glass ? [NSColor.white.cgColor, NSColor.white.withAlphaComponent(0.55).cgColor] : [top.cgColor, top.cgColor]
        }
        CATransaction.commit()
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let total = EqualizerBars.size.width
        let left = (bounds.width - total) / 2
        for (index, bar) in bars.enumerated() {
            bar.bounds = CGRect(x: 0, y: 0, width: EqualizerBars.barWidth, height: Self.rest)
            bar.position = CGPoint(x: left + CGFloat(index) * (EqualizerBars.barWidth + EqualizerBars.gap) + EqualizerBars.barWidth / 2,
                                   y: bounds.midY)
            bar.contentsScale = window?.backingScaleFactor ?? 2
        }
        CATransaction.commit()
        animate(restart: false)
    }

    /// Core Animation toglie le animazioni quando il livello esce dall'albero: rientrando, le barre ripartono.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        animate(restart: false)
    }

    private func animate(restart: Bool) {
        guard window != nil, bounds.height > 0 else { return }
        if !playing {
            // In pausa le barre scendono a puntini, morbide, e restano lì.
            for bar in bars where bar.animation(forKey: "batte") != nil {
                let from = bar.presentation()?.bounds.size.height ?? Self.rest
                bar.removeAnimation(forKey: "batte")
                let settle = CABasicAnimation(keyPath: "bounds.size.height")
                settle.fromValue = from
                settle.toValue = Self.rest
                settle.duration = 0.35
                settle.timingFunction = CAMediaTimingFunction(name: .easeOut)
                bar.add(settle, forKey: "posa")
            }
            return
        }
        guard restart || bars.contains(where: { $0.animation(forKey: "batte") == nil }) else { return }
        let tall = min(EqualizerBars.size.height, bounds.height)
        let pattern = EqualizerPattern(seed: seed)
        let now = position + (CACurrentMediaTime() - positionAt)
        for (index, bar) in bars.enumerated() {
            bar.removeAnimation(forKey: "posa")
            let beat = CAKeyframeAnimation(keyPath: "bounds.size.height")
            beat.values = pattern.levels(bar: index).map { Self.rest + (tall - Self.rest) * CGFloat($0) }
            beat.calculationMode = .linear
            beat.duration = pattern.duration
            beat.repeatCount = .infinity
            beat.isRemovedOnCompletion = false
            // La fase segue il punto del brano: la stessa battuta cade sempre nello stesso punto della canzone.
            beat.timeOffset = now.truncatingRemainder(dividingBy: pattern.duration)
            bar.add(beat, forKey: "batte")
        }
    }
}

/// Il disegno dei colpi di un brano: due battute da quattro, a un tempo fra 96 e 128 battiti al minuto, uguale ogni
/// volta per lo stesso brano.
struct EqualizerPattern {
    let seed: Int
    /// Battiti al minuto.
    var tempo: Double { 96 + Double(abs(seed) % 9) * 4 }
    var beat: Double { 60 / tempo }
    /// Due battute.
    var duration: Double { beat * 8 }
    static let samplesPerBeat = 12

    /// Un numero fra 0 e 1, sempre lo stesso per lo stesso brano, la stessa barra e lo stesso colpo.
    private func noise(_ bar: Int, _ step: Int) -> Double {
        var x = UInt64(truncatingIfNeeded: seed) &* 0x9E37_79B9_7F4A_7C15 &+ UInt64(bar) &* 0xBF58_476D_1CE4_E5B9 &+ UInt64(step) &* 0x94D0_49BB_1331_11EB
        x ^= x >> 31
        x = x &* 0xD6E8_FEB8_6659_FD93
        x ^= x >> 32
        return Double(x % 10_000) / 10_000
    }

    /// I colpi di una barra: quando cadono (in battiti) e quanto sono forti.
    private func hits(bar: Int) -> [(at: Double, strength: Double)] {
        var out: [(Double, Double)] = []
        for eighth in 0..<16 {
            let at = Double(eighth) / 2
            let onBeat = eighth % 2 == 0
            let quarter = eighth / 2
            let chance = noise(bar, eighth)
            let strength: Double
            switch bar {
            case 0:   // cassa: sui tempi, più forte sul primo
                strength = onBeat ? (quarter % 4 == 0 ? 1 : 0.78 + 0.16 * chance) : (chance > 0.84 ? 0.5 : 0)
            case 1:   // basso: segue la cassa, con qualche levare
                strength = onBeat ? 0.62 + 0.3 * chance : (chance > 0.5 ? 0.42 + 0.2 * chance : 0)
            case 2:   // rullante: sul secondo e sul quarto
                strength = onBeat && quarter % 2 == 1 ? 0.92 + 0.08 * chance : (chance > 0.72 ? 0.36 : 0.14)
            case 3:   // voce e accordi: più liberi
                strength = 0.34 + 0.56 * chance
            default:  // piatti: ogni ottavo, leggeri
                strength = onBeat ? 0.4 + 0.24 * chance : 0.52 + 0.3 * chance
            }
            if strength > 0.05 { out.append((at, strength)) }
        }
        return out
    }

    /// Le altezze di una barra lungo le due battute, fra 0 e 1: ogni colpo sale in un attimo e poi cala, sopra un
    /// fondo che non scende mai a zero (mentre suona, le barre non sono mai puntini fermi).
    func levels(bar: Int) -> [Double] {
        let hits = hits(bar: bar)
        // In battiti: i bassi calano piano, i piatti in fretta.
        let decay = [0.62, 0.56, 0.44, 0.52, 0.3][min(bar, 4)]
        let floor = [0.2, 0.24, 0.16, 0.26, 0.18][min(bar, 4)]
        let count = 8 * Self.samplesPerBeat
        var values: [Double] = []
        values.reserveCapacity(count + 1)
        for sample in 0...count {
            let t = Double(sample % count) / Double(Self.samplesPerBeat)
            var level = 0.0
            for hit in hits {
                // Anche i colpi della battuta prima, che stanno ancora calando quando il giro ricomincia.
                for shift in [0.0, -8.0] {
                    let since = t - (hit.at + shift)
                    guard since >= 0 else { continue }
                    let attack = min(1, since / 0.06)
                    level = max(level, hit.strength * attack * exp(-since / decay))
                }
            }
            values.append(min(1, floor + (1 - floor) * level))
        }
        return values
    }
}
