# PRD — Apple/Google Wallet Passes (loyalty, coupon, ticket)

**Status:** Draft · **Author:** Product · **Date:** 2026-06-24

**Rev (2026-06-24, post eng-review):** Pressure-tested as the heaviest build; scope held at Apple-only Phase 1 (Google/push-geofence correctly deferred). Migration-slot reservation tightened — highest *applied* is 0013 and **0014–0022 do not exist as files**, so the doc now states 0023 is a forward reservation requiring a pre-apply collision check (`ls migrations/`), not an implication that 0014–0018 are taken on disk. Added explicit pass-update idempotency (a monotonically-increasing `update_tag`/`updated_at` drives PassKit `passesUpdatedSince` and de-duped APNs pushes), called out that the lead-submit row-count limiter **does not transfer** to the install route (needs an IP-bucket/edge limiter since installs persist no countable row), specified the exact public-only `excluded_routes` prefix to avoid leaking the authenticated signing-config routes, and flagged `.p12` upload as untrusted-crypto-input parsing that must be size-capped + sandboxed. Push delivery downgraded from "BackgroundTasks with retry" to "BackgroundTasks best-effort + a durable re-drive" since in-process tasks die on a Render dyno restart.

**Priority:** Strategic — high retention value, heaviest non-AI build. This is the only roadmap feature requiring third-party signing infrastructure (Apple PassKit certs + Google Wallet REST onboarding) and a push pipeline, so it is explicitly **phased** (Apple first → Google second → push third) and is slower to ship than every prior coming-soon feature.
**Tiers:** Pro + Agency. New `wallet_passes` flag, seeded `false` everywhere by this feature's migration, flipped `true` for Pro + Agency in the same PR. Push-update geofencing rides the same flag (no separate flag in v1).
**Plan flags:** `wallet_passes` (bool) — new; registered in `FEATURE_ENFORCEMENT` as `inert` at Phase 0, flipped `enforced` when the Apple write path lands (Phase 1).
**Split from:** Natural extension of the existing **coupon** and **event** dynamic QR types (`CouponContent.tsx`, `EventContent.tsx`, `couponPage.js`, `eventPage.js`). Loyalty is introduced as a thin new sub-type on the same surface, not a brand-new QR primitive.
**Migration:** Reserved slot **0023** (`wallet_passes` + `wallet_signing_config` + `pass_registrations` + `qr_loyalty_details` tables, flag flip). **Slot reservation is forward-looking only:** the highest migration file on disk is `0013` — files `0014`–`0022` do **not** exist, so 0023 is a deliberately-spaced reservation, *not* a claim that 0014–0018 are taken. The implementer **must** re-run `ls qr_backend/migrations/` immediately before applying and renumber to the next free slot if anything landed in between (no gaps-tolerated assumption). Phases 2–3 (Google + push-geofence) ship **additive** columns/tables in later migrations — slot 0023 ships only the schema Phase 1 needs.

---

## 1. TL;DR / Summary

Qravio already lets users build **coupon** and **event** dynamic QRs whose scan pages render a landing page. This feature adds an **"Add to Apple Wallet / Add to Google Wallet"** button to those scan pages, plus a new **loyalty** sub-type, turning a one-time scan into a persistent pass that lives on the visitor's phone. Because passes are **push-updatable**, a merchant can change a coupon's discount, an event's gate/time, or a loyalty stamp count *after* distribution, and the pass updates silently on every holder's device. Optional **geofenced re-engagement** fires a wallet lock-screen notification when the holder is near the merchant's location.

