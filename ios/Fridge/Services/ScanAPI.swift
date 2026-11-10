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

    /// Scans left (NFR-9).
    struct Usage: Decodable, Equatable {
        let today: Int
        let daily_limit: Int
        let this_month: Int
        let monthly_limit: Int
        let left: Int
        let resets_at: Date?

        var text: String {
            if left <= 0 { return "No scans left" }
            let monthLeft = monthly_limit - this_month
            return monthLeft < daily_limit - today
                ? "\(left) scan\(left == 1 ? "" : "s") left this month"
                : "\(left) scan\(left == 1 ? "" : "s") left today"
        }
    }

    struct Response: Decodable, Equatable {
        let location: String
        let items: [DraftItem]
        let usage: Usage?
    }

    enum ScanError: LocalizedError, Equatable {
        case offline
        case aiDisabled
        case limitReached(String)
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .offline: "Scanning needs an internet connection."
            case .aiDisabled: "Scanning is temporarily unavailable."
            case .limitReached: "Scan limit reached"
            case .failed: "Couldn't read the photos."
            }
        }
    }

    static var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { dec in
            let raw = try dec.singleValueContainer().decode(String.self)
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = f.date(from: raw) { return date }
            f.formatOptions = [.withInternetDateTime]
            if let date = f.date(from: raw) { return date }
            // Postgres style "2026-11-05 08:00:00+00"
            let pg = DateFormatter()
            pg.locale = Locale(identifier: "en_US_POSIX")
            pg.dateFormat = "yyyy-MM-dd HH:mm:ssXXXXX"
            if let date = pg.date(from: raw) { return date }
            pg.dateFormat = "yyyy-MM-dd'T'HH:mm:ssXXXXX"
            if let date = pg.date(from: raw) { return date }
            throw DecodingError.dataCorruptedError(in: try dec.singleValueContainer(), debugDescription: "date \(raw)")
        }
        return d
    }

    /// Scans left, without scanning or any AI call.
    static func usage() async throws -> Usage {
        struct Check: Encodable { let check = true }
        struct Wrapped: Decodable { let usage: Usage }
        let w: Wrapped = try await supabase.functions.invoke(
            "scan-ingredients", options: FunctionInvokeOptions(body: Check()), decoder: decoder)
        return w.usage
    }

    /// Saves a reviewed scan in one transaction (app.add_pantry_items).
    static func save(_ review: ScanReview) async throws -> (added: Int, updated: Int) {
        struct Params: Encodable { let items: [ScanReview.SaveItem] }
        struct Result: Decodable { let added: Int; let updated: Int }
        let r: Result = try await supabase.schema("app")
            .rpc("add_pantry_items", params: Params(items: review.saveItems))
            .execute()
            .value
        await ExpiryReminders.shared.pantrySaved()
        return (r.added, r.updated)
    }

    static func scan(placement: Placement, photos: [ScanPhoto]) async throws -> Response {
        let body = Request(location: placement.rawValue, images: photos.map { $0.jpeg.base64EncodedString() })
        do {
            return try await supabase.functions.invoke(
                "scan-ingredients",
                options: FunctionInvokeOptions(body: body, timeoutInterval: 90), decoder: decoder)
        } catch let error as URLError {
            throw error.code == .timedOut ? ScanError.failed("timeout") : ScanError.offline
        } catch FunctionsError.httpError(let code, let data) {
            throw map(code: code, data: data)
        }
    }

    /// Server error body: { error: { code, message } } (F0.5).
    static func map(code: Int, data: Data) -> ScanError {
        struct Envelope: Decodable { struct E: Decodable { let code: String; let message: String? }; let error: E }
        let envelope = try? JSONDecoder().decode(Envelope.self, from: data)
        let serverCode = envelope?.error.code
        if serverCode == "limit_reached" || code == 429 {
            return .limitReached(envelope?.error.message ?? "You've used your scans for now. You can still add items manually.")
        }
        if serverCode == "ai_disabled" || code == 503 { return .aiDisabled }
        return .failed(serverCode ?? "http \(code)")
    }
}
