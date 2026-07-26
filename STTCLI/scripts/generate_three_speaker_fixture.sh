#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FIXTURE_DIR="$ROOT_DIR/Tests/Fixtures"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

OUT_WAV="$FIXTURE_DIR/three_speakers.wav"
REF_TXT="$FIXTURE_DIR/three_speakers_reference.txt"
META_JSON="$FIXTURE_DIR/three_speakers_metadata.json"
TURNS_JSON="$FIXTURE_DIR/three_speakers_turns.json"
TARGET_SECONDS="${TARGET_SECONDS:-600}"
SILENCE_SECONDS="${SILENCE_SECONDS:-0.85}"
SPEECH_RATE="${SPEECH_RATE:-125}"

mkdir -p "$FIXTURE_DIR"

require_voice() {
  local voice="$1"
  if ! say -v '?' | awk '{print $1}' | grep -Fxq "$voice"; then
    echo "Missing macOS voice: $voice" >&2
    echo "Install it in System Settings -> Accessibility -> Spoken Content -> System Voice." >&2
    exit 1
  fi
}

duration_seconds() {
  ffprobe -v error -show_entries format=duration -of default=nk=1:nw=1 "$1"
}

duration_to_millis() {
  awk -v value="$1" 'BEGIN { printf "%d", value * 1000 }'
}

require_voice "Samantha"
require_voice "Daniel"
require_voice "Karen"

