import XCTest
@testable import AnyBrief

final class SummaryProviderRegistryTests: XCTestCase {
    func testDefaultRegistryContainsCurrentSummaryProviders() throws {
        let registry = SummaryProviderRegistry.default

        XCTAssertEqual(
            registry.modules.map(\.id),
            [.openAICompatible, .localOllama, .commandLine]
        )
        XCTAssertEqual(try registry.module(for: .openAICompatible).title, "OpenAI-compatible")
        XCTAssertEqual(try registry.module(for: .localOllama).title, "Local Ollama")
        XCTAssertEqual(try registry.module(for: .commandLine).title, "CLI")
    }

    func testRegistryBuildsProviderDefaultsWithoutChangingSettingsShape() throws {
        let openAI = try SummaryProviderRegistry.default.defaultConfiguration(for: .openAICompatible)
        let ollama = try SummaryProviderRegistry.default.defaultConfiguration(for: .localOllama)
        let cli = try SummaryProviderRegistry.default.defaultConfiguration(for: .commandLine)

        XCTAssertEqual(openAI.provider, .openAICompatible)
        XCTAssertFalse(openAI.payload.isEmpty)

        XCTAssertEqual(ollama.provider, .localOllama)
        XCTAssertEqual(ollama.ollamaConfig.contextLength, OllamaDefaults.contextLength)
        XCTAssertEqual(ollama.ollamaConfig.chunkThreshold, OllamaDefaults.chunkThreshold)
        XCTAssertEqual(ollama.ollamaConfig.chunkSize, OllamaDefaults.chunkSize)
        XCTAssertFalse(ollama.payload.isEmpty)

        XCTAssertEqual(cli.provider, .commandLine)
        XCTAssertEqual(cli.cliConfig.commandPreset, CLIDefaults.preset)
        XCTAssertTrue(cli.cliCodexIgnoreUserConfig)
        XCTAssertTrue(cli.cliAPIPreflightEnabled)
        XCTAssertFalse(cli.payload.isEmpty)
    }

    func testLegacyCLIConfigurationDefaultsToIgnoringCodexUserConfiguration() {
        var configuration = SummaryProviderConfiguration(provider: .commandLine)
        configuration.payload = [
            "commandPreset": .string("codex"),
            "commandLine": .string(""),
            "codexSandboxMode": .string("workspace-write"),
            "claudeAllowedTools": .string("Read"),
        ]

        XCTAssertEqual(configuration.cliCommandPreset, "codex")
        XCTAssertEqual(configuration.cliCodexSandboxMode, "workspace-write")
        XCTAssertEqual(configuration.cliClaudeAllowedTools, "Read")
        XCTAssertTrue(configuration.cliCodexIgnoreUserConfig)
        XCTAssertTrue(configuration.cliAPIPreflightEnabled)
    }

    func testCLIConfigurationCanDisableAPIPreflight() throws {
        var configuration = SummaryProviderConfiguration.cli(preset: "claude")
        configuration.cliAPIPreflightEnabled = false

        let data = try JSONEncoder().encode(configuration.cliConfig)
        let decoded = try JSONDecoder().decode(CLIConfig.self, from: data)

        XCTAssertFalse(decoded.apiPreflightEnabled)
    }

    func testCLIPresetNormalizationDropsStoredCommandLine() {
        var configuration = SummaryProviderConfiguration.cli(
            preset: "claude",
            commandLine: #"printf "old custom command""#
        )
        configuration = CLIModule().normalize(configuration)

        XCTAssertEqual(configuration.cliCommandPreset, "claude")
        XCTAssertEqual(configuration.cliCommandLine, "")
    }

    func testCLIConfigurationWithCommandLineDefaultsToCustomPreset() {
        let configuration = SummaryProviderConfiguration.cli(commandLine: #"printf "custom command""#)

        XCTAssertEqual(configuration.cliCommandPreset, "custom")
        XCTAssertTrue(configuration.cliCommandLine.contains("custom command"))
    }

    func testCLIMetadataIncludesCommandOnlyForCustomPreset() {
        let settings = AppSettings.default
        let module = CLIModule()

        let presetMetadata = module.metadata(
            from: .cli(preset: "claude", commandLine: #"printf "old custom command""#),
            settings: settings
        )
        XCTAssertEqual(presetMetadata.commandPreset, "claude")
        XCTAssertNil(presetMetadata.commandLine)

        let customMetadata = module.metadata(
            from: .cli(preset: "custom", commandLine: #"printf "custom command""#),
            settings: settings
        )
        XCTAssertEqual(customMetadata.commandPreset, "custom")
        XCTAssertTrue(customMetadata.commandLine?.contains("custom command") == true)
    }
}
