# PRD — API & Auth Rate Limiting

**Status:** Draft · **Author:** Product · **Date:** 2026-07-27
**Priority:** Security/reliability hardening. Not a customer-visible feature and not a packaging lever — a control that stops one caller from spending the whole platform's money, CPU, or email reputation. Ship it because the ceiling today is "whatever the attacker's laptop can emit."
**Tiers:** **All plans.** Abuse limits are universal and identical for everyone. Fair-use burst ceilings are *derived* from the per-plan quota that already exists (`api_calls_per_month`), not sold separately.
**Plan flags:** **None (recommended).** Rate limiting is an abuse control, not a capability; packaging it creates the incentive to under-protect cheap tiers. If product overrules this, the one flag to add is `api_burst_per_minute` (int) — seeded as a full-object `'{...}'::jsonb` blob and registered `inert`→`enforced` in the same PR (house convention; `test_feature_gate_coverage` stays green). See §8.
**Split from:** `API_ACCESS_PRD.md` (which shipped the *monthly quota* and the `X-RateLimit-*` headers that this spec has to disambiguate) and the auth-hardening half of `ORG_MFA_AUDIT_LOG_PRD.md`. Scan-flood abuse belongs to the concurrently-drafted `SCAN_FRAUD_DETECTION` spec — see §12.

**Verification note (2026-07-27):** every claim below was checked against the repo at `bdf4fed`. **Three findings materially change the shape of this feature** and are called out in §2: (1) the FastAPI backend has **no auth endpoints at all** — credentials never reach it, so the "unthrottled `/auth/login`" gap is real but lives in Supabase, not in our code; (2) the API prefix is **`/api`**, not `/api/v1` as `CLAUDE.md` states; (3) `POST /api/contact` is **JWT-authed**, not public — but it is still an unmetered outbound-email surface.

---

## 1. TL;DR / Summary

Qravio has no rate limiter. There is exactly one throttle in the entire backend — a hand-rolled "10 lead submissions per IP per hour" count-query at `qr_backend/src/api/routes/internal.py:1330–1344`. Everything else is unbounded: the public plan list, the public QR-preview SVG renderer, the public report-token reader, both payment webhooks, and every authenticated endpoint including the two that spend real money per call (Resend email on `POST /api/contact`, Anthropic tokens on the OCR and AI-analyst routes).

The headers that *look* like a rate limit — `X-RateLimit-Limit/Remaining/Reset`, emitted from `api_public.py:185–206`, `ai_analyst.py:433–446`, `vcard_ocr.py:113–126` — are a **monthly billing quota**, not a rate limit. A Pro API key can legally spend its entire 3,000-call allowance in sixty seconds. The product advertises throttling it does not have.

This spec ships rate limiting in **two layers, in two phases**:

- **Phase 1 — no migration, no new infra, mostly configuration.** A Cloudflare WAF rate-limiting rule set in front of `api.qravio.app` gives an unspoofable per-IP volumetric ceiling on every path. Supabase Auth's own rate limits (dashboard settings) close the credential-stuffing / OTP-brute-force / auth-email-spend hole, because that traffic never touches our backend. Plus three code-only correctness fixes: one trustworthy client-IP helper, failed-login mirroring so we can *see* an attack, and a header-namespace decision that avoids breaking existing API consumers.
- **Phase 2 — one small migration (`0046_rate_limiting.sql`), only if Phase 1 telemetry justifies it.** A Postgres atomic-counter limiter for *semantic* per-identity burst limits on named expensive endpoints — reusing the exact `increment_api_usage` RPC pattern already shipped at `api_public.py:170–177`, which works correctly across the 4 uvicorn workers and N Render instances that make in-process counters wrong.

**We deliberately do not add Redis.** It is real monthly cost, a new failure domain, and a new dependency for volumes that Postgres and the Cloudflare edge handle for free. §12 records the conditions under which that answer changes.

## 2. Problem & Motivation

### 2.1 The credential-stuffing surface is real, but it is not where the brief said it was

The highest-severity abuse surface for any SaaS is unthrottled authentication. Qravio's is unthrottled. **But it is not in this repo.**

`qr_backend/src/api/routes/auth.py` defines exactly one route — `POST /api/auth/verify-user` (line 76) — and it is JWT-protected, because it is *not* in the `excluded_routes` list at `src/main.py:60–77`. There is no `register`, no `login`, no `forgot-password`, no `verify-otp` endpoint in the FastAPI application. Grep confirms it; so does the frontend, which calls Supabase GoTrue **directly from the browser**:

