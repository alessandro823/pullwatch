# Pullwatch — tags en geschiedenis

Datum: 2026-10-16
Status: brainstorm afgerond, wacht op review
Bouwt voort op: `2026-10-15-pullwatch-design.md`

## Waarom

Pullwatch bevalt. Twee wensen erbij:

1. **Nieuwe tags melden** in gevolgde repo's — puur informatief ("er is een release geweest"), maar wél als gewone macOS-melding, net als een PR.
2. **Lokale geschiedenis** van wat er gemeld is, doorzoekbaar, met doorklikken naar de echte PR of tag.

Harde eis van de gebruiker: **PR's en tags altijd duidelijk van elkaar te onderscheiden** — in melding, menu en geschiedenis.

## Doelen

- Nieuwe tag in een repo waarvoor tags aan staan → macOS-melding, klik opent tag-pagina.
- Per repo kiezen: PR's, tags, beide of niets.
- Geschiedenisvenster met zoekveld (titel/tagnaam, auteur, repo), filter Alles / PR's / Tags, tabel, klik opent item.
- Menu toont PR's en tags in aparte secties.
- Bewaartermijn instelbaar.

## Niet-doelen

- Acties op tags (deployen, changelog tonen, release notes ophalen).
- Releases als apart concept: we volgen git-tags, niet GitHub Releases.
- Gelezen/ongelezen synchroniseren met GitHub/Azure DevOps.
- Geschiedenis van dingen die níet gemeld zijn (stil geseede items komen er niet in).

## Anti-doelen (zou het mislukt maken)

- Een stortvloed aan tag-meldingen na de upgrade of na het aanzetten van tags op een repo met honderden bestaande tags.
- PR's en tags die op elkaar lijken waardoor je moet lezen om te weten wat het is.
- Merkbaar meer rate-limit-problemen bij accounts met veel repo's.
- Bestaande repo-instellingen kwijt na de upgrade.

## Wat de gebruiker besliste

