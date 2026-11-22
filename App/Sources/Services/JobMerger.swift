import Foundation
import SwiftData

/// Combines two jobs that should have been one.
@MainActor
enum JobMerger {
    /// Moves every recording and line item from `source` into `target`, keeps the earlier date,
    /// fills any blank fields on the target, then deletes the empty source job.
    static func merge(_ source: Job, into target: Job, context: ModelContext) {
        guard source.id != target.id else { return }

        target.jobDate = min(target.jobDate, source.jobDate)
        if target.client == nil { target.client = source.client }
        if target.title.isEmpty { target.title = source.title }
        if target.address.isEmpty { target.address = source.address }
        if !source.notes.isEmpty {
            target.notes = target.notes.isEmpty ? source.notes : target.notes + "\n" + source.notes
        }

        var next = (target.items.map(\.sortIndex).max() ?? -1) + 1
        for item in source.sortedItems {
            item.job = target
            item.sortIndex = next
            next += 1
        }
        for recording in source.recordings {
            recording.job = target
        }
        for invoice in source.invoices {
            invoice.job = target
        }
        if target.status == .invoiced || source.status == .invoiced {
            target.status = .draft
        }

        // Save the moves first so the cascade delete can't take the moved items with it.
        try? context.save()
        context.delete(source)
        try? context.save()
    }
}
