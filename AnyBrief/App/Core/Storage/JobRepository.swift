import Foundation

/// Abstraction for persisted job state access.
protocol JobRepositoryProtocol {
    func load() async -> [Job]
    func save(_ jobs: [Job]) async
    func upsert(_ job: Job) async
    func get(id: String) async -> Job?
}

/// Atomic JSON-backed repository for `~/anybrief/state/jobs.json`.
actor JobRepository: JobRepositoryProtocol {
    private let fileManager: FileManager
    private let loggingService: LoggingService
    private let historyLimit: Int
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(
        fileManager: FileManager = .default,
        loggingService: LoggingService,
        historyLimit: Int = 500
    ) {
        self.fileManager = fileManager
        self.loggingService = loggingService
        self.historyLimit = historyLimit

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        self.encoder = encoder

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
    }

    func load() async -> [Job] {
        guard fileManager.fileExists(atPath: jobsFileURL.path) else {
            do {
                try persist([])
            } catch {
                await loggingService.log(
                    "Failed to create jobs state at \(jobsFileURL.path): \(error.localizedDescription)",
                    level: .error,
                    component: "Storage"
                )
            }
            return []
        }

        do {
            let data = try Data(contentsOf: jobsFileURL)
            let state = try decoder.decode(JobState.self, from: data)
            return trim(state.jobs)
        } catch {
            do {
                let corruptURL = try moveCorruptedFile()
                await loggingService.log(
                    "Corrupted jobs state moved to \(corruptURL.lastPathComponent). Resetting jobs state.",
                    level: .warn,
                    component: "Storage"
                )
                try persist([])
            } catch {
                await loggingService.log(
                    "Failed to recover jobs state at \(jobsFileURL.path): \(error.localizedDescription)",
                    level: .error,
                    component: "Storage"
                )
            }
            return []
        }
    }

    func save(_ jobs: [Job]) async {
        do {
            try persist(jobs)
        } catch {
            await loggingService.log(
                "Failed to save jobs state to \(jobsFileURL.path): \(error.localizedDescription)",
                level: .error,
                component: "Storage"
            )
        }
    }

    func upsert(_ job: Job) async {
        var jobs = await load()

        if let existingIndex = jobs.firstIndex(where: { $0.id == job.id }) {
            jobs[existingIndex] = job
        } else {
            jobs.append(job)
        }

        await save(jobs)
    }

    func get(id: String) async -> Job? {
        await load().first(where: { $0.id == id })
    }

    private func persist(_ jobs: [Job]) throws {
        let trimmedJobs = trim(jobs)
        let state = JobState(updatedAt: Date(), jobs: trimmedJobs)
        let data = try encoder.encode(state)
        let temporaryURL = jobsFileURL.appendingPathExtension("tmp")

        if fileManager.fileExists(atPath: temporaryURL.path) {
            try fileManager.removeItem(at: temporaryURL)
        }

        try data.write(to: temporaryURL, options: [])

        if fileManager.fileExists(atPath: jobsFileURL.path) {
            _ = try fileManager.replaceItemAt(jobsFileURL, withItemAt: temporaryURL)
        } else {
            try fileManager.moveItem(at: temporaryURL, to: jobsFileURL)
        }
    }

    private func moveCorruptedFile() throws -> URL {
        let corruptURL = jobsFileURL.deletingLastPathComponent().appendingPathComponent(
            "jobs.json.corrupt-\(Self.corruptTimestampFormatter.string(from: Date()))",
            isDirectory: false
        )

        if fileManager.fileExists(atPath: corruptURL.path) {
            try fileManager.removeItem(at: corruptURL)
        }

        try fileManager.moveItem(at: jobsFileURL, to: corruptURL)
        return corruptURL
    }

    private func trim(_ jobs: [Job]) -> [Job] {
        Array(
            jobs
                .sorted {
                    if $0.updatedAt != $1.updatedAt {
                        return $0.updatedAt > $1.updatedAt
                    }
                    if $0.createdAt != $1.createdAt {
                        return $0.createdAt > $1.createdAt
                    }
                    return $0.id > $1.id
                }
                .prefix(historyLimit)
        )
    }

    private var jobsFileURL: URL {
        fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("anybrief", isDirectory: true)
            .appendingPathComponent("state", isDirectory: true)
            .appendingPathComponent("jobs.json", isDirectory: false)
    }

    private static let corruptTimestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter
    }()
}

private struct JobState: Codable {
    let version: Int
    let updatedAt: Date
    let jobs: [Job]

    init(updatedAt: Date, jobs: [Job]) {
        self.version = 1
        self.updatedAt = updatedAt
        self.jobs = jobs
    }
}
