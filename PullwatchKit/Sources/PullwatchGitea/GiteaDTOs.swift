import Foundation

// De antwoorden van de API v1 van Gitea en Forgejo (snake_case, `JSONDecoding` met
// `snakeCase: true`). Velden die een oudere server niet kent zijn optioneel.

struct UserDTO: Decodable {
    let login: String
    let fullName: String?
    let avatarUrl: String?
}

struct OrganizationDTO: Decodable {
    /// `name` bij Gitea, met `username` ernaast bij Forgejo; allebei de naam in de URL.
    let name: String?
    let username: String?
}

struct RepositoryDTO: Decodable {
    let fullName: String
    let archived: Bool?
    let defaultBranch: String?
}

/// Een pull request uit `/repos/issues/search?type=pulls`: een issue met `pull_request`.
struct IssueDTO: Decodable {
    struct PullRequestMeta: Decodable {
        let merged: Bool?
        let mergedAt: String?
        /// Gitea 1.22 en later, en Forgejo; ontbreekt op een oudere server.
        let draft: Bool?
    }

    struct Repository: Decodable {
        let fullName: String
    }

    let number: Int
    let title: String
    let state: String
    let user: UserDTO
    let htmlUrl: String
    let createdAt: String
    let updatedAt: String?
    let closedAt: String?
    let pullRequest: PullRequestMeta?
    let repository: Repository
}

/// Een pull request uit `/repos/:eigenaar/:repo/pulls` of `/pulls/:nummer`.
struct PullRequestDTO: Decodable {
    struct Branch: Decodable {
        struct Repository: Decodable {
            let fullName: String
        }

        /// De branchnaam.
        let ref: String?
        let sha: String?
        let repo: Repository?
    }

    let number: Int
    let title: String
    let state: String
    let draft: Bool?
    let merged: Bool?
    let mergedAt: String?
    let user: UserDTO
    let htmlUrl: String
    let createdAt: String
    let updatedAt: String?
    let closedAt: String?
    let head: Branch?
    let base: Branch?
}

struct TagDTO: Decodable {
    struct Commit: Decodable {
        let sha: String?
        let created: String?
    }

    let name: String
    let commit: Commit?
}

struct ReleaseDTO: Decodable {
    let tagName: String
    let name: String?
    let draft: Bool?
    let prerelease: Bool?
    let htmlUrl: String?
    let createdAt: String?
    let publishedAt: String?
    let author: UserDTO?
}

/// De gecombineerde stand van een commit (`/commits/:ref/status`): per context de laatste status.
struct CombinedStatusDTO: Decodable {
    struct Status: Decodable {
        let status: String?
        let context: String?
    }

    let state: String?
    let statuses: [Status]?
}

struct CommitDTO: Decodable {
    struct Commit: Decodable {
        struct Person: Decodable {
            let name: String?
            let email: String?
        }

        let author: Person?
        let message: String?
    }

    let commit: Commit?
    /// De gebruiker op de server achter de commit, als die te koppelen is.
    let author: UserDTO?
}

struct TreeDTO: Decodable {
    struct Entry: Decodable {
        let path: String
        let type: String
    }

    let tree: [Entry]?
    let truncated: Bool?
    let page: Int?
    let totalCount: Int?
}

/// Een foutantwoord: `message` met de reden (bv. de scope die het token mist).
struct ErrorDTO: Decodable {
    let message: String?
}

struct BranchDTO: Decodable {
    struct Commit: Decodable {
        struct Person: Decodable {
            let name: String?
            let email: String?
            /// De gebruikersnaam op de server, als de commit aan een account te koppelen is.
            let username: String?
        }

        let id: String
        let timestamp: String?
        let author: Person?
    }

    let name: String
    let commit: Commit?
}

struct CompareDTO: Decodable {
    let totalCommits: Int
}
