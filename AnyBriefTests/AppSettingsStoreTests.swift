import XCTest
@testable import AnyBrief

/// Tests settings persistence behavior from the app settings/storage spec.
final class AppSettingsStoreTests: XCTestCase {
    private var sandboxURL: URL!
    private var store: AppSettingsStore!

    override func setUpWithError() throws {
        sandboxURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: sandboxURL, withIntermediateDirectories: true)
        store = AppSettingsStore(fileManager: .default, rootDirectoryURL: sandboxURL)
    }

    override func tearDownWithError() throws {
        if let sandboxURL, FileManager.default.fileExists(atPath: sandboxURL.path) {
            try FileManager.default.removeItem(at: sandboxURL)
        }
    }

    func testSaveCreatesConfigDirectoryAndPersistsSettings() async throws {
        var settings = AppSettings.default
        settings.automation.calDAVSettings.name = "work"
        settings.automation.localHTTPAPISettings.enabled = true
        settings.automation.localHTTPAPISettings.port = 48_000
        settings.summary.enabled = true
        settings.prompts.summary.speakerContextPromptID = "speaker-context-id"
        settings.recording.microphoneDeviceUID = "test-input-device"
        settings.transcription.diarizationEnabled = false
        settings.transcription.skipMicrophoneDiarization = false
        settings.transcription.fluidAudioSTTConfig.customVocabulary = ""
        settings.transcription.whisperCppConfig.customVocabulary = "Admon\nMGCom: сам же ком"

        try await store.save(settings)

        let configDirectoryURL = sandboxURL
            .appendingPathComponent("anybrief", isDirectory: true)
            .appendingPathComponent("config", isDirectory: true)
        var isDirectory: ObjCBool = false
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: configDirectoryURL.path, isDirectory: &isDirectory)
        )
        XCTAssertTrue(isDirectory.boolValue)

        let settingsFileURL = configDirectoryURL.appendingPathComponent("settings.json", isDirectory: false)
        let savedObject = try JSONSerialization.jsonObject(with: Data(contentsOf: settingsFileURL))
        guard let savedDictionary = savedObject as? [String: Any] else {
            return XCTFail("Expected grouped settings dictionary.")
        }
        XCTAssertNotNil(savedDictionary["application"])
        XCTAssertNotNil(savedDictionary["recording"])
        XCTAssertNotNil(savedDictionary["summary"])
        XCTAssertNotNil(savedDictionary["transcription"])
        XCTAssertNotNil(savedDictionary["automation"])
        XCTAssertNotNil(savedDictionary["postProcessing"])
        if let postProcessing = savedDictionary["postProcessing"] as? [String: Any] {
            XCTAssertTrue((postProcessing["rules"] as? [Any])?.isEmpty == true)
        } else {
            XCTFail("Expected post-processing settings dictionary.")
        }
        if let automation = savedDictionary["automation"] as? [String: Any] {
            XCTAssertNotNil(automation["sources"])
            XCTAssertNotNil(automation["rules"])
            XCTAssertNil(automation["localHTTPAPI"])
            XCTAssertNil(automation["calDAV"])
            XCTAssertNil(automation["autopilot"])
            XCTAssertNil(automation["windowObserver"])
        } else {
            XCTFail("Expected automation settings dictionary.")
        }
        XCTAssertNil(savedDictionary["summaryProviderConfigurations"])
        XCTAssertNil(savedDictionary["sttSpeakersMode"])
        XCTAssertNil(savedDictionary["caldavConfig"])
        XCTAssertNil((savedDictionary["transcription"] as? [String: Any])?["customVocabulary"])

        let loadedSettings = try store.loadSynchronously()
        XCTAssertEqual(loadedSettings.automation.calDAVSettings.name, settings.automation.calDAVSettings.name)
        XCTAssertEqual(loadedSettings.automation.localHTTPAPISettings.enabled, settings.automation.localHTTPAPISettings.enabled)
        XCTAssertEqual(loadedSettings.automation.localHTTPAPISettings.port, settings.automation.localHTTPAPISettings.port)
        XCTAssertEqual(loadedSettings.summary.enabled, settings.summary.enabled)
        XCTAssertEqual(loadedSettings.prompts.summary.speakerContextPromptID, settings.prompts.summary.speakerContextPromptID)
        XCTAssertEqual(loadedSettings.recording.microphoneDeviceUID, "test-input-device")
        XCTAssertFalse(loadedSettings.transcription.diarizationEnabled)
        XCTAssertFalse(loadedSettings.transcription.skipMicrophoneDiarization)
        XCTAssertEqual(loadedSettings.transcription.fluidAudioSTTConfig.customVocabulary, "")
        XCTAssertEqual(
            loadedSettings.transcription.whisperCppConfig.customVocabulary,
            "Admon\nMGCom: сам же ком"
        )
    }

    func testLoadSynchronouslyDefaultsMissingGroupedValues() throws {
        let configDirectoryURL = sandboxURL
            .appendingPathComponent("anybrief", isDirectory: true)
            .appendingPathComponent("config", isDirectory: true)
        try FileManager.default.createDirectory(at: configDirectoryURL, withIntermediateDirectories: true)
        let settingsFileURL = configDirectoryURL.appendingPathComponent("settings.json", isDirectory: false)
        let settingsJSON = """
        {
          "application": {
            "storageRoot": "~/custom-anybrief"
          },
          "recording": {},
          "summary": {
            "enabled": true
          },
          "transcription": {},
          "automation": {
            "sources": [
              {
                "source": "local_http_api",
                "enabled": false,
                "payload": {
                  "port": 48000
                }
              },
              {
                "source": "caldav",
                "enabled": false,
                "payload": {
                  "name": "work"
                }
              }
            ],
            "rules": []
          }
        }
        """
        try settingsJSON.write(to: settingsFileURL, atomically: true, encoding: .utf8)
        try writeGroupedSettingsMarker(in: configDirectoryURL)

        let loadedSettings = try store.loadSynchronously()
        XCTAssertTrue(loadedSettings.transcription.diarizationEnabled)
        XCTAssertTrue(loadedSettings.transcription.skipMicrophoneDiarization)
        XCTAssertEqual(loadedSettings.transcription.customVocabulary, "")
        XCTAssertEqual(loadedSettings.transcription.fluidAudioSTTConfig.customVocabulary, "")
        XCTAssertEqual(loadedSettings.transcription.whisperCppConfig.customVocabulary, "")
        XCTAssertNil(loadedSettings.recording.microphoneDeviceUID)

        XCTAssertFalse(loadedSettings.automation.localHTTPAPISettings.enabled)
        XCTAssertTrue(loadedSettings.summary.enabled)
        XCTAssertEqual(loadedSettings.automation.localHTTPAPISettings.port, 48_000)
        XCTAssertEqual(loadedSettings.automation.calDAVSettings.name, "work")
        XCTAssertEqual(loadedSettings.automation.windowObserverSettings.pollIntervalSec, 30)
        XCTAssertEqual(loadedSettings.application.storageRoot, "~/custom-anybrief")
        XCTAssertFalse(loadedSettings.application.liveTranscriptEnabled)
        XCTAssertTrue(loadedSettings.application.postProcessingTabEnabled)
        XCTAssertTrue(loadedSettings.postProcessing.rules.isEmpty)
    }

    func testLoadSynchronouslyMigratesLegacyDiarizationThresholdOnce() async throws {
        let configDirectoryURL = sandboxURL
            .appendingPathComponent("anybrief", isDirectory: true)
            .appendingPathComponent("config", isDirectory: true)
        try FileManager.default.createDirectory(at: configDirectoryURL, withIntermediateDirectories: true)
        let settingsFileURL = configDirectoryURL.appendingPathComponent("settings.json", isDirectory: false)
        let settingsJSON = """
        {
          "transcription": {
            "providers": [
              {
                "id": "fluid",
                "provider": "fluid_audio_stt",
                "enabled": true,
                "payload": {
                  "speakersMode": "auto",
                  "speakersCount": 2,
                  "threshold": 0.35
                }
              },
              {
                "id": "whisper",
                "provider": "whisper_cpp",
                "enabled": false,
                "payload": {
                  "model": "small",
                  "language": "auto",
                  "useGPU": true,
                  "speakersMode": "auto",
                  "speakersCount": 2,
                  "threshold": 0.35
                }
              }
            ]
          }
        }
        """
        try settingsJSON.write(to: settingsFileURL, atomically: true, encoding: .utf8)
        try writeGroupedSettingsMarker(in: configDirectoryURL)

        var loadedSettings = try store.loadSynchronously()

        XCTAssertEqual(loadedSettings.transcription.fluidAudioSTTConfig.threshold, 0.65)
        XCTAssertEqual(loadedSettings.transcription.whisperCppConfig.threshold, 0.65)
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: configDirectoryURL
                    .appendingPathComponent(SettingsMigrationService.diarizationThresholdMarkerFileName)
                    .path
            )
        )

        let persistedSettings = try JSONDecoder().decode(
            AppSettings.self,
            from: Data(contentsOf: settingsFileURL)
        )
        XCTAssertEqual(persistedSettings.transcription.fluidAudioSTTConfig.threshold, 0.65)
        XCTAssertEqual(persistedSettings.transcription.whisperCppConfig.threshold, 0.65)

        loadedSettings.transcription.fluidAudioSTTConfig.threshold = 0.35
        loadedSettings.transcription.whisperCppConfig.threshold = 0.35
        try await store.save(loadedSettings)

        let reloadedSettings = try store.loadSynchronously()
        XCTAssertEqual(reloadedSettings.transcription.fluidAudioSTTConfig.threshold, 0.35)
        XCTAssertEqual(reloadedSettings.transcription.whisperCppConfig.threshold, 0.35)
    }

    func testLoadMigratesLegacySummaryProvidersIntoLLMAndPrompts() throws {
        let configDirectoryURL = sandboxURL
            .appendingPathComponent("anybrief", isDirectory: true)
            .appendingPathComponent("config", isDirectory: true)
        try FileManager.default.createDirectory(at: configDirectoryURL, withIntermediateDirectories: true)
        // Grouped marker so the legacy flat reset does not fire.
        try "grouped-v1\n".write(
            to: configDirectoryURL.appendingPathComponent("settings.grouped-v1", isDirectory: false),
            atomically: true,
            encoding: .utf8
        )
        let settingsJSON = """
        {
          "summary": {
            "enabled": true,
            "speakerContext": "Mic = Alice",
            "retryCount": 5,
            "timeoutSec": 240,
            "providers": [
              {
                "id": "openai-main",
                "provider": "openai_compatible",
                "enabled": true,
                "payload": {
                  "apiURL": "https://api.example/v1/chat/completions",
                  "model": "gpt-test",
                  "apiKey": "",
                  "apiKeyKeychainRef": "openai-key-ref",
                  "prompt": "Custom summary prompt"
                }
              },
              {
                "id": "ollama-backup",
                "provider": "local_ollama",
                "enabled": false,
                "payload": {
                  "model": "llama3.2:latest",
                  "prompt": "Custom summary prompt"
                }
              }
            ]
          }
        }
        """
        try settingsJSON.write(
            to: configDirectoryURL.appendingPathComponent("settings.json", isDirectory: false),
            atomically: true,
            encoding: .utf8
        )

        let settings = try store.loadSynchronously()

        XCTAssertTrue(settings.summary.enabled)
        XCTAssertTrue(settings.llm.connections.allSatisfy { $0.timeoutSec == 240 })
        XCTAssertTrue(settings.llm.connections.allSatisfy { $0.retryCount == 5 })
        XCTAssertEqual(settings.prompts.trimmedSpeakerContext, "Mic = Alice")

        XCTAssertEqual(settings.llm.connections.map(\.id), ["openai-main", "ollama-backup"])
        XCTAssertEqual(settings.llm.connections[0].openAIAPIKeyKeychainRef, "openai-key-ref")
        XCTAssertNil(settings.llm.connections[0].payload["prompt"])
        XCTAssertNil(settings.llm.connections[1].payload["prompt"])

        let migratedPrompt = settings.prompts.items.first { $0.id == "migrated-openai-main" }
        XCTAssertEqual(migratedPrompt?.text, "Custom summary prompt")
        XCTAssertEqual(settings.prompts.summary.promptID, "migrated-openai-main")
        // Identical prompt texts are deduplicated across providers.
        XCTAssertNil(settings.prompts.items.first { $0.id == "migrated-ollama-backup" })

        // Fallback chain keeps the legacy behavior: all enabled connections in order.
        XCTAssertTrue(settings.prompts.summary.connectionIDs.isEmpty)
        XCTAssertEqual(settings.summaryLLMChain.map(\.id), ["openai-main"])

        // Live requires an explicit connection choice after migration.
        XCTAssertNil(settings.prompts.live.connectionID)
        XCTAssertNil(settings.liveLLMConnection)
    }

    func testLoadMigratesGlobalLLMTimeoutAndSpeakerContextToPerConnectionFormat() throws {
        let configDirectoryURL = sandboxURL
            .appendingPathComponent("anybrief", isDirectory: true)
            .appendingPathComponent("config", isDirectory: true)
        try FileManager.default.createDirectory(at: configDirectoryURL, withIntermediateDirectories: true)
        try "grouped-v1\n".write(
            to: configDirectoryURL.appendingPathComponent("settings.grouped-v1", isDirectory: false),
            atomically: true,
            encoding: .utf8
        )
        // Shape used before per-connection timeout/retry and the speaker-context
        // combobox: llm.connections already populated, but timeoutSec/retryCount
        // were global and prompts.summary.speakerContext was free text.
        let settingsJSON = """
        {
          "llm": {
            "timeoutSec": 240,
            "retryCount": 5,
            "connections": [
              { "id": "conn-a", "provider": "openai_compatible", "enabled": true, "payload": {} },
              { "id": "conn-b", "provider": "openai_compatible", "enabled": true, "payload": {}, "timeoutSec": 60 }
            ]
          },
          "prompts": {
            "summary": {
              "promptID": "summary-default",
              "speakerContext": "Mic = Alice"
            }
          }
        }
        """
        try settingsJSON.write(
            to: configDirectoryURL.appendingPathComponent("settings.json", isDirectory: false),
            atomically: true,
            encoding: .utf8
        )

        let settings = try store.loadSynchronously()

        // conn-a had no explicit timeout/retry, so it inherits the old global values.
        XCTAssertEqual(settings.llm.connections[0].timeoutSec, 240)
        XCTAssertEqual(settings.llm.connections[0].retryCount, 5)
        // conn-b already had its own timeout, which must not be overwritten.
        XCTAssertEqual(settings.llm.connections[1].timeoutSec, 60)
        XCTAssertEqual(settings.llm.connections[1].retryCount, 5)

        XCTAssertEqual(settings.prompts.trimmedSpeakerContext, "Mic = Alice")
    }

    func testAppSettingsConfigFileRoundTripsPostProcessingRules() throws {
        var settings = AppSettings.default
        settings.application.postProcessingTabEnabled = true
        settings.postProcessing.enabled = true
        settings.postProcessing.rules = [
            PostProcessingRuleConfiguration(
                id: "custom-rule",
                title: "Custom Rule",
                calendarTitlePattern: "Weekly Sync",
                destinationFolderPath: "/tmp/weekly-sync",
                filenameTemplate: "{date} {calendarTitle}.md",
                conflictBehavior: .addSuffix
            ),
        ]

        let data = try JSONEncoder().encode(AppSettingsConfigFile(settings: settings))
        let decoded = try JSONDecoder().decode(AppSettingsConfigFile.self, from: data).appSettings()

        XCTAssertTrue(decoded.application.postProcessingTabEnabled)
        XCTAssertEqual(decoded.postProcessing.rules, settings.postProcessing.rules)
    }

    func testLoadSynchronouslyRenamesLegacyFlatSettingsAndCreatesGroupedDefaults() throws {
        let configDirectoryURL = sandboxURL
            .appendingPathComponent("anybrief", isDirectory: true)
            .appendingPathComponent("config", isDirectory: true)
        try FileManager.default.createDirectory(at: configDirectoryURL, withIntermediateDirectories: true)
        let settingsFileURL = configDirectoryURL.appendingPathComponent("settings.json", isDirectory: false)
        let settingsJSON = """
        {
          "summaryProviderConfigurations": [
            {
              "provider": "openai_compatible",
              "apiURL": "https://old.example.com",
              "model": "legacy-model"
            }
          ],
          "sttSpeakersMode": "fixed",
          "sttSpeakersCount": 9,
          "sttThreshold": 0.99,
          "caldavConfig": {
            "url": "https://caldav.example.com",
            "username": "legacy"
          },
          "autopilotPollIntervalSec": 7200,
          "apiEnabled": true,
          "apiPort": 49999
        }
        """
        try settingsJSON.write(to: settingsFileURL, atomically: true, encoding: .utf8)

        let loadedSettings = try store.loadSynchronously()

        XCTAssertEqual(loadedSettings.llm.connections, AppSettings.default.llm.connections)
        XCTAssertEqual(loadedSettings.transcription.fluidAudioSTTConfig, AppSettings.default.transcription.fluidAudioSTTConfig)
        XCTAssertEqual(loadedSettings.automation.calDAVSettings.config.url, AppSettings.default.automation.calDAVSettings.config.url)
        XCTAssertEqual(loadedSettings.automation.calendarAutopilotSettings.pollIntervalSec, AppSettings.default.automation.calendarAutopilotSettings.pollIntervalSec)
        XCTAssertEqual(loadedSettings.automation.localHTTPAPISettings.enabled, AppSettings.default.automation.localHTTPAPISettings.enabled)
        XCTAssertEqual(loadedSettings.automation.localHTTPAPISettings.port, AppSettings.default.automation.localHTTPAPISettings.port)

        let legacyFiles = try FileManager.default.contentsOfDirectory(atPath: configDirectoryURL.path)
            .filter { $0.hasPrefix("settings.legacy-") && $0.hasSuffix(".json") }
        XCTAssertEqual(legacyFiles.count, 1)
        let legacyData = try Data(contentsOf: configDirectoryURL.appendingPathComponent(legacyFiles[0]))
        XCTAssertEqual(String(data: legacyData, encoding: .utf8), settingsJSON)

        let groupedObject = try JSONSerialization.jsonObject(with: Data(contentsOf: settingsFileURL))
        guard let groupedDictionary = groupedObject as? [String: Any] else {
            return XCTFail("Expected default grouped settings dictionary.")
        }
        XCTAssertNotNil(groupedDictionary["application"])
        XCTAssertNotNil(groupedDictionary["recording"])
        XCTAssertNotNil(groupedDictionary["summary"])
        XCTAssertNotNil(groupedDictionary["transcription"])
        XCTAssertNotNil(groupedDictionary["automation"])
        XCTAssertNil(groupedDictionary["summaryProviderConfigurations"])
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: configDirectoryURL.appendingPathComponent(SettingsResetService.groupedMarkerFileName).path
            )
        )
    }

    func testLoadSynchronouslyRenamesUnreadableLegacySettingsWithoutParsingContent() throws {
        let configDirectoryURL = sandboxURL
            .appendingPathComponent("anybrief", isDirectory: true)
            .appendingPathComponent("config", isDirectory: true)
        try FileManager.default.createDirectory(at: configDirectoryURL, withIntermediateDirectories: true)
        let settingsFileURL = configDirectoryURL.appendingPathComponent("settings.json", isDirectory: false)
        let unreadableLegacyData = Data([0x00, 0x80, 0xff, 0x7b])
        try unreadableLegacyData.write(to: settingsFileURL)

        let loadedSettings = try store.loadSynchronously()

        XCTAssertEqual(loadedSettings.automation.localHTTPAPISettings.port, AppSettings.default.automation.localHTTPAPISettings.port)
        let legacyFiles = try FileManager.default.contentsOfDirectory(atPath: configDirectoryURL.path)
            .filter { $0.hasPrefix("settings.legacy-") && $0.hasSuffix(".json") }
        XCTAssertEqual(legacyFiles.count, 1)
        let legacyData = try Data(contentsOf: configDirectoryURL.appendingPathComponent(legacyFiles[0]))
        XCTAssertEqual(legacyData, unreadableLegacyData)
    }

    private func writeGroupedSettingsMarker(in configDirectoryURL: URL) throws {
        try Data("grouped-v1\n".utf8).write(
            to: configDirectoryURL.appendingPathComponent(SettingsResetService.groupedMarkerFileName),
            options: .atomic
        )
    }
}
