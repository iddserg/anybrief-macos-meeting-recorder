import Foundation

/// Parses CalDAV XML and iCalendar payloads into calendar automation models.
enum CalDAVCalendarParser {
    static func parseEvents(
        from data: Data,
        fallbackCalendarName: String,
        rangeStart: Date,
        rangeEnd: Date
    ) throws -> [CalendarEvent] {
        let parser = XMLParser(data: data)
        let delegate = CalendarDataParserDelegate()
        parser.delegate = delegate
        guard parser.parse() else {
            throw CalendarSyncError.invalidResponse
        }

        return delegate.calendarData
            .flatMap {
                events(
                    from: $0,
                    fallbackCalendarName: fallbackCalendarName,
                    rangeStart: rangeStart,
                    rangeEnd: rangeEnd
                )
            }
            .sorted { $0.startAt < $1.startAt }
    }

    static func parseCalendarList(from data: Data) throws -> [CalDAVCalendarService.CalendarInfo] {
        let parser = XMLParser(data: data)
        let delegate = CalendarListParserDelegate()
        parser.delegate = delegate
        guard parser.parse() else {
            throw CalendarSyncError.invalidResponse
        }
        return delegate.calendars
    }

    private final class CalendarDataParserDelegate: NSObject, XMLParserDelegate {
        private(set) var calendarData: [String] = []
        private var currentText = ""

        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
            currentText = ""
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            currentText += string
        }

