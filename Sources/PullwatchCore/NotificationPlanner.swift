import Foundation

public enum PlannedNotification: Equatable, Sendable {
    case pullRequest(PullRequest)
    case tag(Tag)
    case summary(kind: ItemKind, count: Int, lines: [String])
}

public enum NotificationPlanner {
    public static let burstThreshold = 3

    /// PR's eerst, dan tags; elk deel wordt apart tegen de burst-drempel gehouden.
    public static func plan(pullRequests: [PullRequest], tags: [Tag]) -> [PlannedNotification] {
        planKind(pullRequests, kind: .pullRequest, single: { .pullRequest($0) }, line: { "\($0.repo): \($0.title)" })
            + planKind(tags, kind: .tag, single: { .tag($0) }, line: { "\($0.repo): \($0.name)" })
    }

    private static func planKind<T>(
        _ items: [T],
        kind: ItemKind,
        single: (T) -> PlannedNotification,
        line: (T) -> String
    ) -> [PlannedNotification] {
        if items.count > burstThreshold {
            return [.summary(kind: kind, count: items.count, lines: items.prefix(3).map(line))]
        }
        return items.map(single)
    }
}
