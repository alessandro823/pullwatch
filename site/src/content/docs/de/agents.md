---
title: Agenten (MCP)
description: Lass einen Coding-Agenten wie Claude Code, Codex, Cursor oder VS Code Pullwatch über MCP nach deinen Pull Requests, Repositories und Schwachstellen fragen.
---

Pullwatch hat einen lokalen [Model Context Protocol](https://modelcontextprotocol.io)-Server. Ein Coding-Agent auf deinem Mac kann Pullwatch also fragen, was es weiß: „Welche meiner Pull Requests haben fehlgeschlagene Checks?“, „Was ist in `acme/web` kritisch?“, „Warum kann ich `express` nicht aktualisieren?“, „Wer ist noch auf einem alten `@acme/ui`?“. Der Agent nutzt, was Pullwatch mit deinen Konten bereits abgerufen hat, und braucht deshalb kein eigenes Token.

Agenten lesen nur. Sie sehen nur die Repositories, denen du folgst, bekommen nie ein Token und können auf GitHub, Azure DevOps, GitLab, Bitbucket, Codeberg, Forgejo oder Gitea nichts ändern. Nichts wird geteilt, bevor du es einschaltest.

## Einschalten

Öffne Einstellungen, **Agenten** und wähle bei **Agenten erlauben, Pullwatch zu verwenden**:

- **Nie** (Standard): Agenten bekommen keine Daten. Ein Agent, der es versucht, erfährt, dass Agenten ausgeschaltet sind.
- **Solange Pullwatch geöffnet ist**: Agenten können fragen, solange Pullwatch läuft. Läuft es nicht, erfährt der Agent, dass er Pullwatch öffnen soll.
- **Immer**: Läuft Pullwatch nicht, startet es im Hintergrund (ohne Fenster, es bleibt in der Menüleiste), sobald ein Agent fragt, und antwortet.

Das sind dieselben Möglichkeiten, die Xcode für externe Agenten bietet.

## Agenten einrichten

Wähle unter **Agenten einrichten** deinen Agenten. Pullwatch zeigt den Befehl oder das JSON mit dem Pfad des Pullwatch, das du gerade verwendest, und **Kopieren** legt es in die Zwischenablage. Für Pullwatch in Programme sieht es so aus. Wenn du die App verschiebst, richte den Agenten erneut ein.

### Claude Code

Im Terminal ausführen:

```sh
claude mcp add --scope user --transport stdio pullwatch -- /Applications/Pullwatch.app/Contents/Helpers/pullwatch-mcp
```

Mit `--scope user` funktioniert Pullwatch in jedem Projekt. Ohne gilt es nur im Ordner, in dem du den Befehl ausgeführt hast.

### Codex

Im Terminal ausführen:

```sh
codex mcp add pullwatch -- /Applications/Pullwatch.app/Contents/Helpers/pullwatch-mcp
```

Codex schreibt das in seine globale Konfiguration, `~/.codex/config.toml`, und damit gilt es in jedem Projekt.

### Cursor

In `~/.cursor/mcp.json` eintragen:

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

In `.vscode/mcp.json` deines Projekts eintragen:

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

### Andere Agenten

Jeder MCP-Client, der einen Server über stdio startet, funktioniert: Gib ihm `/Applications/Pullwatch.app/Contents/Helpers/pullwatch-mcp` als Befehl, ohne Argumente.

## Den Agenten einmal erlauben

Wenn sich ein Agent zum ersten Mal verbindet, fragt Pullwatch dich mit einer Mitteilung, zum Beispiel „Claude Code möchte Pullwatch verwenden“, mit **Erlauben** und **Nicht erlauben**. Ein Klick auf die Mitteilung selbst öffnet Einstellungen, **Agenten**. Bis du es erlaubst, bleibt der Agent verbunden, bekommt aber keine Daten: Jede Frage bekommt als Antwort, dass er auf Erlaubnis wartet. Erlaubst du ihn, funktioniert seine nächste Frage.

Du erlaubst einen Agenten einmal; Pullwatch fragt nicht bei jeder Frage erneut. Jedes Tool liest nur, was Pullwatch dir ohnehin zeigt. Eine Rückfrage bei jedem Aufruf würde dich vor allem daran gewöhnen, auf **Erlauben** zu klicken. Eine bewusste Entscheidung pro Agent, die du jederzeit zurücknehmen kannst, schützt dich besser.

- **Erlaubte Agenten** in Einstellungen, **Agenten** zeigt die Agenten, die du erlaubt hast, und den Agenten, der wartet, mit **Nicht erlauben** und **Erlauben**. Die Entfernen-Taste neben einem Agenten nimmt ihn von der Liste; Pullwatch fragt dann bei seiner nächsten Verbindung erneut.
- **Nicht erlauben** schließt jede Verbindung dieses Agenten und merkt sich nichts. Der Agent verbindet sich nicht von selbst neu: Starte ihn oder seinen MCP-Server neu, um erneut zu fragen.
- Pullwatch erkennt einen Agenten an dem Namen, den er meldet (Claude Code, Codex, Cursor, VS Code oder sein eigener Name). Du siehst diesen Namen, damit du weißt, wer fragt; ein Passwort ist er nicht.

## Sehen, welche Agenten verbunden sind

**Verbundene Agenten** in Einstellungen, **Agenten** zeigt jeden Agenten, der gerade verbunden ist: Name und Version (**Verbinden…**, bis er sagt, wer er ist), seit wann, das zuletzt verwendete Tool und wann, und **Wartet auf Erlaubnis**, solange er wartet. **Trennen** schließt seine Verbindung; wie nach **Nicht erlauben** bleibt der Agent dann weg, bis du ihn neu startest.

Solange mindestens ein Agent verbunden ist, zeigt der Kopf des [Menüs](/de/using/menu/) eine Agenten-Taste mit der Zahl der Agenten. Ein orangefarbener Punkt darauf heißt, dass ein Agent auf Erlaubnis wartet. Klicke darauf für dieselbe Liste, mit **Trennen** für jeden Agenten, **Nicht erlauben** und **Erlauben** für einen, der wartet, und **Agenten-Einstellungen…**, um Einstellungen, **Agenten** zu öffnen.

## Die Tools

Der Agent entscheidet selbst, welches Tool er aufruft; du stellst nur deine Frage. Jedes Tool liest, was Pullwatch bereits abgerufen hat; keines macht einen Netzwerkaufruf oder startet eine Abfrage. Die Antworten sind auf Englisch: JSON mit einer Zusammenfassung in einer Zeile.

Listen liefern standardmäßig 25 Einträge. Mit `limit` (höchstens 100) und `cursor` blätterst du weiter; die Antwort hat `total` und, wenn es mehr gibt, `next_cursor`. Wo ein Tool `repo` erwartet, ist das `besitzer/name` (`projekt/repo` auf Azure DevOps); `account_id` (aus `get_status`) brauchst du nur, wenn zwei Konten einem Repository mit demselben Namen folgen.

Die Beispiele unten stammen aus den Testdaten von Pullwatch. Die Antworten sind gekürzt.

### get_status

Die Konten (ID, Dienst, Name und Host), wie ihre letzte Abfrage lief, was gerade synchronisiert wird, wann die Versionsprüfung war, welche Quellen aus sind, und die Zahl der ungelesenen Einträge. Ein Konto nennt in `unreachable_repositories` die gefolgten Repositories, die sein Token nicht lesen kann: Ihre Tags und Branches werden nicht aktualisiert. Keine Argumente.

```jsonc
// get_status {}
// "2 accounts (1 failing), 3 followed repositories; sources off: PyPI."
{"accounts":[{"host":"github.com","name":"@octo","service":"GitHub","state":"ok","last_poll":"2026-11-04T09:00:00Z"},
  {"host":"gitlab.example.com","name":"group","service":"GitLab","state":"failed","error":"Token invalid or expired"}],
 "followed_repositories":3,"unread_pull_requests":6,"unread_tags":2,
 "sources_off":[{"message":"Not checked: source PyPI is off.","name":"PyPI","source":"pyPI"}],"sync":{"state":"idle"}}
```

### list_pull_requests

Pull Requests aus dem Verlauf, neueste zuerst, mit ihren Checks. Jeder hat eine `reference` in der Schreibweise seines Dienstes: `acme/web#1` auf GitHub, Bitbucket, Codeberg, Forgejo und Gitea, `group/project!42` auf GitLab und `project/repo!42` auf Azure DevOps. Argumente: `repo`, `account_id`, `state` (standardmäßig `open`, mit Entwürfen und Warteschlange; oder `draft`, `queued`, `merged`, `closed`, `all`), `author`, `mine` (nur deine), `unread` (`true` oder `false`), `checks` (`failed`, `pending` oder `passed`), `limit`, `cursor`.

```jsonc
// list_pull_requests {"checks":"failed"}
// "1 pull request (open), 1 with failing checks."
{"total":1,"not_checked":[],"pull_requests":[{"repository":"acme/web","number":1,"reference":"acme/web#1","title":"Add login","author":"octo",
  "state":"open","is_mine":true,"is_read":false,"checks":{"status":"failed","failed":1,"passed":3,"pending":0,"total":4},
  "url":"https://github.com/acme/web/pull/1"}]}
```

### get_pull_request

Ein Pull Request: seine `reference`, Status, Entwurf, Autor und Co-Autoren, Zahl der Checks, Platz in der Merge-Queue, ob er die Warteschlange ohne Merge verlassen hat (`left_queue`, mit dem Grund, wenn der Dienst einen nennt), gelesen oder nicht, Daten und Link. Argumente: `repo` und `number` (beide erforderlich), `account_id`.

```jsonc
// get_pull_request {"repo":"acme/web","number":3}
// "acme/web #3 (queued): Ready to merge"
{"not_checked":[],"pull_request":{"repository":"acme/web","number":3,"reference":"acme/web#3","title":"Ready to merge","author":"ada","co_authors":[],
  "is_queued":true,"merge_queue":{"kind":"merge_queue","position":1},"checks":{"status":"passed","passed":4,"total":4},
  "url":"https://github.com/acme/web/pull/3"}}
```

### list_tags

Tags und Releases, neueste zuerst. Argumente: `repo`, `account_id`, `unread`, `limit`, `cursor`.

```jsonc
// list_tags {"repo":"acme/web","limit":1}
// "2 tags; newest: acme/web v1.2.0."
{"total":2,"next_cursor":"1","tags":[{"repository":"acme/web","name":"v1.2.0","author":"octo","is_read":false,
  "release":{"title":"Spring release","is_prerelease":false,"url":"https://github.com/acme/web/releases/tag/v1.2.0"},
  "url":"https://github.com/acme/web/releases/tag/v1.2.0"}]}
```

### list_repositories

Die Repositories, denen du folgst, schlechteste zuerst, mit ihrem Zustand (`problem`, `behind`, `ok` oder `unknown`) und Zahlen: offene Pull Requests, neuester Tag, Schwachstellen nach Schweregrad, ernste Sicherheitswarnungen, offene Secrets, veraltete Runtimes und Paket-Updates. `unreachable` ist `true`, wenn das Token des Kontos das Repository nicht lesen kann; der neueste Tag kann dann alt sein. Argumente: `account_id`, `health`, `limit`, `cursor`.

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

Die Runtimes, Frameworks und Pakete eines Repositorys: installierte und neueste Version, was zurückliegt oder sein Lebensende erreicht hat, und was jedes Update aufhält. Ein Paket, das eines der Repositories, denen du folgst, veröffentlicht, hat `in_house` (siehe unten). Argumente: `repo` (erforderlich), `account_id`, `only_outdated`, `limit`, `cursor` (sie blättern durch die Pakete).

```jsonc
// get_repository_report {"repo":"acme/web","only_outdated":true,"limit":1}
// "acme/web: 1 runtime (1 behind or end of life), 2 packages listed."
{"repository":"acme/web","health":"problem","checked":true,"total":2,"next_cursor":"1","not_checked":[],
 "runtimes":[{"name":"Node.js","version":"18","latest":"22","status":"end_of_life","declared_in":[".nvmrc"]}],
 "packages":[{"name":"express","ecosystem":"npm","installed":["4.19.2"],"latest":"5.1.0","requested":["^4.19.0"],
   "update":"needs_manifest_change","blocker":"express 5.1.0 needs a new major version (outside ^4.19.0)."}]}
```

### list_vulnerabilities

Bekannte Schwachstellen in Paketen und die Warnungen von Code-Scanning und Advanced Security, schlechteste zuerst, mit Quelle und Behebung. Argumente: `repo`, `account_id`, `min_severity` (`low`, `moderate`, `high` oder `critical`), `limit`, `cursor`.

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

Die Pakete und Container-Images, die die Repositories, denen du folgst, in der Registry ihres eigenen Dienstes veröffentlichen (GitHub Packages, eine Registry von GitLab, ein Feed von Azure Artifacts), eines pro Paket, wie in [Pakete](/de/using/packages/): Typ, Konto, Owner, das veröffentlichende Repository (fehlt bei Azure Artifacts), die neueste Version und ihr Datum, Sichtbarkeit, die Seite in der Registry, die letzten Versionen mit ihrem Tag und Run, und `used_by`: die Repositories, denen du folgst und die davon abhängen, mit ihren Versionen und ob sie es selbst verlangen. `usage_known` ist `false` für Typen, die die Prüfung der Abhängigkeiten noch nicht abgleicht (Container-Images, Helm); ein leeres `used_by` heißt dort also unbekannt und nie ungenutzt. `needs_permission` listet die Konten, die ihre Registry nicht lesen dürfen, mit dem Grund, und `not_checked` nennt die Quelle, wenn **Paket-Registrys deiner Konten** aus ist. Argumente: `repo` (nur was dieses Repository veröffentlicht), `type` (`npm`, `container`, `nuget`, `maven`, `rubygems`, `pypi`, `helm`, `generic` und mehr), `account_id`, `limit`, `cursor`.

```jsonc
// list_packages {"repo":"acme/web"}
// "1 published package."
{"total":1,"not_checked":[],"needs_permission":[],"packages":[{"name":"ui","type":"npm","owner":"acme","repository":"acme/web",
  "latest_version":"2.3.0","visibility":"private","url":"https://github.com/orgs/acme/packages/npm/package/ui",
  "recent_versions":[{"version":"2.3.0","tag":"v2.3.0"},{"version":"2.2.0"}],
  "used_by":[{"repository":"acme/admin","versions":["2.2.0"],"is_direct":true}],"usage_known":true}]}
```

### explain_update

Warum sich ein Paket nicht einfach aktualisieren lässt, pro Installation: der verlangte Bereich, der Schritt (Patch, Minor oder Major), was ihn aufhält und welche Schwachstellen ein Update behebt. Argumente: `repo` und `package` (beide erforderlich), `ecosystem` (nur wenn der Name mehrdeutig ist), `account_id`. Auch ein Paket, das nur über ein anderes Paket hereinkommt (jedes Paket aus einer Lockfile), wird erklärt: `via` nennt die Kette, und die Erklärung sagt, was das Beheben einer Schwachstelle verlangt, nur die Lockfile oder zuerst ein neueres Elternpaket.

Für ein hauseigenes Paket fügen dieses Tool und `get_repository_report` beide `in_house` hinzu: `source` (das veröffentlichende Repository oder das Projekt in Azure DevOps), `repository`, `owner`, `url` (die Seite des Repositorys), `registry_url` (das Paket in deiner eigenen Registry), `status` und `reason`. Mit `status` `checked` kommt die neueste Version aus deiner eigenen Registry. Mit `source_off`, `needs_permission`, `read_failed` (deine Registry lieferte keine neueste Version) oder `unconfirmed` (die Lockfile holt das Paket aus deiner eigenen Registry, aber diese Registry nannte es nicht) wurde sie nicht gelesen: `update` ist `not_checked`, `not_checked` nennt die Quelle oder die fehlende Berechtigung, und `reason` sagt, was du freigeben musst. Pullwatch hält einen Namen nur privat, wenn es erkennen kann, dass das Paket deins ist; [Welche Namen privat bleiben](/de/using/dependencies/#welche-namen-privat-bleiben) nennt die Fälle. Ein solcher Name geht nie an eine öffentliche Registry und erreicht OSV.dev nur, wenn eine frühere Prüfung ihn auch in der öffentlichen Registry gefunden hat. Wo Pullwatch es nicht erkennen kann, zum Beispiel wenn die Lockfile keine Registry nennt, kann der Name beide erreichen.

```jsonc
// explain_update {"repo":"acme/web","package":"express"}
// "express 5.1.0 needs a new major version (outside ^4.19.0)."
{"package":"express","ecosystem":"npm","latest":"5.1.0","vulnerabilities":[],"not_checked":[],
 "installs":[{"version":"4.19.2","requested":"^4.19.0","declared_in":"package.json","step":"major",
   "update":"needs_manifest_change","explanation":"express 5.1.0 needs a new major version (outside ^4.19.0)."}]}
```

### get_agent_brief

Derselbe Auftrag in Markdown, den **Für einen KI-Agenten kopieren** für einen Abschnitt der Seite eines Repositorys in die Zwischenablage legt (siehe [Repositories](/de/using/repositories/#für-einen-ki-agenten-kopieren)). Argumente: `repo` und `section` (beide erforderlich; `pull_requests`, `pull_requests_per_month`, `check`, `package_updates`, `packages` oder `security`), `workspace` (für `packages`), `account_id`.

```jsonc
// get_agent_brief {"repo":"acme/web","section":"security"}
// "Agent brief for acme/web, section security."
{"repository":"acme/web","section":"security",
 "markdown":"## Pullwatch: security on GitHub\n\nRepository: acme/web (https://github.com/acme/web)\nChecked: 2026-11-03\n\nCode scanning: 1 open alert\n..."}
```

## Was nie geteilt wird

- Tokens, Einträge im Schlüsselbund und die Werte von Secrets, die Secret-Scanning gefunden hat, erreichen nie einen Agenten; Secret-Scanning ist nur eine Zahl. Konten erscheinen als Name und Host. Eine Serveradresse mit einem Token darin verliert diesen Teil, und Co-Autoren erscheinen ohne ihre E-Mail-Adresse. Kein Tool kann nach Zugangsdaten fragen, denn Pullwatch gibt den Tools keine.
- Ein Repository, dem du nicht folgst, gibt es für einen Agenten nicht. Eine Frage danach bekommt „Repository … is not followed in Pullwatch.“
- Hast du unter Einstellungen, **Quellen** eine Quelle ausgeschaltet, sagt die Antwort „Not checked: source … is off.“ für das, was diese Quelle beantwortet hätte. Es wird nie als aktuell oder frei von Schwachstellen gemeldet. Siehe [Datenschutz und Quellen](/de/privacy/).
- Die Tools lesen nur. Aktionen wie „als gelesen markieren“ kommen vielleicht später, hinter einem eigenen Schalter, der standardmäßig aus ist, und auch sie schreiben nie zu GitHub, Azure DevOps, GitLab, Bitbucket, Codeberg, Forgejo oder Gitea.

## Datenschutz

Was ein Agent in Pullwatch liest, geht an den Anbieter seines Modells, wie alles andere, was du ihm zeigst: Titel von Pull Requests, Namen von Repositories, Paketversionen, Schwachstellen. Einstellungen, **Agenten** sagt das unter der Auswahl. Pullwatch selbst sendet dafür nichts irgendwohin: Agent und Pullwatch sprechen über eine Verbindung auf deinem Mac, die nur dein Benutzerkonto und der eigene Helfer von Pullwatch nutzen können.

Zum Aufhören wähle **Nie**. Pullwatch schließt dann die Verbindung, und Agenten bekommen keine Daten, bis du erneut wählst. Du kannst den Server auch aus dem Agenten entfernen (`claude mcp remove pullwatch`, `codex mcp remove pullwatch` oder den Eintrag im JSON).

## Fehlerbehebung

Beginne mit der Serverliste deines Agenten, für Claude Code:

```sh
claude mcp list
```

`pullwatch` sollte dort als verbunden stehen. Fehlt es, füge es erneut mit `--scope user` hinzu, damit es nicht an einen Ordner gebunden ist. Schlägt es fehl, prüfe, ob der Helfer dort liegt, wohin der Befehl zeigt: `ls -l /Applications/Pullwatch.app/Contents/Helpers/pullwatch-mcp`.

Der Agent zeigt die Antwort von Pullwatch wörtlich, auf Englisch. Jede Antwort, und was du tust:

### Agenten sind ausgeschaltet

```text
Agents are turned off in Pullwatch: Settings, Agents
```

Die Auswahl in Einstellungen, **Agenten** ist **Nie**. Wähle **Solange Pullwatch geöffnet ist** oder **Immer**.

### Pullwatch ist nicht geöffnet

```text
Open Pullwatch to use it from an agent.
```

Die Auswahl ist **Solange Pullwatch geöffnet ist**, und Pullwatch läuft nicht. Öffne es, oder wähle **Immer**.

### Pullwatch ist nicht rechtzeitig gestartet

```text
Pullwatch did not start in time. Open Pullwatch to use it from an agent.
```

Die Auswahl ist **Immer**, aber Pullwatch war nicht innerhalb von 25 Sekunden bereit. Öffne es selbst. Öffnet es sich nicht über den Pfad in der Einrichtung deines Agenten, hast du die App verschoben: Richte den Agenten erneut ein.

### Wartet auf Erlaubnis

```text
Waiting for approval in Pullwatch: allow Claude Code in the notification or under Settings, Agents.
```

Klicke auf **Erlauben** in der Mitteilung, in Einstellungen, **Agenten** unter **Erlaubte Agenten** oder hinter der Agenten-Taste im Menü. Frage danach erneut; der Agent muss sich nicht neu verbinden. Keine Mitteilung gesehen? Dann sind Mitteilungen für Pullwatch in den Systemeinstellungen aus; erlaube den Agenten dann in den Einstellungen.

### Getrennt

```text
Pullwatch disconnected this agent. Reconnect the agent to Pullwatch (restart its MCP server) to use it again.
```

Du hast auf **Trennen** oder **Nicht erlauben** geklickt. Starte den Agenten oder seinen MCP-Server neu (in Claude Code `/mcp`), um dich wieder zu verbinden.

### Verbindung während einer Antwort geschlossen

```text
Pullwatch closed the connection while answering. Try again.
```

Pullwatch wurde während der Antwort neu gestartet, zum Beispiel für ein Update. Frage erneut: Der Helfer verbindet sich einmal von selbst neu.

### Protokollversionen

Pullwatch spricht MCP 2025-11-25, 2025-06-18, 2025-03-26 und 2024-11-05. Ein Agent, der eine neuere Version verlangt, bekommt 2025-11-25, und die akzeptieren die aktuellen Versionen von Claude Code, Codex, Cursor und VS Code. Lehnt ein Agent sie ab, aktualisiere Pullwatch und den Agenten.
