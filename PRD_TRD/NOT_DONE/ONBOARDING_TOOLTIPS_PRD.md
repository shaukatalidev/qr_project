# PRD — Onboarding tooltips

**Status:** Draft (detailed) · **Author:** Product · **Date:** 2026-08-28
**Priority:** Activation and paid-feature discovery. Same root cause as the industry packs — users do not know what the interface offers — but aimed at the sessions *after* the first, where packs cannot help.
**Tiers:** **All plans, ungated.** Teaching the product is not a premium tier, and the users who most need it are the ones least likely to pay before they understand it.
**Plan flags:** none.
**Split from:** the existing `/[slug]/help` route and the marketing `HelpContent.tsx`. Those answer questions people already know to ask; this surfaces capabilities they do not know exist.
**Repos:** `qr_frontend` only. No backend in v1, no Worker, no migration, no third-party script.

---

## 1. TL;DR / Summary

Two mechanisms, deliberately separate:

1. **Persistent explainers** — a small info affordance beside genuinely non-obvious controls,
   opening a one-sentence explanation on hover (pointer devices) **or tap** (touch). Always
   available, never dismissed, no state.
2. **A short first-run tour** — 4–6 sequential coach marks on the first visit to the QR list and
   the first visit to the builder. Skippable at any point, never repeated.

v1 stores "seen" state in `localStorage` and ships **zero backend**. Cross-device persistence is a
v2 with one table, decided from a metric rather than up front.

## 2. Problem & Motivation

### 2.1 The product has grown faster than its explanations

A single QR detail page now carries cards for: A/B testing, routing rules, tags, conversion
tracking, review-funnel stats, reminder settings, languages, password protection, scheduling,
retargeting pixels, and a feature-lock group. Every one has a title. Almost none says what it is
*for*.

### 2.2 Two asymmetric consequences, both bad

**Paying customers do not use what they pay for.** `advanced_analytics`, `routing_rules`,
`ab_testing`, `review_reminders`, `outbound_webhooks` and `api_access` are all Pro+ flags. A Pro
customer who never discovers routing rules is a churn risk who believes they are paying for a QR
generator. We are charging for capability we do not explain.

**New users do not finish.** Half our real users have never created a QR. Each of the builder's
four steps contains a decision with no stated consequence — "Page Design" does not explain that it
applies only to some types, and **Dynamic vs Static** is the single most consequential and least
reversible choice in the product, presented as two words.

### 2.3 What exists does not cover it, and the "tooltips" we have are not tooltips

- There is a `/help` route and marketing `HelpContent`. Both answer questions someone already
  knows to ask.
- **`@radix-ui/react-tooltip` is not installed.** Fourteen Radix packages are (accordion, checkbox,
  dialog, dropdown-menu, label, popover, progress, select, separator, slider, slot, switch, tabs,
  toast) — tooltip is not among them. Every `Tooltip` in the analytics components is **Recharts'
  chart tooltip**, which explains a data point, not a feature.
- **27 files use the native `title="…"` attribute** as an ad-hoc tooltip (`title="Edit"`,
  `title="Delete"`). Those are hover-only, unstyled, slow to appear, inconsistent across browsers,
  and **completely invisible on touch devices** — which is where a large share of our users are.

So there is no explainer pattern to extend. There is no onboarding state, no tour, and no first-run
experience anywhere in the codebase.

### 2.4 Why adjacency, not documentation

The gap is not "I could not find the manual". It is **"I did not know there was anything to look
up."** No amount of documentation fixes that, because it requires the user to already suspect the
feature exists. Explanation has to sit next to the control.

## 3. Goals & Non-Goals

### Goals

- **G1.** One **reusable explainer component**, used consistently — one icon, one position, one
  interaction, one voice — so the pattern becomes recognisable rather than ad hoc.
- **G2.** Cover the ~20 controls that are genuinely non-obvious (§6), chosen by evidence. **Not**
  every control.
- **G3.** A first-run tour on **two** surfaces only: the QR list and the builder. 4–6 steps each.
- **G4.** **Touch-first.** An explainer that only works on hover does not exist for most of our
  users. Tap to open, tap outside to close.
