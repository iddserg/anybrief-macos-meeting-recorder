import Foundation

/// Dashboard bridge for CalDAV settings and today's autopilot schedule.
/// The bridge lives with the CalDAV source so Dashboard does not become the
/// owner of CalDAV-specific behavior.
extension DashboardViewModel {
    func testCalendarSettings() {
        guard !isTestingCalendarSettings else {
            return
        }
        isTestingCalendarSettings = true
        calendarSettingsMessage = nil
        calendarSettingsMessageIsError = false

        Task {
            do {
                let password = await currentCalDAVPassword()
                let eventsCount = try await calendarService.testConnection(
                    baseURLString: caldavURL,
                    username: caldavUsername,
                    password: password,
                    calendarID: calDAVCalendarID.trimmingCharacters(in: .whitespacesAndNewlines)
                )
                await loggingService.log(
                    "CalDAV settings check succeeded. Events in the next 24 hours: \(eventsCount).",
                    level: .info,
                    component: "Settings"
                )
                await MainActor.run {
                    isTestingCalendarSettings = false
                    calendarSettingsMessage = String(
                        format: String(localized: "Calendar settings are valid. Events in the next 24 hours: %d."),
                        eventsCount
                    )
                    calendarSettingsMessageIsError = false
                }
            } catch {
                await loggingService.log(
                    "CalDAV settings check failed: \(error.localizedDescription)",
                    level: .warn,
                    component: "Settings"
                )
                await MainActor.run {
                    isTestingCalendarSettings = false
                    calendarSettingsMessage = error.localizedDescription
                    calendarSettingsMessageIsError = true
                }
            }
        }
    }

    func loadCalendars() {
        guard !isLoadingCalendars else {
            return
        }
        guard calendarConnectionFieldsReady else {
            calendarSettingsMessage = String(localized: "Enter CalDAV URL, username, and password first.")
            calendarSettingsMessageIsError = true
            return
        }
        isLoadingCalendars = true
        calendarSettingsMessage = nil
        calendarSettingsMessageIsError = false

        Task {
            do {
                let password = await currentCalDAVPassword()
                let calendars = try await calendarService.discoverCalendars(
                    baseURLString: caldavURL,
                    username: caldavUsername,
                    password: password
                )
                await loggingService.log(
                    "Loaded \(calendars.count) CalDAV calendars from settings.",
                    level: .info,
                    component: "Settings"
                )
                await MainActor.run {
                    discoveredCalendars = calendars
                    verifiedCalendarConnectionSignature = calendarConnectionSignature()
                    if !calDAVCalendarID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                       !calendars.contains(where: { $0.id == calDAVCalendarID }) {
                        calDAVCalendarID = ""
                    }
                    isLoadingCalendars = false
                    calendarSettingsMessage = String(
                        format: String(localized: "Found calendars: %d. Select one below."),
                        calendars.count
                    )
                    calendarSettingsMessageIsError = false
                }
            } catch {
                await loggingService.log(
                    "Failed to load CalDAV calendars: \(error.localizedDescription)",
                    level: .warn,
                    component: "Settings"
                )
                await MainActor.run {
                    discoveredCalendars = []
                    verifiedCalendarConnectionSignature = nil
                    isLoadingCalendars = false
                    calendarSettingsMessage = error.localizedDescription
                    calendarSettingsMessageIsError = true
                }
            }
        }
    }

    func selectCalendar(_ calendar: CalDAVCalendarService.CalendarInfo) {
        calDAVCalendarID = calendar.id
        calendarSettingsMessage = String(
            format: String(localized: "Calendar ID selected: %@"),
            calendar.id
        )
        calendarSettingsMessageIsError = false
    }

    func currentCalDAVPassword() async -> String? {
        let typed = caldavPassword.trimmingCharacters(in: .whitespacesAndNewlines)
        if !typed.isEmpty, !typed.hasPrefix("••") {
            return typed
        }
        let settings = await appSettingsStore.load(using: loggingService)
        return settings.automation.calDAVSettings.passwordKeychainRef.flatMap { keychainStore.load(key: $0) }
    }

    func calendarConnectionSignature() -> String {
        [
            caldavURL.trimmingCharacters(in: .whitespacesAndNewlines),
            caldavUsername.trimmingCharacters(in: .whitespacesAndNewlines),
            caldavPassword.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("••")
                ? "stored-password"
                : caldavPassword.trimmingCharacters(in: .whitespacesAndNewlines),
        ].joined(separator: "\n")
    }

