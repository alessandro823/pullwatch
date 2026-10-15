# Pullwatch — design

Datum: 2026-10-15
Status: goedgekeurd in brainstorm, wacht op review van spec

## Doel

Een macOS menubar-app die nieuwe pull requests in Azure DevOps en GitHub detecteert en daar een macOS-melding van geeft. Klikken op de melding opent de PR in de browser.

**Voor wie:** één gebruiker (eigen Mac), meerdere accounts/organisaties over beide providers.

**Succescriteria**

- Nieuwe PR in een gevolgde repo → melding binnen één poll-interval (standaard 2 min).
- Klik op melding → PR opent in standaardbrowser.
- Geen dubbele meldingen, ook niet na herstart van de app.
- Geen meldingen voor al bestaande PR's bij eerste start, nieuw account of nieuw toegevoegde repo.
- Eigen PR's standaard verborgen; draft-PR's standaard verborgen.

## Scope

**In v1**

- Providers: Azure DevOps (dev.azure.com) en GitHub (github.com).
- Meerdere accounts, mix van providers.
- Auth per account: PAT (Keychain) of CLI-token (`az` / `gh`).
- Event: alleen "nieuwe PR" (inclusief draft → ready-for-review als drafts uit staan).
- Repo-filter per account: allowlist of denylist.
- Toggles per account: drafts meenemen, eigen PR's verbergen.
- Menubar-menu met recente nieuwe PR's, settings-venster, start bij inloggen.

**Buiten v1**

- Review-requests, statuswijzigingen (merged/closed), comments, nieuwe commits.
- Azure DevOps Server (on-prem), GitHub Enterprise Server.
- Distributie buiten eigen Mac (notarization, auto-update).

## Aanpak

Native Swift / SwiftUI app. Geen externe dependencies. Swift 6 language mode.

- `MenuBarExtra` voor de menubar, `LSUIElement = YES` (geen Dock-icoon).
- `UserNotifications` voor meldingen.
- Keychain (Security framework) voor PAT's.
- `URLSession` voor REST.
- `SMAppService.mainApp` voor start bij inloggen.

## Architectuur

```
Pullwatch.app (SwiftUI)
├── MenuBarExtra        → icoon + badge, recente nieuwe PR's, acties
├── SettingsWindow      → accounts, repo-filter, interval, toggles
│
├── PollScheduler       → timer, per account poll(), backoff, wake-handling
├── PRProvider (protocol)
│     ├── AzureDevOpsProvider
│     └── GitHubProvider
├── TokenSource (protocol)
│     ├── KeychainPATSource
│     ├── AzCLISource
│     └── GhCLISource
├── PRFilter            → pure functie
├── SeenStore           → gezien-ids met timestamp, JSON op schijf
├── Notifier            → UNUserNotificationCenter + klik-afhandeling
└── ConfigStore         → accounts + instellingen als JSON (zonder tokens)
```

Code is opgesplitst in twee targets:

- **`PullwatchCore`** (framework): modellen, providers, token sources, filter, seen store, scheduler-logica, config store. Geen AppKit/SwiftUI. Volledig unit-testbaar.
- **`Pullwatch`** (app): SwiftUI views, `Notifier`, app lifecycle, koppeling met `NSWorkspace`.

### Kernmodellen

```swift
enum ProviderKind: String, Codable { case azureDevOps, gitHub }
enum AuthMethod: String, Codable { case pat, cli }
enum FilterMode: String, Codable { case allow, deny }

struct Account: Codable, Identifiable {
    let id: UUID
    var kind: ProviderKind
    var displayName: String
    var organization: String      // DevOps org of GitHub owner (user/org)
    var authMethod: AuthMethod
    var filterMode: FilterMode
    var repos: [String]           // DevOps: "project/repo", GitHub: "owner/repo"
    var includeDrafts: Bool       // default false
    var hideOwn: Bool             // default true
}

struct PullRequest: Codable, Hashable {
    let accountId: UUID
    let repo: String              // zelfde formaat als Account.repos
    let number: Int
    let title: String
    let authorId: String
    let authorName: String
    let isDraft: Bool
    let createdAt: Date
    let webURL: URL
    var dedupKey: String { "\(accountId):\(repo):\(number)" }
}
```

