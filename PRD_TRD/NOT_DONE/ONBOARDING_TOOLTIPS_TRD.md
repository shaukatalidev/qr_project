# TRD — Onboarding tooltips

**Spec:** `ONBOARDING_TOOLTIPS_PRD.md` · **Status:** Draft (detailed) · **Date:** 2026-08-28
**Migration:** **none in v1.** (A `user_onboarding_state` table is the v2 option — §9.)
**Repos:** `qr_frontend` only. **Backend:** no change. **Worker:** no change. **KV:** untouched.
**New dependency:** `@radix-ui/react-tooltip` (see §3). **Third-party scripts:** none.

---

## 1. Architecture

Two independent pieces sharing nothing but a copy file:

```
explainer-copy.ts ──▶ <Explainer id="routing-rules" />     stateless, always available
                 └──▶ TOURS ──▶ <TourProvider tour="qr-list">   localStorage-gated, first run only
                                      │
                                      ├── tour-spotlight.tsx   (rect from data-tour-id)
                                      └── tour-card.tsx        (copy, Back/Next/Skip)
```

**No product-tour library.** A spotlight is an absolutely-positioned overlay with a computed rect;
the alternative is a third-party script on an authenticated dashboard (PRD NG1).

## 2. What is actually in the repo

Establish this before writing code, because the obvious assumption is wrong:

| Assumption | Reality |
|---|---|
| "shadcn `Tooltip` exists, just use it" | **It does not.** `components/ui/` has `popover.tsx`, `sheet.tsx`, `confirm-dialog.tsx` — no `tooltip.tsx`. |
| "`Tooltip` is used in the analytics components" | Those are **Recharts'** chart tooltips (`import { … Tooltip } from 'recharts'`), which explain a data point, not a feature. |
| "`@radix-ui/react-tooltip` is installed" | **It is not.** Fourteen Radix packages are; tooltip is not among them. |
| "There is an existing explainer pattern" | The pattern is the native **`title="…"` attribute in 27 files** — hover-only, unstyled, and invisible on touch. |

## 3. The dependency decision

**Recommendation: add `@radix-ui/react-tooltip`.**

- It is a first-party sibling of the fourteen Radix packages already installed, same maintainer,
  same version line (`^1.x`), a few KB.
- The alternative — building hover behaviour on `@radix-ui/react-popover` — means hand-rolling
  hover intent, open delay, and the focus semantics Radix Tooltip already ships, and getting the
  accessibility wrong is likely.

**Use both:** Tooltip for the pointer branch, the already-installed Popover for the touch branch.
Radix Popover is designed for click/tap; Radix Tooltip is designed for hover and focus. Each does
the job it was built for.

## 4. Copy as data

`src/lib/constants/explainer-copy.ts`:

```ts
export interface ExplainerCopy {
  id: string;              // 'routing-rules'
  text: string;            // ONE sentence, second person, present tense
  learnMoreHref?: string;  // into /help
}

export const EXPLAINERS: Record<string, ExplainerCopy> = { /* ~20 entries */ };
```

All copy in one file so a voice review (PRD §5.4) is one file rather than twenty components, and so
copy rot is a single diff. A test asserts every `id` rendered in the tree exists here and that no
entry is orphaned (§8).

## 5. `<Explainer>` — `src/components/ui/explainer.tsx`

```tsx
<Explainer id="routing-rules" />
```

### 5.1 Pointer-type branch — the most important detail in this document

```ts
const canHover = useMediaQuery('(hover: hover) and (pointer: fine)');
```

- `canHover` → Radix **Tooltip** (hover + focus).
- otherwise → Radix **Popover** (tap to open, tap-outside/`Escape` to close).

**A hover-only explainer does not exist on mobile**, which is where a large share of our users are
(PRD G4, §10). Both branches are tested (§8).

Implement `useMediaQuery` with `window.matchMedia`, guarded for SSR (`typeof window === 'undefined'`
→ default to `true`, the hover branch, so the server render is stable and hydration does not flip
the tree). Subscribe to changes — a tablet with a keyboard attached changes answer mid-session.

### 5.2 Accessibility (PRD G5)

- The trigger is a real `<button type="button">` with an `aria-label` derived from the copy id —
  never a bare `<svg>` or a `<div onClick>`.