| Flow | Call site |
|---|---|
| Password login | `qr_frontend/src/app/(auth)/login/LoginClient.tsx:63` — `supabase.auth.signInWithPassword` |
| Signup | `qr_frontend/src/app/(auth)/signup/SignupClient.tsx:78` — `supabase.auth.signUp` |
| Password reset | `qr_frontend/src/app/(auth)/forgot-password/ForgotPasswordClient.tsx:45` — `supabase.auth.resetPasswordForEmail` |
| OAuth | `LoginClient.tsx:110`, `SignupClient.tsx:95`, `ConnectedAccountsCard.tsx:37` |
| Password re-auth | `qr_frontend/src/components/org/settings/security/ChangePasswordForm.tsx:42` |

So credential stuffing, OTP brute force, and reset-email flooding all hit `https://<project>.supabase.co/auth/v1/*`. Our middleware, our routers, and any limiter we write in Python are **structurally incapable of seeing that traffic**. This is not a reason to relax — it is a reason to fix it in the right place. Building a FastAPI limiter for endpoints that do not exist would be theatre.

**It gets worse, and this is the part worth acting on:** we cannot currently *detect* an attack either. `_log_login_event` (`auth.py:28–43`) takes an `event_status` parameter defaulting to `"success"`, and its one and only caller (`auth.py:101`) never passes anything else. The `login_events` table — surfaced to users at `security.py:98–105` and in the data export at `security.py:378–385` — therefore contains **only successful logins**. A million failed password attempts against a customer's account produce exactly zero rows in our database. We are blind by construction.

### 2.2 The `X-RateLimit-*` headers are a monthly quota, and that naming collision misleads

Three routes emit `X-RateLimit-Limit`, `X-RateLimit-Remaining`, `X-RateLimit-Reset`:

- `api_public.py:185–206` — derived from `api_calls_per_month` via the `increment_api_usage` RPC (line 174); `X-RateLimit-Reset` is `_next_period_epoch(period)` (line 91), i.e. **the start of next month's billing window**.
- `ai_analyst.py:433–446` — same shape, `ai_analyst_queries_per_month`.
- `vcard_ocr.py:113–126` — same shape, `card_ocr_scans_per_month`.

Every one of them is a calendar-scale usage meter wearing the clothes of a per-second throttle. An integrator reading `X-RateLimit-Remaining: 2847` reasonably concludes they may burst; nothing stops them, and the 429 they eventually get says "Monthly API quota … exceeded" with a `Retry-After` measured in **weeks** (`api_public.py:197`). That is a genuinely bad developer experience and it is also a lie about our protections.

We cannot rename these headers: `/api/public/v1` is a shipped, documented, key-authenticated surface with real consumers, and silently changing header names breaks their client code. §8 and TRD §7 record the decision — **keep `X-RateLimit-*` meaning the monthly quota, forever; emit the new burst limiter under the IETF standards-track `RateLimit-*` names (no `X-` prefix)**, and fix the *prose* in the developer docs to call the old one a quota.

### 2.3 Unauthenticated surfaces, enumerated

Derived from the exclusion list at `src/main.py:60–77` (prefix-matched by `auth_bearer.py:68–70`). Note `API_PREFIX = "/api"` (`src/config/settings/base.py:26`, no override in any environment class), confirmed by the Worker's `BACKEND_URL = "https://api.qravio.app/api"` (`qr_cf_code/wrangler.toml`) and the frontend's `NEXT_PUBLIC_API_URL=http://localhost:8000/api`.

