# PRD — GST Invoice on Your Own Billing (v1: GSTIN + Billing-Details Capture)

**Status:** Draft · **Author:** Product · **Date:** 2026-07-25
**Priority:** Conversion **enabler**, not a differentiator (Scanova and QRCodeChimp both ship it). A GST-registered Indian buyer cannot claim input-tax-credit without a tax invoice carrying their GSTIN; today the only path is a manual `billing@qravio.app` email. This is the cheap half of gap-analysis item **#10** — capture the data so a correct invoice *can* be issued — and nothing more.
**Tiers:** **All plans, ungated.** It is a billing enabler, not a feature: a Free workspace must be able to fill in billing details *before* its first checkout so the very first invoice is right. Confirmed from the billing code — `get_current_subscription` (`razorpay_routes.py:708`) serves Free workspaces a synthetic `free-tier` response, so there is no plan boundary to hang this on and none should be invented.
**Plan flags:** **None.** No `FEATURE_ENFORCEMENT` entry, no `plans.features` key, no `test_feature_gate_coverage` surface. The migration is a table, not a flag seed.
**Split from:** the billing surface — `qr_backend/src/api/routes/razorpay_routes.py` (subscription lifecycle, `subscriptions` table) and the billing page (`qr_frontend/src/app/[slug]/(dash)/billing/`). Mirrors the per-workspace settings-resource pattern of **white-label branding** (`workspace_branding`, migration `0011`, `branding.py` GET/PUT, `useBranding.ts`) — same 1:1 table, same two endpoints, same hook shape. **Not** the GST **e-invoice QR** (a documented skip: a compliant e-invoice QR must be IRP-signed by NIC, and the B2C dynamic-QR mandate binds only firms >₹500 cr — self-generating one is non-compliant theater).

**Rev (2026-07-25, post eng-review):** Reviewed via `/plan-eng-review`; ships **as-drafted** — a clean settings-resource over the shipped `workspace_branding` pattern, with all the unforgiving GST correctness (per-FY numbering, place-of-supply, reconciliation, e-invoice) correctly deferred. Decision: **GSTIN validation is format + mod-36 checksum only in v1** — live GSTN-API verification (active-status + registered-legal-name lookup) is deferred to the invoice-engine phase; self-declared matches today's `billing@` posture and v1 issues no automated invoice. Open questions accepted per recommendations (key on `workspace_id`, resolving inherited via `billing_workspace_id`; **warn** not block on GSTIN-state ↔ address-state mismatch with the GSTIN state canonical; non-blocking upgrade prompt; capture company/address on the USD rail too; single legal-name field). **Two carry-forwards:** (1) `workspace_billing_profile` holds business PII and **must be included in the account-deletion cascade fix** (same as the WhatsApp/signature tables); (2) R1 operational readiness — the Terms already promise GST invoices, so confirm the manual `billing@` process reliably issues correct invoices before this prominent field raises the expectation. The **mod-36 checksum must be tested against known-good + one-char-mutated vectors** (§9) — a wrong implementation silently rejects valid GSTINs or accepts invalid ones.

---

## 1. TL;DR / Summary

A workspace **owner** on the billing page can save a **billing profile**: legal/company name, GSTIN,
billing address (line 1/2, city, state, PIN), and a billing email. The GSTIN is **format- and
checksum-validated** server-side (15 characters: 2-digit state code + 10-char PAN + entity code +
literal `Z` + check character). The profile is stored once per workspace and is attached to the Razorpay
subscription `notes` at checkout so finance can read it straight off the payment record.

That is the **whole** feature: one migration (a `workspace_billing_profile` table mirroring
`workspace_branding`), one GET/PUT route pair mirroring `branding.py`, one card on the billing page, and
one hook. **No invoice is generated.** The manual `billing@qravio.app` workaround stays — it just becomes
correct and fast, because the data finance needs is on file and structured instead of retyped out of an
email thread.

