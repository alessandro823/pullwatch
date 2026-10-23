import Foundation
import Testing
@testable import PullwatchCore

/// Provider met vaste repo's en bestanden; `repos == nil` laat `listRepos` falen.
private actor FileProvider: PRProvider {
    let repos: [String]?
    let files: [String: [String: String]]
    let brokenRepos: Set<String>

    init(repos: [String]?, files: [String: [String: String]], brokenRepos: Set<String> = []) {
        self.repos = repos
        self.files = files
        self.brokenRepos = brokenRepos
    }

    func currentUserId() async throws -> String { "me" }
    func testConnection() async throws -> String { "me" }
    func listRepos() async throws -> [String] {
        guard let repos else { throw ProviderError.unauthorized }
        return repos
    }
    func openPullRequests() async throws -> [PullRequest] { [] }
    func pullRequests(updatedSince since: Date?, limit: Int) async throws -> [PullRequest] { [] }
    func tags(in repos: [String]) async throws -> TagFetch { TagFetch(tags: []) }
    func filePaths(in repo: String) async throws -> [String] {
        if brokenRepos.contains(repo) { throw ProviderError.server(status: 500) }
        return (files[repo] ?? [:]).keys.sorted()
    }
    func fileContent(in repo: String, path: String) async throws -> String { files[repo]?[path] ?? "" }
    func invalidateCredentials() async {}
}

@Suite struct VersionCheckerTests {
    let now = Date(timeIntervalSince1970: 1_792_000_000)

