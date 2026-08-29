# TRD — QR templates by industry

**Spec:** `INDUSTRY_QR_TEMPLATES_PRD.md` · **Status:** Draft (detailed) · **Date:** 2026-08-28
**Migration:** none. **Repos:** `qr_frontend` only. **Backend:** no change. **Worker:** no change. **KV:** untouched.
**New plan flags:** none. **New dependencies:** none.

---

## 1. Architecture

A pack is **data, not code**: one entry in a constants file naming an existing QR type, an existing
page template, an existing design template, and a content skeleton that satisfies that type's
existing zod schema.

The builder **already has a deep-link contract**. Its mount effect reads:

| Param | Effect (existing) |
|---|---|
| `?restore=` | restore a draft |
| `?type=` | `setQrType`, `setSelectedCategory('dynamic')`, **`setCurrentStep(2)`** — skips type selection |
| `?pageTemplate=` | `setPageDesign(prev => ({...prev, templateId}))` |
| `?designTemplate=` + `?source=system` | applies `SYSTEM_TEMPLATES.find(...)`'s design |
| `?designTemplate=` + `?source=user` | fetches `/workspaces/{id}/templates/{id}`, **silently ignoring a deleted template** |

So a pack is a **named bundle of parameters that already work**, plus one genuinely new thing: the
content skeleton. `?pack=` slots into the same effect.

**Nothing about a pack survives selection.** Once the builder is populated, the QR is an ordinary QR
with no pack reference. That is the property that keeps packs a constants file forever — a pack can
be edited or deleted later without touching a single existing row.

## 2. The constants file

`src/lib/constants/industry-packs.ts`:

```ts
import type { LucideIcon } from 'lucide-react';
import type { QRType } from '@/lib/types/qr';

export interface IndustryPack {
  id: string;                  // 'restaurant' — appears in URLs, must be stable
  label: string;               // 'Restaurant / Café'
  icon: LucideIcon;
  tagline: string;             // 'Menu QR with a digital menu page'
  qrType: QRType;              // must exist in ALL_TYPES
  pageTemplateId?: string;     // must exist in getTemplatesForType(qrType)
  designTemplateId?: string;   // must exist in SYSTEM_TEMPLATES
  thumbnail?: string;
  sampleContent: Record<string, unknown>;  // must satisfy qrType's zod schema
  order: number;
}

export const INDUSTRY_PACKS: IndustryPack[] = [ /* … */ ];
```

House rules: **one export per file** (the interface moves to `src/lib/types/` if imported from more
than one place), kebab-case filename, no `any`.

`sampleContent` is typed loosely at the boundary and **validated in tests against the real zod
schema** for `qrType` (§6). A pack whose sample content the builder would reject is a broken pack
and must fail CI, not a user.

Note the file extension of the page-template constants is **`page-templates.tsx`**, not `.ts` —
`getTemplatesForType(qrType)` and `getDefaultTemplateId(qrType)` are exported from there.

## 3. Deep-link contract

**Added:** `?pack=<packId>`, sufficient on its own — type, templates and content are all looked up
from the pack.

**Precedence, written down here because two call sites will otherwise disagree:**

1. `?restore=` wins over everything (an in-progress draft beats a fresh start).
2. `?pack=` wins over `?type=` / `?pageTemplate=` / `?designTemplate=`.
3. The existing parameters keep working unchanged when `?pack=` is absent.

### 3.1 Handler, inside the existing mount effect

```ts
const packId = searchParams?.get('pack');
if (packId) {
  const pack = INDUSTRY_PACKS.find((p) => p.id === packId);
  if (!pack) return;                     // E1: ignore silently, render the normal builder
  if (!isTypeAllowed(pack.qrType)) return; // E2: fall back to the normal builder

  setQrType(pack.qrType);
  setSelectedCategory('dynamic');
  setCurrentStep(2);                     // same as ?type=
  if (pack.pageTemplateId) setPageDesign((prev) => ({ ...prev, templateId: pack.pageTemplateId }));
  if (pack.designTemplateId && !hasUserDesignTemplate) {   // §12 Q1
    const found = SYSTEM_TEMPLATES.find((t) => t.id === pack.designTemplateId);
    if (found) setQRData((prev) => ({ ...prev, design: found.design }));
  }
  applySampleContent(pack);
  setAppliedPack(pack);                  // drives the banner + the save-time guard
  return;
}
```

The silent-ignore on an unknown id follows the precedent already in that effect for a deleted user
template (*"silently ignore — template may have been deleted"*).

### 3.2 Entitlement check — fail open

`isTypeAllowed` must mirror `QRTypeSelector` / `QRTypesTab` exactly, **including their fail-open
behaviour**:

```ts
const planUnknown = isLoading || isError;
const allowedDynamicTypes =
  (subscription?.features?.dynamic_qr_types as string[] | undefined) ?? null;
// null / planUnknown → do NOT hide. An outage must not become a paywall.
```

`lead_form` is gated by its own `lead_forms` boolean rather than by `dynamic_qr_types` membership —
the same special case `QRTypesTab` already encodes. No pack ships with `lead_form` in the §6 list,
but the helper must handle it so a future pack cannot get it wrong.

## 4. Sample-content safety

Three layers (PRD §9), each in a specific place:

### 4.1 Visual

`applySampleContent` records the set of prefilled field paths in builder state. Content inputs read
that set and render prefilled-and-untouched values with the placeholder treatment plus a small
"sample" affordance. A field the user edits leaves the set permanently.

### 4.2 Clear action

