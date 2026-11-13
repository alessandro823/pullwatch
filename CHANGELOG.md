# Changelog

All notable changes to Pullwatch are recorded here. The format follows
[Keep a Changelog 1.1.0](https://keepachangelog.com/en/1.1.0/) and the app
follows [Semantic Versioning](https://semver.org/). Each released section
becomes the notes of its GitHub release (`scripts/release/notes.sh`);
`docs/releasing.md` describes how a release is cut. Changes since the last
release wait as fragments in `changelog.d/` until the cut writes them here.

## [Unreleased]

## [0.10.1] - 2026-11-13

### Changed

- SwiftLog, used inside the MCP Swift SDK for the agent connection, is updated to 1.17.0 (#8).
- The Branches section shows GitHub's git-branch icon, as on GitHub (#14).

## [0.10.0] - 2026-11-12

### Added

- A Branches section in the main window, after Tags, shows pushes to branches of the repositories you follow: who pushed, how many commits, a force push or a new branch, and when. Search, filter by repository or person, or hide your own pushes; double-click opens the comparison in the browser. It sends no notifications. Branches follow along with pull requests and can be switched off per repository (#9).
- Repositories that an account's token can't read are no longer skipped silently. Settings, Accounts shows how many there are on the account and lists them, with what to do (for a gh account: pick the login that can read them); the repository page and the Latest tag column in Repos mark them, and agents see them in get_status and list_repositories (#10).

## [0.9.1] - 2026-11-08

### Thank you again, Ruben

This release was built by **Ruben Talstra** (@rubentalstra) in [Vernum-Projecten/pullwatch](https://github.com/Vernum-Projecten/pullwatch) once more: drafts back in the lists with their own switches, queued only in a real merge queue, shorter repository names under a filter and the Dock badge that shows again. Thank you!

### Changed

- Under the filter of one organization, user or project in the sidebar, the Repository column of the pull request and tag lists shows the repository without that name in front (`specifications #12` instead of `openEHR/specifications #12`). The tooltip still gives the full reference (#245).
- The notification for a pull request that will no longer merge by itself shows the amber arrow only when it left a merge queue or merge train; when auto-merge or auto-complete was turned off it shows the arrow in the colour of open, as the lists show that pull request. Its setting is now called **Pull requests that stop merging by themselves** (#258).

### Fixed

- A pull request shows as queued only while it is really in a merge queue (GitHub, Bitbucket Cloud) or merge train (GitLab), as GitHub shows it. With only auto-merge (GitHub, GitLab) or auto-complete (Azure DevOps) on, it stays open until it enters the queue. Agents see the same in the `queued` state (#242).
- Draft pull requests now appear in the PR list, the repository pages, the menu and the statistics, with the draft icon, as on GitHub. Each account has two switches: **Show draft PRs** (on by default) hides drafts everywhere when off, and a pull request then arrives once it is ready for review; **Notify about draft PRs** (off by default) also notifies about a new draft (#247).
- A pull request that changes between draft and ready for review now changes its icon too; the history kept the state it first saw (#247).
- The red badge with the number of unread pull requests and tags shows on the Dock icon again when a Pullwatch window opens. Before, it stayed empty until the count changed (#251).
- Turning **Show draft PRs** off now also removes the drafts already listed, and **Notify about draft PRs** turns off with it. A pull request that changes between draft and ready for review changes its icon at the next poll, also when you were notified about it, and turning draft notifications on or off no longer reloads the whole history (#254).

## [0.9.0] - 2026-11-05

### Thank you again, Ruben

This release was built by **Ruben Talstra** (@rubentalstra) in [Vernum-Projecten/pullwatch](https://github.com/Vernum-Projecten/pullwatch) as well: the answers to the review of 0.8.0, a notification when a pull request leaves the merge queue, the logos of package ecosystems, a smaller download and a tighter hold on where your token and your private package names go. Thank you!

### Added

- A notification when an open pull request leaves the merge queue or merge
  train, or loses auto-merge or auto-complete, without merging: on GitHub
  (with the reason GitHub gives), GitLab, Azure DevOps and Bitbucket Cloud.
  It has its own switch in Settings, Notifications, on by default, follows
  the bell of each repository, and never fires for a pull request that
  merged, closed or became a draft. Agents see it as `left_queue` in
  `get_pull_request`. GitHub pull requests with auto-merge on now show as
  Queued too (Vernum-Projecten/pullwatch#236).

### Changed

- Packages shows the logo of a package's ecosystem next to its name and in the inspector, from Simple Icons: npm, container images, Docker, NuGet, Maven, RubyGems, PyPI, Helm, Composer, Conan, Go, Terraform and Cargo (the Rust logo). Generic and Universal packages keep their symbol (Vernum-Projecten/pullwatch#221).
- The download is smaller: the app no longer carries its debugging symbols,
  which made up more than half of the program itself (Vernum-Projecten/pullwatch#230).

### Fixed

- A dependency only counts as in-house when its lockfile shows it comes
  from your own registry (or it is an npm name with your scope), not just
  because one of your repositories publishes a package with the same name.
  A public package that shares a name with one of yours stays public, so
  its known vulnerabilities are reported again, and OSV.dev still checks an
  in-house package whose name the public registry also knows. In-house
  status ends when the publishing account is removed or paused (Vernum-Projecten/pullwatch#214).
- A package from your own registry whose versions could not be read, or
  that has no version, no longer counts as an in-house package that is up to
  date. It now keeps the latest version from the previous check, or gets the
  public lookup and vulnerability check like any other package. A name that
  only your own registry knows is still never sent anywhere: it shows "Not
  checked" with the reason that the registry gave no latest version (Vernum-Projecten/pullwatch#215).
- A package whose lockfile gets it from your own registry no longer reaches
  a public registry or OSV.dev when Pullwatch could not read that registry:
  on a first check where reading failed, with the source Package registries
  of your accounts off, without permission to read the registry, on Gitea,
  Forgejo, Codeberg and Bitbucket, or when the repository that publishes it
  is not followed. It shows as in-house and not checked instead. The
  Dependencies and Agents pages now list exactly which names stay private
  and which can still reach public services (Vernum-Projecten/pullwatch#216).
- Your token now only goes to the server of your account. Pullwatch no longer
  follows a link to the next page of GitHub security alerts or packages when
  it points to another host, and an account whose server address is missing
  or is not an https address (for example one edited by hand in the settings
  file) is no longer checked: its card in Settings, Accounts says what to fix (Vernum-Projecten/pullwatch#217).
- A Bitbucket account without the email address of its Atlassian account is
  no longer checked and failing on every refresh. Settings and the menu say
  the email address is missing until you fill it in (Vernum-Projecten/pullwatch#218).
- A Bitbucket API token without a scope Pullwatch needs now says which scope
  is missing, instead of "Token invalid or expired" (Vernum-Projecten/pullwatch#218).
- An Azure Artifacts package whose newest version is a pre-release no longer shows that pre-release as its latest version: the highest stable release is the latest, as for container images, and the newer pre-release is mentioned next to it. Dependencies on the stable release no longer read as behind (Vernum-Projecten/pullwatch#219).
- A package in GitHub Packages or the GitLab Package Registry with more than ten pre-releases newer than its last stable release no longer shows a pre-release as its latest version: the stable release stays the latest, and the newest pre-release is mentioned next to it, as for Azure Artifacts and container images (Vernum-Projecten/pullwatch#229).
- The tooltip of **In-house** only says the latest version comes from your
  own registry when Pullwatch read it there. Otherwise it says who publishes
  the package, that it was not checked and why, as the line next to it does (Vernum-Projecten/pullwatch#231).
- Relative times such as "5 minutes ago" now keep up by themselves: the When
  column of the pull request list, the menu, the last poll per account, the
  repository overview, Dependencies, Packages and the connected agents no
  longer stay at the time they were first drawn until the pointer moves over
  them (Vernum-Projecten/pullwatch#238).

## [0.8.0] - 2026-11-04

### Added

- Coding agents such as Claude Code, Codex, Cursor and VS Code can ask Pullwatch about your pull requests and their checks, tags, repositories, outdated packages, vulnerabilities and what holds an update back, over MCP. Turn it on in Settings, Agents (off by default; Pullwatch can also start in the background when an agent asks), where you also find the setup command or JSON for each agent. Agents only read what Pullwatch already fetched, see only the repositories you follow, never get a token, and cannot change anything on GitHub, Azure DevOps or GitLab (Vernum-Projecten/pullwatch#139).
- Pullwatch asks once, in a notification, before a new agent gets any data, and Settings, Agents lists the agents you allowed and the ones connected now, with Disconnect. While an agent is connected, the menu panel shows an agents button, with an orange dot when one waits for your approval (Vernum-Projecten/pullwatch#139).
- A new section, Packages (Command-6), lists what the repositories you
  follow publish to the registry of their own service: npm, NuGet, Maven and
  other packages and container images from GitHub Packages, GitLab and Azure
  Artifacts. One row per package with its latest version and which of your
  repositories use it; the inspector shows the recent versions and who is on
  which one. A repository's Overview names what it publishes, and a new
  notification, off by default, tells you about a new version of your own
  packages. Agents can ask for the same with the new `list_packages` tool (Vernum-Projecten/pullwatch#167).
- A dependency that one of your repositories publishes now gets its latest
  version from your own registry and says In-house, instead of being
  unknown. Its name is never sent to a public registry or OSV.dev. Settings,
  Sources has a switch for the package registries of your accounts (Vernum-Projecten/pullwatch#167).
- The repository page's Packages tab is now called Dependencies, the same
  as the section in the sidebar (Vernum-Projecten/pullwatch#167).
- Codeberg, Forgejo and Gitea accounts: one card in the welcome window with a
  button for each, for codeberg.org, your own Forgejo server, and gitea.com or
  your own Gitea server. Pullwatch follows the pull requests (drafts
  included), tags and releases of the organisations and users you choose,
  shows the commit statuses as checks, checks the dependencies, and reads a
  public repository without signing in where the server allows it. Sign in
  with a token with the scopes read:user, read:organization,
  read:repository and read:issue; Test connection names a missing scope, an
  unknown owner, an address that is no Gitea or Forgejo, and a certificate
  macOS does not trust (Vernum-Projecten/pullwatch#176).
- Bitbucket Cloud accounts: follow the pull requests and tags of the
  repositories in your workspaces on bitbucket.org, with their build statuses
  as checks, co-authors from the commits, the dependency check and single
  public repositories from other workspaces. Sign in with an Atlassian API
  token with read scopes and the email address of your Atlassian account.
  Bitbucket has no releases, so Tags and Releases shows only tags for these
  accounts (Vernum-Projecten/pullwatch#177).
- Pull requests show their number as the service writes it: `#1570` on
  GitHub, Bitbucket, Gitea, Forgejo and Codeberg, `!42` for GitLab merge requests and Azure DevOps pull
  requests. The Repo column of the list shows the repository in full,
  `FerroHEALTH/FerroFED #1570`, and sorts a repository's pull requests by
  number, the menu panel and the repository
  page show the number, and a notification names
  `FerroHEALTH/FerroFED #1570`. Search finds a pull request by `1570`,
  `#1570`, `!42`, `FerroFED#1570` or `FerroHEALTH/FerroFED#1570`. Item, Copy
  Reference (Option-Shift-Command-L) copies `FerroHEALTH/FerroFED#1570`, and
  agents get the same `reference` from `list_pull_requests` and
  `get_pull_request`. The pull requests on a repository page show their
  state with the same icon as the list instead of a text label (Vernum-Projecten/pullwatch#193).

### Changed

- The welcome window's account choice is clearer: GitHub, Azure DevOps and
  GitLab each get a card of the same shape with a button per place your
  account can live (GitHub.com or GitHub Enterprise, dev.azure.com, GitLab.com
  or your own server), centred in the window. GitLab accounts now show
  GitLab's logo there, in Settings and in the add-account menu, which also
  offers GitLab Self-Managed (Vernum-Projecten/pullwatch#174).
- A complete menu bar in Apple's order instead of one Go menu that held everything: File (New Account…, Watch a Repository…, Open in Browser), Edit with Find, View with the sidebar, toolbar, Reload and full screen, Go, Item (read and unread, Copy Link), Repository, Window with Pullwatch (⌘0), and Help with the documentation, keyboard shortcuts, release notes, a link to report an issue and the acknowledgements. Check for Updates… is in the Pullwatch menu, and the Dock icon's menu offers Reload and Check All Repositories (Vernum-Projecten/pullwatch#179).

### Fixed

- Bots such as `github-actions[bot]` and `renovate[bot]` now show their own picture next to their pull requests. Pullwatch uses the picture GitHub and GitLab send with each pull request instead of guessing one from the name; pull requests already in the history get it at the next poll (Vernum-Projecten/pullwatch#150).
- The app now includes the licenses of the open-source software it uses (Sparkle, the MCP Swift SDK with SwiftLog, Swift System and EventSource, and GitHub Octicons), next to its own license and NOTICE. Read them under About Pullwatch, Acknowledgements, or Help, Acknowledgements (Vernum-Projecten/pullwatch#166).
- Rust packages get an update status again: Pullwatch reads the requested
  range from every `Cargo.toml` of a workspace, including the
  `[workspace.dependencies]` that members take over with `workspace = true`,
  renamed packages, dev, build and target-specific dependencies. A status
  that stays unknown now says why (no latest version, no requested range,
  a range it cannot read), in the app and for agents (Vernum-Projecten/pullwatch#187).
- A vulnerable package that only comes in through another package can be
  found and explained: Dependencies lists it under "Only transitive, with a
  vulnerability" with the chain that pulls it in, and `explain_update` and
  `get_repository_report` explain it too, including whether the fix only
  changes the lockfile or needs a newer parent first. A version check made
  by an older Pullwatch runs again by itself (Vernum-Projecten/pullwatch#187).
- Leaving a pull request or tag list that was filtered on an author or a
  repository no longer reloads that list while it closes, which made macOS
  log a warning about the table that a future macOS turns into a crash (Vernum-Projecten/pullwatch#204).

## [0.7.0] - 2026-11-04

### Thank you again, Ruben

Once more nearly everything in this release was built by **Ruben Talstra** (@rubentalstra) in [Vernum-Projecten/pullwatch](https://github.com/Vernum-Projecten/pullwatch): CI checks and the merge queue on every pull request, redesigned notifications, a cleaner repository page, where each vulnerability comes from, what blocks a package update, and a thorough tidy-up of the code underneath. Thank you, Ruben! 🙏

### Added

- Dependencies and the repository page show whether each package can be updated: a Status
  column with Up to date, Update within range (patch or minor), Major update or Blocked, and
  groups for Can update now, Needs a manifest change and Blocked. The repository page shows the
  newest version you can use now next to the newest version, and for a blocked package what holds
  it back and what to update first, such as "Held at 18.3.1 by react-dom, which asks for ^18.3.1.
  Update react-dom to 19.1.0 first." or "6.0.0 needs Node ^18.0.0 || >=20.0.0; the repository
  uses Node 16." (Vernum-Projecten/pullwatch#85)
- The fix line of a vulnerability says whether the fix is within range, needs a manifest change,
  or is blocked, and what to update first. Copied repository text and notifications say the same (Vernum-Projecten/pullwatch#85).
- The sidebar badge of Dependencies counts only updates you can take now and security fixes (Vernum-Projecten/pullwatch#85).
- New setting in Settings, General: new-version notifications only for updates you can take now
  (on by default) (Vernum-Projecten/pullwatch#85).
- **Watch single GitLab projects you add yourself.** Under "Other
  Repositories" in a GitLab account's repository list, or with "Watch a
  Repository…", type `group/subgroup/project` or paste a link from
  gitlab.com or your own GitLab server. A public project your token can't
  read is read without signing in, when the server allows that. Each added
  project costs one request for its merge requests per poll (Vernum-Projecten/pullwatch#94).
- Every vulnerability shows where it comes from: the database that published it (RustSec,
  GitHub, PyPA, Go, NVD and more) next to its id, and an info button with all its ids as links
  (GHSA, CVE, RUSTSEC, GO, PYSEC), related ids, the references with the fix first, and the
  published and modified dates. The severity now comes from the best source: the CVSS 3.1 or
  4.0 vector in the advisory (Pullwatch computes the score), then the database's own rating,
  then GitHub's advisory, and the row says which one it was. Withdrawn advisories are left out
  and counted separately. The copied text and notifications read "RUSTSEC-2023-0071 (RustSec),
  also GHSA-… and CVE-…" (Vernum-Projecten/pullwatch#96).
- Rows and buttons in the menu-bar panel light up under the pointer, like
  macOS's own menu-bar panels, and the highlight fades in smoothly (Vernum-Projecten/pullwatch#106).
- Settings, Sources also lists the CI checks of pull requests, with a switch.
  When it is off, Pullwatch asks no server for the checks, hides the checks it
  fetched before and sends no notification about failed checks (Vernum-Projecten/pullwatch#114).
- Each pull request shows its checks (CI) like GitHub's list: an icon in the
  colour of the state (a green check, a red cross, an amber dot while checks
  run) and how many passed out of all of them, such as 4/8, in the PR list,
  the menu and a repository's pull requests. The tooltip and VoiceOver say it
  in words. Works for GitHub, Azure DevOps and GitLab; on GitHub the app's
  Checks and Commit statuses permissions (read) are needed, otherwise the
  repository page says Needs permission (Vernum-Projecten/pullwatch#114).
- An optional notification when the checks of one of your own open pull
  requests fail, off by default, under Settings, Notifications (Vernum-Projecten/pullwatch#114).
- Pull requests waiting to merge by themselves show as Queued, with GitHub's merge
  queue icon in GitHub's amber, in the pull request list, the menu bar, a repository's
  pull requests and the statistics (counted as open). On GitHub that is a pull request
  in the merge queue, with its position in the tooltip; on GitLab a merge request set to
  auto-merge or in a merge train; on Azure DevOps a pull request with auto-complete set.
  Entering the queue sends no notification (Vernum-Projecten/pullwatch#124).

### Changed

- Every PR author has a profile picture in the list, also without
  co-authors, as tags already did; bots show their own picture (Vernum-Projecten/pullwatch#49).
- The repository page is cleaner: tabs for Overview, Check, Packages and
  Security, and on Check and Packages counts at the top (vulnerabilities,
  outdated runtimes, packages you can update, blocked) that filter the tab.
  Runtimes and frameworks sit in a compact grid; vulnerabilities, packages and
  the service's own security findings are sortable tables with search and
  filters, one row per advisory with its installs underneath. Selecting a row
  opens an inspector with the summary, the severity and where it comes from,
  every id and link, the fix, the affected installs and buttons to open or
  copy the advisory. Space opens and closes the inspector (Vernum-Projecten/pullwatch#97).
- Dependencies fits the smallest window without scrolling sideways, and its
  status column says "Up to Date" instead of "Current" (Vernum-Projecten/pullwatch#97).
- Notifications are redesigned. The title says what happened ("New Pull Request", "Pull Request Merged", "New Release v1.2.0", "Critical Vulnerability"), the subtitle names the repository, and the body gives the title with its author and co-authors. macOS stacks them per repository, and above 20 items in one poll each repository gets one summary.
  Notifications have buttons: Mark as Read, Open Repository Page and Mute Repository (with Undo in the menu), and Show in Pullwatch and Copy Advisory ID on a vulnerability. A GitHub author's avatar is attached.
  New pull requests, releases and vulnerabilities come with a banner; tags, merged pull requests and new versions arrive quietly in Notification Center. Reading an item in Pullwatch removes its notification.
  The new Settings > Notifications pane has a switch per kind with a preview, quiet hours, and options for the Dock badge and the unread dot in the menu bar. The notification switches under General moved there (Vernum-Projecten/pullwatch#101).

### Fixed

- Statistics use GitHub's pull request colours and show all four states: opened
  (green), draft (gray), merged (purple, "completed" for Azure DevOps) and closed
  without merging (red), as stacked bars per period and as tiles. Hovering an
  author or repository shows how its pull requests are split over those states (Vernum-Projecten/pullwatch#105).
- An account signed in with GitHub no longer has to sign in again when a check is
  stopped while its GitHub token is being renewed, or when two checks renew it at the
  same time (Vernum-Projecten/pullwatch#117).
- When `gh`, `az`, `glab` or a server does not answer in time, the account
  status now says so in your language ("gh did not answer in time") instead of
  a Dutch timeout text. A few other error details (a missing HTTP response, an
  incomplete answer from GitHub or OSV) are translated as well (Vernum-Projecten/pullwatch#122).

## [0.6.0] - 2026-11-03

### Thank you, Ruben

This release would not exist in this form without **Ruben Talstra** (@rubentalstra). He created the fork [Vernum-Projecten/pullwatch](https://github.com/Vernum-Projecten/pullwatch), where nearly everything in 0.6.0 was built, and his input and ideas shaped where Pullwatch is going:

- **More places to follow:** GitLab (gitlab.com and your own server), GitHub Enterprise Server and GHE.com, and single repositories you add yourself.
- **Sign in with GitHub** through the Pullwatch GitHub App, a welcome window that walks you through your first account, and profile pictures and co-authors in the pull request list.
- **A much deeper version check:** every install of every package with where it comes from, more lockfiles (yarn, pnpm, NuGet, Gemfile), version ranges per ecosystem, what blocks an update, and GitHub's advisories, code scanning and secret scanning.
- **A new main window** with navigation, search, tables, mark as read or unread, and GitHub's icons for pull requests.
- **Updates inside the app** with Sparkle, a signed and notarised release lane, CI on every pull request, and a proper install window in the disk image.

Thank you, Ruben, for the time, the care and the many good ideas. 🙏

### Added

- **Sources** in Settings: every source Pullwatch takes vulnerability and
  version information from (OSV.dev, the GitHub Advisory Database, GitHub
  security, Azure DevOps Advanced Security, the package registries,
  endoflife.date and swift.org), with what it provides, the address it
  calls and a switch to turn it off, plus every other connection Pullwatch
  makes (your accounts' servers, Sign in with GitHub, profile pictures and
  the update check). **Copy overview** puts the list on the clipboard, to
  share with whoever asks where the data comes from. A source that is off
  is never called, and wherever that leaves something unchecked Pullwatch
  says so ("Not checked: source OSV.dev is off") instead of "no
  vulnerabilities" or "up to date".
- **Copy a section for an AI agent.** Every heading on a repository's page
  has a copy button that puts that section on the clipboard as an English
  Markdown brief: packages with their versions, files, ranges and what
  blocks an update; vulnerabilities with their ids and fixed versions;
  security alerts; pull requests; each with a task line an agent can act on.
- **Language** in Settings, General: follow macOS (the default) or choose
  Nederlands, English, Deutsch or Français, with a button to restart
  Pullwatch in that language.
- **Welcome window on first launch.** It walks through adding an account
  and asks for permission to send notifications by itself. Its headings are
  announced by VoiceOver and its text wraps or scrolls at larger sizes (Vernum-Projecten/pullwatch#5).
- **An install window in the disk image**: the app and a link to
  Applications on a background with an arrow (Vernum-Projecten/pullwatch#7).
- **CI and a release workflow.** Every pull request runs the package tests,
  the app's unit and UI tests and an unsigned release build with the disk
  image. A tag `vX.Y.Z` builds, signs, notarises and packages the release
  and attaches it to a draft GitHub release (Vernum-Projecten/pullwatch#8).
- **Updates inside the app** with Sparkle. When a new version is out, the
  menu and the notification offer **Install**: Pullwatch shows the release
  notes, downloads the update, checks its signatures, installs it and
  restarts. Settings, General, Updates adds **Install updates
  automatically** (download in the background, install when you quit) and
  **Include test versions** (pre-releases). An update is only offered on a
  macOS version it runs on (Vernum-Projecten/pullwatch#9).
- GitLab accounts, on gitlab.com or your own server (https only): Pullwatch follows the
  merge requests, tags and releases of the groups (with their subgroups) and users you
  choose, shows who worked on a merge request, and runs the version and vulnerability check
  on GitLab repositories. Sign in with a personal access token with the `read_api` scope or
  with the GitLab CLI (`glab auth login`). Add one in the welcome window or under
  Settings, Accounts (Vernum-Projecten/pullwatch#10).
- GitHub Enterprise accounts, on GitHub Enterprise Server or your enterprise's subdomain on
  GHE.com (https only): choose GitHub Enterprise on the GitHub card in the welcome window or
  in the add menu under Settings, Accounts, and enter your server. Pullwatch follows pull
  requests, tags and releases there, links to that server and shows its host on the account
  card. Sign in with a personal access token made on the server or with the GitHub CLI
  (`gh auth login --hostname`). What a server lacks, such as a repository's own advisories
  on GitHub Enterprise Server, shows as not available instead of an error (Vernum-Projecten/pullwatch#11).
- **Sign in with GitHub** through the Pullwatch GitHub App (device flow):
  the code goes on the clipboard, the app waits for the approval and the
  installation, and lists the accounts and organisations where it is
  installed. Debug builds use the test app "TEST Pullwatch" (Vernum-Projecten/pullwatch#18).
- **Profile pictures** for GitHub accounts (Vernum-Projecten/pullwatch#22).
- **Log level** in Settings, General, and a button that opens Console (Vernum-Projecten/pullwatch#35).
- **Co-authors of a pull request.** The PR list shows the author with the
  people who worked on it (commit authors and `Co-authored-by:` trailers),
  as small avatars and "mona and 2 others"; hover for every name. GitHub
  asks once per new or changed PR in one batched GraphQL request, Azure
  DevOps reads the PR's commits. Statistics can count co-authors too (Vernum-Projecten/pullwatch#49).
- **Where each package and vulnerability comes from.** The repository page
  lists packages per workspace in Direct, Transitive and Dev groups, with
  every version on its own row and the chain it comes through ("via
  express → body-parser"). A vulnerability shows once per advisory with
  Direct or Via express, Dev only and what to update, and the count counts
  advisories. Dependencies shows each repository's versions per workspace and
  marks repositories that only have a package transitively. New CVE
  notifications and the copied repository text say direct or via which
  package (Vernum-Projecten/pullwatch#58).
- **More lockfiles for the package and vulnerability check**: `yarn.lock`
  (classic and Berry), `pnpm-lock.yaml` (v6 to v9), NuGet
  `packages.lock.json` and `Gemfile.lock`, each install with its workspace,
  direct or transitive, runtime, dev or optional, and the chain it comes
  through. Ruby gems get their latest version from rubygems.org (Vernum-Projecten/pullwatch#59).
- **Mark as read or unread in the main window.** Right-click a PR or tag
  (or press ⇧⌘U, as in Mail), mark everything in the list as read with the
  toolbar button or ⌘K, and see unread items by their blue dot. The menu's
  rows have Mark as Read and Mark as Unread too (Vernum-Projecten/pullwatch#63).
- **GitHub's advisories and security alerts.** Each vulnerability shows its
  GHSA id next to the CVE, GitHub's severity with the CVSS score and vector,
  the CWE names and a link to github.com/advisories, on the repository page,
  in the copied text and in notifications; each advisory is fetched once.
  The repository page gets a security section with the repository's own
  published advisories, open code scanning alerts and the number of open
  secrets on GitHub, or the Advanced Security alerts on Azure DevOps. Open
  critical and high alerts count in the Repos findings and health, with an
  optional notification (Settings, General). A kind the app may not read
  yet shows **Needs permission** with a link (Vernum-Projecten/pullwatch#73).
- The version check keeps the range each manifest asks for next to the installed version (npm, yarn
  and pnpm, Composer, PyPI and Poetry, Cargo, NuGet, RubyGems, Go modules and Swift packages), and
  works out per install whether the newest version fits that range, so only the lockfile changes,
  or needs a manifest change, and whether the step is a patch, minor or major update (Vernum-Projecten/pullwatch#83).
- The version check now reads what each package version asks for from its registry (npm,
  Packagist, crates.io, NuGet, RubyGems, PyPI and the Go proxy) and works out what holds an
  update back: a parent package whose range pins it, a peer dependency, or a runtime (Node, PHP,
  Python, Rust, .NET, Ruby, Go) that is older than the new version needs. It also finds the
  newest version you can use right now, and the lowest parent version that lets a fix through.
  Vulnerability fixes use the same rules. Details per version are kept between checks, so a
  check asks the registries for little more than before (Vernum-Projecten/pullwatch#84).
- **Watch single repositories you add yourself.** Under "Other
  Repositories" in an account's repository list, or with "Watch a
  Repository…" in the main window (Go menu and the Repos toolbar), type
  `owner/repo` or paste a github.com or dev.azure.com link. Pullwatch checks
  it first and says in plain words when it can't find or read it. On GitHub
  this works for public repositories of other organisations too, without
  the Pullwatch app installed there; when your account can't read one,
  Pullwatch reads it without signing in and says so (Vernum-Projecten/pullwatch#89).

### Changed

- A new app icon in Icon Composer format (Vernum-Projecten/pullwatch#4).
- `scripts/release/release.sh` notarises and staples the app before
  packaging it, so the app in the zip carries its own ticket too (Vernum-Projecten/pullwatch#8).
- The project is a committed Xcode project with settings in `.xcconfig`
  files and a folder per area (Vernum-Projecten/pullwatch#12).
- Account names follow the organisation (Vernum-Projecten/pullwatch#21).
- Progress has one place: a bar at the bottom of the main window for the
  first sync, fetching the history again and the version check, with Stop
  where that is safe. Toolbar buttons stay put while their job runs, and the
  menu shows a small spinner next to Refresh during a poll (Vernum-Projecten/pullwatch#52).
- **What to follow per repository is simpler.** The account's repository
  list keeps its PRs, Tags and Merged columns with an "all" checkbox per
  owner and column, without a bell in every cell: notifications per kind
  are in a repository's context menu. Merged needs PRs, and New
  Repositories chooses between nothing, PRs, or PRs and tags (Vernum-Projecten/pullwatch#54).
- The version check keeps every install of a package: its version, its
  workspace, direct or transitive, runtime, dev or optional, and the
  shortest chain from a direct package. A package used in two versions is
  no longer folded into the oldest one, and each vulnerability is listed
  for every install it hits. Older saved checks still load (Vernum-Projecten/pullwatch#57).
- Built with Swift 6.4 (tools version 6.4) with approachable concurrency,
  the app on the main actor by default, and the ExistentialAny,
  MemberImportVisibility, NonisolatedNonsendingByDefault and
  InferIsolatedConformances features; CI treats warnings as errors (Vernum-Projecten/pullwatch#66).
- **Pullwatch fetches only what you choose.** A new account follows no
  repositories until you check them, so it never fetches a whole account by
  itself, and a saved account can be turned off with "Fetch This Account"
  without losing its choices (Vernum-Projecten/pullwatch#71).
- The **Versions** section is now called **Dependencies** (Afhankelijkheden),
  since it shows the runtimes, frameworks and packages a repository depends on (Vernum-Projecten/pullwatch#75).
- **Pull request icons like GitHub's.** Open, draft, merged and closed pull
  requests each get GitHub's Octicon in GitHub's colour (green, gray,
  purple, red) in the menu, the PR list, the sidebar and the empty lists,
  and the Closed pill is red now. The PR and tag list shows one narrow icon
  column in place of Kind and Status (hover for "Pull request, merged" or
  "Tag"), with the Release pill next to the tag name. The app icon and the
  menu bar icon use the same `git-pull-request` glyph. The Octicons are MIT
  licensed (see NOTICE) (Vernum-Projecten/pullwatch#77).

### Fixed

- Windows opened from the menu (Settings, About, Open…) come to the front
  instead of opening behind the app you were using.
- Opening Pullwatch while it runs shows the main window (Vernum-Projecten/pullwatch#6).
- Adding an account no longer leaves an empty row behind: nothing is saved
  until the account has an organisation, and empty accounts from older
  versions are removed at launch (Vernum-Projecten/pullwatch#22).
- Tokens of accounts that no longer exist are removed from the Keychain at
  launch (Vernum-Projecten/pullwatch#50).
- A PR that was just opened shows up at once instead of up to a minute
  later: Pullwatch no longer answers from GitHub's one-minute cache (Vernum-Projecten/pullwatch#51).
- The main window fills in after adding an account: existing tags within
  the history retention appear under Tags (read, without notifications),
  newly followed repositories get their version check right after the poll
  that first sees them, and empty lists say they are fetching (Vernum-Projecten/pullwatch#52).
- Notifications say "1 new PR" instead of "1 new PRs", in every language,
  and show the severity of a vulnerability in your language (Vernum-Projecten/pullwatch#53).
- **Tags have an author on GitHub, and releases are shown.** Tags and
  Releases lists each tag with who made it (the person behind a release,
  else the tagger, else the commit author) and its photo, a Release or
  Pre-release label with the release title, and a filter for releases or
  tags without one. A release published after its tag was seen gets one
  notification and updates the same row. A tag without a release opens the
  tag's files instead of a release page that does not exist. GitHub tags
  come from one GraphQL request per ten repositories, and a repository
  where nothing changed costs one small request per fifty. Azure DevOps
  tags without a creator get their tagger or commit author (Vernum-Projecten/pullwatch#74).

## [0.5.0] - 2026-11-01

Released by Alessandro Torrisi from the upstream repository
([alessandro823/pullwatch](https://github.com/alessandro823/pullwatch/releases/tag/v0.5.0)),
before this changelog existed. The fork starts from this version.

### Added

- **Repositories**: a list per project, worst first, with a page per
  repository for its pull requests, the version check, packages with a new
  version and its activity.
- **Statistics**: pull request activity per week, month or year, filtered
  by project, author or repository.
- **Keyboard shortcuts** for the sections, search, refresh, back and open
  in the browser.
- The menu header shows the version number.

### Changed

- The repository overview is calculated once instead of on every screen
  update.

[Unreleased]: https://github.com/alessandro823/pullwatch/compare/v0.10.1...HEAD
[0.10.1]: https://github.com/alessandro823/pullwatch/compare/v0.10.0...v0.10.1
[0.10.0]: https://github.com/alessandro823/pullwatch/compare/v0.9.1...v0.10.0
[0.9.1]: https://github.com/alessandro823/pullwatch/compare/v0.9.0...v0.9.1
[0.9.0]: https://github.com/alessandro823/pullwatch/compare/v0.8.0...v0.9.0
[0.8.0]: https://github.com/alessandro823/pullwatch/compare/v0.7.0...v0.8.0
[0.7.0]: https://github.com/alessandro823/pullwatch/compare/v0.6.0...v0.7.0
[0.6.0]: https://github.com/alessandro823/pullwatch/compare/v0.5.0...v0.6.0
[0.5.0]: https://github.com/alessandro823/pullwatch/releases/tag/v0.5.0
