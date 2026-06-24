# TRD — AI Business-Card OCR → vCard Import

**Status:** Draft · **Author:** Engineering (Staff) · **Date:** 2026-06-24
**Priority:** Activation delighter on the flagship `vcard` type — a metered AI accelerator that shortens time-to-first-vCard. Not a moat; a conversion lubricant.
**Tiers:** **Starter, Pro, Agency** (`card_ocr` flag) + optional **Free hook**; metered per-workspace-per-month via `card_ocr_scans_per_month`.
**Plan flags (NEW):** `card_ocr` (bool) + `card_ocr_scans_per_month` (int). Registered `inert` in `FEATURE_ENFORCEMENT` then flipped `enforced` in the **same PR** (house convention; `test_feature_gate_coverage` stays green).
**Migration slot:** **0024** (`0024_ai_business_card_ocr.sql`). Current highest applied = `0013`; roadmap reserves `0014–0018`; `0024` is the instructed slot for this backlog item.
**Services touched:** `qr_backend` only (new metered endpoint, AI helper, migration). `qr_frontend` (scan control on the vCard builder + hook). **`qr_cf_code` — no change** (no KV, no new QR type, no template, no cron, no scan-path touch).
**Implements PRD:** AI Business-Card OCR → vCard Import. **Mirrors** the metering/usage-table design of AI_SCAN_ANALYST (`ai_analyst_usage`, `increment_ai_usage` RPC).

**Rev (2026-06-24, post eng-review):** Scope accepted as boring-by-default (one backend endpoint + one FE control + minimal `0024`; no Worker, correctly). Applied fixes: (1) **`0024` seed now writes a full-object `'{...}'::jsonb` blob** for both keys — verified that `test_feature_gate_coverage._seed_feature_keys()` only regex-discovers `'{...}'::jsonb` blobs, so the prior path-only `jsonb_set` seed would have failed both keys as "stale" (`api_access`/`retargeting_pixels` reach the seed set via the `0009` blob, not their own migrations); (2) **resolved the §3.1/§Open-Q5 metering contradiction** — increment-then-check (the `api_public.py` pattern, verified) is the ONE authoritative path; the abandoned "pre-count SELECT for the 429 short-circuit" is deleted because it reintroduces the RMW race the atomic RPC removes; tokens are folded by a **second** idempotent RPC after extraction (`add_card_ocr_tokens`, no second increment of `scans_used`); (3) **refund/decrement made idempotent + floored at 0** (`GREATEST(scans_used-1,0)`) so a retried refund can't underflow; (4) added a **Pillow decompression-bomb guard** (`MAX_IMAGE_PIXELS`, decode in try/except → 415, re-validate decoded format — don't trust client `content_type`); (5) `_QUOTA_SPEC` entry for `card_ocr_scans_per_month` set `usage=None` (value-only; usage lives in our own counter, like `api_calls_per_month`); (6) v1.1 `GET .../usage` windows by `period_start_iso` to match enforcement. Migration stays `0024`, schema unchanged otherwise.

---

## 1. Overview & Architecture

A user building a vCard QR can snap or upload a photo of a paper business card. The image is POSTed to **one new metered backend endpoint**, downscaled server-side, and sent to **`claude-haiku-4-5`** (vision) with a strict JSON-extraction prompt. Claude returns the exact field set of the existing `VcardContent` Pydantic model. The backend validates every value, returns the matched fields, and the frontend **pre-fills the existing vCard form**. The user reviews/edits every field before saving through the normal wizard. **No QR is auto-created from OCR output** — confirm-before-save is a hard invariant.

The feature is overwhelmingly a **backend** change. The frontend adds one shadcn control + a TanStack mutation hook. **The Cloudflare Worker is untouched** — AI runs backend-side at request time, never on the scan hot path, so the edge consent posture and KV model are unchanged.

**Services touched**

| Service | Change |
|---|---|
| `qr_backend` | New router `vcard_ocr.py` (`POST /workspaces/{id}/vcard/ocr`), AI helper `utilities/card_ocr.py` (downscale + vision call + strict-JSON prompt + output validation), migration `0024` (`card_ocr_usage` + `increment_card_ocr_usage` RPC + flag/limit flip), `card_ocr` in `FEATURE_ENFORCEMENT` (`inert`→`enforced`), `ANTHROPIC_API_KEY` read via `settings`, `Pillow` + `anthropic` in `requirements.txt`. |
| `qr_frontend` | "Scan a business card" control + pre-fill banner on `VCardContent.tsx`; `useCardOcr` mutation hook; `card_ocr` + `card_ocr_scans_per_month` in `PlanFeatures`; upgrade chip for non-entitled. |
| `qr_cf_code` | **No change.** No new QR type, no `build_kv_content` branch, no template, no cron, no `recordScan` change. The worker↔React template-mirroring rule does not apply (nothing to mirror). |

**Data flow — OCR extraction**

