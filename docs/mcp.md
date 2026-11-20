# The MCP server for coding agents

How Pullwatch serves coding agents over the Model Context Protocol, for the
people who work on it. What a user sees and does is on the website's
[Agents page](../site/src/content/docs/agents.md) (`/agents/`). The epic is
fork issue #139; the pieces landed in #146 (core), #147 (tools), #148
(connection), #165 (Settings, Agents and approval), #185 (menu panel)
and #170 and #171 (`list_packages`, `in_house`).

## Architecture

```
Claude Code / Codex / Cursor / VS Code
        │ stdio, newline-delimited JSON-RPC (MCP)
        ▼
pullwatch-mcp            Pullwatch.app/Contents/Helpers, signed with the app
        │ Unix socket <data folder>/mcp.sock (folder 0700, socket 0600)
        ▼
Pullwatch.app            AgentServer → MCPSocketServer → one PullwatchMCPServer per connection
```

- **The app is the server.** The tools, the approval and the list of
  connected agents live where the data is, so there is one copy of the logic
  and an agent sees what the windows show. `AgentServer`
  (`Pullwatch/Pullwatch/Agents/`) owns one task that runs
  `MCPSocketServer` while `AppConfig.agentAccess` is not `never`, and never
  while XCTest hosts the app. It builds the registry from
  `AppModel.mcpTools()` (`PullwatchMCPTools.all(dataSource:)` over
  `AppMCPDataSource`, which reads the models on every call).
