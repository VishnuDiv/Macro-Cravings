"""Unit tests for data_fixes.py, one or more cases per numbered fix. Run by logic_checks/run.sh."""
import copy
import importlib.util
import os
import sys

here = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("data_fixes", os.path.join(here, "data_fixes.py"))
df = importlib.util.module_from_spec(spec)
spec.loader.exec_module(df)

bad = 0
n = 0


def check(ok, msg):
    global bad, n
    n += 1
    print("  %s  %s" % ("ok  " if ok else "FAIL", msg))
    bad += not ok


def ing(text, key=None, grams=None, count=None):
    return {"text": text, "key": key, "grams": grams, "ml": None, "count": count, "optional": False}


def rec(id, name="Test", section="meal", base=None, servings=2, macros=None, **kw):
    r = {"id": id, "name": name, "section": section, "base": base or [], "mixIns": [], "instructions": ["Mix it.", "Serve."],
         "servings": servings, "macros": macros, "tags": [], "source": {"kind": "book", "title": "The Ultimate High Protein Chef Cookbook", "page": 1}}
    r.update(kw)
    return r


# ensure_veg_swap helper
r = rec("a", base=[ing("30 g parmesan", "parmesan", 30)], macros={"calories": 800, "protein": 40, "carbs": 60, "fat": 30}, vegetarian=True)
l = r["base"][0]
check(df.ensure_veg_swap(r, l, ing("x", "y"), "n", {"parmesan": "vegetarian hard cheese"}, "P → V")
      and r["vegetarian"] is False and r["vegAdaptation"]["summary"] == "P → V" and r["vegAdaptation"]["macrosPerServing"]["calories"] == 400
      and r["vegAdaptation"]["steps"] == ["Mix it.", "Serve."], "ensure_veg_swap creates the adaptation (per-serving macros copied)")
check(df.ensure_veg_swap(r, l, ing("x", "y"), "n") is False and len(r["vegAdaptation"]["swaps"]) == 1, "ensure_veg_swap skips a line that is already swapped")

# 1 ramen
r1 = rec("r1", "Spicy Ramen Bowl", base=[ing("1 packet instant ramen noodles", "ramen", count=1)], tags=["ramen"], vegetarian=True)
r1b = rec("r1b", "Salad", base=[ing("1 packet instant ramen", "ramen")], tags=[])
check(df.fix1_ramen([r1, r1b]) == 1 and r1["vegAdaptation"]["swaps"][0]["with"]["key"] == "instant_ramen"
      and r1["vegAdaptation"]["swaps"][0]["with"]["count"] == 1 and "vegAdaptation" not in r1b, "fix 1: ramen packet swapped (only ramen/pantry recipes), amounts kept")

# 2 hidden meat
r2 = rec("r2", base=[ing("Caesar dressing 2 tbsp", "caesar"), ing("1 tbsp Worcestershire sauce", "ws"), ing("1 tbsp fish sauce"), ing("1 tbsp oyster sauce"),
                     ing("1 tbsp mushroom oyster sauce"), ing("20 g Parmesan", "parmesan", 20), ing("2 tbsp pesto"), ing("200 ml chicken stock"),
                     ing("1 tbsp gelatin"), ing("50 g marshmallows"), ing("20 g vegan marshmallows"), ing("1 tbsp vegan Worcestershire")],
         instructions=["Add the parmesan and worcestershire.", "Pour in the chicken stock."])
c = df.fix2_hidden_meat([r2])
keys = [s["with"]["key"] for s in r2["vegAdaptation"]["swaps"]]
check(keys == ["caesar_dressing_vegetarian", "vegetarian_worcestershire", "soy_sauce_miso", "vegetarian_oyster_sauce", "vegetarian_parmesan",
               "vegetarian_pesto", "vegetable_stock", "agar_powder", "vegan_marshmallows"], "fix 2: every hidden-meat row swaps (mushroom/vegan lines skipped): %s" % keys)
st = " ".join(r2["vegAdaptation"]["steps"])
check("vegetarian hard cheese" in st and "vegetarian Worcestershire" in st and "vegetable stock" in st and "parmesan" not in st.lower(), "fix 2: steps rewritten")
r2c = rec("r2c", section="creami", base=[ing("1 tbsp gelatin")])
df.fix2_hidden_meat([r2c])
check("vegAdaptation" not in r2c, "fix 2: creami recipes get no vegAdaptation")
r2d = rec("r2d", base=[ing("20 g Parmesan"), ing("10 g pecorino")])
df.fix2_hidden_meat([r2d])
check(r2d["vegAdaptation"]["steps"] == ["Mix it.", "Serve."] and len(r2d["vegAdaptation"]["swaps"]) == 2, "fix 2: two lines, steps not double-replaced")

