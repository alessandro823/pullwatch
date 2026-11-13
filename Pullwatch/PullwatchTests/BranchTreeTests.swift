import Foundation
import PullwatchCore
import Testing

@testable import Pullwatch

/// De rijen van de boom in Branches: volgorde, diepte, filters, verwijderde branches en dicht.
@MainActor @Suite struct BranchTreeTests {
    let account = UUID(uuidString: "00000000-0000-0000-0000-0000000000AA")!
    let now = Date(timeIntervalSince1970: 1_790_000_000)

    func info(_ name: String, parent: String? = nil, minutesAgo: Double = 60, author: String = "mona", own: Bool = false, removed: Bool = false) -> BranchInfo {
        BranchInfo(
            name: name, sha: name, authorName: author, isOwn: own, lastPushAt: now - minutesAgo * 60,
            webURL: URL(string: "https://example.com/\(name)")!, parent: parent, removedAt: removed ? now - 60 : nil)
    }

    func tree(_ branches: [BranchInfo], repo: String = "octo/app", defaultBranch: String? = "main") -> RepoBranches {
        RepoBranches(
            accountId: account, repo: repo, defaultBranch: defaultBranch,
            branches: Dictionary(uniqueKeysWithValues: branches.map { ($0.name, $0) }), checkedAt: now)
    }

    func names(_ rows: [BranchRow]) -> [String] {
        rows.map { row in row.info.map { String(repeating: "  ", count: row.depth) + $0.name } ?? "[\(row.repo)]" }
    }

    var sample: RepoBranches {
        tree([
            info("main", minutesAgo: 120),
            info("feature/a", parent: "main", minutesAgo: 30),
            info("feature/a-icons", parent: "feature/a", minutesAgo: 10, author: "jdoe"),
            info("fix/old", parent: "main", minutesAgo: 600, own: true),
        ])
    }

    @Test func `Branches hang under their parent, the most recent first`() {
        let rows = BranchTree.rows(trees: [sample], filter: BranchFilter(), showRemoved: false, collapsed: [], now: now)

        #expect(names(rows) == ["[octo/app]", "main", "  feature/a", "    feature/a-icons", "  fix/old"])
        #expect(rows[1].isDefault)
        #expect(rows[3].pushedRecently)
        #expect(!rows[4].pushedRecently)
    }

    @Test func `A filter keeps the parents of what it finds`() {
        let rows = BranchTree.rows(
            trees: [sample], filter: BranchFilter(searchText: "icons"), showRemoved: false, collapsed: [], now: now)

        #expect(names(rows) == ["[octo/app]", "main", "  feature/a", "    feature/a-icons"])
    }

    @Test func `Others only hides own branches but not a parent of someone else's`() {
        var tree = sample
        tree.branches["feature/a"]?.isOwn = true
        let rows = BranchTree.rows(trees: [tree], filter: BranchFilter(othersOnly: true), showRemoved: false, collapsed: [], now: now)

        #expect(names(rows) == ["[octo/app]", "main", "  feature/a", "    feature/a-icons"])
    }

    @Test func `Removed branches only show when asked`() {
        var tree = sample
        tree.branches["gone"] = info("gone", parent: "main", minutesAgo: 5, removed: true)

        let hidden = BranchTree.rows(trees: [tree], filter: BranchFilter(), showRemoved: false, collapsed: [], now: now)
        let shown = BranchTree.rows(trees: [tree], filter: BranchFilter(), showRemoved: true, collapsed: [], now: now)

        #expect(!names(hidden).contains("  gone"))
        #expect(names(shown).contains("  gone"))
    }

    @Test func `A branch whose parent is gone hangs under the default branch`() {
        let tree = tree([info("main"), info("orphan", parent: "deleted")])
        let rows = BranchTree.rows(trees: [tree], filter: BranchFilter(), showRemoved: false, collapsed: [], now: now)

        #expect(names(rows) == ["[octo/app]", "main", "  orphan"])
    }

    @Test func `A collapsed repository shows only its header`() {
        let rows = BranchTree.rows(trees: [sample], filter: BranchFilter(), showRemoved: false, collapsed: [sample.id], now: now)

        #expect(names(rows) == ["[octo/app]"])
        #expect(rows.first?.kind == .repo(activeToday: 4, isCollapsed: true))
    }

    @Test func `Repositories are in name order and one without matches disappears`() {
        let other = tree([info("main"), info("spike", parent: "main", author: "hubot")], repo: "octo/zeta")
        let all = BranchTree.rows(trees: [other, sample], filter: BranchFilter(), showRemoved: false, collapsed: [], now: now)
        let hubot = BranchTree.rows(trees: [other, sample], filter: BranchFilter(author: "hubot"), showRemoved: false, collapsed: [], now: now)

        #expect(all.filter { $0.info == nil }.map(\.repo) == ["octo/app", "octo/zeta"])
        #expect(names(hubot) == ["[octo/zeta]", "main", "  spike"])
    }

    @Test func `The pill shows a new branch or a force-push of the last day`() {
        let fresh = BranchPush(
            accountId: account, repo: "octo/app", branch: "feature/a", newSha: "2", kind: .forcePush, isOwn: false,
            pushedAt: now - 600, webURL: URL(string: "https://example.com")!)
        let older = BranchPush(
            accountId: account, repo: "octo/app", branch: "fix/old", newSha: "1", kind: .newBranch, isOwn: false,
            pushedAt: now - 3 * 86_400, webURL: URL(string: "https://example.com")!)

        let kinds = BranchTree.recentKinds(of: [fresh, older], now: now)

        #expect(kinds == ["\(sample.id)/feature/a": .forcePush])
    }
}
