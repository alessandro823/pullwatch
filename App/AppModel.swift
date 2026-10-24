import AppKit
import Observation
import os
import PullwatchCore

private let logger = Logger(subsystem: "nl.torrisi.pullwatch", category: "app")

@MainActor
@Observable
final class AppModel {
    static let shared = AppModel()

    private(set) var config: AppConfig
    private(set) var history: History
    private(set) var statuses: [UUID: AccountState] = [:]
    private(set) var notificationsAllowed = true
    /// Voortgang van "Opnieuw ophalen"; `nil` als er niets loopt.
    private(set) var refetch: RefetchProgress?
    private(set) var versionReport: VersionReport?
    /// Voortgang van "Versies checken" (gescande repo's, totaal); `nil` als er niets loopt.
    private(set) var versionCheck: (done: Int, total: Int)?
    /// Repo's (`RepoVersions.id`) die nu los opnieuw gecheckt worden.
    private(set) var refreshingRepos: Set<String> = []

    struct RefetchProgress: Equatable {
        let startedAt: Date
        var done: Int
        let total: Int
    }

    @ObservationIgnored private let configStore = JSONFileStore<AppConfig>(url: AppPaths.file("config.json"))
    @ObservationIgnored private let historyStore = JSONFileStore<History>(url: AppPaths.file("history.json"))
    @ObservationIgnored private let legacyRecentStore = JSONFileStore<RecentList>(url: AppPaths.file("recent.json"))
    @ObservationIgnored private let versionStore = JSONFileStore<VersionReport>(url: AppPaths.file("versions.json"))
    @ObservationIgnored private let secrets = KeychainStore()
    @ObservationIgnored private let engine = PollEngine(
        makeProvider: { ProviderFactory.make($0) },
        store: JSONFileStore<SeenState>(url: AppPaths.file("seen.json"))
    )
    @ObservationIgnored private let notifier = Notifier.shared
    @ObservationIgnored private var loopTask: Task<Void, Never>?
    /// Vroegste moment voor de volgende automatische versiecheck (na een mislukte of lopende poging).
    @ObservationIgnored private var nextAutoVersionAttempt: Date?

    private init() {
        do {
            config = try configStore.load() ?? AppConfig()
        } catch {
            logger.error("config onleesbaar: \(error.localizedDescription)")
            config = AppConfig()
        }

        var stored: History?
        var storedUnreadable = false
        do {
            stored = try historyStore.load()
        } catch {
            logger.error("history onleesbaar, start leeg: \(error.localizedDescription)")
            storedUnreadable = true
            Self.moveAside(historyStore.url)
        }
        var legacy: RecentList?
        if !storedUnreadable {
            do {
                legacy = try legacyRecentStore.load()
            } catch {
                logger.error("recent.json onleesbaar, niet gemigreerd: \(error.localizedDescription)")
            }
        }
        // recent.json blijft staan na migratie.
        let initial = History.initial(stored: stored, storedUnreadable: storedUnreadable, legacy: legacy)
        history = initial.history
        var needsSave = initial.needsSave
        if history.prune(now: Date(), retention: config.historyRetention) { needsSave = true }
        if needsSave { saveHistory() }

        do {
            versionReport = try versionStore.load()
        } catch {
            logger.error("versions.json onleesbaar, start leeg: \(error.localizedDescription)")
        }
    }

    /// Zet een onleesbaar bestand opzij als `<naam>.corrupt-<unix-tijd>`, zodat het niet overschreven wordt.
    private static func moveAside(_ url: URL) {
        let timestamp = Int(Date().timeIntervalSince1970)
        let target = url.deletingLastPathComponent().appending(path: "\(url.lastPathComponent).corrupt-\(timestamp)")
        do {
            try FileManager.default.moveItem(at: url, to: target)
            logger.notice("onleesbaar bestand bewaard als \(target.lastPathComponent, privacy: .public)")
        } catch {
            logger.error("opzij zetten van \(url.lastPathComponent, privacy: .public) mislukt: \(error.localizedDescription)")
        }
    }

