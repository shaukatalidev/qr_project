# PRD — Per-QR scan limit (scan cap + expiry by scan count)

**Status:** SHIPPED 2026-08-29 · **Author:** Product · **Date:** 2026-08-28
**As built:** see `PER_QR_SCAN_LIMIT_TRD.md` §0 — the two headline risks (§10's `outside_hours` drop, G5's bot-billing bug) were already fixed before this shipped, and §5.3's badge name collided with an existing one.
**Covers requested items 5 ("QR scan limit") and 6 ("expiry by scan count") as one feature.** They are the same column, the same KV field, the same Worker branch position and the same system page. Specified apart they would contradict each other on the first edit.
**Priority:** Parity checkbox plus a genuine SMB use case (limited-redemption offers). Reuses the shipped expiry machinery end to end, so the marginal cost is small and the review lessons are already paid for.
**Tiers:** **All plans, ungated**, matching `QR_EXPIRY_SCHEDULING`'s posture and the house line established by `0027` (all QR types opened) and `0028` (folders opened). Zero COGS.
**Plan flags:** **none new.** No `FEATURE_ENFORCEMENT` entry, no plan-seed edit, `test_feature_gate_coverage` stays green.
**Split from:** (a) `QR_EXPIRY_SCHEDULING` — time-based, shipped in `0033`/`0048`; (b) the **plan-level** `max_scans` cap enforced by `_enforce_scan_limit`. This is neither, and §2.1 explains why the second distinction is the important one.
**Repos:** `qr_backend`, `qr_cf_code`, `qr_frontend`.

---

## 1. TL;DR / Summary

A dynamic QR gets an optional **`scan_limit`**: an integer count of scans after which it stops
serving content and shows a "this code has reached its scan limit" page.

Two user-facing framings, **one mechanism**:

- **"Limit scans to N"** — a cap. Coupon redemptions, ticketed entry, limited offers.
- **"Expire after N scans"** — the same rule expressed as a lifecycle.

The builder presents one control and carries both readings in its copy.

Under the hood: two nullable columns on `qr_codes`, two fields in the KV snapshot, one branch in
the Worker beside the existing schedule branches, one new state on the existing system-page module,
and one new blocked-scan reason.

**The cap is a guaranteed floor, not an exact ceiling — and the UI says so.** §6 is the most
important section in this document.

## 2. Problem & Motivation

### 2.1 What exists is not this, and one of the differences is dangerous

| Mechanism | Scope | Trigger | Blast radius |
|---|---|---|---|
| **`max_scans`** (plan quota) | **The whole workspace** | Monthly billable scan count | `_enforce_scan_limit` sets `status='disabled'` on **every dynamic QR the workspace owns** |
| **`start_at` / `end_at`** (`0033`) | One QR | A date | That QR only |
| **`daily_*`** (`0048`) | One QR | Recurring hours | That QR only |
| **`status='paused'`** | One QR | A human remembering | That QR only |
| **This feature** | One QR | A scan count | That QR only |

The `max_scans` row is the one that matters. A customer today has **no** way to cap a single QR.
Their only count-based lever is the workspace quota, and when that trips it takes down every other
QR they own — including the ones that were behaving.

So a customer with one unpredictable QR (a poster that might go viral, a campaign with an unknown
audience) currently faces a choice between no protection at all and a workspace-wide outage. That
is the gap, and it is a safety gap rather than a feature gap.

### 2.2 The use cases are concrete

- **"First 100 customers get 20% off"**, printed on 5,000 flyers. Today customers 101 through 5,000
  all reach the discount page, and the merchant either honours it or argues at the counter. This is
  the canonical Indian-SMB promo and we cannot support it.
- **Event entry** — a badge QR valid for one scan; a table QR valid for a fixed party size.
- **Trial / demo codes** an agency distributes with a hard usage budget.
- **Cost containment** — §2.1.

### 2.3 Competitive parity

"Scan limit" is a line item in Beaconstac, QR Tiger and QRCodeChimp comparison tables. It does not
win a deal alone; its absence shows as a blank cell.

## 3. Goals & Non-Goals

### Goals

