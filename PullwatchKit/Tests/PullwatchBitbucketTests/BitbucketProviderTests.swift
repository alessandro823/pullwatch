import Foundation
import Testing
@testable import PullwatchBitbucket
@testable import PullwatchCore
import PullwatchTestSupport

@Suite struct BitbucketProviderTests {
    let api = "https://api.bitbucket.org/2.0/"
    let email = "jane@example.com"
    let token = "ATATT3xFfGF0-secret"

    func makeProvider(
        _ http: MockHTTPClient,
        workspaces: [String] = ["atlassian"],
        email: String? = "jane@example.com",
        extraRepos: [String] = [],
        now: @escaping @Sendable () -> Date = { Date.testStart }
    ) -> BitbucketProvider {
        BitbucketProvider(
            accountId: fixedAccountId, workspaces: workspaces, email: email, extraRepos: extraRepos,
            tokenSource: StaticTokenSource(token: token), http: http, now: now
        )
    }

    func urls(_ http: MockHTTPClient) -> [String] {
        http.requests.compactMap { $0.url?.absoluteString }
    }

    /// De repo's van `atlassian`: één repo, `atlassian-event`.
    func oneRepo(_ http: MockHTTPClient, updated: String = "2026-11-04T11:48:34.614213+00:00") {
        http.on("\(api)repositories/atlassian?", body: BitbucketFixtures.repositories([("atlassian/atlassian-event", updated)]))
    }

    // MARK: Inloggen

    @Test func `Sends Basic auth with the email and the API token`() async throws {
        let http = MockHTTPClient()
        http.on("\(api)user", body: BitbucketFixtures.user)
        _ = try await makeProvider(http).currentUserId()
        let request = try #require(http.requests.first)
        let expected = "Basic " + Data("jane@example.com:ATATT3xFfGF0-secret".utf8).base64EncodedString()
        #expect(request.value(forHTTPHeaderField: "Authorization") == expected)
        #expect(request.url?.absoluteString == "\(api)user")
    }

    @Test func `The header never shows the token in plain text`() {
        let header = BitbucketProvider.basicAuthorization(email: email, token: token)
        #expect(header.hasPrefix("Basic "))
        #expect(!header.contains(token))
        #expect(!header.contains(email))
    }

    @Test func `Without an email no request goes out`() async throws {
        let http = MockHTTPClient()
        http.on("\(api)user", body: BitbucketFixtures.user)
        await #expect(throws: ProviderError.missingEmail) { try await makeProvider(http, email: nil).currentUserId() }
        #expect(http.requests.isEmpty)
    }

    @Test func `The current user is the account uuid`() async throws {
        let http = MockHTTPClient()
        http.on("\(api)user", body: BitbucketFixtures.user)
        #expect(try await makeProvider(http).currentUserId() == "{11111111-2222-3333-4444-555555555555}")
    }

    @Test func `Test connection checks every workspace and gives the display name`() async throws {
        let http = MockHTTPClient()
        http.on("\(api)user", body: BitbucketFixtures.user)
        http.on("\(api)repositories/atlassian?pagelen=1", body: BitbucketFixtures.repositories([]))
        #expect(try await makeProvider(http).testConnection() == "Jane Doe")
        #expect(urls(http).contains("\(api)repositories/atlassian?pagelen=1"))
    }

