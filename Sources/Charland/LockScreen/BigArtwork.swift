import AppKit
import ImageIO
import CharlandCore

/// La copertina grande del brano che suona, dal catalogo di Apple (carpa, 19 novembre 2026: «tutte e 5», fra cui la
/// copertina nitida per Dynamic).
///
/// Le app di musica danno copertine da 600 a 1200 pixel; a tutto schermo, su 3420 pixel di larghezza, e per di più
/// ingrandite nelle inquadrature di Dynamic, si sgranano. Il catalogo di Apple (itunes.apple.com, la ricerca pubblica,
/// senza chiave) ha la stessa copertina fino a 3000 pixel: se ne prende una da `side` pixel.
///
/// Alla rete vanno titolo, artista e la regione del Mac, solo per le app di musica e solo negli stili a tutto schermo.
/// Lo stesso brano ha spesso più uscite (l'album, una raccolta, un singolo) con copertine diverse: si tiene quella che
/// somiglia alla copertina data dall'app, confrontate in piccolo, e se nessuna le somiglia niente. Le copertine si
/// tengono su disco (al massimo `kept`, le più vecchie vanno via); un «non c'è» vale una settimana. L'immagine torna già
/// decodificata: la prima volta che si disegna una foto così grande, decodificarla al momento costerebbe un fotogramma
/// lungo proprio sul blocco.
enum BigArtwork {
    nonisolated static let side = 2400
    /// Quante copertine grandi tenere su disco (da mezzo a due megabyte e mezzo l'una).
    nonisolated static let kept = 200

