import Foundation

/// Recording session runtime state for the active recording.
struct RecordingSession: Sendable {
    let jobId: String
    let pid: Int32
    let paths: MeetingPaths
    let startedAt: Date
    let source: String
    let title: String
    let autoStopDisabled: Bool
    let autoStopAt: Date?
    let microphonePaused: Bool
    let microphoneDegraded: Bool
    let recordingWarnings: [String]
    let systemSpeakersOverride: Int?
    let calendarEventUID: String?

    init(
        jobId: String,
        pid: Int32,
        paths: MeetingPaths,
        startedAt: Date,
        source: String,
        title: String,
        autoStopDisabled: Bool,
        autoStopAt: Date? = nil,
        microphonePaused: Bool = false,
        microphoneDegraded: Bool = false,
        recordingWarnings: [String] = [],
        systemSpeakersOverride: Int? = nil,
        calendarEventUID: String? = nil
    ) {
        self.jobId = jobId
        self.pid = pid
        self.paths = paths
        self.startedAt = startedAt
        self.source = source
        self.title = title
        self.autoStopDisabled = autoStopDisabled
        self.autoStopAt = autoStopAt
        self.microphonePaused = microphonePaused
        self.microphoneDegraded = microphoneDegraded
        self.recordingWarnings = recordingWarnings
        self.systemSpeakersOverride = systemSpeakersOverride
        self.calendarEventUID = calendarEventUID
    }

    func withAutoStopDisabled(_ autoStopDisabled: Bool) -> RecordingSession {
        RecordingSession(
            jobId: jobId,
            pid: pid,
            paths: paths,
            startedAt: startedAt,
            source: source,
            title: title,
            autoStopDisabled: autoStopDisabled,
            autoStopAt: autoStopAt,
            microphonePaused: microphonePaused,
            microphoneDegraded: microphoneDegraded,
            recordingWarnings: recordingWarnings,
            systemSpeakersOverride: systemSpeakersOverride,
            calendarEventUID: calendarEventUID
        )
    }

    func withMicrophonePaused(_ microphonePaused: Bool) -> RecordingSession {
        RecordingSession(
            jobId: jobId,
            pid: pid,
            paths: paths,
            startedAt: startedAt,
            source: source,
            title: title,
            autoStopDisabled: autoStopDisabled,
            autoStopAt: autoStopAt,
            microphonePaused: microphonePaused,
            microphoneDegraded: microphoneDegraded,
            recordingWarnings: recordingWarnings,
            systemSpeakersOverride: systemSpeakersOverride,
            calendarEventUID: calendarEventUID
        )
    }

    func withMicrophoneDegraded(_ warning: String) -> RecordingSession {
        withRecordingWarning(warning, microphoneDegraded: true)
    }

    func withRecordingWarning(_ warning: String) -> RecordingSession {
        withRecordingWarning(warning, microphoneDegraded: microphoneDegraded)
    }

    func withRecordingWarnings(_ warnings: [String]) -> RecordingSession {
        warnings.reduce(self) { session, warning in
            session.withRecordingWarning(warning)
        }
    }

    private func withRecordingWarning(_ warning: String, microphoneDegraded: Bool) -> RecordingSession {
        var warnings = recordingWarnings
        if !warnings.contains(warning) {
            warnings.append(warning)
        }
        return RecordingSession(
            jobId: jobId,
            pid: pid,
            paths: paths,
            startedAt: startedAt,
            source: source,
            title: title,
            autoStopDisabled: autoStopDisabled,
            autoStopAt: autoStopAt,
            microphonePaused: microphonePaused,
            microphoneDegraded: microphoneDegraded,
            recordingWarnings: warnings,
            systemSpeakersOverride: systemSpeakersOverride,
            calendarEventUID: calendarEventUID
        )
    }
}
