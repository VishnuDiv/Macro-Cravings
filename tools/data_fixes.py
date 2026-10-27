"""Build-time data fixes from the Opus review (docs/DATA_FIXES_SPEC.md).

apply(recipes) is called by build_data.py after key aliasing. Source files in data/books and data/web are never edited;
every fix runs again on each build. Each fix returns a count that build_data prints.
"""
import copy
import re

I = re.IGNORECASE
NOTE_BAD_MACROS = "Source nutrition looked wrong; showing calculated estimate."


# ---------------------------------------------------------------- helpers

def is_creami(r):
    return (r.get("section") or "creami") == "creami"


def per_serving(r):
    """Per-serving macros from the whole-recipe macros, or None."""
    m = r.get("macros")
    if not m:
        return None
    s = max(1, r.get("servings") or 1)
    return {k: (round(v / s, 1) if isinstance(v, (int, float)) else v) for k, v in m.items()}


def all_lines(r):
    return list(r.get("base") or []) + list(r.get("mixIns") or [])


def replace_in_text(text, old, new):
    """Case-insensitive substring replacement that does not stack on an existing 'vegetarian'/'vegan' prefix."""
    return re.sub(r"(?<!vegetarian )(?<!vegan )" + re.escape(old), new, text, flags=I)


def ensure_veg_swap(recipe, line, with_ing, note, steps_replace=None, summary=None):
    """Adds a vegetarian swap for `line` (creating the vegAdaptation when missing). Returns False when already swapped."""
    va = recipe.get("vegAdaptation")
    if not va:
        va = {"summary": "", "swaps": [], "steps": list(recipe.get("instructions") or []), "macrosPerServing": per_serving(recipe)}
        recipe["vegAdaptation"] = va
    if any(s.get("replaces") == line["text"] for s in va["swaps"]):
        return False
    va["swaps"].append({"replaces": line["text"], "with": with_ing, "note": note})
    for old, new in (steps_replace or {}).items():
        va["steps"] = [replace_in_text(s, old, new) for s in va["steps"]]
    recipe["vegetarian"] = False
    if summary and summary not in (va.get("summary") or ""):
        va["summary"] = "; ".join(x for x in [va.get("summary") or "", summary] if x)
    return True


def like_for_like(line, text, key):
    """A replacement Ing that keeps the original amounts."""
    return {"text": text, "key": key, "grams": line.get("grams"), "ml": line.get("ml"), "count": line.get("count"),
            "optional": bool(line.get("optional"))}


# ---------------------------------------------------------------- amount / key / servings sanity (negative-macro fixes)

_FR = "½⅓⅔¼¾⅛"
_NUM_RE = r"(?:\d+\s*&\s*[%s]|\d+\s+\d+/\d+|\d+\s*[%s]|\d+/\d+|\d*\.\d+|\d+|[%s])" % (_FR, _FR, _FR)
_SIZE_FIRST = re.compile(r"^\s*%s\s*[-–]?\s*(?:inch|inches|\"|”)" % _NUM_RE, re.I)
_COUNT_THEN_SIZE = re.compile(r"^\s*(\d+(?:\s*[-–]\s*\d+)?)\s*\(?~?\s*\d+\s*[-–]?\s*(?:inch|inches|\"|”)", re.I)
_WEIGHT_FIRST = re.compile(r"^\s*(%s)\s*(g|gm|gms|gram|grams|kg|ml|oz|ounce|ounces|lb|lbs|pound|pounds)\b" % _NUM_RE, re.I)
_WEIGHT_FACTOR = {"g": ("grams", 1), "gm": ("grams", 1), "gms": ("grams", 1), "gram": ("grams", 1), "grams": ("grams", 1), "kg": ("grams", 1000),
                  "ml": ("ml", 1), "oz": ("grams", 28.35), "ounce": ("grams", 28.35), "ounces": ("grams", 28.35),
                  "lb": ("grams", 453.6), "lbs": ("grams", 453.6), "pound": ("grams", 453.6), "pounds": ("grams", 453.6)}


def _to_float(tok):
    t = tok.strip()
    uni = {"½": .5, "⅓": 1 / 3, "⅔": 2 / 3, "¼": .25, "¾": .75, "⅛": .125}
    m = re.fullmatch(r"(\d+)\s*&?\s*([%s])" % _FR, t)
    if m:
        return int(m.group(1)) + uni[m.group(2)]
    if t in uni:
        return uni[t]
    m = re.fullmatch(r"(\d+)\s+(\d+)/(\d+)", t)
    if m:
        return int(m.group(1)) + int(m.group(2)) / int(m.group(3))
    m = re.fullmatch(r"(\d+)/(\d+)", t)
    if m:
        return int(m.group(1)) / int(m.group(2))
    try:
        return float(t)
    except ValueError:
        return None


def fix_size_not_count(recipes):
    """"10 inch tortilla", "8-inch", 6\" are sizes, not counts: the count is the number BEFORE the size, else 1."""
    log = []
    for r in recipes:
        for ing in all_lines(r):
            t = ing.get("text") or ""
            if ing.get("grams") is not None or ing.get("ml") is not None:
                continue
            new = None
            if _SIZE_FIRST.match(t):
                new = 1
            else:
                m = _COUNT_THEN_SIZE.match(t)
                if m:
                    parts = [float(x) for x in re.split(r"\s*[-–]\s*", m.group(1).strip())]
                    new = sum(parts) / len(parts)
            if new is not None and ing.get("count") != new:
                log.append("%s: %r count %s -> %s" % (r.get("id"), t[:50], ing.get("count"), new))
                ing["count"] = new
    return log


def fix_count_is_weight(recipes):
    """A line like "325 g/ 11 oz aubergine" or "15.5 ounce can chickpeas" whose count repeats the weight number (so 325 aubergines)
    gets the amount as grams / ml instead."""
    log = []
    for r in recipes:
        for ing in all_lines(r):
            if ing.get("count") is None or ing.get("grams") is not None or ing.get("ml") is not None:
                continue
            m = _WEIGHT_FIRST.match(ing.get("text") or "")
            if not m:
                continue
            qty = _to_float(m.group(1))
            if qty is None or abs(ing["count"] - qty) >= 1:
                continue
            field, factor = _WEIGHT_FACTOR[m.group(2).lower()]
            ing[field] = round(qty * factor, 2)
            log.append("%s: %r count %s -> %s %s" % (r.get("id"), (ing.get("text") or "")[:40], ing["count"], field, ing[field]))
            ing["count"] = None
    return log


