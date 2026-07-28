# PRD — Data Retention Enforcement (Hard Delete of Expired Analytics Data)

**Status:** Draft · **Author:** Product · **Date:** 2026-07-27
**Priority:** Trust/compliance debt paydown, not a growth feature. We **advertise** a retention window on every pricing surface and we **do not honour it** — `analytics_retention_days` is a read clamp only; no scan row has ever been deleted. This closes the gap between the promise and the disk.
**Tiers:** **All tiers** — this is a platform behaviour, not a packaged feature. The *window* is already tier-differentiated (Free 7 · Starter 30 · Pro 90 · Agency 365; `-1` = unlimited), so enforcement inherits the existing packaging unchanged.
**Plan flags:** **None new.** Reuses the shipped `analytics_retention_days` limit (already `"enforced"` in `FEATURE_ENFORCEMENT`, `qr_backend/src/api/routes/subscription.py:539`). No `FEATURE_ENFORCEMENT` addition, no new seed, **no `test_feature_gate_coverage` exposure** — a rare spec with zero flag work. The registry *comment* on that line is wrong and must be corrected (it names a `get_analytics_days` function that does not exist and describes the flag as clamp-only).
**Split from:** the retention half of **PLAN_LIMITS_ENFORCEMENT_PRD** (`PRD_TRD/DONE/`), which shipped the read clamp and deferred the delete. This is that deferred half. Distinct from **ACCOUNT_DELETION_ERASURE** (concurrent draft), which covers *user-initiated* erasure; this covers *time-based automatic* purge.

---

## 1. TL;DR / Summary

Qravio sells a retention window — "7 days of analytics" on Free, "1 year" on Agency — and enforces it by **hiding** old data at read time. It has never **deleted** any of it. Every `qr_scan_events` row ever written is still on disk, and it becomes readable again the moment a workspace upgrades, because the clamp is computed from the *current* plan.

This feature adds the missing half: a **daily, per-workspace, batched hard delete** of raw scan telemetry older than that workspace's `analytics_retention_days`, driven by the existing Cloudflare Worker cron → a new backend `/internal/retention-purge` endpoint. Retention is resolved through the *same* `get_limit(ws, db, "analytics_retention_days")` helper the clamp already uses — one source of truth, no second retention config.

Three hard requirements make it safe to ship a feature whose bug mode is irreversible customer data loss:

1. **Raw events are purged; aggregates are never touched.** `qr_scan_counters` (lifetime totals, device/country/date/hour maps) survives every purge, so a customer's all-time scan count never moves.
2. **Blast-radius rails are v1 scope, not polish** — a `RETENTION_DRY_RUN` mode that ships enabled by default, a max-rows-per-run ceiling, and a per-workspace anomaly guard that aborts rather than deletes when a run wants to delete far more than that workspace's recent history.
3. **A 30-day grace period before the first purge at a *reduced* retention window.** A customer who downgrades Pro→Free for one month must not silently lose 83 days of history overnight. The system detects the reduction itself and holds the old window for 30 days, with an owner email pointing at the existing analytics export.

## 2. Problem & Motivation

**We make a retention claim on four surfaces and honour it on none.** `analytics_retention_days` is seeded 7/30/90/365 per tier (`qr_backend/migrations/0009_pricing_v3_4tier_collapse.sql:98,101,104,107`) and rendered as a paid differentiator on the marketing pricing table (`qr_frontend/src/components/pricing/PricingComparisonTable.tsx:42` — "Analytics Retention"), the pricing cards (`PricingCards.tsx:296`), the in-app billing plan list (`BillingPlans.tsx:284–288`), and the analytics range picker (`AnalyticsHeader.tsx:52`). Every one of those reads as a data-lifecycle promise.

**What actually happens is a read clamp.** Every call site resolves the limit and narrows a query window — `scan.py:234–248` (`_retention_days` / `_retention_cutoff_iso`), `scan.py:390`, `:549`, `:738`, `:929`, `:1414`, `:1629`; `reports.py:211–212`; `analytics_reports.py:302`. There is **no `DELETE` against `qr_scan_events` anywhere in `qr_backend/src/`** — verified. The rows stay. Forever.

Four consequences, in descending order of how much they should worry us:

