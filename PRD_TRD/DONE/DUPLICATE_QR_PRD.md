# PRD — Duplicate QR

**Status:** SHIPPED 2026-08-29 · **Author:** Product · **Date:** 2026-08-28
**As built:** see `DUPLICATE_QR_TRD.md` §0 — seven TRD claims were wrong, §2.4's landing-page precedent does not exist, and §5.3's post-duplicate navigation was changed.
**Priority:** Highest value-to-effort ratio in the 2026-08-28 batch. No new concepts, no edge change, no migration; it makes an existing workflow 12× faster for the customers who create the most QRs.
**Tiers:** **All plans, ungated.** A duplicate consumes a `max_qr` slot, which is the fence that already exists. A second fence on the *act* of duplicating would only push people back to rebuilding by hand — the behaviour this feature exists to remove.
**Plan flags:** **None new.** The copy is created through `create_qr`, so it passes the same `max_qr`, `dynamic_qr_types`, `lead_forms` and `max_file_size_mb` checks as any other QR. A duplicate can never grant a capability the workspace could not have created directly.
**Split from:** the QR create path (`src/core/qr/service.py::create_qr`). Direct sibling to the landing-page duplicate that already ships (`POST /landing-pages/{id}/duplicate`, `useLandingPages.ts:258`).
**Repos:** `qr_backend`, `qr_frontend`. No Worker change, no KV contract change, no migration.

---

## 1. TL;DR / Summary

A **Duplicate** action on the QR list row menu and the QR detail header creates a new, fully
independent QR carrying over everything the original configured — content, QR design, page design,
destinations (including A/B variants and weights), schedule window, daily window, locales and
translations, routing rules, retargeting-pixel selection, tags and folder — under a new name
(`"{original} (copy)"`), with a **new short code**, **no scan history**, **no password**, and
status `active`.

The implementation is deliberately *not* a table-by-table row copy. It **reads the original
through the same relation set the GET endpoint uses, rebuilds the content payload, and calls the
existing `create_qr`.** Every validator, plan gate, short-code reservation, storage rule and KV
publish is therefore reused rather than re-implemented, and a duplicate cannot become a QR the
API would have refused.

## 2. Problem & Motivation

### 2.1 The current cost

Creating the fifth near-identical QR is a full pass through the four-step builder: choose type,
enter content, pick and configure a page design, configure the QR design, download. For a
`menu` QR with categories and items, or a `business` QR with hours, services and socials, that is
several minutes of data entry to reproduce something that already exists in the account.

### 2.2 Who feels it

The three segments who feel it are the three that matter commercially:

- **Agencies.** `max_workspaces` is 3 on Pro and unlimited on Agency, and the agency motion is
  "the same campaign, twelve clients". Design identical, page layout identical, one URL and one
  logo different each time. Today that is twelve builder passes.
- **Multi-location SMBs.** Eleven outlets of the same restaurant need eleven menu QRs differing
  in one heading. Eleven outlets of the same salon need eleven review funnels differing in one
  Google review link.
- **Iterating designers.** Anyone who wants to try a variant of a QR that is already printed and
  live. Today the only safe way to experiment is to rebuild from scratch, because editing the
  live one risks the printed artefact.

### 2.3 The workaround is lossy, not merely slow

Rebuilding is not an equivalent path. Step-3 page-design choices — template, theme colour, page
title, section ordering — are easy to reproduce *approximately* and hard to reproduce *exactly*.
So the "same" campaign drifts visually across a client roster, which is precisely the outcome an
agency is selling against.

### 2.4 We already accept the premise

Landing pages have had a duplicate endpoint since they shipped. QR codes — the primary object of
the product, the thing the company is named for — do not. There is no principled reason for the
asymmetry; it is an accident of build order.

### 2.5 Competitive context

Duplicate/clone is a standard row action in Bitly, Beaconstac, QR Tiger and QRCodeChimp. It does
not win a deal on its own, but its absence is noticed immediately by anyone migrating from a
competitor, and it is the kind of gap that makes a product feel unfinished in a trial.

## 3. Goals & Non-Goals

### Goals

- **G1.** One-press duplicate from the QR list row menu and from the QR detail header.
- **G2.** The copy is a fully independent QR: its own `id`, its own `short_code`, its own KV entry,
  its own storage prefix. Deleting the original must not affect the copy in any way.
