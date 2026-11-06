import Foundation
import Testing
@testable import PullwatchCore
@testable import PullwatchGitHub
import PullwatchTestSupport

/// De merge queue van GitHub bij de open PR's: via de gebundelde GraphQL-vraag, met plek en
/// tijdstip, en zonder dat een mislukte vraag of een oudere server de poll laat falen.
@Suite struct MergeQueueTests {
    func item(number: Int, draft: Bool = false) -> String {
        #"""
        {"number":\#(number),"title":"PR \#(number)","created_at":"2025-10-15T10:00:00Z","draft":\#(draft),
         "user":{"login":"octocat"},"html_url":"https://github.com/acme/web/pull/\#(number)",
         "repository_url":"https://api.github.com/repos/acme/web"}
        """#
    }

    let queued = #"""
        {"data":{"pr0":{"pullRequest":{"isInMergeQueue":true,"mergeQueueEntry":{"state":"AWAITING_CHECKS","position":2,"enqueuedAt":"2025-10-15T11:00:00Z"}}},
                 "pr1":{"pullRequest":{"isInMergeQueue":false,"mergeQueueEntry":null}}}}
        """#

    func makeHTTP(graphQL: String? = nil) -> MockHTTPClient {
        let http = MockHTTPClient()
        http.on("search/issues", body: #"{"total_count":3,"items":[\#(item(number: 1)),\#(item(number: 2)),\#(item(number: 3, draft: true))]}"#)
        http.on("users/acme", body: #"{"type":"Organization"}"#)
        if let graphQL { http.on("graphql", body: graphQL) }
        return http
    }

    func makeProvider(_ http: MockHTTPClient) -> GitHubProvider {
        GitHubProvider(accountId: fixedAccountId, owner: "acme", tokenSource: StaticTokenSource(token: "t"), http: http)
    }

    func graphQLBodies(_ http: MockHTTPClient) -> [String] {
        http.requests.filter { $0.url?.path() == "/graphql" }.compactMap { $0.httpBody.map { String(decoding: $0, as: UTF8.self) } }
    }

    @Test func `A queued pull request gets its position and time`() async throws {
        let http = makeHTTP(graphQL: queued)
        let prs = try await makeProvider(http).openPullRequests()

        let first = try #require(prs.first { $0.number == 1 })
        #expect(first.mergeQueue == MergeQueueEntry(
            kind: .mergeQueue, position: 2, enqueuedAt: Date(timeIntervalSince1970: 1_760_526_000)
        ))
        #expect(first.isQueued)
        #expect(prs.first { $0.number == 2 }?.mergeQueue == nil)
        #expect(prs.first { $0.number == 3 }?.mergeQueue == nil)
    }

    /// "Merge when ready" of "Enable auto-merge" zet alleen `autoMergeRequest`; de PR komt pas in
    /// de merge queue als zijn checks slagen. GitHub toont hem tot dan als open, Pullwatch ook.
    @Test func `Auto-merge before the queue is kept but not queued`() async throws {
        let http = makeHTTP(graphQL: #"""
            {"data":{"pr0":{"pullRequest":{"isInMergeQueue":false,"mergeQueueEntry":null,"autoMergeRequest":{"enabledAt":"2025-10-15T11:00:00Z"}}},
                     "pr1":{"pullRequest":{"isInMergeQueue":false,"mergeQueueEntry":null,"autoMergeRequest":null}}}}
            """#)
        let prs = try await makeProvider(http).openPullRequests()

        let first = try #require(prs.first { $0.number == 1 })
        #expect(first.mergeQueue == MergeQueueEntry(kind: .autoMerge, enqueuedAt: Date(timeIntervalSince1970: 1_760_526_000)))
        #expect(!first.isQueued)
    }

    @Test func `Drafts are not asked, the rest in one request`() async throws {
        let http = makeHTTP(graphQL: queued)
        _ = try await makeProvider(http).openPullRequests()

        let bodies = graphQLBodies(http)
        let body = try #require(bodies.first)
        #expect(bodies.count == 1)
        #expect(body.contains("isInMergeQueue mergeQueueEntry { state position enqueuedAt }"))
        #expect(body.contains("pr1:"))
        #expect(!body.contains("pr2:"), "een draft kan niet in de merge queue")
        // Alleen de wachtrij: geen co-auteurs of checks in deze vraag.
        #expect(!body.contains("commits(last"))
    }

    @Test func `A server without merge queues is not asked again`() async throws {
        let http = makeHTTP(graphQL: #"""
            {"errors":[{"message":"Field 'isInMergeQueue' doesn't exist on type 'PullRequest'","extensions":{"code":"undefinedField"}}]}
            """#)
        let provider = makeProvider(http)

        let prs = try await provider.openPullRequests()
        #expect(prs.count == 3)
        #expect(prs.allSatisfy { $0.mergeQueue == nil })
        _ = try await provider.openPullRequests()
        #expect(graphQLBodies(http).count == 1)
    }

    @Test func `A failed request keeps what the previous one said`() async throws {
        let http = makeHTTP()
        http.onSequence("graphql", bodies: [queued, #"{"errors":[{"type":"RATE_LIMITED","message":"API rate limit exceeded"}]}"#])
        let provider = makeProvider(http)

        _ = try await provider.openPullRequests()
        let again = try await provider.openPullRequests()

        #expect(again.first { $0.number == 1 }?.mergeQueue?.position == 2)
        #expect(again.first { $0.number == 2 }?.mergeQueue == nil)
    }

    @Test func `Leaving the queue clears it`() async throws {
        let http = makeHTTP()
        http.onSequence("graphql", bodies: [queued, #"{"data":{"pr0":{"pullRequest":{"isInMergeQueue":false,"mergeQueueEntry":null}},"pr1":{"pullRequest":{"isInMergeQueue":false,"mergeQueueEntry":null}}}}"#])
        let provider = makeProvider(http)

        _ = try await provider.openPullRequests()
        let again = try await provider.openPullRequests()

        #expect(again.allSatisfy { $0.mergeQueue == nil })
    }

    @Test func `Without open ready pull requests there is no request`() async throws {
        let http = MockHTTPClient()
        http.on("search/issues", body: #"{"total_count":1,"items":[\#(item(number: 3, draft: true))]}"#)
        http.on("users/acme", body: #"{"type":"Organization"}"#)

        _ = try await makeProvider(http).openPullRequests()

        #expect(graphQLBodies(http).isEmpty)
    }
}
