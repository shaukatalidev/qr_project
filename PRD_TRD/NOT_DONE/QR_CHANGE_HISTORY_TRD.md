# TRD — QR change history

**Spec:** `QR_CHANGE_HISTORY_PRD.md` · **Status:** Draft (detailed) · **Date:** 2026-08-28
**Migration slot (RESERVATION):** `0055_qr_change_history.sql`. Highest on disk when written: `0054`. **`ls qr_backend/migrations/` and take the next free integer, and re-confirm the highest APPLIED number in the DB — several 003x/004x slots on disk are still unapplied.**
**Repos:** `qr_backend`, `qr_frontend`. **Worker:** no change, no redeploy. **KV contract:** unchanged.
**New plan flags:** none. **New `FEATURE_ENFORCEMENT` entries:** none — depth reuses `analytics_retention_days`, already `enforced`.

---

## 1. Architecture

### 1.1 Shape

```
                          ┌── update_qr        (dashboard)
                          ├── create_qr        (dashboard, creation entry)
                          ├── api_public.py    (public_api)
   record_change(...) ◀───┼── bulk handlers    (bulk)
        │                 ├── _enforce_scan_limit         (sweep / scan_cap)
        │                 ├── razorpay_routes, mor_routes (sweep / plan_downgrade)
        │                 ├── admin/qrs.py                (admin / moderation)
        │                 └── anon-claim sweep            (sweep / unclaimed)
        ▼
   qr_change_events  (append-only: REVOKE + trigger, mirroring admin_audit_log)
        ▲
        └── GET /api/workspaces/{ws}/qr-codes/{id}/history   → History tab
```

### 1.2 Why not a database trigger

A trigger on `qr_codes` is the obvious shortcut and it cannot work:

1. **It cannot see the actor.** The backend uses the Supabase **service role key** and bypasses
   RLS, so every write arrives as the same database role. `auth.uid()` is not available. Attribution
   is the feature; a trigger cannot provide it.
2. **It cannot see the source.** A dashboard save, a public-API call and a cron sweep are the same
   `UPDATE` at the database level, and PRD §5.3 requires them to render differently — attributing
   an automated disable to a colleague is the failure mode we are specifically avoiding.
3. **It cannot see most of the change.** The interesting fields live in `qr_destinations`,
   `qr_designs` and the fifteen `*_details` tables. A trigger per table would produce one row per
   table per save, defeating PRD §5.2's grouping.

The recorder is therefore application-level, called once per mutation with an explicit actor.

### 1.3 Precedent to copy exactly

`admin_audit.py` + `0044_admin_panel.sql` already solved the adjacent problem. Reuse its decisions
rather than re-deriving them:

- **Append-only, belt and braces** — `REVOKE UPDATE, DELETE` from `PUBLIC`, `anon`, `authenticated`
  **and** `service_role`, *plus* a `BEFORE UPDATE OR DELETE` trigger that raises. The migration's
  own comment explains why the REVOKE alone is insufficient: the backend connects as `service_role`,
  and grants are the kind of thing a later migration or a dashboard click can quietly restore. The
  trigger fires for every role including the owner.
- **No FK on the actor column** — `admin_audit_log.actor_user_id` is deliberately FK-free.
- **Never raises** — a logging failure must not fail the operation the user asked for.
- **Only the changed fields, never whole rows** — these are read by a human during incident review.
- **Trim oversized payloads** rather than dropping them (`_MAX_JSON_KEYS = 40`).

## 2. Migration `0055`

