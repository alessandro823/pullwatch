import PullwatchCore
import ServiceManagement
import SwiftUI

struct SettingsView: View {
    let model: AppModel

    var body: some View {
        TabView {
            AccountsSettingsView(model: model)
                .tabItem { Label("Accounts", systemImage: "person.2") }
            GeneralSettingsView(model: model)
                .tabItem { Label("Algemeen", systemImage: "gearshape") }
        }
        .frame(minWidth: 680, minHeight: 520)
    }
}

private struct AccountsSettingsView: View {
    let model: AppModel
    @State private var selection: UUID?

    var body: some View {
        HSplitView {
            VStack(alignment: .leading, spacing: 0) {
                List(model.config.accounts, selection: $selection) { account in
                    VStack(alignment: .leading) {
                        Text(account.displayName)
                        Text("\(account.kind == .azureDevOps ? "Azure DevOps" : "GitHub") · \(account.organization)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .tag(account.id)
                }
                HStack {
                    Menu {
                        Button("Azure DevOps") { add(.azureDevOps) }
                        Button("GitHub") { add(.gitHub) }
                    } label: {
                        Image(systemName: "plus")
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    Button {
                        if let selection {
                            model.removeAccount(selection)
                            self.selection = nil
                        }
                    } label: {
                        Image(systemName: "minus")
                    }
                    .buttonStyle(.borderless)
                    .disabled(selection == nil)
                }
                .padding(6)
            }
            .frame(minWidth: 200, maxWidth: 240)

            Group {
                if let id = selection, let account = model.config.accounts.first(where: { $0.id == id }) {
                    AccountEditor(model: model, original: account).id(id)
                } else {
                    Text("Selecteer of voeg een account toe")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(minWidth: 440)
        }
    }

    private func add(_ kind: ProviderKind) {
        let account = Account(
            kind: kind,
            displayName: kind == .azureDevOps ? "Azure DevOps" : "GitHub",
            organization: "",
            authMethod: .cli
        )
        model.saveAccount(account, pat: nil)
        selection = account.id
    }
}

private struct GeneralSettingsView: View {
    let model: AppModel
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?

    private let intervals = [60, 120, 300, 600, 900]

    private func nearestInterval(_ value: Int) -> Int {
        intervals.min { abs($0 - value) < abs($1 - value) } ?? value
    }

    var body: some View {
        Form {
            Picker("Poll-interval", selection: Binding(
                get: { nearestInterval(model.config.clampedInterval) },
                set: { model.setPollInterval($0) }
            )) {
                ForEach(intervals, id: \.self) { seconds in
                    Text("\(seconds / 60) min").tag(seconds)
                }
            }
            Toggle("Starten bij inloggen", isOn: $launchAtLogin)
                .onChange(of: launchAtLogin) { _, enabled in
                    do {
                        if enabled {
                            try SMAppService.mainApp.register()
                        } else {
                            try SMAppService.mainApp.unregister()
                        }
                        loginError = nil
                    } catch {
                        loginError = error.localizedDescription
                        launchAtLogin = SMAppService.mainApp.status == .enabled
                    }
                }
            if let loginError {
                Text(loginError).font(.caption).foregroundStyle(.red)
            }
        }
        .formStyle(.grouped)
    }
}
