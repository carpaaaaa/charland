/// Quando chiedere una stella su GitHub (StarAsk nell'app): solo dopo un aggiornamento vero, mai alla prima
/// installazione, mai di nuovo dopo che chi usa l'app ha scelto (stella data o «Non chiedere più»).
public enum StarAskRule {
    public static func shouldAsk(previous: String?, current: String, done: Bool) -> Bool {
        guard !done, let previous, !previous.isEmpty else { return false }
        return previous != current
    }
}
