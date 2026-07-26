import Foundation

struct AppSettings: Codable {
    var application = ApplicationSettings()
    var recording = RecordingSettings()
    var summary = SummarySettings()
    var llm = LLMSettings()
    var prompts = PromptsSettings()
    var transcription = TranscriptionSettings()
    var automation = AutomationSettings()
    var postProcessing = PostProcessingSettings()

    init() {}

    init(
        application: ApplicationSettings = ApplicationSettings(),
        recording: RecordingSettings = RecordingSettings(),
        summary: SummarySettings = SummarySettings(),
        llm: LLMSettings = LLMSettings(),
        prompts: PromptsSettings = PromptsSettings(),
        transcription: TranscriptionSettings = TranscriptionSettings(),
        automation: AutomationSettings = AutomationSettings(),
        postProcessing: PostProcessingSettings = PostProcessingSettings()
    ) {
        self.application = application
        self.recording = recording
        self.summary = summary
        self.llm = llm
        self.prompts = prompts
        self.transcription = transcription
        self.automation = automation
        self.postProcessing = postProcessing
    }

    enum CodingKeys: String, CodingKey {
        case application
        case recording
        case summary
        case llm
        case prompts
        case transcription
        case automation
        case postProcessing
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        application = try container.decodeIfPresent(ApplicationSettings.self, forKey: .application) ?? ApplicationSettings()
        recording = try container.decodeIfPresent(RecordingSettings.self, forKey: .recording) ?? RecordingSettings()
        summary = try container.decodeIfPresent(SummarySettings.self, forKey: .summary) ?? SummarySettings()
        llm = try container.decodeIfPresent(LLMSettings.self, forKey: .llm) ?? LLMSettings()
        prompts = try container.decodeIfPresent(PromptsSettings.self, forKey: .prompts) ?? PromptsSettings()
        transcription = try container.decodeIfPresent(TranscriptionSettings.self, forKey: .transcription) ?? TranscriptionSettings()
        automation = try container.decodeIfPresent(AutomationSettings.self, forKey: .automation) ?? AutomationSettings()
        postProcessing = try container.decodeIfPresent(PostProcessingSettings.self, forKey: .postProcessing)
            ?? PostProcessingSettings()
        migrateLegacySummarySettingsIfNeeded()
    }
}

struct ApplicationSettings: Codable {
    var storageRoot = "~/anybrief"
    var launchAtLogin = false
    var hideDockIcon = false
    var showNotifications = true
    var disableSummaryFooter = false
    var liveTranscriptEnabled = false
    var postProcessingTabEnabled = true
    var notificationCategories = [
        "recording_started",
        "recording_stopped",
        "pre_end",
        "summary_ready",
        "auto_skipped",
        "recording_interrupted",
        "window_observer",
    ]
    var presenceCheckEnabled = true
    var locale = "system"
    var jobsHistoryLimit = 500

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = ApplicationSettings()
        storageRoot = try container.decodeIfPresent(String.self, forKey: .storageRoot) ?? defaults.storageRoot
        launchAtLogin = try container.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? defaults.launchAtLogin
        hideDockIcon = try container.decodeIfPresent(Bool.self, forKey: .hideDockIcon) ?? defaults.hideDockIcon
        showNotifications = try container.decodeIfPresent(Bool.self, forKey: .showNotifications) ?? defaults.showNotifications
        disableSummaryFooter = try container.decodeIfPresent(Bool.self, forKey: .disableSummaryFooter) ?? defaults.disableSummaryFooter
        liveTranscriptEnabled = try container.decodeIfPresent(Bool.self, forKey: .liveTranscriptEnabled)
            ?? defaults.liveTranscriptEnabled
        postProcessingTabEnabled = try container.decodeIfPresent(Bool.self, forKey: .postProcessingTabEnabled)
            ?? defaults.postProcessingTabEnabled
        notificationCategories = try container.decodeIfPresent([String].self, forKey: .notificationCategories)
            ?? defaults.notificationCategories
        presenceCheckEnabled = try container.decodeIfPresent(Bool.self, forKey: .presenceCheckEnabled)
            ?? defaults.presenceCheckEnabled
        locale = try container.decodeIfPresent(String.self, forKey: .locale) ?? defaults.locale
        jobsHistoryLimit = try container.decodeIfPresent(Int.self, forKey: .jobsHistoryLimit) ?? defaults.jobsHistoryLimit
    }
}

