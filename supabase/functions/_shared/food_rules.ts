// F2.2: allergen and diet checks for recipe ingredients. Code, not the model, has the last word:
// an ingredient is flagged if its catalog tags OR its name match. Name matching is by whole
// words, after removing phrases that only look like a match ("coconut milk", "oyster mushroom").
// It errs on the side of flagging: a dropped recipe is cheaper than an allergic reaction.

/** Allergen tag -> words/phrases that indicate it in an ingredient name. */
const ALLERGEN_WORDS: Record<string, string[]> = {
  milk: [
    "milk", "cheese", "butter", "cream", "yogurt", "yoghurt", "whey", "ghee", "casein", "buttermilk",
    "parmesan", "parmigiano", "mozzarella", "cheddar", "feta", "ricotta", "brie", "gouda", "mascarpone",
    "paneer", "custard", "kefir", "lactose", "halloumi", "camembert", "gruyere", "pecorino", "burrata",
    "provolone", "queso", "creme fraiche", "half and half", "bechamel", "alfredo",
  ],
  egg: ["egg", "mayonnaise", "mayo", "aioli", "meringue", "hollandaise"],
  fish: [
    "fish", "salmon", "tuna", "cod", "anchovy", "anchovies", "sardine", "tilapia", "halibut", "trout",
    "bass", "catfish", "mackerel", "haddock", "snapper", "pollock", "swordfish", "herring", "worcestershire",
    "caesar", "bonito", "dashi",
  ],
  shellfish: [
    "shellfish", "shrimp", "prawn", "crab", "lobster", "scallop", "clam", "mussel", "oyster", "crawfish",
    "crayfish", "langoustine", "squid", "calamari", "octopus",
  ],
  "tree nuts": [
    "almond", "walnut", "cashew", "pecan", "pistachio", "hazelnut", "macadamia", "pine nut", "brazil nut",
    "praline", "marzipan", "nutella", "pesto", "nut", "frangipane", "chestnut",
  ],
  peanuts: ["peanut", "satay", "groundnut"],
  wheat: [
    "wheat", "flour", "bread", "breadcrumb", "panko", "pasta", "spaghetti", "penne", "macaroni", "linguine",
    "fettuccine", "lasagna", "lasagne", "noodle", "ramen", "udon", "couscous", "bulgur", "semolina", "farro",
    "spelt", "seitan", "tortilla", "pita", "naan", "bagel", "croissant", "cracker", "soy sauce", "pastry",
    "dough", "wonton", "dumpling", "roux", "bun", "baguette", "brioche", "crouton", "orzo", "gnocchi",
  ],
  gluten: ["barley", "rye", "malt", "oat", "oats", "beer"],
  soy: ["soy", "soya", "tofu", "tempeh", "edamame", "miso", "tamari", "natto"],
  sesame: ["sesame", "tahini", "hummus", "halva", "halvah", "furikake", "gomasio", "za atar", "zaatar"],
};
// Gluten is in everything wheat is in.
ALLERGEN_WORDS.gluten = [...ALLERGEN_WORDS.gluten, ...ALLERGEN_WORDS.wheat];

/** Phrases removed before matching a tag, because they contain a word but not the allergen. */
const NOT_ALLERGEN: Record<string, string[]> = {
  milk: [
    "coconut milk", "almond milk", "oat milk", "soy milk", "soya milk", "rice milk", "cashew milk",
    "coconut cream", "peanut butter", "almond butter", "cashew butter", "nut butter", "apple butter",
    "cocoa butter", "shea butter", "butter bean", "butter beans", "butternut", "cream of tartar",
  ],
  egg: [],
  fish: [],
  shellfish: ["oyster mushroom", "oyster mushrooms", "crab apple", "crab apples"],
  "tree nuts": ["water chestnut", "water chestnuts", "nutmeg", "coconut", "butternut", "peanut", "peanuts", "doughnut", "donut"],
  peanuts: [],
  wheat: [
    "rice flour", "almond flour", "coconut flour", "corn flour", "cornflour", "chickpea flour",
    "tapioca flour", "potato flour", "buckwheat flour", "rice noodle", "rice noodles", "glass noodle",
    "glass noodles", "corn tortilla", "corn tortillas", "rice paper", "cauliflower rice", "tamari",
  ],
  gluten: [
    "rice flour", "almond flour", "coconut flour", "corn flour", "cornflour", "chickpea flour",
    "tapioca flour", "potato flour", "buckwheat flour", "rice noodle", "rice noodles", "glass noodle",
    "glass noodles", "corn tortilla", "corn tortillas", "rice paper", "cauliflower rice", "tamari",
  ],
  soy: [],
  sesame: [],
};

/** Names that say they're free of the allergen ("gluten-free bread", "vegan cheese"). */
const FREE_OF: Record<string, string[]> = {
  milk: ["dairy free", "milk free", "lactose free", "vegan", "plant based", "non dairy"],
  egg: ["egg free", "eggless", "vegan"],
  fish: ["fish free"],
  shellfish: ["shellfish free"],
  "tree nuts": ["nut free", "tree nut free"],
  peanuts: ["peanut free", "nut free"],
  wheat: ["gluten free", "wheat free"],
  gluten: ["gluten free"],
  soy: ["soy free"],
  sesame: ["sesame free"],
};

