import Foundation
import PullwatchCore

/// Eén rij in de boom van Branches: de kop van een repo, of een branch op zijn diepte onder zijn
/// ouder. Alleen waarden, zodat een cel niets uit de environment hoeft te lezen.
nonisolated struct BranchRow: Identifiable, Hashable {
    enum Kind: Hashable {
        /// De kop van een repo: hoeveel branches vandaag een push kregen en of hij dicht is.
        case repo(activeToday: Int, isCollapsed: Bool)
        case branch(BranchInfo)
    }

    /// `RepoBranches.id` voor een kop, met `/branchnaam` erachter voor een branch.
    let id: String
    let treeId: String
    let accountId: UUID
    let repo: String
    let kind: Kind
    /// 0 voor de standaardbranch en de kop.
    let depth: Int
    let isDefault: Bool
    /// De soort van de laatste push als die van de afgelopen dag een nieuwe branch of een
    /// force-push was, voor de pill.
    let recentKind: BranchPush.Kind?
    /// De laatste push was in het afgelopen uur (de stip).
    var pushedRecently = false

    var info: BranchInfo? {
        if case .branch(let info) = kind { info } else { nil }
    }
}

/// Bouwt de rijen van de boom: per repo (op naam) de kop, dan de standaardbranch met daaronder
/// elke branch onder zijn ouder, de recentst gepushte eerst. Een branch waarvan de ouder niet
/// zichtbaar is hangt onder de standaardbranch, of bovenaan als die er niet is. Met een filter
/// blijven de branches die erdoor komen over, met hun ouders erboven, zodat de plek klopt.
nonisolated enum BranchTree {
    static func rows(
        trees: [RepoBranches],
        filter: BranchFilter,
        showRemoved: Bool,
        collapsed: Set<String>,
        recentKinds: [String: BranchPush.Kind] = [:],
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> [BranchRow] {
        var rows: [BranchRow] = []
        let sorted = trees.sorted { $0.repo.localizedStandardCompare($1.repo) == .orderedAscending }
        for tree in sorted {
            let visible = tree.branches.values.filter { showRemoved || $0.removedAt == nil }
            guard !visible.isEmpty else { continue }
            let names = Set(visible.map(\.name))
            let defaultName = tree.defaultBranch.flatMap { names.contains($0) ? $0 : nil }

            func parent(of info: BranchInfo) -> String? {
                guard info.name != defaultName else { return nil }
                if let parent = info.parent, names.contains(parent), parent != info.name { return parent }
                return defaultName
            }

            var children: [String?: [BranchInfo]] = [:]
            for info in visible { children[parent(of: info), default: []].append(info) }
            for key in children.keys {
                children[key]?.sort {
                    let (a, b) = ($0.lastPushAt ?? .distantPast, $1.lastPushAt ?? .distantPast)
                    return a != b ? a > b : $0.name < $1.name
                }
            }

            // Wat het filter doorlaat, met de ouders erbij.
            var kept = Set<String>()
            if filter.isFiltering {
                let byName = Dictionary(uniqueKeysWithValues: visible.map { ($0.name, $0) })
                for info in visible where filter.matches(info, repo: tree.repo) {
                    var current: BranchInfo? = info
                    while let branch = current, kept.insert(branch.name).inserted {
                        current = parent(of: branch).flatMap { byName[$0] }
                    }
                }
                guard !kept.isEmpty else { continue }
            } else {
                kept = names
            }

            let isCollapsed = collapsed.contains(tree.id)
            let activeToday = tree.live.filter { $0.lastPushAt.map { calendar.isDate($0, inSameDayAs: now) } ?? false }.count
            rows.append(BranchRow(
                id: tree.id, treeId: tree.id, accountId: tree.accountId, repo: tree.repo,
                kind: .repo(activeToday: activeToday, isCollapsed: isCollapsed), depth: 0, isDefault: false, recentKind: nil))
            guard !isCollapsed else { continue }

            // Diepte eerst; een kring (die de engine niet maakt) loopt niet rond.
            var placed = Set<String>()
            func add(_ info: BranchInfo, depth: Int) {
                guard kept.contains(info.name), placed.insert(info.name).inserted else { return }
                let id = "\(tree.id)/\(info.name)"
                rows.append(BranchRow(
                    id: id, treeId: tree.id, accountId: tree.accountId, repo: tree.repo, kind: .branch(info),
                    depth: depth, isDefault: info.name == defaultName, recentKind: recentKinds[id],
                    pushedRecently: info.removedAt == nil && info.lastPushAt.map { now.timeIntervalSince($0) <= 3600 } ?? false))
                for child in children[info.name] ?? [] { add(child, depth: depth + 1) }
            }
            for root in children[nil] ?? [] { add(root, depth: 0) }
        }
        return rows
    }

    /// Per branch-rij (`BranchRow.id`) de soort van de laatste push als die van de afgelopen dag
    /// een nieuwe branch of een force-push was.
    static func recentKinds(of pushes: [BranchPush], now: Date = Date()) -> [String: BranchPush.Kind] {
        var result: [String: BranchPush.Kind] = [:]
        var seen = Set<String>()
        // De log staat nieuwste eerst: de eerste push per branch is zijn laatste.
        for push in pushes {
            let id = "\(push.accountId.uuidString):\(push.repo.lowercased())/\(push.branch)"
            guard seen.insert(id).inserted, now.timeIntervalSince(push.pushedAt) <= 86_400 else { continue }
            if push.kind == .newBranch || push.kind == .forcePush { result[id] = push.kind }
        }
        return result
    }
}