    @Test func `An unknown workspace is no access`() async throws {
        let http = MockHTTPClient()
        http.on("\(api)user", body: BitbucketFixtures.user)
        http.on("\(api)repositories/nobody", status: 404, body: BitbucketFixtures.unknownWorkspace)
        await #expect(throws: ProviderError.noAccess("nobody")) {
            try await makeProvider(http, workspaces: ["nobody"]).testConnection()
        }
    }

    @Test func `An invalid token is unauthorized`() async throws {
        let http = MockHTTPClient()
        http.on("\(api)user", status: 401, body: "")
        await #expect(throws: ProviderError.unauthorized) { try await makeProvider(http).testConnection() }
    }

    @Test func `A missing scope names the scope`() async throws {
        let http = MockHTTPClient()
        http.on("\(api)user", status: 403, body: BitbucketFixtures.missingScope)
        await #expect(throws: ProviderError.missingScope("read:repository:bitbucket")) { try await makeProvider(http).currentUserId() }
    }

    @Test func `A missing pull request scope names that scope`() async throws {
        let http = MockHTTPClient()
        oneRepo(http)
        http.on("\(api)repositories/atlassian/atlassian-event/pullrequests", status: 403, body: BitbucketFixtures.missingPullRequestScope)
        await #expect(throws: ProviderError.missingScope("read:pullrequest:bitbucket")) { try await makeProvider(http).openPullRequests() }
    }

    @Test func `A missing scope on an extra repository names the scope`() async throws {
        let http = MockHTTPClient()
        http.on("\(api)repositories/other/tool", status: 403, body: BitbucketFixtures.missingScope)
        await #expect(throws: ProviderError.missingScope("read:repository:bitbucket")) {
            try await makeProvider(http, workspaces: [], extraRepos: ["other/tool"]).listRepos()
        }
    }

    @Test(arguments: [
        #"{"type": "error", "error": {"message": "Forbidden"}}"#,
        #"{"type": "error", "error": {"message": "Access denied", "detail": "You do not have access to this repository."}}"#,
        #"{"type": "error", "error": {"message": "Forbidden", "detail": {"required": []}}}"#,
        "",
    ])
    func `A 403 without required scopes stays unauthorized`(body: String) async throws {
        let http = MockHTTPClient()
        http.on("\(api)user", status: 403, body: body)
        await #expect(throws: ProviderError.unauthorized) { try await makeProvider(http).currentUserId() }
    }

    @Test func `A 401 with a scope body stays an invalid token`() async throws {
        let http = MockHTTPClient()
        http.on("\(api)user", status: 401, body: BitbucketFixtures.missingPullRequestScope)
        await #expect(throws: ProviderError.unauthorized) { try await makeProvider(http).currentUserId() }
    }

    @Test(arguments: [
        ("nl", "Het token mist de scope read:pullrequest:bitbucket; maak een token met de scopes die Pullwatch noemt"),
        ("en", "The token lacks the scope read:pullrequest:bitbucket; create a token with the scopes Pullwatch lists"),
    ])
    func `The missing scope message names the scope`(language: String, expected: String) {
        #expect(ProviderError.missingScope("read:pullrequest:bitbucket").userMessage(bundle: .core(for: language)) == expected)
    }

    @Test(arguments: [
        ("nl", "Token ongeldig of verlopen"),
        ("en", "Token invalid or expired"),
    ])
    func `The invalid token message stays the same`(language: String, expected: String) {
        #expect(ProviderError.unauthorized.userMessage(bundle: .core(for: language)) == expected)
    }

    @Test func `A rate limit waits for Retry-After`() async throws {
        let http = MockHTTPClient()
        http.on("\(api)user", status: 429, headers: ["Retry-After": "30"], body: "Rate limit for this resource has been exceeded")
        let now = Date.testStart
        await #expect(throws: ProviderError.rateLimited(until: now + 30)) {
            try await makeProvider(http, now: { now }).currentUserId()
        }
    }

    @Test func `A server error stays a server error`() async throws {
        let http = MockHTTPClient()
        http.on("\(api)user", status: 500, body: "")
        await #expect(throws: ProviderError.server(status: 500)) { try await makeProvider(http).currentUserId() }
    }

    // MARK: Repo's en paginering

    @Test func `Lists the repositories of a workspace across next links`() async throws {
        let http = MockHTTPClient()
        let next = "\(api)repositories/atlassian?pagelen=100&sort=-updated_on&page=2"
        http.on("page=2", body: BitbucketFixtures.repositories([("atlassian/aui", "2026-11-04T09:29:09.154297+00:00")]))
        http.on("\(api)repositories/atlassian?", body: BitbucketFixtures.repositories(
            [("atlassian/atlassian-event", "2026-11-04T11:48:34.614213+00:00"), ("atlassian/Bamboo-specs", "2026-11-04T09:16:35+00:00")],
            next: next
        ))
        let repos = try await makeProvider(http).listRepos()
        #expect(repos == ["atlassian/atlassian-event", "atlassian/aui", "atlassian/Bamboo-specs"])
        #expect(urls(http).last == next)
        let first = try #require(urls(http).first)
        #expect(first.contains("sort=-updated_on"))
        #expect(first.contains("fields=next,values.full_name,values.updated_on"))
    }

    @Test func `A next link to another host is not followed`() async throws {
        let http = MockHTTPClient()
        http.on("\(api)repositories/atlassian?", body: BitbucketFixtures.repositories(
            [("atlassian/aui", "2026-11-04T09:29:09+00:00")], next: "https://evil.example.com/2.0/repositories/atlassian?page=2"
        ))
        #expect(try await makeProvider(http).listRepos() == ["atlassian/aui"])
        #expect(http.requests.count == 1)
    }

    @Test(arguments: [
        "http://api.bitbucket.org/2.0/repositories/atlassian?page=2",
        "https://api.bitbucket.org:8443/2.0/repositories/atlassian?page=2",
        "https://bitbucket.org/2.0/repositories/atlassian?page=2",
    ])
    func `A next link with another scheme, port or host is not followed`(next: String) async throws {
        let http = MockHTTPClient()
        http.on("page=2", body: BitbucketFixtures.repositories([("atlassian/other", "2026-11-04T09:29:09+00:00")]))
        http.on("\(api)repositories/atlassian?", body: BitbucketFixtures.repositories(
            [("atlassian/aui", "2026-11-04T09:29:09+00:00")], next: next
        ))
        #expect(try await makeProvider(http).listRepos() == ["atlassian/aui"])
        #expect(http.requests.count == 1)
    }

    // MARK: Pull requests

    @Test func `Maps an open pull request`() async throws {
        let http = MockHTTPClient()
        oneRepo(http)
        http.on("pullrequests?state=OPEN", body: BitbucketFixtures.page([BitbucketFixtures.pullRequest(219, draft: true)]))
        let pr = try #require(try await makeProvider(http).openPullRequests().first)
        #expect(pr.repo == "atlassian/atlassian-event")
        #expect(pr.number == 219)
        #expect(pr.title == "[Renovate] Update patches (5.1.x) (patch)")
        #expect(pr.authorId == "{250a442a-3ab3-4fcb-87c3-3c8f3df65ec7}")
        #expect(pr.authorName == "psre-renovate-bot")
        #expect(pr.authorAvatarURL?.host() == "secure.gravatar.com")
        #expect(pr.isDraft)
        #expect(pr.state == .open)
        #expect(pr.closedAt == nil)
        #expect(pr.revision == "6315b3bac849")
        #expect(pr.sourceBranch == "renovate/5.1.x-patch-patches")
        #expect(pr.targetBranch == "5.1.x")
        #expect(pr.webURL.absoluteString == "https://bitbucket.org/atlassian/atlassian-event/pull-requests/219")
        #expect(urls(http).contains("\(api)repositories/atlassian/atlassian-event/pullrequests?state=OPEN&pagelen=50"))
    }

    @Test func `A pull request in the merge queue is queued`() async throws {
        let http = MockHTTPClient()
        oneRepo(http)
        http.on("pullrequests?state=OPEN", body: BitbucketFixtures.page([BitbucketFixtures.pullRequest(1, queued: true)]))
        let pr = try #require(try await makeProvider(http).openPullRequests().first)
        #expect(pr.mergeQueue == MergeQueueEntry(kind: .mergeQueue))
    }

    @Test func `Follows next links for pull requests`() async throws {
        let http = MockHTTPClient()
        oneRepo(http)
        http.on("pullrequests?state=OPEN&pagelen=50&page=2", body: BitbucketFixtures.page([BitbucketFixtures.pullRequest(2)]))
        http.on("pullrequests?state=OPEN", body: BitbucketFixtures.page(
            [BitbucketFixtures.pullRequest(1)],
            next: "\(api)repositories/atlassian/atlassian-event/pullrequests?state=OPEN&pagelen=50&page=2"
        ))
        #expect(try await makeProvider(http).openPullRequests().map(\.number) == [1, 2])
    }

    @Test func `An unchanged repository is not asked again`() async throws {
        let http = MockHTTPClient()
        oneRepo(http)
        http.on("pullrequests?state=OPEN", body: BitbucketFixtures.page([BitbucketFixtures.pullRequest(1)]))
        let provider = makeProvider(http)
        _ = try await provider.openPullRequests()
        let second = try await provider.openPullRequests()
        #expect(second.map(\.number) == [1])
        #expect(urls(http).filter { $0.contains("/pullrequests?") }.count == 1)
    }

    @Test func `A changed repository is asked again`() async throws {
        let http = MockHTTPClient()
        http.onSequence("\(api)repositories/atlassian?", bodies: [
            BitbucketFixtures.repositories([("atlassian/atlassian-event", "2026-11-04T11:00:00+00:00")]),
            BitbucketFixtures.repositories([("atlassian/atlassian-event", "2026-11-04T11:05:00+00:00")]),
        ])
        http.on("pullrequests?state=OPEN", body: BitbucketFixtures.page([BitbucketFixtures.pullRequest(1)]))
        let provider = makeProvider(http)
        _ = try await provider.openPullRequests()
        _ = try await provider.openPullRequests()
        #expect(urls(http).filter { $0.contains("/pullrequests?") }.count == 2)
    }

    @Test func `An unchanged repository is asked again after a while`() async throws {
        let http = MockHTTPClient()
        oneRepo(http)
        http.on("pullrequests?state=OPEN", body: BitbucketFixtures.page([BitbucketFixtures.pullRequest(1)]))
        let clock = TestClock()
        let provider = makeProvider(http, now: { clock.now })
        _ = try await provider.openPullRequests()
        clock.advance(BitbucketProvider.openRefresh + 1)
        _ = try await provider.openPullRequests()
        #expect(urls(http).filter { $0.contains("/pullrequests?") }.count == 2)
    }

    @Test(arguments: [("MERGED", PRState.merged), ("DECLINED", .closed), ("SUPERSEDED", .closed)])
    func `Maps a closed state with updated_on as the closing time`(state: String, expected: PRState) async throws {
        let http = MockHTTPClient()
        oneRepo(http)
        http.on("/pullrequests?", body: BitbucketFixtures.page([
            BitbucketFixtures.pullRequest(20, state: state, updated: "2026-11-04T11:48:34.598722+00:00"),
        ]))
        let pr = try #require(try await makeProvider(http).pullRequests(updatedSince: nil, limit: 10).first)
        #expect(pr.state == expected)
        #expect(pr.closedAt == DateParsing.parse("2026-11-04T11:48:34+00:00"))
    }

    @Test func `The history sync asks every state since a time and skips repositories not updated since`() async throws {
        let http = MockHTTPClient()
        http.on("\(api)repositories/atlassian?", body: BitbucketFixtures.repositories([
            ("atlassian/atlassian-event", "2026-11-04T11:48:34+00:00"), ("atlassian/old", "2020-01-01T00:00:00+00:00"),
        ]))
        http.on("/pullrequests?", body: BitbucketFixtures.page([BitbucketFixtures.pullRequest(20, state: "MERGED")]))
        let since = try #require(DateParsing.parse("2026-01-01T00:00:00Z"))
        _ = try await makeProvider(http).pullRequests(updatedSince: since, limit: 10)
        let asked = urls(http).filter { $0.contains("/pullrequests?") }
        #expect(asked.count == 1)
        let url = try #require(asked.first)
        #expect(url.hasPrefix("\(api)repositories/atlassian/atlassian-event/pullrequests?"))
        #expect(url.contains("state=OPEN&state=MERGED&state=DECLINED&state=SUPERSEDED&sort=-updated_on"))
        #expect(url.contains("q=updated_on%20%3E%202026-01-01T00:00:00Z"))
    }

    // MARK: Tags

    @Test func `Tags come without a release because Bitbucket has none`() async throws {
        let http = MockHTTPClient()
        http.on("\(api)repositories/atlassian/aui/refs/tags?sort=-target.date&pagelen=100", body: BitbucketFixtures.tags)
        let fetch = try await makeProvider(http).tags(in: ["atlassian/aui"])
        #expect(fetch.tags.map(\.name) == ["9.12.17", "9.12.16"])
        #expect(fetch.tags.allSatisfy { $0.release == nil })
        let annotated = try #require(fetch.tags.first)
        #expect(annotated.repo == "atlassian/aui")
        #expect(annotated.authorName == "Build Agent")
        #expect(annotated.authorAvatarURL != nil)
        #expect(annotated.createdAt == DateParsing.parse("2026-11-04T09:05:19+00:00"))
        #expect(annotated.webURL.absoluteString == "https://bitbucket.org/atlassian/aui/commits/tag/9.12.17")
        let light = try #require(fetch.tags.last)
        #expect(light.authorName == "Jane Doe")
        #expect(light.createdAt == DateParsing.parse("2026-10-28T08:00:00+00:00"))
    }

    @Test func `A missing repository is unavailable for tags`() async throws {
        let http = MockHTTPClient()
        http.on("refs/tags", status: 404, body: BitbucketFixtures.noAccess)
        let fetch = try await makeProvider(http).tags(in: ["atlassian/gone"])
        #expect(fetch.tags.isEmpty)
        #expect(fetch.unavailableRepos == ["atlassian/gone"])
    }

    @Test func `Dated tags are newest first`() async throws {
        let http = MockHTTPClient()
        http.on("refs/tags", body: BitbucketFixtures.tags)
        #expect(try await makeProvider(http).datedTags(in: "atlassian/aui", limit: 1).map(\.name) == ["9.12.17"])
    }

    // MARK: Checks

    @Test(arguments: [
        ("SUCCESSFUL", CheckOutcome.passed), ("FAILED", .failed), ("STOPPED", .failed), ("INPROGRESS", .pending),
    ])
    func `Maps a build status`(state: String, expected: CheckOutcome) {
        #expect(BitbucketProvider.outcome(of: state) == expected)
    }

    @Test func `Counts the build statuses on the source commit`() async throws {
        let http = MockHTTPClient()
        http.on("\(api)repositories/atlassian/aui/commit/7e21fd330776/statuses", body: BitbucketFixtures.statuses(
            ["SUCCESSFUL", "FAILED", "INPROGRESS", "SUCCESSFUL"]
        ))
        let pr = PullRequest.fixture(repo: "atlassian/aui", number: 5486, revision: "7e21fd330776")
        let checks = try await makeProvider(http).checks(of: [pr])
        #expect(checks[pr.dedupKey] == .counts(CheckCounts(passed: 2, failed: 1, pending: 1)))
    }

    @Test func `No statuses is an empty count`() async throws {
        let http = MockHTTPClient()
        http.on("/statuses", body: BitbucketFixtures.statuses([]))
        let pr = PullRequest.fixture(repo: "atlassian/aui", revision: "7e21fd330776")
        #expect(try await makeProvider(http).checks(of: [pr])[pr.dedupKey] == .counts(CheckCounts()))
    }

    @Test func `Statuses the token may not read need permission`() async throws {
        let http = MockHTTPClient()
        http.on("/statuses", status: 403, body: BitbucketFixtures.missingScope)
        let pr = PullRequest.fixture(repo: "atlassian/aui", revision: "7e21fd330776")
        #expect(try await makeProvider(http).checks(of: [pr])[pr.dedupKey] == .needsPermission)
    }

    @Test func `A pull request without a commit hash gets no request`() async throws {
        let http = MockHTTPClient()
        let pr = PullRequest.fixture(repo: "atlassian/aui", revision: nil)
        #expect(try await makeProvider(http).checks(of: [pr]).isEmpty)
        #expect(http.requests.isEmpty)
    }

    // MARK: Co-auteurs

    @Test func `Co-authors come from commit authors and trailers without the author`() async throws {
        let http = MockHTTPClient()
        http.on("\(api)repositories/atlassian/aui/pullrequests/7/commits", body: BitbucketFixtures.commits)
        let pr = PullRequest.fixture(repo: "atlassian/aui", number: 7, authorId: "{aaaa}", authorName: "Jane Doe")
        let people = try #require(try await makeProvider(http).coAuthors(of: [pr])[pr.dedupKey])
        #expect(people.map(\.name) == ["Sam Smith", "Kim Lee"])
        #expect(people.last?.email == "kim@example.com")
    }

    // MARK: Bestanden

    @Test func `Lists files recursively across pages`() async throws {
        let http = MockHTTPClient()
        let next = "\(api)repositories/atlassian/aui/src/HEAD/?pagelen=100&max_depth=50&page=rXtr"
        http.on("page=rXtr", body: BitbucketFixtures.tree([("packages/core/package.json", "commit_file")]))
        http.on("\(api)repositories/atlassian/aui/src/HEAD/?", body: BitbucketFixtures.tree(
            [(".bitbucket", "commit_directory"), ("package.json", "commit_file"), ("packages", "commit_directory")], next: next
        ))
        let paths = try await makeProvider(http).filePaths(in: "atlassian/aui", ref: nil)
        #expect(paths == ["package.json", "packages/core/package.json"])
        #expect(urls(http).first?.contains("max_depth=50") == true)
    }

    @Test func `Files on a tag use that ref`() async throws {
        let http = MockHTTPClient()
        http.on("src/9.12.17/", body: BitbucketFixtures.tree([("pom.xml", "commit_file")]))
        #expect(try await makeProvider(http).filePaths(in: "atlassian/aui", ref: "9.12.17") == ["pom.xml"])
    }

    @Test func `An empty repository has no files`() async throws {
        let http = MockHTTPClient()
        http.on("/src/", status: 404, body: BitbucketFixtures.noAccess)
        #expect(try await makeProvider(http).filePaths(in: "atlassian/empty", ref: nil).isEmpty)
    }

    @Test func `Reads one file raw`() async throws {
        let http = MockHTTPClient()
        http.on("\(api)repositories/atlassian/aui/src/HEAD/packages/core/package.json", body: #"{"name":"@atlassian/aui"}"#)
        let text = try await makeProvider(http).fileContent(in: "atlassian/aui", path: "packages/core/package.json", ref: nil)
        #expect(text == #"{"name":"@atlassian/aui"}"#)
    }

    // MARK: Losse repo's

    @Test func `An extra repository the token can read`() async throws {
        let http = MockHTTPClient()
        http.on("\(api)repositories/other/tool", authorized: true, body: BitbucketFixtures.repository("other/Tool"))
        let check = try await makeProvider(http).checkRepository("other/tool")
        #expect(check == RepositoryCheck(name: "other/Tool"))
    }

    @Test func `A public extra repository is read without signing in`() async throws {
        let http = MockHTTPClient()
        // De tags eerst: de route van de repo zelf past ook op hun URL.
        http.on("refs/tags", authorized: false, body: BitbucketFixtures.tags)
        http.on("\(api)repositories/atlassian/aui", authorized: true, status: 403, body: BitbucketFixtures.noAccess)
        http.on("\(api)repositories/atlassian/aui", authorized: false, body: BitbucketFixtures.repository("atlassian/aui"))
        let provider = makeProvider(http, workspaces: ["mine"], extraRepos: ["atlassian/aui"])
        #expect(try await provider.checkRepository("atlassian/aui") == RepositoryCheck(name: "atlassian/aui", readWithoutSignIn: true))
        let fetch = try await provider.tags(in: ["atlassian/aui"])
        #expect(fetch.tags.count == 2)
        let tagRequest = try #require(http.requests.last)
        #expect(tagRequest.value(forHTTPHeaderField: "Authorization") == nil)
    }

    @Test func `A private extra repository is no access`() async throws {
        let http = MockHTTPClient()
        http.on("\(api)repositories/other/secret", status: 404, body: BitbucketFixtures.noAccess)
        await #expect(throws: ProviderError.noAccess("other/secret")) {
            try await makeProvider(http).checkRepository("other/secret")
        }
    }

    @Test func `Extra repositories bring their open pull requests`() async throws {
        let http = MockHTTPClient()
        http.on("\(api)repositories/mine?", body: BitbucketFixtures.repositories([]))
        http.on("\(api)repositories/other/tool/pullrequests", body: BitbucketFixtures.page([BitbucketFixtures.pullRequest(3, repo: "other/tool")]))
        http.on("\(api)repositories/other/tool", body: BitbucketFixtures.repository("other/tool"))
        let prs = try await makeProvider(http, workspaces: ["mine"], extraRepos: ["other/tool", "mine/skip"]).openPullRequests()
        #expect(prs.map(\.repo) == ["other/tool"])
        #expect(!urls(http).contains { $0.contains("mine/skip") })
    }

    // MARK: Bronnen

    @Test func `The sources overview names the same API host`() async {
        let account = Account(kind: .bitbucket, organization: "atlassian", authMethod: .pat, email: email)
        let provider = makeProvider(MockHTTPClient())
        let endpoint = await provider.endpoint("user")
        #expect(SourcesOverview.server(of: account).appending(path: "user") == endpoint)
    }
}
