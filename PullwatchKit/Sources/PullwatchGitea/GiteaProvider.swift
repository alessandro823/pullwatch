public import Foundation
public import PullwatchCore

/// Gitea, Forgejo en Codeberg via de API v1 (`<server>/api/v1`), die de drie delen. Eigenaren zijn
/// organisaties of gebruikers; een repo heet `eigenaar/repo` (`full_name`). Pull requests komen
/// per eigenaar in één lijst uit `/repos/issues/search?type=pulls&owner=…` (één vraag per poll,
/// hoeveel repo's de eigenaar ook heeft); een losse repo vraagt zijn eigen `/pulls`.
public actor GiteaProvider: PRProvider {
    enum Owner: Equatable {
        case organization(String)
        case user(String)

        var name: String {
            switch self {
            case .organization(let name), .user(let name): name
            }
        }
    }

    let accountId: UUID
    let owners: [String]
    let tokenSource: any TokenSource
    let http: any HTTPClient
    let now: @Sendable () -> Date
    /// De server zonder "/" aan het eind, bv. `https://codeberg.org`.
    let instanceURL: URL
    /// De naam van de dienst voor foutmeldingen ("Codeberg", "Forgejo", "Gitea").
    let serviceName: String
    /// Gitea en Codeberg geven hooguit vijftig items per pagina (`MAX_RESPONSE_ITEMS`).
    let pageSize = 50
    let maxPages = 10
    /// Een bestandsboom geeft duizend paden per pagina; zoveel pagina's hooguit.
    let maxTreePages = 100
    private var ownerCache: [String: Owner] = [:]
    /// De weergavenaam van de auteur per PR (dedupKey), zodat `coAuthors(of:)` de eigen commits
    /// van de auteur herkent.
    var authorNames: [String: String] = [:]
    /// Losse repo's (`Account.extraRepos`) buiten de gevolgde eigenaren
    /// (`GiteaProvider+ExtraRepos`).
    let extraRepos: [String]
    /// Hoe elke losse repo te lezen is, per naam lowercased.
    var repoAccess: [String: (access: RepoAccess, at: Date)] = [:]
    /// Tot wanneer de limiet voor verzoeken zonder token op is.
    var anonymousPausedUntil: Date?

    public init(
        accountId: UUID,
        owners: [String],
        extraRepos: [String] = [],
        instanceURL: URL,
        serviceName: String = "Gitea",
        tokenSource: any TokenSource,
        http: any HTTPClient,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.accountId = accountId
        self.owners = owners
            .map { $0.trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: "/@"))) }
            .filter { !$0.isEmpty }
        self.extraRepos = Account.reposOutside(owners: self.owners, extraRepos)
        var base = instanceURL.absoluteString
        while base.hasSuffix("/") { base.removeLast() }
        self.instanceURL = URL(string: base) ?? instanceURL
        self.serviceName = serviceName
        self.tokenSource = tokenSource
        self.http = http
        self.now = now
    }

    // MARK: - Gebruiker en verbinding

    public func currentUserId() async throws -> String {
        try await currentUser().login
    }

    /// Controleert het token (`/user`, scope read:user), elke eigenaar (read:organization of
    /// read:user) en de lijst van pull requests (`/repos/issues/search`, scope read:issue); geeft
    /// de gebruikersnaam. Elke fout zegt wat er mis is: een ongeldig token, een ontbrekende scope,
    /// een onbekende eigenaar, een server die geen Gitea of Forgejo is, of een certificaat dat niet
    /// deugt.
    public func testConnection() async throws -> String {
        let user = try await currentUser()
        for owner in owners {
            _ = try await resolve(owner)
        }
        let _: [IssueDTO] = try await get(endpoint("repos", "issues", "search"), query: [
            URLQueryItem(name: "type", value: "pulls"),
            URLQueryItem(name: "limit", value: "1"),
        ])
        return user.login
    }

    /// `/user`. Geeft de server geen JSON van Gitea (een webpagina, een andere dienst) of kent hij
    /// `/api/v1` niet, dan `unexpectedServer`.
    private func currentUser() async throws -> UserDTO {
        do {
            return try await get(endpoint("user"))
        } catch ProviderError.decoding, ProviderError.server(status: 404) {
            throw ProviderError.unexpectedServer(host: instanceURL.host() ?? instanceURL.absoluteString, service: serviceName)
        }
    }

    // MARK: - Repo's

    /// De repo's van alle gevolgde eigenaren, op naam; gearchiveerde niet.
    public func listRepos() async throws -> [String] {
        var names: [String] = []
        for owner in owners {
            let url = switch try await resolve(owner) {
            case .organization(let name): endpoint("orgs", name, "repos")
            case .user(let name): endpoint("users", name, "repos")
            }
            let repos: [RepositoryDTO] = try await pages(url, query: [], maxPages: maxPages * 4)
            names += repos.filter { $0.archived != true }.map(\.fullName)
        }
        names += try await extraRepoNames()
        var seen: Set<String> = []
        return names.filter { seen.insert($0.lowercased()).inserted }
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    // MARK: - Pull requests

    /// Open pull requests (ook drafts) bij alle gevolgde eigenaren, en van elke losse repo de
    /// vijftig recentst bijgewerkte.
    public func openPullRequests() async throws -> [PullRequest] {
        var result: [PullRequest] = []
        for owner in owners {
            result += try await searchPullRequests(owner: try await resolve(owner), query: [
                URLQueryItem(name: "state", value: "open"),
            ], limit: .max)
        }
        result += try await extraPullRequests(state: "open", since: nil, limit: .max)
        return result
    }

    /// Pull requests in elke status, recentst bijgewerkt eerst, samen hooguit `limit`; met `since`
    /// alleen wat sindsdien is bijgewerkt.
    public func pullRequests(updatedSince since: Date?, limit: Int) async throws -> [PullRequest] {
        var query = [URLQueryItem(name: "state", value: "all")]
        if let since {
            query.append(URLQueryItem(name: "since", value: since.formatted(Date.ISO8601FormatStyle(timeZone: .gmt))))
        }
        var result: [PullRequest] = []
        for owner in owners {
            result += try await searchPullRequests(owner: try await resolve(owner), query: query, limit: limit)
        }
        result += try await extraPullRequests(state: "all", since: since, limit: limit)
        return Array(result.sorted { ($0.closedAt ?? $0.createdAt) > ($1.closedAt ?? $1.createdAt) }.prefix(limit))
    }

    /// De pull requests van één eigenaar uit de zoekfunctie voor issues (`type=pulls`).
    private func searchPullRequests(owner: Owner, query: [URLQueryItem], limit: Int) async throws -> [PullRequest] {
        let found: [IssueDTO] = try await pages(
            endpoint("repos", "issues", "search"),
            query: [URLQueryItem(name: "type", value: "pulls"), URLQueryItem(name: "owner", value: owner.name)] + query,
            maxPages: maxPages, stop: { $0.count >= limit }
        )
        return try found.prefix(limit).map(makePullRequest)
    }

    func makePullRequest(_ dto: IssueDTO) throws -> PullRequest {
        let merged = dto.pullRequest?.merged == true
        return try makePullRequest(
            repo: dto.repository.fullName, number: dto.number, title: dto.title, user: dto.user,
            draft: dto.pullRequest?.draft, open: dto.state == "open", merged: merged,
            closedAt: merged ? (dto.pullRequest?.mergedAt ?? dto.closedAt) : dto.closedAt,
            createdAt: dto.createdAt, updatedAt: dto.updatedAt, htmlURL: dto.htmlUrl
        )
    }

    func makePullRequest(_ dto: PullRequestDTO, repo: String) throws -> PullRequest {
        let merged = dto.merged == true
        var pullRequest = try makePullRequest(
            repo: dto.base?.repo?.fullName ?? repo, number: dto.number, title: dto.title, user: dto.user,
            draft: dto.draft, open: dto.state == "open", merged: merged,
            closedAt: merged ? (dto.mergedAt ?? dto.closedAt) : dto.closedAt,
            createdAt: dto.createdAt, updatedAt: dto.updatedAt, htmlURL: dto.htmlUrl
        )
        // Alleen een PR uit dezelfde repo: een branch in een fork hoort niet in de boom.
        if dto.head?.repo?.fullName == nil || dto.head?.repo?.fullName == dto.base?.repo?.fullName {
            pullRequest.sourceBranch = dto.head?.ref
            pullRequest.targetBranch = dto.base?.ref
        }
        return pullRequest
    }

    private func makePullRequest(
        repo: String, number: Int, title: String, user: UserDTO, draft: Bool?, open: Bool, merged: Bool,
        closedAt: String?, createdAt: String, updatedAt: String?, htmlURL: String
    ) throws -> PullRequest {
        guard let created = DateParsing.parse(createdAt) else {
            throw ProviderError.decoding("created_at \(createdAt)")
        }
        guard let webURL = URL(string: htmlURL) else {
            throw ProviderError.decoding("html_url in pull request \(number)")
        }
        let state: PRState = open ? .open : (merged ? .merged : .closed)
        let pullRequest = PullRequest(
            accountId: accountId,
            repo: repo,
            number: number,
            title: title,
            authorId: user.login,
            authorName: user.login,
            authorAvatarURL: user.avatarUrl.flatMap { $0.isEmpty ? nil : URL(string: $0) },
            isDraft: draft ?? Self.hasWorkInProgressPrefix(title),
            createdAt: created,
            webURL: webURL,
            state: state,
            closedAt: state == .open ? nil : closedAt.flatMap(DateParsing.parse),
            // `updated_at` verandert bij een push, een reactie of een label; zoals bij GitHub.
            revision: updatedAt
        )
        if let name = user.fullName, !name.isEmpty { authorNames[pullRequest.dedupKey] = name }
        return pullRequest
    }

    /// Een server zonder `draft`-veld (Gitea vóór 1.22) maakt een draft met een voorvoegsel in de
    /// titel; dit zijn de standaarden van Gitea en Forgejo (`WORK_IN_PROGRESS_PREFIXES`).
    static func hasWorkInProgressPrefix(_ title: String) -> Bool {
        let lower = title.trimmingCharacters(in: .whitespaces).lowercased()
        return lower.hasPrefix("wip:") || lower.hasPrefix("[wip]")
    }

    public func invalidateCredentials() async {
        repoAccess = [:]
        await tokenSource.invalidate()
    }

    // Gitea en Forgejo hebben geen eigen beveiligingsmeldingen: `securityAlerts` blijft de
    // standaard nil.

    // MARK: - Eigenaren

    /// Een organisatie, anders een gebruiker; een naam die geen van beide is geeft `noAccess`.
    func resolve(_ owner: String) async throws -> Owner {
        if let known = ownerCache[owner] { return known }
        let resolved: Owner
        do {
            let organization: OrganizationDTO = try await get(endpoint("orgs", owner))
            resolved = .organization(organization.username ?? organization.name ?? owner)
        } catch ProviderError.server(status: 404) {
            do {
                let user: UserDTO = try await get(endpoint("users", owner))
                resolved = .user(user.login)
            } catch ProviderError.server(status: 404) {
                throw ProviderError.noAccess(owner)
            }
        }
        ownerCache[owner] = resolved
        return resolved
    }
}
