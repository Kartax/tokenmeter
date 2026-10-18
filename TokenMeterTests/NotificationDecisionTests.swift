import XCTest
@testable import TokenMeter

/// Seam B: Readings + settings + global switch + already-notified set → notifications to send
/// and the updated set. Pure function; the clock is injected by comparing against a fixed now.
final class NotificationDecisionTests: XCTestCase {
    // MARK: - Fixtures

    private var accountID = UUID()

    /// Empty key set for a single Account; `now` is the decision moment.
    private var keySet: NotifiedKeySet { NotifiedKeySet(keys: []) }
    private var now = date("2026-10-18T12:00:00Z")

    private func account(threshold: NotificationThreshold = .default, showAll: Bool = false) -> (Account, AccountNotificationSettings) {
        let account = Account(id: accountID, kind: .ollama, label: "Personal", threshold: threshold,
                              showAllWindows: showAll)
        return (account, AccountNotificationSettings(threshold: threshold, showAllWindows: showAll))
    }

    private func quota(_ percent: Double, identity: WindowIdentity = .session, isMain: Bool = true,
                       resetsAt: Date? = date("2026-10-18T17:00:00Z")) -> Quota {
        Quota(window: Window(identity: identity, title: "Session", isMain: isMain, resetsAt: resetsAt), percentUsed: percent)
    }

    private func credit(allowance: String, remaining: String, renewsAt: Date? = date("2026-11-03T09:30:00Z"),
                        isMain: Bool = true) -> CreditBalance {
        CreditBalance(id: "included", title: "Monthly credits", remaining: Decimal(string: remaining)!,
                      allowance: allowance == "" ? nil : Decimal(string: allowance)!,
                      currency: "USD", renewsAt: renewsAt, isMain: isMain)
    }

    private func reading(_ quotas: [Quota], _ credits: [CreditBalance]) -> Reading {
        Reading(accountID: accountID, takenAt: now, quotas: quotas, credits: credits)
    }

    // MARK: - No notifications

    func testThresholdOffProducesNoNotificationAndKeepsTheSet() {
        let (account, settings) = account(threshold: .off)
        let decision = NotificationDecision.decide(new: reading([quota(100)], []),
                                                   account: account, settings: settings,
                                                   notificationsEnabled: true, notified: keySet, now: now)
        XCTAssertTrue(decision.notifications.isEmpty)
        XCTAssertTrue(decision.notified.keys.isEmpty)
    }

    /// A silenced decision returns the set unchanged, so re-enabling cannot re-fire within the
    /// same reset periods.
    func testSilencedDecisionKeepsTheNotifiedSetIntact() {
        let silenced: [(enabled: Bool, threshold: NotificationThreshold)] = [(false, .p90), (true, .off)]
        for silencedCase in silenced {
            let (account, settings) = account(threshold: silencedCase.threshold)
            let decision = NotificationDecision.decide(
                new: reading([quota(100)], [credit(allowance: "60", remaining: "1")]),
                account: account, settings: settings,
                notificationsEnabled: silencedCase.enabled, notified: keySet, now: now)
            XCTAssertTrue(decision.notifications.isEmpty, "silenced case \(silencedCase)")
            XCTAssertTrue(decision.notified.keys.isEmpty,
                          "the empty set is kept when silenced (case \(silencedCase))")
            // The still-active keys survive a silenced decision in both directions.
            let active = NotifiedKeySet(keys: [NotifiedKey(accountID: accountID, window: .week,
                                                           resetAt: date("2026-10-25T09:00:00Z"))])
            let withKeys = NotificationDecision.decide(new: reading([quota(100)], []),
                                                       account: account, settings: settings,
                                                       notificationsEnabled: silencedCase.enabled,
                                                       notified: active, now: now)
            XCTAssertEqual(withKeys.notified, active, "keys survive while silenced (case \(silencedCase))")
        }
    }

    /// A show-all-off Account's non-main Credit balance produces nothing.
    func testHiddenCreditWithoutShowAllProducesNoNotification() {
        let (hiddenAccount, hiddenSettings) = account()
        let hidden = credit(allowance: "60", remaining: "1", isMain: false)
        let decision = NotificationDecision.decide(new: reading([], [hidden]),
                                                   account: hiddenAccount, settings: hiddenSettings,
                                                   notificationsEnabled: true, notified: keySet, now: now)
        XCTAssertTrue(decision.notifications.isEmpty, "a non-main balance is hidden without show-all")
        XCTAssertTrue(decision.notified.keys.isEmpty, "no key is recorded for a hidden balance")

        let (shownAccount, shownSettings) = account(threshold: .default, showAll: true)
        let shown = NotificationDecision.decide(new: reading([], [hidden]),
                                                account: shownAccount, settings: shownSettings,
                                                notificationsEnabled: true, notified: keySet, now: now)
        XCTAssertEqual(shown.notifications.count, 1, "show-all reveals the non-main balance")
    }

