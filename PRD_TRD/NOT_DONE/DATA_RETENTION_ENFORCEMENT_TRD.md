# TRD — Data Retention Enforcement (Hard Delete of Expired Analytics Data)

**Status:** Draft · **Author:** Engineering (Staff) · **Date:** 2026-07-27
**Priority:** Trust/compliance debt paydown. `analytics_retention_days` is enforced as a **read clamp only** — verified: there is no `DELETE` against `qr_scan_events` anywhere in `qr_backend/src/`. This adds the delete, with the blast-radius engineering a destructive daily sweep requires.
**Tiers:** All. The window is already tier-differentiated (Free 7 · Starter 30 · Pro 90 · Agency 365; `-1` unlimited on custom plans); enforcement inherits it unchanged.
**Plan flags:** **None new.** `analytics_retention_days` is already `"enforced"` in `FEATURE_ENFORCEMENT` (`src/api/routes/subscription.py:539`) with a `_QUOTA_SPEC` entry (`:442–445`). **No registry addition, no flag seed, no `test_feature_gate_coverage` exposure.** The only `subscription.py` edit is the **comment** on `:539`, which references a `get_analytics_days` function that does not exist and describes the flag as clamp-only.
**Migration slot:** **`0045_data_retention_enforcement.sql` — PROVISIONAL.** Highest on disk is `0032_lemonsqueezy_variant_backfill.sql`. `0033`–`0043` are claimed by drafted-but-unapplied specs in `PRD_TRD/NOT_DONE/` (verified: `0033` QR_EXPIRY, `0034` QR_UPI, `0035` QR_LOCATION, `0036`/`0037` QR_PHONE_CALL + GA4_RELABEL, `0038` WHATSAPP, `0039` GST, `0040` ORG_MFA, `0041` RESTAURANT_MENU, `0042` MULTILINGUAL, `0043` LOYALTY), and `0044` by the concurrent ACCOUNT_DELETION_ERASURE spec. **This slot MUST be re-verified against `qr_backend/migrations/` at build time** — the AI_BUSINESS_CARD_OCR spec shipped as `0026`, not the `0024` it reserved, precisely because a stale reservation table was trusted.
**Services touched:** `qr_backend` (new `utilities/retention.py`, one new `/internal/*` endpoint, two edits to existing scan-limit call sites, one email helper, config vars, migration) · `qr_cf_code` (one line added to the **existing** daily cron branch in `scheduled()` — **no `wrangler.toml` change, no new cron trigger**) · `qr_frontend` (copy only; no new component, no new hook, no new gate).
**Implements PRD:** Data Retention Enforcement (Hard Delete of Expired Analytics Data). **Mirrors the shape of** `src/utilities/webhook_dispatch.py`'s retention prune (`:60`, `:550–575`) and **deliberately diverges from its unboundedness** (§3.1 / §9).

---

## 1. Overview & Architecture

The read side is done and correct: every analytics call site resolves `get_limit(ws, db, "analytics_retention_days")` and narrows its query window (`scan.py:234–248` `_retention_days`/`_retention_cutoff_iso`, plus `:390`, `:549`, `:738`, `:929`, `:1414`, `:1629`; `reports.py:211–212`; `analytics_reports.py:302`). The write side has no counterpart — rows accumulate forever, and because the clamp is computed from the *current* plan (`get_limit` → `resolve_plan`, `subscription.py:283–329`), an upgrade makes previously-hidden history readable again.

We add a **daily, per-workspace, bounded purge** driven by the cron that already fires. The Worker's `scheduled()` daily branch (`qr_cf_code/src/index.js`, `"0 6 * * *"`) gains one `ping("/internal/retention-purge", …)`. The backend endpoint iterates workspaces, resolves each one's retention through **the same `get_limit` call the clamp uses**, computes a cutoff from `scanned_at`, and deletes in bounded batches via a Postgres function.

Three architectural decisions carry the whole design:

**(1) The delete and the billing ledger are one statement.** The Free-tier `max_scans` meter counts **raw** `qr_scan_events` for the current period (`internal.py:551–558` and `:670–677`), so purging raw rows would silently make the 2,000/month Free cap unreachable. The purge RPC therefore aggregates the rows it is deleting by calendar month and upserts a `retention_purge_ledger` row **inside the same `WITH … DELETE … RETURNING` statement**. Delete and ledger cannot diverge, because they are the same transaction. The two enforcement call sites add the ledger value for the current period to their live count.

**(2) Retention *reduction* is detected observationally, not by hooking billing.** Billing is owner-scoped — `resolve_plan` resolves from the most generous active subscription across every workspace the owner holds, and `_invalidate_plan_cache` evicts the whole owner set (`subscription.py:212–234`). A downgrade therefore narrows retention across an unbounded fan-out of workspaces, through any of: Razorpay downgrade, LemonSqueezy, cancellation, expiry, or subscription-row deletion. Rather than instrument every path, the sweep records each workspace's last-seen retention in `workspace_retention_state`; when today's resolved value is **lower**, it stamps a 30-day grace window, sends one owner notice, and **keeps purging at the old, wider window** until the grace expires. A path we forgot cannot defeat it.

**(3) Fail-closed inverts.** Everywhere else in this codebase, an unresolvable limit means *deny* — `_limit_value` returns `0` for a missing key (`subscription.py:457–472`). For a retention window, `0` naively means `cutoff = now()`, i.e. **delete everything**. Here fail-closed means **keep the data**: `-1`, `0`, `None`, non-positive, or any exception out of `get_limit` ⇒ skip the workspace entirely, record a `skipped_*` run row, delete nothing.

**Services touched**

| Service | Change |
|---|---|
| `qr_backend` | NEW `src/utilities/retention.py` (the sweep: per-workspace resolution, grace state, anomaly guard, batched RPC calls, run logging). NEW `POST /internal/retention-purge` in `src/api/routes/internal.py`. MODIFIED `_enforce_scan_limit` (`:532–616`) and `_reenable_free_scan_disabled` (`:618–715`) to add the purge ledger to their period count. NEW `send_retention_reduction_notice` in `src/utilities/email.py`. NEW config vars in `src/config/settings/base.py`. Migration `0045`. Comment-only fix at `subscription.py:539`. |
| `qr_cf_code` | ONE line in the **existing** `"0 6 * * *"` branch of `scheduled()` (`src/index.js`): `ctx.waitUntil(ping("/internal/retention-purge", "retention-purge"))`. **No `wrangler.toml` edit** — the trigger already exists (`wrangler.toml:52–53`), so there is no cron-registration lag; `npm run deploy:prod` is a plain code deploy. No KV, no scan-path, no template change. |
| `qr_frontend` | Copy only: `PricingComparisonTable.tsx:42`, `PricingCards.tsx:296`, `BillingPlans.tsx:284–288`, `AnalyticsHeader.tsx:29,52`. No new component, no new hook, no `PlanFeatures` change (`analytics_retention_days` is already in the interface, `useSubscription.ts:35`). |

**Data flow — daily purge**

```
06:00 UTC  Worker scheduled() event.cron === "0 6 * * *"
  → ctx.waitUntil(ping("/internal/retention-purge", …, x-internal-secret))
  → backend POST /internal/retention-purge   [verify_internal_secret, internal.py:21]
      run_retention_sweep(db):
        budget = RETENTION_MAX_ROWS_PER_RUN                       # global ceiling
        for ws in paginated(workspaces):                          # 1000/page, cursor by id
          1. days = get_limit(ws, db, "analytics_retention_days")  # SAME helper as the clamp
             ├─ -1 / 0 / None / <=0 / raises  → log run(status='skipped_*'); continue   [FAIL-CLOSED = KEEP]
          2. state = workspace_retention_state[ws]
             ├─ days < state.last_retention_days → stamp reduction, grace_until = now+30d,
             │                                     queue owner notice, effective_days = OLD days
             ├─ now() < state.grace_until        → effective_days = state.last_retention_days
             └─ else                             → effective_days = days ; persist last_retention_days = days
          3. cutoff = now() - effective_days  (measured on scanned_at, same basis as the clamp)
          4. anomaly guard: projected = dry-count(ws, cutoff, cap)
             if projected > max(ANOMALY_FLOOR, ANOMALY_MULTIPLE x median(last 7 live runs)):
                 log run(status='aborted_anomaly'); ALERT; continue                  [NEVER DELETE]
          5. while deleted_ws < MAX_PER_WORKSPACE and budget > 0:
                 (n, per_month) = rpc purge_workspace_scan_events(ws, cutoff, BATCH, DRY_RUN)
                 # one statement: bounded DELETE + ledger upsert, atomic
                 if n == 0: break
             same loop for purge_workspace_link_clicks(ws, cutoff, BATCH, DRY_RUN)
          6. insert retention_purge_runs(ws, mode, status, days, effective_days,
                                         cutoff, rows_deleted jsonb, duration_ms)
        → 200 {"status":"ok","mode":"dry_run|live","workspaces":n,"deleted":{...},"skipped":{...}}

READ PATH (unchanged): analytics → _retention_cutoff_iso(get_limit(...)) → windowed SELECT
BILLING  (modified):  _enforce_scan_limit → count(qr_scan_events >= period_start)
                                          + retention_purge_ledger(ws, current month)
```

