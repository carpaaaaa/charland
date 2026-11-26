import AppKit
import CoreLocation
import MapKit
import SwiftUI
import CharlandCore

/// Il meteo della casa (carpa, 18 novembre 2026): il simbolo del tempo in alto a sinistra, al posto del giorno; la città
/// si sceglie al primo avvio o si prende dalla posizione; un clic sul simbolo apre Meteo.
///
/// Le previsioni vengono da MET Norway (l'istituto meteorologico norvegese, `api.met.no`): gratuite anche per un'app
/// in vendita, senza chiave, con l'obbligo di citarle e di farsi riconoscere nello User-Agent. WeatherKit di Apple
/// chiederebbe un profilo con la sua capacità, che la firma di Charland oggi non ha. Alla rete va solo la posizione
/// arrotondata a due decimali (circa un chilometro).
@MainActor @Observable
final class WeatherStore {
    static let shared = WeatherStore()

    /// Dove guardare il tempo. `nil` finché non l'hai scelto.
    enum Place: Codable, Equatable {
        case automatic
        case city(name: String, latitude: Double, longitude: Double)
    }

    struct Now: Codable, Equatable {
        var symbol: String
        var temperature: Double
        var place: String
        var fetched: Date
    }

    var place: Place? {
        didSet {
            // Con @Observable il didSet scatta anche dentro init: lì non si salva e non si chiede niente.
            guard ready, place != oldValue else { return }
            UserDefaults.standard.set(try? JSONEncoder().encode(place), forKey: Self.placeKey)
            if place == nil { current = nil }
            refresh()
        }
    }
    private(set) var current: Now?
    /// Il nome del posto trovato con la posizione (per «Automatica»).
    private(set) var detectedName: String?
    /// Qualcosa non va (posizione negata, niente rete): lo dicono le Impostazioni.
    private(set) var problem: String?
    private(set) var loading = false
    @ObservationIgnored private var loadingPlace: Place?
    /// Le Impostazioni mostrano la scelta della città (primo avvio, o clic sul meteo senza città).
    var askPlace = false
    /// Il simbolo a colori (sole giallo, gocce blu) o in bianco e nero come il resto dell'isola (carpa, 18 novembre 2026:
    /// «voglio che si possa rendere anche bianco e nero non colorato dalle impostazioni»). A colori di serie.
    var colored: Bool { didSet { if ready { UserDefaults.standard.set(colored, forKey: Self.coloredKey) } } }

    private static let placeKey = "weatherPlace"
    private static let nowKey = "weatherNow"
    private static let askedKey = "weatherAsked"
    private static let coloredKey = "weatherColored"
    /// Ogni quanto si chiede di nuovo il tempo: le previsioni di MET Norway cambiano ogni ora circa.
    private static let freshFor: TimeInterval = 30 * 60

    @ObservationIgnored private var ready = false
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private let locator = LocationOnce()

    private init() {
        let d = UserDefaults.standard
        colored = d.object(forKey: Self.coloredKey) == nil ? true : d.bool(forKey: Self.coloredKey)
        if let data = d.data(forKey: Self.placeKey) { place = try? JSONDecoder().decode(Place?.self, from: data) ?? nil }
        // L'ultimo tempo letto vale ancora per qualche ora: alla prima apertura dopo l'avvio c'è subito un simbolo.
        if let data = d.data(forKey: Self.nowKey), let saved = try? JSONDecoder().decode(Now.self, from: data),
           Date().timeIntervalSince(saved.fetched) < 3 * 3600 {
            current = saved
        }
        ready = true
    }

    /// La scelta è già stata proposta una volta (anche se hai detto «Più tardi»).
    var asked: Bool {
        get { UserDefaults.standard.bool(forKey: Self.askedKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.askedKey) }
    }

    /// Quello che dice il simbolo, per chi ci passa sopra: «14° · Milano».
    var summary: String {
        guard place != nil else { return String(localized: "Scegli la città del meteo") }
        guard let current else { return String(localized: "Meteo") }
        return "\(Int(current.temperature.rounded()))° · \(current.place)"
    }

    /// Il nome del posto, per le Impostazioni.
    var placeName: String? {
        switch place {
        case .city(let name, _, _)?: name
        case .automatic?: detectedName ?? current?.place
        case nil: nil
        }
    }

