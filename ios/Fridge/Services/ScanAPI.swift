import Foundation
import Supabase

/// F1.1: sends scan photos to the `scan-ingredients` Edge Function.
enum ScanAPI {
    struct Request: Encodable {
        let location: String
        let images: [String]
    }

    /// F1.1 placeholder response: what the server received. F1.2 adds detected items.
    struct Response: Decodable, Equatable {
        struct ImageReport: Decodable, Equatable {
            let index: Int
            let bytes: Int
            let width: Int
            let height: Int
            let has_exif: Bool
            let has_metadata: Bool
            let within_limits: Bool
        }
        let placeholder: Bool?
        let location: String
        let images: [ImageReport]
    }

    enum ScanError: LocalizedError, Equatable {
        case offline
        case aiDisabled
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .offline: "Scanning needs an internet connection."
            case .aiDisabled: "Scanning is temporarily unavailable."
            case .failed: "Couldn't read the photos."
            }
        }
    }

    static func scan(placement: Placement, photos: [ScanPhoto]) async throws -> Response {
        let body = Request(location: placement.rawValue, images: photos.map { $0.jpeg.base64EncodedString() })
        do {
            return try await supabase.functions.invoke(
                "scan-ingredients",
                options: FunctionInvokeOptions(body: body, timeoutInterval: 90))
        } catch let error as URLError {
            throw error.code == .timedOut ? ScanError.failed("timeout") : ScanError.offline
        } catch FunctionsError.httpError(let code, let data) {
            throw map(code: code, data: data)
        }
    }

    /// Server error body: { error: { code, message } } (F0.5).
    static func map(code: Int, data: Data) -> ScanError {
        struct Envelope: Decodable { struct E: Decodable { let code: String }; let error: E }
        let serverCode = (try? JSONDecoder().decode(Envelope.self, from: data))?.error.code
        if serverCode == "ai_disabled" || code == 503 { return .aiDisabled }
        return .failed(serverCode ?? "http \(code)")
    }
}
