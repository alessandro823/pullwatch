# pullwatchd

A headless Go variant of Pullwatch. One binary polls the GitHub and Azure DevOps accounts in a config file, keeps a history of pull requests and tags, runs the same version and CVE check as the Mac app, and serves a small web dashboard.

The Mac app is unchanged. This process does not read its Keychain or `~/Library/Application Support/Pullwatch`.

## What it does

- Polls open pull requests on the configured interval (default 2 minutes, clamped to 1–15 minutes). The first successful poll of an account is silent, so existing pull requests are not treated as new.
- Polls tags every 15 minutes for repositories with tags enabled. The first tag poll of a repository is silent.
- Syncs pull-request history (open, merged and closed) on that same 15 minute cadence, up to 1000 per account, and notices merges in repositories with `completed` enabled.
- Hides drafts unless `include_drafts` is set, and hides your own pull requests unless `hide_own` is false.
- Once a day (and on demand) reads project files on the default branch and the newest version tag, compares languages and frameworks with [endoflife.date](https://endoflife.date) (Swift releases come from swift.org), and looks up exact package versions on [OSV](https://osv.dev).
- Persists history, the seen-set and the version report as JSON under `data_dir`.

## Configure

```bash
cp config.example.yaml config.yaml
export GITHUB_TOKEN=...            # fine-grained: Pull requests, Metadata, Contents
export AZURE_DEVOPS_TOKEN=...      # PAT: Code (Read), Project and Team (Read)
```

`config.yaml` names the environment variable (`token_env`). A `token:` field in the file is rejected. Optional dashboard basic auth:

```bash
export PULLWATCH_DASHBOARD_USER=ada
export PULLWATCH_DASHBOARD_PASSWORD=...
```

`PULLWATCH_LISTEN`, `PULLWATCH_DATA_DIR` and `PULLWATCH_POLL_INTERVAL` override the file. `PULLWATCH_CONFIG` is the default path for `-config`.

Per repository, `prs`, `tags` and `completed` match the Mac app. Repositories omitted from `repos` use `new_repo_default` (`prs` or `none`). Tags are never on by default. `notify_*` is accepted so a config can record the same choices as the Mac app; the dashboard still lists every new item until you mark it seen, because there is no separate notification channel.

## Run the binary

```bash
cd server
go build -o pullwatchd ./cmd/pullwatchd
./pullwatchd -config config.yaml
```

Open http://127.0.0.1:8080. The inbox lists unseen pull requests and tags, History is searchable, and Versions shows the CVE report. **Refresh** polls immediately. **Check again** runs the version check. **Seen** dismisses one row.

Without tokens, the sample dashboard is:

```bash
./pullwatchd --demo
```

## Docker

From `server/`, with `config.yaml` next to the compose file:

```bash
docker compose up --build
```

Or the image alone:

```bash
docker build -t pullwatchd .
docker run --rm -p 8080:8080 \
  -e GITHUB_TOKEN -e AZURE_DEVOPS_TOKEN \
  -e PULLWATCH_DASHBOARD_USER -e PULLWATCH_DASHBOARD_PASSWORD \
  -v "$PWD/config.yaml:/config.yaml:ro" \
  -v pullwatch-data:/data \
  pullwatchd
```

The image is `golang:1.27.3-alpine3.24` for the build and `alpine:3.24.3` at runtime. It listens on `:8080` and stores state in `/data`. Put the dashboard behind a login (`PULLWATCH_DASHBOARD_USER` / `PULLWATCH_DASHBOARD_PASSWORD`) before exposing it.

## Tests

The module is `go 1.27.3`.

```bash
cd server
go vet ./...
go test ./...
```

## Left out on purpose

These belong to the Mac app and are not in the server:

- Menu bar, Dock, login item, and macOS notifications (including the “more than 3” summary and the per-repo mute bell). The dashboard is the surface; mark a row seen to dismiss it.
- Keychain, and `gh` / `az` CLI login. Tokens come from the environment. Azure accepts a PAT or a bearer token (`auth: bearer`).
- The Mac app’s own update check against GitHub releases.
- Dutch, German and French UI. The dashboard is English.
- An in-browser account editor. Accounts live in the config file.
- GitHub Enterprise Server and Azure DevOps Server, which the Mac app does not support either.
