---
title: Agents (MCP)
description: Let a coding agent such as Claude Code, Codex, Cursor or VS Code ask Pullwatch about your pull requests, repositories and vulnerabilities over MCP.
---

Pullwatch has a local [Model Context Protocol](https://modelcontextprotocol.io) server, so a coding agent on your Mac can ask it what it knows: "which of my pull requests have failing checks?", "what is critical in `acme/web`?", "why can't I update `express`?", "who is still on an old `@acme/ui`?". The agent uses what Pullwatch already fetched with your accounts, so it needs no token of its own.

Agents only read. They see only the repositories you follow, they never get a token, and they cannot change anything on GitHub, Azure DevOps, GitLab, Bitbucket, Codeberg, Forgejo or Gitea. Nothing is shared until you turn it on.

## Turn it on

Open Settings, **Agents** and choose under **Allow agents to use Pullwatch**:

- **Never** (the default): agents get no data. An agent that tries is told that agents are turned off.
- **While Pullwatch is open**: agents can ask while Pullwatch runs. When it is not running, the agent is told to open Pullwatch.
- **Always**: when Pullwatch is not running, it starts in the background (no window, it stays in the menu bar) as soon as an agent asks, and answers.

These are the same choices Xcode offers for external agents.

## Set up an agent

Under **Set Up an Agent**, pick your agent. Pullwatch shows the command or the JSON with the path of the copy of Pullwatch you are running, and **Copy** puts it on the clipboard. For Pullwatch in Applications it reads as below. If you move the app, set up the agent again.

### Claude Code

Run in Terminal:

```sh
claude mcp add --scope user --transport stdio pullwatch -- /Applications/Pullwatch.app/Contents/Helpers/pullwatch-mcp
```

`--scope user` makes Pullwatch available in every project. Without it, Pullwatch works only in the folder where you ran the command.

### Codex

Run in Terminal:

```sh
codex mcp add pullwatch -- /Applications/Pullwatch.app/Contents/Helpers/pullwatch-mcp
```

Codex writes this to its global configuration, `~/.codex/config.toml`, so it works in every project.

### Cursor

Add to `~/.cursor/mcp.json`:

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

Add to `.vscode/mcp.json` in your project:

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

### Other agents

Any MCP client that starts a server over stdio works: give it `/Applications/Pullwatch.app/Contents/Helpers/pullwatch-mcp` as the command, without arguments.

## Allow the agent, once

The first time an agent connects, Pullwatch asks you in a notification, for example "Claude Code wants to use Pullwatch", with **Allow** and **Don't Allow**. Clicking the notification itself opens Settings, **Agents**. Until you allow it, the agent stays connected but gets no data: every question gets the answer that it is waiting for approval. Allow it, and its next question works.

You allow an agent once; Pullwatch does not ask again on every question. Every tool only reads what Pullwatch already shows you, so a prompt on each call would mostly train you to click **Allow**; one deliberate choice per agent, which you can take back at any time, protects you better.

- **Approved Agents** in Settings, **Agents** lists the agents you allowed, and the one that is waiting with **Don't Allow** and **Allow**. The remove button next to an agent takes it off the list; Pullwatch then asks again the next time it connects.
- **Don't Allow** closes every connection of that agent and remembers nothing. The agent does not reconnect by itself: restart it, or its MCP server, to ask again.
- Pullwatch recognizes an agent by the name it reports (Claude Code, Codex, Cursor, VS Code or its own name). That name is shown to you so you know who asks; it is not a password.

## See which agents are connected

**Connected Agents** in Settings, **Agents** lists each agent that is connected now: its name and version (**Connecting…** until it says who it is), since when, the last tool it used and when, and **Waiting for approval** while it waits. **Disconnect** closes its connection; like **Don't Allow**, the agent then stays away until you restart it.

While at least one agent is connected, the header of the [menu panel](/using/menu/) shows an agents button with the number of agents. An orange dot on it means an agent waits for approval. Click it for the same list, with **Disconnect** for each agent, **Don't Allow** and **Allow** for one that waits, and **Agent Settings…** to open Settings, **Agents**.

## The tools

The agent decides which tool to call; you just ask your question. Every tool reads what Pullwatch has already fetched; none of them makes a network call or starts a poll. The answers are in English, as JSON with a one-line summary.

Lists return 25 items by default. `limit` (at most 100) and `cursor` page through them; the answer has `total` and, when there is more, `next_cursor`. Where a tool takes `repo`, it is `owner/name` (`project/repo` on Azure DevOps); `account_id` (from `get_status`) is only needed when two accounts follow a repository with the same name.

The examples below come from Pullwatch's test data. The answers are shortened.

### get_status

Accounts (id, service, name and host), how their last poll went, what is syncing, when the version check ran, which sources are off, and the unread counts. An account lists the followed repositories its token can't read in `unreachable_repositories`: their tags and branches are not updated. No arguments.

```jsonc
// get_status {}
// "2 accounts (1 failing), 3 followed repositories; sources off: PyPI."
{"accounts":[{"host":"github.com","name":"@octo","service":"GitHub","state":"ok","last_poll":"2026-11-04T09:00:00Z"},
  {"host":"gitlab.example.com","name":"group","service":"GitLab","state":"failed","error":"Token invalid or expired"}],
 "followed_repositories":3,"unread_pull_requests":6,"unread_tags":2,
 "sources_off":[{"message":"Not checked: source PyPI is off.","name":"PyPI","source":"pyPI"}],"sync":{"state":"idle"}}
```

### list_pull_requests

Pull requests from the history, newest first, with their checks. Each has a `reference` the way its service writes it: `acme/web#1` on GitHub, Bitbucket, Codeberg, Forgejo and Gitea, `group/project!42` on GitLab and `project/repo!42` on Azure DevOps. Arguments: `repo`, `account_id`, `state` (`open` by default, with drafts and queued ones; or `draft`, `queued`, `merged`, `closed`, `all`), `author`, `mine` (only yours), `unread` (`true` or `false`), `checks` (`failed`, `pending` or `passed`), `limit`, `cursor`.

```jsonc
// list_pull_requests {"checks":"failed"}
// "1 pull request (open), 1 with failing checks."
{"total":1,"not_checked":[],"pull_requests":[{"repository":"acme/web","number":1,"reference":"acme/web#1","title":"Add login","author":"octo",
  "state":"open","is_mine":true,"is_read":false,"checks":{"status":"failed","failed":1,"passed":3,"pending":0,"total":4},
  "url":"https://github.com/acme/web/pull/1"}]}
```

### get_pull_request

One pull request: its `reference`, state, draft, author and co-authors, check counts, merge queue position, whether it left the queue without merging (`left_queue`, with the reason when the service gives one), read state, dates and link. Arguments: `repo` and `number` (both required), `account_id`.

```jsonc
// get_pull_request {"repo":"acme/web","number":3}
// "acme/web #3 (queued): Ready to merge"
{"not_checked":[],"pull_request":{"repository":"acme/web","number":3,"reference":"acme/web#3","title":"Ready to merge","author":"ada","co_authors":[],
  "is_queued":true,"merge_queue":{"kind":"merge_queue","position":1},"checks":{"status":"passed","passed":4,"total":4},
  "url":"https://github.com/acme/web/pull/3"}}
```

### list_tags

Tags and releases, newest first. Arguments: `repo`, `account_id`, `unread`, `limit`, `cursor`.

```jsonc
// list_tags {"repo":"acme/web","limit":1}
// "2 tags; newest: acme/web v1.2.0."
{"total":2,"next_cursor":"1","tags":[{"repository":"acme/web","name":"v1.2.0","author":"octo","is_read":false,
  "release":{"title":"Spring release","is_prerelease":false,"url":"https://github.com/acme/web/releases/tag/v1.2.0"},
  "url":"https://github.com/acme/web/releases/tag/v1.2.0"}]}
```

### list_repositories

The repositories you follow, worst first, with their health (`problem`, `behind`, `ok` or `unknown`) and counts: open pull requests, latest tag, vulnerabilities by severity, serious security alerts, open secrets, outdated runtimes and package updates. `unreachable` is `true` when the account's token can't read the repository, so its latest tag may be old. Arguments: `account_id`, `health`, `limit`, `cursor`.

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

The runtimes, frameworks and packages of one repository: installed and latest version, what is behind or end of life, and what holds each update back. A package that one of your followed repositories publishes has `in_house` (see below). Arguments: `repo` (required), `account_id`, `only_outdated`, `limit`, `cursor` (they page the packages).

```jsonc
// get_repository_report {"repo":"acme/web","only_outdated":true,"limit":1}
// "acme/web: 1 runtime (1 behind or end of life), 2 packages listed."
{"repository":"acme/web","health":"problem","checked":true,"total":2,"next_cursor":"1","not_checked":[],
 "runtimes":[{"name":"Node.js","version":"18","latest":"22","status":"end_of_life","declared_in":[".nvmrc"]}],
 "packages":[{"name":"express","ecosystem":"npm","installed":["4.19.2"],"latest":"5.1.0","requested":["^4.19.0"],
   "update":"needs_manifest_change","blocker":"express 5.1.0 needs a new major version (outside ^4.19.0)."}]}
```

### list_vulnerabilities

Known vulnerabilities in packages and the security alerts of code scanning and Advanced Security, worst first, with their source and fix. Arguments: `repo`, `account_id`, `min_severity` (`low`, `moderate`, `high` or `critical`), `limit`, `cursor`.

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

The packages and container images your followed repositories publish to the registry of their own service (GitHub Packages, a GitLab registry, an Azure Artifacts feed), one per package, as in [Packages](/using/packages/): type, account, owner, the publishing repository (absent for Azure Artifacts), the latest version and its date, visibility, the registry page, the recent versions with their tag and run, and `used_by`: the followed repositories that depend on it, with their versions and whether they ask for it themselves. `usage_known` is `false` for types the dependency check does not match yet (container images, Helm), so an empty `used_by` there means unknown, not unused. `needs_permission` lists the accounts that may not read their registry, with the reason, and `not_checked` names the source when **Package registries of your accounts** is off. Arguments: `repo` (only what that followed repository publishes), `type` (`npm`, `container`, `nuget`, `maven`, `rubygems`, `pypi`, `helm`, `generic` and more), `account_id`, `limit`, `cursor`.

```jsonc
// list_packages {"repo":"acme/web"}
// "1 published package."
{"total":1,"not_checked":[],"needs_permission":[],"packages":[{"name":"ui","type":"npm","owner":"acme","repository":"acme/web",
  "latest_version":"2.3.0","visibility":"private","url":"https://github.com/orgs/acme/packages/npm/package/ui",
  "recent_versions":[{"version":"2.3.0","tag":"v2.3.0"},{"version":"2.2.0"}],
  "used_by":[{"repository":"acme/admin","versions":["2.2.0"],"is_direct":true}],"usage_known":true}]}
```

### explain_update

Why one package cannot simply be updated, per install: the requested range, the step (patch, minor or major), what blocks it and the vulnerabilities an update fixes. Arguments: `repo` and `package` (both required), `ecosystem` (only when the name is ambiguous), `account_id`. It also explains a package that only comes in through another package (any package from a lockfile): `via` names the chain, and the explanation says what fixing a vulnerability takes, only the lockfile or a newer parent first.

For an in-house package, both this tool and `get_repository_report` add `in_house`: `source` (the publishing repository, or the Azure DevOps project), `repository`, `owner`, `url` (the repository's page), `registry_url` (the package in your own registry), `status` and `reason`. With `status` `checked`, the latest version comes from your own registry. With `source_off`, `needs_permission`, `read_failed` (your registry gave no latest version) or `unconfirmed` (the lockfile gets the package from your own registry, but that registry did not list it), it was not read: `update` is `not_checked`, `not_checked` names the source or the missing permission, and `reason` says what to grant. Pullwatch keeps a name private only when it can tell the package is yours; [Which names stay private](/using/dependencies/#which-names-stay-private) lists the cases. Such a name is never sent to a public registry, and reaches OSV.dev only when an earlier check found it in the public registry too. Where Pullwatch cannot tell, for example when the lockfile names no registry, the name can reach both.

```jsonc
// explain_update {"repo":"acme/web","package":"express"}
// "express 5.1.0 needs a new major version (outside ^4.19.0)."
{"package":"express","ecosystem":"npm","latest":"5.1.0","vulnerabilities":[],"not_checked":[],
 "installs":[{"version":"4.19.2","requested":"^4.19.0","declared_in":"package.json","step":"major",
   "update":"needs_manifest_change","explanation":"express 5.1.0 needs a new major version (outside ^4.19.0)."}]}
```

### get_agent_brief

The same Markdown brief that **Copy for an AI Agent** puts on the clipboard for one section of a repository page (see [Repositories](/using/repositories/#copy-for-an-ai-agent)). Arguments: `repo` and `section` (both required; `pull_requests`, `pull_requests_per_month`, `check`, `package_updates`, `packages` or `security`), `workspace` (for `packages`), `account_id`.

```jsonc
// get_agent_brief {"repo":"acme/web","section":"security"}
// "Agent brief for acme/web, section security."
{"repository":"acme/web","section":"security",
 "markdown":"## Pullwatch: security on GitHub\n\nRepository: acme/web (https://github.com/acme/web)\nChecked: 2026-11-03\n\nCode scanning: 1 open alert\n..."}
```

## What is never shared

- Tokens, Keychain items and the values of secrets found by secret scanning never reach an agent; secret scanning is only a count. Accounts appear as name and host. A server address with a token in it loses that part, and co-authors appear without their e-mail address. No tool can ask for a credential, because Pullwatch does not give the tools one.
- A repository you do not follow does not exist for an agent. Asking about one gives "Repository … is not followed in Pullwatch."
- When you switched a source off under Settings, **Sources**, the answer says "Not checked: source … is off." for what it would have answered. It is never reported as current or free of vulnerabilities. See [Privacy and sources](/privacy/).
- The tools only read. Actions such as marking as read may come later, behind a separate switch that is off by default, and even those will never write to GitHub, Azure DevOps, GitLab, Bitbucket, Codeberg, Forgejo or Gitea.

## Privacy

What an agent reads in Pullwatch is sent to its model provider, the same as anything else you show it: titles of pull requests, repository names, package versions, vulnerabilities. Settings, **Agents** says so under the choice. Pullwatch itself sends nothing anywhere for this: the agent and Pullwatch talk over a connection on your Mac that only your user account and Pullwatch's own helper can use.

To stop, choose **Never**. Pullwatch then closes the connection, and agents get no data until you choose again. You can also remove the server from the agent (`claude mcp remove pullwatch`, `codex mcp remove pullwatch`, or the JSON entry).

## Troubleshooting

Start with your agent's own list of servers, for Claude Code:

```sh
claude mcp list
```

`pullwatch` should be listed as connected. When it is missing, add it again with `--scope user`, so it is not tied to one folder. When it failed, check that the helper is where the command points: `ls -l /Applications/Pullwatch.app/Contents/Helpers/pullwatch-mcp`.

The agent shows Pullwatch's answer word for word. Each one, and what to do:

### Agents are turned off

```text
Agents are turned off in Pullwatch: Settings, Agents
```

The choice in Settings, **Agents** is **Never**. Choose **While Pullwatch is open** or **Always**.

### Pullwatch is not open

```text
Open Pullwatch to use it from an agent.
```

The choice is **While Pullwatch is open** and Pullwatch is not running. Open it, or choose **Always**.

### Pullwatch did not start in time

```text
Pullwatch did not start in time. Open Pullwatch to use it from an agent.
```

The choice is **Always**, but Pullwatch was not ready within 25 seconds. Open it yourself. If it does not open from the path in your agent's setup, you moved the app: set up the agent again.

### Waiting for approval

```text
Waiting for approval in Pullwatch: allow Claude Code in the notification or under Settings, Agents.
```

Click **Allow** in the notification, in Settings, **Agents** under **Approved Agents**, or behind the agents button in the menu panel. Then ask again; the agent does not need to reconnect. No notification? Then notifications for Pullwatch are off in System Settings; allow the agent in Settings instead.

### Disconnected

```text
Pullwatch disconnected this agent. Reconnect the agent to Pullwatch (restart its MCP server) to use it again.
```

You clicked **Disconnect** or **Don't Allow**. Restart the agent, or its MCP server (in Claude Code, `/mcp`), to connect again.

### Closed while answering

```text
Pullwatch closed the connection while answering. Try again.
```

Pullwatch restarted while answering, for example for an update. Ask again: the helper reconnects by itself once.

### Protocol versions

Pullwatch speaks MCP 2025-11-25, 2025-06-18, 2025-03-26 and 2024-11-05. An agent that asks for a newer version gets 2025-11-25, which current versions of Claude Code, Codex, Cursor and VS Code accept. When an agent refuses it, update Pullwatch and the agent.
