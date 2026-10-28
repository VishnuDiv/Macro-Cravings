#!/usr/bin/env python3
"""Clarity audit: flag vague recipe steps against data/clarity/CLARITY_RUBRIC.md.

Reads the BUILT CreamiCravings/Resources/recipes.json (read-only), checks every step of `instructions` and
`vegAdaptation.steps` with regex heuristics, maps each recipe back to the SOURCE data file that holds it
(data/book_recipes.json, data/books/*.json, data/web/*.json), and writes:

  data/clarity/flagged.json   {recipeId: {file, field, stepIdx, reasons, section, name, steps:[...], also?}}
  data/clarity/batches.json   rewrite batches (~60 recipes) grouped by source file, meals first   (--batches)

Fried recipes: recipes whose data/airfry/classification.json class is deep_fry / shallow_fry have their frying
sentences skipped (the air-fryer conversion rewrites those). If that file does not exist yet, a provisional
regex (deep-fry / shallow-fry / hot-oil markers) is used and a warning is printed; re-run once it exists.

Usage:  python3 -I tools/clarity_audit.py [--batches] [--batch-size 60] [--show N]
Stdlib only.
"""
import argparse
import collections
import glob
import json
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BUILT = os.path.join(ROOT, "CreamiCravings", "Resources", "recipes.json")
DATA = os.path.join(ROOT, "data")
OUT = os.path.join(DATA, "clarity")
AIRFRY = os.path.join(DATA, "airfry", "classification.json")

# ---------------------------------------------------------------- patterns
NUM = r"(?:\d+(?:[.,/]\d+)?|[¼½¾⅓⅔]|\d+\s*[¼½¾⅓⅔]|one|two|three|four|five|six|seven|eight|nine|ten|twelve|fifteen|twenty|thirty|forty|a|an|half an?|a few|a couple of?|several)"
UNIT_T = r"(?:sec(?:ond)?s?|min(?:ute)?s?|mins?|hours?|hrs?|h)\b"
TIME_RE = re.compile(
    r"(?:\b\d+(?:[.,/]\d+)?\s*(?:[-–—]|to|or)\s*\d+(?:[.,/]\d+)?\s*" + UNIT_T +   # 20-25 min, 3 to 4 minutes
    r"|\b(?:\d+(?:[.,/]\d+)?|[¼½¾]|one|two|three|four|five|six|seven|eight|nine|ten|twelve|fifteen|twenty|thirty|forty|a|an|half an?)\s*(?:more\s+|additional\s+|extra\s+|further\s+)?" + UNIT_T +
    r"|\bovernight\b|\b\d+\s*[-–]?\s*\d*\s*days?\b|\b(?:a|one) day\b|\b\d+\s*(?:[-–]|to)?\s*\d*\s*whistles?\b"
    r"|\b(?:according to|per|following|as directed on) (?:the )?(?:package|packet|pack|box|bag|manufacturer)"
    r"|\bpackage (?:directions|instructions)\b)", re.I)
VAGUE_TIME_RE = re.compile(r"\b(?:a few|a couple(?: of)?|several|few)\s+(?:more\s+)?(?:min(?:ute)?s?|seconds|hours)\b", re.I)
TEMP_RE = re.compile(r"\b\d{2,3}\s*(?:°|º|degrees?|deg)\s*[FC]?|\b\d{3}\s*[FC]\b|\b\d{2,3}\s*°?\s*(?:fahrenheit|celsius)\b|gas mark \d", re.I)
LEVEL_RE = re.compile(r"\b(?:low|medium|med|moderate|high|medium[- ]low|medium[- ]high|med[- ]high|med[- ]low|full)(?:[- ]?(?:heat|flame|power|setting))?\b"
                      r"|\b(?:simmer(?:ing)?|boil(?:ing)?|rolling boil)\b", re.I)
LEVEL_STRICT_RE = re.compile(r"\b(?:over|on|to|at|a|in a)\s+(?:a\s+)?(?:low|medium|med|moderate|high|medium[- ]low|medium[- ]high|med[- ]high|med[- ]low)\b"
                             r"|\b(?:low|medium|moderate|high|medium[- ]low|medium[- ]high)[- ](?:heat|flame)\b"
                             r"|\b(?:gentle|steady|low|bare|rolling)\s+(?:simmer|boil)\b|\bsimmer\b|\bboil(?:ing)?\b", re.I)