**Invariant that ties the two halves together:** the purge cutoff must never be **tighter** than the clamp cutoff. Both are `now() - N days` measured on `scanned_at`, both resolve `N` from the same `get_limit` call, and during grace the purge uses a **wider** window than the clamp. So the purge can only ever delete rows the clamp already refuses to serve. Asserted by test (§10).

---

## 2. Data Model & Migrations

`migrations/0045_data_retention_enforcement.sql` — BEGIN/COMMIT-wrapped, idempotent (`IF NOT EXISTS` / `CREATE OR REPLACE`), applied by hand in the Supabase SQL editor (no automated runner). **Slot is provisional — re-verify against `qr_backend/migrations/` before applying** (§ header).

**RLS note:** the backend uses the Supabase **service-role** REST client, which **bypasses RLS**. All three new tables `ENABLE ROW LEVEL SECURITY` with **no policies**, so the anon/authenticated roles can never read them (defence in depth — none of them is ever read by a JWT-authed route). Tenant isolation is enforced in code via explicit `workspace_id` filters, never RLS. The purge functions are **not** `SECURITY DEFINER` — they run as the calling (service) role, so they gain no privilege beyond what the client already has.

```sql
-- Migration 0045: Data Retention Enforcement (hard delete of expired analytics data)
--
-- Adds the DELETE half of `analytics_retention_days`, which today is a READ CLAMP only
-- (scan.py:234-248, reports.py:211, analytics_reports.py:302) — no row has ever been
-- deleted from qr_scan_events.
--
-- Ships THIS phase only:
--   * retention_purge_ledger        — per (workspace, calendar month) count of PURGED scan
--                                     rows, so the Free max_scans meter (which counts RAW
--                                     qr_scan_events, internal.py:551-558) stays exact.
--   * workspace_retention_state     — last-seen retention + grace window (downgrade safety).
--   * retention_purge_runs          — per-run audit / observability / anomaly baseline.
--   * purge_workspace_scan_events   — BOUNDED delete + atomic ledger upsert (one statement).
--   * purge_workspace_link_clicks   — BOUNDED delete for qr_link_click_events.
--   * idx_link_click_ws_time        — the (workspace_id, clicked_at) access path the purge
--                                     needs; qr_scan_events already has its equivalent
--                                     (idx_qr_scan_events_workspace_scanned, 0007:45-46).
--
-- NO plan-flag seed and NO FEATURE_ENFORCEMENT change: analytics_retention_days is already
-- seeded on every plan (0009:98,101,104,107) and already registered 'enforced'
-- (subscription.py:539). test_feature_gate_coverage is untouched by this migration.
--
-- Idempotent; apply in the Supabase SQL Editor. See migrations/README.md.

BEGIN;

-- ── Purge ledger: what we deleted, by billing-relevant month ────────────────────
-- Free's max_scans window is the CALENDAR MONTH (period_start_iso, subscription.py:332+)
-- and its cap counts raw rows. Bucketing by date_trunc('month', scanned_at) is therefore
-- exactly the granularity the meter needs. Paid tiers are max_scans = -1 and never read
-- this table (they return early at internal.py:546-548).
CREATE TABLE IF NOT EXISTS retention_purge_ledger (
    workspace_id uuid        NOT NULL REFERENCES workspaces(id) ON DELETE CASCADE,
    period_month date        NOT NULL,          -- first day of the UTC calendar month of scanned_at
    scans_purged bigint      NOT NULL DEFAULT 0,
    updated_at   timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (workspace_id, period_month)
);
ALTER TABLE retention_purge_ledger ENABLE ROW LEVEL SECURITY;  -- no policies: service role only

-- ── Per-workspace retention state: reduction detection + grace window ───────────
-- Maintained BY THE SWEEP, not by the billing paths. Billing is owner-scoped
-- (resolve_plan, subscription.py:283-329), so a single downgrade narrows retention across
-- every workspace that owner holds, via any of Razorpay / LemonSqueezy / cancellation /
-- expiry. Observing the resolved value each run cannot miss a path we forgot to hook.
CREATE TABLE IF NOT EXISTS workspace_retention_state (
    workspace_id         uuid PRIMARY KEY REFERENCES workspaces(id) ON DELETE CASCADE,
    last_retention_days  integer,          -- highest window observed & honoured so far
    retention_reduced_at timestamptz,      -- when we first observed a NARROWER window
    grace_until          timestamptz,      -- purge at last_retention_days until this passes
    notice_sent_at       timestamptz,      -- one owner email per reduction event
    last_purge_at        timestamptz,
    last_cutoff_at       timestamptz,
    updated_at           timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE workspace_retention_state ENABLE ROW LEVEL SECURITY;

-- ── Run audit log: observability, forensics, and the anomaly baseline ───────────
-- status: 'ok' | 'capped' | 'skipped_unlimited' | 'skipped_invalid_retention'
--       | 'skipped_grace' | 'aborted_anomaly' | 'error'
CREATE TABLE IF NOT EXISTS retention_purge_runs (
    id             uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    workspace_id   uuid        REFERENCES workspaces(id) ON DELETE CASCADE,
    run_at         timestamptz NOT NULL DEFAULT now(),
    mode           text        NOT NULL,                      -- 'dry_run' | 'live'
    status         text        NOT NULL,
    retention_days integer,                                   -- plan value resolved today
    effective_days integer,                                   -- window actually applied (>= retention_days during grace)
    cutoff_at      timestamptz,
    rows_deleted   jsonb       NOT NULL DEFAULT '{}'::jsonb,  -- {"qr_scan_events":n,"qr_link_click_events":n}
    duration_ms    integer,
    note           text
);
ALTER TABLE retention_purge_runs ENABLE ROW LEVEL SECURITY;

CREATE INDEX IF NOT EXISTS idx_retention_runs_ws_time
    ON retention_purge_runs (workspace_id, run_at DESC);
CREATE INDEX IF NOT EXISTS idx_retention_runs_time
    ON retention_purge_runs (run_at DESC);

-- ── Access path for the link-click purge ────────────────────────────────────────
-- 0016 gave qr_link_click_events (qr_id, clicked_at) and (qr_id, session_id) only; the
-- purge is per WORKSPACE. qr_scan_events already has idx_qr_scan_events_workspace_scanned
-- (0007:45-46) and needs nothing new.
-- On a large table prefer CREATE INDEX CONCURRENTLY outside this transaction (see 0007:54-59).
CREATE INDEX IF NOT EXISTS idx_link_click_ws_time
    ON qr_link_click_events (workspace_id, clicked_at);

-- ── Bounded purge of raw scan events + ATOMIC ledger upsert ─────────────────────
-- ONE statement does the bounded DELETE and the ledger increment, so the two can never
-- diverge: if the delete commits, the meter compensation commits with it.
--
-- Guards below exist because the caller resolves `p_cutoff` from a plan value, and
-- _limit_value fail-closes a MISSING key to 0 (subscription.py:457-472). A cutoff of
-- now() would delete the entire table. We refuse it in the database, not only in Python.
CREATE OR REPLACE FUNCTION purge_workspace_scan_events(
    p_workspace_id uuid,
    p_cutoff       timestamptz,
    p_limit        integer,
    p_dry_run      boolean DEFAULT true
)
RETURNS TABLE (deleted integer, per_month jsonb)
LANGUAGE plpgsql
AS $$
DECLARE
    v_deleted integer := 0;
    v_months  jsonb   := '{}'::jsonb;
BEGIN
    IF p_workspace_id IS NULL OR p_cutoff IS NULL THEN
        RAISE EXCEPTION 'retention: workspace_id and cutoff are required';
    END IF;
    -- Hard floor: never accept a cutoff inside the last 24h, whatever the caller computed.
    IF p_cutoff > now() - interval '1 day' THEN
        RAISE EXCEPTION 'retention: refusing cutoff % (must be >= 1 day in the past)', p_cutoff;
    END IF;
    IF p_limit IS NULL OR p_limit <= 0 OR p_limit > 100000 THEN
        RAISE EXCEPTION 'retention: limit must be 1..100000 (got %)', p_limit;
    END IF;

    IF p_dry_run THEN
        WITH candidate AS (
            SELECT scanned_at
              FROM qr_scan_events
             WHERE workspace_id = p_workspace_id
               AND scanned_at < p_cutoff
             ORDER BY scanned_at
             LIMIT p_limit
        ), by_month AS (
            SELECT date_trunc('month', scanned_at)::date AS m, count(*)::bigint AS n
              FROM candidate GROUP BY 1
        )
        SELECT coalesce(sum(n), 0)::integer,
               coalesce(jsonb_object_agg(m::text, n), '{}'::jsonb)
          INTO v_deleted, v_months
          FROM by_month;
    ELSE
        WITH victim AS (
            SELECT id
              FROM qr_scan_events
             WHERE workspace_id = p_workspace_id
               AND scanned_at < p_cutoff
             ORDER BY scanned_at            -- oldest first: monotonic progress, resumable
             LIMIT p_limit
             FOR UPDATE SKIP LOCKED         -- two concurrent runs cannot fight over a row
        ), gone AS (
            DELETE FROM qr_scan_events e
             USING victim v
             WHERE e.id = v.id
            RETURNING e.scanned_at
        ), by_month AS (
            SELECT date_trunc('month', scanned_at)::date AS m, count(*)::bigint AS n
              FROM gone GROUP BY 1
        ), ledger AS (
            INSERT INTO retention_purge_ledger (workspace_id, period_month, scans_purged, updated_at)
            SELECT p_workspace_id, m, n, now() FROM by_month
            ON CONFLICT (workspace_id, period_month)
            DO UPDATE SET scans_purged = retention_purge_ledger.scans_purged + EXCLUDED.scans_purged,
                          updated_at   = now()
            RETURNING 1
        )
        SELECT coalesce(sum(n), 0)::integer,
               coalesce(jsonb_object_agg(m::text, n), '{}'::jsonb)
          INTO v_deleted, v_months
          FROM by_month;
    END IF;

    RETURN QUERY SELECT v_deleted, v_months;
END;
$$;

-- ── Bounded purge of raw link-click events (no ledger: no billing meter reads these) ──
-- NOTE: qr_link_click_events.workspace_id is NULLABLE (0016:37). Rows with a NULL
-- workspace_id are invisible to this per-workspace purge — see TRD §12 Q4 for the
-- orphan pass. Do NOT widen this function to cover them; a NULL-matching predicate here
-- would make the delete set unbounded by workspace.
CREATE OR REPLACE FUNCTION purge_workspace_link_clicks(
    p_workspace_id uuid,
    p_cutoff       timestamptz,
    p_limit        integer,
    p_dry_run      boolean DEFAULT true
)
RETURNS integer
LANGUAGE plpgsql
AS $$
DECLARE
    v_deleted integer := 0;
BEGIN
    IF p_workspace_id IS NULL OR p_cutoff IS NULL THEN
        RAISE EXCEPTION 'retention: workspace_id and cutoff are required';
    END IF;
    IF p_cutoff > now() - interval '1 day' THEN
        RAISE EXCEPTION 'retention: refusing cutoff % (must be >= 1 day in the past)', p_cutoff;
    END IF;
    IF p_limit IS NULL OR p_limit <= 0 OR p_limit > 100000 THEN
        RAISE EXCEPTION 'retention: limit must be 1..100000 (got %)', p_limit;
    END IF;

    IF p_dry_run THEN
        SELECT count(*)::integer INTO v_deleted
          FROM (SELECT 1 FROM qr_link_click_events
                 WHERE workspace_id = p_workspace_id AND clicked_at < p_cutoff
                 ORDER BY clicked_at LIMIT p_limit) s;
    ELSE
        WITH victim AS (
            SELECT id FROM qr_link_click_events
             WHERE workspace_id = p_workspace_id AND clicked_at < p_cutoff
             ORDER BY clicked_at LIMIT p_limit
             FOR UPDATE SKIP LOCKED
        ), gone AS (
            DELETE FROM qr_link_click_events c USING victim v WHERE c.id = v.id RETURNING 1
        )
        SELECT count(*)::integer INTO v_deleted FROM gone;
    END IF;

    RETURN v_deleted;
END;
$$;

COMMIT;

-- Sanity (after COMMIT):
--   SELECT proname FROM pg_proc WHERE proname LIKE 'purge_workspace_%';
--   SELECT * FROM purge_workspace_scan_events(
--       '<ws-uuid>'::uuid, now() - interval '7 days', 100, true);   -- dry run: counts only
--   SELECT count(*) FROM retention_purge_runs;                       -- 0 until first sweep
```

