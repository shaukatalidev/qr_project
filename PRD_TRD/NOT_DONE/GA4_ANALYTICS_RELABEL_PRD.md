# PRD — GA4 Analytics: First-Class Relabel of the Google Tag Slot

**Status:** Draft · **Author:** Product · **Date:** 2026-07-25
**Priority:** Quick win / completeness fix (gap-analysis #8: S effort, Fit 2, Impact 2). The capability **already ships** — a workspace can paste a `G-XXXXXXXXXX` GA4 Measurement ID into the "Google" retargeting-pixel slot today and `gtag.js` fires on every worker-rendered landing page. The only gap is that we **call it an Ads-retargeting pixel**, so no buyer, no comparison table, and no support article knows GA4 works. This is a labelling and documentation fix, not new capability — say so plainly and do not gold-plate it.
**Tiers:** **Pro + Agency**, unchanged — the existing `retargeting_pixels` flag (seeded `false` by `0009`, flipped on for Pro/Agency by `0013`). **No tier change, no new flag, no re-gating in v1.** Whether GA4-only should drop to Starter is a pricing question, not a labelling one (§8 / Open Q1).
**Plan flags:** **None (NEW).** The gate stays `retargeting_pixels`. The flag **key** is deliberately *not* renamed — renaming a `plans.features` key means a migration, a `FEATURE_ENFORCEMENT` rewrite, and `test_feature_gate_coverage` churn for a cosmetic gain. Only human-facing labels change.
**Split from:** `RETARGETING_PIXELS_PRD.md` (shipped, `PRD_TRD/DONE/`, migration `0013`) and the per-QR selection layer (`0031_per_qr_retargeting.sql`). Reuses every existing seam — the `retargeting_pixels` table, `build_pixels()`, the KV `pixels` array, `renderPixels()`/`googleSnippet()` at the edge, and the EU consent gate. **Not** a new provider, **not** a new data model, **not** a new edge path.

**Rev (2026-07-25, post eng-review):** Reviewed via `/plan-eng-review`; ships **as-drafted** — a copy/relabel with zero schema and zero scan-path behaviour change. Confirmed there is **no migration** (an earlier slot-`0037` flag was a false positive: `0037` appears only as a contingency for a *future* per-pixel-label column, not this feature). Decision: **keep GA4 at Pro+** on the existing `retargeting_pixels` flag — splitting GA4 to Starter would need a new flag + migration + gate + `build_pixels()` prefix-filtering, i.e. no longer a quick win; revisit only on lost-deal evidence. Other open questions accepted per the PRD's recommendations (rename the tab too; three picker options; keep `UA-` accepted-but-labelled-retired; article-only, no SEO page in v1). **Hard invariant:** the consent gate at `index.js:428` is **not** touched (R1) — the single most important line of this relabel; the Worker comment records *why* analytics tags sit behind the marketing gate. **Action for the legal-copy owner (R6):** confirm the cookies-page "we don't use Google Analytics" statement (about Qravio's own site) is distinguishable from a tenant's GA4 tag on a tenant scan page; add a one-line clarifier if needed.

---

## 1. TL;DR / Summary

Qravio already supports Google Analytics 4. A Pro/Agency workspace pastes a GA4 Measurement ID
(`G-XXXXXXXXXX`) into Settings → Pixels, picks "Google", and the Cloudflare Worker injects the standard
`gtag.js` loader + `gtag('config', …)` into every landing page it renders. Verified in code: the backend
validator `_GOOGLE_RE` (`qr_backend/src/api/routes/pixels.py:33`) accepts `(AW|G|GT|UA)-…`, the edge
re-check `PIXEL_RE.google` (`qr_cf_code/src/utils/pixels.js:24`) matches it, and `googleSnippet()`
(`pixels.js:66–74`) emits `https://www.googletagmanager.com/gtag/js?id=<ID>`. There is an existing test
asserting a `G-ABCDEF1234` ID renders (`qr_cf_code/src/utils/pixels.test.mjs:68`).

**The entire feature is: stop calling it an ad pixel.** Rename the surfaces from "Retargeting pixels" to
"Tracking & analytics tags", split the single **Google** dropdown option into three ID-prefix-derived
labels (**Google Analytics 4** `G-`/`GT-`, **Google Ads** `AW-`, **Universal Analytics — retired**
`UA-`), fix the validator error copy (`pixels.py:80`) and the format hint
(`PixelsSection.tsx:16–19`) to name GA4 explicitly, add the row to the pricing comparison matrix,
and write the help-centre article. Plus one Worker header-comment tweak and two pinning tests.

**Zero schema change. Zero behaviour change on the scan path. No migration.** The `provider` column stays
`'google'`; the sub-label is *derived* client-side from the ID prefix. Nothing in KV changes, so no
`resync_workspace_qrs` sweep and no `npm run deploy:prod` is required for correctness.

**Deliberately excluded: the GTM container path.** See §3 Non-Goals — and note it is already blocked by
both regexes today (`GTM-ABC123` fails `^(AW|G|GT|UA)-…`, verified). We are keeping it blocked on purpose.

## 2. Problem & Motivation

**We ship a feature nobody knows we ship.** "Does it support Google Analytics?" is a standard SMB and
agency qualification question. Today the honest answer is "yes, paste your `G-` ID into the retargeting
pixel slot" — but nothing in the product, the pricing page, or the docs says that. The Settings tab is
labelled **Pixels**, the section header reads **"Retargeting pixels"**, the upgrade card says *"Fire Meta
and Google pixels on your QR landing pages to build retargeting audiences"*
(`PixelsSection.tsx:41–45`), and the builder accordion is titled **"Retargeting pixels"**
(`QRDesign.tsx` ~L668). Every one of those signals says *advertising*, not *measurement*.

**Three concrete losses:**
1. **Sales/comparison.** Competitors list "Google Analytics integration" as a discrete row. Our comparison
   table (`PricingComparisonTable.tsx:49`) has one row — "Retargeting Pixels" — so a buyer scanning for
   GA4 finds nothing and assumes ✗.
2. **Self-serve discovery.** A Pro user who wants scan-page analytics in *their own* GA4 property has no
   reason to open a tab called "Pixels". They either ask support or conclude we don't do it.
3. **Miscategorised copy causes wrong expectations.** A user told this is a "retargeting pixel" reasonably
   expects it to work on their **Website-redirect** QRs (it can't — `build_pixels()` returns `[]` for
   `qr_type == "website"`, `cloudflare_kv.py:219–220`, because a 302 renders no HTML of ours). The current
   framing makes that limitation read like a bug rather than a physical constraint.

**It is close to free.** The extraction target, the validator, the edge snippet, the consent gate, the
per-QR selector, and the KV snapshot all exist and all work. The delta is strings, one comparison-table
row, one docs page, and two tests. There is no honest way to describe this as new capability, and the PRD
should not pretend otherwise: **it is a completeness/clarity fix that converts an already-built capability
into a claimable one.**

## 3. Goals & Non-Goals

**Goals**
- **Name the capability.** Relabel the Settings tab, section headers, the builder accordion, and the
  upgrade/empty states from "Retargeting pixels" to **"Tracking & analytics tags"** (or equivalent) so
  both use cases — measurement *and* advertising — are visible.
- **Split the Google option by ID prefix.** One stored provider (`'google'`), three derived display
  labels: `G-`/`GT-` → **Google Analytics 4**, `AW-` → **Google Ads**, `UA-` → **Universal Analytics
  (retired)**. Purely presentational; derived client-side, not stored.
- **Fix the validator copy.** The 400 from `_clean_pixel` (`pixels.py:80`) and the FE format hint
  (`PixelsSection.tsx:16–19`) must name a GA4 Measurement ID with a real-shaped example, and must say
  in one line why a `GTM-` container is rejected.
- **State the limits honestly, in-product.** Tags fire only on worker-rendered landing pages (never on
  Website-redirect QRs), and EU/EEA/UK scanners must accept the consent strip first. The Settings info box
  already says both (`PixelsSection.tsx:79–82`) — extend it to name GA4 and GTM.
- **Make it claimable.** Add a "Google Analytics 4 (GA4)" row to the pricing comparison matrix and publish
  one help-centre article ("Send QR scan-page traffic to your GA4 property").
- **Pin the current behaviour with tests** so the relabel can never quietly become a behaviour change.

**Non-Goals**
- **No GTM container support — hard skip, permanently in scope-out.** Accepting a `GTM-XXXXXXX` container
  means a tenant can load and hot-swap **arbitrary remote JavaScript** on a page *we* host, under *our*
  domain, for *our* scanners. That is a stored-XSS / malvertising primitive and a DPDP + ePrivacy
  consent-mode liability we would own but not control (a container's contents change after we validate the
  ID; there is nothing to validate). Our SMB core does not use GTM. Both regexes reject `GTM-` today —
  **verified**, since `GTM-…` matches neither `G-` nor `GT-` — and this PRD makes that rejection
  *intentional and tested* rather than incidental. Not a "future"; a decision.
- **No consent-gate change.** GA4 sets `_ga`/`_ga_*` first-party cookies, so it remains a tracking tag
  under ePrivacy Art. 5(3). It stays behind `marketingConsentGranted()` exactly as today. Relabelling
  something "analytics" must **not** become a reason to exempt it. No Google Consent Mode v2 signal
  plumbing in v1 (future, separate spec).
- **No schema/provider change.** `provider` stays `'meta' | 'google'`. We do **not** add a `'ga4'`
  provider value, a per-pixel `label` column, or a `purpose` enum — each would need a migration and a
  backfill for zero user-visible gain over prefix derivation.
- **No flag rename, no re-gating.** `retargeting_pixels` stays the key and stays Pro+. (Moving GA4 to
  Starter is a separate pricing decision — Open Q1.)
- **No GA4 server-side Measurement Protocol.** That would let us report *redirect* scans (the `website`
  type) into a tenant's GA4 property from the backend — genuinely new capability, real cost, real
  PII/consent surface. Explicitly future (§7).
- **No custom event mapping** (`scan`, `vcard_download`, `link_click` → GA4 events). v1 fires the standard
  `page_view` that `gtag('config')` already sends. Future.
- **No new providers** (LinkedIn, TikTok, Pinterest, Snap, Clarity). Out of scope.
- **No auto-provisioning / OAuth into a user's GA4 account.** They paste an ID; that is the whole flow.

## 4. Target Users & Personas

| Persona | Who | Job-to-be-done | Today's pain |
|---|---|---|---|
| **Marketing Manager ("Divya")** | Runs an SMB's web + campaign analytics in GA4 | See QR landing-page traffic in the same GA4 property as the website | Assumes Qravio has no GA4; exports CSVs or gives up |
| **Agency Analyst ("Kabir")** | Reports to clients out of the client's GA4 | Attribute scan-driven sessions inside the client's existing dashboards | Doesn't open a tab called "Pixels"; asks support or churns to a rival that lists GA4 |
| **Evaluating buyer ("Priya")** | Comparing 3 QR vendors on a spreadsheet | Tick the "Google Analytics" row | Our comparison matrix has no GA4 row → scores us ✗ on a feature we have |
| **Support / CS** | Fields "do you support GA4?" | Point at a doc | No doc exists; answers from tribal knowledge, inconsistently |
| **Existing Pro user with an `AW-` pixel** | Already using Google Ads remarketing | Keep working, unchanged | None — must stay a strict no-op for them |

Primary beneficiary is the **Pro/Agency marketer** who already pays and simply cannot find the feature.
Secondary is **sales/SEO**, which gains a claimable comparison row.

## 5. User Stories

- As a **marketing manager**, I want to paste my GA4 Measurement ID and see QR landing-page sessions in my
  own GA4 property, so that scan traffic sits beside my website traffic.
- As a **marketing manager**, I want the field to *tell me* it accepts a GA4 Measurement ID, so that I
  don't have to guess whether a "retargeting pixel" slot will take a `G-` ID.
- As an **agency analyst**, I want the feature named "analytics", so that I find it while looking for
  analytics rather than while looking for ads.
- As an **evaluating buyer**, I want "Google Analytics 4" as its own row in the pricing comparison, so
  that my vendor spreadsheet reflects what the product actually does.
- As **any user**, I want to be told plainly — before I configure anything — that tags fire on landing-page
  QR types but **not** on Website-redirect QRs, so that I don't file a "GA4 shows no data" ticket.
- As a **user pasting a GTM container ID**, I want a clear, specific error explaining that container
  snippets aren't supported and that I should paste the GA4 Measurement ID from inside the container,
  so that I know the fix rather than thinking the field is broken.
- As an **existing Google Ads user**, I want my `AW-` pixel to keep firing untouched and to still be
  labelled "Google Ads", so that a relabel never quietly re-scopes what I set up.
- As an **EU scanner**, I want analytics tags to stay behind the consent strip, so that "it's only
  analytics" never becomes an excuse to drop cookies on me without a choice.

## 6. UX / Product Flow

**6.1 Settings → renamed tab and section**
- Sidebar tab `Pixels` → **"Tracking & Analytics"** (`settings/page.tsx:46`; the `Section` union at L25 and
  the `showPixels` entitlement check at L41 are untouched — same `retargeting_pixels` gate).
- Section header "Retargeting pixels" → **"Tracking & analytics tags"**; sub-line "Track visitors on your QR
  landing pages" → **"Send scan-page traffic to Google Analytics 4, or fire Meta / Google Ads tags"**
  (`PixelsSection.tsx:70–72`).
- The non-entitled upgrade card (`PixelsSection.tsx:41–45`) drops "to build retargeting audiences" for
  copy naming both jobs: measurement (GA4) *and* remarketing (Meta / Google Ads). Still Pro+; still one
  `Upgrade to Pro` CTA.

**6.2 Adding a tag — the provider picker and hint**
- The provider `Select` (`PixelsSection.tsx:89–97`) keeps **two stored values** but reads as three choices:
  `Meta Pixel`, `Google Analytics 4`, `Google Ads`. GA4 and Ads both submit `provider: 'google'`; the
  choice only swaps the **placeholder + hint** (`FORMAT_HINTS`, L16–19):
  - *Google Analytics 4* → `G-XXXXXXXXXX — your GA4 Measurement ID (Admin → Data Streams)`
  - *Google Ads* → `AW-XXXXXXXXX — your Google Ads conversion/tag ID`
  - *Meta* → unchanged: `15–16 digits, e.g. 123456789012345`
- Because the stored value is identical, **switching the picker never changes what gets saved** — it is a
  copy affordance only. This is the entire reason no migration is needed.

**6.3 The configured-tag list — derived labels**
- `PixelRow` currently renders a two-key `PROVIDER_LABEL` map (`PixelRow.tsx:7–10`). It gains a small pure
  helper that derives the label from `provider` + the ID prefix:

  | Stored | ID prefix | Displayed |
  |---|---|---|
  | `meta` | — | **Meta Pixel** |
  | `google` | `G-`, `GT-` | **Google Analytics 4** |
  | `google` | `AW-` | **Google Ads** |
  | `google` | `UA-` | **Universal Analytics** + a muted "retired by Google" note |

- The same helper is reused by the builder's `PixelSelector` checklist
  (`pixel-selector.tsx:35–38`, `126–141`) so a user ticking specific tags per QR sees the same names.
- `UA-` keeps working (we do not break stored rows) but is never *offered* for new entries; the row simply
  carries a "no longer collects data — Google retired Universal Analytics" hint. Honest, not a blocker.

**6.4 The builder accordion**
- Step-5 accordion title "Retargeting pixels" → **"Tracking & analytics tags"** (`QRDesign.tsx` ~L668);
  the collapsed summary ("All workspace pixels" / "N selected" / "None", ~L670–675) is unchanged.
- The per-QR mode control (`off` / `inherit` / `select`) and its defaults are untouched — new QRs still
  default to `off` (opt-in), exactly as `0031` established.
- The non-entitled hint inside `PixelSelector` (L72–78) is reworded to name GA4 alongside Meta.

**6.5 The honesty box (extended, not new)**
The Settings info box (`PixelsSection.tsx:76–83`) already lists the two real constraints. It gains a
third and a fourth line:
- Tags fire on QR pages this app renders as HTML (vCard, PDF, Business, Lead Capture, …). *(existing)*
- They do **not** fire on Website-redirect QRs — those 302 straight to your URL. *(existing)*
- EU/EEA/UK visitors must accept the cookie banner before tags fire. *(existing)*
- **GA4:** paste your **Measurement ID** (`G-…`), not a Google Tag Manager container (`GTM-…`) —
  container snippets aren't supported. *(new)*
- **What you'll see in GA4:** a standard `page_view` per consented scan-page view. Custom scan events
  aren't sent yet. *(new — sets the right expectation up front)*

**6.6 Error path — pasting a GTM container**
`GTM-XXXXXXX` is rejected today with a generic message. It becomes specific:
> "That looks like a Google Tag Manager container ID. Paste your GA4 **Measurement ID** instead — find it
> in GA4 under Admin → Data Streams (it starts with `G-`). GTM containers aren't supported."

**6.7 Marketing / comparison surfaces**
- `PricingComparisonTable.tsx:49` gains a **"Google Analytics 4 (GA4)"** row beside the existing
  "Retargeting Pixels" row — both driven by the same `p.features.retargeting_pixels` boolean, since they
  are the same entitlement. `PricingCards.tsx:306` gets the matching `BoolRow`.
- One help-centre article. No new marketing page in v1 (an SEO page is a later, optional add).

**6.8 What the scanner experiences: nothing new**
Byte-for-byte identical. Same `gtag.js` snippet, same consent gate, same injection point
(`index.js:422–431`). A scan cannot tell this feature shipped — which is the point.

## 7. Scope

**In scope (v1)**
- Copy changes across Settings (tab, header, sub-line, upgrade card, info box, format hints), the builder
  accordion + `PixelSelector`, and the two error messages (backend 400 + FE hint).
- Prefix-derived display labels (GA4 / Google Ads / Universal Analytics) in `PixelRow` and
  `PixelSelector`, via one shared pure helper. No stored-value change.
- Pricing comparison matrix row + pricing-card row for GA4.
- One help-centre / docs article, including the Website-redirect and consent limitations.
- Worker header-comment tweak in `pixels.js` documenting that `google` covers GA4 measurement IDs and
  that GTM containers are deliberately unsupported. **Comment only — no logic touched.**
- Two pinning tests: `GTM-…` is rejected by the backend validator, and `G-…` renders a `gtag.js` snippet
  at the edge (extends the existing coverage at `pixels.test.mjs:68`).

**Out of scope / Future**
- **GTM container support** — *never* (§3; security + compliance decision, not a backlog item).
- **GA4 server-side Measurement Protocol** for `website`-type redirect scans *(future; real capability,
  real cost, new consent surface — needs its own PRD)*.
- **Custom GA4 events** (`qr_scan`, `vcard_download`, `link_click`) beyond the default `page_view`
  *(future; would touch `vcardDownload.js` / `linkClick.js`)*.
- **Google Consent Mode v2** signal plumbing *(future; our gate today is binary allow/deny)*.
- **Moving GA4 below Pro** — a pricing decision, deliberately deferred (Open Q1).
- **New providers** (LinkedIn, TikTok, Clarity, Pinterest) *(future, unrelated)*.
- **A dedicated `/google-analytics-qr-code` SEO page** *(optional follow-up; not a gate)*.
- **Per-pixel `label`/`nickname` column** *(future; only if users ask to name tags — would need a
  migration, provisional slot `0037`)*.

## 8. Pricing & Packaging

| Surface | Tier | Flag / Limit |
|---|---|---|
| GA4 Measurement ID on scan landing pages | **Pro, Agency** (unchanged) | `retargeting_pixels` (existing) |
| Meta / Google Ads pixels | **Pro, Agency** (unchanged) | `retargeting_pixels` (existing) |
| Comparison-matrix row "Google Analytics 4 (GA4)" | — | reads the same boolean |

**No packaging change in v1, and that is the recommendation.** The capability is already sold at Pro+; the
relabel does not add cost, quota, or a new surface, so there is nothing to re-price. Adding a flag would
force a migration, a `FEATURE_ENFORCEMENT` entry, and coverage-test surface for a rename — the exact
over-build this quick win should avoid.

**The one live question (Open Q1): should GA4-only drop to Starter?** The argument for: GA4 is
*measurement*, table-stakes for anyone running campaigns, and a Starter-tier marketer expecting it may
bounce; the argument against: it shares one flag with Meta/Ads remarketing (which is a genuine Pro-tier
capability), splitting them needs a **new** flag + migration + gate — i.e. it stops being a quick win —
and Pro+ pixels are already sold and priced. **Recommendation: keep Pro+ in v1.** Revisit only if
Starter-tier GA4 demand shows up in lost-deal notes. Note that if we ever split them, the split is a
*flag* change, not a data change: `build_pixels()` would filter by prefix, and stored rows stay valid.

**Revenue thesis:** the win here is not upsell, it's **claimability** — a ✓ in a comparison row we
currently score ✗ on, and one fewer "does it do GA4?" pre-sales round-trip.

## 9. Success Metrics & KPIs

**Discoverability (the actual goal)**
- **≥ 2× increase in `google`-provider pixel rows created per month** among Pro/Agency workspaces within
  60 days of GA (baseline: current `retargeting_pixels` rows where `provider='google'` and `pixel_id`
  starts `G-`/`GT-`). This is the single metric that says the relabel worked.
- **GA4 row flips ✗ → ✓** in the comparison matrix and in the sales battlecard. Binary, immediate.
- Help-centre article published and linked from the Settings info box.

**Correctness (the bar that matters for a relabel)**
- **Zero behaviour change, proven, not assumed.** No KV value differs before/after; no snippet output
  differs; `resync_workspace_qrs` is never invoked by this change; the `pixels.test.mjs` suite passes
  unmodified except for the added GTM/GA4 pinning tests.
- **Zero regressions for existing `AW-` users.** An `AW-` row still labels as "Google Ads" and still fires
  identically. Verified by fixture test, not by inspection.
- **`GTM-` stays rejected** at both the backend validator and the edge re-check — now with an explicit
  test, so a future "let's be more permissive" refactor trips CI.

**Support**
- "Does Qravio support Google Analytics?" tickets/pre-sales questions trend to ~zero, deflected by the
  article and the in-product copy.
- **No new** "my GA4 shows no data" tickets from Website-redirect QR owners — the limitation is now stated
  before configuration, not discovered after.

## 10. Rollout Plan

**Phase 0 — Copy, labels, tests (single PR).**
All FE copy + the derived-label helper + the backend error-message change + the two pinning tests + the
Worker comment. Nothing is behind a flag because nothing behaves differently — a copy change does not need
a beta. Reviewed as one diff so the "no behaviour change" claim is verifiable in one read.
- **Acceptance:** an existing workspace's configured tags render with the new derived labels and fire
  unchanged; a `G-` ID entered under the new "Google Analytics 4" picker option is stored as
  `provider='google'` exactly as before; a `GTM-` ID returns the new specific 400; the KV payload for an
  untouched QR is byte-identical.

**Phase 1 — Docs + comparison surfaces.**
Help-centre article, `PricingComparisonTable` / `PricingCards` rows, sales battlecard line, and the
gap-analysis item #8 marked done (`docs-internal/competitive-feature-gap-analysis.md:157`).

**Phase 2 — Watch.**
Track new `G-` pixel-row creation for 60 days against the ≥ 2× target. If Starter-tier demand appears in
lost-deal notes, open the Open Q1 pricing split as its own small spec.

**Cross-service gates — all clear:**
- **No migration** → no Supabase SQL-editor step, no deploy ordering constraint.
- **No Worker logic change** → **`npm run deploy:prod` is not required.** The `pixels.js` comment and the
  added `.test.mjs` case ride the next routine Worker deploy; the feature is complete without one.
- **No email** → `_dmarc.qravio.app` is not a gate.
- **No cron, no new env var, no new secret, no new external service.**
- Backend + frontend deploy in any order (the 400-message string and the FE hint are independent).

## 11. Risks, Edge Cases & Open Questions

**R1 — "Analytics" framing invites dropping the consent gate (the #1 risk).** The most likely way this
harmless change becomes harmful: someone later reasons "GA4 is analytics, not marketing — it shouldn't need
consent" and moves it outside `marketingConsentGranted()`. GA4 sets `_ga`/`_ga_*` cookies and is squarely
within ePrivacy Art. 5(3); most EU DPAs treat non-exempt analytics as consent-requiring.
**Mitigation:** the gate is an explicit **Non-Goal** (§3), the TRD forbids touching `index.js:428`, and the
Worker comment records *why* analytics tags sit behind the marketing gate. Flag this to eng-review.

**R2 — Scope creep into GTM.** "Relabel as analytics" is one short conversation away from "so can we take
a GTM container?" **Mitigation:** §3 records the reasoning (uncontrolled remote JS on a page we host,
un-validatable because container contents change post-validation, DPDP/consent-mode liability, and an SMB
core that doesn't use GTM). A test pins the rejection so it can't be loosened silently.

**R3 — Relabelling implies capability we don't have.** Calling it "Google Analytics 4" may lead users to
expect **all** scans in GA4 — including Website-redirect QRs (a 302 our HTML never touches) and custom
scan events. **Mitigation:** state both limits *in-product before configuration* (§6.5), not only in the
docs. This is the difference between an honest relabel and an oversell.

**R4 — Existing `AW-` users must be a strict no-op.** A shared slot means a careless relabel could
re-present an Ads pixel as "Analytics". **Mitigation:** the label is derived from the ID prefix, so an
`AW-` row is *structurally* incapable of displaying as GA4. Fixture test.

**R5 — Universal Analytics (`UA-`) is dead but still accepted.** Google retired UA in July 2023; a `UA-`
ID collects nothing. Tightening the regex is tempting. **Mitigation:** *don't* — v1 keeps accepting it
(stored rows must keep validating) and merely labels it "retired". **Load-bearing rule if we ever do
tighten:** tighten the **backend** validator only. The edge re-check is deliberately at least as permissive
as the backend (`pixels.js:21–23`); making the *edge* stricter would silently stop already-stored IDs from
firing. Backend-only tightening is safe; edge-only or edge-first is not.

**R6 — Our own cookies page says we don't use Google Analytics.**
`qr_frontend/src/app/(marketing)/cookies/page.tsx:152–155` states *"We do not use Google Analytics,
Facebook Pixel, or any behavioural advertising cookies."* That is about **Qravio's own** site and
dashboard and stays true — a **tenant's** GA4 tag on a **tenant's** scan page is a different surface with
its own consent strip. **Mitigation:** confirm with whoever owns legal copy that the two statements are
distinguishable; add a one-line clarifier on the cookies page if not. Cheap now, awkward later.

**R7 — Nobody notices.** A copy-only change can produce zero measurable lift if the docs and comparison
row don't land. **Mitigation:** Phase 1 (docs + matrix) is part of the feature, not a follow-up; the ≥ 2×
metric is the check.

**Open Questions**
1. **Keep GA4 at Pro+, or split it to Starter?** *Recommend keep Pro+ in v1 — splitting needs a new flag +
   migration + gate and stops being a quick win. Revisit on lost-deal evidence.* (§8)
2. **Rename the Settings tab, or only the section header?** *Recommend renaming the tab too ("Tracking &
   Analytics") — the tab label is the discovery surface that's failing; renaming only the inside fixes
   nothing.*
3. **Split the picker into three options, or one "Google" option with a smarter hint?** *Recommend three
   options — the picker is where a buyer looks for the word "Analytics". The stored value is identical
   either way, so this is free.*
4. **Do we drop `UA-` from the accepted set?** *Recommend no in v1 (keep stored rows valid; label as
   retired). If ever dropped: backend-only, per R5.*
5. **Is one help-centre article enough, or do we want a `/google-analytics-qr-code` SEO page?** *Recommend
   article-only in v1; the SEO page is a separate, optional content task.*

## 12. Dependencies

- **Retargeting Pixels (shipped):** `retargeting_pixels` table + `pixels.py` CRUD + the `retargeting_pixels`
  Pro+ flag (`0009` seed, `0013` flip) — the gate and store we are relabelling. `PRD_TRD/DONE/RETARGETING_PIXELS_PRD.md`.
- **Per-QR retargeting selection (shipped):** `0031_per_qr_retargeting.sql` (`retargeting_mode` +
  `pixel_ids` on `qr_codes`) + `build_pixels()` — the builder surface we are relabelling.
- **KV snapshot (shipped):** `write_to_kv(pixels=…)` (`cloudflare_kv.py:64`, payload L107–110), populated by
  `build_pixels()` (L198) via `sync_qr_to_kv` (L382). **Untouched** — no resync needed.
- **Edge injection (shipped):** `renderPixels`/`googleSnippet`/`injectPixelsIntoResponse`
  (`qr_cf_code/src/utils/pixels.js`) called at `src/index.js:422–431`. **Logic untouched.**
- **Consent gate (shipped):** `marketingConsentGranted()` (`qr_cf_code/src/utils/consent.js`) — the
  dependency we must **not** modify.
- **Pricing surfaces (shipped):** `PricingComparisonTable.tsx`, `PricingCards.tsx`,
  `lib/constants/pricing.ts` — one new row driven by the existing boolean.
- **No migration. No new external service, AI, email, cron, env var, or secret.**

### Appendix — Key Files

| Concern | File |
|---|---|
| Backend validator + error copy | `qr_backend/src/api/routes/pixels.py` (`_GOOGLE_RE` L33, `_VALID_PROVIDERS` L35, Google 400 message L80) |
| Entitlement gate (unchanged) | `qr_backend/src/api/routes/subscription.py` (`FEATURE_ENFORCEMENT["retargeting_pixels"]` L551) |
| KV snapshot (unchanged) | `qr_backend/src/utilities/cloudflare_kv.py` (`write_to_kv` pixels param L64, payload L107–110, `build_pixels` L198, website short-circuit L219–220, `sync_qr_to_kv` call L382) |
| Per-QR mode fields (unchanged) | `qr_backend/src/api/routes/qr.py` (create/update models L879–882 / L901–903, create default L1608–1611) |
| Edge snippet + comment tweak | `qr_cf_code/src/utils/pixels.js` (header comment L1–13, `PIXEL_RE.google` L18–25, `googleSnippet` L66–74) |
| Edge injection site (unchanged) | `qr_cf_code/src/index.js` (L422–431 — consent-gated `injectPixelsIntoResponse`) |
| Consent gate (must not change) | `qr_cf_code/src/utils/consent.js` (`marketingConsentGranted`) |
| Settings UI copy + hints | `qr_frontend/src/components/org/settings/PixelsSection.tsx` (`FORMAT_HINTS` L16–19, upgrade card L41–45, header L70–72, info box L76–83, provider Select L89–97) |
| Configured-tag row labels | `qr_frontend/src/components/org/settings/PixelRow.tsx` (`PROVIDER_LABEL` L7–10) |
| Builder selector labels | `qr_frontend/src/components/qr-generator/pixel-selector.tsx` (`MODE_OPTIONS` L29–33, `PROVIDER_LABEL` L35–38, upgrade hint L72–78) |
| Builder accordion title | `qr_frontend/src/components/org/content-type/website/QRDesign.tsx` (~L654–690) |
| Settings tab label | `qr_frontend/src/app/[slug]/(dash)/settings/page.tsx` (`Section` union L25, gate L41, tab L46) |
| Comparison matrix + cards | `qr_frontend/src/components/pricing/PricingComparisonTable.tsx` (L49), `PricingCards.tsx` (L306) |
| Pinning tests | `qr_backend/tests/unit_tests/test_retargeting_pixels.py`, `qr_cf_code/src/utils/pixels.test.mjs` (existing GA4 case L68) |
| Legal-copy cross-check | `qr_frontend/src/app/(marketing)/cookies/page.tsx` (L152–155) |
| Gap-analysis source | `docs-internal/competitive-feature-gap-analysis.md` (item #8, L157–162) |