| Surface | Guard today | Cost of one unthrottled request | Decision |
|---|---|---|---|
| `POST /api/razorpay/webhooks` (`razorpay_routes.py:790`) | HMAC signature | HMAC verify + DB lookup | Edge ceiling only; **never** app-limited (dropping a real webhook loses a payment) |
| `POST /api/mor/webhooks` (`mor_routes.py`) | MoR signature | same | same |
| `GET /api/health`, `/health/live`, `/health/ready` (`health.py`) | none | ~0 (static dict) | Edge ceiling only; **must never 429** (Render's own probes) |
| `POST /api/internal/*` (19 routes, `internal.py:31–35`) | `x-internal-secret` header | varies; `/internal/scans` writes 2 tables | **Explicitly out of scope for app limiting** — see §7 and §12 |
| `GET /api/public/plans` (`subscription.py:804`) | none | 1 DB query | Edge ceiling + app limit |
| `GET /api/public/v1/preview/{short_code}.svg` (`api_public.py:1099`) | none | 1 joined DB query + **server-side QR render** (`segno`) | Edge ceiling + app limit. Highest CPU-per-anonymous-request in the app. |
| `GET /api/public/v1/reports/{token}` (`reports.py:260`) | bearer token **in the URL** | 1 DB query | Edge ceiling + app limit — this one is enumerable |
| `/api/public/v1/*` (key-authed, `api_public.py:108`) | API key + monthly quota | full CRUD | Burst limit per key (the gap this spec closes) |
| `/docs`, `/redoc`, `/openapi.json` | none | schema render | Edge ceiling only |

### 2.4 Authenticated but unmetered spend

Being logged in is not a cost control. Two routes convert a single authenticated HTTP call into third-party spend with no per-user throttle whatsoever:

- **`POST /api/contact`** (`contact.py:34–41`) — `Depends(get_current_user_id)`, so it *is* authenticated (the brief listed it as public; it is not). But each call fires **two** Resend sends: `send_contact_support_email` and `send_contact_confirmation_email` (`contact.py:43`, `contact.py:56`). The confirmation goes to a **user-supplied** `payload.email` — one authenticated account can use us as an open relay to mail arbitrary addresses at whatever rate it likes. That is a Resend bill *and* a sender-reputation risk on a domain whose `_dmarc.qravio.app` record is still unpublished.
- **`POST /api/workspaces/{id}/vcard/ocr`** and the AI-analyst routes — monthly-capped, but the cap is a *month*, not a *minute*. A script can burn a workspace's entire Anthropic allowance in one burst and hand us the whole month's token bill in one second.

### 2.5 Why in-process counters are not an option

This is usually the tempting shortcut and it is definitively wrong here. `qr_backend/Dockerfile` runs `uvicorn … --workers 4`, and `BACKEND_SERVER_WORKERS=4` in both `.env` and `.env.example`. That is **four separate OS processes with four separate heaps on a single container** — a `dict`-based limiter would leak 4× its configured allowance before Render's horizontal scaling is even considered. Any correct limiter here is either at the edge or in a shared store.

## 3. Goals & Non-Goals

**Goals**
- **No unauthenticated path can be flooded.** A per-IP volumetric ceiling covers every route, applied where the client IP cannot be forged.
- **Close the auth hole where it actually lives** — Supabase Auth rate-limit configuration — and document it as an owned, verified control rather than an assumption.
- **Make attacks visible.** Mirror failed logins into `login_events` so credential stuffing produces evidence instead of silence.
- **One trustworthy client-IP function** used by every caller, with a stated authoritative header and an explicit refusal to trust spoofable ones.
- **Burst ceilings on the paid API and on money-spending endpoints**, semantically correct across all workers and instances.
- **Zero breakage for existing `/api/public/v1` consumers** — the meaning of `X-RateLimit-*` does not change.
- **A 429 that is never billed.** A throttled request must not consume the caller's monthly quota.

**Non-Goals**
- **No FastAPI limiter for authentication.** Those endpoints do not exist in this codebase. *(§2.1.)*
- **No Redis, no new managed service in v1.** *(§12 records what would change our mind.)*
- **No account lockout.** Lockout keyed on an email address is a denial-of-service primitive an unauthenticated stranger can point at any customer. *(§6.4.)*
- **No scan-path throttling.** Scan-flood, bot traffic, and analytics fraud are `SCAN_FRAUD_DETECTION`'s scope, at the Worker. We do not touch `recordScan`, `/internal/scans`, `qr_scan_events`, or `qr_scan_counters`. *(§12.)*
- **No new plan flag** *(recommended — §8)*, and therefore no `FEATURE_ENFORCEMENT` churn in the recommended path.
- **No CAPTCHA / bot-management product** in v1. *(Future; Cloudflare Turnstile on the public builder is a separate call.)*
- **Not a replacement for the monthly quota.** The two coexist and answer different questions.

## 4. Target Users & Personas

| Persona | Who | Job-to-be-done | Today's pain |
|---|---|---|---|
| **Platform owner ("Shaukat")** | Pays the Anthropic, Resend, Supabase, and Render bills | Sleep through the night without a surprise invoice | One script can spend a month of AI budget in a minute; nothing caps it |
| **Integrator ("Dev at an agency")** | Builds against `/api/public/v1` | Know the actual limits and back off correctly | Headers promise a rate limit that does not exist; the eventual 429 says "retry in 3 weeks" |
| **Customer whose account is targeted ("Amara")** | SMB owner, reused password | Not be locked out, and be told if someone is trying | Failed logins are never recorded; she cannot be warned, and a naive lockout would let the attacker lock *her* out |
| **On-call / support** | Triages "the API is slow" | Distinguish abuse from a bug in ten seconds | No per-identity request telemetry exists |
| **The attacker** | Scripted, unauthenticated | Enumerate report tokens, flood the preview renderer, relay email | Currently unbounded on all three |

Primary beneficiary is the **platform owner** (cost + availability). Secondary is the **integrator**, who gets honest, standards-shaped limit semantics.

## 5. User Stories

- As the **platform owner**, I want a hard per-IP ceiling on every unauthenticated path, so that no anonymous script can exhaust CPU or database connections.
- As the **platform owner**, I want Supabase Auth's own rate limits explicitly configured and recorded, so that credential stuffing is bounded even though that traffic never reaches my backend.
- As the **platform owner**, I want a per-minute burst ceiling on Anthropic- and Resend-spending endpoints, so that a month's budget cannot be spent in a second.
- As an **integrator**, I want standards-shaped `RateLimit-*` headers and a `Retry-After` in seconds, so that my client backs off correctly instead of guessing.
- As an **integrator**, I want a request rejected by the burst limiter **not** to count against my monthly quota, so that being throttled does not also cost me money.
- As a **targeted customer**, I want failed logins against my account recorded and visible in my security page, so that I learn I am under attack.
- As a **targeted customer**, I want repeated failures to slow an attacker down **without** locking me out of my own account, so that the defence is not itself the outage.
- As **on-call**, I want every throttle decision logged with the identity key and the rule that fired, so that I can tell abuse from a bug immediately.
- As the **Worker**, I want my `/internal/scans` posts never throttled, so that a busy poster's scan analytics are never silently lost.

## 6. UX / Product Flow

### 6.1 The anonymous flood (Layer 1 — edge)
A script hits `GET /api/public/v1/preview/abc123.svg` a thousand times a second. Cloudflare's rate-limiting rule on `api.qravio.app` counts by the true client IP — the TCP peer address Cloudflare terminates, which the caller cannot forge — and returns Cloudflare's own 429 **before the request ever reaches Render**. No Python executes, no database connection is taken, no bill accrues. The user-visible artefact is Cloudflare's block page; legitimate users never see it because the ceiling is set well above human behaviour.

### 6.2 The API integrator (Layer 2 — application)
A Pro key issues 400 requests in ten seconds. The burst limiter recognises the key, finds the per-minute allowance exceeded, and returns:

```
429 Too Many Requests
Retry-After: 37
RateLimit-Limit: 120
RateLimit-Remaining: 0
RateLimit-Reset: 37
RateLimit-Policy: 120;w=60
X-RateLimit-Limit: 3000        ← unchanged: monthly quota
X-RateLimit-Remaining: 2612    ← unchanged, and NOT decremented by this rejection
```

The distinction is the whole point: `Retry-After: 37` means *wait 37 seconds*; the monthly numbers are untouched because the burst check runs **before** `increment_api_usage`. A throttled call is free.

### 6.3 The expensive-endpoint burst
A user's script posts 60 business-card images in ten seconds. The first few are processed; the rest get `429` with `Retry-After` in seconds and a body distinguishing "you are going too fast" (`code: "rate_limited"`, retryable now) from the existing "you are out of monthly scans" (`code: "card_ocr_quota_exceeded"`, retryable next month). The frontend already renders a quota-exhausted state; the burst state reuses that component with different copy — "Slow down a moment" rather than "Upgrade".

### 6.4 Repeated authentication failure — and why there is no lockout
Supabase Auth applies its own configured limits; the attacker is slowed at GoTrue. On our side the change is **visibility, not enforcement**: failed attempts are mirrored into `login_events` with `status='failed'` and surface in the existing security page (`security.py:87`) as "3 failed sign-in attempts from an unrecognised location."

We deliberately do **not** ship account lockout. If N failures lock an account, then any stranger who knows a customer's email address can lock that customer out of their own product at will — the control becomes the outage. The correct shape, if we ever need per-account enforcement, is **progressive delay** (a growing artificial latency that costs the attacker throughput without ever closing the door) combined with per-IP limits that punish the *source*, never the *victim*. Recorded as a decision, not an omission.

### 6.5 What the user never sees
Health probes are never throttled. Payment webhooks are never app-throttled. The Worker's `/internal/*` calls are never app-throttled. Ordinary dashboard use — even enthusiastic use — stays far under every ceiling; the limits are sized against machine behaviour, not human.

## 7. Scope

**In scope (v1 — Phase 1, no migration)**
- Cloudflare WAF rate-limiting rules on `api.qravio.app`: a global per-IP ceiling, a tighter rule on the anonymous paths (`/api/public/plans`, `/api/public/v1/preview/*`, `/api/public/v1/reports/*`, `/docs`, `/openapi.json`), and explicit **exclusions** for `/api/health*`, `/api/internal/*`, and both webhook paths.
- **Prerequisite verification:** confirm `api.qravio.app` is proxied (orange-cloud) in the `qravio.app` zone. If it is not, Layer 1 cannot exist as described and the whole plan pivots — this is the single hardest gate in the spec (§11 R1).
- Supabase Auth rate limits configured and documented (sign-in, sign-up, OTP, password-reset email, token refresh), with the chosen values recorded in the repo so they are reviewable.
- `src/utilities/client_ip.py` — one authoritative client-IP resolver. `auth.py:30` and `request.py:105–113` migrate to it.
- Failed-login mirroring so `login_events` stops being success-only.
- Developer-docs correction: the existing `X-RateLimit-*` headers documented as a **monthly quota**; the new `RateLimit-*` namespace documented for burst.

**In scope (v1 — Phase 2, gated on Phase 1 telemetry)**
- `0046_rate_limiting.sql` (provisional slot — see §12): one counter table plus one atomic increment RPC, mirroring `increment_api_usage`.
- Application burst limiter applied to a **named list** of routes only: `/api/public/v1/*` (per API key), `POST /api/contact` (per user — the email-relay fix), `POST /workspaces/{id}/vcard/ocr` and the AI-analyst routes (per workspace), the anonymous public routes (per hashed IP), and QR bulk-create.
- 429 contract: `Retry-After` in seconds, `RateLimit-*` headers, structured body, and the ordering guarantee that a throttled request never increments the monthly counter.

**Out of scope / Future**
- Any throttle on the scan path — `qr_cf_code/src/utils/scan.js`, `/internal/scans`, `recordScan`. **`SCAN_FRAUD_DETECTION` owns this.** *(§12.)*
- Redis or any new managed dependency *(§12)*.
- CAPTCHA / Turnstile on the public builder *(future)*.
- Per-plan sellable burst tiers *(future, and see §8 for why we advise against)*.
- Account lockout *(deliberately rejected — §6.4)*.
- Rate limiting the Next.js frontend's own routes (Vercel's platform limits apply there; different owner, different spec).
- A customer-facing usage/limits dashboard *(future; the monthly meter already has one)*.

