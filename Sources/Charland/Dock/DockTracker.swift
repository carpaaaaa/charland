import AppKit
import ApplicationServices

/// Dove sta il Dock in questo istante, letto dall'Accessibilità.
///
/// Misurato sul Dock vero il 17 novembre 2026 (macOS 27.3, Dock in basso a scomparsa, icone da 35): la lista delle
/// icone riporta il suo riquadro punto per punto anche mentre il Dock sale e scende (0,2 secondi, un valore ogni 9 ms
/// circa), e si allarga con l'ingrandimento. Nascosto, il riquadro sta appena sotto il bordo dello schermo. Il vassoio
/// di vetro coincide con il riquadro delle icone: stessa larghezza della lista, 5 punti più in basso, alto 49.
struct DockReading: Equatable, Sendable {
    /// La lista delle icone, nelle coordinate dell'Accessibilità: origine in alto a sinistra dello schermo principale.
    var list: CGRect
    /// Il vassoio rispetto alla lista: quanto più in basso comincia e quanto è alto.
    var plateTop: CGFloat
    var plateHeight: CGFloat
    /// Il Dock è in basso (o in alto), non su un fianco.
    var horizontal: Bool
}

/// Legge il Dock in sottofondo, mai sul thread principale: una lettura costa 0,2 ms di solito, ma quando il Dock è
/// occupato può bloccare per decine di millisecondi, e l'isola non deve perdere fotogrammi per questo.
///
/// A riposo guarda ogni due secondi (quattro volte al secondo se il Dock a scomparsa è fuori: può rientrare da un
/// momento all'altro). Quando il puntatore tocca il bordo o gira attorno al Dock (`kick`) guarda 80 volte al secondo
/// per un secondo abbondante; quando il riquadro cambia, ogni 4 ms finché non si ferma. Mission Control e App Exposé
/// fanno lo stesso per tre secondi (`listenToMissionControl`).
final class DockTracker: @unchecked Sendable {
    static let shared = DockTracker()

    private let condition = NSCondition()
    private var running = false
    /// Cresce a ogni accensione: un thread di un'accensione precedente, ancora dentro una lettura, se ne accorge ed esce.
    private var generation = 0
    private var sleepingLong = false
    private var warmUntil: CFTimeInterval = 0
    private var hotUntil: CFTimeInterval = 0
    private var notified = false
    private var handler: (@MainActor () -> Void)?

    private var latest: DockReading?
    private var sampleTime: CFTimeInterval = 0
    /// Le ultime due altezze diverse e quando sono state viste: da lì la velocità. Un cambio di sola larghezza
    /// (l'ingrandimento) non le tocca.
    private var yTime: CFTimeInterval = 0
    private var previousY: CGFloat = 0
    private var previousTime: CFTimeInterval = 0

    /// Il Dock si è visto nascosto di recente: è a scomparsa. Se resta fuori a lungo senza mai nascondersi non lo è più.
    private var autohides = false
    private var shownSince: CFTimeInterval = 0
    private var screenBottom: CGFloat = .greatestFiniteMagnitude
    /// L'ascolto di Mission Control si accende una volta sola per processo: non si toglie, e a lettura spenta il
    /// segnale non fa niente.
    private var listeningToMissionControl = false

    private static let trace = ProcessInfo.processInfo.environment["CHARLAND_DOCK"] != nil

    /// `onChange` viene chiamata sul thread principale quando il Dock comincia a muoversi (una volta, finché non si
    /// chiama `acknowledge`).
    func start(onChange: @escaping @MainActor () -> Void) {
        listenToMissionControl()
        condition.lock()
        defer { condition.unlock() }
        handler = onChange
        guard !running else { return }
        running = true
        generation += 1
        let mine = generation
        let thread = Thread { [weak self] in self?.loop(mine) }
        thread.name = "charland.dock"
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    func stop() {
        condition.lock()
        running = false
        latest = nil
        handler = nil
        notified = false
        yTime = 0
        previousY = 0
        previousTime = 0
        autohides = false
        shownSince = 0
        condition.signal()
        condition.unlock()
    }

    /// Il puntatore è sul bordo o attorno al Dock: per un po' si guarda a ogni fotogramma.
    func kick(for duration: CFTimeInterval = 1.3) {
        condition.lock()
        warmUntil = max(warmUntil, CACurrentMediaTime() + duration)
        if sleepingLong { condition.signal() }
        condition.unlock()
    }

    /// Mission Control e App Exposé (tre dita in su o in giù, ^↑, F3, angoli attivi) fanno salire il Dock a scomparsa
    /// senza che il puntatore tocchi il bordo: la lettura, che a Dock nascosto guarda ogni due secondi, lo vedeva
    /// fino a due secondi dopo, e spesso i vassoi non c'erano proprio (carpa, 19 novembre: «quando appare il Dock
    /// spesso non ha i widget»; misurato: in un giro su cinque mancavano ancora a 1,7 secondi). SkyLight avvisa ogni
    /// processo quando entra ed esce da Mission Control con la notifica 1508. Provato su macOS 27.3: arriva con
    /// Mission Control e con App Exposé, mai col Dock fatto salire dal puntatore, con Mostra scrivania (dove il Dock
    /// non sale) o nell'uso normale. A ogni avviso si guarda a ogni fotogramma per tre secondi: il Dock comincia a
    /// salire subito dopo, e quando il riquadro cambia la lettura passa da sola a ogni 4 ms. Funzioni private cercate
    /// a runtime: se mancano, o se un giorno il numero cambia, resta la lettura ogni due secondi.
    private func listenToMissionControl() {
        condition.lock()
        let first = !listeningToMissionControl
        listeningToMissionControl = true
        condition.unlock()
        typealias MainConnection = @convention(c) () -> Int32
        typealias Notified = @convention(c) (UInt32, UnsafeMutableRawPointer?, Int, UnsafeMutableRawPointer?, Int32) -> Void
        typealias Register = @convention(c) (Int32, Notified, UInt32, UnsafeMutableRawPointer?) -> Int32
        guard first, let sky = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_NOW),
              let main = dlsym(sky, "SLSMainConnectionID"), let register = dlsym(sky, "SLSRegisterConnectionNotifyProc") else { return }
        let connection = unsafeBitCast(main, to: MainConnection.self)()
        guard connection != 0 else { return }
        let result = unsafeBitCast(register, to: Register.self)(connection, { _, _, _, _, _ in
            DockTracker.shared.missionControlChanged()
        }, 1508, nil)
        if Self.trace { print("[dock] in ascolto di Mission Control (\(result))"); fflush(stdout) }
    }

