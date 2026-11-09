import Foundation
import Supabase

/// F2.2: calls the `generate-recipes` Edge Function.
enum RecipeAPI {
    struct Ingredient: Codable, Equatable, Identifiable {
        enum Kind: String, Codable { case pantry, staple, missing }
        let position: Int
        let name: String
        let ingredient_id: Int64?
        let pantry_item_id: UUID?
        let kind: Kind
        let quantity: Double?
        let unit: String?
        let grams: Double?
        let note: String?
        let is_optional: Bool
        var id: Int { position }
    }

    struct Macros: Codable, Equatable {
        let kcal: Double
        let protein_g: Double
        let carbs_g: Double
        let fat_g: Double
        let fiber_g: Double
        let sugar_g: Double
        let sodium_mg: Double
        let estimated: Bool
        let coverage: Double
    }

    struct Recipe: Codable, Equatable, Identifiable {
        let temp_id: String
        let title: String
        let description: String
        let servings: Int
        let prep_min: Int
        let cook_min: Int
        let ingredients: [Ingredient]
        let steps: [String]
        let macros_per_serving: Macros
        let macros_total: Macros
        let uses_expiring: [String]
        let model_version: String
        var id: String { temp_id }

        var totalMinutes: Int { prep_min + cook_min }
        /// Needed and not optional.
        var missing: [Ingredient] { ingredients.filter { $0.kind == .missing && !$0.is_optional } }
    }

    struct Usage: Codable, Equatable {
        let today: Int
        let daily_limit: Int
        let this_month: Int
        let monthly_limit: Int
        let left: Int

        var text: String {
            if left <= 0 { return "No recipe requests left" }
            let monthLeft = monthly_limit - this_month
            let period = monthLeft < daily_limit - today ? "this month" : "today"
            return "\(left) recipe request\(left == 1 ? "" : "s") left \(period)"
        }
    }

    struct Response: Codable, Equatable {
        let recipes: [Recipe]
        let note: String?
        let limited_by: [String]
        let usage: Usage?
    }

    enum RecipeError: LocalizedError, Equatable {
        case offline
        case aiDisabled
        case limitReached(String)
        /// The model couldn't make recipes that pass the checks: show the fixes.
        case noGoodRecipes
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .offline: "Recipe ideas need an internet connection."
            case .aiDisabled: "Recipe ideas are temporarily unavailable."
            case .limitReached(let message): message
            case .noGoodRecipes: "Couldn't come up with good recipes."
            case .failed: "Something went wrong. Try again."
            }
        }
    }

    /// Requests left, without generating.
    static func usage() async throws -> Usage {
        struct Check: Encodable { let check = true }
        struct Wrapped: Decodable { let usage: Usage }
        let w: Wrapped = try await supabase.functions.invoke(
            "generate-recipes", options: FunctionInvokeOptions(body: Check()), decoder: ScanAPI.decoder)
        return w.usage
    }

    static func generate(_ request: RecipeRequest) async throws -> Response {
        do {
            return try await supabase.functions.invoke(
                "generate-recipes",
                options: FunctionInvokeOptions(body: request, timeoutInterval: 120), decoder: ScanAPI.decoder)
        } catch let error as URLError {
            if error.code == .cancelled { throw CancellationError() }
            throw error.code == .timedOut ? RecipeError.failed("timeout") : RecipeError.offline
        } catch FunctionsError.httpError(let code, let data) {
            throw map(code: code, data: data)
        }
    }

    static func map(code: Int, data: Data) -> RecipeError {
        struct Envelope: Decodable { struct E: Decodable { let code: String; let message: String? }; let error: E }
        let envelope = try? JSONDecoder().decode(Envelope.self, from: data)
        switch envelope?.error.code {
        case "limit_reached": return .limitReached(envelope?.error.message ?? "You've used your recipe requests for now.")
        case "ai_disabled": return .aiDisabled
        case "validation_failed": return .noGoodRecipes
        default:
            if code == 429 { return .limitReached(envelope?.error.message ?? "You've used your recipe requests for now.") }
            if code == 503 { return .aiDisabled }
            return .failed(envelope?.error.code ?? "http \(code)")
        }
    }
}
