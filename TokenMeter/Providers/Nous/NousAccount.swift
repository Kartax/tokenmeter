import Foundation

/// Tolerant model of `GET /api/oauth/account` (spec #1 Nous contract; fixture in the notes).
/// Money arrives as a JSON number or a decimal string; every field optional.
struct AccountResponse: Decodable, Sendable {
    var user: User?
    var organisation: Organisation?
    var subscription: Subscription?
    /// Top-level purchased credits; a `paid_service_access` fallback applies when this is absent.
    var purchasedCreditsRemaining: FlexibleMoney?
    var paidServiceAccess: PaidServiceAccess?

    private enum CodingKeys: String, CodingKey {
        case user, organisation, subscription, purchasedCreditsRemaining = "purchased_credits_remaining"
        case paidServiceAccess = "paid_service_access"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        user = try? c.decodeIfPresent(User.self, forKey: .user)
        organisation = try? c.decodeIfPresent(Organisation.self, forKey: .organisation)
        subscription = try? c.decodeIfPresent(Subscription.self, forKey: .subscription)
        purchasedCreditsRemaining = try? c.decodeIfPresent(FlexibleMoney.self, forKey: .purchasedCreditsRemaining)
        paidServiceAccess = try? c.decodeIfPresent(PaidServiceAccess.self, forKey: .paidServiceAccess)
    }

    var purchasedCreditBalance: CreditBalance? {
        let flexible: FlexibleMoney?
        if let purchasedCreditsRemaining {
            flexible = purchasedCreditsRemaining
        } else {
            flexible = paidServiceAccess?.purchased_credits_remaining
        }
        guard let purchased = flexible?.amount else { return nil }
        return CreditBalance(id: "purchased", title: "Purchased credits", remaining: purchased,
                             allowance: nil, currency: "USD", renewsAt: nil, isMain: false)
    }
}

extension AccountResponse {
    struct User: Decodable, Sendable {
        var email: String?
    }

    struct Organisation: Decodable, Sendable {
        var name: String?
    }

    struct PaidServiceAccess: Decodable, Sendable {
        var subscription_credits_remaining: FlexibleMoney?
        var purchased_credits_remaining: FlexibleMoney?
    }

    struct Subscription: Decodable, Sendable {
        var plan: String?
        var tier: String?
        var monthly_credits: FlexibleMoney?
        var credits_remaining: FlexibleMoney?
        var rollover_credits: FlexibleMoney?
        var current_period_end: String?

        private enum CodingKeys: String, CodingKey {
            case plan, tier, monthly_credits, credits_remaining, rollover_credits, current_period_end
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            plan = try? c.decodeIfPresent(String.self, forKey: .plan)
            tier = try? c.decodeIfPresent(String.self, forKey: .tier)
            monthly_credits = try? c.decodeIfPresent(FlexibleMoney.self, forKey: .monthly_credits)
            credits_remaining = try? c.decodeIfPresent(FlexibleMoney.self, forKey: .credits_remaining)
            rollover_credits = try? c.decodeIfPresent(FlexibleMoney.self, forKey: .rollover_credits)
            current_period_end = try? c.decodeIfPresent(String.self, forKey: .current_period_end)
        }

        /// The main monthly Credit balance; nil when either amount is missing (never zero-filled).
        var mainCreditBalance: CreditBalance? {
            guard let remaining = credits_remaining?.amount, let monthly = monthly_credits?.amount else {
                return nil
            }
            return CreditBalance(id: "monthly", title: "Monthly credits", remaining: remaining,
                                 allowance: monthly, currency: "USD",
                                 renewsAt: HTTP.date(current_period_end), isMain: true)
        }
    }
}

/// A JSON number or decimal string (`55`, `"55"`, `"1.5"`, `19.25`); nil when absent or not numeric.
struct FlexibleMoney: Decodable, Sendable, Equatable {
    var amount: Decimal?

    init(_ amount: Decimal?) { self.amount = amount }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        // Strings first ("22" in practice); numbers via their string form so both `900` and
        // `19.25` survive; anything else (null, object) is nil, never zero.
        if let string = try? container.decode(String.self) {
            amount = Decimal(string: string.trimmingCharacters(in: .whitespaces))
        } else if let int = try? container.decode(Int.self) {
            amount = Decimal(int)
        } else if let double = try? container.decode(Double.self) {
            amount = Decimal(string: String(describing: double))
        } else {
            amount = nil
        }
    }
}