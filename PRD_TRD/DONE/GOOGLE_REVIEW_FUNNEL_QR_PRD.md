# PRD — Google Review Funnel QR (feedback-first)

**Status:** Draft · **Author:** Product · **Date:** 2026-06-24
**Priority:** SMB-acquisition wedge + SEO/GEO land-grab on "google review QR code" — high-intent, dense India/ROW ICP. Ships as a **new dynamic QR type**, reusing the just-built Lead Capture form arm.
**Tiers:** **Starter+** via the existing `dynamic_qr_types` allow-list (no new boolean flag). The new type value `review_funnel` is appended to Starter/Pro/Agency `dynamic_qr_types` by this feature's migration. The private-feedback arm reuses Lead Capture infrastructure but is **bundled into this type** (not separately gated by `lead_forms`).
**Plan flags:** none new. Gating is by `dynamic_qr_types` containing `review_funnel` (seeded by migration **0021**). `FEATURE_ENFORCEMENT` is untouched (no new boolean flag), so `test_feature_gate_coverage` stays green by construction.
**Split from:** the new-QR-type family (peer of `lead_form` in `LEAD_CAPTURE_FORMS_PRD.md`); reuses Lead Capture's `/internal/lead-submit` + Resend path for the unhappy-scanner arm.
**Migration:** **0021** — `qr_review_funnel` detail table + `dynamic_qr_types` seed append. Reserved slot 0021 (0014–0018 taken by the analytics/AI roadmap; 0019–0020 reserved elsewhere). Schema for **this phase only**.

**Rev (2026-06-24, post eng-review):** Tightened R2 URL validation to require `https` + a parsed-host exact/suffix allow-list (never a substring `in`, which a look-alike domain would pass), clarified it is a client-side redirect (no SSRF surface), and dropped bare `goo.gl`. Corrected `internal.py` line refs (`:790` gate). The substantive engineering gaps — the route-decision `stars`/`review_route` must be persisted end-to-end (scan.js whitelist + Pydantic model + scan-events columns, all in-phase), both star-branches must record an event so the 1–3★ distribution isn't blank, and the KV form shape stays flat so the existing worker `/lead-submit/` handler works verbatim — are detailed in the TRD; this PRD's scope/KPIs are unchanged.

---

## 1. TL;DR / Summary

Local SMBs live and die by their Google rating. The single highest-leverage growth lever for a restaurant, clinic, or salon is **more 5-star reviews** — but the friction of finding the business on Google Maps and tapping through to "write a review" kills the conversion. Every competitor (and a thousand Etsy NFC plaques) sells a "tap for a Google review" product, and that is exactly the search term — *"google review QR code"* — that our static-page SEO/GEO engine should own.

Qravio ships a **`review_funnel` dynamic QR type**: scan a table-tent/receipt QR → land on a fast, branded **rating step (1–5 stars)** → **4–5★ scanners are routed straight to the merchant's Google review write-URL**; **1–3★ scanners are routed into a private feedback form** (reusing our just-built Lead Capture form + Resend notification) so the owner hears the complaint privately and can fix it. The merchant gets more public 5-star reviews **and** a private early-warning channel for unhappy customers.

This is feedback-**first**, not review-gating: every scanner sees the same rating step, nobody is blocked from leaving a public review, and we never suppress a negative one. It reuses six existing seams (the 7-step new-QR-type pipeline, the Lead Capture submit endpoint, Resend, the consent gate, the page-template system, and the static-page SEO engine) — so the net-new surface is one detail table, one worker template arm, one builder form, and one migration.

## 2. Problem & Motivation

**The strategic gap: we have no acquisition wedge for the local-SMB ICP.** Our densest, lowest-CAC market is India/ROW small businesses — restaurants, cafés, clinics, salons, kirana stores. They do not care about "dynamic QR with retargeting pixels"; they care about **getting more Google reviews**. We have nothing pointed at that intent, while the category-defining demand ("google review QR code", "tap for review", "review card") is enormous and high-purchase-intent. A `review_funnel` type is the wedge that converts that demand into Starter signups.

**The SEO/GEO play is sitting unclaimed.** Memory `project_seo_geo_roadmap` documents the 72-static-page programmatic engine that already ranks us. A `review_funnel` type unlocks a whole new content cluster — *"google review QR code generator"*, *"QR code for Google reviews for restaurants"*, *"review funnel QR"* — that maps directly to the existing static-page factory. This is the cheapest organic-acquisition surface in the backlog: one new type powers an entire keyword cluster.

