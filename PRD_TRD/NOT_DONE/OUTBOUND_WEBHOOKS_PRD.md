# PRD — Outbound Webhooks + Zapier/Make Integration

**Status:** Draft · **Author:** Product · **Date:** 2026-06-24
**Priority:** Automation/integration wave — the "make Qravio a node in the customer's stack" play, sitting directly on top of the shipped public API.
**Tiers:** **Pro** (basic — up to 3 endpoints, scan + lead events) · **Agency** (high volume — up to 20 endpoints, all event types, higher delivery rate, Zapier/Make app). Free/Starter: none.
**Plan flags:** `outbound_webhooks` (bool, NEW) · `webhook_endpoints_max` (int, NEW — Pro `3`, Agency `20`). Seeded `false`/`0` everywhere by the house preflight pattern; this feature's migration (`0020`) flips Pro/Agency on.
**Split from:** `API_ACCESS_PRD.md`, which explicitly **deferred webhooks-out** ("Non-Goals: GraphQL, webhooks-out, or OAuth app authorization (future)"). This PRD is that deferred half.

**Rev (2026-06-24, post eng-review):** R7 strengthened — the delivery log persists lead PII at rest (for redeliver), so it now mandates a retention TTL (prune past `analytics_retention_days`/30-day cap), value-level log redaction, and a ToS/DPA onward-transfer note. Dependencies note corrected the most important architecture bug: webhook signing secrets must be stored **encrypted (Fernet)**, not SHA256-hashed like `api_tokens`, because we must sign with the plaintext on every delivery. Scope otherwise accepted as-is (Phase split, sweeper-not-queue, milestone deferral, workspace-wide endpoints all sound). See the TRD Rev note for the implementation-level changes.

---

## 1. TL;DR / Summary

Today Qravio is a destination: data flows *in* (scans, leads) and a marketer must *come to us* to see it. The public API (shipped, `api_public.py` on `/api/public/v1`) lets them pull — but pulling means polling, and nobody polls. **Outbound webhooks invert the flow:** when a scan, a scan-milestone, or a lead submission happens, Qravio fires a signed `POST` to a URL the customer controls — their CRM, their Slack, their data warehouse, or a Zapier/Make "catch hook." That single primitive turns Qravio into an automation node: "QR scanned → add row to Google Sheet," "lead submitted → create HubSpot contact," "QR hit 1,000 scans → Slack the team."

The mechanics reuse seams we already own. Delivery is dispatched **off the hot path** — `ctx.waitUntil` already fires scan ingestion to `internal.py POST /scans`, and that handler already runs after the redirect is served; we hang a **FastAPI `BackgroundTasks`** dispatcher off the same ingestion point and off `/internal/lead-submit`. Each delivery is **HMAC-SHA256 signed** with a per-endpoint secret — the exact `hmac.compare_digest` pattern in `razorpay_routes.py`, inverted to *sign* instead of *verify*. Management (create/list/rotate/delete endpoints, view delivery log) reuses the `api_tokens` workspace-scoped auth model and the org-app settings surface. Zapier/Make are **templates on top of the public API + these webhooks** — not new backend surface.

Phase 1 ships the dispatcher, two event types (`scan`, `lead.submitted`), a delivery log with retry/backoff + dead-letter, and a Settings UI. Phase 2 adds the `scan.milestone` event and the published Zapier/Make apps.

## 2. Problem & Motivation

**Polling is a non-feature.** The public API can list QRs and read analytics, but every real automation use case ("when X happens, do Y") needs a *push*. The API_ACCESS PRD itself flagged this: webhooks-out were cut from v1 to keep the surface small, with a written note that they're the next layer. Customers who bought "API access" on the pricing page increasingly ask "can it trigger my Zap?" — and the honest answer is no. That is the gap this closes.

