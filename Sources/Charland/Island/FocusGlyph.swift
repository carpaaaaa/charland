import SwiftUI
import AppKit
import CharlandCore

// La Concentrazione di macOS nell'isola: il simbolo e la parola del momento compatto (carpa, 19 novembre 2026: «una bella
// animazione smooth che si mette a non disturbare e poi gli si leva»). Accesa, la luna nasce sottile e ruotata e si apre
// nella falce di Non disturbare; spenta, la falce cala di nuovo sottile, si gira e perde il colore. Niente lampi né
// cerchi che si chiudono: è la stessa luna che cambia fase.
//
// Il movimento è una funzione del tempo fatta di molle esatte (`Spring` del motore dell'isola): un cambio a metà riparte
// dal punto e dalla velocità in cui si trova, senza scatti, e ogni fotogramma si può ricalcolare per controllarlo.

/// Una molla che parte da un valore e da una velocità a un certo istante: il valore si legge a qualsiasi tempo.
struct SpringTrack: Equatable {
    var from: Double
    var velocity: Double = 0
    var to: Double
    var start: Double = 0
    var spring: CharlandCore.Spring

    init(_ value: Double, spring: CharlandCore.Spring) {
        from = value
        to = value
        self.spring = spring
    }

    func sample(_ t: Double) -> (value: Double, velocity: Double) {
        var value = from, speed = velocity
        spring.step(value: &value, velocity: &speed, target: to, dt: max(0, t - start))
        return (value, speed)
    }

    func value(_ t: Double) -> Double { sample(t).value }

    /// Verso un valore nuovo: riparte da dove si trova adesso, con la sua velocità. `delay` aspetta prima di muoversi.
    mutating func retarget(_ target: Double, at t: Double, delay: Double = 0) {
        let now = sample(t)
        from = now.value
        velocity = delay > 0 ? 0 : now.velocity
        to = target
        start = t + delay
    }

    func settled(_ t: Double) -> Bool {
        let s = sample(t)
        return t >= start && abs(s.value - to) < 0.0005 && abs(s.velocity) < 0.002
    }
}

/// I colori della Concentrazione: quello del modo acceso e il grigio di quando si spegne.
enum FocusPalette {
    /// Non disturbare e le Concentrazioni senza un colore noto: l'indaco di Apple, schiarito per leggersi sul nero.
    static let indigo = (r: 0.49, g: 0.48, b: 1.0)
    /// Sonno.
    static let mint = (r: 0.40, g: 0.86, b: 0.81)
    static let off = (r: 0.62, g: 0.62, b: 0.64)

    static func rgb(_ tint: String) -> (r: Double, g: Double, b: Double) { tint == "mint" ? mint : indigo }

    /// Il colore fra spento (0) e acceso (1).
    static func color(_ tint: String, lit: Double) -> Color {
        let a = rgb(tint), k = min(1, max(0, lit))
        return Color(red: off.r + (a.r - off.r) * k, green: off.g + (a.g - off.g) * k, blue: off.b + (a.b - off.b) * k)
    }
}

/// Le molle del simbolo e dove vanno accesa e spenta.
struct FocusMotion: Equatable {
    /// Quanto è aperta la falce: 0 un filo, 1 la falce piena di Non disturbare.
    var phase = SpringTrack(0, spring: CharlandCore.Spring(response: 0.62, damping: 0.86))
    var scale = SpringTrack(0.62, spring: CharlandCore.Spring(response: 0.42, damping: 0.64))
    var tilt = SpringTrack(-38, spring: CharlandCore.Spring(response: 0.6, damping: 0.8))
    var opacity = SpringTrack(0, spring: CharlandCore.Spring(response: 0.24, damping: 1))
    /// 0 grigio, 1 il colore del modo.
    var lit = SpringTrack(1, spring: CharlandCore.Spring(response: 0.5, damping: 1))
    private(set) var on: Bool?

    struct Look: Equatable {
        var phase: Double
        var scale: Double
        var tilt: Double
        var opacity: Double
        var lit: Double
    }

    /// Spento, il simbolo nasce acceso e cala dopo questo tempo: così si vede cosa si è spento.
    static let offDelay = 0.34

    /// Acceso: il simbolo nasce sottile e ruotato e si apre nella falce.
    mutating func appear(at t: Double) {
        on = true
        opacity.retarget(1, at: t)
        scale.retarget(1, at: t)
        tilt.retarget(0, at: t)
        phase.retarget(1, at: t, delay: 0.06)
    }

    /// Spento: la falce entra già piena e accesa (se il nome era ancora nell'isola, prende il posto di quella che esce
    /// senza ricrescere da un filo), poi chi la mostra chiama `set(on: false)` dopo `offDelay` e cala.
    mutating func appearLit(at t: Double) {
        on = true
        phase = SpringTrack(1, spring: phase.spring)
        tilt = SpringTrack(0, spring: tilt.spring)
        scale = SpringTrack(0.88, spring: scale.spring)
        scale.retarget(1, at: t)
        opacity.retarget(1, at: t)
    }

