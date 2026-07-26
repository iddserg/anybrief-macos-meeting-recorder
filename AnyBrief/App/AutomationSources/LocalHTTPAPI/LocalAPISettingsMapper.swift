import Foundation

/// Local HTTP API settings mapper for the grouped settings envelope.
extension LocalAPIHandlers {
    func handleSettingsGet(request: HTTPRequest) async throws -> HTTPResponse {
        let settings = await appSettingsStore.load(using: loggingService)
        return jsonResponse(settingsPayload(settings), request: request)
    }

    func handleSettingsPut(request: HTTPRequest) async throws -> HTTPResponse {
        let body = try request.jsonObject()
        var settings = await appSettingsStore.load(using: loggingService)
        let shouldRequestNotificationPermission = settings.application.showNotifications == false
            && ((body["application"] as? [String: Any])?["showNotifications"] as? Bool == true)

        try applyGroupedSettingsPayload(body, to: &settings)

        if shouldRequestNotificationPermission {
            _ = await permissionService.request(.notifications)
        }

        try await appSettingsStore.save(settings)
        await settingsDidChangeHandler.call()
        return jsonResponse(settingsPayload(settings), request: request)
    }

    static func configurationPayload(from object: Any?) throws -> ConfigurationPayload {
        guard let dictionary = object as? [String: Any] else {
            return [:]
        }
        do {
            let data = try JSONSerialization.data(withJSONObject: dictionary)
            return try JSONDecoder().decode(ConfigurationPayload.self, from: data)
        } catch {
            throw APIError(
                status: 400,
                code: "invalid_request",
                message: "Invalid settings payload."
            )
        }
    }

    func configurationPayload(from object: Any?) throws -> ConfigurationPayload {
        try Self.configurationPayload(from: object)
    }

    func decodePayload<T: Decodable>(_ object: Any?, as type: T.Type) throws -> T {
        guard let dictionary = object as? [String: Any] else {
            throw APIError(status: 400, code: "invalid_request", message: "Missing settings payload.")
        }
        do {
            let data = try JSONSerialization.data(withJSONObject: dictionary)
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw APIError(status: 400, code: "invalid_request", message: "Invalid settings payload.")
        }
    }

    static func promptItems(from payloads: [[String: Any]]) -> [PromptItem] {
        payloads.compactMap { payload in
            guard let text = payload["text"] as? String else {
                return nil
            }
            return PromptItem(
                id: payload["id"] as? String ?? UUID().uuidString.lowercased(),
                name: payload["name"] as? String ?? "",
                text: text,
                titlePatterns: payload["titlePatterns"] as? [String] ?? []
            )
        }
    }

    static func promptItemPayload(_ item: PromptItem) -> [String: Any] {
        [
            "id": item.id,
            "name": item.name,
            "text": item.text,
            "titlePatterns": item.titlePatterns,
        ]
    }

    static func summaryProviderConfigurationEnvelope(_ payload: [String: Any]) throws -> SummaryProviderConfiguration? {
        guard let providerRaw = payload["provider"] as? String,
              let provider = SummaryProvider(rawValue: providerRaw) else {
            return nil
        }
        return SummaryProviderConfiguration(
            id: payload["id"] as? String ?? UUID().uuidString.lowercased(),
            provider: provider,
            name: payload["name"] as? String,
            enabled: payload["enabled"] as? Bool ?? true,
            timeoutSec: payload["timeoutSec"] as? Int,
            retryCount: payload["retryCount"] as? Int,
            payload: try configurationPayload(from: payload["payload"])
        )
    }

    func summaryProviderEntries(from payloads: [[String: Any]]) throws -> [SummaryProviderConfiguration] {
        try payloads.compactMap { payload in
            guard var configuration = try Self.summaryProviderConfigurationEnvelope(payload) else {
                return nil
            }
            if configuration.provider == .openAICompatible {
                var config = configuration.openAICompatibleConfig
                try updateSecret(config.apiKey, currentRef: &config.apiKeyKeychainRef)
                config.apiKey = ""
                configuration.openAICompatibleConfig = config
            }
            return configuration
        }
    }

