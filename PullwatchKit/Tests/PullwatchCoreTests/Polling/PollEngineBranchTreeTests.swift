import Foundation
import Testing
@testable import PullwatchCore
import PullwatchTestSupport

/// De boom van Branches: standaardbranch, ouders, voor en achter, verdwenen en gemerged.
@Suite struct PollEngineBranchTreeTests {
    private struct Harness {
        let clock = TestClock()
        let provider = MockProvider()
        let engine: PollEngine

        init() {
            let clock = clock
            let provider = provider
            engine = PollEngine(makeProvider: { _ in provider }, store: nil, now: { clock.now })
        }

        /// Eén ronde zoals de app hem doet, met `budget` vergelijkingen voor de boom.
        func poll(_ account: Account, budget: Int = PollEngine.branchTreeCompareLimit) async -> RepoBranches? {
            await engine.setBranchTreeBudget(budget)
            _ = await engine.poll(accounts: [account], interval: 120, retention: .oneYear)
            _ = await engine.pollBranches(accounts: [account])
            return await engine.branchTrees().first
        }

        func nextPoll(_ account: Account, budget: Int = PollEngine.branchTreeCompareLimit) async -> RepoBranches? {
            clock.advance(PollEngine.branchInterval)
            return await poll(account, budget: budget)
        }

        func set(_ heads: [BranchHead], defaultBranch: String? = nil, fingerprint: String? = nil, unchanged: Bool = false) async {
            await provider.set(branchFetch: BranchFetch(
                heads: unchanged ? [] : heads,
                fingerprints: fingerprint.map { ["proj/a": $0] } ?? [:],
                unchangedRepos: unchanged ? ["proj/a"] : [],
                defaultBranches: defaultBranch.map { ["proj/a": $0] } ?? [:]))
        }
    }

    let account = Account.fixture(repoWatch: ["proj/a": .prs])

    func head(_ name: String, _ sha: String, minutesAgo: Double = 0, now: Date = .testStart) -> BranchHead {
        BranchHead(
            repo: "proj/a", name: name, sha: sha, committedAt: now - minutesAgo * 60, authorName: "Someone",
            authorId: "someone", webURL: URL(string: "https://example.com/proj/a/tree/\(name)")!)
    }

    func c(_ ahead: Int, _ behind: Int) -> BranchComparison { BranchComparison(ahead: ahead, behind: behind) }

    @Test func `A branch from main hangs under main with its distance`() async throws {
        let h = Harness()
        await h.set([head("main", "m1", minutesAgo: 60), head("feature/x", "x1")])
        await h.provider.set(comparisons: ["m1...x1": c(2, 0)])

        let tree = try #require(await h.poll(account))

        #expect(tree.defaultBranch == "main")
        let x = try #require(tree.branches["feature/x"])
        #expect(x.parent == "main")
        #expect(x.parentSource == .defaultBranch)
        #expect(x.againstParent == c(2, 0))
        #expect(x.againstDefault == c(2, 0))
        #expect(tree.branches["main"]?.parent == nil)
    }

    @Test func `A stacked branch hangs under the branch it was made from`() async throws {
        let h = Harness()
        await h.set([head("main", "m1", minutesAgo: 60), head("a", "a1", minutesAgo: 30), head("b", "b1")])
        await h.provider.set(comparisons: [
            "m1...a1": c(3, 0), "b1...a1": c(0, 1),
            "m1...b1": c(4, 0), "a1...b1": c(1, 0),
        ])

        let tree = try #require(await h.poll(account))

        #expect(tree.branches["a"]?.parent == "main")
        #expect(tree.branches["b"]?.parent == "a")
        #expect(tree.branches["b"]?.parentSource == .history)
        #expect(tree.branches["b"]?.againstParent == c(1, 0))
        #expect(tree.branches["b"]?.againstDefault == c(4, 0))
    }

    @Test func `The target branch of an open PR wins over the history`() async throws {
        let h = Harness()
        var pr = PullRequest.fixture(repo: "proj/a", number: 48)
        pr.sourceBranch = "b"
        pr.targetBranch = "a"
        await h.provider.set(pullRequests: [pr])
        await h.set([head("main", "m1", minutesAgo: 60), head("a", "a1", minutesAgo: 30), head("b", "b1")])
        await h.provider.set(comparisons: ["m1...a1": c(3, 0), "b1...a1": c(5, 5), "a1...b1": c(9, 9), "m1...b1": c(1, 0)])

        let tree = try #require(await h.poll(account))

        #expect(tree.branches["b"]?.parent == "a")
        #expect(tree.branches["b"]?.parentSource == .pullRequest)
        #expect(tree.branches["b"]?.pullRequest == 48)
        #expect(tree.branches["b"]?.againstParent == c(9, 9))
    }