_OIL_WORDS = re.compile(r"\boil+s?\b|spray|ghee|butter|\bfat\b|lard|shortening|margarine", re.I)       # not "boil"
_SWEET_WORDS = re.compile(r"sugar|sweeten|stevia|monk|erythritol|allulose|honey|syrup|swerve|splenda|jaggery|maple|agave|molasses|xylitol|truvia|lakanto|nectar|treacle", re.I)
_SUGAR_KEYS = {"sugar", "brown_sugar", "powdered_sugar", "coconut_sugar", "white_sugar", "caster_sugar", "granulated_sugar", "icing_sugar"}
_STOP = set("a an and or of the with for to in on fresh dried chopped diced sliced minced finely roughly cup cups tbsp tsp tablespoon tablespoons teaspoon teaspoons large small medium g ml oz".split())


def _tokens(text):
    return [re.sub(r"s$", "", w) for w in re.findall(r"[a-z]{3,}", (text or "").lower()) if w not in _STOP]


# phrase -> catalog key, tried before the generic token match
_KEY_HINTS = [(r"pasta|penne|spaghetti|macaroni|rigatoni|fusilli|linguine|fettuccine|orzo", "pasta_dry"),
              (r"sweet ?corn", "sweetcorn"), (r"boiling water|hot water|cold water|ice water|\bwater\b", "water")]


def _best_catalog_key(text, catalog):
    """Catalog key for what the line names: a hint phrase, else the key whose name tokens all appear in the line (most tokens first)."""
    head = re.sub(r"\([^)]*\)", " ", text)                      # ignore parentheticals ("(boiling water ...)")
    for pat, key in _KEY_HINTS:
        if re.search(pat, head, re.I) and (catalog is None or key in catalog):
            return key
    toks = set(_tokens(head))
    best, best_n = None, 0
    for k in catalog or {}:
        kt = [re.sub(r"s$", "", w) for w in k.split("_") if len(w) >= 3]
        if kt and all(w in toks for w in kt) and len(kt) > best_n:
            best, best_n = k, len(kt)
    return best


def fix_wrong_keys(recipes, catalog=None):
    """Lines whose text names a different food than their key: an oil key on a line with no oil word (noodles keyed vegetable_oil),
    a sugar key on a line with no sweetener word. Re-keys by text; every change is logged."""
    log = []
    for r in recipes:
        for ing in all_lines(r):
            k, t = ing.get("key") or "", ing.get("text") or ""
            is_oil_key = k.endswith("_oil") or k == "oil"
            if not (is_oil_key and not _OIL_WORDS.search(t)) and not (k in _SUGAR_KEYS and not _SWEET_WORDS.search(t)):
                continue
            new = None
            if re.search(r"noodle|vermicelli|pad thai", t, re.I):
                new = "rice_noodles" if re.search(r"rice|pad thai|vermicelli", t, re.I) else "noodles"
            if new is None:
                new = _best_catalog_key(t, catalog)
            if new and new != k and (catalog is None or new in catalog):
                log.append("%s: %r key %s -> %s" % (r.get("id"), t[:50], k, new))
                ing["key"] = new
            else:
                log.append("%s: %r key %s looks wrong, no replacement found" % (r.get("id"), t[:50], k))
    return log


NOTE_SCALED = "Source nutrition was per serving; scaled to the whole recipe (x%d) to match the ingredient amounts."
NOTE_MISMATCH = "Source nutrition did not match the ingredient amounts; showing calculated estimate."


def _catalog_kcal(r, catalog):
    tot = 0.0
    for i in all_lines(r):
        if i.get("optional"):
            continue
        info = (catalog or {}).get(i.get("key") or "")
        if info:
            tot += (info.get("per100g") or {}).get("calories", 0) * line_grams(i, info) / 100
    return tot


def _evidence_note(r, note):
    ev = r.get("evidence")
    if isinstance(ev, dict):
        if note not in (ev.get("summary") or ""):
            ev["summary"] = " ".join(x for x in [ev.get("summary") or "", note] if x)
    else:
        r["evidence"] = {"verdict": "unverified", "rating": None, "ratingCount": None, "summary": note, "commonFixes": []}


def fix_servings_sanity(recipes, catalog):
    """Printed macros that cannot belong to the ingredient list: a meal above 2500 kcal per serving, or a catalog total per serving more
    than 4x the printed value while the printed value looks like one portion. Creami recipes whose printed values are per serving are
    scaled to the whole pint when the catalog / printed ratio is close to a whole number of servings; anything else is nulled with a note."""
    log = []
    for r in recipes:
        m = r.get("macros")
        if not m or not isinstance(m.get("calories"), (int, float)) or m["calories"] <= 0:
            continue
        s = max(1, r.get("servings") or 1)
        printed_ps = m["calories"] / s
        cat_ps = _catalog_kcal(r, catalog) / s
        if cat_ps <= 0:
            continue
        creami = is_creami(r)
        ratio = _catalog_kcal(r, catalog) / m["calories"]
        n = round(ratio)
        too_big = (not creami) and printed_ps > 2500
        mismatch = printed_ps <= 1200 and cat_ps > 4 * printed_ps
        # a Creami recipe whose catalog total is almost exactly 3-8 times the printed value: the printed numbers are per serving
        per_serving_pint = creami and (r.get("servings") or 1) == 1 and 3 <= n <= 8 and abs(ratio - n) / n < 0.08
        if not (too_big or mismatch or per_serving_pint):
            continue
        if creami and 2 <= n <= 8 and abs(ratio - n) / n < 0.2 and (r.get("servings") or 1) == 1:
            for k, v in list(m.items()):
                if isinstance(v, (int, float)):
                    m[k] = round(v * n, 1)
            _evidence_note(r, NOTE_SCALED % n)
            log.append("%s: scaled printed macros x%d (catalog %d kcal vs printed %d)" % (r.get("id"), n, round(_catalog_kcal(r, catalog)), round(printed_ps)))
        else:
            r["macros"] = None
            _evidence_note(r, NOTE_MISMATCH)
            log.append("%s: nulled printed macros (printed %d kcal/serving, catalog %d kcal/serving)" % (r.get("id"), round(printed_ps), round(cat_ps)))
    return log


