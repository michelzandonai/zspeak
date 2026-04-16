#!/usr/bin/env bash
# Gera fixtures de áudio para testes de integração do zspeak.
#
# Requisitos: macOS (usa `say` e `afconvert` nativos).
#
# Saídas (todas WAV PCM 16-bit mono 16kHz):
#   - pt-short.wav   (~2-3s)  Frase curta em PT-BR
#   - pt-long.wav    (~15s)   Parágrafo com code-switching (termos técnicos em inglês)
#   - silence.wav    (5s)     Silêncio puro — usado para checar que o modelo não alucina
#
# Uso:
#   bash Tests/Fixtures/generate.sh
#
# Idempotente: sobrescreve arquivos existentes. Commita os WAVs gerados.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# Voz PT-BR estável presente em qualquer macOS 14+ (Luciana é instalada por padrão)
VOICE="Luciana"

# Formato PCM 16-bit little-endian mono 16kHz — casa com o pipeline do Parakeet
FORMAT="LEI16@16000"

echo "[generate.sh] Gerando pt-short.wav..."
say -v "$VOICE" \
    -o "pt-short.wav" \
    --data-format="$FORMAT" \
    "Olá mundo, teste de transcrição local."

echo "[generate.sh] Gerando pt-long.wav..."
say -v "$VOICE" \
    -o "pt-long.wav" \
    --data-format="$FORMAT" \
    "Hoje preciso ajustar o pipeline de deploy no Kubernetes. Também vou revisar o banco de dados PostgreSQL e conferir o cache do Redis. Depois abro um pull request com as alterações."

echo "[generate.sh] Gerando silence.wav..."
# Gera 5s de silêncio: say '' não funciona, então usamos afconvert a partir
# de /dev/zero. 5s * 16000 samples * 2 bytes = 160000 bytes de PCM raw.
SILENCE_RAW="$(mktemp -t zspeak-silence).raw"
dd if=/dev/zero of="$SILENCE_RAW" bs=160000 count=1 status=none
afconvert \
    -f WAVE \
    -d LEI16@16000 \
    -c 1 \
    --input-format-hint "LEI16@16000/1" \
    "$SILENCE_RAW" \
    "silence.wav" 2>/dev/null || {
        # Fallback: se --input-format-hint falhar (versões antigas), usa sox-less caminho
        # criando WAV manualmente com header via printf.
        python3 - <<'PY'
import struct, wave
with wave.open("silence.wav", "wb") as w:
    w.setnchannels(1)
    w.setsampwidth(2)
    w.setframerate(16000)
    w.writeframes(b"\x00" * (16000 * 2 * 5))
PY
    }
rm -f "$SILENCE_RAW"

echo ""
echo "[generate.sh] Fixtures geradas:"
for f in pt-short.wav pt-long.wav silence.wav; do
    if [[ -f "$f" ]]; then
        size=$(stat -f%z "$f")
        printf "  %-16s  %8d bytes\n" "$f" "$size"
    else
        echo "  ERRO: $f não foi gerada"
        exit 1
    fi
done

echo ""
echo "[generate.sh] Verificação de formato:"
for f in pt-short.wav pt-long.wav silence.wav; do
    info=$(afinfo "$f" 2>/dev/null | grep "Data format" || echo "afinfo falhou")
    printf "  %-16s  %s\n" "$f" "$info"
done

echo ""
echo "[generate.sh] OK. Commite os 3 WAVs para usar nos testes."
