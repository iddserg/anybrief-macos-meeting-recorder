import Foundation

/// Fetches CalDAV calendar data for the CalDAV automation source.
final class CalDAVCalendarService {
    struct CalendarInfo: Identifiable, Equatable, Sendable {
        let id: String
        let displayName: String
        let href: String
    }

    typealias DataLoader = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    private static let sharedCoordinator = CalendarFetchCoordinator()

    private let dataLoader: DataLoader
    private let coordinator: CalendarFetchCoordinator

    init(
        dataLoader: @escaping DataLoader = { request in
            try await URLSession.shared.data(for: request)
        },
        coordinator: CalendarFetchCoordinator = CalDAVCalendarService.sharedCoordinator
    ) {
        self.dataLoader = dataLoader
        self.coordinator = coordinator
    }

    func fetchEvents(
        settings: AppSettings,
        password: String?,
        from startDate: Date,
        to endDate: Date
    ) async throws -> [CalendarEvent] {
        let urlString = settings.automation.calDAVSettings.config.url.trimmingCharacters(in: .whitespacesAndNewlines)
        let username = settings.automation.calDAVSettings.config.username.trimmingCharacters(in: .whitespacesAndNewlines)
        let calendarID = settings.automation.calDAVSettings.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !urlString.isEmpty,
              !username.isEmpty,
              let password,
              !password.isEmpty,
              Self.isExpandedCalendarURL(urlString) || !calendarID.isEmpty,
              let url = Self.calendarURL(
                  baseURLString: urlString,
                  username: username,
                  calendarID: calendarID
              ) else {
            throw CalendarSyncError.missingConfiguration
        }

        let cacheKey = CalendarFetchCoordinator.SourceKey(
            urlString: url.absoluteString,
            username: username,
            calendarName: settings.automation.calDAVSettings.name.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        let cacheTTL = Self.cacheTTL(for: settings)

        return try await coordinator.fetch(
            key: cacheKey,
            rangeStart: startDate,
            rangeEnd: endDate,
            ttl: cacheTTL
        ) { [dataLoader] in
            var request = URLRequest(url: url)
            request.httpMethod = "REPORT"
            request.timeoutInterval = 30
            request.setValue("1", forHTTPHeaderField: "Depth")
            request.setValue("application/xml; charset=utf-8", forHTTPHeaderField: "Content-Type")
            request.setValue("Basic \(Self.basicAuth(username: username, password: password))", forHTTPHeaderField: "Authorization")
            request.httpBody = Self.calendarQueryBody(from: startDate, to: endDate).data(using: .utf8)

            let (data, response) = try await dataLoader(request)
            guard let http = response as? HTTPURLResponse else {
                throw CalendarSyncError.invalidResponse
            }
            guard (200..<300).contains(http.statusCode) else {
                throw CalendarSyncError.requestFailed(http.statusCode)
            }

            return try CalDAVCalendarParser.parseEvents(
                from: data,
                fallbackCalendarName: settings.automation.calDAVSettings.name,
                rangeStart: startDate,
                rangeEnd: endDate
            )
        }
    }

    func discoverCalendars(
        baseURLString: String,
        username: String,
        password: String?
    ) async throws -> [CalendarInfo] {
        let username = username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !baseURLString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !username.isEmpty,
              let password,
              !password.isEmpty,
              let url = Self.calendarHomeURL(baseURLString: baseURLString, username: username) else {
            throw CalendarSyncError.missingConfiguration
        }

        var request = URLRequest(url: url)
        request.httpMethod = "PROPFIND"
        request.timeoutInterval = 30
        request.setValue("1", forHTTPHeaderField: "Depth")
        request.setValue("application/xml; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue("Basic \(Self.basicAuth(username: username, password: password))", forHTTPHeaderField: "Authorization")
        request.httpBody = Self.calendarDiscoveryBody.data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw CalendarSyncError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            throw CalendarSyncError.requestFailed(http.statusCode)
        }

        let calendars = try Self.parseCalendarList(from: data)
        if calendars.isEmpty {
            throw CalendarSyncError.noCalendarsFound
        }
        return calendars
    }

    func testConnection(
        baseURLString: String,
        username: String,
        password: String?,
        calendarID: String
    ) async throws -> Int {
        var settings = AppSettings.default
        settings.automation.calDAVSettings.config.url = baseURLString
        settings.automation.calDAVSettings.config.username = username
        settings.automation.calDAVSettings.name = calendarID
        let start = Date()
        let end = Calendar.current.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(24 * 3600)
        let events = try await fetchEvents(settings: settings, password: password, from: start, to: end)
        return events.count
    }

    static func calendarHomeURL(baseURLString: String, username: String) -> URL? {
        let trimmedBaseURLString = baseURLString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let baseURL = URL(string: trimmedBaseURLString),
              var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            return nil
        }

        let username = username.trimmingCharacters(in: .whitespacesAndNewlines)
        let encodedUsername = encodedPathComponent(username)
        var path = components.percentEncodedPath
        if let calendarsRange = path.range(of: "/calendars/") {
            let prefix = path[..<calendarsRange.upperBound]
            path = "\(prefix)\(encodedUsername)/"
        } else {
            if !path.hasSuffix("/") {
                path += "/"
            }
            path += "calendars/\(encodedUsername)/"
        }
        components.percentEncodedPath = path
        return components.url
    }