# ---------------------------------------------------------------- clarity notes: line fixes (data/catalog/clarity_notes.json)

SUB_RECIPE_ONCE = [re.compile(r"^1 batch tofu scramble$", re.I), re.compile(r"^per taco: 1/4 kebab mix$", re.I)]


def fix_clarity_lines(recipes, notes, catalog=None, parse=None):
    """Applies the audit's lineFixes: match recipeId + exact lineText, then suggestedText and / or suggestedKey.
    Duplicate lines are only logged (they may be legitimate repeats in different sub-sections), except a sub-recipe that would be
    counted twice ("1 batch tofu scramble" repeated, "Per taco: 1/4 kebab mix"): those repeats become mix_in_choice (0 kcal) with
    "... (made above)". A line the audit calls parse junk (a heading) is removed. Unmatched fixes are logged and skipped.
    `parse(text)` (optional) re-reads the amount of a line whose text changed. Returns a dict of counts and log lines."""
    fixes = (notes or {}).get("lineFixes") or []
    by_id = {r.get("id"): r for r in recipes}
    out = {"applied": 0, "skipped": 0, "unmatched": [], "duplicates_logged": [], "removed": [], "changed_over_10pct": [], "once": []}
    before = {}
    for f in fixes:
        r = by_id.get(f.get("recipeId"))
        text = f.get("lineText")
        if not r:
            out["unmatched"].append("%s: recipe not found" % f.get("recipeId"))
            continue
        before.setdefault(r["id"], _catalog_kcal(r, catalog))
        pools = [r.get("base") or [], r.get("mixIns") or []]
        hit = None
        for pool in pools:
            for i, ing in enumerate(pool):
                if ing.get("text") == text:
                    hit = (pool, i)
                    break
            if hit:
                break
        swap_with = None
        if not hit:
            for sw in (r.get("vegAdaptation") or {}).get("swaps") or []:
                if (sw.get("with") or {}).get("text") == text:
                    swap_with = sw["with"]
                    break
        if not hit and not swap_with:
            out["unmatched"].append("%s: %r" % (r["id"], (text or "")[:50]))
            continue
        sug, key = f.get("suggestedText"), f.get("suggestedKey")
        reason = (f.get("reason") or "").lower()
        if sug == "":
            if "duplicate" in reason:
                same = [ing for pool in pools for ing in pool if ing.get("text") == text]
                if hit and any(p.match(text.strip()) for p in SUB_RECIPE_ONCE) and len(same) > 1:
                    for ing in same[1:]:                                   # count the sub-recipe once
                        ing["key"] = "mix_in_choice"
                        ing["text"] = text + " (made above)"
                        ing["grams"] = ing["ml"] = ing["count"] = None
                        out["once"].append("%s: %r" % (r["id"], text[:40]))
                    out["applied"] += 1
                else:
                    out["duplicates_logged"].append("%s: %r" % (r["id"], text[:50]))
                    out["skipped"] += 1
            elif hit:
                pool, i = hit
                pool.pop(i)
                out["removed"].append("%s: %r" % (r["id"], text[:50]))
                out["applied"] += 1
            else:
                out["skipped"] += 1
            continue
        ing = hit[0][hit[1]] if hit else swap_with
        if any(p.match(text.strip()) for p in SUB_RECIPE_ONCE):          # "Per taco: 1/4 kebab mix": the beef is already counted above
            key = "mix_in_choice"
            ing["grams"] = ing["ml"] = ing["count"] = None
        if sug:
            new = re.sub(r"\s*\($", "", sug.strip())                      # the audit sometimes leaves a dangling "("
            if new != ing.get("text"):
                ing["text"] = new
                if parse and key != "mix_in_choice":
                    a = parse(new)
                    if a and (a.get("grams") or a.get("ml")) and ing.get("grams") is None and ing.get("ml") is None:
                        ing.update({k: v for k, v in a.items() if k in ("grams", "ml")})
                        ing["count"] = None
        if key and key != ing.get("key"):
            ing["key"] = key
            if key == "mix_in_choice":
                ing["grams"] = ing["ml"] = ing["count"] = None
        out["applied"] += 1
    for rid, kb in before.items():
        ka = _catalog_kcal(by_id[rid], catalog)
        if kb > 0 and abs(ka - kb) / kb > 0.10:
            out["changed_over_10pct"].append("%s %d->%d" % (rid, round(kb), round(ka)))
    return out


# ---------------------------------------------------------------- veg macros from the catalog (when the source gave none)

_MACRO_KEYS = ("calories", "protein", "carbs", "fat", "sugar", "fiber")


def fix_veg_macros_from_catalog(recipes, catalog):
    """A vegAdaptation with macrosPerServing = null gets: printed per serving - replaced line(s) + substitute(s), both from the catalog at
    the same weights. Negative results are clamped at 0 and logged. Skips recipes with no printed macros."""
    log = []
    for r in recipes:
        va = r.get("vegAdaptation")
        m = r.get("macros")
        if not va or va.get("macrosPerServing") is not None or not m or not va.get("swaps"):
            continue
        s = max(1, r.get("servings") or 1)
        out = {k: (m.get(k) / s if isinstance(m.get(k), (int, float)) else None) for k in _MACRO_KEYS}
        lines = {l.get("text"): l for l in all_lines(r)}
        used = 0
        for sw in va["swaps"]:
            orig = lines.get(sw.get("replaces"))
            with_ing = sw.get("with") or {}
            oi, wi = (catalog or {}).get((orig or {}).get("key") or ""), (catalog or {}).get(with_ing.get("key") or "")
            if not orig or not oi or not wi:
                continue
            og, wg = line_grams(orig, oi), line_grams(with_ing, wi)
            used += 1
            for k in _MACRO_KEYS:
                if out[k] is None:
                    continue
                out[k] += ((wi.get("per100g") or {}).get(k, 0) * wg - (oi.get("per100g") or {}).get(k, 0) * og) / 100 / s
        if not used:
            continue
        clamped = [k for k, v in out.items() if v is not None and v < 0]
        va["macrosPerServing"] = {k: (None if v is None else round(max(0.0, v))) for k, v in out.items()}
        log.append("%s: %s%s" % (r.get("id"), va["macrosPerServing"], " (clamped: %s)" % ",".join(clamped) if clamped else ""))
    return log


