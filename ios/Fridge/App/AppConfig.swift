import Foundation

/// Values injected at build time from Config/Dev.xcconfig or Config/Prod.xcconfig
/// through Info.plist.
enum AppConfig {
    static let supabaseURL: URL = {
        guard let raw = Bundle.main.object(forInfoDictionaryKey: "SupabaseURL") as? String,
              let url = URL(string: raw), url.host != nil else {
            fatalError("SupabaseURL is missing or invalid. Set SUPABASE_URL in ios/Config/*.xcconfig.")
        }
        return url
    }()

    static let supabaseKey: String = {
        guard let key = Bundle.main.object(forInfoDictionaryKey: "SupabaseKey") as? String,
              !key.isEmpty else {
            fatalError("SupabaseKey is missing. Set SUPABASE_KEY in ios/Config/*.xcconfig.")
        }
        return key
    }()
}
