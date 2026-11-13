import Foundation
public import PullwatchCore

/// Co-auteurs en checks van PR's via GraphQL, twintig PR's per verzoek (aliassen `pr0`, `pr1`,
/// …). Per PR alleen wat nodig is: de auteurs van de laatste vijftig commits (GitHub zet de
/// `Co-authored-by:`-trailers daar zelf bij) en van de laatste commit alleen de telling van de
/// checks per stand (`statusCheckRollup`, `checkRunCountsByState` en
/// `statusContextCountsByState`), zonder namen of links. Zo kosten co-auteurs en checks samen één
/// verzoek per twintig PR's.
extension GitHubProvider {
    /// PR's per GraphQL-verzoek bij `coAuthors(of:)`, `checks(of:)` en `details`.
    static let coAuthorBatch = 20

    public func coAuthors(of pullRequests: [PullRequest]) async throws -> [String: [Person]] {
        try await details(of: pullRequests, coAuthorsOf: Set(pullRequests.map(\.dedupKey)), checksOf: []).coAuthors
    }

    public func checks(of pullRequests: [PullRequest]) async throws -> [String: PRChecks] {
        try await details(of: pullRequests, coAuthorsOf: [], checksOf: Set(pullRequests.map(\.dedupKey))).checks
    }

    /// Een PR die niet (meer) bestaat geeft geen co-auteurs en geen checks. Repo's die alleen
    /// zonder token te lezen zijn slaan we over: GraphQL vraagt een token. Weigert GitHub de
    /// checks (de GitHub App mist Checks of Commit statuses, lezen), dan `.needsPermission` en
    /// komen de co-auteurs gewoon.
    public func details(of pullRequests: [PullRequest], coAuthorsOf: Set<String>, checksOf: Set<String>) async throws -> PRDetails {
        var details = PRDetails()
        var checksOf = checksOf
        if checksUnsupported {
            // Deze server kent de telling niet: geen checks, en ook geen verzoek ervoor.
            for pr in pullRequests where checksOf.contains(pr.dedupKey) { details.checks[pr.dedupKey] = .counts(CheckCounts()) }
            checksOf = []
        }
        let known = pullRequests.filter {
            $0.repo.split(separator: "/").count == 2 && !readsWithoutToken($0.repo)
                && (coAuthorsOf.contains($0.dedupKey) || checksOf.contains($0.dedupKey))
        }
        for batch in known.chunked(Self.coAuthorBatch) {
            let wanted = batch.map { pr in
                PRDetailQuery.Wanted(
                    pr: pr,
                    coAuthors: coAuthorsOf.contains(pr.dedupKey),
                    checks: checksOf.contains(pr.dedupKey)
                )
            }
            try await fetchDetails(wanted, into: &details)
        }
        return details
    }

    /// Eén verzoek; bij een server die de velden van de checks niet kent, of een token dat ze
    /// niet mag lezen, nog één keer zonder checks.
    private func fetchDetails(_ wanted: [PRDetailQuery.Wanted], into details: inout PRDetails) async throws {
        let asksChecks = wanted.contains(where: \.checks)
        let response: PRDetailQuery.Response
        do {
            let body = try JSONEncoder().encode(PRDetailQuery(wanted))
            let (data, _) = try await send(endpoints.graphQL, body: body)
            response = try JSONDecoding.decode(PRDetailQuery.Response.self, from: data)
        } catch ProviderError.unauthorized where asksChecks {
            // GraphQL weigert een vraag zonder recht met 401 of 403 voor het hele verzoek.
            for item in wanted where item.checks { details.checks[item.pr.dedupKey] = .needsPermission }
            return try await fetchDetails(wanted.map(\.withoutChecks), into: &details)
        }
        // Een server zonder deze velden (een oudere GitHub Enterprise Server): eerst zonder de
        // checks, en kent hij de co-auteurs ook niet, dan geen co-auteurs, in plaats van elke poll
        // dezelfde fout.
        if response.data == nil, GraphQLSchemaMismatch.matches(response.errors) {
            if asksChecks {
                checksUnsupported = true
                for item in wanted where item.checks { details.checks[item.pr.dedupKey] = .counts(CheckCounts()) }
                return try await fetchDetails(wanted.map(\.withoutChecks), into: &details)
            }
            for item in wanted where item.coAuthors { details.coAuthors[item.pr.dedupKey] = [] }
            return
        }
        // Zonder `data` mislukte het hele verzoek (bv. de GraphQL-limiet): later opnieuw.
        guard let found = response.data else { throw ProviderError.decoding(String(localized: "GraphQL-antwoord zonder co-auteurs en checks", bundle: .localizedGitHub)) }
        let forbidden = response.forbiddenAliases
        for (index, item) in wanted.enumerated() {
            let alias = "pr\(index)"
            let node = found[alias] ?? nil
            if item.coAuthors {
                let commits = node?.pullRequest?.commits?.nodes ?? []
                let candidates = commits.flatMap { $0.commit.authors.nodes }.map { author in
                    Person(
                        name: author.name ?? author.user?.login ?? author.email ?? "",
                        login: author.user?.login,
                        email: author.email,
                        avatarURL: author.user?.avatarUrl.flatMap(URL.init(string:))
                    )
                }.filter { !$0.name.isEmpty }
                details.coAuthors[item.pr.dedupKey] = CoAuthorTrailer.coAuthors(
                    from: candidates, author: [item.pr.authorId, item.pr.authorName]
                )
            }
            if item.checks {
                if forbidden.contains(alias) || forbidden.contains("") {
                    details.checks[item.pr.dedupKey] = .needsPermission
                } else if let pullRequest = node?.pullRequest {
                    details.checks[item.pr.dedupKey] = .counts(pullRequest.checkCounts)
                }
            }
        }
    }
}

