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
                content.title = "\(pr.repo): nieuwe PR"
                content.body = "\(pr.title) — \(pr.authorName)"
                content.userInfo = ["url": pr.webURL.absoluteString, "key": pr.dedupKey]
                identifier = pr.dedupKey
            case .tag(let tag):
                content.title = "\(tag.repo): nieuwe tag"
                content.body = tag.authorName.map { "\(tag.name) — \($0)" } ?? tag.name
                content.userInfo = ["url": tag.webURL.absoluteString, "key": tag.dedupKey]
                identifier = tag.dedupKey
            case .completed(let pr):
                content.title = "\(pr.repo): PR completed"
                content.body = "\(pr.title) — \(pr.authorName)"
                content.userInfo = ["url": pr.webURL.absoluteString, "key": pr.dedupKey]
                identifier = pr.dedupKey + ":completed"
            case .summary(let kind, let count, let lines):
                switch kind {
                case .pullRequest: content.title = "\(count) nieuwe PR's"
                case .tag: content.title = "\(count) nieuwe tags"
                case .completed: content.title = "\(count) PR's completed"
                }
                content.body = lines.joined(separator: "\n")
                identifier = UUID().uuidString
            }
            content.sound = .default
            add(UNNotificationRequest(identifier: identifier, content: content, trigger: nil))
        }
    }

    func deliverAuthFailure(accountName: String) {
        let content = UNMutableNotificationContent()
        content.title = "Pullwatch: \(accountName)"
        content.body = "Token ongeldig of verlopen. Werk het bij in Instellingen."
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
