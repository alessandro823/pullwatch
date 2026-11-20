import AppKit
import Observation
import PullwatchCore
import PullwatchMCP

/// Log is Sendable; ook bruikbaar vanuit nonisolated callbacks.
nonisolated private let logger = Log(category: "app")

/// De samenstelling van de app: maakt de modellen met elk één taak een keer, verbindt ze, start
/// het pollen en regelt wat over meer modellen gaat (een account weghalen, een melding
/// openen, ⌘R). De toestand zelf staat in de modellen; dit model houdt er niets van bij.
@Observable
final class AppModel {
    static let shared = AppModel()

    @ObservationIgnored let services: AppServices
    @ObservationIgnored let accounts: AccountsModel
    @ObservationIgnored let historyModel: HistoryModel
    @ObservationIgnored let branchesModel: BranchesModel
    @ObservationIgnored let notifications: NotificationsModel
    @ObservationIgnored let versions: VersionsModel
    @ObservationIgnored let overview: OverviewModel
    @ObservationIgnored let polling: PollingModel
    @ObservationIgnored let updates: UpdatesModel
    @ObservationIgnored let router: AppRouter
    @ObservationIgnored let agents: AgentServer
    /// Wat de tools van agents lezen: de modellen hierboven.
    @ObservationIgnored let mcpDataSource: AppMCPDataSource

    @ObservationIgnored private var loopTask: Task<Void, Never>?
    @ObservationIgnored private var wakeTask: Task<Void, Never>?
    /// Klikken op meldingen, zolang de app draait.
    @ObservationIgnored private var responseTask: Task<Void, Never>?
    /// De vraag om meldingen bij het opstarten.
    @ObservationIgnored private var permissionTask: Task<Void, Never>?
    #if DEBUG
    @ObservationIgnored private var tourTask: Task<Void, Never>?
    #endif

    private init() {
        let services = AppServices()
        let accounts = AccountsModel(services: services)
        let history = HistoryModel(services: services, accounts: accounts)
        let branches = BranchesModel(store: services.branchStore)
        let notifications = NotificationsModel(services: services, accounts: accounts)
        let versions = VersionsModel(services: services, accounts: accounts, notifications: notifications)
        let overview = OverviewModel(accounts: accounts, history: history, versions: versions)
        self.services = services
        self.accounts = accounts
        historyModel = history
        branchesModel = branches
        self.notifications = notifications
        self.versions = versions
        self.overview = overview
        let polling = PollingModel(
            services: services, accounts: accounts, history: history, branches: branches, versions: versions,
            notifications: notifications
        )
        self.polling = polling
        updates = UpdatesModel(services: services, accounts: accounts, notifications: notifications)
        router = AppRouter()
        let dataSource = AppMCPDataSource(
            accounts: accounts, history: history, overview: overview, versions: versions, polling: polling,
            engine: services.engine,
            syncStatus: { AppModel.syncStatus(accounts: accounts, polling: polling, versions: versions, overview: overview) }
        )
        mcpDataSource = dataSource
        // De tools lezen de modellen hierboven; de server maakt ze pas als de socket opengaat.
        let agents = AgentServer(makeTools: { PullwatchMCPTools.all(dataSource: dataSource) })
        agents.load(approved: accounts.config.approvedAgents)
        self.agents = agents
        // Het overzicht volgt instellingen, geschiedenis en rapport, meteen bij elke wijziging.
        // Andere bronnen uit of een account erbij of eraf: eerst het getoonde rapport, dat dan zelf
        // het overzicht bijwerkt.
        accounts.didChangeConfig = { [weak accounts] in
            if !versions.configChanged() { overview.recomputeRepoSummaries() }
            guard let config = accounts?.config else { return }
            agents.load(approved: config.approvedAgents)
            // De socket volgt Instellingen, Agents, maar pas als de app gestart is.
            if agents.isEnabled { agents.apply(config.agentAccess) }
        }
        agents.onApprovalsChanged = { [weak accounts] approved in
            accounts?.edit { $0.approvedAgents = approved }
        }
        let notifier = services.notifier
        agents.onApprovalNeeded = { [weak notifications] clientName, displayName in
            guard let notifications else { return }
            notifier.deliver([notifications.builder.agentApproval(clientName: clientName, displayName: displayName)])
        }
        agents.onApprovalAnswered = { clientName in
            notifier.removeDelivered(identifiers: [NotificationContentBuilder.agentApprovalIdentifier(clientName)])
        }
        history.didChangeHistory = { overview.recomputeRepoSummaries() }
        versions.didChangeReport = { overview.recomputeRepoSummaries() }
        versions.didChangeSeenPackages = { overview.recomputeSidebar() }
    }

