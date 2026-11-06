import Foundation
import Testing
@testable import PullwatchCore
import PullwatchTestSupport

@Suite struct HistoryTests {
    let t0 = Date.testStart
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

    @Test func setReadMarksOnlyTheGivenItemsBothWays() {
        var history = History()
        history.add(pullRequests: [.fixture(number: 1), .fixture(number: 2)], tags: [.fixture(name: "v1")], at: t0)
        let ids = history.items.map(\.id)

        let first = history.setRead([ids[0], ids[1]], true)
        #expect(first)
        #expect(history.unreadCount == 1)
        let again = history.setRead([ids[0]], true)
        #expect(!again, "al gelezen: niets veranderd")

        let unread = history.setRead([ids[0]], false)
        #expect(unread)
        #expect(history.unreadCount == 2)
        let unknown = history.setRead(["onbekend"], true)
        #expect(!unknown)
    }

    @Test func unreadCountPerKind() {
        var history = History()
        history.add(pullRequests: [.fixture(number: 1), .fixture(number: 2)], tags: [.fixture(name: "v1")], at: t0)
        #expect(history.unreadCount(.pullRequest) == 2)
        #expect(history.unreadCount(.tag) == 1)
    }

    @Test func groupsByProjectPerAccountSortedWithUnreadCounts() {
        let other = UUID()
        var history = History()
        history.add(pullRequests: [
            .fixture(repo: "FerroHEALTH/portal", number: 1),
            .fixture(repo: "FerroHEALTH/api", number: 2),
            .fixture(repo: "Code24/engine", number: 3),
            .fixture(accountId: other, repo: "acme/web", number: 4),
        ], tags: [.fixture(repo: "Lab/x")], at: t0)
        history.markRead(history.items.first { $0.entry.repo == "Code24/engine" }!.id)
        let groups = history.groups(.pullRequest, accountNames: [fixedAccountId: "Werk", other: "GitHub"])
        #expect(groups.map(\.name) == ["acme", "Code24", "FerroHEALTH"])
        #expect(groups.map(\.unreadCount) == [1, 0, 2])
        #expect(groups.first { $0.name == "FerroHEALTH" }?.id == HistoryGroup.ID(accountId: fixedAccountId, project: "FerroHEALTH"))
    }

    @Test func sameProjectNameInTwoAccountsGetsAccountName() {
        let other = UUID()
        var history = History()
        history.add(pullRequests: [.fixture(repo: "acme/a", number: 1), .fixture(accountId: other, repo: "acme/b", number: 2)], tags: [], at: t0)
        let names = history.groups(.pullRequest, accountNames: [fixedAccountId: "Werk", other: "GitHub"]).map(\.name)
        #expect(names == ["acme (GitHub)", "acme (Werk)"])
    }

    @Test func searchWithinGroup() {
        var history = History()
        history.add(pullRequests: [
            .fixture(repo: "FerroHEALTH/portal", number: 1, title: "Fix login"),
            .fixture(repo: "Code24/engine", number: 2, title: "Fix login too"),
        ], tags: [], at: t0)
        let group = HistoryGroup.ID(accountId: fixedAccountId, project: "FerroHEALTH")
        #expect(history.search("login", kind: .pullRequest, group: group).map(\.entry.repo) == ["FerroHEALTH/portal"])
        #expect(history.search("login", kind: .pullRequest, group: nil).count == 2)
    }

