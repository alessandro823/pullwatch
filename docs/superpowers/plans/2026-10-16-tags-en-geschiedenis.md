# Tags en geschiedenis — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Pullwatch meldt naast nieuwe PR's ook nieuwe git-tags (per repo aan te zetten) en houdt een doorzoekbare lokale geschiedenis bij met een eigen venster.

**Architecture:** `Account` krijgt per-repo `WatchSet` (prs/tags) i.p.v. allow/deny-lijst, met migratie bij decoderen. `PRProvider` krijgt `tags(in:)`; `PollEngine` haalt tags op met een eigen 15-min-schema binnen dezelfde fetch en seedt de eerste tag-poll per repo stil. `History` vervangt `RecentList`, bevat PR's én tags, wordt opgeschoond op bewaartermijn en is doorzoekbaar; de app krijgt menu-secties en een Geschiedenis-venster.

**Tech Stack:** Swift 6, SwiftUI (`MenuBarExtra`, `Window`, `Table`), Swift Testing, geen externe dependencies.

**Spec:** `docs/superpowers/specs/2026-10-16-tags-en-geschiedenis-design.md`

## Global Constraints

- Geen externe dependencies; opslag blijft JSON via `JSONFileStore` in `~/Library/Application Support/Pullwatch/`.
- Alle core-logica in `PullwatchCore` (geen AppKit/SwiftUI), unit-getest met Swift Testing (`@Suite`/`@Test`/`#expect`). `make test` = `swift test`.
- UI-teksten en code-comments in het Nederlands, zoals bestaande code.
- PR: blauw, SF Symbol `arrow.triangle.pull`, pill "PR". Tag: oranje, SF Symbol `tag`, pill "TAG". Overal consequent.
- Tag-poll-interval vast **900 s**, los van PR-interval; "Nu verversen" pollt ook tags.
- Tags alleen aan via vinkje per repo; `newRepoDefault` kent alleen `.none` / `.prs`.
- Na migratie staan tags nergens aan; PR-gedrag blijft identiek.
- Eerste tag-poll per repo is altijd stil.
- Bewaartermijn: 2 maanden / 6 maanden / 1 jaar / altijd; standaard 1 jaar.
- Menu: 5 items per sectie; sectie Tags alleen als er ooit een tag in de geschiedenis staat.
- Burst-samenvatting per soort bij >3 (`NotificationPlanner.burstThreshold = 3`).
- `hideOwn` en `includeDrafts` gelden alleen voor PR's.

## Review Focus

1. **Repo met tag-vinkje bestaat niet meer / geen toegang (404)** → die repo levert lege taglijst; account blijft groen en PR's blijven komen. (Task 3, 4)
2. **Tagnamen met `/`, `+`, `#` of spaties** (`release/1.0`, `v1.0+build`) → klikbare, correct ge-encodede URL. (Task 3, 4)
3. **Oude `config.json`, `seen.json`, `recent.json` van v1** → laden zonder verlies of crash; PR-volggedrag exact gelijk. (Task 1, 5, 7)
4. **Tag-vinkje uit en weer aan** na tussentijdse tags → opnieuw stil seeden, geen stortvloed. (Task 5)
5. **Hoofdletterverschil** tussen repo-naam in config en van de provider (`Proj/Api` vs `proj/api`) → wordt als dezelfde repo herkend, voor PR's én tags. (Task 1, 5)

---

## File Structure

