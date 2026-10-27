#!/usr/bin/env python3
"""Build CreamiCravings/Resources/recipes.json (+ copy catalog files) from data/.

Run: python3 -I tools/build_data.py
"""
import glob
import json
import os
import re
import shutil
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DATA = os.environ.get("CREAMI_DATA") or os.path.join(ROOT, "data")          # overridable for tests
RES = os.environ.get("CREAMI_RES") or os.path.join(ROOT, "CreamiCravings", "Resources")

FLAVOR_RULES = [
    ("chocolate", ["chocolate", "cocoa", "brownie", "fudge"]),
    ("peanut-butter", ["peanut"]),
    ("coffee", ["coffee", "espresso", "jamoca", "tiramisu"]),
    ("cookies", ["cookie", "oreo", "dough"]),
    ("caramel", ["caramel", "toffee", "rolo"]),
    ("mint", ["mint", "shamrock", "peppermint"]),
    ("cheesecake", ["cheesecake"]),
    ("cake", ["cake", "birthday", "confetti", "red velvet"]),
    ("seasonal", ["pumpkin", "shamrock", "minter"]),
]
FRUIT_KEYS = ["strawberries", "cherries", "raspberries", "banana", "lime"]
NUT_RE = re.compile(r"almond|walnut|pecan|cashew|pistachio|hazelnut|macadamia|peanut|nutella|nut_butter|pine_nut|^nuts$")


UNI = {"½": 0.5, "⅓": 1 / 3, "⅔": 2 / 3, "¼": 0.25, "¾": 0.75, "⅛": 0.125, "⅜": 0.375, "⅝": 0.625, "⅞": 0.875}
_NUM = r"(?:\d+\s+\d+/\d+|\d+\s*[%s]|\d+/\d+|\d*\.\d+|\d+|[%s])" % ("".join(UNI), "".join(UNI))
_QTY = r"(?P<q>%s)(?:\s*(?:-|–|—|to)\s*(?P<q2>%s))?" % (_NUM, _NUM)
# (regex alternatives, field, factor); longest/most specific first
_UNITS = [
    (r"fl\.?\s*oz\.?|fluid\s+ounces?", "ml", 29.57),
    (r"cups?", "ml", 240.0),
    (r"tablespoons?|tbsp\.?|tbs\.?", "ml", 15.0),
    (r"teaspoons?|tsp\.?", "ml", 5.0),
    (r"ml|milliliters?", "ml", 1.0),
    (r"kg|kilograms?", "grams", 1000.0),
    (r"pounds?|lbs?\.?", "grams", 453.6),
    (r"ounces?|oz\.?", "grams", 28.35),
    (r"grams?|g", "grams", 1.0),
]
_NOT_COUNT = {"pinch", "pinches", "dash", "dashes", "handful", "splash", "drizzle", "scoop", "scoops", "serving", "servings", "or", "of", "to", "and"}


def _num(t):
    t = t.strip()
    if not t:
        return None
    m = re.fullmatch(r"(\d+)\s*([%s])" % "".join(UNI), t)
    if m:
        return int(m.group(1)) + UNI[m.group(2)]
    if t in UNI:
        return UNI[t]
    m = re.fullmatch(r"(\d+)\s+(\d+)/(\d+)", t)
    if m:
        return int(m.group(1)) + int(m.group(2)) / int(m.group(3))
    m = re.fullmatch(r"(\d+)/(\d+)", t)
    if m:
        return int(m.group(1)) / int(m.group(2)) if int(m.group(2)) else None
    try:
        return float(t)
    except ValueError:
        return None


def parse_amount(text):
    """Returns {"grams"|"ml"|"count": value} from the leading quantity of an ingredient line, or None."""
    t = text.strip()
    t = re.sub(r"^[A-Za-z ]{1,20}:\s*", "", t)          # "Crust: 3/4 cup ..."
    m = re.match(_QTY, t)
    if not m:
        return None
    q = _num(m.group("q"))
    if q is None:
        return None
    if m.group("q2"):
        q2 = _num(m.group("q2"))
        if q2 is not None:
            q = (q + q2) / 2
    rest = t[m.end():].lstrip()
    for pat, field, factor in _UNITS:
        if re.match(r"(?:%s)(?![A-Za-z])" % pat, rest, re.I):
            return {field: round(q * factor, 2)}
    # package size in parentheses: "1 (15 oz) can", "1 box (0.3 oz) ..."
    pm = re.match(r"(?:[A-Za-z]+\s+)?\(\s*(?P<s>%s)\s*(?P<u>[A-Za-z. ]+?)\s*\)" % _NUM, rest)
    if pm:
        size = _num(pm.group("s"))
        for pat, field, factor in _UNITS:
            if size is not None and field == "grams" and re.fullmatch(pat, pm.group("u").strip(), re.I):
                return {"grams": round(q * size * factor, 2)}
    wm = re.match(r"([A-Za-z]+)", rest)
    if wm and wm.group(1).lower() not in _NOT_COUNT:
        return {"count": round(q, 3)}
    return None


