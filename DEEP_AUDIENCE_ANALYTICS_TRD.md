# TRD — Deep Audience Analytics: OS/Browser + Geo Map + Hour Heatmap

**Status:** Draft · **Author:** Engineering (Staff) · **Date:** 2026-06-24
**Tiers / flags:** All three surfaces = **Pro & Agency** via the existing `advanced_analytics` flag, already `enforced` in `scan.py` (`FEATURE_ENFORCEMENT["advanced_analytics"] = "enforced"`, subscription.py line 439). **No new flag, no new entitlement, no `FEATURE_ENFORCEMENT` change.**
**Migration:** **NONE in Phase 1** (parse-on-read from `qr_scan_events`). Slot **0019** is reserved *only* for the optional Phase-2 counter-key perf path and is **not built** here. Current DB highest applied = `0013_retargeting_pixels.sql`; 0014–0018 reserved by the AI/funnel/report roadmap.
**Services touched:** `qr_backend` (new UA parser + 3 read endpoints), `qr_frontend` (3 cards + 3 hooks + 1 lazy map dep). **`qr_cf_code`: NO change** — UA, city, region, timezone, hour are already written by `recordScan`.
**Split from:** the parent `/org/[slug]/(dash)/analytics/page.tsx` surface and the per-QR `QRDetails.tsx` overview tab. Sibling of `SCAN_CONVERSION_FUNNEL_TRD.md`; both extend the same Pro-gated page without colliding (distinct cards, distinct hooks, distinct endpoints).

**Rev (2026-06-24, post eng-review):** Verified the key claims against the live tree (`advanced_analytics = "enforced"` confirmed subscription.py line 439; 0013 is the highest applied migration; `_fetch_windowed_events`/`_require_advanced_analytics`/`_retention_cutoff_iso` exist at the cited lines; scan.js writes all named fields). Four substantive corrections: (1) **§3.4 heatmap** — the live `/hourly` deliberately buckets **UTC** ("single, dependency-free source of truth", scan.py ~line 681); Phase-1 heatmap now buckets **UTC** too and reports `bucketed_by:"utc"`, with per-row `zoneinfo` IANA conversion (up to 50k/req) demoted to a Phase-2 option — it was both a real perf cost and a silent departure from the house decision. (2) **§5.4 / §9 per-QR truncation bug** — `_fetch_windowed_events` caps at **50k rows per workspace**; the per-QR compact path must push `.eq("qr_id", …)` into the query (not Python-filter a truncated workspace window), else a hot QR silently under-counts. (3) **§3.3** — `/top-countries` selects only `country_code` today (line 656); `city` is genuinely new read work. (4) **§7** clarified `?include_bots` default and the city-fold threshold constant. Migration posture confirmed correct: **zero migration in Phase 1**; slot 0019 reserved-but-unbuilt, ships only its own schema, no flag-flip (so the house `lower(name)+is_custom+coalesce` convention is N/A by construction), with a retained parse-on-read fallback for un-backfilled rows if Phase 2 is ever built.

---

## 1. Overview & Architecture

Qravio's edge worker stamps every scan into `qr_scan_events` with the raw `user_agent`, plus Cloudflare's `cf.city / region / country / timezone / latitude / longitude`, `device_type`, `language`, `referer_domain`, and `scanned_at` (confirmed in `qr_cf_code/src/utils/scan.js` lines 39–52). The analytics read-path (`qr_backend/src/api/routes/scan.py`) currently re-aggregates only four of those into `/devices` (4 device classes), `/top-countries` (country only — the FE hook `useAnalyticsGeographic` hits `/analytics/top-countries`), and `/hourly` (a flat 0–23 strip). OS, browser, city, and the day×hour pattern are present in the raw rows and discarded at read time.

This feature adds three premium read surfaces by **parsing/re-aggregating the raw rows** — the exact pattern `/devices` and `/top-countries` already use (`_fetch_windowed_events`, scan.py line 171). No new ingestion, no schema change, no Worker change, no counter keys.

**Services touched:**

