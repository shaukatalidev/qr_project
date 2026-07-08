# PRD — Deep Audience Analytics: OS/Browser + Geo Map + Hour Heatmap

**Status:** Draft · **Author:** Product · **Date:** 2026-06-24
**Priority:** 2nd of the post-coming-soon analytics wave — the "richer audience picture" companion to the Conversion Funnel. Cheapest high-value item in the analytics backlog (mostly read-path; likely zero migration).
**Tiers:** Pro & Agency, behind the existing `advanced_analytics` flag (already enforced in `scan.py`). No new flag, no new gate function.
**Plan flags:** `advanced_analytics` (bool, **existing, already enforced** — reused). No new entitlement introduced by this feature.
**Split from:** the parent analytics surface (`/org/[slug]/(dash)/analytics/page.tsx`) and the per-QR detail overview (`QRDetails.tsx`). Sibling of `SCAN_CONVERSION_FUNNEL_PRD.md`; both extend the same Pro-gated analytics page without colliding.

**Rev (2026-06-24, post eng-review):** Tightened three accuracy claims against the live code. (1) §2 reworded — `city` is **not** currently selected by `/top-countries` (it selects only `country_code`, scan.py line 656); the city dimension is genuinely new read-path work, not "selected but unreturned." (2) §11 R6 / §6 corrected — the live `/hourly` deliberately buckets by **UTC** ("a single, dependency-free source of truth", scan.py line ~681); the heatmap therefore inherits that UTC basis by default and per-row IANA-tz conversion is downgraded to a **Phase-2 option** (50k `zoneinfo` conversions/request is real cost and diverges from the house decision). (3) Per-QR endpoint path corrected to `GET /analytics/qrs/{id}`. (4) Added R7: the per-QR compact path must **not** reuse the workspace-level 50k-capped `_fetch_windowed_events` directly (a hot QR can be truncated out of the workspace window → silent under-count); it must read per-QR counters or a `qr_id`-filtered query. (5) Slot 0019 / parse-on-read reconciled: Phase 1 ships **zero migration**; 0019 is reserved-but-unbuilt for the Phase-2 counter path, which carries a retained parse-on-read fallback.

---

## 1. TL;DR / Summary

Qravio already captures, on **every scan**, the raw `user_agent` plus Cloudflare's `cf.city / region / country / timezone / latitude / longitude` into `qr_scan_events`. But the analytics page surfaces only **4 device classes** (`mobile / tablet / desktop / bot`), a **country-only** geo list, and a **flat 0–23 hour** strip. The richest dimensions we already store — **operating system, browser, city, and the day×hour pattern** — are sitting unused in the raw rows.

This PRD turns that latent data into three premium analytics surfaces on the existing `advanced_analytics`-gated page:

1. **OS & Browser breakdown** — parse the stored `user_agent` into OS (iOS/Android/Windows/macOS/Linux) and browser (Safari/Chrome/Firefox/Edge/Samsung/in-app webviews).
2. **Interactive geo map with city drill-down** — render the existing country counts on a world map; clicking a country drills into its top cities (the `city` field is already stored, just never surfaced).
3. **Day×hour heatmap** — a 7×24 grid showing *when* scans happen, built from the existing date + hour data.

**Phase 1 ships with parse-on-read from `qr_scan_events` — no migration, no backfill, no Worker change, no new counter keys.** The UA parser runs **backend-side on read** (never on the Worker scan hot path). A map library is **lazy-loaded** so it never weights the rest of the app. We also market our **cookieless daily-rotated session model** (`session_id = SHA-256(IP+UA+today)`) as a GDPR/ePrivacy-exempt advantage — copy, not code.

## 2. Problem & Motivation

**We collect rich audience data and throw most of it away at the read layer.** `recordScan` (`qr_cf_code/src/utils/scan.js`, line 16) writes `user_agent` (raw), `city`, `region`, `country_code`, `timezone`, `latitude`, `longitude`, and `device_type` on every scan. But the analytics endpoints in `qr_backend/src/api/routes/scan.py` only re-aggregate four of those: `/devices` (4 classes from `device_type`), `/top-countries` (country only — it selects **only** `country_code` today, scan.py line 656; `city` is stored on the row but never queried or returned), and `/hourly` (a flat 24-bucket strip, bucketed by **UTC** hour, with **no day-of-week dimension**). The single most valuable audience questions a marketer asks — *"iOS or Android? Which browser? Which cities? What day and hour do people actually scan?"* — are all answerable from data we already have and currently discard.

