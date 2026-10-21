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
