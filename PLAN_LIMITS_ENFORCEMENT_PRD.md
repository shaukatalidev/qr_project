# PRD — Plan Limit Enforcement Across Frontend, Backend & Worker

**Status:** Draft · **Author:** Engineering · **Date:** 2026-06-14
**Scope:** `qr_frontend` + `qr_backend` + `qr_cf_code` (all three services)
**Supersedes:** `BILLING_ENFORCEMENT_PLAN.md` (stale audit doc from 2026-06-07/08)
**Objective:** Make the limits and features advertised on the pricing page (Free / Starter / Pro / Agency) **actually enforced** end-to-end — with one source of truth, no "sell it but don't enforce it" gaps, and graceful upgrade/downgrade behavior.

---

## 1. Background & The Core Problem

The pricing page sells four tiers with specific quotas and feature gates. The enforcement **machinery** in the backend is already mature (`check_limit`, `check_feature`, scan-cap auto-disable, KV entitlements). The problem is **not** "build enforcement from scratch" — it's three things:

1. **Config drift (the headline):** The backend `plans` table is the source of truth, but it was never repriced to v3. **Migration 0009 does not exist** (highest is `0008`). The DB still enforces the *old* numbers while the pricing page advertises the *new* ones:

   | Limit | Pricing page (sold) | Backend DB (enforced today) |
   |---|---|---|
   | Free dynamic QR | **5** | 3 |
   | Free monthly scans | **2,000** | 500 |
   | Free members | **2** | 1 |
   | Starter dynamic QR | **50** | 15 |
   | Pro dynamic QR | **300** | 50 |

   Every other tier number is similarly stale. **What we sell ≠ what we enforce.** This is a trust/revenue bug, not just a config nit.

2. **Specific enforcement holes** even where the engine runs: a 20MB hard file ceiling that breaks Agency's 50MB, bulk-create bypassing type/count gates, analytics retention only half-applied, and — most damaging — **Free-tier QRs that get scan-disabled never come back** at month rollover (no re-enable job).

3. **Features sold but not built:** Lead Capture Forms, Retargeting Pixels, API Access (+ call quotas), White-Labeling settings, and SSO/SAML appear on the pricing page but have **no working implementation**. Gating a feature that doesn't exist is meaningless; these need to be built before they can be enforced.

This PRD covers all three across the three services.

---

## 2. Goals & Non-Goals

### Goals
1. **One source of truth** for plan limits/features, with automated parity between what's displayed, what's enforced, and what the worker sees.
2. **Reprice the backend** to the v3 tiers (migration 0009) so enforcement matches the page.
3. **Close every enforcement hole** for limits/features that already have a UI (counts, file size, types, scans, retention, feature gates).
4. **Graceful lifecycle:** upgrades unlock immediately; downgrades lock excess usage safely; Free monthly windows reset automatically.
5. **Build the missing features** that are sold (API, lead capture, retargeting, white-label) or remove them from the page if not shipping.
6. **Fail-closed** on every limit decision; never silently allow over-limit usage.

### Non-Goals
- Re-architecting the billing/subscription/webhook system (it works; memory: Phases 0–5 done).
- Real-time edge scan counting via Durable Objects (the backend-mediated scan cap is sufficient — see §6.3).
- Changing prices or tier structure (v3 is decided; this enforces it).
- Payment-provider migration (Razorpay/Lemon Squeezy stay).

---

## 3. The Enforcement Architecture (how it works today)

