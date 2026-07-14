# TRD — Google Review Funnel QR (feedback-first)

**Status:** Draft · **Author:** Engineering (Staff) · **Date:** 2026-06-24
**Tiers:** **Starter, Pro, Agency** — gated exclusively by the existing `dynamic_qr_types` allow-list containing `"review_funnel"` (seeded by 0021). **No new boolean flag**, so `FEATURE_ENFORCEMENT` is untouched and `test_feature_gate_coverage` stays green by construction.
**Flags:** none new. The unhappy-arm feedback form is **bundled into the type**, not separately gated by `lead_forms` (deliberate packaging, §8).
**Migration slot:** `0021_google_review_funnel.sql` (0014–0018 = analytics roadmap; 0019–0020 reserved elsewhere; current DB highest applied = `0013_retargeting_pixels.sql`).
**Services touched:** `qr_backend` (new QR type pipeline + relaxed `/internal/lead-submit` reuse + migration), `qr_cf_code` (new `reviewFunnel/` page + `/review-go/:shortCode` route + rating-step submit reuse), `qr_frontend` (content-type form + React preview + picker cases + per-funnel analytics card).

**Rev (2026-06-24, post eng-review):** Fixed three verified-against-code gaps. (1) **Scan-field threading is a 3-point change, not automatic:** `scan.js:56–59` only whitelists `variant_key`/`destination_url`, `ScanEventPayload` drops unknown keys, and `record_scan_event` bare-inserts `payload.dict()` — so `stars`/`review_route` need the worker whitelist + Pydantic fields + two nullable `qr_scan_events` columns (now added in 0021, in-phase; the analytics card is dead otherwise). §4.2/§13/§2 updated. (2) **Denominator gap:** client-side routing meant only the Google branch recorded an event, leaving 1–3★ distribution + `routed_to_feedback` uncomputable — now BOTH branches record one event (feedback via a `sendBeacon`→204 on `/review-go?...&route=feedback`); §1/§4.2/§13 updated. (3) **KV shape kept FLAT** (not nested under `content.feedback`) so the existing worker `/lead-submit/` handler — which also reads `kvContent.redirect_url` (`:217`) and passes `kvContent` to the thanks page (`:220`), not just `fields` — works verbatim with zero changes; §3.4/§4.1/§4.3 updated. Also hardened R2 URL validation (https + parsed-host suffix match, drop `goo.gl`) and corrected `internal.py` line refs (`:782`/`:790`).

---

## 1. Overview & Architecture

`review_funnel` is a **new dynamic QR type** that composes six existing seams rather than inventing new infrastructure. On scan, the Worker renders a neutral **1–5 star rating step** entirely from KV (no backend round-trip on the hot path). When the scanner taps a star, edge routing decides the branch: **stars ≥ threshold → 302 to the merchant's Google review write-URL**; **stars < threshold → render a private feedback form** (the Lead Capture form arm), which POSTs to the existing `POST /internal/lead-submit` (consent, honeypot, IP rate-limit, validation, Resend owner-notify). The merchant gets more public 5-star reviews *and* a private early-warning channel — built **feedback-first** (every scanner reaches the same rating step; nobody is ever blocked from leaving a public Google review — §9 R1, a product invariant).

**Services & data flow:**

| Concern | qr_backend | qr_cf_code | qr_frontend |
|---|---|---|---|
| New type | Literal `review_funnel`; `build_kv_content` branch; `SELECT_WITH_RELATIONS` join + pydantic model + `_build_content_from_db_rows`; create/update upsert into `qr_review_funnel`; Google-URL validation at write; migration 0021 seed | `handlers/qrRouter.js` dispatch → `src/pages/reviewFunnel/`; rating template; `/review-go/:shortCode?stars=N` route in `src/index.js` | `content-types/review-funnel-form.tsx`; `templates/review-funnel/`; `TemplatePicker`/`PagePreview` cases |
| Negative arm | **Relax `/internal/lead-submit`** to accept `review_funnel` QRs (read feedback config from `qr_lead_forms`) — no new endpoint | reuse `/lead-submit/:shortCode` POST path (already reads `kvContent.fields`) | feedback surfaces in existing `LeadsClient` for free |
| Analytics | per-funnel aggregate from `qr_scan_events` + review-route events | `recordScan(...)` for the route-decision event (with `stars`) | Review Funnel card in `QRDetails.tsx` (conditional on `type === 'review_funnel'`) |

**Hot-path data flow:** `GET /:shortCode` → KV lookup → `handleQRCode` → `type === 'review_funnel'` → render rating step from `kvContent` (`escapeHTML` on all merchant copy). Star tap (client JS) → if `stars ≥ threshold`, navigate to `/review-go/:shortCode?stars=N` → Worker fires `ctx.waitUntil(recordScan(..., {review_route:'google', stars}))` then `302` to the **validated stored** Google URL (never user-supplied at scan time). If `stars < threshold`, the same page reveals the feedback form (no extra round-trip), which submits to `/lead-submit/:shortCode`.

