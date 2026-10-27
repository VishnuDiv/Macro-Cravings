# Creami Cravings (iOS app)

Personal SwiftUI iPhone app for Ninja Creami recipes. Design contract: `docs/SPEC.md`.

- Build: Xcode project `CreamiCravings.xcodeproj` (synchronized folder: files under `CreamiCravings/` are in the target automatically; don't hand-edit the pbxproj). iOS 18.0+, no packages.
- Data: run `python3 -I tools/build_data.py` after changing anything in `data/` to regenerate `CreamiCravings/Resources/recipes.json` and copy the catalog.
- Catalog accuracy check: `python3 -I tools/calibrate_catalog.py data/book_recipes.json data/catalog/ingredients.json`.
- Logic checks (no Xcode needed): `tools/logic_checks/run.sh`.
- Book-derived data, photos and the generated recipes.json are personal-use content and are gitignored; never commit them. Web recipes keep ingredient facts only, with steps in our own words and a source link.
