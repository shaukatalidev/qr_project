# TRD — Scan→Action Conversion Funnel & Revenue Attribution

**Status:** Draft · **Author:** Engineering (Staff) · **Date:** 2026-06-24
**Priority:** 1st of the post-coming-soon analytics wave — the premium analytics wedge.
**Tiers / flags:** Funnel surface = **Pro & Agency** via the existing `advanced_analytics` flag (already `enforced` in `scan.py`). Phase-2 revenue attribution = **Agency-only** via a **NEW** `revenue_attribution` bool flag.
**Migration:** `0016_scan_conversion_funnel.sql` (slot 0016 in the 0014–0018 roadmap sequence; current DB highest is `0013_retargeting_pixels.sql`).
**Split from:** parent analytics surface (`/analytics`); extends Lead Capture (`0012`) + Retargeting Pixels (`0013`) + link-click tracking.
**Rev (2026-06-24, post eng-review):** (1) the conversion denominator is now **source-matched to scans of actionable QRs** (lead_form/list_links), not all-workspace scans, so the headline rate isn't diluted by website/vcard scans; (2) **pixel reach moved out of the Actions breakdown** into a separate `retargetable_reach` stat (it's the scan, not an action); (3) migration `0016` carries Phase 1.0/1.1 schema only — the **revenue tables split to a Phase-2 migration** (the `revenue_attribution` flag seed stays for coverage parity), and the missing `qr_scan_events(qr_id, scanned_at)` index is added; (4) `list_links` **`qr_id` is resolved backend-side from `link_id`** (no click-URL change). Added a forward-only note for `qr_link_click_events` and an end-to-end `session_id`-parity test.

---

## 1. Overview & Architecture

Qravio already counts scans (`qr_scan_events` + denormalized `qr_scan_counters`), captures lead submissions (`qr_lead_submissions`), and tracks list-link clicks (`/internal/link-click/{link_id}`). These live in silos. This feature joins them server-side into a **conversion funnel** (Scan → Action → [Phase 2] Revenue) with step counts, % of previous step, and drop-off %, surfaced on the existing Pro-gated `/analytics` page, on the per-QR detail overview tab, and on the Leads dashboard.

**Services touched:**

| Phase | qr_backend | qr_frontend | qr_cf_code |
|---|---|---|---|
| **1.0 (GA, no edge change)** | NEW `GET /analytics/funnel` aggregate + CSV; reuse `_require_advanced_analytics` + retention clamp | NEW funnel card, per-QR mini-funnel, Leads conversion stat, wire dead CSV button | none |
| **1.1 (per-session join)** | accept `session_id` on `/internal/lead-submit` + `/internal/link-click`; stamp it on the rows | none | thread `session_id` into the lead-submit + link-click POST bodies |
| **2 (Agency revenue)** | NEW `stripe_routes.py` + `shopify_routes.py` HMAC webhooks; `qr_revenue_events`; `revenue_attribution` flag flip; `build_entitlements` emits `revenue_attribution` | Settings→Revenue section; revenue funnel step | none |

**Phase-1.0 data flow (no new edge data):** FE calls `GET /workspaces?…/analytics/funnel?range=30&qr_id=<opt>` → backend resolves workspace, asserts `advanced_analytics`, clamps `range` to `analytics_retention_days` → counts scans from `qr_scan_events` (windowed) → counts actions from `qr_lead_submissions` (form submits) + `qr_link_items`/link-click counters (clicks) → computes drop-off → returns `FunnelResponse`. 60 s TanStack `staleTime` + a short backend in-process cache. `?format=csv` returns the same data as `text/csv`.

**Phase-1.1 per-session join:** the Worker threads the same `session_id` (`SHA-256(IP+UA+today)` truncated to 16 hex, already computed in `recordScan`) into the lead-submit and link-click POSTs. Backend stamps `session_id` on `qr_lead_submissions` / a new link-click events table, enabling true per-session join (`short_code` + same-day `session_id`).

---

## 2. Data Model & Migrations

**File:** `qr_backend/migrations/0016_scan_conversion_funnel.sql` — `BEGIN/COMMIT`-wrapped, idempotent (`IF NOT EXISTS`, `jsonb_set`). All backend queries use the Supabase **service role key**, which **bypasses RLS**, so no policies are added; tenant isolation is enforced in route code via workspace resolution + `workspace_members` checks (§8).

