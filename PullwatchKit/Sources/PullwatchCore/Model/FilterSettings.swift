import Foundation

/// De filter-relevante instellingen van een account. Wordt ook bewaard in `SeenState`
/// om te detecteren welke PR's pas door een instellingswijziging zichtbaar worden.
public struct FilterSettings: Codable, Hashable, Sendable {
    public var kind: ProviderKind
    public var organization: String
    public var repoWatch: [String: WatchSet]
    public var newRepoDefault: NewRepoDefault
    public var showDrafts: Bool
    public var includeDrafts: Bool
    public var hideOwn: Bool
    /// `Account.extraRepos`, lowercased en gesorteerd; leeg in oude JSON.
    public var extraRepos: [String]

    public init(
        kind: ProviderKind,
        organization: String,
        repoWatch: [String: WatchSet],
        newRepoDefault: NewRepoDefault,
        showDrafts: Bool = true,
        includeDrafts: Bool,
        hideOwn: Bool,
        extraRepos: [String] = []
    ) {
        self.kind = kind
        self.organization = organization
        self.repoWatch = repoWatch
        self.newRepoDefault = newRepoDefault
        self.showDrafts = showDrafts
        self.includeDrafts = includeDrafts
        self.hideOwn = hideOwn
        self.extraRepos = Array(Set(extraRepos.map { $0.lowercased() })).sorted()
    }

    private enum CodingKeys: String, CodingKey {
        case kind, organization, repoWatch, newRepoDefault, showDrafts, includeDrafts, hideOwn, extraRepos
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = try c.decode(ProviderKind.self, forKey: .kind)
        organization = try c.decode(String.self, forKey: .organization)
        (repoWatch, newRepoDefault) = try RepoWatchCoding.decode(from: decoder)
        includeDrafts = try c.decode(Bool.self, forKey: .includeDrafts)
        // Van vóór `showDrafts` liet `includeDrafts` drafts ook zien: zo blijft de vergelijking
        // met de vorige instellingen kloppen en haalt de eerste sync de drafts alsnog op.
        showDrafts = try c.decodeIfPresent(Bool.self, forKey: .showDrafts) ?? includeDrafts
        hideOwn = try c.decode(Bool.self, forKey: .hideOwn)
        extraRepos = try c.decodeIfPresent([String].self, forKey: .extraRepos) ?? []
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(kind, forKey: .kind)
        try c.encode(organization, forKey: .organization)
        try c.encode(repoWatch, forKey: .repoWatch)
        try c.encode(newRepoDefault, forKey: .newRepoDefault)
        try c.encode(showDrafts, forKey: .showDrafts)
        try c.encode(includeDrafts, forKey: .includeDrafts)
        try c.encode(hideOwn, forKey: .hideOwn)
        if !extraRepos.isEmpty { try c.encode(extraRepos, forKey: .extraRepos) }
    }

    /// Kwam deze repo onder deze instellingen al binnen? Bij GitHub alleen repo's van de gevolgde
    /// eigenaren en de losse repo's; Azure DevOps haalt de hele organisatie op. Zo meldt een net
    /// toegevoegde losse repo zijn bestaande PR's niet als nieuw.
    func covers(repo: String) -> Bool {
        guard kind == .gitHub else { return true }
        let owner = repo.split(separator: "/", maxSplits: 1).first.map(String.init) ?? repo
        let owners = organization.split(separator: ",").map(String.init)
        return owners.contains { $0.caseInsensitiveCompare(owner) == .orderedSame }
            || extraRepos.contains(repo.lowercased())
    }

    public func watch(for repo: String) -> WatchSet {
        RepoWatchCoding.lookup(repo, in: repoWatch, default: newRepoDefault)
    }

    func sameSource(as other: FilterSettings) -> Bool {
        kind == other.kind
            && organization.caseInsensitiveCompare(other.organization) == .orderedSame
    }

    /// Of een geschiedenis-sync onder `other` dezelfde PR's oplevert: zelfde bron, zelfde
    /// PR-vinkjes per repo (hoofdletterongevoelig) en standaard, drafts tonen en melden, eigen PR's, en dezelfde
    /// losse repo's (een net toegevoegde heeft zijn geschiedenis nog niet). Tag-vinkjes tellen niet mee.
    func sameSyncScope(as other: FilterSettings) -> Bool {
        sameSource(as: other)
            && newRepoDefault == other.newRepoDefault
            && showDrafts == other.showDrafts
            && includeDrafts == other.includeDrafts
            && hideOwn == other.hideOwn
            && prOverrides == other.prOverrides
            && extraRepos == other.extraRepos
    }

    /// PR-vinkjes per repo (lowercased) die afwijken van de standaard; een entry gelijk aan de
    /// standaard gedraagt zich als een ontbrekende entry.
    private var prOverrides: [String: Bool] {
        var result: [String: Bool] = [:]
        for (repo, set) in repoWatch where set.prs != newRepoDefault.watchSet.prs {
            result[repo.lowercased()] = set.prs
        }
        return result
    }
}

extension Account {
    var filterSettings: FilterSettings {
        FilterSettings(
            kind: kind,
            // Alle eigenaren: een andere keuze telt als een andere instelling (opnieuw beginnen).
            organization: owners.joined(separator: ","),
            repoWatch: repoWatch,
            newRepoDefault: newRepoDefault,
            showDrafts: showDrafts,
            includeDrafts: includeDrafts,
            hideOwn: hideOwn,
            extraRepos: extraRepos
        )
    }
}