def all_ings(r):
    """Base + mix-in lines plus the substitute lines of a vegetarian adaptation."""
    extra = [sw["with"] for sw in ((r.get("vegAdaptation") or {}).get("swaps") or []) if isinstance(sw.get("with"), dict)]
    return r["base"] + r["mixIns"] + extra


def fill_amounts(recipes):
    """Fills grams/ml/count from the line text when all three are null. Returns (parsed, empty)."""
    parsed = empty = 0
    for r in recipes:
        for ing in all_ings(r):
            if ing.get("grams") is None and ing.get("ml") is None and ing.get("count") is None:
                empty += 1
                a = parse_amount(ing.get("text") or "")
                if a:
                    ing.update(a)
                    parsed += 1
    return parsed, empty


def normalize_meal(r):
    """macros = macrosPerServing x servings (vegAdaptation.macrosPerServing stays per serving)."""
    servings = r.get("servings") or 1
    per = r.pop("macrosPerServing", None)
    if per is not None:
        r["macros"] = {k: (round(v * servings, 1) if isinstance(v, (int, float)) else v) for k, v in per.items()}
    r.setdefault("macros", None)
    return r


def load(path, default=None):
    try:
        with open(path, encoding="utf-8") as f:
            return json.load(f)
    except (OSError, ValueError):
        return default


def norm(name):
    return re.sub(r"[^a-z0-9]+", " ", name.lower()).strip()


def slug(name):
    return re.sub(r"[^a-z0-9]+", "-", name.lower()).strip("-") or "recipe"


def book_tags(r):
    keys = [i.get("key") or "" for i in r["base"] + r["mixIns"]]
    name = r["name"].lower()
    hay = name + " " + " ".join(k.replace("_", " ") for k in keys)
    tags = ["high-protein", "copycat", "lite-ice-cream"]
    m = r.get("macros") or {}
    if (m.get("calories") or 9999) <= 400 and (m.get("protein") or 0) >= 25:
        tags.append("healthy")
    for tag, words in FLAVOR_RULES:
        if any(w in hay for w in words):
            tags.append(tag)
    if "vanilla" in name:
        tags.append("vanilla")
    if any(any(f in k for f in FRUIT_KEYS) for k in keys):
        tags.append("fruit")
    if not any(NUT_RE.search(k) for k in keys):
        tags.append("nut-free")
    return tags


