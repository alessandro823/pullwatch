import Foundation

/// De filter-relevante instellingen van een account. Wordt ook bewaard in `SeenState`
/// om te detecteren welke PR's pas door een instellingswijziging zichtbaar worden.
public struct FilterSettings: Codable, Hashable, Sendable {
    public var kind: ProviderKind
    public var organization: String
    public var repoWatch: [String: WatchSet]
    public var newRepoDefault: NewRepoDefault
    public var includeDrafts: Bool
    public var hideOwn: Bool

    public init(
        kind: ProviderKind,
        organization: String,
        repoWatch: [String: WatchSet],
        newRepoDefault: NewRepoDefault,
        includeDrafts: Bool,
        hideOwn: Bool
    ) {
        self.kind = kind
        self.organization = organization
        self.repoWatch = repoWatch
        self.newRepoDefault = newRepoDefault
        self.includeDrafts = includeDrafts
        self.hideOwn = hideOwn
    }

    private enum CodingKeys: String, CodingKey {
        case kind, organization, repoWatch, newRepoDefault, includeDrafts, hideOwn
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = try c.decode(ProviderKind.self, forKey: .kind)
        organization = try c.decode(String.self, forKey: .organization)
        (repoWatch, newRepoDefault) = try RepoWatchCoding.decode(from: decoder)
        includeDrafts = try c.decode(Bool.self, forKey: .includeDrafts)
        hideOwn = try c.decode(Bool.self, forKey: .hideOwn)
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(kind, forKey: .kind)
        try c.encode(organization, forKey: .organization)
        try c.encode(repoWatch, forKey: .repoWatch)
        try c.encode(newRepoDefault, forKey: .newRepoDefault)
        try c.encode(includeDrafts, forKey: .includeDrafts)
        try c.encode(hideOwn, forKey: .hideOwn)
    }

    public func watch(for repo: String) -> WatchSet {
        RepoWatchCoding.lookup(repo, in: repoWatch, default: newRepoDefault)
    }

    public func sameSource(as other: FilterSettings) -> Bool {
        kind == other.kind
            && organization.caseInsensitiveCompare(other.organization) == .orderedSame
    }
}

extension Account {
    public var filterSettings: FilterSettings {
        FilterSettings(
            kind: kind,
            organization: organization,
            repoWatch: repoWatch,
            newRepoDefault: newRepoDefault,
            includeDrafts: includeDrafts,
            hideOwn: hideOwn
        )
    }
}

public enum PRFilter {
    public static func follows(repo: String, settings: FilterSettings) -> Bool {
        settings.watch(for: repo).prs
    }

    public static func passes(_ pr: PullRequest, settings: FilterSettings, currentUserId: String?) -> Bool {
        guard follows(repo: pr.repo, settings: settings) else { return false }
        if pr.isDraft && !settings.includeDrafts { return false }
        if settings.hideOwn, let me = currentUserId,
           pr.authorId.caseInsensitiveCompare(me) == .orderedSame {
            return false
        }
        return true
    }
}
