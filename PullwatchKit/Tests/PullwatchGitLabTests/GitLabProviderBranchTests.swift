import Foundation
import Testing
@testable import PullwatchCore
@testable import PullwatchGitLab
import PullwatchTestSupport

/// Branches van GitLab: de heads per project (met bladeren en een vingerafdruk), de vergelijking
/// van twee commits en de adressen van de webpagina's.
@Suite struct GitLabProviderBranchTests {
    let api = "https://gitlab.com/api/v4/"

    func makeProvider(_ http: MockHTTPClient, extras: [String] = []) -> GitLabProvider {
        GitLabProvider(
            accountId: fixedAccountId, owners: ["acme"], extraRepos: extras,
            tokenSource: StaticTokenSource(token: "glpat-secret"), http: http, now: { Date.testStart }
        )
    }

    func branch(
        _ name: String, id: String, date: String = "2026-11-10T09:00:00.000Z",
        author: String = "Jan Jansen", email: String = "jan@example.com", isDefault: Bool = false
    ) -> String {
        #"{"name":"\#(name)","merged":false,"protected":false,"default":\#(isDefault),"#
            + #""commit":{"id":"\#(id)","short_id":"abc","title":"t","author_name":"\#(author)","author_email":"\#(email)","#
            + #""committed_date":"\#(date)","created_at":"\#(date)"}}"#
    }

    func list(_ branches: [String]) -> String { "[" + branches.joined(separator: ",") + "]" }

    func compareBody(_ count: Int) -> String {
        #"{"commits":["# + (0..<count).map { #"{"id":"c\#($0)"}"# }.joined(separator: ",") + #"],"diffs":[]}"#
    }

    func urls(_ http: MockHTTPClient) -> [String] { http.requests.compactMap { $0.url?.absoluteString } }

    // MARK: Heads

    @Test func `The branch GitLab marks as default is the default branch`() async throws {
        let http = MockHTTPClient()
        http.on("projects/acme%2Fapi/repository/branches", body: list([
            branch("main", id: "a"), branch("develop", id: "b", isDefault: true),
        ]))

        let fetch = try await makeProvider(http).branches(in: ["acme/api"], unchanged: [:])

        #expect(fetch.defaultBranches == ["acme/api": "develop"])
    }

    @Test func headsCarryTheCommitAndItsAuthor() async throws {
        let http = MockHTTPClient()
        http.on("projects/acme%2Fplatform%2Fapi/repository/branches", body: list([
            branch("main", id: "aaa111"),
            branch("feature/x", id: "bbb222", author: "Piet", email: "piet@example.com"),
        ]))
        let fetch = try await makeProvider(http).branches(in: ["acme/platform/api"], unchanged: [:])

        #expect(fetch.unavailableRepos.isEmpty)
        #expect(fetch.unchangedRepos.isEmpty)
        #expect(fetch.heads.map(\.name) == ["main", "feature/x"])
        let main = try #require(fetch.heads.first)
        #expect(main.repo == "acme/platform/api")
        #expect(main.sha == "aaa111")
        #expect(main.committedAt == DateParsing.parse("2026-11-10T09:00:00Z"))
        #expect(main.authorName == "Jan Jansen")
        #expect(main.authorEmail == "jan@example.com")
        #expect(main.authorId == nil)
        #expect(main.authorAvatarURL == nil)
        #expect(main.webURL.absoluteString == "https://gitlab.com/acme/platform/api/-/tree/main")
        #expect(fetch.heads[1].webURL.absoluteString == "https://gitlab.com/acme/platform/api/-/tree/feature/x")
        #expect(fetch.fingerprints["acme/platform/api"] != nil)
        #expect(try #require(urls(http).first).contains("per_page=100"))
    }

    @Test func laterPagesAreRead() async throws {
        let http = MockHTTPClient()
        http.on("page=2", body: list([branch("b2", id: "222")]))
        http.on("repository/branches", headers: ["x-next-page": "2"], body: list([branch("b1", id: "111")]))
        let fetch = try await makeProvider(http).branches(in: ["acme/api"], unchanged: [:])
        #expect(fetch.heads.map(\.name) == ["b1", "b2"])
    }

