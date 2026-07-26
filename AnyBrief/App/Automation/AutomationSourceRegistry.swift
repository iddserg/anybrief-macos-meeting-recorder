import Foundation

struct AutomationSourceRegistry {
    let modules: [any AutomationSourceModule]

    static let `default` = AutomationSourceRegistry(modules: [
        CalDAVModule(),
        LocalHTTPAPIModule(),
        WindowObserverModule(),
    ])

    private let modulesByID: [AutomationSourceID: any AutomationSourceModule]

    init(modules: [any AutomationSourceModule]) {
        self.modules = modules
        modulesByID = Dictionary(uniqueKeysWithValues: modules.map { ($0.id, $0) })
    }

    func module(for source: AutomationSourceID) throws -> any AutomationSourceModule {
        guard let module = modulesByID[source] else {
            throw AutomationSourceError(message: "Missing automation source \(source.rawValue).")
        }
        return module
    }

    func defaultConfiguration(for source: AutomationSourceID) throws -> AutomationSourceConfiguration {
        try module(for: source).defaultConfiguration()
    }

    func normalize(_ configuration: AutomationSourceConfiguration) -> AutomationSourceConfiguration {
        (try? module(for: configuration.source).normalize(configuration)) ?? configuration
    }

    func replacing(_ module: any AutomationSourceModule) -> AutomationSourceRegistry {
        guard modules.contains(where: { $0.id == module.id }) else {
            return AutomationSourceRegistry(modules: modules + [module])
        }
        return AutomationSourceRegistry(modules: modules.map { $0.id == module.id ? module : $0 })
    }
}
