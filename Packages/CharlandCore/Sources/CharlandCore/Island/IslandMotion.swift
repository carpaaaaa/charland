import Foundation

/// I posti dove può stare un contenuto.
public enum ContentSlot: String, Sendable, CaseIterable, Codable {
    case leading
    case trailing
    case minimal
    case expanded
    case slider
    case lip
    /// La goccia staccata a sinistra (la terza attività). Le viste la disegnano come `minimal`.
    case minimalLeading
    /// Dentro un'attività aperta, la fila delle altre attività in corso. L'identificativo del contenuto sono i loro
    /// identificativi uniti da «|»: quando cambiano, la fila nuova entra al posto di quella vecchia.
    case switcher
}

/// Un contenuto visibile in un fotogramma: cosa, dove e quanto è presente.
/// Dalla presenza la vista ricava opacità, scala e sfocatura (vedi `ContentLayer.look`).
public struct ContentLayer: Sendable, Equatable {
    public var slot: ContentSlot
    public var id: String
    public var frame: IslandRect
    /// 0 = assente, 1 = presente.
    public var presence: Double

    /// Opacità, scala e sfocatura dell'ingresso: sfocatura da 8 a 0, scala da 0,94 a 1.
    public var look: (opacity: Double, scale: Double, blur: Double) {
        let p = min(1, max(0, presence))
        return (p, 0.94 + 0.06 * p, 8 * (1 - p))
    }
}

/// La goccia della dettatura in volo verso il cursore.
public struct DripState: Sendable, Equatable {
    /// Testa e coda, nello spazio dell'isola.
    public var headX: Double
    public var headY: Double
    public var tailX: Double
    public var tailY: Double
    public var headRadius: Double
    public var tailRadius: Double
    /// `true` finché è ancora attaccata all'isola da un collo (la disegna l'isola stessa).
    public var attached: Bool
}

/// Tutto quello che si vede in un fotogramma. È un valore puro, ricavato solo dal tempo
/// e dagli eventi: per questo il movimento si può provare senza schermo.
public struct IslandFrame: Sendable, Equatable {
    public var shape: IslandShape
    public var layers: [ContentLayer]
    public var drip: DripState?
    /// Quanto l'isola è aperta sotto la fascia della fotocamera, da 0 a 1: guida il vetro.
    public var openness: Double
    /// Fin dove il velo resta nero pieno (y in punti). Sotto comincia la sfumatura verso il vetro.
    public var blackUntil: Double

    public init(shape: IslandShape, layers: [ContentLayer], drip: DripState?, openness: Double, blackUntil: Double = 0) {
        self.shape = shape
        self.layers = layers
        self.drip = drip
        self.openness = openness
        self.blackUntil = blackUntil
    }
}

/// Il motore del movimento: tiene le molle di ogni numero e produce un fotogramma per passo.
public struct IslandMotion: Sendable {
    public let metrics: IslandMetrics
    public var tuning: IslandTuning
    /// Moltiplica la risposta delle molle: più di 1 = più calme, meno di 1 = più vivaci.
    public var calm: Double = 1

    private var channels: [Animated]
    /// I contenuti di ogni posto, nell'ordine di `ContentSlot.allCases`. Un array e non un dizionario:
    /// a ogni passo si modificano sul posto, senza copie.
    private var slots: [[SlotState]] = Array(repeating: [], count: IslandMotion.slotOrder.count)
    private static let slotOrder = ContentSlot.allCases
    private var mode: IslandMode = .rest
    private var clock = 0.0
    private var drip: DripFlight?
    /// Le gocce staccate che stanno rientrando nel corpo: spariscono quando sono ferme.
    private var hideWhenSettled: Set<BlobSlot> = []
    /// Un contenuto nuovo deve nascere: la forma aspetta un passo, così la vista si crea a isola
    /// ferma e l'eventuale fotogramma lungo non si vede. Vale solo se l'isola è davvero ferma:
    /// fermarla in corsa sarebbe proprio l'inciampo da evitare (vedi `step`).
    private var holdOneStep = false
    private var scheduled: [Scheduled] = []
    private var blackUntil: Animated
    /// Allungamento in più dei due bordi, per l'elastico dello slider.
    private var extraLeft = 0.0
    private var extraRight = 0.0

