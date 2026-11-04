import Foundation

/// Units offered in the add/edit sheet (F1.5). Stored as `pantry_items.unit` text.
enum MeasureUnit: String, CaseIterable, Identifiable, Codable {
    case each, g, kg, ml, l, oz, lb, cup, tbsp, tsp, bunch, pack

    var id: String { rawValue }

    /// How much the stepper adds or removes.
    var step: Double {
        switch self {
        case .g, .ml: 50
        case .kg, .l, .lb, .cup: 0.5
        case .each, .oz, .tbsp, .tsp, .bunch, .pack: 1
        }
    }

    /// Catalog `default_unit` values are g, ml or each; anything unknown falls back to each.
    init(catalogUnit: String?) {
        self = catalogUnit.flatMap(MeasureUnit.init(rawValue:)) ?? .each
    }
}
