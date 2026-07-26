import Foundation

enum ConfigurationPayloadValue: Codable, Equatable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case object([String: ConfigurationPayloadValue])
    case array([ConfigurationPayloadValue])
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int.self) {
            self = .int(value)
        } else if let value = try? container.decode(Double.self) {
            self = .double(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([ConfigurationPayloadValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: ConfigurationPayloadValue].self))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case let .string(value):
            try container.encode(value)
        case let .int(value):
            try container.encode(value)
        case let .double(value):
            try container.encode(value)
        case let .bool(value):
            try container.encode(value)
        case let .object(value):
            try container.encode(value)
        case let .array(value):
            try container.encode(value)
        case .null:
            try container.encodeNil()
        }
    }
}

typealias ConfigurationPayload = [String: ConfigurationPayloadValue]

extension Dictionary where Key == String, Value == ConfigurationPayloadValue {
    var jsonObject: [String: Any] {
        mapValues { $0.jsonObject }
    }
}

extension ConfigurationPayloadValue {
    var jsonObject: Any {
        switch self {
        case let .string(value):
            return value
        case let .int(value):
            return value
        case let .double(value):
            return value
        case let .bool(value):
            return value
        case let .object(value):
            return value.jsonObject
        case let .array(value):
            return value.map(\.jsonObject)
        case .null:
            return NSNull()
        }
    }
}

enum ConfigurationPayloadCodec {
    static func decode<T: Decodable>(_ type: T.Type, from payload: ConfigurationPayload, default defaultValue: T) -> T {
        guard let data = try? JSONEncoder().encode(payload),
              let value = try? JSONDecoder().decode(T.self, from: data) else {
            return defaultValue
        }
        return value
    }

    static func encode<T: Encodable>(_ value: T) -> ConfigurationPayload {
        guard let data = try? JSONEncoder().encode(value),
              let payload = try? JSONDecoder().decode(ConfigurationPayload.self, from: data) else {
            return [:]
        }
        return payload
    }
}
