public import Foundation

/// Hoe het laatst ging met een account: nog niet gepold, gelukt of mislukt sinds wanneer.
public enum AccountState: Equatable, Sendable {
    case idle
    case ok(lastPoll: Date)
    case failed(ProviderError, since: Date)
}

/// Wat één `PollEngine.poll` opleverde over alle accounts.
public struct PollResult: Equatable, Sendable {
    public var newPullRequests: [PullRequest] = []
    /// Open drafts die de lijst toont zonder melding, omdat "Draft-PR's melden" uit staat
    /// (`PRFilter.notifies`). Gelezen in de geschiedenis, zoals de sync. Niet bedoeld voor meldingen.
    public var quietPullRequests: [PullRequest] = []
    /// Nieuwe tags, en bekende tags die net een release kregen, gesorteerd op repo en dan naam.
    public var newTags: [Tag] = []
    /// Bekende tags zoals ze nu zijn (auteur, release), om de geschiedenis bij te werken. Alleen van
    /// repo's waarvan de tags deze poll echt opgehaald zijn. Niet bedoeld voor meldingen.
    public var updatedTags: [Tag] = []
    public var statuses: [UUID: AccountState] = [:]
    /// Accounts die in deze cyclus net naar `.unauthorized` gingen (één melding per overgang).
    public var authFailures: [UUID] = []
    /// PR's (alle states) uit de geschiedenis-sync, gefilterd met `PRFilter`. Leeg als er
    /// geen sync aan de beurt was of die mislukte. Niet bedoeld voor meldingen.
    public var syncedPullRequests: [PullRequest] = []
    /// PR's die sinds de vorige geschiedenis-sync gemerged zijn in repo's met "Completed" aan,
    /// gesorteerd op `closedAt`.
    public var completedPullRequests: [PullRequest] = []
    /// Bestaande tags uit de eerste tag-poll van een repo, met datum en binnen de bewaartermijn,
    /// voor de geschiedenis (gelezen). Niet bedoeld voor meldingen.
    public var syncedTags: [Tag] = []
    /// Per account de repo's waarvan deze poll de tags ophaalde (alleen als tags aan de beurt waren).
    var tagRepos: [UUID: [String]] = [:]
    /// De checks die deze poll ophaalde, per dedupKey, om de geschiedenis bij te werken. Niet
    /// bedoeld voor meldingen.
    public var checks: [String: PRChecks] = [:]
    /// Eigen open PR's waarvan de checks net mislukten (voor de melding "Checks mislukt"); alleen
    /// met `checksForOwnPullRequests`. Een PR waarvan Pullwatch de checks nog nooit zag meldt niet.
    public var failedChecks: [PullRequest] = []
    /// Van elke open PR die deze poll ophaalde of hij in de rij staat om vanzelf te mergen
    /// (`PullRequest.mergeQueue`), per dedupKey; `nil` als waarde: niet (meer) in de rij. Om de
    /// geschiedenis bij te werken, niet voor meldingen: in de rij komen meldt niets.
    public var mergeQueues: [String: MergeQueueEntry?] = [:]
    /// Open PR's die sinds de vorige poll uit de rij gingen zonder te mergen, met
    /// `PullRequest.leftQueue` (en de reden als de dienst die gaf), gesorteerd op `createdAt`.
    /// Voor de melding "Uit de rij" en de geschiedenis.
    public var leftQueue: [PullRequest] = []
}

/// Voortgang van één `PollEngine.poll`: hoeveel accounts klaar zijn van hoeveel, en welk account
/// er een eerste geschiedenis-sync (volledige backfill) doet; nil als er geen bij zit.
public struct PollProgress: Equatable, Sendable {
    public var done: Int
    public var total: Int
    /// `Account.displayName` van het account met de eerste sync in deze poll.
    public var firstSyncAccount: String?

    public init(done: Int, total: Int, firstSyncAccount: String? = nil) {
        self.done = done
        self.total = total
        self.firstSyncAccount = firstSyncAccount
    }
}
