import XCTest
@testable import TokenMeter

/// Percent used derived from a Credit balance's remaining amount and its allowance.
final class CreditBalanceTests: XCTestCase {
    private func credit(remaining: String, allowance: String?) -> CreditBalance {
        CreditBalance(id: "included", title: "Monthly credits", remaining: Decimal(string: remaining)!,
                      allowance: allowance.map { Decimal(string: $0)! }, currency: "USD",
                      renewsAt: nil, isMain: true)
    }

    func testPercentUsedFromRemainingAndAllowance() {
        XCTAssertEqual(credit(remaining: "41.2", allowance: "60").percentUsed!, 31.333, accuracy: 0.001)
        XCTAssertEqual(credit(remaining: "0", allowance: "60").percentUsed, 100)
        XCTAssertEqual(credit(remaining: "60", allowance: "60").percentUsed, 0)
    }

    func testRolloverBalanceReadsAsNothingUsed() {
        XCTAssertEqual(credit(remaining: "75", allowance: "60").percentUsed, 0)
    }

    func testOverdrawnBalanceIsClampedTo100() {
        XCTAssertEqual(credit(remaining: "-5", allowance: "60").percentUsed, 100)
    }

    func testNoOrZeroAllowanceHasNoPercent() {
        XCTAssertNil(credit(remaining: "41.2", allowance: nil).percentUsed)
        XCTAssertNil(credit(remaining: "41.2", allowance: "0").percentUsed)
    }
}
