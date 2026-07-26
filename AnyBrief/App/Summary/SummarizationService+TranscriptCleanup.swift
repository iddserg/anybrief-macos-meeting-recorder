import Foundation

extension SummarizationService {
    func cleanupTranscript(
        transcript: String,
        settings: AppSettings,
        workingDirectory: URL? = nil,
        transcriptURL: URL? = nil,
        progress: (@Sendable (LLMProgressEvent) async -> Void)? = nil
    ) async throws -> String {
        guard let prompt = settings.prompts.transcriptCleanupPrompt else {
            throw SummarizationError.missingConfiguration("transcript cleanup prompt")
        }
        let output = try await llmService.process(
            text: transcript,
            prompt: prompt.text,
            speakerContext: settings.prompts.trimmedSpeakerContext,
            connections: settings.transcriptCleanupLLMChain,
            settings: settings,
            workingDirectory: workingDirectory,
            transcriptURL: transcriptURL,
            progress: progress
        )
        return output.text
    }

    /// Prefixes the transcript with calendar-only frontmatter so the cleanup
    /// model can infer real speaker names from the meeting title/attendees.
    func transcriptCleanupInput(transcript: String, calendarEvent: CalendarEvent?) -> String {
        guard let calendarEvent else {
            return transcript
        }
        let frontmatter = calendarFrontmatter(calendarEvent).joined(separator: "\n")
        guard !frontmatter.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return transcript
        }
        return """
        Meeting metadata frontmatter:
        ```yaml
        \(frontmatter)
        ```

        Transcript:
        \(transcript)
        """
    }
}
