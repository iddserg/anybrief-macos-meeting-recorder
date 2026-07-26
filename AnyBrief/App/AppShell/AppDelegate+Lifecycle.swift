import AppKit
import Foundation

extension AppDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        guard !Self.isRunningUnderXCTest else {
            return
        }

        do {
            singleInstanceLock = try SingleInstanceLock.acquire()
        } catch SingleInstanceLock.LockError.alreadyRunning {
            requestRunningInstanceToOpenDashboard()
            NSApp.terminate(nil)
            return
        } catch {
            Task {
                await environment.loggingService.log(
                    "Failed to acquire app lock: \(error.localizedDescription)",
                    level: .error,
                    component: "App"
                )
            }
        }

        installReopenDashboardObserver()
        menuContext = MenuBarContext(appState: environment.appState, currentSession: nil)
        menuBarManager.install(context: menuContext, target: self)
        installSleepObserver()

        Task {
            await refreshPermissionAppState()

            do {
                try await environment.storageService.prepareStorage(using: environment.loggingService)
                let jobs = await environment.jobRepository.load()
                var settings = await environment.appSettingsStore.load(using: environment.loggingService)
                await ensureLocalAPIKey(in: &settings)
                await environment.loggingService.log(
                    "Loaded settings from ~/anybrief/config/settings.json (locale=\(settings.application.locale), localHTTPAPIEnabled=\(settings.automation.localHTTPAPISettings.enabled), localHTTPAPIPort=\(settings.automation.localHTTPAPISettings.port))",
                    level: .info,
                    component: "Settings"
                )
                await environment.loggingService.log(
                    "Launch executable: \(CommandLine.arguments.first ?? "unknown")",
                    level: .info,
                    component: "App"
                )
                let hideDockIcon = settings.application.hideDockIcon
                await MainActor.run {
                    DockIconController.apply(hideDockIcon: hideDockIcon)
                }
                do {
                    try launchAtLoginController.setEnabled(settings.application.launchAtLogin)
                } catch {
                    await environment.loggingService.log(
                        "Failed to apply launch-at-login setting: \(error.localizedDescription)",
                        level: .warn,
                        component: "Settings"
                    )
                }
                await environment.loggingService.log(
                    "Loaded \(jobs.count) job(s) from ~/anybrief/state/jobs.json",
                    level: .info,
                    component: "Storage"
                )
                await resolveBundledCLIPaths(using: environment.loggingService)
                await startupRecoveryService.recoverJobs()
                await localAPIService.start()
                await autopilotService.start()
                let screenStatus = await environment.permissionService.check(.screenRecording)
                await environment.loggingService.log(
                    "Screen Recording status: \(screenStatus)",
                    level: screenStatus == .granted ? .info : .warn,
                    component: "Permissions"
                )
                if screenStatus == .granted {
                    prewarmRecordingCapture()
                }

            } catch {
                await environment.loggingService.log(
                    "Failed to prepare storage: \(error.localizedDescription)",
                    level: .error,
                    component: "Storage"
                )
            }

            await environment.loggingService.log(
                "AnyBrief started, version \(applicationVersion)",
                level: .info,
                component: "App"
            )
        }
    }

    func prewarmRecordingCapture() {
        let loggingService = environment.loggingService
        Task.detached(priority: .utility) {
            let startedAt = Date()
            do {
                try await EmbeddedAudioRecorder.prewarmSystemAudioCapture()
                let elapsedMs = Int(Date().timeIntervalSince(startedAt) * 1000)
                await loggingService.log(
                    "Prewarmed ScreenCaptureKit display cache in \(elapsedMs)ms.",
                    level: .debug,
                    component: "Recording"
                )
            } catch {
                await loggingService.log(
                    "Failed to prewarm ScreenCaptureKit display cache: \(error.localizedDescription)",
                    level: .warn,
                    component: "Recording"
                )
            }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        Task { @MainActor in
            presentDashboard()
        }
        return true
    }

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        menuBarManager.makeMenu(for: menuContext, target: self)
    }

    var applicationVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
    }

    func ensureLocalAPIKey(in settings: inout AppSettings) async {
        if let ref = settings.automation.localHTTPAPISettings.apiKeyKeychainRef,
           environment.keychainStore.load(key: ref) != nil {
            return
        }

        let ref = UUID().uuidString.lowercased()
        let key = (0..<32).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()

        do {
            try environment.keychainStore.save(key: ref, value: key)
        } catch {
            await environment.loggingService.log(
                "Failed to save generated local API key to keychain: \(error.localizedDescription)",
                level: .error,
                component: "App"
            )
            return
        }

        settings.automation.localHTTPAPISettings.apiKeyKeychainRef = ref

        do {
            try await environment.appSettingsStore.save(settings)
            await environment.loggingService.log(
                "Generated local API key on first launch.",
                level: .info,
                component: "App"
            )
        } catch {
            environment.keychainStore.delete(key: ref)
            settings.automation.localHTTPAPISettings.apiKeyKeychainRef = nil
            await environment.loggingService.log(
                "Failed to persist generated local API key settings: \(error.localizedDescription)",
                level: .error,
                component: "App"
            )
        }
    }

    func resolveBundledCLIPaths(using loggingService: LoggingService) async {
        let tools: [(name: String, resolver: () throws -> URL)] = [
            ("stt",      CLIPathResolver.resolveStt),
            ("whisper-stt", CLIPathResolver.resolveWhisperSTT),
            ("whisper-cli-core", CLIPathResolver.resolveWhisperCore),
            ("ffmpeg",   CLIPathResolver.resolveFfmpeg),
        ]

        for tool in tools {
            do {
                let url = try tool.resolver()
                let isExecutable = FileManager.default.isExecutableFile(atPath: url.path)
                let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
                let size = attrs?[.size] as? Int ?? 0
                await loggingService.log(
                    "\(tool.name): \(url.path) [\(size / 1024)KB, executable=\(isExecutable)]",
                    level: isExecutable ? .info : .warn,
                    component: "CLIPathResolver"
                )
            } catch {
                await loggingService.log(
                    "\(tool.name): NOT FOUND — \(error.localizedDescription)",
                    level: .error,
                    component: "CLIPathResolver"
                )
            }
        }

        if let cliDir = ProcessInfo.processInfo.environment["ANYBRIEF_CLI_DIR"] {
            await loggingService.log(
                "CLI source: env ANYBRIEF_CLI_DIR=\(cliDir)",
                level: .info,
                component: "CLIPathResolver"
            )
        } else {
            await loggingService.log(
                "CLI source: app bundle Resources/bin",
                level: .info,
                component: "CLIPathResolver"
            )
        }
    }

    func installReopenDashboardObserver() {
        reopenDashboardObserver = DistributedNotificationCenter.default().addObserver(
            forName: Self.reopenDashboardNotification,
            object: Bundle.main.bundleIdentifier,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.presentDashboard()
            }
        }
    }

    func requestRunningInstanceToOpenDashboard() {
        DistributedNotificationCenter.default().postNotificationName(
            Self.reopenDashboardNotification,
            object: Bundle.main.bundleIdentifier,
            userInfo: nil,
            deliverImmediately: true
        )
    }

    static var isRunningUnderXCTest: Bool {
        let environment = ProcessInfo.processInfo.environment
        return environment["XCTestConfigurationFilePath"] != nil
            || environment["XCTestBundlePath"] != nil
    }

    func installSleepObserver() {
        workspaceSleepObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            Task {
                await self?.handleSystemWillSleep()
            }
        }
    }
}
