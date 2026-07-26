import Foundation

/// A reusable prompt. `titlePatterns` are optional case/diacritic-insensitive
/// "contains" patterns matched against the meeting title to pick a prompt
/// automatically for summarization (rules UI ships in a later iteration).
struct PromptItem: Codable, Identifiable, Equatable {
    var id = UUID().uuidString.lowercased()
    var name = ""
    var text = ""
    var titlePatterns: [String] = []

    init(
        id: String = UUID().uuidString.lowercased(),
        name: String = "",
        text: String = "",
        titlePatterns: [String] = []
    ) {
        self.id = id
        self.name = name
        self.text = text
        self.titlePatterns = titlePatterns
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString.lowercased()
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        text = try container.decodeIfPresent(String.self, forKey: .text) ?? ""
        titlePatterns = try container.decodeIfPresent([String].self, forKey: .titlePatterns) ?? []
    }

    func matchesTitle(_ title: String) -> Bool {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty else {
            return false
        }
        return titlePatterns.contains { pattern in
            let trimmedPattern = pattern.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedPattern.isEmpty else {
                return false
            }
            return trimmedTitle.range(
                of: trimmedPattern,
                options: [.caseInsensitive, .diacriticInsensitive]
            ) != nil
        }
    }
}

struct SummaryPromptAssignment: Codable, Equatable {
    /// Ordered connection ids for the fallback chain; empty = all enabled connections.
    var connectionIDs: [String] = []
    var promptID: String?
    /// References a `PromptItem` in `PromptsSettings.items` whose text is used as
    /// speaker context. Shared with transcript cleanup.
    var speakerContextPromptID: String?

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        connectionIDs = try container.decodeIfPresent([String].self, forKey: .connectionIDs) ?? []
        promptID = try container.decodeIfPresent(String.self, forKey: .promptID)
        speakerContextPromptID = try container.decodeIfPresent(String.self, forKey: .speakerContextPromptID)
    }
}

struct TranscriptCleanupAssignment: Codable, Equatable {
    var enabled = false
    /// Ordered connection ids for the fallback chain; empty = all enabled connections.
    var connectionIDs: [String] = []
    var promptID: String?

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        connectionIDs = try container.decodeIfPresent([String].self, forKey: .connectionIDs) ?? []
        promptID = try container.decodeIfPresent(String.self, forKey: .promptID)
    }
}

struct LivePromptAssignment: Codable, Equatable {
    /// nil means Auto: Live tries all enabled connections in pool order.
    var connectionID: String?
    var promptID: String?

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        connectionID = try container.decodeIfPresent(String.self, forKey: .connectionID)
        promptID = try container.decodeIfPresent(String.self, forKey: .promptID)
    }
}

struct PromptsSettings: Codable {
    var items: [PromptItem] = PromptDefaults.defaultItems()
    var summary = SummaryPromptAssignment()
    var live = LivePromptAssignment()
    var transcriptCleanup = TranscriptCleanupAssignment()

    init() {
        summary.promptID = PromptDefaults.summaryPromptID
        live.promptID = PromptDefaults.livePromptID
        transcriptCleanup.promptID = PromptDefaults.transcriptCleanupPromptID
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = PromptsSettings()
        items = try container.decodeIfPresent([PromptItem].self, forKey: .items) ?? defaults.items
        summary = try container.decodeIfPresent(SummaryPromptAssignment.self, forKey: .summary) ?? defaults.summary
        live = try container.decodeIfPresent(LivePromptAssignment.self, forKey: .live) ?? defaults.live
        transcriptCleanup = try container.decodeIfPresent(TranscriptCleanupAssignment.self, forKey: .transcriptCleanup)
            ?? defaults.transcriptCleanup

        // Migrates the pre-combobox `prompts.summary.speakerContext` free-text field
        // (replaced by `speakerContextPromptID`, a reference into `items`) into a
        // PromptItem so existing speaker-context text survives the format change.
        if summary.speakerContextPromptID == nil,
           let summaryContainer = try? container.nestedContainer(keyedBy: LegacySummaryCodingKeys.self, forKey: .summary),
           let legacyText = try? summaryContainer.decodeIfPresent(String.self, forKey: .speakerContext),
           !legacyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let item = PromptItem(id: "migrated-speaker-context", name: String(localized: "Speaker context"), text: legacyText)
            items.append(item)
            summary.speakerContextPromptID = item.id
        }
    }

    private enum LegacySummaryCodingKeys: String, CodingKey {
        case speakerContext
    }
}