    func summaryProviderConfigurationPayload(_ configuration: SummaryProviderConfiguration) -> [String: Any] {
        var providerPayload = configuration.payload
        if configuration.provider == .openAICompatible {
            var config = configuration.openAICompatibleConfig
            config.apiKey = secretMask(for: config.apiKeyKeychainRef) ?? ""
            config.apiKeyKeychainRef = nil
            providerPayload = ConfigurationPayloadCodec.encode(config)
        }
        return [
            "id": configuration.id,
            "provider": configuration.provider.rawValue,
            "name": configuration.name as Any,
            "enabled": configuration.enabled,
            "timeoutSec": configuration.timeoutSec as Any,
            "retryCount": configuration.retryCount as Any,
            "payload": providerPayload.jsonObject,
        ]
    }

    static func transcriptionProviderConfigurationPayload(
        _ configuration: TranscriptionProviderConfiguration
    ) -> [String: Any] {
        [
            "id": configuration.id,
            "provider": configuration.provider.rawValue,
            "enabled": configuration.enabled,
            "payload": configuration.payload.jsonObject,
        ]
    }

    func transcriptionProviderConfigurations(from payloads: [[String: Any]]) throws -> [TranscriptionProviderConfiguration] {
        try payloads.compactMap { payload in
            guard let providerRaw = payload["provider"] as? String,
                  let provider = TranscriptionProviderID(rawValue: providerRaw) else {
                return nil
            }
            return TranscriptionProviderConfiguration(
                id: payload["id"] as? String ?? UUID().uuidString.lowercased(),
                provider: provider,
                enabled: payload["enabled"] as? Bool ?? true,
                payload: try configurationPayload(from: payload["payload"])
            )
        }
    }

    func automationSourceConfigurations(
        from payloads: [[String: Any]],
        currentSettings: AppSettings
    ) throws -> [AutomationSourceConfiguration] {
        var result = currentSettings.automation.sources
        for payload in payloads {
            guard let sourceRaw = payload["source"] as? String,
                  let source = AutomationSourceID(rawValue: sourceRaw) else {
                continue
            }
            let id = payload["id"] as? String ?? UUID().uuidString.lowercased()
            let enabled = payload["enabled"] as? Bool ?? true
            let configuration: AutomationSourceConfiguration
            switch source {
            case .localHTTPAPI:
                var settings = try decodePayload(payload["payload"], as: LocalHTTPAPISettings.self)
                settings.enabled = enabled
                settings.apiKeyKeychainRef = currentSettings.automation.localHTTPAPISettings.apiKeyKeychainRef
                try updateSecret(settings.apiKey, currentRef: &settings.apiKeyKeychainRef)
                settings.apiKey = ""
                configuration = AutomationSourceConfiguration.localHTTPAPI(settings).withID(id)
            case .calDAV:
                var settings = try decodePayload(payload["payload"], as: CalDAVAutomationSettings.self)
                settings.enabled = enabled
                settings.passwordKeychainRef = currentSettings.automation.calDAVSettings.passwordKeychainRef
                try updateSecret(settings.config.password, currentRef: &settings.passwordKeychainRef)
                settings.config.password = ""
                configuration = AutomationSourceConfiguration.calDAV(settings).withID(id)
            case .windowObserver:
                var settings = try decodePayload(payload["payload"], as: WindowObserverConfig.self).normalized()
                settings.enabled = enabled
                configuration = AutomationSourceConfiguration.windowObserver(settings).withID(id)
            }
            if let index = result.firstIndex(where: { $0.source == source }) {
                result[index] = configuration
            } else {
                result.append(configuration)
            }
        }
        return AutomationSettings.normalizedSources(result)
    }

    func automationRuleConfigurations(
        from payloads: [[String: Any]],
        currentRules: [AutomationRuleConfiguration]
    ) throws -> [AutomationRuleConfiguration] {
        var result = currentRules
        for payload in payloads {
            guard let kindRaw = payload["kind"] as? String,
                  let kind = AutomationRuleKind(rawValue: kindRaw),
                  let sourceRaw = payload["source"] as? String,
                  let source = AutomationSourceID(rawValue: sourceRaw) else {
                continue
            }
            let id = payload["id"] as? String ?? UUID().uuidString.lowercased()
            let enabled = payload["enabled"] as? Bool ?? false
            let configuration: AutomationRuleConfiguration
            switch kind {
            case .calendarAutopilot:
                var settings = try decodePayload(payload["payload"], as: AutopilotSettings.self)
                settings.enabled = enabled
                configuration = AutomationRuleConfiguration.calendarAutopilot(settings).withID(id)
            }
            if let index = result.firstIndex(where: { $0.kind == kind && $0.source == source }) {
                result[index] = configuration
            } else {
                result.append(configuration)
            }
        }
        return AutomationSettings.normalizedRules(result)
    }