**The dispatch seam already exists and is free.** Every scan already produces a backend write at `internal.py POST /scans` (line 313, `record_scan_event`), invoked via `ctx.waitUntil` from the Worker *after* the user's redirect/landing page is served — so it never blocks the scan. Lead submissions land at `/internal/lead-submit` the same way. Both are the natural, already-asynchronous fan-out points. We do **not** add work to the Worker scan hot path; the Worker keeps doing exactly what it does (fire-and-forget POST to the backend), and the backend does the outbound fan-out from a `BackgroundTasks` job. This is the same architectural discipline the codebase already enforces: heavy work runs backend-side, never at the edge.

**The signing primitive is already in the repo.** `razorpay_routes.py` verifies inbound HMAC-SHA256 with `hmac.new(...).hexdigest()` + `hmac.compare_digest` (lines 203–223). Outbound signing is the mirror image: compute `HMAC-SHA256(endpoint_secret, raw_body)`, send it as an `X-Qravio-Signature` header, and document how the receiver verifies it. The same `INTERNAL_SECRET` / password-gate-token mental model (shared secret, constant-time compare) applies — we just generate one secret per endpoint.

**The management + auth model is already built.** The shipped `api_tokens` table and the `/security/api-tokens` issuance flow (reused by `api_public.py`) are the template for webhook-endpoint CRUD: workspace-scoped, owner/editor-gated, secret-shown-once. We are adding two tables and a dispatcher — not a new auth system.

**This is a retention and expansion lever.** A workspace that has wired Qravio into its CRM via a webhook has a switching cost that scan analytics alone never create. Zapier/Make listing also becomes a top-of-funnel acquisition channel (Qravio appears in their app directories). The cost-to-moat ratio is excellent because the hard parts (async dispatch point, HMAC, key model) are already in the tree.

## 3. Goals & Non-Goals

**Goals**
- A **webhook dispatcher** invoked from the existing async ingestion points (`internal.py POST /scans` and `/internal/lead-submit`) via `BackgroundTasks`, so delivery **never blocks** scan recording or lead acceptance.
- Two v1 event types: **`scan`** (every recorded scan) and **`lead.submitted`** (every lead-form submission), with a Phase-2 **`scan.milestone`** (QR crosses a configurable threshold: 100/1k/10k scans).
- **Per-endpoint HMAC-SHA256 signing** (`X-Qravio-Signature: sha256=<hex>` + `X-Qravio-Timestamp`), mirroring `razorpay_routes.py`'s verification, so receivers can authenticate payloads.
- **Reliable delivery:** retry with exponential backoff (e.g. 4 attempts over ~1h), a persisted **delivery log** (`webhook_deliveries`), and **dead-letter** state after exhaustion — all queryable in the UI.
- **SSRF-hard outbound:** validate the target URL at write time (https-only, public DNS only, block RFC1918 / loopback / link-local / metadata IPs), re-resolve at delivery time.
- **Management UI** (Settings → Integrations / Webhooks): create endpoint (URL, events, secret shown once), test-ping, view recent deliveries + redeliver, rotate secret, delete. Reuses `api_tokens` auth model.
- **Zapier + Make templates/apps** built **on the public API + these webhooks** — zero new bespoke backend.
- Gate everything behind `outbound_webhooks` (BE `check_feature` + FE `canAccessFeature`); flip the registry `inert→enforced` in the same PR; keep `test_feature_gate_coverage` green.

**Non-Goals**
- OAuth-app authorization / a public "Qravio Connect" app platform *(future)*.
- Customer-defined custom event types or a rules/filter builder beyond per-event-type subscription *(future)*.
- Webhook **fan-in** (inbound webhooks that mutate Qravio state) — that's the API's job *(out)*.
- Guaranteed exactly-once delivery — we ship **at-least-once** with an idempotency key the receiver dedupes on.
- Real-time streaming / SSE / WebSocket push *(future)*.
- Putting *any* outbound HTTP on the Worker scan hot path — dispatch is strictly backend-side.

## 4. Target Users & Personas

