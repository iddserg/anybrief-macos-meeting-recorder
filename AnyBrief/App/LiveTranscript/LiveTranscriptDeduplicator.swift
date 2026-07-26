import Foundation

struct LiveTranscriptDeduplicator {
    private let maximumOverlapWords: Int
    private let minimumOverlapWords: Int
    private let minimumSimilarity: Double

    init(
        maximumOverlapWords: Int = 180,
        minimumOverlapWords: Int = 5,
        minimumSimilarity: Double = 0.82
    ) {
        self.maximumOverlapWords = maximumOverlapWords
        self.minimumOverlapWords = minimumOverlapWords
        self.minimumSimilarity = minimumSimilarity
    }

    func appending(_ fragment: String, to transcript: String) -> String {
        let trimmedFragment = fragment.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedFragment.isEmpty else {
            return transcript
        }

        let trimmedTranscript = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTranscript.isEmpty else {
            return trimmedFragment
        }

        let existingWords = trimmedTranscript.split(whereSeparator: \.isWhitespace).map(String.init)
        let fragmentWords = trimmedFragment.split(whereSeparator: \.isWhitespace).map(String.init)
        let overlap = overlapWordCount(existingWords: existingWords, fragmentWords: fragmentWords)
        let uniqueWords = fragmentWords.dropFirst(overlap)
        guard !uniqueWords.isEmpty else {
            return trimmedTranscript
        }

        return "\(trimmedTranscript)\n\(uniqueWords.joined(separator: " "))"
    }

    private func overlapWordCount(existingWords: [String], fragmentWords: [String]) -> Int {
        let limit = min(maximumOverlapWords, existingWords.count, fragmentWords.count)
        guard limit > 0 else {
            return 0
        }

        let minimum = min(minimumOverlapWords, limit)
        for count in stride(from: limit, through: minimum, by: -1) {
            let suffix = existingWords.suffix(count).map(Self.normalizedWord).filter { !$0.isEmpty }
            let prefix = fragmentWords.prefix(count).map(Self.normalizedWord).filter { !$0.isEmpty }
            guard !suffix.isEmpty, suffix.count == prefix.count else {
                continue
            }

            if similarity(between: suffix, and: prefix) >= minimumSimilarity {
                return count
            }
        }

        return 0
    }

    private func similarity(between lhs: [String], and rhs: [String]) -> Double {
        guard lhs.count == rhs.count, !lhs.isEmpty else {
            return 0
        }

        let matches = zip(lhs, rhs).filter { left, right in
            Self.wordsMatch(left, right)
        }.count
        return Double(matches) / Double(lhs.count)
    }

    private static func normalizedWord(_ word: String) -> String {
        word
            .trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }

    private static func wordsMatch(_ lhs: String, _ rhs: String) -> Bool {
        if lhs == rhs {
            return true
        }
        if lhs.count >= 6, rhs.count >= 6 {
            if lhs.hasPrefix(rhs) || rhs.hasPrefix(lhs) {
                return true
            }
        }
        return editDistance(lhs, rhs, maximumDistance: 1) <= 1
    }

    private static func editDistance(_ lhs: String, _ rhs: String, maximumDistance: Int) -> Int {
        let left = Array(lhs)
        let right = Array(rhs)
        if abs(left.count - right.count) > maximumDistance {
            return maximumDistance + 1
        }

        var previous = Array(0...right.count)
        for leftIndex in 1...left.count {
            var current = [leftIndex] + Array(repeating: 0, count: right.count)
            var rowMinimum = current[0]
            for rightIndex in 1...right.count {
                let substitutionCost = left[leftIndex - 1] == right[rightIndex - 1] ? 0 : 1
                current[rightIndex] = min(
                    previous[rightIndex] + 1,
                    current[rightIndex - 1] + 1,
                    previous[rightIndex - 1] + substitutionCost
                )
                rowMinimum = min(rowMinimum, current[rightIndex])
            }
            if rowMinimum > maximumDistance {
                return maximumDistance + 1
            }
            previous = current
        }
        return previous[right.count]
    }
}
