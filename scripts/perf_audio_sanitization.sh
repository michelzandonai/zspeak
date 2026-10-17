#!/bin/bash
set -euo pipefail
# PCM Float32 válido deve manter o buffer e todos os bits da referência.
TASK_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TASK_TEMP="$(mktemp -d "${TMPDIR:-/tmp}/zspeak-sanitization-bench.XXXXXX")"
trap 'rm -rf "$TASK_TEMP"' EXIT
xcrun swiftc -O -whole-module-optimization -swift-version 6 \
  "$TASK_ROOT/zspeak/AudioSampleSanitizer.swift" \
  "$TASK_ROOT/Tests/Support/AudioSanitizationReference.swift" \
  "$TASK_ROOT/scripts/benchmarks/AudioSanitizationBenchmark.swift" \
  -o "$TASK_TEMP/sanitization-benchmark"
"$TASK_TEMP/sanitization-benchmark"