    func automationSourceConfigurationPayload(_ configuration: AutomationSourceConfiguration) -> [String: Any] {
        var sourcePayload = configuration.payload
        switch configuration.source {
        case .localHTTPAPI:
            var settings = configuration.localHTTPAPISettings
            settings.apiKey = secretMask(for: settings.apiKeyKeychainRef) ?? ""
            settings.apiKeyKeychainRef = nil
            sourcePayload = ConfigurationPayloadCodec.encode(settings)
        case .calDAV:
            var settings = configuration.calDAVSettings
            settings.config.password = secretMask(for: settings.passwordKeychainRef) ?? ""
            settings.passwordKeychainRef = nil
            sourcePayload = ConfigurationPayloadCodec.encode(settings)
        case .windowObserver:
            sourcePayload = ConfigurationPayloadCodec.encode(configuration.windowObserverSettings.normalized())
        }
        return [
            "id": configuration.id,
            "source": configuration.source.rawValue,
            "enabled": configuration.enabled,
            "payload": sourcePayload.jsonObject,
        ]
    }

    static func automationRuleConfigurationPayload(_ configuration: AutomationRuleConfiguration) -> [String: Any] {
        [
            "id": configuration.id,
            "kind": configuration.kind.rawValue,
            "source": configuration.source.rawValue,
            "enabled": configuration.enabled,
            "payload": configuration.payload.jsonObject,
        ]
    }

