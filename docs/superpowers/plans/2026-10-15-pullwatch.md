# Pullwatch Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** macOS menubar-app die nieuwe PR's in Azure DevOps en GitHub detecteert en daarvan een klikbare macOS-melding geeft.

**Architecture:** Alle logica zit in een SwiftPM-library `PullwatchCore` (modellen, providers, token sources, filter, dedup-state, poll-engine), volledig getest met `swift test`. Een dunne SwiftUI-app (`App/`, Xcode-project via XcodeGen) bevat `MenuBarExtra`, settings-venster, notificaties en login-item, en hangt af van de lokale package.

**Tech Stack:** Swift 6 (language mode 6), SwiftUI, Swift Testing, Foundation `URLSession`, Security (Keychain), UserNotifications, ServiceManagement, XcodeGen, macOS 14+.

**Spec:** `docs/superpowers/specs/2026-10-15-pullwatch-design.md`

**Afwijking van spec (bewust):** `PullwatchCore` is een SwiftPM-package in plaats van een Xcode framework-target. Reden: `swift test` werkt zonder Xcode-project en houdt de testloop snel. De app-target hangt af van de lokale package; functioneel identiek.

## Global Constraints

- Bundle-id `nl.torrisi.pullwatch`; deployment target macOS 14.0; Swift language mode 6.
- Geen externe dependencies (alleen Apple frameworks). XcodeGen is alleen build-tooling.
- Geen App Sandbox (de app moet `az`/`gh` kunnen starten). Ad-hoc signing (`CODE_SIGN_IDENTITY = "-"`).
- Opslag: `~/Library/Application Support/Pullwatch/{config.json, seen.json, recent.json}`. Tokens nooit in JSON, alleen Keychain (service `nl.torrisi.pullwatch`, account = `Account.id.uuidString`).
- Poll-interval standaard 120 s, bereik 60–900 s. Backoff `interval × 2ⁿ`, max 900 s.
- SeenStore prune: entries ouder dan 30 dagen.
- Burst: meer dan 3 nieuwe PR's in één cyclus → één samenvattende melding.
- Defaults per account: `includeDrafts = false`, `hideOwn = true`, `filterMode = .deny`.
- CLI-zoekpaden: `/opt/homebrew/bin`, `/usr/local/bin`, `/usr/bin`.
- Azure DevOps resource-id voor `az`: `499b84ac-1321-427f-aa17-267ca6975798`; `api-version=7.1`.
- GitHub headers: `Accept: application/vnd.github+json`, `X-GitHub-Api-Version: 2022-11-28`.
- UI-teksten in het Nederlands. Logging via `os.Logger`, subsystem `nl.torrisi.pullwatch`.
- Elke commit eindigt met de regel `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.

## Review Focus

1. **Azure DevOps geeft HTTP 203 (HTML login-pagina) bij een ongeldige PAT, geen 401.** Verwacht: status "token ongeldig", geen parsefout. → test in Task 4 en Task 7.
2. **PR die langer dan 30 dagen open staat** mag na prune niet opnieuw een melding geven. Verwacht: elke poll ververst de timestamp van nog-open PR's. → test in Task 10.
3. **Filterwijziging (repo aan allowlist toevoegen, drafts aanzetten)** mag geen stortvloed aan meldingen voor bestaande PR's geven, terwijl een draft die ready-for-review wordt wél meldt. → tests in Task 10.
4. **Hoofdletterverschil in repo-namen** ("MyRepo" ingetypt, API geeft "myrepo"). Verwacht: filter matcht case-insensitive. → test in Task 2.
5. **Azure DevOps-data: datums met 7 decimalen (`.1234567Z`) en projectnamen met spaties.** Verwacht: correct geparsed en correct ge-URL-encoded in web-URL. → test in Task 7.

---

## File Structure

```
pullwatch/
├── Package.swift                         # SwiftPM: library PullwatchCore + tests
├── Makefile                              # test / gen / build / install / run / clean
├── project.yml                           # XcodeGen-definitie van de app (Task 12)
├── .gitignore
├── README.md                             # Task 14
├── Sources/PullwatchCore/
│   ├── Models.swift                      # ProviderKind, AuthMethod, FilterMode, Account, PullRequest
│   ├── JSONFileStore.swift               # generieke JSON-opslag + AppPaths
│   ├── PRFilter.swift                    # FilterSettings + PRFilter (puur)
│   ├── SeenState.swift                   # dedup-state + laatst gebruikte filtersettings
│   ├── ProviderError.swift               # foutmodel + Nederlandse userMessage
│   ├── HTTP.swift                        # HTTPClient, URLSessionHTTPClient, HTTPStatus, JSONDecoding, DateParsing
│   ├── PRProvider.swift                  # PRProvider protocol
│   ├── ProcessRunner.swift               # ProcessRunner, SystemProcessRunner, CLILocator
│   ├── TokenSources.swift                # TokenSource, StaticTokenSource, AzCLISource, GhCLISource
│   ├── Keychain.swift                    # SecretStore, KeychainStore, KeychainPATSource
│   ├── AzureDevOpsProvider.swift
│   ├── GitHubProvider.swift
│   ├── Backoff.swift
│   ├── NotificationPlanner.swift
│   ├── ProviderFactory.swift
│   ├── PollEngine.swift                  # pollcyclus, seeding, scheduling, foutstatus
│   ├── AppConfig.swift
│   └── RecentList.swift
├── Tests/PullwatchCoreTests/
│   ├── Support/Fixtures.swift            # PullRequest.fixture, Account.fixture
│   ├── Support/TestClock.swift
│   ├── Support/MockHTTPClient.swift
│   ├── Support/MockProcessRunner.swift
│   ├── Support/MockProvider.swift
│   ├── ModelsTests.swift
│   ├── PRFilterTests.swift
│   ├── SeenStateTests.swift
│   ├── HTTPTests.swift
│   ├── TokenSourceTests.swift
│   ├── KeychainTests.swift
│   ├── AzureDevOpsProviderTests.swift
│   ├── GitHubProviderTests.swift
│   ├── GlueTests.swift                   # Backoff, NotificationPlanner, ProviderFactory
│   ├── PollEngineTests.swift
│   └── AppStateTests.swift               # AppConfig, RecentList
└── App/
    ├── PullwatchApp.swift                # @main, scenes, AppDelegate
    ├── AppModel.swift                    # @Observable state + poll-loop
    ├── Notifier.swift                    # UNUserNotificationCenter
    ├── MenuView.swift                    # menubar-inhoud
    ├── SettingsView.swift                # tabs + algemeen (Task 13)
    └── AccountEditor.swift               # account-bewerkscherm (Task 13)
```

---

### Task 1: Package-scaffold, modellen en JSON-opslag

**Files:**
- Create: `Package.swift`, `.gitignore`, `Makefile`
- Create: `Sources/PullwatchCore/Models.swift`, `Sources/PullwatchCore/JSONFileStore.swift`
- Create: `Tests/PullwatchCoreTests/Support/Fixtures.swift`, `Tests/PullwatchCoreTests/ModelsTests.swift`

**Interfaces:**
- Produces:
  - `enum ProviderKind: String, Codable, Hashable, Sendable, CaseIterable { case azureDevOps, gitHub }`
  - `enum AuthMethod { case pat, cli }`, `enum FilterMode { case allow, deny }` (zelfde conformances)
  - `struct Account: Codable, Identifiable, Hashable, Sendable` met `init(id: UUID = UUID(), kind:, displayName:, organization:, authMethod:, filterMode: = .deny, repos: = [], includeDrafts: = false, hideOwn: = true)`
  - `struct PullRequest: Codable, Hashable, Sendable` met `init(accountId:repo:number:title:authorId:authorName:isDraft:createdAt:webURL:)`, `var dedupKey: String`
  - `struct JSONFileStore<Value: Codable & Sendable>: Sendable` met `init(url: URL)`, `func load() throws -> Value?`, `func save(_ value: Value) throws`
  - `enum AppPaths { static func file(_ name: String) -> URL }`
  - Test helpers: `PullRequest.fixture(...)`, `Account.fixture(...)`

- [ ] **Step 1: Maak package-bestanden**

`Package.swift`:

```swift
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PullwatchCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "PullwatchCore", targets: ["PullwatchCore"]),
    ],
    targets: [
        .target(name: "PullwatchCore"),
        .testTarget(name: "PullwatchCoreTests", dependencies: ["PullwatchCore"]),
    ]
)
```

`.gitignore`:

```
.build/
.swiftpm/
build/
Pullwatch.xcodeproj/
xcuserdata/
.DS_Store
```

`Makefile` (let op: recipe-regels beginnen met een TAB):

```make
.PHONY: test

test:
	swift test
```

- [ ] **Step 2: Schrijf de test-helpers en falende tests**

`Tests/PullwatchCoreTests/Support/Fixtures.swift`:

```swift
import Foundation
@testable import PullwatchCore

let fixedAccountId = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!

extension PullRequest {
    static func fixture(
        accountId: UUID = fixedAccountId,
        repo: String = "proj/api",
        number: Int = 1,
        title: String = "Fix bug",
        authorId: String = "someone",
        isDraft: Bool = false,
        createdAt: Date = Date(timeIntervalSince1970: 1_760_000_000)
    ) -> PullRequest {
        PullRequest(
            accountId: accountId,
            repo: repo,
            number: number,
            title: title,
            authorId: authorId,
            authorName: "Someone",
            isDraft: isDraft,
            createdAt: createdAt,
            webURL: URL(string: "https://example.com/\(repo)/pr/\(number)")!
        )
    }
}

extension Account {
    static func fixture(
        id: UUID = UUID(),
        kind: ProviderKind = .azureDevOps,
        organization: String = "acme",
        filterMode: FilterMode = .deny,
        repos: [String] = [],
        includeDrafts: Bool = false,
        hideOwn: Bool = true
    ) -> Account {
        Account(
            id: id,
            kind: kind,
            displayName: "Test",
            organization: organization,
            authMethod: .pat,
            filterMode: filterMode,
            repos: repos,
            includeDrafts: includeDrafts,
            hideOwn: hideOwn
        )
    }
}
```

`Tests/PullwatchCoreTests/ModelsTests.swift`:

```swift
import Foundation
import Testing
@testable import PullwatchCore

@Suite struct ModelsTests {
    @Test func accountDefaults() {
        let account = Account(kind: .gitHub, displayName: "Eigen", organization: "alessandro", authMethod: .cli)
        #expect(account.filterMode == .deny)
        #expect(account.repos.isEmpty)
        #expect(account.includeDrafts == false)
        #expect(account.hideOwn == true)
    }

    @Test func dedupKeyCombinesAccountRepoAndNumber() {
        let pr = PullRequest.fixture(repo: "proj/api", number: 42)
        #expect(pr.dedupKey == "00000000-0000-0000-0000-000000000001:proj/api:42")
    }

    @Test func jsonFileStoreReturnsNilWhenMissingAndRoundTrips() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = JSONFileStore<[Account]>(url: dir.appending(path: "nested/accounts.json"))

        #expect(try store.load() == nil)

        let accounts = [Account(kind: .azureDevOps, displayName: "Werk", organization: "acme", authMethod: .pat)]
        try store.save(accounts)
        #expect(try store.load() == accounts)
    }

    @Test func appPathsLiveInApplicationSupport() {
        let url = AppPaths.file("config.json")
        #expect(url.path().hasSuffix("Application Support/Pullwatch/config.json"))
    }
}
```

- [ ] **Step 3: Run tests, verwacht falen**

Run: `swift test`
Expected: compile error, o.a. `cannot find 'PullRequest' in scope`.

- [ ] **Step 4: Implementeer modellen en opslag**

`Sources/PullwatchCore/Models.swift`:

```swift
import Foundation

public enum ProviderKind: String, Codable, Hashable, Sendable, CaseIterable {
    case azureDevOps, gitHub
}

public enum AuthMethod: String, Codable, Hashable, Sendable, CaseIterable {
    case pat, cli
}

public enum FilterMode: String, Codable, Hashable, Sendable, CaseIterable {
    case allow, deny
}

public struct Account: Codable, Identifiable, Hashable, Sendable {
    public let id: UUID
    public var kind: ProviderKind
    public var displayName: String
    /// Azure DevOps-organisatie of GitHub-owner (user of org).
    public var organization: String
    public var authMethod: AuthMethod
    public var filterMode: FilterMode
    /// Azure DevOps: "project/repo", GitHub: "owner/repo".
    public var repos: [String]
    public var includeDrafts: Bool
    public var hideOwn: Bool

    public init(
        id: UUID = UUID(),
        kind: ProviderKind,
        displayName: String,
        organization: String,
        authMethod: AuthMethod,
        filterMode: FilterMode = .deny,
        repos: [String] = [],
        includeDrafts: Bool = false,
        hideOwn: Bool = true
    ) {
        self.id = id
        self.kind = kind
        self.displayName = displayName
        self.organization = organization
        self.authMethod = authMethod
        self.filterMode = filterMode
        self.repos = repos
        self.includeDrafts = includeDrafts
        self.hideOwn = hideOwn
    }
}

public struct PullRequest: Codable, Hashable, Sendable {
    public let accountId: UUID
    public let repo: String
    public let number: Int
    public let title: String
    public let authorId: String
    public let authorName: String
    public let isDraft: Bool
    public let createdAt: Date
    public let webURL: URL

    public init(
        accountId: UUID,
        repo: String,
        number: Int,
        title: String,
        authorId: String,
        authorName: String,
        isDraft: Bool,
        createdAt: Date,
        webURL: URL
    ) {
        self.accountId = accountId
        self.repo = repo
        self.number = number
        self.title = title
        self.authorId = authorId
        self.authorName = authorName
        self.isDraft = isDraft
        self.createdAt = createdAt
        self.webURL = webURL
    }

    public var dedupKey: String { "\(accountId.uuidString):\(repo):\(number)" }
}
```

`Sources/PullwatchCore/JSONFileStore.swift`:

```swift
import Foundation

public struct JSONFileStore<Value: Codable & Sendable>: Sendable {
    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    /// Geeft `nil` als het bestand niet bestaat.
    public func load() throws -> Value? {
        guard FileManager.default.fileExists(atPath: url.path()) else { return nil }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(Value.self, from: data)
    }

    public func save(_ value: Value) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(value).write(to: url, options: .atomic)
    }
}

public enum AppPaths {
    public static func file(_ name: String) -> URL {
        URL.applicationSupportDirectory
            .appending(path: "Pullwatch")
            .appending(path: name)
    }
}
```

- [ ] **Step 5: Run tests, verwacht slagen**

Run: `swift test`
Expected: alle 4 tests PASS.

- [ ] **Step 6: Commit**

```bash
git add Package.swift .gitignore Makefile Sources Tests
git commit -m "feat: scaffold PullwatchCore package with models and JSON store

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 2: PRFilter en FilterSettings

**Files:**
- Create: `Sources/PullwatchCore/PRFilter.swift`
- Test: `Tests/PullwatchCoreTests/PRFilterTests.swift`

**Interfaces:**
- Consumes: `Account`, `PullRequest`, `FilterMode`, `ProviderKind` (Task 1)
- Produces:
  - `struct FilterSettings: Codable, Hashable, Sendable { kind, organization, filterMode, repos, includeDrafts, hideOwn }` + `func sameSource(as other: FilterSettings) -> Bool`
  - `extension Account { var filterSettings: FilterSettings }`
  - `enum PRFilter { static func follows(repo: String, settings: FilterSettings) -> Bool; static func passes(_ pr: PullRequest, settings: FilterSettings, currentUserId: String?) -> Bool }`

