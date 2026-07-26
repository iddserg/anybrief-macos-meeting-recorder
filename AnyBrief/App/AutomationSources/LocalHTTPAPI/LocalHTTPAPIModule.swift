import Foundation

struct LocalHTTPAPIModule: AutomationSourceModule {
    let id: AutomationSourceID = .localHTTPAPI
    let title = "Local HTTP API"
    let systemImage = "network"

    func defaultConfiguration() -> AutomationSourceConfiguration {
        AutomationSourceConfiguration(source: id)
    }

    func makeSource(context: AutomationRuntimeContext) -> any AutomationSource {
        LocalHTTPAPISource()
    }

    func makeDiagnostics(context: AutomationDiagnosticsContext) -> any AutomationDiagnostics {
        LocalHTTPAPIDiagnostics(keychainStore: context.keychainStore)
    }
}

final class LocalHTTPAPISource: AutomationSource {
    let id: AutomationSourceID = .localHTTPAPI
    let events = AsyncStream<AutomationEvent> { continuation in
        continuation.finish()
    }

    func start() async {}

    func stop() async {}
}
