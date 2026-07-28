# PRD — Restaurant Menu QR Type (menu-only)

**Status:** Draft · **Author:** Product · **Date:** 2026-07-25
**Priority:** Strategic bet on the largest India SMB vertical we don't serve properly. Indian F&B normalised the QR menu post-COVID, and we have **no dedicated menu type** — `business`, `list_links`, `images`, and `pdf` are all inadequate because none of them model **category → item → price → photo**. This is the anchor type of a "restaurant bundle"; the bundle, not the menu type, is the differentiation.
**Tiers:** **All plans, ungated.** `menu` is appended to `dynamic_qr_types` for Free/Starter/Pro/Agency, consistent with the house posture set by `0027_open_all_qr_types.sql` ("QR *type* is no longer a paywall lever"). The real fences (`max_qr`, `max_scans`, storage, retention, custom domains, white-label) are unchanged and already bite. Item photos consume the **existing** workspace storage quota — no new quota key.
**Plan flags:** **None new.** Gating is `dynamic_qr_types` membership only, so `FEATURE_ENFORCEMENT` is untouched and `test_feature_gate_coverage` stays green by construction (the `review_funnel` precedent — `GOOGLE_REVIEW_FUNNEL_QR_PRD.md`, migration `0021`).
**Split from:** the new-dynamic-QR-type family (peer of `review_funnel` / `lead_form`). Reuses the nested drag-and-drop editor pattern from `ListLinksContent.tsx` (dnd-kit), the multi-template Worker dispatcher pattern from `src/pages/vcard/index.js` / `src/pages/pdf/index.js`, and the existing Supabase Storage image-upload path used by `images`. **Not** the ordering/payments surface — see Non-Goals, which is the load-bearing section of this document.

**Rev (2026-07-25, post eng-review):** Reviewed via `/plan-eng-review` + an independent outside-voice pass that verified every load-bearing claim against code and found **7 ship-blockers** (folded into the TRD Rev). The most important correction to this document: **the "photos count against the existing workspace storage quota" claim is false — no aggregate storage quota exists anywhere in the codebase** (only a per-file MB cap), and **deleting a QR/item never deletes its storage objects**. Every statement here about a storage ceiling is superseded. **Four product decisions:** (1) **Per-QR photo cap** (e.g. ≤50 photos/menu) as a technical bound beside the 300-item cap, plus best-effort `bucket.remove()` on item- and QR-delete — this keeps "no new quota key" true and caps the COGS blast radius; a real `max_storage_mb` quota remains a separate cross-cutting feature (it would fix `images`/`pdf`/`video` orphaning too). (2) **Paste-import uses a heuristic parser, not the `Name | 250 | desc` + `## Category` syntax** — price-anywhere detection (trailing number, strip `₹`/`Rs`/`/-`), tab/comma/multi-space separation, and "a line with no price is a category heading", so a paste from Word/Excel/WhatsApp works; the specced developer syntax required merchants to reformat by hand, which is the friction paste-import exists to remove. Still client-side, free, confirm-before-save. (3) **Auto-linkify phone numbers and URLs in free-text fields IS allowed** (supersedes the "never linkify" recommendation) — a tappable number is a real diner convenience. **Hard safety constraints, non-negotiable:** escape first *then* linkify; scheme allowlist **`tel:` and `https:` only** (never `javascript:`, `data:`, or scheme-relative `//`); `rel="nofollow noopener"` + `target="_blank"` on external links. Note the accepted trade: this makes the menu a call-to-order-adjacent surface by degrees, so §3's no-cart/no-checkout line must be defended explicitly in review rather than structurally. (4) **Sold-out toggles are scoped into `content-editor-dispatch.tsx`** (the day-two surface the TRD missed) so R7's daily workflow is 2 taps, not a wizard walk. **Also corrected:** "live within seconds" is wrong (KV reads are colo-cached ~60 s with no `cacheTtl` set) — state a **≤60 s propagation SLO** and drop the seconds-based acceptance criterion; ~6 of the 10 KPIs have no data source and should be cut to what's queryable (menu QRs created, 30-day edit rate); the "menu last updated" stamp is unbuildable as specced (`updated_at` never reaches KV). **Write amplification, not blob size, is the top technical risk** — `resync_workspace_qrs` serially rewrites every menu blob on any branding/pixel/billing event (R1 is misranked; KV sizing has ~2 orders of magnitude of headroom).

---

## 1. TL;DR / Summary