    @Test func searchOnAuthorAndRepo() {
        var history = History()
        history.add(pullRequests: [
            .fixture(repo: "P/api", number: 1, authorName: "ana"),
            .fixture(repo: "P/web", number: 2, authorName: "ana"),
            .fixture(repo: "p/API", number: 3, authorName: "bob"),
        ], tags: [.fixture(repo: "P/api")], at: t0)
        #expect(history.search("", kind: .pullRequest, author: "ana").map(\.entry.repo).sorted() == ["P/api", "P/web"])
        let api = HistoryRepo(accountId: fixedAccountId, repo: "P/api")
        #expect(history.search("", kind: .pullRequest, repo: api).count == 2)
        #expect(history.search("", kind: .tag, repo: api).count == 1)
        #expect(history.search("", kind: .pullRequest, author: "ana", repo: api).count == 1)
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
        #expect(Set(HistoryRetention.allCases.map(\.label)).count == HistoryRetention.allCases.count)
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

    @Test func mergeAddsNewAsReadSortedByCreatedAt() {
        var history = History()
        history.add(pullRequests: [.fixture(number: 1)], tags: [], at: t0 + 1000)
        let changed = history.merge(synced: [.fixture(number: 2, createdAt: t0)])
        #expect(changed)
        #expect(history.items.map(\.entry.dedupKey) == [
            PullRequest.fixture(number: 1).dedupKey, PullRequest.fixture(number: 2).dedupKey,
        ])
        #expect(history.items[1].isRead)
        #expect(history.items[1].detectedAt == t0)
    }

    @Test func mergeUpdatesStateWithoutTouchingReadOrDetectedAt() {
        var history = History()
        history.add(pullRequests: [.fixture(number: 1)], tags: [], at: t0 + 1000)
        history.add(pullRequests: [.fixture(number: 2)], tags: [], at: t0 + 2000)
        let closed = t0 + 5000
        history.merge(synced: [.fixture(number: 1, title: "Nieuwe titel", state: .merged, closedAt: closed)])
        let item = history.items[1]
        #expect(item.entry.dedupKey == PullRequest.fixture(number: 1).dedupKey)
        #expect(!item.isRead)
        #expect(item.detectedAt == t0 + 1000)
        #expect(item.entry.prState == .merged)
        #expect(item.entry.title == "Nieuwe titel")
        guard case .pullRequest(let pr) = item.entry else { Issue.record("geen PR"); return }
        #expect(pr.closedAt == closed)
    }

    /// Klaar voor review of weer draft: de geschiedenis volgt, zodat het icoon klopt.
    @Test(arguments: [true, false])
    func `Merge updates whether the pull request is a draft`(isDraft: Bool) throws {
        var history = History()
        history.add(pullRequests: [.fixture(number: 1, isDraft: !isDraft)], tags: [], at: t0)
        let changed = history.merge(synced: [.fixture(number: 1, isDraft: isDraft)])
        #expect(changed)
        let item = try #require(history.items.first)
        guard case .pullRequest(let pr) = item.entry else { Issue.record("geen PR"); return }
        #expect(pr.isDraft == isDraft)
    }

    @Test func mergeUnchangedReturnsFalse() {
        var history = History()
        let synced = [PullRequest.fixture(number: 1, state: .closed, closedAt: t0 + 10)]
        let first = history.merge(synced: synced)
        let second = history.merge(synced: synced)
        #expect(first)
        #expect(!second)
    }

    @Test func mergeIgnoresTags() {
        var history = History()
        history.add(pullRequests: [], tags: [.fixture(repo: "proj/api", name: "v1")], at: t0)
        let before = history
        history.merge(synced: [.fixture(repo: "proj/api", number: 1, createdAt: t0 - 100)])
        #expect(history.items.count == 2)
        #expect(history.items.first == before.items.first)
        #expect(history.items.first?.entry.prState == nil)
    }

    @Test func mergeManySyncedPullRequests() {
        let accounts = (0..<3).map { _ in UUID() }
        var history = History()
        // Bestaande, gemelde PR's: elk tiende nummer van elk account.
        let existing = accounts.flatMap { account in
            stride(from: 0, to: 1000, by: 10).map { PullRequest.fixture(accountId: account, number: $0, createdAt: t0 + Double($0)) }
        }
        history.add(pullRequests: existing, tags: [], at: t0 + 10_000)
        let synced = accounts.flatMap { account in
            (0..<1000).map { PullRequest.fixture(accountId: account, number: $0, createdAt: t0 + Double($0), state: .merged) }
        }

        let changed = history.merge(synced: synced.shuffled())
        #expect(changed)

        #expect(history.items.count == 3000)
        #expect(Set(history.items.map(\.id)).count == 3000)
        #expect(history.items.allSatisfy { $0.entry.prState == .merged })
        // Gemelde items houden detectedAt en ongelezen-status en staan bovenaan.
        let notified = history.items.prefix(existing.count)
        #expect(notified.allSatisfy { !$0.isRead && $0.detectedAt == t0 + 10_000 })
        #expect(Set(notified.map(\.id)) == Set(existing.map(\.dedupKey)))
        let backfilled = history.items.dropFirst(existing.count)
        #expect(backfilled.allSatisfy { $0.isRead })
        #expect(zip(backfilled, backfilled.dropFirst()).allSatisfy { $0.detectedAt >= $1.detectedAt })
        let changedAgain = history.merge(synced: synced)
        #expect(!changedAgain)
    }

    @Test func mergeKeepsInsertionOrderForEqualDates() {
        var history = History()
        history.add(pullRequests: [.fixture(number: 1)], tags: [], at: t0)
        history.merge(synced: [.fixture(number: 2, createdAt: t0), .fixture(number: 3, createdAt: t0)])
        #expect(history.items.map(\.entry.dedupKey) == [1, 2, 3].map { PullRequest.fixture(number: $0).dedupKey })
    }

    @Test func mergeDuplicateInOneBatchKeepsLastState() {
        var history = History()
        history.merge(synced: [.fixture(number: 1), .fixture(number: 1, state: .merged, closedAt: t0 + 5)])
        #expect(history.items.count == 1)
        #expect(history.items.first?.entry.prState == .merged)
    }

    @Test func mergeSkipsNewPullRequestsBeforeCutoff() {
        var history = History()
        let changed = history.merge(synced: [.fixture(number: 1, createdAt: t0 - 100, state: .open)], notBefore: t0)
        #expect(!changed)
        #expect(history.items.isEmpty)

        history.merge(synced: [.fixture(number: 2, createdAt: t0)], notBefore: t0)
        #expect(history.items.map(\.entry.dedupKey) == [PullRequest.fixture(number: 2).dedupKey])
    }

    @Test func mergeStillUpdatesExistingItemsBeforeCutoff() {
        var history = History()
        history.merge(synced: [.fixture(number: 1, createdAt: t0 - 100)])
        let changed = history.merge(synced: [.fixture(number: 1, createdAt: t0 - 100, state: .closed, closedAt: t0)], notBefore: t0)
        #expect(changed)
        #expect(history.items.first?.entry.prState == .closed)
    }
}

@Suite("History opstarten")
struct HistoryInitialTests {
    @Test func opgeslagenGeschiedenisWintVanLegacy() {
        let stored = History()
        var legacy = RecentList()
        legacy.add([.fixture(number: 1)], at: Date())
        let result = History.initial(stored: stored, legacy: legacy)
        #expect(result.history.items.isEmpty)
        #expect(!result.needsSave)
    }

    @Test func legacyWordtGemigreerdEnMoetOpgeslagen() {
        var legacy = RecentList()
        legacy.add([.fixture(number: 1)], at: Date())
        let result = History.initial(stored: nil, legacy: legacy)
        #expect(result.history.items.count == 1)
        #expect(result.needsSave)
    }

    @Test func onleesbareGeschiedenisMigreertLegacyNiet() {
        var legacy = RecentList()
        legacy.add([.fixture(number: 1)], at: Date())
        let result = History.initial(stored: nil, storedUnreadable: true, legacy: legacy)
        #expect(result.history.items.isEmpty)
        #expect(!result.needsSave)
    }

    @Test func nietsGeeftLeegZonderOpslaan() {
        let result = History.initial(stored: nil, legacy: nil)
        #expect(result.history.items.isEmpty)
        #expect(!result.needsSave)
    }
}
