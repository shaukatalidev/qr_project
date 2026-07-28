# TRD — API & Auth Rate Limiting

**Status:** Draft · **Author:** Engineering (Staff) · **Date:** 2026-07-27
**Priority:** Security/reliability hardening. The backend has exactly one throttle (`internal.py:1330–1344`) and no limiter of any kind. Two layers, two phases, and a deliberate refusal to add infrastructure we can avoid.
**Tiers:** **All plans, identical.** Burst ceilings for the paid API are *derived* from the existing per-tier `api_calls_per_month` rather than sold as a separate entitlement.
**Plan flags (NEW):** **None (recommended).** If overruled: `api_burst_per_minute` (int), seeded as a full-object `'{...}'::jsonb` blob and registered `inert`→`enforced` in the same PR — see §2.3.
**Migration slot:** **None in Phase 1.** Phase 2 (conditional) ships **`0046_rate_limiting.sql`**. **Provisional** — highest on disk is `0032_lemonsqueezy_variant_backfill.sql`; `0033`–`0043` are claimed by drafted-but-unapplied specs and `0044`/`0045` by concurrent specs. **Re-verify against `qr_backend/migrations/` at build time** — this repo has already shipped a fix for a stale slot number (`0026` was drafted as `0024`).
**Services touched:** `qr_backend` (Phase 1: one new utility + two call-site migrations + one new internal-ish endpoint; Phase 2: one middleware/dependency + one migration) · **Cloudflare dashboard** (WAF rate-limiting rules — configuration, not code) · **Supabase dashboard** (Auth rate limits — configuration) · `qr_frontend` (Phase 1: report failed sign-ins; optional burst-state copy). **`qr_cf_code` — no change.** No new QR type, no KV key, no template, no cron, so **no `npm run deploy:prod` gate**.
**Implements PRD:** API & Auth Rate Limiting. **Mirrors** the atomic-counter design of `increment_api_usage` (`api_public.py:170–177`) and the salted IP-hash convention of `internal.py:1332`.

**Verification note (2026-07-27, checked at `bdf4fed`):** every path, line, and table below was read, not assumed. Three corrections to the originating brief, load-bearing enough to restate here: **(1)** the backend has **no auth endpoints** — `src/api/routes/auth.py` defines one route, `POST /api/auth/verify-user` (line 76), and it is JWT-protected; all credential flows are Supabase GoTrue called from the browser, so no FastAPI limiter can ever see them. **(2)** `API_PREFIX = "/api"` (`src/config/settings/base.py:26`, no environment override), corroborated by `wrangler.toml`'s `BACKEND_URL = "https://api.qravio.app/api"` and the frontend's `NEXT_PUBLIC_API_URL=…:8000/api` — **`CLAUDE.md`'s `/api/v1/*` paths are stale and every path in this document uses the real prefix.** **(3)** `POST /api/contact` is JWT-authed (`contact.py:41`), not public — but it fires two Resend sends per call, one to a caller-supplied address, with no throttle.

---

## 1. Overview & Architecture

Rate limiting splits cleanly into two problems that want different mechanisms, and conflating them is how this gets built badly.

**Abuse prevention** is volumetric, per-IP, short-windowed, and must reject traffic *before* it costs anything. The right place for that is the edge, where the client IP is the TCP peer address and cannot be forged. **Fair-use limiting** is semantic, per-identity (API key / workspace / user), and must be precise about *which* identity exceeded *which* allowance. That needs application context the edge does not have.

So: **Layer 1 is Cloudflare WAF rate-limiting rules on `api.qravio.app`** (Phase 1, zero code, zero new spend). **Layer 2 is a Postgres-backed atomic-counter limiter inside FastAPI** (Phase 2, conditional on Phase 1 telemetry).

**Why not in-process counters:** `qr_backend/Dockerfile` runs `uvicorn … --workers 4` and `BACKEND_SERVER_WORKERS=4` is set in `.env`/`.env.example`. Four processes, four heaps, on one container — before Render's horizontal scaling is considered. A module-level `dict` leaks 4N× its configured allowance. This is disqualifying, not merely imprecise.

**Why not Redis:** it is the textbook answer and it is wrong for this system's shape. It costs real money monthly, adds a failure domain that must then be made fail-open (at which point it protects nothing during exactly the incident you bought it for), and buys sub-millisecond precision we do not need at these volumes. Postgres gives us a correct atomic counter through a pattern already shipped and tested here (`increment_api_usage`). §12 Q1 records the volume threshold that would change this answer.

**Why not Cloudflare KV or a Worker in front of the API:** KV is eventually consistent with propagation measured in tens of seconds — useless as a counter. Durable Objects would be correct, but the Worker currently fronts `r.qravio.app` scan traffic only (`wrangler.toml`), not `api.qravio.app`; putting a Worker in front of the API is a routing-architecture change far larger than the problem.

**Services touched**

| Service | Change |
|---|---|
| **Cloudflare (dashboard)** | WAF rate-limiting rules on `api.qravio.app` + an origin lock so Render is unreachable except via Cloudflare (§8). **Configuration only** — the rules are recorded in-repo as documentation, not applied by code. |
| **Supabase (dashboard)** | Auth rate limits (sign-in, sign-up, OTP, reset email, token refresh). The credential-stuffing control, because credentials never reach our backend. Values recorded in-repo. |
| `qr_backend` | **Phase 1:** new `src/utilities/client_ip.py`; migrate `auth.py:30` + `request.py:105–113` to it; extend `_log_login_event` to record failures; new `POST /api/auth/login-event` for the frontend to report failed sign-ins. **Phase 2:** new `src/utilities/rate_limit.py` + per-route dependency, `0046_rate_limiting.sql`, and migration of the ad-hoc lead throttle at `internal.py:1330–1344` onto the shared limiter. |
| `qr_frontend` | **Phase 1:** report failed `signInWithPassword` results to the new endpoint (`LoginClient.tsx:63`); correct the `X-RateLimit-*` prose in the developer docs. **Phase 2 (optional):** distinct copy for a burst 429 vs. a quota 429. |
| `qr_cf_code` | **No change.** No `recordScan` touch, no KV key, no template, no `scheduled()` branch, no `wrangler.toml` edit. The worker↔React template-mirroring rule does not apply. |

**Data flow — Layer 1 (edge), Phase 1**

