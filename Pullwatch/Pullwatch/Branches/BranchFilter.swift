import Foundation
import PullwatchCore

/// Wat het onderdeel Branches toont: een zoektekst (in branch, repo en auteur), één repo, één
/// persoon en of eigen pushes wegblijven; voor de pushes (`apply`) en de boom (`matches`). Alleen een waarde, zodat de tests het zonder view kunnen
/// nagaan.
nonisolated struct BranchFilter: Equatable {
    var searchText: String = ""
    /// De volledige naam van een repo (`octo/app`), hoofdletterongevoelig.
    var repo: String?
    /// De naam van de auteur zoals de push hem geeft, hoofdletterongevoelig.
    var author: String?
    /// Verbergt de pushes van de persoon zelf (`BranchPush.isOwn`).
    var othersOnly: Bool = false

    /// Of er iets gefilterd wordt; een zoektekst met alleen spaties telt niet.
    var isFiltering: Bool {
        !query.isEmpty || repo != nil || author != nil || othersOnly
    }

    /// De pushes die door het filter komen, in dezelfde volgorde.
    func apply(_ pushes: [BranchPush]) -> [BranchPush] {
        let query = query
        return pushes.filter { push in
            if othersOnly && push.isOwn { return false }
            if let repo, push.repo.caseInsensitiveCompare(repo) != .orderedSame { return false }
            if let author {
                guard let name = push.authorName, name.caseInsensitiveCompare(author) == .orderedSame else { return false }
            }
            return query.isEmpty
                || push.branch.localizedCaseInsensitiveContains(query)
                || push.repo.localizedCaseInsensitiveContains(query)
                || push.authorName?.localizedCaseInsensitiveContains(query) == true
        }
    }

    /// Of een branch in de boom door het filter komt, met dezelfde regels als een push.
    func matches(_ info: BranchInfo, repo: String) -> Bool {
        if othersOnly && info.isOwn { return false }
        if let filterRepo = self.repo, repo.caseInsensitiveCompare(filterRepo) != .orderedSame { return false }
        if let author {
            guard let name = info.authorName, name.caseInsensitiveCompare(author) == .orderedSame else { return false }
        }
        let query = query
        return query.isEmpty
            || info.name.localizedCaseInsensitiveContains(query)
            || repo.localizedCaseInsensitiveContains(query)
            || info.authorName?.localizedCaseInsensitiveContains(query) == true
    }

    private var query: String { searchText.trimmingCharacters(in: .whitespaces) }
}
