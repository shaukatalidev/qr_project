# PRD — UPI Payment QR (Static)

**Status:** Draft · **Author:** Product · **Date:** 2026-07-25
**Priority:** Quick win — **SEO/funnel asset + type completeness**, explicitly *not* a product bet. Ranked **#5** in `docs-internal/competitive-feature-gap-analysis.md` (S effort · Fit 5 · **Impact 2**). It buys us a high-volume India long-tail landing page ("UPI QR code generator") and fills a conspicuous hole in a type list that already ships `bitcoin` and `paypal`. It does not buy retention, and we should not pretend it does.
**Tiers:** **All plans, ungated — and this requires no decision.** Static QR types have never been gated: the plan gate in `qr.py` (~L1548) runs only `if category == "dynamic"`, and `0027_open_all_qr_types.sql` opened the dynamic list to every tier anyway. `upi` inherits the same posture as `bitcoin`/`paypal`/`wifi` by construction.
**Plan flags:** **None.** No `FEATURE_ENFORCEMENT` entry, no `plans.features` seed, no `test_feature_gate_coverage` surface. The migration is a **table only**.
**Split from:** the existing **static-type recipe** — `bitcoin` (`BitcoinContent` model `qr.py` ~L449, `qr_bitcoin_details` table, `BitcoinContent.tsx`, `generateStaticQRContent` case in `qr-generator.ts` ~L176) and `paypal` (~L470 / ~L187). **Not** split from the dynamic-QR lifecycle: there is **no** KV entry, **no** Worker page, **no** scan analytics. Deliberately **not** the "Dynamic UPI collect QR + settlement" item, which the gap analysis puts in the **Skip** column (zero-MDR means no fee upside; per-merchant KYC; RBI PA-licensing exposure).

