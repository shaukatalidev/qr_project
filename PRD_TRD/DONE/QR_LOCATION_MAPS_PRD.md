# PRD — Location / Google Maps QR Type

**Status:** Draft · **Author:** Product · **Date:** 2026-07-25
**Priority:** Quick win (gap-analysis **#6**, `S · Fit 4 · Impact 2`). Type-completeness parity + an SEO landing page on a high-volume India query ("Google Maps QR code", "location QR code generator"). **Explicitly low impact** — a scanner can already reach the same place via a plain `website`/`url` QR pointing at a Maps link. Ship it thin; do not over-invest.
**Tiers:** **All plans, ungated.** QR *type* stopped being a paywall lever at migration `0027` ("open all QR types") — `location` simply joins the canonical `dynamic_qr_types` array on every non-custom plan. The real fences (`max_qr`, `max_scans`, retention, custom domains, white-label) are unchanged.
**Plan flags:** **None.** No new boolean, no new limit, no `FEATURE_ENFORCEMENT` entry. The only plan-table surface is appending `"location"` to `features.dynamic_qr_types` (already registered `enforced` at `qr_backend/src/api/routes/subscription.py:534`).
**Split from:** the `business` storefront template's address→maps link — `qr_cf_code/src/pages/business/storefrontTemplate.js` **L22-34** assembles `street, city, state` into `address` and builds `https://www.google.com/maps/search/?api=1&query=<encoded>`, surfaced as the "Map" quick-action button (L52). That buried three-line helper is the whole feature; we promote it to a first-class type. **Not** the `business` type itself (a full storefront profile with hours/logo/description — `location` stays deliberately smaller), and **not** the `event` type's decorative `location` free-text string (`EventContent.location`, `qr.py:381`, which renders as text and never links).

**Rev (2026-07-25, post eng-review):** Reviewed via `/plan-eng-review`. Confirmed as-drafted on scope (2 templates, no Places API, no map tiles), the **append-if-absent `dynamic_qr_types` guard** (so it doesn't clobber the sibling quick-win types' array writes), coordinate range-validation, and the storefront link-equality regression gate. Two decisions: (1) **keep the "open Maps directly" toggle with the landing page as default** — the 302 reuses the existing website-redirect path, and the tracked+editable redirect is the differentiator vs a plain URL QR. (2) **Ship the `maps_url_override` field in v1 — with a MANDATORY map-host allowlist** (`google.com/maps`, `maps.google.*`, `goo.gl/maps`, `maps.app.goo.gl`, `maps.apple.com`, `waze.com`, `openstreetmap.org`) enforced at **both** write time (backend Pydantic validator) **and** render time (Worker), rejecting anything else and **never failing open**. This flips Open Q3 from "drop it" to "ship with allowlist"; R8's mitigation is now a **hard v1 requirement**, not conditional. Open Q5 caveat stands: because the direct-redirect toggle exists, any consumer of `HAS_LANDING_PAGE_TYPES` must treat `location` as "has a page unless the owner opted out" — verify no downstream code assumes "always renders a page."

---

## 1. TL;DR / Summary

A new first-class **`location`** dynamic QR type: the user enters a place name and an address (optionally
exact `latitude`/`longitude`), and the Cloudflare Worker serves a small branded **"here's where we are"**
landing page with the address, an optional landmark line, and big **Open in Google Maps / Apple Maps /
Waze** buttons — or, if the user ticks **"skip the page, open Maps directly"**, a straight `302` to the
maps URL.

The maps URL is built exactly the way the storefront template already builds it —
`https://www.google.com/maps/search/?api=1&query=<encoded address>` — with one addition that carries the
whole quality story: **if the user supplies `latitude`/`longitude`, the query becomes `lat,lng`, which
pins exactly.** That is our answer to messy Indian addresses, and it costs us nothing.

**No Google Places API, no Maps JavaScript API, no embedded map tiles, no API key, no per-request COGS
in v1.** Every one of those requires a billed Google Cloud key and drags ToS/caching obligations into a
feature whose Impact score is 2. The scope boundary is deliberate and stated in §7.

The real deliverable alongside the type is the **SEO asset**: a `/location-qr-code` type page plus a free,
no-account `/location-qr-code-generator` tool page (a `location` QR is, under the hood, a URL QR — the
existing static-tool machinery generates it fully client-side).

## 2. Problem & Motivation

**We have the logic and none of the credit.** Today the only way to get an address→Maps link out of
Qravio is to build a full **Business** storefront QR — a 12-field profile with hours, logo, tagline, and
description — and hope the user notices the small "Map" tile among Call/Email/Web
(`storefrontTemplate.js:47-55`). A restaurant that wants a table-tent that says *"we're here, tap for
directions"* has to fill in a business profile it doesn't want. There is no type in `ALL_TYPES`
(`qr_frontend/src/lib/constants/qr-types.ts:92-120`) whose job is "take me to this place."

**Every competitor lists it, and the search volume is real.** Beaconstac, QR Tiger, QRCodeChimp and
Scanova all ship a "Location / Google Maps" type. More to the point for us, the gap analysis flags
"Google Maps QR code" as sitting in exactly the high-volume India search band our long-tail SEO strategy
targets (`docs-internal/competitive-feature-gap-analysis.md:129`). A missing type is a missing comparison
row *and* a missing programmatic landing page.

**We must be honest: this is substitutable.** A user can already paste a Google Maps share link into a
`website` QR and get 90% of the outcome. The gap analysis says so plainly
(`competitive-feature-gap-analysis.md:145-149`) and scores Impact **2**. What the dedicated type adds is
narrow and worth exactly its small cost:
- **A form that asks the right questions** (place, address, landmark, coordinates) instead of "paste a URL".
- **An interstitial that offers Apple Maps and Waze**, which a raw Google link cannot.
- **Editability** — a dynamic `location` QR's address can be corrected after the sticker is printed.
- **A type page + free tool page** feeding the long-tail acquisition strategy.

That is the entire pitch. It is a parity/SEO asset, not a bet, and this PRD keeps it sized like one.

## 3. Goals & Non-Goals

**Goals**
- A first-class **`location`** dynamic QR type: builder form → `qr_location_details` row → KV snapshot →
  Worker landing page, following the same four-touchpoint recipe every other type uses (dispatch case,
  `build_kv_content` branch, page module, content-type form).
- **Correct pins for messy addresses** via optional manual `latitude`/`longitude` — no Places API.
- **Two ways to serve it:** a branded landing page (default) with Google/Apple/Waze buttons, or a direct
  `302` to the maps URL when the user prefers the plain-URL behavior.
- **Ungated on every plan**, joining `dynamic_qr_types` the way `0027` intends; no new plan flag.
- Ship the **SEO pair**: `/location-qr-code` type page + free `/location-qr-code-generator` tool page.
- **Extract, don't fork:** one shared maps-URL builder consumed by the new Worker page *and* the existing
  `storefrontTemplate.js`, so the two can never drift.

**Non-Goals**
- **No Google Places API / autocomplete / place-ID resolution.** It needs a billed GCP key, adds
  per-keystroke COGS on low-INR margins, and drags Places caching/attribution ToS into a low-impact
  feature. Manual lat/lng is the v1 precision escape hatch. *(Hard scope boundary — see §11 R3.)*
- **No embedded/static map tiles on the landing page.** Google Static Maps and Maps Embed both require a
  key; the unofficial `output=embed` iframe is unsupported and can break without notice. v1 renders an
  address card, not a map. *(§11 R4.)*
- **No geocoding, no reverse geocoding, no "find near me", no distance/ETA.**
- **No multi-location / store-locator page** (N branches behind one QR). That is a different, larger
  feature and would collide with the planned menu/multi-location work. *(Future.)*
- **No hours / logo / description / social links** on the location page — that is the `business` type, and
  duplicating it would create two half-storefronts. `location` stays a place, an address, and a button.
- **No new plan flag, no metering, no cron, no email, no AI.**

## 4. Target Users & Personas

| Persona | Who | Job-to-be-done | Today's pain |
|---|---|---|---|
| **Restaurant owner ("Farid")** | Single-outlet café/dhaba | A table-tent / shutter sticker that opens directions | Must build a full Business storefront to expose one map link |
| **Clinic / salon front-desk ("Divya")** | Appointment-based SMB | A WhatsApp-shareable "how to reach us" code with a landmark | Sends a screenshot of a pin; patients still call for directions |
| **Event / venue coordinator ("Ravi")** | Weddings, expos, popups | A venue code on the invite that pins the *exact* gate | `event.location` is free text and doesn't link anywhere |
| **Property / site agent ("Nikhil")** | Plots, warehouses, new builds | A pin for a site with **no usable street address** | Free-text address geocodes to the wrong block or the nearest town |
| **SEO visitor (no account)** | Googles "google maps qr code" | Generate one for free, right now | We have no page to land them on |

Primary buyer: nobody upgrades for this. It is retention/parity for existing SMB users and an acquisition
surface for the free tool page. Sizing follows accordingly.

## 5. User Stories

- As a **restaurant owner**, I want a QR that opens Google Maps directions to my outlet, so that a customer
  outside my shutter can find the entrance without calling me.
- As a **clinic manager**, I want to add a landmark line ("opposite Reliance Fresh, 2nd gate"), so that
  patients find us even though our postal address is ambiguous.
- As a **site agent** with an unaddressed plot, I want to paste the exact latitude/longitude I copied from
  Google Maps, so that the pin lands on the plot and not on the nearest post office.
- As an **iPhone user scanning the code**, I want an "Open in Apple Maps" option, so that I'm not forced
  into an app I don't use.
- As a **QR owner**, I want to preview the *exact* link a scanner will get and open it myself before I
  print, so that I catch a wrong pin at design time rather than after 500 stickers.
- As a **QR owner who just wants the plain behavior**, I want to skip the landing page and go straight to
  Maps, so that the QR behaves like the URL QR I would otherwise have built — but stays editable and tracked.
- As a **printed-sticker owner**, I want to correct the address later without reprinting, so that a shifted
  outlet doesn't invalidate my signage.
- As an **SEO visitor**, I want to generate a location QR for free without signing up, so that I get value
  first and consider an account second.

## 6. UX / Product Flow

**6.1 Type picker**
`location` appears in the dynamic section of the type picker (`ALL_TYPES`,
`qr_frontend/src/lib/constants/qr-types.ts:92-120`) as **"Location"** — *"Open directions to a place"* —
with a map-pin icon. The pin visual already exists in the codebase (`QR_LOGO_ICONS.location` at
`qr-types.ts:31`, `QR_LOGO_COLORS.location = '#F44336'` at `qr-types.ts:127`), so the type's center-logo
suggestion is free.

**6.2 Content step (Step 1) — the form**
A new `LocationContent.tsx` content-type form:
1. **Place name** (required) — "Qravio HQ", "Anand Sweets — Indiranagar".
2. **Address** — street, city, state, postal code, country (the same five fields the business form uses,
   `BusinessContent` at `qr_backend/src/api/routes/qr.py:323-339`).
3. **Landmark / directions note** (optional, one line) — India-shaped, renders under the address.
4. **Exact pin (optional, collapsed):** `latitude` / `longitude` fields with inline help — *"Long-press
   your spot in Google Maps, tap the coordinates to copy, paste here."* A single paste of `12.9716,
   77.5946` is accepted and split across the two fields.
5. **Phone** (optional) — renders a Call button; nothing else from the storefront profile is offered.
6. **"Open Maps directly (skip the landing page)"** toggle, off by default.
7. A live **"Preview the exact link scanners get →"** affordance that opens the built maps URL in a new
   tab. This is the mis-pin safety net and is the single most important control on the form (§11 R1).

**6.3 Design step (Step 3) — templates**
Two page templates, mirrored 1:1 between React preview and Worker generator per the house rule:
- **`location_card`** (default) — address card, landmark line, primary "Open in Google Maps", secondary
  "Apple Maps" / "Waze", optional "Call".
- **`location_pin`** — a bold full-bleed pin/hero treatment with the place name large and one primary
  directions button.

Two is a deliberate floor (other types ship four). Anything more is unjustified for an Impact-2 feature.

**6.4 Scanner experience**
- **Landing-page mode (default):** place name, address block, landmark, then the maps buttons. Honors
  white-label / brand entitlements like every other page (via `pageDesign.whiteLabel` / `pageDesign.brand`,
  injected in `qr_cf_code/src/handlers/qrRouter.js:43-50`).
- **Direct mode:** a `302` straight to the maps URL. The scan is still recorded — `recordScan` fires in
  `qr_cf_code/src/index.js:415`, *before* the `handleQRCode` dispatch at `:426` — so direct mode keeps full
  analytics, which is exactly the advantage over the plain URL QR it imitates.

**6.5 SEO surfaces**
- `/location-qr-code` — programmatic type page from `TYPE_PAGES`
  (`qr_frontend/src/lib/constants/qr-type-pages.ts`), unique copy, FAQs.
- `/location-qr-code-generator` — free no-account tool (`isStaticTool: true`). A location QR is a URL QR
  encoding a maps link, so the existing client-side static-tool generator handles it with no backend.
  This page is the actual acquisition asset; the dynamic type is the upsell it points at
  ("want to fix a wrong address after printing? make it dynamic").

## 7. Scope

**In scope (v1)**
- `location` dynamic QR type end-to-end: `LocationContent` model + `locationContent` on `QRContent`,
  `qr_location_details` table, create/update persistence, `build_kv_content` branch, `/internal/location/
  {qr_id}` fallback endpoint, `qrRouter.js` dispatch case, Worker page + 2 templates.
- Optional manual `latitude`/`longitude` → exact-pin maps URL; free-text address → `search?query=` (the
  storefront behavior, unchanged).
- Google Maps / Apple Maps / Waze buttons; optional Call button.
- **"Open Maps directly"** toggle → Worker `302`.
- **`maps_url_override`** (optional): a user-supplied maps link, validated against a **mandatory map-host
  allowlist** at write time (backend) **and** render time (Worker); non-allowlisted hosts rejected, never
  fail open (§11 R8). Decided in v1 per eng-review.
- Shared maps-URL builder used by both the new page and the refactored `storefrontTemplate.js` (extract,
  don't fork).
- Migration appending `"location"` to `features.dynamic_qr_types` on every non-custom plan (ungated).
- Builder form + 2 React template previews + type-picker/icon registration.
- SEO: `TYPE_PAGES` entry → `/location-qr-code` + free `/location-qr-code-generator`.

**Out of scope / Future**
- Google **Places API** (autocomplete, place IDs, verified pins) — needs a billed key; hard boundary *(§11 R3)*.
- **Embedded or static map tiles** on the landing page — needs a key *(§11 R4)*.
- **Multi-location / store locator** behind one QR *(future; likely folds into the multi-outlet work)*.
- **Geocoding** a free-text address into coordinates server-side *(would need a provider + billing)*.
- **Hours / logo / description** on the location page *(that is the `business` type — do not duplicate)*.
- **Static `location` category** in the builder *(a static location QR is literally a `url` QR; the free
  tool page covers that use case without a second type)*.
- Indoor/floor hints, what3words, Plus Codes as a first-class field *(a Plus Code pasted into the address
  field already works via `search?query=`)*.
- Linking `event.location` (`qr.py:381`) or `business` addresses to the new type *(future cleanup)*.

## 8. Pricing & Packaging

| Surface | Tier | Flag / Limit |
|---|---|---|
| `location` QR type (create + scan) | **All plans (Free, Starter, Pro, Agency)** | **None** — membership in `features.dynamic_qr_types` |
| Free `/location-qr-code-generator` tool | **No account required** | None (client-side, no backend) |

**Why ungated.** Migration `0027_open_all_qr_types.sql` settled the policy: *"QR type is no longer a paywall
lever."* Every non-custom plan holds the same 13-type array (14 for pro/agency, which additionally carry
`lead_form`). Gating a *parity* type would both contradict that decision and defeat the point — the
comparison row and the SEO page only pay off if a Free evaluator can actually use the thing. Revenue
protection continues to come from `max_qr` / `max_scans` / retention / domains, all untouched.

**The only plan-table change** is appending `"location"` to `dynamic_qr_types`. Two hazards, both handled
in the TRD:
1. `0027` wrote the array **wholesale**. Sibling quick-win types (UPI `#5`, Phone `#9`) are landing in
   adjacent migration slots and would each rewrite it — last writer wins and silently drops the others'
   type. Our migration therefore **appends if absent** rather than setting wholesale.
2. `0027`'s own warning: *"NEVER set the list to `[]` — the backend gate is fail-open on an empty list."*
   An append onto an accidentally-empty array would flip a fail-open plan into "only `location` allowed."
   The migration guards on a non-empty existing array.

No `FEATURE_ENFORCEMENT` entry is added — `dynamic_qr_types` is already registered `enforced`
(`subscription.py:534`), so `test_feature_gate_coverage` needs nothing new.

## 9. Success Metrics & KPIs

**SEO (the actual point)**
- `/location-qr-code` and `/location-qr-code-generator` indexed within 30 days; the tool page ranking
  top-20 for "location qr code generator" / "google maps qr code" within 90 days.
- ≥ 300 organic sessions/month across the two pages by day 90, with a measurable free-tool → signup rate
  (this is the acquisition claim; if it misses, the feature was still cheap).

**Parity / completeness**
- Comparison matrix and `/beaconstac-alternative` flip "Location / Google Maps QR" from ✗ to ✓.
- Type appears in the picker for **100%** of non-custom plans post-migration (verified by the sanity
  `SELECT` in the migration).

**Product (expected small — do not inflate)**
- 2–5% of newly created dynamic QRs are `location` within 60 days. **We explicitly do not expect more**;
  Impact is scored 2 and the type is substitutable.
- ≥ 25% of created `location` QRs supply `latitude`/`longitude` (proves the precision escape hatch is
  discoverable — the main quality lever).

**Quality**
- **Near-zero "the QR opens the wrong place" tickets.** Measured by support-tag watch. The preview-the-
  exact-link control (§6.2) is the mitigation being tested.
- Zero regressions on the `business` storefront's Map button after the shared-helper extraction (a visual
  + link-equality check on the existing template is a release gate).