```
client → Cloudflare edge (api.qravio.app, proxied)
  → WAF rate-limiting rule set, keyed on the TRUE client IP (TCP peer — unforgeable)
      · rule SKIP:  /api/health*, /api/internal/*, /api/razorpay/webhooks, /api/mor/webhooks
      · rule ANON:  /api/public/plans, /api/public/v1/preview/*, /api/public/v1/reports/*, /docs, /openapi.json
      · rule ALL:   everything else — broad volumetric ceiling
  → over ceiling ⇒ Cloudflare 429 at the edge; ZERO origin cost, no Python, no DB conn
  → under ceiling ⇒ origin (Render) with CF-Connecting-IP set by Cloudflare
        → RequestMiddleware → BearerTokenAuthMiddleware → router → handler
```

**Data flow — Layer 2 (application), Phase 2**

```
request reaches a rate-limited route (explicit per-route dependency, never global)
  → resolve identity key, most specific first:
        api_key_id (public API)  >  workspace_id  >  user_id  >  sha256(ip + HASHING_SALT)
  → increment_rate_limit(bucket_key, window_start, limit) RPC   [ONE round-trip, atomic]
  → hits > limit ⇒ 429 + Retry-After(s) + RateLimit-* headers   ← BEFORE increment_api_usage
                   (a throttled request costs the caller NOTHING against monthly quota)
  → else ⇒ continue: api_key_auth → increment_api_usage → handler
```

**The ordering in that last block is the single most important correctness property in this spec.** Today `api_public.py` increments the monthly counter and *then* checks it (line 174 before line 192), so a quota-exceeded call still burns a count. That is defensible for a quota. It is indefensible for a burst limiter: being told "slow down" must not also cost money. The burst check therefore runs **before** `api_key_auth`'s metering, as a route-level dependency ordered ahead of it.

---

## 2. Data Model & Migrations

### 2.1 Phase 1 — no migration, and that is the recommendation

Nothing in Phase 1 touches schema. Cloudflare rules and Supabase settings are configuration. The client-IP resolver is a pure function. Failed-login mirroring writes to `login_events`, which **already has a `status` column** — `security.py:100` selects it and `auth.py:35–42` writes it — that today only ever holds `'success'` because its one caller (`auth.py:101`) never passes anything else. We start writing `'failed'` into a column that already exists.

Adding a table here would be schema for its own sake. We do not.

### 2.2 Phase 2 — `0046_rate_limiting.sql` (conditional)

Ships **only** if Phase 1 telemetry shows abuse that a per-IP edge ceiling cannot catch — one authenticated identity spread across many IPs, or an API key hammering from a datacentre range we cannot blanket-ban. If Phase 1 suffices, this file is never written and the feature ships with no migration at all.

Two objects, nothing more. BEGIN/COMMIT-wrapped, idempotent, applied by hand in the Supabase SQL editor (no automated runner — see `migrations/README.md`).

```sql
-- Migration 0046: Rate limiting counters (fixed-window, cross-process).
-- SLOT IS PROVISIONAL — re-verify against migrations/ before applying.
-- Idempotent; apply in the Supabase SQL Editor.

BEGIN;

-- Fixed-window counter. One row per (bucket, window). Rows are ephemeral —
-- the newest window is the only one ever read; older rows exist for at most
-- one prune interval. bucket_key NEVER contains a raw IP (see §8).
--   bucket_key format: "<rule>:<identity-kind>:<identity>"
--     e.g. "pubapi:key:9f3c…", "contact:user:uuid", "preview:iph:7a2b…"
CREATE TABLE IF NOT EXISTS rate_limit_counters (
    bucket_key   text        NOT NULL,
    window_start timestamptz NOT NULL,   -- floor(now / window_seconds)
    hits         integer     NOT NULL DEFAULT 0,
    updated_at   timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (bucket_key, window_start)
);

-- Prune support. Partial-index-free: the table is small and the prune is a
-- range delete on the PK's second column, driven by an existing daily cron.
CREATE INDEX IF NOT EXISTS idx_rate_limit_counters_window
    ON rate_limit_counters (window_start);

ALTER TABLE rate_limit_counters ENABLE ROW LEVEL SECURITY;
-- No policies → only the service role (which bypasses RLS) can touch it.
-- Defence in depth; tenant isolation here is irrelevant (no tenant data).

-- Atomic increment + read-back in ONE round-trip. Deliberately the same shape
-- as increment_api_usage (api_public.py:170-177) — a single upsert returning
-- the NEW count, so the caller compares against the ceiling without a
-- read-modify-write race across the 4 uvicorn workers / N Render instances.
CREATE OR REPLACE FUNCTION increment_rate_limit(
    p_bucket_key   text,
    p_window_start timestamptz
)
RETURNS integer
LANGUAGE plpgsql
AS $$
DECLARE
    new_count integer;
BEGIN
    INSERT INTO rate_limit_counters (bucket_key, window_start, hits, updated_at)
    VALUES (p_bucket_key, p_window_start, 1, now())
    ON CONFLICT (bucket_key, window_start)
    DO UPDATE SET hits = rate_limit_counters.hits + 1,
                  updated_at = now()
    RETURNING hits INTO new_count;
    RETURN new_count;
END;
$$;

-- Prune. Called from the existing daily cron (see §11); no new trigger.
CREATE OR REPLACE FUNCTION prune_rate_limit_counters(p_older_than interval DEFAULT '2 hours')
RETURNS integer
LANGUAGE plpgsql
AS $$
DECLARE
    removed integer;
BEGIN
    DELETE FROM rate_limit_counters WHERE window_start < now() - p_older_than;
    GET DIAGNOSTICS removed = ROW_COUNT;
    RETURN removed;
END;
$$;

COMMIT;

-- Sanity (after COMMIT):
--   SELECT increment_rate_limit('test:user:abc', date_trunc('minute', now()));  -- ⇒ 1
--   SELECT increment_rate_limit('test:user:abc', date_trunc('minute', now()));  -- ⇒ 2
--   SELECT prune_rate_limit_counters('0 seconds'::interval);
```

**Fixed window, not sliding.** A sliding-window or token-bucket implementation needs either a second column set or per-request timestamp rows, and buys precision at the boundary that does not matter for an abuse control. The known artefact — up to 2× the ceiling across a window boundary — is acceptable when the ceiling is set at machine-scale, and it is the same trade the shipped monthly quota already makes.

**No plan-flag seed in the recommended path**, so `FEATURE_ENFORCEMENT` and `test_feature_gate_coverage` are untouched by this migration. That is a feature: no coverage-test ritual, no seed-parity risk.

### 2.3 If §8 of the PRD is overruled and a plan flag is added

