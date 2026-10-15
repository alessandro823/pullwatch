import Foundation
@testable import PullwatchCore

actor MockProvider: PRProvider {
    private var userId = "me"
    private var pullRequests: [PullRequest] = []
    private var error: ProviderError?
    private(set) var fetchCount = 0
    private(set) var invalidateCount = 0

    func set(pullRequests: [PullRequest]) { self.pullRequests = pullRequests }
    func set(error: ProviderError?) { self.error = error }

    func currentUserId() async throws -> String {
        if let error { throw error }
        return userId
    }

    func listRepos() async throws -> [String] { [] }

    func openPullRequests() async throws -> [PullRequest] {
        fetchCount += 1
        if let error { throw error }
        return pullRequests
    }

    func invalidateCredentials() async { invalidateCount += 1 }
}