- **G5.** **Accessible.** Keyboard reachable, screen-reader announced, `Escape` closes, focus
  returns to the trigger.
- **G6.** **Never block.** No modal that must be dismissed before working; no focus trap; the tour
  is skippable in one press at every step.
- **G7.** One sentence per explainer. If it needs a paragraph, it needs a help article and the
  explainer should link to it.
- **G8.** Replace the 27 native `title=` usages where they are doing explanatory work, so the
  product has one tooltip behaviour rather than two.

### Non-Goals

- **NG1 — no product-tour SaaS** (Appcues, Pendo, Intercom). A third-party script on an
  authenticated dashboard is a data-sharing decision, a CSP change and a recurring cost — for a
  five-step tour we can write in an afternoon.
- **NG2 — no interactive checklists or gamified onboarding** ("3 of 5 steps complete"). Different
  feature, and it needs server state to be honest across devices.
- **NG3 — no explainers on obvious controls.** "Delete — deletes this QR" trains people to ignore
  the icon, which destroys the value of the ones that matter. This is the main way features like
  this fail.
- **NG4 — no automatic re-run** of the tour after a redesign. Offer it from Help; never re-impose it.
- **NG5 — no server-side onboarding state in v1.** §12 Q1.
- **NG6 — no tour on every page.** Two surfaces. A tour on the billing page is a dark pattern.

## 4. Personas & user stories

**Arun — Pro customer, six months in**
> *I finally learn what "Routing rules" does, from beside the control, and start using a feature I
> have been paying for since February.*

**Kavita — brand new, on a phone**
> *A five-step tour shows me where QRs live, where analytics are, and where to start one — then
> gets out of the way permanently. I can tap the info icons because tapping is all I have.*

**Meera — returning user**
> *I never see the tour again. The explainers are there when I want them and silent when I don't.*

**Ravi — screen-reader user**
> *Every explainer is a real button, announced, and `Escape` returns me where I was.*

## 5. UX

### 5.1 Explainer

A small muted `HelpCircle` beside the control label, **one size, always in the same position
relative to the label**. Opens a popover with one sentence and, where useful, a "Learn more" link
into `/help`.

**Interaction is pointer-type dependent** (G4):

| Device | Behaviour |
|---|---|
| Pointer (`hover: hover`) | Hover to open, with a short delay; also focusable and openable by keyboard |
| Touch | **Tap** to open, tap outside or `Escape` to close |

### 5.2 Tour

A spotlight over the target element, a small card with the copy, `Back` / `Next` / `Skip`, and a
step counter ("2 of 5").

- **Skip is always visible and always one press.**
- `Escape`, outside click and Skip all mean the same thing: never show this tour again.
- **No focus trap** (G6). The user can leave at any moment by simply working.

### 5.3 Timing

The tour starts only **after the page has settled** — not while skeletons are rendering, or the
spotlight lands on an element that then moves 200ms later. Wait for the surface's primary query to
resolve.

### 5.4 Voice

Second person, present tense, one sentence, no marketing:

> ✅ *"Routing rules send different people to different links based on their country, device, or
> the time of day."*
> ❌ *"Unlock the power of intelligent routing!"*

## 6. What gets an explainer

Chosen because each is a question we have actually answered, or a paid capability nobody finds.
This list is the specification of G2 and the guard against NG3.

**Builder (6)**
- **Dynamic vs Static** — the most consequential and least reversible choice in the product
- Page Design — applies to some types only
- Short code — what it is, why it cannot be changed
- Password protection
- Schedule window
- Languages

**QR detail (9)**
- A/B testing
- Routing rules
- **Tags vs folders** — a genuinely confusing distinction that cost a whole PRD to define
- Conversion tracking
- Retargeting pixels
- Review-funnel stats
- Reminder settings
- Scan limit *(once shipped)*
- UTM *(once shipped)*

**Analytics (3)**
- Unique vs total scans
- **Retention window** — why old data disappears. Prevents a support ticket outright.
- Bot filtering

**Billing / plan (2)**
- What `max_scans` counts
- **What happens when it is exceeded — every QR in the workspace is disabled.**