        func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
            currentText += String(data: CDATABlock, encoding: .utf8) ?? ""
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
            if elementName.lowercased().hasSuffix("calendar-data") {
                calendarData.append(currentText)
            }
            currentText = ""
        }
    }

    private final class CalendarListParserDelegate: NSObject, XMLParserDelegate {
        private(set) var calendars: [CalDAVCalendarService.CalendarInfo] = []
        private var currentText = ""
        private var responseHref = ""
        private var displayName = ""
        private var isCalendarResource = false
        private var elementStack: [String] = []

        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
            let name = Self.normalized(elementName)
            elementStack.append(name)
            currentText = ""
            if name == "response" {
                responseHref = ""
                displayName = ""
                isCalendarResource = false
            } else if name == "calendar", elementStack.contains("resourcetype") {
                isCalendarResource = true
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            currentText += string
        }

        func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
            currentText += String(data: CDATABlock, encoding: .utf8) ?? ""
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
            let name = Self.normalized(elementName)
            let text = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
            if name == "href", responseHref.isEmpty {
                responseHref = text
            } else if name == "displayname" {
                displayName = text
            } else if name == "response" {
                appendCalendarIfNeeded()
            }
            if !elementStack.isEmpty {
                elementStack.removeLast()
            }
            currentText = ""
        }

        private func appendCalendarIfNeeded() {
            guard isCalendarResource else {
                return
            }
            let id = Self.calendarID(from: responseHref)
            guard !id.isEmpty else {
                return
            }
            let name = displayName.isEmpty ? id : displayName
            if !calendars.contains(where: { $0.id == id }) {
                calendars.append(CalDAVCalendarService.CalendarInfo(id: id, displayName: name, href: responseHref))
            }
        }

        private static func normalized(_ value: String) -> String {
            value.split(separator: ":").last.map(String.init)?.lowercased() ?? value.lowercased()
        }

        private static func calendarID(from href: String) -> String {
            let trimmed = href.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard let last = trimmed.split(separator: "/").last else {
                return ""
            }
            return String(last).removingPercentEncoding ?? String(last)
        }
    }

    private struct ParsedICSEvent {
        let uid: String
        let calendarName: String
        let title: String
        let startAt: Date
        let endAt: Date
        let timeZone: TimeZone
        let location: String?
        let notes: String?
        let organizer: CalendarParticipant?
        let attendees: [CalendarParticipant]
        let meetingURLs: [String]
        let participantCount: Int
        let hasMeetingURL: Bool
        let recurrenceRule: String?
        let recurrenceID: Date?
        let excludedDates: Set<DateOnly>
    }

    private struct DateOnly: Hashable, Comparable {
        let year: Int
        let month: Int
        let day: Int

        static func < (lhs: DateOnly, rhs: DateOnly) -> Bool {
            if lhs.year != rhs.year { return lhs.year < rhs.year }
            if lhs.month != rhs.month { return lhs.month < rhs.month }
            return lhs.day < rhs.day
        }
    }

    private static func events(
        from ics: String,
        fallbackCalendarName: String,
        rangeStart: Date,
        rangeEnd: Date
    ) -> [CalendarEvent] {
        let parsedEvents = ics.components(separatedBy: "BEGIN:VEVENT").dropFirst().compactMap { rawEvent -> ParsedICSEvent? in
            let eventText = rawEvent.components(separatedBy: "END:VEVENT").first ?? rawEvent
            let lines = unfoldICSLines(eventText)
            let values = Dictionary(grouping: lines, by: { propertyName($0) })
            guard let startLine = values["DTSTART"]?.first,
                  let start = icalDate(from: startLine) else {
                return nil
            }
            let end = values["DTEND"]?.first.flatMap(icalDate(from:)) ?? start.addingTimeInterval(3600)

            let uid = propertyValue(values["UID"]?.first) ?? UUID().uuidString.lowercased()
            let title = propertyValue(values["SUMMARY"]?.first)?.trimmingCharacters(in: .whitespacesAndNewlines)
                ?? fallbackCalendarName.trimmingCharacters(in: .whitespacesAndNewlines)
            let resolvedTitle = title.isEmpty ? "Calendar meeting" : title
            let attendees = participants(from: values["ATTENDEE"] ?? [])
            let organizer = values["ORGANIZER"]?.first.map(participant(from:))
            let participantCount = participantCount(attendees: attendees, organizer: organizer)
            let searchable = lines.joined(separator: "\n").lowercased()
            let meetingURLs = meetingURLs(from: lines)
            let hasMeetingURL = !meetingURLs.isEmpty ||
                searchable.contains("zoom.us/") ||
                searchable.contains("meet.google.com/") ||
                searchable.contains("teams.microsoft.com/") ||
                searchable.contains("webex.com/") ||
                searchable.contains("http://") ||
                searchable.contains("https://")

            return ParsedICSEvent(
                uid: uid,
                calendarName: fallbackCalendarName.trimmingCharacters(in: .whitespacesAndNewlines),
                title: resolvedTitle,
                startAt: start,
                endAt: max(end, start.addingTimeInterval(60)),
                timeZone: timeZone(from: startLine),
                location: values["LOCATION"]?.first.flatMap(propertyValue)?.trimmingCharacters(in: .whitespacesAndNewlines),
                notes: values["DESCRIPTION"]?.first.flatMap(propertyValue)?.trimmingCharacters(in: .whitespacesAndNewlines),
                organizer: organizer,
                attendees: attendees,
                meetingURLs: meetingURLs,
                participantCount: participantCount,
                hasMeetingURL: hasMeetingURL,
                recurrenceRule: values["RRULE"]?.first.flatMap(propertyValue),
                recurrenceID: values["RECURRENCE-ID"]?.first.flatMap(icalDate(from:)),
                excludedDates: excludedDates(from: values["EXDATE"] ?? [], fallbackTimeZone: timeZone(from: startLine))
            )
        }

        var overridesByUID: [String: Set<DateOnly>] = [:]
        var resolvedEvents: [CalendarEvent] = []
        for event in parsedEvents where event.recurrenceID != nil {
            if let recurrenceID = event.recurrenceID {
                overridesByUID[event.uid, default: []].insert(dateOnly(from: recurrenceID, timeZone: event.timeZone))
            }
            if overlaps(start: event.startAt, end: event.endAt, rangeStart: rangeStart, rangeEnd: rangeEnd) {
                resolvedEvents.append(calendarEvent(from: event, startAt: event.startAt, endAt: event.endAt))
            }
        }

        for event in parsedEvents where event.recurrenceID == nil {
            guard let recurrenceRule = event.recurrenceRule else {
                if overlaps(start: event.startAt, end: event.endAt, rangeStart: rangeStart, rangeEnd: rangeEnd) {
                    resolvedEvents.append(calendarEvent(from: event, startAt: event.startAt, endAt: event.endAt))
                }
                continue
            }

            let startDay = dateOnly(from: rangeStart, timeZone: event.timeZone)
            let endDay = dateOnly(from: rangeEnd, timeZone: event.timeZone)
            for day in days(from: startDay, through: endDay, timeZone: event.timeZone) {
                if event.excludedDates.contains(day) || overridesByUID[event.uid, default: []].contains(day) {
                    continue
                }
                if !matchesRecurrence(rule: recurrenceRule, eventStart: event.startAt, occurrenceDay: day, timeZone: event.timeZone) {
                    continue
                }
                guard let occurrenceStart = replacingDate(of: event.startAt, with: day, timeZone: event.timeZone) else {
                    continue
                }
                let occurrenceEnd = occurrenceStart.addingTimeInterval(event.endAt.timeIntervalSince(event.startAt))
                if overlaps(start: occurrenceStart, end: occurrenceEnd, rangeStart: rangeStart, rangeEnd: rangeEnd) {
                    resolvedEvents.append(calendarEvent(from: event, startAt: occurrenceStart, endAt: occurrenceEnd))
                }
            }
        }

        return resolvedEvents
    }

    private static func unfoldICSLines(_ value: String) -> [String] {
        value.replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n")
            .reduce(into: [String]()) { result, line in
                if line.hasPrefix(" ") || line.hasPrefix("\t"), !result.isEmpty {
                    result[result.count - 1] += line.dropFirst()
                } else if !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    result.append(line)
                }
            }
    }

    private static func propertyName(_ line: String) -> String {
        let head = line.split(separator: ":", maxSplits: 1).first ?? ""
        return String(head.split(separator: ";", maxSplits: 1).first ?? "").uppercased()
    }

    private static func propertyValue(_ line: String?) -> String? {
        guard let line else { return nil }
        return line.split(separator: ":", maxSplits: 1).dropFirst().first.map(String.init)?
            .replacingOccurrences(of: "\\,", with: ",")
            .replacingOccurrences(of: "\\n", with: "\n")
            .replacingOccurrences(of: "\\;", with: ";")
    }

    private static func parameterValue(_ name: String, from line: String) -> String? {
        let head = line.split(separator: ":", maxSplits: 1).first ?? ""
        for part in head.split(separator: ";").dropFirst() {
            let pieces = part.split(separator: "=", maxSplits: 1).map(String.init)
            if pieces.count == 2, pieces[0].uppercased() == name.uppercased() {
                return pieces[1].trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            }
        }
        return nil
    }

    private static func icalDate(from line: String) -> Date? {
        guard let value = propertyValue(line) else { return nil }
        if value.count == 8 {
            return icalDateOnly.date(from: value)
        }
        if value.hasSuffix("Z") {
            return icalUTC.date(from: value)
        }
        let timeZone = timeZone(from: line)
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyyMMdd'T'HHmmss"
        return formatter.date(from: value)
    }

    private static func timeZone(from line: String) -> TimeZone {
        if let tzid = parameterValue("TZID", from: line),
           let timeZone = TimeZone(identifier: tzid) {
            return timeZone
        }
        if propertyValue(line)?.hasSuffix("Z") == true {
            return TimeZone(secondsFromGMT: 0) ?? .current
        }
        return .current
    }

    private static func participants(from lines: [String]) -> [CalendarParticipant] {
        lines.map(participant(from:))
    }

    private static func participant(from line: String) -> CalendarParticipant {
        let email = propertyValue(line)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "mailto:", with: "", options: [.caseInsensitive])
        return CalendarParticipant(
            name: parameterValue("CN", from: line)?.trimmingCharacters(in: .whitespacesAndNewlines),
            email: email?.isEmpty == false ? email : nil,
            role: parameterValue("ROLE", from: line),
            status: parameterValue("PARTSTAT", from: line),
            rsvp: parameterValue("RSVP", from: line).map { $0.uppercased() == "TRUE" }
        )
    }

    private static func participantCount(attendees: [CalendarParticipant], organizer: CalendarParticipant?) -> Int {
        var emails = Set<String>()
        var namedOnlyCount = 0
        for attendee in attendees {
            if let email = attendee.email?.lowercased(), !email.isEmpty {
                emails.insert(email)
            } else if attendee.name?.isEmpty == false {
                namedOnlyCount += 1
            }
        }
        if let email = organizer?.email?.lowercased(), !email.isEmpty {
            emails.insert(email)
        } else if organizer?.name?.isEmpty == false {
            namedOnlyCount += 1
        }
        return max(1, emails.count + namedOnlyCount)
    }

    private static func meetingURLs(from lines: [String]) -> [String] {
        var urls: [String] = []
        var seen = Set<String>()
        let pattern = #"https?://[^\s<>"\)\\]+"#
        let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
        for line in lines {
            let value = propertyValue(line) ?? line
            let range = NSRange(value.startIndex..<value.endIndex, in: value)
            regex?.matches(in: value, range: range).forEach { match in
                guard let swiftRange = Range(match.range, in: value) else { return }
                let url = String(value[swiftRange]).trimmingCharacters(in: CharacterSet(charactersIn: ".,;"))
                if seen.insert(url).inserted {
                    urls.append(url)
                }
            }
        }
        return urls
    }

    private static func excludedDates(from lines: [String], fallbackTimeZone: TimeZone) -> Set<DateOnly> {
        var dates = Set<DateOnly>()
        for line in lines {
            let timeZone = timeZone(from: line)
            guard let value = propertyValue(line) else { continue }
            for item in value.split(separator: ",").map(String.init) {
                let syntheticLine = "EXDATE:\(item)"
                if let date = icalDate(from: line.contains("TZID=") ? line.replacingOccurrences(of: value, with: item) : syntheticLine) {
                    dates.insert(dateOnly(from: date, timeZone: line.contains("TZID=") ? timeZone : fallbackTimeZone))
                }
            }
        }
        return dates
    }

    private static func calendarEvent(from event: ParsedICSEvent, startAt: Date, endAt: Date) -> CalendarEvent {
        CalendarEvent(
            uid: "\(event.uid)-\(icalUTC.string(from: startAt))",
            originalUID: event.uid,
            calendarName: event.calendarName,
            title: event.title,
            startAt: startAt,
            endAt: max(endAt, startAt.addingTimeInterval(60)),
            timeZone: event.timeZone.identifier,
            location: event.location,
            notes: event.notes,
            organizer: event.organizer,
            attendees: event.attendees,
            meetingURLs: event.meetingURLs,
            participantCount: event.participantCount,
            hasMeetingURL: event.hasMeetingURL,
            recurrenceRule: event.recurrenceRule,
            recurrenceID: event.recurrenceID
        )
    }

    private static func overlaps(start: Date, end: Date, rangeStart: Date, rangeEnd: Date) -> Bool {
        end > rangeStart && start < rangeEnd
    }

    private static func dateOnly(from date: Date, timeZone: TimeZone) -> DateOnly {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return DateOnly(year: components.year ?? 1970, month: components.month ?? 1, day: components.day ?? 1)
    }

    private static func days(from start: DateOnly, through end: DateOnly, timeZone: TimeZone) -> [DateOnly] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        guard var cursor = calendar.date(from: DateComponents(year: start.year, month: start.month, day: start.day)),
              let endDate = calendar.date(from: DateComponents(year: end.year, month: end.month, day: end.day)) else {
            return []
        }
        var result: [DateOnly] = []
        while cursor <= endDate {
            result.append(dateOnly(from: cursor, timeZone: timeZone))
            cursor = calendar.date(byAdding: .day, value: 1, to: cursor) ?? cursor.addingTimeInterval(24 * 3600)
        }
        return result
    }

    private static func replacingDate(of date: Date, with day: DateOnly, timeZone: TimeZone) -> Date? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let time = calendar.dateComponents([.hour, .minute, .second], from: date)
        return calendar.date(from: DateComponents(
            timeZone: timeZone,
            year: day.year,
            month: day.month,
            day: day.day,
            hour: time.hour,
            minute: time.minute,
            second: time.second
        ))
    }

    private static func matchesRecurrence(rule: String, eventStart: Date, occurrenceDay: DateOnly, timeZone: TimeZone) -> Bool {
        let startDay = dateOnly(from: eventStart, timeZone: timeZone)
        if occurrenceDay < startDay {
            return false
        }
        if let until = recurrenceValue("UNTIL", in: rule) {
            let untilLine = "UNTIL:\(until)"
            if let untilDate = icalDate(from: untilLine),
               dateOnly(from: untilDate, timeZone: timeZone) < occurrenceDay {
                return false
            }
        }

        let interval = Int(recurrenceValue("INTERVAL", in: rule) ?? "") ?? 1
        let frequency = recurrenceValue("FREQ", in: rule) ?? ""
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone

        guard let startDate = calendar.date(from: DateComponents(year: startDay.year, month: startDay.month, day: startDay.day)),
              let occurrenceDate = calendar.date(from: DateComponents(year: occurrenceDay.year, month: occurrenceDay.month, day: occurrenceDay.day)) else {
            return false
        }

        switch frequency {
        case "DAILY":
            let days = calendar.dateComponents([.day], from: startDate, to: occurrenceDate).day ?? 0
            return days >= 0 && days % interval == 0
        case "WEEKLY":
            if let byDay = recurrenceValue("BYDAY", in: rule) {
                let weekdayCodes = Set(byDay.split(separator: ",").map(String.init))
                if !weekdayCodes.contains(weekdayCode(for: occurrenceDate, calendar: calendar)) {
                    return false
                }
            } else if calendar.component(.weekday, from: startDate) != calendar.component(.weekday, from: occurrenceDate) {
                return false
            }
            let startWeek = calendar.dateInterval(of: .weekOfYear, for: startDate)?.start ?? startDate
            let occurrenceWeek = calendar.dateInterval(of: .weekOfYear, for: occurrenceDate)?.start ?? occurrenceDate
            let weeks = calendar.dateComponents([.weekOfYear], from: startWeek, to: occurrenceWeek).weekOfYear ?? 0
            return weeks >= 0 && weeks % interval == 0
        case "MONTHLY":
            guard startDay.day == occurrenceDay.day else { return false }
            let months = calendar.dateComponents([.month], from: startDate, to: occurrenceDate).month ?? 0
            return months >= 0 && months % interval == 0
        default:
            return false
        }
    }

    private static func recurrenceValue(_ name: String, in rule: String) -> String? {
        for part in rule.split(separator: ";").map(String.init) {
            let pieces = part.split(separator: "=", maxSplits: 1).map(String.init)
            if pieces.count == 2, pieces[0].uppercased() == name {
                return pieces[1].uppercased()
            }
        }
        return nil
    }

    private static func weekdayCode(for date: Date, calendar: Calendar) -> String {
        switch calendar.component(.weekday, from: date) {
        case 1: return "SU"
        case 2: return "MO"
        case 3: return "TU"
        case 4: return "WE"
        case 5: return "TH"
        case 6: return "FR"
        default: return "SA"
        }
    }

    private static let icalUTC: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return formatter
    }()

    private static let icalDateOnly: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyyMMdd"
        return formatter
    }()
}
