import Foundation
import os

private let logger = Logger(subsystem: "nl.torrisi.pullwatch", category: "engine")

public enum AccountState: Equatable, Sendable {
    case idle
    case ok(lastPoll: Date)
    case failed(ProviderError, since: Date)
}

public struct PollResult: Equatable, Sendable {
    public var newPullRequests: [PullRequest] = []
    /// Nieuwe tags, gesorteerd op repo en dan naam.
    public var newTags: [Tag] = []
    public var statuses: [UUID: AccountState] = [:]
    /// Accounts die in deze cyclus net naar `.unauthorized` gingen (één melding per overgang).
    public var authFailures: [UUID] = []
}

public actor PollEngine {
    public typealias ProviderFactory = @Sendable (Account) -> any PRProvider

    /// Tags worden los van het PR-interval opgehaald, hooguit eens per kwartier.
    public static let tagInterval: TimeInterval = 900

    private struct Schedule {
        var nextDue: Date = .distantPast
        var nextTagDue: Date = .distantPast
        var failures = 0
        var rateLimitedUntil: Date?
    }

    private struct Fetched {
        let userId: String
        let pullRequests: [PullRequest]
        /// `nil` als tags deze cyclus niet aan de beurt waren.
        let tags: [Tag]?
        let tagRepos: [String]
    }

    private static let maxRateLimitWait: TimeInterval = 3600

    private let makeProvider: ProviderFactory
    private let store: JSONFileStore<SeenState>?
    private let now: @Sendable () -> Date
    private var state: SeenState
    private var providers: [UUID: (account: Account, provider: any PRProvider)] = [:]
    private var userIds: [UUID: String] = [:]
    private var schedules: [UUID: Schedule] = [:]
    private var statuses: [UUID: AccountState] = [:]
    private var inFlight: Set<UUID> = []

    public init(
        makeProvider: @escaping ProviderFactory,
        store: JSONFileStore<SeenState>?,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.makeProvider = makeProvider
        self.store = store
        self.now = now
        do {
            self.state = try store?.load() ?? SeenState()
        } catch {
            logger.error("seen-state onleesbaar, start leeg: \(error.localizedDescription)")
            self.state = SeenState()
        }
    }

    public func forceRefresh() {
        let t = now()
        for (id, var schedule) in schedules {
            if let until = schedule.rateLimitedUntil, until > t { continue }
            schedule.nextDue = t
            schedule.nextTagDue = t
            schedules[id] = schedule
        }
    }

    public func poll(accounts: [Account], interval: TimeInterval) async -> PollResult {
        let t = now()
        forget(except: Set(accounts.map(\.id)))

        let jobs = accounts
            .filter { !inFlight.contains($0.id) && (schedules[$0.id]?.nextDue ?? .distantPast) <= t }
            .map { account in
                let tagsDue = (schedules[account.id]?.nextTagDue ?? .distantPast) <= t
                return (
                    account: account,
                    provider: provider(for: account),
                    userId: userIds[account.id],
                    tagRepos: account.tagRepos,
                    fetchTags: tagsDue && !account.tagRepos.isEmpty
                )
            }
        // Markeer vóór de eerste suspensie, zodat overlappende poll()-aanroepen deze accounts overslaan.
        for job in jobs { inFlight.insert(job.account.id) }
        let jobsById = Dictionary(uniqueKeysWithValues: jobs.map { ($0.account.id, $0) })

        var result = PollResult()
        var succeeded: [UUID] = []
        await withTaskGroup(of: (UUID, Result<Fetched, ProviderError>).self) { group in
            for job in jobs {
                group.addTask {
                    (job.account.id, await Self.fetch(
                        job.provider,
                        knownUserId: job.userId,
                        tagRepos: job.tagRepos,
                        fetchTags: job.fetchTags
                    ))
                }
            }
            // Pas elk resultaat direct toe zodra het binnenkomt (actor-geïsoleerd).
            for await (id, outcome) in group {
                guard let job = jobsById[id] else { continue }
                switch outcome {
                case .success(let fetched):
                    let fresh = handleSuccess(job.account, fetched, at: t, interval: interval)
                    result.newPullRequests += fresh.pullRequests
                    result.newTags += fresh.tags
                    succeeded.append(id)
                case .failure(let error):
                    if await handleFailure(job.account, job.provider, error, at: t, interval: interval) {
                        result.authFailures.append(id)
                    }
                }
                inFlight.remove(id)
            }
        }

        // Alleen accounts die nu slaagden prunen: een langdurig falend account mag zijn seen niet kwijtraken.
        state.prune(now: t, onlyKeyPrefixes: succeeded.map { "\($0.uuidString):" })
        do {
            try store?.save(state)
        } catch {
            logger.error("seen-state opslaan mislukt: \(error.localizedDescription)")
        }

        result.newPullRequests.sort { $0.createdAt < $1.createdAt }
        result.newTags.sort { ($0.repo, $0.name) < ($1.repo, $1.name) }
        result.statuses = Dictionary(uniqueKeysWithValues: accounts.map { ($0.id, statuses[$0.id] ?? .idle) })
        return result
    }

    private static func fetch(
        _ provider: any PRProvider,
        knownUserId: String?,
        tagRepos: [String],
        fetchTags: Bool
    ) async -> Result<Fetched, ProviderError> {
        do {
            let userId: String
            if let knownUserId {
                userId = knownUserId
            } else {
                userId = try await provider.currentUserId()
            }
            let pullRequests = try await provider.openPullRequests()
            let tags = fetchTags ? try await provider.tags(in: tagRepos) : nil
            return .success(Fetched(userId: userId, pullRequests: pullRequests, tags: tags, tagRepos: tagRepos))
        } catch let error as ProviderError {
            return .failure(error)
        } catch {
            return .failure(.network(error.localizedDescription))
        }
    }

    private func provider(for account: Account) -> any PRProvider {
        if let cached = providers[account.id], cached.account == account {
            return cached.provider
        }
        let provider = makeProvider(account)
        providers[account.id] = (account, provider)
        userIds[account.id] = nil
        return provider
    }

    private func forget(except ids: Set<UUID>) {
        providers = providers.filter { ids.contains($0.key) }
        userIds = userIds.filter { ids.contains($0.key) }
        schedules = schedules.filter { ids.contains($0.key) }
        statuses = statuses.filter { ids.contains($0.key) }
        let keys = Set(ids.map(\.uuidString))
        state.lastSettings = state.lastSettings.filter { keys.contains($0.key) }
        state.retain(onlyKeyPrefixes: keys.map { "\($0):" })
    }

    private func handleSuccess(
        _ account: Account,
        _ fetched: Fetched,
        at t: Date,
        interval: TimeInterval
    ) -> (pullRequests: [PullRequest], tags: [Tag]) {
        let settings = account.filterSettings
        let key = account.id.uuidString
        let previous = state.lastSettings[key].flatMap { $0.sameSource(as: settings) ? $0 : nil }

        var fresh: [PullRequest] = []
        for pr in fetched.pullRequests where PRFilter.passes(pr, settings: settings, currentUserId: fetched.userId) {
            // Alleen melden als de PR onder de vorige settings ook zichtbaar was; anders is hij
            // pas zichtbaar door een instellingswijziging of eerste poll → stil seeden.
            if !state.contains(pr.dedupKey), let previous,
               PRFilter.passes(pr, settings: previous, currentUserId: fetched.userId) {
                fresh.append(pr)
            }
            state.mark(pr.dedupKey, at: t)
        }

        state.lastSettings[key] = settings
        userIds[account.id] = fetched.userId
        var schedule = Schedule(nextDue: t + interval, nextTagDue: schedules[account.id]?.nextTagDue ?? .distantPast)
        if fetched.tags != nil {
            schedule.nextTagDue = t + Self.tagInterval
        }
        schedules[account.id] = schedule
        statuses[account.id] = .ok(lastPoll: t)
        return (fresh, handleTags(account, fetched, at: t))
    }

    /// Eerste tag-poll per repo is stil; daarna wordt elke onbekende tag gemeld.
    private func handleTags(_ account: Account, _ fetched: Fetched, at t: Date) -> [Tag] {
        let prefix = "\(account.id.uuidString):"
        // Repo's waarvan tags uit staan vergeten, zodat weer aanzetten opnieuw stil seedt.
        let wantedKeys = Set(fetched.tagRepos.map { prefix + $0.lowercased() })
        state.tagSeeded = state.tagSeeded.filter { !$0.hasPrefix(prefix) || wantedKeys.contains($0) }

        guard let tags = fetched.tags else { return [] }
        let tagsByRepo = Dictionary(grouping: tags) { $0.repo.lowercased() }
        var fresh: [Tag] = []
        for repo in Set(fetched.tagRepos.map { $0.lowercased() }) {
            let seededKey = prefix + repo
            let isSeeded = state.tagSeeded.contains(seededKey)
            for tag in tagsByRepo[repo] ?? [] {
                if isSeeded, !state.contains(tag.dedupKey) {
                    fresh.append(tag)
                }
                state.mark(tag.dedupKey, at: t)
            }
            state.tagSeeded.insert(seededKey)
        }
        return fresh
    }

    /// Geeft `true` als het account net naar `.unauthorized` is overgegaan.
    private func handleFailure(
        _ account: Account,
        _ provider: any PRProvider,
        _ error: ProviderError,
        at t: Date,
        interval: TimeInterval
    ) async -> Bool {
        var schedule = schedules[account.id] ?? Schedule()
        schedule.failures += 1
        if case .rateLimited(let until) = error {
            let clamped = min(until, t + Self.maxRateLimitWait)
            schedule.rateLimitedUntil = clamped
            schedule.nextDue = clamped
        } else {
            schedule.rateLimitedUntil = nil
            schedule.nextDue = t + Backoff.delay(baseInterval: interval, consecutiveFailures: schedule.failures)
        }
        schedules[account.id] = schedule

        var wasUnauthorized = false
        if case .failed(let previous, let since) = statuses[account.id], previous == error {
            wasUnauthorized = previous == .unauthorized
            statuses[account.id] = .failed(error, since: since)
        } else {
            statuses[account.id] = .failed(error, since: t)
        }
        logger.warning("poll mislukt voor \(account.displayName, privacy: .public): \(error.userMessage, privacy: .public)")

        guard error == .unauthorized else { return false }
        userIds[account.id] = nil
        await provider.invalidateCredentials()
        return !wasUnauthorized
    }
}