| Concern | qr_backend | qr_frontend | qr_cf_code |
|---|---|---|---|
| OS/browser split | NEW `src/utilities/ua_parser.py` + `GET /analytics/platforms` | NEW `useAnalyticsPlatforms` hook + Platforms card | none |
| Geo map + city drill | extend `/analytics/top-countries` to accept `?country=XX` → cities | extend `useAnalyticsGeographic(limit, country)` + lazy map card | none |
| Day×hour heatmap | NEW `GET /analytics/heatmap` (7×24 matrix) | NEW `useAnalyticsHeatmap` hook + heatmap card | none |
| Per-QR compact insights | reuse the above endpoints | advanced-gated mini blocks in `QRDetails.tsx` | none |

**Phase-1 data flow (no new edge data):**
```
FE analytics page (Pro) ──authApi──▶ GET /analytics/platforms?workspace_id&range=30
  backend: _resolve_workspace → _require_advanced_analytics → _retention_cutoff_iso
         → _fetch_windowed_events(db, ws, cutoff, "user_agent")
         → ua_parser.parse(ua) per row → tally {os, browser, unknown}
         → PlatformsResponse
FE: GET /analytics/top-countries?country=IN  → city tally from the stored `city` field
FE: GET /analytics/heatmap                   → 7×24 matrix from `scanned_at` + `timezone`
```
All three read `qr_scan_events` rows (not the lossy `qr_scan_counters`), guaranteeing the ±1% reconciliation KPI. The map library is `next/dynamic({ ssr:false })` + intersection-triggered, so it adds 0 KB to the initial route chunk.

---

## 2. Data Model & Migrations

**No migration is required in Phase 1, and none is created.** Justification, point by point:

- **No new columns.** Every dimension we surface (`user_agent`, `city`, `region`, `country_code`, `timezone`, `scanned_at`) is already written by `recordScan` and already present on `qr_scan_events`.
- **No new counter keys.** We deliberately do **not** add `scans_by_os` / `scans_by_browser` to `qr_scan_counters`. Per the CLAUDE gotcha, `qr_scan_counters` is a non-atomic read-modify-write that can lose increments; and adding keys would leave all *historical* events un-bucketed until a backfill runs. Parse-on-read from raw events is correct for all history immediately (Decision **D1**).
- **No flag flip.** `advanced_analytics` is already `enforced`. The `test_feature_gate_coverage` registry↔seed parity test stays green untouched because we add no flag to `FEATURE_ENFORCEMENT` and no key to the plan seed.
- **Index sufficiency.** `_fetch_windowed_events` filters on `(workspace_id, scanned_at)`, served by the existing index from migration 0007. The Conversion-Funnel TRD (0016) adds the `(qr_id, scanned_at)` index for per-QR windowing; the per-QR compact insights here reuse that same per-QR aggregation pattern and benefit from it, but **do not depend on 0016**. **Important (R7):** the per-QR path pushes `.eq("qr_id", …)` into the DB query (an optional `qr_id` arg on `_fetch_windowed_events`), it does **not** Python-filter a workspace-wide window — the 50k cap is per-workspace, so Python-filtering would silently under-count a hot QR. The `(workspace_id, scanned_at)` index still serves the `qr_id`-narrowed scan; 0016's `(qr_id, scanned_at)` index only makes it tighter.

**RLS note:** all backend queries use the Supabase **service-role key**, which **bypasses RLS**. No policies are added. Tenant isolation is enforced in route code via `_resolve_workspace` + explicit `.eq("workspace_id", resolved_ws)` filters and, on the per-QR path, a `workspace_members` membership check (§9).

**Reserved slot 0019 (Phase 2 only, NOT built):** if `/platforms` p95 ever exceeds budget on very large workspaces, `migrations/0019_scans_by_platform.sql` would add `scans_by_os` / `scans_by_browser` JSONB keys to `qr_scan_counters` plus a one-time idempotent backfill, with parse-on-read retained as a fallback for un-backfilled rows. It would be `BEGIN/COMMIT`-wrapped, `IF NOT EXISTS`, and ship only that schema. It does **not** touch the plan seed (no flag change), so the house flag-flip convention is irrelevant to it. This is a measured, later decision.

---

## 3. Backend Design

