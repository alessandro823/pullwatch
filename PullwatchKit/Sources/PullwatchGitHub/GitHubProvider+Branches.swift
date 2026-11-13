import CryptoKit
public import Foundation
public import PullwatchCore

private let logger = Log(category: "github")

// MARK: - Branches

/// De branches van de gevolgde repo's, zoals `+Tags` de tags leest: via GraphQL met aliassen
/// voor meerdere repo's per verzoek, eerst een kleine vraag voor repo's met een bekende
/// vingerafdruk en alleen voor wat veranderde de volle vraag. Elke gevraagde repo komt in precies
/// één uitkomst: gelezen (een vingerafdruk, ook zonder branches), `unavailableRepos` of
/// `unchangedRepos`. Losse repo's die alleen zonder token te lezen zijn, en een server die de
/// GraphQL-vraag niet kent, gaan via REST.
extension GitHubProvider {
    /// Repo's per GraphQL-verzoek voor de volle vraag (honderd branches elk).
    static let branchBatchSize = 10
    /// Branches per pagina, in GraphQL en REST.
    static let branchPageSize = 100
    /// Hooguit zoveel pagina's per repo (vijfduizend branches); daarna telt wat er is.
    static let branchMaxPages = 50

    public func branches(in repos: [String], unchanged known: [String: String]) async throws -> BranchFetch {
        if branchesViaREST { return try await restBranches(in: repos) }
        do {
            return try await graphQLBranches(in: repos, unchanged: known)
        } catch is GraphQLSchemaMismatch {
            branchesViaREST = true
            return try await restBranches(in: repos)
        }
    }

    /// Hoeveel commits `to` voor en achter ligt op `from`. Een onbekende commit (404, bv. na een
    /// force-push die GitHub al opruimde) geeft nil.
    public func compare(in repo: String, from: String, to: String) async throws -> BranchComparison? {
        let url = apiBase.appending(path: "repos").appending(path: repo)
            .appending(path: "compare").appending(path: "\(from)...\(to)")
        do {
            // Eén commit per pagina: alleen de tellingen zijn nodig, niet de lijst.
            let data = try await repoData(repo, url, query: [URLQueryItem(name: "per_page", value: "1")])
            let dto = try JSONDecoding.decode(CompareDTO.self, from: data, snakeCase: true)
            return BranchComparison(ahead: dto.aheadBy, behind: dto.behindBy)
        } catch ProviderError.server(status: 404) {
            return nil
        }
    }

    nonisolated public func compareURL(in repo: String, from: String, to: String) -> URL? {
        URL(string: "\(endpoints.web.absoluteString)/\(repo)/compare/\(from)...\(to)")
    }

    /// De bestanden op deze branch. Elk segment van de naam apart gecodeerd: de "/" blijft een
    /// "/" (GitHub leest `tree/feature/x` als branch `feature/x`), de rest wordt %-gecodeerd.
    func branchTreeURL(repo: String, branch: String) -> URL? {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        var segments: [String] = []
        for segment in branch.split(separator: "/", omittingEmptySubsequences: false) {
            guard let encoded = segment.addingPercentEncoding(withAllowedCharacters: allowed) else { return nil }
            segments.append(encoded)
        }
        return URL(string: "\(endpoints.web.absoluteString)/\(repo)/tree/\(segments.joined(separator: "/"))")
    }

    // MARK: - GraphQL