```sql
-- Migration 0055: customer-facing per-QR change history.
--
-- Sibling to admin_audit_log (0044), NOT a replacement: that table is platform-scoped
-- ("what did staff do to any tenant"); this one is tenant-scoped ("what happened to my QR").
-- Different reader, different question, different retention.
--
-- Idempotent; safe to re-run. Re-confirm the highest APPLIED migration in the DB first.

BEGIN;

CREATE TABLE IF NOT EXISTS qr_change_events (
    id            uuid        PRIMARY KEY DEFAULT gen_random_uuid(),

    qr_id         uuid        NOT NULL REFERENCES qr_codes(id)   ON DELETE CASCADE,
    workspace_id  uuid        NOT NULL REFERENCES workspaces(id) ON DELETE CASCADE,

    -- No FK to auth.users, matching admin_audit_log.actor_user_id: account_purge
    -- enumerates the tables it clears, and an unknown FK is how it fails. NULL for
    -- system actions, which have no actor at all.
    actor_user_id uuid,
    -- Denormalised at write time so a removed member's past entries still render, and
    -- so rendering never requires enumerating users the reader may not see.
    actor_display text,
    actor_kind    text        NOT NULL,
    source        text        NOT NULL,
    -- System actions only: 'scan_cap' | 'plan_downgrade' | 'unclaimed' | 'moderation'.
    reason        text,

    -- {field: {"from": ..., "to": ...}} or {field: {"changed": true}} for
    -- value-suppressed fields. Never whole rows; never secrets.
    changes       jsonb       NOT NULL DEFAULT '{}'::jsonb,

    created_at    timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT qr_change_events_actor_kind_chk
        CHECK (actor_kind = ANY (ARRAY['user','system','api','admin'])),
    CONSTRAINT qr_change_events_source_chk
        CHECK (source     = ANY (ARRAY['dashboard','public_api','bulk','sweep','admin'])),
    CONSTRAINT qr_change_events_changes_is_object_chk
        CHECK (jsonb_typeof(changes) = 'object'),
    -- A system action must not carry an actor, and a user action must carry a kind that
    -- is not 'system'. Stops the "automated disable blamed on a colleague" failure at
    -- the database rather than at code review.
    CONSTRAINT qr_change_events_system_has_no_actor_chk
        CHECK (actor_kind <> 'system' OR actor_user_id IS NULL)
);

CREATE INDEX IF NOT EXISTS idx_qr_change_events_qr_created
    ON qr_change_events (qr_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_qr_change_events_ws_created
    ON qr_change_events (workspace_id, created_at DESC);

ALTER TABLE qr_change_events ENABLE ROW LEVEL SECURITY;

-- Immutability, belt AND braces — see 0044's identical block and the comment there.
REVOKE UPDATE, DELETE ON qr_change_events FROM PUBLIC;
DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'anon') THEN
        EXECUTE 'REVOKE UPDATE, DELETE ON qr_change_events FROM anon';
    END IF;
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'authenticated') THEN
        EXECUTE 'REVOKE UPDATE, DELETE ON qr_change_events FROM authenticated';
    END IF;
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'service_role') THEN
        EXECUTE 'REVOKE UPDATE, DELETE ON qr_change_events FROM service_role';
    END IF;
END$$;

CREATE OR REPLACE FUNCTION qr_change_events_is_append_only()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    RAISE EXCEPTION
        'qr_change_events is append-only; % is not permitted', TG_OP
        USING ERRCODE = 'restrict_violation';
END;
$$;

DROP TRIGGER IF EXISTS trg_qr_change_events_append_only ON qr_change_events;
CREATE TRIGGER trg_qr_change_events_append_only
    BEFORE UPDATE OR DELETE ON qr_change_events
    FOR EACH ROW EXECUTE FUNCTION qr_change_events_is_append_only();

COMMIT;
```

### 2.1 Two consequences to note

**`ON DELETE CASCADE` vs the append-only trigger — CONFIRMED HAZARD, not a theoretical one.**
The trigger fires `BEFORE DELETE ON qr_change_events`, so a cascade from `qr_codes` also raises.

This is not speculation. `account_purge.py` already lists `admin_audit_log` in `_NEVER_DELETE` with
exactly this reasoning:

> *"admin_audit_log — append-only staff trail (0044). UPDATE/DELETE are revoked AND trigger-blocked
> at the database, so a purge attempting to touch it would RAISE and stall the whole run. Listed
> here so that can never happen by accident."*

`qr_change_events` is worse-placed than `admin_audit_log`, because it does not merely need to be
kept out of a purge list — it hangs off `qr_codes` by FK, and **`account_purge` deletes `qr_codes`
rows in bulk** (`_QR_CHILD_TABLES`, then `db.table("qr_codes").delete().in_("id", chunk)`). A
`BEFORE DELETE` trigger on a cascade target would therefore stall **every account deletion**, which
is a right-to-erasure obligation failing on a schedule.

Two viable resolutions, pick one and write it in the migration comment:
- Restrict the trigger to `BEFORE UPDATE` only, and accept that a cascade may delete rows (the QR
  is gone; its history is not evidence anyone can reach — PRD E6); **or**
- Keep `BEFORE UPDATE OR DELETE` and make the trigger allow deletes when the parent QR no longer
  exists, which is fiddly and probably not worth it.