## 10. Rollout Plan

**Phase 0 — Backend + edge (internal).**
Apply the migration (`qr_location_details` + `dynamic_qr_types` append). Add the Pydantic model, create/
update persistence, `SELECT_WITH_RELATIONS` embed, `build_kv_content` branch, and the `/internal/location`
fallback. Add the Worker dispatch case, the shared maps helper, and the page + 2 templates; refactor
`storefrontTemplate.js` onto the shared helper. `npm run deploy` to **staging** and verify: address-only
QR pins via `search?query=`, lat/lng QR pins exactly, direct-mode `302`s, scan is recorded in both modes,
and the business storefront's Map button produces a byte-identical URL to before.

**Phase 1 — Builder + previews (closed).**
`LocationContent.tsx`, the two React templates, type-picker/icon registration, the preview-the-exact-link
control. Internal + a few design-partner workspaces.
- **Acceptance:** create a `location` QR on a **Free** workspace (proves ungating) → scan shows the card
  with working Google/Apple/Waze links → editing the address updates the live QR → the direct-mode toggle
  `302`s → lat/lng overrides the free-text address → the React preview and the Worker page render the
  same template for the same `templateId`.

**Phase 2 — GA + SEO.**
`npm run deploy:prod` for the Worker, ship the `TYPE_PAGES` entry and the free tool page, update the
comparison matrix, `/beaconstac-alternative`, sitemap, and a help-center entry.

