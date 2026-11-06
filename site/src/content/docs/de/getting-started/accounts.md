---
title: Konten hinzufügen
description: GitHub, GitHub Enterprise, Azure DevOps, GitLab, Bitbucket, Codeberg, Forgejo und Gitea verbinden und wählen, welchen Repositories Pullwatch folgt.
---

Öffne **Einstellungen** (die Zahnrad-Schaltfläche im Menü) und geh zu **Konten**. Füge mit **+** ein Konto hinzu, wähle, wie Pullwatch sich anmeldet, und prüfe es mit **Verbindung testen**. Du kannst beliebig viele Konten jeder Art hinzufügen.

Pullwatch liest nur. Es kommentiert, merged und ändert nie etwas auf deinen Servern.

## GitHub

Auf github.com kannst du dich auf drei Arten anmelden:

- **Mit GitHub anmelden.** Pullwatch zeigt einen Code, du bestätigst ihn auf github.com, und die GitHub App von Pullwatch bekommt Lesezugriff auf die Repositories, die du bei ihrer Installation auswählst. Die App fragt nur nach Leseberechtigungen.
- **Personal Access Token.** Füge ein Token ein, das du selbst erstellt hast. Die Scopes stehen unter [Token-Berechtigungen](/de/getting-started/permissions/).
- **GitHub CLI.** Nutzt du `gh` (`gh auth login`), fragt Pullwatch dort nach einem Token. Hast du mehrere Konten in `gh`, wähle unter **GitHub-Konto** das gewünschte.

## GitHub Enterprise

Wähle **GitHub Enterprise** auf der GitHub-Karte (oder im Menü **+**) und gib deinen Server unter **Server** ein:

- einen GitHub Enterprise Server, etwa `https://github.example.com`, oder
- die Subdomain deines Unternehmens auf GHE.com, etwa `https://acme.ghe.com`.

Nur https funktioniert, damit ein Token nie unverschlüsselt übertragen wird. Pullwatch findet die API selbst und verlinkt auf Pull Requests, Tags und Repositories auf diesem Server. Melde dich mit einem Personal Access Token an, das auf diesem Server erstellt wurde, oder mit der GitHub CLI nach `gh auth login --hostname <server>`. **Mit GitHub anmelden** gilt nur für github.com.

Was ein Server nicht hat, erscheint als **Auf diesem Server nicht verfügbar** statt als Fehler, etwa die eigenen Sicherheits-Advisories eines Repositorys auf GitHub Enterprise Server.

## Azure DevOps

Gib deine Organisation ein und melde dich mit einem Personal Access Token oder mit der Azure CLI (`az login`) an. Pullwatch liest die Projekte der Organisation und ihre Repositories.

## GitLab

Lass **Server** für gitlab.com leer, oder gib deinen eigenen Server ein (nur https, zum Beispiel `https://gitlab.example.com`). Trage die Gruppen oder Benutzer ein, denen du folgen willst, durch Kommas getrennt, etwa `acme, acme/platform`. Eine Gruppe umfasst ihre Untergruppen, und Repositories erscheinen als `group/subgroup/project`.

Melde dich mit einem Personal Access Token mit dem Scope `read_api` an, oder mit der GitLab CLI (`glab auth login`). **Token erstellen** im Kontoeditor öffnet die Token-Seite deines Servers mit ausgefülltem Namen und Scope.

## Bitbucket

Wähle **Bitbucket** auf seiner Karte im Willkommensfenster oder **Bitbucket Cloud** im Menü **+**. Das ist Bitbucket Cloud auf bitbucket.org; Bitbucket Data Center wird nicht unterstützt. Trage die Workspaces, denen du folgen willst, unter **Workspaces** ein, durch Kommas getrennt, etwa `acme, acme-labs`. Der Workspace ist der erste Teil eines Links, `bitbucket.org/<workspace>/<repo>`, und Repositories erscheinen als `workspace/repo`.