    func toggleAutopilotEnabled() {
        Task {
            do {
                var settings = await appSettingsStore.load(using: loggingService)
                settings.automation.calendarAutopilotSettings.enabled.toggle()
                try await appSettingsStore.save(settings)
                await loggingService.log(
                    settings.automation.calendarAutopilotSettings.enabled ? "Autopilot enabled from Dashboard." : "Autopilot disabled from Dashboard.",
                    level: .info,
                    component: "Autopilot"
                )
                await MainActor.run {
                    calendarAutopilotEnabled = settings.automation.calendarAutopilotSettings.enabled
                    saveMessage = settings.automation.calendarAutopilotSettings.enabled
                        ? String(localized: "Autopilot enabled.")
                        : String(localized: "Autopilot disabled.")
                    saveMessageIsError = false
                }
                await refresh()
            } catch {
                await MainActor.run {
                    saveMessage = error.localizedDescription
                    saveMessageIsError = true
                }
            }
        }
    }

    func loadTodayAutopilotEventsIfNeeded() async -> (events: [AutopilotScheduleEvent], error: String?) {
        let now = Date()
        if let lastCalendarScheduleRefreshAt,
           now.timeIntervalSince(lastCalendarScheduleRefreshAt) < 60 {
            return (todayAutopilotEvents, calendarScheduleError)
        }
        lastCalendarScheduleRefreshAt = now

        let settings = await appSettingsStore.load(using: loggingService)
        guard settings.automation.calDAVSettings.enabled else {
            clearCalendarScheduleBackoff()
            return ([], nil)
        }
        let password = settings.automation.calDAVSettings.passwordKeychainRef.flatMap { keychainStore.load(key: $0) }
        let settingsSignature = calendarScheduleSettingsSignature(settings: settings, password: password)
        if let calendarScheduleBackoffUntil, calendarScheduleBackoffUntil > now {
            if lastCalendarScheduleBackoffSettingsSignature == settingsSignature {
                return (todayAutopilotEvents, calendarScheduleError)
            }
            clearCalendarScheduleBackoff()
        }
        guard password?.isEmpty == false else {
            return ([], String(localized: "Calendar is not configured."))
        }

        do {
            let startOfDay = Calendar.current.startOfDay(for: now)
            let endOfDay = Calendar.current.date(byAdding: .day, value: 1, to: startOfDay) ?? now.addingTimeInterval(24 * 3600)
            let events = try await calendarService.fetchEvents(
                settings: settings,
                password: password,
                from: startOfDay,
                to: endOfDay
            )
            clearCalendarScheduleBackoff()
            return (
                events.map {
                    AutopilotScheduleEvent(
                        id: $0.uid,
                        title: $0.title,
                        startAt: $0.startAt,
                        endAt: $0.endAt,
                        participantCount: $0.participantCount,
                        hasMeetingURL: $0.hasMeetingURL,
                        meetingURL: $0.meetingURLs.first.flatMap { URL(string: $0) }
                    )
                },
                nil
            )
        } catch {
            if error is SuppressedCalendarFetchError {
                return (todayAutopilotEvents, error.localizedDescription)
            }
            await handleCalendarScheduleLoadError(error, settingsSignature: settingsSignature)
            return (todayAutopilotEvents, error.localizedDescription)
        }
    }

    func handleCalendarScheduleLoadError(_ error: Error, settingsSignature: String) async {
        if shouldThrottleCalendarScheduleRefresh(for: error) {
            let description = error.localizedDescription
            calendarScheduleBackoffUntil = Date().addingTimeInterval(15 * 60)
            lastCalendarScheduleBackoffSettingsSignature = settingsSignature
            if lastCalendarScheduleBackoffErrorDescription != description {
                lastCalendarScheduleBackoffErrorDescription = description
                await loggingService.log(
                    "Failed to load today's calendar schedule: \(description). Pausing dashboard calendar refresh for 15 minutes.",
                    level: .warn,
                    component: "Autopilot"
                )
            }
            return
        }

        await loggingService.log(
            "Failed to load today's calendar schedule: \(error.localizedDescription)",
            level: .warn,
            component: "Autopilot"
        )
    }

    func clearCalendarScheduleBackoff() {
        calendarScheduleBackoffUntil = nil
        lastCalendarScheduleBackoffErrorDescription = nil
        lastCalendarScheduleBackoffSettingsSignature = nil
    }

    func shouldThrottleCalendarScheduleRefresh(for error: Error) -> Bool {
        if let calendarError = error as? CalendarSyncError {
            return calendarError.shouldThrottleAutomaticRetries
        }
        return false
    }

    func calendarScheduleSettingsSignature(settings: AppSettings, password: String?) -> String {
        [
            settings.automation.calDAVSettings.config.url.trimmingCharacters(in: .whitespacesAndNewlines),
            settings.automation.calDAVSettings.config.username.trimmingCharacters(in: .whitespacesAndNewlines),
            settings.automation.calDAVSettings.name.trimmingCharacters(in: .whitespacesAndNewlines),
            settings.automation.calDAVSettings.passwordKeychainRef ?? "",
            String(password?.hashValue ?? 0),
        ].joined(separator: "\n")
    }
}
