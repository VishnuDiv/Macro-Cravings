# Macro Kitchen: Food + Health spec (v1)

The app splits into two modes: **Food** (everything that exists today, plus a meal plan and "Good for" tags) and **Health** (skin, hair and progress photos). Audience: a user who wants help with a skincare routine, hairstyle choices, hair loss (slowing a receding hairline and regrowth options), and progress tracking through photos. All health data stays on the device.

## 1. App structure
- A persistent mode switch, **Food | Health**: a compact segmented pill at the top of each root screen (or a toolbar principal item). The choice persists.
- **Food tabs:** Recipes · Plan (new) · Saved · Shopping · Settings. The existing Freezer tab moves into Plan as a section, or into the Recipes toolbar; keep it reachable.
- **Health tabs:** Today · Skin · Hair · Progress · Settings (the same Settings screen, with Food and Health groups).
- **Face ID lock for Health** (LocalAuthentication): a toggle in Settings, default ON. Unlock when entering Health mode, and again after 5 min in the background. Fall back to the device passcode. Add `INFOPLIST_KEY_NSFaceIDUsageDescription` to the pbxproj build settings (both configs). Update the camera usage text to cover progress photos.

## 2. Food additions
### 2a. "Good for" tags
- Data: `Resources/food_benefits.json` (written by the content agent), with:
  - `ingredientBenefits`: {catalog_key: {benefits: [gut|skin|hair|muscle|heart|energy|bones], why: "short"}};
  - `rules`: e.g. fiber ≥ 8 g per serving → gut; protein ≥ 25 g per serving → muscle and hair; fermented ingredient → gut.
- **Recipe benefits:** the union of the rules plus every non-optional ingredient whose key has benefits and whose grams are ≥ a minimum (from the file, default 10 g; spices 1 g). Show at most 4 chips, ranked by evidence/weight.
- **UI:**
  - The detail screen gets a "Good for" row of chips (Gut, Skin, Hair, Muscle…); tapping one opens a sheet, "Why it's good for your skin", listing the contributing ingredients with their `why`.
  - Cards show up to 2 small icons.
  - Filters get a "Good for" section.
  - Sorts get "Best for skin" and "Best for gut" (score = count + weight).
### 2b. Plan tab (meal planner)
- **Targets:** in Settings → "Daily targets", calories and protein per day. Defaults derive from the goal: Cut 1,900 kcal / 160 g, Maintain 2,300 / 150, Bulk 2,800 / 170. Editable, plus a weight-based helper (protein 0.8–1 g per lb).
- **Day plan slots:** breakfast, lunch, dinner, snack (+ an optional dessert). **Generate** fills them from vegetarian-safe recipes (the veg version when adapted), using each recipe's goal version (cut/maintain/bulk) and portion scaling, so the day sums close to the targets (kcal within ±7%, protein ≥ 95%). Prefer high protein density, variety (no repeats within 3 days, mixed cuisines), saved and rated recipes, and the "Good for" focus if set. Course mapping: breakfast → breakfast; lunch/dinner → meal lunch/dinner; snack → snack/drink/Creami; dessert → dessert/Creami.
- **Per-slot actions:** swap (show 5 alternatives fitting the remaining budget), lock, and portion stepper (0.5×–2×).
- **Views:** the day view shows totals vs targets (rings); a week view (7 days) with "Generate week".
- "Add week to shopping list" merges the ingredients. Persist the plans (UserData).
- Deterministic generator with a seed, plus a "regenerate" button; unit-testable.