```
FE VCardContent scan control (camera/upload)
  → client validates size/type (≤5MB, image/*)
  → useCardOcr → authApi.post(/workspaces/{id}/vcard/ocr, multipart image)
  → BearerTokenAuthMiddleware (attaches user_id)
  → get_workspace_role(workspace_id) → require_can_create (editor+)
  → vcard_ocr.py:
      1. await check_feature(ws, 'card_ocr', db)            [403 if false]
      2. read image bytes; reject >5MB / non-image (413/415)
      3. downscale (longest edge ≤1568px) in-memory via Pillow → JPEG base64
      4. increment_card_ocr_usage(ws, period) RPC → if > cap → 429 (RateLimit-* headers)
      5. claude-haiku-4-5 vision call (strict JSON, max_tokens capped) → raw fields
      6. validate/normalize each field against VcardContent (email regex, drop malformed)
      7. discard image bytes; return {fields, used, limit}
  → onSuccess: react-hook-form setValue() pre-fills matched fields
  → "Pre-filled from your card — please review" banner; user edits → normal save
```

The image is processed in-memory and **discarded**; only the scan **count** (and optional token usage) is persisted — never the image, never the extracted PII.

---

## 2. Data Model & Migrations

A migration **is** required (the flag/limit flip alone mandates one; "No migration required" is not an option). Per house rule we ship **only this phase's schema**: the `card_ocr` flag + `card_ocr_scans_per_month` limit seed/flip, and a tiny `card_ocr_usage` counter table mirroring `ai_analyst_usage` / `api_usage`. We choose a per-period table over a JSONB-on-workspace counter for clean monthly windows and per-period rows for margin reporting (same rationale AI_SCAN_ANALYST used).

**RLS note:** the backend uses the Supabase **service-role** REST client, which **bypasses RLS**. We `ENABLE ROW LEVEL SECURITY` with **no policies** so the anon/auth roles (never used here, but defense-in-depth) can never read the counter; only the service key touches it. Tenant isolation is enforced in code via explicit `workspace_id` filters, never RLS.

**`qr_backend/migrations/0024_ai_business_card_ocr.sql`** — BEGIN/COMMIT-wrapped, idempotent, applied by hand in the Supabase SQL editor.