A new **dynamic `menu` QR type**: the merchant builds a structured menu — **categories**, each holding
**items** with a name, price, description, optional photo, veg/non-veg mark, and an availability
toggle — and the Cloudflare Worker renders it as a fast, mobile-first landing page at scan time,
entirely from the KV snapshot (no backend round-trip on the hot path). Because the QR is dynamic,
**changing a price never means reprinting a table tent**.

Three Worker templates ship in v1 (`classic` text-first, `photo` card grid, `accordion` collapsible
with a sticky category jump-nav), each mirrored by a matching React preview component per the house
rule. The builder gets a nested category/item editor modelled on the existing `list_links` dnd-kit
editor, plus a **client-side paste-import** so a 60-dish menu can be entered in minutes instead of an
afternoon — item-entry friction, not rendering, is the real adoption risk.

**The hard line: this is a menu, not a restaurant OS.** No cart, no ordering, no checkout, no
payments, no table routing, no POS/KOT integration — ever, not "in v2". §3 Non-Goals states why in
full, and that boundary is the single most important product decision in this spec.

## 2. Problem & Motivation

**Indian F&B is the biggest SMB wedge we're not equipped for.** The QR menu is now the default in
Indian cafés, QSRs, bars, cloud kitchens, and hotel room-service — it survived COVID because it's
genuinely cheaper than reprinting laminated cards every time onion prices move. It is also the single
highest-volume "why do I need a QR code?" search intent in the Indian SMB market. Today a restaurateur
evaluating Qravio finds no menu type and leaves.

**Every workaround we offer today is bad, and bad in an obvious way:**

| Today's workaround | Why it fails a restaurant |
|---|---|
| **`pdf` type** (the most common thing SMBs actually do) | A print-laid-out PDF on a 6" phone is pinch-and-zoom hell — the worst mobile reading experience we ship. Slow on 4G, no responsive reflow, and **editing one price means re-exporting and re-uploading the whole document**. |
| **`images` type** (photo of the paper menu) | Same pinch-zoom problem, plus unreadable at thumbnail scale, plus a re-shoot for every price change. |
| **`list_links`** | Models *links*, not priced items. No price field, no description, no category grouping, no photo per row. |
| **`business`** | A storefront card (hours, address, socials). No item/price model at all. |

None of these have a **category → item → price → image** model, which is the entire point. And none of
them deliver the actual value proposition of a *dynamic* QR to a restaurant: **the price on the poster
is a lie the moment it's printed, unless the QR is dynamic.** Menu is the type where "edit without
reprinting" stops being a feature bullet and becomes the reason to buy.

**Strategic framing — the bundle, not the type.** A menu QR on its own is a commodity; several
competitors ship one and a dozen Indian point solutions do too. The differentiation is the
**restaurant bundle**: `menu` (the thing on every table) + `review_funnel` (already shipped —
sentiment-gated Google review capture) + **WhatsApp review reminders** (gap-analysis item #1, the core
bet). One QR on the table drives the menu view *and* the review ask, with reminders closing the loop —
a package no global competitor assembles and no Indian point solution has the analytics for. This spec
is deliberately scoped to the **menu type only**; the bundle is packaging work that depends on item #1
landing. But we build the menu type knowing that's where it's going, and we do **not** compromise the
menu type to chase ordering revenue that would make us a competitor to the POS vendors instead of a
partner to the restaurant.

**It also unlocks the multilingual bet.** Gap-analysis item #3 (vernacular landing pages) explicitly
scopes itself to "the top 3 visitor-facing types (**menu**/business/vcard)". Menu is a prerequisite for
that differentiator, not an unrelated build.

## 3. Goals & Non-Goals

**Goals**
- A new **dynamic `menu` QR type** with a real data model: a menu → ordered **categories** → ordered
  **items** (`name`, `price`, `description`, optional `photo`, diet mark, availability).
- **Edit without reprint**: price/availability changes propagate to the edge through the normal
  KV-sync path within seconds. This is the headline value.
- **Fast on a bad 4G connection in a basement restaurant**: rendered from KV with no backend call, with
  a hard page-weight budget and lazily-loaded, server-downscaled item photos.
- **Three scan templates** (`classic`, `photo`, `accordion`), each mirrored by a React preview
  component (house rule — every Worker template ⇄ one React preview, shipped in the same PR).
- **Entry friction solved, not ignored**: nested drag-to-reorder editor + a client-side **paste-import**
  ("one dish per line") so a real 60-item menu is enterable in one sitting.
- **Ungated, all plans** — type is not a paywall lever (`0027`); the existing storage/QR/scan limits are
  the fences.
