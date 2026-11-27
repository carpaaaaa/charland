import SwiftUI

/// Impostazioni › Blocco schermo.
struct LockScreenPane: View {
    @Bindable private var features = Features.shared
    @Bindable private var lock = LockSettings.shared

    private static let slotTitles: [LocalizedStringKey] = ["Primo posto", "Secondo posto", "Terzo posto", "Quarto posto"]

    var body: some View {
        Form {
            Section {
                Toggle("Charland sul blocco schermo", isOn: $features.lockScreen)
            } footer: {
                Text("A schermo bloccato Charland mostra quattro segni sotto l'orologio e, con la musica, un lettore al centro. Non tocca l'orologio né l'accesso di macOS.")
            }

            Section {
                ForEach(0..<4, id: \.self) { index in
                    Picker(Self.slotTitles[index], selection: Binding(get: { lock.slots[index] }, set: { lock.slots[index] = $0 })) {
                        ForEach(LockSignKind.allCases) { kind in Text(kind.title).tag(kind) }
                    }
                }
                Toggle("Mostra i titoli degli impegni", isOn: $lock.showsTitles)
            } header: {
                Text("Segni sotto l'orologio")
            } footer: {
                Text("Sul blocco li può leggere chiunque passi: spento, del prossimo impegno si vede solo l'ora.")
            }

            Section {
                Toggle("Lettore al centro", isOn: $lock.player)
                Toggle("Testo delle canzoni", isOn: $lock.lyrics)
                Toggle("Luci nei colori della copertina", isOn: $lock.ambience)
                Toggle(isOn: $lock.spacePlays) {
                    Text("Spazio per mettere in pausa")
                    Text("A schermo bloccato, con la musica, lo spazio mette in pausa e fa ripartire il brano, in tutti gli stili. Mentre scrivi la password lo spazio resta della password.")
                }
                Picker("Con la musica lo schermo resta acceso", selection: $lock.awakeMinutes) {
                    ForEach(LockSettings.awakeChoices, id: \.self) { minutes in
                        switch minutes {
                        case 0: Text("Sempre").tag(minutes)
                        case -1: Text("Come macOS").tag(minutes)
                        case 60: Text("1 ora").tag(minutes)
                        case 1: Text("1 minuto").tag(minutes)
                        default: Text("\(minutes) minuti").tag(minutes)
                        }
                    }
                }
            } header: {
                Text("Musica")
            } footer: {
                Text("Bloccando il Mac mentre la musica suona lo schermo resta acceso, finché suona; in pausa e senza musica si spegne come sempre. Premi la foto del lettore per aprire la copertina: foto grande e testo che si illumina parola per parola. Per cercare il testo Charland manda titolo, artista e durata del brano a lrclib.net e, se lì mancano i tempi delle parole, a lrc.red, solo per le app di musica; in Constellation e Dynamic, quando cambia brano a schermo bloccato, manda titolo, artista e la regione del Mac anche ad Apple (itunes.apple.com) per avere la copertina grande. Al primo tasto la copertina si richiude e torna il campo della password.")
            }

            Section {
                Picker("Stile del testo", selection: $lock.theme) {
                    ForEach(LockTheme.allCases) { theme in Text(theme.title).tag(theme) }
                }
                .pickerStyle(.segmented)
                if lock.theme == .montaggio {
                    Toggle(isOn: $lock.montaggioStill) {
                        Text("Sfondo fermo")
                        Text("La copertina intera e sfocata come in Constellation, senza tagli né bande: si muovono solo le parole.")
                    }
                }
                Toggle(isOn: $lock.edge) {
                    Text("Bordo luminoso")
                    Text("Con la copertina aperta una luce nei colori della copertina gira attorno allo schermo, in tutti gli stili.")
                }
                Picker("Aprendo la copertina", selection: Binding(get: { lock.lyricsAtOpen }, set: { lock.opensWithLyrics = $0 })) {
                    Text("Col testo").tag(true)
                    Text("Senza testo").tag(false)
                }
                .pickerStyle(.segmented)
            } header: {
                Text("Copertina aperta")
            } footer: {
                Text("Simple è la copertina come nell'app Musica, col testo in colonna. In Constellation la copertina prende tutto lo schermo e la canzone ci disegna sopra una costellazione per strofa: ogni parola è una stella e le più importanti sono più grandi. Dynamic monta la canzone come un edit: ogni verso è un'inquadratura nuova della copertina e le parole arrivano una alla volta, con un colpo su quelle che contano. Sotto la foto c'è il tasto del testo: lo accendi o lo spegni quando vuoi.")
            }

            Section {
                Button("Blocca lo schermo adesso") { LockScreen.lockNow() }
            } footer: {
                Text("Per vedere subito com'è: si sblocca come sempre.")
            }
        }
        .formStyle(.grouped)
    }
}

extension LockScreen {
    /// Blocca lo schermo subito, come ⌃⌘Q: per provare il blocco dalle impostazioni.
    static func lockNow() {
        guard let login = dlopen("/System/Library/PrivateFrameworks/login.framework/Versions/Current/login", RTLD_NOW),
              let symbol = dlsym(login, "SACLockScreenImmediate") else { return }
        _ = unsafeBitCast(symbol, to: (@convention(c) () -> Int32).self)()
    }
}
