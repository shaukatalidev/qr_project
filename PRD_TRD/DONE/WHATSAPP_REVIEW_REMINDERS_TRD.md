# TRD — WhatsApp Review-Reminder Automation

**Status:** Draft · **Author:** Engineering (Staff) · **Date:** 2026-07-25
**Priority:** The **#1 "core bet"** (analysis §1) and the largest single build on the backlog. Three pieces of infrastructure that do not exist today — a consented-contact store, a **delayed-send queue** (webhooks are synchronous forwards; there is no scheduler), and a **per-message meter** — plus one new public signature-verified inbound webhook and an external, multi-day Meta approval gate. Phase 0 deliberately ships **capture only, no sending**, so the messaging stack is built against a measured opt-in rate rather than a hoped-for one.
**Tiers:** **Pro, Agency** (`review_reminders`). `reminder_messages_per_month` is a **fair-use/abuse ceiling, not a billing meter** — under the recommended **BYO-BSP** model the merchant's own WhatsApp Business API account sends and Meta bills them, so Qravio carries **zero per-message COGS** (PRD §8).
**Plan flags (NEW):** `review_reminders` (bool) + `reminder_messages_per_month` (int). Seeded on every non-custom plan as a **full-object `'{...}'::jsonb` blob** (a path-only `jsonb_set` seed is undiscoverable by `test_feature_gate_coverage._seed_feature_keys()`, which regex-scans blobs) and registered `inert`→`enforced` in the **same PR**.
**Migration slot:** **`0038`** (`0038_whatsapp_review_reminders.sql`). Verified against disk: highest existing = `0032_lemonsqueezy_variant_backfill.sql`; `0033` is claimed by the QR-expiry draft and `0034`–`0037` by the sibling quick-win specs drafted in the same session. **Re-verify at build time** — do not trust this header if other migrations land first (the repo has a commit fixing stale slot numbers, and `AI_BUSINESS_CARD_OCR_TRD` shipped as `0026` after drafting `0024`).
**Services touched:** `qr_backend` (contacts ingest, reminder API, BSP adapter + send queue, sweep endpoint, inbound webhook, migration, gating) · `qr_cf_code` (capture row on the rating template, `POST /review-contact/:shortCode`, `GET /rr/:token`, one added `ping` in the existing `*/5` cron branch — **requires `npm run deploy:prod`**, but **no `wrangler.toml` change**) · `qr_frontend` (capture settings in the builder, mirrored React preview, messaging settings wizard, contacts UI, Reminders card, hooks, `PlanFeatures`). **No AI. No new cron trigger. No new QR type.**
**Implements PRD:** WhatsApp Review-Reminder Automation. **Mirrors** the `webhook_deliveries` claim-lease/backoff/terminal-state queue (`qr_backend/src/utilities/webhook_dispatch.py`), the `card_ocr_usage`/`ai_analyst_usage` metering pattern, and the `razorpay/webhooks` public-signature-verified route precedent.

**Rev (2026-07-25, post eng-review):** Reviewed via `/plan-eng-review` + an outside-voice pass (verified against `webhook_dispatch.py`, `internal.py`, `classicTemplate.js`, `main.py`, `test_feature_gate_coverage.py`). Product decisions in the PRD Rev (Embedded-Signup onboarding · post-tap interstitial capture · cascade-gated Phase 0 + purge-on-abort · A/B guardrail).
**P0 corrections (required):**
1. **Phase-0 circular dependency** — `build_kv_content` gated the capture block on `_messaging_ready` (Phase-1 state), so the row would never render in Phase 0 and every Phase-0 metric was unobtainable. Gate on `reminder_schedules.enabled` + entitlement only.
2. **Forgeable consent** — `/review-contact/` is an unauthenticated open POST and consent is client-asserted. Mint a short-TTL HMAC at render time (`index.js:18-34` `getPwToken` pattern), bind the beacon to it, reject on mismatch; the backend owns the consent text (a server-side template with `{business_name}` + privacy link, not a bare constant).
3. **Sweep claim predicate** — a fresh row has `next_attempt_at = NULL`; predicate must be `scheduled_for <= now AND (next_attempt_at IS NULL OR next_attempt_at <= now)`, **`sending` must be in the claimable set** (else a crashed sweep strands rows, contradicting `test_reminder_queue_claim`), and the index becomes `(scheduled_for, next_attempt_at)`.
4. **Per-workspace BSP webhook** — one global `BSP_WEBHOOK_SECRET` is incompatible with BYO-BSP, and an inbound STOP carries no `provider_message_id`. Use a per-workspace callback path `/{API_PREFIX}/bsp/webhook/{ws_token}` (unguessable, stored on `workspace_messaging_config`) + a per-workspace secret; resolve the workspace from the **path** (sender_number only as cross-check). Fix the `/api/bsp/webhook` vs `settings.API_PREFIX` mismatch or Bearer middleware 401s every callback before signature check.
**P1/P2 corrections:** batch by **time, not count** (200 serial × ~10 s ≫ the synchronous Worker→Render request budget — ~10-way `asyncio.gather`, hard-stop ~25 s, partial counts); **resync KV on messaging-state transitions** (`resync_workspace_qrs()` on config/template-status change and on the 5%-opt-out auto-pause — else an approval landing days later never renders the row, and a paused sender keeps collecting); **enumerate the upsert's update columns** (never `status`/`last_messaged_at`/`consent_at` — the current upsert resurrects opted-out contacts and resets the cooldown = a real double-send; define the idempotency window as a deterministic bucket of `scheduled_for`); **add `ip_hash` + `user_agent` columns to `reminder_contacts`** (the "reuse `lead_submit` IP rate-limit" is otherwise unimplementable); **`CHECK (quiet_start_hour <> quiet_end_hour)`** + a max-defer count (avoid the defer-forever deadlock that also silences the `due:0` alarm); **staleness expiry** `expires_at = scheduled_for + 24h` → `suppressed` (else a post-unpause burst fires stale reminders and drains the cap); **assume-sent** increments the meter and is excluded from the delivery-rate denominator (no `provider_message_id` to match a receipt); **hide the capture row when the feedback step reveals** (the below-threshold arm otherwise stacks 4 inputs + 2 consent boxes on one mobile card); **`/rr/` uses the QR's custom domain** when set (else custom-domain merchants send a `qravio.app` link — the localhost-in-prod lesson); **alarms hang off `/internal/run-alerts`** (daily-pinged), not Worker console logs (the reclamation-sweep 404 proves nobody reads them). **Gating:** `reminder_messages_per_month` is **`inert` in Phase 0** (no gate reference until `messaging/queue.py` exists → `test_enforced_flags_have_a_real_gate` fails otherwise); flip to `enforced` in the Phase-1 PR. **Migration split:** Phase 0 creates **only** `reminder_contacts` + `messaging_opt_outs` + flags; the four send-side tables ship in the Phase-1 migration (the plan allows Phase 1 never being built, so four dead tables + a Phase-0 read of a Phase-1 table is the real cost, and the direct cause of P0-1). **Confirmed:** cooldown key is workspace-wide `(workspace_id, phone_hash)`. **Simplification to weigh:** fold `reminder_schedules` into columns/jsonb on `qr_review_funnel` (saves a table + 2 queries per KV build). **sendBeacon** stays — click-time same-origin is reliable; the ~10% loss budget was pessimistic; instrument it anyway.

---

## 1. Overview & Architecture

The `review_funnel` rating step gains an **optional, skippable capture row** — a phone input plus a **separate, unticked marketing-consent checkbox** — rendered from a new `content.reminder_capture` block in the existing KV payload. Tapping a star fires `navigator.sendBeacon("/review-contact/<shortCode>", …)` and then navigates exactly as it does today; `sendBeacon` is mandatory here because a `fetch` would be cancelled by the navigation. The Worker forwards to `POST /internal/reminder-contact` behind `x-internal-secret`, which normalizes to E.164, checks the suppression list, and upserts a `reminder_contacts` row carrying the **verbatim consent text, timestamp, source QR, and rating bucket**.

**Phase 0 stops there.** Nothing sends. Phase 1 adds the queue: an enqueue step writes a `reminder_messages` row with `scheduled_for = now + delay`, and `/internal/reminder-sweep` — pinged every 5 minutes by the **existing** `*/5 * * * *` cron branch that already drives `webhook-sweep` — claims due rows with a conditional-UPDATE lease, applies quiet hours and frequency caps, and calls the workspace's **own** BSP account. Delivery receipts and STOP replies arrive on a public, signature-verified `POST /api/bsp/webhook`. The reminder link is `GET /rr/:token` on the Worker, which records the click and 302s to the QR's **already-validated, stored** `google_review_url` — never a URL from the request.

**The single most important architectural decision: the merchant is the sender.** Credentials are per-workspace, encrypted at rest with the existing Fernet key. Qravio never sends from a shared WABA in v1 (PRD §3 Non-Goals) — one tenant's block rate must not be able to degrade every other tenant's deliverability.

**Services touched**

