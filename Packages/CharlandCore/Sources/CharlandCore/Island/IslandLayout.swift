import Foundation

/// Un rettangolo nello spazio dell'isola (x = 0 al centro del notch, y = 0 in alto).
public struct IslandRect: Sendable, Equatable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public var midX: Double { x + width / 2 }
    public var midY: Double { y + height / 2 }
    public var maxX: Double { x + width }
    public var maxY: Double { y + height }
    public static let zero = IslandRect(x: 0, y: 0, width: 0, height: 0)
}

/// Dove va ogni contenuto. Le cornici dipendono solo dallo stato di arrivo, mai dal fotogramma:
/// durante un'animazione il contenuto resta fermo e la forma lo scopre.
public struct IslandFrames: Sendable, Equatable {
    /// A sinistra della fotocamera, stretto contro di lei.
    public var compactLeading: IslandRect = .zero
    /// A destra della fotocamera, stretto contro di lei.
    public var compactTrailing: IslandRect = .zero
    /// Dentro la goccia staccata a destra.
    public var minimal: IslandRect = .zero
    /// Dentro la goccia staccata a sinistra.
    public var minimalLeading: IslandRect = .zero
    /// Sotto la fascia della fotocamera.
    public var expanded: IslandRect = .zero
    /// La pillola dello slider.
    public var slider: IslandRect = .zero
    /// Il labbro basso (testo dal vivo, linea della voce nella variante col labbro).
    public var lip: IslandRect = .zero
    /// Sotto il contenuto aperto, la fila delle altre attività in corso.
    public var switcher: IslandRect = .zero
    /// Chi sta nella fila delle altre attività, in ordine.
    public var switcherIDs: [String] = []
    /// Fin dove il velo deve restare nero pieno: testi e simboli non scendono mai sul vetro.
    public var blackUntil: Double = 0

    public init() {}
}

/// Le misure fisse del disegno. Sono i valori di partenza: li tara carpa a occhio.
public struct IslandTuning: Sendable, Equatable {
    /// Aria fra il contenuto compatto e il bordo esterno dell'ala.
    public var wingPadding = 10.0
    /// Aria fra il contenuto compatto e il bordo del notch.
    public var notchGap = 6.0
    /// Raggio in basso nello stato compatto.
    public var compactRadius = 13.0
    public var compactFlare = 7.0
    /// Raggio in basso nello stato espanso.
    public var expandedRadius = 30.0
    public var expandedFlare = 10.0
    /// Aria attorno al contenuto espanso: il raggio interno è `expandedRadius - expandedPadding`.
    public var expandedPadding = 14.0
    /// Distanza fra il corpo e la goccia minima.
    public var minimalGap = 8.0
    /// Margine della goccia minima rispetto alla fascia della barra.
    public var minimalInset = 3.5
    /// Raggio di fusione a riposo: non deve gonfiare le due forme, quindi al massimo la distanza.
    public var minimalBlend = 8.0
    /// Raggio di fusione mentre la goccia si stacca: tiene il collo fino a metà di questo valore.
    public var splitBlend = 22.0
    /// Lo slider: lunghezza e altezza della pillola, aria attorno.
    public var sliderLength = 132.0
    public var sliderHeight = 19.0
    public var sliderPadding = 7.0
    /// Dettatura: quanto esce ai lati e in basso per ogni variante.
    public var dictationWing: [DictationStyle: Double] = [.soffio: 38, .ciglio: 12, .orizzonte: 54]
    public var dictationDrop: [DictationStyle: Double] = [.soffio: 4, .ciglio: 20, .orizzonte: 0]
    /// Quanto scende ancora con il testo dal vivo.
    /// Altezza della fascia di vetro in fondo all'isola aperta: lì non va nessun testo.
    /// Zero nell'aspetto "Solo nero".
    public var glassLip = 36.0
    public var liveTextHeight = 30.0
    public var liveTextWidth = 360.0
    /// La fila delle altre attività dentro un'attività aperta: pillole alte 30, con l'aria sopra.
    public var switcherHeight = 40.0
    public var switcherPill = 30.0

    public init() {}
}