/// GraphQL: per PR (alias `pr0`, `pr1`, …; variabelen `o0`/`n0`/`p0`) de commit-auteurs met
/// co-auteurs, de telling van de checks op de laatste commit en/of de plek in de merge queue.
struct PRDetailQuery: Encodable {
    let query: String
    let variables: [String: Variable]

    struct Wanted {
        let pr: PullRequest
        let coAuthors: Bool
        let checks: Bool
        /// Of de PR in de merge queue staat en op welke plek (`GitHubProvider+MergeQueue`).
        var mergeQueue = false
        /// Waarom de PR net uit deze rij ging, met zijn stand nu (`GitHubProvider.mergeQueueExits`).
        var queueExit: MergeQueueEntry.Kind?

        var withoutChecks: Wanted { Wanted(pr: pr, coAuthors: coAuthors, checks: false, mergeQueue: mergeQueue, queueExit: queueExit) }
    }

    enum Variable: Encodable {
        case text(String)
        case number(Int)

        func encode(to encoder: any Encoder) throws {
            var c = encoder.singleValueContainer()
            switch self {
            case .text(let value): try c.encode(value)
            case .number(let value): try c.encode(value)
            }
        }
    }

    init(_ wanted: [Wanted]) {
        var declarations: [String] = []
        var fields: [String] = []
        var variables: [String: Variable] = [:]
        for (index, item) in wanted.enumerated() {
            let parts = item.pr.repo.split(separator: "/", maxSplits: 1).map(String.init)
            declarations.append("$o\(index): String!, $n\(index): String!, $p\(index): Int!")
            var selections: [String] = []
            if item.coAuthors {
                selections.append("commits(last: 50) { nodes { commit { authors(first: 5) { nodes { name email user { login avatarUrl } } } } } }")
            }
            if item.checks {
                selections.append("""
                    headCommit: commits(last: 1) { nodes { commit { statusCheckRollup { contexts(first: 1) { \
                    checkRunCountsByState { state count } statusContextCountsByState { state count } } } } } }
                    """)
            }
            if item.mergeQueue {
                // `state` en `isDraft` zijn verser dan de zoek-API: een PR die net gemerged is staat
                // daar soms nog open. `autoMergeRequest`: auto-merge zonder merge queue. De branches
                // zijn voor de boom in Branches (de zoek-API geeft ze niet).
                selections.append("state isDraft isInMergeQueue mergeQueueEntry { state position enqueuedAt } autoMergeRequest { enabledAt } baseRefName headRefName")
            }
            if let kind = item.queueExit {
                let type = kind == .autoMerge ? "AUTO_MERGE_DISABLED_EVENT" : "REMOVED_FROM_MERGE_QUEUE_EVENT"
                selections.append("""
                    state isInMergeQueue autoMergeRequest { enabledAt } queueExit: timelineItems(last: 1, itemTypes: [\(type)]) { \
                    nodes { ... on RemovedFromMergeQueueEvent { reason } ... on AutoMergeDisabledEvent { reason } } }
                    """)
            }
            if selections.isEmpty { selections.append("number") }
            fields.append("""
                  pr\(index): repository(owner: $o\(index), name: $n\(index)) {
                    pullRequest(number: $p\(index)) {
                      \(selections.joined(separator: "\n      "))
                    }
                  }
                """)
            variables["o\(index)"] = .text(parts[0])
            variables["n\(index)"] = .text(parts[1])
            variables["p\(index)"] = .number(item.pr.number)
        }
        query = "query(" + declarations.joined(separator: ", ") + ") {\n" + fields.joined(separator: "\n") + "\n}"
        self.variables = variables
    }

