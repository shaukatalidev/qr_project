# Competitive Feature-Gap Analysis — Qravio

**Date:** 2026-07-22 · **Lens:** India-first SMB · **Deliverable:** ranked net-new gaps only

> **What this is:** every feature the leading QR platforms ship that Qravio does **not**
> already have or already plan — verified against the codebase, ranked by impact × effort ×
> India-SMB fit, with the honest hidden cost of each. This is a *subtraction* document: things
> you already have (23 QR types, deep analytics, teams, retargeting, lead forms, AI analyst, AI
> card-OCR, white-label, webhooks, custom domains, A/B, reports) and things already on your
> roadmap (Wallet Passes, Print/Poster export, SSO/SAML) were removed.

---

## Method

- **Competitor teardown** (14 profiles): Uniqode/Beaconstac, QR Code Generator PRO (Bitly/Egoditor),
  Bitly, QR Tiger, Flowcode, Scanova, QRCodeChimp, Linktree/Beacons, Popl/Blinq/HiHello, plus four
  India-specific deep-dives — UPI/GST payment mechanics, WhatsApp commerce, DPDP consent, digital-card
  fulfilment.
- **Inventory** of all three repos + `PRD_TRD/{DONE,NOT_DONE}` to establish what you already have/plan.
- **Adversarial subtraction:** each of 22 candidate gaps was grep-verified against the actual code
  (routes, hooks, migrations, PRDs) to confirm it's genuinely absent — then a skeptic pass named each
  one's hidden cost, realistic effort, and true India-SMB fit. Only survivors are ranked here.

**Legend** — Effort: S = days · M = 1–2 wk · L = 3–6 wk · XL = quarter+. Fit / Impact: 1–5.

---

## Headline finding

**Qravio is mature enough that most "obvious" India QR features are commodities, traps, or already
covered.** The teardown did *not* surface a long list of missing must-builds. It surfaced the
opposite: a handful of genuinely high-leverage moves, surrounded by a large set of features that look
India-shaped but destroy value on contact (dynamic UPI settlement, GST e-invoice QR, native WhatsApp
commerce, GPS capture). The wins cluster in two places:

1. **Leverage what you uniquely already have** — your `review_funnel` + `whatsapp` types are the seed
   for the single best India growth lever (WhatsApp-driven review generation) that *no* competitor
   ships natively.
2. **Close a few embarrassing table-stakes gaps** — you're missing QR **expiry/scheduling**, which
   every serious competitor (Beaconstac, Bitly, QR Tiger) ships and which shows up as a lost checkbox
   in head-to-head SMB comparisons.

Everything else is either a cheap SEO/completeness add or a deliberate skip.

---

## The ranking at a glance

| # | Gap | Tier | Effort | Fit | Impact | Verdict |
|---|-----|------|:------:|:---:|:------:|---------|
| 1 | WhatsApp/SMS **review-reminder automation** | Build now | L | 5 | 4 | **Core bet** — your best India growth lever; build on `review_funnel` |
| 2 | QR **expiry + scheduling** (start/end window) | Build now | M | 3 | 3 | **Core bet (table-stakes)** — visible gap vs every competitor |
| 3 | **Multilingual / vernacular** landing pages | Strategic bet | L | 4 | 3 | **Differentiator** — India's defining trait; no global rival localizes |
| 4 | **Restaurant menu** QR type (menu-only) | Strategic bet | L | 5 | 3 | Ship lean; **never** in-page ordering/checkout |
| 5 | **UPI payment QR** (static, plain) | Quick win | S | 5 | 2 | SEO + completeness only — no product moat, drop "amount-lock" |
| 6 | **Location / Google Maps** QR type | Quick win | S | 4 | 2 | Extract existing storefront-maps logic into a real type |
| 7 | **Email-signature embed** for vCard Plus | Quick win | S | 2 | 3 | Unbundle from NFC; reuse `vcard_plus` |
| 8 | **GA4** first-class relabel | Quick win | S | 2 | 2 | Already half-works; relabel the "Google" pixel slot |
| 9 | **Phone / Call** static QR | Quick win | S | 3 | 2 | Hours of work; type-parity + SEO |
| 10 | **GST invoice** on your own billing | Enabler | M | 5 | 3 | Table-stakes for GST-registered buyers' input-tax-credit |
| 11 | Org-enforced **MFA** + admin **audit log** | Enabler | S/M | 2 | 2 | Unbundle; pull forward only on a white-label/mid-market deal |
| 12 | **Loyalty / stamp card** | Fold into Wallet | XL | 4 | 3 | Build inside the planned Wallet Passes epic, not standalone |
| — | Dynamic UPI collect QR · GST e-invoice QR · GPS capture · GS1 · native Zapier app · CRM suite · AI page-gen · agency/reseller console · in-house NFC · native WhatsApp commerce | **Skip / defer** | — | — | — | See §Skips — each destroys value or serves a buyer you don't have |

