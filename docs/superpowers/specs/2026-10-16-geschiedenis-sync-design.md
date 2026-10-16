# Pullwatch — geschiedenis ophalen, inhalen en PR-status

Datum: 2026-10-16
Status: brainstorm afgerond, wacht op review
Bouwt voort op: `2026-10-16-tags-en-geschiedenis-design.md`

## Waarom

De geschiedenis bevat alleen wat Pullwatch zelf gemeld heeft. De gebruiker wil:

1. **Eenmalig vullen** met wat er al gebeurd is op GitHub en Azure DevOps.
2. **Inhalen** na een periode dat de pc uit stond (bv. twee weken): PR's die in die tijd geopend én gesloten zijn, ziet Pullwatch nu nooit.
3. **PR-status** (open / gemerged / gesloten) in de geschiedenis, die **meegroeit** als een PR later verandert.

## Doelen

- Eerste sync na upgrade vult de geschiedenis met maximaal 1000 PR's per account binnen de bewaartermijn.
- Daarna periodieke sync die gemiste PR's toevoegt en statussen bijwerkt.
- Statuskolom in het Geschiedenis-venster.

## Niet-doelen

- Tags eenmalig aanvullen (git-tags hebben geen datum zonder extra aanvraag per tag; gemiste tags komen bij terugkomst al binnen omdat tags blijven bestaan).
- Meldingen voor opgehaalde/ingehaalde PR's.
- Status van tags; reviews, comments, CI-status.
- Filteren op status in het venster (kan later).

## Anti-doelen

- Een stortvloed aan meldingen na de eerste sync of na lang uit staan.
- Rate-limit-problemen die PR-meldingen stilleggen.
- Een gemelde PR die door de sync als "gelezen" wordt gemarkeerd.

## Wat de gebruiker besliste

- Ophalen van GitHub en Azure DevOps, orde "laatste 1000".
- Ook gemerged/gesloten PR's, met status in de tabel.
- Status groeit mee.
- Voorstel hieronder (één sync-mechanisme, stil toevoegen als gelezen, zelfde filters, kleuren als GitHub, geen tag-backfill) is akkoord.

## Model

```swift
public enum PRState: String, Codable, Sendable { case open, merged, closed }

PullRequest
    + state: PRState      // decodeIfPresent → .open (oude history.json / recent.json)
    + closedAt: Date?     // decodeIfPresent → nil
```

- `openPullRequests()` levert `state = .open`.
- `dedupKey` ongewijzigd.

## Provider

Nieuwe methode:

```swift
/// PR's (alle statussen) aangemaakt óf gesloten/bijgewerkt sinds `since` (nil = geen ondergrens), nieuwste eerst, max `limit`.
func pullRequests(updatedSince since: Date?, limit: Int) async throws -> [PullRequest]
```

- **GitHub:** `GET /search/issues?q=is:pr {org|user}:{owner} updated:>={ISO8601}&sort=updated&order=desc&per_page=100&page=n` (zonder `updated:` als `since == nil`). Max 10 pagina's (zoek-API-limiet 1000). Status: `state == "open"` → open; `pull_request.merged_at != nil` → merged; anders closed. `closedAt` uit `closed_at`.
- **Azure DevOps:** per project `GET /{project}/_apis/git/pullrequests?searchCriteria.status=all&$top=100&$skip=…`. Moet PR's vangen die sinds `since` **aangemaakt of gesloten** zijn: twee queries met `searchCriteria.queryTimeRangeType=created` resp. `closed` en `searchCriteria.minTime={ISO8601}`, samengevoegd op id (zonder `since`: alleen status=all, nieuwste eerst). Status: `active` → open, `completed` → merged, `abandoned` → closed; `closedAt` uit `closedDate`. Totaal over projecten afgekapt op `limit`, nieuwste eerst.
- 404 op een project: overslaan. Overige fouten: gooien.

## Sync in PollEngine

