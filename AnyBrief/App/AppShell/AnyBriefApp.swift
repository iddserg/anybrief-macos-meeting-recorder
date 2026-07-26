import SwiftUI

@main
struct AnyBriefApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    private let environment = AppEnvironment.shared

    var body: some Scene {
        Settings {
            EmptyView()
                .onAppear {
                    _ = environment
                }
        }
    }
}