- **G3.** Carry over everything that is *configuration*: content (every type), QR design, page
  design, destinations with weights and variant keys, `ab_enabled`, schedule window, daily window,
  `default_locale` / `locales` / `locale_autodetect` and per-locale translations, routing rules,
  `retargeting_mode` / `pixel_ids`, tags, folder, custom domain.
- **G4.** Carry over **nothing** that is *history* or *secret*: scans, scan counters, blocked
  scans, lead submissions, link-click events, webhook milestones, or the password.
- **G5.** Land the user in the copy's detail page, not back on the list. The next action after
  duplicating is always "change the one thing that differs".
- **G6.** Enforce every limit and entitlement the create path enforces, with the same status codes
  and the same messages, so the upgrade path is identical and there is one place to maintain it.
- **G7.** Name the copy so ten duplicates of one QR are distinguishable in a list without renaming.

### Non-Goals

- **NG1 — no bulk duplicate ("duplicate ×10") in v1.** `POST /qr-codes/bulk` already exists as its
  own path with its own 50-item ceiling. A bulk *duplicate* multiplies the plan-limit arithmetic,
  the storage-copy cost and the partial-failure surface. It is a natural v2 and it earns its own spec.
- **NG2 — no linked / template copies.** The duplicate is a **snapshot**. Editing the original
  later must not touch the copy. "Change once, propagate everywhere" is the template system, which
  exists separately (`qr_design_templates`, the Templates page).
- **NG3 — no cross-workspace duplicate.** Moving a QR between workspaces touches 24 child tables,
  storage prefixes and `created_by` repointing, and `account_purge` fails on the FK if that last
  one is missed. That is the guest-transfer problem and it is explicitly out of scope here.
- **NG4 — no public API endpoint in v1.** This is a dashboard workflow affordance. Adding it to
  `/api/public/v1` later is one route.
- **NG5 — no "duplicate into another folder" picker in the first release.** The copy lands in the
  original's folder; moving is one existing drag.

## 4. Personas & user stories

**Priya — agency operator, Agency plan, 40 QRs across 6 client workspaces**
> *I duplicate "Acme — Table Tent", change the destination to Beta Corp's URL and the logo, and
> ship in 30 seconds instead of 6 minutes. The design is byte-identical to Acme's, which is what
> my client is paying for.*

**Ravi — restaurant owner, 11 outlets, Pro plan**
> *I build the menu QR once with 6 categories and 40 items, then duplicate it 10 times and change
> only the outlet name on each. I never re-enter a menu.*

**Meera — designer at an SMB, Starter plan**
> *Our table-tent QR is printed and live. I duplicate it before experimenting with the page
> template, so nothing I do can affect the 2,000 cards already on tables.*

**Anonymous / guest builder**
> Out of scope for v1 — guests hold a single QR by design and duplication has no meaning there.

## 5. UX

### 5.1 Entry points

**A. QR list row menu** — `components/org/qrs/components/QRCodesTable.tsx`, which already receives
`onEdit`, `onPreview`, `onViewDetails`, `onDelete`, `onMoveToFolder` from `MyQRCodes.tsx`. Add
`onDuplicate` in the same shape. Menu position: **between Edit and Move to folder**, above the
destructive Delete, so a mis-click near Delete is not more likely.

**B. QR detail header** — `components/org/qrs/details/details-header.tsx`, which today carries
name-edit, copy-link, download and print actions. Add Duplicate to that cluster with the `Copy`
icon already imported there.

### 5.2 Naming

Default: `"{original name} (copy)"`.

If a QR with that exact name already exists in the workspace, probe `"(copy 2)"`, `"(copy 3)"`, …
Names are **not** unique in the schema, so this is a readability nicety and must never fail a
duplicate — after a bounded number of probes, fall back to the un-suffixed name and proceed.

Rationale: silently producing ten QRs all called "Menu (copy)" is the single most common complaint
about duplicate features in other tools, and it converts a time-saving feature into a renaming chore.

### 5.3 Feedback and navigation

Duplication does real server work — a limit check, a storage copy, several inserts and a KV
publish — so an optimistic UI is wrong. Sequence:

1. Menu item enters a pending state (spinner, disabled, label unchanged).
2. On success: navigate to `/{slug}/qrs/{newId}` and show a toast — *"Duplicated. This is a new QR
   with its own short link."* The second sentence matters: it pre-empts the most common
   misunderstanding, which is that the copy shares the original's printed code.
3. On `402` (`max_qr` reached): show the existing upgrade CTA used by the QR list, not a generic
   error toast. The response interceptor already toasts 402; the CTA is what makes it actionable.
4. On `403` (entitlement or staff hold): show the message from the API verbatim — the two cases
   need different explanations and the backend already distinguishes them.

### 5.4 Status of the copy

The copy is created **`active`**, regardless of the original's status, with two exceptions in §8.

A duplicate of a `paused` QR is active because the user is duplicating in order to *use* it; a
copy born paused is a confusing extra step. A duplicate of a `disabled` (scan-cap) or `locked`
(plan-downgrade) QR is also active — those statuses describe the *workspace's* billing condition
and will be re-applied by the same sweeps if they still apply.

### 5.5 What the user is told about the short code

The copy's short code differs, and the QR image differs. This is obvious to us and not to users,
several of whom will assume a duplicate is reprintable from the original's artwork. The success
toast says it, and the copy's detail page shows the new short link in the same place it always does.

## 6. Carry-over matrix

This table is the specification of the feature. Anything not listed defaults to **not copied**.

| Item | Source | Copied? | Rationale |
|---|---|---|---|
| `name` | `qr_codes.name` | Derived | `"… (copy)"` with collision suffix (§5.2). |
| `type`, `category` | `qr_codes` | **Yes** | Identity of the thing being duplicated. |
| `short_code` | `qr_codes.short_code` | **No — newly minted** | Two QRs cannot share a KV key. |
| `status` | `qr_codes.status` | **No — forced `active`** | §5.4. |
| `folder_id` | `qr_codes.folder_id` | **Yes** | Least surprise; the copy belongs where the original lives. |
| `custom_domain_id` | `qr_codes.custom_domain_id` | **Conditionally** | Only if the domain is still owned by the workspace **and** `status = 'verified'`. Otherwise dropped to the default domain — never publish a copy onto a released domain. |
| Content (all `*_details`, `qr_files`, `qr_link_pages`+items, `qr_menus`+categories+items, `qr_lead_forms`, `qr_review_funnel`) | `SELECT_WITH_RELATIONS` | **Yes** | The bulk of the work being saved. |
| Uploaded files (PDF, images, MP3, logos) | Supabase Storage | **Yes — copied to a new prefix** | The copy must survive deletion of the original, which purges the original's prefix. |
| `qr_designs.design` (QR pixel design) | `qr_designs` | **Yes** | |
| `qr_designs.page_design` | `qr_designs` | **Yes** | Includes `templateId`, theme colour, page title. The exactness of this is §2.3's whole point. |
| `qr_destinations` (all rows) | `qr_destinations` | **Yes**, incl. `weight`, `is_active`, `variant_key`, `label` | A/B setup is configuration. |
| `ab_enabled` | `qr_codes` | **Yes** (recomputed from destinations by the create path) | |
| Routing rules | routing tables | **Yes** | Configuration, not history. |
| `start_at` / `end_at` / `schedule_tz` | `qr_codes` | **Yes** | See §9.3 for the expired-original edge case. |
| `daily_start` / `daily_end` / `daily_days` | `qr_codes` | **Yes** | |
| `default_locale` / `locales` / `locale_autodetect` | `qr_codes` | **Yes** | |
| `qr_translations` rows | `qr_translations` | **Yes** | Re-entering six locales by hand defeats the feature. |
| `retargeting_mode` / `pixel_ids` | `qr_codes` | **Yes** | Pixels are workspace-scoped, so the ids remain valid. |
| Tags (`qr_tags` join rows) | `qr_tags` | **Yes** | A copy almost always belongs to the same campaign. See §14 Q2. |
| `created_by` | — | **New: the duplicating user** | Attribution must reflect who created *this* row. |
| Password (`qr_passwords`, `is_password_protected`) | — | **No** | §7.2. |
| `qr_scan_events`, `qr_scan_counters`, `qr_blocked_scans` | — | **No** | The copy has never been scanned. Inheriting counts corrupts every rollup the copy appears in and every billing calculation it touches. |
| `qr_lead_submissions` | — | **No** | Other people's submitted data, belonging to a different QR. |
| `qr_link_click_events` | — | **No** | History. |
| `qr_webhook_milestones` | — | **No** | Milestones are per-QR scan thresholds; a fresh QR has fired none. |

