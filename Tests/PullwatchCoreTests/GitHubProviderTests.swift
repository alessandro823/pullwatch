import Foundation
import Testing
@testable import PullwatchCore

@Suite struct GitHubProviderTests {
    func item(number: Int, repo: String = "acme/web", draft: Bool? = false, login: String = "octocat") -> String {
        let draftField = draft.map { #","draft":\#($0)"# } ?? ""
        return #"""
        {"number":\#(number),"title":"PR \#(number)","created_at":"2025-10-15T10:00:00Z"\#(draftField),
         "user":{"login":"\#(login)"},
         "html_url":"https://github.com/\#(repo)/pull/\#(number)",
         "repository_url":"https://api.github.com/repos/\#(repo)"}
        """#
    }

    func makeProvider(_ http: MockHTTPClient, owner: String = "acme") -> GitHubProvider {
        GitHubProvider(accountId: fixedAccountId, owner: owner, tokenSource: StaticTokenSource(token: "ghtok"), http: http)
    }

    @Test func searchesOpenPullRequestsForOrganization() async throws {
        let http = MockHTTPClient()
        http.on("search/issues", body: #"{"total_count":1,"items":[\#(item(number: 5, draft: true))]}"#)
        http.on("users/acme", body: #"{"type":"Organization"}"#)

        let prs = try await makeProvider(http).openPullRequests()

        let pr = try #require(prs.first)
        #expect(pr.repo == "acme/web")
        #expect(pr.number == 5)
        #expect(pr.title == "PR 5")
        #expect(pr.authorId == "octocat")
        #expect(pr.authorName == "octocat")
        #expect(pr.isDraft == true)
        #expect(pr.createdAt == Date(timeIntervalSince1970: 1_760_522_400))
        #expect(pr.webURL.absoluteString == "https://github.com/acme/web/pull/5")

        let searchURL = try #require(http.requests.last?.url)
        let q = URLComponents(url: searchURL, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "q" }?.value
        #expect(q == "is:pr is:open org:acme")
    }

    @Test func usesUserQualifierForUserOwner() async throws {
        let http = MockHTTPClient()
        http.on("search/issues", body: #"{"total_count":0,"items":[]}"#)
        http.on("users/alessandro", body: #"{"type":"User"}"#)

        _ = try await makeProvider(http, owner: "alessandro").openPullRequests()

        let searchURL = try #require(http.requests.last?.url)
        let q = URLComponents(url: searchURL, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "q" }?.value
        #expect(q == "is:pr is:open user:alessandro")
    }

    @Test func missingDraftFieldMeansNotDraft() async throws {
        let http = MockHTTPClient()
        http.on("search/issues", body: #"{"total_count":1,"items":[\#(item(number: 1, draft: nil))]}"#)
        http.on("users/acme", body: #"{"type":"Organization"}"#)
        #expect(try await makeProvider(http).openPullRequests().first?.isDraft == false)
    }

    @Test func displayNameIsLogin() async throws {
        let http = MockHTTPClient()
        http.on("github.com/user", body: #"{"login":"alessandro"}"#)
        #expect(try await makeProvider(http).currentUserDisplayName() == "alessandro")
    }

    @Test func sendsBearerAndGitHubHeaders() async throws {
        let http = MockHTTPClient()
        http.on("github.com/user", body: #"{"login":"alessandro"}"#)
        #expect(try await makeProvider(http).currentUserId() == "alessandro")
        let request = try #require(http.requests.first)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer ghtok")
        #expect(request.value(forHTTPHeaderField: "Accept") == "application/vnd.github+json")
        #expect(request.value(forHTTPHeaderField: "X-GitHub-Api-Version") == "2022-11-28")
    }

    @Test func listsOrgRepos() async throws {
        let http = MockHTTPClient()
        http.on("orgs/acme/repos", body: #"[{"full_name":"acme/web"},{"full_name":"acme/api"}]"#)
        http.on("users/acme", body: #"{"type":"Organization"}"#)
        #expect(try await makeProvider(http).listRepos() == ["acme/api", "acme/web"])
    }

    @Test func listsOwnReposIncludingPrivateViaUserEndpoint() async throws {
        let http = MockHTTPClient()
        http.on("user/repos", body: #"[{"full_name":"alessandro/secret"}]"#)
        http.on("users/alessandro", body: #"{"type":"User"}"#)
        http.on("github.com/user", body: #"{"login":"Alessandro"}"#)

        #expect(try await makeProvider(http, owner: "alessandro").listRepos() == ["alessandro/secret"])
        let reposURL = try #require(http.requests.last?.url?.absoluteString)
        #expect(reposURL.contains("affiliation=owner"))
    }

    @Test func rateLimitIsReported() async {
        let http = MockHTTPClient()
        http.on("users/acme", status: 403, headers: ["X-RateLimit-Remaining": "0", "X-RateLimit-Reset": "1760000600"], body: "{}")
        let provider = makeProvider(http)
        await #expect(throws: ProviderError.rateLimited(until: Date(timeIntervalSince1970: 1_760_000_600))) {
            try await provider.openPullRequests()
        }
    }

    @Test func paginatesSearchResults() async throws {
        let http = MockHTTPClient()
        let page1 = (1...100).map { item(number: $0) }.joined(separator: ",")
        http.on("page=2", body: #"{"total_count":101,"items":[\#(item(number: 101))]}"#)
        http.on("page=1", body: #"{"total_count":101,"items":[\#(page1)]}"#)
        http.on("users/acme", body: #"{"type":"Organization"}"#)
        #expect(try await makeProvider(http).openPullRequests().count == 101)
    }
}
