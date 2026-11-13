<div align="center">

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/images/icon-dark.png">
  <img src="docs/images/icon-light.png" width="128" height="128" alt="The Pullwatch app icon: a pull request symbol inside a ring">
</picture>

# Pullwatch

**Pull requests, tags and outdated dependencies, watched from your Mac's menu bar.**

[![CI](https://github.com/alessandro823/pullwatch/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/alessandro823/pullwatch/actions/workflows/ci.yml?query=branch%3Amain)
[![Latest release](https://img.shields.io/github/v/release/alessandro823/pullwatch)](https://github.com/alessandro823/pullwatch/releases/latest)
[![macOS 26.6+](https://img.shields.io/badge/macOS-26.6%2B-blue?logo=apple)](https://pullwatch.net/getting-started/install/)
[![Swift 6.4](https://img.shields.io/badge/Swift-6.4-blue?logo=swift&logoColor=white)](PullwatchKit/Package.swift)
[![License](https://img.shields.io/github/license/alessandro823/pullwatch)](LICENSE)
[![Downloads](https://img.shields.io/github/downloads/alessandro823/pullwatch/total)](https://github.com/alessandro823/pullwatch/releases)
[![Website](https://img.shields.io/badge/website-pullwatch.net-blue)](https://pullwatch.net)

[Website](https://pullwatch.net) &nbsp;&nbsp;&nbsp; [Download](https://github.com/alessandro823/pullwatch/releases/latest) &nbsp;&nbsp;&nbsp; [Documentation](https://pullwatch.net/getting-started/install/) &nbsp;&nbsp;&nbsp; [Changelog](CHANGELOG.md)

</div>

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/images/hero-dark.png">
  <img src="docs/images/hero-light.png" alt="The PRs list in the Pullwatch main window: pull requests from four repositories, each with its state icon, checks such as 4 of 8, title, repository and number, author and age.">
</picture>

Pullwatch is a menu bar app for macOS. It tells you about new pull requests,
tags and releases on GitHub, Azure DevOps, GitLab™, Bitbucket, Codeberg,
Forgejo and Gitea, keeps a searchable history, and checks your repositories for outdated runtimes, packages and
known vulnerabilities. It speaks English, Dutch, German and French.

## What it does

- **Pull requests**: a notification for each new or merged pull request (or
  merge request), with its CI checks as `4/8` and whether it waits in a merge
  queue or merge train.
- **Tags and releases**: new tags and the releases of GitHub, GitLab,
  Codeberg, Forgejo and Gitea, per repository, with who made them.
- **Branches**: the branches of the repositories you follow as a tree
  from the default branch, each under the branch it was made from, with
  who pushed last and how far it is ahead and behind; a list to look at,
  without notifications.
- **History and statistics**: every pull request and tag in a searchable
  list, and charts of opened and merged pull requests per author and
  repository.
- **Repositories**: every repository you follow, worst first, with a page
  per repository for its pull requests, versions, dependencies and security.
- **Dependencies**: outdated runtimes, frameworks and packages from your
  manifests and lockfiles, and what holds each update back.
- **Packages**: what your repositories publish to their own registry, and
  who uses it; your own packages are checked against that registry.
- **Vulnerabilities**: known advisories from OSV.dev and the GitHub Advisory
  Database, plus the code scanning, secret scanning and Advanced Security
  alerts of GitHub and Azure DevOps.
- **Notifications** with buttons to mark as read, open the repository or
  mute it, quiet hours, and a switch per kind.
- **Agents via MCP**: Claude Code, Codex, Cursor or VS Code ask Pullwatch
  about your pull requests, repositories and vulnerabilities, read-only and
  off by default ([Agents](https://pullwatch.net/agents/)).

## Supported services

| Service | Pull requests | Tags | Releases | Checks | Security data |
|---|:---:|:---:|:---:|:---:|---|
| GitHub (github.com) | Yes | Yes | Yes | Yes | Repository advisories, code scanning, secret scanning |
| GitHub Enterprise Server and GHE.com | Yes | Yes | Yes | Yes | Code scanning, secret scanning; advisories where the server has them |
| Azure DevOps | Yes | Yes | No | Yes | Advanced Security alerts |
| GitLab (gitlab.com and self-managed) | Yes | Yes | Yes | Yes | None; packages are checked with OSV.dev |
| Bitbucket Cloud (bitbucket.org) | Yes | Yes | No (Bitbucket has none) | Yes (build statuses) | None; packages are checked with OSV.dev |
| Codeberg, Forgejo and Gitea (codeberg.org, gitea.com and your own server) | Yes | Yes | Yes | Yes (commit statuses) | None; packages are checked with OSV.dev |

The dependency and vulnerability check works on every service. See
[Add your accounts](https://pullwatch.net/getting-started/accounts/) for the
details of each.

## Install

1. Download the latest `Pullwatch-x.y.z.dmg` from
   [Releases](https://github.com/alessandro823/pullwatch/releases/latest).
2. Open it and drag **Pullwatch** to **Applications**.

Pullwatch needs macOS 26.6 or later and runs natively on Apple silicon and
Intel. Every release is signed with a Developer ID and notarized by Apple,
and Pullwatch updates itself through [Sparkle](https://sparkle-project.org).
More in [Install and first launch](https://pullwatch.net/getting-started/install/).

## Getting started

1. Open Pullwatch. A welcome window points out its menu bar icon.
2. Add an account: **Sign In with GitHub**, a personal access token, or the
   `gh`, `az` or `glab` command-line tool.
3. Choose per repository what to follow: **PRs**, **Tags**, **Branches**
   (which follow along with **PRs**) and **Merged** (merged pull requests),
   each with its own bell except **Branches**.
4. Allow notifications. Pullwatch then polls in the background.

The [documentation](https://pullwatch.net/getting-started/install/) covers
every screen, the [token permissions](https://pullwatch.net/getting-started/permissions/)
and the [keyboard shortcuts](https://pullwatch.net/using/keyboard-shortcuts/).

## Privacy

- Pullwatch only reads. It never comments, merges or pushes.
- Tokens stay in the macOS Keychain, or with the `gh`, `az` or `glab` tool
  you signed in with. There is no Pullwatch server and no analytics.
- Settings, **Sources** lists every outside connection, and each data
  source can be switched off.

Read [Privacy and sources](https://pullwatch.net/privacy/) for what is sent
where.

## Build from source

You need Xcode 27 (Swift 6.4) on macOS 26.6 or later.

```bash
git clone https://github.com/alessandro823/pullwatch.git
cd pullwatch
open Pullwatch/Pullwatch.xcodeproj   # run the Pullwatch scheme with ⌘R
```

The tests, as CI runs them:

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
swift test --package-path PullwatchKit -Xswiftc -warnings-as-errors
xcodebuild test -project Pullwatch/Pullwatch.xcodeproj -scheme Pullwatch \
  -destination 'platform=macOS'     # unit and UI tests
```

> [!NOTE]
> The UI tests take over the screen. On a Mac you are working on, run
> `-only-testing:PullwatchTests` and let CI run the UI tests.

`scripts/release/release.sh --unsigned` makes an ad hoc signed disk image in
`dist/`. Signing, the release lane and the repository layout are in
[For maintainers](https://pullwatch.net/maintainers/) and
[docs/releasing.md](docs/releasing.md); the MCP server for agents in
[docs/mcp.md](docs/mcp.md).

## Contributing

Bug reports and ideas are welcome as
[issues](https://github.com/alessandro823/pullwatch/issues). A pull request
explains what changed and why, passes the checks in [CLAUDE.md](CLAUDE.md)
(the project's working notes: layout, gates and rules), and adds a changelog
fragment as [changelog.d/README.md](changelog.d/README.md) describes.

[Contributing](CONTRIBUTING.md) &nbsp;&nbsp;&nbsp; [Security](SECURITY.md) &nbsp;&nbsp;&nbsp; [Support](SUPPORT.md) &nbsp;&nbsp;&nbsp; [AI policy](AI_POLICY.md) &nbsp;&nbsp;&nbsp; [Code of conduct](CODE_OF_CONDUCT.md)

## License

Pullwatch is licensed under the [Apache License 2.0](LICENSE).

## Trademarks and third-party

- The pull request, checks, Branches and menu bar icons and the glyph of the
  app icon are [GitHub Octicons](https://github.com/primer/octicons), MIT License.
- GitHub and the Invertocat are trademarks of GitHub, Inc. Pullwatch shows
  the unmodified Invertocat from GitHub's
  [logo download](https://brand.github.com/GitHub_Logos.zip) where an
  account connects to GitHub.
- GITLAB is a trademark of GitLab Inc. in the United States and other
  countries and regions. Pullwatch shows GitLab's logomark, unmodified, from
  GitLab's [press kit](https://about.gitlab.com/press/press-kit/)
  (`gitlab-logo-500-rgb.svg`) where an account connects to GitLab.
- Bitbucket and Atlassian are trademarks of Atlassian. Pullwatch shows the
  unmodified Bitbucket icon from Atlassian's
  [logo component](https://atlassian.design/components/logo/) where an
  account connects to Bitbucket.
- The Codeberg logo is from [Codeberg/Design](https://codeberg.org/Codeberg/Design), CC0; Codeberg is
  a trademark of Codeberg e.V. The Forgejo logo is by Caesar Schinas, from
  [forgejo/meta](https://codeberg.org/forgejo/meta/src/branch/readme/branding),
  CC BY-SA 4.0. Gitea and its logo are trademarks of their owners; Pullwatch
  shows the unmodified logo from the
  [Gitea repository](https://github.com/go-gitea/gitea/blob/main/assets/logo.svg)
  where an account connects to Gitea.
- Azure DevOps is a trademark of the Microsoft group of companies. Pullwatch
  shows only the name, with an SF Symbol (a cloud).
- Pullwatch is not affiliated with, endorsed, sponsored or approved by
  GitHub, GitLab Inc., Atlassian, Microsoft, Codeberg e.V., the Forgejo
  project, CommitGo, Inc. or the Gitea project.

[NOTICE](NOTICE) holds the full notices, including the MCP Swift SDK and its
dependencies.