**Denominator gap (must resolve — affects §7 contract):** with routing done client-side, only the *Google* branch hits `/review-go` and records a `stars` event; below-threshold star-taps reveal the form inline and record **nothing** unless the scanner completes the form. That leaves `star_distribution` for 1–3★ and `routed_to_feedback`/`feedback_started` with no event source — they'd be uncomputable. **Decision:** record the star choice for BOTH branches. The below-threshold tap fires a lightweight beacon — `navigator.sendBeacon("/review-go/<shortCode>?stars=N&route=feedback")` (or the same GET, which on `route=feedback` records the event via `ctx.waitUntil(recordScan(..., {review_route:"feedback", stars}))` and returns `204` instead of a 302). This keeps one route handler, gives every star-tap exactly one event row, and makes `star_distribution`/`routed_to_*`/`feedback_started` all derive from real `qr_scan_events` rows. `feedback_completed` still comes from `qr_lead_submissions`.

---

## 2. Data Model & Migrations

**File:** `qr_backend/migrations/0021_google_review_funnel.sql` — `BEGIN/COMMIT`-wrapped, idempotent (`IF NOT EXISTS`, `@>` guard), applied by hand in the Supabase SQL editor (no automated runner). All backend queries use the **service-role** Supabase client, which **bypasses RLS** — no policies are added; tenant isolation is enforced in route code via workspace resolution + `workspace_members` permission checks (§9). Ships **only this phase's schema** (no future-phase tables); the feedback-form config reuses the existing `qr_lead_forms` table (no new submissions table — submissions land in `qr_lead_submissions`, tagged by `qr_id`).

```sql
-- Migration 0021: Google Review Funnel QR (feedback-first).
-- New dynamic QR type `review_funnel`. Adds ONE detail table for the rating-step
-- config (review URL + threshold + prompt copy) and appends `review_funnel` to the
-- Starter/Pro/Agency `dynamic_qr_types` allow-list. The unhappy-scanner arm REUSES
-- qr_lead_forms (form config) + qr_lead_submissions (the rows) — no new tables there.
-- NO new boolean flag (gating is dynamic_qr_types membership) → no FEATURE_ENFORCEMENT row.
-- notify_email is NOT copied to KV — owner PII stays in qr_lead_forms (Lead Capture rule).
-- Idempotent; safe to re-run.
BEGIN;

-- ── Rating-step config (one row per review_funnel QR) ──────────────────────────
CREATE TABLE IF NOT EXISTS qr_review_funnel (
    qr_id            uuid        PRIMARY KEY REFERENCES qr_codes(id) ON DELETE CASCADE,
    google_review_url text       NOT NULL,                  -- validated Google write-URL (backend-checked)
    star_threshold   smallint    NOT NULL DEFAULT 4
                       CHECK (star_threshold BETWEEN 2 AND 5),
    rating_prompt    text,                                   -- "How was your visit?" (merchant copy)
    thank_you_message text,                                  -- post-feedback copy
    updated_at       timestamptz NOT NULL DEFAULT now()
);

-- ── Route-decision event columns + index (analytics denominator — R7) ──────────
-- Star distribution + route split are counted from qr_scan_events ROWS (not the
-- lossy qr_scan_counters JSONB). The route-go event must carry the chosen star
-- rating + which branch it took. These columns are NULL for every non-review scan
-- and are part of THIS phase's schema (the analytics card is dead without them —
-- ScanEventPayload + scan.js must also be widened to thread them; see §4.2).
ALTER TABLE qr_scan_events ADD COLUMN IF NOT EXISTS stars        smallint;
ALTER TABLE qr_scan_events ADD COLUMN IF NOT EXISTS review_route text;
-- Partial index keeps the per-funnel windowed aggregate cheap and excludes the
-- (vast) majority of rows that are not review-route events.
CREATE INDEX IF NOT EXISTS idx_scan_events_qr_time
    ON qr_scan_events (qr_id, scanned_at);
CREATE INDEX IF NOT EXISTS idx_scan_events_review_route
    ON qr_scan_events (qr_id, scanned_at)
    WHERE review_route IS NOT NULL;

-- ── Plan seed: append `review_funnel` to Starter/Pro/Agency dynamic_qr_types ────
-- HOUSE CONVENTION: parity-safe jsonb append (lower(name) + is_custom guard +
-- coalesce + @> idempotency guard). NO bare "WHERE name IN (...)".
UPDATE plans
SET features = jsonb_set(
        coalesce(features, '{}'::jsonb),
        '{dynamic_qr_types}',
        CASE
            WHEN coalesce(features->'dynamic_qr_types', '[]'::jsonb) @> '["review_funnel"]'::jsonb
                THEN features->'dynamic_qr_types'
            ELSE coalesce(features->'dynamic_qr_types', '[]'::jsonb) || '["review_funnel"]'::jsonb
        END,
        true)
WHERE lower(name) IN ('starter', 'pro', 'agency')
  AND coalesce(is_custom, false) = false;

COMMIT;
-- Sanity: SELECT name, features->'dynamic_qr_types' FROM plans
--         WHERE coalesce(is_custom,false)=false ORDER BY price_monthly;
```

