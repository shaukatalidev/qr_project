# PRD — Scan→Action Conversion Funnel & Revenue Attribution

**Status:** Draft · **Author:** Product · **Date:** 2026-06-24
**Priority:** 1st of the post-coming-soon analytics wave — the premium analytics wedge.
**Tiers:** Pro+ (`advanced_analytics`) for the funnel view; **Phase-2 revenue attribution** gates on a new `revenue_attribution` flag (Agency-only). Both seeded `false` everywhere by migration 0009; this feature's migration (`0016`) flips the funnel surface on for Pro/Agency and seeds `revenue_attribution` for Agency.
**Plan flags:** `advanced_analytics` (bool, already enforced in `scan.py`) reused for the funnel; `revenue_attribution` (bool, NEW — Agency) for Phase-2 Stripe/Shopify revenue.
**Split from:** parent analytics surface (`/analytics`), extends Lead Capture (`LEAD_CAPTURE_FORMS_PRD.md`) + Retargeting Pixels (`RETARGETING_PIXELS_PRD.md`).
**Rev (2026-06-24, post eng-review):** the conversion denominator is **source-matched to scans of actionable QRs** (not all-workspace scans, which diluted the rate); **pixel reach moved out of the Actions step** into a separate stat; migration `0016` is Phase 1.0/1.1 schema only (revenue tables split to a Phase-2 migration); `list_links` `qr_id` is resolved backend-side from `link_id`.

---

## 1. TL;DR / Summary

Qravio already counts scans. Every competitor counts scans. The frontier — where Dub and Flowcode moved — is **conversion**: not "how many people scanned" but "how many people *did the thing*." This PRD defines a 2–3 step conversion funnel that joins three features we *just shipped* — scan events (`qr_scan_events`), lead submissions (`qr_lead_submissions`), and link-page clicks (`handlers/linkClick.js`) — into a single visual funnel with drop-off percentages, slotted into the existing Pro-gated `/analytics` page.

**Step 1: Scan** → **Step 2: Action** (form submit / link click / pixel fire) → **Step 3 (Phase 2): Revenue** (Stripe/Shopify webhook tie-back). The headline number becomes **conversion rate** and **drop-off %** per step. Phase 1 ships with **zero new edge data** — it is a backend aggregate query joining tables we already write to, plus a funnel chart component. Phase 2 adds revenue webhooks for true offline-campaign ROI.

This turns "scan analytics" (commodity) into "campaign ROI analytics" (premium, retention-driving, hard to leave).

## 2. Problem & Motivation

**Pure scan counts are a commodity.** Every free QR tool — and our own free tier — shows scan totals, device breakdown, and geo. Our strategic audit is explicit: *"pure scan counts are commodity, conversion/funnel is the premium wedge."* Dub and Flowcode both repositioned around conversion attribution because that is the number performance marketers actually report to their clients and CFOs.

**We have the raw material and are not using it.** We just shipped Lead Capture (`qr_lead_submissions`), Retargeting Pixels (`pixels` KV key + worker injection), and we already have link-click tracking (`POST /internal/link-click/:link_id` via `handlers/linkClick.js`). But these live in **separate silos**: the audit flags *"No workspace-level analytics rollup endpoint — only per-QR and global workspace scan summary exist. Funnel or conversion analytics (e.g. lead submissions vs scans ratio) are not aggregated server-side."* And specifically: *"Lead form analytics: lead submissions have no per-form conversion rate (scans vs submissions), no time-series chart in LeadsClient — it's a flat table only."*

**Marketers cannot prove offline ROI today.** An agency runs a print campaign, drives 5,000 scans, captures 340 leads, closes $12k. Today Qravio shows them "5,000 scans" and a separate flat table of 340 leads with no ratio, no funnel, no revenue tie-back. They export to a spreadsheet to compute conversion by hand. That spreadsheet is the product gap — and it is the exact gap Dub monetizes.

**The analytics page is already half-mocked, inviting a real story.** The FE audit notes the analytics page ships `repeatVisitorRate` and `scanSuccessRate` from `src/lib/mockAnalyticsData.ts` with TODO comments, and the "Download CSV/PDF" + "Schedule Weekly Report" buttons have **no `onClick`**. A funnel is the credible, real-data centerpiece that replaces mock filler and justifies the Pro gate.

**This is a cheap moat.** Phase 1 needs no new Worker code, no new KV fields, no new edge data — only a new aggregate query and a chart. The cost-to-value ratio is among the best of any feature in the backlog.

## 3. Goals & Non-Goals

