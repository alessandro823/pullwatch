import Foundation
import Testing
@testable import PullwatchCore
@testable import PullwatchGitLab
import PullwatchTestSupport

@Suite struct GitLabProviderTests {
    let api = "https://gitlab.com/api/v4/"

    func makeProvider(
        _ http: MockHTTPClient,
        owners: [String] = ["acme"],
        instance: URL? = nil,
        now: @escaping @Sendable () -> Date = { Date.testStart }
    ) -> GitLabProvider {
        GitLabProvider(
            accountId: fixedAccountId, owners: owners, instanceURL: instance,
            tokenSource: StaticTokenSource(token: "glpat-secret"), http: http, now: now
        )
    }

    /// Een groep-eigenaar "acme" die gevonden wordt.
    func groupAcme(_ http: MockHTTPClient) {
        http.on("\(api)groups/acme?", body: GitLabFixtures.group)
    }

    /// Het overzicht van bronnen (PullwatchCore kent de provider niet) noemt dezelfde API.
    @Test func sourcesOverviewNamesTheSameAPI() async {
        for instance in [nil, "https://gitlab.com", "https://git.example.com", "https://example.com/gitlab"].map({ $0.flatMap(URL.init(string:)) }) {
            let account = Account(kind: .gitLab, organization: "acme", authMethod: .pat, instanceURL: instance)
            let provider = makeProvider(MockHTTPClient(), instance: instance)
            let endpoint = await provider.endpoint("projects")
            #expect(SourcesOverview.server(of: account).appending(path: "projects") == endpoint,
                    "\(String(describing: instance))")
        }
    }

    func urls(_ http: MockHTTPClient) -> [String] {
        http.requests.compactMap { $0.url?.absoluteString }
    }

    // MARK: Gebruiker en verbinding

    @Test func currentUserIsTheUsernameWithBearerToken() async throws {
        let http = MockHTTPClient()
        http.on("\(api)user", body: GitLabFixtures.user)
        #expect(try await makeProvider(http).currentUserId() == "jdoe")
        let request = try #require(http.requests.first)
        #expect(request.url?.absoluteString == "\(api)user")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer glpat-secret")
    }

    @Test func testConnectionChecksEveryOwner() async throws {
        let http = MockHTTPClient()
        // "users" eerst: de route "user" zou er anders ook bij passen.
        http.on("\(api)groups/acme%2Fplatform?", body: GitLabFixtures.subgroup)
        http.on("\(api)groups/jdoe?", status: 404, body: #"{"message":"404 Group Not Found"}"#)
        http.on("\(api)users?username=jdoe", body: GitLabFixtures.users("jdoe", id: 42))
        http.on("\(api)user", body: GitLabFixtures.user)
        let name = try await makeProvider(http, owners: ["acme/platform", "jdoe"]).testConnection()
        #expect(name == "jdoe")
        #expect(urls(http).contains("\(api)groups/acme%2Fplatform?with_projects=false"))
    }

    @Test func unknownOwnerIsNoAccess() async throws {
        let http = MockHTTPClient()
        http.on("\(api)groups/nobody?", status: 404, body: #"{"message":"404 Group Not Found"}"#)
        http.on("\(api)users?username=nobody", body: "[]")
        http.on("\(api)user", body: GitLabFixtures.user)
        await #expect(throws: ProviderError.noAccess("nobody")) {
            try await makeProvider(http, owners: ["nobody"]).testConnection()
        }
    }

    @Test func invalidTokenIsUnauthorized() async throws {
        let http = MockHTTPClient()
        http.on("\(api)user", status: 401, body: #"{"message":"401 Unauthorized"}"#)
        await #expect(throws: ProviderError.unauthorized) { try await makeProvider(http).testConnection() }
    }

    @Test func forbiddenScopeIsUnauthorized() async throws {
        let http = MockHTTPClient()
        http.on("\(api)user", status: 403, body: #"{"error":"insufficient_scope","error_description":"The request requires higher privileges than provided by the access token.","scope":"read_api"}"#)
        await #expect(throws: ProviderError.unauthorized) { try await makeProvider(http).currentUserId() }
    }

    @Test func rateLimitUsesRetryAfter() async throws {
        let http = MockHTTPClient()
        http.on("\(api)user", status: 429, headers: ["Retry-After": "30", "RateLimit-Remaining": "0"], body: "Retry later")
        let now = Date.testStart
        await #expect(throws: ProviderError.rateLimited(until: now + 30)) {
            try await makeProvider(http, now: { now }).currentUserId()
        }
    }

    @Test func rateLimitUsesRateLimitReset() async throws {
        let http = MockHTTPClient()
        http.on("\(api)user", status: 429, headers: ["RateLimit-Remaining": "0", "RateLimit-Reset": "1760000500"], body: "Retry later")
        await #expect(throws: ProviderError.rateLimited(until: Date(timeIntervalSince1970: 1_760_000_500))) {
            try await makeProvider(http).currentUserId()
        }
    }

    // MARK: Repo's

    @Test func listsGroupProjectsWithSubgroupsAcrossPages() async throws {
        // De specifieke route (pagina 2) eerst: de eerste passende route wint.
        let http2 = MockHTTPClient()
        groupAcme(http2)
        http2.on("groups/acme/projects?simple=true&archived=false&order_by=id&sort=asc&include_subgroups=true&with_shared=false&per_page=100&page=2",
                 headers: ["x-next-page": ""], body: "[\(GitLabFixtures.project("acme/platform/web", id: 3))]")
        http2.on("groups/acme/projects?", headers: ["x-next-page": "2", "x-page": "1"],
                 body: "[\(GitLabFixtures.project("acme/platform/api", id: 1)),\(GitLabFixtures.project("acme/Billing", id: 2))]")
        let repos = try await makeProvider(http2).listRepos()
        #expect(repos == ["acme/Billing", "acme/platform/api", "acme/platform/web"])
        #expect(urls(http2).filter { $0.contains("/projects?") }.count == 2)
    }

    @Test func listsUserProjectsById() async throws {
        let http = MockHTTPClient()
        http.on("\(api)groups/jdoe?", status: 404, body: #"{"message":"404 Group Not Found"}"#)
        http.on("\(api)users?username=jdoe", body: GitLabFixtures.users("jdoe", id: 42))
        http.on("\(api)users/42/projects?", body: "[\(GitLabFixtures.project("jdoe/dotfiles", id: 5))]")
        #expect(try await makeProvider(http, owners: ["jdoe"]).listRepos() == ["jdoe/dotfiles"])
    }

    @Test func followsKeysetLinkOnTheSameServerOnly() async throws {
        let http = MockHTTPClient()
        groupAcme(http)
        http.on("id_after=1", headers: ["Link": #"<https://evil.example.com/api/v4/groups/acme/projects?id_after=2>; rel="next""#],
                body: "[\(GitLabFixtures.project("acme/two", id: 2))]")
        http.on("groups/acme/projects?", headers: ["Link": #"<https://gitlab.com/api/v4/groups/acme/projects?id_after=1&pagination=keyset>; rel="next""#],
                body: "[\(GitLabFixtures.project("acme/one", id: 1))]")
        #expect(try await makeProvider(http).listRepos() == ["acme/one", "acme/two"])
        #expect(!urls(http).contains { $0.contains("evil.example.com") })
    }

    @Test(arguments: [
        "http://gitlab.com/api/v4/groups/acme/projects?id_after=2",
        "https://gitlab.com:8443/api/v4/groups/acme/projects?id_after=2",
        "https://gitlab.example.com/api/v4/groups/acme/projects?id_after=2",
    ])
    func `A keyset link with another scheme, port or host is not followed`(next: String) async throws {
        let http = MockHTTPClient()
        groupAcme(http)
        http.on("id_after=2", body: "[\(GitLabFixtures.project("acme/two", id: 2))]")
        http.on("groups/acme/projects?", headers: ["Link": "<\(next)>; rel=\"next\""],
                body: "[\(GitLabFixtures.project("acme/one", id: 1))]")
        #expect(try await makeProvider(http).listRepos() == ["acme/one"])
        #expect(!urls(http).contains { $0.contains("id_after=2") })
    }

    @Test func parsesNextLink() {
        let header = #"<https://gitlab.com/api/v4/projects?page=1>; rel="prev", <https://gitlab.com/api/v4/projects?id_after=9>; rel="next""#
        #expect(GitLabProvider.nextLink(in: header)?.absoluteString == "https://gitlab.com/api/v4/projects?id_after=9")
        #expect(GitLabProvider.nextLink(in: #"<https://gitlab.com/x>; rel="first""#) == nil)
    }

    // MARK: Merge requests

    @Test func mapsOpenMergeRequestFields() async throws {
        let http = MockHTTPClient()
        groupAcme(http)
        http.on("groups/acme/merge_requests", body: "[\(GitLabFixtures.mergeRequest(iid: 12, draft: true))]")
        let prs = try await makeProvider(http).openPullRequests()
        let pr = try #require(prs.first)
        #expect(prs.count == 1)
        #expect(pr.accountId == fixedAccountId)
        #expect(pr.repo == "acme/platform/api")
        #expect(pr.number == 12)
        #expect(pr.title == "MR 12")
        #expect(pr.authorId == "alice")
        #expect(pr.authorName == "alice")
        #expect(pr.isDraft)
        #expect(pr.state == .open)
        #expect(pr.closedAt == nil)
        #expect(pr.revision == "a1b2c3d4")
        #expect(pr.sourceBranch == "feature-12")
        #expect(pr.targetBranch == "main")
        #expect(pr.createdAt == Date(timeIntervalSince1970: 1_760_522_400))
        #expect(pr.webURL.absoluteString == "https://gitlab.com/acme/platform/api/-/merge_requests/12")
        let url = try #require(urls(http).last)
        #expect(url.hasPrefix("\(api)groups/acme/merge_requests?"))
        #expect(url.contains("state=opened"))
        #expect(url.contains("scope=all"))
        #expect(url.contains("per_page=100"))
    }

    @Test func mergeRequestsOfAUserGoPerProject() async throws {
        let http = MockHTTPClient()
        http.on("\(api)groups/jdoe?", status: 404, body: "{}")
        http.on("\(api)users?username=jdoe", body: GitLabFixtures.users("jdoe", id: 42))
        http.on("\(api)users/42/projects?", body: "[\(GitLabFixtures.project("jdoe/dotfiles", id: 5)),\(GitLabFixtures.project("jdoe/gone", id: 6))]")
        http.on("projects/jdoe%2Fdotfiles/merge_requests", body: "[\(GitLabFixtures.mergeRequest(iid: 3, project: "jdoe/dotfiles"))]")
        http.on("projects/jdoe%2Fgone/merge_requests", status: 404, body: #"{"message":"404 Project Not Found"}"#)
        let provider = makeProvider(http, owners: ["jdoe"])
        let prs = try await provider.openPullRequests()
        #expect(prs.map(\.repo) == ["jdoe/dotfiles"])
        // De projectlijst wordt bewaard: een tweede poll vraagt hem niet opnieuw.
        _ = try await provider.openPullRequests()
        #expect(urls(http).filter { $0.contains("users/42/projects") }.count == 1)
    }

    @Test func historyAsksUpdatedAfterAndMapsStates() async throws {
        let http = MockHTTPClient()
        groupAcme(http)
        http.on("groups/acme/merge_requests", body: "[" + [
            GitLabFixtures.mergeRequest(iid: 1, state: "merged", mergedAt: "2025-10-17T08:00:00.000Z", closedAt: nil),
            GitLabFixtures.mergeRequest(iid: 2, state: "closed", closedAt: "2025-10-16T08:00:00.000Z"),
            GitLabFixtures.mergeRequest(iid: 3, state: "locked"),
        ].joined(separator: ",") + "]")
        let since = Date.testStart
        let prs = try await makeProvider(http).pullRequests(updatedSince: since, limit: 50)
        #expect(prs.map(\.number) == [1, 2, 3])
        #expect(prs.map(\.state) == [.merged, .closed, .open])
        #expect(prs[0].closedAt == DateParsing.parse("2025-10-17T08:00:00Z"))
        let url = try #require(urls(http).last)
        #expect(url.contains("updated_after=2025-10-09T08:53:20Z"))
        #expect(url.contains("order_by=updated_at"))
        #expect(url.contains("sort=desc"))
        #expect(!url.contains("state="))
    }

    @Test func historyStopsAtTheLimit() async throws {
        let http = MockHTTPClient()
        groupAcme(http)
        http.on("groups/acme/merge_requests", headers: ["x-next-page": "2"],
                body: "[" + (1...3).map { GitLabFixtures.mergeRequest(iid: $0) }.joined(separator: ",") + "]")
        let prs = try await makeProvider(http).pullRequests(updatedSince: nil, limit: 2)
        #expect(prs.count == 2)
        #expect(urls(http).filter { $0.contains("merge_requests") }.count == 1)
    }

    @Test func repoPathFallsBackToTheWebURL() throws {
        let json = #"{"iid":4,"title":"t","state":"opened","created_at":"2025-10-15T10:00:00Z","author":{"username":"a"},"web_url":"https://git.example.com/gitlab/team/sub/app/-/merge_requests/4"}"#
        let dto = try JSONDecoding.decode(MergeRequestDTO.self, from: Data(json.utf8), snakeCase: true)
        let instance = try #require(URL(string: "https://git.example.com/gitlab"))
        #expect(GitLabProvider.repoPath(of: dto, instanceURL: instance) == "team/sub/app")
    }

    // MARK: Eigen server

    @Test func selfManagedInstanceWithPathPrefix() async throws {
        let http = MockHTTPClient()
        http.on("https://git.example.com/gitlab/api/v4/groups/team?", body: #"{"id":1,"full_path":"team"}"#)
        http.on("https://git.example.com/gitlab/api/v4/groups/team/merge_requests",
                body: "[" + GitLabFixtures.mergeRequest(iid: 8, project: "team/app")
                    .replacingOccurrences(of: "https://gitlab.com/", with: "https://git.example.com/gitlab/") + "]")
        let instance = try #require(InstanceURL.parse("git.example.com/gitlab/"))
        let prs = try await makeProvider(http, owners: ["team"], instance: instance).openPullRequests()
        #expect(prs.first?.webURL.absoluteString == "https://git.example.com/gitlab/team/app/-/merge_requests/8")
        #expect(urls(http).allSatisfy { $0.hasPrefix("https://git.example.com/gitlab/api/v4/") })
    }

    // MARK: Tags

    @Test func tagsWithReleasesAuthorsAndDates() async throws {
        let http = MockHTTPClient()
        http.on("projects/acme%2Fplatform%2Fapi/repository/tags", body: "[" + [
            GitLabFixtures.tag("v2.0.0", created: "2025-09-01T12:00:00.000Z", committed: "2025-08-31T10:00:00.000Z", author: "Bob Dev", release: true),
            GitLabFixtures.tag("v1.0.0+build", created: nil, committed: "2025-07-01T10:00:00.000Z", author: "Carol Dev", release: false),
            GitLabFixtures.tag("v0.9.0", created: nil, committed: "2025-06-01T10:00:00.000Z", author: "Carol Dev", release: true),
        ].joined(separator: ",") + "]")
        http.on("projects/acme%2Fplatform%2Fapi/releases", body: "[" + [
            GitLabFixtures.release("v2.0.0", name: "Version 2", author: "bob"),
            GitLabFixtures.release("v0.9.0", name: "v0.9.0", author: "project_99_bot_3f2a"),
        ].joined(separator: ",") + "]")
        let fetch = try await makeProvider(http).tags(in: ["acme/platform/api"])
        #expect(fetch.unavailableRepos.isEmpty)
        #expect(fetch.tags.map(\.name) == ["v2.0.0", "v1.0.0+build", "v0.9.0"])

        let v2 = fetch.tags[0]
        #expect(v2.repo == "acme/platform/api")
        #expect(v2.authorName == "bob")
        #expect(v2.authorAvatarURL?.absoluteString == "https://gitlab.com/uploads/-/system/user/avatar/9/avatar.png")
        #expect(v2.createdAt == DateParsing.parse("2025-09-01T12:00:00Z"))
        #expect(v2.webURL.absoluteString == "https://gitlab.com/acme/platform/api/-/releases/v2.0.0")
        #expect(v2.release?.title == "Version 2")
        #expect(v2.releaseTitle == "Version 2")
        #expect(v2.release?.publishedAt == DateParsing.parse("2025-09-01T12:30:00Z"))

        let light = fetch.tags[1]
        #expect(light.release == nil)
        #expect(light.authorName == "Carol Dev")
        #expect(light.createdAt == DateParsing.parse("2025-07-01T10:00:00Z"))
        #expect(light.webURL.absoluteString == "https://gitlab.com/acme/platform/api/-/tags/v1.0.0%2Bbuild")

        // Een bot maakte de release: de auteur van de commit gaat voor.
        #expect(fetch.tags[2].authorName == "Carol Dev")
        #expect(fetch.tags[2].release?.authorLogin == "project_99_bot_3f2a")

        let tagsURL = try #require(urls(http).first)
        #expect(tagsURL.contains("order_by=updated"))
        #expect(tagsURL.contains("per_page=100"))
    }

    /// De API en de profielfoto's van de auteurs van releases (geüpload op de server, of Gravatar)
    /// op gitlab.com en op een eigen server: elke host die daarbij de deur uit gaat moet in het
    /// overzicht van bronnen staan, ook zonder geladen geschiedenis.
    @Test func everyGitLabHostIsInTheOverview() async throws {
        let instances = [nil, URL(string: "https://git.example.com/gitlab")]
        let http = MockHTTPClient()
        http.on("repository/tags", body: "[" + [
            GitLabFixtures.tag("v1", created: nil, committed: "2025-07-01T10:00:00Z", author: "A", release: true),
            GitLabFixtures.tag("v0", created: nil, committed: "2025-06-01T10:00:00Z", author: "A", release: true),
        ].joined(separator: ",") + "]")
        http.on(".png", body: "")
        http.on("secure.gravatar.com", body: "")
        var accounts: [Account] = []
        for instance in instances {
            let web = instance?.absoluteString ?? "https://gitlab.com"
            http.on("\(web)/api/v4/projects/acme%2Fapi/releases", body: "[" + [
                GitLabFixtures.release("v1", name: "v1", author: "bob", avatar: "\(web)/uploads/-/system/user/avatar/9/avatar.png"),
                GitLabFixtures.release("v0", name: "v0", author: "carol", avatar: "https://secure.gravatar.com/avatar/abc?s=80&d=identicon"),
            ].joined(separator: ",") + "]")
            accounts.append(Account(kind: .gitLab, organization: "acme", authMethod: .pat, instanceURL: instance))
            let fetch = try await makeProvider(http, instance: instance).tags(in: ["acme/api"])
            // Zoals HistoryView de foto's laadt.
            #expect(fetch.tags.count == 2)
            for url in fetch.tags.compactMap(\.authorAvatarURL) + fetch.tags.compactMap(\.release?.authorAvatarURL) {
                _ = try await http.send(URLRequest(url: url))
            }
        }

        let called = Set(http.requests.compactMap { $0.url?.host() })
        let listed = Set(SourcesOverview.otherConnections(config: AppConfig(accounts: accounts, checkForUpdates: false)).flatMap(\.urls).compactMap { $0.host() })
        expectCalledHostsAreListed(called: called, expected: ["gitlab.com", "git.example.com", "secure.gravatar.com"], listed: listed)
    }

    @Test func noReleaseRequestWithoutReleases() async throws {
        let http = MockHTTPClient()
        http.on("repository/tags", body: "[" + GitLabFixtures.tag("v1", created: nil, committed: "2025-07-01T10:00:00Z", author: "A", release: false) + "]")
        let fetch = try await makeProvider(http).tags(in: ["acme/api"])
        #expect(fetch.tags.count == 1)
        #expect(http.requests.count == 1)
    }

    @Test func missingOrForbiddenReposAreUnavailable() async throws {
        let http = MockHTTPClient()
        http.on("projects/acme%2Fgone/", status: 404, body: #"{"message":"404 Project Not Found"}"#)
        http.on("projects/acme%2Fsecret/", status: 403, body: #"{"message":"403 Forbidden"}"#)
        http.on("projects/acme%2Fok/repository/tags", body: "[]")
        let fetch = try await makeProvider(http).tags(in: ["acme/gone", "acme/secret", "acme/ok"])
        #expect(fetch.unavailableRepos == ["acme/gone", "acme/secret"])
        #expect(fetch.tags.isEmpty)
    }

    @Test func datedTagsNewestFirst() async throws {
        let http = MockHTTPClient()
        http.on("repository/tags", body: "[" + [
            GitLabFixtures.tag("old", created: nil, committed: "2024-01-01T00:00:00Z", author: "A", release: false),
            GitLabFixtures.tag("new", created: nil, committed: "2025-01-01T00:00:00Z", author: "A", release: false),
        ].joined(separator: ",") + "]")
        let tags = try await makeProvider(http).datedTags(in: "acme/api", limit: 1)
        #expect(tags.map(\.name) == ["new"])
    }

    // MARK: Co-auteurs

    @Test func coAuthorsFromCommitsAndTrailers() async throws {
        let http = MockHTTPClient()
        groupAcme(http)
        http.on("groups/acme/merge_requests", body: "[\(GitLabFixtures.mergeRequest(iid: 12))]")
        http.on("projects/acme%2Fplatform%2Fapi/merge_requests/12/commits", body: "[" + [
            GitLabFixtures.commit(author: "Alice Example", email: "alice@example.com", message: "Start\n\nCo-authored-by: Dan Pair <dan@example.com>"),
            GitLabFixtures.commit(author: "Eve Other", email: "eve@example.com", message: "Fix"),
            GitLabFixtures.commit(author: "project_99_bot_1", email: "project99_bot1@noreply.gitlab.com", message: "Bump"),
        ].joined(separator: ",") + "]")
        let provider = makeProvider(http)
        let prs = try await provider.openPullRequests()
        let found = try await provider.coAuthors(of: prs)
        let people = try #require(found[prs[0].dedupKey])
        // Alice is de auteur (op naam herkend); de bot valt weg.
        #expect(people.map(\.name) == ["Dan Pair", "Eve Other"])
        #expect(people.first?.email == "dan@example.com")
    }

    @Test func coAuthorsOfAMissingMergeRequestAreEmpty() async throws {
        let http = MockHTTPClient()
        http.on("merge_requests/5/commits", status: 404, body: #"{"message":"404 Not found"}"#)
        let pr = PullRequest.fixture(repo: "acme/api", number: 5)
        #expect(try await makeProvider(http).coAuthors(of: [pr])[pr.dedupKey] == [])
    }

    // MARK: Bestanden

    @Test func filePathsWalkTheTreeAcrossPages() async throws {
        let http = MockHTTPClient()
        http.on("repository/tree?recursive=true&ref=v1.0.0%2Bbuild&per_page=100&page=2", headers: ["x-next-page": ""],
                body: GitLabFixtures.tree([("src/main.swift", "blob")]))
        http.on("repository/tree?", headers: ["x-next-page": "2"],
                body: GitLabFixtures.tree([("Package.swift", "blob"), ("src", "tree")]))
        let paths = try await makeProvider(http).filePaths(in: "acme/api", ref: "v1.0.0+build")
        #expect(paths == ["Package.swift", "src/main.swift"])
        #expect(urls(http).first?.hasPrefix("\(api)projects/acme%2Fapi/repository/tree?") == true)
    }

    @Test func emptyRepoHasNoFiles() async throws {
        let http = MockHTTPClient()
        http.on("repository/tree", status: 404, body: #"{"message":"404 Tree Not Found"}"#)
        #expect(try await makeProvider(http).filePaths(in: "acme/empty", ref: nil).isEmpty)
    }

    @Test func fileContentEncodesThePathAsOneSegment() async throws {
        let http = MockHTTPClient()
        http.on("repository/files/", body: "{\n  \"name\": \"web\"\n}")
        let text = try await makeProvider(http).fileContent(in: "acme/platform/web", path: "apps/web/package.json", ref: "v2")
        #expect(text.contains("\"web\""))
        #expect(urls(http).first == "\(api)projects/acme%2Fplatform%2Fweb/repository/files/apps%2Fweb%2Fpackage.json/raw?ref=v2")
    }

    @Test func fileContentWithoutRefReadsTheDefaultBranch() async throws {
        let http = MockHTTPClient()
        http.on("repository/files/", body: "x")
        _ = try await makeProvider(http).fileContent(in: "acme/api", path: "go.mod", ref: nil)
        #expect(urls(http).first == "\(api)projects/acme%2Fapi/repository/files/go.mod/raw")
    }

    @Test func noSecurityFeed() async throws {
        let http = MockHTTPClient()
        #expect(try await makeProvider(http).securityAlerts(in: "acme/api") == nil)
        #expect(http.requests.isEmpty)
    }

    @Test func recognisesGitLabBots() {
        #expect(GitLabProvider.isBot("project_123_bot_4f2e"))
        #expect(GitLabProvider.isBot("group_9_bot"))
        #expect(GitLabProvider.isBot("renovate[bot]"))
        #expect(!GitLabProvider.isBot("abbott"))
    }
}
