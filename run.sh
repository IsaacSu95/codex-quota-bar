#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
APP_BIN="$ROOT/dist/CodexQuotaBar.app/Contents/MacOS/CodexMeter"

if [[ ! -x "$APP_BIN" ]]; then
  "$ROOT/build_app.sh" >/dev/null
fi

nohup "$APP_BIN" >/private/tmp/codex-quota-bar.log 2>&1 &
echo "Codex Quota Bar started: $!"
