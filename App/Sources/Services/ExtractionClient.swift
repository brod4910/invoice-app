import Foundation
import InvoiceCore

/// Sends a transcript to the extraction proxy (see /proxy) and returns structured line items.
enum ExtractionClient {
    static func extract(_ request: ExtractionRequest) async throws -> ExtractionResult {
        guard let url = AppConfig.extractionURL else { throw ExtractionError.notConfigured }
        var http = URLRequest(url: url.appendingPathComponent("extract"))
        http.httpMethod = "POST"
        http.timeoutInterval = 120
        http.setValue("application/json", forHTTPHeaderField: "Content-Type")
        http.setValue("Bearer \(AppConfig.appToken)", forHTTPHeaderField: "Authorization")
        http.httpBody = try JSONEncoder().encode(request)

        let (data, response) = try await URLSession.shared.data(for: http)
        guard let status = (response as? HTTPURLResponse)?.statusCode else { throw ExtractionError.badResponse }
        guard (200..<300).contains(status) else {
            throw ExtractionError.server(status, String(decoding: data.prefix(300), as: UTF8.self))
        }
        return try ExtractionDecoding.decode(data)
    }

    enum ExtractionError: LocalizedError {
        case notConfigured, badResponse
        case server(Int, String)

        var errorDescription: String? {
            switch self {
            case .notConfigured: "The extraction server isn't set up yet."
            case .badResponse: "Got an unexpected reply from the server."
            case .server(let code, _): "The server had a problem (\(code)). It will try again."
            }
        }
    }
}