## 8. Pricing & Packaging

| Surface | Tier | Flag / Limit |
|---|---|---|
| Per-IP abuse ceilings (edge) | **All plans, identical** | none — not a plan concern |
| Supabase Auth limits | **All plans, identical** | none — Supabase config |
| Burst ceiling on `/api/public/v1` | **Pro, Agency** (the only tiers with API access) | **derived** from existing `api_calls_per_month` |
| Burst ceiling on AI/email endpoints | **All plans** | fixed constants in code |

**Recommendation: add no new plan flag.** Three reasons, in order of weight:

1. **Selling a safety limit is a bad incentive.** If burst headroom is a paid feature, the cheapest tier is by definition the least protected — and the cheapest tier is exactly where abusive signups live. The control has to be strongest where the trust is lowest, which is the opposite of a pricing ladder.
2. **Tier differentiation already exists.** `plans.features.api_calls_per_month` is seeded per tier and enforced at `api_public.py:186–206`. Derive the burst allowance from it — e.g. `burst_per_minute = clamp(api_calls_per_month / 250, 30, 600)`, so Pro (3,000/mo) gets 30/min and Agency (25,000/mo) gets 100/min — and the ladder is inherited for free, stays consistent when the quota is repriced, and needs no new key.
3. **A new flag costs a real ritual.** It must be seeded on every non-custom plan, classified in `FEATURE_ENFORCEMENT` (`subscription.py:524`), and referenced from a non-`subscription.py` source file, or `test_feature_gate_coverage` fails the build. That ceremony is correct for capabilities customers buy. It is overhead for a number that exists to stop a script.