CLAUSE = r"(?:^|[.;:!(]\s*|,\s*|\b(?:then|and|or|to|while|first|next|meanwhile|now|again|continue to|let(?: it| them| the \w+| everything)?|allow(?: it| them)? to|lightly|gently|briefly|quickly|carefully|also)\s+)"
HEAT_VERBS = {
    "bake": r"bake", "roast": r"roast", "cook": r"cook", "simmer": r"simmer", "fry": r"(?:pan[- ]|stir[- ]|shallow[- ]|deep[- ])?fry",
    "saute": r"saut[eé]e?", "airfry": r"air[- ]?fry", "toast": r"toast", "broil": r"broil", "boil": r"boil", "sear": r"sear",
    "grill": r"grill", "microwave": r"microwave",
}
HEAT_RE = {k: re.compile(CLAUSE + r"(" + v + r")\b(?!\s+(?:sheet|dish|tray|pan|paper|powder|soda|spray|time|mat|mode|setting|function|basket)\b)", re.I)
           for k, v in HEAT_VERBS.items()}
BRING_BOIL_RE = re.compile(r"\b(?:bring|return|come)s?\b[^.;]*\b(?:to|back to) (?:a |the )?(?:boil|simmer)\b", re.I)
UNTIL_RE = re.compile(r"\buntil\b(?![^.;]{0,40}\bset aside)[^.;]{0,60}?\b(golden(?:[- ]brown)?|done|cooked(?: through)?|ready|crisp(?:y|ed)?|thick(?:ened)?|tender|set|"
                      r"brown(?:ed)?|soft(?:ened)?|translucent|reduced|charred|caramel(?:i[sz]ed)?|wilted|heated through|warm(?:ed)? through)\b", re.I)
DESIRED_RE = re.compile(r"\b(?:to your (?:desired|liking)|desired (?:crispiness|doneness|crispness|consistency|thickness)|to your liking|as you like)\b", re.I)
PREHEAT_RE = re.compile(r"\b(?:pre-?heat|heat|turn on)\b[^.;]{0,25}\b(oven|air[- ]?fryer|grill|broiler|waffle (?:iron|maker)|toaster oven)\b", re.I)
SEASON_RE = re.compile(r"\bseason\b(?!ing)([^.;]*)", re.I)
TO_TASTE_RE = re.compile(r"\bto taste\b", re.I)
SALTPEP = re.compile(r"\b(?:salt|pepper|peppercorns?|kosher|sea|black|white|freshly|ground|and|with|a|little|more|some|pinch|of|the|generously|lightly|well|both|sides|it|them|each|side|all|over|evenly|on|to|taste|if|needed|necessary|extra|bit|flaky|fine|cracked|again|then)\b", re.I)
VAGUE_AMT_RE = re.compile(r"\b(?:a|another)\s+(splash|drizzle|dash|handful|glug|knob|dollop|sprinkle|squeeze|swirl|little)\s+(?:of\s+)?(?:more\s+)?([a-z][a-z -]{2,25})", re.I)
REST_RE = re.compile(CLAUSE + r"(rest|cool|chill|refrigerate|marinate|soak|set aside to (?:cool|rest)|freeze|proof|rise)\b", re.I)
REST_OK_RE = re.compile(r"\b(?:months?|weeks?|long[- ]term|completely|room temperature|until|overnight|before serving|while|meanwhile|leftovers?|store|airtight|keeps?|up to)\b", re.I)
VESSEL_RE = re.compile(r"\b(?:pans?|sheets?|trays?|dish(?:es)?|tins?|ramekins?|mugs?|skillets?|parchment|baking paper|racks?|muffin|loaf|casserole|pie plate|cups|foil|stone|steel|mou?lds?|waffle iron|cocotte|dutch oven|pots?|bowls?|jars?|liners?|silicone|air[- ]?fryer|basket)\b", re.I)
EXEMPT_SENT_RE = re.compile(r"^\s*(?:serve|garnish|enjoy|plate|to serve|store|leftovers|refrigerate leftovers|keeps?|note|tip|optional:)\b", re.I)
TOASTER_RE = re.compile(r"\btoaster\b(?! oven)", re.I)
UNDER_GRILL_RE = re.compile(r"\bunder (?:the|a|a hot|a preheated) grill\b|\bgrill (?:on )?high\b", re.I)

