public import Foundation
public import PullwatchCore

/// Bitbucket Cloud (bitbucket.org) via de REST API 2.0 op `api.bitbucket.org/2.0`. Eigenaren zijn
/// workspaces; een repo heet zoals Bitbucket hem noemt, `workspace/repo-slug` (`full_name`).
/// Inloggen met een API-token met scopes van het Atlassian-account plus het e-mailadres van dat
/// account (Basic auth); app passwords werken sinds juli 2026 niet meer.
///
/// Bitbucket heeft geen lijst van alle pull requests van een workspace, dus Pullwatch vraagt ze per
/// repo. Om de limiet (per uur) te sparen onthoudt de provider per repo de open pull requests en
/// vraagt hij ze alleen opnieuw als `updated_on` van de repo veranderde (een push, een nieuwe of
/// gemergede pull request), en anders hooguit eens per `openRefresh`.
public actor BitbucketProvider: PRProvider {
    static let api = URL(string: "https://api.bitbucket.org/2.0")!
    static let web = URL(string: "https://bitbucket.org")!

    let accountId: UUID
    let workspaces: [String]
    /// Het e-mailadres van het Atlassian-account bij het token; zonder geen verzoek met inloggen.
    let email: String?
    let tokenSource: any TokenSource
    let http: any HTTPClient
    let now: @Sendable () -> Date
    let pageSize = 100
    /// Pull requests per pagina (de API staat er hooguit 50 toe).
    let pullRequestPageSize = 50
    let maxPages = 10
    /// Een bestandsboom kan groot zijn; zoveel pagina's van honderd paden hooguit.
    let maxTreePages = 100
    /// Zo lang blijven de open pull requests van een repo die niet veranderde bewaard.
    static let openRefresh: TimeInterval = 600

    /// Per repo (lowercased) de open pull requests, met `updated_on` van de repo toen.
    private var openCache: [String: (updatedOn: String?, at: Date, pullRequests: [PullRequest])] = [:]
    /// Per repo (lowercased) `updated_on` uit de laatste lijst van een workspace, voor de branches:
    /// zolang die niet verschuift, is er niets gepusht (`branches(in:unchanged:)`).
    var repoUpdatedOn: [String: String] = [:]
    /// Losse repo's (`Account.extraRepos`) buiten de gevolgde workspaces.
    let extraRepos: [String]
    /// Hoe elke losse repo te lezen is, per naam lowercased; zie `access(for:)`.
    var repoAccess: [String: (access: RepoAccess, at: Date)] = [:]
    /// Tot wanneer de limiet voor verzoeken zonder inloggen op is.
    var anonymousPausedUntil: Date?
    /// De weergavenaam van de auteur per PR (dedupKey), zodat `coAuthors(of:)` de eigen commits
    /// van de auteur herkent.
    var authorNames: [String: String] = [:]

    public init(
        accountId: UUID,
        workspaces: [String],
        email: String?,
        extraRepos: [String] = [],
        tokenSource: any TokenSource,
        http: any HTTPClient,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.accountId = accountId
        self.workspaces = workspaces
            .map { $0.trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: "/@"))) }
            .filter { !$0.isEmpty }
        self.email = email?.trimmingCharacters(in: .whitespaces)
        self.extraRepos = Account.reposOutside(owners: self.workspaces, extraRepos)
        self.tokenSource = tokenSource
        self.http = http
        self.now = now
    }

    // MARK: - Gebruiker en verbinding

    /// De `uuid` van het account, dezelfde als die van de auteur van een pull request.
    public func currentUserId() async throws -> String {
        let user = try await currentUser()
        guard let id = user.uuid else { throw ProviderError.decoding("uuid in /user") }
        return id
    }

    /// Controleert het token (`/user`) en of elke workspace te vinden is; geeft de weergavenaam.
    public func testConnection() async throws -> String {
        let user = try await currentUser()
        for workspace in workspaces {
            do {
                _ = try await send(endpoint("repositories", workspace), query: [URLQueryItem(name: "pagelen", value: "1")])
            } catch ProviderError.server(status: 404) {
                throw ProviderError.noAccess(workspace)
            }
        }
        return user.displayName ?? user.nickname ?? user.uuid ?? ""
    }

    private func currentUser() async throws -> AccountDTO {
        try await get(endpoint("user"))
    }

    // MARK: - Repo's

    /// De repo's van alle gevolgde workspaces en de losse repo's, op naam.
    public func listRepos() async throws -> [String] {
        var names: [String] = []
        for workspace in workspaces {
            names += try await repositories(of: workspace).map(\.fullName)
        }
        names += try await extraRepoNames()
        var seen: Set<String> = []
        return names.filter { seen.insert($0.lowercased()).inserted }
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    /// Alle repo's die dit account in de workspace mag zien, recentst bijgewerkt eerst. Een
    /// onbekende workspace geeft `noAccess`. Onthoudt `updated_on` per repo (`repoUpdatedOn`).
    func repositories(of workspace: String) async throws -> [RepositoryDTO] {
        do {
            let repos: [RepositoryDTO] = try await pages(endpoint("repositories", workspace), query: [
                URLQueryItem(name: "pagelen", value: String(pageSize)),
                URLQueryItem(name: "sort", value: "-updated_on"),
                URLQueryItem(name: "fields", value: "next,values.full_name,values.updated_on"),
            ], maxPages: maxPages)
            for repo in repos {
                repoUpdatedOn[repo.fullName.lowercased()] = repo.updatedOn
            }
            return repos
        } catch ProviderError.server(status: 404) {
            throw ProviderError.noAccess(workspace)
        }
    }

    // MARK: - Pull requests

    /// Open pull requests (ook drafts) van elke repo in de gevolgde workspaces en van de losse
    /// repo's; per repo opnieuw gevraagd als hij veranderde of de vorige keer te lang geleden is.
    public func openPullRequests() async throws -> [PullRequest] {
        var result: [PullRequest] = []
        for workspace in workspaces {
            for repo in try await repositories(of: workspace) {
                result += try await openPullRequests(in: repo.fullName, updatedOn: repo.updatedOn, anonymous: false)
            }
        }
        for repo in extraRepos {
            let anonymous: Bool
            switch try await access(for: repo) {
            case .token: anonymous = false
            case .anonymous: anonymous = true
            case .missing, .paused: continue
            }
            do {
                result += try await openPullRequests(in: repo, updatedOn: nil, anonymous: anonymous)
            } catch ProviderError.rateLimited where anonymous {
                continue // limiet zonder inloggen op: deze keer zonder deze repo
            } catch ProviderError.server(status: 404) {
                repoAccess[repo.lowercased()] = nil
            }
        }
        return result
    }

    private func openPullRequests(in repo: String, updatedOn: String?, anonymous: Bool) async throws -> [PullRequest] {
        let key = repo.lowercased()
        if let updatedOn, let cached = openCache[key], cached.updatedOn == updatedOn,
           now().timeIntervalSince(cached.at) < Self.openRefresh {
            return cached.pullRequests
        }
        let found: [PullRequestDTO] = try await pages(repository(repo, "pullrequests"), query: [
            URLQueryItem(name: "state", value: "OPEN"),
            URLQueryItem(name: "pagelen", value: String(pullRequestPageSize)),
        ], maxPages: maxPages, anonymous: anonymous)
        let pullRequests = try found.map { try makePullRequest($0, repo: repo) }
        openCache[key] = (updatedOn, now(), pullRequests)
        return pullRequests
    }

    /// Pull requests in elke status, recentst bijgewerkt eerst, samen hooguit `limit`; met
    /// `since` alleen wat sindsdien is bijgewerkt (`q=updated_on > …`), en dan alleen bij repo's
    /// die sindsdien veranderden of waarvan Bitbucket dat niet zegt.
    public func pullRequests(updatedSince since: Date?, limit: Int) async throws -> [PullRequest] {
        guard limit > 0 else { return [] }
        var query = [
            URLQueryItem(name: "state", value: "OPEN"),
            URLQueryItem(name: "state", value: "MERGED"),
            URLQueryItem(name: "state", value: "DECLINED"),
            URLQueryItem(name: "state", value: "SUPERSEDED"),
            URLQueryItem(name: "sort", value: "-updated_on"),
            URLQueryItem(name: "pagelen", value: String(pullRequestPageSize)),
        ]
        if let since {
            query.append(URLQueryItem(name: "q", value: "updated_on > \(since.formatted(Date.ISO8601FormatStyle(timeZone: .gmt)))"))
        }
        var targets: [(repo: String, anonymous: Bool)] = []
        for workspace in workspaces {
            for repo in try await repositories(of: workspace) {
                if let since, let updated = repo.updatedOn.flatMap(DateParsing.parse), updated < since { continue }
                targets.append((repo.fullName, false))
            }
        }
        for repo in extraRepos {
            switch try await access(for: repo) {
            case .token: targets.append((repo, false))
            case .anonymous: targets.append((repo, true))
            case .missing, .paused: continue
            }
        }
        var result: [PullRequest] = []
        for target in targets {
            do {
                let found: [PullRequestDTO] = try await pages(
                    repository(target.repo, "pullrequests"), query: query, maxPages: maxPages, anonymous: target.anonymous,
                    stop: { $0.count >= limit }
                )
                result += try found.prefix(limit).map { try makePullRequest($0, repo: target.repo) }
            } catch ProviderError.rateLimited where target.anonymous {
                continue
            } catch ProviderError.server(status: 404) {
                continue // repo net verdwenen
            }
        }
        // Over repo's heen de recentste eerst, zodat de grens eerlijk is.
        return Array(result.sorted { ($0.closedAt ?? $0.createdAt) > ($1.closedAt ?? $1.createdAt) }.prefix(limit))
    }

    /// Bitbucket noemt geen sluitdatum; bij een gemergede of afgewezen pull request is
    /// `updated_on` het moment van sluiten (of later, als er daarna nog een reactie kwam).
    func makePullRequest(_ dto: PullRequestDTO, repo: String) throws -> PullRequest {
        guard let createdAt = DateParsing.parse(dto.createdOn) else {
            throw ProviderError.decoding("created_on \(dto.createdOn)")
        }
        let webURL = dto.links?.html?.href.flatMap(URL.init(string:))
            ?? Self.webURL(repo, "pull-requests", String(dto.id))
        guard let webURL else { throw ProviderError.decoding("links.html in pull request \(dto.id)") }
        let state: PRState = switch dto.state {
        case "MERGED": .merged
        case "DECLINED", "SUPERSEDED": .closed
        default: .open
        }
        let authorName = dto.author?.displayName ?? dto.author?.nickname ?? ""
        let pullRequest = PullRequest(
            accountId: accountId,
            repo: repo,
            number: dto.id,
            title: dto.title,
            authorId: dto.author?.uuid ?? authorName,
            authorName: authorName,
            authorAvatarURL: dto.author?.links?.avatar?.href.flatMap(URL.init(string:)),
            isDraft: dto.draft ?? false,
            createdAt: createdAt,
            webURL: webURL,
            state: state,
            closedAt: state == .open ? nil : dto.updatedOn.flatMap(DateParsing.parse),
            // De laatste commit van de bronbranch: verandert bij elke push, niet bij een reactie.
            revision: dto.source?.commit?.hash ?? dto.updatedOn,
            mergeQueue: state == .open && dto.queued == true ? MergeQueueEntry(kind: .mergeQueue) : nil,
            // Alleen uit dezelfde repo: een branch in een fork hoort niet in de boom.
            sourceBranch: dto.source?.repository?.fullName == dto.destination?.repository?.fullName ? dto.source?.branch?.name : nil,
            targetBranch: dto.destination?.branch?.name
        )
        if !authorName.isEmpty { authorNames[pullRequest.dedupKey] = authorName }
        return pullRequest
    }

    /// Een pagina op bitbucket.org: de repo houdt zijn "/", de rest wordt gecodeerd.
    static func webURL(_ repo: String, _ segments: String...) -> URL? {
        pageURL(repo, segments.map(encode))
    }

    /// Als `webURL`, maar met segmenten die al gecodeerd zijn (bv. met een `%0D` erin).
    static func pageURL(_ repo: String, _ encoded: [String]) -> URL? {
        let path = (repo.split(separator: "/").map { encode(String($0)) } + encoded).joined(separator: "/")
        return URL(string: web.absoluteString + "/" + path)
    }

    public func invalidateCredentials() async {
        openCache = [:]
        repoAccess = [:]
        await tokenSource.invalidate()
    }

    // Bitbucket Cloud heeft geen beveiligingsmeldingen per repo die een token met leesrechten kan
    // lezen: `securityAlerts` blijft de standaard nil.
}
