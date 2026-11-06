import PullwatchCore
import PullwatchGitHub
import SwiftUI

/// Laat een venster de Toevoegen-knop van een account-editor in zijn eigen voetbalk zetten (het
/// welkomstvenster, het toevoeg-venster), in plaats van onderaan in het scrollende formulier.
/// De editor houdt bij of het account af is en waarom niet; de voetbalk roept `save()` aan.
@Observable
final class AccountSaveAction {
    /// Waarom het nog niet kan ("Log eerst in bij GitHub"); nil als Toevoegen kan.
    fileprivate(set) var blockedReason: LocalizedStringKey?
    fileprivate(set) var error: String?
    @ObservationIgnored fileprivate var perform: () -> Void = {}

    var canSave: Bool { blockedReason == nil }

    func save() { perform() }
}

struct AccountEditor: View {
    /// Uit de environment kan pas in `body`; `init` heeft de accounts nodig voor `isNew`.
    let accounts: AccountsModel
    @Environment(AppModel.self) private var app
    @Environment(AppRouter.self) private var router

    @State private var draft: Account
    @State private var pat = ""
    @State private var connection: ConnectionTest?
    /// De repositories van de dienst; de vorige lijst blijft staan zolang een nieuwe laadt.
    @State private var availableRepos: [String] = []
    @State private var isLoadingRepos = false
    @State private var repoError: String?
    /// Opnieuw laden met de knop.
    @State private var reloadCount = 0
    @State private var storedPAT = false
    @State private var saveError: String?
    @State private var testTask: Task<Void, Never>?
    /// Accounts waarmee `gh` is ingelogd; leeg tot ze geladen zijn.
    @State private var ghAccounts: [String] = []
    /// GitHub App: hoe `gh` er op de host voor staat, voor de packages; nil tot het bekend is.
    @State private var ghStatus: GhCLIStatus?
    /// Inloggen met GitHub voor dit account (code, goedkeuring, installaties); nil bij een
    /// andere manier van inloggen.
    @State private var signIn: GitHubSignIn?
    /// GitLab en GitHub Enterprise: het adres van de server zoals getypt; `draft.instanceURL` volgt
    /// zodra het geldig is.
    @State private var instanceText: String
    /// Op een eigen server in plaats van github.com of gitlab.com: GitHub Enterprise (Server of
    /// GHE.com), of een eigen GitLab-server. Alleen dan staat er een veld voor het adres.
    private let isEnterprise: Bool
    /// GitLab: de groepen en gebruikers, Bitbucket: de workspaces, zoals getypt, met komma's;
    /// `draft.owners` volgt.
    @State private var ownersText: String
    /// Bitbucket: het e-mailadres van het Atlassian-account zoals getypt; `draft.email` volgt.
    @State private var emailText: String
    /// Hoe het account inlogde toen de editor openging; een bestaand `gh`-account houdt die keuze.
    private let originalAuthMethod: AuthMethod

    /// Een nieuw account (nog niet in de config): de knop heet Toevoegen, en pas dan wordt
    /// er iets bewaard.
    private let isNew: Bool
    /// Na een geslaagd bewaren, bijvoorbeeld om het venster te sluiten.
    private let onSaved: () -> Void

    /// Zet de Toevoegen-knop buiten de editor (in een voetbalk); nil: de editor toont hem zelf.
    private let saveAction: AccountSaveAction?

