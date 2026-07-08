# TRD — Edge AI Personalized Routing

**Status:** Draft · **Author:** Engineering (Staff) · **Date:** 2026-06-24
**Implements PRD:** Edge AI Personalized Routing · **Tiers:** Pro (`routing_rules`) · Agency (`ai_variants`)
**Plan flags:** `routing_rules` (bool), `ai_variants` (bool) · **Migration:** `0015_routing_rules.sql` (slot 0015 in the 0014–0018 roadmap sequence; current DB highest is 0013)
**Services touched:** `qr_backend` (FastAPI), `qr_cf_code` (Cloudflare Worker), `qr_frontend` (Next.js)
**Rev (2026-06-24, post eng-review):** v1 = the deterministic routing engine only; **AI variant generation (`ai_variants`, `qr_routing_variants`, `ai_variant_generations`, the generation UI + Anthropic dep) is deferred to a Phase-2 PR/migration**. The downgrade → `resync_workspace_qrs` hook moves into **Phase 1** (the write-time KV entitlement snapshot otherwise leaves the Worker guard ineffective — P1). Migration `0015` flag-flip fixed to the `lower(name)` + `is_custom` convention (bare `name IN (...)` risked a dead-on-arrival flag). Added: an `Intl.DateTimeFormat`-in-Workers verification spike + UTC-offset fallback, a `time`-condition-only construction guard, an explicit `qr_route_`/`qr_ab_` two-cookie precedence rule, and a Storage-URL-signing network-call check.

---

## 1. Overview & Architecture

Edge AI Personalized Routing turns the geo/device/time/language signal the Worker already reads in `recordScan` into a **routing decision made before paint**, plus (Agency) Claude-pre-generated localized landing copy snapshotted into KV. Two new entitlement flags gate the work: `routing_rules` (Pro+) gates the rule engine and builder UI; `ai_variants` (Agency) gates Claude generation.

**Services that change:**

- **qr_backend** — extends the existing `QRDestinationCreate` model (the `rules: Optional[dict]` field already exists on the Pydantic model but is never persisted to a real column), validates a structured rule schema at write, gates writes via `check_feature`, emits a new top-level `routing` block + (Agency) `content.variants` through `build_kv_content`/`sync_qr_to_kv`, and adds a new write-time AI generation utility + internal-style authenticated endpoint. Wires both new flags into `FEATURE_ENFORCEMENT` and `build_entitlements`.
- **qr_cf_code** — new pure-CPU `src/utils/routing.js` engine evaluated in `src/index.js` for `website` (destination variants, via `handleWebsiteRedirect`) and in `src/handlers/qrRouter.js` for HTML types (content variants). Adds a sticky `qr_route_<sc>` cookie mirroring the proven `qr_ab_<sc>` pattern. **Zero new network calls on the scan path.**
- **qr_frontend** — a Routing tab/card on the QR detail page next to `ABTestingCard`, a rule-builder UI, an Agency-gated "Generate localized variants" flow, new TanStack Query hooks, and re-labelling of `useABResults`/`ab-results-card` as "routing variants".

**Data flow (scan time):**

```
Scan → Worker fetch (src/index.js)
  → QR_KV.get(shortCode) → parsedData
  → status / password / custom-domain guards (unchanged)
  → if parsedData.routing && entitlements.routing_rules !== false:
        evaluateRouting(parsedData.routing, request, cookieHeader)
          → read request.cf.country/region/timezone + detectDevice(ua) + Accept-Language[0]
          → sticky qr_route_<sc> cookie wins; else first-match rule; else default
  → website: handleWebsiteRedirect picks the matched destination (variant_key) → 302
  → HTML types: handleQRCode renders content.variants[key] ?? content (base)
  → recordScan via ctx.waitUntil with extra.variant_key  (existing scans_by_variant counters light up)
  → set/refresh qr_route_<sc> (30-day, SameSite=Lax)
```

**Data flow (write time):** Frontend → `authApi` (Supabase JWT) → backend create/update → validate rules → persist `qr_destinations.rules` → (Agency, on demand) Claude generation → drafts saved → `sync_qr_to_kv()` rebuilds KV with `routing` + `content.variants`. No AI runs on the scan path; AI is bounded, batched, write-time only.

---

## 2. Data Model & Migrations

### 2.1 Migration file

`qr_backend/migrations/0015_routing_rules.sql` — begin/commit-wrapped, idempotent (`IF NOT EXISTS`, `ON CONFLICT`), no automated runner (applied in Supabase SQL Editor per repo convention).

