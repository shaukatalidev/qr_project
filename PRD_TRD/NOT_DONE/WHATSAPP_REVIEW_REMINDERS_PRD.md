# PRD — WhatsApp Review-Reminder Automation

**Status:** Draft · **Author:** Product · **Date:** 2026-07-25
**Priority:** The **#1 "core bet"** in the competitive gap analysis (`docs-internal/competitive-feature-gap-analysis.md` §1) — our best India growth lever and the only ranked gap where we start from a structural advantage. WhatsApp reminders are documented to lift Google-review collection ~3× versus email, review volume is the #1 local-SEO lever for Indian F&B/retail/services, and **no** global competitor (Uniqode, Bitly, QR Tiger, Flowcode, Scanova, QRCodeChimp) ships it natively. This is the one item on the list worth real investment — and the one with the most ways to get it wrong.
**Tiers:** **Pro, Agency** (`review_reminders` flag) with a **per-workspace monthly message ceiling** (`reminder_messages_per_month`) that is a **fair-use/abuse cap, not a billing meter** — see §8, where the recommended v1 shape is **BYO-BSP** (the merchant connects their own WhatsApp Business API account and pays Meta directly, so Qravio carries **zero per-message COGS**).
**Plan flags:** `review_reminders` (bool, NEW) + `reminder_messages_per_month` (int limit, NEW). Both seeded as a full-object `'{...}'::jsonb` blob and registered `inert`→`enforced` in the **same PR** (house convention; `test_feature_gate_coverage` stays green).
**Split from:** the shipped `review_funnel` QR type (`GOOGLE_REVIEW_FUNNEL_QR_TRD.md`, migration `0022`) — the scan moment, the sentiment gate, and the feedback arm already exist. Reuses the **outbound-webhooks delivery-queue pattern** (`OUTBOUND_WEBHOOKS_TRD.md`, `webhook_deliveries` + `/internal/webhook-sweep` on the `*/5 * * * *` cron) as the model for the delayed-send queue, and the `card_ocr_usage`/`ai_analyst_usage` metering pattern for the message counter. **Not** native WhatsApp catalog/commerce (an explicit Skip in the analysis) and **not** a general campaign/broadcast tool.

**Honest framing (read this before anything else):** the analysis calls this **L effort** and says "sequence this right — it is *not* a quick win." Three things are true simultaneously: (1) the growth thesis is strong and the seam really is ours; (2) **the feature does not exist without consented phone capture, which we have zero of today** — the happy path routes straight to Google and captures nothing; and (3) the messaging layer drags in Meta template approval, WABA onboarding, DPDP consent obligations, and per-message economics that are **hostile to a ₹999/mo price point** unless we choose the sender model deliberately. This PRD scopes **Phase 0 to capture only — no sending at all** — so we build the asset and measure the conversion cost *before* committing to the messaging stack.

