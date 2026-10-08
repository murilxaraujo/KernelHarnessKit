import Testing
@testable import KernelHarnessKit

@Test
func packageExposesVersion() {
    #expect(KHK.version == "0.3.0")
}
