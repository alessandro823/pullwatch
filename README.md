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

Aanroepen van `az` en `gh` time-outen na 20 seconden.

### PAT-scopes

- Azure DevOps: **Code (Read)** en **Project and Team (Read)** (de projectenlijst komt van `/_apis/projects`)
- GitHub (fine-grained): **Pull requests: Read** en **Metadata: Read** op de gewenste repos; classic: `repo`

## Bekende eigenaardigheden

- Door ad-hoc signing kan macOS na elke `make install` opnieuw om Keychain-toegang vragen voor PAT-accounts; kies "Altijd toestaan".
- Bij de eerste start vraagt Pullwatch om toestemming voor meldingen.
- `make run` herstart een al draaiende Pullwatch niet; sluit hem eerst af via het menu "Stop".

## Data

`~/Library/Application Support/Pullwatch/` — `config.json`, `seen.json`, `recent.json`. Tokens staan in de Keychain (`nl.torrisi.pullwatch`).

Logs: `log stream --predicate 'subsystem == "nl.torrisi.pullwatch"'`
