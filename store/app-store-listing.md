# App Store listing (draft)

Draft for App Store Connect (F5.3). Character counts are checked against Apple's limits. The
privacy policy and terms links must stay in the description (subscription apps).

| Field | Text | Length |
|---|---|---|
| **App name** | Spoil Not: Fridge to Recipe | 27/30 |
| **Subtitle** | Scan food, cook before it goes | 30/30 |
| **Keywords** | `pantry,waste,expiry,expiration,tracker,meal ideas,grocery,shopping list,leftovers,ingredient,planner` | 100/100 |
| **Promotional text** | Snap your fridge, see what's about to expire, and get recipes that use it up first. Less waste, fewer "what's for dinner?" moments. | 131/170 |

Keywords don't repeat words already in the name or subtitle (Apple indexes those anyway).

## Description (2153/4000)

```
Spoil Not keeps track of the food you already have and helps you cook it before it goes bad.

SCAN YOUR FRIDGE
Take a photo of a shelf and your food is listed for you, with amounts and expiry dates filled in. Check the list, fix anything, and save. You can also add items by hand from a list of about 1,000 common foods.

SEE WHAT EXPIRES FIRST
Your pantry, fridge and freezer are sorted by what needs using soonest. Get one daily reminder before food expires. Staples like salt, oil and spices stay in a separate list with no dates to manage.

RECIPES FROM WHAT YOU HAVE
Get recipe ideas built around what's in your kitchen, starting with what expires first. Choose the meal, time, cuisine and servings. Recipes leave out the allergies and diets you set, and show what you have and what's missing.

COOK, SHOP AND SHARE
• Tap "Cooked this" and the ingredients you used come out of your pantry.
• Add what's missing to a shopping list sorted by aisle, then move what you bought into your pantry.
• Save recipes, write your own, scale servings, and see approximate nutrition.
• Share a recipe with a link anyone can open, or export it as a PDF.
• Works offline: your pantry, saved recipes and shopping list are on your phone.

NO SIGN-UP
There's no account to create, and no email or name needed. Delete everything at any time in Settings.

FREE AND PREMIUM
Your pantry, saved recipes, shopping list, reminders and sharing are free. Scanning and recipe ideas are part of a monthly or yearly subscription.

Subscriptions renew automatically until cancelled. Payment is charged to your Apple ID at confirmation, and you can manage or cancel anytime in Settings → Apple ID → Subscriptions at least 24 hours before the end of the current period.

Good to know: scanning and recipe ideas use AI from Anthropic. Photos are used to identify food and aren't stored. Nutrition is approximate. Always check that meat, poultry, fish and eggs reach safe temperatures, and read ingredient labels if you have allergies.

Privacy policy: https://fridge-share.fridge-app.workers.dev/privacy
Terms of use: https://www.apple.com/legal/internet-services/itunes/dev/stdeula/
```

## Other fields
- **Primary category:** Food & Drink. **Secondary:** Lifestyle.
- **Age rating:** 4+ (every questionnaire answer is "None").
- **Support URL:** needs a page; the share site could host `/support` with the contact email (fridgefoodscanner@gmail.com).
- **Privacy policy URL:** https://fridge-share.fridge-app.workers.dev/privacy
- **Copyright:** 2026 <your name>

## App Review notes (draft)
```
No sign-in is needed: the app creates an anonymous account on first launch, so every feature can
be tested right away. Scanning and recipe ideas need a subscription; Sandbox purchases from the
review build are accepted. Any photo of groceries works for testing the scan. Settings → Delete
account removes all data. Scanning and recipe ideas send data to Anthropic's AI only after the
user agrees on the consent screen shown before first use.
```

## Screenshots (once the app is final)
Required sizes: 6.9" (iPhone 16 Pro Max) and 6.5". Suggested five, each with a one-line caption:
1. Scan: "Snap a shelf. Your food is listed for you."
2. Pantry: "See what expires first."
3. Recipe ideas: "Recipes from what you already have."
4. Recipe detail: "Know what you have and what's missing."
5. Shopping list: "Add what's missing, sorted by aisle."
