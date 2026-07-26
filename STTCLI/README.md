# STT - Speech-to-Text with Speaker Diarization

A macOS command-line utility wrapping the FluidAudio library providing speech-to-text transcription with speaker diarization using the Parakeet v3 model.

## Features

- **🎵 Audio Processing**: Supports MP3 and other common audio formats
- **🗣️ Speech Recognition**: Uses Parakeet TDT v3 (0.6b) for high-accuracy transcription
- **👥 Offline Speaker Diarization**: Uses the full recording with AHC + PLDA + VBx clustering
- **🚀 On-Device Processing**: Everything runs locally on Apple Neural Engine (ANE)
- **📄 Multiple Output Formats**: Individual transcripts, diarization results, and combined output

## Requirements

- macOS 14.0 or later
- Apple Silicon Mac (M1, M2, M3, M4) recommended for optimal performance
- Swift 5.10 or later

## Installation

### Build for AnyBrief

From the AnyBrief repository root:

```bash
make cli-stt
```

This builds the patched universal CLI and places it at `bin/stt`, ready for app
bundle embedding.

### Standalone build from source

```bash
swift build --package-path STTCLI -c release
```

The compiled binary will be available under `STTCLI/.build/release/stt`.

### Add to PATH (Optional)

```bash
# Copy to a directory in your PATH
cp STTCLI/.build/release/stt /usr/local/bin/stt
```

The upstream Homebrew formula may not include AnyBrief's
`OfflineDiarizerManager`, model-preparation, exact-count fallback, and
maximum-count extensions. Use the patched build for AnyBrief integration.

## Usage

### Basic Usage

```bash
# Transcribe and diarize an audio file
stt input.mp3

# Compare with the legacy per-speaker-turn ASR path
stt input.mp3 --turn-first

# Transcribe only (skip diarization)
stt input.mp3 --transcribe-only

# Download and compile the offline diarization models without an audio file
stt --prepare-diarization-models

# Verbose output
stt input.mp3 --verbose

# Custom output directory
stt input.mp3 --output ./results/

# Custom diarization threshold (0.0-1.0, default: 0.65)
stt input.mp3 --threshold 0.6

# Require exactly three speakers (with exact-count fallback)
stt input.mp3 --speakers 3

# Detect no more than five speakers; fewer are valid
stt input.mp3 --speaker-max 5
```

### Command Line Options

```
USAGE: stt [<input-file>] [--output <output>] [--verbose] [--transcribe-only] [--diarize-only] [--prepare-diarization-models] [--batch-first] [--turn-first] [--threshold <threshold>] [--speakers <speakers>] [--speaker-max <speaker-max>]

ARGUMENTS:
  <input-file>            Input audio file path (not required with --prepare-diarization-models)

OPTIONS:
  -o, --output <output>   Output directory for results (default: same as input file)
  -v, --verbose           Enable verbose output
  --transcribe-only       Skip diarization and only perform transcription
  --diarize-only          Skip transcription and only write diarization text and JSON
  --prepare-diarization-models
                          Download and compile offline diarization models, then exit
  --batch-first           Use full-audio transcription before diarization (the default)
  --turn-first            Use legacy per-speaker-turn transcription
  --threshold <threshold> Diarization clustering threshold (0.0-1.0, default: 0.65)
  --speakers <speakers>   Exact number of speakers (-1 = auto-detect)
  --speaker-max <N>       Maximum number of speakers; fewer speakers are allowed
  -h, --help             Show help information.
```

## Output Files

The tool generates up to four output files, depending on the selected mode:

### 1. `*_transcript.txt`
Pure transcription text without speaker information.

```
I think we have finally got a real competitor for anthropic...
```

### 2. `*_diarization.txt` (unless `--transcribe-only` is used)
Detailed diarization results with timing and speaker information.

```
SPEAKER DIARIZATION RESULTS
==========================

Audio Duration: 296.2 seconds
Speaker Count: 2
Segments: 15
Processing Time: 2.14 seconds
Real-time Factor: 0.14x

SPEAKER SEGMENTS:
-----------------
Speaker 1: 00:00.240 - 00:45.680 (45.4s) [Quality: 85.2%]
Speaker 2: 00:45.800 - 01:32.120 (46.3s) [Quality: 91.7%]
Speaker 1: 01:32.240 - 02:15.800 (43.6s) [Quality: 88.9%]
...
```

### 3. `*_diarization.json` (when diarization runs)

Machine-readable intervals used by `whisper-stt` and other timestamp-alignment
consumers. Each segment contains `start`, `end`, `speaker`, and `quality`.

### 4. `*_combined.txt`

Transcription combined with speaker information and timing.
With `--transcribe-only`, it contains timestamped speech without speaker
separation.

```
COMBINED TRANSCRIPT WITH SPEAKER DIARIZATION
===========================================

TRANSCRIPT BY SPEAKER:
---------------------

[00:00.240 - 00:45.680] Speaker 1:
I think we have finally got a real competitor for anthropic. The new model seems to be performing really well in our tests.

[00:45.800 - 01:32.120] Speaker 2:
Yes, I agree. The performance metrics are impressive, especially for code generation tasks.

...

FULL TRANSCRIPTION:
-------------------
I think we have finally got a real competitor for anthropic. The new model seems to be performing really well in our tests. Yes, I agree. The performance metrics are impressive, especially for code generation tasks...
```