The house convention is not optional. `test_feature_gate_coverage._seed_feature_keys()` (`tests/unit_tests/test_feature_gate_coverage.py:36–52`) discovers feature keys **only** by regex-scanning `r"'(\{[^']*\})'::jsonb"` blobs. A path-only `jsonb_set` seed leaves the key undiscovered and `test_registry_matches_plan_seed` fails it as stale — the exact trap `0026` documented.

```sql
-- 1) Seed as a full-object blob where ABSENT (regex-discoverable), non-custom only.
UPDATE plans
SET features = coalesce(features,'{}'::jsonb) || '{"api_burst_per_minute":30}'::jsonb
WHERE NOT (coalesce(features,'{}'::jsonb) ? 'api_burst_per_minute')
  AND coalesce(is_custom,false) = false;
-- 2) Per-tier values via path writes — lower(name) + is_custom guard.
UPDATE plans SET features = jsonb_set(coalesce(features,'{}'::jsonb),'{api_burst_per_minute}','100'::jsonb,true)
WHERE lower(name) = 'agency' AND coalesce(is_custom,false) = false;
```

Then add `"api_burst_per_minute": "enforced",  # rate_limit.py per-key burst ceiling` to `FEATURE_ENFORCEMENT` (`subscription.py:524`) **in the same PR**, add it to `_QUOTA_SPEC` as `{"source": "feature", "usage": None}` (value-only, exactly like `max_file_size_mb` and `card_ocr_scans_per_month`), and ensure the key is referenced from a source file **other than** `subscription.py` or `test_gate_enforced_flags_have_source_reference` fails.

The recommended path avoids all of this by computing the ceiling from `api_calls_per_month`, which is already seeded, already classified, and already enforced.

---

## 3. Backend Design

### 3.1 `src/utilities/client_ip.py` (NEW — Phase 1, the security foundation)

Everything downstream is worthless if the identity key is forgeable. Today there are three call sites and two conventions:

| Call site | Reads | Trustworthy? |
|---|---|---|
| `src/api/routes/auth.py:30` | `x-forwarded-for`, then `request.client.host` | **No** — XFF is client-appendable |
| `src/api/middlewares/request.py:112` | `x-forwarded-for`, then `request.client.host` | **No** — same |
| `qr_cf_code/src/utils/scan.js:20,29` | `CF-Connecting-IP` | Yes (runs *inside* Cloudflare) |

Both backend sites are logging-only today, so the present-day impact is log poisoning rather than a security bypass — but a limiter built on either helper is defeated by one header. This project has already paid for this exact class of mistake once: the Cloudflare-behind-Vercel header mix-up that served USD pricing to every user in India.

```python
def client_ip(request: Request) -> str:
    """Resolve the caller's IP. Authoritative header: CF-Connecting-IP.

    CF-Connecting-IP is set by Cloudflare and stripped-then-rewritten on every
    proxied request, so it cannot be forged BY A CLIENT WHOSE TRAFFIC ACTUALLY
    TRAVERSES CLOUDFLARE. It is trivially forged by anyone who can reach the
    origin directly. Trusting it is therefore conditional on the deployment
    guaranteeing that path (§8: origin lock). TRUST_CF_HEADERS is False in
    development so a local run never believes a header it can't verify.

    X-Forwarded-For is NEVER trusted for limiting: it is a client-appendable
    list, and the leftmost entry — which auth.py:30 and request.py:112 read
    today — is precisely the attacker-controlled one.
    """
```

- `TRUST_CF_HEADERS` (new setting, `base.py`; `False` in `development.py`, `True` in `staging.py`/`production.py`).
- When trusted and `CF-Connecting-IP` is **absent**, that is an anomaly, not a fallback: it means the request bypassed Cloudflare. Log at `WARNING` and treat the caller as unidentified — assign it to a shared `"unknown"` bucket with a **tighter** ceiling, never a more permissive one. Failing open here would hand an attacker the bypass.
- `hashed_client_ip(request) -> str` returns `sha256(ip + settings.HASHING_SALT).hexdigest()`, matching `internal.py:1332` exactly so we have one hashing convention on the backend.
- **Migrate `auth.py:30` and `request.py:105–113` to this helper.** Independently correct, ships in Phase 1, needs no limiter.

*(Noted, not fixed here: the Worker hashes IPs **unsalted and truncated to 16 hex** (`scan.js:11–17`) while the backend hashes **salted and full-length**. Two `ip_hash` schemes in one system. Out of scope — it belongs with `SCAN_FRAUD_DETECTION`, which owns that data — but it should not be discovered twice.)*

### 3.2 `src/api/routes/auth.py` — failed-login visibility (Phase 1)

`_log_login_event` (lines 28–43) already accepts `event_status` and already writes it to `login_events.status`. Its one caller (line 101) never passes anything but the default. So the table records **only successes**, and a million failed attempts against a customer produce zero rows. We cannot see credential stuffing even in hindsight.

Two changes:

1. Swap the IP read at line 30 for `client_ip(request)` (§3.1).
2. Add `POST /api/auth/login-event` — a small, **JWT-exempt** endpoint the login page calls when `signInWithPassword` returns an error, so a failed attempt is recorded against the email's user (resolved server-side; the endpoint takes an email and a status, never a password).

Three properties this endpoint must have, because it is unauthenticated by necessity:

- **It is a user-visible audit signal, never an enforcement input.** A client can lie in both directions — spam fabricated failures, or stay silent about real ones. Enforcement lives with Supabase and the edge (§4), where the client has no vote. Treating a self-reported failure as a lockout trigger would build the account-DoS the PRD explicitly rejects (§6.4).
- **It must not be an email-enumeration oracle.** It returns `204` unconditionally, in constant time, whether or not the address maps to a user. If the email is unknown, no row is written and the response is identical.
- **It is itself rate-limited** — per hashed IP, tightly, at both layers. An endpoint that writes a DB row for an unauthenticated caller is exactly what this spec exists to bound.

It joins `excluded_routes` in `main.py:60–77` alongside the other public prefixes. **`ORG_MFA_AUDIT_LOG` consumes `login_events`** — coordinate so both specs do not write the same column differently.

### 3.3 `src/utilities/rate_limit.py` (NEW — Phase 2)

One pure module, no HTTP of its own, so it is unit-testable without a server.

