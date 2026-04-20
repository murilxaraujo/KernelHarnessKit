import Testing
import Foundation
@testable import KernelHarnessKit

@Suite("JSONValue")
struct JSONValueTests {
    @Test func decodesAllPrimitives() throws {
        let payload = Data(#"""
        {
            "s": "hello",
            "i": 42,
            "d": 3.14,
            "t": true,
            "f": false,
            "n": null,
            "a": [1, "x", null],
            "o": { "k": "v" }
        }
        """#.utf8)

        let value = try JSONDecoder().decode(JSONValue.self, from: payload)

        #expect(value["s"]?.stringValue == "hello")
        #expect(value["i"]?.intValue == 42)
        #expect(value["d"]?.doubleValue == 3.14)
        #expect(value["t"]?.boolValue == true)
        #expect(value["f"]?.boolValue == false)
        #expect(value["n"]?.isNull == true)
        #expect(value["a"]?[0]?.intValue == 1)
        #expect(value["a"]?[1]?.stringValue == "x")
        #expect(value["a"]?[2]?.isNull == true)
        #expect(value["o"]?["k"]?.stringValue == "v")
    }

    @Test func codableRoundTrip() throws {
        let original: JSONValue = [
            "name": "widget",
            "count": 7,
            "tags": ["a", "b"],
            "meta": ["nested": true],
            "optional": nil,
        ]
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(JSONValue.self, from: data)
        #expect(decoded == original)
    }

    @Test func literalSyntax() {
        let value: JSONValue = [
            "a": "b",
            "c": 1,
            "d": true,
            "e": nil,
            "f": [1, 2, 3],
        ]
        #expect(value["a"]?.stringValue == "b")
        #expect(value["c"]?.intValue == 1)
        #expect(value["e"]?.isNull == true)
        #expect(value["f"]?[2]?.intValue == 3)
    }

    @Test func foundationBridge() throws {
        let value: JSONValue = ["n": 42, "s": "hello", "b": true, "a": [1, 2]]
        let fv = value.foundationValue as? [String: Any]
        #expect(fv?["s"] as? String == "hello")
        let back = try JSONValue(foundation: fv as Any)
        #expect(back == value)
    }

    @Test func encodesCodableValues() throws {
        struct Person: Codable, Equatable { let name: String; let age: Int }
        let person = Person(name: "Ada", age: 36)
        let value = try JSONValue(encoding: person)
        #expect(value["name"]?.stringValue == "Ada")
        #expect(value["age"]?.intValue == 36)

        let decoded = try value.decode(as: Person.self)
        #expect(decoded == person)
    }
}