```sql
BEGIN;

-- ── Monthly OCR-scan counter (mirrors api_usage / ai_analyst_usage shape) ──
-- Windowed by subscription.period_start_iso (billing anchor for paid, calendar
-- month for Free). One row per (workspace, period_start); created lazily.
CREATE TABLE IF NOT EXISTS card_ocr_usage (
    workspace_id  uuid        NOT NULL REFERENCES workspaces(id) ON DELETE CASCADE,
    period_start  date        NOT NULL,
    scans_used    integer     NOT NULL DEFAULT 0,
    tokens_used   bigint      NOT NULL DEFAULT 0,   -- margin monitoring (input+output)
    updated_at    timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (workspace_id, period_start)
);

ALTER TABLE card_ocr_usage ENABLE ROW LEVEL SECURITY;
-- No policies → only the service role (bypasses RLS) can read/write.

-- ── Atomic scan increment (mirrors increment_api_usage RPC) ──
-- Single upsert returns the NEW count so the caller compares to the cap in one
-- round-trip; `scans_used = scans_used + 1` in the DB avoids read-modify-write races.
-- p_tokens defaults 0 (tokens are unknown at increment time — they're added AFTER
-- extraction via add_card_ocr_tokens; the param is kept for the api_usage-shape
-- parity and one-call test fixtures, but the route passes the default).
CREATE OR REPLACE FUNCTION increment_card_ocr_usage(
    p_workspace_id uuid,
    p_period_start date,
    p_tokens       bigint DEFAULT 0
)
RETURNS integer
LANGUAGE plpgsql
AS $$
DECLARE
    new_count integer;
BEGIN
    INSERT INTO card_ocr_usage (workspace_id, period_start, scans_used, tokens_used, updated_at)
    VALUES (p_workspace_id, p_period_start, 1, p_tokens, now())
    ON CONFLICT (workspace_id, period_start)
    DO UPDATE SET scans_used  = card_ocr_usage.scans_used + 1,
                  tokens_used = card_ocr_usage.tokens_used + EXCLUDED.tokens_used,
                  updated_at  = now()
    RETURNING scans_used INTO new_count;
    RETURN new_count;
END;
$$;

-- ── Compensating refund on a clean model failure (idempotent, floored at 0) ──
-- Called ONLY when Claude returns no usable JSON / the call errors, so a refused
-- scan doesn't burn the user's quota. GREATEST(...,0) prevents underflow under a
-- retried/duplicated refund; no-op if the period row somehow doesn't exist.
CREATE OR REPLACE FUNCTION refund_card_ocr_usage(
    p_workspace_id uuid,
    p_period_start date
)
RETURNS void
LANGUAGE plpgsql
AS $$
BEGIN
    UPDATE card_ocr_usage
       SET scans_used = GREATEST(scans_used - 1, 0),
           updated_at = now()
     WHERE workspace_id = p_workspace_id
       AND period_start = p_period_start;
END;
$$;

-- ── Token accounting, separate from the scan increment (margin monitoring) ──
-- Folded in AFTER a successful extraction so we never double-increment scans_used.
CREATE OR REPLACE FUNCTION add_card_ocr_tokens(
    p_workspace_id uuid,
    p_period_start date,
    p_tokens       bigint
)
RETURNS void
LANGUAGE plpgsql
AS $$
BEGIN
    UPDATE card_ocr_usage
       SET tokens_used = tokens_used + p_tokens,
           updated_at  = now()
     WHERE workspace_id = p_workspace_id
       AND period_start = p_period_start;
END;
$$;

-- ── Flag + limit seed/flip (HOUSE CONVENTION: lower(name) + is_custom guard) ──
-- 1) Seed BOTH keys as a full-object '{...}'::jsonb BLOB where absent, non-custom only.
--    MUST be a blob (not path-only jsonb_set): test_feature_gate_coverage's
--    _seed_feature_keys() discovers feature keys ONLY by regex-scanning '{...}'::jsonb
--    blobs (verified) — a path-only seed leaves both keys undiscovered and the coverage
--    test fails them as "stale". `features || blob` writes only the (absent) new keys;
--    the NOT(... ? 'card_ocr') guard keeps it idempotent / non-clobbering.
UPDATE plans
SET features = coalesce(features,'{}'::jsonb)
             || '{"card_ocr":false,"card_ocr_scans_per_month":0}'::jsonb
WHERE NOT (coalesce(features,'{}'::jsonb) ? 'card_ocr')
  AND coalesce(is_custom,false) = false;

-- 3) Enable + set per-tier caps for the paid tiers.
UPDATE plans
SET features = jsonb_set(
        jsonb_set(coalesce(features,'{}'::jsonb), '{card_ocr}', 'true'::jsonb, true),
        '{card_ocr_scans_per_month}', '25'::jsonb, true)
WHERE lower(name) = 'starter' AND coalesce(is_custom,false) = false;

UPDATE plans
SET features = jsonb_set(
        jsonb_set(coalesce(features,'{}'::jsonb), '{card_ocr}', 'true'::jsonb, true),
        '{card_ocr_scans_per_month}', '100'::jsonb, true)
WHERE lower(name) = 'pro' AND coalesce(is_custom,false) = false;

UPDATE plans
SET features = jsonb_set(
        jsonb_set(coalesce(features,'{}'::jsonb), '{card_ocr}', 'true'::jsonb, true),
        '{card_ocr_scans_per_month}', '500'::jsonb, true)
WHERE lower(name) = 'agency' AND coalesce(is_custom,false) = false;

-- Free hook: launch OFF (card_ocr=false, cap stays 0). Enable post-telemetry by
-- re-running steps (3)-style for lower(name)='free' with cap '1'. (PRD §8/Open Q2.)

COMMIT;

-- Sanity (after COMMIT):
--   SELECT name, features->'card_ocr', features->'card_ocr_scans_per_month'
--     FROM plans WHERE coalesce(is_custom,false)=false ORDER BY price_monthly;
```

Why `lower(name)` + `coalesce(is_custom,false)=false` + `coalesce(features,'{}')`: a bare `WHERE name IN ('Starter',...)` is case-sensitive, touches custom plans, and nulls NULL `features` — three bugs prior specs hit. `-1`/unlimited is **not** offered on any tier (margin protection).

No change to `qr_codes`, `qr_vcard_details`, `qr_scan_events`, or `qr_scan_counters` — OCR never persists a QR; that happens only through the existing vCard create path when the user saves.

---

## 3. Backend Design

### 3.1 New router — `qr_backend/src/api/routes/vcard_ocr.py`
Registered in `endpoints.py` under the standard JWT prefix (`router.include_router(vcard_ocr_router)`), so `BearerTokenAuthMiddleware` runs and `get_current_user_id` is populated from `request.state`.

```
POST /api/v1/workspaces/{workspace_id}/vcard/ocr     # multipart image → matched vCard fields
GET  /api/v1/workspaces/{workspace_id}/vcard/ocr/usage  # quota meter (optional, v1.1 read-out)
```

The endpoint accepts `image: UploadFile = File(...)` (mirrors `storage.py:upload_avatar`), depends on `member = Depends(require_can_create)` (editor+, since this feeds QR creation — PRD Open Q4 resolved yes), `user_id = Depends(get_current_user_id)`, `db = Depends(get_supabase)`. `require_can_create` resolves `get_workspace_role(workspace_id)`, which already enforces workspace membership and validates the UUID — that is our tenant-isolation boundary.

**Gating** (top of handler, before any AI cost is incurred):
```python
if not await check_feature(workspace_id, "card_ocr", db):   # check_feature is ASYNC — await it
    raise HTTPException(403, detail={"code": "card_ocr_locked", "upgrade_to": "starter"})
```
`check_feature` reads the resolved plan (`resolve_plan`, 30s cache), so a mid-month downgrade flips this to 403 on the next call — identical to `api_public.py`. It fails closed (returns `False`) on any resolve error.