cat > "$TMP_DIR/turns.tsv" <<'EOF'
speaker_1	Samantha	Good morning team. This is the regression call for the desktop recorder, and we will cover recording, calendar data, summaries, and release checks.
speaker_2	Daniel	I have the latest build running. The app starts cleanly, the menu item appears in the system bar, and the dashboard opens without a delay.
speaker_3	Karen	I will track quality notes. Please mention exact feature names because the reference transcript should help us find recognition mistakes later.
speaker_1	Samantha	First topic is manual recording. When the user presses start, the status panel should switch to recording and the stop button should become active.
speaker_2	Daniel	The system audio stream starts first. The microphone stream joins after that, and both channels write separate wave files before post processing.
speaker_3	Karen	I checked the silent microphone option. If silence mode is enabled, the microphone meter must stay hidden and the output should contain generated silence.
speaker_1	Samantha	That behavior matters for privacy. A user may want system sound from the meeting, but they may not want their own room audio captured.
speaker_2	Daniel	The status card now shows the active job, current stage, started time, and duration. It also shows compact meters for system sound and microphone.
speaker_3	Karen	The meters are useful, but the test phrase should include both channel names. System sound has signal. Microphone has signal. Silence should be explicit.
speaker_1	Samantha	Second topic is calendar autopilot. The app reads CalDAV events, finds meetings with links, and starts recording before the scheduled start time.
speaker_2	Daniel	For each event, we keep the title, start date, end date, meeting URL, organizer, attendee list, and participant count when it is available.
speaker_3	Karen	The participant count is important for recognition. If the setting says from calendar, the recognizer should receive the calendar count instead of auto detect.
speaker_1	Samantha	The calendar page should show today's schedule in a simple list. Past meetings should look muted, current meetings should stand out, and future meetings should stay readable.
speaker_2	Daniel	We removed the stretched calendar blocks because they made short events look too large. Each event row now uses content height instead of duration height.
speaker_3	Karen	Please include edge cases in this fixture. One meeting has one participant, another has seven participants, and another has thirteen participants.
speaker_1	Samantha	Third topic is summary generation. After recording stops, the pipeline converts audio, transcribes speech, writes front matter, and creates a markdown summary.
speaker_2	Daniel	Front matter should include all useful calendar metadata. That means event identifier, title, times, URL, organizer, attendees, and participant count.
speaker_3	Karen	If a calendar field is missing, the summary should still be valid markdown. Empty fields should not break parsing or hide the transcript.
speaker_1	Samantha	The recent meetings table should be compact. The summary action comes first, then the folder icon, then the delete icon.
speaker_2	Daniel	Meeting names can be edited inline. Pressing enter commits the rename, and completed meetings should rename the folder when the new title is saved.
speaker_3	Karen	Delete must remove the whole meeting recording folder, but it should ask for confirmation first so a user does not lose data by mistake.
speaker_1	Samantha	Fourth topic is localization. The application should not mix Russian and English labels in one screen unless the text is a technical field name.
speaker_2	Daniel	The sidebar uses Russian section names. Status, meetings, autopilot, settings, logs, and permissions should all have consistent typography and spacing.
speaker_3	Karen	Buttons need short labels. Long labels should either wrap cleanly or become icons with tooltips, but they must not clip inside the button.
speaker_1	Samantha	Fifth topic is permissions. Microphone, screen recording, and notifications should show granted or missing states with clear system settings buttons.
speaker_2	Daniel	The permissions screen should not scroll at the default window size. It should fit the card, the permission rows, and the privacy note.
speaker_3	Karen	Notifications should use the app icon. If the icon is missing in a system notification, the bundle resources need another look.
speaker_1	Samantha	Sixth topic is logs. The log screen should auto scroll to the newest message unless the user disables auto scroll with a checkbox.
speaker_2	Daniel	Log rows should use a small readable monospaced font. Activity logs and errors should have separate framed areas with enough padding.
speaker_3	Karen	A clear logs button is fine, but it should not sit too close to the checkbox. The click target needs to include the whole button shape.
speaker_1	Samantha	Seventh topic is packaging. The disk image should contain the current app, the version string should be simple, and the landing page should link to the download.
speaker_2	Daniel	The GitHub action builds the disk image. It checks out the repository, prepares private command line dependencies, runs make dmg, and uploads the artifact.
speaker_3	Karen	If a private dependency token is missing, the action should fail with a helpful message. The message should name the exact secret that is required.
speaker_1	Samantha	Eighth topic is distribution. Unsigned builds can be shared for testing, but Developer ID signing and notarization are needed for a smoother install experience.
speaker_2	Daniel	A teammate with an Apple Developer account can export a Developer ID certificate and provide credentials through repository secrets for the release workflow.
speaker_3	Karen	We should document that process carefully. Testers need to know which builds are local, which builds are signed, and which builds are notarized.
speaker_1	Samantha	Ninth topic is speech recognition quality. This file should be long enough to test transcription stability, punctuation tolerance, and diarization behavior.
speaker_2	Daniel	Unlike the first fixture, this scenario should not repeat the same block. Repetition makes word error rate misleading when the alignment shifts.
speaker_3	Karen	Each turn should have a stable speaker identifier, voice name, and source text. A separate turns file makes debugging easier than one huge paragraph.
speaker_1	Samantha	The reference text still stays useful for word error rate and character error rate. It should be normalized before comparing with the hypothesis.
speaker_2	Daniel	The turn file is useful for future checks. Later we can compare expected speaker order with detected diarization segments and find speaker swaps.
speaker_3	Karen	For now, we should at least verify that the recognizer finds three speakers and that the text error rate stays within an expected range.
speaker_1	Samantha	Tenth topic is audio format. The fixture should be mono wave audio at sixteen kilohertz with signed sixteen bit samples.
speaker_2	Daniel	That format is small enough for the repository and simple enough for command line tools to inspect with ffprobe or similar utilities.
speaker_3	Karen	Short pauses are intentional. They make turns easier to separate while still sounding like a realistic structured team call.
speaker_1	Samantha	Eleventh topic is error handling. If transcription fails, the command should return a useful error instead of crashing or printing an empty output.
speaker_2	Daniel	If diarization returns more labels than expected, the labels should continue past speaker Z without breaking or losing segments.
speaker_3	Karen	If word allocation fails near a segment boundary, the transcript should keep the words in order and avoid assigning everything to one speaker.
speaker_1	Samantha	Twelfth topic is app performance. Starting a recording should not block the user interface or make system audio lag for several seconds.
speaker_2	Daniel	Audio startup work should stay off the main thread where possible. The dashboard can update state after the recorder confirms the session has started.
speaker_3	Karen	If the computer goes to sleep during recording, the app should stop gracefully and still process valid microphone and system files.
speaker_1	Samantha	Thirteenth topic is file naming. In progress folders can keep a technical suffix, but completed folders should use the saved meeting name when possible.
speaker_2	Daniel	If the user renames a completed meeting after summary generation, the folder rename should happen at the same time as the metadata update.
speaker_3	Karen	Names must be sanitized for the file system. Slashes, colons, and very long titles should not create invalid paths.
speaker_1	Samantha	Fourteenth topic is agent access. The integrations settings tab exposes a local base URL and API key for automation tools.
speaker_2	Daniel	The key can be regenerated with one button. Copy should copy the current connection details without showing duplicate fields.
speaker_3	Karen	The integrations tab belongs after application settings, because most users will adjust summaries, recognition, and calendar before external automation.
speaker_1	Samantha	Fifteenth topic is the landing page. It should describe autopilot, local recording, calendar metadata, summaries, and compact meeting management.
speaker_2	Daniel	Competitor features are useful for positioning, but the page should avoid fake customer names and avoid mentioning real private company examples.
speaker_3	Karen	The download link should point to the latest disk image on the server, and the readme should explain how the image is produced.
speaker_1	Samantha	Sixteenth topic is release hygiene. Profiling files and local Xcode signing changes should stay out of git unless we intentionally change project settings.
speaker_2	Daniel	Build artifacts belong in ignored paths. Source files, fixture scripts, fixture metadata, and the regression audio file belong in the repository.
speaker_3	Karen	This test should be deterministic enough for manual regression checks, even if exact speech recognition scores vary by model version.
speaker_1	Samantha	Before we close, let us confirm the expected outcome. The transcript should cover all product topics without losing a whole section.
speaker_2	Daniel	The evaluator should print reference word count, hypothesis word count, word errors, word error rate, and character error rate.
speaker_3	Karen	The output folder should contain the plain transcript, diarization report, and combined report so a developer can inspect failures quickly.
speaker_1	Samantha	If the word error rate gets worse after a code change, the developer should inspect the largest missing phrases before changing thresholds.
speaker_2	Daniel	If the speaker count changes, the developer should inspect the diarization threshold and the segment report instead of assuming transcription broke.
speaker_3	Karen	This concludes the fixture recording. Three voices spoke in a mixed order, the content was unique, and the reference data is ready for testing.
EOF

