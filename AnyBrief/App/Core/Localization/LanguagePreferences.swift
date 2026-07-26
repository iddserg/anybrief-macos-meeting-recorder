import Foundation

enum LanguagePreferences {
    static func apply(_ locale: String) {
        if locale == "system" {
            UserDefaults.standard.removeObject(forKey: "AppleLanguages")
        } else {
            UserDefaults.standard.set([locale], forKey: "AppleLanguages")
        }
    }

    static func effectiveLanguageCode(for locale: String) -> String {
        switch locale {
        case "ru":
            return "ru"
        case "en":
            return "en"
        default:
            return normalizedSupportedLanguageCode(systemPreferredLanguageIdentifier())
        }
    }

    private static func systemPreferredLanguageIdentifier() -> String {
        if let languages = UserDefaults.standard.persistentDomain(forName: UserDefaults.globalDomain)?["AppleLanguages"] as? [String],
           let first = languages.first {
            return first
        }
        return Locale.preferredLanguages.first ?? "en"
    }

    private static func normalizedSupportedLanguageCode(_ identifier: String) -> String {
        identifier.lowercased().hasPrefix("ru") ? "ru" : "en"
    }
}
