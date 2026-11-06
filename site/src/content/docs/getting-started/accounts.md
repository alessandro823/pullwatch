---
title: Add your accounts
description: Connect GitHub, GitHub Enterprise, Azure DevOps, GitLab, Bitbucket, Codeberg, Forgejo and Gitea, and choose which repositories Pullwatch follows.
---

Open **Settings** (the gear button in the menu panel) and go to **Accounts**. Add an account with **+**, choose how Pullwatch signs in, and use **Test connection** to check it. You can add as many accounts as you like, of any kind.

Pullwatch only reads. It never comments, merges or changes anything on your servers.

## GitHub

There are three ways to sign in on github.com:

- **Sign In with GitHub.** Pullwatch shows a code, you confirm it on github.com, and the Pullwatch GitHub App gets read access to the repositories you choose when you install it. The app asks only for read permissions.
- **Personal access token.** Paste a token you made yourself. See [Token permissions](/getting-started/permissions/) for the scopes.
- **GitHub CLI.** If you use `gh` (`gh auth login`), Pullwatch asks it for a token. With several `gh` accounts, pick the one to use under **GitHub account**.

## GitHub Enterprise

Choose **GitHub Enterprise** on the GitHub card (or in the **+** menu) and enter your server under **Server**:

- a GitHub Enterprise Server, such as `https://github.example.com`, or
- your enterprise's subdomain on GHE.com, such as `https://acme.ghe.com`.

Only https works, so a token never travels unencrypted. Pullwatch finds the API by itself and links to pull requests, tags and repositories on that server. Sign in with a personal access token made on that server, or with the GitHub CLI after `gh auth login --hostname <server>`. **Sign In with GitHub** is for github.com only.

Some things a server does not have show as **Not available on this server** instead of an error, such as a repository's own security advisories on GitHub Enterprise Server.

## Azure DevOps

Enter your organization, then sign in with a personal access token or with the Azure CLI (`az login`). Pullwatch reads the projects of the organization and their repositories.

## GitLab

Leave **Server** empty for gitlab.com, or enter your own server (https only, for example `https://gitlab.example.com`). List the groups or users to follow, separated by commas, such as `acme, acme/platform`. A group includes its subgroups, and repositories appear as `group/subgroup/project`.

Sign in with a personal access token with the `read_api` scope, or with the GitLab CLI (`glab auth login`). **Create token** in the account editor opens your server's token page with the name and scope filled in.

## Bitbucket

Choose **Bitbucket** on its card in the welcome window, or **Bitbucket Cloud** in the **+** menu. This is Bitbucket Cloud on bitbucket.org; Bitbucket Data Center is not supported. List the workspaces to follow under **Workspaces**, separated by commas, such as `acme, acme-labs`. The workspace is the first part of a link, `bitbucket.org/<workspace>/<repo>`, and repositories appear as `workspace/repo`.

Sign in with an Atlassian API token with scopes and the email address of your Atlassian account, under **Email address**. **Create token** opens the API tokens page of your Atlassian account: choose **Create API token with scopes**, then **Bitbucket**, and the read scopes in [Token permissions](/getting-started/permissions/). App passwords no longer work, and there is no Bitbucket command-line tool that Pullwatch could take a token from. The email address is kept in the settings, the token in the Keychain.

Bitbucket has no releases, so **Tags and Releases** shows only tags for a Bitbucket account. The checks of a pull request are the build statuses on its latest commit, from Bitbucket Pipelines or any other CI that reports them. Bitbucket has no list of all pull requests in a workspace, so Pullwatch asks each repository; a repository that did not change since the last poll is asked again after 10 minutes at the latest.

## Codeberg, Forgejo and Gitea

Codeberg, Forgejo and Gitea share one card, because they speak the same API. Pick the button for your service:

- Codeberg: an account on codeberg.org.
- Forgejo: your own Forgejo server. Enter it under **Server** (https only, for example `https://git.example.com`).
- Gitea: leave **Server** empty for gitea.com, or enter your own Gitea server.

