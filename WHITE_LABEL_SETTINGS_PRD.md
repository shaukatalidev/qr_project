# PRD — White-Label Settings UI

**Status:** Draft · **Author:** Engineering · **Date:** 2026-06-14
**Priority:** **2nd, after API Access** (eng-review D1) — smallest build, no consent dependency, so it's the fast second win before the consent-gated features.
**Tiers:** Agency (`white_labeling`) — already `true` for Agency in the DB.
**Split from:** `PLAN_LIMITS_ENFORCEMENT_PRD.md`.

---

## 1. Background — what already exists vs. what's missing
The white-label **enforcement** is **done** (Plan-Limit Enforcement work): when a workspace has `white_labeling`, the worker already **suppresses** "Powered by Qravio" across all content templates *and* the system pages (`scanLimitPage`, `disabledPage`, `passwordGatePage`, `planLimitPage`) via the `entitlements.white_labeling` KV snapshot. The registry classifies `white_labeling` as `enforced`.

**What's missing is the positive branding layer:** today white-label only *removes* Qravio branding. Agencies want to *add their own* — custom logo, brand color, and a custom "powered by" line — on the QR landing/system pages. This PRD adds the **settings UI + brand propagation**. No new gate is needed (the flag is already enforced).

## 2. Goals & Non-Goals
**Goals:** an Agency settings page to set a **custom logo, brand color, and custom footer text/link** (optionally favicon); propagate those assets through KV to the worker; render them in place of the suppressed Qravio branding.
**Non-Goals:** fully custom CSS/themes, custom email-template branding (separate effort), per-QR brand overrides (workspace-level only for v1). Custom domains are already a separate shipped feature.

## 3. Design
1. **Storage:** a `workspace_branding` row (or a `branding` object in `workspaces.settings` jsonb). Logo/favicon uploaded via existing Supabase Storage (`storage.py` + `DirectUpload`).
2. **KV propagation:** extend `build_entitlements` (`cloudflare_kv.py`) so that when `white_labeling` is true it also emits a `brand` object `{ logo_url, brand_color, footer_text, footer_url }`. Snapshot-at-write — **re-sync the workspace's QRs** when branding changes (reuse the existing per-QR `sync_qr_to_kv` loop; same caveat as the white-label snapshot today).
3. **Worker rendering:** the templates already branch on `whiteLabel`. Extend that branch: when a `brand` object is present, render the custom logo/color/footer *instead of nothing* (currently white-label just renders nothing there). Centralize in the shared design util (`src/utils/design.js`).
4. **Settings UI:** an Agency-only settings section (logo upload, color picker, footer text/link) gated on `canAccessFeature(sub,'white_labeling')`, with a live preview.

**Input validation (eng-review):** validate `brand_color` as a hex (`#RGB`/`#RRGGBB`) and sanitize `footer_text`/`footer_url` at WRITE time before they reach KV — these are injected into worker template CSS/HTML, so an unvalidated color or footer is a CSS/HTML-injection vector. Logo/favicon uploads reuse `storage.py` `validate_file` + the 50MB absolute cap.

## 4. Data Model (migration)
```sql
CREATE TABLE workspace_branding (
  workspace_id uuid PRIMARY KEY REFERENCES workspaces(id) ON DELETE CASCADE,
  logo_url text,
  favicon_url text,
  brand_color text,          -- hex
  footer_text text,
  footer_url text,
  updated_at timestamptz NOT NULL DEFAULT now()
);
```
No plan-flag migration needed (`white_labeling` already true for Agency, already `enforced`).

## 5. Phases
- **Phase 1:** table + settings UI (logo + color + footer) + `build_entitlements` `brand` propagation + re-sync on save + worker renders custom branding. **Acceptance:** an Agency sets a logo+color; their QR landing + system pages show it (not Qravio, not blank); a non-Agency workspace can't access the page; downgrading clears branding at the edge on the next sync.
- **Phase 2:** favicon, custom email-from branding, per-QR override.

## 6. Testing
Branding renders only when `white_labeling` true (downgrade hides it via the existing entitlement snapshot); save triggers KV re-sync; settings page denied to non-Agency; worker template parity with the React preview.

## 7. Open Questions
1. Scope of "brand" — logo + color + footer enough for v1, or also custom domain "from" / email branding? (Recommend logo+color+footer first.)
2. Store under a dedicated `workspace_branding` table or `workspaces.settings` jsonb? (Recommend the table — typed, indexable, cleaner than overloading settings.)

## 8. Appendix — Key Files
| Concern | File |
|---|---|
| Entitlement/brand snapshot | `qr_backend/src/utilities/cloudflare_kv.py` (`build_entitlements`, `sync_qr_to_kv`) |
| Worker branding branch | `qr_cf_code/src/utils/design.js`, content + system page templates (`scanLimitPage.js`, `disabledPage.js`, `passwordGatePage.js`, `planLimitPage.js`) |
| Upload | `qr_backend/src/api/routes/storage.py`, `qr_frontend/.../content-types/DirectUpload` |
| Gating (already enforced) | `qr_backend/src/api/routes/subscription.py` (`white_labeling`), `qr_frontend/src/lib/plan-features.ts` |
| Settings UI | `qr_frontend/src/app/org/[slug]/(dash)/settings/…` |
