# Feature specs

One spec per feature in [DESIGN.md §10](../DESIGN.md#10-feature-breakdown-v1). Each spec has a summary, behavior, data/API and testable acceptance criteria.

**Proto** column: **yes** = in the prototype (DESIGN §9), **part** = a reduced version, **no** = v1 only.

| ID | Feature | Size | Proto | Depends on |
|---|---|---|---|---|
| [F0.1](F0.1-project-setup.md) | Project setup | S | yes | — |
| [F0.2](F0.2-auth-and-sessions.md) | Auth & sessions | M | part (anonymous) | F0.1, F0.3 |
| [F0.3](F0.3-schemas.md) | Schemas | M | yes | F0.1 |
| [F0.4](F0.4-catalog-seed.md) | Catalog seed | L | part (~100 items) | F0.3 |
| [F0.5](F0.5-ai-functions.md) | AI functions | M | yes | F0.1, F0.3 |
| [F1.1](F1.1-photo-scan.md) | Photo scan | M | yes | F0.2, F0.5 |
| [F1.2](F1.2-ingredient-detection.md) | Ingredient detection | L | yes | F0.4, F0.5, F1.1 |
| [F1.3](F1.3-scan-review.md) | Scan review | M | yes | F1.2, F1.5, F1.6 |
| [F1.4](F1.4-pantry-list.md) | Pantry list | M | yes | F0.3, F1.6 |
| [F1.5](F1.5-manual-add-edit.md) | Manual add & edit | M | yes | F0.4, F1.6 |
| [F1.6](F1.6-expiry-rules.md) | Expiry rules | S | yes | F0.3, F0.4 |
| [F1.7](F1.7-onboarding-prefs.md) | Onboarding & prefs | S | yes | F0.2, F0.4 |
| [F2.1](F2.1-request-options.md) | Request options | S | yes | F1.4, F1.7 |
| [F2.2](F2.2-generation-pipeline.md) | Generation pipeline | L | yes | F0.5, F1.7, F2.1, F2.3 |
| [F2.3](F2.3-macros.md) | Macros | M | yes | F0.4, F0.5 |
| [F2.4](F2.4-results-ui.md) | Results UI | M | yes | F2.2 |
| [F3.1](F3.1-save-and-list.md) | Save & list | M | part (no 50 limit) | F0.3, F2.4 |
| [F3.2](F3.2-edit-recipe.md) | Edit recipe | M | yes | F3.1, F2.3 |
| [F3.3](F3.3-delete-recipe.md) | Delete recipe | S | yes | F3.1 |
| [F3.4](F3.4-cooked-this.md) | "Cooked this" | M | yes | F1.4, F2.4 |
| [F3.5](F3.5-shopping-list.md) | Shopping list | M | yes | F1.5, F1.6, F2.4 |
| [F3.6](F3.6-offline-cache.md) | Offline cache & sync | L | no | F0.3, Phases 1–3 |
| [F4.1](F4.1-share-link.md) | Share link | S | no | F3.1 |
| [F4.2](F4.2-public-page.md) | Public page | M | no | F4.1 |
| [F4.3](F4.3-universal-links.md) | Universal Links | M | no | F4.1, F4.2, F3.1 |
| [F4.4](F4.4-export.md) | Export text/PDF | S | no | F3.1 |
| [F5.1](F5.1-expiry-notifications.md) | Expiry notifications | S | yes (local) | F1.4, F1.6 |
| [F5.2](F5.2-observability.md) | Observability | S | part (events + cost) | F0.5 |
| [F5.3](F5.3-app-store-readiness.md) | App Store readiness | M | no | all v1 |

## Suggested prototype build order
1. **Foundation:** F0.1 → F0.3 → F0.4 (prototype seed) → F0.2 (anonymous) → F0.5
2. **Pantry without AI:** F1.6 → F1.5 → F1.4 → F1.7. The app is already useful at this point, and it's the cheapest way to check the data model.
3. **Scanning:** F1.1 → F1.2 (run the eval) → F1.3
4. **Recipes:** F2.3 → F2.1 → F2.2 (run the eval) → F2.4
5. **Recipe management and the rest:** F3.1 → F3.3 → F3.2 → F3.4 → F3.5 → F5.1 → F5.2 events

## Open decisions found while writing the specs
| # | Decision | Recommendation | Spec |
|---|---|---|---|
| 1 | Add `catalog.ingredients.allergens` | **Yes.** Without it, allergens can't be checked in code. | F1.7, F2.2, F0.4 |
| 2 | Add `location` to `user_shelf_life_overrides` | **Yes.** "Milk lasts 10 days" shouldn't apply to frozen milk. | F1.6 |
| 3 | Estimate nutrition for unknown scanned items later, not during the scan | **Yes.** Same as manual entry, and keeps the scan prompt smaller (update DESIGN §6.1a step 7). | F1.2 |
| 4 | Share page shows the live recipe or a snapshot taken at share time | **Live recipe;** the recipient saves the snapshot. | F4.1 |
| 5 | Where to host the share page | **Cloudflare Worker on your own domain.** Supabase HTML and custom-domain limits; check first. | F4.2 |
| 6 | `updated_at`/`deleted_at` and soft deletes on synced tables | **Yes, in v1,** needed for offline sync | F3.6, F0.3 |
| 7 | `recipes.source` gains `'shared'` | **Yes** | F4.3 |
| 8 | "Only use what I have" option for generation | **Yes for v1,** cheap to add | F2.1 |