struct RecordingSettings: Codable {
    var microphoneVoiceProcessingEnabled = false
    var microphoneDeviceUID: String?

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        microphoneVoiceProcessingEnabled = try container.decodeIfPresent(
            Bool.self,
            forKey: .microphoneVoiceProcessingEnabled
        ) ?? false
        let decodedMicrophoneDeviceUID = try container.decodeIfPresent(
            String.self,
            forKey: .microphoneDeviceUID
        )?.trimmingCharacters(in: .whitespacesAndNewlines)
        microphoneDeviceUID = decodedMicrophoneDeviceUID?.isEmpty == false
            ? decodedMicrophoneDeviceUID
            : nil
    }
}

/// Automatic-summary pipeline gate. Connections live in `llm`, prompts and
/// task assignments in `prompts`. Legacy fields are decoded (never encoded)
/// only to feed the one-time migration into those sections.
struct SummarySettings: Codable {
    var enabled = false

    var legacySpeakerContext: String?
    var legacyRetryCount: Int?
    var legacyTimeoutSec: Int?
    var legacyProviders: [SummaryProviderConfiguration]?

    enum CodingKeys: String, CodingKey {
        case enabled
        case speakerContext
        case retryCount
        case timeoutSec
        case providers
    }

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = SummarySettings()
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? defaults.enabled
        legacySpeakerContext = try container.decodeIfPresent(String.self, forKey: .speakerContext)
        legacyRetryCount = try container.decodeIfPresent(Int.self, forKey: .retryCount)
        legacyTimeoutSec = try container.decodeIfPresent(Int.self, forKey: .timeoutSec)
        legacyProviders = try container.decodeIfPresent([SummaryProviderConfiguration].self, forKey: .providers)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(enabled, forKey: .enabled)
    }
}

extension AppSettings {
    /// Migrates pre-LLM-layer settings (`summary.providers` with prompts inside
    /// payloads) into `llm.connections` + `prompts`. Deterministic and
    /// idempotent: it runs on every decode until the file is saved in the new
    /// shape, which drops the legacy keys.
    mutating func migrateLegacySummarySettingsIfNeeded() {
        defer {
            summary.legacySpeakerContext = nil
            summary.legacyRetryCount = nil
            summary.legacyTimeoutSec = nil
            summary.legacyProviders = nil
            llm.legacyTimeoutSec = nil
            llm.legacyRetryCount = nil
        }

        // Pre-per-connection global `llm.timeoutSec`/`llm.retryCount` become each
        // connection's own default when it doesn't already have an explicit value.
        if let legacyTimeoutSec = llm.legacyTimeoutSec {
            for index in llm.connections.indices where llm.connections[index].timeoutSec == nil {
                llm.connections[index].timeoutSec = legacyTimeoutSec
            }
        }
        if let legacyRetryCount = llm.legacyRetryCount {
            for index in llm.connections.indices where llm.connections[index].retryCount == nil {
                llm.connections[index].retryCount = legacyRetryCount
            }
        }

        if let speakerContext = summary.legacySpeakerContext,
           !speakerContext.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           prompts.summary.speakerContextPromptID == nil {
            let item = PromptItem(id: "migrated-speaker-context", name: String(localized: "Speaker context"), text: speakerContext)
            prompts.items.append(item)
            prompts.summary.speakerContextPromptID = item.id
        }

        guard llm.connections.isEmpty, let legacyProviders = summary.legacyProviders, !legacyProviders.isEmpty else {
            return
        }

        var migratedPromptID: String?
        for provider in legacyProviders {
            guard case let .string(prompt)? = provider.payload["prompt"],
                  !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                continue
            }
            if let existing = prompts.items.first(where: { $0.text == prompt }) {
                if migratedPromptID == nil, provider.enabled {
                    migratedPromptID = existing.id
                }
                continue
            }
            let item = PromptItem(
                id: "migrated-\(provider.id)",
                name: provider.name ?? provider.provider.rawValue,
                text: prompt
            )
            prompts.items.append(item)
            if migratedPromptID == nil, provider.enabled {
                migratedPromptID = item.id
            }
        }
        if let migratedPromptID {
            prompts.summary.promptID = migratedPromptID
        }

