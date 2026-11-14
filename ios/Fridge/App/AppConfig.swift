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

    /// Where shared recipe pages live (F4.2), e.g. https://fridge-share.<account>.workers.dev
    static let shareBaseURL: URL? = (Bundle.main.object(forInfoDictionaryKey: "ShareBaseURL") as? String)
        .flatMap(URL.init(string:)).flatMap { $0.host == nil ? nil : $0 }

    /// The privacy policy (F5.3), served by the share Worker.
    static var privacyURL: URL? { shareBaseURL?.appendingPathComponent("privacy") }

    static func shareURL(token: String) -> URL? { shareBaseURL?.appendingPathComponent("r").appendingPathComponent(token) }
}