**If product overrules this** (a plausible call — "burst headroom" is a legible Agency upsell), the flag is `api_burst_per_minute` (int), and the house convention is non-negotiable: the seed **must** write a full-object `'{...}'::jsonb` blob, not a path-only `jsonb_set`, because `test_feature_gate_coverage._seed_feature_keys()` (`tests/unit_tests/test_feature_gate_coverage.py:36–52`) discovers keys **only** by regex-scanning `r"'(\{[^']*\})'::jsonb"` — a path-only seed leaves the key undiscovered and the coverage test fails it as stale.

```sql
-- seed as a full-object blob where ABSENT (regex-discoverable), non-custom only
UPDATE plans
SET features = coalesce(features,'{}'::jsonb) || '{"api_burst_per_minute":30}'::jsonb
  WHERE NOT (coalesce(features,'{}'::jsonb) ? 'api_burst_per_minute')
    AND coalesce(is_custom,false) = false;
-- per-tier values via path writes (lower(name) + is_custom guard — house convention)
UPDATE plans SET features = jsonb_set(coalesce(features,'{}'::jsonb),'{api_burst_per_minute}','100'::jsonb,true)
  WHERE lower(name) = 'agency' AND coalesce(is_custom,false) = false;
```

Register `inert`→`enforced` in the **same PR** that builds the gate.

**No upsell messaging on a 429.** A throttled integrator is mid-incident; "upgrade for more" reads as extortion. The burst 429 says how long to wait. The *monthly quota* 429 — a genuinely commercial event — keeps its existing upgrade copy (`api_public.py:198–201`).

## 9. Success Metrics & KPIs

**Protection**
- **100% of unauthenticated paths** covered by an edge ceiling (audited against the `main.py:60–77` exclusion list, which is the authoritative inventory).
- **Zero successful floods**: no single IP exceeds its configured ceiling at origin post-launch (Cloudflare analytics).
- **Anonymous preview-render CPU** (`/api/public/v1/preview/*.svg`) bounded — p99 origin request rate for that path under the configured ceiling.
- **Supabase Auth limits verified live**, not merely configured: a scripted burst against the sign-in endpoint is rejected by GoTrue.

