
import Foundation

extension DashboardViewModel {
    @discardableResult
    func checkForUpdates(userInitiated: Bool = true) -> Task<Void, Never>? {
        guard !isCheckingForUpdates else {
            return nil
        }

        isCheckingForUpdates = true

        return Task {
            do {
                let result = try await appUpdateService.checkForUpdate(languageSelection: languageSelection)

                await loggingService.log(
                    "Update check completed. current=\(result.currentVersion), latest=\(result.manifest.version), updateAvailable=\(result.isNewer)",
                    level: .info,
                    component: "Updates"
                )

                await MainActor.run {
                    isCheckingForUpdates = false
                    availableUpdate = result.isNewer ? result.manifest : nil
                }
                await updateNotificationService?.notifyUpdateCheck(result, userInitiated: userInitiated)

            } catch {
                await loggingService.log(
                    "Update check failed: \(error.localizedDescription)",
                    level: .warn,
                    component: "Updates"
                )
                await MainActor.run {
                    isCheckingForUpdates = false
                }
                if userInitiated {
                    await updateNotificationService?.notify(
                        category: .updateCheck, title: "AnyBrief",
                        body: String(format: String(localized: "Could not check for updates: %@"), error.localizedDescription))
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