ffmpeg -hide_banner -loglevel error -y \
  -f lavfi -i "anullsrc=r=16000:cl=mono" \
  -t "$SILENCE_SECONDS" "$TMP_DIR/silence.wav"

reference_text=""
concat_entries=""
turns_tsv="$TMP_DIR/generated_turns.tsv"
: > "$turns_tsv"
total_millis=0
target_millis=$((TARGET_SECONDS * 1000))
turn_index=0
cycle=1

while [ "$total_millis" -lt "$target_millis" ]; do
  while IFS=$'\t' read -r speaker_id voice text; do
    turn_index=$((turn_index + 1))
    basename="$(printf '%03d_%s_cycle_%02d' "$turn_index" "$speaker_id" "$cycle")"
    aiff_path="$TMP_DIR/$basename.aiff"
    wav_path="$TMP_DIR/$basename.wav"

    say -v "$voice" -r "$SPEECH_RATE" -o "$aiff_path" "$text"
    ffmpeg -hide_banner -loglevel error -y -i "$aiff_path" -ar 16000 -ac 1 "$wav_path"

    concat_entries+="file '$wav_path'
file '$TMP_DIR/silence.wav'
"
    printf "%s\t%s\t%s\t%s\n" "$turn_index" "$speaker_id" "$voice" "$text" >> "$turns_tsv"
    if [ -z "$reference_text" ]; then
      reference_text="$text"
    else
      reference_text="$reference_text $text"
    fi

    turn_duration="$(duration_seconds "$wav_path")"
    turn_millis="$(duration_to_millis "$turn_duration")"
    silence_millis="$(duration_to_millis "$SILENCE_SECONDS")"
    total_millis=$((total_millis + turn_millis + silence_millis))

    if [ "$total_millis" -ge "$target_millis" ]; then
      break
    fi
  done < "$TMP_DIR/turns.tsv"
  cycle=$((cycle + 1))
done

printf "%s" "$concat_entries" > "$TMP_DIR/concat.txt"

ffmpeg -hide_banner -loglevel error -y \
  -f concat -safe 0 -i "$TMP_DIR/concat.txt" \
  -ar 16000 -ac 1 -c:a pcm_s16le "$OUT_WAV"

printf "%s\n" "$reference_text" > "$REF_TXT"

actual_duration="$(duration_seconds "$OUT_WAV")"

cat > "$META_JSON" <<EOF
{
  "audio": "three_speakers.wav",
  "reference": "three_speakers_reference.txt",
  "turns": "three_speakers_turns.json",
  "sampleRateHz": 16000,
  "channels": 1,
  "format": "pcm_s16le wav",
  "speechRateWordsPerMinute": $SPEECH_RATE,
  "silenceBetweenTurnsSeconds": $SILENCE_SECONDS,
  "targetDurationSeconds": $TARGET_SECONDS,
  "actualDurationSeconds": $actual_duration,
  "turnCount": $turn_index,
  "recommendedCommand": "swift run stt Tests/Fixtures/three_speakers.wav --output .build/three-speaker-fixture --speakers 3 --threshold 0.5",
  "speakers": [
    {
      "id": "speaker_1",
      "voice": "Samantha",
      "role": "product lead"
    },
    {
      "id": "speaker_2",
      "voice": "Daniel",
      "role": "engineer"
    },
    {
      "id": "speaker_3",
      "voice": "Karen",
      "role": "qa"
    }
  ]
}
EOF

python3 - "$turns_tsv" "$TURNS_JSON" <<'PY'
import csv
import json
import sys
from pathlib import Path

source = Path(sys.argv[1])
target = Path(sys.argv[2])
turns = []

with source.open(encoding="utf-8", newline="") as handle:
    reader = csv.reader(handle, delimiter="\t")
    for row in reader:
        index, speaker_id, voice, text = row
        turns.append(
            {
                "index": int(index),
                "speakerId": speaker_id,
                "voice": voice,
                "text": text,
            }
        )

target.write_text(json.dumps(turns, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
PY

echo "Wrote $OUT_WAV"
echo "Wrote $REF_TXT"
echo "Wrote $META_JSON"
echo "Wrote $TURNS_JSON"
echo "Duration: ${actual_duration}s"
echo "Turns: $turn_index"