# Creami
CREAMI_PROG_RE = re.compile(r"spin (?:it )?(?:again|once more)|add[- ]?in|lite[ -]?ice[ -]?cream|ice[ -]?cream|sorbet|gelato|mix[- ]?in|re-?spin|milkshake|smoothie bowl|frozen (?:yogurt|drink)|italian ice|slushi|frozen yogurt|creamiccino", re.I)
CREAMI_SPIN_RE = re.compile(r"(?<!first )(?<!second )\b(?:spin(?!ning)|process(?! in a food processor)|run (?:it|the pint|through)|churn|place (?:the pint )?in(?:to)? (?:the|your) (?:creami|machine))\b", re.I)
FREEZE_RE = re.compile(r"\bfreeze\b(?![- ](?:fill|line|safe))|\bfrozen solid\b", re.I)
FREEZE_TIME_RE = re.compile(r"\b\d+\s*(?:[-–]|to)?\s*\d*\s*(?:hours?|hrs?|h|min(?:ute)?s?)\b|\bovernight\b|\b(?:a|one|two|1|2)\s+days?\b|\b24\b", re.I)
SPLASH_MILK_RE = re.compile(r"\b(?:a splash|a little|some|a bit|a drizzle)\s+(?:of\s+)?(?:more\s+)?(?:milk|liquid|cream|water|almond milk)", re.I)

FRY_SENT_RE = re.compile(r"\b(?:deep[- ]?fr|shallow[- ]?fr|pan[- ]?fr|fry|fried|frying|hot oil|oil (?:is )?(?:to|reaches) \d|\d{3}\s*°?\s*F\b[^.]*oil|drain on (?:paper|kitchen)|until (?:the )?oil)", re.I)
PROVISIONAL_FRY_RE = re.compile(r"\bdeep[- ]?fr|\bshallow[- ]?fr|\b(?:heat|bring) (?:the |enough |plenty of )?oil (?:in [^.]{0,40})?to \d{3}|\bfry in batches\b|\binches? of oil\b|\boil for (?:deep )?frying\b", re.I)

REASON_TEXT = {
    "heat-no-time": "heat step with no time/duration",
    "heat-vague-time": "heat step with only a vague time ('a few minutes')",
    "heat-no-level": "stovetop/grill step with no heat level (low/medium/medium-high/high)",
    "oven-no-temp": "bake/roast/air-fry with no temperature anywhere in the recipe",
    "until-no-time": "'until golden/done/tender/...' with no time range",
    "vague-doneness": "'to your liking / desired crispiness' with no concrete cue or time",
    "season-no-amount": "'season'/'to taste' for something other than salt/pepper with no approximate amount",
    "vague-amount": "'a splash/drizzle/handful of X' where the ingredient list gives no amount",
    "preheat-no-temp": "preheat oven/air fryer/grill with no temperature",
    "bake-no-vessel": "bake/roast but no pan/vessel named anywhere in the recipe",
    "rest-no-time": "rest/cool/chill/marinate/soak with no time",
    "creami-no-program": "Creami spin step with no program name",
    "creami-no-freeze-time": "Creami freeze step with no freeze time",
    "creami-respin-vague": "respin liquid given as 'a splash' instead of 1-2 tbsp",
}


def sentences(step):
    parts = re.split(r"(?<=[.!?;])\s+(?=[A-Z0-9(“\"])", step.strip())
    return [p for p in parts if p.strip()]


def is_creami(r):
    return (r.get("section") in (None, "creami")) or bool(r.get("creamiType"))


def category(r):
    sec = r.get("section")
    if sec == "meal":
        return "meal"
    if sec in (None, "creami") or r.get("creamiType"):
        return "creami"
    return sec or "other"


def ing_lines(r):
    va = r.get("vegAdaptation") or {}
    lines = [i.get("text") or "" for i in (r.get("base") or []) + (r.get("mixIns") or [])]
    for s in va.get("swaps") or []:
        if isinstance(s, dict):
            w = s.get("with")
            lines.append((w.get("text") if isinstance(w, dict) else w) or "")
    return lines


def ing_has_amount(word_phrase, lines):
    """True if an ingredient line naming any content word of `word_phrase` carries a number/unit amount."""
    words = [w for w in re.findall(r"[a-z]{3,}", word_phrase.lower())
             if w not in {"the", "and", "with", "more", "some", "your", "over", "top", "each", "into", "onto", "for", "fresh", "chopped"}]
    if not words:
        return True
    hit = False
    for line in lines:
        ll = line.lower()
        if any(w in ll or (w.endswith("s") and w[:-1] in ll) for w in words):
            hit = True
            if re.search(r"\d|[¼½¾⅓⅔]|\b(?:one|two|three|half|pinch)\b", ll) and not re.search(r"to taste|as needed|for serving|optional", ll):
                return True
    return not hit and False


