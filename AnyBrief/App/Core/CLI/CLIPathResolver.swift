import Foundation

enum CLIPathResolver {
    private static let fileManager = FileManager.default
    private static let envVarName = "ANYBRIEF_CLI_DIR"

    static func resolveRecorder() throws -> URL {
        try resolve(binaryName: "recorder")
    }

    static func resolveStt() throws -> URL {
        try resolve(binaryName: "stt")
    }

    static func resolveWhisperSTT() throws -> URL {
        try resolve(binaryName: "whisper-stt")
    }

    static func resolveWhisperCore() throws -> URL {
        try resolve(binaryName: "whisper-cli-core")
    }

    static func resolveFfmpeg() throws -> URL {
        try resolve(binaryName: "ffmpeg")
    }

    private static func resolve(binaryName: String) throws -> URL {
        if let overrideDirectory = ProcessInfo.processInfo.environment[envVarName], !overrideDirectory.isEmpty {
            let overrideURL = URL(fileURLWithPath: overrideDirectory, isDirectory: true)
                .appendingPathComponent(binaryName, isDirectory: false)
            if fileManager.fileExists(atPath: overrideURL.path) {
                logResolvedPathOnce(binaryName: binaryName, resolvedURL: overrideURL)
                return overrideURL
            }
        }

        if let bundledURL = Bundle.main.url(forResource: binaryName, withExtension: nil, subdirectory: "bin"),
           fileManager.fileExists(atPath: bundledURL.path) {
            logResolvedPathOnce(binaryName: binaryName, resolvedURL: bundledURL)
            return bundledURL
        }

        throw CLINotFoundError(binaryName: binaryName)
    }

    private static func logResolvedPathOnce(binaryName: String, resolvedURL: URL) {
        Task {
            await LoggingService.shared.logOnce(
                "Resolved \(binaryName) path: \(resolvedURL.path)",
                level: .info,
                component: "CLIPathResolver",
                key: "resolved:\(binaryName)"
            )
        }
    }
}

struct CLINotFoundError: LocalizedError {
    let binaryName: String

    var errorDescription: String? {
        "CLI binary '\(binaryName)' was not found."
    }
}
