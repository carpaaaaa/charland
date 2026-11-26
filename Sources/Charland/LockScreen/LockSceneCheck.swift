import AppKit
import SwiftUI

/// `Charland --prova-scena`: la scena della copertina (Constellation e Dynamic) segue il brano e la sua copertina.
/// Fuori schermo, senza musica vera e senza rete: stampa una riga per prova ed esce con 0 se è tutto a posto.
///
/// Rifà quello che succede al cambio brano: da «In riproduzione» il titolo nuovo arriva spesso prima della sua foto, e
/// in quel momento la copertina del brano è ancora quella del brano di prima. Fino al 19 novembre 2026 la scena nata
/// lì restava per tutta la canzone; un brano senza copertina teneva quella di prima, e in Dynamic non usciva il testo.
extension LockChecks {
    static func sceneCheck() async -> Bool {
        /// Una copertina finta, di un colore. Disegnata subito in una bitmap: un'immagine che si disegna quando serve
        /// (`NSImage(size:flipped:drawingHandler:)`) verrebbe disegnata dal thread che prepara la scena, e il suo
        /// blocco, nato qui sul thread principale, lì fa chiudere l'app.
        func art(_ hue: CGFloat) -> NSImage {
            let side = 600
            let space = CGColorSpace(name: CGColorSpace.sRGB)!
            let ctx = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            let colors = [NSColor(hue: hue, saturation: 0.8, brightness: 0.9, alpha: 1).cgColor,
                          NSColor(hue: hue, saturation: 0.9, brightness: 0.2, alpha: 1).cgColor] as CFArray
            if let gradient = CGGradient(colorsSpace: space, colors: colors, locations: [0, 1]) {
                ctx.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: side, y: side), options: [])
            }
            return NSImage(cgImage: ctx.makeImage()!, size: NSSize(width: side, height: side))
        }
        /// Un brano finto. Senza app: così non parte la richiesta della copertina grande al catalogo.
        func song(_ title: String, _ image: NSImage?) -> NowPlayingSnapshot {
            NowPlayingSnapshot(title: title, artist: "Prova", album: title, duration: 200, elapsed: 1, anchor: Date(), rate: 1,
                               playing: true, app: nil, artwork: image, tint: .white)
        }
        func wait(_ seconds: Double, _ done: () -> Bool) async -> Bool {
            let end = Date().addingTimeInterval(seconds)
            while Date() < end {
                if done() { return true }
                try? await Task.sleep(for: .milliseconds(40))
            }
            return done()
        }
        var allGood = true
        func report(_ ok: Bool, _ what: String) {
            if !ok { allGood = false }
            print(ok ? "ok  " : "NO  ", what)
            fflush(stdout)
        }

        let model = LockModel()
        model.direct = true
        let red = art(0.0), blue = art(0.6), green = art(0.33)
        func play(_ snapshot: NowPlayingSnapshot) {
            model.music = snapshot
            Mappa.ensure(model)
        }

        // 1. Un brano con la sua copertina.
        play(song("Primo", red))
        let first = model.music?.trackKey ?? ""
        report(await wait(5) { model.mappa.scene?.key == first && model.mappa.scene?.cover === red }, "il primo brano ha la sua scena")

        // 2. Cambio brano lento: arriva il titolo del secondo con ancora la copertina del primo, la scena sbagliata fa
        //    in tempo a nascere, poi arriva la copertina giusta.
        play(song("Secondo", red))
        let second = model.music?.trackKey ?? ""
        _ = await wait(5) { model.mappa.scene?.key == second }
        play(song("Secondo", blue))
        report(await wait(5) { model.mappa.scene?.key == second && model.mappa.scene?.cover === blue },
               "copertina arrivata dopo il titolo: la scena del brano viene rifatta con la sua")

        // 3. Cambio brano svelto: la copertina giusta arriva prima che la scena sbagliata sia pronta.
        play(song("Terzo", blue))
        let third = model.music?.trackKey ?? ""
        play(song("Terzo", green))
        let rightOne = await wait(5) { model.mappa.scene?.key == third && model.mappa.scene?.cover === green }
        // ...e quella sbagliata, che finisce di prepararsi dopo, non le passa sopra
        try? await Task.sleep(for: .milliseconds(700))
        report(rightOne && model.mappa.scene?.cover === green, "copertina arrivata subito dopo il titolo: resta quella giusta")

        // 4. Stesso disco: brano nuovo, stessa copertina. Niente da rifare due volte.
        play(song("Quarto", green))
        let fourth = model.music?.trackKey ?? ""
        report(await wait(5) { model.mappa.scene?.key == fourth && model.mappa.scene?.cover === green }, "brano nuovo dello stesso disco: scena sua, stessa copertina")

        // 5. Un brano senza copertina: per un attimo resta la scena di prima (fra un brano e l'altro la copertina manca
        //    spesso per un istante), poi se ne va.
        play(song("Quinto", nil))
        try? await Task.sleep(for: .milliseconds(600))
        report(model.mappa.scene?.key == fourth, "brano senza copertina: per un attimo la scena di prima resta (niente passaggio dal nero)")
        report(await wait(4) { model.mappa.scene == nil }, "brano senza copertina: dopo due secondi la scena di prima se ne va")

        // 6. In Dynamic, quel brano ha comunque il suo piano: le parole escono.
        if Montaggio.active {
            model.lyrics = sampleLyrics
            model.rows = sampleLyrics.rows(trackDuration: 200)
            let planned = await wait(5) {
                Montaggio.plan(model)
                return Montaggio.fits(model) && model.montaggio.plan != nil
            }
            report(planned, "brano senza copertina in Dynamic: il piano del testo c'è")
        } else {
            print("--   brano senza copertina in Dynamic: saltata (lo stile scelto non è Dynamic; CHARLAND_BLOCCO_TEMA=montaggio per provarla)")
        }

        // 7. La copertina torna (un altro brano): la scena rinasce.
        play(song("Sesto", red))
        let sixth = model.music?.trackKey ?? ""
        report(await wait(5) { model.mappa.scene?.key == sixth && model.mappa.scene?.cover === red }, "dopo un brano senza copertina, il brano dopo ha la sua scena")

        print(allGood ? "Tutto a posto." : "Qualcosa non torna.")
        return allGood
    }
}
