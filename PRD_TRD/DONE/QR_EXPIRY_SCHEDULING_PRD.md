# PRD — QR Expiry + Campaign Scheduling

**Status:** Draft · **Author:** Product · **Date:** 2026-07-25
**Priority:** Table-stakes parity gap. Every serious competitor (Beaconstac, Bitly, QR Tiger, QRCodeChimp, Scanova) ships an expiry date and/or a scheduled active window; Qravio does not, and it reads as a missing checkbox in head-to-head SMB comparisons. Close the gap; don't over-build.
**Tiers:** **All plans, ungated (v1 recommendation).** Zero per-use COGS and a pure comparison-table checkbox — consistent with the house's "open all QR types" (`0027`) / "folders all plans" (`0028`) posture. An optional `qr_scheduling` Starter+ upsell flag is the alternative (see §8 / §11 Open Q1).
**Plan flags:** **None in v1** (ungated). If product elects the upsell path: `qr_scheduling` (bool, NEW), registered `inert`→`enforced` in the same PR (house convention; `test_feature_gate_coverage` stays green).
**Split from:** the dynamic-QR lifecycle (`qr_codes.status` state machine in `qr.py`). Reuses the Worker system-page pattern (`scanLimitPage.js` / `disabledPage.js`) and the KV-snapshot path (`sync_qr_to_kv`). **Not** the routing-rules "time" dimension (recurring daily/weekly windows — a different feature) and **not** scan-limit (count-based, already shipped).

**Rev (2026-07-25, post eng-review):** Reviewed via `/plan-eng-review` + an independent outside-voice pass. Decisions: (1) **Ungated, all plans — confirmed** (columns-only gating; no `qr_scheduling` flag in v1). (2) **event/coupon display dates kept independent** from the enforced window, disambiguated by builder copy — no data migration, no behavior change to shipped QRs. (3) **Timezone: author-zone, not IST.** Collect in the author's browser timezone (`Intl`), **store the authoring IANA zone** (`schedule_tz`) alongside the UTC instants, and always render the window in the zone it was set in (labeled) — so a window authored as "11:59 PM" never shows a shifted wall-clock to a viewer in another zone. **Every "IST" reference below is superseded by this.** (4) **Blocked scans are RECORDED** (owner sees "still being scanned → consider extending"), but to a **separate counter that `_enforce_scan_limit` and normal analytics never read** — a scanned expired QR must never count toward the billable scan cap nor auto-disable the workspace's *other* live QRs (the critical landmine the review caught). Load-bearing correctness fixes now in the TRD: normalize both DB→KV timestamp write paths to a strict `…Z` string in Python (a raw PostgREST string can be `Date.parse`→`NaN` in V8 → silent never-expire under fail-open); populate the window into KV **only via `sync_qr_to_kv`** (three direct `write_to_kv` callers exist — a missed one silently strips the window); pin the Worker window-check to a single location (after the status branches, before the website early-return and the password gate) so expired **website** QRs are covered; keep fail-open but emit a **loud Worker error log** on an unparseable `end_at`.

---

## 1. TL;DR / Summary

A user building or editing a **dynamic** QR can set an optional **go-live time** (`start_at`) and/or an
optional **expiry time** (`end_at`). Outside that window the **Cloudflare Worker decides at the edge** what
to serve: before `start_at` → a "not yet live / scheduled" page; after `end_at` → an "expired" page; inside
the window (or when no window is set) → the QR behaves exactly as today. Times are **entered in the
author's own browser timezone**, the **authoring timezone is stored** (`schedule_tz`), and the window is
**always displayed in the zone it was set in** and **stored/enforced in UTC** — so a window authored as
"11:59 PM" never shows a shifted wall-clock to a viewer in a different zone.

The whole feature is: two nullable timestamp columns on `qr_codes`, those two values snapshotted into the
KV payload, one time-window check in the Worker beside the existing status branches, one new Worker system
page, and date-time inputs in the builder (create **and** edit). The dashboard derives a **Scheduled /
Active / Expired** badge from the columns.

