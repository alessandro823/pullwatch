import Foundation

// De antwoorden van de Bitbucket Cloud REST API 2.0 (snake_case, `JSONDecoding` met
// `snakeCase: true`). Alleen de velden die Pullwatch leest; de API stuurt er veel meer mee.

/// Eén pagina van een lijst: de waarden en, als er meer is, de volledige URL van de volgende.
struct PageDTO<Value: Decodable>: Decodable {
    let values: [Value]
    let next: String?
}

struct Link: Decodable {
    let href: String?
}

/// Een gebruiker of account (`/user`, de auteur van een pull request).
struct AccountDTO: Decodable {
    struct Links: Decodable {
        let avatar: Link?
    }

    /// `{…}`; vast, ook als de naam verandert. Een verwijderd account kan het missen.
    let uuid: String?
    let displayName: String?
    let nickname: String?
    let links: Links?
}

struct RepositoryDTO: Decodable {
    let fullName: String
    let updatedOn: String?
}

struct PullRequestDTO: Decodable {
    struct Endpoint: Decodable {
        struct Commit: Decodable { let hash: String? }
        struct Repository: Decodable { let fullName: String? }
        struct Branch: Decodable { let name: String? }

        let commit: Commit?
        let repository: Repository?
        let branch: Branch?
    }

    struct Links: Decodable {
        let html: Link?
    }

    let id: Int
    let title: String
    /// OPEN, MERGED, DECLINED of SUPERSEDED.
    let state: String
    let draft: Bool?
    /// In de merge queue van de doelbranch.
    let queued: Bool?
    let author: AccountDTO?
    let source: Endpoint?
    let destination: Endpoint?
    let createdOn: String
    let updatedOn: String?
    let links: Links?
}

/// De auteur van een commit of tag: `raw` is "Naam <e-mail>" zoals git hem schreef, `user` het
/// Bitbucket-account als Bitbucket het e-mailadres kent.
struct GitAuthorDTO: Decodable {
    let raw: String?
    let user: AccountDTO?
}

struct TagDTO: Decodable {
    struct Target: Decodable {
        let hash: String?
        let date: String?
        let author: GitAuthorDTO?
    }

    struct Links: Decodable {
        let html: Link?
    }

    let name: String
    /// Een geannoteerde tag heeft een eigen datum en tagger; een lichte niet.
    let date: String?
    let tagger: GitAuthorDTO?
    let target: Target?
    let links: Links?
}

struct CommitDTO: Decodable {
    let author: GitAuthorDTO?
    let message: String?
}

struct CommitStatusDTO: Decodable {
    /// SUCCESSFUL, FAILED, INPROGRESS of STOPPED.
    let state: String?
}

/// Een regel van `/src` (`commit_file` of `commit_directory`).
struct TreeEntryDTO: Decodable {
    let path: String
    let type: String
}

/// Het foutantwoord van API 2.0 (`{"type": "error", "error": {"message": …, "detail": …}}`). Bij
/// een token zonder de juiste scope is `detail` geen zin maar een object met de scopes die het
/// verzoek nodig heeft en die het token heeft:
/// `"detail": {"required": ["read:pullrequest:bitbucket"], "granted": [...]}`.
struct ErrorDTO: Decodable {
    struct Body: Decodable {
        let message: String?
        let detail: Detail?

        private enum CodingKeys: String, CodingKey { case message, detail }

        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            message = try c.decodeIfPresent(String.self, forKey: .message)
            // Meestal is `detail` een zin; dan staan er geen scopes in.
            detail = try? c.decodeIfPresent(Detail.self, forKey: .detail)
        }
    }

    struct Detail: Decodable {
        let required: [String]?
    }

    let error: Body?
}

/// Een branch uit `refs/branches`: zijn naam en de laatste commit.
struct BranchDTO: Decodable {
    let name: String
    let target: TagDTO.Target?
}
