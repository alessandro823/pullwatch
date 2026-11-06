import Foundation
import Testing
@testable import PullwatchCore
import PullwatchTestSupport

@Suite struct ModelsTests {
    @Test func accountDefaults() {
        let account = Account(kind: .gitHub, organization: "alessandro", authMethod: .cli)
        #expect(account.repoWatch.isEmpty)
        // Een nieuw account volgt niets tot je kiest; oude configs houden `.prs` (zie PopulateTests).
        #expect(account.newRepoDefault == .none)
        #expect(!account.followsAnything)
        #expect(!account.isPaused)
        #expect(account.includeDrafts == false)
        #expect(account.hideOwn == true)
    }

    @Test func followsAnythingWithOneRepoOrADefault() {
        var account = Account(kind: .gitHub, organization: "octo", authMethod: .gitHubApp)
        account.setWatch(.tags, for: "octo/a")
        #expect(account.followsAnything)
        account.setWatch(.none, for: "octo/a")
        account.newRepoDefault = .prs
        #expect(account.followsAnything)
    }

    @Test func pausedAccountsAreNotPolledAndRoundTrip() throws {
        var paused = Account(kind: .gitHub, organization: "octo", authMethod: .gitHubApp)
        paused.isPaused = true
        let active = Account(kind: .gitHub, organization: "mona", authMethod: .gitHubApp)
        let config = AppConfig(accounts: [paused, active])
        #expect(config.pollableAccounts.map(\.id) == [active.id])

        let decoded = try JSONDecoder().decode(Account.self, from: JSONEncoder().encode(paused))
        #expect(decoded.isPaused)
        // Een config van vóór de schakelaar: aan.
        let old = try JSONDecoder().decode(Account.self, from: JSONEncoder().encode(active))
        #expect(!old.isPaused)
    }

    @Test func legacyPullRequestJSONDecodesAsOpen() throws {
        let json = #"{"accountId":"00000000-0000-0000-0000-000000000001","repo":"proj/api","number":7,"title":"Oud","authorId":"a","authorName":"A","isDraft":false,"createdAt":1760000000,"webURL":"https://example.com/pr/7"}"#
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let pr = try decoder.decode(PullRequest.self, from: Data(json.utf8))
        #expect(pr.state == .open)
        #expect(pr.closedAt == nil)
    }

