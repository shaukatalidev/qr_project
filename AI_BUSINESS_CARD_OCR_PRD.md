# PRD — AI Business-Card OCR → vCard Import

**Status:** Draft · **Author:** Product · **Date:** 2026-06-24
**Priority:** Activation delighter on the flagship `vcard` type — a cheap, on-brand AI accelerator that shortens time-to-first-QR. Not a moat; a conversion lubricant.
**Tiers:** **Starter+** (`card_ocr` flag) with a **metered monthly cap per workspace** (`card_ocr_scans_per_month`), plus an optional **Free hook** (a tiny lifetime/monthly allotment to seed the upgrade ask). Both seeded by this feature's migration.
**Plan flags:** `card_ocr` (bool, NEW) + `card_ocr_scans_per_month` (int limit, NEW). Registered `inert` in `FEATURE_ENFORCEMENT` and flipped `enforced` in the **same PR** (house convention; `test_feature_gate_coverage` stays green).
**Split from:** the `vcard` builder flow (`qr_frontend/src/components/qr-generator/content-types/VCardContent.tsx`). Mirrors the metering/usage-table design of **AI_SCAN_ANALYST** (`AI_SCAN_ANALYST_PRD.md`, migration `0014`, `ai_analyst_usage`).

**Rev (2026-06-24, post eng-review):** Tightened to ship as-drafted (scope accepted — single metered endpoint, no QR type, no Worker touch is correctly boring). Fixed real issues: (1) the `0024` flag-seed must write a **full-object `'{...}'::jsonb` blob** (not only `jsonb_set` path writes) or `test_feature_gate_coverage._seed_feature_keys()` — which regex-scans `'{...}'::jsonb` blobs — will not discover `card_ocr`/`card_ocr_scans_per_month` and will fail them as "stale" (verified against `0010`/`0013`, whose keys are discovered only via the `0009` blob); (2) resolved the metering self-contradiction — **increment-then-check is the single authoritative path** (do not also "pre-count SELECT", which reintroduces the RMW race the atomic RPC removes); (3) added explicit **decode-bomb / pixel-dimension guard** on the Pillow decode (a 5 MB cap does not bound a decompression bomb's pixel count); (4) made the failure **refund idempotent** under retry and noted the refund must never drive `scans_used` negative; (5) v1.1 `GET .../usage` read-out must reuse `period_start_iso` windowing (not a naive calendar month) so the read-out matches enforcement. No scope cut needed.

---

## 1. TL;DR / Summary

A user building a vCard QR can **snap or upload a photo of a paper business card**. The image is POSTed to a single new backend endpoint, which sends it to **`claude-haiku-4-5`** (vision-capable, cheapest) with a strict JSON-extraction prompt. Claude returns structured fields — `first_name`, `last_name`, `company`, `job_title`, `phone`, `email`, `website`, `city`, etc. — that **pre-fill the existing vCard content-type form**. The user **reviews and edits every field before saving** (confirm-before-save; we never auto-create a QR from OCR output).

The entire feature is one metered FastAPI route plus a thumbnail-uploader UI control bolted onto the existing vCard step. **No new QR type. No Worker change. No KV change. No edge AI.** AI runs backend-side only, at request time — never on the scan hot path. We meter token spend with a per-workspace monthly cap that mirrors `ai_analyst_usage`, and we hard-cap image size + `max_tokens` to protect margins.

This is a 30-second "wow" on the single most-built QR type, turning the most tedious step of vCard creation (hand-typing 8–12 fields off a card) into a snapshot.

## 2. Problem & Motivation

**The vCard builder is our most-used dynamic type and its slowest step is manual data entry.** A digital business card has ~10 fields (`VcardContent` in `qr.py` defines `first_name`, `last_name`, `company`, `job_title`, `phone`, `email`, `street_address`, `website`, `city`, `country`, `bio`, `zip_code`, `state`). Sales reps, event-booth staff, and SMB owners frequently already *have* a paper card they want to digitize — and today they retype it field-by-field on a phone keyboard. That friction is the single biggest drop-off in the vCard wizard.

**The seam is already in our hands.** The Anthropic Python SDK is already provisioned server-side (`ANTHROPIC_API_KEY`, used by AI_SCAN_ANALYST). The vCard form, its Pydantic model (`VcardContent`), and the `qr_vcard_details` table already exist. This feature is a thin adapter: image → Claude vision → the *exact same fields* the form already accepts. We are not inventing a data model; we are auto-populating one.

**It's a cheap, on-brand activation delighter.** Our strategic posture treats AI as a *capability accelerator on existing flows*, not a separate product. Business-card OCR is the canonical "AI makes the boring part disappear" moment. It improves **time-to-first-vCard** and gives Starter a tangible reason to exist above Free.

**We must be honest about what it is — and isn't.** OCR-of-business-cards is a **commodity** (CamCard, Veryfi, ABBYY, Google Vision all do it). The value here is **integration, not the AI**: the extracted data lands directly in *our* vCard builder and becomes a *dynamic, trackable* QR — something a standalone scanner app cannot do. We deliberately scope this as a delighter, gate it modestly (Starter+), and protect margin with metering. We do **not** position it as a differentiator or build a heavyweight pipeline.

## 3. Goals & Non-Goals

**Goals**
- A single metered endpoint `POST /api/v1/workspaces/{workspace_id}/vcard/ocr` that accepts one card image and returns extracted vCard fields as JSON (no QR is created).
- **Pre-fill the existing vCard form** with the extracted fields; the user **reviews/edits before save** (never auto-create).
- **Meter and cap**: per-workspace monthly counter (`card_ocr_usage`, mirroring `ai_analyst_usage`), enforced against `card_ocr_scans_per_month` from `plans.features`; hard image-size cap + capped `max_tokens` to bound cost.
- Gate behind `card_ocr` (Starter+), registered + flipped `enforced` in the same PR; coverage test stays green.
- Graceful, honest UX when extraction is partial or low-confidence — fields fill where confident, blanks stay blank, nothing is silently wrong.

**Non-Goals**
- **No auto-create.** OCR output is never persisted as a QR without an explicit user save through the normal create flow. *(Confirm-before-save is a hard requirement, not a setting.)*
- **No new QR type, no Worker/KV/edge change.** This does not touch `build_kv_content`, `build_entitlements`, the scan path, or any template. *(The Worker is untouched.)*
- **No multi-card / batch scan** in v1 (one card per request). *(Future.)*
- **No CRM/contact-book storage** of scanned cards — we extract into a vCard QR draft, we are not building an address book. *(Future, separate PRD.)*
- **No client-side OCR** and **no third-party OCR vendor** — Claude vision only, backend only.
- **No image retention** beyond the request. The uploaded card image is processed in-memory and discarded; we store only the **count** of OCR calls (and optionally token usage), never the image or extracted PII. *(Strict non-PII on any persisted/usage surface.)*

## 4. Target Users & Personas

| Persona | Who | Job-to-be-done | Today's pain |
|---|---|---|---|
| **Field Sales Rep ("Sana")** | Carries her own digital vCard, collects paper cards at expos | Spin up her own vCard fast; later digitize a stack of received cards | Retypes 10 fields per card on a phone keyboard |
| **Event-Booth Staffer ("Leo")** | Sets up vCards for a team before a conference | Create 12 team vCards quickly from printed cards | Manual entry × 12 = abandonment |
| **SMB Owner (" Amara")** | Has one professionally printed card, wants a scannable version | Convert her existing card into a dynamic, editable QR | Doesn't want to re-key her own card |
| **Starter-curious Free user** | On Free, hits the OCR hook | Sees "snap a card" once, wants more | Free allotment exhausted → upgrade ask |

Primary buyer is the **Starter-tier individual/SMB** for whom this is the headline reason to pay over Free. Secondary: **Pro/Agency** booth teams who value the speed at volume (a higher monthly cap is the upsell).

## 5. User Stories

- As a **sales rep**, I want to photograph a business card and have the vCard form auto-fill, so that I create my digital card in seconds instead of typing 10 fields.
- As a **booth staffer**, I want each scan to drop me into the normal builder with fields pre-filled, so that I can fix the one field OCR got wrong and hit save.
- As **any user**, I want to **review and correct** every extracted field before the QR is created, so that a misread phone number never goes live silently.
- As a **Free user**, I want to try card scan once (the hook), so that I understand what Starter unlocks — and I see a clear, honest "you've used your free scan" upgrade nudge.
- As a **workspace owner**, I want OCR usage capped per month, so that the feature can't run up a surprise AI bill.
- As an **Agency owner**, I want a higher monthly cap, so that my team can digitize cards at an event without hitting the wall.
- As a **privacy-conscious user**, I want my uploaded card image discarded after extraction, so that no scanned PII is retained server-side.

## 6. UX / Product Flow

**6.1 The scan entry point — vCard builder Step (`VCardContent.tsx`)**
1. In the vCard content-type form (the `(builder)/build` wizard, Step 1 content), a new **"Scan a business card"** control renders at the top of the form for `card_ocr`-entitled workspaces. It's a shadcn `Button` + hidden file input (camera-capable on mobile via `accept="image/*" capture="environment"`), styled with the indigo `primary` token — no raw `<button>`, no inline styles.
2. The control is **conditionally rendered** on `canAccessFeature(subscription, 'card_ocr')` (via the `PlanFeatures` interface in `useSubscription.ts` / `plan-features.ts`). Non-entitled users see a compact **upgrade chip** ("Scan a card — Starter") instead, mirroring how other gated builder affordances tease.
3. On file pick, the client validates size/type client-side (reject > ~5 MB, non-image), shows a spinner, and POSTs the image to the OCR endpoint via `authApi`. A new TanStack mutation hook `useCardOcr` (in `src/hooks/`) wraps it — **never** `useEffect + fetch`.

**6.2 Extraction + confirm-before-save**
1. The endpoint returns `{ fields: {...}, used: <n>, limit: <m> }`. The mutation `onSuccess` calls the form's `react-hook-form` `reset()`/`setValue()` to **pre-fill** matched fields; unmatched fields stay empty.
2. A subtle **"Pre-filled from your card — please review"** banner appears above the form (dismissable). Every field remains fully editable. **No QR is created at this step.** The user proceeds through the normal wizard (design, save) exactly as a hand-typed vCard.
3. Low-confidence or missing fields are simply left blank — we do **not** guess. (See §11 on confidence handling.)

**6.3 Quota + error states**
- If the workspace is over `card_ocr_scans_per_month`, the endpoint returns a structured `429`/`402`-style payload; the UI shows an **"You've used all N card scans this month — upgrade for more"** toast/inline state, reusing the existing upgrade-gate component pattern.
- On extraction failure (blurry image, no card detected, model returns no usable JSON), the UI shows a friendly **"Couldn't read that card — try a clearer photo or enter details manually"** and leaves the form untouched. The call still **counts against** the cap only if Claude was actually invoked (decide: count successful invocations; see §11).

**6.4 Discoverability**
- A one-line "New: Scan a paper card to build your vCard" note on the vCard type tile in the type picker (FE constant), and a help tooltip. No marketing-site change required for v1; optional landing-page mention at GA.

**6.5 Settings (optional, v1.1)** — a small **Usage** read-out ("Card scans this month: 7 / 50") could surface in the existing billing/usage area, reusing the metering counter. Not required for v1 GA.

## 7. Scope

**In scope (v1)**
- `POST /workspaces/{id}/vcard/ocr` — accepts one image (multipart or base64), calls `claude-haiku-4-5` with a strict JSON schema prompt, validates output against the `VcardContent` field set, returns matched fields. Gated by `card_ocr`; metered against `card_ocr_scans_per_month`.
- `card_ocr_usage` counter (per workspace per month), incremented on a successful model invocation; mirrors `ai_analyst_usage`.
- FE: scan control on `VCardContent.tsx`, `useCardOcr` hook, confirm-before-save pre-fill, quota/error states, upgrade chip for non-entitled.
- Hard caps: image size (e.g. ≤ 5 MB, downscale server-side before sending), `max_tokens` ceiling, single image per call.
- `card_ocr` registered in `FEATURE_ENFORCEMENT` (`inert`→`enforced` same PR), `card_ocr_scans_per_month` seeded per tier.

**Out of scope / Future**
- Batch / multi-card upload, stack scanning *(future)*.
- Storing scanned cards as an address book / CRM export *(future)*.
- OCR for any other type (event flyers → event QR, menus → PDF) *(future; same endpoint pattern)*.
- Confidence scores surfaced per field in the UI *(future polish)*.
- Logo/photo extraction from the card into the vCard avatar *(future)*.
- A Free-tier **lifetime-1** hook variant vs **monthly-N** — pick one at launch (see §9), the other is future tuning.

## 8. Pricing & Packaging

| Surface | Tier | Flag / Limit |
|---|---|---|
| Business-card scan → vCard pre-fill | **Starter, Pro, Agency** | `card_ocr` (NEW bool) |
| Monthly scan allotment | per tier | `card_ocr_scans_per_month` (NEW int) |
| Optional Free hook | **Free** | `card_ocr=true` + a tiny `card_ocr_scans_per_month` (e.g. `1`–`3`) |

**Suggested seed values** (tunable in `plans.features` without deploy): Free = `1` (or `0` if we want a hard gate), Starter = `25`, Pro = `100`, Agency = `500`. `-1`/unlimited is **not** offered on any tier — every scan is a metered Claude vision call and margin must be protected (mirrors AI_SCAN_ANALYST's deliberate no-unlimited stance).

- **Why Starter+ (not Pro+):** this is an **activation delighter**, not a premium analytics moat. Putting it at Starter gives the cheapest paid tier a concrete, demoable reason to exist and lifts Free→Starter conversion. The *margin* protection comes from the cap, not the tier.
- **Why a Free hook:** one free scan is a high-conversion "aha" — the user feels the magic once, then hits the wall with a contextual upgrade ask. If margin/abuse risk is a concern at launch, seed Free at `0` and turn the hook on after watching cost telemetry.
- **Migration flag-flip (house convention):** seed the flag/limit absent-everywhere first, then enable for the chosen tiers by lowercased name — never bare `WHERE name IN (...)`. **Critical:** the seed step must write a **full-object `'{...}'::jsonb` blob** (merged with `||`), not only single-key `jsonb_set` path writes — `test_feature_gate_coverage._seed_feature_keys()` discovers feature keys by regex-scanning `'{...}'::jsonb` blobs, so a path-only seed leaves both new keys undiscovered and the coverage test fails them as "stale" (this is how `api_access`/`retargeting_pixels` reach the seed-key set via the `0009` blob):
  ```sql
  -- seed BOTH keys as a full-object blob where ABSENT (regex-discoverable; non-custom).
  -- `features || blob` only writes keys not already present via the NOT(... ? ...) guard.
  UPDATE plans
  SET features = coalesce(features,'{}'::jsonb) || '{"card_ocr":false,"card_ocr_scans_per_month":0}'::jsonb
    WHERE NOT (coalesce(features,'{}'::jsonb) ? 'card_ocr') AND coalesce(is_custom,false)=false;
  -- enable + set the cap for paid tiers (and Free if hook chosen) via path writes
  UPDATE plans SET features = jsonb_set(
        jsonb_set(coalesce(features,'{}'::jsonb), '{card_ocr}', 'true'::jsonb, true),
        '{card_ocr_scans_per_month}', '25'::jsonb, true)
    WHERE lower(name) = 'starter' AND coalesce(is_custom,false)=false;  -- pro/agency similarly
  ```
- **Upsell ladder:** Free user exhausts the hook → "Upgrade to Starter for 25 scans/mo." Starter booth team hits the wall → "Upgrade to Pro/Agency for more." One feature, two upgrade rungs.

## 9. Success Metrics & KPIs

**Activation**
- ≥ 30% of vCard QRs **created** by `card_ocr`-entitled workspaces use the scan pre-fill (vs fully manual) within 30 days of GA.
- **Time-to-create a vCard** (first content-form open → save) drops **≥ 40%** for scan-assisted vs manual creations (event timing on the builder).
- Free→Starter conversion **+8%** among Free users who triggered the OCR hook (vs Free users who didn't), if the Free hook is enabled.

**Quality / trust**
- **Field-level extraction accuracy ≥ 85%** on a labeled internal eval set of ~50 real cards (name + email + phone correctly extracted), measured as a release gate (see §12). No silent wrong fields — measured by post-save edit rate on pre-filled fields.
- **0 auto-created QRs** from OCR (invariant; confirm-before-save).

**Margin / cost**
- **Median cost per scan within target** (haiku vision + capped `max_tokens`); p95 cost bounded by the image-size cap. Per-scan token usage logged (optional column) for margin monitoring.
- **0 workspaces** exceed their monthly cap (enforcement working); cap-hit rate tracked as an upsell signal.
- Endpoint p95 latency **< 4s** for a single card (one synchronous Claude call).

## 10. Rollout Plan

**Phase 0 — Endpoint + metering (internal).**
- Migration ships the flag + limit + `card_ocr_usage` counter (this phase's schema only — nothing else). Register `card_ocr` in `FEATURE_ENFORCEMENT` as `inert`. Build the endpoint, image downscale, strict-JSON prompt, output validation against `VcardContent`. Test with a seeded Starter workspace and a fixture deck of card photos. No UI.

**Phase 1 — Builder UI behind a FE flag (closed beta).**
- Add the scan control to `VCardContent.tsx`, `useCardOcr` hook, confirm-before-save pre-fill, quota/error states. Ship behind a FE env/constant flag for an internal + 3–5 design-partner beta. Run the **accuracy eval gate** (≥ 85% on the 50-card set) before widening.
- **Acceptance:** an entitled Starter workspace scans a card → form pre-fills matched fields → user edits → saves a normal vCard QR; over-cap returns the upgrade state; non-entitled sees the upgrade chip; a garbage image fails gracefully; **no QR is created without an explicit save**; uploaded image is not retained.

**Phase 2 — GA.**
- Flip `card_ocr` `inert`→`enforced` in `FEATURE_ENFORCEMENT` (same PR as the seed if not already, keeping `test_feature_gate_coverage` green), remove the FE flag, optionally enable the Free hook, surface the usage read-out (v1.1).
- **GA gates:** accuracy eval ≥ 85%; cost-per-scan telemetry within target on the beta cohort; cap enforcement verified end-to-end.

**Notes on the two cross-service gates (proactively cleared):**
- **No email** is sent by this feature → the unpublished `_dmarc.qravio.app` record is **not** a blocker here.
- **No cron / no Worker change** → no prod-worker-deploy gate; `npm run deploy:prod` is **not** required for this feature.
- `ANTHROPIC_API_KEY` must already be provisioned (shared with AI_SCAN_ANALYST); confirm it exists per environment.

## 11. Risks, Edge Cases & Open Questions

**R1 — Commodity capability.** OCR-of-cards is undifferentiated (CamCard/Veryfi/Google Vision). **Mitigation:** scope as a delighter, not a moat; the value is that output lands in *our* dynamic vCard builder. Don't over-invest; ship thin.

**R2 — Accuracy on noisy cards (known risk).** Glossy, multi-language, vertically-laid, or low-contrast cards misread. **Mitigation:** **confirm-and-edit-before-save is mandatory** — we never auto-create. Leave low-confidence fields blank rather than guess. Eval gate (≥ 85%) before GA. Tell the model to return `null` for any field it isn't confident about, and validate every returned value (e.g. email regex, phone normalization) server-side, dropping malformed values.

**R3 — Token / image cost blowup (known risk).** Vision tokens scale with image resolution. **Mitigation:** **downscale the image server-side** before sending (cap longest edge, e.g. ~1568px per vision best practice), hard `max_tokens` ceiling on the JSON output, single image per call, and a **monthly per-workspace cap** (`card_ocr_scans_per_month`) mirroring `ai_analyst_usage`. No unlimited tier. Optionally log per-call token usage for margin alarms.

**R3b — Decompression bomb (DoS, known risk).** A 5 MB byte cap does **not** bound decoded pixel count — a small, highly-compressed PNG can decode to gigapixels and OOM the worker before downscale runs. **Mitigation:** set `PIL.Image.MAX_IMAGE_PIXELS` to a sane ceiling (e.g. ~40 MP), wrap `Image.open(...).load()` in a try/except that returns `415` on `DecompressionBombError`/decode failure (never 500), and verify the decoded format is in the JPEG/PNG/WebP allowlist (don't trust the client `content_type`).

**R4 — Prompt injection via card text.** A malicious card could contain text like "ignore instructions." **Mitigation:** the model is asked only to *extract into a fixed JSON schema*; we **never execute** its output and we **validate** every field server-side. Output that doesn't match the schema is discarded. No tool-use, no side effects.

**R5 — PII retention.** Scanned cards are third-party PII. **Mitigation:** process the image **in-memory and discard** it; persist **only the usage count** (and optional non-identifying token count) — never the image, never the extracted fields, in `card_ocr_usage`. The extracted fields live only transiently in the user's form until *they* choose to save (at which point it's their normal vCard, governed by existing data handling).

**R6 — Gating correctness.** A new flag must be `inert`→`enforced` in the same PR with seed parity, or `test_feature_gate_coverage` breaks. `check_feature(ws, 'card_ocr', db)` is **async** — must be awaited. The limit check must read the *workspace's* plan limit via the existing limit helper, fail-closed on error.

**R7 — Abuse / cost on Free hook.** A free scan invites scripted abuse. **Mitigation:** require auth (the endpoint is Bearer-protected, workspace-scoped via `require_can_create`/permissions), the cap is per-workspace-per-month, and the Free hook can launch at `0` (off) and be turned on after watching telemetry.

**Open Questions**
1. Count against the cap on **every Claude invocation** or only on **successful extraction**? *Recommend: count successful invocations (a clean refusal/garbage image doesn't burn the user's quota, but does cost us — accept the small cost for trust).*
2. Free hook: **monthly-N** (e.g. 1/mo) vs **lifetime-1**? *Recommend monthly-1, easier to reason about with the same counter; or launch at 0 and enable post-telemetry.*
3. Surface per-field confidence to the user in v1, or just leave blanks? *Recommend blanks-only in v1; confidence UI is future polish.*
4. Should `require_can_create` (editor+) be the permission, since this feeds QR creation? *Recommend yes — align with vCard create permission.*

## 12. Dependencies

- **Anthropic SDK + `ANTHROPIC_API_KEY` (shared with AI_SCAN_ANALYST):** the vision call. Confirm the key is provisioned per environment; model id `claude-haiku-4-5`.
- **vCard data model (shipped):** `VcardContent` Pydantic model + `qr_vcard_details` table + `VCardContent.tsx` form — the extraction target and pre-fill surface.
- **Gating engine (shipped):** `FEATURE_ENFORCEMENT` registry + `check_feature` (async) in `subscription.py`; the limit helper for `card_ocr_scans_per_month`; `canAccessFeature`/`PlanFeatures` in `plan-features.ts`/`useSubscription.ts`.
- **Metering pattern (shipped reference):** `ai_analyst_usage` table + monthly-cap logic from AI_SCAN_ANALYST (`0014`) — `card_ocr_usage` mirrors it.
- **API client / hooks (shipped):** `authApi` (`api-client.ts`) + TanStack Query; new `useCardOcr` mutation in `src/hooks/`.
- **No Worker, KV, cron, or email dependency.**

### Migration decision — ship **0024**

A migration **is** required, but a **minimal** one. Per house rule (ship only this phase's schema), `0024` adds exactly: (a) the `card_ocr` flag + `card_ocr_scans_per_month` limit seed/flip via the `jsonb_set` convention above; (b) a small **`card_ocr_usage`** counter table `(workspace_id, period_month, scans_used, [tokens_used], updated_at)` mirroring `ai_analyst_usage`, with an idempotent upsert/increment used by the endpoint. We chose a tiny table over a JSONB-on-workspace counter for the same reason AI_SCAN_ANALYST did: clean monthly windows and per-period rows for margin reporting. The roadmap reserves 0014–0018; the next free roadmap slot for this backlog item is **0024** (as instructed). Begin/Commit-wrapped, idempotent (`IF NOT EXISTS`), applied by hand in the Supabase SQL editor.

*(If product decides the Free hook launches off and we tolerate JSONB usage on an existing table instead of a new one, the table could be dropped — but the flag+limit flip still requires a migration, so "No migration required" is **not** an option here. We ship `0024`.)*

### Appendix — Key Files

| Concern | File |
|---|---|
| OCR endpoint + gate + meter | `qr_backend/src/api/routes/qr.py` (new `POST /workspaces/{id}/vcard/ocr`) or a small new `src/api/routes/vcard_ocr.py` mounted in `endpoints.py` |
| vCard model (extraction target) | `qr_backend/src/api/routes/qr.py` (`VcardContent`, ~line 290), `qr_vcard_details` table |
| AI call helper | new `qr_backend/src/utilities/card_ocr.py` (Anthropic vision call, image downscale, strict-JSON prompt, output validation) |
| Metering | `qr_backend/migrations/0024_ai_business_card_ocr.sql` (`card_ocr_usage` + flag/limit seed), increment helper mirroring `ai_analyst_usage` |
| Gating | `qr_backend/src/api/routes/subscription.py` (`FEATURE_ENFORCEMENT['card_ocr']` inert→enforced), limit read for `card_ocr_scans_per_month` |
| Builder UI | `qr_frontend/src/components/qr-generator/content-types/VCardContent.tsx` (scan control + pre-fill) |
| Hook | new `qr_frontend/src/hooks/useCardOcr.ts` (TanStack mutation via `authApi`) |
| FE gating | `qr_frontend/src/lib/plan-features.ts`, `src/hooks/useSubscription.ts` (`PlanFeatures.card_ocr`) |
| Config | `ANTHROPIC_API_KEY` (existing env, shared with AI_SCAN_ANALYST), `src/config/manager.py` |