- **(a) The privacy claim is false as written.** "We keep 7 days" is a statement about our systems, not about a UI filter. A customer reading the pricing page, a prospect's security questionnaire, and a DPA all interpret it as deletion. Today it means "we hide it from you."
- **(b) Blast radius.** Every scan event ever recorded — `ip_hash`, `session_id`, `country_code`/`region`/`city`, `latitude`/`longitude`, `asn`, `user_agent`, `referer`, `destination_url` (`ScanEventPayload`, `internal.py:325–347`) — is one breach away from disclosure, including data we told the customer was gone years ago. Deleting expired telemetry is the single highest-leverage reduction in what a breach can expose.
- **(c) Unbounded storage growth.** `qr_scan_events` is the highest-write table in the product (one row per scan, forever) and is the sole source for every windowed aggregation (`_MAX_WINDOW_EVENTS = 50000`, `scan.py:229`). Cost and query planning both degrade monotonically with a table that only ever grows.
- **(d) Upgrade silently un-hides "deleted" data.** `_retention_days` reads `get_limit` → `resolve_plan` → the workspace's **current** plan (`subscription.py:283–329`). A Free workspace on day 400 has 400 days of rows on disk and a 7-day clamp. The instant it upgrades to Agency the clamp becomes 365 days and **393 days of previously-hidden history become readable**. That is definitionally not retention — it is a paywall on data we said we had discarded. This alone makes the current behaviour indefensible to describe as a retention policy.

**Why now.** The repo already contains the exact shape of the answer: `qr_backend/src/utilities/webhook_dispatch.py` prunes the webhook delivery log using `min(workspace analytics_retention_days, RETENTION_DAYS_CAP=30)` (`:60`, `:550–575`). We have a working precedent for "resolve the workspace's retention, compute a cutoff, delete". We have a daily Worker cron already firing (`qr_cf_code/src/index.js`, `"0 6 * * *"` branch). What is missing is the sweep over the table that actually matters — and the safety engineering that the existing precedent conspicuously lacks (its delete is unbounded; see §11 R2).

## 3. Goals & Non-Goals

**Goals**
- **Hard-delete raw scan telemetry past its workspace's retention window**, daily, per workspace, resolved through the existing `get_limit(ws, db, "analytics_retention_days")` helper — never a second retention config.
- **Preserve every aggregate.** `qr_scan_counters` is never touched by the purge; lifetime scan totals, unique counts, and the device/country/date/hour maps are permanent.
- **Preserve billing-meter correctness.** The Free 2,000-scans/month cap counts *raw events* (see §11 R1) — enforcement must remain exact after a purge, with no bypass.
- **Make the destructive path safe to operate**: dry-run default, max-rows-per-run ceiling, per-workspace anomaly abort, per-run audit rows, and a purge that is batched, resumable, idempotent, and safe to run concurrently with scan ingestion.
- **Handle retention *reduction* humanely** — a 30-day grace window plus an owner notice before the first narrower purge, with a pointer to the existing analytics export.
- **Tell the truth on every surface**: pricing, billing, and the analytics header state that expired scan records are *deleted*, not hidden.

**Non-Goals**
- **No new plan flag, no new tier, no repricing.** The windows stay 7/30/90/365. *(If we later want retention as an upsell lever, that is a separate pricing decision.)*
- **No purging of lead submissions.** `qr_lead_submissions` holds captured business records the customer paid to collect — not telemetry. Deleting a Pro customer's leads at 90 days would destroy their deliverable. Lead retention is a **separate policy with its own PRD**. *(Explicit non-goal, §7.)*
- **No user-initiated erasure.** "Delete my account / delete this workspace's data now" is **ACCOUNT_DELETION_ERASURE**'s scope. This spec owns exactly one trigger: elapsed time. *(§12.)*
- **No archive/cold-storage tier.** A purge that writes the rows somewhere else is not a purge, and would re-introduce the false claim one layer down. Delete means delete.
- **No re-plumbing of `webhook_deliveries` pruning.** That sweep already exists and works (`webhook_dispatch.py:550`); we do not take ownership of it in v1. *(§12 open question.)*
- **No change to `login_events` / `alert_events` / audit trails.** Security logs have different retention drivers; **ORG_MFA_AUDIT_LOG** owns them.
- **No Worker/KV/edge behaviour change.** No new cron entry, no `wrangler.toml` edit, no scan-path change.
- **No backfill inside a single HTTP request.** The first catch-up purge is an operated, staged activity (§10), not one giant `DELETE`.

## 4. Target Users & Personas

