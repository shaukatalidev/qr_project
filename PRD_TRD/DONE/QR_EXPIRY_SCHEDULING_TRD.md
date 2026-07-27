# TRD — QR Expiry + Campaign Scheduling

**Status:** Draft · **Author:** Engineering (Staff) · **Date:** 2026-07-25
**Priority:** Table-stakes parity (Beaconstac/Bitly/QR Tiger/QRCodeChimp/Scanova all ship it). Close the gap with the minimum correct surface; the only hard part is timezone correctness + edge-time enforcement.
**Tiers:** **All plans, ungated (v1).** Optional `qr_scheduling` Starter+ upsell flag is a product call, not a technical need (PRD §8 / Open Q1).
**Plan flags (NEW):** **None in v1.** If the upsell path is chosen: `qr_scheduling` (bool), seeded as a full-object `'{...}'::jsonb` blob and registered `inert`→`enforced` in the same PR (house convention; `test_feature_gate_coverage` stays green).
**Migration slot:** **`0033`** (`0033_qr_expiry_scheduling.sql`). Verified against disk: highest existing = `0032_lemonsqueezy_variant_backfill.sql`, so `0033` is the next free slot. **Re-verify at build time** — do not trust this header if other migrations land first (the repo has a commit fixing stale slot numbers).
**Services touched:** `qr_backend` (3 `qr_codes` columns + `qr_blocked_scans` counter, model fields, single-writer KV pass-through, one new `/internal/blocked-scan` endpoint) · `qr_cf_code` (edge window check + one new system page + `recordBlockedScan` helper — **requires `npm run deploy:prod`**) · `qr_frontend` (builder Schedule section + dashboard badge/read-out). **No AI, no email, no new cron.**
**Implements PRD:** QR Expiry + Campaign Scheduling. **Mirrors** the Worker system-page pattern (`disabledPage.js` `buildPage()`) and the KV-snapshot path (`sync_qr_to_kv` → `write_to_kv`).

**Rev (2026-07-25, post eng-review):** Reviewed via `/plan-eng-review` + an outside-voice pass. Scope accepted as orthogonal-to-`status` / no-cron / edge-enforced (correct). Decisions folded: ungated all-plans (confirmed, columns-only gating); event/coupon display dates left independent; **timezone = author-zone** (store `schedule_tz` IANA + UTC instants, render in the authoring zone via `Intl` — supersedes every "IST" mention below and turns `istLocalToUtcIso`/`utcIsoToIstParts` into zone-aware helpers); **blocked scans recorded to a separate, non-billable counter.** Correctness fixes: (1) **CRITICAL — blocked scans must NOT touch `qr_scan_events`/`qr_scan_counters`.** `_enforce_scan_limit` (internal.py) counts `qr_scan_events` by workspace with no type filter and runs after every insert, so routing blocked scans through `/internal/scans` would count them toward the cap **and could flip the workspace's *other* active dynamic QRs to `disabled`.** Blocked scans go to a new `qr_blocked_scans` aggregate counter via a dedicated `/internal/blocked-scan` endpoint, read by nobody in the billable/analytics path. (2) **CRITICAL — KV timestamp format.** Normalize `start_at`/`end_at` to a strict `…Z` ISO string in Python on **both** write paths (create used `.isoformat()`→`+00:00`; `sync_qr_to_kv` passed the raw PostgREST value, which can be space-separated `+00` → `Date.parse` `NaN` in V8 → with fail-open the QR silently never expires). Unit-test `Date.parse` against the **real Supabase-returned** string, not a hand-written literal. (3) **Single-writer KV.** Populate the window into KV **only** through `sync_qr_to_kv` (reads DB truth); route all create/update KV refreshes through it and audit the **three** direct `write_to_kv` callers in `qr.py` — a `None`-defaulted param on a missed caller silently strips the window. (4) **Worker placement pinned** to a single spot: immediately after the `status`/`locked` branches (post-`index.js` L381), **before** the `website` early-return (L405) and the password gate (L383); the "before `recordScan` ~L415" anchor is deleted (it would miss website QRs). (5) **Fail-open + loud log:** an unparseable `end_at` still fails open (never dark a live QR) but emits a **loud Worker error log** + canary coverage. Migration `0033` accordingly adds `schedule_tz` + the `qr_blocked_scans` counter — no longer "columns-only."

---

## 1. Overview & Architecture

A **dynamic** QR gains two optional UTC timestamps — `start_at` (go-live) and `end_at` (expiry). Both are
plain columns on `qr_codes`, snapshotted into the KV payload alongside the existing `status`. On every scan
the **Cloudflare Worker** compares "now" to the stored window (right after the `status` branches, before the
password gate) and, if outside it, returns a new branded system page **without recording a scan** — exactly
how the scan-limit page blocks today. Inside the window, or when no window is set, behavior is byte-for-byte
unchanged.

