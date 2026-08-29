# PRD — QR templates by industry

**Status:** Draft (detailed) · **Author:** Product · **Date:** 2026-08-28
**Priority:** **Activation**, not feature parity. Six of twelve real users have never created a QR (`dormant-user-outreach`, 2026-08-05). The blank builder asks a taxonomy question the new user is not equipped to answer.
**Tiers:** **All plans, ungated.** Packs are *filtered* to what the workspace can actually create — a starter pack that leads to a 403 is worse than no starter pack.
**Plan flags:** none new. Visibility reuses the `dynamic_qr_types` / `lead_forms` checks the type picker already performs, including their fail-open behaviour.
**Split from:** the existing `/[slug]/templates` page (Design Templates / QR Types / Page Templates) and the builder's existing deep-link contract.
**Repos:** `qr_frontend` only. No backend, no Worker, no migration, no KV change.

---

## 1. TL;DR / Summary

**Industry packs** are pre-assembled starting points named after *what the customer is*, not what
our system has: Restaurant, Salon, Retail shop, Clinic, Real estate, Gym, Event, Freelancer,
Product/Packaging, Reviews.

Choosing one opens the builder with the QR type chosen, the page template applied, the design
template applied, and the content fields pre-populated with realistic industry placeholder copy the
user edits rather than invents.

Implementation is small because the builder **already** accepts `?type=`, `?pageTemplate=`,
`?designTemplate=` and `?source=` deep links. A pack is a named bundle of those plus a content
skeleton.

## 2. Problem & Motivation

### 2.1 Our templates are organised by our taxonomy, and a new user does not have it

The Templates page has three tabs, each grouping by an axis the customer does not think in:

| Tab | Grouped by | Categories |
|---|---|---|
| **Design Templates** | *Aesthetic* | `minimal`, `bold`, `colorful`, `corporate`, `rounded`, `dark` |
| **QR Types** | *Mechanism* | `website`, `vcard_plus`, `pdf`, `menu`, `business`, … (Dynamic / Static filter) |
| **Page Templates** | *Per-type variants* | Only reachable **after** the type decision |

A salon owner does not think "I want bold". A clinic owner does not know whether they want
`business` or `vcard_plus` — and that is the **hardest and most consequential decision in the
funnel**, because everything downstream depends on it and it is effectively irreversible without
starting over.

None of the three tabs answers *"I run a salon; what should I make?"* — which is the actual first
question.

### 2.2 The one industry-shaped thing we have is on the wrong surface

`LANDING_PAGE_TEMPLATES` (`lib/constants/templates.ts`) does carry industry-flavoured categories —
`restaurant`, and a full "Modern Restaurant" preview with menu sections and sample dishes. But it
belongs to the **landing-page builder**, a different surface from the QR builder. The right idea
already exists in the codebase, aimed at the wrong funnel.

### 2.3 The evidence

Half our real users signed up, saw a grid of fourteen mechanism names, and left without creating a
QR. A pack converts a taxonomy question into a **self-recognition** question, which people answer
instantly and correctly.

### 2.4 Secondary benefit, deliberately out of scope

Industry packs are a natural public surface ("QR codes for restaurants") for a content programme
whose measured bottleneck is authority rather than volume. Not in this spec — but the constants are
shaped so marketing can import them later without forking the list (§12 Q2).

## 3. Goals & Non-Goals

### Goals

- **G1.** 8–10 packs covering the realistic Indian SMB spread.
- **G2.** Each pack: a QR type, a page template, a design template, and **realistic placeholder
  content** — not lorem ipsum, and not empty fields.
- **G3.** Reachable from the three places the decision is actually made: the QR list **empty state**,
  the **top of the builder's type step**, and the **Templates page**.
- **G4.** Land the user in the builder with everything applied and the first editable field focused.
- **G5.** **Only show packs the workspace can build**, failing open during a subscription outage.
- **G6.** Placeholder content is **visibly** placeholder, one-press clearable, and warned about at
  save time.

### Non-Goals

- **NG1 — no new backend "pack" entity.** Packs are frontend constants. A database object means a
  CMS, an admin surface and a migration for a list that changes twice a year.