    func goReleases() -> String {
        #"""
        {"result":{"releases":[
          {"name":"1.27","releaseDate":"2026-08-19","isEol":false,"latest":{"name":"1.27.3"}},
          {"name":"1.26","releaseDate":"2026-02-10","isEol":false,"latest":{"name":"1.26.10"}},
          {"name":"1.25","releaseDate":"2025-08-12","isEol":true,"latest":{"name":"1.25.9"}}
        ]}}
        """#
    }

    func account(_ watch: [String: WatchSet], default fallback: NewRepoDefault = .none) -> Account {
        Account(kind: .gitHub, displayName: "Acme", organization: "acme", authMethod: .pat, repoWatch: watch, newRepoDefault: fallback)
    }

    @Test func checksOnlyFollowedReposAndSortsWorstFirst() async {
        let http = MockHTTPClient()
        http.on("products/go", body: goReleases())
        let provider = FileProvider(
            repos: ["acme/new", "acme/old", "acme/skip", "acme/tagsonly"],
            files: [
                "acme/new": ["go.mod": "go 1.27.1"],
                "acme/old": ["go.mod": "go 1.26", "tools/go.mod": "go 1.25.0", "node_modules/x/go.mod": "go 1.1"],
                "acme/skip": ["go.mod": "go 1.25"],
                "acme/tagsonly": [:],
            ]
        )
        let acc = account(["acme/new": .prs, "acme/old": WatchSet(prs: false, tags: false, completed: true), "acme/tagsonly": .tags])
        let checker = VersionChecker(makeProvider: { _ in provider }, http: http, now: { now })

        let report = await checker.run(accounts: [acc])

        #expect(report.repos.map(\.repo) == ["acme/old", "acme/new", "acme/tagsonly"])
        let old = report.repos[0].components
        #expect(old.count == 1)
        #expect(old[0].version == "1.25.0")
        #expect(old[0].status == .eol)
        #expect(old[0].latest == "1.27.3")
        #expect(old[0].sources == ["go.mod", "tools/go.mod"])
        #expect(report.repos[1].components.first?.status == .current)
        #expect(report.repos[2].components.isEmpty)
        #expect(http.requests.filter { $0.url!.absoluteString.contains("products/go") }.count == 1)
    }

    @Test func followsReposViaNewRepoDefault() async {
        let provider = FileProvider(repos: ["acme/a"], files: [:])
        let report = await VersionChecker(makeProvider: { _ in provider }, http: MockHTTPClient(), now: { now })
            .run(accounts: [account([:], default: .prs)])
        #expect(report.repos.map(\.repo) == ["acme/a"])
    }

    @Test func errorsStayPerRepoAndPerAccount() async {
        let http = MockHTTPClient()
        let good = FileProvider(repos: ["acme/ok", "acme/broken"], files: ["acme/ok": [:]], brokenRepos: ["acme/broken"])
        let failing = FileProvider(repos: nil, files: [:])
        let first = account(["acme/ok": .prs, "acme/broken": .prs])
        let second = Account(kind: .gitHub, displayName: "Kapot", organization: "kapot", authMethod: .pat)
        let checker = VersionChecker(makeProvider: { $0.id == first.id ? good : failing }, http: http, now: { now })

        let report = await checker.run(accounts: [first, second])

        let byRepo = Dictionary(uniqueKeysWithValues: report.repos.map { ($0.repo, $0) })
        #expect(byRepo["acme/ok"]?.error == nil)
        #expect(byRepo["acme/broken"]?.error == ProviderError.server(status: 500).userMessage)
        #expect(byRepo["Kapot"]?.error == ProviderError.unauthorized.userMessage)
    }

    @Test func unknownWhenReleasesUnavailable() async {
        let http = MockHTTPClient()
        http.on("products/go", status: 500, body: "")
        let provider = FileProvider(repos: ["acme/a"], files: ["acme/a": ["go.mod": "go 1.26"]])
        let report = await VersionChecker(makeProvider: { _ in provider }, http: http, now: { now })
            .run(accounts: [account(["acme/a": .prs])])
        #expect(report.repos.first?.components.first?.status == .unknown)
    }

    @Test func comparesVersionsNumerically() {
        #expect(VersionChecker.isOlder("1.9", than: "1.10"))
        #expect(!VersionChecker.isOlder("1.10", than: "1.9"))
        #expect(!VersionChecker.isOlder("8.0", than: "8"))
    }
}

@Suite struct ProviderFileTests {
    @Test func gitHubListsBlobsAndTreatsEmptyRepoAsNoFiles() async throws {
        let http = MockHTTPClient()
        http.on("repos/acme/empty/git/trees", status: 409, body: "{}")
        http.on("repos/acme/web/git/trees/HEAD", body: #"{"tree":[{"path":"src","type":"tree"},{"path":"src/go.mod","type":"blob"}],"truncated":false}"#)
        let provider = GitHubProvider(accountId: fixedAccountId, owner: "acme", tokenSource: StaticTokenSource(token: "t"), http: http)

        #expect(try await provider.filePaths(in: "acme/web") == ["src/go.mod"])
        #expect(try await provider.filePaths(in: "acme/empty") == [])
        #expect(http.requests.first?.url?.query == "recursive=1")
    }

    @Test func gitHubReadsRawContent() async throws {
        let http = MockHTTPClient()
        http.on("repos/acme/web/contents/src/go.mod", body: "go 1.26\n")
        let provider = GitHubProvider(accountId: fixedAccountId, owner: "acme", tokenSource: StaticTokenSource(token: "t"), http: http)

        #expect(try await provider.fileContent(in: "acme/web", path: "src/go.mod") == "go 1.26\n")
        #expect(http.requests.first?.value(forHTTPHeaderField: "Accept") == "application/vnd.github.raw+json")
    }

    @Test func azureListsFilesAndReadsContent() async throws {
        let http = MockHTTPClient()
        http.on("includeContent=true", body: #"{"path":"/src/go.mod","content":"go 1.26"}"#)
        http.on("Proj/_apis/git/repositories/web/items", body: #"{"value":[{"path":"/","isFolder":true},{"path":"/src/go.mod"}]}"#)
        let provider = AzureDevOpsProvider(
            accountId: fixedAccountId, organization: "org", tokenSource: StaticTokenSource(token: "t"), authMethod: .pat, http: http
        )

        #expect(try await provider.filePaths(in: "Proj/web") == ["src/go.mod"])
        #expect(try await provider.fileContent(in: "Proj/web", path: "src/go.mod") == "go 1.26")
        let query = http.requests.last?.url?.query ?? ""
        #expect(query.contains("path=/src/go.mod"))
    }
}
