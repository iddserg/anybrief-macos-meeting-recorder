import Foundation

/// Checks AnyBrief update manifests outside the Dashboard UI.
struct AppUpdateManifest: Codable, Sendable {
    let version: String
    let build: String?
    let downloadURL: URL
    let releaseNotesURL: URL?
}

struct AppUpdateCheckResult: Sendable {
    let currentVersion: String
    let manifest: AppUpdateManifest
    let isNewer: Bool
}

struct AppUpdateService: Sendable {
    func checkForUpdate(languageSelection: String) async throws -> AppUpdateCheckResult {
        let currentVersion = Self.currentAppVersion
        let manifestURL = Self.updateManifestURL(languageSelection: languageSelection)
        let (data, response) = try await URLSession.shared.data(from: manifestURL)
        if let httpResponse = response as? HTTPURLResponse,
           !(200..<300).contains(httpResponse.statusCode) {
            throw URLError(.badServerResponse)
        }

        let manifest = try JSONDecoder().decode(AppUpdateManifest.self, from: data)
        return AppUpdateCheckResult(
            currentVersion: currentVersion,
            manifest: manifest,
            isNewer: Self.compareVersion(manifest.version, to: currentVersion) == .orderedDescending
        )
    }

    private static var currentAppVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    }

    private static func updateManifestURL(languageSelection: String) -> URL {
        let isRussian: Bool
        switch languageSelection {
        case "ru":
            isRussian = true
        case "en":
            isRussian = false
        default:
            isRussian = Locale.preferredLanguages.first?.hasPrefix("ru") == true
        }

        return URL(string: isRussian
            ? "https://anybrief.ru/version.json"
            : "https://anybrief.pro/version.json"
        )!
    }

    private static func compareVersion(_ left: String, to right: String) -> ComparisonResult {
        let leftParts = numericVersionParts(left)
        let rightParts = numericVersionParts(right)
        let count = max(leftParts.count, rightParts.count)

        for index in 0..<count {
            let leftValue = index < leftParts.count ? leftParts[index] : 0
            let rightValue = index < rightParts.count ? rightParts[index] : 0
            if leftValue > rightValue {
                return .orderedDescending
            }
            if leftValue < rightValue {
                return .orderedAscending
            }
        }

        return .orderedSame
    }

    private static func numericVersionParts(_ version: String) -> [Int] {
        version
            .split(separator: ".")
            .map { part in
                let digits = part.prefix { $0.isNumber }
                return Int(digits) ?? 0
            }
    }
}
