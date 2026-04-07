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

# ffmpeg arm64 — baixa de martin-riedl.de e cacheia localmente
FFMPEG_URL="https://ffmpeg.martin-riedl.de/redirect/latest/macos/arm64/release/ffmpeg.zip"
FFMPEG_CACHE_DIR="$HOME/.cache/zspeak/ffmpeg-arm64"
FFMPEG_CACHE_BINARY="$FFMPEG_CACHE_DIR/ffmpeg"

detect_identity() {
  security find-identity -v -p codesigning \
    | awk -F '"' '/Apple Development:/ { print $2; exit }'
}

SIGNING_IDENTITY="${SIGNING_IDENTITY:-$(detect_identity)}"
if [[ -z "${SIGNING_IDENTITY}" ]]; then
  SIGNING_IDENTITY="-"
fi

download_ffmpeg() {
  if [[ -f "$FFMPEG_CACHE_BINARY" ]] && [[ -x "$FFMPEG_CACHE_BINARY" ]]; then
    echo "  ffmpeg cache hit ($(du -h "$FFMPEG_CACHE_BINARY" | cut -f1))"
    return 0
  fi

  mkdir -p "$FFMPEG_CACHE_DIR"
  local tmp_zip="$(mktemp -t ffmpeg-XXXXXX.zip)"

  echo "  Baixando ffmpeg arm64 de martin-riedl.de..."
  if ! curl -fsSL -o "$tmp_zip" "$FFMPEG_URL"; then
    rm -f "$tmp_zip"
    echo "  ERRO: download do ffmpeg falhou. Verifique conexão com a internet."
    return 1
  fi

  local tmp_extract="$(mktemp -d)"
  if ! unzip -q "$tmp_zip" -d "$tmp_extract"; then
    rm -rf "$tmp_extract" "$tmp_zip"
    echo "  ERRO: extração do ffmpeg.zip falhou."
    return 1
  fi

  # Localiza o binário ffmpeg dentro do zip (estrutura pode variar)
  local extracted_binary="$(find "$tmp_extract" -type f -name ffmpeg -perm +111 | head -n 1)"
  if [[ -z "$extracted_binary" ]]; then
    extracted_binary="$(find "$tmp_extract" -type f -name ffmpeg | head -n 1)"
  fi
  if [[ -z "$extracted_binary" ]]; then
    rm -rf "$tmp_extract" "$tmp_zip"
    echo "  ERRO: binário ffmpeg não encontrado no zip baixado."
    return 1
  fi

  cp "$extracted_binary" "$FFMPEG_CACHE_BINARY"
  chmod +x "$FFMPEG_CACHE_BINARY"
  rm -rf "$tmp_extract" "$tmp_zip"

  # Valida que é um executável arm64
  if ! file "$FFMPEG_CACHE_BINARY" | grep -q "arm64"; then
    echo "  AVISO: ffmpeg baixado não é arm64 nativo — verifique."
  fi

  echo "  ffmpeg baixado e cacheado ($(du -h "$FFMPEG_CACHE_BINARY" | cut -f1))"
}

echo "==> Buildando binário"
cd "$ROOT_DIR"
swift build

echo "==> Preparando ffmpeg arm64 (para transcrição de arquivos não-nativos)"
download_ffmpeg

echo "==> Montando bundle em $APP_DIR"
rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"
cp "$BUILD_DIR/$APP_NAME" "$MACOS_DIR/$APP_NAME"
cp "$INFO_PLIST" "$CONTENTS_DIR/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleExecutable $APP_NAME" "$CONTENTS_DIR/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleName $APP_NAME" "$CONTENTS_DIR/Info.plist"

# Copia ffmpeg para dentro do bundle
if [[ -f "$FFMPEG_CACHE_BINARY" ]]; then
  cp "$FFMPEG_CACHE_BINARY" "$MACOS_DIR/ffmpeg"
  chmod +x "$MACOS_DIR/ffmpeg"
  echo "  ffmpeg copiado para $MACOS_DIR/ffmpeg"
else
  echo "  AVISO: ffmpeg não está no cache — feature de transcrição de arquivos não-nativos ficará indisponível"
fi

echo "==> Compilando Metal shaders do MLX"
METAL_DIR="$ROOT_DIR/.build/checkouts/mlx-swift/Source/Cmlx/mlx-generated/metal"
if [ ! -d "$METAL_DIR" ]; then
  echo "  AVISO: Diretório Metal do MLX não encontrado, pulando metallib"
elif ! xcrun -sdk macosx metal --version >/dev/null 2>&1; then
  echo "  AVISO: Metal Toolchain ausente — correção LLM (MLX) ficará indisponível no DMG."
  echo "         Para habilitar, rode: xcodebuild -downloadComponent MetalToolchain"
else
  MLX_AIR_DIR="$(mktemp -d)"
  find "$METAL_DIR" -name "*.metal" -exec sh -c '
    xcrun -sdk macosx metal -c "$1" -I "$2" -o "$3/$(basename "$1" .metal).air" 2>/dev/null
  ' _ {} "$METAL_DIR" "$MLX_AIR_DIR" \;
  if compgen -G "$MLX_AIR_DIR/*.air" > /dev/null; then
    xcrun -sdk macosx metallib "$MLX_AIR_DIR"/*.air -o "$MACOS_DIR/mlx.metallib" 2>/dev/null
    echo "  mlx.metallib gerado ($(du -h "$MACOS_DIR/mlx.metallib" | cut -f1))"
  else
    echo "  AVISO: nenhum .air gerado, pulando metallib"
  fi
  rm -rf "$MLX_AIR_DIR"
fi

# Assina o ffmpeg embutido ANTES do app (requisito do hardened runtime)
if [[ -f "$MACOS_DIR/ffmpeg" ]]; then
  echo "==> Re-assinando ffmpeg embutido"
  codesign --remove-signature "$MACOS_DIR/ffmpeg" 2>/dev/null || true
  codesign \
    --force \
    --sign "$SIGNING_IDENTITY" \
    --options runtime \
    --timestamp=none \
    "$MACOS_DIR/ffmpeg"
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

echo "==> Gerando DMG"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$CONTENTS_DIR/Info.plist" 2>/dev/null || echo '0.0.0')"
DMG_PATH="$ROOT_DIR/${APP_NAME}-${VERSION}.dmg"
STAGING_DIR="$(mktemp -d)"
cp -R "$APP_DIR" "$STAGING_DIR/"
ln -s /Applications "$STAGING_DIR/Applications"
rm -f "$DMG_PATH"
hdiutil create \
  -volname "$APP_NAME" \
  -srcfolder "$STAGING_DIR" \
  -ov \
  -format UDZO \
  "$DMG_PATH"
rm -rf "$STAGING_DIR"

echo
echo "App pronto em:"
echo "  $APP_DIR"
echo "DMG pronto em:"
echo "  $DMG_PATH"
