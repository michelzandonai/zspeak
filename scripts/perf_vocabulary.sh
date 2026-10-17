#!/bin/bash
set -euo pipefail
# Compara o matcher real e o ITN com a revisão anterior, sem carregar ASR/UI.
TASK_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TASK_TEMP="$(mktemp -d "${TMPDIR:-/tmp}/zspeak-vocabulary-bench.XXXXXX")"
trap 'rm -rf "$TASK_TEMP"' EXIT
BASELINE_REV="4daadce01a08c24a884a7d53d6daea539f030617"
git -C "$TASK_ROOT" show "$BASELINE_REV:zspeak/PTBRTextNormalizer.swift" \
  | sed -e 's/PTBRTextNormalizer/PTBRTextNormalizerReference/g' \
        -e 's/TextNormalizationSettings/TextNormalizationSettingsReference/g' \
  > "$TASK_TEMP/PTBRTextNormalizerReference.swift"
xcrun swiftc -O -whole-module-optimization -swift-version 6 \
  "$TASK_ROOT/zspeak/VocabularyEntry.swift" \
  "$TASK_ROOT/zspeak/VocabularyReplacements.swift" \
  "$TASK_ROOT/zspeak/PTBRTextNormalizer.swift" \
  "$TASK_TEMP/PTBRTextNormalizerReference.swift" \
  "$TASK_ROOT/Tests/Support/VocabularyReplacementReference.swift" \
  "$TASK_ROOT/Tests/Support/TextPostProcessingRegressionCorpus.swift" \
  "$TASK_ROOT/scripts/benchmarks/VocabularyBenchmark.swift" \
  -o "$TASK_TEMP/vocabulary-benchmark"
"$TASK_TEMP/vocabulary-benchmark"