**Deliberately boring, and deliberately half a feature.** Sequential per-financial-year invoice numbering,
the CGST/SGST-vs-IGST place-of-supply engine, and GSTR-1/3B reconciliation are an *unforgiving* correctness
bar — a wrong invoice number series or a wrong tax split is a compliance defect the customer's CA will
catch, not a UI bug we can hotfix. That work is explicitly deferred (§3, §7, §10 Phase 2) until GST-registered
customers are a material segment. This PRD buys the option on that work for one table.

**One rail only.** Lemon Squeezy is the **merchant of record** for the USD rest-of-world rail — it is the
seller and issues its own tax invoice (`qr_backend/src/integrations/mor/base.py:4`). Qravio legally cannot
issue a GST invoice for a Lemon Squeezy sale. GSTIN capture therefore applies to the **Razorpay/INR rail**,
where Qravio *is* the seller of record. The billing page already knows which rail a user is on
(`currencyForCountry` in `qr_frontend/src/lib/geo.ts`), so this is a rendering condition, not new machinery.

## 2. Problem & Motivation

**A GST-registered buyer cannot expense us without a tax invoice.** For any Indian business registered
under GST, a purchase without a compliant tax invoice bearing *their* GSTIN is a purchase on which they
cannot claim input-tax-credit — it is ~18% more expensive in real terms than the sticker price. For a
₹1,000/mo tool that is enough friction to stall a card entry. The buyer's finance team asks "can I get a
GST invoice?" *before* paying, and today the honest answer is "email us afterwards."

**Today the answer is an email address.** We already tell people this in two places:
- `qr_frontend/src/components/marketing/HelpContent.tsx:130-131` — *"If you need a GST invoice with your
  GSTIN, email billing@qravio.app with your details after purchase."*
- `qr_frontend/src/app/(marketing)/terms/page.tsx:127-131` — *"Invoices will reflect the GST component. If
  you are a GST-registered business and require a tax invoice with your GSTIN, email …"*

So the promise is already made in the Terms. What is missing is any product surface behind it: there is **no
GSTIN field anywhere in the codebase** (verified — the only `company_name` hits are the vCard/apps content
model at `qr_backend/src/api/routes/qr.py:801`), no invoice generation, and no invoice history. Finance
receives the buyer's details as free text in an email, retypes them, and hopes the GSTIN is right.

**The competitors ship it, so it reads as missing.** Scanova and QRCodeChimp both take a GSTIN at checkout.
In a side-by-side evaluation by an Indian SMB's finance-adjacent buyer, "no GSTIN field" is a visible blank
cell, and one that signals "not built for Indian businesses" — an especially bad signal for a product whose
whole pricing rail is India-first.

**The cheap half is genuinely cheap, and it is the half that unblocks the sale.** Capturing GSTIN + company
+ address is one table and one form. It does not commit us to an invoice engine; it makes the *existing*
manual process correct, auditable, and same-day, and it lets the pre-purchase question be answered "yes —
add your GSTIN in Billing and we'll invoice you against it." The expensive half (numbering series, place-of-
supply, reconciliation) can wait for evidence that enough of our revenue is GST-registered to justify the
correctness bar.

## 3. Goals & Non-Goals

**Goals**
- Let a workspace **owner** save a billing profile — **legal name**, **GSTIN** (optional), **billing address**
  (line 1/2, city, state, postal code, country), **billing email** — from the billing page.
- **Validate the GSTIN properly**: 15-character layout, state code in the valid set, embedded PAN pattern,
  literal `Z` in position 14, **and the mod-36 check character**. Reject silently-wrong values at write time;
  never store an invalid GSTIN.
- **Attach the profile to the payment record**: pass `gstin` and legal name into the Razorpay subscription
  `notes` at create/upgrade (the `notes` dict already exists at `razorpay_routes.py:301` and `:618`), so the
  data finance needs is on the Razorpay payment itself and the manual invoice takes seconds.
- **Respect owner-scoped billing**: the profile belongs to the workspace the subscription actually lives on.
  A workspace showing an *inherited* plan (`is_inherited=true`) displays that profile **read-only** and points
  management at `billing_workspace_id`, exactly as `CurrentPlanCard` already does for the plan itself.
- **Be honest about the rail**: show the GSTIN field on the INR/Razorpay rail; on the USD rail, state plainly
  that Lemon Squeezy is the merchant of record and issues the invoice.
