import AppKit
import SwiftUI
import CharlandCore

/// Quello che la scena del timer mostra in questo momento, in coordinate della finestra (y verso il basso).
@MainActor
@Observable
final class TimerDropModel {
    var size: CGSize = .zero
    /// Il filo con la goccia e il pallino da cui pende: una forma sola, di vetro.
    var liquid = Path()
    var liquidOpacity: Double = 1
    /// Il pallino che resta al posto dell'icona mentre la goccia vola nell'isola, e che torna farfalla.
    var pallino = Path()
    var pallinoOpacity: Double = 0
    /// La farfalla fatta di gocce che si fonde nel pallino (e ne rinasce): nel colore della barra dei menu, identica
    /// all'icona quando è aperta, così lo scambio con l'icona vera non si vede.
    var butterfly = Path()
    var butterflyOpacity: Double = 0
    var glyph: Color = .white
    /// Da dove esce il filo e dove finisce la goccia: il filo di luce corre fra i due.
    var from: CGPoint = .zero
    var to: CGPoint = CGPoint(x: 0, y: 1)
    var label = ""
    var detail = ""
    var cancel = true
    var tooltipOrigin: CGPoint = .zero
    var tooltipOpacity: Double = 1
}

/// La goccia del timer. Tirando giù, la farfalla nella barra dei menu si fonde in un pallino (le quattro ali scorrono
/// verso il centro e si uniscono come gocce), e dal pallino pende il filo con la goccia che segue il puntatore
/// (carpa: «voglio un'animazione fluida dove la farfalla diventa il pallino»). Il vetro è quello di Charland
/// (`CharlandGlass`), lo stesso degli slider e dell'isola. Accanto, la nuvoletta nera con la durata e l'ora in cui suonerà.
struct TimerDropView: View {
    let model: TimerDropModel
    let appearance: Appearance
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        let liquid = OutlineShape(path: model.liquid)
        let pallino = OutlineShape(path: model.pallino)
        let glassOn = appearance.look == .blackGlass && !reduceTransparency && appearance.glass > 0.01
        ZStack(alignment: .topLeading) {
            ZStack(alignment: .topLeading) {
                // Il vetro c'è sempre, anche a forma vuota: crearlo al primo gesto costava fotogrammi.
                if glassOn {
                    // Come il notch (carpa: «sopra nero e pian piano gradient col vetro»): nero pieno al pallino e
                    // dove il filo esce dalla barra, poi la stessa curva del velo dell'isola fino al vetro di Charland
                    // nella goccia. Il filo di luce non c'è sul nero e sale verso la goccia.
                    CharlandGlassFill(shape: liquid, veil: AnyShapeStyle(veil), rim: AnyShapeStyle(rim))
                        .opacity(model.liquidOpacity)
                    // Il pallino sta in alto, sul nero.
                    pallino.fill(.black)
                        .opacity(model.pallinoOpacity)
                } else {
                    liquid.fill(.black).opacity(model.liquidOpacity)
                    pallino.fill(.black).opacity(model.pallinoOpacity)
                }
            }
            .shadow(color: .black.opacity(glassOn ? CharlandGlass.shadowOpacity : 0), radius: CharlandGlass.shadowRadius,
                    y: CharlandGlass.shadowY)
            OutlineShape(path: model.butterfly)
                .fill(model.glyph)
                .opacity(model.butterflyOpacity)
            tooltip
                .offset(x: model.tooltipOrigin.x, y: model.tooltipOrigin.y)
                .opacity(model.tooltipOpacity)
        }
        .frame(width: model.size.width, height: model.size.height, alignment: .topLeading)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func unit(_ p: CGPoint) -> UnitPoint {
        UnitPoint(x: model.size.width > 0 ? p.x / model.size.width : 0,
                  y: model.size.height > 0 ? p.y / model.size.height : 0)
    }

    /// Quanto vetro si apre in fondo: la regolazione «Vetro», fino al vetro di Charland. Con Contrasto aumentato resta
    /// più scuro, come nell'isola.
    private var release: Double {
        (contrast == .increased ? min(appearance.glass, 0.45) : appearance.glass) * (1 - CharlandGlass.veil)
    }

