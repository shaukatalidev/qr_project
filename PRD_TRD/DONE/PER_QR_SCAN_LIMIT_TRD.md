# TRD — Per-QR scan limit

**Spec:** `PER_QR_SCAN_LIMIT_PRD.md` · **Status:** SHIPPED 2026-08-29 (see §0) · **Date:** 2026-08-28
**Migration slot (RESERVATION):** `0056_qr_scan_limit.sql`. Highest on disk when written: `0054`. **`ls qr_backend/migrations/` and take the next free integer; re-confirm the highest APPLIED number in the DB.**
**Repos:** `qr_backend`, `qr_cf_code`, `qr_frontend`. **KV payload changes → regenerate `kv_contract.json` and run the parity script.**
**New plan flags:** none. **New `FEATURE_ENFORCEMENT` entries:** none.

---

## 0. AS BUILT — 2026-08-29

Shipped as `feat/per-qr-scan-limit` in all three repos. **Read this before anything below
it.** The core design — backend counts, edge enforces a boolean, no new status value —
survived intact and needed no revision. What follows are the places the spec described a
world that no longer exists, and two hazards it did not know about.

### The two headline risks were already fixed

| Spec claim | Reality |
|---|---|
| TRD §3.4 / PRD §10, presented as the highest-risk item: *"'outside_hours' has been rejected here since the daily-window feature shipped… the Worker has been POSTing it and silently having it dropped"* | **Fixed before this feature.** `internal.py` accepts all four reasons today. The comment above the check narrates the bug in the past tense and reads as though it is current — which is exactly how a stale warning survives. The **lockstep discipline still applies**, and the guard below is real, but nothing was re-fixed. |
| PRD G5 / TRD §3.2: *"the known live bug in which bots are hidden from analytics but ARE charged against `max_scans` — do not inherit it"* | **Also fixed**, by `src/utilities/scan_counting.py`. Every quota path now routes through `count_billable_scans` (`subscription.py:444`, `internal.py:642`, `internal.py:716`). |

Both were true when the specs were drafted. Neither was checked before they were written up
as live risks, and both would have sent an implementer looking for a bug that was not there.

### The count-source dilemma was already solved, in the same function

TRD §3.2 requirement 2 presents an open choice between the cheap-but-lossy
`qr_scan_counters` and the accurate-but-expensive `qr_scan_events`, and asks the implementer
to "choose deliberately and document it". **`check_scan_milestones` — called forty lines
below the new call site — had already solved it**: use the counter as a cheap GATE and pay
for an accurate `count(*)` only once the gate clears. That shape was copied verbatim, and
the docstring says where it came from.

The gate under-counting is safe (it delays the check to a later scan, and the accurate count
then decides); over-counting is impossible, because a lost read-modify-write only ever loses.

### Two hazards the spec did not know about

**`get_qr_blocked_scans` was dropping two of the four reasons.** It bucketed a hand-written
`{"not_yet_live", "expired"}`, so `outside_hours` (0048) and `unclaimed_expired` (0052) were
counted by the edge, stored by the DB, and then discarded on the way out — `total`
under-reported and daily-window blocks were never shown to owners at all. The same drift the
feature is about, one layer further out. Now derived from the allowlist, with a test.

**The "Limit reached" badge name was already taken.** `getStatusMeta` returned the label
**"Scan limit reached"** for `status === 'disabled'` — the WORKSPACE's monthly billing
quota, rendered on an individual QR row in words that sound per-QR. Shipping PRD §5.3's
badge as specified would have put two identical labels with opposite meanings on the same
screen. The workspace one is now "Workspace limit".

### Corrections

| # | Section | Correction |
|---|---|---|
| 1 | §4 | **The KV contract does not apply.** `kv_contract.json` covers only the per-type `content` sub-object; `scan_limit` / `scan_limit_reached` are top-level siblings of it. No regeneration, and the parity script would not have caught drift on them. The §8.3 select-coverage assertion is the control that does. |
| 2 | §5.1 | The branch goes **between** the absolute window and the daily window, not after both. A cap is permanent; "closed, opens again at 09:30" promises a reopening that is never coming. |
| 3 | §6 | *"RHF + zod"* — `schedule-card.tsx`, the file the TRD says to model on, uses local `useState` + a plain validator. Matched the sibling. |
| 4 | §6 | *"progress bar in `performance-panel.tsx`"* — that panel has no progress bar. Reused `ui/progress.tsx` with the `ApiUsageMeter` idiom. |
| 5 | §3.2 | `record_scan_event` does not read the `qr_codes` row at all (the `workspace_id` lookup is conditional and rarely runs), so the check pays for its own single indexed read. |
| 6 | §8.1 | The lockstep test does **not** parse the Worker from `qr_backend`. Two of the three places live in this repo and they are the two that drifted, so the primary guard works inside one repo's CI; the cross-repo leg uses a checked-in `blocked_reasons.json` and a parity script. |