- Ungated, all plans, no new plan flag.

**Non-Goals**
- **No invoice generation in v1.** No PDF, no HTML invoice, no invoice number, no line items, no HSN/SAC.
  The `billing@qravio.app` workaround remains the delivery mechanism.
- **No invoice numbering series.** Sequential, gap-free, per-financial-year numbering (with the ₹-value and
  format constraints GST imposes) is a compliance artifact, not a string format — deferred.
- **No place-of-supply engine.** CGST+SGST for intra-state vs IGST for inter-state, derived from the seller's
  registered state and the buyer's place of supply, is the single most error-prone part of GST and is
  **explicitly deferred**. v1 stores the state; it computes nothing.
- **No GSTR-1 / GSTR-3B reconciliation, no e-invoice / IRP / IRN, no credit notes, no reverse-charge, no
  OIDAR handling.** All deferred.
- **No invoice history UI** and **no emailed invoices** (an emailed invoice would also drag in the
  unpublished `_dmarc.qravio.app` gate — deliberately avoided in v1).
- **No pricing change.** Prices remain **GST-inclusive** as the Terms already state; v1 does not add a "+18%
  GST" line at checkout, does not display an ex-GST price, and does not re-price anything. Whether B2B buyers
  should see ex-GST pricing is a *pricing* decision, not this feature.
- **No GST e-invoice QR code** — a documented skip (must be IRP-signed by NIC; no mandate applies to our
  SMBs; a self-made CGST/SGST QR is non-compliant theater).
- **No Worker / KV / edge change.** The billing profile never reaches the scan path. It is not an entitlement.
- **No GSTIN on the Lemon Squeezy rail.** LS is the merchant of record; we cannot issue that invoice.

## 4. Target Users & Personas

| Persona | Who | Job-to-be-done | Today's pain |
|---|---|---|---|
| **Registered SMB Owner ("Vikram")** | Pvt Ltd / LLP with a GSTIN, buys SaaS on the company card | Claim input-tax-credit on the subscription | No GSTIN field; must email `billing@` after paying and hope |
| **Finance/Accounts Executive ("Priya")** | Books the expense, files GSTR-3B | A tax invoice with the correct GSTIN and legal name | Chases the vendor by email; retyped details, wrong legal name |
| **Agency Owner ("Amit")** | Pays for up to 5 workspaces under one owner | One billing identity across all his workspaces | Would otherwise re-enter the same GSTIN per workspace |
| **Pre-purchase Evaluator** | Comparing Qravio vs Scanova/QRCodeChimp | Confirm "can I get a GST invoice?" *before* paying | The answer today is an email address, not a product surface |
| **Unregistered sole proprietor** | No GSTIN, still wants a proper bill | Company name + address on the invoice | Same email workaround, no structured data |

Primary buyer is the **GST-registered Indian SMB on the INR rail**. The unregistered proprietor matters too —
which is why **GSTIN is optional** and the rest of the profile is not.

## 5. User Stories

- As a **registered SMB owner**, I want to save my GSTIN and company details in Billing, so that my invoice
  carries them and I can claim input-tax-credit.
- As a **finance executive**, I want the legal entity name and billing address stored exactly as registered,
  so that the invoice matches our books and passes our CA's check.
- As a **pre-purchase evaluator**, I want to see a GSTIN field *before* I pay, so that I know a tax invoice
  is possible without emailing anyone.
- As **any user**, I want an obviously-wrong GSTIN rejected the moment I type it, so that I don't discover a
  typo three invoices later when my ITC claim is denied.
- As an **unregistered proprietor**, I want to save company name and address **without** a GSTIN, so that I
  still get a properly addressed bill.
- As an **agency owner** paying for several workspaces, I want one billing profile on the workspace that
  actually holds the subscription, so that I don't maintain five copies of the same GSTIN.
- As a **rest-of-world (USD) customer**, I want to be told plainly who issues my invoice, so that I don't
  wait for a GST invoice that will never come.