**We already built the hard half.** The unhappy-scanner arm is a **private feedback form** — which is precisely Lead Capture, shipped 2026-06-23 (`qr_lead_forms`, `qr_lead_submissions`, `POST /internal/lead-submit` with consent + IP rate-limit + Resend notify, verified at `internal.py:736`). We reuse that submit path verbatim for the 1–3★ branch instead of reinventing a form pipeline. The happy-scanner arm is just a redirect to the Google write-URL — trivially within the existing `destination` model. The two arms compose seams we already own.

**Proven, measurable lift.** The "route happy → Google, unhappy → private" pattern is a well-worn SMB playbook with a clear, attributable outcome (review volume up, average rating up, complaints intercepted before they go public). It gives us a crisp before/after success story for case studies — fuel for the GEO content.

**Why this and why now.** The coming-soon backlog is closed (API, white-label, lead capture, retargeting all built; SSO = contact-sales). The next dollar is best spent on **acquisition**, and `review_funnel` is the one feature that (a) targets our cheapest ICP, (b) reuses fresh infrastructure, and (c) feeds the SEO engine — all at the cost of one type.

## 3. Goals & Non-Goals

**Goals**
- A new **`review_funnel` dynamic QR type** following the full 7-step new-QR-type checklist (Literal value → `build_kv_content` → `SELECT_WITH_RELATIONS`/pydantic/`_build_content_from_db_rows` → `dynamic_qr_types` seed → worker page+template → React preview + content-type form + picker cases → worker/React template parity).
- A **worker-rendered rating step** (1–5 stars) as the scan landing page, served entirely from KV with **no backend round-trip** on the hot path.
- **Threshold routing at the edge:** stars ≥ threshold → 302 to the merchant's Google review write-URL; stars < threshold → render the **private feedback form** (Lead Capture form arm).
- **Reuse `POST /internal/lead-submit`** for the negative-feedback submission (consent, validation, IP rate-limit, Resend owner-notify) — no new submission endpoint.
- A **builder content-type form** to set: Google review URL, star threshold (default 4), feedback-form fields, notify email, page copy/theme.
- **Per-funnel analytics**: star-distribution + route split (→Google vs →feedback) + private-feedback conversion, computed from accurate sources.
- **Seed the SEO/GEO content cluster** for this type via the existing static-page engine (separate content task, enabled by the type existing).

