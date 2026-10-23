import Foundation
@testable import PullwatchCore

actor MockProvider: PRProvider {
    private var userId = "me"
    private var pullRequests: [PullRequest] = []
    private var error: ProviderError?
    private var tagError: ProviderError?
    private var unavailableTagRepos: Set<String> = []
    private var tagList: [Tag] = []
    private var syncedPullRequests: [PullRequest] = []
    private var syncError: ProviderError?
    private(set) var fetchCount = 0
    private(set) var syncCount = 0
    /// Laatste aan `pullRequests(updatedSince:limit:)` doorgegeven `since` (nil = nog nooit aangeroepen).
    private(set) var lastSyncSince: Date??
    private(set) var tagFetchCount = 0
    private(set) var invalidateCount = 0

    func set(pullRequests: [PullRequest]) { self.pullRequests = pullRequests }
    func set(syncedPullRequests: [PullRequest]) { self.syncedPullRequests = syncedPullRequests }
    /// Fout die alleen `pullRequests(updatedSince:limit:)` gooit.
    func set(syncError: ProviderError?) { self.syncError = syncError }
    func set(tags: [Tag]) { tagList = tags }
    func set(error: ProviderError?) { self.error = error }
    /// Fout die alleen `tags(in:)` gooit.
    func set(tagError: ProviderError?) { self.tagError = tagError }
    /// Repo's die `tags(in:)` als onbereikbaar meldt (404/403).
    func set(unavailableTagRepos: [String]) { self.unavailableTagRepos = Set(unavailableTagRepos.map { $0.lowercased() }) }

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

    func pullRequests(updatedSince since: Date?, limit: Int) async throws -> [PullRequest] {
        syncCount += 1
        lastSyncSince = .some(since)
        if let syncError { throw syncError }
        return Array(syncedPullRequests.prefix(limit))
    }

    func tags(in repos: [String]) async throws -> TagFetch {
        tagFetchCount += 1
        if let error { throw error }
        if let tagError { throw tagError }
        let wanted = Set(repos.map { $0.lowercased() }).subtracting(unavailableTagRepos)
        return TagFetch(
            tags: tagList.filter { wanted.contains($0.repo.lowercased()) },
            unavailableRepos: repos.filter { unavailableTagRepos.contains($0.lowercased()) }
        )
    }

    func filePaths(in repo: String) async throws -> [String] { [] }
    func fileContent(in repo: String, path: String) async throws -> String { "" }
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

    func pullRequests(updatedSince since: Date?, limit: Int) async throws -> [PullRequest] { [] }
    func tags(in repos: [String]) async throws -> TagFetch { TagFetch(tags: []) }
    func filePaths(in repo: String) async throws -> [String] { [] }
    func fileContent(in repo: String, path: String) async throws -> String { "" }
    func invalidateCredentials() async {}
}