/** "Chicken-Thighs (boneless)" -> "chicken thighs boneless" */
export function normalizeFoodName(name: string): string {
  return name.toLowerCase().normalize("NFD").replace(/[̀-ͯ]/g, "")
    .replace(/[^a-z0-9]+/g, " ").trim();
}

function escape(s: string): string {
  return s.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}

/** Whole-word match, allowing a plural (s / es / ies for y). */
function hasWord(text: string, word: string): boolean {
  const w = normalizeFoodName(word);
  if (!w) return false;
  const stem = w.endsWith("y") ? `(?:${escape(w)}|${escape(w.slice(0, -1))}ies)` : escape(w);
  return new RegExp(`(?:^| )${stem}(?:s|es)?(?= |$)`).test(text);
}

function strip(text: string, phrases: string[]): string {
  let t = ` ${text} `;
  for (const p of phrases) {
    const n = normalizeFoodName(p);
    t = t.replace(new RegExp(` ${escape(n)}(?:s|es)?(?= )`, "g"), " ");
  }
  return t.trim().replace(/ +/g, " ");
}

/** True if the name mentions the allergen tag (or, for a custom allergy, the word itself). */
export function nameHasAllergen(name: string, allergen: string): boolean {
  const tag = normalizeFoodName(allergen) === "tree nuts" ? "tree nuts" : allergen.trim().toLowerCase();
  const normalized = normalizeFoodName(name);
  if ((FREE_OF[tag] ?? []).some((p) => ` ${normalized} `.includes(` ${p} `))) return false;
  const text = strip(normalized, NOT_ALLERGEN[tag] ?? []);
  const words = ALLERGEN_WORDS[tag] ?? [allergen];   // custom allergy ("mustard"): its own name
  return words.some((w) => hasWord(text, w));
}

export interface CheckedIngredient {
  /** Every name we know for it: the model's, the pantry item's, the catalog's. */
  names: string[];
  /** catalog.ingredients.allergens of the matched catalog item, if any. */
  tags: string[];
  /** catalog category ("meat", "seafood", ...), if known. */
  category: string | null;
}

/** The user's allergens this ingredient contains (by tag or by name). */
export function allergensIn(ing: CheckedIngredient, allergens: string[]): string[] {
  return allergens.filter((a) => {
    const tag = a.trim().toLowerCase();
    return ing.tags.includes(tag) || ing.names.some((n) => nameHasAllergen(n, tag));
  });
}

// ---------------------------------------------------------------- diets

const MEAT_WORDS = [
  "chicken", "beef", "pork", "lamb", "mutton", "bacon", "ham", "sausage", "turkey", "veal", "duck", "goose",
  "venison", "prosciutto", "pancetta", "pepperoni", "salami", "chorizo", "steak", "mince", "meatball",
  "meat", "gelatin", "gelatine", "lard", "brisket", "ribs", "jerky", "hot dog", "rabbit", "liver", "bone broth",
];
const PORK_WORDS = ["pork", "bacon", "ham", "prosciutto", "pancetta", "chorizo", "pepperoni", "salami", "lard", "gelatin", "gelatine"];
const ALCOHOL_WORDS = ["wine", "beer", "rum", "vodka", "whiskey", "whisky", "bourbon", "brandy", "sake", "liqueur", "sherry", "cognac", "gin"];
/** A name with one of these is a meat substitute ("vegan sausage"), not meat. */
const MEAT_FREE = ["vegan", "vegetarian", "veggie", "plant based", "meatless", "meat free", "imitation"];
const NOT_MEAT = ["coconut meat", "crab meat"];   // crab is caught as shellfish instead

function hasAny(names: string[], words: string[], exclude: string[] = []): boolean {
  return names.some((n) => {
    const normalized = normalizeFoodName(n);
    if (MEAT_FREE.some((p) => ` ${normalized} `.includes(` ${p} `))) return false;
    const text = strip(normalized, exclude);
    return words.some((w) => hasWord(text, w));
  });
}

/** Diets enforced in code. keto and low_carb are left to the prompt (no clean yes/no per ingredient). */
export function dietViolation(ing: CheckedIngredient, diet: string): boolean {
  const isMeat = ing.category === "meat" || hasAny(ing.names, MEAT_WORDS, NOT_MEAT);
  const isSeafood = ing.category === "seafood" ||
    allergensIn(ing, ["fish", "shellfish"]).length > 0;
  switch (diet) {
    case "vegetarian": return isMeat || isSeafood;
    case "pescatarian": return isMeat;
    case "vegan":
      return isMeat || isSeafood || allergensIn(ing, ["milk", "egg"]).length > 0 || hasAny(ing.names, ["honey"]);
    case "dairy_free": return allergensIn(ing, ["milk"]).length > 0;
    case "gluten_free": return allergensIn(ing, ["wheat", "gluten"]).length > 0;
    case "halal": return hasAny(ing.names, [...PORK_WORDS, ...ALCOHOL_WORDS], NOT_MEAT);
    case "kosher": return hasAny(ing.names, PORK_WORDS, NOT_MEAT) || allergensIn(ing, ["shellfish"]).length > 0;
    default: return false;
  }
}
