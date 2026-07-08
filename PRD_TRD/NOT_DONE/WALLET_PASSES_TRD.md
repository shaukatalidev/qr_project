# TRD — Apple/Google Wallet Passes (loyalty, coupon, ticket)

**Status:** Draft · **Author:** Engineering (Staff) · **Date:** 2026-06-24

**Rev (2026-06-24, post eng-review):** Scope accepted as Apple-only Phase 1. Fixes applied: (1) migration slot 0023 clarified as a *forward* reservation (disk highest = 0013; 0014–0022 absent) with a mandatory pre-apply `ls migrations/` collision check; (2) added `wallet_passes.update_tag bigint` (monotonic) + `pass_registrations.last_pushed_tag bigint` to make PassKit `passesUpdatedSince` and APNs pushes **idempotent + durably re-drivable** (in-process `BackgroundTasks` die on dyno restart, so a bounded re-drive of lagging registrations is the backstop); (3) corrected the rate-limit plan — the lead-submit limiter counts persisted `qr_lead_submissions` rows and **does not transfer** to install/web-service routes (no row persisted), so those need an explicit IP-bucket limiter (in-process token bucket or a tiny `wallet_install_hits` counter) + uniform 404 timing; (4) pinned the exact `excluded_routes` prefixes (`{API_PREFIX}/wallet/apple` only) so the authenticated `…/workspaces/{ws}/wallet/signing-config` routes are **never** un-Beared by the `startswith` prefix match; (5) hardened `.p12` ingest as untrusted crypto input (size-cap, password-required, parse in a guarded path, never echo bytes); (6) signing-config/test-pass routes get their own rate cap to blunt cert-parse CPU abuse.
**Tiers / flags:** Pro + Agency, via a **NEW** `wallet_passes` bool flag. Registered in `FEATURE_ENFORCEMENT` as `inert` at Phase 0, flipped to `enforced` in the **same PR** that lands the Apple write/install path (Phase 1). Branded passes ride the existing `white_labeling`/`brand` flag (Agency) — no new flag.
**Migration slot:** `0023_wallet_passes.sql` — **forward reservation only.** Disk reality: the highest file present is `0013`; **no `0014`–`0022` files exist** (the "reserved by roadmap specs" notes live in other PRDs, not on disk). The implementer MUST run `ls qr_backend/migrations/` immediately before applying and renumber to the lowest free slot if anything landed in between; do not assume the gap is real. Phases 2 (Google) and 3 (geofence/bulk push) ship **additive** schema in later migrations — 0023 carries only Phase-1 (Apple) schema.
**Services touched (Phase 1):** `qr_backend` (heavy — new signing service, install route, PassKit web-service, APNs push, loyalty type), `qr_frontend` (Settings cert upload, `LoyaltyContent`, wallet-pass authoring panel, previews), `qr_cf_code` (scan-page Add-to-Wallet button + new `loyalty` type page; **no signing on the edge**).

---

## 1. Overview & Architecture

Qravio already renders **coupon** and **event** dynamic-QR scan pages (`couponPage.js`, `eventPage.js`; backend coupon branch in `qr.py` `_build_content_from_db_rows` ~L1065, event ~L1050). This feature converts those one-shot landing pages into installable **Apple `.pkpass`** (Phase 1) and **Google Wallet** (Phase 2) passes, plus a new **loyalty** sub-type. The pass is push-updatable: editing the QR's pass fields refreshes every holder's installed pass via APNs (Apple) / REST `patch` (Google).

The defining constraint: **signing happens only on the backend**. Apple `.pkpass` is a PKCS#7-signed zip using a Pass Type ID private key + the WWDR intermediate; shipping that key to the Cloudflare Worker is a non-starter. So the Worker change is purely a rendered **Add-to-Wallet button** that points at a public backend install URL. All crypto, cert custody, registration webhooks, and push live in `qr_backend`.

**Services & responsibilities (Phase 1, Apple):**