**Rev (2026-07-25, post eng-review):** Reviewed via `/plan-eng-review` + an independent outside-voice pass (every load-bearing claim verified against code) that found **four plan-breaking P0s**, now folded in as required corrections (see the TRD Rev). **Three product decisions:** (1) **Onboarding = BSP Embedded Signup, not manual key-paste.** The merchant clicks through a partner-hosted Meta popup and ends up with their own WABA / number / quality-rating — no API-key paste, no shared WABA, still not a Meta Tech Provider — and the template is submitted via the BSP's API, not copy-pasted. This collapses setup gates 1 & 3 (the single biggest lever on the sub-40% onboarding completion the PRD expects to be its worst number) and removes the template-drift support ticket. (2) **Capture moves to a post-tap interstitial.** The below-the-stars row was effectively unreachable — the star tap *is* the navigation to Google, so a scanner would have to type their phone *before* doing what they came for → near-zero opt-in → the `<4%` gate would kill Phase 1 on a false "no demand" when the truth is "no opportunity." Instead: after the tap, a brief "Thanks! Taking you to Google…" interstitial (~2 s auto-redirect) carries the phone/consent row. (3) **Account-deletion cascade is a hard Phase-0 exit-gate item** (with a test, `reminder_contacts` included) **plus purge-on-abort** — if the exit gate says stop, the collected numbers are deleted (gathered under a promise we won't keep). **Guardrail fixed:** the 2pp Google-route metric was 100%-by-construction (tap = navigation) with no rollback mechanism — replace it with a **50/50 server-side A/B split on `session_id`** (same-period, denominator = page-view scans) + a `config:reminders_enabled` KV kill-key for a real one-flip rollback. **Consent hardened:** `/review-contact/` is an open POST and client-asserted consent is forgeable — bind the beacon to the rendered page with a short-TTL render-time **HMAC** (`getPwToken` pattern), backend owns the consent text (a server-side template with `{business_name}` + a privacy link so it meets Meta's opt-in + DPDP "informed" bar); no valid token → no row. Add a **Data Processing Agreement with the merchant** — the real missing legal artifact. **Strategic:** the honest v1 buyer is multi-outlet / agency (Arjun/Amit), not the single-outlet café — consider **Agency-first concierge onboarding**. Technical corrections (sweep predicate, per-workspace webhook secret+path, time-bounded batch, KV resync, upsert column-pinning, `ip_hash`, quiet-hours CHECK, staleness expiry, migration split, `reminder_messages_per_month` inert in Phase 0) are in the TRD Rev.

---

## 1. TL;DR / Summary

A scanner taps a star on a `review_funnel` QR. Today: ≥ threshold → instant 302 to Google, no data captured; < threshold → private feedback form. Tomorrow, the rating step also offers an **optional, skippable "get a reminder on WhatsApp" row** — a phone field plus a **separate, unticked marketing-consent checkbox** — that **never blocks the star tap**. Opted-in numbers land in a new `reminder_contacts` table via a `navigator.sendBeacon` that fires *before* the Google navigation.

Later — after a merchant-configured delay (default **2 hours**, range 30 min–72 h) — a **delayed-send queue** picks up due contacts and sends **one** approved WhatsApp template message containing a short link back to the merchant's Google review page. The link routes through a new Worker route so a click is attributed and suppresses further reminders. Every message carries an opt-out instruction; STOP replies arrive on a signature-verified BSP inbound webhook and write to a `messaging_opt_outs` suppression list that every send checks.

**The sender is the merchant, not us.** In v1 the workspace **connects its own WhatsApp Business API account** through one supported BSP (Gupshup at launch). Qravio orchestrates timing, consent, suppression, and attribution; Meta bills the merchant. This is the only shape that (a) makes the review ask come from "Café Xyz" instead of "Qravio", (b) keeps a bad tenant's block rate off *our* shared quality rating, and (c) leaves Qravio with **zero per-message COGS** on a ₹999/mo plan.

**Three new pieces of infrastructure**, none of which exist today: a **consented-contact store**, a **delayed-send queue** (webhooks are synchronous forwards; there is no scheduler), and a **per-message usage meter**. Plus one new public, signature-verified inbound webhook.

## 2. Problem & Motivation

**We own the scan moment and throw it away.** `review_funnel` is our sharpest India wedge — it converts a physical table-tent into sentiment-gated review routing. But the funnel is **single-shot**. Verified in `qr_cf_code/src/pages/reviewFunnel/classicTemplate.js:262-263`: a star at or above threshold does `window.location.href = "/review-go/" + shortCode + "?stars=" + n`, which the Worker turns into a `302` to Google (`qr_cf_code/src/index.js:294-296`). If the customer doesn't finish the review in that session — distracted, not signed into Google, queue moved, phone died — **the intent is gone forever.** We have no way to reach them, because we captured nothing.

That gap is most of the value. A rating tap is a strong intent signal; Google-review *completion* from a cold hand-off is a minority of taps. The reminder targets the majority who bounced, which is exactly why the ~3× lift over email is plausible: WhatsApp is where the Indian SMB's customer already is, open rates are near-universal, and the message arrives with the visit still fresh.

**Only the *unhappy* path leaves contact details today.** The below-threshold arm reveals a lead form that posts to `/lead-submit/` (`qr_cf_code/src/index.js:162`), whose configured fields *can* include a phone (`FIELD_TYPES` at `qr_frontend/src/components/qr-generator/content-types/LeadFormFieldRow.tsx:25-28` already offers `phone`). So the one cohort whose number we sometimes have is the one we should *not* be soliciting public reviews from. That inversion is the whole problem statement.

**And the consent we do collect does not cover messaging.** The consent label rendered on both the lead form and the funnel's feedback arm (`qr_cf_code/src/pages/reviewFunnel/classicTemplate.js:41`, `.../leadForm/cardTemplate.js:38`) reads *"I consent to having this website store my submitted information so they can respond to my enquiry."* That is a **storage-and-response** consent. Under DPDP 2023 it is not a free, specific, informed, unambiguous consent to receive **marketing/outreach messages**, and Meta's own policy requires opt-in for template messaging. **We cannot message a single number we hold today.** Phase 0 exists because of this sentence.

**The competitive window is real but not permanent.** This is an Indian micro-category (SmartReviewer, WiserNotify, SMS India Hub) that the global QR platforms have not entered. They sell QR codes; we would be selling *review outcomes*. Fusing the scan moment with the reminder channel is a defensible bundle none of them can copy without building a funnel type first.

**What it is not.** Not a broadcast/campaign tool, not a CRM, not WhatsApp commerce. One purpose, one template family, one audience: people who tapped a star on your own QR and asked to be reminded.

## 3. Goals & Non-Goals

**Goals**
- **Capture consented phone numbers on the `review_funnel` scan flow without measurably depressing the Google-route conversion** — the primary funnel metric is a *hard guardrail*, not a hope (§9).
- Store consent with **full provenance** (verbatim consent text, timestamp, source, QR, locale) so a DPDP or Meta audit is answerable from one table.
- A **delayed-send queue** that fires a single WhatsApp template message per contact after a merchant-configured delay, with retry/backoff, terminal states, quiet hours, and per-contact frequency caps.
- **BYO-BSP:** a workspace connects its own WhatsApp Business API account (one BSP supported at launch); Qravio never sends from a shared Qravio sender in v1.
- **Universal, enforced opt-out**: STOP handling via inbound webhook + a suppression list checked on every send + a per-message opt-out instruction.
- **Attribution**: reminder → click → (proxy for) review, so the merchant sees whether it worked and we can suppress follow-ups.
- Gate at **Pro+** behind `review_reminders`, metered by `reminder_messages_per_month` as a fair-use ceiling; registered `inert`→`enforced` in the same PR.

**Non-Goals**
- **No sending in Phase 0.** Phase 0 ships capture, consent, storage, opt-out, and the export — and nothing that transmits a message. This is deliberate: it builds the asset, measures the conversion cost, and lets us abort the messaging stack if capture rates are bad.
- **No SMS in v1.** TRAI **DLT** registration (entity + sender ID + per-template scrubbing, plus a principal-entity/telemarketer chain) is a worse self-serve wall than Meta's, for a channel whose India value-add over WhatsApp is marginal. The data model is channel-agnostic so SMS can slot in later; the feature is not. *(Explicitly deferred — §7.)*
- **No Qravio-provided messaging / bundled message credits in v1.** Reselling Meta conversations at Indian marketing rates against a ₹999/mo plan is a margin trap (§8). Deferred until there is a reseller agreement and a credits SKU.
- **We do not become a Meta Tech Provider / BSP.** We integrate with one, as the analysis instructs.
- **No shared Qravio WABA sending on behalf of tenants.** One tenant's block rate would tank every tenant's deliverability, and a review ask from "Qravio" converts poorly. *(This is the single most tempting shortcut in the feature. It is a No.)*
- **No broadcast, list import, or arbitrary campaign composer.** Only contacts who opted in on *this workspace's* QR, only the review-reminder template family. A bulk-import path invites bought lists and makes us the data fiduciary for consent we never witnessed.
- **No review-completion detection.** Google does not tell us whether a review was written. We can suppress on opt-out, click, and feedback submission — nothing else. Copy must assume some recipients already reviewed (§11 R6).
- **No reminders on the unhappy path in v1** beyond service-recovery — a below-threshold scanner must never receive a public-review solicitation (§11 R2).
- **No new QR type, no KV schema overhaul.** One additive `content.reminder_capture` block on the existing `review_funnel` KV payload.

## 4. Target Users & Personas

| Persona | Who | Job-to-be-done | Today's pain |
|---|---|---|---|
| **Café / Restaurant Owner ("Nikhil")** | 1–3 outlets, table-tent QRs, lives on Google ratings | Convert every happy diner into a public review | Diners tap 5★, get bounced to Google, never finish; rating stalls |
| **Clinic / Salon Manager ("Priya")** | Appointment-based, high repeat rate | Ask *after* the visit, when the customer is home and free | No channel; front-desk staff won't chase reviews by phone |
| **Multi-outlet Retail Ops ("Arjun")** | 8–20 stores, Agency-tier buyer | Compare review lift per outlet, one messaging setup | Nothing to compare; no per-QR reminder telemetry |
| **Agency Account Manager ("Amit")** | Runs review programs for SMB clients | Prove ROI on a review program with real numbers | Manual review chasing; no attribution story |
| **The scanner ("Meera")** | The diner who tapped 5★ | Be reminded when it's convenient — or left alone | Either nagged by staff or forgotten entirely |

Primary buyer is the **Pro-tier multi-location SMB** for whom review volume is a revenue input, not a vanity metric. **Agency** is the natural upsell (higher ceiling, per-outlet comparison). The **scanner** is a first-class stakeholder here in a way they are not in most of our features: get consent or frequency wrong and we damage the merchant's relationship with their own customer.

## 5. User Stories

- As a **café owner**, I want customers who tapped 5★ but didn't finish to get one polite WhatsApp nudge a couple of hours later, so that my Google rating reflects how people actually felt.
- As a **café owner**, I want the message to come **from my own WhatsApp business number**, so that my customer recognises the sender and doesn't report it as spam.
- As a **clinic manager**, I want to choose the delay and the quiet hours, so that nobody gets a message at 11 pm.
- As a **scanner**, I want the phone field to be **clearly optional** and the consent box **unticked**, so that giving my number is a decision I made, not one made for me.
- As a **scanner**, I want to tap a star and go straight to Google **without** filling anything in, so that the reminder option costs me nothing.
- As a **scanner who changed their mind**, I want to reply STOP once and never hear from that business again through this channel, so that opting out actually works.
- As a **workspace owner**, I want to see how many reminders were sent, delivered, read, clicked, and opted out — per QR — so that I can tell whether this is working.
- As a **workspace owner**, I want to connect my existing WhatsApp Business API account in a few steps and be told plainly when my template isn't approved yet, so that I'm not debugging silence.
- As a **privacy-conscious owner**, I want the exact consent text and timestamp stored against every number, so that I can answer a DPDP request without guessing.
- As a **Free/Starter user**, I want to see the capability and what it costs to unlock, so that the upgrade ask is concrete.

## 6. UX / Product Flow

**6.1 Merchant setup — a three-gate wizard (be honest about the gates)**
The Reminders settings section is a **linear, blocking checklist**, because every step downstream is dead until the one before it passes. Each gate shows real status, not a spinner:
1. **Connect your WhatsApp Business API account** — pick the supported BSP, paste API key + app name + sender number; we validate against the BSP and store credentials encrypted. *(Failure mode surfaced plainly: "This number isn't a WhatsApp Business API number — a personal WhatsApp or WhatsApp Business app number will not work.")*
2. **Get the reminder template approved** — we show the exact, Meta-policy-safe template body and variable order to paste into their BSP console, then poll/refresh template status. **Status is shown as `pending` for as long as Meta takes (typically 1–3 business days; can be longer or rejected).** Nothing can be sent until this is `approved`.
3. **Turn it on per QR** — in the `review_funnel` builder: enable capture, set delay, quiet hours, per-contact cooldown, and the reminder-link target.

**6.2 The capture moment — the design constraint that matters most**
On the rating step, **below** the stars and visually secondary:
> *Want a reminder to leave your review later?*
> `[ phone input, optional ]`
> `[ ] Yes, send me one WhatsApp reminder about my review. I can reply STOP anytime.`

- The **star tap is never gated.** Tapping a star fires `navigator.sendBeacon` with whatever is in the field (possibly nothing) and then navigates. `sendBeacon` is chosen precisely because it survives the navigation — a `fetch` would be cancelled by the 302.
- **Nothing is stored unless both** a parseable phone **and** an explicitly ticked consent box are present. Pre-ticking is forbidden and is asserted in tests.
- The consent sentence is **its own** consent — distinct from the existing storage-consent used by the feedback arm — and the verbatim string is stored with the contact.
- If the merchant hasn't finished setup, the row is **not rendered at all**. We never collect numbers we cannot lawfully or technically use.
- **Below-threshold scanners see no reminder row.** They get the existing feedback form. Soliciting a public review from an unhappy customer is the review-gating failure mode our own `review_funnel` invariant exists to prevent.

**6.3 The reminder**
- After `delay_minutes`, the queue sends one approved template from the merchant's number, e.g.: *"Hi! Thanks for visiting {{business_name}} today. If you have 30 seconds, a quick Google review really helps us: {{link}}. Already left one? Thank you — please ignore this. Reply STOP to opt out."*
- `{{link}}` is a short, unguessable, expiring Worker URL (`/rr/:token`) that records the click and 302s to the merchant's already-validated `google_review_url` — the same stored, backend-validated URL the funnel redirects to, never a scan-time parameter.
- **Quiet hours** (default 21:00–09:00 in the workspace's configured timezone) defer, never drop: a message due at 22:30 sends at 09:00.
- **Frequency caps**: one reminder per contact per QR per cooldown window (default 30 days), and a hard per-contact global ceiling across the workspace.
- Clicking the link, submitting feedback, or opting out **suppresses** anything still queued for that contact.

**6.4 Reporting**
A **Reminders** card on the `review_funnel` QR detail (peer of the existing Review Funnel card) shows: opt-in rate (of star taps), queued / sent / delivered / read / clicked / failed, opt-out rate, and — the number that decides the feature's fate — **Google-route conversion with the capture row on vs. the pre-capture baseline**.

**6.5 Contacts & rights requests**
A workspace-scoped contacts list (phone masked by default, full value gated to owners) with consent text, timestamp, source QR, and status. Per-contact **delete** and **suppress**, plus CSV export. This is the surface a DPDP rights request is answered from — it is a requirement, not a nice-to-have.

**6.6 Non-entitled users**
Free/Starter see the Reminders section as a locked card with a concrete ask ("Turn 5★ taps into published reviews — WhatsApp reminders, Pro"), matching how other Pro+ affordances tease.

## 7. Scope

**In scope — Phase 0 (capture only, no sending)**
- `reminder_contacts` + `messaging_opt_outs` tables; consent-provenance columns; plan flags seeded.
- `content.reminder_capture` block on the `review_funnel` KV payload; capture row in the Worker template + its mirrored React preview.
- New Worker route `POST /review-contact/:shortCode` → new `POST /internal/reminder-contact`; E.164 normalization + validation; opt-out/suppression check at write time.
- `marketing_consent` threaded through the existing `/lead-submit` path so the feedback arm can *also* record a (service-recovery-only) consented contact.
- Contacts list + export + delete UI; opt-in-rate and Google-route-conversion telemetry.
- **Guardrail instrumentation and its rollback trigger (§9) ship in this phase, not after.**

**In scope — Phase 1 (sending, closed beta)**
- `reminder_schedules`, `reminder_messages` (the queue), `workspace_messaging_config`, `reminder_usage`.
- One BSP adapter behind a provider interface; encrypted credential storage; template-status check.
- `/internal/reminder-sweep` on the **existing** `*/5 * * * *` cron branch; claim-lease + backoff + terminal states, mirroring `webhook_deliveries`.
- BSP inbound webhook (delivery receipts + STOP), signature-verified, on the public-route allow-list.
- `/rr/:token` attribution route; quiet hours; frequency caps; `review_reminders` gate + meter.
- Reminders card + settings wizard.

**Out of scope / Future**
- **SMS / TRAI DLT** *(deferred; data model is channel-ready, the feature is not)*.
- **Qravio-provided messaging with bundled credits** *(needs a reseller agreement + credits SKU + margin model — §8)*.
- **Multiple BSPs** *(one adapter at launch; the interface exists so a second is additive)*.
- **Bulk contact import / bought lists** *(deliberate No — consent we didn't witness)*.
- **Reminders on other QR types** (`lead_form`, `vcard`, future `menu`) *(the same queue generalizes; Phase 3)*.
- **Loyalty / re-engagement re-use of this channel** *(the Wallet Passes epic's Android answer — analysis §12)*.
- **Multi-step sequences / A-B tested copy / AI-written messages** *(one message, one template family, v1)*.
- **Review-completion detection** *(not technically possible via Google)*.
- **Per-message billing to the merchant through Qravio** *(they pay Meta directly in v1)*.

## 8. Pricing & Packaging

| Surface | Tier | Flag / Limit |
|---|---|---|
| Consented phone capture on `review_funnel` (Phase 0) | **Pro, Agency** | `review_reminders` (NEW bool) |
| WhatsApp reminder sending (Phase 1) | **Pro, Agency** | `review_reminders` + `reminder_messages_per_month` (NEW int) |
| Free, Starter | locked | upgrade card; capture row not rendered; API 403 |

**Suggested seed values** (tunable in `plans.features` without a deploy): Free `false`/`0`, Starter `false`/`0`, Pro `true`/`2000`, Agency `true`/`10000`. No `-1`/unlimited on any tier — the ceiling is an abuse brake and must always bind.

**The sender-model decision is the pricing decision.** Two shapes, and they are not close:

| | **BYO-BSP (recommended, v1)** | **Qravio-provided credits (deferred)** |
|---|---|---|
| Who pays Meta | The merchant, directly | Qravio, resold |
| Qravio COGS/message | **₹0** | Full Meta rate + BSP markup |
| Sender identity | The merchant's own number ✅ | Qravio's, or a provisioned per-merchant number |
| Quality-rating blast radius | Per-merchant ✅ | **Shared — one bad tenant hurts everyone** |
| Onboarding friction | High (BSP account + template approval) ❌ | Low ✅ |
| Margin at ₹999/mo Pro | Unaffected ✅ | **Hostile** — see below |

**Why the credits model is deferred, with numbers.** Meta moved to per-message pricing in mid-2025; India **marketing** templates run on the order of **~₹0.7–0.9 per message** and **utility** templates roughly **~₹0.10–0.15** *(order-of-magnitude only — re-verify the live rate card at build time; Meta has repriced repeatedly)*, plus BSP platform fees (Gupshup adds a small per-message markup; Wati/Interakt charge ₹2,000–3,000/mo SaaS floors). At marketing rates, **a 1,000-message month costs ~₹780 against a ₹999 Pro plan** — roughly 78% of that plan's entire revenue consumed by one feature's COGS, before Supabase, Cloudflare, Anthropic, or support. Even a conservative 500-message cap is ~39%. **There is no version of bundled credits that works at current Indian price points without a dedicated add-on SKU.** BYO-BSP removes the problem entirely rather than optimising around it.

**The category question is worth real money.** If a post-visit review request can legitimately be approved as a **utility** template rather than **marketing**, the per-message cost drops ~6–7×. Meta's utility category covers transaction follow-ups; a feedback request tied to a specific visit is arguably in scope, but categorisation is at Meta's discretion and they have reclassified aggressively. Under BYO-BSP this is the *merchant's* cost, so it does not gate our launch — but it materially changes whether a credits SKU is ever viable. **Test both categorisations during the beta and record the outcome** (§11 Open Q3).

**Why Pro+ (not Starter):** unlike `review_funnel` itself (a Starter acquisition wedge), reminders carry operational weight — support burden on WABA onboarding, DPDP exposure on stored numbers, abuse surface. The buyer who will complete a BSP onboarding is not a ₹399 self-serve user. Pro also gives `review_funnel` a genuine second upgrade rung: *Starter to get the funnel, Pro to make it compound.*

## 9. Success Metrics & KPIs

**The guardrail comes first, because it can kill the feature**
- **Google-route conversion must not fall.** `star_tap ≥ threshold → /review-go?route=google` rate, with the capture row rendered, must stay within **2 percentage points** of the 14-day pre-capture baseline for the same QRs. **A sustained drop beyond 2pp over 7 days is an automatic rollback trigger** (disable the capture row via KV; no deploy needed). Measured per-QR and in aggregate; the baseline is captured *before* Phase 0 ships.

**Capture (Phase 0 gate)**
- **Opt-in rate ≥ 8%** of above-threshold star taps within 30 days. Below **4%**, the messaging stack is **not** worth building and Phase 1 does not start — say this out loud now so the decision is cheap later.
- 100% of stored contacts carry a non-empty verbatim `consent_text` + timestamp + source (**invariant**, asserted in tests, not sampled).
- Zero contacts stored without an explicitly ticked box (**invariant**).

**Sending (Phase 1)**
- **Delivery rate ≥ 90%** of sent messages reach `delivered` (below that, number quality or template health is wrong).
- **Click-through ≥ 25%** of delivered reminders hit `/rr/:token` — the honest proxy, since review completion is unobservable.
- **Merchant-reported review lift**: design partners report new-review volume before/after; target **≥ 1.5×** over an 8-week window. Self-reported and small-n — treat as directional evidence, not proof, and say so in any marketing claim.
- **Opt-out rate < 2%** of delivered messages. Above **5%** for any workspace, auto-pause that workspace's sending and alert — a merchant burning their own customer list is our reputational problem too.
- **Zero messages sent** to an opted-out, unconsented, or quiet-hours-blocked number (**invariant**).
- **Zero reminders sent to below-threshold scanners** (**invariant** — the review-gating guard).

**Business**
- Starter→Pro upgrades attributed to the reminders gate; `review_funnel` QR creation rate among Pro workspaces.
- **Onboarding completion**: % of entitled workspaces that get past all three setup gates. **Expect this to be the worst number in the feature** (template approval alone is a multi-day wall). Below 40%, the BYO model needs rethinking, not more UI polish.

## 10. Rollout Plan

**Phase 0 — Consented capture, no sending (internal → GA).**
Migration `0038` (whole-feature schema + flags — see the TRD's note on why one slot). Capture row in the Worker template + mirrored React preview; `POST /review-contact/:shortCode` → `/internal/reminder-contact`; E.164 normalization; opt-out check; contacts UI + export + delete; `marketing_consent` threaded through `/lead-submit`. **Nothing sends.** Ship the guardrail dashboard **first**, capture 14 days of pre-capture baseline, then enable the row for internal + design partners, then widen.
- **Exit gate:** opt-in ≥ 8% (proceed) / 4–8% (proceed with reduced scope, one BSP, hand-held partners only) / < 4% (**stop; do not build Phase 1**). Google-route conversion within 2pp. Consent-provenance invariants green.

**Phase 1 — Sending, closed beta (5–10 design partners).**
BSP adapter + encrypted credential storage + template-status check; the queue + `/internal/reminder-sweep`; inbound webhook (receipts + STOP); `/rr/:token`; quiet hours + frequency caps; meter + `review_reminders` gate; settings wizard + Reminders card. Partners are **hand-held through WABA onboarding** — that time is the point of the beta, and how long it takes is a finding.
- **Acceptance:** a Pro workspace connects its BSP account → template approved → a 5★ tap with consent creates a contact → after the delay exactly one message sends from the merchant's number → delivery receipt lands → click recorded and 302 lands on Google → STOP suppresses all future sends → a second tap inside the cooldown sends nothing → a message due at 23:00 sends at 09:00 → over-cap returns the quota state → non-entitled 403s.

**Phase 2 — GA.**
Flip `review_reminders` `inert`→`enforced` (same PR as the seed), remove the FE beta flag, publish the help-center onboarding guide (the WABA walkthrough is the single highest-leverage doc in this feature), add the comparison-matrix row and the review-reminder SEO cluster.
- **GA gates:** delivery ≥ 90%; opt-out < 2%; zero consent-invariant violations; onboarding completion measured and reported honestly; the `_dmarc.qravio.app` TXT record published if any part ships email notifications.

**Cross-service gates:**
- **Worker change → `npm run deploy:prod` is required** (capture row, `/review-contact/`, `/rr/`, and the new sweep ping). **No `wrangler.toml` change** — the reminder sweep rides the existing `*/5 * * * *` trigger, which already dispatches `webhook-sweep` (`qr_cf_code/wrangler.toml:53`, `qr_cf_code/src/index.js:78-79`).
- **Deploy order:** apply `0038` → deploy backend (`/internal/reminder-contact` must exist) → deploy Worker (the capture beacon has a target). A Worker deployed early would beacon into a 404 and silently drop opt-ins.
- **BSP account + Meta template approval are external, multi-day gates** on Phase 1 — start them the day Phase 0's exit gate passes, not after Phase 1 code is written.

## 11. Risks, Edge Cases & Open Questions

**R1 — Capture depresses the very conversion we're lifting (the #1 risk).** Any UI between a happy customer and Google costs conversion. **Mitigation:** the row is secondary, optional, below the stars, and **never blocks the tap**; `sendBeacon` fires without awaiting; the row is absent entirely when the merchant hasn't finished setup. The 2pp guardrail with an automatic KV-level rollback (§9) is the real control — and it exists precisely because our confidence here should be low.

**R2 — Review gating / Google ToS (inherited invariant, now sharper).** `review_funnel` was built feedback-first: nobody is ever blocked from leaving a public review. A reminder sent *only* to high-raters is a selective solicitation and is exactly what Google's policy targets. **Mitigation:** reminders are triggered by **opt-in**, not by rating; the below-threshold arm shows no reminder row and receives no review solicitation; merchant-editable copy is constrained to an approved template with no incentive language. **Never build "remind only 5★ customers" as a setting.**

**R3 — Meta template approval latency and rejection (the schedule risk).** Approval typically takes 1–3 business days and can be rejected for tone, formatting, or category. **Mitigation:** ship a pre-vetted template body with correct variable ordering; surface real status in the wizard; make "pending" a first-class, non-alarming state. **Do not promise a same-day setup anywhere in marketing.**

**R4 — WABA onboarding is the activation cliff.** Meta Business verification, a dedicated number not tied to a personal/Business-app WhatsApp, display-name approval. **Mitigation:** target merchants who **already** have a BSP account ("connect your existing account" is a far softer ask than "go get verified"); hand-hold the beta; measure completion honestly (§9). **Accept that this caps the addressable base** — and prefer that to the shared-WABA shortcut, which trades a real cap for a systemic risk.

**R5 — DPDP obligations on stored numbers.** Third-party personal data, collected for a stated purpose, held by us as processor for the merchant. Our own privacy page already claims DPDP compliance and a 30-day rights-request SLA (`qr_frontend/src/app/(marketing)/privacy/page.tsx:35,213,243`), so the obligation is already asserted. **Mitigation:** separate unticked consent; verbatim text + timestamp + source stored; purpose limitation enforced in code (contacts are usable **only** by the reminder sender, never exported into another feature); working withdrawal (STOP + UI delete); retention TTL with automatic purge; opt-outs retained as **hashes only**, permanently, since a suppression list must outlive the data it suppresses. **Related liability:** the analysis flags the account-deletion cascade as a stub with no backend cascade. Adding a phone-number table to a product that cannot actually delete a user's data makes that pre-existing gap materially worse — **fix the cascade before or with this feature**, not after.

**R6 — Reminding someone who already reviewed.** Google gives us no completion signal. **Mitigation:** the template says so explicitly ("Already left one? Thank you — please ignore this"); click, feedback submission, and opt-out all suppress; the cooldown caps repeats. **This will still happen.** It is a known, accepted, disclosed limitation.

**R7 — Spam perception / merchant reputation damage.** A badly configured merchant messaging aggressively harms their own customers and, by association, us. **Mitigation:** quiet hours default on; per-contact cooldown; per-workspace monthly ceiling; opt-out-rate auto-pause at 5%; **no bulk import**, so the audience can only ever be people who tapped that merchant's own QR.

**R8 — Delayed-send queue is new infrastructure.** No scheduler exists today; webhooks are synchronous forwards. A naive queue double-sends on retry, stalls on a poison row, or fans out unboundedly. **Mitigation:** mirror the proven `webhook_deliveries` design (conditional-UPDATE claim lease, capped attempts, exponential backoff, terminal `dead_letter`) with one deliberate change — **a bounded batch size**, which the webhook sweep currently lacks (`sweep()` selects all due rows unbounded, `qr_backend/src/utilities/webhook_dispatch.py:525-531`). At message volumes that is a timeout waiting to happen. **Also verified in passing: the Worker pings `/internal/reclamation-sweep` daily (`qr_cf_code/src/index.js:77`) and no such backend route exists — that cron 404s every day today.** Do not assume "cron fires" means "job runs"; the reminder sweep needs its own success/failure metric.

**R9 — A message is money and cannot be un-sent.** Unlike a webhook retry, a duplicate send costs the merchant and annoys the customer. **Mitigation:** idempotency key per (contact, qr, cooldown window) with a unique constraint; the claim-lease before any provider call; provider message-id recorded on send; ambiguous provider outcomes (timeout after request) resolve to **assume-sent**, not retry — an unsent reminder is a much cheaper failure than a duplicate.

**R10 — Inbound webhook is a new public, unauthenticated-by-default surface.** **Mitigation:** signature verification with the BSP's shared secret before any parsing (the `razorpay/webhook` precedent), added to the public-route allow-list explicitly, strict payload validation, replay window, and no side effects beyond suppression/status updates.

**R11 — Single-BSP lock-in.** **Mitigation:** all provider calls sit behind one interface with a single adapter; nothing outside the adapter knows the BSP's name. A second adapter is additive. Accepting one BSP is the right v1 trade; hiding that fact from the code is not.

**Open Questions**
1. **Which BSP at launch?** *Recommend **Gupshup** — best India coverage, transparent per-message pricing, straightforward REST, and the largest existing base among Indian SMBs (so "connect your existing account" lands more often). Wati/Interakt are more UI-products than APIs and carry monthly SaaS floors our merchants would pay twice.*
2. **Is the phone row shown to every scanner, or only above threshold?** *Recommend: rendered for everyone (it appears below the stars before any tap) but **only above-threshold taps create a review-reminder contact**; a below-threshold tap with a phone creates a **service-recovery** contact that the review template can never target. Hiding the row until after a tap is a layout shift that costs conversion.*
3. **Marketing vs utility template category?** *Test both in beta and record which gets approved and at what rate. It does not gate v1 (the merchant pays), but it decides whether a credits SKU is ever viable.*
4. **Default delay — 2 hours or 24 hours?** *Recommend 2 h (visit still fresh, same-day intent) as the default, with the range exposed. Worth an A/B in beta; it is the cheapest lever in the feature.*
5. **Retention TTL on contacts?** *Recommend purge at **180 days** after last activity, or immediately after the reminder sequence completes plus a cooldown, whichever is sooner. Opt-out hashes retained indefinitely. Product/legal to confirm.*
6. **Does a Phase-0-only capture ship to GA, or stay internal until sending exists?** *Recommend **GA the capture** — it is honest ("get a reminder" with the merchant's setup incomplete is not), so gate the row on completed setup, which means in practice Phase 0 GA reaches only workspaces that finished onboarding. Revisit if that makes the Phase 0 sample too small to read.*

## 12. Dependencies

- **`review_funnel` QR type (shipped, `0022`):** the scan moment, star gate, `/review-go/` route, and the stored, backend-validated `google_review_url`. `qr_backend/src/api/routes/qr.py`, `qr_cf_code/src/pages/reviewFunnel/`.
- **Lead-capture path (shipped, `0012`):** `/internal/lead-submit`, consent/honeypot/IP-rate-limit, `qr_lead_forms`/`qr_lead_submissions` — the feedback arm and the `marketing_consent` thread-through.
- **Outbound webhooks (shipped, `0023`):** `webhook_deliveries` claim-lease/backoff/terminal-state model, `/internal/webhook-sweep`, and the Fernet credential-encryption pattern (`WEBHOOK_SECRET_ENC_KEY`) — the queue and the BSP-secret storage both mirror these.
- **Cron pattern (shipped):** the Worker `scheduled()` dispatch by `event.cron` and the `x-internal-secret` ping (`qr_cf_code/src/index.js:44-81`). The reminder sweep joins the **existing** `*/5 * * * *` branch — no new trigger.
- **Metering pattern (shipped):** `ai_analyst_usage` (`0014`) / `card_ocr_usage` (`0026`) + their atomic increment RPCs — `reminder_usage` mirrors them.
- **Gating engine (shipped):** `FEATURE_ENFORCEMENT` + `check_feature`/`get_limit`/`_QUOTA_SPEC` in `subscription.py`; `canAccessFeature`/`PlanFeatures` on the frontend.
- **NEW external dependency — one BSP account + a merchant-side WABA + Meta template approval.** The only hard external gate in the feature, and the only one we cannot engineer around.
- **NEW config:** BSP base URL + webhook signing secret in `qr_backend/src/config/settings/base.py`; per-workspace BSP credentials encrypted with the existing Fernet key.
- **No AI. No new cron trigger. No new QR type.**

### Appendix — Key Files

| Concern | File |
|---|---|
| Feature schema + flag seed | `qr_backend/migrations/0038_whatsapp_review_reminders.sql` (NEW — contacts, opt-outs, schedules, message queue, messaging config, usage meter) |
| Capture ingest + sweep + relaxed lead-submit | `qr_backend/src/api/routes/internal.py` (`/lead-submit` `:1234`, `ALLOWED_SUBMIT_TYPES` `:1217`, `LeadSubmitPayload` `:1220`; NEW `/reminder-contact`, `/reminder-sweep` beside `/webhook-sweep` `:1118`) |
| Workspace reminder API | `qr_backend/src/api/routes/reminders.py` (NEW — schedules, contacts, opt-outs, config, usage, test send) |
| BSP inbound webhook | `qr_backend/src/api/routes/bsp_webhook.py` (NEW — public + signature-verified; allow-list in `src/api/dependencies/auth_bearer.py`) |
| Messaging provider layer | `qr_backend/src/utilities/messaging/` (NEW — provider interface, one BSP adapter, E.164 phone utils, template registry, send/queue logic mirroring `webhook_dispatch.py`) |
| Queue pattern being mirrored | `qr_backend/src/utilities/webhook_dispatch.py` (`_claim` `:231`, `sweep` `:516`, `BACKOFF_SCHEDULE_SECONDS` `:57`) |
| KV capture block | `qr_backend/src/utilities/cloudflare_kv.py` (`build_kv_content` `review_funnel` branch `:451`; `write_to_kv` `:52`; `sync_qr_to_kv` `:307`) |
| Gating | `qr_backend/src/api/routes/subscription.py` (`FEATURE_ENFORCEMENT` `:524`, `_QUOTA_SPEC` `:429`, `get_limit` `:474`, `check_feature` `:613`) |
| Worker capture + attribution + sweep ping | `qr_cf_code/src/index.js` (`scheduled` `:44`, `*/5` branch `:78`, `/lead-submit/` `:162`, `/review-go/` `:257`; NEW `/review-contact/`, `/rr/`) |
| Worker rating template (capture row) | `qr_cf_code/src/pages/reviewFunnel/classicTemplate.js` (consent label `:41`, star tap `:255-268`) |
| Builder capture settings | `qr_frontend/src/components/qr-generator/content-types/review-funnel-rating-fields.tsx`, `review-funnel-form.tsx` |
| React template mirror | `qr_frontend/src/components/qr-generator/templates/review-funnel/` (house rule: every Worker template mirrored) |
| Settings wizard + contacts UI | `qr_frontend/src/components/org/settings/` (NEW `MessagingSection.tsx` etc., mirroring `WebhooksSection.tsx`) |
| Hooks | `qr_frontend/src/hooks/useReminders.ts` (NEW — mirrors `useWebhooks.ts` key-factory + mutation shape) |
| FE gating | `qr_frontend/src/hooks/useSubscription.ts` (`PlanFeatures` `:28`), `qr_frontend/src/lib/plan-features.ts` |
| Cron trigger (unchanged) | `qr_cf_code/wrangler.toml` (`crons` `:53` — **no change**; sweep rides the existing `*/5 * * * *`) |