> **Also flagged (not a competitor feature — a live liability):** the "Delete Account" button is a
> stub (sign-out + a "manual within 30 days" promise, **no backend cascade**). That is a real
> misrepresentation and a DPDP exposure. Fix the actual deletion cascade (Supabase tables + Storage +
> Cloudflare KV) regardless of anything else on this list.

---

## Tier 1 — Build now

### 1. WhatsApp / SMS review-reminder automation  ·  L · Fit 5 · Impact 4 · **Core bet**

**What competitors do:** none of the seven global platforms ship this natively — it's a distinct
Indian micro-category (SmartReviewer, WiserNotify, SMS India Hub). WhatsApp reminders are documented
to **~3× Google-review collection vs email**, and review volume is the #1 local-SEO lever for Indian
restaurants/retail/services.

**Why you're positioned to win it:** you already have the `review_funnel` type (sentiment gating:
happy → Google, unhappy → private form) and outbound webhooks. You own the scan moment; competitors
don't fuse the review funnel with a reminder channel.

**The catch (sequence this right — it is *not* a quick win):**
- **Consent + phone capture is the real dependency.** The happy path routes straight to Google and
  captures *no* phone number; only unhappy-path lead submitters leave contact details. You must add
  consented phone capture to the scan flow first — and do it without depressing the very conversion
  you're trying to lift.
- **Messaging ops:** WhatsApp needs BSP onboarding (Gupshup/Wati/Interakt) + WABA verification + Meta
  **marketing-template approval** + per-conversation fees. SMS needs **TRAI DLT** sender/template
  registration (brutal for self-serve SMBs). Both need DPDP consent + opt-out on stored numbers.
- **New infra:** there is no job scheduler/queue for delayed sends today (webhooks are synchronous
  forwards), and no per-message billing meter.

**Recommended shape:** Phase 1 = consented phone capture on `review_funnel` + a delayed-send queue,
reselling through one BSP (don't become a Meta Tech Provider). Gate as Pro+. This is the one item
worth real investment.

### 2. QR expiry + campaign scheduling  ·  M · Fit 3 · Impact 3 · **Core bet (table-stakes)**

**What competitors do:** Beaconstac, Bitly, QR Tiger, QRCodeChimp, Scanova all ship an expiry date
and/or a scheduled active window. You don't — and it's a literal missing checkbox in SMB comparison
tables.

**What you have that doesn't cover it:** manual `active/paused` status; scan-limit auto-disable (count-
based, not date-based); decorative start/end *display* fields on `event`/`coupon` only; routing-rules
"time" dimension (recurring daily/weekly, not a campaign window). None disable the QR by date.

**The catch (this is where the actual work is):**
- The **Worker must decide expiry at the edge** from the KV-written window — *not* wait for a cron to
  flip `status`, or a printed QR keeps redirecting live for minutes-to-hours past expiry.
- **Timezone:** SMBs think in IST; DB/cron run UTC (5.5 hr off). Store UTC, collect/display IST.
- **Status state-machine collision:** `qr_codes.status` is already overloaded (active/paused/inactive/
  scan-cap-disabled/downgrade-locked), each with its own cron + KV-sync path. Adding
  `scheduled`/`expired` multiplies the interaction matrix — regression-test every transition.