| Bestand | Rol |
|---|---|
| `Sources/PullwatchCore/Models.swift` | + `WatchSet`, `NewRepoDefault`, `Tag`; `Account` met `repoWatch`/`newRepoDefault` + legacy-decoding |
| `Sources/PullwatchCore/PRFilter.swift` | `FilterSettings` op nieuw model; `follows` → `watch(for:)` |
| `Sources/PullwatchCore/PRProvider.swift` | + `tags(in:)` |
| `Sources/PullwatchCore/AzureDevOpsProvider.swift`, `GitHubProvider.swift` | tags ophalen |
| `Sources/PullwatchCore/SeenState.swift` | + `tagSeeded`, backward-compatible decoding |
| `Sources/PullwatchCore/PollEngine.swift` | tag-schema, tag-detectie, `PollResult.newTags` |
| `Sources/PullwatchCore/NotificationPlanner.swift` | per soort |
| `Sources/PullwatchCore/History.swift` (nieuw) | `History`, `HistoryItem`, `HistoryRetention`, zoeken |
| `Sources/PullwatchCore/RecentList.swift` | blijft alleen voor migratie (geen nieuwe features) |
| `Sources/PullwatchCore/AppConfig.swift` | + `historyRetention` |
| `App/AppModel.swift`, `Notifier.swift`, `MenuView.swift`, `PullwatchApp.swift`, `SettingsView.swift`, `AccountEditor.swift` | wiring + UI |
| `App/HistoryView.swift` (nieuw) | Geschiedenis-venster |
| `App/KindStyle.swift` (nieuw) | kleur/icoon/pill per soort, gedeeld door menu en venster |

---

### Task 1: Repo-watch-model met migratie

**Files:**
- Modify: `Sources/PullwatchCore/Models.swift`, `Sources/PullwatchCore/PRFilter.swift`
- Modify: `Tests/PullwatchCoreTests/Support/Fixtures.swift`, `ModelsTests.swift`, `PRFilterTests.swift`, `PollEngineTests.swift`, `AppStateTests.swift` (callers van `filterMode`/`repos`)

**Interfaces:**
- Produces:
  - `public struct WatchSet: Codable, Hashable, Sendable { public var prs: Bool; public var tags: Bool }` + `static let none, prs, tags, both`
  - `public enum NewRepoDefault: String, Codable, CaseIterable, Sendable { case none, prs }` + `var watchSet: WatchSet`
  - `Account.repoWatch: [String: WatchSet]`, `Account.newRepoDefault: NewRepoDefault` (default `.prs`); `filterMode`/`repos` verdwijnen uit `Account` (enum `FilterMode` blijft, alleen voor migratie).
  - `Account.watch(for repo: String) -> WatchSet` — case-insensitive lookup in `repoWatch`, anders `newRepoDefault.watchSet`.
  - `Account.tagRepos: [String]` — keys van `repoWatch` met `tags == true`, gesorteerd.
  - `FilterSettings` velden `repoWatch`, `newRepoDefault` (i.p.v. `filterMode`, `repos`) + dezelfde `watch(for:)`; `PRFilter.follows(repo:settings:)` = `settings.watch(for: repo).prs`.
  - Fixture: `Account.fixture(..., repoWatch: [String: WatchSet] = [:], newRepoDefault: NewRepoDefault = .prs, ...)`.

- [ ] **Step 1: Tests schrijven** (`ModelsTests`)

```swift
@Test func legacyDenyConfigMigrates() throws {
    let json = #"{"id":"00000000-0000-0000-0000-000000000009","kind":"gitHub","displayName":"X","organization":"o","authMethod":"pat","filterMode":"deny","repos":["o/legacy"],"includeDrafts":false,"hideOwn":true}"#
    let a = try JSONDecoder().decode(Account.self, from: Data(json.utf8))
    #expect(a.newRepoDefault == .prs)
    #expect(a.repoWatch == ["o/legacy": .none])
    #expect(a.watch(for: "o/other") == .prs)
    #expect(a.tagRepos.isEmpty)
}
@Test func legacyAllowConfigMigrates() throws { /* filterMode "allow", repos ["o/api"] → newRepoDefault .none, repoWatch ["o/api": .prs] */ }
@Test func newFormatRoundTrips() throws { /* encode Account met repoWatch ["o/a": .both] → decode gelijk; encoded JSON bevat geen "filterMode" */ }
@Test func watchLookupIsCaseInsensitive() {
    let a = Account.fixture(repoWatch: ["Proj/Api": .both], newRepoDefault: .none)
    #expect(a.watch(for: "proj/api") == .both)
    #expect(a.watch(for: "proj/x") == .none)
}
```

