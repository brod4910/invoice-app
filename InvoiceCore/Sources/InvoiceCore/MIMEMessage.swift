import Foundation

/// Builds an RFC 2822 email with plain-text and HTML parts, as the Gmail API expects in `message.raw`.
public enum MIMEMessage {
    public struct Attachment: Equatable, Sendable {
        public var filename: String
        public var mimeType: String
        public var data: Data

        public init(filename: String, mimeType: String, data: Data) {
            self.filename = filename
            self.mimeType = mimeType
            self.data = data
        }
    }

    public static func build(
        to: String?,
        subject: String,
        html: String,
        text: String,
        attachments: [Attachment] = [],
        boundary: String = "invoice-\(UUID().uuidString)"
    ) -> String {
        var headers: [String] = []
        if let to, !to.isEmpty { headers.append("To: \(to)") }
        headers.append("Subject: \(encodeHeader(subject))")
        headers.append("MIME-Version: 1.0")

        let alternativeBoundary = attachments.isEmpty ? boundary : "\(boundary)-alt"
        let alternative = [
            "--\(alternativeBoundary)",
            "Content-Type: text/plain; charset=\"UTF-8\"",
            "Content-Transfer-Encoding: base64",
            "",
            wrap(Data(text.utf8).base64EncodedString()),
            "--\(alternativeBoundary)",
            "Content-Type: text/html; charset=\"UTF-8\"",
            "Content-Transfer-Encoding: base64",
            "",
            wrap(Data(html.utf8).base64EncodedString()),
            "--\(alternativeBoundary)--",
        ]

        if attachments.isEmpty {
            headers.append("Content-Type: multipart/alternative; boundary=\"\(boundary)\"")
            return (headers + [""] + alternative + [""]).joined(separator: "\r\n")
        }

        headers.append("Content-Type: multipart/mixed; boundary=\"\(boundary)\"")
        var body = [
            "--\(boundary)",
            "Content-Type: multipart/alternative; boundary=\"\(alternativeBoundary)\"",
            "",
        ] + alternative
        for attachment in attachments {
            let name = attachment.filename.replacingOccurrences(of: "\"", with: "")
            body += [
                "--\(boundary)",
                "Content-Type: \(attachment.mimeType); name=\"\(name)\"",
                "Content-Disposition: attachment; filename=\"\(name)\"",
                "Content-Transfer-Encoding: base64",
                "",
                wrap(attachment.data.base64EncodedString()),
            ]
        }
        body += ["--\(boundary)--", ""]
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
