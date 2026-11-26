import SwiftUI
import CharlandCore

/// Tutto quello che Charland disegna sul blocco schermo, in una vista sola a tutto schermo.
///
/// Due viste che si danno il cambio in dissolvenza (carpa, 18 novembre 2026: «chill, con un fade, smooth ma semplice»):
/// - **chiusa**: i segni sotto l'orologio e il lettore di vetro. Non tocca niente di macOS;
/// - **aperta**: sfondo, orologio nostro, foto grande, comandi e testo. Copre il blocco di macOS finché non si preme un tasto.
///
/// Niente animazioni di SwiftUI: ogni passaggio è un numero da 0 a 1 che `LockScreen` porta avanti con un suo timer
/// (`LockModel.advance`). Nelle finestre del blocco l'orologio delle animazioni di SwiftUI non gira bene: restavano
/// a metà (la riga cantata grigia) e andavano a scatti.
struct LockStage: View {
    let model: LockModel
    /// Negli scatti fuori schermo il vetro di sistema non si disegna: al suo posto un fondo scuro.
    var offscreen = false

    var body: some View {
        let L = model.layout
        let shown = LockModel.ease(model.shownT) * (1 - LockModel.ease(model.leaveT))
        let present = LockModel.ease(model.presentT)
        let open = LockModel.ease(model.openT)

        // Le due viste ci sono sempre, una delle due a opacità zero: crearle al momento del tocco costava
        // un fotogramma lungo proprio all'inizio della dissolvenza (fino a 80 ms sul blocco vero).
        // «Mappa» si apre crescendo dalla foto del lettore, e sta sopra il lettore e i segni: la copertina gli passa
        // sopra salendo e ci si posa sopra tornando. I segni se ne vanno prima che la copertina li raggiunga; il
        // lettore resta dov'è finché è coperto e torna mentre la foto scende
        // (vale per i due temi a tutto schermo, Costellazione e Montaggio: `MappaView` sceglie la scena)
        let mappa = LockSettings.shared.theme != .easy
        ZStack(alignment: .topLeading) {
            if !mappa {
                LockOpenView(model: model, L: L, offscreen: offscreen)
                    .opacity(open * present)
                    .allowsHitTesting(model.open)
            }
            signs(L)
                .opacity(1 - (mappa ? LockModel.ease(model.openT * 4.5) : open))
                .offset(y: (1 - LockModel.ease(model.shownT)) * 10)
            LockCardView(model: model, L: L, offscreen: offscreen)
                .opacity(present * (1 - (mappa ? LockModel.ease((model.openT - 0.3) / 0.3) : open)))
                .offset(y: (1 - present) * 10)
                .allowsHitTesting(!model.open)
            if mappa {
                MappaView(model: model, L: L, offscreen: offscreen)
                    .opacity(present)
                    .allowsHitTesting(model.open)
            }
        }
        .frame(width: model.size.width, height: model.size.height, alignment: .topLeading)
        .opacity(shown)
        .environment(\.colorScheme, .dark)
    }

    private func signs(_ L: LockLayout) -> some View {
        HStack(spacing: 34) {
            ForEach(model.signs) { sign in LockSignView(sign: sign) }
        }
        .frame(width: model.size.width, height: 46)
        .scaleEffect(L.signScale)
        .offset(y: L.signsY - 23)
        .allowsHitTesting(false)
    }
}

// MARK: - Chiusa: il lettore

/// Il lettore al centro, sopra l'avatar: una lastra di vetro con foto, titolo, barra e comandi, come su iPhone.
/// Sul blocco vero i clic li prende la finestrella `LockHitView`; nella prova in finestra li prende questa vista.
struct LockCardView: View {
    let model: LockModel
    var L: LockLayout
    var offscreen: Bool