def check_step(r, steps, idx, ctx):
    """Return the set of reason codes for steps[idx]."""
    step = steps[idx]
    reasons = set()
    sents = sentences(step)
    prev = " ".join(steps[max(0, idx - 2):idx])
    before = " ".join(steps[:idx])
    lines = ctx["lines"]
    timed = set()          # heat verbs already given a time earlier in this step ("bake 30 min ... bake it on the shorter end")
    for si, s in enumerate(sents):
        if EXEMPT_SENT_RE.search(s) and not any(rx.search(s) for k, rx in HEAT_RE.items() if k not in ("toast",)):
            continue
        if ctx["skip_fry"] and FRY_SENT_RE.search(s):
            continue
        nxt = sents[si + 1] if si + 1 < len(sents) else ""
        has_time = bool(TIME_RE.search(s)) or bool(re.match(r"\s*(?:about|around|roughly|approximately|this (?:should )?takes?|it takes)\b", nxt, re.I) and TIME_RE.search(nxt))
        vague_time = bool(VAGUE_TIME_RE.search(s))
        if vague_time and not re.search(r"\d", s):
            has_time = False
        bring = bool(BRING_BOIL_RE.search(s))
        found = [k for k, rx in HEAT_RE.items() if rx.search(s)]
        if bring:
            found = [k for k in found if k not in ("boil", "simmer")]
        # 'cook' / 'heat' only (e.g. "cook the garlic for 30 seconds") – same rules as stovetop
        for k in found:
            if k == "toast" and TOASTER_RE.search(s):
                continue
            if k == "toast" and not re.search(r"\b(?:pan|skillet|oven|dry|heat|tray|sheet|until)\b", s, re.I):
                # "toast the bread" with no context – still needs a time, unless it is a garnish note
                pass
            if has_time:
                timed.add(k)
            elif k not in timed:
                reasons.add("heat-vague-time" if vague_time else "heat-no-time")
            # heat level / temperature
            oven_roast = k == "roast" and ctx["oven"]
            if k in ("bake", "airfry") or oven_roast:
                if not ctx["recipe_temp"]:
                    reasons.add("oven-no-temp")
            elif k in ("cook", "fry", "saute", "sear", "roast") or (k == "toast" and re.search(r"\b(?:pan|skillet|dry|heat|wok|tawa|ghee|oil|butter)\b", s, re.I)) or (k == "grill" and not UNDER_GRILL_RE.search(s)):
                if k == "cook" and (re.search(r"\b(?:oven|bake|in the microwave|microwave|air[- ]?fryer|slow cooker|instant pot|pressure|rice cooker|waffle)\b", s + " " + prev, re.I)
                                    or re.search(r"\bcook (?:the |your )?(?:pasta|noodles|rice|quinoa|spaghetti|macaroni|ramen|udon|soba|couscous|grains?|shells|penne|rigatoni|fusilli|orzo|linguine|fettuccine|lentils|dal|beans)\b", s, re.I)
                                    or re.search(r"\bcook (?:the |your )?(?:pasta|noodles|rice|quinoa|spaghetti|macaroni|ramen|udon|soba|couscous|grains?)\b", s, re.I)):
                    continue
                if k == "toast" and re.search(r"\boven\b", s, re.I):
                    continue
                if k == "grill" and re.search(r"\bgrill(?:ed)? (?:pan )?(?:on|over) (?:a )?(?:\w+[- ])?(?:high|medium|low)", s, re.I):
                    continue
                if re.search(r"\b(?:instant pot|pressure cooker|slow cooker|rice cooker)\b", s + " " + prev, re.I) or \
                        re.search(r"\b(?:according to|per|following) (?:the )?(?:package|packet|pack|box|bag)|package (?:directions|instructions)", s, re.I):
                    continue
                if not (LEVEL_STRICT_RE.search(step) or LEVEL_STRICT_RE.search(before) or TEMP_RE.search(s)):
                    reasons.add("heat-no-level")
        if not found or bring:
            m = UNTIL_RE.search(s)
            if m and not has_time:
                cue = m.group(1).lower()
                heatish = re.search(r"\b(?:heat|pan|skillet|oven|pot|wok|cook|fry|bake|roast|simmer|boil|grill|broil|toast|melt|warm|microwave|air[- ]?fry|sear|reduce)\w*", s, re.I)
                if heatish or cue in ("set", "done", "cooked", "ready"):
                    reasons.add("until-no-time")
        if DESIRED_RE.search(s) and not has_time and re.search(r"cook|fry|bake|crisp|toast|grill|roast|air", s, re.I):
            reasons.add("vague-doneness")
        # preheat
        pm = PREHEAT_RE.search(s)
        if pm and not TEMP_RE.search(s) and not re.search(r"\b(?:high|medium|low)\b", s, re.I):
            if pm.group(1).lower().startswith(("oven", "air", "toaster")):
                reasons.add("preheat-no-temp")
        # season / to taste
        sm = SEASON_RE.search(s)
        if sm and not re.search(r"\bseasoning\b", sm.group(0), re.I):
            obj = sm.group(1)
            obj = re.split(r"(?:,|\band\b|\bthen\b)\s+(?!(?:black |white |freshly (?:ground |cracked )?|ground |kosher |sea )?(?:pepper|salt)\b)|\b(?:before|until|till|while|if desired)\b", obj, 1)[0]
            leftover = SALTPEP.sub(" ", re.sub(r"[^a-zA-Z ]", " ", obj)).strip()
            if leftover:
                if not re.search(r"\d|[¼½¾]", obj) and not ing_has_amount(leftover, lines):
                    reasons.add("season-no-amount")
            elif re.search(r"\bto taste\b", obj, re.I) and ctx["unq_seasonings"]:
                reasons.add("season-no-amount")
        elif TO_TASTE_RE.search(s):
            before = s[:TO_TASTE_RE.search(s).start()]
            tail = re.split(r"[,;]|\b(?:and|with|add|stir in|adjust)\b", before)[-1]
            leftover = SALTPEP.sub(" ", re.sub(r"[^a-zA-Z ]", " ", tail)).strip()
            if leftover and not ing_has_amount(leftover, lines):
                reasons.add("season-no-amount")
            elif not leftover and ctx["unq_seasonings"] and not re.search(r"salt|pepper", s, re.I):
                reasons.add("season-no-amount")
        for vm in VAGUE_AMT_RE.finditer(s):
            kind, what = vm.group(1).lower(), vm.group(2)
            if kind == "little" and not re.search(r"\b(?:oil|water|milk|butter|sauce|broth|stock|cream|juice)\b", what, re.I):
                continue
            if ctx["creami"] and SPLASH_MILK_RE.search(s):
                reasons.add("creami-respin-vague")
                continue
            if not ing_has_amount(what, lines):
                reasons.add("vague-amount")
        # rests (non-Creami freeze handled here too)
        rm = REST_RE.search(s)
        if rm and not has_time and not REST_OK_RE.search(s) and not bring:
            verb = rm.group(1).lower()
            if not (ctx["creami"] and verb == "freeze"):
                if not (verb == "cool" and re.search(r"\bslightly\b|\ba bit\b|\bbriefly\b", s) is None and re.search(r"\bcool(?:ing)? rack\b", s)):
                    reasons.add("rest-no-time")
        # Creami
        if ctx["creami"]:
            if CREAMI_SPIN_RE.search(s) and not CREAMI_PROG_RE.search(s) and not re.search(r"\b(?:water|blender|blend|hot|warm)\b", s, re.I):
                reasons.add("creami-no-program")
            if FREEZE_RE.search(s) and not FREEZE_TIME_RE.search(s) and not re.search(r"\bfrozen\b.*\b(?:fruit|berries|banana)|\bfreezer\b(?! for)", s, re.I):
                reasons.add("creami-no-freeze-time")
            if SPLASH_MILK_RE.search(s) and re.search(r"re-?spin", s, re.I):
                reasons.add("creami-respin-vague")
    # vessel: only judged on the first bake/roast step of a recipe
    if ctx["bake_no_vessel_idx"] == idx:
        reasons.add("bake-no-vessel")
    return reasons


