#if DEBUG
import AppKit
import PullwatchCore

/// Alleen in debug-builds, met `-PullwatchSnapshotTour YES` (en `-PullwatchSnapshotDirectory`):
/// loopt eenmalig langs elk scherm van het hoofdvenster en bewaart elk als PNG, zodat de schermen
/// te bekijken zijn zonder UI-automatisering. Wacht tot er geschiedenis en een versiecheck zijn,
/// bv. met `-PullwatchFakeGitHub YES -PullwatchFakeData YES`.
enum SnapshotTour {
    private static var hasRun = false

    static func runIfRequested(_ model: AppModel) async {
        guard UserDefaults.standard.bool(forKey: "PullwatchSnapshotTour"), !hasRun else { return }
        hasRun = true
        // `-PullwatchSnapshotDark YES`: de schermen in donkere modus, los van de instelling van de Mac.
        if UserDefaults.standard.bool(forKey: "PullwatchSnapshotDark") {
            NSApp.appearance = NSAppearance(named: .darkAqua)
        } else if UserDefaults.standard.bool(forKey: "PullwatchSnapshotLight") {
            // `-PullwatchSnapshotLight YES`: lichte modus, ook als de Mac donker staat.
            NSApp.appearance = NSAppearance(named: .aqua)
        }
        // Eerst de lege schermen tijdens de eerste sync, met de balk onderin (met
        // `-PullwatchFakeDelay` duurt die lang genoeg om te zien).
        if model.historyModel.history.items.isEmpty {
            model.router.show(.pullRequests)
            try? await Task.sleep(for: .seconds(2))
            SnapshotCamera.shoot("fetching-pull-requests", windowId: WindowID.main.rawValue)
            // De camera wacht zelf 400 ms; pas daarna verder.
            try? await Task.sleep(for: .seconds(1))
            model.router.show(.tags)
            try? await Task.sleep(for: .seconds(1))
            SnapshotCamera.shoot("fetching-tags", windowId: WindowID.main.rawValue)
            try? await Task.sleep(for: .seconds(1))
            model.router.show(.repos)
            try? await Task.sleep(for: .seconds(1))
            SnapshotCamera.shoot("fetching-repos", windowId: WindowID.main.rawValue)
            try? await Task.sleep(for: .seconds(1))
            // De versiecheck met zijn aantallen, zodra die loopt.
            for _ in 0..<120 where model.versions.versionCheck.map({ $0.total == 0 }) ?? true {
                try? await Task.sleep(for: .milliseconds(250))
            }
            model.router.show(.dependencies)
            try? await Task.sleep(for: .seconds(1))
            SnapshotCamera.shoot("checking-versions", windowId: WindowID.main.rawValue)
            try? await Task.sleep(for: .seconds(1))
        }
        for _ in 0..<240 where model.historyModel.history.items.isEmpty || model.versions.versionReport == nil || model.versions.versionCheck != nil {
            try? await Task.sleep(for: .milliseconds(500))
        }
        model.router.show(.main)
        try? await Task.sleep(for: .seconds(2))
        // `-PullwatchSnapshotSmallest YES`: het hoofdvenster op zijn kleinste maat, om afkappen te zien.
        if UserDefaults.standard.bool(forKey: "PullwatchSnapshotSmallest"),
           let window = NSApp.windows.first(where: { $0.identifier?.rawValue.hasPrefix(WindowID.main.rawValue) == true }) {
            window.setContentSize(NSSize(width: max(window.contentMinSize.width, 900), height: max(window.contentMinSize.height, 520)))
            try? await Task.sleep(for: .seconds(1))
        }
        let repo = model.overview.repoSummaries.first { $0.repo.hasSuffix("hello-world") } ?? model.overview.repoSummaries.first
        let group = model.overview.sidebar.pullRequestGroups.first

        var steps: [(String, () -> Void)] = [
            ("pull-requests", { model.router.show(.pullRequests) }),
            // Een geselecteerde rij: het nummer in de kolom Repo volgt de kleuren van de selectie.
            ("pull-requests-selected", { SnapshotCamera.selectRow(1, windowId: WindowID.main.rawValue) }),
            ("tags", { model.router.show(.tags) }),
            ("branches", { model.router.show(.branches) }),
            // De gestapelde branch feature/dark-icons, met het inspectievenster.
            ("branches-selected", { SnapshotCamera.selectRow(4, windowId: WindowID.main.rawValue) }),
            ("stats", { model.router.show(.stats) }),
            ("repos", { model.router.show(.repos) }),
            ("versions", { model.router.show(.dependencies) }),
            // Wat de repo's publiceren: de lijst, een package met wie het gebruikt, en het filter op één repo.
            ("packages", { model.router.show(.packages) }),
            ("history-author-token", { model.router.showHistory(.pullRequest, author: "mona") }),
        ]
        if let package = model.versions.publishedPackages.first(where: { !$0.users.isEmpty }) ?? model.versions.publishedPackages.first {
            steps.append(("packages-inspector", {
                model.router.show(.packages)
                model.router.publishedPackagesRequest = PublishedPackagesRequest(selection: package.id)
            }))
        }
        if let publisher = model.versions.publishedPackages.first(where: { $0.package.repository != nil })?.package {
            steps.append(("packages-repo", {
                model.router.showPublishedPackages(of: HistoryRepo(accountId: publisher.accountId, repo: publisher.repository ?? ""))
            }))
        }
        if let group {
            steps.append(("history-group", { model.router.sidebarSelection = .group(.pullRequest, group.id) }))
        }
        if let repo {
            steps.append(("repo-detail", {
                model.router.show(.repos)
                model.router.repoTab = .overview
                model.router.showRepo(id: repo.id)
            }))
            // Het eind van het overzicht: Volgen (PR's, tags, branches, gemerged) met de meldingen.
            steps.append(("repo-detail-follow", { SnapshotCamera.scroll(windowId: WindowID.main.rawValue, pages: 20) }))
            // De controle: runtimes en kwetsbaarheden, en een gekozen advies in het inspectievenster.
            steps.append(("repo-check", { model.router.repoSelectionRequest = RepoSelectionRequest(tab: .check) }))
            if let advisory = repo.versions?.vulnerabilityRows(gitHub: repo.advisories).max(by: { $0.severity < $1.severity }) {
                steps.append(("repo-check-inspector", { model.router.repoSelectionRequest = RepoSelectionRequest(tab: .check, rowId: advisory.id) }))
            }
            // Packages, met een package dat iets tegenhoudt in het inspectievenster.
            steps.append(("repo-packages", { model.router.repoSelectionRequest = RepoSelectionRequest(tab: .dependencies) }))
            steps.append(("repo-packages-inspector", { model.router.repoSelectionRequest = RepoSelectionRequest(tab: .dependencies, rowId: "|npm:express") }))
            // De beveiliging van GitHub zelf, met een melding van code scanning.
            steps.append(("repo-security", { model.router.repoSelectionRequest = RepoSelectionRequest(tab: .security) }))
            if let alert = repo.versions?.security?.findingRows.first {
                steps.append(("repo-security-inspector", { model.router.repoSelectionRequest = RepoSelectionRequest(tab: .security, rowId: alert.id) }))
            }
            // Een repo met een eigen advies bij "Beveiliging op GitHub".
            if let linguist = model.overview.repoSummaries.first(where: { $0.repo.hasSuffix("/linguist") && $0.id != repo.id }) {
                steps.append(("repo-detail-linguist", {
                    model.router.showRepo(id: linguist.id)
                    model.router.repoSelectionRequest = RepoSelectionRequest(tab: .security)
                }))
                steps.append(("repo-detail-linguist-2", { model.router.repoSelectionRequest = RepoSelectionRequest(tab: .check) }))
                // Daar mag de app de checks niet lezen: de opmerking onder de pull requests.
                steps.append(("repo-detail-linguist-overview", { model.router.repoSelectionRequest = RepoSelectionRequest(tab: .overview) }))
                steps.append(("repo-detail-back", {
                    model.router.showRepo(id: repo.id)
                    model.router.repoSelectionRequest = RepoSelectionRequest(tab: .overview)
                }))
            }
            steps.append(("repo-stats", { model.router.showStats(repoId: repo.id) }))
            steps.append(("repo-history-token", { model.router.showHistory(.pullRequest, repo: HistoryRepo(accountId: repo.accountId, repo: repo.repo)) }))
        }
        // Een losse repo van een andere organisatie (de nep-openEHR) in de lijst van Repo's.
        if let extra = model.overview.repoSummaries.first(where: { $0.repo.hasPrefix("openEHR/") }) {
            steps.append(("repo-detail-extra", {
                model.router.show(.repos)
                model.router.showRepo(id: extra.id)
            }))
        }
        steps.append(("repos-again", { model.router.show(.repos) }))
        // `-PullwatchSnapshotTourInteract YES`: na elke tabel ook sorteren (twee keer, dus beide
        // richtingen), schuiven en een rij kiezen, zoals iemand met de muis doet; de waarschuwing
        // van AppKit over een reentrante tabel-delegate (#204) zou dan in stderr staan.
        if UserDefaults.standard.bool(forKey: "PullwatchSnapshotTourInteract") {
            let tables: Set<String> = [
                "pull-requests", "tags", "branches", "repos", "versions", "packages", "history-author-token", "history-group",
                "repo-check", "repo-packages", "repo-security", "repo-history-token", "repos-again",
            ]
            let main = WindowID.main.rawValue
            steps = steps.flatMap { step -> [(String, () -> Void)] in
                guard tables.contains(step.0) else { return [step] }
                // Elke kolom twee keer: oplopend en aflopend.
                let sorts = (0..<6).flatMap { column -> [(String, () -> Void)] in
                    [
                        ("\(step.0)-sorted-\(column)", { SnapshotCamera.sortByColumn(column, windowId: main) }),
                        ("\(step.0)-sorted-\(column)-again", { SnapshotCamera.sortByColumn(column, windowId: main) }),
                    ]
                }
                return [step] + sorts + [
                    ("\(step.0)-scrolled", { SnapshotCamera.scroll(windowId: main, pages: 1) }),
                    ("\(step.0)-row", { SnapshotCamera.selectRow(2, windowId: main) }),
                ]
            }
        }
        // `-PullwatchSnapshotTourOnly a,b` (met `-PullwatchSnapshotTourRepeat <n>`): alleen deze
        // stappen, n keer na elkaar, om één overgang te herhalen.
        if let only = UserDefaults.standard.string(forKey: "PullwatchSnapshotTourOnly") {
            let names = only.split(separator: ",").map(String.init)
            let picked = steps.filter { names.contains($0.0) }
            steps = Array(repeating: picked, count: max(1, UserDefaults.standard.integer(forKey: "PullwatchSnapshotTourRepeat")))
                .flatMap(\.self)
        }
        for (name, step) in steps {
            // De naam van de stap in stderr, zodat een melding van AppKit bij een stap te leggen is.
            FileHandle.standardError.write(Data("SnapshotTour step \(name)\n".utf8))
            step()
            try? await Task.sleep(for: .seconds(1.5))
            SnapshotCamera.shoot(name, windowId: WindowID.main.rawValue)
            try? await Task.sleep(for: .seconds(0.8))
        }
        // "Volg een repository…": het blad fotografeert zichzelf ("watch-repository").
        model.watchRepository()
        try? await Task.sleep(for: .seconds(2))
        model.router.isWatchingRepository = false
        try? await Task.sleep(for: .seconds(1))
        // De lijst van het account in Instellingen, met "Andere repositories" onderaan.
        model.router.show(.settings)
        try? await Task.sleep(for: .seconds(3))
        let settings = "com_apple_SwiftUI_Settings_window"
        for page in 1...6 {
            SnapshotCamera.scroll(windowId: settings, pages: Double(page))
            try? await Task.sleep(for: .seconds(0.6))
            SnapshotCamera.shoot("settings-repos-\(page)", windowId: settings)
            try? await Task.sleep(for: .seconds(0.8))
        }
    }
}
#endif
