import Foundation
import Testing
@testable import PullwatchCore
import PullwatchTestSupport

/// Pushes naar branches: seeden, pushes, force-pushes, nieuwe branches en de randgevallen.
@Suite struct PollEngineBranchTests {
    private struct Harness {
        let clock = TestClock()
        let provider = MockProvider()
        let engine: PollEngine

        init() {
            let clock = clock
            let provider = provider
            engine = PollEngine(makeProvider: { _ in provider }, store: nil, now: { clock.now })
        }

        /// Eén ronde zoals de app hem doet: eerst `poll`, dan `pollBranches`.
        func poll(_ account: Account) async -> Tick {
            let result = await engine.poll(accounts: [account], interval: 120, retention: .oneYear)
            return Tick(result: result, branchPushes: await engine.pollBranches(accounts: [account]))
        }

        /// Naar de volgende branch-poll.
        func nextBranchPoll(_ account: Account) async -> Tick {
            clock.advance(PollEngine.branchInterval)
            return await poll(account)
        }

        func set(_ heads: [BranchHead], unavailable: [String] = [], fingerprints: [String: String] = [:], unchanged: [String] = []) async {
            await provider.set(branchFetch: BranchFetch(
                heads: heads, unavailableRepos: unavailable, fingerprints: fingerprints, unchangedRepos: unchanged))
        }
    }

    /// De uitkomst van een ronde: die van `poll` en de pushes van `pollBranches`.
    private struct Tick {
        let result: PollResult
        let branchPushes: [BranchPush]
        var statuses: [UUID: AccountState] { result.statuses }
        var newPullRequests: [PullRequest] { result.newPullRequests }
    }

    let account = Account.fixture(repoWatch: ["proj/a": .prs])
    let day: TimeInterval = 86_400

    func head(
        _ name: String, _ sha: String, at date: Date?, authorId: String? = "someone", authorName: String? = "Someone",
        email: String? = nil
    ) -> BranchHead {
        BranchHead(
            repo: "proj/a", name: name, sha: sha, committedAt: date, authorName: authorName, authorId: authorId,
            authorEmail: email, webURL: URL(string: "https://example.com/proj/a/tree/\(name)")!)
    }

    @Test func firstPollSeedsOnlyBranchesMovedInLast14Days() async {
        let h = Harness()
        let now = h.clock.now
        let recent = head("feature/x", "x1", at: now - 2 * day)
        await h.set([recent, head("old", "o1", at: now - 30 * day), head("nodate", "n1", at: nil)])

        let result = await h.poll(account)

        #expect(result.branchPushes.map(\.branch) == ["feature/x"])
        let row = result.branchPushes.first
        #expect(row?.kind == .recent)
        #expect(row?.pushedAt == now - 2 * day)
        #expect(row?.oldSha == nil)
        #expect(row?.newSha == "x1")
        #expect(row?.commits == nil)
        #expect(row?.webURL == recent.webURL)
        #expect(row?.accountId == account.id)
    }

    @Test func changedHeadBecomesPushWithCommitCount() async {
        let h = Harness()
        await h.set([head("main", "1", at: h.clock.now - 30 * day)])
        #expect(await h.poll(account).branchPushes.isEmpty)
        // De commit is van het moment van de volgende branch-poll.
        await h.set([head("main", "2", at: h.clock.now + PollEngine.branchInterval)])
        await h.provider.set(comparisons: ["1...2": BranchComparison(ahead: 4, behind: 0)])

        let result = await h.nextBranchPoll(account)

        #expect(result.branchPushes.count == 1)
        let row = result.branchPushes.first
        #expect(row?.kind == .push)
        #expect(row?.commits == 4)
        #expect(row?.oldSha == "1")
        #expect(row?.newSha == "2")
        #expect(row?.pushedAt == h.clock.now)
        #expect(row?.webURL == h.provider.compareURL(in: "proj/a", from: "1", to: "2"))
    }

    @Test func rewrittenHeadIsForcePush() async {
        let h = Harness()
        await h.set([head("main", "1", at: h.clock.now - 30 * day)])
        _ = await h.poll(account)
        await h.set([head("main", "2", at: h.clock.now)])
        await h.provider.set(comparisons: ["1...2": BranchComparison(ahead: 3, behind: 2)])

        let result = await h.nextBranchPoll(account)

        #expect(result.branchPushes.map(\.kind) == [.forcePush])
        #expect(result.branchPushes.first?.commits == nil)
        #expect(result.branchPushes.first?.oldSha == "1")
    }

