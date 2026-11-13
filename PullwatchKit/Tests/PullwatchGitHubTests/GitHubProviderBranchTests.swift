import Foundation
import Testing
@testable import PullwatchCore
@testable import PullwatchGitHub
import PullwatchTestSupport

/// Branches van GitHub: de heads via GraphQL (met aliassen, vingerafdrukken en bladeren), REST
/// voor wat GraphQL niet kan, de vergelijking van twee commits en de adressen van de webpagina's.
@Suite struct GitHubProviderBranchTests {
    // MARK: - Hulp

    /// Eén branch in een GraphQL-antwoord, met de commit en zijn auteur.
    func head(
        _ name: String, oid: String, date: String = "2026-11-10T09:00:00Z",
        gitName: String = "Jan Jansen", email: String = "jan@example.com",
        login: String? = "jan", avatar: String? = "https://avatars.githubusercontent.com/u/1?v=4"
    ) -> String {
        let user = login.map { login in
            #"{"login":"\#(login)","avatarUrl":\#(avatar.map { #""\#($0)""# } ?? "null")}"#
        } ?? "null"
        return #"{"name":"\#(name)","target":{"oid":"\#(oid)","committedDate":"\#(date)","#
            + #""author":{"name":"\#(gitName)","email":"\#(email)","user":\#(user)}}}"#
    }

