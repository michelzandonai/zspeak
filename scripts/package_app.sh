#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="zspeak"
BUILD_DIR="$(cd "$ROOT_DIR" && swift build --show-bin-path)"
APP_DIR="$ROOT_DIR/build/$APP_NAME.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
INFO_PLIST="$ROOT_DIR/zspeak/Info.plist"
ENTITLEMENTS="$ROOT_DIR/zspeak/zspeak.entitlements"

detect_identity() {
  security find-identity -v -p codesigning \
    | awk -F '"' '/Apple Development:/ { print $2; exit }'
}

SIGNING_IDENTITY="${SIGNING_IDENTITY:-$(detect_identity)}"
if [[ -z "${SIGNING_IDENTITY}" ]]; then
  SIGNING_IDENTITY="-"
fi

echo "==> Buildando binário"
cd "$ROOT_DIR"
swift build

echo "==> Montando bundle em $APP_DIR"
rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"
cp "$BUILD_DIR/$APP_NAME" "$MACOS_DIR/$APP_NAME"
cp "$INFO_PLIST" "$CONTENTS_DIR/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleExecutable $APP_NAME" "$CONTENTS_DIR/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleName $APP_NAME" "$CONTENTS_DIR/Info.plist"

echo "==> Assinando app com '$SIGNING_IDENTITY'"
codesign \
  --force \
  --deep \
  --sign "$SIGNING_IDENTITY" \
  --entitlements "$ENTITLEMENTS" \
  --timestamp=none \
  "$APP_DIR"

echo "==> Verificando assinatura"
codesign --verify --deep --strict "$APP_DIR"

echo
echo "App pronto em:"
echo "  $APP_DIR"