```
SOURCE OF TRUTH = backend `plans` table
  ├─ columns: max_qr, max_scans
  └─ features JSONB: max_members, max_workspaces, max_custom_domains,
                     max_file_size_mb, analytics_retention_days,
                     dynamic_qr_types[], api_calls_per_month,
                     + boolean gates (folders, password_protection,
                       advanced_analytics, ab_testing, bulk_generation,
                       custom_domain, lead_forms, retargeting_pixels,
                       api_access, white_labeling, sso)

BACKEND (qr_backend/src/api/routes/subscription.py) — the enforcement engine
  ├─ resolve_plan(workspace_id)        # active sub → else free; 30s cache; fail-closed
  ├─ check_limit(ws, field)            # current_usage < limit ; -1 = unlimited
  ├─ check_feature(ws, key)            # bool(features[key]) ; False on lookup fail
  └─ get_limit(ws, field)              # numeric lookup (file size, retention)
       ↓ called from qr.py, workspace.py, custom_domain.py, storage.py, folder.py, scan.py

FRONTEND (qr_frontend) — display + pre-emptive UX (NOT the authority)
  ├─ src/lib/constants/pricing.ts      # DISPLAY ONLY (pricing page / SEO)
  ├─ src/lib/plan-features.ts          # canAccessFeature(sub, key)  [no getLimit() yet]
  └─ hooks: useLimitCheck / useQRLimitCheck / useScanLimitCheck → /subscriptions/limit-check

WORKER (qr_cf_code) — acts on pre-computed state in KV, never knows numbers
  ├─ reads KV: status (active|paused|disabled) + entitlements{white_labeling, ab_testing}
  ├─ status==="disabled" → scanLimitPage   (set by backend _enforce_scan_limit)
  └─ status==="paused"   → pausedPage

SCAN CAP FLOW (works today, modulo stale 500 value + free re-enable gap):
  scan → recordScan → POST /internal/scans → backend increments + _enforce_scan_limit
       → if count >= max_scans: flip dynamic QRs to status=disabled + sync_qr_to_kv
       → next scan: worker sees status=disabled → scanLimitPage   (one-scan lag)
```

**Three enforcement responsibilities per limit type:**
- **Count limits** (dynamic QR, members, workspaces, domains): backend **blocks** at the mutation (hard, authoritative); frontend **pre-empts** (disable button + UpgradePrompt) for UX. Worker: N/A.
- **Scan cap:** backend computes + flips `status`; worker renders the block page; frontend shows usage/alert.
- **Feature gates:** backend blocks the API; frontend hides/gates the UI; a few (white-label, A/B) also need a worker **entitlement** in KV.
- **File size / retention / QR-types:** backend validates; frontend pre-checks/locks the input.

---

## 4. Current-State Matrix

### 4.1 Numeric limits

| Limit | Target (F/S/P/A) | Frontend gate | Backend enforce | Worker | Verdict |
|---|---|---|---|---|---|
| Dynamic QR count | 5 / 50 / 300 / ∞ | ✅ `QRTypeSelector.tsx:30,160` (banner+block) | ✅ `qr.py:1185` single; ⚠️ bulk path `qr.py:2006` no per-item recheck (race) | — | **Wrong numbers** (DB stale) + bulk race |
| Static QR | ∞ all | n/a | n/a | — | OK |
| Monthly scans | 2,000 / ∞ / ∞ / ∞ | ✅ `ScanLimitAlert.tsx` (banner) | ⚠️ `internal.py:466` works but **fail-open swallow** (`except: pass`) + DB=500 | ✅ `scanLimitPage` via `status=disabled` | **Wrong number (500)** + silent-swallow + free re-enable gap |
| Team members | 2 / 5 / 10 / ∞ | ❌ none (`InviteUserModal`) | ✅ `workspace.py:327` (invite); ⚠️ accept-invite recheck unverified | — | FE pre-empt missing; verify accept path |
| Workspaces | 1 / 1 / 3 / ∞ | ❌ none | ❌ **no workspace-create gate**; auto-create side-effect `folder.py:150` | — | **Unenforced** both layers |
| File upload MB | 2 / 10 / 25 / 50 | ❌ hardcoded per uploader (`PDFContent` 20, `ImagesContent` 5…) | ⚠️ `storage.py:227` per-plan BUT `file_utils.py:17` hard-caps 20MB → **breaks Agency 50MB** | — | Ceiling bug + no FE pre-check |
| Custom domains | 0 / 0 / 3 / ∞ | ⚠️ access gated, **count not** (`domains/page.tsx`) | ✅ `custom_domain.py:198` count | (KV `domain:*`) | FE count gate missing |
| Analytics retention | 7 / 30 / 90 / 365 d | ❌ date picker commented out, no clamp | ⚠️ only `/days` clamps (`scan.py:192`); `/summary`,`/top`,`/devices`,`/qrs` serve full history | — | Half-enforced BE + no FE |
| Dynamic QR types | 2 / 5 / 13 / 13 | ✅ `QRTypeSelector.tsx:35,190` (lock) | ✅ `qr.py:1238` single; ❌ **bulk loop ungated** | — | Bulk bypass |
| API calls/mo | 3,000 / 25,000 | ❌ none | ❌ none (no metering) | — | **Not built** |

### 4.2 Feature gates

