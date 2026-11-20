---
title: Agents (MCP)
description: Laat een coding agent zoals Claude Code, Codex, Cursor of VS Code Pullwatch via MCP vragen naar je pull requests, repositories en kwetsbaarheden.
---

Pullwatch heeft een lokale [Model Context Protocol](https://modelcontextprotocol.io)-server, zodat een coding agent op je Mac kan vragen wat Pullwatch weet: "welke van mijn pull requests hebben falende checks?", "wat is kritiek in `acme/web`?", "waarom kan ik `express` niet bijwerken?", "wie zit nog op een oude `@acme/ui`?". De agent gebruikt wat Pullwatch al met je accounts heeft opgehaald, dus hij heeft geen eigen token nodig.

Agents lezen alleen. Ze zien alleen de repositories die je volgt, krijgen nooit een token en kunnen niets veranderen op GitHub, Azure DevOps, GitLab, Bitbucket, Codeberg, Forgejo of Gitea. Er wordt niets gedeeld tot je het aanzet.

## Aanzetten

Open Instellingen, **Agents** en kies bij **Agents toestaan Pullwatch te gebruiken**:

- **Nooit** (standaard): agents krijgen geen gegevens. Een agent die het probeert, hoort dat agents uit staan.
- **Zolang Pullwatch open is**: agents kunnen vragen zolang Pullwatch draait. Draait het niet, dan hoort de agent dat hij Pullwatch moet openen.
- **Altijd**: draait Pullwatch niet, dan start het op de achtergrond (zonder venster, het blijft in de menubalk) zodra een agent iets vraagt, en antwoordt.

Dit zijn dezelfde keuzes die Xcode heeft voor externe agents.

## Een agent instellen

Kies je agent onder **Een agent instellen**. Pullwatch toont de opdracht of de JSON met het pad van de Pullwatch die je nu gebruikt, en **Kopieer** zet die op het klembord. Voor Pullwatch in Apps ziet het er zo uit. Verplaats je de app, stel de agent dan opnieuw in.

### Claude Code

Voer uit in Terminal:

```sh
claude mcp add --scope user --transport stdio pullwatch -- /Applications/Pullwatch.app/Contents/Helpers/pullwatch-mcp
```

Met `--scope user` werkt Pullwatch in elk project. Zonder werkt het alleen in de map waar je de opdracht gaf.

### Codex

Voer uit in Terminal:

```sh
codex mcp add pullwatch -- /Applications/Pullwatch.app/Contents/Helpers/pullwatch-mcp
```

Codex schrijft dit in zijn algemene configuratie, `~/.codex/config.toml`, dus het werkt in elk project.

### Cursor

Zet in `~/.cursor/mcp.json`:

```jsonc
{
  "mcpServers": {
    "pullwatch": {
      "type": "stdio",
      "command": "/Applications/Pullwatch.app/Contents/Helpers/pullwatch-mcp"
    }
  }
}
```

### VS Code

Zet in `.vscode/mcp.json` van je project:

```jsonc
{
  "servers": {
    "pullwatch": {
      "type": "stdio",
      "command": "/Applications/Pullwatch.app/Contents/Helpers/pullwatch-mcp"
    }
  }
}
```

### Andere agents

Elke MCP-client die een server via stdio start, werkt: geef hem `/Applications/Pullwatch.app/Contents/Helpers/pullwatch-mcp` als opdracht, zonder argumenten.

## De agent één keer toestaan

De eerste keer dat een agent verbinding maakt, vraagt Pullwatch het je met een melding, bijvoorbeeld "Claude Code wil Pullwatch gebruiken", met **Sta toe** en **Sta niet toe**. Een klik op de melding zelf opent Instellingen, **Agents**. Tot je toestaat, blijft de agent verbonden maar krijgt hij geen gegevens: elke vraag krijgt als antwoord dat hij op toestemming wacht. Sta je hem toe, dan werkt zijn volgende vraag.

Je staat een agent één keer toe; Pullwatch vraagt het niet opnieuw bij elke vraag. Elke tool leest alleen wat Pullwatch je al laat zien, dus een vraag bij elke aanroep zou je vooral leren om op **Sta toe** te klikken. Eén bewuste keuze per agent, die je altijd kunt terugdraaien, beschermt je beter.

- **Toegestane agents** in Instellingen, **Agents** toont de agents die je hebt toegestaan, en de agent die wacht, met **Sta niet toe** en **Sta toe**. De verwijderknop naast een agent haalt hem van de lijst; Pullwatch vraagt het dan opnieuw bij zijn volgende verbinding.
- **Sta niet toe** sluit elke verbinding van die agent en onthoudt niets. De agent maakt niet zelf opnieuw verbinding: start hem, of zijn MCP-server, opnieuw om het nog eens te vragen.
- Pullwatch herkent een agent aan de naam die hij doorgeeft (Claude Code, Codex, Cursor, VS Code of zijn eigen naam). Die naam zie je, zodat je weet wie het vraagt; het is geen wachtwoord.

## Zien welke agents verbonden zijn

**Verbonden agents** in Instellingen, **Agents** toont elke agent die nu verbonden is: naam en versie (**Verbinden…** tot hij zegt wie hij is), sinds wanneer, de laatst gebruikte tool en wanneer, en **Wacht op toestemming** zolang hij wacht. **Loskoppelen** sluit zijn verbinding; net als na **Sta niet toe** blijft de agent dan weg tot je hem opnieuw start.

Zolang er minstens één agent verbonden is, staat bovenin het [menupaneel](/nl/using/menu/) een agentsknop met het aantal agents. Een oranje stip erop betekent dat een agent op toestemming wacht. Klik erop voor dezelfde lijst, met **Loskoppelen** per agent, **Sta niet toe** en **Sta toe** voor een agent die wacht, en **Agentinstellingen…** om Instellingen, **Agents** te openen.

## De tools

De agent kiest zelf welke tool hij gebruikt; jij stelt alleen je vraag. Elke tool leest wat Pullwatch al heeft opgehaald; geen enkele doet een netwerkaanroep of start een poll. De antwoorden zijn in het Engels: JSON met een samenvatting van één regel.

Lijsten geven standaard 25 items. Met `limit` (hoogstens 100) en `cursor` blader je verder; het antwoord heeft `total` en, als er meer is, `next_cursor`. Waar een tool `repo` vraagt, is dat `eigenaar/naam` (`project/repo` op Azure DevOps); `account_id` (uit `get_status`) is alleen nodig als twee accounts een repository met dezelfde naam volgen.

De voorbeelden hieronder komen uit de testgegevens van Pullwatch. De antwoorden zijn ingekort.

### get_status

De accounts (id, dienst, naam en host), hoe hun laatste poll ging, wat er bijgewerkt wordt, wanneer de versiecheck was, welke bronnen uit staan, en het aantal ongelezen. Een account noemt in `unreachable_repositories` de gevolgde repositories die zijn token niet kan lezen: hun tags en branches worden niet bijgewerkt. Geen argumenten.

```jsonc
// get_status {}
// "2 accounts (1 failing), 3 followed repositories; sources off: PyPI."
{"accounts":[{"host":"github.com","name":"@octo","service":"GitHub","state":"ok","last_poll":"2026-11-04T09:00:00Z"},
  {"host":"gitlab.example.com","name":"group","service":"GitLab","state":"failed","error":"Token invalid or expired"}],
 "followed_repositories":3,"unread_pull_requests":6,"unread_tags":2,
 "sources_off":[{"message":"Not checked: source PyPI is off.","name":"PyPI","source":"pyPI"}],"sync":{"state":"idle"}}
```

### list_pull_requests

Pull requests uit de geschiedenis, nieuwste eerst, met hun checks. Elke heeft een `reference` zoals de dienst hem schrijft: `acme/web#1` op GitHub, Bitbucket, Codeberg, Forgejo en Gitea, `group/project!42` op GitLab en `project/repo!42` op Azure DevOps. Argumenten: `repo`, `account_id`, `state` (standaard `open`, met drafts en wachtrij; of `draft`, `queued`, `merged`, `closed`, `all`), `author`, `mine` (alleen die van jou), `unread` (`true` of `false`), `checks` (`failed`, `pending` of `passed`), `limit`, `cursor`.

```jsonc
// list_pull_requests {"checks":"failed"}
// "1 pull request (open), 1 with failing checks."
{"total":1,"not_checked":[],"pull_requests":[{"repository":"acme/web","number":1,"reference":"acme/web#1","title":"Add login","author":"octo",
  "state":"open","is_mine":true,"is_read":false,"checks":{"status":"failed","failed":1,"passed":3,"pending":0,"total":4},
  "url":"https://github.com/acme/web/pull/1"}]}
```

### get_pull_request

Eén pull request: de `reference`, staat, draft, auteur en co-auteurs, aantallen checks, plaats in de merge queue, of hij uit de rij ging zonder te mergen (`left_queue`, met de reden als de dienst die geeft), gelezen of niet, datums en link. Argumenten: `repo` en `number` (allebei verplicht), `account_id`.

```jsonc
// get_pull_request {"repo":"acme/web","number":3}
// "acme/web #3 (queued): Ready to merge"
{"not_checked":[],"pull_request":{"repository":"acme/web","number":3,"reference":"acme/web#3","title":"Ready to merge","author":"ada","co_authors":[],
  "is_queued":true,"merge_queue":{"kind":"merge_queue","position":1},"checks":{"status":"passed","passed":4,"total":4},
  "url":"https://github.com/acme/web/pull/3"}}
```

### list_tags

Tags en releases, nieuwste eerst. Argumenten: `repo`, `account_id`, `unread`, `limit`, `cursor`.

```jsonc
// list_tags {"repo":"acme/web","limit":1}
// "2 tags; newest: acme/web v1.2.0."
{"total":2,"next_cursor":"1","tags":[{"repository":"acme/web","name":"v1.2.0","author":"octo","is_read":false,
  "release":{"title":"Spring release","is_prerelease":false,"url":"https://github.com/acme/web/releases/tag/v1.2.0"},
  "url":"https://github.com/acme/web/releases/tag/v1.2.0"}]}
```

### list_repositories

De repositories die je volgt, slechtste eerst, met hun staat (`problem`, `behind`, `ok` of `unknown`) en aantallen: open pull requests, nieuwste tag, kwetsbaarheden per ernst, ernstige beveiligingsmeldingen, open secrets, verouderde runtimes en package-updates. `unreachable` is `true` als het token van het account de repository niet kan lezen; de nieuwste tag kan dan oud zijn. Argumenten: `account_id`, `health`, `limit`, `cursor`.

```jsonc
// list_repositories {"limit":2}
// "3 repositories: 1 with problems, 1 unknown."
{"total":3,"next_cursor":"2","repositories":[
  {"repository":"acme/web","health":"problem","checked":true,"open_pull_requests":5,"latest_tag":"v1.2.0","vulnerabilities":1,
   "serious_security_alerts":1,"open_secrets":2,"outdated_runtimes":1,"package_updates":1,"not_checked":[]},
  {"repository":"group/app","health":"unknown","checked":true,"open_pull_requests":1,"package_updates":0,
   "not_checked":[{"message":"Not checked: source PyPI is off.","source":"pyPI"}]}]}
```

### get_repository_report

De runtimes, frameworks en packages van één repository: geïnstalleerde en nieuwste versie, wat achterloopt of end of life is, en wat elke update tegenhoudt. Een package dat een van je gevolgde repositories publiceert, heeft `in_house` (zie hieronder). Argumenten: `repo` (verplicht), `account_id`, `only_outdated`, `limit`, `cursor` (die bladeren door de packages).

```jsonc
// get_repository_report {"repo":"acme/web","only_outdated":true,"limit":1}
// "acme/web: 1 runtime (1 behind or end of life), 2 packages listed."
{"repository":"acme/web","health":"problem","checked":true,"total":2,"next_cursor":"1","not_checked":[],
 "runtimes":[{"name":"Node.js","version":"18","latest":"22","status":"end_of_life","declared_in":[".nvmrc"]}],
 "packages":[{"name":"express","ecosystem":"npm","installed":["4.19.2"],"latest":"5.1.0","requested":["^4.19.0"],
   "update":"needs_manifest_change","blocker":"express 5.1.0 needs a new major version (outside ^4.19.0)."}]}
```

### list_vulnerabilities

Bekende kwetsbaarheden in packages en de meldingen van code scanning en Advanced Security, slechtste eerst, met hun bron en oplossing. Argumenten: `repo`, `account_id`, `min_severity` (`low`, `moderate`, `high` of `critical`), `limit`, `cursor`.

```jsonc
// list_vulnerabilities {"repo":"acme/web"}
// "2 findings (1 critical, 1 high) in 1 repository."
{"total":2,"not_checked":[],"unchecked_repositories":[],"findings":[
  {"kind":"security_alert","found_by":"GitHub code scanning","severity":"critical","rule":"js/sql-injection","tool":"CodeQL",
   "summary":"Database query built from user-controlled sources","path":"src/db.js","line":12},
  {"kind":"package_vulnerability","found_by":"OSV.dev","severity":"high","id":"GHSA-qwcr-r2fm-qrc7","package":"body-parser",
   "installed":["1.20.2"],"fixed_in":"1.20.3","origin":"transitive",
   "fixes":["Update express so it pulls in body-parser 1.20.3 or newer."]}]}
```

### list_packages

De packages en container-images die je gevolgde repositories publiceren in het register van hun eigen dienst (GitHub Packages, een register van GitLab, een feed van Azure Artifacts), één per package, zoals in [Packages](/nl/using/packages/): soort, account, eigenaar, de repository die het publiceert (ontbreekt bij Azure Artifacts), de nieuwste versie en de datum, zichtbaarheid, de pagina in het register, de recente versies met hun tag en run, en `used_by`: de gevolgde repositories die ervan afhangen, met hun versies en of ze het zelf vragen. `usage_known` is `false` voor soorten die de dependency-check nog niet matcht (container-images, Helm), dus een lege `used_by` betekent daar onbekend, niet ongebruikt. `needs_permission` noemt de accounts die hun register niet mogen lezen, met de reden, en `not_checked` noemt de bron als **Packageregisters van je accounts** uit staat. Argumenten: `repo` (alleen wat die gevolgde repository publiceert), `type` (`npm`, `container`, `nuget`, `maven`, `rubygems`, `pypi`, `helm`, `generic` en meer), `account_id`, `limit`, `cursor`.

```jsonc
// list_packages {"repo":"acme/web"}
// "1 published package."
{"total":1,"not_checked":[],"needs_permission":[],"packages":[{"name":"ui","type":"npm","owner":"acme","repository":"acme/web",
  "latest_version":"2.3.0","visibility":"private","url":"https://github.com/orgs/acme/packages/npm/package/ui",
  "recent_versions":[{"version":"2.3.0","tag":"v2.3.0"},{"version":"2.2.0"}],
  "used_by":[{"repository":"acme/admin","versions":["2.2.0"],"is_direct":true}],"usage_known":true}]}
```

### explain_update

Waarom één package niet zomaar bij te werken is, per installatie: het gevraagde bereik, de stap (patch, minor of major), wat hem tegenhoudt en welke kwetsbaarheden een update oplost. Argumenten: `repo` en `package` (allebei verplicht), `ecosystem` (alleen als de naam dubbelzinnig is), `account_id`. Ook een package dat alleen via een ander package binnenkomt (elk package uit een lockfile) krijgt uitleg: `via` noemt de keten, en de uitleg zegt wat het oplossen van een kwetsbaarheid vraagt, alleen de lockfile of eerst een nieuwere ouder.

Voor een in-house package voegen deze tool en `get_repository_report` `in_house` toe: `source` (de repository die het publiceert, of het Azure DevOps-project), `repository`, `owner`, `url` (de pagina van de repository), `registry_url` (het package in je eigen register), `status` en `reason`. Met `status` `checked` komt de nieuwste versie uit je eigen register. Met `source_off`, `needs_permission`, `read_failed` (je register gaf geen nieuwste versie) of `unconfirmed` (de lockfile haalt het package uit je eigen register, maar dat register noemde het niet) is het niet gelezen: `update` is `not_checked`, `not_checked` noemt de bron of het ontbrekende recht, en `reason` zegt wat je moet toestaan. Pullwatch houdt een naam alleen privé als het kan zien dat het package van jou is; [Welke namen privé blijven](/nl/using/dependencies/#welke-namen-privé-blijven) noemt de gevallen. Zo'n naam gaat nooit naar een openbaar register, en komt alleen bij OSV.dev als een eerdere check hem ook in het openbare register vond. Waar Pullwatch het niet kan zien, bijvoorbeeld als de lockfile geen register noemt, kan de naam bij allebei komen.

```jsonc
// explain_update {"repo":"acme/web","package":"express"}
// "express 5.1.0 needs a new major version (outside ^4.19.0)."
{"package":"express","ecosystem":"npm","latest":"5.1.0","vulnerabilities":[],"not_checked":[],
 "installs":[{"version":"4.19.2","requested":"^4.19.0","declared_in":"package.json","step":"major",
   "update":"needs_manifest_change","explanation":"express 5.1.0 needs a new major version (outside ^4.19.0)."}]}
```

### get_agent_brief

Dezelfde opdracht in Markdown die **Kopieer voor een AI-agent** op het klembord zet, voor één kopje van de pagina van een repository (zie [Repositories](/nl/using/repositories/#kopieer-voor-een-ai-agent)). Argumenten: `repo` en `section` (allebei verplicht; `pull_requests`, `pull_requests_per_month`, `check`, `package_updates`, `packages` of `security`), `workspace` (voor `packages`), `account_id`.

```jsonc
// get_agent_brief {"repo":"acme/web","section":"security"}
// "Agent brief for acme/web, section security."
{"repository":"acme/web","section":"security",
 "markdown":"## Pullwatch: security on GitHub\n\nRepository: acme/web (https://github.com/acme/web)\nChecked: 2026-11-03\n\nCode scanning: 1 open alert\n..."}
```

## Wat nooit gedeeld wordt

- Tokens, sleutelhangeronderdelen en de waarden van secrets die secret scanning vond, komen nooit bij een agent; secret scanning is alleen een aantal. Accounts verschijnen als naam en host. Een serveradres met een token erin verliest dat deel, en co-auteurs verschijnen zonder hun e-mailadres. Geen tool kan om een wachtwoord of token vragen, want Pullwatch geeft de tools er geen.
- Een repository die je niet volgt, bestaat niet voor een agent. Een vraag erover krijgt "Repository … is not followed in Pullwatch."
- Heb je een bron uitgezet onder Instellingen, **Bronnen**, dan zegt het antwoord "Not checked: source … is off." voor wat die bron zou hebben beantwoord. Het wordt nooit als actueel of vrij van kwetsbaarheden gemeld. Zie [Privacy en bronnen](/nl/privacy/).
- De tools lezen alleen. Acties zoals markeren als gelezen komen misschien later, achter een aparte schakelaar die standaard uit staat, en ook die schrijven nooit naar GitHub, Azure DevOps, GitLab, Bitbucket, Codeberg, Forgejo of Gitea.

## Privacy

Wat een agent in Pullwatch leest, gaat naar de aanbieder van zijn model, net als al het andere dat je hem laat zien: titels van pull requests, namen van repositories, versies van packages, kwetsbaarheden. Instellingen, **Agents** zegt dat onder de keuze. Pullwatch zelf stuurt hiervoor niets weg: de agent en Pullwatch praten via een verbinding op je Mac die alleen jouw gebruikersaccount en de eigen helper van Pullwatch kunnen gebruiken.

Wil je stoppen, kies dan **Nooit**. Pullwatch sluit dan de verbinding, en agents krijgen geen gegevens tot je opnieuw kiest. Je kunt de server ook uit de agent halen (`claude mcp remove pullwatch`, `codex mcp remove pullwatch`, of het item in de JSON).

## Problemen oplossen

Begin met de lijst van servers van je agent, voor Claude Code:

```sh
claude mcp list
```

`pullwatch` hoort daar als verbonden te staan. Ontbreekt hij, voeg hem dan opnieuw toe met `--scope user`, zodat hij niet aan één map vastzit. Mislukt hij, kijk dan of de helper staat waar de opdracht naar wijst: `ls -l /Applications/Pullwatch.app/Contents/Helpers/pullwatch-mcp`.

De agent toont het antwoord van Pullwatch letterlijk, in het Engels. Elk antwoord, en wat je doet:

### Agents staan uit

```text
Agents are turned off in Pullwatch: Settings, Agents
```

De keuze in Instellingen, **Agents** is **Nooit**. Kies **Zolang Pullwatch open is** of **Altijd**.

### Pullwatch is niet open

```text
Open Pullwatch to use it from an agent.
```

De keuze is **Zolang Pullwatch open is** en Pullwatch draait niet. Open het, of kies **Altijd**.

### Pullwatch startte niet op tijd

```text
Pullwatch did not start in time. Open Pullwatch to use it from an agent.
```

De keuze is **Altijd**, maar Pullwatch was niet binnen 25 seconden klaar. Open het zelf. Opent het niet vanaf het pad in de instelling van je agent, dan heb je de app verplaatst: stel de agent opnieuw in.

### Wacht op toestemming

```text
Waiting for approval in Pullwatch: allow Claude Code in the notification or under Settings, Agents.
```

Klik op **Sta toe** in de melding, in Instellingen, **Agents** onder **Toegestane agents**, of achter de agentsknop in het menupaneel. Vraag het daarna opnieuw; de agent hoeft niet opnieuw te verbinden. Geen melding gezien? Dan staan meldingen voor Pullwatch uit in Systeeminstellingen; sta de agent dan toe in Instellingen.

### Losgekoppeld

```text
Pullwatch disconnected this agent. Reconnect the agent to Pullwatch (restart its MCP server) to use it again.
```

Je klikte op **Loskoppelen** of **Sta niet toe**. Start de agent, of zijn MCP-server (in Claude Code `/mcp`), opnieuw om weer te verbinden.

### Verbinding gesloten tijdens een antwoord

```text
Pullwatch closed the connection while answering. Try again.
```

Pullwatch startte opnieuw terwijl het antwoordde, bijvoorbeeld voor een update. Vraag het opnieuw: de helper verbindt zelf één keer opnieuw.

### Protocolversies

Pullwatch spreekt MCP 2025-11-25, 2025-06-18, 2025-03-26 en 2024-11-05. Een agent die een nieuwere versie vraagt, krijgt 2025-11-25, en die accepteren de huidige versies van Claude Code, Codex, Cursor en VS Code. Weigert een agent die, werk dan Pullwatch en de agent bij.
