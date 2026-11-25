import Foundation
import InvoiceCore
import Observation

/// The address book built ahead of time from Dad's Sent mail (the last two years, then only
/// new mail). Kept on the phone so client emails are found instantly, including company clients
/// with several people. Refreshed at most once a day, and on request from Settings.
@MainActor
@Observable
final class MailDirectoryStore {
    static let shared = MailDirectoryStore()

    private(set) var directory = EmailDirectory()
    private(set) var isRefreshing = false
    private(set) var lastRefresh: Date?

    private static let lastRefreshKey = "mailDirectory.lastRefresh"
    private static let firstSyncLimit = 1500
    private static let laterSyncLimit = 300

    private var fileURL: URL {
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("mail-directory.json")
    }

    private init() {
        if let data = try? Data(contentsOf: fileURL),
           let saved = try? JSONDecoder().decode(EmailDirectory.self, from: data) {
            directory = saved
        }
        lastRefresh = UserDefaults.standard.object(forKey: Self.lastRefreshKey) as? Date
    }

    var peopleCount: Int { directory.entries.count }

    func matches(name: String) -> [EmailSuggestion] { directory.matches(name: name) }

    func refreshIfNeeded() async {
        if let lastRefresh, Date().timeIntervalSince(lastRefresh) < 24 * 3600 { return }
        await refresh()
    }

    /// Reads To/Cc of sent mail newer than what's already counted.
    func refresh() async {
        guard !isRefreshing, GoogleAuth.shared.hasRefreshToken else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        let own = UserDefaults.standard.string(forKey: "gmail.signedInEmail")
        let query: String
        let limit: Int
        if let since = directory.syncedThrough {
            // Gmail accepts seconds since 1970 here. Mail already counted is skipped below.
            query = "in:sent after:\(Int(since.timeIntervalSince1970))"
            limit = Self.laterSyncLimit
        } else {
            query = "in:sent newer_than:2y"
            limit = Self.firstSyncLimit
        }
        let mails = await ContactLookup.fetchMails(query: query, limit: limit, headers: ["To", "Cc"])
        guard !mails.isEmpty || directory.syncedThrough != nil else { return }
        var updated = directory
        let already = directory.syncedThrough
        for item in mails.reversed() where already == nil || item.date > already! {
            updated.record(item.mail, sentAt: item.date, ownEmail: own)
        }
        directory = updated
        if let data = try? JSONEncoder().encode(updated) { try? data.write(to: fileURL, options: .atomic) }
        lastRefresh = Date()
        UserDefaults.standard.set(lastRefresh, forKey: Self.lastRefreshKey)
    }

    /// Forgets everything, e.g. when signing out of Gmail.
    func clear() {
        directory = EmailDirectory()
        lastRefresh = nil
        try? FileManager.default.removeItem(at: fileURL)
        UserDefaults.standard.removeObject(forKey: Self.lastRefreshKey)
    }
}
