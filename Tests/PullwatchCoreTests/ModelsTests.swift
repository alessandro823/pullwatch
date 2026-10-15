import Foundation
import Testing
@testable import PullwatchCore

@Suite struct ModelsTests {
    @Test func accountDefaults() {
        let account = Account(kind: .gitHub, displayName: "Eigen", organization: "alessandro", authMethod: .cli)
        #expect(account.filterMode == .deny)
        #expect(account.repos.isEmpty)
        #expect(account.includeDrafts == false)
        #expect(account.hideOwn == true)
    }

    @Test func dedupKeyCombinesAccountRepoAndNumber() {
        let pr = PullRequest.fixture(repo: "proj/api", number: 42)
        #expect(pr.dedupKey == "00000000-0000-0000-0000-000000000001:proj/api:42")
    }

    @Test func jsonFileStoreReturnsNilWhenMissingAndRoundTrips() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = JSONFileStore<[Account]>(url: dir.appending(path: "nested/accounts.json"))

        #expect(try store.load() == nil)

        let accounts = [Account(kind: .azureDevOps, displayName: "Werk", organization: "acme", authMethod: .pat)]
        try store.save(accounts)
        #expect(try store.load() == accounts)
    }

    @Test func appPathsLiveInApplicationSupport() {
        let url = AppPaths.file("config.json")
        #expect(url.path(percentEncoded: false).hasSuffix("Application Support/Pullwatch/config.json"))
    }

    @Test func jsonFileStoreWorksWithSpacesInPath() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
            .appending(path: "Application Support")
        defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }
        let store = JSONFileStore<[Account]>(url: dir.appending(path: "config.json"))

        let accounts = [Account(kind: .gitHub, displayName: "Eigen", organization: "alessandro", authMethod: .cli)]
        try store.save(accounts)
        #expect(try store.load() == accounts)
    }
}