# ---------------------------------------------------------------- source mapping
def source_files():
    return [os.path.join(DATA, "book_recipes.json")] + sorted(glob.glob(os.path.join(DATA, "books", "*.json"))) + \
        sorted(glob.glob(os.path.join(DATA, "web", "*.json")))


def load_sources():
    idx = collections.defaultdict(list)
    for fp in source_files():
        try:
            items = json.load(open(fp, encoding="utf-8"))
        except (OSError, ValueError):
            continue
        if isinstance(items, dict):
            items = items.get("recipes", [])
        for i, r in enumerate(items):
            if isinstance(r, dict) and r.get("id"):
                idx[r["id"]].append((os.path.relpath(fp, ROOT), i, r))
    return idx


def pick_source(built, cands):
    """Choose the source record the build kept: the one whose instructions match the built ones best."""
    if not cands:
        return None, []
    def score(c):
        src = c[2].get("instructions") or []
        same = sum(1 for a, b in zip(src, built.get("instructions") or []) if a == b)
        return (same, -len(c[0]))
    best = max(cands, key=score)
    return best, [c[0] for c in cands if c is not best]


def load_airfry():
    try:
        d = json.load(open(AIRFRY, encoding="utf-8"))
    except (OSError, ValueError):
        return None
    out = {}
    if isinstance(d, dict):
        items = d.get("recipes", d)
        if isinstance(items, dict):
            for k, v in items.items():
                out[k] = (v.get("class") if isinstance(v, dict) else v)
        else:
            d = items
    if isinstance(d, list):
        for v in d:
            if isinstance(v, dict) and v.get("id"):
                out[v["id"]] = v.get("class")
    return out


