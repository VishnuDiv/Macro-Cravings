"""Unit tests for build_data.parse_amount. Run by logic_checks/run.sh."""
import importlib.util
import os
import sys

here = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("build_data", os.path.join(here, "build_data.py"))
bd = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bd)

CASES = [
    ("1/3 cup sugar", {"ml": 80.0}),
    ("2 tablespoons honey", {"ml": 30.0}),
    ("1 Tablespoon instant pudding mix", {"ml": 15.0}),
    ("1 (15 oz) can pumpkin", {"grams": 425.25}),
    ("½ cup Greek yogurt", {"ml": 120.0}),
    ("1 1/2 cups milk", {"ml": 360.0}),
    ("8 oz cream cheese", {"grams": 226.8}),
    ("1 tsp vanilla", {"ml": 5.0}),
    ("1-2 tbsp cocoa", {"ml": 22.5}),
    ("1/4-1/3 cup sugar", {"ml": 70.0}),
    ("100-200 g cream", {"grams": 150.0}),
    ("⅔ cup yogurt", {"ml": 160.0}),
    ("2 bananas", {"count": 2.0}),
    ("1 egg", {"count": 1.0}),
    ("0.5 tsp sea salt", {"ml": 2.5}),
    ("Crust: 3/4 cup graham crumbs", {"ml": 180.0}),
    ("1 box (0.3 oz) gelatin mix", {"grams": 8.5}),
    ("1 lb strawberries", {"grams": 453.6}),
    ("2 fl oz espresso", {"ml": 59.14}),
    ("pinch of salt", None),
    ("unsweetened plant milk, as needed", None),
]
bad = 0
for text, want in CASES:
    got = bd.parse_amount(text)
    ok = (got is None) == (want is None) and (got is None or all(abs(got[k] - v) < 0.05 for k, v in want.items()) and set(got) == set(want))
    print("  %s  parse_amount(%r) -> %s" % ("ok  " if ok else "FAIL", text, got))
    bad += not ok
print("amount parser: %d cases, %d failed" % (len(CASES), bad))
sys.exit(1 if bad else 0)
