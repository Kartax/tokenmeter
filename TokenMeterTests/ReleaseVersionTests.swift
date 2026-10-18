import XCTest
@testable import TokenMeter

final class ReleaseVersionTests: XCTestCase {
    func testTaggedReleaseWithHigherMinorIsNewerThanBundleVersion() throws {
        let latest = try XCTUnwrap(ReleaseVersion("v0.2.0"))
        let current = try XCTUnwrap(ReleaseVersion("0.1.0"))
        XCTAssertGreaterThan(latest, current)
    }

    func testComponentsCompareNumericallyNotAlphabetically() throws {
        let latest = try XCTUnwrap(ReleaseVersion("v0.10.0"))
        let current = try XCTUnwrap(ReleaseVersion("0.9.3"))
        XCTAssertGreaterThan(latest, current)
    }

    func testMissingTrailingComponentsCountAsZero() throws {
        let latest = try XCTUnwrap(ReleaseVersion("v0.2"))
        let current = try XCTUnwrap(ReleaseVersion("0.2.0"))
        XCTAssertEqual(latest, current)
        XCTAssertFalse(latest > current)
    }
}
