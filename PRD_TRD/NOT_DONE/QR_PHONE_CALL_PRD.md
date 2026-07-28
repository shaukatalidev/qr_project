# PRD — Phone / Call Static QR

**Status:** Draft · **Author:** Product · **Date:** 2026-07-25
**Priority:** Quick win (gap-analysis **#9**, S effort, Fit 3, Impact 2). Hours of work, not days. Two jobs: close a **type-parity** hole every competitor fills (Beaconstac, Bitly, QR Tiger, QRCodeChimp, Scanova all ship a "Phone/Call" type), and mint another **free-tool SEO long-tail page** (`/phone-qr-code-generator`) for the acquisition strategy. No moat, no differentiation — deliberately commodity.
**Tiers:** **All plans, ungated.** Static QR types are **not** plan-gated anywhere in the product — the type gate (`dynamic_qr_types`) lives inside `if category == "dynamic":` (`qr_backend/src/api/routes/qr.py:1548`), and `0027_open_all_qr_types.sql` only rewrites that dynamic list. `phone` inherits the exact posture of `sms`/`wifi`/`email`/`bitcoin`: free, unlimited, no flag. It is also generatable **logged-out** on the public tool page.
**Plan flags:** **None.** No `FEATURE_ENFORCEMENT` entry, no `_QUOTA_SPEC` entry, no seed — so `test_feature_gate_coverage` is untouched. Adding a flag here would be a regression against the house's open-the-types posture (`0027`, `0028`).
**Split from:** the **static QR type recipe**, modeled field-for-field on `sms`: `SMSContent` Pydantic model (`qr.py:432`), the `Literal[...]` type union (`qr.py:838–863`), `generateStaticQRContent`'s `case 'sms'` (`qr_frontend/src/lib/qr-generator.ts:151`), `SMSContent.tsx`, and the `TYPE_PAGES` SEO entry (`qr-type-pages.ts:1143`). **Not** split from the dynamic-QR stack — no KV, no Worker, no landing page, no scan analytics.

**Rev (2026-07-25, post eng-review):** Reviewed via `/plan-eng-review`; ships **as-drafted**. Verified against code that the sibling *typed* static types (`sms`/`bitcoin`/`paypal`/`email`/`whatsapp`/`wifi`) each write a detail table on create (`qr.py:1993/2007/…`) and read it back in `_build_content_from_db_rows` (L1206/1212). Decision on the one open architecture question: **phone gets NO detail table** — the single `tel:<number>` scalar is stored as `qr_destinations[0].target_url` and reconstructed like the `url`/`text` types (`qr.py:1182`), not via a `qr_phone_details` row. This is a **deliberate, principled divergence** from `sms`'s table and from the UPI decision (which added `qr_upi_details`): UPI carries four structured fields worth a table; phone carries one scalar. **Consequence: no migration** (the contingency `0036` table sketched in the TRD is dropped). Remaining open questions accepted per the PRD's recommendations (picker label "Phone"; no `/call-qr-code-generator` alias in v1; a live "will dial …" echo; keep "· no tracking" in the type description). Build must **consume** the vestigial `phoneSchema`/`PhoneContent`/`QR_TYPE_LABELS.phone`, not duplicate them (R6).

---

## 1. TL;DR / Summary

Add a **`phone` static QR type** that encodes a `tel:` URI. The user types one phone number; the QR
encodes `tel:+919876543210`; scanning it opens the phone's dialer with that number pre-loaded, one tap
from a call. That is the entire feature.

It ships as the **thinnest possible clone of the existing `sms` type** — one Pydantic model, one entry
in the type `Literal`, one `case` in `generateStaticQRContent`, one ≤200-line content-form component,
one `TYPE_PAGES` entry — and it lands **three URLs for free** off that single content entry:
`/phone-qr-code` (info), `/phone-qr-code-generator` (free logged-out generator), and `/embed/phone`
(iframe embed), all auto-derived from `TYPE_PAGES`/`STATIC_TOOL_PAGES()`
(`qr_frontend/src/app/sitemap.ts:42–54`, `src/app/(marketing)/[slug]/page.tsx:21`,
`src/app/embed/[type]/page.tsx:16`).

**Deliberately boring, and deliberately incomplete.** Static QRs never reach the Cloudflare Worker —
the KV write is fenced behind `if category == "dynamic":` (`qr.py:2250`) — so a Phone QR has **no scan
analytics, ever**. That is not a bug we will fix; it is the definition of a static code. We ship the
known-limitation copy alongside the feature (§6.4, §11 R1) rather than pretending otherwise.

## 2. Problem & Motivation

**We're missing a checkbox that costs hours to fill.** "Phone / Call QR" is a standard row in every
competitor's type matrix. We ship 9 static types — `url`, `text`, `vcard`, `whatsapp`, `wifi`, `email`,
`sms`, `bitcoin`, `paypal` (`qr_frontend/src/lib/constants/qr-types.ts:111–120`) — and a *Call* type is
the conspicuous omission: we let you text a number (`sms`), WhatsApp a number (`whatsapp`), and email an
address (`email`), but not **call** a number. In a side-by-side that reads as an arbitrary hole, and to
the buyer it reads as immaturity.

**The `url` type cannot substitute — verified.** A user cannot work around this by making a "URL" QR
containing `tel:+91…`. Three independent layers reject it:
- `websiteSchema` (`qr_frontend/src/lib/validations/qr-schemas.ts:13–20`) — `.url()` **plus**
  `.refine((url) => url.startsWith('http://') || url.startsWith('https://'), 'URL must start with
  http:// or https://')`.
- `websiteFormSchema` in the builder's own website form
  (`qr_frontend/src/components/qr-generator/content-types/WebsiteContent.tsx:28–33`) — `.url(...)` plus
  `.refine((url) => /^https?:\/\//i.test(url), 'Enter a valid website URL')`.
- The shared `ProtocolUrlInput` control offers a **closed scheme dropdown**:
  `URL_PROTOCOLS = ['https://', 'http://']` (`qr_frontend/src/lib/url.ts:6`). There is no field in
  which a `tel:` string can even be typed.

So the answer to "just use a URL QR" is: **the product physically will not let you.** A dedicated type
is the only path.

**It is a genuine SEO asset, not just parity.** "phone qr code generator" / "call qr code generator" is
exactly the head-of-long-tail free-tool query our acquisition strategy targets, and our free-tool page
machinery is fully programmatic — one `TYPE_PAGES` entry with `isStaticTool: true` produces the info
page, the tool page, the embed route, and both sitemap rows with **zero new routing code**.

**It is nearly free to build.** The `sms` recipe is ~10 touch-points across two services, all additive
`case`/entry additions. Vestigial `phone` scaffolding already exists in the codebase from an earlier
pass: `phoneSchema`/`PhoneContent` (`qr-schemas.ts:130–135`, currently **referenced by nothing**),
`QR_TYPE_LABELS.phone = 'Phone'` (`src/app/[slug]/(builder)/build/page.tsx:77`), and
`QR_LOGO_COLORS.phone` (`qr-types.ts`). Someone started this and stopped; we finish it.

## 3. Goals & Non-Goals

**Goals**
- Add a **`phone` static QR type** encoding `tel:<number>`, creatable in the logged-in builder **and**
  on the logged-out public builder, on **every plan**, with no flag and no limit.
- **Mirror the `sms` recipe exactly** so the diff is boringly reviewable and the type behaves
  identically to its 9 siblings (validation shape, form layout, preview, download, save-to-account).
- **Ship the SEO assets in the same PR**: a `TYPE_PAGES` entry (`isStaticTool: true`) + generator-page
  FAQs, which yields `/phone-qr-code`, `/phone-qr-code-generator`, `/embed/phone`, and two sitemap rows.
- **Be explicit in-product that static means no analytics** — pre-empt the "why does my Call QR show 0
  scans?" ticket with copy at the point of choice, not in a help doc.
- **No migration, no Worker deploy, no plan-flag churn** (verified in §12 / TRD §2, §4).

**Non-Goals**
- **No scan analytics for `phone`.** Static QRs never write to KV (`qr.py:2250`) and never hit the
  Worker, so there is nothing to count. Not a limitation to engineer around — a property of the type.
- **No dynamic `phone` type.** A dynamic "call" QR would mean redirecting a scan to a `tel:` URI from
  our edge, which is a materially worse scan experience (an interstitial page between camera and
  dialer) for the one type where the whole value is *immediacy*. If a user wants a trackable,
  editable phone CTA, the answer is a **`business` or `vcard_plus` dynamic QR** whose landing page
  carries a Call button — that already exists.
- **No extension of `phone` into `sms`/`whatsapp` territory** — no message body, no `tel:` extension
  (`;ext=`), no `wtai://` legacy scheme.
- **No new detail table** (`qr_phone_details`). One scalar field does not earn a table (§12 / TRD §2).
- **No editing of an existing phone QR's number.** Static QRs are **name-only editable** by design
  (`qr.py:2790–2796` — any field beyond `name` on a static QR is a `403`). `phone` inherits that; it is
  not a `phone`-specific gap.
- **No `phone` entry in `dynamic_qr_types`** — it is a static type; touching that array would be wrong
  and would risk the `0027` invariant ("NEVER set the list to `[]`").

## 4. Target Users & Personas

| Persona | Who | Job-to-be-done | Today's pain |
|---|---|---|---|
| **Local Service Provider ("Rakesh")** | Plumber/electrician/tutor with a van decal or pamphlet | One-tap "call me now" from print | Prints the number as text; customer mistypes it or gives up |
| **Retail Counter Owner ("Priya")** | Shop with a counter-top standee | Scanner reaches the shop line instantly for stock/queries | Uses a WhatsApp QR, which excludes non-WhatsApp callers and forces a text |
| **Real-Estate / Field Agent ("Imran")** | Yard signs, brochures, hoardings | Inbound call from a passerby without saving a contact | vCard QR is heavyweight — the scanner must save a contact, then call |
| **Free-tool visitor (SEO)** | Lands on `/phone-qr-code-generator` from search | One free, watermark-free call QR, no signup | We rank for nothing here; they use a competitor's generator |

Primary buyer is not a buyer at all — it's an **acquisition surface**. The logged-out free-tool visitor
is the point; the logged-in parity is the secondary benefit. Treat conversion (`Save to account` →
signup, per `PublicQRBuilder.tsx:162`) as the win condition, not paid upgrades.

## 5. User Stories

- As a **local service provider**, I want a QR that opens the dialer with my number filled in, so that a
  customer reading my flyer can call me in one tap instead of retyping ten digits.
- As a **shop owner**, I want a *call* QR rather than a WhatsApp QR, so that customers who don't use
  WhatsApp — or who want to actually talk — aren't excluded.
- As a **logged-out visitor**, I want to generate a phone QR for free, with no signup and no watermark,
  so that I can print it today; and I want an obvious path to save it to an account if I come back.
- As **any user**, I want the phone-number field to reject a malformed number *before* I download and
  print 500 flyers, so that I never ship a dead QR.
- As **any user**, I want to be told **before I choose** that a static Phone QR has no scan tracking and
  cannot be edited later, so that I'm not surprised by a 0-scan dashboard row.
- As a **user who does want tracking**, I want a clear pointer to the dynamic alternative (a Business or
  vCard Plus QR with a Call button), so that the limitation comes with a path forward.
- As an **API consumer**, I want `phone` to appear in the public API's static-type list and content-field
  table, so that I can create Call QRs programmatically like every other static type.

## 6. UX / Product Flow

**6.1 Type picker**
`phone` appears in the **Static** section of the type grid alongside `sms`/`whatsapp`/`email` — a new
`ALL_TYPES` entry (`qr-types.ts`, static block at :111–120) with a phone-handset icon. Same treatment in
the logged-out picker (`PublicQRBuilder` / `PublicQRTypeSelector`, which filters
`ALL_TYPES.filter(t => t.category === 'static')`). No badge, no lock, no upgrade chip — it is free
everywhere.

**6.2 Content step — one field**
A `PhoneContent` form component modeled directly on `SMSContent.tsx`, minus the message textarea:
- Single **"Phone number"** `Input` (`type="tel"`, placeholder `E.g. +919876543210`), react-hook-form +
  zod, `mode: 'onChange'`, wired through `useStandaloneFormSync` and `NavButton` exactly as
  `SMSContent.tsx:53–80` does.
- Validation reuses the **already-present-but-unused** `phoneSchema`
  (`qr-schemas.ts:130–135`): `.min(1, 'Phone number is required')` +
  `.regex(/^\+?\d{10,15}$/, 'Please enter a valid phone number with country code')` — the identical rule
  `smsSchema.number` and `whatsappSchema.number` use, so error copy is consistent across the three.
- Inline helper under the field: **"Include the country code (e.g. +91) so the code works for scanners
  anywhere."**

**6.3 Design + download step** — unchanged. The live preview (`useQRPreview.ts:31–32`) calls
`generateStaticQRContent('phone', content)` → `tel:+919876543210`, and the existing design/download
pipeline handles it like any other static payload.

**6.4 The known limitation, surfaced at the point of choice (load-bearing)**
This is the one piece of UX that is *not* a copy-paste of `sms`, and it is the whole reason this PRD
exists rather than a ticket. Three placements:
1. **Type-picker description** — the `ALL_TYPES` `description` reads "Start a phone call · no tracking"
   rather than a bare "Start a phone call".
2. **Content-step note** — a single muted line beneath the form: *"Static QR — the number is printed
   into the code itself. It works forever and needs no internet, but it can't be tracked or changed
   later. Want scan analytics or an editable number? Use a Business QR with a Call button."* with the
   second sentence linking to the dynamic flow.
3. **Free-tool page + FAQ** — the `/phone-qr-code-generator` FAQ block carries an explicit
   *"Can I see how many people scanned my phone QR code?"* → *"No…"* entry (§10 acceptance).

**6.5 Free-tool page (`/phone-qr-code-generator`)**
Rendered by the existing `QrToolPageContent` with `PublicQRBuilder initialType="phone"
initialCategory="static" initialStep={2}` (`QrToolPageContent.tsx:52–57`) — the visitor lands directly on
the one-field form. `isStaticContentComplete` gains a `case 'phone'` so the wizard's completeness check
requires a non-empty number (`PublicQRBuilder.tsx:33–52`). `/create?type=phone` deep-links work with no
code change — `parseCreateParams` derives its allowlist from `ALL_TYPES` (`src/lib/create-params.ts:6–8`).

**6.6 Dashboard**
A saved phone QR renders in the list/detail with the standard **Static** chip
(`QRCodesTable.tsx:216–221`, `QRCard.tsx:137–142`), `0` scans, and the existing static behavior: the
name is editable, the content is not.

## 7. Scope

**In scope (v1)**
- Backend: `"phone"` in the `QRCodeCreate.type` `Literal` union (`qr.py:838–863`); `PhoneContent`
  Pydantic model + `phoneContent` on `QRContent`; a `qr_type == "phone"` reconstruction branch in
  `_build_content_from_db_rows` (which already receives `qr_type`, `qr.py:1064`). **No detail table.**
- Frontend: `ALL_TYPES` + `QR_TYPES` + `TYPE_ICONS` entries; `generateStaticQRContent` `case 'phone'`;
  a new `PhoneContent.tsx` (≤200 lines, one export) + barrel export + `QRContent.tsx` dispatch case;
  `isStaticContentComplete` case; `qr-type-icons.ts` + `qr-recommendations.ts` entries; `QRContent`
  TS interface field.
- SEO: a `TYPE_PAGES` entry (`isStaticTool: true`, unique long-form copy — anti-thin-content per the
  file's own header comment) + a `TOOL_FAQS.phone` block. Yields `/phone-qr-code`,
  `/phone-qr-code-generator`, `/embed/phone`, and 2 sitemap rows automatically.
- Docs: `phone` added to `STATIC_TYPES` and `CONTENT_BY_TYPE` in `api-docs-objects.ts` (the public API
  reference), since `api_public.py:313` reuses `qr_routes.QRCodeCreate` and therefore accepts `phone` the
  moment the `Literal` is extended.
- The three known-limitation copy placements (§6.4).

**Out of scope / Future**
- Scan analytics for `phone` *(impossible for any static type — §3)*.
- A **dynamic** phone/call type *(deliberately rejected — §3)*.
- A `qr_phone_details` table *(unearned by one scalar — §12 / TRD §2)*.
- Editing a static QR's number post-create *(a whole-category behavior, `qr.py:2790`; out of scope)*.
- `tel:` extensions (`;ext=`), multiple numbers, or a "call + SMS" combo type *(future, low value)*.
- A `/call-qr-code-generator` slug alias *(see §11 Open Q2 — the `TYPE_PAGES` slug↔type mapping is
  `slug.replace(/-/g,'_')` (`qr-type-pages.ts:44`), so an alias needs a real redirect, not a second
  entry)*.
- Any marketing-site nav change beyond the auto-generated pages.

## 8. Pricing & Packaging

| Surface | Tier | Flag / Limit |
|---|---|---|
| `phone` static QR (in-app builder) | **All plans (Free, Starter, Pro, Agency)** | **None** |
| `/phone-qr-code-generator` free tool | **Logged out, no account** | **None** |
| `phone` via Public API | Whatever gates the API itself (`api_access`) | **None new** |

**Why ungated — this is not a judgment call, it's the existing architecture.** The plan-based QR type
gate is scoped to dynamic types only: `if category == "dynamic":` wraps the entire `dynamic_qr_types`
check (`qr.py:1548–1567`), and `0027_open_all_qr_types.sql` writes only that array. **No static type has
ever been gated**, and every one of the 9 is generatable logged-out and free. Introducing a paywall on
the tenth would be inconsistent, would break the free-tool SEO play that is this feature's main
justification, and would contradict the recent house direction (`0027` opened all dynamic types, `0028`
opened folders to all plans).

**Where the money is:** the free tool page is a **top-of-funnel asset**. Its monetization path is the
existing `Save to account` → `/signup` handoff (`PublicQRBuilder.tsx:162`) and the static→dynamic
cross-sell embedded in the §6.4 limitation copy ("want tracking? use a Business QR"). We measure that
conversion (§9), not revenue from `phone` itself.

## 9. Success Metrics & KPIs

**Parity (the cheap win)**
- "Phone / Call QR" flips ✗ → ✓ in the comparison matrix and on `/beaconstac-alternative` within the
  release.
- `phone` present in the public API docs' static-type list and creatable via `POST /api/public/v1/qrs`.

**SEO (the real win — the reason to build)**
- `/phone-qr-code-generator` and `/phone-qr-code` **indexed within 30 days** (Search Console coverage),
  matching the indexation bar the other 9 tool pages are held to.
- Ranking for "phone qr code generator" / "call qr code generator" long-tail within 90 days; organic
  sessions on the two new URLs tracked against the median of the existing 9 static tool pages —
  **at or above median by day 90**, else the copy needs work, not the code.

**Funnel**
- Free-tool → signup conversion on `/phone-qr-code-generator` **at or above the static-tool-page
  median** (the `savePendingQR` → `/signup` path).
- Static→dynamic cross-sell: clicks on the §6.4 "use a Business QR for tracking" link, tracked as the
  upsell signal this feature actually produces.

**Support (the risk this PRD is mostly about)**
- **"Why does my Call QR show 0 scans?" tickets ≈ 0.** This is the headline metric. If the §6.4 copy
  works, the ticket never gets filed. If tickets appear, the fix is copy placement — not analytics.
- Zero "my printed Call QR doesn't dial" reports — i.e. the `+`-prefixed international format guidance
  landed (R2).

## 10. Rollout Plan

Single phase. There is no migration, no Worker deploy, no flag flip, and no beta cohort — the feature is
additive, ungated, and cannot regress an existing type.

**Phase 0 — Build + ship (one PR).**
Backend `Literal` + `PhoneContent` model + `_build_content_from_db_rows` branch → frontend type
constants, `generateStaticQRContent` case, `PhoneContent.tsx`, dispatch cases → `TYPE_PAGES` +
`TOOL_FAQS` entry → API-docs constants → §6.4 copy. Deploy backend **before** frontend (the FE will
POST `type: "phone"`, which the un-updated backend would reject with a `422` on the `Literal` — see TRD
§11 deploy order).

**Acceptance (all must pass before merge):**
- Logged-in: create a phone QR → the encoded payload is exactly `tel:+919876543210` → downloading and
  scanning it on **both iOS and Android** opens the native dialer pre-filled (device check, not a unit
  test — this is the only real-world risk).
- Logged-out: `/phone-qr-code-generator` renders the one-field form at step 2, generates, downloads
  watermark-free, and `Save to account` round-trips through signup.
- `/phone-qr-code`, `/phone-qr-code-generator`, `/embed/phone` all render; both appear in
  `/sitemap.xml`; `/create?type=phone` deep-links to the content step.
- A malformed number (`abc`, `12345`) is rejected client-side before download.
- The QR list shows the new QR with a **Static** chip and 0 scans; renaming works; editing the number
  returns the existing static `403` (`qr.py:2790`).
- The §6.4 limitation copy is present in all three placements.
- `POST /api/public/v1/qrs` with `{"type":"phone","category":"static","content":{"phoneContent":
  {"number":"+919876543210"}}}` succeeds and the returned `preview_url` SVG encodes the `tel:` URI (the
  public preview endpoint already renders `qr_destinations.target_url` for static QRs —
  `api_public.py:1124–1127`).

**Cross-service gates — all pre-cleared:**
- **No Worker change → `npm run deploy:prod` is NOT required.** Static QRs never write to KV
  (`qr.py:2250`), so `qr_cf_code` is byte-for-byte untouched. The Worker↔React template-mirroring house
  rule does not apply (no scan page exists to mirror).
- **No migration → nothing to apply by hand in the Supabase SQL editor.**
- **No email → the unpublished `_dmarc.qravio.app` record is not a gate.**
- **No new plan flag → `test_feature_gate_coverage` is untouched.**

## 11. Risks, Edge Cases & Open Questions

**R1 — "Why no scans on my Call QR?" (the known, accepted limitation).** A user creates a phone QR,
watches the dashboard, sees `0`, and files a ticket. Static QRs mint a `short_code` unconditionally
(`qr.py:1615`) but never get a KV entry (`qr.py:2250`), so the edge never sees the scan and the counter
never moves. **Mitigation:** it is a copy problem, not an engineering one — the three §6.4 placements
put the limitation *before* the choice, and each one offers the dynamic alternative. **Explicitly
accepted:** we will not add analytics to static types, and we will not hide the 0.

**R2 — Number formatting → dead printed QRs (the highest real-world cost).** A number without a country
code (`9876543210`) dials fine domestically but fails for an international scanner; spaces, hyphens, and
parentheses are common in user input and are **not** valid in a `tel:` URI. A wrong number discovered
after a 500-flyer print run is unrecoverable, because static QRs cannot be edited. **Mitigation:** reuse
`phoneSchema`'s `/^\+?\d{10,15}$/` (which already rejects separators outright, matching `sms`/`whatsapp`),
the "include the country code" helper text, and a live preview of the resolved `tel:` string. **Do not**
silently strip separators — `whatsapp` does that (`qr-generator.ts:159`, `.replace(/[^0-9]/g,'')`) and
it would mask a genuine typo here.

**R3 — Scanner/OS variability.** Some camera apps require an explicit user tap before opening the
dialer; a few older Android launchers show a confirm sheet; a desktop webcam scanner may do nothing.
**Mitigation:** this is inherent to `tel:` and identical for every competitor's Call QR. Cover it in the
tool-page FAQ ("Does scanning place the call automatically? No — the dialer opens pre-filled and you tap
to call, which is a phone security safeguard") and verify on real iOS + Android hardware at acceptance.

**R4 — Thin-content SEO penalty.** `qr-type-pages.ts`'s own header comment warns copy must be unique per
type ("anti-thin-content"), and `QrToolPageContent.tsx:18–19` notes that shared FAQs previously made the
`/[slug]-qr-code` and `/[slug]-qr-code-generator` twins near-duplicates. A lazily-cloned `sms` entry
would produce two thin pages and could drag the whole programmatic set. **Mitigation:** write genuinely
distinct `phone` copy (use cases: van decals, yard signs, counter standees, service pamphlets) and a
**separate** `TOOL_FAQS.phone` block from the `TYPE_PAGES.faqs` block — same discipline the other 9
follow.

**R5 — Cannibalizing `whatsapp`/`sms`.** In India, WhatsApp is often the *preferred* contact channel, so
some users who'd be better served by a WhatsApp QR will pick Phone. **Mitigation:** low stakes (both are
free static types, both take 30 seconds) and the type-picker descriptions differentiate them. Not worth
a chooser UI.

**R6 — Vestigial scaffolding drift.** `phoneSchema`/`PhoneContent` (`qr-schemas.ts:130–135`),
`QR_TYPE_LABELS.phone` (`build/page.tsx:77`), and `QR_LOGO_COLORS.phone` already exist from an
abandoned attempt and are **currently referenced by nothing**. Re-adding parallel definitions instead of
wiring these up would leave two sources of truth for the same validation. **Mitigation:** the build must
*consume* `phoneSchema`, not duplicate it; grep for existing `phone` symbols before adding any (TRD §5.1).

**R7 — `preview_url` semantics (pre-existing, flagged not fixed).** `QRCodeResponse` derives
`preview_url` from `short_code` for **every** QR including static ones (`qr.py:959–964`), even though a
static short code has no KV entry. The public preview endpoint already handles this correctly — for
`category == "static"` it renders `qr_destinations[0].target_url` rather than the short link
(`api_public.py:1124–1127`) — so a phone QR's preview SVG will correctly encode `tel:…`. **This works
only because we store the `tel:` URI in `qr_destinations`** (TRD §2). Verify at build; do not change the
shared behavior.

**Open Questions**
1. **Type-picker label — "Phone" or "Call"?** *Recommend **"Phone"** for the picker (matches the
   existing vestigial `QR_TYPE_LABELS.phone = 'Phone'` and the `phone` slug), with "Call" used in the
   description and marketing copy. Consistency with the type id beats a marginally punchier label.*
2. **Add a `/call-qr-code-generator` alias for the second search intent?** *Recommend **not in v1**.
   `slugToBuilderType` is a mechanical `slug.replace(/-/g,'_')` (`qr-type-pages.ts:44`), so a second
   `TYPE_PAGES` entry with slug `call` would map to a non-existent `call` type. A true alias needs a
   `next.config` redirect or an explicit slug→type override — do it as a follow-up only if "call qr
   code" outperforms "phone qr code" in Search Console.*
3. **Does the content step get a live "will dial: +91 98765 43210" echo?** *Recommend yes — one muted
   line. Given R2's unrecoverable failure mode (printed, uneditable), showing the resolved `tel:` target
   is the cheapest possible insurance.*
4. **Should the type-picker description carry "· no tracking", or is that too negative on a free tool?**
   *Recommend keeping it. The support cost of a surprised user exceeds the conversion cost of an honest
   label, and it doubles as the static→dynamic cross-sell hook. Product to confirm the exact wording.*

## 12. Dependencies

- **Static QR type recipe (shipped):** `QRCodeCreate.type` `Literal` (`qr.py:838–863`), `SMSContent`
  model (`qr.py:432`), `QRContent` model (`qr.py:530–550`), `_build_content_from_db_rows`
  (`qr.py:1062`), and the destination-based static persistence path — the builder writes
  `generateStaticQRContent(...)` output into `destinations[0].target_url`
  (`src/app/[slug]/(builder)/build/page.tsx:282`, `:332`).
- **Static QR payload encoder (shipped):** `generateStaticQRContent` (`qr-generator.ts:130+`) and its
  consumers `useQRPreview.ts:31`, `build/page.tsx:282`, `PublicQRBuilder.tsx`.
- **Builder wizard (shipped):** `QRContent.tsx` dynamic-import dispatch (`:102–108`, `:402–414`),
  `useStandaloneFormSync`, `NavButton`, react-hook-form + zod + shadcn.
- **Public/free-tool builder (shipped):** `PublicQRBuilder.tsx`, `PublicQRTypeSelector.tsx`,
  `parseCreateParams` (`src/lib/create-params.ts`), `savePendingQR`.
- **Programmatic SEO page machinery (shipped):** `TYPE_PAGES` / `STATIC_TOOL_PAGES()` / `resolveTypeSlug`
  (`qr-type-pages.ts:44, 1395–1420`), `QrTypePageContent`, `QrToolPageContent`, `TOOL_FAQS`,
  `sitemap.ts:42–54`, `(marketing)/[slug]/page.tsx`, `embed/[type]/page.tsx`.
- **Public API (shipped):** `api_public.py:313` reuses `qr_routes.QRCodeCreate` — extending the `Literal`
  is the only backend change the API needs; `api_public.py:1124–1127` already renders static previews
  from the destination.
- **Existing but unused `phone` scaffolding:** `phoneSchema`/`PhoneContent` (`qr-schemas.ts:130–135`),
  `QR_TYPE_LABELS.phone` (`build/page.tsx:77`), `QR_LOGO_COLORS.phone` (`qr-types.ts`) — consume, don't
  duplicate.
- **No migration. No Cloudflare Worker or KV dependency. No AI, email, cron, payment, or new external
  service. No new plan flag.**

### Appendix — Key Files

| Concern | File |
|---|---|
| Type union (`"phone"`) | `qr_backend/src/api/routes/qr.py` (`QRCodeCreate.type` Literal, ~L838–863; `"sms"` at L859) |
| Content model | `qr_backend/src/api/routes/qr.py` (NEW `PhoneContent` beside `SMSContent` ~L432; `phoneContent` on `QRContent` ~L540) |
| Read-back reconstruction | `qr_backend/src/api/routes/qr.py` (`_build_content_from_db_rows` ~L1062, already receives `qr_type`; `sms` branch ~L1205; destination fallback ~L1180) |
| Static persistence (no table) | `qr_backend/src/api/routes/qr.py` (destinations insert ~L1634; KV write fenced by `if category == "dynamic"` ~L2250) |
| Public API + preview | `qr_backend/src/api/routes/api_public.py` (reuses `QRCodeCreate` ~L313; static preview from `target_url` ~L1124–1127) |
| Type constants | `qr_frontend/src/lib/constants/qr-types.ts` (`ALL_TYPES` static block ~L111–120; `QR_TYPES` ~L207; `TYPE_ICONS` ~L238) |
| `tel:` encoder | `qr_frontend/src/lib/qr-generator.ts` (`generateStaticQRContent`, `case 'sms'` ~L151) |
| Validation (reuse) | `qr_frontend/src/lib/validations/qr-schemas.ts` (`phoneSchema` ~L130–135 — **already exists, unused**) |
| Why `url` can't substitute | `qr_frontend/src/lib/validations/qr-schemas.ts:13–20`, `content-types/WebsiteContent.tsx:28–33`, `src/lib/url.ts:6` |
| Builder form | `qr_frontend/src/components/qr-generator/content-types/PhoneContent.tsx` (NEW — clone of `SMSContent.tsx`, ≤200 lines) |
| Builder dispatch | `qr_frontend/src/components/qr-generator/QRContent.tsx` (`case 'sms'` ~L402–414), `content-types/index.ts` barrel |
| Free-tool completeness | `qr_frontend/src/components/marketing/PublicQRBuilder.tsx` (`isStaticContentComplete` ~L33–52) |
| SEO pages (3 URLs, 1 entry) | `qr_frontend/src/lib/constants/qr-type-pages.ts` (NEW `phone` entry, `isStaticTool: true`; `sms` at ~L1143) + `src/lib/constants/tool-faqs.ts` (NEW `phone` block; `sms` at ~L126) |
| API docs constants | `qr_frontend/src/lib/constants/api-docs-objects.ts` (`STATIC_TYPES` ~L100, `CONTENT_BY_TYPE` ~L113) |
| Worker | **No change** (static never reaches KV or the edge) |
| Migration | **None required** (see TRD §2) |
