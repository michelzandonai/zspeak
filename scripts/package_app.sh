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

echo "==> Compilando Metal shaders do MLX"
METAL_DIR="$ROOT_DIR/.build/checkouts/mlx-swift/Source/Cmlx/mlx-generated/metal"
if [ -d "$METAL_DIR" ]; then
  MLX_AIR_DIR="$(mktemp -d)"
  find "$METAL_DIR" -name "*.metal" -exec sh -c '
    xcrun -sdk macosx metal -c "$1" -I "$2" -o "$3/$(basename "$1" .metal).air" 2>/dev/null
  ' _ {} "$METAL_DIR" "$MLX_AIR_DIR" \;
  xcrun -sdk macosx metallib "$MLX_AIR_DIR"/*.air -o "$MACOS_DIR/mlx.metallib" 2>/dev/null
  rm -rf "$MLX_AIR_DIR"
  echo "  mlx.metallib gerado ($(du -h "$MACOS_DIR/mlx.metallib" | cut -f1))"
else
  echo "  AVISO: Diretório Metal do MLX não encontrado, pulando metallib"
fi

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
