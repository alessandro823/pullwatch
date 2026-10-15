import Foundation

public struct RecentItem: Codable, Equatable, Sendable, Identifiable {
    public var pullRequest: PullRequest
    public var detectedAt: Date
    public var isRead: Bool

    public var id: String { pullRequest.dedupKey }
}

public struct RecentList: Codable, Equatable, Sendable {
    public static let capacity = 50

    public private(set) var items: [RecentItem] = []

    public init() {}

    public var unreadCount: Int {
        items.filter { !$0.isRead }.count
    }

    public mutating func add(_ prs: [PullRequest], at date: Date) {
        for pr in prs.sorted(by: { $0.createdAt < $1.createdAt }) {
            items.removeAll { $0.id == pr.dedupKey }
            items.insert(RecentItem(pullRequest: pr, detectedAt: date, isRead: false), at: 0)
        }
        if items.count > Self.capacity {
            items.removeLast(items.count - Self.capacity)
        }
    }

    public mutating func markRead(_ key: String) {
        guard let index = items.firstIndex(where: { $0.id == key }) else { return }
        items[index].isRead = true
    }

    public mutating func markAllRead() {
        for index in items.indices {
            items[index].isRead = true
        }
    }

    public mutating func removeAccount(_ id: UUID) {
        items.removeAll { $0.pullRequest.accountId == id }
    }
}
