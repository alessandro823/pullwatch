import Foundation
import Testing
@testable import PullwatchCore

@Suite struct AzureDevOpsProviderTests {
    let projects = #"{"count":1,"value":[{"name":"My Project"}]}"#

    func prJSON(id: Int, draft: Bool? = nil, date: String = "2025-10-15T10:00:00.1234567Z") -> String {
        let draftField = draft.map { #","isDraft":\#($0)"# } ?? ""
        return #"""
        {"pullRequestId":\#(id),"title":"PR \#(id)","creationDate":"\#(date)"\#(draftField),
         "createdBy":{"id":"user-guid","displayName":"Jan Jansen"},
         "repository":{"name":"api","project":{"name":"My Project"}}}
        """#
    }

    func makeProvider(_ http: MockHTTPClient, auth: AuthMethod = .pat, token: String = "secret") -> AzureDevOpsProvider {
        AzureDevOpsProvider(
            accountId: fixedAccountId,
            organization: "acme",
            tokenSource: StaticTokenSource(token: token),
            authMethod: auth,
            http: http
        )
    }

    @Test func mapsPullRequestFields() async throws {
        let http = MockHTTPClient()
        http.on("_apis/projects", body: projects)
        http.on("_apis/git/pullrequests", body: #"{"value":[\#(prJSON(id: 17))]}"#)

        let prs = try await makeProvider(http).openPullRequests()

        let pr = try #require(prs.first)
        #expect(prs.count == 1)
        #expect(pr.accountId == fixedAccountId)
        #expect(pr.repo == "My Project/api")
        #expect(pr.number == 17)
        #expect(pr.title == "PR 17")
        #expect(pr.authorId == "user-guid")
        #expect(pr.authorName == "Jan Jansen")
        #expect(pr.isDraft == false)
        #expect(pr.createdAt == Date(timeIntervalSince1970: 1_760_522_400))
        #expect(pr.webURL.absoluteString == "https://dev.azure.com/acme/My%20Project/_git/api/pullrequest/17")
    }

    @Test func requestsActivePullRequestsWithApiVersion() async throws {
        let http = MockHTTPClient()
        http.on("_apis/projects", body: projects)
        http.on("_apis/git/pullrequests", body: #"{"value":[]}"#)

        _ = try await makeProvider(http).openPullRequests()

        let url = try #require(http.requests.last?.url?.absoluteString)
        #expect(url.hasPrefix("https://dev.azure.com/acme/My%20Project/_apis/git/pullrequests?"))
        #expect(url.contains("searchCriteria.status=active"))
        #expect(url.contains("api-version=7.1"))
    }

    @Test func patUsesBasicAuth() async throws {
        let http = MockHTTPClient()
        http.on("connectionData", body: #"{"authenticatedUser":{"id":"me-guid"}}"#)
        _ = try await makeProvider(http, auth: .pat, token: "secret").currentUserId()
        let expected = "Basic " + Data(":secret".utf8).base64EncodedString()
        #expect(http.requests.first?.value(forHTTPHeaderField: "Authorization") == expected)
    }

    @Test func cliUsesBearerAuth() async throws {
        let http = MockHTTPClient()
        http.on("connectionData", body: #"{"authenticatedUser":{"id":"me-guid"}}"#)
        let id = try await makeProvider(http, auth: .cli, token: "jwt").currentUserId()
        #expect(id == "me-guid")
        #expect(http.requests.first?.value(forHTTPHeaderField: "Authorization") == "Bearer jwt")
    }

    @Test func testConnectionReturnsDisplayNameAfterCheckingOrganizationAccess() async throws {
        let http = MockHTTPClient()
        http.on("connectionData", body: #"{"authenticatedUser":{"id":"me-guid","providerDisplayName":"Alessandro Torrisi"}}"#)
        http.on("_apis/projects", body: projects)
        let name = try await makeProvider(http).testConnection()
        #expect(name == "Alessandro Torrisi")
        #expect(http.requests.contains { $0.url!.absoluteString.contains("_apis/projects") })
    }

    @Test func testConnectionReportsNoAccessWhenOrganizationRejectsToken() async {
        // connectionData is not organization-scoped: it succeeds for any org name.
        let http = MockHTTPClient()
        http.on("connectionData", body: #"{"authenticatedUser":{"id":"me-guid","providerDisplayName":"Alessandro Torrisi"}}"#)
        http.on("_apis/projects", status: 401, body: "")
        let provider = makeProvider(http)
        await #expect(throws: ProviderError.noAccess("acme")) { try await provider.testConnection() }
    }

    @Test func anonymousIdentityMeansUnauthorized() async {
        // Azure DevOps answers connectionData with an anonymous user when the token is not accepted.
        let http = MockHTTPClient()
        http.on("connectionData", body: #"{"authenticatedUser":{"id":"aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa","providerDisplayName":"Anonymous"}}"#)
        let provider = makeProvider(http)
        await #expect(throws: ProviderError.unauthorized) { try await provider.currentUserId() }
        await #expect(throws: ProviderError.unauthorized) { try await provider.testConnection() }
    }

    @Test func paginatesWithSkip() async throws {
        let http = MockHTTPClient()
        http.on("_apis/projects", body: projects)
        let page1 = (1...100).map { prJSON(id: $0) }.joined(separator: ",")
        http.on("skip=100", body: #"{"value":[\#(prJSON(id: 101))]}"#)
        http.on("skip=0", body: #"{"value":[\#(page1)]}"#)

        let prs = try await makeProvider(http).openPullRequests()
        #expect(prs.count == 101)
    }

    @Test func draftFlagIsMapped() async throws {
        let http = MockHTTPClient()
        http.on("_apis/projects", body: projects)
        http.on("_apis/git/pullrequests", body: #"{"value":[\#(prJSON(id: 1, draft: true))]}"#)
        #expect(try await makeProvider(http).openPullRequests().first?.isDraft == true)
    }

    @Test func invalidPatLoginPageIsUnauthorized() async {
        let http = MockHTTPClient()
        http.on("_apis/projects", status: 203, body: "<html>Sign in</html>")
        let provider = makeProvider(http)
        await #expect(throws: ProviderError.unauthorized) { try await provider.openPullRequests() }
    }

    @Test func listsReposAsProjectSlashRepo() async throws {
        let http = MockHTTPClient()
        http.on("_apis/projects", body: projects)
        http.on("_apis/git/repositories", body: #"{"value":[{"name":"web"},{"name":"api"}]}"#)
        #expect(try await makeProvider(http).listRepos() == ["My Project/api", "My Project/web"])
    }

    @Test func cachesProjectsForAnHour() async throws {
        let http = MockHTTPClient()
        http.on("_apis/projects", body: projects)
        http.on("_apis/git/pullrequests", body: #"{"value":[]}"#)
        let provider = makeProvider(http)
        _ = try await provider.openPullRequests()
        _ = try await provider.openPullRequests()
        let projectCalls = http.requests.filter { $0.url!.absoluteString.contains("_apis/projects") }
        #expect(projectCalls.count == 1)
    }
}