- As **Qravio finance**, I want the buyer's GSTIN on the Razorpay payment record, so that issuing the manual
  invoice is a lookup, not an email thread.

## 6. UX / Product Flow

**6.1 The billing-details card — billing page**
1. A new **"Billing details"** card renders on `/{slug}/billing`, composed by the page
   (`qr_frontend/src/app/[slug]/(dash)/billing/page.tsx`, currently 29 lines and a pure composition of
   `<BillingPlans />`) — **not** bolted into `BillingPlans.tsx`, which is already 677 lines.
2. **Empty state** (no profile yet): a compact prompt — *"Add your GST and billing details so your invoices
   are issued correctly"* — with an **Add billing details** button. On the INR rail the copy names GST; on
   the USD rail it does not (§6.4).
3. **Filled state**: a read-back of legal name, GSTIN (masked-free — it's a public registration number, shown
   in full), and the address, with an **Edit** action.
4. **Form** (react-hook-form + zod, shadcn primitives only): Legal / company name (required), GSTIN
   (optional, uppercased and space-stripped as you type, validated on blur), Address line 1 (required),
   Address line 2, City, **State** (a select of the 37 Indian states/UTs with their GST state codes), Postal
   code, Country (defaults to India), Billing email (defaults to the owner's account email).
5. **Inline GSTIN feedback**: an invalid checksum or a bad state code shows a specific message
   (*"That GSTIN's check character doesn't match — please re-check"*), not a generic "invalid".

**6.2 Permissions**
- Only a workspace **owner** can view or edit the billing profile — it is billing data, and the existing
  `require_workspace_role(["owner"])` dependency (`qr_backend/src/api/dependencies/deps.py:95`, already used
  by `update_workspace` at `workspace.py:757`) is exactly the boundary. Editors/viewers do not see the card.

**6.3 Owner-scoped billing (inherited plans)**
- Workspaces inherit their owner's plan. `get_current_subscription` already returns `is_inherited` and
  `billing_workspace_id` (`razorpay_routes.py:172-193`) and `CurrentPlanCard` already renders the plan
  read-only in that case.
- The billing-details card follows the same rule: on an **inherited** workspace it shows the billing
  workspace's profile **read-only**, with *"Managed on <workspace> — edit it there."* One billing identity per
  paying owner, no five copies of the same GSTIN, no ambiguity about which one an invoice uses.

**6.4 Rail honesty (INR vs USD)**
- **INR / Razorpay** (Qravio is the seller of record): full GST copy, GSTIN field shown.
- **USD / Lemon Squeezy** (LS is the merchant of record): the GSTIN field is hidden and replaced with a short
  note — *"Your invoice is issued by Lemon Squeezy, our merchant of record, and is emailed to you after each
  payment."* Company name and address are still captured (they're useful regardless).
- The rail is already known client-side via the billing layout's `CurrencyProvider` and
  `currencyForCountry` (`qr_frontend/src/lib/geo.ts`); no new detection.

**6.5 At checkout**
- When a profile exists, `gstin` and legal name ride the Razorpay subscription `notes` at create
  (`razorpay_routes.py:301`) and upgrade (`:618`). If the profile is saved *after* the subscription was
  created, the DB row remains the authoritative record — `notes` are a best-effort convenience mirror, and
  the upgrade path re-attaches them on the next subscription create.
- On the **upgrade** path (`/{slug}/billing/upgrade`), a workspace with no billing details sees a
  non-blocking *"Add GST details for your invoice"* link. **It never blocks checkout** — a blocked checkout to
  collect optional tax data is a self-inflicted conversion wound.

**6.6 Getting the actual invoice (unchanged in v1)**
- The help copy is updated from "email us with your details" to *"add your GSTIN under Billing → Billing
  details, then email `billing@qravio.app` and we'll issue your tax invoice against it."* The workaround
  stays; it gets correct and fast. **The Terms page copy is not touched** — it already promises invoices, and
  v1 must not be read as promising *automated* invoices.

## 7. Scope

**In scope (v1)**
- `workspace_billing_profile` table (1:1 with `workspaces`, mirroring `workspace_branding` from `0011`).
- `GET` + `PUT /api/v1/workspaces/{workspace_id}/billing-profile`, owner-only, mirroring `branding.py`.
- Server-side GSTIN validation: layout regex, state-code set, PAN sub-pattern, literal `Z`, **mod-36 check
  character**. Normalization to uppercase + whitespace-stripped. Empty/absent is valid (unregistered buyers).
- Billing-details card + form on the billing page; `useBillingProfile` / `useUpdateBillingProfile` hook pair.
- Inherited-workspace read-only behavior; owner-only visibility; INR-vs-USD rail copy.
- GSTIN + legal name into the Razorpay subscription `notes` on create and upgrade.
- Help-center copy update (`HelpContent.tsx`).
- **Ungated, all plans.** No plan flag, no gating, no coverage-test surface.

**Out of scope / Future (the deferred second half — its own PRD)**
- Invoice **generation** (PDF/HTML), invoice **numbering** (sequential, gap-free, per-financial-year series),
  invoice **history** UI, invoice **email** delivery.
- **Place-of-supply engine**: CGST+SGST vs IGST derived from seller state ↔ buyer place of supply.
- **GSTR-1 / GSTR-3B** exports and reconciliation; **e-invoice / IRP / IRN**; **credit notes** on refund or
  downgrade; **reverse charge**; **OIDAR**.
- **HSN/SAC** codes and per-line tax breakdown.
- **GSTIN verification against the GSTN API** (live legal-name lookup / active-status check) — v1 validates
  the *format and checksum* only, which catches typos but not a well-formed GSTIN belonging to someone else.
- **Ex-GST B2B pricing display** — a pricing decision, not this feature.
- **Non-India tax IDs** (VAT/ABN/EIN) — the schema leaves room (`tax_id_type`), v1 populates only `gstin`.
- **GST e-invoice QR** — a documented, permanent skip.

## 8. Pricing & Packaging

| Surface | Tier | Flag / Limit |
|---|---|---|
| Billing details + GSTIN capture | **All plans (Free, Starter, Pro, Agency)** | **None** (ungated) |
| Actual tax invoice issuance | All paying INR customers (manual, via `billing@`) | **None** |

**Why ungated — and why it isn't even a close call.** This is not a feature; it is a prerequisite for taking
money from a GST-registered buyer. Gating it would mean "pay us first, then tell us who to invoice," which
inverts the actual purchase sequence: the finance-side question ("can I get a GST invoice?") is asked
*before* the card is entered. A Free workspace evaluating an upgrade must be able to fill this in, and the
first invoice must be right the first time.

It is also the cheapest possible packaging decision: **no `plans.features` key, no `FEATURE_ENFORCEMENT`
entry, no `test_feature_gate_coverage` surface, no per-tier seed UPDATEs.** The migration is a single
`CREATE TABLE`. Every gating question that normally consumes half a billing spec simply does not arise here.

**Confirmed against the billing code:** `get_current_subscription` (`razorpay_routes.py:708-782`) synthesises
a `free-tier` response for workspaces with no subscription, so a Free workspace has a perfectly usable
billing page today — there is no plan boundary to hang a gate on, and inventing one would be pure cost.

## 9. Success Metrics & KPIs

**Conversion (the point of the feature)**
- **GSTIN-on-file rate**: ≥ 35% of *paying INR* workspaces have a validated GSTIN within 90 days of GA. This
  is also the evidence base for whether the deferred invoice engine is worth building — below ~20%, it isn't.
- **Pre-purchase capture**: ≥ 15% of INR workspaces that upgrade have saved billing details *before*
  checkout (proves the field is discoverable at the moment the question is asked).
- Sales/support signal: "can I get a GST invoice?" stops being a pre-purchase blocker — tracked as
  conversations where the answer changes from "email us after" to "yes, add it in Billing."

**Correctness (the bar that matters)**
- **Zero invalid GSTINs stored.** Every persisted GSTIN passes layout + state-code + PAN + checksum. Verified
  by an automated checksum test with known-good and one-character-mutated vectors, plus a periodic
  `SELECT` sweep over the table.
- **Zero cross-workspace profile leaks**: a non-owner or a member of another workspace never reads a profile
  (owner-only + explicit `workspace_id` filter; the service-role client bypasses RLS).
- **Zero GST promises on the USD rail**: no Lemon Squeezy customer is shown a GSTIN field or told to expect a
  Qravio-issued GST invoice.

**Operational**
- **Time-to-invoice** on the `billing@` workaround drops from *days* (email round-trip to collect details) to
  *same-day* (details already on file and on the Razorpay payment record).
- Invoice-detail **correction rate** (invoices reissued because the legal name/GSTIN was wrong) → ~0, since
  the buyer types their own details into a validated field instead of finance retyping them from an email.

## 10. Rollout Plan

**Phase 0 — Schema + endpoint (internal).**
Migration `0039` (one table). Build the GSTIN validator (layout + state code + PAN + checksum) and the
owner-only GET/PUT pair mirroring `branding.py`. Unit-test the validator against known-good and mutated
GSTINs. No UI. Verify a non-owner gets 403 and a cross-workspace read is impossible.

**Phase 1 — Billing-details card (closed, then open).**
Add the card + form to the billing page, the `useBillingProfile` hook pair, the inherited-workspace
read-only state, and the INR/USD rail copy. Wire `gstin` + legal name into the Razorpay `notes` on create
and upgrade. Update `HelpContent.tsx`.
- **Acceptance:** an owner saves a valid GSTIN → it persists and reads back; a checksum-mutated GSTIN is
  rejected with a specific message; a profile saved with **no** GSTIN succeeds; an editor sees no card; an
  inherited workspace shows the billing workspace's profile read-only; a USD-rail user sees the Lemon Squeezy
  note and **no** GSTIN field; a new Razorpay subscription created afterwards carries `gstin` in its `notes`;
  checkout is never blocked by a missing profile.

**Phase 2 — GA + the honest handoff.**
Open to all workspaces. Finance's manual invoice process now reads from the profile (or from the Razorpay
payment `notes`). **Watch the GSTIN-on-file rate for 90 days** — that number is the gate on whether the
deferred invoice engine gets built at all.

