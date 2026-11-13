import Foundation

private let logger = Log(category: "polling")

/// De boom van Branches per repo (`RepoBranches`): bijwerken met de heads van een poll, de ouder
/// van elke branch bepalen en hoe ver hij voor en achter ligt. Vergelijkingen kosten een verzoek
/// per stuk, dus elk account krijgt per poll `branchTreeCompareLimit`; wat niet past komt de
/// volgende poll, en alleen een veranderde head kost een nieuwe vergelijking.
extension PollEngine {
    /// Vergelijkingen per account per poll voor de boom.
    static let branchTreeCompareLimit = 60
    /// Hooguit zoveel kandidaten (de recentst gepushte, plus de standaardbranch) bij het zoeken
    /// naar een ouder.
    static let branchParentCandidates = 8

    /// Een open PR vanaf een branch: zijn nummer en de branch waar hij in moet.
    struct BranchPullRequest: Sendable {
        let number: Int
        let target: String
    }

    /// Per repo (lowercased) per bronbranch de open PR, uit de laatste PR-poll van het account.
    static func branchPullRequests(_ pullRequests: [PullRequest]) -> [String: [String: BranchPullRequest]] {
        var result: [String: [String: BranchPullRequest]] = [:]
        for pr in pullRequests where pr.state == .open {
            guard let source = pr.sourceBranch, let target = pr.targetBranch, source != target else { continue }
            result[pr.repo.lowercased(), default: [:]][source] = BranchPullRequest(number: pr.number, target: target)
        }
        return result
    }

    /// Werkt `tree` bij. `heads` is nil als de repo niet opnieuw gelezen is (onveranderd): dan
    /// blijven de branches staan en lopen alleen de PR's, ouders en vergelijkingen. Een branch
    /// die niet meer in `heads` staat is verdwenen; zat zijn laatste commit in de
    /// standaardbranch, dan heet hij gemerged. `budget` telt de vergelijkingen af; na een rate
    /// limit is hij nul.
    static func updateTree(
        _ tree: inout RepoBranches,
        heads: [BranchHead]?,
        defaultBranch: String?,
        pullRequests: [String: BranchPullRequest],
        provider: any PRProvider,
        budget: inout Int,
        at t: Date
    ) async {
        var newlyRemoved: [String] = []
        if let heads {
            var present: Set<String> = []
            for head in heads where present.insert(head.name).inserted {
                var info = tree.branches[head.name] ?? BranchInfo(name: head.name, sha: head.sha, webURL: head.webURL)
                if info.sha != head.sha || info.lastPushAt == nil {
                    info.lastPushAt = head.committedAt.map { min($0, t) } ?? t
                }
                info.sha = head.sha
                info.authorName = head.authorName ?? info.authorName
                info.authorAvatarURL = head.authorAvatarURL ?? info.authorAvatarURL
                info.webURL = head.webURL
                info.removedAt = nil
                info.merged = false
                tree.branches[head.name] = info
            }
            for (name, info) in tree.branches where info.removedAt == nil && !present.contains(name) {
                tree.branches[name]?.removedAt = t
                newlyRemoved.append(name)
            }
        }
        let liveNames = tree.live.map(\.name)
        tree.defaultBranch = defaultBranch ?? tree.defaultBranch.flatMap { liveNames.contains($0) ? $0 : nil }
            ?? RepoBranches.guessedDefault(among: liveNames)
        tree.checkedAt = t

        let repo = tree.repo
        func compare(_ from: String, _ to: String) async -> BranchComparison? {
            guard budget > 0 else { return nil }
            budget -= 1
            do {
                return try await provider.compare(in: repo, from: from, to: to)
            } catch ProviderError.rateLimited {
                logger.notice("branch-boom: vergelijken gestopt door rate limit")
                budget = 0
                return nil
            } catch {
                logger.notice("branch-boom: vergelijken mislukt voor \(repo): \(error.localizedDescription)")
                return nil
            }
        }

        let defaultName = tree.defaultBranch
        let defaultSha = defaultName.flatMap { tree.branches[$0]?.removedAt == nil ? tree.branches[$0]?.sha : nil }

        // Verdwenen: gemerged als de standaardbranch alles van de branch heeft.
        if let defaultSha {
            for name in newlyRemoved {
                guard let sha = tree.branches[name]?.sha else { continue }
                if let comparison = await compare(defaultSha, sha) {
                    tree.branches[name]?.merged = comparison.ahead == 0
                }
            }
        }

        // De standaardbranch heeft geen ouder; de PR's horen bij de branches die er zijn.
        for name in liveNames {
            tree.branches[name]?.pullRequest = pullRequests[name]?.number
        }
        if let defaultName, tree.branches[defaultName] != nil {
            tree.branches[defaultName]?.parent = nil
            tree.branches[defaultName]?.parentSource = nil
            tree.branches[defaultName]?.againstParent = nil
            tree.branches[defaultName]?.againstDefault = nil
        }

        // Ouders, de recentst gepushte branch eerst.
        let order = tree.live.filter { $0.name != defaultName }
            .sorted { ($0.lastPushAt ?? .distantPast, $1.name) > ($1.lastPushAt ?? .distantPast, $0.name) }
            .map(\.name)
        let live = Set(liveNames)
        for name in order {
            guard let info = tree.branches[name] else { continue }
            if let pr = pullRequests[name], live.contains(pr.target), !tree.isDescendant(pr.target, of: name) {
                if info.parent != pr.target || info.parentSource != .pullRequest {
                    tree.branches[name]?.parent = pr.target
                    tree.branches[name]?.parentSource = .pullRequest
                    tree.branches[name]?.comparedParent = nil
                }
                continue
            }
            let parentIsLive = info.parent.map(live.contains) ?? false
            let settled = parentIsLive && (info.parentSource == .history || info.parentSource == .defaultBranch)
            if settled { continue }
            await findParent(of: name, in: &tree, live: live, compare: compare)
        }

        // Voor en achter tegen de ouder en de standaardbranch, alleen na een verandering.
        for name in order {
            guard let info = tree.branches[name] else { continue }
            if let parent = info.parent, let parentSha = tree.branches[parent]?.sha {
                let key = "\(parentSha)...\(info.sha)"
                if info.comparedParent != key, let comparison = await compare(parentSha, info.sha) {
                    tree.branches[name]?.againstParent = comparison
                    tree.branches[name]?.comparedParent = key
                }
            }
            if let defaultSha {
                let key = "\(defaultSha)...\(info.sha)"
                if info.parent == defaultName, let againstParent = tree.branches[name]?.againstParent,
                   tree.branches[name]?.comparedParent == key {
                    tree.branches[name]?.againstDefault = againstParent
                    tree.branches[name]?.comparedDefault = key
                } else if info.comparedDefault != key, let comparison = await compare(defaultSha, info.sha) {
                    tree.branches[name]?.againstDefault = comparison
                    tree.branches[name]?.comparedDefault = key
                }
            }
        }
    }

