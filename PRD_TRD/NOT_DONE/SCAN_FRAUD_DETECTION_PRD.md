# PRD — Scan Fraud & Abuse Detection

**Status:** Draft · **Author:** Product · **Date:** 2026-07-27
**Priority:** **Platform integrity / billing correctness — not a sellable feature.** Scans are the billing meter, so scan fraud is a denial-of-service against our own paying customer: a flood against a Free workspace's QR takes every one of that customer's *printed* QR codes offline. This closes a live weaponizable path, and it is the prerequisite for trusting every analytics number we sell on top of scans.
**Tiers:** **All tiers, ungated, no new plan flag.** Free is the tier that gets DoS'd (it is the only tier with a finite `max_scans`), so gating the defence behind a paid tier would protect exactly the customers who don't need it and abandon the ones who do. See §8 for why this deliberately breaks the house "every feature gets a flag" reflex.
**Plan flags:** **None.** No `FEATURE_ENFORCEMENT` entry, no `plans.features` key, no `PlanFeatures` field. `test_feature_gate_coverage` is untouched by this feature. The only tunables are operator-side thresholds and per-workspace overrides (§6.5), which are not entitlements.
**Split from:** the scan-limit enforcement half of `PLAN_LIMITS_ENFORCEMENT_PRD.md` (`_enforce_scan_limit`, `qr_backend/src/api/routes/internal.py:532`) and the bot-exclusion half of the shipped analytics read path (`exclude_bots` in `qr_backend/src/api/routes/scan.py`). Boundary with the concurrent `RATE_LIMITING_PRD.md`: **that spec owns API and auth-endpoint throttling; this spec owns the scan path only** (§12).

---

## 1. TL;DR / Summary

Today the entire defence against scan fraud is **one regex** — `if (/bot|crawl|spider|slurp|facebookexternalhit/i.test(ua)) return "bot";` (`qr_cf_code/src/utils/scan.js:2`) — plus a per-device dedupe that produces `is_unique` (`internal.py:375–392`). That is all of it. There is no rate limit, no velocity check, no ASN check, and no notion of a scan being suspicious.

Worse, the one signal we *do* produce is applied inconsistently. The analytics read path already excludes `device_type = 'bot'` by default (`exclude_bots=True`, `scan.py:1392`, `:1753`, `:1955`). The **billing** path does not: `_enforce_scan_limit` (`internal.py:551–558`) and `_usage_max_scans` (`subscription.py:367–375`) both count every row in `qr_scan_events` with no device filter. **So a Googlebot crawl of a Free workspace's short code burns that workspace's quota while being invisible in its analytics.** We are already billing a meter we already know is wrong.

This feature introduces a **classification** model, not a filtering one. Every scan row is written exactly as it is today and additionally stamped with an `integrity_flag` (`clean` / `bot` / `suspect` / `abuse`) and a human-readable `integrity_reason`. Nothing is ever deleted or silently dropped. Flagged scans are then **excluded from the billing meter** and from the analytics the customer reads, with a visible, defensible explanation — *"4,102 scans on this QR on 12 Aug were excluded as automated traffic from a hosting provider."*

The single most important behaviour change is a **circuit breaker on `_enforce_scan_limit`**: a workspace whose current period is dominated by flagged traffic is **never auto-disabled**. It gets an alert and an operator review instead. That one rule converts the DoS from "your printed QR codes go dark" into "you get an email."

Everything ships **backend-side at scan ingest** (`POST /internal/scans`). **The Cloudflare Worker is not touched in v1** — no `deploy:prod` gate, no KV change, no template mirroring. And nothing enforces on day one: v1 Phase 0 runs in **shadow mode**, writing flags and measuring, with exclusion switched on only after a false-positive review (§10).

## 2. Problem & Motivation

### 2.1 Scans are the billing meter, so scan fraud is a DoS against our own customer

This is the argument the whole spec rests on. Read the enforcement path:

`_enforce_scan_limit` (`internal.py:532`) runs **after every single scan**. It resolves the workspace's plan, counts `qr_scan_events` rows in the current period (`internal.py:551–558`), and if that count meets `max_scans` it does this:

```python
db.table("qr_codes").update({"status": "disabled"}).in_("id", affected_ids).execute()
```

— *every active dynamic QR in the workspace*, flipped to `disabled` and synced to KV so the edge serves `getScanLimitPage()` (`qr_cf_code/src/index.js:372–374`) instead of redirecting. Then it fires an owner alert (`_fire_scan_cap_alert`, `internal.py:896`).

Only Free has a finite cap. The authority is `0009_pricing_v3_4tier_collapse.sql:97` — `('free', 0, 0, 5, 2000, …)` — so **2,000 scans per calendar month**; Starter/Pro/Agency are all `-1`. (There is **no live discrepancy** to reconcile: `0005_pricing_v2_dual_currency.sql:59` seeded Free at `500` and the note at `0007_billing_foundations.sql:24` repeats it, but both are **pricing v2**, superseded by `0009`. The `_enforce_scan_limit` docstring's "2,000" matches the live v3 seed and is correct; `0007:24` is stale prose, not a live value, and this feature's PR should fix it in passing. Do **not** cite `tests/unit_tests/test_limits_engine.py:20` — its `FREE_PLAN` fixture still carries the 0005-era `500` and is an arbitrary test value, not a source of truth.)

