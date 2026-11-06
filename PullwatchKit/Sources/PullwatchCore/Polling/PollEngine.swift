public import Foundation
import os

private let logger = Log(category: "engine")

/// Haalt per account de pull requests, tags, checks en geschiedenis op, onthoudt wat al gezien is
/// en houdt per account de planning en de backoff bij.
public actor PollEngine {
    public typealias ProviderFactory = @Sendable (Account) -> any PRProvider

    /// Tags worden los van het PR-interval opgehaald, hooguit eens per kwartier.
    static let tagInterval: TimeInterval = 900
    /// Maximaal aantal PR's per account per geschiedenis-sync.
    static let syncLimit = 1000
    /// Een vervolg-sync kijkt zoveel terug vóór de vorige sync, zodat randgevallen niet wegvallen.
    static let syncOverlap: TimeInterval = 3600
    /// Maximaal aantal bestaande tags per repo dat de eerste tag-poll in de geschiedenis zet.
    static let tagBackfillLimit = 100
    /// Maximaal aantal PR's per account per poll waarvan de co-auteurs opgehaald worden; nieuwe
    /// open PR's eerst. Wat overblijft komt bij een volgende poll aan de beurt (open PR's) of
    /// zodra de PR verandert.
    static let coAuthorLimit = 50
    /// Maximaal aantal PR's per account per poll waarvan de checks opgehaald worden.
    static let checkLimit = 50
    /// Zo lang na de merge haalt Pullwatch de checks van een gemergde PR nog op.
    static let recentlyMerged: TimeInterval = 3 * 86_400
    /// Mislukte checks van een open PR die niet veranderde: zo vaak opnieuw, voor een check die
    /// opnieuw gestart werd (dat verandert de PR zelf niet).
    static let failedCheckRefresh: TimeInterval = 900
    /// Na "geen toestemming" zo lang wachten voor de volgende vraag.
    static let checkPermissionRetry: TimeInterval = 3600

    private struct Schedule {
        var nextDue: Date = .distantPast
        var nextTagDue: Date = .distantPast
        /// Geschiedenis-sync loopt op het tag-ritme mee met een PR-poll die toch al draait.
        var nextSyncDue: Date = .distantPast
        var failures = 0
        var rateLimitedUntil: Date?
    }

    struct Fetched {
        let userId: String
        let pullRequests: [PullRequest]
        /// Open PR's (dedupKeys) waarvan niet te lezen was of ze in de rij staan
        /// (`PRProvider.unreadMergeQueues`).
        let unreadMergeQueues: Set<String>
        /// `nil` als tags deze cyclus niet aan de beurt waren of het ophalen mislukte.
        let tags: [Tag]?
        /// De repo's waarvan de tags opgehaald zijn; bij tags volgen als standaard uit de lijst
        /// van de dienst.
        let tagRepos: [String]
        /// Gedateerde tags van repo's die nog niet geseed waren (`PRProvider.datedTags`).
        let backfillTags: [Tag]
        /// Tag-repo's die de provider oversloeg (404/geen toegang), lowercased.
        let unavailableTagRepos: Set<String>
        /// Tag-repo's die niet veranderden sinds hun vingerafdruk, lowercased; zonder tags.
        let unchangedTagRepos: Set<String>
        /// Nieuwe vingerafdrukken per tag-repo, lowercased.
        let tagFingerprints: [String: String]
        /// Fout bij het ophalen van tags die het account niet laat falen (zie `fetchTags`).
        let tagError: ProviderError?
        /// `nil` als de sync deze cyclus niet aan de beurt was of mislukte.
        let synced: [PullRequest]?
        /// Fout bij de geschiedenis-sync; laat het account nooit falen.
        let syncError: ProviderError?
        /// Net opgehaalde co-auteurs per dedupKey, met de revisie waarbij ze horen.
        let coAuthors: [String: (revision: String?, people: [Person])]
        /// Net opgehaalde checks per dedupKey, met de revisie waarbij ze horen.
        let checks: [String: (revision: String?, checks: PRChecks)]
    }

    /// Welke checks een poll vraagt: ook van de eigen PR's als `hideOwn` aan staat (voor de
    /// melding), met de bekende checks en het moment van de poll.
    struct CheckRequest: Sendable {
        /// De bron CI-checks staat aan (`DataSourceID.ciChecks`); uit vraagt de poll geen checks.
        let isEnabled: Bool
        let includeOwn: Bool
        let known: [String: CheckMark]
        let at: Date
    }

    /// Waar een poll de tags van ophaalt: het account (eigen instellingen, standaard) en de repo's
    /// (lowercased) waarvan de eerste tag-poll al gedaan is, met hun vingerafdruk als die er is.
    struct TagRepos: Sendable {
        let account: Account
        let seeded: Set<String>
        let fingerprints: [String: String]
    }

    /// Een geschiedenis-sync die deze cyclus moet draaien; `since == nil` haalt alles op.
    struct SyncRequest: Sendable {
        let since: Date?
        /// Eerste sync over de hele bewaartermijn (geen geldige `SyncMark`).
        let isFirst: Bool
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
    /// Account waarvan de eerste sync (volledige backfill) nu loopt; geldt over overlappende poll()-aanroepen heen.
    private var firstSyncAccount: UUID?
    /// Sync-markeringen van vóór "Opnieuw ophalen", per account dat nog niet opnieuw gesynct is;
    /// `cancelHistoryResync` zet ze terug.
    private var resyncBackup: [String: SyncMark] = [:]

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

    /// Vergeet alle sync-markeringen en pollt meteen, zodat elk account de geschiedenis binnen de
    /// bewaartermijn opnieuw ophaalt (één account tegelijk, zoals bij de eerste sync).
    public func resetHistorySync() {
        resyncBackup = resyncBackup.merging(state.syncMarks) { kept, _ in kept }
        state.syncMarks = [:]
        forceRefresh()
    }

    /// Stopt "Opnieuw ophalen": accounts die nog niet opnieuw gesynct zijn krijgen hun vorige
    /// sync-markering terug en gaan verder met een gewone vervolg-sync. Wat al opnieuw is
    /// opgehaald (of nu loopt) blijft.
    public func cancelHistoryResync() {
        for (key, mark) in resyncBackup where state.syncMarks[key] == nil {
            state.syncMarks[key] = mark
        }
        resyncBackup = [:]
        do {
            try store?.save(state)
        } catch {
            logger.error("seen-state opslaan mislukt: \(error.localizedDescription)")
        }
    }

    /// Wie elk account bij zijn dienst is (`PRProvider.currentUserId()`), zoals de laatste poll het
    /// vroeg: om eigen PR's te herkennen (`PullRequest.authorId`). Een account dat nog niet gepold
    /// is, of waarvan de provider net opnieuw gemaakt is, staat er niet in. Geen geheim: een id of
    /// login.
    public func currentUserIds() -> [UUID: String] {
        userIds
    }

    /// Tijdstip van de laatste geslaagde sync per account (alleen accounts met een sync).
    public func lastHistorySync(for ids: [UUID]) -> [UUID: Date] {
        var result: [UUID: Date] = [:]
        for id in ids {
            if let mark = state.syncMarks[id.uuidString] { result[id] = mark.at }
        }
        return result
    }

    /// Accounts waarvan de geschiedenis nog een eerste sync over de hele bewaartermijn nodig heeft
    /// (nieuw account, of andere filters of bewaartermijn); hun lijsten zijn dan nog niet gevuld.
    public func pendingFirstSync(accounts: [Account], retention: HistoryRetention) -> Set<UUID> {
        let t = now()
        return Set(accounts.filter { syncRequest(for: $0, retention: retention, at: t).isFirst }.map(\.id))
    }

    public func forceRefresh() {
        let t = now()
        for (id, var schedule) in schedules {
            if let until = schedule.rateLimitedUntil, until > t { continue }
            schedule.nextDue = t
            schedule.nextTagDue = t
            schedule.nextSyncDue = t
            schedules[id] = schedule
        }
    }

    public func poll(
        accounts: [Account],
        interval: TimeInterval,
        retention: HistoryRetention,
        checksForOwnPullRequests: Bool = false,
        fetchChecks: Bool = true,
        progress: (@Sendable (PollProgress) async -> Void)? = nil
    ) async -> PollResult {
        let t = now()
        forget(except: Set(accounts.map(\.id)))

        // Hooguit één eerste sync (volledige backfill) tegelijk, ook als poll() overlapt (bv. "Nu
        // verversen" naast de timer), zodat de backfills van meerdere accounts niet samen de
        // zoek-ratelimit opmaken. Andere accounts houden hun `nextSyncDue` en komen later aan de
        // beurt; vervolg-syncs lopen gewoon mee.
        let jobs = accounts
            .filter { !inFlight.contains($0.id) && (schedules[$0.id]?.nextDue ?? .distantPast) <= t }
            .map { account in
                let tagsDue = (schedules[account.id]?.nextTagDue ?? .distantPast) <= t
                let syncDue = (schedules[account.id]?.nextSyncDue ?? .distantPast) <= t
                var sync = syncDue ? syncRequest(for: account, retention: retention, at: t) : nil
                if let request = sync, request.isFirst {
                    if firstSyncAccount == nil { firstSyncAccount = account.id } else { sync = nil }
                }
                let prefix = "\(account.id.uuidString):"
                return (
                    account: account,
                    provider: provider(for: account),
                    userId: userIds[account.id],
                    coAuthorRevisions: state.coAuthors.filter { $0.key.hasPrefix(prefix) }.mapValues(\.revision),
                    checkRequest: CheckRequest(
                        isEnabled: fetchChecks,
                        includeOwn: checksForOwnPullRequests,
                        known: state.checks.filter { $0.key.hasPrefix(prefix) },
                        at: t
                    ),
                    tagRepos: TagRepos(
                        account: account,
                        seeded: Set(state.tagSeeded.keys.filter { $0.hasPrefix(prefix) }.map { String($0.dropFirst(prefix.count)) }),
                        fingerprints: Dictionary(uniqueKeysWithValues: state.tagFingerprints
                            .filter { $0.key.hasPrefix(prefix) }
                            .map { (String($0.key.dropFirst(prefix.count)), $0.value) })
                    ),
                    fetchTags: tagsDue && (account.followsTagsByDefault || !account.tagRepos.isEmpty),
                    sync: sync
                )
            }
        // Markeer vóór de eerste suspensie, zodat overlappende poll()-aanroepen deze accounts overslaan.
        for job in jobs { inFlight.insert(job.account.id) }
        let jobsById = Dictionary(uniqueKeysWithValues: jobs.map { ($0.account.id, $0) })
        var report = PollProgress(
            done: 0, total: jobs.count,
            firstSyncAccount: jobs.first { $0.sync?.isFirst == true }?.account.displayName
        )
        if !jobs.isEmpty { await progress?(report) }

        var result = PollResult()
        var succeeded: [UUID] = []
        await withTaskGroup(of: (UUID, Result<Fetched, ProviderError>).self) { group in
            for job in jobs {
                group.addTask {
                    (job.account.id, await Self.fetch(
                        job.provider,
                        knownUserId: job.userId,
                        coAuthorRevisions: job.coAuthorRevisions,
                        checkRequest: job.checkRequest,
                        tagRepos: job.tagRepos,
                        fetchTags: job.fetchTags,
                        sync: job.sync
                    ))
                }
            }
            // Pas elk resultaat direct toe zodra het binnenkomt (actor-geïsoleerd).
            for await (id, outcome) in group {
                guard let job = jobsById[id] else { continue }
                switch outcome {
                case .success(let fetched):
                    let checks = handleChecks(fetched, includeOwn: checksForOwnPullRequests, at: t)
                    result.checks.merge(checks.all) { _, new in new }
                    result.failedChecks += checks.failed
                    // Een PR waarvan de rij niet te lezen was houdt in de geschiedenis wat hij had.
                    for pr in fetched.pullRequests where !fetched.unreadMergeQueues.contains(pr.dedupKey) {
                        result.mergeQueues[pr.dedupKey] = .some(pr.mergeQueue)
                    }
                    var left = handleQueues(job.account, fetched, at: t)
                    if !left.isEmpty {
                        let exits = await job.provider.mergeQueueExits(of: left)
                        left = left.compactMap { pr in
                            guard !exits.notLeft.contains(pr.dedupKey) else { return nil }
                            let reason = exits.reasons[pr.dedupKey]
                            var pr = pr
                            pr.leftQueue?.reason = reason
                            return pr
                        }
                        result.leftQueue += left
                    }
                    let fresh = handleSuccess(job.account, fetched, retention: retention, at: t, interval: interval)
                    result.newPullRequests += fresh.pullRequests
                    result.quietPullRequests += fresh.quiet
                    result.newTags += fresh.tags
                    result.updatedTags += fresh.updated
                    result.syncedTags += fresh.backfill
                    if fetched.tags != nil { result.tagRepos[id] = fetched.tagRepos }
                    let sync = handleSync(job.account, fetched, request: job.sync, retention: retention, at: t)
                    result.syncedPullRequests += sync.pullRequests
                    result.completedPullRequests += sync.completed
                    succeeded.append(id)
                case .failure(let error):
                    if await handleFailure(job.account, job.provider, error, at: t, interval: interval) {
                        result.authFailures.append(id)
                    }
                }
                inFlight.remove(id)
                if firstSyncAccount == id { firstSyncAccount = nil }
                report.done += 1
                await progress?(report)
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
        result.updatedTags.sort { ($0.repo, $0.name) < ($1.repo, $1.name) }
        result.syncedTags.sort { ($0.createdAt ?? .distantPast) > ($1.createdAt ?? .distantPast) }
        result.completedPullRequests.sort { ($0.closedAt ?? .distantPast) < ($1.closedAt ?? .distantPast) }
        result.failedChecks.sort { $0.createdAt < $1.createdAt }
        result.leftQueue.sort { $0.createdAt < $1.createdAt }
        result.statuses = Dictionary(uniqueKeysWithValues: accounts.map { ($0.id, statuses[$0.id] ?? .idle) })
        return result
    }


    /// Vervolg-sync vanaf de vorige sync (min overlap), mits de sync-relevante filtersettings en
    /// de bewaartermijn ongewijzigd zijn; anders een eerste sync over de hele bewaartermijn.
    private func syncRequest(for account: Account, retention: HistoryRetention, at t: Date) -> SyncRequest {
        if let mark = state.syncMarks[account.id.uuidString],
           mark.settings.sameSyncScope(as: account.filterSettings), mark.retention == retention {
            return SyncRequest(since: mark.at - Self.syncOverlap, isFirst: false)
        }
        return SyncRequest(since: retention.maxAge.map { t - $0 }, isFirst: true)
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
        state.syncMarks = state.syncMarks.filter { keys.contains($0.key) }
        resyncBackup = resyncBackup.filter { keys.contains($0.key) }
        state.retain(onlyKeyPrefixes: keys.map { "\($0):" })
    }

    /// Bewaart de opgehaalde checks en geeft ze terug voor de geschiedenis, met de eigen open
    /// PR's waarvan de checks net rood werden: van lopend of groen naar mislukt, of mislukt op
    /// een nieuwe commit. Een PR waarvan de checks nog nooit opgehaald waren meldt niet, zodat de
    /// eerste poll na het aanzetten stil blijft.
    private func handleChecks(
        _ fetched: Fetched,
        includeOwn: Bool,
        at t: Date
    ) -> (all: [String: PRChecks], failed: [PullRequest]) {
        var all: [String: PRChecks] = [:]
        var failed: [PullRequest] = []
        let open = Dictionary(fetched.pullRequests.map { ($0.dedupKey, $0) }, uniquingKeysWith: { first, _ in first })
        for (key, found) in fetched.checks {
            let previous = state.checks[key]
            state.checks[key] = CheckMark(revision: found.revision, checks: found.checks, fetchedAt: t, at: t)
            all[key] = found.checks
            guard includeOwn, found.checks.state == .failed, let previous,
                  previous.checks.state != .failed || previous.revision != found.revision,
                  var pr = open[key], Self.isOwn(pr, userId: fetched.userId) else { continue }
            pr.checks = found.checks
            failed.append(pr)
        }
        for pr in fetched.pullRequests + (fetched.synced ?? []) {
            state.checks[pr.dedupKey]?.at = t
        }
        return (all, failed)
    }

    /// Onthoudt welke open PR's in de rij staan en geeft de PR's die sinds de vorige poll uit de
    /// rij gingen zonder te mergen: de vorige poll zag hem in de rij, nu is hij open, geen draft
    /// en niet in de rij, en de lijst toont hem (`PRFilter`). Een PR die niet meer in de open
    /// lijst staat is gemerged of gesloten: die meldt nooit (dat doet de melding Gemerged) en zijn
    /// stand gaat weg. Een PR waarvan de rij niet te lezen was (`unreadMergeQueues`) houdt zijn
    /// vorige stand. Zonder vorige stand (nieuw, of de eerste poll na een update) meldt niets.
    private func handleQueues(_ account: Account, _ fetched: Fetched, at t: Date) -> [PullRequest] {
        let prefix = "\(account.id.uuidString):"
        let open = Set(fetched.pullRequests.map(\.dedupKey))
        state.queued = state.queued.filter { !$0.key.hasPrefix(prefix) || open.contains($0.key) }
        var left: [PullRequest] = []
        for pr in fetched.pullRequests {
            let key = pr.dedupKey
            if fetched.unreadMergeQueues.contains(key) {
                state.queued[key]?.at = t
                continue
            }
            let previous = state.queued[key]
            if pr.state == .open, !pr.isDraft, let entry = pr.mergeQueue {
                state.queued[key] = QueueMark(kind: entry.kind, at: t)
                continue
            }
            state.queued[key] = nil
            guard let previous, pr.state == .open, !pr.isDraft else { continue }
            var shown = withDetails(pr)
            guard PRFilter.passes(shown, settings: account.filterSettings, currentUserId: fetched.userId) else { continue }
            shown.leftQueue = MergeQueueExit(kind: previous.kind, at: t)
            left.append(shown)
        }
        return left
    }

    private func handleSuccess(
        _ account: Account,
        _ fetched: Fetched,
        retention: HistoryRetention,
        at t: Date,
        interval: TimeInterval
    ) -> (pullRequests: [PullRequest], quiet: [PullRequest], tags: [Tag], updated: [Tag], backfill: [Tag]) {
        let settings = account.filterSettings
        let key = account.id.uuidString
        let previous = state.lastSettings[key].flatMap { $0.sameSource(as: settings) ? $0 : nil }
        for (dedupKey, found) in fetched.coAuthors {
            state.coAuthors[dedupKey] = CoAuthorMark(revision: found.revision, people: found.people, at: t)
        }
        for pr in fetched.pullRequests + (fetched.synced ?? []) {
            state.coAuthors[pr.dedupKey]?.at = t
        }

        var fresh: [PullRequest] = []
        var quiet: [PullRequest] = []
        for pr in fetched.pullRequests.map(withDetails)
        where PRFilter.passes(pr, settings: settings, currentUserId: fetched.userId) {
            // Een draft zonder melding komt gelezen in de lijst en wordt niet als gezien
            // gemarkeerd: is hij later klaar voor review, dan meldt hij als nieuwe PR.
            guard PRFilter.notifies(pr, settings: settings) else {
                quiet.append(pr)
                continue
            }
            // Alleen melden als de PR onder de vorige settings ook gemeld zou zijn; anders meldt
            // hij pas door een instellingswijziging of eerste poll → stil seeden.
            if !state.contains(pr.dedupKey), let previous, previous.covers(repo: pr.repo),
               PRFilter.passes(pr, settings: previous, currentUserId: fetched.userId),
               PRFilter.notifies(pr, settings: previous) {
                fresh.append(pr)
            }
            state.mark(pr.dedupKey, at: t)
        }

        state.lastSettings[key] = settings
        userIds[account.id] = fetched.userId
        let previousSchedule = schedules[account.id] ?? Schedule()
        var schedule = Schedule(
            nextDue: t + interval,
            nextTagDue: previousSchedule.nextTagDue,
            nextSyncDue: previousSchedule.nextSyncDue
        )
        if fetched.tags != nil || fetched.tagError != nil {
            schedule.nextTagDue = t + Self.tagInterval
        }
        if let tagError = fetched.tagError {
            logger.warning("tags ophalen mislukt voor \(account.displayName): \(tagError.userMessage)")
        }
        schedules[account.id] = schedule
        statuses[account.id] = .ok(lastPoll: t)
        let tags = handleTags(account, fetched, notBefore: retention.maxAge.map { t - $0 }, at: t)
        return (fresh, quiet, tags.fresh, tags.updated, tags.backfill)
    }

    /// Verwerkt de geschiedenis-sync: plant de volgende sync en geeft de gefilterde PR's terug,
    /// plus de PR's die sinds de vorige sync gemerged zijn (zie `completed`). Markeert geen
    /// PR-dedupKeys in `seen`; meldingen van nieuwe PR's blijven bij de open-PR-poll.
    private func handleSync(
        _ account: Account,
        _ fetched: Fetched,
        request: SyncRequest?,
        retention: HistoryRetention,
        at t: Date
    ) -> (pullRequests: [PullRequest], completed: [PullRequest]) {
        var schedule = schedules[account.id] ?? Schedule()
        defer { schedules[account.id] = schedule }

        if let error = fetched.syncError {
            // `syncMarks` ongemoeid: na een mislukte eerste sync volgt weer een eerste sync.
            if case .rateLimited(let until) = error {
                schedule.nextSyncDue = min(until, t + Self.maxRateLimitWait)
            } else {
                schedule.nextSyncDue = t + Self.tagInterval
            }
            logger.warning("geschiedenis-sync mislukt voor \(account.displayName): \(error.userMessage)")
            return ([], [])
        }
        guard let synced = fetched.synced else { return ([], []) }

        let settings = account.filterSettings
        // Een eerste sync seedt stil: dan is er geen vorige sync om tegen te vergelijken.
        let previous = request?.isFirst == false ? state.syncMarks[account.id.uuidString] : nil
        let newlyCompleted = completed(account, synced, previous: previous, userId: fetched.userId, at: t)
        state.syncMarks[account.id.uuidString] = SyncMark(at: t, settings: settings, retention: retention)
        resyncBackup[account.id.uuidString] = nil
        schedule.nextSyncDue = t + Self.tagInterval
        return (
            synced.filter { PRFilter.passes($0, settings: settings, currentUserId: fetched.userId) }.map(withDetails),
            newlyCompleted.map(withDetails)
        )
    }

    /// De PR met de bewaarde co-auteurs en checks erbij, als die er zijn. Checks van een oudere
    /// revisie horen niet meer bij deze PR en blijven weg.
    private func withDetails(_ pr: PullRequest) -> PullRequest {
        var pr = pr
        if let people = state.coAuthors[pr.dedupKey]?.people, !people.isEmpty {
            pr.coAuthors = people
        }
        if let mark = state.checks[pr.dedupKey], mark.revision == pr.revision {
            pr.checks = mark.checks
        }
        return pr
    }

    /// Gemergde PR's in repo's met "Completed" aan die gemeld moeten worden: de repo had het ook
    /// al bij de vorige sync aan (aanzetten seedt stil), de merge is van na die sync (min overlap)
    /// en de PR is nog niet gemeld. Alle gemergde PR's worden als gezien gemarkeerd.
    private func completed(
        _ account: Account,
        _ synced: [PullRequest],
        previous: SyncMark?,
        userId: String,
        at t: Date
    ) -> [PullRequest] {
        let settings = account.filterSettings
        var fresh: [PullRequest] = []
        for pr in synced where pr.state == .merged
            && PRFilter.passes(pr, settings: settings, currentUserId: userId, watching: \.completed) {
            let key = pr.dedupKey + ":completed"
            if let previous, !state.contains(key), previous.settings.covers(repo: pr.repo),
               PRFilter.passes(pr, settings: previous.settings, currentUserId: userId, watching: \.completed),
               let closedAt = pr.closedAt, closedAt >= previous.at - Self.syncOverlap {
                fresh.append(pr)
            }
            state.mark(key, at: t)
        }
        return fresh
    }

    /// Eerste tag-poll per repo meldt niets: de bestaande tags met een datum vanaf `notBefore`
    /// (de bewaartermijn) gaan als `backfill` stil de geschiedenis in. Daarna wordt elke
    /// onbekende tag gemeld, en een bekende tag die een release krijgt ook (één keer). Releases
    /// die er al waren toen een repo voor het eerst met vingerafdruk opgehaald werd (de eerste
    /// poll na een update) gaan stil. Bekende tags komen in `updated`, voor auteur en release in
    /// de geschiedenis.
    private func handleTags(
        _ account: Account,
        _ fetched: Fetched,
        notBefore: Date?,
        at t: Date
    ) -> (fresh: [Tag], updated: [Tag], backfill: [Tag]) {
        // Mislukte tag-fetch: tag-state ongemoeid laten tot de volgende tag-poll.
        guard fetched.tagError == nil else { return ([], [], []) }
        let prefix = "\(account.id.uuidString):"
        // Repo's waarvan tags uit staan vergeten, zodat weer aanzetten opnieuw stil seedt.
        let wantedKeys = Set(fetched.tagRepos.map { prefix + $0.lowercased() })
        state.tagSeeded = state.tagSeeded.filter { !$0.key.hasPrefix(prefix) || wantedKeys.contains($0.key) }
        state.dropOrphanFingerprints()

        guard let tags = fetched.tags else { return ([], [], []) }
        let tagsByRepo = Dictionary(grouping: tags) { $0.repo.lowercased() }
        let datedByRepo = Dictionary(grouping: fetched.backfillTags) { $0.repo.lowercased() }
        if !fetched.unavailableTagRepos.isEmpty {
            logger.warning("tags overgeslagen voor \(account.displayName): \(fetched.unavailableTagRepos.sorted().joined(separator: ", ")) (niet gevonden of geen toegang)")
        }
        var fresh: [Tag] = []
        var updated: [Tag] = []
        var backfill: [Tag] = []
        // Onbereikbare repo's niet als geseed markeren of verversen: anders worden hun bestaande
        // tags als nieuw gemeld zodra de toegang terugkomt.
        for repo in Set(fetched.tagRepos.map { $0.lowercased() }).subtracting(fetched.unavailableTagRepos) {
            let seededKey = prefix + repo
            let isSeeded = state.tagSeeded[seededKey] != nil
            if isSeeded, fetched.unchangedTagRepos.contains(repo) {
                state.refreshTags(ofRepo: seededKey, at: t)
                state.tagSeeded[seededKey] = t
                continue
            }
            let knowsReleases = state.tagFingerprints[seededKey] != nil
            for tag in tagsByRepo[repo] ?? [] {
                let releaseKey = tag.dedupKey + ":release"
                if isSeeded, !state.contains(tag.dedupKey) {
                    fresh.append(tag)
                } else if isSeeded, knowsReleases, tag.release != nil, !state.contains(releaseKey) {
                    fresh.append(tag) // de tag was er al, de release is nieuw
                } else if isSeeded {
                    updated.append(tag)
                }
                state.mark(tag.dedupKey, at: t)
                if tag.release != nil { state.mark(releaseKey, at: t) }
            }
            // Ook tags buiten wat de provider teruggaf (bv. voorbij de nieuwste honderd) blijven gezien.
            state.refreshTags(ofRepo: seededKey, at: t)
            state.tagFingerprints[seededKey] = fetched.tagFingerprints[repo]
            if !isSeeded {
                for tag in datedByRepo[repo] ?? [] {
                    guard let date = tag.createdAt, notBefore.map({ date >= $0 }) ?? true else { continue }
                    backfill.append(tag)
                    state.mark(tag.dedupKey, at: t)
                    if tag.release != nil { state.mark(tag.dedupKey + ":release", at: t) }
                }
            }
            state.tagSeeded[seededKey] = t
        }
        return (fresh, updated, backfill)
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
        logger.warning("poll mislukt voor \(account.displayName): \(error.userMessage)")

        guard error == .unauthorized else { return false }
        userIds[account.id] = nil
        await provider.invalidateCredentials()
        return !wasUnauthorized
    }
}
