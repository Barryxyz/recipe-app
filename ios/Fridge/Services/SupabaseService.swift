import Foundation
import Supabase

/// The one Supabase client the app uses.
let supabase = SupabaseClient(
    supabaseURL: AppConfig.supabaseURL,
    supabaseKey: AppConfig.supabaseKey
)

/// Response from the F0.1 `hello` test function.
struct HelloResponse: Decodable {
    let message: String
    let anthropicKeyConfigured: Bool
    let serverTime: String
}

enum DebugAPI {
    static func hello() async throws -> HelloResponse {
        try await supabase.functions.invoke("hello")
    }
}
