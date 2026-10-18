import Foundation

/// A dotted numeric version such as the bundle's `CFBundleShortVersionString` ("0.1.0")
/// or a release tag ("v0.2.0"), ordered component by component.
struct ReleaseVersion: Comparable {
    /// Numeric components without trailing zeros, so "0.2" and "0.2.0" are equal.
    private let components: [Int]

    init?(_ string: String) {
        let trimmed = string.hasPrefix("v") ? string.dropFirst() : Substring(string)
        var components: [Int] = []
        for part in trimmed.split(separator: ".", omittingEmptySubsequences: false) {
            guard let number = Int(part) else { return nil }
            components.append(number)
        }
        while components.last == 0 { components.removeLast() }
        self.components = components
    }

    static func < (lhs: ReleaseVersion, rhs: ReleaseVersion) -> Bool {
        lhs.components.lexicographicallyPrecedes(rhs.components)
    }
}
