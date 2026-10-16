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

Bestaande PR's worden bij het toevoegen stil overgeslagen; alleen nieuwe PR's geven een melding.

Aanroepen van `az` en `gh` time-outen na 20 seconden.

### PAT-scopes

- Azure DevOps: **Code (Read)** (volstaat ook voor tags) en **Project and Team (Read)** (de projectenlijst komt van `/_apis/projects`)
- GitHub (fine-grained): **Pull requests: Read** en **Metadata: Read** op de gewenste repos. Tags (`GET /repos/{owner}/{repo}/tags`) vereisen volgens de GitHub-documentatie alleen **Metadata: Read**, niet Contents (niet getest met een live PAT); classic: `repo`

## Bekende eigenaardigheden

- Door ad-hoc signing kan macOS na elke `make install` opnieuw om Keychain-toegang vragen voor PAT-accounts; kies "Altijd toestaan".
- Bij de eerste start vraagt Pullwatch om toestemming voor meldingen.
- `make run` herstart een al draaiende Pullwatch niet; sluit hem eerst af via het menu "Stop".

## Data

`~/Library/Application Support/Pullwatch/` — `config.json`, `seen.json`, `history.json` (geschiedenis van PR's en tags). Tokens staan in de Keychain (`nl.torrisi.pullwatch`).

Logs: `log stream --predicate 'subsystem == "nl.torrisi.pullwatch"'`