| Service | Change |
|---|---|
| `qr_backend` | Migration `0038` (6 tables + 2 RPCs + flag seed); `POST /internal/reminder-contact` + `POST /internal/reminder-sweep`; new `routes/reminders.py` (workspace CRUD/usage/test-send) and `routes/bsp_webhook.py` (public, signature-verified); new `utilities/messaging/` package (provider interface, one BSP adapter, E.164 utils, template registry, queue logic mirroring `webhook_dispatch.py`); `build_kv_content` `review_funnel` branch gains `reminder_capture`; `marketing_consent` threaded through `/lead-submit`; `review_reminders` + `reminder_messages_per_month` in `FEATURE_ENFORCEMENT`/`_QUOTA_SPEC`; two new settings + one excluded route. |
| `qr_cf_code` | Capture row in `pages/reviewFunnel/classicTemplate.js`; `POST /review-contact/:shortCode` (204, beacon target); `GET /rr/:token` (attribution → 302); one `ping("/internal/reminder-sweep", …)` in the existing `*/5` branch of `scheduled()`. **`npm run deploy:prod` required; `wrangler.toml` unchanged.** |
| `qr_frontend` | Capture settings on the `review_funnel` builder; **mirrored React preview of the capture row** (house rule); `MessagingSection` setup wizard + contacts table + opt-out list; Reminders card on QR detail; `useReminders.ts`; `PlanFeatures` additions. |

**Data flow — capture (Phase 0)**

```
Rating step (KV-rendered) → user types phone + ticks consent (both optional)
  → star tap: navigator.sendBeacon("/review-contact/<shortCode>",
       {phone, consent:true, consent_text, stars})     [fires BEFORE navigation]
  → immediately: window.location.href = "/review-go/<shortCode>?stars=N"  [unchanged path]
  → Worker /review-contact/: 204 always; forwards to backend with x-internal-secret
  → POST /internal/reminder-contact:
       1. resolve short_code → qr_codes row (404 if not review_funnel)
       2. check_feature(ws,'review_reminders')      [403 → drop, log, no store]
       3. reject if consent !== true OR consent_text empty  [422]
       4. normalize phone → E.164 (default region from workspace config); invalid → 422
       5. phone_hash = sha256(e164 + HASHING_SALT)
       6. if messaging_opt_outs has (workspace_id, phone_hash) → 200 {"stored": false}
       7. upsert reminder_contacts on (workspace_id, qr_id, phone_hash)
       8. Phase 1 only: enqueue reminder_messages (scheduled_for = now + delay)
```

**Data flow — send (Phase 1)**

```
Worker cron "*/5 * * * *" → ping /internal/reminder-sweep (x-internal-secret)
  → sweep(db, batch_size=200):
      SELECT queued rows WHERE next_attempt_at <= now ORDER BY scheduled_for LIMIT 200
      for each:  _claim()  [conditional UPDATE → 'sending', lease pushed out]
                 guards: opt-out? cooldown? quiet hours? monthly cap? template approved?
                 → skip/defer/suppress WITHOUT calling the provider
                 provider.send_template(...) → provider_message_id
                 increment_reminder_usage(ws, period)
      terminal: sent → (webhook) delivered → read → clicked
      failures: attempt_count++, backoff, MAX_ATTEMPTS → dead_letter
  → BSP inbound POST /api/bsp/webhook (signature-verified):
      status receipts → reminder_messages.status
      "STOP"/"UNSUBSCRIBE" inbound → messaging_opt_outs insert + suppress queued rows
  → GET /rr/:token (Worker) → mark clicked + suppress siblings → 302 stored google_review_url
```

---

## 2. Data Model & Migrations

Six tables and two RPCs. All backend queries use the Supabase **service-role** client, which **bypasses RLS**; we `ENABLE ROW LEVEL SECURITY` with **no policies** on every new table so the anon/authenticated roles can never read them, and tenant isolation is enforced in route code via explicit `workspace_id` filters — the same posture as `card_ocr_usage` and `webhook_deliveries`. Phone numbers are stored in **plaintext E.164** (we must be able to send to them) **plus** a `phone_hash` used for lookup, dedup, and suppression; the opt-out table stores **only the hash**, so a suppression record survives the deletion of the contact it suppresses without retaining the number.

**Deliberate, documented divergence from the house "ship only this phase's schema" rule:** `0038` creates the Phase-1 send-side tables (`reminder_schedules`, `reminder_messages`, `workspace_messaging_config`, `reminder_usage`) even though Phase 0 writes only `reminder_contacts` and `messaging_opt_outs`. Rationale: the two phases are days apart in one feature branch, empty tables cost nothing, and reserving a second slot in a session where five sibling specs are competing for `0034`–`0037` is a worse risk than the divergence. **If the phases separate in time, split this file at the marked boundary and take a fresh slot for the second half.**

**`qr_backend/migrations/0038_whatsapp_review_reminders.sql`** — `BEGIN/COMMIT`-wrapped, idempotent (`IF NOT EXISTS`), applied by hand in the Supabase SQL editor.

