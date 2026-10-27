import Foundation
import Testing
@testable import PullwatchCore

/// Provider met vaste repo's en bestanden; `repos == nil` laat `listRepos` falen.
/// Bestanden op een tag staan onder "repo@tag".
private actor FileProvider: PRProvider {
    let repos: [String]?
    let files: [String: [String: String]]
    let brokenRepos: Set<String>
    let tagNames: [String: [String]]

    init(repos: [String]?, files: [String: [String: String]], brokenRepos: Set<String> = [], tags: [String: [String]] = [:]) {
        self.repos = repos
        self.files = files
        self.brokenRepos = brokenRepos
        self.tagNames = tags
    }

    func currentUserId() async throws -> String { "me" }
    func testConnection() async throws -> String { "me" }
    func listRepos() async throws -> [String] {
        guard let repos else { throw ProviderError.unauthorized }
        return repos
    }
    func openPullRequests() async throws -> [PullRequest] { [] }
    func pullRequests(updatedSince since: Date?, limit: Int) async throws -> [PullRequest] { [] }
    func tags(in repos: [String]) async throws -> TagFetch {
        TagFetch(tags: repos.flatMap { repo in
            (tagNames[repo] ?? []).map { Tag(accountId: UUID(), repo: repo, name: $0, authorName: nil, webURL: URL(string: "https://x")!) }
        })
    }
    func filePaths(in repo: String, ref: String?) async throws -> [String] {
        let key = ref.map { "\(repo)@\($0)" } ?? repo
        if brokenRepos.contains(key) { throw ProviderError.server(status: 500) }
        return (files[key] ?? [:]).keys.sorted()
    }
    func fileContent(in repo: String, path: String, ref: String?) async throws -> String {
        files[ref.map { "\(repo)@\($0)" } ?? repo]?[path] ?? ""
    }
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
        #expect(!query.contains("versionDescriptor"))
    }

    @Test func gitHubReadsTreeAndContentOnTag() async throws {
        let http = MockHTTPClient()
        http.on("git/trees/v1.2.0", body: #"{"tree":[{"path":"go.mod","type":"blob"}]}"#)
        http.on("contents/go.mod", body: "go 1.26\n")
        let provider = GitHubProvider(accountId: fixedAccountId, owner: "acme", tokenSource: StaticTokenSource(token: "t"), http: http)

        #expect(try await provider.filePaths(in: "acme/web", ref: "v1.2.0") == ["go.mod"])
        #expect(try await provider.fileContent(in: "acme/web", path: "go.mod", ref: "v1.2.0") == "go 1.26\n")
        #expect(http.requests.last?.url?.query == "ref=v1.2.0")
    }

    @Test func azureReadsOnTag() async throws {
        let http = MockHTTPClient()
        http.on("includeContent=true", body: #"{"path":"/go.mod","content":"go 1.26"}"#)
        let provider = AzureDevOpsProvider(
            accountId: fixedAccountId, organization: "org", tokenSource: StaticTokenSource(token: "t"), authMethod: .pat, http: http
        )

        _ = try await provider.fileContent(in: "Proj/web", path: "go.mod", ref: "v1.2.0")
        let query = http.requests.last?.url?.query ?? ""
        #expect(query.contains("versionDescriptor.version=v1.2.0"))
        #expect(query.contains("versionDescriptor.versionType=tag"))
    }
}

@Suite struct VersionCheckerVulnerabilityTests {
    let now = Date(timeIntervalSince1970: 1_792_000_000)

    func account() -> Account {
        Account(kind: .gitHub, displayName: "Acme", organization: "acme", authMethod: .pat, repoWatch: ["acme/a": .prs, "acme/b": .prs])
    }

    @Test func attachesVulnerabilitiesPerRepoWithOneSharedQuery() async {
        let http = MockHTTPClient()
        http.on("querybatch", body: #"{"results":[{"vulns":[{"id":"GHSA-a"}]}]}"#)
        http.on("vulns/GHSA-a", body: #"{"id":"GHSA-a","summary":"lek","database_specific":{"severity":"HIGH"},"affected":[{"package":{"name":"lodash","ecosystem":"npm"},"ranges":[{"events":[{"fixed":"4.17.21"}]}]}]}"#)
        let lock = #"{"lockfileVersion":3,"packages":{"node_modules/lodash":{"version":"4.17.20"}}}"#
        let provider = FileProvider(repos: ["acme/a", "acme/b"], files: [
            "acme/a": ["package-lock.json": lock],
            "acme/b": ["web/package-lock.json": lock, "package.json": "{}"],
        ])

        let report = await VersionChecker(makeProvider: { _ in provider }, http: http, now: { now }).run(accounts: [account()])

        #expect(report.repos.count == 2)
        for repo in report.repos {
            #expect(repo.vulnerabilities.map(\.id) == ["GHSA-a"])
            #expect(repo.vulnerabilities.first?.fixedIn == "4.17.21")
            #expect(repo.severity == VersionStatus.eol.severity)
        }
        #expect(http.requests.filter { $0.url!.absoluteString.contains("querybatch") }.count == 1)
    }

    @Test func osvFailureIsReportedButVersionsRemain() async {
        let http = MockHTTPClient()
        http.on("querybatch", status: 500, body: "")
        let provider = FileProvider(repos: ["acme/a"], files: ["acme/a": ["go.mod": "go 1.26\nrequire x.com/y v1.0.0\n"]])

        let report = await VersionChecker(makeProvider: { _ in provider }, http: http, now: { now }).run(accounts: [account()])

        let repo = report.repos.first
        #expect(repo?.components.first?.label == "Go")
        #expect(repo?.vulnerabilities.isEmpty == true)
        #expect(repo?.vulnerabilityError?.isEmpty == false)
    }

    @Test func oldReportWithoutVulnerabilitiesDecodes() throws {
        let json = #"{"accountId":"00000000-0000-0000-0000-000000000001","repo":"acme/a","components":[]}"#
        let repo = try JSONDecoder().decode(RepoVersions.self, from: Data(json.utf8))
        #expect(repo.vulnerabilities.isEmpty)
        #expect(repo.vulnerabilityError == nil)
    }
}

@Suite struct LockedFrameworkVersionTests {
    @Test func lockfileVersionWinsOverManifestMinimum() async {
        let http = MockHTTPClient()
        http.on("products/symfony", body: #"{"result":{"releases":[{"name":"7.4","releaseDate":"2025-11-01","isEol":false,"latest":{"name":"7.4.9"}},{"name":"7.2","releaseDate":"2024-11-01","isEol":true,"latest":{"name":"7.2.9"}}]}}"#)
        http.on("querybatch", body: #"{"results":[{}]}"#)
        let provider = FileProvider(repos: ["p/api"], files: ["p/api": [
            "composer.json": #"{"require":{"symfony/console":"^7.2"}}"#,
            "composer.lock": #"{"packages":[{"name":"symfony/console","version":"v7.4.8"}]}"#,
        ]])
        let account = Account(kind: .azureDevOps, displayName: "x", organization: "x", authMethod: .pat, repoWatch: ["p/api": .prs])

        let report = await VersionChecker(makeProvider: { _ in provider }, http: http, now: { Date(timeIntervalSince1970: 1_792_000_000) })
            .run(accounts: [account])

        let symfony = report.repos.first?.components.first
        #expect(symfony?.version == "7.4.8")
        #expect(symfony?.status == .current)
        #expect(symfony?.sources == ["composer.lock"])
    }
}

@Suite struct RustPinnedVersionTests {
    @Test func toolchainWinsOverCargoMinimum() async {
        let http = MockHTTPClient()
        http.on("products/rust", body: #"{"result":{"releases":[{"name":"1.99","releaseDate":"2026-09-01","isEol":false,"latest":{"name":"1.99.1"}}]}}"#)
        let provider = FileProvider(repos: ["f/ehr"], files: ["f/ehr": [
            "Cargo.toml": "[workspace.package]\nrust-version = \"1.98\"\n",
            "rust-toolchain.toml": "[toolchain]\nchannel = \"1.99.1\"\n",
        ]])
        let account = Account(kind: .gitHub, displayName: "f", organization: "f", authMethod: .pat, repoWatch: ["f/ehr": .prs])

        let report = await VersionChecker(makeProvider: { _ in provider }, http: http, now: { Date(timeIntervalSince1970: 1_792_000_000) })
            .run(accounts: [account])

        let rust = report.repos.first?.components.first
        #expect(rust?.version == "1.99.1")
        #expect(rust?.sources == ["rust-toolchain.toml"])
    }
}

@Suite struct PinnedOverMinimumTests {
    let now = Date(timeIntervalSince1970: 1_792_000_000)

    func run(_ files: [String: String]) async -> [ComponentVersion] {
        let provider = FileProvider(repos: ["t/go-tool"], files: ["t/go-tool": files])
        let account = Account(kind: .azureDevOps, displayName: "t", organization: "t", authMethod: .pat, repoWatch: ["t/go-tool": .prs])
        let report = await VersionChecker(makeProvider: { _ in provider }, http: MockHTTPClient(), now: { now }).run(accounts: [account])
        return report.repos.first?.components ?? []
    }

    @Test func locallyReplacedGoModuleDoesNotCount() async {
        let components = await run([
            "backend/go.mod": "module app\n\ngo 1.27.2\n\nreplace github.com/x/bot => ./internal/bot\n",
            "backend/internal/bot/go.mod": "module github.com/x/bot\n\ngo 1.21\n",
            "tools/go.mod": "module tools\n\ngo 1.26\n",
        ])
        let go = components.first { $0.label == "Go" }
        #expect(go?.version == "1.26")
        #expect(go?.sources == ["backend/go.mod", "tools/go.mod"])
    }

    @Test func nodeEngineMinimumDropsWhenDockerPinsNode() async {
        let components = await run([
            "teams-app/package.json": #"{"engines":{"node":">=20.0.0"}}"#,
            "docker/Dockerfile.frontend": "FROM node:24-alpine\n",
        ])
        #expect(components.map(\.label) == ["Docker node"])
    }

    @Test func minimumStaysWithoutPin() async {
        let components = await run(["package.json": #"{"engines":{"node":">=20.0.0"}}"#])
        #expect(components.map { "\($0.label)@\($0.version)" } == ["Node@20.0.0"])
    }

    @Test func resolvesRelativeReplacePaths() {
        #expect(StackDetector.localGoReplacements(path: "backend/go.mod", content: "replace a => ./internal/a\nreplace (\n  b v1 => ../shared/b\n  c => github.com/c v1.0.0\n)\n")
            == ["backend/internal/a", "shared/b"])
    }
}

@Suite struct SingleRepoRefreshTests {
    let now = Date(timeIntervalSince1970: 1_792_000_000)

    @Test func checksOneRepoAndReplacesItKeepingCheckedAt() async {
        let http = MockHTTPClient()
        http.on("products/go", body: #"{"result":{"releases":[{"name":"1.27","releaseDate":"2026-08-19","isEol":false,"latest":{"name":"1.27.3"}}]}}"#)
        let provider = FileProvider(repos: nil, files: ["a/one": ["go.mod": "go 1.27.2"]])
        let account = Account(kind: .gitHub, displayName: "a", organization: "a", authMethod: .pat, repoWatch: ["a/one": .prs])

        let fresh = await VersionChecker(makeProvider: { _ in provider }, http: http, now: { now }).run(account: account, repo: "a/one")

        #expect(fresh.components.first?.status == .current)
        let old = VersionReport(checkedAt: Date(timeIntervalSince1970: 1), repos: [
            RepoVersions(accountId: account.id, repo: "a/one", components: [], error: "Netwerkfout"),
            RepoVersions(accountId: account.id, repo: "a/two", components: []),
        ])
        let updated = old.replacing(fresh)
        #expect(updated.checkedAt == old.checkedAt)
        #expect(updated.repos.first { $0.repo == "a/one" }?.error == nil)
        #expect(updated.repos.count == 2)
    }
}

@Suite struct LatestReleaseTests {
    let now = Date(timeIntervalSince1970: 1_792_000_000)

    @Test func picksHighestFinalVersionTag() {
        #expect(VersionChecker.latestTag(["v1.9.0", "v1.10.0", "v2.0.0-rc1", "nightly", "release-1.2"]) == "v1.10.0")
        #expect(VersionChecker.latestTag(["v2.0.0-rc1", "v2.0.0-rc2"]) == "v2.0.0-rc2")
        #expect(VersionChecker.latestTag(["nightly"]) == nil)
        #expect(VersionChecker.latestTag([]) == nil)
    }

    @Test func fixedOnMainIsNotReported() async {
        let http = MockHTTPClient()
        http.on("products/go", body: #"{"result":{"releases":[{"name":"1.27","releaseDate":"2026-08-19","isEol":false,"latest":{"name":"1.27.3"}},{"name":"1.26","releaseDate":"2026-02-10","isEol":true,"latest":{"name":"1.26.10"}}]}}"#)
        // Alleen de release heeft het (kwetsbare) pakket nog.
        http.on("querybatch", body: #"{"results":[{"vulns":[{"id":"GO-1"}]}]}"#)
        http.on("vulns/GO-1", body: #"{"id":"GO-1","affected":[{"package":{"name":"x.com/y","ecosystem":"Go"},"ranges":[{"events":[{"fixed":"1.1.0"}]}]}]}"#)
        let provider = FileProvider(
            repos: ["a/one"],
            files: [
                "a/one": ["go.mod": "go 1.27.2\n"],
                "a/one@v1.0.0": ["go.mod": "go 1.26\nrequire x.com/y v1.0.0\n"],
            ],
            tags: ["a/one": ["v0.9.0", "v1.0.0"]]
        )
        let account = Account(kind: .gitHub, displayName: "a", organization: "a", authMethod: .pat, repoWatch: ["a/one": .prs])

        let repo = await VersionChecker(makeProvider: { _ in provider }, http: http, now: { now }).run(account: account, repo: "a/one")

        #expect(repo.components.first?.status == .current)
        #expect(repo.release?.tag == "v1.0.0")
        #expect(repo.release?.components.first?.version == "1.26")
        #expect(repo.release?.components.first?.status == .eol)
        #expect(repo.release?.vulnerabilities.first?.fixedIn == "1.1.0")
        // Op main opgelost: telt niet mee.
        #expect(repo.worstStatus == .current)
        #expect(repo.vulnerabilities.isEmpty)
        #expect(repo.severity == VersionStatus.current.severity)
    }

    @Test func noTagsMeansNoRelease() async {
        let provider = FileProvider(repos: ["a/one"], files: ["a/one": [:]])
        let account = Account(kind: .gitHub, displayName: "a", organization: "a", authMethod: .pat, repoWatch: ["a/one": .prs])

        let repo = await VersionChecker(makeProvider: { _ in provider }, http: MockHTTPClient(), now: { now }).run(account: account, repo: "a/one")

        #expect(repo.release == nil)
    }

    @Test func releaseOnlyVulnerabilityIsNotNotified() {
        let id = UUID()
        func vuln(_ v: String) -> Vulnerability {
            Vulnerability(id: "GO-1", cve: nil, summary: nil, severity: nil, ecosystem: "Go", package: "x", version: v, fixedIn: nil, source: "go.mod")
        }
        let before = VersionReport(checkedAt: now, repos: [RepoVersions(accountId: id, repo: "a/one", components: [])])
        let after = VersionReport(checkedAt: now, repos: [RepoVersions(
            accountId: id, repo: "a/one", components: [],
            release: ReleaseVersions(tag: "v1", components: [], vulnerabilities: [vuln("1.0.0")])
        )])
        #expect(after.newVulnerabilities(since: before).isEmpty)
        #expect(after.repos[0].isInRelease(vuln("1.0.0")) == true)
    }
}