All new/changed code lives in `qr_backend/src/api/routes/scan.py` (router prefix `/analytics`) and the new `qr_backend/src/utilities/ua_parser.py`. Every new endpoint clones the proven preamble:
```python
resolved_ws = _resolve_workspace(db, user_id, workspace_id)
await _require_advanced_analytics(resolved_ws, db)   # 403 if plan lacks advanced_analytics
cutoff = _retention_cutoff_iso(resolved_ws, db)      # clamps to analytics_retention_days
events = _fetch_windowed_events(db, resolved_ws, cutoff, "<columns>")
```

### 3.1 `src/utilities/ua_parser.py` (new, pure-Python, no network, no heavyweight dep)

A curated rule table mapping a raw UA string to `{os, browser}`. Pure-Python regex/substring rules — **no `ua-parser`/`user-agents` PyPI dependency** unless the rule table proves insufficient (R3). Signature:
```python
def parse_ua(user_agent: str | None) -> tuple[str, str]:
    """Return (os, browser). Each is a normalized label or 'Unknown'."""
```
- **OS labels:** `iOS, Android, Windows, macOS, Linux, ChromeOS, Other, Unknown`.
- **Browser labels:** `Safari, Chrome, Firefox, Edge, Samsung Internet, Opera, In-app browser, Other, Unknown`.
- **In-app webviews** (Instagram, FacebookApp/FBAN/FBAV, TikTok, Snapchat, LinkedInApp, Line, WhatsApp) are bucketed as **`In-app browser`** rather than mislabeled Chrome/Safari. Order matters: webview checks run **before** generic Chrome/Safari checks (in-app UAs embed `Safari`/`Chrome`).
- **Bots** are not a browser bucket; the existing `device_type='bot'` already separates them. We still parse their UA but they fall to `Other`/`Unknown` browser, and `/platforms` can optionally exclude `device_type='bot'` (see §8 contract).
- Helper `parse_platforms(rows) -> dict` tallies a list of event rows into `{os: {...}, browser: {...}}` with an explicit `Unknown` bucket; KPI caps `Unknown < 5%`.

Golden-fixture tests: ≥40 real UA strings (iOS Safari, iPadOS, Android Chrome, Samsung Internet, Instagram/FBAN/FBAV/TikTok in-app, Edge desktop+mobile, Firefox, Opera, Windows/macOS/Linux desktop, a Chrome-spoofing bot).

### 3.2 `GET /analytics/platforms` (new)

```python
class PlatformBucket(pydantic.BaseModel):
    name: str
    scans: int
    pct: float

class PlatformsResponse(pydantic.BaseModel):
    os: list[PlatformBucket]
    browser: list[PlatformBucket]
    total: int
    unknown_pct: float   # combined os+browser unknown share, for the <5% KPI
```
Reads `_fetch_windowed_events(db, ws, cutoff, "user_agent, device_type")`, parses each row via `parse_ua`, tallies, sorts desc, computes `pct`. Optional `?include_bots=false` (default) excludes `device_type='bot'` so the split reflects humans. Empty workspace → `{os: [], browser: [], total: 0, unknown_pct: 0.0}`.

### 3.3 `GET /analytics/top-countries?country=XX` (extended — city drill-down)

The existing endpoint (scan.py line 645) is extended, **not** broken: with no `country` param it returns the unchanged `List[CountryScanItem]` (country tally). When `?country=IN` is supplied it returns city counts for that country:
```python
class CityScanItem(pydantic.BaseModel):
    city: str          # "Other" for folded low-count cells
    scans: int

# response_model stays List[CountryScanItem] | List[CityScanItem] via a Union, OR
# (cleaner) a sibling endpoint GET /analytics/cities?country=XX returns List[CityScanItem].
```
**Decision:** add a sibling **`GET /analytics/cities?country=XX&limit=10`** rather than overloading `/top-countries`'s response shape — it keeps the existing FE `CountryScanItem[]` consumer and `useAnalyticsGeographic` typing stable (mirrors Q2's reasoning for not overloading `/hourly`). (Note: the live `/top-countries` selects **only** `country_code`, scan.py line 656 — `city` is on the row but not currently queried, so this is genuinely new read work, not "resurface an existing selection.") It reads `_fetch_windowed_events(db, ws, cutoff, "country_code, city")`, filters to the requested `country_code`, tallies `city`, and **folds cities with `n < 3` into "Other"** (R5; open-question recommendation, constant `_MIN_CITY_COUNT = 3`). Missing/empty city → "Unknown". `limit` is applied **after** the fold so the "Other" bucket isn't an artifact of truncating the top-N.

