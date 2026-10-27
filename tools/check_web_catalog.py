#!/usr/bin/env python3
"""Check web recipes against the ingredient catalog (after key aliases).

Usage: check_web_catalog.py [data dir] [--no-fill]   (default: <project>/data)

Prints: unresolved keys (must be 0), lines resolving to 0 g, and for recipes with source macros the
calculated calories (SPEC grams rule, optional lines skipped) vs the source: median |%diff| and the worst 10.
Exit code 1 if any key is unresolved.
"""
import glob
import importlib.util
import json
import os
import statistics
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ARGS = [a for a in sys.argv[1:] if not a.startswith("--")]
NO_FILL = "--no-fill" in sys.argv          # skip the build-time amount parsing (to compare before/after)
DATA = ARGS[0] if ARGS else os.path.join(ROOT, "data")

_spec = importlib.util.spec_from_file_location("build_data", os.path.join(ROOT, "tools", "build_data.py"))
_bd = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_bd)


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
    cat = json.load(open(os.path.join(DATA, "catalog", "ingredients.json")))
    ap = os.path.join(DATA, "catalog", "key_aliases.json")
    aliases = json.load(open(ap)) if os.path.exists(ap) else {}
    unresolved, zero, rows, nrec = {}, 0, [], 0
    for fp in sorted(glob.glob(os.path.join(DATA, "web", "*.json"))):
        items = json.load(open(fp))
        if isinstance(items, dict):
            items = items.get("recipes", [])
        for r in items:
            nrec += 1
            kcal, nz, nlines = 0.0, 0, 0
            for line in (r.get("base") or []) + (r.get("mixIns") or []):
                if not NO_FILL and line.get("grams") is None and line.get("ml") is None and line.get("count") is None:
                    line = {**line, **(_bd.parse_amount(line.get("text") or "") or {})}   # same rule as build_data.fill_amounts
                key = line.get("key")
                ing = cat.get(aliases.get(key, key))
                if ing is None:
                    unresolved.setdefault(key, []).append(r.get("id"))
                    continue
                if line.get("optional"):
                    continue
                nlines += 1
                g = line_grams(line, ing)
                if g == 0 and ing["per100g"]["calories"] > 0:
                    nz += 1
                kcal += ing["per100g"]["calories"] * g / 100
            zero += nz
            src = (r.get("macros") or {}).get("calories")
            if src:
                rows.append((r.get("id"), os.path.basename(fp), src, kcal, nz, nlines))

    print(f"web recipes: {nrec}   catalog entries: {len(cat)}   aliases: {len(aliases)}")
    print(f"unresolved keys: {len(unresolved)}" + (": " + ", ".join(sorted(unresolved)) if unresolved else ""))
    print(f"non-optional lines with calories that resolve to 0 g (no amount parsed): {zero}")
    if rows:
        diffs = [(abs(c / s - 1) * 100, rid, fn, s, c, nz, nl) for rid, fn, s, c, nz, nl in rows]
        full = [d for d in diffs if d[5] == 0]
        print(f"\nrecipes with source calories: {len(rows)}   median |diff| {statistics.median(d[0] for d in diffs):.1f}%"
              f"   within 15%: {sum(d[0] <= 15 for d in diffs)}")
        if full:
            print(f"  of these, all amounts known: {len(full)}   median |diff| {statistics.median(d[0] for d in full):.1f}%"
                  f"   within 15%: {sum(d[0] <= 15 for d in full)}")
        print(f"\n{'worst 10':58} {'source':>6} {'calc':>6} {'%diff':>7} {'0g lines':>8}")
        for d, rid, fn, s, c, nz, nl in sorted(diffs, reverse=True)[:10]:
            print(f"{rid[:58]:58} {s:6.0f} {c:6.0f} {(c / s - 1) * 100:+7.1f} {nz:>4}/{nl}")
    return 1 if unresolved else 0


if __name__ == "__main__":
    sys.exit(main())
