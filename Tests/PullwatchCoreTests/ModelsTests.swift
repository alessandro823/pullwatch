import Foundation
import Testing
@testable import PullwatchCore

@Suite struct ModelsTests {
    @Test func accountDefaults() {
        let account = Account(kind: .gitHub, displayName: "Eigen", organization: "alessandro", authMethod: .cli)
        #expect(account.repoWatch.isEmpty)
        #expect(account.newRepoDefault == .prs)
        #expect(account.includeDrafts == false)
        #expect(account.hideOwn == true)
    }

    @Test func legacyDenyConfigMigrates() throws {
        let json = #"{"id":"00000000-0000-0000-0000-000000000009","kind":"gitHub","displayName":"X","organization":"o","authMethod":"pat","filterMode":"deny","repos":["o/legacy"],"includeDrafts":false,"hideOwn":true}"#
        let a = try JSONDecoder().decode(Account.self, from: Data(json.utf8))
        #expect(a.newRepoDefault == .prs)
        #expect(a.repoWatch == ["o/legacy": .none])
        #expect(a.watch(for: "o/other") == .prs)
        #expect(a.tagRepos.isEmpty)
    }

    @Test func legacyAllowConfigMigrates() throws {
        let json = #"{"id":"00000000-0000-0000-0000-000000000009","kind":"gitHub","displayName":"X","organization":"o","authMethod":"pat","filterMode":"allow","repos":["o/api"],"includeDrafts":false,"hideOwn":true}"#
        let a = try JSONDecoder().decode(Account.self, from: Data(json.utf8))
        #expect(a.newRepoDefault == .none)
        #expect(a.repoWatch == ["o/api": .prs])
        #expect(a.watch(for: "o/other") == .none)
    }

    @Test func newFormatRoundTrips() throws {
        let a = Account.fixture(repoWatch: ["o/a": .both, "o/b": .tags], newRepoDefault: .none)
        let data = try JSONEncoder().encode(a)
        #expect(try JSONDecoder().decode(Account.self, from: data) == a)
        let text = String(decoding: data, as: UTF8.self)
        #expect(!text.contains("filterMode"))
        #expect(!text.contains("\"repos\""))
        #expect(a.tagRepos == ["o/a", "o/b"])
    }

    @Test func watchLookupIsCaseInsensitive() {
        let a = Account.fixture(repoWatch: ["Proj/Api": .both], newRepoDefault: .none)
        #expect(a.watch(for: "proj/api") == .both)
        #expect(a.watch(for: "proj/x") == .none)
    }

    @Test func setWatchReusesExistingKeyCaseInsensitively() {
        var a = Account.fixture(repoWatch: ["Proj/Api": .prs], newRepoDefault: .none)
        a.setWatch(.both, for: "proj/api")
        #expect(a.repoWatch == ["Proj/Api": .both])
    }

    @Test func setWatchAddsNewKey() {
        var a = Account.fixture(repoWatch: [:], newRepoDefault: .none)
        a.setWatch(.tags, for: "o/new")
        #expect(a.repoWatch == ["o/new": .tags])
    }

    @Test func setWatchDropsEntryEqualToDefaultWithoutTags() {
        var a = Account.fixture(repoWatch: ["o/a": .both], newRepoDefault: .prs)
        a.setWatch(.prs, for: "O/A")
        #expect(a.repoWatch.isEmpty)
        var b = Account.fixture(repoWatch: ["o/a": .prs], newRepoDefault: .none)
        b.setWatch(.none, for: "o/a")
        #expect(b.repoWatch.isEmpty)
    }

    @Test func setWatchKeepsExplicitOptOutAndTagEntries() {
        var a = Account.fixture(repoWatch: [:], newRepoDefault: .prs)
        a.setWatch(.none, for: "o/a")
        #expect(a.repoWatch == ["o/a": .none])
        a.setWatch(.tags, for: "o/b")
        a.setWatch(.both, for: "o/c")
        #expect(a.repoWatch["o/b"] == .tags)
        #expect(a.repoWatch["o/c"] == .both)
    }

    @Test func mergedRepoNamesCollapsesCaseDuplicatesToProviderCasing() {
        let merged = Account.mergedRepoNames(available: ["proj/api"], configured: ["Proj/Api"])
        #expect(merged == ["proj/api"])
    }

    @Test func mergedRepoNamesKeepsConfigOnlyAndSortsCaseInsensitively() {
        let merged = Account.mergedRepoNames(available: ["b/x", "A/y"], configured: ["c/gone", "B/X"])
        #expect(merged == ["A/y", "b/x", "c/gone"])
    }

    @Test func legacyLastSettingsDecode() throws {
        let json = #"{"kind":"gitHub","organization":"o","filterMode":"allow","repos":["o/api"],"includeDrafts":false,"hideOwn":true}"#
        let s = try JSONDecoder().decode(FilterSettings.self, from: Data(json.utf8))
        #expect(s.newRepoDefault == .none)
        #expect(s.repoWatch == ["o/api": .prs])
        #expect(s.watch(for: "o/api") == .prs)
    }

    @Test func dedupKeyCombinesAccountRepoAndNumber() {
        let pr = PullRequest.fixture(repo: "proj/api", number: 42)
        #expect(pr.dedupKey == "00000000-0000-0000-0000-000000000001:proj/api:42")
    }

    @Test func tagDedupKeyIsDistinctFromPR() {
        let tag = Tag.fixture(repo: "Proj/API", name: "v1")
        #expect(tag.dedupKey == "00000000-0000-0000-0000-000000000001:proj/api:tag:v1")
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
