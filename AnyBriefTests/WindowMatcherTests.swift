import XCTest
@testable import AnyBrief

final class WindowMatcherTests: XCTestCase {
    func testDefaultsCoverCallAppsAndBrowserMeetingTitles() {
        let examples = [
            ("zoom.us", "Daily", "default-zoom"),
            ("Microsoft Teams", "Daily", "default-teams"),
            ("Google Chrome", "Meet - abc-defg-hij", "default-google-meet"),
            ("Safari", "Meet - Planning", "default-google-meet"),
            ("Webex", "Meeting", "default-webex"),
            ("FaceTime", "Call", "default-facetime"),
            ("Яндекс Телемост", "Встреча", "default-telemost-ru"),
            ("Yandex Telemost", "Meeting", "default-telemost-en"),
            ("Safari", "Встреча — Яндекс Телемост", "default-telemost-web"),
            ("Контур.Толк", "Встреча", "default-tolk"),
            ("Google Chrome", "Планирование — Контур.Толк", "default-tolk-web"),
        ]
        for (app, title, expected) in examples {
            let match = WindowMatcher.firstMatch(in: [ObservedWindow(applicationName: app, title: title, processIdentifier: 1)], rules: WindowObserverRule.defaultRules)
            XCTAssertEqual(match?.ruleID, expected)
        }
        XCTAssertEqual(Set(WindowObserverRule.defaultRules.map(\.id)).count, WindowObserverRule.defaultRules.count)
        for app in ["Google Chrome", "Safari", "Firefox", "Slack", "Telegram", "Discord", "AnyBrief"] {
            XCTAssertNil(WindowMatcher.firstMatch(in: [ObservedWindow(applicationName: app, title: "General chat", processIdentifier: 1)], rules: WindowObserverRule.defaultRules))
        }
    }

    func testNormalizationPreservesExistingCustomRules() {
        var config = WindowObserverConfig()
        config.rules = [WindowObserverRule(id: "custom", enabled: false, name: "My meeting", applicationPattern: "custom app")]
        XCTAssertEqual(config.normalized().rules, config.rules)
    }

    func testMatchesApplicationPatternCaseInsensitively() {
        let window = ObservedWindow(applicationName: "zoom.us", title: "Daily Sync", processIdentifier: 100)
        let rule = WindowObserverRule(name: "Zoom", applicationPattern: "Zoom")

        XCTAssertTrue(WindowMatcher.matches(window: window, rule: rule))
    }

    func testMatchesTitlePatternForBrowserMeetings() {
        let window = ObservedWindow(applicationName: "Google Chrome", title: "Meet - Planning", processIdentifier: 101)
        let rule = WindowObserverRule(name: "Meet", applicationPattern: "", titlePattern: "meet")

        let match = WindowMatcher.firstMatch(in: [window], rules: [rule])

        XCTAssertEqual(match?.ruleName, "Meet")
        XCTAssertEqual(match?.recordingTitle, "Google Chrome - Meet - Planning")
    }

    func testRequiresAllNonEmptyPatterns() {
        let window = ObservedWindow(applicationName: "Microsoft Teams", title: "Chat", processIdentifier: 102)
        let rule = WindowObserverRule(name: "Teams call", applicationPattern: "teams", titlePattern: "meeting")

        XCTAssertFalse(WindowMatcher.matches(window: window, rule: rule))
    }

    func testIgnoresDisabledRules() {
        let window = ObservedWindow(applicationName: "zoom.us", title: "Daily Sync", processIdentifier: 103)
        let rule = WindowObserverRule(enabled: false, name: "Zoom", applicationPattern: "zoom")

        XCTAssertNil(WindowMatcher.firstMatch(in: [window], rules: [rule]))
    }
}