### Decisions taken at build time

* **`scan_limit` is on the public API** (PRD §12 Q3). It rides along for free —
  `api_public.py` reuses `QRCodeCreate`/`QRCodeUpdate` — so excluding it would have been
  deliberate extra work.
* **No webhook** (PRD §12 Q4). `scan.milestone` is Agency-only with fixed global thresholds
  `[100, 1000, 10000]`, so a per-QR cap cannot reuse it; it would be a new event type.
  Sequenced as a follow-up.
* **`getStatusMeta` takes one lifecycle argument, not two.** Every caller passes the same
  `qr` object, and `getStatusMeta(qr.status, qr, qr)` reads like a mistake.
* **The builder control shares the Schedule accordion** rather than adding a step. "When
  does this stop working" is one question on two axes.

### Both new guards were verified by breaking them

A guard that cannot fail is worse than no guard, so each was checked by simulating the exact
historic drift and confirming it failed with the offending name:

* removing `outside_hours` from the Python allowlist → *"accepted by the DB but not Python:
  ['outside_hours']"*;
* removing `scan_limit_reached_at` from `sync_qr_to_kv`'s select → *"sync_qr_to_kv reads
  ['scan_limit_reached_at'] off the QR row but does not select them"*.


---

## 1. Architecture

```
qr_codes.scan_limit  ·  qr_codes.scan_limit_reached_at
        │
        ├── sync_qr_to_kv ──▶ KV { scan_limit: 100, scan_limit_reached: false }
        │                              │
        │                              ▼
        │                   Worker src/index.js
        │                     status branches → schedule branches → **scan-limit branch**
        │                            │                                     │
        │                            │                    reached → getSchedulePage({state:"scan_limit_reached"})
        │                            │                            + recordBlockedScan(..., "scan_limit")
        │                            └── website early-return (MUST be after the branch)
        │
        └── internal.py record_scan_event
              count non-bot scans → >= limit && reached_at IS NULL
                → stamp reached_at → publish_qr
```

**The backend counts, the edge enforces.** PRD §6 explains why the edge cannot count and what we
promise instead. Do **not** attempt an edge counter in KV: it is ~1 write/sec/key and eventually
consistent, so a Worker-maintained count would be both lossy and slow — less accurate than the
backend path while appearing more precise.

## 2. Migration `0056`

```sql
-- Migration 0056: per-QR scan limit ("stop after N scans").
--
-- Sibling to 0033/0048 (time-based windows). Deliberately NOT a new qr_codes.status
-- value: the enum already carries five values with five distinct owners (see
-- src/core/qr/status.py). The limit is a nullable column evaluated at the edge and
-- derived for display, exactly as start_at/end_at are.
--
-- Idempotent; safe to re-run. Re-confirm the highest APPLIED migration first.

BEGIN;

ALTER TABLE qr_codes ADD COLUMN IF NOT EXISTS scan_limit            integer;
ALTER TABLE qr_codes ADD COLUMN IF NOT EXISTS scan_limit_reached_at timestamptz;

ALTER TABLE qr_codes DROP CONSTRAINT IF EXISTS qr_codes_scan_limit_chk;
ALTER TABLE qr_codes ADD CONSTRAINT qr_codes_scan_limit_chk
    CHECK (scan_limit IS NULL OR scan_limit > 0);

-- A QR cannot be "reached" without a limit to reach.
ALTER TABLE qr_codes DROP CONSTRAINT IF EXISTS qr_codes_scan_limit_reached_chk;
ALTER TABLE qr_codes ADD CONSTRAINT qr_codes_scan_limit_reached_chk
    CHECK (scan_limit_reached_at IS NULL OR scan_limit IS NOT NULL);

-- Partial: only limited QRs are ever compared or swept.
CREATE INDEX IF NOT EXISTS idx_qr_codes_scan_limit
    ON qr_codes (id) WHERE scan_limit IS NOT NULL;

-- ── Blocked-scan reason: widen the CHECK. ────────────────────────────────────
-- The constraint has been widened twice already (0048 added 'outside_hours',
-- 0052 added 'unclaimed_expired'), and the accompanying Python allowlist in
-- internal.py::record_blocked_scan was NOT updated for 'outside_hours' — so the
-- Worker POSTed it and the backend silently dropped it for the whole lifetime of
-- the daily-window feature. See §3.4: three places change together or the counts
-- vanish with no error anywhere.
ALTER TABLE qr_blocked_scans DROP CONSTRAINT IF EXISTS qr_blocked_scans_reason_chk;
ALTER TABLE qr_blocked_scans ADD CONSTRAINT qr_blocked_scans_reason_chk
    CHECK (blocked_reason IN (
        'not_yet_live', 'expired', 'outside_hours', 'unclaimed_expired', 'scan_limit'
    ));

COMMIT;

-- Sanity:
--   SELECT id, name, scan_limit, scan_limit_reached_at FROM qr_codes
--    WHERE scan_limit IS NOT NULL ORDER BY scan_limit_reached_at DESC NULLS LAST LIMIT 20;
--   SELECT blocked_reason, sum(count) FROM qr_blocked_scans GROUP BY 1;
```