**Cross-service gates:**
- **Worker change → `npm run deploy:prod` is required** (new dispatch case + new page module).
- **Deploy order:** migration → backend → Worker → frontend. The Worker must not ship before
  `build_kv_content` writes `content` for `location`, or an early-created QR renders the error page.
  *(The `/internal/location/{qr_id}` fallback makes this non-fatal, but order it correctly anyway.)*
- **No email** → the unpublished `_dmarc.qravio.app` record is **not** a gate. **No cron.** **No AI key.**

## 11. Risks, Edge Cases & Open Questions

**R1 — Messy Indian addresses mis-pin (the #1 product risk).** Free text → `search?query=` is a *search*,
not a resolution. "Shop 4, Nr. Old Bus Stand, Sector 12" can land on the wrong sector, the nearest town, or
a same-named place in another state. **Mitigation:** (a) optional manual `latitude`/`longitude` that
bypasses geocoding entirely — the single highest-leverage, zero-cost fix; (b) a landmark line so a human
can finish the job the geocoder started; (c) the **"preview the exact link"** control in the builder so the
owner verifies *before* printing; (d) honest form copy — *"we pass your address to Google Maps as a search;
for an exact pin, paste coordinates."* We do **not** promise a verified pin.

**R2 — It is substitutable, so impact is genuinely low.** A `website` QR pointing at a Maps share link is
90% of this. **Mitigation:** accept it. Size the build to match (2 templates, no map tiles, no Places),
and bank the value where it is real — the SEO pair and the comparison row. If the tool page underperforms
at 90 days, the sunk cost is small by design.

**R3 — Places API is a scope/COGS trap (hard boundary).** Autocomplete and verified place IDs would fix
R1 properly, but they require a billed Google Cloud key, per-request cost on low-INR margins, key
rotation/restriction management, and Places ToS obligations around caching and attribution of returned
data. **Decision: out of scope in v1, no exceptions.** Revisit only if mis-pin tickets prove material, and
then as its own PRD with a cost model.

**R4 — No map preview on the landing page may read as sparse.** Competitors show a map thumbnail. Static
Maps and Maps Embed both need a key; the unofficial `maps.google.com/maps?q=…&output=embed` iframe is
undocumented, unsupported, and can break silently. **Mitigation:** design the card to look intentional — a
strong pin illustration, generous address typography, and a large primary button — rather than a hole
where a map should be. Reassess with Places in the same future round.

**R5 — `dynamic_qr_types` array collision + the empty-list fail-open trap (the #1 migration risk).** `0027`
sets the array wholesale; concurrent quick-win type migrations would clobber each other, and appending to
an accidentally-`[]` array converts a fail-open plan into "only `location` allowed"
(`qr.py:1560` — `if _allowed_types and qrType not in _allowed_types`). **Mitigation:** append-if-absent with
an explicit non-empty guard; sanity `SELECT` in the migration; a post-apply check that every non-custom
plan's array length went **up by exactly one**.

**R6 — Worker/React template drift.** Every React template must be mirrored by a Worker template (house
rule). Two templates × two implementations is four files that can diverge. **Mitigation:** keep the pair
minimal, share the URL-building logic through one helper per service, and make "same `templateId` renders
the same layout" an explicit Phase-1 acceptance check.

**R7 — Refactoring the shipped storefront template.** Extracting `storefrontTemplate.js:32-34` into a
shared helper touches a live template. **Mitigation:** the helper's address-only path must be byte-identical
to today's expression; assert link equality in a Worker unit test against the current output; ship the
refactor in the same PR so the two implementations never coexist.

**R8 — Open redirect via a user-supplied maps URL.** If we accept a `maps_url_override` (or ever accept a
raw URL) and honor it in direct mode, our short-code domain becomes an arbitrary redirector — a phishing
vector on our own hostname. **Mitigation:** validate any override against an allowlist of map hosts
(`google.com/maps`, `maps.google.*`, `goo.gl/maps`, `maps.app.goo.gl`, `maps.apple.com`, `waze.com`,
`openstreetmap.org`) at **both** write time (backend) and render time (Worker); reject anything else. **Decision (post eng-review): the override ships in v1, so this
allowlist is a hard v1 requirement** — enforced on both sides, rejecting non-allowlisted hosts, and **never
failing open** on a parse error.

**R9 — Address is publishable data, and sometimes a home.** A sole proprietor's "business address" is
frequently their residence, and the landing page is public and indexable-by-scan. **Mitigation:** the owner
is publishing it deliberately (same posture as the `business` type's address today); no new PII class, no
new storage, no scanner-side collection. Worth one line of builder copy, not a program.

**R10 — Coordinate validation.** A transposed lat/lng (`77.59, 12.97`) silently pins in the Arabian Sea.
**Mitigation:** range-check (`-90..90` / `-180..180`) in zod, Pydantic, **and** a DB `CHECK`; accept a
single pasted `"lat, lng"` string and split it; refuse `0,0`.

**Open Questions**
1. **Landing page or direct-redirect as the default?** *Recommend landing page as default with the toggle
   available — the page is the only thing distinguishing us from a URL QR, and it's where Apple Maps/Waze
   live. Product to confirm.*
2. **Two templates or one?** *Recommend two (`location_card`, `location_pin`). One is defensible for cost;
   more than two is not, at Impact 2.*
3. **Ship the `maps_url_override` field at all?** *Resolved (post eng-review): **yes, ship it in v1 — with
   the host allowlist as a hard requirement** (both write-time and render-time validation; reject
   non-allowlisted hosts; never fail open). The `website` type remains the simpler path for "I already have
   a link," but the override earns its place given the mandatory allowlist. See R8.*
4. **Should the free tool page emit a static URL QR only, or also offer "make it dynamic → sign up"?**
   *Recommend both: static generation free and instant, with the dynamic upsell as the conversion path —
   it mirrors the `/scan` tool's static→dynamic cross-sell that already ships.*
5. **Does `location` belong in `HAS_LANDING_PAGE_TYPES`?** *Yes when landing-page mode is default; note the
   direct-redirect toggle makes the flag "has a page unless the owner opted out" — confirm no downstream
   consumer of that constant assumes "always renders a page."*

## 12. Dependencies

- **QR-type recipe (shipped):** `handleQRCode` dispatch (`qr_cf_code/src/handlers/qrRouter.js:29`),
  `build_kv_content` (`qr_backend/src/utilities/cloudflare_kv.py:387`), content-type forms
  (`qr_frontend/src/components/qr-generator/content-types/`), type registration
  (`qr_frontend/src/lib/constants/qr-types.ts`). Four touchpoints, all well-trodden.
- **The maps-link logic being promoted (shipped):** `qr_cf_code/src/pages/business/storefrontTemplate.js:22-34`.
- **Template system (shipped):** `page-templates.tsx` (`ALL_PAGE_TEMPLATES`, `getTemplatesForType` at
  `:542`), `TemplatePicker.tsx`, `PagePreview/PagePreview.tsx`, and the per-type Worker dispatcher pattern
  (`src/pages/event/index.js` — `HANDLERS` map + `DEFAULT_TEMPLATE`).
- **Type gating (shipped):** `features.dynamic_qr_types` enforced at `qr.py:1546-1560` (create) and
  `:2459-2477` (bulk); registry entry at `subscription.py:534`; policy set by
  `qr_backend/migrations/0027_open_all_qr_types.sql`.
- **SEO machinery (shipped):** `TYPE_PAGES` / `isStaticTool` in
  `qr_frontend/src/lib/constants/qr-type-pages.ts` and the `(marketing)/[slug]` dispatcher.
- **Migration mechanism (shipped):** hand-applied SQL in `qr_backend/migrations/`; provisional slot
  **`0035`** — **verify against `qr_backend/migrations/` at build time**: highest on disk is `0032_
  lemonsqueezy_variant_backfill.sql`, `0033` is claimed by QR expiry, `0034` by the UPI type. The repo has
  a prior commit fixing stale slot numbers; do not trust this header.
- **No AI, no email, no cron, no new external service, no new environment variable, no API key.**

### Appendix — Key Files

| Concern | File |
|---|---|
| Logic being promoted | `qr_cf_code/src/pages/business/storefrontTemplate.js` (address assembly L22-25, `mapsUrl` L32-34, Map button L52) |
| Detail table + type unlock | `qr_backend/migrations/0035_location_qr_type.sql` (NEW — `qr_location_details` + `dynamic_qr_types` append) |
| Type registration (backend) | `qr_backend/src/api/routes/qr.py` (`QRCodeCreate.type` Literal ~L836-863; `QRContent` ~L531-556; `SELECT_WITH_RELATIONS` L998) |
| Content model + persistence | `qr_backend/src/api/routes/qr.py` (`LocationContent` beside `BusinessContent` ~L323-339; insert beside the event insert ~L2121-2126; update upsert ~L3227-3234) |
| KV snapshot | `qr_backend/src/utilities/cloudflare_kv.py` (`build_kv_content` branch ~L404-427; default-template shim ~L90) |
| Worker fallback endpoint | `qr_backend/src/api/routes/internal.py` (`GET /internal/location/{qr_id}`, mirrors `get_internal_event` L274-285) |
| Edge dispatch | `qr_cf_code/src/handlers/qrRouter.js` (new `location` case beside `business` L165-182) |
| Worker page + templates | `qr_cf_code/src/pages/locationPage.js` + `src/pages/location/{index,cardTemplate,pinTemplate,shared}.js` (NEW) |
| Shared maps-URL helper | `qr_cf_code/src/utils/maps.js` (NEW) + `qr_frontend/src/lib/maps.ts` (NEW mirror) |
| Builder form | `qr_frontend/src/components/qr-generator/content-types/LocationContent.tsx` (NEW) + `content-types/index.ts` + `QRContent.tsx` (~L149/189 imports, ~L445/458 render) |
| Type registration (frontend) | `qr_frontend/src/lib/constants/qr-types.ts` (`ALL_TYPES` L92-120, `QR_TYPES` L185-210, `TYPE_ICONS` L218-243, `HAS_LANDING_PAGE_TYPES` L75-90), `qr-type-icons.ts` |
| React templates | `qr_frontend/src/lib/constants/page-templates.tsx` (`LOCATION_TEMPLATES` + spread ~L527-539) + `components/qr-generator/templates/location/` (NEW) |
| SEO pages | `qr_frontend/src/lib/constants/qr-type-pages.ts` (`TYPE_PAGES` entry → `/location-qr-code` + `/location-qr-code-generator`) |
| Gating policy (context, unchanged) | `qr_backend/migrations/0027_open_all_qr_types.sql`, `qr_backend/src/api/routes/subscription.py:534` |
