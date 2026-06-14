# Qravio Pricing v3 — Restrictions & Enforcement Plan

> What each plan limit is, **where it is enforced in the live code**, its status, and the gaps that must close before the v3 reprice goes live. Companion to `PRICING_MODEL.md` (the price/tier spec) and supersedes the stale parts of `BILLING_ENFORCEMENT_PLAN.md`.
>
> **Reality check (from a live-code audit, 2026-06-09):** enforcement is *far* more complete than `BILLING_ENFORCEMENT_PLAN.md` claims. Nearly every gate that doc lists as "missing" is actually built. This document reflects the **live code**, not the old plan.

## Architecture of the gate layer

- **`resolve_plan(workspace_id)`** — `subscription.py:218-268`. 30s in-process cache; reads the most recent `subscriptions` row with status in (`trialing`,`active`), falls back to the `free` plan row if none. Invalidated on payment verify / activation webhook / cancellation.
- **`check_limit(key)`** — `subscription.py:428-468`. Counts live usage, returns `allowed = usage < limit`; `-1` ⇒ unlimited. Reads top-level columns (`max_qr`, `max_scans`) or `features` JSONB numeric keys (`max_members`, `max_custom_domains`). **Fail-closed** at call sites (raise 503 on resolution error). Caller raises the 4xx.
- **`get_limit(key)`** — for non-countable numerics (`max_file_size_mb`, `max_workspaces`, `analytics_retention_days`).
- **`check_feature(key)`** — `subscription.py:471-507`. Returns `bool(features[key])`; **fail-closed** (returns `False`) on missing key or plan-resolution error.
- **Source of truth** = `plans.features` JSONB + `plans.max_qr`/`max_scans` columns in the DB. Frontend `pricing.ts` is display/SEO only; the FE `canAccessFeature()` (`plan-features.ts`) reads the subscription's features echoed from the backend.
- **Known structural caveat:** `check_limit` has a **TOCTOU race** — no lock, so two concurrent creates can both pass a near-limit check. Low impact at current scale; note it.

## Restriction matrix — v3 values + enforcement

Legend: ✅ enforced · ⚠️ partial / needs verify · ❌ not enforced · — n/a

| Restriction | Free | Starter | Pro | Agency | Enforced at (`file:line`) | Status |
|---|---|---|---|---|---|---|
| `max_qr` (dynamic) | 5 | 50 | 300 | ∞ | `qr.py:1185-1209` (single), `qr.py:2006-2029` (bulk) | ✅ |
| `max_scans` /period | 2,000/mo | ∞ | ∞ | ∞ | `internal.py:466-530` (record + enforce) | ⚠️ fail-open swallow |
| `max_members` (incl. owner) | 2 | 5 | 10 | ∞ | `workspace.py:327-337` (invite) | ⚠️ accept path unverified |
| `folders` | ❌ | ✅ | ✅ | ✅ | `folder.py:131-141` | ✅ |
| `custom_domain` (bool) | ❌ | ❌ | ✅ | ✅ | `custom_domain.py:187-195` | ✅ |
| `max_custom_domains` | 0 | 0 | 1 | ∞ | `custom_domain.py:198-206` | ✅ |
| `max_workspaces` | 1 | 1 | 3 | ∞ | — (no create endpoint) | ❌ unenforced |
| `dynamic_qr_types` | 2 | 5 | 13 | 13 | `qr.py:1238-1257` (single create) | ⚠️ not gated in bulk loop |
| `max_file_size_mb` | 2 | 10 | 25 | 50 | `storage.py:227-239` | ✅ |
| `advanced_analytics` | ❌ | ❌ | ✅ | ✅ | `scan.py:113-123` (`_require_advanced_analytics`) | ✅ |
| `password_protection` | ❌ | ✅ | ✅ | ✅ | `qr.py:2256-2261` (PATCH) | ⚠️ create path unverified |
| `ab_testing` | ❌ | ❌ | ✅ | ✅ | `qr.py:1265-1269`, `~2371`, `scan.py:~410` | ✅ |
| `analytics_retention_days` | 7 | 30 | 90 | 365 | `scan.py:192-194` (`/days` only) | ⚠️ partial |
| `bulk_generation` | ❌ | ❌ | ✅ | ✅ | `qr.py:1999-2003` | ✅ (FE handler still mock) |
| `white_labeling` | ❌ | ❌ | ❌ | ✅ | registry `subscription.py:407` → KV/worker | ⚠️ worker path unverified |
| `api_access` / `api_calls_per_month` | — | — | 3,000 | 25,000 | — | ❌ inert (not built) |
| `lead_forms`, `retargeting_pixels`, `sso` | ❌ | ❌ | Pro+/Agency | Agency | — | ❌ inert flags |

## Free-tier scan model — how 2,000/mo actually behaves

