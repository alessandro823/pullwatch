import Foundation
import Testing
@testable import PullwatchCore
import PullwatchTestSupport

/// Een PR in de rij om vanzelf te mergen: wanneer hij telt, hoe oude JSON leest, en hoe de poll
/// en de geschiedenis hem bijhouden.
@Suite struct MergeQueueTests {
    let entry = MergeQueueEntry(kind: .mergeQueue, position: 2, enqueuedAt: Date(timeIntervalSince1970: 1_760_100_000))

    func queued(_ pr: PullRequest, _ entry: MergeQueueEntry?) -> PullRequest {
        var pr = pr
        pr.mergeQueue = entry
        return pr
    }

    @Test func `Only an open ready pull request is queued`() {
        #expect(queued(.fixture(), entry).isQueued)
        #expect(!queued(.fixture(isDraft: true), entry).isQueued)
        #expect(!queued(.fixture(state: .merged), entry).isQueued)
        #expect(!PullRequest.fixture().isQueued)
    }

    /// Zoals GitHub: alleen een echte rij toont de PR als queued. Met auto-merge of auto-complete
    /// aan wacht hij op zijn checks en is hij nog gewoon open, ook al houdt Pullwatch die stand bij.
    @Test(arguments: [
        (MergeQueueEntry.Kind.mergeQueue, true),
        (.mergeTrain, true),
        (.autoMerge, false),
        (.autoComplete, false),
    ])
    func `Only a merge queue or merge train is queued`(kind: MergeQueueEntry.Kind, isQueued: Bool) {
        let pr = queued(.fixture(), MergeQueueEntry(kind: kind))
        #expect(pr.isQueued == isQueued)
        #expect(pr.mergeQueue?.kind == kind, "de stand blijft voor de melding uit de rij")
    }

    @Test func `History from before the queue still decodes`() throws {
        let json = #"""
            {"accountId":"00000000-0000-0000-0000-000000000001","repo":"proj/api","number":1,"title":"Fix bug",
             "authorId":"someone","authorName":"Someone","isDraft":false,"createdAt":782000000,
             "webURL":"https://example.com/proj/api/pr/1","state":"open"}
            """#
        let pr = try JSONDecoder().decode(PullRequest.self, from: Data(json.utf8))
        #expect(pr.mergeQueue == nil)
        #expect(pr.state == .open)
    }

    @Test func `The queue survives a round trip and an unknown kind still reads`() throws {
        let pr = queued(.fixture(), entry)
        let decoded = try JSONDecoder().decode(PullRequest.self, from: try JSONEncoder().encode(pr))
        #expect(decoded.mergeQueue == entry)

        let future = try JSONDecoder().decode(MergeQueueEntry.self, from: Data(#"{"kind":"somethingNew","position":3}"#.utf8))
        #expect(future == MergeQueueEntry(kind: .mergeQueue, position: 3))
    }

    @Test func `A poll updates the queue of open pull requests in the history`() {
        let pr = PullRequest.fixture()
        var history = History()
        history.add(pullRequests: [pr], tags: [], at: .now)

        let entered = history.update(mergeQueues: [pr.dedupKey: .some(entry)])
        #expect(entered)
        #expect(history.items.first?.entry.pullRequest?.mergeQueue == entry)
        let again = history.update(mergeQueues: [pr.dedupKey: .some(entry)])
        #expect(!again, "niets veranderd")
        let left = history.update(mergeQueues: [pr.dedupKey: .none])
        #expect(left)
        #expect(history.items.first?.entry.pullRequest?.mergeQueue == nil)
    }

    @Test func `A merged pull request leaves the queue`() {
        let pr = queued(.fixture(), entry)
        var history = History()
        history.add(pullRequests: [pr], tags: [], at: .now)

        let merged = history.merge(synced: [.fixture(state: .merged, closedAt: .now)])
        #expect(merged)

        let stored = history.items.first?.entry.pullRequest
        #expect(stored?.state == .merged)
        #expect(stored?.mergeQueue == nil)
        // Een PR die niet meer open is krijgt geen wachtrij meer van een poll.
        let requeued = history.update(mergeQueues: [pr.dedupKey: .some(entry)])
        #expect(!requeued)
    }

    @Test func `A poll reports the queue of every open pull request`() async {
        let account = Account.fixture()
        let provider = MockProvider()
        let clock = TestClock()
        let engine = PollEngine(makeProvider: { _ in provider }, store: nil, now: { clock.now })
        let inQueue = queued(.fixture(accountId: account.id, number: 1), entry)
        let ready = PullRequest.fixture(accountId: account.id, number: 2)
        await provider.set(pullRequests: [inQueue, ready])

        let result = await engine.poll(accounts: [account], interval: 120, retention: .oneYear)

        #expect(result.mergeQueues == [inQueue.dedupKey: .some(entry), ready.dedupKey: .none])
    }

    @Test func `A queued pull request still passes the filter like any open one`() {
        let settings = Account.fixture(hideOwn: false).filterSettings
        #expect(PRFilter.passes(queued(.fixture(), entry), settings: settings, currentUserId: nil))
    }
}

private extension HistoryEntry {
    var pullRequest: PullRequest? {
        if case .pullRequest(let pr) = self { pr } else { nil }
    }
}