    private func graphQLBranches(in repos: [String], unchanged known: [String: String]) async throws -> BranchFetch {
        var fetch = BranchFetch()
        // Losse repo's die alleen zonder token te lezen zijn gaan via REST (GraphQL vraagt altijd
        // een token); de rest gaat samen via GraphQL.
        let (signed, unsigned, unavailable) = try await splitByAccess(repos)
        fetch.unavailableRepos += unavailable
        for repo in unsigned { try await restBranches(repo, into: &fetch) }
        var changed = signed.filter { known[$0] == nil }
        let checked = signed.filter { known[$0] != nil }
        for batch in checked.chunked(Self.fingerprintBatchSize) {
            let nodes = try await branchQuery(batch.map { ($0, nil) }, full: false, fetch: &fetch)
            for repo in batch {
                guard let node = nodes[repo] else { continue }
                // De vingerafdruk ziet alleen de eerste pagina: een repo met meer branches wordt
                // altijd helemaal gelezen, anders bleef een push voorbij branch honderd onopgemerkt.
                if node.refs.totalCount <= node.refs.nodes.count, node.fingerprint == known[repo] {
                    fetch.unchangedRepos.append(repo)
                } else {
                    changed.append(repo)
                }
            }
        }
        for batch in changed.chunked(Self.branchBatchSize) {
            let nodes = try await branchQuery(batch.map { ($0, nil) }, full: true, fetch: &fetch)
            for repo in batch {
                guard let node = nodes[repo] else { continue }
                guard let rest = try await laterPages(of: repo, after: node, fetch: &fetch) else { continue }
                fetch.fingerprints[repo] = node.fingerprint
                if let name = node.defaultBranchRef?.name { fetch.defaultBranches[repo] = name }
                fetch.heads += makeHeads(repo: repo, node.refs.nodes + rest)
            }
        }
        // Een losse repo die GraphQL niet gaf: nog één keer via REST, met token en anders zonder.
        for repo in fetch.unavailableRepos where isExtra(repo) && signed.contains(repo) {
            fetch.unavailableRepos.removeAll { $0 == repo }
            try await restBranches(repo, into: &fetch)
        }
        return fetch
    }

    /// De branches op de pagina's na de eerste, tot `hasNextPage` false is. nil als de repo
    /// onderweg niet meer te lezen is: hij staat dan in `fetch.unavailableRepos`.
    private func laterPages(
        of repo: String,
        after first: BranchQuery.Repository,
        fetch: inout BranchFetch
    ) async throws -> [BranchQuery.Ref]? {
        var refs: [BranchQuery.Ref] = []
        var page = first
        var pages = 1
        while pages < Self.branchMaxPages, let info = page.refs.pageInfo, info.hasNextPage, let cursor = info.endCursor {
            guard let next = try await branchQuery([(repo, cursor)], full: true, fetch: &fetch)[repo] else { return nil }
            refs += next.refs.nodes
            // Dezelfde cursor nog eens zou rond blijven gaan.
            if next.refs.pageInfo?.endCursor == cursor { break }
            page = next
            pages += 1
        }
        if pages == Self.branchMaxPages, page.refs.pageInfo?.hasNextPage == true { logger.notice("branches van \(repo) na \(pages) pagina's afgebroken") }
        return refs
    }

    /// Eén GraphQL-verzoek voor `items` (repo met eventueel de cursor van zijn volgende pagina);
    /// geeft per gevonden repo zijn branches. Wat niet gevonden wordt of geen toegang geeft komt
    /// in `fetch.unavailableRepos`. `full: false` is de kleine vraag: alleen naam en sha.
    private func branchQuery(
        _ items: [(repo: String, cursor: String?)],
        full: Bool,
        fetch: inout BranchFetch
    ) async throws -> [String: BranchQuery.Repository] {
        var variables: [String: String] = [:]
        var valid: [(alias: String, repo: String)] = []
        for (repo, cursor) in items {
            let parts = repo.split(separator: "/", maxSplits: 1).map(String.init)
            guard parts.count == 2 else {
                fetch.unavailableRepos.append(repo)
                continue
            }
            let index = valid.count
            variables["o\(index)"] = parts[0]
            variables["n\(index)"] = parts[1]
            if let cursor { variables["c\(index)"] = cursor }
            valid.append(("r\(index)", repo))
        }
        guard !valid.isEmpty else { return [:] }
        let request = BranchQuery(query: BranchQuery.text(count: valid.count, full: full), variables: variables)
        let response: BranchQuery.Response
        let headers: HTTPURLResponse
        do {
            let (body, http) = try await send(endpoints.graphQL, body: try JSONEncoder().encode(request))
            response = try JSONDecoding.decode(BranchQuery.Response.self, from: body)
            headers = http
        } catch ProviderError.unauthorized {
            fetch.unavailableRepos += valid.map(\.repo) // geen toegang (403: SSO, rechten, IP-allowlist)
            return [:]
        }
        // GraphQL meldt een opgebruikte limiet met status 200 en een fout van het type RATE_LIMITED.
        if response.errors?.contains(where: { $0.type == "RATE_LIMITED" }) == true {
            let reset = headers.value(forHTTPHeaderField: "X-RateLimit-Reset").flatMap(Double.init)
            throw ProviderError.rateLimited(until: reset.map(Date.init(timeIntervalSince1970:)) ?? now() + 60)
        }
        guard let payload = response.data else {
            if GraphQLSchemaMismatch.matches(response.errors) { throw GraphQLSchemaMismatch() }
            throw ProviderError.decoding(response.errors?.first?.message.map { "GraphQL: \($0)" }
                ?? String(localized: "GraphQL-antwoord zonder gegevens", bundle: .localizedGitHub))
        }
        var result: [String: BranchQuery.Repository] = [:]
        for (alias, repo) in valid {
            if let node = payload[alias] ?? nil {
                result[repo] = node
            } else {
                fetch.unavailableRepos.append(repo) // bestaat niet (meer) of geen toegang
            }
        }
        return result
    }