    /// Un cambio di bersaglio che scatta più tardi: serve alle coreografie in due tempi.
    private struct Scheduled: Sendable {
        var at: Double
        var channel: Int
        var target: Double
        var spring: Spring
    }

    private struct SlotState: Sendable {
        var id: String
        var frame: IslandRect
        var presence: Animated
        var enterAt: Double?
        var leaving: Bool
    }

    private struct DripFlight: Sendable {
        var start: Double
        var duration: Double
        var fromX: Double
        var fromY: Double
        var toX: Double
        var toY: Double
        var radius: Double
        var detached: Bool
    }

    /// Quanto dura il volo della goccia verso il cursore.
    public static let dripDuration = 0.36
    /// I contenuti entrano questo tempo dopo l'inizio del movimento della forma.
    public static let contentDelay = 0.06
    static let contentIn = Spring(response: 0.34, damping: 0.9)
    static let contentOut = Spring(response: 0.18, damping: 1.0)

    public init(metrics: IslandMetrics, tuning: IslandTuning = IslandTuning()) {
        self.metrics = metrics
        self.tuning = tuning
        channels = IslandShape.resting(metrics).scalars.map { Animated($0) }
        blackUntil = Animated(metrics.notchHeight)
    }

    public var shape: IslandShape { makeShape(targets: false) }
    public var targetShape: IslandShape { makeShape(targets: true) }
    public var now: Double { clock }

    /// La forma letta direttamente dalle molle, senza il vettore di numeri in mezzo:
    /// si chiama a ogni fotogramma. Stesse regole di `IslandShape(scalars:)`.
    private func makeShape(targets: Bool) -> IslandShape {
        func v(_ i: Int) -> Double { targets ? channels[i].target : channels[i].value }
        var blobs: [Blob] = []
        blobs.reserveCapacity(BlobSlot.allCases.count)
        for slot in 0..<BlobSlot.allCases.count {
            let b = 8 + slot * 6
            blobs.append(Blob(x: v(b), y: v(b + 1), halfWidth: max(0, v(b + 2)), halfHeight: max(0, v(b + 3)),
                              radius: max(0, v(b + 4)), blend: max(0, v(b + 5))))
        }
        return IslandShape(left: v(0), right: v(1), height: v(2), radius: max(0, v(3)), flare: max(0, v(4)),
                           wave: v(5), wavePhase: v(6), press: v(7), blobs: blobs)
    }

    public var isMoving: Bool {
        if drip != nil || !scheduled.isEmpty { return true }
        if channels.contains(where: { !$0.isSettled }) || !blackUntil.isSettled { return true }
        return slots.contains { $0.contains { !$0.presence.isSettled || $0.enterAt != nil } }
    }

    /// In questo istante non si muove niente di visibile: né la forma, né il respiro, né la goccia,
    /// né un contenuto che entra o esce. Un bersaglio appena cambiato non conta: la molla
    /// parte da ferma, e il primo passo può aspettare senza che si veda.
    private var isStill: Bool {
        if drip != nil || channels[5].value != 0 || blackUntil.velocity != 0 { return false }
        if channels.contains(where: { $0.velocity != 0 }) { return false }
        return !slots.contains { $0.contains { $0.presence.velocity != 0 } }
    }

    private func spring(_ base: Spring) -> Spring {
        Spring(response: base.response * calm, damping: base.damping)
    }

    // MARK: Stati

