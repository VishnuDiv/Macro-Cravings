#!/usr/bin/env python3
"""Acceptance check for docs/DATA_FIXES_SPEC.md on the built CreamiCravings/Resources/recipes.json.

Reports (each should be 0):
  - vegetarian=true recipes, and veg versions, that still have a line or veg step matching a meat/fish word or an
    unswapped hidden-meat sauce (instant packet in ramen recipes, caesar, Worcestershire, fish sauce, oyster sauce,
    Parmesan, pesto, meat stock, gelatin, collagen);
  - negative fat (recipe macros or vegAdaptation macros);
  - duplicate source URLs.
Usage: check_data_fixes.py [recipes.json]   Exit code 1 when anything is non-zero.
"""
import json
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PATH = sys.argv[1] if len(sys.argv) > 1 else os.path.join(ROOT, "CreamiCravings", "Resources", "recipes.json")
I = re.IGNORECASE

MEAT = re.compile(r"\b(chicken|beef|steak|pork|bacon|ham|turkey|sausages?|fish|salmon|tuna|prawns?|shrimp|lamb|chorizo|pepperoni|anchov\w*|"
                  r"brisket|veal|duck|crab|lobster|cod|tilapia|mince(d)? (beef|meat|pork|lamb))\b", I)
# a meat word is fine when the same line or step says it is not real meat
NOT_MEAT = re.compile(r"vegan|vegetarian|\bveg\b|veggie|plant|meat-free|meatless|faux|imitation|mock|seitan|tofu|tempeh|soy|jackfruit|"
                      r"mushroom|quorn|mycoprotein|beyond|impossible|paneer|chicken[- ]style|chicken-flavou?r|no[- ]chicken|\"chicken\"|'chicken'|"
                      r"chicken seasoning|chicken spice|steak seasoning|same seasonings?|same spice blend|steak bites|tomato tuna|salmon-style|'tuna'|pepper tuna|coconut bacon|egg|noodle soup flavo", I)
SAUCE = [
    ("caesar", re.compile(r"caesar dressing", I)),
    ("worcestershire", re.compile(r"worcestershire", I)),
    ("fish sauce", re.compile(r"fish sauce", I)),
    ("oyster sauce", re.compile(r"oyster sauce", I)),
    ("parmesan", re.compile(r"parmesan|pecorino|grana padano", I)),
    ("pesto", re.compile(r"pesto", I)),
    ("meat stock", re.compile(r"\b(chicken|beef)\s+(bone\s+)?(stock|broth|bouillon|boullion)\b", I)),
    ("gelatin", re.compile(r"gelatin", I)),
    ("collagen", re.compile(r"collagen", I)),
]
VEGGY = re.compile(r"vegan|vegetarian|\bveg\b|veggie|plant|mushroom|rennet-free|[- ]free\b", I)
RAMEN = re.compile(r"instant ramen|packet|seasoning packet|flavou?r packet|nissin|top ramen|maruchan|cup noodle", I)


def lines_after_swaps(r):
    """Original lines, with swapped ones replaced by their veg substitute."""
    va = r.get("vegAdaptation") or {}
    repl = {s.get("replaces"): (s.get("with") or {}).get("text") for s in va.get("swaps") or []}
    return [repl.get(l.get("text"), l.get("text")) or "" for l in (r.get("base") or []) + (r.get("mixIns") or [])]


def body(text):
    """Drops a leading "Sub heading: " label ("Smokey beef: 1 red onion"), which is not an ingredient."""
    m = re.match(r"^[A-Za-z' &/-]{2,40}:\s*(.+)$", text)
    return m.group(1) if m else text


def problems(r):
    va = r.get("vegAdaptation")
    if r.get("vegetarian") is True:
        lines, steps = [l.get("text") or "" for l in (r.get("base") or []) + (r.get("mixIns") or [])], r.get("instructions") or []
    elif va and r.get("vegetarian") is False:
        lines, steps = lines_after_swaps(r), va.get("steps") or []
    else:
        return []
    out = []
    subs = " ".join(((s.get("with") or {}).get("text") or "") + " " + ((s.get("with") or {}).get("key") or "") for s in (va or {}).get("swaps") or []).lower()
    ramen_recipe = "ramen" in (r.get("name") or "").lower() + " ".join(r.get("tags") or [])
    line_bodies = [body(x) for x in lines]
    for t, is_line in [(x, True) for x in line_bodies] + [(x, False) for x in steps]:
        m = MEAT.search(re.sub(r"\([^)]*\)", "", t) if is_line else t)     # parenthetical hints on lines are not ingredients
        if m and not NOT_MEAT.search(t) and re.sub(r"s$", "", m.group(0).lower()) not in subs:
            out.append("meat word '%s': %s" % (m.group(0), t[:90]))
        for name, rx in SAUCE:
            if not rx.search(t) or VEGGY.search(t):
                continue
            # a step may mention a sauce whose ingredient line is already the veg version
            if not is_line and any(rx.search(l) and VEGGY.search(l) for l in lines):
                continue
            out.append("%s: %s" % (name, t[:90]))
        if is_line and ramen_recipe and RAMEN.search(t) and not re.search(r"miso|vegan|vegetarian|discard|noodles only", t, I):
            out.append("ramen packet: " + t[:90])
    return out


def norm_url(u):
    u = re.sub(r"^https?://(www\.)?", "", (u or "").strip().lower())
    return re.split(r"[?#]", u)[0].rstrip("/")


def main():
    recipes = json.load(open(PATH))
    bad = {}
    for r in recipes:
        p = problems(r)
        if p:
            bad[r["id"]] = p
    neg = []
    for r in recipes:
        for label, m in (("macros", r.get("macros")), ("veg macros", (r.get("vegAdaptation") or {}).get("macrosPerServing"))):
            if m and isinstance(m.get("fat"), (int, float)) and m["fat"] < 0:
                neg.append("%s %s fat %s" % (r["id"], label, m["fat"]))
    # same rule as data_fixes.fix12: one URL is a duplicate only when the ingredient key sets overlap by 80% or more
    def key_set(r):
        return {g.get("key") for s in ("base", "mixIns") for g in (r.get(s) or []) if g.get("key")}

    seen, dups = {}, []
    for r in recipes:
        u = norm_url((r.get("source") or {}).get("url"))
        if u:
            keys = key_set(r)
            for other_id, k in seen.get(u, []):
                if len(keys & k) >= 0.8 * max(1, len(keys | k)):
                    dups.append("%s == %s" % (r["id"], other_id))
                    break
            seen.setdefault(u, []).append((r["id"], keys))
    print("recipes: %d" % len(recipes))
    print("veg recipes/versions with meat/hidden-meat leftovers: %d" % len(bad))
    for i, p in list(bad.items())[:40]:
        print("  %s: %s" % (i, "; ".join(p[:3])))
    print("negative fat: %d %s" % (len(neg), neg[:10]))
    print("duplicate source URLs: %d %s" % (len(dups), dups[:10]))
    return 1 if (bad or neg or dups) else 0


if __name__ == "__main__":
    sys.exit(main())
