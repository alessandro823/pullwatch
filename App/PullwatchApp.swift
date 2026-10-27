import AppKit
import SwiftUI
import UserNotifications

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        _ = AppLanguage.atLaunch
        UNUserNotificationCenter.current().delegate = Notifier.shared
        AppModel.shared.start()
        DockIcon.shared.start()
    }
}

/// Toont Pullwatch in het Dock zolang er een eigen venster (instellingen, geschiedenis, versies)
/// open is; zonder venster draait de app weer alleen in de menubalk.
@MainActor
final class DockIcon {
    static let shared = DockIcon()
    static let windowIds = ["settings", "history", "versions"]

    func start() {
        let center = NotificationCenter.default
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didMiniaturizeNotification] {
            center.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { DockIcon.shared.update() }
            }
        }
        // Bij willClose is het venster nog zichtbaar; daarom pas daarna kijken.
        center.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { DockIcon.shared.update() } }
        }
    }

    private func update() {
        let hasWindow = NSApp.windows.contains { window in
            (window.isVisible || window.isMiniaturized)
                && Self.windowIds.contains { window.identifier?.rawValue.hasPrefix($0) == true }
        }
        let policy: NSApplication.ActivationPolicy = hasWindow ? .regular : .accessory
        guard NSApp.activationPolicy() != policy else { return }
        NSApp.setActivationPolicy(policy)
        if hasWindow { NSApp.activate() }
    }
}

@main
struct PullwatchApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel.shared

    var body: some Scene {
        MenuBarExtra {
            MenuView(model: model)
        } label: {
            HStack(spacing: 2) {
                Image(systemName: model.menuBarSymbol)
                if model.history.unreadCount > 0 {
                    Text("•")
                }
            }
        }
        .menuBarExtraStyle(.window)

        Window("Pullwatch instellingen", id: "settings") {
            SettingsView(model: model)
        }
        .windowResizability(.contentMinSize)

        Window("Geschiedenis", id: "history") {
            HistoryView(model: model)
        }
        .windowResizability(.contentMinSize)

        Window("Versies", id: "versions") {
            VersionsView(model: model)
        }
        .windowResizability(.contentMinSize)
    }
}
