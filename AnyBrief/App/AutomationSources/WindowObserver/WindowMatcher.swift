import Foundation

enum WindowMatcher {
    static func firstMatch(in windows: [ObservedWindow], rules: [WindowObserverRule]) -> WindowObserverMatch? {
        let normalizedRules = rules.map(\.normalized).filter(\.enabled)
        for window in windows {
            for rule in normalizedRules where matches(window: window, rule: rule) {
                return WindowObserverMatch(
                    ruleID: rule.id,
                    ruleName: rule.name.isEmpty ? matchingLabel(for: rule) : rule.name,
                    applicationName: window.applicationName,
                    windowTitle: window.title,
                    processIdentifier: window.processIdentifier
                )
            }
        }
        return nil
    }

    static func matches(window: ObservedWindow, rule: WindowObserverRule) -> Bool {
        let normalizedRule = rule.normalized
        let applicationPattern = normalizedRule.applicationPattern
        let titlePattern = normalizedRule.titlePattern
        guard !applicationPattern.isEmpty || !titlePattern.isEmpty else {
            return false
        }

        if !applicationPattern.isEmpty,
           !window.applicationName.localizedCaseInsensitiveContains(applicationPattern) {
            return false
        }
        if !titlePattern.isEmpty,
           !window.title.localizedCaseInsensitiveContains(titlePattern) {
            return false
        }
        return true
    }

    private static func matchingLabel(for rule: WindowObserverRule) -> String {
        if !rule.applicationPattern.isEmpty {
            return rule.applicationPattern
        }
        return rule.titlePattern
    }
}
