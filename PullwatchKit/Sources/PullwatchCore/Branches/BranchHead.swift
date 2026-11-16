public import Foundation

/// De kop van één branch zoals de dienst hem nu meldt.
public struct BranchHead: Codable, Hashable, Sendable {
    /// Exact de doorgegeven repo-string.
    public let repo: String
    /// Branchnaam zonder `refs/heads/`.
    public let name: String
    public let sha: String
    public let committedAt: Date?
    /// Naam uit git, of de login als die er is.
    public let authorName: String?
    /// Login of account-id, vergeleken met `currentUserId()`.
    public let authorId: String?
    public let authorEmail: String?
    public let authorAvatarURL: URL?
    /// De branch zelf bij de dienst.
    public let webURL: URL

    public init(
        repo: String, name: String, sha: String, committedAt: Date? = nil, authorName: String? = nil,
        authorId: String? = nil, authorEmail: String? = nil, authorAvatarURL: URL? = nil, webURL: URL
    ) {
        self.repo = repo
        self.name = name
        self.sha = sha
        self.committedAt = committedAt
        self.authorName = authorName
        self.authorId = authorId
        self.authorEmail = authorEmail
        self.authorAvatarURL = authorAvatarURL
        self.webURL = webURL
    }
}

/// Wat een provider bij één ophaalronde van de branches teruggeeft.
public struct BranchFetch: Equatable, Sendable {
    public var heads: [BranchHead]
    /// Repo's waarvan de branches niet op te halen waren.
    public var unavailableRepos: [String]
    /// Per repo een vingerafdruk van de branchlijst, om de volgende ronde over te slaan.
    public var fingerprints: [String: String]
    /// Repo's die sinds de vorige vingerafdruk niet veranderden.
    public var unchangedRepos: [String]
    /// Per gelezen repo de standaardbranch, als de dienst hem in hetzelfde antwoord noemt.
    public var defaultBranches: [String: String]

    public init(
        heads: [BranchHead] = [], unavailableRepos: [String] = [], fingerprints: [String: String] = [:],
        unchangedRepos: [String] = [], defaultBranches: [String: String] = [:]
    ) {
        self.heads = heads
        self.unavailableRepos = unavailableRepos
        self.fingerprints = fingerprints
        self.unchangedRepos = unchangedRepos
        self.defaultBranches = defaultBranches
    }
}

/// Hoeveel commits een branch voor of achter ligt op een andere.
public struct BranchComparison: Codable, Hashable, Sendable {
    public let ahead: Int
    public let behind: Int

    public init(ahead: Int, behind: Int) {
        self.ahead = ahead
        self.behind = behind
    }
}