| Persona | Who | Job-to-be-done | Today's pain |
|---|---|---|---|
| **Privacy-conscious buyer ("Nadia", DPO / IT at an SMB)** | Signs off on vendors; fills security questionnaires | Answer "how long do you keep visitor data?" truthfully | The honest answer today is "indefinitely, but we hide it" — which fails the questionnaire |
| **Free user ("Ravi")** | Sees "7 days of analytics" on the pricing page | Trust that his scans aren't stockpiled | His scan history from a year ago is intact on our disk, and would reappear if he ever paid |
| **Downgrading customer ("Priya", agency owner)** | Drops Pro→Free between client engagements | Come back in a month without losing everything | Would be the person most harmed if we purged 90→7 days the night of the downgrade |
| **Qravio operator (us)** | Runs the purge; owns the pager | Delete expired data without ever deleting live data | No delete path exists; the one delete precedent in the repo is unbounded |
| **Incident responder (us, worst day)** | Scopes a breach | Report the smallest honest number | Today the number is "every scan since launch" |

Primary beneficiary is **the company's ability to make a true claim**; the primary *risk-bearer* is **Priya**, which is why the grace period is a v1 requirement and not a follow-up.

## 5. User Stories

- As a **privacy-conscious buyer**, I want expired scan records actually deleted, so that "we retain N days" is a statement I can put in a security questionnaire.
- As a **Free user**, I want my scan telemetry gone after 7 days, so that upgrading later doesn't resurrect a year of my visitors' geo and device history.
- As a **workspace owner on any tier**, I want my **lifetime scan totals** to survive retention purges, so that the number on my dashboard doesn't drop overnight and my invoice/limits don't reset.
- As a **customer who downgrades**, I want a **grace period and a warning email** before my window narrows, so that a one-month downgrade doesn't irreversibly destroy 83 days of history I could have exported.
- As a **customer about to lose data**, I want the warning to link me to the **existing analytics export**, so that "act before it's gone" is a two-click action, not a support ticket.
- As an **operator**, I want the first release to run in **dry-run** and tell me exactly what it *would* delete, so that I can eyeball the volumes before a single row dies.
- As an **operator**, I want a run that wants to delete an anomalous amount for a workspace to **abort and page**, not proceed, because there is no undo.
- As an **operator**, I want each run to be **batched and resumable**, so that a large purge can't lock the hottest table in the product or blow the request timeout.
- As **billing**, I want the Free 2,000-scan cap to stay exactly enforceable after a purge, so that retention enforcement is not accidentally a way to get unlimited free scans.

## 6. UX / Product Flow

This feature is ~90% backend. Its user-visible surface is three copy changes and one email.

**6.1 Steady state (the common case) — invisible.**
Daily at 06:00 UTC the Worker's existing cron pings the backend; the backend purges each workspace's expired raw scan rows. Dashboards do not change: every number a customer sees today is either an all-time counter (unaffected) or already clamped to the retention window (so the underlying rows were already invisible). **A correct purge is a no-op from the UI's point of view.** That property is also our best regression test (§9).

**6.2 Truthful copy (three surfaces).**
1. **Pricing** (`PricingComparisonTable.tsx:42`, `PricingCards.tsx:296`): relabel "Analytics Retention" → **"Scan history kept"**, with a footnote: *"Individual scan records older than this are permanently deleted. Lifetime scan totals are kept forever."* The second sentence is the one that prevents support tickets.
2. **Billing** (`BillingPlans.tsx:284–288`): same phrasing on the plan feature list.
3. **Analytics header** (`AnalyticsHeader.tsx:29,52`): the range picker already bounds itself to the plan window; add an inline note — *"Your plan keeps N days of scan detail. Older records are deleted. Export before they expire."* linking to the shipped export (`GET /workspaces/{ws}/analytics/export`, `analytics_reports.py:282`).

**6.3 Retention-reduction notice (the one new email).**
When a workspace's resolved retention **drops** (downgrade, cancellation, expiry — any cause), the system:
1. Detects the reduction on the next daily run, records it, and sets a **30-day grace window**.
2. Continues purging at the **old, wider** window during the grace period — nothing is lost that wasn't already expiring.
3. Emails the workspace owner once: *"Your plan now keeps 7 days of scan history (was 90). We'll keep your existing history until <date> — export it any time before then."* with a direct export link. Sent via the existing Resend helper set (`qr_backend/src/utilities/email.py`).
4. After `grace_until`, the narrower window takes effect and the backlog purges under the same batching/ceiling rules as any other run.

**6.4 Settings read-out (optional, v1.1).**
A "Data retention" row in workspace settings: current window, next purge date, last purge timestamp, and an export button. Nice-to-have; not a GA gate.

**6.5 Operator flow (not customer-facing).**
Dry-run → read the per-workspace projected counts from the run log → tune ceilings → flip to live for an internal cohort → staged backfill → global live. Detailed in §10.

## 7. Scope