**Competitors lead with exactly these three views.** Bitly, Flowcode, and Beaconstac all front-load OS/browser splits, an interactive geo map with city drill-down, and a time-of-day heatmap in their paid analytics. A Pro buyer comparing Qravio to Bitly sees our country-only list and flat hour strip and reads it as "less mature," even though our *raw* data is identical. This is a perception-and-parity gap we can close cheaply.

**The seams already exist and are battle-tested.** `scan.py` already has the exact pattern we need: `_fetch_windowed_events(db, ws, cutoff_iso, columns)` (line 171) pulls raw `qr_scan_events` rows within the plan's `analytics_retention_days` window, and `/devices` (line 337) already re-aggregates a dimension *from raw events, not from the lossy counter*. The CLAUDE-documented gotcha — `qr_scan_counters` is a **non-atomic read-modify-write that can lose increments** — is already handled here by reading raw rows. We extend the same proven read-path with three more aggregations (OS, browser, city, day×hour). No new ingestion code, no new edge data.

**The map and heatmap also make the page feel alive.** The analytics page currently imports `mockScanSuccessRate` / `mockVisitorRatio` from `mockAnalyticsData.ts` and renders a flat country list. Replacing the flat list with an interactive map and adding a heatmap turns a static report into something a marketer returns to weekly — a retention driver, not a one-time glance.

## 3. Goals & Non-Goals

**Goals**
- A backend **UA parser** (`src/utilities/ua_parser.py`) that maps the raw `user_agent` to a normalized `{os, browser}` pair, with an explicit `unknown` bucket — run **on read**, never on the Worker.
- Two new (or extended) aggregate endpoints under `/workspaces/{id}/analytics`: **`/platforms`** (OS + browser splits) and an extended **`/geographic`** that returns **city drill-down** when a `country` filter is supplied; plus an extended **`/hourly`** (or new `/heatmap`) returning a **7×24 day×hour** matrix.
- An **interactive geo map** with country → city drill-down on the analytics page, **lazy-loaded** so it adds zero weight to first paint elsewhere.
- A **day×hour heatmap grid** (7 rows × 24 columns) with a peak-window callout.
- All three respect the existing `advanced_analytics` gate and the `analytics_retention_days` clamp.
- Market the cookieless daily-hash session model as a privacy advantage in upgrade/marketing copy.

**Non-Goals**
- **No new `qr_scan_counters` JSONB keys** in Phase 1 (parse-on-read avoids the backfill question entirely — see §11 R1). A counter-key optimization is an explicit Phase-2 *option*, not a commitment.
- **No Worker change.** UA, city, and hour are already written; we only read them differently.
- **No new edge dimensions** (no UTM, no exact GPS pin, no carrier/ASN surfacing) — those need new capture and are separate PRDs.
- **No raw-row / PII export** of IP, exact lat/long, or full user_agent strings on any user-facing surface — only aggregated, non-identifying buckets (see §11 R5).
- **No AI/LLM** in this feature. (AI summaries of these dimensions belong to `AI_SCAN_ANALYST` / slot 0014, separate.)
- No real-time streaming — query-on-load with the existing TanStack Query cache.

## 4. Target Users & Personas

| Persona | Who | Job-to-be-done | Today's pain |
|---|---|---|---|
| **Performance Marketer ("Priya")** | In-house growth at a D2C brand | Decide iOS-first vs Android-first creative; know which cities convert | Sees only "mobile 78%" — no OS, no city, no browser |
| **Agency Account Lead ("Marcus")** | Runs 30 client campaigns | Put a credible "audience" slide in the client deck | Country list + flat hour strip looks thin next to Bitly |
| **Event/Retail Ops ("Dev")** | Posters across multiple cities | Know which *city* drove scans and at what *hour* to staff/restock | No city drill-down; flat hour strip hides day-of-week patterns |
| **Privacy-conscious EU buyer** | Brand with a strict DPO | Buy analytics that don't need a cookie banner | Doesn't know Qravio's scan analytics are cookieless |

Primary buyer is the **Pro-tier marketer/agency** who already pays for `advanced_analytics` and wants the audience picture to match what they get from Bitly/Flowcode — a parity-and-retention play more than a new-revenue play.

## 5. User Stories