    @Test func anOtherHostNextLinkIsNotFollowed() async throws {
        let http = MockHTTPClient()
        http.on("evil.example.com", body: list([branch("stolen", id: "999")]))
        http.on("repository/branches", headers: ["Link": #"<https://evil.example.com/api/v4/x?id_after=1>; rel="next""#],
                body: list([branch("b1", id: "111")]))
        let fetch = try await makeProvider(http).branches(in: ["acme/api"], unchanged: [:])
        #expect(fetch.heads.map(\.name) == ["b1"])
        #expect(!urls(http).contains { $0.contains("evil.example.com") })
    }

    // MARK: Vingerafdruk en uitkomsten

    @Test func anUnchangedFingerprintSkipsTheHeads() async throws {
        let http = MockHTTPClient()
        http.on("repository/branches", body: list([branch("main", id: "aaa"), branch("dev", id: "bbb")]))
        let provider = makeProvider(http)
        let first = try await provider.branches(in: ["acme/api"], unchanged: [:])
        let fingerprint = try #require(first.fingerprints["acme/api"])

        let second = try await provider.branches(in: ["acme/api"], unchanged: ["acme/api": fingerprint])
        #expect(second.unchangedRepos == ["acme/api"])
        #expect(second.heads.isEmpty)
        #expect(second.fingerprints.isEmpty)

        // Een push (andere sha) verandert de vingerafdruk.
        let pushed = MockHTTPClient()
        pushed.on("repository/branches", body: list([branch("main", id: "ccc"), branch("dev", id: "bbb")]))
        let third = try await makeProvider(pushed).branches(in: ["acme/api"], unchanged: ["acme/api": fingerprint])
        #expect(third.unchangedRepos.isEmpty)
        #expect(third.heads.count == 2)
        #expect(third.fingerprints["acme/api"] != fingerprint)
    }

    @Test func missingOrForbiddenReposAreUnavailable() async throws {
        let http = MockHTTPClient()
        http.on("projects/acme%2Fgone/", status: 404, body: #"{"message":"404 Project Not Found"}"#)
        http.on("projects/acme%2Fsecret/", status: 403, body: #"{"message":"403 Forbidden"}"#)
        http.on("projects/acme%2Fok/", body: list([branch("main", id: "aaa")]))
        let fetch = try await makeProvider(http).branches(in: ["acme/gone", "acme/secret", "acme/ok"], unchanged: [:])
        #expect(fetch.unavailableRepos == ["acme/gone", "acme/secret"])
        #expect(fetch.heads.map(\.repo) == ["acme/ok"])
    }

    /// Elke gevraagde repo komt in precies één uitkomst, ook een repo zonder branches.
    @Test func everyRequestedRepoEndsUpInExactlyOneBucket() async throws {
        let http = MockHTTPClient()
        http.on("projects/acme%2Fread/", body: list([branch("main", id: "aaa")]))
        http.on("projects/acme%2Fempty/", body: "[]")
        http.on("projects/acme%2Fsame/", body: list([branch("main", id: "bbb")]))
        http.on("projects/acme%2Fgone/", status: 404, body: "{}")
        let provider = makeProvider(http)
        let same = try #require(try await provider.branches(in: ["acme/same"], unchanged: [:]).fingerprints["acme/same"])

        let repos = ["acme/read", "acme/empty", "acme/same", "acme/gone"]
        let fetch = try await provider.branches(in: repos, unchanged: ["acme/same": same])
        let read = Set(fetch.fingerprints.keys)
        #expect(read == ["acme/read", "acme/empty"])
        #expect(Set(fetch.unchangedRepos) == ["acme/same"])
        #expect(Set(fetch.unavailableRepos) == ["acme/gone"])
        #expect(read.union(fetch.unchangedRepos).union(fetch.unavailableRepos) == Set(repos))
        #expect(fetch.heads.filter { $0.repo == "acme/empty" }.isEmpty)
    }

    @Test func aRateLimitOfTheAccountIsThrown() async throws {
        let http = MockHTTPClient()
        http.on("repository/branches", status: 429, headers: ["Retry-After": "30"], body: "Retry later")
        await #expect(throws: ProviderError.rateLimited(until: Date.testStart + 30)) {
            try await makeProvider(http).branches(in: ["acme/api"], unchanged: [:])
        }
    }

    @Test func aPublicExtraProjectIsReadWithoutTokenAndItsLimitMakesItUnavailable() async throws {
        let http = MockHTTPClient()
        http.on("gitlab-org%2Fcli/repository/branches", authorized: false, body: list([branch("main", id: "aaa")]))
        http.on("\(api)projects/gitlab-org%2Fcli", authorized: true, status: 404, body: "{}")
        http.on("\(api)projects/gitlab-org%2Fcli", authorized: false, body: #"{"id":1,"path_with_namespace":"gitlab-org/cli"}"#)
        let provider = makeProvider(http, extras: ["gitlab-org/cli"])
        let fetch = try await provider.branches(in: ["gitlab-org/cli"], unchanged: [:])
        #expect(fetch.heads.map(\.name) == ["main"])
        #expect(http.requests.filter { $0.url?.path.hasSuffix("/repository/branches") == true }
            .allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == nil })

        let limited = MockHTTPClient()
        limited.on("repository/branches", authorized: false, status: 429, headers: ["Retry-After": "30"], body: "")
        limited.on("\(api)projects/gitlab-org%2Fcli", authorized: true, status: 404, body: "{}")
        limited.on("\(api)projects/gitlab-org%2Fcli", authorized: false, body: #"{"id":1,"path_with_namespace":"gitlab-org/cli"}"#)
        let second = try await makeProvider(limited, extras: ["gitlab-org/cli"]).branches(in: ["gitlab-org/cli"], unchanged: [:])
        #expect(second.unavailableRepos == ["gitlab-org/cli"])
        #expect(second.heads.isEmpty)
    }

    // MARK: Vergelijken

    @Test func compareCountsAheadAndBehindWithTwoRequests() async throws {
        let http = MockHTTPClient()
        http.on("from=old&to=new", body: compareBody(3))
        http.on("from=new&to=old", body: compareBody(1))
        let comparison = try await makeProvider(http).compare(in: "acme/platform/api", from: "old", to: "new")
        #expect(comparison == BranchComparison(ahead: 3, behind: 1))
        let calls = urls(http)
        #expect(calls.count == 2)
        #expect(calls.allSatisfy { $0.contains("projects/acme%2Fplatform%2Fapi/repository/compare?") && $0.contains("straight=true") })
    }

    @Test func compareOfAnUnknownCommitIsNil() async throws {
        let http = MockHTTPClient()
        http.on("repository/compare", status: 404, body: #"{"message":"404 Commit Not Found"}"#)
        #expect(try await makeProvider(http).compare(in: "acme/api", from: "gone", to: "new") == nil)
    }

    @Test func compareLetsOtherErrorsThrough() async throws {
        let http = MockHTTPClient()
        http.on("repository/compare", status: 500, body: "boom")
        await #expect(throws: ProviderError.self) {
            try await makeProvider(http).compare(in: "acme/api", from: "a", to: "b")
        }
    }

    // MARK: Adressen

    @Test func compareURLNamesBothCommits() {
        let provider = makeProvider(MockHTTPClient())
        #expect(provider.compareURL(in: "acme/platform/api", from: "abc", to: "def")?.absoluteString
            == "https://gitlab.com/acme/platform/api/-/compare/abc...def")
    }

    /// `feature/ä b#1`: de "/" blijft een "/" (GitLab leest `tree/feature/x` als branch
    /// `feature/x`), de rest wordt per segment %-gecodeerd.
    @Test func headURLEncodesEverySegmentOfAnAwkwardName() async throws {
        let http = MockHTTPClient()
        http.on("repository/branches", body: list([branch("feature/ä b#1", id: "aaa"), branch("fix/a+b?c%d", id: "bbb")]))
        let fetch = try await makeProvider(http).branches(in: ["acme/api"], unchanged: [:])
        #expect(fetch.heads[0].webURL.absoluteString == "https://gitlab.com/acme/api/-/tree/feature/%C3%A4%20b%231")
        #expect(fetch.heads[1].webURL.absoluteString == "https://gitlab.com/acme/api/-/tree/fix/a%2Bb%3Fc%25d")
    }

    // MARK: Gebruiker

    @Test func `The identity has the names and every e-mail of the user`() async throws {
        let http = MockHTTPClient()
        http.on("\(api)user", body: #"{"id":7,"username":"jjansen","name":"Jan Jansen","email":"jan@example.com","commit_email":"jan@work.example","public_email":"jan@example.com"}"#)

        let identity = try await makeProvider(http).currentUserIdentity()

        #expect(identity == UserIdentity(names: ["Jan Jansen", "jjansen"], emails: ["jan@example.com", "jan@work.example"]))
    }

    @Test func `An identity without e-mail fields has only the names`() async throws {
        let http = MockHTTPClient()
        http.on("\(api)user", body: #"{"id":7,"username":"jjansen","name":"Jan Jansen","public_email":""}"#)

        #expect(try await makeProvider(http).currentUserIdentity() == UserIdentity(names: ["Jan Jansen", "jjansen"], emails: []))
    }
}
