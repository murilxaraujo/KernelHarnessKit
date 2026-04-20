import Testing
@testable import KernelHarnessKit

@Test
func packageExposesVersion() {
    #expect(KHK.version == "0.1.0")
}