| Persona | Who | Job-to-be-done | Today's pain |
|---|---|---|---|
| **Growth/Ops Engineer ("Sam")** | Owns the marketing stack at a D2C brand | Pipe lead submissions into HubSpot/Sheets automatically | Exports CSV nightly by hand; leads go stale |
| **Agency Automation Lead ("Marcus")** | Runs 30 client campaigns, lives in Zapier/Make | "When this campaign's QR is scanned, notify the client's Slack" | No trigger exists; builds nothing in Qravio |
| **Event Organizer ("Dev")** | Ticketed events with lead-capture QRs | Real-time alert when registrations cross a milestone | Refreshes the dashboard manually |
| **Developer ("Priya")** | Building an internal dashboard on the public API | Get pushed events instead of polling `/analytics` | Polls; burns API quota; latency |

Primary buyer: the **agency / ops-engineer** segment already on Pro/Agency — the cohort with the highest willingness to pay and, once they've wired a webhook into production, the lowest churn.

## 5. User Stories

- As an **ops engineer**, I want a signed POST to my endpoint every time a lead is submitted, so that I can create a CRM contact without polling.
- As an **agency lead**, I want to connect Qravio to Zapier with a "New Scan" / "New Lead" trigger, so that I can build client automations without touching code.
- As an **event organizer**, I want a `scan.milestone` webhook at 1,000 scans, so that my team gets a Slack alert the moment we hit the goal.
- As a **developer**, I want to verify the `X-Qravio-Signature` header, so that I can trust the payload came from Qravio and not a spoofer.
- As a **workspace owner**, I want to see a delivery log with status codes and retry counts and a "redeliver" button, so that I can debug a broken endpoint.
- As a **security-conscious admin**, I want to rotate an endpoint's secret without recreating it, so that a leaked secret is quickly invalidated.
- As a **Free/Starter user**, I want to see the Webhooks settings card behind an upgrade gate, so that I understand what Pro unlocks.

## 6. UX / Product Flow

**6.1 Settings → Integrations / Webhooks (`/org/[slug]/(dash)/settings`)**
A new **Webhooks** section renders conditionally exactly like the shipped **Branding** (`white_labeling`) and **Pixels** (`retargeting_pixels`) settings sections — `canAccessFeature(subscription, 'outbound_webhooks')`; non-entitled tiers see an `UpgradeGate` card ("Push scans & leads to your stack. Upgrade to Pro.").

1. **Endpoint list** — a table (shadcn, follows the live blue-600/gray org-app pattern, not the indigo spec) of existing endpoints: URL (truncated), subscribed events (badges), status (active / paused / failing), last delivery result, created date. Empty state mirrors the org `EmptyState` primitive.
2. **Add endpoint** — a `react-hook-form + zod` form: **URL** (zod `.url()` + https refinement), **event checkboxes** (`scan`, `lead.submitted`, Phase 2 `scan.milestone` with a threshold input), optional **description**. On save, the **signing secret is shown once** in a copy-once card (same UX as the shipped API-key creation); thereafter only a prefix is shown.
3. **Per-endpoint actions** — **Send test ping** (fires a synthetic `ping` event so the user can confirm receipt before going live), **Rotate secret** (shows new secret once), **Pause/Resume**, **Delete**.
4. **Delivery log drawer** — opening an endpoint shows its recent `webhook_deliveries`: event type, HTTP status, attempt count, latency, timestamp, and a **Redeliver** button for failed/dead-lettered rows. This is the audit + debug surface KNOWN-RISKS calls for.

**6.2 QR detail (`QRDetails.tsx`)** — informational only in v1: a small "Webhooks: 2 endpoints will receive scans of this QR" note on the overview tab when the workspace has active scan-subscribed endpoints (no per-QR endpoint config in v1 — endpoints are workspace-wide, mirroring how `pixels` are workspace-wide).

**6.3 Developers / Docs page (`/docs` + in-app `/developers`)** — extend the existing public API reference (data-driven from `src/lib/constants/api-docs*.ts`) with a **Webhooks** section: event catalog, the exact JSON payload shapes, the signature-verification recipe (language-agnostic + a Python/Node snippet), retry/backoff schedule, and idempotency guidance. Add Zapier/Make "Connect" cards linking to the published apps (Phase 2).

