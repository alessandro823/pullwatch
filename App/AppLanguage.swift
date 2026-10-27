import AppKit

/// Taal van de app: volgt macOS, of een vaste keuze via `AppleLanguages` in de eigen defaults.
/// Een wijziging werkt pas na een herstart.
enum AppLanguage: String, CaseIterable, Identifiable {
    case system, nl, en, de, fr

    var id: String { rawValue }

    /// Talen in hun eigen taal, zodat je je taal ook herkent als de app in een andere staat.
    var name: String {
        switch self {
        case .system: String(localized: "Systeem")
        case .nl: "Nederlands"
        case .en: "English"
        case .de: "Deutsch"
        case .fr: "Français"
        }
    }

    private static let key = "AppleLanguages"

    /// Keuze waarmee deze run gestart is (wordt vastgelegd bij het opstarten).
    static let atLaunch = current

    /// Alleen de eigen defaults: `UserDefaults.standard` zou ook de systeemtalen teruggeven.
    static var current: AppLanguage {
        let domain = Bundle.main.bundleIdentifier.flatMap { UserDefaults.standard.persistentDomain(forName: $0) }
        guard let code = (domain?[key] as? [String])?.first else { return .system }
        return AppLanguage(rawValue: code) ?? .system
    }

    static func select(_ language: AppLanguage) {
        if language == .system {
            UserDefaults.standard.removeObject(forKey: key)
        } else {
            UserDefaults.standard.set([language.rawValue], forKey: key)
        }
    }

    /// Start een nieuwe Pullwatch en sluit deze zodra die draait.
    @MainActor static func relaunch() {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }
}

/// Het standaard About-paneel van macOS met versie en icoon, plus een korte uitleg en link.
@MainActor enum AboutPanel {
    static let repository = URL(string: "https://github.com/alessandro823/pullwatch")!

    static func show() {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let text: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
            .foregroundColor: NSColor.secondaryLabelColor,
            .paragraphStyle: paragraph,
        ]
        let credits = NSMutableAttributedString(
            string: String(localized: "Nieuwe pull requests en tags uit GitHub en Azure DevOps in je menubalk, met geschiedenis en een versie- en CVE-check van je repo's.") + "\n\n",
            attributes: text
        )
        var link = text
        link[.link] = repository
        credits.append(NSAttributedString(string: "github.com/alessandro823/pullwatch", attributes: link))
        credits.append(NSAttributedString(string: "\n" + String(localized: "Licentie: Apache 2.0"), attributes: text))
        NSApp.activate()
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits])
    }
}
