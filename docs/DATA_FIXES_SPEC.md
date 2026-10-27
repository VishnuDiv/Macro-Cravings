# Data fixes from the Opus review (2026-10-27)

Implement these as **build-time fixes** in a new module `tools/data_fixes.py`, called by `tools/build_data.py` after aliasing, so they are reproducible whenever data is rebuilt. Don't edit data/books/*.json or data/web/*.json for these. Other agents own those files. Each fix logs a count. All text matching is case-insensitive.

## Helper: `ensure_veg_swap(recipe, line, with_ing, note, steps_replace={old: new})`
If the recipe has no vegAdaptation, create one:
- `swaps` = []
- `steps` = a copy of `instructions`
- `macrosPerServing` = a copy of `macrosPerServing` (or null)
- `summary` = ""

Then:
- Append the swap. `replaces` is the exact line text.
- Apply `steps_replace` to the steps (plain substring replacement).
- Set `vegetarian` = false.
- Append to `summary`, joined with "; ". For example: "Parmesan → vegetarian hard cheese".
- Macros are unchanged for like-for-like swaps.
- Skip the line if a swap for it already exists.

## A. Vegetarian safety
1. **Instant ramen packets.** A line matches when it contains a ramen or noodle term (`instant ramen|ramen noodles|noodle pack|packet|seasoning packet|flavor packet|flavour packet|nissin|top ramen|maruchan|cup noodle`), the recipe is NOT already vegetarian=false for buldak, and the recipe has the tag "ramen" or "pantry", or its name contains "ramen". Then call `ensure_veg_swap`:
   - with: `{"text": "Instant ramen noodles (discard the flavor packet unless labelled vegan) + 1 tsp white miso + 1 tsp vegetable bouillon", "key": "instant_ramen", ...}`, keeping the original grams/count;
   - note: "Most ramen flavor packets contain chicken or beef extract. Maruchan and Nissin vegan or 'Oriental' packets vary, so check the label, or use the miso + bouillon base."
2. **Hidden-meat sauces.** Swap these lines in every recipe, unless the line text already says vegan, vegetarian, veg, meat-free or plant:
   | Line contains | Swap to (text, key) |
   |---|---|
   | caesar dressing | "Vegetarian Caesar dressing (e.g. Primal Kitchen Vegan Caesar, or Greek yogurt + lemon + capers + rennet-free Parmesan)", `caesar_dressing_vegetarian` |
   | worcestershire | "Vegetarian Worcestershire sauce (e.g. Annie's, Henderson's Relish)", `vegetarian_worcestershire` |
   | fish sauce | "Soy sauce + ½ tsp white miso (or vegan fish sauce)", `soy_sauce_miso` |
   | oyster sauce (but not "mushroom") | "Vegetarian mushroom 'oyster' sauce (Lee Kum Kee Vegetarian Stir-Fry Sauce)", `vegetarian_oyster_sauce` |
   | parmesan, pecorino or grana padano | "Vegetarian hard cheese (rennet-free Parmesan-style, e.g. BelGioioso Vegetarian Parmesan, Trader Joe's)", `vegetarian_parmesan` |
   | pesto | "Vegetarian pesto (rennet-free cheese; e.g. Trader Joe's Vegan Kale Cashew Basil Pesto, or homemade)", `vegetarian_pesto` |
   | chicken/beef stock, broth or bouillon | "Vegetable stock/broth (same amount)", `vegetable_stock` |
   | gelatin or gelatine | "Agar powder (1 tsp agar ≈ 1 tbsp gelatin)", `agar_powder` |
   | marshmallow (not "vegan"), only in non-creami recipes | "Vegan marshmallows (Dandies)", `vegan_marshmallows` |

   Also replace the matching words in the steps via steps_replace: "parmesan" → "vegetarian hard cheese", "worcestershire" → "vegetarian Worcestershire", "chicken stock"/"beef stock"/"chicken broth"/"beef broth" → "vegetable stock". For creami-section recipes (no vegAdaptation UI), don't create a vegAdaptation; the catalog callout covers them.
3. **Collagen.** Any line whose text contains "collagen" gets key `collagen_powder`, with grams kept. For non-creami recipes, also call ensure_veg_swap with "Unflavored whey or casein protein powder (same grams)", key `protein_powder_unflavored`.
4. **chef-breakfast-crunchwraps.** Swap the line "1 crispy beef tortilla" (match on substring "crispy beef tortilla") with "1 crispy tortilla filled with seasoned soy mince (from the soy-mince filling)", key `tortilla_wrap`.