So the attack is: **2,000 requests to a Free workspace's short code and every printed QR that workspace owns stops working.** A restaurant's table tents, a church's noticeboard, a startup's conference banner — all dark, all at once, for the rest of the calendar month, for the price of a shell loop. The victim's only recovery is to upgrade (which is a perverse incentive we should be deeply uncomfortable with) or wait for the monthly `_reenable_free_scan_disabled` sweep (`internal.py:618`, cron `0 0 1 * *`).

Nothing in the product prevents this. There is no per-IP scan limit, no velocity ceiling, no ASN filter. The cost to the attacker is a single line of `curl`. The cost to the customer is every physical asset they printed.

We do not need evidence of an attack in the wild to act. The asymmetry is the problem: trivially cheap to execute, catastrophic and *physically irreversible* in effect (you cannot un-print a poster), and completely undetectable today because we have no signal that distinguishes 2,000 real scans from 2,000 forged ones.

### 2.2 Secondary harms — everything downstream of the meter is poisoned

The scan row is the atom of nearly every analytics product we've shipped. Forged rows corrupt all of them:

- **Analytics the customer reports to their own boss.** `SCAN_CONVERSION_FUNNEL` and `DEEP_AUDIENCE_ANALYTICS` (both shipped, `PRD_TRD/DONE/`) read `qr_scan_events` directly. A flood inflates the funnel denominator and craters the conversion rate; it fabricates geo, OS/browser, and hour-of-day distributions. `CAMPAIGN_TAGS_ROLLUP` inherits the same rot. An agency on Agency tier presenting a poisoned rollup to their client is a churn event.
- **False webhook and milestone fires.** `dispatch_event(..., "scan", ...)` fires per scan (`internal.py:492–508`), and `check_scan_milestones` (`internal.py:519`) fires `scan.milestone` against `qr_scan_events` counts. A flood spams the customer's Zapier/Make automation with thousands of junk events and burns their "10,000 scans!" milestone on garbage. Those are irreversible outbound side-effects in *someone else's* system.
- **Wasted paid quota on higher tiers.** Paid tiers have `max_scans = -1`, so they cannot be knocked offline this way — but they still pay us for infrastructure serving forged traffic, and any future metered-scan pricing inherits the whole problem. The `_enforce_scan_limit` early-return at `internal.py:547–548` is the only thing standing between paid customers and the Free-tier outage.
- **Poisoned routing and A/B decisions.** `routing.py` rules and the A/B variant attribution (`variant_key` / `scans_by_variant`, `internal.py:446–451`) are decided on scan counts. Forged traffic skewed to one variant makes the customer ship the losing creative.
- **AI analyst hallucinating from junk.** `ai_analyst.py` narrates over the same tables. It will confidently explain a fabricated spike.

### 2.3 We already know the meter is wrong and we bill it anyway

The `exclude_bots` default in `scan.py` is an admission: we already believe bot rows are not real scans, and we already hide them from the customer. But `_enforce_scan_limit:551` and `_usage_max_scans:367` count them. That inconsistency is live today, needs no attacker to trigger, and is a one-predicate fix. It is the cheapest correctness win in this document and it should ship first.

## 3. Goals & Non-Goals

**Goals**

- **Make the billing meter count only defensible scans.** One shared predicate, used by every site that counts scans for quota purposes, so `_enforce_scan_limit`, `_usage_max_scans`, and `_reenable_free_scan_disabled` can never disagree about whether a workspace is over cap.
- **Never auto-disable a workspace on the strength of suspicious traffic.** Circuit breaker: if flagged traffic dominates the period, alert and hold rather than disable. The DoS must not be able to reach the `status = 'disabled'` write.
- **Classify, never delete.** Every scan row is written and kept. Flags are additive metadata. Evidence survives so a dispute is resolvable.
- **Explain every exclusion to the customer** in plain language, at the QR and workspace level, with counts, dates, and a reason — good enough for support to defend and for the customer to sanity-check.
- **Separate the three phenomena** (bots / accidental duplicates / deliberate abuse) with different signals, different responses, and different confidence bars (§6.1).
- **Ship monitor-only first.** Flags are written and measured before a single scan is excluded from anything (§10 Phase 0 → Phase 1 gate).
- **Give operators an override** — reclassify traffic, allowlist a workspace's known-good source, pin a workspace against auto-disable, and restore one that was wrongly capped.

**Non-Goals**

- **Not a WAF, not DDoS protection.** We do not make the *platform* flood-proof; Cloudflare already sits in front of the Worker for that. We make the *customer's quota* flood-proof. Platform-level request throttling is `RATE_LIMITING_PRD.md`.
- **No API or auth-endpoint rate limiting.** Owned by `RATE_LIMITING_PRD.md`. This spec touches the scan path only.
- **No blocking, CAPTCHA, or challenge at scan time.** A QR scan must resolve in one hop with no interstitial. We never make a real human prove they are human to reach a menu. *(Hard product constraint, not a v1 cut.)*
- **No deletion or mutation of scan rows, ever** — including "cleanup" of confirmed-fraudulent rows. *(Invariant.)*
- **No new plan flag, no new tier, no upsell.** (§8.)
- **No Worker/KV/edge change in v1.** No `build_kv_content` branch, no template, no cron, no `deploy:prod` gate. *(Phase 3 may add an edge pre-filter; explicitly deferred.)*
- **No IP-reputation vendor, no ML model, no third-party fraud service** in v1. Rules over signals we already collect.
- **No change to the edge `ip_hash`/`session_id` derivation in v1** — changing it would break the shipped scan↔lead↔click session join (`scan.js:19–24`). Its limitations are a constraint we design around (§11 R4), not something we fix here.
- **No retroactive re-billing.** Flags are forward-only from the migration; we do not reclassify historical rows or refund past cap-outs beyond the manual operator restore.