**No `FEATURE_ENFORCEMENT` change.** Because gating is `dynamic_qr_types` membership (not a boolean flag), the `subscription.py` registry is untouched and the `test_feature_gate_coverage` parity test cannot break. This mirrors how `lead_form` was seeded by 0012 (verified precedent at `migrations/0012_lead_capture_forms.sql:60`), but **only the type-list append** — without the `lead_forms=true` flip, since review_funnel is Starter+ and not gated by `lead_forms`.

---

## 3. Backend Design (`qr_backend`)

### 3.1 New QR type — 7-step pipeline in `src/api/routes/qr.py`

1. **Literal value** (`qr.py:736`–760): append `"review_funnel"` to the `type` Literal list (after `"lead_form"`).
2. **`SELECT_WITH_RELATIONS`** (`qr.py:836`): append `, qr_review_funnel(*)` to the relation string. `qr_review_funnel.qr_id` is a PRIMARY KEY, so PostgREST embeds it as a **to-one** object — handle exactly like `qr_lead_forms` (`_lf_raw = row.pop(...)`, normalize dict→`[dict]`).
3. **Pydantic model + `_build_content_from_db_rows`** (`qr.py:880`+): add a `review_funnel: Optional[dict] = None` param to `_build_content_from_db_rows`, plus a `ReviewFunnelContent`-style block returning `{google_review_url, star_threshold, rating_prompt, thank_you_message}` and, **separately**, the bundled feedback-form config from the embedded `qr_lead_forms` row (`fields`, `success_message`). The create path also accepts a `lead_form` block (reusing the existing `LeadFormPayload`) for the feedback fields.
4. **`dynamic_qr_types` seed** — migration 0021 (§2).
5/6/7 — Worker + React (§5, §6).

**Create/update upsert** (`qr.py:1909`/`2774` pattern): after the `qr_codes` insert, upsert into `qr_review_funnel` keyed `on_conflict="qr_id"` (`google_review_url`, `star_threshold`, `rating_prompt`, `thank_you_message`), **and** upsert the feedback-form config into `qr_lead_forms` (`fields`, `success_message`, `notify_email`) — reusing the existing lead-form upsert at `qr.py:1909`/`2774`. Both writes precede `write_to_kv()` so KV carries fresh content.

**Google-URL validation (R2)** — backend-side, at write time. A helper `_validate_google_review_url(url)` requires `scheme == "https"` and allow-lists hosts by **exact match or proper-suffix** (parse with `urllib.parse`, compare `netloc.lower()` against `{"g.page", "maps.app.goo.gl", "search.google.com", "www.google.com", "google.com"}` and `*.google.com` via an explicit `host == "google.com" or host.endswith(".google.com")` check — never a bare substring `in`, which `evilgoogle.com.attacker.net` would pass). Reject any other host with `422 {"detail":"google_review_url must be a Google review link"}`. Note `maps.app.goo.gl`/`goo.gl` are Google shorteners that can 302 onward; we accept them because they are Google-operated, but the risk is a **client-side** redirect (phishing), not server-side SSRF — the Worker never fetches the target, it only emits a browser 302 to the stored, validated URL (never a scan-time parameter). Drop bare `goo.gl` from the list (deprecated, broadly abusable) unless a partner needs it.

### 3.2 Gating

The dynamic-type gate at `qr.py:1272` already enforces the per-plan `dynamic_qr_types` list; with the 0021 seed, Free 403s and Starter+ create successfully — **no code change** to the gate, and **no** `subscription.py` change. (The defensive `qrType == "lead_form"` check at `qr.py:1305` is left as-is; we do **not** add a `review_funnel`-specific feature check, because review_funnel is not a flag.) Routes keep `require_can_create`/`require_can_update` from `dependencies/permissions.py`.

### 3.3 Reuse `/internal/lead-submit` for the negative arm — the one seam to relax

The current `lead_submit` handler (`internal.py:736`) hard-rejects `type != "lead_form"` (verified at `internal.py:782`: `raise HTTPException(404, "QR code is not a lead form")`) **and** gates on `check_feature(workspace_id, "lead_forms")` (verified at `internal.py:790`). Both must be relaxed to admit `review_funnel`:

```python
ALLOWED_SUBMIT_TYPES = {"lead_form", "review_funnel"}
if qr_row.get("type") not in ALLOWED_SUBMIT_TYPES:
    raise HTTPException(404, detail="QR code does not accept submissions")
...
# Feature gate: lead_form needs the lead_forms flag; review_funnel is gated by
# its own dynamic_qr_types membership (already enforced at create), so the
# feedback arm is bundled and NOT separately gated by lead_forms (PRD §8/D1).
if qr_row.get("type") == "lead_form" and not await check_feature(workspace_id, "lead_forms", db):
    raise HTTPException(403, detail="Lead capture forms are not enabled on this workspace's plan.")
```

Everything else is **unchanged**: consent check, `qr_lead_forms.fields` validation, IP rate-limit (`max 10/IP/hr`, `ip_hash = sha256(ip+HASHING_SALT)`), `qr_lead_submissions` insert, best-effort Resend notify to `notify_email`. The endpoint stays under the `/internal/*` router guarded router-wide by `verify_internal_secret` (`x-internal-secret`) — no Bearer-middleware change, no new excluded route. **Optional submission ceiling (R4/D1):** keep the existing 10/IP/hr limit; revisit a per-funnel daily cap only if abuse appears.

