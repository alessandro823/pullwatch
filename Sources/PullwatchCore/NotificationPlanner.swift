import Foundation

public enum PlannedNotification: Equatable, Sendable {
    case single(PullRequest)
    case summary(count: Int, lines: [String])
}

public enum NotificationPlanner {
    public static let burstThreshold = 3

    public static func plan(_ prs: [PullRequest]) -> [PlannedNotification] {
        if prs.count > burstThreshold {
            let lines = prs.prefix(3).map { "\($0.repo): \($0.title)" }
            return [.summary(count: prs.count, lines: lines)]
        }
        return prs.map { .single($0) }
    }
}