    /// Passa a un nuovo stato. Le cornici dei contenuti sono quelle dello stato di arrivo.
    public mutating func apply(_ newMode: IslandMode, state: IslandState) {
        let target = IslandLayout.shape(for: newMode, state: state, metrics: metrics, tuning: tuning)
        let frames = IslandLayout.frames(for: newMode, state: state, metrics: metrics, tuning: tuning)
        // Prima di muovere il corpo: il seme di una goccia nuova nasce contro il bordo com'è adesso.
        let edges = (left: channels[0].value, right: channels[1].value)

        retargetBody(target)
        blackUntil.spring = spring(.shape)
        blackUntil.target = frames.blackUntil

        // Le due gocce staccate, a destra e a sinistra, con la stessa coreografia specchiata.
        for side in IslandLayout.DropSide.allCases {
            moveDrop(side, target: target, from: side == .trailing ? edges.right : edges.left)
        }

        applyContents(for: newMode, frames: frames)
        mode = newMode
    }

    /// Una goccia staccata: nasce dentro il corpo e si stacca con un collo liquido, oppure rientra e viene
    /// riassorbita. Se c'era già (cambia solo dove sta, o chi ci sta dentro) si sposta e basta: rifare il collo a ogni
    /// cambio di stato la riattaccava al corpo per un istante a ogni aggiornamento di un'attività.
    private mutating func moveDrop(_ side: IslandLayout.DropSide, target: IslandShape, from edge: Double) {
        let slot = side.blob
        let had = shape[slot].isVisible && !hideWhenSettled.contains(slot)
        let wants = target[slot].isVisible
        let blendChannel = blobBase(slot) + 5
        if wants {
            hideWhenSettled.remove(slot)
            if had {
                setBlob(slot, target: target[slot], spring: spring(.shape), blendSpring: spring(.shape))
                return
            }
            // Nasce come un punto dentro il corpo, contro il suo bordo: non si vede. Poi cresce ed esce, e il raggio
            // di fusione sale subito per tirarsi dietro il collo.
            let seed = IslandLayout.minimalSeed(side, bodyEdge: edge, metrics, tuning)
            setBlob(slot, snap: Blob(x: seed.x, y: seed.y, halfWidth: 0.1, halfHeight: 0.1, radius: 0.1, blend: 0))
            setBlob(slot, target: target[slot], spring: spring(.shape), blendSpring: spring(.quick))
            channels[blendChannel].target = tuning.splitBlend
            // Staccata la goccia, la fusione si rilassa: a riposo le due forme non si gonfiano.
            schedule(blendChannel, after: 0.26 * calm, target: target[slot].blend,
                     spring: Spring(response: 0.6 * calm, damping: 1.0))
        } else if had {
            // Rientra nel corpo: il collo si riforma, la goccia viene riassorbita e si spegne.
            let edgeNow = side == .trailing ? target.right : target.left
            let seed = IslandLayout.minimalSeed(side, bodyEdge: edgeNow, metrics, tuning)
            setBlob(slot, target: Blob(x: seed.x, y: seed.y, halfWidth: 0.1, halfHeight: 0.1, radius: 0.1,
                                       blend: tuning.splitBlend),
                    spring: spring(.shape), blendSpring: spring(.quick))
            schedule(blendChannel, after: 0.22 * calm, target: 0, spring: Spring(response: 0.5 * calm, damping: 1.0))
            hideWhenSettled.insert(slot)
        }
    }

    private mutating func retargetBody(_ target: IslandShape) {
        let s = target.scalars
        let shapeSpring = spring(.shape)
        // left, right, height, radius, flare. Respiro, fase e pressione hanno vita propria.
        for i in 0..<5 {
            channels[i].spring = shapeSpring
            channels[i].target = s[i]
        }
        channels[0].target += extraLeft
        channels[1].target += extraRight
        // Chiudendo, il bordo basso non rimbalza: salirebbe sopra il fondo del notch vero
        // e le ali sembrerebbero più corte del notch per qualche fotogramma.
        if s[2] < channels[2].value {
            channels[2].spring = Spring(response: shapeSpring.response * 0.92, damping: 1.0)
        }
    }

    private func blobBase(_ slot: BlobSlot) -> Int { 8 + slot.rawValue * 6 }

    private mutating func schedule(_ channel: Int, after delay: Double, target: Double, spring: Spring) {
        scheduled.removeAll { $0.channel == channel }
        scheduled.append(Scheduled(at: clock + delay, channel: channel, target: target, spring: spring))
    }