**Validation + metering order** (fail-closed, cost-protected):
1. Reject `content_type not in ("image/jpeg","image/png","image/webp")` → 415; `len(content) > 5*1024*1024` → 413 (mirrors `upload_avatar`). The client `content_type` is **advisory only** — the authoritative format check happens in `downscale()` against the *decoded* image (§3.2), which also enforces the decompression-bomb pixel ceiling and maps any decode failure to 415 (never 500).
2. `quota = get_limit(workspace_id, db, "card_ocr_scans_per_month")` (reads `features.card_ocr_scans_per_month`; missing key → 0, fail-closed). If `quota == 0` → 403 (Free hook off). 
3. `period = period_start_iso(resolve_plan(...))[:10]`; **increment-then-check** atomically:
   ```python
   count = db.rpc("increment_card_ocr_usage",
                  {"p_workspace_id": ws, "p_period_start": period}).execute().data
   if quota != -1 and count > quota:
       raise HTTPException(429, headers={"X-RateLimit-Limit": str(quota),
                           "X-RateLimit-Remaining": "0", "X-RateLimit-Reset": str(reset_epoch)},
                           detail={"code": "card_ocr_quota_exceeded", "limit": quota})
   ```
   Increment-then-check (the `api_public.py` pattern) means concurrent uploads can't exceed the cap.

   **Open Q1 (count successful vs every invocation):** we **increment before** the Claude call so a concurrent flood can't blow margin, but on a **clean Claude failure** (no usable JSON, garbage image) we **decrement once via a compensating RPC call** so the user isn't charged quota for a model refusal — PRD recommendation "count successful invocations." A genuine extraction (any field returned) keeps the increment. The image-cost is still bounded because the increment gates concurrency.

4. Call `card_ocr.extract_vcard_fields(image_bytes, content_type)` (§3.2). The scan was **already** counted atomically in step 3 (increment-then-check) — that is the single authoritative gate and we do **not** also do a "pre-count `SELECT`" (it would reintroduce exactly the read-modify-write race the atomic RPC removes). Branch on the outcome:
   - **Success** (any field extracted): fold token usage in with a **separate** `add_card_ocr_tokens(ws, period, p_tokens)` RPC (does **not** touch `scans_used`, so no double-increment). Accurate token accounting, the scan count already correct.
   - **Clean model failure** (`CardOcrError`: no usable JSON / garbage image) or 503 (no key / SDK error): call `refund_card_ocr_usage(ws, period)` — idempotent and floored at 0 (`GREATEST(scans_used-1,0)`), so a retried refund can't underflow — then raise `422`/`503`. The user isn't charged quota for a model refusal (PRD Open Q1).

5. Return `{fields, used: count, limit: quota}`; the image bytes are dropped (no persistence, no Supabase Storage write).

### 3.2 AI helper — `qr_backend/src/utilities/card_ocr.py`
A single pure module (no HTTP), so the route stays thin and the AI call is unit-testable with a mocked SDK.

```python
def downscale(image_bytes: bytes, content_type: str) -> tuple[bytes, str]:
    """Pillow: cap longest edge at 1568px (Anthropic vision best practice),
    re-encode JPEG q85. Bounds vision-token cost regardless of source resolution.

    Decompression-bomb / decode guard (the 5 MB byte cap does NOT bound decoded
    pixels — a tiny PNG can decode to gigapixels and OOM): set
    Image.MAX_IMAGE_PIXELS (~40 MP) and wrap Image.open(...).load() in try/except
    → raise a CardOcrInputError the route maps to 415 (never 500). Re-validate the
    DECODED format against {JPEG, PNG, WEBP} — do not trust the client content_type."""

async def extract_vcard_fields(image_bytes: bytes, content_type: str) -> dict:
    """Downscale → claude-haiku-4-5 vision call with a strict JSON-schema prompt →
    parse → validate/normalize against the VcardContent field set → return matched
    fields + usage. Raises CardOcrError on no-usable-JSON (caller refunds quota)."""
```

The validated output uses exactly the `VcardContent` keys (§ Appendix): `first_name, last_name, company, job_title, phone, email, street_address, website, city, country, bio, zip_code, state`. Server-side validation: email via regex (drop if invalid), website coerced to a URL or dropped, phone light-normalized (strip non-dialing chars, keep `+`), all strings trimmed and length-capped, `bio` ≤500. **Any field the model is unsure about must be `null`** (prompt instruction) and `null`/malformed values are simply omitted — we never guess (PRD R2). Unknown keys returned by the model are discarded (prompt-injection guard, PRD R4).

`ANTHROPIC_API_KEY` is read via `settings` (`src/config/manager.py` → environment settings classes). If unset, `extract_vcard_fields` raises and the route returns `503 {"code":"card_ocr_unavailable"}` (never 500s a user) — the quota increment is refunded.

