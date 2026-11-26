import Foundation

/// Quale cosa mostra il widget del calendario nel Dock (carpa, 26 novembre 2026): la prossima anche se non è oggi e
/// anche se non ha un'ora. Conta il giorno più vicino che ha qualcosa; in quel giorno prima le cose con un'ora, se no
/// quella senza ora. Così con una cosa a un'ora il 30 si vede quella; con una cosa a un'ora l'1 e una senza ora il 30
/// si vede quella senza ora, perché il 30 viene prima.
public enum NextUp {
    /// `days`: il giorno di ogni cosa, nell'ordine dell'elenco (per giorno, poi per ora). `timed`: se ha un'ora.
    /// `timedPick`: l'indice della prossima cosa con un'ora scelta per conto suo (quella in corso, una riunione che
    /// comincia prima che finisca un promemoria...), o nil se non ce ne sono. Restituisce l'indice da mostrare.
    public static func choose(days: [Date], timed: [Bool], timedPick: Int?) -> Int? {
        guard let nearest = days.min() else { return nil }
        if let pick = timedPick, pick < days.count, days[pick] == nearest { return pick }
        return days.indices.first { days[$0] == nearest && !timed[$0] }
            ?? timedPick
    }
}