**Reuse:** mirror the existing `scanLimitPage.js` / `disabledPage.js` Worker pages and the
`_reenable_free_scan_disabled` cron pattern in `internal.py`. New migration + one Worker system page +
builder UI.

---

## Tier 2 — Quick wins (cheap parity + SEO surface)

> **Strategic note tying to your SEO plan:** items 5, 6 and 9 are commodity static types with low
> in-product impact — but each one is a new programmatic long-tail landing page ("UPI QR code
> generator", "Google Maps QR code", "phone-call QR code") in exactly the high-volume India search
> space your SEO strategy is trying to win. Ship them **for the SEO/funnel asset**, not for retention,
> and don't oversell them in-product.

### 5. UPI payment QR (static, plain)  ·  S · Fit 5 · Impact 2 · Quick win (SEO/funnel)

Copy the existing `bitcoin`/`paypal` static-type recipe (add `upi` to `qr-types.ts`, `UPIContent.tsx`
with `pa`/`pn`/`am`/`tn`, backend model + `qr_upi_details` migration; static types encode the `upi://`
URI directly, so likely **no Worker change**). **Two honesty constraints:** (a) **drop any
"fixed-amount lock" claim** — `am` is only a prefill hint; every payer app lets the user edit it, so
the headline is spec-impossible; (b) it competes with the **free, verified, settlement-backed QR every
SMB already has from their bank/PSP**, and a static code yields zero payment analytics. Validate the
VPA field to avoid becoming a phishing vector. Ship it as an SEO magnet + type-completeness, not a bet.

### 6. Location / Google Maps QR type  ·  S · Fit 4 · Impact 2 · Quick win

Partial today: address → maps link is buried inside the `business` storefront template. Extract that
logic (`storefrontTemplate.js` lines ~25-33) into a first-class `location` type (form + `build_kv_content`
branch + Worker page). Note it's substitutable by a plain URL QR pointing at a Maps link, so impact is
low — but it's cheap parity and a clean SEO page. Watch messy Indian addresses (free-text →
`search?query=` mis-pins; precise pins need Google Places API + billing).

### 7. Email-signature embed for vCard Plus  ·  S · Fit 2 · Impact 3 · Quick win

Uniqode and QRCodeChimp both distribute the digital card as an **email-signature snippet** (QR +
link). You have `vcard_plus`; this is just an embeddable HTML snippet generator on top of it — no new
data model. Unbundle it cleanly from NFC (see Skips). Near-zero cost; small B2B distribution win.

### 8. GA4 first-class relabel  ·  S · Fit 2 · Impact 2 · Quick win

Already half-works: the "Google" retargeting-pixel slot's regex accepts `G-` (GA4 Measurement IDs) and
fires `gtag.js` on landing pages. The gap is only that it's **mislabeled** as an Ads-retargeting pixel.
Rename/document it as GA4 analytics + fix the validator copy — near-free value. **Skip the GTM
container path**: letting a tenant inject an arbitrary GTM container = uncontrolled remote-JS on a page
you host (XSS/malvertising/DPDP consent-mode liability) for a feature your SMB core won't use.

### 9. Phone / Call static QR  ·  S · Fit 3 · Impact 2 · Quick win

Hours of work: add a `phone` static type (`tel:` URI) modeled on `SMSContent.tsx`. Pure commodity (no
scan analytics — expect the "why no scans on my Call QR?" support ticket), but closes type-parity and
is another SEO page. The `url` type can't substitute — its zod schema rejects non-`http(s)` schemes.

---

## Tier 3 — Strategic bets (bigger, differentiating — sequence deliberately)

### 3. Multilingual / vernacular landing pages  ·  L · Fit 4 · Impact 3 · **Differentiator**

**The one genuine differentiator no global competitor has.** Multilingual is India's defining trait
(tier-2/3 reach), and Uniqode/Bitly/QR Tiger/Flowcode are all English-first. Today every Worker
template hardcodes `<html lang="en">` and English UI chrome ("Save Contact", "Call", "Download").

