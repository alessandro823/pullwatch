import Testing
@testable import PullwatchCore
import PullwatchTestSupport

@Suite struct PRFilterTests {
    @Test func denyModeFollowsEverythingExceptListed() {
        let s = Account.fixture(repoWatch: ["proj/legacy": .none]).filterSettings
        #expect(PRFilter.follows(repo: "proj/api", settings: s))
        #expect(!PRFilter.follows(repo: "proj/legacy", settings: s))
    }

    @Test func allowModeFollowsOnlyListed() {
        let s = Account.fixture(repoWatch: ["proj/api": .prs], newRepoDefault: .none).filterSettings
        #expect(PRFilter.follows(repo: "proj/api", settings: s))
        #expect(!PRFilter.follows(repo: "proj/web", settings: s))
    }

    @Test func repoMatchingIsCaseInsensitive() {
        let s = Account.fixture(repoWatch: ["Proj/MyRepo": .prs], newRepoDefault: .none).filterSettings
        #expect(PRFilter.follows(repo: "proj/myrepo", settings: s))
    }

    /// Zoals GitHub staan drafts standaard in de lijst; "Draft-PR's melden" beslist over de melding.
    @Test func `Drafts are listed by default and only notify when included`() {
        let draft = PullRequest.fixture(isDraft: true)
        let off = Account.fixture().filterSettings
        let on = Account.fixture(includeDrafts: true).filterSettings
        #expect(PRFilter.passes(draft, settings: off, currentUserId: "me"))
        #expect(PRFilter.passes(draft, settings: on, currentUserId: "me"))
        #expect(!PRFilter.notifies(draft, settings: off))
        #expect(PRFilter.notifies(draft, settings: on))
        #expect(PRFilter.notifies(.fixture(), settings: off), "een PR die klaar is meldt altijd")
    }

    /// "Draft-PR's tonen" uit verbergt drafts overal; een PR die klaar is voor review telt gewoon.
    @Test func `Hidden drafts pass nowhere but a ready pull request does`() {
        let hidden = Account.fixture(showDrafts: false, includeDrafts: true).filterSettings
        #expect(!PRFilter.passes(.fixture(isDraft: true), settings: hidden, currentUserId: "me"))
        #expect(PRFilter.passes(.fixture(isDraft: false), settings: hidden, currentUserId: "me"))
    }

    @Test func ownPullRequestsHiddenWhenHideOwn() {
        let mine = PullRequest.fixture(authorId: "ME")
        #expect(!PRFilter.passes(mine, settings: Account.fixture(hideOwn: true).filterSettings, currentUserId: "me"))
        #expect(PRFilter.passes(mine, settings: Account.fixture(hideOwn: false).filterSettings, currentUserId: "me"))
    }

    @Test func unfollowedRepoNeverPasses() {
        let pr = PullRequest.fixture(repo: "proj/legacy")
        let s = Account.fixture(repoWatch: ["proj/legacy": .none]).filterSettings
        #expect(!PRFilter.passes(pr, settings: s, currentUserId: "me"))
    }

    @Test func sameSourceComparesKindAndOrganizationCaseInsensitive() {
        let a = Account.fixture(kind: .gitHub, organization: "Acme").filterSettings
        let b = Account.fixture(kind: .gitHub, organization: "acme", repoWatch: ["x/y": .none]).filterSettings
        let c = Account.fixture(kind: .azureDevOps, organization: "acme").filterSettings
        #expect(a.sameSource(as: b))
        #expect(!a.sameSource(as: c))
    }
}
