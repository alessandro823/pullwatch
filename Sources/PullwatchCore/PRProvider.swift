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
    /// PR's in alle statussen (open, gemerged, gesloten), nieuwste eerst, afgekapt op `limit`.
    /// Met `since` alleen PR's die sindsdien zijn bijgewerkt (GitHub) of aangemaakt/gesloten (Azure DevOps).
    func pullRequests(updatedSince since: Date?, limit: Int) async throws -> [PullRequest]
    /// Tags van de opgegeven repos; `Tag.repo` is exact de doorgegeven repo-string.
    /// Een repo die 404 of geen toegang geeft wordt overgeslagen en in `unavailableRepos` gemeld.
    func tags(in repos: [String]) async throws -> TagFetch
    /// Alle bestandspaden (zonder leidende "/") op de default branch; een lege repo geeft een lege lijst.
    func filePaths(in repo: String) async throws -> [String]
    /// Inhoud van één bestand op de default branch als tekst.
    func fileContent(in repo: String, path: String) async throws -> String
    /// Gooi gecachte tokens weg (na een 401).
    func invalidateCredentials() async
}