**But scope it tightly.** ~80% is *already* possible — SMBs can type Devanagari/Tamil straight into
existing content fields (UTF-8 renders fine). The L-effort locale system only buys (a) visitor-language
**auto-detect** and (b) translated **static chrome**. So:
- Scope to the **top 3 visitor-facing types** (menu/business/vcard), not a 23-type locale schema.
- Provide **machine-translate defaults** so price-sensitive SMBs don't hand-author 3 language variants.
- Budget the permanent **i18n maintenance tax**: 40+ Worker templates *and* their mirrored React
  previews each carry translation dictionaries + fallback forever (your Worker↔React sync is already a
  known pain point).

### 4. Restaurant menu QR type (menu-only)  ·  L · Fit 5 · Impact 3

Indian F&B is a massive SMB wedge, and you have **no dedicated menu type** (`business`/`list_links`/
`images` are inadequate — no category→item→price→image model). Build a lean `menu` type
(`MenuContent.tsx` with nested categories, reusing the `ListLinksContent` dnd-kit pattern; backend
`qr_menu_*` tables; Worker `src/pages/menu/`).

**Hard line: never build in-page ordering/checkout.** That forks you into a food-ordering/settlement
business owned by POS-integrated incumbents (Petpooja, DotPe, UrbanPiper) who control the kitchen
printer — and drags in Razorpay Route + per-merchant KYC, FSSAI menu obligations, and BSP fees. Ship
menu-only, then pair it with `review_funnel` + item #1 (WhatsApp reminders) as a **"restaurant bundle"**
— that packaging, not the menu type itself, is the differentiation.

### 12. Loyalty / digital stamp card  ·  XL · Fit 4 · Impact 3 · Fold into Wallet Passes

Genuinely India-native (cafes/salons/retail live on paper punch-cards) and **already specced** in
`PRD_TRD/NOT_DONE/WALLET_PASSES_PRD.md` (a real `loyalty` sub-type with `qr_loyalty_details`). Today
only a **cosmetic** `coupon_stamp` template exists (always renders 0/6, no state). Two caveats that
make it XL and argue for sequencing it *after* item #1:
- **Anti-fraud stamping is unsolved.** Edge scans are anonymous/device-based → "increment on scan" is
  trivially farmed. Real loyalty needs merchant-authorized stamping (staff PIN / customer OTP) — a
  whole second flow the TRD hand-waves.
- **Wallet push is Apple-skewed** (PassKit) in a ~95%-Android market → the re-engagement payoff should
  route via **WhatsApp**, reusing item #1's infra. (Also note: the PRD's reserved migration slot 0023
  was consumed by `0023_outbound_webhooks.sql` — use a new slot after 0031.)

### 10. GST invoice on your own billing  ·  M · Fit 5 · Impact 3 · Enabler (not a differentiator)

Not a QR feature and not a differentiator (Scanova/QRCodeChimp both do it) — but a **conversion blocker**
for GST-registered buyers who need a tax invoice to claim input-tax-credit. Today it's a manual
`billing@` email workaround; there's no GSTIN field, no invoice generation, no invoice history.
**Cheap first step now:** capture GSTIN + company + billing-address (one migration + a billing-settings
form) so you *can* issue correct invoices. **Defer full automation** (sequential per-FY numbering,
CGST/SGST vs IGST place-of-supply engine, GSTR-1/3B reconciliation — unforgiving correctness bar) until
GST-registered customers are a material segment.

### 11. Org-enforced MFA + admin audit log  ·  S/M · Fit 2 · Impact 2 · Enabler

Unbundle the three sub-features the market lumps together:
- **MFA is already PRESENT** (Supabase TOTP, user-level, in Settings › Security). Only **org-enforced**
  "require all members to have 2FA" is missing (touches the Bearer-auth middleware / AAL2).
- **Admin audit log is a real gap** — you have per-user `login_events` (login history), but no
  immutable, exportable trail of admin actions (QR/member/settings/role changes). Cheap-ish `audit_log`
  table + write-path instrumentation.
- **SCIM: skip** — it's gated on SSO/SAML, which the team already made a deliberate "not now" call on.

Pull MFA-enforcement + audit-log forward **only** when a named white-label/mid-market deal needs them.

---

## Skips (with the reason, so they're off the table)