    @Test func pushWithoutComparisonHasNoCommitCount() async {
        let h = Harness()
        await h.set([head("main", "1", at: h.clock.now - 30 * day)])
        _ = await h.poll(account)
        await h.set([head("main", "2", at: h.clock.now)])
        await h.provider.set(compareErrors: ["1...2": .network("kapot")])

        let result = await h.nextBranchPoll(account)

        #expect(result.branchPushes.map(\.kind) == [.push])
        #expect(result.branchPushes.first?.commits == nil)
    }

    @Test func newBranchAfterSeed() async {
        let h = Harness()
        let main = head("main", "1", at: h.clock.now - 30 * day)
        await h.set([main])
        _ = await h.poll(account)
        let feature = head("feature/y", "y1", at: h.clock.now)
        await h.set([main, feature])

        let result = await h.nextBranchPoll(account)

        #expect(result.branchPushes.count == 1)
        let row = result.branchPushes.first
        #expect(row?.kind == .newBranch)
        #expect(row?.branch == "feature/y")
        #expect(row?.oldSha == nil)
        #expect(row?.commits == nil)
        #expect(row?.webURL == feature.webURL)
        #expect(await h.provider.compareCalls == 0)
    }

    @Test func deletedBranchGivesNoRow() async {
        let h = Harness()
        let main = head("main", "1", at: h.clock.now - 30 * day)
        await h.set([main, head("gone", "g1", at: h.clock.now - 30 * day)])
        _ = await h.poll(account)
        await h.set([main])

        #expect(await h.nextBranchPoll(account).branchPushes.isEmpty)
    }

    @Test func unchangedRepoCostsNoCompare() async {
        let h = Harness()
        await h.set([head("main", "1", at: h.clock.now - 30 * day)], fingerprints: ["proj/a": "f1"])
        _ = await h.poll(account)
        #expect(await h.provider.lastBranchUnchanged.isEmpty) // nog niet geseed
        // Een dienst die de repo onveranderd noemt: wat hij verder meegeeft telt niet.
        await h.set([head("main", "2", at: h.clock.now)], fingerprints: ["proj/a": "f1"], unchanged: ["proj/a"])
        await h.provider.set(comparisons: ["1...2": BranchComparison(ahead: 1, behind: 0)])

        let result = await h.nextBranchPoll(account)

        #expect(result.branchPushes.isEmpty)
        #expect(await h.provider.compareCalls == 0)
        #expect(await h.provider.lastBranchUnchanged == ["proj/a": "f1"])

        // De onthouden heads bleven staan: de volgende echte verandering vergelijkt met sha 1.
        await h.set([head("main", "2", at: h.clock.now)], fingerprints: ["proj/a": "f2"])
        let next = await h.nextBranchPoll(account)
        #expect(next.branchPushes.map(\.kind) == [.push])
        #expect(next.branchPushes.first?.oldSha == "1")
        #expect(next.branchPushes.first?.commits == 1)
    }

    @Test func rateLimitOnBranchesKeepsPullRequests() async {
        let h = Harness()
        await h.set([head("main", "1", at: h.clock.now - 30 * day)])
        _ = await h.poll(account)
        let pr = PullRequest.fixture(accountId: account.id, repo: "proj/a")
        await h.provider.set(pullRequests: [pr])
        h.clock.advance(PollEngine.branchInterval)
        let limitedAt = h.clock.now
        await h.provider.set(branchError: .rateLimited(until: limitedAt + 600))
        await h.set([head("main", "2", at: limitedAt)])

        let result = await h.poll(account)

        #expect(result.statuses[account.id] == .ok(lastPoll: limitedAt))
        #expect(result.newPullRequests.map(\.dedupKey) == [pr.dedupKey])
        #expect(result.branchPushes.isEmpty)
        #expect(await h.provider.branchCalls == 2)

        // Binnen de 600 s geen branches, ook niet met "Nu verversen".
        await h.provider.set(branchError: nil)
        h.clock.advance(300)
        await h.engine.forceRefresh()
        #expect(await h.poll(account).branchPushes.isEmpty)
        #expect(await h.provider.branchCalls == 2)

        // Daarna wel, en de onthouden heads zijn er nog.
        await h.provider.set(comparisons: ["1...2": BranchComparison(ahead: 1, behind: 0)])
        let after = await h.nextBranchPoll(account)
        #expect(await h.provider.branchCalls == 3)
        #expect(after.branchPushes.map(\.kind) == [.push])
    }

