import AppKit
import PullwatchMCP

/// Start de Pullwatch waar de helper in zit, op de achtergrond: niet naar voren, niet in de
/// recente items, en met `-PullwatchLaunchedByAgent YES`, zodat de app geen venster herstelt.
/// Pullwatch is een menubalk-app, dus er verschijnt geen venster of Dock-icoon.
struct WorkspaceLauncher: PullwatchLaunching {
    /// De app rond de helper; nil als de helper los staat.
    let app: URL?
    /// Launch-argumenten die de app ook moet krijgen (een eigen datamap).
    let arguments: [String]

    struct NotInsideTheApp: Error {}

    func launchPullwatch() async throws {
        guard let app else { throw NotInsideTheApp() }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.addsToRecentItems = false
        configuration.arguments = arguments + ["-\(PullwatchAppLocation.launchedByAgentArgument)", "YES"]
        _ = try await NSWorkspace.shared.openApplication(at: app, configuration: configuration)
    }
}
