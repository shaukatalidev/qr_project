# TRD — Outbound Webhooks + Zapier/Make Integration

**Status:** Draft · **Author:** Engineering (Staff) · **Date:** 2026-06-24
**Priority:** Automation/integration wave — "make Qravio a node in the customer's stack," sitting on the shipped public API (`api_public.py`, `/api/public/v1`).
**Tiers / flags:** **Pro** (3 endpoints, `scan` + `lead.submitted`) · **Agency** (20 endpoints, all events incl. Phase-2 `scan.milestone`, Zapier/Make app). Free/Starter: none. NEW flags `outbound_webhooks` (bool) + `webhook_endpoints_max` (int — Pro `3`, Agency `20`). Both registered in `FEATURE_ENFORCEMENT` and flipped `inert→enforced` in the same PR.
**Migration:** `0020_outbound_webhooks.sql` (reserved slot; current DB highest applied = `0013`; slots 0014–0018 reserved by the analytics roadmap). Ships **Phase-1 schema only** — `scan.milestone`'s once-only marker column splits to a later migration.
**Services touched:** `qr_backend` (dispatcher + CRUD route + 2 ingestion hooks + gate + sweeper endpoint), `qr_frontend` (Settings → Webhooks section + hook + docs). **`qr_cf_code`: no change in Phase 1** — the existing `ctx.waitUntil → POST /internal/scans` and `/internal/lead-submit` fan-out points already exist; dispatch is strictly backend-side. A Worker cron is **only** added if the durability sweeper runs on the edge (Phase 2, gated on `npm run deploy:prod`).
**Split from:** `API_ACCESS_PRD.md`, which explicitly deferred webhooks-out. This is that deferred half.

**Rev (2026-06-24, post eng-review):** Fixed the load-bearing correctness bug — the schema stored `secret_hash = sha256(secret)` (one-way) yet `_attempt` must `sign(secret_plain, …)` on every delivery; changed to `secret_enc` (Fernet, new `WEBHOOK_SECRET_ENC_KEY` env), with list/read never selecting it. Hardened SSRF-at-send to be TOCTOU-proof (connect to the validated IP with Host/SNI preserved, not an independent httpx re-resolve; bounded-chunk 10 KB read, ignore Content-Length). Added a DB-claim/lease so the inline `BackgroundTasks` attempt and the sweeper can't double-POST one row; clarified retries are sweeper-driven via `next_attempt_at` (no in-process `asyncio.sleep`) and survive restart; added backoff jitter. Defined idempotency-key semantics (retry reuses key; manual redeliver mints a new one). Tightened the scan hook: dispatch only after `workspace_id` resolves and only for non-blocked scans. Added delivery-log retention TTL + value-level log redaction for lead PII, the env var, and matching tests; confirmed the `outbound_webhooks`+`webhook_endpoints_max` registry pair follows the existing `api_access`+`api_calls_per_month` precedent (coverage parity intact).

---

## 1. Overview & Architecture

The dispatch seam already exists and is free. Every scan produces a backend write at `internal.py POST /scans` (`record_scan_event`, line 318), invoked from the Worker via `ctx.waitUntil` **after** the redirect/landing page is served (`qr_cf_code/src/utils/scan.js`, line 63). Lead submissions land at `/internal/lead-submit` (line 741) the same way. Both already accept `BackgroundTasks` (lead-submit injects it at line 743). We hang an **outbound fan-out** off both points: after the row is persisted, enqueue a `BackgroundTasks` job that loads the workspace's active webhook endpoints subscribed to that event, persists one `webhook_deliveries` row per endpoint (`status='pending'`), and attempts an HMAC-signed `POST` inline. Failures retry on a fixed backoff; exhaustion → `dead_letter`. A **sweeper** endpoint (`POST /internal/webhook-sweep`) re-attempts stuck `pending`/`retrying` rows so deliveries survive a backend restart — durability without a new queue service.

**Why backend-side only:** the Worker keeps doing exactly what it does today (fire-and-forget POST to the backend). We never add outbound HTTP to the scan hot path. `BackgroundTasks` fires *after* the `POST /scans`/`/internal/lead-submit` response returns to the Worker, so a slow or down customer endpoint can never delay scan recording or the Worker's `waitUntil`.