`accountDefaults` aanpassen: `repoWatch.isEmpty`, `newRepoDefault == .prs`. Bestaande `PRFilterTests`/`PollEngineTests` omzetten: `filterMode: .deny, repos: [x]` → `repoWatch: [x: .none]`; `filterMode: .allow, repos: [x]` → `repoWatch: [x: .prs], newRepoDefault: .none`. `addingRepoToAllowlist…`: `account.repoWatch["proj/b"] = .prs`.

Plus `legacyLastSettingsDecode`: oude `seen.json` bevat `lastSettings` met `filterMode`/`repos` → `FilterSettings` decodeert via dezelfde migratie (anders valt heel `seen.json` weg).

- [ ] **Step 2:** `swift test` → compileert niet / faalt.
- [ ] **Step 3: Implementeren.** Migratie als gedeelde helper voor `Account` en `FilterSettings`. `Account.init(from:)`: als `filterMode` aanwezig → migreren volgens tabel in spec; anders nieuwe velden. `encode(to:)` schrijft alleen nieuwe velden (synthetiseerbaar via `CodingKeys` zonder legacy keys + aparte `LegacyKeys`).
- [ ] **Step 4:** `swift test` → alles groen (incl. ongewijzigde PR-semantiek in `PollEngineTests`).
- [ ] **Step 5: Commit** `feat: per-repo watch settings with legacy migration`

---

### Task 2: Tag-model en provider-protocol

**Files:**
- Modify: `Sources/PullwatchCore/Models.swift`, `PRProvider.swift`, `Tests/.../Support/MockProvider.swift`, `Fixtures.swift`, `ModelsTests.swift`

**Interfaces:**
- Produces:
  - `public struct Tag: Codable, Hashable, Sendable { accountId: UUID; repo: String; name: String; authorName: String?; webURL: URL; var dedupKey: String { "\(accountId.uuidString):\(repo.lowercased()):tag:\(name)" } }`
  - `PRProvider.tags(in repos: [String]) async throws -> [Tag]` — `Tag.repo` is exact de doorgegeven repo-string. Repo die 404 geeft → overslaan.
  - `MockProvider.set(tags: [Tag])`; `MockProvider.tagFetchCount`; `tags(in:)` geeft alleen tags waarvan `repo` (case-insensitive) in `repos` zit. `GatedProvider.tags` → `[]`.
  - `Tag.fixture(accountId:repo:name:)` met URL `https://example.com/{repo}/tag/{name}`.

- [ ] **Step 1:** Test `tagDedupKeyIsDistinctFromPR`: `Tag.fixture(repo: "Proj/API", name: "v1").dedupKey == "00000000-0000-0000-0000-000000000001:proj/api:tag:v1"`.
- [ ] **Step 2:** `swift test` → faalt.
- [ ] **Step 3:** Implementeren (alleen model/protocol/mocks; providers krijgen tijdelijk `throw ProviderError.decoding("tags nog niet")` — vervangen in Task 3/4).
- [ ] **Step 4:** `swift test` → groen.
- [ ] **Step 5: Commit** `feat: tag model and provider protocol`

---

### Task 3: Azure DevOps-tags

**Files:** Modify `Sources/PullwatchCore/AzureDevOpsProvider.swift`; Test `Tests/PullwatchCoreTests/AzureDevOpsProviderTests.swift`

**Interfaces:** Consumes `Tag`, `PRProvider.tags(in:)` (Task 2).

