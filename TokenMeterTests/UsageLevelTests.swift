import XCTest
@testable import TokenMeter

/// Bar colour levels: normal below 75%, warning from 75%, critical from 90% and at the limit.
final class UsageLevelTests: XCTestCase {
    private func level(_ percentUsed: Double) -> UsageLevel {
        Quota(window: Window(identity: .session, title: "Session", isMain: true), percentUsed: percentUsed).level
    }

    func testLevelsByPercentUsed() {
        XCTAssertEqual(level(0), .normal)
        XCTAssertEqual(level(74.9), .normal)
        XCTAssertEqual(level(75), .warning)
        XCTAssertEqual(level(89.9), .warning)
        XCTAssertEqual(level(90), .critical)
        XCTAssertEqual(level(100), .critical)
    }

    func testOverTheLimitIsCriticalAndShownAsLimitReached() {
        let quota = Quota(window: Window(identity: .week, title: "Week", isMain: true), percentUsed: 130)
        XCTAssertEqual(quota.level, .critical)
        XCTAssertEqual(quota.percentUsed, 100)
        XCTAssertTrue(quota.limitReached)
    }
}