**6.4 Zapier/Make** — the Qravio Zapier app exposes **triggers** (New Scan, New Lead, polling fallback via `GET /api/public/v1/...`) backed by these webhooks for instant triggers, and **actions** (Create QR, etc.) backed by the existing public API. Make gets an equivalent custom app/scenario template. These live in Zapier/Make's own infra; Qravio only provides the webhook + API surface.

## 7. Scope

**In scope (v1 / Phase 1)**
- `webhook_endpoints` + `webhook_deliveries` tables (migration `0020`) + the two new plan flags.
- Backend dispatcher fired from `internal.py POST /scans` and `/internal/lead-submit` via `BackgroundTasks`; never blocks ingestion.
- Event types `scan`, `lead.submitted`, plus a synthetic `ping`.
- HMAC-SHA256 signing (`X-Qravio-Signature` + `X-Qravio-Timestamp` + `X-Qravio-Idempotency-Key`).
- Retry/backoff (4 attempts, exponential), delivery-log persistence, dead-letter state, redeliver.
- SSRF allow-listing (https-only, public-IP-only, re-resolve at send).
- Endpoint-management CRUD (reusing `api_tokens`-style workspace auth + `require_can_*` permissions) + Settings UI + delivery-log drawer.
- `outbound_webhooks` gate (BE + FE), registry flipped `inert→enforced` same PR.

**Out of scope / Future**
- `scan.milestone` event (**Phase 2**) — needs a per-QR threshold check against `qr_scan_events` (accurate count, see §11) at ingestion time.
- Published Zapier + Make apps (**Phase 2** — depend on a stable v1 payload contract).
- OAuth apps / Connect platform; customer-defined events; rules/filter builder.
- Per-QR endpoint scoping (v1 endpoints are workspace-wide).
- Inbound/fan-in webhooks; exactly-once delivery; streaming.

## 8. Pricing & Packaging

| Surface | Tier | Flag / limit |
|---|---|---|
| Webhooks: up to **3** endpoints, `scan` + `lead.submitted`, standard delivery rate | **Pro** | `outbound_webhooks=true`, `webhook_endpoints_max=3` |
| Webhooks: up to **20** endpoints, **all** events incl. `scan.milestone`, higher delivery rate, **Zapier/Make app** | **Agency** | `outbound_webhooks=true`, `webhook_endpoints_max=20` |
| Free / Starter | — | `outbound_webhooks=false`, `webhook_endpoints_max=0` |

- **New flag `outbound_webhooks` (bool):** registered in `FEATURE_ENFORCEMENT` (`subscription.py`) as `inert`, flipped `enforced` in the same PR that flips the migration on; `check_feature(ws, 'outbound_webhooks', db)` (async — `await`) guards all CRUD + dispatch-eligibility. `canAccessFeature(subscription, 'outbound_webhooks')` gates the FE section. Add to the `PlanFeatures` interface in `useSubscription.ts`.
- **New limit `webhook_endpoints_max` (int):** enforced at endpoint-create via `get_limit(ws, db, 'webhook_endpoints_max')` (`-1` = unlimited); the create endpoint counts active rows and returns `403`/`409` over cap, mirroring the `max_qr` pattern.
- **Migration flag-flip uses the house convention exactly** (§13) — seed `false`/`0` on every non-custom plan missing the key, then `true`/`3`/`20` for `lower(name) IN (...)` excluding custom plans. **Never** a bare `WHERE name IN ('Pro',...)`.
- **Upsell angle:** Pro→Agency teaser on the Webhooks card — "Need scan-milestone alerts, 20 endpoints, and the Zapier app? Upgrade to Agency." Free/Starter see the gate as a new reason to move to Pro.

## 9. Success Metrics & KPIs

**Activation (first 60 days post-GA)**
- ≥ 30% of Pro/Agency workspaces create ≥1 webhook endpoint.
- ≥ 70% of created endpoints successfully receive the **test ping** within 5 min (proxy for "correctly configured").

**Reliability (the trust bar for an automation feature)**
- **≥ 99.0%** of deliveries succeed within the retry window (2xx received before dead-letter).
- Dispatch adds **0 ms p95** to scan-recording latency (`BackgroundTasks` off the response path — verified by p95 of `POST /scans` unchanged vs baseline).
- **0** SSRF incidents (no delivery ever resolves to a private/internal IP — enforced + tested).