**Correctness / no collateral damage**
- **0 throttled `/internal/scans` requests** — the false-positive that silently destroys customer analytics. Tracked as a hard invariant, alerting on any nonzero value.
- **0 throttled health probes**; **0 dropped payment webhooks**.
- **False-positive rate < 0.01%** of authenticated dashboard requests in the first 30 days (measured as 429s on JWT routes from distinct real users).
- **0 breaking changes** for existing `/api/public/v1` consumers — `X-RateLimit-*` semantics byte-identical to today.
- **0 monthly-quota increments** on burst-rejected requests (ordering invariant; asserted in tests).

**Visibility**
- **Failed logins recorded**: `login_events` contains `status='failed'` rows within one week of launch (today: structurally zero).
- Every throttle decision logged with rule id, identity-key type, and outcome — on-call can attribute a 429 in one query.

**Cost**
- **No new monthly infra spend in Phase 1** (edge rules and Supabase settings are included in plans we already pay for).
- Phase 2 adds **≤ 1 DB round-trip** per limited request, and only on the named endpoint list — never on the scan path.

## 10. Rollout Plan

**Phase 0 — Verify the assumption (blocking, hours not days).**
Confirm `api.qravio.app` is proxied through Cloudflare. `wrangler.toml` shows the `qravio.app` zone exists and the Worker's `BACKEND_URL` points at `https://api.qravio.app/api`, but nothing in the repo proves the DNS record is orange-clouded rather than a direct `CNAME` to Render. **If it is grey-clouded, Layer 1 does not exist** and Phase 1 collapses to Supabase config + the code fixes, with the app limiter promoted from Phase 2 to Phase 1. Do not write a line of limiter code before answering this.

**Phase 1a — Configuration (no deploy).**
Cloudflare rate-limiting rules in *log/count* mode first, sized from a week of real traffic. Supabase Auth limits set in the dashboard and the chosen values committed to the repo as documentation. Watch counters for a week; only then flip rules to *block*.

**Phase 1b — Code-only fixes (one backend deploy, no migration).**
`client_ip.py`; migrate `auth.py:30` and `request.py:105–113`; failed-login mirroring; developer-docs header correction. All independently useful and independently revertable.
**Acceptance:** a spoofed `X-Forwarded-For` no longer changes the resolved IP anywhere; a failed sign-in produces a `login_events` row with `status='failed'`; the `/developers` docs describe `X-RateLimit-*` as a monthly quota; no existing test regresses.

**Phase 2 — Application burst limiter (gated).**
Ship only if Phase 1 counters show semantic limits are needed — i.e. abuse that a per-IP ceiling cannot catch (one authenticated identity behind many IPs, or an API key hammering from a datacentre range we cannot blanket-ban). Apply `0046_rate_limiting.sql`, deploy the limiter in **shadow mode** (evaluate, log, never reject) for a week, review the would-have-blocked set for false positives, then enforce endpoint-by-endpoint starting with `POST /api/contact` (smallest blast radius, clearest abuse case) and ending with `/api/public/v1` (largest external contract).
**Acceptance:** burst 429 carries `Retry-After` in seconds and does not decrement `X-RateLimit-Remaining`; `/internal/scans` is provably unreachable by the limiter; a header-spoofing bypass attempt fails; concurrent requests across 4 workers cannot exceed the ceiling.

**Deploy order:** Cloudflare rules → Supabase settings → backend (code fixes) → *[gate]* → migration → backend (limiter, shadow) → enforce. **No Worker change, so no `npm run deploy:prod` gate. No frontend change in Phase 1.** Phase 2 touches the frontend only if we choose to render a distinct burst-throttled state.

**Rollback:** each layer reverts independently — a Cloudflare rule is disabled in the dashboard in seconds; the app limiter is behind a kill switch that returns it to shadow mode without a deploy.

## 11. Risks, Edge Cases & Open Questions

**R1 — `api.qravio.app` may not be proxied through Cloudflare (highest risk, unverified).** The entire Layer 1 design assumes it is. Repo evidence is circumstantial: the zone exists and the Worker targets that host, but `wrangler.toml` deliberately leaves Worker routes commented out with a long warning about zone topology being unconfirmed. **Mitigation:** Phase 0 blocks on the answer. If grey-clouded, either orange-cloud it (preferred — also gets DDoS protection and TLS termination) or promote the app limiter to Phase 1 and accept that floods reach Render.