- **G1.** Optional `scan_limit` on any **dynamic** QR, settable at create and at edit.
- **G2.** Enforced **at the edge**, from the KV snapshot, beside the existing schedule branches.
- **G3.** A **distinct** system page from the plan-cap page. The two say completely different things
  to completely different readers and offer different actions.
- **G4.** **Blocked scans are recorded, to a counter no billing path reads.** A scan blocked by a
  per-QR limit must never burn `max_scans` and must never contribute to the workspace-wide disable.
- **G5.** **Bot scans never count toward the limit.** A crawler must not consume a customer's 100
  vouchers.
- **G6.** Dashboard shows progress ("73 of 100 scans") and a **Limit reached** badge derived from
  the columns.
- **G7.** Raising or clearing the limit **revives the QR immediately** — within one KV publish.
- **G8.** Be honest about the overshoot (§6) in the builder, not in a support reply.

### Non-Goals

- **NG1 — no new `qr_codes.status` value.** The enum already carries five values with five distinct
  owners (`src/core/qr/status.py` documents who may clear each). `QR_EXPIRY_SCHEDULING` refused to
  add `expired` for exactly this reason and this feature follows it: a nullable column evaluated at
  the edge, derived for display.
- **NG2 — no exact, globally-consistent counter.** §6. It is not available at the edge, and
  pretending otherwise is the main way this feature ships broken.
- **NG3 — no per-user or per-device limits** ("one scan per person"). That needs durable identity
  at the edge and is a much larger feature.
- **NG4 — no static-QR support.** A static QR encodes its target in the pixels and never reaches the
  Worker, so it physically cannot be capped. State it plainly and offer "convert to dynamic", as
  the expiry feature already does.
- **NG5 — no monthly reset.** The count is lifetime. A resetting per-QR limit collides conceptually
  with `max_scans` and confuses both.
