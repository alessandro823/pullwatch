import Foundation

public enum NotificationKind: Equatable, Sendable {
    case pullRequest, tag, completed
}

public enum PlannedNotification: Equatable, Sendable {
    case pullRequest(PullRequest)
    case tag(Tag)
    case completed(PullRequest)
    case summary(kind: NotificationKind, count: Int, lines: [String])
}

public enum NotificationPlanner {
    public static let burstThreshold = 3

    /// PR's eerst, dan tags, dan completed PR's; elk deel wordt apart tegen de burst-drempel gehouden.
    public static func plan(pullRequests: [PullRequest], tags: [Tag], completed: [PullRequest] = []) -> [PlannedNotification] {
        planKind(pullRequests, kind: .pullRequest, single: { .pullRequest($0) }, line: { "\($0.repo): \($0.title)" })
            + planKind(tags, kind: .tag, single: { .tag($0) }, line: { "\($0.repo): \($0.name)" })
            + planKind(completed, kind: .completed, single: { .completed($0) }, line: { "\($0.repo): \($0.title)" })
    }

    /// Laat weg waarvoor de repo op "geen melding" staat; het item zelf blijft gevolgd.
    public static func audible(
        pullRequests: [PullRequest], tags: [Tag], completed: [PullRequest], accounts: [Account]
    ) -> (pullRequests: [PullRequest], tags: [Tag], completed: [PullRequest]) {
        let byId = Dictionary(accounts.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        func notifies(_ accountId: UUID, _ repo: String, _ field: KeyPath<WatchSet, Bool>) -> Bool {
            byId[accountId]?.watch(for: repo)[keyPath: field] ?? true
        }
        return (
            pullRequests.filter { notifies($0.accountId, $0.repo, \.notifyPRs) },
            tags.filter { notifies($0.accountId, $0.repo, \.notifyTags) },
            completed.filter { notifies($0.accountId, $0.repo, \.notifyCompleted) }
        )
    }

    private static func planKind<T>(
        _ items: [T],
        kind: NotificationKind,
        single: (T) -> PlannedNotification,
        line: (T) -> String
    ) -> [PlannedNotification] {
        if items.count > burstThreshold {
            return [.summary(kind: kind, count: items.count, lines: items.prefix(3).map(line))]
        }
        return items.map(single)
    }
}
