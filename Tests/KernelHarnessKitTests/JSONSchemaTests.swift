import Testing
import Foundation
@testable import KernelHarnessKit

@Suite("JSONSchema")
struct JSONSchemaTests {
    @Test func buildsObjectSchema() throws {
        let schema = JSONSchema.object(
            properties: [
                "path": .string(description: "Absolute path"),
                "limit": .integer(minimum: 1, maximum: 100),
            ],
            required: ["path"]
        )

        let dict = schema.dictionary
        #expect(dict["type"] as? String == "object")
        let props = dict["properties"] as? [String: Any]
        #expect(props?["path"] != nil)
        let required = dict["required"] as? [String]
        #expect(required == ["path"])
        #expect(dict["additionalProperties"] as? Bool == false)
    }

    @Test func buildsArraySchema() {
        let schema = JSONSchema.array(items: .string())
        #expect(schema.type == .array)
        #expect(schema.items?.value.type == .string)
    }

    @Test func serializesEnumValues() throws {
        let schema = JSONSchema.string(enum: ["red", "green", "blue"])
        let data = try JSONEncoder().encode(schema)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect((json?["enum"] as? [String]) == ["red", "green", "blue"])
    }

    @Test func codableRoundTrip() throws {
        let schema = JSONSchema.object(
            properties: [
                "items": .array(items: .object(properties: ["x": .integer()], required: ["x"]))
            ],
            required: ["items"]
        )
        let data = try JSONEncoder().encode(schema)
        let decoded = try JSONDecoder().decode(JSONSchema.self, from: data)
        #expect(decoded == schema)
    }
}