    @Test func otherBranchErrorChangesNothing() async {
        let h = Harness()
        await h.set([head("main", "1", at: h.clock.now - 30 * day)])
        _ = await h.poll(account)
        await h.provider.set(branchError: .network("kapot"))

        let failed = await h.nextBranchPoll(account)
        #expect(failed.branchPushes.isEmpty)
        #expect(failed.statuses[account.id] == .ok(lastPoll: h.clock.now))

        await h.provider.set(branchError: nil)
        await h.set([head("main", "1", at: h.clock.now - 30 * day), head("feature/z", "z1", at: h.clock.now)])
        #expect(await h.nextBranchPoll(account).branchPushes.map(\.kind) == [.newBranch])
    }

    @Test func unavailableRepoKeepsHeadsAndFloodsNothingOnReturn() async {
        let h = Harness()
        let heads = [head("main", "1", at: h.clock.now - 30 * day), head("feature/a", "a1", at: h.clock.now - 20 * day)]
        await h.set(heads)
        _ = await h.poll(account)

        await h.set([], unavailable: ["proj/a"])
        for _ in 0..<4 {
            #expect(await h.nextBranchPoll(account).branchPushes.isEmpty)
        }

        await h.set(heads)
        #expect(await h.nextBranchPoll(account).branchPushes.isEmpty)
        await h.set([heads[0], head("feature/a", "a2", at: h.clock.now)])
        #expect(await h.nextBranchPoll(account).branchPushes.map(\.kind) == [.push])
    }

    @Test func turningBranchesOffAndOnReseedsQuietly() async {
        let h = Harness()
        await h.set([head("main", "1", at: h.clock.now - 1 * day), head("old", "o1", at: h.clock.now - 30 * day)])
        #expect(await h.poll(account).branchPushes.map(\.kind) == [.recent])

        // Uit voor deze repo: de onthouden heads gaan weg.
        let off = Account.fixture(
            id: account.id, repoWatch: ["proj/a": WatchSet(prs: true, tags: false, branches: false)])
        #expect(await h.nextBranchPoll(off).branchPushes.isEmpty)
        await h.set([head("main", "2", at: h.clock.now - 1 * day), head("old", "o2", at: h.clock.now - 10 * day)])

        let on = await h.nextBranchPoll(account)
        #expect(on.branchPushes.map(\.kind) == [.recent, .recent])
        #expect(on.branchPushes.map(\.newSha) == ["2", "o2"])
        #expect(await h.provider.compareCalls == 0)

        // Uit voor het hele account (niets volgt branches): ook dan opnieuw seeden.
        let none = Account.fixture(
            id: account.id, repoWatch: ["proj/a": WatchSet(prs: true, tags: false, branches: false)], newRepoDefault: .none)
        let calls = await h.provider.branchCalls
        #expect(await h.nextBranchPoll(none).branchPushes.isEmpty)
        #expect(await h.provider.branchCalls == calls)
        await h.set([head("main", "3", at: h.clock.now - 1 * day), head("old", "o2", at: h.clock.now - 30 * day)])

        let again = await h.nextBranchPoll(account)
        #expect(again.branchPushes.map(\.kind) == [.recent])
        #expect(again.branchPushes.map(\.newSha) == ["3"])
        #expect(await h.provider.compareCalls == 0)
    }

    @Test func futureCommitDateCountsAsNow() async {
        let h = Harness()
        await h.set([head("main", "1", at: h.clock.now + 3600)])

        let result = await h.poll(account)

        #expect(result.branchPushes.map(\.kind) == [.recent])
        #expect(result.branchPushes.first?.pushedAt == h.clock.now)
    }

    @Test func ownPushIsMarkedByIdEmailOrLogin() async {
        let h = Harness()
        var mine = account
        mine.login = "mona"
        mine.email = "Me@Example.com"
        let now = h.clock.now
        await h.set([
            head("by-id", "1", at: now - day, authorId: "ME"),
            head("by-email", "2", at: now - day, authorId: nil, authorName: "Someone", email: "me@example.com"),
            head("by-login-id", "3", at: now - day, authorId: "Mona"),
            head("by-login-name", "4", at: now - day, authorId: nil, authorName: "mona"),
            head("other", "5", at: now - day, authorId: "other", authorName: "Other", email: "other@example.com"),
        ])

        let result = await h.poll(mine)

        let own = Dictionary(uniqueKeysWithValues: result.branchPushes.map { ($0.branch, $0.isOwn) })
        #expect(own == ["by-id": true, "by-email": true, "by-login-id": true, "by-login-name": true, "other": false])
    }