**Phase 3 (DEFERRED — separate PRD, explicitly not this one).**
Invoice generation: per-financial-year sequential numbering, CGST/SGST-vs-IGST place-of-supply computation,
PDF rendering, invoice history, email delivery, credit notes on refund/downgrade. **Trigger:** GST-registered
workspaces are a material revenue segment (per the Phase-2 measurement). **Blockers to clear first:** a
decided invoice-number series and its registered issuer state; a legal review of the tax split; and — for
emailed invoices — the unpublished `_dmarc.qravio.app` record.

**Cross-service gates (all clear for v1):**
- **No Worker change** → `npm run deploy:prod` is **not** required.
- **No email** in v1 → the unpublished `_dmarc.qravio.app` record is **not** a gate.
- **No cron**, no new external service, no new secret, no new env var.
- Deploy order: apply migration `0039` → backend → frontend.

## 11. Risks, Edge Cases & Open Questions

**R1 — The Terms already promise more than v1 delivers (the #1 non-technical risk).**
`terms/page.tsx:127-131` states *"Invoices will reflect the GST component"* and `HelpContent.tsx:130-131`
says prices are GST-inclusive. v1 ships a *field*, not an invoice. **Mitigation:** do **not** touch the Terms
copy (the promise is already there and is honoured by the manual process); update only the help copy to point
at the new field while keeping `billing@qravio.app` as the delivery path. Nothing in v1's UI may imply an
automatic invoice. Any copy that says "your invoice will be generated" is a bug.

**R2 — A well-formed GSTIN can still be the wrong one.** The checksum catches typos; it cannot tell us the
GSTIN belongs to the buyer or is currently active. **Mitigation:** accept this in v1 — the buyer self-declares
their own tax number, exactly as they do in the email workaround today, and the liability sits with the
declarant. GSTN-API verification is deferred (§7). Do **not** display any "verified" badge.

**R3 — Prices are GST-inclusive, so the eventual invoice must *back out* the tax, not add it.**
₹X displayed already contains the tax; the invoice line is `X × 100/118` + `X × 18/118`, not `X + 18%`.
**Mitigation:** v1 computes nothing, which is precisely why it is safe. This is recorded here so the deferred
phase does not silently ship a "+18% GST" line and overcharge, and so nobody adds an ex-GST display to the
checkout as a "small" follow-on.

**R4 — Rail asymmetry is a compliance trap, not a UI detail.** Lemon Squeezy is the merchant of record for
USD (`integrations/mor/base.py:4`); showing a GSTIN field to an LS customer promises an invoice Qravio cannot
legally issue. **Mitigation:** the GSTIN field is conditioned on the INR rail, and the USD state says who the
actual issuer is. Covered by a frontend test.

**R5 — Owner-scoped billing could produce five conflicting GSTINs.** An owner holds up to 5 workspaces
(migration `0030`) that inherit one subscription. A per-workspace profile invites five different GSTINs for
one paying entity. **Mitigation:** the profile that counts is the one on `billing_workspace_id`; inherited
workspaces render it **read-only** and point at the billing workspace. See Open Q1 for the
workspace-keyed-vs-owner-keyed decision.

**R6 — Place of supply is the part that gets people fined.** Intra-state (CGST+SGST) vs inter-state (IGST)
depends on the seller's registered state and the buyer's place of supply; the GSTIN's first two digits and
the typed address state can disagree. **Mitigation:** v1 **stores both and computes nothing**, so a mismatch
is at worst stale data, never a wrong tax split. Recommend warning (not blocking) on mismatch — see Open Q2.

**R7 — PII / DPDP.** Company name, address, and email are business-identifying and, for a sole proprietorship,
arguably personal. **Mitigation:** the profile never enters KV, never reaches the Worker, is never logged in
full (log presence, not value), and cascades on workspace deletion via the FK. *(Note the separately-tracked
broken account-deletion cascade — this table must be added to that fix, not worked around here.)* Statutory
6-year record retention attaches to *issued invoices*, not to a profile that has produced none, so v1 creates
no retention-vs-deletion conflict; the deferred phase must resolve it.

**R8 — GSTIN is optional, and the empty case must not be second-class.** Unregistered proprietors are a
large share of Indian SMBs. **Mitigation:** GSTIN nullable; company name + address alone is a complete, valid
profile; no nag, no "incomplete" badge.

**R9 — `notes` on the Razorpay subscription are best-effort, not a record of truth.** They are written at
subscription-create; a profile saved afterwards won't retroactively appear on the existing subscription.
**Mitigation:** the DB row is authoritative and finance reads it there; `notes` are a convenience that makes
the common case (details entered before upgrading) a zero-lookup. Razorpay `notes` also cap at 15 keys /
256-char values — we add 2 to the existing 3, comfortably inside.

**Open Questions**
1. **Key the profile on `workspace_id` or on the owning `user_id`?** *Recommend `workspace_id`* — it mirrors
   `workspace_branding` exactly, matches the workspace-scoped billing page and the `subscriptions.workspace_id`
   column, and reuses `require_workspace_role(["owner"])` verbatim. The owner-identity concern (R5) is fully
   handled by resolving through `billing_workspace_id` for inherited workspaces. An owner-keyed table would be
   more "correct" as a tax identity but would need a new permission path and a new resolver for zero user-visible
   gain in v1. TRD decision.
2. **On a GSTIN-state ↔ address-state mismatch: warn or block?** *Recommend warn.* Blocking punishes the
   legitimate case (registered in Maharashtra, billing address in Karnataka) and v1 computes no tax, so a
   mismatch is harmless. Treat the GSTIN's state code as canonical when both are present.
3. **Should the upgrade flow prompt for billing details before checkout?** *Recommend a non-blocking inline
   link only.* A required step ahead of payment costs conversions to collect data that is optional for most
   buyers. Revisit only if the pre-purchase capture rate (§9) is near zero.
4. **Capture company name + address on the USD rail too, or hide the whole card?** *Recommend capture* — the
   fields are useful for our own records and for a future non-India tax-ID field; only the GSTIN input and the
   GST copy are India-conditional.
5. **One legal-name field or separate "legal name" and "trade name"?** *Recommend one* ("Legal / company name,
   as registered"). GST invoices use the registered legal name; a second field is a v2 nicety.

## 12. Dependencies

- **Billing lifecycle (shipped):** `qr_backend/src/api/routes/razorpay_routes.py` — `subscriptions` table,
  `create_razorpay_subscription` (`:247`, `notes` at `:301`), `upgrade_subscription` (`:504`, `notes` at
  `:618`), `get_current_subscription` (`:708`) with `is_inherited`/`billing_workspace_id` (`:172-193`).
- **Owner-scoped plan resolution (shipped):** `resolve_plan` / `_owner_of_workspace` /
  `_best_active_subscription_for_owner` in `qr_backend/src/api/routes/subscription.py` (`:283`, `:237`, `:248`)
  — the source of `billing_workspace_id` for the inherited case.
- **Per-workspace settings-resource pattern (shipped — copy it):** `workspace_branding` table (migration
  `0011`), `branding.py` GET `:107` / PUT `:117`, `qr_frontend/src/hooks/useBranding.ts`. Same shape, one
  table over.
- **Permissions (shipped):** `require_workspace_role(["owner"])`
  (`qr_backend/src/api/dependencies/deps.py:95`), already used by `update_workspace` (`workspace.py:757`).
- **Rail detection (shipped):** `currencyForCountry` / `resolveInitialCurrency`
  (`qr_frontend/src/lib/geo.ts`) + the billing-scoped `CurrencyProvider`
  (`qr_frontend/src/app/[slug]/(dash)/billing/layout.tsx`).
- **Migration mechanism (shipped):** hand-applied SQL in `qr_backend/migrations/`; provisional slot **`0039`**
  (highest on disk = `0032`; `0033` is reserved by QR Expiry; `0034`–`0038` are provisionally claimed by the
  concurrent spec batch — **re-verify against `ls qr_backend/migrations/` at build time**).
- **No AI, no Worker, no KV, no cron, no email, no new external service, no new env var or secret.**

### Appendix — Key Files

| Concern | File |
|---|---|
| Billing-profile table | `qr_backend/migrations/0039_gst_billing_profile.sql` (NEW — `workspace_billing_profile`, mirrors `0011_white_label_branding.sql`) |
| Billing-profile endpoints | `qr_backend/src/api/routes/billing_profile.py` (NEW — GET/PUT, owner-only; mirrors `branding.py:107/117`), registered in `src/api/endpoints.py` |
| GSTIN validation | `qr_backend/src/utilities/gstin.py` (NEW — layout + state code + PAN + mod-36 check character) |
| Razorpay `notes` pass-through | `qr_backend/src/api/routes/razorpay_routes.py` (`notes` dict at `:301` create, `:618` upgrade) |
| Owner-scoped resolution | `qr_backend/src/api/routes/subscription.py` (`resolve_plan` `:283`), `razorpay_routes.py` (`is_inherited`/`billing_workspace_id` `:172-193`, `:708`) |
| Permission boundary | `qr_backend/src/api/dependencies/deps.py` (`require_workspace_role` `:95`) |
| Billing-details UI | `qr_frontend/src/components/org/billing/billing-details-card.tsx` + `billing-details-form.tsx` (NEW, ≤200 lines each), composed by `qr_frontend/src/app/[slug]/(dash)/billing/page.tsx` |
| Hook | `qr_frontend/src/hooks/useBillingProfile.ts` (NEW — mirrors `useBranding.ts`) |
| GSTIN + state constants (FE) | `qr_frontend/src/lib/gstin.ts` + `qr_frontend/src/lib/constants/gst-states.ts` (NEW) |
| Rail detection | `qr_frontend/src/lib/geo.ts` (`currencyForCountry`), `billing/layout.tsx` (`CurrencyProvider`) |
| Copy to update | `qr_frontend/src/components/marketing/HelpContent.tsx:130-131` (help answer only — **do not** touch `app/(marketing)/terms/page.tsx:127-131`) |
| Worker | **No change** (no KV, no type, no template, no cron) |
