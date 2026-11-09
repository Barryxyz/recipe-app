import Foundation
import XCTest
@testable import Fridge

/// F2.4: fixes, formatting, decoding and the kept results (no UI, no network).
final class RecipeResultsTests: XCTestCase {
    private func request(onlyOnHand: Bool = false, minutes: Int? = nil, cuisine: String? = nil, meal: Meal = .any) -> RecipeRequest {
        RecipeRequest(options: RecipeOptions(servings: 2, maxMinutes: minutes, meal: meal, cuisine: cuisine,
                                             preferExpiring: true, onlyOnHand: onlyOnHand), excluding: [])
    }

    func testFixesOnlyForOptionsTheUserSet() {
        XCTAssertEqual(RecipeFix.fixes(for: request(), limitedBy: []), [], "nothing set: no fixes")
        XCTAssertEqual(RecipeFix.fixes(for: request(), limitedBy: ["pantry"]), [.addItems])
        let all = request(onlyOnHand: true, minutes: 15, cuisine: "thai", meal: .breakfast)
        XCTAssertEqual(RecipeFix.fixes(for: all, limitedBy: []), [.allowMissing, .anyTime, .anyCuisine, .anyMeal],
                       "no reason given: every option that was set")
        XCTAssertEqual(RecipeFix.fixes(for: all, limitedBy: ["max_minutes", "diet"]), [.anyTime],
                       "only the named ones; diets are never offered")
        XCTAssertEqual(RecipeFix.fixes(for: request(minutes: 30), limitedBy: ["cuisine"]), [.anyTime],
                       "a named option the user didn't set falls back to the ones they did")
    }

    func testFixesRelaxTheRequest() {
        let r = request(onlyOnHand: true, minutes: 15, cuisine: "thai", meal: .breakfast)
        XCTAssertEqual(RecipeFix.allowMissing.apply(to: r)?.only_on_hand, false)
        XCTAssertNil(RecipeFix.anyTime.apply(to: r)?.max_minutes)
        XCTAssertNil(RecipeFix.anyCuisine.apply(to: r)?.cuisine)
        XCTAssertEqual(RecipeFix.anyMeal.apply(to: r)?.meal, "any")
        XCTAssertNil(RecipeFix.addItems.apply(to: r))
        XCTAssertEqual(RecipeFix.anyTime.apply(to: r)?.cuisine, "thai", "other options are kept")
    }

    func testRequestOptionsRoundTrip() {
        let r = request(onlyOnHand: true, minutes: 45, cuisine: "korean", meal: .lunch)
        XCTAssertEqual(RecipeRequest(options: r.options, excluding: []), r)
    }

    func testFormatting() {
        XCTAssertEqual(MacroFormat.kcal(523), 520)
        XCTAssertEqual(MacroFormat.kcal(525), 530)
        XCTAssertEqual(MacroFormat.minutes(45), "45 min")
        XCTAssertEqual(MacroFormat.minutes(90), "1 h 30 min")
        XCTAssertEqual(MacroFormat.minutes(120), "2 h")
        XCTAssertEqual(MacroFormat.amount(0.5, unit: "tsp"), "½ tsp")
        XCTAssertEqual(MacroFormat.amount(1.25, unit: "cup"), "1¼ cup")
        XCTAssertEqual(MacroFormat.amount(0.33, unit: "cup"), "⅓ cup")
        XCTAssertEqual(MacroFormat.amount(2, unit: "each"), "2")
        XCTAssertEqual(MacroFormat.amount(200, unit: "g"), "200 g")
        XCTAssertEqual(MacroFormat.amount(1.5, unit: "kg"), "1.5 kg")
        XCTAssertEqual(MacroFormat.amount(nil, unit: "g"), "")
    }

