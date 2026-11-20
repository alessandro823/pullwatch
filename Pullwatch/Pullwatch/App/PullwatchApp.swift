import AppKit
import PullwatchCore
import SwiftUI

extension View {
    /// Geeft een venster de modellen van de app mee in de environment. Elke view leest daar
    /// alleen het model dat hij nodig heeft (`@Environment(PollingModel.self)`), zodat een
    /// wijziging in een ander model hem niet opnieuw laat tekenen.
    func appModels(_ app: AppModel) -> some View {
        environment(app)
            .environment(app.accounts)
            .environment(app.historyModel)
            .environment(app.branchesModel)
            .environment(app.notifications)
            .environment(app.versions)
            .environment(app.overview)
            .environment(app.polling)
            .environment(app.updates)
            .environment(app.router)
            .environment(app.agents)
    }
}

/// De app: het menubalk-icoon met zijn paneel, het hoofdvenster, het welkomstvenster en Instellingen.
@main
struct PullwatchApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel.shared
    @State private var acknowledgements = AcknowledgementsModel()

    var body: some Scene {
        MenuBarExtra {
            MenuView()
                .appModels(model)
        } label: {
            MenuBarLabel()
                .appModels(model)
        }
        .menuBarExtraStyle(.window)

        Window("Pullwatch", id: WindowID.main.rawValue) {
            MainView()
                .appModels(model)
                .countsAsOpenWindow(WindowID.main.rawValue)
        }
        .commands { AppCommands(model: model) }
        .windowResizability(.contentMinSize)
        .defaultLaunchBehavior(.suppressed)
        // Gestart door de helper van een agent: het venster van de vorige keer niet terugzetten.
        .restorationBehavior(AppModel.launchedByAgent ? .disabled : .automatic)

        Window("Welkom bij Pullwatch", id: WindowID.onboarding.rawValue) {
            OnboardingView()
                .appModels(model)
                .countsAsOpenWindow(WindowID.onboarding.rawValue)
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)
        // Eerste start: meteen het welkomstvenster, anders lijkt de app niet te starten.
        .defaultLaunchBehavior(model.opensOnboardingAtLaunch ? .presented : .suppressed)
        .restorationBehavior(.disabled)
        // Geen eigen onderdeel in het menu Venster: daar staat alleen Pullwatch (⌘0, `WindowCommands`).
        .commandsRemoved()

        Settings {
            SettingsView()
                .appModels(model)
                .countsAsOpenWindow("settings")
        }

        Window("Over Pullwatch", id: WindowID.about.rawValue) {
            AboutView()
                .environment(model.router)
                .countsAsOpenWindow(WindowID.about.rawValue)
        }
        .windowResizability(.contentSize)
        .windowStyle(.hiddenTitleBar)
        .defaultPosition(.center)
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)
        .commandsRemoved()

        Window("Erkenningen", id: WindowID.acknowledgements.rawValue) {
            AcknowledgementsView()
                .environment(acknowledgements)
                .countsAsOpenWindow(WindowID.acknowledgements.rawValue)
        }
        .defaultSize(width: 920, height: 620)
        .defaultPosition(.center)
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)
        .commandsRemoved()

        #if DEBUG
        // Alleen voor schermafbeeldingen (`-PullwatchMenuPreview YES`): het menupaneel als gewoon
        // venster, want een MenuBarExtra laat zich niet vanzelf openen.
        Window(Text(verbatim: "Menu"), id: "menu-preview") {
            MenuView()
                .appModels(model)
                .onAppear { SnapshotCamera.shoot("menu", windowId: "menu-preview") }
        }
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(UserDefaults.standard.bool(forKey: "PullwatchMenuPreview") ? .presented : .suppressed)
        .commandsRemoved()

        // Alleen voor schermafbeeldingen (`-PullwatchNotificationPreview YES`, met
        // `-PullwatchSkipNotificationRequest YES`): elke soort melding zoals de builder hem maakt,
        // getekend in een venster in plaats van verstuurd.
        Window(Text(verbatim: "Notifications"), id: "notification-preview") {
            NotificationPreviewGallery()
                .onAppear { SnapshotCamera.shoot("notifications", windowId: "notification-preview") }
        }
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(UserDefaults.standard.bool(forKey: "PullwatchNotificationPreview") ? .presented : .suppressed)
        .commandsRemoved()
        #endif
    }
}
