import Foundation

/// Een nieuwere Pullwatch op GitHub.
public struct AvailableUpdate: Equatable, Sendable {
    public let version: String
    /// Releasepagina met de release notes.
    public let pageURL: URL
    /// De DMG van de release; nil als die er (nog) niet bij staat.
    public let downloadURL: URL?
}

/// Kijkt naar de nieuwste release op GitHub (zonder token; publieke repo, 60 verzoeken per uur).
public enum UpdateChecker {
    public static let latestReleaseURL = URL(string: "https://api.github.com/repos/alessandro823/pullwatch/releases/latest")!
    /// Eens per dag, zoals de versiecheck.
    public static let interval: TimeInterval = 24 * 3600

    /// De nieuwste release als die nieuwer is dan `current` ("0.3.0"), anders nil.
    public static func check(current: String, http: any HTTPClient, now: Date = Date()) async throws -> AvailableUpdate? {
        struct Release: Decodable {
            struct Asset: Decodable {
                let name: String
                let browserDownloadUrl: URL
            }
            let tagName: String
            let htmlUrl: URL
            let assets: [Asset]
        }
        var request = URLRequest(url: latestReleaseURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, response) = try await http.send(request)
        try HTTPStatus.check(response, now: now)
        let release = try JSONDecoding.decode(Release.self, from: data, snakeCase: true)
        let version = release.tagName.hasPrefix("v") ? String(release.tagName.dropFirst()) : release.tagName
        guard isNewer(version, than: current) else { return nil }
        return AvailableUpdate(
            version: version,
            pageURL: release.htmlUrl,
            downloadURL: release.assets.first { $0.name.hasSuffix(".dmg") }?.browserDownloadUrl
        )
    }

    /// Alleen versienummers ("0.3.1"); pre-releases ("0.4.0-beta") tellen niet.
    static func isNewer(_ candidate: String, than current: String) -> Bool {
        guard candidate.allSatisfy({ $0.isNumber || $0 == "." }) else { return false }
        return VersionChecker.isOlder(current, than: candidate)
    }
}