        llm.connections = legacyProviders.map { provider in
            var connection = provider
            connection.payload["prompt"] = nil
            connection.timeoutSec = summary.legacyTimeoutSec
            connection.retryCount = summary.legacyRetryCount
            return connection
        }
        // Empty explicit chain keeps today's behavior: all enabled connections in order.
        prompts.summary.connectionIDs = []
    }
}

struct TranscriptionSettings: Codable {
    var diarizationEnabled = true
    var skipMicrophoneDiarization = true
    /// Decode-only compatibility for settings written before dictionaries
    /// moved into provider payloads.
    var customVocabulary = ""
    var providers: [TranscriptionProviderConfiguration] = [.fluidAudioSTT()]

    enum CodingKeys: String, CodingKey {
        case diarizationEnabled
        case skipMicrophoneDiarization
        case customVocabulary
        case providers
    }

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = TranscriptionSettings()
        diarizationEnabled = try container.decodeIfPresent(
            Bool.self,
            forKey: .diarizationEnabled
        ) ?? defaults.diarizationEnabled
        skipMicrophoneDiarization = try container.decodeIfPresent(
            Bool.self,
            forKey: .skipMicrophoneDiarization
        ) ?? defaults.skipMicrophoneDiarization
        customVocabulary = try container.decodeIfPresent(
            String.self,
            forKey: .customVocabulary
        ) ?? defaults.customVocabulary
        providers = try container.decodeIfPresent(
            [TranscriptionProviderConfiguration].self,
            forKey: .providers
        ) ?? defaults.providers
        migrateLegacyCustomVocabularyIfNeeded()
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(diarizationEnabled, forKey: .diarizationEnabled)
        try container.encode(skipMicrophoneDiarization, forKey: .skipMicrophoneDiarization)
        try container.encode(providers, forKey: .providers)
    }
}

extension TranscriptionSettings {
    mutating func migrateLegacyCustomVocabularyIfNeeded() {
        let legacyVocabulary = customVocabulary.normalizedRecognitionVocabulary
        guard !legacyVocabulary.isEmpty else {
            customVocabulary = ""
            return
        }

        for provider in TranscriptionProviderID.allCases {
            if !providers.contains(where: { $0.provider == provider }) {
                switch provider {
                case .fluidAudioSTT:
                    providers.append(
                        .fluidAudioSTT(
                            enabled: false,
                            config: FluidAudioSTTConfig(customVocabulary: legacyVocabulary)
                        )
                    )
                case .whisperCpp:
                    providers.append(
                        .whisperCpp(
                            enabled: false,
                            config: WhisperCppConfig(customVocabulary: legacyVocabulary)
                        )
                    )
                }
                continue
            }
            guard let index = providers.firstIndex(where: { $0.provider == provider }),
                  providers[index].payload["customVocabulary"] == nil else {
                continue
            }
            switch provider {
            case .fluidAudioSTT:
                var config = providers[index].fluidAudioSTTConfig
                config.customVocabulary = legacyVocabulary
                providers[index].fluidAudioSTTConfig = config
            case .whisperCpp:
                var config = providers[index].whisperCppConfig
                config.customVocabulary = legacyVocabulary
                providers[index].whisperCppConfig = config
            }
        }
        customVocabulary = ""
    }