## 7. Guardrails

### 7.1 Limits and entitlement are re-checked, not inherited

- **`max_qr`** — checked before any write, via the same `check_limit` the create path uses. That
  helper fails **closed but retryably** (a lookup error returns 503, not a 402 upgrade wall) and
  distinguishes the lapsed-subscription grace case in its message. Duplicate inherits all of that
  by calling the same code, and must not re-implement the check.
- **`dynamic_qr_types` / `lead_forms`** — re-checked. A workspace that downgraded may still hold a
  QR of a type it can no longer create. **Duplicating it must fail with the same 403 as creating
  it**, otherwise Duplicate is a downgrade-evasion hatch: downgrade to Free, duplicate your ten
  `lead_form` QRs, keep the capability.
- **`max_file_size_mb`** — re-checked against the original's file sizes before any bytes are
  copied. A workspace that downgraded from Agency (50MB) to Starter (10MB) must not be able to
  duplicate its way to a second 40MB PDF.

### 7.2 The password is never copied

A password is a secret with a distribution list. Cloning it silently spreads it onto a QR the
owner may share with a different audience, and the owner has no signal that it happened. The copy
is created unprotected and the detail page's password card shows its normal "not protected" state,
which is a visible, correctable condition rather than an invisible leak.

### 7.3 Staff holds cannot be duplicated

`suspended` is a moderation hold that **only staff may clear** (`src/core/qr/status.py`:
`STAFF_HOLD_STATUSES`). Duplicating a suspended QR would be a one-press takedown bypass: the
content is copied, the copy is `active`, and the same material is live again under a new short
code. Refuse with a distinct 403.

`unclaimed_expired` is refused for a structural reason rather than a moderation one: it marks a QR
built without an account that nobody claimed. There is no live owner to attribute a copy to.

Use `is_staff_hold()` and the status constants rather than inline literals, so a future hold status
is covered without anyone remembering this paragraph.

## 8. Edge cases

| # | Case | Behaviour |
|---|---|---|
| E1 | Original is `paused` / `disabled` / `locked` | Copy is `active`. §5.4. |
| E2 | Original is `suspended` / `unclaimed_expired` | 403, no writes. §7.3. |
| E3 | Original is a **static** QR | Allowed. A static duplicate is simply a new static QR; no KV, no short code semantics. |
| E4 | Original's custom domain was released or un-verified | Copy uses the default domain. Do not fail. |
| E5 | Original has an `end_at` already in the past | Copy is created with the same expired window and is therefore born expired. §9.3 — flag prominently rather than silently clearing. |
| E6 | Original's type is no longer entitled | 403. §7.1. |
| E7 | Workspace is at `max_qr` | 402 with the existing upgrade copy. |
| E8 | Plan lookup fails transiently | 503 (inherited from `check_limit`), retryable, never a false upgrade wall. |
| E9 | Original has 6 locales and a large `i18n` block | Succeeds — the original already passed the 96KB KV ceiling and the copy's block is identical in size. Assert rather than assume. |
| E10 | Original has a 50MB PDF | Succeeds on Agency; blocked by the `max_file_size_mb` re-check on a downgraded plan. Watch latency (TRD §8). |
| E11 | Duplicate pressed twice quickly | Two QRs, two `max_qr` slots. Mutations never auto-retry, and the button is disabled while pending, but a determined double-press is a legitimate "I want two copies". |
| E12 | Original deleted between load and create | 404, no writes. |
| E13 | Original is a `review_funnel` on a Free plan | Duplicates fine — `review_funnel` is an ungated type. (Its *responses* are separately paywalled; that is a different, live bug tracked in `FIXES/REVIEW_FUNNEL_RESPONSES_ON_QR_DETAILS_FIX.md`.) |

## 9. Deliberate decisions worth writing down

### 9.1 Snapshot, not link

Stated in NG2 and repeated here because it is the decision users will ask about: editing the
original never changes the copy. If the ask "I want all twelve client QRs to update at once"
arrives, the answer is the template system or a routing rule, not a mutation of this feature's
semantics.

