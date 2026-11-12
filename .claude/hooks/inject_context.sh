#!/usr/bin/env bash
# .claude/hooks/inject_context.sh
#
# Claude Code SessionStart hook. Prints the state a session needs to orient:
# the remotes, open issues with their type and priority, git status.

set -uo pipefail

root="${CLAUDE_PROJECT_DIR:-$(cd "$(dirname "$0")/../.." && pwd)}"
cd "$root" || exit 0

echo "=== Pullwatch: read CLAUDE.md first ==="
echo
echo "=== remotes (origin = Alessandro's repository, where pull requests go; fork = ours, the tracker) ==="
git remote -v 2>/dev/null | awk '$3 == "(fetch)" { print $1 "  " $2 }'
echo
echo "=== open issues (tracker: $(gh repo set-default --view 2>/dev/null || echo 'no default set')) ==="
# <Type/Priority> is the native issue type and the Priority field (CLAUDE.md,
# Workflow); read one issue with: gh issue view <n> --json title,body,comments
# shellcheck disable=SC2016 # $labels is a jq binding
gh issue list --state open --limit 50 --json number,title,labels \
  --jq '.[] | ([.labels[].name] | join(", ")) as $labels | "#\(.number)  \(.title)  [\($labels)]"' 2>/dev/null |
  while IFS= read -r line; do
    n="${line%%  *}"
    tp="$(bash scripts/gh/fields.sh show "${n#\#}" 2>/dev/null | awk '/^  type:/ { t = $2 } /^  priority:/ { p = $2 } END { printf "%s/%s", t, p }')"
    echo "${line/  \[/  <${tp:-?/?}>  [}"
  done || echo "(gh unavailable)"
echo
echo "=== git status ==="
git status --short --branch 2>/dev/null
echo
echo "=== last 5 commits ==="
git log --oneline -5 2>/dev/null