**Goals**
- A **server-side funnel aggregate** (`GET /workspaces/{id}/analytics/funnel`) that joins `qr_scan_events` → action events (`qr_lead_submissions` + link clicks) within a time range, returning step counts + drop-off %.
- A **funnel visualization** on the existing `/analytics` page (Pro-gated) and a **per-QR mini-funnel** on the QR detail overview tab, for lead-form and list-links QRs.
- A **per-QR conversion rate** (actions ÷ scans) surfaced on the Leads dashboard and QR detail, replacing the flat-table-only experience.
- **Phase 2:** Stripe/Shopify revenue webhooks tying a closed transaction back to a scan session, producing **revenue per scan / per campaign** (Agency, `revenue_attribution`).
- Make `conversion rate` and `drop-off %` exportable (wire the dead CSV button to a real endpoint).

**Non-Goals**
- Cross-session / cross-day attribution in Phase 1 — the `session_id` is a **daily-rotated cookieless hash** (`SHA-256(IP+UA+today)`), so Phase 1 attribution stays **same-session** (scan and action in the same day, same device). True multi-touch attribution is *(future)*.
- New edge tracking fields (UTM, scroll depth, time-on-page) — *(future)*; the funnel reuses existing `recordScan` data.
- Pixel-conversion-event ingestion from Meta/Google (server-side CAPI) — *(future)*; a "pixel fired" step in Phase 1 is inferred from the page render, not from the ad platform.
- A funnel *builder* (custom multi-step goals) — Phase 1 funnels are fixed templates per QR type *(future: configurable goals)*.
- Real-time / streaming funnel updates — Phase 1 is query-on-load + 60s cache *(future)*.

## 4. Target Users & Personas

| Persona | Who | Job-to-be-done | Today's pain |
|---|---|---|---|
| **Performance Marketer ("Priya")** | In-house growth at a D2C brand running print + packaging QRs | Report scan→lead→sale conversion weekly to her CMO | Exports scans and leads to a spreadsheet, computes ratio by hand |
| **Agency Account Lead ("Marcus")** | Manages 30 client campaigns across workspaces | Prove campaign ROI to clients to justify retainer | Has scan counts but no drop-off story; clients ask "did it convert?" |
| **Event Organizer ("Dev")** | Runs ticketed events with lead-capture QRs | See registration funnel: scanned poster → opened form → submitted | Flat leads table; no view of how many scanned but didn't submit |
| **Founder / SMB owner** | Runs a `list_links` Linktree-style QR | Which link did scanners actually click? | Link clicks tracked but never joined to scans → no CTR |

Primary buyer is the **agency/performance-marketer** (Pro/Agency tiers) proving ROI on **offline** campaigns — the segment with the highest willingness to pay and the lowest churn once attribution is wired into their reporting cadence.

## 5. User Stories

- As a **performance marketer**, I want to see scan → form-submit conversion rate per campaign, so that I can report ROI to my CMO without a spreadsheet.
- As an **agency lead**, I want a drop-off % at each funnel step, so that I can tell a client "80% scanned but only 12% submitted — let's simplify the form."
- As an **event organizer**, I want a per-QR mini-funnel on the QR detail page, so that I can see registration drop-off for one poster at a glance.
- As a **`list_links` user**, I want to know what % of scanners clicked a link (and which link), so that I can reorder my links by performance.
- As an **agency on Agency tier (Phase 2)**, I want a Stripe sale tied back to the scan that drove it, so that I can show **revenue per scan** and true campaign ROAS.
- As a **free-tier user**, I want to see the funnel card teased behind an upgrade gate, so that I understand what Pro unlocks.
- As **any Pro user**, I want to export the funnel as CSV, so that I can drop it into a client deck.

## 6. UX / Product Flow