    var body: some View {
        let c = L.card
        let shape = RoundedRectangle(cornerRadius: LockLayout.cardRadius, style: .continuous)
        let music = model.music
        let mix = LockModel.ease(model.trackT)
        ZStack(alignment: .topLeading) {
            Group { if offscreen { shape.fill(Color(white: 0.1).opacity(0.86)) } else { CharlandGlassFill(shape: shape) } }
                .frame(width: c.width, height: c.height)
                .shadow(color: .black.opacity(CharlandGlass.shadowOpacity), radius: CharlandGlass.shadowRadius, y: CharlandGlass.shadowY)

            LockArtwork(image: music?.artwork, old: model.oldArtwork, mix: mix, radius: 16)
                .frame(width: 64, height: 64)
                .contentShape(Rectangle())
                .onTapGesture { LockScreen.shared.toggleOpen() }
                .offset(x: 14, y: 14)

            Text(music?.title ?? "").font(.system(size: 17, weight: .semibold)).foregroundStyle(.white).lineLimit(1)
                .frame(width: 300, alignment: .leading).opacity(mix).offset(x: 92, y: 21)
            Text(music?.artist ?? "").font(.system(size: 14, weight: .medium)).foregroundStyle(.white.opacity(0.62)).lineLimit(1)
                .frame(width: 300, alignment: .leading).opacity(mix).offset(x: 92, y: 44)
            LockWave(color: music?.tint ?? .white, clock: nil)
                .offset(x: c.width - 14 - 22, y: 38)
            LockScrubber(model: model, width: 412, interactive: model.direct)
                .offset(x: 14, y: 94)
            LockControls(playing: model.playing, interactive: model.direct)
                .offset(x: c.width / 2 - 94, y: 122)
        }
        .frame(width: c.width, height: c.height, alignment: .topLeading)
        .offset(x: c.minX, y: c.minY)
    }
}

// MARK: - Aperta: la copertina

/// La copertina aperta, come l'app Musica: foto grande con titolo, barra e comandi sotto, testo a destra.
/// Senza testo (o col testo spento dal suo tasto) la foto sta al centro, più grande.
struct LockOpenView: View {
    let model: LockModel
    var L: LockLayout
    /// Negli scatti fuori schermo il vetro di sistema non si disegna.
    var offscreen = false

    var body: some View {
        let music = model.music
        let k = L.k
        let c = L.controlScale
        let te = CGFloat(LockModel.ease(model.textT))
        let a = Self.mix(L.art(open: true, text: false), L.art(open: true, text: true), te)
        // il testo entra quando la foto gli ha fatto posto, ed esce prima che lei torni al centro: non si passano mai sopra
        let column = LockModel.ease((model.textT - 0.6) / 0.4)
        let mix = LockModel.ease(model.trackT)
        let titleScale = 1.6 * k, artistScale = 1.3 * k
        let titleWidth = (a.width - 46 * k * te) / titleScale, artistWidth = a.width / artistScale
        let title = music?.title ?? "", artist = music?.artist ?? ""
        let titleNatural = min(titleWidth, Self.width(title, 17, .semibold)), artistNatural = min(artistWidth, Self.width(artist, 14, .medium))

        ZStack(alignment: .topLeading) {
            LockBackdrop(model: model, mix: mix)
            if LockSettings.shared.ambience { LockAmbience(model: model) }
            veils
            // il bordo luminoso anche qui (carpa, 19 novembre 2026: «voglio il bordo luminoso anche in quello simple»).
            // C'è da quando la copertina comincia ad aprirsi, mentre la vista è ancora trasparente: nasce prima che si veda
            if LockSettings.shared.edge, model.open || model.openT > 0 {
                MappaNeon(model: model)
            }
            LockClock(size: model.size, flat: offscreen)

            LockBigArtwork(model: model, mix: mix, radius: 30 * k)
                .frame(width: a.width, height: a.height)
                .contentShape(Rectangle())
                .onTapGesture { LockScreen.shared.toggleOpen() }
                .offset(x: a.minX, y: a.minY)

            // titolo e artista: a sinistra sotto la foto col testo, al centro senza
            Text(title).font(.system(size: 17, weight: .semibold)).foregroundStyle(.white).lineLimit(1)
                .frame(width: titleWidth, alignment: .leading)
                .scaleEffect(titleScale, anchor: .topLeading)
                .opacity(mix)
                .offset(x: a.minX + (1 - te) * (a.width - titleNatural * titleScale) / 2, y: a.maxY + 26 * k)
            Text(artist).font(.system(size: 14, weight: .medium)).foregroundStyle(.white.opacity(0.62)).lineLimit(1)
                .frame(width: artistWidth, alignment: .leading)
                .scaleEffect(artistScale, anchor: .topLeading)
                .opacity(mix)
                .offset(x: a.minX + (1 - te) * (a.width - artistNatural * artistScale) / 2, y: a.maxY + 63 * k)
            LockWave(color: music?.tint ?? .white, clock: model.playing ? model.live : nil)
                .scaleEffect(c, anchor: .trailing)
                .opacity(column)
                .offset(x: a.maxX - 22, y: a.maxY + 36 * k)

            LockScrubber(model: model, width: a.width, interactive: true, scale: c)
                .offset(x: a.minX, y: a.maxY + 108 * k - 8 * (c - 1))
            LockControls(playing: model.playing, interactive: true)
                .scaleEffect(c)
                .offset(x: a.midX - 94, y: a.maxY + 138 * k)
            // il tasto del testo: lo accende o lo spegne quando vuoi; se questo brano il testo non ce l'ha, il tasto non c'è
            LockLyricsButton(on: model.wantsColumn)
                .scaleEffect(c, anchor: .trailing)
                .opacity(LockModel.ease(model.buttonT))
                .allowsHitTesting(model.buttonT > 0.5)
                .offset(x: a.maxX - 42, y: a.maxY + 140 * k)

            // la colonna c'è appena c'è un testo, anche spenta: così accenderla non costa niente
            if !model.rows.isEmpty {
                LockLyricsColumn(model: model)
                    .frame(width: L.lyrics.width, height: L.lyrics.height, alignment: .topLeading)
                    .offset(x: L.lyrics.minX, y: L.lyrics.minY)
                    .opacity(column * LockModel.ease(model.lyricsT))
                    .allowsHitTesting(false)
            }
        }
        .frame(width: model.size.width, height: model.size.height, alignment: .topLeading)
    }

