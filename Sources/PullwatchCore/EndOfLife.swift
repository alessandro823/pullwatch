import Foundation

public enum VersionStatus: String, Codable, Sendable, Comparable {
    case current, behind, eol, unknown

    /// Hoe erg: EOL eerst, dan achter, onbekend, actueel.
    public var severity: Int {
        switch self {
        case .eol: 3
        case .behind: 2
        case .unknown: 1
        case .current: 0
        }
    }

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.severity < rhs.severity }
}

/// Eén releasecyclus van een product bij endoflife.date (bv. Go "1.27", .NET "8").
public struct EndOfLifeRelease: Equatable, Sendable {
    public let name: String
    /// "yyyy-MM-dd".
    public let releaseDate: String
    public let isEol: Bool
    /// Nieuwste patch binnen deze cyclus.
    public let latest: String?

    public init(name: String, releaseDate: String, isEol: Bool, latest: String?) {
        self.name = name
        self.releaseDate = releaseDate
        self.isEol = isEol
        self.latest = latest
    }
}

public enum EndOfLife {
    public static func url(product: String) -> URL {
        URL(string: "https://endoflife.date/api/v1/products")!.appending(path: product)
    }

    public static func decode(_ data: Data) throws -> [EndOfLifeRelease] {
        struct Response: Decodable {
            struct Result: Decodable { let releases: [Release] }
            struct Release: Decodable {
                struct Latest: Decodable { let name: String }
                let name: String
                let releaseDate: String
                let isEol: Bool?
                let latest: Latest?
            }
            let result: Result
        }
        let response = try JSONDecoding.decode(Response.self, from: data)
        return response.result.releases.map {
            EndOfLifeRelease(name: $0.name, releaseDate: $0.releaseDate, isEol: $0.isEol ?? false, latest: $0.latest?.name)
        }
    }

    public static func fetch(product: String, http: any HTTPClient, now: Date = Date()) async throws -> [EndOfLifeRelease] {
        var request = URLRequest(url: url(product: product))
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await http.send(request)
        try HTTPStatus.check(response, now: now)
        return try decode(data)
    }

    /// Patches tellen niet: alleen een nieuwere cyclus (major/minor) maakt een versie "achter".
    public static func evaluate(version: String, releases: [EndOfLifeRelease], now: Date) -> (status: VersionStatus, latest: String?) {
        let today = now.formatted(Date.ISO8601FormatStyle(timeZone: .gmt).year().month().day())
        let released = releases.filter { $0.releaseDate <= today }
        guard let newest = released.max(by: { $0.releaseDate < $1.releaseDate }) else { return (.unknown, nil) }
        let latest = newest.latest ?? newest.name
        let match = released
            .filter { version == $0.name || version.hasPrefix($0.name + ".") }
            .max { $0.name.count < $1.name.count }
        guard let match else { return (.unknown, latest) }
        if match.isEol { return (.eol, latest) }
        return (match.name == newest.name ? .current : .behind, latest)
    }
}
