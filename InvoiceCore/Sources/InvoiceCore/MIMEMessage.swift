import Foundation

/// Builds an RFC 2822 email with plain-text and HTML parts, as the Gmail API expects in `message.raw`.
public enum MIMEMessage {
    public static func build(
        to: String?,
        subject: String,
        html: String,
        text: String,
        boundary: String = "invoice-\(UUID().uuidString)"
    ) -> String {
        var headers: [String] = []
        if let to, !to.isEmpty { headers.append("To: \(to)") }
        headers.append("Subject: \(encodeHeader(subject))")
        headers.append("MIME-Version: 1.0")
        headers.append("Content-Type: multipart/alternative; boundary=\"\(boundary)\"")

        let body = [
            "--\(boundary)",
            "Content-Type: text/plain; charset=\"UTF-8\"",
            "Content-Transfer-Encoding: base64",
            "",
            wrap(Data(text.utf8).base64EncodedString()),
            "--\(boundary)",
            "Content-Type: text/html; charset=\"UTF-8\"",
            "Content-Transfer-Encoding: base64",
            "",
            wrap(Data(html.utf8).base64EncodedString()),
            "--\(boundary)--",
            "",
        ]
        return (headers + [""] + body).joined(separator: "\r\n")
    }

    /// Base64url without padding, the encoding the Gmail API uses for `raw`.
    public static func base64URL(_ message: String) -> String {
        Data(message.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// RFC 2047 encoding for non-ASCII subjects.
    static func encodeHeader(_ value: String) -> String {
        if value.unicodeScalars.allSatisfy({ $0.isASCII }) { return value }
        return "=?UTF-8?B?\(Data(value.utf8).base64EncodedString())?="
    }

    private static func wrap(_ s: String, width: Int = 76) -> String {
        var lines: [Substring] = []
        var index = s.startIndex
        while index < s.endIndex {
            let end = s.index(index, offsetBy: width, limitedBy: s.endIndex) ?? s.endIndex
            lines.append(s[index..<end])
            index = end
        }
        return lines.joined(separator: "\r\n")
    }
}
