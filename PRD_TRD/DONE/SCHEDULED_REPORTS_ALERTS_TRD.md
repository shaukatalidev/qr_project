# TRD — Scheduled & PDF Analytics Reports + Anomaly Alerts

**Status:** Draft · **Author:** Staff Eng · **Date:** 2026-06-24
**Priority:** High — closes a live trust bug (dead `Download CSV/PDF` + `Schedule Weekly Report` buttons) and the lifecycle-email retention gap.
**Tiers:** On-demand CSV/PDF export gates at **Pro+** via the existing `advanced_analytics` flag (the analytics page is already Pro-gated). Scheduled emailed reports + anomaly alerts gate at **Starter+** via a new `scheduled_reports` flag. Scan-cap / auto-disabled alerts are **ungated** (lifecycle notification, all tiers including Free).
**Plan flags:** `scheduled_reports` (bool) — new; seeded `false` everywhere by migration `0018`, flipped `true` for Starter/Pro/Agency. `advanced_analytics` (bool, existing, already `enforced` in `scan.py`) reused for raw export.
**Split from:** strategic gap #7 (lifecycle emails) + the analytics-surface placeholder-button bug.
**Rev (2026-06-24, post eng-review):** (1) anomaly detection uses a **rolling trailing-7d-vs-prior-7d** window (the daily-cron WoW-vs-Monday-anchor would compare a partial week to a full one and false-fire drops); dedup stays once-per-ISO-week; (2) PDF renderer committed to **WeasyPrint** (the "make-pdf path" was a local CLI skill, not a backend library); (3) migration `0018` flag-flip hardened to the `lower(name)` + `is_custom` + NULL-coalesce convention; (4) scheduled reports **claim** each row (conditional `last_sent_at` update) so a duplicate cron delivery can't double-send; (5) external recipients allowed but bounce-monitored, and **`_dmarc.qravio.app` is a hard GA gate**.

---

## 1. Overview & Architecture

This feature assembles existing primitives rather than inventing new ones. **All three services change**, but lightly:

- **`qr_backend`** gains a new `reports` route module (`src/api/routes/reports.py`) for export + schedule/alert CRUD, two new internal cron endpoints in `internal.py` (`/internal/run-reports`, `/internal/run-alerts`), a scan-cap/auto-disabled alert hook inside the existing `_enforce_scan_limit()`, and PDF/CSV rendering helpers in `src/utilities/`. Email delivery reuses `src/utilities/email.py` (Resend).
- **`qr_cf_code`** gains two new cron triggers (daily + weekly; monthly already exists) in `wrangler.toml` and corresponding branches in the `scheduled()` handler in `src/index.js`. **No KV schema change, no template work** — reports read from `qr_scan_counters` server-side, never from KV or the edge.
- **`qr_frontend`** wires real `onClick` handlers to the two dead buttons (`analytics/page.tsx`, `qr-analytics-card.tsx`), adds a schedule modal, an Alerts card, and new TanStack Query hooks in `useAnalytics.ts`.

**Data flow — on-demand export:**
```
User clicks Download PDF on /org/[slug]/(dash)/analytics
  → authApi.get('/analytics/export.pdf?range=30d', {responseType:'blob'})
  → reports.py: require advanced_analytics → clamp range to analytics_retention_days
  → read qr_scan_counters (workspace or qr scoped) → build markdown report
  → render HTML→PDF (WeasyPrint) → return application/pdf (Content-Disposition: attachment)
  → browser triggers download
```

**Data flow — scheduled report (cron-driven):**
```
CF cron (daily/weekly/monthly) → scheduled() in src/index.js
  → POST BACKEND_URL/internal/run-reports  (x-internal-secret, body {frequency})
  → reports cron handler: SELECT scheduled_reports WHERE is_active AND frequency=? AND due
  → for each: CLAIM the row (conditional last_sent_at update; skip if already claimed) → build PDF/CSV in a BackgroundTask → resend.Emails.send(attachments=[...])
  → cron returns fast (counts only); a hard send failure resets the claim to retry next cycle
```