    /// De heads van één repo. De auteur is de GitHub-login als de commit aan een account hangt,
    /// anders de naam uit git; `authorId` alleen met een login (`currentUserId()` is de login).
    private func makeHeads(repo: String, _ refs: [BranchQuery.Ref]) -> [BranchHead] {
        refs.compactMap { ref in
            guard let target = ref.target, let webURL = branchTreeURL(repo: repo, branch: ref.name) else { return nil }
            let author = target.author
            return BranchHead(
                repo: repo,
                name: ref.name,
                sha: target.oid,
                committedAt: target.committedDate.flatMap(DateParsing.parse),
                authorName: author?.user?.login ?? author?.name.flatMap { $0.isEmpty ? nil : $0 },
                authorId: author?.user?.login,
                authorEmail: author?.email.flatMap { $0.isEmpty ? nil : $0 },
                authorAvatarURL: author?.user?.avatarUrl.flatMap(URL.init(string:)),
                webURL: webURL
            )
        }
    }

    /// Een vingerafdruk van een branchlijst: de hash van de op naam gesorteerde `naam:sha`-paren
    /// en het totaal. Verandert bij een push, een nieuwe en een verwijderde branch.
    static func branchFingerprint(_ pairs: [(name: String, sha: String)], total: Int, prefix: String = "") -> String {
        let text = pairs.sorted { $0.name < $1.name }.map { "\($0.name):\($0.sha)" }.joined(separator: "\n") + "\n\(total)"
        let digest = SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
        return prefix + digest
    }

    // MARK: - REST

    /// Branches via REST voor alle repo's, voor een GitHub Enterprise Server waarvan de
    /// GraphQL-API de vraag niet kent. REST geeft per branch alleen naam en sha.
    private func restBranches(in repos: [String]) async throws -> BranchFetch {
        var fetch = BranchFetch()
        for repo in repos {
            guard repo.split(separator: "/").count == 2 else {
                fetch.unavailableRepos.append(repo)
                continue
            }
            try await restBranches(repo, into: &fetch)
        }
        return fetch
    }