**Verify the current constraint text before writing the `ADD`** — `0000_base_schema.sql` shows only
`('not_yet_live','expired')`, while `0048` and `0052` widened it. Dropping and re-adding with the
full list is idempotent and safe; appending to a guessed list is not.

Nullable, no default, no backfill: every existing QR is unlimited and its KV value is untouched
until it is next republished.

## 3. Backend

### 3.1 KV publish — `src/utilities/cloudflare_kv.py`

**Two edits, both mandatory in the same commit.**

**(a) `sync_qr_to_kv`'s explicit `select(...)`** — currently:

```python
.select(
    "id, short_code, type, workspace_id, status, is_password_protected, "
    "start_at, end_at, schedule_tz, default_locale, locales, locale_autodetect, "
    "daily_start_time, daily_end_time, daily_days"
)
```

must gain `scan_limit, scan_limit_reached_at`.

That select is explicit by design, and its own comment says why: *"Omitting one does not fail
loudly — it silently drops that setting from KV on the next resync (scan-limit disable, billing
re-enable, branding save…), which is exactly how page_design once caused permanent DB↔KV drift."*
Adding the columns without touching this line ships a limit that vanishes when a customer saves
their branding.

**(b) `write_to_kv(...)`** gains:

```python
scan_limit=qr.get("scan_limit"),
scan_limit_reached=bool(qr.get("scan_limit_reached_at")),
```

**Emit a boolean, not the timestamp.** The Worker needs a decision, not a date, and a boolean
cannot be misparsed. This is the direct lesson from the expiry work, where a raw PostgREST
timestamp string could `Date.parse` → `NaN` in V8 and silently never expire; the fix there was
normalising to strict `…Z` in Python (`_to_utc_z`). A boolean removes the class of bug entirely.

**Omit both keys when `scan_limit IS NULL`,** so unlimited QRs keep byte-identical KV values and
the Worker's zero-work path is keyed on absence — the same discipline the `i18n` block uses.

### 3.2 Counting — `src/api/routes/internal.py::record_scan_event`

After the existing scan insert, and **only** when the QR carries a `scan_limit`:

```python
if qr.get("scan_limit") and not qr.get("scan_limit_reached_at"):
    count = _count_qr_scans_excluding_bots(qr_id, db)
    if count >= qr["scan_limit"]:
        db.table("qr_codes").update(
            {"scan_limit_reached_at": _now_z()}
        ).eq("id", qr_id).is_("scan_limit_reached_at", "null").execute()
        await run_in_threadpool(publish_qr, qr_id, db)
```

Four requirements:

1. **Exclude bots.** Use `exclude_bot_scans` from `src/utilities/scan_counting.py` (PRD G5). Note
   the known live bug in which bots are hidden from analytics but **are** charged against
   `max_scans`; do not inherit it here.
2. **Choose the count source deliberately and document it.** `qr_scan_counters` is cheaper but has
   a known non-atomic write path, so it can under-count — and an under-count means serving *more*
   than N, which is the direction that embarrasses us. `qr_scan_events` is accurate and more
   expensive. **Write the choice and its reasoning in the docstring**; the next reader will
   otherwise assume the cheap one was fine.
3. **The `.is_("scan_limit_reached_at", "null")` guard makes the stamp idempotent** under concurrent
   scans, so a burst does not produce N publishes.
