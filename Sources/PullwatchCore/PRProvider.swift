import Foundation

public protocol PRProvider: Sendable {
    /// Identiteit van de ingelogde gebruiker, vergeleken met `PullRequest.authorId`.
    func currentUserId() async throws -> String
    /// Weergavenaam van de ingelogde gebruiker (voor de verbindingstest).
    func currentUserDisplayName() async throws -> String
    /// Alle repos die het account kan zien, in hetzelfde formaat als `Account.repos`.
    func listRepos() async throws -> [String]
    /// Alle open PR's inclusief drafts, ongefilterd.
    func openPullRequests() async throws -> [PullRequest]
    /// Gooi gecachte tokens weg (na een 401).
    func invalidateCredentials() async
}