    static func calendarURL(baseURLString: String, username: String, calendarID: String) -> URL? {
        let trimmedBaseURLString = baseURLString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let baseURL = URL(string: trimmedBaseURLString) else {
            return nil
        }
        if isExpandedCalendarURL(trimmedBaseURLString) || calendarID.isEmpty {
            return baseURL
        }
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            return nil
        }

        let encodedUsername = encodedPathComponent(username)
        let encodedCalendarID = encodedPathComponent(calendarID)
        var path = components.percentEncodedPath
        if !path.hasSuffix("/") {
            path += "/"
        }
        path += "calendars/\(encodedUsername)/\(encodedCalendarID)/"
        components.percentEncodedPath = path
        return components.url
    }

    static func parseCalendarList(from data: Data) throws -> [CalendarInfo] {
        try CalDAVCalendarParser.parseCalendarList(from: data)
    }

    private static func cacheTTL(for settings: AppSettings) -> TimeInterval {
        if settings.automation.calendarAutopilotSettings.enabled {
            return min(
                TimeInterval(max(10, settings.automation.calendarAutopilotSettings.pollIntervalSec)),
                maxAutopilotBackgroundPollInterval
            )
        }
        return 60
    }

    private static func calendarQueryBody(from startDate: Date, to endDate: Date) -> String {
        """
        <?xml version="1.0" encoding="utf-8" ?>
        <c:calendar-query xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav">
          <d:prop>
            <c:calendar-data />
          </d:prop>
          <c:filter>
            <c:comp-filter name="VCALENDAR">
              <c:comp-filter name="VEVENT">
                <c:time-range start="\(icalUTC.string(from: startDate))" end="\(icalUTC.string(from: endDate))"/>
              </c:comp-filter>
            </c:comp-filter>
          </c:filter>
        </c:calendar-query>
        """
    }

    private static let calendarDiscoveryBody = """
        <?xml version="1.0" encoding="utf-8" ?>
        <d:propfind xmlns:d="DAV:" xmlns:cs="http://calendarserver.org/ns/" xmlns:c="urn:ietf:params:xml:ns:caldav">
          <d:prop>
            <d:displayname />
            <d:resourcetype />
            <cs:getctag />
            <c:supported-calendar-component-set />
          </d:prop>
        </d:propfind>
        """

    private static func isExpandedCalendarURL(_ value: String) -> Bool {
        URL(string: value.trimmingCharacters(in: .whitespacesAndNewlines))?.path.contains("/calendars/") == true
    }

    private static func encodedPathComponent(_ value: String) -> String {
        let allowedCharacters = CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))
        return value.addingPercentEncoding(withAllowedCharacters: allowedCharacters) ?? value
    }

    private static func basicAuth(username: String, password: String) -> String {
        Data("\(username):\(password)".utf8).base64EncodedString()
    }

    private static let icalUTC: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return formatter
    }()
}