- **NG6 — no "notify at N but keep serving".** That is the alerts feature
  (`analytics_alert_configs`, run by `internal.py`'s run-alerts tick), which already exists. Link
  to it; do not grow a second notification path here.

## 4. Personas & user stories

**Ravi — café owner, Free plan, 5,000 flyers printed**
> *I set the limit to 100. The 101st scanner sees "this offer has ended" instead of a coupon I have
> to refuse to their face.*

**Meera — event organiser, Pro plan**
> *Each badge QR is valid for one scan. A photographed badge doesn't get someone else in.*

**Arun — near his plan's scan cap, Starter**
> *I cap the one QR I can't predict, instead of watching every QR I own get disabled at once.*

**Priya — agency, Agency plan**
> *Demo codes for prospects with a hard usage budget, so a client can't quietly run a campaign on
> my trial QR.*

## 5. UX

### 5.1 Builder and edit

A **Scan limit** card beside the existing Schedule card (`details/schedule-card.tsx` is the model
to copy — same shape, same placement, same enable/disable idiom).

- Toggle: **Limit total scans**.
- Number input, min 1, integer. No maximum beyond a sane ceiling.
- Helper copy: *"After this many scans the QR stops working and shows an 'ended' page. Bots and
  link previews don't count."*
- Live progress when the QR has scans: **"73 of 100 scans used."**
- **The honesty note (G8):** *"Scans are counted moments after they happen, so a very busy QR may
  serve a few extra before it stops."*

### 5.2 Both framings, one control

Beneath the input, two preset chips that write the same field:

- **"Limit to N scans"** — the cap framing.
- **"Expire after N scans"** — the lifecycle framing.

They set identical state. The chips exist because users arrive with one of two mental models and
searching for the wrong word is how a shipped feature goes unfound.

### 5.3 QR list

A **Limit reached** badge alongside the existing Scheduled / Active / Expired badges. Derived from
`scan_limit_reached_at IS NOT NULL` — no new status, no extra query beyond the columns already
returned.

### 5.4 Detail page

- A progress bar in the performance panel: `73 / 100`, with the remaining count.
- When reached: a prominent **Raise limit** action. That is the only thing the owner wants at that
  moment, and burying it behind the edit flow guarantees a support ticket.

### 5.5 The system page (Worker)

Headline: **"This code has reached its scan limit."**
Body: *"The person who created it set a limit on how many times it can be used."*

Requirements:

- **No upgrade CTA.** The reader is a member of the public who scanned a poster, not our customer.
  The plan-cap page's "upgrade your plan" message shown to a café's customer is both meaningless
  and embarrassing.
- White-label aware (`whiteLabel` / `brand`), like every other system page.
- English only, deliberately — locale resolution happens *after* the status and schedule branches
  by design, so all system pages stay English in v1. Localising this one would require moving
  locale resolution above the gates, which changes behaviour for every system page.

## 6. The counting problem — read this before implementing anything

### 6.1 The edge cannot count

The Worker serves from a KV snapshot the backend writes. Cloudflare KV is **eventually consistent**
(a write can take up to ~60s to propagate globally) and **rate-limited to roughly one write per
second per key**. A Worker cannot therefore maintain an accurate global counter without a Durable
Object, which is a different architecture with a different cost model and a different failure
surface.

### 6.2 The chosen design

- **The backend counts.** `/internal/scans` already inserts the scan. It compares the count against
  the limit there, and on crossing it stamps `scan_limit_reached_at` and republishes KV.
- **The Worker enforces** a boolean from the KV snapshot.
- **The consequence is overshoot**, bounded by the scan-record round trip plus KV propagation.
  Under normal load that is seconds and a handful of scans; under a burst it could be dozens.

### 6.3 The product commitment

> **The limit is a guaranteed floor.** We promise "**at least** N scans will be served" and we say
> in-product that a busy QR may serve a few more. We do **not** promise "never more than N".

Every piece of copy, every comparison-table cell and every support answer must match that. A
campaign that genuinely depends on an exact ceiling — a legally-limited redemption, a regulated
draw — needs a redemption system, and we should say so rather than sell them a QR.

### 6.4 Why this differs from the expiry decision

`QR_EXPIRY_SCHEDULING` explicitly refused a lagging cron and enforced at the edge, so that "a
printed QR stops the **instant** it expires rather than minutes-to-hours later when a sweep runs".

That was available because **time is knowable at the edge with no state**. `Date.now()` needs no
coordination. A count does. Choosing lag here is not a lower standard; it is the only option short
of a Durable Object per QR, and that is not justified by this feature.

## 7. Gating

**Ungated on all plans.** Two reasons:

1. It costs us nothing — no COGS, no per-use expense.
2. Gating a **safety** control is a bad trade. The workspaces most likely to blow through
   `max_scans` are on Free and Starter, and their overrun disables every QR they own (§2.1).
   Selling them the tool that prevents that is worse business than giving it away.

## 8. Edge cases

| # | Case | Behaviour |
|---|---|---|
| E1 | Limit raised after being reached | `scan_limit_reached_at` cleared in the same write; KV republished; QR live again. **This is the path users hit under time pressure — make it fast and obvious.** |
| E2 | Limit cleared entirely | Same as E1; both KV keys omitted, QR returns to the pre-feature fast path. |
| E3 | Limit **lowered** below the current count | Stamp `reached_at` immediately. Never leave a QR serving above its own stated limit. |
| E4 | Limit set to exactly the current count | Reached immediately. Correct, if surprising — show the current count in the input's helper text so it cannot be set blind. |
| E5 | Bot scans a limited QR | Not counted (G5), not blocked. `detectDevice` in the Worker already classifies bots. |
| E6 | QR is also expired by date | The **schedule** branch wins — it runs first and "expired" is the more informative statement. |
| E7 | QR is `suspended` / `paused` / `disabled` / `locked` | Those branches win; they run before this one. A moderation hold must never be described as a scan limit. |
| E8 | A `website` (redirect) QR reaches its limit | Shows the system page, **not** a 302. This requires the branch to sit before the website early-return — see TRD §5.1. |
| E9 | KV carries `scan_limit_reached` but the Worker predates the feature | Unknown key ignored; QR serves normally. Fail-open, and the reason the Worker deploys first. |
| E10 | `scan_limit_reached` is malformed | Fail open, log loudly. Serving a live QR beats darking a printed one on a parse error. |
| E11 | A blocked scan is recorded | To `qr_blocked_scans` only, with reason `scan_limit`. Never `qr_scan_events`. |
| E12 | Owner wants to know it was hit | The blocked-scan counter is already surfaced by `useQRBlockedScans` — "still being scanned 42× — raise the limit?" |

## 9. Success metrics

| Metric | Why |
|---|---|
| QRs created with a limit; distribution of values | Adoption, and whether the presets match reality |
| Limit-reached events per week | The feature firing at all |
| **Median and p95 overshoot** (scans served beyond N) | **Validates §6.3.** If p95 overshoot is large, the honesty copy is not sufficient and the design needs revisiting |
| Raise-after-reached rate | High means limits are set too low, or §5.4's action is not being found |
| Blocked-scan volume, **verified as excluded from billable `max_scans`** | G4, and it must be checked in production, not only in tests |
| Support tickets: "my QR stopped working" resolving to a scan limit | The reached page's copy is not reaching the owner |

## 10. Risks

| Risk | Severity | Mitigation |
|---|---|---|
| **Blocked scans burn the billable cap and disable the whole workspace** | **Critical** | The Worker returns before `recordScan`; blocked scans go to `recordBlockedScan` → `qr_blocked_scans`, which nothing billable reads. The Worker integration suite already pins "a page that served no content must never POST `/internal/scans`" — extend it to this branch. |
| **The new blocked reason is silently dropped** | **High** | Three places must change in lockstep (TRD §3.4). This has already happened once in this exact function: `outside_hours` was POSTed by the Worker and dropped by the backend's allowlist for the whole daily-window feature's lifetime. |
| Bots consume a customer's vouchers | High | Count with `exclude_bot_scans`. Note the known live bug where bots **are** counted against `max_scans` — do not inherit that behaviour here. |
| A KV refresh from an unrelated path drops the limit | High | The fields are written only through `sync_qr_to_kv`, whose explicit `select(...)` must name the new columns. Omitting one does not fail loudly — it silently strips the setting on the next resync, which is exactly how `page_design` once caused permanent DB↔KV drift. |
| Overshoot surprises a customer who read "limit" as exact | Medium | §6.3 copy, in the builder and on the reached page, before it happens. |
| Raising the limit does not revive the QR | Medium | Clearing `reached_at` republishes via `publish_qr` in the same save. Test the revive path explicitly. |
| Someone reuses the plan-cap `scanLimitPage` | Medium | G3. A public scanner told to "upgrade your plan" is a support ticket and an embarrassment. |
| The limit is read from a lossy counter and under-counts | Medium | TRD §3.2 — choose the source deliberately and document it; `qr_scan_counters` has a known non-atomic write path. |

## 11. Rollout

**Deploy order is load-bearing** and is the reverse of intuition:

1. **Apply the migration.**
2. **Deploy the Worker first.** A KV value carrying `scan_limit_reached` that the Worker does not
   understand is ignored — harmless. The reverse (backend stamping the flag with no Worker branch)
   means the limit silently does nothing while the UI claims it is enforced, which is the worst
   possible state for a feature whose entire value is "it stops".
3. Deploy the backend.
4. Ship the frontend.

Backwards compatible throughout: existing QRs have `scan_limit IS NULL`, both KV keys are omitted,
and their KV values stay byte-identical until they are next republished for another reason.

## 12. Open questions

1. **Does the limit ever reset?** v1: no, lifetime (NG5). Revisit only with a clear use case that
   is not already served by `max_scans`.
2. **Notify the owner at 80% and 100%?** Strongly wanted, and it belongs in
   `analytics_alert_configs` + the run-alerts tick, not here (NG6). Sequence it as a follow-up.
3. **Should `scan_limit` be settable via the public API?** Almost free — one field on the existing
   update schema. Confirm before build; if yes, the Worker-side fail-open behaviour matters more,
   because the UI is then not the only writer.
4. **Should reaching the limit fire an outbound webhook?** `webhook_scan_milestone` (`0024`) already
   exists and is the natural home. Cheap; decide before the backend PR.