### 3.4 KV content — `src/utilities/cloudflare_kv.py`

Add a `review_funnel` branch to `build_kv_content` (`cloudflare_kv.py:325`+), mirroring the `lead_form` branch (`:378`). It **fetches from two tables and merges them FLAT** (per §4.3 — do NOT nest under `content.feedback`, so the existing `/lead-submit/` handler's flat reads of `fields`/`redirect_url`/`success_message` work verbatim), and **must NOT include `notify_email`** (owner PII stays in `qr_lead_forms`). The `qr_review_funnel` keys and the `qr_lead_forms` keys do not collide, so a flat merge is unambiguous:

```python
elif qr_type == "review_funnel":
    rf = (supabase.table("qr_review_funnel")
          .select("google_review_url, star_threshold, rating_prompt, thank_you_message")
          .eq("qr_id", qr_id).maybe_single().execute())
    lf = (supabase.table("qr_lead_forms")
          .select("fields, success_message, redirect_url")  # NO notify_email
          .eq("qr_id", qr_id).maybe_single().execute())
    out = dict(rf.data) if rf and rf.data else {}
    # FLAT merge — fields/success_message/redirect_url sit at content.* exactly
    # like a lead_form, so the worker /lead-submit/ handler needs ZERO changes.
    out.update(dict(lf.data) if lf and lf.data else {"fields": []})
    return out
```
Note: each `.maybe_single().execute()` is its own call — handle a missing `qr_lead_forms` row (funnel created without a feedback form) by defaulting `fields` to `[]`, so the rating step still renders.

No `build_entitlements`/`build_pixels` change — review_funnel introduces no edge-enforced boolean (it is gated at create time, not scan time). No `write_to_kv` field-shape change beyond the new `content` payload above.

---

## 4. Cloudflare Worker / Edge Design (`qr_cf_code`)

### 4.1 Dispatch + rating page

`src/handlers/qrRouter.js`: add a `type === "review_funnel"` branch (peer of the `lead_form` branch at `:214`) that renders from `kvContent`:

```js
if (type === "review_funnel") {
  const rf = (kvContent && kvContent.google_review_url) ? kvContent : null;
  if (!rf) return getErrorPage();             // no /internal GET fallback; KV is source of truth
  return getReviewFunnelPage(rf, pageDesign, { shortCode: parsedData.shortCode || "" });
}
```

New `src/pages/reviewFunnel/index.js` (dispatcher, picks template by `page_design.templateId`) + `src/pages/reviewFunnel/<variant>Template.js` (≥1 template; v1 ships `classicTemplate.js`). The template renders:
- The **rating step**: 5 tappable stars + `escapeHTML(rating_prompt || "How was your visit?")`.
- Inline client JS (no framework): on star tap, if `stars >= threshold` → `location.href = "/review-go/<shortCode>?stars=" + stars`; else reveal the **feedback form** (built from `kvContent.fields` — flat, per the §4.3 merge — honeypot `_hp`, consent checkbox, `consent_text`) whose `<form action="/lead-submit/<shortCode>" method="POST">` — **identical** to the lead-form template's form, so the existing `/lead-submit/` handler in `src/index.js:151` works **verbatim** (it reads `kvContent.fields`; we share that flat shape — see §4.3).
- **R1 invariant:** the feedback arm always shows a visible "Leave a Google review anyway" link → the validated `google_review_url`. No scanner is ever blocked from Google. Default copy is neutral.

`escapeHTML()` (`src/utils/html.js`) on **all** merchant strings (prompt, thank-you, field labels).

### 4.2 `/review-go/:shortCode` route — `src/index.js`

Add a route **before** the generic `/:shortCode` handler (alongside `/vcard-download/`, `/click/`, `/pw-verify/`, `/lead-submit/`):

```js
if (pathname.startsWith("/review-go/")) {
  const sc = pathname.split("/")[2];
  const stars = parseInt(url.searchParams.get("stars") || "0", 10);
  const route = url.searchParams.get("route") === "feedback" ? "feedback" : "google";
  if (!(stars >= 1 && stars <= 5)) return getErrorPage();   // bound the input
  const kvRaw = await env.QR_KV.get(sc).catch(() => null);
  if (!kvRaw) return getErrorPage();
  const kv = JSON.parse(kvRaw);
  ctx.waitUntil(recordScan(request, env, ctx, kv.qr_id, sc, kv.workspace_id,
                           { review_route: route, stars }));
  if (route === "feedback") {
    // beacon path: record the low-star choice, no redirect
    return new Response(null, { status: 204 });
  }
  const target = kv.content?.google_review_url;          // VALIDATED stored URL only
  if (!target) return getErrorPage();
  return Response.redirect(target, 302);
}
```
The `route=feedback` call is a `navigator.sendBeacon` (fire-and-forget, returns `204`); the `route=google` call is the user-navigated redirect. Both record exactly one `qr_scan_events` row with `stars` + `review_route`, so every star-tap is counted. The 302 target is still the **validated stored** URL only.

Tracking rides `ctx.waitUntil(recordScan(...))` — off the critical path, errors swallowed (matches the scan pipeline). Per O.Q.2, we record **one** event on the route-go path with a `stars` attribute (and `review_route: "google"`); the feedback arm's submission is already recorded by `qr_lead_submissions`.

**Threading the new fields is a 3-point change, not automatic — verified against current code:**
1. `recordScan`'s `extra` whitelist (`scan.js:56–59`) **only copies `variant_key` and `destination_url`** today. It silently drops anything else. We must add `if (extra.review_route) payload.review_route = extra.review_route;` and `if (typeof extra.stars === "number") payload.stars = extra.stars;`.
2. `ScanEventPayload` (`internal.py:290–309`) has no `review_route`/`stars` fields. Pydantic **drops unknown keys by default**, so without adding `review_route: str | None = None` and `stars: int | None = None` the worker's values are stripped at the model boundary even after step 1.
3. `record_scan_event` does `event_data = payload.dict()` then `db.table("qr_scan_events").insert(event_data)` (`internal.py:353–354`) — a bare insert of the whole dict, so the `qr_scan_events` table **must** have the `stars`/`review_route` columns (migration 0021, §2) or the insert errors.

All three ship in **this phase** (the analytics card and every KPI denominator are non-functional otherwise) — they are NOT forward-only/optional.

### 4.3 Feedback form KV shape parity

The `/lead-submit/` handler (`src/index.js:182`) reads `kvContent.fields` directly — **and it is not the only flat read.** Verified against current code, the same handler also reads `kvContent.redirect_url` (`:217`) and passes the whole `kvContent` into `getLeadFormThanksPage(kvContent, …)` (`:220`) / `getLeadFormPage(kvContent, …)` (`:233`), all of which assume the flat lead-form shape (`fields`, `success_message`, `redirect_url` at the top of `content`). So generalizing **only** the `fields` read (as a one-liner) would leave the review_funnel thank-you copy and post-submit redirect reading from the wrong place.

**Decision (revised — keep the KV shape FLAT, do not nest under `content.feedback`):** `build_kv_content` for `review_funnel` returns the rating config at the top of `content` **and merges the feedback form's keys flat alongside them** — `fields`, `success_message`, `redirect_url` live at `content.*` exactly like `lead_form`, while `google_review_url`/`star_threshold`/`rating_prompt`/`thank_you_message` sit beside them. Because the rating-step keys and the lead-form keys do not collide, the existing `/lead-submit/` handler then works **verbatim with zero changes** (it already reads `content.fields`/`content.redirect_url`/`success_message`), and the thanks page renders correct copy. This is strictly simpler than nesting + a partial generalization that misses two reads. (Override §3.4's `content.feedback` nesting accordingly — see the revised branch there.) The honeypot, consent, and backend POST body are unchanged.