# 3 collagen
r3 = rec("r3", base=[ing("10 g collagen peptides", "collagen", 10)])
r3c = rec("r3c", section="creami", base=[ing("10 g collagen", "collagen", 10)])
check(df.fix3_collagen([r3, r3c]) == 2 and r3["base"][0]["key"] == "collagen_powder" and r3["vegAdaptation"]["swaps"][0]["with"]["key"] == "protein_powder_unflavored"
      and r3["vegAdaptation"]["swaps"][0]["with"]["grams"] == 10 and "vegAdaptation" not in r3c and r3c["base"][0]["key"] == "collagen_powder", "fix 3: collagen re-keyed, swapped for non-creami")

# 4 crunchwraps
r4 = rec("chef-breakfast-crunchwraps", base=[ing("1 crispy beef tortilla", "beef")])
check(df.fix4_crunchwraps([r4]) == 1 and r4["vegAdaptation"]["swaps"][0]["with"]["key"] == "tortilla_wrap", "fix 4: crunchwraps swap")

# 5 fat
r5 = rec("r5", servings=4, base=[ing("800 g 15% ground beef", "beef", 800)], source={"kind": "book"},
         vegAdaptation={"summary": "", "swaps": [{"replaces": "800 g 15% ground beef", "with": ing("300 g soy chunks", "soy_chunks", 300), "note": ""}],
                        "steps": [], "macrosPerServing": {"calories": 700, "protein": 70, "carbs": 90, "fat": 20}})
df.fix5_fat([r5])
check(r5["vegAdaptation"]["macrosPerServing"]["fat"] == 1, "fix 5: fattier meat lowers veg fat, then the sub-fat floor applies (got %s)" % r5["vegAdaptation"]["macrosPerServing"])
r5b = rec("r5b", servings=2, base=[ing("600 g chicken breast", "chicken_breast", 600)], source={"kind": "book"},
          vegAdaptation={"summary": "", "swaps": [{"replaces": "600 g chicken breast", "with": ing("700 g seitan", "seitan", 700), "note": ""}],
                         "steps": [], "macrosPerServing": {"calories": 400, "protein": 50, "carbs": 30, "fat": 0}})
df.fix5_fat([r5b])
check(r5b["vegAdaptation"]["macrosPerServing"]["fat"] == 7 and r5b["vegAdaptation"]["macrosPerServing"]["calories"] == 463, "fix 5: floor raises fat to 7 g and kcal by 9x (got %s)" % r5b["vegAdaptation"]["macrosPerServing"])
r5c = rec("r5c", servings=1, base=[ing("500 g lean ground turkey", "turkey", 500)], source={"kind": "book"},
          vegAdaptation={"summary": "", "swaps": [{"replaces": "500 g lean ground turkey", "with": ing("300 g tofu", "tofu_extra_firm", 300), "note": ""}],
                         "steps": [], "macrosPerServing": {"calories": 500, "protein": 50, "carbs": 10, "fat": 10}})
df.fix5_fat([r5c])
check(r5c["vegAdaptation"]["macrosPerServing"]["fat"] == 30, "fix 5: 'lean' caps meat fat at 4 (rubric 8): +20 g (got %s)" % r5c["vegAdaptation"]["macrosPerServing"])

# 6 web macros
w = lambda id, m, **k: rec(id, source={"kind": "web", "url": "https://x.com/" + id}, macros=m, servings=1, **k)
ws = [w("w1", {"calories": 900, "protein": 10, "carbs": 10, "fat": 10}), w("w2", {"calories": 500, "protein": 30, "carbs": 50, "fat": 15, "fiber": 45}),
      w("w3", {"calories": 3000, "protein": 200, "carbs": 300, "fat": 100}), w("w4", {"calories": 500, "protein": 30, "carbs": 50, "fat": 12}),
      w("web-meal-quinoa-idli-ministryofcurry", {"calories": 300, "protein": 15, "carbs": 40, "fat": 7}, evidence={"verdict": "promising", "summary": "Nice."})]