**Tables deliberately NOT touched.** `qr_scan_counters` — the aggregate (lifetime `total_scans`/`unique_scans` and the `scans_by_device`/`country`/`date`/`hour`/`variant` maps written at `internal.py:396–462`) is never read or written by this migration or the sweep. `qr_lead_submissions` — customer deliverable, explicit non-goal. `webhook_deliveries` — already pruned by `webhook_dispatch._prune_old_deliveries` (`:550–575`); no duplicated ownership. `login_events` / `alert_events` — ORG_MFA_AUDIT_LOG's scope.

---

## 3. Backend Design

### 3.1 `src/utilities/retention.py` (new)

The engine. Pure-ish module (supabase client in, dict out) so the sweep is unit-testable without HTTP. Mirrors the shape of `webhook_dispatch.sweep()` (`:516–547`) — resolve the workspace's retention, compute a cutoff, delete — and diverges from it on the one axis that matters: **every statement is bounded**.

```python
# Config-derived module constants (read via `settings`, §3.5)
BATCH               = settings.RETENTION_BATCH_SIZE                 # 1000
MAX_PER_WORKSPACE   = settings.RETENTION_MAX_ROWS_PER_WORKSPACE_PER_RUN   # 50_000
MAX_PER_RUN         = settings.RETENTION_MAX_ROWS_PER_RUN           # 500_000
GRACE_DAYS          = settings.RETENTION_GRACE_DAYS                 # 30
ANOMALY_MULTIPLE    = settings.RETENTION_ANOMALY_MULTIPLE           # 10.0
ANOMALY_FLOOR       = settings.RETENTION_ANOMALY_FLOOR              # 10_000
PURGED_TABLES       = ("qr_scan_events", "qr_link_click_events")
```