# ---------------------------------------------------------------- Greek yogurt / skyr fat level (for the "My Greek yogurt" picker)

_NONFAT_TEXT = re.compile(r"\b0\s?%|non[- ]?fat|fat[- ]?free|zero fat", re.I)
_FULL_TEXT = re.compile(r"\b(?:4|5|10)\s?%|full[- ]?fat|whole[- ]?milk", re.I)
_TWO_TEXT = re.compile(r"\b(?:2|3)\s?%", re.I)


def fix_yogurt_fat_keys(recipes):
    """Greek yogurt and skyr lines that say how fat they are (2%, 5%, full-fat, whole milk) get a key that carries that fat level, so the
    app can show them as the user's chosen yogurt. Regular yogurt, curd, labneh and quark are never touched."""
    log = []
    for r in recipes:
        for ing in all_lines(r):
            k, t = ing.get("key") or "", ing.get("text") or ""
            if k not in ("greek_yogurt", "skyr") or _NONFAT_TEXT.search(t):
                continue
            new = None
            if _FULL_TEXT.search(t):
                new = "greek_yogurt_full" if k == "greek_yogurt" else "skyr_full"
            elif _TWO_TEXT.search(t) and k == "greek_yogurt":
                new = "greek_yogurt_2pct"
            if new:
                ing["key"] = new
                log.append("%s: %r %s -> %s" % (r.get("id"), t[:40], k, new))
    return log


# ---------------------------------------------------------------- D. keys (10, 11)

def fix10_rekey(recipes):
    n = 0
    for r in recipes:
        for ing in all_lines(r):
            t = (ing.get("text") or "").lower()
            key = ing.get("key")
            new = None
            if key == "bell_pepper" and re.search(r"salt (and|&) pepper", t):
                new = "salt"
            elif key == "bell_pepper" and re.search(r"black pepper|pepper to taste", t):
                new = "black_pepper"
            elif "rice vinegar" in t:
                new = "rice_vinegar"
            elif "sesame oil" in t:
                new = "sesame_oil"
            elif key == "soy_sauce" and re.search(r"\boil\b", t):
                new = "olive_oil"
            elif "rice noodles" in t:
                new = "rice_noodles"
            elif "tamarind" in t:
                new = "tamarind_paste"
            elif key == "paneer" and re.search(r"low[- ]fat paneer", t):
                new = "paneer_low_fat"
            if new and new != key:
                ing["key"] = new
                n += 1
    return n


SWAP_KEY_MAP = {
    "veg_sausage": "veggie_sausage", "soy_chunks_dry": "soy_chunks", "soy_mince_dry": "soy_chunks",
    "plant_mince": "plant_based_mince", "beyond_mince": "plant_based_mince", "supertofu": "tofu_super_firm",
    "tofu_high_protein": "tofu_super_firm", "smoky_veg_rashers": "veggie_bacon", "vegetarian_pepperoni": "veggie_pepperoni",
    "veggie_pepperoni_slices": "veggie_pepperoni", "veg_hard_cheese": "vegetarian_parmesan", "vegetarian_hard_cheese": "vegetarian_parmesan",
    "veg_parmesan": "vegetarian_parmesan", "vegetable_broth": "vegetable_stock", "vegetable_bouillon": "vegetable_stock",
    "vegetable_stock_cube": "vegetable_stock", "veg_worcestershire": "vegetarian_worcestershire",
    "vegan_worcestershire": "vegetarian_worcestershire", "worcestershire_vegetarian": "vegetarian_worcestershire",
}


def fix11_swap_keys(recipes):
    n = 0
    for r in recipes:
        for sw in (r.get("vegAdaptation") or {}).get("swaps") or []:
            w = sw.get("with") or {}
            if w.get("key") in SWAP_KEY_MAP:
                w["key"] = SWAP_KEY_MAP[w["key"]]
                n += 1
    return n


# ---------------------------------------------------------------- E. duplicates (12, 13)

def norm_url(u):
    u = (u or "").strip().lower()
    u = re.sub(r"^https?://", "", u)
    u = re.sub(r"^www\.", "", u)
    u = re.split(r"[?#]", u)[0]
    return u.rstrip("/")


def _key_set(r):
    return {g.get("key") for s in ("base", "mixIns") for g in (r.get(s) or []) if g.get("key")}


def fix12_dedupe_urls(recipes):
    # Same URL is a duplicate only if the ingredients mostly match too: one page can
    # legitimately source several variants (e.g. copycat / lighter / high-protein).
    seen, out, dropped = {}, [], []
    for r in recipes:
        u = norm_url((r.get("source") or {}).get("url")) if (r.get("source") or {}).get("kind") == "web" else ""
        keys = _key_set(r)
        if u and any(len(keys & k) >= 0.8 * max(1, len(keys | k)) for k in seen.get(u, [])):
            dropped.append(r.get("id"))
            continue
        if u:
            seen.setdefault(u, []).append(keys)
        out.append(r)
    return out, dropped


def _core_name(name):
    words = [w for w in re.sub(r"[^a-z0-9]+", " ", (name or "").lower()).split() if w not in ("high", "protein", "anabolic")]
    return " ".join(words)


def fix13_book_dupes(recipes):
    """A Lean Bulking recipe whose normalized name (without high/protein/anabolic) equals a chef recipe is a duplicate,
    whatever its calories (they may be per piece vs per serving). The chef version stays and gets source.alsoIn."""
    chef = {}
    for r in recipes:
        if "chef" in ((r.get("source") or {}).get("title") or "").lower():
            chef.setdefault(_core_name(r["name"]), r)
    out, dropped = [], []
    for r in recipes:
        if "lean bulking" in ((r.get("source") or {}).get("title") or "").lower():
            c = chef.get(_core_name(r["name"]))
            if c:
                if not c["source"].get("alsoIn"):
                    c["source"]["alsoIn"] = "The Ultimate Guide to Lean Bulking p.%s" % (r["source"].get("page"))
                dropped.append("%s (%s)" % (r.get("id"), r.get("name")))
                continue
        out.append(r)
    return out, dropped