```sql
-- Migration 0016: Scan→Action Conversion Funnel (Phase 1.0/1.1 schema only).
-- Per eng-review, the Phase-2 revenue TABLES (qr_revenue_events,
-- workspace_revenue_connections) are split into a separate Phase-2 migration; see
-- below. The revenue_attribution FLAG is still seeded here so the coverage test
-- (test_feature_gate_coverage) has parity from day one.
BEGIN;

-- (R1) Per-session join key for form views vs submits. Lead submits skip recordScan,
-- so we stamp the scan's session_id (SHA-256(IP+UA+today), 16 hex) onto the submission.
ALTER TABLE qr_lead_submissions
    ADD COLUMN IF NOT EXISTS session_id text;
CREATE INDEX IF NOT EXISTS idx_lead_sub_session
    ON qr_lead_submissions (qr_id, session_id) WHERE session_id IS NOT NULL;

-- (R3) Link clicks today only POST a timestamp. Persist per-click rows so list_links
-- "scan→click" can join on session_id (Phase 1.1). FORWARD-ONLY: rows begin at the
-- 1.1 deploy; the existing lifetime per-link click counter stays the aggregate source.
CREATE TABLE IF NOT EXISTS qr_link_click_events (
    id           uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    link_id      uuid        NOT NULL REFERENCES qr_link_items(id) ON DELETE CASCADE,
    qr_id        uuid        REFERENCES qr_codes(id) ON DELETE CASCADE,
    workspace_id uuid,
    session_id   text,
    clicked_at   timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_link_click_qr_time
    ON qr_link_click_events (qr_id, clicked_at);
CREATE INDEX IF NOT EXISTS idx_link_click_session
    ON qr_link_click_events (qr_id, session_id) WHERE session_id IS NOT NULL;

-- (R6) The funnel denominator counts qr_scan_events ROWS (not the lossy counter),
-- so the windowed count needs an index (was referenced but missing from the DDL).
CREATE INDEX IF NOT EXISTS idx_scan_events_qr_time
    ON qr_scan_events (qr_id, scanned_at);

-- Plan flag (flag ONLY — the revenue tables ship in the Phase-2 migration):
-- seed revenue_attribution=false everywhere, then enable for Agency.
UPDATE plans
SET features = jsonb_set(features, '{revenue_attribution}', 'false'::jsonb, true)
WHERE coalesce(is_custom, false) = false;
UPDATE plans
SET features = jsonb_set(features, '{revenue_attribution}', 'true'::jsonb, true)
WHERE lower(name) = 'agency' AND coalesce(is_custom, false) = false;

COMMIT;
-- Sanity: SELECT name, features->>'revenue_attribution' FROM plans
--         WHERE coalesce(is_custom,false)=false ORDER BY price_monthly;
```

**Phase-2 migration (revenue tables — NOT in 0016; number assigned when Phase 2 is built):** deferred so v1 ships no dead schema.

```sql
BEGIN;
-- Revenue events tied to a scan session / QR. HMAC-verified webhook only.
CREATE TABLE IF NOT EXISTS qr_revenue_events (
    id             uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    workspace_id   uuid        NOT NULL REFERENCES workspaces(id) ON DELETE CASCADE,
    qr_id          uuid        REFERENCES qr_codes(id) ON DELETE SET NULL,
    provider       text        NOT NULL,          -- 'stripe' | 'shopify'
    external_id    text        NOT NULL,          -- charge/order id (idempotency)
    session_id     text,                          -- scan session match key (fallback)
    client_ref     text,                          -- metadata-stamped match key (preferred)
    amount_minor   bigint      NOT NULL,          -- integer minor units (paise/cents)
    currency       text        NOT NULL,
    occurred_at    timestamptz NOT NULL DEFAULT now(),
    created_at     timestamptz NOT NULL DEFAULT now(),
    UNIQUE (provider, external_id)                -- webhook replay idempotency
);
CREATE INDEX IF NOT EXISTS idx_revenue_ws_time ON qr_revenue_events (workspace_id, occurred_at);
CREATE INDEX IF NOT EXISTS idx_revenue_qr      ON qr_revenue_events (qr_id);
-- Per-workspace billing-provider connection (signing secrets; service-role only).
CREATE TABLE IF NOT EXISTS workspace_revenue_connections (
    workspace_id    uuid        PRIMARY KEY REFERENCES workspaces(id) ON DELETE CASCADE,
    provider        text        NOT NULL,         -- 'stripe' | 'shopify'
    signing_secret  text        NOT NULL,         -- webhook signing secret (encrypted at rest)
    is_active       boolean     NOT NULL DEFAULT true,
    created_at      timestamptz NOT NULL DEFAULT now()
);
COMMIT;
```