Recommendation: **`BEFORE UPDATE` only**, with a comment stating that the delete path is guarded by
the FK cascade and by nothing else, deliberately — and that the reason it cannot be
`BEFORE UPDATE OR DELETE` is the `account_purge` cascade above, not an oversight.

Add `qr_change_events` to `_QR_CHILD_TABLES` explicitly as well, so the purge deletes it *before*
the parent rather than relying on cascade ordering.

**`account_purge` must learn about this table.** No FK to `auth.users` avoids the failure mode the
guest-transfer work hit, but the purge routine still needs to null `actor_user_id` (and possibly
`actor_display`, PRD §12 Q1) for the erased user. **Add it to the purge enumeration in the same
PR.** A right-to-erasure request that leaves a user's name in an immutable table is a compliance
problem that cannot be fixed afterwards by an `UPDATE` — the trigger forbids it.

> ⚠️ That last point is load-bearing: an append-only table and a right-to-erasure obligation are in
> tension. Resolve it **before** the migration is applied, not after there is data. If erasure must
> be able to redact, the trigger has to permit a narrowly-scoped update, and that exception must be
> written into the migration with its justification.

## 3. Backend — the recorder

New module `src/utilities/change_log.py`, modelled on `src/utilities/admin_audit.py`.

```python
def record_change(
    db: Client,
    *,
    qr_id: str,
    workspace_id: str,
    changes: dict,
    actor_user_id: str | None = None,
    actor_display: str | None = None,
    actor_kind: str = "user",
    source: str = "dashboard",
    reason: str | None = None,
) -> None:
```

### 3.1 Contract

- **Returns early on an empty `changes` dict.** A save that changed nothing writes no row (PRD E1).
  This is the first line of the function, before any I/O.
- **Never raises.** Wraps the insert in `try/except Exception`, logs at ERROR. Same policy and same
  explicit trade-off as `record_admin_action`: under this policy a QR write can succeed while its
  history row is lost. The alternative — failing the customer's save because a log write failed —
  is worse.
- **Trims** oversized `changes` dicts the way `admin_audit._trim` does, keeping the first N keys and
  appending a `__truncated__` marker. Never drops the payload wholesale.
- **Synchronous and blocking** — the PostgREST client is. From an `async def` handler it **must** be
  `await run_in_threadpool(record_change, ...)`. See §3.3.

### 3.2 Actor resolution

`actor_display` is resolved **at write time** and stored, never at read time:

- `actor_kind='user'` → the member's display name, else the email local-part. **Never the full
  email** and never the workspace name.
- `actor_kind='api'` → the API key's label, e.g. `"API key: production"`.
- `actor_kind='system'` → `NULL`; the UI renders from `reason`.
- `actor_kind='admin'` → `"Qravio support"`. Never a staff member's name — that is what
  `admin_audit_log` is for, and it has a different reader.

Resolving at read time would mean the history endpoint enumerating user records, which is both an
N+1 and a PII surface the reader may not be entitled to.

### 3.3 The blocking-call guard

`test_no_blocking_kv_call_survives_in_an_async_handler` walks the AST of every route module to
catch unwrapped blocking KV calls. `record_change` has the identical hazard. **Either extend that
test's target list to include `record_change`, or add a sibling test with the same shape.** Do not
rely on review — the existing test exists because review did not catch it for KV.

## 4. Backend — building the diff

New module `src/core/qr/diff.py`.

```python
def build_change_set(before: dict, after: dict) -> dict:
    """{field: {"from": x, "to": y}} for fields that actually differ."""
```

### 4.1 ⚠ The `before` snapshot must be taken deliberately

**`update_qr` does not currently read enough to diff against.** Its pre-write read is narrow —
nine columns, no relations:

```python
.select("category, type, status, start_at, end_at, schedule_tz, "
        "daily_start_time, daily_end_time, daily_days")
```

That covers status and the schedule fields and **nothing else** — not the destination, not the
name, not the design, not any content relation. The destination diff (PRD G5, the entry the whole
feature exists for) is not derivable from it.

So the recorder needs its own `before` snapshot. Two options:

| Option | Cost | Coverage |
|---|---|---|
| **A. Widen the existing read to `SELECT_WITH_RELATIONS`** | One heavier query on every update | Everything, including nested content |
| **B. Add a targeted second read** of `qr_codes` (full row) + `qr_destinations` + `qr_designs`, only when a diffable field is in the payload | One extra query, only on relevant saves | Everything except deep content-field diffs, which degrade to `{"changed": true}` |

