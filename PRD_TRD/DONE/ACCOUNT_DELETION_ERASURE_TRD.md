# TRD — Account Deletion & Data Erasure (Right to Erasure)

**Status:** Draft · **Author:** Engineering (Staff) · **Date:** 2026-07-27
**Priority:** **P0 compliance debt.** The published privacy policy grants a Right to Erasure (`qr_frontend/src/app/(marketing)/privacy/page.tsx:228`) with a 30-day SLA (`:243`); **no deletion path exists anywhere in the monorepo.** Verified: no `DELETE /workspaces/{id}` route (`workspace.py` deletes only members `:677` and invitations `:717`), no user-deletion route in `security.py`, no Supabase Auth `delete_user` call in `qr_backend/src`.
**Tiers:** **All, including Free.** No tier gate.
**Plan flags:** **None.** No `plans.features` key, no `FEATURE_ENFORCEMENT` entry, no `PlanFeatures` field — so `test_feature_gate_coverage` is untouched. Gating a statutory right would be the violation.
**Migration slot:** **`0044_account_deletion_erasure.sql` — PROVISIONAL.** Disk reality at drafting: highest present is `0032_lemonsqueezy_variant_backfill.sql`; slots `0033`–`0043` are claimed by drafted-but-unapplied specs in `PRD_TRD/NOT_DONE/` (`0033` QR expiry · `0034` UPI · `0035` location · `0036` phone · `0037` GA4 · `0038` WhatsApp · `0039` GST · `0040` org MFA · `0041` restaurant menu · `0042` multilingual · `0043` loyalty). **The slot MUST be re-verified against `qr_backend/migrations/` at build time and renumbered to the lowest free slot.** This repo has a commit history of fixing stale slot numbers: `AI_BUSINESS_CARD_OCR` reserved `0024` and shipped as `0026`; `WALLET_PASSES` reserved `0023` and lost it to `0023_outbound_webhooks.sql`. **Treat this header as a hint, never as truth.**
**Services touched:** `qr_backend` (new routes, purge engine, migration, 4 email templates) · `qr_frontend` (delete card + dialog + banner + restore interstitial + hook, privacy-policy correction) · `qr_cf_code` (**one line** — a `ping("/internal/deletion-purge")` in the existing `0 6 * * *` `scheduled()` branch; **no new cron trigger, `wrangler.toml` `crons` unchanged**, no fetch-path change, no template).
**Implements PRD:** Account Deletion & Data Erasure (Right to Erasure). **Unblocks** `WHATSAPP_REVIEW_REMINDERS`, `EMAIL_SIGNATURE_EMBED`, `GST_INVOICE_BILLING`, `LOYALTY_STAMP_CARD`, all of which name this as a prerequisite.

**Two corrections to the framing this spec was commissioned under — verified against code, and both change the design:**

1. **KV teardown helpers already exist and per-QR deletes already use them.** `delete_from_kv` (`cloudflare_kv.py:519`) is called by `delete_qr_code` (`qr.py:3430`), `bulk_delete_qr_codes` (`qr.py:3386`), and the update path (`qr.py:3313`); `delete_domain_from_kv` (`:508`) by `custom_domain.py:480` and `razorpay_routes.py:1124`. **The risk is therefore not "no teardown exists" but "a bulk/cascade purge bypasses the routes that do it."** A `DELETE FROM workspaces` cascade drops `qr_codes` — and with it the `short_code` values that are our only handle on the edge keys. The ship-blocker requirement is precise: **enumerate and persist every key before deleting any row** (§3.3 step 1). Restated, not softened.
2. **Storage is workspace-prefixed, not user-prefixed.** The `storage.py:9` module docstring claims `{bucket}/{user_id}/{uuid}_{original_filename}`, but every current writer is workspace-scoped: `{workspace_id}/temp/{uuid}/{name}` (`storage.py:237`), `{workspace_id}/{qr_id}/{file_name}` (`qr.py:1706`, `:1737`, `:1803`, `:1858`), `{workspace_id}/{qr_id}/logo.{ext}` (`qr.py:2357`), `{workspace_id}/branding/logo-*.{ext}` (`branding.py:164`). Genuinely user-prefixed paths do exist — `avatars/{user_id}/avatar.{ext}` (`storage.py:143`) and legacy `{user_id}/…` uploads still honoured at `storage.py:497` and `:552-554`. **The erasure handle is therefore two prefix sweeps (workspace *and* user) plus a row-derived path list, not one user-prefix listing** (§3.4).

---

## 1. Overview & Architecture

Account deletion is a **soft-delete state machine with a 30-day grace period followed by an ordered, checkpointed, resumable hard purge**. It is deliberately *not* a single transactional delete: four independent stores (Postgres, Supabase Storage, Cloudflare KV, Cloudflare-for-SaaS) must be reconciled, and only one of them has transactions.

The design has three load-bearing properties:

- **External state dies before the rows that describe it.** KV keys, storage objects, and CF hostnames are torn down *before* the Postgres rows are deleted, because the rows are the only index into that external state. Deleting rows first is unrecoverable.
- **Every step is idempotent and checkpointed.** A crash resumes; a re-run of a finished purge is a no-op. Progress lives on the request row, so resumption survives process death, deploys, and restarts.
- **Nothing is ever marked `purged` optimistically.** A step that exhausts retries lands in `dead_letter` and alerts. A silently-incomplete purge is the worst possible outcome — it looks compliant and isn't.

**Services touched**

| Service | Change |
|---|---|
| `qr_backend` | Migration `0044` (`deletion_requests` + `_claim_deletion_request` RPC). New `src/utilities/account_purge.py` (enumeration, teardown, ordered purge, checkpointing). New routes in `src/api/routes/security.py` (`/security/deletion/preflight`, `POST`/`GET`/`DELETE` `/security/deletion`). New `POST /internal/deletion-purge` in `src/api/routes/internal.py`. New `src/utilities/storage_purge.py` (recursive, paginated prefix sweep). 4 new Resend templates in `src/utilities/email.py`. **No new plan flag, no `FEATURE_ENFORCEMENT` entry.** |
| `qr_frontend` | `AccountSection.tsx` red card body replaced (extracted to `delete-account-card.tsx` + `delete-account-dialog.tsx`, ≤200 lines each). New `useAccountDeletion.ts` TanStack hook. Scheduled-deletion banner in the dash layout. Restore interstitial on the `(auth)` side. **`privacy/page.tsx:192` amended 90 → 30 days.** |
| `qr_cf_code` | **One line.** Add `ctx.waitUntil(ping("/internal/deletion-purge", "deletion-purge"))` to the existing `event.cron === "0 6 * * *"` branch (`src/index.js:73-77`). **No new cron trigger** (`wrangler.toml` `crons = ["0 0 1 * *", "0 6 * * 1", "0 6 * * *", "*/5 * * * *"]` is unchanged), **no fetch-path change**, **no new page/template** — the T+0 pause reuses the existing `status === "paused"` → `getPausedPage` branch at `src/index.js:368`. The worker↔React template-mirroring rule does not apply (nothing to mirror). A `npm run deploy:prod` **is** required for the one-line dispatch. |

**Data flow — request (T+0)**

```
Settings → Account → "Delete my account"
  → GET /security/deletion/preflight            (read-only impact summary)
      → owned workspaces (workspaces.owner_id) + member-only workspaces
      → per-workspace member counts → case A / B / C classification
      → counts: qr_codes, qr_scan_events, qr_files, custom_domains
      → active subscriptions (razorpay | lemon_squeezy)
      → blocking conditions (case C unresolved)
  → user types their email → POST /security/deletion {confirm_email, workspace_resolutions[]}
      → BearerTokenAuthMiddleware → get_current_user_id
      1. validate confirm_email == request.state.user_email     [400 on mismatch]
      2. re-classify server-side; reject if any case-C unresolved [409]
      3. INSERT deletion_requests (status='pending', purge_after=now()+30d)
      4. cancel subscriptions  (razorpay: rz.subscription.cancel; MoR: flag manual — R4)
      5. for each solely-owned ws: UPDATE qr_codes SET status='paused'
                                   → sync_qr_to_kv(qr_id, db)     (reversible)
      6. invalidate_plan_cache(ws) for every touched workspace
      7. revoke sessions (auth.admin.sign_out / refresh-token revoke)
      8. Resend: confirmation email (+ member notifications for case C)
  → 202 {status:'pending', purge_after:'2026-08-26T…'}
```

**Data flow — purge (T+30)**

```
CF Worker scheduled() "0 6 * * *"  →  POST /internal/deletion-purge  (x-internal-secret)
  → claim up to PURGE_BATCH_SIZE due requests via _claim_deletion_request (lease)
  → for each, resume from checkpoint:
      step 1  enumerate  → persist short_codes[] + domains[] + storage_paths[] on the row
      step 2  cf_saas    → delete_custom_hostname(cf_id) × M
      step 3  kv         → delete_from_kv(sc) × N ; delete_domain_from_kv(host) × M ; POST-VERIFY
      step 4  storage    → recursive prefix sweep (workspace + user) + row-derived paths
      step 5  db         → explicit deletes, leaf → root (cascade inventory §2)
      step 6  billing    → pseudonymise subscriptions (NEVER delete)
      step 7  auth       → auth.admin.delete_user(user_id)
      step 8  finalise   → strip PII from the request row, status='purged'
  → any step exhausting MAX_ATTEMPTS → status='dead_letter' + alert  (never 'purged')
  → Resend: completion email (sent at step 8, to the address captured at step 1)
```

---

## 2. Data Model & Migrations

### 2.1 The cascade inventory

**This table is the specification of what erasure must destroy.** It is also a living document: every future PRD that adds a user- or workspace-scoped table must add a row (the four blocked specs will add `reminder_contacts`, `qr_loyalty_*`, `workspace_billing_profile`).

