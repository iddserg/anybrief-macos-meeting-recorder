import XCTest
@testable import AnyBrief

final class WindowMatcherTests: XCTestCase {
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
