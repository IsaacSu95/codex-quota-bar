#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
BUILD_BIN="$ROOT/.build/release/CodexMeter"
APP="$ROOT/dist-share/CodexQuotaBar.app"

mkdir -p "$ROOT/.build/release" "$ROOT/dist-share"

CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-/private/tmp/codex-quota-bar-clang-cache}" \
swiftc "$ROOT/Sources/CodexMeter/main.swift" \
  -o "$BUILD_BIN" \
  -framework AppKit

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BUILD_BIN" "$APP/Contents/MacOS/CodexMeter"
chmod +x "$APP/Contents/MacOS/CodexMeter"

cp "$ROOT/App/Info.plist" "$APP/Contents/Info.plist"

printf 'APPL????' > "$APP/Contents/PkgInfo"

xattr -cr "$APP" 2>/dev/null || true
codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || true

ditto -c -k --keepParent "$APP" "$ROOT/dist-share/CodexQuotaBar.zip"

echo "$APP"
echo "$ROOT/dist-share/CodexQuotaBar.zip"