- [ ] **Step 1: Schrijf de falende tests**

`Tests/PullwatchCoreTests/PRFilterTests.swift`:

```swift
import Testing
@testable import PullwatchCore

@Suite struct PRFilterTests {
    @Test func denyModeFollowsEverythingExceptListed() {
        let s = Account.fixture(filterMode: .deny, repos: ["proj/legacy"]).filterSettings
        #expect(PRFilter.follows(repo: "proj/api", settings: s))
        #expect(!PRFilter.follows(repo: "proj/legacy", settings: s))
    }

    @Test func allowModeFollowsOnlyListed() {
        let s = Account.fixture(filterMode: .allow, repos: ["proj/api"]).filterSettings
        #expect(PRFilter.follows(repo: "proj/api", settings: s))
        #expect(!PRFilter.follows(repo: "proj/web", settings: s))
    }

    @Test func repoMatchingIsCaseInsensitive() {
        let s = Account.fixture(filterMode: .allow, repos: ["Proj/MyRepo"]).filterSettings
        #expect(PRFilter.follows(repo: "proj/myrepo", settings: s))
    }

    @Test func draftsHiddenUnlessIncluded() {
        let draft = PullRequest.fixture(isDraft: true)
        #expect(!PRFilter.passes(draft, settings: Account.fixture().filterSettings, currentUserId: "me"))
        #expect(PRFilter.passes(draft, settings: Account.fixture(includeDrafts: true).filterSettings, currentUserId: "me"))
    }

    @Test func ownPullRequestsHiddenWhenHideOwn() {
        let mine = PullRequest.fixture(authorId: "ME")
        #expect(!PRFilter.passes(mine, settings: Account.fixture(hideOwn: true).filterSettings, currentUserId: "me"))
        #expect(PRFilter.passes(mine, settings: Account.fixture(hideOwn: false).filterSettings, currentUserId: "me"))
    }

    @Test func unfollowedRepoNeverPasses() {
        let pr = PullRequest.fixture(repo: "proj/legacy")
        let s = Account.fixture(filterMode: .deny, repos: ["proj/legacy"]).filterSettings
        #expect(!PRFilter.passes(pr, settings: s, currentUserId: "me"))
    }

    @Test func sameSourceComparesKindAndOrganizationCaseInsensitive() {
        let a = Account.fixture(kind: .gitHub, organization: "Acme").filterSettings
        let b = Account.fixture(kind: .gitHub, organization: "acme", repos: ["x/y"]).filterSettings
        let c = Account.fixture(kind: .azureDevOps, organization: "acme").filterSettings
        #expect(a.sameSource(as: b))
        #expect(!a.sameSource(as: c))
    }
}
```

- [ ] **Step 2: Run tests, verwacht falen**

Run: `swift test --filter PRFilterTests`
Expected: compile error `cannot find 'PRFilter' in scope`.

- [ ] **Step 3: Implementeer**

`Sources/PullwatchCore/PRFilter.swift`:

```swift
import Foundation

/// De filter-relevante instellingen van een account. Wordt ook bewaard in `SeenState`
/// om te detecteren welke PR's pas door een instellingswijziging zichtbaar worden.
public struct FilterSettings: Codable, Hashable, Sendable {
    public var kind: ProviderKind
    public var organization: String
    public var filterMode: FilterMode
    public var repos: [String]
    public var includeDrafts: Bool
    public var hideOwn: Bool

    public func sameSource(as other: FilterSettings) -> Bool {
        kind == other.kind
            && organization.caseInsensitiveCompare(other.organization) == .orderedSame
    }
}

extension Account {
    public var filterSettings: FilterSettings {
        FilterSettings(
            kind: kind,
            organization: organization,
            filterMode: filterMode,
            repos: repos,
            includeDrafts: includeDrafts,
            hideOwn: hideOwn
        )
    }
}

public enum PRFilter {
    public static func follows(repo: String, settings: FilterSettings) -> Bool {
        let listed = settings.repos.contains { $0.caseInsensitiveCompare(repo) == .orderedSame }
        switch settings.filterMode {
        case .allow: return listed
        case .deny: return !listed
        }
    }

    public static func passes(_ pr: PullRequest, settings: FilterSettings, currentUserId: String?) -> Bool {
        guard follows(repo: pr.repo, settings: settings) else { return false }
        if pr.isDraft && !settings.includeDrafts { return false }
        if settings.hideOwn, let me = currentUserId,
           pr.authorId.caseInsensitiveCompare(me) == .orderedSame {
            return false
        }
        return true
    }
}
```

- [ ] **Step 4: Run tests, verwacht slagen**

Run: `swift test --filter PRFilterTests`
Expected: 7 tests PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/PullwatchCore/PRFilter.swift Tests/PullwatchCoreTests/PRFilterTests.swift
git commit -m "feat: add PR filter with allow/deny, drafts and own-PR rules

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 3: SeenState (dedup-state)

**Files:**
- Create: `Sources/PullwatchCore/SeenState.swift`
- Test: `Tests/PullwatchCoreTests/SeenStateTests.swift`

**Interfaces:**
- Consumes: `FilterSettings` (Task 2), `JSONFileStore` (Task 1)
- Produces: `struct SeenState: Codable, Equatable, Sendable` met
  - `var seen: [String: Date]`, `var lastSettings: [String: FilterSettings]` (key = `Account.id.uuidString`)
  - `init()`, `func contains(_ key: String) -> Bool`, `mutating func mark(_ key: String, at date: Date)`, `mutating func prune(now: Date, maxAge: TimeInterval = 30 * 24 * 3600)`

- [ ] **Step 1: Schrijf de falende tests**

`Tests/PullwatchCoreTests/SeenStateTests.swift`:

```swift
import Foundation
import Testing
@testable import PullwatchCore

@Suite struct SeenStateTests {
    let t0 = Date(timeIntervalSince1970: 1_760_000_000)
    let day: TimeInterval = 24 * 3600

    @Test func markThenContains() {
        var state = SeenState()
        #expect(!state.contains("a"))
        state.mark("a", at: t0)
        #expect(state.contains("a"))
    }

    @Test func pruneRemovesEntriesOlderThan30Days() {
        var state = SeenState()
        state.mark("old", at: t0)
        state.mark("recent", at: t0 + 25 * day)
        state.prune(now: t0 + 31 * day)
        #expect(!state.contains("old"))
        #expect(state.contains("recent"))
    }

    @Test func markRefreshesTimestampSoPruneKeepsIt() {
        var state = SeenState()
        state.mark("a", at: t0)
        state.mark("a", at: t0 + 20 * day)
        state.prune(now: t0 + 40 * day)
        #expect(state.contains("a"))
    }

    @Test func roundTripsThroughJSONFileStore() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = JSONFileStore<SeenState>(url: dir.appending(path: "seen.json"))

        var state = SeenState()
        state.mark("a", at: t0)
        state.lastSettings["acc"] = Account.fixture(repos: ["p/r"]).filterSettings
        try store.save(state)

        #expect(try store.load() == state)
    }
}
```

- [ ] **Step 2: Run tests, verwacht falen**

Run: `swift test --filter SeenStateTests`
Expected: compile error `cannot find 'SeenState' in scope`.

- [ ] **Step 3: Implementeer**

`Sources/PullwatchCore/SeenState.swift`:

```swift
import Foundation

/// Persistente dedup-state. `seen` bevat dedupKeys van PR's die gemeld of stil geseed zijn,
/// met de laatste keer dat ze open gezien zijn. `lastSettings` bevat per account de
/// filtersettings van de laatste succesvolle poll.
public struct SeenState: Codable, Equatable, Sendable {
    public var seen: [String: Date] = [:]
    public var lastSettings: [String: FilterSettings] = [:]

    public init() {}

    public func contains(_ key: String) -> Bool {
        seen[key] != nil
    }

    public mutating func mark(_ key: String, at date: Date) {
        seen[key] = date
    }

    public mutating func prune(now: Date, maxAge: TimeInterval = 30 * 24 * 3600) {
        seen = seen.filter { now.timeIntervalSince($0.value) <= maxAge }
    }
}
```

- [ ] **Step 4: Run tests, verwacht slagen**

Run: `swift test --filter SeenStateTests`
Expected: 4 tests PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/PullwatchCore/SeenState.swift Tests/PullwatchCoreTests/SeenStateTests.swift
git commit -m "feat: add persistent seen-state with 30-day prune

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 4: Foutmodel, HTTP-laag, datum-parsing en PRProvider-protocol

**Files:**
- Create: `Sources/PullwatchCore/ProviderError.swift`, `Sources/PullwatchCore/HTTP.swift`, `Sources/PullwatchCore/PRProvider.swift`
- Create: `Tests/PullwatchCoreTests/Support/MockHTTPClient.swift`
- Test: `Tests/PullwatchCoreTests/HTTPTests.swift`

**Interfaces:**
- Consumes: `PullRequest` (Task 1)
- Produces:
  - `enum ProviderError: Error, Equatable, Sendable { case unauthorized, rateLimited(until: Date), server(status: Int), network(String), decoding(String), cliNotFound(String), cliNotLoggedIn(String), missingToken }` + `var userMessage: String`
  - `protocol HTTPClient: Sendable { func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) }`, `struct URLSessionHTTPClient: HTTPClient`
  - `enum HTTPStatus { static func check(_ response: HTTPURLResponse, now: Date) throws }`
  - `enum JSONDecoding { static func decode<T: Decodable>(_ type: T.Type, from data: Data, snakeCase: Bool = false) throws -> T }`
  - `enum DateParsing { static func parse(_ string: String) -> Date? }`
  - `protocol PRProvider: Sendable { currentUserId() async throws -> String; listRepos() async throws -> [String]; openPullRequests() async throws -> [PullRequest]; invalidateCredentials() async }`
  - Test helper `MockHTTPClient` met `on(_ urlSubstring:status:headers:body:)` en `requests`

- [ ] **Step 1: Schrijf MockHTTPClient en de falende tests**

`Tests/PullwatchCoreTests/Support/MockHTTPClient.swift`:

```swift
import Foundation
@testable import PullwatchCore

/// Route-matching op substring van de volledige URL; de EERSTE geregistreerde match wint.
/// Registreer dus specifieke routes vóór algemene.
final class MockHTTPClient: HTTPClient, @unchecked Sendable {
    private struct Route {
        let substring: String
        let status: Int
        let headers: [String: String]
        let body: String
    }

    private let lock = NSLock()
    private var routes: [Route] = []
    private var recorded: [URLRequest] = []

    var requests: [URLRequest] { lock.withLock { recorded } }

    func on(_ substring: String, status: Int = 200, headers: [String: String] = [:], body: String) {
        lock.withLock { routes.append(Route(substring: substring, status: status, headers: headers, body: body)) }
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let url = request.url!
        let route: Route? = lock.withLock {
            recorded.append(request)
            return routes.first { url.absoluteString.contains($0.substring) }
        }
        guard let route else { throw ProviderError.network("geen mock-route voor \(url.absoluteString)") }
        let response = HTTPURLResponse(url: url, statusCode: route.status, httpVersion: nil, headerFields: route.headers)!
        return (Data(route.body.utf8), response)
    }
}
```

`Tests/PullwatchCoreTests/HTTPTests.swift`:

```swift
import Foundation
import Testing
@testable import PullwatchCore

@Suite struct HTTPTests {
    let now = Date(timeIntervalSince1970: 1_760_000_000)

    func response(_ status: Int, _ headers: [String: String] = [:]) -> HTTPURLResponse {
        HTTPURLResponse(url: URL(string: "https://x")!, statusCode: status, httpVersion: nil, headerFields: headers)!
    }

    func checkError(_ r: HTTPURLResponse) -> ProviderError? {
        do { try HTTPStatus.check(r, now: now); return nil } catch let e as ProviderError { return e } catch { return nil }
    }

    @Test func successPasses() {
        #expect(checkError(response(200)) == nil)
    }

    @Test func azureDevOps203LoginPageIsUnauthorized() {
        #expect(checkError(response(203)) == .unauthorized)
    }

    @Test func unauthorized401() {
        #expect(checkError(response(401)) == .unauthorized)
    }

    @Test func retryAfterOn429() {
        #expect(checkError(response(429, ["Retry-After": "30"])) == .rateLimited(until: now + 30))
    }

    @Test func gitHubRateLimit403UsesResetHeader() {
        let r = response(403, ["X-RateLimit-Remaining": "0", "X-RateLimit-Reset": "1760000600"])
        #expect(checkError(r) == .rateLimited(until: Date(timeIntervalSince1970: 1_760_000_600)))
    }

    @Test func plain403IsUnauthorized() {
        #expect(checkError(response(403)) == .unauthorized)
    }

    @Test func serverError() {
        #expect(checkError(response(503)) == .server(status: 503))
    }

    @Test func parsesDatesWithAndWithoutFractionalSeconds() {
        let expected = Date(timeIntervalSince1970: 1_760_522_400) // 2025-10-15T10:00:00Z
        #expect(DateParsing.parse("2025-10-15T10:00:00Z") == expected)
        #expect(DateParsing.parse("2025-10-15T10:00:00.123Z") == expected)
        #expect(DateParsing.parse("2025-10-15T10:00:00.1234567Z") == expected)
        #expect(DateParsing.parse("garbage") == nil)
    }

    @Test func decodingErrorBecomesProviderError() {
        struct Thing: Decodable { let name: String }
        #expect(throws: ProviderError.self) {
            _ = try JSONDecoding.decode(Thing.self, from: Data("<html>".utf8))
        }
    }

    @Test func snakeCaseDecoding() throws {
        struct Thing: Decodable { let htmlUrl: String }
        let thing = try JSONDecoding.decode(Thing.self, from: Data(#"{"html_url":"u"}"#.utf8), snakeCase: true)
        #expect(thing.htmlUrl == "u")
    }
}
```

- [ ] **Step 2: Run tests, verwacht falen**

Run: `swift test --filter HTTPTests`
Expected: compile error `cannot find 'HTTPStatus' in scope`.

- [ ] **Step 3: Implementeer**

`Sources/PullwatchCore/ProviderError.swift`:

```swift
import Foundation

public enum ProviderError: Error, Equatable, Sendable {
    case unauthorized
    case rateLimited(until: Date)
    case server(status: Int)
    case network(String)
    case decoding(String)
    case cliNotFound(String)
    case cliNotLoggedIn(String)
    case missingToken

    public var userMessage: String {
        switch self {
        case .unauthorized:
            return "Token ongeldig of verlopen"
        case .rateLimited(let until):
            return "Rate limit, opnieuw om \(until.formatted(date: .omitted, time: .shortened))"
        case .server(let status):
            return "Serverfout (\(status))"
        case .network(let message):
            return "Netwerkfout: \(message)"
        case .decoding(let message):
            return "Onverwacht antwoord: \(message)"
        case .cliNotFound(let name):
            return "\(name) niet gevonden (installeer via Homebrew)"
        case .cliNotLoggedIn(let name):
            return "Niet ingelogd, voer `\(name == "az" ? "az login" : "gh auth login")` uit"
        case .missingToken:
            return "Geen token ingesteld"
        }
    }
}
```

`Sources/PullwatchCore/HTTP.swift`:

```swift
import Foundation

public protocol HTTPClient: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

public struct URLSessionHTTPClient: HTTPClient {
    public init() {}

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw ProviderError.network("geen HTTP-response")
            }
            return (data, http)
        } catch let error as ProviderError {
            throw error
        } catch {
            throw ProviderError.network(error.localizedDescription)
        }
    }
}

public enum HTTPStatus {
    public static func check(_ response: HTTPURLResponse, now: Date) throws {
        let status = response.statusCode
        switch status {
        case 203:
            // Azure DevOps antwoordt met 203 + HTML-loginpagina bij een ongeldige PAT.
            throw ProviderError.unauthorized
        case 200..<300:
            return
        case 401:
            throw ProviderError.unauthorized
        case 403, 429:
            if let retryAfter = response.value(forHTTPHeaderField: "Retry-After"), let seconds = Double(retryAfter) {
                throw ProviderError.rateLimited(until: now + seconds)
            }
            if response.value(forHTTPHeaderField: "X-RateLimit-Remaining") == "0",
               let reset = response.value(forHTTPHeaderField: "X-RateLimit-Reset"),
               let epoch = Double(reset) {
                throw ProviderError.rateLimited(until: Date(timeIntervalSince1970: epoch))
            }
            if status == 429 { throw ProviderError.rateLimited(until: now + 60) }
            throw ProviderError.unauthorized
        default:
            throw ProviderError.server(status: status)
        }
    }
}

public enum JSONDecoding {
    public static func decode<T: Decodable>(_ type: T.Type, from data: Data, snakeCase: Bool = false) throws -> T {
        let decoder = JSONDecoder()
        if snakeCase { decoder.keyDecodingStrategy = .convertFromSnakeCase }
        do {
            return try decoder.decode(type, from: data)
        } catch {
            throw ProviderError.decoding("\(T.self): \(error.localizedDescription)")
        }
    }
}

public enum DateParsing {
    /// ISO-8601; fractionele seconden (ook 7 cijfers zoals Azure DevOps levert) worden genegeerd.
    public static func parse(_ string: String) -> Date? {
        var value = string
        if let dot = value.firstIndex(of: "."),
           let end = value[dot...].firstIndex(where: { "Z+-".contains($0) }) {
            value.removeSubrange(dot..<end)
        }
        return try? Date(value, strategy: .iso8601)
    }
}
```

`Sources/PullwatchCore/PRProvider.swift`:

```swift
import Foundation

public protocol PRProvider: Sendable {
    /// Identiteit van de ingelogde gebruiker, vergeleken met `PullRequest.authorId`.
    func currentUserId() async throws -> String
    /// Alle repos die het account kan zien, in hetzelfde formaat als `Account.repos`.
    func listRepos() async throws -> [String]
    /// Alle open PR's inclusief drafts, ongefilterd.
    func openPullRequests() async throws -> [PullRequest]
    /// Gooi gecachte tokens weg (na een 401).
    func invalidateCredentials() async
}
```

- [ ] **Step 4: Run tests, verwacht slagen**

Run: `swift test --filter HTTPTests`
Expected: 10 tests PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/PullwatchCore/ProviderError.swift Sources/PullwatchCore/HTTP.swift Sources/PullwatchCore/PRProvider.swift Tests/PullwatchCoreTests/Support/MockHTTPClient.swift Tests/PullwatchCoreTests/HTTPTests.swift
git commit -m "feat: add HTTP layer, error model and PRProvider protocol

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 5: Process runner, CLI-locator en CLI token sources

**Files:**
- Create: `Sources/PullwatchCore/ProcessRunner.swift`, `Sources/PullwatchCore/TokenSources.swift`
- Create: `Tests/PullwatchCoreTests/Support/TestClock.swift`, `Tests/PullwatchCoreTests/Support/MockProcessRunner.swift`
- Test: `Tests/PullwatchCoreTests/TokenSourceTests.swift`

**Interfaces:**
- Consumes: `ProviderError` (Task 4)
- Produces:
  - `struct ProcessOutput: Sendable { status: Int32; stdout: String; stderr: String }`
  - `protocol ProcessRunner: Sendable { func run(_ executable: URL, _ arguments: [String]) async throws -> ProcessOutput }`, `struct SystemProcessRunner: ProcessRunner`
  - `struct CLILocator: Sendable { init(searchPaths: = default, isExecutable: = FileManager); func locate(_ name: String) -> URL? }`
  - `protocol TokenSource: Sendable { func token() async throws -> String; func invalidate() async }` (default `invalidate` no-op)
  - `struct StaticTokenSource: TokenSource { init(token: String) }`
  - `actor AzCLISource: TokenSource { init(runner:, locator: = CLILocator(), now: = { Date() }) }`
  - `actor GhCLISource: TokenSource { init(runner:, locator: = CLILocator(), now: = { Date() }) }`
  - Test helpers `TestClock` (`now`, `advance(_:)`), `MockProcessRunner` (`output`, `calls`)

- [ ] **Step 1: Schrijf test-helpers en falende tests**

`Tests/PullwatchCoreTests/Support/TestClock.swift`:

```swift
import Foundation

final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current = Date(timeIntervalSince1970: 1_760_000_000)

    var now: Date { lock.withLock { current } }

    func advance(_ seconds: TimeInterval) {
        lock.withLock { current += seconds }
    }
}
```

`Tests/PullwatchCoreTests/Support/MockProcessRunner.swift`:

```swift
import Foundation
@testable import PullwatchCore

final class MockProcessRunner: ProcessRunner, @unchecked Sendable {
    private let lock = NSLock()
    private var _output = ProcessOutput(status: 0, stdout: "", stderr: "")
    private var _calls: [(URL, [String])] = []

    var output: ProcessOutput {
        get { lock.withLock { _output } }
        set { lock.withLock { _output = newValue } }
    }

    var calls: [(URL, [String])] { lock.withLock { _calls } }

    func run(_ executable: URL, _ arguments: [String]) async throws -> ProcessOutput {
        lock.withLock {
            _calls.append((executable, arguments))
            return _output
        }
    }
}
```

`Tests/PullwatchCoreTests/TokenSourceTests.swift`:

```swift
import Foundation
import Testing
@testable import PullwatchCore

@Suite struct TokenSourceTests {
    let homebrew = CLILocator(isExecutable: { $0.hasPrefix("/opt/homebrew/bin/") })
    let nothing = CLILocator(isExecutable: { _ in false })

    @Test func locatorFindsFirstExecutableInSearchPaths() {
        let locator = CLILocator(isExecutable: { $0 == "/usr/local/bin/gh" })
        #expect(locator.locate("gh") == URL(filePath: "/usr/local/bin/gh"))
        #expect(locator.locate("az") == nil)
    }

    @Test func azParsesTokenAndCallsCorrectCommand() async throws {
        let clock = TestClock()
        let runner = MockProcessRunner()
        let expires = Int(clock.now.timeIntervalSince1970) + 3600
        runner.output = ProcessOutput(status: 0, stdout: #"{"accessToken":"tok1","expires_on":\#(expires)}"#, stderr: "")
        let source = AzCLISource(runner: runner, locator: homebrew, now: { clock.now })

        #expect(try await source.token() == "tok1")
        let call = try #require(runner.calls.first)
        #expect(call.0 == URL(filePath: "/opt/homebrew/bin/az"))
        #expect(call.1 == ["account", "get-access-token", "--resource", "499b84ac-1321-427f-aa17-267ca6975798", "--output", "json"])
    }

    @Test func azCachesUntilFiveMinutesBeforeExpiry() async throws {
        let clock = TestClock()
        let runner = MockProcessRunner()
        let expires = Int(clock.now.timeIntervalSince1970) + 3600
        runner.output = ProcessOutput(status: 0, stdout: #"{"accessToken":"tok1","expires_on":\#(expires)}"#, stderr: "")
        let source = AzCLISource(runner: runner, locator: homebrew, now: { clock.now })

        _ = try await source.token()
        clock.advance(3000)
        _ = try await source.token()
        #expect(runner.calls.count == 1)

        clock.advance(400) // nu binnen 5 minuten van expiry
        _ = try await source.token()
        #expect(runner.calls.count == 2)
    }

    @Test func azInvalidateForcesRefetch() async throws {
        let runner = MockProcessRunner()
        runner.output = ProcessOutput(status: 0, stdout: #"{"accessToken":"tok1"}"#, stderr: "")
        let source = AzCLISource(runner: runner, locator: homebrew)
        _ = try await source.token()
        await source.invalidate()
        _ = try await source.token()
        #expect(runner.calls.count == 2)
    }

    @Test func azNotFound() async {
        let source = AzCLISource(runner: MockProcessRunner(), locator: nothing)
        await #expect(throws: ProviderError.cliNotFound("az")) { try await source.token() }
    }

    @Test func azNonZeroExitMeansNotLoggedIn() async {
        let runner = MockProcessRunner()
        runner.output = ProcessOutput(status: 1, stdout: "", stderr: "Please run 'az login'")
        let source = AzCLISource(runner: runner, locator: homebrew)
        await #expect(throws: ProviderError.cliNotLoggedIn("az")) { try await source.token() }
    }

    @Test func ghTrimsTokenAndCaches() async throws {
        let runner = MockProcessRunner()
        runner.output = ProcessOutput(status: 0, stdout: "gho_abc\n", stderr: "")
        let source = GhCLISource(runner: runner, locator: homebrew)
        #expect(try await source.token() == "gho_abc")
        #expect(try await source.token() == "gho_abc")
        #expect(runner.calls.count == 1)
        #expect(runner.calls.first?.1 == ["auth", "token"])
    }

    @Test func ghEmptyOutputMeansNotLoggedIn() async {
        let runner = MockProcessRunner()
        runner.output = ProcessOutput(status: 0, stdout: "\n", stderr: "")
        let source = GhCLISource(runner: runner, locator: homebrew)
        await #expect(throws: ProviderError.cliNotLoggedIn("gh")) { try await source.token() }
    }

    @Test func staticTokenSource() async throws {
        #expect(try await StaticTokenSource(token: "x").token() == "x")
    }
}
```

- [ ] **Step 2: Run tests, verwacht falen**

Run: `swift test --filter TokenSourceTests`
Expected: compile error `cannot find 'CLILocator' in scope`.

- [ ] **Step 3: Implementeer**

`Sources/PullwatchCore/ProcessRunner.swift`:

```swift
import Foundation

public struct ProcessOutput: Sendable, Equatable {
    public let status: Int32
    public let stdout: String
    public let stderr: String

    public init(status: Int32, stdout: String, stderr: String) {
        self.status = status
        self.stdout = stdout
        self.stderr = stderr
    }
}

public protocol ProcessRunner: Sendable {
    func run(_ executable: URL, _ arguments: [String]) async throws -> ProcessOutput
}

public struct SystemProcessRunner: ProcessRunner {
    public init() {}

    public func run(_ executable: URL, _ arguments: [String]) async throws -> ProcessOutput {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = executable
            process.arguments = arguments
            // GUI-apps erven geen shell-PATH; az/gh hebben zelf ook tools uit Homebrew nodig.
            var environment = ProcessInfo.processInfo.environment
            environment["PATH"] = (CLILocator.defaultSearchPaths + [environment["PATH"] ?? ""]).joined(separator: ":")
            process.environment = environment

            let stdout = Pipe()
            let stderr = Pipe()
            process.standardOutput = stdout
            process.standardError = stderr
            process.terminationHandler = { finished in
                let out = String(decoding: stdout.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                let err = String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                continuation.resume(returning: ProcessOutput(status: finished.terminationStatus, stdout: out, stderr: err))
            }
            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}

public struct CLILocator: Sendable {
    public static let defaultSearchPaths = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"]

    private let searchPaths: [String]
    private let isExecutable: @Sendable (String) -> Bool

    public init(
        searchPaths: [String] = CLILocator.defaultSearchPaths,
        isExecutable: @escaping @Sendable (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) {
        self.searchPaths = searchPaths
        self.isExecutable = isExecutable
    }

    public func locate(_ name: String) -> URL? {
        searchPaths
            .map { "\($0)/\(name)" }
            .first(where: isExecutable)
            .map { URL(filePath: $0) }
    }
}
```

`Sources/PullwatchCore/TokenSources.swift`:

```swift
import Foundation

public protocol TokenSource: Sendable {
    func token() async throws -> String
    func invalidate() async
}

extension TokenSource {
    public func invalidate() async {}
}

public struct StaticTokenSource: TokenSource {
    private let value: String

    public init(token: String) {
        self.value = token
    }

    public func token() async throws -> String { value }
}

public actor AzCLISource: TokenSource {
    private static let devOpsResource = "499b84ac-1321-427f-aa17-267ca6975798"

    private let runner: any ProcessRunner
    private let locator: CLILocator
    private let now: @Sendable () -> Date
    private var cached: (token: String, expiresAt: Date)?

    public init(runner: any ProcessRunner, locator: CLILocator = CLILocator(), now: @escaping @Sendable () -> Date = { Date() }) {
        self.runner = runner
        self.locator = locator
        self.now = now
    }

    public func token() async throws -> String {
        if let cached, cached.expiresAt.addingTimeInterval(-300) > now() {
            return cached.token
        }
        guard let az = locator.locate("az") else { throw ProviderError.cliNotFound("az") }
        let output = try await runner.run(az, ["account", "get-access-token", "--resource", Self.devOpsResource, "--output", "json"])
        guard output.status == 0 else { throw ProviderError.cliNotLoggedIn("az") }

        struct Response: Decodable {
            let accessToken: String
            let expires_on: Int?
        }
        let response = try JSONDecoding.decode(Response.self, from: Data(output.stdout.utf8))
        let expiresAt = response.expires_on.map { Date(timeIntervalSince1970: TimeInterval($0)) }
            ?? now().addingTimeInterval(3000)
        cached = (response.accessToken, expiresAt)
        return response.accessToken
    }

    public func invalidate() async {
        cached = nil
    }
}

public actor GhCLISource: TokenSource {
    private let runner: any ProcessRunner
    private let locator: CLILocator
    private let now: @Sendable () -> Date
    private var cached: (token: String, fetchedAt: Date)?

    public init(runner: any ProcessRunner, locator: CLILocator = CLILocator(), now: @escaping @Sendable () -> Date = { Date() }) {
        self.runner = runner
        self.locator = locator
        self.now = now
    }

    public func token() async throws -> String {
        if let cached, now().timeIntervalSince(cached.fetchedAt) < 15 * 60 {
            return cached.token
        }
        guard let gh = locator.locate("gh") else { throw ProviderError.cliNotFound("gh") }
        let output = try await runner.run(gh, ["auth", "token"])
        let token = output.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard output.status == 0, !token.isEmpty else { throw ProviderError.cliNotLoggedIn("gh") }
        cached = (token, now())
        return token
    }

    public func invalidate() async {
        cached = nil
    }
}
```

- [ ] **Step 4: Run tests, verwacht slagen**

Run: `swift test --filter TokenSourceTests`
Expected: 9 tests PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/PullwatchCore/ProcessRunner.swift Sources/PullwatchCore/TokenSources.swift Tests/PullwatchCoreTests/Support/TestClock.swift Tests/PullwatchCoreTests/Support/MockProcessRunner.swift Tests/PullwatchCoreTests/TokenSourceTests.swift
git commit -m "feat: add az/gh CLI token sources with caching

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 6: Keychain-opslag en PAT token source

**Files:**
- Create: `Sources/PullwatchCore/Keychain.swift`
- Test: `Tests/PullwatchCoreTests/KeychainTests.swift`

**Interfaces:**
- Consumes: `TokenSource`, `ProviderError` (Task 4/5)
- Produces:
  - `protocol SecretStore: Sendable { read(account: String) throws -> String?; write(_ secret: String, account: String) throws; delete(account: String) throws }`
  - `struct KeychainStore: SecretStore { init(service: String = "nl.torrisi.pullwatch") }`
  - `struct KeychainError: Error, Equatable { let status: OSStatus }`
  - `struct KeychainPATSource: TokenSource { init(store: any SecretStore, accountId: UUID) }`