- **`resolve_effective_days(workspace_id, db) -> tuple[int | None, str, dict]`** — the fail-closed gate and the grace machine, in one place.
  ```python
  try:
      days = get_limit(workspace_id, db, "analytics_retention_days")   # SAME call as scan.py:236
  except Exception:
      return None, "skipped_invalid_retention", {}      # unreadable ⇒ KEEP THE DATA
  if days == -1:
      return None, "skipped_unlimited", {}              # unlimited ⇒ never purge
  if not isinstance(days, int) or days <= 0:
      return None, "skipped_invalid_retention", {}      # 0 / None / negative ⇒ KEEP
  ```
  **This inversion is the single most important line in the feature.** `_limit_value` fail-closes a missing `features` key to `0` (`subscription.py:457–472`); for every quota in the product that means *deny*, and here it would mean `cutoff = now()` — delete the entire workspace's history. `0` must be a skip, loudly logged, never a purge.

  Then the grace logic against `workspace_retention_state`:
  ```python
  state = _load_state(workspace_id, db)          # row or {}
  last  = state.get("last_retention_days")
  grace = state.get("grace_until")

  if last is not None and days < last:           # RETENTION REDUCED (downgrade/cancel/expiry)
      _stamp_reduction(workspace_id, db, old=last, new=days,
                       grace_until=_now() + timedelta(days=GRACE_DAYS))
      _queue_reduction_notice(workspace_id, old=last, new=days)   # §3.4, one per event
      return last, "skipped_grace", {"grace": True}               # purge at the OLD window
  if grace and _now() < _parse(grace):
      return last, "skipped_grace", {"grace": True}               # still inside the window
  _touch_state(workspace_id, db, last_retention_days=days)        # widen/steady-state
  return days, "ok", {}
  ```
  Note the ratchet: `last_retention_days` moves **up** immediately (an upgrade widens retention at once — nothing is destroyed by keeping more) and moves **down** only after the grace window expires. `retention_reduced_at`/`notice_sent_at` make the notice exactly-once per reduction event; a second consecutive reduction inside a grace window re-stamps and re-notifies (rare, and the customer should hear about it).

- **`project_delete_count(workspace_id, cutoff, db) -> int`** — one dry-run RPC call capped at `MAX_PER_WORKSPACE`. Feeds the anomaly guard; never deletes.

- **`_anomaly_threshold(workspace_id, db) -> int`** — `max(ANOMALY_FLOOR, ANOMALY_MULTIPLE * median(rows_deleted totals of the last 7 `status='ok'`, `mode='live'` runs for this workspace))`. A workspace with no live-run history uses `ANOMALY_FLOOR` only. Reads `retention_purge_runs` via `idx_retention_runs_ws_time`.

- **`purge_workspace(workspace_id, db, *, dry_run, budget) -> dict`** — the batched loop:
  ```python
  deleted = {t: 0 for t in PURGED_TABLES}
  while deleted["qr_scan_events"] < MAX_PER_WORKSPACE and budget > 0:
      res = db.rpc("purge_workspace_scan_events", {
          "p_workspace_id": workspace_id, "p_cutoff": cutoff,
          "p_limit": min(BATCH, MAX_PER_WORKSPACE - deleted["qr_scan_events"], budget),
          "p_dry_run": dry_run}).execute()
      n = (res.data or [{}])[0].get("deleted", 0)
      if n == 0:
          break                     # nothing older than the cutoff remains — done
      deleted["qr_scan_events"] += n
      budget -= n
      if dry_run:
          break                     # a dry run counts one batch; it must not spin
  ```
  Then the identical loop for `purge_workspace_link_clicks`. **Termination is guaranteed**: in live mode each batch removes rows from the candidate set, so the set strictly shrinks; in dry-run mode the loop is single-pass by construction (otherwise it would never terminate, since a dry run deletes nothing — this is the one bug a naive implementation of this loop always has).

  **Concurrency with ingestion:** `cutoff` is computed **once** per workspace per run and every insert writes `scanned_at ≈ now()` (`internal.py:393`), so a row inserted mid-sweep can never enter the delete set. Deletes are by primary key from a bounded oldest-first selection with `FOR UPDATE SKIP LOCKED`, so a concurrent second run (cron retry, manual invocation) skips claimed rows rather than blocking or double-counting.

- **`run_retention_sweep(db) -> dict`** — the top level. Pages `workspaces` 1000 at a time ordered by `id` (the pagination shape already used by `_reenable_free_scan_disabled`, `internal.py:636–655`), applies the global `MAX_PER_RUN` budget across workspaces, wraps each workspace in `try/except` so one bad workspace cannot abort the sweep (same discipline as `webhook_dispatch.sweep()` `:543–544` and `_reenable_free_scan_disabled` `:709–711`), and writes exactly one `retention_purge_runs` row per workspace per run — including for skips and aborts, because "we deliberately did nothing" is the most important thing to be able to prove later.

  **Allowlist:** when `RETENTION_LIVE_WORKSPACE_IDS` is non-empty, only those workspace ids run live; every other workspace runs dry regardless of `RETENTION_DRY_RUN`. This is the Phase-1 mechanism (PRD §10) and is checked **per workspace**, not once per run.

### 3.2 `src/api/routes/internal.py` — `POST /internal/retention-purge` (new)

Mirrors `webhook_sweep` (`:1117–1140`) exactly: router-wide `verify_internal_secret` (`:21`), no request body, loud `logger.error` + 500 if the whole sweep fails, structured `logger.info` summary on success.

```python
@router.post(
    "/retention-purge",
    name="internal:retention_purge",
    status_code=fastapi.status.HTTP_200_OK,
    summary="Daily hard-delete of analytics data past each workspace's retention window",
)
async def retention_purge(db: Client = Depends(get_supabase)):
    try:
        result = run_retention_sweep(db)
    except Exception:
        logger.error("ALERT: retention-purge failed entirely", exc_info=True)
        raise fastapi.HTTPException(status_code=500, detail="retention-purge failed")
    logger.info("retention-purge: mode=%s workspaces=%s deleted=%s skipped=%s aborted=%s duration_ms=%s",
                result["mode"], result["workspaces"], result["deleted"],
                result["skipped"], result["aborted"], result["duration_ms"])
    return {"status": "ok", **result}
```

**The endpoint takes no parameters.** No workspace id, no cutoff, no window, no override — everything is resolved server-side from `plans`. A caller who holds `INTERNAL_SECRET` therefore cannot steer it at a specific customer or an arbitrary window; the worst they can do is run today's sweep early (idempotent — the second run finds nothing older than the cutoff). This is deliberate (§8).

### 3.3 `src/api/routes/internal.py` — scan-limit call sites (modified)

Both places that count raw scans for the current period must add the purge ledger, or the Free cap silently stops working once the purge starts deleting inside the current calendar month.

- **`_enforce_scan_limit` (`:532–616`)** — the count at `:551–558` becomes:
  ```python
  live = (db.table("qr_scan_events").select("id", count="exact")
            .eq("workspace_id", workspace_id)
            .gte("scanned_at", period_start_iso(resolved)).execute()).count or 0
  total_workspace_scans = live + _purged_in_period(db, workspace_id, period_start_iso(resolved))
  ```
- **`_reenable_free_scan_disabled` (`:618–715`)** — the identical count at `:670–677` gets the identical treatment.
- **`_purged_in_period(db, ws, period_start_iso) -> int`** — sums `retention_purge_ledger.scans_purged` for `period_month >= date_trunc('month', period_start)`. One primary-key-ranged read.

**Why this is exact and not an approximation:** the ledger buckets by calendar month, and the only plan with a finite `max_scans` is Free (`2000`; all paid tiers are `-1`, `0009_pricing_v3_4tier_collapse.sql:29`), whose period **is** the UTC calendar month (`period_start_iso`, `subscription.py:332+`). Paid workspaces return early at `internal.py:546–548` and never consult the ledger. So the ledger is read only where its bucketing exactly matches the enforcement window. That invariant is load-bearing and gets its own test (§10) — if a future plan ships a finite `max_scans` on a billing-anchored (non-calendar) period, this becomes wrong and the test must fail.

### 3.4 `src/utilities/email.py` — `send_retention_reduction_notice` (new)

One new Resend template alongside the existing helpers (`send_alert_email` `:234`, `send_scheduled_report_email` `:155`). Owner resolved with the existing `_resolve_owner_email` helper (`internal.py:881`).

- Subject: *"Your Qravio plan now keeps N days of scan history"*.
- Body: old window → new window, the **exact date** history beyond the new window will be deleted (`grace_until`), and a direct link to the shipped export (`GET /workspaces/{ws}/analytics/export`, `analytics_reports.py:282`).
- **Exactly once per reduction event**, guarded by `workspace_retention_state.notice_sent_at`. Best-effort and wrapped: an email failure must **never** abort the sweep or change purge behaviour (same discipline as `_fire_scan_cap_alert`, `internal.py:612–615`).
- **DMARC gate:** `_dmarc.qravio.app` is unpublished per the standing house note. If it is still unpublished at Phase 2, ship with the notice **suppressed** (`notice_sent_at` left null, the reduction logged and surfaced in-app) — the grace period itself is unaffected, only the email is held.

