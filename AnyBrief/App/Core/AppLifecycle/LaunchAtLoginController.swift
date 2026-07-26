import Foundation
import ServiceManagement

protocol LaunchAtLoginControlling {
    func setEnabled(_ enabled: Bool) throws
}

protocol LaunchAtLoginServiceProtocol {
    var status: LaunchAtLoginServiceStatus { get }
    func register() throws
    func unregister() throws
}

enum LaunchAtLoginServiceStatus {
    case enabled
    case requiresApproval
    case notRegistered
    case notFound
}

/// Launch-at-login integration backed by `SMAppService.mainApp`.
/// - https://developer.apple.com/documentation/servicemanagement/smappservice/mainapp
final class LaunchAtLoginController: LaunchAtLoginControlling {
    private let service: LaunchAtLoginServiceProtocol

    init(service: LaunchAtLoginServiceProtocol = MainAppLaunchAtLoginService()) {
        self.service = service
    }

    func setEnabled(_ enabled: Bool) throws {
        switch (enabled, service.status) {
        case (true, .enabled), (true, .requiresApproval):
            return
        case (false, .notRegistered), (false, .notFound):
            return
        case (true, _):
            try service.register()
        case (false, _):
            try service.unregister()
        }
    }
}

private struct MainAppLaunchAtLoginService: LaunchAtLoginServiceProtocol {
    var status: LaunchAtLoginServiceStatus {
        switch SMAppService.mainApp.status {
        case .enabled:
            return .enabled
        case .requiresApproval:
            return .requiresApproval
        case .notRegistered:
            return .notRegistered
        case .notFound:
            return .notFound
        @unknown default:
            return .notFound
        }
    }

    func register() throws {
        try SMAppService.mainApp.register()
    }

    func unregister() throws {
        try SMAppService.mainApp.unregister()
    }
}