Endpoint per repo `"{project}/{repo}"` (split op eerste `/`): `GET {base}/{project}/_apis/git/repositories/{repo}/refs?filter=tags/&api-version=7.1` (zonder `$top` geeft ADO alle refs). DTO: `{ value: [{ name: "refs/tags/v1", creator: { displayName }? }] }`. Naam = `name` zonder `refs/tags/`. URL: `URLComponents` op `{base}/{project}/_git/{repo}` met query `version=GT{naam}`. 404 → `[]` voor die repo.

- [ ] **Step 1: Tests**
  - `parsesTagsFromRefs`: mock `"_apis/git/repositories/api/refs"` met 2 refs (één met creator) → 2 tags, namen `v1.0`, `release/2.0`, `authorName` `"Jan"` resp. `nil`, `repo == "proj/api"`.
  - `tagURLEncodesName`: tag `release/2.0+b` → `webURL.absoluteString == "https://dev.azure.com/acme/proj/_git/api?version=GTrelease/2.0%2Bb"`.
  - `missingRepoYieldsNoTags`: route `/refs` status 404 → `tags(in: ["proj/gone"]) == []`, geen throw.
  - `requestsTagFilter`: request-URL bevat `filter=tags/` en `api-version=7.1`.
- [ ] **Step 2:** `swift test --filter AzureDevOpsProviderTests` → faalt.
- [ ] **Step 3:** `tags(in:)` implementeren.
- [ ] **Step 4:** groen.
- [ ] **Step 5: Commit** `feat: fetch tags from Azure DevOps`

---

### Task 4: GitHub-tags

**Files:** Modify `Sources/PullwatchCore/GitHubProvider.swift`; Test `GitHubProviderTests.swift`

**Interfaces:** idem Task 3.

REST `GET /repos/{owner}/{repo}/tags?per_page=100&page=n` voor alle pagina's (tot `maxPages`, stop bij `< pageSize`). `repo` is `"owner/name"`. DTO `[{ name }]`; `authorName = nil`. URL `https://github.com/{owner}/{name}/releases/tag/{naam}` met naam percent-encoded als padsegment (`/` → `%2F`, `+` → `%2B`). 404 → `[]`.

- [ ] **Step 1: Tests**
  - `parsesTagsAcrossPages`: pagina 1 met 100 tags, pagina 2 met 1 → 101 tags, `repo == "acme/api"`.
  - `tagURLEncodesName`: `release/1.0` → `"https://github.com/acme/api/releases/tag/release%2F1.0"`.
  - `missingRepoYieldsNoTags`: 404 → `[]`.
- [ ] **Step 2:** `swift test --filter GitHubProviderTests` → faalt.
- [ ] **Step 3:** Implementeren. `HTTPStatus.check` gooit `.server(status: 404)` — vangen per repo.
- [ ] **Step 4:** groen.
- [ ] **Step 5: Commit** `feat: fetch tags from GitHub`

---

### Task 5: Tag-detectie in PollEngine

**Files:** Modify `Sources/PullwatchCore/PollEngine.swift`, `SeenState.swift`; Test `PollEngineTests.swift`, `SeenStateTests.swift`

**Interfaces:**
- Consumes: `Account.tagRepos`, `PRProvider.tags(in:)`, `Tag.dedupKey`.
- Produces:
  - `PollResult.newTags: [Tag]` (gesorteerd op repo, dan naam).
  - `PollEngine.tagInterval: TimeInterval = 900` (static).
  - `SeenState.tagSeeded: Set<String>` met keys `"{accountId}:{repo.lowercased()}"`; `init(from:)` met `decodeIfPresent` → leeg (oude `seen.json` blijft laadbaar).

