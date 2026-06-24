# Qravio — Feature Roadmap Index

> Provenance: feature-discovery run **2026-06-24** (codebase audit + competitor/AI/analytics research → 12 scored candidates).
> **All 12 candidates now have a full PRD + TRD** at repo root (`<SLUG>_PRD.md` / `<SLUG>_TRD.md`).
> The top 5 were additionally **eng-reviewed** (`/plan-eng-review`) and revised; the 7 runners-up are first-draft specs
> generated with the same grounding + the five-review lessons baked in (correct migration flag-flip convention,
> migration-ships-only-this-phase, strict gating, accurate denominators, AI backend-only, DMARC/cron deploy gates).
>
> **Scoring** = `(impact×2) + (moat+growth+retention+revenue) − effort`, `+2` if AI- or analytics-themed. Impact/Effort/fit 1–5.

---

## Migration sequence (reserved + assigned)

Migrations are applied by hand in the Supabase SQL editor; current DB highest **applied** = `0013`. All 12 specs hold a unique slot:

| Slot | Feature | Spec status | Needs migration? |
|------|---------|-------------|------------------|
| 0013 | `retargeting_pixels` | applied (live) | — |
| 0014 | `AI_SCAN_ANALYST` | eng-reviewed ✅ | yes (`0014_ai_analyst.sql`) |
| 0015 | `EDGE_AI_PERSONALIZED_ROUTING` | eng-reviewed ✅ | yes (`0015_routing_rules.sql`; AI-variant tables → Phase 2 migration) |
| 0016 | `SCAN_CONVERSION_FUNNEL` | eng-reviewed ✅ | yes (`0016_scan_conversion_funnel.sql`; revenue tables → Phase 2 migration) |
| 0017 | `SHAREABLE_CLIENT_REPORTS` | eng-reviewed ✅ | yes (`0017_report_links.sql`) |
| 0018 | `SCHEDULED_REPORTS_ALERTS` | eng-reviewed ✅ | yes (`0018_scheduled_reports.sql`) |
| 0019 | `DEEP_AUDIENCE_ANALYTICS` | draft | yes (`0019_scans_by_platform.sql` — platform counter keys) |
| 0020 | `OUTBOUND_WEBHOOKS` | draft | yes (`0020_outbound_webhooks.sql` — endpoints + deliveries) |
| 0021 | `GOOGLE_REVIEW_FUNNEL_QR` | draft | yes (`0021_google_review_funnel.sql` — new QR type) |
| 0022 | `CAMPAIGN_TAGS_ROLLUP` | draft | yes (`0022_campaign_tags_rollup.sql` — tags + join) |
| 0023 | `WALLET_PASSES` | draft | yes (`0023_wallet_passes.sql` — passes + registrations) |
| 0024 | `AI_BUSINESS_CARD_OCR` | draft | minimal (`0024_ai_business_card_ocr.sql` — flag + usage meter; core endpoint needs no schema) |
| 0025 | `PRINT_READY_EXPORT` | draft | flag-only (`0025_print_export.sql`) |

**Next free migration slot = `0026`.** When building, apply migrations in slot order; re-confirm the highest *applied* number against the DB first.

---

## Priority order (full slate, by score)

| Score | Feature | Category | Impact | Effort | Gate | Spec |
|------:|---------|----------|:------:|:------:|------|------|
| 28 | AI Scan Analyst (ask-your-scans) | AI | 5 | 3 | Pro (`ai_analyst`) | reviewed ✅ |
| 28 | Edge AI Personalized Routing | AI | 5 | 4 | Pro + Agency (`routing_rules`/`ai_variants`) | reviewed ✅ |
| 26 | Scan→Action Conversion Funnel | Analytics | 5 | 3 | Pro (`advanced_analytics`) | reviewed ✅ |
| 24 | Shareable White-Label Reports | Revenue | 4 | 2 | Pro/Agency (`shareable_reports`) | reviewed ✅ |
| 24 | Scheduled & PDF Reports + Alerts | Analytics | 4 | 2 | Starter+ (`scheduled_reports`) | reviewed ✅ |
| 22 | Deep Audience Analytics (OS/Browser + Geo Map + Heatmap) | Analytics | 4 | 2 | Pro (`advanced_analytics`) | draft |
| 21 | Outbound Webhooks + Zapier/Make | Enterprise | 4 | 3 | Pro + Agency (`outbound_webhooks`) | draft |
| 20 | Google Review Funnel QR (feedback-first) | Growth | 4 | 2 | Starter+ (`dynamic_qr_types`) | draft |
| 19 | Campaign Tags + Multi-QR Rollup | Retention | 3 | 2 | Pro (`advanced_analytics`) | draft |
| 18 | Apple/Google Wallet Passes | Retention | 4 | 4 | Pro + Agency | draft |
| 17 | AI Business-Card OCR → vCard | AI | 3 | 2 | Starter+ (or metered Free hook) | draft |
| 13 | Print-Ready QR Asset & Poster Export | Revenue | 3 | 3 | Pro / Agency | draft |

