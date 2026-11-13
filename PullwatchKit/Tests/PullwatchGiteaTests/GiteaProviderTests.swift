import Foundation
import Testing
@testable import PullwatchCore
@testable import PullwatchGitea
import PullwatchTestSupport

/// Een smaak met zijn server, zoals `ProviderFactory` hem doorgeeft.
struct Flavour: CustomTestStringConvertible, Sendable {
    let name: String
    let server: String

    var host: String { URL(string: server)!.host()! }
    var api: String { server + "/api/v1/" }
    var testDescription: String { name }

    static let codeberg = Flavour(name: "Codeberg", server: "https://codeberg.org")
    static let forgejo = Flavour(name: "Forgejo", server: "https://forgejo.example.com")
    static let giteaCom = Flavour(name: "Gitea", server: "https://gitea.com")
    static let giteaOwn = Flavour(name: "Gitea", server: "https://example.com/gitea")
    static let all = [codeberg, forgejo, giteaCom, giteaOwn]
}

func makeProvider(
    _ http: MockHTTPClient,
    flavour: Flavour = .codeberg,
    owners: [String] = ["acme"],
    extraRepos: [String] = [],
    now: @escaping @Sendable () -> Date = { Date.testStart }
) -> GiteaProvider {
    GiteaProvider(
        accountId: fixedAccountId, owners: owners, extraRepos: extraRepos, instanceURL: URL(string: flavour.server)!,
        serviceName: flavour.name, tokenSource: StaticTokenSource(token: "gitea-secret"), http: http, now: now
    )
}

func urls(_ http: MockHTTPClient) -> [String] {
    http.requests.compactMap { $0.url?.absoluteString }
}

@Suite struct GiteaProviderTests {
    // MARK: Gebruiker en verbinding

    @Test func `Current user is the login with the token header`() async throws {
        let http = MockHTTPClient()
        http.on("https://codeberg.org/api/v1/user", body: GiteaFixtures.user())
        #expect(try await makeProvider(http).currentUserId() == "jdoe")
        let request = try #require(http.requests.first)
        #expect(request.url?.absoluteString == "https://codeberg.org/api/v1/user")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "token gitea-secret")
    }

