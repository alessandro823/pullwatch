import PullwatchCore
import SwiftUI

struct AccountEditor: View {
    let model: AppModel

    @State private var draft: Account
    @State private var pat = ""
    @State private var connectionMessage: String?
    @State private var availableRepos: [String] = []
    @State private var repoSearch = ""
    @State private var repoError: String?
    @State private var loadingRepos = false
    @State private var storedPAT = false
    @State private var saveError: String?
    @State private var testTask: Task<Void, Never>?
    @State private var reposTask: Task<Void, Never>?
    /// Accounts waarmee `gh` is ingelogd; leeg tot ze geladen zijn.
    @State private var ghAccounts: [String] = []

    init(model: AppModel, original: Account) {
        self.model = model
        _draft = State(initialValue: original)
    }

    var body: some View {
        Form {
            Section("Account") {
                TextField("Naam", text: $draft.displayName)
                TextField(draft.kind == .azureDevOps ? String(localized: "Organisatie") : String(localized: "Owner (user of org)"), text: $draft.organization)
                Picker("Authenticatie", selection: $draft.authMethod) {
                    Text("Personal Access Token").tag(AuthMethod.pat)
                    Text(draft.kind == .azureDevOps ? "Azure CLI (az login)" : "GitHub CLI (gh auth login)").tag(AuthMethod.cli)
                }
                if draft.kind == .gitHub && draft.authMethod == .cli {
                    Picker("GitHub-account", selection: $draft.cliUser) {
                        Text("Actief account in gh").tag(String?.none)
                        ForEach(ghAccountChoices, id: \.self) { login in
                            Text(verbatim: login).tag(String?.some(login))
                        }
                    }
                    .help("Welk account uit `gh auth status` het token levert; handig als je met meerdere GitHub-accounts bent ingelogd")
                    .task { ghAccounts = await GhCLIAccounts.list(runner: SystemProcessRunner()) }
                }
                if draft.authMethod == .pat {
                    SecureField(
                        storedPAT ? String(localized: "Opgeslagen — leeg laten om te behouden") : String(localized: "Token"),
                        text: $pat
                    )
                }
                HStack {
                    Button("Test verbinding") {
                        testTask?.cancel()
                        testTask = Task { await testConnection() }
                    }
                    .disabled(!hasRequiredFields || testTask != nil)
                    if let connectionMessage {
                        Text(connectionMessage).font(.caption)
                    }
                }
            }

            Section("Meldingen") {
                Toggle("Draft-PR's meenemen", isOn: $draft.includeDrafts)
                Toggle("Eigen PR's verbergen", isOn: $draft.hideOwn)
            }

            Section("Repositories") {
                Picker("Nieuwe repo's volgen", selection: $draft.newRepoDefault) {
                    Text("Niets").tag(NewRepoDefault.none)
                    Text("PR's").tag(NewRepoDefault.prs)
                }

                HStack {
                    TextField("Zoeken", text: $repoSearch)
                    Button(loadingRepos ? "Laden…" : "Repos laden") {
                        reposTask?.cancel()
                        reposTask = Task { await loadRepos() }
                    }
                    .disabled(!hasRequiredFields || reposTask != nil)
                }
                if let repoError {
                    Text(repoError).font(.caption).foregroundStyle(.red)
                }
                ScrollView {
                    Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                        GridRow {
                            Text("Repo").font(.caption).foregroundStyle(.secondary)
                            HStack(spacing: 4) {
                                Toggle("Alle PR's", sources: filteredRepos.map { binding(for: $0, \.prs) }, isOn: \.self)
                                    .tint(ItemKind.pullRequest.color)
                                    .help("PR's aan/uit voor alle zichtbare repo's")
                                    .disabled(filteredRepos.isEmpty)
                                Text("PR's").font(.caption).foregroundStyle(ItemKind.pullRequest.color)
                                AllNotifyButton(sources: filteredRepos.map { binding(for: $0, \.notifyPRs) })
                            }
                            HStack(spacing: 4) {
                                Toggle("Alle tags", sources: filteredRepos.map { binding(for: $0, \.tags) }, isOn: \.self)
                                    .tint(ItemKind.tag.color)
                                    .help("Tags aan/uit voor alle zichtbare repo's")
                                    .disabled(filteredRepos.isEmpty)
                                Text("Tags").font(.caption).foregroundStyle(ItemKind.tag.color)
                                AllNotifyButton(sources: filteredRepos.map { binding(for: $0, \.notifyTags) })
                            }
                            HStack(spacing: 4) {
                                Toggle("Alle completed", sources: filteredRepos.map { binding(for: $0, \.completed) }, isOn: \.self)
                                    .tint(PRState.merged.color)
                                    .help("Completed aan/uit voor alle zichtbare repo's")
                                    .disabled(filteredRepos.isEmpty)
                                Text("Completed").font(.caption).foregroundStyle(PRState.merged.color)
                                AllNotifyButton(sources: filteredRepos.map { binding(for: $0, \.notifyCompleted) })
                            }
                            .help("Melding als een PR in deze repo gemerged wordt (binnen ~15 minuten)")
                        }
                        Divider()
                        ForEach(filteredRepos, id: \.self) { repo in
                            GridRow {
                                Text(repo)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                watchCell(repo, \.prs, notify: \.notifyPRs, tint: ItemKind.pullRequest.color)
                                watchCell(repo, \.tags, notify: \.notifyTags, tint: ItemKind.tag.color)
                                watchCell(repo, \.completed, notify: \.notifyCompleted, tint: PRState.merged.color)
                            }
                        }
                    }
                    .toggleStyle(.checkbox)
                    .labelsHidden()
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(minHeight: 140)
            }

            VStack(alignment: .trailing, spacing: 4) {
                if let validationMessage {
                    Text(validationMessage).font(.caption).foregroundStyle(.secondary)
                }
                if let saveError {
                    Text(saveError).font(.caption).foregroundStyle(.red)
                }
                HStack {
                    Spacer()
                    Button("Opslaan") { save() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(validationMessage != nil)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { storedPAT = model.hasStoredPAT(draft.id) }
        .onDisappear {
            testTask?.cancel()
            reposTask?.cancel()
        }
    }

    /// Ook een eerder gekozen account dat `gh` nu niet (meer) kent, zodat de keuze zichtbaar blijft.
    private var ghAccountChoices: [String] {
        guard let chosen = draft.cliUser, !ghAccounts.contains(chosen) else { return ghAccounts }
        return ghAccounts + [chosen]
    }

    private var hasRequiredFields: Bool {
        !draft.displayName.trimmingCharacters(in: .whitespaces).isEmpty
            && !draft.organization.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private var validationMessage: String? {
        if !hasRequiredFields { return "Naam en organisatie zijn verplicht" }
        if draft.authMethod == .pat && pat.isEmpty && !storedPAT { return "Vul een token in" }
        return nil
    }

    private func save() {
        if model.saveAccount(draft, pat: pat.isEmpty ? nil : pat) {
            saveError = nil
            pat = ""
            storedPAT = draft.authMethod == .pat ? (storedPAT || model.hasStoredPAT(draft.id)) : false
        } else {
            saveError = "PAT opslaan in Keychain mislukt"
        }
    }

    private var filteredRepos: [String] {
        let sorted = Account.mergedRepoNames(available: availableRepos, configured: Array(draft.repoWatch.keys))
        guard !repoSearch.isEmpty else { return sorted }
        return sorted.filter { $0.localizedCaseInsensitiveContains(repoSearch) }
    }

    /// Vinkje voor volgen plus belletje voor de melding; het belletje doet pas iets als je volgt.
    private func watchCell(
        _ repo: String,
        _ field: WritableKeyPath<WatchSet, Bool>,
        notify: WritableKeyPath<WatchSet, Bool>,
        tint: Color
    ) -> some View {
        HStack(spacing: 4) {
            Toggle("Volgen", isOn: binding(for: repo, field))
                .tint(tint)
            NotifyButton(isOn: binding(for: repo, notify))
                .disabled(!draft.watch(for: repo)[keyPath: field])
        }
    }

    private func binding(for repo: String, _ field: WritableKeyPath<WatchSet, Bool>) -> Binding<Bool> {
        Binding(
            get: { draft.watch(for: repo)[keyPath: field] },
            set: { isOn in
                var watch = draft.watch(for: repo)
                watch[keyPath: field] = isOn
                draft.setWatch(watch, for: repo)
            }
        )
    }

    private func provider() -> any PRProvider {
        ProviderFactory.make(draft, pat: pat.isEmpty ? nil : pat)
    }

    private func testConnection() async {
        connectionMessage = String(localized: "Bezig…")
        defer { testTask = nil }
        do {
            let name = try await provider().testConnection()
            if Task.isCancelled { return }
            connectionMessage = "✓ " + String(localized: "Verbonden als \(name)", comment: "Naam van de ingelogde gebruiker")
        } catch let error as ProviderError {
            if Task.isCancelled { return }
            connectionMessage = "✗ \(error.userMessage)"
        } catch {
            if Task.isCancelled { return }
            connectionMessage = "✗ \(error.localizedDescription)"
        }
    }

    private func loadRepos() async {
        loadingRepos = true
        repoError = nil
        defer {
            loadingRepos = false
            reposTask = nil
        }
        do {
            let repos = try await provider().listRepos()
            if Task.isCancelled { return }
            availableRepos = repos
        } catch let error as ProviderError {
            if Task.isCancelled { return }
            repoError = error.userMessage
        } catch {
            if Task.isCancelled { return }
            repoError = error.localizedDescription
        }
    }
}

/// Belletje: wel of geen melding voor iets dat je volgt.
private struct NotifyButton: View {
    @Binding var isOn: Bool
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button {
            isOn.toggle()
        } label: {
            Image(systemName: isOn ? "bell.fill" : "bell.slash")
                .foregroundStyle(isOn && isEnabled ? Color.primary : Color.secondary)
                .opacity(isEnabled ? 1 : 0.3)
        }
        .buttonStyle(.borderless)
        .help(isOn ? String(localized: "Melding aan; klik om alleen te volgen zonder melding") : String(localized: "Geen melding; staat wel in menu en geschiedenis"))
    }
}

/// Belletje in de kop: alles aan, of alles uit als alles al aan staat.
private struct AllNotifyButton: View {
    let sources: [Binding<Bool>]

    private var allOn: Bool { sources.allSatisfy(\.wrappedValue) }

    var body: some View {
        Button {
            let target = !allOn
            for source in sources { source.wrappedValue = target }
        } label: {
            Image(systemName: allOn ? "bell.fill" : "bell.slash")
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.borderless)
        .disabled(sources.isEmpty)
        .help(allOn ? String(localized: "Meldingen uit voor alle zichtbare repo's") : String(localized: "Meldingen aan voor alle zichtbare repo's"))
    }
}