- **NG2 — no AI-generated per-business content** in v1. Different feature, per-use COGS, review
  requirement.
- **NG3 — no industry field on the workspace and no onboarding questionnaire.** Do not make people
  declare an identity to see a grid; let them recognise themselves in it.
- **NG4 — no replacement of the existing three tabs.** They serve users who already know what they
  want, and they are correct for that audience.
- **NG5 — no fourth tab.** The industry axis **cross-cuts** the aesthetic one; adding a fourth tab
  to a page whose job is "pick a starting point" is itself a taxonomy problem. §5.3.
- **NG6 — no per-industry pricing, gating or bundling.**

## 4. Personas & user stories

**Kavita — salon owner, day one, Free plan**
> *I pick "Salon". Thirty seconds later I'm editing a booking-link page with my own salon's name in
> it, instead of choosing between fourteen QR types I don't understand.*

**Ravi — restaurant owner**
> *"Restaurant" gives me the menu QR with categories and sample items already structured. I fill in
> my dishes rather than designing a schema.*

**Meera — experienced user, third QR**
> *The packs are visible, skippable, and never in my way. The row stays collapsed after I collapse
> it.*

**A user who does not fit any pack**
> *The normal type grid is right there, unchanged. Nothing is hidden behind a pack.*

## 5. UX

### 5.1 Where packs appear, in decision order

1. **QR list empty state** — the highest-leverage spot, and precisely where the dormant users
   stopped. "Start from your industry", above the current empty state.
2. **Builder, step 1** — a pack row above the type grid, collapsible, collapsed state remembered.
3. **Templates page** — as an **"Industry" filter on the existing Design Templates tab** (§5.3).

### 5.2 The pack card

Industry name · icon · one line of what it makes ("Menu QR with a digital menu page") · a small
preview thumbnail · **the QR type as a secondary label**.

That last element is deliberate: the user learns our vocabulary by association ("Salon → Business
QR") rather than being tested on it up front. Over a few sessions they graduate to the type grid.

### 5.3 Why a filter, not a tab (NG5)

Design Templates already filters by aesthetic. Industry is orthogonal — a restaurant might want
`bold` or `minimal` — so it belongs as a second filter dimension, not a sibling tab. Four tabs on a
"pick a starting point" page reproduces exactly the problem §2.1 describes.

### 5.4 After selection

The builder opens at the type-selected step with a dismissible note:

> **"Started from the Restaurant pack — everything here is editable."**

Every prefilled field is **visibly placeholder** (muted styling plus a small "sample" affordance),
and a **Clear sample content** action sits in the pack banner.

### 5.5 Locked types

A pack whose type the plan does not allow is **hidden**, not shown-and-locked. An upsell placed in
the activation flow of a user who has never succeeded once is the wrong trade — and since `0027`
opened all thirteen creatable types to every plan, the affected set is small (effectively
`lead_form` only).

## 6. The packs

Initial set, to be validated against actual signup distribution (§10):

| Pack | QR type | Why this type |
|---|---|---|
| Restaurant / Café | `menu` | The flagship SMB use case; the type with the highest data-entry cost |
| Salon / Spa | `business` | Services, hours, booking link, directions |
| Retail shop | `business` | Hours, location, catalogue link, socials |
| Clinic / Doctor | `business` | Directions, hours, appointment link |
| Real estate | `pdf` | Property brochure behind a scannable sign |
| Gym / Fitness | `list_links` | Schedule, membership, socials in one page |
| Event | `event` | Date, venue, directions, calendar add |
| Freelancer / Consultant | `vcard_plus` | Digital business card |
| Product / Packaging | `website` | Product page; pairs naturally with UTMs once those ship |
| Reviews | `review_funnel` | Highest-ROI type we have, and the least discoverable |

**The `review_funnel` entry earns its place.** It is genuinely valuable and nobody finds it by
browsing a type grid, because its name describes a mechanism rather than an outcome. "Reviews" is
what the customer is looking for.

## 7. Gating

Ungated. This is activation. Filter by entitlement (§5.5) rather than tease.

## 8. Edge cases

| # | Case | Behaviour |
|---|---|---|
| E1 | Unknown `?pack=` id (stale link in an email) | **Ignore silently**, render the normal builder. Never an error page. Matches the existing "template may have been deleted" precedent in the builder's deep-link effect. |
| E2 | Pack's type not entitled | Pack hidden in the picker; if reached by URL, fall back to the normal builder with the type unset |
| E3 | Subscription query loading or errored | **Show all packs** (fail open), matching `QRTypeSelector` and `QRTypesTab` |
| E4 | Pack references a deleted page/design template | Caught in CI by the referential-integrity test (TRD §6), never reaches a user |
| E5 | User applies a pack, then changes the type | Sample content for the old type is cleared; do not carry it across types |
| E6 | User publishes without editing anything | Save-time warning (§9 / TRD §4), not a block |
| E7 | Workspace already has a saved design template | §12 Q1 — proposal: do not override it |
| E8 | `localStorage` unavailable (private window) | Row renders expanded; every access wrapped in try/catch |

## 9. Sample-content safety — the top risk

Publishing "Bella Cucina" for a business in Pune is the failure that damages a real customer, so
three independent layers:

1. **Visual** — prefilled fields render with placeholder treatment, distinguishable from typed values.
2. **Action** — **Clear sample content** wipes every untouched prefilled field in one press.
3. **Save-time guard** — before the create mutation, compare current content against the pack's
   sample. If any user-visible string is still byte-identical, confirm: *"Some sample text hasn't
   been changed — publish anyway?"* **Warn, do not block** — some sample values (a heading like
   "Our Menu") are legitimately correct as-is.

