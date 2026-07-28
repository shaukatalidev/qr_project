# TRD — Loyalty / Digital Stamp Card (merchant-authorized stamping)

**Status:** Draft · **Author:** Engineering (Staff) · **Date:** 2026-07-25
**Priority:** XL, and honestly so. The card, the templates, and the type seam are routine; **the entire engineering difficulty is that a stamp must be un-grantable by the person who benefits from it.** Every design decision below falls out of that one constraint.
**Tiers:** **Pro + Agency.** `loyalty_cards` (bool) + `loyalty_members_max` (int, per workspace). `loyalty` appended to Pro/Agency `dynamic_qr_types` only — the `lead_form` double-gate precedent from `0027_open_all_qr_types.sql`, not the open-types rule.
**Plan flags (NEW):** `loyalty_cards`, `loyalty_members_max`. Seeded as a **full-object `'{...}'::jsonb` blob** (`test_feature_gate_coverage._seed_feature_keys()` regex-discovers only blob seeds; a path-only `jsonb_set` seed fails both keys as "stale"), registered `inert`→`enforced` in the **same PR**.
**Migration slot:** **`0043_loyalty_stamp_card.sql` — PROVISIONAL.** Disk reality at authoring time: highest existing file is `0032_lemonsqueezy_variant_backfill.sql`; `0033` is claimed by `QR_EXPIRY_SCHEDULING_TRD.md`; `0034`–`0042` are being claimed by the concurrent batch of gap-analysis specs. **Re-run `ls qr_backend/migrations/` immediately before applying and renumber to the lowest free slot.** This repo has burned two specs already: `WALLET_PASSES_*` reserved `0023` and `0023_outbound_webhooks.sql` took it; `AI_BUSINESS_CARD_OCR_*` reserved `0024` and shipped as `0026`. Treat the header as a hint, never as truth.
**Services touched:** `qr_backend` (heavy — 4 new tables, 3 atomic RPCs, a public staff-session auth scheme, 2 route modules) · `qr_cf_code` (member card route + 3 proxy routes + the `loyalty` type page — **requires `npm run deploy:prod`**) · `qr_frontend` (content form, anti-fraud settings, staff-PIN manager, a **public** staff console at `/stamp/[code]`, Loyalty dashboard tab). **No AI. No email. No new cron trigger** (the lapsed sweep rides the existing daily internal cron).
**Implements PRD:** Loyalty / Digital Stamp Card. **OWNS** the `loyalty` type end-to-end (see Rev). ~~**Depends on** `WHATSAPP_REVIEW_REMINDERS_*` for the OTP + re-engagement transport.~~ — **this dependency is REMOVED in v1** (see Rev).

