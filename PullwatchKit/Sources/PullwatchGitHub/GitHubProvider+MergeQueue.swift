import Foundation
public import PullwatchCore

/// Of een open PR in de merge queue staat (`PullRequest.isInMergeQueue` en
/// `mergeQueueEntry { state position enqueuedAt }`) of auto-merge aan heeft (`autoMergeRequest`),
/// via dezelfde gebundelde GraphQL-vraag als de co-auteurs en checks (`PRDetailQuery`), vijftig
/// PR's per verzoek. De zoek-API van REST kent de merge queue niet. Een server zonder deze velden
/// (een oudere GitHub Enterprise Server) krijgt de vraag daarna niet meer: geen PR staat dan in de
/// rij. Voor een PR die net uit de rij ging vraagt `mergeQueueExits` de reden uit zijn tijdlijn.
extension GitHubProvider {
    /// PR's per GraphQL-verzoek: de vraag per PR is klein.
    static let mergeQueueBatch = 50

    /// Wat één verzoek over de rij zei: de PR's in de rij, en de PR's waarover het niets
    /// betrouwbaars zei (geen antwoord voor die PR, of niet meer open of weer draft).
    private struct QueueAnswer {
        var entries: [String: MergeQueueEntry] = [:]
        var unread: Set<String> = []
        /// Per PR (dedupKey) zijn branch en doelbranch, voor de boom in Branches.
        var branches: [String: (source: String, target: String)] = [:]
    }

    public func unreadMergeQueues() async -> Set<String> {
        mergeQueueUnread
    }

    /// De PR's met hun plek in de merge queue of met auto-merge erbij. Drafts kunnen niet in de
    /// rij. Mislukt een verzoek, dan houden de PR's daarin wat de vorige vraag zei, en faalt de
    /// poll niet; ze staan dan in `mergeQueueUnread`, net als een PR die volgens GraphQL al niet
    /// meer open is (de zoek-API loopt soms achter).
    func withMergeQueues(_ pullRequests: [PullRequest]) async -> [PullRequest] {
        mergeQueueUnread = []
        guard !mergeQueueUnsupported else { return pullRequests }
        let candidates = pullRequests.filter {
            $0.state == .open && !$0.isDraft && $0.repo.split(separator: "/").count == 2 && !readsWithoutToken($0.repo)
        }
        guard !candidates.isEmpty else {
            knownMergeQueues = [:]
            return pullRequests
        }
        var found: [String: MergeQueueEntry] = [:]
        var unread: Set<String> = []
        var branches: [String: (source: String, target: String)] = [:]
        for batch in candidates.chunked(Self.mergeQueueBatch) {
            do {
                let answer = try await mergeQueues(of: batch)
                found.merge(answer.entries) { _, new in new }
                branches.merge(answer.branches) { _, new in new }
                unread.formUnion(answer.unread)
                for key in answer.unread { if let known = knownMergeQueues[key] { found[key] = known } }
            } catch is GraphQLSchemaMismatch {
                mergeQueueUnsupported = true
                knownMergeQueues = [:]
                mergeQueueUnread = Set(candidates.map(\.dedupKey))
                return pullRequests
            } catch {
                for pr in batch {
                    unread.insert(pr.dedupKey)
                    if let known = knownMergeQueues[pr.dedupKey] { found[pr.dedupKey] = known }
                }
            }
        }
        knownMergeQueues = found
        mergeQueueUnread = unread
        return pullRequests.map { pr in
            var pr = pr
            pr.mergeQueue = found[pr.dedupKey]
            if let refs = branches[pr.dedupKey] {
                pr.sourceBranch = refs.source
                pr.targetBranch = refs.target
            }
            return pr
        }
    }

