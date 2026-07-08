# Grand Billing-Enforcement Plan — QR SaaS

> Authoritative checklist for implementing plan enforcement across Backend (FastAPI), Frontend (Next.js), and Cloudflare Worker. Built from the plan/feature catalog + 4 layer audits (backend, frontend, worker, database).

**Note on plan count:** the task brief says "5 plans," but the catalog defines **6** (`free`, `lite`, `starter`, `pro`, `business`, `agency`). This document uses all 6 as the source of truth. Flagging the discrepancy explicitly.

## Decisions (locked 2026-06-07)

1. **Scope = all 6 plans as-is** — `free`, `lite`, `starter`, `pro`, `business`, `agency`. Enforce the limits exactly as defined in `plans.features` today.
2. **`max_scans` = monthly reset** — add `current_period_start` and reset the scan count each billing period (matches the UI copy). This makes the billing-period plumbing in Cross-cutting #5 / Phase 1 a hard prerequisite, not optional.
3. **Single source of truth = `plans.features` JSONB (backend DB)** — do NOT add a `plan_limits` table. The frontend constant (`plan-features.ts` / `constants/pricing.ts`) must be generated from / validated against the DB so the two can't drift.

---

## 1. Plan Matrix — "What should be true"

Values per `plans` row. `-1` / "unlimited" means no cap. Quota source columns: `max_qr` and `max_scans` are top-level integer columns on `plans`; **everything else lives in `plans.features` JSONB**.

| Feature / Quota | Free | Lite | Starter | Pro | Business | Agency |
|---|---|---|---|---|---|---|
| `max_qr` (dynamic only) | 3 | 5 | 15 | 50 | 200 | unlimited |
| `max_scans` (all-time*) | 500 | unlimited | unlimited | unlimited | unlimited | unlimited |
| `folders` | ❌ | ❌ | ✅ | ✅ | ✅ | ✅ |
| `max_members` | 1 | 1 | 3 | 5 | 10 | unlimited |
| `custom_domain` (bool) | ❌ | ❌ | ❌ | ✅ | ✅ | ✅ |
| `max_custom_domains` | 0 | 0 | 0 | 1 | 3 | unlimited |
| `max_workspaces` | 1 | 1 | 1 | 3 | 10 | unlimited |
| `dynamic_qr_types` | 2: website, vcard_plus | 3: +pdf | 5: website, pdf, vcard_plus, list_links, business | 8: +images, video, mp3 | 8 (same as Pro) | 8 (all) |
| `max_file_size_mb` | 2 | 5 | 5 | 20 | 20 | 50 |
| `advanced_analytics` | ❌ | ❌ | ❌ | ✅ | ✅ | ✅ |
| `password_protection` | ❌ | ❌ | ✅ | ✅ | ✅ | ✅ |
| `ab_testing` | ❌ | ❌ | ❌ | ✅ | ✅ | ✅ |
| `analytics_retention_days` | 7 | 30 | 30 | 90 | 365 | 730 |
| `bulk_generation` | ❌ | ❌ | ❌ | ✅ | ✅ | ✅ |
| `lead_forms` (inert) | ❌ | ❌ | ❌ | ✅ | ✅ | ✅ |
| `retargeting_pixels` (inert) | ❌ | ❌ | ❌ | ✅ | ✅ | ✅ |
| `api_access` (inert) | ❌ | ❌ | ❌ | ❌ | ✅ | ✅ |
| `api_calls_per_month` (inert) | — | — | — | — | 5000 | 25000 |
| `sso` (inert) | ❌ | ❌ | ❌ | ❌ | ❌ | ✅ |
| `white_labeling` | ❌ | ❌ | ❌ | ❌ | ❌ | ✅ |

\* `max_scans` is enforced as an **all-time** total today (no billing-period window), despite UI/docstrings calling it "monthly." See Bug #2.

---

## 2. Enforcement Matrix — "The gap map"

