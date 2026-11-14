import XCTest
@testable import Fridge

/// F4.3: share links and the shared recipe preview / copy.
final class SharedRecipeTests: XCTestCase {
    private let token = "AbCdEfGhIjKlMnOpQrStU1"
    private let host = "fridge-share.fridge-app.workers.dev"

    func testWebLinkOnTheShareHost() {
        XCTAssertEqual(SharedLink.token(from: URL(string: "https://\(host)/r/\(token)")!, shareHost: host), token)
        XCTAssertEqual(SharedLink.token(from: URL(string: "https://\(host.uppercased())/r/\(token)?x=1")!, shareHost: host), token)
    }

    func testAppSchemeLink() {
        XCTAssertEqual(SharedLink.token(from: URL(string: "com.barryxyz.fridge://r/\(token)")!, shareHost: host), token)
    }

    func testOtherLinksAreIgnored() {
        let bad = [
            "https://evil.example/r/\(token)",
            "http://\(host)/r/\(token)",
            "https://\(host)/r/short",
            "https://\(host)/r/\(token)/extra",
            "https://\(host)/x/\(token)",
            "https://\(host)/r/AbCdEfGhIjKlMnOpQrSt-1",
            "com.barryxyz.fridge://x/\(token)",
            "other://r/\(token)",
        ]
        for s in bad { XCTAssertNil(SharedLink.token(from: URL(string: s)!, shareHost: host), s) }
        XCTAssertNil(SharedLink.token(from: URL(string: "https://\(host)/r/\(token)")!, shareHost: nil))
    }

    func testDecodesTheServerShape() throws {
        let json = """
        {"title":"Lemon pasta","description":null,"servings":2,"prep_min":5,"cook_min":null,
         "steps":["1. Boil.","Toss."],"macros_per_serving":null,"is_ai":false,
         "ingredients":[{"name":"Lemons","quantity":1,"unit":null,"note":"zested","is_optional":false}]}
        """
        let r = try JSONDecoder().decode(SharedRecipe?.self, from: Data(json.utf8))
        XCTAssertEqual(r?.title, "Lemon pasta")
        XCTAssertEqual(r?.is_ai, false)
        XCTAssertNil(r?.cook_min)
        XCTAssertEqual(r?.ingredients.first?.note, "zested")
        XCTAssertNil(try JSONDecoder().decode(SharedRecipe?.self, from: Data("null".utf8)))
    }

    func testPreviewUsesTheRecipientsPantry() {
        let lemon = PantryItem(id: UUID(), ingredientId: 9, displayName: "Lemon", quantity: 2, unit: "each", location: .fridge,
                               addedAt: .now, expiresAt: nil, expiryOverridden: false, status: .active, source: .manual,
                               isStaple: false)
        let r = SharedRecipe(title: "Lemon pasta", servings: 2,
                             macros_per_serving: .init(kcal: 400, protein_g: 10, carbs_g: 60, fat_g: 12, fiber_g: 3,
                                                       sugar_g: 2, sodium_mg: 300, estimated: false, coverage: 1),
                             ingredients: [.init(name: "Lemons", quantity: 1, unit: nil, note: nil, is_optional: false),
                                           .init(name: "Pasta", quantity: 200, unit: "g", note: nil, is_optional: false)])
        let recipe = r.asRecipe(pantry: PantryMatcher([lemon]))
        XCTAssertEqual(recipe.ingredients.map(\.kind), [.pantry, .missing])
        XCTAssertEqual(recipe.macros_total.kcal, 800)
        XCTAssertTrue(recipe.ingredients.allSatisfy { $0.ingredient_id == nil })
    }

    func testCopyIsAPlainDraft() {
        let r = SharedRecipe(title: "  Soup  ", servings: 40, prep_min: 10, steps: ["Step 1: Chop.", "Simmer."],
                             ingredients: [.init(name: "Leek", quantity: 2, unit: nil, note: "sliced", is_optional: true)])
        let d = r.draft
        XCTAssertEqual(d.title, "Soup")
        XCTAssertEqual(d.servings, RecipeEditDraft.servingsRange.upperBound)
        XCTAssertEqual(d.steps.map(\.text), ["Chop.", "Simmer."])
        XCTAssertEqual(d.ingredients.first?.ingredientId, nil)
        XCTAssertEqual(d.ingredients.first?.unit, "")
        XCTAssertEqual(d.ingredients.first?.isOptional, true)
        XCTAssertEqual(d.payload(source: "shared").source, "shared")
    }
}

/// F5.3
final class PrivacyLinkTests: XCTestCase {
    func testPrivacyPolicyIsOnTheShareHost() {
        guard let base = AppConfig.shareBaseURL else { return }
        XCTAssertEqual(AppConfig.privacyURL?.absoluteString, base.absoluteString + "/privacy")
    }
}
