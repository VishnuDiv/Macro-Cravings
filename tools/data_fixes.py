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
            if "collagen" in (line.get("text") or "").lower():
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


# ---------------------------------------------------------------- entry point

def apply(recipes):
    """Runs every fix. Returns (recipes, report) where report maps a fix label to its count."""
    rep = {}
    rep["10 re-keyed lines"] = fix10_rekey(recipes)
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
    c5 = fix5_fat(recipes)
    rep["5 veg macros adjusted (fat/kcal)"] = len(c5)
    rep["5 detail"] = ", ".join("%s %s->%s" % c for c in c5[:12])
    n6 = fix6_web_macros(recipes)
    rep["6 web macros nulled"] = len(n6)
    rep["7 per-piece servings"] = fix7_pieces(recipes)
    return recipes, rep


# Keys the fixes introduce; build_data reports the ones the catalog does not have yet.
FIX_KEYS = sorted({"caesar_dressing_vegetarian", "vegetarian_worcestershire", "soy_sauce_miso", "vegetarian_oyster_sauce", "vegetarian_parmesan",
                   "vegetarian_pesto", "vegetable_stock", "agar_powder", "vegan_marshmallows", "collagen_powder", "protein_powder_unflavored",
                   "tortilla_wrap", "instant_ramen", "rice_vinegar", "sesame_oil", "rice_noodles", "tamarind_paste", "paneer_low_fat", "olive_oil",
                   "salt", "black_pepper", "flour", "eggs", "cabbage", "pickles", "mix_in_choice", "tofu_super_firm", "veggie_sausage",
                   "soy_chunks", "plant_based_mince", "veggie_bacon", "veggie_pepperoni"})