**In scope (v1)**
- Daily per-workspace hard delete of **`qr_scan_events`** rows older than `now() - analytics_retention_days`, resolved via `get_limit`.
- Daily per-workspace hard delete of **`qr_link_click_events`** (migration `0016`) on the same window — same telemetry class, same retention semantics; lifetime click totals survive in `qr_link_items.click_count`.
- **Aggregate preservation**: `qr_scan_counters` untouched, by construction and by test.
- **Billing-meter preservation**: a purge ledger so the Free `max_scans` window count stays exact after rows are deleted (§11 R1).
- **Safety rails, all v1**: `RETENTION_DRY_RUN` (default on at first deploy), global + per-workspace max-rows-per-run ceilings, per-workspace anomaly abort, fail-closed handling of `-1`/`0`/missing/unreadable retention values (fail-closed here means **do not delete**).
- **Retention-reduction grace**: 30 days, self-detected, with one owner notice email.
- **Per-run audit rows** (workspace, window, cutoff, rows deleted per table, duration, mode, outcome) as the observability and forensics surface.
- **Batched, resumable, concurrency-safe deletes** with an explicit row limit per statement.
- Copy corrections on pricing / billing / analytics header, and the corrected `FEATURE_ENFORCEMENT` comment.
- Worker: add the purge ping to the **existing** daily cron branch. No new cron, no `wrangler.toml` change.

**Out of scope / Future**
- `qr_lead_submissions` retention *(explicit non-goal — customer deliverable, separate policy + PRD)*.
- User-initiated deletion of an account/workspace's data on demand *(**ACCOUNT_DELETION_ERASURE**)*.
- Customer-configurable retention (e.g. "delete after 3 days even though my plan allows 90") *(future; a real enterprise ask, needs its own flag)*.
- Per-QR or per-region retention overrides *(future)*.
- Cold-storage archive / customer-requested full data export bundle *(future; the per-report export already exists)*.
- Taking over `webhook_deliveries` pruning from `webhook_dispatch.py` *(§12)*.
- Fixing the daily cron's `/internal/reclamation-sweep` 404 *(pre-existing, unrelated, tracked separately — see §12)*.
- Purging `login_events` / `alert_events` *(ORG_MFA_AUDIT_LOG)*.

## 8. Pricing & Packaging

**No packaging change.** Retention is already tier-differentiated and already sold:

| Tier | `analytics_retention_days` | Source |
|---|---|---|
| Free | `7` | `migrations/0009_pricing_v3_4tier_collapse.sql:98` |
| Starter | `30` | `:101` |
| Pro | `90` | `:104` |
| Agency | `365` | `:107` |
| Custom / legacy | any value; `-1` = unlimited | `is_custom` plan rows; `-1` handled at `scan.py:237–238` |

- **No new flag, no seed migration for flags, no `FEATURE_ENFORCEMENT` entry.** `analytics_retention_days` is already registered `"enforced"` (`subscription.py:539`) and already carries a `_QUOTA_SPEC` entry (`:442–445`, `usage: None`, "day-window cap; caller clamps"). `test_feature_gate_coverage` is unaffected — the only edit to `subscription.py` is the **comment** on line 539, which currently misdescribes the flag as a clamp and references a function name that does not exist in the codebase.
- **`-1` (unlimited) must never purge.** Not offered on any public tier today, but reachable on custom plans and on legacy `0005`-era rows (which seeded values up to `730`). Explicit skip, explicit test.
- **`0` / missing must never purge either** — and this is the sharp edge. `_limit_value` fail-closes a **missing** key to `0` (`subscription.py:457–472`), which is correct for a *quota* (deny) and catastrophic for a *retention window* (`now() - 0 days` deletes everything). The purge inverts the usual fail-closed direction: **any retention value we cannot confidently resolve as a positive integer means keep the data**.
- **Does retention become a stronger upsell once it's real?** Probably — "we actually delete it" makes the 7→365 ladder mean something. That is a pricing conversation for after this ships, deliberately not bundled here.

## 9. Success Metrics & KPIs

**Correctness (release gates — these are the ones that matter)**
- **0 rows deleted inside any workspace's retention window.** Measured by a post-run assertion: for every workspace, `MIN(scanned_at)` in `qr_scan_events` ≥ its effective cutoff, and no row younger than the cutoff is missing. Any violation is a Sev-1.
- **0 change to `qr_scan_counters`** across the first live run (`total_scans` / `unique_scans` byte-identical before and after, sampled across ≥100 workspaces).
- **Dashboard invariance**: every analytics endpoint returns identical payloads pre- and post-purge for a fixture workspace, because the purged rows were already outside the clamp. A diff here means the clamp and the purge disagree — a bug in one of them.
- **Billing-meter exactness**: for a seeded Free workspace, the scan cap fires at exactly 2,000 in a month in which a purge ran mid-month (§11 R1).