Melde dich mit einem API-Token mit Scopes von Atlassian und der E-Mail-Adresse deines Atlassian-Kontos unter **E-Mail-Adresse** an. **Token erstellen** öffnet die Seite mit den API-Tokens deines Atlassian-Kontos: Wähle **Create API token with scopes**, dann **Bitbucket** und die Leserechte aus [Token-Berechtigungen](/de/getting-started/permissions/). App-Passwörter funktionieren nicht mehr, und es gibt kein Kommandozeilenwerkzeug von Bitbucket, aus dem Pullwatch ein Token holen könnte. Die E-Mail-Adresse steht in den Einstellungen, das Token im Schlüsselbund.

Bitbucket kennt keine Releases, deshalb zeigt **Tags und Releases** bei einem Bitbucket-Konto nur Tags. Die Checks eines Pull Requests sind die Build-Status auf seinem letzten Commit, von Bitbucket Pipelines oder anderer CI, die sie meldet. Bitbucket hat keine Liste aller Pull Requests eines Workspace, deshalb fragt Pullwatch jedes Repository einzeln; ein Repository, das sich seit der letzten Abfrage nicht geändert hat, wird spätestens nach 10 Minuten erneut gefragt.

## Codeberg, Forgejo und Gitea

Codeberg, Forgejo und Gitea teilen sich eine Karte, weil sie dieselbe API sprechen. Wähle die Taste deines Dienstes:

- Codeberg: ein Konto auf codeberg.org.
- Forgejo: dein eigener Forgejo-Server. Gib ihn unter **Server** ein (nur https, zum Beispiel `https://git.example.com`).
- Gitea: lass **Server** leer für gitea.com, oder gib deinen eigenen Gitea-Server ein.

Trage die Organisationen oder Benutzer, denen du folgen willst, unter **Organisationen oder Benutzer** ein, durch Kommas getrennt, etwa `acme` und `jdoe`. Repositories erscheinen als `owner/repo`.

Melde dich mit einem Token an, das du auf diesem Server unter Einstellungen, Anwendungen erstellst, mit den Scopes `read:user`, `read:organization`, `read:repository` und `read:issue` ([Token-Berechtigungen](/de/getting-started/permissions/) sagt warum). **Token erstellen** öffnet diese Seite. Eine Anmeldung über das Kommandozeilenwerkzeug `tea` gibt es nicht: `tea` hat keinen Befehl, der sein Token herausgibt.

**Verbindung testen** sagt, was nicht stimmt: ein ungültiges Token, ein Scope, der dem Token fehlt (mit Namen), eine Organisation oder ein Benutzer, die es nicht gibt, eine Adresse, unter der kein Gitea oder Forgejo antwortet, oder ein Zertifikat, dem macOS nicht vertraut. Pullwatch spricht nur über https mit Servern mit einem gültigen Zertifikat, ein selbst signiertes Zertifikat funktioniert also nur, wenn macOS ihm vertraut.

Pull Requests kommen mit einer Anfrage pro Organisation oder Benutzer, egal wie viele Repositories es gibt. Drafts erkennt Pullwatch am Draft-Kennzeichen und auf einem älteren Gitea an einem Titel, der mit `WIP:` oder `[WIP]` beginnt. Die Checks eines Pull Requests sind die Commit-Statuses auf seinem letzten Commit, etwa von Forgejo Actions, Gitea Actions oder Woodpecker. Tags kommen mit ihren Releases, auch Pre-Releases.

## Wählen, was du verfolgst

Jedes Konto listet seine Repositories. Hake pro Repository an, was du möchtest:

- **PRs**: neue Pull Requests (oder Merge Requests).
- **Tags**: neue Tags und bei GitHub, GitLab, Codeberg, Forgejo und Gitea die Releases dazu. Tags sind standardmäßig aus.
- **Gemergt**: Pull Requests, die gemergt werden.

