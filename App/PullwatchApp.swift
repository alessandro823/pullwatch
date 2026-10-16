import AppKit
import SwiftUI
import UserNotifications

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        UNUserNotificationCenter.current().delegate = Notifier.shared
        AppModel.shared.start()
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
    }
}
