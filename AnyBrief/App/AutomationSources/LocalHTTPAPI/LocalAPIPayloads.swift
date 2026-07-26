import Foundation

struct MeetingRecord {
    let job: Job
    let folderURL: URL
    let title: String
    let summaryURL: URL?
    let transcriptTextURL: URL?
    let transcriptJSONURL: URL?
    let bundleURL: URL?
}

struct ParsedLogLine {
    let timestamp: Date
    let level: String
    let component: String
    let message: String
}

struct APIError: Error {
    let status: Int
    let code: String
    let message: String
    var details: [String: Any] = [:]
}

final class LocalAPISettingsDidChangeHandler: @unchecked Sendable {
    private let lock = NSLock()
    private var action: (@Sendable () async -> Void)?

    func set(_ action: @escaping @Sendable () async -> Void) {
        lock.lock()
        self.action = action
        lock.unlock()
    }

    func call() async {
        let action = actionSnapshot()
        await action?()
    }

    private func actionSnapshot() -> (@Sendable () async -> Void)? {
        lock.lock()
        let action = action
        lock.unlock()
        return action
    }
}