    /// Durante il volo della goccia si chiama a ogni fotogramma: niente array di passaggio.
    private mutating func setBlob(_ slot: BlobSlot, snap blob: Blob) {
        let base = blobBase(slot)
        channels[base].snap(to: blob.x)
        channels[base + 1].snap(to: blob.y)
        channels[base + 2].snap(to: blob.halfWidth)
        channels[base + 3].snap(to: blob.halfHeight)
        channels[base + 4].snap(to: blob.radius)
        channels[base + 5].snap(to: blob.blend)
    }

    private mutating func setBlob(_ slot: BlobSlot, target blob: Blob, spring: Spring, blendSpring: Spring) {
        let base = blobBase(slot)
        let values = [blob.x, blob.y, blob.halfWidth, blob.halfHeight, blob.radius, blob.blend]
        for (offset, v) in values.enumerated() {
            channels[base + offset].spring = offset == 5 ? blendSpring : spring
            channels[base + offset].target = v
        }
    }

    private mutating func applyContents(for mode: IslandMode, frames: IslandFrames) {
        var wanted: [ContentSlot: (String, IslandRect)] = [:]
        switch mode {
        case .rest:
            break
        case .compact(let primary, let secondary, let tertiary):
            wanted[.leading] = (primary, frames.compactLeading)
            wanted[.trailing] = (primary, frames.compactTrailing)
            if let secondary { wanted[.minimal] = (secondary, frames.minimal) }
            if let tertiary { wanted[.minimalLeading] = (tertiary, frames.minimalLeading) }
        case .expanded(let id):
            wanted[.leading] = (id, frames.compactLeading)
            wanted[.trailing] = (id, frames.compactTrailing)
            wanted[.expanded] = (id, frames.expanded)
            if !frames.switcherIDs.isEmpty {
                wanted[.switcher] = (frames.switcherIDs.joined(separator: "|"), frames.switcher)
            }
        case .transient(let transient, _):
            switch transient {
            case .slider(let side):
                wanted[.slider] = (side.rawValue, frames.slider)
            case .dictation(_, let liveText, _):
                wanted[.leading] = ("dictation", frames.compactLeading)
                wanted[.trailing] = ("dictation", frames.compactTrailing)
                if liveText { wanted[.lip] = ("dictation", frames.lip) }
            case .dripping:
                break
            }
        }

        for (index, slot) in Self.slotOrder.enumerated() {
            var layers = slots[index]
            let want = wanted[slot]
            var found = false
            for i in layers.indices {
                if let (id, frame) = want, layers[i].id == id {
                    // È già qui (o stava uscendo e torna): riparte da dov'è, senza scatti.
                    found = true
                    if layers[i].leaving {
                        layers[i].leaving = false
                        layers[i].presence.spring = spring(Self.contentIn)
                        layers[i].presence.target = 1
                    }
                    layers[i].frame = frame
                } else if !layers[i].leaving {
                    // Non serve più: esce, e resta dov'era mentre esce.
                    layers[i].leaving = true
                    layers[i].enterAt = nil
                    layers[i].presence.spring = spring(Self.contentOut)
                    layers[i].presence.target = 0
                }
            }
            if let (id, frame) = want, !found {
                // Se prende il posto di un altro contenuto aspetta che quello sia quasi uscito.
                let replacing = layers.contains { $0.presence.value > 0.05 }
                let delay = (replacing ? 0.13 : Self.contentDelay) * calm
                layers.append(SlotState(id: id, frame: frame,
                                        presence: Animated(0, spring: spring(Self.contentIn), restDistance: 0.002, restSpeed: 0.02),
                                        enterAt: clock + delay, leaving: false))
                holdOneStep = true
            }
            slots[index] = layers
        }
    }

    // MARK: Valori diretti

    /// Il respiro del bordo basso, guidato dalla voce.
    public mutating func setWave(amplitude: Double) {
        channels[5].spring = Spring(response: 0.16, damping: 1.0)
        channels[5].target = amplitude
    }

