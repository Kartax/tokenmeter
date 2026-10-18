import Foundation

/// Claims of a JWT, decoded without verifying the signature. Only used to read our own tokens'
/// metadata (expiry, email, account ids); never to make trust decisions.
struct JWTClaims: Sendable {
    let claims: [String: any Sendable]

    /// Nil when `token` is not a three-part JWT with a JSON object payload.
    init?(_ token: String) {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        var base64 = parts[1].replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        guard let data = Data(base64Encoded: base64),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        claims = object.compactMapValues { Self.sendable($0) }
    }

    /// The `exp` claim.
    var expiresAt: Date? {
        (claims["exp"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
    }

    func string(_ key: String) -> String? {
        (claims[key] as? String).flatMap { $0.isEmpty ? nil : $0 }
    }

    /// A nested object claim, e.g. `https://api.openai.com/auth`.
    func object(_ key: String) -> [String: any Sendable]? {
        claims[key] as? [String: any Sendable]
    }

    private static func sendable(_ value: Any) -> (any Sendable)? {
        switch value {
        case let string as String: string
        case let number as NSNumber: number
        case let object as [String: Any]: object.compactMapValues { sendable($0) }
        case let array as [Any]: array.compactMap { sendable($0) }
        default: nil
        }
    }
}