List the organizations or users to follow under **Organizations or users**, separated by commas, such as `acme` and `jdoe`. Repositories appear as `owner/repo`.

Sign in with a token made on that server under Settings, Applications, with the scopes `read:user`, `read:organization`, `read:repository` and `read:issue` ([Token permissions](/getting-started/permissions/) says why). **Create token** opens that page. Pullwatch has no sign-in through the `tea` command-line tool: `tea` has no command that hands out its token.

**Test connection** says what is wrong when something is: a token that is not valid, a scope the token lacks (by name), an organization or user that does not exist, an address where no Gitea or Forgejo answers, or a certificate macOS does not trust. Pullwatch only talks to servers over https with a valid certificate, so a self-signed certificate does not work unless macOS trusts it.

Pull requests come in one request per organization or user, whatever the number of repositories. Drafts are recognised by the draft flag, and on an older Gitea by a title that starts with `WIP:` or `[WIP]`. The checks of a pull request are the commit statuses on its last commit, such as those of Forgejo Actions, Gitea Actions or Woodpecker. Tags come with their releases, including pre-releases.

## Choose what to follow

Each account lists its repositories. Per repository, tick what you want:

- **PRs**: new pull requests (or merge requests).
- **Tags**: new tags, and on GitHub, GitLab, Codeberg, Forgejo and Gitea the releases made for them. Tags are off by default.
- **Merged**: pull requests that get merged.

Next to each tick is a bell. Turn it off to keep a repository in the menu and the history without notifications. The bell in the header switches all visible repositories at once. Draft pull requests appear in the menu and the history with the draft icon, as on GitHub. Per account you can turn that off with **Show draft PRs**: drafts then appear nowhere, and a pull request arrives once it is ready for review. With **Notify about draft PRs** a new draft also gives a notification. You can also hide your own pull requests and turn the whole account off for a while.

## Repositories outside your account

Under **Other repositories** at the bottom of the list, add a single repository that is not part of the account's owners or groups:

- GitHub: `owner/repo`, or paste a github.com link.
- Azure DevOps: `project/repo` inside the account's organization, or a dev.azure.com link.
- GitLab: `group/subgroup/project`, or a link from gitlab.com or the account's own server.
- Bitbucket: `workspace/repo`, or paste a bitbucket.org link.
- Codeberg, Forgejo and Gitea: `owner/repo`, or a link from the account's server.

Pullwatch checks it with one request and tells you in plain words when it cannot find or read it. A public repository on github.com, gitlab.com or bitbucket.org that your token may not read is read without signing in. **Watch a Repository…** (⇧⌘N, in the File menu and in the toolbar of Repositories) opens the same field with a choice of account. Remove one with a right click or the Delete key.

Such a repository shows up everywhere like the others you follow, grouped under its own owner.

- **GitHub**: this also works for a public repository of another organization where the Pullwatch GitHub App is not installed, such as `openEHR/specifications-AM`. The pull requests of these repositories come in one search per account, with up to 30 repositories per search.
- **GitLab**: links from gitlab.com or the account's own server work, also `/-/` links such as `/-/merge_requests/12`; a link to another server is refused. A public project is read without signing in only when the server answers without a token: gitlab.com does, a server that requires signing in does not, and then the project is not found. Each such project costs one request per poll for its merge requests (one page, the 100 most recently updated).
- **Codeberg, Forgejo and Gitea**: a link must be on the account's server. A public repository is read without signing in when the server allows it, as codeberg.org and gitea.com do. Each such repository costs one request per poll for its pull requests (one page, the 50 most recently updated).

## How often Pullwatch looks

Under Settings, General you set how often Pullwatch checks for new pull requests, and how long the history is kept (2 months, 6 months, 1 year or forever). Tags are checked every 15 minutes. **Refresh now** in the menu panel checks right away.
