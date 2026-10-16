import Foundation
import Testing
@testable import PullwatchCore

private struct Harness {
    let clock: TestClock
    let providers: [UUID: MockProvider]
    let engine: PollEngine

    init(accounts: [Account], store: JSONFileStore<SeenState>? = nil) {
        let clock = TestClock()
        let providers = Dictionary(uniqueKeysWithValues: accounts.map { ($0.id, MockProvider()) })
        self.clock = clock
        self.providers = providers
        self.engine = PollEngine(makeProvider: { providers[$0.id]! }, store: store, now: { clock.now })
    }

    func provider(_ account: Account) -> MockProvider { providers[account.id]! }
}

@Suite struct PollEngineTests {
    let day: TimeInterval = 24 * 3600

    @Test func firstPollSeedsSilentlyThenNotifiesNewPR() async {
        let account = Account.fixture()
        let h = Harness(accounts: [account])
        let a = PullRequest.fixture(accountId: account.id, number: 1)
        await h.provider(account).set(pullRequests: [a])

        #expect(await h.engine.poll(accounts: [account], interval: 120, retention: .oneYear).newPullRequests.isEmpty)

        let b = PullRequest.fixture(accountId: account.id, number: 2)
        await h.provider(account).set(pullRequests: [a, b])
        h.clock.advance(120)
        #expect(await h.engine.poll(accounts: [account], interval: 120, retention: .oneYear).newPullRequests == [b])
    }

    @Test func notDueAccountIsSkippedUntilForceRefresh() async {
        let account = Account.fixture()
        let h = Harness(accounts: [account])
        _ = await h.engine.poll(accounts: [account], interval: 120, retention: .oneYear)

        let b = PullRequest.fixture(accountId: account.id, number: 2)
        await h.provider(account).set(pullRequests: [b])
        h.clock.advance(10)
        #expect(await h.engine.poll(accounts: [account], interval: 120, retention: .oneYear).newPullRequests.isEmpty)
        #expect(await h.provider(account).fetchCount == 1)

        await h.engine.forceRefresh()
        #expect(await h.engine.poll(accounts: [account], interval: 120, retention: .oneYear).newPullRequests == [b])
    }

    @Test func longOpenPullRequestIsNotRenotifiedAfterPrune() async {
        let account = Account.fixture()
        let h = Harness(accounts: [account])
        let a = PullRequest.fixture(accountId: account.id, number: 1)
        await h.provider(account).set(pullRequests: [a])

        for _ in 0..<4 {
            #expect(await h.engine.poll(accounts: [account], interval: 120, retention: .oneYear).newPullRequests.isEmpty)
            h.clock.advance(20 * day)
        }
    }

    @Test func addingRepoToAllowlistSeedsItsExistingPRsSilently() async {
        var account = Account.fixture(repoWatch: ["proj/a": .prs], newRepoDefault: .none)
        let h = Harness(accounts: [account])
        let a1 = PullRequest.fixture(accountId: account.id, repo: "proj/a", number: 1)
        let b1 = PullRequest.fixture(accountId: account.id, repo: "proj/b", number: 1)
        await h.provider(account).set(pullRequests: [a1, b1])
        _ = await h.engine.poll(accounts: [account], interval: 120, retention: .oneYear)

        account.repoWatch["proj/b"] = .prs
        h.clock.advance(120)
        #expect(await h.engine.poll(accounts: [account], interval: 120, retention: .oneYear).newPullRequests.isEmpty)

        let b2 = PullRequest.fixture(accountId: account.id, repo: "proj/b", number: 2)
        await h.provider(account).set(pullRequests: [a1, b1, b2])
        h.clock.advance(120)
        #expect(await h.engine.poll(accounts: [account], interval: 120, retention: .oneYear).newPullRequests == [b2])
    }

    @Test func turningOnDraftsDoesNotFloodWithExistingDrafts() async {
        var account = Account.fixture(includeDrafts: false)
        let h = Harness(accounts: [account])
        let draft = PullRequest.fixture(accountId: account.id, number: 1, isDraft: true)
        await h.provider(account).set(pullRequests: [draft])
        _ = await h.engine.poll(accounts: [account], interval: 120, retention: .oneYear)

        account.includeDrafts = true
        h.clock.advance(120)
        #expect(await h.engine.poll(accounts: [account], interval: 120, retention: .oneYear).newPullRequests.isEmpty)
    }

