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
                        model.hasStoredPAT(draft.id) ? "Opgeslagen — leeg laten om te behouden" : "Token",
                        text: $pat
                    )
                }
                HStack {
                    Button("Test verbinding") { Task { await testConnection() } }
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
                Picker("Modus", selection: $draft.filterMode) {
                    Text("Alles volgen behalve aangevinkte").tag(FilterMode.deny)
                    Text("Alleen aangevinkte volgen").tag(FilterMode.allow)
                }
                .pickerStyle(.radioGroup)

                HStack {
                    TextField("Zoeken", text: $repoSearch)
                    Button(loadingRepos ? "Laden…" : "Repos laden") { Task { await loadRepos() } }
                        .disabled(loadingRepos)
                }
                if let repoError {
                    Text(repoError).font(.caption).foregroundStyle(.red)
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(filteredRepos, id: \.self) { repo in
                            Toggle(repo, isOn: binding(for: repo))
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(minHeight: 140)
            }

            HStack {
                Spacer()
                Button("Opslaan") {
                    model.saveAccount(draft, pat: pat.isEmpty ? nil : pat)
                    pat = ""
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .formStyle(.grouped)
    }

    private var filteredRepos: [String] {
        let all = Set(availableRepos).union(draft.repos)
        let sorted = all.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        guard !repoSearch.isEmpty else { return sorted }
        return sorted.filter { $0.localizedCaseInsensitiveContains(repoSearch) }
    }

    private func binding(for repo: String) -> Binding<Bool> {
        Binding(
            get: { draft.repos.contains { $0.caseInsensitiveCompare(repo) == .orderedSame } },
            set: { isOn in
                if isOn {
                    draft.repos.append(repo)
                } else {
                    draft.repos.removeAll { $0.caseInsensitiveCompare(repo) == .orderedSame }
                }
            }
        )
    }

    private func provider() -> any PRProvider {
        ProviderFactory.make(draft, pat: pat.isEmpty ? nil : pat)
    }

    private func testConnection() async {
        connectionMessage = "Bezig…"
        do {
            let id = try await provider().currentUserId()
            connectionMessage = "✓ Verbonden (\(id))"
        } catch let error as ProviderError {
            connectionMessage = "✗ \(error.userMessage)"
        } catch {
            connectionMessage = "✗ \(error.localizedDescription)"
        }
    }

    private func loadRepos() async {
        loadingRepos = true
        repoError = nil
        defer { loadingRepos = false }
        do {
            availableRepos = try await provider().listRepos()
        } catch let error as ProviderError {
            repoError = error.userMessage
        } catch {
            repoError = error.localizedDescription
        }
    }
}
