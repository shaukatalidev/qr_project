# TRD — Ask-Your-Scans AI Analyst (Claude)

**Status:** Draft · **Author:** Engineering (Staff) · **Date:** 2026-06-24
**Priority:** Strategic (first AI surface) · **Tiers:** Pro (`advanced_analytics` already enforced + new `ai_analyst`) · Agency (same) · Free/Starter — none
**Plan flags:** `ai_analyst` (bool) + limit `ai_analyst_queries_per_month` (int) + digest sub-allotment `ai_digest_runs_per_month` (int), all seeded `false`/`0` on every tier by migration `0014`, flipped Pro/Agency in the same migration. `ai_analyst` is registered `inert` in `FEATURE_ENFORCEMENT` and flipped `enforced` in this PR (coverage test stays green).
**Implements PRD:** Ask-Your-Scans AI Analyst (Claude).
**Rev (2026-06-24, post eng-review):** `get_period_comparison` tool added (deltas computed in SQL/Python, not by the model); chart is now a `{kind, source}` selector with backend-attached `data`; `scan.py` reader extraction lands as its own PR first; grounding split into `test_ai_analyst_plumbing` (stub) + `test_ai_analyst_delta_grounding` + a separate live-eval release gate; weekly digest fans out as idempotent (`last_digest_at`-gated) background tasks; redundant `jsonb_set` in the Pro migration removed. Migration stays `0014` (roadmap sequence 0014–0018).

---

## 1. Overview & Architecture

This feature adds a conversational analytics surface plus a weekly prose digest. It is overwhelmingly a **backend** change; the frontend reuses existing analytics chart components, and the worker only gains one cron trigger. Claude runs **server-side only** in `qr_backend` via the Anthropic SDK — there is no edge inference and no new client capture, so the EU consent posture at the worker is unchanged.

**Services touched**

| Service | Change |
|---|---|
| `qr_backend` | New router `ai_analyst.py` (ask endpoint + fixed Claude tool surface), refactor of `scan.py` aggregate readers into shared callables, new metering RPC + tables (migration 0014), new internal cron endpoint `POST /internal/ai-digest-run`, Resend digest email, `ai_analyst` flag in `FEATURE_ENFORCEMENT`. |
| `qr_frontend` | New "Ask your scans" panel on the analytics page, `useAskAnalyst` mutation hook + `useAiAnalystUsage` query hook, digest toggle wiring the dead "Schedule Weekly Report" button, `ai_analyst` gating in `plan-features.ts`. |
| `qr_cf_code` | One new cron trigger (`0 0 * * 1`, Monday 06:00 UTC range — see §4) in `wrangler.toml` dev+prod, mirroring the existing `free-scan-reset` registration, posting to `/internal/ai-digest-run`. No KV, scan, or template changes. |

**Data flow — interactive ask**

```
FE Ask panel (analytics/page.tsx)
  → useAskAnalyst → authApi.post(/workspaces/{id}/ai-analyst/ask, {question})
  → BearerTokenAuthMiddleware (attaches user_id) → require_can_read → ai_analyst.py
    1. check_feature('advanced_analytics') AND check_feature('ai_analyst')  [403 if either false]
    2. increment_ai_usage(ws, period_start, 'query') RPC → if > cap → 429 + RateLimit-* headers
    3. Anthropic Messages API (tool-use loop): Claude calls fixed allowlist tools
       → each tool runs the SHARED scan.py aggregate reader, scoped to PATH workspace_id
       → tool returns numbers + short labels only (never free text)
    4. Claude emits final {narrative, chart{kind,data}}; backend records usage tokens
  → response {narrative, chart, used_tools, usage} → FE renders narrative + existing chart component
```

**Data flow — weekly digest**

```
Cloudflare Cron (Mon) → scheduled() in qr_cf_code/src/index.js
  → POST BACKEND_URL/internal/ai-digest-run (x-internal-secret)
  → internal.py selects ai_analyst_settings(digest_enabled=true, not-yet-done-this-ISO-week)
    → fan each workspace out as a bounded background task; endpoint returns immediately:
        re-check entitlement → meter ai_digest_runs_per_month
        → run the SAME tool-grounded Claude flow (fixed digest prompt)
        → send_ai_digest_email(recipient, prose) [Resend] → stamp last_digest_at
```

The numbers are grounded in Qravio's proprietary edge scan corpus (`qr_scan_counters` / `qr_scan_events`) — that is the moat.

---

## 2. Data Model & Migrations