def main():
    book = load(os.path.join(DATA, "book_recipes.json"), [])
    qr = load(os.path.join(DATA, "qr_links.json"), {})
    out, seen = [], set()
    dropped_books = []
    for r in book:
        page = r.get("page")
        rec = {k: v for k, v in r.items() if k not in ("page", "photoPage")}
        rec["source"] = {"kind": "book", "title": "Creami Cravings", "page": page, "site": None, "url": None}
        rec["photo"] = "p%d.jpg" % (page + 1) if page is not None else None
        rec["videoURL"] = qr.get(str(page))
        rec["pintSize"] = "standard"
        rec["tags"] = book_tags(r)
        out.append(rec)
        seen.add(norm(r["name"]))
    nbook = len(out)

    # Books 2 and 3 (data/books/*.json): macros = macrosPerServing x servings; vegAdaptation stays per serving.
    nmeal = 0
    ids_seen = {r.get("id") for r in out}
    for fp in sorted(glob.glob(os.path.join(DATA, "books", "*.json"))):
        items = load(fp, [])
        if isinstance(items, dict):
            items = items.get("recipes", [])
        for r in items if isinstance(items, list) else []:
            if not isinstance(r, dict) or not r.get("name") or not r.get("base") or not r.get("instructions"):
                dropped_books.append(os.path.basename(fp))
                continue
            if r.get("id") in ids_seen:
                continue
            ids_seen.add(r.get("id"))
            r = dict(r)
            normalize_meal(r)
            r.setdefault("mixIns", [])
            r["mixIns"] = r.get("mixIns") or []
            r["tags"] = r.get("tags") or []
            r["pintSize"] = r.get("pintSize") or "standard"
            r.setdefault("photo", None)
            r.setdefault("videoURL", None)
            r.setdefault("section", "meal")
            src = dict(r.get("source") or {})
            src["kind"] = "book"
            r["source"] = src
            out.append(r)
            nmeal += 1

    nweb = dropped = dupes = 0
    files = sorted(glob.glob(os.path.join(DATA, "web", "*.json")))
    for fp in files:
        items = load(fp, [])
        if isinstance(items, dict):
            items = items.get("recipes", [])
        for r in items if isinstance(items, list) else []:
            if not isinstance(r, dict) or not r.get("name") or not r.get("base") or not r.get("instructions"):
                dropped += 1
                continue
            n = norm(r["name"])
            if n in seen:
                dupes += 1
                continue
            seen.add(n)
            r = dict(r)
            if "macrosPerServing" in r:          # web meals use the books/meals schema
                normalize_meal(r)
                r.setdefault("section", "meal")
            src = dict(r.get("source") or {})
            src["kind"] = "web"
            r["source"] = src
            r.setdefault("mixIns", [])
            r["mixIns"] = r.get("mixIns") or []
            r["tags"] = r.get("tags") or []
            r["pintSize"] = r.get("pintSize") or "standard"
            r.setdefault("photo", None)
            r.setdefault("videoURL", None)
            r.setdefault("macros", None)
            out.append(r)
            nweb += 1

    ids = set()
    for r in out:
        base = r.get("id") or slug(r["name"])
        rid, n = base, 2
        while rid in ids:
            rid = "%s-%d" % (base, n)
            n += 1
        ids.add(rid)
        r["id"] = rid

    parsed, empty = fill_amounts(out)

    aliases = load(os.path.join(DATA, "catalog", "key_aliases.json"), {})
    aliases = aliases if isinstance(aliases, dict) else {}
    aliased = 0
    for r in out:
        for ing in all_ings(r):
            k = ing.get("key")
            seen_k = set()
            while k in aliases and k not in seen_k:   # follow chains, guard loops
                seen_k.add(k)
                k = aliases[k]
            if k != ing.get("key"):
                ing["key"] = k
                aliased += 1

    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    import data_fixes
    out, fix_report = data_fixes.apply(out)

    # Photos: bundled Resources/Photos/<id>.jpg first (books), else a remote photoURL for web recipes (data/web_images.json).
    web_images = load(os.path.join(DATA, "web_images.json"), {})
    web_images = web_images if isinstance(web_images, dict) else {}
    photo_cov = {}
    for r in out:
        if os.path.exists(os.path.join(RES, "Photos", r["id"] + ".jpg")):
            r["photo"] = r["id"] + ".jpg"
        if not r.get("photo") and web_images.get(r["id"]):
            r["photoURL"] = web_images[r["id"]]
        sec = r.get("section") or "creami"
        c = photo_cov.setdefault(sec, [0, 0, 0])
        c[0] += 1
        c[1] += 1 if r.get("photo") else 0
        c[2] += 1 if r.get("photoURL") else 0

    os.makedirs(RES, exist_ok=True)
    with open(os.path.join(RES, "recipes.json"), "w", encoding="utf-8") as f:
        json.dump(out, f, ensure_ascii=False, indent=1)

    copied = []
    for fn in ("ingredients.json", "base_liquids.json", "protein_powders.json", "source_powder_brands.json", "guides.json", "paneer_model.json", "veg_alternatives.json"):
        src = os.path.join(DATA, "catalog", fn)
        if os.path.exists(src):
            shutil.copyfile(src, os.path.join(RES, fn))
            copied.append(fn)

    print("book recipes: %d" % nbook)
    print("books 2/3 recipes: %d (dropped %d invalid)" % (nmeal, len(dropped_books)))
    print("web recipes: %d (from %d files; dropped %d invalid, %d duplicates)" % (nweb, len(files), dropped, dupes))
    secs = {}
    for r in out:
        secs[r.get("section") or "creami"] = secs.get(r.get("section") or "creami", 0) + 1
    print("total recipes: %d  by section: %s" % (len(out), ", ".join("%s %d" % kv for kv in sorted(secs.items()))))
    print("amounts parsed: %d of %d empty lines" % (parsed, empty))
    print("data fixes (docs/DATA_FIXES_SPEC.md):")
    for k, v in sorted(fix_report.items()):
        print("  %s: %s" % (k, v))
    print("photo coverage (bundled / remote URL / total): " + ", ".join(
        "%s %d/%d/%d" % (k, v[1], v[2], v[0]) for k, v in sorted(photo_cov.items())))
    print("key aliases: %d loaded, %d ingredient keys rewritten" % (len(aliases), aliased))
    print("catalog files copied: %s" % (", ".join(copied) or "none"))
    cat = load(os.path.join(RES, "ingredients.json"))
    if isinstance(cat, dict):
        missing = sorted({i.get("key") for r in out for i in all_ings(r) if i.get("key") and i["key"] not in cat})
        print("keys missing from catalog (%d): %s" % (len(missing), ", ".join(missing[:40]) + (" ..." if len(missing) > 40 else "")))
        print("keys introduced by data fixes and missing from the catalog: %s" % (", ".join(k for k in data_fixes.FIX_KEYS if k not in cat) or "none"))
    else:
        print("no ingredient catalog yet; skipping missing-key report")


if __name__ == "__main__":
    main()
