# PRD — QR change history

**Status:** Draft (detailed) · **Author:** Product · **Date:** 2026-08-28
**Priority:** Trust and team-safety. The value proposition of a dynamic QR is that its destination can change after printing; the cost, today, is that nobody can see *that* it changed, *when*, or *who did it*. The old value is overwritten in place and gone.
**Tiers:** **Reading history: all plans, ungated.** **Depth is gated by the existing `analytics_retention_days` ladder** (7 / 30 / 90 / 365) rather than a second, parallel retention concept.
**Plan flags:** **None new.** Retention reuses `analytics_retention_days`, already `enforced` in `FEATURE_ENFORCEMENT`. `test_feature_gate_coverage` stays green with no edit.
**Split from:** `src/core/qr/service.py::update_qr`. **Distinct from `admin_audit_log`** (0044), which is the *platform-scoped* trail of what staff did to any tenant. This is the *customer-facing* trail of what happened to their own QR — different reader, different question, different table. It is also **not** the workspace-scoped `audit_log` specified in `ORG_MFA_AUDIT_LOG_PRD.md` (still unbuilt), which answers "what did this workspace's members do across the whole account".
**Repos:** `qr_backend`, `qr_frontend`. No Worker change, no KV contract change.

---

## 1. TL;DR / Summary

Every change to a QR is recorded as one append-only row: **who**, **when**, **which fields**,
**from what**, **to what**, and **through which path** (dashboard, public API, bulk edit, or an
automated sweep). A **History** tab on the QR detail page renders it as a reverse-chronological
timeline:

> *Priya changed the destination from `acme.com/spring` to `acme.com/summer` · 14 Aug, 3:42 PM*
> *Automatically disabled — monthly scan limit reached · 2 Aug, 11:09 PM*

v1 is **read-only**: no restore, no revert, no branching. One table, one recorder called from
every mutation path, one endpoint, one tab.

## 2. Problem & Motivation

### 2.1 The structural hole

A dynamic QR is a **printed object whose behaviour can be changed remotely by anyone with editor
rights**. That is the product. Without a history it is also an accountability hole, because the
change is destructive: `qr_destinations.target_url` is updated in place, and the previous value
does not exist anywhere afterwards.

### 2.2 Four concrete failures

**The 5,000-poster problem.** A destination is repointed at 11pm. Scans keep arriving; conversions
stop. The owner cannot determine whether the QR was changed, by whom, or what it pointed at
before. There is no way to put it back, because the old URL is gone.

**Teams cannot self-serve.** `max_members` is 10 on Pro and unlimited on Agency. On a ten-person
workspace, "who paused this?" has no answer that does not involve us reading the production
database. `qr_codes.updated_at` says *something* changed; it never says what, and it never says who.

**Agencies cannot prove delivery.** A client asks when the campaign URL switched over. The agency's
only evidence is a screenshot they may not have taken.

**Support load lands on us.** Every "our QR stopped working" ticket begins by reconstructing a
change nobody recorded. The reconstruction is guesswork.

### 2.3 We already believe in this — for ourselves

`admin_audit_log` (0044) records every staff mutation, is immutable at the database level
(`UPDATE`/`DELETE` revoked from every role *and* trigger-blocked), and stamps the actor's role as
it was at the time so a later demotion cannot rewrite history. We built that because we understood
we would need to answer "who did this" during an incident.

Customers get nothing equivalent. That asymmetry is the gap.

### 2.4 The automated changes are the ones people cannot explain

Four separate automated paths change a QR's status without a human touching it:

| Path | What it does | What the customer sees today |
|---|---|---|
| `_enforce_scan_limit` (`internal.py`) | Sets `disabled` when the **workspace** hits `max_scans` — on **every QR the workspace owns** | Every QR stops working at once, with no explanation on any of them |
| Plan-downgrade sweep (`razorpay_routes.py`, `mor_routes.py`) | Sets `locked` when QR count exceeds the new plan's cap | Some QRs stop, seemingly at random |
| Admin suspend (`admin/qrs.py`) | Sets `suspended` | The QR stops; the dashboard cannot say why |
| Anon-claim sweep (0051/0052) | Sets `unclaimed_expired` | |

