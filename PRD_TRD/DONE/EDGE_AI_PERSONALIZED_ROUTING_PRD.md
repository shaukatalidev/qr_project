# PRD — Edge AI Personalized Routing

**Status:** Draft · **Author:** Engineering · **Date:** 2026-06-24
**Priority:** Highest-effort moat play — build after the simpler routing/lifecycle gaps (Scheduled Routing, Expiration) are scoped; this PRD subsumes both "scheduled routing" and "multi-language landing" gaps into one engine.
**Tiers:** **Pro** (`routing_rules`, bool — geo/device/time/language rules) · **Agency** (`ai_variants`, bool — Claude-generated localized/persona copy). Free/Starter — none.
**Plan flags:** `routing_rules` (bool), `ai_variants` (bool) — both seeded `false` on every tier by migration 0009; this feature's migration (0015) flips `routing_rules` on for Pro/Agency and `ai_variants` on for Agency only.
**Split from:** Strategic-gaps audit items #1 (Scheduled Routing) + #8 (Multi-Language Localization), extends the existing `qr_destinations` JSONB and the proven A/B sticky-cookie engine.
**Rev (2026-06-24, post eng-review):** **v1 = the deterministic routing engine only**; AI variant generation (`ai_variants`, Agency) is deferred to a **Phase-2 PR** so the first ship carries no LLM dependency. The downgrade → `resync_workspace_qrs` hook moves into **Phase 1** (the write-time KV snapshot otherwise leaves the Worker guard ineffective). Migration `0015` flag-flip uses the `lower(name)` + `is_custom` convention; the `Intl.DateTimeFormat`-in-Workers assumption gets a verification spike + UTC-offset fallback before time-window rules commit.

---

## 1. TL;DR / Summary

At scan time, the Cloudflare Worker already knows the visitor's country, region, timezone, device, and `Accept-Language` — it reads all of these in `recordScan` today, then throws them away after analytics. Edge AI Personalized Routing turns that signal into a **routing decision made before paint**: a Pro workspace defines rules ("EU + mobile + business hours → variant A; US + after-hours → variant B; lang=es → Spanish landing"), and the Worker evaluates them in microseconds against `request.cf` + the cookie-pinned variant — no inference, no backend call on the hot path. For Agency workspaces, Claude **pre-generates** localized and persona-tuned landing copy at *write* time, snapshotted into KV (the `resync_workspace_qrs` pattern), so the edge stays as fast as a plain redirect. This is a structural moat: a SaaS-on-Vercel rival cannot make a geo/time/device decision at the edge before the page paints, and they have no pre-warmed AI variant cache. We monetize the **engine** at Pro and the **AI generation** at Agency.

## 2. Problem & Motivation