| Feature | Tier | Frontend gate | Backend enforce | Worker entitlement | Verdict |
|---|---|---|---|---|---|
| Folders | all? (check page) | ⚠️ create-blocked `FolderSection.tsx:116` | ✅ `folder.py:131` | — | OK (confirm tier) |
| Password protection | Starter+ | ✅ `password-protection-card.tsx:22` | ✅ PATCH `qr.py:2256`; ⚠️ verify CREATE path | (KV `is_password_protected`) | Verify create gate |
| Advanced analytics | Pro+ | ✅ `analytics/page.tsx:39` | ✅ `scan.py:113` (most endpoints) | — | OK |
| A/B testing | Pro+ | ✅ `ab-testing-card.tsx:74` | ✅ create+update+scan | ✅ `entitlements.ab_testing` | OK |
| Bulk generation | Pro+ | ✅ `bulk/page.tsx:163` | ✅ `qr.py:1999` | — | **FE handler is a mock** — never calls API |
| Custom domain | Pro+ | ✅ `domains/page.tsx`, `domain-selector.tsx` | ✅ `custom_domain.py:187` | (KV isolation) | OK (count gate sep.) |
| White labeling | Agency | ❌ no settings UI | ⚠️ snapshot only `cloudflare_kv.py:122` | ⚠️ partial; system pages hardcode brand | **Incomplete** |
| Lead capture forms | Pro+ | ❌ no UI at all | ❌ none | — | **Not built** |
| Retargeting pixels | Pro+ | ❌ no UI at all | ❌ none | — | **Not built** |
| API access | Pro+ | ❌ `developers/page.tsx` → `notFound()` | ❌ none | — | **Not built** |
| SSO / SAML | (none on self-serve?) | ❌ | ❌ | — | **Not built / clarify tier** |

---

## 5. Critical Findings (ranked)

1. **[P0] Backend reprice missing (migration 0009).** Enforcement runs against stale `0005` numbers. Fixing this single migration corrects ~9 limits at once. Root cause of "sell ≠ enforce."
2. **[P0] Free monthly re-enable absent.** `_enforce_scan_limit` disables Free dynamic QRs at overage, but re-enable only fires on a **payment webhook** — which Free users never trigger. Their QRs stay dead forever. A scheduled monthly reset must ship *with* the reprice or we break every Free user who hits the (new, higher) cap.
3. **[P0] `file_utils.py:17` 20MB hard ceiling** rejects Agency's 50MB uploads regardless of plan.
4. **[P1] Source-of-truth drift.** `pricing.ts` (display) uses `max_dynamic_qr`; backend uses `max_qr`. Two hand-maintained copies of the plan matrix guarantee future drift. Need a parity mechanism (fetch from API or a parity test).
5. **[P1] Bulk create bypasses type + count gates** (`qr.py:2006+`) — Free/Starter can mass-create disallowed types and overshoot the QR cap.
6. **[P1] Analytics retention half-enforced** — only `/days` clamps; other endpoints leak full history to Free/Starter.
7. **[P1] Scan-limit fail-open swallow** (`internal.py:470` `except: pass`) — enforcement errors silently leak scans; must at least log, ideally fail-closed.
8. **[P1] Frontend count gates missing** for members / workspaces / custom domains — users hit a hard 402 instead of a graceful pre-empt.
9. **[P1] Downgrade integrity** — over-limit dynamic QRs aren't locked after a downgrade; stale `domain:*` KV keeps a custom domain live after losing the plan.
10. **[P2] Sold-but-unbuilt features** — API access, lead capture, retargeting, white-label settings, SSO. Large net-new builds (§7).

---

## 6. Design Decisions

### 6.1 Single source of truth
The backend `plans` table stays authoritative. To kill drift:
- Frontend stops hardcoding numbers for *enforcement* logic; it reads live limits from `useCurrentSubscription`/`usePlans`. `pricing.ts` remains **display-only** for the public (logged-out) pricing page, and gets a **parity test** asserting `pricing.ts` values == the seeded `plans` rows.
- Add a `getLimit(subscription, key)` helper in `plan-features.ts` (mirrors `canAccessFeature`) so no component reads `subscription.features.*` inline.
- Standardize field names (`max_qr` canonical across FE+BE, or an explicit map) — pick one in Phase 0.

### 6.2 Fail-closed everywhere
`resolve_plan` already fails closed on missing plan. Fix `internal.py:470` to log + fail-closed. Every new check follows: lookup error → deny, never allow.

