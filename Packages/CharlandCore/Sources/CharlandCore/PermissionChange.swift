/// I permessi di macOS che Charland usa per i tasti (Accessibilità, Monitoraggio input) possono arrivare dopo l'avvio.
/// Quello che parte all'avvio solo con il permesso (volume e luminosità, scorciatoie di soli modificatori, la x rossa)
/// va riacceso quando uno dei due passa da negato a concesso (carpa, 26 novembre 2026: «una volta che ho permesso
/// tutto non si sono messi gli slider del volume e luminosità, ho dovuto disattivarli e riattivarli»).
public struct PermissionState: Equatable, Sendable {
    public var accessibility: Bool
    public var inputMonitoring: Bool
    public init(accessibility: Bool, inputMonitoring: Bool) {
        self.accessibility = accessibility
        self.inputMonitoring = inputMonitoring
    }

    /// Vero se da `previous` a questo stato almeno un permesso è stato concesso.
    public func gainedSince(_ previous: PermissionState) -> Bool {
        (accessibility && !previous.accessibility) || (inputMonitoring && !previous.inputMonitoring)
    }
}
