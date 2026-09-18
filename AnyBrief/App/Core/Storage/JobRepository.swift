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

struct CallStatisticsDay: Identifiable, Equatable, Sendable {
    let date: Date
    let callCount: Int
    let duration: TimeInterval

    var id: Date { date }
}

/// Durable recording-usage history kept independently from jobs and meeting files.
actor CallStatisticsService {
    private struct Record: Codable {
        let jobID: String
        let startedAt: Date
        let duration: TimeInterval
    }

    private struct State: Codable {
        let version: Int
        let records: [Record]

        init(records: [Record]) {
            version = 1
            self.records = records
        }
    }

    private let fileManager: FileManager
    private let fileURL: URL
    private let retentionDays: Int
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(
        fileManager: FileManager = .default,
        fileURL: URL? = nil,
        retentionDays: Int = 400
    ) {
        self.fileManager = fileManager
        self.fileURL = fileURL ?? fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("anybrief", isDirectory: true)
            .appendingPathComponent("state", isDirectory: true)
            .appendingPathComponent("call-statistics.json", isDirectory: false)
        self.retentionDays = max(365, retentionDays)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        self.encoder = encoder

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
    }

    func recordCall(jobID: String, startedAt: Date, duration: TimeInterval) throws {
        guard duration.isFinite, duration > 0 else { return }
        var records = (try? loadRecords()) ?? []
        records.removeAll { $0.jobID == jobID }
        records.append(Record(jobID: jobID, startedAt: startedAt, duration: duration))
        try persist(trim(records, now: Date()))
    }

    func dailyStatistics(days: Int = 365, now: Date = Date()) -> [CallStatisticsDay] {
        let requestedDays = max(1, days)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let today = calendar.startOfDay(for: now)
        guard let firstDay = calendar.date(byAdding: .day, value: -(requestedDays - 1), to: today) else {
            return []
        }

        let records = (try? loadRecords()) ?? []
        let grouped = Dictionary(grouping: records.filter { $0.startedAt >= firstDay && $0.startedAt < now.addingTimeInterval(86_400) }) {
            calendar.startOfDay(for: $0.startedAt)
        }

        return (0..<requestedDays).compactMap { offset in
            guard let date = calendar.date(byAdding: .day, value: offset, to: firstDay) else { return nil }
            let dayRecords = grouped[date] ?? []
            return CallStatisticsDay(
                date: date,
                callCount: dayRecords.count,
                duration: dayRecords.reduce(0) { $0 + $1.duration }
            )
        }
    }

    private func loadRecords() throws -> [Record] {
        guard fileManager.fileExists(atPath: fileURL.path) else { return [] }
        return try decoder.decode(State.self, from: Data(contentsOf: fileURL)).records
    }

    private func persist(_ records: [Record]) throws {
        try fileManager.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(State(records: records)).write(to: fileURL, options: .atomic)
    }

    private func trim(_ records: [Record], now: Date) -> [Record] {
        let cutoff = now.addingTimeInterval(-TimeInterval(retentionDays) * 86_400)
        return records.filter { $0.startedAt >= cutoff }
    }
}
