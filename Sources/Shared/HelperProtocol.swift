import Foundation

/// L'aiutante di sistema di Charland: un processo di sistema (root) installato una volta con `SMAppService` e
/// approvato da chi usa il Mac in Impostazioni di Sistema › Generale › Elementi di login. Da lì in poi spegne e
/// riaccende il sonno a coperchio chiuso senza chiedere la password ogni volta, e fa da guardiano: se Charland si
/// chiude o cade, se scade il tempo o la batteria scende al 10%, rimette subito il sonno normale.
@objc public protocol CharlandHelperProtocol {
    /// Accende o spegne «resta sveglio anche a coperchio chiuso». `deadline` in secondi dal 1970, 0 = nessuna scadenza.
    /// Resta acceso finché la connessione che l'ha chiesto è viva.
    func setClosedLidAwake(_ on: Bool, deadline: Double, reply: @escaping (Bool) -> Void)
    /// La versione dell'aiutante e se in questo momento il sonno è spento.
    func status(reply: @escaping (String, Bool) -> Void)
}

public enum CharlandHelperInfo {
    public static let label = "com.charstudio.charland.helper"
    public static let plistName = "com.charstudio.charland.helper.plist"
    public static let version = "2"
    /// Solo Charland, firmata dal team di Char Studio, può parlare con l'aiutante.
    public static let clientRequirement =
        "identifier \"com.charstudio.charland\" and anchor apple generic and certificate leaf[subject.OU] = \"2RLZS256X6\""
}