**The design is deliberately orthogonal to `qr_codes.status`.** We add **no** status value and **no** cron.
The five-value status enum (active/paused/disabled/locked/inactive) and every transition path
(`_enforce_scan_limit`, `_reenable_free_scan_disabled`, `_lock_excess_dynamic_qrs_for_workspace`, billing
re-enable) are untouched. The dashboard derives Scheduled/Active/Expired **client-side** from the columns.
This buys exact-at-scan-time enforcement (a printed QR stops the instant it expires, no sweep lag) and
avoids multiplying an already-overloaded state machine.

**Services touched**

| Service | Change |
|---|---|
| `qr_backend` | Migration `0033` (2 nullable `timestamptz` columns on `qr_codes`); `start_at`/`end_at` on the QR create/update Pydantic models + window validation; pass the two values through the create `write_to_kv(...)` call and add them to `sync_qr_to_kv`'s select + `write_to_kv` signature/payload. **No** gating, RPC, internal endpoint, or cron in v1. |
| `qr_cf_code` | Parse `start_at`/`end_at` from KV; a time-window check in `src/index.js` beside the status branches; **new** `src/pages/schedulePage.js` (not-yet-live + expired states, mirrors `disabledPage.js`). **Requires prod worker deploy.** |
| `qr_frontend` | Builder "Schedule" section (IST date-time pickers → UTC on submit, zod window validation) on create + edit; static-QR inline note; dashboard derived badge; a small hook/util for IST↔UTC. |

**Data flow — setting a window (create/edit)**

```
Builder Schedule section (IST pickers)
  → convert IST → UTC ISO-8601 (with Z) client-side; zod: end_at > start_at
  → authApi POST/PATCH /workspaces/{id}/qrs[/{qr_id}] { ..., start_at, end_at }
  → qr.py: window validation (server-side, defense-in-depth) → persist to qr_codes
      (create: INSERT columns; update: model_dump direct-column write — no special-casing)
  → create → write_to_kv(..., schedule_start=iso, schedule_end=iso)
    update/any transition → sync_qr_to_kv(qr_id) → reads columns → write_to_kv(...)
  → KV entry now carries { ..., "schedule_start": "...Z"|null, "schedule_end": "...Z"|null }
```

**Data flow — enforcement (scan)**

```
GET /:shortCode → env.QR_KV.get(shortCode) → parse { status, schedule_start, schedule_end, ... }
  → if status paused/disabled/locked → existing pages (precedence)
  → else if schedule_start && Date.now() <  Date.parse(schedule_start) → schedulePage(NOT_YET_LIVE)   [no scan]
  → else if schedule_end   && Date.now() >= Date.parse(schedule_end)   → schedulePage(EXPIRED)         [no scan]
  → else → password gate → routing → redirect / handleQRCode (unchanged)
```

The window check sits **before** `recordScan` (line ~415) so a blocked scan records nothing — consistent
with scan-limit/paused/locked.

---

## 2. Data Model & Migrations

Three columns on `qr_codes` (`start_at`, `end_at`, `schedule_tz`) plus **one new non-billable counter
table** `qr_blocked_scans`. No RLS change on `qr_codes` (base schema, already service-role-only); the new
table gets `ENABLE ROW LEVEL SECURITY` with no policies (service-role-only, defense-in-depth). `NULL` on
either window side = unbounded (no start = live now; no end = never expires). Window instants are UTC;
`schedule_tz` records the IANA zone the window was authored in (for correct, viewer-independent display).

**`qr_backend/migrations/0033_qr_expiry_scheduling.sql`** — BEGIN/COMMIT-wrapped, idempotent
(`ADD COLUMN IF NOT EXISTS` / `IF NOT EXISTS`), applied by hand in the Supabase SQL editor.