# ---------------------------------------------------------------- audit
def audit(recipes, airfry):
    results = {}
    for r in recipes:
        va = r.get("vegAdaptation") or {}
        fields = [("instructions", r.get("instructions") or [])]
        if va.get("steps"):
            fields.append(("vegAdaptation.steps", va["steps"]))
        all_text = " ".join(s for _, st in fields for s in st)
        lines = ing_lines(r)
        unq = [l for l in lines if re.search(r"to taste|as needed", l, re.I) and not re.search(r"\b(?:salt|pepper)\b", l, re.I)]
        if airfry is not None:
            skip_fry = airfry.get(r["id"]) in ("deep_fry", "shallow_fry")
        else:
            skip_fry = bool(PROVISIONAL_FRY_RE.search(all_text))
        per_field = {}
        for fname, steps in fields:
            oven = bool(re.search(r"\boven\b|\b(?:roasting|baking) (?:tray|sheet|pan|dish)\b|\bsheet pan\b", " ".join(steps), re.I) or TEMP_RE.search(" ".join(steps)))
            bake_idx = None
            if not VESSEL_RE.search(" ".join(steps)):
                for i, s in enumerate(steps):
                    if HEAT_RE["bake"].search(s) or (oven and HEAT_RE["roast"].search(s)):
                        bake_idx = i
                        break
            ctx = {"oven": oven, "lines": lines, "unq_seasonings": unq, "skip_fry": skip_fry, "creami": is_creami(r),
                   "recipe_temp": bool(TEMP_RE.search(" ".join(steps))), "bake_no_vessel_idx": bake_idx}
            flagged = {}
            for i in range(len(steps)):
                rs = check_step(r, steps, i, ctx)
                if rs:
                    flagged[i] = sorted(rs)
            # Creami recipe with no freeze time anywhere
            if ctx["creami"] and not FREEZE_TIME_RE.search(" ".join(steps)) and not r.get("section"):
                fi = next((i for i, s in enumerate(steps) if FREEZE_RE.search(s)), 0)
                flagged.setdefault(fi, [])
                if "creami-no-freeze-time" not in flagged[fi]:
                    flagged[fi] = sorted(flagged[fi] + ["creami-no-freeze-time"])
            if flagged:
                per_field[fname] = flagged
        if per_field:
            results[r["id"]] = (per_field, skip_fry)
    return results


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--built", default=BUILT)
    ap.add_argument("--out", default=OUT)
    ap.add_argument("--batches", action="store_true", help="also write batches.json")
    ap.add_argument("--batch-size", type=int, default=60)
    ap.add_argument("--show", type=int, default=20, help="worst N recipes to print")
    a = ap.parse_args()

    recipes = json.load(open(a.built, encoding="utf-8"))
    airfry = load_airfry()
    if airfry is None:
        print("WARNING: %s not found; using a provisional deep/shallow-fry regex to skip frying sentences. Re-run once it exists.\n"
              % os.path.relpath(AIRFRY, ROOT))
    src = load_sources()
    res = audit(recipes, airfry)

    flagged, mismatches, unmapped = {}, 0, []
    by_id = {r["id"]: r for r in recipes}
    for rid, (per_field, skip_fry) in res.items():
        r = by_id[rid]
        best, also_in = pick_source(r, src.get(rid, []))
        if best is None:
            unmapped.append(rid)
        file = best[0] if best else None
        srec = best[2] if best else {}
        steps_detail = []
        for fname, fl in per_field.items():
            built_steps = r["instructions"] if fname == "instructions" else r["vegAdaptation"]["steps"]
            src_steps = srec.get("instructions") if fname == "instructions" else ((srec.get("vegAdaptation") or {}).get("steps"))
            for i, rs in sorted(fl.items()):
                d = {"field": fname, "idx": i, "text": built_steps[i], "reasons": rs}
                if src_steps is None:
                    d["note"] = "vegAdaptation.steps is generated at build time (source has none); fix the matching instructions step"
                elif i >= len(src_steps) or src_steps[i] != built_steps[i]:
                    d["sourceText"] = src_steps[i] if i < len(src_steps) else None
                    mismatches += 1
                steps_detail.append(d)
        first = "instructions" if "instructions" in per_field else "vegAdaptation.steps"
        entry = {"file": file, "field": first, "stepIdx": sorted(per_field[first]),
                 "reasons": sorted({x for v in per_field[first].values() for x in v}),
                 "name": r["name"], "category": category(r), "sourceUrl": (r.get("source") or {}).get("url"),
                 "steps": steps_detail}
        other = [f for f in per_field if f != first]
        if other:
            entry["also"] = {"field": other[0], "stepIdx": sorted(per_field[other[0]]),
                             "reasons": sorted({x for v in per_field[other[0]].values() for x in v})}
        if also_in:
            entry["duplicateIdIn"] = also_in
        if skip_fry:
            entry["fryingStepsLeftToAirfry"] = True
        flagged[rid] = entry

    os.makedirs(a.out, exist_ok=True)
    with open(os.path.join(a.out, "flagged.json"), "w", encoding="utf-8") as f:
        json.dump(flagged, f, ensure_ascii=False, indent=1)

    # ---- report
    total_steps = sum(len(r.get("instructions") or []) + len(((r.get("vegAdaptation") or {}).get("steps")) or []) for r in recipes)
    nsteps = sum(len(e["steps"]) for e in flagged.values())
    print("Recipes: %d   steps checked: %d" % (len(recipes), total_steps))
    print("Flagged: %d recipes (%.1f%%), %d steps (%.1f%%)" % (len(flagged), 100 * len(flagged) / len(recipes), nsteps, 100 * nsteps / total_steps))
    rc = collections.Counter(x for e in flagged.values() for s in e["steps"] for x in s["reasons"])
    print("\nSteps per reason:")
    for k, v in rc.most_common():
        print("  %-24s %5d  %s" % (k, v, REASON_TEXT.get(k, "")))
    print("\nBy category:")
    cat_tot = collections.Counter(category(r) for r in recipes)
    cat_fl = collections.Counter(e["category"] for e in flagged.values())
    for k in cat_tot:
        print("  %-8s %4d / %4d  (%.0f%%)" % (k, cat_fl[k], cat_tot[k], 100 * cat_fl[k] / cat_tot[k]))
    print("\nBy source file:")
    file_tot = collections.Counter()
    for r in recipes:
        best, _ = pick_source(r, src.get(r["id"], []))
        file_tot[best[0] if best else "?"] += 1
    file_fl = collections.Counter(e["file"] for e in flagged.values())
    for k in sorted(file_tot):
        print("  %-44s %4d / %4d  (%.0f%%)" % (k, file_fl[k], file_tot[k], 100 * file_fl[k] / file_tot[k]))
    print("\nWorst %d recipes (flagged steps):" % a.show)
    worst = sorted(flagged.items(), key=lambda kv: (-len(kv[1]["steps"]), kv[0]))[:a.show]
    for rid, e in worst:
        print("  %2d  %-60s %s" % (len(e["steps"]), e["name"][:60], e["file"]))
    if mismatches:
        print("\nNOTE: %d flagged steps differ between the built and source text (build-time fixes); see 'sourceText'." % mismatches)
    if unmapped:
        print("WARNING: %d recipes not found in any source file: %s" % (len(unmapped), ", ".join(unmapped[:10])))
    dups = [rid for rid, e in flagged.items() if e.get("duplicateIdIn")]
    if dups:
        print("NOTE: ids present in more than one source file (the build keeps the first): %s" % ", ".join(dups))
    print("\nWrote %s" % os.path.relpath(os.path.join(a.out, "flagged.json"), ROOT))

    if a.batches:
        # files the air-fryer batches (data/airfry/batches.json) also touch: don't edit them at the same time
        af_files = set()
        try:
            afb = json.load(open(os.path.join(DATA, "airfry", "batches.json"), encoding="utf-8"))
        except (OSError, ValueError):
            afb = {}
        groups = afb.values() if isinstance(afb, dict) else afb
        for g in groups:
            ids = g.get("recipeIds", []) if isinstance(g, dict) else g
            for rid in ids if isinstance(ids, list) else []:
                if rid in by_id:
                    best, _ = pick_source(by_id[rid], src.get(rid, []))
                    if best:
                        af_files.add(best[0])
        write_batches(flagged, a.out, a.batch_size, af_files)