- **Availability toggle instead of deletion** — "Sold out" is a state a restaurant needs daily; deleting
  and re-adding a dish every evening is not a workflow.

**Non-Goals — and the reasoning, because this is the whole spec**

- **NEVER in-page ordering, cart, or checkout. Not in v1, not in v2, not behind a flag.** This is a hard
  product line, and here is exactly why:
  - **It forks us into a different business** — food-ordering and settlement — owned by POS-integrated
    incumbents (**Petpooja, DotPe, UrbanPiper**) who control the thing that actually matters: the
    **kitchen printer**. An order that doesn't reach the KOT is worse than no ordering at all, and we
    have no path to the kitchen.
  - **It drags in payments infrastructure we deliberately don't want**: Razorpay **Route** (or an equivalent
    split-settlement rail), **per-merchant KYC onboarding** for every restaurant, refund and chargeback
    operations, and settlement reconciliation — a support and compliance load an SMB SaaS team cannot
    absorb. This is the same reasoning that put "dynamic UPI collect QR + settlement" in the gap
    analysis' explicit **Skip** column.
  - **It attaches food-safety and consumer obligations we're not equipped for**: taking an order makes
    us part of the transaction, pulling in **FSSAI** menu-labelling expectations, price/tax
    correctness liability, and consumer-protection exposure on a per-plate basis. *Displaying* a menu
    the merchant authored carries none of that.
  - **It changes the buyer and the price point** — ordering platforms sell to operations teams at
    per-order commission, not to marketers at ₹399/mo. We'd be a worse product for a buyer we don't
    have, and lose the one we do.
  - **The differentiation is the bundle, not the ordering.** Menu + `review_funnel` + WhatsApp
    reminders wins the restaurant on *marketing*, which is our actual competence.
- **No cart-adjacent affordances either**: no "call the waiter", no table-number capture, no order
  notes, no "reserve a table", no delivery-partner deep links beyond a plain merchant-entered link.
  Each of these is the thin end of the same wedge and would be read as "ordering is coming".
- **No POS / inventory integration** (no Petpooja/PetPooja-style sync, no stock counts). Availability is
  a manual merchant toggle.
- **No per-item variants / modifiers / add-ons** in v1 (half-plate vs full-plate, size, extra cheese).
  This is genuine Indian-menu shape and it's the strongest candidate for v1.1 — but it is also the exact
  data model an ordering system needs, so we ship a single price plus an optional free-text price note
  and revisit deliberately (§11 Open Q1).
- **No nutrition / allergen / calorie certification.** Merchant-entered free text only, with no claim of
  accuracy by us. Diet marks (veg/non-veg/egg/vegan) are a merchant-set display attribute.
- **No menu-level multilingual** in v1 — that is gap-analysis item #3, a separate spec that will target
  `menu` first.
- **No per-item scan analytics** in v1 (which dishes were viewed/tapped). Attractive, but it needs an
  edge tracking route and an events schema; deferred (§7 Future).
- **No AI menu extraction** in v1 (photograph a paper menu → items). The `card_ocr` pattern makes this
  a natural v1.1, and it's noted as the eventual answer to entry friction — but v1 solves entry with a
  free, deterministic paste-import instead of a metered AI call.
- **No static menu QR.** A menu must be editable; a static QR encodes its target in the pixels and can
  never be updated. Dynamic-only, stated plainly in-product.

## 4. Target Users & Personas

| Persona | Who | Job-to-be-done | Today's pain |
|---|---|---|---|
| **Café / QSR owner ("Vikram")** | 1–2 outlets, 40–80 dishes, Pune/Indore | Put a scannable menu on every table and change prices without a reprint | Uploads a PDF; customers pinch-zoom; every price change is a re-export + re-upload |
| **Bar / specials-driven kitchen ("Nikhil")** | Menu changes weekly | Swap out specials and mark sold-out dishes daily | Reprints inserts, or the QR shows dishes the kitchen ran out of at 8pm |
| **Cloud kitchen operator ("Farah")** | Delivery-first, no dining room | A shareable menu link for WhatsApp/Instagram bio | Sends a PDF over WhatsApp that opens in a viewer app |
| **Hotel F&B / room service ("Ms. Rao")** | In-room card, multiple outlets | One printed card per room, several menus behind it | Reprinting 120 room cards for a price revision |
| **Agency / print shop ("Amit")** | Sets up QRs for restaurant clients | Build a client's menu once, hand over editing | Rebuilds a PDF for the client every month |