public enum IslandLayout {
    /// La forma di arrivo per uno stato.
    public static func shape(for mode: IslandMode, state: IslandState, metrics m: IslandMetrics,
                             tuning t: IslandTuning = IslandTuning()) -> IslandShape {
        var shape = IslandShape.resting(m)
        switch mode {
        case .rest:
            break

        case .compact(let primaryID, let secondaryID, let tertiaryID):
            guard let primary = state.activity(primaryID) else { break }
            applyCompact(&shape, primary, m, t)
            if secondaryID != nil {
                shape[.minimal] = minimalBlob(.trailing, bodyEdge: shape.right, m, t, blend: t.minimalBlend)
            }
            if tertiaryID != nil {
                shape[.minimalLeading] = minimalBlob(.leading, bodyEdge: shape.left, m, t, blend: t.minimalBlend)
            }

        case .expanded(let id):
            guard let activity = state.activity(id) else { break }
            // Sinistra e destra della fotocamera restano occupate dal contenuto compatto:
            // nessuna fronte vuota sopra il contenuto aperto.
            let half = max(m.halfNotch + 24, activity.expandedWidth / 2 + t.expandedPadding)
            shape.left = max(half, m.halfNotch + t.notchGap + activity.leadingWidth + t.wingPadding)
            shape.right = max(half, m.halfNotch + t.notchGap + activity.trailingWidth + t.wingPadding)
            let switcher = state.others(than: id).isEmpty ? 0 : t.switcherHeight
            shape.height = m.notchHeight + activity.expandedHeight + switcher + max(t.expandedPadding, t.glassLip)
            shape.radius = t.expandedRadius
            shape.flare = t.expandedFlare

        case .transient(let transient, let underID):
            let under = underID.flatMap(state.activity)
            switch transient {
            case .slider(let side):
                if let under { applyCompact(&shape, under, m, t) }
                let wing = t.sliderLength + t.sliderPadding * 2
                // L'ala dello slider ha gli angoli pieni, concentrici con la pillola.
                shape.radius = min(m.notchHeight / 2, t.sliderHeight / 2 + t.sliderPadding)
                shape.flare = t.compactFlare
                if side == .volume {
                    shape.right = m.halfNotch + wing
                    shape.left = max(shape.left, m.halfNotch + 14)
                } else {
                    shape.left = m.halfNotch + wing
                    shape.right = max(shape.right, m.halfNotch + 14)
                }

            case .dictation(let style, let liveText, let handsFree):
                // a sinistra c'è il tempo che passa: le ali sono un poco più larghe per farci stare il numero
                let wing = (t.dictationWing[style] ?? 30) + (style != .ciglio ? (handsFree ? 14 : 12) : 0)
                let drop = t.dictationDrop[style] ?? 4
                shape.left = m.halfNotch + wing
                shape.right = m.halfNotch + wing
                shape.height = m.notchHeight + drop
                shape.radius = style == .ciglio ? 14 : t.compactRadius
                shape.flare = t.compactFlare
                if liveText {
                    shape.left = max(shape.left, t.liveTextWidth / 2)
                    shape.right = max(shape.right, t.liveTextWidth / 2)
                    shape.height += t.liveTextHeight + min(t.glassLip, 10)
                    shape.radius = 20
                    shape.flare = t.expandedFlare
                }

            case .dripping:
                // Il corpo torna al notch mentre la goccia scende: la goccia la muove chi anima.
                break
            }
        }
        return shape
    }

    /// Le cornici dei contenuti per uno stato.
    public static func frames(for mode: IslandMode, state: IslandState, metrics m: IslandMetrics,
                              tuning t: IslandTuning = IslandTuning()) -> IslandFrames {
        var f = IslandFrames()
        let band = m.notchHeight
        f.blackUntil = band
        switch mode {
        case .rest:
            break

        case .compact(let primaryID, let secondaryID, let tertiaryID):
            guard let primary = state.activity(primaryID) else { break }
            f.compactLeading = IslandRect(x: -m.halfNotch - t.notchGap - primary.leadingWidth, y: 0,
                                          width: primary.leadingWidth, height: band)
            f.compactTrailing = IslandRect(x: m.halfNotch + t.notchGap, y: 0,
                                           width: primary.trailingWidth, height: band)
            if secondaryID != nil {
                let right = m.halfNotch + t.notchGap + primary.trailingWidth + t.wingPadding
                f.minimal = minimalBlob(.trailing, bodyEdge: right, m, t, blend: 0).rect
            }
            if tertiaryID != nil {
                let left = m.halfNotch + t.notchGap + primary.leadingWidth + t.wingPadding
                f.minimalLeading = minimalBlob(.leading, bodyEdge: left, m, t, blend: 0).rect
            }

        case .expanded(let id):
            guard let activity = state.activity(id) else { break }
            // Il contenuto compatto resta fermo ai lati della fotocamera mentre l'isola si apre.
            f.compactLeading = IslandRect(x: -m.halfNotch - t.notchGap - activity.leadingWidth, y: 0,
                                          width: activity.leadingWidth, height: band)
            f.compactTrailing = IslandRect(x: m.halfNotch + t.notchGap, y: 0,
                                           width: activity.trailingWidth, height: band)
            f.expanded = IslandRect(x: -activity.expandedWidth / 2, y: band,
                                    width: activity.expandedWidth, height: activity.expandedHeight)
            f.blackUntil = band + activity.expandedHeight
            let others = state.others(than: id)
            if !others.isEmpty {
                // Le pillole stanno sul nero, sotto il contenuto e sopra la fascia di vetro in fondo.
                f.switcher = IslandRect(x: -activity.expandedWidth / 2 + 12, y: band + activity.expandedHeight + t.switcherHeight - t.switcherPill,
                                        width: activity.expandedWidth - 24, height: t.switcherPill)
                f.switcherIDs = others
                f.blackUntil = band + activity.expandedHeight + t.switcherHeight
            }

        case .transient(let transient, _):
            switch transient {
            case .slider(let side):
                let y = (band - t.sliderHeight) / 2
                let x = side == .volume ? m.halfNotch + t.sliderPadding
                                        : -m.halfNotch - t.sliderPadding - t.sliderLength
                f.slider = IslandRect(x: x, y: y, width: t.sliderLength, height: t.sliderHeight)

            case .dictation(let style, let liveText, let handsFree):
                let wing = (t.dictationWing[style] ?? 30) + (style != .ciglio ? (handsFree ? 14 : 12) : 0)
                let drop = t.dictationDrop[style] ?? 4
                let inner = max(8, wing - t.notchGap - 4)
                if style == .ciglio {
                    // Microfono e voce stanno nel labbro, sotto la fotocamera, sul nero.
                    f.compactLeading = IslandRect(x: -m.halfNotch + 8, y: band - 2, width: 22, height: drop - 3)
                    f.compactTrailing = IslandRect(x: -m.halfNotch + 34, y: band - 2,
                                                   width: m.notchWidth - 44, height: drop - 3)
                    f.blackUntil = band + drop - 4
                } else {
                    f.compactLeading = IslandRect(x: -m.halfNotch - t.notchGap - inner, y: 0, width: inner, height: band + drop)
                    f.compactTrailing = IslandRect(x: m.halfNotch + t.notchGap, y: 0, width: inner, height: band + drop)
                }
                if liveText {
                    f.lip = IslandRect(x: -t.liveTextWidth / 2 + 16, y: band + drop,
                                       width: t.liveTextWidth - 32, height: t.liveTextHeight - 4)
                    f.blackUntil = band + drop + t.liveTextHeight - 2
                }

            case .dripping:
                break
            }
        }
        return f
    }