    /// `enterprise`: een nieuw account op een eigen server, GitHub Enterprise of een eigen
    /// GitLab-server (de keuze in het welkomstvenster of het toevoeg-menu).
    init(
        accounts: AccountsModel, original: Account, enterprise: Bool = false, saveAction: AccountSaveAction? = nil,
        onSaved: @escaping () -> Void = {}
    ) {
        self.accounts = accounts
        self.saveAction = saveAction
        _draft = State(initialValue: original)
        // Een adres uit de config dat niet bruikbaar is, staat in het veld zoals het er stond.
        _instanceText = State(initialValue: original.instanceURL?.absoluteString ?? original.unusableInstanceURL ?? "")
        isEnterprise = switch original.kind {
        case .gitHub: enterprise || original.isGitHubEnterprise || original.unusableInstanceURL != nil
        case .gitLab: enterprise || original.instanceURL != nil || original.unusableInstanceURL != nil
        // Forgejo en Gitea: een eigen server (bij Gitea mag het veld leeg: gitea.com); Codeberg niet.
        case .gitea: original.giteaFlavour.allowsOwnServer
        case .azureDevOps, .bitbucket: false
        }
        _ownersText = State(initialValue: original.owners.joined(separator: ", "))
        _emailText = State(initialValue: original.email ?? "")
        originalAuthMethod = original.authMethod
        isNew = !accounts.config.accounts.contains { $0.id == original.id }
        self.onSaved = onSaved
    }

    /// Inloggen met GitHub kan zodra de GitHub App is ingesteld, en alleen op github.com: op
    /// GitHub Enterprise bestaat de Pullwatch-app niet (daar zou hij per server geregistreerd
    /// moeten zijn).
    private var offersGitHubApp: Bool {
        draft.kind == .gitHub && !isEnterprise && (accounts.gitHubApp.isConfigured || originalAuthMethod == .gitHubApp)
    }

    /// `gh` alleen nog voor accounts die het al gebruiken, of zolang er geen GitHub App is; op
    /// GitHub Enterprise altijd (`gh auth login --hostname`). Bitbucket heeft geen officiële CLI
    /// die een token leesbaar bewaart, dus daar nooit.
    private var offersCLI: Bool {
        switch draft.kind {
        // Gitea, Forgejo en Codeberg: `tea` heeft geen commando dat zijn token geeft.
        case .bitbucket, .gitea: false
        case .gitHub: isEnterprise || originalAuthMethod == .cli || !accounts.gitHubApp.isConfigured
        case .azureDevOps, .gitLab: true
        }
    }

    /// Bitbucket logt alleen in met een API-token: dan valt er niets te kiezen.
    private var offersChoice: Bool {
        offersGitHubApp || offersCLI
    }

    /// Bitbucket: het e-mailadres van het Atlassian-account hoort bij het token.
    private var needsEmail: Bool {
        draft.kind == .bitbucket
    }

    /// Of er een veld voor het adres van de server staat.
    private var showsServerField: Bool {
        isEnterprise
    }

    /// De host waarvoor `gh` het token geeft.
    private var ghHost: String {
        GitHubEndpoints(instanceURL: draft.effectiveInstanceURL).cliHost
    }

    private var cliName: LocalizedStringKey {
        switch draft.kind {
        case .azureDevOps: "Azure CLI (az login)"
        case .gitHub: "GitHub CLI (gh auth login)"
        case .gitLab: "GitLab CLI (glab auth login)"
        case .bitbucket: "API-token met scopes"
        // Nooit getoond (`offersCLI`); een oud account met `cli` leest het token uit de Keychain.
        case .gitea: "Personal Access Token"
        }
    }

    /// Een getypt adres dat geen https-adres is.
    private var instanceTextIsInvalid: Bool {
        showsServerField && !instanceText.trimmingCharacters(in: .whitespaces).isEmpty
            && InstanceURL.parse(instanceText, for: draft.kind) == nil
    }

    /// Moet het veld een adres hebben? GitHub Enterprise en een eigen GitLab-server wel (leeg zou
    /// het token naar github.com of gitlab.com sturen); bij Gitea is leeg gitea.com, en Forgejo
    /// zonder server ziet `Account.serverProblem` zelf.
    private var requiresServer: Bool {
        isEnterprise && draft.kind != .gitea
    }

    /// Een eigen server zonder adres (`Account.serverProblem`).
    private var lacksEnterpriseServer: Bool {
        draft.serverProblem == .missing
    }