| Concern | Service | Files |
|---|---|---|
| Migration (2 tables + signing config + flag flip) | qr_backend | `migrations/0023_wallet_passes.sql` (new) |
| `.pkpass` signing (PKCS#7, WWDR chain) | qr_backend | `src/utilities/pass_signing.py` (new) |
| Pass CRUD + public install + PassKit web-service + APNs push | qr_backend | `src/api/routes/wallet.py` (new) |
| Router registration | qr_backend | `src/api/endpoints.py` |
| Public route exclusion (install + webhooks) | qr_backend | `src/main.py` `excluded_routes` |
| Gating + `FEATURE_ENFORCEMENT` flip | qr_backend | `src/api/routes/subscription.py` |
| KV `wallet` block + loyalty `build_kv_content` branch | qr_backend | `src/utilities/cloudflare_kv.py` |
| Loyalty type wiring (Literal, model, SELECT join) | qr_backend | `src/api/routes/qr.py` |
| Add-to-Wallet button + loyalty page/template | qr_cf_code | `src/pages/{coupon,event,loyalty}/` |
| Settings cert upload + authoring panel + previews | qr_frontend | `WalletPassesSection.tsx`, `LoyaltyContent.tsx`, `templates/` |
| FE gating | qr_frontend | `src/lib/plan-features.ts`, `src/hooks/useSubscription.ts` |

**Data flow — author:** Builder coupon/event/loyalty form toggles "Wallet Pass" → `POST/PUT /qrs` writes the QR + a `wallet_passes` template row → `write_to_kv()` runs synchronously and `build_kv_content` emits a small top-level `wallet` block `{ enabled, pass_id, platforms }` so the scan page knows to render the button.

**Data flow — install (public, no login):** Scan → Worker renders landing page with platform-detected button → tap hits `GET /wallet/apple/{pass_id}?t=<token>` → backend re-checks gate + signs a fresh `.pkpass` → returns `application/vnd.apple.pkpass`. On install Apple POSTs the device→pass mapping into `pass_registrations` via the PassKit web-service contract.

**Data flow — update:** QR pass edit / loyalty stamp bump writes new content and bumps `wallet_passes.update_tag` → backend enqueues an **idempotent** async APNs push to every registration whose `last_pushed_tag` lags the new tag → each device calls back `GET /wallet/apple/v1/passes/{passTypeId}/{serial}` → backend returns the re-signed pass (and `passesUpdatedSince` returns serials by comparing `update_tag`). Push is backend-side, `BackgroundTasks`-driven (best-effort, lost on dyno restart → durable re-drive backstop, §3.1), never on the Worker scan hot path.

---

## 2. Data Model & Migrations

**File:** `qr_backend/migrations/0023_wallet_passes.sql` — `BEGIN/COMMIT`-wrapped, idempotent (`IF NOT EXISTS` / `jsonb_set`), applied by hand in the Supabase SQL editor (no automated runner). All backend queries use the Supabase **service-role key, which bypasses RLS**; no RLS policies are added — tenant isolation is enforced in route code via explicit `.eq("workspace_id", ...)` filters + `workspace_members` role checks (§9). The flag flip uses the **house convention** (`lower(name)` + `is_custom` guard + `coalesce` NULL-coalesce; never a bare `WHERE name IN (...)`).

```sql
-- Migration 0023: Apple/Google Wallet Passes — Phase 1 (Apple) schema ONLY.
-- Google-specific columns (object ids, issuer class) and geofence/bulk-push
-- tables are deferred to later additive migrations (Phases 2/3).
BEGIN;

-- (1) Per-workspace pass template + encrypted Apple signing config.
--     One row per QR that has wallet enabled; signing config columns are
--     workspace-scoped and duplicated-on-write is avoided by reading the
--     latest non-null config for the workspace (see note). Cert/key are
--     ENCRYPTED at rest (Fernet via backend secret) — never plaintext, never
--     sent to FE/Worker.
CREATE TABLE IF NOT EXISTS wallet_passes (
    id                uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    qr_id             uuid        NOT NULL REFERENCES qr_codes(id) ON DELETE CASCADE,
    workspace_id      uuid        NOT NULL REFERENCES workspaces(id) ON DELETE CASCADE,
    pass_style        text        NOT NULL,        -- 'coupon' | 'eventTicket' | 'storeCard' (loyalty)
    serial_number     text        NOT NULL,        -- stable per QR; PassKit serial
    auth_token        text        NOT NULL,        -- per-pass PassKit authenticationToken (opaque)
    template          jsonb       NOT NULL DEFAULT '{}'::jsonb, -- header/primary/secondary fields, bg color, logo url, expiry, locations
    is_enabled        boolean     NOT NULL DEFAULT true,
    update_tag        bigint      NOT NULL DEFAULT 1,  -- monotonic; bumped on every content edit. Drives PassKit
                                                       -- `passesUpdatedSince` AND APNs push idempotency (re-push
                                                       -- for the same tag is a no-op). NON-atomic RMW is fine here:
                                                       -- a single-writer QR-update path bumps it via SET update_tag
                                                       -- = update_tag + 1 in the same statement, not jsonb RMW.
    created_at        timestamptz NOT NULL DEFAULT now(),
    updated_at        timestamptz NOT NULL DEFAULT now(),
    UNIQUE (qr_id)
);
CREATE INDEX IF NOT EXISTS idx_wallet_passes_ws   ON wallet_passes (workspace_id);
CREATE INDEX IF NOT EXISTS idx_wallet_passes_qr   ON wallet_passes (qr_id);

-- (2) Per-workspace Apple signing config (separate from pass rows so it is
--     authored once in Settings; cert + key encrypted at rest).
CREATE TABLE IF NOT EXISTS wallet_signing_config (
    workspace_id        uuid        PRIMARY KEY REFERENCES workspaces(id) ON DELETE CASCADE,
    apple_team_id       text,
    apple_pass_type_id  text,                       -- pass.com.qravio.<ws> Pass Type Identifier
    apple_cert_enc      text,                       -- Fernet-encrypted .p12 (cert+key), base64
    apple_cert_fingerprint text,                    -- for display only, non-secret
    google_issuer_id    text,                       -- Phase 2 (nullable now)
    is_active           boolean     NOT NULL DEFAULT true,
    created_at          timestamptz NOT NULL DEFAULT now(),
    updated_at          timestamptz NOT NULL DEFAULT now()
);

-- (3) Device↔pass registrations (PassKit web-service source of truth for push).
CREATE TABLE IF NOT EXISTS pass_registrations (
    id                 uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    pass_id            uuid        NOT NULL REFERENCES wallet_passes(id) ON DELETE CASCADE,
    device_library_id  text        NOT NULL,        -- Apple deviceLibraryIdentifier
    push_token         text        NOT NULL,        -- APNs push token for this device
    serial_number      text        NOT NULL,
    platform           text        NOT NULL DEFAULT 'apple',  -- 'apple' | 'google' (Phase 2)
    last_pushed_tag    bigint      NOT NULL DEFAULT 0,        -- highest wallet_passes.update_tag we have
                                                              -- successfully pushed to this device. The durable
                                                              -- re-drive re-pushes any registration WHERE
                                                              -- last_pushed_tag < pass.update_tag (idempotent backstop
                                                              -- for BackgroundTasks lost to a dyno restart).
    created_at         timestamptz NOT NULL DEFAULT now(),
    UNIQUE (pass_id, device_library_id)             -- register is idempotent
);
CREATE INDEX IF NOT EXISTS idx_pass_reg_pass    ON pass_registrations (pass_id);
CREATE INDEX IF NOT EXISTS idx_pass_reg_serial  ON pass_registrations (serial_number);

-- (4) Loyalty sub-type detail table (mirrors qr_coupon_details / qr_event_details).
CREATE TABLE IF NOT EXISTS qr_loyalty_details (
    qr_id            uuid        PRIMARY KEY REFERENCES qr_codes(id) ON DELETE CASCADE,
    program_name     text        NOT NULL DEFAULT '',
    reward_text      text,                          -- "Buy 9 get 1 free"
    stamps_required  int         NOT NULL DEFAULT 10,
    stamps_current   int         NOT NULL DEFAULT 0,
    business_name    text,
    website_url      text,
    terms            text,
    created_at       timestamptz NOT NULL DEFAULT now(),
    updated_at       timestamptz NOT NULL DEFAULT now()
);

-- (5) Plan flag — HOUSE CONVENTION. Seed false everywhere (only where absent),
--     then enable for Pro + Agency. is_custom guard + coalesce NULL-safety.
UPDATE plans
SET features = jsonb_set(coalesce(features, '{}'::jsonb), '{wallet_passes}', 'false'::jsonb, true)
WHERE NOT (coalesce(features, '{}'::jsonb) ? 'wallet_passes')
  AND coalesce(is_custom, false) = false;

UPDATE plans
SET features = jsonb_set(coalesce(features, '{}'::jsonb), '{wallet_passes}', 'true'::jsonb, true)
WHERE lower(name) IN ('pro', 'agency')
  AND coalesce(is_custom, false) = false;

-- (6) Add 'loyalty' to the dynamic types allowlist for Pro/Agency so the
--     existing dynamic_qr_types gate (qr.py L1285) permits creation.
UPDATE plans
SET features = jsonb_set(
      features,
      '{dynamic_qr_types}',
      (coalesce(features->'dynamic_qr_types', '[]'::jsonb) || '["loyalty"]'::jsonb),
      true)
WHERE lower(name) IN ('pro', 'agency')
  AND coalesce(is_custom, false) = false
  AND NOT (coalesce(features->'dynamic_qr_types', '[]'::jsonb) ? 'loyalty');

COMMIT;
-- Sanity: SELECT name, features->>'wallet_passes',
--   features->'dynamic_qr_types' FROM plans
--   WHERE coalesce(is_custom,false)=false ORDER BY price_monthly;
```

`auth_token` and `apple_cert_enc` are secrets that never leave the backend. The public install token is a separate short-lived HMAC over `pass_id` (§8), not `auth_token`.

---

## 3. Backend Design

### 3.1 New router `src/api/routes/wallet.py`

Registered in `endpoints.py` (`router.include_router(router=wallet_router)`). Split into **authenticated** (Bearer, workspace-scoped) and **public** (install + PassKit web-service) sections.

**Authenticated (Bearer + `require_can_*` + `await check_feature`):**

- `POST /workspaces/{workspace_id}/wallet/signing-config` — upload Apple cert. Body = multipart `.p12` + `team_id` + `pass_type_id` + `p12_password`. `require_can_update`, `await check_feature(ws, "wallet_passes", db)` → 403 if absent. **Untrusted-crypto-input handling:** size-cap the upload (e.g. ≤256 KB — a `.p12` is tiny), require a non-empty `p12_password`, parse cert+key in a guarded path (catch `cryptography` exceptions → 422, never 500/stack-trace), check the WWDR chain, then Fernet-encrypt and store in `wallet_signing_config`. Never echo the raw bytes or password back in any response or log. Returns `{ configured: true, fingerprint, pass_type_id }` — **never** the cert/key. This route is itself rate-capped (cert parsing is CPU; see §8).
- `POST /workspaces/{workspace_id}/wallet/test-pass` — signs a sample `.pkpass` from the stored config and streams it back (validates the cert end-to-end). Gated identically.
- `GET /workspaces/{workspace_id}/wallet/signing-config` — returns `{ configured, fingerprint, pass_type_id, google_issuer_id }` (non-secret display fields only).
- Pass authoring is **not** a separate route — the wallet template is written by the existing `POST/PUT /qrs` handler when the coupon/event/loyalty payload includes a `wallet` block (writes/updates the `wallet_passes` row inside the same transaction-ish sequence, then `write_to_kv`).

**Push on update:** in the QR update handler, after writing pass content, bump `wallet_passes.update_tag` (`SET update_tag = update_tag + 1`) in the same write, then call `wallet.enqueue_push(pass_id, db, background_tasks)`. It loads `pass_registrations WHERE last_pushed_tag < update_tag` for the pass and fires APNs notifications (token-based auth key, held as a backend secret `APNS_AUTH_KEY` / `APNS_KEY_ID` / `APNS_TEAM_ID`), advancing `last_pushed_tag` on ack. The push is **idempotent** — re-firing for an already-pushed tag is a no-op. Note `BackgroundTasks` run in-process and are **lost on a Render dyno restart/deploy**, so this is best-effort; the reliability backstop is a bounded **durable re-drive** (a tiny periodic or next-edit-triggered sweep that re-pushes any registration whose `last_pushed_tag` lags the current `update_tag`). Failures are logged and **never** block the QR write response. (If a true scheduled sweep is later added on the Worker, it registers only after `npm run deploy:prod` — but v1's re-drive is backend-side, no cron.)

**Public (added to `excluded_routes` in `main.py`):** `BearerTokenAuthMiddleware._is_excluded` is a **`path.startswith(prefix)`** prefix match (verified in `auth_bearer.py`), so the excluded prefix MUST be the public-only stem **`{settings.API_PREFIX}/wallet/apple`** (covers install + every PassKit web-service path). It MUST NOT be the broader `{API_PREFIX}/wallet` — that would un-Bearer the authenticated `…/workspaces/{ws}/wallet/signing-config` and `…/wallet/test-pass` cert routes and expose the upload path with no auth. The authenticated routes deliberately live under the `/workspaces/{ws}/…` stem, never under `/wallet/apple`. (Phase 2's `GET /wallet/google/{pass_id}` adds a second exact prefix `{API_PREFIX}/wallet/google`.)

- `GET /wallet/apple/{pass_id}` — install. Validates the HMAC `t` token, loads the pass, **re-checks** `await check_feature(ws, "wallet_passes", db)` (downgrade safety), signs a fresh `.pkpass`, returns it with `Content-Type: application/vnd.apple.pkpass`. Gate fail → `403` clean "pass unavailable" body. Disabled/deleted pass → `404` branded message, no stack trace.
- `GET /wallet/google/{pass_id}` — Phase 2: 302 to the Google "Save to Google Wallet" link minted from the service-account JWT.
- **PassKit web-service** (Apple's fixed contract — `webServiceURL` baked into the `.pkpass`, auth via `Authorization: ApplePass <auth_token>`):
  - `POST /wallet/apple/v1/devices/{deviceLibraryId}/registrations/{passTypeId}/{serial}` — register; upserts `pass_registrations` (idempotent on UNIQUE). 201 first time / 200 if already.
  - `DELETE /wallet/apple/v1/devices/{deviceLibraryId}/registrations/{passTypeId}/{serial}` — unregister; deletes the row.
  - `GET /wallet/apple/v1/devices/{deviceLibraryId}/registrations/{passTypeId}?passesUpdatedSince=<tag>` — returns serials updated since tag.
  - `GET /wallet/apple/v1/passes/{passTypeId}/{serial}` — returns the re-signed `.pkpass` (used after a push).
  - `POST /wallet/apple/v1/log` — Apple error log sink (200, store nothing sensitive).

All web-service routes verify the `ApplePass <auth_token>` header against `wallet_passes.auth_token` for that serial — this is the PassKit-native per-pass secret, distinct from the install HMAC.

### 3.2 Signing service `src/utilities/pass_signing.py`

`sign_pkpass(pass_dict, images, signing_config) -> bytes`: builds `pass.json`, computes the `manifest.json` SHA-1 digests, produces the PKCS#7 detached signature over the manifest using the workspace cert/key + WWDR intermediate (`cryptography` / `pkcs7`), and zips `pass.json` + `manifest.json` + `signature` + images. Pinned deps in `requirements.txt`: `cryptography` (already present), `cryptography.hazmat ... pkcs7`. The WWDR intermediate ships as a bundled asset. `build_apple_pass_dict(qr_row, wallet_row)` maps coupon→`coupon`, event→`eventTicket`, loyalty→`storeCard` and emits `relevantDate`/`expirationDate`/`locations`. **No PII** is ever placed in the dict (§9).

### 3.3 KV + new loyalty type (7-step seam)

- **`build_kv_content`** (`cloudflare_kv.py`): add a `loyalty` branch reading `qr_loyalty_details`; and, for any QR with a `wallet_passes` row where `is_enabled`, emit a top-level `wallet` block `{ enabled: true, pass_id, platforms: ["apple"], install_url }` (install URL carries the HMAC token). No cert data ever enters KV.
- **`qr.py`**: add `"loyalty"` to the `type` Literal (~L736); add `LoyaltyContent` pydantic model; add `qr_loyalty_details(*)` to `SELECT_WITH_RELATIONS` (~L836); add the `loyalty` branch in `_build_content_from_db_rows`.
- **`FEATURE_ENFORCEMENT`** (`subscription.py` ~L428): add `"wallet_passes": "inert"` at Phase 0, flip to `"enforced"` in the Phase 1 PR (commented `# wallet.py install + qr.py author check_feature`). `test_feature_gate_coverage` asserts registry↔seed parity — kept green because 0023 seeds the flag everywhere.
- **`build_entitlements`**: unchanged for v1 — passes are gated/signed at the backend, not the edge. Branded passes read `workspace_branding` backend-side when `white_labeling` is active (reuse `_fetch_workspace_brand`).

---

## 4. Cloudflare Worker / Edge Design

The Worker **never signs**. Changes are render-only.

- **`build_kv_content`** adds the top-level `wallet` block (above) into the KV value (now ~12 top-level keys: `…, content, entitlements, pixels, wallet`).
- **`qrRouter.js`**: add a `loyalty` case in `handleQRCode` dispatching to a new `src/pages/loyalty/index.js` (mirroring coupon/event dispatcher pattern with `templateId` selection and a backend fallback `/internal/loyalty/{qr_id}`).
- **New `src/pages/loyalty/`**: `index.js` dispatcher + at least `legacyTemplate.js` + `stampCardTemplate.js`, plus `helpers.js`. Use `escapeHTML()` on all user data.
- **Add-to-Wallet button** (shared partial, e.g. `src/pages/walletButton.js`): when `kvValue.wallet?.enabled`, render a platform-detected button. iOS UA → Apple `PKAddPassButton` styling linking to `wallet.install_url` (the backend `GET /wallet/apple/{pass_id}?t=…`); Android → Google button (Phase 2, hidden in v1 if no Google link); desktop → show both. Inject the partial into `couponPage.js`, `eventPage.js`, and the new loyalty page.
- **Scan-data implications:** the button tap is a navigation to the backend, **not** a `recordScan` event — install conversion is measured backend-side at the install route (deduped per `session_id` that the Worker can pass as a query param `s=`, computed exactly as in `scan.js`: `SHA-256(IP+UA+today)` 16-hex). The scan itself is still recorded by the existing flow; no new edge scan fields.
- **Template↔React mirroring (house rule):** every new Worker template (loyalty `legacy`/`stampCard`, and the wallet-button states) must have a matching React preview in `qr_frontend/.../templates/loyalty/` and the button preview in the authoring panel.
- **Consent gate:** not triggered — passes carry **no** marketing pixels/cookies; `hasMarketingTags` is unaffected.
- **`scheduled()` / crons:** **none in v1.** Pushes are event-driven (on QR edit). A future Phase-3 geofence/bulk-sweep cron would register **only after `npm run deploy:prod`** (worker prod = `qr-worker-prod`). Worker deploy order: dev (`sparkling-waterfall-3a9f`) → verify → prod.

---

## 5. Frontend Design

All UI uses shadcn/ui primitives, Tailwind tokens (`primary #4648d4` indigo, `tertiary` cyan, `surface-container-*`, `on-surface`), react-hook-form + zod, files ≤200 lines, one export, kebab-case. Server state via TanStack Query + `authApi` (`src/lib/api-client.ts`); never `useEffect+fetch`.

- **`useSubscription.ts`** — add `wallet_passes: boolean;` to the `PlanFeatures` interface.
- **`plan-features.ts`** — `canAccessFeature(sub, 'wallet_passes')` already works generically off `PlanFeatures`; no special case needed beyond the interface field.
- **Settings → `WalletPassesSection.tsx`** (`org/[slug]/(dash)/settings/`, sibling to `PixelsSection`/`BrandingSection`). Gated by `canAccessFeature(sub, 'wallet_passes')`; Free/Starter render the existing upgrade-gate component. Contains: Apple cert `.p12` uploader (multipart → `POST .../wallet/signing-config`), Team ID + Pass Type ID inputs (zod), a "Test pass" button (`POST .../wallet/test-pass` → downloads the `.pkpass`), and a configured-state badge showing the fingerprint. New hook `src/hooks/useWalletConfig.ts` with a `walletKeys` factory (`walletKeys.config(workspaceId)`).
- **Authoring panel** — extend `content-types/CouponContent.tsx`, `EventContent.tsx`, and new `content-types/LoyaltyContent.tsx` with a "Wallet Pass" toggle + a `WalletPassFieldsPanel.tsx` (header/primary/secondary fields, background color, logo-from-branding, expiry, geofence locations list). Field state folds into the QR create/update payload's `wallet` block — no separate save call.
- **New loyalty type FE seam:** `LoyaltyContent.tsx` content form; React preview components in `templates/loyalty/`; a `loyalty` case in `TemplatePicker.tsx` and `PagePreview.tsx`; loyalty entry in `src/lib/constants/page-templates.ts` (`LOYALTY_TEMPLATES`).
- **Hooks:** reuse `useQRs`/`qrKeys`; new `useWalletConfig`. No analytics-key changes in v1 (install metrics are read backend-side; a passes dashboard is Phase 3).

---

## 6. AI / External-Service Integration

**No AI on any path** — passes are merchant-authored; the explicit non-goal forbids per-holder AI copy in v1. (Any future segment copy runs backend-side only, Haiku-tier, metered/capped, confirm-before-save.)

**External services:**
- **Apple PassKit** — Pass Type ID cert + WWDR intermediate (per-workspace cert upload, stored Fernet-encrypted); **APNs token-based auth** (recommended over a managed provider): `APNS_AUTH_KEY`/`APNS_KEY_ID`/`APNS_TEAM_ID` as backend secrets. Push topic = the Pass Type Identifier.
- **Google Wallet (Phase 2)** — one Qravio issuer, per-workspace class IDs; service-account JWT signs Save links and `patch` updates; secret held backend-side, never per-workspace in the browser.
- **Cert encryption** — Fernet via a backend `WALLET_ENC_KEY` secret (KMS is a future hardening option). Plaintext at rest is prohibited.
- **Email** — **not in v1** (install is in-app + scan-page only). If a future phase emails an install link, **publishing `_dmarc.qravio.app` is a hard GA prerequisite** (currently unpublished; SPF/DKIM already align via `send.qravio.app`). Resend would be the sender.
- **PDF** — none (passes are `.pkpass`/Google objects, not PDFs); WeasyPrint not involved.

---

## 7. API Contracts

```
POST /api/v1/workspaces/{ws}/wallet/signing-config   (Bearer, require_can_update, check_feature)
  multipart: p12=<file>, team_id, pass_type_id, p12_password
  200 → { "configured": true, "fingerprint": "AB:CD:…", "pass_type_id": "pass.com.qravio.x" }
  403 → { "detail": "wallet_passes not available on your plan" }

POST /api/v1/workspaces/{ws}/wallet/test-pass        (Bearer, require_can_update, check_feature)
  200 → application/vnd.apple.pkpass  (binary)
  409 → { "detail": "No Apple certificate configured" }

GET  /api/v1/wallet/apple/{pass_id}?t=<hmac>&s=<session>   (PUBLIC, excluded_routes)
  200 → application/vnd.apple.pkpass
  403 → text "Pass unavailable" (gate lost)
  404 → branded "Pass not found" (deleted/disabled)

POST /api/v1/wallet/apple/v1/devices/{deviceLibraryId}/registrations/{passTypeId}/{serial}
  Header: Authorization: ApplePass <auth_token>
  body: { "pushToken": "<apns-token>" }
  201 (new) | 200 (exists) | 401 (bad auth_token)

GET  /api/v1/wallet/apple/v1/passes/{passTypeId}/{serial}   (ApplePass auth)
  200 → application/vnd.apple.pkpass  (re-signed, after push)
```

KV `wallet` block (top-level in the QR's KV value):
```json
{ "wallet": { "enabled": true,
  "pass_id": "uuid",
  "platforms": ["apple"],
  "install_url": "https://api.qravio.app/api/v1/wallet/apple/<pass_id>?t=<hmac>" } }
```

QR create/update `wallet` authoring block (inside the coupon/event/loyalty payload):
```json
{ "wallet": { "enabled": true, "background_color": "#4648d4",
  "header_fields": [{"key":"stamps","label":"Stamps","value":"3 / 10"}],
  "expiry": "2026-12-31", "locations": [{"lat":12.97,"lng":77.59,"relevantText":"1 stamp from free coffee"}] } }
```

---

## 8. Security, Privacy & Abuse

- **Key custody (highest risk):** Apple cert/key Fernet-encrypted at rest in `wallet_signing_config.apple_cert_enc`; decrypted only inside `pass_signing.py`. **Never** returned by any route, never written to KV, never sent to the Worker. The Worker only ever holds an install URL.
- **Tenant isolation:** service-role bypasses RLS, so every wallet query filters explicitly by `.eq("workspace_id", ws)`; authoring routes go through `require_can_update` + `await check_feature`. Cross-workspace `pass_id` access is impossible on authenticated routes (workspace-scoped) and on the public install route the HMAC `t` token is bound to the exact `pass_id`.
- **Public install auth:** `t` = HMAC-SHA256(`pass_id` + `wallet_passes.id`, `WALLET_INSTALL_SECRET`), constant-time compared. PassKit web-service routes use Apple's native `Authorization: ApplePass <auth_token>` (per-pass, opaque), verified against the stored `auth_token`.
- **Gate at both ends:** authored only when `check_feature(ws, "wallet_passes")` true; install route **re-checks** the same (downgrade safety; `resolve_plan` 30s cache makes it cheap). Below-Pro → clean 403, no force-revoke of installed passes (documented caveat).
- **No PII on public surfaces:** the `.pkpass`/Save payloads carry only merchant-authored fields. A strict allowlist test asserts the signed pass dict and the install response contain **no** `ip_hash`, `session_id`, `push_token`, raw `qr_scan_events` rows, lead data, or `workspace_members` info.
- **Webhook/SSRF:** PassKit web-service endpoints accept only Apple's fixed shapes; `pushToken` is stored, never dereferenced as a URL. No outbound fetch is driven by request bodies.
- **Rate limiting:** the lead-submit limiter (`internal.py` L822) counts persisted `qr_lead_submissions` rows per IP/hour — that pattern **does not transfer** here because the install route persists no countable row. So install + PassKit web-service routes need an explicit **IP-bucket limiter** — either an in-process token bucket (simplest; per-dyno, acceptable for enumeration-blunting) or a tiny `wallet_install_hits(ip_hash, window)` counter if cross-dyno accuracy is wanted. Cert-upload/test-pass routes get their own (tighter) per-workspace cap because cert parsing burns CPU. Unknown/disabled `pass_id` → **uniform 404 with constant-time response** so the limiter + timing don't leak which `pass_id`s exist.
- **Consent gate:** not engaged — passes inject no marketing pixels/cookies.

---

## 9. Performance, Scale & Cost

- **Signing cost:** PKCS#7 over a small manifest is sub-50ms backend CPU; the install route is on-demand and cache-friendly per `(pass_id, content-hash)` (short in-process cache). Not on any hot loop.
- **Scan hot path unchanged:** the only edge addition is rendering one button from a KV field already present — zero new edge fetches, no latency regression (Phase-1 acceptance gate).
- **Push fan-out:** an edit bumps `update_tag` and pushes to the N registrations where `last_pushed_tag < update_tag` via APNs; runs in `BackgroundTasks` off the request. Bounded concurrency; idempotent (tag-gated) so the durable re-drive can safely re-run. APNs is cheap (token auth, no per-message fee). A large holder base (10k+ devices) should chunk the fan-out so one edit doesn't monopolise a worker; the re-drive naturally resumes a partial fan-out.
- **Storage:** `pass_registrations` grows with installs (one row per device per pass); indexed on `pass_id`/`serial`. `wallet_passes` is one row per wallet-enabled QR.
- **KV:** `wallet` block is ~120 bytes — negligible vs the 25MB KV value ceiling.

---

## 10. Testing Strategy

- **pytest (backend):** sign a sample `.pkpass` and assert it unzips with valid `manifest.json`/`signature`; register/unregister idempotency on `pass_registrations` UNIQUE; **push idempotency** (re-firing `enqueue_push` for the same `update_tag` is a no-op; `passesUpdatedSince` returns a serial only when `update_tag` advanced; the re-drive re-pushes exactly the `last_pushed_tag < update_tag` set); install route returns `application/vnd.apple.pkpass` for a valid token and `403`/`404` for lost-gate/deleted; **install-route rate-limit + uniform-404-timing** for unknown `pass_id`; **PII allowlist test** over the signed dict + install response (no `ip_hash`/`session_id`/`push_token`/lead/member); gate test that Free/Starter author + install are refused; loyalty type round-trips through `_build_content_from_db_rows`. `test_feature_gate_coverage` **stays green** (flag seeded everywhere by 0023, registered in `FEATURE_ENFORCEMENT`).
- **Worker (vitest):** loyalty page renders for both templates; Add-to-Wallet button appears iff `kvValue.wallet.enabled`; platform detection (iOS/Android/desktop); `escapeHTML` on user fields; no signing/secret ever present in worker output.
- **Frontend (Vitest/Playwright):** `WalletPassesSection` gated render; cert-upload form validation; authoring toggle threads `wallet` into the payload; loyalty preview mirrors the worker template. Note the **~29 pre-existing FE test failures are a documented baseline** — new tests must not add to it; treat only net-new failures as regressions.
- **Manual acceptance (Phase 1):** Pro workspace uploads cert → authors loyalty pass → scan → tap installs a valid `.pkpass` on a real iPhone → edit pass → APNs push refreshes the holder's pass.

---

## 11. Observability & Rollout

**Deploy order (Phase 1):**
1. **Apply migration 0023** in Supabase SQL editor (user-applied; verify the sanity SELECT shows `wallet_passes=true` for Pro/Agency, `false` for Free/Starter, and `loyalty` in their `dynamic_qr_types`).
2. **Backend** deploy (Render) with new secrets: `WALLET_ENC_KEY`, `WALLET_INSTALL_SECRET`, `APNS_AUTH_KEY`/`APNS_KEY_ID`/`APNS_TEAM_ID`. Ships `wallet.py`, `pass_signing.py`, KV `wallet` block, loyalty type, and the `FEATURE_ENFORCEMENT` flip `inert→enforced` (same PR).
3. **Worker** deploy: dev (`sparkling-waterfall-3a9f`) → verify scan + button render → prod (`qr-worker-prod`). No crons in v1 (so no prod-deploy cron gate yet).
4. **Frontend** deploy (Vercel): Settings section + authoring panel + loyalty type.

**Observability:** structured logs on signing success/failure (target ≥99% success), APNs delivery (target ≥95%), install-route error rate (<0.1%), and a zero-key-exposure invariant (no cert/key in any log line — asserted by a log-scrub test). Install conversion is computed backend-side from install-route hits deduped per `session_id` vs scans of the pass-enabled QR.

**Phases:** Phase 0 = migration + inert flag (this slot). Phase 1 = Apple (flag flipped, dogfood 3–5 retail/event accounts). Phase 2 = Google (additive migration for issuer/object columns — **not** in 0023). Phase 3 = geofence relevance + bulk-push passes dashboard (a batch-sweep cron, if added, counts only after prod worker deploy). **GA gates:** signing ≥99%, APNs ≥95%, PII allowlist test green, `test_feature_gate_coverage` green, zero key-exposure incidents.

**DMARC:** no email in v1, so no DMARC blocker now — but any future install-email phase makes publishing `_dmarc.qravio.app` a GA prerequisite.

---

## 12. Open Technical Questions & Risks

1. **APNs transport** — token-based auth key (recommended) vs managed provider. Recommend token auth held as a backend secret; confirm with eng.
2. **Google issuer scope (Phase 2)** — one Qravio issuer + per-workspace class IDs (recommended, simpler onboarding) vs per-workspace issuer.
3. **Cert encryption** — Fernet via `WALLET_ENC_KEY` (v1) vs cloud KMS (future hardening). Must never be plaintext.
4. **Push need a cron?** No — event-driven on QR edit. Any future batch/geofence sweep registers a `scheduled()` cron **only after `npm run deploy:prod`**.
5. **Downgrade semantics** — v1 does not force-revoke installed passes (documented caveat); install + new authoring are gate-blocked. Revisit if a "kill installed passes on downgrade" requirement emerges.

### Appendix — Key Files

| Concern | File |
|---|---|
| Migration (tables + flag flip + loyalty allowlist) | `qr_backend/migrations/0023_wallet_passes.sql` (new) |
| Pass CRUD + install + PassKit web-service + APNs push | `qr_backend/src/api/routes/wallet.py` (new) |
| `.pkpass` PKCS#7 signing | `qr_backend/src/utilities/pass_signing.py` (new) |
| Router registration | `qr_backend/src/api/endpoints.py` |
| Public route exclusion | `qr_backend/src/main.py` (`excluded_routes`) |
| Gating + `FEATURE_ENFORCEMENT` flip | `qr_backend/src/api/routes/subscription.py` |
| KV `wallet` block + loyalty content | `qr_backend/src/utilities/cloudflare_kv.py` |
| Loyalty type wiring (Literal, model, SELECT join) | `qr_backend/src/api/routes/qr.py` |
| Scan-page Add-to-Wallet + loyalty page | `qr_cf_code/src/pages/{coupon,event,loyalty}/`, `walletButton.js`, `handlers/qrRouter.js` |
| Settings cert upload + authoring + previews | `qr_frontend/.../settings/WalletPassesSection.tsx`, `content-types/LoyaltyContent.tsx`, `WalletPassFieldsPanel.tsx`, `templates/loyalty/` |
| FE gating | `qr_frontend/src/lib/plan-features.ts`, `qr_frontend/src/hooks/useSubscription.ts`, `useWalletConfig.ts` (new) |
