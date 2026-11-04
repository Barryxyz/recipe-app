import Foundation

/// Where an item is kept. Matches the `location` check constraint on `app.pantry_items`.
enum StorageLocation: String, Codable, CaseIterable, Identifiable {
    case fridge, freezer, pantry

    var id: String { rawValue }

    var title: String {
        switch self {
        case .fridge: "Fridge"
        case .freezer: "Freezer"
        case .pantry: "Pantry"
        }
    }
}
