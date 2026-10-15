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
        let data: ConnectionData = try await get(baseURL.appending(path: "_apis/connectionData"), apiVersion: "7.1-preview")
        return data.authenticatedUser.id
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
            webURL: webURL
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

private struct ConnectionData: Decodable {
    struct User: Decodable { let id: String }
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
    let creationDate: String
    let createdBy: Identity
    let repository: Repository
}