## 4. Target Users & Personas

| Persona | Who | Job-to-be-done | Today's pain |
|---|---|---|---|
| **Free SMB with printed assets ("Ravi", café owner)** | 1 workspace, 3 dynamic QRs on table tents, 2,000 scans/mo cap | Table tents keep working | A 2,000-request script kills every table tent for the rest of the month. He has no idea why, and no way to prove it wasn't real traffic |
| **Agency analyst ("Priya")** | Agency tier, reports campaign performance to end clients | Numbers she can defend in a client meeting | A bot crawl inflates a campaign's scans 4×; her conversion rate collapses; she cannot explain it or exclude it |
| **Conference/booth marketer ("Tom")** | Pro tier, one QR on a booth backdrop | 600 scans in 3 hours at peak, all genuine | **The false-positive victim.** Every naive per-IP threshold flags his best-performing event as an attack |
| **Restaurant at dinner rush ("Maya")** | Starter, table-tent QRs on venue Wi-Fi | 200 scans/hour from one NAT'd IP | Same as Tom, but sustained and daily. Carrier-grade NAT makes hundreds of genuine phones share one `ip_hash` |
| **Support / operator (us)** | Fields "my QRs stopped working" tickets | Diagnose and restore in minutes | No signal to look at. No way to tell a flood from a viral moment. No restore button — only a monthly cron |
| **The attacker** | Competitor, disgruntled ex-customer, script kiddie | Take a victim's QRs offline | Succeeds today for the cost of one shell loop |

Note that **two of the six personas are false-positive victims, and one of them is the highest-value real usage pattern we have.** That ordering is deliberate and drives §11 R1.

## 5. User Stories

- As a **Free customer**, I want a flood against my QR to not take my printed table tents offline, so that a stranger cannot destroy my physical marketing for the price of a script.
- As a **customer whose scans were excluded**, I want to see exactly how many, on which QR, on which day, and why, so that I can check the claim against reality instead of trusting a black box.
- As an **agency analyst**, I want automated traffic excluded from the funnel and rollups by default, so that the conversion rate I present to my client is defensible.
- As a **booth marketer**, I want 600 genuine scans in three hours at a trade show to be counted in full, so that our best event of the year doesn't get written off as fraud.
- As a **restaurant owner**, I want 200 scans/hour from one venue Wi-Fi IP to count as 200 scans, so that being busy is not treated as an attack.
- As a **workspace owner**, I want to be told when we detect suspicious traffic on my QR *and* to know my codes are still live, so that the alert is information rather than an outage notice.
- As a **support operator**, I want to reclassify traffic, allowlist a known-good source, and restore a wrongly-capped workspace in one call, so that a false positive is a five-minute fix and not a lost customer.
- As **Qravio**, I want the flagged/clean split observable per workspace before anything is enforced, so that we can measure the false-positive rate on real traffic before it can hurt anyone.

## 6. UX / Product Flow

### 6.1 The three phenomena — different signals, different responses

Collapsing these into one "suspicious" bucket is the standard way this feature goes wrong. They are separated end to end.

| | **Bot** | **Accidental duplicate** | **Deliberate abuse** |
|---|---|---|---|
| **What it is** | Crawlers, link unfurlers (Slack/WhatsApp/iMessage previews), uptime monitors, security scanners | One person scanning the same code twice — pocket re-scan, showing a friend, re-opening the page | A flood aimed at exhausting a victim's quota or fabricating engagement |
| **Volume** | Constant, low, everywhere | Constant, low, everywhere | Rare, extreme, targeted |
| **Signals** | UA match (existing regex, widened); **datacenter/hosting ASN** (`cf.asn`, already collected); missing `Accept-Language`; no `Referer` on a link-unfurl pattern | `session_id` already seen for this `qr_id` — **already computed** as `is_unique` (`internal.py:375–392`) | Velocity per `(qr_id, ip_hash)` per minute **combined with** low session entropy; datacenter ASN at volume; UA/geo/language incoherence |
| **Confidence** | High — a datacenter ASN essentially never carries a phone-camera QR scan | Certain — it is a definitional dedupe, not an inference | Medium at best; needs corroborating signals before it means anything |
| **Response** | Flag `bot`. **Exclude from billing and analytics** (analytics already does this) | **No change.** Stays `clean`, counts toward billing, already excluded from *unique* counts | Flag `abuse`. Exclude from billing + analytics, alert the owner, **suppress auto-disable** |
| **Why that response** | It's not a scan by a person; we served a crawler, not a customer | **We rendered a real page for a real human — that is real usage and it is billable.** Deduping it away would under-count genuine engagement | The value of the flood to the victim is zero and negative; and the DoS must not reach the disable path |

The middle column is the one people get wrong: **repeat scans by the same human are not fraud and are not excluded from billing.** They already do the only thing they should do — not inflate the unique-visitor count.

A fourth flag, **`suspect`**, exists for traffic that trips a threshold without corroboration. It is written to the row and shown in operator tooling but has **no billing or analytics effect** — it exists so we can measure a rule's precision in production without that rule being able to hurt anyone. Every new rule enters at `suspect` and is promoted to `abuse` only on measured evidence.

### 6.2 What the customer sees — analytics

