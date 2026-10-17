#!/bin/bash
set -euo pipefail
# Mede somente busca de corte e limite do preview; não executa ASR ou microfone.
TASK_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TASK_TEMP="$(mktemp -d "${TMPDIR:-/tmp}/zspeak-preview-bench.XXXXXX")"
trap 'rm -rf "$TASK_TEMP"' EXIT
xcrun swiftc -O -whole-module-optimization -swift-version 6 \
  "$TASK_ROOT/zspeak/AudioSamplePadding.swift" \
  "$TASK_ROOT/zspeak/LiveTranscription.swift" \
  "$TASK_ROOT/scripts/benchmarks/LivePreviewBacklogBenchmark.swift" \
  -o "$TASK_TEMP/preview-benchmark"
"$TASK_TEMP/preview-benchmark"