**Adoption / expansion**
- ≥ 15 workspaces install the **Zapier/Make** app within 60 days of Phase-2 GA.
- Pro→Agency upgrade rate **+10%** among workspaces that hit the 3-endpoint cap or view the `scan.milestone` teaser.
- Pro-tier **logo churn −8%** among workspaces with ≥1 endpoint receiving production traffic for ≥30 days (switching-cost hypothesis).

**Quality**
- Delivery-log counts reconcile within **±1%** of dispatched events (no phantom or dropped log rows).
- < 2% of endpoints in `failing`/dead-letter state at any time (mostly customer-side misconfig, surfaced clearly).

## 10. Risks, Edge Cases & Open Questions

**R1 — SSRF / outbound abuse (top risk).** A customer-supplied URL is an SSRF vector: pointing an endpoint at `http://169.254.169.254/` (cloud metadata) or `http://10.x` could exfiltrate internal data. **Mitigation:** at **write time** require `https://`, reject hosts that resolve to RFC1918 / loopback / link-local / metadata ranges; at **delivery time** re-resolve DNS and re-check (defends against DNS-rebinding TOCTOU), disable redirects (or re-validate each hop), cap response read + timeout (e.g. 5s, 10KB). This is the central security test suite.

**R2 — Dispatch must never block ingestion.** `POST /scans` runs in `ctx.waitUntil` but the *backend* handler still returns to the Worker. Webhook fan-out runs in `BackgroundTasks` (fire-after-response) so a slow/down customer endpoint never delays scan recording or the Worker's `waitUntil`. **Open Q:** at high scan volume, `BackgroundTasks` runs in-process — do we need a durable queue (e.g. a `webhook_deliveries` row written `pending` + a worker/cron drainer) so deliveries survive a backend restart? **Recommend:** persist the delivery row *first* (status `pending`), attempt inline via `BackgroundTasks`, and have a **sweeper** (cron) pick up stuck `pending`/`retrying` rows — durability without a new queue service. (If the sweeper is a Worker cron, it registers **only after `npm run deploy:prod`** — a GA gate.)

**R3 — Retry storms / amplification.** A scan spike × many endpoints × retries could amplify outbound load. **Mitigation:** per-endpoint concurrency cap + delivery-rate limit (tier-differentiated), and **auto-pause** an endpoint after N consecutive dead-letters (notify the owner). Backoff schedule fixed (e.g. 0s, 1m, 10m, 1h).

**R4 — Scan-volume firehose.** A high-traffic QR could fire thousands of `scan` webhooks/min. **Mitigation:** document that `scan` is high-volume; recommend `scan.milestone`/`lead.submitted` for most automations; consider an optional per-endpoint sampling/batch in a later phase. Agency's higher rate cap is a packaging lever here.

**R5 — Milestone accuracy (Phase 2).** `scan.milestone` must fire exactly once per threshold. `qr_scan_counters` is a **non-atomic read-modify-write** (documented increment-loss). **Decision:** compute the milestone check against **`qr_scan_events` row counts** (accurate denominator), not the lossy counter, and persist a `milestone_fired_at` marker per QR/threshold to guarantee once-only.

**R6 — Replay / spoofing of our deliveries.** Receivers must be able to reject replays. **Mitigation:** sign `timestamp + body`, include `X-Qravio-Timestamp`, and document a freshness window (e.g. reject > 5 min) + idempotency-key dedupe. We provide the verification recipe in docs.

