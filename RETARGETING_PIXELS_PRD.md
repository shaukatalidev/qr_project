# PRD — Retargeting Pixels

**Status:** Draft · **Author:** Engineering · **Date:** 2026-06-14
**Priority:** 4th / last — **consent-gated**: build after the shared consent/cookie gate (eng-review D1). Pixels are tracking cookies.
**Tiers:** Pro+ (`retargeting_pixels`) — seeded `false` everywhere by migration 0009; this feature's migration flips Pro/Agency on.
**Split from:** `PLAN_LIMITS_ENFORCEMENT_PRD.md`.

---

## 1. Background
Sold at Pro+, not built (flag-only, `inert`). Retargeting lets a workspace fire ad-platform pixels (Meta, Google Ads, LinkedIn, TikTok) when someone lands on a worker-rendered QR page, so they can build remarketing audiences from scans.

**Key constraint:** pixels can only be injected into pages the worker actually **renders as HTML** (vcard, pdf, business, list_links, images, lead_form, etc.). Pure `website` redirects (302 to an external URL) **cannot** carry a pixel — the visitor never sees our HTML. The UI must make this explicit.

## 2. Goals & Non-Goals
**Goals:** workspace-level pixel config (+ optional per-QR override), `<script>`/`<img>` snippet injection into worker landing pages, a settings UI, gated behind `retargeting_pixels`.
**Non-Goals:** server-side conversion APIs (Meta CAPI), custom event mapping, consent-management platform integration (see Open Questions).

## 3. Design
1. **Config storage:** workspace-scoped pixels (provider + id), with an optional per-QR enable/disable. Snapshot into KV so the worker injects without a backend call at scan time.
2. **KV propagation:** extend the per-QR KV value with a `pixels` array (alongside the existing `entitlements`) in `build_kv_content`/`sync_qr_to_kv` (`cloudflare_kv.py`). Only populate when the workspace has `retargeting_pixels` AND the QR type renders HTML. Snapshot-at-write — re-sync the workspace's QRs when pixels change (same pattern as white-label/A-B entitlement snapshots).
3. **Worker injection (security-critical — eng-review D3):** validate `pixel_id` at WRITE time against a strict per-provider regex (Meta = 15-16 digits, Google = `AW-`/`G-`+alnum, etc.) and reject anything else; the worker injects ONLY from a hardcoded per-provider snippet template in one util (`src/utils/pixels.js`). **Never interpolate free-form text into a `<script>`** — HTML-escaping a script body does not make it safe; this is the difference between a feature and a stored-XSS hole on customer-facing pages.
4. **Settings UI:** a workspace settings section to add/remove pixels (provider dropdown + id), gated; per-QR override toggle in the builder.

## 4. Data Model (migration)
```sql
CREATE TABLE retargeting_pixels (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  workspace_id uuid NOT NULL REFERENCES workspaces(id) ON DELETE CASCADE,
  provider text NOT NULL,            -- 'meta' | 'google_ads' | 'linkedin' | 'tiktok'
  pixel_id text NOT NULL,
  is_active boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX idx_retargeting_ws ON retargeting_pixels(workspace_id) WHERE is_active;
```
Plus flip `retargeting_pixels` true for Pro/Agency.

## 5. Gating
- BE: `check_feature(workspace_id,'retargeting_pixels')` on pixel create/update; flip `FEATURE_ENFORCEMENT` `inert→enforced` in the same PR.
- Worker: only injects when the snapshotted config is present (which the backend only writes for entitled workspaces) — defense-in-depth like the A/B entitlement guard.
- FE: `canAccessFeature(sub,'retargeting_pixels')` gates the settings section + per-QR toggle.

## 6. Phases
- **Phase 1:** table + flag flip · workspace pixel CRUD (Meta + Google first) · KV `pixels` propagation + worker injection util · settings UI · gate. **Acceptance:** a Pro workspace adds a Meta pixel; scanning an HTML-rendering QR fires it (verify in browser/Pixel Helper); a `website` redirect QR shows "not supported"; non-Pro can't configure.
- **Phase 2:** per-QR overrides · LinkedIn/TikTok · consent gating (§Open Questions).
- **Phase 3:** server-side conversions (Meta CAPI) if demand appears.

## 7. Testing
Snapshot writes only for entitled workspaces; **a malformed/malicious pixel_id is rejected at write** (XSS-injection test); the worker injects only validated ids from fixed templates; redirect-only types never inject; gate denies non-Pro; pixel change re-syncs KV.

## 8. Open Questions
1. **Consent/GDPR is a launch blocker for EU traffic** — ad pixels are tracking cookies. Need a cookie-consent gate before firing in the EU (shares the unresolved consent decision in the Mixpanel PRD). Decide: geo-gate, consent banner on landing pages, or EU-off by default.
2. Workspace-wide only, or per-QR overrides in v1? (Recommend workspace-wide first.)
3. Which providers at launch? (Recommend Meta + Google Ads.)

## 9. Appendix — Key Files
| Concern | File |
|---|---|
| KV snapshot + entitlements | `qr_backend/src/utilities/cloudflare_kv.py` (`build_kv_content`/`build_entitlements`/`sync_qr_to_kv`) |
| Worker page templates + new util | `qr_cf_code/src/pages/`, `src/handlers/qrRouter.js`, new `src/utils/pixels.js` |
| Gating | `qr_backend/src/api/routes/subscription.py`, `qr_frontend/src/lib/plan-features.ts` |
| Settings UI | `qr_frontend/src/app/org/[slug]/(dash)/settings/…` |