The hard parts are real backend infrastructure, not templates: **Apple `.pkpass` signing** (Pass Type ID cert + private key, signed on the backend — never the edge), the **Google Wallet REST API** (service-account JWT to mint "Save to Google Wallet" links), and a **push-update service** (APNs for Apple pass refresh, Google Wallet `patch` for Google). Apple/Google both call back via **device-registration webhooks** so we know which passes to push. Gate: Pro + Agency, new `wallet_passes` flag. Effort is high; retention value is the highest on the roadmap (a pass in the wallet is a re-marketing channel the competitor can't reach).

## 2. Problem & Motivation

**Strategic gap.** Qravio's coupon/event/loyalty QRs end at the scan. A scanned coupon is screenshotted or forgotten; an event ticket lives in an email; a loyalty card is a paper punch card. Every category leader — Uniqode/Beaconstac, Bitly, QR Tiger — ships wallet passes on their business/agency tiers, and it is the single feature most requested by retail/F&B/events buyers because **a pass on the phone is a recurring touchpoint, not a one-shot redirect.** We are below table stakes for the verticals (retail loyalty, ticketed events, coupon campaigns) where dynamic QR retention matters most.

**Why now / why it fits.** The buyer-facing surface already exists. We have:
- The **coupon** QR type (`CouponContent.tsx`, `couponPage.js`, the `coupon` branch in `qr.py` ~line 1069 reading `discount_type`) — a pass's coupon fields map almost 1:1.
- The **event** QR type (`EventContent.tsx`, `eventPage.js`) — maps to a PassKit `eventTicket`.
- The full new-QR-type seam (7-step house process), KV sync (`write_to_kv` / `build_kv_content`), and edge entitlements (`build_entitlements`).

**Why it is the heaviest build.** Unlike Lead Capture / Retargeting (which reused existing tables and the Worker render path), passes need **certificate-backed signing** and a **two-way push pipeline**. Apple requires a Pass Type ID certificate + WWDR intermediate; signing must happen server-side with the private key (a Render-side service, never in the Worker — the Worker has no crypto key custody and signing on the edge would leak the key). Google requires Wallet API console onboarding + a service account. Pass **updates** require us to host the registration/push web service endpoints Apple's `PKAddPassButton` flow calls back into. This is why we phase it.

**Retention thesis.** A wallet pass converts a dynamic QR from a redirect into an owned re-engagement channel: push a "20% off this weekend" update to every coupon holder, bump a loyalty stamp on the next scan, or geofence-notify a ticket holder at the venue. That is a switching-cost moat for Agency clients and a concrete Pro→Agency and Starter→Pro upgrade lever.

## 3. Goals & Non-Goals

**Goals**
- Issue valid, installable **Apple `.pkpass`** and **Google Wallet** passes derived from a coupon, event, or loyalty QR.
- Surface an **Add-to-Wallet** button on the existing coupon/event/loyalty scan page (platform-detected: Apple button on iOS, Google button on Android, both on desktop).
- **Push-updatable fields**: editing the underlying QR's pass content updates already-distributed passes (Apple via APNs refresh, Google via REST `patch`).
- **Geofenced re-engagement**: optional lock-screen relevance notification when the holder nears a merchant location (Apple `locations`, Google `locations`).
- Per-workspace **signing config** (Apple Pass Type ID + cert/key, Google issuer ID + service account) stored encrypted, never exposed to the frontend or Worker.
- Gate the whole feature behind `wallet_passes` (Pro + Agency).
- **No PII leakage**: the public pass-install and registration endpoints expose only pass content the merchant authored — never raw scan rows, `ip_hash`, `session_id`, or member data.

**Non-Goals**
- Pass signing on the Cloudflare Worker (security non-starter — signing stays on the backend).
- Wallet passes for QR types other than coupon/event/loyalty in v1 (no vcard/website passes).
- Apple Pass NFC / value-add (PassKit NFC, payment) — out of scope.
- Per-pass personalization at scale beyond the merchant's authored template (no AI-generated per-holder copy in v1; any future AI copy runs backend-side only).
- Real-time inventory/seat assignment for tickets (event QR stays informational).
- Self-serve certificate generation UX in v1 (Apple cert upload is a guided manual flow; auto-provisioning is future).

## 4. Target Users & Personas

- **Reena — Retail/F&B Owner (loyalty, primary).** Runs a coffee chain on Pro. Wants a "buy 9 get 1 free" loyalty pass customers add once and she can update (stamp count, current promo) without reprinting anything. The geofence "you're nearby, 1 stamp from a free coffee" is her dream.
- **Karthik — Event Organizer (ticket).** Sells tickets to meetups/conferences. Wants attendees to add a wallet ticket; if the venue or time changes, every ticket updates silently. Currently uses a separate ticketing tool — passes let him consolidate.
- **Priya — Agency Owner (Agency).** Manages coupon + loyalty campaigns for ~25 SMB clients. Wants branded passes per client and the ability to push a coupon update across a client's whole holder base from one dashboard. Wallet passes are a headline she can sell.
- **Maya — The end customer / pass holder (no account).** Scans a QR, taps "Add to Apple/Google Wallet," and the pass lives on her phone. Never logs in to Qravio. Receives updates and geofence pings.
- **Internal: Sales/Success.** Uses "wallet loyalty + push updates" as the concrete Pro+/Agency upsell against Uniqode and Bitly.

## 5. User Stories

- As a **loyalty merchant**, I want customers to add a punch-card pass to their wallet, so that I have a recurring touchpoint instead of a paper card.
- As a **merchant**, I want to edit a coupon/loyalty/event pass once and have it update on every holder's phone, so that I never reissue a campaign.
- As an **event organizer**, I want attendees to hold a wallet ticket that auto-updates if the venue/time changes, so that no one shows up at the wrong place.
- As a **merchant**, I want a lock-screen notification to surface my pass when the holder is near my store, so that I drive return visits.
- As an **Agency owner**, I want passes branded with my client's logo/color, so that the pass looks like the client's own brand.
- As a **workspace owner**, I want to upload my Apple Pass Type ID cert once and connect Google Wallet once, so that all my passes sign correctly.
- As a **pass holder with no account**, I want a one-tap Add-to-Wallet button that detects my platform, so that installation is frictionless.
- As **Qravio**, I want signing keys held only on the backend and never shipped to the edge or frontend, so that no certificate can leak.

## 6. UX / Product Flow

**A. One-time workspace setup (owner, in-app)**
1. New **Settings → Wallet Passes** section (`org/[slug]/(dash)/settings`, sibling to the existing PixelsSection/BrandingSection pattern). Gated by `canAccessFeature(sub, 'wallet_passes')`; Free/Starter see an upgrade gate.
2. **Apple:** guided upload of the Pass Type ID certificate (`.p12`) + the Apple Team ID + Pass Type Identifier. Stored encrypted in `wallet_passes` signing config (per-workspace). A "Test pass" button signs and downloads a sample `.pkpass` to validate the cert.
3. **Google (Phase 2):** "Connect Google Wallet" pastes the Issuer ID; the service-account JWT used to sign Save links lives in backend env/secrets (one Qravio service account per issuer class), never per-workspace in the browser.

**B. Authoring a pass (owner/editor, in the QR builder)**
1. On the **coupon / event / loyalty** content form (`content-types/CouponContent.tsx`, `EventContent.tsx`, new `LoyaltyContent.tsx`) the builder adds a **"Wallet Pass"** toggle + a pass-fields panel (header/primary/secondary fields, background color, logo from `workspace_branding`, expiry, geofence locations).
2. Saving the QR writes the pass template alongside the QR; `build_kv_content` adds a small `wallet` block to KV so the **scan page** knows to render the Add-to-Wallet button and which `pass_id` to link. **Signing never happens in KV/Worker** — the button points at a backend install URL.

**C. Installing a pass (public, no login — the scan page)**
1. Customer scans the coupon/event/loyalty QR → Worker renders the existing landing page (`couponPage.js` / `eventPage.js` / new loyalty page) with a platform-detected **Add to Apple/Google Wallet** button (button asset only; no signing on the edge).
2. Tapping it hits a **public backend route** — `GET /wallet/apple/{pass_id}` returns the freshly-signed `.pkpass` (content-type `application/vnd.apple.pkpass`); `GET /wallet/google/{pass_id}` 302s to the Google "Save to Google Wallet" link minted from the service-account JWT. These routes are added to `excluded_routes` in `main.py` (public, no Bearer), token-scoped to the `pass_id`.
3. On install, Apple calls Qravio's **registration webhook** (`POST /wallet/apple/v1/devices/...`, the PassKit web-service contract) so we record the device→pass mapping in `pass_registrations`. Google registration is implicit via the issued object id.

**D. Updating distributed passes (owner action)**
1. Editing the QR's pass fields (or bumping a loyalty stamp) bumps a monotonic **`update_tag`** on the `wallet_passes` row and **enqueues a push**: APNs notification to every registered Apple device for that pass → device calls back `GET /wallet/apple/v1/passes/...` (and the `passesUpdatedSince` serials endpoint compares against `update_tag`) → backend returns the re-signed pass; Google → REST `patch` on the object. The push is **idempotent**: re-firing for the same `update_tag` is a no-op, so a retry never double-notifies. Push runs **backend-side, asynchronously** (FastAPI `BackgroundTasks`, best-effort), never on the Worker scan hot path. Because in-process background tasks die on a Render dyno restart, a bounded **durable re-drive** (re-push any registration whose acknowledged tag lags the current `update_tag`) is the reliability backstop — not a guarantee that every in-flight push survives a deploy.
2. Geofence updates write `locations` into the pass; the relevance notification is handled by the OS once the pass is updated.

**E. Lifecycle / gating**
- Workspace **downgrades below Pro** → install routes return a clean "pass unavailable" response and new passes can't be authored (gate re-checked at write time and at install time). Existing installed passes are not force-revoked in v1 (documented caveat).
- Pass **deleted** → install route 404s with a branded message; no stack trace.

## 7. Scope — In (v1) vs Out/Future

**In scope (v1 = Phase 1, Apple only)**
- Migration **0023**: `wallet_passes` table (pass template + per-workspace signing config) + `pass_registrations` table (device↔pass) + `wallet_passes` flag flip (Pro/Agency).
- New **loyalty** sub-type wired through the 7-step new-type seam (Literal value, `build_kv_content` branch, `SELECT_WITH_RELATIONS` join + pydantic model in `qr.py`, `dynamic_qr_types` seed, Worker page+template, React preview + content form + TemplatePicker/PagePreview cases).
- Apple `.pkpass` **signing service** (backend; cert/key custody; WWDR chain).
- Public install route `GET /wallet/apple/{pass_id}` + the PassKit **web-service endpoints** (register/unregister/get-serials/get-latest) + APNs push on update.
- Add-to-Apple-Wallet button on coupon/event/loyalty scan pages (Worker template + mirrored React preview).
- Settings → Wallet Passes (Apple cert upload + test pass).
- `wallet_passes` gate, registered `inert` → flipped `enforced` in this PR.

**Out / Future**
- **Phase 2:** Google Wallet (Save link via service-account JWT, Google object `patch` updates, Add-to-Google-Wallet button).
- **Phase 3:** Geofenced re-engagement (`locations` + relevance) and bulk push campaigns from a passes dashboard.
- Self-serve Apple cert auto-provisioning.
- Wallet passes for other QR types (vcard "business card pass," etc.).
- AI-authored per-segment pass copy (backend-side only, future).
- NFC / payment passes.

## 8. Pricing & Packaging

| Tier | Wallet passes? | Push updates | Geofence (Phase 3) |
|---|---|---|---|
| Free | ❌ upgrade gate | — | — |
| Starter | ❌ upgrade gate | — | — |
| **Pro** | ✅ | ✅ | ✅ |
| **Agency** | ✅ + branded per-client passes | ✅ | ✅ |

- **New flag:** `wallet_passes` (bool) in `plans.features` JSONB. Seeded `false` everywhere, flipped `true` for Pro/Agency by migration 0023 using the **house flag-flip convention** (NULL-coalesce + `is_custom=false` guard — never a bare `WHERE name IN (...)`). Added to `FEATURE_ENFORCEMENT` as `inert` at Phase 0, flipped `enforced` in the Phase 1 PR. `test_feature_gate_coverage` must stay green.
- **Branding** on passes rides the existing `white_labeling` (Agency) flag via `build_entitlements().brand` — no new flag. Pro passes use the workspace's `workspace_branding` logo/color if present, else Qravio defaults.
- **Upsell angle:** Wallet passes are the headline retention feature for retail/events. Starter→Pro is gated on access; Agency adds per-client branded passes and is the pitch for agencies running loyalty programs. Sales demo = install a live loyalty pass and push a stamp update on stage.

## 9. Success Metrics & KPIs

Denominators come from **`qr_scan_events` raw rows** (accurate uniques via `session_id`), never the lossy `qr_scan_counters` aggregates.

- **Activation:** ≥ 25% of Pro/Agency workspaces that own a coupon/event/loyalty QR enable a wallet pass within 45 days of GA.
- **Install conversion:** ≥ 15% of *scans on a pass-enabled QR* result in an Add-to-Wallet tap (measured backend-side at the install route, deduped per `session_id`); ≥ 60% of taps complete install (Apple registration webhook fired).
- **Update leverage:** ≥ 30% of pass-enabled workspaces push at least one update within 60 days (proves the recurring-channel value).
- **Retention:** pass-enabling workspaces show ≥ 6pp lower 90-day churn than matched non-enablers; ≥ 40% of installed passes remain registered (un-deleted) at 30 days.
- **Upgrade lift:** ≥ 7% relative increase in Starter→Pro upgrades among workspaces that hit the wallet-passes upgrade gate.
- **Reliability:** ≥ 99% of `.pkpass` signing requests succeed; APNs push delivery (registered → pass refreshed) ≥ 95%; zero signing-key exposure incidents; < 0.1% install-route error rate.
- **Geofence (Phase 3):** ≥ 5% of geofenced-pass holders trigger a return-visit scan within 30 days.

## 10. Risks, Edge Cases & Open Questions

**Risks & mitigations**
- **Certificate custody (highest).** Apple cert/key must be encrypted at rest, decrypted only in the signing service, and **never** sent to the frontend or Worker. Mitigation: store in `wallet_passes` signing config encrypted (KMS/Fernet via a backend secret), sign only in the backend; the Worker scan page links to a backend install URL, never to a key.
- **Edge signing temptation.** Signing a `.pkpass` requires PKCS#7 with the private key; doing it on the Worker would mean shipping the key to Cloudflare — a hard no. Mitigation: the only Worker change is rendering an Add-to-Wallet button that points at the backend.
- **APNs/Google push pipeline reliability.** Registration webhooks + push are stateful and easy to get wrong. Mitigation: `pass_registrations` is the source of truth; pushes are async/backend-side with retry; failures logged, never block scans.
- **Apple/Google onboarding latency.** Apple Pass Type ID cert and Google Wallet API console approval are external, slow, and per-merchant (Apple) or per-Qravio (Google). Mitigation: phase Apple first (per-workspace cert upload), Google second (Qravio-level service account); document the cert flow.
- **Stale gate after downgrade.** Re-check `await check_feature(ws, 'wallet_passes', db)` at **both** author time and install time (`resolve_plan()` 30s cache makes this cheap). Installed passes are not force-killed in v1 (documented).
- **PII on public surfaces.** The install + PassKit web-service routes return only merchant-authored pass content. Strict allowlist test asserts no `ip_hash`, `session_id`, raw scan rows, lead data, or member info ever appear in a pass payload.

**Edge cases**
- Holder on desktop → show both buttons; Apple button downloads `.pkpass`, Google opens Save link.
- Workspace has no Apple cert uploaded → button hidden for Apple, shown for Google (Phase 2); test pass blocked with a clear setup prompt.
- Coupon expiry passed → pass shows expired state (Apple `expirationDate`/`voided`), not an error.
- Loyalty stamp bump on a deleted pass → no-op, logged.
- Geofence with >10 locations → Apple caps `locations`; clamp silently.

**Open Questions**
1. **Push transport for Apple:** direct APNs (token-based auth key) vs a managed provider? Recommend token-based APNs auth key held as a Qravio backend secret. Confirm with eng.
2. **Google service account scope:** one Qravio issuer for all workspaces vs per-workspace issuer? Recommend one Qravio issuer with per-workspace class IDs (simpler onboarding). Confirm.
3. **Cert encryption mechanism:** Fernet via backend secret vs cloud KMS? Defer to eng; must not be plaintext.
4. **Does push need a cron?** Update pushes are event-driven (on QR edit), not scheduled — **no cron in v1.** If a future batch/geofence sweep needs `scheduled()`, it registers **only after `npm run deploy:prod`**.
5. **Email involvement:** if we ever email an install link, **publishing `_dmarc.qravio.app` is a GA prerequisite.** v1 is in-app + scan-page only, so no email dependency.

## 11. Rollout Plan

- **Phase 0 — Migration & flag (inert).** Ship migration **0023**: `wallet_passes` + `pass_registrations` tables, per-workspace signing config columns, `wallet_passes` seeded `false` everywhere then flipped `true` for Pro/Agency (house flag-flip convention). Add `wallet_passes` to `FEATURE_ENFORCEMENT` as `inert`. No UI. User applies 0023 in the Supabase SQL editor (current highest applied = 0013; 0014–0018 reserved by roadmap specs; 0023 reserved here).
- **Phase 1 — Apple (beta, behind build flag).** Backend signing service + install route + PassKit web-service endpoints + APNs push; loyalty sub-type via the 7-step seam; Settings cert upload + test pass; Add-to-Apple-Wallet button on coupon/event/loyalty scan pages (Worker template + mirrored React preview). Flip `wallet_passes` `inert→enforced` in the same PR. **Acceptance:** (1) a Pro workspace uploads a cert, authors a loyalty pass, and a scan → tap installs a valid `.pkpass`; (2) editing the pass pushes an update that refreshes the holder's pass via APNs; (3) install payload contains no PII (asserted); (4) Free/Starter see the gate and the install route refuses below-Pro at read time; (5) Worker scan-path latency unchanged (no signing on edge). Dogfood with 3–5 friendly retail/event accounts.
- **Phase 2 — Google (GA-extend).** Google Wallet Save link via service-account JWT, object `patch` updates, Add-to-Google-Wallet button (additive migration for any Google-specific columns — **not** in 0023). Acceptance: Android install + update parity with Apple.
- **Phase 3 — Geofence + bulk push.** `locations` relevance, a passes dashboard with bulk update/push. If a batch sweep introduces a Worker cron, it counts only after **prod worker deploy**.
- **GA gates:** signing reliability ≥ 99% and zero key-exposure incidents in beta; APNs delivery ≥ 95%; PII allowlist test green; `test_feature_gate_coverage` green.

## 12. Dependencies + Appendix

**Already-shipped primitives (reused):** coupon QR type (`CouponContent.tsx`, `couponPage.js`, `qr.py` coupon branch ~L1069); event QR type (`EventContent.tsx`, `eventPage.js`); the 7-step new-QR-type seam; KV sync (`write_to_kv`, `build_kv_content`); edge entitlements (`build_entitlements` → `brand`); `workspace_branding` (migration 0011) for pass branding; the public-route exclusion pattern in `main.py` (`excluded_routes`); the provider-webhook pattern (`razorpay_routes.py` / `mor_routes.py`) for the Apple/Google registration webhooks; `FEATURE_ENFORCEMENT` + `check_feature`.

**New external infrastructure:** Apple Pass Type ID certificate + WWDR intermediate + APNs auth key; Google Wallet API console onboarding + service account; a backend signing service (PKCS#7) — these are the long-lead items, not code.

**Must be applied/deployed first:** migration 0023; cert/key custody secret in backend env; (Phase 2) Google issuer ID + service-account secret.

**No dependency on:** the consent gate (passes carry no marketing pixels/cookies), lifecycle emails (v1 in-app/scan-page only), or AI (no model on the scan/push path).

### Appendix — Key Files

| Concern | File |
|---|---|
| Migration (tables + flag flip) | `qr_backend/migrations/0023_wallet_passes.sql` (new) |
| Pass CRUD + signing + install + PassKit web-service + push | `qr_backend/src/api/routes/wallet.py` (new), `qr_backend/src/utilities/pass_signing.py` (new) |
| Router registration | `qr_backend/src/api/endpoints.py` |
| Public route exclusion (install + webhooks) | `qr_backend/src/main.py` (`BearerTokenAuthMiddleware` excluded prefixes) |
| Gating (BE) | `qr_backend/src/api/routes/subscription.py` (`FEATURE_ENFORCEMENT`, `check_feature`) |
| KV pass block + branding | `qr_backend/src/utilities/cloudflare_kv.py` (`build_kv_content`, `build_entitlements`) |
| New loyalty type wiring | `qr_backend/src/api/routes/qr.py` (`SELECT_WITH_RELATIONS`, pydantic model, `_build_content_from_db_rows`) |
| Scan-page Add-to-Wallet button | `qr_cf_code/src/pages/coupon/`, `qr_cf_code/src/pages/event/`, `qr_cf_code/src/pages/loyalty/` (new) |
| Content forms + previews | `qr_frontend/src/components/qr-generator/content-types/{Coupon,Event,Loyalty}Content.tsx`, `qr_frontend/src/components/qr-generator/templates/` |
| Settings (cert upload) | `qr_frontend/src/app/org/[slug]/(dash)/settings/`, `WalletPassesSection.tsx` (new) |
| Gating (FE) | `qr_frontend/src/lib/plan-features.ts` (`canAccessFeature`, `wallet_passes`), `qr_frontend/src/hooks/useSubscription.ts` (`PlanFeatures`) |