`advanced_analytics` needs **no flag change** — it is already `true` for Pro/Agency (0009) and `enforced`. Migration 0016 only adds the `revenue_attribution` flag (its tables are Phase-2).

---

## 3. Backend Design

### 3.1 Funnel endpoint — `qr_backend/src/api/routes/scan.py`

Add to the existing `/analytics` router (`prefix="/analytics"`, mounted under `API_PREFIX`).

```python
class FunnelStep(pydantic.BaseModel):
    key: str                 # "scan" | "action" | "revenue"
    label: str
    count: int
    pct_of_previous: float   # 100.0 for the first step
    drop_off_pct: float      # vs previous step; 0.0 for the first
    breakdown: Dict[str, int] = {}   # action sources: form_submit / link_click (pixel is a reach stat, not here)

class FunnelResponse(pydantic.BaseModel):
    range_days: int
    qr_id: Optional[str] = None
    conversion_rate: float          # actions / scans * 100
    join_mode: str                  # "aggregate" | "session"
    exclude_bots: bool
    steps: List[FunnelStep]
    retargetable_reach: int = 0     # scans on pixel-enabled QRs — a reach stat, NOT an action
    revenue_total_minor: int = 0    # Phase 2
    revenue_per_scan_minor: float = 0.0
    currency: Optional[str] = None
```

```python
@router.get("/funnel", response_model=FunnelResponse)
async def get_funnel(
    workspace_id: Optional[uuid.UUID] = Query(None),
    qr_id: Optional[uuid.UUID] = Query(None),
    range: int = Query(30, ge=1, le=365),
    exclude_bots: bool = Query(True),     # O.Q.2 default = yes
    format: Optional[str] = Query(None),  # "csv"
    user_id: str = Depends(get_current_user_id),
    db: Client = Depends(get_supabase),
):
    resolved_ws = _resolve_workspace(db, user_id, workspace_id)
    await _require_advanced_analytics(resolved_ws, db)        # 403 if not Pro+
    # Clamp to plan retention (O.Q.4 = yes) — reuse the existing helper.
    cutoff = _retention_cutoff_iso(resolved_ws, db)
    days = min(range, _retention_days(resolved_ws, db) or range)
    window_start = (datetime.now(timezone.utc) - timedelta(days=days)).isoformat()
    start = max(window_start, cutoff) if cutoff else window_start
    ...
```

**Scan denominator (R6 + eng-review finding 1):** count `qr_scan_events` **rows** within `[start, now]`, **not** `qr_scan_counters` (the JSONB counter is a non-atomic read-modify-write and can lose increments). Filter `device_type != 'bot'` when `exclude_bots`. **Scope the denominator to QRs that have an action step, source-matched** — never divide actions by all-workspace scans, or a workspace's many `website`/`vcard`/`pdf` scans dilute the rate toward zero. Concretely: the form-submit rate uses scans of `lead_form` QRs; the link-click rate uses scans of `list_links` QRs; the workspace funnel's Scan step counts scans of `(lead_form ∪ list_links)` QRs. Scoped further by `qr_id` if supplied, else the workspace's actionable QR ids. Use the existing `_MAX_WINDOW_EVENTS`/`_WINDOW_PAGE` paging convention; for count-only we use Supabase `count="exact"` with a `head` query plus a `device_type` filter rather than pulling rows.

