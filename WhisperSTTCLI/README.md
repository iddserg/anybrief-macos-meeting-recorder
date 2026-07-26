# whisper-stt

`whisper-stt` is AnyBrief's tracked wrapper around a full-file `whisper.cpp`
transcription. It combines Whisper word timestamps with the offline FluidAudio
speaker intervals produced by the bundled `stt` helper and writes the same
`<name>_combined.txt` format consumed by AnyBrief.

Whisper runs once over the complete recording, preserving context and avoiding
per-speaker model reloads. FluidAudio diarization uses
`OfflineDiarizerManager`; Live Transcript is a separate non-diarized path.

## Usage

```bash
whisper-stt meeting.wav \
  --output ./result \
  --model ./models/ggml-small.bin \
  --language ru \
  --speakers 3 \
  --threshold 0.65
```

Speaker constraints:

- `--speakers N` requires exactly N speakers. The underlying `stt` helper uses
  its exact-count fallback if offline reconstruction returns another count.
- `--speaker-max N` allows any detected count from one through N. The
  compatibility spelling `--speakerMax N` is also accepted.
- `--speakers` and `--speaker-max` cannot be combined.
- `--speakers=-1` leaves the speaker count unconstrained.

AnyBrief calendar mode uses `--speaker-max`, because not every participant
necessarily speaks. The wrapper passes the selected constraint unchanged to
`stt --diarize-only`.

Other important options:

- `--transcribe-only` skips FluidAudio diarization.
- `--vad-model FILE` enables Silero voice activity detection before Whisper,
  suppressing recognition on silence and low-level background noise.
- `--threshold 0...1` sets the FluidAudio clustering threshold (default `0.65`).
- `--no-gpu` disables Whisper Metal acceleration.
- `--threads N` sets whisper.cpp worker threads.
- `--vocabulary-file FILE` passes preferred terms to whisper.cpp as an initial
  prompt; aliases after a colon are normalized in the generated transcript.
- `--diarization-json FILE` reuses existing FluidAudio intervals.
- `--whisper-json FILE` reuses existing full whisper.cpp JSON.

## Runtime layout

The three executables must be next to each other in the app bundle:

```text
Contents/Resources/bin/
├── stt
├── whisper-stt
└── whisper-cli-core
```

A multilingual ggml model is supplied with `--model` or `WHISPER_MODEL`.
The Silero model is supplied with `--vad-model` or `WHISPER_VAD_MODEL`.
Prepare the shared offline diarization models directly through the helper:

```bash
stt --prepare-diarization-models
```

## Output

The wrapper writes:

- `<name>_transcript.txt` — plain Whisper transcript;
- `<name>_diarization.txt` — FluidAudio speaker report;
- `<name>_diarization.json` — machine-readable FluidAudio intervals;
- `<name>_whisper.json` — complete whisper.cpp output with token timestamps;
- `<name>_combined.txt` — timestamped speaker turns.

## Build and test

```bash
swift build -c release --arch arm64 --arch x86_64
swift test
```

The repository `Makefile` builds the wrapper, pins and builds whisper.cpp, then
copies both executables alongside `stt` into `bin/`.
