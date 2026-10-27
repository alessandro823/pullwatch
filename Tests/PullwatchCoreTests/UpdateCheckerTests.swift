import Foundation
import Testing
@testable import PullwatchCore

@Suite struct UpdateCheckerTests {
    let release = #"""
    {"tag_name":"v0.3.1","html_url":"https://github.com/alessandro823/pullwatch/releases/tag/v0.3.1",
     "assets":[{"name":"notes.txt","browser_download_url":"https://x/notes.txt"},
               {"name":"Pullwatch-0.3.1.dmg","browser_download_url":"https://x/Pullwatch-0.3.1.dmg"}]}
    """#

    @Test func reportsNewerReleaseWithDMG() async throws {
        let http = MockHTTPClient()
        http.on("releases/latest", body: release)

        let update = try await UpdateChecker.check(current: "0.3.0", http: http)

        #expect(update?.version == "0.3.1")
        #expect(update?.downloadURL?.absoluteString == "https://x/Pullwatch-0.3.1.dmg")
        #expect(update?.pageURL.absoluteString.hasSuffix("/v0.3.1") == true)
    }

    @Test func sameOrOlderIsNoUpdate() async throws {
        let http = MockHTTPClient()
        http.on("releases/latest", body: release)
        #expect(try await UpdateChecker.check(current: "0.3.1", http: http) == nil)
        #expect(try await UpdateChecker.check(current: "0.10.0", http: http) == nil)
    }

    @Test func comparesNumericallyAndSkipsPrereleases() {
        #expect(UpdateChecker.isNewer("0.10.0", than: "0.9.1"))
        #expect(UpdateChecker.isNewer("1.0", than: "0.9.9"))
        #expect(!UpdateChecker.isNewer("0.4.0-beta", than: "0.3.0"))
    }

    @Test func noReleaseYetIsAnError() async {
        let http = MockHTTPClient()
        http.on("releases/latest", status: 404, body: "{}")
        await #expect(throws: ProviderError.self) { try await UpdateChecker.check(current: "0.3.0", http: http) }
    }
}
