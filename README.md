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

Via **Versies…** in het menu check je welke gevolgde repo's (minstens één vinkje) achterlopen. Pullwatch leest per repo `go.mod`, `*.csproj`/`*.fsproj`/`Directory.Build.props`, `package.json` (Node, Angular, React, Vue, Next.js, Nuxt), `composer.json` (PHP, Symfony, Laravel), `rust-toolchain(.toml)` en `rust-version` in de root-`Cargo.toml` (Rust), `.nvmrc`, `pyproject.toml`, `.python-version` en `Dockerfile*` op de default branch, en vergelijkt de versies met [endoflife.date](https://endoflife.date). Een versie-eis die alleen een minimum is (`engines.node`, `php` in `composer.json`, `requires-python`, `rust-version`) telt niet als dezelfde taal ergens echt vastgezet is (Docker-image, `.nvmrc`, `rust-toolchain`), en een `go.mod` die via `replace … => ./pad` als lokale kopie van een dependency dient telt niet mee. Voor frameworks gaat de geïnstalleerde versie uit `package-lock.json`/`composer.lock` voor het minimum uit het manifest. Eigen Docker-images worden herkend aan een bekende naam vóór het eerste streepje (`php-fpm-alpine:8.4` → PHP 8.4); `ARG`-standaardwaarden in `FROM` worden ingevuld. Status: **Actueel**, **Achter** (er is een nieuwere major/minor; patches tellen niet), **EOL** of **Onbekend**. De check draait eens per dag vanzelf (uit te zetten onder Instellingen → Algemeen) en altijd via **Opnieuw checken**; het laatste resultaat blijft bewaard. Komt er bij een automatische check een nieuwe CVE bij, dan krijg je een melding; de eerste check, nieuw gevolgde repo's en repo's waarvan de vorige CVE-check mislukte geven geen melding. Een check die helemaal mislukt (bv. offline) wordt na een uur opnieuw geprobeerd.

Dezelfde check zoekt bekende kwetsbaarheden (CVE's) via [OSV.dev](https://osv.dev) in packages met een exacte versie: `go.mod` (requires), `package-lock.json`, `PackageReference`/`PackageVersion` in .NET-projectbestanden, `requirements*.txt` (alleen `==`), `poetry.lock`, `uv.lock`, `composer.lock` en `Cargo.lock` (alleen crates.io). `yarn.lock` en `pnpm-lock.yaml` worden niet gelezen. Per repo zie je het aantal kwetsbaarheden per ernst, met link, getroffen package en de versie waarin het opgelost is. Met de kopieerknop zet je de versies en kwetsbaarheden van een repo als tekst op het klembord. Met ↻ naast de kopieerknop check je één repo opnieuw (bv. na een update), zonder de rest.

Heeft een repo tags, dan wordt ook de nieuwste tag gecheckt (hoogste versienummer; pre-releases zoals `-rc1` alleen als er geen andere zijn). De tag staat naast de reponaam; wijkt een onderdeel in die release af van de default branch, dan zie je beide versies. Bij elke kwetsbaarheid staat of hij **ook in de tag** zit of **alleen op main** (nieuw sinds de release). Wat op main al opgelost is telt niet: geen melding, geen status, niet in de lijst. Via **Versies** in Geschiedenis (of rechtsklik op een regel) open je het overzicht gefilterd op die repo.

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