    /// Si apre la casa: se il tempo è vecchio si richiede. Da qui parte anche il controllo ogni mezz'ora.
    func ensureFresh() {
        if timer == nil {
            let timer = Timer(timeInterval: Self.freshFor, repeats: true) { _ in
                MainActor.assumeIsolated { WeatherStore.shared.refresh() }
            }
            timer.tolerance = 120
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        }
        if let current, Date().timeIntervalSince(current.fetched) < Self.freshFor { return }
        refresh()
    }


    /// Fermo: niente più richieste ogni mezz'ora.
    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// Per gli scatti e le scene: un tempo di prova, che non si salva e non chiede niente alla rete.
    func showForPreview(_ now: Now) {
        current = now
    }

    /// Un clic sul meteo nella casa: apre Meteo, o la scelta della città se non c'è ancora.
    func openFromIsland() {
        guard place != nil else {
            askPlace = true
            AppServices.shared.showSettings(section: .general)
            return
        }
        DockLaunch.open(bundle: "com.apple.weather")
    }

    func refresh() {
        guard let place else { return }
        // Già in corso per questo stesso posto: basta quella. Per un posto diverso si parte subito: prima una lettura
        // in corso bloccava tutte le altre, e scegliendo una città mentre «Automatica» aspettava la posizione (o la
        // risposta alla richiesta del permesso, che può non arrivare mai) il meteo non arrivava più fino al riavvio.
        if loading, loadingPlace == place { return }
        loading = true
        loadingPlace = place
        Task {
            // Solo la lettura più recente dice «finito».
            defer { if loadingPlace == place { loading = false; loadingPlace = nil } }
            do {
                let (coordinate, name) = try await resolve(place)
                let now = try await WeatherService.fetch(coordinate, place: name)
                guard self.place == place else { return }
                current = now
                problem = nil
                UserDefaults.standard.set(try? JSONEncoder().encode(now), forKey: Self.nowKey)
            } catch let error as LocationOnce.Failure {
                // l'errore di un posto che nel frattempo non è più quello scelto non si mostra
                if self.place == place { problem = error.message }
            } catch {
                if self.place == place { problem = String(localized: "Il meteo non risponde: riprovo fra poco.") }
            }
        }
    }

    private func resolve(_ place: Place) async throws -> (CLLocationCoordinate2D, String) {
        switch place {
        case .city(let name, let latitude, let longitude):
            return (CLLocationCoordinate2D(latitude: latitude, longitude: longitude), name)
        case .automatic:
            let location = try await locator.current()
            let name = await Self.cityName(of: location) ?? detectedName ?? String(localized: "Qui")
            detectedName = name
            return (location.coordinate, name)
        }
    }

    /// Il nome della città di una posizione, con MapKit.
    static func cityName(of location: CLLocation) async -> String? {
        guard let request = MKReverseGeocodingRequest(location: location),
              let item = try? await request.mapItems.first else { return nil }
        return item.addressRepresentations?.cityName ?? item.name
    }
}

// MARK: - Previsioni