### 4.4 Consent gate, scheduled, mirroring

- **Consent gate** (`src/utils/consent.js`) is **unaffected** — it fires only when `hasMarketingTags` (workspace pixels present). The rating step sets no marketing tags.
- **`scheduled()`:** no change. **No new cron** → no prod-worker-deploy-for-cron gate.
- **Template mirroring (house rule, R5):** the rating step + feedback form exist in the Worker (`src/pages/reviewFunnel/`) **and** must be mirrored by a React preview (§5). Ship both in the same PR.

---

## 5. Frontend Design (`qr_frontend`)

### 5.1 Builder content-type form

`src/components/qr-generator/content-types/review-funnel-form.tsx` (react-hook-form + zod, ≤200 lines, one export, kebab-case). Fields: **Google review URL** (required; zod refine to the same Google host allow-list as the backend, so client + server agree), **star threshold** (shadcn `Slider`, default 4, range 2–5), **feedback form fields** (reuse the existing `LeadFormFieldRow.tsx` field-builder from `content-types/`), **notify email**, **rating prompt copy**, **post-feedback thank-you message**. A non-dismissable helper note documents the **R1 invariant** ("Every customer can still leave a public Google review — don't write coercive copy"). No inline styles, no `any`. The save path maps `feedback` fields onto the existing `lead_form` payload block consumed by `qr.py`.

### 5.2 React preview + picker (template parity)

`src/components/qr-generator/templates/review-funnel/` — a React preview component **pixel-mirroring** the Worker `classicTemplate.js` rating step (stars + prompt; a toggle to preview the feedback arm). Add `review_funnel` cases to `TemplatePicker.tsx` and `PagePreview.tsx` (and a type tile in the type picker, shown locked for Free via `canAccessFeature`). `MobilePreview` wraps it in the phone frame. Every Worker template ⇄ one React preview (house rule, memory `feedback_sync_worker`).

### 5.3 Per-funnel analytics card