- As a **marketer**, I want an OS split (iOS vs Android) and a browser split, so I can prioritize creative and test the right in-app webviews.
- As an **agency lead**, I want to click a country on a map and see its top cities, so I can tell a client "62% of your scans came from Mumbai and Pune."
- As an **ops lead**, I want a day×hour heatmap, so I can see that scans peak Saturday 2–5pm and staff accordingly.
- As a **marketer**, I want the heatmap and map to honor my selected time range (7/30/90/365), so the picture matches the rest of the page.
- As a **free-tier user**, I want to see these cards teased behind the existing upgrade gate, so I understand what Pro unlocks.
- As an **EU buyer**, I want the page to state that scan analytics are cookieless and need no consent banner, so my DPO approves it.
- As a **Pro user on a slow connection**, I want the page to load fast even with a map, so the heavy map library only downloads when the map scrolls into view.

## 6. UX / Product Flow

**6.1 Workspace analytics page — `/org/[slug]/(dash)/analytics/page.tsx`**
The page already gates on `canAccessFeature(subscription, 'advanced_analytics')` (line 40) and renders `AnalyticsUpgradeGate` for free users; that stays. We add to the authenticated view:

1. **Platforms card (OS + Browser).** Two stacked horizontal-bar lists (or a donut + bar pair, shadcn/ui primitives only) fed by a new `useAnalyticsPlatforms()` hook → `GET …/analytics/platforms`. Reuses the page's existing `7/30/90/365` day selector.
2. **Interactive geo map** replaces (or sits above) the current flat country list. Default view = choropleth/bubble world map colored by scan volume, fed by the existing `useAnalyticsGeographic` data. **Clicking a country** drills in: the card swaps to that country's **top cities** (new `useAnalyticsGeographic(limit, country)` call). A breadcrumb ("World ▸ India") returns to the world view. The map component is **`next/dynamic` lazy-loaded with `ssr:false`** and a skeleton fallback, so its bundle (a lightweight SVG map lib, e.g. an `react-simple-maps`-class dependency — final choice in TRD) never blocks first paint.
3. **Day×hour heatmap** replaces/augments the current flat `HourlyScansChart`. A 7×24 grid (rows = Mon–Sun, columns = 0–23), each cell shaded by relative scan volume, with a hovercard showing the exact count and a "Peak: Sat 2–5pm" callout. Fed by `useAnalyticsHeatmap()` → extended `/hourly` (or new `/heatmap`).
4. The mock `mockScanSuccessRate` / `mockVisitorRatio` tiles are left to the Funnel PRD; this PRD does not depend on them.

**6.2 Per-QR detail — `QRDetails.tsx` overview tab**
The per-QR analytics card (`QRAnalyticsCard`, fed by `GET /analytics/qrs/{id}`, scan.py line 396 — intentionally **not** advanced-gated for the basic per-QR view; note the existing endpoint reads `qr_scan_counters`, so the new compact insights add a `qr_id`-scoped raw-event read, see §11 R7) gains a **compact** version of the same three insights *only when the workspace has `advanced_analytics`*: a small OS/browser line, a city list (no full map on the detail page to keep bundle light), and a mini heatmap. Mirrors how `ABResultsCard` conditionally renders.

**6.3 Upgrade gate & marketing copy**
`AnalyticsUpgradeGate` copy is updated to name the three new views ("OS & browser, an interactive geo map with city drill-down, and a scan-time heatmap"). The **public pricing/feature page** and the in-app gate add a privacy line: *"Cookieless by design — scan analytics use a daily-rotating anonymous hash, so no consent banner is required in the EU."* (copy only — references the existing `session_id` model; no code).

## 7. Scope