    @Test func branchesOffForRepoFetchesNothing() async {
        let h = Harness()
        let off = Account.fixture(
            repoWatch: ["proj/a": WatchSet(prs: true, tags: false, branches: false)], newRepoDefault: .none)
        await h.set([head("main", "1", at: h.clock.now)])

        let result = await h.poll(off)

        #expect(result.branchPushes.isEmpty)
        #expect(await h.provider.branchCalls == 0)
        #expect(await h.provider.listRepoCalls == 0)
    }

    @Test func reposListedOnceWhenTagsAndBranchesFollowByDefault() async {
        let h = Harness()
        let both = Account.fixture(newRepoDefault: .prsAndTags)
        await h.provider.set(repos: ["proj/a", "proj/b"])

        _ = await h.poll(both)

        #expect(await h.provider.listRepoCalls == 1)
        #expect(await h.provider.lastBranchRepos == ["proj/a", "proj/b"])
    }

    @Test func comparesAreCappedPerPoll() async {
        let h = Harness()
        let names = (0..<25).map { String(format: "b%02d", $0) }
        await h.set(names.map { head($0, "\($0)-1", at: h.clock.now - 30 * day) })
        _ = await h.poll(account)
        // b00 is het nieuwst, b24 het oudst.
        await h.set(names.enumerated().map { i, name in head(name, "\(name)-2", at: h.clock.now - Double(i) * 60) })
        await h.provider.set(comparisons: Dictionary(uniqueKeysWithValues: names.map {
            ("\($0)-1...\($0)-2", BranchComparison(ahead: 1, behind: 0))
        }))

        let result = await h.nextBranchPoll(account)

        #expect(result.branchPushes.count == 25)
        #expect(await h.provider.compareCalls == PollEngine.branchCompareLimit)
        let counted = Set(result.branchPushes.filter { $0.commits != nil }.map(\.branch))
        #expect(counted == Set(names.prefix(20)))
        #expect(result.branchPushes.allSatisfy { $0.kind == .push })
    }

    @Test func `The PR poll never waits for branches`() async {
        let h = Harness()
        // De eerste poll neemt bestaande PR's stil op; een PR erna is nieuw.
        _ = await h.engine.poll(accounts: [account], interval: 120, retention: .oneYear)
        let pr = PullRequest.fixture(accountId: account.id, repo: "proj/a")
        await h.provider.set(pullRequests: [pr])
        await h.provider.set(branchError: .network("kapot"))
        await h.set([head("main", "1", at: h.clock.now)])
        h.clock.advance(PollEngine.branchInterval)

        let result = await h.engine.poll(accounts: [account], interval: 120, retention: .oneYear)

        #expect(await h.provider.branchCalls == 0)
        #expect(result.newPullRequests.map(\.dedupKey) == [pr.dedupKey])
        #expect(result.statuses[account.id] == .ok(lastPoll: h.clock.now))
        #expect(await h.engine.pollBranches(accounts: [account]).isEmpty)
        #expect(await h.provider.branchCalls == 1)
    }

    @Test func `No branches for an account whose poll failed`() async {
        let h = Harness()
        await h.provider.set(error: .network("kapot"))
        await h.set([head("main", "1", at: h.clock.now)])

        let tick = await h.poll(account)

        #expect(tick.branchPushes.isEmpty)
        #expect(await h.provider.branchCalls == 0)
    }

    @Test func `A second branch round in the same interval fetches nothing`() async {
        let h = Harness()
        await h.set([head("main", "1", at: h.clock.now)])
        #expect(await h.poll(account).branchPushes.map(\.kind) == [.recent])

        #expect(await h.engine.pollBranches(accounts: [account]).isEmpty)
        #expect(await h.provider.branchCalls == 1)
    }

    @Test func `Reload fetches the branches again within the interval`() async {
        let h = Harness()
        await h.set([head("main", "1", at: h.clock.now)])
        _ = await h.poll(account)
        h.clock.advance(60)

        await h.engine.forceRefresh()
        _ = await h.poll(account)

        #expect(await h.provider.branchCalls == 2)
        #expect(await h.engine.lastBranchCheck() == h.clock.now)
    }

    @Test func `A round without errors sets the branch check time`() async {
        let h = Harness()
        #expect(await h.engine.lastBranchCheck() == nil)
        await h.set([head("main", "1", at: h.clock.now)])

        _ = await h.poll(account)

        #expect(await h.engine.lastBranchCheck() == h.clock.now)
    }

