import Foundation
import IOKit.ps

// L'aiutante di sistema di Charland (vedi `CharlandHelperProtocol`). Lo avvia launchd quando Charland lo chiama e
// se ne va da solo quando non serve più: a riposo non c'è nessun processo.

/// `pmset -a disablesleep 0|1`: il sonno a coperchio chiuso spento o normale.
@discardableResult
func setSleepDisabled(_ on: Bool) -> Bool {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
    p.arguments = ["-a", "disablesleep", on ? "1" : "0"]
    p.standardOutput = FileHandle.nullDevice
    p.standardError = FileHandle.nullDevice
    do { try p.run() } catch { return false }
    p.waitUntilExit()
    return p.terminationStatus == 0
}

/// A batteria e al 10% o meno.
func batteryCritical() -> Bool {
    guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
          let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return false }
    for source in list {
        guard let d = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any] else { continue }
        let onBattery = (d[kIOPSPowerSourceStateKey] as? String) == kIOPSBatteryPowerValue
        if onBattery, let level = d[kIOPSCurrentCapacityKey] as? Int, level <= 10 { return true }
    }
    return false
}

final class Helper: NSObject, NSXPCListenerDelegate, CharlandHelperProtocol {
    private let queue = DispatchQueue(label: "charland.aiutante")
    /// La connessione di Charland che tiene acceso il coperchio chiuso.
    private weak var holder: NSXPCConnection?
    private var engaged = false
    private var deadline: Double = 0
    private var watch: DispatchSourceTimer?
    private var exitWork: DispatchWorkItem?

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        connection.exportedInterface = NSXPCInterface(with: CharlandHelperProtocol.self)
        connection.exportedObject = self
        // Charland chiusa, caduta o che ha chiuso la connessione: il sonno torna normale. Si confronta l'identità e non
        // la connessione debole: quando arriva l'avviso quella di una semplice domanda sullo stato può essere già
        // sparita (nil), e prima questo bastava a rimettere il sonno mentre Charland teneva ancora il coperchio chiuso.
        let id = ObjectIdentifier(connection)
        connection.invalidationHandler = { [weak self] in self?.lost(id) }
        connection.interruptionHandler = { [weak self] in self?.lost(id) }
        connection.resume()
        queue.async { self.exitWork?.cancel() }
        return true
    }

    func setClosedLidAwake(_ on: Bool, deadline: Double, reply: @escaping (Bool) -> Void) {
        let caller = NSXPCConnection.current()
        queue.async {
            if on {
                self.holder = caller
                self.deadline = deadline
                self.engaged = setSleepDisabled(true)
                if self.engaged { self.startWatch() } else { self.holder = nil }
                reply(self.engaged)
            } else {
                self.release()
                reply(true)
            }
        }
    }

    func status(reply: @escaping (String, Bool) -> Void) {
        queue.async { reply(CharlandHelperInfo.version, self.engaged) }
    }

    private func lost(_ id: ObjectIdentifier) {
        queue.async {
            if self.engaged, self.holder.map(ObjectIdentifier.init) == id || self.holder == nil { self.release() }
            self.scheduleExit()
        }
    }

    /// Ogni cinque secondi: tempo scaduto o batteria al 10% spengono tutto.
    private func startWatch() {
        watch?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 5, repeating: 5, leeway: .seconds(1))
        timer.setEventHandler { [weak self] in
            guard let self, self.engaged else { return }
            let expired = self.deadline > 0 && Date().timeIntervalSince1970 >= self.deadline
            if expired || batteryCritical() || self.holder == nil { self.release() }
        }
        timer.resume()
        watch = timer
    }

    private func release() {
        watch?.cancel()
        watch = nil
        holder = nil
        deadline = 0
        setSleepDisabled(false)
        engaged = false
        scheduleExit()
    }

    /// Senza niente da fare per mezzo minuto se ne va: launchd lo riavvia alla prossima chiamata.
    private func scheduleExit() {
        exitWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.engaged else { return }
            exit(0)
        }
        exitWork = work
        queue.asyncAfter(deadline: .now() + 30, execute: work)
    }

    func begin() {
        // Appena avviato nessuno ha chiesto niente: se un avvio precedente era caduto a metà, il sonno torna normale.
        queue.async {
            setSleepDisabled(false)
            self.scheduleExit()
        }
    }
}

let helper = Helper()
let listener = NSXPCListener(machServiceName: CharlandHelperInfo.label)
listener.setConnectionCodeSigningRequirement(CharlandHelperInfo.clientRequirement)
listener.delegate = helper
listener.resume()
helper.begin()
dispatchMain()