### 9.2 Copy tags by default

Tags are the campaign grouping introduced by `CAMPAIGN_TAGS_ROLLUP`. A duplicate is nearly always
part of the same campaign, so copying is the right default. The counter-risk is rollup pollution —
twelve client QRs all tagged `campaign:spring` when the agency wanted twelve separate campaigns.
v1 copies silently; §14 Q2 holds the checkbox option.

### 9.3 Copy the schedule window

The window is configuration and re-entering it is annoying. The counter-argument is E5: duplicating
an expired campaign QR produces a QR that is born expired and reads as broken.

Decision: **copy it, and make it loud.** The copy's detail page surfaces the inherited window in
its Schedule card as it would for any QR, and where `end_at` is already in the past the QR list
shows the existing **Expired** badge. The user sees the state rather than being surprised by it.
Clearing the window silently would be the worse failure — an agency re-running a campaign with a
contractual end date would lose the end date without noticing.

## 10. Gating & pricing

Ungated on every plan. The fence is `max_qr`, which already exists, is already enforced, and is
already the thing customers upgrade for. Gating the *action* would produce no incremental revenue
(the user simply rebuilds by hand) and a worse product.

No plan-seed change, no new flag, no `FEATURE_ENFORCEMENT` entry, so `test_feature_gate_coverage`
stays green with no edit.

## 11. Success metrics

| Metric | Why | Healthy signal |
|---|---|---|
| Duplicate actions per workspace per week | Adoption | Non-zero within a week on multi-QR workspaces |
| Share of new QRs created by duplication | The workflow's real weight | 15–30% for agency/multi-location workspaces |
| Median time from duplicate → first save of the copy | Did it actually shorten the job | Under 60s |
| Duplicate → edit → save completion rate | A copy nobody edits suggests the naming or the landing page is wrong | >80% |
| 402/403 rate on duplicate | Limit surfaces are unclear, or Duplicate is being used to probe entitlement | Low and flat |
| Support tickets about "my copy has the same link" | The §5.5 copy is not landing | Zero after week two |

## 12. Risks

| Risk | Severity | Mitigation |
|---|---|---|
| Partial duplication leaves an orphan `qr_codes` row with no content | High | Build the entire content payload **before** the first insert and delegate to `create_qr`, which already owns that ordering and its failure modes. TRD §5. |
| `_build_content_from_db_rows` silently drops a field for some type, so copies lose data | High | Audit it against `SELECT_WITH_RELATIONS` **before** building; per-type-family tests; record anything that does not round-trip. TRD §16. |
| File copy doubles storage and busts `max_file_size_mb` accounting | Medium | Pre-flight the size check before copying bytes. |
| A large PDF copy exceeds the 30s client timeout | Medium | Server-side object copy rather than download-and-reupload; measure at 50MB. TRD §8. |
| Duplicate becomes a downgrade-evasion hatch | Medium | §7.1, with a test. |
| A copy inherits stale KV because publish is fire-and-forget | Medium | Publish via `publish_qr` (records `kv_sync_status`, never raises, swept by the cron), never `sync_qr_to_kv` directly. |
| Users assume the copy is reprintable from the original's artwork | Low | §5.5 toast copy. |

## 13. Rollout

Single backend PR then a single frontend PR; the endpoint is inert until a button calls it.
No migration, no Worker deploy, no KV contract change, no plan-seed change. Reverting the frontend
removes a menu item; reverting the backend removes an endpoint nothing else calls.

**Phase 2 candidates, explicitly out of this scope:** bulk duplicate, duplicate-into-workspace,
public API exposure, a duplicate-options dialog (rename, choose folder, include/exclude tags).

## 14. Open questions

1. **Copy or clear the schedule window?** §9.3 says copy, loudly. Revisit if support sees
   "my duplicate doesn't work" tickets that resolve to an inherited expiry.
2. **Copy tags silently, or offer a checkbox?** v1 copies. Revisit if agencies report campaign-rollup
   pollution — the metric is "distinct QRs per campaign tag" rising without a matching campaign count.
3. **Should Duplicate appear on the public API?** Not in v1 (NG4). It is one route to add later.
4. **Should a duplicate-options dialog replace the one-press action?** Only if the metrics in §11
   show a high rename-immediately-after rate. One press is the feature; a dialog is a smaller feature.
