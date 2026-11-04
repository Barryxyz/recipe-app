import Foundation
import XCTest
@testable import Fridge

/// F1.7: turning onboarding/Settings choices into stored preferences and back.
final class PrefsDraftTests: XCTestCase {
    private let salt = IngredientChoice(id: 77, name: "salt", category: "spices", defaultUnit: "g", isCustom: false)
    private let oil = IngredientChoice(id: 85, name: "olive oil", category: "oils", defaultUnit: "ml", isCustom: false)

    func testWheatGlutenStoresBothTags() {
        var d = PrefsDraft()
        d.toggle(.wheatGluten)
        d.toggle(.peanuts)
        XCTAssertEqual(d.prefs.allergens, ["peanuts", "wheat", "gluten"], "catalog tag names, in a stable order")
    }

    func testAllergyTagsMatchCatalogTags() {
        // The catalog seed only uses these tags (build_catalog_seed.py ALLERGENS).
        let catalogTags: Set<String> = ["milk", "egg", "fish", "shellfish", "tree nuts", "peanuts", "wheat", "soy", "sesame", "gluten"]
        XCTAssertEqual(AllergyChoice.allTags, catalogTags)
    }

    func testOtherAllergiesAreCleanedUp() {
        var d = PrefsDraft()
        d.otherAllergies = " Mustard, celery,,mustard , PEANUTS ,  "
        XCTAssertEqual(d.otherAllergyList, ["mustard", "celery"],
                       "trimmed, lowercased, de-duplicated; known tags belong to the chips")
        XCTAssertEqual(d.prefs.allergens, ["mustard", "celery"])
    }

    func testDietsStoredInStableOrder() {
        var d = PrefsDraft()
        d.toggle(.kosher)
        d.toggle(.vegan)
        d.toggle(.glutenFree)
        XCTAssertEqual(d.prefs.diets, ["vegan", "gluten_free", "kosher"])
        d.toggle(.vegan)
        XCTAssertEqual(d.prefs.diets, ["gluten_free", "kosher"], "toggling twice removes it")
    }

    func testServingsAreClamped() {
        var d = PrefsDraft()
        d.servings = 0
        XCTAssertEqual(d.prefs.defaultServings, 1)
        d.servings = 99
        XCTAssertEqual(d.prefs.defaultServings, 20, "matches the database check (1-20)")
    }

    func testStaplesNoDuplicates() {
        var d = PrefsDraft()
        d.addStaple(salt)
        d.addStaple(oil)
        d.addStaple(salt)
        XCTAssertEqual(d.prefs.stapleIngredientIds, [77, 85])
        d.removeStaple(77)
        XCTAssertEqual(d.prefs.stapleIngredientIds, [85])
    }

    func testRoundTripThroughStoredPrefs() {
        var d = PrefsDraft()
        d.toggle(.vegetarian)
        d.toggle(.wheatGluten)
        d.toggle(.sesame)
        d.otherAllergies = "mustard"
        d.addStaple(salt)
        d.servings = 4
        let back = PrefsDraft(d.prefs, staples: [salt])
        XCTAssertEqual(back.diets, [.vegetarian])
        XCTAssertEqual(back.allergies, [.wheatGluten, .sesame])
        XCTAssertEqual(back.otherAllergies, "mustard")
        XCTAssertEqual(back.servings, 4)
        XCTAssertEqual(back.prefs, d.prefs)
    }

    func testOnlyGlutenStoredStillShowsWheatGlutenChip() {
        let prefs = UserPrefs(diets: [], allergens: ["gluten"], stapleIngredientIds: [], defaultServings: 2)
        XCTAssertEqual(PrefsDraft(prefs, staples: []).allergies, [.wheatGluten])
    }

    func testUnknownDietIsIgnored() {
        let prefs = UserPrefs(diets: ["vegan", "paleo"], allergens: [], stapleIngredientIds: [], defaultServings: 2)
        XCTAssertEqual(PrefsDraft(prefs, staples: []).diets, [.vegan])
    }

    func testOnboardingSkippedOnlyWhenPrefsWereSet() {
        let empty = UserPrefs(diets: [], allergens: [], stapleIngredientIds: [], defaultServings: 2)
        XCTAssertFalse(OnboardingState.prefsLookConfigured(empty))
        var withStaples = empty
        withStaples.stapleIngredientIds = [77]
        XCTAssertTrue(OnboardingState.prefsLookConfigured(withStaples))
    }
}