**R2 — Trusting a spoofable IP header makes the limiter a no-op (known, and we already have a scar).** `CF-Connecting-IP` is set by Cloudflare and is authoritative **only** when the request genuinely arrived via Cloudflare; on a direct-to-Render connection any client can set that header to a random value per request and defeat per-IP limiting entirely. `X-Forwarded-For` is worse — it is a client-appendable list. Today `auth.py:30` and `request.py:112` both read `x-forwarded-for` **first**, and the Worker uses `CF-Connecting-IP` (`scan.js:20,29`) — three call sites, two conventions, no shared helper. This project has already been burned by exactly this class of bug (the Cloudflare-behind-Vercel header mix-up that served USD pricing to every user in India). **Mitigation:** one resolver, an explicit trust flag, and the network path locked down so origin cannot be reached except through Cloudflare (TRD §8).

**R3 — A false positive on `/internal/scans` silently destroys customer analytics (highest-consequence failure).** `recordScan` fires inside `ctx.waitUntil` with `.catch(() => {})` (`qr_cf_code/src/utils/scan.js:75–84`): a 429 is swallowed, the visitor sees a perfect redirect, and the scan simply never existed. There is no retry, no dead-letter, no alarm. Worse, all Worker traffic arrives from Cloudflare egress addresses, so a per-IP limiter sees the entire planet's scans as one client. **Mitigation:** `/api/internal/*` is excluded from the app limiter by construction (not by configuration), the edge rule explicitly skips it, and a test asserts a legitimate burst passes.

**R4 — Blocking a payment webhook loses money.** Razorpay and the MoR provider retry, but not forever, and a dropped `subscription.charged` desynchronises billing state. **Mitigation:** both webhook paths are excluded from app limiting; edge ceilings for them are set far above provider burst behaviour, and the exclusion is asserted in tests.

**R5 — Header-namespace confusion.** Shipping `RateLimit-*` beside `X-RateLimit-*` risks integrators reading the wrong pair. **Mitigation:** `RateLimit-Policy` is emitted with an explicit window (`120;w=60`) so the burst headers are self-describing; the docs table shows both side by side. The alternative — renaming the old headers — is rejected because it breaks live consumers.

**R6 — Legitimate bursts look like abuse.** A customer's nightly sync legitimately issues hundreds of API calls. **Mitigation:** shadow mode before enforcement; ceilings derived from observed p99 rather than guessed; per-key overrides possible without a deploy.

**R7 — NAT / shared egress.** A whole office, university, or mobile carrier behind one IP shares an anonymous ceiling. **Mitigation:** anonymous ceilings sized generously; authenticated traffic keyed on identity (user / workspace / API key), never IP, so real customers are never punished for their neighbours.

**R8 — Storing IPs is a privacy question.** **Mitigation:** the app limiter never persists a raw IP. It keys on a salted hash, matching the existing `internal.py:1332` pattern (`sha256(ip + settings.HASHING_SALT)`), and rows are short-lived by construction. Note the pre-existing inconsistency worth cleaning up in passing: the Worker hashes **unsalted and truncates to 16 hex** (`scan.js:11–17`), while the backend hashes **salted, full-length** — two different `ip_hash` schemes in one system.

**R9 — Mirroring failed logins requires the frontend to report them.** Supabase rejects the credential in the browser; the backend never sees it. Getting a `status='failed'` row therefore means the client must tell us, and a client can lie (spam fake failures, or stay silent about real ones). **Mitigation:** treat these rows as *telemetry for the account owner*, never as an enforcement input. Enforcement stays with Supabase and the edge. §12 Q4 records the alternative.

**Open Questions**
1. Is `api.qravio.app` orange-clouded? *(Blocking — Phase 0.)*
2. Does the current Cloudflare plan include enough rate-limiting rules for the rule set in TRD §4? *(If not, collapse to one broad rule plus app-layer specificity.)*
3. Ship Phase 2 at all, or is the edge sufficient? *Recommend: decide on data after Phase 1, and be genuinely willing to answer "no" — the best version of this feature may be one with no migration and no new code paths.*
4. Should failed-login reporting be a dedicated endpoint, or should we poll Supabase's auth audit log instead? *Recommend the endpoint for v1 (simple, immediate), with the audit-log route noted as the trustworthy long-term source.*

## 12. Dependencies