**Deliberately boring.** The edge enforces the window directly from the KV-written timestamps — there is
**no new `qr_codes.status` value**, **no cron**, and **no state-machine change**. This sidesteps the
combinatorial risk of adding `scheduled`/`expired` to an already-overloaded status enum, and it guarantees a
printed QR stops the **instant** it expires rather than minutes-to-hours later when a sweep runs.

## 2. Problem & Motivation

**We lose the checkbox.** Time-boxed campaigns are the single most common reason an SMB wants control over a
QR's lifetime: an event badge that should only work during the event, a flash-sale poster that must die when
the sale ends, a seasonal menu insert, an agency client campaign with a contractual end date. Beaconstac,
Bitly, QR Tiger, QRCodeChimp, and Scanova all ship this. In a side-by-side comparison Qravio shows a blank
cell, and the buyer assumes we're less mature.

**What we have doesn't cover it.** Today a QR's lifetime is controlled by:
- **Manual `active`/`paused`** — the owner must remember to flip it; a printed poster keeps redirecting until
  someone notices. Not a *scheduled* stop.
- **Scan-limit auto-disable** — count-based (`status='disabled'` when the monthly scan cap is hit), not
  date-based.
- **Decorative `start_date`/`end_date` on `event`, `valid_from`/`valid_until` on `coupon`** — these are
  **display-only** (rendered on the landing page, even a client-side "offer ended" countdown in
  `coupon/flashTemplate.js`) and **never enforce anything at the edge**. The QR still redirects after the
  printed end date.
- **Routing-rules "time" dimension** — recurring daily/weekly windows for *which destination* to serve, not
  a one-shot campaign go-live/expiry that *disables* the QR.

None of these disable a QR **by date**. That's the gap.

**It's cheap and self-contained.** Two columns, a KV field, an edge check, a system page, and a builder
input. No AI, no new external service, no per-use cost. The only real engineering care is timezone
correctness (IST↔UTC) and enforcing at the edge (not via a lagging cron).

## 3. Goals & Non-Goals

**Goals**
- Let a user set an optional **`start_at`** (go-live) and/or **`end_at`** (expiry) on any **dynamic** QR, at
  create **and** edit time.
- **Enforce at the edge**: before `start_at` → scheduled page; after `end_at` → expired page; both return a
  branded system page and record **no scan** (mirrors how scan-limit blocks before `recordScan`).
- **Author-timezone UX, UTC storage**: collect in the author's browser timezone, **store the authoring IANA
  zone** (`schedule_tz`) alongside the UTC instants, and always render the window in the zone it was set in.
  Store/compare in UTC. No naive "server local time" and no viewer-dependent wall-clock anywhere.
- **Derive display state** (Scheduled / Active / Expired) in the dashboard QR list from the columns — no
  extra status column, no cron.
- Ship the parity checkbox without regressing any existing `status` transition (paused/disabled/locked).

**Non-Goals**
- **No new `qr_codes.status` value** (`scheduled`/`expired`) and **no status-machine change.** The window is
  evaluated at the edge and derived for display; `status` stays exactly the five values it is today.
- **No cron / background sweep in v1.** The edge is the enforcement point; the dashboard derives state from
  the columns. *(A future "your QR expired" email would add one — out of scope here.)*
- **No static-QR expiry.** Static QRs encode their target directly in the QR pixels and never hit the Worker,
  so they physically cannot be expired at the edge. Scheduling is a **dynamic-only** capability (state it
  plainly in-product; offer "convert to dynamic" as the path). *(This is also a clean static→dynamic
  upsell.)*
- **No recurring / time-of-day windows** — that's the routing-rules "time" dimension, a separate feature.
- **No per-destination / per-A/B-variant windows** in v1 (the window is a property of the QR, not a variant).
- **No auto-delete of expired QRs** — expired means "stops redirecting", not "deleted". Data and analytics
  are retained; the owner can extend/clear the window to revive it.

## 4. Target Users & Personas

