#!/bin/bash
set -euo pipefail
# Compara preparo real vs referência 1.0.64, com gate de igualdade bit a bit.
TASK_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TASK_TEMP="$(mktemp -d "${TMPDIR:-/tmp}/zspeak-speech-bench.XXXXXX")"
trap 'rm -rf "$TASK_TEMP"' EXIT
xcrun swiftc -O -whole-module-optimization -swift-version 6 \
  "$TASK_ROOT/zspeak/SpeechSampleTrimmer.swift" \
  "$TASK_ROOT/zspeak/SpeechSignalConditioner.swift" \
  "$TASK_ROOT/zspeak/AudioSamplePadding.swift" \
  "$TASK_ROOT/Tests/Support/SpeechPreparationReference.swift" \
  "$TASK_ROOT/scripts/benchmarks/SpeechPreparationBenchmark.swift" \
  -o "$TASK_TEMP/speech-benchmark"
"$TASK_TEMP/speech-benchmark"
