import Foundation

extension PipelineOrchestrator {
    func merge(system: [TranscriptSegment], mic: [TranscriptSegment], for session: RecordingSession) async throws -> [TranscriptSegment] {
        await upsertJob(from: session, status: "processing", stage: .mergingTranscripts)
        await loggingService.log(
            "Merging transcripts for job \(session.jobId)",
            level: .info,
            component: "Pipeline"
        )
        Self.appendToJobLog("--- merging_transcripts ---\n", at: session.paths.jobLogURL)
        let segments = try await transcriptMergeService.write(
            system: system,
            mic: mic,
            meetingFolder: session.paths.folderURL
        )
        await loggingService.log(
            "Merge completed for job \(session.jobId): system=\(system.count), mic=\(mic.count), merged=\(segments.count)",
            level: .info,
            component: "Pipeline"
        )
        let folder = session.paths.folderURL.path
        Self.appendToJobLog(
            "✅ Merge complete! \(segments.count) segments (system \(system.count), mic \(mic.count))\n" +
            "📄 Transcript: \(folder)/transcript.txt\n" +
            "🔗 JSON: \(folder)/transcript_merged.json\n",
            at: session.paths.jobLogURL
        )
        return segments
    }
}
