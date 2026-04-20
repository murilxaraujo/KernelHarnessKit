import Foundation

/// A small JSON Schema representation used for describing tool inputs and
/// structured-output response formats.
///
/// This is intentionally scoped to the subset of JSON Schema that OpenAI,
/// Anthropic, and MCP servers interpret — not a complete implementation. It
/// serializes to a dictionary via ``JSONSchema/dictionary`` and to a typed
/// ``JSONValue`` via ``JSONSchema/jsonValue``.
///
/// Use the static builders (`string(description:)`, `object(properties:required:)`, etc.)
/// to compose schemas; they yield ergonomic, readable call-sites:
///
/// ```swift
/// let schema = JSONSchema.object(
///     properties: [
///         "path": .string(description: "Absolute file path"),
///         "content": .string(description: "File contents"),
///     ],
///     required: ["path", "content"]
/// )
/// ```
public struct JSONSchema: Sendable, Hashable, Codable {
    /// The JSON Schema primitive type (`string`, `integer`, `object`…).
    public enum PrimitiveType: String, Sendable, Hashable, Codable {
        case string, integer, number, boolean, object, array, null
    }

    /// The declared primitive type, if any.
    public var type: PrimitiveType?

    /// Free-form description shown to the model.
    public var description: String?

    /// `enum` values, if this schema constrains its value to a fixed set.
    public var enumValues: [JSONValue]?

    /// `const`, if this schema fixes a single value.
    public var const: JSONValue?

    /// Properties, when ``type`` is ``PrimitiveType/object``.
    public var properties: [String: JSONSchema]?

    /// Required property names, when ``type`` is ``PrimitiveType/object``.
    public var required: [String]?

    /// Whether additional properties are allowed (defaults to provider-specific
    /// behavior when `nil`). Most providers reject extras when this is `false`.
    public var additionalProperties: Bool?

    /// Item schema, when ``type`` is ``PrimitiveType/array``.
    public var items: Box<JSONSchema>?

    /// Minimum items, when ``type`` is ``PrimitiveType/array``.
    public var minItems: Int?

    /// Maximum items, when ``type`` is ``PrimitiveType/array``.
    public var maxItems: Int?

    /// Minimum value, when ``type`` is ``PrimitiveType/number`` or ``PrimitiveType/integer``.
    public var minimum: Double?

    /// Maximum value, when ``type`` is ``PrimitiveType/number`` or ``PrimitiveType/integer``.
    public var maximum: Double?

    /// Regex pattern, when ``type`` is ``PrimitiveType/string``.
    public var pattern: String?

    /// Named `anyOf` branches.
    public var anyOf: [JSONSchema]?

    /// Memberwise initializer. Prefer the static builders for common cases.
    public init(
        type: PrimitiveType? = nil,
        description: String? = nil,
        enumValues: [JSONValue]? = nil,
        const: JSONValue? = nil,
        properties: [String: JSONSchema]? = nil,
        required: [String]? = nil,
        additionalProperties: Bool? = nil,
        items: JSONSchema? = nil,
        minItems: Int? = nil,
        maxItems: Int? = nil,
        minimum: Double? = nil,
        maximum: Double? = nil,
        pattern: String? = nil,
        anyOf: [JSONSchema]? = nil
    ) {
        self.type = type
        self.description = description
        self.enumValues = enumValues
        self.const = const
        self.properties = properties
        self.required = required
        self.additionalProperties = additionalProperties
        self.items = items.map(Box.init)
        self.minItems = minItems
        self.maxItems = maxItems
        self.minimum = minimum
        self.maximum = maximum
        self.pattern = pattern
        self.anyOf = anyOf
    }

    /// Heap-allocated wrapper so JSONSchema can contain itself without Swift
    /// rejecting the recursive value-type layout.
    public final class Box<T: Sendable & Hashable & Codable>:
        @unchecked Sendable, Hashable, Codable
    {
        public let value: T
        public init(_ value: T) { self.value = value }

        public static func == (lhs: Box<T>, rhs: Box<T>) -> Bool {
            lhs.value == rhs.value
        }

        public func hash(into hasher: inout Hasher) { hasher.combine(value) }

        public required init(from decoder: Decoder) throws {
            self.value = try T(from: decoder)
        }

        public func encode(to encoder: Encoder) throws {
            try value.encode(to: encoder)
        }
    }
}

// MARK: - Builders

extension JSONSchema {
    /// A string schema.
    public static func string(
        description: String? = nil,
        enum enumValues: [String]? = nil,
        pattern: String? = nil
    ) -> JSONSchema {
        JSONSchema(
            type: .string,
            description: description,
            enumValues: enumValues?.map(JSONValue.string),
            pattern: pattern
        )
    }