enum WeatherService {
    /// Le previsioni di MET Norway per un punto: il tempo dell'ora che viene e la temperatura di adesso.
    static func fetch(_ coordinate: CLLocationCoordinate2D, place: String) async throws -> WeatherStore.Now {
        // Due decimali: circa un chilometro, abbastanza per il tempo e niente di più preciso esce dal Mac.
        let lat = String(format: "%.2f", coordinate.latitude), lon = String(format: "%.2f", coordinate.longitude)
        var request = URLRequest(url: URL(string: "https://api.met.no/weatherapi/locationforecast/2.0/compact?lat=\(lat)&lon=\(lon)")!)
        // MET Norway chiede che ogni app si faccia riconoscere: nome, versione e sito.
        request.setValue("\(Identity.name)/\(Identity.version) https://\(Identity.site)", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 15
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let properties = root["properties"] as? [String: Any],
              let series = properties["timeseries"] as? [[String: Any]] else { throw URLError(.badServerResponse) }
        // Il primo passo che non è già passato.
        let now = Date()
        let iso = ISO8601DateFormatter()
        let step = series.first { ($0["time"] as? String).flatMap(iso.date(from:)).map { $0.addingTimeInterval(3600) > now } ?? false }
            ?? series.first
        guard let step, let values = step["data"] as? [String: Any],
              let instant = (values["instant"] as? [String: Any])?["details"] as? [String: Any],
              let temperature = (instant["air_temperature"] as? NSNumber)?.doubleValue else { throw URLError(.cannotParseResponse) }
        let code = ["next_1_hours", "next_6_hours", "next_12_hours"].lazy
            .compactMap { ((values[$0] as? [String: Any])?["summary"] as? [String: Any])?["symbol_code"] as? String }
            .first ?? "cloudy"
        return WeatherStore.Now(symbol: symbol(for: code), temperature: temperature, place: place, fetched: now)
    }

    /// Dal codice di MET Norway (`partlycloudy_night`, `lightrainshowers_day`…) al simbolo di sistema più vicino.
    static func symbol(for code: String) -> String {
        let night = code.hasSuffix("_night") || code.hasSuffix("_polartwilight")
        let base = code.components(separatedBy: "_").first ?? code
        if base.contains("thunder") { return "cloud.bolt.rain.fill" }
        if base.contains("sleet") { return "cloud.sleet.fill" }
        if base.contains("snow") { return "cloud.snow.fill" }
        if base.contains("rainshowers") { return night ? "cloud.moon.rain.fill" : "cloud.sun.rain.fill" }
        if base.contains("heavyrain") { return "cloud.heavyrain.fill" }
        if base.contains("lightrain") { return "cloud.drizzle.fill" }
        if base.contains("rain") { return "cloud.rain.fill" }
        switch base {
        case "clearsky": return night ? "moon.stars.fill" : "sun.max.fill"
        case "fair": return night ? "moon.fill" : "sun.max.fill"
        case "partlycloudy": return night ? "cloud.moon.fill" : "cloud.sun.fill"
        case "fog": return "cloud.fog.fill"
        default: return "cloud.fill"
        }
    }
}

// MARK: - Posizione

/// Una posizione sola, quando serve: chiede il permesso la prima volta e poi si spegne subito.
@MainActor
final class LocationOnce: NSObject, CLLocationManagerDelegate {
    struct Failure: Error {
        let message: String
    }

    private let manager = CLLocationManager()
    private var waiting: [CheckedContinuation<CLLocation, Error>] = []

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyKilometer
    }

    func current() async throws -> CLLocation {
        // Una posizione di meno di un'ora va benissimo per il tempo.
        if let last = manager.location, Date().timeIntervalSince(last.timestamp) < 3600 { return last }
        return try await withCheckedThrowingContinuation { continuation in
            waiting.append(continuation)
            guard waiting.count == 1 else { return }
            switch manager.authorizationStatus {
            case .notDetermined: manager.requestWhenInUseAuthorization()
            case .denied, .restricted: finish(.failure(Self.denied))
            default: manager.requestLocation()
            }
        }
    }

    private static var denied: Failure {
        Failure(message: String(localized: "Charland non può usare la posizione: concedila in Impostazioni di Sistema › Privacy e sicurezza › Localizzazione, o scegli una città."))
    }

    private func finish(_ result: Result<CLLocation, Error>) {
        let all = waiting
        waiting = []
        all.forEach { $0.resume(with: result) }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        MainActor.assumeIsolated {
            guard !waiting.isEmpty else { return }
            switch status {
            case .notDetermined: break
            case .denied, .restricted: finish(.failure(Self.denied))
            default: self.manager.requestLocation()
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        MainActor.assumeIsolated { finish(.success(location)) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        let denied = (error as? CLError)?.code == .denied
        MainActor.assumeIsolated {
            finish(.failure(denied ? Self.denied : Failure(message: String(localized: "Non trovo la posizione: riprovo fra poco, o scegli una città."))))
        }
    }
}

// MARK: - Ricerca della città

/// I suggerimenti mentre scrivi il nome di una città, da MapKit.
@MainActor @Observable
final class CitySearch: NSObject, MKLocalSearchCompleterDelegate {
    var query = "" { didSet { completer.queryFragment = query } }
    private(set) var results: [MKLocalSearchCompletion] = []
    @ObservationIgnored private let completer = MKLocalSearchCompleter()

    override init() {
        super.init()
        completer.delegate = self
        completer.resultTypes = .address
        completer.addressFilter = MKAddressFilter(including: [.locality])
    }

    nonisolated func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        // MapKit risponde sul thread principale: i risultati si leggono di là, dal proprio completatore.
        MainActor.assumeIsolated { results = Array(self.completer.results.prefix(6)) }
    }

    nonisolated func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: Error) {
        MainActor.assumeIsolated { results = [] }
    }

    /// Dal suggerimento alle coordinate.
    static func resolve(_ completion: MKLocalSearchCompletion) async -> WeatherStore.Place? {
        let search = MKLocalSearch(request: MKLocalSearch.Request(completion: completion))
        guard let item = try? await search.start().mapItems.first else { return nil }
        let coordinate = item.location.coordinate
        let name = item.addressRepresentations?.cityName ?? completion.title
        return .city(name: name, latitude: coordinate.latitude, longitude: coordinate.longitude)
    }
}

/// Il campo per cercare una città, con i suggerimenti sotto.
struct CitySearchField: View {
    let chosen: (WeatherStore.Place) -> Void
    @State private var search = CitySearch()
    @State private var resolving = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("Cerca una città", text: $search.query)
                .textFieldStyle(.roundedBorder)
            if !search.query.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(search.results, id: \.self) { result in
                        Button {
                            resolving = true
                            Task {
                                if let place = await CitySearch.resolve(result) { chosen(place) }
                                resolving = false
                            }
                        } label: {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(result.title)
                                if !result.subtitle.isEmpty {
                                    Text(result.subtitle).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 4)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(resolving)
                    }
                }
            }
        }
    }
}