- Tags krijgen een gewone melding, zoals PR's.
- Tags volgen dezelfde accounts/repo's; per repo vink je PR's en/of tags aan.
- Repo-instelling: **variant A** — tabel met per repo twee vinkjes (PR's, Tags) plus een keuze voor nieuwe repo's. De oude modus "alles behalve / alleen aangevinkt" verdwijnt.
- Tags gaan **alleen aan via het vinkje per repo**. De standaard voor nieuwe repo's kent alleen Niets / PR's — nooit tags (houdt het aantal tag-aanvragen klein en voorspelbaar).
- UI-indeling: **variant B** — menu met twee secties (Pull requests, Tags) en knop "Geschiedenis…" die een apart venster opent met zoekveld, segmented filter Alles/PR's/Tags en tabel (type, titel, repo, auteur, wanneer).
- Bewaren: instelling "Geschiedenis bewaren" met 2 maanden / 6 maanden / 1 jaar / altijd; standaard 1 jaar.
- Opslag als JSON-bestand (geen SQLite); later overstappen mag als het traag wordt.

Mockups staan in `.superpowers/brainstorm/*/content/history-layout.html` (optie B) en `repo-settings.html` (optie A).

## Kleur en herkenning

- PR: blauw, SF Symbol `arrow.triangle.pull`, label "PR".
- Tag: oranje, SF Symbol `tag`, label "TAG".
- Overal consequent (menu, geschiedenistabel, filter).

## Repo-model (vervangt `filterMode` + `repos`)

```swift
enum WatchSet: String, Codable { case none, prs, tags, both }   // of OptionSet; aan builder

struct Account {
    ...
    var repoWatch: [String: WatchSet]   // expliciet ingestelde repo's (case-insensitive key)
    var newRepoDefault: NewRepoDefault  // .none of .prs — nooit tags
    var includeDrafts: Bool             // alleen PR's
    var hideOwn: Bool                   // alleen PR's
}
```

**Migratie** (bij laden van `config.json` met oud formaat):

| Oud | `repoWatch` | `newRepoDefault` |
|---|---|---|
| `deny` + repos | elke gelijste repo → `.none` | `.prs` |
| `allow` + repos | elke gelijste repo → `.prs` | `.none` |

Tags staan na migratie nergens aan → geen enkele nieuwe melding door de upgrade. Gedrag voor PR's moet exact gelijk blijven (test dit).

**Settings-UI:** de bestaande repolijst (zoeken, "Repos laden") wordt een tabel met kolommen Repo / PR's / Tags. Bovenaan picker "Nieuwe repo's volgen: Niets · PR's" (afwijkend van de mockup, die nog Tags/Beide toonde). De set repo's waarvoor tags gepolld worden = precies de repo's in `repoWatch` met `.tags` of `.both`. Een repo waarvan beide vinkjes gelijk zijn aan de default hoeft niet in `repoWatch` te staan (aan builder).

`FilterSettings` / seeding-logica moeten mee: een repo die van "geen tags" naar "tags" gaat, seedt zijn bestaande tags stil — zelfde mechanisme als nu via `lastSettings`.

## Tags ophalen

Nieuwe providermethode, bv. `func tags(in repos: [String]) async throws -> [Tag]`, alleen aangeroepen voor repo's met tags aan.

```swift
struct Tag {
    let accountId: UUID
    let repo: String
    let name: String
    let authorName: String?   // vaak onbekend
    let webURL: URL
    var dedupKey: String { "\(accountId):\(repo):tag:\(name)" }
}
```

- **Azure DevOps:** `GET /{project}/_apis/git/repositories/{repo}/refs?filter=tags/` (gepagineerd via continuation token). Auteur: `creator.displayName`. URL: `https://dev.azure.com/{org}/{project}/_git/{repo}?version=GT{tag}`. PAT-scope Code (Read) volstaat.
- **GitHub:** volledige taglijst per repo ophalen (alle pagina's) en diffen met `seen` — dus ook tags op oudere commits (backports) worden gemeld. REST `/repos/{o}/{r}/tags` of GraphQL `refs(refPrefix: "refs/tags/")` met meerdere repo's per query: keuze aan builder. Auteur ontbreekt meestal → `nil`. URL: `https://github.com/{o}/{r}/releases/tag/{tag}` (werkt ook zonder release). Scope: Metadata (Read) volstaat; README bijwerken als dat niet klopt.
- **Interval:** tags apart en trager pollen dan PR's — vast **15 minuten** (claude's call), met dezelfde backoff/rate-limit-afhandeling per account. Handmatig verversen pollt ook tags.
- Altijd volledige lijst → elke bestaande tag wordt elke tag-poll opnieuw "gezien" en dus niet geprunet. Een verwijderde tag valt na 30 dagen uit `seen`; komt hij daarna terug met dezelfde naam, dan meldt hij opnieuw (acceptabel).
- **Eerste tag-poll van een repo is altijd stil** (claude's call): of de repo nu nieuw is in de org of net een tag-vinkje kreeg, de bestaande tags worden stil geseed. Bijhouden per repo (bv. set "tag-geseede repo's" in `SeenState`), niet alleen via `lastSettings`.
- `hideOwn` en `includeDrafts` gelden niet voor tags.

## Meldingen

- Tag: titel `"{repo}: nieuwe tag"`, body `"{tagnaam}"` (+ `" — {auteur}"` als bekend). Klik opent tag-URL en markeert gelezen.
- PR: ongewijzigd.
- Burst: per soort apart (>3 PR's → "n nieuwe PR's"; >3 tags → "n nieuwe tags"). Een gemengde poll met 2 PR's en 2 tags geeft dus 4 losse meldingen.

## Geschiedenis

Vervangt `RecentList` / `recent.json` door `history.json`.

```swift
struct HistoryItem: Identifiable {
    enum Kind { case pullRequest(PullRequest), tag(Tag) }
    let kind: Kind
    let detectedAt: Date
    var isRead: Bool
    var id: String   // dedupKey
}
```

- Alleen gemelde items komen erin.
- Bestaande `recent.json` bij eerste start migreren naar `history.json` (gelezen-status behouden), daarna `recent.json` laten staan of verwijderen — aan builder.
- Opruimen: bij laden en na elke toevoeging items ouder dan de bewaartermijn weg (op `detectedAt`).
- Account verwijderen → zijn items weg (zoals nu).
- Opslaan alleen bij wijziging (nieuw item, gelezen markeren, opruimen).
- Grootte-inschatting: ~0,5 KB per item; 1 jaar bij druk gebruik ≈ 10 MB. Prima voor JSON; bij "altijd" eventueel later SQLite.

**Zoeken:** case-insensitive substring over titel/tagnaam, auteur en repo; gecombineerd met filter Alles/PR's/Tags. In geheugen, live bij typen.

**Venster "Geschiedenis":** apart `Window` (zoals Settings), geopend via knop in het menu. Tabel kolommen: type-pill, titel, repo, auteur ("—" als onbekend), wanneer (relatief, tooltip absoluut). Sortering nieuwste eerst. Dubbelklik of klik opent URL en markeert gelezen. Ongelezen visueel herkenbaar (bv. vet of stip) — aan builder.

## Menu

- Sectie **Pull requests**: laatste 5 PR's.
- Sectie **Tags**: laatste 5 tags (sectie verborgen als er nooit een tag is gemeld).
- Ongelezen-stip zoals nu; "Alles gelezen" geldt voor beide.
- Knop **Geschiedenis…** naast Instellingen.
- Lege staat: "Nog geen nieuwe PR's" / "Nog geen nieuwe tags".

## Instellingen (algemeen)

- Nieuwe picker "Geschiedenis bewaren": 2 maanden / 6 maanden / 1 jaar / altijd (standaard 1 jaar). Opgeslagen in `AppConfig`.

## Testen

In `PullwatchCore`, unit tests met de bestaande mocks:
- config-migratie oud → nieuw (beide modi), PR-gedrag identiek;
- tag-detectie: eerste poll stil, nieuwe tag meldt, tag aanzetten op repo seedt stil, tags uit → niets;
- providers: tags parsen (ADO refs + paginering, GitHub GraphQL);
- notification planner per soort;
- history: toevoegen, gelezen, opruimen per termijn, zoeken/filter, migratie van `recent.json`.

## Aan de builder

- Exacte type-vormen (`WatchSet` enum vs OptionSet, `HistoryItem` encoding).
- Of tags in `PollEngine` meedraaien of in een eigen schema binnen dezelfde actor.
- REST vs GraphQL voor GitHub-tags, en batchgrootte.
- Visuele details van tabel en menu binnen de afspraken hierboven.

## Calls van Claude (gebruiker kan nog bijsturen)

- Tags pollen elke 15 minuten, los van het PR-interval.
- Volledige taglijst per repo diffen (geen "top 20"), zodat backport-tags niet gemist worden.
- Eerste tag-poll per repo altijd stil.
- Tag-URL op GitHub wijst naar `/releases/tag/{naam}`.
- Burst-samenvatting per soort.
- Menu toont 5 per sectie.
- `hideOwn`/drafts niet van toepassing op tags.
