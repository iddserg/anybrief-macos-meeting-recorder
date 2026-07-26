import Foundation

protocol AppSettingsStoreProtocol {
    func load(using loggingService: LoggingService) async -> AppSettings
    func save(_ settings: AppSettings) async throws
}

final class AppSettingsStore: AppSettingsStoreProtocol {
    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let rootDirectoryURL: URL
    private let resetService: SettingsResetService

    init(fileManager: FileManager = .default, rootDirectoryURL: URL? = nil) {
        self.fileManager = fileManager
        self.rootDirectoryURL = rootDirectoryURL ?? fileManager.homeDirectoryForCurrentUser
        self.resetService = SettingsResetService(fileManager: fileManager)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        self.encoder = encoder

        self.decoder = JSONDecoder()
    }

    func load(using loggingService: LoggingService) async -> AppSettings {
        do {
            return try loadSynchronously()
        } catch {
            await loggingService.log(
                "Failed to load settings from \(settingsFileURL.path): \(error.localizedDescription). Using defaults.",
                level: .warn,
                component: "Settings"
            )
            return .default
        }
    }

    func save(_ settings: AppSettings) async throws {
        let data = try encoder.encode(settings)
        try fileManager.createDirectory(
            at: settingsFileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: settingsFileURL, options: .atomic)
        try resetService.writeGroupedSettingsMarker(for: settingsFileURL)
        try SettingsMigrationService.writeDiarizationThresholdMarker(
            for: settingsFileURL,
            fileManager: fileManager
        )
    }

    func loadSynchronously() throws -> AppSettings {
        guard fileManager.fileExists(atPath: settingsFileURL.path) else {
            return .default
        }

        let defaultSettingsData = try encoder.encode(AppSettings.default)
        let resetResult = try resetService.resetLegacyFlatSettingsIfNeeded(
            settingsFileURL: settingsFileURL,
            groupedMarkerURL: groupedMarkerURL,
            defaultSettingsData: defaultSettingsData
        )
        if resetResult.didReset {
            return .default
        }

        let data = try Data(contentsOf: settingsFileURL)
        var settings = try decoder.decode(AppSettings.self, from: data)
        if !fileManager.fileExists(atPath: diarizationThresholdMigrationMarkerURL.path) {
            let didMigrate = settings.migrateLegacyDiarizationThresholdIfNeeded()
            if didMigrate {
                try encoder.encode(settings).write(to: settingsFileURL, options: .atomic)
            }
            try SettingsMigrationService.writeDiarizationThresholdMarker(
                for: settingsFileURL,
                fileManager: fileManager
            )
        }
        return settings
    }

    private var settingsFileURL: URL {
        rootDirectoryURL
            .appendingPathComponent("anybrief", isDirectory: true)
            .appendingPathComponent("config", isDirectory: true)
            .appendingPathComponent("settings.json", isDirectory: false)
    }

    private var groupedMarkerURL: URL {
        settingsFileURL
            .deletingLastPathComponent()
            .appendingPathComponent(SettingsResetService.groupedMarkerFileName, isDirectory: false)
    }

    private var diarizationThresholdMigrationMarkerURL: URL {
        settingsFileURL
            .deletingLastPathComponent()
            .appendingPathComponent(
                SettingsMigrationService.diarizationThresholdMarkerFileName,
                isDirectory: false
            )
    }
}

enum SettingsMigrationService {
    static let diarizationThresholdMarkerFileName = "settings.diarization-threshold-v2"

    static func writeDiarizationThresholdMarker(
        for settingsFileURL: URL,
        fileManager: FileManager
    ) throws {
        let markerURL = settingsFileURL
            .deletingLastPathComponent()
            .appendingPathComponent(diarizationThresholdMarkerFileName, isDirectory: false)
        try fileManager.createDirectory(
            at: markerURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("0.35-to-0.65\n".utf8).write(to: markerURL, options: .atomic)
    }
}

struct SettingsResetService {
    static let groupedMarkerFileName = "settings.grouped-v1"

    struct Result {
        let didReset: Bool
        let legacyFileURL: URL?
    }

    private let fileManager: FileManager
    private let timestampProvider: () -> Date

    init(fileManager: FileManager = .default, timestampProvider: @escaping () -> Date = Date.init) {
        self.fileManager = fileManager
        self.timestampProvider = timestampProvider
    }

    func resetLegacyFlatSettingsIfNeeded(
        settingsFileURL: URL,
        groupedMarkerURL: URL,
        defaultSettingsData: Data
    ) throws -> Result {
        guard fileManager.fileExists(atPath: settingsFileURL.path) else {
            return Result(didReset: false, legacyFileURL: nil)
        }
        guard !fileManager.fileExists(atPath: groupedMarkerURL.path) else {
            return Result(didReset: false, legacyFileURL: nil)
        }

        let legacyURL = availableLegacySettingsURL(for: settingsFileURL)
        try fileManager.moveItem(at: settingsFileURL, to: legacyURL)
        try fileManager.createDirectory(
            at: settingsFileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try defaultSettingsData.write(to: settingsFileURL, options: .atomic)
        try writeGroupedSettingsMarker(for: settingsFileURL)
        return Result(didReset: true, legacyFileURL: legacyURL)
    }

    func writeGroupedSettingsMarker(for settingsFileURL: URL) throws {
        let markerURL = settingsFileURL
            .deletingLastPathComponent()
            .appendingPathComponent(Self.groupedMarkerFileName, isDirectory: false)
        try fileManager.createDirectory(
            at: markerURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("grouped-v1\n".utf8).write(to: markerURL, options: .atomic)
    }

    private func availableLegacySettingsURL(for settingsFileURL: URL) -> URL {
        let directoryURL = settingsFileURL.deletingLastPathComponent()
        let timestamp = Self.timestampFormatter.string(from: timestampProvider())
        let baseName = "settings.legacy-\(timestamp)"
        var candidateURL = directoryURL.appendingPathComponent("\(baseName).json", isDirectory: false)
        var suffix = 2

        while fileManager.fileExists(atPath: candidateURL.path) {
            candidateURL = directoryURL.appendingPathComponent("\(baseName)-\(suffix).json", isDirectory: false)
            suffix += 1
        }

        return candidateURL
    }

    private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter
    }()
}