**Non-Goals**
- **Review-gating / suppressing negative reviews** — explicitly NOT this. All scanners reach the rating step; no scanner is blocked from Google; we never hide a public review. (See §11 R1.)
- Reading or displaying the merchant's actual Google rating / pulling reviews via the Google Places API — *(future)*; v1 only links out to the write-URL the merchant pastes.
- Multi-platform routing (Yelp/Trustpilot/Facebook) — v1 is Google-only; multi-destination is *(future)*.
- AI-summarizing the private feedback inbox — *(future; backend-side only if added — see §11 R6)*.
- A new boolean entitlement flag — gating is `dynamic_qr_types` membership only.
- CRM/Zapier export of feedback (inherits Lead Capture's non-goal).

## 4. Target Users & Personas

| Persona | Who | Job-to-be-done | Today's pain |
|---|---|---|---|
| **Restaurant owner ("Anand")** | Single-location café in Pune, table-tent + receipt QR | Get more 5-star Google reviews, hear complaints before they go public | Customers never bother finding him on Maps; angry ones post 1-star instead of telling him |
| **Clinic front-desk ("Dr. Mehta")** | Dental clinic, QR on the discharge slip | Boost rating; privately catch service issues | No structured feedback channel; rating stuck at 4.1 |
| **Salon chain manager ("Reena")** | 6 outlets, one QR per chair | Compare review-funnel performance across outlets | No per-location review-conversion view |
| **Local-marketing agency ("Marcus")** | Manages reputation for 20 SMB clients | Sell "review growth" as a retainer line item | Stitches together third-party plaque tools per client |

Primary buyer is the **owner-operator SMB on Starter** (the cheapest paid tier) — the highest-volume, lowest-CAC segment Qravio under-serves today. The agency reseller is the expansion path (Pro/Agency, many funnels).

## 5. User Stories

- As a **restaurant owner**, I want happy diners sent straight to my Google review page, so that I actually accumulate 5-star reviews instead of losing them to friction.
- As a **clinic owner**, I want unhappy patients routed to a private form that emails me, so that I can fix the issue before it becomes a public 1-star.
- As an **owner**, I want to set the star threshold (e.g. 4★+ → Google), so that I control where the cutoff sits — while knowing nobody is ever *blocked* from Google.
- As a **salon manager**, I want per-funnel analytics (star distribution, % routed to Google vs feedback), so that I can compare outlets.
- As an **agency**, I want to spin up one `review_funnel` per client quickly, so that "review growth" becomes a repeatable retainer service.
- As a **Free-tier user**, I want to see the review-funnel type behind an upgrade prompt, so that I understand Starter unlocks it.
- As a **scanner**, I want a fast, branded one-tap rating, so that leaving feedback isn't a chore — and I'm never prevented from writing a public Google review if I want to.

## 6. UX / Product Flow

**6.1 Builder — QR wizard (`qr_frontend/src/components/qr-generator/`)**
1. In the type picker the user selects **Google Review Funnel** (new type tile; shown gated/locked for Free with an upgrade nudge — mirrors how `lead_form` appears for non-entitled plans).
2. **Content step** (new `content-types/review-funnel-form.tsx`, react-hook-form + zod, ≤200 lines, one export, kebab-case): fields are **Google review URL** (required, validated as a Google/`maps.app.goo.gl`/`g.page` URL), **star threshold** (slider, default 4, range 2–5), **feedback form fields** (reuse the Lead Capture field-builder component), **notify email**, **rating prompt copy** + **post-feedback thank-you message**.
3. **Page Design step** picks a `review_funnel` template via `TemplatePicker` + `PagePreview`; the live `MobilePreview` shows the rating step. Every worker template has a mirrored React preview (house rule — §11 R5).
4. Save → `qr.py` write path → `write_to_kv()` packages the rating config + feedback-form config into KV `content` (no `notify_email` in KV — owner PII stays in `qr_review_funnel`/`qr_lead_forms`, matching Lead Capture's rule).

**6.2 Scan flow (Cloudflare Worker — `qr_cf_code`)**
1. `GET /:shortCode` → KV lookup → `handleQRCode` dispatches `type === 'review_funnel'` to `src/pages/reviewFunnel/`.
2. Worker renders the **rating step** (1–5 stars) entirely from `kvContent` — no backend call, `escapeHTML()` on all merchant copy.
3. Scanner taps a star (client-side, no extra round-trip to choose the branch):
   - **stars ≥ threshold** → 302 redirect to the Google review write-URL (a `/review-go/:shortCode?stars=N` worker route records the choice via `recordScan`-style event, then redirects — keeps tracking off the user's critical path via `ctx.waitUntil`).
   - **stars < threshold** → render the **private feedback form** (same Lead Capture form template), which `POST`s to **`/internal/lead-submit`** (existing endpoint: consent checkbox, honeypot, IP rate-limit, validation, Resend owner-notify).
4. The consent gate (`src/utils/consent.js`) behaves exactly as today — it only fires when marketing pixels are present (`hasMarketingTags`); the rating step itself sets no marketing tags.

**6.3 QR detail / analytics (`QRDetails.tsx` overview tab + `/analytics`)**
- A **Review Funnel card** (renders conditionally for `type === 'review_funnel'`, like `ABResultsCard` does for `website`) showing: **star distribution** (1–5 bar), **% routed to Google vs feedback**, **feedback-form completion rate**, total scans. Counts come from `qr_scan_events` / the review-route event rows — **not** the lossy `qr_scan_counters` JSONB (§11 R7).
- The **Leads dashboard** (`LeadsClient`) already lists `qr_lead_submissions`; feedback from `review_funnel` QRs surfaces there for free since the unhappy arm reuses that table (tagged by `qr_id`).

**6.4 SEO/GEO (marketing surface, static-page engine)**
- Once the type exists, the static-page factory generates the `review_funnel` keyword cluster (separate content PR). Linked from footer + sitemap, consistent with the API-docs/static-page precedent.

## 7. Scope

**In scope (v1)**
- New `review_funnel` dynamic QR type, full 7-step pipeline.
- Worker rating step + edge threshold routing (≥ threshold → Google 302; < threshold → feedback form).
- Reuse of `/internal/lead-submit` for the negative arm (zero new submission endpoint).
- `qr_review_funnel` detail table (review URL, threshold, prompt copy) + reuse of `qr_lead_forms` for the feedback-form config.
- Builder content-type form + React preview + ≥1 worker template (+ mirror).
- Per-funnel analytics card (star distribution, route split, feedback completion).
- `dynamic_qr_types` seed append for Starter/Pro/Agency (migration 0021).
- Google-URL validation (basic host/format check) at write time, backend-side.

**Out of scope / Future**
- Multi-platform routing (Yelp/Facebook/Trustpilot).
- Google Places API integration (live rating display, review pull).
- AI summarization of the feedback inbox (backend-side only if ever added — §11 R6).
- A/B testing the threshold or copy (could later reuse `ab_testing`).
- QR-on-receipt POS integrations.
- Per-location rollup dashboards across many funnels (single-funnel analytics only in v1).

## 8. Pricing & Packaging

| Surface | Tier | Gate |
|---|---|---|
| Create/use `review_funnel` QRs, edge routing, feedback arm, per-funnel analytics | **Starter, Pro, Agency** | `dynamic_qr_types` list contains `"review_funnel"` (seeded by 0021) |
| Free tier | locked | type tile shown with upgrade prompt; create returns 403 via the existing `dynamic_qr_types` gate (`qr.py:1272`) |

- **Why `dynamic_qr_types` and no new boolean flag:** the existing gate at `qr.py:1272` already enforces the per-plan allowed-types list and is the canonical mechanism for "which QR types can this plan create" (exactly how `lead_form` is gated). Adding a redundant boolean would mean touching `FEATURE_ENFORCEMENT` and risking the coverage-parity test for no benefit. **No `FEATURE_ENFORCEMENT` change → `test_feature_gate_coverage` stays green by construction.**
- **Why Starter (not Pro):** this is an **acquisition wedge** for the cheapest-CAC ICP. Gating it at Pro would defeat the purpose; the goal is to convert Free → Starter on the "more Google reviews" promise. The feedback arm is bundled in — it is **not** separately gated by `lead_forms` (a Starter user gets the review funnel's private-feedback form even without the full Lead Capture entitlement, because it is part of this type's value prop). This is the deliberate packaging decision; revisit only if abuse appears.
- **Upsell angle:** Free → Starter ("Turn scans into 5-star Google reviews — upgrade to Starter"). Agency resellers buy higher tiers for volume (many funnels across clients) and the richer analytics already gated at Pro+ (`advanced_analytics`).
- **Migration flag-flip house convention:** the migration uses the parity-safe `jsonb_set` append pattern (per the codebase house rule and 0012's verified precedent), **not** a bare case-sensitive `WHERE name IN (...)`, and excludes custom plans (`coalesce(is_custom,false)=false`). See §12.

## 9. Success Metrics & KPIs

**Acquisition (the headline)**
- ≥ **8%** of new Free signups in India/ROW create a `review_funnel` QR within 7 days (intent proxy).
- ≥ **20%** of Free workspaces that hit the `review_funnel` upgrade gate convert to Starter within 30 days.
- Organic sessions to the `review_funnel` SEO cluster reach **2,000/mo within 90 days** of the static-page cluster shipping.

**Engagement / outcome**
- Median `review_funnel` QR sees a **scan→star-tap rate ≥ 60%** (rating step is low-friction).
- Of star-taps, **≥ 70%** are ≥ threshold and route to Google (validates the happy-path framing).
- **≥ 15%** of below-threshold scanners complete the private feedback form (vs. abandoning).
- Merchant-reported (survey, design-partner cohort): average Google rating up **≥ 0.2★** and review volume up **≥ 2×** within 60 days for active funnels.

**Quality / trust**
- Analytics star-distribution reconciles within **±2%** of a manual `qr_scan_events` / review-route-event spot-check (accurate denominator, not the lossy counter).
- Rating-step worker render p95 **< 80ms** (KV-only, no backend call).
- Zero incidents of the funnel **blocking** a scanner from reaching Google (ToS-safety invariant — §11 R1).

## 10. Rollout Plan

**Phase 0 — Backend type + migration (internal)**
- Add the `review_funnel` Literal, `build_kv_content` branch, `SELECT_WITH_RELATIONS` join + pydantic model + `_build_content_from_db_rows`, and the `qr_review_funnel` table. Apply migration **0021** (idempotent, BEGIN/COMMIT, `IF NOT EXISTS`) in the Supabase SQL editor — seeds `review_funnel` into Starter/Pro/Agency `dynamic_qr_types`. No FE/worker yet. Verify the gate: Starter can create, Free 403s.

**Phase 1 — Worker scan flow + builder (design-partner beta)**
- Worker `reviewFunnel/` page + ≥1 template + mirrored React preview + content-type form + picker cases. Threshold routing + reuse of `/internal/lead-submit` for the negative arm.
- Beta behind a FE env/constant flag for 5–10 SMB design partners (India café/clinic cohort).
- **Acceptance:** scan → rating step renders from KV; 5★ → Google write-URL 302; 2★ → feedback form → submission lands in `qr_lead_submissions` + owner gets the Resend email; analytics card shows star distribution; worker and React previews are pixel-identical; no scanner is ever blocked from Google.
- **Email deliverability GA gate:** the unhappy-arm owner notification rides Resend (`send.qravio.app`). **`_dmarc.qravio.app` is NOT yet published** (memory `project_email_dmarc`). Publishing `v=DMARC1; p=none` for `qravio.app` is a **GA prerequisite** for the notification email to avoid the Gmail "dangerous" banner. No new cron is added, so no prod-worker-deploy-for-cron gate applies.

**Phase 2 — SEO/GEO cluster + GA**
- Ship the static-page keyword cluster (footer + sitemap links). Flip the FE flag to GA. Publish the case-study from beta data.

**Phase 3 — Future:** multi-platform routing, Google Places live rating, threshold A/B, feedback-inbox AI summary (backend-side).

## 11. Risks, Edge Cases & Open Questions

**R1 — Google ToS / review-gating line (the headline risk).** Routing only happy scanners to Google can read as "review gating," which Google discourages. **Mitigation (invariant):** frame and build **feedback-first** — *every* scanner sees the same neutral rating step; the post-rating routing is the merchant's funnel, but the rating step **always** offers a visible path to leave a public Google review regardless of stars (a "Leave a Google review anyway" link on the feedback arm). We **never suppress, hide, or block** a public review. Default copy is neutral ("How was your visit?"), not "Only leave 5 stars on Google." This is a product invariant, not a toggle. Document it in the builder UI so merchants don't write coercive copy.

**R2 — Malicious/invalid Google URL.** A merchant could paste a phishing URL. **Mitigation:** validate the review URL backend-side at write time — require `https` + allow-list Google hosts by exact/suffix match (`google.com` or `*.google.com`, `g.page`, `maps.app.goo.gl`, `search.google.com`); use a parsed-host suffix check, **never a substring `in`** (which `evilgoogle.com.attacker.net` would pass); reject others with 422. `escapeHTML()` everything rendered. The 302 target is the validated stored URL, never user-supplied at scan time (a client-side redirect, not a server-side fetch — no SSRF surface).

**R3 — Feedback arm = PII + consent.** The negative arm collects free-text + optional contact info → PII. **Mitigation:** it reuses `/internal/lead-submit` which already enforces a consent checkbox, honeypot, and IP rate-limit (handler at `internal.py:736`; `lead_forms` gate at `:790`). No change needed; we inherit Lead Capture's consent posture. The EU consent gate (`consent.js`) is independent and unaffected (it keys off marketing pixels, which the rating step doesn't set).

**R4 — Bundling the feedback arm under Starter bypasses `lead_forms` (Pro+).** A Starter user gets a private-feedback form without the `lead_forms` entitlement. **Decision (D1):** this is intentional packaging — the feedback arm is intrinsic to the review-funnel value prop and is **narrower** than general Lead Capture (fixed purpose, no CRM). We accept it. **Open question:** cap feedback submissions/retention for Starter to prevent using `review_funnel` as a backdoor general lead-capture tool? *Recommend a reasonable submission ceiling reusing existing rate limits; revisit if abused.*

**R5 — Worker/React template drift (house rule).** The rating-step + feedback-form templates exist in both the Worker (`src/pages/reviewFunnel/`) and the React preview. **Mitigation:** ship both in the same PR; the review checklist verifies parity. This is the standing house rule and a documented memory (`feedback_sync_worker`).

**R6 — Future AI summarization must stay backend-side.** If we ever summarize the feedback inbox, it runs **backend-side at request time** (Anthropic SDK, `claude-haiku-4-5` for cheap summaries, metered/capped, confirm-before-save) — **never** on the Worker scan hot path. Out of scope for v1; noted to prevent a future mistake.

**R7 — Accurate analytics denominator.** Star distribution and route-split must be counted from raw event rows (`qr_scan_events` + the review-route events), **not** `qr_scan_counters` (non-atomic read-modify-write, can lose increments). Add a `(qr_id, scanned_at)`-style index if the funnel query is slow.

**Open Questions**
1. Default star threshold — 4 or 5? *Recommend 4 (captures 4–5★ as "happy," matches the one-liner).*
2. Should the rating step record a scan event per star-tap, or only the route decision? *Recommend one event with a `stars` attribute on the route-go path.*
3. Starter feedback-submission ceiling (R4)? *Recommend yes, reuse existing limits.*
4. Multi-language rating prompt at v1, or English/merchant-supplied copy only? *Recommend merchant-supplied copy only at v1.*

## 12. Dependencies + Appendix

**Dependencies**
- **Lead Capture (shipped 2026-06-23):** `qr_lead_forms`, `qr_lead_submissions`, `POST /internal/lead-submit` (`internal.py:736`), Resend notify — the negative-feedback arm reuses these verbatim. Migration 0012 applied.
- **Resend / email (`utilities/email.py`):** owner notification. **GA gate: publish `_dmarc.qravio.app`** (currently unpublished — `project_email_dmarc`).
- **Dynamic-type gate (shipped):** `qr.py:1272` enforces `dynamic_qr_types`; 0008/0012 precedent for seeding the list.
- **Consent gate (shipped):** `consent.js` — unaffected (rating step sets no marketing tags).
- **Scan pipeline (shipped):** `qr_scan_events` + `recordScan` (`qr_cf_code/src/utils/scan.js`) for the route-decision event.
- **Page-template + builder system (shipped):** `TemplatePicker`, `PagePreview`, `MobilePreview`, `content-types/`, `templates/`.
- **SEO static-page engine (shipped):** `project_seo_geo_roadmap` factory for the keyword cluster (Phase 2).
- **Migration 0021** — `qr_review_funnel` table (review URL, star threshold, prompt copy; **no `notify_email` in KV**) + parity-safe `dynamic_qr_types` append for Starter/Pro/Agency. Schema for **this phase only** (no future-phase tables). Flag-flip pattern:
  ```sql
  UPDATE plans SET features = jsonb_set(
      coalesce(features,'{}'::jsonb), '{dynamic_qr_types}',
      CASE WHEN coalesce(features->'dynamic_qr_types','[]'::jsonb) @> '["review_funnel"]'::jsonb
           THEN features->'dynamic_qr_types'
           ELSE coalesce(features->'dynamic_qr_types','[]'::jsonb) || '["review_funnel"]'::jsonb END,
      true)
    WHERE lower(name) IN ('starter','pro','agency') AND coalesce(is_custom,false)=false;
  ```
  BEGIN/COMMIT-wrapped, idempotent (`IF NOT EXISTS`, `@>` guard). **No `FEATURE_ENFORCEMENT` row** (no boolean flag).

### Appendix — Key Files

| Concern | File |
|---|---|
| Type Literal + `SELECT_WITH_RELATIONS` join + pydantic model + `_build_content_from_db_rows` + create/update upsert | `qr_backend/src/api/routes/qr.py` (~`759`, `836`, `880`+, `1272` gate, `1909`/`2774` upsert pattern) |
| KV content branch (`build_kv_content`) | `qr_backend/src/utilities/cloudflare_kv.py` (~`378`, mirror `lead_form` branch) |
| Negative-arm submission (reused) | `qr_backend/src/api/routes/internal.py` (`/lead-submit`, `:736`) |
| Worker dispatch + rating page + templates | `qr_cf_code/src/handlers/qrRouter.js`; new `qr_cf_code/src/pages/reviewFunnel/` (+ `/review-go/:shortCode` route in `src/index.js`) |
| Worker scan/util | `qr_cf_code/src/utils/scan.js` (`recordScan`), `src/utils/html.js` (`escapeHTML`), `src/utils/consent.js` |
| Builder content-type form + React preview + picker cases | `qr_frontend/src/components/qr-generator/content-types/review-funnel-form.tsx`, `.../templates/review-funnel/`, `TemplatePicker.tsx`, `PagePreview.tsx` |
| Per-funnel analytics card | `qr_frontend/src/components/org/qrs/QRDetails.tsx` (conditional on `type === 'review_funnel'`, mirror `ABResultsCard`) |
| Feedback inbox (reused) | `qr_frontend/src/app/org/[slug]/(dash)/leads/` (`LeadsClient`) |
| Gating | `qr_backend/src/api/routes/qr.py` `dynamic_qr_types` gate (no `subscription.py` change) |
| Migration | `qr_backend/migrations/0021_google_review_funnel.sql` |
