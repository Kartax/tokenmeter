import XCTest
@testable import TokenMeter

/// Reset/renewal times: relative within 24 h, absolute otherwise; Credit balance lines.
final class DisplayFormatTests: XCTestCase {
    private let format = DisplayFormat(timeZone: TimeZone(identifier: "UTC")!)
    private let now = date("2026-10-18T12:00:00Z") // a Sunday

    func testResetWithin24HoursIsRelative() {
        XCTAssertEqual(format.resetTime(date("2026-10-18T14:14:00Z"), now: now), "in 2 h 14 m")
        XCTAssertEqual(format.resetTime(date("2026-10-18T12:09:30Z"), now: now), "in 9 m")
        XCTAssertEqual(format.resetTime(date("2026-10-19T11:59:00Z"), now: now), "in 23 h 59 m")
    }

    func testResetWithinAWeekIsWeekdayAndTime() {
        XCTAssertEqual(format.resetTime(date("2026-10-19T12:00:00Z"), now: now), "Mon 12:00")
        XCTAssertEqual(format.resetTime(date("2026-10-20T09:00:00Z"), now: now), "Tue 09:00")
    }

    func testResetFurtherAwayIsDayAndMonth() {
        XCTAssertEqual(format.resetTime(date("2026-11-03T09:30:00Z"), now: now), "3 Nov")
    }

    func testResetInThePastIsNow() {
        XCTAssertEqual(format.resetTime(date("2026-10-18T11:00:00Z"), now: now), "now")
    }

    func testCreditDetailShowsPercentUsedAndRenewal() {
        let balance = CreditBalance(id: "included", title: "Monthly credits", remaining: Decimal(string: "41.2")!,
                                    allowance: 60, currency: "USD", renewsAt: date("2026-11-03T09:30:00Z"),
                                    isMain: true)
        XCTAssertEqual(format.creditDetail(balance, now: now), "31% used · renews 3 Nov")
    }

    func testCreditDetailOmitsMissingRenewal() {
        let balance = CreditBalance(id: "included", title: "Monthly credits", remaining: Decimal(string: "41.2")!,
                                    allowance: 60, currency: "USD", renewsAt: nil, isMain: true)
        XCTAssertEqual(format.creditDetail(balance, now: now), "31% used")
    }

    func testCreditBalanceWithoutAllowance() {
        let balance = CreditBalance(id: "purchased", title: "Purchased credits", remaining: 25,
                                    allowance: nil, currency: "USD", renewsAt: nil, isMain: false)
        XCTAssertEqual(format.creditLine(balance, now: now), "$25 left")
    }

    func testCreditBalanceWithoutAllowanceIncludesRenewal() {
        let balance = CreditBalance(id: "premium", title: "Premium requests", remaining: 25,
                                    allowance: nil, currency: "USD", renewsAt: date("2026-11-03T09:30:00Z"),
                                    isMain: true)
        XCTAssertEqual(format.creditLine(balance, now: now), "$25 left, renews 3 Nov")
    }

    func testNonMonetaryCreditsAreCountedNotPriced() {
        let balance = CreditBalance(id: "credits", title: "Credits", remaining: Decimal(string: "14.5")!,
                                    allowance: nil, currency: CreditBalance.creditsUnit, renewsAt: nil, isMain: false)
        XCTAssertEqual(format.creditLine(balance, now: now), "14.50 credits left")
    }
}