```sql
-- Migration 0015: Edge Personalized Routing — ENGINE ONLY (v1).
-- AI variant generation (qr_routing_variants table, ai_variant_generations
-- counter, ai_variants flag) is DEFERRED to a Phase-2 migration; see below.
BEGIN;

-- 1. Ensure the routing-rules column the QRDestination model already references.
--    The `rules` field exists on QRDestinationCreate/Response but was never
--    created by any prior migration — a latent gap. Add it now (idempotent).
ALTER TABLE qr_destinations
    ADD COLUMN IF NOT EXISTS rules jsonb;

-- 2. Flag flip — routing_rules ON for Pro + Agency, explicit false elsewhere.
--    Matches the 0014 convention: lower(name) + is_custom guard (case-safe,
--    never touches custom/enterprise plans). A bare name IN ('Pro','Agency')
--    matches zero rows if plan names are stored lowercase → dead-on-arrival.
UPDATE plans SET features = jsonb_set(
    coalesce(features, '{}'::jsonb), '{routing_rules}', 'true'::jsonb, true)
    WHERE lower(name) IN ('pro', 'agency') AND coalesce(is_custom, false) = false;
UPDATE plans SET features = jsonb_set(
    coalesce(features, '{}'::jsonb), '{routing_rules}', 'false'::jsonb, true)
    WHERE lower(name) IN ('free', 'starter') AND coalesce(is_custom, false) = false;

COMMIT;
```

**Phase-2 migration (AI variants — NOT in 0015; number assigned when Phase 2 is built):** the deferred AI-variant schema, using the same `lower(name)` + `is_custom` guard.

```sql
BEGIN;
-- AI variant drafts + audit (Agency). content.variants is snapshotted into KV
-- at write time; this table is the editable source of truth + spend/audit log.
CREATE TABLE IF NOT EXISTS qr_routing_variants (
    id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    qr_id         uuid NOT NULL REFERENCES qr_codes(id) ON DELETE CASCADE,
    variant_key   text NOT NULL,            -- e.g. "es", "fr", "persona_premium"
    kind          text NOT NULL DEFAULT 'locale',  -- 'locale' | 'persona'
    locale        text,                     -- BCP-47, e.g. "es", "fr-CA"
    content       jsonb NOT NULL,           -- generated/edited copy, base-content subset
    is_published  boolean NOT NULL DEFAULT false,
    source        text NOT NULL DEFAULT 'ai', -- 'ai' | 'manual'
    model_id      text,                     -- snapshot of the Claude model used
    created_at    timestamptz NOT NULL DEFAULT now(),
    updated_at    timestamptz NOT NULL DEFAULT now(),
    UNIQUE (qr_id, variant_key)
);
CREATE INDEX IF NOT EXISTS idx_qr_routing_variants_qr ON qr_routing_variants(qr_id);
ALTER TABLE qr_codes ADD COLUMN IF NOT EXISTS ai_variant_generations int NOT NULL DEFAULT 0;
UPDATE plans SET features = jsonb_set(coalesce(features,'{}'::jsonb),'{ai_variants}','true'::jsonb,true)
    WHERE lower(name) = 'agency' AND coalesce(is_custom,false) = false;
UPDATE plans SET features = jsonb_set(coalesce(features,'{}'::jsonb),'{ai_variants}','false'::jsonb,true)
    WHERE lower(name) IN ('free','starter','pro') AND coalesce(is_custom,false) = false;
COMMIT;
```

**RLS note:** All backend access uses the Supabase **service-role key** (lazy singleton in `src/database/supabase.py`), which **bypasses RLS**. Tenant isolation is enforced in the app layer via `require_can_*` permission deps on the workspace-scoped routes, not by RLS policies. The new `qr_routing_variants` table inherits this model — no RLS policy is required for service-role reads, but a deny-by-default RLS policy should still be added for hygiene (the anon/auth keys are never used here).

### 2.2 `rules` JSONB shape (validated by Pydantic, see §3)

```json
{
  "default_variant_key": "b",
  "rules": [
    {
      "id": "r1",
      "match": {
        "country": ["DE", "FR"],
        "region": [],
        "device": ["mobile"],
        "language": ["de", "fr"],
        "time": { "start": "09:00", "end": "18:00", "days": [1,2,3,4,5],
                  "tz_mode": "scanner", "fixed_tz": null }
      },
      "target": { "variant_key": "a", "destination_url": "https://de.brand.com" }
    }
  ]
}
```

---

## 3. Backend Design

### 3.1 Files changed/added