    nonisolated private static var folder: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent(Bundle.main.bundleIdentifier ?? "com.charstudio.charland").appendingPathComponent("copertine", isDirectory: true)
    }
    nonisolated private static func file(_ key: String, missing: Bool = false) -> URL {
        let name = key.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? String($0) : "_" }.joined()
        return folder.appendingPathComponent(String(name.prefix(120)) + (missing ? ".manca" : ".jpg"))
    }

    /// La copertina grande, o niente se il catalogo non la ha (o la rete non risponde).
    /// - Parameter like: la copertina data dall'app: la grande deve somigliarle.
    /// - Parameter retry: la richiesta di prima per questo brano aveva la copertina sbagliata come confronto: il suo
    ///   «non c'è» si toglie e si cerca di nuovo.
    nonisolated static func image(title: String, artist: String, album: String, duration: Double, like reference: CGImage? = nil,
                                  retry: Bool = false) async -> CGImage? {
        let key = LRCLIB.cacheKey(title: title, artist: artist, duration: duration) + "|" + LRCLIB.key(album)
        if let data = try? Data(contentsOf: file(key)) { return decode(data) }
        if retry { try? FileManager.default.removeItem(at: file(key, missing: true)) }
        if let at = (try? FileManager.default.attributesOfItem(atPath: file(key, missing: true).path))?[.modificationDate] as? Date,
           Date().timeIntervalSince(at) < 7 * 86400 { return nil }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        switch await search(title: title, artist: artist, album: album, duration: duration, like: reference) {
        case .offline: return nil
        case .missing:
            // solo un «non c'è» detto dal catalogo si ricorda; la rete che non risponde no
            FileManager.default.createFile(atPath: file(key, missing: true).path, contents: Data())
            return nil
        case .found(let url):
            guard let (data, status) = await get(url), status == 200, let image = decode(data) else { return nil }
            try? data.write(to: file(key), options: .atomic)
            prune()
            return image
        }
    }

    /// Cosa ha detto il catalogo: la copertina c'è (il suo indirizzo), non c'è, o la rete non ha risposto.
    private enum Found { case found(URL), missing, offline }

    /// Cerca il brano nel catalogo: stesso titolo (senza code come «feat.» o «Remastered»), stesso artista, la durata
    /// più vicina (entro 4 secondi se si sa). Torna l'indirizzo della copertina grande, o `url` vuoto se non c'è.
    nonisolated private static func search(title: String, artist: String, album: String, duration: Double, like reference: CGImage?) async -> Found {
        var c = URLComponents(string: "https://itunes.apple.com/search")
        let region = Locale.current.region?.identifier ?? "US"
        c?.queryItems = [URLQueryItem(name: "term", value: "\(artist) \(LRCLIB.clean(title))"), URLQueryItem(name: "entity", value: "song"),
                         URLQueryItem(name: "media", value: "music"), URLQueryItem(name: "limit", value: "15"), URLQueryItem(name: "country", value: region)]
        guard let url = c?.url, let (data, status) = await get(url), status == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let results = json["results"] as? [[String: Any]] else { return .offline }
        let wantTitle = LRCLIB.key(title), wantArtist = LRCLIB.key(artist), wantAlbum = LRCLIB.key(album)
        guard !wantTitle.isEmpty, !wantArtist.isEmpty else { return .missing }
        var candidates: [(score: Double, art: String)] = []
        for r in results {
            guard let art = r["artworkUrl100"] as? String, LRCLIB.key(r["trackName"] as? String ?? "") == wantTitle else { continue }
            let a = LRCLIB.key(r["artistName"] as? String ?? "")
            guard !a.isEmpty, a == wantArtist || a.contains(wantArtist) || wantArtist.contains(a) else { continue }
            var score = 0.0
            if let ms = r["trackTimeMillis"] as? Double, duration > 0 {
                let off = abs(ms / 1000 - duration)
                guard off <= 4 else { continue }
                score -= off
            }
            if !wantAlbum.isEmpty, LRCLIB.key(r["collectionName"] as? String ?? "") == wantAlbum { score += 3 }
            if !candidates.contains(where: { $0.art == art }) { candidates.append((score, art)) }
        }
        candidates.sort { $0.score > $1.score }
        var chosen = candidates.first?.art
        // con la copertina dell'app: fra le prime quattro quella che le somiglia di più, se le somiglia abbastanza
        if let reference, let mine = grid(reference) {
            chosen = nil
            var nearest = Double.infinity
            for candidate in candidates.prefix(4) {
                guard let url = URL(string: candidate.art), let (data, status) = await get(url), status == 200,
                      let thumb = decode(data), let theirs = grid(thumb) else { continue }
                let far = zip(mine, theirs).reduce(0) { $0 + abs($1.0 - $1.1) } / Double(mine.count)
                if far < nearest { nearest = far; chosen = candidate.art }
            }
            if nearest > likeness { chosen = nil }
        }
        // l'indirizzo della miniatura dice la misura: «100x100bb» diventa la misura voluta
        guard let art = chosen, let big = URL(string: art.replacingOccurrences(of: "100x100bb", with: "\(side)x\(side)bb")) else { return .missing }
        return .found(big)
    }

    nonisolated private static func get(_ url: URL) async -> (Data, Int)? {
        var request = URLRequest(url: url, timeoutInterval: 10)
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
        request.setValue("Charland/\(version) (https://charstudio.app)", forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await URLSession.shared.data(for: request), let http = response as? HTTPURLResponse else { return nil }
        return (data, http.statusCode)
    }

    /// Quanto possono differire in media due copertine (colori da 0 a 1 su una griglia 8×8) per dirsi la stessa: la
    /// stessa foto compressa in modo diverso sta sotto 0,04, due copertine diverse di solito sopra 0,15.
    nonisolated static let likeness = 0.1

    /// La copertina in piccolo: 8×8 pixel, rosso verde e blu da 0 a 1.
    nonisolated static func grid(_ image: CGImage) -> [Double]? {
        let side = 8
        var bytes = [UInt8](repeating: 0, count: side * side * 4)
        guard let ctx = CGContext(data: &bytes, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .medium
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
        var out: [Double] = []
        for i in 0..<(side * side) { out += [Double(bytes[i * 4]) / 255, Double(bytes[i * 4 + 1]) / 255, Double(bytes[i * 4 + 2]) / 255] }
        return out
    }

    /// Tiene su disco al massimo `kept` copertine: le più vecchie (per data di salvataggio) vanno via.
    nonisolated private static func prune() {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        let images = files.filter { $0.pathExtension == "jpg" }
        guard images.count > kept else { return }
        let dated = images.map { ($0, (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) }
        for (url, _) in dated.sorted(by: { $0.1 < $1.1 }).prefix(images.count - kept) { try? fm.removeItem(at: url) }
    }

    /// Decodifica subito, fuori dal thread principale: l'immagine torna già pronta da disegnare.
    nonisolated private static func decode(_ data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
    }
}