    /// Waar je een token maakt, met de naam en de scopes al ingevuld: bij GitLab, en op een GitHub
    /// Enterprise-server (een classic token; een fine-grained token kan ook).
    private var tokenPage: URL? {
        guard let base = draft.effectiveInstanceURL else { return nil }
        switch draft.kind {
        case .gitLab:
            return URL(string: base.absoluteString + "/-/user_settings/personal_access_tokens?name=Pullwatch&scopes=read_api")
        case .bitbucket:
            // Atlassian kan de scopes niet vooraf invullen; de hint noemt ze.
            return URL(string: "https://id.atlassian.com/manage-profile/security/api-tokens")
        case .gitea:
            // Gitea en Forgejo vullen geen naam of scopes in vanuit de link; de pagina met tokens.
            return URL(string: base.absoluteString + "/user/settings/applications")
        case .gitHub where draft.isGitHubEnterprise:
            return URL(string: base.absoluteString + "/settings/tokens/new?description=Pullwatch&scopes=repo,read:org")
        default:
            return nil
        }
    }

    private var tokenHint: LocalizedStringKey {
        switch draft.kind {
        case .gitLab: "Een personal access token met de scope read_api"
        case .bitbucket: "Kies Create API token with scopes, dan Bitbucket, met read:user:bitbucket, read:repository:bitbucket en read:pullrequest:bitbucket"
        case .gitea: "Een token met de scopes read:user, read:organization, read:repository en read:issue"
        default: "Een classic token met de scopes repo en read:org, of een fine-grained token met leestoegang"
        }
    }

    /// Het veld met eigenaren (GitLab, Bitbucket, Gitea): label, voorbeeld en hulp per dienst.
    private var ownersLabel: String {
        switch draft.kind {
        case .bitbucket: String(localized: "Workspaces")
        case .gitea: String(localized: "Organisaties of gebruikers")
        default: String(localized: "Groepen of gebruikers")
        }
    }

    private var ownersPrompt: String {
        switch draft.kind {
        case .bitbucket: "acme, acme-labs"
        case .gitea: "acme, jdoe"
        default: "acme, acme/platform"
        }
    }

    private var ownersHelp: LocalizedStringKey {
        switch draft.kind {
        case .bitbucket: "Scheid meerdere met een komma. De workspace staat in de link: bitbucket.org/workspace/repo."
        case .gitea: "Scheid meerdere met een komma."
        default: "Scheid meerdere met een komma. Een groep volgt ook zijn subgroepen."
        }
    }

    /// Een voorbeeld van een eigen server in het veld.
    private var serverPrompt: String {
        switch draft.kind {
        case .gitLab: "https://gitlab.example.com"
        case .gitea: draft.giteaFlavour == .forgejo ? "https://forgejo.example.com" : "https://gitea.com"
        default: "https://github.example.com"
        }
    }

    private var invalidServerHint: LocalizedStringKey {
        switch draft.kind {
        case .gitLab: "Alleen een https-adres, bijvoorbeeld https://gitlab.example.com"
        case .gitea: "Alleen een https-adres met een geldig certificaat, bijvoorbeeld https://git.example.com"
        default: "Alleen een https-adres, bijvoorbeeld https://github.example.com of https://acme.ghe.com"
        }
    }

