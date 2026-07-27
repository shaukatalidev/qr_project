# PRD — Loyalty / Digital Stamp Card (merchant-authorized stamping)

**Status:** Draft · **Author:** Product · **Date:** 2026-07-25
**Priority:** Genuinely India-native retention play — cafes, salons, and neighbourhood retail already run paper punch-cards, so the behaviour needs no education. But it is the **heaviest** item in the competitive backlog (XL) because the hard part is not the card, it is **anti-fraud stamping**: an edge scan is anonymous, so "increment on scan" is farmed in ten seconds. Build it **inside** the Wallet Passes epic, sequenced **after** WhatsApp review reminders (analysis item #1) so the re-engagement payoff has a channel.
**Tiers:** **Pro + Agency** — `loyalty_cards` (bool) + `loyalty_members_max` (int cap per workspace). QR *type* membership follows the `lead_form` precedent from `0027_open_all_qr_types.sql`: `loyalty` is added to `dynamic_qr_types` **only** for Pro/Agency and is **double-gated** by the boolean, because unlike other types this one carries per-member PII, staff credentials, and outbound-message COGS.
**Plan flags:** `loyalty_cards` (bool, NEW) + `loyalty_members_max` (int limit, NEW). Both seeded as a **full-object `'{...}'::jsonb` blob** (so `test_feature_gate_coverage._seed_feature_keys()` discovers them) and registered `inert`→`enforced` in the **same PR** (house convention).
**Split from:** the **Wallet Passes epic** (`WALLET_PASSES_PRD.md` / `WALLET_PASSES_TRD.md`), which already reserves a `loyalty` sub-type and a `qr_loyalty_details` table. This PRD **folds into** that epic — it does not duplicate it. It supplies the two things the Wallet spec hand-waves: (1) the **merchant-authorized stamping flow** (WALLET_PASSES_TRD §3.1 says "loyalty stamp bump" with no mechanism), and (2) a **re-engagement channel that works on Android** (Wallet's payoff is APNs/PassKit push, Apple-skewed, in a ~95%-Android market). It also **corrects** a modelling bug in the Wallet schema: `qr_loyalty_details.stamps_current` (WALLET_PASSES_TRD §2 table 4) is per-QR, but stamp state is inherently **per-customer**.

**Rev (2026-07-25, post eng-review):** Reviewed via `/plan-eng-review` + an outside-voice pass; **5 blockers found and the shape changed twice.** **(A) v1 = "Stamp v0": OTP and WhatsApp are CUT.** OTP defended *identity farming*, which merchant-authorized stamping already closes (phantom members still need 10 staff-authorized stamps each; Open Q3 refuses an enrolment bonus, so phantom enrolment has zero payoff). Ship the type + details + members (**device-cookie identity, phone optional and unverified**) + staff-PIN console + ledger + staff-authorized redemption + cooldowns/caps/idempotency/reversal. Cut OTP, `qr_loyalty_otps`, all WhatsApp triggers, the lapsed sweep + cron, TOTP/Fernet/`LOYALTY_ENC_KEY`, and `loyalty_members_max`. **M-sized, zero dependency on item #1 or Wallet** — and it tests the only thing that actually kills the feature: whether counter staff use the console under a queue. **(B) Loyalty OWNS the `loyalty` type; the Wallet TRD must be amended** to drop `stamps_current` and its duplicate `qr.py`/KV/template claims (Wallet keeps `.pkpass`/APNs only). **The item-#1 dependency is REMOVED, not merely re-sequenced** — that spec ships **no OTP primitive** (zero mentions; a 30-min minimum queue delay cannot carry a 10-min OTP TTL; Meta's authentication category is never priced there) and names loyalty re-use as an explicit non-goal, so waiting on it bought only opt-out plumbing while hostaging loyalty to item #1's own `<4%` kill gate. **Consequently §8's Pro-gating rationale is void** — under BYO-WABA the merchant pays for messages, so "loyalty carries real marginal cost" is false; re-argue the tier on PII/staff-credential/support grounds or reconsider it. Full blocker list and all technical corrections are in the TRD Rev.

**Fold note (read this first).** Everything in `WALLET_PASSES_*` about the `loyalty` sub-type — the type Literal, `qr_loyalty_details`, the 7-step new-type seam, the `storeCard` PassKit style, the `wallet_passes` flag — remains **owned by the Wallet epic**. This spec is **additive**: the member/stamp/staff data model, the stamping authorization flow, the staff console, the WhatsApp re-engagement triggers, and the two new plan flags. It is deliberately structured so **Phase A (web stamp card + WhatsApp) ships without any Apple cert infrastructure**, and the Wallet `.pkpass` becomes a purely additive Phase B. That de-risking is the main reason to spec loyalty separately at all.

---

## 1. TL;DR / Summary

A Pro/Agency merchant creates a **`loyalty`** dynamic QR: "buy 9 get 1 free", 10 stamps, a reward. A customer
scans the poster, enrols **once** with their phone number (consented, **OTP-verified**), and gets a personal
stamp card at a stable URL that lives behind a cookie on the merchant's short-code origin — scan the poster
again next month and their own card comes up.

**Stamps are never granted by scanning.** A stamp is a **merchant-authorized** action:

- **Mode A — Staff console (default).** Staff open a public, PIN-authenticated console on their own phone,
  scan the customer's member code (or type their phone), and tap **Stamp**. The authority lives on the
  *merchant's* device, which is the only arrangement a customer cannot farm.
- **Mode B — Rotating counter code (opt-in, weaker).** For merchants who won't put a device in the loop, the
  console displays a **6-digit code that rotates every 60 seconds** (TOTP over a per-QR secret). The customer
  enters it on their own phone. A photographed code is valid for at most one rotation and is single-use per
  member. Documented in-product as the weaker tier.

Every stamp lands in an **append-only ledger** (`qr_loyalty_events`) carrying who authorized it, under which
mode, from which IP hash, with an idempotency key — plus universal guards (per-member cooldown, per-day cap,
per-staff-session cap) that hold in **both** modes. Reversal writes a compensating row; nothing is ever
deleted. All counting happens in **one atomic Postgres RPC on the backend** — the Cloudflare Worker holds no
secret, does no counting, and only proxies the customer-facing POSTs exactly as it already proxies
`/pw-verify/:shortCode`.

The **payoff is WhatsApp, not wallet push**: "one stamp from your free coffee", "your reward is ready",
"we haven't seen you in 45 days" all ride analysis item **#1**'s consented-phone + delayed-send-queue
infrastructure. Apple Wallet remains a nice-to-have Phase B for the iOS minority.

**Today we ship a lie.** `qr_cf_code/src/pages/coupon/stampTemplate.js` renders a beautiful stamp card that
is **hardcoded to 0/6 for every visitor, forever** (`const STAMPS = [false,false,false,false,false,false]`,
L14). It is cosmetic. This feature makes it real — and until it does, we should be honest that the existing
`coupon_stamp` template is a picture of a loyalty card, not a loyalty card.

## 2. Problem & Motivation

**The behaviour already exists on paper.** Walk into any Indian cafe, salon, tiffin service, or car-wash and
there is a paper punch-card in a drawer. It is lost, forged with a borrowed rubber stamp, and gives the
merchant zero data about who is coming back. This is the rare feature where we do not have to teach the
market anything — we have to be *better than a card and a stamp*, which is a low bar on convenience and a
high bar on trust.

**Our current answer is cosmetic and slightly dishonest.** The `coupon_stamp` template
(`qr_cf_code/src/pages/coupon/stampTemplate.js`) exists, looks good, and is wired into the coupon dispatcher
(`qr_cf_code/src/pages/coupon/index.js`, `HANDLERS.coupon_stamp`). It has **no state**: line 12's own comment
says *"No per-customer stamp field exists — render an empty 'start collecting' card rather than fabricating
progress"*. Every scanner, forever, sees 0/6 and a "Claim Reward" button that does nothing. A merchant who
picks that template today is showing customers a prop.

**The Wallet epic assumed the hard part away.** `WALLET_PASSES_TRD.md` §1 and §3.1 describe a "loyalty stamp
bump" that bumps `update_tag` and pushes via APNs — but never says **who is allowed to bump it**, and its
`qr_loyalty_details.stamps_current` column models the count as a property of the *QR* rather than of the
*customer*. Those two gaps are the entire feature. Without them you get a shared counter that any scanner can
advance: not a loyalty program, a public tally.

**Anti-fraud is the whole engineering problem.** A dynamic QR scan at our edge is anonymous and
device-derived (`computeSessionId` in `qr_cf_code/src/utils/scan.js` is `SHA-256(IP+UA+today)` — deliberately
non-identifying). Any design of the form "scan the poster → +1 stamp" is farmed by scanning ten times, or by
one customer walking the queue with their phone. There are **two orthogonal fraud vectors** and they need
different answers:

| Vector | What it is | The only real fix |
|---|---|---|
| **Identity farming** | One person claims to be many customers to multiply rewards | Phone-number identity, **OTP-verified at enrolment** |
| **Presence / transaction farming** | One real customer stamps without buying anything | **Merchant-side authorization** on every stamp (staff PIN or rotating counter code) |

OTP alone does not stop a verified customer self-stamping from their sofa. Merchant authorization alone does
not stop one person enrolling 40 phantom members. We need both, at different steps. Everything else —
cooldowns, caps, ledgers — is defence in depth, not the mechanism.

**Why now, and why after item #1.** The reward loop is worthless without a way to reach the customer. Wallet
push (`WALLET_PASSES_PRD.md` §1) is PassKit/APNs — excellent on iOS, ~5% of our market. The channel Indian
SMBs and their customers actually live on is **WhatsApp**, which analysis item #1 (WhatsApp review reminders)
builds: consented phone capture, opt-out handling, a BSP template pipeline, and a delayed-send queue. Loyalty
is that infrastructure's second customer. Building loyalty first would mean building half of item #1 badly.

## 3. Goals & Non-Goals

**Goals**
- Ship a **real** `loyalty` dynamic QR with **per-customer** stamp state, replacing the cosmetic
  `coupon_stamp` template's fiction with an actual card.
- **Merchant-authorized stamping only.** No code path anywhere grants a stamp from an anonymous edge scan.
  Two authorization modes (staff PIN console; rotating counter code), staff-PIN being the default.
- **OTP-verified phone enrolment** with explicit DPDP-grade consent, producing a member identity that is
  **also** the WhatsApp handle — one consent capture serving both purposes.
- An **append-only stamp ledger** with anti-fraud metadata (auth mode, staff identity, IP hash, idempotency
  key) that a merchant can audit and reverse, and that a support agent can use to settle a dispute.
- **Staff-authorized redemption** with a single-use redemption code and a merchant-chosen reset/rollover
  policy — a customer must never be able to self-redeem.
- **WhatsApp re-engagement** on three triggers (near-reward, reward-ready, lapsed) riding item #1's queue.
- **Ship Phase A without Apple.** The web stamp card + WhatsApp loop must be independently shippable; the
  `.pkpass` `storeCard` is additive.
- Correct the Wallet epic's per-QR `stamps_current` modelling and feed that correction back.

**Non-Goals**
- **No stamping at the edge, ever.** The Worker holds no PIN, no TOTP secret, and no counter. It proxies
  customer POSTs to the backend (the `/pw-verify/:shortCode` pattern, `qr_cf_code/src/index.js` L98–133) and
  nothing more. *(A Worker that could stamp is a Worker whose secret leaking mints free coffee.)*
- **No stamp on scan.** Not as an option, not behind a merchant toggle, not "for low-risk merchants." The
  moment it exists it becomes the default and the ledger becomes noise. *(This is the one hard invariant.)*
- **No payments, no POS integration, no purchase verification** in v1. We authorize on *staff attestation*,
  not on a verified transaction. Tying a stamp to a real bill means a POS integration and, for UPI, the
  settlement rabbit-hole the gap analysis explicitly skips.
- **No customer login / account.** Identity is a verified phone plus an opaque member token. Nobody creates a
  Qravio password to collect coffee stamps.
- **No points / tiers / spend-based accrual** in v1 — stamps only, one visit one stamp. Points economies need
  a purchase amount, which we don't have.
- **No cross-QR or cross-workspace member graph.** A member belongs to one loyalty QR. A shared customer
  identity across a merchant's outlets is a Phase C question, and a DPDP question before it is a schema one.
- **No PII in KV.** Member phones, tokens, stamp counts, PINs, and TOTP secrets never enter the KV value.
- **No Apple/Google Wallet dependency for Phase A.** (Phase B, owned by the Wallet epic.)
- **No SMS fallback in v1** if item #1 ships WhatsApp-only — loyalty inherits whatever channel #1 delivers,
  and does not build a second one.

## 4. Target Users & Personas

| Persona | Who | Job-to-be-done | Today's pain |
|---|---|---|---|
| **Cafe Owner ("Nikhil")** | Runs two coffee outlets, on Pro | Replace the paper punch-card with something staff can't lose and customers can't forge | Cards are lost weekly; a borrowed stamp forges a free coffee; zero data on who returns |
| **Counter Staff ("Divya")** | Barista, uses their own phone, high turnover | Stamp a customer in under 5 seconds without logging into anything | A dashboard login per staff member is a non-starter; they need a PIN, not an account |
| **Salon Owner ("Farida")** | Single chair, no staff device at the counter | Let the customer stamp themselves *without* it being farmable | Won't hold a phone during a service; needs the counter-code mode |
| **The Customer ("Ashwin")** | Regular, Android, no Qravio account | Collect stamps without an app or another password, and be told when the reward is ready | Paper card is at home; nobody tells them they're one stamp away |
| **Agency Owner ("Priya")** | Runs campaigns for ~25 SMB clients (Agency tier) | Stand up branded loyalty programs per client and show retention lift | No loyalty product to sell; loses the retail brief to Uniqode |

Primary buyer is the **repeat-visit SMB on Pro** (F&B, salon, wellness, neighbourhood retail). The
differentiating detail is that **Divya, not Nikhil, is the daily user** — the staff console's usability under
a queue is the feature's real adoption gate.

## 5. User Stories

- As a **cafe owner**, I want stamps that only my staff can grant, so that a customer cannot farm free
  coffees by scanning my poster ten times.
- As **counter staff**, I want to enter a 4-digit PIN once at the start of my shift and then stamp customers
  in two taps, so that I'm not fighting an app while five people wait.
- As **counter staff**, I want to undo a stamp I just gave the wrong person, so that a mistake is a
  correction and not a dispute.
- As a **salon owner with no counter device**, I want the customer to stamp themselves using a code that
  changes every minute on my display, so that I get most of the fraud protection without holding a phone.
- As a **customer**, I want to enrol once with my phone number and never create an account, so that joining
  costs me ten seconds.
- As a **customer**, I want to scan the same poster next visit and see *my* card with *my* stamps, so that I
  don't have to remember a link.
- As a **customer**, I want a WhatsApp message when I'm one stamp away and when my reward is ready, so that I
  actually come back and claim it.
- As a **customer**, I want to stop the messages with one word, so that the loyalty program never becomes
  spam I can't escape.
- As a **merchant**, I want a visible ledger of every stamp — who authorized it and when — so that I can
  settle a "your staff didn't stamp me" argument in one look.
- As a **merchant**, I want redemption to require my staff's authorization and burn a single-use code, so
  that one completed card cannot be redeemed twice.
- As **Qravio**, I want the stamp path to be un-farmable *by construction* rather than by heuristic, so that
  our first loyalty customer's program doesn't get drained in week one and take the reputation with it.

## 6. UX / Product Flow

**6.1 Authoring the program (owner/editor, QR builder)**
1. New **Loyalty** type in the type picker (Pro/Agency; Free/Starter see the upgrade gate). The content form
   collects: program name, business name, reward text ("A free regular coffee"), **stamps required** (3–20),
   terms, and the **stamping mode** — *Staff PIN (recommended)* or *Counter code*.
2. An **anti-fraud settings** group, sensible-by-default and explained in plain language: **minimum time
   between stamps** (default 6 hours — "a real punch card can't be punched twice in five minutes"),
   **maximum stamps per customer per day** (default 1), and **redemption policy** (reset to zero vs roll over
   the extra stamps).
3. **Staff PINs** are managed here: add a staff member (label + 4–6 digit PIN, shown once, stored hashed),
   revoke, or rotate. Labels are what appear in the ledger ("Divya — evening shift").
4. Saving writes the program to KV like any other type. **What goes to KV is the program only** — name,
   reward, stamps required, mode. No member, no PIN, no secret.

**6.2 Enrolment (customer, public, no login)**
1. Customer scans the poster → the Worker renders the loyalty landing page at 0/N with **"Join — collect
   your first stamp"**.
2. They enter their phone number and tick an explicit consent line ("Send me WhatsApp updates about my
   stamps and rewards from *Nikhil's Coffee*. Reply STOP anytime."). The exact consent string is stored with
   the member row, mirroring how `qr_lead_submissions.consent_text` records it today.
3. An **OTP** is delivered over item #1's channel. They enter it → a member row is created, an opaque
   `member_token` is minted, and a long-lived cookie is set **on the short-code origin** so a future scan of
   the same poster resolves straight to their card.
4. They land on **their** stamp card: 0/10, "Show this to staff to get stamped", with a member QR/code.
   **Enrolment itself grants no stamp** — the first stamp is a staff action like every other.

**6.3 Stamping — Mode A, staff console (default)**
1. Staff open a public URL (a short link the owner can print and stick under the counter) → a PIN pad.
2. PIN → a **shift session** valid for the rest of the day on that device. No Qravio account, no email, no
   password reset flow.
3. Console shows **Scan customer** (camera) or **Find by phone**. Either resolves a member; the console shows
   their name-less card ("•••• 4821 · 7/10") and one big **Stamp** button.
4. Tap → backend authorizes and increments → console shows **8/10** with an **Undo** affordance for a short
   window. The customer's card updates on their next view; if item #1's channel is live and a trigger fires,
   the WhatsApp message queues.
5. If the customer is inside the cooldown, the console says so plainly ("Divya stamped this card 40 minutes
   ago — minimum gap is 6 hours") rather than failing silently. Staff can request an **owner override**,
   which is itself a ledger row.

**6.4 Stamping — Mode B, rotating counter code (opt-in, weaker)**
1. The same console, in **Display mode**, shows a large **6-digit code that rotates every 60 seconds** —
   propped on the counter, no staff interaction per customer.
2. The customer opens their card and taps **I'm at the counter** → enters the code.
3. Backend validates the code against the per-QR secret for the current (or immediately previous) 60-second
   window, enforces single-use per member per window, applies the same cooldown and caps, and stamps.
4. The builder states the trade-off honestly at selection time: *"Anyone who can see your counter display can
   stamp themselves. Use Staff PIN if your reward is valuable."*

**6.5 Redemption (staff-authorized, both modes)**
- When `stamps_current >= stamps_required`, the customer's card shows **Reward ready — show this to staff**.
- The customer cannot redeem. Staff, in the console, resolve the member and tap **Redeem** → the backend
  issues a **single-use redemption code**, writes a `redeem` ledger row, and applies the merchant's policy
  (reset to 0, or roll over `stamps_current - stamps_required`).
- The code is displayed to both sides and marked used immediately. Re-tapping Redeem on an already-redeemed
  card is a no-op with a clear message, not a second reward.

**6.6 Re-engagement (WhatsApp, via item #1)**
Three triggers, all opt-out-respecting, all deduped so a member never gets the same nudge twice:
- **Near-reward** — fires on the stamp that reaches `stamps_required - 1`. *"One more coffee and your next
  one's on us ☕"*
- **Reward-ready** — fires on completion. *"Your free coffee is ready to claim at Nikhil's Coffee."*
- **Lapsed** — a member with ≥1 stamp and no visit in N days (merchant-set, default 45). Batched by the
  existing daily internal sweep, never per-member timers.

**6.7 Merchant view (dashboard)**
A **Loyalty** tab on the QR detail: members enrolled, active vs lapsed, stamps this week, rewards issued vs
redeemed, and the **ledger** (timestamp, member last-4, event type, auth mode, staff label). Reversal from
the ledger. CSV export follows the existing lead-capture export gating.

**6.8 Degraded and edge states**
- Member scans a poster whose program was deleted → branded "this program has ended", not an error.
- Workspace downgrades below Pro → **existing members keep their stamps and can still redeem**; new
  enrolments and new stamps are blocked with a clear owner-facing message. We do not confiscate a customer's
  earned coffee because the merchant changed plan. *(Rationale, not just mercy: the customer is a third party
  who did nothing wrong; punishing them costs the merchant reputation, and us the merchant.)*
- Stamps required edited mid-program → applies going forward; already-complete cards stay claimable.
- Consent withdrawn ("STOP") → messages stop, stamps and card keep working. Loyalty is not conditioned on
  marketing consent.

## 7. Scope

**In scope (v1 = Phase A, no Apple dependency)**
- `loyalty` dynamic QR type via the 7-step new-type seam (shared with the Wallet epic — whichever ships first
  lands it; this spec's migration creates `qr_loyalty_details` idempotently so neither blocks the other).
- Member enrolment: phone + explicit consent + **OTP verification**; opaque `member_token`; member card page;
  short-code-origin cookie for returning scans.
- **Merchant-authorized stamping**, Mode A (staff PIN console) and Mode B (rotating counter code).
- Staff PIN management (add/label/revoke/rotate), hashed at rest, shown once.
- Append-only `qr_loyalty_events` ledger with anti-fraud metadata; staff undo; owner reversal.
- Staff-authorized redemption with a single-use code + reset/rollover policy.
- Guards: per-member cooldown, per-member daily cap, per-staff-session daily cap, per-QR anomaly alert,
  idempotency keys on every mutating call, OTP attempt/rate limits.
- WhatsApp triggers (near-reward, reward-ready, lapsed) **via item #1's queue** — this spec defines the
  triggers and payloads, item #1 owns the transport, templates, opt-out, and per-workspace message budget.
- Merchant Loyalty tab: counts, ledger, reversal, CSV export.
- `loyalty_cards` + `loyalty_members_max` flags, `inert`→`enforced` in the same PR; `loyalty` appended to
  Pro/Agency `dynamic_qr_types`.
- **Retire the fiction:** the cosmetic `coupon_stamp` coupon template is marked deprecated in the picker and
  points at the real loyalty type. *(Existing QRs using it keep rendering — no silent behaviour change.)*

**Out of scope / Future**
- **Phase B — Apple Wallet `storeCard`** (`.pkpass` whose `update_tag` bumps on each stamp, APNs refresh).
  Owned by the Wallet epic; additive migration for pass rows.
- **Phase C — Google Wallet loyalty object** (the Android-relevant wallet half; still second to WhatsApp).
- Multi-outlet / shared member identity across a merchant's QRs *(DPDP question first, schema second)*.
- Points, tiers, spend-based accrual, purchase verification, POS integration *(needs a bill amount)*.
- Referral mechanics ("bring a friend, both get a stamp") — attractive and a fraud surface of its own.
- Self-serve staff accounts (as opposed to PINs) — PINs are correct for high-turnover counter staff.
- SMS/email channel duplication *(loyalty inherits item #1's channel; it does not build a second)*.
- Loyalty analytics beyond the tab (cohort retention curves, LTV) *(future; the ledger makes it possible)*.
- Migrating existing `coupon_stamp` QRs into real loyalty programs *(manual re-create in v1)*.

## 8. Pricing & Packaging

| Surface | Tier | Flag / Limit |
|---|---|---|
| Loyalty stamp card (type + stamping + ledger) | **Pro, Agency** | `loyalty_cards` (NEW bool) |
| Enrolled members per workspace | per tier | `loyalty_members_max` (NEW int) |
| `loyalty` in creatable types | **Pro, Agency** | `dynamic_qr_types` membership (double-gate, `lead_form` precedent) |
| WhatsApp re-engagement sends | inherits item #1 | item #1's per-workspace message budget — **not** a new meter |
| Branded loyalty page / pass | Agency | existing `white_labeling` |

**Suggested seed values** (tunable in `plans.features` without a deploy): Free `loyalty_cards=false`,
`loyalty_members_max=0`; Starter same; **Pro** `true` / `2000`; **Agency** `true` / `10000`. No unlimited
tier — every member is a potential recurring outbound-message cost and a row of personal data we are
accountable for under DPDP; both argue against `-1`.

- **Why Pro+ and not Starter:** unlike QR expiry (`QR_EXPIRY_SCHEDULING_PRD.md` §8, correctly ungated because
  it is a zero-COGS parity checkbox), loyalty carries **real marginal cost** (outbound messages), **real
  liability** (third-party phone numbers), and **real support surface** (stamp disputes). It is also a
  retention moat worth paying for, and it is the natural Starter→Pro lever for a repeat-visit business.
- **Why a member cap rather than a stamp cap:** stamps are free to us; members are not (each is a
  message-eligible contact and a DPDP record). Capping members also bounds the blast radius of an abused
  program.
- **Why the double-gate:** `0027_open_all_qr_types.sql` opened QR *types* to everyone precisely because type
  was a bad paywall lever — with one exception, `lead_form`, kept paid because the *capability* (PII capture,
  export) is the value. Loyalty is the same shape: it captures verified phone numbers and sends messages, so
  it follows `lead_form`, not the open-types rule.
- **Migration flag-flip (house convention):** seed **both** keys as a full-object `'{...}'::jsonb` blob where
  absent (`test_feature_gate_coverage._seed_feature_keys()` only regex-discovers blob seeds — a path-only
  `jsonb_set` seed leaves them undiscovered and fails the coverage test as "stale"), then enable per tier
  with `lower(name)` + `coalesce(is_custom,false)=false` guards. Never a bare `WHERE name IN (...)`.

## 9. Success Metrics & KPIs

Denominators come from **`qr_scan_events` raw rows** and the loyalty ledger, never the lossy
`qr_scan_counters` aggregates.

**The bar that actually matters — fraud**
- **Zero drained programs.** No merchant reports rewards issued without corresponding staff authorization.
  This is the single metric that decides whether the feature survives contact with real merchants.
- **≥ 99.9% of stamps carry a valid authorization record** (staff PIN session or a validated counter code) —
  measured directly off the ledger, which structurally cannot record a stamp without one. A non-100% number
  here means a bug, not a tolerance.
- **Reversal rate < 2%** of stamps (higher suggests a console usability problem, not fraud).
- **Counter-code mode share and its dispute rate** tracked separately from staff-PIN mode; if counter-code
  disputes materially exceed staff-PIN disputes, we say so in-product and consider retiring the mode.

**Adoption / activation**
- ≥ 30% of Pro/Agency workspaces in retail/F&B create a loyalty QR within 60 days of GA.
- ≥ 40% of loyalty-QR scanners complete enrolment (OTP verified) — the funnel's real drop-off is the OTP.
- **Median stamps-per-staff-session ≥ 5** — proves the console survives a real counter, not just a demo.

**Retention (the thesis)**
- Enrolled members show **≥ 2× the repeat-visit rate** of non-enrolled scanners of the same QR.
- ≥ 25% of completed cards are redeemed within 30 days.
- Merchants running a loyalty QR show **≥ 5pp lower 90-day churn** than matched non-runners.

**Channel (inherited from item #1)**
- ≥ 20% of near-reward WhatsApp nudges are followed by a stamp within 14 days.
- Opt-out rate **< 3%** — above that we are over-messaging and should cut a trigger.

**Operational**
- Stamp API p95 **< 500ms** (staff are standing at a counter with a queue).
- Zero PII in KV (asserted by test, not by inspection); zero staff PINs or TOTP secrets in any log line.

## 10. Rollout Plan

**Sequencing gate (hard).** This feature starts **after analysis item #1 (WhatsApp review reminders) is in
production**, because it depends on that spec's consented-phone capture, OTP-capable outbound channel,
opt-out handling, and delayed-send queue. Building loyalty first means building a worse half of #1 inside it.
If #1 slips, loyalty slips — that is the correct trade, not a blocker to route around.

**Phase 0 — Schema + flags (inert, no UI).**
Apply the migration (member/ledger/staff tables, `qr_loyalty_details` created-or-extended, both flags seeded
as a blob and enabled for Pro/Agency, `loyalty` appended to their `dynamic_qr_types`). Register both flags
`inert` in `FEATURE_ENFORCEMENT`. No user-visible change.

**Phase 1 — Stamping core (internal).**
Enrolment + OTP, the atomic stamp/redeem RPCs, the staff console, the ledger, all guards. Worker proxy routes
and the loyalty page/templates. Deploy the Worker to **staging** and verify: an anonymous scan **never**
increments; a staff-PIN stamp does; the cooldown holds; a replayed idempotency key is a no-op; a reused
counter code is rejected. Flip both flags `inert`→`enforced` in this PR.

**Phase 2 — Design-partner beta (closed).**
3–5 real merchants — deliberately including **one salon or single-operator business** (counter-code mode) and
**one multi-staff cafe** (staff-PIN mode), because the two modes fail in different ways and only real counters
find it. WhatsApp triggers on. Merchant Loyalty tab + ledger.
- **Acceptance:** a customer enrols with OTP → staff stamp them → the count is right on both devices → the
  cooldown blocks a second stamp minutes later → the near-reward WhatsApp arrives → staff redeem with a
  single-use code → the card resets per policy → the ledger shows every event with its authorizer → an
  attempt to stamp by scanning the poster does nothing → a downgraded workspace keeps existing members whole.
- **Fraud red-team as a named gate:** before widening, someone on the team spends an hour actively trying to
  farm a beta program (replay the stamp POST, share a counter code, re-enrol with the same phone, race two
  concurrent stamps, reuse a redemption code). Findings block GA.

**Phase 3 — GA.**
Remove the FE beta flag, deprecate the cosmetic `coupon_stamp` template in the picker, comparison-matrix and
SEO updates, help-centre entry covering the two modes and their honest trade-off.

**Phase B (later, Wallet epic) — Apple `storeCard`.** Additive: a `wallet_passes` row per member card whose
`update_tag` bumps on each stamp. Requires the Wallet epic's cert infrastructure; **nothing in Phase A waits
for it**.

**Cross-service gates:**
- **Worker change → `npm run deploy:prod` required** (new proxy routes + loyalty page). Deploy order:
  migration → backend → Worker → frontend. A Worker deployed early sees a type it can't render; a backend
  deployed early has no traffic. Migration first regardless.
- **Item #1's outbound channel must be live** (OTP delivery depends on it). No DMARC gate — loyalty sends no
  email in v1.
- **Lapsed-member sweep** rides the existing daily internal cron (`0 6 * * *`); no new cron trigger, so no
  additional `wrangler.toml` cron gate.

## 11. Risks, Edge Cases & Open Questions

**R1 — Stamp farming (the feature-defining risk).** Any "increment on scan" path is farmed immediately.
**Mitigation:** merchant authorization is structural, not heuristic — the stamp RPC *cannot* be reached
without either a valid staff session or a valid time-boxed counter code, and the ledger has no shape that
records an unauthorized stamp. Reinforced by cooldown, daily caps, per-session caps, and idempotency. The
red-team gate (§10 Phase 2) exists because this risk is not closable by review alone.

**R2 — Counter-code mode is genuinely weaker, and we're shipping it anyway.** A photographed code works for
up to one rotation; a customer can screenshot and send it to a friend nearby. **Mitigation:** 60-second
rotation, single-use per member per window, cooldown and daily caps still apply, and — the important part —
**say so in the product** at mode-selection time rather than implying parity. If beta shows abuse, we retire
the mode rather than quietly tolerating it. *(Recommendation: ship it. A salon owner's realistic alternative
is a paper card with a rubber stamp, which is strictly worse.)*

**R3 — Staff PIN leakage / shared PINs.** Counter staff turn over constantly and will write the PIN on a
sticky note. **Mitigation:** per-staff labelled PINs (so the ledger attributes), one-tap revoke, shift-scoped
sessions that expire daily, a per-session daily stamp cap with an owner alert on breach, and rotation
prompts. We treat a PIN as an *attribution* mechanism with modest secrecy, not as a strong credential — and
we design the caps assuming a PIN eventually leaks.

**R4 — DPDP / phone-number liability.** We hold third-party phone numbers, purpose-bound to a merchant's
program. **Mitigation:** explicit consent string stored per member (the `qr_lead_submissions.consent_text`
pattern), one-word opt-out that stops messages without breaking the card, cascade deletion on QR/workspace
delete, a retention policy for lapsed members, and phone stored once — not copied into KV, analytics, scan
events, or the ledger's metadata. *(Note the standing repo issue that account deletion doesn't cascade fully;
loyalty must not add to it — flagged for eng-review.)*

**R5 — OTP cost and OTP friction.** OTP is both a per-message cost and the biggest funnel drop. **Mitigation:**
one OTP per enrolment (never per stamp), aggressive per-phone rate limits, and the cookie so returning
customers never re-verify. If enrolment completion is poor in beta, the lever is *making the reward visible
before asking for the phone*, not weakening verification.

**R6 — The staff console is the real product, and it's easy to get wrong.** If stamping takes more than a few
seconds under a queue, staff stop doing it and the program dies quietly. **Mitigation:** shift-scoped session
(PIN once per day, not per stamp), camera-first member resolution, one dominant button, optimistic UI with
undo, and "median stamps per staff session ≥ 5" as an explicit success metric so a dead console shows up in
numbers rather than in churn.

**R7 — Wallet push is the wrong payoff for this market.** The Wallet epic's re-engagement story is APNs on
PassKit. **Mitigation:** WhatsApp is the primary channel and Phase A does not depend on Apple at all; the
`.pkpass` is a Phase B nicety for iOS holders. State this in the Wallet epic too, so the sequencing isn't
re-litigated.

**R8 — Fold friction with the Wallet epic.** Two specs touching `qr_loyalty_details` and the `loyalty` type
can collide (duplicate migrations, conflicting column definitions). **Mitigation:** this spec's migration
creates `qr_loyalty_details` with `IF NOT EXISTS` and adds its own columns with `ADD COLUMN IF NOT EXISTS`,
so either order works; and it explicitly **drops the per-QR `stamps_current`** from the Wallet definition,
which is the one genuine conflict and a correction rather than a compromise.

**R9 — Migration-slot collision (a repeat offender here).** The Wallet PRD reserved `0023`, which
`0023_outbound_webhooks.sql` then consumed; the OCR spec reserved `0024`, which was taken and shipped as
`0026`; QR expiry now claims `0033`. **Mitigation:** treat the slot in the TRD header as provisional and
re-run `ls qr_backend/migrations/` immediately before applying. Non-negotiable.

**R10 — A customer's stamps outliving the merchant's plan.** Covered in §6.8: members keep their stamps and
can redeem; new activity is blocked. The alternative — voiding a stranger's earned reward — is worse for
everyone including us.

**Open Questions**
1. **Is counter-code mode in v1 at all, or staff-PIN-only?** *Recommend shipping both, with counter-code
   clearly labelled as weaker — a meaningful slice of the ICP is a single operator with no counter device,
   and excluding them halves the market. Product to confirm the honesty-in-copy approach is acceptable.*
2. **Member cap per workspace, or per loyalty QR?** *Recommend per workspace (`loyalty_members_max`) — it
   bounds cost and DPDP exposure at the billable unit and is one meter, not N.*
3. **Does enrolment grant a first stamp?** *Recommend no. It's a tempting activation trick, and it is exactly
   the "stamp on scan" hole we spent the whole spec closing. If activation needs a boost, make the reward
   visible pre-enrolment instead.*
4. **Redemption policy default — reset to zero, or roll over?** *Recommend roll over (`stamps_current -
   stamps_required`), because it matches how a customer perceives a card they over-filled, and merchants can
   switch to reset.*
5. **Cooldown default — 6 hours or per-day?** *Recommend 6 hours plus a 1/day cap: the pair covers both the
   "stamped twice in the same visit" and "queued twice today" cases, and F&B has legitimate twice-a-day
   regulars a hard 24h lock would annoy.*
6. **Should the lapsed-member nudge be on by default?** *Recommend off by default, on by explicit merchant
   choice — it's the trigger most likely to read as spam and drive the opt-out rate above the 3% bar.*
7. **Does the Wallet epic absorb this spec's tables, or stay separate?** *Recommend separate migration,
   shared `qr_loyalty_details`, with the Wallet epic depending on this one for stamp state — the opposite of
   the current draft. Needs a decision before either builds.*

## 12. Dependencies

- **Analysis item #1 — WhatsApp review reminders (`WHATSAPP_REVIEW_REMINDERS_PRD/TRD`, in flight):** the hard
  dependency. Supplies consented phone capture, the OTP-capable outbound channel, opt-out/STOP handling, the
  delayed-send queue, and the per-workspace message budget. Loyalty defines triggers and payloads only.
- **Wallet Passes epic (`WALLET_PASSES_PRD.md` / `WALLET_PASSES_TRD.md`, not started):** owns the `loyalty`
  type seam, `qr_loyalty_details`, and the Phase-B `.pkpass` `storeCard`. This spec extends it and corrects
  its per-QR `stamps_current`.
- **Worker proxy pattern (shipped):** `POST /pw-verify/:shortCode` in `qr_cf_code/src/index.js` (L98–133) —
  the exact precedent for edge→backend POST proxying with no secret at the edge.
- **Public-route + internal-secret patterns (shipped):** `verify_internal_secret` in
  `qr_backend/src/api/routes/internal.py` (L21) and the excluded-prefix match in
  `qr_backend/src/api/middlewares/auth_bearer.py`.
- **Rate-limit precedent (shipped):** the lead-submit limiter (`internal.py` L1331–1344, 10/IP/hour counted
  off `qr_lead_submissions.ip_hash`) — the shape to follow, though loyalty needs its own counters because
  stamps are ledger rows, not lead rows.
- **Atomic-counter RPC precedent (shipped):** `increment_card_ocr_usage` / `increment_api_usage` — the
  increment-then-check pattern the stamp RPC mirrors.
- **New-QR-type seam (shipped, 7 steps):** `qr.py` type Literal (L839–864), `SELECT_WITH_RELATIONS` (L998),
  `build_kv_content` (`cloudflare_kv.py` L387), `qrRouter.js` dispatch, page templates, React previews.
- **Gating engine (shipped):** `FEATURE_ENFORCEMENT` (`subscription.py` L524–560), `check_feature`,
  `get_limit`, `canAccessFeature` / `PlanFeatures`.
- **Consent-capture precedent (shipped):** `qr_lead_submissions.consent_text` + `ip_hash`
  (`0012_lead_capture_forms.sql`).
- **No AI. No new external service beyond item #1's channel. No email. No new cron trigger.**

### Appendix — Key Files

| Concern | File |
|---|---|
| Cosmetic template being replaced | `qr_cf_code/src/pages/coupon/stampTemplate.js` (L12–15: hardcoded `[false ×6]`, always 0/6) |
| Coupon dispatcher registering it | `qr_cf_code/src/pages/coupon/index.js` (`HANDLERS.coupon_stamp`) |
| Wallet epic's loyalty seam (extended, not duplicated) | `PRD_TRD/NOT_DONE/WALLET_PASSES_TRD.md` §2 table (4) `qr_loyalty_details`, §3.3 type wiring |
| Migration (members, ledger, staff PINs, flags) | `qr_backend/migrations/0043_loyalty_stamp_card.sql` (NEW — slot **provisional**, re-verify) |
| Stamping + enrolment + console API | `qr_backend/src/api/routes/loyalty.py` (NEW), registered in `src/api/endpoints.py` |
| Worker→backend proxy target | `qr_backend/src/api/routes/internal.py` (new loyalty endpoints beside `verify_qr_password_by_code`, L1173) |
| Edge proxy routes + loyalty page | `qr_cf_code/src/index.js` (mirror `/pw-verify/` L98–133), `qr_cf_code/src/pages/loyalty/` (NEW) |
| Type dispatch | `qr_cf_code/src/handlers/qrRouter.js` (coupon branch L233–243 is the shape) |
| KV program block (no PII) | `qr_backend/src/utilities/cloudflare_kv.py` (`build_kv_content` L387, `write_to_kv` payload L93) |
| Type wiring | `qr_backend/src/api/routes/qr.py` (Literal L839–864, `SELECT_WITH_RELATIONS` L998) |
| Gating | `qr_backend/src/api/routes/subscription.py` (`FEATURE_ENFORCEMENT` L524–560) |
| Builder + console + dashboard UI | `qr_frontend/src/components/qr-generator/content-types/LoyaltyContent.tsx` (NEW), `qr_frontend/src/app/stamp/[code]/` (NEW public staff console), QR-detail Loyalty tab |
| FE gating | `qr_frontend/src/lib/plan-features.ts`, `qr_frontend/src/hooks/useSubscription.ts` (`loyalty_cards`, `loyalty_members_max`) |
| Outbound channel (item #1) | `PRD_TRD/NOT_DONE/WHATSAPP_REVIEW_REMINDERS_*` — triggers defined here, transport owned there |
