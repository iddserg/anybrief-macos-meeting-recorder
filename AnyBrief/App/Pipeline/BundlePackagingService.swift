import Foundation

/// Packages finalized meeting artifacts into `bundle.zip`.
final class BundlePackagingService {
    private let fileManager: FileManager
    private let zipURLResolver: () throws -> URL

    init(
        fileManager: FileManager = .default,
        zipURLResolver: @escaping () throws -> URL = { URL(fileURLWithPath: "/usr/bin/zip", isDirectory: false) }
    ) {
        self.fileManager = fileManager
        self.zipURLResolver = zipURLResolver
    }

    func createBundleZip(in folderURL: URL, bundleURL: URL, includeMicrophone: Bool = true) throws {
        let tempBundleURL = folderURL.appendingPathComponent(
            bundleURL.lastPathComponent + ".tmp",
            isDirectory: false
        )

        if fileManager.fileExists(atPath: bundleURL.path) {
            try fileManager.removeItem(at: bundleURL)
        }
        if fileManager.fileExists(atPath: tempBundleURL.path) {
            try fileManager.removeItem(at: tempBundleURL)
        }

        let process = Process()
        process.executableURL = try zipURLResolver()
        process.currentDirectoryURL = folderURL
        process.arguments = [
            "-q",
            tempBundleURL.lastPathComponent,
        ] + bundleItems(in: folderURL, includeMicrophone: includeMicrophone)
        try PipelineProcessRunner.run(
            process,
            errorContext: "zip failed creating \(bundleURL.lastPathComponent)"
        )

        try fileManager.moveItem(at: tempBundleURL, to: bundleURL)
    }

    private func bundleItems(in folderURL: URL, includeMicrophone: Bool) -> [String] {
        var items = [
            "system_audio.mp3",
            "microphone_audio.mp3",
            "transcript.txt",
            "transcript_merged.json",
        ]
        if fileManager.fileExists(atPath: folderURL.appendingPathComponent("transcript_raw.txt").path) {
            items.append("transcript_raw.txt")
        }
        let summaryURL = folderURL.appendingPathComponent("summary.md", isDirectory: false)
        if fileManager.fileExists(atPath: summaryURL.path) {
            items.append("summary.md")
        }
        return includeMicrophone ? items : items.filter { $0 != "microphone_audio.mp3" }
    }
}