    /// Il nero dell'isola che scende e sfuma, e un filo di buio in basso: tengono leggibili orologio e comandi.
    private var veils: some View {
        ZStack {
            LinearGradient(stops: [.init(color: .black.opacity(0.82), location: 0), .init(color: .black.opacity(0.62), location: 0.09),
                                   .init(color: .black.opacity(0.36), location: 0.23), .init(color: .black.opacity(0.12), location: 0.37),
                                   .init(color: .clear, location: 0.54)], startPoint: .top, endPoint: .bottom)
            LinearGradient(stops: [.init(color: .black.opacity(0.5), location: 0), .init(color: .black.opacity(0.22), location: 0.2),
                                   .init(color: .clear, location: 0.44)], startPoint: .bottom, endPoint: .top)
        }
        .frame(width: model.size.width, height: model.size.height)
        .allowsHitTesting(false)
    }

    static func mix(_ a: CGRect, _ b: CGRect, _ t: CGFloat) -> CGRect {
        CGRect(x: a.minX + (b.minX - a.minX) * t, y: a.minY + (b.minY - a.minY) * t,
               width: a.width + (b.width - a.width) * t, height: a.height + (b.height - a.height) * t)
    }

    static func width(_ string: String, _ size: CGFloat, _ weight: NSFont.Weight) -> CGFloat {
        (string as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: size, weight: weight)]).width
    }
}

/// Lo sfondo della copertina aperta: la copertina (o il video, quando ci sarà) sfocata, che si muove appena.
/// Al cambio brano quello di prima si scioglie in quello nuovo.
struct LockBackdrop: View {
    let model: LockModel
    var mix: Double

    var body: some View {
        // si muove piano; in pausa `clock` si ferma e lui con lei
        let t = model.live.clock
        let scale = 1.19 + sin(t / 7.5) * 0.05
        let dx = sin(t / 9.2) * 0.016 * model.size.width, dy = cos(t / 11) * 0.014 * model.size.height
        let shade = model.oldBackdrop == nil ? model.shade : model.oldShade + (model.shade - model.oldShade) * mix
        // in pausa un velo in più
        let dim = min(0.86, shade + 0.16 * (1 - LockModel.ease(model.playT)))
        ZStack {
            Color.black
            if let old = model.oldBackdrop, mix < 1 { layer(old, scale, dx, dy).opacity(1 - mix) }
            if let image = model.backdrop { layer(image, scale, dx, dy).opacity(model.oldBackdrop == nil ? 1 : mix) }
            Color.black.opacity(dim)
        }
        .frame(width: model.size.width, height: model.size.height)
        .clipped()
        .allowsHitTesting(false)
    }

