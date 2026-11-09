// F2.2: allergen and diet checks, with hidden-allergen cases. No AI, no database.
import { assertEquals } from "jsr:@std/assert@1";
import { allergensIn, type CheckedIngredient, dietViolation, nameHasAllergen } from "./food_rules.ts";

const yes = (allergen: string, names: string[]) => {
  for (const n of names) assertEquals(nameHasAllergen(n, allergen), true, `"${n}" should contain ${allergen}`);
};
const no = (allergen: string, names: string[]) => {
  for (const n of names) assertEquals(nameHasAllergen(n, allergen), false, `"${n}" should not contain ${allergen}`);
};

Deno.test("milk: dairy words, not plant milks or look-alikes", () => {
  yes("milk", ["whole milk", "Parmesan", "sour cream", "Butter", "greek yogurt", "ice cream", "Crème fraîche",
    "heavy cream", "cream cheese", "ghee", "buttermilk", "mozzarella balls", "half-and-half", "Gruyère"]);
  no("milk", ["coconut milk", "almond milk", "oat milk", "peanut butter", "butternut squash", "butter beans",
    "cream of tartar", "vegan cheese", "dairy-free yogurt", "cocoa butter"]);
});

Deno.test("egg: hidden in mayo, aioli, meringue; not eggplant", () => {
  yes("egg", ["eggs", "egg yolk", "mayonnaise", "garlic aioli", "Egg noodles", "hollandaise"]);
  no("egg", ["eggplant", "vegan mayo", "eggless pasta"]);
});

Deno.test("fish and shellfish, including sauces", () => {
  yes("fish", ["salmon fillet", "anchovies", "fish sauce", "Worcestershire sauce", "caesar dressing", "canned tuna", "dashi"]);
  no("fish", ["shellfish stock", "codiaeum"]);
  yes("shellfish", ["shrimp", "king prawns", "oyster sauce", "crab meat", "mussels", "calamari"]);
  no("shellfish", ["oyster mushrooms", "crab apples"]);
});

Deno.test("tree nuts and peanuts: pesto, marzipan; not nutmeg, coconut, peanuts", () => {
  yes("tree nuts", ["pesto", "pine nuts", "toasted almonds", "Marzipan", "mixed nuts", "walnut halves", "cashews"]);
  no("tree nuts", ["nutmeg", "coconut", "butternut squash", "peanuts", "water chestnuts", "doughnut", "nut-free granola"]);
  yes("peanuts", ["peanut butter", "satay sauce", "roasted peanuts"]);
  no("peanuts", ["pine nuts", "almonds"]);
});

Deno.test("wheat and gluten: flour, pasta, soy sauce; not rice flour or gluten-free", () => {
  yes("wheat", ["all-purpose flour", "spaghetti", "soy sauce", "panko breadcrumbs", "flour tortillas",
    "udon noodles", "couscous", "puff pastry", "pizza dough"]);
  no("wheat", ["rice flour", "rice noodles", "corn tortillas", "gluten-free bread", "tamari", "buckwheat flour",
    "cauliflower rice"]);
  yes("gluten", ["rolled oats", "barley", "beer", "malt vinegar", "bread"]);
  no("gluten", ["gluten-free pasta", "rice"]);
});

Deno.test("soy and sesame", () => {
  yes("soy", ["tofu", "edamame", "white miso paste", "soy sauce", "tamari"]);
  no("soy", ["soy-free spread"]);
  yes("sesame", ["tahini", "hummus", "toasted sesame oil", "sesame seeds"]);
  no("sesame", ["olive oil"]);
});

Deno.test("custom allergy: matched by its own word", () => {
  yes("mustard", ["Dijon mustard", "mustard seeds"]);
  yes("celery", ["celery stalks"]);
  no("mustard", ["mayonnaise"]);
});

const ing = (names: string[], tags: string[] = [], category: string | null = null): CheckedIngredient =>
  ({ names, tags, category });

Deno.test("tags win even when the name says nothing", () => {
  assertEquals(allergensIn(ing(["house sauce"], ["soy", "wheat"]), ["soy", "milk"]), ["soy"]);
  assertEquals(allergensIn(ing(["spinach"]), ["milk", "egg"]), []);
  assertEquals(allergensIn(ing(["whatever"], ["tree nuts"]), ["tree nuts"]), ["tree nuts"]);
});

Deno.test("diets", () => {
  const chicken = ing(["chicken thighs"], [], "meat");
  const salmon = ing(["salmon"], ["fish"], "seafood");
  const cheese = ing(["cheddar cheese"], ["milk"], "dairy");
  const tofu = ing(["tofu"], ["soy"], "protein");
  assertEquals([dietViolation(chicken, "vegetarian"), dietViolation(salmon, "vegetarian"), dietViolation(cheese, "vegetarian")], [true, true, false]);
  assertEquals([dietViolation(chicken, "pescatarian"), dietViolation(salmon, "pescatarian")], [true, false]);
  assertEquals([dietViolation(cheese, "vegan"), dietViolation(ing(["honey"]), "vegan"), dietViolation(tofu, "vegan")], [true, true, false]);
  assertEquals(dietViolation(ing(["chicken stock"]), "vegetarian"), true, "stock from meat");
  assertEquals(dietViolation(ing(["vegetable stock"]), "vegetarian"), false);
  assertEquals(dietViolation(ing(["vegan sausage"]), "vegetarian"), false);
  assertEquals(dietViolation(ing(["fish sauce"]), "vegetarian"), true);
  assertEquals(dietViolation(ing(["eggplant"]), "vegan"), false);
  assertEquals(dietViolation(ing(["spaghetti"]), "gluten_free"), true);
  assertEquals(dietViolation(ing(["butter"], ["milk"]), "dairy_free"), true);
  assertEquals([dietViolation(ing(["bacon"]), "halal"), dietViolation(ing(["white wine"]), "halal"), dietViolation(ing(["lamb"]), "halal")], [true, true, false]);
  assertEquals([dietViolation(ing(["shrimp"]), "kosher"), dietViolation(ing(["ham"]), "kosher"), dietViolation(ing(["beef"]), "kosher")], [true, true, false]);
  assertEquals(dietViolation(ing(["pasta"]), "keto"), false, "keto is left to the prompt");
});