    func applyGroupedSettingsPayload(_ body: [String: Any], to settings: inout AppSettings) throws {
        if let application = body["application"] as? [String: Any] {
            if let storageRoot = application["storageRoot"] as? String {
                settings.application.storageRoot = storageRoot
            }
            if let launchAtLogin = application["launchAtLogin"] as? Bool {
                settings.application.launchAtLogin = launchAtLogin
            }
            if let hideDockIcon = application["hideDockIcon"] as? Bool {
                settings.application.hideDockIcon = hideDockIcon
            }
            if let showNotifications = application["showNotifications"] as? Bool {
                settings.application.showNotifications = showNotifications
            }
            if let disableSummaryFooter = application["disableSummaryFooter"] as? Bool {
                settings.application.disableSummaryFooter = disableSummaryFooter
            }
            if let liveTranscriptEnabled = application["liveTranscriptEnabled"] as? Bool {
                settings.application.liveTranscriptEnabled = liveTranscriptEnabled
            }
            if let postProcessingTabEnabled = application["postProcessingTabEnabled"] as? Bool {
                settings.application.postProcessingTabEnabled = postProcessingTabEnabled
            }
            if let notificationCategories = application["notificationCategories"] as? [String] {
                settings.application.notificationCategories = notificationCategories
            }
            if let presenceCheckEnabled = application["presenceCheckEnabled"] as? Bool {
                settings.application.presenceCheckEnabled = presenceCheckEnabled
            }
            if let locale = application["locale"] as? String {
                settings.application.locale = locale
            }
            if let jobsHistoryLimit = application["jobsHistoryLimit"] as? Int {
                settings.application.jobsHistoryLimit = jobsHistoryLimit
            }
        }

        if let recording = body["recording"] as? [String: Any],
           let microphoneVoiceProcessingEnabled = recording["microphoneVoiceProcessingEnabled"] as? Bool {
            settings.recording.microphoneVoiceProcessingEnabled = microphoneVoiceProcessingEnabled
        }
        if let recording = body["recording"] as? [String: Any],
           recording.keys.contains("microphoneDeviceUID") {
            let uid = (recording["microphoneDeviceUID"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            settings.recording.microphoneDeviceUID = uid?.isEmpty == false ? uid : nil
        }

        if let summary = body["summary"] as? [String: Any] {
            if let enabled = summary["enabled"] as? Bool {
                settings.summary.enabled = enabled
            }
        }

        if let llm = body["llm"] as? [String: Any] {
            if let connectionConfigs = llm["connections"] as? [[String: Any]] {
                settings.llm.connections = try summaryProviderEntries(from: connectionConfigs)
            }
        }

        if let prompts = body["prompts"] as? [String: Any] {
            if let itemPayloads = prompts["items"] as? [[String: Any]] {
                settings.prompts.items = Self.promptItems(from: itemPayloads)
            }
            if let summaryAssignment = prompts["summary"] as? [String: Any] {
                if let promptID = summaryAssignment["promptID"] as? String {
                    settings.prompts.summary.promptID = promptID
                }
                if let connectionIDs = summaryAssignment["connectionIDs"] as? [String] {
                    settings.prompts.summary.connectionIDs = connectionIDs
                }
                if summaryAssignment.keys.contains("speakerContextPromptID") {
                    settings.prompts.summary.speakerContextPromptID = summaryAssignment["speakerContextPromptID"] as? String
                }
            }
            if let liveAssignment = prompts["live"] as? [String: Any] {
                if liveAssignment.keys.contains("promptID") {
                    settings.prompts.live.promptID = liveAssignment["promptID"] as? String
                }
                if liveAssignment.keys.contains("connectionID") {
                    settings.prompts.live.connectionID = liveAssignment["connectionID"] as? String
                }
            }
            if let transcriptCleanupAssignment = prompts["transcriptCleanup"] as? [String: Any] {
                if let enabled = transcriptCleanupAssignment["enabled"] as? Bool {
                    settings.prompts.transcriptCleanup.enabled = enabled
                }
                if transcriptCleanupAssignment.keys.contains("promptID") {
                    settings.prompts.transcriptCleanup.promptID = transcriptCleanupAssignment["promptID"] as? String
                }
                if let connectionIDs = transcriptCleanupAssignment["connectionIDs"] as? [String] {
                    settings.prompts.transcriptCleanup.connectionIDs = connectionIDs
                }
            }
        }

        if let transcription = body["transcription"] as? [String: Any] {
            if let diarizationEnabled = transcription["diarizationEnabled"] as? Bool {
                settings.transcription.diarizationEnabled = diarizationEnabled
            }
            if let skipMicrophoneDiarization = transcription["skipMicrophoneDiarization"] as? Bool {
                settings.transcription.skipMicrophoneDiarization = skipMicrophoneDiarization
            }
            if let providerConfigs = transcription["providers"] as? [[String: Any]] {
                settings.transcription.providers = try transcriptionProviderConfigurations(
                    from: providerConfigs
                )
            }
            if let customVocabulary = transcription["customVocabulary"] as? String {
                settings.transcription.setLegacyVocabularyForAllProviders(customVocabulary)
            }
        }

        if let postProcessing = body["postProcessing"] as? [String: Any] {
            if let enabled = postProcessing["enabled"] as? Bool {
                settings.postProcessing.enabled = enabled
            }
            if let rulePayloads = postProcessing["rules"] as? [[String: Any]] {
                settings.postProcessing.rules = try postProcessingRules(from: rulePayloads)
            }
            settings.postProcessing.rules = PostProcessingSettings.normalizedRules(settings.postProcessing.rules)
        }

        if let automation = body["automation"] as? [String: Any] {
            if let enabled = automation["enabled"] as? Bool {
                settings.automation.enabled = enabled
            }
            if let sourceConfigs = automation["sources"] as? [[String: Any]] {
                settings.automation.sources = try automationSourceConfigurations(
                    from: sourceConfigs,
                    currentSettings: settings
                )
            }
            if let ruleConfigs = automation["rules"] as? [[String: Any]] {
                settings.automation.rules = try automationRuleConfigurations(
                    from: ruleConfigs,
                    currentRules: settings.automation.rules
                )
            }
        }
    }

    func settingsPayload(_ settings: AppSettings) -> [String: Any] {
        [
            "application": [
                "storageRoot": settings.application.storageRoot,
                "launchAtLogin": settings.application.launchAtLogin,
                "hideDockIcon": settings.application.hideDockIcon,
                "showNotifications": settings.application.showNotifications,
                "disableSummaryFooter": settings.application.disableSummaryFooter,
                "liveTranscriptEnabled": settings.application.liveTranscriptEnabled,
                "postProcessingTabEnabled": settings.application.postProcessingTabEnabled,
                "notificationCategories": settings.application.notificationCategories,
                "presenceCheckEnabled": settings.application.presenceCheckEnabled,
                "locale": settings.application.locale,
                "jobsHistoryLimit": settings.application.jobsHistoryLimit,
            ],
            "recording": [
                "microphoneVoiceProcessingEnabled": settings.recording.microphoneVoiceProcessingEnabled,
                "microphoneDeviceUID": settings.recording.microphoneDeviceUID ?? "",
            ],
            "summary": [
                "enabled": settings.summary.enabled,
            ],
            "llm": [
                "connections": settings.llm.connections.map { summaryProviderConfigurationPayload($0) },
            ],
            "prompts": [
                "items": settings.prompts.items.map(Self.promptItemPayload),
                "summary": [
                    "promptID": settings.prompts.summary.promptID as Any,
                    "connectionIDs": settings.prompts.summary.connectionIDs,
                    "speakerContextPromptID": settings.prompts.summary.speakerContextPromptID as Any,
                ],
                "live": [
                    "promptID": settings.prompts.live.promptID as Any,
                    "connectionID": settings.prompts.live.connectionID as Any,
                ],
                "transcriptCleanup": [
                    "enabled": settings.prompts.transcriptCleanup.enabled,
                    "promptID": settings.prompts.transcriptCleanup.promptID as Any,
                    "connectionIDs": settings.prompts.transcriptCleanup.connectionIDs,
                ],
            ],
            "transcription": [
                "diarizationEnabled": settings.transcription.diarizationEnabled,
                "skipMicrophoneDiarization": settings.transcription.skipMicrophoneDiarization,
                "providers": settings.transcription.providers.map(Self.transcriptionProviderConfigurationPayload),
            ],
            "automation": [
                "enabled": settings.automation.enabled,
                "sources": settings.automation.sources.map { automationSourceConfigurationPayload($0) },
                "rules": settings.automation.rules.map(Self.automationRuleConfigurationPayload),
            ],
            "postProcessing": [
                "enabled": settings.postProcessing.enabled,
                "rules": settings.postProcessing.rules.map(Self.postProcessingRulePayload),
            ],
        ]
    }

    static func postProcessingRulePayload(_ rule: PostProcessingRuleConfiguration) -> [String: Any] {
        codablePayload(rule)
    }

    func postProcessingRules(from payloads: [[String: Any]]) throws -> [PostProcessingRuleConfiguration] {
        try payloads.map(Self.codableObject)
    }

    static func codablePayload<T: Encodable>(_ value: T) -> [String: Any] {
        guard let data = try? JSONEncoder().encode(value),
              let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any] else {
            return [:]
        }
        return dictionary
    }

    static func codableObject<T: Decodable>(_ payload: [String: Any]) throws -> T {
        let data = try JSONSerialization.data(withJSONObject: payload)
        return try JSONDecoder().decode(T.self, from: data)
    }

    func secretMask(for ref: String?) -> String? {
        guard let ref, !ref.isEmpty, keychainStore.load(key: ref) != nil else {
            return nil
        }
        return "***"
    }

    func updateSecret(_ rawValue: Any?, currentRef: inout String?) throws {
        guard let rawValue else {
            return
        }
        if rawValue is NSNull {
            if let currentRef {
                keychainStore.delete(key: currentRef)
            }
            currentRef = nil
            return
        }
        guard let stringValue = rawValue as? String else {
            throw APIError(status: 400, code: "invalid_request", message: "Secret fields must be strings or null.")
        }
        if stringValue == "***" || stringValue.hasPrefix("••") {
            return
        }
        if stringValue.isEmpty {
            if let currentRef {
                keychainStore.delete(key: currentRef)
            }
            currentRef = nil
            return
        }
        let reference = currentRef?.isEmpty == false ? currentRef! : UUID().uuidString.lowercased()
        try keychainStore.save(key: reference, value: stringValue)
        currentRef = reference
    }
}

private extension AutomationSourceConfiguration {
    func withID(_ id: String) -> AutomationSourceConfiguration {
        var copy = self
        copy.id = id
        return copy
    }
}

private extension AutomationRuleConfiguration {
    func withID(_ id: String) -> AutomationRuleConfiguration {
        var copy = self
        copy.id = id
        return copy
    }
}
