import Foundation
import Testing
@testable import PullwatchCore

@Suite struct HistoryTests {
    let t0 = Date(timeIntervalSince1970: 1_760_000_000)
    let day: TimeInterval = 86_400

    @Test func addsNewestFirstAcrossKinds() {
        var history = History()
        history.add(pullRequests: [.fixture(number: 1)], tags: [], at: t0)
        history.add(pullRequests: [], tags: [.fixture(name: "v1")], at: t0 + 60)
        #expect(history.items.map(\.entry.kind) == [.tag, .pullRequest])
        #expect(history.unreadCount == 2)
        history.add(pullRequests: [.fixture(number: 1)], tags: [], at: t0 + 120)
        #expect(history.items.count == 2)
        #expect(history.items.first?.entry.kind == .pullRequest)
        #expect(history.items.first?.detectedAt == t0 + 120)
    }

    @Test func latestFiltersByKind() {
        var history = History()
        history.add(pullRequests: [.fixture(number: 1), .fixture(number: 2), .fixture(number: 3)],
                    tags: [.fixture(name: "v1")], at: t0)
        #expect(history.latest(.tag, limit: 5).count == 1)
        #expect(history.latest(.pullRequest, limit: 2).count == 2)
        #expect(history.latest(.pullRequest, limit: 2).allSatisfy { $0.entry.kind == .pullRequest })
    }

    @Test func pruneRespectsRetention() {
        var history = History()
        history.add(pullRequests: [.fixture(number: 1)], tags: [], at: t0)
        let now = t0 + 62 * day
        var twoMonths = history
        let r_twoMonths = twoMonths.prune(now: now, retention: .twoMonths)
        #expect(r_twoMonths)
        #expect(twoMonths.items.isEmpty)
        var sixMonths = history
        let r_sixMonths = sixMonths.prune(now: now, retention: .sixMonths)
        #expect(!r_sixMonths)
        #expect(sixMonths.items.count == 1)
        var forever = history
        let r_forever = forever.prune(now: t0 + 10_000 * day, retention: .forever)
        #expect(!r_forever)
        #expect(forever.items.count == 1)
    }

    @Test func retentionLabels() {
        #expect(HistoryRetention.allCases.map(\.label) == ["2 maanden", "6 maanden", "1 jaar", "Altijd"])
        #expect(HistoryRetention.oneYear.maxAge == 365 * day)
        #expect(HistoryRetention.forever.maxAge == nil)
    }

    @Test func searchMatchesTitleAuthorRepoCaseInsensitive() {
        var history = History()
        history.add(pullRequests: [.fixture(repo: "proj/api", number: 1, title: "Fix Login")],
                    tags: [.fixture(repo: "other/web", name: "v2")], at: t0)
        #expect(history.search("login", kind: nil).count == 1)
        #expect(history.search("SOMEONE", kind: nil).count == 2)
        #expect(history.search("OTHER/WEB", kind: nil).count == 1)
        #expect(history.search("  v2  ", kind: nil).count == 1)
        #expect(history.search("   ", kind: nil).count == 2)
        #expect(history.search("zzz", kind: nil).isEmpty)
    }

    @Test func searchCombinesKindFilter() {
        var history = History()
        history.add(pullRequests: [.fixture(number: 1, title: "release")],
                    tags: [.fixture(name: "release-1")], at: t0)
        #expect(history.search("release", kind: .tag).map(\.entry.kind) == [.tag])
        #expect(history.search("release", kind: .pullRequest).map(\.entry.kind) == [.pullRequest])
        #expect(history.search("", kind: .tag).count == 1)
    }

    @Test func searchSkipsNilAuthor() {
        let tag = Tag(accountId: fixedAccountId, repo: "a/b", name: "v1", authorName: nil,
                      webURL: URL(string: "https://example.com")!)
        var history = History()
        history.add(pullRequests: [], tags: [tag], at: t0)
        #expect(history.search("nil", kind: nil).isEmpty)
        #expect(history.search("v1", kind: nil).count == 1)
    }

    @Test func markReadAndRemoveAccount() {
        let other = UUID()
        var history = History()
        history.add(pullRequests: [.fixture(number: 1), .fixture(accountId: other, number: 2)], tags: [], at: t0)
        history.markRead(history.items[0].id)
        #expect(history.unreadCount == 1)
        history.markAllRead()
        #expect(history.unreadCount == 0)
        history.removeAccount(other)
        #expect(history.items.count == 1)
    }

    @Test func migratesRecentList() {
        var list = RecentList()
        list.add([.fixture(number: 1, createdAt: t0), .fixture(number: 2, createdAt: t0 + 1)], at: t0 + 100)
        list.markRead(PullRequest.fixture(number: 1).dedupKey)
        let history = History(migrating: list)
        #expect(history.items.count == 2)
        #expect(history.items.map(\.detectedAt) == list.items.map(\.detectedAt))
        #expect(history.items.map(\.isRead) == list.items.map(\.isRead))
        #expect(history.items.allSatisfy { $0.entry.kind == .pullRequest })
    }

    @Test func legacyConfigWithoutRetentionDefaultsToOneYear() throws {
        let json = #"{"accounts":[],"pollInterval":120}"#
        let config = try JSONDecoder().decode(AppConfig.self, from: Data(json.utf8))
        #expect(config.historyRetention == .oneYear)
        #expect(config.pollInterval == 120)
    }

    @Test func historyRoundTripsThroughJSON() throws {
        var history = History()
        history.add(pullRequests: [.fixture(number: 1)], tags: [.fixture(name: "v1")], at: t0)
        let data = try JSONEncoder().encode(history)
        #expect(try JSONDecoder().decode(History.self, from: data) == history)
    }
}
