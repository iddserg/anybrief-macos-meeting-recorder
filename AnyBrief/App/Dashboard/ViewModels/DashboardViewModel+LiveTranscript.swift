import SwiftUI

extension DashboardViewModel {
    func setLiveTranscriptVisible(_ visible: Bool) {
        liveTranscriptService.setVisible(visible && liveTranscriptEnabled)
    }

    func toggleLiveTranscript() {
        guard liveTranscriptEnabled else {
            liveTranscriptService.setVisible(false)
            liveTranscriptService.setUserEnabled(false)
            return
        }
        liveTranscriptService.setUserEnabled(!liveTranscriptSnapshot.isUserEnabled)
    }

    func updateLiveTranscriptRecordingState(_ isRecording: Bool) {
        liveTranscriptService.setRecordingActive(isRecording)
    }

    var canProcessLiveTranscriptPrompt: Bool {
        isLiveLLMConfigured
            && !isProcessingLiveTranscriptPrompt
            && !liveTranscriptPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !liveTranscriptSnapshot.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var liveTranscriptLLMPlaceholder: String {
        if !isLiveLLMConfigured {
            return String(localized: "Enable at least one LLM connection in the LLM tab first.")
        }
        if liveTranscriptPromptMessageIsError, let liveTranscriptPromptMessage {
            return liveTranscriptPromptMessage
        }
        return String(localized: "LLM output will appear here.")
    }

    func processLiveTranscriptPrompt() {
        liveTranscriptPromptTask?.cancel()
        liveTranscriptPromptTask = nil
        liveTranscriptAutoRerunPending = false
        runLiveTranscriptPrompt(after: 0)
    }

    /// Auto mode never cancels an in-flight LLM request: transcript chunks
    /// arrive faster than the LLM responds, so cancel-and-restart would starve
    /// the output forever. Instead, coalesce updates into one pending rerun
    /// that fires with the freshest transcript once the current request ends.
    func processLiveTranscriptPromptIfAutoEnabled() {
        guard liveTranscriptAutoProcessEnabled else {
            return
        }
        guard !liveTranscriptSnapshot.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !liveTranscriptPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }
        if liveTranscriptPromptTask != nil {
            liveTranscriptAutoRerunPending = true
            return
        }
        runLiveTranscriptPrompt(after: 700_000_000)
    }

    func cancelLiveTranscriptPromptProcessing() {
        liveTranscriptPromptTask?.cancel()
        liveTranscriptPromptTask = nil
        liveTranscriptAutoRerunPending = false
        isProcessingLiveTranscriptPrompt = false
    }

    func clearLiveTranscript() {
        cancelLiveTranscriptPromptProcessing()
        liveTranscriptService.clearTranscript()
        liveTranscriptLLMOutput = ""
        liveTranscriptPromptMessage = nil
        liveTranscriptPromptMessageIsError = false
    }

    var canClearLiveTranscript: Bool {
        !liveTranscriptSnapshot.text.isEmpty || !liveTranscriptLLMOutput.isEmpty
    }

    private func runLiveTranscriptPrompt(after delayNanoseconds: UInt64) {
        guard !liveTranscriptSnapshot.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            isProcessingLiveTranscriptPrompt = false
            liveTranscriptPromptMessage = String(localized: "Live transcript is empty.")
            liveTranscriptPromptMessageIsError = true
            return
        }
        guard !liveTranscriptPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            isProcessingLiveTranscriptPrompt = false
            liveTranscriptPromptMessage = String(localized: "Prompt is empty.")
            liveTranscriptPromptMessageIsError = true
            return
        }

        isProcessingLiveTranscriptPrompt = true
        liveTranscriptPromptMessage = String(localized: "Processing with summary LLM settings...")
        liveTranscriptPromptMessageIsError = false

        liveTranscriptPromptTask = Task { [weak self] in
            guard let self else { return }
            if delayNanoseconds > 0 {
                try? await Task.sleep(nanoseconds: delayNanoseconds)
                if Task.isCancelled {
                    return
                }
            }

            // Read at execution time so the request covers the newest chunks.
            let transcript = self.liveTranscriptSnapshot.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let prompt = self.liveTranscriptPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !transcript.isEmpty, !prompt.isEmpty else {
                self.finishLiveTranscriptPrompt()
                return
            }

            do {
                let settings = await appSettingsStore.load(using: loggingService)
                let chain = settings.liveLLMChain
                guard !chain.isEmpty else {
                    self.liveTranscriptPromptMessage = String(
                        localized: "Enable at least one LLM connection in the LLM tab first."
                    )
                    self.liveTranscriptPromptMessageIsError = true
                    self.finishLiveTranscriptPrompt()
                    return
                }
                let result = try await llmService.process(
                    text: transcript,
                    prompt: prompt,
                    connections: chain,
                    settings: settings
                )
                if Task.isCancelled {
                    return
                }
                self.liveTranscriptLLMOutput = result.text
                self.liveTranscriptPromptMessage = String(localized: "Processed.")
                self.liveTranscriptPromptMessageIsError = false
            } catch {
                if Task.isCancelled {
                    return
                }
                self.liveTranscriptPromptMessage = error.localizedDescription
                self.liveTranscriptPromptMessageIsError = true
            }
            self.finishLiveTranscriptPrompt()
        }
    }

    private func finishLiveTranscriptPrompt() {
        isProcessingLiveTranscriptPrompt = false
        liveTranscriptPromptTask = nil
        if liveTranscriptAutoProcessEnabled, liveTranscriptAutoRerunPending {
            liveTranscriptAutoRerunPending = false
            runLiveTranscriptPrompt(after: 0)
        }
    }

    var liveTranscriptStatusText: String {
        liveTranscriptStatusText(now: Date())
    }

    func liveTranscriptStatusText(now: Date) -> String {
        switch liveTranscriptSnapshot.status {
        case .idle:
            return String(localized: "Stopped")
        case .waitingForRecording:
            return String(localized: "Waiting for recording")
        case .starting:
            return String(localized: "Starting")
        case .running:
            let statusPrefix = liveTranscriptSnapshot.lastChunkMessage == nil
                ? String(localized: "Listening to system audio")
                : String(localized: "No system speech detected")
            guard let nextChunkAt = liveTranscriptSnapshot.nextChunkAt else {
                return statusPrefix
            }

            let seconds = max(0, Int(ceil(nextChunkAt.timeIntervalSince(now))))
            if seconds == 0 {
                return "\(statusPrefix) · \(String(localized: "next chunk now"))"
            }
            return "\(statusPrefix) · \(String(format: String(localized: "next chunk in %ds"), seconds))"
        case .transcribing:
            return String(localized: "Transcribing")
        case .stopping:
            return String(localized: "Stopping")
        case let .failed(message):
            return message
        }
    }

    var liveTranscriptStatusColor: Color {
        switch liveTranscriptSnapshot.status {
        case .idle:
            return ABDesign.secondaryText
        case .waitingForRecording, .starting, .transcribing, .stopping:
            return ABDesign.yellow
        case .running:
            if liveTranscriptSnapshot.lastChunkMessage != nil,
               liveTranscriptSnapshot.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return ABDesign.yellow
            }
            return ABDesign.green
        case .failed:
            return ABDesign.red
        }
    }

    var liveTranscriptPlaceholder: String {
        if liveTranscriptSnapshot.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           let message = liveTranscriptSnapshot.lastChunkMessage {
            return message + " " + String(localized: "Make sure Screen Recording permission is granted and the meeting or media is playing through system audio.")
        }
        return String(localized: "Live transcript will appear here.")
    }
}
