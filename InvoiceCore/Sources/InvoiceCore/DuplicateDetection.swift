import Foundation

/// A lightweight view of a job used to spot likely duplicates.
public struct JobFingerprint: Equatable, Sendable {
    public var id: UUID
    public var clientName: String?
    public var jobDate: Date

    public init(id: UUID, clientName: String?, jobDate: Date) {
        self.id = id
        self.clientName = clientName
        self.jobDate = jobDate
    }
}

public enum DuplicateDetection {
    /// Pairs of jobs for the same client on the same calendar day.
    /// Each pair is ordered (earlier job first) and each job appears in at most one pair.
    public static func likelyDuplicates(
        _ jobs: [JobFingerprint],
        calendar: Calendar = .current
    ) -> [(keep: UUID, mergeIn: UUID)] {
        let sorted = jobs.sorted { $0.jobDate < $1.jobDate }
        var used = Set<UUID>()
        var pairs: [(UUID, UUID)] = []
        for (i, a) in sorted.enumerated() where !used.contains(a.id) {
            guard let nameA = a.clientName.map(ClientMatching.normalize), !nameA.isEmpty else { continue }
            for b in sorted[(i + 1)...] where !used.contains(b.id) {
                guard let nameB = b.clientName.map(ClientMatching.normalize), nameA == nameB else { continue }
                guard calendar.isDate(a.jobDate, inSameDayAs: b.jobDate) else { continue }
                pairs.append((a.id, b.id))
                used.insert(a.id)
                used.insert(b.id)
                break
            }
        }
        return pairs.map { (keep: $0.0, mergeIn: $0.1) }
    }
}