`src/components/org/qrs/QRDetails.tsx` overview tab — a new `ReviewFunnelCard.tsx` rendered **conditionally for `qr.type === 'review_funnel'`**, mirroring how `ABResultsCard` renders for `type === 'website'`. Shows: **star distribution** (1–5 bar, shadcn `Progress`), **% routed to Google vs feedback**, **feedback-form completion rate**, total scans. Driven by a new hook on the `analyticsKeys`/`qrKeys` factory pattern, e.g. `useReviewFunnelStats(qrId, range, workspaceId)`, transported by `authApi` (Supabase-JWT Axios). Counts come from a new backend aggregate `GET /analytics/review-funnel?qr_id=…` reading `qr_scan_events` rows (route-go events: `review_route`/`stars`) — **not** `qr_scan_counters` (R7), reusing the `_resolve_workspace` + retention-clamp helpers in `scan.py`. The endpoint is **not** `advanced_analytics`-gated (single-funnel analytics ship at Starter+ with the type); richer cross-funnel rollups stay Pro+ via `advanced_analytics` (out of scope, §7 future). Tokens: `primary` `#4648d4` for the Google-routed segment, `tertiary` cyan for the feedback segment, `on-surface-variant` for labels. shadcn primitives only, ≤200 lines (split the bar into a sub-component), TanStack Query only.

### 5.4 Feedback inbox (free reuse)

The Leads dashboard (`src/app/org/[slug]/(dash)/leads/`, `LeadsClient`) already lists `qr_lead_submissions`; `review_funnel` feedback surfaces there automatically (tagged by `qr_id`) since the unhappy arm writes to that table. **No change required.**

### 5.5 PlanFeatures / gating

`src/lib/plan-features.ts` (`canAccessFeature`): the type tile uses the plan's `dynamic_qr_types` list (already exposed on the subscription) — `canCreateType(subscription, 'review_funnel')` — to show locked + an upsell ("Turn scans into 5-star Google reviews — upgrade to Starter") for Free. **No new `PlanFeatures` boolean.**

---

## 6. AI / External-Service Integration

**No AI in v1.** Star distribution + route split are deterministic counts that must reconcile ±2% (KPI), which rules out an LLM. Future feedback-inbox summarization (R6), if ever built, runs **backend-side at request time** (`claude-haiku-4-5`, metered/capped, confirm-before-save) — **never** on the Worker scan hot path.

**Email (Resend) + DMARC GA gate.** The unhappy-arm owner notification rides the existing Resend path in `utilities/email.py` (verified `send.qravio.app` MAIL FROM, SPF+DKIM align). **`_dmarc.qravio.app` is NOT yet published** (memory `project_email_dmarc`). **GA prerequisite:** publish `v=DMARC1; p=none` TXT for `qravio.app` so the notification avoids the Gmail "dangerous" banner. No new cron → no prod-worker-deploy-for-cron gate.

**Google Places API:** out of scope (v1 only links to the merchant-pasted write-URL; no rating pull).

---

## 7. API Contracts

**Create/update QR** — `POST /api/v1/workspaces/{workspace_id}/qrs` / `PATCH …/{qr_id}` (Bearer, `require_can_create/update`, `dynamic_qr_types` gate):
```json
{
  "type": "review_funnel", "category": "dynamic", "name": "Pune Café table tent",
  "review_funnel": {
    "google_review_url": "https://g.page/r/CafeXyz/review",
    "star_threshold": 4,
    "rating_prompt": "How was your visit?",
    "thank_you_message": "Thanks — we'll make it right."
  },
  "lead_form": { "fields": [{"name":"message","label":"What went wrong?","type":"textarea","required":true}],
                 "notify_email": "owner@cafe.example", "success_message": "Thank you" }
}
```
`422 {"detail":"google_review_url must be a Google review link"}` on a non-Google host. `403` for Free (dynamic-type gate at `qr.py:1272`).

**`POST /api/v1/internal/lead-submit`** (x-internal-secret) — **unchanged shape**, now accepts `review_funnel` QRs:
```json
{ "short_code": "Ab3xZ", "data": {"message":"slow service"}, "consent": true,
  "consent_text": "I agree to be contacted", "ip": "…", "user_agent": "…" }
```
→ `201 {"status":"ok"}`. `404` if the QR is neither `lead_form` nor `review_funnel`; `400` on missing consent/required field.

**`GET /review-go/{shortCode}?stars=N`** (Worker route) → `302` to the validated `google_review_url`; records one route event via `recordScan` extra `{review_route:"google", stars:N}`.

**`GET /api/v1/analytics/review-funnel?qr_id=…&range=30`** (Bearer) →
```json
{ "qr_id":"…","range_days":30,"total_scans":820,
  "star_distribution":{"1":12,"2":18,"3":40,"4":210,"5":300},
  "routed_to_google":510,"routed_to_feedback":70,
  "feedback_started":70,"feedback_completed":11,"feedback_completion_rate":15.7 }
```

---

## 8. Pricing & Packaging

| Surface | Tier | Gate |
|---|---|---|
| Create/use `review_funnel`, edge routing, feedback arm, per-funnel analytics | **Starter, Pro, Agency** | `dynamic_qr_types` contains `"review_funnel"` (seeded by 0021) |
| Free | locked | type tile + upgrade prompt; create 403s via `qr.py:1272` |