    /// A show-all-off Account's non-main Window produces nothing (hidden Windows stay hidden).
    func testHiddenWindowWithoutShowAllProducesNoNotification() {
        let (account, settings) = account()
        let scoped = quota(95, identity: .scoped("seven_day_sonnet"), isMain: false)
        let decision = NotificationDecision.decide(new: reading([scoped], []),
                                                   account: account, settings: settings,
                                                   notificationsEnabled: true, notified: keySet, now: now)
        XCTAssertTrue(decision.notifications.isEmpty, "a non-main Window is hidden without show-all")
        XCTAssertTrue(decision.notified.keys.isEmpty, "no key is recorded for a hidden Window")
    }

    func testGlobalSwitchOffProducesNoNotification() {
        let (account, settings) = account()
        let decision = NotificationDecision.decide(new: reading([quota(100)], []),
                                                   account: account, settings: settings,
                                                   notificationsEnabled: false, notified: keySet, now: now)
        XCTAssertTrue(decision.notifications.isEmpty)
        XCTAssertTrue(decision.notified.keys.isEmpty)
    }

    func testBelowThresholdProducesNoNotification() {
        let (account, settings) = account(threshold: .p90)
        let decision = NotificationDecision.decide(new: reading([quota(89.9)], []),
                                                   account: account, settings: settings,
                                                   notificationsEnabled: true, notified: keySet, now: now)
        XCTAssertTrue(decision.notifications.isEmpty)
        XCTAssertTrue(decision.notified.keys.isEmpty)
    }

    func testCrossingWithoutResetTimeProducesNoNotification() {
        // Without a reset time the key would repeat across periods; never notify.
        let (account, settings) = account()
        let noReset = Quota(window: Window(identity: .session, title: "Session", isMain: true), percentUsed: 95)
        let decision = NotificationDecision.decide(new: reading([noReset], []),
                                                   account: account, settings: settings,
                                                   notificationsEnabled: true, notified: keySet, now: now)
        XCTAssertTrue(decision.notifications.isEmpty)
    }

    // MARK: - Crossing at the thresholds

    func testCrossingAtTheThresholdNotifies() {
        for (threshold, percent) in [(NotificationThreshold.p80, 80.0), (.p90, 90.0), (.p95, 95.0)] {
            let (account, settings) = account(threshold: threshold)
            let decision = NotificationDecision.decide(
                new: reading([quota(percent)], []),
                account: account, settings: settings,
                notificationsEnabled: true, notified: keySet, now: now)
            XCTAssertEqual(decision.notifications.count, 1, "\(threshold) at \(percent)%")
            XCTAssertEqual(decision.notifications.first?.title, "Session at \(Int(percent))% used")
        }
    }

    // MARK: - Only visible Windows

    func testHiddenScopedWindowIsIgnoredUnlessShowAllIsOn() {
        let (hidden, hiddenSettings) = account(threshold: .p90, showAll: false)
        let scoped = quota(95, identity: .scoped("seven_day_sonnet"), isMain: false)
        let hiddenDecision = NotificationDecision.decide(new: reading([], []),
                                                         account: hidden, settings: hiddenSettings,
                                                         notificationsEnabled: true, notified: keySet, now: now)
        _ = hiddenDecision

        let (shown, shownSettings) = account(threshold: .p90, showAll: true)
        let shownDecision = NotificationDecision.decide(
            new: reading([scoped], []),
            account: shown, settings: shownSettings,
            notificationsEnabled: true, notified: keySet, now: now)
        XCTAssertEqual(shownDecision.notifications.count, 1)

        let againHidden = NotificationDecision.decide( new: reading([scoped], []),
            account: hidden, settings: hiddenSettings,
            notificationsEnabled: true, notified: keySet, now: now)
        XCTAssertTrue(againHidden.notifications.isEmpty, "hidden scoped Windows stay hidden without show-all")
    }

    func testCreditBalanceBelowTenPercentNotifiesOnce() {
        let (account, settings) = account()
        let decision = NotificationDecision.decide( new: reading([], [credit(allowance: "60", remaining: "5.99")]),
            account: account, settings: settings, notificationsEnabled: true, notified: keySet, now: now)
        XCTAssertEqual(decision.notifications.count, 1)
        XCTAssertEqual(decision.notified.keys.count, 1)
        let again = NotificationDecision.decide( new: reading([], [credit(allowance: "60", remaining: "5.99")]),
            account: account, settings: settings, notificationsEnabled: true,
            notified: decision.notified, now: now)
        XCTAssertTrue(again.notifications.isEmpty, "at most once per renewal period")
    }