```sql
-- Migration 0038: WhatsApp Review-Reminder Automation.
-- Consented phone capture on review_funnel QRs (Phase 0) + a delayed-send queue,
-- per-workspace BYO-BSP config, and a fair-use message meter (Phase 1).
-- Sender model: the MERCHANT's own WhatsApp Business API account. Qravio never
-- sends from a shared WABA in v1 — one tenant's block rate must not be able to
-- degrade every other tenant's deliverability.
-- Idempotent; safe to re-run.
BEGIN;

-- ── Consented contacts (Phase 0) ──────────────────────────────────────────────
-- One row per (workspace, qr, phone). Consent provenance is NOT optional: a row
-- without verbatim consent_text + consent_at is a DPDP liability, so both are
-- NOT NULL and the ingest route rejects anything else with 422.
CREATE TABLE IF NOT EXISTS reminder_contacts (
    id            uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    workspace_id  uuid        NOT NULL REFERENCES workspaces(id) ON DELETE CASCADE,
    qr_id         uuid        NOT NULL REFERENCES qr_codes(id)   ON DELETE CASCADE,
    channel       text        NOT NULL DEFAULT 'whatsapp',   -- channel-agnostic for a future SMS phase
    phone_e164    text        NOT NULL,                      -- normalized; we must be able to send to it
    phone_hash    text        NOT NULL,                      -- sha256(e164 + HASHING_SALT) — lookup/dedup/suppression
    consent_text  text        NOT NULL,                      -- VERBATIM checkbox label shown (audit)
    consent_at    timestamptz NOT NULL DEFAULT now(),
    consent_source text       NOT NULL DEFAULT 'review_funnel_rating',  -- | 'review_funnel_feedback'
    -- Rating bucket at capture time. 'happy' contacts may receive the review
    -- template; 'unhappy' contacts NEVER may (PRD R2 — soliciting a public review
    -- from a below-threshold scanner is exactly the review-gating failure mode).
    sentiment     text        NOT NULL DEFAULT 'happy'
                    CHECK (sentiment IN ('happy','unhappy')),
    stars         smallint,
    locale        text,
    session_id    text,                                      -- joins to the scan event
    status        text        NOT NULL DEFAULT 'active'      -- active|opted_out|deleted
                    CHECK (status IN ('active','opted_out','deleted')),
    last_messaged_at timestamptz,
    created_at    timestamptz NOT NULL DEFAULT now(),
    UNIQUE (workspace_id, qr_id, phone_hash)
);
ALTER TABLE reminder_contacts ENABLE ROW LEVEL SECURITY;  -- no policies → service role only
CREATE INDEX IF NOT EXISTS idx_reminder_contacts_ws_created
    ON reminder_contacts (workspace_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_reminder_contacts_hash
    ON reminder_contacts (workspace_id, phone_hash);

-- ── Opt-out suppression (Phase 0) ─────────────────────────────────────────────
-- HASH ONLY, retained indefinitely: a suppression list must outlive the data it
-- suppresses, and keeping the plaintext number would defeat the deletion it honors.
CREATE TABLE IF NOT EXISTS messaging_opt_outs (
    workspace_id uuid        NOT NULL REFERENCES workspaces(id) ON DELETE CASCADE,
    phone_hash   text        NOT NULL,
    channel      text        NOT NULL DEFAULT 'whatsapp',
    source       text        NOT NULL DEFAULT 'inbound_stop',  -- inbound_stop|owner|rights_request
    created_at   timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (workspace_id, phone_hash, channel)
);
ALTER TABLE messaging_opt_outs ENABLE ROW LEVEL SECURITY;

-- ══ Phase 1 boundary — everything below is created empty and unused until the
--    send stack ships. Split here if the phases separate in time. ══════════════

-- ── Per-QR reminder schedule config ───────────────────────────────────────────
CREATE TABLE IF NOT EXISTS reminder_schedules (
    qr_id             uuid        PRIMARY KEY REFERENCES qr_codes(id) ON DELETE CASCADE,
    workspace_id      uuid        NOT NULL REFERENCES workspaces(id) ON DELETE CASCADE,
    enabled           boolean     NOT NULL DEFAULT false,
    channel           text        NOT NULL DEFAULT 'whatsapp',
    delay_minutes     integer     NOT NULL DEFAULT 120
                        CHECK (delay_minutes BETWEEN 30 AND 4320),   -- 30 min … 72 h
    cooldown_days     integer     NOT NULL DEFAULT 30 CHECK (cooldown_days BETWEEN 1 AND 365),
    quiet_start_hour  smallint    NOT NULL DEFAULT 21 CHECK (quiet_start_hour BETWEEN 0 AND 23),
    quiet_end_hour    smallint    NOT NULL DEFAULT 9  CHECK (quiet_end_hour   BETWEEN 0 AND 23),
    -- IANA zone the quiet-hours window is evaluated in. Store the zone, not an
    -- offset: the same lesson the QR-expiry spec learned the hard way.
    timezone          text        NOT NULL DEFAULT 'Asia/Kolkata',
    template_key      text        NOT NULL DEFAULT 'review_reminder_v1',
    updated_at        timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE reminder_schedules ENABLE ROW LEVEL SECURITY;

-- ── The delayed-send queue (mirrors webhook_deliveries) ───────────────────────
-- Same state machine and claim-lease as webhook_deliveries, with two deliberate
-- differences: (a) `scheduled_for` (webhooks fire immediately, reminders do not),
-- and (b) a sweep that is BATCH-BOUNDED — webhook_dispatch.sweep() selects all
-- due rows with no LIMIT, which is a timeout waiting to happen at message volume.
CREATE TABLE IF NOT EXISTS reminder_messages (
    id                uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    workspace_id      uuid        NOT NULL REFERENCES workspaces(id) ON DELETE CASCADE,
    qr_id             uuid        NOT NULL REFERENCES qr_codes(id)   ON DELETE CASCADE,
    contact_id        uuid        NOT NULL REFERENCES reminder_contacts(id) ON DELETE CASCADE,
    channel           text        NOT NULL DEFAULT 'whatsapp',
    template_key      text        NOT NULL,
    -- Idempotency: at most ONE message per contact per QR per cooldown window.
    -- A duplicate WhatsApp message costs the merchant money and annoys their
    -- customer — unlike a webhook retry, it cannot be taken back (PRD R9).
    idempotency_key   text        NOT NULL UNIQUE,
    scheduled_for     timestamptz NOT NULL,
    status            text        NOT NULL DEFAULT 'queued',
                        -- queued|sending|sent|delivered|read|clicked|failed|dead_letter|suppressed
    attempt_count     integer     NOT NULL DEFAULT 0,
    next_attempt_at   timestamptz,
    provider_message_id text,
    provider_status   text,
    last_error        text,
    click_token       text        UNIQUE,     -- /rr/:token — random 128-bit, expires with the row
    clicked_at        timestamptz,
    created_at        timestamptz NOT NULL DEFAULT now(),
    sent_at           timestamptz,
    delivered_at      timestamptz
);
ALTER TABLE reminder_messages ENABLE ROW LEVEL SECURITY;
-- Sweep index: the hot query is "queued/failed rows that are due", nothing else.
CREATE INDEX IF NOT EXISTS idx_reminder_messages_sweep
    ON reminder_messages (next_attempt_at)
    WHERE status IN ('queued','sending','failed');
CREATE INDEX IF NOT EXISTS idx_reminder_messages_ws_created
    ON reminder_messages (workspace_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_reminder_messages_contact
    ON reminder_messages (contact_id, created_at DESC);

-- ── Per-workspace BYO-BSP credentials ─────────────────────────────────────────
-- api_key_enc is Fernet-encrypted with WEBHOOK_SECRET_ENC_KEY (the outbound-
-- webhook precedent) — NOT a hash: we must decrypt to call the provider.
CREATE TABLE IF NOT EXISTS workspace_messaging_config (
    workspace_id       uuid        PRIMARY KEY REFERENCES workspaces(id) ON DELETE CASCADE,
    provider           text        NOT NULL DEFAULT 'gupshup',
    api_key_enc        text        NOT NULL,
    app_name           text,
    sender_number      text,                                   -- E.164, the merchant's WABA number
    default_region     text        NOT NULL DEFAULT 'IN',      -- E.164 parse default for bare local numbers
    template_name      text,                                    -- name approved in the merchant's BSP console
    template_language  text        NOT NULL DEFAULT 'en',
    template_status    text        NOT NULL DEFAULT 'unknown', -- unknown|pending|approved|rejected
    status             text        NOT NULL DEFAULT 'disconnected', -- disconnected|connected|paused|error
    paused_reason      text,                                    -- e.g. 'opt_out_rate_exceeded'
    verified_at        timestamptz,
    updated_at         timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE workspace_messaging_config ENABLE ROW LEVEL SECURITY;

-- ── Fair-use meter (mirrors card_ocr_usage / ai_analyst_usage) ────────────────
-- NOT a billing meter under BYO-BSP: the merchant pays Meta. This bounds abuse
-- (a compromised account blasting a bought list) and our own queue capacity.
CREATE TABLE IF NOT EXISTS reminder_usage (
    workspace_id   uuid        NOT NULL REFERENCES workspaces(id) ON DELETE CASCADE,
    period_start   date        NOT NULL,          -- period_start_iso(resolve_plan(...))[:10]
    messages_sent  integer     NOT NULL DEFAULT 0,
    opt_outs       integer     NOT NULL DEFAULT 0,
    updated_at     timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (workspace_id, period_start)
);
ALTER TABLE reminder_usage ENABLE ROW LEVEL SECURITY;

-- ── Atomic increment (mirrors increment_card_ocr_usage) ───────────────────────
CREATE OR REPLACE FUNCTION increment_reminder_usage(
    p_workspace_id uuid,
    p_period_start date
)
RETURNS integer
LANGUAGE plpgsql
AS $$
DECLARE new_count integer;
BEGIN
    INSERT INTO reminder_usage (workspace_id, period_start, messages_sent, updated_at)
    VALUES (p_workspace_id, p_period_start, 1, now())
    ON CONFLICT (workspace_id, period_start)
    DO UPDATE SET messages_sent = reminder_usage.messages_sent + 1,
                  updated_at    = now()
    RETURNING messages_sent INTO new_count;
    RETURN new_count;
END;
$$;

CREATE OR REPLACE FUNCTION increment_reminder_opt_outs(
    p_workspace_id uuid,
    p_period_start date
)
RETURNS void
LANGUAGE plpgsql
AS $$
BEGIN
    INSERT INTO reminder_usage (workspace_id, period_start, opt_outs, updated_at)
    VALUES (p_workspace_id, p_period_start, 1, now())
    ON CONFLICT (workspace_id, period_start)
    DO UPDATE SET opt_outs   = reminder_usage.opt_outs + 1,
                  updated_at = now();
END;
$$;

-- ── Flag + limit seed/flip (HOUSE CONVENTION) ─────────────────────────────────
-- 1) Seed BOTH keys as a full-object '{...}'::jsonb BLOB where absent, non-custom
--    only. MUST be a blob: test_feature_gate_coverage._seed_feature_keys()
--    discovers feature keys ONLY by regex-scanning '{...}'::jsonb blobs, so a
--    path-only jsonb_set seed leaves both keys undiscovered and the coverage test
--    fails them as "stale" (the 0026 lesson).
UPDATE plans
SET features = coalesce(features,'{}'::jsonb)
             || '{"review_reminders":false,"reminder_messages_per_month":0}'::jsonb
WHERE NOT (coalesce(features,'{}'::jsonb) ? 'review_reminders')
  AND coalesce(is_custom,false) = false;

-- 2) Enable + set the fair-use ceiling for Pro / Agency.
UPDATE plans
SET features = jsonb_set(
        jsonb_set(coalesce(features,'{}'::jsonb), '{review_reminders}', 'true'::jsonb, true),
        '{reminder_messages_per_month}', '2000'::jsonb, true)
WHERE lower(name) = 'pro' AND coalesce(is_custom,false) = false;

UPDATE plans
SET features = jsonb_set(
        jsonb_set(coalesce(features,'{}'::jsonb), '{review_reminders}', 'true'::jsonb, true),
        '{reminder_messages_per_month}', '10000'::jsonb, true)
WHERE lower(name) = 'agency' AND coalesce(is_custom,false) = false;

-- Free/Starter stay false/0 (PRD §8). No -1/unlimited on any tier — the ceiling
-- is an abuse brake and must always bind.

COMMIT;

-- Sanity (after COMMIT):
--   SELECT name, features->'review_reminders', features->'reminder_messages_per_month'
--     FROM plans WHERE coalesce(is_custom,false)=false ORDER BY price_monthly;
--   SELECT count(*) FROM reminder_contacts WHERE consent_text IS NULL;  -- must be 0
```

`lower(name)` + `coalesce(is_custom,false)=false` + `coalesce(features,'{}')` throughout: a bare `WHERE name IN ('Pro',…)` is case-sensitive, touches custom plans, and nulls a NULL `features` — three bugs prior specs hit.