4. **Never raise into the scan path.** A failure here loses a limit enforcement; raising would lose
   a scan record, which is worse. Wrap it.

**Do not touch `_enforce_scan_limit`.** That is the workspace-wide plan cap; it disables every QR
the workspace owns. Sharing code with it is how a per-QR limit becomes a workspace outage. Add a
comment at the new call site naming that hazard explicitly.

### 3.3 Update path — `src/core/qr/service.py`

`create_qr` / `update_qr` accept `scan_limit` (nullable int, `> 0`):

- **Raising or clearing the limit clears `scan_limit_reached_at` in the same write**, then
  republishes. This is PRD E1/E2, the revive path, and the one users exercise under pressure.
- **Lowering below the current count stamps `reached_at` immediately** (PRD E3). Do not leave a QR
  serving above its own stated limit because the crossing already happened.
- Reject `scan_limit` on **static** QRs with a clear message (PRD NG4), mirroring how
  `_validate_schedule_window` rejects a window on a static QR.
- The QR read returns `scan_limit`, `scan_limit_reached_at` **and the current non-bot scan count**,
  so the dashboard renders "73 of 100" without a second request.

### 3.4 ⚠ The three-place lockstep — the highest-risk change in this TRD

Adding a blocked-scan reason requires **three** changes. Missing any one loses every count with no
error anywhere:

| # | Place | Change |
|---|---|---|
| 1 | DB `CHECK` on `qr_blocked_scans.blocked_reason` | Add `'scan_limit'` (§2) |
| 2 | **`internal.py::record_blocked_scan`'s Python allowlist** — currently `("not_yet_live", "expired", "outside_hours", "unclaimed_expired")` | Add `"scan_limit"` |
| 3 | The Worker call site | `recordBlockedScan(env, qr_id, workspace_id, "scan_limit")` |

**This has already gone wrong once, in this exact function.** The endpoint's own comment records
it: *"'outside_hours' has been rejected here since the daily-window feature shipped, even though
migration 0048 widened the DB CHECK to accept it — the Worker has been POSTing it and silently
having it dropped, so recurring-window blocks were never counted."*

The failure is invisible from both ends: the endpoint returns `{"status": "error"}` with HTTP 200,
and `recordBlockedScan` is fire-and-forget with every failure swallowed. **Add a test that asserts
every reason the Worker can send is accepted by the endpoint** (§8.1) — that is the only control
that actually works here.

### 3.5 Schemas

`src/api/schemas/qr.py`: add `scan_limit: Optional[int]` to `QRCodeCreate` and `QRCodeUpdate`, and
`scan_limit` / `scan_limit_reached_at` / `scan_count` to the response model. Validate `> 0` as a
pure validator beside the existing ones.

Public API picks it up if it reuses these models — verify, and answer PRD §12 Q3 in the PR
description.

## 4. KV contract

The payload gains two top-level keys (`build_kv_content` is untouched — these are not part of the
type-specific `content` block):

```bash
cd qr_backend && UPDATE_KV_CONTRACT=1 pytest tests/integration_tests/test_kv_contract.py
cp tests/integration_tests/kv_contract.json ../qr_cf_code/src/integration/
./scripts/check-kv-contract-parity.sh    # manual pre-merge step; no CI job sees both repos
```

## 5. Worker — `qr_cf_code`

### 5.1 Branch placement (load-bearing)

`src/index.js` runs, in order:

```
suspended → paused → disabled → locked → unclaimed_expired
  → schedule window (not_yet_live, expired)
  → daily window (outside_hours)
  → ★ SCAN LIMIT GOES HERE ★
  → password gate
  → locale resolution
  → routing
  → website early-return (handleWebsiteRedirect)
  → handleQRCode dispatch → recordScan
```

Three constraints, each with a failure mode:

- **After the status branches** — a moderation hold, a pause, a plan lock and a billing disable all
  outrank a scan limit. A suspended QR must never be described to the public as "reached its scan
  limit" (PRD E7).
- **After the schedule branches** — "expired" is the more informative statement when both apply
  (PRD E6), and it matches the precedent already set between the absolute and daily windows.
- **BEFORE the password gate and BEFORE the `type === "website"` early-return.** The existing
  schedule comment spells out the second one: *"website QRs return from handleWebsiteRedirect
  before the generic recordScan, so a check placed near recordScan would let expired website QRs
  keep redirecting."* Identical hazard here, and `website` is the most common type (PRD E8).
  Before the password gate so a capped QR does not prompt for a password it will then refuse.