    @Test(arguments: Flavour.all)
    func `Test connection checks the user, every owner and the pull request search`(flavour: Flavour) async throws {
        let http = MockHTTPClient()
        http.on("\(flavour.api)orgs/acme", body: GiteaFixtures.organization("acme", forgejo: flavour.name != "Gitea"))
        http.on("\(flavour.api)orgs/jdoe", status: 404, body: GiteaFixtures.orgNotFound)
        http.on("\(flavour.api)users/jdoe", body: GiteaFixtures.user(host: flavour.host))
        http.on("\(flavour.api)repos/issues/search", body: "[]")
        http.on("\(flavour.api)user", body: GiteaFixtures.user(host: flavour.host))
        let name = try await makeProvider(http, flavour: flavour, owners: ["acme", "jdoe"]).testConnection()
        #expect(name == "jdoe")
        #expect(urls(http) == [
            "\(flavour.api)user", "\(flavour.api)orgs/acme", "\(flavour.api)orgs/jdoe", "\(flavour.api)users/jdoe",
            "\(flavour.api)repos/issues/search?type=pulls&limit=1",
        ])
    }

    @Test func `An invalid token is unauthorized`() async {
        let http = MockHTTPClient()
        http.on("https://codeberg.org/api/v1/user", status: 401, body: GiteaFixtures.tokenRequired)
        await #expect(throws: ProviderError.unauthorized) { try await makeProvider(http).testConnection() }
    }

    @Test(arguments: [GiteaFixtures.forgejoMissingScope("read:issue"), GiteaFixtures.giteaMissingScope("read:issue")])
    func `A token without a scope says which scope`(body: String) async {
        let http = MockHTTPClient()
        http.on("https://codeberg.org/api/v1/orgs/acme", body: GiteaFixtures.organization("acme"))
        http.on("https://codeberg.org/api/v1/repos/issues/search", status: 403, body: body)
        http.on("https://codeberg.org/api/v1/user", body: GiteaFixtures.user())
        await #expect(throws: ProviderError.missingScope("read:issue")) { try await makeProvider(http).testConnection() }
    }

    @Test func `A plain 403 stays unauthorized`() async {
        let http = MockHTTPClient()
        http.on("https://codeberg.org/api/v1/user", status: 403, body: #"{"message":"Forbidden"}"#)
        await #expect(throws: ProviderError.unauthorized) { try await makeProvider(http).testConnection() }
    }

    @Test(arguments: [(404, GiteaFixtures.notFound), (200, "<!DOCTYPE html><html><body>Sign in</body></html>")])
    func `A server that is not Gitea or Forgejo says so`(status: Int, body: String) async {
        let http = MockHTTPClient()
        http.on("https://forgejo.example.com/api/v1/user", status: status, body: body)
        await #expect(throws: ProviderError.unexpectedServer(host: "forgejo.example.com", service: "Forgejo")) {
            try await makeProvider(http, flavour: .forgejo).testConnection()
        }
    }

    @Test func `An unknown owner is no access`() async {
        let http = MockHTTPClient()
        http.on("https://codeberg.org/api/v1/orgs/nobody", status: 404, body: GiteaFixtures.orgNotFound)
        http.on("https://codeberg.org/api/v1/users/nobody", status: 404, body: GiteaFixtures.notFound)
        http.on("https://codeberg.org/api/v1/user", body: GiteaFixtures.user())
        await #expect(throws: ProviderError.noAccess("nobody")) { try await makeProvider(http, owners: ["nobody"]).testConnection() }
    }

    @Test func `Error messages name the scope or the server`() {
        for error in [
            ProviderError.missingScope("read:issue"), .untrustedCertificate("git.example.com"),
            .unexpectedServer(host: "git.example.com", service: "Forgejo"),
        ] {
            #expect(error.userMessage.contains("read:issue") || error.userMessage.contains("git.example.com"))
        }
    }

    // MARK: Repo's

    @Test func `Repositories of an organisation and a user, without archived ones`() async throws {
        let http = MockHTTPClient()
        http.on("https://codeberg.org/api/v1/orgs/acme/repos",
                body: "[\(GiteaFixtures.repository("acme/api")),\(GiteaFixtures.repository("acme/old", archived: true))]")
        http.on("https://codeberg.org/api/v1/orgs/acme", body: GiteaFixtures.organization("acme"))
        http.on("https://codeberg.org/api/v1/orgs/jdoe", status: 404, body: GiteaFixtures.orgNotFound)
        http.on("https://codeberg.org/api/v1/users/jdoe/repos", body: "[\(GiteaFixtures.repository("jdoe/dotfiles"))]")
        http.on("https://codeberg.org/api/v1/users/jdoe", body: GiteaFixtures.user())
        let repos = try await makeProvider(http, owners: ["acme", "jdoe"]).listRepos()
        #expect(repos == ["acme/api", "jdoe/dotfiles"])
    }

    @Test func `Pages follow the Link header on the same server only`() async throws {
        let http = MockHTTPClient()
        http.on("https://codeberg.org/api/v1/orgs/acme/repos?limit=50&page=2", body: "[\(GiteaFixtures.repository("acme/two"))]")
        http.on("https://codeberg.org/api/v1/orgs/acme/repos?limit=50&page=1", headers: [
            "Link": #"<https://codeberg.org/api/v1/orgs/acme/repos?limit=50&page=2>; rel="next",<https://codeberg.org/api/v1/orgs/acme/repos?limit=50&page=2>; rel="last""#,
            "X-Total-Count": "2",
        ], body: "[\(GiteaFixtures.repository("acme/one"))]")
        http.on("https://codeberg.org/api/v1/orgs/acme", body: GiteaFixtures.organization("acme"))
        #expect(try await makeProvider(http).listRepos() == ["acme/one", "acme/two"])

        let elsewhere = MockHTTPClient()
        elsewhere.on("https://codeberg.org/api/v1/orgs/acme/repos?limit=50&page=1", headers: [
            "Link": #"<https://evil.example.com/api/v1/orgs/acme/repos?page=2>; rel="next""#,
        ], body: "[\(GiteaFixtures.repository("acme/one"))]")
        elsewhere.on("https://codeberg.org/api/v1/orgs/acme", body: GiteaFixtures.organization("acme"))
        #expect(try await makeProvider(elsewhere).listRepos() == ["acme/one"])
        #expect(!urls(elsewhere).contains { $0.contains("evil.example.com") })
    }

    @Test(arguments: [
        "http://codeberg.org/api/v1/orgs/acme/repos?limit=50&page=2",
        "https://codeberg.org:8443/api/v1/orgs/acme/repos?limit=50&page=2",
        "https://gitea.com/api/v1/orgs/acme/repos?limit=50&page=2",
    ])
    func `A Link with another scheme, port or host is not followed`(next: String) async throws {
        let http = MockHTTPClient()
        http.on("page=2", body: "[\(GiteaFixtures.repository("acme/two"))]")
        http.on("https://codeberg.org/api/v1/orgs/acme/repos?limit=50&page=1", headers: [
            "Link": "<\(next)>; rel=\"next\"", "X-Total-Count": "2",
        ], body: "[\(GiteaFixtures.repository("acme/one"))]")
        http.on("https://codeberg.org/api/v1/orgs/acme", body: GiteaFixtures.organization("acme"))
        #expect(try await makeProvider(http).listRepos() == ["acme/one"])
        #expect(!urls(http).contains { $0.contains("page=2") })
    }

    @Test func `Without a Link header a full page goes on while X-Total-Count promises more`() async throws {
        let http = MockHTTPClient()
        let full = (1...50).map { GiteaFixtures.repository("acme/r\($0)") }.joined(separator: ",")
        http.on("https://codeberg.org/api/v1/orgs/acme/repos?limit=50&page=2", headers: ["X-Total-Count": "51"],
                body: "[\(GiteaFixtures.repository("acme/last"))]")
        http.on("https://codeberg.org/api/v1/orgs/acme/repos?limit=50&page=1", headers: ["X-Total-Count": "51"], body: "[\(full)]")
        http.on("https://codeberg.org/api/v1/orgs/acme", body: GiteaFixtures.organization("acme"))
        let repos = try await makeProvider(http).listRepos()
        #expect(repos.count == 51)
        #expect(repos.contains("acme/last"))
        #expect(!urls(http).contains { $0.contains("page=3") })
    }

    // MARK: Pull requests

    @Test(arguments: Flavour.all)
    func `Open pull requests come from one search per owner`(flavour: Flavour) async throws {
        let http = MockHTTPClient()
        http.on("\(flavour.api)orgs/acme", body: GiteaFixtures.organization("acme"))
        http.on("\(flavour.api)repos/issues/search", body: """
        [\(GiteaFixtures.issue(number: 12, host: flavour.host)),\(GiteaFixtures.issue(number: 13, draft: true, host: flavour.host))]
        """)
        let prs = try await makeProvider(http, flavour: flavour).openPullRequests()
        #expect(prs.map(\.number) == [12, 13])
        let first = try #require(prs.first)
        #expect(first.repo == "acme/api")
        #expect(first.authorId == "alice")
        #expect(first.state == .open)
        #expect(!first.isDraft)
        #expect(prs[1].isDraft)
        #expect(first.webURL.absoluteString == "https://\(flavour.host)/acme/api/pulls/12")
        #expect(first.revision == "2026-11-04T12:39:40+01:00")
        #expect(first.authorAvatarURL?.host() == flavour.host)
        #expect(urls(http).last == "\(flavour.api)repos/issues/search?type=pulls&owner=acme&state=open&limit=50&page=1")
    }

    @Test(arguments: [
        ("WIP: new parser", true), ("[WIP] new parser", true), ("wip: lower case", true), ("Wipe the cache", false),
    ])
    func `Without a draft field the WIP prefix makes a draft`(title: String, isDraft: Bool) async throws {
        let http = MockHTTPClient()
        http.on("https://gitea.com/api/v1/orgs/acme", body: GiteaFixtures.organization("acme", forgejo: false))
        http.on("https://gitea.com/api/v1/repos/issues/search",
                body: "[\(GiteaFixtures.issue(number: 1, title: title, draft: nil, host: "gitea.com"))]")
        let pr = try #require(try await makeProvider(http, flavour: .giteaCom).openPullRequests().first)
        #expect(pr.isDraft == isDraft)
    }

    @Test func `The draft flag wins over the title`() async throws {
        let http = MockHTTPClient()
        http.on("https://codeberg.org/api/v1/orgs/acme", body: GiteaFixtures.organization("acme"))
        http.on("https://codeberg.org/api/v1/repos/issues/search", body: "[\(GiteaFixtures.issue(number: 1, title: "WIP: done", draft: false))]")
        #expect(try await makeProvider(http).openPullRequests().first?.isDraft == false)
    }

    @Test func `Recent pull requests are merged, closed or open and newest first`() async throws {
        let http = MockHTTPClient()
        http.on("https://codeberg.org/api/v1/orgs/acme", body: GiteaFixtures.organization("acme"))
        http.on("https://codeberg.org/api/v1/repos/issues/search", body: """
        [\(GiteaFixtures.issue(number: 1, state: "closed", merged: true, mergedAt: "2026-11-04T13:00:00+01:00", closedAt: "2026-11-04T13:00:00+01:00")),
         \(GiteaFixtures.issue(number: 2, state: "closed", closedAt: "2026-11-04T14:00:00+01:00")),
         \(GiteaFixtures.issue(number: 3))]
        """)
        let since = Date(timeIntervalSince1970: 1_793_000_000)
        let prs = try await makeProvider(http).pullRequests(updatedSince: since, limit: 2)
        #expect(prs.map(\.number) == [2, 1])
        #expect(prs.map(\.state) == [.closed, .merged])
        #expect(prs[1].closedAt == DateParsing.parse("2026-11-04T13:00:00+01:00"))
        let query = try #require(urls(http).last)
        #expect(query.contains("state=all"))
        #expect(query.contains("since=2026-10-26T"))
    }

    // MARK: Tags

    @Test func `Tags carry their release, pre-release and author`() async throws {
        let http = MockHTTPClient()
        http.on("https://codeberg.org/api/v1/repos/acme/api/tags", body: """
        [\(GiteaFixtures.tag("v2.0.0-rc.1")),\(GiteaFixtures.tag("v1.0.0", created: "2026-01-02T10:00:00Z")),\(GiteaFixtures.tag("v0.9"))]
        """)
        http.on("https://codeberg.org/api/v1/repos/acme/api/releases", body: """
        [\(GiteaFixtures.release("v2.0.0-rc.1", prerelease: true)),\(GiteaFixtures.release("v1.0.0", author: "renovate-bot")),\(GiteaFixtures.release("v0.9", draft: true))]
        """)
        let fetch = try await makeProvider(http).tags(in: ["acme/api"])
        #expect(fetch.tags.map(\.name) == ["v2.0.0-rc.1", "v1.0.0", "v0.9"])
        let candidate = try #require(fetch.tags.first?.release)
        #expect(candidate.isPrerelease)
        #expect(candidate.title == "Version v2.0.0-rc.1")
        #expect(candidate.url.absoluteString == "https://codeberg.org/acme/api/releases/tag/v2.0.0-rc.1")
        #expect(fetch.tags[0].authorName == "jdoe")
        // Een bot is geen auteur; de release blijft.
        #expect(fetch.tags[1].authorName == nil)
        #expect(fetch.tags[1].release != nil)
        #expect(fetch.tags[1].createdAt == DateParsing.parse("2026-01-02T10:00:00Z"))
        // Een draft-release telt niet: de tag gaat naar zijn eigen pagina.
        #expect(fetch.tags[2].release == nil)
        #expect(fetch.tags[2].webURL.absoluteString == "https://codeberg.org/acme/api/src/tag/v0.9")
    }

    @Test func `A missing or forbidden repository is unavailable`() async throws {
        let http = MockHTTPClient()
        http.on("https://codeberg.org/api/v1/repos/acme/gone/tags", status: 404, body: GiteaFixtures.notFound)
        http.on("https://codeberg.org/api/v1/repos/acme/secret/tags", status: 403, body: #"{"message":"Forbidden"}"#)
        let fetch = try await makeProvider(http).tags(in: ["acme/gone", "acme/secret"])
        #expect(fetch.unavailableRepos == ["acme/gone", "acme/secret"])
    }

    // MARK: Checks

    @Test(arguments: [
        ("success", CheckCounts(passed: 1)), ("warning", CheckCounts(passed: 1)), ("skipped", CheckCounts(skipped: 1)),
        ("failure", CheckCounts(failed: 1)), ("error", CheckCounts(failed: 1)), ("pending", CheckCounts(pending: 1)),
    ])
    func `Commit statuses become checks`(status: String, counts: CheckCounts) async throws {
        let http = MockHTTPClient()
        http.on("https://codeberg.org/api/v1/repos/acme/api/pulls/12", body: GiteaFixtures.pull(number: 12, sha: "abc123"))
        http.on("https://codeberg.org/api/v1/repos/acme/api/commits/abc123/status", body: GiteaFixtures.combinedStatus([status]))
        let pr = PullRequest.fixture(repo: "acme/api", number: 12)
        let checks = try await makeProvider(http).checks(of: [pr])
        #expect(checks[pr.dedupKey] == .counts(counts))
    }

    @Test func `A mix of statuses counts each one`() async throws {
        let http = MockHTTPClient()
        http.on("https://codeberg.org/api/v1/repos/acme/api/pulls/12", body: GiteaFixtures.pull(number: 12, sha: "abc123"))
        http.on("https://codeberg.org/api/v1/repos/acme/api/commits/abc123/status",
                body: GiteaFixtures.combinedStatus(["success", "success", "failure", "pending", "unknown"]))
        let pr = PullRequest.fixture(repo: "acme/api", number: 12)
        let counts = try #require(try await makeProvider(http).checks(of: [pr])[pr.dedupKey]?.counts)
        #expect(counts == CheckCounts(passed: 2, failed: 1, pending: 1))
    }

    @Test func `Forbidden statuses need permission and a missing pull request is left out`() async throws {
        let http = MockHTTPClient()
        http.on("https://codeberg.org/api/v1/repos/acme/api/pulls/12", body: GiteaFixtures.pull(number: 12, sha: "abc123"))
        http.on("https://codeberg.org/api/v1/repos/acme/api/commits/abc123/status", status: 403,
                body: GiteaFixtures.forgejoMissingScope("read:repository"))
        http.on("https://codeberg.org/api/v1/repos/acme/api/pulls/13", status: 404, body: GiteaFixtures.notFound)
        let forbidden = PullRequest.fixture(repo: "acme/api", number: 12)
        let gone = PullRequest.fixture(repo: "acme/api", number: 13)
        let checks = try await makeProvider(http).checks(of: [forbidden, gone])
        #expect(checks[forbidden.dedupKey] == .needsPermission)
        #expect(checks[gone.dedupKey] == nil)
    }

    // MARK: Co-auteurs

    @Test func `Co-authors come from commit authors and trailers`() async throws {
        let http = MockHTTPClient()
        http.on("https://codeberg.org/api/v1/repos/acme/api/pulls/12/commits", body: """
        [\(GiteaFixtures.commit(name: "Alice Example", email: "alice@example.com", login: "alice", message: "Fix\\n\\nCo-authored-by: Bob Builder <bob@example.com>")),
         \(GiteaFixtures.commit(name: "Carol", email: "carol@example.com", login: "carol", message: "More")),
         \(GiteaFixtures.commit(name: "Renovate Bot", email: "bot@example.com", login: "renovate-bot", message: "Update"))]
        """)
        let pr = PullRequest.fixture(repo: "acme/api", number: 12, authorId: "alice", authorName: "alice")
        let people = try #require(try await makeProvider(http).coAuthors(of: [pr])[pr.dedupKey])
        #expect(people.map(\.name).sorted() == ["Bob Builder", "Carol"])
        #expect(people.first { $0.name == "Carol" }?.login == "carol")
        #expect(try #require(urls(http).first).contains("verification=false&files=false"))
    }

    // MARK: Bestanden

    @Test func `File paths page through the tree until the total`() async throws {
        let http = MockHTTPClient()
        http.on("https://codeberg.org/api/v1/repos/acme/api/git/trees/HEAD?recursive=true&per_page=1000&page=2",
                body: GiteaFixtures.tree([("src/main.go", "blob")], page: 2, total: 3))
        http.on("https://codeberg.org/api/v1/repos/acme/api/git/trees/HEAD?recursive=true&per_page=1000&page=1",
                body: GiteaFixtures.tree([("go.mod", "blob"), ("src", "tree")], page: 1, total: 3))
        #expect(try await makeProvider(http).filePaths(in: "acme/api", ref: nil) == ["go.mod", "src/main.go"])
        #expect(urls(http).count == 2)
    }

    @Test func `An empty repository has no files`() async throws {
        let http = MockHTTPClient()
        http.on("https://codeberg.org/api/v1/repos/acme/empty/git/trees/v1.0", status: 404, body: GiteaFixtures.notFound)
        #expect(try await makeProvider(http).filePaths(in: "acme/empty", ref: "v1.0").isEmpty)
    }

    @Test func `File content is raw text on the ref`() async throws {
        let http = MockHTTPClient()
        http.on("https://codeberg.org/api/v1/repos/acme/api/raw/src/my%20file.txt?ref=v1.0%2Bbuild", body: "module forgejo.org\n")
        #expect(try await makeProvider(http).fileContent(in: "acme/api", path: "src/my file.txt", ref: "v1.0+build") == "module forgejo.org\n")
    }

    // MARK: Losse repo's

    @Test func `A public repository the token cannot read is read without it`() async throws {
        let http = MockHTTPClient()
        http.on("https://codeberg.org/api/v1/repos/other/lib/pulls", authorized: false, body: "[\(GiteaFixtures.pull(number: 4, repo: "other/lib"))]")
        http.on("https://codeberg.org/api/v1/repos/other/lib", authorized: true, status: 404, body: GiteaFixtures.notFound)
        http.on("https://codeberg.org/api/v1/repos/other/lib", authorized: false, body: GiteaFixtures.repository("other/lib"))
        http.on("https://codeberg.org/api/v1/orgs/acme", body: GiteaFixtures.organization("acme"))
        http.on("https://codeberg.org/api/v1/repos/issues/search", body: "[]")
        let provider = makeProvider(http, extraRepos: ["other/lib", "acme/inside"])
        #expect(try await provider.checkRepository("other/lib") == RepositoryCheck(name: "other/lib", readWithoutSignIn: true))
        let prs = try await provider.openPullRequests()
        #expect(prs.map(\.number) == [4])
        let request = try #require(http.requests.last)
        #expect(request.url?.absoluteString.contains("repos/other/lib/pulls?state=open&sort=recentupdate") == true)
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
        // `acme/inside` valt onder de gevolgde eigenaar: geen eigen vraag.
        #expect(!urls(http).contains { $0.contains("acme/inside") })
    }

    @Test func `A repository nobody can read is no access`() async {
        let http = MockHTTPClient()
        http.on("https://codeberg.org/api/v1/repos/other/private", authorized: true, status: 404, body: GiteaFixtures.notFound)
        http.on("https://codeberg.org/api/v1/repos/other/private", authorized: false, status: 401, body: GiteaFixtures.tokenRequired)
        await #expect(throws: ProviderError.noAccess("other/private")) {
            try await makeProvider(http, extraRepos: ["other/private"]).checkRepository("other/private")
        }
    }

    // MARK: Bronnen

    @Test(arguments: [GiteaFlavour.codeberg, .gitea])
    func `The sources overview names the same API`(flavour: GiteaFlavour) async {
        let account = Account(kind: .gitea, organization: "acme", authMethod: .pat, giteaFlavour: flavour)
        let provider = GiteaProvider(
            accountId: account.id, owners: account.owners, instanceURL: account.effectiveInstanceURL!,
            tokenSource: StaticTokenSource(token: "t"), http: MockHTTPClient()
        )
        let endpoint = await provider.endpoint("user")
        #expect(SourcesOverview.server(of: account).appending(path: "user") == endpoint)
    }

    @Test func `An own server keeps its path`() async {
        let account = Account(
            kind: .gitea, organization: "acme", authMethod: .pat, instanceURL: URL(string: "https://example.com/forgejo"),
            giteaFlavour: .forgejo
        )
        let provider = makeProvider(MockHTTPClient(), flavour: Flavour(name: "Forgejo", server: "https://example.com/forgejo"))
        let endpoint = await provider.endpoint("user")
        #expect(endpoint.absoluteString == "https://example.com/forgejo/api/v1/user")
        #expect(SourcesOverview.server(of: account).appending(path: "user") == endpoint)
    }

