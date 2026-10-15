import Foundation
import Testing
@testable import PullwatchCore

@Suite struct HTTPTests {
    let now = Date(timeIntervalSince1970: 1_760_000_000)

    func response(_ status: Int, _ headers: [String: String] = [:]) -> HTTPURLResponse {
        HTTPURLResponse(url: URL(string: "https://x")!, statusCode: status, httpVersion: nil, headerFields: headers)!
    }

    func checkError(_ r: HTTPURLResponse) -> ProviderError? {
        do { try HTTPStatus.check(r, now: now); return nil } catch let e as ProviderError { return e } catch { return nil }
    }

    @Test func successPasses() {
        #expect(checkError(response(200)) == nil)
    }

    @Test func azureDevOps203LoginPageIsUnauthorized() {
        #expect(checkError(response(203)) == .unauthorized)
    }

    @Test func unauthorized401() {
        #expect(checkError(response(401)) == .unauthorized)
    }

    @Test func retryAfterOn429() {
        #expect(checkError(response(429, ["Retry-After": "30"])) == .rateLimited(until: now + 30))
    }

    @Test func gitHubRateLimit403UsesResetHeader() {
        let r = response(403, ["X-RateLimit-Remaining": "0", "X-RateLimit-Reset": "1760000600"])
        #expect(checkError(r) == .rateLimited(until: Date(timeIntervalSince1970: 1_760_000_600)))
    }

    @Test func plain403IsUnauthorized() {
        #expect(checkError(response(403)) == .unauthorized)
    }

    @Test func serverError() {
        #expect(checkError(response(503)) == .server(status: 503))
    }

    @Test func parsesDatesWithAndWithoutFractionalSeconds() {
        let expected = Date(timeIntervalSince1970: 1_760_522_400) // 2025-10-15T10:00:00Z
        #expect(DateParsing.parse("2025-10-15T10:00:00Z") == expected)
        #expect(DateParsing.parse("2025-10-15T10:00:00.123Z") == expected)
        #expect(DateParsing.parse("2025-10-15T10:00:00.1234567Z") == expected)
        #expect(DateParsing.parse("garbage") == nil)
    }

    @Test func decodingErrorBecomesProviderError() {
        struct Thing: Decodable { let name: String }
        #expect(throws: ProviderError.self) {
            _ = try JSONDecoding.decode(Thing.self, from: Data("<html>".utf8))
        }
    }

    @Test func snakeCaseDecoding() throws {
        struct Thing: Decodable { let htmlUrl: String }
        let thing = try JSONDecoding.decode(Thing.self, from: Data(#"{"html_url":"u"}"#.utf8), snakeCase: true)
        #expect(thing.htmlUrl == "u")
    }
}
