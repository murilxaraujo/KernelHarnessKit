import Foundation
import KernelHarnessKit

/// Reconstructs `ContentBlock.toolUse` values from Anthropic's streaming
/// `input_json_delta` fragments.
///
/// Events arrive as: `content_block_start(index, id, name)` → N ×
/// `content_block_delta(index, partial_json)` → `content_block_stop(index)`.
/// We concatenate the partials per index and parse the resulting JSON when the
/// block stops.
struct ToolUseAccumulator {
    private var slots: [Int: Slot] = [:]

    struct Slot {
        let id: String
        let name: String
        var partialJSON: String
    }

    mutating func begin(index: Int, id: String, name: String) {
        slots[index] = Slot(id: id, name: name, partialJSON: "")
    }

    mutating func append(index: Int, partialJSON: String) {
        guard slots[index] != nil else { return }
        slots[index]?.partialJSON.append(partialJSON)
    }

    /// Finalize the block at `index` and produce a `ContentBlock.toolUse`.
    /// Returns `nil` if this index was never opened as a tool_use (e.g. it was
    /// a text or thinking block).
    mutating func finalize(index: Int) -> ContentBlock? {
        guard let slot = slots.removeValue(forKey: index) else { return nil }
        let raw = slot.partialJSON.isEmpty ? "{}" : slot.partialJSON
        let input: [String: JSONValue]
        if let data = raw.data(using: .utf8),
           let parsed = try? JSONDecoder().decode([String: JSONValue].self, from: data) {
            input = parsed
        } else {
            input = [:]
        }
        return .toolUse(id: slot.id, name: slot.name, input: input)
    }
}
