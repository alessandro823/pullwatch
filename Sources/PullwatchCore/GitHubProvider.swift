import Foundation

public actor GitHubProvider: PRProvider {
    private enum OwnerKind { case organization, user }

    private let accountId: UUID
    private let owner: String
    private let tokenSource: any TokenSource
    private let http: any HTTPClient
    private let now: @Sendable () -> Date
    private let apiBase = URL(string: "https://api.github.com")!
    private let pageSize = 100
    private let maxPages = 10
    private var ownerKind: OwnerKind?

    public init(
        accountId: UUID,
        owner: String,
        tokenSource: any TokenSource,
        http: any HTTPClient,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.accountId = accountId
        self.owner = owner
        self.tokenSource = tokenSource
        self.http = http
        self.now = now
    }

    public func currentUserId() async throws -> String {
        let user: UserDTO = try await get(apiBase.appending(path: "user"))
        return user.login
    }

    public func listRepos() async throws -> [String] {
        let url: URL
        var query: [URLQueryItem] = []
        switch try await resolveOwnerKind() {
        case .organization:
            url = apiBase.appending(path: "orgs").appending(path: owner).appending(path: "repos")
        case .user:
            let login = try await currentUserId()
            if login.caseInsensitiveCompare(owner) == .orderedSame {
                // /users/{owner}/repos toont geen private repos; voor jezelf /user/repos gebruiken.
                url = apiBase.appending(path: "user/repos")
                query = [URLQueryItem(name: "affiliation", value: "owner")]
            } else {
                url = apiBase.appending(path: "users").appending(path: owner).appending(path: "repos")
            }
        }

        var names: [String] = []
        for page in 1...maxPages {
            let repos: [RepoDTO] = try await get(url, query: query + [
                URLQueryItem(name: "per_page", value: String(pageSize)),
                URLQueryItem(name: "page", value: String(page)),
            ])
            names += repos.map(\.fullName)
            if repos.count < pageSize { break }
        }
        return names.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    public func openPullRequests() async throws -> [PullRequest] {
        let qualifier = try await resolveOwnerKind() == .organization ? "org" : "user"
        var result: [PullRequest] = []
        for page in 1...maxPages {
            let response: SearchDTO = try await get(apiBase.appending(path: "search/issues"), query: [
                URLQueryItem(name: "q", value: "is:pr is:open \(qualifier):\(owner)"),
                URLQueryItem(name: "per_page", value: String(pageSize)),
                URLQueryItem(name: "page", value: String(page)),
            ])
            for item in response.items {
                result.append(try makePullRequest(item))
            }
            if response.items.count < pageSize || result.count >= response.totalCount { break }
        }
        return result
    }

    public func invalidateCredentials() async {
        await tokenSource.invalidate()
    }

    private func resolveOwnerKind() async throws -> OwnerKind {
        if let ownerKind { return ownerKind }
        let info: OwnerDTO = try await get(apiBase.appending(path: "users").appending(path: owner))
        let kind: OwnerKind = info.type == "Organization" ? .organization : .user
        ownerKind = kind
        return kind
    }

    private func makePullRequest(_ item: SearchDTO.Item) throws -> PullRequest {
        guard let createdAt = DateParsing.parse(item.createdAt) else {
            throw ProviderError.decoding("created_at \(item.createdAt)")
        }
        guard let webURL = URL(string: item.htmlUrl),
              let repoURL = URL(string: item.repositoryUrl) else {
            throw ProviderError.decoding("url in PR \(item.number)")
        }
        let repo = repoURL.pathComponents.suffix(2).joined(separator: "/")
        return PullRequest(
            accountId: accountId,
            repo: repo,
            number: item.number,
            title: item.title,
            authorId: item.user.login,
            authorName: item.user.login,
            isDraft: item.draft ?? false,
            createdAt: createdAt,
            webURL: webURL
        )
    }

    private func get<T: Decodable>(_ url: URL, query: [URLQueryItem] = []) async throws -> T {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        if !query.isEmpty { components.queryItems = query }
        var request = URLRequest(url: components.url!)
        let token = try await tokenSource.token()
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        let (data, response) = try await http.send(request)
        try HTTPStatus.check(response, now: now())
        return try JSONDecoding.decode(T.self, from: data, snakeCase: true)
    }
}

private struct UserDTO: Decodable {
    let login: String
}

private struct OwnerDTO: Decodable {
    let type: String
}

private struct RepoDTO: Decodable {
    let fullName: String
}

private struct SearchDTO: Decodable {
    struct Item: Decodable {
        let number: Int
        let title: String
        let createdAt: String
        let draft: Bool?
        let user: UserDTO
        let htmlUrl: String
        let repositoryUrl: String
    }

    let totalCount: Int
    let items: [Item]
}
