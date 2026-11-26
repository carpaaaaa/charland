import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// L'app della musica scelta in Impostazioni (carpa, 18 novembre 2026: «in alto a sinistra il simbolo di una nota dove se
/// la premi ti apre l'app musica che selezioni da settings, di default è Apple Music»). La nota della riproduzione vuota
/// apre lei, e il ▶︎ della riproduzione vuota la fa partire quando nessun lettore recente risponde.
@MainActor @Observable
final class MusicApp {
    static let shared = MusicApp()
    static let key = "musicAppBundleID"
    static let appleMusic = "com.apple.Music"

    /// Le app della musica che si propongono se sono installate. Le altre si scelgono con «Altra app…».
    static let known = [appleMusic, "com.spotify.client", "com.tidal.desktop", "com.deezer.deezer-desktop",
                        "com.amazon.music", "tv.plex.plexamp", "co.brushedtype.doppler-macos", "com.coppertino.Vox"]

    var bundleID: String {
        didSet { UserDefaults.standard.set(bundleID, forKey: Self.key) }
    }

    private init() {
        bundleID = UserDefaults.standard.string(forKey: Self.key) ?? Self.appleMusic
    }

    /// Le scelte del menu: quelle installate, Apple Music sempre e quella scelta anche se è fuori dall'elenco.
    var choices: [String] {
        var ids = Self.known.filter { $0 == Self.appleMusic || Self.url(for: $0) != nil }
        if !ids.contains(bundleID) { ids.append(bundleID) }
        return ids
    }

    static func url(for id: String) -> URL? { NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) }

    /// Il nome da mostrare: «Music» per Apple Music su un Mac in inglese, come lo chiama il Finder.
    static func name(for id: String) -> String {
        guard let url = url(for: id) else { return id == appleMusic ? "Apple Music" : id }
        return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }

    var name: String { Self.name(for: bundleID) }

    static func icon(for id: String) -> NSImage? {
        guard let url = url(for: id) else { return nil }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        icon.size = NSSize(width: 16, height: 16)
        return icon
    }

    /// Apre l'app scelta, davanti.
    func open() {
        // Come «Apri Charcal» nel Dock: da un'app in secondo piano macOS non lascia attivare un'altra app senza
        // cederle l'attivazione (provato il 18 novembre 2026: con `openApplication` da solo Musica restava dietro).
        DockLaunch.open(bundle: Self.url(for: bundleID) != nil ? bundleID : Self.appleMusic)
    }

    /// Fa partire la musica nell'app scelta. Musica e Spotify ricevono «play» (riprendono l'ultima cosa ascoltata) senza
    /// venire davanti; serve l'Automazione, che macOS chiede la prima volta. Negata, o con un'altra app, la si apre.
    func play() {
        let id = Self.url(for: bundleID) != nil ? bundleID : Self.appleMusic
        guard id == Self.appleMusic || id == "com.spotify.client" else { open(); return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", "tell application id \"\(id)\" to play"]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        p.terminationHandler = { ended in
            guard ended.terminationStatus != 0 else { return }
            Task { @MainActor in MusicApp.shared.open() }
        }
        do { try p.run() } catch { open() }
    }

    /// «Altra app…»: un'app qualunque dalla cartella Applicazioni.
    func chooseOther() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowsMultipleSelection = false
        panel.prompt = String(localized: "Scegli")
        NSApp.activate()
        guard panel.runModal() == .OK, let url = panel.url, let id = Bundle(url: url)?.bundleIdentifier else { return }
        bundleID = id
    }
}

/// La scelta dell'app della musica, in Impostazioni › Generale.
struct MusicAppPicker: View {
    @Bindable private var app = MusicApp.shared
    private static let other = "__altra"

    var body: some View {
        Picker("App della musica", selection: Binding(get: { app.bundleID }, set: { value in
            if value == Self.other { app.chooseOther() } else { app.bundleID = value }
        })) {
            ForEach(app.choices, id: \.self) { id in
                Label {
                    Text(MusicApp.name(for: id))
                } icon: {
                    if let icon = MusicApp.icon(for: id) { Image(nsImage: icon) }
                }
                .tag(id)
            }
            Divider()
            Text("Altra app…").tag(Self.other)
        }
    }
}