New file: **`qr_backend/migrations/0014_ai_analyst.sql`** (next number after `0013_retargeting_pixels.sql`). Begin/Commit wrapped, idempotent. Service-role REST client bypasses RLS, so RLS policies are advisory only; we add a deny-all RLS policy to be safe-by-default (anon/auth roles can never read these tables; only the service key, which is never exposed to the browser, touches them).

```sql
BEGIN;

-- ── Per-workspace AI Analyst settings (digest opt-in) ──────────────────────
CREATE TABLE IF NOT EXISTS ai_analyst_settings (
    workspace_id    uuid        PRIMARY KEY REFERENCES workspaces(id) ON DELETE CASCADE,
    digest_enabled  boolean     NOT NULL DEFAULT false,
    digest_recipient text       NULL,            -- defaults to workspace owner email at send time
    last_digest_at  timestamptz NULL,
    created_at      timestamptz NOT NULL DEFAULT now(),
    updated_at      timestamptz NOT NULL DEFAULT now()
);

-- ── Monthly metering counters (mirrors api_usage shape from 0010) ──────────
-- kind = 'query' (interactive) | 'digest' (cron). Separate rows → separate caps.
CREATE TABLE IF NOT EXISTS ai_analyst_usage (
    workspace_id   uuid        NOT NULL REFERENCES workspaces(id) ON DELETE CASCADE,
    period_start   date        NOT NULL,
    kind           text        NOT NULL DEFAULT 'query',
    call_count     integer     NOT NULL DEFAULT 0,
    input_tokens   bigint      NOT NULL DEFAULT 0,   -- margin monitoring
    output_tokens  bigint      NOT NULL DEFAULT 0,
    cache_read_tokens bigint   NOT NULL DEFAULT 0,
    updated_at     timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (workspace_id, period_start, kind)
);

ALTER TABLE ai_analyst_settings ENABLE ROW LEVEL SECURITY;
ALTER TABLE ai_analyst_usage    ENABLE ROW LEVEL SECURITY;
-- No policies created → only the service role (bypasses RLS) can read/write.

-- ── Atomic increment + token accounting (mirrors increment_api_usage RPC) ──
CREATE OR REPLACE FUNCTION increment_ai_usage(
    p_workspace_id uuid,
    p_period_start date,
    p_kind         text,
    p_in_tokens    bigint DEFAULT 0,
    p_out_tokens   bigint DEFAULT 0,
    p_cache_tokens bigint DEFAULT 0
)
RETURNS integer
LANGUAGE plpgsql
AS $$
DECLARE
    new_count integer;
BEGIN
    INSERT INTO ai_analyst_usage (workspace_id, period_start, kind, call_count,
                                  input_tokens, output_tokens, cache_read_tokens, updated_at)
    VALUES (p_workspace_id, p_period_start, p_kind, 1,
            p_in_tokens, p_out_tokens, p_cache_tokens, now())
    ON CONFLICT (workspace_id, period_start, kind)
    DO UPDATE SET call_count        = ai_analyst_usage.call_count + 1,
                  input_tokens      = ai_analyst_usage.input_tokens + EXCLUDED.input_tokens,
                  output_tokens     = ai_analyst_usage.output_tokens + EXCLUDED.output_tokens,
                  cache_read_tokens = ai_analyst_usage.cache_read_tokens + EXCLUDED.cache_read_tokens,
                  updated_at        = now()
    RETURNING call_count INTO new_count;
    RETURN new_count;
END;
$$;

-- ── Flag + cap flip (jsonb_set create-if-missing, like 0010) ──────────────
-- Free/Starter keep ai_analyst=false / caps=0 (gate denies them).
UPDATE plans
SET features = jsonb_set(jsonb_set(
        jsonb_set(features, '{ai_analyst}', 'true'::jsonb, true),
        '{ai_analyst_queries_per_month}', '50'::jsonb, true),
        '{ai_digest_runs_per_month}', '5'::jsonb, true)
WHERE lower(name) = 'pro' AND coalesce(is_custom, false) = false;

UPDATE plans
SET features = jsonb_set(jsonb_set(
        jsonb_set(features, '{ai_analyst}', 'true'::jsonb, true),
        '{ai_analyst_queries_per_month}', '300'::jsonb, true),
        '{ai_digest_runs_per_month}', '5'::jsonb, true)
WHERE lower(name) = 'agency' AND coalesce(is_custom, false) = false;

-- Seed false/0 on every other public plan so the coverage test sees the keys.
UPDATE plans
SET features = jsonb_set(jsonb_set(jsonb_set(
        features, '{ai_analyst}', 'false'::jsonb, true),
        '{ai_analyst_queries_per_month}', '0'::jsonb, true),
        '{ai_digest_runs_per_month}', '0'::jsonb, true)
WHERE lower(name) IN ('free', 'starter') AND coalesce(is_custom, false) = false;

COMMIT;
```