- On the analytics page (`qr_frontend/src/app/[slug]/(dash)/analytics/`), when the current window contains excluded scans, a single quiet line under the header: **"1,204 scans excluded as automated traffic."** with an info affordance. It is not an alarm; most workspaces will show a small nonzero number forever, because bots are ambient.
- The info popover breaks it down by reason and day: *"Automated traffic (hosting provider): 1,180 · Known crawler: 24."* No thresholds, no scores, no internal rule names — a reason a human can evaluate.
- The existing `exclude_bots` / `include_bots` query params (`scan.py:1392`, `:1753`, `:1955`, and the public API at `api_public.py:1028`) generalize to cover the new flags, keeping their current defaults. A customer who wants raw numbers can already ask for them, and that stays true.

### 6.3 What the customer sees — the attack case

When `abuse` is detected on a QR:

1. An owner email, **once per ISO week per workspace**, reusing the existing dedup ledger `_alert_once` (`internal.py:854`) with a new `alert_type` — the same mechanism that keeps `scan_cap` alerts from spamming.
2. The email says what happened *and* explicitly reassures: **"Your QR codes are still live."** Excluded scans do not count toward the plan limit. No action is needed. Reply if the traffic looks legitimate to you.
3. The QR detail page shows a dated integrity note on the affected QR. No red banners, no "SECURITY ALERT" framing — the customer did nothing wrong and is not at risk.

### 6.4 What the customer never sees

No fraud score. No confidence percentage. No rule names. No "trust level." Those invite arguments we cannot win and imply a precision we do not have.

### 6.5 Operator surface (internal, no UI in v1)

Internal-secret endpoints only (`/internal/*`, no Bearer auth — `internal.py:21–35`), driven by curl or a runbook:

- **Reclassify** a set of scans for a `(qr_id, day)` — either direction, `clean` ⇄ flagged — with the reason recorded. Wrongly flagged traffic can be given back.
- **Allowlist** a `(workspace_id, ip_hash | asn | qr_id)` so a customer's known-good source (an office NAT, a monitoring probe they run on purpose, a venue's Wi-Fi ASN) is never flagged again.
- **Pin** a workspace against auto-disable entirely — the escape hatch for a customer under sustained attack while we investigate.
- **Restore** a wrongly-capped workspace by re-running the existing `_reenable_free_scan_disabled` logic (`internal.py:618`) for one workspace instead of waiting for the monthly cron. This is the "give them their QRs back right now" button and it is the single most important operator capability in the feature.

A UI for any of this is explicitly out of scope for v1. Frequency will be low; a runbook is honest and ships this quarter.

## 7. Scope

**In scope (v1)**

1. **Fix the meter/analytics inconsistency.** One shared billable-scan predicate used by `_enforce_scan_limit` (`internal.py:551`), `_usage_max_scans` (`subscription.py:367`), and the re-enable sweep (`internal.py:670`), so bot and abuse rows stop burning quota and the three sites can never drift.
2. **`integrity_flag` + `integrity_reason` on `qr_scan_events`**, stamped at ingest. Additive columns; no row is ever deleted or rewritten.
3. **Bot classification at ingest** — widened UA list plus **datacenter/hosting ASN** matching on the `asn` field the Worker already sends (`scan.js:54`).
4. **Velocity + entropy rules for abuse** — per `(qr_id, ip_hash)` per short window, gated on corroborating signals (§6.1), with NAT-safe thresholds (§11 R1).
5. **Circuit breaker on `_enforce_scan_limit`** — a workspace whose period is dominated by flagged traffic is alerted, never auto-disabled.
6. **Durable daily rollup** of excluded counts per `(workspace_id, qr_id, day, reason)` so the customer-facing explanation and billing reconciliation survive scan-row pruning and retention windows.
7. **Owner alert** for `abuse`, weekly-deduped via `_alert_once`, with the "your codes are still live" reassurance.
8. **Analytics disclosure line** + reason breakdown; generalize the existing `exclude_bots` params to the new flags.
9. **Operator endpoints**: reclassify, allowlist, pin, per-workspace restore.
10. **Shadow mode** as a first-class shipping state — flags written, nothing excluded, everything measured (§10).

**Out of scope / Future**

- Edge pre-filtering / suppression before the DB write *(Phase 3; needs Durable Objects or the Workers rate-limit binding — new infra, new `deploy:prod` gate)*.
- Any blocking, challenge, or CAPTCHA on the scan path *(never — hard constraint)*.
- Customer-facing self-serve allowlist/reclassify UI *(future, once volume justifies it)*.
- Cross-day / long-horizon IP reputation *(blocked by the daily-rotating edge `ip_hash`; see §11 R4)*.
- ML/anomaly-scoring models, third-party IP-reputation feeds *(future; rules first, and rules may be enough)*.
- Retroactive reclassification of pre-migration rows and refunds for historical cap-outs *(manual operator restore only)*.
- Fraud detection on lead submissions, link clicks, or form spam — `lead_submit` already has its own per-IP-hour limit (`internal.py:1331–1344`) *(separate concern)*.
- Bot/abuse exclusion from **webhook dispatch** and **milestone** fires *(strongly desirable; deferred to Phase 2 because it changes an outbound contract customers may already depend on — see §12)*.

## 8. Pricing & Packaging

| Surface | Tier | Flag |
|---|---|---|
| Scan classification, billing exclusion, circuit breaker, alerts, disclosure | **Free, Starter, Pro, Agency** | **none** |

**There is no new plan flag and no new limit key.** This is deliberate and it breaks the house reflex, so here is the reasoning:

- **The tier that needs it is the tier that can't pay for it.** `max_scans` is finite *only on Free* (`0009`: Free `2000`, all paid tiers `-1`). Gating the DoS defence behind a paid tier would protect precisely the workspaces that cannot be knocked offline and abandon the only ones that can. That is not a packaging decision, it is a decision to leave the vulnerability open.
- **Correct billing is not a feature.** Charging a customer's quota for a Googlebot crawl is a defect. We do not sell the fix for a defect.
- **The analytics half is already gated by the flags that exist.** Funnel/rollup/audience surfaces sit behind `advanced_analytics`; cleaner inputs make those better without a new entitlement.
- **A flag would be a liability.** `FEATURE_ENFORCEMENT` + `test_feature_gate_coverage` would then require a `scan_fraud_detection` key seeded across every tier, and a `false` value on any tier would mean "this workspace's meter is knowingly wrong." There is no defensible value for that key other than `true` everywhere — which is the same as no key.

Consequence: **zero `plans.features` changes, zero `FEATURE_ENFORCEMENT` changes, `test_feature_gate_coverage` unaffected, no `PlanFeatures` field, no `canAccessFeature` call.** Thresholds and overrides are operator configuration in a dedicated table (§6.5), not entitlements.

**The commercial argument for doing it anyway:** Free is our top-of-funnel and it is currently weaponizable against the customers we most want to convert. One public incident — "someone killed my restaurant's QR codes and Qravio's answer was *upgrade*" — costs more than this feature does. Meanwhile every paid analytics surface gets more trustworthy inputs for free.

## 9. Success Metrics & KPIs

**Correctness (the point of the feature)**

- **0 workspaces auto-disabled where flagged traffic exceeded the circuit-breaker share** of the period. This is the primary KPI; any occurrence is a P1.
- **100% agreement** between the three scan-counting sites (`_enforce_scan_limit`, `_usage_max_scans`, re-enable sweep) on whether a workspace is over cap — asserted by test and by a periodic reconciliation check.
- **0 scan rows deleted or mutated** by this feature. *(Invariant.)*

**False positives (the dominant risk — measured, not assumed)**

- **False-positive rate < 0.1% of scans** on a hand-labelled review set built from real traffic during shadow mode, and **specifically including** a trade-show burst, a restaurant dinner rush, a corporate-NAT office, and a classroom (§10 gate).
- **0 workspaces** where flagged share exceeds 20% of period scans without an operator reviewing it within 24h during Phase 1.
- **Reclassification rate < 1 per 1,000 flagged workspace-days** after Phase 2 — every operator reclassification is a logged false positive and the trend is the health metric.
- **Trade-show canary:** a labelled high-density genuine event ends the day with **≥ 99% of its scans `clean`**.

**Detection (secondary — a low number here is fine; a high false-positive number is not)**