- Per account `lastSync: Date` in `SeenState` (`decodeIfPresent` → leeg).
- Sync draait mee met het tag-schema (`nextTagDue`, elke 900 s, "Nu verversen" forceert), voor **elk** account, ook zonder tag-repo's.
- `since`: bij eerste sync `now − retention.maxAge` (bij "altijd": `nil`); daarna `lastSync − 1 uur` (overlap tegen klokverschil). `limit = 1000`.
- Resultaat door hetzelfde `PRFilter` als de poll (repo-vinkje PR's, drafts, eigen PR's).
- Bij succes `lastSync = t`. **Fouten laten het account nooit falen** (claude's call; GitHub-sync en open-PR-poll delen het zoekbudget van 30/min): fout loggen, PR's/tags van deze poll gewoon verwerken, `lastSync` niet bijwerken. Bij `.rateLimited(until)` wordt alleen de volgende sync uitgesteld tot `until` (eigen `nextSyncDue` in het schema, los van `nextTagDue`); PR-polling loopt door.
- **Opnieuw vullen** (claude's call): `lastSync` van een account vervalt (→ volgende sync is weer een eerste sync) als de filter-instellingen van dat account wijzigen (zelfde vergelijking als `lastSettings`) of de bewaartermijn verandert. Bijv. PR-vinkje aan, drafts aan, eigen PR's tonen, langere termijn. `merge` is idempotent, dus opnieuw ophalen kost alleen aanvragen.
- Sync markeert **niets** in `seen`: meldingen blijven volledig bij de bestaande open-PR-poll. (Een nieuwe open PR die de sync eerder ziet dan de poll, wordt dus nog steeds door de poll gemeld.)
- `PollResult.syncedPullRequests: [PullRequest]`.

De bewaartermijn moet daarvoor in de engine bekend zijn: `poll(accounts:interval:retention:)` of vergelijkbaar — aan builder.

## History

```swift
/// Voegt gesyncte PR's toe of werkt ze bij. Bestaande items: alleen state/closedAt/title bijwerken
/// (gelezen-status en detectedAt blijven). Nieuwe items: isRead = true, detectedAt = createdAt.
mutating func merge(synced: [PullRequest])
```

- In `AppModel.tick`: eerst gemelde items `add` (ongelezen), dan `merge(synced:)`, dan `prune`, dan opslaan. Zo wordt een gemelde PR nooit stil gelezen.
- Bijgewerkte status van een gemelde PR komt ook via `merge`.
- `detectedAt = createdAt` voor opgehaalde items zodat ze chronologisch staan en de bewaartermijn klopt.
- `merge` voegt nieuwe items **gesorteerd op `detectedAt`** in (nieuwste eerst blijft gelden), niet bovenaan. Het menu ("laatste 5") blijft dus de recentste items tonen; oude opgehaalde PR's zakken vanzelf onder de recent gemelde.
- Opslaan alleen als `merge` iets veranderde.

## UI

- Geschiedenis-tabel: kolom **Status** na Type, alleen voor PR's (tags: leeg). Pill/label: open groen, gemerged paars, gesloten grijs; teksten "Open", "Gemerged", "Gesloten".
- Menu: ongewijzigd (status in menurijen aan builder, niet verplicht).
- README: sync/inhalen kort beschrijven; GitHub zoek-API telt tegen een aparte rate limit (30/min).

## Testen

- Providers: status-mapping (GitHub open/merged/closed, ADO active/completed/abandoned), `since`-query, paginering en `limit`, ADO samenvoegen van created+closed zonder dubbelen.
- Engine: eerste sync gebruikt `now − retention`; tweede `lastSync − 1h`; sync elke 900 s; sync-fout laat PR-meldingen door en houdt `lastSync`; rate limit faalt; filter toegepast; sync markeert niets in `seen`.
- History: `merge` voegt nieuw toe als gelezen met `detectedAt = createdAt`; werkt status bij zonder gelezen/detectedAt te wijzigen; gemelde-dan-gesyncte PR blijft ongelezen; oude JSON zonder `state` → `.open`.

## Calls van Claude

- Eén sync-mechanisme voor eenmalig vullen, inhalen en status bijwerken.
- Sync elke 900 s mee met tags; overlap 1 uur.
- Eerste sync binnen bewaartermijn, max 1000 per account; "altijd" = geen datumgrens.
- Opgehaalde items stil en gelezen, `detectedAt = createdAt`.
- Kleuren zoals GitHub (groen/paars/grijs).
- Geen tag-backfill.
- Sync-fouten (ook rate limit) laten het account nooit falen; rate limit stelt alleen de sync uit.
- Filter- of bewaartermijnwijziging → opnieuw vullen voor dat account.
- `merge` voegt gesorteerd op `detectedAt` in; menu ongewijzigd.
