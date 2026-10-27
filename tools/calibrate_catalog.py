#!/usr/bin/env python3
"""Check the ingredient catalog against the book's per-pint macros.

Usage: calibrate_catalog.py <book_recipes.json> <ingredients.json> [base_liquids.json]

Applies the SPEC grams rule (grams ?? ml*gramsPerMl(1.0) ?? count*gramsPerCount ?? defaultGrams ?? 0),
skips optional lines, sums calories and protein per recipe and compares with recipe.macros.
Also reports recipe keys missing from the catalog, swap keys that don't resolve, affiliate / milk / shake
entries without both alternatives, and base-liquid ingredientKeys missing from the catalog.
Exit code 1 if any acceptance check fails.
"""
import json
import os
import statistics
import sys

LIQUID_CATS = {"milk", "ultra_filtered", "plant_milk", "protein_shake"}


def line_grams(line, ing):
    if line.get("grams") is not None:
        return line["grams"]
    if line.get("ml") is not None:
        return line["ml"] * (ing.get("gramsPerMl") or 1.0)
    if line.get("count") is not None and ing.get("gramsPerCount") is not None:
        return line["count"] * ing["gramsPerCount"]
    if ing.get("defaultGrams") is not None:
        return ing["defaultGrams"]
    return 0.0


def main():
    if len(sys.argv) < 3:
        sys.exit(__doc__)
    recipes = json.load(open(sys.argv[1]))
    cat = json.load(open(sys.argv[2]))
    bl_path = sys.argv[3] if len(sys.argv) > 3 else os.path.join(os.path.dirname(sys.argv[2]), "base_liquids.json")
    liquids = json.load(open(bl_path)) if os.path.exists(bl_path) else []

    missing, rows, unknown = set(), [], []
    for r in recipes:
        kcal = prot = 0.0
        for line in r.get("base", []) + r.get("mixIns", []):
            if line.get("optional"):
                continue
            ing = cat.get(line["key"])
            if ing is None:
                missing.add(line["key"])
                continue
            g = line_grams(line, ing)
            if g == 0:
                unknown.append((r["id"], line["key"]))
            kcal += ing["per100g"]["calories"] * g / 100
            prot += ing["per100g"]["protein"] * g / 100
        m = r.get("macros") or {}
        if m.get("calories"):
            rows.append((r["id"], m["calories"], kcal, m.get("protein"), prot))

    print(f"{'id':38} {'book':>5} {'calc':>6} {'%diff':>7} {'bookP':>6} {'calcP':>6} {'%P':>6}")
    kd, pd = [], []
    for rid, bk, ck, bp, cp in sorted(rows, key=lambda x: -abs(x[2] / x[1] - 1)):
        d = (ck / bk - 1) * 100
        kd.append(d)
        p = (cp / bp - 1) * 100 if bp else 0.0
        pd.append(p)
        print(f"{rid:38} {bk:5.0f} {ck:6.0f} {d:+7.1f} {bp or 0:6.0f} {cp:6.1f} {p:+6.1f}")

    n = len(rows)
    k15 = sum(abs(d) <= 15 for d in kd)
    p20 = sum(abs(p) <= 20 for p in pd)
    med = statistics.median(abs(d) for d in kd) if kd else 0
    print(f"\nRecipes with book macros: {n}")
    print(f"Calories within +-15%: {k15}/{n} ({k15 / n * 100:.0f}%)   median |diff| {med:.1f}%   mean diff {statistics.mean(kd):+.1f}%")
    print(f"Protein within +-20%:  {p20}/{n} ({p20 / n * 100:.0f}%)   median |diff| {statistics.median(abs(p) for p in pd):.1f}%   mean diff {statistics.mean(pd):+.1f}%")
    if unknown:
        print(f"Lines resolving to 0 g (not counted): {len(unknown)}: " + ", ".join(f"{a}:{b}" for a, b in unknown))

    dangling = sorted({(k, s["key"]) for k, v in cat.items() for s in v.get("swaps", []) if s.get("key") and s["key"] not in cat})
    no_alt = sorted(k for k, v in cat.items()
                    if (v.get("affiliate") or v["category"] in LIQUID_CATS)
                    and not (v.get("storeAlternative") and v.get("homemadeAlternative")))
    bad_bl = sorted(b["id"] for b in liquids if b.get("ingredientKey") not in cat)

    print(f"\nCatalog entries: {len(cat)}   base liquids: {len(liquids)}")
    print(f"Missing keys ({len(missing)}): {', '.join(sorted(missing)) or '-'}")
    print(f"Dangling swap keys ({len(dangling)}): {', '.join(f'{a}->{b}' for a, b in dangling) or '-'}")
    print(f"Affiliate/milk/shake entries missing an alternative ({len(no_alt)}): {', '.join(no_alt) or '-'}")
    print(f"Base liquids with unknown ingredientKey ({len(bad_bl)}): {', '.join(bad_bl) or '-'}")

    ok = (not missing and not dangling and not no_alt and not bad_bl
          and k15 >= 0.8 * n and med <= 8 and p20 >= 0.8 * n)
    print("\nACCEPTANCE:", "PASS" if ok else "FAIL")
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
