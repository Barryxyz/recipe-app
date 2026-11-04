import Foundation
import Supabase

/// F1.1: sends scan photos to the `scan-ingredients` Edge Function.
enum ScanAPI {
    struct Request: Encodable {
        let location: String
        let images: [String]
    }

    /// One detected item (F1.2), a draft for the review screen (F1.3).
    struct DraftItem: Decodable, Equatable, Identifiable {
        let temp_id: String
        let name: String
        let ingredient_id: Int64?
        let display_name: String
        let category: String?
        let match: String
        let quantity: Double?
        let unit: String?
        let confidence: Double
        let low_confidence: Bool
        let suggest_staple: Bool
        let photo_indexes: [Int]
        var id: String { temp_id }
    }

    struct Response: Decodable, Equatable {
        let location: String
        let items: [DraftItem]
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
