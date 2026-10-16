import Foundation
@testable import PullwatchCore

let fixedAccountId = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!

extension PullRequest {
    static func fixture(
        accountId: UUID = fixedAccountId,
        repo: String = "proj/api",
        number: Int = 1,
        title: String = "Fix bug",
        authorId: String = "someone",
        isDraft: Bool = false,
        createdAt: Date = Date(timeIntervalSince1970: 1_760_000_000),
        state: PRState = .open,
        closedAt: Date? = nil
    ) -> PullRequest {
        PullRequest(
            accountId: accountId,
            repo: repo,
            number: number,
            title: title,
            authorId: authorId,
            authorName: "Someone",
            isDraft: isDraft,
            createdAt: createdAt,
            webURL: URL(string: "https://example.com/\(repo)/pr/\(number)")!,
            state: state,
            closedAt: closedAt
        )
    }
}

extension Tag {
    static func fixture(
        accountId: UUID = fixedAccountId,
        repo: String = "proj/api",
        name: String = "v1"
    ) -> Tag {
        Tag(
            accountId: accountId,
            repo: repo,
            name: name,
            authorName: "Someone",
            webURL: URL(string: "https://example.com/\(repo)/tag/\(name)")!
        )
    }
}

extension Account {
    static func fixture(
        id: UUID = UUID(),
        kind: ProviderKind = .azureDevOps,
        organization: String = "acme",
        repoWatch: [String: WatchSet] = [:],
        newRepoDefault: NewRepoDefault = .prs,
        includeDrafts: Bool = false,
        hideOwn: Bool = true
    ) -> Account {
        Account(
            id: id,
            kind: kind,
            displayName: "Test",
            organization: organization,
            authMethod: .pat,
            repoWatch: repoWatch,
            newRepoDefault: newRepoDefault,
            includeDrafts: includeDrafts,
            hideOwn: hideOwn
        )
    }
}