Primary buyer is the **owner-operator SMB restaurant** — price-sensitive, phone-first, allergic to
anything that takes an afternoon to set up. Secondary: **agencies and print shops** who set menus up on
behalf of restaurant clients and value handover.

## 5. User Stories

- As a **restaurant owner**, I want to enter my menu as categories and dishes with prices, so that
  customers see a real menu instead of a PDF they have to zoom into.
- As a **restaurant owner**, I want to change a price and have it live on the table tents immediately,
  so that I never reprint for a ₹10 revision.
- As a **kitchen manager**, I want to mark a dish "sold out" in two taps and un-mark it tomorrow, so
  that I don't have to delete and retype it every service.
- As an **owner with an 80-dish menu**, I want to paste my existing list and have it parsed into items,
  so that setting up doesn't take an afternoon of typing on a phone.
- As an **owner**, I want to drag categories and dishes into the order I actually serve them, so that
  the menu reads like my menu and not like the order I happened to type it in.
- As an **owner**, I want to add a photo to my signature dishes only, so that the page stays fast and
  the photos I do have are the good ones.
- As a **diner**, I want the menu to open in under two seconds on patchy restaurant Wi-Fi and be
  readable without zooming, so that I can order from the waiter without fighting my phone.
- As a **diner scanning a long menu**, I want to jump to "Desserts" without scrolling past 60 dishes,
  so that I find what I want quickly.
- As a **vegetarian diner in India**, I want the green/red diet marks I expect on a menu, so that I can
  scan the page the way I scan a paper menu.
- As an **agency**, I want to build the menu for a client and hand over editing rights, so that they
  maintain prices themselves afterwards.

## 6. UX / Product Flow

**6.1 Type selection**
`Menu` appears in the QR type picker as a dynamic type for **every** plan (no lock chip). Copy leads
with the dynamic value: *"A live menu customers can read on their phone — change prices without
reprinting."* Static is not offered for this type; the picker states dynamic-only inline.

