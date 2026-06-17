import Foundation

/// Small validator for the JSON Schema subset used by phase output validation.
enum PhaseOutputSchemaValidator {
    static func validate(_ value: JSONValue, against schema: JSONSchema, path: String = "$") throws {
        if let const = schema.const, value != const {
            throw HarnessError.outputValidationFailed(phase: "", reason: "\(path) must equal const value")
        }
        if let enumValues = schema.enumValues, !enumValues.contains(value) {
            throw HarnessError.outputValidationFailed(phase: "", reason: "\(path) is not one of the allowed enum values")
        }
        if let anyOf = schema.anyOf, !anyOf.isEmpty {
            for branch in anyOf {
                do {
                    try validate(value, against: branch, path: path)
                    return
                } catch {
                    continue
                }
            }
            throw HarnessError.outputValidationFailed(phase: "", reason: "\(path) did not match any schema branch")
        }

        if let type = schema.type {
            try validateType(value, type: type, path: path)
        }

        switch value {
        case .string(let string):
            if let pattern = schema.pattern,
               string.range(of: pattern, options: .regularExpression) == nil {
                throw HarnessError.outputValidationFailed(phase: "", reason: "\(path) does not match pattern")
            }
        case .integer(let int):
            try validateNumber(Double(int), schema: schema, path: path)
        case .number(let number):
            try validateNumber(number, schema: schema, path: path)
        case .array(let array):
            if let min = schema.minItems, array.count < min {
                throw HarnessError.outputValidationFailed(phase: "", reason: "\(path) has fewer than \(min) items")
            }
            if let max = schema.maxItems, array.count > max {
                throw HarnessError.outputValidationFailed(phase: "", reason: "\(path) has more than \(max) items")
            }
            if let itemSchema = schema.items?.value {
                for (index, item) in array.enumerated() {
                    try validate(item, against: itemSchema, path: "\(path)[\(index)]")
                }
            }
        case .object(let object):
            for key in schema.required ?? [] where object[key] == nil {
                throw HarnessError.outputValidationFailed(phase: "", reason: "\(path).\(key) is required")
            }
            if let properties = schema.properties {
                for (key, propertySchema) in properties {
                    if let propertyValue = object[key] {
                        try validate(propertyValue, against: propertySchema, path: "\(path).\(key)")
                    }
                }
                if schema.additionalProperties == false {
                    let allowed = Set(properties.keys)
                    if let extra = object.keys.first(where: { !allowed.contains($0) }) {
                        throw HarnessError.outputValidationFailed(phase: "", reason: "\(path).\(extra) is not allowed")
                    }
                }
            }
        case .bool, .null:
            break
        }
    }

    private static func validateType(_ value: JSONValue, type: JSONSchema.PrimitiveType, path: String) throws {
        let matches: Bool
        switch (value, type) {
        case (.string, .string), (.integer, .integer), (.number, .number), (.bool, .boolean), (.object, .object), (.array, .array), (.null, .null):
            matches = true
        case (.integer, .number):
            matches = true
        default:
            matches = false
        }
        if !matches {
            throw HarnessError.outputValidationFailed(phase: "", reason: "\(path) is not a \(type.rawValue)")
        }
    }

    private static func validateNumber(_ number: Double, schema: JSONSchema, path: String) throws {
        if let minimum = schema.minimum, number < minimum {
            throw HarnessError.outputValidationFailed(phase: "", reason: "\(path) is less than \(minimum)")
        }
        if let maximum = schema.maximum, number > maximum {
            throw HarnessError.outputValidationFailed(phase: "", reason: "\(path) is greater than \(maximum)")
        }
    }
}