Track which fields the user *touched* rather than diffing everything, so an intentionally-kept
heading does not nag on every save.

## 10. Success metrics

| Metric | Why | Healthy |
|---|---|---|
| **First-QR completion rate for new workspaces, pack-started vs blank-started** | **This is the number.** §2.3 is the entire justification | Materially higher for pack-started |
| Pack selection distribution | Tells us which industries we actually serve; drives the §6 list | — |
| Share of pack-started QRs published with **unedited** sample content | Failure signal; triggers stronger placeholder treatment | Low |
| Time from signup to first published QR | | Falling |
| Pack row collapse rate among repeat users | Is it in the way? | Collapse-and-stay is fine |

## 11. Risks

| Risk | Severity | Mitigation |
|---|---|---|
| **Sample content published verbatim to a real customer-facing page** | **High** | Three layers, §9. |
| Packs go stale as types and templates evolve | High | A test asserting every pack's `qrType` ∈ `ALL_TYPES`, every `pageTemplateId` ∈ `getTemplatesForType(qrType)`, every `designTemplateId` ∈ `SYSTEM_TEMPLATES`. A pack pointing at a deleted template fails CI, not a user. |
| Ten packs is just another grid — the same problem again | Medium | Ten self-recognised labels ≠ fourteen mechanism names. Keep it ≤10; if a pack cannot be recognised in one word, cut it. |
| We guess the wrong industries | Low | It is a constants file. Change it in an afternoon once §10's distribution has data. |
| Entitlement filtering hides packs during an outage | Medium | Fail open on loading and error (E3), with a test for each state. |
| Content authoring is under-budgeted | Medium | §13 — this is a writing task, not a coding task, and it is the larger half of the work. |

## 12. Open questions

1. **Does a pack apply a design template too?** Applying one makes the result feel finished; it also
   overrides a workspace's saved brand template. **Proposal: apply the pack design only when the
   workspace has no saved design template** (E7).
2. **Should packs be shared with the marketing site** for "QR codes for restaurants" pages? The
   constants are shaped to allow it (§2.4). Sequencing is a separate call — but do not fork the list
   when it happens.
3. **Should the chosen industry be remembered** on the workspace to bias later defaults? That is an
   onboarding-state question and belongs with `ONBOARDING_TOOLTIPS`, which faces the same
   `localStorage`-vs-server decision.

## 13. Note on effort

**The code is the small half.** Ten packs × realistic copy for every field of the chosen type is a
writing task, and it must be written by someone who knows Indian SMB vocabulary. Placeholder copy
that reads as American SaaS defeats the recognition the packs exist to create — "Bella Cucina" is
exactly the wrong register for the market this is aimed at. Budget it explicitly.
