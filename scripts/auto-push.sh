#!/bin/bash
# Commits and pushes every change in this repo.
# Run by the Claude Code Stop hook in .claude/settings.json at the end of each Claude reply.
# Safe to run by hand too: ./scripts/auto-push.sh

set -u
cd "$(dirname "$0")/.." || exit 0
git rev-parse --git-dir >/dev/null 2>&1 || exit 0

say() { printf '{"systemMessage": "auto-push: %s"}\n' "$1"; }

git add -A
git diff --cached --quiet && exit 0   # nothing changed

# The repo is public: refuse to commit anything that looks like a secret.
if git diff --cached -U0 | grep -E '^\+' | grep -Eq \
  'sk-ant-[A-Za-z0-9_-]{10,}|sb_secret_[A-Za-z0-9_-]{10,}|eyJ[A-Za-z0-9_-]{15,}\.eyJ[A-Za-z0-9_-]{15,}|BEGIN [A-Z ]*PRIVATE KEY|gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}'; then
  git reset -q
  say "possible secret (API key or token) in the changes. Nothing was committed. Remove it or add the file to .gitignore."
  exit 0
fi

count=$(git diff --cached --name-only | wc -l | tr -d ' ')
files=$(git diff --cached --name-only | head -3 | xargs -n1 basename | paste -sd ',' - | sed 's/,/, /g')
[ "$count" -gt 3 ] && files="$files and $((count - 3)) more"

git commit -q -m "Update $files" \
  -m "Auto-committed by the Claude Code Stop hook (scripts/auto-push.sh)." \
  -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>" || exit 0

if git push -q origin HEAD >/dev/null 2>&1; then
  say "committed and pushed $count file(s)"
else
  say "committed $count file(s) but the push failed (offline or not logged in?). It will go up with the next push."
fi
