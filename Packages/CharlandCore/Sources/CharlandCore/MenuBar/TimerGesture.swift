import CoreGraphics

/// Le regole del gesto che tira un timer fuori dalla barra dei menu (le stesse di Filo).
/// Soglia e durata si misurano sempre dal punto premuto, mai dall'icona: un clic sul bordo
/// dell'icona disterebbe già qualche punto dal centro e verrebbe letto come un trascinamento.
public enum TimerGesture {
    /// Sotto questa distanza è un clic.
    public static let dragThreshold: CGFloat = 8
    /// Sotto questa distanza dal punto premuto si annulla, come riportare la goccia nella barra.
    public static let cancelRadius: CGFloat = 30
    /// I minuti vanno da 1 a 8 ore.
    public static let range = 1...480

    public static func dragBegan(press: CGPoint, current: CGPoint) -> Bool {
        hypot(current.x - press.x, current.y - press.y) > dragThreshold
    }

    /// I minuti per un trascinamento dal punto premuto; `nil` vuol dire annulla.
    /// `extra` sono i minuti aggiunti o tolti con la rotella.
    public static func minutes(press: CGPoint, current: CGPoint, extra: Int = 0) -> Int? {
        guard let base = minutes(forDistance: hypot(current.x - press.x, current.y - press.y)) else { return nil }
        return min(range.upperBound, max(range.lowerBound, base + extra))
    }

    /// Scala progressiva: un minuto ogni 20 punti fino a 15, poi cinque ogni 33 fino all'ora,
    /// poi un quarto d'ora ogni 15 fino a quattro ore.
    public static func minutes(forDistance d: CGFloat) -> Int? {
        guard d > cancelRadius else { return nil }
        var px = d - cancelRadius
        var minutes = 1
        let tiers: [(stepPx: CGFloat, stepMin: Int, upTo: Int)] = [(20, 1, 15), (33, 5, 60), (15, 15, 240)]
        for tier in tiers {
            while minutes < tier.upTo, px >= tier.stepPx {
                minutes += tier.stepMin
                px -= tier.stepPx
            }
            // finita la distanza dentro questo gradino ci si ferma; arrivati in cima si passa al prossimo
            // (in Filo il controllo usava il passo del gradino appena finito: dopo l'ora si saltava da 60 a 90)
            if minutes < tier.upTo { break }
        }
        return minutes
    }

    /// Come si legge una durata: «45 s», «25 min», «1 h», «2 h 25 min».
    public static func label(minutes: Int) -> String {
        if minutes < 60 { return "\(minutes) min" }
        let h = minutes / 60, m = minutes % 60
        return m == 0 ? "\(h) h" : "\(h) h \(m) min"
    }
}
