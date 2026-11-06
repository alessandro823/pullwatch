public import Foundation

/// Wat een item in de geschiedenis is: een pull request of een tag.
public enum ItemKind: String, Codable, Sendable {
    case pullRequest, tag
}

/// De stand van een pull request.
public enum PRState: String, Codable, Sendable, CaseIterable {
    case open, merged, closed
}

/// Een pull request zoals een provider hem geeft.
public struct PullRequest: Codable, Hashable, Sendable {
    public let accountId: UUID
    public let repo: String
    public let number: Int
    public var title: String
    public let authorId: String
    public let authorName: String
    /// De foto van de auteur zoals de provider hem geeft (GitHub `avatar_url`, ook van een bot als
    /// `github-actions[bot]`; GitLab `avatar_url`). Nil bij Azure DevOps, waar de foto een token
    /// nodig heeft, en in geschiedenis van vóór dit veld tot de PR opnieuw opgehaald is.
    public var authorAvatarURL: URL?
    /// Draft of klaar voor review; de geschiedenis werkt het bij (`History.merge(synced:)`).
    public var isDraft: Bool
    public let createdAt: Date
    public let webURL: URL
    public var state: PRState
    public var closedAt: Date?
    /// Wie er naast de auteur aan meewerkte (commit-auteurs en `Co-authored-by:`-trailers),
    /// zonder de auteur zelf en zonder bots. Leeg zolang het niet opgehaald is.
    public var coAuthors: [Person]
    /// Verandert als de PR verandert (GitHub: `updated_at`, Azure DevOps: de laatste commit van de
    /// bronbranch); `PollEngine` haalt de co-auteurs alleen opnieuw op als dit anders is.
    public var revision: String?
    /// De checks op de laatste commit (CI); nil zolang ze niet opgehaald zijn. `PollEngine` haalt
    /// ze alleen voor open en net gemergde PR's, en alleen opnieuw als de PR veranderde of de
    /// checks nog lopen.
    public var checks: PRChecks?
    /// Of en waar de PR in de rij staat om vanzelf te mergen (merge queue, merge train,
    /// auto-complete); nil als hij er niet in staat of de dienst het niet weet. Telt alleen
    /// zolang de PR open is.
    public var mergeQueue: MergeQueueEntry?
    /// Of de PR uit de rij ging zonder te mergen, wanneer en waarom (`MergeQueueExit`); weer in
    /// de rij komen wist het. Telt alleen zolang de PR open is en niet in de rij staat.
    public var leftQueue: MergeQueueExit?

    public init(
        accountId: UUID,
        repo: String,
        number: Int,
        title: String,
        authorId: String,
        authorName: String,
        authorAvatarURL: URL? = nil,
        isDraft: Bool,
        createdAt: Date,
        webURL: URL,
        state: PRState = .open,
        closedAt: Date? = nil,
        coAuthors: [Person] = [],
        revision: String? = nil,
        checks: PRChecks? = nil,
        mergeQueue: MergeQueueEntry? = nil,
        leftQueue: MergeQueueExit? = nil
    ) {
        self.accountId = accountId
        self.repo = repo
        self.number = number
        self.title = title
        self.authorId = authorId
        self.authorName = authorName
        self.authorAvatarURL = authorAvatarURL
        self.isDraft = isDraft
        self.createdAt = createdAt
        self.webURL = webURL
        self.state = state
        self.closedAt = closedAt
        self.coAuthors = coAuthors
        self.revision = revision
        self.checks = checks
        self.mergeQueue = mergeQueue
        self.leftQueue = leftQueue
    }

    private enum CodingKeys: String, CodingKey {
        case accountId, repo, number, title, authorId, authorName, isDraft, createdAt, webURL, state, closedAt, coAuthors, revision, checks
        case mergeQueue, authorAvatarURL, leftQueue
    }

    /// Oude JSON heeft geen `state`/`closedAt`: dan is de PR open. Zonder `coAuthors` (van vóór de
    /// co-auteurs) is die lijst leeg.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        accountId = try c.decode(UUID.self, forKey: .accountId)
        repo = try c.decode(String.self, forKey: .repo)
        number = try c.decode(Int.self, forKey: .number)
        title = try c.decode(String.self, forKey: .title)
        authorId = try c.decode(String.self, forKey: .authorId)
        authorName = try c.decode(String.self, forKey: .authorName)
        // Ontbreekt in JSON van vóór de foto's van de API.
        authorAvatarURL = try c.decodeIfPresent(URL.self, forKey: .authorAvatarURL)
        isDraft = try c.decode(Bool.self, forKey: .isDraft)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        webURL = try c.decode(URL.self, forKey: .webURL)
        state = try c.decodeIfPresent(PRState.self, forKey: .state) ?? .open
        closedAt = try c.decodeIfPresent(Date.self, forKey: .closedAt)
        coAuthors = try c.decodeIfPresent([Person].self, forKey: .coAuthors) ?? []
        revision = try c.decodeIfPresent(String.self, forKey: .revision)
        // Ontbreekt in JSON van vóór de checks.
        checks = try c.decodeIfPresent(PRChecks.self, forKey: .checks)
        // Ontbreekt in JSON van vóór de wachtrij.
        mergeQueue = try c.decodeIfPresent(MergeQueueEntry.self, forKey: .mergeQueue)
        // Ontbreekt in JSON van vóór de melding "uit de rij".
        leftQueue = try c.decodeIfPresent(MergeQueueExit.self, forKey: .leftQueue)
    }

    /// Open, niet in de rij, en eerder uit de rij gegaan zonder te mergen.
    public var hasLeftQueue: Bool { state == .open && mergeQueue == nil && leftQueue != nil }

    /// Open en echt in een merge queue of merge train, zoals GitHub de PR dan toont. Auto-merge
    /// en auto-complete tellen niet: die PR is nog gewoon open. Een draft kan niet mergen en telt
    /// dus ook niet.
    public var isQueued: Bool { state == .open && !isDraft && mergeQueue?.kind.isQueue == true }

    /// De auteur en daarna de co-auteurs, zoals ze in lijsten en statistieken heten.
    var contributorNames: [String] { [authorName] + coAuthors.map(\.handle) }

    public var dedupKey: String { "\(accountId.uuidString):\(repo):\(number)" }
}

/// Iemand die aan een PR meewerkte: een GitHub-gebruiker (login, foto) of alleen een naam en
/// e-mailadres uit een commit.
public struct Person: Codable, Hashable, Sendable {
    /// Naam uit de commit of trailer; bij een GitHub-gebruiker zonder naam de login.
    public var name: String
    /// GitHub-login (zonder @), als bekend.
    public var login: String?
    public var email: String?
    public var avatarURL: URL?

    public init(name: String, login: String? = nil, email: String? = nil, avatarURL: URL? = nil) {
        self.name = name
        self.login = login
        self.email = email
        self.avatarURL = avatarURL
    }

    /// Zoals de persoon in lijsten heet: de login (net als `PullRequest.authorName` bij GitHub),
    /// anders de naam.
    public var handle: String { login ?? name }
}