## B. Macros
5. **Vegetarian fat floor and lean-meat fat.**
   - For each book vegAdaptation with a meat swap, re-derive the meat's fat per 100 g. If the replaced line has `(\d+)%` (e.g. "5% beef mince"), use that number. Otherwise, if it says "lean", use min(rubric fat, 4) with these rubric fats: chicken breast 2.6, thigh 6, ground chicken/turkey 8, beef mince 5% → 5, steak 7, bacon medallion 4.
   - Compute fatDelta = (rubricFat − derivedFat) × meatGrams / 100 / servings, and set veg fat += fatDelta. Raise kcal by 9 × fatDelta.
   - Then floor: veg fat ≥ sum over swaps of (sub fat per 100 g × sub grams / 100 / servings). Sub fat values: seitan 2, extra-firm tofu 8, super-firm tofu 9, paneer 24, low-fat paneer 10, soy chunks 1, tempeh 11, plant mince 14, mycoprotein 3, veggie sausage 15, veggie bacon 15, veggie pepperoni 18, vegan chicken 8. If the floor raises fat, raise kcal by 9× the increase.
   - Round to whole numbers. Log every recipe that changed.
   - The review's targets: chef-pepper-steak-rice-bowls ends at about 4–6 g fat. chef-sheetpan-chicken-kebabs, chef-sheetpan-chicken-kebab-wrap and chef-creamy-garlic-chicken-meatballs end non-negative.
6. **Implausible web macros.** Set macrosPerServing (and therefore macros) to null when: |kcal − (4P+4C+9F)| / kcal > 0.35 (only when P, C and F are all present); OR fiber > 40 per serving; OR kcal per serving > 2500. Always null these: web-meal-loaded-vegetarian-nachos-high-protein-theherbeevore, web-meal-vegan-japchae-okonomi-kitchen, web-meal-quinoa-idli-ministryofcurry, web-meal-instant-pot-refried-beans-skinnytaste. Add a note to evidence.summary: "Source nutrition looked wrong; showing calculated estimate."
7. **Per-piece servings.** Set `servingLabel` = "piece" when servings ≥ 10 and kcal per serving < 150, or when the name matches nugget|falafel|bite|ball|idli|cookie|muffin|wing and servings ≥ 6. For falafel recipes with course dinner, change course to snack.

## C. Cooking
8. **Baking soda with seitan.** In vegAdaptations where any swap's `with.key` is seitan: add a swap for any line containing "baking soda" or "bicarbonate", replacing it with `{"text": "(Omit the baking soda — not needed for seitan)", "key": "mix_in_choice", grams 0}`. Remove any step sentence that mentions baking soda or bicarbonate.
9. **Missing book lines.** chef-cheesy-chicken-bites: append base lines "30 g plain flour (for coating)" (key flour) and "1 egg, beaten" (key eggs, count 1). chef-nashville-hot-chicken-sandwich: append mixIns "Shredded cabbage (to serve)" (key cabbage) and "Pickle slices (to serve)" (key pickles).

## D. Keys
10. **Re-key by text**, for lines whose key looks wrong:
    - "salt and pepper", "salt & pepper", "black pepper" or "pepper to taste" keyed bell_pepper → `salt` or `black_pepper`
    - "rice vinegar" → `rice_vinegar`
    - "sesame oil" → `sesame_oil`
    - plain "oil" or "olive oil" keyed soy_sauce → `olive_oil`
    - "rice noodles" → `rice_noodles`
    - "tamarind" → `tamarind_paste`
    - "low-fat paneer" or "low fat paneer" keyed paneer → `paneer_low_fat`
11. **Canonical swap keys.** Map `with.key` values: veg_sausage → veggie_sausage; soy_chunks_dry and soy_mince_dry → soy_chunks; plant_mince and beyond_mince → plant_based_mince; supertofu and tofu_high_protein → tofu_super_firm; smoky_veg_rashers → veggie_bacon; vegetarian_pepperoni and veggie_pepperoni_slices → veggie_pepperoni; veg_hard_cheese, vegetarian_hard_cheese and veg_parmesan → vegetarian_parmesan; vegetable_broth, vegetable_bouillon and vegetable_stock_cube → vegetable_stock; veg_worcestershire, vegan_worcestershire and worcestershire_vegetarian → vegetarian_worcestershire.

## E. Duplicates
12. Dedupe web recipes by normalized source.url, keeping the first, and log the drops.
13. Book cross-duplicates: chef and bulk recipes whose normalized names match after removing the words high, protein and anabolic, AND whose calories are within 10%. Keep the chef version and add `source.alsoIn` = "The Ultimate Guide to Lean Bulking p.N". The review named the pizza bagels, the fudge brownies and the popcorn chicken.

## F. App (Swift)
14. **Veg-mode proTip.** In vegetarian mode, the proTip drops any sentence that contains a meat or fish word (chicken, beef, steak, pork, bacon unless preceded by "veggie", turkey, ham, sausage unless preceded by "veggie", shrimp, prawn, salmon, tuna, fish). If nothing is left, hide the card.
15. `servingLabel` = "piece": macros read "per piece", and the servings stepper becomes a "pieces" stepper.
16. Decode `source.alsoIn` and show it under the source line: "Also in: …".

## Acceptance
- `tools/data_fixes.py` has unit tests in `tools/test_data_fixes.py`, with at least one case per numbered fix.
- After `build_data.py`, a check script reports zero of each:
  - recipes that are vegetarian=true or have a veg version AND still have a line or veg step matching a meat or fish word or an unswapped hidden-meat sauce (instant packet in ramen recipes, caesar, Worcestershire, fish sauce, oyster sauce, Parmesan, pesto, meat stock, gelatin, collagen) not covered by a swap;
  - negative fat;
  - duplicate source URLs.
- Report the counts per fix.
- run.sh passes, and the iOS build is clean.