```sql
BEGIN;

-- ── Campaign scheduling window for DYNAMIC QRs (all UTC; edge-enforced from KV) ──
-- start_at:     QR is "not yet live" before this instant (NULL = live immediately).
-- end_at:       QR is "expired" at/after this instant     (NULL = never expires).
-- schedule_tz:  IANA zone the window was authored in (e.g. 'Asia/Kolkata',
--               'America/New_York') so the dashboard renders the window in the zone
--               it was SET in, not the viewer's. NULL = legacy/none.
-- Enforced at the Cloudflare edge from the KV snapshot — NOT via qr_codes.status,
-- and NOT via any cron. No new status value is introduced.
ALTER TABLE qr_codes ADD COLUMN IF NOT EXISTS start_at    timestamptz;
ALTER TABLE qr_codes ADD COLUMN IF NOT EXISTS end_at      timestamptz;
ALTER TABLE qr_codes ADD COLUMN IF NOT EXISTS schedule_tz text;

-- Partial indexes: the dashboard "expiring soon / scheduled" filters scan only rows
-- that actually set a bound. Cheap; skips the vast NULL majority. (No cron reads these.)
CREATE INDEX IF NOT EXISTS idx_qr_codes_end_at
  ON qr_codes (end_at) WHERE end_at IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_qr_codes_start_at
  ON qr_codes (start_at) WHERE start_at IS NOT NULL;

-- ── Non-billable blocked-scan counter (owner-visible "still being scanned") ──
-- A per-(qr, day, reason) aggregate. DELIBERATELY SEPARATE from qr_scan_events /
-- qr_scan_counters: _enforce_scan_limit counts qr_scan_events by workspace with no
-- type filter and runs after every insert, so a scanned expired QR routed through
-- the normal scan path would (a) burn the billable cap and (b) trip scan-cap
-- auto-disable on the workspace's OTHER live QRs. Nothing in the billable/analytics
-- path ever reads this table.
CREATE TABLE IF NOT EXISTS qr_blocked_scans (
    qr_id          uuid    NOT NULL REFERENCES qr_codes(id) ON DELETE CASCADE,
    workspace_id   uuid    NOT NULL REFERENCES workspaces(id) ON DELETE CASCADE,
    day            date    NOT NULL,
    blocked_reason text    NOT NULL,          -- 'not_yet_live' | 'expired'
    count          integer NOT NULL DEFAULT 0,
    updated_at     timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (qr_id, day, blocked_reason)
);
ALTER TABLE qr_blocked_scans ENABLE ROW LEVEL SECURITY;  -- no policies → service-role only

-- Atomic day-bucket increment (mirrors the increment_*_usage upsert convention).
CREATE OR REPLACE FUNCTION increment_blocked_scan(
    p_qr_id uuid, p_workspace_id uuid, p_day date, p_reason text
) RETURNS void LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO qr_blocked_scans (qr_id, workspace_id, day, blocked_reason, count, updated_at)
    VALUES (p_qr_id, p_workspace_id, p_day, p_reason, 1, now())
    ON CONFLICT (qr_id, day, blocked_reason)
    DO UPDATE SET count = qr_blocked_scans.count + 1, updated_at = now();
END;
$$;

COMMIT;

-- Sanity:
--   SELECT id, status, start_at, end_at, schedule_tz FROM qr_codes
--    WHERE start_at IS NOT NULL OR end_at IS NOT NULL LIMIT 20;
--   SELECT * FROM qr_blocked_scans ORDER BY updated_at DESC LIMIT 20;
```

**No plan-flag seed in v1** (ungated). *If* product elects the `qr_scheduling` upsell, add — in the same
build PR — a full-object `'{...}'::jsonb` blob seed (per the `0014`/`0026` convention, so
`test_feature_gate_coverage._seed_feature_keys()` discovers the key) plus the per-tier enable UPDATEs, using
`lower(name)` + `coalesce(is_custom,false)=false` guards. Not included here to keep v1 columns-only.

No change to `qr_destinations`, `qr_designs`, `qr_scan_events`, or the per-type detail tables. The decorative
`event.end_date` / `coupon.valid_until` display fields are **left independent** in v1 (PRD §11 R5).

---

## 3. Backend Design

