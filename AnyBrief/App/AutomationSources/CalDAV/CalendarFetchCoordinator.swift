import Foundation

/// Shares recent calendar fetch results across autopilot, dashboard, and local API.
actor CalendarFetchCoordinator {
    struct SourceKey: Hashable, Sendable {
        let urlString: String
        let username: String
        let calendarName: String
    }

    struct CachedSuccess: Sendable {
        let fetchedAt: Date
        let rangeStart: Date
        let rangeEnd: Date
        let events: [CalendarEvent]
    }

    struct CachedFailure: Sendable {
        let failedAt: Date
        let message: String
    }

    struct InFlightRequest: Sendable {
        let id: UUID
        let rangeStart: Date
        let rangeEnd: Date
        let task: Task<CachedSuccess, Error>
    }

    private var successes: [SourceKey: CachedSuccess] = [:]
    private var failures: [SourceKey: CachedFailure] = [:]
    private var inFlight: [SourceKey: [InFlightRequest]] = [:]

    func fetch(
        key: SourceKey,
        rangeStart: Date,
        rangeEnd: Date,
        ttl: TimeInterval,
        load: @escaping @Sendable () async throws -> [CalendarEvent]
    ) async throws -> [CalendarEvent] {
        let now = Date()
        if let success = successes[key],
           now.timeIntervalSince(success.fetchedAt) < ttl,
           success.rangeStart <= rangeStart,
           success.rangeEnd >= rangeEnd {
            return filter(success.events, rangeStart: rangeStart, rangeEnd: rangeEnd)
        }

        if let failure = failures[key],
           now.timeIntervalSince(failure.failedAt) < ttl {
            throw SuppressedCalendarFetchError(message: failure.message)
        }

        if let request = inFlight[key]?.first(where: { $0.rangeStart <= rangeStart && $0.rangeEnd >= rangeEnd }) {
            let success = try await request.task.value
            return filter(success.events, rangeStart: rangeStart, rangeEnd: rangeEnd)
        }

        let requestID = UUID()
        let task = Task {
            let events = try await load()
            return CachedSuccess(
                fetchedAt: Date(),
                rangeStart: rangeStart,
                rangeEnd: rangeEnd,
                events: events
            )
        }
        inFlight[key, default: []].append(
            InFlightRequest(
                id: requestID,
                rangeStart: rangeStart,
                rangeEnd: rangeEnd,
                task: task
            )
        )

        do {
            let success = try await task.value
            successes[key] = success
            failures[key] = nil
            removeInFlightRequest(key: key, requestID: requestID)
            return filter(success.events, rangeStart: rangeStart, rangeEnd: rangeEnd)
        } catch {
            failures[key] = CachedFailure(failedAt: Date(), message: error.localizedDescription)
            removeInFlightRequest(key: key, requestID: requestID)
            throw error
        }
    }

    private func removeInFlightRequest(key: SourceKey, requestID: UUID) {
        guard var requests = inFlight[key] else {
            return
        }
        requests.removeAll { $0.id == requestID }
        inFlight[key] = requests.isEmpty ? nil : requests
    }

    private func filter(_ events: [CalendarEvent], rangeStart: Date, rangeEnd: Date) -> [CalendarEvent] {
        events.filter { $0.endAt > rangeStart && $0.startAt < rangeEnd }
    }
}