    func testCreditAtOrAboveTenPercentProducesNoNotification() {
        let (account, settings) = account()
        let decision = NotificationDecision.decide( new: reading([], [credit(allowance: "60", remaining: "6.00")]),
            account: account, settings: settings, notificationsEnabled: true, notified: keySet, now: now)
        XCTAssertTrue(decision.notifications.isEmpty)
    }

    func testCreditWithoutAllowanceProducesNoNotification() {
        let (account, settings) = account()
        let purchased = CreditBalance(id: "purchased", title: "Purchased credits", remaining: 1,
                                      allowance: nil, currency: "USD", renewsAt: nil, isMain: false)
        let decision = NotificationDecision.decide( new: reading([], [purchased]),
            account: account, settings: settings, notificationsEnabled: true, notified: keySet, now: now)
        XCTAssertTrue(decision.notifications.isEmpty)
    }

    // MARK: - Already-notified set

    func testRepeatInSameResetPeriodProducesNoNotification() {
        let (account, settings) = account(threshold: .p90)
        let first = NotificationDecision.decide(
            new: reading([quota(91)], []),
            account: account, settings: settings, notificationsEnabled: true, notified: keySet, now: now)
        XCTAssertEqual(first.notifications.count, 1)

        let second = NotificationDecision.decide(
            new: reading([quota(94)], []),
            account: account, settings: settings, notificationsEnabled: true, notified: first.notified, now: now)
        XCTAssertTrue(second.notifications.isEmpty, "no repeat within the same reset period")
    }

    func testKeyedPerWindow() {
        let (account, settings) = account(threshold: .p90, showAll: true)
        let reading = reading([quota(91, identity: .session), quota(95, identity: .week)], [])
        let decision = NotificationDecision.decide(new: reading,
                                                   account: account, settings: settings,
                                                   notificationsEnabled: true, notified: keySet, now: now)
        XCTAssertEqual(decision.notifications.count, 2)
        XCTAssertEqual(decision.notified.keys.count, 2, "one key per Window")
    }

    func testAfterResetANewCrossingNotifiesAgain() {
        let (account, settings) = account(threshold: .p90)
        let first = NotificationDecision.decide(
            new: reading([quota(91, resetsAt: date("2026-10-18T17:00:00Z"))], []),
            account: account, settings: settings, notificationsEnabled: true, notified: keySet, now: now)
        XCTAssertEqual(first.notifications.count, 1)

        // The Window reset (new reset time = new period): the new crossing notifies again.
        let after = NotificationDecision.decide(
            new: reading([quota(92, resetsAt: date("2026-10-19T17:00:00Z"))], []),
            account: account, settings: settings, notificationsEnabled: true,
            notified: first.notified, now: date("2026-10-19T12:00:00Z"))
        XCTAssertEqual(after.notifications.count, 1, "a new reset period notifies again")
    }

    func testKeyFromAPreviousPeriodDoesNotBlockANewCrossing() {
        // A key whose reset time differs (a new period) is a different key: the crossing
        // notifies even if the set still holds the old key.
        let (account, settings) = account(threshold: .p90)
        let oldKey = NotifiedKey(accountID: accountID, window: .session,
                                 resetAt: date("2026-10-18T17:00:00Z"))
        let set = NotifiedKeySet(keys: [oldKey])
        let decision = NotificationDecision.decide( new: reading([quota(92, resetsAt: date("2026-10-19T17:00:00Z"))], []),
            account: account, settings: settings, notificationsEnabled: true, notified: set, now: now)
        XCTAssertEqual(decision.notifications.count, 1)
        XCTAssertEqual(decision.notified.keys.contains(oldKey), true,
                       "the old key's period is still active and stays until its reset")
    }

    func testKeysWithPassedResetTimeArePruned() {
        // A key whose Window has reset (reset time passed) is no longer active and drops out.
        let pastKey = NotifiedKey(accountID: accountID, window: .session,
                                  resetAt: date("2026-10-18T11:00:00Z"))
        let activeKey = NotifiedKey(accountID: accountID, window: .week,
                                    resetAt: date("2026-10-25T11:00:00Z"))
        let pruned = NotifiedKeySet(keys: [pastKey, activeKey]).pruned(now: now)
        XCTAssertEqual(pruned.keys, [activeKey])
    }
}