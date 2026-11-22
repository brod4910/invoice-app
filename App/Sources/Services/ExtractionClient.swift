import Foundation
import InvoiceCore

/// Turns a transcript into structured line items.
/// Uses Apple's free on-device model when the phone supports it. Otherwise, if the optional
/// Claude server in /proxy is configured, uses that.
enum ExtractionClient {
    static func extract(_ request: ExtractionRequest) async throws -> ExtractionResult {
        let raw: ExtractionResult
        if OnDeviceExtractor.isAvailable {
            raw = try await OnDeviceExtractor.extract(request)
        } else if AppConfig.extractionURL != nil {
            raw = try await extractWithServer(request)
        } else {
            throw ExtractionError.unavailable(OnDeviceExtractor.unavailableReason ?? "Apple's on-device AI isn't available.")
        }
        // Drop anything the model made up: items, prices and names must come from what was said.
        let grounded = ExtractionGrounding.ground(raw, transcript: request.transcript)
        // Fields Dad labels out loud ("Client …", "Address …") always win.
        return SpokenFields.parse(request.transcript).apply(to: grounded)
    }

    static func extractWithServer(_ request: ExtractionRequest) async throws -> ExtractionResult {
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
        case unavailable(String)

        var errorDescription: String? {
            switch self {
            case .unavailable(let reason): reason
            case .notConfigured: "The extraction server isn't set up yet."
            case .badResponse: "Got an unexpected reply from the server."
            case .server(let code, _): "The server had a problem (\(code)). It will try again."
            }
        }
    }
}