    /// Eén verzoek: per PR in de rij zijn plek. Gooit `GraphQLSchemaMismatch` als de server de
    /// velden niet kent.
    private func mergeQueues(of batch: [PullRequest]) async throws -> QueueAnswer {
        let wanted = batch.map { PRDetailQuery.Wanted(pr: $0, coAuthors: false, checks: false, mergeQueue: true) }
        let nodes = try await detailNodes(wanted)
        var answer = QueueAnswer()
        for (index, pr) in batch.enumerated() {
            guard let node = (nodes["pr\(index)"] ?? nil)?.pullRequest else {
                answer.unread.insert(pr.dedupKey)
                continue
            }
            if let state = node.state, state != "OPEN" || node.isDraft == true {
                answer.unread.insert(pr.dedupKey)
                continue
            }
            if let source = node.headRefName, let target = node.baseRefName {
                answer.branches[pr.dedupKey] = (source, target)
            }
            if node.isInMergeQueue == true || node.mergeQueueEntry != nil {
                answer.entries[pr.dedupKey] = MergeQueueEntry(
                    kind: .mergeQueue,
                    position: node.mergeQueueEntry?.position,
                    enqueuedAt: node.mergeQueueEntry?.enqueuedAt.flatMap(DateParsing.parse)
                )
            } else if let request = node.autoMergeRequest {
                answer.entries[pr.dedupKey] = MergeQueueEntry(kind: .autoMerge, enqueuedAt: request.enabledAt.flatMap(DateParsing.parse))
            }
        }
        return answer
    }

    /// Waarom deze PR's net uit de rij gingen: de laatste `RemovedFromMergeQueueEvent` (merge
    /// queue) of `AutoMergeDisabledEvent` (auto-merge) uit hun tijdlijn, met hun stand nu. Een PR
    /// die nu niet open is of weer in de rij staat, ging niet zonder mergen uit de rij. Alleen voor
    /// de paar PR's die net uit de rij gingen; een fout geeft geen reden.
    public func mergeQueueExits(of pullRequests: [PullRequest]) async -> MergeQueueExits {
        let asked = pullRequests.filter { $0.leftQueue != nil && $0.repo.split(separator: "/").count == 2 }
        var exits = MergeQueueExits()
        for batch in asked.chunked(Self.mergeQueueBatch) {
            let wanted = batch.map { PRDetailQuery.Wanted(pr: $0, coAuthors: false, checks: false, queueExit: $0.leftQueue?.kind) }
            guard let nodes = try? await detailNodes(wanted) else { continue }
            for (index, pr) in batch.enumerated() {
                guard let node = (nodes["pr\(index)"] ?? nil)?.pullRequest else { continue }
                if let state = node.state, state != "OPEN" || node.isInMergeQueue == true || node.autoMergeRequest != nil {
                    exits.notLeft.insert(pr.dedupKey)
                    continue
                }
                let reason = node.queueExit?.nodes?.last??.reason?.trimmingCharacters(in: .whitespacesAndNewlines)
                if let reason, !reason.isEmpty { exits.reasons[pr.dedupKey] = reason }
            }
        }
        return exits
    }

    /// Stuurt één `PRDetailQuery` en geeft de antwoorden per alias. Gooit `GraphQLSchemaMismatch`
    /// als de server een veld niet kent, en een fout als het hele verzoek mislukte.
    private func detailNodes(_ wanted: [PRDetailQuery.Wanted]) async throws -> [String: PRDetailQuery.Response.Repository?] {
        let (data, _) = try await send(endpoints.graphQL, body: try JSONEncoder().encode(PRDetailQuery(wanted)))
        let response = try JSONDecoding.decode(PRDetailQuery.Response.self, from: data)
        guard let nodes = response.data else {
            if GraphQLSchemaMismatch.matches(response.errors) { throw GraphQLSchemaMismatch() }
            // Zonder `data` mislukte het hele verzoek (bv. de GraphQL-limiet); de aanroeper houdt
            // dan wat hij wist.
            throw ProviderError.decoding(response.errors?.first?.message.map { "GraphQL: \($0)" }
                ?? String(localized: "GraphQL-antwoord zonder gegevens", bundle: .localizedGitHub))
        }
        return nodes
    }
}