**Recommendation: B for v1.** `SELECT_WITH_RELATIONS` pulls fifteen `*_details` relations plus
menu categories and items on *every* save, and content-field-level diffing is the least valuable
part of PRD §5.3 (the table already says design changes render as key names, not JSON). Measure A
before choosing it. Whichever is chosen, **write it in the docstring** — the next person will
otherwise assume the narrow read was sufficient, which is exactly the mistake this section exists
to prevent.

### 4.2 Value allowlist, not deny-list

A module-level frozenset names the fields whose **values** may be stored:

```python
VALUE_LOGGED_FIELDS = frozenset({
    "name", "status", "folder_id", "custom_domain_id",
    "destination", "destinations",
    "start_at", "end_at", "schedule_tz",
    "daily_start_time", "daily_end_time", "daily_days",
    "default_locale", "locales", "locale_autodetect",
    "retargeting_mode",
    "page_design.templateId", "page_design.themeColor", "page_design.pageTitle",
})
```

Everything else records `{field: {"changed": True}}` — the field name, no values.

**Allowlist, not deny-list, and this is not a style preference.** A deny-list is defeated by the
next column anyone adds; the allowlist fails safe by omitting a value nobody thought about.

Additionally, strip secrets **at the input boundary** before `before`/`after` ever reach
`build_change_set`: `password_hash`, `password`, `is_password_protected`'s hash side, and any
signed URL. Two independent mistakes are then required to leak one value.

### 4.3 Normalisation — or every save diffs against itself

Three real traps in this codebase:

1. **Timestamps.** `update_qr` normalises `start_at`/`end_at` through `_to_utc_z` before writing.
   A raw PostgREST timestamp string and a `…Z` string are unequal as Python strings while
   representing the same instant. **Normalise both sides through `_to_utc_z` before comparing**, or
   every save records a phantom schedule change.
2. **Column↔field renames.** `update_qr` mutates its own payload mid-flight:
   `update_data["daily_start"]` becomes `update_data["daily_start_time"]`, same for `daily_end`.
   Diff **after** that normalisation, against the column names, or the daily window appears to
   change on every save that touches it and never on saves that do.
3. **`locales` ordering.** It is a JSONB array; compare as a set for "did the locale set change",
   but render the ordered list. Order changes are not user-visible and must not produce an entry.

### 4.4 Suppress no-op destination rewrites

`update_qr` rewrites the `qr_destinations` set wholesale when `destinations` is present in the
payload. The builder sends it on every save. **Compare the resulting set, not the fact that a
rewrite happened**, or every single save records "destinations changed" and the tab becomes noise.

## 5. Backend — call sites

| Path | Module | `source` | `actor_kind` | `reason` |
|---|---|---|---|---|
| Dashboard update | `core/qr/service.py::update_qr` | `dashboard` | `user` | — |
| Creation | `core/qr/service.py::create_qr` | `dashboard` | `user` | — (`changes = {"created": {"to": name}}`) |
| Public API update | `api/routes/api_public.py` | `public_api` | `api` | — |
| Bulk edit / bulk delete | `api/routes/qr.py` bulk handlers | `bulk` | `user` | — |
| Scan-cap disable | `api/routes/internal.py::_enforce_scan_limit` | `sweep` | `system` | `scan_cap` |
| Free-scan monthly re-enable | `api/routes/internal.py::_reenable_free_scan_disabled` | `sweep` | `system` | `scan_cap` |
| Plan-downgrade lock | `api/routes/razorpay_routes.py`, `mor_routes.py` | `sweep` | `system` | `plan_downgrade` |
| Subscription-activation restore | same two modules | `sweep` | `system` | `plan_downgrade` |
| Staff suspend / unsuspend | `api/routes/admin/qrs.py` | `admin` | `admin` | `moderation` |
| Anon-claim reconcile | the `unclaimed_expired` paths | `sweep` | `system` | `unclaimed` |

**All of them ship in the same PR** (PRD §11 phase 1). The four system paths are the larger half of
the value; a history containing only dashboard saves looks complete and is not.

**Ordering:** insert **after** the mutation succeeds. A recorded change that did not happen is worse
than an unrecorded change that did.

**Admin note:** the staff paths write **both** `admin_audit_log` (platform trail, for us) and
`qr_change_events` (tenant trail, for them). Different readers; both are correct.