### 3.4 `GET /analytics/heatmap` (new — 7×24 matrix)

A **new** endpoint (not an extension of `/hourly`) so the existing flat `useAnalyticsHourly` consumer is untouched (Q2 recommendation).
```python
class HeatmapResponse(pydantic.BaseModel):
    matrix: list[list[int]]   # 7 rows (Mon..Sun, ISO Mon-first) × 24 cols (0..23)
    peak: dict | None         # {"dow": 5, "hour": 14, "scans": 88}  (or None when empty)
    bucketed_by: str          # Phase 1 always "utc"; "local" reserved for the Phase-2 tz option
```
Reads `_fetch_windowed_events(db, ws, cutoff, "scanned_at")`. **Phase 1 buckets by UTC hour**, matching the live `/hourly` decision (scan.py ~line 681 deliberately chose UTC as "a single, dependency-free source of truth" and rejected write-time local hour). `bucketed_by` reports `"utc"`. Per-row IANA-tz localization (parse `cf.timezone` → `zoneinfo.ZoneInfo` per row) is a **Phase-2 option only**: it would mean up to 50k `ZoneInfo` constructions/lookups per request and a deliberate departure from the existing house basis — neither justified for Phase 1 (R6). Day-of-week is **ISO Mon-first**, derived from the same UTC `datetime` (Q3 recommendation). `peak` is the single max cell for the card callout. (`timezone` is therefore **not** selected in Phase 1, keeping the row payload minimal.)

### 3.5 Gating wiring (no change to the registry)

Every new endpoint calls `await _require_advanced_analytics(resolved_ws, db)` (scan.py line 129), which calls the **async** `check_feature(ws, "advanced_analytics", db)`. Non-Pro → 403. Because `advanced_analytics` is already `enforced` in `FEATURE_ENFORCEMENT`, there is **no inert→enforced flip**, **no `build_entitlements` thread** (not edge-enforced), and **no seed change**. `test_feature_gate_coverage` stays green untouched.

---

## 4. Cloudflare Worker / Edge Design

**No Worker change.** This is a pure read-path feature. The Worker already writes everything we need:
- `user_agent` (raw) — `recordScan` line 48
- `city`, `region`, `country_code`, `timezone` — lines 39–43
- `device_type` — line 49, `scanned_at` — stamped on insert

