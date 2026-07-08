# TRD — Shareable / White-Label Client Report Links

**Status:** Draft · **Author:** Engineering (Staff) · **Date:** 2026-06-24
**Implements PRD:** Shareable / White-Label Client Report Links
**Tiers / Flags:** `shareable_reports` (bool, **new** — flipped on for Pro + Agency by migration **0017**). Branded rendering rides the existing `white_labeling` (Agency) flag — no new branding flag.
**Migration:** `qr_backend/migrations/0017_report_links.sql` (slot 0017 in the 0014–0018 roadmap sequence; current DB highest is `0013_retargeting_pixels.sql`).
**Services touched:** `qr_backend` (new `reports.py` route + public read + migration + RPC), `qr_frontend` (new public `/r/[token]` page + `ShareReportModal` + hooks + flag). **`qr_cf_code` is NOT touched** — the scan path, KV schema, and Worker templates are untouched (PRD Open Question 1 resolved: report renders on the Next.js marketing surface).
**Rev (2026-06-24, post eng-review):** (1) migration `0017` flag-flip hardened to the house convention — `is_custom` guard + NULL-coalesce + idiomatic key-absence check (the true-flip would otherwise touch custom plans / null a NULL `features`); (2) the public endpoint gets a **60s server-side aggregate cache by `(qr_ids, window)` + a Cloudflare edge rate-limit** instead of a phantom per-instance per-token counter (the growth loop expects fan-out, so caching ships in v1, not "if it goes viral"); (3) the PII test is now a **strict exact-key-set allowlist** (a new field fails CI vs silently leaking); (4) revoke-timing wording corrected (revoke is instant via a fresh `revoked_at` read; the 30s cache only gates plan downgrade); (5) low-count de-anonymization accepted for v1 with a documented caveat (owner opts in, country-level only).

---

## 1. Overview & Architecture

Public, no-login, read-only analytics report URLs at `qravio.app/r/<report_token>`, one per QR (`scope=qr`) and one per folder/campaign (`scope=folder`). Access is gated by an unguessable opaque token stored in a `report_links` DB row (PRD Open Question 2 resolved: opaque random token + DB row, with HMAC-precedent kept only conceptually). Payload is **strictly non-PII aggregates** reused from the existing `qr_scan_counters` read path. Branding comes from the existing `workspace_branding` → `build_entitlements().brand` snapshot for Agency; Pro renders a "Powered by Qravio" footer.

**Why no Worker:** Reports are not QR scans — no `recordScan`, no KV key, no template-parity work. The Worker scan path (`src/index.js` → `handleQRCode` → `recordScan`) is completely untouched. This keeps KV lean and avoids the one-to-one React/Worker template mirroring rule.

**Data flow (create):**
```
Owner/editor → ShareReportModal → authApi.post(/workspaces/{ws}/reports)
  → reports.py: require_can_create + await check_feature(ws,'shareable_reports')
  → generate opaque token (secrets.token_urlsafe, ≥160 bits)
  → INSERT report_links row → return { id, report_token, url }
```
**Data flow (public read):**
```
Client → Next.js app/(marketing)/r/[token]/page.tsx (force-dynamic, no Bearer)
  → authApi-less fetch GET /api/public/v1/reports/{token}  (excluded from BearerTokenAuthMiddleware)
  → reports public handler:
       lookup row by token (service role, bypasses RLS) → revoked_at IS NULL?
       re-check check_feature(ws,'shareable_reports')  [stale-gate defense]
       resolve scope (qr_id | folder_id → qr_ids via folders) 
       read qr_scan_counters for qr_ids, clamp to analytics_retention_days
       build_entitlements(ws) → brand block (Agency) or null (Pro)
       fire-and-forget increment_report_views RPC
  → non-PII JSON → page renders stat cards + charts + branded/Qravio footer
```

---

## 2. Data Model & Migrations

**File:** `qr_backend/migrations/0017_report_links.sql` (Begin/Commit-wrapped, idempotent, plan-flag flip at end — house convention). Service role key bypasses RLS, so RLS policies are advisory only; we still add a `revoked_at` filter in every query and add `ENABLE ROW LEVEL SECURITY` with a deny-all policy as defense-in-depth (no anon role ever reads these tables directly — only the backend with the service key).