### 6.3 Scan cap stays backend-mediated (no Durable Objects)
The flow (backend disables → KV `status` → worker page) is correct and cheap. Accept the documented one-scan lag. Do **not** add edge counters. Fix only the stale number (0009) and the Free re-enable job.

### 6.4 Downgrade model reuses `status`
On downgrade, a backend handler locks excess dynamic QRs (oldest-kept-or-user-chosen) by setting `status` to a new `"locked"` value + `sync_qr_to_kv`. Worker adds one branch (`status==="locked"` → a "plan limit" page). Custom-domain downgrade deletes the `domain:*` KV key.

### 6.5 Missing features are real builds, gated as they land
Each unbuilt feature (API, lead capture, retargeting, white-label, SSO) is a self-contained sub-project: build the feature, then gate it with the existing `check_feature` (BE) + `canAccessFeature` (FE) pattern. Until built, **mark them "coming soon" on the page** rather than advertising an enforceable feature that doesn't exist.

---

## 7. Missing Features To Build (sold on the page, not implemented)

| Feature | Tier | What exists | What must be built |
|---|---|---|---|
| **API Access** | Pro / Agency | flag only; `developers/page.tsx`→`notFound()` | API-key issuance + storage, an authenticated public API surface, per-key auth, **monthly call metering + quota enforcement** (3k/25k), key-management UI gated on `api_access` |
| **Lead Capture Forms** | Pro+ | flag only | A new dynamic QR type or per-QR form config, form builder UI, submissions store + viewer, worker render of the form page, `check_feature('lead_forms')` |
| **Retargeting Pixels** | Pro+ | flag only | Per-QR/workspace pixel config (FB/Google/etc.), inject pixel into worker-rendered landing pages, settings UI, `check_feature('retargeting_pixels')` |
| **White-Labeling** | Agency | partial KV snapshot; brand suppressed in *some* templates | Settings UI; propagate `white_labeling` entitlement to **all** templates + system pages (`passwordGatePage`, `scanLimitPage` hardcode brand); re-sync KV on plan change |
| **SSO / SAML** | unclear (no tier marked) | flag + enterprise copy | Decide: enterprise-only/contact-sales (remove from self-serve compare) or build (IdP integration). **Open question §11.** |

---

## 8. Phase-Wise Implementation Plan

Each phase is independently shippable. Phases 0–1 are the must-do correctness work; 4 is the large net-new build.

### Phase 0 — Source of truth + reprice (P0, unblocks everything) — ~1–2 days
> **Note (verified 2026-06-14):** the v3 *code* already landed (`subscription.py` filters `.eq("is_public", True)` at :625; `pricing.ts` is 4-tier) but the **migration SQL was lost** — `migrations/` stops at `0008` and the repo has no commits. So `subscription.py` already references a `plans.is_public` column that no migration creates. Migration 0009 must therefore both **add `is_public`** and reprice — and it must ship before that code path is exercised against the DB, or `list_plans` errors on a missing column.
- Write **migration 0009** (adds `plans.is_public` + reprices): set the v3 numbers for free/starter/pro/agency (`max_qr` 5/50/300/-1; `max_scans` 2000/-1/-1/-1; `features.max_members` 2/5/10/-1; `max_workspaces` 1/1/3/-1; `max_custom_domains` 0/0/3/-1; `max_file_size_mb` 2/10/25/50; `analytics_retention_days` 7/30/90/365; `dynamic_qr_types` 2/5/13/13; `api_calls_per_month` 0/0/3000/25000; feature booleans per tier). Set `is_public=false` on retired `lite`/`business`; null their stale Razorpay/LS IDs.
- Reconcile field-name drift (`max_qr` vs `max_dynamic_qr`); add `getLimit()` to `plan-features.ts`.
- Add a **parity test** (`pricing.ts` == seeded plan rows).
- Create/verify Razorpay plans + Lemon Squeezy variants for the new prices (payment-ops).
- **Acceptance:** `resolve_plan` returns v3 numbers; a Free workspace is blocked at 5 dynamic QR / 2,000 scans; pricing page parity test green.