These are precisely the events that generate tickets, and precisely the ones no history built only
around the dashboard save path would capture. **Recording them is not a nice-to-have; it is the
larger half of the feature's value.**

## 3. Goals & Non-Goals

### Goals

- **G1.** Record every customer-visible mutation of a QR: destination, name, status, content fields,
  QR design, page design, schedule window, daily window, locales, routing rules, password on/off,
  folder, tags, custom domain, retargeting mode.
- **G2.** Attribute each change to an actor (a workspace member, an API key, or the system) and a
  timestamp, and render it in the reader's locale-correct local format.
- **G3.** A **History** tab beside Overview / Content / Design / Page on the QR detail page.
- **G4.** Record changes made through **every** path — dashboard, public API, bulk edit, and all
  four automated sweeps in §2.4.
- **G5.** Keep the destination diff **verbatim and complete**: old URL and new URL in full, never
  truncated, never normalised. It is the entry people open the tab for.
- **G6.** Never record a secret. A password change records *that* it changed; never the value,
  never the hash.
- **G7.** Group one save into one entry. A builder save touching nine fields is one row and one
  timeline entry listing nine fields — not nine entries.
- **G8.** Be honest about truncation: when the plan's retention window is shorter than the QR's
  age, say so rather than implying the history is complete.

### Non-Goals

- **NG1 — no restore / revert in v1.** Restoring means re-validating content against the *current*
  plan (the type may no longer be entitled), re-copying storage objects that may have been purged,
  re-minting nothing, and re-publishing KV. That is a create-path problem wearing a history-shaped
  hat. It is phase 2 and it needs its own spec.
- **NG2 — no scan or analytics history.** Those are events, not changes, and they already have
  `qr_scan_events` / `qr_scan_counters`.
- **NG3 — no workspace-wide activity feed.** Per-QR only. A workspace feed is a different surface
  with different tenancy and volume characteristics, and it is what `ORG_MFA_AUDIT_LOG_PRD.md`
  already specifies.
- **NG4 — no read auditing.** Who *viewed* a QR is a compliance feature. `admin_audit.py`'s
  docstring already argues the general case: a trail where 99% of entries are "looked at a page"
  is a trail nobody reads.
- **NG5 — no backfill.** Pre-existing changes are unrecoverable; the data does not exist. The empty
  state says when history started rather than implying nothing ever changed.
- **NG6 — no editing or deleting history.** Append-only at the database level, mirroring `admin_audit_log`.

## 4. Personas & user stories

**Arun — owner, 8-person Pro workspace**
> *I see that Priya repointed the destination at 11:04pm on 14 Aug, and what it pointed at before.
> I put it back myself in thirty seconds instead of opening a ticket.*

**Priya — editor**
> *I can see my own changes, which means I can check what I did before a client call.*

**Meera — agency, Agency plan**
> *I export the change log for a client campaign as evidence of what was delivered and when.*

**Support (us)**
> *"My QR stopped working" now arrives with the customer already knowing it was auto-disabled at
> the monthly scan cap, because their own history told them.*

## 5. UX

### 5.1 The tab

A **History** tab in `TabPills`, URL `?tab=history` — the detail page already drives tabs from a
search param (`searchParams.get('tab') ?? 'overview'`), so this is one entry in an existing list.

### 5.2 Entry anatomy

Each entry shows: actor initial/avatar, actor name, relative time (absolute on hover and on focus),
and a human sentence per changed field.

**Grouping (G7).** One save = one entry. Nine changed fields render as one entry with nine lines,
collapsed to three with a "+6 more" expander. Nine separate entries would make the timeline
unreadable on day one, and the underlying save was a single user intent.

### 5.3 Per-field rendering rules