@Suite struct GiteaPullRequestBranchTests {
    @Test func `A pull request from the same repository carries its branches`() async throws {
        let dto = try JSONDecoding.decode(PullRequestDTO.self, from: Data(GiteaFixtures.pull(number: 12).utf8), snakeCase: true)

        let pr = try await makeProvider(MockHTTPClient()).makePullRequest(dto, repo: "acme/api")

        #expect(pr.sourceBranch == "feature")
        #expect(pr.targetBranch == "main")
    }

    @Test func `A pull request from a fork has no source branch`() async throws {
        let dto = try JSONDecoding.decode(PullRequestDTO.self, from: Data(Self.withForkHead(GiteaFixtures.pull(number: 12)).utf8), snakeCase: true)

        let pr = try await makeProvider(MockHTTPClient()).makePullRequest(dto, repo: "acme/api")

        #expect(pr.sourceBranch == nil)
    }

    /// De head-repo wordt `jane/api`, een fork.
    static func withForkHead(_ json: String) -> String {
        guard let range = json.range(of: #""head":"#) else { return json }
        var tail = String(json[range.lowerBound...])
        tail = tail.replacingOccurrences(of: #""full_name":"acme/api""#, with: #""full_name":"jane/api""#)
        return String(json[..<range.lowerBound]) + tail
    }
}

}
