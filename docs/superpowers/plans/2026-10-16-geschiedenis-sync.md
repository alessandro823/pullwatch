# Geschiedenis-sync, inhalen en PR-status — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** De geschiedenis eenmalig vullen met recente PR's (alle statussen), gemiste PR's inhalen na uitval, en PR-status (open/gemerged/gesloten) bijhouden en tonen.

**Architecture:** `PullRequest` krijgt `state`/`closedAt`. Providers krijgen `pullRequests(updatedSince:limit:)`. `PollEngine` draait elke 900 s per account een sync (eigen schema, fouten nooit fataal), houdt per account een sync-markering bij (tijd + filter + bewaartermijn) en geeft `syncedPullRequests` terug. `History.merge(synced:)` voegt stil en gesorteerd toe en werkt status bij; het venster krijgt een statuskolom.

**Tech Stack:** Swift 6, SwiftUI, Swift Testing, geen dependencies.

**Spec:** `docs/superpowers/specs/2026-10-16-geschiedenis-sync-design.md`

## Global Constraints

- Geen externe dependencies; core-logica in `PullwatchCore`, Swift Testing; `swift test`, `make build`.
- UI-teksten en comments in het Nederlands.
- Sync elke 900 s (`PollEngine.tagInterval`), "Nu verversen" forceert ook de sync.
- Eerste sync: `since = now − retention.maxAge` (bij `.forever`: `nil`); daarna `since = lastSync − 3600 s`. `limit = 1000` per account.
- Sync-fouten laten het account nooit falen; `.rateLimited(until)` stelt alleen de volgende sync uit tot `until` (max 1 uur, zoals bestaande clamp); PR-polling loopt door.
- Sync markeert niets in `seen`; meldingen blijven bij de open-PR-poll.
- Sync-resultaat door `PRFilter.passes` (repo-vinkje PR's, drafts, eigen PR's).
- Filter- of bewaartermijnwijziging → volgende sync is weer een eerste sync voor dat account.
- `merge`: nieuw → `isRead = true`, `detectedAt = createdAt`, gesorteerd ingevoegd op `detectedAt` (nieuwste eerst); bestaand → alleen `state`, `closedAt`, `title` bijwerken.
- Status-kleuren/teksten: open groen "Open", merged paars "Gemerged", closed grijs "Gesloten".
- Oude JSON zonder `state` → `.open`, zonder `closedAt` → `nil`.

## Review Focus

1. **Gemelde PR die de sync daarna ook ziet** → blijft ongelezen en bovenaan. (Task 2)
2. **PC twee weken uit** → eerste sync na terugkomst gebruikt `lastSync − 1 u`, haalt in, geen meldingen voor gesloten PR's. (Task 4)
3. **GitHub search rate limit tijdens eerste sync** → PR-meldingen gaan door, sync wordt uitgesteld. (Task 4)
4. **ADO-PR die vóór `since` is aangemaakt maar erna gesloten** → komt met status Gemerged/Gesloten in de sync. (Task 3)
5. **Bestaande `history.json`/`recent.json` zonder status** → laadt, PR's tonen "Open" tot de sync ze bijwerkt. (Task 1)

---

### Task 1: PR-status in het model

**Files:** Modify `Sources/PullwatchCore/Models.swift`; Test `Tests/PullwatchCoreTests/ModelsTests.swift`, `Support/Fixtures.swift`

**Interfaces — Produces:**
- `public enum PRState: String, Codable, Sendable, CaseIterable { case open, merged, closed }`
- `PullRequest.state: PRState` (var), `PullRequest.closedAt: Date?` (var); init-parameters `state: PRState = .open, closedAt: Date? = nil` achteraan; `init(from:)` met `decodeIfPresent` (→ `.open` / `nil`).
- `PullRequest.fixture(..., state: PRState = .open, closedAt: Date? = nil)`.

- [ ] **Step 1: Tests** `legacyPullRequestJSONDecodesAsOpen` (JSON zonder `state`/`closedAt` → `.open`, `nil`); `pullRequestWithStateRoundTrips` (`.merged` + `closedAt` → encode/decode gelijk).
- [ ] **Step 2:** `swift test --filter ModelsTests` → faalt.
- [ ] **Step 3:** Implementeren. Bestaande callers blijven compileren dankzij defaults.
- [ ] **Step 4:** `swift test` groen; `make build` slaagt.
- [ ] **Step 5: Commit** `feat: add PR state to pull request model`

---

### Task 2: History.merge(synced:)

**Files:** Modify `Sources/PullwatchCore/History.swift`; Test `Tests/PullwatchCoreTests/HistoryTests.swift`

**Interfaces:**
- Consumes: `PullRequest.state/closedAt` (Task 1).
- Produces: `@discardableResult public mutating func merge(synced: [PullRequest]) -> Bool` (true als er iets veranderde). `HistoryEntry` krijgt `var prState: PRState?` (nil voor tags).