### 3.5 `src/config/settings/base.py` (modified)

New `decouple.config` entries alongside `INTERNAL_SECRET` (`:133`) / `CARD_OCR_MODEL` (`:145`), all with safe defaults so an unset environment is the *conservative* one:

| Var | Default | Meaning |
|---|---|---|
| `RETENTION_DRY_RUN` | **`True`** | Count and log; delete nothing. **Ships enabled.** |
| `RETENTION_LIVE_WORKSPACE_IDS` | `""` | CSV allowlist; when non-empty, only these run live (Phase 1). |
| `RETENTION_BATCH_SIZE` | `1000` | Rows per RPC call. Matches `_WINDOW_PAGE` (`scan.py:230`) and the `page_size` in `_reenable_free_scan_disabled` (`internal.py:638`). |
| `RETENTION_MAX_ROWS_PER_WORKSPACE_PER_RUN` | `50000` | Per-workspace ceiling; the rest waits for tomorrow. |
| `RETENTION_MAX_ROWS_PER_RUN` | `500000` | Global ceiling per sweep. |
| `RETENTION_GRACE_DAYS` | `30` | Grace after a retention reduction (one billing cycle). |
| `RETENTION_ANOMALY_MULTIPLE` | `10.0` | Abort above this × the workspace's 7-run median. |
| `RETENTION_ANOMALY_FLOOR` | `10000` | Never abort below this absolute count. |

Add all eight to `.env.example` with the same defaults and a one-line warning that `RETENTION_DRY_RUN=false` is irreversible. These are **not** subject to `validate_public_urls()` (they are not published URLs), but an operator checklist entry in the deploy doc is warranted.

### 3.6 `src/api/routes/subscription.py` (comment-only)

Line `:539` currently reads:
```python
"analytics_retention_days": "enforced",  # scan.py get_analytics_days clamp via get_limit
```
`get_analytics_days` does not exist in the codebase (the real helpers are `_retention_days`/`_retention_cutoff_iso`, `scan.py:234–248`), and "clamp" no longer describes the whole enforcement. Correct it to name the real helpers and both halves — read clamp *and* purge. **No `FEATURE_ENFORCEMENT` key is added or removed and no seed changes, so `test_feature_gate_coverage` is not exercised by this feature at all.** `_QUOTA_SPEC['analytics_retention_days']` (`:442–445`, `usage: None`, "day-window cap; caller clamps") is correct as-is and stays.

---

## 4. Cloudflare Worker / Edge Design

**One line, in a branch that already exists.** `qr_cf_code/src/index.js` `scheduled()` dispatches by `event.cron`; the daily `"0 6 * * *"` branch already pings `run-reports:daily`, `run-alerts`, and `reclamation-sweep`. We append:

```javascript
} else if (event.cron === "0 6 * * *") {
  ctx.waitUntil(ping("/internal/run-reports", "run-reports:daily", { frequency: "daily" }));
  ctx.waitUntil(ping("/internal/run-alerts", "run-alerts"));
  ctx.waitUntil(ping("/internal/reclamation-sweep", "reclamation-sweep"));
  // Hard-delete analytics rows past each workspace's analytics_retention_days.
  ctx.waitUntil(ping("/internal/retention-purge", "retention-purge"));
}
```

**No `wrangler.toml` change.** `"0 6 * * *"` is already registered (`wrangler.toml:52–53`), so there is **no new cron trigger and therefore no trigger-registration gate** — `npm run deploy:prod` is a plain code deploy, and the purge starts on the next 06:00 UTC tick. The dev worker intentionally has no crons (`wrangler.toml:31–33`), so the purge never runs against a dev environment by accident.

The `ping` helper is fire-and-forget with `ctx.waitUntil` and already logs non-2xx responses to the Worker console — sufficient for edge-side visibility; the authoritative record is the backend's `retention_purge_runs` rows.

**Nothing else at the edge changes.** No KV key, no `build_kv_content` branch, no `page_design`/template, no `handleQRCode` case, no `recordScan` field, no consent-gate change. The worker↔React template-mirroring house rule does not apply (no new scan page). The scan hot path is byte-for-byte unchanged.

**⚠️ Pre-existing, out of scope, do not fix here:** that same daily branch pings `/internal/reclamation-sweep`, and **no such route exists in `qr_backend/src/`** (verified — zero definitions). It 404s every day at 06:00 UTC. Noted so the new purge's logs aren't mistaken for it and vice versa; it belongs in its own ticket (§12 Q6).

---

## 5. Frontend Design

Copy only. **No new component, no new hook, no new gate, no `PlanFeatures` change** — `analytics_retention_days` is already in the interface (`useSubscription.ts:35`) and already in the `getLimit` key union (`plan-features.ts:60`).

### 5.1 Analytics header (`src/components/org/analytics/AnalyticsHeader.tsx:29,52`)
The range picker already bounds itself with `getLimit(subscription, 'analytics_retention_days')`. Add an inline note beside it (shadcn `Alert`/muted text, Tailwind tokens only, no inline styles): *"Your plan keeps N days of scan detail. Older records are permanently deleted — export before they expire."* with a link to the existing export. When the limit is `-1`, render nothing.

### 5.2 Pricing (`src/components/pricing/PricingComparisonTable.tsx:42`, `PricingCards.tsx:296`)
Relabel **"Analytics Retention"** → **"Scan history kept"** and add the footnote: *"Individual scan records older than this are permanently deleted. Lifetime scan totals are kept forever."* The second sentence is what prevents "my numbers dropped" tickets — the counters genuinely don't move.

### 5.3 Billing (`src/components/org/billing/BillingPlans.tsx:284–288`)
Same phrasing on the in-app plan feature list, so the pre-downgrade view matches the post-downgrade email.

### 5.4 Static pricing constants (`src/lib/constants/pricing.ts:101,141,174,211`)
Values (7/30/90/365) are **unchanged** — do not touch them, or `src/lib/__tests__/pricing-parity.test.ts:93–108` fails. Only the rendered labels change.

### 5.5 (v1.1, optional) Settings read-out
A "Data retention" row in workspace settings: current window, last purge timestamp, next scheduled purge, export button. Would need a small read endpoint over `workspace_retention_state`/`retention_purge_runs`. **Not a GA gate** — deliberately deferred so v1 ships no new authenticated surface over the purge tables.

---

## 6. External-Service Integration

**No AI. No new third-party service. No new outbound HTTP.**

- **Email (Resend, existing):** one new template — the retention-reduction notice (§3.4) — via `src/utilities/email.py`. **Gated on `_dmarc.qravio.app` being published**, per the standing house note; if unpublished at Phase 2, ship the grace period with the email suppressed and surface the reduction in-app only. The grace window itself is never blocked on email.
- **Cloudflare (existing):** cron only, via the already-registered `"0 6 * * *"` trigger. No KV read or write anywhere in this feature.
- **Supabase (existing):** service-role REST client + two new SQL functions. The purge functions are **not** `SECURITY DEFINER` — they run as the calling role and grant no new privilege.
- **Razorpay / LemonSqueezy:** **no integration.** This is a deliberate design choice, not an omission — the grace mechanism observes the *resolved* plan each run rather than hooking any billing webhook, so it works identically across both providers, cancellation, expiry, and the owner-scoped fan-out (§1, decision 2).
- **No PDF/WeasyPrint, no new env-provisioned secret** (the eight new vars are tuning knobs with safe defaults, not credentials).

---

## 7. API Contracts

One internal endpoint. No public or JWT-authed API surface is added.