```
SCAN:  user scans → Worker serves redirect → ctx.waitUntil → POST /internal/scans
         backend: insert qr_scan_events + counters (unchanged, returns 200)
         backend BackgroundTasks: dispatch_event("scan", workspace_id, qr_id, payload)
            → SELECT active endpoints WHERE 'scan' = ANY(events)
            → per endpoint: insert webhook_deliveries(pending) → SSRF-revalidate → signed POST
            → 2xx ⇒ delivered; else retry/backoff; exhausted ⇒ dead_letter

LEAD:  Worker → POST /internal/lead-submit → insert qr_lead_submissions (unchanged)
         backend BackgroundTasks: dispatch_event("lead.submitted", …)

MGMT:  FE authApi (JWT) → /workspaces/{id}/webhooks CRUD (require_can_* + check_feature)
SWEEP: cron (backend scheduler or Worker cron, Phase 2) → POST /internal/webhook-sweep (x-internal-secret)
```

**New backend files:** `src/utilities/webhook_dispatch.py` (dispatcher + signing + SSRF + retry), `src/api/routes/webhooks.py` (CRUD, mirrors `pixels.py`). **Changed:** `internal.py` (2 fan-out hooks + sweep endpoint), `subscription.py` (registry), `endpoints.py` (register router).

---

## 2. Data Model & Migrations

`migrations/0020_outbound_webhooks.sql` — BEGIN/COMMIT-wrapped, idempotent (`IF NOT EXISTS`), applied by hand in the Supabase SQL editor (no automated runner). The Supabase client uses the **service role key → bypasses RLS**; every query in `webhooks.py` filters `workspace_id` explicitly (no RLS reliance).

```sql
-- Migration 0020: Outbound Webhooks (Pro/Agency `outbound_webhooks`)
-- Build migration for the flag 0009/preflight seeded false everywhere.
-- Ships Phase-1 schema ONLY: scan.milestone marker columns split to a later slot.
-- Idempotent; apply in Supabase SQL Editor. No automated runner — see README.

BEGIN;

CREATE TABLE IF NOT EXISTS webhook_endpoints (
    id              uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    workspace_id    uuid        NOT NULL REFERENCES workspaces(id) ON DELETE CASCADE,
    url             text        NOT NULL,                    -- https-only, SSRF-validated at write
    events          text[]      NOT NULL DEFAULT '{}',       -- {'scan','lead.submitted'}
    description      text,
    secret_enc      text        NOT NULL,                    -- Fernet-encrypted plaintext secret (NOT a hash — see §3.1; we must SIGN with it on every delivery, so it must be reversible). Key = WEBHOOK_SECRET_ENC_KEY env.
    secret_prefix   text        NOT NULL,                    -- 'whsec_' + first 6 chars, for display
    status          text        NOT NULL DEFAULT 'active',   -- active|paused|failing
    consecutive_failures int    NOT NULL DEFAULT 0,
    created_by      uuid,
    created_at      timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS webhook_deliveries (
    id               uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    endpoint_id      uuid        NOT NULL REFERENCES webhook_endpoints(id) ON DELETE CASCADE,
    workspace_id     uuid        NOT NULL,                   -- denormalized for tenant-scoped reads
    event_type       text        NOT NULL,                   -- scan|lead.submitted|ping
    idempotency_key  text        NOT NULL,                   -- uuid; receiver dedupes on this
    payload          jsonb       NOT NULL,
    status           text        NOT NULL DEFAULT 'pending', -- pending|retrying|delivered|dead_letter
    attempt_count    int         NOT NULL DEFAULT 0,
    next_attempt_at  timestamptz,                            -- backoff anchor for the sweeper
    response_status  int,
    response_ms      int,
    last_error       text,
    created_at       timestamptz NOT NULL DEFAULT now(),
    delivered_at     timestamptz
);

CREATE INDEX IF NOT EXISTS idx_webhook_endpoints_ws
    ON webhook_endpoints (workspace_id);
CREATE INDEX IF NOT EXISTS idx_webhook_deliveries_endpoint_created
    ON webhook_deliveries (endpoint_id, created_at DESC);
-- sweeper hot path: stuck rows due for retry
CREATE INDEX IF NOT EXISTS idx_webhook_deliveries_sweep
    ON webhook_deliveries (next_attempt_at)
    WHERE status IN ('pending','retrying');

-- ── Plan flags (HOUSE CONVENTION: coalesce + is_custom guard + lower(name)) ──
-- 1) seed false/0 on every non-custom plan missing the key (preflight parity)
UPDATE plans SET features = jsonb_set(coalesce(features,'{}'::jsonb),'{outbound_webhooks}','false'::jsonb,true)
  WHERE NOT (coalesce(features,'{}'::jsonb) ? 'outbound_webhooks') AND coalesce(is_custom,false)=false;
UPDATE plans SET features = jsonb_set(coalesce(features,'{}'::jsonb),'{webhook_endpoints_max}','0'::jsonb,true)
  WHERE NOT (coalesce(features,'{}'::jsonb) ? 'webhook_endpoints_max') AND coalesce(is_custom,false)=false;
-- 2) flip the bool for Pro + Agency
UPDATE plans SET features = jsonb_set(features,'{outbound_webhooks}','true'::jsonb,true)
  WHERE lower(name) IN ('pro','agency') AND coalesce(is_custom,false)=false;
-- 3) tier-differentiated endpoint cap
UPDATE plans SET features = jsonb_set(features,'{webhook_endpoints_max}','3'::jsonb,true)
  WHERE lower(name) = 'pro' AND coalesce(is_custom,false)=false;
UPDATE plans SET features = jsonb_set(features,'{webhook_endpoints_max}','20'::jsonb,true)
  WHERE lower(name) = 'agency' AND coalesce(is_custom,false)=false;

COMMIT;

-- Sanity:
--   SELECT name, features->>'outbound_webhooks', features->>'webhook_endpoints_max'
--     FROM plans WHERE coalesce(is_custom,false)=false ORDER BY price_monthly;
```