### 3.3 Gating registry (`subscription.py`)
Add to `FEATURE_ENFORCEMENT`:
```python
"card_ocr": "enforced",                 # vcard_ocr.py POST check_feature gate
"card_ocr_scans_per_month": "enforced", # vcard_ocr.py metering via get_limit + increment_card_ocr_usage RPC
```
Both keys are seeded on **every** non-custom plan by `0024`, so `test_registry_matches_plan_seed` stays green (the test diffs seed JSONB keys against the registry). The limit key is a cap, not a behavioral gate, but it is enforced (quota), so `enforced` is correct and a source reference (`card_ocr_scans_per_month` in `vcard_ocr.py`) satisfies the "real gate exists" assertion. Registering `inert` first then flipping to `enforced` **in this same PR** keeps the house convention.

`get_limit` and `_limit_value` already handle a `features`-source key; we add `card_ocr_scans_per_month` to `_QUOTA_SPEC` as `{"source": "feature", "usage": None}` (value-only, exactly like `max_file_size_mb`). We deliberately set `usage=None` rather than wiring a `check_limit` usage fn: usage is read from our own `card_ocr_usage` counter via the atomic RPC at request time (the `api_usage` pattern), never through the generic `check_limit` path. `_limit_value` then fail-closes a missing key to `0`.

### 3.4 KV / entitlements / internal endpoints
**None.** We do **not** thread `card_ocr` into `build_entitlements` — that snapshot governs per-QR worker rendering (`white_labeling`, `ab_testing`, `brand`); OCR never renders at the edge, so adding it would be dead weight. No `build_kv_content` branch, no `write_to_kv` change, no `/internal/*` endpoint, no `x-internal-secret` consumer. This is a deliberate, documented divergence — gating is entirely backend-side.

---

## 4. Cloudflare Worker / Edge Design

**No worker change.** This feature adds no QR type, no KV top-level key, no `src/pages/*` template, no `handlers/` dispatch case, no `recordScan` field, no consent-gate change, and no `scheduled()` cron. Because there is no new scan page or template, the **worker↔React template-mirroring house rule does not apply** (nothing to mirror). Consequently **no `npm run deploy:prod` gate** applies — the prod-worker-deploy step that new crons require is not triggered here. The edge scan hot path is byte-for-byte unchanged; AI runs only backend-side at request time.

---

## 5. Frontend Design

### 5.1 Gating (`src/lib/plan-features.ts`, `src/hooks/useSubscription.ts`)
Extend the `PlanFeatures` interface:
```ts
card_ocr: boolean;                 // Starter+ business-card OCR
card_ocr_scans_per_month: number;  // -1 unlimited (not offered); 0 = none
```
Add `'card_ocr_scans_per_month'` to the `getLimit` key union. Entitlement check is the existing `canAccessFeature(subscription, 'card_ocr')` (fail-open false when loading/inactive — correct: a non-entitled user simply sees the upgrade chip, never the control).

### 5.2 Scan control on `VCardContent.tsx`
At the top of the existing vCard form (`build/page.tsx` Step 1 content), render a new `<CardScanControl />` extracted into `src/components/qr-generator/content-types/card-scan-control.tsx` (the file is already 355 lines — adding inline would breach the 200-line limit, so the control is its own kebab-case, one-export component):
- **Entitled:** shadcn `Button` (`variant` styled with the `primary` indigo `#4648d4` token — no raw `<button>`, no inline styles) labeled "Scan a business card", wrapping a hidden `<input type="file" accept="image/*" capture="environment" />` (camera on mobile). On pick: client-validate (`>5MB` or non-image → toast), show a spinner, call `useCardOcr`.
- **Non-entitled:** a compact upgrade **chip** ("Scan a card — Starter") linking to billing, mirroring other gated builder affordances. Rendered via `canAccessFeature(subscription,'card_ocr')`.

On success, the parent calls react-hook-form `setValue(field, val, { shouldDirty:true })` for each matched field (or `reset({...current, ...fields})`), and shows a dismissable **"Pre-filled from your card — please review"** banner above the form (shadcn `Alert`, `tertiary` cyan accent, `on-surface-variant` text). **No QR is created** — the user proceeds through the normal wizard. Unmatched fields stay blank (we never guess). Quota-exhausted → inline "You've used all N card scans this month — upgrade for more" using the existing upgrade-gate pattern; extraction failure → "Couldn't read that card — try a clearer photo or enter details manually", form untouched.