```http
POST /api/v1/internal/retention-purge
x-internal-secret: <INTERNAL_SECRET>
(no request body — every parameter is resolved server-side from `plans`)

200 OK
{
  "status": "ok",
  "mode": "dry_run",                       // or "live"
  "workspaces": 1284,                      // workspaces examined this run
  "deleted": { "qr_scan_events": 41203, "qr_link_click_events": 118 },
  "skipped": {
    "unlimited": 3,                        // analytics_retention_days = -1
    "invalid_retention": 0,                // 0 / None / <=0 / get_limit raised  → KEPT
    "grace": 7                             // inside a post-reduction grace window
  },
  "aborted": 0,                            // anomaly guard tripped → nothing deleted
  "capped": 2,                             // hit MAX_ROWS_PER_WORKSPACE_PER_RUN; resumes tomorrow
  "budget_exhausted": false,               // hit MAX_ROWS_PER_RUN
  "duration_ms": 8412
}

500 { "detail": "retention-purge failed" }   // whole-sweep failure; logged as ALERT
403 { "detail": "..." }                      // missing/incorrect x-internal-secret (router-wide)
```

Per-workspace detail is **not** in the response — it is in `retention_purge_runs`, one row per workspace per run, which is the queryable forensic record (§11).

**SQL function contracts** (called only from `retention.py`):
```
purge_workspace_scan_events(uuid, timestamptz, integer, boolean)
  → TABLE(deleted integer, per_month jsonb)     -- per_month: {"2026-05-01": 412, ...}
  raises on: null ws/cutoff · cutoff newer than now()-1day · limit outside 1..100000

purge_workspace_link_clicks(uuid, timestamptz, integer, boolean) → integer
  same guards
```

**Unchanged contracts** (must stay byte-identical after a purge, and this is asserted in §10): every endpoint in `scan.py`, `reports.py`, and `analytics_reports.py`. A correct purge only removes rows the retention clamp already refuses to serve, so no analytics response may change.

---

## 8. Security, Privacy & Abuse

- **Auth:** `/internal/retention-purge` bypasses Bearer auth by exclusion in `src/api/middlewares/auth_bearer.py` and is protected by the router-wide `verify_internal_secret` (`internal.py:21`) — the same posture as `webhook-sweep`, `run-reports`, `run-alerts`, and `free-scan-reset`.
- **This is the most destructive thing behind that header — so it is deliberately unsteerable.** The endpoint accepts **no parameters**: not a workspace id, not a cutoff, not a window, not a dry-run override. Everything is resolved server-side from `plans` and the sweep's own state. An attacker holding `INTERNAL_SECRET` cannot target a customer, cannot widen a window, and cannot disable dry-run; the worst they achieve is running today's already-scheduled sweep early, which is idempotent (a second run finds nothing older than the cutoff). Combined with `MAX_ROWS_PER_RUN` and the anomaly guard, the damage from a compromised secret is bounded by the same rails that bound our own bugs.
- **Tenant isolation:** every delete carries an explicit `workspace_id = p_workspace_id` predicate inside the SQL function. The service-role client **bypasses RLS**, so this predicate is the only isolation boundary and it is enforced in the database, not in Python. The three new tables have RLS enabled with no policies (§2).
- **Privacy — this feature's entire purpose.** `qr_scan_events` carries `ip_hash`, `session_id`, `country_code`/`region`/`city`, `latitude`/`longitude`, `asn`, `user_agent`, `referer`, `destination_url` (`ScanEventPayload`, `internal.py:325–347`). Deleting it on schedule is the largest single reduction in breach blast radius available to us, and it makes the pricing-page retention claim true for the first time. **Hard delete only** — no archive table, no soft-delete flag, no cold storage. An "archive" would re-create the exact false claim one layer down.
- **What survives, and why that is not a privacy hole:** `qr_scan_counters` retains only **non-identifying aggregates** — integer totals and small string→count maps keyed by device type, country code, date, hour, and A/B variant (`internal.py:396–462`). No `ip_hash`, no `session_id`, no city, no coordinates, no user agent, no referer. Retaining it is consistent with the retention claim, which is about scan *records*, and the copy in §5 says so explicitly. `retention_purge_ledger` stores counts only.
- **Abuse / self-inflicted:** the realistic threat is our own bug, not an attacker. Mitigations are the same list: dry-run default, per-workspace and global ceilings, the anomaly abort, the SQL-level cutoff floor (`cutoff > now() - 1 day` raises), the `1..100000` limit clamp, the allowlist, and one audit row per workspace per run including skips.
- **Auditability:** `retention_purge_runs` is the answer to "what did you delete, for whom, when, and under what window" — including negative evidence for skips and aborts. Retained indefinitely (it is metadata, not telemetry, and is tiny: one row per workspace per day).
- **Consent gate:** unaffected. No edge behaviour, no client capture, no new collection — this only *removes* data.

---

## 9. Performance, Scale & Cost

- **Steady state is trivial.** After backfill, each daily run deletes roughly one day of newly-expired rows per workspace. For most workspaces that is tens to hundreds of rows — a handful of bounded index scans.
- **Access paths already exist for the hot table.** `idx_qr_scan_events_workspace_scanned` on `(workspace_id, scanned_at)` (`migrations/0007_billing_foundations.sql:45–46`) is exactly the predicate + sort the purge issues. `qr_link_click_events` needs the new `idx_link_click_ws_time` (§2) because `0016` only indexed `(qr_id, clicked_at)`; on a large table, build it `CONCURRENTLY` outside the migration transaction (the pattern `0007:54–59` already documents).
- **Lock footprint is bounded by design — the divergence from the precedent.** `webhook_dispatch._prune_old_deliveries` issues `.delete().lt("created_at", cutoff)` with no bound (`:556`, `:573`) and `sweep()` selects every due row with no `LIMIT` (`:525–531`). On `webhook_deliveries` that is survivable; on `qr_scan_events` — the highest-write table in the product, on the scan ingestion path — an unbounded delete would hold row locks and WAL for the duration and could back pressure into `POST /internal/scans`, i.e. into the edge. Here every statement deletes at most `BATCH` (1000) rows selected by primary key with `FOR UPDATE SKIP LOCKED`, so each transaction is short and a concurrent run skips rather than blocks.
- **The run cannot outlive the request.** `MAX_ROWS_PER_RUN` (500k) and `MAX_ROWS_PER_WORKSPACE_PER_RUN` (50k) bound total work; anything left is picked up by tomorrow's run because the sweep is resumable by construction (the candidate set is defined by the data, not by a stored cursor — deleted rows simply stop matching). Tune both down if the observed p95 approaches the backend request timeout.
- **Backfill is the only expensive phase, and it is operated, not requested.** The first purge for a workspace with years of history is large; it is staged across days via the ceiling, and for the largest tenants run by hand in the Supabase SQL editor in bounded batches during a low-traffic window — the same way every migration in this repo is applied.
- **Cost.** No new infra, no new service, no queue, no outbound HTTP. Marginal DB cost is the daily scan-and-delete; marginal storage cost **falls** — but see below.
- **Storage reclamation lags deletion (do not over-promise).** Postgres `DELETE` marks tuples dead; space returns to the table's free list on autovacuum and to the OS only on a rewrite. Row count, query-planning benefit, and breach blast radius improve immediately; on-disk footprint improves as autovacuum keeps up. Expect one-time bloat after backfill and treat a maintenance-window rewrite as an operational option, not a feature requirement.
- **Read-path cost is unchanged and arguably better** — `_fetch_windowed_events` (`scan.py:249+`, capped at `_MAX_WINDOW_EVENTS = 50000`, `:229`) scans a strictly smaller table.
- **New read on the scan hot path:** `_purged_in_period` adds one primary-key-ranged `retention_purge_ledger` read to `_enforce_scan_limit`, which runs after every scan insert. It is a tiny indexed lookup against a table with at most one row per workspace per month, and it sits alongside an existing `count="exact"` over `qr_scan_events` that is far more expensive. Negligible, but measure `POST /internal/scans` p95 against baseline as a Phase-1 gate.

---

## 10. Testing Strategy

**Backend (pytest, `qr_backend/tests/unit_tests/test_retention_purge.py`, new)**