**Operational**
- **p95 purge run duration** under the backend request timeout, every day, at steady state (target: seconds, since a steady-state day deletes one day of expiry).
- **0 runs aborted by the anomaly guard** after the backfill completes (an abort at steady state means something changed upstream — treat as a page, not noise).
- **`qr_scan_events` row count plateaus** rather than growing monotonically, within 30 days of global live.
- **0 unbounded statements**: every delete in the path carries an explicit limit (enforced by code review + a test that asserts the RPC signature takes a limit).

**Trust**
- **Retention claim is defensible**: pricing/billing/analytics copy states deletion; a security questionnaire can be answered with a number and a mechanism.
- **≤ 1 support ticket per 1,000 workspaces** citing "my old data disappeared" in the 30 days after global live (the grace email + copy changes are what buy this).
- **100% of retention-reduction events** produce exactly one owner notice before the narrower window takes effect (no double-sends, no silent narrowing).

## 10. Rollout Plan

Every phase is gated on the previous one producing *evidence*, not just deploying.

**Phase 0 — Schema + purge engine, dry-run only (internal).**
- Apply the migration (audit-run table, purge ledger, purge RPC, grace/state table).
- Deploy the backend `/internal/retention-purge` endpoint and utility. `RETENTION_DRY_RUN` defaults **true**; the endpoint counts and records what it *would* delete, and deletes nothing.
- Wire the Worker ping into the existing `"0 6 * * *"` branch and deploy the Worker. **No `wrangler.toml` change** → no new cron to register → **`npm run deploy:prod` is a code deploy, not a cron-registration gate.**
- **Exit gate:** ≥ 7 consecutive dry runs; read the per-workspace projected counts out of the run log; confirm the totals are plausible; confirm no workspace projects a delete inside its window; tune the ceilings to the observed distribution.

**Phase 1 — Live on an internal cohort.**
- Flip `RETENTION_DRY_RUN=false` for an allowlist of internal/test workspaces only (`RETENTION_LIVE_WORKSPACE_IDS`).
- **Acceptance:** rows outside the window are gone; rows inside are intact; `qr_scan_counters` unchanged; every analytics endpoint returns the same payload as before the purge; the Free scan cap still fires at exactly 2,000 for a seeded Free workspace whose events were mid-month-purged; run rows show sane durations and counts; a deliberately-poisoned anomalous workspace **aborts instead of deleting**.

**Phase 2 — Copy + notice, then staged backfill.**
- Ship the pricing/billing/analytics copy changes and the retention-reduction notice email.
- **Backfill is operated, not requested.** The first purge for a workspace with years of history is large. Run it in staged passes governed by the per-run ceiling — the sweep is resumable by construction, so "today's run deletes up to N rows, tomorrow's continues" is the intended mechanism. For the largest workspaces, run the catch-up by hand in the Supabase SQL editor in bounded batches during a low-traffic window, exactly like every other migration in this repo is applied.
- **Exit gate:** backfill complete, table size trending down, zero correctness violations.

**Phase 3 — Global live.**
- Remove the allowlist; `RETENTION_DRY_RUN=false` globally.
- **GA gates:** (a) 30 consecutive clean runs on the internal cohort; (b) backfill complete; (c) the anomaly guard demonstrated to abort on a synthetic anomaly; (d) grace-period path verified end-to-end with a real downgrade in staging; (e) the copy changes are live *before* the first customer-facing purge, not after.

**Cross-service gates:**
- **Worker deploy required** (`npm run deploy:prod`) — code change to `scheduled()`, but **no new cron trigger**, so no trigger-registration lag.
- **Email gate:** the retention-reduction notice is a new outbound email. Per the standing house note, `_dmarc.qravio.app` is not published; if that remains true, ship Phase 2 with the notice **surfaced in-app only** and hold the email until DMARC lands. The grace period itself is not blocked by this — only the email is.
- **Migration must be applied before the endpoint deploys** (the endpoint calls the purge RPC).

## 11. Risks, Edge Cases & Open Questions