### 3.1 Models + validation — `qr_backend/src/api/routes/qr.py`
Add two optional fields to the QR **create** model (near `status: Optional[str] = "active"`, ~L866) and the
**update** model:
```python
start_at: Optional[datetime] = None   # UTC go-live; None = live immediately
end_at:   Optional[datetime] = None   # UTC expiry;  None = never expires
```
Both are direct `qr_codes` columns, so on update they flow through the existing
`update_data = payload.model_dump(exclude_unset=True)` path (~L2839) with **no** special-casing — they are
**not** popped like `content`/`destinations`/`design`/`page_design` (which aren't columns). The status-
restriction block (~L2806–2836) is untouched: the window is orthogonal to `status`.

**Server-side validation** (defense-in-depth; the client also validates):
- If both set, require `end_at > start_at` → `422` otherwise.
- **Dynamic-only:** reject a window on a `category == "static"` QR → `422` ("Scheduling requires a dynamic QR")
  — static QRs never reach the Worker, so a window on them would silently do nothing.
- Normalize to timezone-aware UTC. Reject naive datetimes (or coerce as UTC with an explicit rule) — never
  store a floating/naive instant. An `end_at` in the past is **allowed on update** (immediate expiry — a
  legitimate "kill it now") but **warned/allowed on create** per PRD Open Q4 (recommend: allow, surface a UI
  warning, don't hard-block).

**Serialization to KV:** `qr_codes` reads return ISO-8601 strings (so the `sync_qr_to_kv` path is clean);
the **create** path holds `datetime` objects, so pass `start_at.isoformat()` / `end_at.isoformat()` (or
`None`) into `write_to_kv` — `json.dumps` cannot serialize a raw `datetime`. Store/emit with an explicit
`Z`/offset so the Worker's `Date.parse` is unambiguous UTC.

### 3.2 KV snapshot — `qr_backend/src/utilities/cloudflare_kv.py` (single-writer)
**Populate the window into KV via `sync_qr_to_kv` ONLY** — do not hand-assemble it in the direct
`write_to_kv` callers. `write_to_kv`'s new params default to `None`, so any direct caller that forgets them
writes `null` → **silently strips the window at the edge → enforcement stops**. There are **three** direct
`write_to_kv(...)` callers in `qr.py` (approx. L2258 / L2567 / L3318) plus `sync_qr_to_kv`. The fix:

1. **`write_to_kv(...)`** (~L52): add params `schedule_start`, `schedule_end`, `schedule_tz` (all
   `str | None = None`); add them to the `payload` dict (~L93) as top-level keys next to `status`
   (`"schedule_start"` / `"schedule_end"` are **strict `…Z` ISO-8601 UTC strings or `null`**; `schedule_tz`
   is the IANA zone string or `null`).
2. **`sync_qr_to_kv(qr_id, supabase)`** (~L307) is the **only** function that fills those params: extend the
   `qr_codes` select (~L324) to include `start_at, end_at, schedule_tz`; pass
   `schedule_start=_to_utc_z(qr.get("start_at"))`, `schedule_end=_to_utc_z(qr.get("end_at"))`,
   `schedule_tz=qr.get("schedule_tz")` into the `write_to_kv(...)` call (~L370). This is the canonical
   "make KV match DB" path used by create-refresh, scan-limit disable/re-enable, and billing enable/lock.
3. **Route every create/update/refresh KV write through `sync_qr_to_kv(qr_id)`** after persisting the
   columns — i.e. **audit the three direct `write_to_kv` callers** and convert each windowed path to call
   `sync_qr_to_kv` (or explicitly pass the three fields). This is the resolution to old Open Q4: one writer,
   no strip risk.

**`_to_utc_z(v)` — the format-normalization helper (CRITICAL).** `timestamptz` values come back from
PostgREST as strings whose exact shape varies (`"…+00:00"` vs space-separated `"… +00"`); Python's
`.isoformat()` yields `+00:00`, **not** `Z`. The Cloudflare Worker parses these with `Date.parse`, which is
**implementation-defined for non-`Z` / space-separated forms and can return `NaN` in V8** → under fail-open
that means the QR **never expires, silently**. `_to_utc_z` parses whatever Postgres/Pydantic hands us and
re-emits a canonical `YYYY-MM-DDTHH:MM:SSZ` string (UTC, `Z`-suffixed) so the edge parse is unambiguous.
Both `datetime` objects (create path) and PostgREST strings (`sync_qr_to_kv`) go through it. This is unit-
tested against the **actual Supabase-returned** value, not a hand-written literal (§10).

### 3.3 Gating
**None in v1** (ungated, all plans). The columns are populated regardless of tier; the Worker enforces for
everyone. No `FEATURE_ENFORCEMENT` entry, no `_QUOTA_SPEC`, no coverage-test surface — the migration is
columns-only. *(Upsell path: add `qr_scheduling` per §2 note + a `check_feature`/`canAccessFeature` gate on
the builder Schedule section and a backend guard in `qr.py`.)*

### 3.4 Internal endpoints / cron
**No cron in v1.** Window *enforcement* is entirely edge-side from the KV snapshot; lifecycle *display* state
is derived client-side. *(A future "your QR expired" email would add a daily ping — e.g. reuse the existing
`0 6 * * *` cron with a new `/internal/expiry-notify` — but that's out of scope and explicitly deferred to
avoid the prod-worker-cron gate for v1.)*

### 3.5 Blocked-scan recording — `POST /internal/blocked-scan`
The one new internal endpoint (added to `qr_backend/src/api/routes/internal.py`, router-level
`Depends(verify_internal_secret)` — Worker sends `x-internal-secret`, same pattern as `/internal/scans`).
Body `{ qr_id, workspace_id, blocked_reason }` (`blocked_reason ∈ {"not_yet_live","expired"}`). It calls the
`increment_blocked_scan(qr_id, workspace_id, today_utc, reason)` RPC (§2) and returns `{"status":"ok"}`.
**It deliberately does NOT** insert into `qr_scan_events`, touch `qr_scan_counters`, run `_enforce_scan_limit`,
or fan out webhooks — a blocked scan is not a billable/analytics scan. Fire-and-forget from the Worker
(`ctx.waitUntil`), errors swallowed (never blocks the scanner's page). Owner read-out: a small aggregate over
`qr_blocked_scans` surfaced on the QR detail ("scanned 42× while expired — extend?"), reusing the QR read
path — no new hot-path query.

---

## 4. Cloudflare Worker / Edge Design

**This is the crux and the only edge change.** In `qr_cf_code/src/index.js`:

1. **Parse** the fields from KV (~L353, alongside `status`):
   ```js
   const { qr_id, status, workspace_id, is_password_protected,
           schedule_start, schedule_end } = parsedData;   // schedule_tz not needed at the edge
   ```
2. **Window check — pinned to ONE location.** Insert it **immediately after the `status`/`locked` branches
   (post-L381)** and **before both the `website` early-return (L405) and the password gate (L383)**. This
   single placement is load-bearing: `website` QRs short-circuit to `handleWebsiteRedirect` at L405 (which
   does its own `recordScan`) and return *before* the generic `recordScan` at L415 — so anchoring the check
   "before `recordScan` ~L415" would let expired **website** QRs keep redirecting. Placing it at post-L381
   covers every type. Precedence: paused/disabled/locked still win (PRD §6.4).
   ```js
   // Campaign schedule window — edge-enforced from the KV snapshot; no cron, no
   // qr_codes.status change. Inclusive start, exclusive end. An unparseable/absent
   // timestamp is treated as "no bound" (FAIL-OPEN to normal serving) — a bad value
   // must never brick a live QR — but an unparseable value is LOUD-LOGGED (below),
   // because a silently-non-expiring QR is the exact failure this feature prevents.
   const nowMs = Date.now();
   const startMs = schedule_start ? Date.parse(schedule_start) : NaN;
   const endMs   = schedule_end   ? Date.parse(schedule_end)   : NaN;
   // Loud log on a present-but-unparseable bound (systematic bad KV write → caught).
   if (schedule_start && Number.isNaN(startMs))
     console.error(`[schedule] unparseable start_at for ${shortCode}: ${schedule_start}`);
   if (schedule_end && Number.isNaN(endMs))
     console.error(`[schedule] unparseable end_at for ${shortCode}: ${schedule_end}`);
   if (!Number.isNaN(startMs) && nowMs < startMs) {
     ctx.waitUntil(recordBlockedScan(request, env, qr_id, workspace_id, "not_yet_live"));
     return getSchedulePage({ state: "not_yet_live", whiteLabel, brand });
   }
   if (!Number.isNaN(endMs) && nowMs >= endMs) {
     ctx.waitUntil(recordBlockedScan(request, env, qr_id, workspace_id, "expired"));
     return getSchedulePage({ state: "expired", whiteLabel, brand });
   }
   ```
   `Date.parse` on a strict `…Z` ISO-8601 string (guaranteed by `_to_utc_z`, §3.2) yields a correct UTC
   epoch; the Worker runtime clock is UTC — no local-time ambiguity. **Blocked scans are recorded** via
   `ctx.waitUntil(recordBlockedScan(...))` — a fire-and-forget POST to the **new** `/internal/blocked-scan`
   endpoint (§3.5), which writes only to `qr_blocked_scans`. It **never** calls `recordScan` /
   `/internal/scans`, so a blocked scan never touches `qr_scan_events` / `qr_scan_counters` and cannot count
   toward the billable cap or trip `_enforce_scan_limit` on the workspace's other QRs. `recordBlockedScan`
   lives in `qr_cf_code/src/utils/scan.js` (mirrors `recordScan`'s `x-internal-secret` fire-and-forget shape).

3. **New system page** `qr_cf_code/src/pages/schedulePage.js` — mirror `disabledPage.js`'s shared
   `buildPage()` helper (accentColor/badge/title/description/svgPath + `{ whiteLabel, brand }`, returns 200 +
   `Cache-Control: no-store`). One export `getSchedulePage({ state, whiteLabel, brand })` with two variants:
   - `not_yet_live` — amber (like `getPausedPage`): badge "Scheduled", "This QR code isn't active yet",
     generic copy (do **not** leak the go-live date to scanners — PRD Open Q2).
   - `expired` — red (like `getDisabledPage`): badge "Expired", "This QR code has expired".
   Import `getSchedulePage` at the top of `index.js` next to the other page imports.

**Custom-domain / white-label:** the page already receives `{ whiteLabel, brand }` from the same
`parsedData.entitlements` the other system pages read — no extra work.

**Deploy gate:** because the Worker changes, **`npm run deploy:prod` is required** to enforce in production
(and `npm run deploy` to staging first). No `wrangler.toml` change (no new cron/route/KV namespace).

---

## 5. Frontend Design

### 5.1 Types + author-timezone ↔ UTC conversion
Add `start_at?: string | null` / `end_at?: string | null` (ISO-8601 UTC) **and `schedule_tz?: string | null`**
(IANA zone) to the QR create/update types and the QR read model. A small pure util
(`qr_frontend/src/lib/schedule.ts`), **zone-aware via `Intl` (not a fixed offset — a fixed offset breaks on
DST and on non-IST zones)**:
- `authorTz()` → `Intl.DateTimeFormat().resolvedOptions().timeZone` (the entry-time browser zone; sent as
  `schedule_tz`).
- `zonedLocalToUtcIso(localParts, tz)` → the UTC `…Z` instant for a wall-clock time in `tz`.
- `utcIsoToZonedParts(iso, tz)` / `formatInZone(iso, tz)` → render an instant in the **stored** `schedule_tz`
  (NOT the viewer's zone), with a zone label.

**All storage/transport is UTC ISO with `Z`; the window is always displayed in `schedule_tz`** (the zone it
was authored in) so a viewer in another zone sees the same wall-clock the author typed. zod on the builder
form: `start_at`/`end_at` optional; if both present `refine(end > start)`; a past `end_at` warns on create,
allowed on edit; static QR → fields omitted entirely.

### 5.2 Builder "Schedule" section
A new collapsed-by-default section in the QR builder (create **and** edit), its own kebab-case, one-export
component (≤200 lines) under `qr_frontend/src/components/qr-generator/`, using shadcn date-time primitives
(no raw `<input>`, no inline styles, Tailwind tokens only). Two optional pickers, **"Go live"** and
**"Expires"**, each labeled with the **detected browser timezone** (e.g. "Times are in Asia/Kolkata (IST)"),
resolved via `authorTz()`. On submit, values convert to UTC ISO via §5.1, and `schedule_tz` is set to the
detected zone, riding the existing create/update payload. For a `static` QR, render the inline
convert-to-dynamic note instead of the pickers (PRD §6.1). react-hook-form + zod only (no uncontrolled inputs,
no `useEffect + fetch`).

### 5.3 Dashboard derived badge + blocked-scan read-out
In the QR list/detail, compute the lifecycle chip client-side from the columns (no server field): `now <
start_at` → **Scheduled**; `now >= end_at` → **Expired**; else **Active** — rendered alongside the existing
Paused/Disabled/Locked chips (status chips win visually, matching edge precedence). Show the relevant date
inline, **formatted in `schedule_tz`** via `formatInZone` (§5.1) with the zone label ("Live from 5 Aug,
9:00 AM IST" / "Expired 31 Jul, 11:59 PM IST") — never the viewer's zone. On an **expired** QR's detail,
surface the blocked-scan aggregate ("scanned 42× since it expired — extend?") from the `qr_blocked_scans`
read-out, with an inline "extend / clear expiry" action.

### 5.4 Hook / API
No new endpoint — the window fields ride the **existing** QR create/update mutations (the `useQRs` family in
`qr_frontend/src/hooks/`). Extend those hooks' payload types; no new query key. `workspaceId` from the
workspace store per house rule.

---

## 6. External-Service Integration

**None.** No AI, no Anthropic call, no email/Resend, no PDF/WeasyPrint, no payment provider. The only edge
"integration" is the existing Cloudflare KV read the Worker already performs. `_dmarc.qravio.app` is **not** a
gate (no email). No new environment variables or secrets.

---

## 7. API Contracts

The window rides the existing QR create/update endpoints — no new route.

```jsonc
// POST /api/v1/workspaces/{workspace_id}/qrs   (create)  — new optional fields
// PATCH /api/v1/workspaces/{workspace_id}/qrs/{qr_id}    (update) — same
{
  // ...existing QR fields...
  "start_at":    "2026-08-05T03:30:00Z",   // UTC ISO-8601; null/omitted = live immediately
  "end_at":      "2026-07-31T18:29:00Z",   // UTC ISO-8601; null/omitted = never expires
  "schedule_tz": "Asia/Kolkata"            // IANA zone the window was authored in (for display)
}

// 422 — window invalid
{ "detail": "end_at must be after start_at." }
// 422 — window on a static QR
{ "detail": "Scheduling requires a dynamic QR." }
```

The QR **read** response includes `start_at` / `end_at` / `schedule_tz` (UTC ISO / IANA or `null`) so the
dashboard can derive the badge and render it in the authoring zone.

**Internal (Worker → backend), new:**
```jsonc
// POST /api/v1/internal/blocked-scan   (x-internal-secret; fire-and-forget)
{ "qr_id": "uuid", "workspace_id": "uuid", "blocked_reason": "expired" }  // or "not_yet_live"
// → { "status": "ok" }   — increments qr_blocked_scans only; never qr_scan_events
```

KV value gains three top-level keys (`schedule_start`/`schedule_end` are strict `…Z` strings — see `_to_utc_z`):
```jsonc
{ /* ...existing... */ "status": "active",
  "schedule_start": "2026-08-05T03:30:00Z", "schedule_end": null, "schedule_tz": "Asia/Kolkata" }
```

---

## 8. Security, Privacy & Abuse

- **Not a security boundary, and we don't pretend it is.** Expiry stops the *redirect/landing page* at our
  edge; it is a lifecycle control, not access control. Content that was already public during the window
  isn't retroactively secret. (Password protection remains the access-control mechanism and still runs —
  after the window check, only for in-window scans.)
- **No scanner data leak:** the scheduled/expired page is generic and names no owner data; the go-live date is
  intentionally **not** shown to scanners (PRD Open Q2). No PII introduced anywhere; the two columns are
  timestamps.
- **Tenant isolation unchanged:** the window is read from the same per-`shortCode` KV entry already scoped by
  the custom-domain workspace check; no cross-tenant surface.
- **Abuse:** no per-use cost, no new unauthenticated surface (fields ride the Bearer-authed, `require_can_*`-
  gated QR endpoints). A malformed KV timestamp **fails open** to normal serving (a bad value must never
  brick a live QR); the worst case is a window that doesn't enforce, caught by the canary + tests.
- **Fail-open rationale:** unlike scan-limit (fail-open to avoid blocking paid scans), expiry fail-open means
  "serve normally if the window is unreadable" — the safe default for a parity feature (never dark a working
  QR on a parse bug).

---

## 9. Performance, Scale & Cost

- **Edge:** two `Date.parse` + two integer compares per scan — nanoseconds, pure CPU, no added network call,
  no added KV read (the fields ride the entry already fetched). Hot path unchanged for the no-window majority
  (both fields `null` → both branches skipped).
- **Backend:** two extra columns in the QR read/write; the KV payload grows by two short strings. Negligible.
- **DB:** two partial indexes covering only rows that set a bound (the vast majority are `NULL`) — near-zero
  storage/write cost, and they make any future "expiring soon" dashboard filter or notify-sweep cheap.
- **No cron, no jobs, no fan-out, no per-use COGS.** The throttle is n/a — there's nothing to throttle.

---

## 10. Testing Strategy

**Backend (pytest, `qr_backend/tests/`):**
- `test_schedule_persist`: create/update with `start_at`/`end_at`/`schedule_tz` persists to `qr_codes` and the
  values reach KV via `sync_qr_to_kv` (assert the `write_to_kv` payload carries `schedule_start`/`schedule_end`/
  `schedule_tz`); round-trips from the DB.
- `test_schedule_validation`: `end_at <= start_at` → 422; a window on a `static` QR → 422; naive datetime
  handled per the chosen rule; past `end_at` on update allowed.
- **`test_to_utc_z` (CRITICAL):** feed `_to_utc_z` the **actual Supabase-returned** `timestamptz` string (both
  the `+00:00` and space-separated `+00` shapes) **and** a `datetime`; assert it always emits a strict
  `…Z` string that `Date.parse` accepts (guard against the silent-never-expire bug). `None` → JSON `null`.
- **`test_blocked_scan_not_billable` (CRITICAL regression):** posting to `/internal/blocked-scan` increments
  `qr_blocked_scans` **only** — asserts **no** `qr_scan_events` row, **no** `qr_scan_counters` mutation, and
  that `_enforce_scan_limit` is **not** invoked / the workspace's other `active` dynamic QRs are **not**
  flipped to `disabled`. This is the landmine test; it must fail loudly if blocked scans ever leak into the
  billable path.
- **Status orthogonality regression:** paused/disabled/locked transitions and `_reenable_free_scan_disabled`
  still behave exactly as before with window columns present (the window must not perturb the status machine).

**Worker (`qr_cf_code`, hand-rolled `*.test.mjs` run via `node` — the house convention, e.g.
`src/scheduled.test.mjs`):** add `src/schedule.test.mjs` —
- before `start_at` → `not_yet_live` page **+ one `recordBlockedScan` call** (mock the fetch, assert it hits
  `/internal/blocked-scan`, **not** `/internal/scans`); after `end_at` → `expired` page + blocked-scan call;
  inside window / both `null` → normal dispatch, no blocked-scan call.
- **Website coverage:** a `type:"website"` QR that is expired shows the expired page and does **not** reach
  `handleWebsiteRedirect` — proves the check sits before the L405 early-return.
- **Precedence:** `status='paused'|'disabled'|'locked'` wins over any window.
- Malformed/`NaN` timestamp → **fails open** to normal serving (not a 500, not a dark QR) **and** emits the
  loud `console.error` (assert the log).
- Inclusive-start / exclusive-end boundary (`now == start_at` serves; `now == end_at` expires).

**Frontend (Vitest):** the **author-zone ↔ UTC round-trip is a release gate** — "expires 31 Jul 11:59 PM" in
`Asia/Kolkata` serializes to `2026-07-31T18:29:00Z` and renders back to the same wall-clock **in
`Asia/Kolkata`** regardless of the test runner's TZ (the R1 correctness bar; run the test under a non-IST
`TZ=America/New_York` to prove viewer-independence). zod window validation (end > start); static QR shows the
convert note, not pickers; the derived Scheduled/Active/Expired badge matches given fixture columns + a fixed
"now".

**Manual / canary:** a staging canary QR with a ~2-minute window — scan before (scheduled page), inside
(redirect), after (expired page), confirming edge enforcement, blocked-scan rows appear in `qr_blocked_scans`,
and **the billable scan count does not move**.

---

## 11. Observability & Rollout

**Phase 0 — Backend + edge (internal/staging).** Apply `0033`; add model fields + validation; thread the two
values through `write_to_kv` + `sync_qr_to_kv` (+ the direct create call); add the edge window check +
`schedulePage.js`; `npm run deploy` to staging. Verify with the canary QR (before/in/after, precedence, no
scan recorded).

**Phase 1 — Builder + dashboard (closed).** Schedule section (IST pickers → UTC, zod), static note, derived
badge, behind a FE flag for internal + design partners. Run the IST↔UTC round-trip gate.

**Phase 2 — GA.** Remove the FE flag; **`npm run deploy:prod`** the Worker; update the comparison matrix +
`/beaconstac-alternative` SEO page + help center. (Upsell path only: flip `qr_scheduling` `inert`→`enforced`.)

**Deploy order:** apply migration `0033` → deploy backend (KV now writes the fields) → deploy Worker
(enforcement). A Worker deployed before the backend writes the fields simply sees "no window" (both branches
skip) — safe — but apply the migration first regardless. **No email/DMARC gate. No cron gate.**

**Metrics / logs:** % of new dynamic QRs with a window (adoption); count of scans hitting the scheduled/expired
page (structured Worker log: `shortCode`, `state`, no PII); zero false-expiry (canary + ticket watch);
IST↔UTC gate green. No new dashboard infra — derive from existing scan logs + the columns.

---

## 12. Open Technical Questions & Risks

1. **Two columns vs `qr_schedule` detail table** — resolved: **columns on `qr_codes`** (`start_at`, `end_at`,
   `schedule_tz`). 1:1 QR property; the update path writes unknown `qr_codes` columns directly; trivial KV
   snapshot. (One separate table — `qr_blocked_scans` — is added, but for the non-billable counter, not the
   window itself.)
2. **No status flip / no cron** — resolved: the edge enforces from the snapshot; display state is derived.
   **Reconciled with the blocked-scan decision:** blocked scans now *do* produce events, but they land in the
   isolated `qr_blocked_scans` table that **no** existing consumer reads (`_enforce_scan_limit`, analytics,
   webhooks all read `qr_scan_events`), so the "no persisted `expired` status needed" conclusion still holds —
   nothing in the billable/analytics path depends on a status flip.
3. **Naive-datetime policy** — resolved (recommend strict-reject at the API; the client always sends
   `Z`-suffixed UTC, so a naive value signals a client bug worth surfacing, not silently coercing).
4. **Single-writer KV (was "both paths must carry the fields")** — resolved: the window is populated into KV
   **only** by `sync_qr_to_kv`; every create/update/refresh routes its KV write through it, and the **three**
   direct `write_to_kv` callers in `qr.py` are audited so none finalizes a windowed QR's KV with the params
   defaulted to `None` (which would strip the window). §3.2.
5. **Timestamp format (CRITICAL, new)** — resolved: `_to_utc_z` normalizes both `datetime` and PostgREST
   string inputs to a strict `…Z` ISO-8601, tested against the real Supabase-returned value — because
   `Date.parse` on a non-`Z`/space-separated form is `NaN` in V8 and, under fail-open, that silently means
   "never expires."
6. **Blocked-scan storage (new)** — resolved: a dedicated `qr_blocked_scans` aggregate + `/internal/blocked-
   scan` endpoint, deliberately outside `qr_scan_events`/`qr_scan_counters`/`_enforce_scan_limit`. A
   discriminator column on `qr_scan_events` was rejected — it would risk polluting every billable/analytics
   count query.
7. **event/coupon dual-date confusion (PRD R5)** — v1 keeps the decorative `end_date`/`valid_until` and the
   enforced `end_at` independent, disambiguated by builder copy. Unifying them is future cleanup.
8. **Fail-open direction** — confirmed: a malformed/unparseable window fails **open** (serve normally) **but
   loud-logs**. Never dark a live QR on a parse bug; the loud log + canary catch a systematically-broken write.

### Appendix — Key Files

| Concern | File |
|---|---|
| Window cols + tz + blocked counter | `qr_backend/migrations/0033_qr_expiry_scheduling.sql` (NEW — `start_at`, `end_at`, `schedule_tz` + `qr_blocked_scans` table + `increment_blocked_scan` RPC) |
| Model fields + validation + persist | `qr_backend/src/api/routes/qr.py` (create/update models ~L865; update direct-column path ~L2839; status block ~L2806 untouched) |
| KV snapshot (single-writer) | `qr_backend/src/utilities/cloudflare_kv.py` (`write_to_kv` params+payload ~L52/L93 + `_to_utc_z` helper; `sync_qr_to_kv` select+call ~L324/L370). **Audit the 3 direct `write_to_kv` callers in `qr.py`** (~L2258/L2567/L3318) |
| Blocked-scan endpoint | `qr_backend/src/api/routes/internal.py` (NEW `POST /internal/blocked-scan` → `increment_blocked_scan`; never touches `qr_scan_events`/`_enforce_scan_limit`) |
| Edge enforcement | `qr_cf_code/src/index.js` (parse ~L353; window check **post-status-branches L381, before the website early-return L405 AND password gate L383**) |
| Blocked-scan Worker helper | `qr_cf_code/src/utils/scan.js` (NEW `recordBlockedScan` — `x-internal-secret` fire-and-forget, mirrors `recordScan`) |
| Scanner system page | `qr_cf_code/src/pages/schedulePage.js` (NEW — mirrors `disabledPage.js` `buildPage()`; `not_yet_live` + `expired`) |
| Builder Schedule UI | `qr_frontend/src/components/qr-generator/` (NEW section, ≤200 lines) + `qr_frontend/src/lib/schedule.ts` (author-zone ↔ UTC via `Intl`) |
| Dashboard badge + blocked read-out | `qr_frontend` QR list/detail (derive Scheduled/Active/Expired; render in `schedule_tz`; show `qr_blocked_scans` count on expired) |
| QR mutation hooks | `qr_frontend/src/hooks/` (`useQRs` family — extend create/update payload with `start_at`/`end_at`/`schedule_tz`) |
| Worker deploy | `qr_cf_code` — **`npm run deploy:prod`** required (edge change); no `wrangler.toml` change |
| Gating | **None** (ungated, all plans). Window columns populated for every tier. |
