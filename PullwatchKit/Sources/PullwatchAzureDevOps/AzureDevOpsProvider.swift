public import Foundation
public import PullwatchCore

/// Azure DevOps via de REST API: de pull requests, tags en bestanden van de repo's in de projecten
/// van één organisatie, met een PAT of het token van `az`.
public actor AzureDevOpsProvider: PRProvider {
    let accountId: UUID
    let organization: String
    let tokenSource: any TokenSource
    let authMethod: AuthMethod
    let http: any HTTPClient
    let now: @Sendable () -> Date
    let pageSize = 100
    private var projectCache: (names: [String], fetchedAt: Date)?
    /// Het e-mailadres (`uniqueName`) van de auteur per PR (dedupKey), uit de laatste lijst, zodat
    /// `coAuthors(of:)` de eigen commits van de auteur herkent.
    var authorEmails: [String: String] = [:]
    /// Het id van het project per PR (dedupKey), uit de laatste lijst: de policy-evaluaties van
    /// een PR vragen het (`checks(of:)`).
    var projectIds: [String: String] = [:]
    /// Hooguit zoveel commits per PR waarvan het bericht afgekapt is en apart opgehaald wordt.
    let fullMessageLimit = 10

    public init(
        accountId: UUID,
        organization: String,
        tokenSource: any TokenSource,
        authMethod: AuthMethod,
        http: any HTTPClient,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.accountId = accountId
        self.organization = organization
        self.tokenSource = tokenSource
        self.authMethod = authMethod
        self.http = http
        self.now = now
    }

    var baseURL: URL {
        URL(string: "https://dev.azure.com")!.appending(path: organization)
    }

    public func currentUserId() async throws -> String {
        try await authenticatedUser().id
    }

    /// De weergavenamen en het e-mailadres van het account waarmee de gebruiker inlogt
    /// (`properties.Account`, alleen als dat een e-mailadres is), voor de eigen pushes: een
    /// commit in Azure DevOps hangt niet aan de GUID van een gebruiker.
    public func currentUserIdentity() async throws -> UserIdentity? {
        let user = try await authenticatedUser()
        let account = user.properties?.account?.value
        return UserIdentity(
            names: [user.providerDisplayName, user.customDisplayName].compactMap { $0 },
            emails: [account].compactMap { $0 }.filter { $0.contains("@") }
        )
    }

    public func testConnection() async throws -> String {
        let user = try await authenticatedUser()
        // connectionData is niet organisatie-gebonden; een org-endpoint bewijst pas toegang.
        do {
            let _: ValueList<ProjectDTO> = try await get(
                baseURL.appending(path: "_apis/projects"),
                query: [URLQueryItem(name: "$top", value: "1")]
            )
        } catch ProviderError.unauthorized {
            throw ProviderError.noAccess(organization)
        }
        return user.providerDisplayName ?? user.id
    }

    /// Azure DevOps beantwoordt connectionData met een anonieme gebruiker als het token niet geaccepteerd wordt.
    private func authenticatedUser() async throws -> ConnectionData.User {
        let data: ConnectionData = try await get(baseURL.appending(path: "_apis/connectionData"), apiVersion: "7.1-preview")
        guard data.authenticatedUser.id != ConnectionData.anonymousUserId else { throw ProviderError.unauthorized }
        return data.authenticatedUser
    }

    public func listRepos() async throws -> [String] {
        var result: [String] = []
        for project in try await projects() {
            let list: ValueList<RepositoryDTO> = try await get(
                baseURL.appending(path: project).appending(path: "_apis/git/repositories")
            )
            result += list.value.map { "\(project)/\($0.name)" }
        }
        return result.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    public func openPullRequests() async throws -> [PullRequest] {
        var result: [PullRequest] = []
        for project in try await projects() {
            var skip = 0
            while true {
                let page: ValueList<PullRequestDTO> = try await get(
                    baseURL.appending(path: project).appending(path: "_apis/git/pullrequests"),
                    query: [
                        URLQueryItem(name: "searchCriteria.status", value: "active"),
                        URLQueryItem(name: "$top", value: String(pageSize)),
                        URLQueryItem(name: "$skip", value: String(skip)),
                    ]
                )
                for dto in page.value {
                    result.append(try makePullRequest(dto))
                }
                if page.value.count < pageSize { break }
                skip += pageSize
            }
        }
        return result
    }

    public func pullRequests(updatedSince since: Date?, limit: Int) async throws -> [PullRequest] {
        var byId: [Int: PullRequest] = [:]
        // Met `since` twee reeksen: recent aangemaakt en recent gesloten; zonder `since` één reeks.
        let ranges: [String?] = since == nil ? [nil] : ["created", "closed"]
        // Per reeks het aantal opgehaalde PR's over alle projecten; een reeks stopt bij `limit`.
        var fetched = Array(repeating: 0, count: ranges.count)
        for project in try await projects() {
            for (series, range) in ranges.enumerated() where fetched[series] < limit {
                var skip = 0
                while true {
                    var query = [
                        URLQueryItem(name: "searchCriteria.status", value: "all"),
                        URLQueryItem(name: "$top", value: String(pageSize)),
                        URLQueryItem(name: "$skip", value: String(skip)),
                    ]
                    if let range, let since {
                        query += [
                            URLQueryItem(name: "searchCriteria.queryTimeRangeType", value: range),
                            URLQueryItem(name: "searchCriteria.minTime", value: since.formatted(Date.ISO8601FormatStyle(timeZone: .gmt))),
                        ]
                    }
                    let page: ValueList<PullRequestDTO>
                    do {
                        page = try await get(
                            baseURL.appending(path: project).appending(path: "_apis/git/pullrequests"),
                            query: query
                        )
                    } catch ProviderError.server(status: 404) {
                        break // project bestaat niet (meer)
                    }
                    for dto in page.value {
                        byId[dto.pullRequestId] = try makePullRequest(dto)
                    }
                    fetched[series] += page.value.count
                    if page.value.count < pageSize || fetched[series] >= limit { break }
                    skip += pageSize
                }
            }
            if fetched.allSatisfy({ $0 >= limit }) { break }
        }
        return Array(byId.values.sorted { $0.createdAt > $1.createdAt }.prefix(limit))
    }

    public func invalidateCredentials() async {
        projectCache = nil
        await tokenSource.invalidate()
    }

    /// Een losse repo (`project/repo`) binnen de organisatie van het account: één verzoek naar de
    /// repository. Azure DevOps kent geen openbaar lezen zonder inloggen voor deze API's.
    public func checkRepository(_ repo: String) async throws -> RepositoryCheck {
        let parts = repo.split(separator: "/", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { throw ProviderError.noAccess(repo) }
        let (data, response) = try await send(
            baseURL.appending(path: parts[0]).appending(path: "_apis/git/repositories").appending(path: parts[1]),
            apiVersion: "7.1"
        )
        if response.statusCode == 404 || response.statusCode == 403 { throw ProviderError.noAccess(repo) }
        try HTTPStatus.check(response, now: now())
        let found = try JSONDecoding.decode(SingleRepositoryDTO.self, from: data)
        return RepositoryCheck(name: "\(found.project.name)/\(found.name)")
    }

    private func projects() async throws -> [String] {
        if let projectCache, now().timeIntervalSince(projectCache.fetchedAt) < 3600 {
            return projectCache.names
        }
        let list: ValueList<ProjectDTO> = try await get(
            baseURL.appending(path: "_apis/projects"),
            query: [URLQueryItem(name: "$top", value: "500")]
        )
        let names = list.value.map(\.name)
        projectCache = (names, now())
        return names
    }

    private func makePullRequest(_ dto: PullRequestDTO) throws -> PullRequest {
        guard let createdAt = DateParsing.parse(dto.creationDate) else {
            throw ProviderError.decoding("creationDate \(dto.creationDate)")
        }
        let project = dto.repository.project.name
        let state: PRState
        switch dto.status {
        case "completed": state = .merged
        case "abandoned": state = .closed
        default: state = .open
        }
        let webURL = baseURL
            .appending(path: project)
            .appending(path: "_git")
            .appending(path: dto.repository.name)
            .appending(path: "pullrequest")
            .appending(path: String(dto.pullRequestId))
        let pullRequest = PullRequest(
            accountId: accountId,
            repo: "\(project)/\(dto.repository.name)",
            number: dto.pullRequestId,
            title: dto.title,
            authorId: dto.createdBy.id,
            authorName: dto.createdBy.displayName,
            // Geen `authorAvatarURL`: `createdBy.imageUrl` laadt alleen met het token, en AsyncImage
            // stuurt dat niet mee. Het persoonssymbool is beter dan een geweigerd verzoek.
            isDraft: dto.isDraft ?? false,
            createdAt: createdAt,
            webURL: webURL,
            state: state,
            closedAt: dto.closedDate.flatMap(DateParsing.parse),
            revision: dto.lastMergeSourceCommit?.commitId,
            // Auto-complete aan: de PR voltooit vanzelf zodra de policies slagen. Azure DevOps
            // geeft geen plek in een rij en geen tijdstip.
            mergeQueue: state == .open && dto.autoCompleteSetBy != nil ? MergeQueueEntry(kind: .autoComplete) : nil,
            sourceBranch: dto.sourceRefName.flatMap(Self.branchName),
            targetBranch: dto.targetRefName.flatMap(Self.branchName)
        )
        if let email = dto.createdBy.uniqueName { authorEmails[pullRequest.dedupKey] = email }
        if let id = dto.repository.project.id { projectIds[pullRequest.dedupKey] = id }
        return pullRequest
    }

    /// `refs/heads/feature/x` wordt `feature/x`; een andere ref (een tag, een PR-merge) geen branch.
    static func branchName(_ ref: String) -> String? {
        ref.hasPrefix("refs/heads/") ? String(ref.dropFirst("refs/heads/".count)) : nil
    }
}