## 3. Health: Skin
- **Profile quiz:** skin type (oily, dry, combination, normal, sensitive), concerns (acne, oil, dryness, dark spots, texture, redness, aging/fine lines, dark circles), and sun exposure. Stored in UserData.
- **Routine builder:** templates from `Resources/skincare.json` (content agent), AM and PM, each a list of steps (cleanser, treatment, moisturizer, SPF, etc.) with a recommended active per concern and a frequency (daily, 2–3×/week, ramp-up schedule for retinoids).
- **My products:** the user adds products (name, brand optional, step, AM/PM, frequency, started date, optional photo of the bottle). They map onto the routine steps.
- **Conflicts:** rules from skincare.json (e.g. retinoid + AHA/BHA the same night, retinoid + benzoyl peroxide, vitamin C + AHA same time, a new active ramp-up), surfaced as gentle warnings on My Routine.
- **Guides:** articles from skincare.json, shown with the existing guide renderer (what each active does, how to start, what to expect and when, purging vs breakout, SPF basics).

## 4. Health: Hair
- **Profile:** hair type (straight, wavy, curly, coily), thickness, length, face shape (oval, round, square, oblong/long, heart, diamond; with simple illustrations or SF Symbols, plus a "How to tell" helper), concerns (receding hairline, thinning crown, shedding, dandruff/itchy scalp, dryness, frizz), and the Norwood stage (self-assessed, 1–7, with reference descriptions).
- **Styles:** from `Resources/haircare.json` (content agent): hairstyles with name, description, suits (face shapes, hair types, Norwood range, length), "how to ask your barber" text and maintenance level. Show the matches for the profile, ranked; mark the styles that are especially good for a receding hairline.
- **Hair loss guide:** evidence-graded interventions (A strong / B moderate / C weak / D no evidence) with what it is, how to use it, timelines (e.g. minoxidil: shedding phase, 3–6 months to see results), side effects, cost, OTC vs prescription, and "talk to a dermatologist" where prescription-only. Plus myths.
- **Routine items:** chosen interventions (e.g. ketoconazole shampoo 2×/week, minoxidil daily, scalp massage, microneedling weekly) go into the Today checklist with their schedules.

## 5. Health: Progress photos
- **Series:** Face front, Face left, Face right (skin); Hairline (front, forehead tilted); Temples (left/right); Crown (top); Hair overall. Each series has its own schedule (daily / every 2 days / weekly / custom) with local notifications at a chosen time.
- **Capture** (AVFoundation camera view):
  - a semi-transparent ghost of the previous photo in the series, with an opacity slider;
  - alignment guides (center line, eye line);
  - front/back camera toggle;
  - a 3 s timer;
  - a reminder to use the same lighting and spot.
  - Also allow importing from Photos (PhotosPicker).
- **Storage:** JPEG in Application Support/Progress/<series>/<date>.jpg plus a metadata JSON. NEVER uploaded anywhere; excluded from iCloud backup by default (`isExcludedFromBackup`), with an opt-in "Include in device backup" toggle.
- **Per entry:** date, optional note, and quick ratings (skin: breakouts 0–5, redness 0–5, oiliness 0–5; hair: shedding low/med/high), plus a link to the routine adherence that day.
- **Compare:** side-by-side and a swipe slider between any two entries, a timeline grid, and a monthly "first vs latest".
- **Hairline tracker (manual):** on a Hairline photo the user taps 3 points on the hairline (left temple peak, center, right temple peak) and 2 points on the brow line. Store them normalized. Metric = mean hairline-to-brow distance ÷ inter-brow distance, which is scale-invariant. Chart it over time with a trend line, and say "stable / receding / improving" only when the change is > 5% across ≥ 4 entries. No automatic AI measurement.
- **Export:** a user-initiated share sheet only.

## 6. Health: Today
- A date header and a checklist built from: skin AM steps, skin PM steps, hair items due today, photo series due today (tapping opens the camera), and an optional water/supplements line (user-added).
- Streaks per routine, and a 7-day adherence ring.
- Due photos get a badge on the Progress tab.

## 7. Content files (from the content agent; build against fixtures until they land)
- `data/health/skincare.json` → Resources
- `data/health/haircare.json` → Resources
- `data/catalog/food_benefits.json` → Resources
Copy them in build_data.py when present. They're original content, OK to commit.

