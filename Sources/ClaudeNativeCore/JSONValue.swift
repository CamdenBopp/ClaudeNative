import Foundation

/// A decoded JSON value. The CLI's stream is open-ended, so every line is
/// decoded into this first and then read field by field.
public enum JSONValue: Sendable, Equatable, Codable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: JSONValue].self))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }

    public subscript(key: String) -> JSONValue? {
        if case .object(let object) = self { return object[key] }
        return nil
    }

    public var string: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    public var bool: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }

    public var int: Int? {
        if case .number(let value) = self { return Int(exactly: value) }
        return nil
    }

    public var array: [JSONValue]? {
        if case .array(let value) = self { return value }
        return nil
    }

    public var object: [String: JSONValue]? {
        if case .object(let value) = self { return value }
        return nil
    }

    /// One line of compact JSON, as the CLI reads it on stdin.
    public func line() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(self)
        data.append(UInt8(ascii: "\n"))
        return data
    }

    /// Parses one line. Through JSONSerialization rather than the Codable
    /// init, which tried Bool, Double, String and array before object, so
    /// each object threw four errors first: 3.4 times slower on a 92 MB
    /// session, with the same values.
    public static func parse(_ line: Data) throws -> JSONValue {
        JSONValue(foundation: try JSONSerialization.jsonObject(with: line, options: [.fragmentsAllowed]))
    }

    /// A value as JSONSerialization gives it. Its Booleans are NSNumbers
    /// too, told apart by their CFBoolean type.
    init(foundation value: Any) {
        switch value {
        case let string as String:
            self = .string(string)
        case let number as NSDecimalNumber:
            // A long decimal comes as NSDecimalNumber, whose doubleValue
            // can be a unit off in the last place; its text parses exactly,
            // as the decoder did ("0.0048195600000000005" in a cost).
            self = .number(Double(number.stringValue) ?? number.doubleValue)
        case let number as NSNumber:
            self = CFGetTypeID(number) == CFBooleanGetTypeID() ? .bool(number.boolValue) : .number(number.doubleValue)
        case let array as [Any]:
            self = .array(array.map(JSONValue.init(foundation:)))
        case let object as [String: Any]:
            self = .object(object.mapValues(JSONValue.init(foundation:)))
        default:
            self = .null
        }
    }
}