extension PromptsSettings {
    func prompt(withID id: String?) -> PromptItem? {
        guard let id else {
            return nil
        }
        return items.first { $0.id == id }
    }

    /// Title patterns win over the assigned prompt; collection order breaks ties.
    func summaryPrompt(forMeetingTitle title: String?) -> PromptItem? {
        if let title, let match = items.first(where: { $0.matchesTitle(title) }) {
            return match
        }
        return prompt(withID: summary.promptID) ?? items.first
    }

    var livePrompt: PromptItem? {
        prompt(withID: live.promptID)
    }

    var transcriptCleanupPrompt: PromptItem? {
        prompt(withID: transcriptCleanup.promptID)
    }

    var trimmedSpeakerContext: String {
        (prompt(withID: summary.speakerContextPromptID)?.text ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum PromptDefaults {
    static let summaryPromptID = "summary-default"
    static let livePromptID = "live-default"
    static let transcriptCleanupPromptID = "transcript-cleanup-default"

    static func defaultItems() -> [PromptItem] {
        [
            PromptItem(id: summaryPromptID, name: "Meeting summary", text: summaryText),
            PromptItem(id: livePromptID, name: "Live notes", text: liveText),
            PromptItem(id: transcriptCleanupPromptID, name: "Transcript cleanup", text: transcriptCleanupText),
        ]
    }

    static let liveText = """
    Extract the key points, decisions, risks, and action items from this live transcript. \
    Keep the output concise and update-friendly. Write in %lang%.
    """

    static let transcriptCleanupText = """
    Clean up this meeting transcript. Fix speech-recognition errors (mis-heard words, garbled phrases) \
    and obvious typos, using context to infer the intended meaning. Where a speaker label is generic \
    (e.g. "Speaker 1", "Unknown") and the meeting metadata or the conversation itself makes the real name \
    clear, replace it with that name. Speaker diarization can mistakenly split one real participant across \
    multiple labels. When conversation continuity, identity evidence, and speaking context make it reasonably \
    clear that two or more labels belong to the same person, normalize those turns to one consistent speaker \
    label or name. Keep distinct speakers separate whenever the evidence is ambiguous; do not merge identities \
    merely because speakers discuss the same topic or alternate frequently. Do not guess a name you cannot \
    reasonably infer.

    Keep the original line structure: one line per turn, in the same "[timestamp] Speaker: text" format as \
    the input. Speaker-label normalization may assign the same corrected label to multiple turns, but never \
    combine transcript lines. Do not reorder, drop, or add lines. Do not summarize or comment on the content — \
    only correct it. Preserve the meaning and the language the participants spoke in.
    """

    static let summaryText = """
    Create a concise, structured Markdown meeting summary.

    If meeting metadata/frontmatter is present, use it as context: title, date, participants, calendar description, duration, and other useful fields.

    Output format by meaning. Translate every Markdown heading below into %lang%; do not keep these English heading labels verbatim unless %lang% is English:
    # Meeting Summary

    ## Meeting Goal
    One short paragraph: why the meeting happened and what was discussed.

    ## Participants
    List participants, companies, or roles if they are clear from the text or metadata.

    ## Main Topics
    Split the content into several meaningful sections with concrete titles based on the actual meeting topics.
    In each section, include only important facts, agreements, arguments, and context.

    ## Key Takeaways
    List the main conclusions, decisions, risks, constraints, and important observations.

    ## Next Steps
    List follow-up actions. Include owners and deadlines only if they were explicitly mentioned.

    Rules:
    - Write in %lang%.
    - All Markdown headings, section names, and bullet text must be in %lang%.
    - Do not include questions.
    - Do not invent facts.
    - Do not copy timestamps or raw transcript lines.
    - Do not summarize everything line by line.
    - Preserve important names, companies, products, metrics, and agreements.
    - If the meeting was split into parts, produce one final summary and do not mention the split.
    """
}