**No change** to `qr_codes`, `qr_review_funnel`, `qr_lead_forms`, `qr_scan_events`, or `qr_scan_counters`. The one existing-table interaction is `qr_lead_submissions`: the feedback arm's `marketing_consent` does **not** get a new column there — it produces a `reminder_contacts` row with `sentiment='unhappy'` instead, which keeps the review-gating invariant enforceable by a `WHERE sentiment='happy'` filter rather than by developer discipline.

---

## 3. Backend Design

### 3.1 Capture ingest — `qr_backend/src/api/routes/internal.py`
A new route beside the existing internal endpoints (router-wide `verify_internal_secret` at `internal.py:21/31-34`, so no Bearer change and no new excluded route):

```
POST /api/internal/reminder-contact      # Worker beacon → consented contact
POST /api/internal/reminder-sweep        # cron → drain the send queue (Phase 1)
```

`ReminderContactPayload`: `short_code`, `phone`, `consent: bool`, `consent_text: str`, `stars: int | None`, `session_id: str | None`, `ip`, `user_agent`. Handler order — **every early return is a 200 with `{"stored": false, "reason": …}`, never an error**, because the caller is a fire-and-forget beacon that cannot react and a 5xx would just noise the Worker logs:

1. Resolve `short_code` → `qr_codes`; not found or `type != "review_funnel"` → `{"stored": false}`.
2. `await check_feature(workspace_id, "review_reminders", db)` — **async, must be awaited**; false → `{"stored": false, "reason": "not_entitled"}`. Fail-closed on resolve error.
3. `consent is not True` or `consent_text` blank → `{"stored": false, "reason": "no_consent"}`. **This is the invariant** — no ticked box, no row, ever.
4. Normalize `phone` to E.164 via `messaging/phone.py` using `workspace_messaging_config.default_region` (default `IN`); unparseable → `{"stored": false, "reason": "bad_phone"}`.
5. `phone_hash = sha256(e164 + settings.HASHING_SALT)` — the same salting convention `lead_submit` uses for `ip_hash`.
6. Suppression check against `messaging_opt_outs` → `{"stored": false, "reason": "opted_out"}`.
7. `sentiment = "happy" if stars is not None and stars >= star_threshold else "unhappy"` — read `star_threshold` from `qr_review_funnel`, **never** from the request.
8. Upsert `reminder_contacts` `on_conflict="workspace_id,qr_id,phone_hash"`.
9. **Phase 1 only:** if `reminder_schedules.enabled` and `sentiment == 'happy'`, enqueue (§3.4).

**Rate limiting:** reuse the `lead_submit` IP-hash approach — cap contacts per `ip_hash` per hour per QR. Without it, the beacon endpoint is an open write path behind a secret the Worker holds but a determined attacker could replay if they obtained it.

**Relaxing `/lead-submit`** (`internal.py:1234`, `LeadSubmitPayload` at `:1220`, `ALLOWED_SUBMIT_TYPES` at `:1217`): add optional `marketing_consent: bool = False` and `marketing_consent_text: str | None = None`. When both are present **and** a phone-typed field is in `data`, create a `reminder_contacts` row with `consent_source='review_funnel_feedback'`, `sentiment='unhappy'`. Everything else in that handler is untouched. **The existing `consent`/`consent_text` fields are NOT reused for this** — that label (`classicTemplate.js:41`) is a storage-and-response consent and does not authorise outbound messaging (PRD §2).

### 3.2 Provider layer — `qr_backend/src/utilities/messaging/`
A package, not a module, so the BSP is swappable and unit-testable with a fake:

```
messaging/
  __init__.py
  base.py       # MessagingProvider protocol: send_template(), fetch_template_status(),
                # verify_webhook(raw, headers) -> bool, parse_webhook(payload) -> list[Event]
  gupshup.py    # THE one adapter. Nothing outside this file names the BSP.
  phone.py      # to_e164(raw, region) -> str | None, hash_phone(e164) -> str, mask(e164)
  templates.py  # TEMPLATE_REGISTRY: key -> {body, variables[], category, opt_out_line}
  queue.py      # enqueue(), sweep(), _claim(), _send_and_finalize(), suppress_for_contact()
```

