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
    private(set) var recent: RecentList
    private(set) var statuses: [UUID: AccountState] = [:]
    private(set) var notificationsAllowed = true

    @ObservationIgnored private let configStore = JSONFileStore<AppConfig>(url: AppPaths.file("config.json"))
    @ObservationIgnored private let recentStore = JSONFileStore<RecentList>(url: AppPaths.file("recent.json"))
    @ObservationIgnored private let secrets = KeychainStore()
    @ObservationIgnored private let engine = PollEngine(
        makeProvider: { ProviderFactory.make($0) },
        store: JSONFileStore<SeenState>(url: AppPaths.file("seen.json"))
    )
    @ObservationIgnored private let notifier = Notifier.shared
    @ObservationIgnored private var loopTask: Task<Void, Never>?

    private init() {
        do {
            config = try configStore.load() ?? AppConfig()
        } catch {
            logger.error("config onleesbaar: \(error.localizedDescription)")
            config = AppConfig()
        }
        recent = (try? recentStore.load()) ?? RecentList()
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
            Task { @MainActor in await self?.refreshNow() }
        }

        loopTask = Task { [weak self] in
            guard let self else { return }
            self.notificationsAllowed = await self.notifier.requestAuthorization()
            while !Task.isCancelled {
                await self.tick()
                try? await Task.sleep(for: .seconds(15))
            }
        }
    }

    func refreshNow() async {
        await engine.forceRefresh()
        await tick()
    }

    func open(_ item: RecentItem) {
        NSWorkspace.shared.open(item.pullRequest.webURL)
        markRead(item.id)
    }

    func markRead(_ key: String) {
        recent.markRead(key)
        saveRecent()
    }

    func markAllRead() {
        recent.markAllRead()
        saveRecent()
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
        recent.removeAccount(id)
        statuses[id] = nil
        saveConfig()
        saveRecent()
    }

    func hasStoredPAT(_ id: UUID) -> Bool {
        (try? secrets.read(account: id.uuidString)) != nil
    }

    func setPollInterval(_ seconds: Int) {
        config.pollInterval = seconds
        saveConfig()
    }

    private func tick() async {
        let result = await engine.poll(
            accounts: config.pollableAccounts,
            interval: TimeInterval(config.clampedInterval)
        )
        statuses = result.statuses

        if !result.newPullRequests.isEmpty {
            recent.add(result.newPullRequests, at: Date())
            saveRecent()
            notifier.deliver(NotificationPlanner.plan(result.newPullRequests))
        }
        for id in result.authFailures {
            if let account = config.accounts.first(where: { $0.id == id }) {
                notifier.deliverAuthFailure(accountName: account.displayName)
            }
        }
    }

    private func saveConfig() {
        do {
            try configStore.save(config)
        } catch {
            logger.error("config opslaan mislukt: \(error.localizedDescription)")
        }
    }

    private func saveRecent() {
        do {
            try recentStore.save(recent)
        } catch {
            logger.error("recent opslaan mislukt: \(error.localizedDescription)")
        }
    }
}
