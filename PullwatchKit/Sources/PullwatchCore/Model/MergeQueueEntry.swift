public import Foundation

/// Een open PR die vanzelf gaat mergen zodra hij aan de beurt is: in de merge queue van GitHub,
/// in een merge train van GitLab, met auto-merge bij GitHub of GitLab ("merge als de pipeline
/// slaagt"), of met auto-complete bij Azure DevOps. De app toont hem dan als Queued, zoals GitHub (`PRStatus.queued`).
public struct MergeQueueEntry: Codable, Hashable, Sendable {
    /// Hoe de dienst de PR laat wachten.
    public enum Kind: String, Codable, Hashable, Sendable {
        /// De merge queue van GitHub (`PullRequest.mergeQueueEntry`).
        case mergeQueue
        /// Een merge train van GitLab (Premium).
        case mergeTrain
        /// Merge zodra de checks slagen: GitLab `merge_when_pipeline_succeeds`, GitHub
        /// `autoMergeRequest` (auto-merge zonder merge queue).
        case autoMerge
        /// Azure DevOps: auto-complete staat aan (`autoCompleteSetBy`).
        case autoComplete

        /// Of de PR echt in een rij staat (merge queue, merge train), zoals GitHub en GitLab
        /// alleen dan het merge-queue-icoon tonen. Auto-merge en auto-complete wachten alleen
        /// op de checks: de PR is dan nog gewoon open.
        public var isQueue: Bool {
            switch self {
            case .mergeQueue, .mergeTrain: true
            case .autoMerge, .autoComplete: false
            }
        }
    }

    public var kind: Kind
    /// De plek in de rij, vanaf 1; nil als de dienst die niet geeft.
    public var position: Int?
    /// Sinds wanneer de PR in de rij staat; nil als de dienst dat niet geeft.
    public var enqueuedAt: Date?

    public init(kind: Kind, position: Int? = nil, enqueuedAt: Date? = nil) {
        self.kind = kind
        self.position = position
        self.enqueuedAt = enqueuedAt
    }

    /// Onbekende soorten uit een nieuwere versie lezen als merge queue, zodat de geschiedenis
    /// leesbaar blijft.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = (try? c.decode(Kind.self, forKey: .kind)) ?? .mergeQueue
        position = try c.decodeIfPresent(Int.self, forKey: .position)
        enqueuedAt = try c.decodeIfPresent(Date.self, forKey: .enqueuedAt)
    }

    private enum CodingKeys: String, CodingKey {
        case kind, position, enqueuedAt
    }
}
