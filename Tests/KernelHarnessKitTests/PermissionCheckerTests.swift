import Testing
import Foundation
@testable import KernelHarnessKit

@Suite("DefaultPermissionChecker")
struct PermissionCheckerTests {
    @Test func autoAllowsEverything() {
        let checker = DefaultPermissionChecker(mode: .auto)
        let d = checker.evaluate(toolName: "write_file", isReadOnly: false, filePath: "x", command: nil)
        #expect(d.allowed)
        #expect(d.requiresConfirmation == false)
    }

    @Test func readOnlyBlocksWrites() {
        let checker = DefaultPermissionChecker(mode: .readOnly)
        #expect(checker.evaluate(toolName: "read_file", isReadOnly: true, filePath: nil, command: nil).allowed)
        #expect(
            checker.evaluate(toolName: "write_file", isReadOnly: false, filePath: nil, command: nil).allowed == false
        )
    }

    @Test func defaultAsksForWrites() {
        let checker = DefaultPermissionChecker(mode: .default)
        let reads = checker.evaluate(toolName: "read_file", isReadOnly: true, filePath: nil, command: nil)
        #expect(reads.allowed)
        #expect(reads.requiresConfirmation == false)

        let writes = checker.evaluate(toolName: "write_file", isReadOnly: false, filePath: nil, command: nil)
        #expect(writes.allowed)
        #expect(writes.requiresConfirmation == true)
    }

    @Test func customPolicyToolOverride() {
        let policy = PermissionPolicy(toolOverrides: ["write_file": .deny])
        let checker = DefaultPermissionChecker(mode: .custom(policy))
        let d = checker.evaluate(toolName: "write_file", isReadOnly: false, filePath: nil, command: nil)
        #expect(d.allowed == false)
    }

    @Test func customPolicyPathRule() {
        let policy = PermissionPolicy(pathRules: [
            PathRule(pattern: "/tmp/**", permission: .allow),
            PathRule(pattern: "/etc/**", permission: .deny),
        ])
        let checker = DefaultPermissionChecker(mode: .custom(policy))
        #expect(
            checker.evaluate(toolName: "write_file", isReadOnly: false, filePath: "/tmp/x", command: nil).allowed
        )
        #expect(
            checker.evaluate(toolName: "write_file", isReadOnly: false, filePath: "/etc/passwd", command: nil).allowed == false
        )
    }

    @Test func customPolicyCommandDenyList() {
        let policy = PermissionPolicy(commandDenyList: ["rm -rf"])
        let checker = DefaultPermissionChecker(mode: .custom(policy))
        #expect(
            checker.evaluate(toolName: "shell", isReadOnly: false, filePath: nil, command: "rm -rf /").allowed == false
        )
    }

    @Test func globMatcher() {
        #expect(GlobMatcher.matches(path: "/a/b/c.txt", pattern: "/a/**"))
        #expect(GlobMatcher.matches(path: "/a/b.txt", pattern: "/a/*.txt"))
        #expect(GlobMatcher.matches(path: "/a/b/c.txt", pattern: "/a/*.txt") == false)
        #expect(GlobMatcher.matches(path: "abc", pattern: "a?c"))
        #expect(GlobMatcher.matches(path: "ac", pattern: "a?c") == false)
    }
}
