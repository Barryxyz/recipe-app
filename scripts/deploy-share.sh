#!/bin/bash
# Deploys the shared-recipe page (F4.2) to Cloudflare Workers. Publishes it publicly.
#   ./scripts/deploy-share.sh login    one-time: opens the browser to sign in to Cloudflare
#   ./scripts/deploy-share.sh          deploy (runs the page tests first)
# Needs Node 18+: uses ~/.local/node22 when present (this Mac's Homebrew can't upgrade Node).
set -euo pipefail
cd "$(dirname "$0")/../share"
[ -x "$HOME/.local/node22/bin/node" ] && export PATH="$HOME/.local/node22/bin:$PATH"
WRANGLER="npx --yes wrangler@4.156.0"
case "${1:-}" in
  login) exec $WRANGLER login ;;
  "") ;;
  *) echo "Unknown option: $1 (use 'login', or nothing to deploy)"; exit 1 ;;
esac
deno test --quiet test
$WRANGLER deploy
