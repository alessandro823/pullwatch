import Foundation
import Testing
@testable import PullwatchCore
import PullwatchTestSupport

/// Losse repo's (`Account.extraRepos`): wat je intypt of plakt, de config, en dat een net
/// toegevoegde repo zijn bestaande PR's niet als nieuw meldt.
@Suite struct ExtraReposTests {
    func parse(
        _ input: String,
        _ kind: ProviderKind = .gitHub,
        organization: String = "contoso",
        instance: URL? = nil
    ) -> Result<String, RepositoryProblem> {
        Result { () throws(RepositoryProblem) -> String in
            try RepositoryReference.parse(input, kind: kind, organization: organization, instanceURL: instance)
        }
    }

    // MARK: Intypen en plakken

    @Test(arguments: [
        "openEHR/specifications-AM",
        "  openEHR/specifications-AM  ",
        "https://github.com/openEHR/specifications-AM",
        "https://github.com/openEHR/specifications-AM/",
        "https://github.com/openEHR/specifications-AM.git",
        "https://github.com/openEHR/specifications-AM/tree/master/docs",
        "https://github.com/openEHR/specifications-AM/pull/50",
        "http://www.github.com/openEHR/specifications-AM",
        "github.com/openEHR/specifications-AM",
        "git@github.com:openEHR/specifications-AM.git",
    ])
    func readsGitHubNamesAndLinks(_ input: String) {
        #expect(parse(input) == .success("openEHR/specifications-AM"))
    }

    @Test(arguments: ["", "openEHR", "a/b/c", "https://github.com/openEHR", "open EHR/x", "owner/re po", "owner/..", "ftp://example.com/a/b"])
    func refusesWhatIsNoGitHubRepo(_ input: String) {
        #expect(parse(input) == .failure(.unrecognised(.gitHub)))
    }

    @Test(arguments: [
        "Website/web",
        "https://dev.azure.com/contoso/Website/_git/web",
        "https://contoso@dev.azure.com/contoso/Website/_git/web",
        "https://dev.azure.com/contoso/Website/_git/web?path=/README.md",
        "https://contoso.visualstudio.com/Website/_git/web",
        "https://contoso.visualstudio.com/DefaultCollection/Website/_git/web",
        "git@ssh.dev.azure.com:v3/contoso/Website/web",
    ])
    func readsAzureDevOpsNamesAndLinks(_ input: String) {
        #expect(parse(input, .azureDevOps) == .success("Website/web"))
    }

    @Test func keepsSpacesInAzureDevOpsProjects() {
        #expect(parse("https://dev.azure.com/contoso/My%20Project/_git/web", .azureDevOps) == .success("My Project/web"))
        #expect(parse("My Project/web", .azureDevOps) == .success("My Project/web"))
    }

    @Test func aLinkToTheOtherServiceSaysSo() {
        #expect(parse("https://dev.azure.com/contoso/Website/_git/web") == .failure(.otherService(.azureDevOps)))
        #expect(parse("https://github.com/openEHR/specifications-AM", .azureDevOps) == .failure(.otherService(.gitHub)))
    }