    private let json = """
    {"recipes":[{"temp_id":"r1","title":"Garlic chicken","description":"Quick.","servings":2,"prep_min":10,"cook_min":20,
      "ingredients":[
        {"position":0,"name":"chicken breast","ingredient_id":52,"pantry_item_id":"7E2B8C1A-5F4D-4C2B-9A1E-3D5F6A7B8C9D","kind":"pantry","quantity":300,"unit":"g","grams":300,"note":null,"is_optional":false},
        {"position":1,"name":"olive oil","ingredient_id":85,"pantry_item_id":"8E2B8C1A-5F4D-4C2B-9A1E-3D5F6A7B8C9D","kind":"staple","quantity":1,"unit":"tbsp","grams":14,"note":null,"is_optional":false},
        {"position":2,"name":"lime","ingredient_id":null,"pantry_item_id":null,"kind":"missing","quantity":1,"unit":"each","grams":67,"note":"juiced","is_optional":false},
        {"position":3,"name":"parsley","ingredient_id":null,"pantry_item_id":null,"kind":"missing","quantity":null,"unit":null,"grams":null,"note":null,"is_optional":true}],
      "steps":["Cook."],
      "macros_per_serving":{"kcal":523.4,"protein_g":38.2,"carbs_g":41,"fat_g":22,"fiber_g":6,"sugar_g":9,"sodium_mg":840,"estimated":true,"coverage":0.95},
      "macros_total":{"kcal":1046.8,"protein_g":76.4,"carbs_g":82,"fat_g":44,"fiber_g":12,"sugar_g":18,"sodium_mg":1680,"estimated":true,"coverage":0.95},
      "uses_expiring":["chicken breast"],"model_version":"claude-haiku-5-5"}],
     "note":null,"limited_by":[],"attempts":[],
     "usage":{"today":3,"daily_limit":20,"this_month":10,"monthly_limit":300,"left":17,"resets_at":"2026-11-10T05:00:00+00:00"}}
    """

    func testDecodesServerResponseAndKeepsIt() throws {
        let r = try ScanAPI.decoder.decode(RecipeAPI.Response.self, from: Data(json.utf8))
        let recipe = r.recipes[0]
        XCTAssertEqual(recipe.totalMinutes, 30)
        XCTAssertEqual(recipe.missing.map(\.name), ["lime"], "optional missing items don't count")
        XCTAssertEqual(MacroFormat.summary(recipe.macros_per_serving), "≈520 kcal · P 38 g · C 41 g · F 22 g")
        XCTAssertEqual(r.usage?.text, "17 recipe requests left today")

        let session = RecipeSession(request: request(), response: r)
        let back = try JSONDecoder().decode(RecipeSession.self, from: JSONEncoder().encode(session))
        XCTAssertEqual(back.response, r)
        XCTAssertEqual(back.request, session.request)
    }

    func testStepNumbersAreRemoved() {
        XCTAssertEqual(RecipeText.stepWithoutNumber("1. Heat the oil."), "Heat the oil.")
        XCTAssertEqual(RecipeText.stepWithoutNumber("Step 2: Add the garlic."), "Add the garlic.")
        XCTAssertEqual(RecipeText.stepWithoutNumber("3) Stir"), "Stir")
        XCTAssertEqual(RecipeText.stepWithoutNumber("  10 - Serve"), "Serve")
        XCTAssertEqual(RecipeText.stepWithoutNumber("2 eggs go in the pan"), "2 eggs go in the pan", "a quantity isn't a step number")
        XCTAssertEqual(RecipeText.stepWithoutNumber("Bake at 200 °C."), "Bake at 200 °C.")
    }

    func testErrorMapping() {
        let body = { (code: String) in Data(#"{"error":{"code":"\#(code)","message":"msg"}}"#.utf8) }
        XCTAssertEqual(RecipeAPI.map(code: 502, data: body("validation_failed")), .noGoodRecipes)
        XCTAssertEqual(RecipeAPI.map(code: 429, data: body("limit_reached")), .limitReached("msg"))
        XCTAssertEqual(RecipeAPI.map(code: 503, data: body("ai_disabled")), .aiDisabled)
        XCTAssertEqual(RecipeAPI.map(code: 502, data: body("ai_failed")), .failed("ai_failed"))
    }
}
