import XCTest

@MainActor
final class StoreKitQualificationTests: XCTestCase {
    func testLocalLifetimeRestoreAndRefund() async throws {
        let fixture = NativeStoreKitRestore()
        try fixture.prepare(configurationURL: Bundle(for: Self.self).url(forResource: "Qualification", withExtension: "storekit"))
        defer { fixture.reset() }
        let empty = await fixture.restore()
        XCTAssertFalse(empty)
        try await fixture.seedLifetime()
        let restored = await fixture.restore()
        XCTAssertTrue(restored)
        try fixture.revoke()
        let revoked = await fixture.restore()
        XCTAssertFalse(revoked)
    }
}