    mutating func setVocabulary(_ vocabulary: String, for provider: TranscriptionProviderID) {
        switch provider {
        case .fluidAudioSTT:
            var config = fluidAudioSTTConfig
            config.customVocabulary = vocabulary
            fluidAudioSTTConfig = config
        case .whisperCpp:
            var config = whisperCppConfig
            config.customVocabulary = vocabulary
            whisperCppConfig = config
        }
    }

    mutating func setLegacyVocabularyForAllProviders(_ vocabulary: String) {
        setVocabulary(vocabulary, for: .fluidAudioSTT)
        setVocabulary(vocabulary, for: .whisperCpp)
    }

    var enabledProviders: [TranscriptionProviderConfiguration] {
        providers.filter(\.enabled)
    }

    var activeProviderConfiguration: TranscriptionProviderConfiguration {
        enabledProviders.first ?? providers.first ?? .fluidAudioSTT()
    }
}

extension String {
    var normalizedRecognitionVocabulary: String {
        components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
            .joined(separator: "\n")
    }
}

extension AppSettings {
    /// One-time settings-file migration for the former diarization default.
    /// The store records completion separately so a user can intentionally
    /// select 0.35 again after upgrading without it being changed on each load.
    @discardableResult
    mutating func migrateLegacyDiarizationThresholdIfNeeded() -> Bool {
        let legacyThreshold = 0.35
        let currentThreshold = 0.65
        let tolerance = 0.000_001
        var didMigrate = false

        for index in transcription.providers.indices {
            switch transcription.providers[index].provider {
            case .fluidAudioSTT:
                var config = transcription.providers[index].fluidAudioSTTConfig
                guard abs(config.threshold - legacyThreshold) <= tolerance else {
                    continue
                }
                config.threshold = currentThreshold
                transcription.providers[index].fluidAudioSTTConfig = config
                didMigrate = true
            case .whisperCpp:
                var config = transcription.providers[index].whisperCppConfig
                guard abs(config.threshold - legacyThreshold) <= tolerance else {
                    continue
                }
                config.threshold = currentThreshold
                transcription.providers[index].whisperCppConfig = config
                didMigrate = true
            }
        }

        return didMigrate
    }
}

struct AutomationSettings: Codable {
    var enabled = false
    var sources: [AutomationSourceConfiguration] = [
        .calDAV(),
        .localHTTPAPI(),
        .windowObserver(),
    ]
    var rules: [AutomationRuleConfiguration] = [
        .calendarAutopilot(),
    ]

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = AutomationSettings()
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? defaults.enabled
        sources = try container.decodeIfPresent([AutomationSourceConfiguration].self, forKey: .sources)
            ?? defaults.sources
        rules = try container.decodeIfPresent([AutomationRuleConfiguration].self, forKey: .rules)
            ?? defaults.rules
        sources = Self.normalizedSources(sources)
        rules = Self.normalizedRules(rules)
    }

    static func normalizedSources(_ sources: [AutomationSourceConfiguration]) -> [AutomationSourceConfiguration] {
        var result = sources
        for defaultSource in AutomationSettings().sources where !result.contains(where: { $0.source == defaultSource.source }) {
            result.append(defaultSource)
        }
        return result
    }

    static func normalizedRules(_ rules: [AutomationRuleConfiguration]) -> [AutomationRuleConfiguration] {
        var result = rules
        for defaultRule in AutomationSettings().rules where !result.contains(where: { $0.kind == defaultRule.kind }) {
            result.append(defaultRule)
        }
        return result
    }

    func sourceConfiguration(for source: AutomationSourceID) -> AutomationSourceConfiguration {
        sources.first(where: { $0.source == source }) ?? {
            switch source {
            case .calDAV:
                return .calDAV()
            case .localHTTPAPI:
                return .localHTTPAPI()
            case .windowObserver:
                return .windowObserver()
            }
        }()
    }

    mutating func updateSourceConfiguration(
        for source: AutomationSourceID,
        _ update: (inout AutomationSourceConfiguration) -> Void
    ) {
        let index = sources.firstIndex { $0.source == source }
        var configuration = index.map { sources[$0] } ?? sourceConfiguration(for: source)
        update(&configuration)
        if let index {
            sources[index] = configuration
        } else {
            sources.append(configuration)
        }
        sources = Self.normalizedSources(sources)
    }

    func ruleConfiguration(for kind: AutomationRuleKind) -> AutomationRuleConfiguration {
        rules.first(where: { $0.kind == kind }) ?? {
            switch kind {
            case .calendarAutopilot:
                return .calendarAutopilot()
            }
        }()
    }

    mutating func updateRuleConfiguration(
        for kind: AutomationRuleKind,
        _ update: (inout AutomationRuleConfiguration) -> Void
    ) {
        let index = rules.firstIndex { $0.kind == kind }
        var configuration = index.map { rules[$0] } ?? ruleConfiguration(for: kind)
        update(&configuration)
        if let index {
            rules[index] = configuration
        } else {
            rules.append(configuration)
        }
        rules = Self.normalizedRules(rules)
    }
}

