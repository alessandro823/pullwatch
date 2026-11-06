public import Foundation

/// Project (Azure DevOps) of eigenaar (GitHub) binnen één account: het deel van de repo-naam vóór de "/".
public struct HistoryGroup: Hashable, Sendable, Identifiable {
    public struct ID: Hashable, Sendable, Codable {
        public let accountId: UUID
        public let project: String

        public init(accountId: UUID, project: String) {
            self.accountId = accountId
            self.project = project
        }

        init(_ entry: HistoryEntry) {
            self.init(accountId: entry.accountId, repo: entry.repo)
        }

        public init(accountId: UUID, repo: String) {
            let project = repo.split(separator: "/", maxSplits: 1).first.map(String.init) ?? repo
            self.init(accountId: accountId, project: project)
        }
    }

    /// De repo-naam zonder de groep ervoor, zoals in een lijst die al op die groep filtert:
    /// `openEHR/specifications` wordt `specifications`, `groep/sub/project` wordt `sub/project`.
    /// Een naam zonder "/" blijft zoals hij is.
    public static func repoName(_ repo: String) -> String {
        let parts = repo.split(separator: "/", maxSplits: 1)
        return parts.count == 2 ? String(parts[1]) : repo
    }

    /// Groepen met hun teller, op naam; dezelfde projectnaam bij twee accounts krijgt de accountnaam erachter.
    static func named(_ counts: [ID: Int], accountNames: [UUID: String]) -> [HistoryGroup] {
        let projectCounts = Dictionary(grouping: counts.keys, by: \.project).mapValues(\.count)
        return counts.map { id, count in
            let account = accountNames[id.accountId]
            let name = (projectCounts[id.project] ?? 0) > 1 && account != nil ? "\(id.project) (\(account!))" : id.project
            return HistoryGroup(id: id, name: name, unreadCount: count)
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    public let id: ID
    public let name: String
    public let unreadCount: Int
}

/// Eén repo binnen een account, als filter op de geschiedenis.
public struct HistoryRepo: Hashable, Sendable {
    public let accountId: UUID
    public let repo: String

    public init(accountId: UUID, repo: String) {
        self.accountId = accountId
        self.repo = repo
    }
}
