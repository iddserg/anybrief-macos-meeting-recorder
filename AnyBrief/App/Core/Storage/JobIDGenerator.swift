import Foundation

enum JobIDGenerator {
    private static let alphabet = Array("23456789abcdefghjkmnpqrstuvwxyz")

    static func make(length: Int = 10) -> String {
        String((0..<length).compactMap { _ in alphabet.randomElement() })
    }

    static func compactDisplay(_ id: String, length: Int = 10) -> String {
        guard id.count > length else {
            return id
        }

        let normalized = id.replacingOccurrences(of: "-", with: "")
        return String(normalized.prefix(length))
    }
}
