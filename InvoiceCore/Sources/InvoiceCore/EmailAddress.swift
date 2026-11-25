import Foundation

public enum EmailAddress {
    /// A light check used to warn before drafting, not a full RFC 5322 validator.
    public static func isPlausible(_ text: String?) -> Bool {
        guard let text = text?.trimmingCharacters(in: .whitespaces), !text.isEmpty else { return false }
        let parts = text.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty, !text.contains(" ") else { return false }
        let domain = parts[1]
        guard let dot = domain.lastIndex(of: "."), dot != domain.startIndex else { return false }
        return domain.distance(from: dot, to: domain.endIndex) > 2
    }
}
