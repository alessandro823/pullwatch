public import Foundation

/// De branches van één gevolgde repo zoals ze nu zijn, voor de boom in Branches: de standaard-
/// branch, elke branch met zijn ouder en hoe ver hij daarvan af staat, en de branches die
/// verdwenen (gemerged of weggehaald), zolang de bewaartermijn loopt. `PollEngine` houdt ze bij
/// in seen.json, want een repo die niet veranderde wordt niet opnieuw gelezen.
public struct RepoBranches: Codable, Equatable, Sendable, Identifiable {
    public let accountId: UUID
    /// Exact de repo-string van de laatste poll.
    public var repo: String
    /// Zoals de dienst hem noemt; anders geraden (`guessedDefault`), of nil zonder branches.
    public var defaultBranch: String?
    /// Op naam.
    public var branches: [String: BranchInfo]
    /// De laatste keer dat de repo gelezen is (ook als hij niet veranderde); voor het prunen.
    public var checkedAt: Date

    public var id: String { "\(accountId.uuidString):\(repo.lowercased())" }

    public init(accountId: UUID, repo: String, defaultBranch: String? = nil, branches: [String: BranchInfo] = [:], checkedAt: Date) {
        self.accountId = accountId
        self.repo = repo
        self.defaultBranch = defaultBranch
        self.branches = branches
        self.checkedAt = checkedAt
    }

    /// De branches die er nu zijn.
    public var live: [BranchInfo] { branches.values.filter { $0.removedAt == nil } }

    /// De standaardbranch als de dienst hem niet noemt: de eerste van de gebruikelijke namen die
    /// bestaat, anders nil.
    public static func guessedDefault(among names: some Collection<String>) -> String? {
        ["main", "master", "develop", "trunk"].first { names.contains($0) }
    }
}

/// Eén branch in `RepoBranches`.
public struct BranchInfo: Codable, Equatable, Sendable, Identifiable {
    /// Waar de ouder van een branch vandaan komt.
    public enum ParentSource: String, Codable, Sendable {
        /// De doelbranch van een open PR vanaf deze branch.
        case pullRequest
        /// Uit de geschiedenis: de branch waar deze de minste commits voor ligt.
        case history
        /// Niets beters bekend: de standaardbranch.
        case defaultBranch
    }

    public var name: String
    public var sha: String
    public var authorName: String?
    public var authorAvatarURL: URL?
    public var isOwn: Bool
    /// De datum van de laatste commit, anders wanneer Pullwatch de push zag.
    public var lastPushAt: Date?
    /// De branch zelf bij de dienst.
    public var webURL: URL
    /// nil voor de standaardbranch, en zolang de ouder nog niet bepaald is.
    public var parent: String?
    public var parentSource: ParentSource?
    /// Tegen de ouder en tegen de standaardbranch; nil zolang niet vergeleken.
    public var againstParent: BranchComparison?
    public var againstDefault: BranchComparison?
    /// De heads waartegen `againstParent` en `againstDefault` vergeleken zijn (`"oud...nieuw"`),
    /// zodat alleen een verandering een nieuwe vergelijking kost.
    public var comparedParent: String?
    public var comparedDefault: String?
    /// Het nummer van een open PR vanaf deze branch.
    public var pullRequest: Int?
    /// Wanneer de branch verdween; nil zolang hij er is.
    public var removedAt: Date?
    /// Verdwenen en zijn laatste commit zat al in de standaardbranch.
    public var merged: Bool

    public var id: String { name }

    public init(
        name: String, sha: String, authorName: String? = nil, authorAvatarURL: URL? = nil, isOwn: Bool = false,
        lastPushAt: Date? = nil, webURL: URL, parent: String? = nil, parentSource: ParentSource? = nil,
        againstParent: BranchComparison? = nil, againstDefault: BranchComparison? = nil, pullRequest: Int? = nil,
        removedAt: Date? = nil, merged: Bool = false
    ) {
        self.name = name
        self.sha = sha
        self.authorName = authorName
        self.authorAvatarURL = authorAvatarURL
        self.isOwn = isOwn
        self.lastPushAt = lastPushAt
        self.webURL = webURL
        self.parent = parent
        self.parentSource = parentSource
        self.againstParent = againstParent
        self.againstDefault = againstDefault
        self.pullRequest = pullRequest
        self.removedAt = removedAt
        self.merged = merged
    }
}