| Concern | File |
|---|---|
| Rule model, write gate, validation, KV trigger | `qr_backend/src/api/routes/qr.py` |
| `routing` + `content.variants` snapshot | `qr_backend/src/utilities/cloudflare_kv.py` |
| AI generation (Claude, write-time, capped) | new `qr_backend/src/utilities/ai_variants.py` |
| Variant CRUD + generation endpoints | new `qr_backend/src/api/routes/routing.py` (mounted in `src/api/endpoints.py`) |
| Gating registry + entitlement | `qr_backend/src/api/routes/subscription.py`, `cloudflare_kv.py` |

### 3.2 Rule validation (qr.py)

Add a `RoutingRules` Pydantic model and validate `QRDestinationCreate.rules` against it on create/update. Constraints (raise `400` on violation, mirroring deep-link/API bypass defense):

- `default_variant_key` **required** and must exist among the destination/variant set (UI blocks save without a default; backend re-checks).
- `country`/`region` are ISO-3166 alpha-2 strings; `device ∈ {mobile,tablet,desktop}`; `language` is a BCP-47 primary subtag list; `time.start/end` are `HH:MM`; `tz_mode ∈ {scanner,fixed}`, `fixed_tz` required when `fixed`.
- Max **20 rules** per destination set; each rule must resolve to a known `variant_key`.
- Gate: `if dest.rules: if not await check_feature(workspace_id, "routing_rules", db): raise HTTPException(403)`.

`SELECT_WITH_RELATIONS` (qr.py ~line 836) already joins `qr_destinations` including the new `rules` column via `*`; the existing destination write loop (lines ~1355, ~2162) already passes `"rules": d.rules`, so persistence is automatic once the column exists. After the DB write, the existing synchronous `write_to_kv()` call path runs.

### 3.3 KV sync (cloudflare_kv.py)

Add a `routing` top-level key and (Agency) `content.variants`:

- **`build_routing(qr_id, supabase) -> dict | None`** — reads the active destination set's `rules` JSONB; returns `{ default_variant_key, rules: [...] }` or `None` when no rules exist. Pure passthrough of validated data (validation already happened at write).
- **`build_kv_content`** — for HTML-rendering types, after assembling base `content`, attach `content["variants"]` by querying `qr_routing_variants` where `is_published = true`, keyed by `variant_key`. Only published rows enter KV. Returns `{}`/unchanged for `website` (variants are URLs, carried in `destinations`).
- **`write_to_kv`** — add a `routing: dict | None = None` parameter and a `"routing": routing` payload key (alongside the existing 9 top-level keys: `qr_id, type, destination, destinations, is_password_protected, status, workspace_id, page_design, content, entitlements, pixels`).
- **`sync_qr_to_kv`** — pass `routing=build_routing(qr_id, supabase)` into `write_to_kv`. This makes routing survive every canonical rebuild (create/refresh, scan-limit disable, billing re-enable, downgrade resync).
- **`build_entitlements`** — add `routing_rules` and `ai_variants` booleans to the returned dict (read from `resolve_plan(...)["plan"]["features"]`), so the edge can self-defend on downgrade. Fail-closed (`False`) on resolution error, same as `white_labeling`/`ab_testing`.

### 3.4 AI generation (ai_variants.py, Phase 2)

`generate_variants(qr_id, locales, kind, workspace_id, db) -> list[VariantDraft]`:

1. Gate `await check_feature(workspace_id, "ai_variants", db)` → 403 if false.
2. Soft-cap: read `qr_codes.ai_variant_generations`; reject (429) when `>= 10` (configurable `AI_VARIANT_CAP`).
3. Load base `content` for the QR type (reuse `build_kv_content` minus variants).
4. Call Claude once per batch (all requested locales in a single structured request) — see §6.
5. Persist drafts to `qr_routing_variants` with `is_published = false`, `source = 'ai'`, `model_id` snapshot; increment the counter atomically.
6. Return drafts for the editable preview. **Nothing publishes** until the user saves (sets `is_published = true`), which re-runs `sync_qr_to_kv`.

### 3.5 Gating (subscription.py)

Add to `FEATURE_ENFORCEMENT` (line ~428), flipped `inert→enforced` in the **same PR** (the `test_feature_gate_coverage` parity test must stay green). **v1 registers only `routing_rules`**; `ai_variants` is registered in the Phase-2 PR with the generation pipeline, so 0015 only needs `routing_rules` seeded on every public plan:

```python
"routing_rules": "enforced",   # qr.py write gate + cloudflare_kv build_entitlements + worker guard
# "ai_variants": deferred to the Phase-2 (AI variants) PR
```