- **Cloudflare (shipped, in use):** the `qravio.app` zone, already used for the Worker (`qr_cf_code/wrangler.toml`) and for Cloudflare-for-SaaS custom hostnames (`src/utilities/cloudflare_saas.py`). Backend credentials `CF_ACCOUNT_ID` / `CF_API_TOKEN` / `CF_ZONE_ID` already exist (`src/config/settings/base.py:68–76`). **Layer 1 depends entirely on `api.qravio.app` being proxied — see §11 R1.**
- **Supabase Auth (shipped):** owns every credential flow. Its rate-limit settings are the auth control. No code dependency; a configuration dependency we must own and record.
- **Atomic-counter pattern (shipped reference):** `increment_api_usage` RPC, called at `api_public.py:170–177`. Phase 2's limiter is the same shape — this is deliberate reuse, not new invention.
- **Existing throttle to supersede:** `internal.py:1330–1344` (lead submissions, 10/IP/hour via a `SELECT count`). Phase 2 should migrate it to the shared limiter so there is one implementation, not two.
- **`settings.HASHING_SALT`** (`base.py:131`) for IP hashing.
- **`SCAN_FRAUD_DETECTION` (concurrent spec, not yet on disk):** owns *all* scan-path abuse — bot filtering, self-scan suppression, scan flooding, and any Worker-side throttle. **The boundary: if the request arrives at `qr_cf_code`'s `fetch` handler for a short code, it is theirs; if it arrives at the FastAPI application, it is ours.** `/api/internal/scans` sits on their side of that line despite being a backend route, because it is Worker-originated scan traffic — we exclude it, they may throttle its source. No overlap, no duplicated counter.
- **`ORG_MFA_AUDIT_LOG` (drafted, `PRD_TRD/NOT_DONE/`):** consumes `login_events`. Failed-login mirroring here makes that spec's audit surface meaningfully complete; coordinate the schema addition so we do not both write it.
- **No AI. No email. No new QR type. No KV change. No Worker change. No cron.**

### Migration decision — **Phase 1 requires none; `0046` is reserved for Phase 2**

**Phase 1 ships no migration, and that is the recommendation, not a compromise.** The highest-severity gaps — anonymous floods and credential stuffing — are closed by Cloudflare rules and Supabase settings. Neither needs a table. The code-only fixes (client-IP resolver, failed-login mirroring, docs) touch no schema; `login_events` already has a `status` column (`security.py:100` selects it) that today only ever holds `'success'`.

**Phase 2 does need a table**, and pretending otherwise would be dishonest. A cross-process counter cannot live in Python memory (§2.5), and deriving counts from existing tables — the trick `internal.py:1338` uses against `qr_lead_submissions` — only works where a natural event table exists. There is none for `/api/contact`, none for the preview renderer, none for report-token reads. If Phase 2 ships, it ships **`0046_rate_limiting.sql`**: one counter table plus one atomic increment RPC, and nothing else.

**The slot is provisional and must be re-verified at build time.** Highest on disk is `0032_lemonsqueezy_variant_backfill.sql`; `0033`–`0043` are claimed by drafted-but-unapplied specs and `0044`/`0045` by specs being written concurrently with this one. None of those are applied, so the numbering is a coordination convention rather than a fact — re-check `qr_backend/migrations/` before writing the file. This repo has already shipped a commit fixing exactly this class of stale-slot error (`0026` was drafted as `0024`).

### Appendix — Key Files

| Concern | File |
|---|---|
| Public-route inventory (authoritative) | `qr_backend/src/main.py:60–77` (`excluded_routes`), matched by `src/api/middlewares/auth_bearer.py:68–70` |
| Monthly-quota headers to preserve | `qr_backend/src/api/routes/api_public.py:185–206`; `ai_analyst.py:433–446`; `vcard_ocr.py:113–126` |
| Atomic-counter pattern to reuse | `qr_backend/src/api/routes/api_public.py:170–177` (`increment_api_usage`) |
| The only existing throttle | `qr_backend/src/api/routes/internal.py:1330–1344` (lead submissions, 10/IP/hour) |
| Client-IP handling to fix | `qr_backend/src/api/routes/auth.py:30`; `src/api/middlewares/request.py:105–113`; cf. `qr_cf_code/src/utils/scan.js:20,29` |
| Login telemetry (success-only today) | `qr_backend/src/api/routes/auth.py:28–43,101`; read at `src/api/routes/security.py:98–105` |
| Auth flows (all Supabase, browser-side) | `qr_frontend/src/app/(auth)/login/LoginClient.tsx:63`, `signup/SignupClient.tsx:78`, `forgot-password/ForgotPasswordClient.tsx:45` |
| Unmetered email spend | `qr_backend/src/api/routes/contact.py:34–61`; `src/utilities/email.py` |
| Anonymous CPU cost | `qr_backend/src/api/routes/api_public.py:1099` (preview SVG render) |
| Anonymous token surface | `qr_backend/src/api/routes/reports.py:260` (`/api/public/v1/reports/{token}`) |
| Multi-process deployment proof | `qr_backend/Dockerfile` (`--workers 4`); `.env.example` (`BACKEND_SERVER_WORKERS=4`) |
| Cloudflare zone / hostnames | `qr_cf_code/wrangler.toml`; `qr_backend/src/utilities/cloudflare_saas.py`; `src/config/settings/base.py:68–76` |
| Plan-flag ritual (if §8 is overruled) | `qr_backend/src/api/routes/subscription.py:524` (`FEATURE_ENFORCEMENT`); `tests/unit_tests/test_feature_gate_coverage.py:36–52` |
| Scan path (out of scope — `SCAN_FRAUD_DETECTION`) | `qr_cf_code/src/utils/scan.js`; `qr_backend/src/api/routes/internal.py:350` (`record_scan_event`) |
