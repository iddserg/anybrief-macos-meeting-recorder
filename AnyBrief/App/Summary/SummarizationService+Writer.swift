import Foundation

extension SummarizationService {
    func writeSummary(
        _ summary: String,
        to meetingFolder: URL,
        date: Date,
        durationMinutes: Int,
        speakers: Int,
        model: String,
        provider: SummaryProviderMetadata? = nil,
        metadata: SummaryMetadata? = nil,
        preservedFrontmatter: String? = nil,
        status: String? = nil,
        summaryError: String? = nil,
        includeFooter: Bool = true
    ) throws {
        try fileManager.createDirectory(at: meetingFolder, withIntermediateDirectories: true)
        var frontmatter = [
            "date: \(isoFormatter.string(from: date))",
            "duration: \(durationMinutes)",
            "speakers: \(speakers)",
            "model: \(yamlScalar(model))",
        ]
        if let provider {
            frontmatter.append(contentsOf: summaryProviderFrontmatter(provider))
        }
        if let status, !status.isEmpty {
            frontmatter.append("status: \(status)")
        }
        if let summaryError, !summaryError.isEmpty {
            frontmatter.append("summary_error: \(summaryError)")
        }
        if let metadata {
            frontmatter.append(contentsOf: metadataFrontmatter(metadata))
        } else if let preservedFrontmatter {
            frontmatter.append(contentsOf: preservedMetadataFrontmatter(from: preservedFrontmatter))
        }
        let footer = includeFooter
            ? "\n\n---\n\(Self.summaryFooter)\n"
            : "\n"
        let warningBlock = visibleWarningBlock(metadata?.warnings ?? [])
        let markdown = """
        ---
        \(frontmatter.joined(separator: "\n"))
        ---
        \(warningBlock)
        \(summary)
        \(footer)
        """
        let summaryURL = meetingFolder.appendingPathComponent("summary.md", isDirectory: false)
        let tempURL = meetingFolder.appendingPathComponent(".summary.md.tmp", isDirectory: false)
        try markdown.write(to: tempURL, atomically: true, encoding: .utf8)
        if fileManager.fileExists(atPath: summaryURL.path) {
            try fileManager.removeItem(at: summaryURL)
        }
        try fileManager.moveItem(at: tempURL, to: summaryURL)
    }

    func visibleWarningBlock(_ warnings: [String]) -> String {
        guard !warnings.isEmpty else {
            return ""
        }

        let bullets = warnings
            .map { "> - \($0)" }
            .joined(separator: "\n")
        return """
        > **Recording warning**
        > AnyBrief detected possible recording or transcription quality issues. Verify the audio and transcript before relying on this summary.
        \(bullets)

        """
    }
}
