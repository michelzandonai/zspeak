#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="zspeak"
DERIVED_DATA_PATH="$ROOT_DIR/build"
BUILD_DIR="$DERIVED_DATA_PATH/Build/Products/Release"
APP_DIR="$ROOT_DIR/build/$APP_NAME.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
INFO_PLIST="$ROOT_DIR/zspeak/Info.plist"
ENTITLEMENTS="$ROOT_DIR/zspeak/zspeak.entitlements"
LOCAL_SIGNING_IDENTITY_NAME="zspeak Local Code Signing"
ALLOW_MISSING_MLX_METALLIB="${ALLOW_MISSING_MLX_METALLIB:-0}"

# ffmpeg arm64 — baixa de martin-riedl.de e cacheia localmente
FFMPEG_URL="https://ffmpeg.martin-riedl.de/redirect/latest/macos/arm64/release/ffmpeg.zip"
FFMPEG_CACHE_DIR="$HOME/.cache/zspeak/ffmpeg-arm64"
FFMPEG_CACHE_BINARY="$FFMPEG_CACHE_DIR/ffmpeg"

detect_identity() {
  security find-identity -v -p codesigning \
    | awk -F '"' '/Developer ID Application:|Apple Development:|Mac Developer:/ { print $2; exit }'
}

detect_local_identity() {
  security find-identity -v -p codesigning \
    | awk -F '"' -v name="$LOCAL_SIGNING_IDENTITY_NAME" '$0 ~ name { print $2; exit }'
}

create_local_identity() {
  local identity
  identity="$(detect_local_identity)"
  if [[ -n "$identity" ]]; then
    echo "$identity"
    return 0
  fi

  local cert_dir="$HOME/.cache/zspeak/codesign"
  local keychain="$HOME/Library/Keychains/login.keychain-db"
  local key_path="$cert_dir/zspeak-local-codesign.key"
  local cert_path="$cert_dir/zspeak-local-codesign.crt"
  local p12_path="$cert_dir/zspeak-local-codesign.p12"
  local p12_password="zspeak-local-codesign"
  local openssl_config="$cert_dir/openssl-code-signing.cnf"

  mkdir -p "$cert_dir"
  cat > "$openssl_config" <<CONFIG
[ req ]
distinguished_name = req_distinguished_name
x509_extensions = v3_req
prompt = no

[ req_distinguished_name ]
CN = $LOCAL_SIGNING_IDENTITY_NAME

[ v3_req ]
basicConstraints = critical,CA:FALSE
keyUsage = critical,digitalSignature
extendedKeyUsage = codeSigning
subjectKeyIdentifier = hash
CONFIG

  echo "  Criando identidade local de assinatura: $LOCAL_SIGNING_IDENTITY_NAME" >&2
  openssl req \
    -new \
    -newkey rsa:2048 \
    -x509 \
    -days 3650 \
    -nodes \
    -config "$openssl_config" \
    -keyout "$key_path" \
    -out "$cert_path" >/dev/null 2>&1

  openssl pkcs12 \
    -export \
    -out "$p12_path" \
    -inkey "$key_path" \
    -in "$cert_path" \
    -passout pass:"$p12_password" >/dev/null 2>&1

  security import "$p12_path" \
    -k "$keychain" \
    -P "$p12_password" \
    -A \
    -T /usr/bin/codesign \
    -T /usr/bin/security >/dev/null

  security add-trusted-cert \
    -d \
    -r trustRoot \
    -p codeSign \
    -k "$keychain" \
    "$cert_path" >/dev/null 2>&1 || true

  identity="$(detect_local_identity)"
  if [[ -n "$identity" ]]; then
    echo "$identity"
  fi
}

SIGNING_IDENTITY="${SIGNING_IDENTITY:-$(detect_identity)}"
if [[ -z "${SIGNING_IDENTITY}" ]]; then
  SIGNING_IDENTITY="$(create_local_identity)"
fi
if [[ -z "${SIGNING_IDENTITY}" ]]; then
  echo "  AVISO: identidade local indisponível; usando assinatura ad-hoc."
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
xcodebuild \
  -scheme "$APP_NAME" \
  -configuration Release \
  -destination "platform=macOS" \
  -derivedDataPath "$DERIVED_DATA_PATH" \
  build

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
METAL_DIR="$ROOT_DIR/build/SourcePackages/checkouts/mlx-swift/Source/Cmlx/mlx-generated/metal"
if [ ! -d "$METAL_DIR" ]; then
  METAL_DIR="$ROOT_DIR/.build/checkouts/mlx-swift/Source/Cmlx/mlx-generated/metal"
fi
if [ ! -d "$METAL_DIR" ]; then
  if [[ "$ALLOW_MISSING_MLX_METALLIB" == "1" ]]; then
    echo "  AVISO: diretório Metal do MLX não encontrado: $METAL_DIR"
    echo "         Gerando bundle sem MLX; Modo Prompt mostrara erro em runtime."
  else
    echo "  ERRO: diretório Metal do MLX não encontrado: $METAL_DIR"
    echo "        Rode swift package resolve/swift build antes de empacotar."
    exit 1
  fi
elif ! xcrun -sdk macosx metal --version >/dev/null 2>&1; then
  if [[ "$ALLOW_MISSING_MLX_METALLIB" == "1" ]]; then
    echo "  AVISO: Metal Toolchain ausente."
    echo "         Gerando bundle sem MLX; Modo Prompt mostrara erro em runtime."
  else
    echo "  ERRO: Metal Toolchain ausente."
    echo "        Rode: xcodebuild -downloadComponent MetalToolchain"
    echo "        Sem mlx.metallib, o Modo Prompt/LLM nao pode inicializar com seguranca."
    exit 1
  fi
else
  MLX_AIR_DIR="$(mktemp -d)"
  find "$METAL_DIR" -name "*.metal" -exec sh -c '
    xcrun -sdk macosx metal -c "$1" -I "$2" -o "$3/$(basename "$1" .metal).air" 2>/dev/null
  ' _ {} "$METAL_DIR" "$MLX_AIR_DIR" \;
  # zsh nullglob qualifier (N) — array vazio se não houver matches, sem erro
  air_files=( "$MLX_AIR_DIR"/*.air(N) )
  if (( ${#air_files} > 0 )); then
    xcrun -sdk macosx metallib "${air_files[@]}" -o "$MACOS_DIR/mlx.metallib" 2>/dev/null
    echo "  mlx.metallib gerado ($(du -h "$MACOS_DIR/mlx.metallib" | cut -f1)) — ${#air_files} shaders"
  else
    rm -rf "$MLX_AIR_DIR"
    if [[ "$ALLOW_MISSING_MLX_METALLIB" == "1" ]]; then
      echo "  AVISO: nenhum .air gerado; bundle sera criado sem MLX."
    else
      echo "  ERRO: nenhum .air gerado; nao foi possivel criar mlx.metallib"
      exit 1
    fi
  fi
  rm -rf "$MLX_AIR_DIR"
fi

if [[ ! -s "$MACOS_DIR/mlx.metallib" ]]; then
  if [[ "$ALLOW_MISSING_MLX_METALLIB" == "1" ]]; then
    echo "  AVISO: mlx.metallib ausente no bundle final"
  else
    echo "  ERRO: mlx.metallib ausente no bundle final"
    exit 1
  fi
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
