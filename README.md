# Pullwatch

A macOS menu bar app that notifies you about new pull requests in Azure DevOps and GitHub, plus new tags (optional, per repository). It keeps a searchable history and can check your repositories for outdated languages, frameworks and known vulnerabilities.

The app's interface is in Dutch.

## Install

Download the latest `Pullwatch-x.y.z.dmg` from [Releases](https://github.com/alessandro823/pullwatch/releases), open it and drag Pullwatch to Applications.

The app is signed with a Developer ID and notarized by Apple. Universal (Apple silicon and Intel), requires macOS 14 or later.

## Build from source

- Xcode (Swift 6)
- `brew install xcodegen`
- Optional: `az` (`az login`) and/or `gh` (`gh auth login`) for CLI authentication

```bash
make test      # PullwatchCore unit tests
make install   # build and copy to ~/Applications/Pullwatch.app
make run       # install + launch
make dmg       # build dist/Pullwatch-<version>.dmg (ad-hoc signed)
make release   # signed with Developer ID, notarized and stapled DMG
```

`make release` needs a Developer ID Application certificate in the Keychain and a notarytool profile (`xcrun notarytool store-credentials pullwatch --apple-id <id> --team-id <team>`); override with `SIGN_ID=…` and `NOTARY_PROFILE=…`.

## Usage

1. Click the menu bar icon → **Instellingen…** (Settings).
2. Add an account (Azure DevOps or GitHub), choose PAT or CLI, and test the connection.
3. Per account, choose which repositories you follow: PR's, Tags and/or Completed (merged PRs).

Tags are off by default. Next to each checkbox is a bell: turn it off to keep following the repository (menu and history) without getting notifications. The bell in the header toggles all visible repositories. Tags are polled every 15 minutes (separate from the PR interval; "Nu verversen" polls tags too). The first tag poll per repository is silent.

While a window (settings, history, versions) is open, Pullwatch shows in the Dock; close the last window and it runs from the menu bar only.

### History

**Geschiedenis…** opens a searchable list of every detected PR and tag (filter by kind, double-click opens the page). Retention (2 months, 6 months, 1 year or forever) is set under Settings → General.

Pullwatch also fetches existing PRs (open, merged and closed) for the history. The first time it goes back to the retention period, with at most 1000 PRs per account; after that the history is updated every 15 minutes (state, title and close date). Fetched PRs don't notify and are marked as read. Changing the repository filter or retention restarts the initial fetch for that account. The GitHub search API has its own limit of 30 requests per minute; when hit, Pullwatch waits it out while PR polling carries on.

Calls to `az` and `gh` time out after 20 seconds.

### Versions

**Versies…** shows which followed repositories are behind. Per repository Pullwatch reads, on the default branch:

| File | Detects |
|---|---|
| `go.mod` | Go |
| `*.csproj`, `*.fsproj`, `Directory.Build.props` | .NET |
| `package.json` | Node (`engines`), Angular, React, Vue, Next.js, Nuxt |
| `composer.json` | PHP, Symfony, Laravel |
| `rust-toolchain(.toml)`, root `Cargo.toml` | Rust |
| `Package.swift` | Swift (`swift-tools-version`; not on endoflife.date, so always unknown) |
| `.nvmrc`, `.node-version`, `pyproject.toml`, `.python-version` | Node, Python |
| `Dockerfile*` | base images (node, golang, python, dotnet, alpine, debian, ubuntu, nginx, postgres, redis, eclipse-temurin, rust, php, ruby) |
| `.github/workflows/*.yml` | `python-version`, `node-version`, `go-version`, `dotnet-version` |

Versions are compared with [endoflife.date](https://endoflife.date): **Actueel** (current), **Achter** (a newer major/minor exists; patches don't count), **EOL** or **Onbekend** (unknown).

- A version requirement that is only a minimum (`engines.node`, `php` in `composer.json`, `requires-python`, `rust-version`, CI versions) is dropped when the same language is pinned elsewhere (Docker image, `.nvmrc`, `rust-toolchain`).
- A `go.mod` used as a local copy of a dependency (`replace … => ./path`) is ignored.
- For frameworks, the installed version from `package-lock.json`/`composer.lock` wins over the manifest's minimum.
- Custom Docker images are recognised by a known name before the first dash (`php-fpm-alpine:8.4` → PHP 8.4); `ARG` defaults in `FROM` are filled in.

The same check looks up known vulnerabilities via [OSV.dev](https://osv.dev) for packages with an exact version: `go.mod`, `package-lock.json`, `PackageReference`/`PackageVersion` in .NET projects, `requirements*.txt` (`==` only), `poetry.lock`, `uv.lock`, `composer.lock`, `Cargo.lock` (crates.io only) and `Package.resolved`. `yarn.lock` and `pnpm-lock.yaml` are not read. Package names and versions are sent to api.osv.dev, also for private repositories.

If a repository has tags, the newest version tag is checked too (pre-releases like `-rc1` only if there is nothing else). Each vulnerability on the default branch is marked as also in that release or new since it. Anything already fixed on the default branch is not reported.

The check runs once a day (can be turned off under Settings → General) and on **Opnieuw checken**; ↻ re-checks a single repository and the copy button puts a repository's versions and vulnerabilities on the clipboard. New CVEs found by the daily check trigger a notification. From the history window, **Versies** (or right-click a row) opens the versions filtered on that repository.

### PAT scopes

- Azure DevOps: **Code (Read)** (also covers tags) and **Project and Team (Read)** (the project list comes from `/_apis/projects`).
- GitHub (fine-grained): **Pull requests: Read** and **Metadata: Read** on the repositories you want, plus **Contents: Read** for Versions. Classic: `repo`.

## Known quirks

- With an ad-hoc signed local build (`make install`), macOS may ask for Keychain access again after each install for PAT accounts; choose "Always Allow".
- On first launch Pullwatch asks for permission to send notifications.
- `make run` doesn't restart a running Pullwatch; quit it first via **Stop** in the menu.

## Data

`~/Library/Application Support/Pullwatch/`: `config.json`, `seen.json`, `history.json`, `versions.json`. Tokens are stored in the Keychain (`nl.torrisi.pullwatch`).

Logs: `log stream --predicate 'subsystem == "nl.torrisi.pullwatch"'`

## License

[Apache 2.0](LICENSE)
