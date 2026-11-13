import Foundation

// De antwoorden van de REST API v4 (snake_case, `JSONDecoding` met `snakeCase: true`).

struct UserDTO: Decodable {
    let id: Int?
    let username: String
    let name: String?
    /// De e-mailadressen staan alleen bij `/user` (de gebruiker zelf): dat van het account, dat
    /// voor commits en het openbare.
    let email: String?
    let commitEmail: String?
    let publicEmail: String?
}

struct GroupDTO: Decodable {
    let fullPath: String
}

struct ProjectDTO: Decodable {
    let pathWithNamespace: String
}

struct MergeRequestDTO: Decodable {
    struct Author: Decodable {
        let username: String
        let name: String?
        /// Absoluut (gitlab.com, Gravatar) of, op een eigen server, een pad als
        /// `/uploads/-/system/user/avatar/1/avatar.png`.
        let avatarUrl: String?
    }

    struct References: Decodable {
        let full: String?
    }

    let iid: Int
    let title: String
    let state: String
    let createdAt: String
    let updatedAt: String?
    let mergedAt: String?
    let closedAt: String?
    let draft: Bool?
    let workInProgress: Bool?
    let author: Author
    let webUrl: String
    let references: References?
    let sourceBranch: String?
    let targetBranch: String?
    let sha: String?
    /// Auto-merge staat aan: merge zodra de pipeline slaagt, of in de merge train.
    let mergeWhenPipelineSucceeds: Bool?
}

struct TagDTO: Decodable {
    struct Commit: Decodable {
        let authorName: String?
        let committedDate: String?
        let createdAt: String?
    }

    struct Release: Decodable {
        let tagName: String
    }

    let name: String
    let createdAt: String?
    let commit: Commit?
    let release: Release?
}

struct ReleaseDTO: Decodable {
    struct Author: Decodable {
        let username: String
        let avatarUrl: String?
    }

    struct Links: Decodable {
        let selfURL: String?

        private enum CodingKeys: String, CodingKey {
            case selfURL = "self"
        }
    }

    let name: String?
    let tagName: String
    let createdAt: String?
    let releasedAt: String?
    let author: Author?
    let links: Links?

    private enum CodingKeys: String, CodingKey {
        case name, tagName, createdAt, releasedAt, author
        case links = "_links"
    }
}

struct CommitDTO: Decodable {
    let authorName: String?
    let authorEmail: String?
    let message: String?
}

struct TreeEntryDTO: Decodable {
    let path: String
    let type: String
}

/// Een branch met zijn laatste commit (`repository/branches`).
struct BranchDTO: Decodable {
    struct Commit: Decodable {
        let id: String
        let committedDate: String?
        let authorName: String?
        let authorEmail: String?
    }

    let name: String
    let commit: Commit
    /// De standaardbranch van het project.
    let `default`: Bool?
}

/// De commits die `repository/compare` tussen twee punten vindt; alleen het aantal telt.
struct CompareDTO: Decodable {
    struct Commit: Decodable {
        let id: String
    }

    let commits: [Commit]
}