# ---------------------------------------------------------------- C. cooking (8, 9)

def fix9_missing_lines(recipes):
    n = 0
    adds = {
        "chef-cheesy-chicken-bites": ("base", [
            {"text": "30 g plain flour (for coating)", "key": "flour", "grams": 30, "ml": None, "count": None, "optional": False},
            {"text": "1 egg, beaten", "key": "eggs", "grams": None, "ml": None, "count": 1, "optional": False}]),
        "chef-nashville-hot-chicken-sandwich": ("mixIns", [
            {"text": "Shredded cabbage (to serve)", "key": "cabbage", "grams": None, "ml": None, "count": None, "optional": False},
            {"text": "Pickle slices (to serve)", "key": "pickles", "grams": None, "ml": None, "count": None, "optional": False}]),
    }
    for r in recipes:
        if r.get("id") in adds:
            field, lines = adds[r["id"]]
            have = {l["text"] for l in all_lines(r)}
            for l in lines:
                if l["text"] not in have:
                    r.setdefault(field, []).append(dict(l))
                    n += 1
    return n


def _drop_sentences(step, pattern):
    parts = re.split(r"(?<=[.!?])\s+", step)
    kept = [p for p in parts if not re.search(pattern, p, I)]
    return " ".join(kept)


def fix8_seitan_baking_soda(recipes):
    n = 0
    for r in recipes:
        va = r.get("vegAdaptation")
        if not va or not any((s.get("with") or {}).get("key") == "seitan" for s in va.get("swaps") or []):
            continue
        for line in all_lines(r):
            if re.search(r"baking soda|bicarbonate", line.get("text") or "", I):
                w = {"text": "(Omit the baking soda — not needed for seitan)", "key": "mix_in_choice", "grams": 0, "ml": None, "count": None, "optional": False}
                if ensure_veg_swap(r, line, w, "Seitan does not need baking soda.", summary="Omit baking soda"):
                    n += 1
        steps = [_drop_sentences(s, r"baking soda|bicarbonate") for s in va["steps"]]
        va["steps"] = [s for s in steps if s.strip()]
    return n


# ---------------------------------------------------------------- A. vegetarian safety (1-4)

RAMEN_TERMS = r"instant ramen|ramen noodles|noodle pack|packet|seasoning packet|flavor packet|flavour packet|nissin|top ramen|maruchan|cup noodle"
RAMEN_WITH = "Instant ramen noodles (discard the flavor packet unless labelled vegan) + 1 tsp white miso + 1 tsp vegetable bouillon"
RAMEN_NOTE = ("Most ramen flavor packets contain chicken or beef extract. Maruchan and Nissin vegan or 'Oriental' packets vary, "
              "so check the label, or use the miso + bouillon base.")


def fix1_ramen(recipes):
    n = 0
    for r in recipes:
        if is_creami(r):
            continue
        name = (r.get("name") or "").lower()
        if not (("ramen" in (r.get("tags") or [])) or ("pantry" in (r.get("tags") or [])) or "ramen" in name):
            continue
        for line in all_lines(r):
            t = (line.get("text") or "").lower()
            if not re.search(RAMEN_TERMS, t):
                continue
            if "buldak" in t or ("buldak" in name and r.get("vegetarian") is False):
                continue
            if ensure_veg_swap(r, line, like_for_like(line, RAMEN_WITH, "instant_ramen"), RAMEN_NOTE,
                               summary="Ramen flavor packet → miso + vegetable bouillon"):
                n += 1
    return n


VEG_WORDS = re.compile(r"vegan|vegetarian|\bveg\b|veggie|meat-free|plant", I)
STOCK_RE = r"\b(chicken|beef)\s+(bone\s+)?(stock|broth|bouillon|boullion)\b"
STOCK_STEPS = {k: "vegetable stock" for k in ("chicken bone broth", "beef bone broth", "chicken stock", "beef stock", "chicken broth",
                                              "beef broth", "chicken bouillon", "beef bouillon")}

# (name, line regex, extra predicate, with text, with key, steps_replace, summary)
HIDDEN = [
    ("caesar", r"caesar dressing", None,
     "Vegetarian Caesar dressing (e.g. Primal Kitchen Vegan Caesar, or Greek yogurt + lemon + capers + rennet-free Parmesan)",
     "caesar_dressing_vegetarian", {"caesar dressing": "vegetarian Caesar dressing"}, "Caesar dressing → vegetarian Caesar"),
    ("worcestershire", r"worcestershire", None, "Vegetarian Worcestershire sauce (e.g. Annie's, Henderson's Relish)",
     "vegetarian_worcestershire", {"worcestershire": "vegetarian Worcestershire"}, "Worcestershire → vegetarian Worcestershire"),
    ("fish sauce", r"fish sauce", None, "Soy sauce + ½ tsp white miso (or vegan fish sauce)", "soy_sauce_miso",
     {"fish sauce": "soy sauce with a little miso"}, "Fish sauce → soy sauce + miso"),
    ("oyster sauce", r"oyster sauce", lambda t: "mushroom" not in t,
     "Vegetarian mushroom 'oyster' sauce (Lee Kum Kee Vegetarian Stir-Fry Sauce)", "vegetarian_oyster_sauce",
     {"oyster sauce": "vegetarian mushroom oyster sauce"}, "Oyster sauce → vegetarian mushroom sauce"),
    ("parmesan", r"parmesan|pecorino|grana padano", None,
     "Vegetarian hard cheese (rennet-free Parmesan-style, e.g. BelGioioso Vegetarian Parmesan, Trader Joe's)", "vegetarian_parmesan",
     {"parmesan": "vegetarian hard cheese", "pecorino": "vegetarian hard cheese", "grana padano": "vegetarian hard cheese"},
     "Parmesan → vegetarian hard cheese"),
    ("pesto", r"pesto", None,
     "Vegetarian pesto (rennet-free cheese; e.g. Trader Joe's Vegan Kale Cashew Basil Pesto, or homemade)", "vegetarian_pesto",
     {"pesto": "vegetarian pesto"}, "Pesto → vegetarian pesto"),
    ("meat stock", STOCK_RE, None, "Vegetable stock/broth (same amount)", "vegetable_stock", STOCK_STEPS, "Meat stock → vegetable stock"),
    ("gelatin (sweetened mix)", r"jell-?o|gelatin (dessert|mix)|jelly (crystals|mix)|gelatin packet",
     lambda t: not re.search(r"sugar[- ]free|unflavou?red|plain|sachet|pots", t),
     "Agar powder + sugar (replaces the sweetened gelatin mix: 1 tsp agar ≈ 1 tbsp gelatin, plus the sugar)", "agar_plus_sugar",
     {"gelatine": "agar powder", "gelatin": "agar powder"}, "Gelatin mix → agar + sugar"),
    ("gelatin", r"gelatin|gelatine", None, "Agar powder (1 tsp agar ≈ 1 tbsp gelatin)", "agar_powder",
     {"gelatine": "agar powder", "gelatin": "agar powder"}, "Gelatin → agar powder"),
    ("marshmallow", r"marshmallow", lambda t: "vegan" not in t, "Vegan marshmallows (Dandies)", "vegan_marshmallows",
     {"marshmallows": "vegan marshmallows", "marshmallow": "vegan marshmallow"}, "Marshmallows → vegan marshmallows"),
]


