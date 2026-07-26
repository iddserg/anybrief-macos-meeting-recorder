import Foundation

public struct RecognitionVocabulary: Equatable, Sendable {
    public struct Entry: Equatable, Sendable {
        public let preferred: String
        public let aliases: [String]
    }

    public let entries: [Entry]

    public init(text: String) {
        entries = text.components(separatedBy: .newlines).compactMap { rawLine in
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty, !line.hasPrefix("#") else { return nil }
            let parts = line.split(separator: ":", maxSplits: 1).map(String.init)
            let preferred = parts[0].trimmingCharacters(in: .whitespaces)
            guard !preferred.isEmpty else { return nil }
            let aliases = parts.count == 2
                ? parts[1].split(separator: ",")
                    .map { String($0).trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
                : []
            return Entry(preferred: preferred, aliases: aliases)
        }
    }

    public init(contentsOf url: URL) throws {
        self.init(text: try String(contentsOf: url, encoding: .utf8))
    }

    public var prompt: String {
        entries.map(\.preferred).joined(separator: ", ")
    }

    public func applyingAliases(to text: String) -> String {
        var result = text
        let replacements = entries.flatMap { entry in
            entry.aliases.map { (alias: $0, preferred: entry.preferred) }
        }.sorted { $0.alias.count > $1.alias.count }

        for replacement in replacements {
            let escaped = NSRegularExpression.escapedPattern(for: replacement.alias)
            let pattern = "(?<![\\p{L}\\p{N}])\(escaped)(?![\\p{L}\\p{N}])"
            guard let regex = try? NSRegularExpression(
                pattern: pattern,
                options: [.caseInsensitive]
            ) else {
                continue
            }
            let range = NSRange(result.startIndex..<result.endIndex, in: result)
            result = regex.stringByReplacingMatches(
                in: result,
                range: range,
                withTemplate: NSRegularExpression.escapedTemplate(for: replacement.preferred)
            )
        }
        return result
    }
}
