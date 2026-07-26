
import Foundation

extension DashboardViewModel {
    func checkForUpdates(userInitiated: Bool = true) {
        guard !isCheckingForUpdates else {
            return
        }

        isCheckingForUpdates = true
        if userInitiated {
            updateCheckMessage = String(localized: "Checking for updates...")
            updateCheckMessageIsError = false
        }

        Task {
            do {
                let result = try await appUpdateService.checkForUpdate(languageSelection: languageSelection)

                await loggingService.log(
                    "Update check completed. current=\(result.currentVersion), latest=\(result.manifest.version), updateAvailable=\(result.isNewer)",
                    level: .info,
                    component: "Updates"
                )

                await MainActor.run {
                    isCheckingForUpdates = false
                    if result.isNewer {
                        availableUpdate = result.manifest
                        updateCheckMessage = String(
                            format: String(localized: "A new version is available: %@."),
                            result.manifest.version
                        )
                        updateCheckMessageIsError = false
                    } else {
                        availableUpdate = nil
                        if userInitiated {
                            updateCheckMessage = String(localized: "You are using the latest version.")
                            updateCheckMessageIsError = false
                        }
                    }
                }
            } catch {
                await loggingService.log(
                    "Update check failed: \(error.localizedDescription)",
                    level: .warn,
                    component: "Updates"
                )
                await MainActor.run {
                    isCheckingForUpdates = false
                    if userInitiated {
                        updateCheckMessage = String(
                            format: String(localized: "Could not check for updates: %@"),
                            error.localizedDescription
                        )
                        updateCheckMessageIsError = true
                    }
                }
            }
        }
    }

    func openAvailableUpdateDownload() {
        guard let downloadURL = availableUpdate?.downloadURL else {
            return
        }
        workspace.open(downloadURL)
    }

}