- Keyboard focusable and openable; `Escape` closes; **focus returns to the trigger**.
- Content carries `role="tooltip"` and is associated via `aria-describedby`.
- The icon itself is `aria-hidden`.

### 5.3 Visual contract

One size, one position (immediately after the label), muted until hover/focus, using design tokens
(`text-on-surface-variant`, `surface-container`) rather than raw palette classes. The contract is
what makes twenty of them read as a system rather than as clutter (PRD §10).

### 5.4 Replacing native `title=` (PRD G8)

Sweep the 27 files. Two rules:

- A `title` doing **explanatory** work ("what does this do") → `<Explainer>`.
- A `title` doing **labelling** work on an icon-only button (`title="Edit"`, `title="Delete"` in
  `schedule-row.tsx`, `details-header.tsx`) → **`aria-label` + the shadcn tooltip**, not an
  explainer. These are labels, not explanations, and giving them info icons is exactly the noise
  PRD NG3 forbids.

Do the sweep in its own commit so the diff is reviewable.

## 6. Tour

`src/components/onboarding/` — `tour-provider.tsx`, `tour-spotlight.tsx`, `tour-card.tsx`;
`src/lib/constants/tours.ts`.

```ts
interface TourStep {
  targetId: string;                        // matches data-tour-id
  title: string;
  body: string;
  placement: 'top' | 'bottom' | 'left' | 'right';
  requiresRole?: 'editor' | 'owner';       // PRD E4
}
export const TOURS: Record<'qr-list' | 'builder', TourStep[]>;
```

### 6.1 Targeting

Elements carry `data-tour-id="…"`. **Never CSS selectors or DOM traversal** — those break silently
on the next refactor and the failure is a spotlight over empty space.

### 6.2 Start conditions — all must hold

1. No `seen` entry in `localStorage` for this tour.
2. The surface's primary query has resolved (`!isLoading`) — PRD §5.3.
3. **Every** step's target exists in the DOM. If any is missing, do not start; log in development
   (PRD E3).
4. The user's workspace role permits the actions described (`requiresRole`, PRD E4).

### 6.3 Positioning

`getBoundingClientRect()` on the target; recompute on `resize` and `scroll`, throttled with
`requestAnimationFrame`. The spotlight is an overlay with a cut-out; the card placement runs a
viewport collision check so it never renders off-screen on a 390px phone (PRD E7).

### 6.4 Not focus-trapped

The tour must never block work (PRD G6). `Escape`, outside click and **Skip** all mark seen and
dismiss. There is no state in which the user is stuck.

### 6.5 Persistence — `src/lib/onboarding-storage.ts`

```ts
const KEY = (tour: string) => `qravio.onboarding.${tour}.v1`;

export function hasSeenTour(tour: string): boolean {
  try { return window.localStorage.getItem(KEY(tour)) === '1'; } catch { return false; }
}
export function markTourSeen(tour: string): void {
  try { window.localStorage.setItem(KEY(tour), '1'); } catch { /* no-op */ }
}
```

**Every read and write in try/catch.** Private windows, cleared site data, browsers set to block
site data, and thumbnail-capture contexts can all throw on access, and an exception here must not
take down the page it decorates (PRD E1).

The `v1` suffix lets a future redesign re-offer a tour **deliberately** (bump to `v2`) rather than
by accident.

## 7. Mount points

- `<TourProvider tour="qr-list">` in `app/[slug]/(dash)/qrs/page.tsx`.
- `<TourProvider tour="builder">` in `app/[slug]/(builder)/build/page.tsx` — note the builder is
  outside `(dash)`, so it needs its own mount.
- `data-tour-id` on ~10 targets across `MyQRCodes.tsx`, the sidebar, the builder step nav, and the
  create button.
- `<Explainer>` at the ~20 call sites in PRD §6.
- A **"Replay tour"** entry in `/[slug]/help/page.tsx` that clears the `seen` keys (PRD §12 Q2).

## 8. Tests

### 8.1 Vitest — explainer