### 5.2 The branch

```js
// ── Per-QR scan limit ───────────────────────────────────────────────────────
// The BACKEND counts (KV is eventually consistent and ~1 write/sec/key, so the
// edge cannot maintain an accurate counter); this reads the decision it stamped.
// Absent key = unlimited = every QR that predates this feature, which is the
// zero-work fast path.
//
// FAIL OPEN on anything unexpected: darking a printed QR on a bad flag is worse
// than serving a few extra scans. Log loudly — a limit that silently never fires
// is the exact failure this feature exists to prevent.
if (scan_limit_reached === true) {
  ctx.waitUntil(recordBlockedScan(env, qr_id, workspace_id, "scan_limit"));
  return getSchedulePage({ state: "scan_limit_reached", whiteLabel, brand });
}
if (scan_limit_reached !== undefined && typeof scan_limit_reached !== "boolean") {
  console.error(`[scan_limit] non-boolean flag for ${shortCode}: ${scan_limit_reached}`);
}
```

Returning **here**, before `recordScan`, is what keeps this page from POSTing `/internal/scans`.
That is not cosmetic: the backend counts that table per workspace with no type filter, so a scan
recorded here burns the billable cap and, once tripped, disables every other QR the workspace owns.

### 5.3 The page — extend `getSchedulePage`, do not add a fourth module

`src/pages/schedulePage.js` already handles three states through a shared `buildPage({accentColor,
accentBg, accentBorder, badgeText, title, description, svgPath, whiteLabel, brand})` helper. Add a
fourth state rather than writing a near-identical HTML template:

```js
if (state === "scan_limit_reached") {
  return buildPage({
    accentColor: "#f43f5e",
    accentBg: "rgba(244, 63, 94, 0.15)",
    accentBorder: "rgba(244, 63, 94, 0.4)",
    badgeText: "Limit reached",
    title: "This code has reached its scan limit",
    description: "The person who created it set a limit on how many times it can be used.",
    svgPath: `...`,
    whiteLabel,
    brand,
  });
}
```

**This is emphatically NOT `scanLimitPage.js`.** That module is the *plan*-cap page shown when
`status === 'disabled'`, and it carries an upgrade message aimed at our customer. Showing it to a
café's customer who scanned a table tent is meaningless and embarrassing (PRD G3, §5.5). The two
modules keep near-identical names and completely different audiences — put a comment saying so in
both files.

Escape all interpolated values through `escapeHTML()` from `src/utils/html.js`.

## 6. Frontend

| File | Purpose |
|---|---|
| `components/org/qrs/details/scan-limit-card.tsx` | Toggle, number input, progress, honesty note, the two framing chips, **Raise limit** when reached. Model on `schedule-card.tsx`. Under 200 lines. |
| `components/qr-generator/...` | The same control at create time, beside the schedule control |
| `components/org/qrs/components/QRCodesTable.tsx` | **Limit reached** badge, derived |
| `components/org/qrs/details/performance-panel.tsx` | Progress bar `73 / 100` |
| `src/lib/types/qr.ts` | `scan_limit`, `scan_limit_reached_at`, `scan_count` |

RHF + zod (`z.number().int().min(1)`), no uncontrolled inputs. Hidden for `category === 'static'`
with the one-line "convert to dynamic" note, exactly as the schedule control does.

## 7. Rollout — order matters

1. **Apply `0056`** (slot re-confirmed; highest-applied re-confirmed).
2. **Deploy the Worker** (`npm run deploy:prod` — there is no plain `npm run deploy`).
3. **Deploy the backend.**
4. **Ship the frontend.**

Worker first because a KV key it does not understand is ignored (harmless), while a backend
stamping the flag with no Worker branch means the limit silently does nothing while the UI claims
enforcement — PRD §11.

## 8. Tests

### 8.1 The lockstep test (write this first)

```python
def test_every_worker_blocked_reason_is_accepted_by_the_endpoint():
    ...
```

Enumerate the reason strings the Worker can send — ideally by parsing `recordBlockedScan(` call
sites out of `qr_cf_code/src/index.js`, or from a checked-in constant list if the repo boundary
makes that impractical — and assert each is accepted by `record_blocked_scan` **and** satisfies the
DB CHECK. This is the only control that actually catches §3.4's failure, which has already shipped
once undetected.