    /// L'elastico dello slider allunga anche il bordo dell'isola dal suo lato:
    /// la pillola non esce mai dalla forma. I valori seguono subito, senza molla in più,
    /// perché l'elastico è già una molla.
    public mutating func setEdgeStretch(left: Double, right: Double) {
        let dl = left - extraLeft
        let dr = right - extraRight
        extraLeft = left
        extraRight = right
        channels[0].value += dl
        channels[0].target += dl
        channels[1].value += dr
        channels[1].target += dr
    }

    public mutating func setPressed(_ pressed: Bool) {
        channels[7].spring = pressed ? Spring(response: 0.14, damping: 0.9) : spring(.lively)
        channels[7].target = pressed ? 1 : 0
    }

    /// Fa partire la goccia verso un punto, nello spazio dell'isola.
    public mutating func startDrip(toX: Double, toY: Double, duration: Double = IslandMotion.dripDuration) {
        let current = shape
        let r = 8.0
        drip = DripFlight(start: clock, duration: duration, fromX: 0, fromY: current.height - r - 1,
                          toX: toX, toY: toY, radius: r, detached: false)
        // Nasce dentro il corpo e senza fusione: un raggio di fusione pieno da subito gonfierebbe
        // il bordo di 4 punti in un fotogramma.
        setBlob(.drip, snap: Blob(x: 0, y: current.height - r - 1, halfWidth: r, halfHeight: r, radius: r, blend: 0))
    }

    // MARK: Passo

    /// Avanza di `dt` secondi e restituisce `true` se qualcosa si muove ancora.
    @discardableResult
    public mutating func step(dt: Double) -> Bool {
        if holdOneStep {
            holdOneStep = false
            // Questo fotogramma serve solo a far nascere le viste nuove: la forma resta ferma.
            // Ma solo se era già ferma: se sta correndo (si apre mentre la forma compatta ancora
            // rimbalza) un fotogramma uguale al precedente si vede come un inciampo.
            // Allora la vista nasce in corsa, e il movimento continua.
            if isStill { return true }
        }
        let dt = min(max(dt, 0), 1.0 / 20.0)
        clock += dt
        var moving = false
        if !scheduled.isEmpty {
            for item in scheduled where item.at <= clock {
                channels[item.channel].spring = item.spring
                channels[item.channel].target = item.target
            }
            scheduled.removeAll { $0.at <= clock }
            moving = true
        }
        for i in channels.indices where i != 6 {
            if channels[i].step(dt: dt) { moving = true }
        }
        if blackUntil.step(dt: dt) { moving = true }
        // La fase del respiro scorre solo mentre c'è ampiezza.
        if channels[5].value != 0 || channels[5].target != 0 {
            channels[6].snap(to: channels[6].value + dt * 3.2)
            moving = true
        }

        // Sul posto, senza tirare fuori gli array: niente copie a ogni fotogramma.
        for s in slots.indices where !slots[s].isEmpty {
            for i in slots[s].indices {
                if let enterAt = slots[s][i].enterAt {
                    if clock >= enterAt {
                        slots[s][i].enterAt = nil
                        slots[s][i].presence.target = 1
                    }
                    moving = true
                }
                if slots[s][i].presence.step(dt: dt) { moving = true }
            }
            slots[s].removeAll { $0.leaving && $0.presence.isSettled && $0.presence.value == 0 }
        }

        for slot in hideWhenSettled {
            let base = blobBase(slot)
            let edge = slot == .minimal ? 1 : 0
            if channels[base..<(base + 6)].allSatisfy(\.isSettled), channels[edge].isSettled,
               !scheduled.contains(where: { $0.channel == base + 5 }) {
                setBlob(slot, snap: .hidden)
                hideWhenSettled.remove(slot)
            }
        }

        if stepDrip() { moving = true }
        return moving
    }