    @Test func `The service's default branch beats the usual names`() async throws {
        let h = Harness()
        await h.set([head("main", "m1"), head("develop", "d1")], defaultBranch: "develop")
        await h.provider.set(comparisons: ["d1...m1": c(1, 0)])

        let tree = try #require(await h.poll(account))

        #expect(tree.defaultBranch == "develop")
        #expect(tree.branches["main"]?.parent == "develop")
    }

    @Test func `A merged parent hands its children to main`() async throws {
        let h = Harness()
        await h.set([head("main", "m1", minutesAgo: 60), head("a", "a1", minutesAgo: 30), head("b", "b1")])
        await h.provider.set(comparisons: [
            "m1...a1": c(3, 0), "b1...a1": c(0, 1), "m1...b1": c(4, 0), "a1...b1": c(1, 0),
        ])
        _ = await h.poll(account)
        // a is in main gemerged en weggehaald; main staat nu op m2.
        await h.set([head("main", "m2", minutesAgo: -10, now: h.clock.now + PollEngine.branchInterval), head("b", "b1")])
        await h.provider.set(comparisons: ["m2...a1": c(0, 4), "m2...b1": c(1, 4)])

        let tree = try #require(await h.nextPoll(account))

        let a = try #require(tree.branches["a"])
        #expect(a.removedAt == h.clock.now)
        #expect(a.merged)
        #expect(!tree.live.map(\.name).contains("a"))
        #expect(tree.branches["b"]?.parent == "main")
        #expect(tree.branches["b"]?.againstParent == c(1, 4))
    }

    @Test func `A deleted branch that was not merged is not called merged`() async throws {
        let h = Harness()
        await h.set([head("main", "m1", minutesAgo: 60), head("spike", "s1")])
        await h.provider.set(comparisons: ["m1...s1": c(2, 0)])
        _ = await h.poll(account)
        await h.set([head("main", "m1", minutesAgo: 60)])

        let tree = try #require(await h.nextPoll(account))

        #expect(tree.branches["spike"]?.removedAt != nil)
        #expect(tree.branches["spike"]?.merged == false)
    }

    @Test func `A parent search that does not fit the budget waits for the next poll`() async throws {
        let h = Harness()
        await h.set([head("main", "m1", minutesAgo: 60), head("a", "a1", minutesAgo: 30), head("b", "b1")])
        await h.provider.set(comparisons: [
            "m1...a1": c(3, 0), "b1...a1": c(0, 1), "m1...b1": c(4, 0), "a1...b1": c(1, 0),
        ])

        let first = try #require(await h.poll(account, budget: 1))
        #expect(first.branches["b"]?.parent == "main")
        #expect(first.branches["b"]?.parentSource == nil)

        let second = try #require(await h.nextPoll(account))
        #expect(second.branches["b"]?.parent == "a")
        #expect(second.branches["b"]?.parentSource == .history)
    }

    @Test func `A rate limit stops the comparisons without failing the poll`() async throws {
        let h = Harness()
        await h.set([head("main", "m1", minutesAgo: 60), head("x", "x1")])
        await h.provider.set(compareErrors: ["m1...x1": .rateLimited(until: .testStart + 600)])

        let tree = try #require(await h.poll(account))

        #expect(tree.branches["x"]?.parentSource == nil)
        #expect(tree.branches["x"]?.againstDefault == nil)
        #expect(await h.provider.compareCalls == 1)
    }

    @Test func `An unchanged repository keeps its tree and only compares what moved`() async throws {
        let h = Harness()
        await h.set([head("main", "m1", minutesAgo: 60), head("x", "x1")], fingerprint: "f1")
        await h.provider.set(comparisons: ["m1...x1": c(2, 0)])
        _ = await h.poll(account)
        let calls = await h.provider.compareCalls
        await h.set([], fingerprint: "f1", unchanged: true)

        let tree = try #require(await h.nextPoll(account))

        #expect(tree.branches["x"]?.parent == "main")
        #expect(tree.branches["x"]?.againstParent == c(2, 0))
        #expect(await h.provider.compareCalls == calls)
        #expect(await h.provider.lastBranchUnchanged == ["proj/a": "f1"])
    }

    @Test func `A repository without a tree is read in full once`() async {
        let h = Harness()
        await h.set([head("main", "m1")], fingerprint: "f1")
        _ = await h.poll(account, budget: 0)
        await h.engine.forgetBranchTrees()

        _ = await h.nextPoll(account)

        #expect(await h.provider.lastBranchUnchanged.isEmpty)
    }
}
