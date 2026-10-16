import Foundation

public enum ProviderKind: String, Codable, Hashable, Sendable, CaseIterable {
    case azureDevOps, gitHub
}

public enum ItemKind: String, Codable, Sendable {
    case pullRequest, tag
}

public enum AuthMethod: String, Codable, Hashable, Sendable, CaseIterable {
    case pat, cli
}

/// Alleen nog gebruikt om oude configuratie te migreren.
public enum FilterMode: String, Codable, Hashable, Sendable, CaseIterable {
    case allow, deny
}

/// Wat er voor één repo gevolgd wordt.
public struct WatchSet: Codable, Hashable, Sendable {
    public var prs: Bool
    public var tags: Bool

    public init(prs: Bool, tags: Bool) {
        self.prs = prs
        self.tags = tags
    }

    public static let none = WatchSet(prs: false, tags: false)
    public static let prs = WatchSet(prs: true, tags: false)
    public static let tags = WatchSet(prs: false, tags: true)
    public static let both = WatchSet(prs: true, tags: true)
}

/// Wat er gevolgd wordt voor repo's zonder eigen instelling. Tags staan nooit standaard aan.
public enum NewRepoDefault: String, Codable, CaseIterable, Sendable {
    case none, prs

    public var watchSet: WatchSet {
        switch self {
        case .none: return .none
        case .prs: return .prs
        }
    }
}

/// Gedeelde (de)codering van de repo-instellingen voor `Account` en `FilterSettings`,
/// inclusief migratie van het oude `filterMode`/`repos`-formaat.
enum RepoWatchCoding {
    enum Keys: String, CodingKey {
        case repoWatch, newRepoDefault
    }

    enum LegacyKeys: String, CodingKey {
        case filterMode, repos
    }

    static func decode(from decoder: any Decoder) throws -> (repoWatch: [String: WatchSet], newRepoDefault: NewRepoDefault) {
        let legacy = try decoder.container(keyedBy: LegacyKeys.self)
        if let mode = try legacy.decodeIfPresent(FilterMode.self, forKey: .filterMode) {
            let repos = try legacy.decodeIfPresent([String].self, forKey: .repos) ?? []
            switch mode {
            case .deny: return (Dictionary(repos.map { ($0, WatchSet.none) }, uniquingKeysWith: { a, _ in a }), .prs)
            case .allow: return (Dictionary(repos.map { ($0, WatchSet.prs) }, uniquingKeysWith: { a, _ in a }), .none)
            }
        }
        let c = try decoder.container(keyedBy: Keys.self)
        return (
            try c.decodeIfPresent([String: WatchSet].self, forKey: .repoWatch) ?? [:],
            try c.decodeIfPresent(NewRepoDefault.self, forKey: .newRepoDefault) ?? .prs
        )
    }

    static func lookup(_ repo: String, in repoWatch: [String: WatchSet], default fallback: NewRepoDefault) -> WatchSet {
        if let exact = repoWatch[repo] { return exact }
        for (key, value) in repoWatch where key.caseInsensitiveCompare(repo) == .orderedSame {
            return value
        }
        return fallback.watchSet
    }
}

public struct Account: Codable, Identifiable, Hashable, Sendable {
    public let id: UUID
    public var kind: ProviderKind
    public var displayName: String
    /// Azure DevOps-organisatie of GitHub-owner (user of org).
    public var organization: String
    public var authMethod: AuthMethod
    /// Per repo wat gevolgd wordt. Azure DevOps: "project/repo", GitHub: "owner/repo".
    public var repoWatch: [String: WatchSet]
    /// Geldt voor repo's die niet in `repoWatch` staan.
    public var newRepoDefault: NewRepoDefault
    public var includeDrafts: Bool
    public var hideOwn: Bool

    public init(
        id: UUID = UUID(),
        kind: ProviderKind,
        displayName: String,
        organization: String,
        authMethod: AuthMethod,
        repoWatch: [String: WatchSet] = [:],
        newRepoDefault: NewRepoDefault = .prs,
        includeDrafts: Bool = false,
        hideOwn: Bool = true
    ) {
        self.id = id
        self.kind = kind
        self.displayName = displayName
        self.organization = organization
        self.authMethod = authMethod
        self.repoWatch = repoWatch
        self.newRepoDefault = newRepoDefault
        self.includeDrafts = includeDrafts
        self.hideOwn = hideOwn
    }

