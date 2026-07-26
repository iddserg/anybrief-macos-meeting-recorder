import XCTest
@testable import AnyBrief

final class AutomationSourceRegistryTests: XCTestCase {
    func testDefaultRegistryContainsCalDAVModule() throws {
        let registry = AutomationSourceRegistry.default

        let module = try registry.module(for: .calDAV)

        XCTAssertEqual(module.id, .calDAV)
        XCTAssertEqual(module.title, "CalDAV")
        XCTAssertEqual(module.defaultConfiguration().source, .calDAV)
    }

    func testDefaultRegistryContainsWindowObserverModule() throws {
        let registry = AutomationSourceRegistry.default

        let module = try registry.module(for: .windowObserver)

        XCTAssertEqual(module.id, .windowObserver)
        XCTAssertEqual(module.title, "Window Observer")
        XCTAssertEqual(module.defaultConfiguration().source, .windowObserver)
        XCTAssertTrue(module.hasSettingsView)
    }

    func testDefaultRegistryContainsLocalHTTPAPIModule() throws {
        let registry = AutomationSourceRegistry.default

        let module = try registry.module(for: .localHTTPAPI)

        XCTAssertEqual(module.id, .localHTTPAPI)
        XCTAssertEqual(module.title, "Local HTTP API")
        XCTAssertEqual(module.defaultConfiguration().source, .localHTTPAPI)
        XCTAssertFalse(module.hasSettingsView)
    }

    func testNormalizeFallsBackToConfigurationForKnownModule() {
        let configuration = AutomationSourceConfiguration(source: .calDAV, enabled: false)

        let normalized = AutomationSourceRegistry.default.normalize(configuration)

        XCTAssertEqual(normalized, configuration)
    }

    func testDefaultRegistryBuildsCalDAVSourceThroughRuntimeContext() throws {
        let module = try AutomationSourceRegistry.default.module(for: .calDAV)
        let context = AutomationRuntimeContext(
            appSettingsStore: RegistryTestAppSettingsStore(),
            keychainStore: RegistryTestSecretStore(),
            loggingService: LoggingService(
                logsDirectoryURL: FileManager.default.temporaryDirectory
                    .appendingPathComponent(UUID().uuidString, isDirectory: true)
            ),
            currentSessionProvider: { nil },
            sleep: { _ in }
        )

        let source = module.makeSource(context: context)

        XCTAssertEqual(source.id, .calDAV)
        XCTAssertTrue(source is CalDAVAutomationSource)
    }

    func testDefaultRegistryBuildsWindowObserverSourceThroughRuntimeContext() throws {
        let module = try AutomationSourceRegistry.default.module(for: .windowObserver)
        let context = AutomationRuntimeContext(
            appSettingsStore: RegistryTestAppSettingsStore(),
            keychainStore: RegistryTestSecretStore(),
            loggingService: LoggingService(
                logsDirectoryURL: FileManager.default.temporaryDirectory
                    .appendingPathComponent(UUID().uuidString, isDirectory: true)
            ),
            currentSessionProvider: { nil },
            sleep: { _ in }
        )

        let source = module.makeSource(context: context)

        XCTAssertEqual(source.id, .windowObserver)
        XCTAssertTrue(source is WindowObserverSource)
    }

    func testDefaultRegistryBuildsLocalHTTPAPISourceThroughRuntimeContext() throws {
        let module = try AutomationSourceRegistry.default.module(for: .localHTTPAPI)
        let context = AutomationRuntimeContext(
            appSettingsStore: RegistryTestAppSettingsStore(),
            keychainStore: RegistryTestSecretStore(),
            loggingService: LoggingService(
                logsDirectoryURL: FileManager.default.temporaryDirectory
                    .appendingPathComponent(UUID().uuidString, isDirectory: true)
            ),
            currentSessionProvider: { nil },
            sleep: { _ in }
        )

        let source = module.makeSource(context: context)

        XCTAssertEqual(source.id, .localHTTPAPI)
        XCTAssertTrue(source is LocalHTTPAPISource)
    }

    func testAutopilotServiceBuildsRuntimeSourcesFromRegistryModules() {
        let context = AutomationRuntimeContext(
            appSettingsStore: RegistryTestAppSettingsStore(),
            keychainStore: RegistryTestSecretStore(),
            loggingService: LoggingService(
                logsDirectoryURL: FileManager.default.temporaryDirectory
                    .appendingPathComponent(UUID().uuidString, isDirectory: true)
            ),
            currentSessionProvider: { nil },
            sleep: { _ in }
        )
        let registry = AutomationSourceRegistry(modules: [
            CalDAVModule(),
            RegistryIterationModule(),
        ])

        let sources = AutopilotService.makeSources(
            registry: registry,
            context: context
        )

        XCTAssertEqual(sources.map { $0.id }, [.calDAV, .windowObserver])
        XCTAssertTrue(sources[0] is CalDAVAutomationSource)
        XCTAssertTrue(sources[1] is RegistryIterationSource)
    }
}

private final class RegistryTestAppSettingsStore: AppSettingsStoreProtocol {
    func load(using loggingService: LoggingService) async -> AppSettings {
        .default
    }

    func save(_ settings: AppSettings) async throws {}
}

private final class RegistryTestSecretStore: SecretStoreProtocol {
    func save(key: String, value: String) throws {}

    func load(key: String) -> String? {
        nil
    }

    func delete(key: String) {}
}

private struct RegistryIterationModule: AutomationSourceModule {
    let id: AutomationSourceID = .windowObserver
    let title = "Registry Iteration"
    let systemImage = "puzzlepiece"

    func defaultConfiguration() -> AutomationSourceConfiguration {
        AutomationSourceConfiguration(source: id)
    }

    func makeSource(context: AutomationRuntimeContext) -> any AutomationSource {
        RegistryIterationSource()
    }

    func makeDiagnostics(context: AutomationDiagnosticsContext) -> any AutomationDiagnostics {
        RegistryIterationDiagnostics()
    }
}

private final class RegistryIterationSource: AutomationSource {
    let id: AutomationSourceID = .windowObserver
    let events = AsyncStream<AutomationEvent> { continuation in
        continuation.finish()
    }

    func start() async {}

    func stop() async {}
}

private struct RegistryIterationDiagnostics: AutomationDiagnostics {
    func diagnose(configuration: AutomationSourceConfiguration, settings: AppSettings) async -> AutomationDiagnosticResult {
        AutomationDiagnosticResult(status: .success, message: "ok")
    }
}