**Data flow — anomaly alerts:**
```
CF daily cron → POST /internal/run-alerts (x-internal-secret)
  → read analytics_alert_configs + qr_scan_counters → compute trailing-7d-vs-prior-7d deltas per workspace/QR
  → for each breach: INSERT alert_events ... ON CONFLICT DO NOTHING (dedupe)
  → if insert affected a row → send alert email; else no-op (already sent this window)
Scan-cap / auto-disabled alerts piggyback on _enforce_scan_limit() (internal.py /scans path)
  → same alert_events dedupe table → Free→Starter CTA email
```

---

## 2. Data Model & Migrations

This feature is assigned slot 0018 in the 0014–0018 roadmap sequence (current DB highest is `0013_retargeting_pixels.sql`): **`migrations/0018_scheduled_reports.sql`**. All Supabase access uses the **service role key, which bypasses RLS** — so no RLS policies are added; tenant isolation is enforced in application code via `workspace_id` filters and `require_*` permission deps. Tables are still `workspace_id`-keyed with `ON DELETE CASCADE` for correctness.

```sql
-- migrations/0018_scheduled_reports.sql
BEGIN;

CREATE TABLE IF NOT EXISTS scheduled_reports (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  workspace_id  uuid NOT NULL REFERENCES workspaces(id) ON DELETE CASCADE,
  qr_id         uuid REFERENCES qr_codes(id) ON DELETE CASCADE,  -- null = whole workspace
  frequency     text NOT NULL,                                   -- 'daily'|'weekly'|'monthly'
  recipients    text[] NOT NULL DEFAULT '{}',
  format        text NOT NULL DEFAULT 'pdf',                     -- 'pdf'|'csv'
  is_active     boolean NOT NULL DEFAULT true,
  last_sent_at  timestamptz,
  created_at    timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_sched_reports_ws  ON scheduled_reports(workspace_id) WHERE is_active;
CREATE INDEX IF NOT EXISTS idx_sched_reports_due ON scheduled_reports(frequency)    WHERE is_active;

CREATE TABLE IF NOT EXISTS analytics_alert_configs (
  workspace_id  uuid PRIMARY KEY REFERENCES workspaces(id) ON DELETE CASCADE,
  spike_enabled boolean NOT NULL DEFAULT false,
  spike_pct     int     NOT NULL DEFAULT 200,
  drop_enabled  boolean NOT NULL DEFAULT false,
  drop_pct      int     NOT NULL DEFAULT 70,
  recipients    text[]  NOT NULL DEFAULT '{}',
  updated_at    timestamptz NOT NULL DEFAULT now()
);

-- dedupe ledger: one row per fired alert per window
CREATE TABLE IF NOT EXISTS alert_events (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  workspace_id  uuid NOT NULL REFERENCES workspaces(id) ON DELETE CASCADE,
  qr_id         uuid REFERENCES qr_codes(id) ON DELETE CASCADE,
  alert_type    text NOT NULL,           -- 'spike'|'drop'|'scan_cap'|'auto_disabled'
  window_anchor date NOT NULL,
  sent_at       timestamptz NOT NULL DEFAULT now(),
  UNIQUE (workspace_id, qr_id, alert_type, window_anchor)
);
```

> **Dedupe note:** `qr_id` is nullable, and Postgres treats `NULL` as distinct in a `UNIQUE` constraint, which would defeat dedupe for workspace-scoped alerts. To make the constraint reliable, `_enforce_scan_limit` / the alert sender always write a **sentinel** `qr_id = '00000000-0000-0000-0000-000000000000'` for workspace-scoped alerts (scan_cap is workspace-level). For per-QR alerts (spike/drop/auto_disabled), the real `qr_id` is used. `ON CONFLICT (workspace_id, qr_id, alert_type, window_anchor) DO NOTHING` then makes re-runs idempotent.

```sql
-- flag flip: seed scheduled_reports=false everywhere, true for Starter/Pro/Agency.
-- House convention: coalesce NULL features, idiomatic key-absence check, lower(name)
-- + is_custom guard so custom/enterprise plans are never touched.
UPDATE plans SET features = jsonb_set(coalesce(features,'{}'::jsonb), '{scheduled_reports}', 'false'::jsonb, true)
  WHERE NOT (coalesce(features,'{}'::jsonb) ? 'scheduled_reports')
    AND coalesce(is_custom, false) = false;
UPDATE plans SET features = jsonb_set(coalesce(features,'{}'::jsonb), '{scheduled_reports}', 'true'::jsonb, true)
  WHERE lower(name) IN ('starter','pro','agency') AND coalesce(is_custom, false) = false;

COMMIT;
```

