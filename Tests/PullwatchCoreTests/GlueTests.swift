import Foundation
import Testing
@testable import PullwatchCore

@Suite struct GlueTests {
    @Test func backoffDoublesPerFailureAndCaps() {
        #expect(Backoff.delay(baseInterval: 120, consecutiveFailures: 0) == 120)
        #expect(Backoff.delay(baseInterval: 120, consecutiveFailures: 1) == 240)
        #expect(Backoff.delay(baseInterval: 120, consecutiveFailures: 2) == 480)
        #expect(Backoff.delay(baseInterval: 120, consecutiveFailures: 3) == 900)
        #expect(Backoff.delay(baseInterval: 120, consecutiveFailures: 50) == 900)
    }

    @Test func upToThreeNewPullRequestsGetIndividualNotifications() {
        let prs = (1...3).map { PullRequest.fixture(number: $0) }
        #expect(NotificationPlanner.plan(prs) == prs.map { .single($0) })
    }

    @Test func moreThanThreeBecomesOneSummaryWithFirstThreeLines() {
        let prs = (1...5).map { PullRequest.fixture(repo: "p/r", number: $0, title: "T\($0)") }
        #expect(NotificationPlanner.plan(prs) == [.summary(count: 5, lines: ["p/r: T1", "p/r: T2", "p/r: T3"])])
    }

    @Test func emptyInputPlansNothing() {
        #expect(NotificationPlanner.plan([]).isEmpty)
    }

    @Test func factoryPicksProviderByKind() {
        #expect(ProviderFactory.make(Account.fixture(kind: .azureDevOps)) is AzureDevOpsProvider)
        #expect(ProviderFactory.make(Account.fixture(kind: .gitHub)) is GitHubProvider)
    }

    @Test func factoryUsesPatOverrideBeforeKeychain() async throws {
        let http = MockHTTPClient()
        http.on("github.com/user", body: #"{"login":"me"}"#)
        let provider = ProviderFactory.make(Account.fixture(kind: .gitHub), pat: "typed", secrets: InMemorySecretStore(), http: http)
        _ = try await provider.currentUserId()
        #expect(http.requests.first?.value(forHTTPHeaderField: "Authorization") == "Bearer typed")
    }

    @Test func factoryReadsPatFromSecretStore() async throws {
        let http = MockHTTPClient()
        http.on("github.com/user", body: #"{"login":"me"}"#)
        let account = Account.fixture(kind: .gitHub)
        let secrets = InMemorySecretStore()
        try secrets.write("stored", account: account.id.uuidString)
        _ = try await ProviderFactory.make(account, secrets: secrets, http: http).currentUserId()
        #expect(http.requests.first?.value(forHTTPHeaderField: "Authorization") == "Bearer stored")
    }
}