## 6. Backend — read endpoint

```
GET /api/workspaces/{workspace_id}/qr-codes/{qr_id}/history?limit=50&offset=0
```

`require_can_read`. Explicit `.eq("workspace_id", …)` **and** `.eq("qr_id", …)` — the service role
bypasses RLS, so tenancy is the query's job and nothing else's.

**Retention clamp.** Read `analytics_retention_days` via the same `get_limit` path
`scan.py::get_analytics_days` uses, then filter `created_at >= now() - interval '<n> days'`.

Response:

```json
{
  "items": [
    { "id": "...", "actor_display": "Priya", "actor_kind": "user",
      "source": "dashboard", "reason": null,
      "changes": { "destination": { "from": "...", "to": "..." } },
      "created_at": "2026-08-14T15:42:11Z" }
  ],
  "total": 128,
  "retention_days": 30,
  "truncated": true
}
```

`truncated` is true when rows exist beyond the window. The UI renders PRD §5.4's honest notice from
it. Computing it costs one extra `count` with a `lt(created_at, cutoff)` filter and a `limit(1)` —
cheap, and the alternative is a UI that lies by omission.

**CSV export** (`GET .../history/export.csv`) mirrors `lead_forms.py`'s export shape and applies the
same clamp.

## 7. Worker

**No change. No redeploy. No KV contract regeneration.** History is a dashboard read; nothing
reaches the edge and no KV value changes.

## 8. Frontend

### 8.1 Hook

`src/hooks/useQRHistory.ts` with its own key factory following the `qrKeys` pattern in `useQRs.ts`:

```ts
export const historyKeys = {
  all: ['qr-history'] as const,
  list: (qrId: string, workspaceId: string, page: number) =>
    [...historyKeys.all, qrId, workspaceId, page] as const,
};
```

`QueryClient` defaults do **not** retry 4xx (set in `providers.tsx`), so a 403 costs one request,
not four.

**Invalidate on QR mutation.** `useUpdateQR`'s `onSuccess` must invalidate `historyKeys.all` for
that QR, or the tab shows stale history immediately after the save that created the entry — the
single most likely moment for a user to look.

### 8.2 Components

| File | Responsibility |
|---|---|
| `details/history-tab.tsx` | Composition, pagination, query states. Under 200 lines. |
| `details/history-entry.tsx` | One grouped entry: actor, time, the field lines, expander |
| `details/history-field-diff.tsx` | One field's from → to, implementing PRD §5.3's per-field rules |
| `details/history-retention-notice.tsx` | The truncation banner + upgrade CTA |
| `details/tab-pills.tsx` | Add the History tab |

`history-field-diff.tsx` is where the rules live, in **one** switch on field name, so PRD §5.3 is
implemented once rather than scattered. The destination case is the one to get right first: full
URLs, monospace, copyable, never truncated.

**System entries** render from `reason` with no actor chip and a distinct muted treatment, so
"automatically disabled" can never look like a colleague's action even at a glance.

### 8.3 Loading and error states

Reuse `InlineLoadError` from `components/ui/query-state`, as `ReviewFunnelCard` and
`ScheduledReportsClient` do. Skeleton rows on first load; do not block the whole tab.

## 9. Observability

- One log line per recorder failure at ERROR, carrying `qr_id` and `source`, so a silently-lost
  history surfaces in monitoring rather than in a customer's absent timeline.
- A counter of rows written per `source`, to confirm the four system paths are actually firing —
  the failure mode is that they were wired but never exercised in production.
- `update_qr` p95 before and after (PRD §9).

## 10. Tests

### 10.1 Diff unit tests — `tests/unit_tests/test_qr_change_diff.py`

Pure function, table-driven:

- three changed fields → three keys, exact values;
- no change → `{}`;
- a timestamp that differs only in representation (`+00:00` vs `Z`) → **no** entry (§4.3 trap 1);
- `daily_start` vs `daily_start_time` naming → one entry, not two, not zero (§4.3 trap 2);
- `locales` reordered but same set → no entry (§4.3 trap 3);
- an identical destination set rewritten → no entry (§4.4);
- a field outside `VALUE_LOGGED_FIELDS` → `{"changed": true}`, no values;
- `password_hash` present in the inputs → **absent from the output entirely**, asserted on the
  serialised JSON, not on the dict.

### 10.2 Recorder tests — `tests/unit_tests/test_change_log.py`

