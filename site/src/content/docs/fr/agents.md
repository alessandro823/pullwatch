---
title: Agents (MCP)
description: "Laissez un agent de code comme Claude Code, Codex, Cursor ou VS Code interroger Pullwatch par MCP sur vos pull requests, vos dépôts et vos vulnérabilités."
---

Pullwatch dispose d’un serveur [Model Context Protocol](https://modelcontextprotocol.io) local : un agent de code sur votre Mac peut lui demander ce qu’il sait. « Lesquelles de mes pull requests ont des checks en échec ? », « Qu’y a-t-il de critique dans `acme/web` ? », « Pourquoi ne puis-je pas mettre à jour `express` ? », « Qui est encore sur un ancien `@acme/ui` ? ». L’agent utilise ce que Pullwatch a déjà récupéré avec vos comptes, il n’a donc besoin d’aucun jeton.

Les agents ne font que lire. Ils ne voient que les dépôts que vous suivez, ne reçoivent jamais de jeton et ne peuvent rien modifier sur GitHub, Azure DevOps, GitLab, Bitbucket, Codeberg, Forgejo ou Gitea. Rien n’est partagé tant que vous ne l’activez pas.

## L’activer

Ouvrez Réglages, **Agents** et choisissez sous **Autoriser les agents à utiliser Pullwatch** :

- **Jamais** (par défaut) : les agents ne reçoivent aucune donnée. Un agent qui essaie apprend que les agents sont désactivés.
- **Tant que Pullwatch est ouvert** : les agents peuvent poser leurs questions tant que Pullwatch tourne. S’il ne tourne pas, l’agent apprend qu’il faut ouvrir Pullwatch.
- **Toujours** : si Pullwatch ne tourne pas, il démarre en arrière-plan (sans fenêtre, il reste dans la barre des menus) dès qu’un agent pose une question, et répond.

Ce sont les mêmes choix que ceux de Xcode pour les agents externes.

## Configurer un agent

Choisissez votre agent sous **Configurer un agent**. Pullwatch affiche la commande ou le JSON avec le chemin de la copie de Pullwatch que vous utilisez, et **Copier** le place dans le presse-papiers. Pour Pullwatch dans Applications, cela donne ce qui suit. Si vous déplacez l’app, configurez à nouveau l’agent.

### Claude Code

À exécuter dans Terminal :

```sh
claude mcp add --scope user --transport stdio pullwatch -- /Applications/Pullwatch.app/Contents/Helpers/pullwatch-mcp
```

Avec `--scope user`, Pullwatch fonctionne dans chaque projet. Sans cette option, il ne fonctionne que dans le dossier où vous avez lancé la commande.

### Codex

À exécuter dans Terminal :

```sh
codex mcp add pullwatch -- /Applications/Pullwatch.app/Contents/Helpers/pullwatch-mcp
```

Codex l’écrit dans sa configuration globale, `~/.codex/config.toml`, et cela vaut donc pour chaque projet.

### Cursor

À ajouter dans `~/.cursor/mcp.json` :

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

À ajouter dans `.vscode/mcp.json` de votre projet :

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

### Autres agents

Tout client MCP qui lance un serveur par stdio fonctionne : donnez-lui `/Applications/Pullwatch.app/Contents/Helpers/pullwatch-mcp` comme commande, sans arguments.

## Autoriser l’agent, une seule fois

La première fois qu’un agent se connecte, Pullwatch vous le demande par une notification, par exemple « Claude Code veut utiliser Pullwatch », avec **Autoriser** et **Ne pas autoriser**. Un clic sur la notification elle-même ouvre Réglages, **Agents**. Tant que vous ne l’autorisez pas, l’agent reste connecté mais ne reçoit aucune donnée : chaque question reçoit pour réponse qu’il attend une autorisation. Autorisez-le, et sa question suivante fonctionne.

Vous autorisez un agent une seule fois ; Pullwatch ne redemande pas à chaque question. Chaque outil lit seulement ce que Pullwatch vous montre déjà ; une demande à chaque appel vous habituerait surtout à cliquer sur **Autoriser**. Un choix réfléchi par agent, que vous pouvez annuler à tout moment, vous protège mieux.

- **Agents autorisés** dans Réglages, **Agents** liste les agents que vous avez autorisés, et l’agent en attente avec **Ne pas autoriser** et **Autoriser**. Le bouton de suppression à côté d’un agent le retire de la liste ; Pullwatch le demande alors à nouveau à sa prochaine connexion.
- **Ne pas autoriser** ferme toutes les connexions de cet agent et ne retient rien. L’agent ne se reconnecte pas de lui-même : relancez-le, ou son serveur MCP, pour demander à nouveau.
- Pullwatch reconnaît un agent au nom qu’il annonce (Claude Code, Codex, Cursor, VS Code ou son propre nom). Ce nom vous est montré pour que vous sachiez qui demande ; ce n’est pas un mot de passe.

## Voir quels agents sont connectés

**Agents connectés** dans Réglages, **Agents** liste chaque agent connecté en ce moment : son nom et sa version (**Connexion…** tant qu’il n’a pas dit qui il est), depuis quand, le dernier outil utilisé et quand, et **En attente d’autorisation** tant qu’il attend. **Déconnecter** ferme sa connexion ; comme après **Ne pas autoriser**, l’agent reste alors à l’écart jusqu’à ce que vous le relanciez.

Tant qu’au moins un agent est connecté, le haut du [panneau du menu](/fr/using/menu/) affiche un bouton des agents avec leur nombre. Un point orange dessus signifie qu’un agent attend une autorisation. Cliquez dessus pour la même liste, avec **Déconnecter** pour chaque agent, **Ne pas autoriser** et **Autoriser** pour celui qui attend, et **Réglages des agents…** pour ouvrir Réglages, **Agents**.

## Les outils

L’agent choisit lui-même l’outil à appeler ; vous posez simplement votre question. Chaque outil lit ce que Pullwatch a déjà récupéré ; aucun ne fait d’appel réseau ni ne lance une interrogation des services. Les réponses sont en anglais : du JSON avec un résumé d’une ligne.

Les listes renvoient 25 éléments par défaut. `limit` (au plus 100) et `cursor` permettent de passer aux pages suivantes ; la réponse contient `total` et, s’il y en a plus, `next_cursor`. Quand un outil demande `repo`, c’est `propriétaire/nom` (`projet/repo` sur Azure DevOps) ; `account_id` (tiré de `get_status`) n’est utile que si deux comptes suivent un dépôt du même nom.

Les exemples ci-dessous viennent des données de test de Pullwatch. Les réponses sont abrégées.

### get_status

Les comptes (id, service, nom et hôte), le résultat de leur dernière interrogation, ce qui se synchronise, la date de la vérification des versions, les sources désactivées et le nombre d’éléments non lus. Un compte liste dans `unreachable_repositories` les dépôts suivis que son jeton ne peut pas lire : leurs tags et branches ne sont plus mis à jour. Aucun argument.

```jsonc
// get_status {}
// "2 accounts (1 failing), 3 followed repositories; sources off: PyPI."
{"accounts":[{"host":"github.com","name":"@octo","service":"GitHub","state":"ok","last_poll":"2026-11-04T09:00:00Z"},
  {"host":"gitlab.example.com","name":"group","service":"GitLab","state":"failed","error":"Token invalid or expired"}],
 "followed_repositories":3,"unread_pull_requests":6,"unread_tags":2,
 "sources_off":[{"message":"Not checked: source PyPI is off.","name":"PyPI","source":"pyPI"}],"sync":{"state":"idle"}}
```

### list_pull_requests

Les pull requests de l’historique, les plus récentes d’abord, avec leurs checks. Chacune a une `reference` écrite comme son service l’écrit : `acme/web#1` sur GitHub, Bitbucket, Codeberg, Forgejo et Gitea, `group/project!42` sur GitLab et `project/repo!42` sur Azure DevOps. Arguments : `repo`, `account_id`, `state` (`open` par défaut, brouillons et file d’attente compris ; ou `draft`, `queued`, `merged`, `closed`, `all`), `author`, `mine` (seulement les vôtres), `unread` (`true` ou `false`), `checks` (`failed`, `pending` ou `passed`), `limit`, `cursor`.

```jsonc
// list_pull_requests {"checks":"failed"}
// "1 pull request (open), 1 with failing checks."
{"total":1,"not_checked":[],"pull_requests":[{"repository":"acme/web","number":1,"reference":"acme/web#1","title":"Add login","author":"octo",
  "state":"open","is_mine":true,"is_read":false,"checks":{"status":"failed","failed":1,"passed":3,"pending":0,"total":4},
  "url":"https://github.com/acme/web/pull/1"}]}
```

### get_pull_request

Une pull request : sa `reference`, état, brouillon, auteur et coauteurs, nombre de checks, place dans la file de fusion, si elle a quitté la file sans être fusionnée (`left_queue`, avec la raison quand le service la donne), lue ou non, dates et lien. Arguments : `repo` et `number` (obligatoires), `account_id`.

```jsonc
// get_pull_request {"repo":"acme/web","number":3}
// "acme/web #3 (queued): Ready to merge"
{"not_checked":[],"pull_request":{"repository":"acme/web","number":3,"reference":"acme/web#3","title":"Ready to merge","author":"ada","co_authors":[],
  "is_queued":true,"merge_queue":{"kind":"merge_queue","position":1},"checks":{"status":"passed","passed":4,"total":4},
  "url":"https://github.com/acme/web/pull/3"}}
```

### list_tags

Les tags et les releases, les plus récents d’abord. Arguments : `repo`, `account_id`, `unread`, `limit`, `cursor`.

```jsonc
// list_tags {"repo":"acme/web","limit":1}
// "2 tags; newest: acme/web v1.2.0."
{"total":2,"next_cursor":"1","tags":[{"repository":"acme/web","name":"v1.2.0","author":"octo","is_read":false,
  "release":{"title":"Spring release","is_prerelease":false,"url":"https://github.com/acme/web/releases/tag/v1.2.0"},
  "url":"https://github.com/acme/web/releases/tag/v1.2.0"}]}
```

### list_repositories

Les dépôts que vous suivez, les pires d’abord, avec leur état (`problem`, `behind`, `ok` ou `unknown`) et leurs chiffres : pull requests ouvertes, dernier tag, vulnérabilités par gravité, alertes de sécurité graves, secrets ouverts, runtimes en retard et mises à jour de paquets. `unreachable` vaut `true` quand le jeton du compte ne peut pas lire le dépôt ; le dernier tag peut alors être ancien. Arguments : `account_id`, `health`, `limit`, `cursor`.

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

Les runtimes, frameworks et paquets d’un dépôt : version installée et dernière version, ce qui est en retard ou en fin de vie, et ce qui bloque chaque mise à jour. Un paquet qu’un de vos dépôts suivis publie a `in_house` (voir plus bas). Arguments : `repo` (obligatoire), `account_id`, `only_outdated`, `limit`, `cursor` (ils paginent les paquets).

```jsonc
// get_repository_report {"repo":"acme/web","only_outdated":true,"limit":1}
// "acme/web: 1 runtime (1 behind or end of life), 2 packages listed."
{"repository":"acme/web","health":"problem","checked":true,"total":2,"next_cursor":"1","not_checked":[],
 "runtimes":[{"name":"Node.js","version":"18","latest":"22","status":"end_of_life","declared_in":[".nvmrc"]}],
 "packages":[{"name":"express","ecosystem":"npm","installed":["4.19.2"],"latest":"5.1.0","requested":["^4.19.0"],
   "update":"needs_manifest_change","blocker":"express 5.1.0 needs a new major version (outside ^4.19.0)."}]}
```

### list_vulnerabilities

Les vulnérabilités connues des paquets et les alertes du code scanning et d’Advanced Security, les pires d’abord, avec leur source et leur correctif. Arguments : `repo`, `account_id`, `min_severity` (`low`, `moderate`, `high` ou `critical`), `limit`, `cursor`.

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

Les paquets et images de conteneur que vos dépôts suivis publient dans le registre de leur propre service (GitHub Packages, un registre GitLab, un flux Azure Artifacts), un par paquet, comme dans [Paquets](/fr/using/packages/) : type, compte, propriétaire, le dépôt qui publie (absent pour Azure Artifacts), la dernière version et sa date, la visibilité, la page du registre, les versions récentes avec leur tag et leur run, et `used_by` : les dépôts suivis qui en dépendent, avec leurs versions et s’ils le demandent eux-mêmes. `usage_known` vaut `false` pour les types que la vérification des dépendances n’associe pas encore (images de conteneur, Helm) : un `used_by` vide y signifie donc inconnu, et non inutilisé. `needs_permission` liste les comptes qui ne peuvent pas lire leur registre, avec la raison, et `not_checked` nomme la source quand **Registres de paquets de vos comptes** est désactivé. Arguments : `repo` (seulement ce que ce dépôt suivi publie), `type` (`npm`, `container`, `nuget`, `maven`, `rubygems`, `pypi`, `helm`, `generic` et d’autres), `account_id`, `limit`, `cursor`.

```jsonc
// list_packages {"repo":"acme/web"}
// "1 published package."
{"total":1,"not_checked":[],"needs_permission":[],"packages":[{"name":"ui","type":"npm","owner":"acme","repository":"acme/web",
  "latest_version":"2.3.0","visibility":"private","url":"https://github.com/orgs/acme/packages/npm/package/ui",
  "recent_versions":[{"version":"2.3.0","tag":"v2.3.0"},{"version":"2.2.0"}],
  "used_by":[{"repository":"acme/admin","versions":["2.2.0"],"is_direct":true}],"usage_known":true}]}
```

### explain_update

Pourquoi un paquet ne se met pas à jour aussi simplement, par installation : la plage demandée, le pas (patch, minor ou major), ce qui bloque et les vulnérabilités qu’une mise à jour corrige. Arguments : `repo` et `package` (obligatoires), `ecosystem` (seulement si le nom est ambigu), `account_id`. Un paquet qui n’arrive que par un autre paquet (tout paquet d’un lockfile) est expliqué aussi : `via` donne la chaîne, et l’explication dit ce que demande la correction d’une vulnérabilité, seulement le lockfile ou d’abord un parent plus récent.

Pour un paquet interne, cet outil et `get_repository_report` ajoutent `in_house` : `source` (le dépôt qui publie, ou le projet Azure DevOps), `repository`, `owner`, `url` (la page du dépôt), `registry_url` (le paquet dans votre propre registre), `status` et `reason`. Avec `status` `checked`, la dernière version vient de votre propre registre. Avec `source_off`, `needs_permission`, `read_failed` (votre registre n’a donné aucune dernière version) ou `unconfirmed` (le lockfile prend le paquet dans votre propre registre, mais ce registre ne l’a pas listé), elle n’a pas été lue : `update` vaut `not_checked`, `not_checked` nomme la source ou l’autorisation manquante, et `reason` dit ce qu’il faut accorder. Pullwatch ne garde un nom privé que s’il peut voir que le paquet est le vôtre ; [Les noms qui restent privés](/fr/using/dependencies/#les-noms-qui-restent-privés) liste les cas. Un tel nom n’est jamais envoyé à un registre public, et n’atteint OSV.dev que si une vérification précédente l’a aussi trouvé dans le registre public. Là où Pullwatch ne peut pas le voir, par exemple quand le lockfile ne nomme aucun registre, le nom peut atteindre les deux.

```jsonc
// explain_update {"repo":"acme/web","package":"express"}
// "express 5.1.0 needs a new major version (outside ^4.19.0)."
{"package":"express","ecosystem":"npm","latest":"5.1.0","vulnerabilities":[],"not_checked":[],
 "installs":[{"version":"4.19.2","requested":"^4.19.0","declared_in":"package.json","step":"major",
   "update":"needs_manifest_change","explanation":"express 5.1.0 needs a new major version (outside ^4.19.0)."}]}
```

### get_agent_brief

La même consigne en Markdown que **Copier pour un agent IA** place dans le presse-papiers pour une section de la page d’un dépôt (voir [Dépôts](/fr/using/repositories/#copier-pour-un-agent-ia)). Arguments : `repo` et `section` (obligatoires ; `pull_requests`, `pull_requests_per_month`, `check`, `package_updates`, `packages` ou `security`), `workspace` (pour `packages`), `account_id`.

```jsonc
// get_agent_brief {"repo":"acme/web","section":"security"}
// "Agent brief for acme/web, section security."
{"repository":"acme/web","section":"security",
 "markdown":"## Pullwatch: security on GitHub\n\nRepository: acme/web (https://github.com/acme/web)\nChecked: 2026-11-03\n\nCode scanning: 1 open alert\n..."}
```

## Ce qui n’est jamais partagé

- Les jetons, les éléments du trousseau et les valeurs des secrets trouvés par le secret scanning n’atteignent jamais un agent ; le secret scanning n’est qu’un nombre. Les comptes apparaissent avec leur nom et leur hôte. Une adresse de serveur contenant un jeton perd cette partie, et les coauteurs apparaissent sans leur adresse e-mail. Aucun outil ne peut demander d’identifiants, car Pullwatch n’en donne aucun aux outils.
- Un dépôt que vous ne suivez pas n’existe pas pour un agent. Une question à son sujet reçoit « Repository … is not followed in Pullwatch. »
- Si vous avez désactivé une source dans Réglages, **Sources**, la réponse indique « Not checked: source … is off. » pour ce que cette source aurait fourni. Ce n’est jamais présenté comme à jour ou sans vulnérabilité. Voir [Confidentialité et sources](/fr/privacy/).
- Les outils ne font que lire. Des actions comme marquer comme lu viendront peut-être plus tard, derrière un interrupteur à part, désactivé par défaut, et même celles-ci n’écriront jamais sur GitHub, Azure DevOps, GitLab, Bitbucket, Codeberg, Forgejo ou Gitea.

## Confidentialité

Ce qu’un agent lit dans Pullwatch est envoyé au fournisseur de son modèle, comme tout ce que vous lui montrez : titres de pull requests, noms de dépôts, versions de paquets, vulnérabilités. Réglages, **Agents** le dit sous le choix. Pullwatch lui-même n’envoie rien nulle part pour cela : l’agent et Pullwatch communiquent par une connexion sur votre Mac que seuls votre compte utilisateur et le programme auxiliaire de Pullwatch peuvent utiliser.

Pour arrêter, choisissez **Jamais**. Pullwatch ferme alors la connexion, et les agents ne reçoivent plus de données tant que vous ne choisissez pas autre chose. Vous pouvez aussi retirer le serveur de l’agent (`claude mcp remove pullwatch`, `codex mcp remove pullwatch`, ou l’entrée du JSON).

## Dépannage

Commencez par la liste des serveurs de votre agent, pour Claude Code :

```sh
claude mcp list
```

`pullwatch` devrait y figurer comme connecté. S’il manque, ajoutez-le à nouveau avec `--scope user`, pour qu’il ne soit pas lié à un dossier. S’il échoue, vérifiez que le programme auxiliaire se trouve là où pointe la commande : `ls -l /Applications/Pullwatch.app/Contents/Helpers/pullwatch-mcp`.

L’agent affiche la réponse de Pullwatch telle quelle, en anglais. Chaque réponse, et que faire :

### Les agents sont désactivés

```text
Agents are turned off in Pullwatch: Settings, Agents
```

Le choix dans Réglages, **Agents** est **Jamais**. Choisissez **Tant que Pullwatch est ouvert** ou **Toujours**.

### Pullwatch n’est pas ouvert

```text
Open Pullwatch to use it from an agent.
```

Le choix est **Tant que Pullwatch est ouvert** et Pullwatch ne tourne pas. Ouvrez-le, ou choisissez **Toujours**.

### Pullwatch n’a pas démarré à temps

```text
Pullwatch did not start in time. Open Pullwatch to use it from an agent.
```

Le choix est **Toujours**, mais Pullwatch n’était pas prêt en 25 secondes. Ouvrez-le vous-même. S’il ne s’ouvre pas depuis le chemin de la configuration de votre agent, vous avez déplacé l’app : configurez à nouveau l’agent.

### En attente d’autorisation

```text
Waiting for approval in Pullwatch: allow Claude Code in the notification or under Settings, Agents.
```

Cliquez sur **Autoriser** dans la notification, dans Réglages, **Agents** sous **Agents autorisés**, ou derrière le bouton des agents dans le panneau du menu. Posez ensuite la question à nouveau ; l’agent n’a pas besoin de se reconnecter. Pas de notification ? Les notifications de Pullwatch sont alors désactivées dans Réglages Système ; autorisez l’agent dans les Réglages de Pullwatch.

### Déconnecté

```text
Pullwatch disconnected this agent. Reconnect the agent to Pullwatch (restart its MCP server) to use it again.
```

Vous avez cliqué sur **Déconnecter** ou **Ne pas autoriser**. Relancez l’agent, ou son serveur MCP (dans Claude Code, `/mcp`), pour vous reconnecter.

### Connexion fermée pendant une réponse

```text
Pullwatch closed the connection while answering. Try again.
```

Pullwatch a redémarré pendant sa réponse, par exemple pour une mise à jour. Posez la question à nouveau : le programme auxiliaire se reconnecte une fois de lui-même.

### Versions du protocole

Pullwatch parle MCP 2025-11-25, 2025-06-18, 2025-03-26 et 2024-11-05. Un agent qui demande une version plus récente reçoit 2025-11-25, que les versions actuelles de Claude Code, Codex, Cursor et VS Code acceptent. Si un agent la refuse, mettez à jour Pullwatch et l’agent.