```sql
BEGIN;

CREATE TABLE IF NOT EXISTS report_links (
    id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    workspace_id  uuid NOT NULL REFERENCES workspaces(id) ON DELETE CASCADE,
    scope         text NOT NULL CHECK (scope IN ('qr', 'folder')),
    qr_id         uuid REFERENCES qr_codes(id) ON DELETE CASCADE,
    folder_id     uuid REFERENCES folders(id)  ON DELETE CASCADE,
    report_token  text NOT NULL UNIQUE,          -- secrets.token_urlsafe(20) => ~160 bits
    title         text,                          -- optional display title; defaults derived
    view_count    bigint NOT NULL DEFAULT 0,
    created_by    uuid,                          -- workspace_members.user_id
    created_at    timestamptz NOT NULL DEFAULT now(),
    revoked_at    timestamptz,                   -- soft-revoke; NULL = live
    CONSTRAINT report_scope_target CHECK (
        (scope = 'qr'     AND qr_id     IS NOT NULL AND folder_id IS NULL) OR
        (scope = 'folder' AND folder_id IS NOT NULL AND qr_id     IS NULL)
    )
);

CREATE INDEX IF NOT EXISTS idx_report_links_token ON report_links(report_token);
CREATE INDEX IF NOT EXISTS idx_report_links_ws    ON report_links(workspace_id) WHERE revoked_at IS NULL;

ALTER TABLE report_links ENABLE ROW LEVEL SECURITY;  -- service role bypasses; deny anon
-- (no anon SELECT policy created on purpose: only the backend service key reads this table)

-- Atomic, lossless view-count increment (mirrors increment_api_usage from 0010)
CREATE OR REPLACE FUNCTION increment_report_views(p_token text)
RETURNS bigint
LANGUAGE plpgsql AS $$
DECLARE v bigint;
BEGIN
    UPDATE report_links
       SET view_count = view_count + 1
     WHERE report_token = p_token AND revoked_at IS NULL
     RETURNING view_count INTO v;
    RETURN COALESCE(v, 0);
END;
$$;

-- Plan flag flip: seed shareable_reports=false everywhere, true for Pro + Agency.
-- House convention: coalesce NULL features, idiomatic key-absence check, and the
-- is_custom guard so custom/enterprise plans are never touched.
UPDATE plans SET features = jsonb_set(coalesce(features,'{}'::jsonb),
    '{shareable_reports}', 'false'::jsonb, true)
  WHERE NOT (coalesce(features,'{}'::jsonb) ? 'shareable_reports')
    AND coalesce(is_custom, false) = false;
UPDATE plans SET features = jsonb_set(coalesce(features,'{}'::jsonb),
    '{shareable_reports}', 'true'::jsonb, true)
  WHERE lower(name) IN ('pro', 'agency') AND coalesce(is_custom, false) = false;

COMMIT;
```

No change to `qr_scan_counters`, `qr_scan_events`, `workspace_branding`, or `folders`.

---

## 3. Backend Design

**New module:** `qr_backend/src/api/routes/reports.py`, registered in `qr_backend/src/api/endpoints.py` via `router.include_router(router=reports_router)`. It carries **two router families**:

1. **Authenticated CRUD router** — `prefix=/workspaces/{workspace_id}/reports`, mounted under `API_PREFIX` like every other JWT route. Uses `require_can_create` / `require_can_read` / `require_can_delete` from `src/api/dependencies/permissions.py`.
2. **Public read router** — `prefix=/api/public/v1/reports`, mounted directly on `app` (absolute prefix, **not** under `API_PREFIX`), exactly like `api_public.py`. The prefix `/api/public/v1` is **already** in `excluded_routes` in `main.py`, so no middleware change is required. This router does **NOT** attach `api_key_auth` (reports are token-in-URL, not API-key) — it is a standalone router with its own per-token rate-limit dependency.

### 3.1 Authenticated CRUD contracts