Gedrag:
- `Schedule` krijgt `nextTagDue: Date = .distantPast`; `forceRefresh` zet die ook op `t`. Een fetch haalt tags alleen als `nextTagDue <= t` en `tagRepos` niet leeg; anders `nil`. Bij succes met tags: `nextTagDue = t + tagInterval`.
- Fout bij tags = fout van het account (bestaande backoff).
- Verwerking per tag-repo: als `"{id}:{repo}"` niet in `tagSeeded` → alle tags stil markeren + key toevoegen; anders tags die niet in `seen` staan → `newTags`. Alles `mark(at: t)`.
- Repo's die niet meer in `tagRepos` staan: hun key uit `tagSeeded` halen (bij elke succesvolle tag-poll), zodat weer aanzetten opnieuw stil seedt.
- `forget(except:)` filtert `tagSeeded` op account-prefix.

- [ ] **Step 1: Tests** (`Harness` hergebruiken)
  - `firstTagPollIsSilentThenNewTagNotifies`: `repoWatch ["proj/a": .both]`, tags `[v1]` → leeg; na `advance(900)` tags `[v1, v2]` → `newTags == [v2]`.
  - `tagsNotRefetchedBeforeTagInterval`: na eerste poll, `advance(120)` → `tagFetchCount == 1`; `forceRefresh` → 2.
  - `reenablingTagsReseedsSilently`: tags aan, poll; uit (`.prs`), poll, nieuwe tag `v2` erbij; weer `.both`, `advance(900)` → `newTags` leeg; daarna `v3` → `[v3]`.
  - `noTagReposMeansNoTagFetch`: `newRepoDefault .prs`, geen `repoWatch` → `tagFetchCount == 0`.
  - `tagRepoCaseMismatchStillMatches`: config `"Proj/A"`, mock geeft tags met repo `"Proj/A"` → tweede poll meldt nieuwe tag; `tagSeeded` key lowercase.
  - `SeenStateTests.legacySeenJsonLoads`: `{"seen":{},"lastSettings":{}}` decodeert met lege `tagSeeded`.
- [ ] **Step 2:** `swift test --filter PollEngineTests` → faalt.
- [ ] **Step 3:** Implementeren. `Fetched` krijgt `tags: [Tag]?` en `tagRepos: [String]`.
- [ ] **Step 4:** `swift test` → alles groen.
- [ ] **Step 5: Commit** `feat: detect new tags with silent first poll per repo`

---

### Task 6: Meldingen per soort

**Files:** Modify `Sources/PullwatchCore/NotificationPlanner.swift`, `App/Notifier.swift`; Test nieuw `Tests/PullwatchCoreTests/NotificationPlannerTests.swift` (of bestaande `GlueTests` als planner daar getest wordt — eerst checken met `grep -rn NotificationPlanner Tests`).

**Interfaces:**
- Produces:
  - `public enum ItemKind: String, Codable, Sendable { case pullRequest, tag }` (in `Models.swift`)
  - `PlannedNotification`: `.pullRequest(PullRequest)`, `.tag(Tag)`, `.summary(kind: ItemKind, count: Int, lines: [String])`
  - `NotificationPlanner.plan(pullRequests: [PullRequest], tags: [Tag]) -> [PlannedNotification]` — PR's eerst, dan tags; elk deel apart tegen `burstThreshold`. Tag-regel: `"{repo}: {naam}"`.
  - Notifier: tag-titel `"{repo}: nieuwe tag"`, body `naam` + `" — {auteur}"` indien bekend, `userInfo` `url`/`key` = `tag.dedupKey`, identifier `dedupKey`. Summary-titel `"{n} nieuwe PR's"` / `"{n} nieuwe tags"`.
- [ ] **Step 1: Tests:** `mixedSmallBatchGivesSingles` (2 PR + 2 tags → 4 items in volgorde), `tagBurstSummarizesSeparately` (1 PR + 4 tags → `[.pullRequest, .summary(kind: .tag, count: 4, lines: 3 regels)]`).
- [ ] **Step 2:** faalt. **Step 3:** implementeren + Notifier aanpassen. **Step 4:** `swift test` groen, `make build` slaagt.
- [ ] **Step 5: Commit** `feat: separate notifications for tags`

