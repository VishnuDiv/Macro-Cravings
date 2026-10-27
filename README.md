# Macro Kitchen

A personal SwiftUI iPhone app for high-protein, vegetarian-friendly cooking: Ninja Creami pints, meals, desserts and drinks, with macros that follow your actual milk, protein powder and swaps.

## Features
- Search, favorites, filters (section, course, cuisine, tags, macros, fiber, allergens, pantry, affiliate products) and sorts (Featured, Healthiest, High fiber…)
- Milk and protein-powder pickers that recalculate calories; nutrition from the recipe, an ingredient database, Open Food Facts barcode lookup, or a typed-in label
- Vegetarian mode: meat recipes open as protein-matched vegetarian versions, with ranked alternatives (availability, where to buy, prep) and warnings for hidden non-veg ingredients
- Ingredient swaps and store-bought or homemade alternatives, pantry tracking, shopping list, cook mode, freeze/chill timers, made-it log
- Guides: high-protein paneer (with a yield and macro calculator per milk), vegetarian protein sources, seitan, tofu, best protein powders for cooking

## Data
Recipe content is **not in this repository**. The app is built from local files that stay on the owner's machine (see `.gitignore`): personally purchased recipe books and recipes collected from creators' websites. The repository contains the app, the build and check tools, and original data (ingredient catalog, milks, protein powders, vegetarian alternatives, guides, paneer model).

To build with your own data, put recipe JSON in `data/` as described in `docs/SPEC.md`, then:

```bash
python3 -I tools/build_data.py        # builds CreamiCravings/Resources/recipes.json
python3 -I tools/check_data_fixes.py  # vegetarian-safety and data checks
tools/logic_checks/run.sh             # logic tests (no Xcode needed)
```

## Building
1. `cp Signing.xcconfig.example Signing.xcconfig` and put your Apple Developer Team ID in it.
2. Open `CreamiCravings.xcodeproj` in Xcode 26 or later and run on an iPhone (iOS 18+).
