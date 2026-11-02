import Foundation

struct GeoResult {
    let country: String
    let ip: String
    let source: String
}

struct GeoError: Error, CustomStringConvertible {
    let message: String
    var description: String { message }
}

/// What the daemon does with the lookup results.
enum GeoVerdict {
    /// A provider placed the IP in a blocked region.
    case blocked(GeoResult)
    /// The region is outside the blocked set. `confirmedBy` is the second provider, when one was asked.
    case open(GeoResult, confirmedBy: GeoResult?)
    /// The first provider said open, no second provider confirmed it.
    case unconfirmed(GeoResult, String)
    /// No provider answered.
    case failed(String)
}

/// Look up the country of the public IP. Try several providers in order.
enum GeoLookup {
    private struct Provider {
        let name: String
        let url: String
        let parse: ([String: Any]) -> (country: String?, ip: String?)
    }

    /// HTTPS only. With plain HTTP anyone on the path, the VPN exit included, can forge the country.
    private static let providers: [Provider] = [
        Provider(name: "ipinfo.io", url: "https://ipinfo.io/json") {
            ($0["country"] as? String, $0["ip"] as? String)
        },
        Provider(name: "country.is", url: "https://api.country.is/") {
            ($0["country"] as? String, $0["ip"] as? String)
        },
        Provider(name: "ipwho.is", url: "https://ipwho.is/") {
            ($0["country_code"] as? String, $0["ip"] as? String)
        },
        Provider(name: "ipapi.co", url: "https://ipapi.co/json/") {
            ($0["country_code"] as? String, $0["ip"] as? String)
        },
        Provider(name: "ifconfig.co", url: "https://ifconfig.co/json") {
            ($0["country_iso"] as? String, $0["ip"] as? String)
        },
    ]

    /// Decide the state. Blocking needs one provider. Opening needs two providers that agree,
    /// because the geo databases differ and a wrong "open" is the costly mistake.
    static func check(blockedCountries: Set<String>, confirmOpen: Bool) -> GeoVerdict {
        let first: GeoResult
        switch lookup() {
        case .failure(let error):
            return .failed(error.message)
        case .success(let result):
            first = result
        }
        if blockedCountries.contains(first.country) { return .blocked(first) }
        guard confirmOpen else { return .open(first, confirmedBy: nil) }

        switch lookup(excluding: [first.source]) {
        case .failure(let error):
            return .unconfirmed(first, error.message)
        case .success(let second):
            if blockedCountries.contains(second.country) { return .blocked(second) }
            return .open(first, confirmedBy: second)
        }
    }

    /// Blocking call. Return the first successful provider result.
    static func lookup(excluding: Set<String> = []) -> Result<GeoResult, GeoError> {
        var errors: [String] = []
        for provider in providers where !excluding.contains(provider.name) {
            switch fetch(provider) {
            case .success(let result):
                return .success(result)
            case .failure(let error):
                errors.append("\(provider.name): \(error.message)")
            }
        }
        return .failure(GeoError(message: errors.joined(separator: " | ")))
    }

    /// A fresh session for every request. No connection from before a network change gets reused.
    private static func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 6
        config.timeoutIntervalForResource = 8
        config.waitsForConnectivity = false
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.httpAdditionalHeaders = [
            "User-Agent": "fence/\(FenceConfig.version)",
            "Accept": "application/json",
        ]
        return URLSession(configuration: config)
    }

    private static func fetch(_ provider: Provider) -> Result<GeoResult, GeoError> {
        guard let url = URL(string: provider.url), url.scheme == "https" else {
            return .failure(GeoError(message: "bad URL"))
        }
        let session = makeSession()
        defer { session.invalidateAndCancel() }
        let semaphore = DispatchSemaphore(value: 0)
        var outcome: Result<GeoResult, GeoError> = .failure(GeoError(message: "no response"))

        session.dataTask(with: URLRequest(url: url)) { data, response, error in
            defer { semaphore.signal() }
            if let error = error {
                outcome = .failure(GeoError(message: error.localizedDescription))
                return
            }
            guard let http = response as? HTTPURLResponse else {
                outcome = .failure(GeoError(message: "no HTTP response"))
                return
            }
            guard (200..<300).contains(http.statusCode) else {
                outcome = .failure(GeoError(message: "HTTP \(http.statusCode)"))
                return
            }
            guard let data = data,
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                outcome = .failure(GeoError(message: "bad JSON"))
                return
            }
            let parsed = provider.parse(object)
            guard let country = parsed.country?.uppercased(), country.count == 2,
                  country.allSatisfy({ $0.isLetter && $0.isASCII }),
                  let ip = parsed.ip, ip.count <= 45 else {
                outcome = .failure(GeoError(message: "no country in reply"))
                return
            }
            outcome = .success(GeoResult(country: country, ip: ip, source: provider.name))
        }.resume()

        if semaphore.wait(timeout: .now() + 12) == .timedOut {
            return .failure(GeoError(message: "timeout"))
        }
        return outcome
    }
}