    /// Acceso o spento mentre è già nell'isola: riparte da dove si trova.
    mutating func set(on: Bool, at t: Double) {
        self.on = on
        if on {
            phase.retarget(1, at: t)
            tilt.retarget(0, at: t)
            scale.retarget(1, at: t)
            opacity.retarget(1, at: t)
            lit.retarget(1, at: t)
        } else {
            phase.retarget(0.22, at: t)
            tilt.retarget(24, at: t)
            scale.retarget(0.9, at: t)
            opacity.retarget(0.72, at: t)
            lit.retarget(0, at: t)
        }
    }

    func look(_ t: Double) -> Look {
        Look(phase: phase.value(t), scale: scale.value(t), tilt: tilt.value(t), opacity: min(1, max(0, opacity.value(t))),
             lit: lit.value(t))
    }

    func settled(_ t: Double) -> Bool {
        phase.settled(t) && scale.settled(t) && tilt.settled(t) && opacity.settled(t) && lit.settled(t)
    }
}

/// La falce: un disco a cui un secondo disco toglie la parte in alto a destra, come il simbolo di Non disturbare.
/// `phase` 0 lascia un filo di luce in basso a sinistra, 1 la falce piena.
struct MoonShape: Shape {
    var phase: Double

    func path(in rect: CGRect) -> Path {
        let r = min(rect.width, rect.height) / 2
        let c = CGPoint(x: rect.midX, y: rect.midY)
        let cut = r * 0.92
        // da 0,16 r (un filo) a 0,74 r (la falce): il disco che toglie scivola verso l'alto a destra
        let d = r * (0.16 + 0.58 * phase)
        let angle = -Double.pi / 4
        let o = CGPoint(x: c.x + d * cos(angle), y: c.y + d * sin(angle))
        let moon = Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
        let shadow = Path(ellipseIn: CGRect(x: o.x - cut, y: o.y - cut, width: 2 * cut, height: 2 * cut))
        return moon.subtracting(shadow)
    }
}

/// Il simbolo a sinistra della fotocamera. Con un simbolo di sistema (Sonno, Lavoro…) lo stesso movimento senza la falce.
struct FocusGlyph: View {
    let on: Bool
    /// `nil`: la falce disegnata (Non disturbare e le Concentrazioni senza un simbolo noto).
    let symbol: String?
    let tint: String
    @State private var motion = FocusMotion()

    static func now() -> Double { Date().timeIntervalSinceReferenceDate }

    var body: some View {
        TimelineView(.animation(minimumInterval: nil, paused: motion.on != nil && motion.settled(Self.now()))) { context in
            FocusGlyphFrame(look: motion.look(context.date.timeIntervalSinceReferenceDate), symbol: symbol, tint: tint)
        }
        .onAppear { if on { motion.appear(at: Self.now()) } else { motion.appearLit(at: Self.now()) } }
        .onChange(of: on) { _, value in motion.set(on: value, at: Self.now()) }
        .task {
            guard !on else { return }
            try? await Task.sleep(for: .seconds(FocusMotion.offDelay))
            if !on { motion.set(on: false, at: Self.now()) }
        }
    }
}

/// Un fotogramma del simbolo, dato il suo aspetto: serve all'isola e alle prove che lo disegnano fotogramma per fotogramma.
struct FocusGlyphFrame: View {
    let look: FocusMotion.Look
    let symbol: String?
    let tint: String

    var body: some View {
        let style: AnyShapeStyle = Glassy.on ? Glassy.ink : AnyShapeStyle(FocusPalette.color(tint, lit: look.lit))
        Group {
            if let symbol {
                Image(systemName: symbol).font(.system(size: 14, weight: .semibold)).foregroundStyle(style)
            } else {
                MoonShape(phase: look.phase).fill(style).frame(width: 14.5, height: 14.5)
            }
        }
        .rotationEffect(.degrees(look.tilt))
        .scaleEffect(look.scale)
        .opacity(look.opacity * (Glassy.on ? 0.55 + 0.45 * look.lit : 1))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// La parola a destra: il nome della Concentrazione accesa, o «Spento». Entra un attimo dopo il simbolo, scivolando e
/// mettendosi a fuoco come quella del Risparmio energetico; se cambia mentre è nell'isola, sfuma nell'altra.
struct FocusLabel: View {
    let text: String
    let on: Bool
    let tint: String
    @State private var shown = false

    static let font = NSFont.systemFont(ofSize: 13, weight: .semibold)
    /// L'ala destra dell'isola: larga quanto la parola più due punti d'aria, mai più di 150.
    static func width(for text: String) -> Double {
        min(150, max(36, ceil((text as NSString).size(withAttributes: [.font: font]).width) + 3))
    }

    var body: some View {
        Text(text)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(Glassy.on ? Glassy.ink : AnyShapeStyle(on ? FocusPalette.color(tint, lit: 1) : Color.white.opacity(0.55)))
            .lineLimit(1)
            .truncationMode(.tail)
            .id(text)
            .transition(.blurReplace)
            .opacity(shown ? 1 : 0)
            .blur(radius: shown ? 0 : 5)
            .offset(x: shown ? 0 : -10)
            .frame(maxWidth: .infinity, alignment: .trailing)
            .animation(.spring(response: 0.4, dampingFraction: 0.86), value: text)
            .animation(.easeInOut(duration: 0.35), value: on)
            .task {
                try? await Task.sleep(for: .milliseconds(220))
                withAnimation(.spring(response: 0.45, dampingFraction: 0.85)) { shown = true }
            }
    }
}