### Protocollen

```swift
protocol TokenSource: Sendable {
    func token() async throws -> String
}

protocol PRProvider: Sendable {
    /// Identiteit van ingelogde gebruiker, voor "eigen PR's verbergen".
    func currentUserId() async throws -> String
    /// Alle repos die het account kan zien (voor de repo-picker).
    func listRepos() async throws -> [String]
    /// Alle open PR's (inclusief drafts), ongefilterd.
    func openPullRequests() async throws -> [PullRequest]
}

protocol HTTPClient: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

protocol ProcessRunner: Sendable {
    func run(_ executable: URL, _ args: [String]) async throws -> String
}
```

## Providers

### Azure DevOps

- Base: `https://dev.azure.com/{org}`, `api-version=7.1`.
- Auth: PAT → `Authorization: Basic base64(":" + pat)`; CLI-token → `Authorization: Bearer {token}`.
- Identiteit: `GET /_apis/connectionData` → `authenticatedUser.id`.
- Projecten: `GET /_apis/projects` (gecached, elk uur ververst).
- Repos: `GET /{project}/_apis/git/repositories`.
- Open PR's: per project `GET /{project}/_apis/git/pullrequests?searchCriteria.status=active&$top=100` (paginering via `$skip`).
- Auteur: `createdBy.id`; draft: `isDraft`.
- Web-URL: `https://dev.azure.com/{org}/{project}/_git/{repo}/pullrequest/{id}`.

### GitHub

- Base: `https://api.github.com`, header `Accept: application/vnd.github+json`, `X-GitHub-Api-Version: 2022-11-28`.
- Auth: `Authorization: Bearer {token}` (PAT of `gh auth token`).
- Identiteit: `GET /user` → `login`.
- Repos: `GET /orgs/{owner}/repos` of, als owner een user is, `GET /users/{owner}/repos` (gepagineerd). Type owner bepalen via `GET /users/{owner}` → `type`.
- Open PR's: `GET /search/issues?q=is:pr+is:open+org:{owner}` (of `user:{owner}`), `per_page=100`, gepagineerd. Draft-status zit in `draft`.
- Auteur: `user.login`.
- Web-URL: `html_url`.
- Repo-naam afleiden uit `repository_url`.

## Token sources

- **KeychainPATSource**: generic password, service `nl.torrisi.pullwatch`, account = `Account.id`.
- **AzCLISource**: `az account get-access-token --resource 499b84ac-1321-427f-aa17-267ca6975798 --output json` → `accessToken`, `expiresOn`. Cache in geheugen tot 5 min vóór expiry.
- **GhCLISource**: `gh auth token` → stdout. Cache 15 min.
- CLI-pad: zoeken in `/opt/homebrew/bin`, `/usr/local/bin`, `/usr/bin` (GUI-app erft geen shell-PATH).

## Pollcyclus

Per account, onafhankelijk en parallel (`TaskGroup`):

1. Token ophalen.
2. `openPullRequests()`.
3. `PRFilter.apply(prs, account, currentUserId)`:
   - repo in allowlist / niet in denylist;
   - `isDraft == false` tenzij `includeDrafts`;
   - `authorId != currentUserId` tenzij `hideOwn == false`.
4. Nieuw = `dedupKey` niet in `SeenStore`.
5. Nieuwe PR's markeren als gezien, daarna melden (tenzij seeding).

### Seeding (geen spam)

- Account zonder eerdere succesvolle poll → eerste resultaat stil als gezien markeren.
- Repo die nieuw in de gevolgde set komt (filterwijziging) → open PR's van die repo stil als gezien markeren bij de volgende poll. `ConfigStore` houdt per account de laatst gepolde repo-set bij om dit te detecteren; bij denylist geldt "nieuw gevolgd" alleen voor repos die van de denylist af gaan.
- Draft die ready-for-review wordt terwijl drafts uit staan: valt dan pas door filter → geldt als nieuw → melding. Bewust gedrag.

### SeenStore

- Opslag: `~/Library/Application Support/Pullwatch/seen.json`, `[dedupKey: Date]`.
- Prune bij elke save: entries ouder dan 30 dagen weg.
- Een PR die tijdelijk uit de response valt, krijgt geen tweede melding zolang de entry bestaat.

