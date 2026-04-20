import Foundation

/// A type-safe representation of any JSON value.
///
/// `JSONValue` is the canonical type for untyped payloads in KernelHarnessKit:
/// tool arguments, tool results, MCP messages, and JSON Schema examples. It is
/// `Sendable`, `Hashable`, and `Codable`, and round-trips losslessly with
/// `JSONEncoder`/`JSONDecoder` and with native Swift literals via
/// `ExpressibleBy*Literal` conformances.
public enum JSONValue: Sendable, Hashable {
    /// A JSON string.
    case string(String)
    /// A JSON number with a fractional component.
    case number(Double)
    /// A JSON number without a fractional component.
    ///
    /// Kept distinct from ``number(_:)`` so that integer-typed fields in
    /// JSON Schema (`"type": "integer"`) round-trip without being converted
    /// to a floating-point value.
    case integer(Int64)
    /// A JSON boolean.
    case bool(Bool)
    /// A JSON array.
    case array([JSONValue])
    /// A JSON object with insertion-order-preserving keys.
    case object([String: JSONValue])
    /// A JSON `null`.
    case null
}

// MARK: - Convenience access

extension JSONValue {
    /// The underlying string, if this value is a ``string(_:)``.
    public var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    /// The underlying integer, if this value is an ``integer(_:)``, or a
    /// whole-number ``number(_:)``.
    public var intValue: Int64? {
        switch self {
        case .integer(let value):
            return value
        case .number(let value) where value.rounded() == value:
            return Int64(value)
        default:
            return nil
        }
    }

    /// The underlying floating-point number.
    public var doubleValue: Double? {
        switch self {
        case .number(let value): return value
        case .integer(let value): return Double(value)
        default: return nil
        }
    }

    /// The underlying boolean.
    public var boolValue: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }

    /// The underlying array.
    public var arrayValue: [JSONValue]? {
        if case .array(let value) = self { return value }
        return nil
    }

    /// The underlying object.
    public var objectValue: [String: JSONValue]? {
        if case .object(let value) = self { return value }
        return nil
    }

    /// `true` if this value represents JSON `null`.
    public var isNull: Bool {
        if case .null = self { return true }
        return false
    }

    /// Subscript into a JSON object by key. Returns `nil` for non-objects or
    /// missing keys.
    public subscript(key: String) -> JSONValue? {
        guard case .object(let dict) = self else { return nil }
        return dict[key]
    }

    /// Subscript into a JSON array by index. Returns `nil` for non-arrays or
    /// out-of-bounds indices.
    public subscript(index: Int) -> JSONValue? {
        guard case .array(let items) = self, items.indices.contains(index) else {
            return nil
        }
        return items[index]
    }
}

// MARK: - Literal conformances

extension JSONValue: ExpressibleByStringLiteral {
    public init(stringLiteral value: String) { self = .string(value) }
}

extension JSONValue: ExpressibleByIntegerLiteral {
    public init(integerLiteral value: Int64) { self = .integer(value) }
}

extension JSONValue: ExpressibleByFloatLiteral {
    public init(floatLiteral value: Double) { self = .number(value) }
}

extension JSONValue: ExpressibleByBooleanLiteral {
    public init(booleanLiteral value: Bool) { self = .bool(value) }
}

extension JSONValue: ExpressibleByNilLiteral {
    public init(nilLiteral: ()) { self = .null }
}

extension JSONValue: ExpressibleByArrayLiteral {
    public init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
}

extension JSONValue: ExpressibleByDictionaryLiteral {
    public init(dictionaryLiteral elements: (String, JSONValue)...) {
        self = .object(Dictionary(uniqueKeysWithValues: elements))
    }
}

// MARK: - Codable

extension JSONValue: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int64.self) {
            self = .integer(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "JSONValue cannot decode this value"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .integer(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }
}

// MARK: - Bridging to Foundation

extension JSONValue {
    /// The matching `Foundation` object — suitable for passing to APIs that
    /// take `[String: Any]` (for example, the `input_schema` field on an OpenAI
    /// tool definition).
    public var foundationValue: Any {
        switch self {
        case .string(let value): return value
        case .number(let value): return value
        case .integer(let value): return value
        case .bool(let value): return value
        case .null: return NSNull()
        case .array(let items): return items.map(\.foundationValue)
        case .object(let dict):
            return dict.mapValues(\.foundationValue)
        }
    }

    /// Build a ``JSONValue`` from a Foundation object graph produced by
    /// `JSONSerialization`. Throws if the input contains unsupported types.
    public init(foundation value: Any) throws {
        switch value {
        case is NSNull:
            self = .null
        case let bool as Bool:
            // NSNumber will bridge as Bool for kCFBooleanTrue/False.
            self = .bool(bool)
        case let int as Int64:
            self = .integer(int)
        case let int as Int:
            self = .integer(Int64(int))
        case let number as Double:
            self = .number(number)
        case let number as NSNumber:
            // Distinguish int-backed NSNumber from double-backed.
            let objcType = String(cString: number.objCType)
            if objcType == "d" || objcType == "f" {
                self = .number(number.doubleValue)
            } else {
                self = .integer(number.int64Value)
            }
        case let string as String:
            self = .string(string)
        case let array as [Any]:
            self = .array(try array.map(JSONValue.init(foundation:)))
        case let dict as [String: Any]:
            var result: [String: JSONValue] = [:]
            result.reserveCapacity(dict.count)
            for (key, entry) in dict {
                result[key] = try JSONValue(foundation: entry)
            }
            self = .object(result)
        default:
            throw JSONValueError.unsupportedFoundationType(String(describing: type(of: value)))
        }
    }

    /// Re-encode a Codable value as a ``JSONValue``.
    public init<T: Encodable>(encoding value: T, encoder: JSONEncoder = .init()) throws {
        let data = try encoder.encode(value)
        self = try JSONDecoder().decode(JSONValue.self, from: data)
    }

    /// Decode a Codable value from this ``JSONValue``.
    public func decode<T: Decodable>(
        as type: T.Type,
        decoder: JSONDecoder = .init()
    ) throws -> T {
        let data = try JSONEncoder().encode(self)
        return try decoder.decode(T.self, from: data)
    }
}

/// Errors produced while converting between JSONValue and Foundation/Codable.
public enum JSONValueError: Error, Sendable, Equatable {
    /// The Foundation graph contained a type that is not representable as JSON.
    case unsupportedFoundationType(String)
}