- [ ] **Step 1: Tests**
  - `mergeAddsNewAsReadSortedByCreatedAt`: history met gemeld item `detectedAt = t0+1000`; merge PR met `createdAt = t0` → staat ná het gemelde item, `isRead == true`, `detectedAt == t0`; merge returns true.
  - `mergeUpdatesStateWithoutTouchingReadOrDetectedAt`: gemelde ongelezen PR (open) → merge zelfde PR `.merged`, `closedAt`, nieuwe titel → item `isRead == false`, `detectedAt` gelijk, `prState == .merged`, titel bijgewerkt, positie gelijk.
  - `mergeUnchangedReturnsFalse`: twee keer dezelfde merge → tweede `false`.
  - `mergeIgnoresTags`: tag-item met zelfde repo blijft ongemoeid.
- [ ] **Step 2:** faalt. **Step 3:** implementeren (binaire of lineaire insert op `detectedAt`, nieuwste eerst). **Step 4:** `swift test` groen.
- [ ] **Step 5: Commit** `feat: merge synced pull requests into history`

---

### Task 3: Providers — pullRequests(updatedSince:limit:)

**Files:** Modify `Sources/PullwatchCore/PRProvider.swift`, `GitHubProvider.swift`, `AzureDevOpsProvider.swift`, `Tests/.../Support/MockProvider.swift`; Test `GitHubProviderTests.swift`, `AzureDevOpsProviderTests.swift`

**Interfaces — Produces:**
- `PRProvider.pullRequests(updatedSince since: Date?, limit: Int) async throws -> [PullRequest]` — alle statussen, nieuwste eerst (GitHub: `updated` desc; ADO: `creationDate` desc na samenvoegen), afgekapt op `limit`.
- `MockProvider.set(syncedPullRequests:)`, `set(syncError:)`, `syncCount`, `lastSyncSince: Date??` (laatste doorgegeven `since`). `GatedProvider` → `[]`.

GitHub: `search/issues` met `q = "is:pr {org|user}:{owner}" + (since.map { " updated:>=\(ISO8601, UTC, seconden)" } ?? "")`, `sort=updated`, `order=desc`, `per_page=100`, max 10 pagina's of tot `limit`. DTO uitbreiden: `state: String`, `closedAt: String?`, `pullRequest: { mergedAt: String? }?`. Mapping: `state == "open"` → `.open`; `mergedAt != nil` → `.merged`; anders `.closed`.

ADO: per project `_apis/git/pullrequests` met `searchCriteria.status=all`, `$top=100`, `$skip`. Met `since`: twee reeksen — `searchCriteria.queryTimeRangeType=created` en `=closed`, beide met `searchCriteria.minTime={ISO8601}` — samengevoegd op `pullRequestId`. Zonder `since`: één reeks, stoppen zodra `limit` bereikt. DTO: `status`, `closedDate?`. Mapping: `active` → open, `completed` → merged, `abandoned` → closed. 404 op project → overslaan.

- [ ] **Step 1: Tests**
  - GitHub `syncMapsStates`: 3 items (open; closed+merged_at; closed zonder merged_at) → `[.open, .merged, .closed]`, `closedAt` gezet bij de laatste twee.
  - GitHub `syncQueryIncludesUpdatedSinceAndSort`: request-URL bevat `updated:>=2025-10-09T…Z` (url-decoded), `sort=updated`, `order=desc`; zonder `since` géén `updated:`.
  - GitHub `syncStopsAtLimit`: 2 pagina's van 100, `limit: 150` → 150 PR's, 2 requests.
  - ADO `syncMapsStates`: active/completed/abandoned → open/merged/closed.
  - ADO `syncMergesCreatedAndClosedWithoutDuplicates`: route met `queryTimeRangeType=created` geeft PR 1,2; `=closed` geeft PR 2,3 → 3 PR's, elk één keer; beide requests bevatten `searchCriteria.minTime=` en `searchCriteria.status=all`.
  - ADO `syncWithoutSinceUsesSingleQuery`: geen `queryTimeRangeType` in de requests.
- [ ] **Step 2:** faalt. **Step 3:** implementeren. **Step 4:** `swift test` groen.
- [ ] **Step 5: Commit** per provider: `feat: sync pull requests from GitHub` / `feat: sync pull requests from Azure DevOps`

---

### Task 4: Sync in PollEngine

**Files:** Modify `Sources/PullwatchCore/PollEngine.swift`, `SeenState.swift`; Test `PollEngineTests.swift`, `SeenStateTests.swift`

**Interfaces:**
- Consumes: `PRProvider.pullRequests(updatedSince:limit:)`, `HistoryRetention.maxAge`, `PRFilter.passes`, `Account.filterSettings`.
- Produces:
  - `public struct SyncMark: Codable, Equatable, Sendable { var at: Date; var settings: FilterSettings; var retention: HistoryRetention }`; `SeenState.syncMarks: [String: SyncMark]` (key `accountId.uuidString`, `decodeIfPresent` → `[:]`, mee in `forget`/`retain`).
  - `PollEngine.poll(accounts:interval:retention:) async -> PollResult` (nieuwe parameter `retention: HistoryRetention`; bestaande tests geven `.oneYear` mee).
  - `PollEngine.syncLimit = 1000`, `PollEngine.syncOverlap: TimeInterval = 3600`.
  - `PollResult.syncedPullRequests: [PullRequest]` (gefilterd).

