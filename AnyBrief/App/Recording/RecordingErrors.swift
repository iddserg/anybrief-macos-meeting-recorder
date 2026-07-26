import Foundation

struct RecordingAlreadyActiveError: LocalizedError {
    var errorDescription: String? {
        "A recording session is already active."
    }
}

struct NoActiveRecordingError: LocalizedError {
    var errorDescription: String? {
        "There is no active recording session."
    }
}

struct NotCalendarRecordingError: LocalizedError {
    var errorDescription: String? {
        "Auto-stop can only be disabled for calendar recordings."
    }
}

struct RecordingOutputInvalidError: LocalizedError {
    let message: String

    init(message: String = "Recorder output files are missing or empty.") {
        self.message = message
    }

    var errorDescription: String? {
        message
    }
}

struct RecorderAlreadyStoppedError: LocalizedError {
    let message: String

    var errorDescription: String? {
        message
    }
}

struct RecorderHungError: LocalizedError {
    let stalledFor: TimeInterval

    var errorDescription: String? {
        "Recorder output stalled for \(Int(stalledFor.rounded())) seconds."
    }
}
