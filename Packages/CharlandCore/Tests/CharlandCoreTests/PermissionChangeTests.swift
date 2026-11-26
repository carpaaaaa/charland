import Testing
@testable import CharlandCore

@Suite("Permessi arrivati dopo l'avvio")
struct PermissionChangeTests {
    @Test("si riaccende solo quando un permesso passa da negato a concesso")
    func gained() {
        let none = PermissionState(accessibility: false, inputMonitoring: false)
        let ax = PermissionState(accessibility: true, inputMonitoring: false)
        let all = PermissionState(accessibility: true, inputMonitoring: true)
        #expect(ax.gainedSince(none))
        #expect(all.gainedSince(ax))
        #expect(!all.gainedSince(all))
        #expect(!none.gainedSince(all))
        #expect(!ax.gainedSince(all))
    }
}