**Rev (2026-07-25, post eng-review):** Reviewed via `/plan-eng-review`. Spec accepted **as-drafted** — a disciplined third instance of the `bitcoin`/`paypal` static recipe with no new architecture; scope, ungated posture, no-Worker verification, the VPA/parameter-injection guard, and the exhaustive encoder tests were all confirmed sound. Two cross-cutting decisions: (1) the **"static isn't tracked" disclosure ships for `upi` only** in v1 — retrofitting it to `bitcoin`/`paypal`/`wifi` is explicitly **out of scope** (supersedes Open Q3's retrofit lean); (2) the pre-existing `_normalize_web_url` mangling of scheme-only URIs (`bitcoin:`/`WIFI:` → `https://bitcoin:…`, corrupting their public-preview SVG) is filed as a **separate ticket**, not folded into this PR — the `test_upi_scheme_not_mangled` pin still lands here regardless. All internally-recorded resolutions stand (ship the `qr_upi_details` table; NPCI param names as columns; empty free-tool placeholder).

---

## 1. TL;DR / Summary

Add `upi` as a **static** QR type, mirroring `bitcoin`/`paypal` exactly. The user enters a **UPI ID (VPA)** plus an optional payee name, amount, and note; the builder encodes a standard NPCI deep link —

```
upi://pay?pa=<vpa>&pn=<payee>&am=<amount>&cu=INR&tn=<note>
```

— **directly into the QR pixels, client-side**. A payer scanning it from inside GPay / PhonePe / Paytm / any UPI app lands on a pre-filled send screen.

The whole feature is: one new `upi` entry in the type list, one `UPIContent.tsx` form, one `case 'upi'` in `generateStaticQRContent`, one backend Pydantic model + `qr_upi_details` table, and **two new SEO pages** (`/upi-qr-code`, `/upi-qr-code-generator`) that fall out of the existing `TYPE_PAGES` machinery for free.

**No Cloudflare Worker change.** Static QRs never get a KV entry (`qr.py` ~L2252 gates the KV write on `category == "dynamic"`) and `build_kv_content` has no static branches — the URI lives in the pixels, not at our edge. **No `npm run deploy:prod` gate.**

**Two things we will not claim.** (1) There is **no "fixed-amount lock."** `am` is a *prefill hint*; every payer app lets the user edit the amount before confirming. Any headline promising a locked amount is spec-impossible and we must not ship it. (2) This **competes with a free, bank-issued, verified, settlement-backed QR that every Indian SMB already has** — and unlike that one, ours yields **zero payment analytics**, because a static code never touches our infrastructure. We ship this for the search traffic and the completeness of the type grid. That is the honest case, and it is a sufficient one.

## 2. Problem & Motivation

**The SEO case is the real case.** Our strategy memo's bottleneck is authority + indexation, and the play is to win the long tail first. "UPI QR code generator" is one of the highest-volume commercial-intent QR queries in the Indian search space we are trying to own. The `TYPE_PAGES` machinery already turns a new static type into **two indexed pages with unique copy** and a working, no-account, client-side tool — `/upi-qr-code` (informational) and `/upi-qr-code-generator` (free tool), both auto-registered in `generateStaticParams` and `sitemap.ts`. The marginal cost of that asset, given the machinery exists, is a form component and a URI template.

**The completeness case is secondary but real.** We ship `bitcoin` and `paypal` — a payment-request type for a currency almost none of our Indian users hold, and one for a rail that is marginal in India — while omitting the payment rail that essentially **all** of them use. In a type-grid screenshot or a comparison table, that reads as an oversight. Filling it costs a day.

**What we are honestly *not* solving.** An Indian merchant's payment-collection problem is already solved:

- Their bank or PSP (BharatPe, Paytm, PhonePe, a soundbox vendor) hands them a **free, printed, verified** QR wired to their settlement account.
- That QR is **verified** — the payer app shows a confirmed merchant name; ours shows whatever string the creator typed into `pn`.
- That QR produces **settlement records, reconciliation, and payment analytics**. A static Qravio UPI QR produces **nothing**: no scan event, no redirect, no dashboard row, because static QRs bypass the Worker entirely.

So the buyer for this is not "an SMB that needs to accept UPI." It is the long tail of **individual and one-off collectors** — a freelancer's invoice footer, a temple donation box, a society maintenance notice, a workshop fee poster, a tip jar — for whom "make me a nice QR with my UPI ID on it, right now, without an account" is the entire job. That user arrives from Google, uses the free tool, and *may* convert later. That is the funnel we are buying.

**Why now.** It is an `S`-sized item that reuses a recipe already executed twice. There is no dependency, no external service, no AI, no cost, no cron, no edge deploy.

## 3. Goals & Non-Goals

**Goals**
- Add `upi` as a **static** QR type end-to-end, following the `bitcoin`/`paypal` recipe with no new architectural pattern.
- Encode a spec-correct `upi://pay?…` deep link with `pa` (VPA, required), `pn`, `am`, `tn`, and a fixed `cu=INR`, with correct percent-encoding and empty-field omission.
- **Validate the `pa` (VPA) field** server-side and client-side against the VPA grammar — a payment QR that accepts arbitrary text is a phishing primitive, not a feature.
- Ship **two SEO pages** (`/upi-qr-code`, `/upi-qr-code-generator`) with unique, non-thin copy, plus the free no-account tool via `PublicQRBuilder`.
- **Set expectations honestly in-product**: this is a plain, unverified UPI link; the amount is a suggestion; there are no payment analytics.
- Ungated on every plan, consistent with every other static type.

**Non-Goals**
- **No "amount lock" / "fixed amount" claim anywhere** — product copy, marketing copy, FAQ, or meta description. `am` prefills; the payer edits it. This is a **hard copy constraint**, not a preference. (§11 R1)
- **No dynamic UPI, no collect flow, no settlement, no reconciliation, no payment status.** That is the Skip-column item: zero-MDR on P2M means no fee upside to fund it, it forces per-merchant PSP KYC, and it walks toward RBI payment-aggregator licensing. Out of scope permanently, not just for v1.
- **No merchant verification.** We cannot confirm a VPA is owned by the person entering it — NPCI VPA-validation APIs require PSP membership we do not have. We validate **format**, never **ownership**, and we say so.
- **No signed / verified merchant QR** (`mc`, `tr`, `sign` params). Those require merchant onboarding through a PSP.
- **No scan analytics** — impossible for a static type by construction. We will not imply otherwise.
- **No dynamic `upi` variant** ("upgrade this to a trackable UPI landing page"). Tempting, and it is the one path to analytics, but it inserts a Qravio interstitial between a payer and their money — a materially worse and more suspicious payment experience. Explicitly deferred; see §7 and §11 R5.
- **No Worker change, no KV entry, no landing page template.**
- **No other UPI-adjacent India features** (GST e-invoice QR, UPI-settlement dashboards) — both are Skip-column items.

## 4. Target Users & Personas

| Persona | Who | Job-to-be-done | Today's pain |
|---|---|---|---|
| **Freelancer ("Nikhil")** | Designer/consultant invoicing Indian clients | A QR on the invoice PDF footer so a client pays in two taps | Pastes a raw VPA string; client mistypes it, or pays the wrong person |
| **One-off Collector ("Priya")** | Society treasurer / event organiser / teacher collecting fees | A printable poster QR for a fixed collection drive | Screenshots her GPay QR — low-res, personal, no branding, wrong crop |
| **Donation Box ("Trust admin")** | Temple, NGO, school desk | A durable printed QR with the trust's name and a note | Bank QR is a laminated PSP sticker; can't brand or reprint it |
| **SEO arrival (the real volume)** | Searched "UPI QR code generator" | Generate + download a QR **right now**, no signup | Competing free tools are ad-choked; ours is clean and becomes a funnel entry |

**Explicit non-persona:** the SMB with a counter and a soundbox. They already have a free, verified, settlement-backed QR and there is no honest reason to switch. Do not target them; do not build for them.

## 5. User Stories

- As a **freelancer**, I want to generate a QR from my UPI ID and drop it in my invoice footer, so that clients pay without copying a VPA by hand.
- As a **society treasurer**, I want to print a poster QR with a payee name and a note ("Maintenance — Flat 402"), so residents know what they are paying for before they confirm.
- As a **trust admin**, I want a branded, high-resolution downloadable QR (SVG/PDF), so it prints sharply on a donation board.
- As **anyone entering a UPI ID**, I want to be told immediately if what I typed isn't a valid VPA, so I don't print a code that fails at the payer's app.
- As a **payer**, I want the scan to open my UPI app with the recipient (and, if set, the amount) pre-filled, so I only review and confirm.
- As **any user**, I want the product to tell me plainly that the amount is a **suggestion the payer can change**, and that this code is **not a verified merchant QR** and **records no payment data** — so my expectations match reality.
- As a **visitor from Google**, I want to generate and download a UPI QR without creating an account, so the tool page is actually useful — and I want an obvious reason to sign up afterwards.

## 6. UX / Product Flow

**6.1 Type selection**
`upi` appears in the **Static** section of the type picker (`qr-types.ts` static block, ~L110–119, beside `bitcoin` and `paypal`) as **"UPI"** — *"Accept a UPI payment"* — with a payments icon. Static types are ungated, so it is visible and creatable on every plan including Free.

**6.2 Content step — `UPIContent.tsx`**
Four fields, react-hook-form + zod, shadcn primitives, matching `BitcoinContent.tsx` field-for-field in structure:

| Field | UI label | Required | Notes |
|---|---|---|---|
| `pa` | **UPI ID (VPA)** | ✅ | `name@bank` · inline validation against the VPA grammar |
| `pn` | **Payee name** | — | Shown in the payer's app; **unverified free text** |
| `am` | **Amount (₹)** | — | Helper text: *"Suggested amount — the payer can change it before paying."* |
| `tn` | **Note** | — | Short reference shown to the payer |

**Three honesty affordances, all required:**
1. **Amount helper text** (above) — never "lock", never "fixed", never "exact".
2. An inline note under the form: *"This creates a plain UPI link — not a verified merchant QR. Your payer's app will not show a verified business name."*
3. An inline note in the preview/download step: *"Static QR codes are not tracked. Scans and payments won't appear in your dashboard."* (Reuse whatever static-vs-dynamic disclosure the other static types already carry; if none exists, this type is the right place to introduce it.)

**6.3 Design + download**
Unchanged. The live preview and every export path already call `generateStaticQRContent(type, content)` (`QRPreview.tsx` ~L65, `MobilePreview.tsx` ~L68, `useQRPreview.ts` ~L32) — adding one `case 'upi'` lights up preview, PNG/JPG/SVG/PDF export, and logo/colour design with no further work.

**6.4 After save**
Standard static-QR behaviour, inherited with zero new code: the row is persisted with a `qr_upi_details` record and a `qr_destinations` row holding the `upi://` URI; the QR detail page renders the content via `content-editor-dispatch.tsx`; and **editing is name-only** — `qr.py` (~L2790) already 403s any other field change on a static QR, with the message *"Static QR codes can only have their name updated."* A user who wants to change the VPA creates a new QR. This is existing, consistent behaviour across all static types; we surface it in the form's helper copy rather than changing it.

**6.5 Scan behaviour (set expectations, don't over-promise)**
The `upi://` scheme resolves inside UPI apps. Scanning from GPay/PhonePe/Paytm/BHIM/a bank app works as expected. Scanning a `upi://` code from a **generic phone camera app** — especially on iOS — may do nothing, because the OS has no handler registered. This is **identical to the printed bank QR at every shop counter** (Indians overwhelmingly scan from *inside* a payment app), so it is not a regression against the alternative — but our marketing copy must say **"scan with any UPI app,"** never "scan with your camera." (§11 R3)

**6.6 SEO surfaces (the actual deliverable)**
Two pages, both generated by the existing dispatcher at `qr_frontend/src/app/(marketing)/[slug]/page.tsx` from one new `TYPE_PAGES` entry with `slug: 'upi'`, `category: 'static'`, `isStaticTool: true`:
- **`/upi-qr-code`** — informational: what a UPI QR is, how the `upi://pay` deep link works, use cases, benefits, FAQs.
- **`/upi-qr-code-generator`** — the free, no-account client-side tool (`PublicQRBuilder` with `upi` preselected) + how-to copy + FAQs from `tool-faqs.ts`.

Both are picked up automatically by `generateStaticParams` and `sitemap.ts` (~L42–52). Add the footer link in `LandingFooter.tsx` (~L20) beside the Bitcoin generator. **Copy must be unique** (anti-thin-content) and **must not** contain a fixed-amount claim.

## 7. Scope

**In scope (v1)**
- `upi` static type: type-list entry, icon, `QRType` constant, recommendations/swatch entries.
- `UPIContent.tsx` (create) + the `case 'upi'` in the builder dispatch and the QR-detail content-editor dispatch.
- `case 'upi'` in `generateStaticQRContent` producing a spec-correct, correctly-encoded `upi://pay?…` with `cu=INR`.
- Backend: `UpiContent` Pydantic model, `upiContent` on `QRContent`, `"upi"` in the type `Literal`, `qr_upi_details` in `SELECT_WITH_RELATIONS`, detail insert on create, round-trip through `_build_content_from_db_rows`, `QRUpiDetailsResponse`.
- **VPA validation** (client zod + server-side, defence in depth) → `422` on malformed.
- Migration **`0034`** (provisional): `qr_upi_details` table only — no `plans` seed.
- Free public tool wiring: `PublicQRBuilder` `hasContent` case, `TYPE_PAGES` entry, `tool-faqs.ts` entry, footer link, API-docs constants.
- Honesty copy: amount-is-a-suggestion, not-a-verified-merchant-QR, static-is-not-tracked.

**Out of scope / Future**
- **Dynamic UPI collect QR, settlement, payment status, reconciliation** *(Skip column — permanently out, not deferred)*.
- **Merchant/VPA verification, signed merchant QRs (`mc`/`tr`/`sign`)** *(requires PSP membership)*.
- **A trackable `upi` dynamic variant** routing through a Qravio interstitial *(deferred; degrades the payment experience and invites suspicion — §11 R5)*.
- **Editing a static UPI QR's VPA/amount after save** *(blocked today for all static types by `qr.py` ~L2790; changing that is a cross-cutting static-QR decision, not a UPI one)*.
- **GST e-invoice QR, UPI-settlement analytics, soundbox integrations** *(Skip column)*.
- **Bulk UPI QR generation** *(bulk import is website-only today, `qr.py` ~L2424–2433)*.
- **Multi-currency** — `cu` is hardcoded `INR`; UPI is INR-only in practice.

## 8. Pricing & Packaging

| Surface | Tier | Flag / Limit |
|---|---|---|
| UPI static QR type | **All plans (Free, Starter, Pro, Agency)** | **None** — static types are structurally ungated |
| `/upi-qr-code-generator` free tool | **No account required** | n/a — client-side, no backend call |

**Why ungated is not a decision.** The plan gate in `qr.py` (~L1546–1567) is wrapped in `if category == "dynamic"`, so no static type has ever consulted `plans.features`. `0027_open_all_qr_types.sql` then removed type-as-paywall for dynamic types too, with the reasoning stated in the migration header: *"QR type is no longer a paywall lever."* Gating `upi` would require inventing a static-type gate that does not exist — a strictly worse outcome for a type whose entire value is being a free, indexable, no-friction funnel entry.

**Where the money actually is.** The real fences are unchanged and enforced independently: `max_qr`, `max_scans`, analytics retention, custom domains, white-label, branding, bulk, API, seats. This feature touches none of them. Its commercial job is **top-of-funnel**: rank for the query, serve the free tool, and offer the honest upsell — *"want to know how many people scanned this? Make it dynamic."* That cross-sell is the same static→dynamic ladder the `/scan` tool already runs.

**Consequence for the build:** no `FEATURE_ENFORCEMENT` row, no `plans.features` blob seed, no `_QUOTA_SPEC` entry, and **no `test_feature_gate_coverage` exposure**. The migration is one `CREATE TABLE`.

## 9. Success Metrics & KPIs

This is an SEO/funnel asset. Measure it as one — **do not** measure it on in-product retention, which it will not move.

**Search (the primary bar)**
- `/upi-qr-code-generator` **indexed and ranking** for its head term within 90 days of GA; impressions trending up in Search Console. Set the bar at indexation + first-page-adjacent long-tail, not at #1 for the head term.
- Both pages pass the anti-thin-content bar: unique copy, unique FAQs, no duplicate meta.

**Funnel**
- **Tool → signup conversion** on `/upi-qr-code-generator` at or above the median of the existing static tool pages (`bitcoin`, `wifi`, `whatsapp`). If it lands materially below, the copy or the CTA is wrong, not the feature.
- Non-zero share of `upi` in newly created static QRs inside the app — a completeness signal, not a target to optimise.

**Correctness / trust (the bar that actually matters)**
- **100% of generated URIs are spec-valid and open correctly** in GPay, PhonePe, Paytm, and BHIM — verified by hand on real devices before GA (§10). A payment QR that fails at the payer's app is worse than no feature.
- **Zero fixed-amount claims** shipped in product copy, meta descriptions, FAQs, or the landing pages. Auditable, binary, and a release gate.
- **Zero malformed VPAs persisted** — validation rejects them at write time.

**Explicitly not a metric:** payment volume, payment success rate, settlement, or scan counts. We cannot measure any of them for a static QR, and any dashboard implying we can is a bug.

## 10. Rollout Plan

**Phase 0 — Type + encoder (internal).**
Migration `0034` (`qr_upi_details`). Backend model, type `Literal`, `SELECT_WITH_RELATIONS`, detail insert, content round-trip, VPA validation. FE: `UPIContent.tsx`, `generateStaticQRContent` case, type-list/icon/constants wiring, both dispatch sites.
- **Acceptance:** create a `upi` QR → the encoded value is exactly the expected URI → the detail row persists → reopening the QR shows the entered values → a malformed VPA is rejected → **no KV write occurs** (assert it, don't assume it).

**Phase 1 — Real-device verification (release gate, non-negotiable).**
Generate codes covering: VPA only; VPA + name; VPA + name + amount; VPA + name + amount + note; a note containing spaces, `&`, and Devanagari characters. Scan each from **GPay, PhonePe, Paytm, and BHIM** on real hardware. Confirm the recipient resolves, the amount prefills, and the note appears. **This gate blocks GA** — a mis-encoded payment URI is the one failure mode that costs a real user real money.

**Phase 2 — GA + SEO pages.**
`TYPE_PAGES` entry (both page copies), `tool-faqs.ts` entry, `PublicQRBuilder` case, footer link, API-docs constants. Verify `/upi-qr-code` and `/upi-qr-code-generator` build statically, appear in `sitemap.ts` output, and carry correct canonicals. **Copy review gate: no fixed-amount language, no verified-merchant implication, no analytics implication.** Submit to Search Console.

**Cross-service gates — all clear:**
- **No Worker change → `npm run deploy:prod` is NOT required.** Static QRs get no KV entry (`qr.py` ~L2252) and `build_kv_content` has no static branch. The worker↔React template-mirroring rule does not apply (there is no scan page).
- **No email** → the unpublished `_dmarc.qravio.app` record is **not** a gate.
- **No cron, no external service, no AI, no new env var, no secret.**
- **Deploy order:** apply `0034` → deploy backend (the detail insert needs the table) → deploy frontend.

## 11. Risks, Edge Cases & Open Questions

**R1 — The fixed-amount claim (the one that must not ship).** Competitors' UPI QR pages routinely imply the amount is locked. It is not: `am` is a prefill hint and every payer app exposes an editable amount field before confirmation. Shipping that claim would be a false statement about how someone gets paid. **Mitigation:** treat it as a **copy release gate** — grep the diff for "lock"/"fixed"/"exact amount" across the form, FAQs, `TYPE_PAGES` copy, and meta descriptions before GA. In-product helper text states the truth affirmatively: *"Suggested amount — the payer can change it before paying."*

**R2 — Phishing vector (the security risk).** A payment QR generator is, by construction, a tool for pointing strangers' money at an arbitrary account. **Mitigation:** validate `pa` against the VPA grammar (reject spaces, control characters, embedded URLs, multiple `@`, missing handle) on both client and server; cap `pn`/`tn` length; ensure every value is percent-encoded into the URI so no field can inject additional `&`-separated parameters (e.g. a note containing `&am=99999`). **Be explicit about the limit:** format validation is **not** ownership verification — a well-formed VPA can still belong to a fraudster, and no free generator on the market solves that. We do not claim to.

**R3 — Camera-app scan expectations.** A `upi://` code scanned from a generic camera app (notably iOS) may not open anything. **Mitigation:** copy says **"scan with any UPI app"**, never "point your camera." Note honestly that this matches the behaviour of the printed bank QR at every Indian shop counter — the norm is scanning from inside a payment app — so we are at parity with the alternative, not behind it.

**R4 — We are competing with a free, verified, settlement-backed incumbent.** Every SMB already has a bank/PSP QR that is verified, produces settlement records, and cost them nothing. Ours is unverified and produces nothing. **Mitigation:** do not target that buyer (§4 non-persona). Target the freelancer/one-off-collector long tail and the search arrival. Ship as an SEO magnet + type completeness — the framing this PRD is built on.

**R5 — The analytics-shaped hole, and the trap in filling it.** Static means zero scan data, which will generate "why can't I see scans?" questions. The obvious fix — a dynamic `upi` type that routes through a Qravio page — is a **trap**: it inserts an unexpected third party between a payer and their money, which is exactly what payment-fraud training tells Indian users to distrust. **Mitigation:** v1 sets expectations plainly instead. Revisit only with evidence, and never by silently making a payment redirect through us.

**R6 — Post-save immutability.** A static UPI QR's VPA cannot be edited after creation (`qr.py` ~L2790, name-only updates). Someone who prints 500 posters against a typo'd VPA has a real problem. **Mitigation:** strong client-side validation plus a **confirm-the-VPA** review step before save. Changing static-QR immutability is a cross-cutting decision that should not be made inside this feature.

**R7 — Field-naming divergence.** `bitcoin`/`paypal` use semantic field names (`address`, `amount`, `username`). Using the raw UPI parameter names (`pa`/`pn`/`am`/`tn`) as model/column names diverges from that. **Mitigation/decision:** use the **spec names** — they are self-documenting against the URI they build, and any future reader diffing the model against the NPCI spec sees a 1:1 map. UI labels stay human ("UPI ID (VPA)", "Payee name", "Amount (₹)", "Note"). Recorded here so it is a decision, not an accident. (Open Q1)

**R8 — `am` formatting.** UPI expects a decimal amount with at most two places. `1000.005`, `1,000`, or `₹1000` will be rejected or mishandled by payer apps. **Mitigation:** validate as a positive number with ≤2 decimals, normalise to a plain `1000.00`-style string, strip separators and currency symbols before encoding.

**Open Questions**
1. **`pa`/`pn`/`am`/`tn` vs semantic column names?** *Recommend the spec names, per R7. TRD decision, and it is made.*
2. **Do we need `qr_upi_details` at all, or can the `upi://` URI in `qr_destinations.target_url` be the single source of truth (no migration)?** *Recommend the table — it preserves symmetry with every other static type, keeps `_build_content_from_db_rows` uniform, and avoids re-parsing a URI to repopulate a form. The no-table variant is genuinely viable and would drop the migration entirely; see TRD §2 for the trade-off.*
3. **Ship the "static isn't tracked" disclosure for `upi` only, or retrofit it across all static types?** *Resolved (post eng-review): `upi`-only in v1. The identical gap on `bitcoin`/`paypal`/`wifi` is acknowledged but explicitly out of scope for this PR.*
4. **Does the free tool page pre-fill anything or start empty?** *Recommend empty with a realistic placeholder (`yourname@okhdfcbank`) — never a working VPA, which would be a live payment target sitting on an indexed page.*

## 12. Dependencies

- **Static-type recipe (shipped, executed twice):** `bitcoin` (`qr.py` ~L449 / `qr_bitcoin_details` / `BitcoinContent.tsx` / `qr-generator.ts` ~L176) and `paypal` (~L470 / ~L187). This feature adds a third instance and no new pattern.
- **Static-QR persistence path (shipped):** `qr_destinations.target_url` stores the encoded URI (the FE sends it from `build/page.tsx` ~L282/~L336); `_normalize_web_url` (`qr.py` ~L74) passes `upi://…` through untouched because `_SCHEME_RE` (~L71) matches a `://` scheme.
- **Client-side encoder (shipped):** `generateStaticQRContent` (`qr-generator.ts` ~L132) — one new `case`, and preview + all four export formats work.
- **Programmatic SEO machinery (shipped):** `TYPE_PAGES` + `resolveTypeSlug` (`qr-type-pages.ts`), the `(marketing)/[slug]` dispatcher, `sitemap.ts` (~L42–52), `tool-faqs.ts`, `PublicQRBuilder`. One data entry yields two indexed pages and a working free tool.
- **Migration mechanism (shipped):** hand-applied SQL in `qr_backend/migrations/`; provisional slot **`0034`** — **verify against `qr_backend/migrations/` at build time**: latest on disk is `0032_lemonsqueezy_variant_backfill.sql` and `0033` is claimed by QR Expiry + Campaign Scheduling.
- **No Worker, no KV, no cron, no email, no AI, no external service, no new env var, no plan flag.**

### Appendix — Key Files

| Concern | File |
|---|---|
| Detail table | `qr_backend/migrations/0034_qr_upi_details.sql` (NEW — `qr_upi_details`; **verify slot**, `0033` = QR expiry) |
| Backend model + type + persist | `qr_backend/src/api/routes/qr.py` (`UpiContent` beside `BitcoinContent` ~L449; `upiContent` on `QRContent` ~L544; `"upi"` in the type `Literal` ~L860; `SELECT_WITH_RELATIONS` ~L998; content round-trip ~L1071/~L1211/~L1399/~L1427; detail insert ~L2001; static-update block ~L2790 unchanged) |
| VPA validation | `qr_backend/src/api/routes/qr.py` (field validator on `UpiContent.pa`, mirroring `_validate_google_review_url` ~L513 as the write-time-guard precedent) |
| URI encoder | `qr_frontend/src/lib/qr-generator.ts` (`generateStaticQRContent` ~L132; new `case 'upi'` beside `bitcoin` ~L176) |
| Builder form | `qr_frontend/src/components/qr-generator/content-types/UPIContent.tsx` (NEW — mirrors `BitcoinContent.tsx`, ≤200 lines) |
| Builder dispatch | `qr_frontend/src/components/qr-generator/QRContent.tsx` (~L534) + `qr_frontend/src/components/org/qrs/details/content-editor-dispatch.tsx` (~L187) |
| Type registry | `qr_frontend/src/lib/constants/qr-types.ts` (static list ~L118; `QR_TYPES` ~L208; `TYPE_ICONS` ~L239) + `qr-type-icons.ts` (~L38), `qr-recommendations.ts` (~L51), `template-swatch-colors.ts` (~L34), `BuilderSidebar.tsx` (~L54) |
| FE types | `qr_frontend/src/lib/types/qr.ts` (`UpiContent` iface ~L379; `upiContent` on `QRContent` ~L446; icon map ~L865) |
| SEO pages | `qr_frontend/src/lib/constants/qr-type-pages.ts` (NEW `slug: 'upi'` entry, `isStaticTool: true`) — auto-served by `(marketing)/[slug]/page.tsx` + `sitemap.ts` (~L42–52) |
| SEO copy | `qr_frontend/src/lib/constants/tool-faqs.ts` (~L144 beside `bitcoin`), `qr_frontend/src/components/landing/LandingFooter.tsx` (~L20) |
| Free tool | `qr_frontend/src/components/marketing/PublicQRBuilder.tsx` (`hasContent` case ~L44) |
| API docs | `qr_frontend/src/lib/constants/api-docs-objects.ts` (`STATIC_TYPES` ~L100; field table ~L116) |
| Worker | **No change** (no KV entry, no `build_kv_content` branch, no template, no cron) |