**6.1 Workspace funnel (the headline) — `/org/[slug]/(dash)/analytics`**
1. Pro user opens **Analytics** (already `advanced_analytics`-gated via `canAccessFeature(subscription, 'advanced_analytics')`; free users keep the existing `UpgradeGate`).
2. A new **Conversion Funnel** card renders below the existing stat cards, using the page's existing `7/30/90/365` day range selector.
3. The card shows a horizontal/vertical funnel: **Scans → Actions → (Phase 2) Revenue**, each bar labeled with its count, the **% of previous step**, and the **drop-off %** between steps. The headline KPI is **overall conversion rate** (actions ÷ scans **of action-capable QRs** — lead_form/list_links — so the rate isn't diluted by website/vcard scans; eng-review).
4. A breakdown toggle splits **Actions** into its real sources: *form submits*, *link clicks*. Pixel-enabled scans render as a separate **retargetable reach** stat beside the funnel, not as an action (a pixel firing on render is the scan, not a user action; eng-review).
5. The previously-dead **"Download CSV"** button (no `onClick` today) is wired to `GET …/analytics/funnel?format=csv`.
6. The mock `repeatVisitorRate` / `scanSuccessRate` tiles are replaced by **conversion rate** and **drop-off %** real values (retires `mockAnalyticsData.ts` usage on this page).

**6.2 Per-QR mini-funnel — QR detail overview tab (`QRDetails.tsx`)**
1. On the overview tab of a `lead_form` or `list_links` QR, a compact **Conversion** card renders beside the existing `QRAnalyticsCard` (mirrors how `ABResultsCard` conditionally renders for `type === 'website'`).
2. For `lead_form`: **scanned → submitted** two-step funnel + conversion %. For `list_links`: **scanned → clicked any link** + per-link CTR list.
3. Hidden for QR types with no action step (static types, plain `website` redirects).

**6.3 Leads dashboard enrichment — `/leads` (`LeadsClient`)**
- The flat submissions table gains a **conversion-rate header stat** (submissions ÷ scans for the selected form QR) and a small sparkline, addressing the audit's "flat table only" gap.

**6.4 Phase-2 revenue setup — `settings/` → new "Revenue" section (Agency)**
1. Agency owner opens **Settings → Revenue** (gated by `revenue_attribution`, rendered conditionally like the existing Branding/Pixels sections).
2. Connects **Stripe** (webhook signing secret) or **Shopify** (webhook). Instructions mirror the custom-domain DNS-instructions UX.
3. Once connected, the funnel gains a **Revenue** step and the workspace funnel shows **revenue / total** and **revenue-per-scan**.

## 7. Scope

**In scope (v1 / Phase 1 — no edge changes)**
- `GET /workspaces/{id}/analytics/funnel?range=&qr_id=` aggregate endpoint (BE).
- Workspace funnel card + per-QR mini-funnel + Leads conversion stat (FE).
- CSV export of the funnel (wires the dead button).
- Same-session join keyed on `short_code` + same-day `session_id` (see §11 unifying-key decision).
- `advanced_analytics` gate reused; `FEATURE_ENFORCEMENT` already enforced (no flip needed for Phase 1).

**Out of scope / Future**
- Phase 2: `revenue_attribution` flag + Stripe/Shopify webhooks + revenue step (Agency).
- Cross-day / cross-device attribution (blocked by daily-rotated `session_id`).
- Configurable multi-step funnel goals / custom events.
- UTM/source attribution within the funnel (needs new edge capture — separate PRD).
- Pixel **conversion** events via Meta CAPI / Google server-side.
- Scheduled weekly funnel email (the other dead button) — *(future, ties to lifecycle-email gap)*.
- Real-time streaming.

## 8. Pricing & Packaging

| Surface | Tier | Flag |
|---|---|---|
| Workspace + per-QR funnel, drop-off %, conversion rate, CSV export | **Pro & Agency** | `advanced_analytics` (existing, already enforced in `scan.py`) |
| Phase-2 Stripe/Shopify **revenue attribution** step | **Agency only** | `revenue_attribution` (NEW bool) |

- **Why reuse `advanced_analytics` for the funnel:** it already gates `/analytics`; the funnel is the new centerpiece of that page. No new flag, no new gate function, minimal migration surface for Phase 1 (only `dynamic_qr_types`/seed parity needs no change since no new QR type is added).
- **Why a new `revenue_attribution` flag for Phase 2:** revenue/ROAS is the premium-of-premium signal and the clearest Agency upsell — it justifies the 2.5× Pro→Agency jump for performance shops. Seeded `false` everywhere by migration 0009; `0016` flips Agency on; register in `FEATURE_ENFORCEMENT` as `inert` until the Phase-2 PR flips it `enforced` (coverage test enforces parity).
- **Upsell angle:** Free users see the funnel card behind the existing `UpgradeGate` → "See your scan-to-conversion rate. Upgrade to Pro." Pro users on the funnel see a **Revenue** step teaser → "Tie scans to real revenue. Upgrade to Agency." This is a clean two-step upgrade ladder built into one surface.

## 9. Success Metrics & KPIs

**Activation (first 30 days post-GA)**
- ≥ 55% of Pro/Agency workspaces with ≥1 `lead_form` or `list_links` QR view the funnel card at least once.
- ≥ 25% of those export the funnel CSV at least once (proxy for "used in a report").

**Adoption / engagement**
- Median Analytics-page sessions/week per Pro workspace **+30%** vs the pre-funnel baseline (funnel is a return-visit driver).
- ≥ 40% of QR-detail views on `lead_form` QRs interact with the mini-funnel.

**Revenue / retention signals**
- Pro→Agency upgrade rate **+15%** among workspaces that viewed the Phase-1 Revenue-step teaser (vs non-viewers).
- Pro-tier **logo churn −10%** among workspaces that exported the funnel ≥2× in a month (attribution = switching cost hypothesis).
- Phase 2: ≥ 20 Agency workspaces connect Stripe/Shopify within 60 days of revenue GA.

**Quality / trust**
- Funnel conversion-rate values reconcile within **±2%** of a manual `qr_scan_events` vs `qr_lead_submissions` spot-check (no double-count, no orphan attribution).
- Funnel endpoint p95 latency < 600ms for a 90-day window (with the 60s cache).

## 10. Rollout Plan

**Phase 0 — Aggregate query + endpoint (internal)**
- Build `GET …/analytics/funnel`; validate counts against a hand-computed spreadsheet on a seed workspace. Behind `advanced_analytics`. No FE.

**Phase 1 — Funnel UI (Pro+, GA-able)**
- Workspace funnel card, per-QR mini-funnel, Leads conversion stat, CSV export. Replace mock tiles. Ship behind a FE feature flag (env/constant) for a 1-week internal + design-partner beta (3–5 agencies from the Pro base), then flip GA.
- **Acceptance:** a Pro workspace with a lead-form QR sees scan→submit→drop-off %; a `list_links` QR shows scan→click CTR; numbers reconcile ±2% with raw tables; CSV downloads; free users see the upgrade gate; non-Pro `GET /funnel` returns 403.

**Phase 2 — Revenue attribution (Agency)**
- Add `revenue_attribution` flag (`0016` already seeds it; flip `FEATURE_ENFORCEMENT` inert→enforced here), Stripe + Shopify webhook handlers (mirror `razorpay_routes.py` / `mor_routes.py` signature-guarded public-webhook pattern, excluded from Bearer middleware), Settings→Revenue section, revenue funnel step.
- **Acceptance:** an Agency connects Stripe; a test checkout with a matching scan session shows as revenue tied to that scan's QR; revenue-per-scan renders; Pro sees the upsell teaser.

**Phase 3 — Future:** configurable goals, UTM dimension, CAPI conversion events, scheduled funnel email.

## 11. Risks, Edge Cases & Open Questions

**R1 — Unifying key for form VIEW vs SUBMIT (known risk).** Lead-form submissions **deliberately skip `recordScan`** (`POST /lead-submit/:sc` never calls `recordScan`), so a form *view* (the scan) and a form *submit* are written by two different pathways. **Decision (D1):** join on **`short_code` + same-day `session_id`** — the scan writes `session_id` to `qr_scan_events`; the worker must pass the same `session_id` (or its inputs IP+UA) into the `/internal/lead-submit` body so the submission can be stamped with it. This requires a **small worker change** (thread `session_id` into the lead-submit POST) and a `session_id` column on `qr_lead_submissions` (migration `0016`). Without it, the funnel can only report aggregate ratio (total submits ÷ total scans), not per-session join. **Recommend:** ship aggregate-ratio in Phase 1.0 (no worker change), add per-session join in Phase 1.1 (worker change). Aggregate ratio is honest and unblocks GA.

**R2 — Daily-rotated session_id caps attribution (known risk).** `session_id = SHA-256(IP+UA+today)` rotates at UTC midnight, so a scan at 23:58 and a submit at 00:02 look like different sessions. Phase 1 is **explicitly same-session/same-day**; we document this and accept a small undercount at day boundaries. Cross-day attribution is out of scope.

**R3 — Link clicks lack session context.** `handlers/linkClick.js` POSTs only a timestamp to `/internal/link-click/:link_id` — no `session_id`, no geo/device. So `list_links` "scan → click" can only be **aggregate-ratio** (total clicks ÷ total scans) in Phase 1 unless we thread `session_id` into the click POST too (same small worker change as R1).

**R4 — Double-count / inflated denominators.** Bots are flagged (`device_type === 'bot'`) but still recorded; the funnel should offer a "exclude bots" default to avoid a deflated conversion rate. Decide default on/off.

**R5 — Revenue webhook spoofing (Phase 2).** Stripe/Shopify webhooks must be HMAC-signature-verified (like `razorpay_routes` / `mor_routes`) and excluded from Bearer middleware; never trust an unverified `amount`.

**R6 — Counter source: events vs counters.** `qr_scan_counters` JSONB is the cheap denominator but it's a **non-atomic read-modify-write** (audit-flagged increment loss). For funnel accuracy, count scans from `qr_scan_events` rows within range, not the denormalized counter. Confirm the events table is retained long enough (no TTL purge job exists today — a latent advantage here).

**Open Questions**
1. Aggregate-ratio-only at GA (no worker change) vs per-session join from day one (worker change)? *Recommend aggregate first.*
2. Exclude bots from the denominator by default? *Recommend yes.*
3. Phase-2 revenue match key: same `session_id`, or a `client_reference_id`/metadata stamped at checkout (more reliable but requires the merchant to pass it)? *Recommend metadata-based when available, session fallback.*
4. Should the funnel respect `analytics_retention_days` clamp (Pro = 30/90/365)? *Recommend yes — reuse the existing `get_limit()` clamp in `scan.py`.*

## 12. Dependencies

- **Lead Capture (shipped):** `qr_lead_submissions` table + `/internal/lead-submit` — the form-submit action source. Needs migration `0012` applied.
- **Retargeting Pixels (shipped):** the `pixels` KV key — informs the "pixel-rendered page" action source. Migration `0013` applied.
- **Link-click tracking (shipped):** `handlers/linkClick.js` + `/internal/link-click/:link_id` — the link-click action source.
- **Scan pipeline (shipped):** `qr_scan_events` (raw rows with `session_id`, `short_code`) + `qr_scan_counters` — the scan denominator. `recordScan` in `qr_cf_code/src/utils/scan.js`.
- **Gating engine (shipped):** `advanced_analytics` already enforced in `scan.py`; `canAccessFeature` in `src/lib/plan-features.ts`; `FEATURE_ENFORCEMENT` registry in `subscription.py`.
- **Analytics UI surface (shipped):** `/analytics` page + `useAnalytics*` hooks; `QRDetails.tsx` overview tab; `LeadsClient`.
- **Phase 2 only:** Stripe + Shopify accounts/webhook secrets; new webhook routes parallel to `razorpay_routes.py`; migration `0016` `revenue_attribution` flag + a `qr_revenue_events` table; Settings→Revenue UI.
- **Migration `0016`** (slot 0016 in the 0014–0018 roadmap sequence): Phase 1.0/1.1 schema only — adds `session_id` to `qr_lead_submissions` (R1 join), the `qr_link_click_events` table (R3), the `qr_scan_events(qr_id, scanned_at)` index (R6), and seeds the `revenue_attribution` flag (for coverage parity). The **revenue TABLES (`qr_revenue_events`, `workspace_revenue_connections`) split to a separate Phase-2 migration** (eng-review). Begin/Commit-wrapped, idempotent.

### Appendix — Key Files

| Concern | File |
|---|---|
| Funnel aggregate endpoint + gate | `qr_backend/src/api/routes/scan.py` (new `/analytics/funnel`, reuse `_require_advanced_analytics`, `get_limit` clamp) |
| Scan events / counters source | `qr_backend` `qr_scan_events`, `qr_scan_counters`; ingestion in `src/api/routes/internal.py` (`POST /scans`) |
| Action sources | `qr_lead_submissions` (`/internal/lead-submit`), link clicks (`/internal/link-click/:id`) |
| Worker session threading (R1/R3) | `qr_cf_code/src/handlers/linkClick.js`, lead-submit handler in `src/index.js`, `src/utils/scan.js` |
| Workspace funnel UI | `qr_frontend/src/app/org/[slug]/(dash)/analytics/page.tsx`, `src/components/org/analytics/`, new `useAnalyticsFunnel` hook in `src/hooks/useAnalytics.ts` |
| Per-QR mini-funnel | `qr_frontend/src/components/org/qrs/QRDetails.tsx`, `.../details/` |
| Leads conversion stat | `qr_frontend/src/app/org/[slug]/(dash)/leads/` (`LeadsClient`) |
| Gating | `qr_backend/src/api/routes/subscription.py` (`FEATURE_ENFORCEMENT`), `qr_frontend/src/lib/plan-features.ts` |
| Phase-2 revenue webhooks | new `qr_backend/src/api/routes/stripe_routes.py` / `shopify_routes.py` (mirror `razorpay_routes.py`); Bearer-excluded in `main.py` |
| Migration | `qr_backend/migrations/0016_scan_conversion_funnel.sql` |