Gedrag:
- `Schedule.nextSyncDue = .distantPast`; sync is aan de beurt als `nextSyncDue <= t` (bij een job die toch al draait). `forceRefresh` zet ook `nextSyncDue = t` (behalve tijdens PR-rate-limit, zoals nu).
- `since`: als `syncMarks[id]` bestaat **en** `settings == account.filterSettings` **en** `retention` gelijk → `mark.at − syncOverlap`; anders eerste sync: `retention.maxAge.map { t − $0 }` (nil bij `.forever`).
- Sync-call in `fetch` ná PR's en tags. Fouten worden gevangen en als `syncError` teruggegeven — nooit `.failure`.
- Succes: `syncMarks[id] = SyncMark(at: t, settings:, retention:)`, `nextSyncDue = t + tagInterval`, resultaat door `PRFilter.passes(_, settings:, currentUserId:)` naar `syncedPullRequests`. Niets in `seen`.
- `syncError == .rateLimited(until)` → `nextSyncDue = min(until, t + maxRateLimitWait)`; andere fout → `nextSyncDue = t + tagInterval`; beide loggen; `syncMarks` ongewijzigd; account `.ok`.

- [ ] **Step 1: Tests**
  - `firstSyncUsesRetentionWindow`: retention `.twoMonths` → `lastSyncSince == t − 61 dagen`; `.forever` → `nil`.
  - `laterSyncUsesLastSyncMinusOverlap`: na sync op t, `advance(900)` → `since == t − 3600`.
  - `syncRunsEvery900Seconds`: `advance(120)` → `syncCount` gelijk; `advance(780)` → +1; `forceRefresh` → +1.
  - `syncResultIsFiltered`: repoWatch `["proj/x": .none]`, synced PR's in `proj/x` en `proj/a` → alleen `proj/a`; eigen PR (authorId "me") eruit bij `hideOwn`.
  - `syncDoesNotNotifyOrMarkSeen`: synced open PR #5 die ook in `openPullRequests` staat na de stille eerste poll → wordt in de volgende poll nog steeds gemeld als hij nieuw is (sync markeerde niets). Concreet: eerste poll zonder PR's; tweede poll: sync én open-lijst bevatten #5 → `newPullRequests == [#5]`.
  - `syncErrorKeepsAccountOk`: `set(syncError: .server(status: 500))` → status `.ok`, PR's gemeld, `syncMarks` niet gezet (volgende sync is weer eerste).
  - `syncRateLimitPostponesOnlySync`: `.rateLimited(until: t+600)` → volgende PR-poll na 120 s draait (`fetchCount` +1), sync pas na 600 s.
  - `settingsChangeTriggersFullResync`: na sync, `includeDrafts = true` → volgende sync `since` is weer `t − retention`.
  - `retentionChangeTriggersFullResync`: idem met andere retention.
  - `SeenStateTests.legacySeenJsonWithoutSyncMarksLoads`.
- [ ] **Step 2:** faalt. **Step 3:** implementeren. **Step 4:** `swift test` groen; `make build` (AppModel aanpassen aan nieuwe `poll`-signatuur met `config.historyRetention`).
- [ ] **Step 5: Commit** `feat: periodic history sync in poll engine`

---

### Task 5: App-wiring, statuskolom, README

**Files:** Modify `App/AppModel.swift`, `App/HistoryView.swift`, `App/KindStyle.swift`, `README.md`

**Interfaces — Consumes:** `PollResult.syncedPullRequests`, `History.merge(synced:)`, `HistoryEntry.prState`, `PRState`.

- `tick`: na `add` van gemelde items → `merge(synced:)`; `prune`/opslaan als `add` of `merge` iets veranderde. Notificatie-logica ongewijzigd.
- `KindStyle.swift`: extension `PRState` met `color` (`.green` / `.purple` / `.gray`) en `label` ("Open"/"Gemerged"/"Gesloten"), plus `StatePill` view.
- `HistoryView`: kolom "Status" na Type; `StatePill` voor PR's, leeg voor tags.
- README: korte sectie over ophalen/inhalen (eerste keer binnen bewaartermijn, max 1000 per account, elke 15 min bijgewerkt, opgehaalde PR's zonder melding als gelezen; GitHub-zoek-API heeft eigen limiet van 30/min).

- [ ] **Step 1:** `make build` slaagt; `swift test` groen.
- [ ] **Step 2: Commit** `feat: show PR status and wire history sync`

---

## Na alle taken

- [ ] `swift test` groen, `make build` slaagt; whole-branch review; superpowers:finishing-a-development-branch.
- [ ] Handmatig (gebruiker): na `make run` vult de geschiedenis zich binnen enkele minuten; statuskolom toont Gemerged/Gesloten; geen meldingenstorm.