```
POST   /api/v1/workspaces/{ws}/reports     require_can_create + check_feature('shareable_reports')
GET    /api/v1/workspaces/{ws}/reports     require_can_read   (list, with view_count)
DELETE /api/v1/workspaces/{ws}/reports/{id} require_can_delete (soft: SET revoked_at = now())
```

`POST` body (Pydantic `ReportCreate`): `{ "scope": "qr"|"folder", "qr_id": uuid|null, "folder_id": uuid|null, "title": str|null }`. Validates the same `report_scope_target` invariant in Python before insert, and verifies the `qr_id`/`folder_id` belongs to `{ws}` (`db.table("qr_codes").select("id").eq("id",qr_id).eq("workspace_id",ws).maybe_single()`). Token: `secrets.token_urlsafe(20)`, with a uniqueness retry loop (max 10, mirroring short-code generation). Returns `{ id, report_token, url, scope, view_count: 0 }` where `url = f"{settings.FRONTEND_URL}/r/{report_token}"`.

Gating: at the top of `POST`, `if not await check_feature(ws, "shareable_reports", db): raise HTTPException(403, ...)`. `check_feature` is async — must be awaited.

### 3.2 Public read handler (the core)

`GET /api/public/v1/reports/{token}` — no auth dependency, returns 200 with a `state` field rather than leaking 403/404 details:

```python
row = db.table("report_links").select("*").eq("report_token", token).maybe_single().execute().data
if not row or row["revoked_at"] is not None:
    return {"state": "unavailable"}                      # clean branded page
ws = row["workspace_id"]
if not await check_feature(ws, "shareable_reports", db): # stale-gate defense at READ time
    return {"state": "unavailable"}
# resolve scope → qr_ids
if row["scope"] == "qr":
    qr_ids = [row["qr_id"]]
else:
    qr_ids = [r["id"] for r in db.table("qr_codes").select("id")
                .eq("workspace_id", ws).eq("folder_id", row["folder_id"]).execute().data]
if not qr_ids:  # deleted QR / empty folder → empty-but-branded
    return {"state": "ok", "aggregates": EMPTY_AGGREGATES, "branding": _branding(ws,db), ...}
```

Aggregate assembly **reuses the existing `qr_scan_counters` read path** (the same maps `scan.py` reads at lines ~220/422): pull `scans_by_device`, `scans_by_country`, `scans_by_date`, `scans_by_hour` for `qr_ids`, sum them, and clamp `scans_by_date`/`scans_by_hour` to the workspace's `analytics_retention_days` window via `get_limit(ws, db, "analytics_retention_days")` (sync). `unique_visitors` is derived the same way the per-QR card does (`unique_scans` from counters). For `scope=folder`, also emit a `per_qr` breakdown array (qr title + total scans, sorted desc).

`resolve_plan` has a 30-second cache, so the read-time `check_feature` is cheap (PRD risk mitigation).

The token-resolution + aggregation is wrapped so the response is a **hard allowlist** — see §7. **Caching (eng-review):** the **expensive part** — the `qr_scan_counters` aggregation + `build_entitlements` — is cached server-side for **60s keyed by `(qr_ids, window)`** (same pattern as the funnel endpoint), so a shared/leaked report can't hammer the costly counter scan. The token-row read (`revoked_at`, workspace) and the `check_feature` gate run **fresh on every load** (one indexed lookup + a 30s-cached `resolve_plan`), so revocation and downgrade stay effectively instant while the scan is amortized. View-count: after building the response, fire `db.rpc("increment_report_views", {"p_token": token}).execute()` inside a `try/except` on **every** load (a single-row write, outside the cached path) so view counts stay accurate (fire-and-forget; cosmetic, eventual-consistency OK).

### 3.3 Branding via build_entitlements

`_branding(ws, db)` calls the **existing** `build_entitlements(ws, db)` from `src/utilities/cloudflare_kv.py`. When it returns `{"white_labeling": True, "brand": {logo_url, brand_color, footer_text, footer_url}}`, the report uses that brand block and emits `powered_by: false`. Otherwise (Pro, no white-label) → `{ brand_color: "#4648d4" (primary), powered_by: true }`. Branding can **never** come from query params (spoofing mitigation) — only from the report row's own workspace.