No changes to `qr_scan_events` / `qr_scan_counters` — the tool surface reads the existing JSONB aggregates (`scans_by_device`, `scans_by_country`, `scans_by_date`, `scans_by_hour`, `scans_by_variant`).

---

## 3. Backend Design

### 3.1 Refactor: extract shared aggregate readers (`scan.py`)
The PRD requires the tool surface to wrap — not duplicate — `scan.py` logic. Today the analytics handlers (`get_analytics_devices`, `get_analytics_top_countries`, `get_analytics_days`, `get_analytics_hourly`, `get_analytics_ab_results`, `get_analytics_top`, etc.) embed both the gate (`_require_advanced_analytics`) and the Supabase query. We extract the **pure query bodies** into gate-free callables in `scan.py`:

```python
# scan.py — new pure readers (no HTTP, no advanced_analytics gate;
# gating happens once in ai_analyst.py before any tool runs)
def read_scans_by_date(workspace_id: str, db: Client, days: int) -> dict[str, int]
def read_scans_by_device(workspace_id: str, db: Client) -> dict[str, int]
def read_scans_by_country(workspace_id: str, db: Client, limit: int) -> list[dict]
def read_scans_by_hour(workspace_id: str, db: Client) -> list[dict]
def read_scans_by_variant(qr_id: str, workspace_id: str, db: Client) -> dict
def read_top_qrs(workspace_id: str, db: Client, limit: int) -> list[dict]
def read_workspace_summary(workspace_id: str, db: Client) -> dict
def read_lead_counts(workspace_id: str, db: Client, days: int) -> dict
# Period-over-period comparison — deltas/percentages computed HERE (SQL/Python), never by the model.
# Returns {metric: {current, prior, delta_abs, delta_pct}} for total scans, device shares, and lead counts.
def read_period_comparison(workspace_id: str, db: Client, days: int) -> dict[str, dict]
```

Each clamps the date window via the existing `get_limit(workspace_id, db, "analytics_retention_days")` so the AI can never answer beyond plan retention. The existing HTTP handlers are rewritten to call these readers after their gate check — zero behavior change, verified by the existing analytics tests. **Land this extraction as its own PR first** (pure refactor, no behavior change, green on the existing analytics tests); the `ai_analyst.py` PR then only adds new code on top. Structural and behavioral changes must not ride in one commit — a regression must stay easy to bisect (Beck: make the change easy, then make the easy change).

### 3.2 New router: `qr_backend/src/api/routes/ai_analyst.py`
Registered in `qr_backend/src/api/endpoints.py` under the standard JWT prefix (`/api/v1`), so `BearerTokenAuthMiddleware` runs and attaches `user_id`.

```
POST /api/v1/workspaces/{workspace_id}/ai-analyst/ask
GET  /api/v1/workspaces/{workspace_id}/ai-analyst/usage      # quota meter
GET  /api/v1/workspaces/{workspace_id}/ai-analyst/settings   # digest opt-in state
PUT  /api/v1/workspaces/{workspace_id}/ai-analyst/settings   # toggle digest
```

**Gating helper** (called at the top of `ask` and `settings` writes):
```python
async def _require_ai_analyst(workspace_id: str, user_id: str, db: Client) -> None:
    # require_can_read already enforces workspace membership via Depends
    if not await check_feature(workspace_id, "advanced_analytics", db):
        raise HTTPException(403, "advanced_analytics required")
    if not await check_feature(workspace_id, "ai_analyst", db):
        raise HTTPException(403, detail={"code": "ai_analyst_locked",
                                         "upgrade_to": "pro"})
```
Plan-downgrade safety: because `check_feature` reads the resolved plan (`resolve_plan`, 30s cache), a mid-month downgrade flips this to `403` on the next ask — identical to `api_public.py`.