    /// De helper van een agent startte de app (`-PullwatchLaunchedByAgent YES`, stand Altijd):
    /// dan herstelt de app geen hoofdvenster, zodat het starten van een agent niets in beeld zet.
    nonisolated static var launchedByAgent: Bool {
        UserDefaults.standard.bool(forKey: PullwatchAppLocation.launchedByAgentArgument)
    }

    /// De app draait als host van de unit-tests: niet pollen, melden of vensters openen.
    nonisolated static var isTestHost: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    /// Alle netwerkverkeer van de app; in debug-builds met `-PullwatchFakeGitHub` een
    /// nagespeeld GitHub (`FakeGitHub`), zodat de UI-tests de hele inlog-flow doorlopen.
    nonisolated static let networking: any HTTPClient = {
        #if DEBUG
        if FakeGitHub.isEnabled { return FakeGitHub.shared }
        #endif
        return URLSessionHTTPClient()
    }()

    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    // MARK: - Starten

    func start() {
        guard loopTask == nil else { return }
        updates.start()
        let notifier = services.notifier
        notifier.registerCategories()
        responseTask = Task { [weak self] in
            for await response in notifier.responses {
                self?.handleNotification(response.action, response.payload)
            }
        }

        wakeTask = Task { [weak self] in
            for await _ in NSWorkspace.shared.notificationCenter.notifications(named: NSWorkspace.didWakeNotification) {
                // Wi-Fi is vlak na het ontwaken nog niet terug; wacht om een vals "Netwerkfout" te voorkomen.
                try? await Task.sleep(for: .seconds(10))
                await self?.polling.refreshNow()
            }
        }

        agents.isEnabled = true
        agents.apply(config.agentAccess)
        #if DEBUG
        FakeAgents.installIfRequested(in: agents)
        #endif

        let incomplete = accounts.incompleteAccounts
        for account in incomplete { removeAccount(account.id) }
        if !incomplete.isEmpty { logger.notice("\(incomplete.count) lege accounts verwijderd") }
        accounts.removeOrphanTokens()
        #if DEBUG
        accounts.installFakeTokens()
        #endif
        // Wie al een account heeft (ook van voor het welkomstvenster) krijgt het niet te zien.
        if !accounts.onboardingCompleted && !config.pollableAccounts.isEmpty { accounts.completeOnboarding() }
        // Bij een eerste start vraagt het welkomstvenster om meldingen, met uitleg erbij;
        // anders zoals altijd bij het opstarten (macOS vraagt het maar één keer).
        if !accounts.needsOnboarding {
            permissionTask = Task { [weak self] in await self?.notifications.requestNotifications() }
        }

        #if DEBUG
        tourTask = Task { [weak self] in
            if let self { await SnapshotTour.runIfRequested(self) }
        }
        #endif

        loopTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                await self.polling.tick()
                self.versions.startAutoVersionCheckIfDue()
                self.updates.startUpdateCheckIfDue()
                try? await Task.sleep(for: .seconds(15))
            }
        }
    }

    /// Bij een eerste start opent het welkomstvenster vanzelf; niet als host van de unit-tests.
    var opensOnboardingAtLaunch: Bool { accounts.needsOnboarding && !Self.isTestHost }

    private var config: AppConfig { accounts.config }

    // MARK: - Over meer modellen

    /// Eén status voor alles wat Pullwatch ophaalt: de balk onderin het hoofdvenster en de
    /// spinner in het menu lezen hem.
    var syncStatus: SyncStatus {
        Self.syncStatus(accounts: accounts, polling: polling, versions: versions, overview: overview)
    }

    /// `syncStatus` uit de modellen zelf, ook voor de tools van agents.
    static func syncStatus(accounts: AccountsModel, polling: PollingModel, versions: VersionsModel, overview: OverviewModel) -> SyncStatus {
        let refreshingRepos = versions.refreshingRepos
        let repoName = refreshingRepos.first.flatMap { id in overview.repoSummariesById[id]?.repo }
        return SyncStatus.current(
            poll: polling.pollProgress,
            firstSyncPending: !polling.pendingFirstSync.isEmpty && !accounts.config.pollableAccounts.isEmpty,
            refetch: polling.refetch.map { ($0.done, $0.total) },
            versions: versions.versionCheck.map { ($0.done, $0.total) },
            checkingRepo: refreshingRepos.isEmpty ? nil : (repoName ?? ""),
            failure: polling.pollFailure
        )
    }

    /// Stopt wat de balk onderin toont, als dat veilig kan: "Opnieuw ophalen" (accounts die nog
    /// niet aan de beurt waren houden hun oude geschiedenis-sync) of de versiecheck (repo's die al
    /// gecheckt zijn blijven).
    func cancelSync() {
        switch syncStatus.work {
        case .refetch:
            polling.cancelRefetch()
        case .versions:
            versions.cancelCheck()
        default:
            break
        }
    }

    /// ⌘R: de geopende repo opnieuw checken, in PR's, Tags, Branches en Statistieken pollen, anders alles checken.
    func refreshCurrent() {
        if case .repo(let id)? = router.path.last, let summary = overview.repoSummariesById[id] {
            versions.startRefresh(of: summary)
            return
        }
        switch router.mainSection {
        case .repos, .dependencies, .packages:
            versions.startCheck()
        case .pullRequests, .tags, .branches, .stats:
            polling.refresh()
        }
    }

    func showRepo(accountId: UUID, repo: String) {
        router.showRepo(id: overview.repoId(accountId: accountId, repo: repo))
    }

    func watchRepository() {
        guard !accounts.accountsForExtraRepos.isEmpty else { return }
        router.show(.main)
        router.isWatchingRepository = true
    }

    /// Volgen en meldingen van één repo, als binding voor de schakelaars op de repo-pagina.
    subscript(watch repo: String, account accountId: UUID) -> WatchSet {
        get { accounts.watch(repo: repo, accountId: accountId) }
        set { setWatch(newValue, repo: repo, accountId: accountId) }
    }

    /// Volgen en meldingen van één repo, direct opgeslagen; daarna meteen pollen.
    func setWatch(_ set: WatchSet, repo: String, accountId: UUID) {
        guard accounts.setWatch(set, repo: repo, accountId: accountId) else { return }
        polling.refresh()
    }

    /// Bewaart een account (`AccountsModel.saveAccount`) en pollt kort daarna.
    @discardableResult
    func saveAccount(_ account: Account, pat: String?) -> Bool {
        guard accounts.saveAccount(account, pat: pat) else { return false }
        historyModel.removeHiddenDrafts()
        polling.scheduleRefresh()
        return true
    }

    /// Een wijziging aan een bestaand account, meteen bewaard (Instellingen hebben geen Opslaan).
    func updateAccount(_ account: Account) {
        guard accounts.updateAccount(account) else { return }
        historyModel.removeHiddenDrafts()
        polling.scheduleRefresh()
    }

    /// Voegt een gecontroleerde losse repo toe aan een bewaard account en volgt er de PR's van.
    func addExtraRepository(_ check: RepositoryCheck, to accountId: UUID) {
        guard var account = config.accounts.first(where: { $0.id == accountId }) else { return }
        account.addExtraRepo(check.name)
        updateAccount(account)
    }

    func removeAccount(_ id: UUID) {
        accounts.removeAccount(id)
        historyModel.removeAccount(id)
        branchesModel.removeAccount(id)
        polling.removeStatus(of: id)
    }

    // MARK: - Instellingen, als eigenschappen voor bindings (`@Bindable`)

    /// De keuzes voor het poll-interval, in seconden.
    static let pollIntervals = AppConfig.pollIntervalChoices

    /// Het poll-interval, op de dichtstbijzijnde keuze.
    var pollInterval: Int {
        get { config.pollIntervalChoice }
        set {
            accounts.edit { $0.pollInterval = newValue }
            polling.scheduleRefresh()
        }
    }

    var checksForUpdates: Bool {
        get { config.checkForUpdates }
        set { accounts.edit { $0.checkForUpdates = newValue } }
    }

    var includesTestVersions: Bool {
        get { config.includeTestVersions }
        set {
            accounts.edit { $0.includeTestVersions = newValue }
            updates.includeTestVersionsChanged(newValue)
        }
    }

    /// Instellingen > Meldingen, direct opgeslagen.
    var notificationSettings: NotificationSettings {
        get { config.notifications }
        set {
            guard newValue != config.notifications else { return }
            accounts.edit { $0.notifications = newValue }
            historyModel.updateDockBadge()
        }
    }

    /// Instellingen, Agents: of coding agents Pullwatch via MCP mogen gebruiken. Direct
    /// opgeslagen; de socket gaat meteen open of dicht (via `didChangeConfig`).
    var agentAccess: AgentAccess {
        get { config.agentAccess }
        set { accounts.edit { $0.agentAccess = newValue } }
    }

    var checksVersionsDaily: Bool {
        get { config.autoVersionCheck }
        set { accounts.edit { $0.autoVersionCheck = newValue } }
    }

    var historyRetention: HistoryRetention {
        get { config.historyRetention }
        set {
            accounts.edit { $0.historyRetention = newValue }
            historyModel.prune(retention: newValue)
            branchesModel.prune(retention: newValue)
        }
    }

    // MARK: - Agents

    /// De tools die agents krijgen: `PullwatchMCPTools` over de modellen van de app, zodat een
    /// agent dezelfde gegevens ziet als de vensters. `AgentServer` maakt ze zo als de socket
    /// opengaat.
    func mcpTools() -> [MCPTool] {
        PullwatchMCPTools.all(dataSource: mcpDataSource)
    }

    // MARK: - Meldingen

    /// Een klik op een melding (`action` nil) of een knop erop.
    private func handleNotification(_ action: NotificationAction?, _ payload: NotificationPayload) {
        switch action {
        case nil:
            if payload.installsUpdate { updates.installUpdate() }
            if payload.section == "settings" {
                router.showSettings(SettingsTab.forNotification(payload))
            } else if let section = payload.section.flatMap(MainSection.init(rawValue:)) {
                switch (section, payload.package) {
                case (.dependencies, let package?): router.showPackage(package)
                case (.packages, let package?): router.showPublishedPackage(package)
                default: router.navigate(to: section)
                }
                router.show(.main)
            } else if payload.url == nil, let accountId = payload.accountId, let repo = payload.repo {
                // Een samenvatting van een repo: de repopagina.
                openRepositoryPage(accountId: accountId, repo: repo)
            }
            if let url = payload.url { NSWorkspace.shared.open(url) }
            // Een PR of tag openen leest hem; een samenvatting openen leest niets.
            if payload.url != nil, !payload.historyKeys.isEmpty { historyModel.setRead(Set(payload.historyKeys), true) }
        case .markRead?, .markAllRead?:
            historyModel.setRead(Set(payload.historyKeys), true)
        case .openRepository?:
            if let accountId = payload.accountId, let repo = payload.repo { openRepositoryPage(accountId: accountId, repo: repo) }
        case .mute?:
            if let accountId = payload.accountId, let repo = payload.repo {
                mute(repo: repo, accountId: accountId, kinds: payload.watchKinds)
            }
        case .showInPullwatch?:
            if let package = payload.package {
                router.showPackage(package)
                router.show(.main)
            } else if let accountId = payload.accountId, let repo = payload.repo {
                openRepositoryPage(accountId: accountId, repo: repo)
            }
        case .copyAdvisoryId?:
            guard let id = payload.advisoryId else { return }
            Pasteboard.copy(id)
        case .allowAgent?:
            if let name = payload.agentName { agents.allow(name) }
        case .denyAgent?:
            if let name = payload.agentName { agents.deny(name) }
        }
    }

    private func openRepositoryPage(accountId: UUID, repo: String) {
        router.navigate(to: .repos)
        showRepo(accountId: accountId, repo: repo)
        router.show(.main)
    }

    /// Zet de meldingen van `kinds` voor deze repo uit (de keuze per repo van #54); de repo
    /// blijft gevolgd.
    func mute(repo: String, accountId: UUID, kinds: [WatchKind]) {
        guard !kinds.isEmpty, let account = config.accounts.first(where: { $0.id == accountId }) else { return }
        let before = account.watch(for: repo)
        var after = before
        for kind in kinds { after[notifies: kind] = false }
        guard after != before else { return }
        notifications.remember(RepositoryMute(accountId: accountId, repo: repo, kinds: kinds, previous: before))
        setWatch(after, repo: repo, accountId: accountId)
    }

    /// Zet terug wat de laatste "Repo dempen" uitzette.
    func undoMute() {
        guard let mute = notifications.recentMute else { return }
        notifications.dismissMute()
        guard let account = config.accounts.first(where: { $0.id == mute.accountId }) else { return }
        var watch = account.watch(for: mute.repo)
        for kind in mute.kinds { watch[notifies: kind] = mute.previous[notifies: kind] }
        setWatch(watch, repo: mute.repo, accountId: mute.accountId)
    }
}