    /// Il velo lungo il filo: nero pieno al pallino e all'uscita dalla barra, poi la curva dell'isola (`VeilCurve`) fino
    /// al vetro in fondo alla goccia. Come il notch, che resta nero sulla fotocamera e apre il vetro più in basso.
    private var veil: LinearGradient {
        let curve = VeilCurve(knee: 0.86, kneeValue: IslandBackdrop.legibleShare)
        let solid = 0.12
        var stops: [Gradient.Stop] = [.init(color: .black, location: 0), .init(color: .black, location: solid)]
        let steps = 32
        for i in 1...steps {
            let t = Double(i) / Double(steps)
            stops.append(.init(color: .black.opacity(1 - release * curve.value(t)), location: solid + (1 - solid) * t))
        }
        return LinearGradient(stops: stops, startPoint: unit(model.from), endPoint: unit(model.to))
    }

    /// Il filo di luce come nel notch: niente sul nero, il più chiaro dove comincia il vetro, più tenue in fondo.
    private var rim: LinearGradient {
        let k = appearance.rim
        return LinearGradient(stops: [
            .init(color: .white.opacity(0), location: 0),
            .init(color: .white.opacity(0), location: 0.45),
            .init(color: .white.opacity(CharlandGlass.rimTop * k), location: 0.75),
            .init(color: .white.opacity(CharlandGlass.rimBottom * k + 0.1 * k), location: 1),
        ], startPoint: unit(model.from), endPoint: unit(model.to))
    }

    private var tooltip: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(model.cancel ? String(localized: "Annulla") : model.label)
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .monospacedDigit()
            if !model.cancel {
                Text(model.detail)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.62))
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 13)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.black))
        .fixedSize()
    }
}

/// La farfalla come campo di distanza: le quattro gocce del segno «Rugiada», ognuna una capsula irregolare (un cerchio
/// grande che si assottiglia fino alla punta verso il corpo), distanze vere. `morph` le porta verso il centro, le
/// arrotonda e le unisce con un minimo morbido fino al pallino: a 0 è il segno dell'icona, a 1 un cerchio solo.
struct ButterflyField: ScalarField {
    /// Il centro dell'icona nella finestra (y verso l'alto) e quanti punti vale un'unità del segno (quadrato di 1024).
    let anchor: CGPoint
    let scale: Double
    let morph: Double
    /// Il raggio del pallino, in punti.
    let pallino: Double

    /// Centro e raggio della parte tonda, e punta, in unità del segno (y verso il basso): da `CharlandMark.svgPath`.
    private static let wings: [(cx: Double, cy: Double, r: Double, tx: Double, ty: Double)] = [
        (298, 401, 128, 486, 489), (726, 401, 128, 538, 489),
        (388, 669, 82, 485, 537), (636, 669, 82, 539, 537),
    ]
    private static let tip = 7.0

    func value(x: Double, y: Double) -> Double {
        let ux = (x - Double(anchor.x)) / scale + 512
        let uy = 512 - (y - Double(anchor.y)) / scale
        let e = morph * morph * (3 - 2 * morph)
        let rp = pallino / scale
        // I ponti liquidi fra le ali crescono a metà strada e spariscono alla fine: il pallino non si gonfia. Più
        // larghi (600) la farfalla quasi fusa era più grande del pallino, e nello scambio col vetro la misura saltava.
        let k = 300 * morph * (1 - morph)
        var d = Double.infinity
        for w in Self.wings {
            let cx = w.cx + (512 - w.cx) * e, cy = w.cy + (512 - w.cy) * e
            let tx = w.tx + (512 - w.tx) * e, ty = w.ty + (512 - w.ty) * e
            let r1 = w.r + (rp - w.r) * e, r2 = Self.tip + (rp - Self.tip) * e
            let wing = Self.unevenCapsule(ux - cx, uy - cy, tx - cx, ty - cy, r1, r2)
            if k > 0.0001, d.isFinite {
                let h = max(k - abs(d - wing), 0) / k
                d = min(d, wing) - h * h * k * 0.25
            } else {
                d = min(d, wing)
            }
        }
        return d * scale
    }

    /// Le capsule irregolari sono distanze vere e il minimo morbido quadratico non cresce mai più in fretta di una
    /// distanza (la sua pendenza è una media pesata di quelle dei due lati): nessuno scarto da dichiarare.
    var distortion: Double? { 0 }