    /// An integer schema.
    public static func integer(
        description: String? = nil,
        minimum: Int? = nil,
        maximum: Int? = nil
    ) -> JSONSchema {
        JSONSchema(
            type: .integer,
            description: description,
            minimum: minimum.map(Double.init),
            maximum: maximum.map(Double.init)
        )
    }

    /// A floating-point schema.
    public static func number(
        description: String? = nil,
        minimum: Double? = nil,
        maximum: Double? = nil
    ) -> JSONSchema {
        JSONSchema(
            type: .number,
            description: description,
            minimum: minimum,
            maximum: maximum
        )
    }

    /// A boolean schema.
    public static func boolean(description: String? = nil) -> JSONSchema {
        JSONSchema(type: .boolean, description: description)
    }

    /// An object schema.
    public static func object(
        properties: [String: JSONSchema],
        required: [String]? = nil,
        additionalProperties: Bool? = false,
        description: String? = nil
    ) -> JSONSchema {
        JSONSchema(
            type: .object,
            description: description,
            properties: properties,
            required: required,
            additionalProperties: additionalProperties
        )
    }

    /// An array schema.
    public static func array(
        items: JSONSchema,
        description: String? = nil,
        minItems: Int? = nil,
        maxItems: Int? = nil
    ) -> JSONSchema {
        JSONSchema(
            type: .array,
            description: description,
            items: items,
            minItems: minItems,
            maxItems: maxItems
        )
    }

    /// A `const` schema fixing the value to a single literal.
    public static func const(_ value: JSONValue, description: String? = nil) -> JSONSchema {
        JSONSchema(description: description, const: value)
    }

    /// A permissive schema that matches any JSON value.
    public static let any = JSONSchema()
}

// MARK: - Codable keys

extension JSONSchema {
    private enum CodingKeys: String, CodingKey {
        case type
        case description
        case enumValues = "enum"
        case const
        case properties
        case required
        case additionalProperties
        case items
        case minItems
        case maxItems
        case minimum
        case maximum
        case pattern
        case anyOf
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.type = try c.decodeIfPresent(PrimitiveType.self, forKey: .type)
        self.description = try c.decodeIfPresent(String.self, forKey: .description)
        self.enumValues = try c.decodeIfPresent([JSONValue].self, forKey: .enumValues)
        self.const = try c.decodeIfPresent(JSONValue.self, forKey: .const)
        self.properties = try c.decodeIfPresent([String: JSONSchema].self, forKey: .properties)
        self.required = try c.decodeIfPresent([String].self, forKey: .required)
        self.additionalProperties = try c.decodeIfPresent(Bool.self, forKey: .additionalProperties)
        if let nested = try c.decodeIfPresent(JSONSchema.self, forKey: .items) {
            self.items = Box(nested)
        }
        self.minItems = try c.decodeIfPresent(Int.self, forKey: .minItems)
        self.maxItems = try c.decodeIfPresent(Int.self, forKey: .maxItems)
        self.minimum = try c.decodeIfPresent(Double.self, forKey: .minimum)
        self.maximum = try c.decodeIfPresent(Double.self, forKey: .maximum)
        self.pattern = try c.decodeIfPresent(String.self, forKey: .pattern)
        self.anyOf = try c.decodeIfPresent([JSONSchema].self, forKey: .anyOf)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(type, forKey: .type)
        try c.encodeIfPresent(description, forKey: .description)
        try c.encodeIfPresent(enumValues, forKey: .enumValues)
        try c.encodeIfPresent(const, forKey: .const)
        try c.encodeIfPresent(properties, forKey: .properties)
        try c.encodeIfPresent(required, forKey: .required)
        try c.encodeIfPresent(additionalProperties, forKey: .additionalProperties)
        try c.encodeIfPresent(items?.value, forKey: .items)
        try c.encodeIfPresent(minItems, forKey: .minItems)
        try c.encodeIfPresent(maxItems, forKey: .maxItems)
        try c.encodeIfPresent(minimum, forKey: .minimum)
        try c.encodeIfPresent(maximum, forKey: .maximum)
        try c.encodeIfPresent(pattern, forKey: .pattern)
        try c.encodeIfPresent(anyOf, forKey: .anyOf)
    }
}

// MARK: - Serialization

extension JSONSchema {
    /// A ``JSONValue`` representation of this schema.
    public var jsonValue: JSONValue {
        // Round-trip through JSONEncoder/Decoder so Codable is the single
        // source of truth for what keys this schema serializes.
        do {
            return try JSONValue(encoding: self)
        } catch {
            return .object([:])
        }
    }

    /// A Foundation dictionary representation, suitable for APIs that take
    /// `[String: Any]` schemas (such as the OpenAI function-calling payload).
    public var dictionary: [String: Any] {
        (jsonValue.foundationValue as? [String: Any]) ?? [:]
    }
}