    private enum CodingKeys: String, CodingKey {
        case id, kind, displayName, organization, authMethod, repoWatch, newRepoDefault, includeDrafts, hideOwn
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        kind = try c.decode(ProviderKind.self, forKey: .kind)
        displayName = try c.decode(String.self, forKey: .displayName)
        organization = try c.decode(String.self, forKey: .organization)
        authMethod = try c.decode(AuthMethod.self, forKey: .authMethod)
        (repoWatch, newRepoDefault) = try RepoWatchCoding.decode(from: decoder)
        includeDrafts = try c.decode(Bool.self, forKey: .includeDrafts)
        hideOwn = try c.decode(Bool.self, forKey: .hideOwn)
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(kind, forKey: .kind)
        try c.encode(displayName, forKey: .displayName)
        try c.encode(organization, forKey: .organization)
        try c.encode(authMethod, forKey: .authMethod)
        try c.encode(repoWatch, forKey: .repoWatch)
        try c.encode(newRepoDefault, forKey: .newRepoDefault)
        try c.encode(includeDrafts, forKey: .includeDrafts)
        try c.encode(hideOwn, forKey: .hideOwn)
    }

    /// Wat er voor deze repo gevolgd wordt (hoofdletterongevoelig).
    public func watch(for repo: String) -> WatchSet {
        RepoWatchCoding.lookup(repo, in: repoWatch, default: newRepoDefault)
    }

    /// Schrijft wat er voor deze repo gevolgd wordt. Hergebruikt een bestaande key
    /// (hoofdletterongevoelig); een entry gelijk aan de standaard zonder tags verdwijnt.
    public mutating func setWatch(_ set: WatchSet, for repo: String) {
        let key = repoWatch.keys.first { $0.caseInsensitiveCompare(repo) == .orderedSame } ?? repo
        if set == newRepoDefault.watchSet && !set.tags {
            repoWatch[key] = nil
        } else {
            repoWatch[key] = set
        }
    }

    /// Voegt repo's van de provider en uit de config samen, hoofdletterongevoelig ontdubbeld
    /// (de schrijfwijze van de provider wint) en hoofdletterongevoelig gesorteerd.
    public static func mergedRepoNames(available: [String], configured: [String]) -> [String] {
        var byLowercase: [String: String] = [:]
        for name in configured { byLowercase[name.lowercased()] = name }
        for name in available { byLowercase[name.lowercased()] = name }
        return byLowercase.values.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    /// Repo's waarvan de tags gevolgd worden, gesorteerd en hoofdletterongevoelig ontdubbeld
    /// (de eerste schrijfwijze in sorteervolgorde wint), zodat een repo niet dubbel opgehaald wordt.
    public var tagRepos: [String] {
        var seen: Set<String> = []
        return repoWatch.filter { $0.value.tags }.keys.sorted().filter { seen.insert($0.lowercased()).inserted }
    }
}

public enum PRState: String, Codable, Sendable, CaseIterable {
    case open, merged, closed
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
    public var state: PRState
    public var closedAt: Date?

    public init(
        accountId: UUID,
        repo: String,
        number: Int,
        title: String,
        authorId: String,
        authorName: String,
        isDraft: Bool,
        createdAt: Date,
        webURL: URL,
        state: PRState = .open,
        closedAt: Date? = nil
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
        self.state = state
        self.closedAt = closedAt
    }

    private enum CodingKeys: String, CodingKey {
        case accountId, repo, number, title, authorId, authorName, isDraft, createdAt, webURL, state, closedAt
    }

    /// Oude JSON heeft geen `state`/`closedAt`: dan is de PR open.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        accountId = try c.decode(UUID.self, forKey: .accountId)
        repo = try c.decode(String.self, forKey: .repo)
        number = try c.decode(Int.self, forKey: .number)
        title = try c.decode(String.self, forKey: .title)
        authorId = try c.decode(String.self, forKey: .authorId)
        authorName = try c.decode(String.self, forKey: .authorName)
        isDraft = try c.decode(Bool.self, forKey: .isDraft)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        webURL = try c.decode(URL.self, forKey: .webURL)
        state = try c.decodeIfPresent(PRState.self, forKey: .state) ?? .open
        closedAt = try c.decodeIfPresent(Date.self, forKey: .closedAt)
    }

    public var dedupKey: String { "\(accountId.uuidString):\(repo):\(number)" }
}

public struct Tag: Codable, Hashable, Sendable {
    public let accountId: UUID
    public let repo: String
    public let name: String
    public let authorName: String?
    public let webURL: URL

    public init(accountId: UUID, repo: String, name: String, authorName: String?, webURL: URL) {
        self.accountId = accountId
        self.repo = repo
        self.name = name
        self.authorName = authorName
        self.webURL = webURL
    }

    public var dedupKey: String { "\(accountId.uuidString):\(repo.lowercased()):tag:\(name)" }
}

/// Resultaat van `PRProvider.tags(in:)`.
public struct TagFetch: Equatable, Sendable {
    public var tags: [Tag]
    /// Repo's die overgeslagen zijn (404 of geen toegang); exact de doorgegeven repo-strings.
    public var unavailableRepos: [String]

    public init(tags: [Tag], unavailableRepos: [String] = []) {
        self.tags = tags
        self.unavailableRepos = unavailableRepos
    }
}
