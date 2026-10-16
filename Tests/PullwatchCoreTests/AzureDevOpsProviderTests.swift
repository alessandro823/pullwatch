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

    // MARK: - Tags

    @Test func parsesTagsFromRefs() async throws {
        let http = MockHTTPClient()
        http.on("_apis/git/repositories/api/refs", body: #"""
        {"value":[{"name":"refs/tags/v1.0","creator":{"displayName":"Jan"}},{"name":"refs/tags/release/2.0"}]}
        """#)

        let tags = try await makeProvider(http).tags(in: ["proj/api"]).tags

        #expect(tags.map(\.name) == ["v1.0", "release/2.0"])
        #expect(tags.map(\.authorName) == ["Jan", nil])
        #expect(tags.allSatisfy { $0.repo == "proj/api" && $0.accountId == fixedAccountId })
    }

    @Test func tagURLEncodesName() async throws {
        let http = MockHTTPClient()
        http.on("_apis/git/repositories/api/refs", body: #"{"value":[{"name":"refs/tags/release/2.0+b"}]}"#)

        let tags = try await makeProvider(http).tags(in: ["proj/api"]).tags

        #expect(tags.first?.webURL.absoluteString == "https://dev.azure.com/acme/proj/_git/api?version=GTrelease/2.0%2Bb")
    }

    @Test func missingRepoYieldsNoTags() async throws {
        let http = MockHTTPClient()
        http.on("/refs", status: 404, body: "{}")

        let fetch = try await makeProvider(http).tags(in: ["proj/gone"])

        #expect(fetch.tags.isEmpty)
        #expect(fetch.unavailableRepos == ["proj/gone"])
    }

    @Test func forbiddenRepoIsSkippedOthersStillYieldTags() async throws {
        let http = MockHTTPClient()
        http.on("_apis/git/repositories/secret/refs", status: 403, body: "{}")
        http.on("_apis/git/repositories/api/refs", body: #"{"value":[{"name":"refs/tags/v1"}]}"#)

        let fetch = try await makeProvider(http).tags(in: ["proj/secret", "proj/api"])
        let tags = fetch.tags

        #expect(fetch.unavailableRepos == ["proj/secret"])
        #expect(tags.map(\.name) == ["v1"])
        #expect(tags.allSatisfy { $0.repo == "proj/api" })
    }

    @Test func tagRequestFailureOtherThanNotFoundPropagates() async throws {
        let http = MockHTTPClient()
        http.on("/refs", status: 500, body: "{}")

        await #expect(throws: ProviderError.self) {
            _ = try await makeProvider(http).tags(in: ["proj/api"])
        }
    }

    @Test func requestsTagFilter() async throws {
        let http = MockHTTPClient()
        http.on("/refs", body: #"{"value":[]}"#)

        _ = try await makeProvider(http).tags(in: ["proj/api"])

        let url = try #require(http.requests.last?.url?.absoluteString)
        #expect(url.contains("filter=tags/"))
        #expect(url.contains("api-version=7.1"))
    }

    func syncPR(id: Int, status: String, closed: String? = nil) -> String {
        let closedField = closed.map { #","closedDate":"\#($0)""# } ?? ""
        return #"""
        {"pullRequestId":\#(id),"title":"PR \#(id)","creationDate":"2025-10-15T10:00:00Z","status":"\#(status)"\#(closedField),
         "createdBy":{"id":"user-guid","displayName":"Jan Jansen"},
         "repository":{"name":"api","project":{"name":"My Project"}}}
        """#
    }

    @Test func syncMapsStates() async throws {
        let http = MockHTTPClient()
        http.on("_apis/projects", body: projects)
        http.on("_apis/git/pullrequests", body: #"""
        {"value":[\#(syncPR(id: 1, status: "active")),
        \#(syncPR(id: 2, status: "completed", closed: "2025-10-16T09:00:00Z")),
        \#(syncPR(id: 3, status: "abandoned", closed: "2025-10-16T08:00:00Z"))]}
        """#)

        let prs = try await makeProvider(http).pullRequests(updatedSince: nil, limit: 1000)

        #expect(Set(prs.map(\.number)) == [1, 2, 3])
        let byNumber = Dictionary(uniqueKeysWithValues: prs.map { ($0.number, $0) })
        #expect(byNumber[1]?.state == .open)
        #expect(byNumber[2]?.state == .merged)
        #expect(byNumber[3]?.state == .closed)
        #expect(byNumber[1]?.closedAt == nil)
        #expect(byNumber[2]?.closedAt == Date(timeIntervalSince1970: 1_760_605_200))
    }

    @Test func syncMergesCreatedAndClosedWithoutDuplicates() async throws {
        let http = MockHTTPClient()
        http.on("_apis/projects", body: projects)
        http.on("queryTimeRangeType=created", body: #"{"value":[\#(syncPR(id: 1, status: "active")),\#(syncPR(id: 2, status: "active"))]}"#)
        http.on("queryTimeRangeType=closed", body: #"{"value":[\#(syncPR(id: 2, status: "completed")),\#(syncPR(id: 3, status: "abandoned"))]}"#)

        let prs = try await makeProvider(http).pullRequests(updatedSince: Date(timeIntervalSince1970: 1_760_000_000), limit: 1000)

        #expect(prs.map(\.number).sorted() == [1, 2, 3])
        let prRequests = http.requests.map(\.url!.absoluteString).filter { $0.contains("_apis/git/pullrequests") }
        #expect(prRequests.count == 2)
        for url in prRequests {
            #expect(url.contains("searchCriteria.minTime=2025-10-09T08:53:20Z") || url.contains("searchCriteria.minTime=2025-10-09T08%3A53%3A20Z"))
            #expect(url.contains("searchCriteria.status=all"))
        }
    }

    @Test func syncWithoutSinceUsesSingleQuery() async throws {
        let http = MockHTTPClient()
        http.on("_apis/projects", body: projects)
        http.on("_apis/git/pullrequests", body: #"{"value":[\#(syncPR(id: 1, status: "active"))]}"#)

        _ = try await makeProvider(http).pullRequests(updatedSince: nil, limit: 1000)

        let prRequests = http.requests.map(\.url!.absoluteString).filter { $0.contains("_apis/git/pullrequests") }
        #expect(prRequests.count == 1)
        #expect(!prRequests[0].contains("queryTimeRangeType"))
    }
}
