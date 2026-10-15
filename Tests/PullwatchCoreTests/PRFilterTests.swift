import Testing
@testable import PullwatchCore

@Suite struct PRFilterTests {
    @Test func denyModeFollowsEverythingExceptListed() {
        let s = Account.fixture(filterMode: .deny, repos: ["proj/legacy"]).filterSettings
        #expect(PRFilter.follows(repo: "proj/api", settings: s))
        #expect(!PRFilter.follows(repo: "proj/legacy", settings: s))
    }

    @Test func allowModeFollowsOnlyListed() {
        let s = Account.fixture(filterMode: .allow, repos: ["proj/api"]).filterSettings
        #expect(PRFilter.follows(repo: "proj/api", settings: s))
        #expect(!PRFilter.follows(repo: "proj/web", settings: s))
    }

    @Test func repoMatchingIsCaseInsensitive() {
        let s = Account.fixture(filterMode: .allow, repos: ["Proj/MyRepo"]).filterSettings
        #expect(PRFilter.follows(repo: "proj/myrepo", settings: s))
    }

    @Test func draftsHiddenUnlessIncluded() {
        let draft = PullRequest.fixture(isDraft: true)
        #expect(!PRFilter.passes(draft, settings: Account.fixture().filterSettings, currentUserId: "me"))
        #expect(PRFilter.passes(draft, settings: Account.fixture(includeDrafts: true).filterSettings, currentUserId: "me"))
    }

    @Test func ownPullRequestsHiddenWhenHideOwn() {
        let mine = PullRequest.fixture(authorId: "ME")
        #expect(!PRFilter.passes(mine, settings: Account.fixture(hideOwn: true).filterSettings, currentUserId: "me"))
        #expect(PRFilter.passes(mine, settings: Account.fixture(hideOwn: false).filterSettings, currentUserId: "me"))
    }

    @Test func unfollowedRepoNeverPasses() {
        let pr = PullRequest.fixture(repo: "proj/legacy")
        let s = Account.fixture(filterMode: .deny, repos: ["proj/legacy"]).filterSettings
        #expect(!PRFilter.passes(pr, settings: s, currentUserId: "me"))
    }

    @Test func sameSourceComparesKindAndOrganizationCaseInsensitive() {
        let a = Account.fixture(kind: .gitHub, organization: "Acme").filterSettings
        let b = Account.fixture(kind: .gitHub, organization: "acme", repos: ["x/y"]).filterSettings
        let c = Account.fixture(kind: .azureDevOps, organization: "acme").filterSettings
        #expect(a.sameSource(as: b))
        #expect(!a.sameSource(as: c))
    }
}
