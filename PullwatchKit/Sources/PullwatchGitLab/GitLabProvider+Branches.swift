import CryptoKit
public import Foundation
public import PullwatchCore

// MARK: - Branches

extension GitLabProvider {
    /// Hooguit zoveel pagina's per project (vijfduizend branches); daarna telt wat er is.
    static let branchMaxPages = 50

    /// Per project alle branches met hun laatste commit, zoals `tags(in:)` repo na repo. GitLab
    /// kent geen goedkopere controle, dus de vingerafdruk (de hash van de gesorteerde
    /// `naam:sha`-paren) volgt pas na het ophalen; een gelijke geeft `unchangedRepos`. Elke
    /// gevraagde repo komt in precies één uitkomst: gelezen (een vingerafdruk, ook zonder
    /// branches), `unavailableRepos` of `unchangedRepos`.
    public func branches(in repos: [String], unchanged known: [String: String]) async throws -> BranchFetch {
        var fetch = BranchFetch()
        for repo in repos {
            do {
                let branches = try await branches(of: repo)
                let fingerprint = Self.branchFingerprint(branches.map { ($0.name, $0.commit.id) })
                if known[repo] == fingerprint {
                    fetch.unchangedRepos.append(repo)
                    continue
                }
                let heads = branches.compactMap { makeHead(repo: repo, $0) }
                fetch.fingerprints[repo] = fingerprint
                if let name = branches.first(where: { $0.default == true })?.name { fetch.defaultBranches[repo] = name }
                fetch.heads += heads
            } catch ProviderError.server(status: 404) {
                fetch.unavailableRepos.append(repo) // bestaat niet (meer)
            } catch ProviderError.unauthorized {
                fetch.unavailableRepos.append(repo) // 403: geen toegang tot de repository
            } catch ProviderError.rateLimited where readsWithoutTokenCached(repo) {
                fetch.unavailableRepos.append(repo) // limiet zonder token op; de volgende keer weer
            }
        }
        return fetch
    }

    private func branches(of repo: String) async throws -> [BranchDTO] {
        try await pages(
            endpoint("projects", repo, "repository", "branches"), query: [], maxPages: Self.branchMaxPages,
            anonymous: try await readsAnonymously(repo)
        )
    }

    /// De auteur is de naam uit git; GitLab geeft bij een branch geen gebruiker mee, dus geen
    /// `authorId` en geen foto.
    private func makeHead(repo: String, _ dto: BranchDTO) -> BranchHead? {
        guard let webURL = branchTreeURL(repo: repo, branch: dto.name) else { return nil }
        return BranchHead(
            repo: repo,
            name: dto.name,
            sha: dto.commit.id,
            committedAt: dto.commit.committedDate.flatMap(DateParsing.parse),
            authorName: dto.commit.authorName.flatMap { $0.isEmpty ? nil : $0 },
            authorId: nil,
            authorEmail: dto.commit.authorEmail.flatMap { $0.isEmpty ? nil : $0 },
            authorAvatarURL: nil,
            webURL: webURL
        )
    }

    /// Hash van de op naam gesorteerde `naam:sha`-paren; verandert bij een push, een nieuwe en
    /// een verwijderde branch.
    static func branchFingerprint(_ pairs: [(name: String, sha: String)]) -> String {
        let text = pairs.sorted { $0.name < $1.name }.map { "\($0.name):\($0.sha)" }.joined(separator: "\n")
        return SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Hoeveel commits `to` voor en achter ligt op `from`: twee vragen met `straight=true`
    /// (alleen de twee punten, niet de merge-base). Een onbekende commit (404) geeft nil.
    public func compare(in repo: String, from: String, to: String) async throws -> BranchComparison? {
        do {
            let anonymous = try await readsAnonymously(repo)
            let ahead = try await commitCount(repo, from: from, to: to, anonymous: anonymous)
            let behind = try await commitCount(repo, from: to, to: from, anonymous: anonymous)
            return BranchComparison(ahead: ahead, behind: behind)
        } catch ProviderError.server(status: 404) {
            return nil
        }
    }

    private func commitCount(_ repo: String, from: String, to: String, anonymous: Bool) async throws -> Int {
        let dto: CompareDTO = try await get(endpoint("projects", repo, "repository", "compare"), anonymous: anonymous, query: [
            URLQueryItem(name: "from", value: from),
            URLQueryItem(name: "to", value: to),
            URLQueryItem(name: "straight", value: "true"),
        ])
        return dto.commits.count
    }

    nonisolated public func compareURL(in repo: String, from: String, to: String) -> URL? {
        pageURL(repo, ["-", "compare", Self.encode("\(from)...\(to)")])
    }

    /// De bestanden op deze branch. Elk segment van de naam apart gecodeerd: de "/" blijft een
    /// "/" (GitLab leest `tree/feature/x` als branch `feature/x`), de rest wordt %-gecodeerd.
    nonisolated func branchTreeURL(repo: String, branch: String) -> URL? {
        let name = branch.split(separator: "/", omittingEmptySubsequences: false).map { Self.encode(String($0)) }
        return pageURL(repo, ["-", "tree"] + name)
    }

    /// Als `webURL`, maar met segmenten die al gecodeerd zijn, en zonder actor.
    nonisolated private func pageURL(_ repo: String, _ encoded: [String]) -> URL? {
        let repoPath = repo.split(separator: "/").map { Self.encode(String($0)) }.joined(separator: "/")
        return URL(string: instanceURL.absoluteString + "/" + repoPath + "/" + encoded.joined(separator: "/"))
    }
}