| Field | Rendering | Why |
|---|---|---|
| **Destination** | `from` → `to`, both **full URLs**, monospace, individually copyable | The entry people came for. Truncating it destroys the feature. |
| **Status → paused/active** | "Priya paused this QR" / "resumed" | |
| **Status → disabled by the cap** | **"Automatically disabled — monthly scan limit reached"**, no person named | Attributing a system action to whoever last saved is worse than no history: it accuses a colleague. |
| **Status → locked** | "Automatically locked — plan limit exceeded after a downgrade" | |
| **Status → suspended** | "Suspended by Qravio" + the support route | Never attribute to a workspace member. |
| **Name** | `from` → `to` | |
| **Content fields** | Field label, both values, truncated at a generous ceiling with expand | |
| **QR design / page design** | "Page design updated" + the specific keys that changed (`templateId`, `themeColor`, `pageTitle`) | Never dump JSON at a human. |
| **Password** | "Password protection enabled" / "disabled" / "changed" | **No values, ever.** G6. |
| **Locales** | The locale set before and after, as chips | |
| **Routing rules** | "Routing rules updated — 3 rules" | Rule-level diffing is v2. |
| **Tags** | Added and removed chips | |
| **Folder** | `from` → `to` folder name | |
| **Creation** | "Priya created this QR" — always the first entry | Anchors the timeline. |

### 5.4 Empty and truncated states

**Empty:** *"No changes since this QR was created."* — plus the creation entry, which always exists
for QRs created after the feature ships.

**Pre-feature QRs:** *"History starts 28 Aug 2026. Changes made before then were not recorded."*
Do not render a blank timeline; it reads as "nothing ever happened", which is false.

**Truncated by plan:** *"Showing the last 30 days. Your plan keeps 30 days of history."* with the
upgrade path. Silently truncating a trust feature is how it becomes a distrust feature.

### 5.5 Export

A **Download CSV** action on the tab, reusing the pattern `downloadLeadsCsv` already establishes.
Agencies need it as client evidence (§4). Same retention clamp as the on-screen view.

## 6. Data recorded

Per event:

| Field | Notes |
|---|---|
| `qr_id`, `workspace_id` | |
| `actor_user_id` | **Nullable** — system actions have no actor |
| `actor_kind` | `user` \| `system` \| `api` \| `admin`. NOT NULL. |
| `actor_display` | Denormalised at write time, so a removed member still renders |
| `source` | `dashboard` \| `public_api` \| `bulk` \| `sweep` \| `admin`. NOT NULL. |
| `reason` | System actions only: `scan_cap`, `plan_downgrade`, `unclaimed`, `moderation` |
| `changes` | JSONB `{field: {from, to}}`, or `{field: {"changed": true}}` for value-suppressed fields |
| `created_at` | |

**Never written:** password values or hashes, API key material, storage signed URLs, or any field
outside the value allowlist (TRD §4.2).

## 7. Retention & gating

Reading is **ungated**. Hiding "who broke it" behind a paywall converts an incident into a support
ticket for us, which costs more than the upsell earns.

**Depth** reuses `analytics_retention_days` — Free 7, Starter 30, Pro 90, Agency 365 — because:

- it is already `enforced`, so no new flag, no plan-seed edit, no coverage-test churn;
- a customer who understands "my plan keeps 30 days of analytics" already understands "…and 30
  days of history"; a second, differently-shaped retention concept is a support burden;
- it makes the upgrade argument concrete rather than inventing a new one.

Rows older than the window are filtered at read time in v1 and physically pruned on the same tick
that prunes analytics. This table must not grow unbounded and unmentioned.

## 8. Edge cases