**R1 — The Free billing meter counts raw events, so a naive purge silently disables the scan cap. (Verified; highest-severity technical risk.)**
`_enforce_scan_limit` counts `qr_scan_events` for the current period (`internal.py:551–558`), and so does `_reenable_free_scan_disabled` (`:670–677`). Free's cap is `max_scans = 2000` per **calendar month** (`0009_pricing_v3_4tier_collapse.sql:29`; `period_start_iso`, `subscription.py:332+`); all paid tiers are `-1` and return early. Free's retention is **7 days**. So a purge at 7 days means that on the 20th of the month the cap only ever sees the last 7 days of scans — **the 2,000/month cap becomes unreachable and Free effectively gets unlimited scans.**
**Mitigation (v1 requirement):** the purge writes a **ledger** of how many rows it deleted per `(workspace_id, calendar month)` *before* deleting them, and the two enforcement call sites add the ledger value for the current period to their live count. Exact, cheap (one indexed read), and only consulted on the path where it is provably correct (finite `max_scans` ⇒ Free ⇒ calendar-month window). The lower-effort alternative — floor the purge cutoff at the current period start — is correct but retains up to 31 days for a 7-day plan, i.e. it re-weakens the very claim we're fixing. **Recommend the ledger.**

**R2 — The only delete precedent in the repo is unbounded; copying it would be the bug.**
`webhook_dispatch.sweep()` (`:516–547`) selects every due row with no `LIMIT` (`:525–531`), and `_prune_old_deliveries` (`:550–575`) issues `.delete().lt("created_at", cutoff)` with no bound (`:556`, `:573`) while iterating every workspace that has an endpoint. On `webhook_deliveries` that is survivable. On `qr_scan_events` — the hottest, largest table in the product — an unbounded delete would take a long-lived lock, blow the request timeout, and back up scan ingestion at the edge.
**Mitigation:** every delete in this feature carries an explicit row limit; runs are resumable; a per-run ceiling bounds total work; batches are ordered oldest-first so progress is monotonic. We mirror the *shape* of the webhook sweep (resolve retention per workspace, compute cutoff, delete) and explicitly **not** its unboundedness.

**R3 — A bug here destroys customer data with no undo. (The defining risk.)**
**Mitigation, all v1:** (a) `RETENTION_DRY_RUN` ships **on** and the first release deletes nothing; (b) a global and a per-workspace max-rows-per-run ceiling; (c) a **per-workspace anomaly guard** — if a run projects a delete far larger than that workspace's recent purge history, it **skips the workspace, records an aborted run, and logs loudly** rather than proceeding; (d) an internal-cohort allowlist before global live; (e) every run writes an audit row, so "what did we delete and when" is answerable after the fact.

**R4 — Fail-closed points the wrong way for a retention value.**
`_limit_value` returns `0` for a missing key (`subscription.py:457–472`), and `get_limit` can raise if `resolve_plan` fails. For every other quota, "0" means deny — safe. Here, `0` naively means `cutoff = now()`, i.e. **delete everything**.
**Mitigation:** the purge treats `-1`, `0`, `None`, a non-positive value, and any exception from `get_limit` as **"skip this workspace entirely"**. Only a positive integer produces a cutoff. Dedicated tests for each.

**R5 — Downgrade is the sharpest customer-facing edge, and it fans out across workspaces.**
Billing is owner-scoped: `resolve_plan` resolves from the most generous active subscription across **every workspace the owner holds** (`subscription.py:283–329`), and `_invalidate_plan_cache` evicts the whole owner set on a change (`:212–234`). So one Pro→Free downgrade narrows retention from 90 to 7 days for *every* workspace that owner controls, simultaneously. Without a grace period, the next 06:00 run destroys 83 days of history across all of them, with no warning and no undo.
**Mitigation / decision:** a **30-day grace period**, self-detected. The sweep records each workspace's last-seen retention; when the resolved value is *lower* than the recorded one, it stamps the reduction, sets `grace_until = now() + 30 days`, sends the owner notice, and **purges at the old, wider window until the grace expires**. Detecting the reduction *observationally* — rather than hooking the billing paths — means it cannot be missed by a code path we forgot (Razorpay downgrade, LemonSqueezy, cancellation, expiry, subscription-row deletion, owner-scoped side effects all behave identically). 30 days is chosen to cover one full billing cycle: a customer who downgrades for a single month and re-upgrades loses nothing. This also matches the house posture on downgrades — `_lock_excess_qrs` (`razorpay_routes.py:1225–1266`) **locks** excess QRs rather than deleting them, and its own note (`:1238`) flags a grace window as the missing piece. We are not inventing a policy; we are applying the existing one to data.

**R6 — Purging concurrently with ingestion.**
Scans are written continuously (`internal.py:393`) while the sweep deletes. **Mitigation:** the cutoff is a fixed instant computed once per workspace per run, and ingestion only ever writes `scanned_at ≈ now()`, so a newly-inserted row can never enter an in-flight delete set. Deletes are by primary key from a bounded, oldest-first selection. Two concurrent runs (a cron retry) cannot double-delete a row and cannot corrupt the ledger, because the ledger is written from the rows actually deleted, not from a pre-count.