No `scan.milestone` columns ship now (no `milestone_fired_at`/`qr_webhook_milestones` table) — Phase 2 gets its own migration on a stable v1 payload contract.

---

## 3. Backend Design

### 3.1 `src/utilities/webhook_dispatch.py` (new)

- `make_secret() -> tuple[str, str, str]` → `(plain='whsec_'+token_urlsafe(32), enc=fernet_encrypt(plain), prefix='whsec_'+plain[6:12])`. **Critical divergence from `api_tokens`:** `api_tokens` are *verified* (hash the presented token, `compare_digest`), so a one-way SHA256 hash is correct there. A webhook secret is *used to **sign*** every outbound delivery, so it **must be recoverable** — store it **encrypted at rest (Fernet / `cryptography`)** under a new `WEBHOOK_SECRET_ENC_KEY` env var, **never** as a SHA256 hash. `_decrypt_secret(row)` is called only inside `_attempt` immediately before `sign(...)`; the plaintext is never logged, never returned by the list/read endpoints, and only re-shown by create/rotate (which already hold the freshly generated plaintext in memory, no decrypt needed).
- `sign(secret_plain: str, timestamp: str, raw_body: bytes) -> str` → mirror of `razorpay_routes.py` (lines 202–208), **inverted to sign**: `hmac.new(secret_plain.encode(), f"{timestamp}.".encode()+raw_body, hashlib.sha256).hexdigest()`. We sign `timestamp + "." + body` (R6 replay defense).
- `validate_webhook_url(url: str) -> None` — **SSRF guard (R1)** at write time: require scheme `https`; reject if host resolves (via `socket.getaddrinfo`) to any address in RFC1918, loopback (`127/8`, `::1`), link-local (`169.254/16`, `fe80::/10`), unique-local (`fc00::/7`), or metadata (`169.254.169.254`). Uses `ipaddress.ip_address(...).is_private/.is_loopback/.is_link_local`. Raises `HTTPException(400)`.
- `async dispatch_event(workspace_id, event_type, payload, db)` — the `BackgroundTasks` entry point: `if not await check_feature(workspace_id, "outbound_webhooks", db): return` (dispatch-eligibility gate); load active endpoints `db.table("webhook_endpoints").select("*").eq("workspace_id", workspace_id).eq("status","active").execute()`, filter `event_type in row["events"]`; for each, insert a `pending` delivery row then `await _attempt(delivery, endpoint, db)`.
- `async _attempt(...)` — **SSRF at send (R1, TOCTOU-hard):** `validate_webhook_url` returns the **resolved IP set**; `_attempt` connects to the **validated IP** (httpx `transport`/explicit-IP connect, or a custom resolver) with the original `Host`/SNI preserved, so httpx does **not** independently re-resolve to a now-rebound private IP between our check and the connect. Reject any address family that resolves to a mix of public+private. `httpx.AsyncClient(timeout=5.0, follow_redirects=False)`; cap response read 10 KB (read in bounded chunks — do **not** trust `Content-Length`); on 2xx → `status='delivered'`, reset `consecutive_failures=0`; else compute backoff `[0s,60s,600s,3600s][attempt]` + **jitter** (±20%, R3 thundering-herd), set `next_attempt_at`, `status='retrying'`; after 4 attempts → `dead_letter`, increment `consecutive_failures`, and **auto-pause** the endpoint at 15 consecutive failures (R3) — flip `status='paused'` + (Phase 2) Resend owner email **gated on DMARC**. The sweeper uses `next_attempt_at <= now()` so backoff is honored across process restarts (not `asyncio.sleep` in-process, which dies with the worker).