### 5.3 Hook (`src/hooks/useCardOcr.ts`)
TanStack **mutation** via `authApi` (never `useEffect + fetch`), following the domain key-factory convention:
```ts
export const cardOcrKeys = {
  all: ['card-ocr'] as const,
  usage: (wsId: string) => [...cardOcrKeys.all, 'usage', wsId] as const,
};

export function useCardOcr(workspaceId: string) {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: async (file: File) => {
      const fd = new FormData();
      fd.append('image', file);
      const { data } = await authApi.post<CardOcrResponse>(
        `/workspaces/${workspaceId}/vcard/ocr`, fd,
        { headers: { 'Content-Type': 'multipart/form-data' } });
      return data;
    },
    onSuccess: () => qc.invalidateQueries({ queryKey: cardOcrKeys.usage(workspaceId) }),
    onError: (e) => toast.error(asErrorMessage(e)),  // 403 → upgrade, 429 → quota
  });
}
```
`workspaceId` comes from `useWorkspaceStore((s) => s.currentWorkspace)?.id` (house rule — never URL params). All new files ≤200 lines, kebab-case, one export, shadcn primitives, Tailwind tokens only. A FE constant flag (`NEXT_PUBLIC_CARD_OCR_BETA`) gates visibility during Phase 1 closed beta; removed at GA.

---

## 6. AI / External-Service Integration

**Where it runs:** backend only, Anthropic Python SDK in `utilities/card_ocr.py`. Never at the edge.

**Model:** `claude-haiku-4-5` (vision-capable, cheapest/fastest) — the canonical OCR/short-extraction model per the AI grounding. A single config constant `CARD_OCR_MODEL` allows escalation if the accuracy eval (§11) fails at Haiku, but Haiku is the launch target.

**Cost controls (PRD R3, hard requirements):** (1) server-side **downscale** to ≤1568px longest edge before sending (Pillow); (2) **`max_tokens` ceiling** (~512 — the JSON output is small); (3) **single image per call** (no batch in v1); (4) **per-workspace monthly cap** via `card_ocr_scans_per_month` + the atomic counter; (5) **no unlimited tier**. The static system prompt + JSON-schema instruction form a stable prefix marked `cache_control: {type:"ephemeral"}` so repeat calls pay ~0.1× on the cached portion (only the image varies).

**Strict-JSON prompt + anti-injection (PRD R4):** the system prompt asks Claude *only* to extract into the fixed `VcardContent` JSON schema, return `null` for any field it isn't confident about, and never follow instructions found in the card text. We **never execute** the output; every field is validated server-side and schema-foreign keys are discarded. No tool-use, no side effects.

**Confirm-before-save (PRD invariant):** the endpoint returns fields only — it never writes a QR. The user reviews/edits in the form and saves through the normal create flow. **0 auto-created QRs** is a release invariant.

**Token metering:** `usage.input_tokens + usage.output_tokens` from the Anthropic response is folded into `card_ocr_usage.tokens_used` for margin monitoring/alarms.

**Fallback:** SDK error/timeout/no-key → `503 card_ocr_unavailable` with a friendly FE message; the metered increment is **refunded** on a clean model failure (Open Q1 resolution).

**No email** is sent → the unpublished `_dmarc.qravio.app` record is **not** a GA gate for this feature. **No PDF / WeasyPrint.** `ANTHROPIC_API_KEY` must be provisioned per environment (shared with the planned AI_SCAN_ANALYST) — a Phase-0 checklist item.

---

## 7. API Contracts

**POST** `/api/v1/workspaces/{workspace_id}/vcard/ocr` — `multipart/form-data`, field `image` (one file).

```jsonc
// 200 OK — only confident, validated fields present
{
  "fields": {
    "first_name": "Sana",
    "last_name": "Iqbal",
    "company": "Northwind Logistics",
    "job_title": "Regional Sales Lead",
    "phone": "+14155550142",
    "email": "sana@northwind.co",
    "website": "https://northwind.co",
    "city": "San Francisco",
    "country": "USA"
    // state/zip_code/street_address/bio omitted — not confidently read
  },
  "used": 8,
  "limit": 25
}

// 403 — not entitled (Free with hook off, or downgraded)
{ "detail": { "code": "card_ocr_locked", "upgrade_to": "starter" } }

// 429 — monthly cap reached (headers: X-RateLimit-Limit/Remaining/Reset)
{ "detail": { "code": "card_ocr_quota_exceeded", "limit": 25 } }

// 413 image too large · 415 unsupported type
{ "detail": "Image must be under 5 MB." }

// 422 — Claude returned no usable JSON (quota refunded)
{ "detail": { "code": "card_ocr_unreadable" } }

// 503 — ANTHROPIC_API_KEY unset / SDK error (quota refunded)
{ "detail": { "code": "card_ocr_unavailable" } }
```

**GET** `/.../vcard/ocr/usage` → `{ "scans_used": 8, "limit": 25, "period_start": "2026-06-01" }` (v1.1 usage read-out). **`period_start` is `period_start_iso(resolve_plan(...))[:10]`** (the billing-anchor window the POST increments against — NOT a naive calendar month), so the read-out matches enforcement exactly. Reads the same `card_ocr_usage` row by `(workspace_id, period_start)`; missing row → `scans_used: 0`.

---

## 8. Security, Privacy & Abuse

