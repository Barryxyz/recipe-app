import Foundation
import Supabase

/// The one Supabase client the app uses.
let supabase = SupabaseClient(
    supabaseURL: AppConfig.supabaseURL,
    supabaseKey: AppConfig.supabaseKey
)
