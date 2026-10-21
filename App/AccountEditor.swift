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

    init(model: AppModel, original: Account) {
        self.model = model
        _draft = State(initialValue: original)
    }

    var body: some View {
        Form {
            Section("Account") {
                TextField("Naam", text: $draft.displayName)
                TextField(draft.kind == .azureDevOps ? "Organisatie" : "Owner (user of org)", text: $draft.organization)
                Picker("Authenticatie", selection: $draft.authMethod) {
                    Text("Personal Access Token").tag(AuthMethod.pat)
                    Text(draft.kind == .azureDevOps ? "Azure CLI (az login)" : "GitHub CLI (gh auth login)").tag(AuthMethod.cli)
                }
                if draft.authMethod == .pat {
                    SecureField(
                        storedPAT ? "Opgeslagen — leeg laten om te behouden" : "Token",
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
                            Text("PR's").font(.caption).foregroundStyle(ItemKind.pullRequest.color)
                            HStack(spacing: 4) {
                                Toggle("Alle tags", sources: filteredRepos.map { binding(for: $0, \.tags) }, isOn: \.self)
                                    .tint(ItemKind.tag.color)
                                    .help("Tags aan/uit voor alle zichtbare repo's")
                                    .disabled(filteredRepos.isEmpty)
                                Text("Tags").font(.caption).foregroundStyle(ItemKind.tag.color)
                            }
                            HStack(spacing: 4) {
                                Toggle("Alle completed", sources: filteredRepos.map { binding(for: $0, \.completed) }, isOn: \.self)
                                    .tint(PRState.merged.color)
                                    .help("Completed aan/uit voor alle zichtbare repo's")
                                    .disabled(filteredRepos.isEmpty)
                                Text("Completed").font(.caption).foregroundStyle(PRState.merged.color)
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
                                Toggle("PR's", isOn: binding(for: repo, \.prs))
                                    .tint(ItemKind.pullRequest.color)
                                Toggle("Tags", isOn: binding(for: repo, \.tags))
                                    .tint(ItemKind.tag.color)
                                Toggle("Completed", isOn: binding(for: repo, \.completed))
                                    .tint(PRState.merged.color)
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
        connectionMessage = "Bezig…"
        defer { testTask = nil }
        do {
            let name = try await provider().testConnection()
            if Task.isCancelled { return }
            connectionMessage = "✓ Verbonden als \(name)"
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