**Metering** (mirrors `api_public.api_key_auth`): after gating, atomically increment then compare:
```python
quota = _limit_value(resolved["plan"], "ai_analyst_queries_per_month")
period = period_start_iso(resolved)               # billing-anchor window
count = db.rpc("increment_ai_usage",
               {"p_workspace_id": ws, "p_period_start": period,
                "p_kind": "query"}).execute().data
if quota != -1 and count > quota:
    raise HTTPException(429, headers={
        "X-RateLimit-Limit": str(quota), "X-RateLimit-Remaining": "0",
        "X-RateLimit-Reset": str(reset_epoch)}, detail={"code": "ai_quota_exceeded"})
```
Increment-then-check (fail-closed read) means concurrent asks can't exceed the cap. `-1` (unlimited) is intentionally not offered (margin protection).

### 3.3 Claude tool surface (the safety core)
A **fixed allowlist** of tools, each a thin wrapper over a §3.1 reader, **server-bound to the path `workspace_id`** — no tool takes a workspace argument. The model literally cannot name another tenant.

| Tool | Args (model-supplied) | Reader |
|---|---|---|
| `get_scans_by_date` | `days` (7/30/90/365, clamped) | `read_scans_by_date` |
| `get_scans_by_device` | — | `read_scans_by_device` |
| `get_scans_by_country` | `limit` (≤25) | `read_scans_by_country` |
| `get_scans_by_hour` | — | `read_scans_by_hour` |
| `get_scans_by_variant` | `qr_id` (validated ∈ workspace) | `read_scans_by_variant` |
| `get_top_qrs` | `limit` (≤25) | `read_top_qrs` |
| `get_lead_counts` | `days` | `read_lead_counts` |
| `get_period_comparison` | `days` (7/30/90, clamped) | `read_period_comparison` |
| `get_workspace_summary` | — | `read_workspace_summary` |

Tool results return **numbers and short enum labels only** (country codes, device buckets, ISO dates, QR titles `escape`-truncated to 60 chars) — never raw lead text or arbitrary user free-text, so QR-title prompt injection cannot smuggle instructions. The system prompt forbids arithmetic on un-fetched data and requires every stated number to come from a tool result. `qr_id` args are validated against `qr_codes.workspace_id == path_ws` before the reader runs (HTTPException 400 on mismatch).

The handler runs the Anthropic tool-use loop (≤6 turns, hard ceiling), recording every `used_tools` call (name + args + the **full real result**, kept server-side), then asks Claude for a final structured emission of **only** a markdown `narrative` plus a `chart` selector `{kind, source}` — `kind ∈ {days, devices, geographic, hourly, top}` and `source` names which prior tool call to plot. **The model never emits chart numbers.** The backend deterministically attaches `chart.data` from the recorded result of the named `source` call (already shaped like the matching `useAnalytics*` hook output) before responding, so the chart is un-hallucinatable by construction and costs zero output tokens. If `source` names a tool that was not called, the backend omits the chart rather than fabricate one. Likewise, any delta or percentage in the narrative must come from a `get_period_comparison` result — the model is instructed never to subtract two separate tool results itself.

### 3.4 Internal digest endpoint (`internal.py`)
Add `POST /api/v1/internal/ai-digest-run` under the existing `internal_router` (router-level `Depends(verify_internal_secret)` — x-internal-secret). It selects `ai_analyst_settings` where `digest_enabled=true` **AND (`last_digest_at` IS NULL OR `last_digest_at` < start-of-ISO-week)** — so the run is **idempotent and resumable**: a duplicate cron fire or a retry skips workspaces already done this week. Rather than run N live Claude calls **inline** (one HTTP request held open across N sequential model round-trips — a timeout risk past a few dozen enrolled workspaces), it **fans each workspace out as its own background task** (`background_tasks.add_task`, behind a small concurrency semaphore to respect the Anthropic rate limit) and returns immediately with the dispatched count. Each task re-checks `ai_analyst` entitlement, meters against `ai_digest_runs_per_month` (kind=`'digest'`, separate budget — Open Q1 resolved as separate), runs the same tool-grounded flow with a fixed weekly-digest prompt, resolves the recipient (`digest_recipient` else workspace owner email from `workspace_members`/`auth.users`), sends via Resend, and stamps `last_digest_at` on success. Per-workspace try/except + loud logging; one failure never aborts the sweep (mirrors `_reenable_free_scan_disabled`).

### 3.5 Email (`utilities/email.py`)
New `send_ai_digest_email(to_email, workspace_name, prose_html)` reusing the existing Resend `resend.Emails.send` pattern and the indigo-styled template scaffold already in the file.