    var menuBarSymbol: String {
        let hasError = statuses.values.contains { if case .failed = $0 { true } else { false } }
        return hasError ? "exclamationmark.triangle" : "arrow.triangle.pull"
    }

    func start() {
        guard loopTask == nil else { return }
        notifier.onOpen = { [weak self] key in self?.markRead(key) }

        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            // Wi-Fi is vlak na het ontwaken nog niet terug; wacht om een vals "Netwerkfout" te voorkomen.
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(10))
                await self?.refreshNow()
            }
        }

        Task { [weak self] in
            guard let self else { return }
            self.notificationsAllowed = await self.notifier.requestAuthorization()
        }

        loopTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                await self.tick()
                self.startAutoVersionCheckIfDue()
                try? await Task.sleep(for: .seconds(15))
            }
        }
    }

    /// Haalt de geschiedenis van alle accounts opnieuw op (stil, gelezen-status blijft).
    func refetchHistory() async {
        let total = config.pollableAccounts.count
        guard total > 0 else { return }
        refetch = RefetchProgress(startedAt: Date(), done: 0, total: total)
        await engine.resetHistorySync()
        await tick()
    }

    /// Eens per dag (`VersionReport.autoInterval`) vanzelf, als de instelling aan staat.
    private func startAutoVersionCheckIfDue() {
        guard config.autoVersionCheck, versionCheck == nil, !config.pollableAccounts.isEmpty else { return }
        let now = Date()
        if let nextAutoVersionAttempt, now < nextAutoVersionAttempt { return }
        if let last = versionReport?.checkedAt, now.timeIntervalSince(last) < VersionReport.autoInterval { return }
        nextAutoVersionAttempt = now + VersionReport.autoRetryInterval
        Task { await checkVersions(automatic: true) }
    }

    /// Leest per gevolgde repo de taal- en frameworkversies, vergelijkt ze met endoflife.date en zoekt CVE's.
    /// Automatisch: een volledig mislukte check (bv. offline) overschrijft het vorige resultaat niet,
    /// en nieuwe CVE's ten opzichte van de vorige check geven een melding.
    func checkVersions(automatic: Bool = false) async {
        guard versionCheck == nil else { return }
        versionCheck = (0, 0)
        let checker = VersionChecker(makeProvider: { ProviderFactory.make($0) })
        let report = await checker.run(accounts: config.pollableAccounts) { done, total in
            await MainActor.run { [weak self] in self?.versionCheck = (done, total) }
        }
        versionCheck = nil
        if automatic && report.failedCompletely {
            logger.notice("automatische versiecheck mislukt, opnieuw over een uur")
            return
        }
        let previous = versionReport
        versionReport = report
        if automatic {
            let new = report.newVulnerabilities(since: previous)
            if !new.isEmpty { notifier.deliverVulnerabilities(new) }
        }
        do {
            try versionStore.save(report)
        } catch {
            logger.error("versions opslaan mislukt: \(error.localizedDescription)")
        }
    }

    /// Checkt één repo opnieuw en vervangt alleen die regel; geen meldingen.
    func refreshVersions(of repo: RepoVersions) async {
        guard versionCheck == nil, !refreshingRepos.contains(repo.id),
              let account = config.accounts.first(where: { $0.id == repo.accountId }) else { return }
        refreshingRepos.insert(repo.id)
        let fresh = await VersionChecker(makeProvider: { ProviderFactory.make($0) }).run(account: account, repo: repo.repo)
        refreshingRepos.remove(repo.id)
        guard let report = versionReport else { return }
        versionReport = report.replacing(fresh)
        do {
            try versionStore.save(versionReport!)
        } catch {
            logger.error("versions opslaan mislukt: \(error.localizedDescription)")
        }
    }

    private func updateRefetchProgress() async {
        guard var progress = refetch else { return }
        let ids = config.pollableAccounts.map(\.id)
        let synced = await engine.lastHistorySync(for: ids)
        progress.done = synced.values.filter { $0 >= progress.startedAt }.count
        refetch = progress.done >= progress.total ? nil : progress
    }

    func refreshNow() async {
        await engine.forceRefresh()
        await tick()
    }

    func open(_ item: HistoryItem) {
        NSWorkspace.shared.open(item.entry.webURL)
        markRead(item.id)
    }

    func markRead(_ key: String) {
        history.markRead(key)
        saveHistory()
    }

    func markAllRead() {
        history.markAllRead()
        saveHistory()
    }

    /// Returns false (and changes nothing) when the PAT could not be written to the Keychain.
    @discardableResult
    func saveAccount(_ account: Account, pat: String?) -> Bool {
        if account.authMethod == .cli {
            try? secrets.delete(account: account.id.uuidString)
        } else if let pat, !pat.isEmpty {
            do {
                try secrets.write(pat, account: account.id.uuidString)
            } catch {
                logger.error("PAT opslaan mislukt: \(error.localizedDescription)")
                return false
            }
        }
        if let index = config.accounts.firstIndex(where: { $0.id == account.id }) {
            config.accounts[index] = account
        } else {
            config.accounts.append(account)
        }
        saveConfig()
        Task { await refreshNow() }
        return true
    }

    func removeAccount(_ id: UUID) {
        try? secrets.delete(account: id.uuidString)
        config.accounts.removeAll { $0.id == id }
        history.removeAccount(id)
        statuses[id] = nil
        saveConfig()
        saveHistory()
    }

    func hasStoredPAT(_ id: UUID) -> Bool {
        (try? secrets.read(account: id.uuidString)) != nil
    }

    func setPollInterval(_ seconds: Int) {
        config.pollInterval = seconds
        saveConfig()
        Task { await refreshNow() }
    }

    func setAutoVersionCheck(_ enabled: Bool) {
        config.autoVersionCheck = enabled
        saveConfig()
    }

    func setHistoryRetention(_ retention: HistoryRetention) {
        config.historyRetention = retention
        saveConfig()
        if history.prune(now: Date(), retention: retention) { saveHistory() }
    }

    private func tick() async {
        notificationsAllowed = await notifier.isAuthorized()
        let result = await engine.poll(
            accounts: config.pollableAccounts,
            interval: TimeInterval(config.clampedInterval),
            retention: config.historyRetention
        )
        statuses = result.statuses

        let now = Date()
        var changed = false
        let hasNotified = !result.newPullRequests.isEmpty || !result.newTags.isEmpty
        if hasNotified {
            history.add(pullRequests: result.newPullRequests, tags: result.newTags, at: now)
            changed = true
        }
        // Na add: een gemelde PR staat dan al ongelezen in de geschiedenis en blijft dat.
        // PR's van vóór de bewaartermijn niet toevoegen: die zou prune meteen weer verwijderen.
        let cutoff = config.historyRetention.maxAge.map { now - $0 }
        if history.merge(synced: result.syncedPullRequests, notBefore: cutoff) { changed = true }
        if history.prune(now: now, retention: config.historyRetention) { changed = true }
        if changed { saveHistory() }
        if hasNotified || !result.completedPullRequests.isEmpty {
            notifier.deliver(NotificationPlanner.plan(
                pullRequests: result.newPullRequests,
                tags: result.newTags,
                completed: result.completedPullRequests
            ))
        }
        for id in result.authFailures {
            if let account = config.accounts.first(where: { $0.id == id }) {
                notifier.deliverAuthFailure(accountName: account.displayName)
            }
        }
        await updateRefetchProgress()
    }

    private func saveConfig() {
        do {
            try configStore.save(config)
        } catch {
            logger.error("config opslaan mislukt: \(error.localizedDescription)")
        }
    }

    private func saveHistory() {
        do {
            try historyStore.save(history)
        } catch {
            logger.error("history opslaan mislukt: \(error.localizedDescription)")
        }
    }
}