```python
@dataclass(frozen=True)
class Rule:
    name: str           # "pubapi" | "contact" | "ocr" | "anon" | "leadform"
    limit: int          # requests per window
    window_seconds: int # 60 | 3600
    scope: Literal["api_key", "workspace", "user", "ip"]

async def check(rule: Rule, identity: str, db: Client) -> Decision:
    """Increment the (rule, identity, window) bucket and decide.

    ONE RPC round-trip: increment_rate_limit returns the new count, so there is
    no read-modify-write race across the 4 uvicorn workers or N Render
    instances. Returns Decision(allowed, limit, remaining, retry_after).

    FAIL-OPEN on DB error, deliberately, and loudly. A limiter that 503s the
    whole API because a counter table hiccuped has converted a defence into an
    outage. Layer 1 is still standing underneath. Log at ERROR so the gap is
    never silent.
    """

def rate_limit(rule: Rule) -> Callable:
    """FastAPI dependency factory. Applied EXPLICITLY per route — never as
    global middleware, so /internal/* and /health cannot be swept in by an
    accidental prefix match (PRD R3/R4)."""
```

**Fail-open is a real trade and we are choosing it with eyes open.** Fail-closed protects against an attacker who can also break Postgres — but if Postgres is broken, the API is down anyway. Fail-open keeps a Postgres blip from becoming a total outage, and Layer 1 remains in force throughout. This differs from `api_public.py:157–166`, which fails **closed** on quota-resolution error — correct there, because that path guards *revenue* and over-serving is a billing error; here it guards *load*, and over-serving briefly is cheaper than refusing everyone. The divergence is intentional and documented.

**Explicit-per-route, never global.** A `BaseHTTPMiddleware` limiter would run on every request including `/api/health` (Render's own probes) and `/api/internal/*` (the Worker's scan posts). One careless prefix and we silently destroy customer analytics (PRD R3). A dependency applied route-by-route makes inclusion a positive act.

### 3.4 Rule table (Phase 2)

| Rule | Applies to | Scope | Ceiling | Window | Rationale |
|---|---|---|---|---|---|
| `pubapi` | `/api/public/v1/*` (via `api_public.py` router deps, **before** `api_key_auth`) | `api_key` | `clamp(api_calls_per_month / 250, 30, 600)` → Pro 30/min, Agency 100/min | 60s | Burst ceiling the monthly quota never provided |
| `contact` | `POST /api/contact` | `user` | 3 | 3600s | Two Resend sends per call, one to a caller-supplied address (`contact.py:56`) |
| `ai` | `POST /workspaces/{id}/vcard/ocr`, AI-analyst routes | `workspace` | 10 | 60s | Stops a month of Anthropic budget being spent in one second |
| `bulk` | QR bulk-create | `workspace` | 5 | 60s | Heavy DB + KV write amplification per call |
| `anon` | `/api/public/plans`, `/api/public/v1/preview/*.svg`, `/api/public/v1/reports/{token}` | `ip` (hashed) | 60 | 60s | CPU (segno render at `api_public.py:1099`) + token enumeration (`reports.py:260`) |
| `loginevent` | `POST /api/auth/login-event` | `ip` (hashed) | 20 | 3600s | Unauthenticated DB write |
| `leadform` | `POST /api/internal/lead-submit` | `ip` (hashed) | 10 | 3600s | **Migrates the existing throttle** at `internal.py:1330–1344` |

Ceilings are **starting points to be re-derived from observed p99** during shadow mode, not values to ship blind.

**`leadform` is the one `/api/internal/*` route that gets a limit**, and only because it already has one — a `SELECT count(*)` against `qr_lead_submissions` on every submission (`internal.py:1336–1343`), which is both slower than the RPC and a second implementation of the same idea. Moving it onto the shared limiter deletes code and makes it cheaper. Its identity comes from `payload.ip` (Worker-supplied, `internal.py:1226`), not from request headers, so the semantics do not change. **Every other `/internal/*` route stays unlimited** — see §4.

### 3.5 Routes explicitly never limited

Encoded as an assertion in tests (§10), not merely as a configuration convention:

- **`/api/health`, `/health/live`, `/health/ready`** (`health.py`) — Render's platform probes. A 429 here gets the instance recycled.
- **`/api/internal/scans`** (`internal.py:350`) — see §4.
- **`/api/razorpay/webhooks`** (`razorpay_routes.py:790`) and **`/api/mor/webhooks`** — a dropped webhook desynchronises billing state. Providers retry, but not forever. HMAC verification is already the gate.
- **`/api/auth/verify-user`** (`auth.py:76`) — fires once per session on a valid JWT; throttling it throttles login itself.

---

## 4. Cloudflare Worker / Edge Design

