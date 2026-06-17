import Foundation
import KernelHarnessKit

#if canImport(FoundationModels)
import FoundationModels

@available(iOS 27.0, macOS 27.0, visionOS 27.0, *)
@available(watchOS, unavailable)
@available(tvOS, unavailable)
public enum AppleHarnessModels {
    public static func system(
        _ model: SystemLanguageModel = .default
    ) -> FoundationLanguageModelHarnessModel<SystemLanguageModel> {
        FoundationLanguageModelHarnessModel(model)
    }
}

@available(iOS 27.0, macOS 27.0, visionOS 27.0, watchOS 27.0, *)
@available(tvOS, unavailable)
public extension AppleHarnessModels {
    static func privateCloudCompute() -> FoundationLanguageModelHarnessModel<PrivateCloudComputeLanguageModel> {
        FoundationLanguageModelHarnessModel(PrivateCloudComputeLanguageModel())
    }
}

#endif