No KV key additions (the ~11-key KV value is untouched), no `build_kv_content` / `build_entitlements` / `build_pixels` change, no new QR type (so the 7-step new-type checklist and the React↔Worker template-mirror rule are **N/A**), no `scheduled()` cron (so the **prod-Worker-deploy gate is explicitly N/A** — flagged so reviewers don't add a phantom `npm run deploy:prod` prerequisite). The consent gate (`consent.js`) is untouched: this feature surfaces no marketing tags and reads only already-collected data.

---

## 5. Frontend Design

All FE work is additive to the already-`advanced_analytics`-gated analytics page; the page-level gate at `analytics/page.tsx` **line 40** (`canAccessFeature(subscription, 'advanced_analytics')` → `AnalyticsUpgradeGate`, line 41) is unchanged and continues to fully gate the authenticated view. shadcn/ui primitives only, Tailwind tokens only (no inline styles), files ≤200 lines, one export per kebab-case file, react-hook-form not needed (read-only).

### 5.1 Hooks — `src/hooks/useAnalytics.ts`

Extend the `analyticsKeys` factory:
```ts
platforms: (range: number) => [...analyticsKeys.all, 'platforms', range] as const,
cities:    (country: string, limit: number) => [...analyticsKeys.all, 'cities', country, limit] as const,
heatmap:   (range: number) => [...analyticsKeys.all, 'heatmap', range] as const,
```
New hooks (all via `authApi` from `api-client.ts`, `staleTime: 60_000` to match the page):
- `useAnalyticsPlatforms(range = 30, workspaceId?)` → `GET /analytics/platforms?range&workspace_id`.
- `useAnalyticsHeatmap(range = 30, workspaceId?)` → `GET /analytics/heatmap`.
- Extend `useAnalyticsGeographic` to accept an optional `country`; when set it queries the new `useAnalyticsCities(country, limit, workspaceId?)` → `GET /analytics/cities?country=`. Keep the existing 0-arg call shape working (the country variant is a sibling hook so the typed `CountryScanItem[]` return of the original stays intact).

### 5.2 Components — `src/components/org/analytics/`

- **`platforms-card.tsx`** — two stacked horizontal-bar lists (OS, Browser) using shadcn primitives + Tailwind `bg-primary/…` (indigo `#4648d4`) and `tertiary` (cyan) for the secondary list. Fed by `useAnalyticsPlatforms`. Uses the page's existing 7/30/90/365 day selector value.
- **`geo-map-card.tsx`** — the **lazy** wrapper: `const WorldMap = dynamic(() => import('./world-map'), { ssr: false, loading: () => <MapSkeleton/> })`, mounted only after an `IntersectionObserver` (or a small in-view hook) reports the card in view, so its chunk never weights the initial route JS (KPI: 0 KB added). Default = choropleth colored by scan volume from `useAnalyticsGeographic()`. **Clicking a country** sets local `country` state → renders the country's `useAnalyticsCities` city list with a breadcrumb (`World ▸ India`) back to world view.
- **`world-map.tsx`** — the heavy renderer, isolated so only this module pulls the map dep.
- **`heatmap-card.tsx`** — a 7×24 CSS-grid (Tailwind `grid-cols-24`), cells shaded by relative volume (`bg-primary` with opacity steps), shadcn `HoverCard` per cell showing `{dow, hour, count}`, and a "Peak: Sat 2–5pm" callout from `peak`. Labels the tz basis from `bucketed_by`.

### 5.3 Map dependency (Q4 decision)

Add **`react-simple-maps`** (SVG choropleth, tree-shakeable, no canvas/WebGL) — smallest lazy chunk for a country-level choropleth with click handlers; it pairs with a static world-110m TopoJSON loaded inside the lazy chunk. It is imported **only** inside `world-map.tsx`, which is itself `next/dynamic`-loaded, so it is fully code-split off the initial route. `recharts` (already in `package.json`) is reused for the platforms bars; the heatmap is plain CSS grid (no new dep).

### 5.4 Per-QR compact insights — `src/components/org/qrs/QRDetails.tsx` (+ `.../details/`)

The overview tab's `QRAnalyticsCard` (fed by `GET /analytics/qrs/{id}`, intentionally not advanced-gated for the basic view) gains compact blocks **only when** `canAccessFeature(subscription, 'advanced_analytics')` is true — mirroring how `ABResultsCard` renders conditionally. These render: a one-line OS/browser split, a **city list** (no map — keeps the per-QR bundle light, R2), and a mini heatmap. They reuse the same three endpoints scoped per-QR via a `qr_id` query param added to `/platforms`, `/cities`, `/heatmap` (each accepts an optional `qr_id`; a `workspace_members` membership check on the QR's workspace runs first, mirroring `get_qr_analytics` scan.py line 407). **Truncation guard (R7):** the per-QR path must **not** fetch the workspace-wide window and Python-filter to `qr_id` — `_fetch_windowed_events` caps at 50k rows *per workspace*, so on a busy workspace a single QR's rows can fall outside the window and silently under-count. Instead, when `qr_id` is present, push the filter into the query so the 50k cap bounds *that QR's* rows. Concretely, add an optional `qr_id` arg to `_fetch_windowed_events` that appends `.eq("qr_id", qr_id)` before the range scan (the existing `(qr_id, scanned_at)` index from the Funnel TRD's 0016 helps but is not required — the `(workspace_id, scanned_at)` index still serves it). This is the single backend code change beyond the three new endpoints.

### 5.5 Gate copy + privacy line

`AnalyticsUpgradeGate` copy is updated to name the three views ("OS & browser, an interactive geo map with city drill-down, and a scan-time heatmap"). A privacy line is added to the gate and the public pricing/feature page: *"Cookieless by design — scan analytics use a daily-rotating anonymous hash, so no consent banner is required in the EU."* (copy only; references the existing `session_id = SHA-256(IP+UA+today)` model, no code).

No `PlanFeatures` interface change (we reuse `advanced_analytics: boolean`, already at useSubscription.ts line 43).

---

## 6. AI / External-Service Integration

**None.** No Claude/Anthropic call, no Resend email (so the `_dmarc.qravio.app` DMARC GA-gate is **N/A**), no WeasyPrint/PDF, no webhook. The UA parser is pure-Python and runs backend-side on read — explicitly **never on the Worker scan hot path**. AI narratives over these dimensions belong to `AI_SCAN_ANALYST` (slot 0014), a separate spec.

---

## 7. API Contracts

All endpoints: `GET`, Bearer-authed (not in `excluded_routes`), `?workspace_id` optional (resolved to the caller's owned workspace when absent), `?range` clamped to `analytics_retention_days`, 403 for non-Pro, optional `?qr_id` for per-QR scoping.

**`GET /analytics/platforms?workspace_id=…&range=30&include_bots=false`**
```json
{
  "os": [
    {"name": "iOS", "scans": 612, "pct": 51.0},
    {"name": "Android", "scans": 540, "pct": 45.0},
    {"name": "Windows", "scans": 36, "pct": 3.0},
    {"name": "Unknown", "scans": 12, "pct": 1.0}
  ],
  "browser": [
    {"name": "Safari", "scans": 590, "pct": 49.2},
    {"name": "Chrome", "scans": 430, "pct": 35.8},
    {"name": "In-app browser", "scans": 150, "pct": 12.5},
    {"name": "Samsung Internet", "scans": 18, "pct": 1.5}
  ],
  "total": 1200,
  "unknown_pct": 1.8
}
```

**`GET /analytics/cities?country=IN&limit=10&range=30`**
```json
[
  {"city": "Mumbai", "scans": 412},
  {"city": "Pune", "scans": 188},
  {"city": "Other", "scans": 9}
]
```

**`GET /analytics/heatmap?range=30`**
```json
{
  "matrix": [[0,0,1,2,...24 ints], ...7 rows Mon..Sun],
  "peak": {"dow": 5, "hour": 14, "scans": 88},
  "bucketed_by": "utc"
}
```
`/analytics/top-countries` (unchanged shape) continues to return `[{"country_code":"IN","scans":450}, ...]`.

---

## 8. Security, Privacy & Abuse

- **Auth & tenant isolation:** Bearer-authed; `_resolve_workspace` + explicit `.eq("workspace_id", resolved_ws)` on every query (service role bypasses RLS, so the explicit filter is the *only* isolation — never trust RLS here). Per-QR scoping additionally verifies `workspace_members` membership for the QR's workspace before aggregating (same pattern as `get_qr_analytics`, scan.py line 407).
- **Plan gate:** `_require_advanced_analytics` on every new endpoint; non-Pro → 403.
- **PII (STRICT, R5):** `qr_scan_events` holds `ip_hash`, exact `latitude/longitude`, and the **raw** `user_agent`. **None** of these reaches any user-facing surface. We expose only aggregated non-identifying buckets: OS name, browser name, country, city name, hour-of-week counts. No exact map pins (city-centroid choropleth only — `latitude/longitude` are never returned), no raw UA strings, no IP. **Low-count city suppression:** cities with `n < 3` fold into "Other" to prevent re-identification in low-volume workspaces.
- **Abuse / DoS:** `_fetch_windowed_events` is capped at `_MAX_WINDOW_EVENTS = 50000` rows **per workspace** and logs (never crashes) on overflow — bounding the parse cost of a malicious wide window. Note this is a *truncation*, not an error: on overflow the aggregate is approximate (the existing `/devices`/`/top-countries` share this), and the per-QR path must narrow the query by `qr_id` so the cap applies to that QR, not the whole workspace (R7, §5.4). TanStack `staleTime: 60_000` plus the page's date selector bound request frequency. No new public endpoint, no webhook (no SSRF/HMAC surface). Consent gate untouched (no marketing tags introduced).

---

## 9. Performance, Scale & Cost

- **Read-path cost:** `/platforms` parses up to 50k UA strings in pure Python per request; regex-based `parse_ua` is O(rules) per row — well under the p95 < 600ms budget for a 90-day window on typical workspaces. The map and heatmap aggregate the same windowed rows. Budget verified on a seed workspace in Phase 0.
- **Bundle:** the map dep is fully code-split via `next/dynamic({ssr:false})` + intersection load — KPI: **0 KB** added to the initial analytics-route JS; LCP regression < 100 ms. The per-QR detail page ships a city **list**, not the map, so it pulls no map dep.
- **DB load:** reuses the existing `(workspace_id, scanned_at)` index (migration 0007); no new index in Phase 1. No counter writes (zero scan-hot-path cost — the Worker is unchanged).
- **Reconciliation:** reading raw `qr_scan_events` (not the lossy counter) guarantees the ±1% KPI vs a manual row count for the same window.
- **Phase-2 escape hatch:** only if `/platforms` p95 blows budget at scale do we add the 0019 counter keys + backfill (with parse-on-read fallback). Not built speculatively.

---

## 10. Testing Strategy

- **pytest (backend):**
  - `test_ua_parser.py` — golden-fixture set (≥40 real UAs) asserting exact `{os, browser}` including in-app webviews bucketed as "In-app browser"; asserts `Unknown < 5%` over the corpus.
  - `test_analytics_platforms.py` / `_cities.py` / `_heatmap.py` — seed `qr_scan_events`, assert counts reconcile ±1% with a hand-computed tally; assert 403 for a non-Pro workspace; assert retention clamp (rows outside `analytics_retention_days` excluded); assert heatmap `bucketed_by == "utc"` and the matrix uses UTC hour; assert `n<3` city folding into "Other" (and `limit` applied post-fold); assert per-QR `qr_id` scoping + membership 403; **assert the per-QR path filters in the query** — seed >50k workspace rows but only a handful for the target `qr_id` and confirm the per-QR count is exact, not truncated (R7).
  - `test_feature_gate_coverage` — **stays green untouched** (no flag/seed change asserted).
- **Vitest (frontend):** unit-test the three hooks and the heatmap cell shading; the **~29 pre-existing FE test failures are the documented baseline** — verify no *new* failures, do not attempt to fix the baseline.
- **Playwright (E2E):** Pro user sees the three cards; clicking a country shows its cities + breadcrumb back; heatmap renders 7×24 and honors the range selector; non-Pro sees the upgrade gate.
- **Worker tests:** none changed (no Worker change).
- **Bundle assertion:** a build-time check (or manual `next build` analyze) confirming the map chunk is a separate async chunk, not in the route's initial JS.

---

## 11. Observability & Rollout

**No DMARC gate (no email), no prod-Worker-deploy gate (no cron, no Worker change)** — both explicitly N/A so reviewers don't add phantom prerequisites.

- **Phase 0 — Parser + endpoints (internal, no UI):** ship `ua_parser.py` + golden tests, `/platforms`, `/cities`, `/heatmap`, all behind `advanced_analytics`. Validate counts against hand-computed numbers on a seed workspace. **No migration created.** Deploy backend (Render) only.
- **Phase 1 — UI (Pro+, GA-able):** lazy map + drill-down, heatmap, platforms card, per-QR compact insights, three hooks. Ship behind a FE constant flag for a 1-week internal + 3–5 Pro design-partner beta, then flip GA. **Deploy order: backend first (Render), then frontend (Vercel)** — the FE depends on the new endpoints existing.
- **GA acceptance gates:** OS/browser splits with `Unknown < 5%` on a 30-day prod sample; clicking a country shows its cities; heatmap shows a 7×24 grid honoring the range; all three honor `analytics_retention_days`; non-Pro `GET /platforms` returns 403; the map chunk is confirmed lazy (no route-JS regression); counts reconcile ±1% with raw `qr_scan_events`.
- **Observability:** the existing `_fetch_windowed_events` cap-hit `logger.warning` covers wide-window truncation. Add a debug log of `unknown_pct` per `/platforms` call to track parser coverage drift over time. New-endpoint p95 watched against the < 600 ms budget; if breached at scale → trigger the Phase-2 0019 decision.

---

## 12. Open Technical Questions & Risks

- **R1 (avoided):** new counter keys raise a backfill question → **Phase 1 parse-on-read, no migration** (D1). Counter keys are a measured Phase-2-only option (slot 0019).
- **R2:** map bundle weight → `next/dynamic({ssr:false})` + intersection load + skeleton; per-QR page uses a city list, not a map.
- **R3:** UA parsing accuracy / in-app webviews → curated rule table, explicit `Unknown` bucket, golden fixtures, `Unknown < 5%` KPI, webview-before-generic ordering; no heavyweight dep unless the table proves insufficient.
- **R4:** counter-vs-events denominator → all aggregates read raw `qr_scan_events`, never the lossy counter (±1% KPI).
- **R5:** PII on the surface → only aggregated buckets; `n<3` city folding; no pins, no raw UA, no IP/lat-long.
- **R6:** heatmap timezone semantics → Phase 1 buckets **UTC** (consistent with the live `/hourly` decision; `bucketed_by:"utc"`); per-row IANA-tz localization is a measured Phase-2 option (avoids 50k `zoneinfo` conversions/req).
- **R7 (NEW):** per-QR compact path must push `.eq("qr_id", …)` into the query, not Python-filter a 50k-per-workspace-capped window (else a hot QR silently under-counts). §5.4.

**Open questions (with recommendations baked in above):** (1) low-count city threshold → **n<3 → "Other"**; (2) extend `/hourly` vs new endpoint → **new `/heatmap` + new `/cities`** (keep existing flat consumers stable); (3) day-of-week order → **ISO Mon-first**; (4) map dep → **`react-simple-maps`** SVG choropleth (smallest lazy chunk).

### Appendix — Key Files

| Concern | File |
|---|---|
| UA parser (new, read-time) | `qr_backend/src/utilities/ua_parser.py` (+ `tests/test_ua_parser.py`) |
| OS/browser endpoint (new) | `qr_backend/src/api/routes/scan.py` — `GET /analytics/platforms` |
| City drill-down (new sibling) | `qr_backend/src/api/routes/scan.py` — `GET /analytics/cities?country=` |
| Heatmap (new) | `qr_backend/src/api/routes/scan.py` — `GET /analytics/heatmap` |
| Scan-event source (no change) | `qr_cf_code/src/utils/scan.js` (`recordScan`, lines 39–52) |
| Gate helper (reuse) | `qr_backend/src/api/routes/scan.py` — `_require_advanced_analytics` (line 129) |
| Windowing (reuse) | `qr_backend/src/api/routes/scan.py` — `_fetch_windowed_events` (line 171), `_retention_cutoff_iso` |
| Hooks + keys | `qr_frontend/src/hooks/useAnalytics.ts` — `analyticsKeys`, `useAnalyticsPlatforms`/`useAnalyticsCities`/`useAnalyticsHeatmap` |
| Cards | `qr_frontend/src/components/org/analytics/{platforms-card,geo-map-card,world-map,heatmap-card}.tsx` |
| Page | `qr_frontend/src/app/org/[slug]/(dash)/analytics/page.tsx` (gate line 40, existing analytics hooks lines 75–78) |
| Per-QR compact | `qr_frontend/src/components/org/qrs/QRDetails.tsx` (+ `.../details/`) — advanced-gated |
| Map dep (lazy) | `qr_frontend/package.json` (+ `react-simple-maps`), code-split via `next/dynamic` |
| Gating (reuse, no change) | `qr_backend/src/api/routes/subscription.py` (`FEATURE_ENFORCEMENT` line 439 — untouched); `qr_frontend/src/lib/plan-features.ts` |
| Migration | **None (Phase 1).** Phase-2-only: `qr_backend/migrations/0019_scans_by_platform.sql` if counter keys are added |