---

### Task 7: History-model met bewaartermijn en zoeken

**Files:** Create `Sources/PullwatchCore/History.swift`, `Tests/PullwatchCoreTests/HistoryTests.swift`; Modify `AppConfig.swift`, `AppStateTests.swift`

**Interfaces:**
- Produces:
  - `public enum HistoryEntry: Codable, Hashable, Sendable { case pullRequest(PullRequest), tag(Tag) }` met `kind: ItemKind`, `dedupKey`, `accountId`, `repo`, `title` (PR-titel of tagnaam), `author: String?`, `webURL`.
  - `public struct HistoryItem: Codable, Identifiable, Hashable, Sendable { entry; detectedAt: Date; isRead: Bool; id = entry.dedupKey }`
  - `public enum HistoryRetention: String, Codable, CaseIterable, Sendable { case twoMonths, sixMonths, oneYear, forever }` met `maxAge: TimeInterval?` (61 / 183 / 365 dagen / nil) en `label` ("2 maanden" …).
  - `public struct History: Codable, Equatable, Sendable`:
    - `items` (nieuwste eerst), `unreadCount`
    - `add(pullRequests:tags:at:)` (bestaand id → vervangen en naar boven, zoals `RecentList`)
    - `markRead(_ id:)`, `markAllRead()`, `removeAccount(_:)`
    - `prune(now: Date, retention: HistoryRetention) -> Bool` (true als er iets weg is)
    - `latest(_ kind: ItemKind, limit: Int) -> [HistoryItem]`
    - `search(_ text: String, kind: ItemKind?) -> [HistoryItem]` — trim; leeg = alles; anders case-insensitive substring in titel, auteur of repo.
    - `init(migrating: RecentList)` — behoudt `detectedAt`, `isRead`.
  - `AppConfig.historyRetention: HistoryRetention = .oneYear`; `AppConfig.init(from:)` met `decodeIfPresent` zodat oude `config.json` laadt.
- [ ] **Step 1: Tests:** `addsNewestFirstAcrossKinds`, `latestFiltersByKind`, `pruneRespectsRetention` (item 62 dagen oud weg bij `.twoMonths`, blijft bij `.sixMonths`; `.forever` verwijdert nooit), `searchMatchesTitleAuthorRepoCaseInsensitive`, `searchCombinesKindFilter`, `searchSkipsNilAuthor`, `migratesRecentList`, `legacyConfigWithoutRetentionDefaultsToOneYear`, `historyRoundTripsThroughJSON`.
- [ ] **Step 2:** faalt. **Step 3:** implementeren. **Step 4:** groen.
- [ ] **Step 5: Commit** `feat: searchable history with retention`

---

### Task 8: App-wiring (opslag, polling, openen)

**Files:** Modify `App/AppModel.swift`, `App/PullwatchApp.swift`

**Interfaces:**
- Consumes: `History`, `PollResult.newTags`, `NotificationPlanner.plan(pullRequests:tags:)`, `HistoryRetention`.
- Produces (voor Task 9/10): `AppModel.history: History`, `open(_ item: HistoryItem)`, `markRead(_:)`, `markAllRead()`, `setHistoryRetention(_:)`.

- `historyStore = JSONFileStore<History>(url: AppPaths.file("history.json"))`. Laden: `history.json`; zo niet aanwezig maar `recent.json` wel → `History(migrating:)`, direct opslaan, `recent.json` laten staan. Daarna `prune` en opslaan als er iets veranderde.
- `tick`: als `newPullRequests` of `newTags` niet leeg → `history.add`, `prune`, opslaan, `notifier.deliver(plan(...))`.
- `setHistoryRetention`: config opslaan + direct prunen.
- Menubar-badge op `history.unreadCount`. `RecentList` niet meer gebruikt in de app.
- [ ] **Step 1:** `make build` slaagt. **Step 2:** `swift test` groen.
- [ ] **Step 3: Handmatig:** `make run` met bestaande data → oude recente PR's staan in menu, `history.json` is aangemaakt.
- [ ] **Step 4: Commit** `feat: persist history and deliver tag notifications`