    @Test func pullRequestWithStateRoundTrips() throws {
        let closed = Date(timeIntervalSince1970: 1_760_005_000)
        let pr = PullRequest.fixture(state: .merged, closedAt: closed)
        let data = try JSONEncoder().encode(pr)
        let decoded = try JSONDecoder().decode(PullRequest.self, from: data)
        #expect(decoded == pr)
        #expect(decoded.state == .merged)
        #expect(decoded.closedAt == closed)
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

    @Test func tagReposAreDedupedCaseInsensitively() {
        let a = Account.fixture(repoWatch: ["O/A": .both, "o/a": .tags, "o/b": .tags, "o/c": .prs])
        #expect(a.tagRepos == ["O/A", "o/b"])
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

    /// Van vóór "Draft-PR's tonen": een account toont drafts, en bewaarde instellingen lezen het als
    /// `includeDrafts`, dat drafts toen ook liet zien. Zo telt de update als wijziging en haalt de
    /// sync de verborgen drafts op.
    @Test(arguments: [true, false])
    func `Settings from before showing drafts read it from including them`(includeDrafts: Bool) throws {
        let settings = #"{"kind":"gitHub","organization":"o","repoWatch":{},"newRepoDefault":"prs","includeDrafts":\#(includeDrafts),"hideOwn":true}"#
        let s = try JSONDecoder().decode(FilterSettings.self, from: Data(settings.utf8))
        #expect(s.showDrafts == includeDrafts)

        let account = #"{"id":"00000000-0000-0000-0000-000000000009","kind":"gitHub","organization":"o","authMethod":"pat","repoWatch":{},"newRepoDefault":"prs","includeDrafts":\#(includeDrafts),"hideOwn":true}"#
        let a = try JSONDecoder().decode(Account.self, from: Data(account.utf8))
        #expect(a.showDrafts)
        let again = try JSONDecoder().decode(Account.self, from: JSONEncoder().encode(a))
        #expect(again.showDrafts)
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

        let accounts = [Account(kind: .azureDevOps, organization: "acme", authMethod: .pat)]
        try store.save(accounts)
        #expect(try store.load() == accounts)
    }

    @Test func accountNameFollowsKindAndOrganization() throws {
        let octo = Account(kind: .gitHub, organization: "octo", authMethod: .gitHubApp).displayName
        #expect(octo == String(localized: "\("octo") op \("GitHub")", bundle: .localizedCore))
        #expect(octo.contains("octo") && octo.contains("GitHub"))
        #expect(Account(kind: .azureDevOps, organization: " ", authMethod: .cli).displayName == "Azure DevOps")
        // Een vroeger zelf gekozen naam wordt genegeerd; de naam wordt nog wel geschreven voor oudere versies.
        let old = #"{"id":"00000000-0000-0000-0000-000000000009","kind":"gitHub","displayName":"Mijn werk","organization":"acme","authMethod":"pat","repoWatch":{},"newRepoDefault":"prs","includeDrafts":false,"hideOwn":true}"#
        let account = try JSONDecoder().decode(Account.self, from: Data(old.utf8))
        #expect(account.displayName == Account(kind: .gitHub, organization: "acme", authMethod: .pat).displayName)
        #expect(!account.displayName.contains("Mijn werk"))
        let written = try JSONSerialization.jsonObject(with: JSONEncoder().encode(account)) as? [String: Any]
        #expect(written?["displayName"] as? String == account.displayName)
    }

    @Test func oneSignInFollowsSeveralOwners() throws {
        // Van voor meerdere eigenaren: alleen `organization`.
        let old = #"{"id":"00000000-0000-0000-0000-000000000009","kind":"gitHub","displayName":"x","organization":"acme","authMethod":"pat","repoWatch":{},"newRepoDefault":"prs","includeDrafts":false,"hideOwn":true}"#
        let migrated = try JSONDecoder().decode(Account.self, from: Data(old.utf8))
        #expect(migrated.owners == ["acme"])
        #expect(migrated.filterSettings.organization == "acme", "bestaande accounts beginnen niet opnieuw")

        var account = Account(kind: .gitHub, organization: "", authMethod: .gitHubApp, login: "jane")
        #expect(!account.isComplete)
        account.owners = ["jane", "acme"]
        #expect(account.isComplete)
        #expect(account.displayName == String(localized: "@\("jane") op \("GitHub")", bundle: .localizedCore))
        #expect(account.avatarURL?.absoluteString.contains("github.com/jane.png") == true)

        let again = try JSONDecoder().decode(Account.self, from: JSONEncoder().encode(account))
        #expect(again.owners == ["jane", "acme"])
        #expect(again.login == "jane")
        let written = try JSONSerialization.jsonObject(with: JSONEncoder().encode(account)) as? [String: Any]
        #expect(written?["organization"] as? String == "jane", "oudere versies lezen de eerste eigenaar")
    }

    @Test func onlyAccountsWithAnOrganisationAreComplete() {
        #expect(!Account(kind: .gitHub, organization: "  ", authMethod: .gitHubApp).isComplete)
        #expect(Account(kind: .azureDevOps, organization: "contoso", authMethod: .cli).isComplete)
        let config = AppConfig(accounts: [
            Account(kind: .gitHub, organization: "", authMethod: .pat),
            Account(kind: .gitHub, organization: "octo", authMethod: .pat),
        ])
        #expect(config.pollableAccounts.map(\.organization) == ["octo"])
    }

    @Test func gitHubAccountsHaveAPublicAvatar() {
        #expect(Account(kind: .gitHub, organization: "Vernum-Projecten", authMethod: .gitHubApp).avatarURL?.absoluteString
            == "https://github.com/Vernum-Projecten.png?size=128")
        #expect(Account(kind: .azureDevOps, organization: "contoso", authMethod: .cli).avatarURL == nil)
        #expect(Account(kind: .gitHub, organization: "", authMethod: .pat).avatarURL == nil)
    }

    @Test func onboardingStateLivesInTheConfig() throws {
        #expect(try JSONDecoder().decode(AppConfig.self, from: Data(#"{"accounts":[],"pollInterval":120}"#.utf8)).onboardingCompleted == false)
        var config = AppConfig()
        config.onboardingCompleted = true
        let again = try JSONDecoder().decode(AppConfig.self, from: JSONEncoder().encode(config))
        #expect(again.onboardingCompleted)
    }

    @Test func appPathsLiveInApplicationSupport() {
        let url = AppPaths.file("config.json")
        #expect(url.path(percentEncoded: false).hasSuffix("Application Support/Pullwatch/config.json"))
    }

    @Test func appPathsFollowTheDataDirectoryArgument() throws {
        let suite = "pullwatch.tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("/tmp/pullwatch ui test", forKey: AppPaths.directoryOverrideKey)
        #expect(AppPaths.file("config.json", defaults: defaults).path(percentEncoded: false) == "/tmp/pullwatch ui test/config.json")
        defaults.set("", forKey: AppPaths.directoryOverrideKey)
        #expect(AppPaths.file("config.json", defaults: defaults).path(percentEncoded: false).hasSuffix("Application Support/Pullwatch/config.json"))
    }

    @Test func jsonFileStoreWorksWithSpacesInPath() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
            .appending(path: "Application Support")
        defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }
        let store = JSONFileStore<[Account]>(url: dir.appending(path: "config.json"))

        let accounts = [Account(kind: .gitHub, organization: "alessandro", authMethod: .cli)]
        try store.save(accounts)
        #expect(try store.load() == accounts)
    }

    @Test func watchSetWithoutCompletedDecodesAsOff() throws {
        let set = try JSONDecoder().decode(WatchSet.self, from: Data(#"{"prs":true,"tags":false}"#.utf8))
        #expect(set == .prs)
        #expect(!set.completed)
    }

    @Test func setWatchKeepsCompletedEntry() {
        var a = Account.fixture(repoWatch: [:], newRepoDefault: .prs)
        a.setWatch(WatchSet(prs: true, tags: false, completed: true), for: "o/a")
        #expect(a.watch(for: "o/a").completed)
    }
}
