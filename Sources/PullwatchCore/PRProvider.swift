import Foundation

public protocol PRProvider: Sendable {
    /// Identiteit van de ingelogde gebruiker, vergeleken met `PullRequest.authorId`.
    func currentUserId() async throws -> String
    /// Verbindingstest: controleert token én toegang tot de organisatie/owner,
    /// en geeft de weergavenaam van de ingelogde gebruiker.
    func testConnection() async throws -> String
    /// Alle repos die het account kan zien, in hetzelfde formaat als `Account.repoWatch`.
    func listRepos() async throws -> [String]
    /// Alle open PR's inclusief drafts, ongefilterd.
    func openPullRequests() async throws -> [PullRequest]
    /// Gooi gecachte tokens weg (na een 401).
    func invalidateCredentials() async
}