### 3.6 KV / entitlements
No KV write-path change is required — the assistant never renders at the edge. We do **not** thread `ai_analyst` into `build_entitlements` (that snapshot governs per-QR worker rendering: `white_labeling`, `ab_testing`, `brand`). Adding it would be dead weight at the edge. Gating is entirely backend-side. This is a deliberate divergence from features like pixels/white-label whose enforcement lives at the worker.

### 3.7 New env var
`ANTHROPIC_API_KEY` added to `qr_backend/.env` per environment and to `.env.example`; read via `settings` (`src/config/manager.py`). The handler fails closed (`503 ai_unavailable`) if the key is unset, so a misconfigured env never 500s a user.

---

## 4. Cloudflare Worker / Edge Design

Minimal. The worker gains exactly one responsibility: a second cron trigger that pings the digest endpoint, mirroring the `free-scan-reset` pattern documented in memory.

**`wrangler.toml`** — add to both `[env.development.triggers]` and `[env.production.triggers]` crons arrays. Cloudflare cron is UTC; a true "Monday 06:00 UTC" is `0 6 * * 1`. We register `0 6 * * 1` (the backend itself is idempotent per `last_digest_at` within the calendar week, so a duplicate fire is a no-op).

**`src/index.js` `scheduled(event, env, ctx)`** — branch on `event.cron`:
```js
async scheduled(event, env, ctx) {
  if (event.cron === "0 0 1 * *") { /* existing free-scan-reset */ }
  else if (event.cron === "0 6 * * 1") {
    ctx.waitUntil(fetch(`${env.BACKEND_URL}/internal/ai-digest-run`, {
      method: "POST",
      headers: { "x-internal-secret": env.INTERNAL_SECRET },
    }).catch(() => {}));
  }
}
```

**No changes** to: KV schema (no new top-level key), `recordScan` / scan-data shape, `handleQRCode`, any `src/pages/*` template, the consent gate, or pixels. Because there is no new scan page or template, the **worker↔React template mirroring rule does not apply** to this feature — there is nothing to mirror. The scan corpus the AI reads is exactly what `recordScan` already writes (17 fields → `qr_scan_counters` JSONB aggregates); dimensions the worker doesn't capture (browser/OS/UTM) are simply absent from the tool surface, which is why the model is instructed to decline questions about them.

---

## 5. Frontend Design

### 5.1 Gating (`src/lib/plan-features.ts`)
Add `ai_analyst` to the `PlanFeatures` interface (`src/hooks/useSubscription.ts`) and rely on the existing `canAccessFeature(subscription, 'ai_analyst')`. `getLimit(subscription, 'ai_analyst_queries_per_month')` drives the quota meter copy.

### 5.2 Ask panel (`src/app/org/[slug]/(dash)/analytics/page.tsx`)
The analytics page is already `advanced_analytics`-gated. Above the existing chart grid, mount `<AskAnalystPanel />` (new, under `src/components/org/analytics/ask/`):
- `AskAnalystPanel.tsx` — `Card` + `PageHeader`-styled header from `src/components/org/index.ts`; an input (react-hook-form + zod, max 280 chars), three suggested-prompt chips, and a `<AiUsageMeter />` ("X of N AI questions left this month", mirroring `ApiUsageMeter`).
- `AskAnalystResult.tsx` — renders the response: top region = narrative (`react-markdown`, prose-styled with `on-surface` / `on-surface-variant` tokens, no inline styles); bottom region = `<AskChart chart={chart} />`.
- `AskChart.tsx` — a thin switch on `chart.kind` that **reuses the existing chart components** the analytics page already imports (area/days, donut/devices, country bars, hourly bars). No new chart component is built.
- Over-quota / 403 states render an inline `UpgradeGate`-style block (for Free/Starter the whole panel is the gate, turning the buyer-expected capability into a Pro conversion surface).

### 5.3 Hooks (`src/hooks/`)
Follow the domain key-factory + `authApi` convention.

```ts
// useAskAnalyst.ts
export const aiAnalystKeys = {
  all: ['ai-analyst'] as const,
  usage: (wsId: string) => [...aiAnalystKeys.all, 'usage', wsId] as const,
  settings: (wsId: string) => [...aiAnalystKeys.all, 'settings', wsId] as const,
};

export function useAskAnalyst(workspaceId: string) {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: async (question: string) => {
      const { data } = await authApi.post<AskResponse>(
        `/workspaces/${workspaceId}/ai-analyst/ask`, { question });
      return data;
    },
    onSuccess: () => qc.invalidateQueries({ queryKey: aiAnalystKeys.usage(workspaceId) }),
    onError: (e) => toast.error(asErrorMessage(e)),  // 429 → quota toast
  });
}
export function useAiAnalystUsage(workspaceId: string) { /* GET .../usage */ }
export function useAiAnalystSettings(workspaceId: string) { /* GET + PUT settings */ }
```
`workspaceId` is sourced from `useWorkspaceStore((s) => s.currentWorkspace)?.id` per house rule (never URL params). Single-shot Q→A; no thread state in v1.

