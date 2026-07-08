# PRD — API Access (Public REST API + Keys + Metering)

**Status:** Draft · **Author:** Engineering · **Date:** 2026-06-14
**Priority:** 1 of the coming-soon features (build first)
**Tiers:** Pro (3,000 calls/mo) · Agency (25,000 calls/mo) · Free/Starter — none
**Plan flags:** `api_access` (bool), `api_calls_per_month` (int) — seeded `false`/`0` on every tier by migration 0009; this feature's migration flips Pro/Agency on.
**Split from:** `PLAN_LIMITS_ENFORCEMENT_PRD.md` (the "sold but unbuilt" set).

---

## 1. Background

The pricing page sells API access at Pro/Agency with explicit call quotas, but nothing is built: `qr_frontend/src/app/org/[slug]/(dash)/developers/page.tsx` is `notFound()`, there is no public API surface, no key issuance, and no metering. The plan flags exist but are classified `inert` in `FEATURE_ENFORCEMENT` (subscription.py). **A flag gating a feature that doesn't exist is meaningless** — we either build it or keep it "coming soon." This PRD builds it.

## 2. Goals & Non-Goals

**Goals**
1. Issue/manage **API keys** per workspace (create, list, revoke; secret shown once).
2. A versioned **public REST API** for the core QR operations (list/create/update/delete dynamic QRs, read analytics summary).
3. **Per-key authentication** independent of the Supabase JWT path.
4. **Monthly call metering + hard quota enforcement** (3k/25k) with a clean `429` over limit.
5. Gate everything behind `api_access` (BE `check_feature` + FE `canAccessFeature`); flip the registry `inert→enforced` in the same PR.

**Non-Goals**
- GraphQL, webhooks-out, or OAuth app authorization (future).
- Per-key granular scopes beyond a coarse read/write split (Phase 3).
- Public API for static QRs or billing/workspace admin (keep the surface small).

## 3. Design

### 3.1 Authentication (reuses the `/internal/*` exclusion pattern)
The existing `BearerTokenAuthMiddleware` validates **Supabase** JWTs on every non-excluded route (`auth_bearer.py`). The public API must NOT go through that path. Mirror how `/internal/*` is handled:
- Mount a public router at **`/api/public/v1/*`** and add that prefix to the middleware's `excluded_routes` (in `main.py`).
- Apply `api_key_auth` as a **router-level** dependency (`APIRouter(dependencies=[Depends(api_key_auth)])`, the same way `internal_router` attaches `verify_internal_secret`) so no public route can ever forget it. It:
  1. Reads the key from `Authorization: Bearer qr_live_…` (or `X-API-Key`).
  2. Splits prefix + secret, looks up the active row by `key_prefix`, constant-time compares `sha256(secret)` to `key_hash`, checks `revoked_at IS NULL`.
  3. Resolves `workspace_id`, sets it on `request.state`. Updates `last_used_at` **best-effort and throttled** (only when stale by >1 min) so it isn't a DB write on every call.
  4. Calls `check_feature(workspace_id, "api_access")` → 403 if the plan lost it (downgrade-safe).
  5. Meters the call + enforces quota (§3.3) → 429 if over.

### 3.2 Key format & storage
- Key shown once at creation: `qr_live_<22-char base62>` (and `qr_test_` if we ever expose test mode). Prefix `qr_live_<first 8>` stored for display.
- **Store only a fast hash — `sha256(secret)`** (optionally HMAC-SHA256 with a server-side pepper). **NOT** bcrypt/argon2: API keys are high-entropy and verified on *every* request, so slow password hashing only adds per-request latency / CPU-burst DoS risk with zero security gain (Stripe/GitHub pattern — slow hashing is for low-entropy passwords). Never store the raw secret; lost keys are rotated, not recovered. Lookup by `key_prefix` (indexed), then constant-time hash compare. *(Eng-review D2.)*