- **Auth:** endpoint sits under `/api/v1` → Bearer JWT middleware + `require_can_create` (editor+ membership). Not in `excluded_routes`; not an `/internal/*` route; no `x-internal-secret`.
- **Tenant isolation:** `get_workspace_role(workspace_id)` validates membership and the UUID; all DB writes (`card_ocr_usage`) carry an explicit `workspace_id` filter because the service-role client **bypasses RLS**. The model receives no workspace identifier and writes nothing.
- **No SSRF surface:** the only outbound call is to Anthropic with our key — no user-supplied URL is fetched (the card `website` field is data we return, never a server-side request).
- **Prompt injection (R4):** extract-into-fixed-schema only; output validated and schema-foreign keys discarded; never executed; no tool-use.
- **PII retention (R5):** image processed **in-memory and discarded** — no Supabase Storage write, no DB row holds the image or extracted fields. `card_ocr_usage` stores **only** `scans_used` + `tokens_used` (non-identifying). Extracted fields live transiently in the user's form until *they* save (then it's their normal vCard under existing data handling). This counter is **non-PII**, satisfying the strict-non-PII bar for any persisted surface.
- **Abuse / cost (R7):** Bearer-required, workspace-scoped, per-workspace-per-month cap via atomic increment-then-check; the Free hook launches at `0` (off) and is enabled only after watching cost telemetry.
- **Consent gate:** unaffected — no scan-side marketing tags, no edge inference, no new client capture.

---

## 9. Performance, Scale & Cost

- **Latency:** p95 target **< 4s** for one card. Downscale is a single in-memory Pillow op (~tens of ms); the dominant cost is one synchronous Haiku vision round-trip, bounded by the ≤1568px image and ~512 `max_tokens`.
- **DB load:** negligible — one atomic `increment_card_ocr_usage` RPC (no read-modify-write race) plus one `resolve_plan` (30s-cached). No scan-table writes.
- **Cost:** Haiku vision + downscaled image + capped `max_tokens` + cached system/schema prefix (~0.1× cached portion). Per-call tokens recorded in `card_ocr_usage.tokens_used`; alarm if a workspace's monthly token spend exceeds the cap-implied ceiling. Caps are tunable in `plans.features` without a deploy.
- **Scale:** strictly request-driven (one call per user action), capped per workspace — no fan-out, no background jobs, no cron. The cap is the throttle.

---

## 10. Testing Strategy

