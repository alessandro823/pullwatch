package import Foundation
package import PullwatchCore

package let fixedAccountId = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!

extension PullRequest {
    package static func fixture(
        accountId: UUID = fixedAccountId,
        repo: String = "proj/api",
        number: Int = 1,
        title: String = "Fix bug",
        authorId: String = "someone",
        authorName: String = "Someone",
        isDraft: Bool = false,
        createdAt: Date = .testStart,
        state: PRState = .open,
        closedAt: Date? = nil,
        coAuthors: [Person] = [],
        revision: String? = nil
    ) -> PullRequest {
        PullRequest(
            accountId: accountId,
            repo: repo,
            number: number,
            title: title,
            authorId: authorId,
            authorName: authorName,
            isDraft: isDraft,
            createdAt: createdAt,
            webURL: URL(string: "https://example.com/\(repo)/pr/\(number)")!,
            state: state,
            closedAt: closedAt,
            coAuthors: coAuthors,
            revision: revision
        )
    }
}

extension Tag {
    package static func fixture(
        accountId: UUID = fixedAccountId,
        repo: String = "proj/api",
        name: String = "v1",
        createdAt: Date? = nil,
        release: ReleaseInfo? = nil
    ) -> Tag {
        Tag(
            accountId: accountId,
            repo: repo,
            name: name,
            authorName: "Someone",
            webURL: release?.url ?? URL(string: "https://example.com/\(repo)/tag/\(name)")!,
            createdAt: createdAt,
            release: release
        )
    }
}

extension Account {
    package static func fixture(
        id: UUID = UUID(),
        kind: ProviderKind = .azureDevOps,
        organization: String = "acme",
        repoWatch: [String: WatchSet] = [:],
        newRepoDefault: NewRepoDefault = .prs,
        showDrafts: Bool = true,
        includeDrafts: Bool = false,
        hideOwn: Bool = true
    ) -> Account {
        Account(
            id: id,
            kind: kind,
            organization: organization,
            authMethod: .pat,
            repoWatch: repoWatch,
            newRepoDefault: newRepoDefault,
            showDrafts: showDrafts,
            includeDrafts: includeDrafts,
            hideOwn: hideOwn,
            // Bitbucket is pas af met het e-mailadres van het Atlassian-account.
            email: kind == .bitbucket ? "jane@example.com" : nil
        )
    }
}
