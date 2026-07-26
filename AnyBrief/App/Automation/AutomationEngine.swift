import Foundation

/// Listens to automation sources and dispatches resolved actions.
actor AutomationEngine {
    typealias ActionResolver = @Sendable (AutomationEvent) async -> [AutomationAction]
    typealias ActionHandler = @Sendable (AutomationAction) async -> Void

    private let sources: [any AutomationSource]
    private let resolveActions: ActionResolver
    private let handleAction: ActionHandler
    private var tasks: [Task<Void, Never>] = []

    init(
        sources: [any AutomationSource],
        resolveActions: @escaping ActionResolver,
        handleAction: @escaping ActionHandler
    ) {
        self.sources = sources
        self.resolveActions = resolveActions
        self.handleAction = handleAction
    }

    func start() async {
        guard tasks.isEmpty else {
            return
        }

        for source in sources {
            await source.start()
            let stream = source.events
            tasks.append(Task { [resolveActions, handleAction] in
                for await event in stream {
                    let actions = await resolveActions(event)
                    for action in actions {
                        await handleAction(action)
                    }
                }
            })
        }
    }

    func stop() async {
        tasks.forEach { $0.cancel() }
        tasks = []
        for source in sources {
            await source.stop()
        }
    }
}
