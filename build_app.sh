#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
OUT="$ROOT/dist/CodexQuotaBar.app"

mkdir -p "$ROOT/.build/release" "$ROOT/dist" "$OUT/Contents/MacOS" "$OUT/Contents/Resources"

CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-/private/tmp/codex-quota-bar-clang-cache}" \
swiftc "$ROOT/Sources/CodexMeter/main.swift" \
  -o "$OUT/Contents/MacOS/CodexMeter" \
  -framework AppKit

cp "$ROOT/App/Info.plist" "$OUT/Contents/Info.plist"
chmod +x "$OUT/Contents/MacOS/CodexMeter"

echo "$OUT"