Headers on every POST: `Content-Type: application/json`, `X-Qravio-Event`, `X-Qravio-Timestamp` (unix), `X-Qravio-Signature: sha256=<hex>`, `X-Qravio-Idempotency-Key`, `User-Agent: Qravio-Webhooks/1`.

### 3.2 `src/api/routes/webhooks.py` (new, mirrors `pixels.py`)

`router = APIRouter(prefix="/workspaces", tags=["Webhooks"])`. Every handler resolves the workspace via the existing `require_workspace_role`/`require_can_*` deps (`src/api/dependencies/permissions.py`) and calls `check_feature(workspace_id, "outbound_webhooks", db)` (async — **awaited**), 403 if false.

| Method/Path | Perm | Behavior |
|---|---|---|
| `GET /workspaces/{ws}/webhooks` | `require_can_read` | list endpoints (**never** select/return `secret_enc`; expose `secret_prefix`, `status`, last delivery) |
| `POST /workspaces/{ws}/webhooks` | `require_can_create` | `validate_webhook_url`; enforce `get_limit(ws, db, "webhook_endpoints_max")` (sync; `-1`=∞) by counting active rows → **409** over cap; `make_secret()`; insert; **return plaintext secret once** |
| `PATCH /workspaces/{ws}/webhooks/{id}` | `require_can_update` | edit events/description/pause/resume |
| `POST …/{id}/rotate-secret` | `require_can_update` | new secret, returned once |
| `POST …/{id}/test` | `require_can_update` | enqueue a synthetic `ping` delivery via `dispatch_event` |
| `DELETE …/{id}` | `require_can_delete` | hard delete (cascades deliveries) |
| `GET …/{id}/deliveries` | `require_can_read` | recent `webhook_deliveries` for the endpoint (drawer), ordered `created_at DESC` |
| `POST …/deliveries/{did}/redeliver` | `require_can_update` | clone payload → new `pending` row → attempt. **Idempotency-key semantics:** retries of the *same* delivery row reuse the **same** `idempotency_key` (receiver dedupes a flaky-network retry); a *manual redeliver* mints a **new** `idempotency_key` (it is an intentional re-send the receiver should treat as new). Document both in the verification recipe so receivers dedupe correctly. |

These are **JWT-authed under the org app** (NOT excluded in `main.py` — the `BearerTokenAuthMiddleware` validates the Supabase token). Register in `endpoints.py`: `router.include_router(router=webhooks_router)`.

### 3.3 Ingestion hooks (`internal.py`)

- `record_scan_event` (line 318, currently `(payload, request, db)` — **no `background_tasks` yet**): add `background_tasks: BackgroundTasks` to the signature. Fan out **only after** `payload.workspace_id` is resolved (it is `None` on entry and looked up at lines 328–331 — the early `return {"status":"error"}` path at line 333 must **not** dispatch) **and only for scans that were actually recorded** (skip the dispatch if a scan-limit/disabled block short-circuited the insert — do not webhook a blocked scan): `background_tasks.add_task(dispatch_event, payload.workspace_id, "scan", _scan_payload(payload), db)`. Wrapped so a dispatcher failure never alters the existing `{"status":"ok"}` return. **Note:** the `db` client passed into the task is the request-scoped supabase-py REST client; it is a stateless HTTP wrapper (no pooled session), so it is safe to use after the response returns.
- `lead_submit` (line 741, already has `background_tasks`): after the insert, `background_tasks.add_task(dispatch_event, workspace_id, "lead.submitted", _lead_payload(clean_data, qr_id, qr_name), db)`.
- New `POST /internal/webhook-sweep` on the internal router (already router-wide `Depends(verify_internal_secret)`): selects `webhook_deliveries` where `status IN ('pending','retrying') AND next_attempt_at <= now()`, re-attempts each. Driven by the **backend process scheduler** (preferred, no new infra) or a Worker cron (Phase 2). The sweep run also **prunes `webhook_deliveries`** older than the retention TTL (R7) in the same pass. **Double-delivery guard:** the inline `BackgroundTasks` attempt and the sweeper can race on the same row. Before attempting, **claim** the row with a conditional update — `UPDATE webhook_deliveries SET status='retrying', next_attempt_at = now()+interval '90s' WHERE id=:id AND status IN ('pending','retrying') AND (next_attempt_at IS NULL OR next_attempt_at <= now())` and proceed only if it affected 1 row (a soft lease; supabase-py `.update().eq("id").in_("status",[...])` then check returned rows). This makes redelivery at-least-once without two concurrent POSTs for the same attempt. Also set the new row's initial `next_attempt_at = now()` so the sweeper can recover an inline attempt that the process died mid-flight.

