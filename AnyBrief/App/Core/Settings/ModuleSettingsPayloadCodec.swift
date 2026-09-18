import Foundation

struct ConfigurationSecretField {
    let valuePath: [String]
    let referencePath: [String]
}

enum ModuleSettingsPayloadError: LocalizedError {
    case invalidPayload
    case invalidSecret
    case unsupportedRule
    var errorDescription: String? {
        switch self {
        case .invalidPayload: return "Invalid settings payload."
        case .invalidSecret: return "Secret fields must be strings or null."
        case .unsupportedRule: return "Unsupported automation rule for this source."
        }
    }
}

/// Modules declare their schema and secret fields; transports handle envelopes only.
struct ModuleSettingsPayloadCodec {
    private let normalize: (ConfigurationPayload) throws -> ConfigurationPayload
    private let fields: [ConfigurationSecretField]
    private let includesEnabled: Bool

    init() {
        normalize = { $0 }
        fields = []
        includesEnabled = false
    }

    init<T: Codable>(_ type: T.Type, includesEnabled: Bool = false,
                     secrets: [ConfigurationSecretField] = [], transform: @escaping (T) -> T = { $0 }) {
        self.fields = secrets
        self.includesEnabled = includesEnabled
        normalize = { payload in
            do {
                let value = try JSONDecoder().decode(T.self, from: JSONEncoder().encode(payload))
                return try JSONDecoder().decode(ConfigurationPayload.self, from: JSONEncoder().encode(transform(value)))
            } catch { throw ModuleSettingsPayloadError.invalidPayload }
        }
    }

    func importing(_ input: ConfigurationPayload, previous: ConfigurationPayload?, enabled: Bool? = nil,
                   secrets: SecretStoreProtocol) throws -> ConfigurationPayload {
        var prepared = input
        if includesEnabled, let enabled { prepared["enabled"] = .bool(enabled) }
        for field in fields {
            if let value = Self.value(input, at: field.valuePath) {
                switch value {
                case .string, .null: break
                default: throw ModuleSettingsPayloadError.invalidSecret
                }
            }
            Self.set(&prepared, at: field.valuePath, value: .string(""))
            Self.set(&prepared, at: field.referencePath, value: previous.flatMap { Self.value($0, at: field.referencePath) })
        }
        var result = try normalize(prepared)
        for field in fields {
            let reference: String?
            if case let .string(value)? = previous.flatMap({ Self.value($0, at: field.referencePath) }) { reference = value }
            else { reference = nil }
            switch Self.value(input, at: field.valuePath) {
            case nil: break // Omission preserves a previously stored secret.
            case let .string(value)? where value == "***" || value.hasPrefix("••"): break
            case .null?, .string("")?:
                if let reference { secrets.delete(key: reference) }
                Self.set(&result, at: field.referencePath, value: nil)
            case let .string(value)?:
                let key = reference?.isEmpty == false ? reference! : UUID().uuidString.lowercased()
                try secrets.save(key: key, value: value)
                Self.set(&result, at: field.referencePath, value: .string(key))
            default: throw ModuleSettingsPayloadError.invalidSecret
            }
        }
        return result
    }

    func exporting(_ payload: ConfigurationPayload, secrets: SecretStoreProtocol) -> ConfigurationPayload {
        var result = (try? normalize(payload)) ?? payload
        for field in fields {
            var mask = ""
            if case let .string(reference)? = Self.value(payload, at: field.referencePath),
               secrets.load(key: reference) != nil { mask = "***" }
            Self.set(&result, at: field.valuePath, value: .string(mask))
            Self.set(&result, at: field.referencePath, value: nil)
        }
        return result
    }

    private static func value(_ payload: ConfigurationPayload, at path: [String]) -> ConfigurationPayloadValue? {
        guard let key = path.first else { return nil }
        if path.count == 1 { return payload[key] }
        guard case let .object(child)? = payload[key] else { return nil }
        return value(child, at: Array(path.dropFirst()))
    }

    private static func set(_ payload: inout ConfigurationPayload, at path: [String], value: ConfigurationPayloadValue?) {
        guard let key = path.first else { return }
        if path.count == 1 { payload[key] = value; return }
        var child: ConfigurationPayload = [:]
        if case let .object(existing)? = payload[key] { child = existing }
        set(&child, at: Array(path.dropFirst()), value: value)
        payload[key] = .object(child)
    }
}
