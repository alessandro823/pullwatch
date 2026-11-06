import AppKit
import Observation
import PullwatchCore

nonisolated private let logger = Log(category: "app")

/// De geschiedenis van PR's en tags (history.json) met wat gelezen is, de lijstjes van het menu,
/// het aantal ongelezen op het Dock-icoon en de statistieken eruit.
@Observable
final class HistoryModel {
    private(set) var history: History {
        didSet {
            statsCache.removeAll()
            didChangeHistory()
            recomputeMenu()
        }
    }

    /// Voor het menu, bijgewerkt als de geschiedenis verandert (niet bij elke keer tekenen).
    private(set) var menuPullRequests: [HistoryItem] = []
    private(set) var menuTags: [HistoryItem] = []
    private(set) var hasTags = false
    private(set) var unreadCount = 0

    /// Na elke wijziging van `history`; `AppModel` werkt er het overzicht mee bij.
    @ObservationIgnored var didChangeHistory: () -> Void = {}
    @ObservationIgnored private var statsCache = ActivityStatsCache()
    @ObservationIgnored private let services: AppServices
    @ObservationIgnored private let accounts: AccountsModel

    init(services: AppServices, accounts: AccountsModel) {
        self.services = services
        self.accounts = accounts
        let store = services.historyStore
        var stored: History?
        var storedUnreadable = false
        do {
            stored = try store.load()
        } catch {
            logger.error("history onleesbaar, start leeg: \(error.localizedDescription)")
            storedUnreadable = true
            Self.moveAside(store.url)
        }
        var legacy: RecentList?
        if !storedUnreadable {
            do {
                legacy = try services.legacyRecentStore.load()
            } catch {
                logger.error("recent.json onleesbaar, niet gemigreerd: \(error.localizedDescription)")
            }
        }
        // recent.json blijft staan na migratie.
        let initial = History.initial(stored: stored, storedUnreadable: storedUnreadable, legacy: legacy)
        history = initial.history
        var needsSave = initial.needsSave
        if history.prune(now: Date(), retention: accounts.config.historyRetention) { needsSave = true }
        if needsSave { save() }
        // In init loopt didSet niet: het menu hier één keer vullen.
        recomputeMenu()
    }

    /// Zet een onleesbaar bestand opzij als `<naam>.corrupt-<unix-tijd>`, zodat het niet overschreven wordt.
    private static func moveAside(_ url: URL) {
        let timestamp = Int(Date().timeIntervalSince1970)
        let target = url.deletingLastPathComponent().appending(path: "\(url.lastPathComponent).corrupt-\(timestamp)")
        do {
            try FileManager.default.moveItem(at: url, to: target)
            logger.notice("onleesbaar bestand bewaard als \(target.lastPathComponent)")
        } catch {
            logger.error("opzij zetten van \(url.lastPathComponent) mislukt: \(error.localizedDescription)")
        }
    }

    private func recomputeMenu() {
        let pullRequests = history.latest(.pullRequest, limit: 5)
        if pullRequests != menuPullRequests { menuPullRequests = pullRequests }
        let tags = history.latest(.tag, limit: 5)
        if tags != menuTags { menuTags = tags }
        let anyTags = history.items.contains { $0.entry.kind == .tag }
        if anyTags != hasTags { hasTags = anyTags }
        let unread = history.unreadCount
        if unread != unreadCount {
            unreadCount = unread
            updateDockBadge()
        }
    }

    /// Het aantal ongelezen op het Dock-icoon. Pullwatch staat alleen in het Dock zolang er een
    /// venster open is; zonder venster is er dus ook geen badge.
    func updateDockBadge() {
        guard !AppModel.isTestHost else { return }
        let label = accounts.config.notifications.dockBadge && unreadCount > 0 ? "\(unreadCount)" : nil
        let tile = NSApplication.shared.dockTile
        if tile.badgeLabel != label { tile.badgeLabel = label }
    }

    /// Statistieken per periode en filter, bewaard tot de geschiedenis verandert of na tien
    /// minuten (de periode schuift op). Leest `history`, zodat een view die dit vraagt bijwerkt
    /// als die verandert.
    func activityStats(period: StatsPeriod, filter: ActivityFilter) -> ActivityStats {
        statsCache.stats(history: history, period: period, filter: filter)
    }

    // MARK: - Openen en gelezen

