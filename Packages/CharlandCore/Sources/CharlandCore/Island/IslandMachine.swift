import Foundation

/// Un'attività mostrata nell'isola. I nomi delle regioni sono quelli di ActivityKit:
/// compactLeading, compactTrailing, minimal, expanded.
public struct IslandActivity: Sendable, Equatable, Identifiable {
    public var id: String
    /// Chi vince il posto compatto: il più alto. A parità vince l'ultimo arrivato.
    public var priority: Int
    /// Larghezza del contenuto compatto a sinistra e a destra della fotocamera.
    public var leadingWidth: Double
    public var trailingWidth: Double
    /// Misura dell'area espansa sotto la fascia della fotocamera.
    public var expandedWidth: Double
    public var expandedHeight: Double
    /// Se può stare nella goccia minima quando è la seconda attività.
    public var allowsMinimal: Bool

    public init(id: String, priority: Int = 0, leadingWidth: Double = 30, trailingWidth: Double = 30,
                expandedWidth: Double = 380, expandedHeight: Double = 120, allowsMinimal: Bool = true) {
        self.id = id
        self.priority = priority
        self.leadingWidth = leadingWidth
        self.trailingWidth = trailingWidth
        self.expandedWidth = expandedWidth
        self.expandedHeight = expandedHeight
        self.allowsMinimal = allowsMinimal
    }
}

/// Da che lato esce uno slider: la luminosità a sinistra, il volume a destra, come i tasti.
public enum SliderSide: String, Sendable, Equatable, Codable {
    case brightness
    case volume
}

/// Come si affaccia l'isola mentre detti. Ogni variante ha un nome unico, per sceglierla.
public enum DictationStyle: String, Sendable, Equatable, Codable, CaseIterable {
    /// Ali strette ai lati, un filo più in basso: il più discreto.
    case soffio
    /// Ali appena accennate e un labbro basso sotto la fotocamera.
    case ciglio
    /// Ali larghe, nessun labbro: resta nella fascia della barra dei menu.
    case orizzonte
}

/// Uno stato passeggero che prende l'isola per sé finché dura.
public enum IslandTransient: Sendable, Equatable {
    case slider(SliderSide)
    /// Dettatura. `liveText` scende un poco di più per mostrare le parole.
    case dictation(style: DictationStyle, liveText: Bool, handsFree: Bool)
    /// La goccia sta colando verso il cursore.
    case dripping
}

/// Che cosa mostra l'isola in questo momento.
public enum IslandMode: Sendable, Equatable {
    /// Identica al notch, invisibile.
    case rest
    /// Un'attività ai lati della fotocamera; se c'è una seconda sta nella goccia a destra, se c'è una terza nella
    /// goccia a sinistra (carpa, 17 novembre 2026: «voglio che ce ne stiano tre visibili»).
    case compact(primary: String, secondary: String?, tertiary: String? = nil)
    /// Un'attività aperta sotto il notch.
    case expanded(id: String)
    case transient(IslandTransient, under: String?)
}

public enum IslandEvent: Sendable, Equatable {
    case started(IslandActivity)
    case updated(IslandActivity)
    case ended(id: String)
    /// Apre l'attività indicata, o la principale se `nil`.
    case expand(id: String?)
    case collapse
    case pointerEntered
    /// Il puntatore è entrato sopra la goccia di un'attività (a destra o a sinistra del corpo).
    case pointerEnteredDrop(id: String)
    case pointerExited
    case pressed(Bool)
    case transientBegan(IslandTransient)
    case transientEnded
    /// Il tempo che passa: fa scattare le scadenze.
    case tick
}