**Clear sample content** in the pack banner wipes every field still in the untouched set, leaving
edited fields alone. One press, no confirm — it is trivially undoable by re-applying the pack.

### 4.3 Save-time guard

Before the create mutation:

```ts
const stale = untouchedSampleStrings(qrData, appliedPack);
if (stale.length > 0) {
  const ok = await confirm({
    title: 'Some sample text hasn’t been changed',
    description: `“${stale[0]}” and ${stale.length - 1} other field(s) still contain sample text.`,
    confirmText: 'Publish anyway',
  });
  if (!ok) return;
}
```

Use the existing `useConfirm()` hook. **Warn, never block** — a heading like "Our Menu" is
legitimately correct as sample text, and blocking would make the pack worse than no pack.

Compare only **user-visible strings**, and only fields still in the untouched set, so an
intentionally-kept value does not nag on every save.

## 5. Components

| File | Responsibility |
|---|---|
| `components/org/templates/industry-pack-card.tsx` | One card: icon, label, tagline, thumbnail, type label |
| `components/org/templates/industry-packs-row.tsx` | The horizontal scroll row; reuses `FilterChips`' scroll treatment for visual consistency |
| `components/org/templates/design-templates-tab.tsx` | Add "Industry" as a **filter** to `DESIGN_CATEGORIES` (PRD §5.3 — a filter, not a tab) |
| `components/org/qrs/MyQRCodes.tsx` | The row above the existing `EmptyState` |
| `app/[slug]/(builder)/build/page.tsx` | The row above the type grid; the `?pack=` handler; the banner; the save guard |
| `components/qr-generator/pack-banner.tsx` | "Started from the Restaurant pack" + **Clear sample content** |

All under the 200-line limit; pages compose and hold no raw JSX blocks or business logic.

Collapsed state for the builder row persists in `localStorage` under a namespaced key
(`qravio.packs.builderRow.collapsed`). **Wrap every read and write in try/catch** and render
correctly with no stored value — private windows, cleared site data and thumbnail-capture contexts
can throw on access (PRD E8).

## 6. Tests (Vitest)

The tests **are** the maintenance strategy for a constants file that references three other
constants files.

### 6.1 Referential integrity — `industry-packs.test.ts`

For every pack:

- `qrType` ∈ `ALL_TYPES` (from `lib/constants/qr-types.ts`);
- `pageTemplateId` ∈ `getTemplatesForType(qrType)` (from `lib/constants/page-templates.tsx`);
- `designTemplateId` ∈ `SYSTEM_TEMPLATES` (from `lib/constants/design-templates.ts`);
- `id` is unique across packs;
- `order` is unique;
- `label`, `tagline` non-empty.

**This is the test that stops a deleted template becoming a user-facing crash** (PRD E4).

### 6.2 Schema validity

`sampleContent` parses against the **real zod schema** for `qrType` — not a shape assertion, the
actual schema the builder uses. The `menu` pack is the one to check by hand first: nested
categories and items are where a hand-written skeleton is most likely to be subtly wrong.

### 6.3 Entitlement filtering

| Subscription state | Expected |
|---|---|
| Free plan without the type in `dynamic_qr_types` | Pack hidden |
| `isLoading` | **All packs shown** (fail open) |
| `isError` | **All packs shown** (fail open) |
| `dynamic_qr_types` absent from features | All packs shown |

The two fail-open cases are the ones worth writing first; they are the difference between an outage
and a paywall.

### 6.4 Deep link

- `?pack=restaurant` → type set, step 2, page template applied, design applied, sample content
  present;
- `?pack=nonsense` → normal builder, **no error rendered**;
- `?pack=x&designTemplate=y&source=system` → the **pack** wins (§3 precedence);
- `?restore=…&pack=x` → **restore** wins;
- a pack whose type is not entitled, reached by URL → normal builder, type unset.

### 6.5 Sample guard

- untouched sample strings trigger the confirm;
- an edited field is excluded from the check;
- **Clear sample content** wipes untouched fields and leaves edited ones;
- declining the confirm does not fire the mutation.

### 6.6 Storage

`localStorage` throwing on read and on write does not throw out of the component.

## 7. Rollout

**PR 1** — constants + tests, no UI. The referential-integrity test starts guarding immediately.
**PR 2** — the three surfaces, the banner, the save guard.

No migration, no backend, no Worker, no KV. Fully revertable — reverting removes a row of cards.

**Pre-merge checklist**
- [ ] Content written by someone with Indian SMB vocabulary (PRD §13), reviewed for register.
- [ ] All ten packs' sample content parses against its type's zod schema.
- [ ] Every pack manually walked end-to-end at least once: pick → builder → publish.
- [ ] The `menu` pack specifically checked for nested-structure correctness.
- [ ] `npm run lint` and `npm test` clean.

## 8. Risks

| Risk | Mitigation |
|---|---|
| Sample content published verbatim | §4's three layers. |
| A referenced template is deleted and packs break | §6.1 referential-integrity test — fails CI before it fails a user. |
| Entitlement filtering hides packs during a subscription outage | Fail open (§3.2), tested in both loading and error states. |
| The row clutters the builder for repeat users | Collapsed state in `localStorage`, guarded. |
| Packs drift from a future marketing surface | Not a risk yet; keep the constants importable and do not fork the list when marketing pages arrive. |
| The `?pack=` handler diverges from the existing param handlers | It lives **inside the same effect**, sharing the same precedence block, rather than in a second effect that races it. |
| Content is under-budgeted and ships as filler | PRD §13 is a scope statement, not a footnote. The checklist item above is the gate. |