**6.2 Building the menu (builder Step 1, content)**
1. **Menu header**: menu name/heading, an optional short note ("All prices in ₹, taxes extra"), and a
   **currency selector** (defaults to the workspace's inferred currency — ₹ for India). Currency is set
   **once per menu**, not per item.
2. **Categories**: an ordered list ("Starters", "Main Course", "Breads", "Desserts"). Each has a name,
   an optional one-line description, a drag handle, a collapse toggle, and a delete action (with a
   confirm, since deleting a category deletes its dishes).
3. **Items inside a category**: name, **price**, optional description, optional **photo**, an optional
   **diet mark** (veg / non-veg / egg / vegan), an **available** toggle, and an optional free-text
   **price note** for cases a single price doesn't cover ("half / full", "market price").
4. **Reordering**: drag to reorder **categories** among themselves and **items within their category**
   (nested dnd-kit, modelled on the existing `list_links` editor). Moving a dish to a *different*
   category is a **"Move to…" menu** on the item rather than a cross-list drag (§11 Open Q2).
5. **Paste-import**: a "Paste your menu" affordance parses pasted text client-side —
   `Dish name | 250 | short description` per line, with `## Category` lines starting a new category —
   into editable rows. **Nothing is saved until the user reviews and saves**, exactly like the OCR
   confirm-before-save rule. Purely client-side: no upload, no backend endpoint, no AI cost.
6. **Empty and long states**: a starter skeleton (three sample categories) on a brand-new menu; a
   visible item counter with the cap ("62 / 300 items") once a menu gets large.

**6.3 Choosing a look (builder Step 3, page design)**
Three templates, previewed live in `MobilePreview`:
- **Classic** *(default)* — text-first, category headings, dotted price leaders. Fastest, works with
  zero photos, closest to a printed menu. This is the right default for the typical Indian menu with
  60+ dishes and no photography.
- **Photo** — two-column dish cards with images. For cafés/dessert-led menus with real photography.
- **Accordion** — collapsed categories plus a sticky category jump-nav. For long, multi-section menus
  (hotel room service, multi-cuisine).
Theme colour, page title, and logo ride the **existing** page-design controls — no new design surface.

**6.4 Scanner experience (the edge)**
- Scan → the Worker renders the menu **entirely from the KV snapshot**: no backend call, no framework,
  no external fonts, images lazy-loaded with reserved aspect boxes (no layout shift).
- **Sold-out items** render greyed with a "Sold out" chip rather than disappearing — the diner sees the
  dish exists, which is what a paper menu does.
- **Diet marks** render as the standard green/red square glyphs Indian diners already parse.
- Prices are formatted from a stored integer minor unit + the menu currency — never a float, never a
  locale guess at the edge.
- White-label / brand entitlements apply exactly as on every other landing page; a Free-plan menu
  carries the same footer every other Free landing page carries.
- **No interactive elements beyond navigation.** No buttons that look like they add anything to
  anything.

**6.5 Day-two editing**
Editing a menu is the same builder in edit mode. Because the common day-two action is "mark two dishes
sold out", the QR detail page surfaces a direct **"Edit menu"** entry point and the item availability
toggles are reachable without walking the whole wizard.

## 7. Scope

**In scope (v1)**
- New dynamic type `menu`, appended to `dynamic_qr_types` on **all four** non-custom plans.
- Data model: one menu header row per QR, ordered categories, ordered items with
  `name / price / description / photo / diet / availability / price note`.
- Item photos via the **existing** Supabase Storage upload path, server-downscaled, counted against the
  workspace's existing storage quota. No new quota key.
- KV snapshot of the whole menu (bounded by explicit caps) so the scan path makes **zero** backend calls.
- Worker `src/pages/menu/` dispatcher + **three** templates; **three** mirrored React preview components;
  `TemplatePicker` / `PagePreview` cases; `page-templates.ts` entries.
- Nested dnd-kit category/item editor, "Move to…" cross-category action, client-side paste-import.
- Explicit size caps (categories, items, description length, photo size) enforced **server-side**.
- Ungated; no new plan flag; no `FEATURE_ENFORCEMENT` change.

**Out of scope / Future**
- **Ordering, cart, checkout, payments, table routing, POS/KOT** — *permanently out*, see §3.
- **Per-item variants / modifiers** (half/full, sizes, add-ons) — strongest v1.1 candidate (§11 Open Q1).
- **AI menu extraction** (photo of a paper menu → items) reusing the shipped `card_ocr` pattern — the
  eventual answer to entry friction; deferred so v1 carries no AI cost.
- **CSV/Excel bulk import + export** — paste-import covers the common case; a file importer is future.
- **Per-item view/tap analytics** ("which dishes get looked at") — needs an edge route and event schema.
- **Multilingual menus** — gap-analysis item #3, separate spec, `menu` is its first target.
- **Multi-menu per QR** (breakfast / lunch / bar menu behind one code, or time-of-day switching) —
  future; note this overlaps the routing-rules "time" dimension.
- **Scheduled menu changes** (happy-hour pricing) — composes with QR expiry/scheduling, separate spec.
- **Diner-facing search/filter** on the scan page — accordion jump-nav covers v1 navigation.
- **"Restaurant bundle" packaging** (menu + review funnel + WhatsApp reminders as a purchasable bundle)
  — depends on gap-analysis item #1; a packaging/pricing exercise, not this spec.

## 8. Pricing & Packaging

| Surface | Tier | Flag / Limit |
|---|---|---|
| `menu` QR type | **All plans (Free, Starter, Pro, Agency)** | `dynamic_qr_types` membership (seeded by this feature's migration) |
| Item photos | All plans | **Existing** workspace storage quota + existing per-file size limit — no new key |
| Menu size caps | All plans | Fixed product caps (categories / items / description length), not plan-tiered |

**Why ungated.** Migration `0027_open_all_qr_types.sql` made the house position explicit: *"QR type is
no longer a paywall lever… the real fences (max_qr, max_scans, analytics retention, custom domains,
white-label, branding, bulk, api, seats) are UNCHANGED and enforced independently."* Gating the menu
type would contradict that two migrations later, and worse, it would gate the *acquisition* type for
the vertical we're trying to enter — a Free restaurateur who builds a menu and prints table tents is
exactly the user who then needs a custom domain, white-label, and more scans. The upgrade pressure
comes from **scan volume and white-label**, both of which a real restaurant hits fast, not from
withholding the type.

**Why the caps aren't plan-tiered.** A 300-item cap is a *technical* bound (KV payload + edge render
cost), not a monetisation lever, and tiering it would create the exact support conversation we don't
want ("my menu is 40 items, why is it cut off?"). It is set high enough that no honest restaurant menu
hits it.

**Where the money actually is.** The menu type drives Free→Starter/Pro through: **scan volume** (a
table-tent menu is the highest-scan-per-QR use case we have, and it hits `max_scans` faster than any
other type), **white-label** (restaurants hate a competitor's footer on their menu), **custom domain**
(`menu.restaurantname.com` on a table tent), and eventually the **restaurant bundle** with review
funnel + WhatsApp reminders, which is where a genuinely higher price point lives.

**No new flag, deliberately.** Following the `review_funnel` precedent, gating by `dynamic_qr_types`
membership means `FEATURE_ENFORCEMENT` is untouched and `test_feature_gate_coverage` cannot break.

## 9. Success Metrics & KPIs

**Adoption (does the vertical actually land)**
- `menu` becomes a **top-5 created dynamic type** within 90 days of GA.
- ≥ **60%** of started menus reach a **published** state (built ≥ 1 category with ≥ 3 items and saved) —
  the abandonment rate on data entry is the honest read on whether entry friction is solved.
- **Median time from type-selection to first save for a ≥ 20-item menu < 15 minutes**, with
  paste-import used in ≥ 40% of those builds.

**Proving the dynamic value (the actual pitch)**
- ≥ **40%** of published menus are **edited within 30 days** — if merchants never edit, they'd have been
  fine with a PDF and the type isn't earning its build.
- Median **price-change-to-live latency** measured in seconds (KV propagation), not reprints.

**Scan-side quality (a slow menu is a dead menu)**
- **p75 LCP < 2.5s** on a throttled 4G profile for a 60-item menu with 10 photos; **p75 < 1.5s** for a
  photo-free `classic` menu.
- Menu page transfer weight budget: **< 150 KB** of HTML for a 300-item menu (photos excluded, lazy).
- **Zero** scan-path backend calls for a menu render (KV-only invariant, asserted in Worker tests).

**Bundle signal (the strategic thesis)**
- **% of menu-creating workspaces that also create a `review_funnel` QR within 60 days** — the leading
  indicator that the restaurant bundle is real. Tracked from day one even though the bundle isn't
  packaged yet.

**Invariants**
- **0** ordering/cart/checkout surfaces shipped. Non-negotiable, and a review checklist item on every
  PR touching `src/pages/menu/`.
- **0** menus rendered with a price the merchant didn't set (minor-unit/currency correctness).

## 10. Rollout Plan

**Phase 0 — Backend + edge (internal).**
Migration (detail tables + `dynamic_qr_types` seed). Type literal, Pydantic models, create/update
write path, `build_kv_content` branch, `/internal/menu/{qr_id}` fallback. Worker `src/pages/menu/`
dispatcher + the `classic` template. Deploy Worker to **staging**; verify a hand-seeded menu renders
from KV with no backend call, caps are enforced, sold-out items render correctly, and prices format
from minor units.

**Phase 1 — Builder + templates (closed).**
Nested category/item editor, photo upload, paste-import, all three templates plus their three mirrored
React previews, `TemplatePicker`/`PagePreview` cases. Internal plus a handful of design-partner
restaurants (ideally one 60+ item menu and one photo-led café menu — the two failure shapes).
- **Acceptance:** a partner builds a real 40+ item menu in one sitting without support; reorder,
  sold-out toggle, and photo upload all work on a phone; a price edit is live at the edge within
  seconds; the `classic` template hits the LCP budget on 4G; each Worker template is pixel-consistent
  with its React preview.

**Phase 2 — GA.**
Remove the FE flag; **`npm run deploy:prod`** the Worker; add the type to the marketing type list and
ship the `/restaurant-menu-qr-code` SEO page (this is a high-intent India query and the type is an SEO
asset in its own right); help-centre entry covering paste-import and sold-out.

**Cross-service gates:**
- **Worker change → `npm run deploy:prod` is required** (new type dispatch + templates). Deploy order:
  migration → backend (so KV carries `menu` content) → Worker. A Worker deployed early would fall
  through to the error page for a type nothing has created yet — safe, but order it anyway.
- **No email** in v1 → the unpublished `_dmarc.qravio.app` record is **not** a gate.
- **No cron**, **no AI**, **no new external service** → no `wrangler.toml` change beyond nothing, and no
  new secret to provision.

## 11. Risks, Edge Cases & Open Questions

**R1 — KV payload size and edge render cost (the #1 technical risk).** A menu is by far the largest
`content` blob we'd put in KV: 300 items × (name + description + photo URL + price) is orders of
magnitude bigger than a vCard. Every scan reads and `JSON.parse`s the whole entry. **Mitigation:** hard
server-side caps (categories, items, description length), photos stored as **URLs never inlined**, an
explicit HTML weight budget, and a Worker test that renders a max-size fixture and asserts the budget.
The caps are enforced at the API, not just the UI.

**R2 — Photos are the page-weight and storage risk.** Restaurant photos are phone photos: 4 MB, 4000px.
Unbounded, they'd blow both the storage quota and the LCP budget. **Mitigation:** server-side downscale
on upload (as the OCR path already does for a different reason), lazy loading with reserved aspect
boxes at the edge, and photos counted against the **existing** workspace storage quota so there's a real
ceiling. Photos are optional everywhere; `classic` needs none.

**R3 — Data-entry friction is the real adoption risk, not rendering.** The build is easy; getting an
80-dish menu *into* it is where merchants quit. **Mitigation:** paste-import in v1 (client-side, free,
deterministic), nested drag reorder so mistakes are cheap to fix, and AI menu extraction as the
explicit v1.1 upgrade path reusing the shipped `card_ocr` pattern. This risk is why entry-flow metrics
(§9) are first-class KPIs, not vanity.

**R4 — Scope creep toward ordering (the strategic risk).** Every restaurant that adopts this will ask
for ordering within a month, and the ask will be persuasive. **Mitigation:** §3 states the reasoning in
full so the answer is a decision, not a debate; no cart-adjacent affordances ship (not even "call
waiter"); and the counter-offer is the **bundle** — reviews and reminders — which is revenue we can
actually serve. Treat a PR that adds an order-shaped affordance to `src/pages/menu/` as a spec
violation.

**R5 — Price correctness.** Floats and currency guessing are how you show a customer the wrong price.
**Mitigation:** prices stored as **integer minor units** with a **menu-level currency code**; formatting
happens from those two values in both the Worker and the React preview via one shared rule; never a
locale-inferred format at the edge; and a rounding test as a release gate.

**R6 — Worker ⇄ React template drift (a known house pain point).** Three templates × two
implementations = six artefacts to keep in sync, on the type with the most complex markup we've built.
**Mitigation:** keep the DOM deliberately simple (no clever layout that's hard to mirror), drive both
sides from the **same fixture menu** in tests, and treat "Worker template without a React mirror" as a
blocking review item per the house rule.

**R7 — Sold-out is a daily workflow, and if it's slow it won't be used.** A manager marking four dishes
sold out at 8pm should not walk a 4-step wizard. **Mitigation:** availability toggles reachable directly
from the QR detail/edit entry point; the toggle is a normal update that re-syncs KV.

**R8 — Diet marks and allergen claims.** Veg/non-veg marking is culturally load-bearing in India and
getting it wrong is a real harm, but we have no way to verify a merchant's data. **Mitigation:** diet
marks are explicitly **merchant-declared display attributes**; the builder says so; we make no accuracy
claim; allergen information is free text with no certification framing. (FSSAI's marking mandates
attach to packaged-food labelling, not to a merchant's own display menu — and we are not the food
business operator. Displaying is not ordering; that distinction is also what keeps §3's line clean.)

**R9 — Deleting a category deletes its dishes.** An accidental delete on a phone destroys work.
**Mitigation:** confirm dialog naming the item count; deletion isn't committed until save; a menu is
never left empty by a partial save (see the TRD's write-ordering rule).

**R10 — Migration slot collision.** Several specs in this batch reserve slots ahead of disk.
**Mitigation:** the TRD pins a provisional slot and requires an `ls migrations/` check immediately
before applying.

**Open Questions**
1. **Per-item variants (half/full, sizes) in v1 or v1.1?** *Recommend v1.1.* Half/full is real Indian
   menu shape, but it's also precisely the variant/modifier model an ordering system needs, and a third
   nesting level would double the editor's complexity. v1 ships one price plus an optional free-text
   price note ("half ₹120 / full ₹200"), which covers the case visually; if support volume says
   otherwise, add a variants table in v1.1.
2. **Cross-category drag, or a "Move to…" menu?** *Recommend "Move to…" in v1.* Multi-container dnd-kit
   dragging is the classic source of janky mobile reordering, and this editor is used on a phone.
   Within-list drag (both levels) plus an explicit move action is more reliable and much cheaper.
3. **Paste-import in v1, or defer to Phase 2?** *Recommend v1.* It is client-side only (zero backend
   surface) and it is the difference between a merchant finishing and abandoning. Ship it with the
   builder, not after.
4. **Is `classic` the right default template?** *Recommend yes* — most Indian menus have no photography,
   and defaulting to a photo grid makes an empty-state menu look broken.
5. **Should the scan page show a "menu last updated" stamp?** *Recommend yes, subtly* — it's a cheap
   trust signal for a diner and reinforces the dynamic value. Confirm it doesn't read as staleness on a
   menu that legitimately hasn't changed in months.
6. **Multi-menu per QR (breakfast/lunch/bar) in v1?** *Recommend no* — one menu per QR keeps the model
   and the KV payload honest; a restaurant needing three menus makes three QRs (which is also more
   scans, and more accurate analytics).

## 12. Dependencies

- **New-dynamic-QR-type pipeline (shipped precedent):** `review_funnel` (`GOOGLE_REVIEW_FUNNEL_QR_TRD.md`,
  migration `0021`) is the end-to-end recipe — type literal, detail table, `build_kv_content` branch,
  `dynamic_qr_types` seed, Worker dispatch, React preview, picker cases.
- **Type gating posture (shipped):** `qr_backend/migrations/0027_open_all_qr_types.sql` — types are open
  to all plans; `menu` is appended to the canonical arrays, never to an empty list (the gate is
  fail-open on an empty list).
- **Nested drag-drop editor (shipped):** the dnd-kit pattern in
  `qr_frontend/src/components/qr-generator/content-types/ListLinksContent.tsx` — the menu editor is that
  pattern with one more level of nesting.
- **Multi-template Worker dispatcher (shipped):** `qr_cf_code/src/pages/vcard/index.js` and
  `src/pages/pdf/index.js` — `page_design.templateId` → template module.
- **Image upload + storage quota (shipped):** the Supabase Storage upload path used by the `images`
  type, plus the existing per-file size limit and workspace storage quota.
- **KV sync (shipped):** `build_kv_content` / `write_to_kv` / `sync_qr_to_kv` in
  `qr_backend/src/utilities/cloudflare_kv.py`.
- **Migration mechanism (shipped):** hand-applied SQL in `qr_backend/migrations/`; provisional slot **`0041`**
  (highest on disk = `0032`; `0033`–`0040` reserved by sibling specs) — re-verify before applying.
- **Strategic (not blocking):** gap-analysis item **#1** (WhatsApp review reminders) for the restaurant
  bundle. Neither gates this spec.
- **Item #3 (multilingual landing pages) — a shape obligation, not a dependency.** That spec scopes its
  v1 to `vcard` + `business` *only because `menu` doesn't exist yet*, and a vernacular menu is the
  highest-value multilingual surface in the product. Menu v1 ships **English-only**, but its scan
  templates (and their React mirrors) must be built **i18n-native from the first commit** — no
  hardcoded chrome strings, one trailing optional `i18n` argument. That costs a line per template now
  and a full pass over six files later. TRD §4.5 carries the contract. Menu v1 does **not** wait on
  migration `0042` or any multilingual code landing.
- **No AI, no email, no cron, no new external service, no new secret.**

### Appendix — Key Files

| Concern | File |
|---|---|
| Migration (detail tables + type seed) | `qr_backend/migrations/0041_restaurant_menu_qr.sql` (NEW — `qr_menus`, `qr_menu_categories`, `qr_menu_items` + `dynamic_qr_types` append; slot **provisional**, re-check `ls migrations/` before applying) |
| Type literal, models, create/update write path | `qr_backend/src/api/routes/qr.py` (type `Literal` list; per-type content models; detail-table upsert; `SELECT_WITH_RELATIONS`) |
| KV snapshot | `qr_backend/src/utilities/cloudflare_kv.py` (`build_kv_content` — new `menu` branch) |
| Worker fallback endpoint | `qr_backend/src/api/routes/internal.py` (`/internal/menu/{qr_id}`) |
| Image upload | `qr_backend/src/api/routes/storage.py` (existing path; server-side downscale) |
| Type gating seed reference | `qr_backend/migrations/0027_open_all_qr_types.sql` (canonical `dynamic_qr_types` arrays) |
| Worker dispatch | `qr_cf_code/src/handlers/qrRouter.js` (new `menu` case) |
| Worker templates | `qr_cf_code/src/pages/menu/` (NEW — `index.js` dispatcher + `classic`/`photo`/`accordion` templates) |
| Builder editor | `qr_frontend/src/components/qr-generator/content-types/` (NEW nested category/item editor, dnd-kit) |
| React previews (house mirroring rule) | `qr_frontend/src/components/qr-generator/templates/menu/` (NEW — one per Worker template) |
| Template registry + picker | `qr_frontend/src/lib/constants/page-templates.ts`, `TemplatePicker.tsx`, `PagePreview` |
| Type registry | `qr_frontend/src/lib/constants/qr-types.ts` (new `menu` tile) |
| Price/currency formatting | shared rule used by both the Worker template and the React preview (integer minor units + menu currency) |
