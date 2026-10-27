import AppKit
import os
import PullwatchCore
import UserNotifications

private let logger = Logger(subsystem: "nl.torrisi.pullwatch", category: "notifier")

@MainActor
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = Notifier()

    /// Wordt aangeroepen met de dedupKey wanneer de gebruiker op een PR-melding klikt.
    var onOpen: ((String) -> Void)?

    private var center: UNUserNotificationCenter { .current() }

    func requestAuthorization() async -> Bool {
        do {
            return try await center.requestAuthorization(options: [.alert, .sound])
        } catch {
            logger.error("notificatie-toestemming mislukt: \(error.localizedDescription)")
            return false
        }
    }

    func isAuthorized() async -> Bool {
        await Self.authorizationGranted()
    }

    private nonisolated static func authorizationGranted() async -> Bool {
        let status = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
        return status == .authorized || status == .provisional
    }

    func deliver(_ plans: [PlannedNotification]) {
        for plan in plans {
            let content = UNMutableNotificationContent()
            let identifier: String
            switch plan {
            case .pullRequest(let pr):
                content.title = String(localized: "\(pr.repo): nieuwe PR")
                content.body = "\(pr.title) — \(pr.authorName)"
                content.userInfo = ["url": pr.webURL.absoluteString, "key": pr.dedupKey]
                identifier = pr.dedupKey
            case .tag(let tag):
                content.title = String(localized: "\(tag.repo): nieuwe tag")
                content.body = tag.authorName.map { "\(tag.name) — \($0)" } ?? tag.name
                content.userInfo = ["url": tag.webURL.absoluteString, "key": tag.dedupKey]
                identifier = tag.dedupKey
            case .completed(let pr):
                content.title = String(localized: "\(pr.repo): PR completed")
                content.body = "\(pr.title) — \(pr.authorName)"
                content.userInfo = ["url": pr.webURL.absoluteString, "key": pr.dedupKey]
                identifier = pr.dedupKey + ":completed"
            case .summary(let kind, let count, let lines):
                switch kind {
                case .pullRequest: content.title = String(localized: "\(count) nieuwe PR's")
                case .tag: content.title = String(localized: "\(count) nieuwe tags")
                case .completed: content.title = String(localized: "\(count) PR's completed")
                }
                content.body = lines.joined(separator: "\n")
                identifier = UUID().uuidString
            }
            content.sound = .default
            add(UNNotificationRequest(identifier: identifier, content: content, trigger: nil))
        }
    }

    /// Tot drie losse meldingen (klik opent de OSV-pagina), daarboven één samenvatting.
    func deliverVulnerabilities(_ items: [(repo: String, vulnerability: Vulnerability)]) {
        func line(_ v: Vulnerability) -> String {
            let severity = v.severity.map { " [\($0.capitalized)]" } ?? ""
            let fix = v.fixedIn.map { " → \($0)" } ?? ""
            return "\(v.cve ?? v.id)\(severity) \(v.package) \(v.version)\(fix)"
        }
        if items.count <= 3 {
            for (repo, v) in items {
                let content = UNMutableNotificationContent()
                content.title = String(localized: "\(repo): nieuwe kwetsbaarheid")
                content.body = [line(v), v.summary].compactMap { $0 }.joined(separator: "\n")
                content.userInfo = ["url": v.url.absoluteString]
                content.sound = .default
                add(UNNotificationRequest(identifier: "cve-\(repo)-\(v.id)-\(v.package)", content: content, trigger: nil))
            }
        } else {
            let content = UNMutableNotificationContent()
            content.title = String(localized: "\(items.count) nieuwe kwetsbaarheden")
            content.body = (items.prefix(3).map { "\($0.repo): \(line($0.vulnerability))" } + [String(localized: "Zie Versies… in het menu")])
                .joined(separator: "\n")
            content.sound = .default
            add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        }
    }

    func deliverAuthFailure(accountName: String) {
        let content = UNMutableNotificationContent()
        content.title = "Pullwatch: \(accountName)"
        content.body = String(localized: "Token ongeldig of verlopen. Werk het bij in Instellingen.")
        add(UNNotificationRequest(identifier: "auth-\(accountName)", content: content, trigger: nil))
    }

    private func add(_ request: UNNotificationRequest) {
        center.add(request) { error in
            if let error {
                logger.error("melding toevoegen mislukt: \(error.localizedDescription)")
            }
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let info = response.notification.request.content.userInfo
        let urlString = info["url"] as? String
        let key = info["key"] as? String
        await MainActor.run {
            if let urlString, let url = URL(string: urlString) {
                NSWorkspace.shared.open(url)
            }
            if let key {
                self.onOpen?(key)
            }
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}