    @Test func draftBecomingReadyForReviewNotifies() async {
        let account = Account.fixture(includeDrafts: false)
        let h = Harness(accounts: [account])
        let draft = PullRequest.fixture(accountId: account.id, number: 1, isDraft: true)
        await h.provider(account).set(pullRequests: [draft])
        _ = await h.engine.poll(accounts: [account], interval: 120, retention: .oneYear)

        let ready = PullRequest.fixture(accountId: account.id, number: 1, isDraft: false)
        await h.provider(account).set(pullRequests: [ready])
        h.clock.advance(120)
        #expect(await h.engine.poll(accounts: [account], interval: 120, retention: .oneYear).newPullRequests == [ready])
    }

    @Test func ownPullRequestsAreHidden() async {
        let account = Account.fixture(hideOwn: true)
        let h = Harness(accounts: [account])
        _ = await h.engine.poll(accounts: [account], interval: 120, retention: .oneYear)

        let mine = PullRequest.fixture(accountId: account.id, number: 1, authorId: "me")
        let theirs = PullRequest.fixture(accountId: account.id, number: 2, authorId: "colleague")
        await h.provider(account).set(pullRequests: [mine, theirs])
        h.clock.advance(120)
        #expect(await h.engine.poll(accounts: [account], interval: 120, retention: .oneYear).newPullRequests == [theirs])
    }

    @Test func changingOrganizationReseedsSilently() async {
        var account = Account.fixture(organization: "old")
        let h = Harness(accounts: [account])
        _ = await h.engine.poll(accounts: [account], interval: 120, retention: .oneYear)

        account.organization = "new"
        let pr = PullRequest.fixture(accountId: account.id, number: 9)
        await h.provider(account).set(pullRequests: [pr])
        h.clock.advance(120)
        #expect(await h.engine.poll(accounts: [account], interval: 120, retention: .oneYear).newPullRequests.isEmpty)
    }

    @Test func failingAccountDoesNotBlockOthers() async {
        let good = Account.fixture()
        let bad = Account.fixture()
        let h = Harness(accounts: [good, bad])
        _ = await h.engine.poll(accounts: [good, bad], interval: 120, retention: .oneYear)

        let pr = PullRequest.fixture(accountId: good.id, number: 1)
        await h.provider(good).set(pullRequests: [pr])
        await h.provider(bad).set(error: .server(status: 500))
        h.clock.advance(120)
        let result = await h.engine.poll(accounts: [good, bad], interval: 120, retention: .oneYear)

        #expect(result.newPullRequests == [pr])
        #expect(result.statuses[good.id] == .ok(lastPoll: h.clock.now))
        #expect(result.statuses[bad.id] == .failed(.server(status: 500), since: h.clock.now))
    }

    @Test func unauthorizedIsReportedOnceAndInvalidatesCredentials() async {
        let account = Account.fixture()
        let h = Harness(accounts: [account])
        await h.provider(account).set(error: .unauthorized)

        #expect(await h.engine.poll(accounts: [account], interval: 120, retention: .oneYear).authFailures == [account.id])
        h.clock.advance(900)
        #expect(await h.engine.poll(accounts: [account], interval: 120, retention: .oneYear).authFailures.isEmpty)
        #expect(await h.provider(account).invalidateCount == 2)
    }

    @Test func failuresBackOffExponentially() async {
        let account = Account.fixture()
        let h = Harness(accounts: [account])
        _ = await h.engine.poll(accounts: [account], interval: 120, retention: .oneYear) // succes, fetchCount 1
        await h.provider(account).set(error: .network("offline"))

        h.clock.advance(120)
        _ = await h.engine.poll(accounts: [account], interval: 120, retention: .oneYear) // fout 1 → volgende over 240 s
        #expect(await h.provider(account).fetchCount == 2)

        h.clock.advance(200)
        _ = await h.engine.poll(accounts: [account], interval: 120, retention: .oneYear)
        #expect(await h.provider(account).fetchCount == 2)

        h.clock.advance(50)
        _ = await h.engine.poll(accounts: [account], interval: 120, retention: .oneYear)
        #expect(await h.provider(account).fetchCount == 3)
    }

