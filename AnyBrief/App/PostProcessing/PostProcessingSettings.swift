import Foundation

struct PostProcessingSettings: Codable, Equatable {
    var enabled = false
    var rules: [PostProcessingRuleConfiguration] = []

    init() {}

    init(enabled: Bool = false, rules: [PostProcessingRuleConfiguration] = []) {
        self.enabled = enabled
        self.rules = rules
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = PostProcessingSettings()
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? defaults.enabled
        rules = try container.decodeIfPresent([PostProcessingRuleConfiguration].self, forKey: .rules)
            ?? defaults.rules
    }

    static func normalizedRules(_ rules: [PostProcessingRuleConfiguration]) -> [PostProcessingRuleConfiguration] {
        var result: [PostProcessingRuleConfiguration] = []
        var seenIDs = Set<String>()
        for rule in rules where seenIDs.insert(rule.id).inserted {
            result.append(rule)
        }
        return result
    }
}

struct PostProcessingRuleConfiguration: Codable, Equatable, Identifiable {
    enum MatchMode: String, Codable, CaseIterable, Identifiable {
        case exact
        case contains
        case regex

        var id: String { rawValue }
    }

    enum ConflictBehavior: String, Codable, CaseIterable, Identifiable {
        case skip
        case overwrite
        case addSuffix

        var id: String { rawValue }
    }

    var id: String
    var title: String
    var enabled: Bool
    var matchMode: MatchMode
    var calendarTitlePattern: String
    var destinationFolderPath: String
    var filenameTemplate: String
    var conflictBehavior: ConflictBehavior

    init(
        id: String = UUID().uuidString.lowercased(),
        title: String,
        enabled: Bool = true,
        matchMode: MatchMode = .contains,
        calendarTitlePattern: String,
        destinationFolderPath: String,
        filenameTemplate: String = "{date} {calendarTitle} — {topic}.md",
        conflictBehavior: ConflictBehavior = .skip
    ) {
        self.id = id
        self.title = title
        self.enabled = enabled
        self.matchMode = matchMode
        self.calendarTitlePattern = calendarTitlePattern
        self.destinationFolderPath = destinationFolderPath
        self.filenameTemplate = filenameTemplate
        self.conflictBehavior = conflictBehavior
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString.lowercased()
        title = try container.decodeIfPresent(String.self, forKey: .title) ?? ""
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        matchMode = try container.decodeIfPresent(MatchMode.self, forKey: .matchMode) ?? .contains
        calendarTitlePattern = try container.decodeIfPresent(String.self, forKey: .calendarTitlePattern) ?? title
        destinationFolderPath = try container.decodeIfPresent(String.self, forKey: .destinationFolderPath) ?? ""
        filenameTemplate = try container.decodeIfPresent(String.self, forKey: .filenameTemplate)
            ?? "{date} {calendarTitle} — {topic}.md"
        conflictBehavior = try container.decodeIfPresent(ConflictBehavior.self, forKey: .conflictBehavior) ?? .skip
    }
}