**In scope (v1 / Phase 1 — no migration, no Worker change)**
- `src/utilities/ua_parser.py` UA→{os, browser} normalizer + unit tests (golden UA-string fixtures).
- `GET …/analytics/platforms` (OS + browser splits, parse-on-read from `qr_scan_events`, retention-clamped).
- Extended `GET …/analytics/geographic?country=XX` for city drill-down (reuses the already-stored `city` field).
- Extended `GET …/analytics/hourly` → 7×24 matrix (or new `/heatmap` endpoint; TRD decides — extend if it doesn't break the existing flat consumer, else new endpoint).
- FE: lazy-loaded geo map with city drill-down, day×hour heatmap, platforms card; three new hooks in `useAnalytics.ts` with `analyticsKeys` factory entries.
- Per-QR compact insights on `QRDetails.tsx` (advanced-gated).
- `advanced_analytics` gate reused on every new endpoint via `_require_advanced_analytics` (line 129).

**Out of scope / Future**
- New `qr_scan_counters` keys (`scans_by_os` / `scans_by_browser`) as a read-perf optimization — **Phase 2 option** (needs a migration *and* a backfill answer; see §11 R1).
- Carrier/ASN, language-preference, and referer-domain surfacing (data partly exists; separate cards, separate PRD).
- Exact map pins from `latitude/longitude` (PII/precision risk — city-centroid only).
- Heatmap timezone localization (Phase 1 buckets by **UTC** hour, consistent with the live `/hourly`; per-row IANA-tz conversion is a Phase-2 option — see §11 R6).
- AI narrative of the audience dimensions (`AI_SCAN_ANALYST`, slot 0014).
- CSV/PDF export of these dimensions (ties into the dead export buttons — owned by the Funnel/Reports PRDs).

## 8. Pricing & Packaging

| Surface | Tier | Flag |
|---|---|---|
| OS/browser split, interactive geo map + city drill-down, day×hour heatmap (workspace + per-QR) | **Pro & Agency** | `advanced_analytics` (**existing, already enforced** in `scan.py`) |

- **Why reuse `advanced_analytics` and add no new flag:** these are *deeper cuts of the same analytics page* that flag already gates — `/devices`, `/geographic`, `/hourly`, `/top` all live behind `_require_advanced_analytics` today. Adding a flag would fracture one coherent surface and add migration/registry surface for no packaging benefit. **No migration, no `FEATURE_ENFORCEMENT` change, no seed-parity change** — the `test_feature_gate_coverage` registry↔seed parity test stays green untouched.
- **Upsell angle:** free/Starter users see the three new cards behind the existing `AnalyticsUpgradeGate`, now explicitly naming OS/browser, the city-drill map, and the heatmap — a richer, more concrete reason to reach Pro than "device, geographic, hourly" reads today.
- **Lifecycle (downgrade):** because nothing is edge-enforced (no `build_entitlements` thread, no KV change), a Pro→Free downgrade needs **no `resync_workspace_qrs`** — the gate is read-time only. The endpoints simply 403 after downgrade. This is strictly simpler than every prior coming-soon feature.

## 9. Success Metrics & KPIs

**Adoption (first 30 days post-GA)**
- ≥ 60% of Pro/Agency workspaces with ≥1 scan view the new Platforms or Map card at least once.
- ≥ 30% of those interact with the **city drill-down** (a click event), proving the map is more than decoration.
- ≥ 25% interact with the heatmap hovercards.

**Engagement / retention**
- Median Analytics-page sessions/week per Pro workspace **+20%** vs the pre-feature baseline (richer page = more return visits).
- Per-QR overview-tab views that scroll to the compact insights **+15%**.

**Quality / trust**
- OS/browser parser **`unknown` bucket < 5%** of parsed rows on a 30-day production sample (parser coverage check).
- Platform/city/heatmap counts reconcile within **±1%** of a manual `qr_scan_events` count for the same window (parse-on-read correctness; no counter drift since we read raw rows).
- Geo-map card **adds 0 KB to the initial JS bundle** of the analytics route (verified: chunk only loads on intersection); analytics route LCP regression < 100ms.
- New endpoints p95 < 600ms for a 90-day window.

## 10. Rollout Plan

**Phase 0 — Parser + endpoints (internal, no UI)**
- Build `ua_parser.py` with a golden-fixture test set (≥40 real UA strings incl. iOS Safari, Android Chrome, Samsung Internet, Instagram/Facebook in-app webviews, Edge, desktop). Build `/platforms`, extend `/geographic` (city), extend/add heatmap endpoint. All behind `advanced_analytics`. Validate counts against hand-computed numbers on a seed workspace. **No migration created** (parse-on-read).

**Phase 1 — UI (Pro+, GA-able)**
- Lazy-loaded map + drill-down, heatmap, platforms card, per-QR compact insights, three hooks. Ship behind a FE constant flag for a 1-week internal + 3–5 Pro design-partner beta, then flip GA.
- **GA gates / acceptance:** a Pro workspace sees OS/browser splits with `unknown` < 5%; clicking a country shows its cities; the heatmap shows a 7×24 grid honoring the date range; all three honor `analytics_retention_days`; non-Pro `GET /platforms` returns 403; the map chunk is confirmed lazy (no bundle regression on the route); counts reconcile ±1% with raw `qr_scan_events`.
- **Not gated on:** DMARC (this feature sends **no email**) and prod-Worker deploy (this feature adds **no cron and no Worker change**). Both explicitly N/A — flagged here so reviewers don't add phantom prerequisites.

**Phase 2 — Optional perf (only if read-path is too slow at scale)**
- *Only if* the parse-on-read `/platforms` p95 exceeds budget on large workspaces: add `scans_by_os` / `scans_by_browser` JSONB keys to `qr_scan_counters` in a **new migration (reserved slot 0019)** *plus* a one-time idempotent backfill that parses historical `user_agent`s, **and** a parse-on-read fallback retained for any pre-backfill rows. This is a deliberate, measured, later decision — not shipped speculatively.

## 11. Risks, Edge Cases & Open Questions

**R1 — New counter keys raise a backfill question (KNOWN RISK → avoided in Phase 1).** Adding `scans_by_os`/`scans_by_browser` to `qr_scan_counters` would (a) require a migration and (b) leave all *historical* events un-bucketed until a backfill runs. **Decision (D1): Phase 1 uses parse-on-read from `qr_scan_events` — no migration, no backfill, correct for all history immediately.** This mirrors the existing `/devices` endpoint, which already counts from raw events, not counters. Counter keys become a Phase-2 perf option only, with a retained parse-on-read fallback for un-backfilled rows.

**R2 — Map library bundle weight (KNOWN RISK).** A map renderer is heavy. **Mitigation:** `next/dynamic({ ssr: false })` with an intersection-triggered load and a skeleton; the chunk only downloads when the map scrolls into view. KPI verifies 0 KB added to initial route JS. The per-QR detail page uses a **city list, not a map**, to avoid shipping the map dependency there.

**R3 — UA parsing accuracy & in-app webviews.** Raw UA strings are messy: Instagram/Facebook/TikTok in-app browsers, Samsung Internet, bots spoofing Chrome. **Mitigation:** a curated rule table with an explicit `unknown` bucket; golden-fixture tests; KPI caps `unknown` < 5%. We bucket in-app webviews under a clear "In-app browser" label rather than mislabeling them Chrome/Safari. We avoid a heavyweight UA-parsing dependency unless the rule table proves insufficient (TRD decides; keep it pure-Python, no network).

**R4 — Counter vs events denominator.** Per the CLAUDE gotcha, `qr_scan_counters` is a lossy non-atomic RMW. All new aggregates **read `qr_scan_events` rows** within the retention window (via the existing `_fetch_windowed_events` pattern), never the counter — guaranteeing the ±1% reconciliation KPI.

**R5 — PII / privacy on the surface (STRICT).** `qr_scan_events` holds `ip_hash`, exact `latitude/longitude`, and raw `user_agent`. **None** of these may reach a user-facing surface. We expose only **aggregated, non-identifying buckets**: OS name, browser name, country, city name, and hour-of-week counts. No exact pins, no raw UA strings, no IP. City cells with very low counts (e.g. n<3) are folded into "Other" to prevent re-identification in low-volume workspaces (threshold TBD — open question).

**R6 — Heatmap timezone semantics.** The existing `/hourly` deliberately buckets by `scanned_at` **UTC** hour ("a single, dependency-free source of truth", scan.py line ~681), having explicitly *rejected* the write-time local hour the all-time counter used. **Decision (revised post eng-review):** Phase 1 heatmap buckets by **UTC** too, to stay consistent with `/hourly` and avoid 50k per-request `zoneinfo` conversions; `bucketed_by` reports `"utc"`. Per-row IANA-tz (`cf.timezone`) localization is a **Phase-2 option** (measured cost + a deliberate departure from the existing house decision), not Phase-1 work. The card labels the basis so the number is never silently misleading.

**R7 — Per-QR compact path must not silently truncate (NEW).** `_fetch_windowed_events` is capped at 50k rows **per workspace**. The per-QR compact insights must **not** fetch the workspace window and filter to one `qr_id` in Python — on a busy workspace a single QR's rows can fall outside the 50k window and silently under-count. **Decision (D7):** per-QR scoping pushes the `qr_id` filter into the query (`.eq("qr_id", …)`) so the 50k cap applies to that QR's rows, or reads the per-QR counter where exact reconciliation isn't required; it never relies on Python-filtering a workspace-wide truncated set.

**Open Questions**
1. Low-count city suppression threshold — n<3, n<5, or none? *Recommend n<3 → "Other".*
2. Extend `/hourly` to return the 7×24 matrix, or add a separate `/heatmap` endpoint to avoid changing the existing flat consumer's shape? *Recommend a new `/heatmap` to keep `/hourly` stable.*
3. Day-of-week ordering Mon-first (ISO) vs Sun-first (US)? *Recommend workspace-locale-agnostic Mon-first.*
4. Map dependency final pick (SVG choropleth vs bubble) — TRD, optimized for smallest lazy chunk.

## 12. Dependencies

- **Scan pipeline (shipped):** `qr_scan_events` raw rows with `user_agent`, `city`, `region`, `country_code`, `timezone`, `latitude`, `longitude`, `device_type`, `scanned_at` — written by `recordScan` in `qr_cf_code/src/utils/scan.js` (line 16). **No change needed.**
- **Analytics read-path (shipped):** `scan.py` — `_fetch_windowed_events` (line 171), `_require_advanced_analytics` (line 129), `get_limit(... 'analytics_retention_days')` clamp (lines 155/263), and the `/devices` parse-on-read precedent (line 337). New endpoints clone these patterns.
- **Gating engine (shipped):** `advanced_analytics` already enforced in `scan.py`; `canAccessFeature` in `src/lib/plan-features.ts`; `FEATURE_ENFORCEMENT` registry in `subscription.py` — **no change** (no new flag).
- **Analytics UI (shipped):** `analytics/page.tsx` (gate at line 40; day-range selector; existing `useAnalyticsGeographic`/`useAnalyticsHourly`/`useAnalyticsDevices` at lines 75-78), `QRDetails.tsx` overview tab, `useAnalytics.ts` (`analyticsKeys` factory), `country.ts` helpers (`countryCodeToFlag`, `COUNTRY_NAMES`).
- **New map dependency** (lazy-loaded, FE only) — single new npm dep, code-split, TRD-selected.
- **Migration:** **NONE in Phase 1.** Parse-on-read from `qr_scan_events` means no schema change, no new counter keys, no `FEATURE_ENFORCEMENT` flip, no seed change. A migration appears **only** if Phase 2 adds `scans_by_os`/`scans_by_browser` counter keys — reserved **slot 0019** (0014–0018 are taken by the AI/funnel/report roadmap specs), BEGIN/COMMIT-wrapped + `IF NOT EXISTS`, with the standard idempotent backfill, and explicitly *not built unless a measured perf need appears*.

### Appendix — Key Files

| Concern | File |
|---|---|
| UA parser (new, backend-side, read-time) | `qr_backend/src/utilities/ua_parser.py` (+ golden-fixture tests) |
| OS/browser endpoint (new) | `qr_backend/src/api/routes/scan.py` — `GET /platforms`, reuse `_fetch_windowed_events`, `_require_advanced_analytics`, retention clamp |
| Geo city drill-down (extend) | `qr_backend/src/api/routes/scan.py` — `/geographic?country=` returns city dimension from the already-stored `city` field |
| Heatmap endpoint (new/extend) | `qr_backend/src/api/routes/scan.py` — `/heatmap` 7×24 matrix from `qr_scan_events` (decision in §11 Q2) |
| Scan-event source (no change) | `qr_cf_code/src/utils/scan.js` (`recordScan`, line 16) — confirms UA/city/hour already written |
| Workspace analytics UI | `qr_frontend/src/app/org/[slug]/(dash)/analytics/page.tsx`; new `src/components/org/analytics/` map + heatmap + platforms cards |
| New hooks + keys | `qr_frontend/src/hooks/useAnalytics.ts` — `useAnalyticsPlatforms`, extended geo, `useAnalyticsHeatmap`; `analyticsKeys` factory entries |
| Per-QR compact insights | `qr_frontend/src/components/org/qrs/QRDetails.tsx` (+ `.../details/`) — advanced-gated |
| Map dependency (lazy) | `qr_frontend/package.json` (new dep) + `next/dynamic({ssr:false})` wrapper |
| Gating (reuse, no change) | `qr_backend/src/api/routes/subscription.py` (`FEATURE_ENFORCEMENT` — untouched), `qr_frontend/src/lib/plan-features.ts` |
| Migration | **None (Phase 1).** Phase-2-only: `qr_backend/migrations/0019_*.sql` if counter keys are added |
