import Foundation

/// Uploads videos (and photos too big to attach) to Dad's Google Drive and shares them by
/// link, the way Gmail itself handles large files. The app can only see files it uploaded.
@MainActor
enum DriveClient {
    enum DriveError: LocalizedError {
        case failed(String)
        var errorDescription: String? {
            switch self {
            case .failed(let step):
                "Couldn't put the video on Google Drive (\(step)). Check the internet connection and try again."
            }
        }
    }

    /// Uploads the file (once) and returns a link anyone with it can open.
    static func shareLink(for media: JobMedia, name: String) async throws -> String {
        if !media.driveLink.isEmpty { return media.driveLink }
        let token = try await GoogleAuth.shared.validAccessToken()

        // 1. Start a resumable upload (works for large files and slow connections).
        var start = URLRequest(url: URL(string: "https://www.googleapis.com/upload/drive/v3/files?uploadType=resumable&fields=id")!)
        start.httpMethod = "POST"
        start.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        start.setValue("application/json; charset=UTF-8", forHTTPHeaderField: "Content-Type")
        start.setValue(media.mimeType, forHTTPHeaderField: "X-Upload-Content-Type")
        start.setValue(String(media.byteSize), forHTTPHeaderField: "X-Upload-Content-Length")
        start.httpBody = try JSONSerialization.data(withJSONObject: ["name": name, "mimeType": media.mimeType])
        let (_, startResponse) = try await URLSession.shared.data(for: start)
        guard let http = startResponse as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let location = http.value(forHTTPHeaderField: "Location"), let uploadURL = URL(string: location) else {
            throw DriveError.failed("start")
        }

        // 2. Send the file.
        var put = URLRequest(url: uploadURL)
        put.httpMethod = "PUT"
        put.setValue(media.mimeType, forHTTPHeaderField: "Content-Type")
        put.timeoutInterval = 900
        let (data, putResponse) = try await URLSession.shared.upload(for: put, fromFile: media.fileURL)
        guard let status = (putResponse as? HTTPURLResponse)?.statusCode, (200..<300).contains(status),
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = json["id"] as? String else {
            throw DriveError.failed("upload")
        }

        // 3. Anyone with the link can view it (the client has no Google account access needed).
        var share = URLRequest(url: URL(string: "https://www.googleapis.com/drive/v3/files/\(id)/permissions")!)
        share.httpMethod = "POST"
        share.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        share.setValue("application/json", forHTTPHeaderField: "Content-Type")
        share.httpBody = try JSONSerialization.data(withJSONObject: ["role": "reader", "type": "anyone"])
        let (_, shareResponse) = try await URLSession.shared.data(for: share)
        guard let shareStatus = (shareResponse as? HTTPURLResponse)?.statusCode, (200..<300).contains(shareStatus) else {
            throw DriveError.failed("share")
        }

        let link = "https://drive.google.com/file/d/\(id)/view"
        media.driveFileID = id
        media.driveLink = link
        return link
    }
}