    /// ⌘O: wat het zichtbare onderdeel geselecteerd heeft in de browser.
    func open(_ target: BrowserTarget) {
        switch target {
        case .history(let ids):
            for item in history.items where ids.contains(item.id) { open(item) }
        case .page(let url):
            NSWorkspace.shared.open(url)
        }
    }

    /// ⇧⌘L: de webadressen van wat het zichtbare onderdeel geselecteerd heeft, één per regel.
    func links(of target: BrowserTarget) -> [URL] {
        switch target {
        case .history(let ids): history.items.filter { ids.contains($0.id) }.map(\.entry.webURL)
        case .page(let url): [url]
        }
    }

    /// ⌥⇧⌘L: de verwijzingen van de geselecteerde PR's (`FerroHEALTH/FerroFED#1570`), één per
    /// regel; tags en een pagina hebben er geen.
    func references(of target: BrowserTarget) -> [String] {
        guard case .history(let ids) = target else { return [] }
        let kinds = accounts.config.providerKinds
        return history.items.filter { ids.contains($0.id) }.compactMap { item in
            kinds[item.entry.accountId].flatMap(item.entry.reference)
        }
    }

    func open(_ item: HistoryItem) {
        NSWorkspace.shared.open(item.entry.webURL)
        markRead(item.id)
    }

    func markRead(_ key: String) {
        history.markRead(key)
        save()
        removeReadNotifications()
    }

    func markAllRead() {
        history.markAllRead()
        save()
        removeReadNotifications()
    }

    /// Gelezen of ongelezen voor deze PR's en tags (de selectie, of alles wat een lijst toont).
    func setRead(_ ids: Set<String>, _ isRead: Bool) {
        if history.setRead(ids, isRead) { save() }
        if isRead { removeReadNotifications() }
    }

    /// Meldingen van items die nu gelezen zijn gaan uit het Berichtencentrum. Een item dat niet
    /// meer in de geschiedenis staat telt als gelezen.
    private func removeReadNotifications() {
        let unread = Set(history.items.filter { !$0.isRead }.map(\.id))
        services.notifier.removeDelivered(unread: unread)
    }

    // MARK: - Bijwerken

    /// Neemt op wat een poll vond: nieuwe PR's en tags ongelezen, wat de sync bracht gelezen,
    /// en ruimt op wat buiten de bewaartermijn valt.
    func apply(_ result: PollResult, retention: HistoryRetention, now: Date) {
        var changed = false
        let hasNotified = !result.newPullRequests.isEmpty || !result.newTags.isEmpty
        if hasNotified {
            history.add(pullRequests: result.newPullRequests, tags: result.newTags, at: now)
            changed = true
        }
        // Na add: een gemelde PR staat dan al ongelezen in de geschiedenis en blijft dat.
        // PR's van vóór de bewaartermijn niet toevoegen: die zou prune meteen weer verwijderen.
        let cutoff = retention.maxAge.map { now - $0 }
        // Drafts zonder melding komen er net zo in: gelezen, op hun plek.
        if history.merge(synced: result.syncedPullRequests + result.quietPullRequests, notBefore: cutoff) { changed = true }
        // Bestaande tags uit de eerste tag-poll van een repo: gelezen, zonder melding.
        if history.merge(syncedTags: result.syncedTags, notBefore: cutoff) { changed = true }
        // Bekende tags krijgen hun auteur en release bij, zonder melding en op hun plek.
        if history.update(tags: result.updatedTags) { changed = true }
        // De checks (CI) van PR's die er al staan, op hun plek en zonder melding.
        if history.update(checks: result.checks) { changed = true }
        // Of open PR's in de rij staan om vanzelf te mergen, op hun plek en zonder melding.
        if history.update(mergeQueues: result.mergeQueues) { changed = true }
        if history.update(leftQueue: result.leftQueue) { changed = true }
        if history.prune(now: now, retention: retention) { changed = true }
        if changed { save() }
    }

    /// Ruimt op wat buiten een (nieuwe) bewaartermijn valt.
    func prune(retention: HistoryRetention) {
        if history.prune(now: Date(), retention: retention) { save() }
    }

    func removeAccount(_ id: UUID) {
        history.removeAccount(id)
        save()
    }

    private func save() {
        do {
            try services.historyStore.save(history)
        } catch {
            logger.error("history opslaan mislukt: \(error.localizedDescription)")
        }
    }
}
