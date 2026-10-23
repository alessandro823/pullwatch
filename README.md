# Pullwatch

macOS menubar-app die nieuwe pull requests in Azure DevOps en GitHub meldt, plus nieuwe tags (optioneel per repo).

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

Tags volg je door per repo het vinkje voor tags aan te zetten; ze staan standaard overal uit. Tags worden elke 15 minuten gepolld (los van het PR-interval; "Nu verversen" pollt ook tags). De eerste tag-poll per repo is stil.

Via **Geschiedenis…** in het menu open je een doorzoekbaar overzicht van alle gedetecteerde PR's en tags (filter op soort, dubbelklik opent de pagina). De bewaartermijn (2 maanden, 6 maanden, 1 jaar of altijd) stel je in onder Instellingen → Algemeen.

### Geschiedenis ophalen en bijhouden

Pullwatch haalt ook al bestaande PR's (open, gemerged en gesloten) op voor de geschiedenis. De eerste keer gaat dat terug tot de ingestelde bewaartermijn, met maximaal 1000 PR's per account; daarna wordt de geschiedenis elke 15 minuten bijgewerkt (status, titel en sluitdatum). Opgehaalde PR's geven geen melding en staan als gelezen in de lijst; de kolom **Status** toont Open, Gemerged of Gesloten. Een wijziging van het repo-filter of de bewaartermijn start voor dat account opnieuw met een eerste keer ophalen. De GitHub-zoek-API heeft een eigen limiet van 30 verzoeken per minuut; bij een limiet wacht Pullwatch tot die is verlopen en loopt de PR-polling gewoon door.

Bestaande PR's worden bij het toevoegen stil overgeslagen; alleen nieuwe PR's geven een melding.

Aanroepen van `az` en `gh` time-outen na 20 seconden.

### Versies

Via **Versies…** in het menu check je welke gevolgde repo's (minstens één vinkje) achterlopen. Pullwatch leest per repo `go.mod`, `*.csproj`/`*.fsproj`/`Directory.Build.props`, `package.json` (Node, Angular, React, Vue, Next.js, Nuxt), `.nvmrc`, `pyproject.toml`, `.python-version` en `Dockerfile*` op de default branch, en vergelijkt de versies met [endoflife.date](https://endoflife.date). Status: **Actueel**, **Achter** (er is een nieuwere major/minor; patches tellen niet), **EOL** of **Onbekend**. De check draait eens per dag vanzelf (uit te zetten onder Instellingen → Algemeen) en altijd via **Opnieuw checken**; het laatste resultaat blijft bewaard. Komt er bij een automatische check een nieuwe CVE bij, dan krijg je een melding; de eerste check, nieuw gevolgde repo's en repo's waarvan de vorige CVE-check mislukte geven geen melding. Een check die helemaal mislukt (bv. offline) wordt na een uur opnieuw geprobeerd.

Dezelfde check zoekt bekende kwetsbaarheden (CVE's) via [OSV.dev](https://osv.dev) in packages met een exacte versie: `go.mod` (requires), `package-lock.json`, `PackageReference`/`PackageVersion` in .NET-projectbestanden, `requirements*.txt` (alleen `==`), `poetry.lock` en `uv.lock`. `yarn.lock` en `pnpm-lock.yaml` worden niet gelezen. Per repo zie je het aantal kwetsbaarheden per ernst, met link, getroffen package en de versie waarin het opgelost is. Met de kopieerknop zet je de versies en kwetsbaarheden van een repo als tekst op het klembord.

### PAT-scopes

- Azure DevOps: **Code (Read)** (volstaat ook voor tags) en **Project and Team (Read)** (de projectenlijst komt van `/_apis/projects`)
- GitHub (fine-grained): **Pull requests: Read** en **Metadata: Read** op de gewenste repos, plus **Contents: Read** voor Versies. Tags (`GET /repos/{owner}/{repo}/tags`) vereisen volgens de GitHub-documentatie alleen **Metadata: Read**, niet Contents (niet getest met een live PAT); classic: `repo`

## Bekende eigenaardigheden

- Door ad-hoc signing kan macOS na elke `make install` opnieuw om Keychain-toegang vragen voor PAT-accounts; kies "Altijd toestaan".
- Bij de eerste start vraagt Pullwatch om toestemming voor meldingen.
- `make run` herstart een al draaiende Pullwatch niet; sluit hem eerst af via het menu "Stop".

## Data

`~/Library/Application Support/Pullwatch/` — `config.json`, `seen.json`, `history.json` (geschiedenis van PR's en tags), `versions.json` (laatste versiecheck). Tokens staan in de Keychain (`nl.torrisi.pullwatch`).

Logs: `log stream --predicate 'subsystem == "nl.torrisi.pullwatch"'`