    private func layer(_ image: NSImage, _ scale: Double, _ dx: Double, _ dy: Double) -> some View {
        Image(nsImage: image).resizable().interpolation(.high).aspectRatio(contentMode: .fill)
            .frame(width: model.size.width, height: model.size.height)
            .scaleEffect(scale)
            .offset(x: dx, y: dy)
    }
}

/// La foto grande. In pausa si rimpicciolisce, come in Musica; mentre suona respira appena, così non sembra ferma
/// anche quando il video di copertina non c'è.
struct LockBigArtwork: View {
    let model: LockModel
    var mix: Double
    var radius: CGFloat

    var body: some View {
        let play = LockModel.ease(model.playT)
        let breath = 1 + 0.03 * (0.5 - 0.5 * cos(model.live.clock * 2 * .pi / 9)) * play
        ZStack {
            // l'ombra sta su una sagoma ferma: non si ricalcola a ogni respiro della foto
            RoundedRectangle(cornerRadius: radius, style: .continuous).fill(.black)
                .shadow(color: .black.opacity(0.5), radius: 44, y: 28)
            LockArtwork(image: model.music?.artwork, old: model.oldArtwork, mix: mix, radius: radius, zoom: breath)
        }
        .scaleEffect(0.9 + 0.1 * play)
    }
}

/// Una copertina con gli angoli tondi; al cambio brano quella di prima si scioglie in quella nuova.
struct LockArtwork: View {
    var image: NSImage?
    var old: NSImage?
    var mix: Double
    var radius: CGFloat
    var zoom: CGFloat = 1

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        GeometryReader { geo in
            ZStack {
                Color(white: 0.14)
                if let old, mix < 1 { picture(old, geo.size).opacity(1 - mix) }
                if let image { picture(image, geo.size).opacity(old == nil ? 1 : mix) }
                else { Image(systemName: "music.note").font(.system(size: geo.size.width * 0.36, weight: .semibold)).foregroundStyle(.white.opacity(0.5)) }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .clipShape(shape)
            .overlay { shape.strokeBorder(.white.opacity(0.16), lineWidth: 1) }
        }
    }

    private func picture(_ image: NSImage, _ size: CGSize) -> some View {
        Image(nsImage: image).resizable().interpolation(.high).aspectRatio(contentMode: .fill)
            .frame(width: size.width, height: size.height)
            .scaleEffect(zoom)
    }
}

// MARK: - Pezzi

struct LockSignView: View {
    var sign: LockSign