`FakeDB` (applies `.eq()` filters, journals operation order — a `MagicMock` returns a truthy row
whatever you ask it for, so a tenancy assertion would pass with or without the filter that makes it
true):

- empty `changes` → zero inserts;
- an insert that raises → `record_change` returns normally and logs; **the caller's save still
  succeeds** (inject a failing insert into an `update_qr` test and assert the QR saved);
- oversized `changes` → trimmed with the `__truncated__` marker, not dropped;
- `actor_kind='system'` → `actor_user_id IS NULL` and `actor_display IS NULL`.

### 10.3 Call-site tests

- `update_qr` touching name + destination + status → **one** row, three keys.
- `create_qr` → one creation row.
- Bulk edit over five QRs → **five** rows, not five × fields (PRD E2).
- `_enforce_scan_limit` disabling a QR → `actor_kind='system'`, `source='sweep'`,
  `reason='scan_cap'`, `actor_user_id IS NULL`. **This is the test that protects a colleague from
  being blamed for an automated action.**
- Plan-downgrade lock → `reason='plan_downgrade'`.
- Admin suspend → writes **both** `admin_audit_log` and `qr_change_events`.
- Public API update → `source='public_api'`, `actor_kind='api'`.

### 10.4 Read endpoint tests

- Cross-workspace `qr_id` → 404, and the `.eq("workspace_id", …)` filter appears in the journal.
- Free plan (7 days) does not receive a 30-day-old row, and `truncated` is `true`.
- Agency (365 days) receives it, `truncated` is `false`.
- A `viewer` member can read (PRD E7).

### 10.5 Migration tests

- An `UPDATE` on `qr_change_events` raises `restrict_violation`.
- A `DELETE` behaves as §2.1 decided — assert whichever branch was chosen, explicitly.
- **Deleting a `qr_codes` row still succeeds** with history rows present. This is the §2.1 hazard
  and the one that becomes a production outage if unverified.

### 10.6 Coverage guard

A test enumerating the route modules that mutate QRs and asserting each imports `record_change` —
same shape as the existing AST guard. The `source` CHECK constraint is the second line of defence:
an unlisted path fails loudly at insert rather than writing an unattributable row.

**All of the above must run with no Postgres.** CI runs bare `pytest` with no database service, so
a DB-backed test *skips* there — and a skip is indistinguishable from a pass in a green run.
`tests/integration_tests/conftest.py`'s `requires_db` marks the few that genuinely need the local
stack; §10.5's migration assertions are the honest candidates for it, and if they are marked, run
them locally before merging.

### 10.7 Frontend — Vitest

- Timeline renders grouped entries; nine fields render as one entry.
- A system entry renders as automated, with **no** person named.
- The retention notice appears only when `truncated`.
- The destination diff renders both URLs in full and is copyable.
- A password entry shows "changed" and no value anywhere in the DOM.

## 11. Rollout

1. **Decide the erasure/append-only tension** (§2.1) — before the migration is applied.
2. **Apply `0055`** (re-confirm the slot; re-confirm the highest applied number).
3. **Add the three tables**… — add `qr_change_events` to `account_purge`'s enumeration, same PR.
4. **Ship the recorder + all ten call sites + the read endpoint** in one PR.
5. **Ship the tab, the notice and the CSV export.**

Backwards compatible: pre-existing QRs have no rows and render PRD §5.4's "history starts" state.
No backfill is possible; do not simulate one.

## 12. Risks

| Risk | Mitigation |
|---|---|
| A secret reaches `changes` | Allowlist (§4.2) + boundary stripping + a test asserting on the serialised row. |
| Every save records phantom changes | The three normalisation traps in §4.3 and the destination no-op in §4.4, each with its own test. |
| The `before` snapshot is assumed to exist and does not | §4.1 — the existing read is nine columns and no relations. Choose A or B deliberately and document it. |
| The append-only trigger blocks QR deletion | §2.1 — verify, and prefer `BEFORE UPDATE` only. Tested in §10.5. |
| Erasure cannot redact an immutable table | §2.1's warning; resolve before applying the migration. |
| A system action is attributed to a person | CHECK constraint + explicit `actor_kind` at every sweep call site + §10.3's test. |
| Unbounded growth | Retention-clamped reads, both indexes `created_at DESC`, physical prune scheduled with the analytics prune — not left undefined. |
| A future mutation path ships with no recorder | `source` CHECK + the §10.6 coverage test. |
