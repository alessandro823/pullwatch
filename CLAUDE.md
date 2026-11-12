# CLAUDE.md

Pullwatch is a macOS menu-bar app by Alessandro Torrisi that notifies about
new pull requests (Azure DevOps and GitHub) and tags, keeps a searchable
history, and checks repositories for outdated runtimes, packages and known
vulnerabilities. Apache-2.0. `README.md` is the short overview (at most 250
lines); the website in `site/` describes every feature; the design
of each part is in `docs/superpowers/specs/` and its plan in
`docs/superpowers/plans/` (both Dutch). Swift is written as
`.claude/rules/swift.md` says.

## Where the work happens

- `origin` = `alessandro823/pullwatch`, Alessandro's repository and the
  source of truth. We are collaborators with push access: every change goes
  there on its own branch and reaches `main` through a pull request
  (`gh pr create --repo alessandro823/pullwatch --base main`).
- **Never push to `main`, and never merge a pull request.** Alessandro
  reviews and merges each one himself; we open it and wait.
- `fork` = `Vernum-Projecten/pullwatch`, our fork. It keeps the tracker
  (issues and their relations, with the organisation's issue fields) and
  follows `origin/main` (`git push fork origin/main:main` after a fetch).
  A pull request links its issue as `Vernum-Projecten/pullwatch#<n>`.
- `gh repo set-default Vernum-Projecten/pullwatch` once per clone, so `gh`
  and `scripts/gh/*` act on the tracker; pass `--repo
  alessandro823/pullwatch` to every `gh pr` command.
- A new clone: `git clone https://github.com/alessandro823/pullwatch.git`,
  then `git remote add fork https://github.com/Vernum-Projecten/pullwatch.git`.

## Repository map

- `Pullwatch/`: the app. `Pullwatch.xcodeproj` (committed; synchronized
  folders, so adding a file needs no project edit; shared scheme
  `Pullwatch`). Settings: `App.xcconfig` (version, build number, bundle id),
  included by `Debug.xcconfig` (the test GitHub App "TEST Pullwatch" of
  Vernum-Projecten; then the optional, git-ignored `Local.xcconfig`) and
  `Release.xcconfig` (the maintainer's GitHub App). Never put the test app in
  `Release.xcconfig`.
  `Pullwatch/Pullwatch/`: one folder per feature, holding its `@Observable`
  model and its views (each type in its own file), as Apple's sample apps
  do. Every model is read by views from the environment.
  `App/`: the wiring. `PullwatchApp.swift` (four scenes: the
  `MenuBarExtra`, the main `Window`, the welcome `Window` that opens by
  itself on a first launch via `defaultLaunchBehavior`, and the `Settings`
  scene; `appModels(_:)` puts every model in each scene's environment),
  `AppDelegate` (starts the model, except as a test host), `WindowPresence`
  (shows the Dock icon while one of those windows is open), `AppModel.swift`
  (the composition root: creates the models once, starts the loop, and
  keeps the intents that span models), `AppServices` (the stores, the engine
  and the notifier) and `AppLanguage` (the language choice in General:
  follow macOS or a fixed language through `AppleLanguages`, applied by
  relaunching).
  `Navigation/`: `AppRouter` (windows, sidebar, paths, filters; `show(_:)`
  opens a window or section; `settingsTab`, a `SettingsTab` the Settings
  window binds its tabs to, and `showSettings(_:)` to open Settings on a
  tab; `SettingsTab.forNotification(_:)` opens Agents for the agent
  approval and Accounts for an expired token), `AppCommands` (the menu bar in Apple's order,
  one `Commands` type per menu: `AppMenuCommands`, `FileCommands`,
  `EditCommands`, `ViewCommands`, `GoCommands`, `ItemCommands`,
  `RepositoryCommands`, `WindowCommands`, `HelpCommands` with the URLs in
  `HelpLinks`; `MenuBarTests` checks the order and the key items),
  `Shortcuts` (the focused values the menus read: `browserTarget`,
  `repoTarget`, `readTarget`, `searchFocus`), `SearchShortcut` and
  `MainView` (sidebar: PRs, Tags, Branches, Statistics, Repos, Dependencies, Packages, ⌘1 to ⌘7). The Dock
  menu (Reload, Check All Repositories) is `AppDelegate.applicationDockMenu`.
  `MenuBar/`: `MenuBarLabel` (the menu-bar icon; it opens the windows the
  model asks for through `AppRouter.windowRequest`) and `MenuView` (the
  menu-bar popover; while an agent is connected its header has
  `MenuAgentsButton`, with `MenuAgentsSummary` and the list
  `MenuAgentsPopover`).
  `Accounts/`: `AccountsModel` (config, accounts, Keychain, GitHub sign-in),
  `GitHubSignIn` (the GitHub sign-in flow), `AccountEditor` and its rows.
  `Onboarding/`: `OnboardingView` with `OnboardingSteps`.
  `PullRequests/`: `HistoryModel` (history, read state, menu lists, Dock
  badge), `HistoryView`, `TagFilter` and the PR and tag pieces
  (`ChecksBadge`, `PRStatus`, `KindStyle`).
  `Repositories/`: `OverviewModel` (repo summaries and sidebar), `ReposView`,
  the models of the repository page (`RepoPage`, `RepoBriefs`,
  `RepoVersions+Clipboard`) and `RepoDetail/`: `RepoDetailView` with a file
  per tab (`RepoOverviewTab`, `RepoCheckTab`, `RepoDependenciesTab`,
  `RepoSecurityTab`), `RepoInspector` and `RepoDetailToolbar`; it puts the
  agent briefs behind the Overview headings and in the toolbar's More menu
  (`RepoBriefs`, one per section).
  `Dependencies/`: `VersionsModel` (the version check, the stored report and
  the one the screens show without the data of sources that are off),
  `PackagesView` and `PackageRows`.
  `Packages/`: the Packages section (what followed repositories publish):
  `PublishedPackagesView`, its cells, `PublishedPackageInspector` and the
  symbol per type (`PublishedPackageType+Display`; `simpleIcon` names the
  ecosystem logo from simple-icons-swift for every type that has one (an
  app-only dependency pinned exactly in the project), and
  `PublishedPackageTypeIcon` draws it at symbol size, else the SF Symbol;
  never `SimpleIcon.allCases`, which puts every icon in the app).
  `Security/`: the vulnerability table and its cells, `AdvisoryInspector`.
  `Statistics/`: `StatsView` and its charts.
  `Branches/`: `BranchesModel` (pushes to branches of followed repositories,
  kept in `branches.json`, no notifications and not unread), `BranchesView` (the sidebar section: search, repo and person
  filters, "Alleen anderen"), `BranchFilter` and `BranchKindLabel`; the
  types and the log (`BranchPush`, `BranchHead`, `BranchLog`) are in `PullwatchCore/Branches/`
  and each provider reads heads in its `+Branches` file.
  `Notifications/`: `NotificationsModel`, `Notifier`, `NotificationGlyph`,
  the notification content and the Notifications settings.
  `Settings/`: `SettingsView` (the Settings window: Accounts, Notifications,
  General with the language choice, Sources, and Agents from `Agents/`), `SourcesSettingsView` (the
  Sources tab: every outgoing connection, switches for the data sources,
  **Copy overview**) and `SourceStatusParts` (the "Niet gecontroleerd: bron
  … staat uit" texts).
  `Polling/`: `PollingModel` (one poll, statuses, refetch).
  `Updates/`: `UpdatesModel`, `Updater` (Sparkle 2: updates in the app when
  the build has `SPARKLE_PUBLIC_ED_KEY`) and `AboutView` (the About window).
  `Acknowledgements/`: `AcknowledgementsModel` and the Acknowledgements
  window (opened from About and Help), reading
  `Resources/Acknowledgements/` (an explicit folder in the project, so it
  lands whole in `Contents/Resources/Acknowledgements/`): `LICENSE`, `NOTICE`
  (copies of the root files), `acknowledgements.json` and one licence file
  per component, copied verbatim from the package checkouts. A dependency
  change updates them; `AcknowledgementsTests` and
  `scripts/checks/acknowledgements.sh` (with
  `acknowledgements-not-linked.txt`) fail otherwise.
  `Agents/`: `AgentServer` (the MCP socket for coding agents: listens while
  `AppConfig.agentAccess` is not `never`, never as a test host; `sessions`
  lists the connected agents with the client name, title and version from
  `initialize`, `connectedSince`, `lastTool` and `lastActivity`;
  `disconnect(id:)`; the approval per client name: `approvedAgents` (kept in
  `AppConfig.approvedAgents`), `pendingAgents`, `allow`, `deny`,
  `removeApproval`, and a notification with Allow and Don't Allow the first
  time a client shows up), `AppMCPDataSource` (the `MCPDataSource` over the
  models, read live on every call; the tools are `AppModel.mcpTools()`),
  `AgentClient` (the setup command or JSON per client with the helper path
  of the running app) and the Settings tab `AgentsSettingsView` with its rows.
  `General/`: what two or more features use (`Pasteboard`, `CopyButton`
  with `AgentBriefButton`, `AgentBriefMenu`, `FilteredEmptyView`, `Pill`,
  `AddButton`).
  `Debug/`: debug-only tooling: `FakeGitHub` and `FakeWorld` (a GitHub
  without network and its repositories, for the UI tests and the camera
  tours), `SnapshotCamera`, `SnapshotTour`, `NotificationPreviewGallery` and
  `FakeAgents` (`-PullwatchFakeAgents <n>`: fake agents in Settings, Agents for
  the camera, with `-PullwatchOpenSettings YES -PullwatchSettingsPane agents`).
  At the top: `Localizable.xcstrings`
  holds the app's text in nl, en, de and fr; `Info.plist` holds only what the
  generated one cannot (`CFBundleLocalizations`). `AppIcon.icon` is the
  app icon, an Icon Composer bundle (`icon.json` plus one SVG per layer in
  `Assets/`); edit it in Icon Composer or by hand, and check it with
  `ictool` (inside Icon Composer) in light, dark, tinted and clear.
  `Pullwatch/PullwatchTests/`: hosted Swift Testing suites for the built app
  (bundle id, menu-bar app, languages, translations complete, SF Symbols).
  While XCTest hosts the app, `AppDelegate` does not start polling and no
  socket opens. `AgentServerTests` runs the real helper against a socket in
  a temporary data folder.
  `Pullwatch/pullwatch-mcp/`: the command-line target `pullwatch-mcp`
  (bundle id `nl.torrisi.pullwatch.mcp`, hardened runtime, stripped in
  Release), embedded by the app's "Embed Helpers" phase in
  `Pullwatch.app/Contents/Helpers/`. An agent starts it with stdio
  (`claude mcp add --scope user --transport stdio pullwatch --
  /Applications/Pullwatch.app/Contents/Helpers/pullwatch-mcp`); `main.swift`
  only wires `MCPBridge` and `WorkspaceLauncher` (`NSWorkspace`, not
  activated). It honours `-PullwatchDataDirectory` and passes it on to an
  app it starts.
  `Pullwatch/PullwatchUITests/`: XCUITests that launch the app with an empty
  data folder (`-PullwatchDataDirectory <dir>`, read by `AppPaths`) and
  tokens in memory only (`-PullwatchEphemeralSecrets`, also implied by
  `-PullwatchFakeGitHub`; `SecretStores`), and walk
  the first-run onboarding in Dutch and English. In debug builds
  `-PullwatchSnapshotDirectory <dir>` makes the app draw its own windows to
  PNG (`Debug/SnapshotCamera.swift`), no Screen Recording permission needed;
  with `-PullwatchFakeGitHub YES -PullwatchFakeData YES
  -PullwatchSnapshotTour YES` and a `config.json` with a GitHub account in
  the data folder it walks every screen of the main window
  (`Debug/SnapshotTour.swift`; it writes each step's name to stderr, with
  `-PullwatchSnapshotTourInteract YES` it also sorts every column of each
  table both ways, scrolls and selects a row, and
  `-PullwatchSnapshotTourOnly a,b -PullwatchSnapshotTourRepeat <n>` repeats
  only those steps), and `-PullwatchOnboardingTour YES` every step of
  the welcome window. Comparing the PNGs of two builds pixel by pixel shows a
  refactor changed nothing; only clocks and time stamps differ.
- `PullwatchKit/`: the local Swift package (`Package.swift`), everything
  without a window, in seven modules under `Sources/`. The names start with
  `Pullwatch` so a module never shares its name with a type in it.
  `PullwatchCore/`, by area, with no provider API code: `Model/` (models,
  `AppConfig`), `Providers/` (the `PRProvider` and `TokenSource` protocols,
  `ProviderError`, `StaticTokenSource`, and `PageLink`, the one rule every
  provider pages by: a `next` link is followed only on https with the host
  and port of the account's API, otherwise paging stops), `Polling/` (`PollEngine`, backoff,
  notification planning, filters, seen state), `History/` (history,
  statistics, repo overview), `Versions/` (the version and vulnerability
  checks, in six parts: `Detection/` (stack and dependency detection,
  lockfiles, provenance), `Registries/` (package registries, metadata per
  version, end-of-life), `Updates/` (whether an update can go, what blocks
  it, and `Ranges/`, the version ranges per ecosystem),
  `Vulnerabilities/` (OSV, the GitHub Advisory Database, CVSS, the
  service's own alerts), `Check/` (`VersionChecker`, `VersionReport`,
  `VersionHistory`) and `Tables/` (the rows and tables of the repository
  page)), `Packages/` (what the accounts publish to their own registry:
  `PublishedPackage`, `PublishedVersion`, `PublishedPackageType`, the result
  per account `PublishedPackages` (`.packages`, `.needsPermission(reason:)`,
  `.notSupported`, `.failed`) and `AccountPackages`, filled by the daily
  version check through `PRProvider.publishedPackages(followedRepos:)` into
  `VersionReport.publishedPackages`), `DataSources/` (`DataSource` is the catalogue of data sources
  that can be switched off, vulnerability and version sources and the CI
  checks of pull requests; `SourcesOverview` lists every connection for the
  Sources tab and its copied overview), `AgentBrief/` (turns a section of
  the repository page into a Markdown brief for an AI agent), `Updates/` (`UpdateChecker`, `Appcast`, `UpdateFeed`), `Support/` (HTTP, processes, JSON
  store, Keychain and `SecretStores`, logging, localisation). `PullwatchGitHub/`:
  `GitHubProvider` (github.com, GitHub Enterprise Server and GHE.com through
  `GitHubEndpoints`), and in `Auth/` the GitHub App device flow and token store
  (`GitHubAppAuth`, `GitHubAppTokenRefresher`), the `gh` token source and
  `GhCLIAccounts`.
  `PullwatchAzureDevOps/`: `AzureDevOpsProvider` and the `az` token source.
  `PullwatchGitLab/`: `GitLabProvider` (gitlab.com and self-managed, REST v4)
  and the `glab` token source. `PullwatchBitbucket/`: `BitbucketProvider`
  (Bitbucket Cloud, REST API 2.0 on `api.bitbucket.org/2.0`; workspaces as
  owners, Basic auth with the Atlassian account's email (`Account.email`) and
  an API token with scopes from the Keychain, pages through `next` links on
  the API host only, the open pull requests of a repository asked again only
  when its `updated_on` moved or after `openRefresh`, build statuses as checks,
  tags without releases; no CLI token source). `PullwatchGitea/`:
  `GiteaProvider` (Gitea, Forgejo and Codeberg on the shared API v1,
  `<server>/api/v1`; one `ProviderKind.gitea` with `Account.giteaFlavour`
  (`GiteaFlavour`: codeberg.org, an own Forgejo server, gitea.com or an own
  Gitea server); organisations and users as owners, pull requests per
  owner from `/repos/issues/search?type=pulls`, pages through `Link` and
  `X-Total-Count` on the server only, commit statuses as checks, tags with
  releases, a 403 "required scope" as `ProviderError.missingScope`; token
  only, `tea` hands out no token). Each provider has the same layout: the
  provider itself (accounts, repositories, pull requests), `+Tags`, `+HTTP`,
  one file of DTOs, and a `+Area` file per further area (co-authors, files,
  checks, security, extra repositories, merge queues and trains,
  published packages).
  `PullwatchProviders/`: `ProviderFactory`, the only module that knows every
  provider. `PullwatchMCP/`: the MCP server for coding agents, on the
  official MCP Swift SDK (`modelcontextprotocol/swift-sdk`, pinned to an
  exact release in `Package.swift`): `MCPToolRegistry` holds the `MCPTool`s
  (an `MCPSchema` for input and output, a handler returning an
  `MCPToolResult`), `PullwatchMCPServer.start` serves them as an SDK `Server`
  named Pullwatch on any SDK `Transport`, wrapped in `MCPBoundedTransport`
  (`MCPLimits`: message size and nesting); invalid arguments come back as
  a tool error (`isError`), an unknown tool as `-32602`. `Tools/` holds the
  read-only tools (`get_status`, `list_pull_requests`, `get_pull_request`,
  `list_tags`, `list_repositories`, `get_repository_report`,
  `list_vulnerabilities`, `list_packages`, `explain_update`, `get_agent_brief`), one type per
  file, built by `PullwatchMCPTools.all(dataSource:)` over an
  `MCPDataSource` (async accessors for what the app's models hold: accounts,
  history, repo summaries, the shown version report, update contexts, poll
  states, sources that are off). They show only followed repositories,
  accounts as name and host, no credentials, "Not checked: source X is off"
  instead of clean, and page lists with `limit` and `cursor`.
  `Transport/`: the local connection. `MCPSocketServer` listens on
  `mcp.sock` in the data folder (`UnixSocket.url()`; folder 0700, socket
  0600, a stale socket removed, `MCPSocketListener`), checks every peer
  before reading a byte (`MCPPeerCheck`: same uid through `getpeereid`, and
  the code signature from the audit token judged by `MCPPeerPolicy`: with a
  team only `nl.torrisi.pullwatch.mcp` of the app's own team; without one,
  as in debug and CI builds, that identifier or the linker-signed
  `pullwatch-mcp`), and serves one `PullwatchMCPServer` per connection over
  `MCPSocketTransport` (newline-delimited JSON, `LineFramer` stops at
  `MCPLimits.maxMessageBytes`). `NonBlockingDescriptor` is the only wrapper
  of `FileHandle`'s readability and writeability callbacks. `Approval/`: `MCPApproval` (until a client name is
  approved, every `tools/call` is a tool error "Waiting for approval in
  Pullwatch: …"; `tools/list` still answers) and `MCPClientName` (the name
  people know: `title`, then known clients, then `clientInfo.name`).
  `MCPSocketServer.disconnect(id:)` first sends
  `notifications/pullwatch/disconnected`, so the helper does not reconnect.
  `Bridge/`: the
  helper's logic, `MCPBridge`, per `AgentAccess` (`never`: every request
  gets "Agents are turned off in Pullwatch: Settings, Agents";
  `whileOpen`: without a socket "Open Pullwatch to use it from an agent.";
  `always`: starts Pullwatch through `PullwatchLaunching` and waits up to
  10 s), reconnecting once with a replayed handshake when the app restarts,
  and never after `notifications/pullwatch/disconnected` ("Pullwatch
  disconnected this agent. …"). The app links it. `docs/mcp.md` has the
  architecture, the peer check, the SDK workarounds, how to add a tool and
  how to test it end to end.
  `PullwatchKit/Package.resolved` and the project's `Package.resolved` pin
  the same versions; a dependency change updates both. Every provider also reads the repositories a person adds by
  hand (`Account.extraRepos`, `PRProvider.checkRepository`), with an
  anonymous fallback for public repositories on github.com, gitlab.com and
  bitbucket.org only. The app links `PullwatchCore`, `PullwatchGitHub` (the sign-in
  screens), `PullwatchProviders` and `PullwatchMCP` (the helper only
  `PullwatchMCP`). Only what another module or the app
  uses is `public`; what only the package's own modules share is `package`.
  A module with text has its own `Localizable.xcstrings` and its own
  `Bundle.localized…` helper (`Support/Localization.swift`).
  `Tests/`: one Swift Testing target per module (`PullwatchCoreTests`,
  `PullwatchGitHubTests`, `PullwatchAzureDevOpsTests`,
  `PullwatchGitLabTests`, `PullwatchBitbucketTests`, `PullwatchGiteaTests`,
  `PullwatchProvidersTests`,
  `PullwatchMCPTests`),
  and `PullwatchTestSupport` with the shared
  `MockHTTPClient`, `MockProcessRunner`, `InMemorySecretStore`, `TestClock`
  (starting at `Date.testStart`), `CLILocator.homebrew` and `.nothing`,
  `expectCalledHostsAreListed` and fixtures; a helper only one target needs
  goes in that target's `Support/`. A test target mirrors its module's
  folders (`PullwatchCoreTests/Versions/Detection/`, `PullwatchMCPTests/Transport/`,
  `PullwatchGitHubTests/Auth/`), so a test sits where its subject sits.
- `docs/setup.md`: everything the maintainer configures outside the code
  (signing, the GitHub App, the release secrets), each with its steps;
  `docs/github-app.md`: the GitHub App for **Sign in with GitHub**. Keep both
  in step with the code. `docs/website.md`: the website on GitHub Pages, the
  `PAGES_DOMAIN` variable and the DNS of `pullwatch.net`. `docs/mcp.md`: the
  MCP server for coding agents, for developers (the user's side is the
  website's Agents page, `site/src/content/docs/agents.md`).
  `docs/superpowers/`: Alessandro's design specs and plans (Dutch).
- `site/`: the website, an Astro Starlight project (`site/README.md`): the
  landing page (`src/content/docs/index.mdx` with the components in
  `src/components/`) and the user documentation in English
  (`src/content/docs/`, the root locale) and in Dutch, German and French
  (`src/content/docs/<lang>/`, same slugs, UI names from the String Catalogs,
  checked by `scripts/check-terms.py`; the landing page's own text in
  `src/content/i18n/<lang>.json`), with screenshots from the camera tour in
  `src/assets/screenshots/` and `src/assets/screenshots/<lang>/` (light and
  dark, fake data only). Versions pinned
  exactly with a committed `package-lock.json`; Node from `site/.nvmrc`.
  `astro.config.mjs` takes `site` and `base` from `PAGES_DOMAIN`; a Markdown
  link is written from the site root (`/using/menu/`) and gets the base from
  `src/plugins/base-links.mjs`. `npm run build` also makes the Pagefind index
  and validates the Markdown links; `npm run check-links` follows every link
  in `dist/`. Keep its pages in step with the app; a detail that leaves
  the README lands here. README images live in `docs/images/`.
- `.github/workflows/`: `ci.yml` (every pull request and push to `main`:
  shellcheck and actionlint, `swift test`, `xcodebuild test` with the unit
  and UI tests, `release.sh --unsigned` with a universal check of the app
  and `pullwatch-mcp`, and the helper in the DMG and zip; no secrets),
  `changelog.yml` (the changelog fragment guard on every pull request, also
  when a label is added or removed, so `no-changelog` set after opening
  counts without a new push), `site.yml` (a pull request or push that
  touches `site/`: both builds of the website and their links; on `main` in
  `alessandro823/pullwatch` only, also the deploy to GitHub Pages) and
  `release.yml` (a `v*` tag: check, sign, notarise, package, draft
  release). `.github/actionlint.yaml` names the `xcode-27` runner label.
  `CHANGELOG.md` (Keep a Changelog) gives each release its notes, assembled
  from the fragments in `changelog.d/`.
  `docs/releasing.md`: the release procedure and its Actions secrets.
- `scripts/release/release.sh [--unsigned]`: Release build (universal), and
  with a Developer ID also signing (inside out: Sparkle, the
  `pullwatch-mcp` helper with its own identifier, the app), notarisation and
  stapling of the app and the DMG; local (notarytool profile) and in `release.yml` (API key in
  `NOTARY_KEY_FILE`). `package.sh <app> <version> <out-dir>` makes
  `Pullwatch-<version>.dmg` (the install window: background from
  `dmg-background.swift`, icons placed by Finder through AppleScript) and
  `Pullwatch-<version>.zip`. The icon positions in both files must match.
  `check-version.sh vX.Y.Z` (tag, `MARKETING_VERSION`, build number and
  changelog agree, no fragment left), `notes.sh vX.Y.Z` (the changelog
  section), `changelog.sh` (`--check`, `--preview`, `--assemble` of the
  fragments), `protect-tags.sh` (the `v*` tag ruleset), `verify-update.swift`
  (checks the signed appcast and zip against the app's public key).
- `scripts/checks/changelog-guard.sh`: the changelog fragment guard CI runs
  on every pull request (`--self-test` proves it).
  `scripts/checks/acknowledgements.sh`: every pin in `Package.resolved` is
  in the acknowledgements manifest with its version or in
  `acknowledgements-not-linked.txt` with a reason, and `NOTICE` names each
  (`--self-test`; CI's guards job). `changelog.d/`: the
  fragments of the next release and their format (`README.md`).
- `scripts/gh/`: tracker helpers (copied from FerroLICENCE): `fields.sh`
  (issue type, Priority, Effort), `rel.sh` (sub-issues and blocked-by),
  `labels.sh` (the label set). `scripts/dev/xcode-skills.sh` exports
  Apple's Xcode agent skills into `.claude/skills/`; `sync-strings.sh` (with
  `catalog-tidy.py`) writes the extracted text into the String Catalogs.
- `.githooks/`: `pre-commit` (refuses private keys, tokens, certificates)
  and `commit-msg` (strips AI attribution). Install once per clone:
  `git config core.hooksPath .githooks`.

## Hard rules

- **Never push to `main` or merge a pull request.** Push a branch to
  `origin` and open a pull request in `alessandro823/pullwatch`; Alessandro
  merges. The Claude Bash hook refuses a push to `main`, `gh pr merge` and a
  pull request opened anywhere else.
- **No secrets in the tree.** Tokens live in the Keychain; the Developer ID
  certificate, the notarisation credentials and Sparkle's private
  key are Alessandro's and live in Actions secrets and his Keychain. The
  pre-commit hook and the Claude `protect_secrets.sh` hook refuse them.
- **The bundle id stays `nl.torrisi.pullwatch`.** Changing it loses every
  user's settings, notifications permission and Keychain tokens.
- **The app supports macOS 26.6 and later, universal (Apple Silicon and
  Intel).** One deployment target, set at the project level and in
  `PullwatchKit/Package.swift`; never per target.
- **Every user-facing string in all four languages** (nl, en, de, fr).
- **Every MCP tool is read-only.** A tool reads what Pullwatch already
  fetched: no network call, no poll, no change to the app's state, and never
  a token, Keychain item or secret value. An action (mark as read, refresh,
  check a repository) only comes behind a future, default-off switch "Allow
  agents to take actions", and even then never writes to GitHub, Azure
  DevOps or GitLab (`docs/mcp.md`).
- **Never weaken, skip or delete a test** to make a build pass.
- **No AI attribution in commits, PRs or issues.** No `Co-authored-by`, no
  "Generated with", no robot emoji. The `commit-msg` hook strips it and the
  Claude Bash hook refuses the command.
- **A full makeover is allowed.** Refactor, rewrite, restructure and restyle
  any part of the app, Alessandro's code included, when it makes Pullwatch
  better; do not ask first. Keep each pull request about one thing, and keep
  Dutch comments and Xcode's formatting.
- **Prose has no AI tells**, in UI text, docs, commits and PRs: no em dashes,
  no middle dot "·" as a separator, no "not X but Y", no buzzwords. Write a
  phrase ("octo op GitHub"), use two lines, or separate labels instead.

## Gates (run before every commit)

The same as CI (`.github/workflows/ci.yml`), warnings as errors:

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
swift test --package-path PullwatchKit -Xswiftc -warnings-as-errors
xcodebuild test -project Pullwatch/Pullwatch.xcodeproj -scheme Pullwatch \
  -destination 'platform=macOS'     # unit and UI tests
shellcheck scripts/*/*.sh .claude/hooks/*.sh .githooks/*
actionlint
bash scripts/release/changelog.sh --check
bash scripts/dev/sync-strings.sh && git diff --exit-code -- '*.xcstrings'
```

Warnings are errors in the app's targets through the project's
`SWIFT_TREAT_WARNINGS_AS_ERRORS`. Do not pass it to `xcodebuild` on the
command line: it then also reaches the MCP SDK's packages, which Xcode
builds with `-suppress-warnings`, and the build stops.

The UI tests take over the screen. On a Mac someone is working on, run
`-only-testing:PullwatchTests` and `xcodebuild build-for-testing` instead,
and let CI run the UI tests.

A UI change is looked at before it is called done: run the app (⌘R in Xcode),
open every screen it touches in light and dark mode, in Dutch and English,
at the smallest window size, and check for truncation and overflow. For the
onboarding, `TEST_RUNNER_PULLWATCH_SHOTS=<dir> xcodebuild test … -only-testing:PullwatchUITests`
saves every step as PNG per language. UI tests quit a running Pullwatch
(same bundle id) first.

After changing user-facing text, `bash scripts/dev/sync-strings.sh` writes the
new keys into every String Catalog (xcodebuild alone does not); add the
English, German and French for each before committing. `LocalizationTests`
fails while an entry misses a language, and CI's "String Catalogs in step
with the code" job fails when the script would still change a catalog.

## Formatting

Xcode's indentation (Ctrl-I), 4 spaces, as the code is now. There is no
`swift format` gate: FerroLICENCE's configuration would rewrite 779 lines in
43 files. Adopting a formatter is Alessandro's call.

## Workflow

The tracker is the fork's GitHub Issues (`Vernum-Projecten/pullwatch`). The
type (Bug, Feature, Task), the priority (Urgent, High, Medium, Low) and the
effort (High, Medium, Low) are GitHub's native issue type and the
Vernum-Projecten organisation's `Priority` and `Effort` issue fields, never
labels. File an issue with `scripts/gh/fields.sh new <type> <priority>
<effort> <gh issue create args>`, never a bare `gh issue create`. `Low` is
one sitting, `Medium` one pull request, `High` more than one. A Task carries
exactly one work-kind label (`documentation`, `chore`, `refactor`, `perf`,
`test`, `ci`); a Bug and a Feature carry none. Epics are parents
(`scripts/gh/rel.sh parent <child> <epic>`); order is `rel.sh blocked-by`.
Read an issue with `gh issue view <n> --json title,body,comments`.

A change lands in `alessandro823/pullwatch`'s `main` through a PR there,
merged by Alessandro, on a conventional-type branch (a Bug is `fix/`,
a Feature `feat/`, a Task its work kind), with conventional commit subjects
in English (`feat: …`, `fix: …`), as the history does. The PR body
says what changed and why, and links the fork issue
(`Vernum-Projecten/pullwatch#<n>`). Prefer what
FerroLICENCE (`~/RustroverProjects/FerroLICENCE`) already does and has
proven (icon, DMG window, Sparkle updater, CI, release lane) over designing
it again; each issue lists the files to copy.

## Releases

A tag `vX.Y.Z` on `main` runs `.github/workflows/release.yml`: it checks
that the tag, `MARKETING_VERSION` and a dated `CHANGELOG.md` section agree,
imports the Developer ID of Code24 BV from Actions secrets into a keychain
of its own, runs `scripts/release/release.sh` (sign, notarise, staple,
package), signs `appcast.xml` for the zip with Sparkle's key and checks
it against the app's public key, and attaches the DMG, zip and appcast to
a draft release with the changelog section as notes (a tag
`vX.Y.Z-beta.N` makes a pre-release on Sparkle's `beta` channel).
Alessandro checks the draft and publishes it; the app reads the latest
release's appcast once a day and Sparkle installs the update (without a
public key in the build, `UpdateChecker` shows a download button). The secrets are his and
exist only in his repository: in the fork the lane stops at once and names
the missing ones. `docs/releasing.md` has the procedure and the secret
names. `release.sh` on his Mac (notarytool profile `pullwatch`) still makes
the same files. Every change worth noting adds a fragment under
`changelog.d/` (`changelog.d/README.md`), never a line under `[Unreleased]`
in `CHANGELOG.md`: the `Changelog` workflow (`changelog.yml`, `scripts/checks/changelog-guard.sh`)
fails a pull request that writes there, and one that changes `Pullwatch/` or
`PullwatchKit/Sources/` without a fragment unless it has the `no-changelog`
label. The release branch runs `scripts/release/changelog.sh --assemble
X.Y.Z YYYY-MM-DD` before the tag.