    /// Distanza da una capsula irregolare: cerchio di raggio `r1` nell'origine e di raggio `r2` in (ax, ay).
    static func unevenCapsule(_ px: Double, _ py: Double, _ ax: Double, _ ay: Double, _ r1: Double, _ r2: Double) -> Double {
        let h = (ax * ax + ay * ay).squareRoot()
        guard h > 0.0001 else { return (px * px + py * py).squareRoot() - max(r1, r2) }
        // nel riferimento della capsula: asse lungo y
        let vx = ax / h, vy = ay / h
        let lx = abs(px * vy - py * vx), ly = px * vx + py * vy
        let b = (r1 - r2) / h
        let a = max(0, 1 - b * b).squareRoot()
        let k = -b * lx + a * ly
        if k < 0 { return (lx * lx + ly * ly).squareRoot() - r1 }
        if k > a * h { return (lx * lx + (ly - h) * (ly - h)).squareRoot() - r2 }
        return lx * a + ly * b - r1
    }
}

/// La fisica della goccia, come in Filo: la goccia insegue il puntatore con una molla, si allunga nella direzione del
/// moto, e il filo si fonde in lei con raccordi tondi. Tirando giù, l'icona viene sostituita da una farfalla di gocce
/// identica che si fonde nel pallino; dal pallino nasce la goccia. Al rilascio: se si annulla, la goccia risale nel
/// pallino e il pallino si riapre nella farfalla, fino all'icona vera; se il timer parte, la goccia si stacca e vola
/// dentro l'isola, e intanto il pallino torna farfalla. Tutto in coordinate di AppKit (y verso l'alto); il modello
/// riceve le forme già girate per SwiftUI.
@MainActor
final class TimerDropScene {
    private enum Mode { case idle, dragging, retracting, flying }

    let model = TimerDropModel()
    private var mode: Mode = .idle
    private var size: CGSize = .zero
    private var anchor: CGPoint = .zero
    private var iconHeight: CGFloat = 15
    private var tail: CGPoint = .zero
    private var tailVelocity = CGVector.zero
    private var tailRadius: CGFloat = 5
    private var ball: CGPoint = .zero
    private var velocity = CGVector.zero
    private var radius: CGFloat = 5
    private var flightTarget: CGPoint = .zero
    private var tooltip: CGPoint = .zero
    private var tooltipVelocity = CGVector.zero
    private var tooltipSize = CGSize(width: 90, height: 52)
    private var lastTick = CACurrentMediaTime()
    private var endStart = CACurrentMediaTime()
    /// Da farfalla (0) a pallino (1), a molla: le ali scorrono, si arrotondano e si uniscono.
    private var morph = Animated(0, spring: Spring(response: 0.3, damping: 0.86), restDistance: 0.002, restSpeed: 0.02)
    /// L'icona vera è di nuovo nella barra (la farfalla di gocce non si disegna più).
    private var iconBack = true
    private var arrived = false
    private var landed = false
    private let tracer = ContourTracer(cell: 0.25)
    private var screen: NSScreen?
    private var watchdog: Timer?
    private var lastStepWall: CFTimeInterval = 0
    /// Un passo a ogni fotogramma vero dello schermo. Con un timer a 120 Hz su uno schermo a 60 arrivavano due passi
    /// per fotogramma, fuori tempo col disegno: la goccia avanzava a scatti.
    private lazy var clock = FrameClock { [weak self] link in self?.step(now: link.targetTimestamp) }
    private var onIcon: (() -> Void)?
    private var onLanded: (() -> Void)?
    private var onEnd: (() -> Void)?

    var target: CGPoint = .zero
    var isBusy: Bool { mode != .idle }

    static let ballRadius: CGFloat = 13
    /// Per le prove: `CHARLAND_LENTO=8` rallenta la goccia otto volte, così la fusione si fotografa.
    private static let slowMotion = max(1, Double(ProcessInfo.processInfo.environment["CHARLAND_LENTO"] ?? "") ?? 1)
    private static let trace = ProcessInfo.processInfo.environment["CHARLAND_SLIDER"] != nil
    /// Il pallino da cui pende il filo, quello in cui si fonde la farfalla.
    static let pallinoRadius: CGFloat = 5