The migration is idempotent (`IF NOT EXISTS`, guarded `jsonb_set`) and wrapped in `BEGIN/COMMIT`, matching the house convention.

---

## 3. Backend Design

### 3.1 New router — `src/api/routes/reports.py`

Mounted under the existing `/workspaces` + `/analytics` surfaces. Registered in `src/api/endpoints.py` as `from src.api.routes.reports import router as reports_router` then `router.include_router(router=reports_router)`. The router prefix is `/workspaces/{workspace_id}` for CRUD and reuses the `/analytics` style for exports. All routes sit under `API_PREFIX` (`/api/v1`) and pass through `BearerTokenAuthMiddleware`.

**Export endpoints** (gated by `advanced_analytics`, reusing `scan.py`'s `_require_advanced_analytics`):

| Method | Path | Returns |
|---|---|---|
| `GET` | `/analytics/export.csv?range=30d&qr_id=<opt>` | `text/csv` attachment |
| `GET` | `/analytics/export.pdf?range=30d&qr_id=<opt>` | `application/pdf` attachment |

Both resolve workspace via the existing `_resolve_workspace()` helper, call `await _require_advanced_analytics(ws, db)`, and **clamp** `range` to the plan's retention with `get_limit(ws, db, "analytics_retention_days")` (reusing the exact clamp pattern in `scan.py:263`). They read `qr_scan_counters` (workspace-wide rollup or a single `.eq("qr_id", qr_id)` row) — never raw `qr_scan_events` — so they're cheap and bounded.

- **CSV**: rows = `scans_by_date` (date,count), with `scans_by_device`, `scans_by_country`, `scans_by_hour` appended as labelled sections in one file (v1; per-dimension zip is Phase 2). Streamed via `fastapi.responses.StreamingResponse` with `Content-Disposition: attachment; filename="qravio-analytics-<scope>-<range>.csv"`.
- **PDF**: a new `src/utilities/report_pdf.py` builds an HTML document (totals, WoW change, daily series table, top countries, device mix) and renders it with **WeasyPrint** (HTML/CSS→PDF, pinned in `requirements.txt` and present in the Render image — eng-review decision, replacing the abstract "make-pdf path", which is a local gstack CLI skill, not a backend library), returning `Response(content=pdf_bytes, media_type="application/pdf")`. The range and the number of counter rows rendered are capped to bound latency.

**Schedule CRUD** (gated by `scheduled_reports`):

| Method | Path | Body / Notes |
|---|---|---|
| `GET` | `/workspaces/{id}/analytics/reports` | list schedules |
| `POST` | `/workspaces/{id}/analytics/reports` | `{frequency, recipients[], qr_id?, format}` |
| `PATCH` | `/workspaces/{id}/analytics/reports/{report_id}` | partial update incl. `is_active` toggle |
| `DELETE` | `/workspaces/{id}/analytics/reports/{report_id}` | hard delete |

**Alert config** (gated by `scheduled_reports`):

| Method | Path | Body |
|---|---|---|
| `GET` | `/workspaces/{id}/analytics/alerts` | config (defaults if no row) |
| `PUT` | `/workspaces/{id}/analytics/alerts` | upsert `analytics_alert_configs` on conflict `workspace_id` |

All write routes use `require_can_update`/`require_can_create`/`require_can_delete` from `src/api/dependencies/permissions.py`; reads use `require_can_read`. Feature gates call `await check_feature(workspace_id, "scheduled_reports", db)` (async) and raise 403 with an upgrade hint when false. Recipients default to the owner's email (looked up via `workspace_members` → `auth.users`) when the array is empty. Supabase queries use the fluent API, e.g. `db.table("scheduled_reports").select("*").eq("workspace_id", ws).eq("is_active", True).execute()`.

### 3.2 Internal cron endpoints — `src/api/routes/internal.py`

Two new endpoints on the existing `/internal` router (already protected router-wide by `Depends(verify_internal_secret)` checking the `x-internal-secret` header — no middleware change needed):

- `POST /internal/run-reports` — body `{"frequency": "daily"|"weekly"|"monthly"}`. Selects `scheduled_reports WHERE is_active AND frequency = ?` whose `last_sent_at` is null or older than the cadence boundary. For each due schedule it **claims** the row with a conditional update — `UPDATE scheduled_reports SET last_sent_at=now() WHERE id=? AND (last_sent_at IS NULL OR last_sent_at < <cadence boundary>)` — and only proceeds if the claim matched a row, so a duplicate cron delivery (CF can deliver a cron more than once) cannot double-send the same client report (eng-review finding 4). It then `background_tasks.add_task(_send_scheduled_report, ...)` to build PDF/CSV and `resend.Emails.send(attachments=[...])`; on a hard send failure the task resets `last_sent_at` so the schedule retries next cycle rather than silently skipping. Returns `{"sent": n, "skipped": m}` fast (the heavy work is in the background task). Null-guards deleted QRs and empty recipient lists (skip with a logged warning).
- `POST /internal/run-alerts` — no body. Iterates workspaces with an `analytics_alert_configs` row (or scan-cap candidates). Computes deltas from `qr_scan_counters.scans_by_date` over a **rolling trailing-7-days vs the prior-7-days** window (eng-review finding 1 — NOT a partial calendar week vs a full prior week, which would false-fire drops on any mid-week daily run). For each breach, attempts `db.table("alert_events").insert({...}).execute()` guarded by the `ON CONFLICT DO NOTHING` unique constraint — only when a row is actually inserted does it queue the alert email. **Floor guard:** spike/drop suppressed when the prior-7d base is `< 20` scans. **Dedupe `window_anchor` = the ISO-week Monday** so an ongoing multi-day spike alerts at most once per week (detection uses the rolling 7d window; dedup uses the weekly anchor).

These mirror the existing `POST /internal/free-scan-reset` pattern exactly (router-level secret dep, idempotent, returns a small JSON summary).

### 3.3 Scan-cap / auto-disabled alert hook

Inside `_enforce_scan_limit()` (`internal.py:447`), immediately after the block that flips QRs to `disabled` and syncs KV (`internal.py:476-522`), add a fire-once alert:

```python
# After affected QRs flipped to 'disabled' and KV synced:
_maybe_fire_alert(db, workspace_id, qr_id=SENTINEL_QR, alert_type="scan_cap")
```

`_maybe_fire_alert` does the `ON CONFLICT DO NOTHING` insert into `alert_events` keyed by `(workspace_id, sentinel, 'scan_cap', period_start_iso_date)`; on a real insert it queues a Resend email to the owner with a **Free→Starter** CTA. This is **ungated** (lifecycle, all tiers). The same helper fires `auto_disabled` per affected `qr_id`. Both swallow errors (never break scan recording), consistent with the fail-open design of `_enforce_scan_limit`.

### 3.4 Gating registry + KV

`FEATURE_ENFORCEMENT` (`subscription.py:428`) gains `"scheduled_reports": "enforced"` in the same PR (the `test_feature_gate_coverage` test asserts parity with the plan seed). **No KV / `build_entitlements` change is required** — reports and alerts run entirely server-side off `qr_scan_counters`, so they touch neither `build_kv_content`, `write_to_kv`, nor `build_pixels`. No `dynamic_qr_types` list change (no new QR type). This keeps the edge contract untouched.

---

## 4. Cloudflare Worker / Edge Design

**No KV schema change. No template work. No new page handlers.** The reports/alerts feature is invisible to the scan-time `fetch` path and to `recordScan`'s 17-field payload.

The only Worker change is **cron**: the existing `scheduled()` handler in `src/index.js` (lines 41–70) currently POSTs only to `/internal/free-scan-reset` on the monthly cron. We extend it to branch on `event.cron` (CF passes the matched cron expression) and call the right internal endpoint:

```js
async scheduled(event, env, ctx) {
  ctx.waitUntil((async () => {
    const headers = { "x-internal-secret": env.INTERNAL_SECRET, "Content-Type": "application/json" };
    if (event.cron === "0 0 1 * *") {
      await fetch(`${env.BACKEND_URL}/internal/free-scan-reset`, { method: "POST", headers });
      await fetch(`${env.BACKEND_URL}/internal/run-reports`, { method: "POST", headers, body: JSON.stringify({ frequency: "monthly" }) });
    } else if (event.cron === "0 0 * * 1") {            // Mon 00:00 UTC — weekly
      await fetch(`${env.BACKEND_URL}/internal/run-reports`, { method: "POST", headers, body: JSON.stringify({ frequency: "weekly" }) });
    } else if (event.cron === "0 6 * * *") {            // 06:00 UTC daily
      await fetch(`${env.BACKEND_URL}/internal/run-reports`, { method: "POST", headers, body: JSON.stringify({ frequency: "daily" }) });
      await fetch(`${env.BACKEND_URL}/internal/run-alerts`, { method: "POST", headers });
    }
  })().catch((e) => console.error("[cron] reports/alerts failed:", e)));
}
```

`wrangler.toml` gets the three crons in **both** `[env.development.triggers]` and `[env.production.triggers]` (currently `crons = ["0 0 1 * *"]`):

```toml
crons = ["0 0 1 * *", "0 0 * * 1", "0 6 * * *"]
```

**Deployment gate:** new crons only register after the **prod worker is deployed** (`npm run deploy:prod`) — same caveat as the existing free-scan-reset cron. Until then, scheduled reports/alerts are inert even with migration 0018 applied.

---

## 5. Frontend Design

### 5.1 Hooks — `src/hooks/useAnalytics.ts`

Extend the existing `analyticsKeys` factory and add hooks (all via `authApi` from `src/lib/api-client.ts`):

```ts
analyticsKeys.reports = (wsId: string) => [...analyticsKeys.all, 'reports', wsId] as const;
analyticsKeys.alerts  = (wsId: string) => [...analyticsKeys.all, 'alerts', wsId] as const;
```

- `useScheduledReports(workspaceId)` → `GET /workspaces/{id}/analytics/reports`
- `useCreateReport()` / `useUpdateReport()` / `useDeleteReport()` — `useMutation` → `invalidateQueries(analyticsKeys.reports(wsId))` + `toast()` (house mutation pattern)
- `useAlertConfig(workspaceId)` → `GET …/analytics/alerts`; `useUpdateAlertConfig()` → `PUT …/analytics/alerts`
- `downloadAnalyticsExport(workspaceId, fmt, range, qrId?)` — a plain async helper (not a hook): `authApi.get('/analytics/export.{fmt}', { params, responseType: 'blob' })` then trigger a browser download via an object URL. Mirrors `downloadLeadsCsv` already in the codebase.

### 5.2 Components & routes

- **`src/app/org/[slug]/(dash)/analytics/page.tsx:148-151`** — the two dead `<button>`s get real handlers. Per the frontend code rules they become shadcn `<Button>`s. **Download CSV/PDF** opens a tiny popover (Download CSV / Download PDF) that calls `downloadAnalyticsExport` with the current `useAnalyticsDays` range. **Schedule Weekly Report** opens `<ScheduleReportModal>`.
- **`src/components/org/analytics/schedule-report-modal.tsx`** — shadcn `Modal` + react-hook-form + zod: `frequency` (Daily/Weekly/Monthly `Select`), `recipients` (comma-separated, validated emails), `scope` (workspace or a chosen QR), `format`. Lists existing schedules with edit/delete (Phase-1 `is_active` toggle via `useUpdateReport`).
- **`src/components/org/analytics/alerts-card.tsx`** — a new `Card` on the analytics page (Starter+). Spike toggle + threshold, Drop toggle + threshold, read-only "Scan-cap & auto-disable alerts are always on" row, recipients. Saved via `useUpdateAlertConfig`.
- **`src/components/org/qrs/details/qr-analytics-card.tsx`** — same two export buttons, scoped to that `qr_id` (passed through to `downloadAnalyticsExport`).

**Gating (UI):** the page already calls `useCurrentSubscription(workspaceId)` and `canAccessFeature(subscription, 'advanced_analytics')` (the page is Pro-gated, so the export buttons are inherently Pro+). For the schedule modal and alerts card, gate with `canAccessFeature(subscription, 'scheduled_reports')` from `src/lib/plan-features.ts`; when false render an inline `UpgradeGate`. Add `scheduled_reports: boolean` to the `PlanFeatures` interface in `src/hooks/useSubscription.ts`.

**Design tokens:** use `primary`/`primary-container` (indigo) and `surface-container-*`, `on-surface-variant` tokens from `tailwind.config.cjs`; no inline styles; `cn()` for conditional classes. Instrument both export buttons with the existing Mixpanel `ELEMENT_CLICKED` via `data-track-id` so the "dead-button-click" KPI can be measured.

---

## 6. AI / External-Service Integration

**No Claude / Anthropic model is used in v1.** Reports are fixed-template markdown rendered to PDF; alerts are deterministic threshold checks. There is no natural-language generation, summarization, or classification in scope (a "AI-written executive summary" of the report is an explicit Phase-3 candidate, not v1). The only external service is **Resend** (email delivery, already wired); PDF rendering is local via **WeasyPrint** (no external service).

> If a Phase-3 AI summary is greenlit later, the recommendation is `claude-haiku-4-5` running in the **backend** background task (not the edge): it ingests the same counter aggregates the PDF already holds and emits a 2–3 sentence summary string injected into the markdown. Haiku is chosen for cost/latency on a high-volume, low-complexity summarization task; inputs are pre-aggregated counters (tiny token count), output capped at ~120 tokens, with a plain-template fallback string if the call errors or times out. Out of scope for this TRD.

---

## 7. API Contracts

**Export (Pro+):**
```
GET /api/v1/analytics/export.pdf?range=30d&qr_id=<uuid?>
→ 200 application/pdf  (Content-Disposition: attachment; filename="...pdf")
GET /api/v1/analytics/export.csv?range=30d
→ 200 text/csv
→ 403 {"detail":"advanced_analytics required"}   (Free/Starter)
```

**Create schedule (Starter+):**
```
POST /api/v1/workspaces/{workspace_id}/analytics/reports
{ "frequency": "weekly", "recipients": ["asha@agency.com"], "qr_id": null, "format": "pdf" }
→ 201 { "id":"<uuid>", "frequency":"weekly", "recipients":["asha@agency.com"],
        "qr_id":null, "format":"pdf", "is_active":true, "last_sent_at":null,
        "created_at":"2026-06-24T..." }
→ 403 { "detail":"scheduled_reports required" }
```

**Alert config (Starter+):**
```
PUT /api/v1/workspaces/{workspace_id}/analytics/alerts
{ "spike_enabled":true, "spike_pct":200, "drop_enabled":true, "drop_pct":70,
  "recipients":["asha@agency.com"] }
→ 200 { ...config, "updated_at":"..." }
```

**Internal cron (x-internal-secret):**
```
POST /api/v1/internal/run-reports   { "frequency":"weekly" }   → 200 {"sent":12,"skipped":1}
POST /api/v1/internal/run-alerts                                → 200 {"fired":3,"deduped":7}
```

---

## 8. Security, Privacy & Abuse

- **Auth:** all customer-facing routes go through `BearerTokenAuthMiddleware` (Supabase JWT) + `require_*` role deps; internal cron routes are protected by the router-wide `verify_internal_secret` (`x-internal-secret`) — no new exclusions added to the middleware.
- **Tenant isolation:** every query filters by `workspace_id`; export endpoints resolve workspace via `_resolve_workspace()` and never accept a cross-workspace `qr_id` (the `qr_id` is validated to belong to the resolved workspace before reading counters).
- **PII / consent:** reports aggregate **counters only** (`scans_by_date/device/country/hour`) — no raw IPs, no `ip_hash`/`session_id`, no individual scan rows leave the system. Recipients are operator-chosen emails. The **edge consent gate is irrelevant** here — reports never run at scan time and never touch the Worker's pixel/consent path.
- **Recipient abuse / external recipients (eng-review):** external (non-member) recipients are allowed (the agency "cc the client" use case), but bounded — cap recipients per schedule (10), validate each via zod (FE) + pydantic `EmailStr` (BE), and **monitor Resend bounce/spam rates with an auto-disable on a schedule whose recipients hard-bounce repeatedly**. Schedules with all-invalid recipients are skipped and logged. This is reputation-sensitive on a young domain — gated behind the DMARC GA gate (§Open Q1).
- **Email deliverability:** reuse the verified `send.qravio.app` MAIL FROM (`settings.FROM_EMAIL`). Known caveat: `_dmarc.qravio.app` is not yet published (per memory), so bulkier report mail may hit Gmail's "dangerous" banner until DMARC is added — see Open Questions.
- **Rate / cost guard:** on-demand PDF is synchronous; the range is clamped to `analytics_retention_days` and the rendered row count is bounded, preventing a 365-day export from a 30-day plan or an unbounded render.

---

## 9. Performance, Scale & Cost

- **Reads are counter-based**, not event-based: a workspace report reads at most one `qr_scan_counters` row per QR (a single JSONB blob), so even an 80-QR Agency report is ~80 small row reads — no scan-event table scans.
- **On-demand PDF** latency is dominated by markdown→PDF rendering; bound by clamped range. Acceptable for a click-to-download UX.
- **Scheduled PDFs** run in FastAPI `BackgroundTasks` so the cron `POST` returns in milliseconds (counts only); CF `scheduled()` wraps the fetch in `ctx.waitUntil` and never blocks.
- **Alerts** are O(workspaces with config) per daily run; the floor guard (`< 20` prior scans) suppresses noise on tiny accounts. The `alert_events` `ON CONFLICT DO NOTHING` insert is a single indexed upsert per candidate.
- **Eventual consistency:** counters are a Python read-modify-write in `internal.py` — reports/alerts read counters, so they're eventually consistent; acceptable for daily/weekly cadence (documented edge case).

---

## 10. Testing Strategy

**Backend (pytest):**
- `advanced_analytics` gate: Free/Starter export → 403; Pro export → 200 with correct `Content-Type`.
- CSV body parses and matches `scans_by_date`; PDF returns non-empty `application/pdf` with correct totals.
- `scheduled_reports` gate: Free schedule/alert create → 403; Starter → 201/200.
- Retention clamp: a 30-day-retention plan requesting `range=365d` is clamped to 30.
- **Dedupe:** two consecutive `/internal/run-alerts` calls in the same window fire the alert exactly once (second is a no-op via `ON CONFLICT`).
- **Window math (finding 1):** a flat-traffic workspace does **not** fire a drop alert on a mid-week (e.g. Wednesday) daily run — asserts the rolling trailing-7d-vs-prior-7d window, not partial-week-vs-full-week (the false-drop regression).
- **Report claim (finding 4):** two concurrent `/internal/run-reports` for the same due schedule send exactly once (the conditional claim blocks the double-send); a simulated send failure resets `last_sent_at` so the next run retries.
- **Scan-cap alert:** forcing a Free workspace over `max_scans` in `_enforce_scan_limit` fires exactly one `scan_cap` alert with a Free→Starter CTA; a second `/scans` over cap fires nothing.
- `FEATURE_ENFORCEMENT` coverage test stays green (new flag present in registry + seed).

**Worker (node `*.test.mjs`, matching `consent.test.mjs`/`pixels.test.mjs`):**
- `scheduled()` dispatches the correct internal endpoint per `event.cron` value; all calls carry `x-internal-secret`; failures are swallowed (no throw).

**Frontend (Vitest + Playwright):**
- Export helper builds the right URL + blob download; modal validates recipients via zod; gating hides schedule/alerts for Free.
- **Baseline:** the FE suite has **~29 pre-existing failures** (documented baseline, not regressions) — assert the new tests pass and the failure count does not increase.

---

## 11. Observability & Rollout

**Feature flag:** `scheduled_reports` flipped `inert→enforced` in `FEATURE_ENFORCEMENT` in the same PR as the build; gated UI keyed on `canAccessFeature`. Export reuses the already-enforced `advanced_analytics`.

**Phased deploy (all 3 services):**
1. Apply migration `0018` to Supabase (creates tables + flips the flag).
2. Deploy backend (new `reports.py` router + internal cron endpoints + scan-cap hook).
3. Deploy frontend (real button handlers, modal, alerts card, hooks).
4. **Deploy the prod Worker** (`npm run deploy:prod`) — required for the new daily/weekly crons to register; until this, scheduled delivery is inert.

**Metrics:** Mixpanel `ELEMENT_CLICKED` on both export buttons (dead-button KPI → 0); export-success rate ≥ 95%; ≥ 25% of Pro+ workspaces export within 30d; ≥ 15% of Starter+ create a schedule within 60d; scan-cap-alert→upgrade ≥ 8% (headline). Monitor Resend bounce/spam rates and cron timing logs (`console.log` in `scheduled()`); backend logs duplicate-alert anomalies. **Beta→GA:** ship to internal + 5 design-partner agencies behind the flag; GA after one clean weekly cycle with no duplicate-alert reports **AND** after `_dmarc.qravio.app` is published (hard gate — bulk external mail trips Gmail's "dangerous" banner without it).

---

## 12. Open Technical Questions & Risks

1. **DMARC dependency — RESOLVED (eng-review): hard GA gate.** Publish `_dmarc.qravio.app` (`v=DMARC1; p=none`) **before GA** — bulk report mail to external recipients trips Gmail's "dangerous" banner without it and damages sender reputation. Not a Phase-1-build blocker, but a GA blocker.
2. **Alert thresholds** — fixed defaults (spike ≥200%, drop ≥70%) + a single sensitivity toggle in v1; full sliders Phase 2.
3. **Cron cadence anchor** — fixed Monday-00:00-UTC weekly for everyone in v1 (per-workspace timezone is Phase 2). The `window_anchor` math must match `period_start_iso()` semantics so dedupe windows align.
4. **PDF branding** — plain Qravio-footer PDF for all tiers in v1; white-label/branded PDFs are Phase-3 Agency upsell (would then read `workspace_branding`).
5. **Nullable `qr_id` dedupe** — confirmed risk; mitigated by the sentinel-UUID convention (§2). If product later wants true per-workspace null-keyed rows, switch to a partial unique index with `COALESCE(qr_id, '0000…')`.
6. **PDF renderer — RESOLVED (eng-review):** the PDF endpoint uses **WeasyPrint** (HTML/CSS→PDF), pinned in `requirements.txt`. The "make-pdf path" wording is dropped (it was a gstack CLI skill, not a backend library). Action item: WeasyPrint needs its system libs (`libpango`, `libcairo`, `libgdk-pixbuf`) in the Render image — confirm the buildpack/Dockerfile includes them before Phase 1.
7. **Counter eventual consistency** — acceptable for daily/weekly cadence; spike/drop on a freshly-incremented day may lag by one read-modify-write cycle. Documented, not blocking.

---

## 13. Appendix — Key Files

| Concern | File |
|---|---|
| Export + schedule/alert routes (new) | `qr_backend/src/api/routes/reports.py` |
| Router registration | `qr_backend/src/api/endpoints.py` |
| Cron internal endpoints (new) | `qr_backend/src/api/routes/internal.py` (`/run-reports`, `/run-alerts`) |
| Scan-cap alert hook | `qr_backend/src/api/routes/internal.py` (`_enforce_scan_limit`, line ~447) |
| Retention clamp + advanced_analytics gate reuse | `qr_backend/src/api/routes/scan.py` (`_require_advanced_analytics`, `get_limit`) |
| Gating registry flip | `qr_backend/src/api/routes/subscription.py` (`FEATURE_ENFORCEMENT`, line 428) |
| Email (Resend) | `qr_backend/src/utilities/email.py` |
| PDF/CSV builders (new) | `qr_backend/src/utilities/report_pdf.py` |
| Migration | `qr_backend/migrations/0018_scheduled_reports.sql` |
| Cron handler | `qr_cf_code/src/index.js` (`scheduled()`, lines 41–70) |
| Cron triggers | `qr_cf_code/wrangler.toml` (dev + prod `triggers.crons`) |
| Analytics page (dead buttons → handlers) | `qr_frontend/src/app/org/[slug]/(dash)/analytics/page.tsx:148-151` |
| Per-QR export buttons | `qr_frontend/src/components/org/qrs/details/qr-analytics-card.tsx` |
| Schedule modal + alerts card (new) | `qr_frontend/src/components/org/analytics/{schedule-report-modal,alerts-card}.tsx` |
| Hooks + key factory | `qr_frontend/src/hooks/useAnalytics.ts` |
| Plan features (FE) | `qr_frontend/src/lib/plan-features.ts` (`canAccessFeature`), `qr_frontend/src/hooks/useSubscription.ts` (`PlanFeatures`) |