## Performance

- **Real-time Factor**: Typically 0.05x - 0.2x (processes 1 minute of audio in 3-12 seconds)
- **Memory Usage**: Optimized for Apple Neural Engine with minimal CPU/GPU usage
- **Accuracy**: Competitive with state-of-the-art models
  - WER: ~2.7% on LibriSpeech test-clean
  - DER: ~17.7% on AMI benchmark for diarization

## Supported Languages

Parakeet v3 supports all 25 European languages:

- English, French, German, Italian, Spanish, Portuguese, Dutch, Polish, Russian, Ukrainian, Czech, Slovak, Hungarian, Romanian, Bulgarian, Croatian, Serbian, Slovenian, Estonian, Latvian, Lithuanian, Finnish, Danish, Swedish, Norwegian

## Examples

### Meeting Transcription
```bash
# Process a meeting recording with custom threshold
stt meeting_recording.mp3 --threshold 0.6 --verbose
```

### Podcast Processing
```bash
# Process multiple podcast episodes
for file in *.mp3; do
    echo "Processing $file..."
    stt "$file" --output ./podcast_transcripts/
done
```

### Quick Transcription Only
```bash
# Fast transcription without speaker identification
stt interview.mp3 --transcribe-only
```

### Three-Speaker Regression Fixture

The repository includes a 10-minute synthetic fixture for checking transcription quality on
a three-speaker product meeting. Speakers alternate throughout the recording, with unique
turn text and short pauses between turns, so WER alignment is not distorted by repeated
paragraphs.

```bash
# Regenerate the WAV fixture with macOS system voices
scripts/generate_three_speaker_fixture.sh

# Run stt, print WER/CER, and verify the speaker count
scripts/run_three_speaker_fixture.sh
```

The fixture lives in `Tests/Fixtures/three_speakers.wav` with its reference text in
`Tests/Fixtures/three_speakers_reference.txt` and turn-level source data in
`Tests/Fixtures/three_speakers_turns.json`. On the checked-in fixture, the current
local run reports `WER: 3.48%`, `CER: 2.70%`, and diarization reports 3 speakers with
`--speakers 3 --threshold 0.5`. The default diarized mode transcribes the full audio once,
uses FluidAudio token timestamps to align words with diarization segments, and then merges
adjacent words into speaker turns. Use `--turn-first` only to compare against the legacy
per-speaker-turn ASR path. Final diarization uses `OfflineDiarizerManager`; live transcript
processing is outside this CLI and does not use speaker diarization.

`--speakers N` requests exactly `N` speakers and applies the CLI fallback if
FluidAudio reconstruction returns another count. `--speaker-max N` (also accepted
as `--speakerMax N`) sets only an upper bound, so any result from one through `N`
speakers is valid. The two options are mutually exclusive.

For AnyBrief calendar recordings, participant-derived counts are passed through
`--speaker-max`, because attendees may be silent or absent. Live Transcript uses
`--transcribe-only` and intentionally does not run this diarization pipeline.

## Troubleshooting

### Model Download Issues
- Models are downloaded automatically on first use
- Run `stt --prepare-diarization-models` to prepare only offline diarization
  models without supplying an audio file
- Ensure internet connectivity for initial setup
- Models are cached under FluidAudio's application-support model directory;
  total size varies with the FluidAudio release

### Performance Issues
- Use Apple Silicon Macs for optimal performance
- Ensure sufficient free memory (4GB+ recommended)
- Close other intensive applications during processing

### Audio Format Issues
- The tool automatically converts audio to the required format (16kHz mono)
- Most common formats are supported (MP3, WAV, M4A, FLAC, etc.)
- File decoding uses Core Audio `ExtAudioFile`, avoiding an
  `AVAudioFile.framePosition` exception seen intermittently with valid VBR MP3 recordings

### Diarization Accuracy
- Adjust `--threshold` parameter (lower = more speakers, higher = fewer speakers)
- Default 0.65 works well for most cases
- Try 0.6 for conversations with many speakers
- Try 0.8 for interviews with distinct speakers

## Technical Details

### Models Used
- **ASR**: Parakeet TDT v3 (0.6b) - NVIDIA's transformer-based model
- **Diarization**: FluidAudio offline community-1 pipeline with Pyannote powerset
  segmentation, WeSpeaker embeddings, PLDA scoring, and VBx clustering
- **VAD**: Silero VAD v2 for voice activity detection

### Processing Pipeline
1. Audio format conversion (16kHz mono)
2. One full-file Parakeet transcription pass
3. Offline powerset segmentation and speaker embedding extraction
4. PLDA/AHC/VBx speaker clustering with optional exact or maximum constraint
5. Token-timestamp alignment with diarization intervals
6. Adjacent-word merging into speaker turns
7. Output generation and formatting

## Credits

Built with:
- [FluidAudio](https://github.com/FluidInference/FluidAudio) - Native Swift SDK for local audio AI
- [Swift Argument Parser](https://github.com/apple/swift-argument-parser) - Command line parsing
- Apple's CoreML and AVFoundation frameworks

## License

This project is licensed under the MIT License. See the FluidAudio library for its Apache 2.0 license.