## 8. Privacy and git
- Progress photos and health profile data live only on the device, in the app container. Nothing health-related goes to git: the repo has code and the generic content files only.
- The screenshot mode (DEBUG) must never show real progress photos. Use bundled sample placeholder images (simple generated shapes) for any Progress screenshots.

## 9. Checks (logic_checks)
- **Plan generator:**
  - deterministic with a seed;
  - day totals within ±7% kcal and ≥ 95% protein for each goal on the real data;
  - no non-vegetarian lines in the planned versions;
  - no repeats within 3 days;
  - locking a slot keeps it;
  - swap candidates fit the remaining budget.
- **Good for:** a fixture recipe with 200 g lentils → gut; ≥ 25 g protein → muscle; the why list is non-empty.
- **Skin conflicts:** retinoid + glycolic acid the same PM triggers a warning; on alternate nights it doesn't.
- **Hairline metric:** synthetic points → the expected ratio; the trend logic thresholds.
- **Schedules:** daily / every-2-days / weekly due-date calculation, including after missed days.
- **Photo store:** save/load/delete round-trip in a temp dir, and the backup-exclusion flag is set.

## 10. Photo analysis (v2)

Two layers: automatic on-device metrics (free, private) and an on-demand AI check-up (opt-in per run, uses the Claude API).

### 10a. On-device metrics (Vision / AVFoundation, no network)
- **Capture-time mattes:** when capturing with the front TrueDepth camera, enable `AVCapturePhotoOutput` semantic segmentation mattes `.hair` and `.skin` (where `availableSemanticSegmentationMatteTypes` supports them) and save the mattes next to the photo (PNG, same folder, same backup exclusion).
- **Fallback** (imported photos or no mattes): use `VNDetectFaceLandmarksRequest` to define the face, forehead and cheek regions. Label those metrics "lower confidence".
- **Skin metrics** (on face photos, inside the skin matte or cheek/forehead regions, eyes/brows/lips masked out):
  - redness = mean CIELAB a*;
  - evenness = std-dev of L* after a 15 px blur, with lower = more even;
  - spot count = local-contrast blobs 2–12 px (DoG), with lighting-normalised thresholds.
- **Hair metrics:**
  - Hairline photos: hairline height = the distance from the hair-matte lower boundary at the face midline (and at the temple columns from landmarks) to the brow line, ÷ inter-pupil distance (scale-invariant). This complements the manual 5-tap tracker; show both.
  - Crown photos: scalp visibility = 1 − (hair-matte coverage within a centered circle). Needs consistent framing, so show the ghost overlay.
- **Lighting guard:** if a photo's mean luminance differs > 15% from the series median, flag "lighting differs, so the trend point may be off" and grey it out in charts.
- **Charts:** per-metric trend lines on each series screen, using the same ≥ 4-entries / > 5% rule as the hairline for any "improving / worsening" label.

### 10b. AI check-up (Claude API, raw HTTPS; Swift has no official SDK)
- **Setup:** Settings → "AI check-up": an API key field stored in the **Keychain** (kSecClassGenericPassword, this-device-only), a "Test key" button (tiny request), and a link to console.anthropic.com. The whole app works without a key.
- **Flow:** "Run check-up" → choose Skin, Hair or Both → the app pre-selects the latest photo per relevant series (max 4, editable) → a consent sheet lists exactly what is sent (thumbnails + "your quiz answers, current routine, and last check-up summary") → Confirm.
- **Image prep:** downscale to 1568 px on the long edge, JPEG quality 0.8, strip all metadata (EXIF/GPS) by re-encoding from pixels. Base64 with no line breaks.
- **Request:** `POST https://api.anthropic.com/v1/messages`.
  - Headers: `content-type: application/json`, `x-api-key: <key>`, `anthropic-version: 2026-10-21`, `anthropic-beta: server-side-fallback-2026-07-01`.
  - Body: `model: "claude-opus-5-5"`, `max_tokens: 16000`, `fallbacks: "default"`, `output_config: {effort: "high", format: {type: "json_schema", schema: <CheckupSchema>}}`, a `system` prompt (below), and one user message whose content is, for each photo, a text block ("Photo 1 · Hairline · 2026-10-27") followed by `{type: "image", source: {type: "base64", media_type: "image/jpeg", data: …}}`, then a final text block with the JSON context (profile, routine, previous check-up summary, and the allowed ids: actives from skincare.json, interventions and styles from haircare.json).
  - Send no `thinking` param and no sampling params. URLSession timeout 180 s, with one retry on 429/5xx/network honouring `retry-after`.