**R7 — PII in payloads + at rest in the delivery log.** `lead.submitted` carries PII; `scan` carries IP-derived geo (we store `ip_hash`, not raw IP — keep it that way). **Mitigation:** payloads send `ip_hash`/geo, **never** raw IP; lead payloads carry only fields the form collected; all transport is https-only (enforced by R1). Honor the existing EU consent posture — do not add new PII to the scan payload. **Lead PII is also persisted in `webhook_deliveries.payload` (for the redeliver feature) — give the delivery log a retention TTL** (prune rows older than the workspace's `analytics_retention_days`, fixed-30-day cap, whichever is shorter) so PII does not accumulate indefinitely, and **never log lead field *values*** (log names/counts only). Enabling a `lead.submitted` webhook is a customer-directed onward transfer — note it in the ToS/DPA.

**Open Questions**
1. Durable queue vs `BackgroundTasks`+`pending`-row sweeper? *Recommend the sweeper (no new infra).*
2. Auto-pause threshold (consecutive dead-letters) — 10? 20? *Recommend 15 + owner email.*
3. Does the delivery-log drawer count from `webhook_deliveries` rows (accurate) — yes; never from a denormalized counter.
4. Do we email the owner on auto-pause? If yes, **DMARC is a prerequisite** (see §12).

## 11. Rollout Plan

**Phase 0 — Schema + dispatcher (internal, no UI).**
Apply migration `0020` (tables + both flags, house flag-flip). Build the dispatcher + SSRF validator + signing + retry/backoff + delivery-log writes, wired into `POST /scans` and `/internal/lead-submit` via `BackgroundTasks`. Behind `outbound_webhooks` (registered `inert`). Validate end-to-end against a controlled receiver (e.g. a request-bin) on a seed workspace; confirm `POST /scans` p95 is unchanged.

**Phase 1 — Webhooks UI + GA (Pro+).**
Settings → Webhooks section (CRUD, test-ping, rotate, delivery-log drawer, redeliver), `outbound_webhooks` flipped `enforced` (coverage test stays green), `webhook_endpoints_max` enforced at create. Ship behind a FE constant flag for a 1-week internal + 3–5 design-partner beta, then flip GA.
- **Acceptance:** a Pro workspace creates an endpoint, gets the secret once, sends a test ping that arrives signed; a real scan + a real lead each deliver a signed POST logged in the drawer; a down endpoint retries then dead-letters and can be redelivered; an endpoint URL resolving to `10.x`/metadata is **rejected at write**; a 4th endpoint on Pro is blocked by `webhook_endpoints_max=3`; Free workspace sees the upgrade gate and `POST` to CRUD returns 403.

**Phase 2 — `scan.milestone` + Zapier/Make apps (Agency lead).**
Add the `scan.milestone` event (event-count from `qr_scan_events`, once-only marker), build + submit the Zapier and Make apps on the v1 payload contract, add the Webhooks docs section + Connect cards. If auto-pause/owner emails ship, **publish `_dmarc.qravio.app` first** (currently unpublished — a hard email-deliverability gate). If the durable sweeper is a **Worker cron**, it registers **only after `npm run deploy:prod`** — gate GA of the sweeper on the prod worker deploy.
- **Acceptance:** a QR crossing 1,000 scans fires exactly one `scan.milestone`; the Zapier "New Lead" trigger fires within seconds of a submission; payload contract is versioned and documented.

**Phase 3 — Future:** per-QR scoping, sampling/batching, customer-defined events, OAuth/Connect platform.

## 12. Dependencies + Appendix

**Dependencies**
- **Public API (shipped):** `api_public.py` / `api_tokens` — the auth model template + the surface Zapier/Make actions call. Migration `0010` applied.
- **Scan pipeline (shipped):** `internal.py POST /scans` (`record_scan_event`, line 313) + `qr_scan_events` (accurate counts) + `qr_scan_counters` — the `scan`/`scan.milestone` dispatch source. Worker `src/utils/scan.js` (`ctx.waitUntil` → `/internal/scans`).
- **Lead Capture (shipped):** `/internal/lead-submit` + `qr_lead_submissions` — the `lead.submitted` dispatch source. Migration `0012` applied.
- **HMAC pattern (shipped):** `razorpay_routes.py` (`hmac.new` + `compare_digest`) — invert to sign outbound. **NOTE:** unlike `api_tokens` (which only ever *verify* a presented token, so a one-way hash is fine), webhook signing secrets must be **recoverable to sign every delivery** — store them **encrypted at rest** (Fernet, new `WEBHOOK_SECRET_ENC_KEY` env), **not** as a SHA256 hash. (TRD §3.1.)
- **Gating engine (shipped):** `FEATURE_ENFORCEMENT` (`subscription.py`), `check_feature`/`get_limit`/`resolve_plan`, `canAccessFeature` (`plan-features.ts`), `useSubscription.ts` `PlanFeatures`.
- **Email (conditional):** Resend (`src/utilities/email.py`) for auto-pause notices — **blocked on `_dmarc.qravio.app` publication.**
- **Worker cron (conditional):** if the delivery sweeper runs as a Worker cron, `wrangler.toml` (dev + prod) + `npm run deploy:prod` to register it.
- **Migration `0020`** (reserved slot; 0014–0018 are the analytics roadmap, 0013 is highest applied): adds `webhook_endpoints` + `webhook_deliveries`, an index on `webhook_deliveries(endpoint_id, created_at)` and `webhook_endpoints(workspace_id)`, and seeds `outbound_webhooks` + `webhook_endpoints_max`. BEGIN/COMMIT-wrapped, idempotent (`IF NOT EXISTS`). **Ships only this phase's schema** — no Phase-2-only columns. Flag-flip uses the house convention:

```sql
-- seed false/0 on all non-custom plans lacking the keys
UPDATE plans SET features = jsonb_set(coalesce(features,'{}'::jsonb), '{outbound_webhooks}', 'false'::jsonb, true)
  WHERE NOT (coalesce(features,'{}'::jsonb) ? 'outbound_webhooks') AND coalesce(is_custom,false)=false;
UPDATE plans SET features = jsonb_set(coalesce(features,'{}'::jsonb), '{webhook_endpoints_max}', '0'::jsonb, true)
  WHERE NOT (coalesce(features,'{}'::jsonb) ? 'webhook_endpoints_max') AND coalesce(is_custom,false)=false;
-- flip Pro
UPDATE plans SET features = jsonb_set(features, '{outbound_webhooks}', 'true'::jsonb, true)
  WHERE lower(name) IN ('pro','agency') AND coalesce(is_custom,false)=false;
UPDATE plans SET features = jsonb_set(features, '{webhook_endpoints_max}', '3'::jsonb, true)
  WHERE lower(name) = 'pro' AND coalesce(is_custom,false)=false;
UPDATE plans SET features = jsonb_set(features, '{webhook_endpoints_max}', '20'::jsonb, true)
  WHERE lower(name) = 'agency' AND coalesce(is_custom,false)=false;
```

**Appendix — Key Files**

| Concern | File |
|---|---|
| Dispatcher + signing + retry/SSRF | new `qr_backend/src/utilities/webhook_dispatch.py`; new `qr_backend/src/api/routes/webhooks.py` (CRUD) |
| Dispatch trigger points | `qr_backend/src/api/routes/internal.py` (`POST /scans` ~line 313, `/internal/lead-submit`) — add `BackgroundTasks` fan-out |
| HMAC pattern to mirror | `qr_backend/src/api/routes/razorpay_routes.py` (`hmac.new`/`compare_digest`, ~lines 203–223) |
| Auth model template | `qr_backend/src/api/routes/api_public.py` + `api_tokens` table; `src/api/dependencies/permissions.py` (`require_can_*`) |
| Gating | `qr_backend/src/api/routes/subscription.py` (`FEATURE_ENFORCEMENT`, `check_feature`, `get_limit`); `qr_frontend/src/lib/plan-features.ts`; `src/hooks/useSubscription.ts` |
| Router registration + middleware | `qr_backend/src/api/endpoints.py`; `qr_backend/src/main.py` (CRUD under JWT, NOT excluded) |
| Settings UI | `qr_frontend/src/app/org/[slug]/(dash)/settings/`; new `src/components/org/settings/WebhooksSection.tsx` (mirror `BrandingSection`/`PixelsSection`); new `useWebhooks` hook in `src/hooks/` |
| Docs / Zapier-Make | `qr_frontend/src/lib/constants/api-docs*.ts`, `src/components/docs/`; `/developers` page |
| Migration | `qr_backend/migrations/0020_outbound_webhooks.sql` |
