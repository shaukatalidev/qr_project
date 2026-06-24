# PRD — Campaign Tags + Multi-QR Rollup & Compare

**Status:** Draft · **Author:** Product · **Date:** 2026-06-24
**Priority:** Analytics-wave companion to the funnel work — the "organize by campaign, not by folder" wedge. Low-risk, mostly-additive, high pull from agencies.
**Tiers:** Pro & Agency. Tagging itself (CRUD + filter) is **ungated** (organization is table-stakes); the **campaign rollup analytics + head-to-head compare** views gate behind the existing `advanced_analytics` flag (already enforced, Pro+).
**Plan flags:** `advanced_analytics` (bool, **reused** — already `enforced` in `subscription.py`'s `FEATURE_ENFORCEMENT`; gates `/analytics` today). **No new flag is introduced**, so `FEATURE_ENFORCEMENT` and the plan seed need no edit and `test_feature_gate_coverage` stays green.
**Split from:** parent analytics surface (`/org/[slug]/(dash)/analytics`) and the QR list/folder system (`MyQRCodes.tsx`, `folder.py`). Sibling to `SCAN_CONVERSION_FUNNEL_PRD.md` (shares the `qr_scan_events`-as-denominator discipline).

**Rev (2026-06-24, post eng-review):** Corrected the headline perf claim — the reused `_fetch_windowed_events` is workspace-wide and hard-caps at 50k rows *before* the Python `qr_id` filter, so on a large workspace a tag's events can be truncated out of the cap (silently breaking the ±1% accuracy goal); R1 now mandates pushing `qr_id IN (...)` into the DB query (TRD §3.2). Flagged the duplicate-index footgun: the `(qr_id, scanned_at)` index already exists as `idx_qr_scan_events_qr_id_scanned_at` (0007), so the migration must NOT create a second differently-named copy. Deferred `list_links` conversion in compare (no backend-readable per-link click counter; `lead_form` stays, sourced from `qr_lead_submissions`). Verified: no new flag / no flag-flip / no `FEATURE_ENFORCEMENT` edit (reuses already-`enforced` `advanced_analytics`), no email→no DMARC gate, no cron→no prod-worker gate, no Worker/KV change, explicit `workspace_id` tenant filters (service role bypasses RLS).

---

## 1. TL;DR / Summary

Folders organize QRs **one way** — a strict, single-parent tree. But a real campaign cuts *across* folders: a "Summer 2026" launch has a poster QR (in `/Print`), an Instagram-bio QR (in `/Social`), and a packaging vCard (in `/Products`). Today there is no way to say "these three QRs are one campaign" and see them rolled up together, and no way to compare two QRs head-to-head.

This PRD adds **cross-folder tags** — free-form, namespaced labels like `campaign:summer-2026`, `channel:print`, `client:acme` — that any QR can carry many of. On top of tags it adds two read-only analytics surfaces, both Pro-gated under the existing `advanced_analytics` flag:

1. **Campaign Rollup** — pick a tag (or `key:*` namespace) and get one aggregated view: total scans, unique scans, device/geo/time-series, and a member-QR breakdown, all summed across whatever folders those QRs live in.
2. **Head-to-Head Compare** — pick 2–4 QRs (or two tags) and see their KPIs side-by-side: scans, uniques, conversion (if a `lead_form`/`list_links` is involved), trend lines on one chart. This generalizes the existing A/B-results card from "one website QR's two variants" to "any N QRs."

Phase 1 needs **zero edge/Worker changes** — tags never touch KV or the scan hot path. It is one migration (a `tags` table + a `qr_tags` join), tag CRUD endpoints, two new aggregate queries that group the already-windowed `qr_scan_events` read by tag, and frontend surfaces that extend the existing QR table and analytics page. The rollup is strictly **READ-only**, so the known non-atomic `qr_scan_counters` write-path gap does not affect it (and we read raw events for accuracy anyway).

## 2. Problem & Motivation

**Folders force a single hierarchy onto a multi-dimensional reality.** The `folders` table (workspace-scoped, `parent_id`-nested, one `folder_id` per QR on `qr_codes`) makes every QR live in exactly one place. But agencies think in *campaigns* and *channels*, which are orthogonal to where a QR is filed. A print poster and a social bio link belong to the same campaign yet must live in different folders. There is no second axis. This is the most common organizational complaint from multi-client users and the reason power users keep a parallel spreadsheet mapping QRs to campaigns.

**There is no campaign-level rollup.** Verified in the repo: `scan.py` exposes per-QR analytics (`/analytics/qr/{id}`) and *whole-workspace* summaries (`/analytics/summary`, `/analytics/top`, `/analytics/devices`, `/analytics/top-countries`, `/analytics/hourly`), but nothing in between. A marketer who wants "how did the Summer campaign do" has to open each QR one at a time and add the numbers by hand. The `/analytics/top` endpoint already aggregates raw events per QR (`_fetch_windowed_events` → group by `qr_id`) — the rollup is the same machinery grouped by **tag** instead of by **QR**.

**Comparison is locked to one feature.** `get_qr_ab_results` (scan.py ~line 486) already does a head-to-head — but only for the two `variant_key` arms of a single `website` QR with A/B testing on. The product has no way to ask "did the poster or the flyer pull better?" across two *separate* QRs. The analytics page's existing top-QR table is a flat leaderboard; it cannot pivot to "compare these specific two."

**The seams are clean and additive.** Folders prove the workspace-scoped-organization pattern (`folder.py`, `CreateFolderModal`, `FolderSection`). The windowed-events aggregator (`_fetch_windowed_events` + `_retention_cutoff_iso`) proves the read pattern that respects `analytics_retention_days`. The A/B results card proves the compare-UI pattern. We are wiring three existing patterns together, not inventing infrastructure — exactly the kind of cheap, retention-driving analytics moat the strategic audit calls for.

## 3. Goals & Non-Goals

**Goals**
- A **tags system**: namespaced (`key:value`) or flat string tags, workspace-scoped, many-to-many with QRs. Create/rename/delete tags; attach/detach on a QR; filter the QR list by tag.
- A **campaign rollup** aggregate endpoint (`GET /analytics/rollup?tag=…`) that sums `qr_scan_events` across all QRs carrying a tag, within the plan's retention window, returning the same KPI shape as the workspace summary plus a per-QR member breakdown.
- A **head-to-head compare** endpoint (`GET /analytics/compare?qr_ids=…` or `?tags=…`) returning aligned per-entity KPI rows + a shared time-series for one chart.
- Frontend: a tag filter/chip UI on the QR list, a tag editor on QR detail and in the builder, a **Campaigns** view on the analytics page, and a compare drawer.
- Reuse `advanced_analytics` for the two analytics surfaces; **no new flag, no seed edit, no `FEATURE_ENFORCEMENT` change**.

**Non-Goals**
- **No edge/Worker/KV changes.** Tags are an org/analytics concept; they never enter `build_kv_content`, `build_entitlements`, or the scan path. The Worker is untouched.
- **No tag-based routing** (e.g. "redirect by campaign") — tags are descriptive, not behavioral. *(future)*
- **No cross-day/cross-device attribution** — same accuracy posture as the funnel PRD; `session_id` is a daily-rotated hash.
- **No auto-tagging via AI** in v1. A "suggest campaign tags from QR names" Haiku helper is a *(future)*, backend-side-only, confirm-before-save idea — not Phase 1.
- **No tag-scoped permissions** — tags inherit the workspace role model; no per-tag ACLs.
- **No new email/report surface** (so no DMARC dependency); rollup export is an in-app CSV download, not a sent email. *(Scheduled tag reports are a future tie-in to `SCHEDULED_REPORTS_ALERTS_PRD.md`.)*

## 4. Target Users & Personas

| Persona | Who | Job-to-be-done | Today's pain |
|---|---|---|---|
| **Agency Account Lead ("Marcus")** | Runs 30 client campaigns | Report "Summer campaign: 8,400 scans across 6 QRs" to a client | Opens 6 QRs, adds by hand; folders can't span channels |
| **Performance Marketer ("Priya")** | In-house growth, print + social | Compare poster vs flyer vs bio-link CTR for the same launch | No way to compare separate QRs; A/B only works inside one QR |
| **Multi-brand Operator ("Sana")** | Manages several brands in one workspace | Slice analytics by `client:acme` vs `client:globex` | Single folder tree forces one axis; can't filter by client |
| **SMB owner** | A handful of QRs | Loosely group "spring menu" QRs without rebuilding folders | Folders feel heavyweight for light grouping |

Primary buyer is the **agency / multi-client operator** (Pro & Agency) — the segment that thinks natively in campaigns and channels and whose retention rises the moment their reporting cadence lives inside Qravio instead of a spreadsheet.

## 5. User Stories

- As an **agency lead**, I want to tag six QRs `campaign:summer-2026` even though they live in different folders, so that I can pull one rollup of the whole campaign.
- As a **marketer**, I want to filter my QR list to `channel:print`, so that I can find every print asset across folders in one view.
- As a **marketer**, I want to select a poster QR and a flyer QR and compare their scans and trend on one chart, so that I can decide which creative to reprint.
- As an **agency on multiple clients**, I want a rollup scoped to `client:acme`, so that I can hand a client only their numbers.
- As **any Pro user**, I want to export a campaign rollup as CSV, so that I can drop it into a client deck.
- As a **Free/Starter user**, I want to still create and filter by tags (organization is free), but see the campaign rollup chart behind an upgrade gate, so that I understand what Pro unlocks.
- As a **workspace owner**, I want to rename or delete a tag in one place and have it update everywhere, so that I don't have orphaned labels.

## 6. UX / Product Flow

**6.1 Tagging a QR — builder + QR detail**
1. In the QR builder's final step and on the QR detail page (`QRDetails.tsx`, beside the existing metadata/folder controls), a **Tags** input (shadcn combobox + chips) lets the user type a tag. Typing `campaign:` offers existing values in that namespace as autocomplete; a free string creates a flat tag.
2. Tags render as removable chips. Color is derived deterministically from the tag `key` (all `campaign:*` one hue, `channel:*` another) — no per-tag color picker in v1.
3. Attaching/detaching writes only to `qr_tags` (a normal authed PATCH). **No `write_to_kv` call** — tags are not edge data, so a tag change does not trigger a KV resync (explicitly confirmed in scope to keep the Worker untouched).

**6.2 Filtering the QR list — `MyQRCodes.tsx`**
1. The existing folder sidebar (`FolderSection.tsx`) gains a **Tags** group below folders: a list of tags with counts.
2. Selecting one or more tags filters `QRCodesTable.tsx` to QRs carrying them (AND within a key, OR across — TBD in Open Questions). Folder filter and tag filter compose (folder ∩ tags).
3. A "Manage tags" affordance opens a small modal (mirrors `CreateFolderModal`/`DeleteFolderModal`) to rename/delete tags workspace-wide.

**6.3 Campaign Rollup — `/org/[slug]/(dash)/analytics` (Pro-gated)**
1. The analytics page gains a **Campaigns** tab/section. Free/Starter users see it behind the existing `advanced_analytics` `UpgradeGate` (same gate that protects the page's rich views today).
2. The user picks a tag (or a `key:*` namespace, e.g. all `campaign:*` as a leaderboard). The page renders one rollup: headline **total scans / unique scans**, the existing device-donut + country-bar + hourly + daily-trend components (reused), and a **member-QR table** (the existing top-QR table component, scoped to the tag's members) showing each QR's share.
3. The rollup honors the page's `7/30/90/365` range selector and is **clamped to `analytics_retention_days`** via the same `get_limit()` path `scan.py` already uses — a Pro user cannot read beyond 90 days even via a tag.
4. A **Download CSV** button hits `GET /analytics/rollup?tag=…&format=csv`.

**6.4 Head-to-Head Compare — compare drawer**
1. From the QR list (multi-select checkboxes) or from the rollup member table, "Compare" opens a drawer with 2–4 selected QRs.
2. The drawer shows a per-QR KPI grid (scans, uniques, top country, top device) and **one overlaid daily-trend chart** with a line per QR. If a selected QR is a `lead_form`, its conversion rate column appears (submissions from `qr_lead_submissions` ÷ scans of that QR); otherwise it's blank, not zero. (`list_links` conversion is deferred in v1 — no backend-readable per-link click counter exists; see TRD §3.2.)
3. Compare can also take **two tags** ("campaign:a vs campaign:b") for a campaign-vs-campaign view, reusing the same drawer with aggregated lines.
4. This generalizes `ABResultsCard` (which compares two `variant_key` arms of one QR) to N independent QRs — same chart idiom, different data source.

## 7. Scope

**In scope (v1 / Phase 1 — no edge changes)**
- Migration `0022`: `tags` table + `qr_tags` join (+ the index on the join, see §11/§12).
- Tag CRUD endpoints in a new `tags.py` router (create/list/rename/delete tags; attach/detach to a QR), permission-gated via `require_can_*`.
- `GET /analytics/rollup?tag=&range=&format=` and `GET /analytics/compare?qr_ids=|tags=&range=` in `scan.py`, both behind `_require_advanced_analytics`, both reading windowed `qr_scan_events` (never the lossy counter).
- FE: tag input on builder + QR detail; tag filter + manage-tags modal on the QR list; Campaigns rollup section + compare drawer on/near the analytics page; `useTags` + `useCampaignRollup` + `useQRCompare` hooks.
- CSV export of a rollup.
- Tagging CRUD/filter **ungated**; rollup + compare **gated on existing `advanced_analytics`**.

**Out of scope / Future**
- Tag-based routing or redirects.
- AI tag suggestions (backend-side Haiku, confirm-before-save) — *(future)*.
- Tag-scoped roles/sharing.
- Scheduled/emailed campaign reports (ties to `SCHEDULED_REPORTS_ALERTS`/`SHAREABLE_CLIENT_REPORTS`) — *(future)*.
- Bulk-tag on import / API tag management — *(future, ties to `api_public`)*.
- Conversion/funnel inside the rollup beyond a per-member conversion column (the full funnel is `SCAN_CONVERSION_FUNNEL_PRD.md`).
- Real-time rollup updates (Phase 1 is query-on-load + cache).

## 8. Pricing & Packaging

| Surface | Tier | Flag |
|---|---|---|
| Create/rename/delete tags, attach/detach, filter QR list by tag | **All tiers (ungated)** | — (organization is table-stakes; like folders, which are seeded on at Starter+ but tags carry no plan cost) |
| Campaign rollup analytics + CSV export | **Pro & Agency** | `advanced_analytics` (existing, already `enforced`) |
| Head-to-head compare (2–4 QRs / two tags) | **Pro & Agency** | `advanced_analytics` (existing, already `enforced`) |

- **Why no new flag:** the rollup and compare views *are* advanced analytics; they live on the already-gated `/analytics` page and call the already-gated read pattern. Reusing `advanced_analytics` means **no migration flag-flip, no `FEATURE_ENFORCEMENT` registry entry, no plan-seed JSON edit** — the three prior specs that mis-handled the case-sensitive flag-flip can't reintroduce that bug here because there is no flip. `test_feature_gate_coverage` stays green untouched.
- **Why keep tagging itself ungated:** charging for the *ability to organize* punishes exactly the multi-client power users we want to retain, and folders set the precedent that organization isn't the paywall — *analytics on top of it* is. Free users tagging their QRs creates the data that makes the rollup tease compelling.
- **Upsell angle:** A Free/Starter user who tags QRs and clicks **Campaigns** hits the `UpgradeGate`: "You've grouped 4 QRs into `campaign:summer`. See them rolled up — upgrade to Pro." The user has already done the work; the gate sits exactly where the payoff is. The compare drawer shows the same gate for non-Pro.

## 9. Success Metrics & KPIs

**Adoption (first 30 days post-GA)**
- ≥ 35% of active workspaces create ≥1 tag.
- ≥ 50% of multi-QR (≥5 QRs) workspaces use at least one `campaign:` or `channel:` namespace.
- Median tags-per-tagged-QR ≥ 2 (proves the multi-axis value over folders).

**Engagement**
- ≥ 45% of Pro/Agency workspaces with ≥2 tagged QRs open the Campaigns rollup at least once.
- ≥ 20% of rollup viewers export a CSV (proxy for "used in a client report").
- ≥ 25% of Pro QR-list sessions use the tag filter.

**Revenue / retention**
- Free/Starter → Pro upgrade rate **+10%** among workspaces that hit the Campaigns `UpgradeGate` after tagging (vs non-taggers).
- Pro logo churn **−8%** among workspaces that exported a rollup ≥2× in a month.

**Quality / performance**
- Rollup totals reconcile within **±1%** of a manual `qr_scan_events` count for the tagged QR set over the same window (no double-count when a QR carries multiple selected tags).
- Rollup endpoint p95 < 700ms for a 90-day window on a 50-QR workspace (with the join indexed and the window bounded by `get_limit`).
- Zero Worker deploys, zero KV writes attributable to this feature (verifies the no-edge-change guarantee).

## 10. Rollout Plan

**Phase 0 — Schema + tag CRUD (internal)**
- Apply migration `0022` by hand in Supabase SQL editor (BEGIN/COMMIT, idempotent `IF NOT EXISTS`). Build `tags.py` CRUD + attach/detach. No analytics, no FE yet. Smoke-test on a seed workspace.

**Phase 1 — Tagging UI (ungated, GA-able on its own)**
- Tag input on builder + QR detail; tag filter + manage modal on the QR list; `useTags` hook. Ship behind a FE constant flag for a short internal pass, then GA. This is independently shippable and low-risk.
- **Acceptance:** a QR in `/Print` and a QR in `/Social` both carry `campaign:summer`; filtering by that tag returns both; rename/delete propagate; no KV write fires on tag change (verify worker KV unchanged).

**Phase 2 — Rollup + Compare analytics (Pro+)**
- `GET /analytics/rollup` + `GET /analytics/compare` behind `_require_advanced_analytics`; Campaigns section + compare drawer + CSV export. Validate rollup totals against a hand-computed spreadsheet on a seed workspace. Beta with 3–5 agencies from the Pro base for ~1 week, then GA.
- **Acceptance:** a Pro workspace's `campaign:summer` rollup sums all member QRs' scans within the retention window; numbers reconcile ±1% with raw events; a Free user sees the `UpgradeGate` and `GET /analytics/rollup` returns 403 for non-Pro; compare overlays 3 QRs' trends; CSV downloads; results are clamped to `analytics_retention_days`.

**GA gates / non-gates**
- **No DMARC gate** — this feature sends no email (CSV is an in-app download).
- **No prod-worker-deploy gate** — this feature adds no cron and no Worker code; nothing to deploy at the edge.
- The only deploy dependency is applying migration `0022` and the standard backend + frontend deploys.

## 11. Risks, Edge Cases & Open Questions

**R1 — Aggregation query performance on large workspaces (known risk).** The rollup resolves a tag → QR-id set (`qr_tags` join) then aggregates `qr_scan_events` for those ids over the window. **Mitigations:** (a) index `qr_tags(tag_id)` and `qr_tags(qr_id)` (migration `0022`); (b) the events read is **bounded by `analytics_retention_days`** via `_retention_cutoff_iso`/`get_limit` — no unbounded scans; (c) push `qr_id IN (...)` into the **DB query** (a new `qr_id`-scoped windowed read, *not* the bare workspace-wide `_fetch_windowed_events` which caps at 50k workspace rows before any qr_id filter — see TRD §3.2), so the 50k cap bounds the tag's rows (not the workspace's) and the existing `idx_qr_scan_events_qr_id_scanned_at` from migration `0007` drives the scan; (d) a 60s response cache like the other analytics endpoints. Validate p95 on a 50-QR / 90-day seed. **Note:** do NOT add a second `(qr_id, scanned_at)` index — `0007`'s already exists; a differently-named copy is a redundant duplicate index (`IF NOT EXISTS` de-dupes by name only).

**R2 — Non-atomic `qr_scan_counters` is irrelevant here (known risk, neutralized).** The counters' read-modify-write can lose increments, but the rollup and compare are **strictly READ-only and read raw `qr_scan_events` rows**, not the denormalized counter — so the known gap cannot corrupt rollup numbers. Document explicitly that rollup/compare MUST use events, never counters, to match the funnel PRD's accuracy posture.

**R3 — Double-count across multiple selected tags.** If a QR carries both `campaign:summer` and `channel:print` and the user selects both, the QR's scans must count **once**. Resolve to a **distinct `qr_id` set** before aggregating; never sum per-tag totals.

**R4 — Tag explosion / hygiene.** Free-form tags invite typos (`campaign:summer` vs `Campaign:Summer`). **Mitigation:** normalize on write (lowercase the `key`, trim, collapse whitespace; preserve value case for display but match case-insensitively); cap tags-per-workspace and tags-per-QR (e.g. 200 / 20); rename/delete in the manage modal. Enforce a `UNIQUE(workspace_id, lower(name))` constraint.

**R5 — Retention bypass via tags.** A Pro user must not read beyond `analytics_retention_days` by going through a tag. The rollup/compare **reuse the exact `get_limit()` clamp** `scan.py` already applies — no new window path is introduced.

**R6 — Bots inflate rollup denominators.** `device_type === 'bot'` rows are recorded. Offer an "exclude bots" default (consistent with the funnel PRD) so a campaign's conversion/quality isn't distorted. Decide default on.

**R7 — Permissions.** Tag CRUD and attach/detach go through `require_can_update`/`require_can_create`/`require_can_delete`; rollup/compare reads through `require_can_read` **and** `_require_advanced_analytics`. The service-role client bypasses RLS, so every query MUST filter by `workspace_id` explicitly (no implicit isolation).

**Open Questions**
1. Multi-tag filter semantics: AND across all selected tags, or OR? *Recommend OR across tags by default, with a future AND toggle — OR matches "show me everything in any of these campaigns."*
2. Cap on compare entities — 4 lines readable on one chart; allow up to 6? *Recommend 4 for v1.*
3. Should `campaign:*` namespace get first-class treatment (a dedicated "Campaigns" leaderboard) vs all tags being equal? *Recommend treating `campaign:` as a soft convention surfaced in the UI, not a hard schema distinction.*
4. Exclude bots from rollup by default? *Recommend yes.*
5. Should deleting a tag that's the sole grouping for a rollup warn the user? *Recommend a confirm modal showing affected QR count (mirror `DeleteFolderModal`).*

## 12. Dependencies

- **Folders (shipped):** `folder.py`, `folders` table, `qr_codes.folder_id`, `FolderSection.tsx`, `CreateFolderModal`/`DeleteFolderModal` — the organizational pattern tags extend (a second, many-to-many axis).
- **Scan pipeline (shipped):** `qr_scan_events` (raw rows with `qr_id`, `scanned_at`, `session_id`, geo/device) — the rollup/compare denominator. `_fetch_windowed_events` + `_retention_cutoff_iso` in `scan.py` are the read primitives.
- **Gating engine (shipped):** `advanced_analytics` already `enforced` in `subscription.py` `FEATURE_ENFORCEMENT` (line 439) and seeded true for Pro/Agency in `0009`; `check_feature`/`get_limit` (async; await); `canAccessFeature` in `src/lib/plan-features.ts`. **No edits to gating config.**
- **Analytics UI (shipped):** `/analytics/page.tsx`, `useAnalytics*` hooks + `analyticsKeys` factory, the device-donut/country-bar/hourly/daily-trend + top-QR-table components (reused for the rollup), `ABResultsCard` (the compare-UI ancestor), `QRDetails.tsx` (tag editor host).
- **QR list UI (shipped):** `MyQRCodes.tsx`, `QRCodesTable.tsx`, `QRCard.tsx` — host the tag filter + chips + multi-select.
- **Migration `0022`** (reserved slot; current highest applied = `0013`, roadmap reserves `0014–0018`, this feature claims `0022`): ships **only this phase's schema** — `tags(id, workspace_id, name, created_at)` with `UNIQUE(workspace_id, lower(name))`; `qr_tags(qr_id, tag_id)` join with PK `(qr_id, tag_id)` and indexes on both columns. **No flag-flip** (reuses `advanced_analytics`), so the migration carries **no `UPDATE plans … jsonb_set`** block at all — avoiding the case-sensitive flag-flip footgun entirely. BEGIN/COMMIT-wrapped, idempotent `IF NOT EXISTS`. Applied by hand in the Supabase SQL editor.
- **No Worker / KV dependency.** Tags never enter `cloudflare_kv.py`, `build_kv_content`, `build_entitlements`, or `build_pixels`. No `wrangler deploy`. No cron.
- **No email dependency** → **no `_dmarc.qravio.app` gate** (CSV is an in-app download, not a sent report).

### Appendix — Key Files

| Concern | File |
|---|---|
| Tag CRUD + attach/detach | new `qr_backend/src/api/routes/tags.py` (mirror `folder.py`; register in `src/api/endpoints.py`) |
| Rollup + compare endpoints + gate | `qr_backend/src/api/routes/scan.py` (new `/analytics/rollup`, `/analytics/compare`; reuse `_require_advanced_analytics`, `_fetch_windowed_events`, `_retention_cutoff_iso`, `get_limit`) |
| Scan events source (denominator) | `qr_scan_events` (raw rows); **never** `qr_scan_counters` (non-atomic) |
| Permissions | `qr_backend/src/api/dependencies/permissions.py` (`require_can_read/create/update/delete`) |
| Gating (no edits) | `qr_backend/src/api/routes/subscription.py` (`advanced_analytics` already `enforced`); `qr_frontend/src/lib/plan-features.ts` |
| Tag input UI | `qr_frontend/src/components/org/qrs/details/` (QR detail) + QR builder final step under `src/components/qr-generator/` |
| Tag filter + manage modal | `qr_frontend/src/components/org/qrs/MyQRCodes.tsx`, `components/QRCodesTable.tsx`, `components/FolderSection.tsx`; new tag-manage modal (mirror `CreateFolderModal`/`DeleteFolderModal`) |
| Campaign rollup + compare UI | `qr_frontend/src/app/org/[slug]/(dash)/analytics/page.tsx`, `src/components/org/analytics/` (reuse existing chart + top-QR-table components, `ABResultsCard` idiom) |
| Hooks | `qr_frontend/src/hooks/useTags.ts`, new `useCampaignRollup`/`useQRCompare` in `src/hooks/useAnalytics.ts` (extend `analyticsKeys`) |
| Migration | `qr_backend/migrations/0022_campaign_tags_rollup.sql` (tags + qr_tags + indexes; **no flag-flip**) |
