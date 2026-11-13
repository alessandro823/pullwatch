import AppKit
import Observation
import PullwatchCore

nonisolated private let logger = Log(category: "app")

/// De branches van de gevolgde repo's: de boom zoals hij nu is (`trees`, uit seen.json van de
/// poll-engine) en de pushes die Pullwatch zag (branches.json). Ze tellen niet mee als ongelezen
/// en geven geen melding.
@Observable
final class BranchesModel {
    private(set) var log: BranchLog
    /// Per gevolgde repo de branches met hun ouder en afstand; gezet na elke branch-poll.
    var trees: [RepoBranches] = []

    @ObservationIgnored private let store: JSONFileStore<BranchLog>?

    /// `nil` houdt alles in het geheugen (tests).
    init(store: JSONFileStore<BranchLog>?) {
        self.store = store
        var initial = BranchLog()
        do {
            initial = try store?.load() ?? BranchLog()
        } catch {
            logger.error("branches onleesbaar, start leeg: \(error.localizedDescription)")
        }
        log = initial
    }

    /// Voegt de pushes van een branch-poll toe, snoeit op de bewaartermijn en bewaart het resultaat.
    func apply(_ pushes: [BranchPush], retention: HistoryRetention, now: Date) {
        mutate {
            $0.add(pushes)
            $0.prune(now: now, retention: retention)
        }
    }

    /// Na een kortere bewaartermijn in Instellingen.
    func prune(retention: HistoryRetention, now: Date = Date()) {
        mutate { $0.prune(now: now, retention: retention) }
    }

    func removeAccount(_ id: UUID) {
        mutate { $0.removeAccount(id) }
        trees.removeAll { $0.accountId == id }
    }

    /// De pushes naar één branch, nieuwste eerst.
    func pushes(accountId: UUID, repo: String, branch: String) -> [BranchPush] {
        log.pushes.filter {
            $0.accountId == accountId && $0.branch == branch && $0.repo.caseInsensitiveCompare(repo) == .orderedSame
        }
    }

    func open(_ url: URL) {
        NSWorkspace.shared.open(url)
    }

    /// Past de log aan en bewaart hem alleen als er iets veranderde.
    private func mutate(_ change: (inout BranchLog) -> Void) {
        var updated = log
        change(&updated)
        guard updated != log else { return }
        log = updated
        save()
    }

    private func save() {
        guard let store else { return }
        do {
            try store.save(log)
        } catch {
            logger.error("branches opslaan mislukt: \(error.localizedDescription)")
        }
    }
}
