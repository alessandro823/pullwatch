import Foundation
@testable import PullwatchCore

actor MockProvider: PRProvider {
    private var userId = "me"
    private var pullRequests: [PullRequest] = []
    private var error: ProviderError?
    private var tagList: [Tag] = []
    private(set) var fetchCount = 0
    private(set) var tagFetchCount = 0
    private(set) var invalidateCount = 0

    func set(pullRequests: [PullRequest]) { self.pullRequests = pullRequests }
    func set(tags: [Tag]) { tagList = tags }
    func set(error: ProviderError?) { self.error = error }

    func currentUserId() async throws -> String {
        if let error { throw error }
        return userId
    }

    func testConnection() async throws -> String {
        if let error { throw error }
        return userId
    }

    func listRepos() async throws -> [String] { [] }

    func openPullRequests() async throws -> [PullRequest] {
        fetchCount += 1
        if let error { throw error }
        return pullRequests
    }

    func tags(in repos: [String]) async throws -> [Tag] {
        tagFetchCount += 1
        if let error { throw error }
        let wanted = Set(repos.map { $0.lowercased() })
        return tagList.filter { wanted.contains($0.repo.lowercased()) }
    }

    func invalidateCredentials() async { invalidateCount += 1 }
}

/// Provider waarvan `openPullRequests` pas terugkeert na `release()`; `started` meldt dat een fetch loopt.
actor GatedProvider: PRProvider {
    private let gate: AsyncStream<Void>
    private let gateContinuation: AsyncStream<Void>.Continuation
    let started: AsyncStream<Void>
    private let startedContinuation: AsyncStream<Void>.Continuation
    private(set) var fetchCount = 0

    init() {
        (gate, gateContinuation) = AsyncStream.makeStream()
        (started, startedContinuation) = AsyncStream.makeStream()
    }

    func release() { gateContinuation.yield() }

    func currentUserId() async throws -> String { "me" }
    func testConnection() async throws -> String { "me" }
    func listRepos() async throws -> [String] { [] }

    func openPullRequests() async throws -> [PullRequest] {
        fetchCount += 1
        startedContinuation.yield()
        for await _ in gate { break }
        return []
    }

    func tags(in repos: [String]) async throws -> [Tag] { [] }
    func invalidateCredentials() async {}
}
