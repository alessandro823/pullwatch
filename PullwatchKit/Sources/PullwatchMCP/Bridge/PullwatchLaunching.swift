public import Foundation

/// Start Pullwatch op de achtergrond, voor de stand **Altijd**. Achter een protocol, zodat de
/// tests van `MCPBridge` niets starten. De helper geeft `NSWorkspace` mee.
public protocol PullwatchLaunching: Sendable {
    /// Start Pullwatch zonder hem naar voren te halen; keert terug zodra macOS hem gestart heeft
    /// (niet als de socket er is).
    func launchPullwatch() async throws
}

/// Waar de app staat ten opzichte van de helper.
public enum PullwatchAppLocation {
    /// `Pullwatch.app` voor een helper op `Pullwatch.app/Contents/Helpers/pullwatch-mcp`, na het
    /// volgen van symlinks (iemand kan de helper in zijn `PATH` linken). Nil als de helper niet
    /// in een app staat.
    public static func appBundle(forHelperAt helper: URL) -> URL? {
        let resolved = helper.resolvingSymlinksInPath().standardizedFileURL
        let helpers = resolved.deletingLastPathComponent()
        let contents = helpers.deletingLastPathComponent()
        let app = contents.deletingLastPathComponent()
        guard helpers.lastPathComponent == "Helpers", contents.lastPathComponent == "Contents",
            app.pathExtension == "app"
        else { return nil }
        return app
    }

    /// De launch-argumenten van de helper die de app ook moet krijgen, zodat een helper met een
    /// eigen datamap (`-PullwatchDataDirectory`, de tests) een app start die dezelfde map en geen
    /// echte tokens gebruikt.
    /// Het argument dat de helper meegeeft als hij de app zelf start: de app herstelt dan geen
    /// venster, zodat een agent die Pullwatch start niets in beeld zet.
    public static let launchedByAgentArgument = "PullwatchLaunchedByAgent"

    public static let forwardedArguments = ["PullwatchDataDirectory", "PullwatchEphemeralSecrets", "PullwatchFakeGitHub"]

    /// `-Naam waarde` voor elk van `forwardedArguments` dat in `arguments` (het argumentdomein van
    /// `UserDefaults`) staat.
    public static func launchArguments(from arguments: [String: Any]) -> [String] {
        forwardedArguments.flatMap { key -> [String] in
            guard let value = arguments[key] else { return [] }
            return ["-\(key)", "\(value)"]
        }
    }
}