### Timing

- Interval: standaard 120 s, instelbaar 60–900 s.
- Direct pollen na `NSWorkspace.didWakeNotification` en na wijziging van config.
- Backoff per account bij fouten: interval × 2ⁿ, max 900 s; reset na succes.
- HTTP 429 / 403 met rate-limit headers: wachten tot `Retry-After` / `X-RateLimit-Reset`.

## Meldingen

- Per nieuwe PR: titel `"{repo}: nieuwe PR"`, body `"{title} — {authorName}"`, `userInfo["url"] = webURL`.
- Burst: meer dan 3 nieuwe PR's in één cyclus over alle accounts → één melding `"{n} nieuwe PR's"`, body met eerste 3 titels. Klik opent geen specifieke PR (een `MenuBarExtra` kan niet programmatisch geopend worden); de PR's staan in het menu met ongelezen-stip.
- Klik → `NSWorkspace.shared.open(url)` en PR als gelezen markeren in menu.
- Toestemming vragen bij eerste start; bij weigering status tonen in menu.

## UI

### Menubar

- Icoon: SF Symbol `arrow.triangle.pull`; met stip bij ongelezen nieuwe PR's; `exclamationmark.triangle` als een account in foutstatus staat.
- Menu:
  - laatste 10 nieuwe PR's: `repo · titel · auteur · relatieve tijd`; klik opent PR, markeert gelezen;
  - "Nu verversen", "Alles gelezen";
  - per account statusregel: ✓ laatste poll-tijd, of fout + reden;
  - "Instellingen…", "Stop Pullwatch".
- Lijst recente PR's in geheugen + persistent in `recent.json` (max 50).

### Instellingen

Tab **Accounts**

- Lijst accounts, toevoegen / verwijderen.
- Velden: type, weergavenaam, organisatie/owner, auth-methode, PAT-veld (direct naar Keychain, nooit in config).
- "Test verbinding": haalt identiteit op, toont naam of fout.
- Filter: modus allow/deny, repo-lijst met checkboxes uit `listRepos()`, zoekveld.
- Toggles: drafts meenemen (uit), eigen PR's verbergen (aan).

Tab **Algemeen**

- Poll-interval.
- Starten bij inloggen.

Config: `~/Library/Application Support/Pullwatch/config.json`.

## Foutafhandeling

| Situatie | Gedrag |
|---|---|
| 401 / token ongeldig of verlopen | Account-status "token ongeldig", één melding, niet herhalen tot token/config wijzigt |
| CLI niet gevonden | Status "az/gh niet gevonden" |
| CLI niet ingelogd | Status met hint `az login` / `gh auth login` |
| Netwerkfout / 5xx | Backoff, status, geen melding |
| Rate limit | Wachten volgens headers, status |
| Parsefout | Status met korte reden, log via `os.Logger` |

Fout in één account beïnvloedt andere accounts niet. Logging via `os.Logger` met subsystem `nl.torrisi.pullwatch`.

## Testen

Swift Testing, op `PullwatchCore`:

- `PRFilter`: allow/deny, drafts, eigen PR's, combinaties.
- `SeenStore`: dedup, seeding nieuw account, seeding nieuw gevolgde repo, prune 30 dagen, persistentie roundtrip.
- Burst-logica (>3 → samenvatting).
- Providers: parsing en paginering met fixture-JSON (gebaseerd op echte API-responses), via mock `HTTPClient`; auth-headers per methode.
- Token sources: `AzCLISource`/`GhCLISource` via mock `ProcessRunner`, inclusief cache-expiry en "niet gevonden".
- Scheduler: backoff-berekening, rate-limit wachttijd.

Handmatig: echte PR op test-repo in beide providers → melding verschijnt, klik opent PR, herstart geeft geen dubbele melding.

## Build

- XcodeGen `project.yml` → `Pullwatch.xcodeproj` (gegenereerd, niet committen).
- Targets: `PullwatchCore` (framework), `Pullwatch` (app), `PullwatchCoreTests`.
- Bundle-id `nl.torrisi.pullwatch`, deployment target macOS 14.
- `Makefile`: `make gen`, `make build`, `make test`, `make install` (ad-hoc signed `.app` naar `~/Applications`).