// MARK: - Impostazioni

/// Il meteo in Impostazioni › Generale: automatica o una città scelta.
struct WeatherSettingsSection: View {
    @Bindable private var weather = WeatherStore.shared
    @State private var changing = false

    var body: some View {
        Section {
            Picker("Città", selection: Binding(get: { weather.place == .automatic ? 1 : weather.place == nil ? 0 : 2 },
                                                set: { value in
                if value == 1 { weather.place = .automatic } else if value == 2 { changing = true }
            })) {
                if weather.place == nil { Text("Non scelta").tag(0) }
                Text("Automatica, dalla posizione").tag(1)
                Text(cityLabel).tag(2)
            }
            if changing || weather.askPlace && weather.place == nil {
                CitySearchField { place in
                    weather.place = place
                    changing = false
                }
            }
            if let current = weather.current {
                LabeledContent("Adesso") {
                    HStack(spacing: 6) {
                        Image(systemName: current.symbol).symbolRenderingMode(weather.colored ? .multicolor : .monochrome)
                        Text("\(Int(current.temperature.rounded()))° · \(current.place)")
                    }
                }
            }
            if let problem = weather.problem {
                Text(problem).font(.callout).foregroundStyle(.secondary)
            }
            Picker("Simbolo", selection: $weather.colored) {
                Text("A colori").tag(true)
                Text("Bianco e nero").tag(false)
            }
            .pickerStyle(.segmented)
        } header: {
            Text("Meteo")
        } footer: {
            Text("Il simbolo del tempo sta in alto a sinistra nella casa; un clic apre Meteo. Le previsioni sono di MET Norway (istituto meteorologico norvegese), che riceve solo la posizione arrotondata a circa un chilometro.")
        }
    }

    private var cityLabel: String {
        if case .city(let name, _, _)? = weather.place { return name }
        return String(localized: "Scegli una città…")
    }
}

/// Al primo avvio (o con un clic sul meteo senza città) le Impostazioni chiedono dove guardare il tempo.
struct WeatherSetupPresenter: ViewModifier {
    @Bindable private var weather = WeatherStore.shared

    func body(content: Content) -> some View {
        content
            .onAppear {
                if weather.place == nil, !weather.asked { weather.askPlace = true }
            }
            .sheet(isPresented: Binding(get: { weather.askPlace && weather.place == nil },
                                        set: { if !$0 { weather.askPlace = false } })) {
                WeatherSetupSheet()
            }
    }
}

struct WeatherSetupSheet: View {
    @Bindable private var weather = WeatherStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Image(systemName: "cloud.sun.fill").symbolRenderingMode(.multicolor).font(.system(size: 30))
            Text("Il meteo nella casa").font(.title2.weight(.semibold))
            Text("In alto a sinistra, aprendo l'isola, c'è il tempo di adesso. Dove lo guardiamo?")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button {
                done(.automatic)
            } label: {
                Label("Usa la mia posizione", systemImage: "location.fill").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            Text("Oppure scegli una città").font(.callout).foregroundStyle(.secondary)
            CitySearchField { done($0) }
            HStack {
                Spacer()
                Button("Più tardi") {
                    weather.asked = true
                    weather.askPlace = false
                }
            }
        }
        .padding(24)
        .frame(width: 380)
    }

    private func done(_ place: WeatherStore.Place) {
        weather.asked = true
        weather.place = place
        weather.askPlace = false
    }
}
