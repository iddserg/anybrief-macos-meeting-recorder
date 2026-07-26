import Foundation
import Security

protocol SecretStoreProtocol {
    func save(key: String, value: String) throws
    func load(key: String) -> String?
    func delete(key: String)
}

enum SecretStoreFactory {
    static func makeDefault() -> SecretStoreProtocol {
        #if DEBUG
        DebugFileSecretStore()
        #else
        KeychainStore()
        #endif
    }
}

final class KeychainStore: SecretStoreProtocol {
    private let service = "pro.anybrief"
    private let cacheLock = NSLock()

    // In-memory cache to avoid repeated Keychain reads (e.g. Dashboard 2s refresh).
    // Evicted on save/delete so callers always see fresh values after writes.
    private var cache: [String: String] = [:]

    func save(key: String, value: String) throws {
        guard let data = value.data(using: .utf8) else {
            throw KeychainStoreError.invalidValueEncoding
        }

        var query = baseQuery(for: key)
        let attributes: [CFString: Any] = [
            kSecValueData: data,
        ]

        let status = SecItemCopyMatching(query as CFDictionary, nil)

        switch status {
        case errSecSuccess:
            let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
            guard updateStatus == errSecSuccess else {
                throw KeychainStoreError.unhandledStatus(updateStatus)
            }
        case errSecItemNotFound:
            query[kSecValueData] = data
            query[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlock
            let addStatus = SecItemAdd(query as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw KeychainStoreError.unhandledStatus(addStatus)
            }
        default:
            throw KeychainStoreError.unhandledStatus(status)
        }

        cacheLock.lock()
        cache[key] = value
        cacheLock.unlock()
    }

    func load(key: String) -> String? {
        cacheLock.lock()
        let cached = cache[key]
        cacheLock.unlock()
        if let cached {
            return cached
        }

        var query = baseQuery(for: key)
        query[kSecMatchLimit] = kSecMatchLimitOne
        query[kSecReturnData] = true

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess,
              let data = result as? Data,
              let value = String(data: data, encoding: .utf8) else {
            return nil
        }

        cacheLock.lock()
        cache[key] = value
        cacheLock.unlock()
        return value
    }

    func delete(key: String) {
        cacheLock.lock()
        cache.removeValue(forKey: key)
        cacheLock.unlock()
        let query = baseQuery(for: key)
        SecItemDelete(query as CFDictionary)
    }

    private func baseQuery(for key: String) -> [CFString: Any] {
        [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: key,
        ]
    }
}

enum KeychainStoreError: Error {
    case invalidValueEncoding
    case unhandledStatus(OSStatus)
}

#if DEBUG
final class DebugFileSecretStore: SecretStoreProtocol {
    private let fileManager: FileManager
    private let fileURL: URL
    private let encoder: JSONEncoder
    private let decoder = JSONDecoder()
    private let lock = NSLock()

    init(fileManager: FileManager = .default, fileURL: URL? = nil) {
        self.fileManager = fileManager
        self.fileURL = fileURL ?? Self.defaultFileURL(fileManager: fileManager)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        self.encoder = encoder
    }

    func save(key: String, value: String) throws {
        try lock.withLock {
            var values = try loadValues()
            values[key] = value
            try saveValues(values)
        }
    }

    func load(key: String) -> String? {
        lock.withLock {
            (try? loadValues())?[key]
        }
    }

    func delete(key: String) {
        try? lock.withLock {
            var values = try loadValues()
            values.removeValue(forKey: key)
            try saveValues(values)
        }
    }

    private static func defaultFileURL(fileManager: FileManager) -> URL {
        fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("anybrief", isDirectory: true)
            .appendingPathComponent("config", isDirectory: true)
            .appendingPathComponent("debug-secrets.json", isDirectory: false)
    }

    private func loadValues() throws -> [String: String] {
        guard fileManager.fileExists(atPath: fileURL.path) else {
            return [:]
        }

        let data = try Data(contentsOf: fileURL)
        guard !data.isEmpty else {
            return [:]
        }

        return try decoder.decode([String: String].self, from: data)
    }

    private func saveValues(_ values: [String: String]) throws {
        try fileManager.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try encoder.encode(values)
        try data.write(to: fileURL, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }
}
#endif