No `build_kv_content` / `write_to_kv` change: reports never enter KV. `build_entitlements` is reused read-only.

### 3.4 Gating registry

In `qr_backend/src/api/routes/subscription.py`, add to `FEATURE_ENFORCEMENT` (line ~428): `"shareable_reports": "inert"` in Phase 0, flipped to `"enforced"` in the same PR as the feature build (Phase 1). The `test_feature_gate_coverage` test asserts parity between `FEATURE_ENFORCEMENT` keys and the plan seed — both get `shareable_reports`, keeping it green.

---

## 4. Cloudflare Worker / Edge Design

**No changes.** This is intentional and is the load-bearing architectural decision:

- No new KV top-level key. The 9-key KV schema (`qr_id, type, destination, destinations, is_password_protected, status, workspace_id, page_design, content, entitlements, pixels`) is untouched.
- No `recordScan` call — a report load is **not** a QR scan and must never appear in `qr_scan_events`/`qr_scan_counters`. The `view_count` lives only in `report_links`.
- No new Worker template, so the React↔Worker template-mirroring house rule does not apply (the report page is plain Next.js).
- No `scheduled()` / cron work.
- Consent gate (`src/utils/consent.js`), pixels (`src/utils/pixels.js`), and the EU strip are irrelevant — reports set no cookies, inject no marketing tags (`hasMarketingTags` stays false), and the report page is served by Next.js, not the edge Worker.

The only edge-adjacent fact: the report page reuses the *snapshot* produced by `build_entitlements` at read time (live DB read), not the KV entitlement snapshot — so a downgrade is reflected in reports immediately (read-time gate), which is *stronger* than KV's lazy snapshot. This is a deliberate asymmetry and is correct for a security-sensitive public surface.

---

## 5. Frontend Design

### 5.1 Public report page (no login)

`qr_frontend/src/app/(marketing)/r/[token]/page.tsx` — thin shell, `export const dynamic = 'force-dynamic'`, delegates to `ReportClient`. Lives in the `(marketing)` group so it inherits the dark/branded marketing layout for the Qravio-footer case; the white-label case overrides surface color from the returned `branding.brand_color`. It fetches `GET /api/public/v1/reports/{token}` directly (no `authApi` Bearer — public endpoint). Renders:

- **`state === 'unavailable'`** → `ReportUnavailable.tsx` (clean branded "This report is no longer available", 200).
- **`state === 'ok'`** → header (brand logo OR Qravio mark + `title` + date range), 3 stat `Card`s (total scans, unique visitors, scans this period), daily area chart, device donut, top-countries list, and for `scope=folder` a per-QR breakdown `Table`. Footer: `branding.powered_by ? PoweredByQravio (links to / with utm_source=report) : renderBrandFooter(branding.brand)`.

Charts reuse the existing analytics chart components (recharts area/donut already in `src/components/org/analytics/`) extracted into shared presentational components under `src/components/org/reports/` so both the dashboard and the public page render identically.

### 5.2 In-app share controls

- **Component:** `qr_frontend/src/components/org/reports/ShareReportModal.tsx` (shadcn `Dialog`) + `ReportsUpgradeGate.tsx`.
- **Entry points:** QR detail overview tab beside `QRAnalyticsCard` (`src/app/org/[slug]/(dash)/qrs/[id]/` → `QRDetails.tsx`), and the analytics page header (`src/app/org/[slug]/(dash)/analytics/page.tsx`) replacing the dead `Download CSV/PDF` cluster (lines ~148-151). For folders, add to the folder/campaign view.
- **Gate:** call `useCurrentSubscription(workspaceId)` then `canAccessFeature(sub, 'shareable_reports')` from `src/lib/plan-features.ts`. False (Free/Starter) → render `ReportsUpgradeGate`. True → render `ShareReportModal` with: a "Public link" toggle, the generated URL + **Copy** button, **Regenerate**, **Revoke**, live **view count**. Agency shows "Branded with your workspace logo"; Pro shows "Reports show 'Powered by Qravio'" + an "Remove Qravio branding — upgrade to Agency" upsell line.

### 5.3 Hooks

