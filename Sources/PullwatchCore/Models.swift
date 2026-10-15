import Foundation

public enum ProviderKind: String, Codable, Hashable, Sendable, CaseIterable {
    case azureDevOps, gitHub
}

public enum AuthMethod: String, Codable, Hashable, Sendable, CaseIterable {
    case pat, cli
}

public enum FilterMode: String, Codable, Hashable, Sendable, CaseIterable {
    case allow, deny
}

public struct Account: Codable, Identifiable, Hashable, Sendable {
    public let id: UUID
    public var kind: ProviderKind
    public var displayName: String
    /// Azure DevOps-organisatie of GitHub-owner (user of org).
    public var organization: String
    public var authMethod: AuthMethod
    public var filterMode: FilterMode
    /// Azure DevOps: "project/repo", GitHub: "owner/repo".
    public var repos: [String]
    public var includeDrafts: Bool
    public var hideOwn: Bool

    public init(
        id: UUID = UUID(),
        kind: ProviderKind,
        displayName: String,
        organization: String,
        authMethod: AuthMethod,
        filterMode: FilterMode = .deny,
        repos: [String] = [],
        includeDrafts: Bool = false,
        hideOwn: Bool = true
    ) {
        self.id = id
        self.kind = kind
        self.displayName = displayName
        self.organization = organization
        self.authMethod = authMethod
        self.filterMode = filterMode
        self.repos = repos
        self.includeDrafts = includeDrafts
        self.hideOwn = hideOwn
    }
}

public struct PullRequest: Codable, Hashable, Sendable {
    public let accountId: UUID
    public let repo: String
    public let number: Int
    public let title: String
    public let authorId: String
    public let authorName: String
    public let isDraft: Bool
    public let createdAt: Date
    public let webURL: URL

    public init(
        accountId: UUID,
        repo: String,
        number: Int,
        title: String,
        authorId: String,
        authorName: String,
        isDraft: Bool,
        createdAt: Date,
        webURL: URL
    ) {
        self.accountId = accountId
        self.repo = repo
        self.number = number
        self.title = title
        self.authorId = authorId
        self.authorName = authorName
        self.isDraft = isDraft
        self.createdAt = createdAt
        self.webURL = webURL
    }

    public var dedupKey: String { "\(accountId.uuidString):\(repo):\(number)" }
}