/// La macchina a stati dell'isola. È pura: stesso stato e stesso evento danno lo stesso risultato.
public struct IslandState: Sendable, Equatable {
    /// Le attività, la più importante per prima.
    public private(set) var activities: [IslandActivity] = []
    public private(set) var expandedID: String?
    /// `true` se l'apertura viene dal puntatore fermo: si chiude da sola quando esce.
    public private(set) var expandedByHover = false
    public private(set) var transient: IslandTransient?
    public private(set) var pointerInside = false
    public private(set) var pressed = false
    /// Quando chiudere l'anteprima dopo l'uscita del puntatore.
    public private(set) var collapseDeadline: Double?
    /// Quando far rientrare lo slider.
    public private(set) var transientDeadline: Double?
    private var arrival = 0
    private var arrivals: [String: Int] = [:]
    /// La casa: quello che si apre passando sopra il notch quando non c'è nessuna attività.
    public private(set) var home: IslandActivity?
    /// Passando sopra si apre l'attività in corso invece della casa (carpa: «quando c'è una live activity, tipo Claude
    /// che lavora o un timer, in hover ti porta direttamente in quella sezione»). La casa resta a un clic.
    public var hoverOpensActivity = false
    /// L'attività della riproduzione (la musica): se c'è, passando sopra si apre lei invece della casa (carpa, 18 novembre
    /// 2026: «quando c'è qualcosa in riproduzione» l'isola si apre lì). `nil` con l'opzione spenta.
    public var playbackID: String?
    /// Dentro un'attività aperta si vedono le altre in corso come pillole. Spento, solo quella aperta (carpa, 18 novembre
    /// 2026: «l'opzione di non mostrare le altre live activities attive mentre sei in una live activity»).
    public var showsOthers = true

    /// Identificativo della casa.
    public static let homeID = "home"

    /// Dopo l'uscita del puntatore l'isola resta aperta per questo tempo.
    public static let collapseDelay = 0.4
    /// Lo slider resta dopo l'ultimo tasto.
    public static let sliderLinger = 1.4

    public init() {}

    public mutating func setHome(_ activity: IslandActivity?) {
        home = activity
    }

    public var mode: IslandMode {
        if let transient {
            return .transient(transient, under: activities.first?.id)
        }
        if let expandedID, activities.contains(where: { $0.id == expandedID }) || expandedID == home?.id {
            return .expanded(id: expandedID)
        }
        guard let primary = activities.first else { return .rest }
        // Le gocce: la seconda attività a destra, la terza a sinistra. Chi non sa stare in una goccia (un momento
        // largo come il Risparmio energetico) cede il posto alla successiva.
        let drops = activities.dropFirst().filter(\.allowsMinimal).prefix(Self.maxDrops).map(\.id)
        return .compact(primary: primary.id, secondary: drops.first, tertiary: drops.dropFirst().first)
    }

    /// Quante gocce staccate al massimo: una a destra e una a sinistra. Le altre attività restano nella casa.
    public static let maxDrops = 2

    /// Le altre attività in corso mentre una è aperta: si vedono dentro l'isola come pillole, per passare dall'una
    /// all'altra (carpa: «si devono vedere ovviamente anche all'interno»). Al massimo tre, nell'ordine dell'isola.
    public func others(than id: String) -> [String] {
        guard showsOthers, id != home?.id else { return [] }
        return activities.map(\.id).filter { $0 != id }.prefix(Self.maxOthers).map { $0 }
    }

    /// Quante altre attività si vedono dentro un'attività aperta.
    public static let maxOthers = 3

    /// Le attività che si vedono adesso nell'isola compatta: al centro, nella goccia destra, in quella sinistra.
    public var visibleIDs: [String] {
        guard case .compact(let primary, let secondary, let tertiary) = mode else { return [] }
        return [primary] + [secondary, tertiary].compactMap { $0 }
    }

    public func activity(_ id: String) -> IslandActivity? {
        if let home, id == home.id { return home }
        return activities.first { $0.id == id }
    }