| Feature | Why skip / defer |
|---|---|
| **Dynamic UPI collect QR + settlement** | Competes with **free, ubiquitous zero-MDR** bank/BharatPe/soundbox QRs; UPI P2M zero-MDR means **no fee upside** to fund the build; forces per-merchant Razorpay KYC or pushes you toward **RBI PA-licensing** (~₹15–25 cr net worth) + refund/dispute ops you're not staffed for. |
| **GST B2C e-invoice QR** | Compliance trap: a **compliant** e-invoice QR must be **IRP-signed by NIC** (you legally can't self-generate one); the B2C dynamic-QR mandate only binds firms >₹500 cr turnover — your SMBs have **no mandate**. A self-made CGST/SGST QR is non-compliant theater. |
| **GPS-precise scan location** | The browser permission prompt fires on the landing page and **tanks the core scan conversion** (60–90% denial); adds DPDP burden; largely **redundant** with the IP-geo you already capture (the QR is at a location the SMB already knows). |
| **GS1 Digital Link** | Wrong buyer — CPG **brands/manufacturers** with licensed GTINs, not SMBs. Only worth it as a deliberate enterprise/CPG upmarket wedge. |
| **Native Zapier/Make app** | Your **webhooks + public API already bridge it** for the technical minority; the India-SMB ICP doesn't live in Zapier; a listing carries a perpetual marketplace-review + maintenance SLA. Defer to agency/global expansion. |
| **CRM connector suite (HubSpot/SF/Zoho)** | Zapier bridges it; India SMBs want "lead in my **Google Sheet / WhatsApp**", not Salesforce. If anything, carve out only a native **Google Sheets** one-click sync (and even that needs annual Google CASA security assessment). |
| **AI landing-page/copy generator** | Thin one-time surface, recurring Anthropic COGS on low-INR margins, content-liability (ASCI/health/food claims on pages you host). Only interesting **reframed as vernacular + WhatsApp-caption** copy. |
| **Agency / reseller console + SCIM** | A B2B2C channel product for a buyer you're **not selling to**; XL re-architecture of the flat owner/editor/viewer model + 5-workspace billing cap; zero demand signal. Ship only the cheap 20% (an `is_locked` flag + role-gate on `templates.py`) as an Agency-tier upsell. |
| **In-house NFC card fulfilment** | Physical-ops trap — customs/GST on NFC blanks, courier + COD reconciliation, **20–40% RTO**, warranty/Consumer-Protection obligations. If NFC ever matters, do it as a **pure affiliate/dropship handoff**, never in-house inventory. |
| **Native WhatsApp catalog/commerce (BSP stack)** | A quarter-plus pivot into a regulated, ops-heavy conversational-commerce category owned by Interakt/Wati/Gupshup. If pursued, ship a **thin BSP-reseller "catalog QR"** that deep-links a partner's catalog — don't own the messaging stack. |
| **DPDP consent tooling (full suite)** | India-native but **near-zero pull** from price-sensitive SMBs and it fights scan-to-lead conversion; converts a checkbox into a legal obligation with statutory SLAs. **Do now:** fix the fake Delete-Account cascade (above). **Defer** the configurable consent-notice / grievance-officer / retention-purge suite until an enterprise/white-label deal or DPDP-Board pressure (compliance deadline ~May 2027). |

---

## Recommended sequence

1. **Fix the account-deletion cascade** (integrity/liability, not optional).
2. **QR expiry + scheduling** (#2) — closes the visible table-stakes gap; self-contained.
3. **Quick-win SEO types** (#5 UPI, #6 Location, #9 Phone) + **GA4 relabel** (#8) + **email-sig embed**
   (#7) — batch of cheap parity/SEO assets that feed your long-tail acquisition strategy.
4. **Consented phone capture → WhatsApp/SMS review reminders** (#1) — the core growth bet; the phone-
   capture groundwork also unlocks loyalty re-engagement later.
5. **GSTIN capture on billing** (#10, cheap half) — unblocks registered B2B buyers.
6. **Menu type** (#4) + **multilingual** (#3) — the "restaurant bundle" + the differentiator.
7. **Loyalty** (#12) inside the planned Wallet Passes epic, reusing #1's WhatsApp channel.