- [ ] **Step 1: Schrijf de falende tests**

`Tests/PullwatchCoreTests/KeychainTests.swift`:

```swift
import Foundation
import Testing
@testable import PullwatchCore

final class InMemorySecretStore: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]
    func read(account: String) throws -> String? { lock.withLock { values[account] } }
    func write(_ secret: String, account: String) throws { lock.withLock { values[account] = secret } }
    func delete(account: String) throws { _ = lock.withLock { values.removeValue(forKey: account) } }
}

@Suite(.serialized) struct KeychainTests {
    @Test func realKeychainRoundTrip() throws {
        let store = KeychainStore(service: "nl.torrisi.pullwatch.tests")
        let account = UUID().uuidString
        defer { try? store.delete(account: account) }

        #expect(try store.read(account: account) == nil)
        try store.write("first", account: account)
        #expect(try store.read(account: account) == "first")
        try store.write("second", account: account)
        #expect(try store.read(account: account) == "second")
        try store.delete(account: account)
        #expect(try store.read(account: account) == nil)
        try store.delete(account: account) // verwijderen van niet-bestaand item is geen fout
    }

    @Test func patSourceReadsByAccountId() async throws {
        let store = InMemorySecretStore()
        let id = UUID()
        try store.write("pat-123", account: id.uuidString)
        #expect(try await KeychainPATSource(store: store, accountId: id).token() == "pat-123")
    }

    @Test func patSourceMissingToken() async {
        let source = KeychainPATSource(store: InMemorySecretStore(), accountId: UUID())
        await #expect(throws: ProviderError.missingToken) { try await source.token() }
    }
}
```

- [ ] **Step 2: Run tests, verwacht falen**

Run: `swift test --filter KeychainTests`
Expected: compile error `cannot find type 'SecretStore' in scope`.

- [ ] **Step 3: Implementeer**

`Sources/PullwatchCore/Keychain.swift`:

```swift
import Foundation
import Security

public protocol SecretStore: Sendable {
    func read(account: String) throws -> String?
    func write(_ secret: String, account: String) throws
    func delete(account: String) throws
}

public struct KeychainError: Error, Equatable {
    public let status: OSStatus
}

public struct KeychainStore: SecretStore {
    private let service: String

    public init(service: String = "nl.torrisi.pullwatch") {
        self.service = service
    }

    private func baseQuery(_ account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    public func read(account: String) throws -> String? {
        var query = baseQuery(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else { throw KeychainError(status: status) }
        return String(decoding: data, as: UTF8.self)
    }

    public func write(_ secret: String, account: String) throws {
        let data = Data(secret.utf8)
        let status = SecItemUpdate(
            baseQuery(account) as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        if status == errSecItemNotFound {
            var query = baseQuery(account)
            query[kSecValueData as String] = data
            let addStatus = SecItemAdd(query as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw KeychainError(status: addStatus) }
            return
        }
        guard status == errSecSuccess else { throw KeychainError(status: status) }
    }

    public func delete(account: String) throws {
        let status = SecItemDelete(baseQuery(account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError(status: status) }
    }
}

public struct KeychainPATSource: TokenSource {
    private let store: any SecretStore
    private let accountId: UUID

    public init(store: any SecretStore, accountId: UUID) {
        self.store = store
        self.accountId = accountId
    }

    public func token() async throws -> String {
        guard let token = try store.read(account: accountId.uuidString), !token.isEmpty else {
            throw ProviderError.missingToken
        }
        return token
    }
}
```

- [ ] **Step 4: Run tests, verwacht slagen**

Run: `swift test --filter KeychainTests`
Expected: 3 tests PASS. (Als macOS een Keychain-toegangsdialoog toont: "Altijd toestaan" kiezen en opnieuw draaien.)

- [ ] **Step 5: Commit**

```bash
git add Sources/PullwatchCore/Keychain.swift Tests/PullwatchCoreTests/KeychainTests.swift
git commit -m "feat: add Keychain secret store and PAT token source

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 7: AzureDevOpsProvider

**Files:**
- Create: `Sources/PullwatchCore/AzureDevOpsProvider.swift`
- Test: `Tests/PullwatchCoreTests/AzureDevOpsProviderTests.swift`

**Interfaces:**
- Consumes: `PRProvider`, `HTTPClient`, `HTTPStatus`, `JSONDecoding`, `DateParsing`, `ProviderError` (Task 4); `TokenSource`, `StaticTokenSource` (Task 5); `AuthMethod`, `PullRequest` (Task 1)
- Produces: `actor AzureDevOpsProvider: PRProvider` met `init(accountId: UUID, organization: String, tokenSource: any TokenSource, authMethod: AuthMethod, http: any HTTPClient, now: @escaping @Sendable () -> Date = { Date() })`

- [ ] **Step 1: Schrijf de falende tests**

`Tests/PullwatchCoreTests/AzureDevOpsProviderTests.swift`:

```swift
import Foundation
import Testing
@testable import PullwatchCore

@Suite struct AzureDevOpsProviderTests {
    let projects = #"{"count":1,"value":[{"name":"My Project"}]}"#