| Persona | Who | Job-to-be-done | Today's pain |
|---|---|---|---|
| **Event Organizer ("Ravi")** | Runs conferences/expos | A badge/signage QR that only works **during** the event window | Must manually pause after the event or it redirects forever |
| **Retail Promo Manager ("Meera")** | SMB running a flash sale | A poster QR that **auto-dies** the minute the sale ends | Stale offer keeps redirecting; embarrassing + off-brand |
| **Print-Campaign Owner ("Sana")** | Prints posters/flyers with a fixed run | A hard **end date** baked in before print, set-and-forget | No way to schedule; relies on remembering to disable |
| **Agency Account Manager ("Amit")** | Manages client campaigns | Client-contracted **start and end** dates per campaign QR | Manual lifecycle bookkeeping across many client QRs |

Primary buyer is the **campaign-running SMB/agency** for whom "set it and forget it" scheduling is the point.

## 5. User Stories

- As an **event organizer**, I want my badge QR to go live at the event start and stop at the end, so that it
  can't be scanned before or after the event.
- As a **promo manager**, I want a flash-sale QR to expire automatically at a date/time I pick, so that a
  dead offer never redirects a customer.
- As a **print-campaign owner**, I want to set an end date before I send the poster to print, so that the QR
  self-retires without me touching the dashboard again.
- As **any user**, I want to enter times in **IST** (the timezone I think in) and trust they're enforced
  correctly, so that my QR doesn't expire 5.5 hours early or late.
- As a **scanner** who scans a not-yet-live or expired QR, I want a clear, branded "not available" page (not
  a broken redirect or error), so that I understand the QR isn't active right now.
- As an **agency manager**, I want to see at a glance which client QRs are Scheduled, Active, or Expired, so
  that I can manage campaign lifecycles across a large list.
- As a **static-QR user**, I want to be told plainly that scheduling needs a dynamic QR (and offered the
  switch), so that I'm not surprised my static code ignores the window.

## 6. UX / Product Flow

**6.1 Setting a window — builder (create + edit)**
1. In the QR builder, a new **"Schedule"** section (collapsed by default) exposes two optional controls:
   **"Go live"** (`start_at`) and **"Expires"** (`end_at`), each a shadcn date-time picker. Empty = no bound
   on that side (no start = live immediately; no end = never expires).
2. The picker label states the timezone explicitly (**"Times are in IST"**); values are converted to UTC on
   submit. Validation (zod): if both set, `end_at` must be after `start_at`; an `end_at` in the past is
   allowed on **edit** (immediately expires the QR — a legitimate "kill it now" action) but warns on create.
3. For a **static** QR the Schedule section is replaced by an inline note: "Scheduling requires a dynamic QR —
   convert to dynamic to use it," linking to the convert flow. (Dynamic-only, per §3.)