`invalidate_plan_cache(workspace_id)` is **not** needed on the write path (no subscription mutation), but the downgrade hook — now in **Phase 1**, §3.6 — must call it before the resync.

### 3.6 Downgrade resync hook (Phase 1 — required, NOT deferred)

**Eng-review finding (P1):** KV `entitlements` is a write-time snapshot, so the Worker's `entitlements.routing_rules === false` guard is only effective if a downgrade actually triggers a KV rebuild. Without this hook, a downgraded QR that is never re-saved keeps `entitlements.routing_rules: true` in KV forever and the edge keeps serving paid routing. The prior plan deferred this to Phase 3, which made the v1 mitigation circular. It therefore ships in **Phase 1**.

On `subscription.activated/charged/halted/cancelled` in `razorpay_routes.py` / `mor_routes.py`, after `invalidate_plan_cache(workspace_id)`, fire `background_tasks.add_task(resync_workspace_qrs, workspace_id, db)` so a Pro→Free downgrade collapses stale `routing`/`entitlements` to default at the edge. `resync_workspace_qrs` already iterates and calls `sync_qr_to_kv` per QR, so the hook is small. (This is the missing plan-change → KV hook the BE audit flags; landing it here closes a real entitlement leak, not just a routing edge case.)

---

## 4. Cloudflare Worker / Edge Design

### 4.1 KV schema additions

New **top-level key `routing`** on the QR KV value: `{ default_variant_key, rules: [...] }` or absent. New **`content.variants`** map (`{ "<variant_key>": { ...content subset } }`) for HTML types. `entitlements` gains `routing_rules` and `ai_variants` booleans.

### 4.2 New engine — `src/utils/routing.js`

Pure CPU, **no I/O**. Exports:

```js
export function evaluateRouting(routing, request, cookieHeader, shortCode) {
  // 1. sticky: qr_route_<shortCode> cookie → if its variant_key still exists, return it (pin=false)
  // 2. read signals: cf = request.cf; device = detectDevice(ua);
  //    lang = (Accept-Language || "").split(",")[0].split("-")[0].toLowerCase();
  //    now in tz (cf.timezone for "scanner", rule.fixed_tz for "fixed")
  // 3. first-match: iterate routing.rules in order; a rule matches when EVERY present
  //    condition matches (country/region in [...], device in [...], language in [...],
  //    time window incl. day-of-week). Empty/absent arrays = wildcard.
  // 4. no match → routing.default_variant_key. Return { variant_key, pin: !sticky }.
}
```

Reuses `detectDevice` and `readCookie` from `src/utils/scan.js`/`src/utils/ab.js`. Timezone math uses `Intl.DateTimeFormat` with the cf/fixed timezone (no external lib). **Eng-review (P2) — verify before committing time-window rules:** spike `Intl.DateTimeFormat({ timeZone: cf.timezone })` in the actual Cloudflare Workers isolate (historically limited ICU/tz data); if tz data is absent it silently returns UTC and every scanner-local window mis-routes. Fallback if the spike fails: a cheap fixed UTC-offset table keyed off `cf.timezone`. Construct the `Intl.DateTimeFormat` **only when a candidate rule actually carries a `time` condition** — skip it entirely for geo/device/language-only rule sets (constructing it is the one non-trivial CPU cost on the hot path). Target p95 added cost **< 1ms**; zero allocations beyond the small rule loop.

### 4.3 Wiring

- **`src/index.js`** — before the `website`/`handleQRCode` branch, compute:
  ```js
  const routingAllowed = parsedData.entitlements?.routing_rules !== false;
  const routeChoice = (parsedData.routing && routingAllowed)
    ? evaluateRouting(parsedData.routing, request, request.headers.get("Cookie"), shortCode)
    : null;
  ```
  Pass `routeChoice` into both branches. After the response, if `routeChoice?.pin`, append `Set-Cookie: qr_route_<sc>=<variant_key>; Path=/; Max-Age=2592000; SameSite=Lax` (30 days, mirrors `qr_ab_`).