- **The helper is a pipe.** `pullwatch-mcp` (`Pullwatch/pullwatch-mcp/`)
  only wires `MCPBridge` (`PullwatchKit/Sources/PullwatchMCP/Bridge/`) to
  stdio and a `WorkspaceLauncher`. The bridge reads `agentAccess` from
  `config.json` itself, so it can answer `never` without starting anything:
  - `never`: every request gets `-32000` "Agents are turned off in
    Pullwatch: Settings, Agents"; the socket is never touched.
  - `whileOpen`: without a socket, "Open Pullwatch to use it from an agent."
  - `always`: without a socket it opens Pullwatch through `NSWorkspace`
    (not activated, and with `-PullwatchLaunchedByAgent YES`, so it restores no
    window) and waits up to 25 s, else
    "Pullwatch did not start in time. …".
  - When the app drops the connection (a Sparkle update), requests in flight
    get "Pullwatch closed the connection while answering. Try again.", and
    the helper reconnects once: it re-reads the mode, replays the agent's
    `initialize` under its own id, holds the agent's requests until that
    answer, then sends `notifications/initialized` and the held requests.
    The agent does not notice. A second drop is final.
  - When the app sends `notifications/pullwatch/disconnected` (Disconnect,
    Don't Allow), the helper drops it, does not reconnect, and answers every
    later request "Pullwatch disconnected this agent. …". Without this the
    reconnect-once would bring a refused agent straight back.
  - These messages are for the model, so they are English and not
    localised, like the tool descriptions.
- **Approval** (`Approval/MCPApproval`): until a client name
  (`clientInfo.name`) is in `AppConfig.approvedAgents`, every `tools/call`
  returns the tool error "Waiting for approval in Pullwatch: allow <Name> in
  the notification or under Settings, Agents." The session stays open, so
  allowing works at the next call. `tools/list` still answers on purpose:
  it holds no data, and clients fetch it once after the handshake
  (`listChanged: false`), so refusing it would leave an allowed agent without
  tools until it reconnects. The first `initialize` of an unknown name posts
  one notification (category `agent`, actions `allowAgent` and `denyAgent`).
  `MCPClientName` turns the name into what people know (`title`, then
  `claude-code` as Claude Code and the other known clients, then the raw
  name). The name is display and bookkeeping only, never a security check.

## Who may connect: the peer check

`MCPSocketServer` checks every accepted connection before it reads a byte
(`Transport/MCPPeerCheck`):

1. **Same user.** The folder is 0700 and `mcp.sock` 0600 (set before
   `listen`); `getpeereid` must return our uid.
2. **Our helper.** The peer's audit token (`LOCAL_PEERTOKEN`) gives its code
   through `SecCodeCopyGuestWithAttributes(kSecGuestAttributeAudit)`, checked
   with `SecCodeCheckValidity`. The audit token names that exact process, so
   a reused pid cannot slip in. `MCPPeerPolicy` decides:
   - **The app has a team** (Developer ID, Apple Development; read from the
     app's own signature): the peer must satisfy
     `identifier "nl.torrisi.pullwatch.mcp" and anchor apple generic and certificate leaf[subject.OU] = "<team>"`,
     carry that identifier and team, and must not be ad hoc. Another team,
     another program of the same team and an ad-hoc helper are refused. This
     is every release.
   - **The app has no team** (debug builds, CI's unsigned release build): a
     validly signed peer with identifier `nl.torrisi.pullwatch.mcp` (Xcode's
     ad-hoc signature of the helper), or the linker-signed ad-hoc
     `pullwatch-mcp` (what the linker writes with
     `CODE_SIGNING_ALLOWED=NO`). Unsigned code and other identifiers are
     refused. Such builds are for development only.
   - A team id that is not ten capitals and digits counts as no team, so
     nothing odd reaches a requirement string.
3. A refused peer is closed and logged (`Log(category: "MCP")`) with the
   reason.

`MCPLimits.standard` caps a message at 1 MiB and its nesting at 32 levels,
checked in `MCPBoundedTransport` and `LineFramer` before the SDK decodes
anything; a message over the limit gets `-32600` and the session goes on.

## The SDK

- The official [MCP Swift SDK](https://github.com/modelcontextprotocol/swift-sdk),
  pinned with `exact:` in `PullwatchKit/Package.swift` (0.12.1 today).
  `swift-log` is a direct dependency because the SDK's `Transport` protocol
  names its `Logger`. `PullwatchKit/Package.resolved` and the project's
  `Package.resolved` pin the same versions, and the acknowledgements
  (`NOTICE`, `Resources/Acknowledgements/`, `scripts/checks/acknowledgements.sh`)
  follow a bump. There is no protocol layer of our own.
- Protocol versions are the SDK's (`PullwatchMCPServer.protocolVersions`):
  2025-11-25, 2025-06-18, 2025-03-26 and 2024-11-05. A client asking for a
  newer one (2026-07-28) gets 2025-11-25; a test pins that. A newer version
  arrives with an SDK release.
- Two SDK gaps are worked around in `PullwatchMCPServer.swift` with public
  API only:
  1. A malformed `tools/call` (no `name`, `arguments` not an object) fails
     while the SDK decodes `CallTool.Parameters`, and the SDK reports that as
     `-32603` (internal error); the spec wants `-32602`. `LenientCallTool`
     registers `tools/call` with the parameters as a plain `Value` and reads
     them itself.
  2. `Server.Configuration.strict` refuses a request before `initialize` by
     throwing inside a task whose error is dropped, so the client never gets
     an answer and hangs. We use `.default` and gate `tools/list` and
     `tools/call` on our own `Handshake`, with a real `-32600`.
  When an SDK release fixes either, drop the workaround and keep its test.
- In Xcode, the SDK's packages build with `-suppress-warnings`, so
  `SWIFT_TREAT_WARNINGS_AS_ERRORS` lives in the project's configurations and
  is never passed to `xcodebuild` on the command line (CLAUDE.md, Gates).

## The tools

`PullwatchMCPTools.all(dataSource:)` registers, in this order:
`get_status`, `list_pull_requests`, `get_pull_request`, `list_tags`,
`list_repositories`, `get_repository_report`, `list_vulnerabilities`,
`list_packages`, `explain_update` and `get_agent_brief`. The website's
Agents page documents each with its arguments and an example. Fields that
need care:

- **`reference`** (`MCPPullRequest`, in `list_pull_requests` and
  `get_pull_request`, required): `PullRequest.reference(_:)`, the number as
  the service writes it, `owner/name#1570` on GitHub, Bitbucket and Gitea,
  `group/project!42` on GitLab, `project/repo!42` on Azure DevOps.
- **`list_packages`** (`ListPackagesTool`, #170): one item per published
  package from `VersionReport.publishedPackageSummaries()`, with `name`,
  `type`, `account_id`, `owner`, `repository` (absent for Azure Artifacts),
  `latest_version`, `published_at`, `visibility`, `url` (through
  `withoutCredentials`), `recent_versions` (`version`, `published_at`,
  `url`, `tag`, `run_url`; at most 10), `used_by` (followed repositories
  only: `repository`, `versions` oldest first, `is_direct`) and
  `usage_known` (`false` for types the dependency check does not match,
  container images and Helm, so an empty `used_by` is not read as unused).
  Filters `repo` (resolved with `MCPFollowedRepos`, so an unfollowed
  repository is refused), `type`, `account_id`; paged. With the
  `packageRegistries` source off it returns no packages and names the
  source in `not_checked`; `needs_permission` lists each account whose
  registry answered `.needsPermission(reason:)`, with that reason. Packages
  of a repository that is no longer followed never appear.
- **`in_house`** (`MCPInHouse`, in `get_repository_report` per package and
  in `explain_update`, #171): `source`, `repository`, `owner`, `url`,
  `registry_url`, `status` (`checked`, `source_off`, `needs_permission`,
  `read_failed`, `unconfirmed`) and `reason`. When the registry was not
  read, `update` is `not_checked` and `not_checked` names the source or the
  missing permission, never up to date. The tools only read
  `PackageMetadata.inHouse`; which names stay out of public registries and
  OSV.dev is `VersionChecker`'s job (`VersionCheckerInHouseTests`,
  `VersionCheckerInHouseLockfileTests`). A name stays private only when
  Pullwatch can tell the package is yours: the account's registry lists it
  with evidence, or the lockfile gets it from the own registry of the
  repository's account (or an npm name with the owner's scope from a
  registry that is not the public one), whatever reading the registry did
  (#216). Without a registry in the lockfile the name can reach both; the
  website's Dependencies page lists the cases.

## Adding a tool

A tool is one type in `PullwatchKit/Sources/PullwatchMCP/Tools/`, with a
`make(_ source: any MCPDataSource) -> MCPTool` and a `run`, added to
`PullwatchMCPTools.all(dataSource:)` in the order `tools/list` should show.

- `MCPTool`: `name` (snake_case, 1 to 128 of `A-Z a-z 0-9 _ - .`), `title`,
  a `description` in English that says what it returns, when to use it and
  its filters, `input` and `output` as `MCPSchema`, `annotations`
  (`MCPTool.readOnly` by default) and the handler.
- `MCPSchema` (`.object`, `.string(oneOf:maxLength:)`, `.integer(minimum:maximum:)`,
  `.boolean`, `.array(of:)`, `.dateTime`) renders the JSON Schema the agent
  sees and validates the arguments with the same description, so the two
  never drift. Objects refuse unknown fields. The handler only gets
  arguments that fit; its output is checked against the output schema.
- Return `MCPToolOutput.result(output, summary:)`: an `Encodable` becomes
  snake_case JSON with ISO 8601 dates, plus a one-line English summary. Throw
  `MCPToolError("…")` for something the model should read and act on (it
  becomes `isError`); any other error becomes a generic error and goes to the
  log without its details.
- New data comes through `MCPDataSource` (async accessors returning
  PullwatchCore values) and its app side in `AppMCPDataSource`; the tests'
  `FakeDataSource` gets the same accessor.

The rules every tool keeps, each covered by `ToolRulesTests` or the tool's
own tests:

- **Read-only.** A tool reads what Pullwatch already fetched: no network
  call, no poll, no write to the app's state or to any service. An action
  (mark as read, refresh, check a repository) may only come behind a
  separate, default-off setting "Allow agents to take actions", with its own
  annotations, and even then never writes to GitHub, Azure DevOps or GitLab.
- **No secrets.** `MCPDataSource` has no accessor for a token, a Keychain
  item or a secret value, and must not get one. Accounts appear as id,
  service, name and host. Every URL goes through `withoutCredentials`.
  Co-authors have no e-mail address; secret scanning is a count.
- **Sources that are off.** Wherever a switched-off source would have
  answered, say so with `MCPSourceOff` ("Not checked: source X is off.") in
  `not_checked`, a `not_checked` status or `checked: false`. Never return
  that as clean or current.
- **Paging.** A list takes `MCPPaging.inputFields` (`limit`, default 25,
  at most 100, and `cursor`) and returns `total` and `next_cursor`.
- **Followed repositories only.** Resolve `repo` with
  `MCPFollowedRepos.resolve`, which refuses an unknown or no longer followed
  repository with the message that points at `list_repositories`, and asks
  for `account_id` when two accounts follow the same name.
- Titles and descriptions written by others are marked as data, not
  instructions, in the schema descriptions.

Then: add the tool to `ToolRulesTests.names` (and to the secret-leak calls
there) and to the hosted `AppMCPDataSourceTests`, document it with its arguments and an example on
the website's Agents page in all four languages, and add a changelog
fragment.

## Testing

- **In memory.** `PullwatchMCPTests` uses the SDK's `InMemoryTransport` and
  `Client` for the handshake and tools, `RawSession` for what the `Client`
  cannot send (malformed requests, requests before `initialize`), and
  `ToolHarness` to call a tool through `MCPToolRegistry.call`, so every
  output is also checked against its schema. Fixtures live in
  `Support/FakeDataSource.swift`.
- **Socket and helper.** `Transport/` tests run real Unix sockets in a
  temporary folder, `MCPBridgeTests` runs the bridge against a real
  `MCPSocketServer` and a scripted app, and the hosted `AgentServerTests`
  spawns the built `Contents/Helpers/pullwatch-mcp` against a socket with
  the real peer check.
- **End to end by hand.** Build Debug into a scratch derived-data folder,
  then run the app straight from its bundle (not through `open`, which could
  reach an installed Pullwatch) with its own data folder and fake GitHub:

  ```sh
  DATA=/tmp/pwmcp      # short: a socket path has at most 104 bytes
  mkdir -m 700 "$DATA"
  # config.json: a GitHub account, "agentAccess":"whileOpen", "approvedAgents":["claude-code"]
  "$APP/Contents/MacOS/Pullwatch" -PullwatchDataDirectory "$DATA" -PullwatchFakeGitHub YES \
    -PullwatchFakeData YES -PullwatchEphemeralSecrets YES -PullwatchSkipNotificationRequest YES &
  {
    echo '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"claude-code","version":"1"}}}'
    echo '{"jsonrpc":"2.0","method":"notifications/initialized"}'
    echo '{"jsonrpc":"2.0","id":2,"method":"tools/list"}'
    echo '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"list_pull_requests","arguments":{"limit":3}}}'
    sleep 3
  } | "$APP/Contents/Helpers/pullwatch-mcp" -PullwatchDataDirectory "$DATA"
  ```

  The data folder must be short: `-PullwatchDataDirectory` under a long
  scratch path makes `mcp.sock` longer than `sun_path` allows, and
  `UnixSocket` refuses it. Use another `clientInfo.name` to see the waiting
  message, and change `agentAccess` to see the helper's own answers. Stop
  only the app you started, by its pid; never touch
  `/Applications/Pullwatch.app` or `~/Library/Application Support/Pullwatch`.
  `-PullwatchFakeAgents <n>` (debug) shows fake sessions in Settings, Agents
  and the menu panel for screenshots.

## Release signing of the helper

`scripts/release/release.sh` signs inside out: Sparkle's parts, then
`Contents/Helpers/pullwatch-mcp` with hardened runtime, a timestamp and
`--identifier nl.torrisi.pullwatch.mcp`, then the app.
`codesign --verify --deep --strict` checks the whole, and the app's
notarisation covers the helper as nested code, so the maintainer configures
nothing extra ([setup.md](setup.md)). The identifier and the team are
exactly what `MCPPeerPolicy` requires, so a helper signed any other way
cannot connect to a release. CI's unsigned release build checks that the
helper is universal (`lipo`) and is in the DMG and the zip with its
identifier and hardened runtime.