    @Test func `A failed branch round keeps the previous check time`() async {
        let h = Harness()
        await h.set([head("main", "1", at: h.clock.now)])
        _ = await h.poll(account)
        let checked = h.clock.now
        await h.provider.set(branchError: .network("kapot"))

        _ = await h.nextBranchPoll(account)

        #expect(await h.engine.lastBranchCheck() == checked)
    }

    @Test func `A push seen after a long gap keeps its commit date`() async {
        let h = Harness()
        let seededAt = h.clock.now
        await h.set([head("main", "1", at: seededAt - 30 * day)])
        _ = await h.poll(account)
        // De Mac sliep drie dagen; de commit is van de dag na de vorige keer lezen.
        h.clock.advance(3 * day)
        await h.set([head("main", "2", at: seededAt + day), head("feature/n", "n1", at: seededAt + 2 * day)])

        let tick = await h.poll(account)

        let pushedAt = Dictionary(uniqueKeysWithValues: tick.branchPushes.map { ($0.branch, $0.pushedAt) })
        #expect(pushedAt == ["main": seededAt + day, "feature/n": seededAt + 2 * day])
    }

    @Test func `A commit dated before the previous read counts from that read`() async {
        let h = Harness()
        await h.set([head("main", "1", at: h.clock.now - 30 * day)])
        _ = await h.poll(account)
        let readAt = h.clock.now
        // Een oude commit die nu pas gepusht werd (of een rebase met de oude datum).
        await h.set([head("main", "2", at: readAt - 5 * day), head("feature/o", "o1", at: readAt - 9 * day)])

        let tick = await h.nextBranchPoll(account)

        #expect(tick.branchPushes.count == 2)
        #expect(tick.branchPushes.allSatisfy { $0.pushedAt == readAt })
    }

    @Test func `A future commit date counts as now for a push`() async {
        let h = Harness()
        await h.set([head("main", "1", at: h.clock.now - 30 * day)])
        _ = await h.poll(account)
        await h.provider.set(comparisons: ["1...2": BranchComparison(ahead: 2, behind: 1)])
        await h.set([head("main", "2", at: h.clock.now + 7 * day)])

        let tick = await h.nextBranchPoll(account)

        #expect(tick.branchPushes.map(\.kind) == [.forcePush])
        #expect(tick.branchPushes.first?.pushedAt == h.clock.now)
    }

    @Test func `A push without a commit date is dated by the poll`() async {
        let h = Harness()
        await h.set([head("main", "1", at: nil)])
        _ = await h.poll(account)
        await h.set([head("main", "2", at: nil)])

        let tick = await h.nextBranchPoll(account)

        #expect(tick.branchPushes.first?.pushedAt == h.clock.now)
    }

    @Test func `Own pushes match the name or e-mail the service knows`() async {
        let h = Harness()
        await h.provider.set(identity: UserIdentity(names: ["Ada Lovelace"], emails: ["ada@work.example"]))
        let now = h.clock.now
        await h.set([
            head("by-mail", "1", at: now - day, authorId: nil, authorName: "A. L.", email: "ADA@work.example"),
            head("by-name", "2", at: now - day, authorId: nil, authorName: "ada lovelace", email: "ada@home.example"),
            head("other", "3", at: now - day, authorId: nil, authorName: "Grace", email: "grace@work.example"),
        ])

        let tick = await h.poll(account)

        let own = Dictionary(uniqueKeysWithValues: tick.branchPushes.map { ($0.branch, $0.isOwn) })
        #expect(own == ["by-mail": true, "by-name": true, "other": false])
        #expect(await h.provider.identityCalls == 1)
    }

    @Test func `The identity is asked once and again only after a failure`() async {
        let h = Harness()
        await h.provider.set(identityError: .network("kapot"))
        await h.set([head("main", "1", at: h.clock.now - day, authorId: nil, authorName: "Ada", email: nil)])

        // Een mislukte vraag laat de branches gewoon doorgaan, zonder eigen rijen.
        let failed = await h.poll(account)
        #expect(failed.branchPushes.map(\.isOwn) == [false])
        #expect(await h.provider.identityCalls == 1)

        await h.provider.set(identityError: nil)
        await h.provider.set(identity: UserIdentity(names: ["Ada"], emails: []))
        await h.set([head("main", "2", at: h.clock.now + PollEngine.branchInterval, authorId: nil, authorName: "Ada", email: nil)])
        let next = await h.nextBranchPoll(account)
        #expect(next.branchPushes.map(\.isOwn) == [true])
        #expect(await h.provider.identityCalls == 2)

        _ = await h.nextBranchPoll(account)
        _ = await h.nextBranchPoll(account)
        #expect(await h.provider.identityCalls == 2)
    }
}
