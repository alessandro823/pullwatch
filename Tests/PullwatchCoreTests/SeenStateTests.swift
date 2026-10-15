import Foundation
import Testing
@testable import PullwatchCore

@Suite struct SeenStateTests {
    let t0 = Date(timeIntervalSince1970: 1_760_000_000)
    let day: TimeInterval = 24 * 3600

    @Test func markThenContains() {
        var state = SeenState()
        #expect(!state.contains("a"))
        state.mark("a", at: t0)
        #expect(state.contains("a"))
    }

    @Test func pruneRemovesEntriesOlderThan30Days() {
        var state = SeenState()
        state.mark("old", at: t0)
        state.mark("recent", at: t0 + 25 * day)
        state.prune(now: t0 + 31 * day)
        #expect(!state.contains("old"))
        #expect(state.contains("recent"))
    }

    @Test func markRefreshesTimestampSoPruneKeepsIt() {
        var state = SeenState()
        state.mark("a", at: t0)
        state.mark("a", at: t0 + 20 * day)
        state.prune(now: t0 + 40 * day)
        #expect(state.contains("a"))
    }

    @Test func roundTripsThroughJSONFileStore() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = JSONFileStore<SeenState>(url: dir.appending(path: "seen.json"))

        var state = SeenState()
        state.mark("a", at: t0)
        state.lastSettings["acc"] = Account.fixture(repos: ["p/r"]).filterSettings
        try store.save(state)

        #expect(try store.load() == state)
    }
}