    private func missionControlChanged() {
        if Self.trace { print(String(format: "[dock] %.4f Mission Control", CACurrentMediaTime())); fflush(stdout) }
        kick(for: 3)
    }

    /// Il bordo basso dello schermo del Dock, nelle coordinate dell'Accessibilità: serve a capire se il Dock è nascosto.
    func setScreenBottom(_ y: CGFloat) {
        condition.lock()
        screenBottom = y
        condition.unlock()
    }

    /// L'ultima lettura, la velocità verticale (punti al secondo, verso il basso positiva) se si sta muovendo, quanto è
    /// vecchia, e se il riquadro è cambiato da poco.
    func snapshot() -> (reading: DockReading?, velocity: CGFloat, age: CFTimeInterval, moving: Bool) {
        condition.lock()
        defer { condition.unlock() }
        let now = CACurrentMediaTime()
        var velocity: CGFloat = 0
        if let latest, yTime > previousTime, now - yTime < 0.03 {
            velocity = (latest.list.minY - previousY) / CGFloat(yTime - previousTime)
        }
        return (latest, velocity, now - sampleTime, now < hotUntil)
    }

    /// Il thread principale ha visto il cambio: il prossimo verrà annunciato di nuovo.
    func acknowledge() {
        condition.lock()
        notified = false
        condition.unlock()
    }

    // MARK: Lettura

    private func loop(_ mine: Int) {
        // Quello che serve per leggere è di questo thread soltanto: due accensioni ravvicinate non se lo contendono.
        let reader = DockReader()
        var lastGood: DockReading?
        var lastGoodTime: CFTimeInterval = 0
        while true {
            condition.lock()
            guard running, generation == mine else { condition.unlock(); return }
            condition.unlock()

            var reading = reader.read()
            let now = CACurrentMediaTime()
            // Una lettura fallita (il Dock occupato per un attimo) non vuol dire che il Dock è sparito: per mezzo
            // secondo vale l'ultima buona. Solo se continua a mancare il vassoio se ne va.
            if let reading {
                lastGood = reading
                lastGoodTime = now
            } else if let lastGood, now - lastGoodTime < 0.6 {
                reading = lastGood
            }

            condition.lock()
            guard running, generation == mine else { condition.unlock(); return }
            var announce: (@MainActor () -> Void)?
            if reading != latest {
                if let reading, reading.list.minY != (latest?.list.minY ?? reading.list.minY) {
                    previousY = latest?.list.minY ?? reading.list.minY
                    // Dopo una sosta il tempo dell'altezza di prima non dice niente: vale l'intervallo solito fra due
                    // valori del Dock (9 ms), così anche il primo fotogramma della salita ha il suo anticipo.
                    previousTime = now - yTime > 0.05 ? now - 0.009 : yTime
                    yTime = now
                }
                latest = reading
                sampleTime = now
                hotUntil = now + 0.35
                if !notified { notified = true; announce = handler }
                if Self.trace, let reading {
                    print(String(format: "[dock] %.4f y=%.1f x=%.1f w=%.1f", now, reading.list.minY, reading.list.minX, reading.list.width))
                    fflush(stdout)
                }
            }
            let hidden = (latest?.list.minY ?? .greatestFiniteMagnitude) >= screenBottom - 1
            if latest != nil {
                if hidden {
                    autohides = true
                    shownSince = 0
                } else {
                    if shownSince == 0 { shownSince = now }
                    // Un minuto fuori senza mai nascondersi: non è (più) a scomparsa, si torna a guardare di rado.
                    if now - shownSince > 60 { autohides = false }
                }
            }
            let idle: TimeInterval = autohides && !hidden ? 0.25 : 2
            let interval: TimeInterval = now < hotUntil ? 0.004 : now < warmUntil ? 0.0125 : idle
            sleepingLong = interval > 0.1
            condition.wait(until: Date(timeIntervalSinceNow: interval))
            if generation == mine { sleepingLong = false }
            condition.unlock()

            if let announce {
                DispatchQueue.main.async { MainActor.assumeIsolated { announce() } }
            }
        }
    }
}

