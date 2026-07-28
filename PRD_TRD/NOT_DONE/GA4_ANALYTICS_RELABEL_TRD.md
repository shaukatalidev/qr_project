# TRD — GA4 Analytics: First-Class Relabel of the Google Tag Slot

**Status:** Draft · **Author:** Engineering (Staff) · **Date:** 2026-07-25
**Priority:** Quick win / completeness fix (gap-analysis #8). The capability is **already shipped and working** — `_GOOGLE_RE` accepts `G-…` and the edge emits `gtag.js`. This spec changes **strings, display-label derivation, docs, and two tests**. Its engineering value is entirely in the *constraints*: prove no behaviour changed, keep the consent gate, keep `GTM-` rejected. Do not let it grow.
**Tiers:** **Pro + Agency**, unchanged (`retargeting_pixels`, seeded by `0009`, flipped on by `0013`). No re-gating.
**Plan flags (NEW):** **None.** The `retargeting_pixels` key is deliberately **not** renamed — renaming a `plans.features` key would mean a migration, a `FEATURE_ENFORCEMENT` edit, and `test_feature_gate_coverage` churn for a cosmetic gain. `FEATURE_ENFORCEMENT["retargeting_pixels"] = "enforced"` (`subscription.py:551`) stays byte-for-byte.
**Migration slot:** **None — no migration required.** Reasoning: the only stored artefacts are `retargeting_pixels.provider` (`'meta' | 'google'`, free-text column, no enum/CHECK) and `retargeting_pixels.pixel_id`. The GA4-vs-Ads distinction is **derivable from the `pixel_id` prefix**, so it needs no column, no backfill, and no data rewrite. Nothing in `plans.features` changes. If a future revision adds a per-pixel `label`/`nickname` column, use provisional slot **`0037`** — highest on disk is `0032_lemonsqueezy_variant_backfill.sql`, `0033` is claimed by QR_EXPIRY_SCHEDULING, and the concurrent quick-win specs (UPI / Location / Phone) claim the next slots; **re-verify against disk at build time**, this repo has already shipped a commit fixing stale slot numbers.
**Services touched:** `qr_frontend` (all real work: copy + derived-label helper) · `qr_backend` (**one error-message string** + one test) · `qr_cf_code` (**a header comment + one test — no logic**, so **`npm run deploy:prod` is NOT required**). No DB, no KV, no cron, no env var, no external service.
**Implements PRD:** GA4 Analytics: First-Class Relabel of the Google Tag Slot. **Builds on** `RETARGETING_PIXELS_PRD.md` (shipped, `0013`) and `0031_per_qr_retargeting.sql`.

**Rev (2026-07-25, post eng-review):** Reviewed via `/plan-eng-review`; ships as-drafted. **No migration** (the `0037` in the metadata is a *future* per-pixel-label contingency only — an earlier collision flag was a false positive). **Keep GA4 at Pro+** on `retargeting_pixels` (no re-gating; a Starter split would need a new flag + migration + `build_pixels()` prefix filter). Non-negotiable constraints reaffirmed: **do not touch** the consent gate (`index.js:428` / `marketingConsentGranted`); keep `GTM-` rejected at **both** the backend validator and the edge, pinned by test; if `UA-` is ever tightened, **backend-only** (edge must stay ≥ as permissive, R5). Legal-copy cross-check on the cookies page is an action item (PRD R6).

---

## 1. Overview & Architecture

**Nothing in the request path changes.** A Pro/Agency workspace stores rows in `retargeting_pixels`
(`provider`, `pixel_id`); `build_pixels()` snapshots the applicable rows into each QR's KV value under the
top-level `pixels` array; on a scan the Worker renders the landing page and, if the scanner has marketing
consent, calls `injectPixelsIntoResponse()` which emits a hardcoded per-provider snippet. For
`provider: 'google'` that snippet is `gtag.js` + `gtag('config', '<ID>')` — which is **exactly** the GA4
install. A `G-XXXXXXXXXX` Measurement ID therefore already works end to end today.

**Verified in code (this is the whole premise, so it is cited, not asserted):**

| Claim | Evidence |
|---|---|
| Backend accepts `G-` IDs | `qr_backend/src/api/routes/pixels.py:33` — `_GOOGLE_RE = re.compile(r"^(AW\|G\|GT\|UA)-[A-Z0-9][A-Z0-9\-]*$")`, applied at L74–82 after `.upper()` normalisation |
| Edge re-check accepts `G-` IDs | `qr_cf_code/src/utils/pixels.js:24` — `google: /^(AW\|G\|GT\|UA)-[A-Z0-9][A-Z0-9-]*$/`, with an explicit comment (L21–23) that the edge must be **at least as permissive** as the backend |
| Edge emits the GA4 install | `pixels.js:66–74` — `googleSnippet()` → `<script async src="https://www.googletagmanager.com/gtag/js?id=${safeId}">` + `gtag('js', new Date()); gtag('config','${safeId}')` |
| GA4 IDs already under test | `qr_cf_code/src/utils/pixels.test.mjs:68` (`G-ABCDEF1234` survives validation), L90, L129 |
| Injection is consent-gated | `qr_cf_code/src/index.js:427–431` — `hasPixels && marketingConsentGranted(request)` → `injectPixelsIntoResponse` |
| `GTM-` is already rejected | Regex trace: `GTM-ABC123` matches neither `G-` (next char is `T`, not `-`) nor `GT-` (next char is `M`, not `-`). Confirmed by executing both patterns against `GTM-ABC123` / `GTM-5XYZ` → **no match**, while `G-ABCDEF1234`, `AW-123456789`, `GT-XYZ123`, `UA-123456-1` all match. |

So the delta is: **make the product say what the code already does.** The design principle for the whole
change is **derive, don't store** — the GA4 / Google Ads / Universal Analytics distinction is computed from
the `pixel_id` prefix at render time in the frontend. That single choice is why there is no migration, no
backfill, no `resync_workspace_qrs` sweep, and no KV rewrite.

**Services touched**

| Service | Change |
|---|---|
| `qr_frontend` | All substantive work, and all of it presentational. One new pure helper `googleTagKind(pixelId)` → `'ga4' \| 'ads' \| 'ua'`; a shared `tagDisplayLabel(provider, pixelId)` consumed by `PixelRow.tsx` and `pixel-selector.tsx`; a three-option provider picker in `PixelsSection.tsx` that still submits two stored values; reworded headers/hints/upgrade copy in `PixelsSection.tsx`, `pixel-selector.tsx`, `QRDesign.tsx`, `settings/page.tsx`; one new row in `PricingComparisonTable.tsx` + `PricingCards.tsx`. **No hook change, no type change, no API-shape change.** |
| `qr_backend` | **One string:** the Google branch's 400 detail in `_clean_pixel` (`pixels.py:80`) becomes GA4-specific and explains the GTM rejection. Plus one added test asserting `GTM-…` → 400. **`_GOOGLE_RE` itself is NOT modified.** |
| `qr_cf_code` | **Comment + test only.** Extend the `pixels.js` header comment (L1–13) and the `googleSnippet` docstring (L62–65) to record that `google` covers GA4 Measurement IDs / Google Tag / Google Ads, and that GTM containers are *intentionally* unsupported. Add a `pixels.test.mjs` case pinning `GTM-` rejection. **`PIXEL_RE`, `googleSnippet`, `injectPixels`, `injectPixelsIntoResponse` and `index.js` are untouched** → the deployed edge behaviour is identical, so **no `deploy:prod` gate**. |

**Data flow — configuring a GA4 tag (unchanged except for labels)**

```
Settings → "Tracking & Analytics" tab (canAccessFeature(sub,'retargeting_pixels') — unchanged)
  → picker option "Google Analytics 4"  ──┐  both submit provider:'google'
    picker option "Google Ads"         ──┘  (picker only swaps placeholder + hint text)
  → useAddPixel → authApi POST /workspaces/{id}/pixels { provider:'google', pixel_id:'G-XXXXXXXXXX' }
  → pixels.py create_pixel → _require_retargeting (Pro+) → _clean_pixel (regex UNCHANGED; 400 copy new)
  → INSERT retargeting_pixels(provider='google', pixel_id='G-XXXXXXXXXX')
  → BackgroundTasks: resync_workspace_qrs → sync_qr_to_kv → write_to_kv(pixels=build_pixels(...))
  → KV: { ..., "pixels": [{"provider":"google","pixel_id":"G-XXXXXXXXXX"}] }        ← IDENTICAL to today
  → list view renders label via tagDisplayLabel('google','G-…') → "Google Analytics 4"   ← the only delta
```

**Data flow — a scan (byte-for-byte unchanged)**

```
GET /:shortCode → KV lookup → … → handleQRCode() renders HTML
  → hasPixels && marketingConsentGranted(request)          [index.js:427-428 — NOT MODIFIED]
      → injectPixelsIntoResponse(resp, parsedData.pixels)  [pixels.js:134 — NOT MODIFIED]
          → googleSnippet('G-XXXXXXXXXX') → gtag.js + gtag('config', …)
  → injectConsentIntoResponse(..., { hasMarketingTags: true, brand })
```

A scanner cannot observe that this feature shipped. That is the acceptance bar, not a side effect.

---

## 2. Data Model & Migrations

**No migration. This is a deliberate, defended decision, not an omission.**

The three candidate schema changes and why each is rejected:

| Candidate | Why rejected |
|---|---|
| Add `'ga4'` to `provider` | `provider` is used as the **snippet-selector key** in both `build_pixels()` (passthrough) and `renderPixels()` (`pixels.js:91–93`, `pixel.provider === "meta" ? … : googleSnippet(…)`). Adding a third value means an edge change → a `deploy:prod` gate, a backfill of existing `google` rows, and a window where old Workers see an unknown provider (which `validatePixel` silently drops → **tags stop firing**). Enormous downside for a label. |
| Add a `purpose`/`kind` column | Redundant with the `pixel_id` prefix — a `G-` ID *is* GA4, definitionally. A column can drift from the ID; the prefix cannot. |
| Add a per-pixel `label`/`nickname` | Real feature (naming multiple tags), not this feature. Deferred; provisional slot **`0037`** if ever built. |

`retargeting_pixels` (from `0013_retargeting_pixels.sql`) stays exactly:
`id uuid PK · workspace_id uuid FK · provider text · pixel_id text · is_active boolean · created_at
timestamptz`, with `idx_retargeting_ws ON (workspace_id) WHERE is_active`. Note `provider` has **no CHECK
constraint and no enum** — validation is application-side in `_clean_pixel` (`pixels.py:52–84`) and
re-checked at the edge in `validatePixel` (`pixels.js:31–38`). Nothing here needs to change for a label.

`qr_codes.retargeting_mode` / `qr_codes.pixel_ids` (from `0031_per_qr_retargeting.sql`, with the
`qr_codes_retargeting_mode_chk` CHECK) are untouched. `plans.features` is untouched — **no seed, no
`jsonb_set`, no `'{...}'::jsonb` blob, so `test_feature_gate_coverage` has no new surface** and cannot
regress on this change.

**KV values are not rewritten.** No `resync_workspace_qrs` call is introduced. A workspace that touches
nothing after this ships keeps byte-identical KV entries — which is the cheapest possible proof that the
scan path is unaffected.

---

## 3. Backend Design

### 3.1 The single code change — `qr_backend/src/api/routes/pixels.py`

`_clean_pixel`'s Google branch (L74–82) keeps its regex and its `.upper()` normalisation. **Only the 400
detail string changes.** Today (L80):

```python
detail="Google pixel_id must match (AW|G|GT|UA)-<alphanumeric>, e.g. AW-12345 or G-ABC123.",
```

That names neither GA4 nor the most common failure (pasting a GTM container). Replace with a message that
names the artefact the user is holding, and special-cases `GTM-`:

```python
elif provider == "google":
    pixel_id_upper = pixel_id.upper()
    if not _GOOGLE_RE.match(pixel_id_upper):
        # Most common paste error: a GTM container ID. Name it explicitly —
        # GTM containers are deliberately unsupported (arbitrary remote JS on a
        # page we host); the user wants the GA4 Measurement ID inside it.
        if pixel_id_upper.startswith("GTM-"):
            raise HTTPException(
                status_code=400,
                detail=(
                    "Google Tag Manager containers aren't supported. Paste your GA4 "
                    "Measurement ID instead — GA4 → Admin → Data Streams (starts with 'G-')."
                ),
            )
        raise HTTPException(
            status_code=400,
            detail=(
                "Enter a Google Analytics 4 Measurement ID (G-XXXXXXXXXX) or a Google Ads "
                "tag ID (AW-XXXXXXXXX)."
            ),
        )
    pixel_id = pixel_id_upper
```

The `GTM-` branch is **copy only** — it fires strictly inside the existing `not _GOOGLE_RE.match(...)`
failure path, so it cannot change which IDs are accepted. Both branches remain `400`.

### 3.2 What is explicitly NOT changed in the backend

- **`_GOOGLE_RE` (L33) is not touched.** Tightening it (e.g. dropping the dead `UA-`) would be a real
  behaviour change, would invalidate stored rows on the next write, and per PRD R5 must be
  **backend-only** if ever done — the edge re-check is intentionally at least as permissive
  (`pixels.js:21–23`), and making the edge stricter than the backend would silently stop already-stored
  IDs from firing. Out of scope here.
- **`_VALID_PROVIDERS` (L35) is not touched** — still `{"meta", "google"}`.
- **`_require_retargeting` / `check_feature(..., "retargeting_pixels", ...)` (L87–92) is not touched** —
  same Pro+ gate, same 403.
- **`FEATURE_ENFORCEMENT["retargeting_pixels"]` (`subscription.py:551`) is not touched.** No flag added,
  none renamed, no `_QUOTA_SPEC` entry — so `test_feature_gate_coverage` sees zero new keys.
- **`build_pixels()` (`cloudflare_kv.py:198–259`) is not touched**, including the `qr_type == "website"`
  short-circuit (L219–220) that is the reason GA4 cannot fire on redirect QRs. That constraint is
  surfaced in copy (§5.4), never worked around.
- **`write_to_kv` (`cloudflare_kv.py:64`, payload L107–110), `sync_qr_to_kv` (L382), and
  `resync_workspace_qrs` (L262) are not touched**, and none is newly invoked.
- **`qr.py` per-QR fields** (models L879–882 / L901–903, create default L1608–1611, `build_pixels` call
  sites L2265 / L2574 / L3325) are not touched. New QRs still default `retargeting_mode='off'`.

### 3.3 API surface

Unchanged. `GET/POST/DELETE /api/v1/workspaces/{workspace_id}/pixels` keep their paths, their
`PixelCreate` / `PixelResponse` schemas (`pixels.py:39–48`), their `require_workspace_role` dependencies,
and their status codes. `provider` remains `'meta' | 'google'` on the wire — a client sending `'ga4'`
would (correctly) still get a 400.

---

## 4. Cloudflare Worker / Edge Design

**No logic change. No `wrangler.toml` change. No new route, KV key, page, template, handler, or cron.
`npm run deploy:prod` is NOT required for this feature to be complete** — the two edits below are a comment
and a test, and can ride any subsequent routine deploy.

**4.1 Header-comment tweak — `qr_cf_code/src/utils/pixels.js:1–13.`** The file currently opens
*"Retargeting pixel injection for scan landing pages"* and says *"Only Meta and Google are supported in
v1."* That comment is the reason the capability got mislabelled everywhere downstream. It should record
what `google` actually covers and why GTM is out:

```js
/**
 * Tracking & analytics tag injection for scan landing pages.
 *
 * Tags are stored in the KV value under the top-level `pixels` array:
 *   [{ provider: "meta" | "google", pixel_id: "..." }]
 *
 * `google` covers BOTH measurement and advertising, distinguished only by the ID
 * prefix — the emitted gtag.js snippet is identical for all of them:
 *   G-…  / GT-… → Google Analytics 4 / Google Tag   (the GA4 install)
 *   AW-…        → Google Ads conversion / remarketing
 *   UA-…        → Universal Analytics (retired by Google in 2023; still accepted
 *                 so previously-stored rows keep validating — never tighten the
 *                 EDGE regex ahead of the backend, see below)
 *
 * GTM-… (Google Tag Manager containers) are DELIBERATELY rejected and must stay
 * rejected: a container is arbitrary, mutable, remote JS executing on a page we
 * host for our scanners — unvalidatable at write time (contents change after we
 * check the ID) and an XSS / malvertising / consent-mode liability. Users paste
 * the GA4 Measurement ID from inside the container instead.
 *
 * GA4 is analytics, but it still sets _ga/_ga_* cookies, so injection stays gated
 * on marketingConsentGranted(request) in index.js — non-EU fires freely, EU
 * requires an explicit grant. Do NOT exempt "analytics" tags from that gate.
 */
```

The `PIXEL_RE.google` comment (L20–23) already documents the edge-must-be-at-least-as-permissive rule —
**leave it exactly as is**; it is load-bearing.

**4.2 `googleSnippet` docstring (L62–65)** gains one line noting the snippet *is* the standard GA4 install
for a `G-` ID. Function body unchanged.

**4.3 Consent gate — a hard no-touch.** `index.js:427–431` stays exactly:

```js
const hasPixels = Array.isArray(parsedData.pixels) && parsedData.pixels.length > 0;
if (hasPixels && marketingConsentGranted(request)) {
  pageResp = await injectPixelsIntoResponse(pageResp, parsedData.pixels);
}
return injectConsentIntoResponse(pageResp, request, { hasMarketingTags: hasPixels, brand });
```

Any diff to these lines means the relabel became a behaviour change and must be rejected in review (PRD
R1). `hasMarketingTags` stays `true` for GA4-only tags: an EU scanner must still see the strip.

---

## 5. Frontend Design

All of the substantive work, and every line of it presentational. House rules apply: shadcn primitives
only, Tailwind tokens only (no inline styles), no `any`, ≤200 lines per file, kebab-case filenames, one
export per file.

### 5.1 The derived-label helper (the one piece of new logic)

A tiny pure module — e.g. `qr_frontend/src/lib/tag-labels.ts` (≤40 lines, no React, no I/O):

```ts
import type { Pixel } from '@/hooks/usePixels';

export type GoogleTagKind = 'ga4' | 'ads' | 'ua';

/** Classify a Google tag ID by prefix. IDs are stored uppercase by the backend. */
export function googleTagKind(pixelId: string): GoogleTagKind {
  const id = (pixelId ?? '').toUpperCase();
  if (id.startsWith('AW-')) return 'ads';
  if (id.startsWith('UA-')) return 'ua';
  return 'ga4';                      // G- and GT- ; also the safe default
}

/** Human label for a stored tag. Derived — never persisted. */
export function tagDisplayLabel(provider: Pixel['provider'], pixelId: string): string {
  if (provider === 'meta') return 'Meta Pixel';
  return { ga4: 'Google Analytics 4', ads: 'Google Ads', ua: 'Universal Analytics' }[
    googleTagKind(pixelId)
  ];
}
```

Notes that matter: IDs are already uppercased server-side (`pixels.py:82`) but we re-normalise so the
helper is correct on any input; `'ga4'` is the **default** branch so an unrecognised-but-valid future
Google prefix reads as analytics rather than crashing or showing blank. `UA-` rows additionally render a
muted "retired by Google" hint at the call site (not baked into the label string).

### 5.2 `PixelRow.tsx` — replace the two-key map

The hardcoded `PROVIDER_LABEL` (L7–10) is deleted in favour of `tagDisplayLabel(pixel.provider,
pixel.pixel_id)`. The `UA-` case appends a muted `text-xs text-slate-400` "retired by Google" note beside
the mono ID. Layout, delete button, and props are unchanged.

### 5.3 `pixel-selector.tsx` — same labels in the builder

Its own `PROVIDER_LABEL` (L35–38) is likewise replaced by `tagDisplayLabel` so the per-QR checklist
(L126–141) names tags identically to Settings. `MODE_OPTIONS` (L29–33: `None` / `All workspace pixels` /
`Specific`) and the three-way mode behaviour are **unchanged** — `0031` semantics stand. The non-entitled
hint (L72–78) is reworded to *"Send this QR's landing-page traffic to Google Analytics 4, or fire Meta /
Google Ads tags."* with the same `Upgrade to Pro` link.

### 5.4 `PixelsSection.tsx` — the discovery surface

- **Header** (L70–72): "Retargeting pixels" → **"Tracking & analytics tags"**; sub-line → *"Send scan-page
  traffic to Google Analytics 4, or fire Meta / Google Ads tags"*.
- **Upgrade card** (L41–45): title → *"Tracking & Analytics — Pro / Agency"*; body names both jobs
  (GA4 measurement **and** Meta/Ads remarketing). CTA unchanged.
- **Provider picker** (L89–97): three `SelectItem`s over **two stored values** — a local
  `type PickerChoice = 'meta' | 'google-ga4' | 'google-ads'` in component state, mapped to
  `provider: 'meta' | 'google'` at submit. `handleAdd` (L53–59) changes only in that it derives `provider`
  from the choice; the `useAddPixel` payload shape is untouched.
- **Format hints** (`FORMAT_HINTS`, L16–19) keyed by `PickerChoice` instead of provider:
  ```ts
  const FORMAT_HINTS: Record<PickerChoice, string> = {
    meta: '15–16 digits, e.g. 123456789012345',
    'google-ga4': 'G-XXXXXXXXXX — your GA4 Measurement ID (Admin → Data Streams)',
    'google-ads': 'AW-XXXXXXXXX — your Google Ads conversion/tag ID',
  };
  ```
  These strings feed both the `placeholder` (L102) and the helper `<p>` (L106); no structural change.
- **Info box** (L76–83) keeps its three existing bullets verbatim and gains two (PRD §6.5): the GA4
  Measurement-ID-not-GTM-container line, and the "what you'll see in GA4 is a standard `page_view`" line.
  This is where the honesty about limits lives, *before* configuration.

The file is 141 lines; the `PickerChoice` mapping and two bullets keep it well under 200. If it drifts
over, extract the add-tag form into its own component rather than trimming the copy.

### 5.5 `QRDesign.tsx` and the Settings tab

- `QRDesign.tsx` (~L654–690): accordion `<h2>` "Retargeting pixels" → **"Tracking & analytics tags"**; the
  `value="retargeting-pixels"` accordion key, the step-5 numbering, the collapsed summary (~L670–675), the
  `hasLandingPage(qrType)` guard (`lib/constants/qr-types.ts:91`), and the `PixelSelector` props are all
  unchanged. **Do not rename the accordion `value`** — it is state, not copy.
- `settings/page.tsx`: tab label `'Pixels'` → `'Tracking & Analytics'` (L46). The `Section` union member
  (L25) and `showPixels` gate (L41) keep their identifiers — renaming them is churn with a deep-link risk.

### 5.6 Pricing surfaces

`PricingComparisonTable.tsx:49` gains a row above/below the existing one, driven by the **same** boolean
(they are the same entitlement — an inconsistent second source would be a bug):

```ts
{ label: 'Google Analytics 4 (GA4)', values: map((p) => !!p.features.retargeting_pixels) },
{ label: 'Retargeting Pixels',       values: map((p) => !!p.features.retargeting_pixels) },
```

`PricingCards.tsx:306` gets the matching `<BoolRow label="Google Analytics 4" yes={!!f.retargeting_pixels} />`.
`lib/constants/pricing.ts` is **unchanged** — no new key; both rows read `retargeting_pixels`.

### 5.7 Hooks, types, state — all unchanged

`usePixels.ts` (`Pixel.provider: 'meta' | 'google'`, `AddPixelPayload`, the three hooks, the `pixelKeys`
factory) is untouched. `lib/types/qr.ts` (`retargeting_mode` / `pixel_ids`, L629–631, L701) is untouched.
`build/page.tsx` (L113, L357–358, L646) and `qr-design-tab.tsx` (L27–28, L65, L109) are untouched. No new
hook, no new query key, no new TanStack invalidation.

---

## 6. External-Service Integration

**None added.** No AI/Anthropic call, no Resend/email, no payment provider, no PDF, no new SDK, no new
environment variable and no new secret. The only third-party code involved is the `gtag.js` loaded **in
the scanner's browser** from `googletagmanager.com`, exactly as it is today — we neither add nor change an
outbound server-side call.

Notably **not** integrated (and deliberately so): the **GA4 Measurement Protocol**. Server-side hits would
be the only way to report `website`-type redirect scans into a tenant's GA4 property, but it means holding
a tenant `api_secret`, minting `client_id`s, and taking on a fresh consent/PII surface at the edge — a
separate feature with its own PRD, not a relabel. `_dmarc.qravio.app` is not a gate (no email).

---

## 7. API Contracts

**No contract changes.** Documented here only to pin what must stay identical.

```jsonc
// POST /api/v1/workspaces/{workspace_id}/pixels   — unchanged shape
{ "provider": "google", "pixel_id": "G-XXXXXXXXXX" }   // GA4 → stored provider is 'google'
{ "provider": "google", "pixel_id": "AW-123456789" }   // Google Ads → same stored provider
{ "provider": "meta",   "pixel_id": "123456789012345" }

// 201 — unchanged
{ "id": "uuid", "provider": "google", "pixel_id": "G-XXXXXXXXXX", "is_active": true }

// 400 — NEW COPY ONLY, same status, same trigger set
{ "detail": "Google Tag Manager containers aren't supported. Paste your GA4 Measurement ID instead — GA4 → Admin → Data Streams (starts with 'G-')." }
{ "detail": "Enter a Google Analytics 4 Measurement ID (G-XXXXXXXXXX) or a Google Ads tag ID (AW-XXXXXXXXX)." }

// 403 — unchanged (Pro+ gate)
{ "detail": "Retargeting pixels require a Pro or Agency plan." }
```

The KV value is **unchanged**, and this is the contract that most matters:

```jsonc
{ /* ...existing... */
  "pixels": [{ "provider": "google", "pixel_id": "G-XXXXXXXXXX" }] }
```

An older deployed Worker reading a KV entry written after this change sees the same bytes it sees today —
which is why deploy ordering is a non-issue (§11).

---

## 8. Security, Privacy & Abuse

- **The GTM rejection is the security decision of this spec.** A GTM container ID would let a tenant load
  arbitrary, *mutable*, remote JavaScript onto a page we serve from our hostname to third-party scanners.
  It cannot be validated at write time (the container's contents change after we check the ID), it defeats
  the entire reason `renderPixels` uses hardcoded per-provider snippet templates
  (`pixels.js:44–74`) instead of user-supplied HTML, and it hands us DPDP/ePrivacy consent-mode liability
  for code we don't control. Both regexes reject `GTM-` today; §10 adds tests so it stays that way.
- **No new injection surface.** `pixel_id` continues to be regex-validated at write time (`pixels.py:74–82`),
  re-validated at the edge (`pixels.js:31–38`), and `escapeHTML`-escaped before interpolation
  (`pixels.js:46`, L67) — defence in depth we are neither adding to nor weakening. The relabel touches no
  interpolation path.
- **Consent posture unchanged, and that is deliberate.** GA4 sets `_ga`/`_ga_*` first-party cookies and is
  consent-requiring under ePrivacy Art. 5(3) in EU/EEA/UK. Injection stays behind
  `marketingConsentGranted()` and `hasMarketingTags` stays `true` for a GA4-only page so EU scanners still
  get the strip. **Calling a tag "analytics" is not a legal basis** — any future PR that moves GA4 outside
  that gate is a different, much larger change and must be blocked at review (PRD R1).
- **Tenant isolation unchanged.** Pixels are workspace-scoped (`workspace_id` filters in
  `list_pixels`/`delete_pixel`, `pixels.py:104–107`, L151) and snapshotted per-QR by `build_pixels()`; the
  service-role client bypasses RLS, so isolation is code-enforced, as before.
- **PII:** none added. We store a provider string and a tag ID; scan-page visitor data flows from the
  scanner's browser to Google under the tenant's own GA4 property and their own privacy notice — our
  posture (and our consent strip) is what it was.
- **Public-copy consistency check (PRD R6):** `qr_frontend/src/app/(marketing)/cookies/page.tsx:152–155`
  states *"We do not use Google Analytics…"*. That covers **Qravio's own** site/dashboard and stays true;
  a **tenant's** GA4 tag on a **tenant's** scan page is a distinct surface with its own consent gate. Have
  whoever owns legal copy confirm the two read as distinguishable, and add a one-line clarifier if not.
- **Abuse:** no new unauthenticated surface, no per-use cost, no quota to exhaust. The endpoints remain
  Bearer-authed and `require_workspace_role`-gated.

---

## 9. Performance, Scale & Cost

- **Edge:** zero delta. Same number of KV reads, same snippet bytes, same `injectPixelsIntoResponse` call.
  Scan-path CPU and latency are unchanged because the code is unchanged.
- **Backend:** zero delta. No new query, no new RPC, no new background task. Critically, **no
  `resync_workspace_qrs` sweep is triggered** — that function re-syncs *every* QR in a workspace
  (`cloudflare_kv.py:262–281`) and is the one thing in this area with real cost. A relabel must never
  invoke it.
- **Frontend:** two tiny pure functions called per rendered row; unmeasurable. No new network request, no
  new query key, no new render loop.
- **DB:** no schema change, no index, no backfill, no migration downtime.
- **Cost:** ₹0 marginal. No AI, no metered call, no storage growth.

The only "performance" risk in this spec would be accidentally introducing a resync or an extra query
while editing display code — called out here so review looks for it.

---

## 10. Testing Strategy

The tests exist to prove a **negative** (nothing behaved differently) and to pin two invariants.

**Backend (pytest, `qr_backend/tests/unit_tests/test_retargeting_pixels.py` — 362 lines, extend it):**
- `test_gtm_container_rejected` (**NEW, the important one**): `_clean_pixel("google", "GTM-ABC123")` raises
  `HTTPException` 400, and the detail names GA4 as the alternative. Parametrised over
  `GTM-ABC123` / `gtm-abc123` / `GTM-5XYZ` so case-normalisation can't smuggle one through.
- `test_ga4_measurement_id_accepted` (**NEW**): `_clean_pixel("google", "g-abcdef1234")` returns
  `("google", "G-ABCDEF1234")` — asserts both acceptance and the uppercase normalisation.
- **Regex-unchanged regression:** the existing valid/invalid `pixel_id` cases must pass **without
  modification**. If any existing assertion needs editing, the change stopped being a relabel — stop and
  escalate. This is the review tripwire.
- Existing `build_pixels` cases (website → `[]`, unentitled → `[]`, mode `off`/`select`/`inherit`) and the
  403/404 cases are untouched and must stay green.
- **`test_feature_gate_coverage` must stay green trivially** — no flag added or renamed, so it has no new
  surface.

**Worker (`qr_cf_code/src/utils/pixels.test.mjs` — 151 lines, extend it):**
- `renderPixels` with `{provider:'google', pixel_id:'GTM-ABC123'}` → **`{head:'', body:''}`** (silently
  dropped by `validatePixel`). Pins the edge half of the GTM rejection.
- The existing GA4 assertions (L68 `G-ABCDEF1234` valid, L90 injected before `</head>`, L129 injected via
  `injectPixelsIntoResponse`) stay **unmodified** — same tripwire rule as the backend.
- Add an explicit `gtag/js?id=G-…` + `gtag('config','G-…')` assertion for a `G-` ID so the GA4 install
  shape (not just ID survival) is pinned, mirroring the existing `AW-` assertions at L33–37.
- **No test may be added for `index.js` consent behaviour changing** — because it doesn't.

**Frontend (Vitest):**
- `tag-labels.test.ts` (**NEW**): `tagDisplayLabel` → `'Google Analytics 4'` for `G-`/`GT-`/lowercase
  `g-`; `'Google Ads'` for `AW-`; `'Universal Analytics'` for `UA-`; `'Meta Pixel'` for `provider:'meta'`
  regardless of ID; unknown-but-valid Google prefix defaults to GA4, not blank/throw.
- `PixelsSection`: selecting "Google Analytics 4" then "Google Ads" swaps the hint text but **both submit
  `provider:'google'`** — asserted on the `useAddPixel` mutation payload. This is the test that guarantees
  the three-option picker stays cosmetic.
- `PixelRow` / `PixelSelector`: an `AW-` fixture renders "Google Ads" (never "Analytics") — PRD R4; a `UA-`
  fixture shows the retired hint.
- **Baseline caveat:** the FE suite carries ~29 pre-existing failures; only net-new failures in
  `pixel*`/`tag-labels`/`pricing` files count as regressions.

**Manual verification (5 minutes, and worth doing):**
Configure a real `G-` Measurement ID on a staging vCard QR → scan from a non-EU IP → confirm a realtime hit
lands in the GA4 property; scan from an EU IP → confirm **no** hit until the consent strip is accepted.
Then diff the QR's KV value against a pre-change capture — it must be **identical**.

---

## 11. Observability & Rollout

**Phase 0 — one PR, no flag.** FE copy + `tag-labels.ts` + picker mapping + `PixelRow`/`PixelSelector`
labels + `QRDesign`/`settings` titles + pricing rows + the `pixels.py` 400 copy + the `pixels.js` comment +
all tests. There is nothing to beta because nothing behaves differently; a feature flag on a string change
is ceremony. Review as a single diff so "no behaviour change" is verifiable in one pass.

**Reviewer checklist (the actual quality gate for this spec):**
1. `pixels.py:33` `_GOOGLE_RE` — **unchanged**?
2. `pixels.js` `PIXEL_RE` / `googleSnippet` / `injectPixels` / `injectPixelsIntoResponse` bodies —
   **unchanged**?
3. `index.js:427–431` consent gate — **unchanged**?
4. `cloudflare_kv.py` — no diff at all, and **no new `resync_workspace_qrs` call**?
5. `subscription.py` — no diff?
6. `migrations/` — **no new file**?
7. Any pre-existing test assertion **edited** rather than added? → escalate.

**Phase 1 — docs + comparison surfaces.** Help-centre article ("Send QR scan-page traffic to your GA4
property"), including the Website-redirect and consent limitations verbatim from the info box; sales
battlecard line; mark gap-analysis item #8 done
(`docs-internal/competitive-feature-gap-analysis.md:157–162`).

**Phase 2 — watch.** Track new `retargeting_pixels` rows with `provider='google'` and a `G-`/`GT-` prefix
for 60 days against the ≥ 2× target (a one-off SQL count, no dashboard build). If the number doesn't move,
the problem was never the label and Open Q1/Q5 (tier, SEO page) get revisited.

**Deploy order — genuinely unconstrained.** Backend and frontend ship in any order (a 400-message string
and a hint string are independent). **No `npm run deploy:prod`** — the Worker diff is a comment and a test;
the deployed edge is already correct. **No migration**, so no Supabase SQL-editor step and no
migration-before-deploy rule. **No DMARC gate** (no email). **No cron gate.**

**Metrics / logs:** no new logging. Existing structured Worker logs and the `retargeting_pixels` table
carry everything needed; adding telemetry for a relabel would cost more than the relabel.

---

## 12. Open Technical Questions & Risks

1. **Derive vs store the GA4/Ads distinction** — **resolved: derive** from the `pixel_id` prefix in the
   frontend. Storing it (new `provider` value or a `kind` column) means a migration, a backfill, an edge
   change with a `deploy:prod` gate, and a rollout window where an older Worker drops an unknown provider
   and **stops firing tags**. Derivation has none of that and cannot drift from the ID.
2. **Consent gate must not move (PRD R1)** — **resolved: no change**, and recorded in the `pixels.js`
   comment so the reasoning survives the next refactor. GA4 sets `_ga` cookies; "analytics" is not an
   exemption. Explicitly flag this to eng-review as the one way this change could turn harmful.
3. **`UA-` still accepted although Universal Analytics is retired** — **resolved: keep accepting**, label
   as retired. If ever tightened: **backend-only**, never the edge — `pixels.js:21–23` documents that the
   edge re-check must stay at least as permissive as the backend, and an edge-first tightening would
   silently dark already-stored IDs.
4. **Three-option picker over two stored values** — confirm at build that `handleAdd`
   (`PixelsSection.tsx:53–59`) maps `'google-ga4' | 'google-ads' → 'google'` and that **no** `'ga4'` string
   can reach the API (a client sending it gets a correct 400 from `_VALID_PROVIDERS`, but the picker must
   never produce it). Covered by the payload test in §10.
5. **Should GA4 split off `retargeting_pixels` to a Starter tier (PRD Open Q1)?** Deferred. Note the shape
   if we ever do: it is a **flag** change, not a data change — `build_pixels()` would filter rows by ID
   prefix against two flags, stored rows stay valid, and the edge is still untouched. Not v1.
6. **`hasLandingPage` / `website` exclusion is permanent, not a bug** — `build_pixels()` returns `[]` for
   `qr_type == "website"` (`cloudflare_kv.py:219–220`) because a 302 renders no HTML of ours. The only fix
   is the server-side Measurement Protocol (§6), which is a different feature. v1 states the limit in
   product copy; anyone who reads the relabel as a promise to cover redirect scans has misread it.
7. **Scope discipline** — the failure mode for this spec is not a bug, it's growth: "while we're in here,
   let's add GTM / custom events / Consent Mode / LinkedIn." Each is separately specced or permanently
   skipped (PRD §3, §7). If the diff touches a regex, a snippet body, or `index.js`, it is no longer this
   feature.

### Appendix — Key Files

| Concern | File |
|---|---|
| Backend 400 copy (**only backend code change**) | `qr_backend/src/api/routes/pixels.py` (Google branch L74–82, message L80) |
| Backend validator (**must stay unchanged**) | `qr_backend/src/api/routes/pixels.py` (`_GOOGLE_RE` L33, `_VALID_PROVIDERS` L35, `_clean_pixel` L52–84) |
| Entitlement gate (**unchanged**) | `qr_backend/src/api/routes/subscription.py` (`FEATURE_ENFORCEMENT["retargeting_pixels"]` L551); `pixels.py:87–92` `_require_retargeting` |
| KV snapshot (**unchanged, and must not be resynced**) | `qr_backend/src/utilities/cloudflare_kv.py` (`write_to_kv` L64 / payload L107–110, `build_pixels` L198–259, website short-circuit L219–220, `sync_qr_to_kv` L382, `resync_workspace_qrs` L262) |
| Per-QR mode plumbing (**unchanged**) | `qr_backend/src/api/routes/qr.py` (models L879–882 / L901–903, create default L1608–1611, `build_pixels` calls L2265 / L2574 / L3325) |
| Worker comment tweak (**no logic**) | `qr_cf_code/src/utils/pixels.js` (header L1–13, `PIXEL_RE` L18–25 *unchanged*, `googleSnippet` L62–74) |
| Worker injection + consent (**hard no-touch**) | `qr_cf_code/src/index.js` (L422–431); `qr_cf_code/src/utils/consent.js` (`marketingConsentGranted`) |
| Derived-label helper (NEW) | `qr_frontend/src/lib/tag-labels.ts` (`googleTagKind`, `tagDisplayLabel` — pure, ≤40 lines) |
| Settings copy + picker | `qr_frontend/src/components/org/settings/PixelsSection.tsx` (`FORMAT_HINTS` L16–19, upgrade card L41–45, `handleAdd` L53–59, header L70–72, info box L76–83, Select L89–97) |
| Tag-row label | `qr_frontend/src/components/org/settings/PixelRow.tsx` (`PROVIDER_LABEL` L7–10 → `tagDisplayLabel`) |
| Builder selector label + hint | `qr_frontend/src/components/qr-generator/pixel-selector.tsx` (`MODE_OPTIONS` L29–33 *unchanged*, `PROVIDER_LABEL` L35–38, upgrade hint L72–78) |
| Builder accordion title | `qr_frontend/src/components/org/content-type/website/QRDesign.tsx` (~L654–690; keep `value="retargeting-pixels"`) |
| Settings tab label | `qr_frontend/src/app/[slug]/(dash)/settings/page.tsx` (`Section` union L25 *unchanged*, gate L41 *unchanged*, tab label L46) |
| Comparison matrix + cards | `qr_frontend/src/components/pricing/PricingComparisonTable.tsx` (L49), `PricingCards.tsx` (L306); `lib/constants/pricing.ts` **unchanged** |
| Hooks / types (**unchanged**) | `qr_frontend/src/hooks/usePixels.ts`; `qr_frontend/src/lib/types/qr.ts` (L629–631, L701) |
| Tests | `qr_backend/tests/unit_tests/test_retargeting_pixels.py` (+GTM/GA4 cases), `qr_cf_code/src/utils/pixels.test.mjs` (existing GA4 L68 / L90 / L129; +GTM-drop case), NEW `qr_frontend` `tag-labels.test.ts` |
| Legal-copy cross-check | `qr_frontend/src/app/(marketing)/cookies/page.tsx` (L152–155) |
| Migration | **None.** Provisional `0037` only if a per-pixel `label` column is ever added (highest on disk `0032`; `0033` claimed by QR_EXPIRY_SCHEDULING — re-verify at build time) |
