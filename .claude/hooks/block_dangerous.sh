#!/usr/bin/env bash
# .claude/hooks/block_dangerous.sh
#
# Claude Code PreToolUse hook (matcher: Bash). Refuses:
#   - rm -rf outside the temp directory
#   - force-pushes touching main, and bare force-pushes
#   - any push to main: a change reaches alessandro823/pullwatch's main
#     only through a pull request Alessandro merges
#   - gh pr merge: Alessandro merges, never a session
#   - gh pr create without --repo alessandro823/pullwatch (the gh default
#     repository is the fork, which keeps the tracker)
#   - security commands that would export or delete signing identities

set -euo pipefail

payload="$(cat)"
if command -v jq >/dev/null 2>&1; then
  cmd="$(printf '%s' "$payload" | jq -r '.tool_input.command // empty' 2>/dev/null || true)"
else
  cmd="$payload"
fi
[ -n "${cmd:-}" ] || exit 0

if printf '%s' "$cmd" | grep -qE '(^|[;&|[:space:]])rm[[:space:]]+-[a-zA-Z]*([rR][a-zA-Z]*f|f[a-zA-Z]*[rR])'; then
  # shellcheck disable=SC2016 # the literal `$TMPDIR` is a grep pattern, not an expansion
  if ! printf '%s' "$cmd" | grep -qE 'rm[[:space:]]+-[a-zA-Z]+[[:space:]]+"?(/private)?/tmp/|\$TMPDIR'; then
    echo "BLOCKED: 'rm -rf' is not allowed outside the temp directory." >&2
    exit 2
  fi
fi

if printf '%s' "$cmd" | grep -qE 'git[[:space:]]+push[^;|&]*(--force([^-]|$)|--force-with-lease|[[:space:]]-f([[:space:]]|$)|[[:space:]]\+[[:alnum:]])'; then
  if printf '%s' "$cmd" | grep -qE '(^|[[:space:]:/+])(main|master)([[:space:]]|$|["'"'"';&|])'; then
    echo "BLOCKED: force-push touching main is forbidden." >&2
    exit 2
  fi
  if ! printf '%s' "$cmd" | grep -qE '(feat|fix|chore|docs|refactor|perf|test|ci|build|release)/'; then
    echo "BLOCKED: bare force-push refused; name a conventional-type branch." >&2
    exit 2
  fi
fi

# `git push origin main`, `HEAD:main`, `x:refs/heads/main`.
if printf '%s' "$cmd" | grep -qE 'git[[:space:]]+push[[:space:]]'; then
  if printf '%s' "$cmd" | grep -qE 'git[[:space:]]+push[[:space:]]+([^;|&]*[[:space:]])?(origin|[^[:space:]]*alessandro823/pullwatch[^[:space:]]*)[[:space:]]+([^;|&]*[[:space:]:])?(refs/heads/)?(main|master)([[:space:]]|$|[;&|])'; then
    echo "BLOCKED: never push to main in alessandro823/pullwatch. Push a branch and open a pull request; Alessandro merges (CLAUDE.md, Where the work happens)." >&2
    exit 2
  fi
fi

if printf '%s' "$cmd" | grep -qE '(^|[;&|(][[:space:]]*)gh[[:space:]]+pr[[:space:]]+merge'; then
  echo "BLOCKED: never merge a pull request; Alessandro reviews and merges (CLAUDE.md, Where the work happens)." >&2
  exit 2
fi

# The gh default repository is the fork (the tracker); pull requests go to Alessandro's repository.
if printf '%s' "$cmd" | grep -qE '(^|[;&|(][[:space:]]*)gh[[:space:]]+pr[[:space:]]+create'; then
  if ! printf '%s' "$cmd" | grep -qE '(--repo|-R)[[:space:]=]+alessandro823/pullwatch([[:space:]]|$)'; then
    echo "BLOCKED: open pull requests in Alessandro's repository: gh pr create --repo alessandro823/pullwatch --base main (CLAUDE.md, Where the work happens)." >&2
    exit 2
  fi
fi

if printf '%s' "$cmd" | grep -qE 'security[[:space:]]+(export|delete-identity|delete-certificate|delete-keychain)'; then
  echo "BLOCKED: exporting or deleting signing identities is the owner's job, never a session's." >&2
  exit 2
fi

exit 0