*Fail-closed (the inversion — highest priority):*
- `analytics_retention_days = -1` → `skipped_unlimited`, **zero rows deleted**, run row written.
- `= 0` (the `_limit_value` fail-closed default for a missing key) → `skipped_invalid_retention`, **zero rows deleted**. This is the test that stops a `plans.features` typo from wiping the product.
- `get_limit` raises → `skipped_invalid_retention`, **zero rows deleted**, sweep continues to the next workspace.
- SQL guard: calling `purge_workspace_scan_events` with `cutoff = now()` **raises**, deletes nothing — the database refuses even if Python is wrong.
- SQL guard: `p_limit` of `0`, `-1`, and `100001` all raise.

*Correctness of the window:*
- A row at `cutoff - 1s` is deleted; a row at `cutoff + 1s` is **not**.
- **Clamp/purge lockstep:** for each of 7/30/90/365, the purge cutoff equals `_retention_cutoff_iso` (`scan.py:242–248`) for the same workspace — the purge is never tighter than the clamp.
- Retention measured on `scanned_at`, not `created_at`/insert time.

*Aggregates and dashboards:*
- `qr_scan_counters` rows are byte-identical before and after a purge (`total_scans`, `unique_scans`, and every JSONB map).
- Every analytics endpoint returns an **identical payload** before and after a purge of a workspace whose expired rows were already outside the clamp — the strongest end-to-end assertion available, and a diff here means the clamp and purge disagree.

*Billing meter (PRD R1):*
- Seeded Free workspace, 2,000 scans spread across a month, a purge mid-month → the cap still fires at **exactly** 2,000 (`_enforce_scan_limit`), proving `_purged_in_period` is wired.
- Same for `_reenable_free_scan_disabled` — a workspace still over cap after a mid-period purge is **not** re-enabled.
- **Ledger-window invariant:** assert that every plan with a finite `max_scans` has a calendar-month period (`period_start_iso` returns a month start). If a future plan ships a finite `max_scans` on a billing anchor, this test must fail — the ledger's month bucketing would no longer match enforcement.
- The delete and the ledger upsert are atomic: a forced failure mid-statement leaves **both** unchanged.

*Batching / concurrency / idempotence:*
- 2,500 expired rows with `BATCH=1000` → three RPC calls, 2,500 deleted, loop terminates.
- **Dry-run does not spin**: with `p_dry_run=true` the loop makes exactly one call per table and deletes nothing (the classic infinite-loop bug in this shape).
- `MAX_ROWS_PER_WORKSPACE_PER_RUN` → `status='capped'`; the **next** run deletes the remainder (resumability).
- `MAX_ROWS_PER_RUN` exhausts mid-sweep → remaining workspaces are untouched and get no run row for that sweep.
- Two concurrent sweeps over the same workspace → each row deleted exactly once, ledger sums correctly (`FOR UPDATE SKIP LOCKED`).
- Rows inserted *during* a sweep with `scanned_at = now()` are never deleted.
- Re-running an identical sweep immediately is a no-op (`deleted = 0`).

*Grace / downgrade (PRD R5):*
- Pro(90) → Free(7): first run after the change purges at **90**, stamps `grace_until = +30d`, queues exactly one notice.
- Inside grace: still purges at 90. Day 31: purges at 7.
- Free(7) → Pro(90) (upgrade): `last_retention_days` widens **immediately**, no grace, no notice.
- Owner-scoped fan-out: one downgrade on a workspace whose owner holds three workspaces stamps grace on **all three** (`resolve_plan`, `subscription.py:283–329`).
- Exactly one notice per reduction event (`notice_sent_at`); an email failure does not abort the sweep or change purge behaviour.

*Anomaly guard:*
- A workspace projecting > `max(FLOOR, MULTIPLE × 7-run median)` → `aborted_anomaly`, **zero rows deleted**, `ALERT` logged.
- A workspace with no live-run history uses `ANOMALY_FLOOR` alone.
- The abort does not stop the sweep for other workspaces.

*Isolation and blast radius:*
- Purging workspace A deletes **zero** rows belonging to workspace B.
- `qr_lead_submissions`, `qr_scan_counters`, `webhook_deliveries`, `login_events`, `alert_events` row counts unchanged by any sweep.

*Registry:* `test_feature_gate_coverage` is **untouched** — no `FEATURE_ENFORCEMENT` key added or removed, no plan seed changed. Assert it still passes as a regression check, not as a new requirement.

**Frontend (Vitest):** the copy changes render for finite windows and render nothing for `-1`; `pricing-parity.test.ts:93–108` still passes (values unchanged, labels only). Note the **~29 pre-existing FE test failures** are the documented baseline — only net-new failures count as regressions.

**Worker:** a `scheduled()` unit test asserting the `"0 6 * * *"` branch pings `/internal/retention-purge` exactly once, and that no other cron string does.

---

## 11. Observability & Rollout

**Deploy order (strict):**
1. Apply `0045` in the Supabase SQL editor; run the sanity SELECTs. Build `idx_link_click_ws_time` `CONCURRENTLY` if `qr_link_click_events` is large.
2. Deploy the backend with `RETENTION_DRY_RUN=true` (the default) — the endpoint, the sweep, the ledger reads in `_enforce_scan_limit`/`_reenable_free_scan_disabled`, the config vars. **The ledger reads must ship before or with the purge, never after.**
3. Deploy the Worker (`npm run deploy:prod`) — one line, existing cron, no trigger registration.
4. Ship the FE copy changes **before** the first live purge, not after.

**Observability (three layers):**
- **Per-run rows** — `retention_purge_runs`, one per workspace per run, including skips and aborts. The forensic record: *"which window did we apply to this customer on this date, and how many rows did we remove."*
  ```sql
  -- daily volume + outcome mix
  SELECT date_trunc('day', run_at) d, mode, status, count(*),
         sum((rows_deleted->>'qr_scan_events')::bigint) AS scan_rows
    FROM retention_purge_runs GROUP BY 1,2,3 ORDER BY 1 DESC;
  -- anything that refused to delete
  SELECT * FROM retention_purge_runs
   WHERE status IN ('aborted_anomaly','skipped_invalid_retention','error')
     AND run_at > now() - interval '7 days' ORDER BY run_at DESC;
  ```
- **Structured logs** — one `logger.info` summary per sweep (mode, workspaces, deleted per table, skipped, aborted, capped, duration); `logger.error` with an `ALERT:` prefix on whole-sweep failure and on every anomaly abort, matching the existing `ALERT:` convention (`internal.py:589`, `webhook_dispatch.py:544`).
- **Alarms (must exist before Phase 3):**
  - **Anomaly abort** → page. There is no undo; an abort means the guard saved us and someone must look.
  - **`skipped_invalid_retention > 0`** → page. It means a plan row lost its retention key — a pricing/seed bug that would have deleted a customer's history.
  - **Total rows deleted > 3× the trailing 7-day median** → page, even if no individual workspace tripped its own guard.
  - **Zero runs in 48h** → warn (the cron or the Worker deploy regressed; also the signal that would have caught the `reclamation-sweep` 404 years ago).
  - **`POST /internal/scans` p95 regression vs baseline** → warn (the `_purged_in_period` read, or lock contention from the purge).

**Rollout phases** — full detail in the PRD §10. Engineering gates in short:
- **Phase 0 (dry-run):** ≥ 7 consecutive dry runs; read projected counts per workspace out of `retention_purge_runs`; confirm no workspace projects a delete inside its window; tune the ceilings to the observed distribution.
- **Phase 1 (internal cohort):** `RETENTION_LIVE_WORKSPACE_IDS` allowlist only. Verify the full §10 acceptance list, including the anomaly guard aborting on a deliberately poisoned workspace and the Free cap still firing at exactly 2,000 after a mid-month purge.
- **Phase 2 (copy + notice + staged backfill):** FE copy live; notice email live (or suppressed pending DMARC); backfill run under the ceiling across days, largest tenants by hand.
- **Phase 3 (global live):** allowlist removed, `RETENTION_DRY_RUN=false`. Gates: 30 consecutive clean cohort runs · backfill complete · anomaly guard demonstrated on a synthetic anomaly · grace path verified end-to-end with a real staging downgrade · alarms wired.