### 5.4 Wiring the dead "Schedule Weekly Report" button
The existing placeholder button (currently no `onClick`, `analytics/page.tsx` ~line 148) becomes a controlled toggle driven by `useAiAnalystSettings`. ON → `PUT settings {digest_enabled:true}`; recipient defaults to owner. Optimistic update + `invalidateQueries` + `toast`. The sibling "Download CSV/PDF" placeholder is **out of scope** (Open Q4 — separate task).

All components ≤200 lines, kebab-case files, one export each, shadcn primitives, tokens only (`primary` `#4648d4`, `tertiary` cyan, surface hierarchy) per `DESIGN_SYSTEM.md`.

---

## 6. AI / Claude Integration

**Where it runs:** backend only, via the Anthropic Python SDK in `ai_analyst.py`. Never at the edge.

**Model:** `claude-haiku-4-5` for both interactive asks and digests — the task is constrained (fixed tool-driven retrieval + short narrative), so the cheapest capable model protects margin and keeps p95 < 8s. `effort: "low"`, `max_tokens` capped (~1024 for narrative). If a beta eval shows the hallucination-eval failing at Haiku, escalate the **final narration step only** to `claude-sonnet-4-6` (tool calls stay cheap) — a single config constant `AI_ANALYST_MODEL`.

**Prompt caching:** the static system prompt + the nine tool definitions form a stable prefix marked with `cache_control: {type: "ephemeral"}`, so repeat queries pay ~0.1× on the cached portion. Only the user question + tool results vary.

**I/O contract:** request = `{question}`; the loop runs tool turns, then a final turn requests a strict JSON emission (`{narrative, chart}`) which we parse. `usage` from the Anthropic response (`input_tokens`, `output_tokens`, `cache_read_input_tokens`) is fed into `increment_ai_usage` for margin monitoring.

**Grounding / anti-hallucination:** Claude is the narrator, the DB is the source of truth. System prompt: *never compute or invent a number — including deltas and percentages; every figure, raw or derived, must come from a tool result. For any period-over-period change ("up 22% WoW", "up from 74%"), call `get_period_comparison` (deltas are computed in SQL/Python) rather than subtracting two numbers yourself; if data isn't available (e.g. browser/OS/UTM breakdown — not captured), say so and name what is available.* `used_tools` is returned so QA can trace each number → tool, and `chart.data` is backend-attached from a real tool result (never model-authored).

**Fallbacks:** SDK error / timeout → `503 ai_unavailable` with a friendly FE message; the metered increment is **not** refunded on Anthropic failure in v1 (simpler; cap is generous) — flagged in Open Questions. Empty-data workspace → tools return zeros → narrative says "you don't have scan data yet" (no fabricated chart).

---

## 7. API Contracts

**POST** `/api/v1/workspaces/{workspace_id}/ai-analyst/ask`
```jsonc
// Request
{ "question": "Top 5 countries last 30 days, and is mobile growing?" }

// 200 OK
{
  "narrative": "**Scans are up 22% week-over-week.** Your top country last 30 days was India (1,204 scans), followed by the US (388)... 81% of scans were mobile, up from 74% the prior week.",
  "chart": {
    "kind": "geographic",
    "source": "get_scans_by_country#1",      // model picks kind + source; backend attaches .data
    "data": [ { "country_code": "IN", "scans": 1204 }, { "country_code": "US", "scans": 388 } ]
  },
  "used_tools": [
    { "name": "get_scans_by_country",  "args": { "limit": 5 }, "result_digest": "IN:1204,US:388,..." },
    { "name": "get_period_comparison", "args": { "days": 7 }, "result_digest": "total{cur:1592,prior:1305,delta_pct:+22.0}; mobile_share{cur:.81,prior:.74,delta_pct:+9.5}" },
    { "name": "get_scans_by_device",   "args": {}, "result_digest": "mobile:.81,desktop:.16,..." }
  ],
  "usage": { "queries_used": 12, "queries_limit": 50 }
}

// 429 (cap reached) — headers X-RateLimit-Limit/Remaining/Reset
{ "detail": { "code": "ai_quota_exceeded", "limit": 50 } }

// 403 (Free/Starter or downgraded)
{ "detail": { "code": "ai_analyst_locked", "upgrade_to": "pro" } }
```