    /// Zoekt de ouder van `name` uit de geschiedenis (`BranchLineage`). Past niet elke
    /// vergelijking in het budget, dan blijft de branch voorlopig onder de standaardbranch hangen
    /// (zonder bron), en probeert de volgende poll het opnieuw.
    private static func findParent(
        of name: String,
        in tree: inout RepoBranches,
        live: Set<String>,
        compare: (String, String) async -> BranchComparison?
    ) async {
        guard let sha = tree.branches[name]?.sha else { return }
        let defaultName = tree.defaultBranch
        var candidates = tree.live
            .filter { $0.name != name && $0.name != defaultName && !tree.isDescendant($0.name, of: name) }
            .sorted { ($0.lastPushAt ?? .distantPast, $1.name) > ($1.lastPushAt ?? .distantPast, $0.name) }
            .prefix(branchParentCandidates - 1)
            .map { (name: $0.name, sha: $0.sha) }
        if let defaultName, let defaultSha = tree.branches[defaultName]?.sha, live.contains(defaultName) {
            candidates.insert((defaultName, defaultSha), at: 0)
        }
        guard !candidates.isEmpty else {
            tree.branches[name]?.parent = nil
            tree.branches[name]?.parentSource = nil
            return
        }
        var comparisons: [String: BranchComparison] = [:]
        for candidate in candidates {
            guard let comparison = await compare(candidate.sha, sha) else {
                // Zonder volledig beeld geen keuze: de volgende poll opnieuw.
                tree.branches[name]?.parent = defaultName
                tree.branches[name]?.parentSource = nil
                return
            }
            comparisons[candidate.name] = comparison
        }
        let parent = BranchLineage.parent(among: comparisons, defaultBranch: defaultName) ?? defaultName
        tree.branches[name]?.parent = parent
        tree.branches[name]?.parentSource = parent == defaultName ? .defaultBranch : .history
        if let parent, let parentSha = tree.branches[parent]?.sha, let comparison = comparisons[parent] {
            tree.branches[name]?.againstParent = comparison
            tree.branches[name]?.comparedParent = "\(parentSha)...\(sha)"
        }
    }

    /// Haalt verdwenen branches weg die ouder zijn dan de bewaartermijn.
    static func pruneRemoved(_ tree: inout RepoBranches, retention: HistoryRetention, now t: Date) {
        guard let maxAge = retention.maxAge else { return }
        tree.branches = tree.branches.filter { _, info in
            info.removedAt.map { t.timeIntervalSince($0) <= maxAge } ?? true
        }
    }
}

extension RepoBranches {
    /// Of `branch` (via zijn ouders) van `ancestor` afstamt; een kring telt niet eindeloos.
    func isDescendant(_ branch: String, of ancestor: String) -> Bool {
        var seen: Set<String> = []
        var current = branches[branch]?.parent
        while let name = current, seen.insert(name).inserted {
            if name == ancestor { return true }
            current = branches[name]?.parent
        }
        return false
    }
}