    public mutating func handle(_ event: IslandEvent, now: Double) {
        switch event {
        case .started(let activity):
            if let index = activities.firstIndex(where: { $0.id == activity.id }) {
                activities[index] = activity
            } else {
                arrival += 1
                arrivals[activity.id] = arrival
                activities.append(activity)
            }
            sort()

        case .updated(let activity):
            guard let index = activities.firstIndex(where: { $0.id == activity.id }) else { return }
            activities[index] = activity
            sort()

        case .ended(let id):
            activities.removeAll { $0.id == id }
            arrivals[id] = nil
            if expandedID == id {
                // Col puntatore sopra l'isola non si chiude sotto la mano: passa alla casa (un timer finito, un agente
                // che ha smesso mentre lo guardavi). Altrimenti si chiude.
                if pointerInside, let fallback = home?.id ?? activities.first?.id {
                    expandedID = fallback
                } else {
                    expandedID = nil
                    expandedByHover = false
                    collapseDeadline = nil
                }
            }

        case .expand(let id):
            guard let target = id ?? activities.first?.id ?? home?.id, activity(target) != nil else { return }
            expandedID = target
            expandedByHover = false
            collapseDeadline = nil

        case .collapse:
            expandedID = nil
            expandedByHover = false
            collapseDeadline = nil

        case .pointerEntered:
            pointerInside = true
            collapseDeadline = nil
            // Di serie passando sopra si apre la casa (che mostra in cima le attività in corso): così casa, vassoio e
            // dettatura restano raggiungibili anche mentre un agente lavora. Senza casa si apre l'attività principale.
            if expandedID == nil, transient == nil, let target = hoverTarget {
                expandedID = target
                expandedByHover = true
            }

        case .pointerEnteredDrop(let id):
            pointerInside = true
            collapseDeadline = nil
            // Sopra una goccia: con l'opzione si apre l'attività di quella goccia, anche se è di sottofondo (l'hai
            // indicata tu); senza, la casa come dal centro.
            if expandedID == nil, transient == nil {
                let target = hoverOpensActivity && activity(id) != nil ? id : hoverTarget
                if let target {
                    expandedID = target
                    expandedByHover = true
                }
            }

        case .pointerExited:
            pointerInside = false
            pressed = false
            if expandedID != nil {
                collapseDeadline = now + Self.collapseDelay
            }

        case .pressed(let down):
            pressed = down

        case .transientBegan(let next):
            transient = next
            if case .slider = next {
                transientDeadline = now + Self.sliderLinger
            } else {
                transientDeadline = nil
            }

        case .transientEnded:
            transient = nil
            transientDeadline = nil

        case .tick:
            if let deadline = collapseDeadline, now >= deadline, !pointerInside {
                expandedID = nil
                expandedByHover = false
                collapseDeadline = nil
            }
            if let deadline = transientDeadline, now >= deadline {
                transient = nil
                transientDeadline = nil
            }
        }
    }

    /// Cosa apre il puntatore. Con `hoverOpensActivity` l'attività in corso più importante, quella che si vede ai lati
    /// della fotocamera; non quelle di sottofondo a priorità negativa (Mantieni attivo può restare acceso tutto il
    /// giorno: aprirlo a ogni passaggio nasconderebbe la casa senza mostrare niente di nuovo).
    /// Con qualcosa in riproduzione (`playbackID`) si apre la riproduzione al posto della casa, anche con «Apri la casa»;
    /// con «Apri l'attività» un'attività più importante (un agente al lavoro) resta davanti, come ai lati della fotocamera.
    public var hoverTarget: String? {
        if hoverOpensActivity, let live = activities.first, live.priority >= 0 { return live.id }
        if let playbackID, activities.contains(where: { $0.id == playbackID }) { return playbackID }
        return home?.id ?? activities.first?.id
    }

    /// La prossima scadenza, per svegliarsi solo quando serve.
    public var nextDeadline: Double? {
        [collapseDeadline, transientDeadline].compactMap { $0 }.min()
    }

    private mutating func sort() {
        let order = arrivals
        activities.sort { a, b in
            if a.priority != b.priority { return a.priority > b.priority }
            return (order[a.id] ?? 0) > (order[b.id] ?? 0)
        }
    }
}