    var body: some View {
        Form {
            Section {
                if isNew && offersChoice {
                    Picker("Authenticatie", selection: $draft.authMethod) {
                        if offersGitHubApp {
                            Text("Inloggen met GitHub").tag(AuthMethod.gitHubApp)
                        }
                        Text("Personal Access Token").tag(AuthMethod.pat)
                        if offersCLI {
                            Text(cliName).tag(AuthMethod.cli)
                        }
                    }
                } else {
                    // Een bestaand account houdt zijn manier van inloggen; anders opnieuw toevoegen.
                    LabeledContent("Authenticatie") { Text(methodName) }
                }
                if draft.authMethod == .gitHubApp, let signIn {
                    GitHubSignInRow(signIn: signIn)
                }
                // Eerst hoe je inlogt, dan waar de repositories staan, dan het token. De naam volgt de
                // organisatie (`Account.displayName`); met de GitHub App komt de eigenaar uit het
                // inloggen, dan valt er niets te typen.
                if showsServerField {
                    // Een eigen server alleen via https (het token gaat erheen).
                    TextField(
                        String(localized: "Server"), text: $instanceText,
                        prompt: Text(verbatim: serverPrompt)
                    )
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("account.instanceURL")
                    .onChange(of: instanceText) { _, text in
                        // Zolang het adres niet bruikbaar is, gaat het account nergens heen
                        // (`unusableInstanceURL`), ook niet naar de standaard van de dienst.
                        let typed = text.trimmingCharacters(in: .whitespaces)
                        if let url = InstanceURL.parse(text, for: draft.kind) {
                            draft.instanceURL = url == draft.defaultInstanceURL ? nil : url
                            draft.unusableInstanceURL = nil
                        } else if typed.isEmpty && !requiresServer {
                            draft.instanceURL = nil
                            draft.unusableInstanceURL = nil
                        } else {
                            draft.instanceURL = nil
                            draft.unusableInstanceURL = typed
                        }
                    }
                    if instanceTextIsInvalid {
                        Text(invalidServerHint)
                            .font(.caption)
                            .foregroundStyle(.red)
                    } else if draft.kind == .gitea {
                        Text(draft.giteaFlavour == .forgejo
                             ? "Je eigen Forgejo-server, via https"
                             : "Leeg is gitea.com; anders je eigen Gitea-server, via https")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else if draft.kind == .gitHub {
                        Text("GitHub Enterprise Server, of je eigen subdomein op ghe.com")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                if draft.kind == .gitLab || draft.kind == .bitbucket || draft.kind == .gitea {
                    TextField(
                        ownersLabel,
                        text: $ownersText,
                        prompt: Text(verbatim: ownersPrompt)
                    )
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("account.organization")
                    .help(ownersHelp)
                    .onChange(of: ownersText) { _, text in
                        let owners = text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                        if owners != draft.owners { draft.owners = owners }
                    }
                } else if draft.authMethod != .gitHubApp {
                    // Een voorbeeld in het veld, zodat je ziet waar je typt en wat er hoort.
                    TextField(
                        draft.kind == .azureDevOps ? String(localized: "Organisatie") : String(localized: "Owner (user of org)"),
                        text: $draft.organization,
                        prompt: Text(verbatim: draft.kind == .azureDevOps ? "contoso" : "octocat")
                    )
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("account.organization")
                }
                if draft.kind == .gitHub && draft.authMethod == .cli {
                    Picker("GitHub-account", selection: $draft.cliUser) {
                        Text("Actief account in gh").tag(String?.none)
                        ForEach(ghAccountChoices, id: \.self) { login in
                            Text(verbatim: login).tag(String?.some(login))
                        }
                    }
                    .help("Welk account uit `gh auth status` het token levert; handig als je met meerdere GitHub-accounts bent ingelogd")
                    .task(id: ghHost) { ghAccounts = await GhCLIAccounts.list(runner: SystemProcessRunner(), host: ghHost) }
                    if draft.isGitHubEnterprise {
                        Text("Log eerst in met `gh auth login --hostname \(ghHost)`.", comment: "De host van de GitHub Enterprise-server")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                if needsEmail {
                    TextField(String(localized: "E-mailadres"), text: $emailText, prompt: Text(verbatim: "name@example.com"))
                        .textContentType(.emailAddress)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("account.email")
                        .help("Het e-mailadres van je Atlassian-account; Bitbucket wil het samen met het API-token.")
                        .onChange(of: emailText) { _, text in
                            let email = text.trimmingCharacters(in: .whitespaces)
                            draft.email = email.isEmpty ? nil : email
                        }
                }
                if draft.authMethod == .pat {
                    SecureField(
                        storedPAT
                            ? String(localized: "Opgeslagen, laat leeg om te behouden")
                            : (draft.kind == .bitbucket ? String(localized: "API-token") : String(localized: "Token")),
                        text: $pat
                    )
                    .accessibilityIdentifier("account.token")
                    if let tokenPage {
                        LabeledContent {
                            Link("Token maken", destination: tokenPage)
                        } label: {
                            Text(tokenHint)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    if !isNew && !pat.isEmpty {
                        HStack {
                            Spacer()
                            Button("Token bewaren") { save() }
                        }
                    }
                }
                if draft.authMethod != .gitHubApp {
                    LabeledContent {
                        Button("Test verbinding") {
                            testTask?.cancel()
                            testTask = Task { await testConnection() }
                        }
                        .disabled(!hasRequiredFields || testTask != nil)
                    } label: {
                        Text("Verbinding")
                        connectionStatus
                    }
                    .accessibilityIdentifier("account.connection")
                }
            } header: {
                Text("Inloggen")
            } footer: {
                if draft.kind == .bitbucket {
                    Text("Bitbucket kent geen releases: bij Tags en releases staan voor dit account alleen tags.")
                }
            }

            if draft.authMethod == .gitHubApp, let signIn, signIn.isSignedIn {
                Section("Repositories van") {
                    GitHubInstallationsRow(signIn: signIn, owners: $draft.owners)
                }
            }

            // GitHubs Packages-API weigert het token van de GitHub App: de packages komen via `gh`.
            // Zolang de keuze niet gemaakt is: aan als `gh` op deze host is ingelogd.
            if draft.kind == .gitHub && draft.authMethod == .gitHubApp {
                Section("Packages") {
                    PackagesCLIRow(
                        isOn: Binding(
                            get: { draft.packagesViaCLI ?? (ghStatus.map { $0.user != nil } ?? true) },
                            set: { draft.packagesViaCLI = $0 }
                        ),
                        status: ghStatus, login: draft.login, host: ghHost
                    )
                    .task(id: ghHost) { ghStatus = await GhCLIAccounts.status(runner: SystemProcessRunner(), host: ghHost) }
                }
            }

            Section {
                // GitLab noemt ze merge requests, dus hier ook.
                // Melden kan alleen als drafts te zien zijn.
                if draft.kind == .gitLab {
                    Toggle("Draft-merge requests tonen", isOn: $draft.showDrafts)
                    Toggle("Draft-merge requests melden", isOn: $draft.includeDrafts)
                        .disabled(!draft.showDrafts)
                    Toggle("Eigen merge requests verbergen", isOn: $draft.hideOwn)
                } else {
                    Toggle("Draft-PR's tonen", isOn: $draft.showDrafts)
                    Toggle("Draft-PR's melden", isOn: $draft.includeDrafts)
                        .disabled(!draft.showDrafts)
                    Toggle("Eigen PR's verbergen", isOn: $draft.hideOwn)
                }
            } header: {
                Text(draft.kind == .gitLab ? "Welke merge requests tellen mee" : "Welke PR's tellen mee")
            } footer: {
                Text("Zonder tonen staan drafts nergens en komt een draft binnen zodra hij klaar is voor review. Verbergen geldt overal.")
            }

            if draft.isComplete {
                RepoFollowList(
                    account: $draft, pat: pat.isEmpty ? nil : pat,
                    available: availableRepos, isLoading: isLoadingRepos, error: repoError,
                    reload: { reloadCount += 1 },
                    openRepo: isNew ? nil : { repo in
                        app.showRepo(accountId: draft.id, repo: repo)
                        router.show(.main)
                    }
                )
            }

            // Een bewaard account in één keer uitzetten, zonder de keuzes kwijt te raken.
            if !isNew {
                Section {
                    Toggle("Dit account ophalen", isOn: Binding(
                        get: { !draft.isPaused },
                        set: { draft.isPaused = !$0 }
                    ))
                } footer: {
                    Text("Uit: Pullwatch haalt niets op voor dit account en stuurt er geen meldingen over. Wat je volgt blijft bewaard.")
                }
            }

            if isNew && saveAction == nil {
            VStack(alignment: .trailing, spacing: 4) {
                if let validationMessage {
                    Text(validationMessage).font(.caption).foregroundStyle(.secondary)
                }
                if let saveError {
                    Text(saveError).font(.caption).foregroundStyle(.red)
                }
                HStack {
                    Spacer()
                    Button(isNew ? "Toevoegen" : "Opslaan") { save() }
                        .keyboardShortcut(.defaultAction)
                        .accessibilityIdentifier("account.save")
                        .disabled(validationMessage != nil)
                }
            }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            storedPAT = accounts.hasStoredPAT(draft.id)
            saveAction?.perform = { save() }
            saveAction?.blockedReason = validationMessage
        }
        .onChange(of: validationMessage) { _, message in saveAction?.blockedReason = message }
        .onChange(of: saveError) { _, error in saveAction?.error = error }
        .task(id: draft.authMethod) {
            guard draft.authMethod == .gitHubApp else {
                signIn = nil
                return
            }
            let signIn = self.signIn ?? GitHubSignIn(accounts: accounts, accountId: draft.id)
            self.signIn = signIn
            // Terug in de app (bijvoorbeeld van de installatiepagina op github.com): opnieuw kijken.
            for await _ in NotificationCenter.default.notifications(named: NSApplication.didBecomeActiveNotification) {
                await signIn.refreshInstallations()
            }
        }
        #if DEBUG
        .onChange(of: signIn?.phase) { _, phase in
            let name = switch phase {
            case .signedOut, nil: "signed-out"
            case .requestingCode: "requesting-code"
            case .waitingForApproval: "waiting-for-approval"
            case .signedIn: "signed-in"
            }
            SnapshotCamera.shoot("github-\(name)")
        }
        .onChange(of: signIn?.waitingForInstall) { _, waiting in
            if waiting == true { SnapshotCamera.shoot("github-waiting-for-install") }
        }
        .onChange(of: availableRepos) { _, _ in SnapshotCamera.shoot("github-repositories") }
        #endif
        .onChange(of: signIn?.installations) { old, installations in
            guard case .found(let found) = installations else { return }
            let logins = found.map(\.login)
            switch old {
            case .found(let before)?:
                // Terwijl dit venster open is ergens anders geïnstalleerd: die nieuwe plek volgen.
                let known = before.map(\.login)
                draft.owners += logins.filter { !known.contains($0) && !draft.owners.contains($0) }
            case .none?:
                // Daarnet nog nergens geïnstalleerd, nu wel: wat er nu staat volgen.
                draft.owners += logins.filter { !draft.owners.contains($0) }
            case .unknown?, nil:
                // De lijst voor het eerst: een nieuw account volgt alles, een bestaand blijft zoals het was.
                if isNew && draft.owners.isEmpty { draft.owners = logins }
            }
        }
        .onChange(of: signIn?.login) { _, login in
            if let login { draft.login = login }
        }
        // Bestaand account: elke wijziging meteen bewaren (geen Opslaan in Instellingen).
        .onChange(of: draft) { _, account in
            if !isNew { app.updateAccount(account) }
        }
        // De repositories laden vanzelf, opnieuw als de plekken of het inloggen veranderen.
        .task(id: RepoLoad(owners: draft.owners, email: draft.email, instanceURL: draft.instanceURL, method: draft.authMethod, cliUser: draft.cliUser, hasNewToken: !pat.isEmpty, signedIn: signIn?.isSignedIn ?? false, reload: reloadCount)) {
            await loadRepos()
        }
        .onDisappear {
            testTask?.cancel()
        }
    }

    /// Uitkomst van Test verbinding, met een symbool en een systeemkleur in plaats van tekens.
    private enum ConnectionTest: Equatable {
        case testing
        case connected(String)
        case failed(String)
    }

    @ViewBuilder private var connectionStatus: some View {
        switch connection {
        case nil:
            EmptyView()
        case .testing:
            Text("Bezig…")
        case .connected(let name):
            Label {
                Text("Verbonden als \(name)", comment: "Naam van de ingelogde gebruiker")
            } icon: {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            }
        case .failed(let message):
            Label {
                Text(verbatim: message)
            } icon: {
                Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
            }
        }
    }

    /// Ook een eerder gekozen account dat `gh` nu niet (meer) kent, zodat de keuze zichtbaar blijft.
    private var ghAccountChoices: [String] {
        guard let chosen = draft.cliUser, !ghAccounts.contains(chosen) else { return ghAccounts }
        return ghAccounts + [chosen]
    }

    /// Eigenaar, server en bij Bitbucket het e-mailadres (`Account.isComplete`).
    private var hasRequiredFields: Bool { draft.isComplete }

    private var validationMessage: LocalizedStringKey? {
        if draft.authMethod == .gitHubApp && signIn?.isSignedIn != true { return "Log eerst in bij GitHub" }
        if draft.authMethod == .gitHubApp && !draft.hasOwner { return "Volg minstens één plek" }
        if instanceTextIsInvalid { return "Vul een https-adres in voor de server" }
        if lacksEnterpriseServer {
            switch draft.kind {
            case .gitLab: return "Vul het adres van je GitLab-server in"
            case .gitea: return "Vul het adres van je Forgejo-server in"
            default: return "Vul het adres van je GitHub Enterprise-server in"
            }
        }
        if draft.serverProblem != nil { return "Vul een https-adres in voor de server" }
        if !draft.hasOwner {
            switch draft.kind {
            case .azureDevOps: return "Vul de organisatie in"
            case .gitHub: return "Vul de owner in"
            case .gitLab: return "Vul een groep of gebruiker in"
            case .bitbucket: return "Vul een workspace in"
            case .gitea: return "Vul een organisatie of gebruiker in"
            }
        }
        if draft.lacksEmail { return "Vul het e-mailadres van je Atlassian-account in" }
        if draft.authMethod == .pat && pat.isEmpty && !storedPAT { return "Vul een token in" }
        return nil
    }

    private func save() {
        if app.saveAccount(draft, pat: pat.isEmpty ? nil : pat) {
            onSaved()
            saveError = nil
            pat = ""
            storedPAT = draft.authMethod == .pat ? (storedPAT || accounts.hasStoredPAT(draft.id)) : false
        } else {
            saveError = String(localized: "PAT opslaan in Keychain mislukt")
        }
    }

    private func provider() -> any PRProvider {
        accounts.provider(for: draft, pat: pat.isEmpty ? nil : pat)
    }

    private func testConnection() async {
        connection = .testing
        defer { testTask = nil }
        do {
            let name = try await provider().testConnection()
            if Task.isCancelled { return }
            connection = .connected(name)
        } catch let error as ProviderError {
            if Task.isCancelled { return }
            connection = .failed(error.userMessage)
        } catch {
            if Task.isCancelled { return }
            connection = .failed(error.localizedDescription)
        }
    }

    /// Wanneer de repositories opnieuw moeten laden.
    private struct RepoLoad: Equatable {
        let owners: [String]
        let email: String?
        let instanceURL: URL?
        let method: AuthMethod
        let cliUser: String?
        let hasNewToken: Bool
        let signedIn: Bool
        let reload: Int
    }

    private var methodName: LocalizedStringKey {
        switch draft.authMethod {
        case .gitHubApp: "Inloggen met GitHub"
        case .pat: draft.kind == .bitbucket ? "API-token met scopes" : "Personal Access Token"
        case .cli: cliName
        }
    }

    private func loadRepos() async {
        guard hasRequiredFields, draft.authMethod != .gitHubApp || signIn?.isSignedIn == true,
              draft.authMethod != .pat || storedPAT || !pat.isEmpty else {
            isLoadingRepos = false
            return
        }
        isLoadingRepos = true
        repoError = nil
        defer { if !Task.isCancelled { isLoadingRepos = false } }
        do {
            let repos = try await accounts.repositories(for: draft, pat: pat.isEmpty ? nil : pat)
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
