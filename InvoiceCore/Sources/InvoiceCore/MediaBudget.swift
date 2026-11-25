import Foundation

/// Gmail refuses emails over 25 MB, and attachments grow by about a third when encoded.
/// This picks which photos and videos fit, in order, so the draft is never rejected.
public enum MediaBudget {
    /// Raw bytes of photos and videos that keep the whole email safely under Gmail's 25 MB.
    public static let defaultLimit = 17_000_000

    /// Indices of the files to attach, keeping the given order and skipping any that don't fit.
    public static func pick(sizes: [Int], limit: Int = defaultLimit) -> (attach: [Int], skip: [Int]) {
        var used = 0
        var attach: [Int] = []
        var skip: [Int] = []
        for (index, size) in sizes.enumerated() {
            if used + size <= limit {
                used += size
                attach.append(index)
            } else {
                skip.append(index)
            }
        }
        return (attach, skip)
    }
}
