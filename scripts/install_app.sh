#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="zspeak"
SOURCE_APP="$ROOT_DIR/build/$APP_NAME.app"
TARGET_APP="/Applications/$APP_NAME.app"

"$ROOT_DIR/scripts/package_app.sh"

echo "==> Instalando em $TARGET_APP"
pkill -x "$APP_NAME" >/dev/null 2>&1 || true
rm -rf "$TARGET_APP"
ditto "$SOURCE_APP" "$TARGET_APP"
xattr -dr com.apple.quarantine "$TARGET_APP" >/dev/null 2>&1 || true

echo "==> Abrindo app"
open "$TARGET_APP"

echo
echo "App instalado em:"
echo "  $TARGET_APP"