### Phase 1 — Close enforcement correctness holes (P0/P1) — ~2–3 days
- Fix `file_utils.py:17` ceiling (raise to 50MB or defer fully to per-plan `storage.py` check).
- Add type **and** count re-check inside the bulk loop (`qr.py:2031+`).
- Verify/add `check_feature('password_protection')` on QR **create**; verify `max_members` recheck on **accept-invitation**.
- Apply `analytics_retention_days` clamp to **all** analytics endpoints, not just `/days`.
- `internal.py:470`: replace `except: pass` with log + fail-closed.
- Add `max_workspaces` enforcement on workspace creation (and the `folder.py:150` auto-create side-effect).
- Build the **Free monthly re-enable job**: `POST /internal/free-scan-reset` (x-internal-secret) that re-enables Free workspaces' disabled dynamic QRs whose new-period count is under cap + KV-syncs; schedule via Cloudflare Cron / pg_cron (`0 0 1 * *`).
- **Acceptance:** Agency uploads 50MB; bulk can't create disallowed types or overshoot; Free QRs auto-recover on the 1st; retention windows enforced on every analytics call.

### Phase 2 — Frontend pre-emptive gates + UX (P1) — ~2 days
- `getLimit()`-based pre-checks: member-invite, workspace-create, custom-domain-add all disable the action + show `UpgradePrompt` at cap (backend still authoritative).
- File-size pre-check in each uploader from `getLimit('max_file_size_mb')`.
- Analytics retention date picker, clamped to plan.
- Fix the **bulk-generation mock** (`bulk/page.tsx`) to call the real API.
- Consolidate the two `UsageTracker` components.
- **Acceptance:** every count limit shows a graceful pre-empt before the 402; no hardcoded MB values remain.

### Phase 3 — Lifecycle: downgrade & edge integrity (P1) — ~2 days
- Downgrade handler: lock excess dynamic QRs (`status="locked"`) + `sync_qr_to_kv`; delete `domain:*` KV on custom-domain loss.
- Worker: add `status==="locked"` branch → plan-limit page (`src/index.js:181`).
- White-label entitlement passed to system pages + all templates.
- **Acceptance:** downgrade Pro→Free locks QRs 6..N and kills custom domains at the edge; upgrade re-enables (existing webhook path).

### Phase 4 — Build missing sold features (P2, large — each its own sub-PRD) — weeks
- **API access** (keys + metering + quota), **Lead Capture Forms**, **Retargeting Pixels**, **White-Labeling settings UI**, **SSO/SAML decision**. Build → gate with `check_feature` + `canAccessFeature`. Until shipped, mark "coming soon" on the page (Phase 0 copy change).
- **Acceptance:** each feature works and is correctly gated + quota-enforced per tier.

### Phase 5 — Verification & governance — ~1 day
- A per-tier **enforcement test matrix** (every row in §4 × 4 tiers, allow/deny).
- Upgrade/downgrade lifecycle tests; Free month-rollover test.
- Keep the parity test in CI so display/enforcement can't drift again.

---

## 9. Testing Strategy

- **Backend (pytest):** for each limit, a test per tier asserting allow-below / deny-at / unlimited(-1); bulk loop type+count; file ceiling per plan; retention clamp on every endpoint; scan-cap disable + Free re-enable job; downgrade lock; fail-closed on plan-lookup error.
- **Frontend (Vitest/Playwright):** `getLimit`/`canAccessFeature` unit tests; pre-empt UI at cap for members/workspaces/domains/files; analytics picker clamp; bulk real-API E2E.
- **Worker:** `status` branch tests (`disabled`→scanLimit, `paused`→paused, `locked`→plan-limit); entitlement-driven white-label/A-B rendering.
- **Cross-layer parity test:** `pricing.ts` == DB plan rows == values the limit-check endpoints return.

## 10. Rollout

1. Ship Phase 0 migration in a maintenance window; verify `resolve_plan` + parity test before announcing.
2. Phase 1 free-reset job must be live **before** the higher Free cap, or early Free users hit a dead-QR state.
3. Phases 2–3 are additive/low-risk. Phase 4 ships feature-by-feature behind `check_feature`.