/// Le letture dell'Accessibilità, con quello che ricordano fra una e l'altra. Usato da un thread solo.
private final class DockReader {
    private var listElement: AXUIElement?
    private var frameAttributeWorks = true
    private var frameAttributeFailures = 0
    private var measuredHeight: CGFloat = -1
    private var plateTop: CGFloat = 5
    private var plateHeight: CGFloat = 49
    private var horizontal = true
    private var lastDiscovery: CFTimeInterval = 0

    func read() -> DockReading? {
        guard AXIsProcessTrusted() else { listElement = nil; return nil }
        if listElement == nil { discover() }
        guard let list = listElement else { return nil }
        guard let frame = frame(of: list) else {
            // Il Dock è stato riavviato o è occupato: si ricomincia a cercarlo.
            listElement = nil
            return nil
        }
        if frame.height != measuredHeight { measure(list, frame: frame) }
        return DockReading(list: frame, plateTop: plateTop, plateHeight: plateHeight, horizontal: horizontal)
    }

    /// Trova la lista delle icone del Dock. Al massimo una volta al secondo: se il Dock non c'è, non si insiste.
    private func discover() {
        let now = CACurrentMediaTime()
        guard now - lastDiscovery > 1 else { return }
        lastDiscovery = now
        guard let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first else { return }
        let app = AXUIElementCreateApplication(dock.processIdentifier)
        // Una lettura che non torna non deve tenere fermo il thread per i sei secondi di serie.
        AXUIElementSetMessagingTimeout(app, 0.4)
        guard let children: [AXUIElement] = attribute(app, kAXChildrenAttribute) else { return }
        for child in children {
            guard let role: String = attribute(child, kAXRoleAttribute), role == kAXListRole else { continue }
            AXUIElementSetMessagingTimeout(child, 0.4)
            listElement = child
            measuredHeight = -1
            // Un Dock nuovo si riprova da capo, anche con la lettura in un colpo solo.
            frameAttributeWorks = true
            frameAttributeFailures = 0
            return
        }
    }

    /// Il vassoio di vetro coincide con il riquadro di un'icona: si misura quando la lista cambia altezza (cioè quando
    /// cambia la grandezza delle icone). Un'icona ingrandita dal puntatore darebbe una misura falsa: vale solo se sta
    /// dentro la lista, cioè se non è più alta di lei.
    private func measure(_ list: AXUIElement, frame: CGRect) {
        measuredHeight = frame.height
        let orientation: String? = attribute(list, kAXOrientationAttribute)
        horizontal = orientation != kAXVerticalOrientationValue
        plateTop = 5
        plateHeight = frame.height
        guard let items: [AXUIElement] = attribute(list, kAXChildrenAttribute), let last = items.last,
              let item = self.frame(of: last, remember: false), item.height > 8, item.height <= frame.height + 1,
              item.minY >= frame.minY, item.minY - frame.minY < 16 else { return }
        plateTop = item.minY - frame.minY
        plateHeight = item.height
    }

    private func attribute<T>(_ element: AXUIElement, _ name: String) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value as? T
    }

    /// Il riquadro in una lettura sola se il Dock la offre (`AXFrame`), se no posizione e misura. Si rinuncia alla
    /// lettura unica solo se fallisce mentre l'altra strada riesce: un Dock occupato fa fallire tutte e due, e passa.
    private func frame(of element: AXUIElement, remember: Bool = true) -> CGRect? {
        if frameAttributeWorks {
            var value: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, "AXFrame" as CFString, &value) == .success, let value,
               CFGetTypeID(value) == AXValueGetTypeID() {
                var rect = CGRect.zero
                if AXValueGetValue(value as! AXValue, .cgRect, &rect) {
                    if remember { frameAttributeFailures = 0 }
                    return rect
                }
            }
        }
        var position: CFTypeRef?, size: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &position) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &size) == .success,
              let position, let size, CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero, extent = CGSize.zero
        AXValueGetValue(position as! AXValue, .cgPoint, &point)
        AXValueGetValue(size as! AXValue, .cgSize, &extent)
        if remember, frameAttributeWorks {
            frameAttributeFailures += 1
            if frameAttributeFailures >= 3 { frameAttributeWorks = false }
        }
        return CGRect(origin: point, size: extent)
    }
}