New `qr_frontend/src/hooks/useReports.ts` with a query-key factory (house convention):
```ts
export const reportKeys = {
  all: ['reports'] as const,
  list: (wsId: string) => [...reportKeys.all, 'list', wsId] as const,
};
useReports(wsId)                 // GET  /workspaces/{ws}/reports  via authApi
useCreateReport(wsId)            // POST → invalidate reportKeys.list(wsId) + toast
useRevokeReport(wsId)            // DELETE {id}, retry:false → invalidate + toast
```
All HTTP via `authApi` from `src/lib/api-client.ts`. The public page does **not** use a TanStack hook (it is server-fetched in a `force-dynamic` route via plain `fetch` to the public endpoint, no auth token).

### 5.4 Flag wiring

Add `shareable_reports: boolean` to the `PlanFeatures` interface in `src/hooks/useSubscription.ts` and ensure `canAccessFeature` in `src/lib/plan-features.ts` reads it (it reads `subscription.plan.features[key]` generically, so only the type addition is needed). `src/lib/constants/pricing.ts` (display only) gets a "Shareable client reports" line under Pro/Agency.

**Tokens:** primary `#4648d4`, surface hierarchy via `surface-container-*`, `cn()` util, shadcn `Dialog`/`Card`/`Badge`/`Table`/`Button` — no inline styles, no raw `<button>`.

---

## 6. AI / External-Service Integration

**None.** This feature wires existing primitives (analytics aggregates + `workspace_branding` + opaque tokens) and requires no LLM. Adding Claude here would add latency/cost to a public, high-read-rate, security-sensitive surface for no product value. If a future phase adds an auto-generated "executive summary" paragraph on the report, the right design would be a **backend** (not edge) call to `claude-haiku-4-5` (cheapest/fastest, summary is low-stakes) over the already-assembled non-PII aggregate JSON, cached on the `report_links` row keyed by an aggregate hash so it is generated at most once per data-change. Explicitly out of scope for v1.

---

## 7. API Contracts

**Create (auth):**
```
POST /api/v1/workspaces/3f2.../reports
Authorization: Bearer <jwt>
{ "scope": "folder", "folder_id": "9ab...", "title": "Acme — Summer Campaign" }
→ 201
{ "id":"d41...", "report_token":"qS7n...20chars...",
  "url":"https://qravio.app/r/qS7n...", "scope":"folder", "view_count":0 }
```

**List (auth):** `GET .../reports → [{ id, scope, qr_id|null, folder_id|null, title, url, view_count, created_at, revoked_at }]`

**Revoke (auth):** `DELETE .../reports/{id} → 204` (sets `revoked_at`).

**Public read (no auth):**
```
GET /api/public/v1/reports/qS7n...
→ 200
{
  "state": "ok",
  "title": "Acme — Summer Campaign",
  "scope": "folder",
  "date_range_days": 90,                          // clamped to analytics_retention_days
  "aggregates": {
    "total_scans": 4821, "unique_visitors": 3110,
    "scans_this_period": 612,
    "scans_by_date":   { "2026-06-01": 120, ... },
    "scans_by_device": { "mobile": 4001, "tablet": 90, "desktop": 700, "bot": 30 },
    "scans_by_country":{ "IN": 3900, "US": 600, ... },
    "scans_by_hour":   { "0": 12, "13": 401, ... }
  },
  "per_qr": [ { "title":"Flyer A", "total_scans":3000 }, ... ],   // folder scope only
  "branding": { "logo_url":"https://.../logo.png", "brand_color":"#0F766E",
                "footer_text":"Acme Reports", "footer_url":"https://acme.com",
                "powered_by": false }              // Pro: {brand_color:"#4648d4", powered_by:true}
}
```
Revoked/unknown/below-Pro: `→ 200 { "state":"unavailable" }`.

**Hard allowlist:** the public response builder constructs the dict from a fixed literal of the keys above. It NEVER spreads a counter/event row. A test asserts the response's **top-level key set is EXACTLY** `{state, title, scope, date_range_days, aggregates, per_qr, branding}` and that `aggregates` keys are exactly the permitted aggregate set — a **strict allowlist**, so any new field added to the builder later fails CI rather than silently leaking (stronger than denylisting known-bad keys like `ip_hash`/`session_id`).