def fix2_hidden_meat(recipes):
    counts = {h[0]: 0 for h in HIDDEN}
    for r in recipes:
        if is_creami(r):
            continue
        for line in all_lines(r):
            t = (line.get("text") or "").lower()
            if VEG_WORDS.search(t):
                continue
            for name, pat, pred, wtext, wkey, steps, summ in HIDDEN:
                if re.search(pat, t) and (pred is None or pred(t)):
                    if ensure_veg_swap(r, line, like_for_like(line, wtext, wkey), "Same amount; check the label for animal ingredients.",
                                       steps_replace=steps, summary=summ):
                        counts[name] += 1
                    break
    return counts


def fix3_collagen(recipes):
    n = 0
    for r in recipes:
        for line in all_lines(r):
            t = (line.get("text") or "").lower()
            if "collagen" in t and re.search(r"broth|stock|bouillon", t):
                if (line.get("key") or "").startswith("collagen"):
                    line["key"] = "chicken_stock"               # bone broth, not a collagen supplement
                continue
            if "collagen" in t:
                line["key"] = "collagen_powder"
                n += 1
                if not is_creami(r):
                    ensure_veg_swap(r, line, like_for_like(line, "Unflavored whey or casein protein powder (same grams)", "protein_powder_unflavored"),
                                    "Collagen is animal-derived; whey or casein gives the same protein.",
                                    summary="Collagen → unflavored whey or casein")
    return n


def fix4_crunchwraps(recipes):
    n = 0
    for r in recipes:
        if r.get("id") == "chef-breakfast-crunchwraps":
            for line in all_lines(r):
                if "crispy beef tortilla" in (line.get("text") or "").lower():
                    w = like_for_like(line, "1 crispy tortilla filled with seasoned soy mince (from the soy-mince filling)", "tortilla_wrap")
                    if ensure_veg_swap(r, line, w, "Use the seasoned soy mince from the filling instead of beef.", summary="Crispy beef tortilla → soy-mince tortilla"):
                        n += 1
    return n


# ---------------------------------------------------------------- B. macros (5, 6, 7)

RUBRIC = [  # (regex on lowercased line text, rubric fat per 100 g)
    (r"chicken thigh|thighs", 6.0),
    (r"ground (chicken|turkey)|(chicken|turkey) mince|turkey", 8.0),
    (r"chicken", 2.6),
    (r"beef mince|ground beef|minced beef|\bmince\b", 5.0),
    (r"steak|sirloin|flank|rump", 7.0),
    (r"bacon", 4.0),
]
SUB_FAT = {"seitan": 2, "tofu_extra_firm": 8, "tofu_super_firm": 9, "paneer": 24, "paneer_low_fat": 10, "soy_chunks": 1, "tempeh": 11,
           "plant_based_mince": 14, "mycoprotein": 3, "quorn_pieces": 3, "veggie_sausage": 15, "veggie_bacon": 15, "veggie_pepperoni": 18,
           "vegan_chicken_pieces": 8, "vegan_chicken": 8}


def _rubric_fat(text):
    t = text.lower()
    for pat, fat in RUBRIC:
        if re.search(pat, t):
            return fat
    return None


def _derived_fat(text, rubric):
    t = text.lower()
    m = re.search(r"(\d+)\s*%", t)
    if m:
        n = float(m.group(1))
        return 100 - n if n > 30 else n          # "93% lean" means 7% fat
    if "lean" in t:
        return min(rubric, 4.0)
    return rubric


def fix5_fat(recipes):
    changed = []
    for r in recipes:
        va = r.get("vegAdaptation")
        if not va or (r.get("source") or {}).get("kind") != "book" or not (va.get("macrosPerServing") or None):
            continue
        servings = max(1, r.get("servings") or 1)
        m = va["macrosPerServing"]
        orig_fat = m.get("fat")
        if not isinstance(orig_fat, (int, float)):
            continue
        fat, kcal = float(orig_fat), float(m.get("calories") or 0)
        meat_swaps = 0
        for sw in va.get("swaps") or []:
            line = next((l for l in all_lines(r) if l.get("text") == sw.get("replaces")), None)
            if not line or line.get("grams") is None:
                continue
            rub = _rubric_fat(line["text"])
            if rub is None:
                continue
            meat_swaps += 1
            d = (rub - _derived_fat(line["text"], rub)) * line["grams"] / 100 / servings
            fat += d
            kcal += 9 * d
        if not meat_swaps:
            continue
        floor = 0.0
        for sw in va.get("swaps") or []:
            w = sw.get("with") or {}
            if w.get("key") in SUB_FAT and isinstance(w.get("grams"), (int, float)):
                floor += SUB_FAT[w["key"]] * w["grams"] / 100 / servings
        if fat < floor:
            kcal += 9 * (floor - fat)
            fat = floor
        if fat < 0:
            kcal -= 9 * fat
            fat = 0.0
        new_fat, new_kcal = int(round(fat)), int(round(kcal))
        if new_fat != orig_fat or new_kcal != m.get("calories"):
            m["fat"], m["calories"] = new_fat, new_kcal
            changed.append((r["id"], orig_fat, new_fat))
    return changed