    @Test func azureDevOpsLinkOfAnotherOrganisation() {
        #expect(parse("https://dev.azure.com/fabrikam/Website/_git/web", .azureDevOps)
            == .failure(.otherOrganization(found: "fabrikam", expected: "contoso")))
        #expect(parse("https://CONTOSO.visualstudio.com/Website/_git/web", .azureDevOps) == .success("Website/web"))
    }

    @Test func azureDevOpsProjectPageIsNotARepo() {
        #expect(parse("https://dev.azure.com/contoso/Website", .azureDevOps) == .failure(.unrecognised(.azureDevOps)))
        #expect(parse("Website/_git", .azureDevOps) == .failure(.unrecognised(.azureDevOps)))
    }

    @Test(arguments: [
        "gitlab-org/security-products/analyzers/semgrep",
        "https://gitlab.com/gitlab-org/security-products/analyzers/semgrep",
        "https://gitlab.com/gitlab-org/security-products/analyzers/semgrep/",
        "https://gitlab.com/gitlab-org/security-products/analyzers/semgrep.git",
        "https://gitlab.com/gitlab-org/security-products/analyzers/semgrep/-/merge_requests/12",
        "https://gitlab.com/gitlab-org/security-products/analyzers/semgrep/-/tree/main/rules",
        "https://www.gitlab.com/gitlab-org/security-products/analyzers/semgrep",
        "gitlab.com/gitlab-org/security-products/analyzers/semgrep",
        "git@gitlab.com:gitlab-org/security-products/analyzers/semgrep.git",
    ])
    func readsGitLabPathsWithNestedGroupsAndLinks(_ input: String) {
        #expect(parse(input, .gitLab) == .success("gitlab-org/security-products/analyzers/semgrep"))
    }

    @Test func readsGitLabPathsAndLinksOfTheOwnServer() {
        let server = URL(string: "https://code.example.com")!
        for input in [
            "team/app",
            "https://code.example.com/team/app/-/merge_requests/3",
            "git@code.example.com:team/app.git",
            "ssh://git@code.example.com:2222/team/app.git",
        ] {
            #expect(parse(input, .gitLab, instance: server) == .success("team/app"), "\(input)")
        }
        // Een server onder een pad: dat pad hoort niet bij het project.
        let prefixed = URL(string: "https://example.com/gitlab")!
        #expect(parse("https://example.com/gitlab/team/app/-/tags", .gitLab, instance: prefixed) == .success("team/app"))
        // Een groep met een punt is geen link.
        #expect(parse("acme.io/app", .gitLab) == .success("acme.io/app"))
    }

    @Test(arguments: [
        "", "group", "group/-/project", "-group/project", ".hidden/project", "group/pro ject",
        "https://gitlab.com/groups/acme/sub", "https://gitlab.com/acme", "https://gitlab.com/users/jdoe/x",
    ])
    func refusesWhatIsNoGitLabProject(_ input: String) {
        #expect(parse(input, .gitLab) == .failure(.unrecognised(.gitLab)))
    }

    @Test func gitLabAllowsTwentySubgroupsAndNoMore() {
        let deepest = (1...21).map { "g\($0)" }.joined(separator: "/") + "/project"
        #expect(parse(deepest, .gitLab) == .success(deepest))
        #expect(parse("g0/" + deepest, .gitLab) == .failure(.unrecognised(.gitLab)))
    }

    @Test func aGitLabLinkToAnotherServerSaysSo() {
        let server = URL(string: "https://code.example.com")!
        #expect(parse("https://gitlab.com/gitlab-org/cli", .gitLab, instance: server)
            == .failure(.otherServer(found: "gitlab.com", expected: "code.example.com")))
        #expect(parse("https://code.example.com/team/app", .gitLab)
            == .failure(.otherServer(found: "code.example.com", expected: "gitlab.com")))
        #expect(parse("git@other.example.org:team/app.git", .gitLab, instance: server)
            == .failure(.otherServer(found: "other.example.org", expected: "code.example.com")))
        #expect(parse("https://github.com/openEHR/specifications-AM", .gitLab) == .failure(.otherService(.gitHub)))
        #expect(parse("https://gitlab.com/gitlab-org/cli") == .failure(.otherService(.gitLab)))
    }

    @Test func everyServiceHasExtraRepos() {
        #expect(ProviderKind.allCases.allSatisfy { $0.supportsExtraRepos })
    }

    @Test func problemsReadAsPlainWords() {
        for problem: RepositoryProblem in [
            .unrecognised(.gitHub), .unrecognised(.azureDevOps), .otherService(.gitHub),
            .otherOrganization(found: "a", expected: "b"), .alreadyAdded("a/b"), .unsupported,
            .unrecognised(.gitLab), .otherServer(found: "gitlab.com", expected: "code.example.com"),
        ] {
            #expect(!problem.userMessage.isEmpty)
            #expect(!problem.userMessage.contains("\u{2014}") && !problem.userMessage.contains("\u{00B7}"))
        }
        #expect(RepositoryProblem.alreadyAdded("a/b").userMessage.contains("a/b"))
    }

    // MARK: Het account

    @Test func oldConfigHasNoExtraRepos() throws {
        let json = #"""
            {"id":"6F1D3C1E-6B1A-4E36-9C5B-3C8D0E8B8A11","kind":"gitHub","organization":"octo","owners":["octo"],
             "authMethod":"gitHubApp","repoWatch":{},"newRepoDefault":"prs","includeDrafts":false,"hideOwn":true}
            """#
        let account = try JSONDecoder().decode(Account.self, from: Data(json.utf8))
        #expect(account.extraRepos.isEmpty)
        let encoded = String(decoding: try JSONEncoder().encode(account), as: UTF8.self)
        #expect(!encoded.contains("extraRepos"), "een account zonder losse repo's schrijft het veld niet")
    }

    @Test func extraReposRoundTrip() throws {
        var account = Account(kind: .gitHub, organization: "octo", authMethod: .gitHubApp)
        account.addExtraRepo("openEHR/specifications-AM")
        let decoded = try JSONDecoder().decode(Account.self, from: JSONEncoder().encode(account))
        #expect(decoded.extraRepos == ["openEHR/specifications-AM"])
        #expect(decoded.watch(for: "openehr/specifications-am") == .prs, "toevoegen volgt de PR's")
    }

    @Test func addingTwiceKeepsOneAndRemovingForgetsTheWatch() {
        var account = Account(kind: .gitHub, organization: "octo", authMethod: .gitHubApp)
        account.addExtraRepo("openEHR/b")
        account.addExtraRepo("OPENEHR/B", watch: .both)
        account.addExtraRepo("apache/a")
        #expect(account.extraRepos == ["apache/a", "openEHR/b"])
        #expect(account.watch(for: "openEHR/b") == .both)
        #expect(account.followsAnything)

        account.removeExtraRepo("openehr/B")
        #expect(account.extraRepos == ["apache/a"])
        #expect(account.repoWatch["openEHR/b"] == nil)
    }

    @Test func onlyExtrasOutsideTheOwnersNeedTheirOwnSearch() {
        var account = Account(kind: .gitHub, organization: "octo", authMethod: .gitHubApp)
        account.extraRepos = ["Octo/inside", "openEHR/outside", "openehr/OUTSIDE"]
        #expect(account.extraReposOutsideOwners == ["openEHR/outside"])
    }

    @Test func extrasShowInTheRepoOverviewEvenAtTheDefault() {
        var account = Account(kind: .gitHub, organization: "octo", authMethod: .gitHubApp, newRepoDefault: .prs)
        account.extraRepos = ["openEHR/specifications-AM"]
        let summaries = RepoOverview.summaries(accounts: [account], report: nil, history: History())
        #expect(summaries.map(\.repo) == ["openEHR/specifications-AM"])
        #expect(summaries.first?.group.project == "openEHR", "onder hun eigen eigenaar")
    }

    // MARK: Filter en melden

    @Test func filterSettingsCoverOwnersAndExtras() {
        var account = Account(kind: .gitHub, organization: "octo", authMethod: .gitHubApp)
        account.owners = ["octo", "mona"]
        account.extraRepos = ["openEHR/Specs"]
        let settings = account.filterSettings
        #expect(settings.covers(repo: "Octo/x"))
        #expect(settings.covers(repo: "mona/y"))
        #expect(settings.covers(repo: "openehr/specs"))
        #expect(!settings.covers(repo: "openEHR/other"))
        #expect(Account.fixture(kind: .azureDevOps).filterSettings.covers(repo: "any/thing"))
    }

    @Test func oldFilterSettingsDecodeWithoutExtras() throws {
        let json = #"{"kind":"gitHub","organization":"octo","repoWatch":{},"newRepoDefault":"prs","includeDrafts":false,"hideOwn":true}"#
        let settings = try JSONDecoder().decode(FilterSettings.self, from: Data(json.utf8))
        #expect(settings.extraRepos.isEmpty)
        // Oude JSON zonder `showDrafts` met `includeDrafts` uit verborg drafts: zo'n account toen.
        #expect(settings == Account(kind: .gitHub, organization: "octo", authMethod: .cli, newRepoDefault: .prs, showDrafts: false).filterSettings)
    }

    @Test func addingAnExtraRepoStartsAFreshHistorySync() {
        var account = Account(kind: .gitHub, organization: "octo", authMethod: .gitHubApp, newRepoDefault: .prs)
        let before = account.filterSettings
        account.addExtraRepo("openEHR/specs", watch: .prs)
        #expect(before.sameSource(as: account.filterSettings))
        #expect(!before.sameSyncScope(as: account.filterSettings), "de geschiedenis van de nieuwe repo moet nog komen")
    }

    @Test func addedExtraRepoSeedsItsOpenPullRequestsSilently() async {
        var account = Account.fixture(kind: .gitHub, organization: "octo", newRepoDefault: .prs)
        let provider = MockProvider()
        let clock = TestClock()
        let engine = PollEngine(makeProvider: { _ in provider }, store: nil, now: { clock.now })
        let own = PullRequest.fixture(accountId: account.id, repo: "octo/app", number: 1)
        await provider.set(pullRequests: [own])
        _ = await engine.poll(accounts: [account], interval: 120, retention: .oneYear)

        // De repo komt erbij: zijn bestaande open PR's zijn niet nieuw.
        account.addExtraRepo("openEHR/specs")
        let existing = PullRequest.fixture(accountId: account.id, repo: "openEHR/specs", number: 50)
        await provider.set(pullRequests: [own, existing])
        clock.advance(120)
        #expect(await engine.poll(accounts: [account], interval: 120, retention: .oneYear).newPullRequests.isEmpty)

        // Een PR die daarna opent wel.
        let fresh = PullRequest.fixture(accountId: account.id, repo: "openEHR/specs", number: 51)
        await provider.set(pullRequests: [own, existing, fresh])
        clock.advance(120)
        #expect(await engine.poll(accounts: [account], interval: 120, retention: .oneYear).newPullRequests == [fresh])
    }
}