**6.2 Dashboard — derived lifecycle state**
- The QR list/detail shows a **Scheduled** (now < `start_at`), **Active** (in window / no window), or
  **Expired** (now > `end_at`) badge, computed client-side from the columns alongside the existing
  Paused/Disabled/Locked chips. A Scheduled/Expired row shows the relevant date inline ("Live from 5 Aug,
  9:00 AM IST" / "Expired 31 Jul, 11:59 PM IST").
- Editing the window (extend/clear) revives or re-schedules the QR; the change propagates to the edge on save.

**6.3 Scanner experience (the edge)**
- **Before `start_at`:** a branded **"This QR code isn't active yet"** system page (amber, mirrors
  `getPausedPage`), optionally naming the go-live date. No redirect.
- **After `end_at`:** a branded **"This QR code has expired"** system page (red, mirrors `getDisabledPage`),
  no redirect.
- **Blocked scans are recorded** (both states) to a **separate blocked-scan counter** so the owner sees
  "people are still scanning this — consider extending it." Critically, blocked scans are **excluded from the
  billable scan cap and from normal analytics** — they must never count toward the monthly scan limit or
  trip the scan-cap auto-disable of the workspace's *other* live QRs.
- **Inside the window / no window:** unchanged — normal redirect or landing page.
- These pages honor **white-label / brand** entitlements exactly like the other system pages (they already
  take `{ whiteLabel, brand }`).

**6.4 Interaction with existing states (precedence)**
- `paused` / `disabled` (scan-cap) / `locked` (downgrade) take **precedence** over the schedule window (an
  owner-paused or plan-locked QR shows its existing page regardless of the window). The window check runs
  **after** the status branches and **before** the password gate. (Spelled out in the TRD.)

## 7. Scope

**In scope (v1)**
- `start_at` + `end_at` (nullable `timestamptz`, UTC) + `schedule_tz` (authoring IANA zone) on **dynamic**
  `qr_codes`; set at create + edit.
- KV snapshot of both timestamps; edge window enforcement + one new Worker system page (two visual states:
  not-yet-live / expired).
- Builder Schedule section (author-timezone pickers, UTC storage, zod window validation) on create + edit;
  static-QR inline note.
- Dashboard derived Scheduled/Active/Expired badge + inline date (rendered in the authoring zone).
- **Blocked-scan recording** to a separate, non-billable counter + an owner-facing "still being scanned"
  read-out; excluded from `_enforce_scan_limit` and normal analytics.
- **Ungated, all plans** (confirmed post eng-review). Columns-only gating; no new plan flag.

**Out of scope / Future**
- Static-QR expiry *(impossible at the edge; offer convert-to-dynamic)*.
- `scheduled`/`expired` `qr_codes.status` values or any status-machine change *(deliberately avoided)*.
- Background cron to flip state / send "expired" notifications *(future; would add the first cron for this
  feature)*.
- Recurring / time-of-day windows *(routing-rules "time" dimension — separate feature)*.
- Per-destination / per-A/B-variant windows *(future)*.
- Unifying the decorative `event`/`coupon` display dates with the enforced window *(future cleanup; v1 leaves
  them independent — see §11 R5)*.
- Bulk "set expiry on N selected QRs" *(future; v1 is per-QR)*.

## 8. Pricing & Packaging

| Surface | Tier (v1 recommendation) | Flag / Limit |
|---|---|---|
| QR expiry + scheduling window | **All plans (Free, Starter, Pro, Agency)** | **None** (ungated) |

**Why ungated (recommended):** it's a **table-stakes parity checkbox with zero per-use cost**. The strategic
goal is to *stop losing the comparison*, which gating undercuts (a gated checkbox still reads as "not
included" to a Free-trial evaluator). It's also consistent with the recent house moves to open QR types
(`0027`) and folders (`0028`) to all plans, and it keeps the migration to **columns only** (no flag seed, no
`FEATURE_ENFORCEMENT` entry, no coverage-test surface).

**The upsell alternative (Open Q1):** if product wants scheduling as a paid "campaign" capability (several
competitors gate it), add a single `qr_scheduling` bool flag at **Starter+**, seeded as a full-object
`'{...}'::jsonb` blob and registered `inert`→`enforced` in the same PR. This is a clean, reversible
product call — but it's a *product* decision, not a technical necessity. **Recommendation: ship ungated in
v1**, revisit gating only if scheduling proves to be a strong upgrade driver.

## 9. Success Metrics & KPIs

**Adoption**
- ≥ 10% of **newly created dynamic** QRs set at least one window bound within 60 days of GA (proves the
  feature is discoverable and wanted).
- Competitive checkbox closed: "QR expiry / scheduling" flips from ✗ to ✓ in the comparison matrix and
  `/beaconstac-alternative` SEO page.

**Trust / correctness (the bar that matters)**
- **Zero false-expiry incidents**: no QR serves the expired/scheduled page while genuinely inside its window
  (the failure mode that erodes trust fastest). Measured by a canary QR per environment + support-ticket
  watch.
- **Timezone correctness**: an IST window entered as "expires 31 Jul 11:59 PM" stops at exactly 18:29 UTC —
  verified by an automated IST↔UTC round-trip test, not eyeballing.
- **Edge precision**: an expired QR stops redirecting within the KV-propagation window of its `end_at` (edge
  reads the stored timestamp; no cron lag).

**Support**
- Reduction in "my campaign QR is still live after the event / my expired offer still redirects" tickets to
  ~zero for QRs that used a window.

## 10. Rollout Plan

**Phase 0 — Backend + edge (internal).**
Migration `0033` (two columns). Thread the timestamps through `write_to_kv` / `sync_qr_to_kv`. Add the
window check + new system page to the Worker. Deploy the Worker to **staging** and verify: pre-start →
scheduled page, post-end → expired page, in-window → normal, precedence over paused/disabled/locked, **no
scan recorded** on a blocked scan. Backend accepts + persists + KV-syncs the fields.

**Phase 1 — Builder + dashboard (closed).**
Add the Schedule section (IST pickers, UTC conversion, zod validation) to create + edit, the static-QR note,
and the derived dashboard badge. Internal + a few design-partner workspaces.
- **Acceptance:** set an IST window on a dynamic QR → scanning before/after shows the correct branded page in
  the correct timezone → editing the window revives/re-schedules it → static QR shows the convert note → the
  dashboard badge matches reality → paused/disabled/locked still win.

**Phase 2 — GA.**
Remove any FE flag, update the comparison matrix + SEO page, add a help-center entry. If product chose the
upsell path, flip `qr_scheduling` `inert`→`enforced` (same PR as the seed).

**Cross-service gates:**
- **Worker change → `npm run deploy:prod` is required** (edge window check + new system page). Deploy order:
  backend migration + KV-write change **before** the Worker enforcement, so the Worker never reads a field
  the backend isn't writing yet (a missing field simply means "no window", so the ordering is safe either
  way, but apply migration first).
- **No email** in v1 → the unpublished `_dmarc.qravio.app` record is **not** a gate.
- **No new cron trigger** in v1 → no `wrangler.toml` cron change.

## 11. Risks, Edge Cases & Open Questions

**R1 — Timezone correctness (the #1 risk).** SMBs think in IST; the DB, Worker, and any cron run in UTC (5.5h
offset). A naive "store the local string" or "compare in server time" bug expires the QR 5.5 hours early or
late. **Mitigation:** collect IST in the builder, convert to a UTC `timestamptz` on submit, store + compare
UTC everywhere, render back in IST for display. Automated IST↔UTC round-trip test as a release gate. Never
use a naive/floating datetime.

**R2 — Edge must decide, not a cron (correctness).** If we flipped a status via a sweep, a printed QR would
keep redirecting for minutes-to-hours past expiry. **Mitigation:** the Worker compares "now" to the
KV-stored `end_at`/`start_at` on **every scan** — enforcement is exact-at-scan-time and needs no background
job. (This is precisely why we chose the orthogonal, no-status-flip design.)

**R3 — KV propagation lag on edit.** Extending/clearing a window writes to KV via `sync_qr_to_kv`; there's a
brief edge-propagation delay. **Mitigation:** acceptable (seconds); the KV write is the same synchronous path
every other QR edit already uses, and the failure mode (briefly serving the old window) is minor and
self-healing.

**R4 — State-machine collision (why we avoided it).** `qr_codes.status` is already overloaded
(active/paused/disabled/locked/inactive), each with its own cron + KV-sync path. Adding `scheduled`/`expired`
would multiply the transition matrix across `qr.py`, `razorpay_routes.py`, and `internal.py`. **Mitigation:**
we do **not** add status values — the window is orthogonal, evaluated at the edge and derived for display.
Precedence is fixed and documented: status branches first, then window.

**R5 — Two sources of "end date" on event/coupon.** `event`/`coupon` already have decorative
`end_date`/`valid_until` fields that don't enforce. Now there's also the enforced `end_at`. A user could set
one and not the other and be confused ("the page says the offer ended but the QR still redirects", or vice
versa). **Mitigation:** v1 keeps them independent but the builder copy is explicit ("this only controls the
displayed date, not when the QR stops working" vs "this stops the QR working"). Unifying them is future
cleanup (§7). Flag for eng-review.

**R6 — Misconfigured window = "my QR is broken" tickets.** A user sets `start_at` in the future and panics
that scanning shows "not active yet". **Mitigation:** the dashboard badge + inline date makes the state
obvious; the scheduled page is clearly worded; edit-to-clear is one action.

**R7 — Clock skew / "expires now" edge.** Exactly-at-boundary scans and edge clock skew. **Mitigation:**
define the window as `start_at <= now < end_at` (inclusive start, exclusive end); rely on Cloudflare's
clock; sub-second boundary behavior is immaterial for a human-scale campaign feature.

**Open Questions**
1. **Ungated vs `qr_scheduling` Starter+ upsell?** *Recommend ungated (all plans) in v1 — table-stakes, zero
   COGS, minimal migration. Product to confirm.* (§8)
2. **Does the scheduled/"not yet live" page name the go-live date, or stay generic?** *Recommend generic-with-
   optional-date; naming the date is friendlier but leaks the owner's schedule to any scanner. Lean generic.*
3. **Store two plain columns on `qr_codes`, or a small `qr_schedule` detail table?** *Recommend two columns —
   it's a 1:1 property of the QR, the update path already treats unknown `qr_codes` columns as direct writes,
   and it keeps the KV snapshot trivial. TRD decision.*
4. **Should an `end_at` set in the past on create be a hard error or a warning?** *Recommend: warn on create
   (probably a mistake), allow on edit (legitimate "kill it now").*

## 12. Dependencies

- **Dynamic-QR lifecycle + KV sync (shipped):** `qr_codes.status` branches in the Worker (`src/index.js`),
  `write_to_kv` / `sync_qr_to_kv` (`src/utilities/cloudflare_kv.py`) — the enforcement + snapshot seam.
- **Worker system-page pattern (shipped):** `getPausedPage` / `getDisabledPage` (`disabledPage.js`,
  shared `buildPage()`), `getScanLimitPage` (`scanLimitPage.js`) — the new scheduled/expired page mirrors
  these, including `{ whiteLabel, brand }`.
- **Builder wizard (shipped):** the create/edit QR forms (react-hook-form + zod + shadcn) — the Schedule
  section slots in; a new/extended hook under `qr_frontend/src/hooks/`.
- **Migration mechanism (shipped):** hand-applied SQL in `qr_backend/migrations/`; next slot **`0033`**.
- **No AI, no new external service, no email, no new cron (v1).**

### Appendix — Key Files

| Concern | File |
|---|---|
| Window columns + tz + blocked counter | `qr_backend/migrations/0033_qr_expiry_scheduling.sql` (NEW — `start_at`, `end_at`, `schedule_tz` on `qr_codes` + a `qr_blocked_scans` counter table) |
| Create/update model + persistence | `qr_backend/src/api/routes/qr.py` (`QRCode*` models ~L865; update path ~L2838 treats new `qr_codes` columns as direct writes) |
| Blocked-scan recording | `qr_cf_code/src/index.js` (fire on the blocked path) → NEW `/internal/blocked-scan` in `qr_backend/src/api/routes/internal.py` → `qr_blocked_scans` (never read by `_enforce_scan_limit`) |
| KV snapshot | `qr_backend/src/utilities/cloudflare_kv.py` (`write_to_kv` ~L52/L93 payload, `sync_qr_to_kv` ~L307 select+call) |
| Edge enforcement | `qr_cf_code/src/index.js` (parse ~L353; window check beside status branches ~L368–381, before password gate ~L383) |
| Scanner system page | `qr_cf_code/src/pages/schedulePage.js` (NEW — mirrors `disabledPage.js` `buildPage()`; not-yet-live + expired states) |
| Builder Schedule UI | `qr_frontend/src/components/qr-generator/…` (new Schedule section; create + edit) + a hook in `qr_frontend/src/hooks/` |
| Dashboard badge | `qr_frontend` QR list/detail (derive Scheduled/Active/Expired from the columns) |
| Optional gating (upsell path only) | `qr_backend/src/api/routes/subscription.py` (`FEATURE_ENFORCEMENT['qr_scheduling']`), `qr_frontend/src/lib/plan-features.ts` |