    /// `anchor`: il centro dell'icona nella finestra; `iconHeight`: quanto è alta l'icona; `glyph`: il suo colore nella
    /// barra (bianco sulla barra scura, nero su quella chiara).
    func begin(anchor: CGPoint, size: CGSize, iconHeight: CGFloat = 15, glyph: Color = .white, screen: NSScreen? = nil) {
        // Un gesto nuovo mentre la goccia di prima vola ancora: quel timer parte adesso e l'icona torna, invece di
        // perdersi (prima `begin` cancellava le chiamate in sospeso e il timer scelto spariva).
        flushPending()
        self.screen = screen
        self.size = size
        self.anchor = anchor
        self.iconHeight = iconHeight
        tail = anchor
        tailVelocity = .zero
        tailRadius = Self.pallinoRadius
        ball = anchor
        target = anchor
        velocity = .zero
        radius = Self.pallinoRadius
        tooltipVelocity = .zero
        morph.snap(to: 0)
        morph.target = 1
        iconBack = false
        arrived = false
        landed = false
        onIcon = nil
        onLanded = nil
        onEnd = nil
        model.size = size
        model.glyph = glyph
        model.tooltipOpacity = 1
        model.cancel = true
        model.pallino = Path()
        model.pallinoOpacity = 0
        mode = .dragging
        // La nuvoletta parte già accanto alla goccia: nata sull'icona, copriva la farfalla che si fonde.
        tooltip = tooltipGoal()
        lastTick = CACurrentMediaTime()
        layout()
        startPhysics()
    }

