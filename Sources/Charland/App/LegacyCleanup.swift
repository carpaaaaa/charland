import Foundation
import Security
import CharlandCore

/// Fino alla 1.5 Charland era a pagamento: la prova e la licenza lasciavano dati sul Mac (preferenze, voci del
/// Portachiavi con la chiave di licenza, un file nascosto). Dalla 1.6 non servono più: la prima volta che parte una build
/// ufficiale li toglie, una volta sola. Solo nelle build ufficiali: una build compilata da chi sviluppa, con un'altra
/// firma, non potrebbe cancellare le voci del Portachiavi dell'app ufficiale e segnerebbe il lavoro come fatto.
enum LegacyCleanup {
    static func run() {
        #if CHARLAND_OFFICIAL
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: "legacyLicenseCleaned") else { return }
        ["trialStart", "licenseEnded", "installCode", "licenseKey"].forEach(defaults.removeObject(forKey:))
        let items: [(String, [String])] = [
            ("com.charstudio.charland.license", ["record", "trial-start", "entitlement"]),
            ("com.charstudio.charland.state", ["s", "v"]),
        ]
        for (service, accounts) in items {
            for account in accounts {
                let query: [CFString: Any] = [
                    kSecClass: kSecClassGenericPassword,
                    kSecAttrService: service,
                    kSecAttrAccount: account,
                    kSecUseAuthenticationUI: kSecUseAuthenticationUISkip,
                ]
                SecItemDelete(query as CFDictionary)
            }
        }
        if let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            try? FileManager.default.removeItem(at: base.appendingPathComponent("\(Identity.supportFolder)/.indice"))
        }
        defaults.set(true, forKey: "legacyLicenseCleaned")
        #endif
    }
}