- `_enforce_scan_limit` (`internal.py:478-530`) runs after every scan. It counts `qr_scan_events` for the workspace **in the current period** via `period_start_iso()` — which uses `subscriptions.current_period_start` if present, else the **UTC calendar-month start**. Free has no subscription ⇒ calendar-month ⇒ **2,000 scans/month, pooled across all QRs, auto-windowed.** The old "500 all-time, never resets" behavior described in `BILLING_ENFORCEMENT_PLAN.md` **is already gone** in live code. The migration only needs to bump the number 500 → 2,000 (done in 0009).
- On exceed: all `active` dynamic QRs are set to `status='disabled'` and KV-synced.

### ⚠️ Gap: free QRs don't auto-recover at month rollover (HIGH)
Re-enable only happens via `_reenable_dynamic_qrs_for_subscription` (`razorpay_routes.py:1115-1193`), which fires on a **subscription renewal/upgrade webhook**. **Free has no subscription and no webhook** — so a free workspace that trips 2,000 scans gets its QRs disabled and they stay disabled even though next month's count resets to 0. This breaks the "resets and recovers" promise in `PRICING_MODEL.md`.
**Fix options:** (a) a scheduled monthly job that re-enables disabled free-tier QRs whose current-period count is under the cap; or (b) lazy re-enable — on the worker's disabled-page path, call a backend re-check that re-enables if under the new period's limit. (a) is simpler and deterministic. **This must ship with the reprice** or free QRs become permanent-death-on-overage, which is worse than the bug we set out to fix.

## Gaps to close (prioritized)

1. **(CRITICAL — release gate) New payment objects.** Every paid INR price changed (₹599→399, ₹1499→999, ₹6999→2499) ⇒ new **Razorpay plans** (monthly + yearly) for starter/pro/agency. Pro/Agency USD changed ($24→19, $99→39) ⇒ new **Lemon Squeezy variants**; starter USD ($9/$90) unchanged. Migration 0009 **nulls** the stale `razorpay_plan_id_*` / `lemonsqueezy_variant_id_*` so checkout fails loudly instead of overcharging. **Create the objects (use `scripts/create_razorpay_plans.py`), backfill the columns, THEN deploy the new pricing page.** Existing subscribers are grandfathered (their `provider_sub_id` is an independent immutable object).
2. **(HIGH) Free monthly re-enable** — see the gap above.
3. **(MED) `dynamic_qr_types` in the bulk loop** — single create gates type (`qr.py:1238-1257`) but the bulk loop (`qr.py:2031+`) does not re-check, so a Free/Starter user could bulk-create disallowed types. Add the same type check inside the loop.
4. **(MED) `accept_invitation` member count** — the invite *issue* path gates `max_members` (`workspace.py:327-337`); verify acceptance also re-checks, or a workspace can exceed the cap via stale pending invites. Verify + add if missing.
5. **(MED) `max_scans` fail-open swallow** — `internal.py:469-472` swallows all enforcement exceptions (a thrown error ⇒ unlimited scans leak). Keep favoring UX (don't block scans on enforcement error) but **log** so leaks are visible.
6. **(MED) `white_labeling` worker enforcement** — registry claims enforced; verify `cloudflare_kv.py` writes the entitlement and the worker templates actually suppress the "Powered by Qravio" badge for Agency only.
7. **(LOW-MED) `analytics_retention_days` window** — only `/days` clamps (`scan.py:192-194`). `/summary`, `/top`, `/devices`, `/qrs/{id}` are un-windowed, so lower tiers can read full history. Clamp the raw-event endpoints (the `qr_scan_counters` JSONB is all-time and cannot be windowed without re-aggregation — document that).
8. **(LOW) `max_workspaces`** — no create-workspace endpoint exists, but the auto-create side-effect at `folder.py:150-155` could give a Free user a 2nd workspace. Guard if/when a create path is added.
9. **(LOW) `billing_cycle` display** — `GET /razorpay/subscriptions/current` derives it as `None` (`razorpay_routes.py:755`) despite being stored on create. Display bug only.
10. **(LOW) `password_protection` create path** — PATCH is gated (`qr.py:2256-2261`); confirm the create path is too.

## Deploy order (must be respected)

1. Create new Razorpay plans + Lemon Squeezy variants in the **dashboards** (staging keys first).
2. Apply migration **0009** (reprice + `is_public` + null stale pointers) on the target DB.
3. Backfill `razorpay_plan_id_*` / `lemonsqueezy_variant_id_*` with the new object IDs.
4. Ship the **free monthly re-enable** job (gap #2).
5. Deploy the **frontend** (4-tier `pricing.ts` + comparison table) — only now do visitors see ₹399/₹999/₹2,499 and $9/$19/$39.
6. Smoke-test one checkout per rail (INR Razorpay, USD Lemon Squeezy) on staging before prod.

Grandfathered `lite`/`business` subscribers keep their plan (rows retained, `is_public=false`); they simply disappear from the pricing/upgrade UI.
