/// Quando chiedere una stella su GitHub (StarAsk nell'app): dopo ogni aggiornamento vero, mai alla prima installazione.
public enum StarAskRule {
    public static func shouldAsk(previous: String?, current: String) -> Bool {
        guard let previous, !previous.isEmpty else { return false }
        return previous != current
    }
}
