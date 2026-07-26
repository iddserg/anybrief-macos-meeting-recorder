
import Foundation

extension DashboardViewModel.CurrentActivity {
    var isRecording: Bool {
        status == "recording" || stage == "recording"
    }

    var showsSeparateStatus: Bool {
        stage != status
    }

    var summaryText: String {
        let stageLabel = detailedStageLabel
        guard showsSeparateStatus else {
            return stageLabel
        }
        return "\(stageLabel) · \(DashboardStatusLabels.label(for: status))"
    }

    var detailedStageLabel: String {
        guard let detail else {
            return DashboardStatusLabels.label(for: stage)
        }
        let phase: String
        switch detail.phase {
        case .transcriptCleanup:
            phase = String(localized: "Cleaning transcript")
        case .summarization:
            phase = String(localized: "Summarizing")
        }
        guard let connectionName = detail.connectionName, !connectionName.isEmpty else {
            return phase
        }
        return "\(phase) · \(connectionName)"
    }

    var fallbackText: String? {
        guard let detail,
              let connectionName = detail.connectionName,
              let connectionIndex = detail.connectionIndex,
              let connectionCount = detail.connectionCount else {
            return nil
        }
        let position = String(
            format: String(localized: "Connection %d of %d"),
            connectionIndex,
            connectionCount
        )
        guard let fallbackFrom = detail.fallbackFrom, !fallbackFrom.isEmpty else {
            return position
        }
        return String(
            format: String(localized: "%@ → %@ · %@"),
            fallbackFrom,
            connectionName,
            position
        )
    }
}

enum DashboardStatusLabels {
    static func label(for status: String) -> String {
        switch status {
        case "recording":
            return String(localized: "Recording")
        case "recorded":
            return String(localized: "Recorded")
        case "processing":
            return String(localized: "Processing")
        case "completed":
            return String(localized: "Completed")
        case "partial", "partial_success":
            return String(localized: "Partial")
        case "failed":
            return String(localized: "Failed")
        case "interrupted", "recording_interrupted":
            return String(localized: "Interrupted")
        case "cancelled":
            return String(localized: "Cancelled")
        case "skipped":
            return String(localized: "Skipped")
        case "transcribing_system":
            return String(localized: "Transcribing system audio")
        case "transcribing_mic":
            return String(localized: "Transcribing microphone")
        case "merging_transcripts":
            return String(localized: "Merging transcripts")
        case "processing_transcript":
            return String(localized: "Processing transcript")
        case "summarizing":
            return String(localized: "Summarizing")
        case "converting_audio":
            return String(localized: "Converting audio")
        case "packaging":
            return String(localized: "Packaging")
        default:
            return status
        }
    }
}
