import Foundation
import Testing
@testable import PullwatchCore
@testable import PullwatchGitLab
import PullwatchTestSupport

/// Auto-merge en merge trains van GitLab: een merge request met "merge als de pipeline slaagt"
/// staat in de rij, en in een merge train met zijn plek.
@Suite struct MergeTrainTests {
    let api = "https://gitlab.com/api/v4/"

    func makeProvider(_ http: MockHTTPClient, now: Date = Date.testStart) -> GitLabProvider {
        GitLabProvider(
            accountId: fixedAccountId, owners: ["acme"], tokenSource: StaticTokenSource(token: "glpat-secret"), http: http,
            now: { now }
        )
    }

    func car(id: Int, iid: Int, branch: String = "main") -> String {
        #"{"id":\#(id),"target_branch":"\#(branch)","status":"fresh","created_at":"2025-10-15T11:00:00.000Z","merge_request":{"iid":\#(iid),"title":"MR \#(iid)"}}"#
    }

    func makeHTTP(trains: String? = nil, trainStatus: Int = 200) -> MockHTTPClient {
        let http = MockHTTPClient()
        http.on("\(api)groups/acme?", body: GitLabFixtures.group)
        http.on("groups/acme/merge_requests", body: "[" + [
            GitLabFixtures.mergeRequest(iid: 12, autoMerge: true),
            GitLabFixtures.mergeRequest(iid: 13, autoMerge: true),
            GitLabFixtures.mergeRequest(iid: 14),
        ].joined(separator: ",") + "]")
        if let trains { http.on("merge_trains", status: trainStatus, body: trains) }
        return http
    }

    func trainRequests(_ http: MockHTTPClient) -> [String] {
        http.requests.compactMap { $0.url?.absoluteString }.filter { $0.contains("merge_trains") }
    }

    @Test func `Auto-merge without a train is kept but not queued`() async throws {
        let http = makeHTTP(trains: #"{"message":"403 Forbidden"}"#, trainStatus: 403)
        let prs = try await makeProvider(http).openPullRequests()

        #expect(prs.first { $0.number == 12 }?.mergeQueue == MergeQueueEntry(kind: .autoMerge))
        #expect(prs.first { $0.number == 12 }?.isQueued == false)
        #expect(prs.first { $0.number == 14 }?.mergeQueue == nil)
    }

    @Test func `A merge train gives each merge request its place per target branch`() async throws {
        let http = makeHTTP(trains: "[" + [car(id: 7, iid: 13), car(id: 5, iid: 12), car(id: 6, iid: 99, branch: "release")].joined(separator: ",") + "]")
        let prs = try await makeProvider(http).openPullRequests()

        let first = try #require(prs.first { $0.number == 12 }?.mergeQueue)
        #expect(first == MergeQueueEntry(kind: .mergeTrain, position: 1, enqueuedAt: Date(timeIntervalSince1970: 1_760_526_000)))
        #expect(prs.first { $0.number == 13 }?.mergeQueue?.position == 2)
        let url = try #require(trainRequests(http).first)
        #expect(url == "\(api)projects/acme%2Fplatform%2Fapi/merge_trains?scope=active&sort=asc&per_page=100&page=1")
    }

    @Test func `A project without merge trains is not asked again for a day`() async throws {
        let http = makeHTTP(trains: #"{"message":"404 Not found"}"#, trainStatus: 404)
        let provider = makeProvider(http)

        _ = try await provider.openPullRequests()
        _ = try await provider.openPullRequests()

        #expect(trainRequests(http).count == 1)
    }

    @Test func `Without auto-merge there is no train request`() async throws {
        let http = MockHTTPClient()
        http.on("\(api)groups/acme?", body: GitLabFixtures.group)
        http.on("groups/acme/merge_requests", body: "[\(GitLabFixtures.mergeRequest(iid: 14))]")

        let prs = try await makeProvider(http).openPullRequests()

        #expect(prs.first?.mergeQueue == nil)
        #expect(trainRequests(http).isEmpty)
    }

    @Test func `A merged merge request is not queued`() async throws {
        let http = MockHTTPClient()
        http.on("\(api)groups/acme?", body: GitLabFixtures.group)
        http.on("groups/acme/merge_requests", body: "[\(GitLabFixtures.mergeRequest(iid: 15, state: "merged", mergedAt: "2025-10-16T10:00:00Z", autoMerge: true))]")

        let prs = try await makeProvider(http).pullRequests(updatedSince: nil, limit: 10)

        #expect(prs.first?.mergeQueue == nil)
    }
}
