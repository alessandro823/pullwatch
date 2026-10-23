import Foundation

public actor AzureDevOpsProvider: PRProvider {
    private let accountId: UUID
    private let organization: String
    private let tokenSource: any TokenSource
    private let authMethod: AuthMethod
    private let http: any HTTPClient
    private let now: @Sendable () -> Date
    private let pageSize = 100
    private var projectCache: (names: [String], fetchedAt: Date)?

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

    private var baseURL: URL {
        URL(string: "https://dev.azure.com")!.appending(path: organization)
    }

    public func currentUserId() async throws -> String {
        try await authenticatedUser().id
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

    public func tags(in repos: [String]) async throws -> TagFetch {
        var result: [Tag] = []
        var unavailable: [String] = []
        for repo in repos {
            guard let slash = repo.firstIndex(of: "/") else { continue }
            let project = String(repo[..<slash])
            let name = String(repo[repo.index(after: slash)...])
            let list: ValueList<RefDTO>
            do {
                list = try await get(
                    baseURL.appending(path: project).appending(path: "_apis/git/repositories")
                        .appending(path: name).appending(path: "refs"),
                    query: [URLQueryItem(name: "filter", value: "tags/")]
                )
            } catch ProviderError.server(status: 404) {
                unavailable.append(repo) // repo bestaat niet (meer)
                continue
            } catch ProviderError.unauthorized {
                unavailable.append(repo) // geen toegang (403: SSO, rechten, IP-allowlist); andere repo's gaan door
                continue
            }
            for ref in list.value {
                let tagName = ref.name.hasPrefix("refs/tags/") ? String(ref.name.dropFirst("refs/tags/".count)) : ref.name
                result.append(Tag(
                    accountId: accountId,
                    repo: repo,
                    name: tagName,
                    authorName: ref.creator?.displayName,
                    webURL: tagURL(project: project, repo: name, tag: tagName)
                ))
            }
        }
        return TagFetch(tags: result, unavailableRepos: unavailable)
    }

    private func tagURL(project: String, repo: String, tag: String) -> URL {
        let base = baseURL.appending(path: project).appending(path: "_git").appending(path: repo)
        var components = URLComponents(url: base, resolvingAgainstBaseURL: false)!
        // "+" en andere tekens expliciet coderen; "/" blijft leesbaar.
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~/"))
        components.percentEncodedQuery = "version=GT" + (tag.addingPercentEncoding(withAllowedCharacters: allowed) ?? tag)
        return components.url!
    }

    public func filePaths(in repo: String) async throws -> [String] {
        let list: ValueList<ItemDTO>
        do {
            list = try await get(itemsURL(repo), query: [
                URLQueryItem(name: "scopePath", value: "/"),
                URLQueryItem(name: "recursionLevel", value: "Full"),
            ])
        } catch ProviderError.server(status: 404) {
            return [] // lege repo
        }
        return list.value.filter { $0.isFolder != true }.map { String($0.path.drop { $0 == "/" }) }
    }

    public func fileContent(in repo: String, path: String) async throws -> String {
        let item: ItemDTO = try await get(itemsURL(repo), query: [
            URLQueryItem(name: "path", value: "/" + path),
            URLQueryItem(name: "includeContent", value: "true"),
        ])
        return item.content ?? ""
    }

    /// `repo` is "project/naam", zoals `listRepos()` levert.
    private func itemsURL(_ repo: String) -> URL {
        let parts = repo.split(separator: "/", maxSplits: 1).map(String.init)
        return baseURL.appending(path: parts.first ?? repo).appending(path: "_apis/git/repositories")
            .appending(path: parts.last ?? repo).appending(path: "items")
    }

    public func invalidateCredentials() async {
        projectCache = nil
        await tokenSource.invalidate()
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
        return PullRequest(
            accountId: accountId,
            repo: "\(project)/\(dto.repository.name)",
            number: dto.pullRequestId,
            title: dto.title,
            authorId: dto.createdBy.id,
            authorName: dto.createdBy.displayName,
            isDraft: dto.isDraft ?? false,
            createdAt: createdAt,
            webURL: webURL,
            state: state,
            closedAt: dto.closedDate.flatMap(DateParsing.parse)
        )
    }

    private func authorizationHeader() async throws -> String {
        let token = try await tokenSource.token()
        switch authMethod {
        case .pat: return "Basic " + Data(":\(token)".utf8).base64EncodedString()
        case .cli: return "Bearer \(token)"
        }
    }

    private func get<T: Decodable>(_ url: URL, apiVersion: String = "7.1", query: [URLQueryItem] = []) async throws -> T {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        components.queryItems = query + [URLQueryItem(name: "api-version", value: apiVersion)]
        var request = URLRequest(url: components.url!)
        let authorization = try await authorizationHeader()
        request.setValue(authorization, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await http.send(request)
        try HTTPStatus.check(response, now: now())
        return try JSONDecoding.decode(T.self, from: data)
    }
}

private struct ValueList<T: Decodable>: Decodable {
    let value: [T]
}

private struct ItemDTO: Decodable {
    let path: String
    let isFolder: Bool?
    let content: String?
}

private struct ConnectionData: Decodable {
    static let anonymousUserId = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"

    struct User: Decodable {
        let id: String
        let providerDisplayName: String?
    }
    let authenticatedUser: User
}

private struct ProjectDTO: Decodable {
    let name: String
}

private struct RepositoryDTO: Decodable {
    let name: String
}

private struct PullRequestDTO: Decodable {
    struct Identity: Decodable {
        let id: String
        let displayName: String
    }

    struct Repository: Decodable {
        struct Project: Decodable { let name: String }
        let name: String
        let project: Project
    }

    let pullRequestId: Int
    let title: String
    let isDraft: Bool?
    let status: String?
    let closedDate: String?
    let creationDate: String
    let createdBy: Identity
    let repository: Repository
}

private struct RefDTO: Decodable {
    struct Creator: Decodable { let displayName: String }
    let name: String
    let creator: Creator?
}
