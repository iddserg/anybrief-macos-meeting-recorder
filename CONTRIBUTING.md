# Contributing

Issues and focused pull requests are welcome.

Before submitting a change:

1. Keep provider-specific code inside its transcription, LLM, or automation
   module.
2. Do not add secrets, recordings, model weights, generated binaries, build
   output, or signing material.
3. Run:

   ```bash
   xcodebuild build -scheme AnyBrief -project AnyBrief.xcodeproj \
     -destination platform=macOS \
     -derivedDataPath /private/tmp/anybrief-derived

   xcodebuild test -scheme AnyBrief -project AnyBrief.xcodeproj \
     -destination platform=macOS \
     -derivedDataPath /private/tmp/anybrief-derived

   swift test --package-path STTCLI
   swift test --package-path WhisperSTTCLI
   ```

For large architectural changes, open an issue first.