`queue.py` mirrors `webhook_dispatch.py` closely enough that a reviewer should diff them:
- `BACKOFF_SCHEDULE_SECONDS = [0, 300, 1800, 7200]` (5 min / 30 min / 2 h — slower than webhooks' `[0,60,600,3600]`; a reminder is not latency-sensitive and a hot retry loop against a BSP invites rate-limiting), `MAX_ATTEMPTS = 4`.
- `_claim(message_id, db)` — the **conditional-UPDATE lease** copied from `webhook_dispatch._claim` (`:231-249`): flip to `sending` with `next_attempt_at` pushed out **only if** still `queued`/`failed` **and** due. Returns `None` if a concurrent sweep already claimed it. This is the entire double-send defence and must not be replaced with a read-then-write.
- `sweep(db, limit=200)` — **bounded**, unlike `webhook_dispatch.sweep` (`:516-547`, which selects all due rows with no `LIMIT`). Ordered by `scheduled_for` so the oldest due message wins. One bad row must not abort the sweep (`except Exception: continue`, same as the webhook sweep).
- **Guards evaluated after the claim and before the provider call** — opt-out, contact `status != 'active'`, cooldown (`last_messaged_at` within `cooldown_days`), quiet hours, monthly cap, `template_status != 'approved'`, `workspace_messaging_config.status != 'connected'`. Quiet hours **defer** (`next_attempt_at = next window open`), everything else **suppresses** (`status='suppressed'`, terminal). Suppression must be a distinct terminal state from `failed` so the Reminders card can tell "we chose not to send" from "we tried and couldn't".
- **Ambiguous provider outcome** (timeout after the request left) resolves to **assume-sent** (`status='sent'`, no retry). An unsent reminder is a much cheaper failure than a duplicate (PRD R9).
- `increment_reminder_usage(ws, period)` is called **after** a successful provider call, not before: unlike the card-OCR meter (where increment-then-check gates a concurrent flood of paid AI calls), the concurrency here is already bounded by the claim lease and the batch size, and the cap is checked from the read value in the guard step.

### 3.3 Workspace API — `qr_backend/src/api/routes/reminders.py` (NEW)
Registered in `src/api/endpoints.py` alongside `webhooks_router` (`endpoints.py:57`), so Bearer middleware + `get_current_user_id` apply. Permissions via `dependencies/permissions.py` — `require_can_read` for reads, `require_can_update` for schedule/config writes, and **owner-only** for full phone reveal and CSV export (`phone_e164` is third-party PII; editors get `mask()`).

```
GET    /workspaces/{ws}/reminders/config          # BSP connection + template status
PUT    /workspaces/{ws}/reminders/config          # connect/update creds (encrypted at rest)
POST   /workspaces/{ws}/reminders/config/verify   # live BSP ping + template status refresh
DELETE /workspaces/{ws}/reminders/config          # disconnect (zeroes api_key_enc)
GET    /workspaces/{ws}/qrs/{qr_id}/reminders/schedule
PUT    /workspaces/{ws}/qrs/{qr_id}/reminders/schedule
GET    /workspaces/{ws}/reminders/contacts        # paginated, masked by default
DELETE /workspaces/{ws}/reminders/contacts/{id}   # DPDP erasure (also writes an opt-out hash)
GET    /workspaces/{ws}/reminders/contacts/export # owner-only CSV
GET    /workspaces/{ws}/reminders/opt-outs
POST   /workspaces/{ws}/reminders/opt-outs        # manual suppression
GET    /workspaces/{ws}/reminders/usage           # {messages_sent, limit, period_start, opt_outs}
GET    /workspaces/{ws}/qrs/{qr_id}/reminders/stats
POST   /workspaces/{ws}/reminders/test            # one message to an owner-verified number
```

`.../usage` windows by **`period_start_iso(resolve_plan(...))[:10]`** — the billing anchor the sweep meters against, not a naive calendar month, so the read-out matches enforcement exactly (the `0026` correction). The **test send** is the single most valuable debugging affordance in the feature and must burn a real quota unit and traverse the real queue, or it validates nothing.

### 3.4 Inbound webhook — `qr_backend/src/api/routes/bsp_webhook.py` (NEW, public)
```
POST /api/bsp/webhook          # delivery receipts + inbound messages (STOP)
```
Added to `excluded_routes` in `qr_backend/src/main.py:62-76`, next to `razorpay/webhooks` and `mor/webhooks` — **prefix-matched**, so the path must be exact and narrow. **Signature verification runs before any parsing**, using `settings.BSP_WEBHOOK_SECRET` and the adapter's `verify_webhook(raw_body, headers)`; an unverified request gets `401` and is not logged with its body. Then:
- **Status events** → update `reminder_messages.provider_status` + `status` by `provider_message_id`, scoped by the resolved workspace (never trust a `workspace_id` in the payload).
- **Inbound `STOP`/`UNSUBSCRIBE`/`स्टॉप`** (case-insensitive, trimmed, small keyword set) → insert `messaging_opt_outs`, set `reminder_contacts.status='opted_out'` for every matching contact in that workspace, `suppress_for_contact()` all non-terminal queued rows, `increment_reminder_opt_outs`. **Idempotent** — a repeated STOP is a no-op.
- **Everything else is ignored.** We are not building an inbox; an unrecognised inbound message must have no side effect.
- **Replay window**: reject events with a provider timestamp older than 5 minutes where the BSP supplies one.

### 3.5 KV snapshot — `qr_backend/src/utilities/cloudflare_kv.py`
Extend the `review_funnel` branch of `build_kv_content` (`:451-473`) — **keep the flat merge**, adding one nested block whose keys cannot collide with the lead-form keys:

```python
elif qr_type == "review_funnel":
    ...existing rf + lf flat merge (unchanged)...
    sched = (supabase.table("reminder_schedules")
             .select("enabled, delay_minutes")
             .eq("qr_id", qr_id).maybe_single().execute())
    cfg_ok = _messaging_ready(workspace_id, supabase)   # connected + template approved
    if sched and sched.data and sched.data.get("enabled") and cfg_ok:
        out["reminder_capture"] = {
            "enabled": True,
            "consent_text": REMINDER_CONSENT_TEXT,   # single source of truth, backend-owned
            "prompt": "Want a reminder to leave your review later?",
        }
    return out
```

**The consent text lives in the backend and is shipped to the edge, never authored in the Worker template** — the string we store as proof of consent must be byte-identical to the string the scanner saw, and that is only guaranteed if one side owns it. `reminder_capture` is **absent** (not `{"enabled": false}`) when setup is incomplete, so the Worker's check is a truthiness test and a stale KV entry degrades to "no capture row" rather than to a broken form.

The window reaches the edge through **both** write paths — the create-time direct `write_to_kv(...)` and `sync_qr_to_kv(qr_id)` (`:307`) — because `build_kv_content` is called by both. No `write_to_kv` signature change is needed (`:52-66`): the block rides `content`.

### 3.6 Gating — `qr_backend/src/api/routes/subscription.py`
```python
"review_reminders": "enforced",              # reminders.py + internal.py reminder-contact check_feature
"reminder_messages_per_month": "enforced",   # messaging/queue.py cap via _limit_value + increment_reminder_usage RPC
```
in `FEATURE_ENFORCEMENT` (`:524-560`), and `"reminder_messages_per_month": {"source": "feature", "usage": None}` in `_QUOTA_SPEC` (`:429-454`) — value-only, exactly like `card_ocr_scans_per_month` (`:453`): usage lives in our own counter, read at send time via `_limit_value`, never through the generic `check_limit` path. `_limit_value` fail-closes a missing key to `0`. Seeded on every non-custom plan by `0038` so `test_registry_matches_plan_seed` stays green; `inert`→`enforced` in the same PR.

### 3.7 Config — `qr_backend/src/config/settings/base.py`
```python
BSP_PROVIDER: str       = decouple.config("BSP_PROVIDER", default="gupshup", cast=str)
BSP_API_BASE_URL: str   = decouple.config("BSP_API_BASE_URL", default="", cast=str)
BSP_WEBHOOK_SECRET: str = decouple.config("BSP_WEBHOOK_SECRET", default="", cast=str)
```
Per-workspace credentials are **not** env vars — they live encrypted in `workspace_messaging_config.api_key_enc`, reusing the existing `WEBHOOK_SECRET_ENC_KEY` Fernet helper (`webhook_dispatch._get_fernet` `:72`). `phonenumbers` joins `requirements.txt` for E.164 parsing; hand-rolling that is a bug factory.

---

## 4. Cloudflare Worker / Edge Design

Four changes in `qr_cf_code`, all additive. **`npm run deploy:prod` is required; `wrangler.toml` is unchanged.**

**4.1 Capture row — `src/pages/reviewFunnel/classicTemplate.js`.** When `content.reminder_capture?.enabled`, render below the stars (`:211`): a `tel` input, an **unticked** checkbox whose label is `escapeHTML(content.reminder_capture.consent_text)` — server-supplied, never a literal in this file — and a hidden field carrying that same text back. `escapeHTML()` on every merchant/server string, as everywhere else in this template.

**4.2 Beacon before navigation — the star-tap handler (`:255-268`).** In *both* branches, before the existing `location.href` / `sendBeacon` calls:
```js
var phone   = (document.getElementById("rr-phone")   || {}).value;
var consent = (document.getElementById("rr-consent") || {}).checked;
if (phone && consent) {
  navigator.sendBeacon("/review-contact/" + shortCode, new Blob([JSON.stringify({
    phone: phone, consent: true, consent_text: consentText, stars: n
  })], { type: "application/json" }));
}
// ...then the EXISTING navigation, unchanged:
if (n >= threshold) { window.location.href = "/review-go/" + shortCode + "?stars=" + n; }
```
`sendBeacon` is **required**, not preferred: it is the only API guaranteed to survive the immediate navigation. A `fetch` — even with `keepalive` — is the wrong default here, and an `await` would insert network latency into the exact conversion path PRD R1 is about. If `sendBeacon` is unavailable, we **skip the capture** rather than delay the redirect.

**4.3 New routes in `src/index.js`** (before the generic `/:shortCode` handler at `:299`, beside `/lead-submit/` `:162` and `/review-go/` `:257`):
```js
// Beacon target. ALWAYS 204 — the caller cannot react, and a non-2xx here would
// only pollute Worker logs. Forwarding failures are swallowed by design.
if (request.method === "POST" && pathname.startsWith("/review-contact/")) {
  const sc = pathname.split("/")[2];
  if (!sc) return new Response(null, { status: 204 });
  const body = await request.json().catch(() => null);
  if (body) {
    ctx.waitUntil(fetch(`${env.BACKEND_URL}/internal/reminder-contact`, {
      method: "POST",
      headers: { "Content-Type": "application/json",
                 "x-internal-secret": env.INTERNAL_SECRET },
      body: JSON.stringify({ ...body, short_code: sc,
        ip: request.headers.get("cf-connecting-ip") || "",
        user_agent: request.headers.get("user-agent") || "",
        session_id: await computeSessionId(request) }),
    }).catch(() => null));
  }
  return new Response(null, { status: 204 });
}

// Reminder click → attribute, then 302 to the STORED, backend-validated URL.
if (pathname.startsWith("/rr/")) {
  const token = pathname.split("/")[2];
  if (!token) return getErrorPage();
  const resp = await fetch(`${env.BACKEND_URL}/internal/reminder-click/${token}`, {
    method: "POST", headers: { "x-internal-secret": env.INTERNAL_SECRET },
  }).catch(() => null);
  if (!resp || !resp.ok) return getErrorPage();
  const { target } = await resp.json();
  if (!target) return getErrorPage();
  return Response.redirect(target, 302);
}
```
`/rr/:token` deliberately does **one backend round-trip** rather than reading KV: the token is per-message, unguessable, single-purpose, and must be resolvable to a click record. It is a low-volume path (one hit per reminder click), so the round-trip is affordable — and it keeps the 302 target sourced from the validated `qr_review_funnel.google_review_url` rather than from anything in the request. `ctx.waitUntil` is used for the capture forward because, as the `/review-go/` comment at `:273-277` already documents, a route that returns immediately can otherwise be torn down before its fetch lands.

**4.4 Sweep ping — `src/index.js:78-79`.** One line inside the **existing** `*/5 * * * *` branch:
```js
} else if (event.cron === "*/5 * * * *") {
  ctx.waitUntil(ping("/internal/webhook-sweep",  "webhook-sweep"));
  ctx.waitUntil(ping("/internal/reminder-sweep", "reminder-sweep"));   // NEW
}
```
**No `wrangler.toml` change** (`crons` at `:53` already includes `*/5 * * * *`), so there is no new-cron-trigger gate. **Caution learned from this codebase:** the Worker already pings `/internal/reclamation-sweep` daily (`:77`) and **no such backend route exists** — that ping has been 404ing every day. A cron that fires proves nothing; `/internal/reminder-sweep` needs its own success metric (§11).

**Template mirroring (house rule):** the capture row exists in the Worker template and **must** be mirrored by the React preview in the same PR (§5.2).

---

## 5. Frontend Design

### 5.1 Gating — `src/hooks/useSubscription.ts`, `src/lib/plan-features.ts`
Extend `PlanFeatures` (`useSubscription.ts:28-81`):
```ts
review_reminders: boolean;             // Pro+ WhatsApp review reminders
reminder_messages_per_month: number;   // fair-use ceiling; 0 = none (never -1)
```
Add `'reminder_messages_per_month'` to the `getLimit` key union. Entitlement via the existing `canAccessFeature(subscription, 'review_reminders')`.

### 5.2 Builder — `src/components/qr-generator/content-types/review-funnel-rating-fields.tsx`
A collapsed **"WhatsApp reminders"** sub-section on the existing `review_funnel` form: enable toggle, delay (30 min–72 h), cooldown days, quiet-hours start/end + IANA timezone select, and a **read-only preview of the exact consent sentence** (fetched from the backend constant — the merchant must not be able to edit the text we store as proof of consent). If the workspace has not completed messaging setup, the whole sub-section is replaced by an inline link to the settings wizard; if not entitled, by an upgrade chip. react-hook-form + zod, shadcn primitives, no inline styles, ≤200 lines — split into its own kebab-case one-export file (`reminder-capture-fields.tsx`) since `review-funnel-rating-fields.tsx` already exists and the limit binds.

**Mirrored preview:** `src/components/qr-generator/templates/review-funnel/` gains the capture row so `PagePreview`/`MobilePreview` show exactly what the Worker renders. **Every Worker template must be mirrored by a React preview** — ship both in the same PR or the preview silently lies.

### 5.3 Settings wizard — `src/components/org/settings/MessagingSection.tsx` (NEW)
Mirrors `WebhooksSection.tsx` in structure (section shell + row components + drawer). Three **linear, blocking** steps with real status, split across ≤200-line files (`messaging-connect-card.tsx`, `messaging-template-card.tsx`, `messaging-optouts-table.tsx`): connect BSP credentials (write-only; never render the key back), template status with a refresh action and an honest `pending` state, and the opt-out list + manual suppression. Add a `settings-nav.tsx` entry.

### 5.4 Contacts + stats
- `src/components/org/leads/` gains a **Contacts** tab (or a sibling route under `src/app/[slug]/(dash)/leads/`) listing `reminder_contacts` — phone masked by default, consent text and timestamp visible, per-row delete, owner-only CSV export. This is the surface a DPDP rights request is answered from.
- `src/components/org/qrs/` gains `ReminderStatsCard.tsx`, rendered conditionally for `type === 'review_funnel'` beside the existing Review Funnel card: opt-in rate, queued/sent/delivered/read/clicked/suppressed/failed, opt-out rate, and — prominently — **Google-route conversion vs. the pre-capture baseline** (the PRD §9 guardrail; putting it anywhere less visible is how a 3pp regression goes unnoticed for a month). `primary` indigo for sent, `tertiary` cyan for clicked, `on-surface-variant` for labels.

### 5.5 Hooks — `src/hooks/useReminders.ts` (NEW)
TanStack Query only, via `authApi`, following the `useWebhooks.ts` key-factory + mutation shape (`useWebhooks.ts:57-180`):
```ts
export const reminderKeys = {
  all: ['reminders'] as const,
  config:   (ws: string) => [...reminderKeys.all, 'config', ws] as const,
  schedule: (ws: string, qrId: string) => [...reminderKeys.all, 'schedule', ws, qrId] as const,
  contacts: (ws: string) => [...reminderKeys.all, 'contacts', ws] as const,
  usage:    (ws: string) => [...reminderKeys.all, 'usage', ws] as const,
  stats:    (ws: string, qrId: string) => [...reminderKeys.all, 'stats', ws, qrId] as const,
};
```
`workspaceId` from `useWorkspaceStore((s) => s.currentWorkspace)?.id` (house rule — never URL params). A FE constant flag (`NEXT_PUBLIC_REMINDERS_BETA`) gates visibility through Phase 1; removed at GA.

---

## 6. External-Service Integration

**No AI.** No Anthropic call anywhere in this feature; `ANTHROPIC_API_KEY` is irrelevant here.

**The BSP (Gupshup at launch, PRD Open Q1).** One adapter behind `MessagingProvider`; nothing outside `gupshup.py` names the provider. Three operations: send an approved template with ordered variables, fetch template status, verify + parse an inbound webhook. **We are a customer of the BSP, not a Meta Tech Provider** — the BSP owns that relationship, as the analysis instructs.

**BYO-WABA is the sender model.** Per-workspace credentials, encrypted with the existing Fernet key. Consequences accepted deliberately: the merchant completes Meta Business verification and template approval themselves (a **1–3 business day** external gate, sometimes longer, sometimes a rejection); we cannot shorten it, only make its status legible. In exchange: the message comes from the merchant's own number, quality-rating damage is contained per-tenant, and **Qravio carries zero per-message COGS** — which is what makes the feature viable at a ₹999/mo Pro price (PRD §8 has the arithmetic).

**Template contract.** `TEMPLATE_REGISTRY['review_reminder_v1']` holds the exact body, ordered variables (`business_name`, `link`), category, and the mandatory opt-out line. We validate variable **count and order** before every send — a mismatch is a guaranteed provider rejection and a wasted, unrecoverable attempt. The registry is the same string the wizard tells the merchant to paste into their BSP console; drift between the two is the #1 predictable support ticket.

**Email (Resend).** Optional operational notifications only (template rejected, sending auto-paused on opt-out rate) via the existing `qr_backend/src/utilities/email.py` pattern. **If any of them ship, publishing `_dmarc.qravio.app` (`v=DMARC1; p=none`) is a GA gate** — the same gate the review-funnel TRD flagged. Simplest path: ship none in v1 and surface state in-app only, which removes the gate entirely. **Recommended.**

**No PDF, no payment provider, no Google API.** We never call Google — the review URL is the merchant-pasted, backend-validated one the funnel already redirects to.

---

## 7. API Contracts

**`POST /api/internal/reminder-contact`** (`x-internal-secret`) — always `200`, never an error:
```jsonc
// request
{ "short_code": "Ab3xZ", "phone": "9876543210", "consent": true,
  "consent_text": "Yes, send me one WhatsApp reminder about my review. I can reply STOP anytime.",
  "stars": 5, "session_id": "…", "ip": "…", "user_agent": "…" }

// 200 — stored
{ "stored": true, "contact_id": "…", "queued": true }
// 200 — deliberately not stored (beacon caller cannot react to an error)
{ "stored": false, "reason": "no_consent" | "opted_out" | "bad_phone" | "not_entitled" | "not_found" }
```

**`POST /api/internal/reminder-sweep`** (`x-internal-secret`, cron) →
`{"status":"ok","due":42,"claimed":40,"sent":37,"suppressed":2,"deferred":1,"dead_lettered":0}`.
Every field is a metric; a sweep that returns `due:0` forever is indistinguishable from a broken cron without them.

**`POST /api/internal/reminder-click/{token}`** (`x-internal-secret`) → `{"target":"https://g.page/r/…/review"}`; `404` on unknown/expired token. Marks `clicked_at`, suppresses queued siblings for that contact.

**`POST /api/bsp/webhook`** (public, signature-verified) → `200 {"ok":true}` for handled and ignored events alike; `401` on signature failure. Never echoes payload contents.

**Workspace API** (Bearer, `require_can_*`) — representative shapes:
```jsonc
// PUT /api/workspaces/{ws}/reminders/config
{ "provider": "gupshup", "api_key": "…", "app_name": "CafeXyz",
  "sender_number": "+919876543210", "template_name": "review_reminder_v1",
  "template_language": "en", "default_region": "IN" }
// → 200 { "status": "connected", "template_status": "pending", "verified_at": "…" }
// api_key is WRITE-ONLY — never returned by any GET.

// GET /api/workspaces/{ws}/reminders/usage
{ "messages_sent": 412, "limit": 2000, "opt_outs": 3, "period_start": "2026-07-01" }

// GET /api/workspaces/{ws}/qrs/{qr_id}/reminders/stats
{ "star_taps_above_threshold": 1840, "opt_ins": 168, "opt_in_rate": 9.1,
  "queued": 12, "sent": 150, "delivered": 141, "read": 118, "clicked": 39,
  "suppressed": 4, "failed": 2, "opt_out_rate": 1.3,
  "google_route_rate": 96.4, "google_route_rate_baseline": 97.1 }

// 403 not entitled
{ "detail": { "code": "review_reminders_locked", "upgrade_to": "pro" } }
// 429 fair-use ceiling (headers: X-RateLimit-Limit/Remaining/Reset)
{ "detail": { "code": "reminder_quota_exceeded", "limit": 2000 } }
// 409 setup incomplete
{ "detail": { "code": "messaging_not_ready", "template_status": "pending" } }
```

**KV** — the `review_funnel` `content` gains one optional nested block; nothing else changes:
```jsonc
{ "google_review_url": "…", "star_threshold": 4, "fields": [ … ],
  "reminder_capture": { "enabled": true, "consent_text": "…", "prompt": "…" } }
```

---

## 8. Security, Privacy & Abuse

- **Auth.** Workspace routes sit under the Bearer middleware with `require_can_read/update`; full phone reveal and CSV export are **owner-only**. Ingest and sweep are `/internal/*`, guarded router-wide by `verify_internal_secret` (`internal.py:21,31-34`). The BSP webhook is the **only** new public surface and is signature-verified before parsing, added narrowly to `excluded_routes` (`src/main.py:62-76`) beside `razorpay/webhooks`.
- **Tenant isolation.** The service-role client bypasses RLS, so every new table carries an explicit `workspace_id` filter in code and RLS-enabled-with-no-policies as defence in depth. The BSP webhook resolves the workspace from **our** `provider_message_id`, never from a `workspace_id` in the payload.
- **Credential handling.** `api_key_enc` is Fernet-encrypted with `WEBHOOK_SECRET_ENC_KEY` (decryptable by necessity — we must call the provider). Write-only over the API; never returned, never logged. Rotation = re-`PUT`.
- **Consent (DPDP 2023).** Separate, unticked, purpose-specific checkbox; verbatim `consent_text` + `consent_at` + `consent_source` stored `NOT NULL`; the string is **backend-owned and shipped to the edge** so what we store is provably what was shown. Purpose limitation is enforced structurally: `reminder_contacts` is readable only by the reminder sender and the contacts UI, and `sentiment='unhappy'` rows are excluded from review templating by a `WHERE`, not by convention.
- **Withdrawal.** STOP via inbound webhook, owner-side suppression, per-contact delete — all write a `messaging_opt_outs` hash that outlives the contact row. Suppression is checked at **capture** and again at **send**.
- **Retention.** Contacts purge at the configured TTL (PRD Open Q5, recommend 180 days) via the same sweep, mirroring `_prune_old_deliveries` (`webhook_dispatch.py:550`). Opt-out hashes are retained indefinitely and are non-reversible.
- **Pre-existing liability this feature aggravates.** The analysis flags the account-deletion cascade as a stub with no backend cascade. Adding a table of third-party phone numbers to a product that cannot actually delete a user's data makes that gap materially worse. **Fix the cascade with or before this feature** — and include `reminder_contacts` in it.
- **Abuse.**
  - *Beacon endpoint:* IP-hash rate limit per QR per hour (the `lead_submit` precedent); consent and entitlement checked server-side, never trusted from the payload.
  - *Spam:* no bulk import (structural — there is no code path that accepts a list), per-contact cooldown, per-workspace monthly ceiling, quiet hours, and **auto-pause at a 5% opt-out rate** (`workspace_messaging_config.status='paused'`).
  - *Phone enumeration:* the ingest response is uniform (`{"stored": …}`) and never reveals whether a number was already known.
  - *Token guessing:* `/rr/:token` uses a 128-bit random token, single-purpose, resolvable only to a stored validated URL.
- **No SSRF.** The only outbound calls are to the configured BSP base URL (an env-pinned host) — never to a user-supplied URL. The review link we send is our own `/rr/` origin.
- **Not a security boundary.** Suppression and quiet hours are correctness controls, not access control. A merchant with valid BSP credentials can always message their own contacts outside our product; we govern what *we* send.

---

## 9. Performance, Scale & Cost

- **Scan hot path: unchanged.** The capture row is static HTML rendered from the KV entry already fetched — no extra KV read, no backend call, no added latency. The beacon is fire-and-forget and does not block the 302. **This is the whole point of the design** (PRD R1): the feature must be free at the moment it could cost conversion.
- **Sweep.** Every 5 minutes: one indexed `SELECT … WHERE next_attempt_at <= now LIMIT 200` on `idx_reminder_messages_sweep`, then ≤200 claim-updates and provider calls. At 200 messages/5 min the ceiling is ~57k/day — comfortably above any plausible aggregate at the Pro/Agency ceilings. **The bounded batch is the load-bearing difference from `webhook_dispatch.sweep()`**, which selects all due rows unbounded (`:525-531`); at message volumes that is a Render request timeout and a stalled queue.
- **Provider latency** is absorbed entirely by the sweep, off any user path. A slow BSP delays reminders, never scans. Per-call timeout ~10 s; a timeout after the request left resolves to assume-sent.
- **Cost.** Qravio: **₹0 per message** (BYO-BSP). Marginal DB cost is a handful of small rows per contact; the queue self-prunes on the retention TTL. The only Qravio-side cost driver is sweep frequency, which is already paid for by the existing cron.
- **The cost that matters is the merchant's**, and it is why `reminder_messages_per_month` exists as a brake rather than a billing line. If the credits model is ever revisited, PRD §8's arithmetic — ~₹780 of COGS on a 1,000-message month against a ₹999 plan — is the number to start from.

---

## 10. Testing Strategy

**Backend (pytest, `qr_backend/tests/`):**
- `test_reminder_contact_consent`: **`consent=false` or blank `consent_text` stores nothing** (invariant); a stored row always has both `NOT NULL`; a pre-ticked-equivalent payload without an explicit `true` is rejected.
- `test_reminder_contact_normalize`: `9876543210` + region `IN` → `+919876543210`; `+91 98765 43210` → same; garbage → `{"stored": false, "reason": "bad_phone"}`; `phone_hash` is stable and salted.
- `test_reminder_contact_suppression`: an opted-out hash is never stored; the response is uniform and does not leak prior knowledge of the number.
- `test_reminder_sentiment`: stars below the QR's own `star_threshold` (read from the DB, **not** the payload) → `sentiment='unhappy'`; **an unhappy contact is never selected for a review template** (the PRD R2 invariant, asserted at the query level).
- `test_reminder_queue_claim`: two concurrent sweeps claim a row **once**; a claimed row is skipped, not double-sent; a lease that expires is re-claimable.
- `test_reminder_idempotency`: a duplicate enqueue inside the cooldown window violates the unique `idempotency_key` and does not create a second message.
- `test_reminder_guards`: quiet hours **defer** (`next_attempt_at` moves, status stays `queued`); opt-out/cooldown/cap/unapproved-template **suppress** (terminal, distinct from `failed`); **no provider call is made in any suppressed case** (assert the fake provider was not invoked).
- `test_reminder_backoff`: failures walk `BACKOFF_SCHEDULE_SECONDS`; `MAX_ATTEMPTS` → `dead_letter`; one poison row does not abort the batch; the batch is capped at `limit`.
- `test_reminder_ambiguous_send`: a provider timeout after the request resolves to `sent`, **not** a retry.
- `test_bsp_webhook_signature`: a bad signature → `401` **before** parsing; a valid STOP inserts an opt-out, flips contacts, suppresses queued rows, and is **idempotent** on replay; an unrecognised inbound has no side effect; a stale timestamp is rejected.
- `test_reminder_gate`: Free/Starter → `403`; Pro → `200`; a mid-month downgrade → `403` on the next call; over-cap → `429` with `X-RateLimit-*`.
- `test_reminder_kv`: `build_kv_content('review_funnel')` includes `reminder_capture` **only** when the schedule is enabled **and** messaging is connected with an approved template; the block is **absent** (not `enabled:false`) otherwise; the existing flat lead-form keys are unchanged.
- **`test_feature_gate_coverage` stays green** after the `inert`→`enforced` flip and the `0038` blob seed.
- BSP SDK/HTTP **mocked** in all CI tests — no live provider calls, ever.

**Worker (`qr_cf_code`, node:test as in `reviewFunnel.test.mjs`):**
- Capture row renders **only** when `content.reminder_capture.enabled`; the checkbox is **unticked**; the consent label is the server-supplied string, escaped.
- **The star tap navigates whether or not the beacon fires** — including when `navigator.sendBeacon` is undefined (regression guard for PRD R1).
- Beacon body carries phone + consent + `consent_text` + stars; no beacon is sent when either input is empty.
- `/review-contact/` returns `204` on every input, including a malformed body and a backend 500.
- `/rr/:token` 302s to the backend-supplied target; an unknown token → error page; **no request-supplied URL is ever redirected to**.
- The `*/5` cron branch pings **both** sweeps.

**Frontend (Vitest + Playwright):** capture settings zod validation (delay range, quiet-hour bounds); the consent sentence is **read-only** in the builder; **React preview ⇄ Worker template parity snapshot for the capture row**; `MessagingSection` renders the three gates with real status and never echoes the API key; contacts masked for editors, revealed for owners; `ReminderStatsCard` renders only for `review_funnel`. **Baseline: ~29 pre-existing FE failures are documented and are not regressions** — assert new tests pass and the count does not increase.

**Manual / beta (the tests that actually decide this feature):** a real BSP sandbox account end-to-end — connect → template approved → 5★ tap with consent → one message at the delay → receipt → click → 302 → STOP → silence. Plus the **conversion guardrail**: 14 days of pre-capture baseline before the row is enabled, then a daily read of Google-route rate with the 2pp rollback trigger armed.

---

## 11. Observability & Rollout

**Phase 0 — capture only (internal → GA).** Apply `0038`; register both flags `inert`→`enforced`; ship `/internal/reminder-contact`, the Worker capture row + `/review-contact/`, the `marketing_consent` thread-through, contacts UI + export + delete, and the **guardrail dashboard first**. Capture 14 days of pre-capture baseline, enable for internal, then design partners, then widen. **Nothing sends.**
- **Exit gate:** opt-in ≥ 8% → proceed; 4–8% → proceed hand-held only; **< 4% → stop, do not build Phase 1.** Google-route rate within 2pp. Consent-provenance invariants green.

**Phase 1 — sending, closed beta.** BSP adapter, `workspace_messaging_config`, the queue + `/internal/reminder-sweep`, the inbound webhook, `/rr/:token`, quiet hours + caps, the meter, the wizard, the Reminders card — behind `NEXT_PUBLIC_REMINDERS_BETA` for 5–10 partners. **Start BSP account setup and Meta template approval the day Phase 0's gate passes**, not when the code is ready: it is a multi-day external dependency and it will otherwise be the critical path.

**Phase 2 — GA.** Remove the FE flag; publish the WABA onboarding guide (the highest-leverage doc in this feature); comparison-matrix row + review-reminder SEO cluster.
- **GA gates:** delivery ≥ 90%; opt-out < 2%; zero consent-invariant violations; onboarding-completion rate measured and reported honestly; `_dmarc.qravio.app` published **if** any email notification ships (avoidable — §6).

**Deploy order:** apply `0038` → deploy backend (`/internal/reminder-contact` must exist) → **`npm run deploy:prod`** the Worker (the beacon needs a live target; deployed early it forwards into a 404 and drops opt-ins silently) → enable the FE flag. `wrangler.toml` unchanged.

**Metrics / logs.** Structured log per sweep run (`due`, `claimed`, `sent`, `suppressed`, `deferred`, `dead_lettered`, duration) and per send (`workspace_id`, `qr_id`, `template_key`, `provider_status`, latency — **never the phone number**). Alarms: sweep returning `due:0` for 24 h (a silent-cron symptom — see the `/internal/reclamation-sweep` 404 that has been happening daily); `dead_letter` rate > 5%; opt-out rate > 5% per workspace (auto-pause + alert); any `reminder_contacts` row with a null `consent_text` (should be impossible — the alarm exists to prove it). **The Google-route guardrail is a dashboard tile, not a query someone remembers to run.**

---

## 12. Open Technical Questions & Risks

1. **Migration slot + single-file scope** — `0038` is provisional (five sibling specs are competing for `0034`–`0037`). **Re-verify against `qr_backend/migrations/` at build time.** The file bundles Phase-1 tables into a Phase-0 migration as a documented divergence from "ship only this phase's schema" (§2); if the phases separate in time, split at the marked boundary and take a fresh slot.
2. **BSP choice (PRD Open Q1)** — Gupshup recommended. Nothing outside `messaging/gupshup.py` may name it; a second adapter must be purely additive. **Verify at build time** that the chosen BSP's inbound webhook exposes a verifiable signature — if it does not, the public route needs a different authentication story (IP allow-list at minimum) and that changes §8.
3. **`sendBeacon` reliability is not 100%.** It is best-effort by specification, and some browsers/extensions drop it. Some opt-ins **will** be lost. Accepted: the alternative (blocking the redirect on a `fetch`) trades a small loss for a direct hit on the conversion the feature exists to protect. **Instrument the gap** — compare beacon-attempted (client counter) with contacts-stored — and revisit only if the loss exceeds ~10%.
4. **Quiet-hours timezone.** Store the **IANA zone** (`reminder_schedules.timezone`), never an offset, and evaluate the window in that zone — the exact correctness bar the QR-expiry spec landed on. A DST-naive offset silently shifts every send by an hour for half the year in non-IST workspaces.
5. **Cooldown vs. multiple QRs.** A customer who scans two of the same merchant's QRs is one person. **Recommend the cooldown key be `(workspace_id, phone_hash)`, not `(qr_id, phone_hash)`** — cross-QR, so a multi-outlet merchant cannot accidentally message the same person twice in a day. The unique index above is per-QR for idempotency; the *cooldown guard* must be workspace-wide. Confirm at build.
6. **Meter timing.** We increment **after** a successful send (not increment-then-check like `card_ocr`) because concurrency is already bounded by the claim lease and the batch size, and the cap is read in the guard step. This makes the cap approximate at the boundary (a batch could overshoot by < `limit`). Accepted for a fair-use brake; **not** acceptable if a billing meter ever replaces it — that would need increment-then-check.
7. **Template drift between the registry and the merchant's BSP console.** We tell them what to paste; they can edit it. A variable-order mismatch is a guaranteed rejection and an unrecoverable wasted attempt. **Validate variable count/order before every send** and surface a specific error, not a generic failure. This is the most predictable support ticket in the feature.
8. **Review-completion is unobservable (PRD R6).** Click-through is a proxy, not a measurement. Any external claim about "review lift" must be sourced from merchant-reported before/after volumes on a small design-partner sample and labelled as such.
9. **The unhappy-path contact is a loaded gun.** `sentiment='unhappy'` rows exist for service recovery only. **Enforce the exclusion in the query, with a test**, not in a comment — a future engineer adding a "message all contacts" feature must hit a failing test, not a code review.
10. **`/internal/reclamation-sweep` 404s daily** (Worker `src/index.js:77`; no matching backend route). Not this feature's bug, but it is direct evidence that "the cron fires" is not evidence that "the job runs". The reminder sweep ships with its own success metric and a `due:0`-for-24h alarm because of it.

### Appendix — Key Files

| Concern | File |
|---|---|
| Migration (6 tables, 2 RPCs, flag seed) | `qr_backend/migrations/0038_whatsapp_review_reminders.sql` (NEW — **re-verify slot**) |
| Capture ingest + sweep + click resolve | `qr_backend/src/api/routes/internal.py` (NEW `/reminder-contact`, `/reminder-sweep`, `/reminder-click/{token}` beside `/webhook-sweep` `:1118`; secret guard `:21,31-34`) |
| Relaxed lead-submit (marketing consent) | `qr_backend/src/api/routes/internal.py` (`LeadSubmitPayload` `:1220`, `ALLOWED_SUBMIT_TYPES` `:1217`, handler `:1234`) |
| Workspace reminder API | `qr_backend/src/api/routes/reminders.py` (NEW), registered in `src/api/endpoints.py` (beside `webhooks_router` `:57`) |
| BSP inbound webhook (public) | `qr_backend/src/api/routes/bsp_webhook.py` (NEW) + `excluded_routes` in `qr_backend/src/main.py:62-76` |
| Provider layer + queue | `qr_backend/src/utilities/messaging/{base,gupshup,phone,templates,queue}.py` (NEW) |
| Queue pattern mirrored (diff against it) | `qr_backend/src/utilities/webhook_dispatch.py` (`BACKOFF_SCHEDULE_SECONDS` `:57`, `_claim` `:231`, `sweep` `:516`, `_prune_old_deliveries` `:550`, `_get_fernet` `:72`) |
| KV capture block | `qr_backend/src/utilities/cloudflare_kv.py` (`review_funnel` branch `:451-473`; `write_to_kv` `:52`; `sync_qr_to_kv` `:307`) |
| Gating | `qr_backend/src/api/routes/subscription.py` (`FEATURE_ENFORCEMENT` `:524`, `_QUOTA_SPEC` `:429`, `_limit_value` `:457`, `get_limit` `:474`, `period_start_iso` `:332`, `check_feature` `:613`) |
| Coverage guardrail | `qr_backend/tests/unit_tests/test_feature_gate_coverage.py` (must stay green) |
| Config / env | `qr_backend/src/config/settings/base.py` (`BSP_PROVIDER`, `BSP_API_BASE_URL`, `BSP_WEBHOOK_SECRET`; existing `WEBHOOK_SECRET_ENC_KEY` `:154`, `HASHING_SALT` `:131`); `phonenumbers` in `requirements.txt` |
| Worker capture row | `qr_cf_code/src/pages/reviewFunnel/classicTemplate.js` (consent label `:41`, form `:216`, star tap `:255-268`) |
| Worker routes + cron ping | `qr_cf_code/src/index.js` (`scheduled` `:44`, `*/5` branch `:78`, `/lead-submit/` `:162`, `/review-go/` `:257`; NEW `/review-contact/`, `/rr/`) |
| Worker cron config (**no change**) | `qr_cf_code/wrangler.toml` (`crons` `:53` already has `*/5 * * * *`) |
| Builder capture settings | `qr_frontend/src/components/qr-generator/content-types/review-funnel-rating-fields.tsx` + NEW `reminder-capture-fields.tsx` |
| React template mirror | `qr_frontend/src/components/qr-generator/templates/review-funnel/` (house rule — same PR) |
| Settings wizard + opt-outs | `qr_frontend/src/components/org/settings/MessagingSection.tsx` (NEW, mirrors `WebhooksSection.tsx`) + `settings-nav.tsx` |
| Contacts + stats UI | `qr_frontend/src/components/org/leads/`, `qr_frontend/src/components/org/qrs/ReminderStatsCard.tsx` (NEW) |
| Hooks | `qr_frontend/src/hooks/useReminders.ts` (NEW — mirrors `useWebhooks.ts:57-180`) |
| FE gating | `qr_frontend/src/hooks/useSubscription.ts` (`PlanFeatures` `:28`), `qr_frontend/src/lib/plan-features.ts` |
| Worker deploy | `qr_cf_code` — **`npm run deploy:prod` required**; no `wrangler.toml` change |