extension AppSettings {
    static let `default` = AppSettings()

    mutating func removeSecretReferences() {
        automation.calDAVSettings.passwordKeychainRef = nil
        automation.calDAVSettings.config.password = ""
        automation.localHTTPAPISettings.apiKey = ""
        automation.localHTTPAPISettings.apiKeyKeychainRef = nil
        for index in llm.connections.indices {
            guard llm.connections[index].provider == .openAICompatible else {
                continue
            }
            llm.connections[index].openAIAPIKey = ""
            llm.connections[index].openAIAPIKeyKeychainRef = nil
        }
    }
}

/// Import/export wrapper that preserves the same grouped shape as persisted settings.
struct AppSettingsConfigFile: Codable {
    var application: ApplicationSettings
    var recording: RecordingSettings
    var summary: SummarySettings
    var llm: LLMSettings
    var prompts: PromptsSettings
    var transcription: TranscriptionSettings
    var automation: AutomationSettings
    var postProcessing: PostProcessingSettings

    enum CodingKeys: String, CodingKey {
        case application
        case recording
        case summary
        case llm
        case prompts
        case transcription
        case automation
        case postProcessing
    }

    init(settings: AppSettings) {
        application = settings.application
        recording = settings.recording
        summary = settings.summary
        llm = settings.llm
        prompts = settings.prompts
        transcription = settings.transcription
        automation = settings.automation
        postProcessing = settings.postProcessing
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        application = try container.decodeIfPresent(ApplicationSettings.self, forKey: .application) ?? ApplicationSettings()
        recording = try container.decodeIfPresent(RecordingSettings.self, forKey: .recording) ?? RecordingSettings()
        summary = try container.decodeIfPresent(SummarySettings.self, forKey: .summary) ?? SummarySettings()
        llm = try container.decodeIfPresent(LLMSettings.self, forKey: .llm) ?? LLMSettings()
        prompts = try container.decodeIfPresent(PromptsSettings.self, forKey: .prompts) ?? PromptsSettings()
        transcription = try container.decodeIfPresent(TranscriptionSettings.self, forKey: .transcription)
            ?? TranscriptionSettings()
        automation = try container.decodeIfPresent(AutomationSettings.self, forKey: .automation) ?? AutomationSettings()
        postProcessing = try container.decodeIfPresent(PostProcessingSettings.self, forKey: .postProcessing)
            ?? PostProcessingSettings()
    }

    func appSettings() -> AppSettings {
        var settings = AppSettings(
            application: application,
            recording: recording,
            summary: summary,
            llm: llm,
            prompts: prompts,
            transcription: transcription,
            automation: automation,
            postProcessing: postProcessing
        )
        settings.migrateLegacySummarySettingsIfNeeded()
        return settings
    }
}