If cross-repo parsing is not available in `qr_backend`'s CI (it clones one repo), use the
`keys.json` / `kv_contract.json` pattern: a checked-in generated list in both repos plus a parity
script. **Do not rely on a reviewer noticing.**

### 8.2 Backend unit (`FakeDB`)

- crossing the limit stamps `reached_at` **once** and publishes once, even across concurrent scans
  (the `.is_(..., "null")` guard);
- **bot scans do not count** — 100 bot scans on a limit of 100 leave `reached_at` NULL;
- raising the limit clears `reached_at` and republishes;
- clearing the limit clears `reached_at` and omits both KV keys;
- lowering below the current count stamps immediately (PRD E3);
- `scan_limit` on a static QR → 422;
- `scan_limit = 0` or negative → 422 (and the DB CHECK as the second line);
- **`_enforce_scan_limit` is not called and not modified** by any of this;
- a failure in the counting block does **not** fail the scan insert.

### 8.3 KV

- `sync_qr_to_kv` emits `scan_limit` and a **boolean** `scan_limit_reached`;
- both keys are **absent** when `scan_limit IS NULL`, and the KV value is byte-identical to
  pre-feature output;
- **an assertion that every column the Worker reads is named in `sync_qr_to_kv`'s `select(...)`** —
  this generalises §3.1(a) and would have caught the `page_design` drift;
- `conftest.py`'s guard must still fail any test reaching the real Cloudflare API.

### 8.4 Worker — standalone scripts (`node src/<name>.test.mjs`; no runner, no `npm test`)

`src/pages/schedulePage.test.mjs` — the new state renders, carries **no upgrade CTA**, and honours
`whiteLabel` / `brand`.

`src/integration/scanFlow.test.mjs` — the real `fetch` handler over the fake KV binding:

- `scan_limit_reached: true` → the reached page **and zero POSTs to `/internal/scans`**;
- one POST to `/internal/blocked-scan` with `blocked_reason: "scan_limit"`;
- a **`website`** QR with the flag → the reached page, **not a 302** (the early-return trap, PRD E8);
- `suspended` **and** limited → the **disabled** page (ordering, PRD E7);
- `expired` **and** limited → the **expired** page (ordering, PRD E6);
- password-protected **and** limited → the reached page, **no** password prompt;
- keys absent → byte-identical output to pre-feature;
- a non-boolean flag → serves normally (fail open) and logs.

**Drain `ctx.waitUntil` until it stops growing.** Callers fire `recordScan`/`recordBlockedScan`
without awaiting, and `recordScan` awaits two crypto digests before deferring, so a single
`Promise.all` finds an empty list and the POST surfaces during the *next* test.

### 8.5 Frontend — Vitest

- the card renders for dynamic and is hidden for static;
- progress renders `73 of 100`;
- the honesty note is present (PRD G8 — assert on the copy, it is a product commitment);
- **Raise limit** appears only when reached;
- both framing chips write the same field;
- zod rejects 0, negatives and non-integers.

## 9. Observability

- Log the crossing event: `qr_id`, `workspace_id`, `scan_limit`, `count_at_crossing`. The
  difference between `count_at_crossing` and `scan_limit` is **the overshoot metric** in PRD §9,
  and it cannot be reconstructed later.
- Graph blocked-scan volume by reason — a `scan_limit` count stuck at zero after launch means §3.4
  went wrong.
- Alert if `qr_blocked_scans` rows with `blocked_reason='scan_limit'` remain zero for 48h after the
  first QR reaches its limit.

## 10. Risks

| Risk | Mitigation |
|---|---|
| The three-place lockstep is broken | §3.4 + the §8.1 test + the §9 alert. Three independent controls, because review already failed at this once. |
| `sync_qr_to_kv`'s select is not updated | §3.1(a) + the §8.3 assertion that every Worker-read key is named in the select. |
| Blocked scans reach the billing counter | Worker returns before `recordScan`; §8.4 pins it; a backend test asserts `count_billable_scans` ignores `qr_blocked_scans`. |
| Counting from a lossy counter under-counts, so we serve more than N | §3.2 requirement 2 — decide and document; the §9 overshoot metric makes it visible. |
| Someone reuses `_enforce_scan_limit` | Its docstring says it disables the whole workspace; add a comment at the new call site naming the hazard. |
| The plan-cap page is shown to a public scanner | §5.3 — separate state, cross-referencing comments in both modules. |
| Overshoot is materially large | Measured (§9). If p95 is bad, the honest response is a Durable Object and a new spec, not quieter copy. |
