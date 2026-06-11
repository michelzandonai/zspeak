#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="zspeak"
SOURCE_APP="$ROOT_DIR/build/$APP_NAME.app"
TARGET_APP="/Applications/$APP_NAME.app"

"$ROOT_DIR/scripts/package_app.sh"

echo "==> Instalando em $TARGET_APP"
pkill -x "$APP_NAME" >/dev/null 2>&1 || true
for _ in {1..25}; do
  if ! pgrep -x "$APP_NAME" >/dev/null 2>&1; then
    break
  fi
  sleep 0.2
done
rm -rf "$TARGET_APP"
ditto "$SOURCE_APP" "$TARGET_APP"
xattr -dr com.apple.quarantine "$TARGET_APP" >/dev/null 2>&1 || true

echo "==> Abrindo app"
opened=0
for _ in {1..5}; do
  if open "$TARGET_APP"; then
    opened=1
    break
  fi
  sleep 1
done
if [[ "$opened" != "1" ]]; then
  echo "  ERRO: não foi possível abrir $TARGET_APP"
  exit 1
fi

echo
echo "App instalado em:"
echo "  $TARGET_APP"