---

## Runner-up build notes (the 7 first-draft specs)

Each has a full `<SLUG>_PRD.md` + `<SLUG>_TRD.md`. Headline build shape + the main risk:

1. **Deep Audience Analytics** (`0019`) — parse the already-stored `user_agent` into OS/browser **on read**, surface city drill-down + a 7×24 day×hour heatmap. Reuses the `_fetch_windowed_events` read path (accurate counts from `qr_scan_events`, not the lossy counter). Risk: lazy-load the map lib; backfill is avoided by parse-on-read. Markets the cookieless daily-hash model as GDPR-exempt.

2. **Outbound Webhooks** (`0020`) — signed `POST` callbacks on scan / milestone / lead-submit, dispatched off the `/internal/scans` + lead-submit ingestion via `BackgroundTasks`, HMAC per-workspace secret. Risk: retry/backoff + dead-letter + delivery log, and **SSRF** (validate/allowlist target URLs, block internal ranges). Closes the API PRD's deferred webhooks-out gap.

3. **Google Review Funnel QR** (`0021`) — new dynamic QR type via the 7-step checklist; **feedback-first** (rate → happy to Google, unhappy to a private form reusing lead-capture + Resend). Risk: stay on the right side of Google ToS (never suppress reviews); keep the Worker template + React preview in sync. Strong SEO/GEO wedge.

4. **Campaign Tags + Rollup** (`0022`) — cross-folder tags + a tag-grouped aggregate over `qr_scan_counters` + head-to-head QR compare. Reuses `advanced_analytics`. Risk: aggregation perf on big workspaces (index the join); rollup is read-only so the counter RMW gap is moot.

5. **Wallet Passes** (`0023`) — Apple PassKit `.pkpass` signing + Google Wallet API + a push-update pipeline, surfaced as Add-to-Wallet on coupon/event QRs. Heaviest non-AI build; phase Apple → Google → push. Risk: developer certs + signing infra + registration webhooks.

6. **AI Business-Card OCR** (`0024`) — Claude **haiku-4-5** vision parses an uploaded card into the existing `qr_vcard_details` fields, **confirm-before-save**, metered/capped (mirrors `ai_analyst_usage`). Risk: commodity capability (value is integration); accuracy needs an edit step. Core endpoint needs no schema; only a flag + usage meter.

7. **Print-Ready Export** (`0025`) — WeasyPrint HTML/CSS→PDF with bleed/crop marks, multi-QR sheets, poster templates. Risk: print fidelity (≥300 DPI, 3mm bleed; RGB-only, CMYK is a print-shop caveat). Pairs with bulk generation.

---

## How to promote a draft to build-ready

1. Run `/plan-eng-review` on the chosen `<SLUG>_PRD.md` + `_TRD.md` (the 7 runners-up are first drafts, not yet review-hardened).
2. Re-confirm the highest **applied** migration number against the DB; the spec's reserved slot assumes `0013` is live and `0014–0025` are unapplied.
3. Implement; wire the entitlement flag into `build_entitlements` + `FEATURE_ENFORCEMENT` (inert→enforced same PR, coverage test green); mirror any Worker template against its React preview; for email features publish `_dmarc.qravio.app` first; for new crons deploy the prod worker.

> **Watch the migration flag-flip:** always `lower(name) IN (...) AND coalesce(is_custom,false)=false` with `coalesce(features,'{}')`, never a bare case-sensitive `WHERE name IN (...)` (a bug that hit 3 specs before it was caught).