out = df.fix6_web_macros(ws)
check(out == ["w1", "w2", "w3", "web-meal-quinoa-idli-ministryofcurry"] and ws[3]["macros"] is not None
      and df.NOTE_BAD_MACROS in ws[4]["evidence"]["summary"] and df.NOTE_BAD_MACROS in ws[0]["evidence"]["summary"], "fix 6: inconsistent, fibre, kcal and listed ids nulled with a note")

# 7 per piece
p1 = rec("p1", "Mini Muffins", servings=12, macros={"calories": 1200, "protein": 1, "carbs": 1, "fat": 1})
p2 = rec("p2", "Chicken Nuggets", servings=6, macros={"calories": 1800, "protein": 1, "carbs": 1, "fat": 1})
p3 = rec("p3", "Baked Falafel", servings=8, macros={"calories": 2400, "protein": 1, "carbs": 1, "fat": 1}, course="dinner")
p4 = rec("p4", "Pasta Bake", servings=4, macros={"calories": 2000, "protein": 1, "carbs": 1, "fat": 1})
check(df.fix7_pieces([p1, p2, p3, p4]) == 3 and p1["servingLabel"] == "piece" and p3["course"] == "snack" and "servingLabel" not in p4, "fix 7: per-piece servings")

# 8 baking soda
r8 = rec("r8", base=[ing("1 tsp baking soda", "baking_soda"), ing("800 g steak", "steak", 800)],
         vegAdaptation={"summary": "", "swaps": [{"replaces": "800 g steak", "with": ing("700 g seitan", "seitan", 700), "note": ""}],
                        "steps": ["Mix flour. Add the baking soda to the water. Knead well.", "Add bicarbonate of soda."], "macrosPerServing": None})
check(df.fix8_seitan_baking_soda([r8]) == 1 and r8["vegAdaptation"]["steps"] == ["Mix flour. Knead well."]
      and r8["vegAdaptation"]["swaps"][-1]["with"]["key"] == "mix_in_choice", "fix 8: baking soda swapped out, sentences removed")

# 9 missing lines
r9 = rec("chef-cheesy-chicken-bites", base=[ing("500 g chicken", "chicken", 500)])
r9b = rec("chef-nashville-hot-chicken-sandwich", base=[ing("1 bun")])
check(df.fix9_missing_lines([r9, r9b]) == 4 and [l["key"] for l in r9["base"]] == ["chicken", "flour", "eggs"] and [l["key"] for l in r9b["mixIns"]] == ["cabbage", "pickles"]
      and df.fix9_missing_lines([r9, r9b]) == 0, "fix 9: missing lines appended once")

# 10 re-key
r10 = rec("r10", base=[ing("salt and pepper", "bell_pepper"), ing("black pepper", "bell_pepper"), ing("1 tbsp rice vinegar", "vinegar"), ing("1 tsp sesame oil", "oil"),
                       ing("2 tbsp oil", "soy_sauce"), ing("100 g rice noodles", "noodles"), ing("1 tbsp tamarind", "x"), ing("100 g low fat paneer", "paneer"),
                       ing("1 bell pepper", "bell_pepper")])
df.fix10_rekey([r10])
check([l["key"] for l in r10["base"]] == ["salt", "black_pepper", "rice_vinegar", "sesame_oil", "olive_oil", "rice_noodles", "tamarind_paste", "paneer_low_fat", "bell_pepper"],
      "fix 10: re-keyed by text: %s" % [l["key"] for l in r10["base"]])

# 11 swap keys
r11 = rec("r11", vegAdaptation={"summary": "", "swaps": [{"replaces": "a", "with": ing("b", "soy_mince_dry")}, {"replaces": "c", "with": ing("d", "veg_parmesan")},
                                                         {"replaces": "e", "with": ing("f", "seitan")}], "steps": []})
check(df.fix11_swap_keys([r11]) == 2 and [s["with"]["key"] for s in r11["vegAdaptation"]["swaps"]] == ["soy_chunks", "vegetarian_parmesan", "seitan"], "fix 11: canonical swap keys")

# 12 / 13 duplicates
def web(id, url, keys):
    return rec(id, source={"kind": "web", "url": url}, base=[ing(k, k) for k in keys])