    var body: some View {
        HStack(spacing: 8) {
            icon
            Text(sign.text)
                .font(.system(size: 17, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
        }
        .foregroundStyle(.white)
        .shadow(color: .black.opacity(0.42), radius: 5, y: 1)
        .fixedSize()
    }

    @ViewBuilder private var icon: some View {
        if sign.ring != nil || sign.spinning {
            ZStack {
                Circle().stroke(.white.opacity(0.24), lineWidth: 3)
                Circle().trim(from: 0, to: sign.spinning ? 0.26 : min(1, max(0.02, sign.ring ?? 0)))
                    .stroke(.white, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                if let number = sign.ringText {
                    Text(number).font(.system(size: number.count > 2 ? 9 : 11, weight: .bold, design: .rounded)).monospacedDigit()
                } else if let symbol = sign.symbol {
                    Image(systemName: symbol).font(.system(size: 10, weight: .bold))
                }
            }
            .frame(width: 23, height: 23)
        } else if let symbol = sign.symbol {
            Image(systemName: symbol)
                .font(.system(size: 19, weight: .semibold))
                .symbolRenderingMode(.monochrome)
                .frame(height: 23)
        }
    }
}

/// L'onda del lettore, nel colore della copertina. A copertina aperta si muove col tempo che scorre; nel lettore
/// chiuso sta ferma (a schermo bloccato non si tiene acceso un timer per cinque stanghette).
struct LockWave: View {
    var color: Color
    var clock: LockLive?
    private static let speeds: [Double] = [6.0, 7.7, 5.0, 6.7, 5.4]
    private static let rest: [CGFloat] = [0.5, 0.85, 0.35, 1, 0.6]

    var body: some View {
        let t = clock?.clock
        HStack(spacing: 2.6) {
            ForEach(0..<5, id: \.self) { i in
                Capsule().fill(color)
                    .frame(width: 2.6, height: 15)
                    .scaleEffect(y: t.map { 0.64 + 0.36 * sin($0 * Self.speeds[i] + Double(i)) } ?? Self.rest[i])
            }
        }
        .frame(width: 22, height: 16, alignment: .trailing)
        .allowsHitTesting(false)
    }
}

/// La barra del tempo. A riposo è una linea sola; i tempi compaiono quando il puntatore è sul lettore
/// (carpa, 18 novembre 2026: «la più clean possibile»).
struct LockScrubber: View {
    let model: LockModel
    var width: CGFloat
    var interactive: Bool
    /// Quanto è grossa: 1 nel lettore, di più a copertina aperta sugli schermi grandi.
    var scale: CGFloat = 1

    var body: some View {
        TimelineView(.periodic(from: .now, by: model.isLive && model.playing ? 0.25 : 3600)) { context in
            let duration = max(1, model.music?.duration ?? 1)
            let position = model.position(at: context.date)
            let hover = CGFloat(LockModel.ease(model.hoverT))
            let inset = 38 * scale * hover
            ZStack {
                HStack {
                    Text(Self.clock(position))
                    Spacer()
                    Text("-" + Self.clock(max(0, duration - position)))
                }
                .font(.system(size: 11.5 * scale, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.white.opacity(0.6))
                .opacity(Double(hover))
                Capsule().fill(.white.opacity(0.22))
                    .overlay(alignment: .leading) {
                        Capsule().fill(.white).frame(width: max(5 * scale, (width - inset * 2) * min(1, position / duration)))
                    }
                    .frame(height: (model.seeking == nil ? 5 : 7) * scale)
                    .padding(.horizontal, inset)
            }
            .frame(width: width, height: 16 * scale)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { value in
                    guard interactive else { return }
                    model.seeking = duration * min(1, max(0, (value.location.x - inset) / max(1, width - inset * 2)))
                }
                .onEnded { _ in
                    guard interactive, let to = model.seeking else { return }
                    LockScreen.shared.seek(to: to)
                })
            .allowsHitTesting(interactive)
        }
    }

    static func clock(_ seconds: Double) -> String {
        let s = Int(seconds.rounded(.down))
        return "\(s / 60):" + String(format: "%02d", s % 60)
    }
}

struct LockControls: View {
    var playing: Bool
    var interactive: Bool

    var body: some View {
        HStack(spacing: 25) {
            button("backward.fill", size: 21) { LockScreen.shared.command("previous") }
            button(playing ? "pause.fill" : "play.fill", size: 26) { LockScreen.shared.command("toggle") }
            button("forward.fill", size: 21) { LockScreen.shared.command("next") }
        }
        .frame(width: 188, height: 46)
        .allowsHitTesting(interactive)
    }

    private func button(_ symbol: String, size: CGFloat, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 46, height: 46)
                .contentShape(Circle())
        }
        .buttonStyle(LockPressStyle())
    }
}

/// Il tasto del testo, sotto la foto: acceso è un disco bianco col segno scuro, spento è solo il segno.
struct LockLyricsButton: View {
    var on: Bool

    var body: some View {
        Button { LockScreen.shared.toggleLyrics() } label: {
            Image(systemName: "quote.bubble.fill")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(on ? Color.black.opacity(0.85) : Color.white.opacity(0.85))
                .frame(width: 42, height: 42)
                .background(Circle().fill(.white.opacity(on ? 0.92 : 0.0)))
                .contentShape(Circle())
        }
        .buttonStyle(LockPressStyle())
    }
}

/// Il tasto si schiarisce sotto il dito.
struct LockPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(Circle().fill(.white.opacity(configuration.isPressed ? 0.16 : 0)))
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}