Legend: ✅ enforced · ⚠️ partial / fail-open · ❌ missing · — n/a (no manifestation at this layer)

| Feature | Backend | Frontend | Worker | Where (key refs) |
|---|---|---|---|---|
| `max_qr` | ✅ | ⚠️ | — | BE: `qr.py:1185-1209` + `subscription.py:197-267`. FE: `QRTypeSelector.tsx:30-31,155-166,190-197` (warns; no final-submit gate). Bulk path ungated. |
| `max_scans` | ⚠️ | ⚠️ | ⚠️ | BE: `internal.py:477-572` (try/except swallows; all-time; re-enable bug). FE: `BillingPlans.tsx:560-577`, `UsageTracker.tsx` (display, mislabeled "Monthly"). Worker: `index.js:185-186` (reactive only, race window). |
| `folders` | ❌ | ❌ | — | BE: `folder.py:119-165` (no `check_feature`). FE: `MyQRCodes.tsx:62-70,204-210`, `CreateFolderModal.tsx`. |
| `max_members` | ❌ | ❌ | — | BE: `workspace.py:302-370` `invite_member()`. FE: `TeamManagement.tsx:158-167`, `InviteUserModal.tsx`. |
| `custom_domain` (bool) | ✅ | ✅ | ✅ | BE: `custom_domain.py:184-195`. FE: `domains/page.tsx:311-313`, `domain-selector.tsx:56-57`. Worker: tenant isolation `index.js:126-179`. (KV stale on downgrade — Bug #11.) |
| `max_custom_domains` (count) | ❌ | ❌ | — | No count check after boolean gate (`custom_domain.py`). FE: none. |
| `max_workspaces` | ❌ | ❌ | — | No `POST /workspaces` gate; auto-create path `folder.py:134-148`. FE: `useWorkspaces.ts`. |
| `dynamic_qr_types` | ❌ | ⚠️ | — | BE: `qr.py` create has no type gate. FE: content-type components gate `isLoggedIn` only, **not plan** (e.g. `PDFContent.tsx:270-277`, `VideoContent.tsx:70-77`). |
| `max_file_size_mb` | ⚠️ | ⚠️ | — | BE: flat 20 MB `file_utils.py:17` + `storage.py:194`. FE: hardcoded `PDFContent.tsx:116-120` (20), `VideoContent/MP3` (50). Per-plan never read. |
| `advanced_analytics` | ❌ | ⚠️ | — | BE: `scan.py` `/analytics/*` ungated. FE: only `recent-scans-list.tsx:72-73`; main `analytics/page.tsx` ungated. |
| `password_protection` | ❌ | ⚠️ | ✅ | BE: `qr.py:2198-2208` PATCH ungated. FE: `password-protection-card.tsx:23` (stale "Pro" label). Worker: `index.js:190-197` enforces KV flag regardless of plan. |
| `ab_testing` | ✅ | ✅ | ⚠️ | BE: `qr.py:1241-1246`, `qr.py:2371-2376`, `scan.py:410-415`. FE: `ab-testing-card.tsx:75`, `WebsiteContent.tsx:95-97`. Worker: `websiteRedirect.js:28-68` no defense-in-depth flag. |
| `analytics_retention_days` | ❌ | ❌ | — | BE: no date filter in `scan.py`. FE: `useAnalytics.ts:59-70` (hardcoded days). |
| `bulk_generation` | ✅ | ⚠️ | — | BE: `qr.py:1969-1974`. FE: gate works `bulk/page.tsx:47` but `handleGenerate` (`:79-112`) is **mock** — never calls API. |
| `white_labeling` | ❌ | ❌ | ❌ | No `check_feature` anywhere. Branding hardcoded in 15+ worker templates (e.g. `listLinks/classicTemplate.js:31`, `passwordGatePage.js:93`). |
| `lead_forms` | — | — | — | Inert — not built. |
| `retargeting_pixels` | — | — | — | Inert — not built. |
| `api_access` | — | — | — | Inert. FE `developers/page.tsx:6` calls `notFound()`. |
| `api_calls_per_month` | — | — | — | Inert. |
| `sso` | — | — | — | Inert — not built. |

---

## 3. Per-Feature Enforcement Checklist

### `max_qr` (mostly done)
- [x] **BE** — `check_limit('max_qr')` on single create (`qr.py:1185-1209`), fail-closed 503 on error.
- [ ] **BE** — Add running `max_qr` count check inside bulk loop (`qr.py:1969-1974`); currently only `check_feature('bulk_generation')` → Pro can overshoot (e.g. 48 → +10).
- [ ] **BE** — Fix count query to exclude `status='disabled'` rows (`subscription.py` count) so plan-disabled QRs don't block creation (DB audit, low).
- [ ] **FE** — Add a secondary gate on the builder final-submit / `BuilderPageContent` (URL `?type=` bypass leaves only backend protecting; `QRTypeSelector.tsx` doesn't block "Next Step").
- [ ] **FE** — Relabel "Monthly Scans"/usage copy (see `max_scans`).
- **Worker** — n/a.

### `max_scans` (partial; has critical bugs)
- [ ] **BE (CRITICAL)** — Fix re-enable status mismatch: `_enforce_scan_limit` writes `status='disabled'` (`internal.py:540`) but `_reenable_dynamic_qrs_for_subscription` (`razorpay_routes.py:1025`, also `mor_routes.py:260`) only re-enables `status='inactive'`. Change to `.in_('status', ['inactive','disabled'])`.
- [ ] **BE (CRITICAL)** — Re-enable must also call `write_to_kv()` for each re-enabled QR; today KV stays `disabled` even if DB is fixed.
- [ ] **BE** — Decide semantics: all-time vs billing-period. If monthly, add `current_period_start` and filter `qr_scan_events.scanned_at` (see Cross-cutting #5). Docstring `subscription.py:76` says "per billing period" but query has no date filter.
- [ ] **BE** — Reconsider swallowing all exceptions in `internal.py:469-472` (fail-open on enforcement error).
- [ ] **BE/DB** — Add index on `qr_scan_events(workspace_id)`; the all-workspace `COUNT(*)` is a full scan.
- [ ] **FE** — Fix mislabeled "Monthly Scans" → all-time (`org/UsageTracker.tsx:66`, `dashboard/UsageTracker.tsx:73`); add a "your QRs are paused" alert on dashboard + QR list (today only `BillingPlans.tsx:560-577`).
- [ ] **Worker** — Fix `scanLimitPage.js:124` copy ("monthly" + "reactivated on renewal" — both false today). Optionally add KV-side count for proactive blocking (see Cross-cutting #3).
- [ ] **Worker** — Remove dead `getDisabledPage` import (`index.js:7`) and dead `status='paused'` branch (`index.js:181`).

### `folders` (missing both layers)
- [ ] **BE** — Add `check_feature(workspace_id, 'folders', db)` to `create_folder()` (`folder.py:119-165`).
- [ ] **FE** — Gate "Create Folder" button/modal via `canAccessFeature(subscription,'folders')` (`MyQRCodes.tsx:62-70,204-210`, `CreateFolderModal.tsx`).
- **Worker** — n/a.
- *Severity disagreement: backend audit=low, DB audit=medium, frontend audit=high. Treat as medium/high (Free/Lite leak).*

### `max_members` (missing both layers)
- [ ] **BE** — In `invite_member()` (`workspace.py:302-370`), count current `workspace_members` + pending invites and compare to `features->>'max_members'` before issuing invite; also enforce in `accept_invitation()`.
- [ ] **FE** — Gate "Invite Member" button on member count vs plan limit (`TeamManagement.tsx:158-167`, `InviteUserModal.tsx`).
- **Worker** — n/a.

### `custom_domain` boolean (done)
- [x] **BE** — `check_feature('custom_domain')` (`custom_domain.py:184-195`).
- [x] **FE** — `domains/page.tsx:311-313`, `domain-selector.tsx:56-57`.
- [x] **Worker** — cross-tenant isolation `index.js:126-179`.
- [ ] **BE/Worker** — On downgrade, delete `domain:<hostname>` KV entry (no handler today — Bug #11).

### `max_custom_domains` (count missing)
- [ ] **BE** — After boolean gate passes, `COUNT(custom_domains WHERE workspace_id=?)` vs `features->>'max_custom_domains'` (`custom_domain.py`).
- [ ] **FE** — Hide/disable "Add Domain" once count ≥ limit (`domains/page.tsx`).
- **Worker** — n/a.

### `max_workspaces` (missing; architecturally hard)
- [ ] **BE** — Gate workspace creation; note the auto-create side-effect in `folder.py:134-148` can silently make a 2nd workspace for Free. Limit is per-user but plans are per-workspace → needs a user-level counter or cross-workspace subscription lookup (DB audit, medium).
- [ ] **FE** — Add gate when a "create workspace" UI exists (none today).
- **Worker** — n/a.

### `dynamic_qr_types` (missing; high revenue leak)
- [ ] **BE (HIGH)** — In `create_qr_code()` (`qr.py`), read `features->>'dynamic_qr_types'` and reject `payload.type` not in the allowed array (also bulk path).
- [ ] **FE** — Filter `ALL_TYPES` in `qr-types.ts` / `QRTypeSelector.tsx` by plan tier; replace `isLoggedIn`-only `UpgradePrompt` checks in content-type components (`PDFContent.tsx:270-277`, `VideoContent.tsx:70-77`, `ImagesContent.tsx:279-286`, `MP3Content.tsx:71-78`, `BusinessContent.tsx:223-230`, etc.) with `canAccessFeature`/plan-tier checks.
- [ ] **FE** — Fix `UpgradePrompt.tsx:30` default redirect (`/signup`) → billing/upgrade URL for logged-in users.
- **Worker** — n/a (renders whatever type exists in KV).

### `max_file_size_mb` (partial / fail-open)
- [ ] **BE (HIGH)** — Replace hardcoded `MAX_FILE_SIZE_BYTES=20MB` (`file_utils.py:17`, applied `storage.py:194`) with per-plan lookup of `features->>'max_file_size_mb'`.
- [ ] **FE** — Drive client-side caps from subscription instead of hardcoded values (`PDFContent.tsx:116-120`=20MB, `VideoContent.tsx:117`/`MP3Content.tsx:118`=50MB, `useFileUpload.ts:18`=5MB default).
- **Worker** — n/a.

### `advanced_analytics` (BE missing; FE partial)
- [ ] **BE** — Add `check_feature('advanced_analytics')` to `/analytics/summary|days|devices|top|qrs/{id}` (`scan.py`).
- [ ] **FE** — Gate the whole `analytics/page.tsx` (summary/devices/geo/hourly/type-mix), not just `recent-scans-list.tsx:72-73`.
- **Worker** — n/a (records scans unconditionally — correct).

### `password_protection` (BE missing; paid-feature bypass)
- [ ] **BE (HIGH)** — Add `check_feature('password_protection')` in PATCH `/qr/{id}` before hashing/saving password + `is_password_protected=True` (`qr.py:2198-2208`); mirror on create path.
- [ ] **FE** — Fix stale "Pro feature" label → "Starter+" (`password-protection-card.tsx:39`).
- [x] **Worker** — enforces gate from KV flag (`index.js:190-197`). No change needed; relies on BE writing a trusted flag.

### `ab_testing` (done; add worker defense-in-depth)
- [x] **BE** — `qr.py:1241-1246`, `qr.py:2371-2376`, `scan.py:410-415`.
- [x] **FE** — `ab-testing-card.tsx:75`, `WebsiteContent.tsx:95-97`.
- [ ] **Worker** — Optional: write/read an `ab_testing` entitlement in KV so `websiteRedirect.js:28-68` won't A/B-route a non-Pro workspace if KV ever has >1 destination (low).

### `analytics_retention_days` (missing everywhere)
- [ ] **BE** — Apply `WHERE scanned_at >= now() - interval` from `features->>'analytics_retention_days'` in `scan.py`. Note `qr_scan_counters` JSONB is all-time and can't be windowed without re-aggregating raw events.
- [ ] **FE** — Constrain query date range by plan retention (`useAnalytics.ts:59-70`).
- **Worker** — n/a.

### `bulk_generation` (gate done; feature is mock)
- [x] **BE** — `check_feature('bulk_generation')` (`qr.py:1969-1974`).
- [x] **FE** — gate `bulk/page.tsx:47`.
- [ ] **FE (HIGH functional)** — Replace mock `handleGenerate` (`bulk/page.tsx:79-112`, `setInterval` fake results) with a real `POST /qr/bulk` call.
- [ ] **BE** — Add `max_qr` count enforcement inside the bulk loop (shared with `max_qr` item above).

### `white_labeling` (missing everywhere)
- [ ] **BE** — Add `check_feature('white_labeling')` and propagate flag into KV (`cloudflare_kv.py`).
- [ ] **Worker** — Read flag and conditionally suppress "Powered by / Secured by Qravio" in all templates (`listLinks/*Template.js`, `media/*Template.js`, `socialMedia/profileTemplate.js`, `passwordGatePage.js:93`, `scanLimitPage.js:127`, `disabledPage.js:123`, …15+ files).
- [ ] **FE** — Wire `canAccessFeature('white_labeling')` for any branding toggle UI.

### Inert features (`lead_forms`, `retargeting_pixels`, `api_access`, `api_calls_per_month`, `sso`)
- No work until the underlying features are built. Flags exist in `plans.features` JSONB. **When built, add the `check_feature` gate in the same commit** (white_labeling is the cautionary example of a flag shipped without a gate).

---

## 4. Cross-Cutting Infrastructure (foundational, do first)

These are shared prerequisites that unblock many per-feature gates. Order = build order.

1. **Single source-of-truth plan→limits config.**
   - Today it's split: `max_qr`/`max_scans` as top-level `plans` columns; all else in `plans.features` JSONB; FE re-encodes in `qr_frontend/src/lib/plan-features.ts` + `src/lib/constants/pricing.ts`. There is **no `plan_features`/`plan_limits` table** (DB audit).
   - Establish one canonical definition (keep `plans.features` JSONB as backend SoT; generate/validate the FE constant from it) so values can't drift between layers.

2. **Generalize `check_limit()` to JSONB numeric quotas + add caching.**
   - `check_limit` (`subscription.py:197`) only handles top-level `max_qr`/`max_scans`. Extend it to count-and-compare arbitrary `features->>'max_*'` quotas (`max_members`, `max_custom_domains`, `max_file_size_mb`, `max_workspaces`).
   - Both `check_feature` (`subscription.py:270`) and `check_limit` do **2 sequential DB queries with no cache** per call and have a **TOCTOU race** (two concurrent creates can both pass). Add short-TTL caching + a guard against concurrent overshoot.

3. **Put plan entitlements into the KV value so the edge can enforce.**
   - KV blob (`cloudflare_kv.py:86-96`) today has: `qr_id, type, destination, destinations, is_password_protected, status, workspace_id, page_design, content`. The worker is **blind to plan tier**.
   - Add: `white_labeling`, `ab_testing` entitlement, and (optionally) `max_scans` + a cached `scan_count` so the edge can block proactively instead of reactively.

4. **Fix the fail-open / status-mismatch correctness bugs** (see Section 5; these gate trust in the whole scan-limit system).

5. **Billing-period plumbing + a workspace usage counter.**
   - Add `current_period_start` (HIGH — DB audit) and persist `billing_cycle` (`subscriptions` table; currently only in Razorpay `notes`, derived as `None` at `razorpay_routes.py:742`). Required for any monthly reset of `max_scans`.
   - No cached usage counters exist at workspace level (`qr_scan_counters` is per-QR). Consider a workspace usage row to avoid full-table counts; add index on `qr_scan_events(workspace_id)`.

6. **Standardize the `status` enum + remove dead code.**
   - Statuses written by backend are only `active`/`disabled`; `inactive` and `paused` appear in queries/worker but aren't produced consistently. Pick a canonical set, then delete dead worker paths (`getDisabledPage` import `index.js:7`, `paused` branch `index.js:181`).

7. **Harden `canAccessFeature` status handling (FE).**
   - `plan-features.ts` treats `status='created'` (unpaid, pending checkout) as full access — abuse vector. Decide whether to keep for checkout UX; `past_due` is treated as no-access (only `TrialBanner.tsx` surfaces it).

---

## 5. Known Bugs / Risks

| # | Severity | Bug | Location |
|---|---|---|---|
| 1 | **CRITICAL** | Scan-limit-disabled QRs are **never re-enabled**. `_enforce_scan_limit` writes `status='disabled'`; re-enable only matches `status='inactive'`. Renewal/upgrade does not restore service. | `internal.py:540` vs `razorpay_routes.py:1025` (+ `mor_routes.py:260`) |
| 2 | **CRITICAL** | `max_scans` counted **all-time** (no date window), but UI/docstring say "monthly." Free workspace permanently disabled after 500 lifetime scans; no `current_period_start`/reset mechanism. | `internal.py:530-536`; docstring `subscription.py:76` |
| 3 | **CRITICAL (compounds #1)** | Even if DB re-enable is fixed, KV is not re-synced (`write_to_kv` not called on re-enable) → edge keeps serving scan-limit page. | `razorpay_routes.py:1023-1025` |
| 4 | **HIGH** | `dynamic_qr_types` ungated server-side — any plan can create any type (e.g. Free creates `video`/`mp3`). | `qr.py` create paths |
| 5 | **HIGH** | `password_protection` ungated in backend PATCH — non-entitled users set passwords via API; worker then enforces the gate (paid feature for free). | `qr.py:2198-2208` |
| 6 | **HIGH** | `max_file_size_mb` flat 20 MB for all plans; Free gets 20 MB (should be 2), Agency capped at 20 (should be 50). | `file_utils.py:17`, `storage.py:194` |
| 7 | **HIGH** | `max_custom_domains` count not enforced — Pro (limit 1) can register unlimited once boolean passes. | `custom_domain.py:184-195` |
| 8 | **HIGH** | `max_members` not enforced — Free/Lite (limit 1) can invite unlimited. | `workspace.py:302-370` |
| 9 | **HIGH (functional)** | Bulk page is mock — even Pro users can't actually bulk-create; UI simulates results. | `bulk/page.tsx:79-112` |
| 10 | **MEDIUM** | `max_qr` bulk bypass — bulk loop has no per-item count gate; can overshoot the cap. | `qr.py:1969-1974` |
| 11 | **MEDIUM** | Custom domain stays live after downgrade — `domain:<hostname>` KV entry never deleted on plan change. | worker `index.js:126-179`; no downgrade handler |
| 12 | **MEDIUM** | `advanced_analytics` API fully open — only one FE sub-component gated; raw `/analytics/*` returns all data to any plan. | `scan.py` |
| 13 | **MEDIUM** | Scan-limit breach race — the breaching scan (and concurrent ones) always served; enforcement is reactive via `ctx.waitUntil`. | worker `scan.js:62-71` → `internal.py` |
| 14 | **MEDIUM** | `billing_cycle` + `current_period_start` columns missing → FE always gets `billing_cycle=null`; no basis for period resets. | `subscriptions` schema; `razorpay_routes.py:742` |
| 15 | **LOW** | Scan-limit enforcement fail-open on error — `try/except: pass` swallows enforcement failures. | `internal.py:469-472` |
| 16 | **LOW** | `max_qr` count includes `disabled` QRs → a capped workspace with disabled QRs can't create new ones. | `subscription.py` count query |
| 17 | **LOW/Risk** | `canAccessFeature` treats `status='created'` (unpaid) as active → feature access without payment. | `plan-features.ts` |
| 18 | **LOW** | `analytics_retention_days`, `max_workspaces`, `white_labeling` unenforced everywhere; misleading "Monthly"/renewal copy (`UsageTracker`, `scanLimitPage.js:124`); dead code (`getDisabledPage`, `paused`). | various |

**Severity disagreements between audits (flagged per instructions):**
- `folders`: backend audit **low**, DB audit **medium**, frontend audit **high**. Treat as **medium/high** (real Free/Lite leak).
- `white_labeling`: backend audit **low**, frontend audit **inert**, worker audit **high** (branding always shown to Agency). Treat as **medium** — enforce when branding-removal is wired.
- The catalog's note that the `max_qr` fail-open was the "known bug" is now **resolved** for the single-create path (raises 503, fail-closed at `qr.py:1188-1200`); the residual gap is the bulk endpoint (#10).

---

## 6. Recommended Sequencing

Work top-to-bottom; items within a phase can be picked one by one.

**Phase 0 — Stop the bleeding (one-liners / tiny, highest user impact)**
1. Bug #1: re-enable `disabled` QRs → `.in_('status',['inactive','disabled'])` (`razorpay_routes.py:1025`, `mor_routes.py:260`).
2. Bug #3: call `write_to_kv()` for each QR in the re-enable path.
3. Decide #2 semantics (all-time vs monthly) — at minimum fix misleading copy (`scanLimitPage.js:124`, `UsageTracker` labels) now; wire the real reset in Phase 1.

**Phase 1 — Foundations (Section 4)**
4. Central plan-limits config + generalized `check_limit()` for JSONB quotas + caching/TOCTOU guard.
5. Add `current_period_start` + persist `billing_cycle`; index `qr_scan_events(workspace_id)`; implement the chosen `max_scans` window.
6. Add plan entitlements to the KV blob (`white_labeling`, `ab_testing`, optional scan count).
7. Standardize `status` enum; delete dead worker code.

**Phase 2 — Close the high-severity revenue leaks (backend gates)**
8. `dynamic_qr_types` gate (#4) — backend create + bulk.
9. `password_protection` backend gate (#5).
10. `max_file_size_mb` per-plan (#6).
11. `max_custom_domains` count (#7).
12. `max_members` count (#8).
13. `folders` gate (BE + FE).
14. `max_qr` bulk count gate (#10).

**Phase 3 — Frontend correctness & UX**
15. Make bulk page real (#9).
16. Per-plan type filtering in builder + fix `UpgradePrompt` redirect.
17. Gate the full analytics page + add backend `advanced_analytics` gate (#12).
18. Fix labels ("Monthly Scans", "Pro feature" on password card), add "QRs paused" alerts, final-submit `max_qr` gate.

**Phase 4 — Worker defense-in-depth & lower priority**
19. `white_labeling` rendering + flag (#18, severity-disputed).
20. Custom-domain KV cleanup on downgrade (#11).
21. `ab_testing` worker defense-in-depth.
22. `analytics_retention_days`, `max_workspaces`, `max_qr` disabled-count semantics (#16), `created`-status access policy (#17).

**Phase 5 — Inert features**
23. When `lead_forms` / `retargeting_pixels` / `api_access` / `api_calls_per_month` / `sso` are built, ship the `check_feature` gate in the same PR.