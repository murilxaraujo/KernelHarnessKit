import Foundation

/// The shape the model should produce for its next message.
///
/// Provider implementations translate this to their native representation
/// (OpenAI `response_format`, Anthropic `response_format`, Gemini `responseMimeType`).
public enum ResponseFormat: Sendable, Hashable {
    /// Plain free-form text.
    case text

    /// Any valid JSON object — the model is told to output JSON but the shape
    /// is unconstrained.
    case jsonObject

    /// JSON matching a specific schema. Supported natively by recent OpenAI
    /// models via `response_format: { type: "json_schema", ... }`.
    case jsonSchema(name: String, schema: JSONSchema, strict: Bool = true)
}
