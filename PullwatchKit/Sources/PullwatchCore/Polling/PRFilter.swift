import Foundation

/// Welke pull requests van een account gevolgd en gemeld worden. Drafts staan in de lijsten zoals
/// op GitHub, tenzij `showDrafts` uit staat; `includeDrafts` beslist of een nieuwe draft meldt.
enum PRFilter {
    public static func follows(repo: String, settings: FilterSettings) -> Bool {
        settings.watch(for: repo).prs
    }

    /// `watching` kiest welk vinkje de repo moet hebben: PR's (standaard) of completed.
    static func passes(
        _ pr: PullRequest,
        settings: FilterSettings,
        currentUserId: String?,
        watching field: KeyPath<WatchSet, Bool> = \.prs
    ) -> Bool {
        guard settings.watch(for: pr.repo)[keyPath: field] else { return false }
        // Verborgen drafts tellen nergens; klaar voor review komt de PR gewoon binnen.
        if pr.isDraft && !settings.showDrafts { return false }
        if settings.hideOwn, let me = currentUserId,
           pr.authorId.caseInsensitiveCompare(me) == .orderedSame {
            return false
        }
        return true
    }

    /// Of een nieuwe PR die `passes` doorlaat ook een melding geeft: een draft alleen met
    /// "Draft-PR's melden" aan (`includeDrafts`); `passes` liet hem al alleen met `showDrafts` door.
    static func notifies(_ pr: PullRequest, settings: FilterSettings) -> Bool {
        !pr.isDraft || settings.includeDrafts
    }
}
