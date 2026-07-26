import FluidAudio
import Foundation

struct RecognitionVocabulary {
    struct Entry {
        let preferred: String
        let aliases: [String]
    }

    let entries: [Entry]

    init(contentsOf url: URL) throws {
        let text = try String(contentsOf: url, encoding: .utf8)
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

    func applyingAliases(to text: String) -> String {
        var result = text
        for replacement in aliasReplacements {
            let escaped = NSRegularExpression.escapedPattern(for: replacement.from)
            let pattern = "(?<![\\p{L}\\p{N}])\(escaped)(?![\\p{L}\\p{N}])"
            guard let regex = try? NSRegularExpression(
                pattern: pattern,
                options: [.caseInsensitive]
            ) else {
                continue
            }
            result = regex.stringByReplacingMatches(
                in: result,
                range: NSRange(result.startIndex..<result.endIndex, in: result),
                withTemplate: NSRegularExpression.escapedTemplate(for: replacement.to)
            )
        }
        return result
    }

    func applyingAliases(to timings: [WordTiming]) -> [WordTiming] {
        Self.applying(aliasReplacements, to: timings)
    }

    static func applying(
        _ replacements: [(from: String, to: String)],
        to timings: [WordTiming]
    ) -> [WordTiming] {
        var result = timings
        for replacement in replacements {
            let sourceWords = words(in: replacement.from)
            let targetWords = words(in: replacement.to)
            guard !sourceWords.isEmpty, !targetWords.isEmpty else {
                continue
            }

            var searchStart = 0
            while result.count >= sourceWords.count,
                  searchStart <= result.count - sourceWords.count {
                var matchStart: Int?
                for start in searchStart...(result.count - sourceWords.count) {
                    let candidate = result[start..<(start + sourceWords.count)].map {
                        normalized($0.word)
                    }
                    if candidate == sourceWords.map(normalized) {
                        matchStart = start
                        break
                    }
                }
                guard let matchStart else { break }

                let endIndex = matchStart + sourceWords.count - 1
                let startTime = result[matchStart].startTime
                let endTime = result[endIndex].endTime
                let duration = max(0, endTime - startTime)
                let replacementTimings = targetWords.enumerated().map { index, word in
                    let wordStart = startTime + duration * Double(index) / Double(targetWords.count)
                    let wordEnd = startTime + duration * Double(index + 1) / Double(targetWords.count)
                    return WordTiming(word: word, startTime: wordStart, endTime: wordEnd)
                }
                result.replaceSubrange(matchStart...endIndex, with: replacementTimings)
                searchStart = matchStart + replacementTimings.count
            }
        }
        return result
    }

    private var aliasReplacements: [(from: String, to: String)] {
        entries.flatMap { entry in
            entry.aliases.map { (from: $0, to: entry.preferred) }
        }.sorted { $0.from.count > $1.from.count }
    }

    private static func words(in text: String) -> [String] {
        text.split(whereSeparator: \.isWhitespace).map(String.init)
    }

    private static func normalized(_ word: String) -> String {
        word.lowercased().filter { $0.isLetter || $0.isNumber }
    }
}