    /// Eén repo in een GraphQL-antwoord voor de branches.
    func repoJSON(_ heads: [String], total: Int? = nil, next: String? = nil, defaultBranch: String? = nil) -> String {
        let pageInfo = #"{"hasNextPage":\#(next != nil),"endCursor":\#(next.map { #""\#($0)""# } ?? "null")}"#
        let defaultRef = defaultBranch.map { #""defaultBranchRef":{"name":"\#($0)"},"# } ?? ""
        return #"{\#(defaultRef)"refs":{"totalCount":\#(total ?? heads.count),"pageInfo":\#(pageInfo),"nodes":[\#(heads.joined(separator: ","))]}}"#
    }

    func graphQL(_ repos: [String?]) -> String {
        let fields = repos.enumerated().map { #""r\#($0.offset)":\#($0.element ?? "null")"# }
        return #"{"data":{\#(fields.joined(separator: ","))}}"#
    }

    func body(_ request: URLRequest?) -> [String: Any]? {
        request?.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
    }

    static let ghe = URL(string: "https://acme.ghe.com")!

    func makeProvider(_ http: MockHTTPClient, instance: URL? = nil, extras: [String] = []) -> GitHubProvider {
        GitHubProvider(
            accountId: fixedAccountId, owners: ["acme"], extraRepos: extras, instanceURL: instance,
            tokenSource: StaticTokenSource(token: "ghtok"), http: http, now: { Date(timeIntervalSince1970: 1_800_000_000) }
        )
    }

    // MARK: - Heads

    @Test func headsCarryTheCommitAndItsAuthor() async throws {
        let http = MockHTTPClient()
        http.on("api.github.com/graphql", body: graphQL([repoJSON([
            head("main", oid: "aaa111"),
            head("feature/x", oid: "bbb222", gitName: "Piet", email: "piet@example.com", login: nil),
        ])]))

        let fetch = try await makeProvider(http).branches(in: ["acme/api"], unchanged: [:])

        #expect(fetch.heads.count == 2)
        let main = try #require(fetch.heads.first { $0.name == "main" })
        #expect(main.repo == "acme/api")
        #expect(main.sha == "aaa111")
        #expect(main.committedAt == DateParsing.parse("2026-11-10T09:00:00Z"))
        #expect(main.authorId == "jan")
        #expect(main.authorName == "jan", "de login als die er is")
        #expect(main.authorEmail == "jan@example.com")
        #expect(main.authorAvatarURL?.absoluteString == "https://avatars.githubusercontent.com/u/1?v=4")
        #expect(main.webURL.absoluteString == "https://github.com/acme/api/tree/main")
        let feature = try #require(fetch.heads.first { $0.name == "feature/x" })
        #expect(feature.authorId == nil, "een commit zonder GitHub-account")
        #expect(feature.authorName == "Piet")
        #expect(feature.authorEmail == "piet@example.com")
        #expect(fetch.fingerprints["acme/api"] != nil)
        #expect(fetch.unavailableRepos.isEmpty && fetch.unchangedRepos.isEmpty)
    }

    @Test func `The full query reads the default branch`() async throws {
        let http = MockHTTPClient()
        http.on("api.github.com/graphql", body: graphQL([repoJSON([head("develop", oid: "a")], defaultBranch: "develop")]))

        let fetch = try await makeProvider(http).branches(in: ["acme/api"], unchanged: [:])

        #expect(fetch.defaultBranches == ["acme/api": "develop"])
        let query = try #require(body(http.requests.first)?["query"] as? String)
        #expect(query.contains("defaultBranchRef { name }"))
    }

    @Test func requestAsksForBranchesOfEveryRepoWithAliases() async throws {
        let http = MockHTTPClient()
        http.on("api.github.com/graphql", body: graphQL([repoJSON([head("main", oid: "a")]), repoJSON([head("main", oid: "b")])]))

        let fetch = try await makeProvider(http).branches(in: ["acme/api", "jane/web"], unchanged: [:])

        #expect(fetch.heads.map(\.repo) == ["acme/api", "jane/web"])
        #expect(http.requests.count == 1)
        let request = try #require(http.requests.first)
        #expect(request.httpMethod == "POST")
        let variables = try #require(body(request)?["variables"] as? [String: String])
        #expect(variables == ["o0": "acme", "n0": "api", "o1": "jane", "n1": "web"])
        let query = try #require(body(request)?["query"] as? String)
        for field in ["r0: repository(owner: $o0, name: $n0)", "r1: repository(owner: $o1, name: $n1)",
                      #"refPrefix: "refs/heads/""#, "first: 100", "pageInfo", "endCursor", "oid", "committedDate", "email", "login"] {
            #expect(query.contains(field), "\(field)")
        }
    }

    @Test func manyReposAreSplitIntoBatchesOfTen() async throws {
        let http = MockHTTPClient()
        let repos = (0..<12).map { "acme/r\($0)" }
        http.on("api.github.com/graphql", body: graphQL(Array(repeating: repoJSON([head("main", oid: "a")]), count: 10)))

        let fetch = try await makeProvider(http).branches(in: repos, unchanged: [:])

        #expect(http.requests.count == 2)
        #expect(fetch.heads.count == 12)
        #expect(Set(fetch.fingerprints.keys) == Set(repos))
    }

    /// Review Focus 1: een repo met meer dan honderd branches wordt helemaal gelezen.
    @Test func laterPagesAreFetchedThroughTheCursor() async throws {
        let http = MockHTTPClient()
        let page1 = (0..<100).map { head(String(format: "b%03d", $0), oid: "o\($0)") }
        http.on("api.github.com/graphql", bodyContains: "CURSOR-2", body: graphQL([repoJSON([head("z-last", oid: "zzz")], total: 102)]))
        http.on("api.github.com/graphql", bodyContains: "CURSOR-1", body: graphQL([repoJSON([head("b100", oid: "o100")], total: 102, next: "CURSOR-2")]))
        http.on("api.github.com/graphql", body: graphQL([repoJSON(page1, total: 102, next: "CURSOR-1")]))

        let fetch = try await makeProvider(http).branches(in: ["acme/big"], unchanged: [:])

        #expect(fetch.heads.count == 102)
        #expect(fetch.heads.contains { $0.name == "z-last" && $0.sha == "zzz" && $0.repo == "acme/big" })
        #expect(http.requests.count == 3)
        let variables = try #require(body(http.requests[1])?["variables"] as? [String: String])
        #expect(variables == ["o0": "acme", "n0": "big", "c0": "CURSOR-1"])
        #expect(fetch.fingerprints["acme/big"] != nil)
    }

    @Test func aRepoWithMoreThanOnePageIsNeverSkipped() async throws {
        // De vingerafdruk ziet alleen de eerste pagina: een push naar branch 150 zou hij missen.
        let http = MockHTTPClient()
        let page1 = (0..<100).map { head(String(format: "b%03d", $0), oid: "o\($0)") }
        http.on("api.github.com/graphql", bodyContains: "CURSOR-1", body: graphQL([repoJSON([head("b100", oid: "o100")], total: 101)]))
        http.on("api.github.com/graphql", body: graphQL([repoJSON(page1, total: 101, next: "CURSOR-1")]))
        let provider = makeProvider(http)
        let fingerprint = try #require(try await provider.branches(in: ["acme/big"], unchanged: [:]).fingerprints["acme/big"])

        let second = try await provider.branches(in: ["acme/big"], unchanged: ["acme/big": fingerprint])

        #expect(second.unchangedRepos.isEmpty)
        #expect(second.heads.count == 101)
    }

    // MARK: - Vingerafdruk

    @Test func unchangedRepoCostsOneSmallRequestAndNoHeads() async throws {
        let http = MockHTTPClient()
        http.on("api.github.com/graphql", body: graphQL([repoJSON([head("main", oid: "a"), head("dev", oid: "b")])]))
        let provider = makeProvider(http)
        let first = try await provider.branches(in: ["acme/api"], unchanged: [:])
        let fingerprint = try #require(first.fingerprints["acme/api"])

        let second = try await provider.branches(in: ["acme/api"], unchanged: ["acme/api": fingerprint])

        #expect(second.heads.isEmpty)
        #expect(second.unchangedRepos == ["acme/api"])
        #expect(second.unavailableRepos.isEmpty)
        #expect(http.requests.count == 2)
        let query = try #require(body(http.requests.last)?["query"] as? String)
        #expect(query.contains("totalCount") && !query.contains("committedDate"), "de kleine vraag")
    }

    @Test func changedRepoIsFetchedInFull() async throws {
        let http = MockHTTPClient()
        http.on("api.github.com/graphql", bodyContains: "committedDate", body: graphQL([repoJSON([head("main", oid: "new")])]))
        http.on("api.github.com/graphql", body: graphQL([repoJSON([head("main", oid: "new")])]))

        let fetch = try await makeProvider(http).branches(in: ["acme/api"], unchanged: ["acme/api": "oud"])

        #expect(http.requests.count == 2)
        #expect(fetch.unchangedRepos.isEmpty)
        #expect(fetch.heads.map(\.sha) == ["new"])
        #expect(fetch.fingerprints["acme/api"] != "oud")
    }

    @Test func fingerprintChangesWithAPushANewBranchOrADeletedBranch() async throws {
        func fingerprint(_ heads: [String]) async throws -> String? {
            let http = MockHTTPClient()
            http.on("api.github.com/graphql", body: graphQL([repoJSON(heads)]))
            return try await makeProvider(http).branches(in: ["acme/api"], unchanged: [:]).fingerprints["acme/api"]
        }
        let base = try await fingerprint([head("main", oid: "a"), head("dev", oid: "b")])
        let reordered = try await fingerprint([head("dev", oid: "b"), head("main", oid: "a")])
        let pushed = try await fingerprint([head("main", oid: "a2"), head("dev", oid: "b")])
        let added = try await fingerprint([head("main", oid: "a"), head("dev", oid: "b"), head("x", oid: "c")])
        let deleted = try await fingerprint([head("main", oid: "a")])

        #expect(base == reordered, "op naam gesorteerd")
        #expect(Set([base, pushed, added, deleted]).count == 4)
    }

    // MARK: - Uitkomst per repo

    @Test func missingRepoIsUnavailable() async throws {
        let http = MockHTTPClient()
        http.on("api.github.com/graphql", body: #"{"data":{"r0":null},"errors":[{"type":"NOT_FOUND","path":["r0"]}]}"#)

        let fetch = try await makeProvider(http).branches(in: ["acme/gone"], unchanged: [:])

        #expect(fetch.heads.isEmpty)
        #expect(fetch.unavailableRepos == ["acme/gone"])
        #expect(fetch.fingerprints.isEmpty)
    }

    @Test func forbiddenBatchIsUnavailable() async throws {
        let http = MockHTTPClient()
        http.on("api.github.com/graphql", status: 403, body: #"{"message":"Resource protected by organization SAML enforcement"}"#)

        let fetch = try await makeProvider(http).branches(in: ["acme/api", "acme/web"], unchanged: [:])

        #expect(fetch.unavailableRepos == ["acme/api", "acme/web"])
    }

    /// Elke gevraagde repo komt in precies één uitkomst: gelezen (met vingerafdruk, ook zonder
    /// branches), niet beschikbaar, of onveranderd.
    @Test func everyRepoEndsUpInExactlyOneOutcome() async throws {
        let http = MockHTTPClient()
        let sameHeads = [head("main", oid: "s1")]
        let seed = MockHTTPClient()
        seed.on("api.github.com/graphql", body: graphQL([repoJSON(sameHeads)]))
        let known = try #require(try await makeProvider(seed).branches(in: ["acme/same"], unchanged: [:]).fingerprints["acme/same"])
        // De volle vraag voor de veranderde repo's (api, empty, gone, bad), de kleine voor same.
        http.on("api.github.com/graphql", bodyContains: "committedDate", body: graphQL([
            repoJSON([head("main", oid: "a"), head("dev", oid: "b")]), repoJSON([]), nil,
        ]))
        http.on("api.github.com/graphql", body: graphQL([repoJSON(sameHeads)]))
        let repos = ["acme/api", "acme/empty", "acme/gone", "acme/same", "geen-slash"]

        let fetch = try await makeProvider(http).branches(in: repos, unchanged: ["acme/same": known])

        for repo in repos {
            let outcomes = [fetch.fingerprints[repo] != nil, fetch.unavailableRepos.contains(repo), fetch.unchangedRepos.contains(repo)]
            #expect(outcomes.filter { $0 }.count == 1, "\(repo): \(outcomes)")
        }
        #expect(fetch.fingerprints["acme/empty"] != nil, "een repo zonder branches is gelezen")
        #expect(Set(fetch.unavailableRepos) == ["acme/gone", "geen-slash"])
        #expect(fetch.unchangedRepos == ["acme/same"])
        #expect(Set(fetch.heads.map(\.repo)) == ["acme/api"])
    }

    @Test func graphQLRateLimitThrowsRateLimitedUntilReset() async throws {
        let http = MockHTTPClient()
        http.on("api.github.com/graphql", headers: ["X-RateLimit-Reset": "1900000000"], body: #"{"errors":[{"type":"RATE_LIMITED","message":"API rate limit exceeded"}]}"#)

        await #expect(throws: ProviderError.rateLimited(until: Date(timeIntervalSince1970: 1_900_000_000))) {
            _ = try await makeProvider(http).branches(in: ["acme/api"], unchanged: [:])
        }
    }

    // MARK: - REST

    @Test func olderServerReadsBranchesThroughRestWithPaging() async throws {
        let http = MockHTTPClient()
        let server = URL(string: "https://github.example.com")!
        http.on("api/graphql", body: #"{"errors":[{"message":"Field 'refs' doesn't exist on type 'Repository'","extensions":{"code":"undefinedField"}}]}"#)
        http.on("branches?per_page=100&page=2", body: #"[{"name":"dev","commit":{"sha":"d2"}}]"#)
        http.on(
            "repos/acme/api/branches", headers: ["Link": #"<https://github.example.com/api/v3/repositories/1/branches?per_page=100&page=2>; rel="next""#],
            body: #"[{"name":"main","commit":{"sha":"m1"}}]"#
        )

        let fetch = try await makeProvider(http, instance: server).branches(in: ["acme/api"], unchanged: [:])

        #expect(fetch.heads.map(\.name) == ["main", "dev"])
        #expect(fetch.heads.map(\.sha) == ["m1", "d2"])
        #expect(fetch.heads.first?.webURL.absoluteString == "https://github.example.com/acme/api/tree/main")
        #expect(fetch.fingerprints["acme/api"] != nil)
        #expect(fetch.unavailableRepos.isEmpty)
    }

    @Test func restStopsAtANextLinkToAnotherHost() async throws {
        let http = MockHTTPClient()
        http.on("api/graphql", body: #"{"errors":[{"message":"Field 'refs' doesn't exist on type 'Repository'","extensions":{"code":"undefinedField"}}]}"#)
        http.on(
            "repos/acme/api/branches", headers: ["Link": #"<https://evil.example.org/branches?page=2>; rel="next""#],
            body: #"[{"name":"main","commit":{"sha":"m1"}}]"#
        )

        let fetch = try await makeProvider(http, instance: URL(string: "https://github.example.com")!).branches(in: ["acme/api"], unchanged: [:])

        #expect(fetch.heads.map(\.name) == ["main"])
        #expect(!http.requests.contains { $0.url?.host() == "evil.example.org" })
    }

    @Test func branchesOfAPublicRepoComeFromRestWithoutToken() async throws {
        let extra = "openEHR/specifications-AM"
        let http = MockHTTPClient()
        http.on("api.github.com/repos/\(extra)/branches", authorized: false, body: #"[{"name":"master","commit":{"sha":"abc"}}]"#)
        http.on("api.github.com/repos/\(extra)", authorized: true, status: 404, body: "{}")
        http.on("api.github.com/repos/\(extra)", authorized: false, body: #"{"full_name":"\#(extra)"}"#)

        let fetch = try await makeProvider(http, extras: [extra]).branches(in: [extra], unchanged: [:])

        #expect(fetch.heads.map(\.name) == ["master"])
        #expect(fetch.heads.first?.repo == extra)
        #expect(fetch.unavailableRepos.isEmpty)
        #expect(fetch.fingerprints[extra] != nil)
        #expect(!http.requests.contains { $0.url!.path() == "/graphql" }, "GraphQL vraagt altijd een token")
    }

    @Test func anonymousRateLimitMakesThePublicRepoUnavailable() async throws {
        let extra = "openEHR/specifications-AM"
        let http = MockHTTPClient()
        http.on("api.github.com/repos/\(extra)/branches", authorized: false, status: 403,
                headers: ["X-RateLimit-Remaining": "0", "X-RateLimit-Reset": "1800003600"], body: "{}")
        http.on("api.github.com/repos/\(extra)", authorized: true, status: 404, body: "{}")
        http.on("api.github.com/repos/\(extra)", authorized: false, body: #"{"full_name":"\#(extra)"}"#)

        let fetch = try await makeProvider(http, extras: [extra]).branches(in: [extra], unchanged: [:])

        #expect(fetch.unavailableRepos == [extra])
        #expect(fetch.heads.isEmpty)
    }

    // MARK: - Vergelijken

    @Test func compareReadsAheadAndBehind() async throws {
        let http = MockHTTPClient()
        http.on("repos/acme/api/compare/aaa...bbb", body: #"{"status":"diverged","ahead_by":3,"behind_by":1,"total_commits":3}"#)

        let comparison = try await makeProvider(http).compare(in: "acme/api", from: "aaa", to: "bbb")

        #expect(comparison == BranchComparison(ahead: 3, behind: 1))
        #expect(http.requests.first?.url?.host() == "api.github.com")
    }

    @Test func compareOfAnUnknownCommitIsNil() async throws {
        let http = MockHTTPClient()
        http.on("compare/", status: 404, body: #"{"message":"Not Found"}"#)

        #expect(try await makeProvider(http).compare(in: "acme/api", from: "gone", to: "bbb") == nil)
    }

    @Test func compareFailureOtherThanNotFoundThrows() async throws {
        let http = MockHTTPClient()
        http.on("compare/", status: 500, body: "{}")

        await #expect(throws: ProviderError.self) {
            _ = try await makeProvider(http).compare(in: "acme/api", from: "a", to: "b")
        }
    }

    // MARK: - Adressen

    /// Review Focus 2: elk segment van de branchnaam apart gecodeerd.
    @Test func webURLEncodesEveryPathSegment() async throws {
        let http = MockHTTPClient()
        http.on("api.github.com/graphql", body: graphQL([repoJSON([head("feature/ä b#1", oid: "a")])]))

        let fetch = try await makeProvider(http).branches(in: ["o/r"], unchanged: [:])

        #expect(fetch.heads.first?.webURL.absoluteString == "https://github.com/o/r/tree/feature/%C3%A4%20b%231")
    }

    @Test func compareURLUsesTheWebHostOfTheAccount() {
        let dotCom = makeProvider(MockHTTPClient())
        let ghe = makeProvider(MockHTTPClient(), instance: Self.ghe)

        #expect(dotCom.compareURL(in: "acme/api", from: "aaa", to: "bbb")?.absoluteString == "https://github.com/acme/api/compare/aaa...bbb")
        #expect(ghe.compareURL(in: "acme/api", from: "aaa", to: "bbb")?.absoluteString == "https://acme.ghe.com/acme/api/compare/aaa...bbb")
    }

    @Test func headsOnGHEUseTheOwnHosts() async throws {
        let http = MockHTTPClient()
        http.on("api.acme.ghe.com/graphql", body: graphQL([repoJSON([head("main", oid: "a")])]))
        http.on("api.acme.ghe.com/repos/acme/api/compare", body: #"{"ahead_by":1,"behind_by":0}"#)
        let provider = makeProvider(http, instance: Self.ghe)

        let fetch = try await provider.branches(in: ["acme/api"], unchanged: [:])
        let comparison = try await provider.compare(in: "acme/api", from: "a", to: "b")

        #expect(fetch.heads.first?.webURL.absoluteString == "https://acme.ghe.com/acme/api/tree/main")
        #expect(comparison == BranchComparison(ahead: 1, behind: 0))
        #expect(Set(http.requests.compactMap { $0.url?.host() }) == ["api.acme.ghe.com"])
    }

    // MARK: - Bronnen

    /// Elke host waar de branches en de vergelijking heen gaan staat in het overzicht van bronnen.
    @Test func everyBranchHostIsInTheOverview() async throws {
        let http = MockHTTPClient()
        http.on("graphql", body: graphQL([repoJSON([head("main", oid: "a")])]))
        http.on("compare/", body: #"{"ahead_by":1,"behind_by":0}"#)
        let accounts = [
            Account(kind: .gitHub, organization: "acme", authMethod: .pat),
            Account(kind: .gitHub, organization: "acme", authMethod: .pat, instanceURL: Self.ghe),
        ]
        for account in accounts {
            let provider = makeProvider(http, instance: account.effectiveInstanceURL)
            _ = try await provider.branches(in: ["acme/api"], unchanged: [:])
            _ = try await provider.compare(in: "acme/api", from: "a", to: "b")
        }

        let called = Set(http.requests.compactMap { $0.url?.host() })
        let listed = Set(DataSource.all.flatMap(\.endpoints).compactMap { $0.host() })
            .union(SourcesOverview.otherConnections(config: AppConfig(accounts: accounts, checkForUpdates: false)).flatMap(\.urls).compactMap { $0.host() })
        expectCalledHostsAreListed(called: called, expected: ["api.github.com", "api.acme.ghe.com"], listed: listed)
    }
}