- **`src/handlers/websiteRedirect.js`** — when `routeChoice` is present, pick the destination whose `variant_key === routeChoice.variant_key` (rule wins over weight-split). When `routeChoice` is null, fall back to the **existing** A/B weighted sticky path unchanged (resolves Open Question #1: rule wins, weight is the no-match fallback). `recordScan` already receives `extra.variant_key`. **Eng-review (P2) — two-cookie precedence:** `qr_route_<sc>` (routing) and `qr_ab_<sc>` (A/B) are separate namespaces; define the state machine explicitly. If the QR has a `routing` block, the routing engine owns the decision and the `qr_ab_` cookie is ignored (a previously A/B-pinned scanner may flip variants once when rules are first added — acceptable, but document it in the builder UI). Pure A/B QRs (no `routing` block) keep the existing `qr_ab_` path untouched. Never read both cookies in one decision.
- **`src/handlers/qrRouter.js` (`handleQRCode`)** — accept `routeChoice`; for HTML types, select `kvContent.variants?.[routeChoice.variant_key] ?? kvContent` (base) **before** rendering. Variants reuse the same edge-signed Storage URLs as base content. **Eng-review (P2) — confirm `getSupabaseSignedUrls` is the EXISTING base-content path and adds no scan-time network round-trip.** If base content already re-signs at the edge today, variants add nothing and the "zero new network calls" guardrail holds; if signing is a live Storage call, the ≤1ms guarantee is already violated for HTML types (independent of routing) and the spec must say so. No new exposure either way.

### 4.4 Scan-data implications

`recordScan` already captures `country_code`, `region`, `city`, `timezone`, `device_type`, `language` (first `Accept-Language` tag) — **all inputs the engine needs are already read**. For HTML types we now pass `extra.variant_key` (previously only `website` did), so `scans_by_variant`/`unique_scans_by_variant` counters populate for content variants too. No new scan fields are required.

### 4.5 Template mirroring

No new page templates are introduced — variants reuse existing per-type templates with substituted content. **House rule still applies:** any future locale-specific template must be mirrored React↔Worker. RTL/font-swap is explicitly out of v1 (copy-only, shared design — Open Question #4).

### 4.6 `scheduled()`

No new cron. The existing `0 0 1 * *` free-scan-reset cron is untouched. (Time-window rules are evaluated **per-scan** against `request.cf.timezone`, not by a scheduler — that is the whole point of edge evaluation.)

---

## 5. Frontend Design

### 5.1 Routes & components

- **QR detail** (`src/components/org/qrs/QRDetails.tsx`) — add a **Routing** tab/card next to `ABTestingCard`, gated. New components under `src/components/org/qrs/details/`:
  - `routing-card.tsx` — entry; if `!canAccessFeature(subscription, 'routing_rules')` renders `routing-upgrade-gate.tsx` (mirrors the analytics `UpgradeGate` pattern).
  - `routing-rule-builder.tsx` — ordered, drag-to-reorder rule list (first-match), each rule a condition set + target; mandatory **default** selector (save blocked without it). Plain-English preview per rule.
  - `ai-variants-panel.tsx` — Agency only (`canAccessFeature(subscription, 'ai_variants')`); "Generate localized variants" → locale/persona picker → editable draft preview → publish. Disabled with an Agency upsell for Pro-without-Agency.
- **Builder** (`src/app/org/[slug]/(builder)/build/`) — optional Routing step for dynamic types (kept ≤200 lines/file; pages stay thin shells delegating to components).

### 5.2 Hooks (`src/hooks/`)

New `useRouting.ts` with a query-key factory:

```ts
export const routingKeys = {
  all: ['routing'] as const,
  rules: (qrId: string) => [...routingKeys.all, 'rules', qrId] as const,
  variants: (qrId: string) => [...routingKeys.all, 'variants', qrId] as const,
};
export function useRoutingRules(qrId: string) { /* authApi.get(`/workspaces/${ws}/qr-codes/${qrId}/routing`) */ }
export function useSaveRoutingRules() { /* useMutation → PUT → invalidate routingKeys.rules + qrKeys.lists() */ }
export function useRoutingVariants(qrId: string) { /* GET variants */ }
export function useGenerateVariants() { /* POST .../variants/generate → invalidate variants */ }
export function usePublishVariant() { /* PATCH .../variants/{key} */ }
```

All HTTP goes through `authApi` from `src/lib/api-client.ts`. Mutations follow the repo pattern: `onSuccess → invalidateQueries + toast`, `onError → toast`, deletes `retry: false`.

### 5.3 Analytics relabel

Reuse `useABResults(qrId)` (in `src/hooks/useAnalytics.ts`) and `ab-results-card.tsx` — relabel "A/B variant" → "Routing variant" copy-only (Phase 1). Phase 2 adds a matched-rule breakdown.

### 5.4 Design system

shadcn/ui primitives only (`Button`, `Card`, `Select`, `Badge`, `Table`, `Skeleton`); layout via `PageHeader`/`Card`/`EmptyState` from `src/components/org/index.ts`. Tokens from `tailwind.config.cjs` (`primary #4648d4`, `tertiary` cyan, `surface-container-*`, `on-surface`/`on-surface-variant`), `cn()` from `src/lib/utils.ts`. No inline styles, no `any`, kebab-case files, one export per file. Forms use react-hook-form + zod (schemas in `src/lib/validations/`).

### 5.5 Plan-features

`PlanFeatures` interface in `src/hooks/useSubscription.ts` and `src/lib/plan-features.ts` gain `routing_rules: boolean` and `ai_variants: boolean`. Gating uses `canAccessFeature(subscription, 'routing_rules' | 'ai_variants')`. `ACTIVE_STATUSES = {active, trialing}` (created excluded) is respected automatically.

---

## 6. AI / External-Service Integration (Phase 2)

- **Model:** `claude-sonnet-4-6` for localized/persona copy generation — the right cost/quality tier for short, structured landing-copy rewrites (well below opus cost, far above haiku quality for nuanced localization). `claude-haiku-4-5` is a fallback for high-volume batches if spend pressure appears; the chosen `model_id` is snapshotted per draft in `qr_routing_variants.model_id`.
- **Where it runs:** **backend only, at write time** — never at the edge, never on the scan path. The Worker has no Anthropic binding and makes no inference call. This is the whole moat: AI output is pre-generated and cached into KV.
- **Dependency:** add `anthropic` to `qr_backend/requirements.txt`; add `ANTHROPIC_API_KEY` to backend `.env`/`.env.example` and config (`src/config/manager.py`). Confirm model id/pricing against the current Claude API reference at build time.
- **I/O contract:** one batched request per generation — system prompt pins JSON-only structured output (the per-locale content subset matching the QR type's editable fields), input is the base `content` + a list of target locales/personas. Output is parsed, schema-validated, and stored as drafts. Temperature low (~0.3) for faithful translation.
- **Caching:** drafts persist in `qr_routing_variants`; published variants snapshot into KV `content.variants`. Regeneration is user-initiated and capped at 10/QR (`ai_variant_generations`). No per-scan calls → marginal cost is bounded and small relative to the Agency price point.
- **Fallbacks/safety:** on API error/timeout, return a 502 with a retry CTA — base content still serves. Generated copy requires explicit publish (never auto-published); one-click revert to base. Prompt+output are logged for review/abuse audit.

---

## 7. API Contracts

All under `/api/v1/workspaces/{workspace_id}/qr-codes/{qr_id}/...` (Bearer JWT; `require_can_update`).

**Get rules**
```
GET .../routing → 200
{ "default_variant_key": "b",
  "rules": [ { "id": "r1", "match": {...}, "target": { "variant_key": "a" } } ] }
```

**Save rules** (gated `routing_rules`)
```
PUT .../routing
{ "default_variant_key": "b", "rules": [ ... ] }
→ 200 { "ok": true }   | 403 feature   | 400 invalid (missing default / bad device / >20 rules)
```

**Generate AI variants** (gated `ai_variants`, Agency)
```
POST .../variants/generate
{ "locales": ["es","fr","de"], "kind": "locale" }
→ 200 { "variants": [ { "variant_key": "es", "locale": "es", "content": {...}, "is_published": false } ] }
→ 403 not-Agency | 429 cap reached (>=10) | 502 model error
```

**Publish / edit a variant**
```
PATCH .../variants/{variant_key}
{ "content": {...}, "is_published": true }
→ 200 { "ok": true }   (triggers sync_qr_to_kv)
```

**Worker-side (no new internal endpoint):** routing is fully self-contained in KV. The only internal endpoint relevant is the existing `POST /internal/scans` (x-internal-secret), which already accepts `variant_key`.

---

## 8. Security, Privacy & Abuse

- **Auth:** All write endpoints sit behind `BearerTokenAuthMiddleware` + `require_can_update`. AI generation additionally requires `check_feature('ai_variants')`. No new public route.
- **Tenant isolation:** Service-role bypasses RLS; isolation enforced by workspace-scoped path + permission deps. `qr_routing_variants.qr_id` is validated to belong to the path workspace before any read/write. Worker custom-domain isolation (`domain:<hostname>` → workspace match) is unchanged and still rejects cross-tenant short codes before routing runs.
- **Injection/XSS:** All variant copy is user/AI text rendered through the existing `escapeHTML()` (from `src/utils/html.js`) in templates — same guarantee as base content. AI output is schema-validated server-side before persistence; no HTML/script fields accepted.
- **Privacy / PII:** The engine reads only coarse signals (country/region/device/language/timezone) already captured by `recordScan` — no new PII, no per-scanner profile store. The sticky `qr_route_<sc>` cookie holds only a 1-char variant key (no identity). It is a strictly-necessary functional cookie (consistency), not marketing — outside the marketing-consent gate. The existing EU consent strip (`src/utils/consent.js`, geo-gated to 31 EU/EEA/UK codes) is unaffected and still fires only when `hasMarketingTags=true` (i.e. retargeting pixels present), injected last.
- **Abuse:** AI generation soft-capped at 10/QR via `ai_variant_generations`; prompt+output logged. Rule count capped at 20/destination-set. No user-controlled URLs are fetched server-side during generation.

---

## 9. Performance, Scale & Cost

- **Scan path:** `evaluateRouting` is pure CPU over `request.cf` + a bounded rule loop (≤20) + one cookie parse + one `Intl.DateTimeFormat` call. Target **≤1ms p95 added**, **zero** new origin/backend/KV calls (verified via Worker timing logs as a release guardrail). KV value grows by the `routing` block + published `content.variants` (a few KB) — well within KV's 25MB value limit.
- **Write path:** unchanged latency for rule saves (one extra column write + existing synchronous `write_to_kv`). AI generation is the only slow path (seconds, one batched Claude call) and is explicitly async-from-scan, user-initiated, and capped — predictable, small marginal cost at the Agency price point.
- **KV consistency:** KV is eventually consistent; a rule edit propagates within KV's normal window. Sticky cookies mean a pinned scanner may see the prior variant until expiry (v1 accepts this, consistency-first like A/B; Phase 3 adds an optional cache-bust token).

---

## 10. Testing Strategy

**Backend (pytest):**
- `test_feature_gate_coverage` stays green after adding `routing_rules`/`ai_variants` to `FEATURE_ENFORCEMENT`.
- Rule validation: rejects missing default, unknown `variant_key`, `device` outside enum, >20 rules, bad time format (400).
- Gate-deny: Free/Starter write of rules → 403; non-Agency generate → 403; cap-exceeded generate → 429.
- KV sync: `build_routing` returns the rules block; `build_kv_content` includes only `is_published=true` variants; `build_entitlements` emits both flags; downgrade resync collapses `routing` to default (entitlement false).
- AI: mock the Anthropic client; assert batched single call, schema-validated drafts, counter increment, `is_published=false`.

**Frontend (Vitest/Playwright):** New routing-builder + gate tests. **Note the ~29 pre-existing FE test failures (Phase-3 baseline) — do not treat them as regressions;** assert net-new tests pass and baseline count is unchanged. Gate tests: Free/Starter sees `routing-upgrade-gate`; Pro sees builder but AI button disabled; Agency sees AI flow.

**Worker (node test runner):** `evaluateRouting` unit tests — sticky-cookie wins; first-match precedence; wildcard arrays; scanner-vs-fixed timezone windows incl. day-of-week; no-match → default; `entitlements.routing_rules === false` → default (downgrade defense); **`Intl.DateTimeFormat({ timeZone })` resolution in the Workers runtime (assert non-UTC for a known tz — drives the §4.2 fallback decision); two-cookie precedence (routing present → `qr_ab_` ignored)**. Integration: `website` rule-vs-weight precedence; HTML `content.variants[key] ?? base`; cookie set/refresh; `recordScan` receives `variant_key`. **Staleness regression (finding 1):** KV with `entitlements.routing_rules: true` but the workspace downgraded and the QR not re-saved → assert the Phase-1 resync hook rebuilt KV to `false`/default.

**Acceptance (Phase 1):** Pro QR with `{DE→A, default→B}` serves A to a DE scanner, B otherwise, sticks across repeats, records per-variant scans, ≤1ms p95 with no backend call; Free/Starter sees the gate; Pro→Free downgrade collapses to default after resync; malformed rule rejected at write.

---

## 11. Observability & Rollout

- **Flags:** `routing_rules`/`ai_variants` in `plans.features` + `FEATURE_ENFORCEMENT` (flip `inert→enforced` same PR). Worker reads `entitlements.routing_rules` as defense-in-depth.
- **Phased deploy (all 3 services):**
  - **Phase 0:** apply `0015` to Supabase (user action) — engine schema only (`rules` column + `routing_rules` flips); flags live but no UI.
  - **Phase 1 (v1):** deploy backend (validation + KV `routing` + entitlement + **the downgrade → `resync_workspace_qrs` hook, §3.6**) → deploy Worker (`evaluateRouting` + wiring) to dev (`sparkling-waterfall-3a9f`) then prod (`qr-worker-prod`) → ship FE routing tab. Order matters: backend/Worker must understand `routing` before FE lets users author it. The resync hook ships here because the Worker entitlement guard is otherwise ineffective (§3.6).
  - **Phase 2 (AI variants — separate PR):** apply the Phase-2 migration (`qr_routing_variants` + `ai_variant_generations` + `ai_variants` flip), register `ai_variants` in `FEATURE_ENFORCEMENT`, add `ANTHROPIC_API_KEY` + `anthropic` dep, ship `ai_variants.py` + generation UI (Agency beta → GA).
  - **Phase 3:** GA polish, matched-rule analytics breakdown, persona-tone presets, optional sticky-cookie cache-bust token.
- **Metrics:** Worker timing log for `evaluateRouting` p95 (guardrail ≤1ms); rule-creation rate (≥20% Pro/Agency in 30d); AI publish-rate (generated→published ≥50%); per-variant scan counters via existing `scans_by_variant`. Mixpanel events on rule save / variant generate (token-gated; EU consent re-add still pending per existing memory — non-EU launch OK).

---

## 12. Open Technical Questions & Risks

1. **Rule vs weight when both present** — v1: matched rule wins outright; weight-split is the no-match fallback (implemented in §4.3). Combined weight-split *within* a matched rule deferred.
2. **AI metering** — soft cap 10 generations/QR via `ai_variant_generations` (recommended). Revisit if Agency demand exceeds the cap meaningfully.
3. **Persona vs locale** — locale-first in v1; persona as a copy-tone toggle (`kind='persona'`) — schema supports both already.
4. **Multilingual page-design (RTL/font swap)** — out of v1 (copy-only, shared design). RTL/font work would require mirrored React↔Worker templates per the house rule.
5. **City-level rules** — deferred (CF gives city but rule cardinality explodes). Country/region only in v1.
6. **`rules` column was never created** despite being in the Pydantic model — `0015` finally adds it; **risk:** any environment where the model already attempted to write `rules` would have silently dropped it. Verify no orphaned expectation; the column add is idempotent.
7. **Entitlement-snapshot staleness** — RESOLVED per eng-review: the downgrade → `resync_workspace_qrs` hook moves to **Phase 1** (§3.6), so a downgrade actively rebuilds KV and collapses `entitlements.routing_rules` to the live value. The Worker `=== false` guard stays as defense-in-depth, but it is no longer the *only* line — the prior "sufficient because `build_entitlements` re-evaluates on sync" claim was circular, since nothing triggered a sync on downgrade until this hook.
8. **Sticky-cookie vs rule change** — v1 accepts stale pinning until 30-day expiry (consistency-first, like A/B); Phase 3 cache-bust token.

---

## Appendix — Key Files

| Concern | File |
|---|---|
| Rule model, write gate, validation | `qr_backend/src/api/routes/qr.py` (`QRDestinationCreate.rules`, `SELECT_WITH_RELATIONS`) |
| Variant CRUD + AI generation endpoints | `qr_backend/src/api/routes/routing.py` (new), `src/api/endpoints.py` |
| KV snapshot (`routing` + `content.variants`) | `qr_backend/src/utilities/cloudflare_kv.py` (`build_routing`, `build_kv_content`, `build_entitlements`, `write_to_kv`, `sync_qr_to_kv`) |
| AI generation (Claude write-time, capped) | `qr_backend/src/utilities/ai_variants.py` (new, `claude-sonnet-4-6`) |
| Gating registry | `qr_backend/src/api/routes/subscription.py` (`FEATURE_ENFORCEMENT`) |
| Worker routing engine | `qr_cf_code/src/utils/routing.js` (new) |
| Worker wiring | `qr_cf_code/src/index.js`, `src/handlers/websiteRedirect.js`, `src/handlers/qrRouter.js` |
| Sticky cookie + scan attribution | `qr_cf_code/src/utils/ab.js`, `qr_cf_code/src/utils/scan.js` |
| Builder / detail UI | `qr_frontend/src/components/org/qrs/details/{routing-card,routing-rule-builder,ai-variants-panel,routing-upgrade-gate}.tsx`, `QRDetails.tsx` |
| Hooks | `qr_frontend/src/hooks/useRouting.ts` (new), `useAnalytics.ts` (`useABResults` relabel) |
| Plan features | `qr_frontend/src/lib/plan-features.ts`, `qr_frontend/src/hooks/useSubscription.ts` |
| Migration | `qr_backend/migrations/0015_routing_rules.sql` (new) |