**Backend (pytest, `qr_backend/tests/`):**
- `test_card_ocr_gate`: Free (hook off) → 403; Starter without flag (pre-flip) → 403; entitled Starter → 200; mid-month downgrade → 403 on next call.
- `test_card_ocr_meter`: 25th scan OK, 26th → 429 with `X-RateLimit-*` headers; the increment is atomic (concurrent calls can't exceed the cap).
- `test_card_ocr_validation`: `>5MB` → 413; `text/plain` → 415; a PNG whose `content_type` lies (e.g. `.png` bytes sent as `image/jpeg`) is accepted by decoded-format check; a decompression-bomb / >`MAX_IMAGE_PIXELS` image → 415 (not 500); a non-decodable blob → 415; downscale produces ≤1568px JPEG.
- `test_card_ocr_refund`: a `CardOcrError` after the increment calls `refund_card_ocr_usage` exactly once; a **double** refund (simulated retry) floors `scans_used` at 0 (never negative).
- `test_card_ocr_extraction` (Anthropic SDK **mocked**): a fixture model response maps to validated `VcardContent` keys; a malformed email is dropped; schema-foreign keys are discarded; a `null`-only response yields `{}` and **refunds** the quota.
- `test_card_ocr_no_persistence`: no Supabase Storage call, no `qr_*` row written — only `card_ocr_usage` mutated.
- **`test_feature_gate_coverage`** stays green after the `inert→enforced` flip and the `0024` seed (both keys classified + referenced in `vcard_ocr.py`).
- **Accuracy eval — separate release gate (NOT a stubbed unit test):** a labeled set of ~50 real card photos; name+email+phone correctly extracted on **≥85%**; run live (nightly/manual), never CI-blocking with a stub.
- Anthropic SDK mocked in all CI unit tests (no live calls).

**Frontend (Vitest + Playwright):** `useCardOcr` success/403/429 with mocked `authApi`; entitled user sees the control, non-entitled sees the upgrade chip; pre-fill calls `setValue` for matched fields only; a garbage response leaves the form untouched. **Note the ~29 pre-existing FE test failures baseline** — only net-new failures in `card-ocr`/`vcard` files are regressions.

**Worker:** none — no worker change in this feature.

---

## 11. Observability & Rollout

**Phase 0 — Endpoint + metering (internal, no UI).** Apply migration `0024`; register `card_ocr` + `card_ocr_scans_per_month` `inert` then flip `enforced` in this PR; build `vcard_ocr.py` + `card_ocr.py` (downscale, strict-JSON prompt, validation); provision `ANTHROPIC_API_KEY` per env; add `anthropic` + `Pillow` to `requirements.txt`. Test with a seeded Starter workspace + a fixture card deck.

**Phase 1 — Builder UI (closed beta).** Add the scan control + `useCardOcr` + pre-fill behind `NEXT_PUBLIC_CARD_OCR_BETA` for internal + 3–5 design partners. **Run the ≥85% accuracy eval gate before widening.** Acceptance: entitled Starter scans a card → form pre-fills matched fields → user edits → saves a normal vCard QR; over-cap → 429 upgrade state; non-entitled → upgrade chip; garbage image → graceful failure + quota refund; **no QR created without an explicit save**; image not retained.

**Phase 2 — GA.** `card_ocr` already `enforced` (flipped in Phase 0); remove the FE beta flag; optionally enable the Free hook (re-run the enable UPDATE for `lower(name)='free'`, cap `1`) after cost telemetry; surface the v1.1 usage read-out. **GA gates:** accuracy ≥85%; cost-per-scan within target on the beta cohort; cap enforcement verified end-to-end.

**Deploy order:** backend (migration applied **before** the endpoint deploys, since it reads `card_ocr_scans_per_month` and calls `increment_card_ocr_usage`) → frontend. **No worker deploy** (no worker change, no cron). **No DMARC gate** (no email).

**Metrics:** ≥30% of entitled-workspace vCard QRs use scan pre-fill in 30d; ≥40% drop in time-to-create (builder event timing); post-save edit rate on pre-filled fields (silent-wrong-field signal); per-scan token spend dashboarded off `card_ocr_usage.tokens_used`; cap-hit rate (upsell signal); 0 auto-created QRs (invariant); p95 < 4s. Structured log per call: `workspace_id`, fields-matched count, token usage, latency, outcome.

---

## 12. Open Technical Questions & Risks

1. **Count vs refund on failure (Open Q1)** — resolved: increment to gate concurrency, **refund** on a clean model failure (no-JSON/garbage). Small cost-on-us accepted for trust. Confirm the refund RPC (or compensating decrement) is idempotent under retry.
2. **Free hook shape (Open Q2)** — launch **OFF** (`card_ocr=false`, cap 0); enable monthly-1 post-telemetry. The same counter handles monthly-N cleanly; lifetime-1 would need a separate window and is deferred.
3. **Confidence UI (Open Q3)** — blanks-only in v1; per-field confidence is future polish. The model returns `null` for low-confidence fields; we never guess.
4. **Permission level (Open Q4)** — resolved: `require_can_create` (editor+), aligned with vCard create permission.
5. **Token-accounting race — resolved.** Scans are gated by the atomic increment-then-check RPC in §3.1 step 3 (the only count path); tokens are folded by a **separate** `add_card_ocr_tokens` RPC that never touches `scans_used`. There is **no** pre-count `SELECT`, so no RMW race on the cap. The only residual is that token totals are eventually-consistent for margin reporting (not enforcement) — acceptable.
6. **Coverage-test parity (R6)** — `0024` must seed **both** keys on every non-custom plan and both must appear in `FEATURE_ENFORCEMENT` with a real source reference in `vcard_ocr.py`, or `test_feature_gate_coverage` breaks.
7. **Commodity capability (R1)** — scoped as a delighter, not a moat; ship thin; the value is that output lands in *our* dynamic, trackable vCard builder.

### Appendix — Key Files

| Concern | File |
|---|---|
| OCR endpoint + gate + meter | `qr_backend/src/api/routes/vcard_ocr.py` (NEW), registered in `src/api/endpoints.py` |
| AI call helper | `qr_backend/src/utilities/card_ocr.py` (NEW — Pillow downscale, Anthropic vision, strict-JSON prompt, validation) |
| vCard model (extraction target) | `qr_backend/src/api/routes/qr.py` `VcardContent` (line 290) |
| Migration | `qr_backend/migrations/0024_ai_business_card_ocr.sql` (NEW — `card_ocr_usage` + `increment_card_ocr_usage` + flag/limit flip) |
| Gating | `qr_backend/src/api/routes/subscription.py` (`FEATURE_ENFORCEMENT['card_ocr']` + `['card_ocr_scans_per_month']`, `_QUOTA_SPEC`, `get_limit`/`check_feature`) |
| Coverage guardrail | `qr_backend/tests/unit_tests/test_feature_gate_coverage.py` (must stay green) |
| Config / env | `ANTHROPIC_API_KEY` via `src/config/manager.py` (+ `.env.example`); `anthropic`,`Pillow` in `requirements.txt` |
| Builder UI | `qr_frontend/src/components/qr-generator/content-types/VCardContent.tsx` + NEW `card-scan-control.tsx` |
| Hook | `qr_frontend/src/hooks/useCardOcr.ts` (NEW) |
| FE gating | `qr_frontend/src/lib/plan-features.ts`, `src/hooks/useSubscription.ts` (`PlanFeatures.card_ocr` + `card_ocr_scans_per_month`) |
| Worker | **No change** (no KV, no type, no template, no cron) |