Today a dynamic QR has exactly one behavior for every scanner on earth. The `qr_destinations` table already carries a `rules`/`conditions` JSONB column (scaffolded with the A/B work) — but **there is no UI and no Worker evaluation engine**; only weight-based A/B split is exposed (`handlers/websiteRedirect.js`, `src/utils/ab.js`). The strategic audit flags this twice: scheduled/time-triggered routing (#1) is "the biggest unplanned product gap for event/retail use cases," and multi-language localization (#8) is "a wedge vs US-first competitors" given our India-first pricing.

Evidence this is the right wedge:

- **The signal is free and already captured.** `recordScan` (src/utils/scan.js) extracts `country_code`, `region`, `city`, `timezone`, `device_type`, and `language` (first `Accept-Language` tag) on *every* scan. We are paying the cost of reading `request.cf` and discarding the routing value.
- **The engine already half-exists.** Sticky-cookie variant pinning (`qr_ab_<sc>`, 30-day, SameSite=Lax), per-variant scan attribution (`scans_by_variant`, `unique_scans_by_variant`), and the `destinations[]` KV array are all live. We extend, not rebuild.
- **The edge is the moat.** Competitors on Vercel/serverless-origin architectures cannot decide *before* the redirect/paint without an origin round-trip (latency tax). Our Worker decides at the PoP. The audit calls the CF Worker edge "a structural advantage no SaaS-on-Vercel rival has."
- **No AI surface exists anywhere in the product** (FE audit: "No AI surface anywhere in the app"). This is the first AI feature, and it's the *defensible* kind — pre-generated and cached, not a hot-path inference gimmick.
- **Two real buyer segments are unserved:** event organizers (pre/post-event and timezone-aware routing) and retail (business-hours vs after-hours destinations). Both are explicitly named as high-stickiness, hard-to-replicate workflows.

The risk the audit names is real and we design around it: **must not add edge latency** (so: pre-evaluate rules from KV, never call AI at scan time) and **entitlement-snapshot staleness on downgrade** (KV is write-time snapshotted; a Pro→Free downgrade must collapse routing back to the default destination).

## 3. Goals & Non-Goals

**Goals**
1. A **rules schema** on `qr_destinations` (geo, device, time-window + timezone, language) that the builder writes and the Worker reads from KV.
2. A **Worker evaluation engine** (`src/utils/routing.js`) that picks the matching destination/variant from `request.cf` + headers, with deterministic precedence and a guaranteed default fallback — adding **< 1ms** and **zero** new network calls on the scan path.
3. A **builder UI** (Routing tab on the QR detail / builder step) to author rules for dynamic QRs.
4. **AI variant pre-generation** (Agency) *(Phase 2 — deferred from v1 per eng-review)*: at write time, Claude generates localized/persona landing copy per declared locale/persona, cached into KV `content.variants`.
5. **Sticky behavior** (cookie-pinned) so a returning scanner sees a stable variant, reusing the `qr_ab_<sc>` cookie pattern.
6. Gate the **engine** behind `routing_rules` (Pro+) and **AI generation** behind `ai_variants` (Agency); flip both `inert→enforced` in the same PR.

**Non-Goals**
- Real-time / hot-path AI inference at the edge (Workers AI binding) — `(future)`; v1 is pre-generated-and-cached only.
- Free-text natural-language rule authoring ("send Germans to the German page") — `(future)`; v1 is a structured rule builder.
- Per-scanner ML personalization / behavioral targeting (no profile store) — `(future)`.
- Routing for **static** types (`url`, `text`, `vcard`, etc., which never hit the Worker render path) — out of scope. Routing applies to `website` (redirect variants) and HTML-rendering dynamic types (content variants).
- A/B *and* rules on the same destination set simultaneously in v1 — rules take precedence; weight-split is the fallback when no rule matches `(see Open Questions)`.

## 4. Target Users & Personas

- **Multi-region brand manager (Pro/Agency).** Runs one packaging QR globally; wants `lang=es`→Spanish landing, `lang=fr`→French, default→English, all from one short code. Today must mint separate QRs per market.
- **Event organizer (Pro).** Wants the same printed badge QR to route to "schedule" before the keynote, "live stream" during, and "recording + survey" after — timezone-aware so a Tokyo attendee and an NYC attendee both get the right phase.
- **Retail / multi-location ops (Pro).** Business-hours → "order online / current promo"; after-hours → "store hours + reservation form." Device-aware: mobile → click-to-call, desktop → full menu.
- **Agency creative lead (Agency).** Manages 50+ client QRs; wants Claude to draft persona/locale variants so they don't hand-write 6 language versions of a landing page, then tweak the generated copy before publish.

## 5. User Stories

- As a **multi-region brand manager**, I want one QR to show localized landing copy based on the scanner's `Accept-Language`, so that I print one code worldwide instead of one per market.
- As an **event organizer**, I want time-window rules evaluated in the scanner's timezone, so that attendees in any region see the correct event phase without me manually switching the destination.
- As a **retail ops lead**, I want business-hours vs after-hours routing plus mobile-vs-desktop variants, so that scanners always land on the most actionable page for that moment and device.
- As an **Agency creative lead**, I want Claude to pre-draft localized and persona variants that I can edit before publishing, so that I deliver multilingual campaigns in minutes instead of days.
- As a **returning scanner**, I want to keep seeing the same variant I first saw, so that my experience is consistent across repeat scans.
- As a **Free/Starter user**, I want a clear upsell when I open the Routing tab, so that I understand routing is a Pro feature.
- As **platform owner**, I want a downgraded workspace's QRs to fall back to the default destination at the edge, so that we never serve a paid capability after entitlement loss.

## 6. UX / Product Flow

**Authoring (builder + QR detail).** Routing is surfaced as a **"Routing" tab** on the QR detail page (`QRDetails.tsx`, alongside the existing `ABTestingCard`) and as an optional step for dynamic types in the builder wizard. It is gated: `canAccessFeature(subscription, 'routing_rules')` → if false, render a `RoutingUpgradeGate` (mirrors the analytics `UpgradeGate` pattern).

1. User opens **Routing** on a dynamic QR. They see a **default destination/variant** (always required — the fallback) and a list of **rules**, each: *condition set* (any of: country/region in [...], device in [mobile/tablet/desktop], time-window `start–end` + timezone mode [scanner-local | fixed], language in [...]) → *target* (a destination URL for `website`, or a content variant for HTML types).
2. Rules are **ordered** (drag to reorder); first match wins. The UI shows a plain-English preview per rule ("If country is DE, FR and device is mobile → Variant B").
3. **AI variants (Agency only, gated `ai_variants`).** On HTML-rendering types, the user clicks **"Generate localized variants"**, picks target locales/personas, and the backend calls Claude to draft copy from the QR's base content. Drafts land in an editable preview; nothing publishes until the user saves. Pro-without-Agency sees the AI button disabled with an Agency upsell.
4. On **Save**, the backend validates the rule schema, persists to `qr_destinations.rules`, runs `build_kv_content` (now emitting `content.variants` + `routing`) and `write_to_kv()`. A `routing_rules`-gated check runs server-side (deep-link/API bypass defense).

**Scan time (Worker, `src/index.js` → `handleWebsiteRedirect` / `handleQRCode`).**
1. KV lookup as today. If `parsedData.routing` is present **and** `entitlements.routing_rules !== false`, call `evaluateRouting(parsedData.routing, request, cookies)` (`src/utils/routing.js`).
2. The engine reads `request.cf.country/region/timezone`, `detectDevice(ua)`, and the first `Accept-Language` tag; checks the sticky `qr_route_<sc>` cookie first (pinned variant wins to stay consistent); otherwise evaluates rules in order; first match returns its target; no match → default.
3. For `website`: 302 to the chosen destination (records scan with `variant_key`, exactly like A/B). For HTML types: render the chosen `content.variants[key]` (falling back to base `content`).
4. Set/refresh `qr_route_<sc>` (30-day, SameSite=Lax). `recordScan` fires via `ctx.waitUntil` with `variant_key` so per-variant analytics light up in the existing `scans_by_variant` counters — the analytics page and `useABResults` surfaces already render this.

**Analytics.** Per-variant performance reuses `useABResults(qrId)` / `ABResultsCard`; we relabel "A/B variant" → "Routing variant" and add a matched-rule breakdown in Phase 2.

## 7. Scope

**In scope (v1)**
- `qr_destinations.rules` schema (geo/device/time/language) + Pydantic models + builder UI on dynamic QRs.
- Worker `evaluateRouting` engine with deterministic precedence, sticky cookie, guaranteed default, zero new network calls.
- KV propagation: `routing` block + (Agency) `content.variants` via `build_kv_content`/`sync_qr_to_kv`.
- Gating: BE `check_feature` for `routing_rules` (write); FE `canAccessFeature`; Worker entitlement guard.
- **Downgrade → `resync_workspace_qrs` hook** (pulled into v1 per eng-review) so a Pro→Free downgrade collapses routing to default at the edge.
- Migration 0015 (routing engine only: `rules` column ensured + `routing_rules` flag flip).

**Out of scope / Future**
- **AI variant generation (Agency, `ai_variants`)** — backend Claude call at write time → editable drafts → cached to KV; locale variants first, persona as a copy-tone toggle. Deferred to a **Phase-2 PR** per eng-review (keeps v1 to the deterministic engine, no LLM dependency on the first ship).
- Natural-language rule authoring `(future)`.
- Hot-path Workers AI inference / Analytics Engine binding `(future)`.
- Routing on static types `(future — N/A by architecture)`.
- City-level rules (only country/region in v1; CF gives city but rule cardinality explodes) `(future)`.
- Combined weight-split *within* a matched rule `(future)`.
- Cross-QR campaign-level routing templates `(future)`.

## 8. Pricing & Packaging

| Capability | Free | Starter | Pro | Agency |
|---|---|---|---|---|
| Geo/device/time/language **routing rules** (`routing_rules`) | — | — | ✅ | ✅ |
| **AI-generated** localized/persona variants (`ai_variants`) | — | — | — | ✅ |

- **New entitlement flags:** `routing_rules` (bool) gates the rule engine + builder UI; `ai_variants` (bool) gates Claude generation. Both added to `plans.features` JSONB and to `FEATURE_ENFORCEMENT` (subscription.py) flipped `inert→enforced` in the same PR (coverage test must stay green).
- **Upsell angle.** Routing rules are the **Pro hook** — "one QR, many audiences" is a tangible reason to leave Starter (alongside A/B, which it complements). AI variant generation is the **Agency hook** — agencies managing 50+ client QRs pay for the time saved hand-writing multilingual copy. AI generation is the *only* clean AI differentiator in the product and a natural "wow" in sales demos. Because AI runs at write time (bounded, batched), its marginal cost is predictable and small relative to the Agency price point; we cap generations/QR to control spend.

## 9. Success Metrics & KPIs

**Activation**
- ≥ **20%** of Pro/Agency workspaces create at least one routing rule within 30 days of GA.
- ≥ **35%** of multi-region/event/retail-tagged accounts (by use-case page entry or onboarding answer) activate routing within 60 days.

**Adoption / engagement**
- ≥ **15%** of *new* dynamic QRs created by Pro+ workspaces carry ≥ 1 routing rule by day 90.
- Median rules-per-routed-QR ≥ **2** (proves multi-variant intent, not a toggle).
- ≥ **40%** of Agency workspaces that open the Routing tab use **AI variant generation** at least once.

**Performance (hard guardrail)**
- Added Worker p95 latency from `evaluateRouting` ≤ **1ms**; **zero** new origin/backend calls on the scan path (verified by Worker timing logs).

**Revenue / retention**
- Routing named as a purchase driver in ≥ **10%** of Pro upgrade survey responses within two quarters.
- Net-revenue-retention lift on routing-active Agency cohort ≥ **5pts** vs non-active (workflow lock-in: rules + cached variants = switching cost).
- AI variant publish-rate (generated → saved) ≥ **50%** (validates copy quality, not just curiosity clicks).

## 10. Rollout Plan

- **Phase 0 — Schema + flags (internal).** Migration 0015 (engine only): ensure `qr_destinations.rules`, seed/flip `routing_rules` (Pro/Agency). `ai_variants` + its table land in the Phase-2 migration. Register `routing_rules` in `FEATURE_ENFORCEMENT`. No user surface.
- **Phase 1 — Routing engine MVP (flagged beta, Pro+).**
  - BE: rule schema validation, `build_kv_content` emits `routing`, gate on write, **+ the subscription-downgrade → `resync_workspace_qrs` hook** (pulled into v1 so the Worker entitlement guard is actually effective).
  - Worker: `evaluateRouting` for `website` (destination variants) + HTML types (content variants), sticky cookie, default fallback, entitlement guard.
  - FE: Routing tab + rule builder behind `routing_rules`; relabel A/B results as routing variants.
  - **Acceptance:** a Pro QR with rules `{DE→A, default→B}` serves A to a DE scanner and B otherwise, sticks across repeat scans, records per-variant scans, adds ≤1ms p95 with no backend call; Free/Starter sees the upgrade gate; a downgraded (Pro→Free) workspace's QR collapses to the default destination at the edge after resync; a malformed rule is rejected at write.
- **Phase 2 — AI variant generation (Agency, beta → GA).**
  - BE: Claude pre-generation endpoint (write-time, batched, capped per QR), editable drafts, KV `content.variants` snapshot.
  - FE: "Generate localized variants" flow with editable preview, Agency-gated.
  - **Acceptance:** an Agency workspace generates es/fr/de variants from base content, edits and publishes; a `lang=es` scanner sees the Spanish variant rendered from KV (no scan-time AI call); Pro-without-Agency sees the AI button disabled with upsell.
- **Phase 3 — GA + polish.** Remove beta flag; add matched-rule analytics breakdown; persona-tone presets; rollout to all Pro/Agency; optional sticky-cookie cache-bust token. *(The downgrade-resync hook moved up to Phase 1 per eng-review — no longer deferred here.)*

## 11. Risks, Edge Cases & Open Questions

**Risks / edge cases**
- **Edge latency (top risk).** Mitigated by design: rules and variants are pre-computed into KV; `evaluateRouting` is pure CPU over `request.cf` + cookie. **No** Claude call, **no** backend call on scan. Enforced as a release guardrail (≤1ms p95).
- **Entitlement-snapshot staleness on downgrade (known KV gap).** KV `entitlements`/`routing` are write-time snapshots; a Pro→Free downgrade leaves stale routing in old QRs, and the Worker `=== false` guard alone is ineffective if the QR is never re-saved (the snapshot stays `true`). Mitigation (per eng-review): the `resync_workspace_qrs()` background hook on subscription downgrade ships in **Phase 1**, not Phase 3, so a downgrade actively rebuilds KV to the live entitlement; the Worker `=== false` guard stays as defense-in-depth.
- **AI copy quality / hallucination.** Generated variants are **drafts requiring explicit save** — never auto-published. Cap generations per QR; log prompt+output for review; provide a one-click revert to base.
- **Stale signed URLs in HTML variants.** Variants reuse the same edge-signed Storage URLs (1-hour expiry) as base content — no new exposure, but localized variants must re-sign at edge like base content.
- **Rule conflicts / no-match.** Deterministic first-match ordering + a *mandatory* default guarantees every scan resolves; UI blocks save without a default.
- **Timezone correctness.** `request.cf.timezone` drives scanner-local windows; "fixed timezone" mode (organizer's TZ) is an explicit per-rule toggle to avoid silent mis-routing.
- **Sticky-cookie vs rule change.** If an owner edits rules, a pinned scanner could see the old variant until cookie expiry. v1 accepts this (consistency-first, like A/B); Phase 3 adds an optional "re-evaluate on change" cache-bust token in KV.

**Open Questions**
1. When both routing rules *and* A/B weights exist on a destination set, does a matched rule win outright (recommended) or split-within-rule? v1 = rule wins, weight is the no-match fallback.
2. `ai_variants` — meter as unlimited-at-Agency or cap generations/QR/month to bound LLM spend? (Recommend a soft cap, e.g. 10 generations/QR.)
3. Persona variants in v1, or locale-only first with persona as a tone toggle? (Recommend locale-first.)
4. Do localized HTML variants need full multilingual page-design (RTL, font swaps) in v1, or copy-only with shared design? (Recommend copy-only first.)
5. City-level rules demand — defer to Phase 3 given rule-cardinality cost?

## 12. Dependencies

- **`qr_destinations.rules` JSONB** — already scaffolded; ensure/extend in migration 0015 (slot 0015 in the 0014–0018 roadmap sequence; current DB highest is 0013).
- **KV write path** — `build_kv_content`, `build_entitlements`, `sync_qr_to_kv`, `resync_workspace_qrs` (`cloudflare_kv.py`); add `routing` block + `content.variants`.
- **Worker A/B primitives** — `src/utils/ab.js`, `handlers/websiteRedirect.js`, sticky-cookie pattern, `recordScan` variant attribution (`src/utils/scan.js`).
- **Plan engine** — `check_feature`/`resolve_plan`/`FEATURE_ENFORCEMENT` (subscription.py); `canAccessFeature` (FE `plan-features.ts`).
- **Claude API** (Phase 2) — backend write-time generation; needs an API key/secret in backend env and a batched, capped call wrapper. **Anthropic dependency** — model id + pricing to be confirmed against current Claude API reference at build time.
- **Subscription downgrade hook** (Phase 3) — the currently-missing plan-change → `resync_workspace_qrs()` background trigger (BE audit gap) to proactively flush stale KV entitlements.
- **Analytics surfaces** — `useABResults`/`ABResultsCard` (relabel), `scans_by_variant` counters (already populated by `recordScan`).

## Appendix — Key Files

| Concern | File |
|---|---|
| Rule schema, write gate, validation | `qr_backend/src/api/routes/qr.py` (`QRDestination` model, `SELECT_WITH_RELATIONS`, create/update) |
| KV snapshot (`routing` + `content.variants`) | `qr_backend/src/utilities/cloudflare_kv.py` (`build_kv_content`/`sync_qr_to_kv`/`resync_workspace_qrs`) |
| AI variant generation (Phase 2) | new `qr_backend/src/utilities/ai_variants.py` (Claude write-time, capped) |
| Gating | `qr_backend/src/api/routes/subscription.py` (`FEATURE_ENFORCEMENT`), `qr_frontend/src/lib/plan-features.ts` |
| Worker routing engine | new `qr_cf_code/src/utils/routing.js`; wired in `src/index.js`, `src/handlers/websiteRedirect.js`, `src/handlers/qrRouter.js` |
| Sticky cookie + scan attribution | `qr_cf_code/src/utils/ab.js`, `qr_cf_code/src/utils/scan.js` |
| Builder / detail UI | `qr_frontend/src/components/org/qrs/details/` (new RoutingCard), `qr_frontend/src/app/org/[slug]/(builder)/build/` |
| Migration | `qr_backend/migrations/0015_routing_rules.sql` (flag flips + ensure `rules` column) |