    func prJSON(id: Int, draft: Bool? = nil, date: String = "2025-10-15T10:00:00.1234567Z") -> String {
        let draftField = draft.map { #","isDraft":\#($0)"# } ?? ""
        return #"""
        {"pullRequestId":\#(id),"title":"PR \#(id)","creationDate":"\#(date)"\#(draftField),
         "createdBy":{"id":"user-guid","displayName":"Jan Jansen"},
         "repository":{"name":"api","project":{"name":"My Project"}}}
        """#
    }

    func makeProvider(_ http: MockHTTPClient, auth: AuthMethod = .pat, token: String = "secret") -> AzureDevOpsProvider {
        AzureDevOpsProvider(
            accountId: fixedAccountId,
            organization: "acme",
            tokenSource: StaticTokenSource(token: token),
            authMethod: auth,
            http: http
        )
    }

    @Test func mapsPullRequestFields() async throws {
        let http = MockHTTPClient()
        http.on("_apis/projects", body: projects)
        http.on("_apis/git/pullrequests", body: #"{"value":[\#(prJSON(id: 17))]}"#)

        let prs = try await makeProvider(http).openPullRequests()

        let pr = try #require(prs.first)
        #expect(prs.count == 1)
        #expect(pr.accountId == fixedAccountId)
        #expect(pr.repo == "My Project/api")
        #expect(pr.number == 17)
        #expect(pr.title == "PR 17")
        #expect(pr.authorId == "user-guid")
        #expect(pr.authorName == "Jan Jansen")
        #expect(pr.isDraft == false)
        #expect(pr.createdAt == Date(timeIntervalSince1970: 1_760_522_400))
        #expect(pr.webURL.absoluteString == "https://dev.azure.com/acme/My%20Project/_git/api/pullrequest/17")
    }

    @Test func requestsActivePullRequestsWithApiVersion() async throws {
        let http = MockHTTPClient()
        http.on("_apis/projects", body: projects)
        http.on("_apis/git/pullrequests", body: #"{"value":[]}"#)

        _ = try await makeProvider(http).openPullRequests()

        let url = try #require(http.requests.last?.url?.absoluteString)
        #expect(url.hasPrefix("https://dev.azure.com/acme/My%20Project/_apis/git/pullrequests?"))
        #expect(url.contains("searchCriteria.status=active"))
        #expect(url.contains("api-version=7.1"))
    }

    @Test func patUsesBasicAuth() async throws {
        let http = MockHTTPClient()
        http.on("connectionData", body: #"{"authenticatedUser":{"id":"me-guid"}}"#)
        _ = try await makeProvider(http, auth: .pat, token: "secret").currentUserId()
        let expected = "Basic " + Data(":secret".utf8).base64EncodedString()
        #expect(http.requests.first?.value(forHTTPHeaderField: "Authorization") == expected)
    }

    @Test func cliUsesBearerAuth() async throws {
        let http = MockHTTPClient()
        http.on("connectionData", body: #"{"authenticatedUser":{"id":"me-guid"}}"#)
        let id = try await makeProvider(http, auth: .cli, token: "jwt").currentUserId()
        #expect(id == "me-guid")
        #expect(http.requests.first?.value(forHTTPHeaderField: "Authorization") == "Bearer jwt")
    }

    @Test func paginatesWithSkip() async throws {
        let http = MockHTTPClient()
        http.on("_apis/projects", body: projects)
        let page1 = (1...100).map { prJSON(id: $0) }.joined(separator: ",")
        http.on("skip=100", body: #"{"value":[\#(prJSON(id: 101))]}"#)
        http.on("skip=0", body: #"{"value":[\#(page1)]}"#)

        let prs = try await makeProvider(http).openPullRequests()
        #expect(prs.count == 101)
    }

    @Test func draftFlagIsMapped() async throws {
        let http = MockHTTPClient()
        http.on("_apis/projects", body: projects)
        http.on("_apis/git/pullrequests", body: #"{"value":[\#(prJSON(id: 1, draft: true))]}"#)
        #expect(try await makeProvider(http).openPullRequests().first?.isDraft == true)
    }

    @Test func invalidPatLoginPageIsUnauthorized() async {
        let http = MockHTTPClient()
        http.on("_apis/projects", status: 203, body: "<html>Sign in</html>")
        let provider = makeProvider(http)
        await #expect(throws: ProviderError.unauthorized) { try await provider.openPullRequests() }
    }

    @Test func listsReposAsProjectSlashRepo() async throws {
        let http = MockHTTPClient()
        http.on("_apis/projects", body: projects)
        http.on("_apis/git/repositories", body: #"{"value":[{"name":"web"},{"name":"api"}]}"#)
        #expect(try await makeProvider(http).listRepos() == ["My Project/api", "My Project/web"])
    }

    @Test func cachesProjectsForAnHour() async throws {
        let http = MockHTTPClient()
        http.on("_apis/projects", body: projects)
        http.on("_apis/git/pullrequests", body: #"{"value":[]}"#)
        let provider = makeProvider(http)
        _ = try await provider.openPullRequests()
        _ = try await provider.openPullRequests()
        let projectCalls = http.requests.filter { $0.url!.absoluteString.contains("_apis/projects") }
        #expect(projectCalls.count == 1)
    }
}
```

- [ ] **Step 2: Run tests, verwacht falen**

Run: `swift test --filter AzureDevOpsProviderTests`
Expected: compile error `cannot find 'AzureDevOpsProvider' in scope`.

- [ ] **Step 3: Implementeer**

`Sources/PullwatchCore/AzureDevOpsProvider.swift`:

```swift
import Foundation

public actor AzureDevOpsProvider: PRProvider {
    private let accountId: UUID
    private let organization: String
    private let tokenSource: any TokenSource
    private let authMethod: AuthMethod
    private let http: any HTTPClient
    private let now: @Sendable () -> Date
    private let pageSize = 100
    private var projectCache: (names: [String], fetchedAt: Date)?

    public init(
        accountId: UUID,
        organization: String,
        tokenSource: any TokenSource,
        authMethod: AuthMethod,
        http: any HTTPClient,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.accountId = accountId
        self.organization = organization
        self.tokenSource = tokenSource
        self.authMethod = authMethod
        self.http = http
        self.now = now
    }

    private var baseURL: URL {
        URL(string: "https://dev.azure.com")!.appending(path: organization)
    }

    public func currentUserId() async throws -> String {
        let data: ConnectionData = try await get(baseURL.appending(path: "_apis/connectionData"), apiVersion: "7.1-preview")
        return data.authenticatedUser.id
    }

    public func listRepos() async throws -> [String] {
        var result: [String] = []
        for project in try await projects() {
            let list: ValueList<RepositoryDTO> = try await get(
                baseURL.appending(path: project).appending(path: "_apis/git/repositories")
            )
            result += list.value.map { "\(project)/\($0.name)" }
        }
        return result.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    public func openPullRequests() async throws -> [PullRequest] {
        var result: [PullRequest] = []
        for project in try await projects() {
            var skip = 0
            while true {
                let page: ValueList<PullRequestDTO> = try await get(
                    baseURL.appending(path: project).appending(path: "_apis/git/pullrequests"),
                    query: [
                        URLQueryItem(name: "searchCriteria.status", value: "active"),
                        URLQueryItem(name: "$top", value: String(pageSize)),
                        URLQueryItem(name: "$skip", value: String(skip)),
                    ]
                )
                for dto in page.value {
                    result.append(try makePullRequest(dto))
                }
                if page.value.count < pageSize { break }
                skip += pageSize
            }
        }
        return result
    }

    public func invalidateCredentials() async {
        projectCache = nil
        await tokenSource.invalidate()
    }

    private func projects() async throws -> [String] {
        if let projectCache, now().timeIntervalSince(projectCache.fetchedAt) < 3600 {
            return projectCache.names
        }
        let list: ValueList<ProjectDTO> = try await get(
            baseURL.appending(path: "_apis/projects"),
            query: [URLQueryItem(name: "$top", value: "500")]
        )
        let names = list.value.map(\.name)
        projectCache = (names, now())
        return names
    }

    private func makePullRequest(_ dto: PullRequestDTO) throws -> PullRequest {
        guard let createdAt = DateParsing.parse(dto.creationDate) else {
            throw ProviderError.decoding("creationDate \(dto.creationDate)")
        }
        let project = dto.repository.project.name
        let webURL = baseURL
            .appending(path: project)
            .appending(path: "_git")
            .appending(path: dto.repository.name)
            .appending(path: "pullrequest")
            .appending(path: String(dto.pullRequestId))
        return PullRequest(
            accountId: accountId,
            repo: "\(project)/\(dto.repository.name)",
            number: dto.pullRequestId,
            title: dto.title,
            authorId: dto.createdBy.id,
            authorName: dto.createdBy.displayName,
            isDraft: dto.isDraft ?? false,
            createdAt: createdAt,
            webURL: webURL
        )
    }

    private func authorizationHeader() async throws -> String {
        let token = try await tokenSource.token()
        switch authMethod {
        case .pat: return "Basic " + Data(":\(token)".utf8).base64EncodedString()
        case .cli: return "Bearer \(token)"
        }
    }

    private func get<T: Decodable>(_ url: URL, apiVersion: String = "7.1", query: [URLQueryItem] = []) async throws -> T {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        components.queryItems = query + [URLQueryItem(name: "api-version", value: apiVersion)]
        var request = URLRequest(url: components.url!)
        let authorization = try await authorizationHeader()
        request.setValue(authorization, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await http.send(request)
        try HTTPStatus.check(response, now: now())
        return try JSONDecoding.decode(T.self, from: data)
    }
}

private struct ValueList<T: Decodable>: Decodable {
    let value: [T]
}

private struct ConnectionData: Decodable {
    struct User: Decodable { let id: String }
    let authenticatedUser: User
}

private struct ProjectDTO: Decodable {
    let name: String
}

private struct RepositoryDTO: Decodable {
    let name: String
}

private struct PullRequestDTO: Decodable {
    struct Identity: Decodable {
        let id: String
        let displayName: String
    }

    struct Repository: Decodable {
        struct Project: Decodable { let name: String }
        let name: String
        let project: Project
    }

    let pullRequestId: Int
    let title: String
    let isDraft: Bool?
    let creationDate: String
    let createdBy: Identity
    let repository: Repository
}
```

- [ ] **Step 4: Run tests, verwacht slagen**

Run: `swift test --filter AzureDevOpsProviderTests`
Expected: 9 tests PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/PullwatchCore/AzureDevOpsProvider.swift Tests/PullwatchCoreTests/AzureDevOpsProviderTests.swift
git commit -m "feat: add Azure DevOps PR provider

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 8: GitHubProvider

**Files:**
- Create: `Sources/PullwatchCore/GitHubProvider.swift`
- Test: `Tests/PullwatchCoreTests/GitHubProviderTests.swift`

**Interfaces:**
- Consumes: zelfde als Task 7
- Produces: `actor GitHubProvider: PRProvider` met `init(accountId: UUID, owner: String, tokenSource: any TokenSource, http: any HTTPClient, now: @escaping @Sendable () -> Date = { Date() })`

- [ ] **Step 1: Schrijf de falende tests**

`Tests/PullwatchCoreTests/GitHubProviderTests.swift`:

```swift
import Foundation
import Testing
@testable import PullwatchCore

@Suite struct GitHubProviderTests {
    func item(number: Int, repo: String = "acme/web", draft: Bool? = false, login: String = "octocat") -> String {
        let draftField = draft.map { #","draft":\#($0)"# } ?? ""
        return #"""
        {"number":\#(number),"title":"PR \#(number)","created_at":"2025-10-15T10:00:00Z"\#(draftField),
         "user":{"login":"\#(login)"},
         "html_url":"https://github.com/\#(repo)/pull/\#(number)",
         "repository_url":"https://api.github.com/repos/\#(repo)"}
        """#
    }

    func makeProvider(_ http: MockHTTPClient, owner: String = "acme") -> GitHubProvider {
        GitHubProvider(accountId: fixedAccountId, owner: owner, tokenSource: StaticTokenSource(token: "ghtok"), http: http)
    }

    @Test func searchesOpenPullRequestsForOrganization() async throws {
        let http = MockHTTPClient()
        http.on("search/issues", body: #"{"total_count":1,"items":[\#(item(number: 5, draft: true))]}"#)
        http.on("users/acme", body: #"{"type":"Organization"}"#)

        let prs = try await makeProvider(http).openPullRequests()

        let pr = try #require(prs.first)
        #expect(pr.repo == "acme/web")
        #expect(pr.number == 5)
        #expect(pr.title == "PR 5")
        #expect(pr.authorId == "octocat")
        #expect(pr.authorName == "octocat")
        #expect(pr.isDraft == true)
        #expect(pr.createdAt == Date(timeIntervalSince1970: 1_760_522_400))
        #expect(pr.webURL.absoluteString == "https://github.com/acme/web/pull/5")

        let searchURL = try #require(http.requests.last?.url)
        let q = URLComponents(url: searchURL, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "q" }?.value
        #expect(q == "is:pr is:open org:acme")
    }

    @Test func usesUserQualifierForUserOwner() async throws {
        let http = MockHTTPClient()
        http.on("search/issues", body: #"{"total_count":0,"items":[]}"#)
        http.on("users/alessandro", body: #"{"type":"User"}"#)

        _ = try await makeProvider(http, owner: "alessandro").openPullRequests()

        let searchURL = try #require(http.requests.last?.url)
        let q = URLComponents(url: searchURL, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "q" }?.value
        #expect(q == "is:pr is:open user:alessandro")
    }

    @Test func missingDraftFieldMeansNotDraft() async throws {
        let http = MockHTTPClient()
        http.on("search/issues", body: #"{"total_count":1,"items":[\#(item(number: 1, draft: nil))]}"#)
        http.on("users/acme", body: #"{"type":"Organization"}"#)
        #expect(try await makeProvider(http).openPullRequests().first?.isDraft == false)
    }

    @Test func sendsBearerAndGitHubHeaders() async throws {
        let http = MockHTTPClient()
        http.on("github.com/user", body: #"{"login":"alessandro"}"#)
        #expect(try await makeProvider(http).currentUserId() == "alessandro")
        let request = try #require(http.requests.first)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer ghtok")
        #expect(request.value(forHTTPHeaderField: "Accept") == "application/vnd.github+json")
        #expect(request.value(forHTTPHeaderField: "X-GitHub-Api-Version") == "2022-11-28")
    }

    @Test func listsOrgRepos() async throws {
        let http = MockHTTPClient()
        http.on("orgs/acme/repos", body: #"[{"full_name":"acme/web"},{"full_name":"acme/api"}]"#)
        http.on("users/acme", body: #"{"type":"Organization"}"#)
        #expect(try await makeProvider(http).listRepos() == ["acme/api", "acme/web"])
    }

    @Test func listsOwnReposIncludingPrivateViaUserEndpoint() async throws {
        let http = MockHTTPClient()
        http.on("user/repos", body: #"[{"full_name":"alessandro/secret"}]"#)
        http.on("users/alessandro", body: #"{"type":"User"}"#)
        http.on("github.com/user", body: #"{"login":"Alessandro"}"#)

        #expect(try await makeProvider(http, owner: "alessandro").listRepos() == ["alessandro/secret"])
        let reposURL = try #require(http.requests.last?.url?.absoluteString)
        #expect(reposURL.contains("affiliation=owner"))
    }

    @Test func rateLimitIsReported() async {
        let http = MockHTTPClient()
        http.on("users/acme", status: 403, headers: ["X-RateLimit-Remaining": "0", "X-RateLimit-Reset": "1760000600"], body: "{}")
        let provider = makeProvider(http)
        await #expect(throws: ProviderError.rateLimited(until: Date(timeIntervalSince1970: 1_760_000_600))) {
            try await provider.openPullRequests()
        }
    }

    @Test func paginatesSearchResults() async throws {
        let http = MockHTTPClient()
        let page1 = (1...100).map { item(number: $0) }.joined(separator: ",")
        http.on("page=2", body: #"{"total_count":101,"items":[\#(item(number: 101))]}"#)
        http.on("page=1", body: #"{"total_count":101,"items":[\#(page1)]}"#)
        http.on("users/acme", body: #"{"type":"Organization"}"#)
        #expect(try await makeProvider(http).openPullRequests().count == 101)
    }
}
```

- [ ] **Step 2: Run tests, verwacht falen**

Run: `swift test --filter GitHubProviderTests`
Expected: compile error `cannot find 'GitHubProvider' in scope`.

- [ ] **Step 3: Implementeer**

`Sources/PullwatchCore/GitHubProvider.swift`:

```swift
import Foundation

public actor GitHubProvider: PRProvider {
    private enum OwnerKind { case organization, user }

    private let accountId: UUID
    private let owner: String
    private let tokenSource: any TokenSource
    private let http: any HTTPClient
    private let now: @Sendable () -> Date
    private let apiBase = URL(string: "https://api.github.com")!
    private let pageSize = 100
    private let maxPages = 10
    private var ownerKind: OwnerKind?

    public init(
        accountId: UUID,
        owner: String,
        tokenSource: any TokenSource,
        http: any HTTPClient,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.accountId = accountId
        self.owner = owner
        self.tokenSource = tokenSource
        self.http = http
        self.now = now
    }

    public func currentUserId() async throws -> String {
        let user: UserDTO = try await get(apiBase.appending(path: "user"))
        return user.login
    }

    public func listRepos() async throws -> [String] {
        var url: URL
        var query: [URLQueryItem] = []
        switch try await resolveOwnerKind() {
        case .organization:
            url = apiBase.appending(path: "orgs").appending(path: owner).appending(path: "repos")
        case .user:
            let login = try await currentUserId()
            if login.caseInsensitiveCompare(owner) == .orderedSame {
                // /users/{owner}/repos toont geen private repos; voor jezelf /user/repos gebruiken.
                url = apiBase.appending(path: "user/repos")
                query = [URLQueryItem(name: "affiliation", value: "owner")]
            } else {
                url = apiBase.appending(path: "users").appending(path: owner).appending(path: "repos")
            }
        }

        var names: [String] = []
        for page in 1...maxPages {
            let repos: [RepoDTO] = try await get(url, query: query + [
                URLQueryItem(name: "per_page", value: String(pageSize)),
                URLQueryItem(name: "page", value: String(page)),
            ])
            names += repos.map(\.fullName)
            if repos.count < pageSize { break }
        }
        return names.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    public func openPullRequests() async throws -> [PullRequest] {
        let qualifier = try await resolveOwnerKind() == .organization ? "org" : "user"
        var result: [PullRequest] = []
        for page in 1...maxPages {
            let response: SearchDTO = try await get(apiBase.appending(path: "search/issues"), query: [
                URLQueryItem(name: "q", value: "is:pr is:open \(qualifier):\(owner)"),
                URLQueryItem(name: "per_page", value: String(pageSize)),
                URLQueryItem(name: "page", value: String(page)),
            ])
            for item in response.items {
                result.append(try makePullRequest(item))
            }
            if response.items.count < pageSize || result.count >= response.totalCount { break }
        }
        return result
    }

    public func invalidateCredentials() async {
        await tokenSource.invalidate()
    }

    private func resolveOwnerKind() async throws -> OwnerKind {
        if let ownerKind { return ownerKind }
        let info: OwnerDTO = try await get(apiBase.appending(path: "users").appending(path: owner))
        let kind: OwnerKind = info.type == "Organization" ? .organization : .user
        ownerKind = kind
        return kind
    }

    private func makePullRequest(_ item: SearchDTO.Item) throws -> PullRequest {
        guard let createdAt = DateParsing.parse(item.createdAt) else {
            throw ProviderError.decoding("created_at \(item.createdAt)")
        }
        guard let webURL = URL(string: item.htmlUrl),
              let repoURL = URL(string: item.repositoryUrl) else {
            throw ProviderError.decoding("url in PR \(item.number)")
        }
        let repo = repoURL.pathComponents.suffix(2).joined(separator: "/")
        return PullRequest(
            accountId: accountId,
            repo: repo,
            number: item.number,
            title: item.title,
            authorId: item.user.login,
            authorName: item.user.login,
            isDraft: item.draft ?? false,
            createdAt: createdAt,
            webURL: webURL
        )
    }

    private func get<T: Decodable>(_ url: URL, query: [URLQueryItem] = []) async throws -> T {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        if !query.isEmpty { components.queryItems = query }
        var request = URLRequest(url: components.url!)
        let token = try await tokenSource.token()
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        let (data, response) = try await http.send(request)
        try HTTPStatus.check(response, now: now())
        return try JSONDecoding.decode(T.self, from: data, snakeCase: true)
    }
}

private struct UserDTO: Decodable {
    let login: String
}

private struct OwnerDTO: Decodable {
    let type: String
}

private struct RepoDTO: Decodable {
    let fullName: String
}

private struct SearchDTO: Decodable {
    struct Item: Decodable {
        let number: Int
        let title: String
        let createdAt: String
        let draft: Bool?
        let user: UserDTO
        let htmlUrl: String
        let repositoryUrl: String
    }

    let totalCount: Int
    let items: [Item]
}
```

- [ ] **Step 4: Run tests, verwacht slagen**

Run: `swift test --filter GitHubProviderTests`
Expected: 8 tests PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/PullwatchCore/GitHubProvider.swift Tests/PullwatchCoreTests/GitHubProviderTests.swift
git commit -m "feat: add GitHub PR provider using search API

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 9: Backoff, NotificationPlanner en ProviderFactory

**Files:**
- Create: `Sources/PullwatchCore/Backoff.swift`, `Sources/PullwatchCore/NotificationPlanner.swift`, `Sources/PullwatchCore/ProviderFactory.swift`
- Test: `Tests/PullwatchCoreTests/GlueTests.swift`

**Interfaces:**
- Consumes: alles uit Task 1–8
- Produces:
  - `enum Backoff { static func delay(baseInterval: TimeInterval, consecutiveFailures: Int, maxDelay: TimeInterval = 900) -> TimeInterval }`
  - `enum PlannedNotification: Equatable, Sendable { case single(PullRequest); case summary(count: Int, lines: [String]) }`
  - `enum NotificationPlanner { static let burstThreshold = 3; static func plan(_ prs: [PullRequest]) -> [PlannedNotification] }`
  - `enum ProviderFactory { static func make(_ account: Account, pat: String? = nil, secrets: any SecretStore = KeychainStore(), http: any HTTPClient = URLSessionHTTPClient(), runner: any ProcessRunner = SystemProcessRunner()) -> any PRProvider }`

- [ ] **Step 1: Schrijf de falende tests**

`Tests/PullwatchCoreTests/GlueTests.swift`:

```swift
import Foundation
import Testing
@testable import PullwatchCore

@Suite struct GlueTests {
    @Test func backoffDoublesPerFailureAndCaps() {
        #expect(Backoff.delay(baseInterval: 120, consecutiveFailures: 0) == 120)
        #expect(Backoff.delay(baseInterval: 120, consecutiveFailures: 1) == 240)
        #expect(Backoff.delay(baseInterval: 120, consecutiveFailures: 2) == 480)
        #expect(Backoff.delay(baseInterval: 120, consecutiveFailures: 3) == 900)
        #expect(Backoff.delay(baseInterval: 120, consecutiveFailures: 50) == 900)
    }

    @Test func upToThreeNewPullRequestsGetIndividualNotifications() {
        let prs = (1...3).map { PullRequest.fixture(number: $0) }
        #expect(NotificationPlanner.plan(prs) == prs.map { .single($0) })
    }

    @Test func moreThanThreeBecomesOneSummaryWithFirstThreeLines() {
        let prs = (1...5).map { PullRequest.fixture(repo: "p/r", number: $0, title: "T\($0)") }
        #expect(NotificationPlanner.plan(prs) == [.summary(count: 5, lines: ["p/r: T1", "p/r: T2", "p/r: T3"])])
    }

    @Test func emptyInputPlansNothing() {
        #expect(NotificationPlanner.plan([]).isEmpty)
    }

    @Test func factoryPicksProviderByKind() {
        #expect(ProviderFactory.make(Account.fixture(kind: .azureDevOps)) is AzureDevOpsProvider)
        #expect(ProviderFactory.make(Account.fixture(kind: .gitHub)) is GitHubProvider)
    }

    @Test func factoryUsesPatOverrideBeforeKeychain() async throws {
        let http = MockHTTPClient()
        http.on("github.com/user", body: #"{"login":"me"}"#)
        let provider = ProviderFactory.make(Account.fixture(kind: .gitHub), pat: "typed", secrets: InMemorySecretStore(), http: http)
        _ = try await provider.currentUserId()
        #expect(http.requests.first?.value(forHTTPHeaderField: "Authorization") == "Bearer typed")
    }

    @Test func factoryReadsPatFromSecretStore() async throws {
        let http = MockHTTPClient()
        http.on("github.com/user", body: #"{"login":"me"}"#)
        let account = Account.fixture(kind: .gitHub)
        let secrets = InMemorySecretStore()
        try secrets.write("stored", account: account.id.uuidString)
        _ = try await ProviderFactory.make(account, secrets: secrets, http: http).currentUserId()
        #expect(http.requests.first?.value(forHTTPHeaderField: "Authorization") == "Bearer stored")
    }
}
```

- [ ] **Step 2: Run tests, verwacht falen**

Run: `swift test --filter GlueTests`
Expected: compile error `cannot find 'Backoff' in scope`.

- [ ] **Step 3: Implementeer**

`Sources/PullwatchCore/Backoff.swift`:

```swift
import Foundation

public enum Backoff {
    public static func delay(baseInterval: TimeInterval, consecutiveFailures: Int, maxDelay: TimeInterval = 900) -> TimeInterval {
        guard consecutiveFailures > 0 else { return baseInterval }
        let exponent = Double(min(consecutiveFailures, 16))
        return min(baseInterval * pow(2, exponent), maxDelay)
    }
}
```

`Sources/PullwatchCore/NotificationPlanner.swift`:

```swift
import Foundation

public enum PlannedNotification: Equatable, Sendable {
    case single(PullRequest)
    case summary(count: Int, lines: [String])
}

public enum NotificationPlanner {
    public static let burstThreshold = 3

    public static func plan(_ prs: [PullRequest]) -> [PlannedNotification] {
        if prs.count > burstThreshold {
            let lines = prs.prefix(3).map { "\($0.repo): \($0.title)" }
            return [.summary(count: prs.count, lines: lines)]
        }
        return prs.map { .single($0) }
    }
}
```

`Sources/PullwatchCore/ProviderFactory.swift`:

```swift
import Foundation

public enum ProviderFactory {
    /// `pat` overschrijft de Keychain (gebruikt bij "Test verbinding" vóór opslaan).
    public static func make(
        _ account: Account,
        pat: String? = nil,
        secrets: any SecretStore = KeychainStore(),
        http: any HTTPClient = URLSessionHTTPClient(),
        runner: any ProcessRunner = SystemProcessRunner()
    ) -> any PRProvider {
        let tokens: any TokenSource
        switch account.authMethod {
        case .pat:
            if let pat {
                tokens = StaticTokenSource(token: pat)
            } else {
                tokens = KeychainPATSource(store: secrets, accountId: account.id)
            }
        case .cli:
            switch account.kind {
            case .azureDevOps: tokens = AzCLISource(runner: runner)
            case .gitHub: tokens = GhCLISource(runner: runner)
            }
        }

        switch account.kind {
        case .azureDevOps:
            return AzureDevOpsProvider(
                accountId: account.id,
                organization: account.organization,
                tokenSource: tokens,
                authMethod: account.authMethod,
                http: http
            )
        case .gitHub:
            return GitHubProvider(accountId: account.id, owner: account.organization, tokenSource: tokens, http: http)
        }
    }
}
```

- [ ] **Step 4: Run tests, verwacht slagen**

Run: `swift test --filter GlueTests`
Expected: 7 tests PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/PullwatchCore/Backoff.swift Sources/PullwatchCore/NotificationPlanner.swift Sources/PullwatchCore/ProviderFactory.swift Tests/PullwatchCoreTests/GlueTests.swift
git commit -m "feat: add backoff, notification planner and provider factory

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 10: PollEngine

**Files:**
- Create: `Sources/PullwatchCore/PollEngine.swift`
- Create: `Tests/PullwatchCoreTests/Support/MockProvider.swift`
- Test: `Tests/PullwatchCoreTests/PollEngineTests.swift`

**Interfaces:**
- Consumes: `PRProvider`, `ProviderError` (Task 4), `SeenState` (Task 3), `PRFilter`/`FilterSettings` (Task 2), `JSONFileStore` (Task 1), `Backoff` (Task 9)
- Produces:
  - `enum AccountState: Equatable, Sendable { case idle; case ok(lastPoll: Date); case failed(ProviderError, since: Date) }`
  - `struct PollResult: Equatable, Sendable { newPullRequests: [PullRequest]; statuses: [UUID: AccountState]; authFailures: [UUID] }`
  - `actor PollEngine` met `init(makeProvider: @escaping @Sendable (Account) -> any PRProvider, store: JSONFileStore<SeenState>?, now: @escaping @Sendable () -> Date = { Date() })`, `func poll(accounts: [Account], interval: TimeInterval) async -> PollResult`, `func forceRefresh()`

**Gedrag (uit spec):**
- Alleen accounts waarvan `nextDue <= now` worden gepold. Na succes: `nextDue = now + interval`. Na fout: `now + Backoff.delay(...)`, bij rate limit: `until`.
- Melden alleen als de PR door de huidige filter komt, nog niet in `seen` staat, én er vorige settings van dezelfde bron zijn waar de PR óók doorheen kwam. Anders stil seeden.
- Elke PR die door de filter komt, krijgt `mark(…, at: now)` (ververst timestamp → geen re-notify na prune).
- `authFailures` bevat een account alleen bij de overgang naar `.unauthorized`.
- `forceRefresh()` zet `nextDue = now` behalve bij lopende rate limit.

- [ ] **Step 1: Schrijf MockProvider en de falende tests**

`Tests/PullwatchCoreTests/Support/MockProvider.swift`:

```swift
import Foundation
@testable import PullwatchCore

actor MockProvider: PRProvider {
    private var userId = "me"
    private var pullRequests: [PullRequest] = []
    private var error: ProviderError?
    private(set) var fetchCount = 0
    private(set) var invalidateCount = 0

    func set(pullRequests: [PullRequest]) { self.pullRequests = pullRequests }
    func set(error: ProviderError?) { self.error = error }

    func currentUserId() async throws -> String {
        if let error { throw error }
        return userId
    }

    func listRepos() async throws -> [String] { [] }

    func openPullRequests() async throws -> [PullRequest] {
        fetchCount += 1
        if let error { throw error }
        return pullRequests
    }

    func invalidateCredentials() async { invalidateCount += 1 }
}
```

`Tests/PullwatchCoreTests/PollEngineTests.swift`:

```swift
import Foundation
import Testing
@testable import PullwatchCore

private struct Harness {
    let clock: TestClock
    let providers: [UUID: MockProvider]
    let engine: PollEngine

    init(accounts: [Account], store: JSONFileStore<SeenState>? = nil) {
        let clock = TestClock()
        let providers = Dictionary(uniqueKeysWithValues: accounts.map { ($0.id, MockProvider()) })
        self.clock = clock
        self.providers = providers
        self.engine = PollEngine(makeProvider: { providers[$0.id]! }, store: store, now: { clock.now })
    }

    func provider(_ account: Account) -> MockProvider { providers[account.id]! }
}

@Suite struct PollEngineTests {
    let day: TimeInterval = 24 * 3600

    @Test func firstPollSeedsSilentlyThenNotifiesNewPR() async {
        let account = Account.fixture()
        let h = Harness(accounts: [account])
        let a = PullRequest.fixture(accountId: account.id, number: 1)
        await h.provider(account).set(pullRequests: [a])

        #expect(await h.engine.poll(accounts: [account], interval: 120).newPullRequests.isEmpty)

        let b = PullRequest.fixture(accountId: account.id, number: 2)
        await h.provider(account).set(pullRequests: [a, b])
        h.clock.advance(120)
        #expect(await h.engine.poll(accounts: [account], interval: 120).newPullRequests == [b])
    }

    @Test func notDueAccountIsSkippedUntilForceRefresh() async {
        let account = Account.fixture()
        let h = Harness(accounts: [account])
        _ = await h.engine.poll(accounts: [account], interval: 120)

        let b = PullRequest.fixture(accountId: account.id, number: 2)
        await h.provider(account).set(pullRequests: [b])
        h.clock.advance(10)
        #expect(await h.engine.poll(accounts: [account], interval: 120).newPullRequests.isEmpty)
        #expect(await h.provider(account).fetchCount == 1)

        await h.engine.forceRefresh()
        #expect(await h.engine.poll(accounts: [account], interval: 120).newPullRequests == [b])
    }

    @Test func longOpenPullRequestIsNotRenotifiedAfterPrune() async {
        let account = Account.fixture()
        let h = Harness(accounts: [account])
        let a = PullRequest.fixture(accountId: account.id, number: 1)
        await h.provider(account).set(pullRequests: [a])

        for _ in 0..<4 {
            #expect(await h.engine.poll(accounts: [account], interval: 120).newPullRequests.isEmpty)
            h.clock.advance(20 * day)
        }
    }

    @Test func addingRepoToAllowlistSeedsItsExistingPRsSilently() async {
        var account = Account.fixture(filterMode: .allow, repos: ["proj/a"])
        let h = Harness(accounts: [account])
        let a1 = PullRequest.fixture(accountId: account.id, repo: "proj/a", number: 1)
        let b1 = PullRequest.fixture(accountId: account.id, repo: "proj/b", number: 1)
        await h.provider(account).set(pullRequests: [a1, b1])
        _ = await h.engine.poll(accounts: [account], interval: 120)

        account.repos.append("proj/b")
        h.clock.advance(120)
        #expect(await h.engine.poll(accounts: [account], interval: 120).newPullRequests.isEmpty)

        let b2 = PullRequest.fixture(accountId: account.id, repo: "proj/b", number: 2)
        await h.provider(account).set(pullRequests: [a1, b1, b2])
        h.clock.advance(120)
        #expect(await h.engine.poll(accounts: [account], interval: 120).newPullRequests == [b2])
    }

    @Test func turningOnDraftsDoesNotFloodWithExistingDrafts() async {
        var account = Account.fixture(includeDrafts: false)
        let h = Harness(accounts: [account])
        let draft = PullRequest.fixture(accountId: account.id, number: 1, isDraft: true)
        await h.provider(account).set(pullRequests: [draft])
        _ = await h.engine.poll(accounts: [account], interval: 120)

        account.includeDrafts = true
        h.clock.advance(120)
        #expect(await h.engine.poll(accounts: [account], interval: 120).newPullRequests.isEmpty)
    }

    @Test func draftBecomingReadyForReviewNotifies() async {
        let account = Account.fixture(includeDrafts: false)
        let h = Harness(accounts: [account])
        let draft = PullRequest.fixture(accountId: account.id, number: 1, isDraft: true)
        await h.provider(account).set(pullRequests: [draft])
        _ = await h.engine.poll(accounts: [account], interval: 120)

        let ready = PullRequest.fixture(accountId: account.id, number: 1, isDraft: false)
        await h.provider(account).set(pullRequests: [ready])
        h.clock.advance(120)
        #expect(await h.engine.poll(accounts: [account], interval: 120).newPullRequests == [ready])
    }

    @Test func ownPullRequestsAreHidden() async {
        let account = Account.fixture(hideOwn: true)
        let h = Harness(accounts: [account])
        _ = await h.engine.poll(accounts: [account], interval: 120)

        let mine = PullRequest.fixture(accountId: account.id, number: 1, authorId: "me")
        let theirs = PullRequest.fixture(accountId: account.id, number: 2, authorId: "colleague")
        await h.provider(account).set(pullRequests: [mine, theirs])
        h.clock.advance(120)
        #expect(await h.engine.poll(accounts: [account], interval: 120).newPullRequests == [theirs])
    }

    @Test func changingOrganizationReseedsSilently() async {
        var account = Account.fixture(organization: "old")
        let h = Harness(accounts: [account])
        _ = await h.engine.poll(accounts: [account], interval: 120)

        account.organization = "new"
        let pr = PullRequest.fixture(accountId: account.id, number: 9)
        await h.provider(account).set(pullRequests: [pr])
        h.clock.advance(120)
        #expect(await h.engine.poll(accounts: [account], interval: 120).newPullRequests.isEmpty)
    }

    @Test func failingAccountDoesNotBlockOthers() async {
        let good = Account.fixture()
        let bad = Account.fixture()
        let h = Harness(accounts: [good, bad])
        _ = await h.engine.poll(accounts: [good, bad], interval: 120)

        let pr = PullRequest.fixture(accountId: good.id, number: 1)
        await h.provider(good).set(pullRequests: [pr])
        await h.provider(bad).set(error: .server(status: 500))
        h.clock.advance(120)
        let result = await h.engine.poll(accounts: [good, bad], interval: 120)

        #expect(result.newPullRequests == [pr])
        #expect(result.statuses[good.id] == .ok(lastPoll: h.clock.now))
        #expect(result.statuses[bad.id] == .failed(.server(status: 500), since: h.clock.now))
    }

    @Test func unauthorizedIsReportedOnceAndInvalidatesCredentials() async {
        let account = Account.fixture()
        let h = Harness(accounts: [account])
        await h.provider(account).set(error: .unauthorized)

        #expect(await h.engine.poll(accounts: [account], interval: 120).authFailures == [account.id])
        h.clock.advance(900)
        #expect(await h.engine.poll(accounts: [account], interval: 120).authFailures.isEmpty)
        #expect(await h.provider(account).invalidateCount == 2)
    }

    @Test func failuresBackOffExponentially() async {
        let account = Account.fixture()
        let h = Harness(accounts: [account])
        _ = await h.engine.poll(accounts: [account], interval: 120) // succes, fetchCount 1
        await h.provider(account).set(error: .network("offline"))

        h.clock.advance(120)
        _ = await h.engine.poll(accounts: [account], interval: 120) // fout 1 → volgende over 240 s
        #expect(await h.provider(account).fetchCount == 2)

        h.clock.advance(200)
        _ = await h.engine.poll(accounts: [account], interval: 120)
        #expect(await h.provider(account).fetchCount == 2)

        h.clock.advance(50)
        _ = await h.engine.poll(accounts: [account], interval: 120)
        #expect(await h.provider(account).fetchCount == 3)
    }

    @Test func rateLimitIsRespectedEvenOnForceRefresh() async {
        let account = Account.fixture()
        let h = Harness(accounts: [account])
        _ = await h.engine.poll(accounts: [account], interval: 120)
        await h.provider(account).set(error: .rateLimited(until: h.clock.now + 600))
        h.clock.advance(120)
        _ = await h.engine.poll(accounts: [account], interval: 120)
        #expect(await h.provider(account).fetchCount == 2)

        await h.engine.forceRefresh()
        h.clock.advance(300)
        _ = await h.engine.poll(accounts: [account], interval: 120)
        #expect(await h.provider(account).fetchCount == 2)
    }

    @Test func stateSurvivesRestartViaStore() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = JSONFileStore<SeenState>(url: dir.appending(path: "seen.json"))
        let account = Account.fixture()
        let a = PullRequest.fixture(accountId: account.id, number: 1)

        let first = Harness(accounts: [account], store: store)
        await first.provider(account).set(pullRequests: [a])
        _ = await first.engine.poll(accounts: [account], interval: 120)

        let second = Harness(accounts: [account], store: store)
        let b = PullRequest.fixture(accountId: account.id, number: 2)
        await second.provider(account).set(pullRequests: [a, b])
        #expect(await second.engine.poll(accounts: [account], interval: 120).newPullRequests == [b])
    }

    @Test func statusesCoverAllAccountsIncludingNotYetPolled() async {
        let account = Account.fixture()
        let other = Account.fixture()
        let h = Harness(accounts: [account, other])
        await h.provider(account).set(error: .network("x"))
        _ = await h.engine.poll(accounts: [account], interval: 120)
        h.clock.advance(1)
        let result = await h.engine.poll(accounts: [account, other], interval: 120)
        #expect(result.statuses.count == 2)
        #expect(result.statuses[other.id] == .ok(lastPoll: h.clock.now))
    }
}
```

- [ ] **Step 2: Run tests, verwacht falen**

Run: `swift test --filter PollEngineTests`
Expected: compile error `cannot find 'PollEngine' in scope`.

- [ ] **Step 3: Implementeer**

`Sources/PullwatchCore/PollEngine.swift`:

```swift
import Foundation
import os

private let logger = Logger(subsystem: "nl.torrisi.pullwatch", category: "engine")

public enum AccountState: Equatable, Sendable {
    case idle
    case ok(lastPoll: Date)
    case failed(ProviderError, since: Date)
}

public struct PollResult: Equatable, Sendable {
    public var newPullRequests: [PullRequest] = []
    public var statuses: [UUID: AccountState] = [:]
    /// Accounts die in deze cyclus net naar `.unauthorized` gingen (één melding per overgang).
    public var authFailures: [UUID] = []
}

public actor PollEngine {
    public typealias ProviderFactory = @Sendable (Account) -> any PRProvider

    private struct Schedule {
        var nextDue: Date = .distantPast
        var failures = 0
        var rateLimitedUntil: Date?
    }

    private struct Fetched {
        let userId: String
        let pullRequests: [PullRequest]
    }

    private let makeProvider: ProviderFactory
    private let store: JSONFileStore<SeenState>?
    private let now: @Sendable () -> Date
    private var state: SeenState
    private var providers: [UUID: (account: Account, provider: any PRProvider)] = [:]
    private var userIds: [UUID: String] = [:]
    private var schedules: [UUID: Schedule] = [:]
    private var statuses: [UUID: AccountState] = [:]

    public init(
        makeProvider: @escaping ProviderFactory,
        store: JSONFileStore<SeenState>?,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.makeProvider = makeProvider
        self.store = store
        self.now = now
        do {
            self.state = try store?.load() ?? SeenState()
        } catch {
            logger.error("seen-state onleesbaar, start leeg: \(error.localizedDescription)")
            self.state = SeenState()
        }
    }

    public func forceRefresh() {
        let t = now()
        for (id, var schedule) in schedules {
            if let until = schedule.rateLimitedUntil, until > t { continue }
            schedule.nextDue = t
            schedules[id] = schedule
        }
    }

    public func poll(accounts: [Account], interval: TimeInterval) async -> PollResult {
        let t = now()
        forget(except: Set(accounts.map(\.id)))

        let jobs = accounts
            .filter { (schedules[$0.id]?.nextDue ?? .distantPast) <= t }
            .map { (account: $0, provider: provider(for: $0), userId: userIds[$0.id]) }

        let outcomes = await withTaskGroup(of: (UUID, Result<Fetched, ProviderError>).self) { group in
            for job in jobs {
                group.addTask {
                    (job.account.id, await Self.fetch(job.provider, knownUserId: job.userId))
                }
            }
            var collected: [UUID: Result<Fetched, ProviderError>] = [:]
            for await (id, outcome) in group {
                collected[id] = outcome
            }
            return collected
        }

        var result = PollResult()
        for job in jobs {
            guard let outcome = outcomes[job.account.id] else { continue }
            switch outcome {
            case .success(let fetched):
                result.newPullRequests += handleSuccess(job.account, fetched, at: t, interval: interval)
            case .failure(let error):
                if await handleFailure(job.account, job.provider, error, at: t, interval: interval) {
                    result.authFailures.append(job.account.id)
                }
            }
        }

        state.prune(now: t)
        do {
            try store?.save(state)
        } catch {
            logger.error("seen-state opslaan mislukt: \(error.localizedDescription)")
        }

        result.newPullRequests.sort { $0.createdAt < $1.createdAt }
        result.statuses = Dictionary(uniqueKeysWithValues: accounts.map { ($0.id, statuses[$0.id] ?? .idle) })
        return result
    }

    private static func fetch(_ provider: any PRProvider, knownUserId: String?) async -> Result<Fetched, ProviderError> {
        do {
            let userId: String
            if let knownUserId {
                userId = knownUserId
            } else {
                userId = try await provider.currentUserId()
            }
            let pullRequests = try await provider.openPullRequests()
            return .success(Fetched(userId: userId, pullRequests: pullRequests))
        } catch let error as ProviderError {
            return .failure(error)
        } catch {
            return .failure(.network(error.localizedDescription))
        }
    }

    private func provider(for account: Account) -> any PRProvider {
        if let cached = providers[account.id], cached.account == account {
            return cached.provider
        }
        let provider = makeProvider(account)
        providers[account.id] = (account, provider)
        userIds[account.id] = nil
        return provider
    }

    private func forget(except ids: Set<UUID>) {
        providers = providers.filter { ids.contains($0.key) }
        userIds = userIds.filter { ids.contains($0.key) }
        schedules = schedules.filter { ids.contains($0.key) }
        statuses = statuses.filter { ids.contains($0.key) }
        let keys = Set(ids.map(\.uuidString))
        state.lastSettings = state.lastSettings.filter { keys.contains($0.key) }
    }

    private func handleSuccess(_ account: Account, _ fetched: Fetched, at t: Date, interval: TimeInterval) -> [PullRequest] {
        let settings = account.filterSettings
        let key = account.id.uuidString
        let previous = state.lastSettings[key].flatMap { $0.sameSource(as: settings) ? $0 : nil }

        var fresh: [PullRequest] = []
        for pr in fetched.pullRequests where PRFilter.passes(pr, settings: settings, currentUserId: fetched.userId) {
            // Alleen melden als de PR onder de vorige settings ook zichtbaar was; anders is hij
            // pas zichtbaar door een instellingswijziging of eerste poll → stil seeden.
            if !state.contains(pr.dedupKey), let previous,
               PRFilter.passes(pr, settings: previous, currentUserId: fetched.userId) {
                fresh.append(pr)
            }
            state.mark(pr.dedupKey, at: t)
        }

        state.lastSettings[key] = settings
        userIds[account.id] = fetched.userId
        schedules[account.id] = Schedule(nextDue: t + interval)
        statuses[account.id] = .ok(lastPoll: t)
        return fresh
    }

    /// Geeft `true` als het account net naar `.unauthorized` is overgegaan.
    private func handleFailure(
        _ account: Account,
        _ provider: any PRProvider,
        _ error: ProviderError,
        at t: Date,
        interval: TimeInterval
    ) async -> Bool {
        var schedule = schedules[account.id] ?? Schedule()
        schedule.failures += 1
        if case .rateLimited(let until) = error {
            schedule.rateLimitedUntil = until
            schedule.nextDue = until
        } else {
            schedule.rateLimitedUntil = nil
            schedule.nextDue = t + Backoff.delay(baseInterval: interval, consecutiveFailures: schedule.failures)
        }
        schedules[account.id] = schedule

        var wasUnauthorized = false
        if case .failed(let previous, let since) = statuses[account.id], previous == error {
            wasUnauthorized = previous == .unauthorized
            statuses[account.id] = .failed(error, since: since)
        } else {
            statuses[account.id] = .failed(error, since: t)
        }
        logger.warning("poll mislukt voor \(account.displayName, privacy: .public): \(error.userMessage, privacy: .public)")

        guard error == .unauthorized else { return false }
        userIds[account.id] = nil
        await provider.invalidateCredentials()
        return !wasUnauthorized
    }
}
```

- [ ] **Step 4: Run tests, verwacht slagen**

Run: `swift test --filter PollEngineTests`
Expected: 14 tests PASS.

- [ ] **Step 5: Run de volledige suite**

Run: `swift test`
Expected: alle tests PASS, geen warnings over Sendable.

- [ ] **Step 6: Commit**

```bash
git add Sources/PullwatchCore/PollEngine.swift Tests/PullwatchCoreTests/Support/MockProvider.swift Tests/PullwatchCoreTests/PollEngineTests.swift
git commit -m "feat: add poll engine with seeding, scheduling and error isolation

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 11: AppConfig en RecentList

**Files:**
- Create: `Sources/PullwatchCore/AppConfig.swift`, `Sources/PullwatchCore/RecentList.swift`
- Test: `Tests/PullwatchCoreTests/AppStateTests.swift`

**Interfaces:**
- Consumes: `Account`, `PullRequest`, `JSONFileStore` (Task 1)
- Produces:
  - `struct AppConfig: Codable, Equatable, Sendable { var accounts: [Account]; var pollInterval: Int; init(accounts: = [], pollInterval: = 120); var clampedInterval: Int; var pollableAccounts: [Account]; static let intervalRange = 60...900 }`
  - `struct RecentItem: Codable, Equatable, Sendable, Identifiable { var pullRequest: PullRequest; var detectedAt: Date; var isRead: Bool; var id: String }`
  - `struct RecentList: Codable, Equatable, Sendable { static let capacity = 50; private(set) var items; init(); var unreadCount: Int; mutating add(_:at:), markRead(_ key: String), markAllRead(), removeAccount(_ id: UUID) }`

- [ ] **Step 1: Schrijf de falende tests**

`Tests/PullwatchCoreTests/AppStateTests.swift`:

```swift
import Foundation
import Testing
@testable import PullwatchCore

@Suite struct AppStateTests {
    let t0 = Date(timeIntervalSince1970: 1_760_000_000)

    @Test func configDefaults() {
        let config = AppConfig()
        #expect(config.accounts.isEmpty)
        #expect(config.pollInterval == 120)
    }

    @Test func intervalIsClamped() {
        #expect(AppConfig(pollInterval: 5).clampedInterval == 60)
        #expect(AppConfig(pollInterval: 5000).clampedInterval == 900)
        #expect(AppConfig(pollInterval: 300).clampedInterval == 300)
    }

    @Test func accountsWithoutOrganizationAreNotPolled() {
        let config = AppConfig(accounts: [Account.fixture(organization: ""), Account.fixture(organization: "acme")])
        #expect(config.pollableAccounts.map(\.organization) == ["acme"])
    }

    @Test func configRoundTrips() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = JSONFileStore<AppConfig>(url: dir.appending(path: "config.json"))
        let config = AppConfig(accounts: [Account.fixture(repos: ["a/b"])], pollInterval: 300)
        try store.save(config)
        #expect(try store.load() == config)
    }

    @Test func recentAddsNewestFirstAsUnread() {
        var list = RecentList()
        let a = PullRequest.fixture(number: 1, createdAt: t0)
        let b = PullRequest.fixture(number: 2, createdAt: t0 + 60)
        list.add([a, b], at: t0 + 120)
        #expect(list.items.map(\.pullRequest) == [b, a])
        #expect(list.unreadCount == 2)
    }

    @Test func recentReplacesDuplicateAndCapsAt50() {
        var list = RecentList()
        list.add((1...60).map { PullRequest.fixture(number: $0, createdAt: t0 + Double($0)) }, at: t0)
        #expect(list.items.count == 50)
        #expect(list.items.first?.pullRequest.number == 60)

        list.add([PullRequest.fixture(number: 55, createdAt: t0 + 1000)], at: t0)
        #expect(list.items.count == 50)
        #expect(list.items.filter { $0.pullRequest.number == 55 }.count == 1)
        #expect(list.items.first?.pullRequest.number == 55)
    }

    @Test func markReadAndMarkAllRead() {
        var list = RecentList()
        let a = PullRequest.fixture(number: 1)
        let b = PullRequest.fixture(number: 2)
        list.add([a, b], at: t0)
        list.markRead(a.dedupKey)
        #expect(list.unreadCount == 1)
        list.markAllRead()
        #expect(list.unreadCount == 0)
    }

    @Test func removeAccountDropsItsItems() {
        var list = RecentList()
        let other = UUID()
        list.add([PullRequest.fixture(accountId: fixedAccountId, number: 1), PullRequest.fixture(accountId: other, number: 1)], at: t0)
        list.removeAccount(fixedAccountId)
        #expect(list.items.map(\.pullRequest.accountId) == [other])
    }
}
```

- [ ] **Step 2: Run tests, verwacht falen**

Run: `swift test --filter AppStateTests`
Expected: compile error `cannot find 'AppConfig' in scope`.

- [ ] **Step 3: Implementeer**

`Sources/PullwatchCore/AppConfig.swift`:

```swift
import Foundation

public struct AppConfig: Codable, Equatable, Sendable {
    public static let intervalRange = 60...900

    public var accounts: [Account]
    public var pollInterval: Int

    public init(accounts: [Account] = [], pollInterval: Int = 120) {
        self.accounts = accounts
        self.pollInterval = pollInterval
    }

    public var clampedInterval: Int {
        min(max(pollInterval, Self.intervalRange.lowerBound), Self.intervalRange.upperBound)
    }

    /// Accounts die net zijn toegevoegd en nog geen organisatie hebben, worden niet gepold.
    public var pollableAccounts: [Account] {
        accounts.filter { !$0.organization.trimmingCharacters(in: .whitespaces).isEmpty }
    }
}
```

`Sources/PullwatchCore/RecentList.swift`:

```swift
import Foundation

public struct RecentItem: Codable, Equatable, Sendable, Identifiable {
    public var pullRequest: PullRequest
    public var detectedAt: Date
    public var isRead: Bool

    public var id: String { pullRequest.dedupKey }
}

public struct RecentList: Codable, Equatable, Sendable {
    public static let capacity = 50

    public private(set) var items: [RecentItem] = []

    public init() {}

    public var unreadCount: Int {
        items.filter { !$0.isRead }.count
    }

    public mutating func add(_ prs: [PullRequest], at date: Date) {
        for pr in prs.sorted(by: { $0.createdAt < $1.createdAt }) {
            items.removeAll { $0.id == pr.dedupKey }
            items.insert(RecentItem(pullRequest: pr, detectedAt: date, isRead: false), at: 0)
        }
        if items.count > Self.capacity {
            items.removeLast(items.count - Self.capacity)
        }
    }

    public mutating func markRead(_ key: String) {
        guard let index = items.firstIndex(where: { $0.id == key }) else { return }
        items[index].isRead = true
    }

    public mutating func markAllRead() {
        for index in items.indices {
            items[index].isRead = true
        }
    }

    public mutating func removeAccount(_ id: UUID) {
        items.removeAll { $0.pullRequest.accountId == id }
    }
}
```

- [ ] **Step 4: Run tests, verwacht slagen**

Run: `swift test --filter AppStateTests`
Expected: 8 tests PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/PullwatchCore/AppConfig.swift Sources/PullwatchCore/RecentList.swift Tests/PullwatchCoreTests/AppStateTests.swift
git commit -m "feat: add app config and recent PR list

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 12: App-shell — XcodeGen, AppModel, notificaties en menubar

**Files:**
- Create: `project.yml`, `App/PullwatchApp.swift`, `App/AppModel.swift`, `App/Notifier.swift`, `App/MenuView.swift`
- Modify: `Makefile` (targets `gen`, `build`, `install`, `run`, `clean` toevoegen)

**Interfaces:**
- Consumes: `PollEngine`, `PollResult`, `AccountState` (Task 10); `AppConfig`, `RecentList`, `RecentItem` (Task 11); `NotificationPlanner`, `PlannedNotification`, `ProviderFactory` (Task 9); `JSONFileStore`, `AppPaths` (Task 1); `KeychainStore` (Task 6)
- Produces (gebruikt in Task 13):
  - `@MainActor @Observable final class AppModel` met `static let shared`, `config: AppConfig`, `recent: RecentList`, `statuses: [UUID: AccountState]`, `notificationsAllowed: Bool`, `menuBarSymbol: String`, `start()`, `refreshNow() async`, `open(_ item: RecentItem)`, `markAllRead()`, `saveAccount(_:pat:)`, `removeAccount(_:)`, `hasStoredPAT(_:) -> Bool`, `setPollInterval(_:)`
  - `@MainActor final class Notifier` met `shared`, `onOpen: ((String) -> Void)?`, `requestAuthorization() async -> Bool`, `deliver(_:)`, `deliverAuthFailure(accountName:)`

Geen unit-tests (UI-laag, dun). Verificatie = build + handmatige run.

- [ ] **Step 1: Installeer XcodeGen**

Run: `brew install xcodegen && xcodegen --version`
Expected: versie wordt getoond.

- [ ] **Step 2: Maak `project.yml`**

```yaml
name: Pullwatch
options:
  bundleIdPrefix: nl.torrisi
  deploymentTarget:
    macOS: "14.0"
packages:
  PullwatchCore:
    path: .
targets:
  Pullwatch:
    type: application
    platform: macOS
    sources:
      - App
    dependencies:
      - package: PullwatchCore
    info:
      path: App/Info.plist
      properties:
        LSUIElement: true
        CFBundleDisplayName: Pullwatch
        CFBundleShortVersionString: "0.1.0"
        CFBundleVersion: "1"
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: nl.torrisi.pullwatch
        PRODUCT_NAME: Pullwatch
        SWIFT_VERSION: "6.0"
        CODE_SIGN_IDENTITY: "-"
        CODE_SIGN_STYLE: Manual
        ENABLE_HARDENED_RUNTIME: NO
        GENERATE_INFOPLIST_FILE: NO
    scheme: {}
```

XcodeGen genereert `App/Info.plist`; voeg hem toe aan `.gitignore` zodat hij niet gecommit wordt:

```
App/Info.plist
```

- [ ] **Step 3: Breid de Makefile uit**

Vervang `Makefile` volledig (recipe-regels met TAB):

```make
.PHONY: test gen build install run clean

DERIVED := build
APP := $(DERIVED)/Build/Products/Release/Pullwatch.app

test:
	swift test

gen:
	xcodegen generate

build: gen
	xcodebuild -project Pullwatch.xcodeproj -scheme Pullwatch -configuration Release -derivedDataPath $(DERIVED) build

install: build
	mkdir -p ~/Applications
	rm -rf ~/Applications/Pullwatch.app
	cp -R $(APP) ~/Applications/

run: install
	open ~/Applications/Pullwatch.app

clean:
	rm -rf $(DERIVED) .build Pullwatch.xcodeproj App/Info.plist
```

- [ ] **Step 4: Schrijf `App/Notifier.swift`**

```swift
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

    func deliver(_ plans: [PlannedNotification]) {
        for plan in plans {
            let content = UNMutableNotificationContent()
            let identifier: String
            switch plan {
            case .single(let pr):
                content.title = "\(pr.repo): nieuwe PR"
                content.body = "\(pr.title) — \(pr.authorName)"
                content.userInfo = ["url": pr.webURL.absoluteString, "key": pr.dedupKey]
                identifier = pr.dedupKey
            case .summary(let count, let lines):
                content.title = "\(count) nieuwe PR's"
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
```

- [ ] **Step 5: Schrijf `App/AppModel.swift`**

```swift
import AppKit
import Observation
import os
import PullwatchCore

private let logger = Logger(subsystem: "nl.torrisi.pullwatch", category: "app")

@MainActor
@Observable
final class AppModel {
    static let shared = AppModel()

    private(set) var config: AppConfig
    private(set) var recent: RecentList
    private(set) var statuses: [UUID: AccountState] = [:]
    private(set) var notificationsAllowed = true

    @ObservationIgnored private let configStore = JSONFileStore<AppConfig>(url: AppPaths.file("config.json"))
    @ObservationIgnored private let recentStore = JSONFileStore<RecentList>(url: AppPaths.file("recent.json"))
    @ObservationIgnored private let secrets = KeychainStore()
    @ObservationIgnored private let engine = PollEngine(
        makeProvider: { ProviderFactory.make($0) },
        store: JSONFileStore<SeenState>(url: AppPaths.file("seen.json"))
    )
    @ObservationIgnored private let notifier = Notifier.shared
    @ObservationIgnored private var loopTask: Task<Void, Never>?

    private init() {
        do {
            config = try configStore.load() ?? AppConfig()
        } catch {
            logger.error("config onleesbaar: \(error.localizedDescription)")
            config = AppConfig()
        }
        recent = (try? recentStore.load()) ?? RecentList()
    }

    var menuBarSymbol: String {
        let hasError = statuses.values.contains { if case .failed = $0 { true } else { false } }
        return hasError ? "exclamationmark.triangle" : "arrow.triangle.pull"
    }

    func start() {
        guard loopTask == nil else { return }
        notifier.onOpen = { [weak self] key in self?.markRead(key) }

        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in await self?.refreshNow() }
        }

        loopTask = Task { [weak self] in
            guard let self else { return }
            self.notificationsAllowed = await self.notifier.requestAuthorization()
            while !Task.isCancelled {
                await self.tick()
                try? await Task.sleep(for: .seconds(15))
            }
        }
    }

    func refreshNow() async {
        await engine.forceRefresh()
        await tick()
    }

    func open(_ item: RecentItem) {
        NSWorkspace.shared.open(item.pullRequest.webURL)
        markRead(item.id)
    }

    func markRead(_ key: String) {
        recent.markRead(key)
        saveRecent()
    }

    func markAllRead() {
        recent.markAllRead()
        saveRecent()
    }

    func saveAccount(_ account: Account, pat: String?) {
        if let pat, !pat.isEmpty {
            do {
                try secrets.write(pat, account: account.id.uuidString)
            } catch {
                logger.error("PAT opslaan mislukt: \(error.localizedDescription)")
            }
        }
        if let index = config.accounts.firstIndex(where: { $0.id == account.id }) {
            config.accounts[index] = account
        } else {
            config.accounts.append(account)
        }
        saveConfig()
        Task { await refreshNow() }
    }

    func removeAccount(_ id: UUID) {
        try? secrets.delete(account: id.uuidString)
        config.accounts.removeAll { $0.id == id }
        recent.removeAccount(id)
        statuses[id] = nil
        saveConfig()
        saveRecent()
    }

    func hasStoredPAT(_ id: UUID) -> Bool {
        (try? secrets.read(account: id.uuidString)) != nil
    }

    func setPollInterval(_ seconds: Int) {
        config.pollInterval = seconds
        saveConfig()
    }

    private func tick() async {
        let result = await engine.poll(
            accounts: config.pollableAccounts,
            interval: TimeInterval(config.clampedInterval)
        )
        statuses = result.statuses

        if !result.newPullRequests.isEmpty {
            recent.add(result.newPullRequests, at: Date())
            saveRecent()
            notifier.deliver(NotificationPlanner.plan(result.newPullRequests))
        }
        for id in result.authFailures {
            if let account = config.accounts.first(where: { $0.id == id }) {
                notifier.deliverAuthFailure(accountName: account.displayName)
            }
        }
    }

    private func saveConfig() {
        do {
            try configStore.save(config)
        } catch {
            logger.error("config opslaan mislukt: \(error.localizedDescription)")
        }
    }

    private func saveRecent() {
        do {
            try recentStore.save(recent)
        } catch {
            logger.error("recent opslaan mislukt: \(error.localizedDescription)")
        }
    }
}
```

- [ ] **Step 6: Schrijf `App/MenuView.swift`**

```swift
import AppKit
import PullwatchCore
import SwiftUI

struct MenuView: View {
    let model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Pullwatch").font(.headline)
                Spacer()
                Button {
                    Task { await model.refreshNow() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("Nu verversen")
            }

            if !model.notificationsAllowed {
                Label("Meldingen staan uit in Systeeminstellingen", systemImage: "bell.slash")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            Divider()

            if model.recent.items.isEmpty {
                Text("Nog geen nieuwe PR's").foregroundStyle(.secondary)
            } else {
                ForEach(model.recent.items.prefix(10)) { item in
                    RecentRow(item: item) { model.open(item) }
                }
            }

            if !model.config.accounts.isEmpty {
                Divider()
                ForEach(model.config.accounts) { account in
                    AccountStatusRow(account: account, state: model.statuses[account.id] ?? .idle)
                }
            }

            Divider()

            HStack {
                Button("Alles gelezen") { model.markAllRead() }
                    .disabled(model.recent.unreadCount == 0)
                Spacer()
                SettingsButton()
                Button("Stop") { NSApp.terminate(nil) }
            }
        }
        .padding(12)
        .frame(width: 360)
    }
}

/// In Task 12 nog leeg; Task 13 vult deze met het openen van het settings-venster.
struct SettingsButton: View {
    var body: some View { EmptyView() }
}

private struct RecentRow: View {
    let item: RecentItem
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 6) {
                Circle()
                    .fill(item.isRead ? Color.clear : Color.accentColor)
                    .frame(width: 6, height: 6)
                    .padding(.top, 6)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.pullRequest.title).lineLimit(1)
                    HStack(spacing: 4) {
                        Text("\(item.pullRequest.repo) · \(item.pullRequest.authorName) ·")
                        Text(item.pullRequest.createdAt, format: .relative(presentation: .named))
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct AccountStatusRow: View {
    let account: Account
    let state: AccountState

    var body: some View {
        HStack(spacing: 4) {
            Text(account.displayName).font(.caption.bold())
            switch state {
            case .idle:
                Text("wacht op eerste poll").font(.caption).foregroundStyle(.secondary)
            case .ok(let lastPoll):
                Text("✓").font(.caption).foregroundStyle(.green)
                Text(lastPoll, format: .relative(presentation: .named)).font(.caption).foregroundStyle(.secondary)
            case .failed(let error, _):
                Text(error.userMessage).font(.caption).foregroundStyle(.red).lineLimit(2)
            }
        }
    }
}
```

- [ ] **Step 7: Schrijf `App/PullwatchApp.swift`**

```swift
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
                if model.recent.unreadCount > 0 {
                    Text("•")
                }
            }
        }
        .menuBarExtraStyle(.window)
    }
}
```

- [ ] **Step 8: Build**

Run: `make build`
Expected: `** BUILD SUCCEEDED **`. Los eventuele Swift 6 concurrency-fouten op in de app-bestanden (niet in Core-API's die al getest zijn) en draai opnieuw.

- [ ] **Step 9: Handmatige smoke-test met handgeschreven config**

Maak een config met één GitHub-account via CLI-auth (vereist `gh auth login`):

```bash
mkdir -p ~/Library/Application\ Support/Pullwatch
cat > ~/Library/Application\ Support/Pullwatch/config.json <<'EOF'
{
  "accounts": [{
    "id": "11111111-1111-1111-1111-111111111111",
    "kind": "gitHub",
    "displayName": "GitHub eigen",
    "organization": "<jouw-github-login>",
    "authMethod": "cli",
    "filterMode": "deny",
    "repos": [],
    "includeDrafts": false,
    "hideOwn": false
  }],
  "pollInterval": 60
}
EOF
make run
```

Expected: icoon in menubar; macOS vraagt meldingstoestemming; menu toont account met ✓ na ~15 s. Open een PR op een eigen test-repo (`hideOwn` staat uit) → binnen ~1 min melding; klik → PR opent in browser; menu toont PR met stip.

- [ ] **Step 10: Commit**

```bash
git add project.yml Makefile .gitignore App
git commit -m "feat: add menubar app shell with polling and notifications

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 13: Instellingen-venster en starten bij inloggen

**Files:**
- Create: `App/SettingsView.swift`, `App/AccountEditor.swift`
- Modify: `App/PullwatchApp.swift` (Window-scene toevoegen), `App/MenuView.swift` (`SettingsButton` invullen)

**Interfaces:**
- Consumes: `AppModel` (Task 12): `config`, `saveAccount(_:pat:)`, `removeAccount(_:)`, `hasStoredPAT(_:)`, `setPollInterval(_:)`; `ProviderFactory.make(_:pat:)` (Task 9); `ProviderError.userMessage` (Task 4); `AppConfig.intervalRange` (Task 11)
- Produces: Window-scene met id `"settings"`.

- [ ] **Step 1: Schrijf `App/AccountEditor.swift`**

```swift
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
```

- [ ] **Step 2: Schrijf `App/SettingsView.swift`**

```swift
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

    var body: some View {
        Form {
            Picker("Poll-interval", selection: Binding(
                get: { model.config.clampedInterval },
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
```

- [ ] **Step 3: Voeg Window-scene toe in `App/PullwatchApp.swift`**

Vervang de `body` van `PullwatchApp` door:

```swift
    var body: some Scene {
        MenuBarExtra {
            MenuView(model: model)
        } label: {
            HStack(spacing: 2) {
                Image(systemName: model.menuBarSymbol)
                if model.recent.unreadCount > 0 {
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
```

- [ ] **Step 4: Vul `SettingsButton` in `App/MenuView.swift`**

Vervang:

```swift
/// In Task 12 nog leeg; Task 13 vult deze met het openen van het settings-venster.
struct SettingsButton: View {
    var body: some View { EmptyView() }
}
```

door:

```swift
struct SettingsButton: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Instellingen…") {
            openWindow(id: "settings")
            NSApp.activate()
        }
    }
}
```

- [ ] **Step 5: Build en handmatige test**

Run: `make run`
Expected:
1. Menu → "Instellingen…" opent venster vóór andere apps.
2. "+" → Azure DevOps; vul organisatie in, kies "Azure CLI"; "Test verbinding" toont ✓ (vereist `az login`).
3. "Repos laden" vult de lijst; zoekveld filtert; vinkjes zetten; "Opslaan".
4. GitHub-account met PAT: plak token, "Test verbinding" ✓ vóór opslaan; na opslaan toont het veld "Opgeslagen — leeg laten om te behouden".
5. Tab Algemeen: interval wijzigen blijft bewaard na herstart; "Starten bij inloggen" aan → zichtbaar in Systeeminstellingen → Algemeen → Inloggen.
6. Ongeldige PAT opslaan → binnen een poll één melding "Token ongeldig of verlopen", menu toont fout, ⚠-icoon.

- [ ] **Step 6: Commit**

```bash
git add App
git commit -m "feat: add settings window for accounts, repo filter and login item

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 14: End-to-end verificatie en README

**Files:**
- Create: `README.md`

- [ ] **Step 1: Schrijf `README.md`**

````markdown
# Pullwatch

macOS menubar-app die nieuwe pull requests in Azure DevOps en GitHub meldt.

## Vereisten

- macOS 14+
- Xcode (Swift 6)
- `brew install xcodegen`
- Optioneel: `az` (`az login`) en/of `gh` (`gh auth login`) voor CLI-authenticatie

## Bouwen en installeren

```bash
make test      # unit-tests van PullwatchCore
make install   # bouwt en kopieert naar ~/Applications/Pullwatch.app
make run       # install + starten
```

## Gebruik

1. Klik op het icoon in de menubar → **Instellingen…**
2. Voeg een account toe (Azure DevOps of GitHub), kies PAT of CLI, test de verbinding.
3. Kies per account welke repos je volgt (alles behalve / alleen geselecteerde).

Bestaande PR's worden bij het toevoegen stil overgeslagen; alleen nieuwe PR's geven een melding.

### PAT-scopes

- Azure DevOps: **Code (Read)**
- GitHub (fine-grained): **Pull requests: Read** en **Metadata: Read** op de gewenste repos; classic: `repo`

## Data

`~/Library/Application Support/Pullwatch/` — `config.json`, `seen.json`, `recent.json`. Tokens staan in de Keychain (`nl.torrisi.pullwatch`).

Logs: `log stream --predicate 'subsystem == "nl.torrisi.pullwatch"'`
````

- [ ] **Step 2: Volledige verificatie**

Run: `swift test`
Expected: alle tests PASS.

Doorloop handmatig (met `make run`):
1. Nieuwe PR in een gevolgde Azure DevOps-repo → melding binnen één interval; klik opent PR.
2. Nieuwe PR in een gevolgde GitHub-repo → idem.
3. App stoppen en starten → geen nieuwe melding voor dezelfde PR's.
4. Eigen PR (hideOwn aan) → geen melding.
5. Draft-PR → geen melding; draft op "ready for review" zetten → melding.
6. Repo aan allowlist toevoegen met bestaande PR's → geen meldingen voor die bestaande PR's.
7. Wifi uit → menu toont netwerkfout, geen meldingen; wifi aan → herstelt.

- [ ] **Step 3: Commit**

```bash
git add README.md
git commit -m "docs: add README with build and usage instructions

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```
