import AppKit

/// Le regolazioni che fanno consumare meno a Charland, messe una volta all'avvio.
@MainActor
enum Thrift {
    static func apply() {
        capFontCache()
    }

    /// CoreGraphics tiene in memoria i glifi già disegnati, raggruppati per carattere e per scala. Il suo tetto di serie
    /// (16 MB) conta solo i glifi: ogni gruppo ha però 4,6 KB suoi che non conta. L'isola e i widget disegnano il testo
    /// mentre cambia scala (ogni apertura, ogni chiusura, ogni cassetto), cioè decine di scale diverse per carattere a
    /// ogni movimento, ognuna un gruppo nuovo con pochi glifi dentro: il tetto non si raggiungeva mai e i gruppi si
    /// accumulavano. Misurato il 18 novembre 2026 sull'app installata: 12.000 gruppi e 55 MB dopo due ore e mezza, in
    /// crescita. Con un tetto di 1 MB i gruppi vecchi se ne vanno e ne restano poche centinaia (prova in isolamento:
    /// 3.000 scale, da 53 a 14 MB).
    ///
    /// Le due funzioni sono interne a CoreGraphics e si cercano a runtime: se un giorno mancano non cambia niente.
    private static func capFontCache() {
        typealias LocalCache = @convention(c) () -> OpaquePointer?
        typealias SetMaxSize = @convention(c) (OpaquePointer?, Int) -> Void
        let everywhere = UnsafeMutableRawPointer(bitPattern: -2)
        guard let get = dlsym(everywhere, "CGFontCacheGetLocalCache"),
              let set = dlsym(everywhere, "CGFontCacheSetMaxSize"),
              let cache = unsafeBitCast(get, to: LocalCache.self)() else { return }
        unsafeBitCast(set, to: SetMaxSize.self)(cache, 1 << 20)
    }
}