Neben jedem Haken ist eine Glocke. Schalte sie aus, um ein Repository ohne Mitteilungen im Menü und im Verlauf zu behalten. Die Glocke in der Kopfzeile schaltet alle sichtbaren Repositories auf einmal. Entwurfs-Pull-Requests stehen mit dem Entwurfssymbol im Menü und im Verlauf, wie auf GitHub. Pro Konto schaltest du das mit **Entwurfs-PRs anzeigen** aus: Entwürfe erscheinen dann nirgends, und ein Pull Request kommt an, sobald er bereit zum Review ist. Mit **Bei Entwurfs-PRs mitteilen** gibt ein neuer Entwurf auch eine Mitteilung. Du kannst außerdem deine eigenen Pull Requests ausblenden und das ganze Konto eine Weile ausschalten.

## Repositories außerhalb deines Kontos

Unter **Andere Repositorys** unten in der Liste fügst du ein einzelnes Repository hinzu, das nicht zu den Ownern oder Gruppen des Kontos gehört:

- GitHub: `owner/repo`, oder füge einen Link von github.com ein.
- Azure DevOps: `project/repo` innerhalb der Organisation des Kontos, oder ein Link von dev.azure.com.
- GitLab: `group/subgroup/project`, oder ein Link von gitlab.com oder vom eigenen Server des Kontos.
- Bitbucket: `workspace/repo`, oder füge einen Link von bitbucket.org ein.
- Codeberg, Forgejo und Gitea: `owner/repo`, oder ein Link vom Server des Kontos.

Pullwatch prüft es mit einer Anfrage und sagt dir in klaren Worten, wenn es das Repository nicht finden oder lesen kann. Ein öffentliches Repository auf github.com, gitlab.com oder bitbucket.org, das dein Token nicht lesen darf, wird ohne Anmeldung gelesen. **Einem Repository folgen…** (⇧⌘N, im Menü Ablage und in der Symbolleiste von Repositories) öffnet dasselbe Feld mit einer Auswahl des Kontos. Entferne eines per Rechtsklick oder mit der Entfernen-Taste.

Ein solches Repository erscheint überall wie die anderen, denen du folgst, gruppiert unter seinem eigenen Owner.

- **GitHub**: Das funktioniert auch für ein öffentliches Repository einer anderen Organisation, in der die GitHub App von Pullwatch nicht installiert ist, etwa `openEHR/specifications-AM`. Die Pull Requests dieser Repositories kommen mit einer Suche pro Konto, mit bis zu 30 Repositories pro Suche.
- **GitLab**: Links von gitlab.com oder vom eigenen Server des Kontos funktionieren, auch Links mit `/-/` wie `/-/merge_requests/12`. Ein Link zu einem anderen Server wird abgelehnt. Ein öffentliches Projekt wird nur dann ohne Anmeldung gelesen, wenn der Server ohne Token antwortet: gitlab.com tut das, ein Server, der eine Anmeldung verlangt, nicht, und dann wird das Projekt nicht gefunden. Jedes solche Projekt kostet pro Abfrage eine Anfrage für seine Merge Requests (eine Seite, die 100 zuletzt aktualisierten).
- **Codeberg, Forgejo und Gitea**: ein Link muss auf dem Server des Kontos liegen. Ein öffentliches Repository wird ohne Anmeldung gelesen, wenn der Server das erlaubt, wie codeberg.org und gitea.com. Jedes solche Repository kostet pro Abfrage eine Anfrage für seine Pull Requests (eine Seite, die 50 zuletzt aktualisierten).

## Wie oft Pullwatch nachsieht

Unter Einstellungen, Allgemein legst du fest, wie oft Pullwatch nach neuen Pull Requests sucht und wie lange der Verlauf aufbewahrt wird (2 Monate, 6 Monate, 1 Jahr oder Immer). Tags werden alle 15 Minuten geprüft. **Jetzt aktualisieren** im Menü prüft sofort.