    /// Posizione della goccia lungo la sua curva: parte dritta verso il basso, poi piega verso il cursore.
    private mutating func stepDrip() -> Bool {
        guard var flight = drip else { return false }
        let u = min(1, (clock - flight.start) / flight.duration)
        // Accelera come una goccia che cade, poi frena appena prima di arrivare.
        let t = u < 0.8 ? 0.8 * pow(u / 0.8, 2.2) : 0.8 + 0.2 * (1 - pow(1 - (u - 0.8) / 0.2, 2))
        let cx = flight.fromX
        let cy = flight.fromY + (flight.toY - flight.fromY) * 0.55
        let omt = 1 - t
        let x = omt * omt * flight.fromX + 2 * omt * t * cx + t * t * flight.toX
        let y = omt * omt * flight.fromY + 2 * omt * t * cy + t * t * flight.toY
        let bodyBottom = channels[2].value
        let gap = (y - flight.radius) - bodyBottom

        if !flight.detached {
            // Ancora attaccata: la disegna il campo dell'isola, allungata verso il basso.
            let stretch = 1 + min(0.9, max(0, y - flight.fromY) / 28)
            // La fusione cresce nei primi istanti del volo e poi cala mentre il collo si allunga.
            let blend = max(0, min(18 * min(1, u / 0.3), 18 - max(0, gap) * 2.2))
            setBlob(.drip, snap: Blob(x: x, y: y, halfWidth: flight.radius / stretch.squareRoot(),
                                      halfHeight: flight.radius * stretch.squareRoot(),
                                      radius: flight.radius / stretch.squareRoot(), blend: blend))
            if gap > blend / 2 + 1.5 {
                flight.detached = true
                setBlob(.drip, snap: .hidden)
            }
        }
        drip = u >= 1 ? nil : flight
        if u >= 1 { setBlob(.drip, snap: .hidden) }
        return drip != nil
    }

    private func dripState() -> DripState? {
        guard let flight = drip else { return nil }
        let u = min(1, (clock - flight.start) / flight.duration)
        func point(_ uu: Double) -> (Double, Double) {
            let v = min(1, max(0, uu))
            let t = v < 0.8 ? 0.8 * pow(v / 0.8, 2.2) : 0.8 + 0.2 * (1 - pow(1 - (v - 0.8) / 0.2, 2))
            let cx = flight.fromX
            let cy = flight.fromY + (flight.toY - flight.fromY) * 0.55
            let omt = 1 - t
            return (omt * omt * flight.fromX + 2 * omt * t * cx + t * t * flight.toX,
                    omt * omt * flight.fromY + 2 * omt * t * cy + t * t * flight.toY)
        }
        let head = point(u)
        // La coda è dov'era la testa poco fa: più veloce va, più si allunga, ma al massimo tre raggi. Senza limite,
        // in fondo alla corsa la coda restava lontanissima e la goccia diventava un ago.
        var tail = point(u - 0.09)
        let dx = head.0 - tail.0, dy = head.1 - tail.1
        let length = (dx * dx + dy * dy).squareRoot()
        let longest = flight.radius * 3
        if length > longest {
            tail = (head.0 - dx / length * longest, head.1 - dy / length * longest)
        }
        // Arrivando si rimpicciolisce dentro il cursore.
        let landing = u > 0.86 ? max(0, 1 - (u - 0.86) / 0.14) : 1
        return DripState(headX: head.0, headY: head.1, tailX: tail.0, tailY: tail.1,
                         headRadius: flight.radius * landing, tailRadius: flight.radius * 0.45 * landing,
                         attached: !flight.detached)
    }

    /// Il fotogramma corrente.
    public var frame: IslandFrame {
        let current = shape
        var layers: [ContentLayer] = []
        for (index, slot) in Self.slotOrder.enumerated() {
            // Anche i contenuti in attesa di entrare, invisibili: così la loro vista nasce all'inizio
            // del movimento, quando la forma parte da ferma, e non a metà corsa.
            for s in slots[index] where s.presence.value > 0.001 || s.enterAt != nil {
                layers.append(ContentLayer(slot: slot, id: s.id, frame: s.frame, presence: s.presence.value))
            }
        }
        let below = current.height - metrics.notchHeight
        let u = min(1, max(0, below / 26))
        return IslandFrame(shape: current, layers: layers, drip: dripState(), openness: u * u * (3 - 2 * u),
                           blackUntil: blackUntil.value)
    }
}
