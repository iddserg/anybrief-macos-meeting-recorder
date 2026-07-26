#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FIXTURE_DIR="$ROOT_DIR/Tests/Fixtures"
OUTPUT_DIR="${1:-$ROOT_DIR/.build/three-speaker-fixture}"

mkdir -p "$OUTPUT_DIR"

swift run stt \
  "$FIXTURE_DIR/three_speakers.wav" \
  --output "$OUTPUT_DIR" \
  --speakers 3 \
  --threshold 0.5

"$ROOT_DIR/scripts/evaluate_transcript.py" \
  "$FIXTURE_DIR/three_speakers_reference.txt" \
  "$OUTPUT_DIR/three_speakers_transcript.txt" \
  --max-wer 0.20 \
  --max-cer 0.15

if ! grep -q "Speaker Count: 3" "$OUTPUT_DIR/three_speakers_diarization.txt"; then
  echo "Expected diarization to find exactly 3 speakers." >&2
  exit 1
fi

echo "Outputs written to $OUTPUT_DIR"
