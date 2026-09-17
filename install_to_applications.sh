#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
APP="$ROOT/dist-share/CodexQuotaBar.app"
TARGET="$HOME/Applications/CodexQuotaBar.app"

if [[ ! -d "$APP" ]]; then
  "$ROOT/package_share.sh" >/dev/null
fi

mkdir -p "$HOME/Applications"
rm -rf "$TARGET"
ditto "$APP" "$TARGET"
xattr -cr "$TARGET" 2>/dev/null || true

echo "$TARGET"