**Why `dynamic_qr_types` and no boolean flag:** the gate at `qr.py:1272` is the canonical "which QR types can this plan create" mechanism (exactly how `lead_form` is gated). A redundant boolean would force a `FEATURE_ENFORCEMENT` edit and risk the coverage-parity test for zero benefit. **Why Starter (not Pro):** this is an acquisition wedge for the cheapest-CAC ICP; gating at Pro defeats the purpose. **Feedback arm bundled (D1, R4):** a Starter user gets the private-feedback form **without** the `lead_forms` (Pro+) entitlement, because §3.3 relaxes the `lead_forms` check for `review_funnel` QRs. This is intentional packaging — the feedback arm is narrower than general Lead Capture (fixed purpose, no CRM). The existing 10/IP/hr submission limit caps abuse.

---

## 9. Security, Privacy & Abuse

- **Tenant isolation (service role bypasses RLS):** create/update resolve the workspace and pass `require_can_*`; the analytics aggregate resolves the workspace via `_resolve_workspace` and filters `qr_scan_events`/`qr_review_funnel` by the caller's `qr_id` set — confirming `qr_codes.workspace_id == resolved_ws` before any `qr_id` query. Route-level scoping is the **only** boundary.
- **R1 — Review-gating / Google ToS (headline risk):** built **feedback-first** as a product invariant — every scanner sees the same neutral rating step; the feedback arm always exposes a "Leave a Google review anyway" link; we never suppress/hide/block a public review. Default copy neutral; the builder warns against coercive copy. Not a toggle.
- **R2 — Malicious URL:** Google-host allow-list validated **backend-side at write time** (§3.1). The 302 target is the stored validated URL, never a scan-time parameter. `escapeHTML()` on all rendered merchant copy.
- **R3 — Feedback PII + consent:** reuses `/internal/lead-submit`'s consent checkbox, honeypot (`_hp`), IP rate-limit, field validation — inherited verbatim. `notify_email` never reaches KV (PII stays in `qr_lead_forms`). The EU consent gate is independent (keys off pixels, which the rating step doesn't set).
- **Internal endpoint:** `/internal/lead-submit` stays router-wide `verify_internal_secret`-protected (`x-internal-secret`); no Bearer change, no new public route.
- **Public surface (rating page):** non-PII — only merchant copy + stars; no scanner identity rendered.

---

## 10. Performance, Scale & Cost

- **Hot path is KV-only:** the rating step renders from `kvContent` with **no backend call** → p95 render **< 80ms** (KPI). The star tap → `/review-go/` does a single KV read + `ctx.waitUntil` event (off critical path) before the 302.
- **Analytics:** per-funnel aggregate uses `count="exact"` head queries over `qr_scan_events` filtered by `qr_id` + `scanned_at >= start`, backed by the new `idx_scan_events_qr_time` index (0021). Single-funnel windows are small; 60s TanStack `staleTime` bounds repeat cost. Counts come from raw rows, not the lossy `qr_scan_counters` (±2% reconciliation KPI).
- **Cost:** one extra KV read on `/review-go`; one extra `qr_lead_submissions` insert per below-threshold completion (negligible). No edge compute beyond template rendering.

---

## 11. Testing Strategy

**Backend (pytest):** (1) create `review_funnel` → `qr_review_funnel` + `qr_lead_forms` rows written, KV `content` carries `google_review_url`/`star_threshold`/`feedback.fields` and **omits** `notify_email`; (2) Google-URL validation accepts `g.page`/`maps.app.goo.gl`/`google.com`, rejects others (422); (3) **gate:** Starter creates, Free 403s via `dynamic_qr_types`; (4) `/internal/lead-submit` now **accepts a `review_funnel` QR without the `lead_forms` flag** and rejects unrelated types (404); consent/required-field/rate-limit unchanged; (5) analytics aggregate reconciles ±2% with hand-counted route events; (6) `_build_content_from_db_rows` parses the embedded `qr_review_funnel` to-one; (7) **`ScanEventPayload` round-trips `stars`/`review_route`** — POST `/internal/scans` with both fields persists them to `qr_scan_events` (guards the Pydantic-drop regression); (8) `build_kv_content("review_funnel")` returns a **flat** `content` (`fields`/`success_message`/`redirect_url` at top level alongside `google_review_url`), and **omits** `notify_email`. **Keep `test_feature_gate_coverage` green — no `FEATURE_ENFORCEMENT` row added** (parity holds by construction).

**Worker (vitest/wrangler):** rating step renders from KV (`escapeHTML` on copy); star ≥ threshold → `/review-go?route=google` → 302 to the **validated stored** URL with a `recordScan` event (`{review_route:"google", stars}`); star < threshold → `sendBeacon /review-go?route=feedback` returns 204 + records `{review_route:"feedback", stars}`, then reveals the feedback form posting to `/lead-submit/`; the feedback form reads the **flat** `content.fields` (no worker `/lead-submit/` change needed); out-of-range `stars` (0/6) → error page; the "Leave a Google review anyway" link is always present (R1); 302 is never blocked.

**Frontend (Vitest + Playwright):** `review-funnel-form` zod validation (Google host, threshold 2–5); React preview ⇄ Worker template parity snapshot; `ReviewFunnelCard` renders only for `type === 'review_funnel'`; Free sees the locked tile + upsell. **Baseline: ~29 pre-existing FE failures are documented and NOT regressions** — assert new tests pass and the failure count does not increase.