ALWAYS_NULL = {"web-meal-loaded-vegetarian-nachos-high-protein-theherbeevore", "web-meal-vegan-japchae-okonomi-kitchen",
               "web-meal-quinoa-idli-ministryofcurry", "web-meal-instant-pot-refried-beans-skinnytaste"}


def fix6_web_macros(recipes):
    nulled = []
    for r in recipes:
        if (r.get("source") or {}).get("kind") != "web":
            continue
        m = r.get("macros")
        bad = r.get("id") in ALWAYS_NULL
        if m and not bad:
            s = max(1, r.get("servings") or 1)
            kcal = (m.get("calories") or 0) / s
            p, c, f = (m.get(k) for k in ("protein", "carbs", "fat"))
            if kcal and None not in (p, c, f) and abs(kcal - (4 * p + 4 * c + 9 * f) / s) / kcal > 0.35:
                bad = True
            if (m.get("fiber") or 0) / s > 40 or kcal > 2500:
                bad = True
        if bad and (m or r.get("id") in ALWAYS_NULL):
            r["macros"] = None
            ev = r.get("evidence")
            if isinstance(ev, dict):
                if NOTE_BAD_MACROS not in (ev.get("summary") or ""):
                    ev["summary"] = " ".join(x for x in [ev.get("summary") or "", NOTE_BAD_MACROS] if x)
            else:
                r["evidence"] = {"verdict": "unverified", "rating": None, "ratingCount": None, "summary": NOTE_BAD_MACROS, "commonFixes": []}
            nulled.append(r["id"])
    return nulled


def fix7_pieces(recipes):
    n = 0
    for r in recipes:
        s = r.get("servings") or 0
        if is_creami(r) or not s:
            continue
        m = r.get("macros")
        kcal = (m.get("calories") / s) if m and isinstance(m.get("calories"), (int, float)) else None
        name = (r.get("name") or "").lower()
        if (s >= 10 and kcal is not None and kcal < 150) or (s >= 6 and re.search(r"nugget|falafel|bite|ball|idli|cookie|muffin|wing", name)):
            r["servingLabel"] = "piece"
            n += 1
            if "falafel" in name and r.get("course") == "dinner":
                r["course"] = "snack"
    return n


# ---------------------------------------------------------------- protein upgrade (wings / crispy bites)

LEGUME_WORDS = ("chickpea", "lentil", "bean", "pea")


def _keyword_hit(text, keywords):
    """Whole-word / phrase match of any keyword in text (case-insensitive)."""
    t = " " + re.sub(r"[^a-z0-9]+", " ", text.lower()).strip() + " "
    return any((" %s " % re.sub(r"[^a-z0-9]+", " ", k.lower()).strip()) in t for k in keywords)


def line_grams(ing, info):
    """Grams of a line the way the app computes them: grams, else ml x gramsPerMl, else count x gramsPerCount, else defaultGrams."""
    info = info or {}
    if isinstance(ing.get("grams"), (int, float)):
        return ing["grams"]
    if isinstance(ing.get("ml"), (int, float)):
        return ing["ml"] * (info.get("gramsPerMl") or 1.0)
    if isinstance(ing.get("count"), (int, float)) and info.get("gramsPerCount"):
        return ing["count"] * info["gramsPerCount"]
    return info.get("defaultGrams") or 0.0


MIN_BASE_GRAMS = 150      # a real "main" ingredient: a garnish of mushrooms in a pasta dish is not a wing base


def mark_protein_upgrades(recipes, catalog, valts):
    """Marks wing / crispy-bite recipes whose main produce or legume line (by weight) is a wing base such as cauliflower.

    Sets recipe["proteinUpgrade"] = {"role": "wing_base", "lineIndex": i} (i = index in `base`). Meals only (courses meal / snack / side),
    never Creami or dessert. Returns the list of marked recipes."""
    role = ((valts or {}).get("upgrades") or {}).get("wing_base")
    if not role:
        return []
    base_keys = set(role.get("baseKeys") or [])
    keywords = role.get("keywords") or []
    marked = []
    for r in recipes:
        r.pop("proteinUpgrade", None)
        if (r.get("section") or "creami") != "meal":
            continue
        # produce / legume lines by grams; the wing base has to be the largest of them
        best, best_g = None, 0.0
        for i, ing in enumerate(r.get("base") or []):
            k = ing.get("key") or ""
            info = (catalog or {}).get(k) or {}
            g = line_grams(ing, info)
            if g <= 0:
                continue
            cat = info.get("category")
            if cat == "produce" or any(w in k for w in LEGUME_WORDS):
                if g > best_g:
                    best, best_g = i, g
        if best is None or best_g < MIN_BASE_GRAMS or (r["base"][best].get("key") or "") not in base_keys:
            continue
        name_tags = " ".join([r.get("name") or ""] + list(r.get("tags") or []))
        # already built on a protein, or the vegetable is a rice substitute: nothing to upgrade
        if re.search(r"\b(tofu|paneer|seitan|tempeh)\b|cauliflower rice|riced", (r.get("name") or "").lower()):
            continue
        if any(re.search(r"tofu|paneer|seitan|tempeh|soy_chunks", (i.get("key") or "")) and line_grams(i, (catalog or {}).get(i.get("key") or "")) >= 100
               for i in r.get("base") or []):
            continue
        if (r.get("cuisine") or "").lower() == "wings" or _keyword_hit(name_tags, keywords):
            r["proteinUpgrade"] = {"role": "wing_base", "lineIndex": best}
            marked.append(r)
    return marked


# ---------------------------------------------------------------- "Add protein" boost (low-protein overnight oats only)

OVERNIGHT_NAME = re.compile(r"overnight oat|overnight oats|overnight protein oats", re.I)
OAT_KEYS = ("rolled_oats", "oats", "steel_cut_oats")
# ingredients that already make an oats recipe a protein recipe (no boost offered)
PROTEIN_KEY_RE = re.compile(r"protein_powder|casein|whey|pea_protein|greek_yogurt|skyr|quark|cottage_cheese|egg_white|tofu|peanut_butter_powder|pb2|collagen")