d1 = web("d1", "https://www.example.com/a/?utm=1", ["oats", "milk", "chia", "honey", "salt"])
d2 = web("d2", "http://example.com/a", ["oats", "milk", "chia", "honey", "salt"])           # same URL, same ingredients -> duplicate
d3 = web("d3", "http://example.com/a", ["tofu", "soy_sauce", "rice", "garlic", "ginger"])     # same URL, different ingredients -> variant, kept
d4 = web("d4", "http://example.com/b", ["oats", "milk", "chia", "honey", "salt"])           # different URL -> kept
d5 = web("d5", "http://example.com/a", ["oats", "milk", "chia", "honey", "salt", "vanilla"])  # same URL, 5/6 overlap -> duplicate
out, dropped = df.fix12_dedupe_urls([d1, d2, d3, d4, d5])
check([x["id"] for x in out] == ["d1", "d3", "d4"] and dropped == ["d2", "d5"], "fix 12: same URL + same ingredients dropped; same URL + different ingredients kept (%s)" % dropped)
c1 = rec("chef-pizza-bagels", "High Protein Pizza Bagels", macros={"calories": 800, "protein": 1, "carbs": 1, "fat": 1})
b1 = rec("bulk-pizza-bagels", "Anabolic Pizza Bagels", macros={"calories": 840, "protein": 1, "carbs": 1, "fat": 1},
         source={"kind": "book", "title": "The Ultimate Guide to Lean Bulking", "page": 33})
b2 = rec("bulk-other", "Anabolic Pizza Bagels", macros={"calories": 2000, "protein": 1, "carbs": 1, "fat": 1},
         source={"kind": "book", "title": "The Ultimate Guide to Lean Bulking", "page": 40})
b3 = rec("bulk-different", "Anabolic Pizza Pockets", macros={"calories": 800, "protein": 1, "carbs": 1, "fat": 1},
         source={"kind": "book", "title": "The Ultimate Guide to Lean Bulking", "page": 41})
out, dropped = df.fix13_book_dupes([c1, b1, b2, b3])
check(len(dropped) == 2 and c1["source"]["alsoIn"] == "The Ultimate Guide to Lean Bulking p.33" and [x["id"] for x in out] == ["chef-pizza-bagels", "bulk-different"],
      "fix 13: identical normalized names merge whatever the calories; a different name stays (%s)" % dropped)

# overnight oats protein boost: only overnight oats that are not already protein recipes
oat = lambda id, name, p, extra=None, **k: rec(id, name, servings=1, macros={"calories": 300, "protein": p, "carbs": 40, "fat": 6}, course="breakfast",
                                              base=[ing("50 g rolled oats", "rolled_oats", 50), ing("150 ml milk", "whole_milk", 150), ing("10 g chia", "chia_seeds", 10)] + (extra or []), **k)
o1 = oat("o1", "Overnight Oats with Chia", 12)                                              # milk + chia at 12 g: eligible
o2 = oat("o2", "Protein Overnight Oats", 26)                                                # "protein" in the name: not
o3 = oat("o3", "Protein Baked Oats", 9)                                                     # baked: not
o4 = oat("o4", "Chocolate Chia Pudding", 5, tags=["overnight"])                             # breakfast + overnight tag + oats: eligible
o5 = oat("o5", "Oats Upma", 10)                                                             # savory, no overnight: not
o6 = rec("o6", "Banana Bread Overnight Oats", servings=2, macros=None, course="breakfast", base=[ing("80 g oats", "oats", 80)])   # no macros: runtime check
o7 = rec("o7", "Overnight Chia Seed Pudding", course="breakfast", macros={"calories": 200, "protein": 5, "carbs": 20, "fat": 9}, base=[ing("30 g chia", "chia_seeds", 30)], tags=["overnight"])
o8 = oat("o8", "Overnight Oats", 18, extra=[ing("150 g Greek yogurt", "greek_yogurt", 150)])  # already has a protein ingredient: not
o9 = oat("o9", "Overnight Oats (Vanilla)", 11, extra=[ing("1 scoop whey", "protein_powder_vanilla", 30)])
o10 = oat("o10", "High-Protein Overnight Oats", 12, tags=["high-protein"])
o11 = oat("o11", "Overnight Oats", 12, tags=["high-protein"])                               # the tag alone does not exclude
marked = df.mark_protein_boost([o1, o2, o3, o4, o5, o6, o7, o8, o9, o10, o11])
check([x["id"] for x in marked] == ["o1", "o4", "o6", "o11"] and not any("proteinBoost" in x for x in (o2, o3, o5, o7, o8, o9, o10)),
      "protein boost: 12 g overnight oats with milk + chia eligible; 'Protein' in the name, Greek yogurt / whey lines, baked and savory oats are not (%s)" % [x["id"] for x in marked])

print("data fixes: %d checks, %d failed" % (n, bad))
sys.exit(1 if bad else 0)