### 3.3 Metering & quota
- Monthly counter, windowed exactly like scans: reuse `resolve_plan` + `period_start_iso` (subscription.py) so the period matches billing anchor / calendar month.
- `quota = get_limit(workspace_id, "api_calls_per_month")`; `-1` = unlimited; over → `429` with `Retry-After` + headers `X-RateLimit-Limit/Remaining/Reset`.
- Increment via an **atomic** `UPDATE api_usage SET call_count = call_count + 1` (or an RPC/upsert) — never a read-modify-write, which loses concurrent increments. The quota *read* fails closed (can't read usage → deny, mirroring the limits engine). Accept a small TOCTOU at the boundary (two calls at 2,999 may both pass) — fine for a soft monthly quota.

### 3.4 Surface (small, mirrors existing internal logic)
`/api/public/v1`: `GET /qrcodes`, `POST /qrcodes` (dynamic only), `GET/PATCH/DELETE /qrcodes/{id}`, `GET /qrcodes/{id}/analytics`. Reuse the service logic in `qr.py`/`scan.py` (extract shared functions; don't duplicate the KV-sync + gating). All scoped to the key's workspace; the existing `max_qr`/`dynamic_qr_types` gates still apply on create.

## 4. Data Model (migration)

```sql
CREATE TABLE api_keys (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  workspace_id uuid NOT NULL REFERENCES workspaces(id) ON DELETE CASCADE,
  name text NOT NULL,
  key_prefix text NOT NULL,          -- display only, e.g. qr_live_a1b2c3d4
  key_hash text NOT NULL,            -- argon2/bcrypt of the secret
  created_by uuid,
  last_used_at timestamptz,
  revoked_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX idx_api_keys_prefix ON api_keys(key_prefix) WHERE revoked_at IS NULL;

CREATE TABLE api_usage (
  workspace_id uuid NOT NULL REFERENCES workspaces(id) ON DELETE CASCADE,
  period_start date NOT NULL,        -- windowed via period_start_iso
  call_count integer NOT NULL DEFAULT 0,
  PRIMARY KEY (workspace_id, period_start)
);
```
Plus the flag-flip migration: `UPDATE plans SET features = jsonb_set(features,'{api_access}','true') , features = jsonb_set(features,'{api_calls_per_month}','3000') WHERE name='pro'` (and `25000` for agency). (Authored as one migration with the table DDL.)

## 5. Phases

- **Phase 1 (MVP):** migration (tables + flag flip) · key issuance/revoke + hashing · `api_key_auth` dependency + middleware exclusion · metering/quota · `GET/POST /qrcodes` only · `check_feature` gate + registry `inert→enforced`. **Acceptance:** a Pro key lists/creates QRs; the 3,001st call in a period → 429; a Free workspace can't create a key.
- **Phase 2:** full CRUD + `/analytics` · developers UI rebuild (key table, usage-vs-quota meter, copy-once secret, revoke) gated on `canAccessFeature('api_access')` · OpenAPI docs page.
- **Phase 3:** coarse read/write scopes · per-key rate limiting (burst) · key rotation UX.

## 6. Testing
- Auth: valid key passes; revoked/invalid → 401; key from a downgraded (api_access=false) workspace → 403.
- Quota: allow below, 429 at cap, unlimited(-1) never blocks; period rollover resets.
- Gating: registry coverage test stays green (flag flipped `enforced`); FE hides the page for non-Pro.
- The create path still honors `max_qr` + `dynamic_qr_types`.

## 7. Open Questions
1. Test-mode keys (`qr_test_`) now or later? (Recommend later.)
2. Surface scope — include folders/bulk in v1 or QR + analytics only? (Recommend the latter.)
3. Rate limiting beyond the monthly quota (per-second burst) — Phase 3 or launch?

## 8. Appendix — Key Files
| Concern | File |
|---|---|
| Auth middleware + exclusions | `qr_backend/src/api/middlewares/auth_bearer.py`, `src/main.py` |
| Gating engine / metering helpers | `qr_backend/src/api/routes/subscription.py` (`check_feature`/`get_limit`/`resolve_plan`/`period_start_iso`, `FEATURE_ENFORCEMENT`) |
| Key hashing | `hashlib.sha256` (fast — NOT `qr_password.py` slow hashing; see §3.2) |
| Reuse QR/analytics logic | `qr_backend/src/api/routes/qr.py`, `scan.py` — public create path MUST reuse the existing `max_qr`/`dynamic_qr_types`/KV-sync enforcement, not reimplement it (DRY) |
| Router registration | `qr_backend/src/api/endpoints.py` |
| Key-management UI | `qr_frontend/src/app/org/[slug]/(dash)/developers/page.tsx` (currently `notFound()`) |

---

# Eng Review (2026-06-14) — across all 5 coming-soon PRDs

`/plan-eng-review` covered API_ACCESS, LEAD_CAPTURE_FORMS, RETARGETING_PIXELS, WHITE_LABEL_SETTINGS, SSO_SAML. Where this section differs from the bodies above, **this wins** (decisions already applied to the PRDs).

## Decisions (locked + applied)
| # | Decision |
|---|---|
| **D1** | **Consent once + reorder.** GDPR/consent gates Lead Capture (PII) + Retargeting (cookies) + Mixpanel. Resolve it ONE time (shared consent/cookie gate) before either; build order = **API Access → White-label → Lead Capture → Retargeting** (consent-bound features last; White-label is consent-free + smallest). |
| **D2** | **API keys hashed with SHA-256** (optionally HMAC+pepper), looked up by prefix, constant-time compared — NOT bcrypt/argon2. High-entropy keys verified per-request; slow password hashing = per-request latency + CPU-burst DoS for no gain. *(EUREKA: "always bcrypt" is wrong for high-entropy secrets.)* |
| **D3** | **Retargeting pixel ids validated at write against a strict per-provider regex; worker injects only from fixed per-provider templates.** Never interpolate free-form text into `<script>` (escaping a script body ≠ safe). Closes a stored-XSS class on customer pages. |
| **D4** | **Lead-form honeypot + per-IP/per-QR rate-limit ships in Phase 1**, not Phase 3. A public unauthenticated form floods with spam immediately. Captcha/Turnstile stays Phase 3. |

## Folded fixes (applied without a separate decision)
- **API auth is a router-level dependency** (`APIRouter(dependencies=[...])` like `internal_router`), so no public route can forget it.
- **API usage increments atomically** (`call_count = call_count + 1`), never read-modify-write; quota read fails closed; small TOCTOU accepted for a soft quota.
- **`last_used_at` write throttled** (>1 min stale) to avoid a DB write per call.
- **Public API create path reuses `qr.py` enforcement** (max_qr / dynamic_qr_types / KV-sync) — no reimplementation (DRY).
- **White-label `brand_color` validated as hex + footer sanitized** at write (CSS/HTML-injection guard); logo upload reuses `validate_file` + 50MB cap.

## Tests to add (per feature — the PRD test sections were thin)
- **API:** per-tier allow/deny; quota allow-below / **429 at cap** / unlimited(-1); revoked/invalid key → 401; downgraded (api_access=false) key → 403; period rollover resets; create still honors max_qr + dynamic_qr_types.
- **Lead:** field validation (required/missing → 400); honeypot/rate-limit blocks a flood; submission scoped to workspace; gate denies non-Pro; React/worker template parity.
- **Retargeting:** **malformed/malicious pixel_id rejected at write** (XSS test); injection only from fixed templates; redirect-only types never inject; gate denies non-Pro.
- **White-label:** branding renders only when entitled; **clears at the edge on downgrade** (entitlement snapshot); non-Agency denied; save re-syncs KV.
- **All:** keep `test_feature_gate_coverage` green — flip each flag `inert→enforced` in the same PR.

## What already exists (reuse, don't rebuild)
Gating engine + coverage test · worker "add a QR type" path + `build_kv_content`/`build_entitlements`/`sync_qr_to_kv` · `pw-verify` proxy pattern (Lead submit) · storage upload + `validate_file` + 50MB cap · white-label brand **suppression** (already shipped — White-label PRD is additive only).

## NOT in scope (deferred)
GraphQL / webhooks-out / OAuth apps (API) · CRM/Zapier + file-upload fields (Lead) · Meta CAPI server-side conversions (Retargeting) · custom CSS/email-template branding (White-label) · **self-serve SSO** (SSO_SAML = contact-sales only, `sso` stays inert) · the shared consent-management system itself (own decision/PRD — D1, prerequisite to Lead + Retargeting).

## Failure modes (critical gaps flagged)
| Codepath | Failure | Test? | Handling | User sees |
|---|---|---|---|---|
| Retargeting injection | malicious pixel_id → stored XSS | ✅ D3 write-validation test | ✅ regex + fixed template | (closed) |
| API key verify | slow-hash CPU burst under load | ✅ load/latency check | ✅ D2 SHA-256 | fast responses |
| API usage increment | concurrent lost updates → over-serve | ✅ concurrency test | ✅ atomic increment | minor TOCTOU only |
| Lead submit | spam flood | ✅ rate-limit test | ✅ D4 honeypot+RL | clean inbox |
| Lead/Retargeting in EU | ship without consent gate | ⚠️ gated by D1 | ✅ build last, behind consent | legally compliant |

## Parallelization
- **Lane A (backend core, sequential):** API Access (own tables/routes) → then per-feature backend.
- **Lane B (worker):** Lead form page / Retargeting injector / White-label brand render — parallel to backend once KV contracts are fixed.
- **Lane C (frontend):** developers UI / settings UIs — after each feature's API contract lands.
- **Cross-cutting (blocks Lane A+B for Lead & Retargeting):** the D1 consent gate must land first.

## Implementation Tasks
- [ ] **T1 (P1)** — API Access: SHA-256 key hashing + router-level `api_key_auth` + atomic metering. Files: `api_keys`/`api_usage` migration, public router, `main.py` exclusion. Verify: 429-at-cap + 401/403 tests.
- [ ] **T2 (P1)** — Shared **consent/cookie gate** decision + implementation (prereq for Lead + Retargeting; shared with Mixpanel). Verify: EU traffic shows consent before any PII/pixel.
- [ ] **T3 (P1)** — Retargeting: per-provider `pixel_id` validation + fixed-template injector. Files: `retargeting_pixels` migration, `src/utils/pixels.js`. Verify: XSS-rejection test.
- [ ] **T4 (P1)** — Lead Capture: honeypot + rate-limit in the submit endpoint. Files: `/internal/lead-submit`. Verify: flood is throttled.
- [ ] **T5 (P2)** — White-label: hex/footer validation before KV. Files: `workspace_branding` migration, `build_entitlements`. Verify: bad color rejected.
- [ ] **T6 (P2)** — SSO: relabel pricing row "Coming soon" → "Contact sales"; confirm custom-plan (`is_custom`+`sso=true`) path. Files: `PricingComparisonTable.tsx`, `PricingCards.tsx`.

## GSTACK REVIEW REPORT

| Review | Trigger | Why | Runs | Status | Findings |
|--------|---------|-----|------|--------|----------|
| CEO Review | `/plan-ceo-review` | Scope & strategy | 0 | — | not run |
| Codex Review | `/codex review` | Independent 2nd opinion | 0 | — | not run (outside voice skipped) |
| Eng Review | `/plan-eng-review` | Architecture & tests (required) | 1 | ISSUES_RESOLVED | 4 decisions (consent/sequencing, key-hashing, pixel-XSS, lead-spam) + 5 folded fixes + per-feature test suites; all applied to the PRDs; 0 unresolved |
| Design Review | `/plan-design-review` | UI/UX gaps | 0 | — | not run (backend/security-heavy) |
| DX Review | `/plan-devex-review` | Developer experience gaps | 0 | — | not run |

- **UNRESOLVED:** none — D1–D4 all decided and written into the PRDs.
- **VERDICT:** ENG CLEARED — the 5 PRDs are ready to implement in the locked order (API Access → White-label → [consent gate] → Lead Capture → Retargeting; SSO = contact-sales, no build). The consent gate (T2) is the prerequisite that unblocks the two data-collection features.
