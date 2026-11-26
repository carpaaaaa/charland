import SwiftUI
import CharlandCore

/// La pillola di volume e luminosità, come nel Centro di Controllo dell'iPhone:
/// riempimento bianco su traccia scura, simbolo dentro. Dove il bianco copre il simbolo,
/// il simbolo diventa nero.
struct SliderPill: View {
    let model: IslandModel

    var body: some View {
        let state = model.slider
        GeometryReader { geo in
            let length = geo.size.width
            let height = geo.size.height
            // Oltre 0 e oltre 100 la pillola si allunga con resistenza e si assottiglia.
            let stretch = RubberBand.offset(overshoot: state.overshoot * length, dimension: length)
            let thin = RubberBand.thinning(stretch: stretch, dimension: length)
            let h = height * (1 - thin)
            let total = length + abs(stretch)
            let fill = max(0, min(1, state.level)) * length + max(0, stretch)
            let shiftsBack = state.side == .brightness ? stretch > 0 : stretch < 0

            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.16))
                Capsule().fill(.white)
                    .frame(width: max(h, fill))
                    .opacity(state.level <= 0.001 && stretch <= 0 ? 0 : 1)
                symbol(state).foregroundStyle(.white)
                // Lo stesso simbolo in nero, visibile solo dove c'è il riempimento.
                symbol(state).foregroundStyle(.black)
                    .mask(alignment: .leading) {
                        Capsule().frame(width: max(h, fill))
                            .opacity(state.level <= 0.001 && stretch <= 0 ? 0 : 1)
                    }
            }
            .frame(width: total, height: h)
            .clipShape(Capsule())
            .offset(x: shiftsBack ? -abs(stretch) : 0, y: (height - h) / 2)
        }
    }

    @ViewBuilder
    private func symbol(_ state: SliderState) -> some View {
        Group {
            if state.side == .volume {
                // Le onde dell'altoparlante seguono il livello; la barra del muto si disegna.
                Image(systemName: state.muted || state.level <= 0.001 ? "speaker.slash.fill" : "speaker.wave.3.fill",
                      variableValue: state.level)
                    .contentTransition(.symbolEffect(.replace))
            } else {
                Image(systemName: "sun.max.fill", variableValue: state.level)
            }
        }
        .font(.system(size: 11, weight: .semibold))
        .frame(width: 26, alignment: .center)
    }
}
