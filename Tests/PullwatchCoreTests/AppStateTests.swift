import Foundation
import Testing
@testable import PullwatchCore

@Suite struct AppStateTests {
    let t0 = Date(timeIntervalSince1970: 1_760_000_000)

    @Test func configDefaults() {
        let config = AppConfig()
        #expect(config.accounts.isEmpty)
        #expect(config.pollInterval == 120)
    }

    @Test func intervalIsClamped() {
        #expect(AppConfig(pollInterval: 5).clampedInterval == 60)
        #expect(AppConfig(pollInterval: 5000).clampedInterval == 900)
        #expect(AppConfig(pollInterval: 300).clampedInterval == 300)
    }

    @Test func accountsWithoutOrganizationAreNotPolled() {
        let config = AppConfig(accounts: [Account.fixture(organization: ""), Account.fixture(organization: "acme")])
        #expect(config.pollableAccounts.map(\.organization) == ["acme"])
    }

    @Test func configRoundTrips() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = JSONFileStore<AppConfig>(url: dir.appending(path: "config.json"))
        let config = AppConfig(accounts: [Account.fixture(repoWatch: ["a/b": .none])], pollInterval: 300)
        try store.save(config)
        #expect(try store.load() == config)
    }

    @Test func recentAddsNewestFirstAsUnread() {
        var list = RecentList()
        let a = PullRequest.fixture(number: 1, createdAt: t0)
        let b = PullRequest.fixture(number: 2, createdAt: t0 + 60)
        list.add([a, b], at: t0 + 120)
        #expect(list.items.map(\.pullRequest) == [b, a])
        #expect(list.unreadCount == 2)
    }

    @Test func recentReplacesDuplicateAndCapsAt50() {
        var list = RecentList()
        list.add((1...60).map { PullRequest.fixture(number: $0, createdAt: t0 + Double($0)) }, at: t0)
        #expect(list.items.count == 50)
        #expect(list.items.first?.pullRequest.number == 60)

        list.add([PullRequest.fixture(number: 55, createdAt: t0 + 1000)], at: t0)
        #expect(list.items.count == 50)
        #expect(list.items.filter { $0.pullRequest.number == 55 }.count == 1)
        #expect(list.items.first?.pullRequest.number == 55)
    }

    @Test func markReadAndMarkAllRead() {
        var list = RecentList()
        let a = PullRequest.fixture(number: 1)
        let b = PullRequest.fixture(number: 2)
        list.add([a, b], at: t0)
        list.markRead(a.dedupKey)
        #expect(list.unreadCount == 1)
        list.markAllRead()
        #expect(list.unreadCount == 0)
    }

    @Test func removeAccountDropsItsItems() {
        var list = RecentList()
        let other = UUID()
        list.add([PullRequest.fixture(accountId: fixedAccountId, number: 1), PullRequest.fixture(accountId: other, number: 1)], at: t0)
        list.removeAccount(fixedAccountId)
        #expect(list.items.map(\.pullRequest.accountId) == [other])
    }
}