### 3.4 Gating registry (`subscription.py`)

Add to `FEATURE_ENFORCEMENT` (same PR, `enforced`):
```python
"outbound_webhooks": "enforced",      # webhooks.py CRUD + webhook_dispatch.dispatch_event check_feature
"webhook_endpoints_max": "enforced",  # webhooks.py POST get_limit cap (count active rows)
```
`test_feature_gate_coverage` asserts registry↔seed parity; the 0020 preflight seed (`false`/`0` everywhere) keeps it green. **No `build_entitlements` change** — webhooks are not edge-enforced; the Worker never reads them.

---

## 4. Cloudflare Worker / Edge Design

**Phase 1: no Worker change.** The fan-out points are entirely backend-side. The Worker continues to `ctx.waitUntil(recordScan(...))` → `POST /internal/scans` and to POST `/internal/lead-submit` exactly as today. **No new KV keys** (webhook config is workspace-wide DB state, never snapshotted into the per-shortCode KV value's ~11 top-level keys). **No template↔React mirroring** is triggered (no new scan page). The scan payload the dispatcher forwards is the same `ScanEventPayload` already built in `scan.js` — `qr_id`, `workspace_id`, `country_code`/geo, `ip_hash`, `session_id`, `device_type` — so **no raw IP leaves the edge** (R7: we forward `ip_hash`, never the IP).

**Phase 2 (conditional):** if the durability sweeper runs as a **Worker cron** rather than the backend scheduler, add a `scheduled()` branch in `src/index.js` (alongside the existing free-scan-reset cron) that calls `POST /internal/webhook-sweep` with `x-internal-secret`, plus a `[triggers] crons` entry in `wrangler.toml` (dev + prod). Per the verified Worker-env note, **a new cron registers only after `npm run deploy:prod`** — a hard GA gate on the sweeper. `scan.milestone` (Phase 2) is computed backend-side at scan ingestion against accurate `qr_scan_events` row counts (R5), not the lossy `qr_scan_counters`, with a once-only marker — still no edge change.

---

## 5. Frontend Design

### 5.1 `PlanFeatures` (`src/hooks/useSubscription.ts`)
Add to the interface:
```ts
outbound_webhooks: boolean;     // Pro+
webhook_endpoints_max: number;  // 0 / 3 / 20
```

### 5.2 `useWebhooks` hook (`src/hooks/useWebhooks.ts`, new)
Mirror `usePixels.ts` — `authApi` (Supabase JWT via interceptor), TanStack Query v5 with a key factory:
```ts
const webhookKeys = {
  list: (ws: string) => ['webhooks', ws] as const,
  deliveries: (ws: string, id: string) => ['webhooks', ws, id, 'deliveries'] as const,
};
```
Exports: `useWebhooks(ws)`, `useCreateWebhook(ws)`, `useUpdateWebhook`, `useRotateSecret`, `useTestWebhook`, `useDeleteWebhook(ws)`, `useDeliveries(ws, id)`, `useRedeliver`. Create/rotate responses carry the one-time `secret`; mutations `invalidateQueries` on the list key. No `useEffect + fetch`.

### 5.3 `WebhooksSection.tsx` (`src/components/org/settings/`, new — mirrors `PixelsSection`/`BrandingSection`)
- Gate: `canAccessFeature(subscription, 'outbound_webhooks')` (`src/lib/plan-features.ts`). Non-entitled tiers render an `UpgradeGate`-style card: "Push scans & leads to your stack. Upgrade to Pro." (Free/Starter), with a Pro→Agency teaser ("20 endpoints, scan-milestone alerts, the Zapier app — upgrade to Agency").
- Endpoint table (shadcn/ui; **live blue-600/gray org-app pattern**, per the Dash-Theme-Drift note — not the indigo spec): URL (truncated), event badges, status badge (`active`/`paused`/`failing`), last delivery, created date. Empty state uses the org `EmptyState` primitive.
- Add-endpoint form: `react-hook-form + zod` — `url` (`z.string().url()` + `.refine(v => v.startsWith('https://'))`), event checkboxes, optional description. On success the secret renders in a copy-once card (same UX as the shipped API-key creation).
- Per-endpoint actions: Send test ping, Rotate secret, Pause/Resume, Delete. **Delivery-log drawer** (`useDeliveries`): event, HTTP status, attempt count, latency, timestamp, **Redeliver** button on failed/dead-lettered rows.
- 200-line limit, one export per file, kebab-case filenames → split `WebhooksTable.tsx`, `WebhookRow.tsx`, `AddWebhookForm.tsx`, `DeliveryDrawer.tsx`. Wire into the existing settings page (`src/app/org/[slug]/(dash)/settings/`) beside `PixelsSection`/`BrandingSection`.

### 5.4 QR detail (`QRDetails.tsx`)
Informational only (v1): an overview-tab note — "Webhooks: N endpoints will receive scans of this QR" — when the workspace has active `scan`-subscribed endpoints. No per-QR config (endpoints are workspace-wide, like pixels).

### 5.5 Docs (`src/lib/constants/api-docs*.ts`, `src/components/docs/`, `/developers`)
Add a data-driven **Webhooks** section: event catalog, payload shapes, the signature-verification recipe (language-agnostic + Python/Node), the retry/backoff schedule, idempotency guidance, and Phase-2 Zapier/Make "Connect" cards.

---

## 6. AI / External-Service Integration

**No AI.** **New env var:** `WEBHOOK_SECRET_ENC_KEY` (Fernet key, in backend `.env` / Render env + `.env.example`) for at-rest encryption of endpoint signing secrets — see §3.1; rotating it requires a re-encrypt migration of `secret_enc`, so treat it as a long-lived secret. **Email (conditional):** auto-pause owner notices use Resend (`src/utilities/email.py`). Per the verified mail note, **`_dmarc.qravio.app` is not yet published** — any new auth/notification email is a deliverability risk. **GA gate:** the auto-pause email ships only after `_dmarc.qravio.app` (`v=DMARC1; p=none`) is published; until then auto-pause flips status silently and surfaces in the UI only. No PDF/WeasyPrint. **Zapier/Make** are external apps built on the public API + these webhooks (zero new bespoke backend); they live in Zapier/Make infra.

---

## 7. API Contracts

```http
POST /workspaces/{ws}/webhooks      (JWT, require_can_create)
{ "url": "https://hooks.zapier.com/abc", "events": ["scan","lead.submitted"], "description": "Zapier" }
201 → { "id":"uuid","url":"...","events":[...],"status":"active",
        "secret_prefix":"whsec_a1b2c3","secret":"whsec_…shown once…","created_at":"..." }
409 → { "detail":"Endpoint limit reached for your plan (max 3). Upgrade to Agency." }
403 → { "detail":"Outbound webhooks require a Pro or higher plan." }
400 → { "detail":"URL must be https and must not resolve to a private/internal address." }
```

Outbound delivery (what the customer receives):
```http
POST https://hooks.zapier.com/abc
X-Qravio-Event: lead.submitted
X-Qravio-Timestamp: 1782518400
X-Qravio-Signature: sha256=9f86d0818…
X-Qravio-Idempotency-Key: 7c1f…-uuid

{ "event":"lead.submitted","id":"7c1f…","created_at":"2026-06-24T10:00:00Z",
  "workspace_id":"uuid",
  "data":{ "qr_id":"uuid","qr_name":"Booth A","fields":{"email":"a@b.co","name":"Sam"} } }
```
Scan event `data`: `{ "qr_id","country_code","region","city","device_type","ip_hash","session_id","scanned_at" }` — **never raw IP**. `ping` event `data`: `{ "message":"Qravio test ping" }`.

Verification recipe (documented): `expected = hmac_sha256(secret, f"{X-Qravio-Timestamp}." + raw_body); compare_digest(expected, sig); reject if |now - timestamp| > 300s; dedupe on X-Qravio-Idempotency-Key.`

---

## 8. Security, Privacy & Abuse

- **Auth & tenant isolation:** CRUD is JWT-authed under the org app (not excluded in `main.py`); `require_can_*` enforce role; every Supabase query filters `workspace_id` explicitly because the **service role key bypasses RLS**. `webhook_deliveries` reads filter both `endpoint_id` and the workspace.
- **SSRF (R1, top risk):** https-only + public-DNS-only at **write time** and **re-resolved at delivery time** (DNS-rebinding); redirects disabled; 5 s timeout; 10 KB response cap; metadata/RFC1918/loopback/link-local/unique-local blocked. This is the central security test suite.
- **Signing/replay (R6):** per-endpoint HMAC-SHA256 over `timestamp + "." + body`, `compare_digest` (mirrors `razorpay_routes.py`); secret stored only as `sha256` hash, shown once, rotatable. Documented 5-min freshness window + idempotency-key dedupe ⇒ at-least-once.
- **Amplification (R3):** per-endpoint fixed backoff, auto-pause after 15 consecutive dead-letters; Agency's higher rate cap is the packaging lever for the scan firehose (R4 — docs steer most automations to `lead.submitted`/`scan.milestone`).
- **PII (R7):** scan payloads carry `ip_hash`/geo, never raw IP; lead payloads carry only configured form fields. All transport https-only. No new PII added to the scan payload; the EU consent posture is unaffected (consent gates scan-page marketing tags, not server-to-server delivery). **However `lead.submitted` exports lead PII (email/name) to a customer-controlled URL — Qravio is the processor and the customer is the controller of that onward transfer.** Minimum bar: (a) the delivery-log / `webhook_deliveries.payload` JSONB stores lead PII at rest — set a **retention TTL** (sweeper also prunes `webhook_deliveries` older than the workspace's `analytics_retention_days`, or a fixed 30-day cap, whichever is shorter) so PII does not accumulate forever in the log; (b) document in the ToS/DPA that enabling a `lead.submitted` webhook is a customer-directed onward transfer; (c) redact lead field *values* from `logger` lines (log field **names/counts only**, never values).

---

## 9. Performance, Scale & Cost

- **0 ms p95 added to `POST /scans`** — dispatch runs in `BackgroundTasks` after the response (KPI: `POST /scans` p95 unchanged vs baseline). The hot path inserts one `pending` row only when active endpoints exist for that event.
- **Indexes:** `idx_webhook_deliveries_endpoint_created` (drawer), `idx_webhook_deliveries_sweep` (partial, sweeper), `idx_webhook_endpoints_ws` (dispatch lookup).
- **Cost:** outbound HTTP via `httpx`; bounded by 5 s timeout + 10 KB read + tier rate cap. `resolve_plan()`'s 30 s cache absorbs the dispatch-eligibility `check_feature`. No new infra (sweeper rides the existing scheduler/cron).
- **Scale guard:** `scan` is documented high-volume; per-endpoint concurrency cap + Agency-only higher delivery rate. Delivery-log reconciliation target ±1% of dispatched events (counts read from `webhook_deliveries` rows, never a denormalized counter — Open-Q #3 resolved "yes").

---

## 10. Testing Strategy

- **pytest (`qr_backend/tests/unit_tests/`):** SSRF matrix (`10.x`, `169.254.169.254`, `127.0.0.1`, `::1`, `fe80::`, `fc00::`, public host) rejected at write **and** at delivery; **DNS-rebind test** (host that resolves public at write, private at send → blocked because `_attempt` connects to the validated IP, not a re-resolve); **secret round-trip** (`fernet_encrypt`→store→`_decrypt_secret`→`sign` produces a sig the documented recipe verifies — proves the secret is reversible, *not* hashed); signature round-trip vs a known receiver; backoff schedule + jitter + dead-letter after 4 attempts; auto-pause at 15; **double-delivery guard** (concurrent inline + sweeper claim the same row → exactly one POST); **redeliver mints a new idempotency key, a retry reuses the same one**; `webhook_endpoints_max` cap returns 409 on the 4th Pro endpoint; Free workspace CRUD → 403; dispatcher never raises into `record_scan_event`/`lead_submit` (mock a down endpoint, assert `/scans` still returns `{"status":"ok"}`); **blocked/scan-limited scan does NOT dispatch**; **delivery-log retention prune** drops rows past TTL. **`test_feature_gate_coverage` stays green** (0020 preflight seed + both registry entries, mirroring the `api_access`+`api_calls_per_month` bool-flag-plus-int-limit precedent).
- **Vitest/Playwright (`qr_frontend`):** `WebhooksSection` gate (entitled vs gated), add-form zod https refinement, secret-shown-once, delivery drawer render. Note the **~29 pre-existing FE test failures** are the documented baseline — do not count them as regressions.
- **Worker:** none in Phase 1 (no edge change). Phase 2 sweeper cron gets a `scheduled()` test if it runs on the edge.

---

## 11. Observability & Rollout

**Deploy order (Phase 0–1, no edge change):**
1. Apply `0020` in the Supabase SQL editor; run the sanity SELECT (Pro/Agency = `true`/`3`/`20`, Free/Starter = `false`/`0`).
2. Deploy backend: dispatcher + `webhooks.py` + ingestion hooks + sweep endpoint + registry flip (`inert→enforced` same PR, coverage test green). Validate end-to-end against a request-bin on a seed workspace; confirm `POST /scans` p95 unchanged.
3. Deploy frontend behind a FE constant flag (1-week internal + 3–5 design-partner beta), then flip GA.

**Observability:** structured logs at each delivery (`endpoint_id`, `event_type`, `status`, `response_status`, `response_ms`); the delivery log is the customer-facing audit surface; loud `logger.error` on dispatcher exceptions (same discipline as the scan-limit fail-open log). Watch dead-letter rate (< 2% of endpoints) and delivery success (≥ 99% within the retry window).

**Phase 2 gates:** (a) `scan.milestone` ships with its own migration (once-only marker, `qr_scan_events` counts); (b) Zapier/Make apps on the versioned v1 payload contract; (c) auto-pause emails ship **only after `_dmarc.qravio.app` is published**; (d) if the sweeper is a Worker cron, it registers **only after `npm run deploy:prod`** — gate sweeper GA on the prod worker deploy.

---

## 12. Open Technical Questions & Risks

1. **Durable queue vs `BackgroundTasks`+`pending`-row sweeper?** Recommend the sweeper (no new infra): persist `pending` first, attempt inline, sweep stuck rows.
2. **Sweeper home:** backend process scheduler (no prod-deploy gate, preferred) vs Worker cron (registers only after `deploy:prod`). Recommend backend scheduler for Phase 1.
3. **Auto-pause threshold:** 15 consecutive dead-letters + owner email (email blocked on DMARC).
4. **Delivery-log counts** always from `webhook_deliveries` rows, never a denormalized counter (resolved: yes).
5. At extreme scan volume a future per-endpoint sampling/batch may be needed (R4) — Agency rate cap is the near-term lever.

### Appendix — Key Files

| Concern | File |
|---|---|
| Dispatcher + signing + SSRF + retry | `qr_backend/src/utilities/webhook_dispatch.py` (new) |
| CRUD route (mirror `pixels.py`) | `qr_backend/src/api/routes/webhooks.py` (new) |
| Fan-out hooks + sweep | `qr_backend/src/api/routes/internal.py` (`record_scan_event` ~318, `lead_submit` ~741, new `/internal/webhook-sweep`) |
| HMAC pattern to mirror | `qr_backend/src/api/routes/razorpay_routes.py` (~202–222) |
| Auth/secret template | `qr_backend/src/api/routes/security.py` + `api_public.py` (`api_tokens`, `token_prefix`, sha256) |
| Gating | `qr_backend/src/api/routes/subscription.py` (`FEATURE_ENFORCEMENT`, `check_feature` async, `get_limit` sync) |
| Router registration | `qr_backend/src/api/endpoints.py`; JWT (not excluded) in `src/main.py` |
| Migration | `qr_backend/migrations/0020_outbound_webhooks.sql` (new) |
| FE section/hook | `qr_frontend/src/components/org/settings/WebhooksSection.tsx`, `src/hooks/useWebhooks.ts` (new); `useSubscription.ts` `PlanFeatures`; `plan-features.ts` |
| Docs / Zapier-Make | `qr_frontend/src/lib/constants/api-docs*.ts`, `src/components/docs/`, `/developers` |