**R7 — Aggregate/raw drift after purge.**
Some analytics read raw events and some read counters. Campaign rollups deliberately read **raw** `qr_scan_events`, never counters (`scan.py:1562–1564`), as does the review funnel (`0022_google_review_funnel.sql:27–28`) and the conversion funnel (`scan.py:1414–1425`). Those are all retention-clamped already, so purged rows were already invisible to them — but the invariant must be stated and tested: **the purge cutoff must never be tighter than the clamp cutoff.** If they ever diverge, a customer sees a window that returns fewer rows than promised. Same helper, same limit, same direction — enforced by test.

**R8 — Storage reclamation is not automatic.** Postgres `DELETE` marks rows dead; space returns to the table's free list on autovacuum, and to the OS only on a rewrite. The row-count and breach-blast-radius goals are met immediately; the *disk-cost* goal lags. **Mitigation:** expect autovacuum to keep up at steady state; treat the post-backfill one-time bloat as an operational item (monitor, and consider a maintenance-window rewrite) rather than a feature requirement. Do not promise an immediate storage-cost drop.

**R9 — Deleting a customer's data is exactly what a compromised internal path would do.** `/internal/*` bypasses Bearer auth and is protected only by the `x-internal-secret` header (`internal.py:21`). This endpoint is the most destructive thing behind that header. **Mitigation:** the ceilings and the anomaly guard bound the damage of *any* caller, authorized or not; the endpoint takes no workspace/cutoff/window parameters from the request body (everything is resolved server-side from plans), so it cannot be steered into deleting a specific customer or an arbitrary window.

