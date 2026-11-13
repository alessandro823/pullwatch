public import Foundation
public import PullwatchCore

/// GitLab (gitlab.com of een eigen server) via de REST API v4. Eigenaren zijn groepen (met hun
/// subgroepen) of gebruikers; een repo heet zoals GitLab hem noemt, `groep/subgroep/project`
/// (`path_with_namespace`). Merge requests worden `PullRequest`s met hun `iid` als nummer.
public actor GitLabProvider: PRProvider {
    enum Owner: Equatable {
        /// Een groep met zijn volledige pad ("groep/subgroep").
        case group(String)
        /// Een gebruiker met zijn id (de API van gebruikers wil het id, niet de naam).
        case user(id: Int)
    }

    let accountId: UUID
    let owners: [String]
    let tokenSource: any TokenSource
    let http: any HTTPClient
    let now: @Sendable () -> Date
    /// De server zonder "/" aan het eind, bv. `https://gitlab.com` of `https://example.com/gitlab`.
    let instanceURL: URL
    let pageSize = 100
    let maxPages = 10
    /// Een bestandsboom kan groot zijn; zoveel pagina's van honderd paden hooguit.
    let maxTreePages = 100
    private var ownerCache: [String: Owner] = [:]
    /// De projecten van een gebruiker-eigenaar (merge requests gaan daar per project), een uur bewaard.
    private var userProjects: [Int: (paths: [String], fetchedAt: Date)] = [:]
    /// De weergavenaam van de auteur per PR (dedupKey), uit de laatste lijst, zodat
    /// `coAuthors(of:)` de eigen commits van de auteur herkent (commits hebben geen gebruikersnaam).
    var authorNames: [String: String] = [:]
    /// Losse projecten (`Account.extraRepos`) buiten de gevolgde groepen en gebruikers: die krijgen
    /// per poll elk één vraag naar hun merge requests (`GitLabProvider+ExtraProjects`).
    let extraRepos: [String]
    /// Hoe elk los project te lezen is, per pad lowercased; zie `access(for:)`.
    var projectAccess: [String: (access: ProjectAccess, at: Date)] = [:]
    /// Tot wanneer de limiet voor verzoeken zonder token op is.
    var anonymousPausedUntil: Date?
    /// Projecten (lowercased) zonder merge trains die dit token mag lezen (geen Premium, uit,
    /// of geen rechten): die krijgen geen vraag meer naar hun train tot `mergeTrainRetry` voorbij is.
    var withoutMergeTrains: [String: Date] = [:]

    private static let defaultInstanceURL = URL(string: "https://gitlab.com")!

    public init(
        accountId: UUID,
        owners: [String],
        extraRepos: [String] = [],
        instanceURL: URL? = nil,
        tokenSource: any TokenSource,
        http: any HTTPClient,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.accountId = accountId
        self.owners = owners
            .map { $0.trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: "/@"))) }
            .filter { !$0.isEmpty }
        self.extraRepos = Self.projectsOutside(owners: self.owners, extraRepos)
        self.instanceURL = instanceURL ?? Self.defaultInstanceURL
        self.tokenSource = tokenSource
        self.http = http
        self.now = now
    }

    // MARK: - Gebruiker en verbinding

    public func currentUserId() async throws -> String {
        try await currentUser().username
    }

    /// De naam, de gebruikersnaam en de e-mailadressen van de gebruiker (`/user`), voor de eigen
    /// pushes: een commit in GitLab hangt niet aan een account.
    public func currentUserIdentity() async throws -> UserIdentity? {
        let user = try await currentUser()
        return UserIdentity(
            names: [user.name, user.username].compactMap { $0 },
            emails: [user.email, user.commitEmail, user.publicEmail].compactMap { $0 }
        )
    }

    /// Controleert het token (`/user`) en of elke eigenaar te vinden is; geeft de gebruikersnaam.
    public func testConnection() async throws -> String {
        let user = try await currentUser()
        for owner in owners {
            _ = try await resolve(owner)
        }
        return user.username
    }

    private func currentUser() async throws -> UserDTO {
        try await get(endpoint("user"))
    }

    // MARK: - Repo's

    /// De projecten van alle gevolgde eigenaren (groepen met subgroepen, gebruikers), op naam;
    /// gearchiveerde projecten niet.
    public func listRepos() async throws -> [String] {
        var names: [String] = []
        for owner in owners {
            names += try await projects(of: try await resolve(owner))
        }
        names += try await extraProjectNames()
        return Array(Set(names)).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    private func projects(of owner: Owner) async throws -> [String] {
        let url: URL
        var query = [
            URLQueryItem(name: "simple", value: "true"),
            URLQueryItem(name: "archived", value: "false"),
            URLQueryItem(name: "order_by", value: "id"),
            URLQueryItem(name: "sort", value: "asc"),
        ]
        switch owner {
        case .group(let path):
            url = endpoint("groups", path, "projects")
            // Ook de subgroepen, maar geen projecten die een andere groep met deze deelt.
            query += [URLQueryItem(name: "include_subgroups", value: "true"), URLQueryItem(name: "with_shared", value: "false")]
        case .user(let id):
            url = endpoint("users", String(id), "projects")
        }
        let projects: [ProjectDTO] = try await pages(url, query: query, maxPages: maxPages)
        return projects.map(\.pathWithNamespace)
    }

    /// De projecten van een gebruiker, een uur bewaard: per poll gaat er per project een vraag
    /// naar de merge requests, de lijst zelf hoeft niet elke keer.
    private func cachedProjects(ofUser id: Int) async throws -> [String] {
        if let cached = userProjects[id], now().timeIntervalSince(cached.fetchedAt) < 3600 {
            return cached.paths
        }
        let paths = try await projects(of: .user(id: id))
        userProjects[id] = (paths, now())
        return paths
    }

    // MARK: - Merge requests

    /// Open merge requests (ook drafts) bij alle gevolgde eigenaren: één lijst per groep (met
    /// subgroepen), bij een gebruiker één per project.
    public func openPullRequests() async throws -> [PullRequest] {
        var result: [PullRequest] = []
        for owner in owners {
            result += try await mergeRequests(of: try await resolve(owner), query: [
                URLQueryItem(name: "state", value: "opened"),
            ], limit: .max)
        }
        // Van een los project de honderd recentst bijgewerkte open merge requests, in één vraag.
        result += try await extraMergeRequests(query: [
            URLQueryItem(name: "state", value: "opened"),
            URLQueryItem(name: "order_by", value: "updated_at"),
            URLQueryItem(name: "sort", value: "desc"),
        ], limit: .max)
        return await withMergeTrains(result)
    }

    /// Merge requests in elke status, recentst bijgewerkt eerst, samen hooguit `limit`; met
    /// `since` alleen wat sindsdien is bijgewerkt (`updated_after`).
    public func pullRequests(updatedSince since: Date?, limit: Int) async throws -> [PullRequest] {
        var query = [
            URLQueryItem(name: "order_by", value: "updated_at"),
            URLQueryItem(name: "sort", value: "desc"),
        ]
        if let since {
            query.append(URLQueryItem(name: "updated_after", value: since.formatted(Date.ISO8601FormatStyle(timeZone: .gmt))))
        }
        var result: [PullRequest] = []
        for owner in owners {
            result += try await mergeRequests(of: try await resolve(owner), query: query, limit: limit)
        }
        result += try await extraMergeRequests(query: query, limit: limit)
        // Over eigenaren en projecten heen de recentste eerst, zodat de grens eerlijk is.
        return Array(result.sorted { ($0.closedAt ?? $0.createdAt) > ($1.closedAt ?? $1.createdAt) }.prefix(limit))
    }

    private func mergeRequests(of owner: Owner, query: [URLQueryItem], limit: Int) async throws -> [PullRequest] {
        let query = query + [URLQueryItem(name: "scope", value: "all")]
        switch owner {
        case .group(let path):
            let found: [MergeRequestDTO] = try await pages(
                endpoint("groups", path, "merge_requests"), query: query, maxPages: maxPages, stop: { $0.count >= limit }
            )
            return try found.prefix(limit).map(makePullRequest)
        case .user(let id):
            var result: [PullRequest] = []
            for project in try await cachedProjects(ofUser: id) {
                let found: [MergeRequestDTO]
                do {
                    found = try await pages(
                        endpoint("projects", project, "merge_requests"), query: query, maxPages: maxPages, stop: { $0.count >= limit }
                    )
                } catch ProviderError.server(status: 404) {
                    continue // project bestaat niet (meer); de lijst is hooguit een uur oud
                }
                result += try found.prefix(limit).map(makePullRequest)
            }
            return result
        }
    }

    func makePullRequest(_ dto: MergeRequestDTO) throws -> PullRequest {
        guard let createdAt = DateParsing.parse(dto.createdAt) else {
            throw ProviderError.decoding("created_at \(dto.createdAt)")
        }
        guard let webURL = URL(string: dto.webUrl), let repo = Self.repoPath(of: dto, instanceURL: instanceURL) else {
            throw ProviderError.decoding("web_url in merge request \(dto.iid)")
        }
        let state: PRState = switch dto.state {
        case "merged": .merged
        case "closed": .closed
        default: .open // "opened", en "locked" (tijdelijk vergrendeld, nog open)
        }
        let closedAt = state == .merged ? (dto.mergedAt ?? dto.closedAt) : (state == .closed ? dto.closedAt : nil)
        let pullRequest = PullRequest(
            accountId: accountId,
            repo: repo,
            number: dto.iid,
            title: dto.title,
            authorId: dto.author.username,
            authorName: dto.author.username,
            authorAvatarURL: Self.avatarURL(dto.author.avatarUrl, instanceURL: instanceURL),
            isDraft: dto.draft ?? dto.workInProgress ?? false,
            createdAt: createdAt,
            webURL: webURL,
            state: state,
            closedAt: closedAt.flatMap(DateParsing.parse),
            // De laatste commit van de bronbranch: verandert bij elke push, niet bij een reactie.
            revision: dto.sha ?? dto.updatedAt,
            // "Merge als de pipeline slaagt" (auto-merge), ook hoe een merge request in een merge
            // train komt; de plek in de train komt erbij in `withMergeTrains`.
            mergeQueue: state == .open && dto.mergeWhenPipelineSucceeds == true ? MergeQueueEntry(kind: .autoMerge) : nil,
            sourceBranch: dto.sourceBranch,
            targetBranch: dto.targetBranch
        )
        if let name = dto.author.name, !name.isEmpty { authorNames[pullRequest.dedupKey] = name }
        return pullRequest
    }

    /// De foto uit `avatar_url`: een absolute URL (gitlab.com, Gravatar) zoals hij is, een pad
    /// (eigen server) op de server. Een pad dat al met het pad van de server begint (GitLab onder
    /// `/gitlab`) komt er niet dubbel achter.
    static func avatarURL(_ raw: String?, instanceURL: URL) -> URL? {
        guard let raw, !raw.isEmpty else { return nil }
        guard raw.hasPrefix("/") else { return URL(string: raw) }
        let serverPath = instanceURL.path(percentEncoded: true).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if !serverPath.isEmpty, raw.hasPrefix("/\(serverPath)/") {
            return URL(string: raw, relativeTo: instanceURL)?.absoluteURL
        }
        let base = instanceURL.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return URL(string: base + raw)
    }

    /// "groep/subgroep/project" uit `references.full` ("groep/project!12"), anders uit de
    /// webpagina (`<server>/groep/project/-/merge_requests/12`).
    static func repoPath(of dto: MergeRequestDTO, instanceURL: URL) -> String? {
        if let full = dto.references?.full, let bang = full.lastIndex(of: "!") {
            let path = String(full[..<bang])
            if path.contains("/") { return path }
        }
        let prefix = instanceURL.absoluteString + "/"
        guard dto.webUrl.hasPrefix(prefix), let marker = dto.webUrl.range(of: "/-/merge_requests/") else { return nil }
        let path = dto.webUrl[dto.webUrl.index(dto.webUrl.startIndex, offsetBy: prefix.count)..<marker.lowerBound]
        return path.isEmpty ? nil : String(path).removingPercentEncoding ?? String(path)
    }

    public func invalidateCredentials() async {
        userProjects = [:]
        projectAccess = [:]
        await tokenSource.invalidate()
    }

    // GitLab heeft geen schone tegenhanger van code scanning en adviezen voor iedereen (de
    // vulnerability-API is GitLab Ultimate en GraphQL): `securityAlerts` blijft de standaard nil.

    // MARK: - Eigenaren

    /// Een groep (ook "groep/subgroep") of anders een gebruiker; een naam die geen van beide is
    /// geeft `noAccess`. Bewaard zolang de provider bestaat.
    func resolve(_ owner: String) async throws -> Owner {
        if let known = ownerCache[owner] { return known }
        let resolved: Owner
        do {
            let group: GroupDTO = try await get(endpoint("groups", owner), query: [
                URLQueryItem(name: "with_projects", value: "false"),
            ])
            resolved = .group(group.fullPath)
        } catch ProviderError.server(status: 404) {
            let users: [UserDTO] = try await get(endpoint("users"), query: [URLQueryItem(name: "username", value: owner)])
            guard let user = users.first(where: { $0.username.caseInsensitiveCompare(owner) == .orderedSame }) ?? users.first,
                  let id = user.id else {
                throw ProviderError.noAccess(owner)
            }
            resolved = .user(id: id)
        }
        ownerCache[owner] = resolved
        return resolved
    }
}
