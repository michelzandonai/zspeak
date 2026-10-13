#!/bin/bash
set -euo pipefail

# Benchmark do código de captura real, otimizado como o app Release.
# Uso: ./scripts/perf_capture_bench.sh --seconds 600 --trials 5 > resultado.json
TASK_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TASK_TEMP="$(mktemp -d "${TMPDIR:-/tmp}/zspeak-capture-bench.XXXXXX")"
trap 'rm -rf "$TASK_TEMP"' EXIT
xcrun swiftc -O -whole-module-optimization -swift-version 6 \
  "$TASK_ROOT/zspeak/StreamingResampler.swift" \
  "$TASK_ROOT/zspeak/AudioTimelineMixer.swift" \
  "$TASK_ROOT/zspeak/LiveSampleEmitter.swift" \
  "$TASK_ROOT/scripts/benchmarks/CaptureBenchmark.swift" \
  -o "$TASK_TEMP/capture-benchmark"
"$TASK_TEMP/capture-benchmark" "$@"