    struct Response: Decodable {
        struct Repository: Decodable { let pullRequest: PullRequestNode? }
        struct PullRequestNode: Decodable {
            let commits: Commits?
            let headCommit: HeadCommits?
            let state: String?
            let isDraft: Bool?
            let baseRefName: String?
            let headRefName: String?
            let isInMergeQueue: Bool?
            let mergeQueueEntry: MergeQueueEntryNode?
            let autoMergeRequest: AutoMergeRequestNode?
            /// De laatste `RemovedFromMergeQueueEvent` of `AutoMergeDisabledEvent`.
            let queueExit: QueueExitEvents?

            /// De telling over alle check-runs en commit-statussen van de laatste commit; zonder
            /// checks (`statusCheckRollup` is dan `null`) een lege telling.
            var checkCounts: CheckCounts {
                var counts = CheckCounts()
                guard let contexts = headCommit?.nodes.last?.commit.statusCheckRollup?.contexts else { return counts }
                for item in contexts.checkRunCountsByState ?? [] {
                    counts.add(GitHubCheckState.checkRun(item.state), count: item.count)
                }
                for item in contexts.statusContextCountsByState ?? [] {
                    counts.add(GitHubCheckState.statusContext(item.state), count: item.count)
                }
                return counts
            }
        }
        /// `MergeQueueEntry`: `position` telt vanaf 1 (de eerste in de rij heeft 1).
        struct MergeQueueEntryNode: Decodable {
            let state: String?
            let position: Int?
            let enqueuedAt: String?
        }
        /// `AutoMergeRequest`: auto-merge staat aan, sinds `enabledAt`.
        struct AutoMergeRequestNode: Decodable { let enabledAt: String? }
        struct QueueExitEvents: Decodable { let nodes: [QueueExitEvent?]? }
        /// `RemovedFromMergeQueueEvent.reason` of `AutoMergeDisabledEvent.reason`: tekst van GitHub.
        struct QueueExitEvent: Decodable { let reason: String? }
        struct Commits: Decodable { let nodes: [CommitNode] }
        struct CommitNode: Decodable { let commit: Commit }
        struct Commit: Decodable { let authors: Authors }
        struct Authors: Decodable { let nodes: [Author] }
        struct Author: Decodable {
            struct User: Decodable {
                let login: String
                let avatarUrl: String?
            }
            let name: String?
            let email: String?
            let user: User?
        }
        struct HeadCommits: Decodable { let nodes: [HeadCommitNode] }
        struct HeadCommitNode: Decodable { let commit: HeadCommit }
        struct HeadCommit: Decodable { let statusCheckRollup: Rollup? }
        struct Rollup: Decodable { let contexts: Contexts? }
        struct Contexts: Decodable {
            let checkRunCountsByState: [StateCount]?
            let statusContextCountsByState: [StateCount]?
        }
        struct StateCount: Decodable {
            let state: String
            let count: Int
        }

        let data: [String: Repository?]?
        let errors: [GraphQLError]?

        /// De aliassen (`pr0`, …) waarvan GitHub de checks weigerde (`FORBIDDEN`, "Resource not
        /// accessible by integration"); "" voor een weigering zonder pad.
        var forbiddenAliases: Set<String> {
            var result: Set<String> = []
            for error in errors ?? [] where error.isForbidden {
                let path = error.path ?? []
                guard path.isEmpty || path.contains(.key("headCommit")) || path.contains(.key("statusCheckRollup")) else { continue }
                if case .key(let alias)? = path.first { result.insert(alias) } else { result.insert("") }
            }
            return result
        }
    }
}

/// Hoe GitHub de stand van een check noemt, vertaald naar de telling: overgeslagen en neutraal
/// tellen als geslaagd, wat stopte zonder te slagen als mislukt.
enum GitHubCheckState {
    /// `CheckRunState`: de conclusie van een afgeronde run, anders zijn status.
    static func checkRun(_ state: String) -> CheckOutcome {
        switch state {
        case "SUCCESS", "COMPLETED": .passed
        case "NEUTRAL", "SKIPPED": .skipped
        case "FAILURE", "ERROR", "TIMED_OUT", "ACTION_REQUIRED", "CANCELLED", "STARTUP_FAILURE", "STALE": .failed
        default: .pending // QUEUED, IN_PROGRESS, WAITING, PENDING, REQUESTED
        }
    }

    /// `StatusState` van een commit-status.
    static func statusContext(_ state: String) -> CheckOutcome {
        switch state {
        case "SUCCESS": .passed
        case "FAILURE", "ERROR": .failed
        default: .pending // PENDING, EXPECTED
        }
    }
}