---

## 12. Observability & Rollout

**Phase 0 — Backend type + migration (internal):** add the Literal, `build_kv_content` branch, `SELECT_WITH_RELATIONS` join + model + `_build_content_from_db_rows`, `qr_review_funnel` upsert + Google-URL validation, and **relax `/internal/lead-submit`** for `review_funnel`. Apply 0021 in Supabase. Verify the gate (Starter creates, Free 403s). No FE/Worker yet.

**Phase 1 — Worker + builder (design-partner beta):** deploy the Worker `reviewFunnel/` page + `/review-go/` route + the generalized `/lead-submit/` field read **after** the backend accepts `review_funnel` submissions (order matters). Ship the builder form + React preview + picker cases behind a FE constant flag for 5–10 India café/clinic partners. **Acceptance:** scan → rating from KV; 5★ → Google 302; 2★ → feedback → `qr_lead_submissions` row + Resend email; analytics card shows star distribution; React ⇄ Worker pixel-identical; no scanner blocked from Google. **Email GA gate:** publish `_dmarc.qravio.app` (`v=DMARC1; p=none`) before GA. **Deploy order:** Supabase 0021 → backend → Worker (dev `sparkling-waterfall-3a9f`, then prod `qr-worker-prod` via `npm run deploy:prod`) → FE flag → beta.

**Phase 2 — SEO/GEO cluster + GA:** ship the `review_funnel` static-page keyword cluster (footer + sitemap), flip the FE flag GA, publish the design-partner case study.

**Metrics:** funnel create rate among new Free India/ROW signups; Free→Starter conversion after hitting the type gate; scan→star-tap rate; % ≥ threshold (routed to Google); feedback completion rate; rating-step p95 (<80ms); zero Google-block incidents (R1 invariant).

---

## 13. Open Technical Questions & Risks + Appendix

**Open questions:** (1) Default threshold — **4** (captures 4–5★ as happy). (2) Event granularity — **one** event per star-tap (`stars` + `review_route` attributes), fired on BOTH branches (Google via the 302 navigation, feedback via a `sendBeacon` returning 204) so 1–5★ distribution and route split derive entirely from `qr_scan_events` rows; not per-render, and never from `qr_scan_counters` (O.Q.2). (3) Starter feedback ceiling — reuse the existing 10/IP/hr limit; add a daily cap only on abuse (R4/D1). (4) Multi-language — merchant-supplied copy only at v1.

**Risks:** **R1** review-gating/ToS — mitigated by the feedback-first invariant (never a toggle). **R2** malicious URL — backend allow-list + stored-URL-only 302. **R4** bundled feedback bypasses `lead_forms` — intentional, narrow, rate-limited. **R5** template drift — ship Worker + React in one PR, verify parity. **R7** analytics denominator — count `qr_scan_events` rows + new index, never `qr_scan_counters`. **Scan-events extra columns (REQUIRED this phase):** the route-go event's `stars`/`review_route` must persist end-to-end — widen the `scan.js` `extra` whitelist (`:56–59`), add the two fields to `ScanEventPayload` (`internal.py:309`, else Pydantic drops them), and add the two nullable columns in 0021 (§2). Without all three the star-distribution/route-split card has no data — this is not optional, and the index alone is insufficient.

### Appendix — Key Files

| Concern | File |
|---|---|
| Type Literal + `SELECT_WITH_RELATIONS` + model + `_build_content_from_db_rows` + upsert + URL validation + gate | `qr_backend/src/api/routes/qr.py` (`736`, `836`, `880`+, `1272`, `1909`/`2774`) |
| KV content branch (no `notify_email`) | `qr_backend/src/utilities/cloudflare_kv.py` (`325`+, mirror `:378`) |
| Relaxed negative-arm submission | `qr_backend/src/api/routes/internal.py` (`/lead-submit` `:736`; type-reject `:782`; `lead_forms` gate `:790`) |
| Per-funnel analytics aggregate | `qr_backend/src/api/routes/scan.py` (new `/analytics/review-funnel`) |
| Migration | `qr_backend/migrations/0021_google_review_funnel.sql` |
| Worker dispatch + rating page + templates | `qr_cf_code/src/handlers/qrRouter.js` (`:214`); new `qr_cf_code/src/pages/reviewFunnel/` |
| `/review-go/` + generalized `/lead-submit/` | `qr_cf_code/src/index.js` (`:151`, new route) |
| Worker scan/util | `qr_cf_code/src/utils/scan.js` (`recordScan` `:16`), `src/utils/html.js`, `src/utils/consent.js` |
| Builder form + preview + picker | `qr_frontend/src/components/qr-generator/content-types/review-funnel-form.tsx`, `.../templates/review-funnel/`, `TemplatePicker.tsx`, `PagePreview.tsx`, `content-types/LeadFormFieldRow.tsx` (reused) |
| Analytics card | `qr_frontend/src/components/org/qrs/QRDetails.tsx` (mirror `ABResultsCard`) |
| Feedback inbox (reused) | `qr_frontend/src/app/org/[slug]/(dash)/leads/` (`LeadsClient`) |
| FE gating | `qr_frontend/src/lib/plan-features.ts` |
