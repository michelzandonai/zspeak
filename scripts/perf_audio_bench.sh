#!/usr/bin/env bash
#
# Coleta logs `PerfAudio` do zspeak e imprime histograma p50/p95 por etapa.
#
# Uso:
#   ./scripts/perf_audio_bench.sh                # janela padrão: últimos 5 minutos
#   ./scripts/perf_audio_bench.sh --last 10m
#   ./scripts/perf_audio_bench.sh --csv          # saída CSV (para planilha/grep)
#   ./scripts/perf_audio_bench.sh --raw          # imprime as linhas brutas e sai
#
# Fluxo recomendado:
#   1. Rode o app (Xcode → Cmd+R, ou abrir o bundle).
#   2. Execute 10 ciclos hotkey → falar 1-2s → hotkey de novo (stop).
#   3. Rode este script. Saída fica no terminal e em /tmp/zspeak-perf-<ts>.csv.
#
# Pré-requisitos:
#   - macOS com `log show` (sempre disponível).
#   - python3 (vem com Xcode CLT / macOS recente).
#
# O script lê o subsystem `com.zspeak` / category `PerfAudio` que o
# `PerfSignposter` emite no formato:
#   PERF event=<nome> phase=<begin|end|mark> [key=value ...] [elapsed_ms=X.XX]
#
set -euo pipefail

LAST="5m"
STYLE="human"
RAW_ONLY=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --last)
      LAST="$2"; shift 2 ;;
    --csv)
      STYLE="csv"; shift ;;
    --raw)
      RAW_ONLY=1; shift ;;
    -h|--help)
      sed -n '2,20p' "$0"; exit 0 ;;
    *)
      echo "argumento desconhecido: $1" >&2; exit 2 ;;
  esac
done

PRED='subsystem == "com.zspeak" AND category == "PerfAudio"'

# `log show --style ndjson` produz uma linha JSON por evento. Filtramos
# apenas as que contêm `PERF event=` para descartar logs auxiliares.
RAW=$(log show --predicate "$PRED" --info --style ndjson --last "$LAST" 2>/dev/null \
  | python3 -c '
import sys, json
for raw in sys.stdin:
    raw = raw.strip()
    if not raw or raw[0] != "{":
        continue
    try:
        obj = json.loads(raw)
    except Exception:
        continue
    msg = obj.get("eventMessage", "")
    if msg.startswith("PERF event="):
        print(msg)
' || true)

if [[ -z "$RAW" ]]; then
  echo "Nenhum log PerfAudio encontrado nos últimos $LAST." >&2
  echo "Rode o app, execute ciclos hotkey/stop, e tente de novo." >&2
  exit 1
fi

if [[ "$RAW_ONLY" -eq 1 ]]; then
  echo "$RAW"
  exit 0
fi

TS=$(date +%Y%m%d-%H%M%S)
CSV_PATH="/tmp/zspeak-perf-${TS}.csv"
RAW_PATH=$(mktemp "${TMPDIR:-/tmp}/zspeak-perf-raw.XXXXXX")
trap 'rm -f "$RAW_PATH"' EXIT
printf '%s\n' "$RAW" > "$RAW_PATH"

STYLE="$STYLE" CSV_PATH="$CSV_PATH" RAW_PATH="$RAW_PATH" python3 - <<'PY'
import os, sys
from collections import defaultdict

style = os.environ.get("STYLE", "human")
csv_path = os.environ.get("CSV_PATH", "/tmp/zspeak-perf.csv")
raw_path = os.environ["RAW_PATH"]

groups = defaultdict(list)
mark_counts = defaultdict(int)

with open(raw_path) as source:
  for line in source:
    line = line.strip()
    if not line.startswith("PERF event="):
        continue
    parts = line.split()
    kv = {}
    for p in parts[1:]:
        if "=" in p:
            k, v = p.split("=", 1)
            kv[k] = v
    event = kv.get("event", "?")
    phase = kv.get("phase", "")
    path = kv.get("path") or kv.get("scope") or "-"

    if phase == "mark":
        mark_counts[(event, path)] += 1
        continue

    if phase != "end":
        continue

    elapsed = kv.get("elapsed_ms")
    if elapsed is None:
        continue
    try:
        elapsed_f = float(elapsed)
    except ValueError:
        continue
    groups[(event, path)].append(elapsed_f)


def percentile(xs, p):
    if not xs:
        return 0.0
    xs = sorted(xs)
    k = (len(xs) - 1) * p
    f = int(k)
    c = min(f + 1, len(xs) - 1)
    if f == c:
        return xs[f]
    return xs[f] + (xs[c] - xs[f]) * (k - f)


rows = []
for (event, path), xs in sorted(groups.items()):
    rows.append({
        "event": event,
        "path": path,
        "n": len(xs),
        "p50_ms": percentile(xs, 0.5),
        "p95_ms": percentile(xs, 0.95),
        "min_ms": min(xs),
        "max_ms": max(xs),
    })

# Sempre escreve CSV em /tmp para análise externa
with open(csv_path, "w") as f:
    f.write("event,path,count,p50_ms,p95_ms,min_ms,max_ms\n")
    for r in rows:
        f.write(f"{r['event']},{r['path']},{r['n']},{r['p50_ms']:.2f},{r['p95_ms']:.2f},{r['min_ms']:.2f},{r['max_ms']:.2f}\n")

if style == "csv":
    sys.stdout.write(open(csv_path).read())
    sys.exit(0)

# Saída human-readable
print()
print(f"  {'event':<28} {'path':<8} {'n':>3} {'p50_ms':>9} {'p95_ms':>9} {'min_ms':>9} {'max_ms':>9}")
print(f"  {'-'*28} {'-'*8} {'-'*3} {'-'*9} {'-'*9} {'-'*9} {'-'*9}")
for r in rows:
    print(f"  {r['event']:<28} {r['path']:<8} {r['n']:>3} {r['p50_ms']:>9.2f} {r['p95_ms']:>9.2f} {r['min_ms']:>9.2f} {r['max_ms']:>9.2f}")

if mark_counts:
    print()
    print("  eventos pontuais (sem duração):")
    for (event, path), n in sorted(mark_counts.items()):
        print(f"  - {event:<28} {path:<8} {n:>3}x")

print()
print(f"  CSV salvo em: {csv_path}")
PY