def mark_protein_boost(recipes):
    """Marks overnight oats that are NOT already protein recipes with proteinBoost = True: no "protein" in the name, no protein-boosting
    ingredient (powder, Greek yogurt, skyr, quark, cottage cheese, egg whites, tofu, PB2, collagen), printed protein under 20 g per
    serving. Never baked or savory oats.

    A recipe with no printed macros is marked too; the app checks the displayed (calculated) protein at runtime."""
    marked = []
    for r in recipes:
        r.pop("proteinBoost", None)
        if (r.get("section") or "creami") != "meal":
            continue
        name = r.get("name") or ""
        if re.search(r"baked", name, re.I) or re.search(r"protein", name, re.I):       # already a protein recipe by name
            continue
        if any(PROTEIN_KEY_RE.search(i.get("key") or "") for i in (r.get("base") or []) + (r.get("mixIns") or [])):
            continue
        by_name = bool(OVERNIGHT_NAME.search(name))
        has_oats = any((i.get("key") or "") in OAT_KEYS for i in r.get("base") or [])
        overnight_tag = "overnight" in (name + " " + " ".join(r.get("tags") or [])).lower()
        if not (by_name or (r.get("course") == "breakfast" and overnight_tag and has_oats)):
            continue
        m = r.get("macros")
        if m and isinstance(m.get("protein"), (int, float)) and m["protein"] / max(1, r.get("servings") or 1) >= 20:
            continue
        r["proteinBoost"] = True
        marked.append(r)
    return marked


# ---------------------------------------------------------------- entry point

def apply(recipes, catalog=None, clarity=None, parse=None):
    """Runs every fix. Returns (recipes, report) where report maps a fix label to its count. `catalog` (key -> entry) enables the
    catalog-aware fixes (wrong keys, servings sanity)."""
    rep = {}
    l_size = fix_size_not_count(recipes)
    rep["a size-not-count lines"] = len(l_size)
    rep["a detail"] = "; ".join(l_size[:6])
    l_w = fix_count_is_weight(recipes)
    rep["a2 count-was-a-weight lines"] = len(l_w)
    rep["a2 detail"] = "; ".join(l_w[:6])
    rep["10 re-keyed lines"] = fix10_rekey(recipes)
    l_y = fix_yogurt_fat_keys(recipes)
    rep["yogurt fat-level keys"] = len(l_y)
    rep["yogurt detail"] = "; ".join(l_y[:5])
    l_k = fix_wrong_keys(recipes, catalog)
    rep["b wrong-key lines"] = len(l_k)
    rep["b detail"] = "; ".join(l_k)
    if clarity:
        c = fix_clarity_lines(recipes, clarity, catalog, parse)
        rep["clarity lineFixes applied"] = c["applied"]
        rep["clarity lineFixes skipped (duplicates logged)"] = c["skipped"]
        rep["clarity unmatched"] = len(c["unmatched"])
        rep["clarity unmatched detail"] = "; ".join(c["unmatched"][:8])
        rep["clarity sub-recipes counted once"] = len(c["once"])
        rep["clarity lines removed"] = len(c["removed"])
        rep["clarity recipes whose calculated kcal moved > 10%"] = len(c["changed_over_10pct"])
        rep["clarity > 10% detail"] = "; ".join(c["changed_over_10pct"][:10])
    rep["11 canonical swap keys"] = fix11_swap_keys(recipes)
    recipes, d12 = fix12_dedupe_urls(recipes)
    rep["12 duplicate source URLs dropped"] = len(d12)
    recipes, d13 = fix13_book_dupes(recipes)
    rep["13 chef/bulk duplicates merged"] = len(d13)
    rep["13 detail"] = "; ".join(d13)
    rep["9 missing book lines added"] = fix9_missing_lines(recipes)
    rep["1 ramen packet swaps"] = fix1_ramen(recipes)
    hidden = fix2_hidden_meat(recipes)
    rep["2 hidden-meat sauce swaps"] = sum(hidden.values())
    rep["2 detail"] = ", ".join("%s %d" % kv for kv in hidden.items() if kv[1])
    rep["3 collagen lines"] = fix3_collagen(recipes)
    rep["4 crunchwrap swaps"] = fix4_crunchwraps(recipes)
    rep["8 seitan baking-soda swaps"] = fix8_seitan_baking_soda(recipes)
    l_vm = fix_veg_macros_from_catalog(recipes, catalog)
    rep["veg macros computed from the catalog"] = len(l_vm)
    rep["veg macros detail"] = "; ".join(l_vm[:6])
    c5 = fix5_fat(recipes)
    rep["5 veg macros adjusted (fat/kcal)"] = len(c5)
    rep["5 detail"] = ", ".join("%s %s->%s" % c for c in c5[:12])
    n6 = fix6_web_macros(recipes)
    rep["6 web macros nulled"] = len(n6)
    rep["7 per-piece servings"] = fix7_pieces(recipes)
    l_s = fix_servings_sanity(recipes, catalog)
    rep["d servings sanity (scaled or nulled)"] = len(l_s)
    rep["d detail"] = "; ".join(l_s)
    return recipes, rep


# Keys the fixes introduce; build_data reports the ones the catalog does not have yet.
FIX_KEYS = sorted({"caesar_dressing_vegetarian", "vegetarian_worcestershire", "soy_sauce_miso", "vegetarian_oyster_sauce", "vegetarian_parmesan",
                   "vegetarian_pesto", "vegetable_stock", "agar_powder", "vegan_marshmallows", "collagen_powder", "protein_powder_unflavored",
                   "tortilla_wrap", "instant_ramen", "rice_vinegar", "sesame_oil", "rice_noodles", "tamarind_paste", "paneer_low_fat", "olive_oil",
                   "salt", "black_pepper", "flour", "eggs", "cabbage", "pickles", "mix_in_choice", "tofu_super_firm", "veggie_sausage",
                   "soy_chunks", "plant_based_mince", "veggie_bacon", "veggie_pepperoni", "agar_plus_sugar", "chicken_stock", "greek_yogurt_full", "greek_yogurt_2pct", "skyr_full"})
