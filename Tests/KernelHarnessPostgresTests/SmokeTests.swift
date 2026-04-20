import Testing
@testable import KernelHarnessPostgres

@Test
func postgresTargetExposesVersion() {
    #expect(KHKPostgres.version == "0.1.0")
}