    /// Alle branches van één repo via `GET /repos/{repo}/branches`, pagina na pagina via de
    /// `next`-link (alleen op de API van het account: `PageLink.follow`); met het token als dat
    /// mag en anders zonder. Wat niet lukt komt in `unavailableRepos`. Een rate limit van het
    /// account gaat door; die zonder token niet (de repo wacht dan tot de limiet terug is).
    private func restBranches(_ repo: String, into fetch: inout BranchFetch) async throws {
        var branches: [BranchDTO] = []
        do {
            var next: URL? = apiBase.appending(path: "repos").appending(path: repo).appending(path: "branches")
            var query = [URLQueryItem(name: "per_page", value: String(Self.branchPageSize))]
            var pages = 0
            while let url = next, pages < Self.branchMaxPages {
                let (data, response) = try await repoResponse(repo, url, query: query)
                branches += try JSONDecoding.decode([BranchDTO].self, from: data, snakeCase: true)
                next = PageLink.follow(PageLink.next(in: response), after: url, api: apiBase)
                query = [] // de next-link heeft zijn eigen query
                pages += 1
            }
        } catch ProviderError.rateLimited(let until) where !readsWithoutToken(repo) {
            throw ProviderError.rateLimited(until: until)
        } catch {
            logger.notice("branches van \(repo) overgeslagen: \(error.localizedDescription)")
            fetch.unavailableRepos.append(repo)
            return
        }
        fetch.fingerprints[repo] = Self.branchFingerprint(
            branches.map { ($0.name, $0.commit.sha) }, total: branches.count, prefix: "rest:")
        fetch.heads += branches.compactMap { branch in
            branchTreeURL(repo: repo, branch: branch.name).map {
                BranchHead(repo: repo, name: branch.name, sha: branch.commit.sha, webURL: $0)
            }
        }
    }
}

/// GraphQL: per repo (alias `r0`, `r1`, …; variabelen `o0`/`n0` voor eigenaar en naam, `c0`
/// voor de cursor van een volgende pagina) de branches met hun laatste commit en auteur, en in de
/// volle vraag de standaardbranch.
private struct BranchQuery: Encodable {
    let query: String
    let variables: [String: String]

    /// `full: false` is de kleine vraag voor de vingerafdruk: totaal, naam en sha.
    static func text(count: Int, full: Bool) -> String {
        let declarations = (0..<count)
            .map { full ? "$o\($0): String!, $n\($0): String!, $c\($0): String" : "$o\($0): String!, $n\($0): String!" }
            .joined(separator: ", ")
        let fields = (0..<count).map { index in
            let after = full ? ", after: $c\(index)" : ""
            let defaultRef = full ? "defaultBranchRef { name } " : ""
            return "  r\(index): repository(owner: $o\(index), name: $n\(index)) { \(defaultRef)refs(refPrefix: \"refs/heads/\", first: \(GitHubProvider.branchPageSize)\(after)) { ...\(full ? "Heads" : "HeadShas") } }"
        }.joined(separator: "\n")
        let fragment = full
            ? """
            fragment Heads on RefConnection {
              totalCount
              pageInfo { hasNextPage endCursor }
              nodes { name target { oid ... on Commit { committedDate author { name email user { login avatarUrl } } } } }
            }
            """
            : """
            fragment HeadShas on RefConnection { totalCount nodes { name target { oid } } }
            """
        return """
            query(\(declarations)) {
            \(fields)
            }
            \(fragment)
            """
    }

    struct Response: Decodable {
        let data: [String: Repository?]?
        let errors: [GraphQLError]?
    }

    struct Repository: Decodable {
        struct Refs: Decodable {
            struct PageInfo: Decodable {
                let hasNextPage: Bool
                let endCursor: String?
            }

            let totalCount: Int
            /// Alleen in de volle vraag.
            let pageInfo: PageInfo?
            let nodes: [Ref]
        }

        struct DefaultRef: Decodable {
            let name: String
        }

        let refs: Refs
        /// Alleen in de volle vraag; nil in een lege repo.
        let defaultBranchRef: DefaultRef?

        /// Over de eerste pagina: in de kleine en de volle vraag dezelfde.
        var fingerprint: String {
            GitHubProvider.branchFingerprint(
                refs.nodes.compactMap { ref in ref.target.map { (ref.name, $0.oid) } }, total: refs.totalCount)
        }
    }

    struct Ref: Decodable {
        let name: String
        let target: Target?
    }

    /// De commit van de branch; datum en auteur alleen in de volle vraag.
    struct Target: Decodable {
        struct Author: Decodable {
            struct User: Decodable {
                let login: String
                let avatarUrl: String?
            }

            let name: String?
            let email: String?
            let user: User?
        }

        let oid: String
        let committedDate: String?
        let author: Author?
    }
}
