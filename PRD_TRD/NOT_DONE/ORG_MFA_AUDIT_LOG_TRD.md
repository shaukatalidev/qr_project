# TRD — Org-Enforced MFA + Admin Audit Log

**Status:** Draft · **Author:** Engineering (Staff) · **Date:** 2026-07-25
**Priority:** Deal-gated enabler (competitive analysis item #11, Fit 2 / Impact 2). Two small, independent mechanisms sharing one migration. The engineering risk is **not** the feature surface — it is (a) enforcement *coverage* across the ~15 endpoints that bypass the shared workspace-auth dependency, and (b) not locking anyone out.
**Tiers:** **Agency + custom (enterprise/white-label).** The audit **write** path is ungated and always on; only the **read/export** surfaces and the MFA policy switch are gated.
**Plan flags (NEW):** `mfa_enforcement` (bool) · `audit_log` (bool) · `audit_log_retention_days` (int — read-window clamp, mirrors `analytics_retention_days`). All three seeded as a **full-object `'{...}'::jsonb` blob** and registered `inert`→`enforced` in the **same PR** (house convention; `test_feature_gate_coverage` stays green).
**Migration slot:** **`0040`** (`0040_org_mfa_audit_log.sql`) — **provisional**. Verified against disk: highest existing = `0032_lemonsqueezy_variant_backfill.sql`; `0033` is claimed by `QR_EXPIRY_SCHEDULING_TRD.md` and `0034`–`0039` by the sibling specs currently in flight (UPI / location / phone / WhatsApp reminders / GA4 relabel / email-signature embed / GST invoice). **Re-verify against `qr_backend/migrations/` at build time** — the repo has a commit history of fixing stale slot numbers, and this one is a forward reservation, not an observation.
**Services touched:** `qr_backend` (migration, AAL propagation, one enforcement dependency, one audit utility, one new read router, gating registry) · `qr_frontend` (re-enable the existing 2FA panel, org-security panel, MFA interstitial + step-up, audit-log page). **`qr_cf_code` — no change whatsoever** (no KV key, no QR type, no template, no `handlers/` case, no `recordScan` field, no `scheduled()` cron ⇒ **`npm run deploy:prod` is NOT a gate**). No AI, no email, no new external service, no new env var.
**Implements PRD:** Org-Enforced MFA + Admin Audit Log. **Mirrors** `_log_login_event` (`auth.py:29`) for the best-effort write helper, `export_leads_csv` (`lead_forms.py:135`) for the CSV export, and the `0026`/`card_ocr` blob-seed convention for the plan flags. **Explicitly excludes SCIM** — see `PRD_TRD/NOT_DONE/SSO_SAML_PRD.md` (SSO/SAML is a recorded "do not build"; `FEATURE_ENFORCEMENT['sso']` stays `inert`), and SCIM without SSO is provisioning for an IdP we don't integrate with.

**Rev (2026-07-25, post eng-review):** Reviewed via `/plan-eng-review`; ships as-drafted. **Decision: build the full feature now** (Phase 0 + org-enforced MFA + audit log together), overriding the PRD's "wait for a named deal" framing — see the PRD Rev for the accepted trade-off. **Hard gate:** re-expose `TwoFactorPanel` (`SecuritySection.tsx:18`) and restore the 404'd security route **first**, and verify enroll→verify→status→unenroll end-to-end — no user can enroll a factor today, so shipping the policy against that state locks out every member. Load-bearing invariants: the policy check rides the **existing** `get_workspace_role()` query as an embedded column (zero extra round-trips) and reads the Supabase JWT `aal` claim already decoded at `auth_bearer.py:99`; the refusal is **`403 mfa_required`, never `401`** (a 401 trips the client's token-refresh/sign-out path into a redirect loop); enabling requires the owner's own session at AAL2, enforced server-side with a **409** (the disabled-switch UI is a hint, not the control), and disabling is always reachable; the audit table is **append-only enforced at the DB** (UPDATE/DELETE revoked *and* trigger-blocked) — verify the trigger does **not** fire on cascaded deletes from `workspaces`/`users`, the exact defect found in the loyalty spec, or workspace deletion will raise; **write ungated / read gated**; `audit_log_retention_days` clamps the **read window** only (never a purge job); bulk QR create writes **one summary row**, not N; API-key traffic on `/api/public/v1` carries no assurance level and is out of the policy's reach — say so in-product; and `record_audit()` must be **best-effort** (mirroring `_log_login_event`) so an audit-write failure can never fail the user's actual mutation. All three flags seed as a full-object `'{...}'::jsonb` blob, `inert`→`enforced` in the same PR, keeping `test_feature_gate_coverage` green.

---

## 1. Overview & Architecture

Two orthogonal mechanisms, one migration, zero edge impact.

**(a) Org-enforced MFA** is a **policy column read on the workspace-auth seam**. Supabase already stamps an **assurance level** into every access token's `aal` claim (`aal1` = password only, `aal2` = a second factor cleared *in this session*). The Bearer middleware already decodes that token locally (`auth_bearer.py:99` `_local_claims`) — it just discards the claim. We stash it on `request.state.auth_aal`, and `get_workspace_role()` (`deps.py:33`) — the single dependency through which every workspace-scoped route resolves membership — refuses `aal1` sessions with `403 mfa_required` when the workspace's `require_mfa` is on. The policy value **rides the membership query as an embedded resource**, so enforcement costs **zero extra database round-trips**.

Enforcement deliberately does **not** live in the middleware: the middleware runs before routing and does not know which workspace a request targets (`workspace_id` arrives as a path param on most routes and a query param on others). `get_workspace_role` is the correct — and only — seam that already has both the user and the workspace in hand.

**(b) The admin audit log** is a **new append-only table plus a best-effort write helper** called from a curated list of mutation sites. Immutability is enforced *by the database* (privileges revoked **and** a mutation-blocking trigger), not by convention. Reads are a single gated router with cursor pagination and a CSV export that mirrors the leads export byte-for-byte in shape.

**Services touched**

| Service | Change |
|---|---|
| `qr_backend` | Migration `0040` (3 columns on `workspaces`, `audit_log` table + immutability, 3 plan-flag keys). `auth_bearer.py`: propagate `aal` on **both** auth paths. NEW `src/api/dependencies/mfa.py` (`enforce_org_mfa`). `deps.py`: embed `require_mfa` in the membership query + call the helper on both return branches. `workspace.py`: `GET`/`PATCH /{id}/security-policy` + audit instrumentation. NEW `src/utilities/audit.py` (`record_audit`). NEW `src/api/routes/audit.py` (list + `export.csv`). `subscription.py`: 3 registry entries + 1 `_QUOTA_SPEC` entry. Explicit `enforce_org_mfa` calls at the ~15 inline-membership sites. |
| `qr_frontend` | Uncomment `TwoFactorPanel` in `SecuritySection.tsx:18` (**prerequisite — no enrollment path exists today**). NEW `org-security-section.tsx` + a settings-nav entry. `api-client.ts`: pass `403 mfa_required` to a step-up handler + auto-retry. NEW `mfa-step-up-dialog.tsx` (reuses `TwoFactorModal` for enrollment). NEW `audit-log` route + `useAuditLog` hook. 3 keys in `PlanFeatures`. |
| `qr_cf_code` | **No change.** The scan hot path is byte-for-byte identical. The worker↔React template-mirroring rule does not apply (nothing to mirror). No prod-worker-deploy gate. |

**Data flow — MFA enforcement (every authenticated workspace request)**

```
Authorization: Bearer <supabase access token>
  → BearerTokenAuthMiddleware.dispatch (auth_bearer.py:131)
      fast path   : _local_claims(token) → request.state.auth_aal = claims["aal"]        (L154-170)
      fallback    : get_user(token) verifies → then read `aal` from the SAME token via
                    jwt.get_unverified_claims(token)  (authenticity already established)  (L171-189)
  → route → Depends(require_can_*) → Depends(get_workspace_role)   (deps.py:33)
      SELECT role, workspaces(require_mfa) FROM workspace_members …  ← one query, as today
      → enforce_org_mfa(workspace_id, request, require_mfa)
          require_mfa false  → return (no-op, the overwhelming majority)
          aal == "aal2"      → return
          otherwise          → 403 {"code":"mfa_required", …}
  → handler
```

**Data flow — audit write (admin mutation)**

```
PATCH /workspaces/{id}/members/{uid}  role: viewer → owner
  → require_workspace_role(["owner"]) → (MFA enforced here, via get_workspace_role)
  → read the CURRENT role (needed for the before-image)      ← the one added SELECT
  → db.table("workspace_members").update({"role": …})         (workspace.py:651)
  → record_audit(db, request, workspace_id=…, actor_user_id=…,
                 action="member.role_changed", target_type="member",
                 target_id=<uid>, target_label=<email>,
                 changes={"before":{"role":"viewer"},"after":{"role":"owner"}})
       → INSERT INTO audit_log …   (never raises; on failure logs ERROR and returns)
  → 200
```

**Data flow — audit read**

```
GET /workspaces/{id}/audit-log?action=member.*&from=…&cursor=…
  → require_workspace_role(["owner"]) (+ MFA policy) → await check_feature(ws,"audit_log")  [403 if false]
  → window = now - get_limit(ws,"audit_log_retention_days")    (-1 ⇒ unbounded)
  → keyset page over (created_at DESC, id DESC), clamped to `window`
  → {items, next_cursor, retention_days}
GET …/audit-log/export.csv → same query, no page cap (bounded by the retention window)
                           → csv.DictWriter → StreamingResponse("text/csv")
```

---

## 2. Data Model & Migrations

Three nullable-safe columns on the existing `workspaces` table, one new `audit_log` table, and the three plan-flag keys. **No change** to `qr_codes`, `qr_scan_events`, `login_events`, `workspace_members`, or any per-type detail table.

**RLS note:** the backend uses the Supabase **service-role** REST client, which **bypasses RLS**. Following the house convention (`card_ocr_usage`, `0026`), `audit_log` gets `ENABLE ROW LEVEL SECURITY` with **no policies**, so `anon`/`authenticated` can never read it even if a future client is pointed at it; tenant isolation is enforced in code by explicit `workspace_id` filters. **Immutability is a separate control** and does **not** rely on RLS (which the service role bypasses): it is `REVOKE UPDATE, DELETE, TRUNCATE` **plus** row- and statement-level blocking triggers, so even the service role — the identity the application actually runs as — physically cannot alter or remove a row.

**No foreign keys on `audit_log`, deliberately.** An `ON DELETE CASCADE` from `workspaces` or `auth.users` would (a) collide with the DELETE-blocking trigger and make workspace deletion fail outright, and (b) erase precisely the trail an auditor wants at the moment a workspace or member is removed. `workspace_id` and `actor_user_id` are therefore plain `uuid` columns with denormalized `actor_email` / `target_label` snapshots. **This must be coordinated with the pending account-deletion-cascade fix** (gap analysis, "Recommended sequence" item 1) so that work does not add a cascade here.

**`qr_backend/migrations/0040_org_mfa_audit_log.sql`** — BEGIN/COMMIT-wrapped, idempotent (`IF NOT EXISTS` / `OR REPLACE`), applied by hand in the Supabase SQL editor.

```sql
BEGIN;

-- ══ 1. Org MFA policy — three columns on the existing workspaces table ══
-- require_mfa: when true, every workspace-scoped API call from a session that has
-- not cleared a second factor (JWT aal != 'aal2') is refused 403 mfa_required.
-- Enforced in src/api/dependencies/deps.py::get_workspace_role — NOT at the edge,
-- NOT in the Bearer middleware (which has no workspace context).
ALTER TABLE workspaces ADD COLUMN IF NOT EXISTS require_mfa            boolean NOT NULL DEFAULT false;
ALTER TABLE workspaces ADD COLUMN IF NOT EXISTS require_mfa_enabled_at timestamptz;
ALTER TABLE workspaces ADD COLUMN IF NOT EXISTS require_mfa_enabled_by uuid;   -- no FK: survives user deletion

-- ══ 2. Admin audit log — append-only ══
-- NO foreign keys, by design: the trail must outlive both the member and the
-- workspace, and a cascade would collide with the append-only triggers below.
-- Human-readable snapshots (actor_email, target_label) are denormalized at write
-- time so a row stays legible after the referenced rows are gone.
CREATE TABLE IF NOT EXISTS audit_log (
    id            bigserial   PRIMARY KEY,
    workspace_id  uuid        NOT NULL,
    actor_user_id uuid,                                   -- NULL = system/internal actor
    actor_email   text,                                   -- snapshot at write time
    actor_role    text,                                   -- role held when the action was taken
    action        text        NOT NULL,                   -- 'member.role_changed', 'qr.updated', …
    target_type   text,                                   -- 'member'|'qr'|'workspace'|'api_token'|'domain'|'invitation'
    target_id     text,
    target_label  text,                                   -- snapshot: email / QR name / domain
    changes       jsonb       NOT NULL DEFAULT '{}'::jsonb,-- {"before":{…},"after":{…}} — NEVER secrets
    ip_address    text,                                   -- text, not inet: x-forwarded-for can be junk
    user_agent    text,
    created_at    timestamptz NOT NULL DEFAULT now()
);

-- Listing index: serves the default (workspace, newest-first) page, the date-range
-- filter, AND the keyset cursor — one index, three jobs. (created_at, id) is the
-- cursor tuple; id breaks ties for same-instant rows.
CREATE INDEX IF NOT EXISTS idx_audit_log_ws_created
    ON audit_log (workspace_id, created_at DESC, id DESC);
-- Filter indexes: "what did Priya do" / "show me every role change".
CREATE INDEX IF NOT EXISTS idx_audit_log_ws_actor_created
    ON audit_log (workspace_id, actor_user_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_audit_log_ws_action_created
    ON audit_log (workspace_id, action, created_at DESC);

ALTER TABLE audit_log ENABLE ROW LEVEL SECURITY;
-- No policies → anon/authenticated can never read. The service role bypasses RLS,
-- which is why immutability is enforced by privileges + triggers, not by RLS.

-- ── Append-only enforcement (the property that makes the log worth reading) ──
CREATE OR REPLACE FUNCTION audit_log_block_mutation() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    RAISE EXCEPTION 'audit_log is append-only; % is not permitted', TG_OP
        USING ERRCODE = 'insufficient_privilege';
END;
$$;

DROP TRIGGER IF EXISTS trg_audit_log_append_only ON audit_log;
CREATE TRIGGER trg_audit_log_append_only
    BEFORE UPDATE OR DELETE ON audit_log
    FOR EACH ROW EXECUTE FUNCTION audit_log_block_mutation();

-- A row-level trigger does NOT fire on TRUNCATE — it needs its own statement-level one.
DROP TRIGGER IF EXISTS trg_audit_log_no_truncate ON audit_log;
CREATE TRIGGER trg_audit_log_no_truncate
    BEFORE TRUNCATE ON audit_log
    FOR EACH STATEMENT EXECUTE FUNCTION audit_log_block_mutation();

-- Belt and braces: the application identity literally lacks the privilege.
REVOKE UPDATE, DELETE, TRUNCATE ON audit_log FROM anon, authenticated, service_role;
GRANT  SELECT, INSERT              ON audit_log TO   service_role;
GRANT  USAGE, SELECT ON SEQUENCE audit_log_id_seq TO service_role;

-- ══ 3. Plan flags — seed as a FULL-OBJECT blob, then enable per tier ══
-- MUST be a '{...}'::jsonb blob, not path-only jsonb_set:
-- test_feature_gate_coverage._seed_feature_keys() discovers feature keys ONLY by
-- regex-scanning '{...}'::jsonb blobs, so a path-only seed leaves all three keys
-- undiscovered and the coverage test fails them as "stale" (the 0026/card_ocr trap).
-- `features || blob` writes only the absent keys; the NOT(... ? ...) guard keeps it
-- idempotent and non-clobbering; lower(name) + is_custom guard per house convention.
UPDATE plans
SET features = coalesce(features,'{}'::jsonb)
             || '{"mfa_enforcement":false,"audit_log":false,"audit_log_retention_days":0}'::jsonb
WHERE NOT (coalesce(features,'{}'::jsonb) ? 'audit_log')
  AND coalesce(is_custom,false) = false;

-- Agency: the only self-serve tier that gets enterprise security (PRD §8).
UPDATE plans
SET features = jsonb_set(
        jsonb_set(
            jsonb_set(coalesce(features,'{}'::jsonb), '{mfa_enforcement}', 'true'::jsonb, true),
            '{audit_log}', 'true'::jsonb, true),
        '{audit_log_retention_days}', '365'::jsonb, true)
WHERE lower(name) = 'agency' AND coalesce(is_custom,false) = false;

-- Free / Starter / Pro stay false/false/0 from the blob seed above.
-- Custom (enterprise / white-label, is_custom=true) plans are granted per deal —
-- resolve_plan/get_plan are intentionally NOT filtered by is_public, so a custom
-- plan works without pricing-page exposure (same path SSO_SAML_PRD §3.3 documents).
-- OPTIONAL Pro rung (PRD Open Q1 — recommended HELD BACK for v1):
--   UPDATE plans SET features = jsonb_set(jsonb_set(coalesce(features,'{}'::jsonb),
--       '{audit_log}','true'::jsonb,true),'{audit_log_retention_days}','30'::jsonb,true)
--     WHERE lower(name)='pro' AND coalesce(is_custom,false)=false;

COMMIT;

-- Sanity (after COMMIT):
--   SELECT name, features->'mfa_enforcement', features->'audit_log',
--          features->'audit_log_retention_days'
--     FROM plans WHERE coalesce(is_custom,false)=false ORDER BY price_monthly;
--   SELECT id, name, require_mfa FROM workspaces WHERE require_mfa;
--   -- immutability must FAIL:
--   UPDATE audit_log SET action='x' WHERE id = (SELECT min(id) FROM audit_log);
```

**Row size / growth.** ~300 bytes typical (`changes` is a small diff, never a full record). Admin mutations run orders of magnitude below scans; bulk QR creation collapses to **one summary row** (§3.5). No purge job in v1 — `audit_log_retention_days` clamps the **read window**, exactly as `analytics_retention_days` clamps analytics reads (`scan.py get_analytics_days`), so nothing is ever deleted by the product.

---

## 3. Backend Design

### 3.1 AAL propagation — `qr_backend/src/api/middlewares/auth_bearer.py`
The middleware already decodes the Supabase access token; it just drops the assurance level. Two paths, **both** must set it — a miss on either makes the whole policy silently inert.

**Fast path** (local HS256 verify, ~L154–170): add one line beside the other `request.state` assignments —
```python
request.state.auth_aal = claims.get("aal")      # "aal1" | "aal2" | None
```

**Fallback path** (`get_user()`, ~L171–189): the Supabase `UserResponse` carries **no** assurance level, so it must come from the token. `get_user()` has already established the token's authenticity server-side, so reading the claim without re-verifying the signature is sound:
```python
from jose import jwt as jose_jwt
...
try:
    request.state.auth_aal = (jose_jwt.get_unverified_claims(token) or {}).get("aal")
except JWTError:
    request.state.auth_aal = None      # unreadable ⇒ treated as aal1 (fail-CLOSED)
```
**Fail-closed is correct here** (the opposite of the QR-expiry fail-open call): if we cannot establish that a session reached AAL2, we must not treat it as if it did. The blast radius of failing closed is bounded — it only bites workspaces that **opted into** the policy, and only until the user steps up. Any project on asymmetric JWT keys takes this branch on every request, which is exactly why it cannot be skipped.

`request.state.auth_aal` is **never set** on excluded routes (`/api/public/v1`, `/internal/*`, webhooks, health) — those don't reach the middleware's verify block at all, and none of them use `get_workspace_role`, so API-key traffic is structurally unaffected (PRD R4).

### 3.2 Enforcement helper — `qr_backend/src/api/dependencies/mfa.py` (NEW)
One small module so there is exactly **one** definition of "does this session satisfy the policy":
```python
async def enforce_org_mfa(workspace_id: str, request: Request, require_mfa: bool | None) -> None:
    """Raise 403 mfa_required when the workspace requires MFA and the caller's
    session has not cleared a second factor. No-op otherwise (the common case)."""
    if not require_mfa:
        return
    if getattr(request.state, "auth_aal", None) == "aal2":
        return
    raise HTTPException(
        status_code=403,
        detail={"code": "mfa_required", "workspace_id": workspace_id},
    )
```
**403, never 401.** A `401` would trip the frontend's token-refresh/sign-out path and produce a redirect loop (PRD R2c) — verify `api-client.ts`'s response interceptor passes `403` through untouched before wiring the UI.

A second helper covers sites that don't have the policy value in hand:
```python
async def enforce_org_mfa_by_lookup(workspace_id, request, db) -> None:
    """For the inline-membership call sites (§3.4). One cached SELECT."""
```
backed by a 30-second in-process TTL cache keyed on `workspace_id`, mirroring `_PLAN_CACHE` (`subscription.py:207`) — with the documented consequence that **disabling** the policy can take up to 30s to propagate (enabling is immediate on the `get_workspace_role` path, which reads it live).

### 3.3 The enforcement seam — `qr_backend/src/api/dependencies/deps.py`
`get_workspace_role` (L33) is the one place every workspace-scoped route resolves membership. Two changes, both surgical:

1. **Embed the policy in the query already being run** (L58–65) — zero extra round-trips, using the same PostgREST embed style as `workspace.py:143`:
   ```python
   member = (db.table("workspace_members")
               .select("role, workspaces(require_mfa)")     # was: .select("role")
               .eq("workspace_id", workspace_id).eq("user_id", user_id)
               .maybe_single().execute())
   ```
   The embed returns `{"role": "...", "workspaces": {"require_mfa": bool}}`; read it defensively (`(member.data.get("workspaces") or {}).get("require_mfa")`) — a `None` embed must be treated as **policy unknown ⇒ fall back to `enforce_org_mfa_by_lookup`**, never as "policy off".
2. **Extend the owner-fallback branch** (L74) — it already selects from `workspaces`, so widen it: `.select("owner_id, require_mfa")`.

Then call `enforce_org_mfa(...)` immediately **before each of the two `return` statements** (L66–71 and L83–87), so no path returns a membership dict without having been checked. The `403 Not a member` raise at L89 is unchanged and takes precedence (a non-member is rejected before the MFA question is even relevant).

`require_workspace_role(...)` (L95) delegates to `get_workspace_role` (L112) and therefore inherits enforcement for free; so does every `require_can_read/create/update/delete` in `permissions.py`.

### 3.4 Bypass sites — the real work (PRD R1)
Hooking `get_workspace_role` covers the majority but **not** the ~15 endpoints that run their own inline `workspace_members` lookup. An "enforced" control with holes is worse than none, so each site is explicitly resolved:

| File | Lines | Disposition |
|---|---|---|
| `scan.py` | 920, 1010, 1094, 1242, 1271, 1298, 1546 | **Enforce** — add `await enforce_org_mfa_by_lookup(...)` beside the membership check (analytics reads are exactly what a policy is meant to cover) |
| `storage.py` | 174, 367, 549 | **Enforce** — file upload/list |
| `security.py` | 198, 247, 327 | **Enforce** — API-token list/create/revoke. Minting a key under a stale session is the specific hole the policy must close |
| `security.py` | 360 (`export_user_data`) | **Exempt** — user-scoped GDPR export, not a workspace action |
| `ai_analyst.py` | 76 | **Enforce** |
| `workspace.py` | 192 (`get_my_workspace_by_slug`) | **EXEMPT — load-bearing.** A blocked member must still be able to resolve the workspace shell in order to *see* the "this workspace requires 2FA" screen. Blocking it produces a blank app with no way forward |
| `workspace.py` | 142 (`list_my_workspaces`), `auth.py` 117/178, `accept_invitation` | **Naturally exempt** — not workspace-scoped by dependency. A new member must be able to accept an invitation and *then* be told to enroll |
| `/api/v1/security/*` (user-scoped: login-history, preferences, sessions, TOTP) | — | **Naturally exempt** — never reaches `get_workspace_role`. This is what makes the enrollment path reachable while blocked. **Do not "fix" this.** |

**Guardrail test (new, in the spirit of `test_feature_gate_coverage`):** grep the route modules for `table("workspace_members")` and assert every hit is either inside `deps.py`, in the explicit exemption allowlist, or accompanied by an `enforce_org_mfa` call within the same function. This is what stops the next inline lookup from silently reopening a hole.

### 3.5 Audit write helper — `qr_backend/src/utilities/audit.py` (NEW)
Mirrors `_log_login_event` (`auth.py:29`) in shape — **never raises, never blocks the mutation** — but upgrades its silent `except: pass` to a loud ERROR log, because a silently-broken audit trail is worse than an absent one.
```python
def record_audit(db, request, *, workspace_id, actor_user_id, action,
                 target_type=None, target_id=None, target_label=None,
                 changes=None, actor_email=None, actor_role=None) -> None:
    """Best-effort append to audit_log. NEVER raises: an audit failure must not
    fail the user's action. Logs at ERROR (with `action`) and increments a
    failure counter so a systematically-broken trail is visible, not silent."""
```
It derives `ip_address` from `x-forwarded-for` (first hop, same parsing as `auth.py:30-32`) and `user_agent` from the request, truncating both. `changes` carries only a **small before/after diff** — never a secret (no `token_hash`, no password, no full record dump); the token-creation row records `token_prefix` and name only.

**Instrumentation sites (v1, PRD §6.5):**

| Action | Site |
|---|---|
| `workspace.created` | `workspace.py:267/278` |
| `member.invited` | `workspace.py:367` (`invite_member`) |
| `member.joined` | `workspace.py:550/565` (`accept_invitation`) |
| `member.role_changed` *(before→after)* | `workspace.py:651` — **read the current role first** for the before-image; this is the one added `SELECT` in the whole feature |
| `member.removed` | `workspace.py:701` |
| `invitation.revoked` | `workspace.py:735` |
| `workspace.renamed` | `workspace.py:763` |
| `workspace.mfa_policy_changed` *(before→after)* | new `PATCH /security-policy` (§3.6) |
| `api_token.created` / `api_token.revoked` | `security.py:277` / `security.py:341` |
| `qr.created` / `qr.updated` / `qr.deleted` | `qr.py` create / update (~L2839 model_dump path) / delete. `qr.updated` records **only changed keys**, with `destination` before→after as the high-value case |
| `qr.bulk_created` | `qr.py` `bulk_create_qr_codes` — **one summary row** with `changes.count`, never N rows |
| `domain.added` / `domain.removed` | `custom_domain.py` |

Deferred to v1.1 (the helper takes them without a schema change): billing/plan changes (`razorpay_routes.py`, actor = system), scheduled-report runs, branding edits.

### 3.6 Security-policy endpoints — `qr_backend/src/api/routes/workspace.py`
```
GET   /api/v1/workspaces/{workspace_id}/security-policy    # owner-only
PATCH /api/v1/workspaces/{workspace_id}/security-policy    # owner-only  {"require_mfa": bool}
```
Both use `Depends(require_workspace_role(["owner"]))`. `PATCH` order of operations:
1. `await check_feature(workspace_id, "mfa_enforcement", db)` → `403 {"code":"mfa_enforcement_locked","upgrade_to":"agency"}` if false. (`check_feature` is **async** — must be awaited; it fails closed.)
2. **Anti-lockout guard (server-side, authoritative):** when enabling, require `request.state.auth_aal == "aal2"` → else `409 {"code":"mfa_enroll_self_first"}`. The UI's disabled switch is convenience; **this** is the control.
3. Write `require_mfa`, `require_mfa_enabled_at = now()`, `require_mfa_enabled_by = user_id`.
4. `record_audit(action="workspace.mfa_policy_changed", changes={"before":{...},"after":{...}})`.

`GET` returns the policy plus the **member 2FA roster** — but the backend has no view of Supabase factors from the service-role REST client, so the roster is assembled **client-side is not possible either** (a user can only list their *own* factors). **Resolution: the roster is derived from `audit_log`-independent state we do control** — we record each member's own enrollment as a `security.mfa_enrolled` / `security.mfa_unenrolled` row when the frontend's enroll/unenroll mutation succeeds (a tiny `POST /security/mfa-state` echo, user-scoped, workspace-fanned-out), and the roster reads the latest state per member. *(This is Open Q3 in §12 — the honest alternative is to drop the roster from v1 and show only an aggregate "N members blocked in the last 24h" derived from `mfa_required` 403 counts.)*

### 3.7 Audit read router — `qr_backend/src/api/routes/audit.py` (NEW)
Registered in `endpoints.py` under the standard JWT prefix.
```
GET /api/v1/workspaces/{workspace_id}/audit-log             # filter + keyset page
GET /api/v1/workspaces/{workspace_id}/audit-log/export.csv  # same query → CSV
```
Both: `Depends(require_workspace_role(["owner"]))` (PRD Open Q2 — owner-only; the log carries colleagues' IPs) **and** `await check_feature(workspace_id, "audit_log", db)` → `403 {"code":"audit_log_locked","upgrade_to":"agency"}`.

**Retention clamp:** `days = get_limit(workspace_id, db, "audit_log_retention_days")`; `-1` ⇒ unbounded; `0` ⇒ unreachable (the feature flag already gated it); otherwise `created_at >= now() - days`. The response echoes `retention_days` so the UI can state the window honestly rather than silently truncating (mirrors the `analytics_retention_days` clamp in `scan.py`).

**Keyset pagination**, not offset: `ORDER BY created_at DESC, id DESC` with an opaque cursor encoding the last `(created_at, id)` tuple — served entirely by `idx_audit_log_ws_created`. Offset paging degrades on exactly the workspaces that need the log most.

**CSV export** mirrors `export_leads_csv` (`lead_forms.py:135–203`) exactly: `csv.DictWriter(output, fieldnames=…, extrasaction="ignore")` → `StreamingResponse(iter([csv_bytes]), media_type="text/csv", headers={"Content-Disposition": "attachment; filename=audit-log.csv"})`. `changes` is serialized as compact JSON in one column. The export is bounded by the retention window; no separate row cap in v1.

### 3.8 Gating registry — `qr_backend/src/api/routes/subscription.py`
Add to `FEATURE_ENFORCEMENT` (~L541):
```python
"mfa_enforcement": "enforced",           # workspace.py PATCH /security-policy check_feature + FE panel gate
"audit_log": "enforced",                 # audit.py list/export check_feature gate
"audit_log_retention_days": "enforced",  # audit.py read-window clamp via get_limit
```
All three are seeded on **every** non-custom plan by `0040`, so `test_registry_matches_plan_seed` (which diffs the seeded JSONB keys against the registry) stays green. `audit_log_retention_days` goes into `_QUOTA_SPEC` (~L429) as `{"source": "feature", "usage": None}` — value-only, exactly like `max_file_size_mb` and `analytics_retention_days`; there is no counter to meter. `_limit_value` fail-closes a missing key to `0`. Registering `inert` and flipping to `enforced` **in this same PR** is the house convention.

### 3.9 Internal endpoints / cron / KV
**None.** No `/internal/*` route, no `x-internal-secret` consumer, no `scheduled()` ping, no `build_kv_content` branch, no `build_entitlements` change. The MFA policy is deliberately **not** threaded into the KV entitlements snapshot: that snapshot governs per-QR *worker rendering* (`white_labeling`, `ab_testing`, `brand`), and an admin policy has no meaning at scan time. Adding it would be dead weight on every KV write.

---

## 4. Cloudflare Worker / Edge Design

**No worker change.** This feature adds no QR type, no KV top-level key, no `src/pages/*` template, no `handlers/` dispatch case, no `recordScan` field, no consent-gate change, and no `wrangler.toml` cron or route. The scan hot path is **byte-for-byte unchanged**, and an end user scanning a QR is never affected by a workspace's MFA policy — a scan is anonymous public traffic with no session and no assurance level, by definition.

Because there is no new scan page or template, the **worker↔React template-mirroring house rule does not apply** (nothing to mirror), and consequently **`npm run deploy:prod` is NOT a gate** for this feature.

*One thing to be explicit about:* the audit log records **admin actions**, never **scans**. Scan data lives in `qr_scan_events` and is analytics, not an audit trail — conflating the two would put edge-volume traffic into a table designed for hundreds of rows a month.

---

## 5. Frontend Design

### 5.1 Prerequisite — re-enable user 2FA · `src/components/org/settings/SecuritySection.tsx`
Line 18 is `{/* <TwoFactorPanel onEnroll2FA={onEnroll2FA} /> */}`. **Uncomment it.** Everything it needs already exists and is wired: `settings/page.tsx` already imports `TwoFactorModal` (L17), holds `show2FAModal` state (L35), passes `onEnroll2FA` into `SecuritySection` (L130), and renders the modal (L152); `useSecurity.ts` already implements `useTwoFactorStatus` (L45), `useEnrollTOTP` (L57), `useVerifyTOTP` (L70, which runs `challenge` then `verify`), and `useUnenrollTOTP` (L94). **No new code — one line uncommented.** The separate `/[slug]/security` route stays 404'd (`page.tsx:17` `notFound()`); Settings → Security is the single reachable surface, as its own comment states.

*(The `ChangePasswordForm` on line 17 is also commented out. Out of scope — do not silently re-enable it in this PR.)*

### 5.2 Org security panel · NEW `src/components/org/settings/org-security-section.tsx`
A new **Organization** entry in the settings nav: extend the `Section` union (`settings/page.tsx:25`) and `baseSections` (L27) — the nav is already a generic `SettingsNav<T>` (`settings-nav.tsx`), so it takes the new item with no change. Owner-only, gated on `canAccessFeature(subscription, 'mfa_enforcement')`; non-entitled renders a compact upgrade card ("Require 2FA for your team — Agency"), mirroring how `showBranding` gates the branding section (`settings/page.tsx:40`).

Contents: the member 2FA roster (Enrolled / Not enrolled chips), the blast-radius warning line, and a shadcn `Switch` bound to `PATCH /security-policy` via a new mutation in `useSecurity.ts`. Enabling opens a `ConfirmDialog` (the existing primitive `TwoFactorPanel.tsx:76` already uses) naming the not-yet-enrolled members. The switch is disabled with an inline hint when the owner's own session isn't AAL2 — **presentation only**; the backend `409` is the actual guard. shadcn primitives, Tailwind tokens (`primary` / `on-surface-variant` / `surface-container`), no inline styles, ≤200 lines, one export, kebab-case filename.

### 5.3 MFA block handling · `src/lib/api-client.ts` + NEW `mfa-step-up-dialog.tsx`
Extend the `authApi` **response** interceptor: on `403` whose `detail.code === 'mfa_required'`, do **not** toast and do **not** sign out — publish the block to a small module-level subscriber that a provider-level `<MfaGate>` listens to, and surface one of two states off `useTwoFactorStatus()` (`useSecurity.ts:45`), which already wraps `listFactors()`:
- **`totp.length === 0` → enrollment interstitial**: reuse `TwoFactorModal` in a non-dismissable framing with the "this workspace requires 2FA" copy.
- **`totp.length > 0` → step-up dialog** (NEW, ≤200 lines): one 6-digit field → `supabase.auth.mfa.challengeAndVerify({ factorId, code })`, which upgrades the **current** session to `aal2` in place. No logout, no password.

On success: `queryClient.invalidateQueries()` and retry the failed request once. **The `aal1`-vs-no-factor distinction is the crux (PRD R5)** — an enrolled user dumped into enrollment sees a "you already have 2FA" dead end, which is the single most likely UX bug in this feature. Sign-out, workspace switching, and Settings → Security must all stay reachable while the gate is up.

### 5.4 Audit log page · NEW `src/app/[slug]/(dash)/audit-log/page.tsx` + `src/hooks/useAuditLog.ts`
The page composes components only (no business logic, no raw JSX blocks — house rule): a filter bar (actor / action / date range), a table (When · Who · Action · Target · Details) with an expandable before→after row, an infinite/cursor "Load more", and an Export CSV button. Sidebar entry gated on `canAccessFeature(subscription, 'audit_log')`.

`useAuditLog.ts` follows the key-factory convention from `useQRs.ts`:
```ts
export const auditKeys = {
  all: ['audit-log'] as const,
  list: (wsId: string, filters: AuditFilters) => [...auditKeys.all, wsId, filters] as const,
};
```
`useInfiniteQuery` via `authApi` with the opaque cursor as `pageParam`; `workspaceId` from `useWorkspaceStore((s) => s.currentWorkspace)?.id` (house rule — never URL params). TanStack Query only, never `useEffect + fetch`. Export is a plain authenticated download of `/audit-log/export.csv` carrying the current filters.

### 5.5 Gating · `src/lib/plan-features.ts`, `src/hooks/useSubscription.ts`
Extend the `PlanFeatures` interface (`useSubscription.ts:28`) beside the existing enterprise-ish keys (`sso`, `white_labeling`):
```ts
// Org security (Agency + custom/white-label)
mfa_enforcement: boolean;
audit_log: boolean;
audit_log_retention_days: number;   // -1 unlimited (custom only); 0 = none
```
Add `'audit_log_retention_days'` to the `getLimit` key union. Entitlement checks use the existing `canAccessFeature(subscription, …)`, which fails to `false` while loading — correct here: a non-entitled or still-loading user sees the upgrade state, never a half-rendered control.

---

## 6. External-Service Integration

**No new external service, no new environment variable, no new secret.**

**Supabase Auth MFA** is the only external dependency and it is **already provisioned** — it ships with the Supabase Auth we already use for every session. The frontend calls `supabase.auth.mfa.{listFactors, enroll, challenge, verify, unenroll}` directly (`useSecurity.ts` L45–L112); the backend never calls the Auth admin API for MFA at all. Our entire backend-side dependency is **one JWT claim (`aal`)** that Supabase already puts in every access token.

**Phase-0 checklist item:** confirm TOTP enrollment is enabled on the Supabase project **per environment** (staging + prod). If a project has MFA disabled, `enroll()` fails and — critically — **no session can ever reach `aal2`**, which would turn an enabled policy into a total lockout. Verify before Phase 1, not after.

**No AI / Anthropic call. No Resend email** — so the unpublished `_dmarc.qravio.app` record is **not** a gate for this feature (adding "MFA policy enabled" notification emails later would make it one; that is why notifications are a Non-Goal). **No Razorpay/LemonSqueezy touch. No PDF/WeasyPrint. No Cloudflare API call.**

---

## 7. API Contracts

```jsonc
// GET /api/v1/workspaces/{workspace_id}/security-policy      (owner only)
{
  "require_mfa": true,
  "enabled_at": "2026-07-20T09:14:00Z",
  "enabled_by": "3f1c…",
  "members": [                                  // roster — see §3.6 / §12 Q3
    { "user_id": "3f1c…", "email": "meera@…", "role": "owner",  "mfa_enrolled": true  },
    { "user_id": "9ab2…", "email": "arjun@…", "role": "editor", "mfa_enrolled": false }
  ]
}

// PATCH /api/v1/workspaces/{workspace_id}/security-policy    (owner only)
{ "require_mfa": true }

// 403 — plan doesn't include it
{ "detail": { "code": "mfa_enforcement_locked", "upgrade_to": "agency" } }
// 409 — the enabling owner is not themselves on 2FA (anti-lockout guard)
{ "detail": { "code": "mfa_enroll_self_first" } }
```

```jsonc
// ANY workspace-scoped endpoint, when the policy is on and the session is aal1:
// HTTP 403 — deliberately NOT 401 (a 401 trips the client's refresh/sign-out path)
{ "detail": { "code": "mfa_required", "workspace_id": "b7e0…" } }
```

```jsonc
// GET /api/v1/workspaces/{workspace_id}/audit-log            (owner only, gated)
//   ?action=member.role_changed&actor_id=…&from=2026-07-01&to=2026-07-25&cursor=…&limit=50
{
  "items": [
    {
      "id": "184922",
      "created_at": "2026-07-24T11:02:33Z",
      "actor": { "user_id": "3f1c…", "email": "meera@…", "role": "owner" },
      "action": "member.role_changed",
      "target": { "type": "member", "id": "9ab2…", "label": "arjun@…" },
      "changes": { "before": { "role": "viewer" }, "after": { "role": "editor" } },
      "ip_address": "103.21.…",
      "user_agent": "Mozilla/5.0 …"
    },
    {
      "id": "184901",
      "created_at": "2026-07-24T10:40:12Z",
      "actor": { "user_id": "9ab2…", "email": "arjun@…", "role": "editor" },
      "action": "qr.updated",
      "target": { "type": "qr", "id": "c41d…", "label": "Diwali Poster" },
      "changes": { "before": { "destination": "https://a.example" },
                   "after":  { "destination": "https://b.example" } }
    }
  ],
  "next_cursor": "MTg0OTAxfDIwMjYtMDctMjRUMTA6NDA6MTJa",   // opaque (created_at,id)
  "retention_days": 365
}

// 403 — plan doesn't include it
{ "detail": { "code": "audit_log_locked", "upgrade_to": "agency" } }

// GET /api/v1/workspaces/{workspace_id}/audit-log/export.csv (owner only, gated)
// 200 text/csv; Content-Disposition: attachment; filename=audit-log.csv
// created_at,actor_email,actor_role,action,target_type,target_label,changes,ip_address,user_agent
```

No existing endpoint's contract changes. Every workspace-scoped endpoint gains **one new possible failure mode** (`403 mfa_required`) that can only occur on a workspace that opted into the policy.

---

## 8. Security, Privacy & Abuse

- **This one *is* a security boundary** — unlike QR expiry, which we were careful to call a lifecycle control. Enforcement therefore **fails closed**: an unreadable/absent `aal` claim is treated as `aal1`, and a policy value we cannot resolve falls through to an explicit lookup rather than defaulting to "off". The cost of failing closed is bounded (it only affects workspaces that opted in, and the step-up path is one tap).
- **Enforcement completeness is the whole ballgame.** A single un-instrumented inline membership check (§3.4) is a bypass. That is why the mitigation is a **grep-based coverage test**, not a review checklist — reviews miss the 16th call site.
- **Known, disclosed limitation — API keys are outside the policy.** `/api/public/v1` authenticates by key (`api_public.py`), carries no JWT, and has no assurance level. The policy governs **dashboard/JWT sessions only**. Mitigations: minting a key **is** behind the policy (`security.py:247`), key creation and revocation are audited, and owners can revoke. We deliberately do **not** auto-revoke keys when the policy is enabled — that would silently break running integrations.
- **Anti-lockout is a security property, not UX polish.** The `409 mfa_enroll_self_first` guard is enforced server-side from `request.state.auth_aal`, independent of the UI. There is **no self-serve bypass** (a bypass defeats the control); break-glass is a documented support runbook (`UPDATE workspaces SET require_mfa=false` after out-of-band identity verification), and that operation is itself recorded as a system-actor audit row.
- **Audit immutability is enforced by the database, not by discipline.** `REVOKE UPDATE, DELETE, TRUNCATE` from `service_role` (the identity the app actually runs as) **plus** row- and statement-level blocking triggers. The application literally cannot rewrite history. Verified by a test that asserts the `UPDATE` fails — not by reading the migration.
- **No secrets in `changes`.** Token creation records `name` + `token_prefix` only, never `token_hash`; password and OTP flows are not audited at all; QR diffs carry changed keys only, never full records.
- **PII posture (DPDP).** `audit_log` holds member emails, IPs, and user agents — personal data. It is service-role-only (RLS on, no policies), **owner-read-only**, never exposed at the edge or to the Worker, and contains **no end-user/scanner data**. Retention is a **read clamp**, so a shorter plan window narrows exposure without destroying the record. The absence of FKs means member deletion does not erase the trail — an intentional trade-off (auditability over erasure) that the DPDP/deletion-cascade work must be told about explicitly.
- **Tenant isolation:** every audit read and write carries an explicit `workspace_id` filter, because the service-role client bypasses RLS. Reads additionally require `require_workspace_role(["owner"])`.
- **Abuse:** no new unauthenticated surface, no per-use cost, no fan-out. The only new write is one small INSERT per admin action, on endpoints that are already Bearer-authed and permission-gated. Audit-write volume is bounded by the mutation endpoints' own rate limits.
- **Consent gate / scan path:** entirely unaffected. No edge change, no new client-side capture, no marketing tag.

---

## 9. Performance, Scale & Cost

- **MFA enforcement: zero added round-trips on the hot path.** The policy rides the `workspace_members` query `get_workspace_role` already runs, as a PostgREST embedded resource — the same shape as `workspace.py:143`. The added work per request is one dict lookup and one string compare. For the overwhelming majority (`require_mfa = false`) `enforce_org_mfa` returns on its first line.
- **The bypass sites (§3.4) do add a lookup** — mitigated by a 30-second in-process TTL cache mirroring `_PLAN_CACHE` (`subscription.py:207`), so it is at most one `SELECT` per workspace per 30s per process. **Documented consequence:** *disabling* the policy can take up to 30s to propagate on those routes (enabling is immediate on the `get_workspace_role` path, which reads live). For a security control, lagging *off* is the safe direction.
- **Audit writes:** one INSERT per admin mutation, on endpoints that already do 2–5 queries. The only *added* read is the before-image `SELECT` on role change (§3.5). Bulk QR creation writes **one** summary row, not N — the one place this could have gone quadratic.
- **Audit reads:** keyset pagination served entirely by `idx_audit_log_ws_created`; no offset scans, no count queries. CSV export is bounded by the retention window and streamed, never buffered as a list.
- **Storage:** ~300 bytes/row on an event class orders of magnitude rarer than scans. A very busy 20-person workspace might write a few thousand rows a month — kilobytes. Three indexes on a small table are cheap. No purge job in v1; if growth ever surprises us, a purge is additive and doesn't change the read path.
- **Cost:** **zero incremental COGS.** No AI call, no email, no third-party API, no edge compute, no background job. The only resource is Postgres rows.

---

## 10. Testing Strategy

**Backend (pytest, `qr_backend/tests/unit_tests/`):**

*`test_org_mfa_enforcement.py`*
- Policy off → `aal1` session passes (the no-op path must stay a no-op).
- Policy on → `aal2` passes; `aal1` → `403` with `detail.code == "mfa_required"`; **missing/unreadable `aal` → 403 (fail-closed)**, asserted explicitly.
- **Status code is 403, never 401** — its own assertion, because a regression here produces a client redirect loop, not a visible error.
- `PATCH /security-policy`: non-owner → 403; owner on a non-entitled plan → 403 `mfa_enforcement_locked`; owner at `aal1` enabling → **409 `mfa_enroll_self_first`**; owner at `aal2` → 200 + policy row + audit row. **Disabling is always permitted to an owner** (anti-lockout).
- **Exemption regression suite:** with the policy on and an `aal1` session, `GET /workspaces` (list), `get_my_workspace_by_slug`, `/security/*` (login-history, preferences, TOTP status), and `accept_invitation` **all still succeed** — this is what keeps the enrollment path reachable, and it is the test most likely to catch an over-eager enforcement PR.
- **API-key path unaffected:** a `/api/public/v1` call against a policy-on workspace succeeds (no JWT, no AAL) — the disclosed limitation, asserted so it stays deliberate.
- **Coverage guardrail (new test):** grep route modules for `table("workspace_members")`; every hit must be in `deps.py`, on the exemption allowlist, or paired with an `enforce_org_mfa` call. Fails on any new un-instrumented site.

*`test_audit_log.py`*
- Each instrumented site writes **exactly one** row with the right `action`, `target_*`, and `changes` — parametrized per site; role change carries a correct **before**-image.
- **Bulk QR create writes one summary row**, not N.
- **Audit-write failure does not break the mutation:** patch the insert to raise → the role change still returns 200, and an ERROR is logged (assert the log, so the failure isn't silent).
- **Immutability, against the real DB behaviour:** `UPDATE` and `DELETE` on `audit_log` as the service role **raise**; `TRUNCATE` raises. This is a migration test, not a unit test — run it against a real Postgres in the migration-verification step, since a mocked client would happily "succeed".
- **No secrets leak:** the `api_token.created` row contains `token_prefix` and never `token_hash`.
- Read gating: non-entitled → 403 `audit_log_locked`; non-owner → 403; entitled owner → 200. Retention clamp: with `audit_log_retention_days = 30`, a 60-day-old row is absent and `retention_days: 30` is echoed. `-1` → unbounded.
- Keyset pagination: pages don't repeat or skip rows across a concurrent insert; CSV export headers + one round-trip row match the JSON shape.
- **`test_feature_gate_coverage` stays green** after the `inert→enforced` flip — all three keys seeded on every non-custom plan by `0040` **and** referenced from real gates (`workspace.py`, `audit.py`).

**Frontend (Vitest):** the `403 mfa_required` interceptor routes to the gate **without** signing out; **`totp.length === 0` → enrollment, `> 0` → step-up** (the R5 crux — assert both branches); a successful step-up retries the failed request once; the org panel renders the upgrade card for non-entitled and the switch for entitled; the switch is disabled when the owner is `aal1`; `useAuditLog` paginates by cursor and passes filters through. *(Note the ~29 pre-existing FE test failures baseline — only net-new failures in the audit/MFA files count as regressions.)*

**Worker:** none — no worker change.

**Manual / staging:** a canary workspace with the policy on. Verify with a real authenticator: enroll → step up → work normally; a second browser with a pre-policy session gets the step-up dialog, not a logout; a member with no factor gets the interstitial and is auto-retried through after enrolling; a **second, policy-off workspace in the same session stays fully usable**; sign-out works while blocked; the audit log shows every action taken during the test, and the CSV opens cleanly in a spreadsheet.

---

## 11. Observability & Rollout

**Phase 0a — Re-expose user 2FA (ships alone, first, unconditionally).** Uncomment `SecuritySection.tsx:18`. Verify enroll → verify → status → unenroll against a real authenticator on staging **and** prod. Confirm TOTP is enabled on the Supabase project in both. **Hard gate on everything below** — without an enrollment path, enabling the policy is a guaranteed lockout. *Worth shipping on its own merits even if this PRD is otherwise deferred: we currently show no way to turn on a 2FA feature we have.*

**Phase 0b — Migration + audit write path (internal, invisible).** Apply `0040`. Ship `record_audit` + the §3.5 instrumentation. Register the three flags `inert`→`enforced` in this PR. **No read surface, no enforcement yet** — the log accumulates quietly so Phase 2 has real history rather than an empty table. Verify immutability against the real database.

**Phase 1 — Enforcement + audit read (closed: internal + 2–3 design partners).** AAL propagation, `mfa.py`, the `deps.py` wiring, **all §3.4 bypass sites**, the security-policy endpoints, the org panel, the interstitial + step-up + auto-retry, the audit page + CSV. Behind a FE flag. Run the full exemption regression suite before widening.

**Phase 2 — GA (deal-triggered).** Remove the FE flag; the flags are already `enforced`. Update security collateral. **GA gates:** zero wrongful lockouts on the design-partner cohort; immutability + coverage tests green; **a named deal is asking** (PRD §9 — if nothing is asking, hold at Phase 1).

**Deploy order (strict):** apply `0040` → deploy backend → deploy frontend. The migration is a **hard prerequisite**: the enforcement helper reads `workspaces.require_mfa` and the audit helper writes `audit_log`, so a backend deployed first would error on the first mutation. A frontend deployed early merely shows a panel whose `PATCH` 404s — harmless. **No worker deploy. No DMARC gate. No cron.**

**Metrics / logs (no new infrastructure — structured logs + SQL over `audit_log`):**
- **`mfa_required` 403 rate per workspace** — the lockout signal. Expect a spike at the flip decaying to ~0 within 72h; a flat, non-decaying rate means the enrollment path is broken and is the trigger to roll the policy back.
- **Audit-write failure count** (ERROR log with `action`) — must be 0. Anything else means the trail is untrustworthy.
- Audit rows/day/workspace (growth watch), CSV exports/quarter (is the log actually consulted?), % of entitled workspaces with `require_mfa = true`, member 2FA enrollment rate on enforced workspaces.
- **Rollback is one `UPDATE`:** `UPDATE workspaces SET require_mfa = false WHERE id = …` disables the policy per-workspace instantly (subject to the 30s TTL cache on the §3.4 routes). No deploy needed. The audit write path has no rollback switch — and needs none, since it cannot fail a user's action.

---

## 12. Open Technical Questions & Risks

1. **Enforcement coverage across the inline-membership sites** — the highest-risk item, resolved by design in §3.4 (one shared helper + explicit disposition per site + a grep-based coverage test). **Confirm at build time** that the site list is still accurate; `scan.py` in particular is large and actively edited, and a 16th inline lookup added between spec and build would be a silent hole.
2. **`aal` on the `get_user()` fallback path** — resolved: read the claim from the already-server-verified token via `jwt.get_unverified_claims`, and fail **closed** if unreadable. Confirm at build which path a given environment actually takes (`SUPABASE_JWT_SECRET` set ⇒ fast path; a project on asymmetric keys takes the fallback on **every** request, making this branch load-bearing rather than exceptional).
3. **The member 2FA roster is not cleanly available server-side** (§3.6) — the service-role REST client cannot enumerate another user's Supabase factors, and a user can only list their own. Options: (a) an echo endpoint recording each member's enrollment state when their own enroll/unenroll succeeds; (b) **drop the roster from v1** and show only an aggregate "N members were blocked in the last 24h" derived from the `mfa_required` 403 counter. *Recommend (b) for v1 — it is honest, needs no new write path, and the owner's real question ("is anyone stuck?") is answered better by the block count than by a roster that can go stale. Revisit (a) if a design partner asks.* **This is the one genuinely unresolved design point in the spec.**
4. **Policy freshness vs. round-trips** — resolved: embed on the `get_workspace_role` path (live, zero cost); 30s TTL cache on the bypass sites. Accepted consequence: disabling can lag ≤30s on those routes. Confirm the embed shape works with `maybe_single()` at build; if PostgREST returns the embed as `null` under some join condition, the defensive read must fall through to `enforce_org_mfa_by_lookup` — **never** to "policy off".
5. **Best-effort vs. strict audit writes (PRD Open Q3)** — v1 is best-effort + loud ERROR (never fail a user's action over telemetry). A strict "no action without its row" mode is a real ask from a compliance-hard buyer; if it comes, implement it as a **per-workspace setting**, not a global flip.
6. **No FKs on `audit_log` (PRD R7)** — resolved and deliberate: FKs would collide with the append-only triggers on cascade and would erase the trail exactly when it matters. **Coordinate explicitly with the pending account-deletion-cascade fix** so that work doesn't add one. Accepted consequence: orphan rows referencing deleted workspaces/users, carrying denormalized labels so they stay legible.
7. **Owner-only audit reads (PRD Open Q2)** — recommend owner-only; the log carries colleagues' IPs and user agents. Widening to editors later is a one-line dependency change; narrowing after launch is a regression to someone.
8. **Which QR mutations to audit (PRD Open Q5)** — recommend create/update/delete with a **changed-keys-only** diff and `destination` before→after as the headline. Watch the volume on `qr.updated`: if the builder autosaves on every keystroke, this could get chatty — **verify the update endpoint's call pattern at build** and, if it's autosave-driven, either debounce the audit write or restrict `qr.updated` rows to a changed-key allowlist (`destination`, `status`, `is_password_protected`, `start_at`/`end_at`).
9. **SCIM stays out — do not let it creep back in.** It only makes sense on top of SSO/SAML, which is a recorded "do not build" (`SSO_SAML_PRD.md`). If a buyer asks for SCIM, the answer is the SSO decision record, not a scope extension here.

### Appendix — Key Files

| Concern | File |
|---|---|
| Migration (policy columns + `audit_log` + immutability + 3 flags) | `qr_backend/migrations/0040_org_mfa_audit_log.sql` (NEW — **re-verify the slot**; disk max = `0032`) |
| AAL propagation | `qr_backend/src/api/middlewares/auth_bearer.py` (fast path ~L154–170; `get_user()` fallback ~L171–189) |
| Enforcement helper | `qr_backend/src/api/dependencies/mfa.py` (NEW — `enforce_org_mfa`, `enforce_org_mfa_by_lookup` + 30s TTL cache) |
| Enforcement seam | `qr_backend/src/api/dependencies/deps.py` (`get_workspace_role` L33: embed at L58, owner fallback at L74, calls before both returns L66/L83) |
| Inherited enforcement | `qr_backend/src/api/dependencies/permissions.py` (`require_can_read/create/update/delete` — no change needed) |
| Bypass sites to instrument | `scan.py` L920/L1010/L1094/L1242/L1271/L1298/L1546 · `storage.py` L174/L367/L549 · `security.py` L198/L247/L327 · `ai_analyst.py` L76 |
| Deliberate exemptions | `workspace.py` L142/L192 · `security.py` L360 + all `/security/*` user-scoped routes · `accept_invitation` |
| Security-policy endpoints | `qr_backend/src/api/routes/workspace.py` (NEW `GET`/`PATCH /{workspace_id}/security-policy`; `update_workspace` ~L749) |
| Audit write helper | `qr_backend/src/utilities/audit.py` (NEW — mirrors `_log_login_event`, `auth.py:29`, with an ERROR log instead of silent `pass`) |
| Audit instrumentation | `workspace.py` L278/L367/L550/L651/L701/L735/L763 · `security.py` L277/L341 · `qr.py` create/update(~L2839)/delete/bulk · `custom_domain.py` |
| Audit read + CSV | `qr_backend/src/api/routes/audit.py` (NEW — mirrors `export_leads_csv`, `lead_forms.py:135–203`), registered in `src/api/endpoints.py` |
| Gating | `qr_backend/src/api/routes/subscription.py` (`FEATURE_ENFORCEMENT` ~L541 ×3; `_QUOTA_SPEC` ~L429 for `audit_log_retention_days`) |
| Coverage guardrails | `qr_backend/tests/unit_tests/test_feature_gate_coverage.py` (stays green) + NEW `test_org_mfa_enforcement.py`, `test_audit_log.py` |
| Re-enable user 2FA (**prerequisite**) | `qr_frontend/src/components/org/settings/SecuritySection.tsx:18` (uncomment `TwoFactorPanel`) |
| Existing 2FA plumbing (reused as-is) | `qr_frontend/src/hooks/useSecurity.ts` (L45/L57/L70/L94) · `security/TwoFactorPanel.tsx` · `settings/TwoFactorModal.tsx` |
| Org security panel | `qr_frontend/src/components/org/settings/org-security-section.tsx` (NEW) + `src/app/[slug]/(dash)/settings/page.tsx` (`Section` L25, `baseSections` L27) |
| MFA block handling | `qr_frontend/src/lib/api-client.ts` (403 `mfa_required` interceptor) + NEW `mfa-step-up-dialog.tsx` |
| Audit log page | `qr_frontend/src/app/[slug]/(dash)/audit-log/page.tsx` (NEW) + `src/hooks/useAuditLog.ts` (NEW) |
| FE gating | `qr_frontend/src/lib/plan-features.ts` · `src/hooks/useSubscription.ts` (`PlanFeatures` ~L28: `mfa_enforcement`, `audit_log`, `audit_log_retention_days`) |
| SCIM/SSO decision record | `PRD_TRD/NOT_DONE/SSO_SAML_PRD.md` (why SCIM is a Non-Goal) |
| Worker | **No change** — no KV, no type, no template, no cron; `npm run deploy:prod` not required |