**Rollback:** set `RETENTION_DRY_RUN=true` and redeploy (or clear the allowlist) — the sweep immediately stops deleting. Note plainly: **rollback stops future deletion; it does not restore deleted rows.** That asymmetry is the whole reason for the dry-run default, the ceilings, and the anomaly guard.

---

## 12. Open Technical Questions & Risks

1. **Grace period = 30 days?** *Recommend 30 — one full billing cycle, so a one-month downgrade is fully reversible. 7 is too short to act on the email; 90 makes the retention claim mushy for a quarter of a year. Tunable via `RETENTION_GRACE_DAYS` without a deploy of new code.*
2. **Ledger vs. flooring the cutoff at the period start for the Free meter (PRD R1)?** *Recommend the ledger (§3.3). The alternative — never purge inside the current billing period — is simpler and needs no schema, but retains up to 31 days for a 7-day plan, re-weakening the exact claim this feature exists to make true.*
3. **Purge `qr_lead_submissions`?** *Recommend no. Leads are a paid customer deliverable, not telemetry; deleting a Pro customer's captured leads at 90 days destroys their work product. Separate policy, separate PRD, probably customer-configurable. Note the tension: lead rows carry more PII than scan rows, so "we retain leads indefinitely" needs its own honest answer — it just isn't this spec's answer to give.*
4. **`qr_link_click_events.workspace_id` is NULLABLE (`0016:37`), so orphan rows are invisible to a per-workspace purge.** *Recommend a separate bounded orphan pass at the global maximum window (365 days), run in the same sweep with its own ceiling — safe because 365 is the widest window any plan grants, so it can never delete a row some workspace was still entitled to. Do not widen the per-workspace function with a NULL-matching predicate (it would make the delete set unbounded by workspace). Quantify the orphan count during Phase 0 before deciding whether it's worth building at all.*
5. **Should `webhook_deliveries` pruning move into this sweep?** *Recommend not in v1 — no duplicated ownership of a delete path. But `_prune_old_deliveries` (`webhook_dispatch.py:550–575`) is unbounded and should adopt this feature's bounded-RPC pattern in a follow-up; it is the same bug class, on a smaller table, and it also re-resolves `get_limit` per workspace inside a loop with no ceiling.*
6. **The daily cron's `/internal/reclamation-sweep` 404.** *Out of scope, referenced only so the two are not confused in the logs. File separately: either implement the route or drop the ping. The "zero runs in 48h" alarm proposed in §11 is the general fix for this class of silent-cron-failure.*
7. **Per-QR retention granularity / customer-configurable windows?** *Not in v1. The design is per-workspace throughout (state table, ledger, run rows keyed on `workspace_id`); adding a tighter per-QR override later means a second resolution step in `resolve_effective_days`, not a schema change.*
8. **Autovacuum after backfill.** *Genuine unknown until we see production volumes. Expect one-time bloat; monitor `pg_stat_user_tables` on `qr_scan_events` through Phase 2 and decide on a maintenance-window rewrite with data, not in advance. Do not promise an immediate storage-cost reduction in any customer-facing material.*
9. **Do we need to notify before the very first steady-state purge?** *Recommend: no per-workspace email for steady state (a Free user's day-8 data expiring daily is the advertised product, and a daily "we deleted things" email is noise), but the copy changes must be live **before** the first customer-facing purge and Phase 3 should carry one product-wide announcement. Per-workspace email is reserved for the reduction case, where the customer loses something they had.*
10. **Migration slot `0045` is provisional.** *`0033`–`0044` are claimed by unapplied specs, several of which will land in a different order than they were drafted; AI_BUSINESS_CARD_OCR shipped as `0026` after reserving `0024` for exactly this reason. **Re-verify against `qr_backend/migrations/` at build time**, and coordinate with ACCOUNT_DELETION_ERASURE (`0044`) since both specs touch delete paths on the same tables.*

### Appendix — Key Files

| Concern | File |
|---|---|
| Sweep engine (NEW) | `qr_backend/src/utilities/retention.py` — `run_retention_sweep`, `resolve_effective_days`, `purge_workspace`, `_anomaly_threshold` |
| Internal endpoint (NEW) | `qr_backend/src/api/routes/internal.py` — `POST /internal/retention-purge` (mirror `webhook_sweep`, `:1117–1140`); auth via `verify_internal_secret` (`:21`) |
| Migration (PROVISIONAL slot) | `qr_backend/migrations/0045_data_retention_enforcement.sql` — `retention_purge_ledger`, `workspace_retention_state`, `retention_purge_runs`, `purge_workspace_scan_events`, `purge_workspace_link_clicks`, `idx_link_click_ws_time` |
| Retention resolution — single source of truth | `qr_backend/src/api/routes/subscription.py` (`get_limit` `:474–480`, `_limit_value` `:457–472`, `_QUOTA_SPEC` `:442–445`, `FEATURE_ENFORCEMENT` `:539` ← comment-only fix) |
| Read clamp the purge must stay in lockstep with | `qr_backend/src/api/routes/scan.py` (`_retention_days` `:234–239`, `_retention_cutoff_iso` `:242–248`, `_MAX_WINDOW_EVENTS` `:229`, plus `:390`, `:549`, `:738`, `:929`, `:1414`, `:1629`) |
| Read clamp — other call sites | `qr_backend/src/api/routes/reports.py:211–212`; `qr_backend/src/api/routes/analytics_reports.py:302` |
| Billing meter to patch (Free `max_scans`) | `qr_backend/src/api/routes/internal.py` (`_enforce_scan_limit` `:532–616`, count `:551–558`; `_reenable_free_scan_disabled` `:618–715`, count `:670–677`) |
| Aggregates preserved (never purged) | `qr_scan_counters`, written at `qr_backend/src/api/routes/internal.py:396–462` |
| Raw tables purged | `qr_scan_events` (insert `internal.py:393`; payload `:325–347`), `qr_link_click_events` (`migrations/0016_scan_conversion_funnel.sql:34–45`) |
| Existing index the purge rides | `qr_backend/migrations/0007_billing_foundations.sql:45–50` (+ `CONCURRENTLY` note `:54–59`) |
| Owner-scoped plan resolution (downgrade fan-out) | `qr_backend/src/api/routes/subscription.py` (`resolve_plan` `:283–329`, `_invalidate_plan_cache` `:212–234`, `period_start_iso` `:332+`) |
| Downgrade precedent — lock, never delete | `qr_backend/src/api/routes/razorpay_routes.py:1225–1266` (grace-window note `:1238`) |
| Delete precedent to mirror (shape) / diverge from (unbounded) | `qr_backend/src/utilities/webhook_dispatch.py` (`RETENTION_DAYS_CAP` `:60`, `sweep` `:516–547`, `_prune_old_deliveries` `:550–575`) |
| Plan retention + `max_scans` seed values | `qr_backend/migrations/0009_pricing_v3_4tier_collapse.sql` (`:29` max_scans row, `:98,101,104,107` feature blobs) |
| Notice email | `qr_backend/src/utilities/email.py` (new `send_retention_reduction_notice`; owner lookup `internal.py:881`) |
| Export the notice links to | `qr_backend/src/api/routes/analytics_reports.py:282`, `qr_backend/src/utilities/report_export.py` |
| Config | `qr_backend/src/config/settings/base.py` (8 new `RETENTION_*` vars alongside `:133`/`:145`) + `.env.example` |
| Worker cron (1 line, existing branch) | `qr_cf_code/src/index.js` `scheduled()` `"0 6 * * *"`; `qr_cf_code/wrangler.toml:52–53` **UNCHANGED** |
| FE copy only | `qr_frontend/src/components/org/analytics/AnalyticsHeader.tsx:29,52`; `src/components/pricing/PricingComparisonTable.tsx:42`, `PricingCards.tsx:296`; `src/components/org/billing/BillingPlans.tsx:284–288`; values in `src/lib/constants/pricing.ts:101,141,174,211` **UNCHANGED** (`pricing-parity.test.ts:93–108`) |
| Tests (NEW) | `qr_backend/tests/unit_tests/test_retention_purge.py`; regression-only: `test_feature_gate_coverage.py`, `test_limits_engine.py`, `test_free_scan_reset.py`, `test_scan_limit_reenable.py` |
