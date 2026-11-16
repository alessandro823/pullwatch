import Foundation
import Observation
import PullwatchCore

/// Het ophalen van PR's en tags: één poll (`tick`, met daarna de branches) met zijn voortgang en de status per account,
/// "Opnieuw ophalen" van de geschiedenis, en de eerste sync van nieuwe accounts. Wat een poll
/// vond gaat naar de geschiedenis, de meldingen en de versiecheck.
@Observable
final class PollingModel {
    private(set) var statuses: [UUID: AccountState] = [:]
    /// Voortgang van "Opnieuw ophalen"; `nil` als er niets loopt.
    private(set) var refetch: RefetchProgress?
    /// Voortgang van de poll die nu loopt; nil tussen twee polls.
    private(set) var pollProgress: PollProgress?
    /// Accounts waarvan de eerste geschiedenis-sync nog moet komen (hun lijsten zijn nog leeg).
    private(set) var pendingFirstSync: Set<UUID> = []
    /// Nog geen poll afgerond sinds de start: lege lijsten zeggen dan "ophalen" in plaats van "nog geen".
    private(set) var hasPolledOnce = false
    /// Laatste poll waarin minstens één account slaagde.
    private(set) var lastSuccessfulPoll: Date?
    /// Per account de gevolgde repo's die het token niet kan lezen, uit de laatste tag- en
    /// branch-poll (`PollEngine.unreachableRepos()`); hun tags en branches worden niet bijgewerkt.
    private(set) var unreachableRepos: [UUID: UnreachableRepos] = [:]
    /// Wanneer de branches het laatst zonder fout opgehaald werden (`PollEngine.lastBranchCheck()`),
    /// voor "Gecheckt …" in Branches.
    private(set) var branchesCheckedAt: Date?
    /// Een poll op verzoek loopt (`refresh()`): de knop Laad opnieuw wacht dan.
    private(set) var isRefreshing = false

    struct RefetchProgress: Equatable {
        let startedAt: Date
        var done: Int
        let total: Int
    }

    /// Lopende `tick()`s; de voortgang gaat pas weg als de laatste klaar is.
    @ObservationIgnored private var activePolls = 0
    @ObservationIgnored private var refreshSoon: Task<Void, Never>?
    /// Een poll op verzoek (menu, ⌘R, een gewijzigde repo); één tegelijk. Een verzoek terwijl
    /// hij loopt geeft daarna nog één poll, zodat een wijziging van net niet gemist wordt.
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var refreshAgain = false
    /// "Opnieuw ophalen" en het stoppen ervan.
    @ObservationIgnored private var refetchTask: Task<Void, Never>?
    @ObservationIgnored private var refetchCancelTask: Task<Void, Never>?
    @ObservationIgnored private let services: AppServices
    @ObservationIgnored private let accounts: AccountsModel
    @ObservationIgnored private let history: HistoryModel
    @ObservationIgnored private let branches: BranchesModel
    @ObservationIgnored private let versions: VersionsModel
    @ObservationIgnored private let notifications: NotificationsModel

    init(
        services: AppServices, accounts: AccountsModel, history: HistoryModel,
        branches: BranchesModel, versions: VersionsModel, notifications: NotificationsModel
    ) {
        self.services = services
        self.accounts = accounts
        self.history = history
        self.branches = branches
        self.versions = versions
        self.notifications = notifications
    }

    private var config: AppConfig { accounts.config }
    private var engine: PollEngine { services.engine }

    // MARK: - Status

    /// Een account kon niet gepold worden: de menubalk toont dan een waarschuwing.
    var hasPollError: Bool {
        statuses.values.contains { if case .failed = $0 { true } else { false } }
    }

    /// Lijsten van PR's en tags vullen zich nog: eerste start, eerste sync of opnieuw ophalen.
    var isFillingHistory: Bool {
        guard !config.pollableAccounts.isEmpty else { return false }
        return !hasPolledOnce || !pendingFirstSync.isEmpty || refetch != nil
    }

    /// Naam van het account waarvan de geschiedenis nu (of als eerste) opgehaald wordt.
    var fillingAccountName: String? {
        if let name = pollProgress?.firstSyncAccount { return name }
        let id = pendingFirstSync.first ?? config.pollableAccounts.first?.id
        return config.accounts.first { $0.id == id }?.displayName
    }

    /// Melding van het eerste account waarvan de laatste poll mislukte.
    var pollFailure: String? {
        for account in config.accounts {
            if case .failed(let error, _) = statuses[account.id] {
                return String(localized: "\(account.displayName): \(error.userMessage)", comment: "Accountnaam, foutmelding")
            }
        }
        return nil
    }

    /// Een weggehaald account heeft geen status meer.
    func removeStatus(of id: UUID) {
        statuses[id] = nil
        unreachableRepos[id] = nil
    }

