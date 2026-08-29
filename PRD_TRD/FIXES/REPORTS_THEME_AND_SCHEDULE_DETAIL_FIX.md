# FIX — `/reports` theme drift + missing schedule detail page

**Status:** Draft · **Author:** Product/Eng · **Date:** 2026-08-28
**Type:** Defect + gap in a **shipped** feature (`SCHEDULED_REPORTS_ALERTS_PRD.md`, DONE).
**Repos:** `qr_frontend` only. **Migration:** none. **Backend change:** none. **Worker change:** none.
**Plan flags:** none new — the surface stays behind the already-`enforced` `scheduled_reports` flag.

---

## 1. What is wrong

Two separate defects arrived as one report ("the /reports page theme is not matching").

### D1 — The page is painted in stock Tailwind blue, not the design system's indigo

`DESIGN_SYSTEM.md` names `primary` = `#4648d4` (indigo) as the button/active/link colour. The
dashboard has been migrating onto that token — `Card` moved off hardcoded `bg-white
border-gray-200 shadow-sm` to the token-driven `card-surface` class, and its docblock records why
("pinned the card to light mode — `.dark` overrides the tokens, not the raw palette"). Measured
across `components/org/`, raw `blue-*` occurrences vs `primary`-token occurrences:

| Directory | raw `blue-*` | `primary` token |
|---|---|---|
| `qrs/` | 20 | **191** |
| `content-type/` | 6 | **105** |
| `analytics/` | **0** | 58 |
| `billing/` | 9 | 36 |
| `settings/` | **0** | 32 |
| `dashboard/` | 4 | 24 |
| **`reports/`** | **30** | **5** |

**`reports/` is the only directory in the dashboard where the stock blue outnumbers the design
token, and it does so six to one.** That is the "doesn't match" in the report, quantified. (`help/`
at 13/0 and `leads/` at 6/0 are also off-theme and are *adjacent* scope — worth a follow-up, not
worth widening this fix.)

The offending lines — 30 occurrences across 19 lines in 7 files, all confirmed on disk:

| File | Line | Class |
|---|---|---|
| `scheduled-reports-client.tsx` | 103 | `bg-blue-600 … hover:bg-blue-700` (the primary "New schedule" button) |
| `export-now-card.tsx` | 106 | `bg-blue-600 … hover:bg-blue-700` |
| `scheduled-reports-list.tsx` | 76 | `text-blue-600 hover:text-blue-700` |
| `schedule-row.tsx` | 42–43, 113 | `focus:ring-blue-500`, `bg-blue-600` (active toggle), `hover:text-blue-600 hover:bg-blue-50` |
| `schedule-form-fields.tsx` | 88, 98, 150, 160, 179 | `text-blue-600 focus:ring-blue-500` on radios; `focus:ring-blue-500` on the input |
| `alert-thresholds.tsx` | 37, 52, 69, 84 | `text-blue-600 focus:ring-blue-500` on checkboxes and inputs |
| `alerts-config-card.tsx` | 129, 138–140 | `focus:ring-blue-500`; the info callout is `bg-blue-50 border-blue-100 text-blue-500/700` |

**Consequence.** The single most prominent control on the page — the "New schedule" button —
renders `#2563eb` next to a sidebar and a QR list rendering `#4648d4`. Two indigos that are
almost the same read as a rendering bug, not as a second brand colour.

### D2 — The same files hardcode greys, so the page cannot go dark

49 raw `gray-*` classes across the directory (`text-gray-900`, `border-gray-300`,
`hover:bg-gray-50`, `bg-gray-200`, …). The shared `Card` component already moved off this —
its docblock records that `bg-white border-gray-200 shadow-sm` "pinned the card to light mode,
because `.dark` overrides the tokens, not the raw palette". The reports components never got
that treatment, so they will stay light-mode-only after everything around them has switched.

### D3 — There is no way to open a single schedule

`/[slug]/reports` renders `ScheduledReportsClient` → a table of `ScheduleTableRow`s. A row shows
QR name, frequency, format, a **recipient count**, `last_sent_at`, an active toggle, edit and
delete. There is no detail route: `app/[slug]/(dash)/reports/` contains only `page.tsx`.

So an owner cannot answer, without opening the edit modal and reading a form:

- *Who* actually receives this report (the row says "3 recipients", not which three).
- What the report will contain — which QR, which window, which format.
- Whether the last send succeeded or merely happened.

### D4 — House code rules are violated in the same files