**Open Questions**
1. **Grace period length — 30 days?** *Recommend 30: one full billing cycle, so a one-month downgrade is fully reversible. 7 is too short to act on an email; 90 makes the retention claim mushy for a third of a year.*
2. **Purge `qr_lead_submissions` too?** *Recommend no, firmly. Leads are a paid deliverable, not telemetry. Separate policy, separate PRD, probably a customer-configurable setting.*
3. **Ledger vs. cutoff-floor for the Free meter (R1)?** *Recommend the ledger — exact, and it doesn't quietly retain 31 days on a 7-day plan.*
4. **Advance notice before the very first steady-state purge?** *Recommend: no per-workspace email for steady state (a Free user's day-8 data expiring daily is the advertised product, and a daily "we deleted things" email is noise), but ship the copy changes **before** the first live purge and send one product-wide announcement at Phase 3. Per-workspace email is reserved for the retention-**reduction** case, where the customer genuinely loses something they had.*
5. **Should the retention window be measured from `scanned_at` or from row insert time?** *Recommend `scanned_at` — it is what the read clamp uses (`scan.py:242–248`), and using anything else guarantees clamp/purge divergence (R7).*
6. **Do we need a per-QR opt-out for regulated customers who must retain longer?** *Recommend no in v1; the custom-plan `-1` path already covers "retain everything" for an enterprise deal.*

## 12. Dependencies

- **Limits engine (shipped, hard dependency):** `get_limit` / `_limit_value` / `resolve_plan` / `period_start_iso` in `qr_backend/src/api/routes/subscription.py`. The purge **must** resolve retention through `get_limit(ws, db, "analytics_retention_days")` — the same call the clamp makes (`scan.py:236`). No second source of truth.
- **Scan ingestion + counters (shipped):** `internal.py record_scan_event` (`:350–356`), the `qr_scan_events` insert (`:393`), and the `qr_scan_counters` update (`:396–462`) — the boundary between what gets purged and what is preserved.
- **Scan-limit enforcement (shipped, must be modified):** `_enforce_scan_limit` (`internal.py:532–616`) and `_reenable_free_scan_disabled` (`:618–715`) both count raw events for the current period and must read the purge ledger (R1).
- **Indexes (shipped):** `idx_qr_scan_events_workspace_scanned` on `(workspace_id, scanned_at)` (`migrations/0007_billing_foundations.sql:45–46`) is exactly the access path the purge needs — no new index required for the primary table.
- **Deletion precedent (shipped, mirror the shape, not the unboundedness):** `qr_backend/src/utilities/webhook_dispatch.py` — `RETENTION_DAYS_CAP` (`:60`), `sweep()` (`:516`), `_prune_old_deliveries()` (`:550–575`).
- **Internal cron plumbing (shipped):** `qr_cf_code/src/index.js` `scheduled()` dispatch by `event.cron`; the daily `"0 6 * * *"` branch already exists, and `wrangler.toml:52–53` already registers it. `verify_internal_secret` (`internal.py:21`) and the `webhook_sweep` endpoint (`:1117–1140`) are the pattern to copy.
- **Export surface (shipped):** `GET /workspaces/{ws}/analytics/export` (`analytics_reports.py:282`) + `report_export.py` — what the retention-reduction notice links to. Without a working export, "we're about to delete your history" is a cruel email.
- **Email (shipped, gated):** `qr_backend/src/utilities/email.py` (Resend). The retention-reduction notice is a **new** outbound email → subject to the standing `_dmarc.qravio.app` publication gate (§10).
- **ACCOUNT_DELETION_ERASURE (concurrent draft — boundary must stay crisp):** that spec owns *user-initiated* erasure (delete my account / my workspace / my data on request, including cascades across every table). This spec owns *time-based automatic* purge of two telemetry tables. **Neither may implement the other's delete path.** Concretely: account deletion must not grow a "purge expired analytics" branch, and this sweep must not grow a "delete everything for this workspace" branch. If both need to delete `qr_scan_events`, the shared primitive is the bounded purge RPC defined here, called with different windows — one owner, two callers. Coordinate the migration slots (this spec provisionally takes the slot *after* theirs) and re-verify both against `qr_backend/migrations/` at build time.
- **No dependency on:** KV, `build_kv_content`, `build_entitlements`, any QR type, any scan-page template, Razorpay/LemonSqueezy webhooks, Anthropic, or any new plan flag.

### Appendix — Key Files

| Concern | File |
|---|---|
| Retention limit — the single source of truth | `qr_backend/src/api/routes/subscription.py` (`get_limit` `:474–480`, `_limit_value` `:457`, `_QUOTA_SPEC['analytics_retention_days']` `:442–445`, `FEATURE_ENFORCEMENT` `:539` — comment needs correcting) |
| Read clamp (must stay in lockstep with the purge) | `qr_backend/src/api/routes/scan.py` (`_retention_days` `:234–239`, `_retention_cutoff_iso` `:242–248`, plus `:390`, `:549`, `:738`, `:929`, `:1414`, `:1629`) |
| Read clamp — other call sites | `qr_backend/src/api/routes/reports.py:211–212`; `qr_backend/src/api/routes/analytics_reports.py:302` |
| Raw tables to purge | `qr_scan_events` (written `internal.py:393`), `qr_link_click_events` (`migrations/0016_scan_conversion_funnel.sql:34–45`) |
| Aggregate table — never purged | `qr_scan_counters` (written `internal.py:396–462`) |
| Billing meter that reads raw events (R1) | `qr_backend/src/api/routes/internal.py` (`_enforce_scan_limit` `:532–616`, count at `:551–558`; `_reenable_free_scan_disabled` `:618–715`, count at `:670–677`) |
| Owner-scoped plan resolution (downgrade fan-out, R5) | `qr_backend/src/api/routes/subscription.py` (`resolve_plan` `:283–329`, `_invalidate_plan_cache` `:212–234`) |
| Downgrade precedent — lock, never delete | `qr_backend/src/api/routes/razorpay_routes.py:1225–1266` (note at `:1238`) |
| Delete precedent to mirror (and to bound) | `qr_backend/src/utilities/webhook_dispatch.py` (`:60`, `:516–547`, `:550–575`) |
| Purge engine + endpoint (new) | `qr_backend/src/utilities/retention.py`, `qr_backend/src/api/routes/internal.py` (`POST /internal/retention-purge`) |
| Migration (provisional slot — re-verify) | `qr_backend/migrations/0045_data_retention_enforcement.sql` |
| Index the purge rides | `qr_backend/migrations/0007_billing_foundations.sql:45–46` |
| Plan retention seed values | `qr_backend/migrations/0009_pricing_v3_4tier_collapse.sql:98,101,104,107` (and `max_scans` at `:29`) |
| Cron | `qr_cf_code/src/index.js` `scheduled()` daily `"0 6 * * *"` branch; `qr_cf_code/wrangler.toml:52–53` (**unchanged**) |
| Export the notice links to | `qr_backend/src/api/routes/analytics_reports.py:282`, `qr_backend/src/utilities/report_export.py` |
| Notice email | `qr_backend/src/utilities/email.py` |
| Customer-facing copy | `qr_frontend/src/components/pricing/PricingComparisonTable.tsx:42`, `PricingCards.tsx:296`, `qr_frontend/src/components/org/billing/BillingPlans.tsx:284–288`, `qr_frontend/src/components/org/analytics/AnalyticsHeader.tsx:29,52` |