    @Test func rateLimitIsRespectedEvenOnForceRefresh() async {
        let account = Account.fixture()
        let h = Harness(accounts: [account])
        _ = await h.engine.poll(accounts: [account], interval: 120, retention: .oneYear)
        await h.provider(account).set(error: .rateLimited(until: h.clock.now + 600))
        h.clock.advance(120)
        _ = await h.engine.poll(accounts: [account], interval: 120, retention: .oneYear)
        #expect(await h.provider(account).fetchCount == 2)

        await h.engine.forceRefresh()
        h.clock.advance(300)
        _ = await h.engine.poll(accounts: [account], interval: 120, retention: .oneYear)
        #expect(await h.provider(account).fetchCount == 2)
    }

    @Test func stateSurvivesRestartViaStore() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = JSONFileStore<SeenState>(url: dir.appending(path: "seen.json"))
        let account = Account.fixture()
        let a = PullRequest.fixture(accountId: account.id, number: 1)

        let first = Harness(accounts: [account], store: store)
        await first.provider(account).set(pullRequests: [a])
        _ = await first.engine.poll(accounts: [account], interval: 120, retention: .oneYear)

        let second = Harness(accounts: [account], store: store)
        let b = PullRequest.fixture(accountId: account.id, number: 2)
        await second.provider(account).set(pullRequests: [a, b])
        #expect(await second.engine.poll(accounts: [account], interval: 120, retention: .oneYear).newPullRequests == [b])
    }

    @Test func statusesCoverAllAccountsIncludingNotYetPolled() async {
        let account = Account.fixture()
        let other = Account.fixture()
        let h = Harness(accounts: [account, other])
        await h.provider(account).set(error: .network("x"))
        _ = await h.engine.poll(accounts: [account], interval: 120, retention: .oneYear)
        h.clock.advance(1)
        let result = await h.engine.poll(accounts: [account, other], interval: 120, retention: .oneYear)
        #expect(result.statuses.count == 2)
        #expect(result.statuses[other.id] == .ok(lastPoll: h.clock.now))
    }

    @Test func prunedSeenOfLongFailingAccountDoesNotReNotifyAfterRecovery() async {
        let account = Account.fixture()
        let h = Harness(accounts: [account])
        let a = PullRequest.fixture(accountId: account.id, number: 1)
        await h.provider(account).set(pullRequests: [a])
        _ = await h.engine.poll(accounts: [account], interval: 120, retention: .oneYear)

        await h.provider(account).set(error: .unauthorized)
        h.clock.advance(31 * day)
        _ = await h.engine.poll(accounts: [account], interval: 120, retention: .oneYear)

        await h.provider(account).set(error: nil)
        h.clock.advance(900)
        #expect(await h.engine.poll(accounts: [account], interval: 120, retention: .oneYear).newPullRequests.isEmpty)
    }

    @Test func overlappingPollDoesNotRefetchInFlightAccount() async {
        let account = Account.fixture()
        let gated = GatedProvider()
        let clock = TestClock()
        let engine = PollEngine(makeProvider: { _ in gated }, store: nil, now: { clock.now })

        let first = Task { await engine.poll(accounts: [account], interval: 120, retention: .oneYear) }
        for await _ in gated.started { break }

        let second = await engine.poll(accounts: [account], interval: 120, retention: .oneYear)
        #expect(second.newPullRequests.isEmpty)
        #expect(second.statuses[account.id] == .idle)
        #expect(await gated.fetchCount == 1)

        await gated.release()
        let firstResult = await first.value
        #expect(firstResult.statuses[account.id] == .ok(lastPoll: clock.now))
        #expect(await gated.fetchCount == 1)
    }

    @Test func rateLimitUntilIsClampedToOneHour() async {
        let account = Account.fixture()
        let h = Harness(accounts: [account])
        await h.provider(account).set(error: .rateLimited(until: h.clock.now + 30 * day))
        _ = await h.engine.poll(accounts: [account], interval: 120, retention: .oneYear)

        await h.provider(account).set(error: nil)
        h.clock.advance(3601)
        _ = await h.engine.poll(accounts: [account], interval: 120, retention: .oneYear) // currentUserId faalt eerst: fetchCount blijft 0
        #expect(await h.provider(account).fetchCount == 1)
    }
    // MARK: - Tags

    @Test func firstTagPollIsSilentThenNewTagNotifies() async {
        let account = Account.fixture(repoWatch: ["proj/a": .both])
        let h = Harness(accounts: [account])
        let v1 = Tag.fixture(accountId: account.id, repo: "proj/a", name: "v1")
        await h.provider(account).set(tags: [v1])

        #expect(await h.engine.poll(accounts: [account], interval: 120, retention: .oneYear).newTags.isEmpty)

        let v2 = Tag.fixture(accountId: account.id, repo: "proj/a", name: "v2")
        await h.provider(account).set(tags: [v1, v2])
        h.clock.advance(900)
        #expect(await h.engine.poll(accounts: [account], interval: 120, retention: .oneYear).newTags == [v2])
    }

    @Test func tagsNotRefetchedBeforeTagInterval() async {
        let account = Account.fixture(repoWatch: ["proj/a": .both])
        let h = Harness(accounts: [account])
        _ = await h.engine.poll(accounts: [account], interval: 120, retention: .oneYear)
        #expect(await h.provider(account).tagFetchCount == 1)

        h.clock.advance(120)
        _ = await h.engine.poll(accounts: [account], interval: 120, retention: .oneYear)
        #expect(await h.provider(account).fetchCount == 2)
        #expect(await h.provider(account).tagFetchCount == 1)

        await h.engine.forceRefresh()
        _ = await h.engine.poll(accounts: [account], interval: 120, retention: .oneYear)
        #expect(await h.provider(account).tagFetchCount == 2)
    }

    @Test func reenablingTagsReseedsSilently() async {
        var account = Account.fixture(repoWatch: ["proj/a": .both])
        let h = Harness(accounts: [account])
        let v1 = Tag.fixture(accountId: account.id, repo: "proj/a", name: "v1")
        await h.provider(account).set(tags: [v1])
        _ = await h.engine.poll(accounts: [account], interval: 120, retention: .oneYear)

        account.repoWatch["proj/a"] = .prs
        h.clock.advance(120)
        _ = await h.engine.poll(accounts: [account], interval: 120, retention: .oneYear)
        let v2 = Tag.fixture(accountId: account.id, repo: "proj/a", name: "v2")
        await h.provider(account).set(tags: [v1, v2])

        account.repoWatch["proj/a"] = .both
        h.clock.advance(900)
        #expect(await h.engine.poll(accounts: [account], interval: 120, retention: .oneYear).newTags.isEmpty)

        let v3 = Tag.fixture(accountId: account.id, repo: "proj/a", name: "v3")
        await h.provider(account).set(tags: [v1, v2, v3])
        h.clock.advance(900)
        #expect(await h.engine.poll(accounts: [account], interval: 120, retention: .oneYear).newTags == [v3])
    }

    @Test func noTagReposMeansNoTagFetch() async {
        let account = Account.fixture(newRepoDefault: .prs)
        let h = Harness(accounts: [account])
        _ = await h.engine.poll(accounts: [account], interval: 120, retention: .oneYear)
        #expect(await h.provider(account).fetchCount == 1)
        #expect(await h.provider(account).tagFetchCount == 0)
    }

    @Test func tagRepoCaseMismatchStillMatches() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = JSONFileStore<SeenState>(url: dir.appending(path: "seen.json"))
        let account = Account.fixture(repoWatch: ["Proj/A": .both])
        let h = Harness(accounts: [account], store: store)
        let v1 = Tag.fixture(accountId: account.id, repo: "Proj/A", name: "v1")
        await h.provider(account).set(tags: [v1])
        #expect(await h.engine.poll(accounts: [account], interval: 120, retention: .oneYear).newTags.isEmpty)

        let v2 = Tag.fixture(accountId: account.id, repo: "Proj/A", name: "v2")
        await h.provider(account).set(tags: [v1, v2])
        h.clock.advance(900)
        #expect(await h.engine.poll(accounts: [account], interval: 120, retention: .oneYear).newTags == [v2])
        #expect(try store.load()?.tagSeeded.keys.sorted() == ["\(account.id.uuidString):proj/a"])
    }

    @Test func tagRepoCaseDiffersBetweenConfigAndProvider() async {
        let account = Account.fixture(repoWatch: ["Proj/A": .both])
        let h = Harness(accounts: [account])
        let v1 = Tag.fixture(accountId: account.id, repo: "proj/a", name: "v1")
        await h.provider(account).set(tags: [v1])
        #expect(await h.engine.poll(accounts: [account], interval: 120, retention: .oneYear).newTags.isEmpty)

        let v2 = Tag.fixture(accountId: account.id, repo: "proj/a", name: "v2")
        await h.provider(account).set(tags: [v1, v2])
        h.clock.advance(900)
        #expect(await h.engine.poll(accounts: [account], interval: 120, retention: .oneYear).newTags == [v2])
    }

    @Test func tagOnlyServerErrorKeepsPullRequestsFlowing() async {
        let account = Account.fixture(repoWatch: ["proj/a": .both])
        let h = Harness(accounts: [account])
        let v1 = Tag.fixture(accountId: account.id, repo: "proj/a", name: "v1")
        await h.provider(account).set(tags: [v1])
        _ = await h.engine.poll(accounts: [account], interval: 120, retention: .oneYear) // PR's en tags stil geseed

        let pr = PullRequest.fixture(accountId: account.id, repo: "proj/a", number: 1)
        await h.provider(account).set(pullRequests: [pr])
        await h.provider(account).set(tagError: .server(status: 500))
        h.clock.advance(900)
        let result = await h.engine.poll(accounts: [account], interval: 120, retention: .oneYear)
        #expect(result.newPullRequests == [pr])
        #expect(result.newTags.isEmpty)
        #expect(result.statuses[account.id] == .ok(lastPoll: h.clock.now))
        #expect(await h.provider(account).tagFetchCount == 2)

        // PR is gemarkeerd: geen herhaalde melding; tags pas na 900 s opnieuw.
        await h.provider(account).set(tagError: nil)
        h.clock.advance(120)
        #expect(await h.engine.poll(accounts: [account], interval: 120, retention: .oneYear).newPullRequests.isEmpty)
        #expect(await h.provider(account).tagFetchCount == 2)

        // Tag-state is niet aangeraakt: repo blijft geseed, nieuwe tag wordt gemeld.
        let v2 = Tag.fixture(accountId: account.id, repo: "proj/a", name: "v2")
        await h.provider(account).set(tags: [v1, v2])
        h.clock.advance(780)
        #expect(await h.engine.poll(accounts: [account], interval: 120, retention: .oneYear).newTags == [v2])
        #expect(await h.provider(account).tagFetchCount == 3)
    }

    @Test func tagOnlyUnauthorizedKeepsPullRequestsFlowing() async {
        let account = Account.fixture(repoWatch: ["proj/a": .both])
        let h = Harness(accounts: [account])
        _ = await h.engine.poll(accounts: [account], interval: 120, retention: .oneYear)

        let pr = PullRequest.fixture(accountId: account.id, repo: "proj/a", number: 1)
        await h.provider(account).set(pullRequests: [pr])
        await h.provider(account).set(tagError: .unauthorized)
        h.clock.advance(900)
        let result = await h.engine.poll(accounts: [account], interval: 120, retention: .oneYear)
        #expect(result.newPullRequests == [pr])
        #expect(result.authFailures.isEmpty)
        #expect(result.statuses[account.id] == .ok(lastPoll: h.clock.now))
        #expect(await h.provider(account).invalidateCount == 0)
        #expect(await h.provider(account).tagFetchCount == 2)

        // Tags pas na tagInterval opnieuw geprobeerd.
        h.clock.advance(120)
        _ = await h.engine.poll(accounts: [account], interval: 120, retention: .oneYear)
        #expect(await h.provider(account).tagFetchCount == 2)
        h.clock.advance(780)
        _ = await h.engine.poll(accounts: [account], interval: 120, retention: .oneYear)
        #expect(await h.provider(account).tagFetchCount == 3)
    }

    @Test func tagOnlyRateLimitFailsAccount() async {
        let account = Account.fixture(repoWatch: ["proj/a": .both])
        let h = Harness(accounts: [account])
        _ = await h.engine.poll(accounts: [account], interval: 120, retention: .oneYear)

        h.clock.advance(900)
        let until = h.clock.now + 600
        await h.provider(account).set(tagError: .rateLimited(until: until))
        let result = await h.engine.poll(accounts: [account], interval: 120, retention: .oneYear)
        #expect(result.statuses[account.id] == .failed(.rateLimited(until: until), since: h.clock.now))
    }

    @Test func longTagOutageReseedsSilentlyAfterRecovery() async {
        let account = Account.fixture(repoWatch: ["proj/a": .both])
        let h = Harness(accounts: [account])
        let v1 = Tag.fixture(accountId: account.id, repo: "proj/a", name: "v1")
        await h.provider(account).set(tags: [v1])
        _ = await h.engine.poll(accounts: [account], interval: 120, retention: .oneYear) // tags stil geseed

        // 31 dagen lang slagen de PR-polls maar falen de tags.
        await h.provider(account).set(tagError: .server(status: 500))
        for _ in 1...31 {
            h.clock.advance(day)
            #expect(await h.engine.poll(accounts: [account], interval: 120, retention: .oneYear).statuses[account.id] == .ok(lastPoll: h.clock.now))
        }

        // Herstel: bestaande tags niet opnieuw melden, daarna wel nieuwe tags.
        await h.provider(account).set(tagError: nil)
        h.clock.advance(day)
        #expect(await h.engine.poll(accounts: [account], interval: 120, retention: .oneYear).newTags.isEmpty)

        let v2 = Tag.fixture(accountId: account.id, repo: "proj/a", name: "v2")
        await h.provider(account).set(tags: [v1, v2])
        h.clock.advance(900)
        #expect(await h.engine.poll(accounts: [account], interval: 120, retention: .oneYear).newTags == [v2])
    }

    @Test func repoUnavailableOnFirstTagPollSeedsSilentlyOnceReachable() async {
        let account = Account.fixture(repoWatch: ["proj/a": .both])
        let h = Harness(accounts: [account])
        let v1 = Tag.fixture(accountId: account.id, repo: "proj/a", name: "v1")
        await h.provider(account).set(tags: [v1])
        await h.provider(account).set(unavailableTagRepos: ["proj/a"]) // bv. 403 door SSO
        #expect(await h.engine.poll(accounts: [account], interval: 120, retention: .oneYear).newTags.isEmpty)

        // Toegang komt terug: bestaande tags stil seeden, daarna nieuwe tags wel melden.
        await h.provider(account).set(unavailableTagRepos: [])
        h.clock.advance(900)
        #expect(await h.engine.poll(accounts: [account], interval: 120, retention: .oneYear).newTags.isEmpty)

        let v2 = Tag.fixture(accountId: account.id, repo: "proj/a", name: "v2")
        await h.provider(account).set(tags: [v1, v2])
        h.clock.advance(900)
        #expect(await h.engine.poll(accounts: [account], interval: 120, retention: .oneYear).newTags == [v2])
    }

    @Test func seededRepoUnavailableLongerThanPruneAgeReseedsSilently() async {
        let account = Account.fixture(repoWatch: ["proj/a": .both])
        let h = Harness(accounts: [account])
        let v1 = Tag.fixture(accountId: account.id, repo: "proj/a", name: "v1")
        await h.provider(account).set(tags: [v1])
        _ = await h.engine.poll(accounts: [account], interval: 120, retention: .oneYear)

        await h.provider(account).set(unavailableTagRepos: ["proj/a"])
        for _ in 1...31 {
            h.clock.advance(day)
            _ = await h.engine.poll(accounts: [account], interval: 120, retention: .oneYear)
        }

        await h.provider(account).set(unavailableTagRepos: [])
        h.clock.advance(day)
        #expect(await h.engine.poll(accounts: [account], interval: 120, retention: .oneYear).newTags.isEmpty)
    }

    @Test func newTagsAreSortedByRepoThenName() async {
        let account = Account.fixture(repoWatch: ["proj/a": .both, "proj/b": .tags])
        let h = Harness(accounts: [account])
        _ = await h.engine.poll(accounts: [account], interval: 120, retention: .oneYear)

        let b1 = Tag.fixture(accountId: account.id, repo: "proj/b", name: "v1")
        let a2 = Tag.fixture(accountId: account.id, repo: "proj/a", name: "v2")
        let a1 = Tag.fixture(accountId: account.id, repo: "proj/a", name: "v1")
        await h.provider(account).set(tags: [b1, a2, a1])
        h.clock.advance(900)
        #expect(await h.engine.poll(accounts: [account], interval: 120, retention: .oneYear).newTags == [a1, a2, b1])
    }

    // MARK: - Sync

    @Test func firstSyncUsesRetentionWindow() async {
        let account = Account.fixture()
        let h = Harness(accounts: [account])
        _ = await h.engine.poll(accounts: [account], interval: 120, retention: .twoMonths)
        #expect(await h.provider(account).lastSyncSince == Date??.some(h.clock.now - 61 * day))

        let other = Account.fixture()
        let h2 = Harness(accounts: [other])
        _ = await h2.engine.poll(accounts: [other], interval: 120, retention: .forever)
        #expect(await h2.provider(other).lastSyncSince == Date??.some(nil))
    }

    @Test func laterSyncUsesLastSyncMinusOverlap() async {
        let account = Account.fixture()
        let h = Harness(accounts: [account])
        let t = h.clock.now
        _ = await h.engine.poll(accounts: [account], interval: 120, retention: .oneYear)

        h.clock.advance(900)
        _ = await h.engine.poll(accounts: [account], interval: 120, retention: .oneYear)
        #expect(await h.provider(account).syncCount == 2)
        #expect(await h.provider(account).lastSyncSince == Date??.some(t - 3600))
    }

    @Test func syncRunsEvery900Seconds() async {
        let account = Account.fixture()
        let h = Harness(accounts: [account])
        _ = await h.engine.poll(accounts: [account], interval: 120, retention: .oneYear)
        #expect(await h.provider(account).syncCount == 1)

        h.clock.advance(120)
        _ = await h.engine.poll(accounts: [account], interval: 120, retention: .oneYear)
        #expect(await h.provider(account).syncCount == 1)

        h.clock.advance(780)
        _ = await h.engine.poll(accounts: [account], interval: 120, retention: .oneYear)
        #expect(await h.provider(account).syncCount == 2)

        await h.engine.forceRefresh()
        _ = await h.engine.poll(accounts: [account], interval: 120, retention: .oneYear)
        #expect(await h.provider(account).syncCount == 3)
    }

    @Test func syncResultIsFiltered() async {
        let account = Account.fixture(repoWatch: ["proj/x": .none], hideOwn: true)
        let h = Harness(accounts: [account])
        let hidden = PullRequest.fixture(accountId: account.id, repo: "proj/x", number: 1, state: .merged)
        let visible = PullRequest.fixture(accountId: account.id, repo: "proj/a", number: 2, state: .closed)
        let mine = PullRequest.fixture(accountId: account.id, repo: "proj/a", number: 3, authorId: "me", state: .merged)
        await h.provider(account).set(syncedPullRequests: [hidden, visible, mine])

        let result = await h.engine.poll(accounts: [account], interval: 120, retention: .oneYear)
        #expect(result.syncedPullRequests == [visible])
    }

    @Test func syncDoesNotNotifyOrMarkSeen() async {
        let account = Account.fixture()
        let h = Harness(accounts: [account])
        _ = await h.engine.poll(accounts: [account], interval: 120, retention: .oneYear)

        let five = PullRequest.fixture(accountId: account.id, number: 5)
        let six = PullRequest.fixture(accountId: account.id, number: 6)
        await h.provider(account).set(pullRequests: [five])
        await h.provider(account).set(syncedPullRequests: [five, six])
        h.clock.advance(900)
        let second = await h.engine.poll(accounts: [account], interval: 120, retention: .oneYear)
        #expect(second.newPullRequests == [five])
        #expect(second.syncedPullRequests == [five, six])

        // #6 kwam alleen via de sync binnen en is dus niet als gezien gemarkeerd.
        await h.provider(account).set(pullRequests: [five, six])
        h.clock.advance(120)
        #expect(await h.engine.poll(accounts: [account], interval: 120, retention: .oneYear).newPullRequests == [six])
    }

    @Test func syncErrorKeepsAccountOk() async {
        let account = Account.fixture()
        let h = Harness(accounts: [account])
        await h.provider(account).set(syncError: .server(status: 500))
        let first = await h.engine.poll(accounts: [account], interval: 120, retention: .oneYear)
        #expect(first.statuses[account.id] == .ok(lastPoll: h.clock.now))
        #expect(first.syncedPullRequests.isEmpty)

        let pr = PullRequest.fixture(accountId: account.id, number: 1)
        await h.provider(account).set(pullRequests: [pr])
        await h.provider(account).set(syncError: nil)
        h.clock.advance(900)
        let second = await h.engine.poll(accounts: [account], interval: 120, retention: .oneYear)
        #expect(second.newPullRequests == [pr])
        #expect(second.statuses[account.id] == .ok(lastPoll: h.clock.now))
        // Mislukte sync zette geen mark: dit is weer een eerste sync.
        #expect(await h.provider(account).syncCount == 2)
        #expect(await h.provider(account).lastSyncSince == Date??.some(h.clock.now - 365 * day))
    }

    @Test func syncRateLimitPostponesOnlySync() async {
        let account = Account.fixture()
        let h = Harness(accounts: [account])
        let t = h.clock.now
        await h.provider(account).set(syncError: .rateLimited(until: t + 600))
        let first = await h.engine.poll(accounts: [account], interval: 120, retention: .oneYear)
        #expect(first.statuses[account.id] == .ok(lastPoll: t))
        await h.provider(account).set(syncError: nil)

        h.clock.advance(120)
        _ = await h.engine.poll(accounts: [account], interval: 120, retention: .oneYear)
        #expect(await h.provider(account).fetchCount == 2)
        #expect(await h.provider(account).syncCount == 1)

        h.clock.advance(360)
        _ = await h.engine.poll(accounts: [account], interval: 120, retention: .oneYear)
        #expect(await h.provider(account).syncCount == 1)

        h.clock.advance(120)
        _ = await h.engine.poll(accounts: [account], interval: 120, retention: .oneYear)
        #expect(await h.provider(account).syncCount == 2)
    }

    @Test func syncRateLimitIsClampedToOneHour() async {
        let account = Account.fixture()
        let h = Harness(accounts: [account])
        await h.provider(account).set(syncError: .rateLimited(until: h.clock.now + 30 * day))
        _ = await h.engine.poll(accounts: [account], interval: 120, retention: .oneYear)
        await h.provider(account).set(syncError: nil)

        h.clock.advance(3600)
        _ = await h.engine.poll(accounts: [account], interval: 120, retention: .oneYear)
        #expect(await h.provider(account).syncCount == 2)
    }

    @Test func settingsChangeTriggersFullResync() async {
        var account = Account.fixture(includeDrafts: false)
        let h = Harness(accounts: [account])
        _ = await h.engine.poll(accounts: [account], interval: 120, retention: .oneYear)

        account.includeDrafts = true
        h.clock.advance(900)
        _ = await h.engine.poll(accounts: [account], interval: 120, retention: .oneYear)
        #expect(await h.provider(account).syncCount == 2)
        #expect(await h.provider(account).lastSyncSince == Date??.some(h.clock.now - 365 * day))
    }

    @Test func retentionChangeTriggersFullResync() async {
        let account = Account.fixture()
        let h = Harness(accounts: [account])
        _ = await h.engine.poll(accounts: [account], interval: 120, retention: .oneYear)

        h.clock.advance(900)
        _ = await h.engine.poll(accounts: [account], interval: 120, retention: .sixMonths)
        #expect(await h.provider(account).syncCount == 2)
        #expect(await h.provider(account).lastSyncSince == Date??.some(h.clock.now - 183 * day))
    }

    @Test func removedAccountForgetsSyncMark() async {
        let account = Account.fixture()
        let h = Harness(accounts: [account])
        _ = await h.engine.poll(accounts: [account], interval: 120, retention: .oneYear)

        h.clock.advance(120)
        _ = await h.engine.poll(accounts: [], interval: 120, retention: .oneYear)
        _ = await h.engine.poll(accounts: [account], interval: 120, retention: .oneYear)
        #expect(await h.provider(account).syncCount == 2)
        #expect(await h.provider(account).lastSyncSince == Date??.some(h.clock.now - 365 * day))
    }
}