**Verification status — read this before trusting the "Cascade today" column.** Only tables created by migrations `0010`+ have FK definitions in `qr_backend/migrations/`; those rows are cited with `file:line` and are **verified**. The base schema (everything created directly in Supabase before `0010`) **is not in this repo**, so its cascade state is **unverified from source** and must be introspected (§2.2) before implementation. Rows marked ⚠️ are assumptions to be confirmed, not facts.

**Workspace-scoped** (destroyed when a solely-owned workspace is purged):

| Table | FK / scope | Cascade today | Purge action |
|---|---|---|---|
| `workspaces` | root | — | **Delete explicitly** (case A/C-ii only) |
| `workspace_members` | ⚠️ `workspace_id` | ⚠️ unverified | Delete explicitly (all rows for purged ws; **plus the requester's rows in every other ws** — case B) |
| `workspace_invitations` | ⚠️ `workspace_id` | ⚠️ unverified | Delete explicitly; **also delete by `email` = requester's email across all workspaces** (an invite carries their address as PII) |
| `qr_codes` | ⚠️ `workspace_id` | ⚠️ unverified | **Enumerate `short_code` first** (§3.3 step 1), then delete explicitly |
| `qr_destinations` | ⚠️ `qr_id` | ⚠️ unverified | Delete explicitly (holds `rules` JSONB routing config) |
| `qr_scan_events` | `workspace_id` + `qr_id` (both confirmed in use, `internal.py:378-393`, `:552-555`) | ⚠️ unverified | Delete explicitly, **batched** — highest-volume table by far (§9) |
| `qr_scan_counters` | ⚠️ `qr_id` | ⚠️ unverified | Delete explicitly |
| `qr_files` | ⚠️ `qr_id` | ⚠️ unverified | **Read `file_path` + `metadata.thumbnail_paths` first** (storage handles), then delete |
| `qr_designs` | ⚠️ `qr_id` | ⚠️ unverified | Delete explicitly |
| `qr_design_templates` | ⚠️ workspace or global | ⚠️ unverified | **Verify scope before acting** — if global/shared, do NOT delete |
| `qr_link_pages`, `qr_link_items` | ⚠️ `qr_id` / page | ⚠️ unverified | Delete explicitly (`qr_link_items` is the parent of `qr_link_click_events`) |
| `qr_vcard_details`, `qr_business_details`, `qr_apps_details`, `qr_event_details`, `qr_coupon_details`, `qr_landing_page_details`, `qr_social_media_details`, `qr_email_details`, `qr_sms_details`, `qr_whatsapp_details`, `qr_wifi_details`, `qr_paypal_details`, `qr_bitcoin_details` | ⚠️ `qr_id` | ⚠️ unverified | Delete explicitly — **all 13**; these hold the richest PII (names, phones, addresses). Enumerated from `build_kv_content` (`cloudflare_kv.py:396-475`) |
| `qr_lead_forms` | `qr_codes` PK | ✅ CASCADE (`0012:26`) | Cascades; delete explicitly anyway (holds owner `notify_email`) |
| `qr_lead_submissions` | `qr_codes` + `workspaces` | ✅ CASCADE ×2 (`0012:37,38`) | Cascades; **delete explicitly** — third-party end-customer PII |
| `qr_review_funnel` | `qr_codes` PK | ✅ CASCADE (`0022:17`) | Cascades |
| `qr_link_click_events` | `qr_link_items` + `qr_codes` | ✅ CASCADE ×2 (`0016:35,36`) | Cascades; delete explicitly, batched |
| `qr_tags` | `qr_codes` + `tags` | ✅ CASCADE ×2 (`0025:33,34`) | Cascades |
| `tags` | `workspaces` | ✅ CASCADE (`0025:20`) | Cascades |
| `qr_webhook_milestones` | `qr_codes` | ✅ CASCADE (`0024:21`) | Cascades |
| `retargeting_pixels` | `workspaces` | ✅ CASCADE (`0013:27`) | Cascades |
| `workspace_branding` | `workspaces` PK | ✅ CASCADE (`0011:18`) | **Read `logo_url` first** (storage handle), then cascades |
| `webhook_endpoints` | `workspaces` | ✅ CASCADE (`0023:29`) | Cascades (holds Fernet-encrypted secrets) |
| `webhook_deliveries` | `webhook_endpoints` | ✅ CASCADE (`0023:46`) | Cascades; **also has its own `workspace_id`** (used at `webhook_dispatch.py:573`) — delete by that too, in case an endpoint row is already gone |
| `scheduled_reports` | `workspaces` + `qr_codes` | ✅ CASCADE ×2 (`0018:30,31`) | Cascades |
| `report_links` | `workspaces` + `qr_codes` + `folders` | ✅ CASCADE ×3 (`0017:18,20,21`) | Cascades — **public share tokens; must die** |
| `analytics_alert_configs` | `workspaces` PK | ✅ CASCADE (`0018:45`) | Cascades |
| `alert_events` | `workspaces` | ✅ CASCADE (`0018:61`) | Cascades |
| `ai_analyst_settings` | `workspaces` PK | ✅ CASCADE (`0014:32`) | Cascades |
| `ai_analyst_usage` | `workspaces` | ✅ CASCADE (`0014:46`) | Cascades |
| `card_ocr_usage` | `workspaces` | ✅ CASCADE (`0026:33`) | Cascades |
| `api_usage` | `workspaces` | ✅ CASCADE (`0010:25`) | Cascades |
| `folders` | ⚠️ `workspace_id` | ⚠️ unverified | Delete explicitly (parent of `report_links.folder_id`) |
| `custom_domains` | ⚠️ `workspace_id` | ⚠️ unverified | **Read `cf_custom_hostname_id` + `domain` + `status` first**, tear down CF + KV, then delete. `qr_codes.custom_domain_id` is `ON DELETE SET NULL` (`0002:15`) — harmless, the QRs die anyway |
| `subscriptions` | ⚠️ `workspace_id` | ⚠️ unverified | **NEVER DELETE — pseudonymise** (§3.6, R10) |
| `api_tokens` | ⚠️ `workspace_id` | ⚠️ unverified | Delete explicitly — live credentials (`security.py:320`) |

**User-scoped** (destroyed regardless of workspace outcome):

| Table | Scope | Cascade today | Purge action |
|---|---|---|---|
| `users` | `id` = auth uid (`workspace.py:390`, `auth.py:110`) | ⚠️ unverified | Delete explicitly, **last before auth** |
| `profiles` | `id` = auth uid (`security.py:357`) | ⚠️ unverified | Delete explicitly. ⚠️ **`users` and `profiles` are both referenced in live code — confirm whether one is a view/alias of the other before writing two deletes** |
| `login_events` | `user_id` (`security.py:378-385`) | ⚠️ unverified | **Hard-delete** — IP/UA/city, no retention basis (PRD Open Q6) |
| `security_preferences` | ⚠️ `user_id` | ⚠️ unverified | Delete explicitly |
| `workspace_members` | `user_id` | ⚠️ unverified | Delete the requester's rows in **every** workspace, including ones that survive (case B) |
| `workspace_invitations` | `email` | ⚠️ unverified | Delete by requester's email, all workspaces |
| Supabase **`auth.users`** | Supabase Auth | n/a | `auth.admin.delete_user(user_id)` — **the very last step** |

**External state (no FK can help here — this is why the purge is ordered):**

| Store | Handle | Teardown |
|---|---|---|
| Cloudflare KV — QR content | `qr_codes.short_code` | `delete_from_kv(sc)` (`cloudflare_kv.py:519`) |
| Cloudflare KV — domain map | `custom_domains.domain` (only `status='verified'`) | `delete_domain_from_kv(host)` (`:508`) |
| Cloudflare for SaaS | `custom_domains.cf_custom_hostname_id` | `delete_custom_hostname(id)` (`cloudflare_saas.py:123`) |
| Supabase Storage | 5 path shapes + row-derived paths | recursive prefix sweep (§3.4) |
| Razorpay | `subscriptions.provider_sub_id` | `rz.subscription.cancel` (`razorpay_routes.py:468`) |
| Lemon Squeezy (MoR) | `subscriptions.provider_sub_id` | ⚠️ **no cancel method on `MoRProvider`** (`src/integrations/mor/base.py`) — manual (R4) |

### 2.2 Mandatory pre-implementation introspection

Run this **before writing the purge**, in every environment, and paste the output into the PR. It converts every ⚠️ above into a fact:

```sql
-- Every FK pointing at workspaces / qr_codes / users, and its delete rule.
SELECT tc.table_name        AS child_table,
       kcu.column_name      AS child_column,
       ccu.table_name       AS parent_table,
       rc.delete_rule
  FROM information_schema.table_constraints tc
  JOIN information_schema.key_column_usage  kcu
    ON tc.constraint_name = kcu.constraint_name
  JOIN information_schema.constraint_column_usage ccu
    ON tc.constraint_name = ccu.constraint_name
  JOIN information_schema.referential_constraints rc
    ON tc.constraint_name = rc.constraint_name
 WHERE tc.constraint_type = 'FOREIGN KEY'
   AND tc.table_schema = 'public'
   AND ccu.table_name IN ('workspaces','qr_codes','users','profiles','qr_link_items','folders','custom_domains')
 ORDER BY ccu.table_name, tc.table_name;

-- Columns named workspace_id / qr_id / user_id that have NO foreign key at all
-- (these are the silent orphan producers the inventory must catch by hand).
SELECT c.table_name, c.column_name
  FROM information_schema.columns c
 WHERE c.table_schema = 'public'
   AND c.column_name IN ('workspace_id','qr_id','user_id','owner_id')
   AND NOT EXISTS (
        SELECT 1 FROM information_schema.key_column_usage k
          JOIN information_schema.table_constraints t
            ON t.constraint_name = k.constraint_name
         WHERE k.table_name = c.table_name
           AND k.column_name = c.column_name
           AND t.constraint_type = 'FOREIGN KEY')
 ORDER BY 1,2;
```

### 2.3 Design decision — **do not add new cascades in this migration**

The tempting fix is "`ALTER TABLE … ON DELETE CASCADE` everywhere, then `DELETE FROM workspaces`." **We recommend against it**, for three reasons:

1. **Correctness must not depend on FK behaviour we cannot see.** The base schema is not in this repo and is not exercised by CI (tests mock the Supabase client). A purge whose completeness rests on cascades no test can assert is a purge we cannot certify.
2. **A cascade would fire before the KV/storage teardown.** The entire ordering guarantee (§1) exists because the rows *are* the index into external state. Making `DELETE FROM workspaces` maximally destructive works directly against that.
3. **Blast radius.** Adding `ON DELETE CASCADE` to `workspaces` makes every future hand-run `DELETE` in the Supabase SQL editor a potential mass-deletion. That is a bad trade for a system whose migrations are applied by hand.

Instead: the purge **deletes every inventoried table explicitly, leaf-to-root**, counting rows as it goes (the counts become the audit record). Existing cascades are a harmless second line of defence — an explicit delete of an already-cascaded child is a no-op. Where introspection reveals a **missing FK entirely** (§2.2 query 2), that is a genuine schema bug: file it, fix it in a separate follow-up migration, and in the meantime the explicit delete covers it.

### 2.4 `qr_backend/migrations/0044_account_deletion_erasure.sql`

BEGIN/COMMIT-wrapped, idempotent (`IF NOT EXISTS`), applied by hand in the Supabase SQL editor per `migrations/README.md`. **Ships only this phase's schema** — one table, one RPC, no data rewrite, no `plans` touch.

**RLS note:** the backend uses the Supabase **service-role** client, which **bypasses RLS** (`src/database/supabase.py:28-38`). We `ENABLE ROW LEVEL SECURITY` with **no policies**, so the `anon`/`authenticated` roles can never read this table — critical here, because a readable `deletion_requests` would let any client enumerate which accounts are scheduled for deletion. Tenant/user isolation is enforced in code via explicit `user_id` filters, never RLS.

```sql
BEGIN;

-- ─────────────────────────────────────────────────────────────────────────────
-- Account deletion requests — soft-delete state machine + purge checkpoint.
--
-- Lifecycle:  pending ──(T+30, cron)──► purging ──► purged
--                │                          └────► dead_letter  (retries exhausted)
--                └──(user cancels)────────► cancelled
--
-- The row SURVIVES the purge as a PII-free audit record (§3.7): user_id and
-- contact_email are nulled at finalisation and only user_id_hash remains, so we
-- can evidence the 30-day SLA without retaining the identity we just erased.
-- ─────────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS deletion_requests (
    id              uuid        PRIMARY KEY DEFAULT gen_random_uuid(),

    -- Nulled at finalisation. NOT a FK to users/auth.users: the FK's own cascade
    -- would delete this audit row at step 7, which is exactly what we must keep.
    user_id         uuid,
    -- sha256(user_id || settings.HASHING_SALT) — survives the purge (see internal.py:1332
    -- for the same construction on ip_hash). The permanent, non-reversible audit key.
    user_id_hash    text        NOT NULL,
    -- Destination for the completion email. Captured at request time, nulled at
    -- finalisation immediately after the mail is handed to Resend.
    contact_email   text,

    status          text        NOT NULL DEFAULT 'pending'
                    CHECK (status IN ('pending','purging','purged','cancelled','dead_letter')),

    requested_at    timestamptz NOT NULL DEFAULT now(),
    purge_after     timestamptz NOT NULL,          -- requested_at + GRACE_PERIOD_DAYS
    purged_at       timestamptz,
    cancelled_at    timestamptz,

    -- ── Resumability ────────────────────────────────────────────────────────
    -- Highest completed step (0 = nothing done). The purge resumes at step+1, so
    -- a crash mid-run never repeats destructive work it already finished and never
    -- skips work it hasn't. Steps are defined in TRD §3.3.
    checkpoint_step smallint    NOT NULL DEFAULT 0,
    -- Enumerated BEFORE any row is deleted (step 1). THIS IS THE SHIP-BLOCKER FIX:
    -- once qr_codes rows are gone, short_code is unrecoverable and the KV keys
    -- serve a deleted user's content forever.
    --   {"short_codes":[...], "domains":[{"host":..,"cf_id":..,"verified":bool}],
    --    "workspace_ids":[...], "storage_paths":[...], "counts":{...}}
    enumeration     jsonb       NOT NULL DEFAULT '{}'::jsonb,
    -- Per-step outcome log, append-only: {"step_3":{"ok":47,"failed":0,"at":"..."}}
    step_results    jsonb       NOT NULL DEFAULT '{}'::jsonb,

    -- ── Claim lease + backoff (mirrors webhook_deliveries, webhook_dispatch.py:231) ──
    attempt_count   smallint    NOT NULL DEFAULT 0,
    next_attempt_at timestamptz,
    last_error      text,

    -- ── Case-C workspace resolutions, chosen by the user at request time (§3.2) ──
    --   [{"workspace_id":"…","action":"transfer","to_user_id":"…"},
    --    {"workspace_id":"…","action":"delete"}]
    resolutions     jsonb       NOT NULL DEFAULT '[]'::jsonb,

    -- Set when a Lemon Squeezy / MoR subscription needs manual cancellation
    -- because MoRProvider has no cancel method (TRD §6.2, PRD R4). BLOCKS finalisation.
    manual_billing_action boolean NOT NULL DEFAULT false,

    updated_at      timestamptz NOT NULL DEFAULT now()
);

-- At most ONE live request per user. Partial unique index so historical
-- purged/cancelled rows accumulate freely as the audit trail.
CREATE UNIQUE INDEX IF NOT EXISTS uq_deletion_requests_live_user
    ON deletion_requests (user_id)
    WHERE status IN ('pending','purging') AND user_id IS NOT NULL;

-- The sweep's hot predicate: due + claimable.
CREATE INDEX IF NOT EXISTS idx_deletion_requests_due
    ON deletion_requests (purge_after)
    WHERE status IN ('pending','purging');

-- Audit/SLA reporting.
CREATE INDEX IF NOT EXISTS idx_deletion_requests_hash
    ON deletion_requests (user_id_hash);

ALTER TABLE deletion_requests ENABLE ROW LEVEL SECURITY;
-- No policies → only the service role (which bypasses RLS) can read/write.
-- Deliberate: a readable table would leak which accounts are scheduled for deletion.

-- ─────────────────────────────────────────────────────────────────────────────
-- Claim lease — conditional UPDATE, the double-purge guard.
--
-- Mirrors webhook_dispatch._claim (src/utilities/webhook_dispatch.py:231): flips a
-- due row to 'purging' and pushes next_attempt_at a lease out, but ONLY if it is
-- still pending/purging AND due AND under MAX_ATTEMPTS. Returns the claimed row or
-- nothing. Two concurrent cron fires (or a retry overlapping a slow run) can never
-- both purge the same account.
--
-- p_limit is REQUIRED and has no unlimited value: webhook_dispatch.sweep()
-- (:516) selects due rows with NO LIMIT, and a purge batch is orders of magnitude
-- heavier than a webhook POST. We do not repeat that mistake.
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION claim_deletion_requests(
    p_lease_seconds integer,
    p_max_attempts  integer,
    p_limit         integer
)
RETURNS SETOF deletion_requests
LANGUAGE plpgsql
AS $$
BEGIN
    RETURN QUERY
    UPDATE deletion_requests d
       SET status          = 'purging',
           attempt_count   = d.attempt_count + 1,
           next_attempt_at = now() + make_interval(secs => p_lease_seconds),
           updated_at      = now()
     WHERE d.id IN (
             SELECT c.id
               FROM deletion_requests c
              WHERE c.status IN ('pending','purging')
                AND c.purge_after <= now()
                AND (c.next_attempt_at IS NULL OR c.next_attempt_at <= now())
                AND c.attempt_count < p_max_attempts
              ORDER BY c.purge_after
              -- SKIP LOCKED: a second worker takes the next row instead of blocking.
              FOR UPDATE SKIP LOCKED
              LIMIT p_limit)
    RETURNING d.*;
END;
$$;

-- ─────────────────────────────────────────────────────────────────────────────
-- Checkpoint advance — one atomic write per completed step, so a crash between
-- steps resumes at exactly the right place.
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION advance_deletion_checkpoint(
    p_id     uuid,
    p_step   smallint,
    p_result jsonb
)
RETURNS void
LANGUAGE plpgsql
AS $$
BEGIN
    UPDATE deletion_requests
       SET checkpoint_step = GREATEST(checkpoint_step, p_step),   -- never moves backwards
           step_results    = coalesce(step_results,'{}'::jsonb)
                             || jsonb_build_object('step_' || p_step::text, p_result),
           updated_at      = now()
     WHERE id = p_id;
END;
$$;

COMMIT;

-- Sanity (after COMMIT):
--   SELECT status, count(*) FROM deletion_requests GROUP BY 1;
--   SELECT * FROM claim_deletion_requests(900, 5, 0);   -- must return 0 rows, no error
```

**No `plans` change, no `plans.features` key, no `FEATURE_ENFORCEMENT` entry** — so `test_feature_gate_coverage` and `test_registry_matches_plan_seed` are untouched by this migration. That is deliberate (PRD §8) and worth stating in the PR description so a reviewer doesn't go looking for the missing seed.

---

## 3. Backend Design

### 3.1 `qr_backend/src/api/routes/security.py` — request/cancel/status routes

New routes appended to the existing `/security` router (already registered in `endpoints.py:48`, so it sits behind `BearerTokenAuthMiddleware` and is **not** in `main.py:62-70`'s excluded prefixes). They reuse the file's own `_require_user_id(request)` helper (`:21`) rather than `get_current_user_id`, matching every other route in this module.

```
GET    /api/v1/security/deletion/preflight   # read-only impact summary + blockers
POST   /api/v1/security/deletion             # schedule deletion (T+0 side-effects)
GET    /api/v1/security/deletion             # current request status (banner polls this)
DELETE /api/v1/security/deletion             # cancel during grace → restore
```

`GET /preflight` performs no writes. It resolves the user's workspaces in two directions — owned (`workspaces.owner_id == user_id`, the same predicate as `_owned_workspace_ids`, `subscription.py:242`) and member-of (`workspace_members.user_id == user_id`) — classifies each into case A/B/C (§3.2), and returns counts plus a `blockers[]` array. Counts use `select("id", count="exact")` head requests, never full row fetches (§9).

`POST` validates `confirm_email` against `request.state.user_email` (populated by the middleware at `auth_bearer.py:169`/`:188`) with a **constant-time compare**, **re-runs the classification server-side** (the client-side pre-flight is advisory — a stale or forged `resolutions[]` must not be able to delete a workspace the user doesn't solely own), and rejects with `409` if any case-C workspace lacks a resolution. Then it executes the T+0 sequence in §1's data-flow block. Each side-effect is individually try/except'd and logged: **the `deletion_requests` row is inserted first**, so a failure in step 4–8 leaves a recoverable, retryable request rather than a half-applied change with no record.

`DELETE` (cancel) is idempotent: it flips `pending` → `cancelled`, calls `resync_workspace_qrs(ws, db)` (`cloudflare_kv.py:262`) per owned workspace to un-pause every QR at the edge, and `invalidate_plan_cache`. Cancelling a request already in `purging` returns **`409`** — once the purge has claimed the row and started destroying external state, there is nothing coherent to restore.

**Guard on both mutating routes:** a user with a live request cannot create a second one (the partial unique index enforces it at the DB level too); a `POST` while `status='purging'` returns `409`.

### 3.2 Workspace classification (`security.py` helper, shared by preflight and POST)

```python
def _classify_workspaces(user_id: str, db) -> dict:
    """Split every workspace the user touches into the three PRD §6.4 cases.

    A: sole owner_id, no other workspace_members rows  → purge with the account
    B: not owner_id (viewer/editor/co-member)          → drop membership only
    C: sole owner_id WITH other members                → BLOCKED until resolved
    """
```

Owner is `workspaces.owner_id` (the same source `_owner_of_workspace` reads, `subscription.py:237`). "Other members" counts `workspace_members` rows with `user_id != requester`. Note the wrinkle already documented in `get_workspace_role` (`deps.py:42-44`): a workspace creator may have **no** `workspace_members` row at all, so membership must never be inferred from that table alone — `owner_id` is authoritative for ownership, `workspace_members` for collaborators.

**Case C resolution** is `{"action": "transfer", "to_user_id": …}` or `{"action": "delete"}`. `transfer` validates the target is a current member (403 otherwise), sets `workspaces.owner_id`, upserts a `workspace_members` row with `role='owner'`, and **calls `invalidate_plan_cache(ws, db)`** — without it the 30s `_PLAN_CACHE` (`subscription.py:207-208`) serves the departed owner's plan to the new owner.

**T+21 forced transfer** runs inside the same cron endpoint as the purge (a cheap pre-pass over `pending` requests where `now() >= purge_after - FORCE_TRANSFER_LEAD_DAYS`): pick the longest-tenured remaining `owner`, else `editor`, else mark the workspace for deletion; email the new owner. This is what keeps a permanently-blocked case C from breaching the statutory deadline (PRD §6.4).

### 3.3 `qr_backend/src/utilities/account_purge.py` (NEW) — the purge engine

A pure module (no FastAPI imports beyond exceptions), so the ordering logic is unit-testable against a mocked Supabase client — matching how `webhook_dispatch.py` is structured and tested (`tests/unit_tests/test_webhook_dispatch.py`).

```python
GRACE_PERIOD_DAYS      = 30       # PRD Open Q1 — must match privacy/page.tsx:192
FORCE_TRANSFER_LEAD_DAYS = 9      # T+21 for a 30-day grace
BACKOFF_SCHEDULE_SECONDS = [0, 300, 3600, 21600]   # cf. webhook_dispatch.py:57
MAX_ATTEMPTS           = 5        # cf. webhook_dispatch.py:58
LEASE_SECONDS          = 900      # a purge run is long; lease generously
PURGE_BATCH_SIZE       = 5        # requests per cron tick — BOUNDED (see below)
ROW_DELETE_CHUNK       = 500      # ids per delete call (cf. bulk_delete cap of 100, qr.py:3348)
RUN_TIME_BUDGET_SECONDS = 240     # stop cleanly and resume next tick
```

> **Bounded on purpose.** `webhook_dispatch.sweep()` (`:516`) selects every due delivery with **no `LIMIT`**. That is tolerable for 10 KB POSTs and intolerable here: one account purge can touch hundreds of thousands of `qr_scan_events` rows plus N Cloudflare API round-trips. `PURGE_BATCH_SIZE` bounds requests per tick, `ROW_DELETE_CHUNK` bounds each statement, and `RUN_TIME_BUDGET_SECONDS` makes the run self-terminating — a partially-processed batch simply resumes on the next tick, which is safe precisely because every step is checkpointed.

**The eight steps.** `purge_account(request_row, db)` dispatches on `checkpoint_step` and runs forward from there. Each step ends with `advance_deletion_checkpoint(id, n, result)`.

**Step 1 — enumerate (the ship-blocker step).** *Must complete before any destructive step.* Reads and persists into `enumeration`:
- every `short_code` from `qr_codes` across all to-be-purged workspaces,
- every `custom_domains` row's `domain`, `cf_custom_hostname_id`, `status`,
- every `qr_files.file_path` plus `metadata.thumbnail_paths`, and `workspace_branding.logo_url`,
- the workspace id list, the user's email, and per-table row counts (the audit record).

Because this lands on the request row **before** step 5, a crash at any later point still leaves a complete, replayable teardown list. If step 1 itself fails, nothing has been destroyed and a retry is free.

**Step 2 — Cloudflare for SaaS.** `delete_custom_hostname(cf_id)` (`cloudflare_saas.py:123`) per enumerated domain. A 404 from Cloudflare is success (already gone). Follows the loop shape of `_revoke_custom_domains_for_workspace` (`razorpay_routes.py:1071-1116`) — read that function first; it is the closest working precedent.

**Step 3 — Cloudflare KV (+ post-verify).** `delete_from_kv(sc)` (`cloudflare_kv.py:519`) per short code; `delete_domain_from_kv(host)` (`:508`) per **verified** domain (matching the `status == "verified"` guard at `custom_domain.py:479`). Both raise `RuntimeError` on non-2xx. **Unlike the per-QR routes — which swallow this exception because the DB delete has already committed (`qr.py:3431`, `:3387`) — the purge must NOT swallow it.** Failures accumulate into a retry list; the step is re-run with backoff; if it exhausts `MAX_ATTEMPTS` the request goes to `dead_letter` and **step 5 never runs**. Then a **post-verify** pass re-reads each key and records the result — this is the evidence behind the PRD's "zero orphaned KV keys" gate.

**Step 4 — Supabase Storage.** Delegated to `storage_purge.py` (§3.4).

**Step 5 — Postgres, leaf → root.** Explicit deletes in dependency order per the §2 inventory: `qr_*_details` and per-QR children → `qr_link_click_events` → `qr_link_items` → `qr_link_pages` → `qr_files` → `qr_designs` → `qr_destinations` → `qr_scan_events` (chunked) → `qr_scan_counters` → `qr_codes` → workspace-scoped tables → `custom_domains` → `api_tokens` → `folders` → `workspace_members` → `workspace_invitations` → `workspaces`. Every statement is `.eq("workspace_id", ws)` or `.in_("qr_id", chunk)` — **never an unscoped delete**, because the service-role client bypasses RLS and a missing filter is a whole-table wipe. Row counts are folded into `step_results`.

Case-B workspaces are **not** touched here beyond deleting the requester's own `workspace_members` and `workspace_invitations` rows.

**Step 6 — billing pseudonymisation (§3.6).**

**Step 7 — Supabase Auth.** `db.auth.admin.delete_user(user_id)`. A "user not found" is success. This is deliberately last: while the auth user exists, the request row still points at a real identity we can use to resume.

**Step 8 — finalise.** Send the completion email to the address captured in step 1, then null `user_id` and `contact_email`, set `status='purged'`, `purged_at=now()`. The row survives with `user_id_hash`, timestamps, and counts (§3.7).

**Idempotency contract, per step:** KV/CF/storage deletes treat "already gone" as success; row deletes are naturally idempotent; the auth delete tolerates 404; the email is guarded by `checkpoint_step < 8` so a resumed run cannot double-send. A re-run of a `purged` request short-circuits immediately.

### 3.4 `qr_backend/src/utilities/storage_purge.py` (NEW) — the storage sweep

Two independent passes plus a row-derived pass, because no single prefix covers the five path shapes (see the header correction, §Rev):

```python
def purge_storage_for_account(workspace_ids: list[str], user_id: str,
                              known_paths: list[str], db) -> dict:
    """Remove every Supabase Storage object belonging to this account.

    Pass 1 (workspace prefixes) — for each workspace: recursively sweep "{ws}/".
      Covers {ws}/temp/{uuid}/{name}          storage.py:237
              {ws}/{qr_id}/{file_name}        qr.py:1706,1737,1803,1858
              {ws}/{qr_id}/logo.{ext}         qr.py:2357
              {ws}/branding/logo-*.{ext}      branding.py:164

    Pass 2 (user prefixes) — sweep "avatars/{user_id}/" and legacy "{user_id}/".
      Covers avatars/{user_id}/avatar.{ext}   storage.py:143
              {user_id}/…  legacy uploads      storage.py:497, :552-554

    Pass 3 (row-derived) — remove `known_paths`, gathered at step 1 from
      qr_files.file_path, qr_files.metadata.thumbnail_paths and
      workspace_branding.logo_url. Belt and braces: catches any path shape a
      future writer introduces that neither prefix pass anticipates.
    """
```

Two implementation details that will bite otherwise:
- **`bucket.list(path=…)` is non-recursive and paginated.** The existing caller (`storage.py:497`) lists a single flat level. Our paths nest two-to-three deep (`{ws}/{qr_id}/{file}`), so the sweep must recurse into every returned "folder" entry and page through with explicit `limit`/`offset` — a single `list()` call silently returns only the first page and would leave most objects behind.
- **`bucket.remove([paths])` takes a batch**; chunk it (the existing rollback calls at `storage.py:221`/`:248` pass small lists). Deletes are idempotent — removing a path twice is not an error.

Returns `{"deleted": n, "failed": [...], "passes": {...}}`. Failures are retried with the step; a persistent failure sends the request to `dead_letter`.

### 3.5 `qr_backend/src/api/routes/internal.py` — `POST /internal/deletion-purge`

Registered on the existing internal router, which already carries `dependencies=[Depends(verify_internal_secret)]` at `:34`, so the `x-internal-secret` check (`:21-24`) is automatic and the whole `/internal/` prefix is Bearer-exempt via `main.py:70`. No body. Idempotent: a duplicate cron fire finds nothing claimable because the lease has already moved `next_attempt_at`.

```python
@router.post("/deletion-purge", summary="Cron: force overdue transfers, then purge due accounts")
async def deletion_purge(db: Client = Depends(get_supabase)) -> dict:
    forced  = await account_purge.force_overdue_transfers(db)   # T+21 pre-pass
    claimed = db.rpc("claim_deletion_requests",
                     {"p_lease_seconds": LEASE_SECONDS,
                      "p_max_attempts":  MAX_ATTEMPTS,
                      "p_limit":         PURGE_BATCH_SIZE}).execute().data or []
    results = []
    deadline = time.monotonic() + RUN_TIME_BUDGET_SECONDS
    for row in claimed:
        if time.monotonic() > deadline:
            break                       # lease expires; next tick resumes from checkpoint
        try:
            results.append(await account_purge.purge_account(row, db))
        except Exception:               # noqa: BLE001 — one bad account must not abort the batch
            logger.error("deletion-purge failed for request %s", row["id"], exc_info=True)
            await account_purge.record_failure(row, db)   # backoff or dead_letter
    return {"forced_transfers": forced, "claimed": len(claimed), "results": results}
```

**Sibling-cron warning (pre-existing bug, referenced not fixed):** the same `0 6 * * *` branch already pings `/internal/reclamation-sweep` (`qr_cf_code/src/index.js:77`). Verified: **no such route exists** in `qr_backend` — `grep -rn "reclamation" qr_backend/` returns nothing, and the internal router's paths are `/ai-digest-run`, `/free-scan-reset`, `/run-alerts`, `/run-reports`, `/webhook-sweep`, `/scans`, `/lead-submit`, `/link-click/*`, `/signed-url/*`, `/refresh-kv/*`, the per-type content endpoints, and the two password-verify routes. That cron **404s daily**. Do not "fix" it while adding `deletion-purge`, and do not mistake its error line in the Worker logs for a regression from this work.

### 3.6 Billing pseudonymisation — `subscriptions` is never deleted

GDPR Art. 17(3)(b) permits retention where processing is necessary for compliance with a legal obligation; Indian tax/accounting rules require it; and `privacy/page.tsx:204-205` already promises 7 years. So:

```python
db.table("subscriptions").update({
    "user_id":               None,                    # if such a column exists
    "customer_email":        None,
    "customer_name":         None,
    "provider_customer_id":  None,                    # provider-side PII pointer
    "erased_user_hash":      _hash_user(user_id),     # sha256(uid + HASHING_SALT)
    "erased_at":             _now_iso(),
}).eq("workspace_id", ws).execute()
```

Retained: amount, currency, plan, provider, `provider_sub_id`, period dates, status. Discarded: everything that identifies a person. `_hash_user` uses `settings.HASHING_SALT` (`src/config/settings/base.py:131`), the same construction as `ip_hash` at `internal.py:1332`.

⚠️ **The exact column list must be confirmed against the live `subscriptions` schema** (§2.2) — the table is base schema and its columns are not in this repo. Whatever the real PII columns are, they get nulled; the financial columns stay. Add the two new columns (`erased_user_hash`, `erased_at`) to `0044` once introspection confirms the rest.

The workspaces are deleted at step 5 while `subscriptions` rows survive — so **`subscriptions.workspace_id` must not be `ON DELETE CASCADE`**. If introspection says it is, step 6 must run *before* step 5 and null the FK, or the retention requirement is silently defeated by the cascade. **Check this specifically.**

### 3.7 Audit record

After step 8 the row carries no personal data: `user_id` and `contact_email` are null; `user_id_hash`, `requested_at`, `purged_at`, `step_results` (counts only), and `status` remain. SLA evidence is one query:

```sql
SELECT count(*) FILTER (WHERE purged_at <= requested_at + interval '31 days') AS on_time,
       count(*) AS total
  FROM deletion_requests WHERE status = 'purged';
```

### 3.8 What we deliberately do **not** touch

No `FEATURE_ENFORCEMENT` entry, no `_QUOTA_SPEC` entry, no `build_entitlements` change (`cloudflare_kv.py:135`), no `build_kv_content` branch (`:387`), no new `/internal/{type}/{qr_id}` endpoint, no `PlanFeatures` field. The T+0 pause writes `status` through the **existing** `sync_qr_to_kv` path, so the KV value shape is unchanged.

---

## 4. Cloudflare Worker / Edge Design

**One line of Worker code changes, and no edge behaviour changes at all.**

**The change.** In `scheduled()` (`qr_cf_code/src/index.js:44-81`), the `event.cron === "0 6 * * *"` branch (`:73-77`) gains one dispatch alongside the existing three:

```javascript
} else if (event.cron === "0 6 * * *") {
  ctx.waitUntil(ping("/internal/run-reports", "run-reports:daily", { frequency: "daily" }));
  ctx.waitUntil(ping("/internal/run-alerts", "run-alerts"));
  ctx.waitUntil(ping("/internal/reclamation-sweep", "reclamation-sweep"));   // ⚠️ pre-existing 404 — untouched
  ctx.waitUntil(ping("/internal/deletion-purge", "deletion-purge"));         // ← NEW
}
```

**No new cron trigger.** `wrangler.toml`'s `[env.production.triggers] crons = ["0 0 1 * *", "0 6 * * 1", "0 6 * * *", "*/5 * * * *"]` is unchanged. Daily at 06:00 UTC is the right cadence: the grace period is measured in days, so hourly granularity buys nothing and daily bounds the worst-case overshoot at <24h inside a 30-day window.

**No fetch-path change.** The T+0 pause deliberately reuses a status the Worker already understands: `sync_qr_to_kv` writes `status: "paused"`, and `src/index.js:368` already returns `getPausedPage({ whiteLabel, brand })` for it (alongside `disabled` → `getScanLimitPage` at `:372` and `locked` → `getPlanLimitPage` at `:378`). **We deliberately do not add a `"deleting"` status** — it would require a Worker deploy to be *ordered before* the backend deploy, and a stale Worker would fall through to rendering the QR normally, i.e. it would keep serving a deleted user's content. Reusing `paused` is correct, honest to the scanner ("this QR is not active"), and fail-safe: an old Worker still pauses.

**No KV shape change, no new KV key namespace, no new page, no new template.** The template-mirroring house rule does not apply (nothing to mirror). `recordScan` (`src/utils/scan.js`), the consent gate, custom-domain isolation, and the password gate are all byte-for-byte unchanged.

**After the purge**, a scanned short code simply misses in KV and the Worker's existing not-found path renders `getErrorPage()` — which is the correct terminal state for a QR whose owner no longer exists.

**Deploy note:** the one-line dispatch requires `npm run deploy:prod`. It is safe to deploy **before** the backend route exists — an unknown `/internal/*` path returns 404 and `ping()` (`src/index.js:55-64`) already logs and swallows it, exactly as it has been doing for `reclamation-sweep`.

---

## 5. Frontend Design

House rules apply throughout: shadcn primitives only, no raw `<button>`, no inline `style={{}}`, no `any`, ≤200 lines per file, one export per file, kebab-case filenames, TanStack Query for server state (never `useEffect + fetch`), `authApi` from `src/lib/api-client.ts`, `workspaceId` from `useWorkspaceStore` rather than URL params.

### 5.1 `src/components/org/settings/AccountSection.tsx` (edit)

The file is 120 lines and keeps its Usage-stats grid (`:27-71`) and Data Export card (`:73-96`) untouched. The red "Delete Account" block (`:98-117`) — currently a `mailto:support@qravio.app` paragraph — is replaced by `<DeleteAccountCard />`, extracted so the file stays well inside the 200-line ceiling and keeps one export.

### 5.2 `src/components/org/settings/delete-account-card.tsx` (NEW)

Preserves the existing destructive visual language (`bg-red-50`, `border-red-100`, the `w-1 h-6 bg-red-400` rule) so the panel doesn't shift. Renders either:
- **No live request** — copy naming what is destroyed and what is retained, a link to Data Export ("download your data first"), and a destructive `Button` opening the dialog.
- **Live request** — an inline scheduled-state panel with the purge date and a **Cancel deletion** button.

### 5.3 `src/components/org/settings/delete-account-dialog.tsx` (NEW)

shadcn `AlertDialog`. On open, fires the pre-flight query and renders the impact summary (PRD §6.2). Case-C workspaces render an inline resolution control per workspace — a `Select` of members for **transfer**, or a **delete workspace** radio that reveals a second confirmation naming the member count. The submit button is disabled until every blocker is resolved **and** the typed email matches (compared client-side for UX; the server re-validates, and the server is authoritative). react-hook-form + zod, per house rules.

### 5.4 `src/hooks/useAccountDeletion.ts` (NEW)

```ts
export const deletionKeys = {
  all: ['account-deletion'] as const,
  status: () => [...deletionKeys.all, 'status'] as const,
  preflight: () => [...deletionKeys.all, 'preflight'] as const,
};

export function useDeletionStatus()   // GET  /security/deletion   — polled by the banner
export function useDeletionPreflight(enabled: boolean)  // GET /security/deletion/preflight
export function useRequestDeletion()  // POST   → invalidate status; then signOut()
export function useCancelDeletion()   // DELETE → invalidate status + qrKeys.all
```

`useDeletionPreflight` is `enabled`-gated on dialog open so it never runs on page load. `useRequestDeletion.onSuccess` invalidates status, shows a toast, and signs the user out (their sessions were revoked server-side anyway). `useCancelDeletion.onSuccess` invalidates `qrKeys.all` (`src/hooks/useQRs.ts`) because every QR's status just changed back to active.

### 5.5 Scheduled-deletion banner — `src/app/[slug]/(dash)/layout.tsx` (edit)

A dismissible-per-session `Alert` above the page content whenever `useDeletionStatus()` returns `pending`: *"Your account is scheduled for deletion on 26 August 2026."* + **Cancel deletion**. `staleTime: 60_000`; no polling storm.

### 5.6 Restore interstitial — `src/app/(auth)/` (NEW route)

`src/middleware.ts` already validates the Supabase session on every request and redirects unauthenticated users to `/login`. A user in grace has a *valid* session (they re-authenticated) but a `pending` request; the dashboard shell redirects them to `/account-scheduled-for-deletion`, which offers **Restore account** or **Continue with deletion (sign out)**. Keeping this in the `(auth)` group means no sidebar and no workspace context — correct, because their workspaces are paused.

### 5.7 `src/app/(marketing)/privacy/page.tsx` (edit — **ship-blocker documentation change**)

`:191-193` currently reads *"retained while your account is active and for **90 days** after account deletion to allow recovery."* The implemented grace is **30 days** (PRD Open Q1). **The published policy and the code must agree** — a mismatch is worse than either number alone, and this is the defect that makes the whole area a liability. Amend to 30 days in the same PR. While in the file: `:200-201` ("files deleted within 30 days") now becomes true; consider adding one sentence about encrypted backups (PRD R6), which the policy currently doesn't mention at all.

---

## 6. External-Service Integration

### 6.1 Cloudflare (KV + Cloudflare for SaaS)

Reused verbatim: `delete_from_kv` (`cloudflare_kv.py:519`), `delete_domain_from_kv` (`:508`), `delete_custom_hostname` (`cloudflare_saas.py:123`). All are synchronous `httpx` calls raising `RuntimeError` on non-2xx; the purge wraps them in `run_in_threadpool` in the async path, exactly as `custom_domain.py:480` does.

**Token permissions are a Phase-0 gate.** `CF_API_TOKEN` needs **Workers KV Storage:Edit** *and* **SSL and Certificates:Edit** (for custom hostnames) in every environment. A token that can write but not delete produces precisely the silent-orphan failure this spec exists to prevent — and it will look like success until someone scans a deleted user's QR. Verify with a throwaway key/hostname before Phase 0 exits.

**KV namespace parity matters.** `wrangler.toml` documents that the backend's `CF_KV_NAMESPACE_ID` must equal the prod worker's KV id. If they diverge, the purge deletes from one namespace while the Worker reads another and every key is orphaned. Assert the ids match as part of the Phase-0 checklist.

### 6.2 Billing providers

**Razorpay — supported.** `cancel_razorpay_subscription` (`razorpay_routes.py:415-420`) already calls `rz.subscription.cancel(provider_sub_id, {"cancel_at_cycle_end": 0})` (`:468`) and sets the local status to `canceled` regardless of the webhook. The purge calls the same client with `cancel_at_cycle_end=False` — deletion means *now*, not end-of-cycle. The route already treats "already cancelled" as success (`:473`); reuse that tolerance.

**Lemon Squeezy / MoR — NOT supported (verified gap).** `MoRProvider` (`src/integrations/mor/base.py`) declares exactly four methods: `variant_id_for` (`:53`), `create_checkout` (`:60`), `verify_signature` (`:76`), `parse_event` (`:80`). **There is no cancel.** `mor_routes.py` exposes only `/mor/checkout` (`:83`) and `/mor/webhooks` (`:191`). A USD subscriber's billing therefore cannot be stopped by our code.

**v1 handling (honest, not clever):** set the local `subscriptions.status = 'canceled'`, set `deletion_requests.manual_billing_action = true`, log at ERROR, and alert. **`manual_billing_action` blocks step 8** — the request cannot reach `purged` until an operator confirms provider-side cancellation and clears the flag. Ugly, visible, and correct: the alternative is silently continuing to charge someone who asked to be erased.

**Recommended follow-up (separate, small PR — not bundled here):** add `cancel_subscription(provider_sub_id) -> bool` to `MoRProvider` and implement it in `lemon_squeezy.py`. It removes a manual step from a legally-timed process and is worth doing before this spec's GA if there is any USD subscriber at all.

### 6.3 Supabase Auth Admin

`db.auth.admin.delete_user(user_id)` on the service-role client (`src/database/supabase.py:28`), plus a sign-out/refresh-token revoke at T+0. Confirm the service-role key permits Auth Admin operations per environment — this is a separate capability from PostgREST access and can be missing without any other symptom.

### 6.4 Resend (email)

Four new templates in `src/utilities/email.py`, following the existing `send_*` shape (`:12`, `:98`, `:155`, `:234`, `:295`, `:368`, `:412`) — each guards on `settings.RESEND_API_KEY` and logs-and-returns when unset:

| Template | Trigger | Notes |
|---|---|---|
| `send_deletion_scheduled_email` | T+0 | Purge date + one-click cancel link (signed token, short TTL) |
| `send_workspace_owner_leaving_email` | T+0, case C | To each collaborator: what happens, when, who inherits |
| `send_workspace_transferred_email` | transfer (chosen or forced) | **Must state the plan consequence** — the workspace re-resolves to the *new* owner's plan (PRD R5) |
| `send_deletion_complete_email` | step 8 | Last message ever sent; names what was destroyed and what was retained |

⚠️ **`_dmarc.qravio.app` is unpublished — this is a real GA gate for this feature** (unlike the card-OCR spec, which sends nothing). A deletion confirmation in spam is both a support incident and a compliance risk, because the cancel link is the user's only recovery path.

**No AI. No PDF/WeasyPrint. No new external service. No new env var or secret** — `CF_API_TOKEN`, `INTERNAL_SECRET`, `RESEND_API_KEY`, `HASHING_SALT`, and the Supabase keys all already exist.

---

## 7. API Contracts

**GET** `/api/v1/security/deletion/preflight`

```jsonc
{
  "can_proceed": false,
  "workspaces_owned_sole": [
    { "id": "…", "name": "Acme Events", "qr_count": 12, "member_count": 0 }
  ],
  "workspaces_owned_shared": [
    { "id": "…", "name": "Acme Marketing", "qr_count": 35, "member_count": 4,
      "members": [ { "user_id": "…", "email": "d***@acme.com", "role": "editor" } ] }
  ],
  "workspaces_member_only": [ { "id": "…", "name": "Client Co", "role": "editor" } ],
  "totals": { "qr_codes": 47, "scan_events": 12480, "files": 3, "custom_domains": 1 },
  "active_subscriptions": [
    { "workspace_id": "…", "plan": "Pro", "provider": "razorpay", "amount": "₹999/mo",
      "auto_cancellable": true }
  ],
  "retained": { "billing_records_years": 7, "basis": "Indian tax law / GDPR Art. 17(3)(b)" },
  "grace_period_days": 30,
  "blockers": [
    { "code": "workspace_has_members", "workspace_id": "…", "member_count": 4,
      "resolutions": ["transfer", "delete"] }
  ]
}
```

**POST** `/api/v1/security/deletion`

```jsonc
// request
{ "confirm_email": "arjun@acme.com",
  "resolutions": [ { "workspace_id": "…", "action": "transfer", "to_user_id": "…" } ] }

// 202 Accepted
{ "status": "pending", "requested_at": "2026-07-27T09:14:02Z",
  "purge_after": "2026-08-26T09:14:02Z",
  "subscriptions_cancelled": 1, "qrs_paused": 47,
  "manual_billing_action": false }

// 400 — confirmation mismatch
{ "detail": { "code": "confirm_email_mismatch" } }

// 409 — unresolved shared workspace (server-side re-check; the client pre-flight is advisory)
{ "detail": { "code": "workspace_has_members", "workspace_ids": ["…"] } }

// 409 — a request already exists
{ "detail": { "code": "deletion_already_requested", "purge_after": "2026-08-26T09:14:02Z" } }
```

**GET** `/api/v1/security/deletion` → `{ "status": "pending"|"purging"|null, "requested_at": …, "purge_after": … }` (`null` when no live request; the banner and interstitial both read this).

**DELETE** `/api/v1/security/deletion`

```jsonc
// 200 — restored
{ "status": "cancelled", "qrs_restored": 47 }

// 404 — nothing to cancel
{ "detail": { "code": "no_deletion_request" } }

// 409 — purge already started; nothing coherent to restore
{ "detail": { "code": "deletion_in_progress" } }
```

**POST** `/api/v1/internal/deletion-purge` — no body, `x-internal-secret` required (enforced by the router dependency at `internal.py:34`).

```jsonc
{ "forced_transfers": 1, "claimed": 2,
  "results": [
    { "request_id": "…", "status": "purged", "checkpoint_step": 8,
      "counts": { "qr_codes": 47, "kv_keys": 47, "storage_objects": 9,
                  "scan_events": 12480, "workspaces": 2 } },
    { "request_id": "…", "status": "purging", "checkpoint_step": 4,
      "note": "run time budget reached; resumes next tick" }
  ] }
```

---

## 8. Security, Privacy & Abuse

- **Auth.** All `/security/deletion*` routes sit under `/api/v1` behind `BearerTokenAuthMiddleware` (not in `main.py:62-70`'s excluded prefixes) and read the user from `request.state` via `_require_user_id` (`security.py:21`). `/internal/deletion-purge` is Bearer-exempt by prefix (`main.py:70`) and guarded by `verify_internal_secret` (`internal.py:21-24`).
- **Authorisation.** A user can only ever delete **their own** account — `user_id` comes from the validated JWT, never from the request body. Workspace-destroying actions additionally require `workspaces.owner_id == user_id`, re-checked server-side at POST regardless of what the client sent.
- **Confirmation strength.** Typed **account email** (not a generic "DELETE"), constant-time compared. **Recommended for GA (PRD Open Q2):** require a fresh re-authentication (Supabase `reauthenticate()` or a recent-`auth_time` check) — a stolen session should not be able to schedule an irreversible deletion.
- **Session revocation at T+0** means an attacker who scheduled the deletion also loses the session, while the legitimate user gets an email with a one-click cancel. The attack is therefore loud and reversible for 30 days.
- **Abuse / DoS.** The purge is expensive by nature. The partial unique index caps it at one live request per user; `PURGE_BATCH_SIZE` and `RUN_TIME_BUDGET_SECONDS` bound work per tick; request/cancel cycling costs a KV resync, so **rate-limit `POST`/`DELETE` to a few per hour per user**.
- **Tenant isolation.** Every purge statement carries an explicit `workspace_id`/`qr_id`/`user_id` filter. The service-role client **bypasses RLS** (`src/database/supabase.py:28-38`), so a missing filter is not a 403 — it is a whole-table delete. This is the single most dangerous class of bug in the file and every delete must be reviewed for it.
- **RLS on `deletion_requests`:** enabled with **no policies** (§2.4). A readable table would let any authenticated client enumerate accounts scheduled for deletion — a genuine information leak, not just tidiness.
- **PII in the audit trail:** post-purge the row holds only `user_id_hash` (salted, one-way, `HASHING_SALT`), timestamps, and counts. **Never** log a raw email or user id in `step_results` or `last_error` — sanitise before writing, because `last_error` is the easiest place for a stack trace to smuggle PII into a row designed to outlive the user.
- **The cancel link** in the T+0 email is a signed, single-use, short-TTL token — never a bare `user_id` in a query string.
- **Third-party PII.** Lead submissions, and (when they land) loyalty members and reminder contacts, are end-customer data for which the merchant is controller and we are processor. When the controller's account ends, so does our basis for holding it: destroyed with the workspace (PRD Open Q3). The deletion screen tells the merchant to export first.
- **No SSRF surface.** Outbound calls go only to Cloudflare, Supabase, Razorpay, and Resend, all with our own credentials. No user-supplied URL is fetched.
- **Consent gate / scan path:** unchanged.

---

## 9. Performance, Scale & Cost

- **`GET /preflight`** must not be expensive — it runs on dialog open. Counts use `select("id", count="exact")` head requests, never row fetches. `qr_scan_events` is the only worrying count; if it is slow at scale, return an approximate count or drop it from the summary rather than blocking the dialog.
- **`POST /security/deletion` (T+0)** is the one user-facing latency risk: it re-syncs **every** QR to KV, one `httpx.put` each (`sync_qr_to_kv` → `write_to_kv`, `cloudflare_kv.py:307`/`:52`), and `resync_workspace_qrs` (`:262`) is a serial loop. For an account with 500 QRs that is 500 sequential round-trips — far too slow for a request. **Do the pause in a `BackgroundTasks` job** (the pattern `branding.py:137`/`:180` and `mor_routes.py:56` already use for exactly this call) and return `202` immediately. The DB status flip is synchronous and fast; the edge catches up within seconds. Target: **< 5s** to the response.
- **Purge cost is dominated by two things:** `qr_scan_events` row volume (a busy workspace can hold hundreds of thousands of rows — delete in `ROW_DELETE_CHUNK` batches, never one unbounded statement) and N sequential Cloudflare API calls for KV. Both are bounded per tick by `PURGE_BATCH_SIZE` and `RUN_TIME_BUDGET_SECONDS`, and both resume cleanly.
- **Explicitly bounded, unlike the precedent.** `webhook_dispatch.sweep()` (`:516`) has no `LIMIT`. At webhook scale that is survivable; at purge scale it is an outage. Every query in this feature that could return an unbounded set carries a limit.
- **Cron cadence:** daily (`0 6 * * *`), on the existing trigger. No new Cloudflare cron, no extra Workers cost.
- **DB load:** one claim RPC + one checkpoint UPDATE per step per request. Negligible relative to the deletes themselves.
- **Cost:** no AI, no new paid service. Marginal Cloudflare API calls and Resend sends. **Net effect on revenue is negative** (cancelled subscriptions) — accepted, and stated in PRD §8.
- **Storage sweep:** paginated `list()` calls are the slow part for accounts with many files; it is checkpointed like everything else, so a large account simply takes more than one tick.

---

## 10. Testing Strategy

**Backend (pytest, `qr_backend/tests/unit_tests/`)** — Supabase and Cloudflare clients mocked throughout, following `test_webhook_dispatch.py` and `test_bulk_delete_qr.py` (which already monkeypatches `delete_from_kv`, `:58`/`:97`).

- **`test_deletion_kv_teardown_ordering`** — *the ship-blocker test.* Assert `enumeration.short_codes` is fully populated **before** any `qr_codes` delete is issued; assert a KV-delete failure leaves the rows **intact** and the request in `dead_letter` (never `purged`); assert one `delete_from_kv` call per short code and one `delete_domain_from_kv` per verified domain.
- **`test_deletion_cascade_completeness`** — seed a workspace touching **every** table in the §2 inventory; after purge, assert 0 rows in each. **This test is the executable form of the inventory** and must be updated by any PR that adds a user- or workspace-scoped table.
- **`test_deletion_idempotent_and_resumable`** — kill the purge after each of steps 1–7 in turn; re-run; assert it completes exactly once and never repeats a destructive call (assert call counts on the mocked KV/storage/auth clients). Re-running a `purged` request is a no-op.
- **`test_deletion_ownership_cases`** — case A purges the workspace; case B deletes only the membership and leaves the workspace fully functional; case C returns `409` without a resolution and succeeds with one; a `transfer` to a non-member is rejected `403`.
- **`test_deletion_forced_transfer`** — at T+21 an unresolved case C transfers to the longest-tenured owner, else editor, else marks for deletion; `invalidate_plan_cache` is called; the notification email fires.
- **`test_deletion_billing`** — Razorpay cancel invoked with `cancel_at_cycle_end=0`; a MoR subscription sets `manual_billing_action=true` and **blocks step 8**; `subscriptions` rows survive with PII nulled and `erased_user_hash` set; no charge path reachable after `requested_at`.
- **`test_deletion_storage_sweep`** — all five path shapes are removed; the sweep **recurses** into `{ws}/{qr_id}/` (a non-recursive `list()` must fail this test); pagination is exercised past one page; `known_paths` catches a path shape neither prefix pass covers.
- **`test_deletion_grace_and_cancel`** — cancel before purge restores QR status and calls `resync_workspace_qrs`; cancel during `purging` returns `409`; cancel after `purged` returns `404`.
- **`test_deletion_claim_lease`** — two concurrent `claim_deletion_requests` calls never return the same row; `attempt_count` increments; `MAX_ATTEMPTS` exhaustion → `dead_letter`; the claim is bounded by `p_limit`.
- **`test_deletion_auth`** — no Bearer → 401; a user cannot target another `user_id`; `/internal/deletion-purge` without `x-internal-secret` → 401/403.
- **`test_deletion_audit_row`** — post-purge the row has null `user_id`/`contact_email`, a non-null `user_id_hash`, and no PII anywhere in `step_results`/`last_error`.
- **`test_feature_gate_coverage` must stay green unchanged** — this feature adds no flag, so any diff there means something was added that shouldn't have been.

**Frontend (Vitest + Playwright)** — dialog renders the pre-flight summary and blockers; the submit button stays disabled until email matches and blockers are resolved; case-C resolution controls appear only for shared workspaces; the banner shows on `pending` and disappears on cancel; the restore interstitial replaces the dashboard during grace. **Note the ~29 pre-existing FE test failures baseline** — only net-new failures in the deletion/settings files are regressions.

**Worker:** no unit test — the change is one `ping()` line in `scheduled()`. Verified manually via `wrangler dev` + a scheduled trigger, asserting the backend receives the call with the right `x-internal-secret`.

**Manual staging rehearsal (Phase 0 exit gate, non-negotiable):** a purpose-built account with 2 workspaces, 6 members, files of every type, a verified custom domain, an active Razorpay subscription, and >10k scan events. Purge it. Then verify by hand: every short code 404s at the edge; the custom hostname is gone from the Cloudflare dashboard; the storage prefixes are empty; every inventoried table returns 0; `subscriptions` survives pseudonymised; the auth user is gone. **Then run the purge again and confirm a clean no-op.**

---

## 11. Observability & Rollout

**Phase 0 — schema + engine, no UI.** Apply `0044` (**re-verify the slot first**). Run the §2.2 introspection in every environment and paste results into the PR. Build `account_purge.py`, `storage_purge.py`, `/internal/deletion-purge`, and the Worker one-liner. Verify `CF_API_TOKEN` delete permissions (KV **and** SSL/Certificates), KV namespace parity, and Supabase Auth Admin capability. Run the staging rehearsal above.
*Exit gate:* rehearsal purge clean, twice (second = no-op), plus one deliberate mid-purge kill that resumes to completion.

**Phase 1 — API + UI behind `NEXT_PUBLIC_ACCOUNT_DELETION_BETA`.** Internal accounts only, with `GRACE_PERIOD_DAYS`/`FORCE_TRANSFER_LEAD_DAYS` shortened in staging so T+21/T+30 are reachable in a test run. Exercise all three ownership cases, the forced transfer, and a restore at mid-grace.
*Acceptance:* case A purges; case B leaves the client workspace working; case C blocks then resolves; forced transfer fires and emails the new owner with the plan-change warning; restore brings every QR live at the edge; no charge after T+0; a KV-delete failure lands in `dead_letter` with rows intact.

**Phase 2 — GA.** Remove the FE flag. **Amend `privacy/page.tsx:192`** (90 → 30 days) — a hard gate, not a follow-up. Update `AccountSection.tsx` copy to name retained billing records. Publish a help-centre page.
*GA gates:* zero-orphan checks green across ≥10 staging purges; `dead_letter` alerting wired; deletion emails verified deliverable (**`_dmarc` published**); `MoRProvider.cancel_subscription` either shipped or the manual-flag runbook written and tested.

**Deploy order.** Migration → backend → **Worker (`npm run deploy:prod`)** → frontend. The Worker line is safe at any point (an unknown internal path just 404s and is swallowed at `src/index.js:58-61`). The frontend must come last so no user can schedule a deletion the backend can't service.

**Rollback.** Before GA: remove the FE flag — the API becomes unreachable and the cron finds nothing. After a request exists: the request row is the whole state; setting `status='cancelled'` and re-running `resync_workspace_qrs` restores everything. **After a purge there is no rollback — that is the feature.** Which is exactly why the Phase-0 exit gate is a full staging rehearsal and not a code read.

**Metrics / alerts.**
- **Page immediately:** any request in `dead_letter`; any `manual_billing_action` older than 7 days; any request where `now() > purge_after + 2 days` and status is still `pending`/`purging` (SLA breach in progress).
- **Dashboard:** requests by status; median T+0→purge latency; restore rate during grace (the "was this a mistake" signal); per-purge counts from `step_results`; orphan post-check failures (should be identically zero).
- **Structured log per step:** `request_id`, `user_id_hash` (**never the raw id**), step number, duration, object counts, outcome.
- **Weekly compliance query:** the on-time/total SQL in §3.7.

---

## 12. Open Technical Questions & Risks

1. **Grace period — 30 days (recommended) vs the 90 currently published (`privacy/page.tsx:192`).** *Recommend **30**, amending the policy in the same PR.* GDPR Art. 12(3) requires completion "without undue delay and in any event within one month"; a 90-day purge sits outside that window even though processing stops at T+0. 30 days is clearly compliant, still a generous undo, and already matches the file-deletion sentence at `:200-201`. **The real defect is the mismatch, not the number** — whichever we pick, code and policy must agree.
2. **Does `subscriptions.workspace_id` cascade?** *Must be checked in §2.2 before writing step 5.* If it is `ON DELETE CASCADE`, deleting the workspace destroys the invoice record we are legally required to keep — silently defeating §3.6. Fix: reorder step 6 before step 5 and null the FK, or drop the cascade. **This is the highest-value single question in the introspection output.**
3. **Are `users` and `profiles` the same object?** Live code reads both — `security.py:357` uses `profiles`, while `workspace.py:390`/`:491`/`:665`/`:704`, `auth.py:110`/`:149`, and `internal.py:802`/`:887` use `users`. One may be a view or alias of the other. *Recommend confirming before writing two deletes*; a delete against a view will either fail or do nothing, and "nothing" is the dangerous outcome.
4. **Re-authentication before `POST` (PRD Open Q2).** *Recommend requiring it at GA*, email-typing + grace is adequate for Phase-1 beta. Cheap via Supabase `reauthenticate()`.
5. **MoR cancellation (PRD R4).** *Recommend shipping `MoRProvider.cancel_subscription` as a separate small PR before GA* if any USD subscriber exists. Until then, `manual_billing_action` blocks finalisation — deliberately visible rather than silently continuing to bill an erased user.
6. **Migration slot `0044` is provisional** — eleven sibling specs claim `0033`–`0043` and **none are on disk**. Re-run `ls qr_backend/migrations/` immediately before applying and renumber to the lowest free slot. Do not trust the header (`AI_BUSINESS_CARD_OCR` reserved `0024`, shipped `0026`).
7. **The cascade inventory is a living contract (PRD §12).** Four blocked specs will add `reminder_contacts`, `qr_loyalty_*`, and `workspace_billing_profile`. Each must add a row to §2 **and** a case to `test_deletion_cascade_completeness` in the PR that introduces it. *Recommend making that an explicit checklist item in those specs' Definition of Done* — an inventory nobody updates is worse than none, because it looks authoritative.
8. **Pre-existing orphans are not addressed.** Storage objects and KV keys already orphaned by past QR/workspace deletes remain. *Recommend a follow-up cleanup job reusing `storage_purge.py`* — out of scope here, but worth filing so it isn't forgotten once the helpers exist.
9. **`/internal/reclamation-sweep` 404s daily** (`qr_cf_code/src/index.js:77`; verified absent from the backend). **Referenced, deliberately not fixed** — it is unrelated to erasure, and bundling it would muddy this PR's review. File separately.
10. **Backups (PRD R6).** Supabase PITR retains purged rows for the project's backup window. Not application-controllable. *Recommend stating the window explicitly in the privacy policy* — it currently says nothing about backups at all, which is a bigger gap than the window itself.
11. **Purge-time volume on `qr_scan_events`.** For a very large account, even chunked deletes may exceed several ticks. Acceptable (checkpointed, resumable) but worth watching. *If it becomes a problem, recommend a partition-drop or `DELETE … LIMIT` loop in a dedicated RPC rather than more application-side chunking.*

### Appendix — Key Files

| Concern | File |
|---|---|
| Request/cancel/status routes | `qr_backend/src/api/routes/security.py` (append to the existing `/security` router; portability sibling at `:347`) |
| Purge engine | `qr_backend/src/utilities/account_purge.py` (**NEW**) |
| Storage sweep | `qr_backend/src/utilities/storage_purge.py` (**NEW**) |
| Cron endpoint | `qr_backend/src/api/routes/internal.py` (`POST /internal/deletion-purge`, **NEW**); secret guard `:21`, router dep `:34` |
| Migration | `qr_backend/migrations/0044_account_deletion_erasure.sql` (**NEW — re-verify slot**) |
| KV teardown (reuse) | `qr_backend/src/utilities/cloudflare_kv.py:519` (`delete_from_kv`), `:508` (`delete_domain_from_kv`), `:307` (`sync_qr_to_kv`), `:262` (`resync_workspace_qrs`) |
| CF-for-SaaS teardown (reuse) | `qr_backend/src/utilities/cloudflare_saas.py:123` (`delete_custom_hostname`) |
| Bulk-teardown precedent (read first) | `qr_backend/src/api/routes/razorpay_routes.py:1071` (`_revoke_custom_domains_for_workspace`) |
| Per-QR teardown precedent | `qr_backend/src/api/routes/qr.py:3403` (single), `:3354` (bulk, 100-id cap), `:3313` (update path) |
| Queue/lease/backoff precedent | `qr_backend/src/utilities/webhook_dispatch.py:231` (`_claim`), `:57` (backoff), `:58` (max attempts), `:301` (`dead_letter`), **`:516` (`sweep()` — unbounded, do NOT copy)** |
| Storage path shapes | `storage.py:143` (avatars), `:237` (temp), `:497`/`:552-554` (legacy user prefix); `qr.py:1706`/`:1737`/`:1803`/`:1858`/`:2357`; `branding.py:164` |
| Billing cancel | `razorpay_routes.py:415-420`, `:468`; **`src/integrations/mor/base.py` (no cancel — §6.2)** |
| Owner-scoped plan resolution | `subscription.py:283` (`resolve_plan`), `:237`, `:242`, `:248`, `:207-208` (`_PLAN_CACHE`) |
| Permissions / auth | `src/api/dependencies/deps.py:15`, `:33`, `:95`; `src/api/middlewares/auth_bearer.py:169`/`:188`; `src/main.py:62-70` |
| Supabase client (service role, **bypasses RLS**) | `qr_backend/src/database/supabase.py:28-38` |
| Hashing salt | `qr_backend/src/config/settings/base.py:131`; usage precedent `internal.py:1332` |
| Email | `qr_backend/src/utilities/email.py` (4 new `send_*`) — ⚠️ `_dmarc` GA gate |
| Worker cron dispatch (**1 line**) | `qr_cf_code/src/index.js:73-77`; `:77` = the known 404; `:55-64` = the log-and-swallow |
| Worker paused branch (reused, unchanged) | `qr_cf_code/src/index.js:368` (`getPausedPage`) |
| Worker cron config (**unchanged**) | `qr_cf_code/wrangler.toml` `[env.production.triggers]` |
| Settings UI (the `mailto:` to replace) | `qr_frontend/src/components/org/settings/AccountSection.tsx:98-117` |
| New UI | `.../settings/delete-account-card.tsx`, `.../delete-account-dialog.tsx` (**NEW**) |
| New hook | `qr_frontend/src/hooks/useAccountDeletion.ts` (**NEW**) |
| Banner / interstitial | `qr_frontend/src/app/[slug]/(dash)/layout.tsx`; `qr_frontend/src/app/(auth)/account-scheduled-for-deletion/page.tsx` (**NEW**) |
| Privacy policy (**must be amended**) | `qr_frontend/src/app/(marketing)/privacy/page.tsx:191-193`, `:200-201`, `:204-205`, `:228`, `:243` |
| Coverage guardrail (**must stay unchanged**) | `qr_backend/tests/unit_tests/test_feature_gate_coverage.py` |