- **Response handling:**
  - if `stop_reason == "refusal"`, show "The analysis couldn't be completed for these photos" plus a retry option;
  - if `max_tokens`, retry once with effort "medium";
  - otherwise take the first `type == "text"` block and JSON-decode it into `CheckupResult`.
  - Record `usage.input_tokens`/`output_tokens` and show the cost (Claude Opus 5.5: $4 / $20 per MTok), e.g. "≈ $0.09".
- **System prompt** (keep in a Swift string constant): a dermatology- and trichology-informed assistant reviewing progress photos for skincare and hair-loss self-care. It describes visible findings with severity and confidence, names likely drivers, recommends concrete steps using ONLY the provided ids where they apply, states uncertainty plainly, and sets seeDermatologist when there are red flags (painful/cystic or scarring acne, sudden patchy loss, changing moles, rashes) or when prescription options (finasteride, tretinoin, oral minoxidil) are the logical next step. No moralising, no generic disclaimers. It reports photo-quality problems (lighting, angle, blur) in photoQuality.
- **CheckupSchema** (every object `additionalProperties: false`, every key in `required`; nullable fields via `anyOf [{…}, {type: "null"}]`):
  ```
  { overall: { summary: string, nextCheckupWeeks: integer },
    photoQuality: { ok: boolean, issues: [string] },
    skin: null | { observations: [{ area: string, finding: string, severity: "none"|"mild"|"moderate"|"severe", confidence: "low"|"medium"|"high" }],
                   likelyDrivers: [string],
                   recommendations: [{ action: string, activeId: string|null, frequency: string, why: string, priority: "high"|"medium"|"low" }],
                   avoid: [string] },
    hair: null | { norwoodEstimate: string, observations: [same shape as skin],
                   recommendations: [{ action: string, interventionId: string|null, why: string, priority: "high"|"medium"|"low" }],
                   styleIds: [string] },
    seeDermatologist: { recommended: boolean, reason: string } }
  ```
- **Results screen:** sections for Summary, What I see (severity chips), Likely drivers, Do this (each with "Add to routine", which maps activeId → a routine step placeholder product, or interventionId → a hair routine item), Avoid, Styles (open the style cards), Dermatologist card (if recommended), Photo-quality tips, and the cost.
- **History:** check-ups are saved locally (the JSON + photo ids + date + cost). "Compare with last check-up" shows the changes.
- **Privacy:** photos leave the device ONLY on Confirm, only to api.anthropic.com, and only the shown ones. There's no telemetry, and the key never appears in logs. Screenshot mode uses canned fixture results and never calls the network.

### 10c. Checks
- **Request builder:** headers, model, `fallbacks: "default"`, `output_config.format` present, image blocks in order and base64 without newlines, re-encoded JPEG has no EXIF/GPS, long edge ≤ 1568.
- **Decoder:** a fixture full response (text block JSON) → CheckupResult; null skin/hair; refusal → error state; max_tokens → retry path.
- **Cost calc** from usage.
- **Keychain wrapper:** round-trip (injectable store for tests).
- **On-device metrics:** synthetic images (a flat-color face with red patches → higher a*; added dots → spot count ≈ dots; a hair matte with a known boundary → the expected hairline ratio); lighting-guard threshold.