---

### Task 9: Menu-secties en Geschiedenis-venster

**Files:** Create `App/KindStyle.swift`, `App/HistoryView.swift`; Modify `App/MenuView.swift`, `App/PullwatchApp.swift`, `App/SettingsView.swift`, `README.md`

- `KindStyle` (`ItemKind` extension): `color` (`.blue` / `.orange`), `symbol` (`arrow.triangle.pull` / `tag`), `pillText` ("PR"/"TAG"), en een `KindPill` view.
- Menu: sectiekop "Pull requests" + `history.latest(.pullRequest, limit: 5)`, lege staat "Nog geen nieuwe PR's"; sectie "Tags" + `latest(.tag, limit: 5)` alleen als er tags in de geschiedenis staan. Rij toont soort-icoon in de kleur. Knop "Geschiedenis…" naast "Instellingen…" (`openWindow(id: "history")`, `NSApp.activate()`).
- `Window("Geschiedenis", id: "history")` met `HistoryView`: `.searchable` of `TextField` "Zoek op titel, auteur, repo…", `Picker` `.segmented` Alles/PR's/Tags, `Table` kolommen type (`KindPill`), titel, repo, auteur (`"—"` als nil), wanneer (relatief, `.help` met absolute datum). Ongelezen titel vet. Dubbelklik (`contextMenu(forSelectionType:primaryAction:)`) → `model.open`. Min-grootte ~720×420.
- SettingsView: Picker "Geschiedenis bewaren" over `HistoryRetention.allCases`.
- README: tags, geschiedenis, `history.json` bij Data; GitHub-scope voor tags verifiëren (fine-grained: tags vallen onder **Contents: Read** of **Metadata: Read** — controleer met een fine-grained PAT en documenteer wat nodig is); ADO Code (Read) volstaat.
- [ ] **Step 1:** `make build` slaagt.
- [ ] **Step 2: Handmatig:** menu toont secties; venster opent; zoeken op auteur filtert; filter Tags toont alleen oranje; dubbelklik opent browser en haalt vet weg; bewaartermijn wijzigen werkt.
- [ ] **Step 3: Commit** `feat: menu sections and history window`

---

### Task 10: Repo-tabel in accountinstellingen

**Files:** Modify `App/AccountEditor.swift`

- Modus-picker vervangen door `Picker("Nieuwe repo's volgen", selection: $draft.newRepoDefault)` met "Niets"/"PR's".
- Repolijst (zoeken + "Repos laden" blijven) wordt `Grid`/`Table` met kolommen Repo / PR's / Tags; twee `Toggle`s per rij (`.checkbox`), getint blauw/oranje via `KindStyle`.
- Binding per repo: get = `draft.watch(for: repo)`; set = schrijf `WatchSet` in `repoWatch` onder bestaande key (case-insensitive match) of nieuwe key; verwijder entry als hij gelijk is aan `newRepoDefault.watchSet` **en** `tags == false`.
- `filteredRepos` = `availableRepos ∪ repoWatch.keys`.
- [ ] **Step 1:** `make build` slaagt.
- [ ] **Step 2: Handmatig:** bestaande account openen → vinkjes kloppen met oude allow/deny-keuze; tag-vinkje aan op één repo → na ~15 min of "Nu verversen" geen melding voor bestaande tags; nieuwe tag pushen → melding "repo: nieuwe tag".
- [ ] **Step 3: Commit** `feat: per-repo PR and tag toggles in account editor`

---

## Na alle taken

- [ ] `swift test` volledig groen, `make build` slaagt.
- [ ] Whole-branch review, daarna superpowers:finishing-a-development-branch.