**Rev (2026-07-25, post eng-review):** Reviewed via `/plan-eng-review` + an outside-voice pass (all claims code-verified). **Two structural decisions reshape this spec.**
**(A) v1 is "Stamp v0" — OTP and WhatsApp are CUT.** The OTP was defending *identity farming*, but **merchant-authorized stamping already closes that**: 40 phantom members still need 10 staff-authorized stamps each, and Open Q3 explicitly refuses an enrolment bonus, so a phantom enrolment has **zero payoff**. OTP was buying nothing while costing the largest funnel drop (this spec concedes it), the whole item-#1 dependency, a 6th table, an OTP-pumping abuse surface, and per-merchant Meta onboarding *before a customer can enrol*. **v1 ships:** `loyalty` type + `qr_loyalty_details` + `qr_loyalty_members` (device-cookie identity; **phone optional and unverified**) + `qr_loyalty_staff` + `qr_loyalty_events`; **staff-PIN console only**; staff-authorized redemption with a single-use code; ledger, cooldowns/caps, idempotency, reversal. **v1 cuts:** OTP + `qr_loyalty_otps`, all WhatsApp triggers, the lapsed sweep + its cron, TOTP + Fernet + `LOYALTY_ENC_KEY`, and `loyalty_members_max` (no verified PII to cap). This is **M-sized with ZERO dependency on item #1 or the Wallet epic**, and it tests the one unproven thing that actually kills the feature: *does counter staff use the console under a queue* (R6 / "median stamps per staff session ≥ 5"). Phase 2 adds phone + WhatsApp — **loyalty-owned**, since item #1 ships no OTP primitive (zero mentions; a 30-min minimum queue delay cannot carry a 10-min OTP TTL; Meta's authentication category is never mentioned or priced there; and loyalty re-use is an explicit non-goal of that spec). Phase 3 is the Wallet `.pkpass`. **The "hard sequencing gate behind item #1" is deleted** — it bought only opt-out plumbing while hostaging loyalty to item #1's own `<4%` kill gate.
**(B) Loyalty OWNS the `loyalty` type; `WALLET_PASSES_TRD` must be amended.** Loyalty owns `qr_loyalty_details`, the type `Literal`, `SELECT_WITH_RELATIONS`, `LoyaltyContent`, the `build_kv_content` branch, and `src/pages/loyalty/*`. **Amend the Wallet TRD to drop `stamps_current`** (the per-QR-vs-per-customer modelling bug this spec exists to correct) **and its duplicate edits to those same four `qr.py` spots, its duplicate KV branch, and its claim on `stampCardTemplate.js`/`helpers.js`** — Wallet retains only `.pkpass`/APNs/`update_tag`. That amendment was demanded by this spec and **has not been made**; it is now a prerequisite. Also: whichever migration lands second must add **every** column with `ADD COLUMN IF NOT EXISTS` (a `CREATE TABLE IF NOT EXISTS` no-ops and silently skips columns), and Wallet's `0023` slot is already consumed by `0023_outbound_webhooks.sql` — renumber it.
**Blockers (must fix):** (1) **The append-only trigger makes loyalty QRs undeletable** — `BEFORE UPDATE OR DELETE` fires on *cascaded* deletes, so deleting a QR/member/workspace raises `qr_loyalty_events is append-only`, breaking both §8's cascade claim and DPDP erasure. Make it `BEFORE UPDATE` only; enforce no-delete by privilege, not by a trigger the cascade must traverse. (2) **Counter-code sharing is not prevented** — `uq_loy_events_step` is keyed `(member_id, counter_code_step)`, so one photographed code stamps **unlimited distinct members** across ~120 s and the per-member cooldown never bites. Use **`UNIQUE (qr_id, counter_code_step)`** (one stamp per program per 60 s window — ample for the single-chair-salon persona and it kills mass-sharing outright), or cut Mode B. (3) **The "structural" anti-fraud invariant isn't structural** — `auth_mode` is nullable with no CHECK, so a NULL-auth stamp stores fine and the ≥99.9% KPI is circular. Add `CHECK (event_type <> 'stamp' OR auth_mode IN ('staff_pin','counter_code','owner_override'))`. (4) **Idempotency ignores `event_type`** — a reused key makes `loyalty_redeem` return `ok:true, redemption_code:NULL` off a *stamp* row (staff sees "redeemed", no reward, card not reset). Filter on `event_type`; index `(member_id, event_type, idempotency_key)`. (5) **`/m/:memberToken` and `/loyalty/*` bypass custom-domain tenant isolation** — those prefixes are matched *before* the `domain:<hostname>` → `workspace_id` check, so on merchant B's custom domain `/m/<A's token>` renders merchant A's customer PII and `/loyalty/enroll/<A's code>` enrols into A's program. Return `workspace_id` from the internal member lookup and apply the same `expectedWorkspaceId` guard.
**High:** `loyalty_reverse` takes no `qr_id` (staff for QR A can reverse QR B's events) and is unbounded in time; reversing a `redeem` re-adds stamps **without** decrementing `rewards_redeemed` or un-burning the code = a free second reward — take `p_qr_id`, restrict staff-undo to `event_type='stamp'` within N minutes, handle redeem-reversal owner-only. The **PIN throttle has no storage** (in-process counters are worthless on multi-worker Render) — add `qr_loyalty_pin_attempts`. Per-IP throttling is the wrong axis for a 6-digit PIN on a semi-public short code — add a **global per-QR failure budget** (e.g. 50/hr → lock console + alert). **Staff-session login is an unauthenticated bcrypt amplifier** (bcrypt-verify against every active staff row; ~250 ms × N per unauthenticated request, and this backend has no global rate limiter) — store `HMAC-SHA256(pin, per-QR salt)` for an O(1) indexed lookup. **`member_token` is a URL-borne secret** — set `Referrer-Policy: no-referrer` on `/m/`, keep it out of Worker logs, and make the *scannable* code short-lived rather than the durable identity token.
**Medium:** the `dynamic_qr_types` append contradicts `0027`'s wholesale-canonical-array convention (re-running `0027`, which invites it, silently drops `loyalty`) — extend `0027`'s arrays or annotate it; `loyalty_stamp` **silently disables every guard when `qr_loyalty_details` is missing** (NULL comparisons are falsy → unlimited stamping) — add `IF NOT FOUND THEN RETURN 'program_not_configured'`; catch `unique_violation` and return a structured refusal instead of a 500; decide whether stamp-time plan gating exists (it's in §7's contract, absent from §3.1, and `dynamic_qr_types` is create-only) and budget its 2–3 extra REST calls against the p95<500 ms counter path; the lapsed sweep is a **new** `/internal/loyalty-sweep` + a new Worker cron ping, not a fold-in (and don't stack onto the `0 6 * * *` branch's already-404ing `/internal/reclamation-sweep`) — moot in v0 since the sweep is cut; **do not use passlib** (`qr_password.py` exists precisely because passlib 1.7.4 crashes against bcrypt ≥4.1) — use `bcrypt` directly and copy that helper's 72-byte handling; the excluded prefix needs a **trailing slash** (`{API_PREFIX}/loyalty/`) or it also excludes `/loyalty-admin`. **Identity gap worth stating:** WhatsApp/Instagram in-app webviews use a separate cookie jar, so "scan next month and your card comes up" silently fails for a large slice of the ICP — on enrol-start, re-issue the cookie when `(qr_id, phone_hash)` already exists rather than restarting enrolment. Minor: `npm run deploy` doesn't exist (`deploy:dev`/`deploy:prod`); the frontend has no `org/` route group; add `stamp` to `RESERVED_ROOTS`; reuse `src/hooks/useQrScanner.ts` (not the marketing composition); `page-templates` is `.tsx`; the Fernet precedent is `WEBHOOK_SECRET_ENC_KEY`; the Worker has **no QR library** so the member card's scannable code needs a backend SVG endpoint; `short_code` isn't in the KV payload (derive from `request.url`); and state where the returning-member 302 sits relative to `recordScan` or returning members go unrecorded. **Confirmed right:** no-stamp-on-scan as a hard invariant, per-customer state in Postgres with a secret-free Worker, `SELECT … FOR UPDATE` per member, the `{API_PREFIX}/loyalty` exclusion argument, the blob seed, slot `0043`, the downgrade policy, and the accurate indictment of the cosmetic `coupon_stamp` template.

---

## 1. Overview & Architecture

A `loyalty` dynamic QR carries a **program definition** (reward, stamps required, anti-fraud policy). Stamp
state is **per customer**, in `qr_loyalty_members`, keyed by an OTP-verified phone. Every mutation is an
append-only row in `qr_loyalty_events` and happens inside **one atomic Postgres RPC** that takes a row lock on
the member, so concurrent stamps cannot race the cooldown check.

**The central architectural rule: the edge cannot stamp.** The Cloudflare Worker holds no PIN, no TOTP
secret, and no counter. It renders pages and **proxies customer POSTs to the backend** using the exact
mechanism already shipped for `POST /pw-verify/:shortCode` (`qr_cf_code/src/index.js` L98–133 → `${env.BACKEND_URL}/internal/qr-by-code/{sc}/verify-password`,
authenticated by `x-internal-secret`). This is not caution for its own sake: a Worker that could stamp is a
Worker whose leaked secret mints unlimited free product for every merchant on the platform simultaneously.

**Authorization has two shapes, and both terminate at the backend:**

| Mode | Who holds authority | Credential | Where it is checked |
|---|---|---|---|
| `staff_pin` (default) | Merchant's own device | `LoyaltyStaff <session_token>` — HMAC, day-scoped, minted by a PIN exchange | `loyalty.py` public-but-session-authed routes, called **directly from the staff console origin** (CORS), never via the Worker |
| `counter_code` (opt-in) | A rotating display at the counter | 6-digit TOTP over a per-QR Fernet-encrypted secret, 60s step, single-use per `(member, step)` | `internal.py`, called **via the Worker proxy** from the customer's page |

The customer's own device is **never** an authority in either mode. `member_token` is an *identity* — it
resolves "which card is this" and nothing more, which is exactly why parking it in a long-lived cookie on the
short-code origin is safe.

**Services touched**

| Service | Change |
|---|---|
| `qr_backend` | Migration (4 tables + `qr_loyalty_details` create-or-extend + 3 RPCs + append-only trigger + flag seed). New `src/api/routes/loyalty.py` (authenticated management + staff-session public routes). New loyalty endpoints in `src/api/routes/internal.py` (Worker-proxied customer flows). New `src/utilities/loyalty.py` (PIN hashing, session HMAC, TOTP, member-token minting). `loyalty` in the type Literal + `SELECT_WITH_RELATIONS` + `build_kv_content`. Both flags in `FEATURE_ENFORCEMENT` + `_QUOTA_SPEC`. Lapsed-nudge sweep folded into the existing daily internal cron endpoint. |
| `qr_cf_code` | New `GET /m/:memberToken` (member card). New proxies `POST /loyalty/enroll/:shortCode`, `POST /loyalty/verify/:shortCode`, `POST /loyalty/code/:memberToken`. New `src/pages/loyalty/` (dispatcher + templates) + `loyaltyPage.js` re-export shim + a `loyalty` branch in `handlers/qrRouter.js`. **Requires prod worker deploy.** |
| `qr_frontend` | `LoyaltyContent.tsx` + anti-fraud settings + staff-PIN manager in the builder. **New public route `src/app/stamp/[code]/`** — the staff console (PIN pad, camera member-resolution reusing `components/marketing/qr-scanner/scanner-tool.tsx`, stamp/redeem/undo, counter-code display mode). Loyalty tab on QR detail (members, ledger, reversal, CSV). `loyalty_cards` in `PlanFeatures`. |

**Data flow — enrolment (customer, public, no login)**

```
Scan poster → Worker GET /:shortCode → KV type='loyalty'
  → cookie qr_loy_<shortCode> present? → 302 /m/<member_token>   [returning customer]
  → else render program card (0/N) + join form
POST /loyalty/enroll/:shortCode  (Worker)
  → x-internal-secret → POST /internal/loyalty/{short_code}/enroll/start { phone, consent_text }
  → backend: check_feature(loyalty_cards) + loyalty_members_max headroom
           → normalize E.164 → phone_hash = sha256(e164 + HASHING_SALT)
           → rate-limit (5 OTP / phone / hour, 20 / ip_hash / hour)
           → mint 6-digit OTP, store code_hash + expires_at (10 min)
           → hand to item #1's outbound channel   [NOT a new transport]
POST /loyalty/verify/:shortCode  (Worker)
  → /internal/loyalty/{short_code}/enroll/verify { phone, code }
  → backend: ≤3 attempts, constant-time compare, consume OTP
           → UPSERT qr_loyalty_members (qr_id, phone_hash) → member_token, phone_verified_at=now()
           → ledger row event_type='enroll', delta=0, stamps_after=0     ← enrolment grants NO stamp
  → Worker sets HttpOnly SameSite=Lax cookie qr_loy_<shortCode>=<member_token>, 1y
  → 302 /m/<member_token>
```

**Data flow — stamping, Mode A (staff PIN)**

```
Staff open https://app.qravio.app/stamp/<code>  (public Next.js route, NO Supabase session)
  → POST /api/v1/loyalty/staff/session { short_code, pin }        [direct to backend, CORS]
  → backend: resolve qr → bcrypt-verify pin against ACTIVE qr_loyalty_staff rows for that qr
           → throttle: 5 failures / ip_hash / qr / 15 min → 429 + lock
           → mint session_token = HMAC(staff_id | qr_id | day | nonce, INTERNAL_SECRET-derived key)
  → console: resolve member (camera scan of /m/<token>, or phone lookup)
  → POST /api/v1/loyalty/stamp   Authorization: LoyaltyStaff <session_token>
       { member_token, idempotency_key }
  → backend: verify session (HMAC + day + staff active + per-session daily cap)
           → db.rpc('loyalty_stamp', {...auth_mode:'staff_pin', staff_id, idempotency_key})
                 ├ SELECT ... FOR UPDATE on the member row          ← serializes concurrent stamps
                 ├ replay? → return the prior result verbatim       ← idempotent
                 ├ cooldown (min_stamp_interval_seconds) + per-day cap → structured refusal
                 ├ stamps_current += 1, stamps_lifetime += 1, last_stamped_at = now()
                 └ INSERT qr_loyalty_events (stamp, delta=+1, stamps_after, auth_mode, staff_id, ip_hash…)
           → if stamps_after == required-1 → enqueue 'near_reward'  ┐ item #1's queue
           → if stamps_after >= required   → enqueue 'reward_ready' ┘  (never inline sends)
  → console shows N+1/M + Undo (short window → loyalty_reverse RPC)
```

**Data flow — stamping, Mode B (rotating counter code)**

```
Console in display mode → GET /api/v1/loyalty/counter-code (LoyaltyStaff auth)
  → backend: TOTP(step = floor(now/60)) over Fernet-decrypted qr_loyalty_details.counter_code_secret
Customer on /m/<token> taps "I'm at the counter" → enters 6 digits
  → Worker POST /loyalty/code/:memberToken → /internal/loyalty/member/{token}/counter-code
  → backend: accept step ∈ {now, now-1} → loyalty_stamp(auth_mode='counter_code', counter_code_step=step)
           → UNIQUE (member_id, counter_code_step) makes a replayed/shared code a hard no-op
```

---

## 2. Data Model & Migrations

Four new tables plus a create-or-extend of `qr_loyalty_details` (owned jointly with the Wallet epic). Three
`plpgsql` RPCs carry all mutation logic so counting is atomic and the route layer stays thin.

**RLS note:** the backend uses the Supabase **service-role** client, which **bypasses RLS**. Every new table
gets `ENABLE ROW LEVEL SECURITY` with **no policies**, so the `anon`/`authenticated` roles can never read
member phones, PIN hashes, or OTP hashes even if a key were mis-scoped. Tenant isolation is enforced in route
code via explicit `.eq("workspace_id", …)` filters plus `workspace_members` role checks — never by RLS. This
matters more here than anywhere else in the codebase: these tables hold third-party phone numbers.

**Ordering independence from the Wallet epic (PRD R8):** `qr_loyalty_details` is created `IF NOT EXISTS` with
the Wallet definition **minus** `stamps_current`, and every added column uses `ADD COLUMN IF NOT EXISTS`. If
`WALLET_PASSES` landed first, the `DROP COLUMN IF EXISTS stamps_current` removes the per-QR counter; if it
lands after, its `CREATE TABLE IF NOT EXISTS` is a no-op and its `stamps_current` never appears. Either order
converges. **The Wallet TRD must be amended to drop that column from its own definition** — otherwise a
re-apply reintroduces it.

**`qr_backend/migrations/0043_loyalty_stamp_card.sql`** — `BEGIN/COMMIT`-wrapped, idempotent, applied by hand
in the Supabase SQL editor.

```sql
-- Migration 0043: Loyalty / digital stamp card — merchant-authorized stamping.
-- Folds into the Wallet Passes epic: shares qr_loyalty_details, adds the per-CUSTOMER
-- state the Wallet TRD is missing, and REMOVES its per-QR stamps_current (a stamp count
-- is a property of a customer, not of a QR).
-- SLOT IS PROVISIONAL — re-run `ls qr_backend/migrations/` before applying (0023 and
-- 0024 were both lost to collisions by earlier specs).
BEGIN;

-- ── (1) Program definition — SHARED with WALLET_PASSES (create-or-extend) ──────
CREATE TABLE IF NOT EXISTS qr_loyalty_details (
    qr_id            uuid        PRIMARY KEY REFERENCES qr_codes(id) ON DELETE CASCADE,
    program_name     text        NOT NULL DEFAULT '',
    reward_text      text,
    stamps_required  int         NOT NULL DEFAULT 10,
    business_name    text,
    website_url      text,
    terms            text,
    created_at       timestamptz NOT NULL DEFAULT now(),
    updated_at       timestamptz NOT NULL DEFAULT now()
);

-- The Wallet TRD's per-QR counter is a modelling bug: stamp state is per CUSTOMER
-- (qr_loyalty_members.stamps_current). Drop it if that migration already ran.
ALTER TABLE qr_loyalty_details DROP COLUMN IF EXISTS stamps_current;

-- Anti-fraud + lifecycle policy, authored in the builder.
ALTER TABLE qr_loyalty_details
    ADD COLUMN IF NOT EXISTS stamp_auth_mode           text    NOT NULL DEFAULT 'staff_pin',
    ADD COLUMN IF NOT EXISTS min_stamp_interval_seconds int    NOT NULL DEFAULT 21600,  -- 6h
    ADD COLUMN IF NOT EXISTS max_stamps_per_day        int     NOT NULL DEFAULT 1,
    ADD COLUMN IF NOT EXISTS redeem_policy             text    NOT NULL DEFAULT 'rollover',
    ADD COLUMN IF NOT EXISTS counter_code_secret_enc   text,          -- Fernet(base32 TOTP secret)
    ADD COLUMN IF NOT EXISTS lapsed_nudge_enabled      boolean NOT NULL DEFAULT false,
    ADD COLUMN IF NOT EXISTS lapsed_after_days         int     NOT NULL DEFAULT 45,
    ADD COLUMN IF NOT EXISTS enroll_enabled            boolean NOT NULL DEFAULT true;

-- Constraints added idempotently (ADD CONSTRAINT has no IF NOT EXISTS in PG 15).
DO $$ BEGIN
    ALTER TABLE qr_loyalty_details
        ADD CONSTRAINT chk_loyalty_auth_mode CHECK (stamp_auth_mode IN ('staff_pin','counter_code')),
        ADD CONSTRAINT chk_loyalty_required  CHECK (stamps_required BETWEEN 3 AND 20),
        ADD CONSTRAINT chk_loyalty_policy    CHECK (redeem_policy IN ('reset','rollover'));
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

-- ── (2) Per-customer membership + stamp state ─────────────────────────────────
-- member_token is an IDENTITY, never an authority: knowing it lets you VIEW a card,
-- never stamp one. That is what makes the 1-year origin cookie safe.
CREATE TABLE IF NOT EXISTS qr_loyalty_members (
    id                uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    qr_id             uuid        NOT NULL REFERENCES qr_codes(id)   ON DELETE CASCADE,
    workspace_id      uuid        NOT NULL REFERENCES workspaces(id) ON DELETE CASCADE,
    member_token      text        NOT NULL UNIQUE,          -- opaque 22-char base62, CSPRNG
    phone_e164        text        NOT NULL,                 -- DPDP: purpose-bound, needed for WhatsApp
    phone_hash        text        NOT NULL,                 -- sha256(e164 + HASHING_SALT) — lookup/dedupe
    phone_verified_at timestamptz,                          -- NULL ⇒ never stampable (see RPC guard)
    consent_text      text        NOT NULL,                 -- exact string shown (audit) — 0012 pattern
    consent_at        timestamptz NOT NULL DEFAULT now(),
    opted_out_at      timestamptz,                          -- STOP: messages off, card keeps working
    stamps_current    int         NOT NULL DEFAULT 0 CHECK (stamps_current >= 0),
    stamps_lifetime   int         NOT NULL DEFAULT 0 CHECK (stamps_lifetime >= 0),
    rewards_redeemed  int         NOT NULL DEFAULT 0,
    last_stamped_at   timestamptz,
    enrolled_at       timestamptz NOT NULL DEFAULT now(),
    updated_at        timestamptz NOT NULL DEFAULT now(),
    UNIQUE (qr_id, phone_hash)                              -- one member per phone per program
);
ALTER TABLE qr_loyalty_members ENABLE ROW LEVEL SECURITY;   -- no policies: service-role only
CREATE INDEX IF NOT EXISTS idx_loy_members_qr     ON qr_loyalty_members (qr_id, last_stamped_at DESC);
CREATE INDEX IF NOT EXISTS idx_loy_members_ws     ON qr_loyalty_members (workspace_id);
-- Lapsed sweep: only members who have actually engaged and still consent.
CREATE INDEX IF NOT EXISTS idx_loy_members_lapsed ON qr_loyalty_members (qr_id, last_stamped_at)
    WHERE opted_out_at IS NULL AND stamps_current > 0;

-- ── (3) Staff PINs (attribution + throttled authorization, NOT a strong credential) ──
-- Created BEFORE the ledger because qr_loyalty_events.staff_id references it.
CREATE TABLE IF NOT EXISTS qr_loyalty_staff (
    id              uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    qr_id           uuid        NOT NULL REFERENCES qr_codes(id)   ON DELETE CASCADE,
    workspace_id    uuid        NOT NULL REFERENCES workspaces(id) ON DELETE CASCADE,
    label           text        NOT NULL,        -- "Divya — evening shift" (shown in the ledger)
    pin_hash        text        NOT NULL,        -- bcrypt; the PIN is displayed once, never stored
    is_active       boolean     NOT NULL DEFAULT true,
    daily_stamp_cap int         NOT NULL DEFAULT 200,
    last_used_at    timestamptz,
    created_at      timestamptz NOT NULL DEFAULT now(),
    revoked_at      timestamptz
);
ALTER TABLE qr_loyalty_staff ENABLE ROW LEVEL SECURITY;
CREATE INDEX IF NOT EXISTS idx_loy_staff_qr ON qr_loyalty_staff (qr_id) WHERE is_active;

-- ── (4) Append-only event ledger (the anti-fraud record of truth) ─────────────
CREATE TABLE IF NOT EXISTS qr_loyalty_events (
    id                 uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    member_id          uuid        NOT NULL REFERENCES qr_loyalty_members(id) ON DELETE CASCADE,
    qr_id              uuid        NOT NULL REFERENCES qr_codes(id)   ON DELETE CASCADE,
    workspace_id       uuid        NOT NULL REFERENCES workspaces(id) ON DELETE CASCADE,
    event_type         text        NOT NULL,   -- enroll | stamp | redeem | reverse | override
    delta              int         NOT NULL DEFAULT 0,
    stamps_after       int         NOT NULL,
    auth_mode          text,                   -- staff_pin | counter_code | owner_override | system
    staff_id           uuid        REFERENCES qr_loyalty_staff(id) ON DELETE SET NULL,
    counter_code_step  bigint,                 -- TOTP step consumed (mode B only)
    idempotency_key    text,
    redemption_code    text,                   -- issued on redeem; single-use
    redemption_used_at timestamptz,            -- the ONLY column the append-only trigger lets you update
    reverses_event_id  uuid        REFERENCES qr_loyalty_events(id) ON DELETE SET NULL,
    ip_hash            text,                   -- sha256(ip + HASHING_SALT) — never a raw IP
    ua_hash            text,
    created_at         timestamptz NOT NULL DEFAULT now(),
    CHECK (event_type IN ('enroll','stamp','redeem','reverse','override'))
);
ALTER TABLE qr_loyalty_events ENABLE ROW LEVEL SECURITY;
-- Replay protection: the same idempotency key can never produce a second event.
CREATE UNIQUE INDEX IF NOT EXISTS uq_loy_events_idem ON qr_loyalty_events (member_id, idempotency_key)
    WHERE idempotency_key IS NOT NULL;
-- A counter code, once spent by a member for a 60s step, is spent. Shared screenshots die here.
CREATE UNIQUE INDEX IF NOT EXISTS uq_loy_events_step ON qr_loyalty_events (member_id, counter_code_step)
    WHERE counter_code_step IS NOT NULL;
CREATE UNIQUE INDEX IF NOT EXISTS uq_loy_events_redcode ON qr_loyalty_events (redemption_code)
    WHERE redemption_code IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_loy_events_qr     ON qr_loyalty_events (qr_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_loy_events_member ON qr_loyalty_events (member_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_loy_events_staff  ON qr_loyalty_events (staff_id, created_at DESC)
    WHERE staff_id IS NOT NULL;

-- Append-only enforcement. A ledger a compromised service key can silently rewrite is
-- not a ledger. Only redemption_used_at (the single-use burn) may ever change.
CREATE OR REPLACE FUNCTION loyalty_events_append_only() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    IF TG_OP = 'DELETE' THEN
        RAISE EXCEPTION 'qr_loyalty_events is append-only (reverse instead of delete)';
    END IF;
    -- Compare every column EXCEPT redemption_used_at; any other change is rejected.
    IF ROW(NEW.id, NEW.member_id, NEW.qr_id, NEW.workspace_id, NEW.event_type, NEW.delta,
           NEW.stamps_after, NEW.auth_mode, NEW.staff_id, NEW.counter_code_step,
           NEW.idempotency_key, NEW.redemption_code, NEW.reverses_event_id,
           NEW.ip_hash, NEW.ua_hash, NEW.created_at)
       IS DISTINCT FROM
       ROW(OLD.id, OLD.member_id, OLD.qr_id, OLD.workspace_id, OLD.event_type, OLD.delta,
           OLD.stamps_after, OLD.auth_mode, OLD.staff_id, OLD.counter_code_step,
           OLD.idempotency_key, OLD.redemption_code, OLD.reverses_event_id,
           OLD.ip_hash, OLD.ua_hash, OLD.created_at) THEN
        RAISE EXCEPTION 'qr_loyalty_events is append-only (only redemption_used_at is mutable)';
    END IF;
    RETURN NEW;
END; $$;
DROP TRIGGER IF EXISTS trg_loyalty_events_append_only ON qr_loyalty_events;
CREATE TRIGGER trg_loyalty_events_append_only
    BEFORE UPDATE OR DELETE ON qr_loyalty_events
    FOR EACH ROW EXECUTE FUNCTION loyalty_events_append_only();

-- ── (5) Enrolment OTPs (short-lived; hashed; consumed once) ───────────────────
CREATE TABLE IF NOT EXISTS qr_loyalty_otps (
    id           uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    qr_id        uuid        NOT NULL REFERENCES qr_codes(id) ON DELETE CASCADE,
    phone_hash   text        NOT NULL,           -- never the raw number
    code_hash    text        NOT NULL,           -- sha256(code + HASHING_SALT)
    attempts     int         NOT NULL DEFAULT 0,
    ip_hash      text,
    expires_at   timestamptz NOT NULL,
    consumed_at  timestamptz,
    created_at   timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE qr_loyalty_otps ENABLE ROW LEVEL SECURITY;
CREATE INDEX IF NOT EXISTS idx_loy_otps_lookup ON qr_loyalty_otps (qr_id, phone_hash, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_loy_otps_rate   ON qr_loyalty_otps (ip_hash, created_at DESC);

-- ── (6) Atomic stamp. ALL authorization has already happened in the route; this
--        function owns correctness (locking, replay, cooldown, caps, ledger).
CREATE OR REPLACE FUNCTION loyalty_stamp(
    p_member_id       uuid,
    p_auth_mode       text,
    p_staff_id        uuid    DEFAULT NULL,
    p_idempotency_key text    DEFAULT NULL,
    p_counter_step    bigint  DEFAULT NULL,
    p_ip_hash         text    DEFAULT NULL,
    p_ua_hash         text    DEFAULT NULL
) RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
    m           qr_loyalty_members%ROWTYPE;
    cfg         qr_loyalty_details%ROWTYPE;
    prior       qr_loyalty_events%ROWTYPE;
    today_count int;      -- stamps already given to this member today
    new_count   int;      -- stamps_current AFTER this stamp
    new_event   uuid;
BEGIN
    -- Row lock serializes concurrent stamps for THIS member (two staff, one customer).
    SELECT * INTO m FROM qr_loyalty_members WHERE id = p_member_id FOR UPDATE;
    IF NOT FOUND THEN RETURN jsonb_build_object('ok', false, 'code', 'member_not_found'); END IF;
    IF m.phone_verified_at IS NULL THEN
        RETURN jsonb_build_object('ok', false, 'code', 'member_unverified');
    END IF;

    -- Replay → return the ORIGINAL result verbatim (never a second stamp, never an error).
    IF p_idempotency_key IS NOT NULL THEN
        SELECT * INTO prior FROM qr_loyalty_events
         WHERE member_id = p_member_id AND idempotency_key = p_idempotency_key;
        IF FOUND THEN
            RETURN jsonb_build_object('ok', true, 'replayed', true,
                'stamps_current', prior.stamps_after, 'event_id', prior.id);
        END IF;
    END IF;

    SELECT * INTO cfg FROM qr_loyalty_details WHERE qr_id = m.qr_id;

    IF m.last_stamped_at IS NOT NULL
       AND m.last_stamped_at > now() - make_interval(secs => cfg.min_stamp_interval_seconds) THEN
        RETURN jsonb_build_object('ok', false, 'code', 'cooldown',
            'retry_after', extract(epoch FROM
                (m.last_stamped_at + make_interval(secs => cfg.min_stamp_interval_seconds)) - now())::int);
    END IF;

    SELECT count(*) INTO today_count FROM qr_loyalty_events
     WHERE member_id = p_member_id AND event_type = 'stamp'
       AND created_at >= date_trunc('day', now() AT TIME ZONE 'Asia/Kolkata') AT TIME ZONE 'Asia/Kolkata';
    IF today_count >= cfg.max_stamps_per_day THEN
        RETURN jsonb_build_object('ok', false, 'code', 'daily_cap', 'limit', cfg.max_stamps_per_day);
    END IF;

    UPDATE qr_loyalty_members
       SET stamps_current  = stamps_current + 1,
           stamps_lifetime = stamps_lifetime + 1,
           last_stamped_at = now(),
           updated_at      = now()
     WHERE id = p_member_id
    RETURNING stamps_current INTO new_count;

    INSERT INTO qr_loyalty_events (member_id, qr_id, workspace_id, event_type, delta, stamps_after,
                                   auth_mode, staff_id, counter_code_step, idempotency_key,
                                   ip_hash, ua_hash)
    VALUES (p_member_id, m.qr_id, m.workspace_id, 'stamp', 1, new_count,
            p_auth_mode, p_staff_id, p_counter_step, p_idempotency_key, p_ip_hash, p_ua_hash)
    RETURNING id INTO new_event;
    -- A duplicate counter_code_step raises unique_violation here → the whole call rolls back,
    -- so a shared/replayed code cannot leave a stamp behind. Deliberate: fail closed.

    RETURN jsonb_build_object('ok', true, 'stamps_current', new_count,
        'stamps_required', cfg.stamps_required, 'event_id', new_event,
        'reward_ready', new_count >= cfg.stamps_required);
END; $$;

-- ── (7) Atomic redeem (staff-authorized only; single-use code; policy applied) ─
CREATE OR REPLACE FUNCTION loyalty_redeem(
    p_member_id uuid, p_staff_id uuid, p_idempotency_key text, p_redemption_code text,
    p_ip_hash text DEFAULT NULL
) RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE m qr_loyalty_members%ROWTYPE; cfg qr_loyalty_details%ROWTYPE;
        prior qr_loyalty_events%ROWTYPE; remaining int; new_event uuid;
BEGIN
    SELECT * INTO m FROM qr_loyalty_members WHERE id = p_member_id FOR UPDATE;
    IF NOT FOUND THEN RETURN jsonb_build_object('ok', false, 'code', 'member_not_found'); END IF;
    IF p_idempotency_key IS NOT NULL THEN
        SELECT * INTO prior FROM qr_loyalty_events
         WHERE member_id = p_member_id AND idempotency_key = p_idempotency_key;
        IF FOUND THEN RETURN jsonb_build_object('ok', true, 'replayed', true,
            'redemption_code', prior.redemption_code, 'stamps_current', prior.stamps_after); END IF;
    END IF;
    SELECT * INTO cfg FROM qr_loyalty_details WHERE qr_id = m.qr_id;
    IF m.stamps_current < cfg.stamps_required THEN
        RETURN jsonb_build_object('ok', false, 'code', 'not_complete',
            'stamps_current', m.stamps_current, 'stamps_required', cfg.stamps_required);
    END IF;
    remaining := CASE WHEN cfg.redeem_policy = 'rollover'
                      THEN m.stamps_current - cfg.stamps_required ELSE 0 END;
    UPDATE qr_loyalty_members
       SET stamps_current = remaining, rewards_redeemed = rewards_redeemed + 1, updated_at = now()
     WHERE id = p_member_id;
    INSERT INTO qr_loyalty_events (member_id, qr_id, workspace_id, event_type, delta, stamps_after,
                                   auth_mode, staff_id, idempotency_key, redemption_code, ip_hash)
    VALUES (p_member_id, m.qr_id, m.workspace_id, 'redeem', -cfg.stamps_required, remaining,
            'staff_pin', p_staff_id, p_idempotency_key, p_redemption_code, p_ip_hash)
    RETURNING id INTO new_event;
    RETURN jsonb_build_object('ok', true, 'redemption_code', p_redemption_code,
        'stamps_current', remaining, 'event_id', new_event);
END; $$;

-- ── (8) Reverse (staff undo / owner correction) — compensating row, never a delete ──
CREATE OR REPLACE FUNCTION loyalty_reverse(
    p_event_id uuid, p_auth_mode text, p_staff_id uuid DEFAULT NULL
) RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE src qr_loyalty_events%ROWTYPE; m qr_loyalty_members%ROWTYPE; already int; newc int;
BEGIN
    SELECT * INTO src FROM qr_loyalty_events WHERE id = p_event_id;
    IF NOT FOUND THEN RETURN jsonb_build_object('ok', false, 'code', 'event_not_found'); END IF;
    SELECT count(*) INTO already FROM qr_loyalty_events WHERE reverses_event_id = p_event_id;
    IF already > 0 THEN RETURN jsonb_build_object('ok', true, 'replayed', true); END IF;
    SELECT * INTO m FROM qr_loyalty_members WHERE id = src.member_id FOR UPDATE;
    UPDATE qr_loyalty_members
       SET stamps_current = GREATEST(stamps_current - src.delta, 0), updated_at = now()
     WHERE id = src.member_id RETURNING stamps_current INTO newc;
    INSERT INTO qr_loyalty_events (member_id, qr_id, workspace_id, event_type, delta, stamps_after,
                                   auth_mode, staff_id, reverses_event_id)
    VALUES (src.member_id, src.qr_id, src.workspace_id, 'reverse', -src.delta, newc,
            p_auth_mode, p_staff_id, p_event_id);
    RETURN jsonb_build_object('ok', true, 'stamps_current', newc);
END; $$;

-- ── (9) Plan flags — HOUSE CONVENTION. Full-object blob seed first (so
--        test_feature_gate_coverage._seed_feature_keys() regex-discovers BOTH keys),
--        then per-tier path writes. lower(name) + is_custom guard, never `name IN (...)`.
UPDATE plans
SET features = coalesce(features,'{}'::jsonb)
             || '{"loyalty_cards":false,"loyalty_members_max":0}'::jsonb
WHERE NOT (coalesce(features,'{}'::jsonb) ? 'loyalty_cards')
  AND coalesce(is_custom,false) = false;

UPDATE plans SET features = jsonb_set(
        jsonb_set(coalesce(features,'{}'::jsonb), '{loyalty_cards}', 'true'::jsonb, true),
        '{loyalty_members_max}', '2000'::jsonb, true)
WHERE lower(name) = 'pro' AND coalesce(is_custom,false) = false;

UPDATE plans SET features = jsonb_set(
        jsonb_set(coalesce(features,'{}'::jsonb), '{loyalty_cards}', 'true'::jsonb, true),
        '{loyalty_members_max}', '10000'::jsonb, true)
WHERE lower(name) = 'agency' AND coalesce(is_custom,false) = false;

-- ── (10) Creatable-type membership: Pro/Agency only (the lead_form double-gate
--         precedent from 0027 — type is normally NOT a paywall lever, but this type
--         captures verified phone numbers and spends outbound-message budget).
UPDATE plans
SET features = jsonb_set(coalesce(features,'{}'::jsonb), '{dynamic_qr_types}',
        (coalesce(features->'dynamic_qr_types','[]'::jsonb) || '["loyalty"]'::jsonb), true)
WHERE lower(name) IN ('pro','agency')
  AND coalesce(is_custom,false) = false
  AND NOT (coalesce(features->'dynamic_qr_types','[]'::jsonb) ? 'loyalty');

COMMIT;

-- Sanity (after COMMIT):
--   SELECT name, features->'loyalty_cards', features->'loyalty_members_max',
--          features->'dynamic_qr_types' ? 'loyalty'
--     FROM plans WHERE coalesce(is_custom,false)=false ORDER BY price_monthly;
--   SELECT column_name FROM information_schema.columns
--    WHERE table_name='qr_loyalty_details' AND column_name='stamps_current';  -- expect 0 rows
```

No change to `qr_codes`, `qr_scan_events`, `qr_scan_counters`, or `qr_coupon_details`. The cosmetic
`coupon_stamp` template keeps working for existing coupon QRs — this migration does not touch them.

---

## 3. Backend Design

### 3.1 New router — `qr_backend/src/api/routes/loyalty.py`
Registered in `src/api/endpoints.py`. **Two sections with different auth schemes**, and the split is
load-bearing:

**(a) Authenticated management** (Bearer + `require_can_*` + `await check_feature`), under the
`/workspaces/{ws}/…` stem so the public-prefix exclusion below can never reach them:
```
GET    /workspaces/{ws}/loyalty/{qr_id}/staff          # list (labels + last_used_at; never a hash)
POST   /workspaces/{ws}/loyalty/{qr_id}/staff          # add: label + pin → bcrypt; PIN returned ONCE
DELETE /workspaces/{ws}/loyalty/{qr_id}/staff/{id}     # revoke (soft: is_active=false, revoked_at)
GET    /workspaces/{ws}/loyalty/{qr_id}/members        # paginated; phone masked to last 4
GET    /workspaces/{ws}/loyalty/{qr_id}/events         # ledger, paginated + CSV export
POST   /workspaces/{ws}/loyalty/{qr_id}/events/{eid}/reverse   # owner correction → loyalty_reverse
```
`POST .../staff` enforces **PIN uniqueness within the QR** (bcrypt-compare the new PIN against every active
row — N is a handful, so the cost is irrelevant) because the console authenticates by PIN alone; two staff
sharing a PIN would make ledger attribution a lie. Minimum 4 digits, **6 recommended and defaulted in the UI**.

**(b) Staff-session routes** — public by Bearer-middleware standards, authorized by
`Authorization: LoyaltyStaff <session_token>`:
```
POST /loyalty/staff/session   { short_code, pin }  → { session_token, expires_at, staff_label }
POST /loyalty/stamp           { member_token | phone, idempotency_key }
POST /loyalty/redeem          { member_token, idempotency_key }
POST /loyalty/events/{eid}/undo
GET  /loyalty/counter-code                        → { code, expires_in }  (display mode)
```

**Excluded-route prefix — the sharp edge.** `BearerTokenAuthMiddleware._is_excluded` is a plain
`path.startswith(prefix)` match (`qr_backend/src/api/middlewares/auth_bearer.py` L68–70). Adding
`{API_PREFIX}/loyalty` is safe **only because** every authenticated loyalty route lives under
`{API_PREFIX}/workspaces/{ws}/loyalty/…`. That invariant must be asserted by a test (§10), not just
remembered — the Wallet TRD hit exactly this trap and had to narrow its prefix to `/wallet/apple`. If any
future authenticated route is added under `/loyalty/`, the prefix must be narrowed to the exact public stems.

**Session token:** `HMAC-SHA256(staff_id | qr_id | yyyy-mm-dd | nonce)` under a key derived from
`INTERNAL_SECRET`, base64url, constant-time compared, valid until end-of-day IST. Deliberately **not** a JWT —
no library, no algorithm-confusion surface, no refresh semantics, and it must expire on its own so a phone
left on the counter overnight is not a standing authority. Every stamp re-reads `qr_loyalty_staff` so a
**revoke is effective immediately**, not at token expiry.

**PIN throttle:** 5 failures per `(ip_hash, qr_id)` per 15 minutes → `429` + a lock window; failures are
counted in-process per dyno **and** backed by a `qr_loyalty_otps`-style count so a multi-dyno spray is still
bounded. Uniform response timing and an identical error body for "wrong PIN" and "no such QR" so the endpoint
cannot enumerate live loyalty programs.

### 3.2 Worker-proxied customer flows — `qr_backend/src/api/routes/internal.py`
Added beside `verify_qr_password_by_code` (L1173), inheriting the router-level
`Depends(verify_internal_secret)` (L21, L34) — so these are reachable **only** by the Worker:
```
GET  /internal/loyalty/{qr_id}                          # program fallback when KV content is stale
POST /internal/loyalty/{short_code}/enroll/start        # { phone, consent_text } → OTP dispatched
POST /internal/loyalty/{short_code}/enroll/verify       # { phone, code } → { member_token }
GET  /internal/loyalty/member/{member_token}            # card state for the member page
POST /internal/loyalty/member/{member_token}/counter-code  # { code, idempotency_key } → mode-B stamp
```
`enroll/start` gates on `check_feature(ws,'loyalty_cards')` **and** `loyalty_members_max` headroom
(`count(*)` of the workspace's members vs `get_limit`) before spending an OTP — never mint a message for a
workspace that cannot accept the member. Rate limits: 5 OTPs per `phone_hash` per hour, 20 per `ip_hash` per
hour, ≤3 verify attempts per OTP, 10-minute TTL, single consumption. Phone normalization to E.164 assumes
`+91` when no country code is supplied (India-first default, explicit in the UI).

`counter-code` validates TOTP for step `floor(now/60)` and `step-1` (clock skew + the customer typing), then
calls `loyalty_stamp(auth_mode='counter_code', p_counter_step=<step>)`. The `uq_loy_events_step` unique index
is what actually makes a shared screenshot useless — the second member to use the same code for the same step
is fine (different `member_id`), but the *same* member replaying it raises `unique_violation` and the whole
RPC rolls back. **Fail closed here, unlike the QR-expiry window's fail-open** — a failure to stamp costs a
customer one coffee they can ask staff to fix; a failure to *block* costs the merchant the program.

### 3.3 Helper module — `qr_backend/src/utilities/loyalty.py`
Pure, HTTP-free, unit-testable:
```python
def mint_member_token() -> str                       # 22-char base62 from secrets.token_bytes
def hash_phone(e164: str) -> str                     # sha256(e164 + settings.HASHING_SALT)
def normalize_phone(raw: str, default_cc="+91") -> str
def hash_pin(pin: str) -> str  /  verify_pin(pin, h) -> bool     # bcrypt (passlib, already vendored)
def mint_staff_session(staff_id, qr_id) -> tuple[str, datetime]  # HMAC, day-scoped
def verify_staff_session(token) -> StaffSession | None           # constant-time
def counter_code(secret_b32: str, step: int) -> str  # 6-digit TOTP, 60s step
def mint_redemption_code() -> str                    # 8-char, unambiguous alphabet (no O/0/I/1)
```
`counter_code_secret_enc` is Fernet-encrypted under `LOYALTY_ENC_KEY` (reuse `WALLET_ENC_KEY` if the Wallet
epic lands first — one key, one rotation story). Decrypted only inside this module, never returned by any
route, never written to KV.

### 3.4 KV + type wiring (the 7-step new-type seam)
- **`qr.py`**: add `"loyalty"` to the type `Literal` (L839–864, after `"review_funnel"`); add a
  `LoyaltyContent` pydantic model beside `CouponContent` (L390); add `qr_loyalty_details(*)` to
  `SELECT_WITH_RELATIONS` (L998); add the `loyalty` branch to `_build_content_from_db_rows` (mirroring the
  coupon branch ~L1318) and the row-pop at ~L1406.
- **`cloudflare_kv.py` `build_kv_content`** (L387): add `elif qr_type == "loyalty"` returning **program data
  only** —
  `{ program_name, business_name, reward_text, stamps_required, terms, stamp_auth_mode, enroll_enabled }`.
  **Hard rule, tested:** no member row, no phone, no `member_token`, no `pin_hash`, no
  `counter_code_secret_enc` ever enters KV. The `write_to_kv` payload (L93) is unchanged in shape.
- **`build_entitlements`**: unchanged. Loyalty is gated backend-side at every mutating call; pushing
  `loyalty_cards` to the edge would be dead weight (the edge never decides anything about loyalty).
- **`FEATURE_ENFORCEMENT`** (`subscription.py` L524–560):
  ```python
  "loyalty_cards":      "enforced",  # loyalty.py + internal.py enroll/stamp check_feature gate
  "loyalty_members_max":"enforced",  # internal.py enroll/start headroom via get_limit
  ```
  `loyalty_members_max` joins `_QUOTA_SPEC` as `{"source": "feature", "usage": None}` (value-only, like
  `max_file_size_mb` / `card_ocr_scans_per_month`) — the count comes from a direct `count(*)` on
  `qr_loyalty_members`, not the generic `check_limit` path. Registered `inert` then flipped `enforced` in the
  same PR so `test_feature_gate_coverage` stays green.

### 3.5 Re-engagement triggers (item #1 owns the transport)
`loyalty.py` and `internal.py` **enqueue**, never send. On a successful stamp, if
`stamps_after == stamps_required - 1` → `near_reward`; if `>= stamps_required` → `reward_ready`. Both are
deduped per `(member_id, trigger, cycle)` so a reversal-and-restamp doesn't re-notify. The **lapsed** trigger
is a batch sweep folded into the existing daily internal cron endpoint (`0 6 * * *`) — select members via
`idx_loy_members_lapsed` where `last_stamped_at < now() - lapsed_after_days` and `lapsed_nudge_enabled`, one
nudge per member per lapse cycle. **No new cron trigger, therefore no new `wrangler.toml` cron gate.** If item
#1's queue is unavailable, enqueue failures are logged and **never** block or roll back the stamp — a coffee
stamp must not fail because a message queue is down.

---

## 4. Cloudflare Worker / Edge Design

**The Worker never stamps, never counts, and holds no loyalty secret.** All four changes are render-or-proxy.

1. **Type dispatch** — add a `loyalty` branch to `qr_cf_code/src/handlers/qrRouter.js` mirroring the coupon
   branch (L233–243): render from `kvContent` when present, else fall back to
   `fetchInternal('/internal/loyalty/' + qr_id, env)`. New `src/pages/loyalty/index.js` dispatcher +
   `src/pages/loyaltyPage.js` re-export shim (the shape `couponPage.js` already uses:
   `export { getCouponPage } from "./coupon/index.js"`).

2. **Member-card route** `GET /m/:memberToken`, registered in `src/index.js` alongside `/vcard-download/:qrId`
   and `/click/:linkId`. Fetches `/internal/loyalty/member/{token}` with `x-internal-secret` and renders the
   live card. **This is the one route with a backend round-trip on a customer-facing path** — acceptable
   because it is not the scan hot path, it is per-member and low-volume, and the alternative (member state in
   KV) would put phone-derived identity at the edge. `Cache-Control: no-store`; an unknown token renders the
   generic branded "card not found" page with **uniform timing** so tokens cannot be enumerated.

3. **Returning-customer redirect** — in the main `GET /:shortCode` flow, **only** when `type === 'loyalty'`,
   read cookie `qr_loy_<shortCode>`; if present, 302 to `/m/<token>`. Every other type's hot path is
   byte-for-byte unchanged. The cookie is `HttpOnly; Secure; SameSite=Lax; Max-Age=31536000` and is set by
   the verify proxy, not by JS. It carries **identity, not authority** — stealing it shows you someone's
   stamp count and nothing else.

4. **Proxy routes** (all mirroring `/pw-verify/:shortCode`, `src/index.js` L98–133 — same
   `${env.BACKEND_URL}` + `x-internal-secret` + pass-through-status shape):
   - `POST /loyalty/enroll/:shortCode` → `…/enroll/start`
   - `POST /loyalty/verify/:shortCode` → `…/enroll/verify`; on success, `Set-Cookie` + 302 to `/m/<token>`
   - `POST /loyalty/code/:memberToken` → `…/member/{token}/counter-code`

**Scan accounting:** the existing `recordScan` (`ctx.waitUntil`, `src/utils/scan.js`) fires for the
`GET /:shortCode` scan exactly as today. `/m/:memberToken` views and stamp POSTs are **not** scans and record
none — a stamp is a business event in the loyalty ledger, not a scan, and conflating them would corrupt both
the billable scan cap and the analytics denominators.

**Templates + the mirroring rule:** `src/pages/loyalty/` ships `stampCardTemplate.js` (the honest successor to
the cosmetic `coupon/stampTemplate.js`, now driven by real `stamps_current`/`stamps_required`) and
`minimalTemplate.js`, plus `helpers.js`. `escapeHTML()` on every merchant and member field. Per the house
rule, **each Worker template must have a matching React preview** in
`qr_frontend/src/components/qr-generator/templates/loyalty/` and an entry in
`qr_frontend/src/lib/constants/page-templates.tsx`.

**Consent gate:** unaffected — loyalty pages carry no marketing pixels or cookies; the `qr_loy_*` cookie is
strictly functional. **`scheduled()` / crons:** none added. **Deploy:** staging → verify → `npm run deploy:prod`.

---

## 5. Frontend Design

All UI: shadcn/ui primitives, Tailwind tokens (`primary` indigo `#4648d4`, `tertiary` cyan), react-hook-form +
zod, TanStack Query via `authApi`, files ≤200 lines, one export, kebab-case filenames.

### 5.1 Gating — `src/lib/plan-features.ts`, `src/hooks/useSubscription.ts`
```ts
loyalty_cards: boolean;        // Pro+ loyalty stamp cards
loyalty_members_max: number;   // enrolled members per workspace (0 = none; no unlimited tier)
```
Add `'loyalty_members_max'` to the `getLimit` key union. The builder's Loyalty type tile uses the existing
`canAccessFeature(subscription, 'loyalty_cards')` upgrade-gate pattern.

### 5.2 Builder — `src/components/qr-generator/content-types/LoyaltyContent.tsx`
Program fields (name, business, reward text, `stamps_required` 3–20, terms) plus two extracted sub-components
to stay under the line limit:
- **`loyalty-antifraud-settings.tsx`** — stamping mode (radio: *Staff PIN — recommended* / *Counter code*),
  cooldown, per-day cap, redemption policy. Selecting counter-code renders an inline, non-dismissable note
  stating the trade-off in plain words (PRD §6.4) — this copy is a product requirement, not decoration.
- **`loyalty-staff-pins.tsx`** — add/label/revoke PINs via `useLoyaltyStaff`. The PIN is generated
  (6 digits, default) or typed, **shown exactly once** in a copy-able callout with "you won't see this again",
  and never re-fetchable. Server rejects a PIN already active on that QR.

### 5.3 Staff console — `src/app/stamp/[code]/page.tsx` (**public route**)
Lives outside `org/*` so no Supabase session is required. **Build-time check:** `src/middleware.ts`'s matcher
(L205–208) runs on everything but `_next`/`api`/static, so confirm `/stamp` falls through to the unauthenticated
branch and is not redirected to `/login` — add it to the public-path allowlist if the middleware's logic
requires it. Composed from small components (page files compose, they don't implement):
- `staff-pin-pad.tsx` — numeric pad → `POST /loyalty/staff/session`; session token in `sessionStorage`
  (not `localStorage` — a shared counter phone should not carry authority across browser restarts).
- `staff-member-scanner.tsx` — camera resolution of `/m/<token>`, **reusing the shipped scanner** in
  `src/components/marketing/qr-scanner/scanner-tool.tsx` rather than adding a second camera stack; falls back
  to a phone-number lookup field.
- `staff-stamp-panel.tsx` — masked card (`•••• 4821 · 7/10`), one dominant **Stamp** button, optimistic
  update with **Undo** for 120 s, structured refusal rendering (`cooldown` shows the human "Divya stamped this
  40 minutes ago"), and **Redeem** when complete. A client-generated `idempotency_key` (uuid) per tap makes
  double-taps and flaky-network retries free.
- `staff-counter-display.tsx` — full-screen rotating 6-digit code with a wipe-progress ring, polled from
  `GET /loyalty/counter-code`, wake-lock requested so the counter tablet doesn't sleep.

### 5.4 Dashboard — Loyalty tab on QR detail
Members (masked phone, stamps, last visit, status), the **ledger** (timestamp, member, event, auth mode, staff
label, reversal action), and headline counts. CSV export follows the existing lead-capture export gating.
Reversal is owner-only (`require_can_delete`) and writes an `override`-attributed ledger row.

### 5.5 Hooks — `src/hooks/`
`useLoyaltyStaff`, `useLoyaltyMembers`, `useLoyaltyLedger` (query-key factories per the `useQRs` convention:
`loyaltyKeys.staff(qrId)`, `loyaltyKeys.members(qrId, filters)`, `loyaltyKeys.ledger(qrId, filters)`), and
`useStaffStamp` (mutation; the console's hooks talk to the **staff-session** routes with the
`LoyaltyStaff` header, not `authApi`'s Supabase JWT — a separate thin client instance, since these routes are
deliberately outside the Bearer scheme). `workspaceId` from the workspace store per house rule.

---

## 6. External-Service Integration

**No AI on any path.** No Anthropic call, no model on the stamp or scan path.

**Outbound messaging — owned entirely by analysis item #1** (`WHATSAPP_REVIEW_REMINDERS_*`). This spec
consumes three things and builds none of them: (a) an **OTP-capable** send for enrolment verification,
(b) a **delayed/queued** send for the three re-engagement triggers, (c) **opt-out/STOP** state that loyalty
reads before enqueuing. If item #1 lands a generic phone-verification primitive, `qr_loyalty_otps` collapses
into it — a deliberate duplication risk, flagged in §12.

**Why not PassKit push:** the Wallet epic's re-engagement channel is APNs on Apple Wallet. In a ~95%-Android
market that reaches a small minority of holders, and it requires per-workspace Apple certificate onboarding
before a single message goes out. WhatsApp reaches essentially everyone and needs no per-merchant crypto
onboarding. **Phase A therefore has zero Apple dependency**; the `.pkpass` `storeCard` is a Phase-B
enhancement owned by the Wallet epic (bump `wallet_passes.update_tag` on each `loyalty_stamp` success).

**Encryption:** `LOYALTY_ENC_KEY` (Fernet) for `counter_code_secret_enc` — or reuse the Wallet epic's
`WALLET_ENC_KEY` if it ships first, to keep one key-rotation story. **No email** in v1 → the unpublished
`_dmarc.qravio.app` record is **not** a gate. **No PDF.** New backend env: `LOYALTY_ENC_KEY` only (session
HMAC derives from the existing `INTERNAL_SECRET`).

---

## 7. API Contracts

```jsonc
// ── Staff session (public route, PIN exchange) ────────────────────────────────
POST /api/v1/loyalty/staff/session
{ "short_code": "a1b2c3", "pin": "482913" }
200 → { "session_token": "…", "expires_at": "2026-07-25T18:29:00Z", "staff_label": "Divya — evening" }
401 → { "detail": { "code": "invalid_pin" } }          // identical body+timing for unknown short_code
429 → { "detail": { "code": "pin_locked", "retry_after": 900 } }

// ── Stamp (Authorization: LoyaltyStaff <session_token>) ───────────────────────
POST /api/v1/loyalty/stamp
{ "member_token": "7Kd…", "idempotency_key": "b1f0…" }
200 → { "ok": true, "stamps_current": 8, "stamps_required": 10, "reward_ready": false,
        "event_id": "uuid", "replayed": false }
409 → { "detail": { "code": "cooldown", "retry_after": 19140,
                    "message": "Stamped 40 minutes ago — minimum gap is 6 hours." } }
409 → { "detail": { "code": "daily_cap", "limit": 1 } }
401 → { "detail": { "code": "session_invalid" } }       // also on a revoked staff row
403 → { "detail": { "code": "loyalty_locked", "upgrade_to": "pro" } }

// ── Redeem (same auth) ───────────────────────────────────────────────────────
POST /api/v1/loyalty/redeem
{ "member_token": "7Kd…", "idempotency_key": "c2a1…" }
200 → { "ok": true, "redemption_code": "K7M4XQ92", "stamps_current": 0 }
409 → { "detail": { "code": "not_complete", "stamps_current": 7, "stamps_required": 10 } }

// ── Enrolment (Worker-proxied; x-internal-secret between Worker and backend) ──
POST /api/v1/internal/loyalty/{short_code}/enroll/start
{ "phone": "9876543210", "consent_text": "Send me WhatsApp updates about my stamps…" }
202 → { "sent": true, "expires_in": 600 }
403 → { "detail": { "code": "loyalty_locked" } }
409 → { "detail": { "code": "members_cap_reached", "limit": 2000 } }
429 → { "detail": { "code": "otp_rate_limited", "retry_after": 3600 } }

POST /api/v1/internal/loyalty/{short_code}/enroll/verify
{ "phone": "9876543210", "code": "418305" }
200 → { "member_token": "7Kd…", "stamps_current": 0, "stamps_required": 10 }
401 → { "detail": { "code": "otp_invalid", "attempts_left": 2 } }

// ── Member card (Worker render source) ───────────────────────────────────────
GET /api/v1/internal/loyalty/member/{member_token}
200 → { "program_name": "Nikhil's Coffee Club", "business_name": "Nikhil's Coffee",
        "reward_text": "A free regular coffee", "stamps_current": 8, "stamps_required": 10,
        "reward_ready": false, "stamp_auth_mode": "staff_pin", "terms": "…",
        "phone_last4": "4821" }        // NEVER the full phone, NEVER the ledger
404 → branded "card not found" (uniform timing)
```

**KV value for a `loyalty` QR** — program only, no state, no secret:
```jsonc
{ "type": "loyalty", "status": "active", "workspace_id": "uuid",
  "page_design": { "templateId": "loyalty_stampcard", "themeColor": "#0d9488" },
  "content": { "program_name": "Nikhil's Coffee Club", "business_name": "Nikhil's Coffee",
               "reward_text": "A free regular coffee", "stamps_required": 10,
               "terms": "…", "stamp_auth_mode": "staff_pin", "enroll_enabled": true } }
```

---

## 8. Security, Privacy & Abuse

- **The invariant:** there is **no code path** from an anonymous edge scan to `loyalty_stamp`. Every caller
  supplies either a verified `LoyaltyStaff` session or a TOTP step validated backend-side. This is enforced by
  route structure, not by a check that could be forgotten — the RPC's `p_auth_mode` has no anonymous value,
  and a test asserts every call site passes a non-null authorizer.
- **Staff PIN is honestly weak, and the design assumes it leaks.** A 6-digit PIN has ~10⁶ of entropy and will
  end up on a sticky note. Compensating controls: per-`(ip_hash, qr_id)` lockout after 5 failures; day-scoped
  sessions; per-staff `daily_stamp_cap` (default 200) with an owner alert on breach; immediate revoke honoured
  on the *next stamp*, not at token expiry; full ledger attribution so a leaked PIN's damage is bounded,
  visible, and reversible. We call it an *attribution token with a throttle*, not a credential.
- **Counter-code mode is the weakest surface and is labelled as such in-product.** 60s rotation, ±1 step
  tolerance, single-use per `(member, step)` enforced by a unique index (so the RPC rolls back rather than
  half-stamping), plus the same cooldown and daily caps. The secret is Fernet-encrypted and never leaves the
  backend — the Worker proxies the *code*, never the secret.
- **Tenant isolation:** service-role bypasses RLS, so every loyalty query filters explicitly by
  `workspace_id`/`qr_id`. Cross-workspace access is impossible on authenticated routes (workspace-scoped) and
  on staff routes (the session token binds `staff_id` **and** `qr_id`; a session for QR A cannot stamp a
  member of QR B — asserted by test).
- **DPDP / PII (the real liability):** we hold third-party phone numbers under a merchant's purpose. Stored
  once in `qr_loyalty_members.phone_e164`, with `phone_hash` for all lookups; **never** copied into KV, scan
  events, the ledger, analytics, or any log line. The exact `consent_text` is recorded per member (the
  `qr_lead_submissions` pattern from `0012`). STOP sets `opted_out_at` — messages stop, **the card keeps
  working** (loyalty is not conditioned on marketing consent). `ON DELETE CASCADE` from both `qr_codes` and
  `workspaces` means deleting a QR or workspace removes members, ledger, PINs, and OTPs. *(Flagged for
  eng-review: the repo's known account-deletion cascade gap must not be extended by these tables.)*
- **Enumeration:** `member_token` is 22 chars of CSPRNG base62 (~130 bits); unknown tokens and unknown short
  codes both return the same branded 404 with uniform timing. Redemption codes use an unambiguous alphabet
  and are single-use via a partial unique index.
- **Append-only ledger:** a `BEFORE UPDATE OR DELETE` trigger rejects everything except the
  `redemption_used_at` burn. A ledger that the application layer can silently rewrite is not evidence, and
  merchant disputes are exactly the case where it must be.
- **Rate limits summary:** OTP 5/phone/h + 20/ip/h, ≤3 verify attempts; PIN 5 failures/ip/qr/15 min; stamp
  bounded by cooldown + per-day + per-session caps; counter-code single-use per step. The lead-submit limiter
  (`internal.py` L1331–1344) is the *shape* to follow but **not reusable** — it counts `qr_lead_submissions`
  rows, and loyalty's countable rows live in a different table with different semantics.
- **No SSRF, no new unauthenticated write to user content, no consent-gate interaction** (loyalty pages carry
  no marketing pixels; `qr_loy_*` is a functional cookie).
- **Log hygiene:** no PIN, no OTP, no phone, no session token, no TOTP secret in any log line — asserted by a
  log-scrub test, the same bar the Wallet TRD sets for certificates.

---

## 9. Performance, Scale & Cost

- **Scan hot path:** unchanged for every non-loyalty type. For `loyalty`, one extra cookie read; a returning
  member costs one 302 plus one backend fetch on `/m/:token` — off the KV fast path and low-volume by nature
  (a customer visits a cafe, not a CDN).
- **Stamp latency:** p95 target **< 500 ms** (staff are standing in front of a queue). One HMAC verify, one
  staff-row read, one RPC. The RPC does a single `SELECT … FOR UPDATE`, one indexed count for the daily cap,
  one update, one insert — all on primary-key or covered indexes.
- **Lock contention:** the row lock is per-*member*, so two staff stamping two different customers never
  contend. The only contended case is two staff stamping the *same* customer simultaneously — which is
  precisely the case that must serialize, and the second call correctly hits the cooldown.
- **Storage:** `qr_loyalty_members` ≈ one row per enrolled customer (capped by `loyalty_members_max`);
  `qr_loyalty_events` grows at roughly one row per visit — a busy cafe at 200 stamps/day is ~73k rows/year,
  trivially indexed by `(qr_id, created_at DESC)`. OTP rows are short-lived and should be swept in the daily
  cron (delete `consumed_at IS NOT NULL OR expires_at < now() - 7 days`).
- **Message cost is the only real COGS**, and it is item #1's meter, not a second one here. Bounded by
  `loyalty_members_max` × (1 OTP + ≤3 triggers/cycle). The lapsed nudge is the biggest volume lever, which is
  why it defaults **off**.
- **KV:** the loyalty content block is a few hundred bytes; no per-member data means KV size is independent of
  program success — a deliberate property, since the alternative would grow a KV value with every enrolment.

---

## 10. Testing Strategy

**Backend (pytest, `qr_backend/tests/`) — the fraud tests are the point:**
- `test_loyalty_no_anonymous_stamp`: **the invariant.** No route reachable without a staff session or a valid
  counter code produces a `stamp` event; a direct `POST /loyalty/stamp` with no/invalid `LoyaltyStaff` header
  → 401 and zero ledger rows. A static assertion that every `loyalty_stamp` call site passes a non-null
  authorizer.
- `test_loyalty_idempotency`: the same `idempotency_key` twice → one event, second returns `replayed:true`
  with the identical count. Concurrent duplicate calls → still one event.
- `test_loyalty_cooldown_and_caps`: a second stamp inside `min_stamp_interval_seconds` → 409 `cooldown` with a
  correct `retry_after`; `max_stamps_per_day` enforced across the IST day boundary; per-staff daily cap trips.
- `test_loyalty_counter_code`: a valid current-step code stamps; `step-1` accepted; `step-2` rejected; the
  **same member replaying the same step** → `unique_violation` → **rolled back, no stamp, no partial state**;
  a *different* member using the same code in the same step succeeds (correct — they're both at the counter).
- `test_loyalty_redeem`: below-threshold → 409; success burns a single-use code and applies rollover vs reset;
  a second redeem with a fresh key → 409 `not_complete`; the redemption code cannot be reused.
- `test_loyalty_ledger_append_only`: `UPDATE`/`DELETE` on `qr_loyalty_events` raises; only
  `redemption_used_at` may change; `loyalty_reverse` writes a compensating row and floors `stamps_current` at 0.
- `test_loyalty_session_scope`: a session minted for QR A cannot stamp a member of QR B; a revoked staff row
  invalidates on the **next** stamp, not at expiry; an expired (previous-day) token → 401.
- `test_loyalty_otp`: rate limits (per phone, per IP), ≤3 attempts, TTL, single consumption, constant-time
  compare; an unverified member (`phone_verified_at IS NULL`) can **never** be stamped.
- `test_loyalty_gating`: Free/Starter → 403 on author, enrol, and stamp; `loyalty_members_max` reached → 409
  **before** an OTP is spent; a mid-cycle downgrade blocks new stamps but leaves existing members redeemable.
- `test_loyalty_kv_has_no_pii`: strict allowlist over the built KV content — no phone, `member_token`,
  `pin_hash`, `counter_code_secret_enc`, or ledger data. Mirrors the Wallet TRD's PII-allowlist test.
- `test_loyalty_public_prefix`: **route-shape assertion** — every route under `{API_PREFIX}/loyalty/` is
  intended-public, and every authenticated loyalty route is under `{API_PREFIX}/workspaces/…`. This test is
  what makes the broad `startswith` exclusion safe over time.
- `test_feature_gate_coverage` stays green (both keys blob-seeded on every non-custom plan, both registered
  with real source references).

**Worker (vitest, `qr_cf_code`):** the loyalty page renders both templates from `kvContent` and falls back to
`/internal/loyalty/{qr_id}` when content is stale; `/m/:token` renders live state and 404s uniformly on an
unknown token; the returning-customer cookie 302 fires **only** for `type === 'loyalty'`; proxy routes forward
`x-internal-secret` and pass status through; **no worker output ever contains a phone, PIN, or secret**;
`escapeHTML` on every merchant/member field.

**Frontend (Vitest/Playwright):** the console's PIN pad → session → stamp flow with a mocked backend; a
double-tap sends one `idempotency_key` and renders one stamp; the cooldown 409 renders the human message;
undo calls reverse; counter-display polls and rotates; the builder threads anti-fraud settings into the QR
payload; a PIN is shown exactly once and never re-fetchable; Loyalty tab masks phones to last-4. **Note the
~29 pre-existing FE test failures as the documented baseline** — only net-new failures in loyalty files count
as regressions.

**Manual — the red-team gate (PRD §10 Phase 2, blocks GA):** actively try to farm a beta program — replay the
stamp POST, share a counter code with a second phone, re-enrol the same number, race two concurrent stamps,
reuse a redemption code, brute the PIN, and stamp by scanning the poster. Findings block GA.

---

## 11. Observability & Rollout

**Hard sequencing gate:** starts **after item #1 is in production** (OTP + queue + opt-out). Not a
nice-to-have ordering — enrolment cannot verify a phone without it, and shipping loyalty first means
re-implementing half of #1 worse.

**Phase 0 — Schema + flags (inert).** Apply the migration (re-verify the slot first). Register both flags
`inert`. Run the sanity SELECTs, including the one asserting `qr_loyalty_details.stamps_current` is gone. No UI.

**Phase 1 — Stamping core (internal/staging).** `loyalty.py`, internal endpoints, `utilities/loyalty.py`, the
three RPCs, type wiring, `build_kv_content` branch, Worker pages + proxies. `npm run deploy` to staging.
Verify with a real phone: enrol → staff-PIN stamp → cooldown holds → replay is a no-op → counter code
single-use → redeem burns → reverse works → **scanning the poster stamps nothing**. Flip both flags
`inert`→`enforced` in this PR.

**Phase 2 — Design-partner beta (closed).** 3–5 merchants, deliberately including one single-operator
(counter-code) and one multi-staff cafe (staff-PIN). WhatsApp triggers on. Loyalty tab + ledger. Red-team gate
before widening.

**Phase 3 — GA.** Remove the FE beta flag, `npm run deploy:prod`, deprecate the cosmetic `coupon_stamp`
template in the picker (existing QRs unaffected), comparison-matrix + SEO + help-centre updates.

**Deploy order:** migration → backend → **Worker (`npm run deploy:prod`)** → frontend. A Worker deployed
before the backend would render a type whose internal endpoints 404; a backend deployed first simply has no
traffic. Migration first regardless. **No DMARC gate** (no email). **No new cron gate** (lapsed sweep rides
the existing daily internal cron).

**Metrics / logs:** stamps by `auth_mode` (the counter-code share is a risk signal); reversal rate
(target < 2%); median stamps per staff session (target ≥ 5 — a dead console shows up here before it shows up
in churn); PIN-failure rate and lockouts per QR (a spike is either a brute-force or a UX failure, and the
ledger distinguishes them); OTP send→verify conversion; enqueue failures to item #1's queue; p95 stamp
latency. Structured log per stamp: `qr_id`, `auth_mode`, `staff_id`, outcome code, latency — **never** a
phone, PIN, token, or secret. Invariants asserted continuously: 100% of `stamp` rows carry an authorizer;
zero PII in KV; zero secrets in logs.

---

## 12. Open Technical Questions & Risks

1. **OTP ownership — does item #1 ship a reusable phone-verification primitive?** If yes, `qr_loyalty_otps`
   and the start/verify pair collapse into it and this spec loses ~80 lines. *Recommend coordinating before
   either builds; duplicating OTP storage across two features is the most likely concrete waste in this
   batch.* **Decide at kickoff, not at merge.**
2. **Migration slot** — `0043` is provisional and this repo has lost two reservations already (`0023`→
   `outbound_webhooks`, `0024`→shipped as `0026`). **Re-run `ls qr_backend/migrations/` before applying.**
3. **Wallet epic ownership of `qr_loyalty_details`** — resolved in favour of *shared, create-or-extend*, with
   this spec authoritative on `stamps_current` (it must not exist). **The Wallet TRD needs a matching edit**;
   otherwise re-applying it reintroduces the per-QR counter. Needs an owner.
4. **Broad `{API_PREFIX}/loyalty` exclusion** — safe only while every authenticated route sits under
   `/workspaces/…`. `test_loyalty_public_prefix` is the guard. *Alternative: enumerate the five exact public
   stems. Recommend the broad prefix + the test, since the stems will churn during build and a stale
   enumeration fails closed in the worse direction (a 401 on a customer flow).*
5. **Counter-code mode: ship or cut?** *Recommend ship, honestly labelled.* It is materially weaker and it
   will produce the first fraud complaint — but the alternative for a single-operator salon is a paper card
   and a rubber stamp. Revisit with beta dispute data; retiring it later is a copy change plus a config
   migration, not a re-architecture.
6. **Daily-cap timezone** — the RPC hard-codes `Asia/Kolkata` for the "per day" boundary. Correct for the
   India-first ICP and consistent with the merchant's mental model, but it is a **hidden assumption** for any
   future non-IST merchant. *Recommend a per-QR timezone column when the first non-IST merchant appears; do
   not pre-build it.* (Contrast `QR_EXPIRY_SCHEDULING_TRD.md`, which stores an authoring zone — that feature
   needed it; this one doesn't yet.)
7. **Fail-closed on stamp errors** — confirmed, and deliberately opposite to QR expiry's fail-open. A missed
   stamp is a staff re-tap; a wrongly-granted stamp is unrecoverable inventory. Any future "retry on
   ambiguity" must preserve idempotency-key semantics rather than relaxing them.
8. **`stamps_lifetime` vs the ledger** — a denormalized counter that could drift from `sum(delta)`. Kept for
   cheap dashboard reads. *Recommend a periodic reconciliation check (ledger sum vs member counters) in the
   daily cron, alerting rather than auto-correcting — drift means a bug worth seeing, not papering over.*
9. **Downgrade semantics** — existing members keep stamps and can redeem; new enrolments/stamps blocked. This
   means a below-Pro workspace still executes redeem paths. Confirm this is the intended gate asymmetry
   (PRD §6.8 argues yes; it is a deliberate exception to the usual "gate everything" rule).

### Appendix — Key Files

| Concern | File |
|---|---|
| Migration (5 tables/extends, 3 RPCs, append-only trigger, flag seed) | `qr_backend/migrations/0043_loyalty_stamp_card.sql` (NEW — **slot provisional**) |
| Management + staff-session routes | `qr_backend/src/api/routes/loyalty.py` (NEW), registered in `src/api/endpoints.py` |
| Worker-proxied customer flows | `qr_backend/src/api/routes/internal.py` (NEW loyalty endpoints beside `verify_qr_password_by_code` L1173; router-level `verify_internal_secret` L21/L34) |
| PIN/session/TOTP/token helpers | `qr_backend/src/utilities/loyalty.py` (NEW) |
| Public-prefix exclusion | `qr_backend/src/main.py` (`excluded_routes`), matcher at `src/api/middlewares/auth_bearer.py` L68–70 |
| Type wiring | `qr_backend/src/api/routes/qr.py` (Literal L839–864; `CouponContent` L390 is the model shape; `SELECT_WITH_RELATIONS` L998; content build ~L1318/L1406) |
| KV program block (no PII) | `qr_backend/src/utilities/cloudflare_kv.py` (`build_kv_content` L387, `write_to_kv` payload L93) |
| Gating | `qr_backend/src/api/routes/subscription.py` (`FEATURE_ENFORCEMENT` L524–560, `_QUOTA_SPEC`) |
| Coverage guardrail | `qr_backend/tests/unit_tests/test_feature_gate_coverage.py` (must stay green) |
| Edge proxies + member card | `qr_cf_code/src/index.js` (mirror `/pw-verify/` L98–133; new `/m/:memberToken`, `/loyalty/*`) |
| Type dispatch | `qr_cf_code/src/handlers/qrRouter.js` (coupon branch L233–243 is the shape) |
| Loyalty pages/templates | `qr_cf_code/src/pages/loyalty/{index,stampCardTemplate,minimalTemplate,helpers}.js` (NEW) + `src/pages/loyaltyPage.js` re-export shim |
| Cosmetic predecessor (deprecated) | `qr_cf_code/src/pages/coupon/stampTemplate.js` (L14 hardcoded `[false ×6]`), registered in `coupon/index.js` |
| Builder UI | `qr_frontend/src/components/qr-generator/content-types/LoyaltyContent.tsx`, `loyalty-antifraud-settings.tsx`, `loyalty-staff-pins.tsx` (all NEW, ≤200 lines) |
| Staff console (public route) | `qr_frontend/src/app/stamp/[code]/` (NEW) + `staff-{pin-pad,member-scanner,stamp-panel,counter-display}.tsx`; reuses `src/components/marketing/qr-scanner/scanner-tool.tsx`; verify `src/middleware.ts` matcher (L205–208) |
| React template mirrors | `qr_frontend/src/components/qr-generator/templates/loyalty/`, `src/lib/constants/page-templates.tsx` (`LOYALTY_TEMPLATES`), `TemplatePicker.tsx`, `PagePreview.tsx` |
| Hooks | `qr_frontend/src/hooks/{useLoyaltyStaff,useLoyaltyMembers,useLoyaltyLedger,useStaffStamp}.ts` (NEW) |
| FE gating | `qr_frontend/src/lib/plan-features.ts`, `src/hooks/useSubscription.ts` (`loyalty_cards`, `loyalty_members_max`) |
| Outbound channel (item #1) | `PRD_TRD/NOT_DONE/WHATSAPP_REVIEW_REMINDERS_*` — OTP + queue + opt-out owned there |
| Wallet epic (folded into) | `PRD_TRD/NOT_DONE/WALLET_PASSES_{PRD,TRD}.md` — `loyalty` type seam, `qr_loyalty_details`, Phase-B `.pkpass` |
| Worker deploy | `qr_cf_code` — **`npm run deploy:prod` required**; no `wrangler.toml` change (no new cron) |