> **That last one may be the single highest-value explainer in the list.** Customers currently learn
> it from an incident. `_enforce_scan_limit` disables every dynamic QR the workspace owns when the
> monthly cap trips, and there is nowhere in the product that says so before it happens.

## 7. Gating

None.

## 8. Success metrics

| Metric | Why | Signal |
|---|---|---|
| Tour completion vs skip rate, per surface | High skip on step 1 = mistimed or unwelcome; high skip on step 4 = too long | — |
| **Explainer open rate per control** | **The discovery signal.** A control whose explainer is opened constantly is a control that is *badly labelled* | High rate ⇒ rename the control, don't improve the tooltip |
| First-QR completion rate, tour-shown vs tour-skipped | Activation | Higher for tour-shown |
| Adoption of `routing_rules` / `ab_testing` among Pro workspaces | §2.2's paid-feature problem | Rising |
| Support tickets answerable by an existing explainer | | Falling |
| Tour shown more than once to the same user | Decides §12 Q1 (server state) | Low, or build the table |

## 9. Edge cases

| # | Case | Behaviour |
|---|---|---|
| E1 | `localStorage` unavailable or throws | Tour may re-show once. Acceptable; every access wrapped in try/catch. |
| E2 | Second device / private window | Tour shows again. Accepted for v1 (NG5); the metric in §8 decides whether to fix it. |
| E3 | A tour target is missing from the DOM | **Do not start the tour.** A partial tour is worse than none. Log in development. |
| E4 | `viewer`-role member | Do not tour them through creating a QR they cannot create. Role-aware step filtering. |
| E5 | Page still loading | Tour waits (§5.3). |
| E6 | User resizes or scrolls mid-tour | Spotlight recomputes, throttled. |
| E7 | Explainer near the viewport edge on a 390px phone | Collision-aware placement; never renders off-screen. |
| E8 | User wants the tour back | Re-offerable from `/help` (§12 Q2). |

## 10. Risks

| Risk | Severity | Mitigation |
|---|---|---|
| **Icon noise** — 20 info icons make the UI look uncertain of itself | High | Strict inclusion criteria (§6); one size; one position; muted until interacted with. **Review the whole set together on one screen before shipping** — they look reasonable one at a time and cluttered in aggregate, and that judgement cannot be made file by file. |
| The tour annoys people and they bounce | Medium | ≤5 steps, Skip always visible, never repeated, never blocking, starts after settle. |
| Hover-only explainers are invisible on mobile | **High** | G4's pointer-type branch, tested both ways. This is the failure that would make the whole feature not exist for most users. |
| Copy rots as features change | Medium | All copy in **one** constants file keyed by control, so a review is one file rather than twenty components. |
| Tooltips become a substitute for good labels | Medium | The open-rate metric surfaces exactly this. A high-open-rate control gets **renamed**, not re-explained. |
| Tour targets break on refactor | Medium | Target by stable `data-tour-id` attributes, never CSS selectors, plus a test that fails when a step's target is absent. |
| Adding a dependency for one component | Low | `@radix-ui/react-tooltip` is a first-party sibling of the 14 Radix packages already installed. §12 Q3. |

## 11. Rollout

**Phase 1 — explainers.** The component, the copy file, the ~20 call sites, and the `title=`
replacements (G8). Independently valuable, no state, no risk, immediately shippable.

**Phase 2 — the tour.** The provider, the spotlight, two surfaces, `localStorage` persistence.

**Phase 3 — decide on server state** from §8's "shown more than once" metric.

## 12. Open questions

1. **Server-side state (v2)?** `localStorage` is per-browser, so a user on laptop and phone sees the
   tour twice. One `user_onboarding_state` table and one endpoint fix it. **Decide from the metric,
   not up front** — the cost of being wrong is one skippable tour.
2. **Re-offer the tour from `/help`?** Yes — cheap, and it turns "I skipped it and now I wish I
   hadn't" from a dead end into a link.
3. **Add `@radix-ui/react-tooltip`, or build the hover branch on the installed Popover?** §2.3 —
   Tooltip is not installed and Popover is. TRD §3 recommends adding it; it is small, same
   maintainer, same version line as the fourteen already present.
4. **Role-aware tours (E4)** — worth doing in v1 if the branching is one condition; otherwise v2.
