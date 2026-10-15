import Foundation
@testable import PullwatchCore

/// Route-matching op substring van de volledige URL; de EERSTE geregistreerde match wint.
/// Registreer dus specifieke routes vóór algemene.
final class MockHTTPClient: HTTPClient, @unchecked Sendable {
    private struct Route {
        let substring: String
        let status: Int
        let headers: [String: String]
        let body: String
    }

    private let lock = NSLock()
    private var routes: [Route] = []
    private var recorded: [URLRequest] = []

    var requests: [URLRequest] { lock.withLock { recorded } }

    func on(_ substring: String, status: Int = 200, headers: [String: String] = [:], body: String) {
        lock.withLock { routes.append(Route(substring: substring, status: status, headers: headers, body: body)) }
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let url = request.url!
        let route: Route? = lock.withLock {
            recorded.append(request)
            return routes.first { url.absoluteString.contains($0.substring) }
        }
        guard let route else { throw ProviderError.network("geen mock-route voor \(url.absoluteString)") }
        let response = HTTPURLResponse(url: url, statusCode: route.status, httpVersion: nil, headerFields: route.headers)!
        return (Data(route.body.utf8), response)
    }
}