# ---------------------------------------------------------------- batching
PRIORITY = {"meal": 0, "creami": 1, "dessert": 2, "drink": 3, "other": 4}


def write_batches(flagged, out_dir, size, airfry_files=()):
    by_file = collections.defaultdict(list)
    for rid, e in flagged.items():
        by_file[e["file"]].append(rid)
    # file priority = its most common flagged category; ties -> higher priority
    def fprio(fp):
        c = collections.Counter(flagged[r]["category"] for r in by_file[fp])
        top = max(c.items(), key=lambda kv: (kv[1], -PRIORITY.get(kv[0], 9)))[0]
        return PRIORITY.get(top, 9), top
    files = sorted(by_file, key=lambda fp: (fprio(fp)[0], -len(by_file[fp]), fp))
    chunks = []          # (prio, cat, [(file, [ids])])
    hi = int(size * 1.25)
    for fp in files:
        ids = sorted(by_file[fp], key=lambda r: (PRIORITY.get(flagged[r]["category"], 9), r))
        n = len(ids)
        if n > hi:
            k = -(-n // size)
            step = -(-n // k)
            for j in range(0, n, step):
                chunks.append([fprio(fp), [(fp, ids[j:j + step])], True, j // step])
        else:
            chunks.append([fprio(fp), [(fp, ids)], False])
    # merge small single-file chunks of the same priority group up to ~size
    batches = []
    small = [c for c in chunks if not c[2] and len(c[1][0][1]) < size * 0.75]
    big = [c for c in chunks if c not in small]
    for c in big:
        batches.append(c)
    open_b = {}
    for c in sorted(small, key=lambda c: (c[0][0], -len(c[1][0][1]))):
        key = c[0][0]
        b = open_b.get(key)
        cnt = sum(len(x[1]) for x in b[1]) if b else 0
        if b and cnt + len(c[1][0][1]) <= size + 5:
            b[1].extend(c[1])
        else:
            nb = [c[0], list(c[1]), False]
            batches.append(nb)
            open_b[key] = nb
    batches.sort(key=lambda b: (b[0][0], b[3] if len(b) > 3 else 0, -sum(len(x[1]) for x in b[1])))
    # waves: batches sharing a file run in different waves, earlier batches first
    out, file_wave = [], {}
    for n, b in enumerate(batches, 1):
        wave = 1 + max([file_wave.get(fp, 0) for fp, _ in b[1]] or [0])
        for fp, _ in b[1]:
            file_wave[fp] = wave
        ids = [r for _, rs in b[1] for r in rs]
        cats = collections.Counter(flagged[r]["category"] for r in ids)
        out.append({
            "batch": n,
            "wave": wave,
            "priority": b[0][1],
            "files": [{"file": fp, "recipes": len(rs)} for fp, rs in b[1]],
            "recipeCount": len(ids),
            "stepCount": sum(len(flagged[r]["steps"]) for r in ids),
            "categories": dict(cats),
            "recipeIds": ids,
        })
        shared = sorted(fp for fp, _ in b[1] if fp in airfry_files)
        if shared:
            out[-1]["sharesFilesWithAirfry"] = shared
    # a wave must not hold two batches touching the same file (checked)
    for w in {b["wave"] for b in out}:
        seen = collections.Counter(f["file"] for b in out if b["wave"] == w for f in b["files"])
        assert all(v == 1 for v in seen.values()), "file in two batches of wave %d" % w
    doc = {
        "_format": "Rewrite batches. Run every batch of wave 1 in parallel, then wave 2, etc.: batches sharing a source file "
                   "are in different waves, so no file is edited by two batches at once. 'sharesFilesWithAirfry' lists source files that the air-fryer conversion (data/airfry/batches.json) also edits: run that batch only when the air-fryer batch on the same file is not running. Each recipeId's flagged steps, reasons and "
                   "source file are in flagged.json. Priority order: meals, then Creami, then desserts and drinks.",
        "batchSize": size,
        "batches": out,
    }
    with open(os.path.join(out_dir, "batches.json"), "w", encoding="utf-8") as f:
        json.dump(doc, f, ensure_ascii=False, indent=1)
    print("\nBatches (%d):" % len(out))
    for b in out:
        print("  #%-2d wave %d  %-7s %3d recipes %4d steps  %s%s" % (b["batch"], b["wave"], b["priority"], b["recipeCount"], b["stepCount"],
                                                          ", ".join("%s(%d)" % (os.path.basename(f["file"]), f["recipes"]) for f in b["files"]),
                                                          "  [shares with airfry: %s]" % ", ".join(os.path.basename(x) for x in b["sharesFilesWithAirfry"]) if b.get("sharesFilesWithAirfry") else ""))
    print("Wrote %s" % os.path.relpath(os.path.join(out_dir, "batches.json"), ROOT))


if __name__ == "__main__":
    sys.exit(main())
