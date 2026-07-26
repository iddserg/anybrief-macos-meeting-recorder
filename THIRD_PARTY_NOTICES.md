# Third-party software

AnyBrief builds on open-source projects that remain under their own licenses:

- [FluidAudio](https://github.com/FluidInference/FluidAudio) — local
  transcription and speaker diarization.
- [whisper.cpp](https://github.com/ggml-org/whisper.cpp) — local Whisper
  inference. The build is pinned in `Makefile`.
- [Swift Argument Parser](https://github.com/apple/swift-argument-parser) —
  command-line argument parsing for `STTCLI`.
- [FFmpeg](https://ffmpeg.org/) and [LAME](https://lame.sourceforge.io/) —
  bundled audio conversion in release builds.

`STTCLI/LICENSE` preserves the license and copyright notice for the embedded
STT command-line source. Refer to each dependency's repository and the
licenses included in distributed binaries for complete terms.