## 11. Open Questions
1. **SSO/SAML** — is it a self-serve tier feature or enterprise/contact-sales only? If not self-serve, remove the row from the standard compare table.
2. **Folders** — which tiers? (Page rows didn't copy marks; confirm Free vs Starter+.)
3. **Downgrade QR selection** — when locking excess dynamic QRs, which survive? (Oldest N? Most-scanned N? User picks?) Recommend: keep the N most-recently-active, lock the rest, let the user re-pick.
4. **"Coming soon" vs remove** — for unbuilt sold features (API/lead/retargeting/white-label), do we relabel the pricing page now (Phase 0) or rush the builds?
5. **Field-name canonicalization** — standardize on `max_qr` everywhere, or keep `max_dynamic_qr` in display + map? (Recommend `max_qr` canonical.)

## 12. Appendix — Key Files
| Concern | File |
|---|---|
| Enforcement engine | `qr_backend/src/api/routes/subscription.py` (`check_limit`/`check_feature`/`resolve_plan`) |
| QR create/bulk gates | `qr_backend/src/api/routes/qr.py` (1185, 1238, 1999, 2006+) |
| Scan cap | `qr_backend/src/api/routes/internal.py:466` (`_enforce_scan_limit`) |
| File size bug | `qr_backend/src/utilities/file_utils.py:17` |
| Plan seed (to reprice) | `qr_backend/migrations/0005…0008` → **new 0009** |
| KV sync + entitlements | `qr_backend/src/utilities/cloudflare_kv.py` (`build_entitlements`, `sync_qr_to_kv`) |
| FE plan helpers | `qr_frontend/src/lib/plan-features.ts`, `src/lib/constants/pricing.ts` |
| FE limit hooks | `qr_frontend/src/hooks/useSubscription.ts` |
| FE gates | `QRTypeSelector.tsx`, `password-protection-card.tsx`, `ab-testing-card.tsx`, `domains/page.tsx`, `analytics/page.tsx`, `bulk/page.tsx` |
| Worker status gate | `qr_cf_code/src/index.js:170-187` |
| Worker pages | `scanLimitPage.js`, `disabledPage.js` (`getPausedPage`) |

---

*Planning document. No code written yet. The single most important first step is Phase 0 migration 0009 — until the DB is repriced, enforcement contradicts the pricing page.*

---

## Eng Review Decisions & Revised Plan (2026-06-14)

`/plan-eng-review` reduced scope and locked 9 decisions. **Where this section differs from the body above, this wins.**

**Scope reduced:** this plan = **enforcement + lifecycle only**. The 5 unbuilt features (API access, lead capture, retargeting, white-label, SSO) are **split to separate PRDs** + a **"coming soon" pricing-page relabel now** so we stop advertising unenforceable features.

| # | Decision |
|---|---|
| A1 | **DB `plans` table = single source.** Strip numbers from `pricing.ts` (labels/copy only); public pricing page reads `/plans` via **ISR + on-demand revalidate** (P1); make `/plans` a public, cached endpoint; type `CurrentSubscription.features` (replace `Record<string,unknown>`); add `getLimit(sub,key)`. Parity test asserts seeded rows match PRICING_MODEL.md intent. |
| A2 | **Free monthly re-enable = Cloudflare Cron Trigger → `POST /internal/free-scan-reset`** (x-internal-secret). Disabled QRs get zero backend traffic (worker returns `scanLimitPage` before `recordScan`), so a scheduler is the only option. Idempotent, pre-filter to workspaces-with-disabled-QRs, paginate, **log count + alert on failure**. NOTE: this is **3 surfaces** to build — the endpoint, `wrangler.toml [triggers]`, and a worker `scheduled` handler — none exist yet. |
| A3 | **Downgrade = graceful revoke.** Keep recent-active N dynamic QRs, set excess to new `status="locked"`, email + grace window, delete `domain:*` KV on custom-domain loss, never delete data. **Must also:** add `"locked"` to the re-enable webhook query (`razorpay_routes.py:1155` `.in_("status", [...])`) or re-upgrade won't restore; add worker `status==="locked"` branch (else over-limit QRs render normally — lock is a no-op at the edge). |
| C2 (corrected) | **The 20MB `file_utils.py:17` ceiling was a FALSE bug** — `validate_file()` only checks content-type; the constant is dead code; Agency 50MB already works via per-plan `storage.py:234`. Action: delete the dead constant + add a 50MB absolute safety cap in `validate_file` as an *enhancement* (defense-in-depth; none exists today). Not a P0. |
| C4 | **Scan-enforcement errors → log + alert, keep fail-open.** Replace `internal.py:470` `except: pass`. Fail-closed here would disable live QRs on a transient blip (footgun). Fix the body's §6.2 "fail-closed everywhere" wording — the scan path is the documented fail-open exception. |
| T2 | **Analytics retention enforced via raw `qr_scan_events` + `scanned_at >= cutoff`** on the windowed endpoints (counters are all-time and can't be windowed). Uses the `(workspace_id, scanned_at)` index (migration 0007); cache hot Agency aggregates. |
| T3 | **One-time backfill** re-enable run on 0009 day (raising Free 500→2000 won't auto-revive QRs disabled under the old cap; monthly cron only runs on the 1st). Reuses the free-scan-reset logic. |
| Pre-flight | **Verify live DB state BEFORE writing 0009:** does `plans.is_public` exist? (`subscription.py:625` already filters `.eq("is_public", True)` but no migration creates it — `list_plans` may be erroring in prod *right now* → empty plan list → upgrade impossible). Are values stale `0005` or hand-patched? Confirm grandfathering of existing subs on retired tiers. |
| Folded | accept-invitation member recheck is a **firm task** (not "verify"); `max_workspaces` registry `"not_applicable"` is a misclassification → enforce + guard `folder.py:150` auto-create; bulk create uses a shared per-item enforcement helper (defense-in-depth, low severity since bulk is Pro+). |

### Revised phases
- **Phase 0 (P0):** pre-flight DB check → migration 0009 (add `is_public` + reprice) → A1 DB-single-source + `/plans` ISR → A2 free-reset infra (3 surfaces) + T3 one-time backfill. **Ship together.**
- **Phase 1 (P1):** BE holes — accept-invite recheck, retention-via-events (T2), C4 observability, max_workspaces, C2 cleanup+50MB cap.
- **Phase 2 (P1):** FE pre-empt gates (getLimit, member/workspace/domain/file), retention picker, UsageTracker dedup, bulk-gen real API.
- **Phase 3 (P1):** A3 downgrade revoke (lock excess + KV cleanup + webhook `"locked"` + worker branch).
- **Phase 5 (P2):** verification matrix + parity test.
- **Split out:** 5 feature PRDs + "coming soon" relabel.

### Implementation Tasks
- [ ] **T1 (P0, human: ~1h / CC: ~15min)** — Pre-flight: inspect live `plans` table (is_public present? values stale/patched? list_plans erroring?). Output known baseline. Surfaced by: outside-voice #1.
- [ ] **T2 (P0, human: ~3h / CC: ~30min)** — Migration 0009: ADD `plans.is_public` + reprice v3 (Free 5/2000/2, Starter 50, Pro 300, Agency -1) + retire lite/business + null stale provider IDs. Files: `qr_backend/migrations/0009_*.sql`. Verify: reprice-value-lock test.
- [ ] **T3 (P0, human: ~1d / CC: ~2h)** — A1 DB-single-source: strip numbers from `pricing.ts`; pricing page reads `/plans` (ISR + on-demand revalidate); public cached `/plans`; type `features`; `getLimit()`. Verify: parity test.
- [ ] **T4 (P0, human: ~1d / CC: ~3h)** — A2 free-reset (endpoint + `wrangler [triggers]` + worker `scheduled`), idempotent + filtered + alerted; **+ T3 one-time backfill** run. Verify: cron under-cap test + backfill test.
- [ ] **T5 (P1, human: ~1.5d / CC: ~3h)** — BE holes: accept-invite member recheck; retention via `qr_scan_events` on all windowed endpoints; `max_workspaces` enforce + registry fix + `folder.py:150` guard; C4 log+alert. Files: `workspace.py`, `scan.py`, `subscription.py`, `internal.py`.
- [ ] **T6 (P1, human: ~20min / CC: ~5min)** — C2: delete dead `MAX_FILE_SIZE_BYTES`; add 50MB safety cap in `validate_file`. File: `file_utils.py`.
- [ ] **T7 (P1, human: ~1.5d / CC: ~3h)** — FE pre-empt gates: member/workspace/custom-domain count + file-size pre-check; analytics retention picker; UsageTracker dedup; bulk-gen real API. Files: `InviteUserModal`, domains page, content uploaders, `AnalyticsHeader`, `bulk/page.tsx`.
- [ ] **T8 (P1, human: ~1.5d / CC: ~3h)** — A3 downgrade revoke: lock excess (`status="locked"`, keep recent-active N) + email/grace + delete `domain:*` KV; add `"locked"` to `razorpay_routes.py:1155` re-enable query. Files: `razorpay_routes.py`, `cloudflare_kv.py`.
- [ ] **T9 (P1, human: ~1h / CC: ~15min)** — Worker `status==="locked"` branch → plan-limit page; verify disabled/paused branches. File: `qr_cf_code/src/index.js`.
- [ ] **T10 (P2, human: ~1.5d / CC: ~4h)** — Verification: per-tier enforcement matrix, lifecycle (upgrade/downgrade/free-reset/backfill), parity test, 3 regression tests (reprice-value-lock, file 45MB ok/55 rejected, parity).
- [ ] **T11 (P2, human: ~3h / CC: ~30min)** — Split-out: "coming soon" relabel for API/lead/retargeting/white-label/SSO; stub PRDs.

### Parallelization
- **Lane A (backend core, sequential — shared `subscription.py`/migrations/routes):** T1 → T2 → T4 → T5 → T8.
- **Lane B (frontend, after the `/plans` contract is fixed in T3):** T3 → T7. Parallel to Lane A once T2 lands the schema.
- **Lane C (worker):** T9 + the worker `scheduled` half of T4. Small, parallel.
- **T6** independent. **T10** after all. Conflict flag: T5 + T8 both touch backend routes → same lane, sequential.

### Failure modes (critical)
| Codepath | Failure | Test | Handling | User sees |
|---|---|---|---|---|
| Free-reset cron | silent fail → all free QRs stay dead | ✅ idempotency + alert | ✅ alert | dead QR → mitigated by alert + backfill |
| `is_public` missing in prod | `list_plans` 500 → upgrade impossible NOW | ✅ T1 pre-flight + migration smoke | n/a until fixed | can't upgrade (revenue) — **verify first** |
| `status="locked"` unhandled in worker | over-limit QR renders normally (lock no-op) | ✅ T9 worker branch | ✅ branch | lock ineffective → covered |
| `"locked"` absent from re-enable query | re-upgrade doesn't restore locked QRs | ✅ upgrade-after-downgrade | ✅ T8 query fix | QRs stay dead after paying → covered |
| retention via raw events | slow query on huge Agency window | ⚠️ add perf test | ✅ index + cache | slow analytics → mitigate cache |

No silent+untested+unhandled gaps remain after the above.

### NOT in scope (deferred)
- Build the 5 sold features (API/lead/retargeting/white-label/SSO) — split to own PRDs + "coming soon" relabel now.
- Date-bucketed rollup counters — chose raw-events query (T2) over a new ingest pipeline.
- Real-time edge scan counting (Durable Objects) — backend-mediated cap is sufficient.
- Razorpay/LS plan-object creation — payment-ops step alongside 0009, not code.

### Outside voice
Ran (Claude subagent — Codex unavailable). Overturned C2 (file_utils dead code, verified). Surfaced: is_public prod-risk (→ T1 pre-flight), one-time backfill (→ T3), retention all-time-counter constraint (→ T2 raw-events), `"locked"` in re-enable query (→ T8), cron = 3 surfaces (→ T4 effort). All accepted by the user.

## GSTACK REVIEW REPORT

| Review | Trigger | Why | Runs | Status | Findings |
|--------|---------|-----|------|--------|----------|
| CEO Review | `/plan-ceo-review` | Scope & strategy | 0 | — | not run |
| Codex Review | `/codex review` | Independent 2nd opinion | 0 | — | not run (Codex unavailable) |
| Eng Review | `/plan-eng-review` | Architecture & tests (required) | 1 | ISSUES_RESOLVED | 7 issues (3 arch, 2 quality→1 corrected, 1 perf, +3 outside-voice gaps), all resolved; ~28 test paths, 3 critical regression tests; 0 critical failure gaps |
| Design Review | `/plan-design-review` | UI/UX gaps | 0 | — | not run (backend/enforcement-heavy) |
| DX Review | `/plan-devex-review` | Developer experience gaps | 0 | — | not run |

- **CALIBRATION:** C2 was raised at confidence 9/10 but verified FALSE (file_utils 20MB constant is dead code) — over-confidence from trusting an explore-agent claim without reading `validate_file`. Logged as a learning.
- **OUTSIDE VOICE:** ran (Claude subagent); overturned C2; added 3 gaps (is_public prod-risk, one-time backfill, retention all-time constraint), all accepted.
- **UNRESOLVED:** none — scope + 9 decisions all settled.
- **VERDICT:** ENG CLEARED — ready to implement. Phase 0 (pre-flight DB check → 0009 → DB-single-source → free-reset infra + backfill) is the unblocking gate; the `is_public`-in-prod check must run before writing 0009.
