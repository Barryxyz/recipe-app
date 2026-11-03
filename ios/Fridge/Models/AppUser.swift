import Foundation

/// A row of `app.users`, created by the sign-up trigger (F0.2).
struct AppUser: Codable, Equatable {
    let id: UUID
    let householdId: UUID
    let createdAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case householdId = "household_id"
        case createdAt = "created_at"
    }
}