- Every `<Explainer id>` rendered anywhere in the tree resolves in `EXPLAINERS`; no orphaned entries.
- **Pointer branch:** `matchMedia('(hover: hover)')` mocked true → Radix Tooltip; mocked false →
  Popover opening on tap. **Both cases.** The touch path is the one that silently ceases to exist
  if this regresses, and it is the majority path.
- `Escape` closes and returns focus to the trigger.
- The trigger is a `<button>` with an `aria-label`; the icon is `aria-hidden`.
- Content is associated via `aria-describedby`.

### 8.2 Vitest — tour

- Does not start when `seen` is set.
- Does not start while `isLoading`.
- **Does not start when any target is missing** (PRD E3).
- Skips role-gated steps for a `viewer` (PRD E4).
- Skip / `Escape` / outside click each mark seen; a re-mount does not re-show.
- `localStorage` throwing on **read** and on **write** does not throw out of the component.
- **Every `TourStep.targetId` has a matching `data-tour-id` in the rendered surface.** This is the
  test that stops a refactor producing a spotlight over nothing.

### 8.3 Playwright — `npm run test:e2e`

First visit shows the tour; Skip dismisses; reload does not re-show. **Run once at a mobile
viewport** — positioning and the touch branch are where this breaks and neither is observable in
jsdom.

## 9. v2 — server-side state (NOT in this scope)

Build only if PRD §8's "tour shown more than once per user" proves material:

```sql
CREATE TABLE IF NOT EXISTS user_onboarding_state (
    user_id    uuid PRIMARY KEY,          -- no FK: account_purge enumerates its tables
    seen_tours jsonb NOT NULL DEFAULT '{}'::jsonb,
    updated_at timestamptz NOT NULL DEFAULT now()
);
```

plus `GET`/`PATCH /api/users/me/onboarding`. `localStorage` stays the fast path and the offline-safe
fallback; the server becomes the merge target.

**Do not build this speculatively.** It is one table and one endpoint whenever the metric justifies
it, and until then it is a schema to keep in sync for no measured benefit.

## 10. Analytics

Reuse the existing Mixpanel wrapper (`src/lib/analytics/mixpanel.ts`, via `getClient()`), routed
through `src/lib/analytics/sanitize.ts` as the other events are:

| Event | Properties |
|---|---|
| `tour_started` | `tour` |
| `tour_step_viewed` | `tour`, `step_index` |
| `tour_completed` | `tour` |
| `tour_skipped` | `tour`, `step_index` |
| `explainer_opened` | `explainer_id` |

`explainer_opened` is **the discovery signal** in PRD §8 and the input to renaming badly-labelled
controls. No PII, no URLs, no workspace content — `getClient()` returns `null` when Mixpanel is not
initialised or the user opted out, so every call must tolerate that.

## 11. Rollout

1. **Add `@radix-ui/react-tooltip`** and build `<Explainer>` + the copy file. No call sites yet.
2. **Wire the ~20 call sites** (PRD §6). Ship.
3. **Sweep the native `title=` usages** (§5.4) in a separate, reviewable commit.
4. **Build the tour** and mount it on the two surfaces.
5. **Add "Replay tour"** to `/help`.

**Pre-merge gate for step 2:** review all ~20 explainers **on one screen together**. They look
reasonable one at a time and cluttered in aggregate, and that judgement cannot be made file by file
(PRD §10, icon noise). Cut anything that does not survive that view.

No migration, no backend, no Worker, no KV. Fully revertable at every step.

## 12. Risks

| Risk | Mitigation |
|---|---|
| Hover-only explainers invisible on mobile | §5.1 pointer branch, both cases tested, mobile Playwright run. |
| Spotlight over a moved or absent element | `data-tour-id` targeting, start-condition check, and the §8.2 target-existence test. |
| Tour blocks work | No focus trap; three independent dismissals; never modal. |
| `localStorage` throws | Every access wrapped; tested on both read and write. |
| Icon noise | Strict §6 criteria, one whole-set review gate, and the open-rate metric to prune later. |
| Copy rot | One constants file; a feature change is a one-file diff. |
| The `title=` sweep turns labels into explainers | §5.4's two rules — labels get `aria-label` + tooltip, not an info icon. |
| A new dependency for one component | §3 — a first-party sibling of fourteen packages already present; the alternative is hand-rolling hover intent and getting a11y wrong. |