`.agents/rules/code-style-guider.md` requires shadcn primitives over raw HTML ("Never
`<button>` when `<Button>` exists"). `scheduled-reports-client.tsx:103`,
`export-now-card.tsx:106` and both icon actions in `schedule-row.tsx:113` are raw `<button>`;
the radios and checkboxes in `schedule-form-fields.tsx` and `alert-thresholds.tsx` are raw
`<input>`. Fixing the colours by hand-editing those class strings would re-cement the
violation, which is why D1 and D4 are one job.

---

## 2. What is NOT wrong (scope fence)

- **The backend is fine.** `analytics_reports.py` has correct CRUD + the `scheduled_reports`
  gate, and `internal.py`'s run-reports/run-alerts re-check it. No endpoint changes here.
- **The entitlement logic is fine** and subtle — `scheduled-reports-client.tsx` deliberately
  refuses to redirect on `subError`, so a failed subscription read cannot bounce a paying
  customer off the page they bought. **Do not "simplify" that during the redesign.**
- **The alerts half is in scope for theming only**, not for behaviour changes.

---

## 3. The fix

### 3.1 Theme (D1, D2, D4)

Token map to apply mechanically across the 7 files:

| Replace | With |
|---|---|
| `bg-blue-600` / `hover:bg-blue-700` | the shadcn `<Button>` default variant (already `primary`) |
| `text-blue-600` (link) | `text-primary hover:text-primary-container` |
| `focus:ring-blue-500` | `focus:ring-primary` (or drop — shadcn primitives ring correctly) |
| `bg-blue-50 border-blue-100 text-blue-700` (callout) | `bg-primary-fixed border-primary-fixed-dim text-on-primary-fixed` |
| `text-gray-900` / `text-gray-600` / `text-gray-500` | `text-on-surface` / `text-on-surface-variant` |
| `border-gray-300` | let the shadcn primitive own it |
| `hover:bg-gray-50` (table row) | `hover:bg-surface-container-low` |
| `bg-gray-200` (toggle off state) | `bg-surface-container-high` |
| raw `<button>` | `<Button>` from `components/ui/button` |
| raw `<input type="radio">` | `<RadioGroup>` |
| raw `<input type="checkbox">` | `<Checkbox>` |
| raw `role="switch"` in `schedule-row.tsx` | `<Switch>` |

Keep `Card` and `PageHeader` — they are already correct and are what makes the rest of the
dashboard consistent.

### 3.2 Stitch redesign pass

Generate the two screens against the existing **"Indigo Graphite"** Stitch design system
(project `7096622585356463237`) rather than free-styling: `/reports` (list + alerts) and the
new schedule detail. Use the output for **layout and hierarchy** only; colour comes from the
token table above, not from the Stitch export, so the page cannot drift a third time.

### 3.3 Schedule detail page (D3)

New route: `app/[slug]/(dash)/reports/[id]/page.tsx`.

**No new endpoint.** `GET /workspaces/{id}/scheduled-reports` already returns the full row set
for the workspace, and TanStack dedupes it. The detail page reads the existing
`useScheduledReports(workspaceId)` query and selects by `id` — so a hard refresh costs the same
one request the list page already makes, and an edit invalidates both surfaces at once.

Sections:

1. **Header** — report name (QR name, or "Whole workspace"), status pill, Edit / Delete /
   Send-now actions. Reuses `PageHeader`.
2. **Delivery** — frequency, format, and the **full recipient list** (the row's "3 recipients"
   expanded), each with a copy affordance.
3. **Scope** — the linked QR (deep-links to `/[slug]/qrs/{qr_id}`) or an explicit "every QR in
   this workspace" statement.
4. **Last send** — `last_sent_at` rendered absolute + relative, and the next expected send
   derived from `frequency`. Where `last_sent_at` is null, say **"Never sent yet"** and, when
   the schedule was created under a minute ago, why that is expected.
5. **What this report contains** — a static description of the metrics the PDF/CSV carries, so
   the owner does not have to trigger a send to find out.

Row → detail navigation: make the QR-name cell in `ScheduleTableRow` a link; keep the existing
edit/delete icon actions where they are so nothing regresses for people who know the table.

**Scope fence — no run history in v1.** `scheduled_reports` carries `last_sent_at` and nothing
else; there is no `scheduled_report_runs` table, so "the last 10 sends, with outcomes" is not
renderable from existing data. Do **not** fake it from `last_sent_at`. A real history is a
separate spec: one table, one insert in `internal.py`'s run-reports tick, one migration.

---

## 4. Tests

- **Vitest, theme regression:** a test that greps `src/components/org/reports/**` for
  `/\b(bg|text|border|ring)-blue-\d{2,3}\b/` and fails on any hit. This is the only thing that
  stops the drift returning on the next feature; the existing directory proves review alone
  did not catch 19 of them.
- **Vitest, detail page:** renders with a fixture schedule; asserts every recipient is present
  (not a count), that a null `last_sent_at` renders "Never sent yet", and that a workspace-wide
  schedule renders the explicit scope sentence rather than an empty QR link.
- **Vitest, regression on the entitlement path:** `subError === true` must NOT redirect. Pin
  the existing behaviour before touching these files.

## 5. Risks

| Risk | Mitigation |
|---|---|
| A mechanical colour sweep also swaps semantic colours (red delete, amber warning) | The greps above are scoped to `blue-` and `gray-` only; leave `red-*` / `amber-*` alone. |
| Swapping raw inputs for shadcn primitives silently breaks `react-hook-form` registration | The forms are already RHF + zod (`schedule-form-schema.ts`); use `<Controller>`/`<FormField>` and keep the existing schema untouched, so a broken wiring fails the schema test rather than saving a malformed schedule. |
| The 200-line-per-component rule | The detail page splits into `schedule-detail-header.tsx`, `schedule-delivery-card.tsx`, `schedule-scope-card.tsx`; the page file only composes. |