    func setInfo(minutes: Int?, ends: Date?) {
        guard let minutes, let ends else {
            model.cancel = true
            tooltipSize = CGSize(width: 86, height: 36)
            return
        }
        model.cancel = false
        model.label = TimerGesture.label(minutes: minutes)
        model.detail = String(localized: "suona alle \(ends.formatted(date: .omitted, time: .shortened))")
        let w1 = (model.label as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 15, weight: .semibold)]).width
        let w2 = (model.detail as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 12, weight: .medium)]).width
        tooltipSize = CGSize(width: ceil(max(w1, w2)) + 30, height: 52)
    }

    /// Rilascio senza timer: la goccia risale nel pallino e il pallino torna farfalla. `icon` quando l'icona vera può
    /// riapparire (la farfalla di gocce è identica), `completion` alla fine.
    func retract(icon: @escaping () -> Void, completion: @escaping () -> Void) {
        guard mode == .dragging else { stop(); icon(); completion(); return }
        mode = .retracting
        endStart = CACurrentMediaTime()
        onIcon = icon
        onEnd = completion
    }

    /// Rilascio col timer: la goccia si stacca dal pallino e vola fino al punto dell'isola, e intanto il pallino torna
    /// farfalla. `icon` quando l'icona vera può riapparire, `landed` quando la goccia è entrata nell'isola.
    func fly(to point: CGPoint, icon: @escaping () -> Void, landed: @escaping () -> Void, completion: @escaping () -> Void) {
        guard mode == .dragging else { stop(); icon(); landed(); completion(); return }
        mode = .flying
        flightTarget = point
        endStart = CACurrentMediaTime()
        morph.target = 0
        // Il filo si spezza al pallino: la sua coda parte sottile. Larga quanto il pallino, senza il suo cerchio
        // (che resta al posto dell'icona) faceva un piccolo imbuto.
        tailRadius = min(tailRadius, 1.5)
        onIcon = icon
        onLanded = landed
        onEnd = completion
    }

    /// Le chiamate rimaste in sospeso (una goccia in volo, l'icona spenta) si fanno adesso.
    private func flushPending() {
        if mode == .flying, !landed, let done = onLanded {
            onLanded = nil
            landed = true
            done()
        }
        if !iconBack, let icon = onIcon {
            onIcon = nil
            iconBack = true
            icon()
        }
    }

    func stop() {
        clock.stop()
        watchdog?.invalidate()
        watchdog = nil
        mode = .idle
        model.liquid = Path()
        model.pallino = Path()
        model.butterfly = Path()
        model.butterflyOpacity = 0
        model.tooltipOpacity = 0
        if let icon = onIcon {
            onIcon = nil
            iconBack = true
            icon()
        }
    }

    /// Il gesto sta per cominciare (pressione sull'icona): l'orologio dello schermo parte subito. Un CADisplayLink nuovo
    /// batte la prima volta dopo 30-40 ms, e partito al trascinamento quel primo passo lungo faceva saltare avanti la
    /// farfalla che si fonde (carpa, 20 novembre 2026: «quando la prendo e tiro giù, in quell'istante lagga»).
    func prepare(on screen: NSScreen?) {
        guard !clock.isRunning else { return }
        self.screen = screen
        lastTick = CACurrentMediaTime()
        clock.start(on: screen ?? NSScreen.screens.first)
        // Tutte le forme del gesto già disegnate, invisibili, mentre il tasto è premuto e niente si muove: la prima
        // volta che SwiftUI disegna il vetro e la nuvoletta costa un fotogramma lungo, meglio pagarlo qui.
        let c = CGPoint(x: model.size.width / 2, y: model.size.height / 2)
        let dot = Path(ellipseIn: CGRect(x: c.x - 3, y: c.y - 3, width: 6, height: 6))
        model.liquid = dot
        model.pallino = dot
        model.butterfly = dot
        model.liquidOpacity = Self.ready
        model.pallinoOpacity = Self.ready
        model.butterflyOpacity = Self.ready
        model.tooltipOpacity = Self.ready
    }

    /// Era solo un clic: l'orologio preparato si ferma, se non c'è una goccia ancora in volo.
    func unprepare() {
        guard mode == .idle else { return }
        clock.stop()
        model.liquid = Path()
        model.pallino = Path()
        model.butterfly = Path()
        model.liquidOpacity = 0
        model.pallinoOpacity = 0
        model.butterflyOpacity = 0
        model.tooltipOpacity = 0
    }

    /// Invisibile ma disegnato: a opacità zero SwiftUI non disegna, e la prima volta poi costa un fotogramma.
    private static let ready = 0.003

    private func startPhysics() {
        if !clock.isRunning { clock.start(on: screen ?? NSScreen.screens.first) }
        lastStepWall = CACurrentMediaTime()
        // Se l'orologio dello schermo non batte (schermo addormentato, scollegato), il gesto finisce da solo:
        // l'icona non resta mai spenta e il timer lasciato parte lo stesso.
        watchdog?.invalidate()
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.mode != .idle, CACurrentMediaTime() - self.lastStepWall > 1.5 else { return }
                self.flushPending()
                self.finish()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        watchdog = timer
    }

    private func step(now: CFTimeInterval) {
        lastStepWall = CACurrentMediaTime()
        if Self.trace, now - lastTick > 0.025, mode != .idle {
            print(String(format: "[filo] fotogramma lungo %.0f ms, %@, fusione %.2f", (now - lastTick) * 1000, "\(mode)", morph.value)); fflush(stdout)
        }
        let started = CACurrentMediaTime()
        defer {
            if Self.trace { print(String(format: "[filo] passo %.2f ms %@ %.2f", (CACurrentMediaTime() - started) * 1000, "\(mode)", morph.value)); fflush(stdout) }
        }
        let dt = CGFloat(min(max(0, now - lastTick), 1.0 / 30.0) / Self.slowMotion)
        lastTick = now
        switch mode {
        case .idle:
            return
        case .dragging:
            integrate(&ball, &velocity, toward: target, k: 420, c: 24, dt: dt)
            integrate(&tooltip, &tooltipVelocity, toward: tooltipGoal(), k: 300, c: 28, dt: dt)
            // La goccia nasce piccola dal pallino e cresce mentre scende.
            radius += (Self.ballRadius - radius) * min(1, 7 * dt)
        case .retracting:
            integrate(&ball, &velocity, toward: anchor, k: 520, c: 26, dt: dt)
            radius += (Self.pallinoRadius - radius) * min(1, 10 * dt)
            model.tooltipOpacity = max(0, model.tooltipOpacity - Double(5 * dt))
            // Rientrata nel pallino: il pallino si riapre nella farfalla.
            if !arrived, hypot(ball.x - anchor.x, ball.y - anchor.y) < 3 || now - endStart > 0.9 {
                arrived = true
                morph.target = 0
            }
            if arrived, morph.value < 0.02 {
                showIcon()
                finish()
                return
            }
        case .flying:
            if !landed {
                // la goccia corre verso l'isola e il filo si stacca dal pallino e la segue, come risucchiato
                integrate(&ball, &velocity, toward: flightTarget, k: 260, c: 25, dt: dt)
                integrate(&tail, &tailVelocity, toward: ball, k: 900, c: 50, dt: dt)
                tailRadius += (0 - tailRadius) * min(1, 10 * dt)
                let left = hypot(ball.x - flightTarget.x, ball.y - flightTarget.y)
                radius += ((left < 60 ? 5 : 10) - radius) * min(1, 8 * dt)
                model.tooltipOpacity = max(0, model.tooltipOpacity - Double(6 * dt))
                if left < 8 || now - endStart > 1.2 {
                    landed = true
                    let done = onLanded
                    onLanded = nil
                    done?()
                }
            }
            if !iconBack, morph.value < 0.02 { showIcon() }
            if landed, iconBack {
                finish()
                return
            }
        }
        morph.step(dt: Double(dt))
        layout()
    }

    /// L'icona vera torna nella barra al posto della farfalla di gocce, identica: lo scambio non si vede.
    private func showIcon() {
        iconBack = true
        model.butterfly = Path()
        model.butterflyOpacity = 0
        let icon = onIcon
        onIcon = nil
        icon?()
    }

    private func finish() {
        let done = onEnd
        onEnd = nil
        stop()
        done?()
    }

    private func integrate(_ p: inout CGPoint, _ v: inout CGVector, toward t: CGPoint, k: CGFloat, c: CGFloat, dt: CGFloat) {
        v.dx += ((t.x - p.x) * k - v.dx * c) * dt
        v.dy += ((t.y - p.y) * k - v.dy * c) * dt
        p.x += v.dx * dt
        p.y += v.dy * dt
    }

    private func tooltipGoal() -> CGPoint {
        var x = ball.x - 18 - radius - tooltipSize.width
        if x < 8 { x = ball.x + radius + 18 }
        return CGPoint(x: x, y: ball.y - tooltipSize.height / 2)
    }

    private func flip(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x, y: size.height - p.y) }

    private static func smooth(_ e0: Double, _ e1: Double, _ x: Double) -> Double {
        let t = min(1, max(0, (x - e0) / (e1 - e0)))
        return t * t * (3 - 2 * t)
    }

    private func layout() {
        let m = morph.value
        let flip = CGAffineTransform(translationX: 0, y: size.height).scaledBy(x: 1, y: -1)
        // La goccia, il filo e il pallino: il vetro entra mentre la farfalla si fonde (prima di metà fusione non c'è).
        if mode == .flying && landed {
            model.liquid = Path()
        } else {
            // un contorno solo: col filo e le sfere sovrapposti il vetro e il filo di luce disegnavano anche i bordi
            // interni (una riga dentro la goccia)
            let path = liquidPath().normalized(using: .winding)
            var t = flip
            model.liquid = Path(path.copy(using: &t) ?? path)
        }
        // Mai a opacità zero mentre il gesto è vivo, ma a `ready` (invisibile): il vetro, la nuvoletta e il pallino che
        // comparivano da zero a metà fusione (0,6) o all'inizio del volo costavano un fotogramma da 30-36 ms la prima
        // volta che SwiftUI li disegnava (misurato col trascinamento vero; carpa, 20 novembre 2026: «quando la tiro giù
        // un po' in fretta lagga», «più smooth quando lasci e va nel notch»).
        model.liquidOpacity = mode == .flying ? 1 : max(Self.ready, Self.smooth(0.6, 0.95, m))
        // La nuvoletta compare solo a fusione quasi finita, quando c'è già la goccia da accompagnare.
        if mode == .dragging { model.tooltipOpacity = max(Self.ready, Self.smooth(0.55, 1, m)) }
        // In volo il pallino resta al posto dell'icona, separato dal filo, e svanisce mentre torna farfalla. Durante il
        // trascinamento c'è già, invisibile, al suo posto: nascere al rilascio faceva scattare l'inizio del volo.
        let r = Self.pallinoRadius
        let pallinoRect = CGRect(x: anchor.x - r, y: size.height - anchor.y - r, width: r * 2, height: r * 2)
        if mode == .flying, !iconBack {
            model.pallino = Path(ellipseIn: pallinoRect)
            model.pallinoOpacity = max(Self.ready, Self.smooth(0.6, 0.95, m))
        } else if mode == .dragging {
            model.pallino = Path(ellipseIn: pallinoRect)
            model.pallinoOpacity = Self.ready
        } else {
            model.pallino = Path()
            model.pallinoOpacity = 0
        }
        // La farfalla di gocce: piena da icona, svanisce nel vetro del pallino nell'ultimo tratto della fusione. Fusa
        // del tutto non si vede: niente da calcolare per tutto il trascinamento.
        if !iconBack, mode == .dragging, m > 0.999 {
            if !model.butterfly.isEmpty { model.butterfly = Path() }
            model.butterflyOpacity = 0
        } else if !iconBack {
            let s = Double(iconHeight) / 478
            let field = ButterflyField(anchor: anchor, scale: s, morph: m, pallino: Double(Self.pallinoRadius))
            let halfW = Double(iconHeight * CharlandMark.aspect) / 2 + 4, halfH = Double(iconHeight) / 2 + 4
            var path = Path()
            for loop in tracer.trace(field, minX: Double(anchor.x) - halfW, minY: Double(anchor.y) - halfH,
                                     maxX: Double(anchor.x) + halfW, maxY: Double(anchor.y) + halfH) {
                guard let first = loop.first else { continue }
                path.move(to: CGPoint(x: first.x, y: Double(size.height) - first.y))
                for p in loop.dropFirst() { path.addLine(to: CGPoint(x: p.x, y: Double(size.height) - p.y)) }
                path.closeSubpath()
            }
            model.butterfly = path
            // Lo scambio col vetro del pallino avviene alla fine della fusione, dove le due forme coincidono.
            model.butterflyOpacity = 1 - Self.smooth(0.7, 1, m)
        }
        // il filo di luce corre dall'uscita del filo alla punta lontana della goccia
        let dx = ball.x - tail.x, dy = ball.y - tail.y
        let len = max(1, hypot(dx, dy))
        let far = CGPoint(x: ball.x + dx / len * radius, y: ball.y + dy / len * radius)
        model.from = self.flip(tail)
        model.to = len < radius ? self.flip(CGPoint(x: tail.x, y: tail.y - radius * 2)) : self.flip(far)
        // la nuvoletta: origine in alto a sinistra in coordinate di SwiftUI
        model.tooltipOrigin = CGPoint(x: tooltip.x, y: size.height - tooltip.y - tooltipSize.height)
    }

    /// L'unica forma liquida: il nastro affusolato lungo il filo, raccordato con archi concavi tangenti alla
    /// gocciolina d'attacco e alla goccia, più la goccia stessa (allungata dalla velocità). Gli archi vanno tutti
    /// nello stesso verso del nastro, così le sovrapposizioni si fondono invece di bucare.
    private func liquidPath() -> CGPath {
        let path = CGMutablePath()
        let r = radius
        let len = max(1, hypot(ball.x - tail.x, ball.y - tail.y))
        if len > r * 0.8 {
            let mid = CGPoint(x: (tail.x + ball.x) / 2, y: (tail.y + ball.y) / 2)
            let bend = max(-20, min(20, velocity.dx * 0.025))
            let ctrl = CGPoint(x: mid.x + bend, y: mid.y)
            let n = max(60, min(200, Int(len / 3)))
            var left: [CGPoint] = [], right: [CGPoint] = []
            left.reserveCapacity(n + 1); right.reserveCapacity(n + 1)
            // Il nastro comincia e finisce un poco dentro le due sfere: se i suoi angoli cadessero proprio sul punto
            // più largo della sfera, l'unione lascerebbe due tacche ai lati della goccia.
            let t0 = min(0.3, 0.3 * tailRadius / len), t1 = max(0.7, 1 - 0.3 * r / len)
            for i in 0...n {
                let t = t0 + (t1 - t0) * CGFloat(i) / CGFloat(n), u = 1 - t
                let px = u * u * tail.x + 2 * u * t * ctrl.x + t * t * ball.x
                let py = u * u * tail.y + 2 * u * t * ctrl.y + t * t * ball.y
                var tx = 2 * u * (ctrl.x - tail.x) + 2 * t * (ball.x - ctrl.x)
                var ty = 2 * u * (ctrl.y - tail.y) + 2 * t * (ball.y - ctrl.y)
                let tl = max(0.001, hypot(tx, ty)); tx /= tl; ty /= tl
                let ribbon = 1.5 + 1.0 * t
                let w = max(Self.blendedHalfWidth(d: t * len, sphere: tailRadius, ribbon: ribbon, fillet: 11),
                            Self.blendedHalfWidth(d: u * len, sphere: r, ribbon: ribbon, fillet: max(9, r * 1.35)))
                left.append(CGPoint(x: px - ty * w, y: py + tx * w))
                right.append(CGPoint(x: px + ty * w, y: py - tx * w))
            }
            path.move(to: right[0])
            for p in right.dropFirst() { path.addLine(to: p) }
            for p in left.reversed() { path.addLine(to: p) }
            path.closeSubpath()
        }
        var tr = CGAffineTransform(translationX: ball.x, y: ball.y)
        let speed = hypot(velocity.dx, velocity.dy)
        if speed > 40, mode == .dragging || mode == .flying {
            let s = 1 + min(0.30, speed / 2600)
            let angle = atan2(velocity.dy, velocity.dx)
            tr = tr.rotated(by: angle).scaledBy(x: s, y: 1 / s).rotated(by: -angle)
        }
        // Ogni sfera comincia dal suo punto: `addArc` dopo un altro pezzo traccia una linea dal punto corrente
        // all'inizio dell'arco, un capello dal filo alla goccia che il velo e il vetro disegnavano (c'è anche in Filo).
        path.move(to: CGPoint(x: r, y: 0).applying(tr))
        path.addArc(center: .zero, radius: r, startAngle: 0, endAngle: 2 * .pi, clockwise: false, transform: tr)
        path.closeSubpath()
        // In volo la coda del filo parte dal pallino che resta al suo posto: il suo cerchio farebbe un doppio anello.
        if tailRadius > 0.5, mode != .flying {
            path.move(to: CGPoint(x: tail.x + tailRadius, y: tail.y))
            path.addArc(center: tail, radius: tailRadius, startAngle: 0, endAngle: 2 * .pi, clockwise: false)
            path.closeSubpath()
        }
        return path
    }

    /// Semilarghezza della sagoma a distanza `d` dal centro di una sfera di raggio `r`, raccordata al filo di
    /// semilarghezza `w0` da un arco concavo di raggio `R` tangente a entrambi.
    static func blendedHalfWidth(d: CGFloat, sphere r: CGFloat, ribbon w0: CGFloat, fillet R: CGFloat) -> CGFloat {
        guard r > w0 else { return w0 }
        let sum = r + R, off = w0 + R
        guard sum > off else { return max(w0, sqrt(max(0, r * r - d * d))) }
        let dc = sqrt(sum * sum - off * off)
        let dt = dc * r / sum
        if d <= dt { return sqrt(max(0, r * r - d * d)) }
        if d < dc { return off - sqrt(max(0, R * R - (d - dc) * (d - dc))) }
        return w0
    }
}

/// Un orologio legato allo schermo per chi non è una vista: chiama `tick` a ogni fotogramma vero, con il tempo del
/// fotogramma che verrà mostrato. Il display link tiene vivo l'orologio finché gira: va fermato con `stop()`.
@MainActor
final class FrameClock: NSObject {
    private var link: CADisplayLink?
    private let tick: (CADisplayLink) -> Void

    init(tick: @escaping (CADisplayLink) -> Void) {
        self.tick = tick
    }

    func start(on screen: NSScreen?) {
        stop()
        guard let screen = screen ?? NSScreen.main else { return }
        let link = screen.displayLink(target: self, selector: #selector(fire(_:)))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    func stop() {
        link?.invalidate()
        link = nil
    }

    var isRunning: Bool { link != nil }

    @objc private func fire(_ link: CADisplayLink) { tick(link) }
}