    static func applyCompact(_ shape: inout IslandShape, _ a: IslandActivity, _ m: IslandMetrics, _ t: IslandTuning) {
        shape.left = m.halfNotch + t.notchGap + a.leadingWidth + t.wingPadding
        shape.right = m.halfNotch + t.notchGap + a.trailingWidth + t.wingPadding
        shape.height = m.notchHeight
        shape.radius = t.compactRadius
        shape.flare = t.compactFlare
    }

    /// Da che lato del corpo sta una goccia staccata.
    public enum DropSide: Sendable, CaseIterable {
        /// A destra: la seconda attività.
        case trailing
        /// A sinistra: la terza.
        case leading

        /// Il posto della goccia nella forma.
        public var blob: BlobSlot { self == .trailing ? .minimal : .minimalLeading }
        /// Il posto del suo contenuto.
        public var content: ContentSlot { self == .trailing ? .minimal : .minimalLeading }
        /// +1 a destra, -1 a sinistra.
        var sign: Double { self == .trailing ? 1 : -1 }
    }

    /// La goccia minima: un cerchio nella fascia della barra, staccato dal corpo. `bodyEdge` è il bordo del corpo da
    /// quel lato, come distanza (positiva) dal centro del notch.
    public static func minimalBlob(_ side: DropSide = .trailing, bodyEdge: Double, _ m: IslandMetrics, _ t: IslandTuning,
                                   blend: Double) -> Blob {
        let diameter = m.notchHeight - t.minimalInset * 2
        let r = diameter / 2
        return Blob(x: side.sign * (bodyEdge + t.minimalGap + r), y: m.notchHeight / 2,
                    halfWidth: r, halfHeight: r, radius: r, blend: blend)
    }

    /// Dove nasce la goccia minima: dentro il corpo, contro il suo bordo, piccola. Da lì cresce ed esce col collo.
    public static func minimalSeed(_ side: DropSide = .trailing, bodyEdge: Double, _ m: IslandMetrics, _ t: IslandTuning) -> Blob {
        let r = (m.notchHeight - t.minimalInset * 2) / 2
        return Blob(x: side.sign * (bodyEdge - r - 2), y: m.notchHeight / 2, halfWidth: r * 0.6, halfHeight: r * 0.6,
                    radius: r * 0.6, blend: t.splitBlend)
    }

    /// Le versioni di prima, per la goccia destra.
    public static func minimalBlob(bodyRight: Double, _ m: IslandMetrics, _ t: IslandTuning, blend: Double) -> Blob {
        minimalBlob(.trailing, bodyEdge: bodyRight, m, t, blend: blend)
    }

    public static func minimalSeed(bodyRight: Double, _ m: IslandMetrics, _ t: IslandTuning) -> Blob {
        minimalSeed(.trailing, bodyEdge: bodyRight, m, t)
    }
}

extension Blob {
    /// Il rettangolo che contiene la goccia.
    public var rect: IslandRect {
        IslandRect(x: x - halfWidth, y: y - halfHeight, width: halfWidth * 2, height: halfHeight * 2)
    }
}