| # | Case | Behaviour |
|---|---|---|
| E1 | A save changes nothing (user opens and re-saves) | **No row.** An empty diff writes nothing. |
| E2 | Bulk edit across 40 QRs | 40 rows, one per QR — **not** 40 × fields. |
| E3 | The scan cap disables 200 QRs at once | 200 rows, `actor_kind='system'`, `reason='scan_cap'`. Volume is acceptable; this is the event customers most need explained. |
| E4 | A member is removed from the workspace | Their past entries render from `actor_display`. Nothing is deleted. |
| E5 | The user account is deleted (right-to-erasure) | `actor_user_id` is nulled; the row survives. Whether `actor_display` also clears is governed by `ACCOUNT_DELETION_ERASURE` — see §12 Q1. |
| E6 | The QR is deleted | History cascades away with it. It is not evidence anyone can reach afterwards. |
| E7 | A viewer-role member opens the tab | Allowed (`require_can_read`). They see the same member names they already see in the members list — no new PII surface. |
| E8 | The recorder itself fails | The save still succeeds. A logging outage must not become a product outage. The row is lost; that trade-off is explicit and matches `admin_audit.py`. |
| E9 | Two people save simultaneously | Two rows, ordered by `created_at`. Last-write-wins on the QR itself is pre-existing behaviour and unchanged. |
| E10 | A change arrives via the public API | `source='public_api'`, `actor_kind='api'`, attributed to the key's owner. |

## 9. Success metrics

| Metric | Healthy signal |
|---|---|
| Share of QR-detail sessions opening History | Non-trivial on multi-member workspaces |
| History opens within 24h of a destination change | This is the intended trigger; high is good |
| "Stopped working" / "wrong link" tickets | Falling |
| Share of tickets where the customer already cites their history | Rising — the feature is doing our support work |
| Rows per QR per month | The input to the retention-cost decision |
| p95 added latency on `update_qr` | Under a few ms; if not, §12 Q2 |

## 10. Risks

| Risk | Severity | Mitigation |
|---|---|---|
| **A secret reaches `changes`** | High | Value **allowlist** (not deny-list) + strip secrets at the input boundary, so two independent mistakes are needed to leak one. Test asserts on the serialised row. |
| A system action is attributed to the last human who touched the QR | High | `actor_kind` is NOT NULL and system paths pass it explicitly; a test pins the scan-cap disable to `actor_kind='system'`, `actor_user_id IS NULL`. |
| Write amplification slows every save | Medium | One insert per save, after the write, in a threadpool, never raising. Measure `update_qr` p95 before and after. |
| Unbounded table growth | Medium | Read clamped by retention; physical prune scheduled with the analytics prune. Do not leave the prune undefined. |
| A new mutation path ships with no recorder call | Medium | `source` CHECK constraint makes an unlisted path fail loudly at insert; plus an AST-style test enumerating QR-mutating route modules. |
| History exposes a teammate's email | Low | `actor_display` is a display name, never a raw email; membership already exposes the same names. |
| Users expect restore because history exists | Medium | NG1 stated in-product: the tab header says "read-only record". |

## 11. Rollout

**Phase 1 (one PR).** Migration + recorder + **all** call sites + read endpoint. Shipping the
dashboard call site alone produces a history that omits exactly the four automated events people
open it for (§2.4) — worse than shipping nothing, because it looks complete.

**Phase 2.** The tab, the CSV export, the retention notice.

**Phase 3 (separate spec).** Restore-to-version, if the metrics show people want it. It is
plausible that reading was the whole need.

## 12. Open questions

1. **Does erasure clear `actor_display`?** `ACCOUNT_DELETION_ERASURE` governs. Proposal: null
   `actor_user_id`, keep the row, replace `actor_display` with "a removed user" — the change itself
   is workspace data, the identity is personal data.
2. **Is the creation event stored or synthesised?** Storing costs one insert in `create_qr` and
   gives a real `source`; synthesising from `created_at`/`created_by` costs nothing and loses that.
   Proposal: **store it** — `create_qr` already writes several rows.
3. **Does the public API expose history?** `GET /api/public/v1/qr-codes/{id}/history` is cheap and
   agencies will want it. Defer to phase 1.5.
4. **Do routing rules get field-level diffs, or "updated"?** v1 says "updated". Field-level diffing
   of a rule array needs a stable rule identity we do not currently have.
