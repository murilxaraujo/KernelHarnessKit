import Foundation

/// The framework's own metadata.
///
/// Kept as a caseless enum rather than the module-level, so it doesn't shadow
/// the `KernelHarnessKit` module name and allow consumers to use
/// `KernelHarnessKit.Thread` (vs Foundation's `Thread`) to disambiguate.
public enum KHK {
    /// Semantic version of the framework.
    public static let version = "0.1.0"
}