**Action numerator:**
- *form_submit* → `qr_lead_submissions` count where `qr_id` (or workspace's lead-form QR ids) and `submitted_at >= start`; denominator = scans of those `lead_form` QRs.
- *link_click* → in 1.0 from the per-link **lifetime** click counter; in 1.1 from `qr_link_click_events` (forward-only — rows start at the 1.1 deploy, so the session-join click numerator covers only post-1.1 clicks; the lifetime counter stays the aggregate source). Denominator = scans of `list_links` QRs.
- *pixel reach* (not an action) → count of scans on QRs whose KV carried `pixels` (workspace has active `retargeting_pixels` rows). Per eng-review finding 2 this is **NOT** added to the action total and **NOT** in the Actions breakdown — a pixel firing on render is the scan, not a user action. Returned as a separate top-level `retargetable_reach` stat beside the funnel.

**Join modes:** `join_mode="aggregate"` (1.0) = `Σ actions / Σ scans-of-actionable-QRs` (source-matched per finding 1, never all-workspace scans). `join_mode="session"` (1.1) = distinct `session_id` present in both `qr_scan_events` and the action table for the same `qr_id` within window. The response advertises which mode produced the numbers so the FE can label honestly ("same-session estimate").

**CSV export:** when `format="csv"`, return a `fastapi.responses.PlainTextResponse` (media type `text/csv`, `Content-Disposition: attachment; filename=funnel_<ws>_<range>d.csv`) with header `step,count,pct_of_previous,drop_off_pct` + one row per step + a summary `conversion_rate` line. This wires the FE's previously dead "Download CSV" button.

### 3.2 Per-session stamping (Phase 1.1)

`internal.py` `LeadSubmitPayload` already has `session_id: str | None` available on the scan path; add it to the lead-submit payload and persist it on the insert (`"session_id": payload.session_id`). Add a new internal contract on the link-click handler to accept `{ "session_id": "...", "timestamp": "..." }`; the backend **resolves `qr_id` and `workspace_id` from `link_id` via `qr_link_items`** (eng-review decision — no click-URL change, no `qr_id` leaked into the public URL) and inserts a `qr_link_click_events` row in addition to the existing counter increment. Both endpoints stay under the `/internal/*` router guarded by `verify_internal_secret` (`x-internal-secret`); no Bearer-middleware change.

### 3.3 Phase-2 revenue webhooks

New `qr_backend/src/api/routes/stripe_routes.py` (`/stripe/webhook`) and `shopify_routes.py` (`/shopify/webhook`), mirroring `razorpay_routes.py` / `mor_routes.py`: public + provider-HMAC-verified. Both prefixes added to `excluded_routes` in `main.py`'s `BearerTokenAuthMiddleware` (like `/api/v1/razorpay/webhooks`, `/api/v1/mor/webhooks`). On a verified `checkout.session.completed` / `orders/paid`:
1. Read `client_reference_id` / `metadata.qr_session` (preferred match key, O.Q.3) or fall back to `session_id`.
2. Resolve the QR/workspace from the match key (scan session → `qr_scan_events.qr_id`).
3. Upsert `qr_revenue_events` keyed on `(provider, external_id)` (idempotent replay guard) with integer `amount_minor`. Never trust an unverified amount (R5).

Settings → Revenue connect endpoints live in a new `revenue.py` router (`/workspaces/{workspace_id}/revenue`, gated by `check_feature(ws, "revenue_attribution")`, `require_can_update`), storing the signing secret in `workspace_revenue_connections`.

### 3.4 Entitlements / KV

Phase 1 needs **no `build_kv_content` / `build_entitlements` / `build_pixels` change** — the funnel reads DB tables only. Phase 2 adds `revenue_attribution: bool` to `build_entitlements` (it already emits `white_labeling`/`ab_testing`) so the edge *could* later inject a checkout-tagging snippet; for v2 this is a snapshot-only addition, no edge behavior yet. No new `write_to_kv` field.

---

## 4. Cloudflare Worker / Edge Design

**Phase 1.0: zero worker change.** The funnel is a pure backend aggregate over tables the Worker already writes through `recordScan` → `/internal/scans`, `/internal/lead-submit`, `/internal/link-click`.

**Phase 1.1 (per-session join):**
- `qr_cf_code/src/utils/scan.js` already computes `sessionId = hashString(`${ip}:${ua}:${today}`)`. Export a helper `computeSessionId(request)` (same `ip`+`ua`+UTC-`today` inputs, 16-hex truncation) so the lead-submit and link-click paths derive the **identical** value.
- `src/index.js` lead-submit handler (`pathname.startsWith("/lead-submit/")`): add `session_id: await computeSessionId(request)` to the JSON body POSTed to `/internal/lead-submit`.
- `src/handlers/linkClick.js`: include `session_id` and `timestamp` in the POST body. **`qr_id` is resolved in the backend from `link_id → qr_link_items.qr_id`** (eng-review decision — no template/URL change, no `qr_id` leaked into the public click URL). Keep the POST inside `ctx.waitUntil(...).catch(()=>{})` — never block the 302.

**KV schema:** unchanged in Phase 1. Phase 2 adds `entitlements.revenue_attribution: bool` (top-level `entitlements` object already exists). No new top-level KV key.

**Scan-data shape:** the funnel relies on `session_id` already in the `recordScan` payload (17-field shape: `qr_id, workspace_id, short_code, country_code, …, ip_hash, session_id, device_type, …`). No new scan fields. `device_type === 'bot'` is the bot filter for `exclude_bots`.

**Template mirroring:** no new scan-page templates and **no click-URL change** (qr_id is resolved backend-side from `link_id`, eng-review decision), so the React↔Worker template-parity rule is **not triggered** at all.

**`scheduled()`:** no change. No new cron.

---

## 5. Frontend Design

### 5.1 Hook — `qr_frontend/src/hooks/useAnalytics.ts`

Extend the existing `analyticsKeys` factory and `authApi` transport:

```ts
// add to analyticsKeys:
funnel: (range: number, qrId?: string) =>
  [...analyticsKeys.all, 'funnel', range, qrId ?? 'workspace'] as const,

export function useAnalyticsFunnel(range = 30, qrId?: string, workspaceId?: string) {
  return useQuery({
    queryKey: [...analyticsKeys.funnel(range, qrId), workspaceId],
    queryFn: async () => {
      const p = new URLSearchParams({ range: String(range) });
      if (qrId) p.set('qr_id', qrId);
      if (workspaceId) p.set('workspace_id', workspaceId);
      const { data } = await authApi.get<FunnelResponse>(`/analytics/funnel?${p.toString()}`);
      return data;
    },
    enabled: !!workspaceId,
    staleTime: 60_000,   // matches backend 60s cache
  });
}
```

CSV download is a plain `authApi.get('/analytics/funnel?...&format=csv', { responseType: 'blob' })` triggered by the button's new `onClick`, then a client-side `Blob`/`a.download`.

### 5.2 Workspace funnel card — `analytics/page.tsx` + `src/components/org/analytics/`

New `ConversionFunnelCard.tsx` (under the existing stat cards), driven by `useAnalyticsFunnel(rangeDays, undefined, workspaceId)` using the page's existing `7/30/90/365` selector. Renders a vertical funnel (bars sized by `pct_of_previous`), each labeled with count, `% of previous`, and `drop_off_pct`; headline KPI = `conversion_rate` (over actionable-QR scans, finding 1). A "breakdown" toggle splits the Action step into `form_submit / link_click` from `steps[1].breakdown`; **pixel-enabled scans render as a separate "retargetable reach" stat (`retargetable_reach`), never inside the Actions breakdown** (finding 2). The mock `repeatVisitorRate` / `scanSuccessRate` tiles (from `src/lib/mockAnalyticsData.ts`, TODO-flagged) are **replaced** by real `conversion_rate` + `drop_off_pct` tiles; mock import removed from this page. The previously dead **Download CSV** button gets its `onClick` (5.1). Gating unchanged: page already returns `<AnalyticsUpgradeGate>` when `!canAccessFeature(subscription, 'advanced_analytics')`.

### 5.3 Per-QR mini-funnel — `src/components/org/qrs/QRDetails.tsx` + `.../details/`

New `ConversionMiniCard.tsx` rendered on the overview tab **only** for `qr.type === 'lead_form'` (scan→submit) or `qr.type === 'list_links'` (scan→click + per-link CTR list), mirroring how `ABResultsCard` conditionally renders for `type === 'website'`. Uses `useAnalyticsFunnel(30, qr.id, workspaceId)`. Hidden for static/website types (no action step).

### 5.4 Leads dashboard — `leads/` (`LeadsClient`)

Add a **conversion-rate header stat** (submissions ÷ scans for the selected form QR) + a small sparkline, sourced from `useAnalyticsFunnel(range, selectedFormQrId, workspaceId)`. Addresses the audit's "flat table only" gap.

### 5.5 Phase-2 Settings → Revenue — `settings/page.tsx`

New `'revenue'` nav section + `RevenueSection.tsx`, conditionally listed when `canAccessFeature(subscription, 'revenue_attribution')` (same pattern as Branding/Pixels). Stripe/Shopify connect form (signing-secret input + DNS-instructions-style copy block). Once connected, the funnel gains a Revenue step (`revenue_total_minor`, `revenue_per_scan_minor`).

**Design system:** shadcn primitives (`Card`, `Badge`, `Button`, `Select`, `Skeleton`, `Progress` for funnel bars), `PageHeader`/`Card`/`EmptyState` from `src/components/org/index.ts`, `cn()`, `primary` (`#4648d4`) for the converted segment and `tertiary` cyan for the action segment, `on-surface-variant` for drop-off labels. No inline styles, no `any`, ≤200 lines/file (split funnel bar into a sub-component). TanStack Query only — no `useEffect+fetch`.

**Upsell ladder:** Free → existing `AnalyticsUpgradeGate` ("See your scan-to-conversion rate. Upgrade to Pro."). Pro → a disabled/teaser **Revenue** step in the funnel card ("Tie scans to real revenue. Upgrade to Agency.") gated on `revenue_attribution`.

---

## 6. AI / External-Service Integration

**No AI in Phase 1 or 2.** This is a deterministic SQL-aggregate + chart feature; conversion math must be exact and reconcilable (±2% acceptance), which rules out an LLM. *Future (Phase 3, out of scope here):* an optional one-line "funnel insight" narration ("submit rate dropped 18% week-over-week — consider shortening the form") could call **`claude-haiku-4-5`** from the **backend** (never the edge — scan path must stay sub-600ms and stateless), fed only the already-computed numeric `FunnelResponse` (no PII), with the generated string cached per `(workspace_id, range, week)` for 24h and a graceful empty-string fallback on any error or timeout. External billing services (Phase 2): **Stripe** + **Shopify** webhooks only, HMAC-verified, mirroring the existing Razorpay/LemonSqueezy provider pattern.

---

## 7. API Contracts

**`GET /api/v1/analytics/funnel`** (Bearer; `advanced_analytics`-gated)

Query: `workspace_id?` (uuid), `qr_id?` (uuid), `range` (1–365, default 30), `exclude_bots` (default true), `format?` (`csv`).

`200` JSON:
```json
{
  "range_days": 30,
  "qr_id": null,
  "conversion_rate": 12.4,
  "join_mode": "aggregate",
  "exclude_bots": true,
  "steps": [
    { "key": "scan",   "label": "Scans",   "count": 5000, "pct_of_previous": 100.0, "drop_off_pct": 0.0,  "breakdown": {} },
    { "key": "action", "label": "Actions", "count": 620,  "pct_of_previous": 12.4,  "drop_off_pct": 87.6,
      "breakdown": { "form_submit": 340, "link_click": 280 } }
  ],
  "retargetable_reach": 5000,
  "revenue_total_minor": 0,
  "revenue_per_scan_minor": 0.0,
  "currency": null
}
```
`403` when not Pro+ (`{"detail":"Advanced analytics requires a Pro or higher plan."}`). `format=csv` → `text/csv` attachment.

**`POST /api/v1/internal/lead-submit`** (x-internal-secret) — body gains `"session_id": "ab12cd34ef56ab78"` (Phase 1.1; optional, persisted on the row).

**`POST /api/v1/internal/link-click/{link_id}`** (x-internal-secret) — body `{ "session_id": "...", "timestamp": "2026-06-24T..." }`; backend resolves `qr_id`/`workspace_id` from `link_id` via `qr_link_items`.

**`POST /api/v1/stripe/webhook` / `/api/v1/shopify/webhook`** (public, HMAC) — provider event; backend upserts `qr_revenue_events`. Returns `200 {"received": true}` after signature verify; `400` on bad signature.

---

## 8. Security, Privacy & Abuse

- **Tenant isolation:** every funnel query resolves the workspace via `_resolve_workspace` and operates only on that workspace's `qr_id` set; the service-role client bypasses RLS, so route-level scoping is the sole boundary — no raw `qr_id` is ever queried without confirming it belongs to the caller's workspace (add a `qr_codes.workspace_id == resolved_ws` check when `qr_id` is passed).
- **Gating:** reuse `_require_advanced_analytics` (403). Phase 2 adds `check_feature(ws,"revenue_attribution")` on revenue routes; register `revenue_attribution` in `FEATURE_ENFORCEMENT` (subscription.py) as `inert` in the 0016 build PR, flipped `enforced` in the Phase-2 PR (the `test_feature_gate_coverage` parity test must stay green).
- **PII / consent:** the funnel exposes only **aggregate counts**, never raw lead data. `session_id` is a daily-rotating cookieless `SHA-256(IP+UA+today)` hash — no raw IP, no cross-day linkage; this is privacy-preserving by construction. The scan-side **consent gate** (`src/utils/consent.js`) is unaffected — the funnel does no edge injection.
- **Webhook abuse (Phase 2):** Stripe/Shopify webhooks are HMAC-signature-verified before any DB write (R5); excluded from Bearer middleware; idempotent via `UNIQUE(provider, external_id)`; signing secrets stored server-side only and never returned to the client.
- **Rate / cost limits:** funnel endpoint inherits Bearer auth; the 60s cache + `_MAX_WINDOW_EVENTS` cap bound query cost; CSV export reuses the same cached aggregate (no extra scan).

## 9. Performance, Scale & Cost

- **Denominator from events, count-only:** use Supabase `count="exact"` head queries (no row payloads) filtered by `qr_id IN (...)` + `scanned_at >= start` + optional `device_type != 'bot'`; backed by an index on `qr_scan_events(qr_id, scanned_at)` (add if missing in 0016). This keeps p95 < 600ms for a 90-day window with the 60s cache (KPI).
- **Caching:** 60s in-process backend cache keyed `(workspace_id, qr_id, range, exclude_bots)` + 60s FE `staleTime`. Reconciles within ±2% of a manual spot-check (counting raw rows, not the lossy counter).
- **No edge cost in Phase 1.** Phase 1.1 adds one extra `qr_link_click_events` insert per click and a `session_id` column write per lead submit — negligible, all inside `ctx.waitUntil`.
- **Retention:** old events are never purged (no TTL job today) — a latent advantage; the retention clamp limits the *query window*, not storage.

## 10. Testing Strategy

**Backend (pytest):** funnel aggregate math (scans/actions/drop-off) on a seeded workspace reconciles ±2% with hand-counted raw rows; `exclude_bots` toggles the denominator; retention clamp narrows the window; **gate-deny** → non-Pro `GET /funnel` returns 403; CSV format returns `text/csv` with correct rows; per-`qr_id` scoping rejects cross-workspace ids. Phase 1.1: `session_id` persisted on lead-submit + link-click; session join distinct-count correctness. Phase 2: webhook HMAC reject on bad signature; idempotent replay (`UNIQUE` no double-count); revenue match by `client_ref` then `session_id`. Keep `test_feature_gate_coverage` green after adding `revenue_attribution`.

**Frontend (Vitest + Playwright):** `useAnalyticsFunnel` query-key/URL correctness; funnel card renders steps + conversion KPI; CSV button triggers a blob download; mini-card renders only for `lead_form`/`list_links`; free user sees the upgrade gate. **Baseline:** the FE suite has ~29 pre-existing failures (documented) — do **not** treat these as regressions; assert the new tests pass and the failure count does not increase.

**Worker (vitest/wrangler):** Phase 1.1 — lead-submit and link-click POST bodies include the correct `session_id` (identical derivation to `recordScan`); the 302/thank-you path is unaffected when the backend POST fails. **End-to-end session parity (finding 6):** a real scan→submit in the same session/day asserts the `session_id` written by `recordScan` equals the one stamped on `qr_lead_submissions` — same `CF-Connecting-IP` + UA + UTC-day across the two separate requests — so the join actually matches, not just a unit check of the hash function.

## 11. Observability & Rollout

- **Flags:** Phase 1 ships behind a FE constant (`FEATURE_FUNNEL_ENABLED` in a constants module) for a 1-week internal + 3–5 design-partner beta, then flip GA. `advanced_analytics` already enforced — no DB flip for Phase 1. Phase 2 gated by `revenue_attribution` (0016 seeds it; `FEATURE_ENFORCEMENT` flips `inert→enforced` in the Phase-2 PR).
- **Phased deploy:** (1) apply `0016` to Supabase; (2) deploy backend (`/analytics/funnel` + CSV) — validate against a hand-computed sheet behind the gate, no FE; (3) deploy FE funnel UI behind the flag → beta → GA; (4) Phase 1.1: deploy backend session-stamping, then the Worker (`session_id` threading) — order matters so the backend accepts the field before the Worker sends it; (5) Phase 2: backend webhooks + FE Revenue section + flag flip.
- **Metrics:** funnel-card view rate (Pro/Agency), CSV-export rate, Analytics-page sessions/week delta, mini-funnel interaction rate, Pro→Agency upgrade after Revenue-teaser view, funnel endpoint p95 latency, ±2% reconciliation spot-check job.

## 12. Open Technical Questions & Risks

- **O.Q.1 — Aggregate-only at GA vs per-session join from day one?** Recommend **aggregate (1.0) first** (no worker change, honest "same-session estimate" labeling via `join_mode`), then 1.1 session join.
- **O.Q.2 — Exclude bots by default?** Recommend **yes** (`exclude_bots=true`) to avoid a deflated conversion rate; surface a toggle.
- **O.Q.3 — Phase-2 match key:** `client_reference_id`/`metadata.qr_session` (preferred, merchant must stamp it) with `session_id` fallback.
- **O.Q.4 — Respect `analytics_retention_days` clamp?** Recommend **yes** — reuse the existing `_retention_cutoff_iso` / `get_limit` clamp.
- **R1/R2 — Day-boundary undercount:** daily-rotated `session_id` means a scan at 23:58 and submit at 00:02 look like different sessions; documented and accepted in Phase 1; cross-day attribution out of scope.
- **R3 — Link-click context:** clicks carry no geo/device today; Phase 1.0 is aggregate-ratio for `list_links`; 1.1 adds `session_id`.
- **R6 — Counter accuracy:** the funnel deliberately counts from `qr_scan_events` rows, not the non-atomic `qr_scan_counters` JSONB; confirm the events table has a `(qr_id, scanned_at)` index (add in 0016 if absent).
- **Resolved (eng-review) — list-links `qr_id` at click time:** `handlers/linkClick.js` only knows `link_id`; the backend resolves `qr_id`/`workspace_id` from `link_id` via `qr_link_items` at ingestion (no click-URL change, no `qr_id` in the public URL).

### Appendix — Key Files

| Concern | File |
|---|---|
| Funnel endpoint + gate + retention clamp + CSV | `qr_backend/src/api/routes/scan.py` |
| Per-session stamping (lead/link) | `qr_backend/src/api/routes/internal.py` |
| Migration | `qr_backend/migrations/0016_scan_conversion_funnel.sql` |
| Gate registry (`revenue_attribution`) | `qr_backend/src/api/routes/subscription.py` (`FEATURE_ENFORCEMENT`) |
| Phase-2 webhooks + Bearer exclusion | new `qr_backend/src/api/routes/stripe_routes.py` / `shopify_routes.py`; `qr_backend/src/main.py`; router wiring in `src/api/endpoints.py` |
| Phase-2 revenue connect | new `qr_backend/src/api/routes/revenue.py` |
| Entitlement snapshot (Phase 2) | `qr_backend/src/utilities/cloudflare_kv.py` (`build_entitlements`) |
| Worker session threading | `qr_cf_code/src/utils/scan.js`, `qr_cf_code/src/index.js` (lead-submit), `qr_cf_code/src/handlers/linkClick.js` |
| Funnel hook | `qr_frontend/src/hooks/useAnalytics.ts` (`useAnalyticsFunnel`, `analyticsKeys.funnel`) |
| Workspace funnel card | `qr_frontend/src/app/org/[slug]/(dash)/analytics/page.tsx`, `qr_frontend/src/components/org/analytics/ConversionFunnelCard.tsx` |
| Per-QR mini-funnel | `qr_frontend/src/components/org/qrs/QRDetails.tsx`, `.../details/ConversionMiniCard.tsx` |
| Leads conversion stat | `qr_frontend/src/app/org/[slug]/(dash)/leads/` (`LeadsClient`) |
| Settings → Revenue (Phase 2) | `qr_frontend/src/app/org/[slug]/(dash)/settings/page.tsx`, `.../settings/RevenueSection.tsx` |
| FE gating | `qr_frontend/src/lib/plan-features.ts` (`canAccessFeature`) |
