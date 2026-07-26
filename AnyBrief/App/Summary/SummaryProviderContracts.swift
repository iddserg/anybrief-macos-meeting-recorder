import Foundation
import SwiftUI

struct SummaryProviderRuntimeContext {
    let keychainStore: SecretStoreProtocol
    let httpClient: HTTPJSONClient
    let session: URLSession
    let fileManager: FileManager
    let logger: (@Sendable (String, LoggingService.LogLevel) async -> Void)?
}

struct SummaryProviderDiagnosticsContext {
    let session: URLSession
    let fileManager: FileManager
}

struct SummaryProviderInput {
    let transcript: String
    /// Fully built system prompt (task prompt + %lang% + optional context).
    /// Runners must not read prompts from the connection payload.
    let systemPrompt: String
    let settings: AppSettings
    let configuration: SummaryProviderConfiguration
    let workingDirectory: URL?
    let transcriptURL: URL?
}

protocol SummaryProviderRunner {
    var provider: SummaryProvider { get }

    func summarize(input: SummaryProviderInput) async throws -> String
}

protocol SummaryProviderDiagnostics {
    func diagnose(
        configuration: SummaryProviderConfiguration,
        settings: AppSettings,
        openAIAPIKey: String
    ) async throws -> SummaryProviderDiagnosticResult
}

struct SummaryProviderSettingsViewContext {
    let configuration: Binding<SummaryProviderConfiguration>
    let apiKey: Binding<String>
}

protocol SummaryProviderModule {
    var id: SummaryProvider { get }
    var title: String { get }
    var systemImage: String { get }
    var allowsMultipleConfigurations: Bool { get }

    func defaultConfiguration() -> SummaryProviderConfiguration
    func normalize(_ configuration: SummaryProviderConfiguration) -> SummaryProviderConfiguration
    func makeRunner(context: SummaryProviderRuntimeContext) -> any SummaryProviderRunner
    func makeDiagnostics(context: SummaryProviderDiagnosticsContext) -> any SummaryProviderDiagnostics
    @MainActor func makeSettingsView(context: SummaryProviderSettingsViewContext) -> AnyView
    func metadata(from configuration: SummaryProviderConfiguration, settings: AppSettings) -> SummaryProviderMetadata
    func runtimeLogMessage(
        configuration: SummaryProviderConfiguration,
        workingDirectory: URL?,
        transcriptURL: URL?
    ) -> String?
}

extension SummaryProviderModule {
    func normalize(_ configuration: SummaryProviderConfiguration) -> SummaryProviderConfiguration {
        configuration
    }

    func runtimeLogMessage(
        configuration: SummaryProviderConfiguration,
        workingDirectory: URL?,
        transcriptURL: URL?
    ) -> String? {
        nil
    }
}

struct SummaryMessage: Codable {
    let role: String
    let content: String
}
