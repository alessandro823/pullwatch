import Foundation

/// De filter-relevante instellingen van een account. Wordt ook bewaard in `SeenState`
/// om te detecteren welke PR's pas door een instellingswijziging zichtbaar worden.
public struct FilterSettings: Codable, Hashable, Sendable {
    public var kind: ProviderKind
    public var organization: String
    public var filterMode: FilterMode
    public var repos: [String]
    public var includeDrafts: Bool
    public var hideOwn: Bool

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
            filterMode: filterMode,
            repos: repos,
            includeDrafts: includeDrafts,
            hideOwn: hideOwn
        )
    }
}

public enum PRFilter {
    public static func follows(repo: String, settings: FilterSettings) -> Bool {
        let listed = settings.repos.contains { $0.caseInsensitiveCompare(repo) == .orderedSame }
        switch settings.filterMode {
        case .allow: return listed
        case .deny: return !listed
        }
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
