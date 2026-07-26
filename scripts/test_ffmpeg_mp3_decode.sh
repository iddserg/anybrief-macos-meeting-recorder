#!/bin/sh
set -eu

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
ffmpeg_path=${1:-"$repo_root/bin/ffmpeg"}
fixture_path="$repo_root/AnyBriefTests/Fixtures/short-audio.mp3"
temporary_directory=$(mktemp -d "${TMPDIR:-/tmp}/anybrief-mp3-test.XXXXXX")
output_path="$temporary_directory/normalized.wav"

cleanup() {
    rm -rf "$temporary_directory"
}
trap cleanup EXIT HUP INT TERM

test -x "$ffmpeg_path"
test -s "$fixture_path"

"$ffmpeg_path" \
    -hide_banner \
    -loglevel error \
    -y \
    -i "$fixture_path" \
    -vn \
    -ac 1 \
    -ar 16000 \
    -codec:a pcm_s16le \
    "$output_path"

test -s "$output_path"
test "$(dd if="$output_path" bs=1 count=4 2>/dev/null)" = "RIFF"
test "$(dd if="$output_path" bs=1 skip=8 count=4 2>/dev/null)" = "WAVE"

channels=$(od -An -tu2 -j22 -N2 "$output_path" | tr -d ' ')
sample_rate=$(od -An -tu4 -j24 -N4 "$output_path" | tr -d ' ')
bits_per_sample=$(od -An -tu2 -j34 -N2 "$output_path" | tr -d ' ')
output_size=$(wc -c < "$output_path" | tr -d ' ')

test "$channels" = "1"
test "$sample_rate" = "16000"
test "$bits_per_sample" = "16"
test "$output_size" -gt 1000

echo "MP3 decode integration test passed: ${sample_rate}Hz, ${channels}ch, ${bits_per_sample}-bit, $output_size bytes"
