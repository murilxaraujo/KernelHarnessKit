import Foundation
import KernelHarnessKit

@main
struct KBAgent {
    static func main() async throws {
        let prompt = Array(CommandLine.arguments.dropFirst()).joined(separator: " ")
        print("agent: answering \(prompt)")
    }
}