**No Worker code change.** No new KV key (the per-`shortCode` value's top-level keys are untouched), no `src/pages/*` template, no `handlers/` case, no `recordScan` field, no `scheduled()` branch, no `wrangler.toml` edit. The worker↔React template-mirroring rule does not apply — there is nothing to mirror — and consequently **`npm run deploy:prod` is not a gate for this feature.**

The edge work is entirely **Cloudflare dashboard configuration** on the `api.qravio.app` hostname, which is a different concern from the Worker on `r.qravio.app`.

**Rule set (recorded in-repo as documentation; applied in the dashboard):**

| # | Match | Key | Ceiling | Action |
|---|---|---|---|---|
| 0 | `path starts_with "/api/health"` **or** `"/api/internal/"` **or** `path in {"/api/razorpay/webhooks","/api/mor/webhooks"}` | — | — | **Skip** (evaluated first; ordering is the safety property) |
| 1 | `path in {"/api/public/plans"}` or `starts_with "/api/public/v1/preview/"` or `"/api/public/v1/reports/"` or `path in {"/docs","/openapi.json","/redoc"}` | client IP | ~120 / 60s | 429 |
| 2 | `path starts_with "/api/public/v1/"` (key-authed) | client IP | ~600 / 60s | 429 |
| 3 | everything else on the hostname | client IP | ~1200 / 60s | 429 |

Rule 0 is first and is a **skip**, not a high ceiling — an ordering bug here is the PRD's R3/R4 failure mode arriving through the back door.

**Two hard prerequisites, both unverified in-repo:**

1. **`api.qravio.app` must be proxied (orange-cloud) in the `qravio.app` zone.** Nothing in the repo proves this. `wrangler.toml` establishes the zone exists and that the Worker's `BACKEND_URL` targets that host, but the DNS record could be a grey-clouded `CNAME` straight to Render, in which case **Layer 1 does not exist**. This blocks Phase 0.
2. **Rule count must fit the Cloudflare plan.** If the plan allows fewer rules than the table above, collapse 2 and 3 into one broad rule and push the specificity into Layer 2.

**Worker-originated traffic and the `/internal/*` boundary — stated once, precisely.** Every `/api/internal/*` request originates from a Cloudflare Worker egress address (`scan.js:75–84`; the cron pings in `index.js`'s `scheduled()`). Per-IP limiting would therefore see the entire planet's scan traffic as a single client and throttle it as one. Worse, `recordScan` wraps its `fetch` in `.catch(() => {})` inside `ctx.waitUntil`: a 429 is swallowed, the visitor gets a flawless redirect, and the scan simply never existed — no retry, no dead-letter, no alarm, no signal to anyone. **Silent, permanent, invisible loss of the customer's analytics.** `/api/internal/*` is guarded by `x-internal-secret` (`internal.py:21–29`) and by the network path, and is excluded at both layers.

**Boundary with `SCAN_FRAUD_DETECTION` (concurrent spec, not yet on disk):** if a request arrives at `qr_cf_code`'s `fetch` handler for a short code, it is theirs — scan flooding, bot filtering, self-scan suppression, and any edge throttle on the scan path. If it arrives at the FastAPI application, it is ours. `/api/internal/scans` sits on **their** side of that line despite being a backend route, because it is Worker-relayed scan traffic: we exclude it, and they may throttle its source at the edge where the real scanner IP is visible. Neither spec builds a counter the other also builds.

---

## 5. Frontend Design

Phase 1 is two small changes; Phase 2 is optional polish.

### 5.1 Report failed sign-ins (`src/app/(auth)/login/LoginClient.tsx`)

`signInWithPassword` at line 63 returns `{ error }` on a bad credential. Today that error only renders a toast. Add a fire-and-forget POST to `/api/auth/login-event` with `{ email, status: 'failed' }` so the attempt reaches `login_events`.

Rules that matter here: **never** send the password or any part of it; **never** block or delay the UI on this call (`void fetch(...).catch(() => {})` — the user's failed-login experience must not depend on our telemetry); and **never** branch UI on the response, which is an unconditional `204` by design (§3.2). Uses plain `fetch`, not `authApi`, because there is no session yet — `authApi`'s interceptor would resolve an empty token and add nothing.

### 5.2 Developer-docs correction (`src/lib/constants/api-docs*.ts`, `src/components/docs/`, `/developers`)

The docs currently present `X-RateLimit-*` without saying they are monthly. Add a table making the two namespaces unambiguous:

| Header | Meaning | Window | Emitted by |
|---|---|---|---|
| `X-RateLimit-Limit/Remaining/Reset` | **Monthly quota** — `api_calls_per_month` | billing month; `Reset` is a Unix epoch | unchanged, since API launch |
| `RateLimit-Limit/Remaining/Reset` | **Burst rate limit** | seconds; `Reset` is seconds-from-now | new (Phase 2) |
| `RateLimit-Policy` | e.g. `120;w=60` | self-describing | new (Phase 2) |
| `Retry-After` | seconds to wait | both 429s | quota 429 exists today (`api_public.py:196`) |

Plus a prose note: a burst 429 does **not** consume monthly quota.

### 5.3 Burst-throttled state (Phase 2, optional)

The card-OCR and AI-analyst surfaces already render a quota-exhausted state. Reuse the component, switch copy on the error `code`: `"rate_limited"` → "You're going a bit fast — try again in a few seconds" (no upgrade CTA; the user has done nothing wrong); `"card_ocr_quota_exceeded"` → the existing upgrade path. If split out, the new component follows the house rules — ≤200 lines, kebab-case filename, one export, shadcn primitives, Tailwind tokens, no inline styles.

**No `PlanFeatures` change** in the recommended path (no new flag — §2.3).

---

## 6. External-Service Integration

**No AI. No email. No PDF. No new SDK, and no new dependency in `requirements.txt`** — the limiter uses `hashlib`, `datetime`, and the existing Supabase client. That is a design goal, not an accident: `slowapi` would need a shared backend to be correct here anyway, so it would buy syntax and not correctness.

**Cloudflare** — dashboard configuration. `CF_ACCOUNT_ID` / `CF_API_TOKEN` / `CF_ZONE_ID` already exist (`base.py:68–76`) and could drive the rules via API, but rate-limiting rules change rarely and a hand-applied, reviewed rule set is safer than code that can rewrite the WAF. Recorded in-repo as documentation. *(Existing Cloudflare API usage for reference: `src/utilities/cloudflare_saas.py`, `src/utilities/cloudflare_kv.py`.)*

**Supabase Auth** — the credential-stuffing control, and the only place it can live (PRD §2.1). Dashboard settings, values recorded in-repo:

| Setting | Guards |
|---|---|
| Sign-in / token-grant rate limit | Credential stuffing |
| Sign-up rate limit | Mass account creation |
| OTP / magic-link send + verify limits | OTP brute force; SMS/email spend |
| Password-recovery email limit | Reset-email flooding, sender reputation |
| Token-refresh limit | Refresh-token abuse |

Verify these **live** — configure, then run a scripted burst and confirm GoTrue rejects it. A setting believed-set and not-set are indistinguishable until an incident.

**New env var:** `TRUST_CF_HEADERS` (bool; `False` in development, `True` in staging/production) — `base.py` + `.env.example`. No other config change. **No `_dmarc.qravio.app` gate** (this feature sends no email — it *reduces* email). **No `ANTHROPIC_API_KEY` dependency.**

---

## 7. API Contracts

### 7.1 Burst 429 (Phase 2)

```http
HTTP/1.1 429 Too Many Requests
Retry-After: 37
RateLimit-Limit: 120
RateLimit-Remaining: 0
RateLimit-Reset: 37
RateLimit-Policy: 120;w=60
X-RateLimit-Limit: 3000
X-RateLimit-Remaining: 2612
X-RateLimit-Reset: 1785110400

{ "detail": { "code": "rate_limited", "limit": 120, "window_seconds": 60, "retry_after": 37 } }
```

`RateLimit-Reset` is **seconds-from-now** (IETF draft semantics). `X-RateLimit-Reset` remains a **Unix epoch** (`_next_period_epoch`, `api_public.py:91`) — byte-identical to today. The two namespaces intentionally use different units *because they measure different things*; `RateLimit-Policy` makes the burst pair self-describing so nobody has to infer it.

**`X-RateLimit-Remaining` is not decremented by this rejection.** The burst dependency runs before `api_key_auth`, so `increment_api_usage` (`api_public.py:174`) never executes. A throttled request is free.

### 7.2 Monthly quota 429 (unchanged — do not touch)

```http
HTTP/1.1 429 Too Many Requests
Retry-After: 1814400
X-RateLimit-Limit: 3000
X-RateLimit-Remaining: 0
X-RateLimit-Reset: 1785110400

{ "detail": "Monthly API quota of 3,000 calls exceeded for this workspace. Upgrade your plan or wait for the next billing period." }
```

Exactly as emitted today at `api_public.py:192–206`. **No change of any kind** — status, headers, body, and copy are a shipped external contract.

Same split applies to `ai_analyst.py:433–446` and `vcard_ocr.py:113–126`: existing quota response untouched; a burst rejection returns `{"code": "rate_limited"}` and is distinguishable from `{"code": "card_ocr_quota_exceeded"}`.

### 7.3 Failed-login report (Phase 1)

```http
POST /api/auth/login-event          (public — in main.py excluded_routes)
{ "email": "user@example.com", "status": "failed" }

204 No Content        ← ALWAYS, whether or not the email maps to a user
```

Unconditional `204` in constant time: any variation (status, body, latency) turns this into an email-enumeration oracle. No password field exists in the schema — it is not optional, it is absent, so a client cannot send one by accident. Rate-limited per hashed IP at both layers.

---

## 8. Security, Privacy & Abuse

**The bypass that matters: header spoofing.** `CF-Connecting-IP` is authoritative *only* for traffic that actually traversed Cloudflare. Anyone reaching Render directly can set it to a fresh random value per request and every per-IP limit evaporates. So the header trust is only as good as the network path, and the network path must be locked:

- **Origin lock (required for Layer 1 to be real):** the Render service must be unreachable except through Cloudflare — Cloudflare Authenticated Origin Pull (mTLS), or an origin allowlist of Cloudflare IP ranges, or Render's own private-networking equivalent. Without it, Layer 1 is a suggestion. **Track as a Phase 0 deliverable alongside the orange-cloud check (§4).**
- **Never trust `X-Forwarded-For` for limiting.** It is a client-appendable list and the leftmost element — which `auth.py:30` and `request.py:112` read today — is the attacker-controlled one. Migrating both to `client_ip()` is Phase 1 work.
- **Missing `CF-Connecting-IP` in production is an anomaly, not a fallback.** Log `WARNING`, bucket the caller as `"unknown"` with a **tighter** ceiling. Failing open here hands over the bypass.
- **The `x-internal-secret` header** (`internal.py:21–29`) stays the guard for `/internal/*`. Note it is compared with `!=` rather than `hmac.compare_digest` — a timing-oracle nit that is out of scope here but worth a one-line fix whenever that file is next touched.

**Privacy.** No raw IP is ever persisted by the limiter. `bucket_key` carries `sha256(ip + settings.HASHING_SALT)` (`base.py:131`), matching `internal.py:1332`. `rate_limit_counters` rows live at most one prune interval (default 2h) and contain no tenant data, no user id, and no PII — a bucket key plus an integer. RLS is enabled with no policies so only the service role (which bypasses RLS anyway) can touch it: defence in depth, since tenant isolation is not a concern for a table with no tenant data.

**The `login-event` endpoint** is the one new unauthenticated write surface, and it is handled adversarially by construction: constant-time unconditional `204` (no enumeration), no password field in the schema, records only what the client claims (never an enforcement input — §3.2), and rate-limited per hashed IP at both layers.

**No account lockout, deliberately.** A lockout keyed on email lets an unauthenticated stranger deny any customer access to their own product; the control becomes the outage. Per-IP limits punish the *source*; Supabase's own backoff slows the *attacker*; the victim keeps their account. If per-account enforcement is ever required, progressive delay is the shape — costs the attacker throughput, never closes the door.

**Abuse surfaces closed:** email relay via `POST /api/contact` (`contact.py:56` mails a caller-supplied address; capped at 3/user/hour), AI-budget burn (10/workspace/min), report-token enumeration (`reports.py:260`; 60/IP/min), anonymous CPU burn on the SVG renderer (`api_public.py:1099`; same rule).

**Consent gate and scan analytics: unaffected.** No change to `recordScan`, `qr_scan_events`, `qr_scan_counters`, or `build_entitlements`. No edge inference, no new client capture, no new cookie.

---

## 9. Performance, Scale & Cost

**Layer 1 costs zero at origin.** A rejected request never reaches Render — no Python frame, no DB connection, no log line on our side. This is the entire reason it goes first: the requests we most want to stop are the ones we least want to pay to evaluate.

**Layer 2 costs one DB round-trip** on limited routes only — a single-row upsert on a `(text, timestamptz)` primary key, the same shape as `increment_api_usage`, which already runs on every public-API request in production. On a route that then performs an Anthropic vision call (p95 target <4s) or two Resend sends, that round-trip is noise. It is **not** applied to any hot path: the scan path is untouched, health is untouched, and ordinary dashboard reads are untouched.

**Table size is bounded by construction.** Rows are `(bucket_key, window_start, hits, updated_at)` — well under 200 bytes. At a pessimistic 10,000 distinct buckets per minute the table holds ~1.2M rows before a 2-hour prune, and the prune is a range delete on an indexed column. Realistically it will hold thousands of rows.

**Prune rides an existing cron.** `qr_cf_code/src/index.js`'s `scheduled()` already fires `"0 6 * * *"` → `/internal/run-reports{daily}` + `/internal/run-alerts` + `/internal/reclamation-sweep`. Adding `prune_rate_limit_counters()` to an existing daily internal handler needs **no new cron trigger and therefore no `wrangler.toml` change and no `npm run deploy:prod` gate** — which matters, because a new cron registers only after a prod Worker deploy.

**Cost delta: zero new monthly spend.** Cloudflare rate-limiting rules are within the plan we already pay for; Supabase Auth limits are settings; the counter table is negligible storage on the existing database. Compare against Redis: ~$7–25/month, a new failure domain, and a new operational surface — for precision this workload does not need. §12 Q1 records the volume at which that changes.

**Scale ceiling, honestly stated.** The Postgres limiter is comfortable to roughly a few thousand limited requests per second. Beyond that the round-trip stops being free and the answer becomes edge-side counting or a dedicated store. We are orders of magnitude below it, and Layer 1 absorbs volumetric spikes before Layer 2 ever sees them.

---

## 10. Testing Strategy

**Backend (pytest, `qr_backend/tests/unit_tests/`)**

- `test_client_ip`: `CF-Connecting-IP` wins when `TRUST_CF_HEADERS`; a **spoofed `X-Forwarded-For` never changes the resolved IP** (the headline bypass test); `TRUST_CF_HEADERS=False` ignores `CF-Connecting-IP` entirely; a missing `CF-Connecting-IP` in a trusting environment yields the tighter `"unknown"` bucket and logs `WARNING` — **never** a more permissive bucket; a forged `CF-Connecting-IP` rotated per request lands in distinct buckets *only* when trust is off (documenting that the mitigation is the origin lock, not the code).
- **`test_rate_limit_never_touches_internal`** (highest-consequence invariant, PRD R3): assert **no** route under `/api/internal/` except `lead-submit` carries a `rate_limit` dependency — enumerated by introspecting `backend_app.routes`, not by reading a config constant, so adding an unguarded limit to `internal.py` fails the build. Plus a functional test: 500 rapid `POST /api/internal/scans` from one source all return `200`.
- `test_rate_limit_never_touches_health_or_webhooks`: same introspection for `/api/health*`, `/api/razorpay/webhooks`, `/api/mor/webhooks` (PRD R4).
- `test_burst_does_not_consume_quota`: a `pubapi`-rejected request must leave `api_usage` unchanged — assert `increment_api_usage` is **not** called, and that `X-RateLimit-Remaining` is identical before and after (the §1 ordering property).
- `test_quota_429_unchanged`: golden test on `api_public.py`'s existing 429 — status, all four headers, and the exact `detail` string. **This test's purpose is to fail if anyone "tidies up" the header names.**
- `test_rate_limit_atomic`: N concurrent `increment_rate_limit` calls never exceed the ceiling (the multi-worker property; the RPC is the reason it holds).
- `test_rate_limit_window_rollover`: the counter resets at the boundary and `Retry-After` is ≤ `window_seconds` and > 0.
- `test_rate_limit_fail_open`: an RPC exception allows the request and logs `ERROR` — never a 500, never a 503.
- `test_login_event_endpoint`: `204` for a known email, `204` for an unknown one, **identical body and headers**; no `login_events` row for an unknown email; a row with `status='failed'` for a known one; the schema rejects a `password` field; over-limit → 429.
- `test_contact_rate_limit`: the 4th contact POST in an hour returns 429 and **sends zero Resend emails** (assert on mocked `resend.Emails.send`) — the point of the rule is the send, not the HTTP response.
- `test_lead_submit_migration`: the migrated `leadform` rule preserves the existing 10/IP/hour behaviour (`internal.py:1330–1344`) using `payload.ip`, not request headers — the Worker relays the IP in the body and that must not silently become "the Cloudflare egress IP for all lead submissions on Earth".
- **`test_feature_gate_coverage` stays green** — trivially in the recommended path, since no plan flag is added. If §2.3 is taken, add the seed-blob + registry assertions.

**Frontend (Vitest)**: a failed `signInWithPassword` fires the login-event POST and a successful one does not; the password never appears in the request body; a login-event network failure does not break or delay the login UI; the burst-throttled state renders distinct copy from the quota state and shows **no** upgrade CTA.

**Worker**: none — no Worker change in this feature.

**Manual / operational (not CI)**: verify `api.qravio.app` is orange-clouded; verify the origin refuses a request that bypasses Cloudflare; run a scripted burst against Supabase Auth sign-in and confirm GoTrue rejects it. **These three are the load-bearing controls in Phase 1 and none of them can be asserted from pytest** — they are checklist items with named owners, not tests.

---

## 11. Observability & Rollout

**Phase 0 — Verify (blocking; hours).** Is `api.qravio.app` proxied through Cloudflare? Can the Render origin be reached directly? Does the Cloudflare plan allow the §4 rule count? **Write no limiter code until these are answered** — a "no" on the first reshapes the plan (§12 Q2).

**Phase 1a — Configure (no deploy).** Cloudflare rules in *log/count* mode; size ceilings from a week of real traffic rather than intuition. Supabase Auth limits set and verified live. Then flip rules to *block*. Rule definitions and Supabase values committed in-repo as documentation so they are reviewable and recoverable.

**Phase 1b — Code-only (one backend deploy, no migration).** `client_ip.py`; migrate `auth.py:30` and `request.py:105–113`; `POST /api/auth/login-event` + its `main.py` exclusion; `TRUST_CF_HEADERS` in `base.py`/`.env.example`; frontend failed-login reporting; developer-docs header correction.
**Acceptance:** a spoofed `X-Forwarded-For` changes nothing anywhere; a failed sign-in produces a `login_events` row with `status='failed'`; `/developers` describes `X-RateLimit-*` as a monthly quota; no existing test regresses.

**Phase 2 — Application limiter (gated on Phase 1 data).** Apply `0046` (**re-verify the slot first**). Deploy in **shadow mode** — evaluate, emit headers, log, reject nothing — for one week. Review the would-have-blocked set for false positives and re-derive ceilings from observed p99. Then enforce **one rule at a time**, smallest blast radius first: `contact` → `loginevent` → `anon` → `ai` → `bulk` → `leadform` → `pubapi` last (largest external contract). Add `prune_rate_limit_counters()` to the existing daily internal handler.
**Acceptance:** burst 429 carries `Retry-After` in seconds and does not decrement `X-RateLimit-Remaining`; `/internal/scans` provably unreachable by the limiter; concurrent requests across 4 workers cannot exceed a ceiling; the header-spoofing bypass fails.

**Deploy order:** Cloudflare rules → Supabase settings → backend (Phase 1b) → frontend → *[gate]* → migration → backend (shadow) → enforce per-rule. **No Worker deploy at any point.**

**Kill switch:** `RATE_LIMIT_MODE` env var — `off` | `shadow` | `enforce`. Reverting to `shadow` needs an env change, not a deploy. Cloudflare rules disable from the dashboard in seconds. Every layer reverts independently.

**Observability:**
- Structured log per throttle decision: `rule`, `scope`, `identity_kind` (**never the raw identity for `ip` scope — the hash only**), `hits`, `limit`, `allowed`, `path`. On-call attributes any 429 in one query.
- `WARNING` when `CF-Connecting-IP` is absent in a trusting environment (a bypass indicator, not noise — alert on a sustained rate).
- `ERROR` on limiter fail-open, so a silent protection gap is impossible.
- Cloudflare analytics for Layer 1 — blocked-request rate per rule, top offending IPs.
- **Alert on any nonzero throttled-`/internal/*` count.** It should be structurally impossible; if it ever fires, we are losing customer scan analytics silently and it is a page, not a ticket.
- Dashboard the failed-login rate from `login_events` once it exists — today it is structurally zero.

---

## 12. Open Technical Questions & Risks

1. **Redis — when does the answer change?** *Recommend: not now.* Postgres + edge covers this workload at zero new spend, using a pattern already shipped (`increment_api_usage`). Revisit when limited-route throughput sustains ~1,000 req/s, or when we need genuine sliding-window/token-bucket precision, or when a second service needs the same counters. Until then Redis is a monthly bill, a new failure domain, and a fail-open decision that must be made anyway — buying precision we do not need.

2. **Is `api.qravio.app` proxied through Cloudflare?** *Unresolved — blocking.* Repo evidence is circumstantial (the zone exists; the Worker targets the host; `wrangler.toml` explicitly warns that zone topology is unconfirmed). **If grey-clouded:** either orange-cloud it (recommended — also gets DDoS protection, and `wrangler.toml`'s warning about wildcard routes is about *Worker* routes, which is a separate concern from proxying a hostname) or promote Layer 2 to Phase 1 and accept that floods reach Render.

3. **Header namespace: `RateLimit-*` beside `X-RateLimit-*`, or `X-Burst-*`?** *Recommend the IETF `RateLimit-*` split.* It is the standards-track spelling, clients increasingly understand it natively, and `RateLimit-Policy` makes the pair self-describing. Renaming the existing headers is not an option — `/api/public/v1` is a live documented contract. The residual risk is integrator confusion, mitigated by the docs table (§5.2) and the golden test (§10) that fails if anyone "tidies" the old names.

4. **Ship Phase 2 at all?** *Recommend deciding on data, and being genuinely willing to answer no.* If Phase 1 telemetry shows the edge catching everything, the best version of this feature is one migration lighter and one code path smaller. Phase 2 exists for abuse the edge structurally cannot see — one identity across many IPs, or an API key in a datacentre range we cannot blanket-ban.

5. **Failed-login reporting: client-side endpoint, or poll Supabase's auth audit log?** *Recommend the endpoint for v1* (simple, immediate, no new integration) **with the audit log noted as the trustworthy long-term source.** Client-reported failures are unverifiable in both directions — hence "telemetry, never enforcement" (§3.2). If these rows ever need to drive a decision, switch to the audit log first.

6. **Fail-open vs. fail-closed.** *Resolved: fail-open, loudly.* A limiter that 503s the API because a counter table hiccuped has converted a defence into an outage, and Layer 1 still stands. This deliberately diverges from `api_public.py:157–166`, which fails closed on quota-resolution error — correct there, because that path guards revenue and over-serving is a billing error; here it guards load, and briefly over-serving is cheaper than refusing everyone.

7. **Fixed window's 2× boundary artefact.** *Accepted.* At machine-scale ceilings the boundary case is immaterial, and the shipped monthly quota already makes the same trade. Sliding windows cost a second column set or per-request rows for precision that changes no outcome.

8. **The `SCAN_FRAUD_DETECTION` boundary.** *Resolved, restated for the record:* their side is the Worker's `fetch` handler for a short code; ours is the FastAPI application. `/api/internal/scans` is on **their** side despite being a backend route. Neither spec builds a counter the other also builds. **Coordinate before either merges** — the spec does not yet exist on disk, so this boundary is agreed in prose and needs to be re-checked when it lands.

9. **Two `ip_hash` schemes in one system.** The Worker hashes unsalted, truncated to 16 hex (`scan.js:11–17`); the backend hashes salted, full-length (`internal.py:1332`). Not this spec's to fix — the Worker's hash feeds `qr_scan_events`, which `SCAN_FRAUD_DETECTION` owns — but flagged so it is not discovered a third time.

10. **`internal.py:24` compares `x-internal-secret` with `!=` rather than `hmac.compare_digest`.** A timing oracle against a high-entropy secret over the network is a weak attack, so this is not urgent — but it is a one-line fix worth taking whenever that file is next opened.

### Appendix — Key Files

| Concern | File |
|---|---|
| Client-IP resolver (NEW, Phase 1) | `qr_backend/src/utilities/client_ip.py` |
| Call sites to migrate | `qr_backend/src/api/routes/auth.py:30`; `src/api/middlewares/request.py:105–113` |
| Failed-login mirroring | `qr_backend/src/api/routes/auth.py:28–43,101` (`_log_login_event`) + new `POST /api/auth/login-event` |
| Public-route exclusion list (authoritative inventory) | `qr_backend/src/main.py:60–77`; prefix match at `src/api/middlewares/auth_bearer.py:68–70` |
| Rate-limit engine (NEW, Phase 2) | `qr_backend/src/utilities/rate_limit.py` |
| Migration (NEW, Phase 2, **slot provisional**) | `qr_backend/migrations/0046_rate_limiting.sql` |
| Atomic-counter pattern to mirror | `qr_backend/src/api/routes/api_public.py:170–177` (`increment_api_usage`) |
| Monthly-quota contract to preserve verbatim | `qr_backend/src/api/routes/api_public.py:185–206`; `ai_analyst.py:433–446`; `vcard_ocr.py:113–126` |
| Existing throttle to migrate | `qr_backend/src/api/routes/internal.py:1330–1344` (lead submissions) |
| Never-limit: internal router | `qr_backend/src/api/routes/internal.py:21–35` (`verify_internal_secret`), `record_scan_event` at line 350 |
| Never-limit: health / webhooks | `qr_backend/src/api/routes/health.py`; `razorpay_routes.py:790`; `mor_routes.py` |
| Unmetered email spend to cap | `qr_backend/src/api/routes/contact.py:34–61`; `src/utilities/email.py` |
| Anonymous CPU / token surfaces | `qr_backend/src/api/routes/api_public.py:1099` (preview SVG); `reports.py:260` (report token); `subscription.py:804` (public plans) |
| Config | `TRUST_CF_HEADERS`, `RATE_LIMIT_MODE` in `src/config/settings/base.py` + `.env.example`; `HASHING_SALT` at `base.py:131` |
| Multi-process deployment proof | `qr_backend/Dockerfile` (`--workers 4`); `.env.example` (`BACKEND_SERVER_WORKERS=4`) |
| Edge config target (no code) | `qr_cf_code/wrangler.toml` (zone/hostnames, for reference only — **no Worker change**) |
| Auth flows (all Supabase, browser-side) | `qr_frontend/src/app/(auth)/login/LoginClient.tsx:63`; `signup/SignupClient.tsx:78`; `forgot-password/ForgotPasswordClient.tsx:45` |
| Plan-flag ritual (only if §2.3 is taken) | `qr_backend/src/api/routes/subscription.py:524`; `tests/unit_tests/test_feature_gate_coverage.py:36–52` |
| Worker | **No change** (no KV, no type, no template, no cron, no `wrangler.toml` edit) |