**GET** `/.../ai-analyst/usage` → `{ "queries_used": 12, "queries_limit": 50, "period_start": "2026-06-01" }`
**PUT** `/.../ai-analyst/settings` → `{ "digest_enabled": true, "digest_recipient": null }` → echoes saved state.
**POST** `/api/v1/internal/ai-digest-run` (x-internal-secret) → `{ "processed": 14, "emailed": 13, "skipped_no_entitlement": 1 }`

---

## 8. Security, Privacy & Abuse

- **Auth:** ask/settings sit under `/api/v1` → Bearer JWT middleware + `require_can_read` (workspace membership). Digest endpoint is `/internal/*` → `verify_internal_secret` only (no Bearer), never browser-reachable.
- **Tenant isolation:** every tool is server-bound to the **path** `workspace_id`; the model never supplies a workspace; `qr_id` tool args are validated to belong to the path workspace. A dedicated cross-workspace scoping test is a release gate.
- **Prompt injection:** tool results carry numbers + short enum labels only; raw lead-submission text is never fed to the model; QR titles are escaped/truncated and treated strictly as data. System prompt instructs the model to never follow instructions embedded in data.
- **Rate limiting / abuse:** hard monthly cap (50 Pro / 300 Agency) via atomic increment-then-check; no unlimited tier; digests draw a separate small budget so a busy chatter can't starve the digest and vice-versa.
- **PII / consent:** server-side only, no new client capture, no cookies/pixels — the EU consent gate at the worker is untouched (Known risk #3 resolved). Aggregates already in the DB are surfaced, not raw PII.
- **Margin/cost abuse:** `max_tokens` cap + low effort + cached prefix bound per-query cost; per-query token usage logged for alarms.

---

## 9. Performance, Scale & Cost

- **Latency:** p95 target < 8s. Tool calls are single-row JSONB reads on `qr_scan_counters` (already indexed by `qr_id`) — sub-50ms each; the loop is ≤6 turns but typically 1–2. Dominant cost is Claude round-trips, bounded by `max_tokens` and Haiku speed.
- **DB load:** negligible — same queries that already serve the analytics page, called a handful of times per ask. Metering uses one atomic RPC (no read-modify-write race), identical to `increment_api_usage`.
- **Cost:** Haiku + `effort: low` + ~1k `max_tokens` + cached system/tool prefix (~0.1× on cached portion). Per-query token spend recorded in `ai_analyst_usage`; alarm if a workspace's monthly token spend exceeds the cap-implied ceiling. Caps are tunable in `plans.features` without a deploy.
- **Digest scale:** the cron endpoint **dispatches** per-workspace background tasks (bounded concurrency) and returns immediately, so it never holds one request across N sequential Claude calls; `last_digest_at`-gated selection makes the weekly run idempotent and resumable. Per-item try/except; one failure never aborts the sweep.

---

## 10. Testing Strategy

**Backend (pytest, `qr_backend/tests/`):**
- `test_ai_analyst_gate`: Free/Starter → 403; Pro without `ai_analyst` flag (pre-flip) → 403; downgrade mid-month → 403.
- `test_ai_analyst_meter`: 50th query OK, 51st → 429 with `X-RateLimit-*` headers; digest budget independent of query budget.
- `test_ai_analyst_tool_scoping`: a tool call can only read the path workspace; cross-workspace `qr_id` → 400 (release-blocking).
- `test_ai_analyst_plumbing` (stubbed Anthropic client): the tool loop dispatches to the right readers; `chart.data` is **backend-attached** from the named `source` call (model-emitted chart numbers are ignored); an unknown/absent `source` drops the chart instead of fabricating one. A stub proves plumbing, **not** grounding.
- `test_ai_analyst_delta_grounding`: every delta/percentage in the narrative originates from a `get_period_comparison` result, never from model arithmetic over two separate calls (asserted against recorded-response fixtures).
- **AI grounding eval — separate release gate, NOT a stubbed unit test:** a 200-question suite run against **recorded real Claude responses** (or a live key in a nightly/manual job; never CI-blocking with a stub, since a stub cannot exhibit hallucination), asserting every stated number traces to a real tool result. **0 hallucinations is the release blocker.**
- `test_ai_analyst_empty_workspace`: zero scans → "no data yet", no chart fabrication.
- `test_ai_digest_run`: enrolled+entitled → emailed (Resend mocked); unenrolled/unentitled → skipped; `last_digest_at` updated.
- `test_scan_readers_refactor`: existing analytics endpoint tests stay green (proves the §3.1 extraction is behavior-preserving).
- **`test_feature_gate_coverage`** must stay green after the `inert→enforced` flip and the 0014 seed.
- Anthropic SDK is mocked in all unit tests (no live calls in CI).

**Frontend (Vitest + Playwright):** `useAskAnalyst` mutation success/429/403 with mocked `authApi`; `AskChart` routes each `chart.kind` to the right component; digest toggle PUT + optimistic update; Free user sees the gate. Note the **~29 pre-existing FE test failures** baseline — only net-new failures in AI-analyst files are regressions.

**Worker (`qr_cf_code` tests):** `scheduled()` dispatches `0 6 * * 1` to `/internal/ai-digest-run` with `x-internal-secret` and does not disturb the existing `0 0 1 * *` branch.

---

## 11. Observability & Rollout

- **Phase 0 (dark launch):** apply migration 0014; register `ai_analyst` `inert` in `FEATURE_ENFORCEMENT`; ship the ask endpoint behind the flag, no UI; internal testing on a seeded Pro workspace; provision `ANTHROPIC_API_KEY` per env.
- **Phase 1 (closed beta):** ship the Ask panel + tool surface + metering; **flip `ai_analyst` `inert→enforced` in this PR** (coverage test green); run the 200-question hallucination eval (release blocker); enable for hand-picked Pro/Agency workspaces. *Acceptance:* "top 5 countries last 30 days" → country bar chart from the existing geographic component + narrative whose every number matches `get_scans_by_country`; 51st query → 429; Free → gate (no endpoint access); browser-breakdown question → model declines; cross-workspace data unreachable.
- **Phase 2 (GA + digest):** wire the toggle, the `ai-digest-run` endpoint, and the cron (dev+prod `wrangler.toml`); roll out to all Pro/Agency; add the AI line to the pricing page + `/docs`. **Deploy order:** backend (endpoint + migration applied) → frontend → worker cron last (so the cron never hits a missing endpoint).
- **Phase 3 (future):** streaming, multi-turn, Slack digest, agency cross-workspace roll-up.
- **Metrics:** activation (≥35% Pro+ ask ≥1 in 30d), median ≥4 asks/active ws/mo, digest enroll ≥25% + open ≥40%, p95 < 8s, **0 hallucination incidents**, 0 cap breaches without a 429. Token spend per workspace dashboarded off `ai_analyst_usage`; structured logs on every ask (`workspace_id`, `used_tools` count, token usage, latency).

---

## 12. Open Technical Questions & Risks

1. **Digest budget vs interactive budget** — resolved: separate (`ai_digest_runs_per_month`), so a chatty user never starves the digest. Confirm `5/mo` is adequate for monthly-anchored billing (weekly digest ≈ 4–5 runs).
2. **Model choice** — start `claude-haiku-4-5`; escalate only the narration step to `claude-sonnet-4-6` if the eval fails. Validate cost/quality in beta (Open Q2).
3. **Failed-call refund** — v1 does **not** refund the metered increment on an Anthropic error. Low harm given generous caps; revisit if beta shows error-rate spikes burning quota.
4. **Cap values (50/300)** — validate against beta token-cost data before GA; tunable in `plans.features` without deploy.
5. **Digest recipient** — owner-only in v1 (Open Q3); configurable list is future.
6. **"Download CSV/PDF" placeholder** — explicitly out of scope (Open Q4); separate task on the same page.
7. **Risk — coverage test parity:** the `0014` seed must add all three keys (`ai_analyst`, `ai_analyst_queries_per_month`, `ai_digest_runs_per_month`) on every public plan or `test_feature_gate_coverage` breaks; the registry only lists `ai_analyst` (the two limits are caps, not gates — confirm the coverage test's column/limit exclusions, like `COLUMN_FEATURES`, cover them or add them to the registry as enforced limits).
8. **Risk — `period_start_iso` anchoring:** metering windows to the billing anchor (not calendar month) — verify the digest cron's weekly cadence reconciles cleanly with the monthly metering window at month boundaries.
