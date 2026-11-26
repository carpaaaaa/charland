import SwiftUI

/// Il vetro di Charland, uno solo per tutto: slider sul bordo, isola sotto la fascia nera del notch, goccia e filo della
/// farfalla. È il vetro degli slider che carpa ha scelto il 17 novembre 2026 («sto vetro mi piace un sacco»): vetro
/// trasparente di Apple con la lente sui bordi, un velo nero leggero che tiene il contrasto anche sopra una pagina
/// bianca, un filo di luce sul bordo più forte in alto, un'ombra morbida.
enum CharlandGlass {
    /// Quanto nero sta sopra il vetro: il minimo anche dove l'isola è più trasparente.
    static let veil = 0.26
    /// Il filo di luce: in alto e in basso (lungo la direzione scelta da chi lo usa), e quanto è spesso.
    static let rimTop = 0.42
    static let rimBottom = 0.08
    static let rimWidth: CGFloat = 1.2
    static let shadowOpacity = 0.16
    static let shadowRadius: CGFloat = 8
    static let shadowY: CGFloat = 2
}

/// Il vetro di Charland in una forma: lente, velo, filo di luce. L'ombra la mette chi lo usa, sul gruppo intero
/// (con dentro anche il contenuto), così cade una volta sola.
struct CharlandGlassFill<S: Shape>: View {
    let shape: S
    /// Da dove a dove va il filo di luce, dal più chiaro al più scuro, nello spazio della vista che lo contiene.
    var rimFrom: UnitPoint = .top
    var rimTo: UnitPoint = .bottom
    /// Per far svanire il filo di luce (l'isola lo spegne sul nero del notch e mentre si chiude).
    var rimStrength: Double = 1
    /// Il velo: di serie il nero leggero uniforme degli slider. La goccia della farfalla passa la sfumatura del notch,
    /// nero pieno in alto fino al vetro in fondo.
    var veil: AnyShapeStyle? = nil
    /// Il filo di luce: di serie dal più chiaro in alto al più tenue in basso (lungo `rimFrom`→`rimTo`).
    var rim: AnyShapeStyle? = nil
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        ZStack {
            if reduceTransparency {
                // Riduci trasparenza: niente vetro, un grigio scuro pieno che si legge su qualunque sfondo.
                shape.fill(Color(white: 0.16))
            } else {
                Color.clear
                    .glassEffect(.clear, in: shape)
                    .environment(\.appearsActive, true)
                    .materialActiveAppearance(.active)
                shape.fill(veil ?? AnyShapeStyle(Color.black.opacity(contrast == .increased ? 0.5 : CharlandGlass.veil)))
            }
            if rimStrength > 0.01 {
                shape.stroke(rim ?? AnyShapeStyle(LinearGradient(colors: [.white.opacity(CharlandGlass.rimTop * rimStrength),
                                                                          .white.opacity(CharlandGlass.rimBottom * rimStrength)],
                                                                 startPoint: rimFrom, endPoint: rimTo)),
                             lineWidth: CharlandGlass.rimWidth)
                    .clipShape(shape)
            }
        }
    }
}