---

## 8. Security, Privacy & Abuse

- **Opt-in only:** nothing public until a row is created; the token is `secrets.token_urlsafe(20)` (~160 bits) — not a guessable QR id.
- **Instant revocation:** `revoked_at` is read fresh on every load (one indexed token lookup, never cached), so a revoke takes effect **immediately** (well under the PRD's 5s). `resolve_plan`'s 30s cache only affects the separate plan-downgrade stale-gate, not revocation — the two were conflated in an earlier draft.
- **Strictly non-PII allowlist** (§7) with a **strict-key-set** regression test — the highest-risk surface, mitigated structurally not by review discipline.
- **Low-count de-anonymization (accepted for v1, eng-review):** on a tiny single-QR report, coarse aggregates (`scans_by_country`/`scans_by_hour`) could in theory point at an individual. Accepted as-is for v1 because sharing is **per-report opt-in** by the owner over **their own** campaign data and the granularity is country-level (no city, IP, or session). Documented caveat; revisit with low-count suppression if it becomes a concern.
- **Stale-gate defense:** `check_feature(ws,'shareable_reports')` re-checked at **read** time, not just create — a churned/downgraded workspace's links return `unavailable`.
- **Tenant isolation:** scope is bound to a single `qr_id`/`folder_id` validated to belong to the report's workspace at create time; folder reads filter `eq(workspace_id, ws)` so a folder can never leak another tenant's QRs. Service role bypasses RLS, so isolation is enforced in the query layer (explicit `.eq(workspace_id,...)`), with deny-all RLS as backstop.
- **Branding spoofing:** brand block comes only from `build_entitlements(ws)` — never query params.
- **Rate limiting / abuse (eng-review):** the realistic protection on an unauthenticated, multi-instance endpoint is **(1) the 60s server-side aggregate cache** (a shared/leaked token can't hammer the costly counter scan — repeat loads hit cache) plus **(2) a Cloudflare rate-limit rule** on `/api/public/v1/reports/*` (the domain is already behind Cloudflare). A per-instance in-process counter was rejected (no shared state across Render instances); the 160-bit token blocks enumeration; the cache + CF rule bound a single leaked token's blast radius.
- **Consent gate:** N/A — reports set no cookies, inject no pixels (`hasMarketingTags=false`), are not a scan-side surface, so the EU consent strip never triggers.

---

## 9. Performance, Scale & Cost

- **Reads** are 1 indexed token lookup (`idx_report_links_token`) + 1 cached `resolve_plan` + 1 `qr_scan_counters` `.in_(qr_ids)` read (the same query the dashboard already runs) + 1 `build_entitlements`. No per-event scan; counters are pre-aggregated JSONB, so a folder of 50 QRs is one query.
- **Writes** (view_count) use the atomic `increment_report_views` RPC (no Python read-modify-write — mirrors `increment_api_usage`), so concurrent loads don't lose increments and it's a single round-trip fired fire-and-forget.
- **No KV writes, no Worker CPU, no scan-event amplification.** Cost is negligible — this is the lowest-marginal-cost public surface in the app.
- The Next.js route stays `force-dynamic` (the page itself isn't statically cached, so a revoke or branding change shows immediately), but the **backend** caches the expensive aggregate 60s by `(qr_ids, window)`, so high-fanout reads are cheap. This matters precisely because the growth loop *expects* fan-out (the agency's clients viewing the report), so the earlier "revisit caching only if a report goes viral" stance is reversed — the cache ships in v1.

---

## 10. Testing Strategy

**Backend (pytest, `qr_backend/tests/`):**
1. Pro workspace creates `scope=qr` link → 201, token present.
2. Public read renders aggregates + `powered_by:true`.
3. Agency read returns `brand` block, `powered_by:false`.
4. **PII allowlist test (strict)** — assert the public JSON's top-level key set is **exactly** `{state,title,scope,date_range_days,aggregates,per_qr,branding}` and `aggregates`' keys are exactly the permitted aggregate set, so a future field can't silently leak (stronger than asserting known-bad keys absent). Phase-1 acceptance #3.
5. Revoke → next read returns `{state:"unavailable"}` (acceptance #4).
6. Free/Starter create → 403; below-Pro read returns `unavailable` (acceptance #5, stale-gate).
7. `scope=folder` aggregates all folder QRs + `per_qr` breakdown (acceptance #6); empty folder → empty-but-branded, not error.
8. Retention clamp: 365-day folder on a 90-day plan returns ≤ 90 date buckets.
9. `test_feature_gate_coverage` stays green after adding `shareable_reports` to `FEATURE_ENFORCEMENT` + seed.
10. Cross-tenant: token for ws A never returns ws B's QRs.

**Frontend (Vitest + Playwright, `qr_frontend`):** unit-test `useReports`/`useCreateReport`/`useRevokeReport` invalidation; gate rendering (`ReportsUpgradeGate` for Free/Starter). Playwright: incognito (no session) loads `/r/<token>` and sees aggregates + correct footer; revoked token shows unavailable page. **Baseline note:** the FE suite has ~29 pre-existing failing tests (documented baseline, not regressions) — new tests must pass and must not increase that count.

**Worker:** none — Worker is untouched; its existing 17 tests must remain green (confirm no incidental import changes).

---

## 11. Observability & Rollout

**Phase 0 — Migration & flag (inert).** Ship `0017_report_links.sql` (table + RPC + flag flip). Add `shareable_reports: "inert"` to `FEATURE_ENFORCEMENT`. No UI. **User applies 0017 to Supabase prod.** Confirm migration 0011 (white_labeling) is already applied (branding dependency).

**Phase 1 — MVP behind a build flag.** Backend CRUD + public read + token + non-PII payload + view RPC; flip `shareable_reports` `inert→enforced`. Frontend `ShareReportModal`, `ReportsUpgradeGate`, public `/r/[token]` page, branding/Qravio branch. Deploy order: **backend first** (Render), then **frontend** (Vercel) — public read endpoint must exist before the page ships. Acceptance criteria = PRD §10 Phase 1 (1–6). Dogfood with 3–5 friendly Agency accounts.

**Phase 2 — GA.** Remove build flag; wire the analytics-page header entry point (replacing dead export CTAs); add the Pro→Agency in-modal upsell. Announce as "White-label client reports."

**Metrics (Mixpanel + DB):** `report_created` (scope, tier), `report_link_copied`, report page views (`view_count` column), `powered_by_footer_clicked` (utm_source=report on `/`). KPIs from PRD §9: ≥30% Agency / ≥12% Pro create ≥1 link in 30d; ≥40% links get ≥1 external view; Pro→Agency upgrade lift; zero PII incidents; <0.1% report-load errors.

---

## 12. Open Technical Questions & Risks

1. **Route owner — RESOLVED:** Next.js marketing surface (`/r/[token]`), Worker untouched. Confirmed by the no-Worker architecture above.
2. **Token mechanism — RESOLVED:** opaque random `secrets.token_urlsafe(20)` + DB row (simplest revocation = `revoked_at`), HMAC kept as precedent only.
3. **Campaign = folder — RESOLVED for v1:** reuse the existing `folders` table; tags are not built and are not a blocker.
4. **Lead-form QRs:** show scan counts only — all lead-submission data is excluded by the §7 allowlist (PRD recommendation: yes).
5. **Rate-limit threshold (open):** exact RPS/token for the public endpoint — defer the number to eng; start ~10 req/s/token, tune on dogfood telemetry.

**Residual risks:**
- **Public analytics exposure** — mitigated by opt-in + 160-bit token + allowlist test + read-time gate + retention clamp + instant revoke. Highest risk; structurally contained.
- **View-count write amplification** — atomic RPC + fire-and-forget; cosmetic data tolerates loss.
- **`force-dynamic` read load** — low (client-facing traffic), single cheap counter query; revisit with edge caching only if a report goes viral.
- **Folder QRs deleted after link creation** — `ON DELETE CASCADE` on `qr_id` plus empty-`qr_ids` → empty-but-branded render; no stack traces.