- Datacenter-ASN traffic classified at **≥ 95%** against a labelled sample (highest-precision rule; if this isn't near-perfect the ASN list is wrong).
- Synthetic red-team flood against a seeded Free workspace: **quota not exhausted, QRs stay `active`, owner alerted** — the end-to-end acceptance test.

**Cost / performance**

- **`POST /internal/scans` p95 latency +≤ 15 ms** vs baseline. The scan write path is `ctx.waitUntil`-detached (`scan.js:75`) so this is not user-visible, but it is the per-scan cost ceiling.
- **≤ 1 additional DB round-trip per scan** in steady state.
- Excluded-scan volume as a share of total: expected low single-digit % platform-wide. A step change is itself an incident signal.

## 10. Rollout Plan

**Phase 0 — Meter consistency + shadow classification (no behaviour change to enforcement).**
Ship the migration (columns, rollup table, overrides table, indexes), the classifier, and the ingest stamping. **Nothing is excluded from anything yet.** The only live change is that classification runs and rollups accumulate.
*Gate to Phase 1:* two weeks of production data; flagged-share distribution reviewed across the full workspace population; the ASN list validated against real traffic; **the four false-positive scenarios (trade show / restaurant rush / corporate NAT / classroom) located in real data and confirmed `clean`.**

**Phase 1 — Enforcement, narrowest slice first.**
Switch on exclusion for **`bot` only** — the highest-confidence class and the one that fixes the existing meter/analytics inconsistency. Land the circuit breaker (which is a pure safety addition and can go live immediately). Ship the analytics disclosure line and the operator endpoints.
*Acceptance:* a bot-flagged scan does not increment billable usage on any of the three counting sites; a workspace with mostly-flagged traffic is not disabled; a customer can see the excluded count and its reason; an operator can reclassify, allowlist, pin, and restore.
*Gate to Phase 2:* one full billing period with zero reclassification requests attributable to bot exclusion.

**Phase 2 — Abuse-class enforcement.**
Promote velocity/entropy rules from `suspect` to `abuse` **one rule at a time**, each measured in `suspect` for at least one full period first. Owner alerting goes live. Extend exclusion to webhook/milestone dispatch (contract change — announce first).
*Gate:* per-rule precision measured in `suspect` mode before promotion. A rule that cannot demonstrate precision in shadow does not get promoted, full stop.

**Phase 3 (deferred, conditional) — Edge pre-filter.**
Only if measured volume justifies it. Requires Durable Objects or the Workers rate-limit binding — new infra, and a **hard `npm run deploy:prod` gate** (cron/binding registration, per `wrangler.toml`). Not in this spec's commitments.

**Cross-service gates:**
- **No Worker change in v1** → no `deploy:prod` gate, no KV migration, no template↔React mirroring.
- **Email:** the owner alert reuses the existing `send_alert_email` path (`src/utilities/email.py`), already in production for `scan_cap`. Per the standing mail note, `_dmarc.qravio.app` remains unpublished — a deliverability risk this feature inherits rather than creates. The alert is not a launch blocker for exclusion (exclusion is the protection; the email is the courtesy).
- **Migration must be applied by hand in the Supabase SQL editor before the backend deploy** (no automated runner — `migrations/README.md`).

## 11. Risks, Edge Cases & Open Questions

**R1 — False positives are the dominant risk and the design driver. (Top risk.)**
The legitimate patterns that look *exactly* like an attack are our best customers' best days:

| Scenario | What it looks like | Why a naive rule kills it |
|---|---|---|
| Trade-show booth | 600 scans in 3 hours, one venue Wi-Fi | One `ip_hash`, extreme velocity |
| Restaurant at dinner rush | 200 scans/hour, nightly, one NAT | Same shape, sustained, recurring |
| Bus-shelter poster | Bursts on mobile carrier CGNAT | Hundreds of genuine users share one carrier IP |
| Classroom | 40 scans in 90 seconds, one school Wi-Fi | Highest instantaneous velocity in the product |
| Corporate office | All-day scans from one NAT | Long-horizon single-IP concentration |

Carrier-grade NAT and corporate NAT mean **hundreds of genuine users legitimately share one `ip_hash`**. A per-IP threshold on its own does not distinguish "busy" from "attacked", and busy is the state we are paid to produce.

**Mitigations, in order of strength:**
1. **ASN class is the primary discriminator, not volume.** A hosting/datacenter ASN carrying phone-camera QR scans is close to impossible; a consumer or mobile ASN carrying a burst is a Tuesday. Traffic on a consumer/mobile ASN is **never flagged on volume alone**, at any velocity. *Caveat, and it matters:* corporate VPN and SASE egress (Zscaler, Netskope, Cloudflare WARP, corporate cloud NAT) presents genuine human scans on datacenter-ish ASNs with entirely normal browser UAs. So the ASN rule is never used bare — it requires a second, non-human-shaped signal (§ TRD 3.2), and known SASE/consumer-VPN ASNs are explicitly excluded from the hosting set.
2. **Velocity is only ever a corroborating signal**, never sufficient by itself.
3. **Session entropy separates a crowd from a script.** A NAT crowd behind one `ip_hash` produces many distinct `session_id`s (`session_id = hash(ip:ua:day)`); a single scripted client produces one. *Honest limitation:* forty identical iPhones on identical iOS versions on one Wi-Fi collapse into **one** `session_id` — the same reason `is_unique` already under-counts at trade shows. So entropy is evidence, never proof, and thresholds are set high enough that the classroom case survives even at worst-case collapse.
4. **Shadow mode is a hard gate** (§10). No rule enforces before its precision is measured on production traffic, and the four scenarios above must be located in real data and confirmed `clean`.
5. **Asymmetric costs are encoded in the defaults.** Missing an attack costs a Free customer one month's cap. Falsely flagging costs a paying customer their best campaign's numbers and our credibility. Thresholds are set conservatively in that direction, and every rule enters at `suspect`.
6. **Operator reclassify + allowlist** (§6.5) make a false positive a five-minute fix.

**R2 — Excluding flagged scans from billing creates a quota-evasion incentive.**
If flagged scans don't count, could a Free customer farm free quota by making their own traffic look bot-like? In practice, no: the flag is applied to traffic that got **no human value** — a datacenter-ASN request still receives the landing page, so nothing is withheld. To "evade" the cap the customer would have to route real customers' scans through a hosting provider, which requires those customers to be bots. The quota exists to price value delivered; a crawler received no value. **Mitigation:** monitor flagged-share per workspace as an abuse signal in its own right — a workspace at 95% flagged for months is either under sustained attack or gaming us, and both warrant a human look. *(This is why the flagged-share metric is a KPI, not just a debug stat.)*

**R3 — The circuit breaker can be abused to escape the cap.**
If "mostly flagged ⇒ never disable" is unconditional, an attacker (or the customer) can flood a workspace to make its own real overage unenforceable. **Mitigation:** the breaker suppresses the *automatic* disable and raises an operator alert; it does not grant unlimited scans. Clean scans continue to accrue and a workspace over cap **on clean scans alone** is disabled normally, breaker or no breaker. The breaker only ever prevents *flagged* traffic from causing the disable.

**R4 — The edge `ip_hash` is unsalted, truncated, and rotates daily. (Verified; corrects a common assumption.)**
The scan path does **not** use `settings.HASHING_SALT`. That salted hash at `internal.py:1332` is the **lead-submit** path. The scan `ip_hash` is computed at the edge: `hashString(`${ip}:${today}`)` (`scan.js:37`), where `hashString` is SHA-256 truncated to **16 hex chars** (`scan.js:8–14`), **unsalted**, with a UTC-date component. Consequences we must design around:
- **Stable per-IP key within a UTC day only.** Every rule in v1 is a within-day rule. Cross-day IP reputation is impossible without changing the edge derivation, which would break the shipped scan↔lead↔click session join (`scan.js:16–24`).
- **Midnight-UTC discontinuity.** A flood spanning midnight UTC splits across two hash spaces. Accepted for v1; a real attack rarely lasts long enough for this to matter, and the daily rollup still sees both halves.
- **The raw IP is available only at the edge.** The backend's `request.client.host` at `POST /internal/scans` is Cloudflare's egress, not the visitor's. **Confirmed: every per-IP signal in this spec must work on the hash.** This is the strongest single argument for eventually moving some detection to the edge — and the reason we don't need to yet, because the daily hash is sufficient for within-day burst detection.
- **Privacy, stated honestly:** an unsalted, truncated SHA-256 of an IPv4 address is **not anonymization**. The IPv4 space is 2³², brute-forceable in seconds; `ip_hash` is pseudonymous personal data under GDPR and should be described as such internally and in the DPA. The daily rotation limits linkability across days, which is a genuine but partial mitigation. **Remediation (out of scope here, worth its own ticket):** add a second `ip_hash_stable` at the edge salted with a Worker secret, kept alongside the existing field so the session join is preserved. This spec does not change the edge and does not make the privacy position worse — but it does make us *rely* on that field, so we should stop describing it as anonymized.

**R5 — Detection cost on the hot path.** `POST /internal/scans` already performs several Supabase round-trips per scan (uniqueness check, insert, counter read, counter write, scan-limit count). Naively counting recent rows per `(qr_id, ip_hash)` is O(n) *under exactly the flood we're defending against* — the detector becomes the amplifier. **Mitigation:** velocity uses an O(1) bucketed counter with an atomic increment-and-return (mirroring `increment_ai_usage`), never a growing-window `count(*)`; the billable-scan count uses a partial index; the pruning of expired velocity buckets rides the existing production cron (`wrangler.toml` `[env.production.triggers]`), not a new one.

**R6 — Three counting sites drifting apart.** `_enforce_scan_limit` (`internal.py:551`), `_usage_max_scans` (`subscription.py:367`), and `_reenable_free_scan_disabled` (`internal.py:670`) each count scans independently today. If they apply different predicates, a workspace can be disabled by one and never re-enabled by another — a **permanent** outage, because a disabled QR gets zero edge traffic and can never re-trigger enforcement (`internal.py:622–624`). **Mitigation:** one shared helper, three call sites, and a test that asserts all three agree. This risk exists in latent form today and this feature must not deepen it.

**R7 — Attacker adaptation.** Published rules invite evasion: rotate UAs, use residential proxies, pace below thresholds. **Mitigation:** we do not publish thresholds or rule names (§6.4); a paced-below-threshold attack takes far longer and costs far more; and the circuit breaker is the backstop regardless of whether classification succeeded — it triggers on the *shape* of the period, not on any individual rule.

**R8 — Retention destroys the evidence.** `analytics_retention_days` is 7 on Free — the tier most likely to be attacked and most likely to dispute. It is currently a **read clamp**, not a delete (`_retention_cutoff_iso`), but the concurrent retention spec may make it a real delete. **Mitigation:** the durable daily rollup (§7.6) carries excluded counts and reasons independently of the raw rows, so the customer-facing explanation and any billing dispute survive row pruning.

**R9 — Timing of the counter update.** `qr_scan_counters` (`internal.py:396–465`) is written before scan-limit enforcement and feeds the dashboard. If flagged scans are excluded from billing but still increment `total_scans` there, the dashboard and the usage meter will disagree and the customer will notice. **Mitigation:** resolved in the TRD; the PRD's requirement is simply that **every customer-visible scan number tells the same story** and that any deliberate divergence (e.g. lifetime totals vs billable period usage) is labelled.

**Open Questions**

1. **Do flagged scans count toward `max_scans`?** — *The most consequential decision in this spec.* **Recommend: no, flagged scans do not count.** Excluding is the entire point: if flagged scans still count, we have detected the attack and prevented none of the harm. Precedent already exists in the analytics read path (`exclude_bots=True` by default). The evasion risk is answered in R2, and the "customer farms free quota" case is bounded because a flagged request delivered no human value. **The circuit breaker (§7.5) is the real protection and it must ship even if this answer is ever reversed** — the two are independent, and if we ever decide flagged scans should count, the breaker still prevents the DoS.
2. **Circuit-breaker threshold?** *Recommend: flagged share of the current period materially above that workspace's own established baseline, with an absolute floor so a low-traffic workspace can't trip on three bot hits.* Exact number set from shadow-mode data, not guessed now.
3. **Should `bot` exclusion be retroactive to existing rows?** *Recommend no.* Rows predate the flag; a retroactive `device_type='bot'` sweep would silently change historical usage numbers customers may have already seen. Forward-only, stated in the disclosure.
4. **Alert on `suspect`, or only on `abuse`?** *Recommend `abuse` only.* Alerting on unenforced classifications trains customers to ignore our email.
5. **Exclude flagged scans from webhook/milestone dispatch?** *Recommend yes, but in Phase 2* — it changes an outbound contract customers' automations may already depend on, so it needs an announcement, not a silent behaviour change.
6. **Should the analytics disclosure be visible on Free?** *Recommend yes, ungated.* Free is the tier that gets attacked; hiding the explanation from them defeats the purpose.

## 12. Dependencies

- **Scan ingest path (shipped):** `POST /internal/scans` → `record_scan_event` (`internal.py:350–529`), fed by `ctx.waitUntil(recordScan(...))` (`scan.js:26–88`, dispatched from `index.js:415`). This is where classification lands.
- **Signals already collected (shipped, no Worker change needed):** `asn`, `country_code`, `ip_hash`, `session_id`, `user_agent`, `device_type`, `referer`, `language`, `timezone` — all already on `ScanEventPayload` (`internal.py:329–347`) and already written by the Worker (`scan.js:44–62`). **We are reusing existing signals, not adding new collection.** *(No new PII, no consent-posture change.)*
- **UA parsing (shipped):** `src/utilities/ua_parser.py` + `tests/unit_tests/test_ua_parser.py` — reuse for UA coherence checks; do not write a second parser.
- **Device dedupe (shipped):** `is_unique` (`internal.py:375–392`) — already handles the "accidental duplicate" class. Not re-implemented.
- **Plan/limits engine (shipped):** `resolve_plan`, `period_start_iso`, `_limit_value`, `check_limit`, `_usage_max_scans` (`subscription.py`). The billable-scan predicate plugs into these.
- **Scan-limit enforcement + restore (shipped):** `_enforce_scan_limit` (`internal.py:532`), `_reenable_free_scan_disabled` (`internal.py:618`), `POST /internal/free-scan-reset` (`internal.py:719`). The circuit breaker and operator restore build directly on these.
- **Alert dedup ledger (shipped):** `_alert_once` (`internal.py:854`) + `alert_events` + `_fire_scan_cap_alert` (`internal.py:896`) + `send_alert_email`. Reused verbatim with a new `alert_type`.
- **Analytics read path (shipped):** `scan.py` `exclude_bots`/`include_bots` (`:1392`, `:1753`, `:1955`) and `api_public.py:1028` — generalized, not replaced.
- **Existing cron (shipped):** `wrangler.toml` `[env.production.triggers]` — velocity-bucket pruning rides an existing schedule. **No new cron, so no `deploy:prod` gate.**
- **`RATE_LIMITING_{PRD,TRD}` (concurrent, separate spec) — boundary:** that spec owns request throttling on the **public API and auth endpoints**; this spec owns the **scan path** (`/:shortCode` → `/internal/scans`) and only the scan path. No shared code, no shared tables, no shared config. If platform-level throttling of scan traffic is ever needed it belongs there, as infrastructure; the classification of a scan that *was* served belongs here. *(Duplicated ownership of the scan path between the two specs is a merge hazard — this sentence is the contract.)*
- **No new external service, no AI, no new env var, no new npm/PyPI dependency.**

### Migration decision — ship `0047`

A migration is required: two additive columns on `qr_scan_events`, a durable rollup table, an overrides/config table, a velocity-bucket table with its atomic increment RPC, and the supporting indexes. **No `plans.features` change and no `FEATURE_ENFORCEMENT` change** (§8), so `test_feature_gate_coverage` is untouched — unusually simple for a migration in this codebase.

**Slot `0047_scan_fraud_detection.sql` is provisional and must be re-verified against `qr_backend/migrations/` at build time.** Highest on disk today is `0032_lemonsqueezy_variant_backfill.sql`; `0033`–`0043` are claimed by drafted-but-unapplied specs and `0044`–`0046` by concurrently drafted ones. Roadmap slot tables in this repo have gone stale before — `AI_BUSINESS_CARD_OCR` was drafted for `0024` and shipped as `0026` for exactly this reason. **Check the directory, not this document.**

### Appendix — Key Files

| Concern | File |
|---|---|
| Scan ingest (classification lands here) | `qr_backend/src/api/routes/internal.py` (`record_scan_event`, `:350–529`) |
| Billing enforcement + circuit breaker | `qr_backend/src/api/routes/internal.py` (`_enforce_scan_limit`, `:532`) |
| Re-enable / operator restore | `qr_backend/src/api/routes/internal.py` (`_reenable_free_scan_disabled` `:618`, `free_scan_reset` `:719`) |
| Usage meter (second counting site) | `qr_backend/src/api/routes/subscription.py` (`_usage_max_scans`, `:367`) |
| Today's entire defence (one regex) | `qr_cf_code/src/utils/scan.js:2` (`detectDevice`) |
| Edge `ip_hash` / `session_id` derivation | `qr_cf_code/src/utils/scan.js:8–24`, `:37` |
| Signals already sent by the edge | `qr_cf_code/src/utils/scan.js:44–62` (incl. `asn`) |
| Alert dedup ledger + scan-cap alert | `qr_backend/src/api/routes/internal.py` (`_alert_once` `:854`, `_fire_scan_cap_alert` `:896`) |
| UA parser to reuse | `qr_backend/src/utilities/ua_parser.py`, `tests/unit_tests/test_ua_parser.py` |
| Analytics bot exclusion to generalize | `qr_backend/src/api/routes/scan.py` (`:599`, `:1357`, `:1392`, `:1641`, `:1753`, `:1955`), `api_public.py:1028` |
| Plan seed / current `max_scans` values (**authority**) | `qr_backend/migrations/0009_pricing_v3_4tier_collapse.sql:97` (Free `2000`, paid `-1`) |
| Stale 500-scan values — **not** sources of truth | `qr_backend/migrations/0005_pricing_v2_dual_currency.sql:59` (superseded), `0007_billing_foundations.sql:24` (stale comment, fix in passing), `tests/unit_tests/test_limits_engine.py:20` (arbitrary fixture) |
| Scan-cap UI (disclosure sits nearby) | `qr_frontend/src/components/org/ScanLimitAlert.tsx`, `components/org/UsageTracker.tsx` |
| Analytics surface for the disclosure line | `qr_frontend/src/app/[slug]/(dash)/analytics/`, `src/components/org/analytics/AnalyticsHeader.tsx` |
| Migration | `qr_backend/migrations/0047_scan_fraud_detection.sql` (new; **slot provisional**) |