    // MARK: - Pollen

    func refreshNow() async {
        await engine.forceRefresh()
        await tick()
    }

    /// Pollt meteen, buiten de vaste ronde om.
    func refresh() {
        guard refreshTask == nil else {
            refreshAgain = true
            return
        }
        isRefreshing = true
        refreshTask = Task {
            defer {
                refreshTask = nil
                isRefreshing = false
            }
            repeat {
                refreshAgain = false
                await refreshNow()
            } while refreshAgain && !Task.isCancelled
        }
    }

    /// Opnieuw pollen kort na de laatste wijziging, niet bij elke klik.
    func scheduleRefresh() {
        refreshSoon?.cancel()
        refreshSoon = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            await self?.refreshNow()
        }
    }

    /// Haalt de geschiedenis van alle accounts opnieuw op (stil, gelezen-status blijft).
    func startRefetch() {
        let total = config.pollableAccounts.count
        guard total > 0, refetchTask == nil else { return }
        refetch = RefetchProgress(startedAt: Date(), done: 0, total: total)
        refetchTask = Task {
            defer { refetchTask = nil }
            await engine.resetHistorySync()
            await tick()
        }
    }

    /// Stopt "Opnieuw ophalen": accounts die nog niet aan de beurt waren houden hun oude
    /// geschiedenis-sync.
    func cancelRefetch() {
        refetch = nil
        guard refetchCancelTask == nil else { return }
        refetchCancelTask = Task {
            defer { refetchCancelTask = nil }
            await engine.cancelHistoryResync()
        }
    }

    func tick() async {
        // De boom van de vorige keer, ook na een start, voordat de poll hem bijwerkt.
        if branches.trees.isEmpty { branches.trees = await engine.branchTrees() }
        await notifications.refreshAuthorization()
        let accounts = config.pollableAccounts
        let retention = config.historyRetention
        await refreshPendingFirstSync()
        activePolls += 1
        let result = await engine.poll(
            accounts: accounts,
            interval: TimeInterval(config.clampedInterval),
            retention: retention,
            checksForOwnPullRequests: config.notifications.checksFailed,
            // Instellingen, Bronnen: met CI-checks uit vraagt de poll geen checks (en meldt dus ook geen mislukte).
            fetchChecks: config.isEnabled(.ciChecks),
            progress: { [weak self] progress in await self?.setPollProgress(progress) }
        )
        activePolls -= 1
        if activePolls == 0 { pollProgress = nil }
        hasPolledOnce = true
        statuses = result.statuses
        await refreshPendingFirstSync()
        if result.statuses.values.contains(where: { if case .ok = $0 { true } else { false } }) {
            lastSuccessfulPoll = Date()
        }

        history.apply(result, retention: config.historyRetention, now: Date())
        let builder = notifications.builder
        let plans = NotificationPlanner.plan(
            pullRequests: result.newPullRequests,
            tags: result.newTags,
            completed: result.completedPullRequests,
            failedChecks: result.failedChecks,
            leftQueue: result.leftQueue,
            settings: config.notifications,
            accounts: config.accounts
        )
        let notifier = services.notifier
        notifier.deliver(plans.map(builder.content(for:)))
        notifier.deliver(result.authFailures.compactMap { id in
            config.accounts.first { $0.id == id }.map(builder.authFailure)
        })
        await updateRefetchProgress()
        versions.startNewRepoVersionCheckIfNeeded(after: result)
        // Pas na de PR's en tags: een trage of mislukte branch-poll houdt die nooit op.
        let pushes = await engine.pollBranches(accounts: accounts, retention: config.historyRetention)
        branches.apply(pushes, retention: config.historyRetention, now: Date())
        branches.trees = await engine.branchTrees()
        unreachableRepos = await engine.unreachableRepos()
        branchesCheckedAt = await engine.lastBranchCheck()
    }

    private func updateRefetchProgress() async {
        guard var progress = refetch else { return }
        let ids = config.pollableAccounts.map(\.id)
        let synced = await engine.lastHistorySync(for: ids)
        progress.done = synced.values.filter { $0 >= progress.startedAt }.count
        refetch = progress.done >= progress.total ? nil : progress
    }

    /// Accounts die nog een eerste sync moeten doen. Een account dat nu faalt (bv. uitgelogd)
    /// telt niet mee: anders blijft de balk "ophalen" zeggen tot het weer werkt.
    private func refreshPendingFirstSync() async {
        let accounts = config.pollableAccounts.filter {
            if case .failed = statuses[$0.id] { false } else { true }
        }
        let pending = await engine.pendingFirstSync(accounts: accounts, retention: config.historyRetention)
        if pending != pendingFirstSync { pendingFirstSync = pending }
    }

    private func setPollProgress(_ progress: PollProgress) {
        pollProgress = progress
    }
}
