# PRD — Shareable / White-Label Client Report Links

**Status:** Draft · **Author:** Engineering · **Date:** 2026-06-24
**Priority:** Revenue — high-leverage, low-effort. Reuses three already-shipped primitives (analytics aggregates + `workspace_branding` + the HMAC password-gate pattern). No new QR type, no Worker template parity work.
**Tiers:** Pro+ shares un-branded reports (new `shareable_reports` flag); Agency adds white-label branding on the report (rides the existing `white_labeling` flag). Seeded `false` everywhere by migration 0009; this feature's migration flips Pro/Agency on for `shareable_reports`.
**Plan flags:** `shareable_reports` (bool) — new; flipped on for Pro + Agency by migration 0017. White-label rendering of the report gates on the existing `white_labeling` (Agency-only) flag.
**Split from:** `WHITE_LABEL_SETTINGS_PRD.md` (this is the direct monetization of that just-shipped feature).
**Rev (2026-06-24, post eng-review):** migration `0017` flag-flip hardened to the `is_custom` + NULL-coalesce convention; the public endpoint gets a **60s backend aggregate cache + Cloudflare edge rate-limit** (caching ships in v1 because the growth loop expects fan-out, not "if it goes viral"); the PII test is now a **strict exact-key-set allowlist**; revoke is immediate (fresh `revoked_at` read) while the 30s cache only gates plan downgrade; low-count de-anonymization accepted for v1 with a documented caveat.

---

## 1. TL;DR / Summary

Agencies manage QR campaigns on behalf of clients but have no way to show those clients results without either (a) burning a paid dashboard seat or (b) manually screenshotting analytics into a deck. This PRD adds **public, no-login, read-only analytics report URLs** — one per QR and one per campaign (folder) — rendered at `qravio.app/r/<report_token>`. Each link is gated by a signed token (the same HMAC pattern already used for password gates), exposes only **non-PII aggregates** the customer already sees in-app, and is branded with the workspace's white-label logo/color/footer from `workspace_branding`. Sharing is a Pro+ feature; **white-label-branded** sharing is Agency. Every report shared by a non-Agency workspace carries a "Powered by Qravio" footer that links home — a built-in growth loop. Effort is low because we reuse existing analytics endpoints, existing branding, and the existing HMAC signing utility; there is no new QR type and no Worker template to keep in sync.

## 2. Problem & Motivation

**The Agency reporting gap is the single clearest monetization of the white-label tier we just shipped.** White-label branding (migration 0011) currently only affects scan-time landing pages — a back-office capability the buyer never sees the ROI of directly. The reporting surface is where an agency *demonstrates value to its own paying client*, which is exactly the moment branding matters most.

Evidence from the strategic context:

- **No seat-free reporting today.** Pro caps at 10 members and Agency is the only "unlimited members" tier. An agency with 30 clients cannot give each client a viewer seat without jumping the tier or polluting their member list. There is no read-only external share surface anywhere in the app (strategic audit gap: "QR detail page has no 'share to team' or 'embed preview' feature beyond copy-link").
- **The analytics export CTAs are non-functional placeholders.** `analytics/page.tsx:148-151` ships "Download CSV/PDF" and "Schedule Weekly Report" buttons with **no `onClick` handlers**. Customers expect to share results and currently hit dead buttons — a live trust gap. A shareable link is the lightest-weight way to close it.
- **Standard for the category.** Uniqode (formerly Beaconstac), Bitly, and QR Tiger all ship a public/shareable analytics link toggle on their agency tiers. We are below table stakes here.
- **Built-in growth loop.** Every report a Pro (non-white-label) workspace shares renders "Powered by Qravio · Get yours free" linking to `/`. Reports are seen by the agency's *clients* — net-new audiences who are exactly our ICP. This is the same viral mechanic our free-tier no-watermark wedge relies on, applied to a higher-intent surface.
- **Near-zero build cost.** The three hard parts already exist: (1) analytics aggregates (`useAnalyticsSummary`, `useQRAnalytics`, `scans_by_*` counters), (2) branding snapshot (`workspace_branding` → `build_entitlements.brand`), (3) a vetted HMAC token pattern (`getPwToken` / `HMAC(INTERNAL_SECRET, …)`). We are wiring existing parts together, not building new infrastructure.

## 3. Goals & Non-Goals

**Goals**
- A public, no-login URL that renders a **read-only** analytics report for a single QR **or** a campaign (folder of QRs).
- Token-based access (unguessable, revocable, opt-in per report). No workspace data leaks beyond the explicitly shared scope.
- **Strictly non-PII** payload: aggregate counts only (scans, uniques, by-device, by-country, by-date, by-hour, top QRs). No raw scan rows, no IPs, no `ip_hash`/`session_id`, no lead submissions, no member info.
- White-label rendering (logo/color/footer) for Agency; "Powered by Qravio" footer for Pro.
- Owner/editor controls in-app: create link, copy, revoke, see view count.
- Gate sharing behind `shareable_reports` (Pro+); gate branding behind `white_labeling` (Agency).

**Non-Goals**
- PDF / CSV file export (future — the placeholder buttons stay, separate task).
- Scheduled / emailed recurring reports ("Schedule Weekly Report" button — future, needs the lifecycle-email system that doesn't exist yet).
- Password-protecting a report (future; v1 relies on the unguessable token + revocation).
- Real-time/live-updating reports (v1 reads the same aggregates the dashboard reads; refresh-on-load is fine).
- Per-client custom domains for reports (future — could ride existing custom-domain infra).
- Multi-workspace / cross-workspace rollup reports (future).

## 4. Target Users & Personas

- **Priya — Agency Owner (primary).** Runs a 12-person agency managing print + retail QR campaigns for ~25 SMB clients on the Agency tier. Wants to send each client a branded link that looks like *her* product, without giving them a login or seeing her other clients' data.
- **Dev — Freelance Marketer (Pro).** Manages 3–4 clients solo. Fine with a Qravio-branded report; the share link saves him from rebuilding a slide deck every month. He is the growth-loop seed — his clients see "Powered by Qravio."
- **Maya — The Client (report viewer, no account).** Receives a URL, opens it on her phone or desktop, sees scan totals and a map/chart. She never logs in and must never see anything beyond her own campaign. She is a future signup if the report is Qravio-branded.
- **Internal: Sales/Success.** Uses "shareable branded reporting" as a concrete Agency-tier upsell talking point against Uniqode.

## 5. User Stories

- As an **agency owner**, I want to generate a public report link for a client's campaign folder, so that I can prove ROI without giving the client a dashboard seat.
- As an **agency owner**, I want the report to show **my** logo and brand color (not Qravio's), so that it looks like my own reporting product.
- As a **Pro freelancer**, I want to share a single-QR report link, so that my client sees live numbers instead of a stale screenshot.
- As a **workspace owner**, I want to **revoke** a link instantly, so that a client who churns or a leaked URL can be cut off.
- As a **workspace owner**, I want each report to show **only aggregate, non-PII data**, so that I'm not exposing visitor identities or other clients.
- As a **report viewer with no account**, I want the link to open instantly with no login wall, so that I can check campaign results from any device.
- As **Qravio**, I want every non-Agency report to carry a "Powered by Qravio" CTA, so that shared reports become a top-of-funnel acquisition channel.

## 6. UX / Product Flow

**A. Enabling a report (owner/editor, in-app)**
1. On the **QR detail page** (`qrs/[id]`, overview tab, beside `QRAnalyticsCard`) and on the **analytics page** header (`analytics/page.tsx`, replacing the dead "Download" CTA cluster), add a **"Share report"** control. For folders, add it to the folder/campaign view.
2. Clicking it (when `canAccessFeature(sub, 'shareable_reports')` is true) opens a `ShareReportModal`: a toggle **"Public link"**, the generated URL with a **Copy** button, a **Regenerate** action, a **Revoke** action, and a live **view count**. Agency workspaces see a "Branded with your workspace logo" note; Pro workspaces see "Reports show 'Powered by Qravio'."
3. If `shareable_reports` is false (Free/Starter), the control renders a `ReportsUpgradeGate` (same pattern as the analytics paywall) instead of the modal.
4. Toggling **on** calls `POST /workspaces/{ws}/reports` → returns `{ report_token, url }`. Toggling **off** / Revoke calls `DELETE /workspaces/{ws}/reports/{id}` (soft-revoke: set `revoked_at`).

**B. Viewing a report (public, no login)**
1. Client opens `https://qravio.app/r/<report_token>`. This is served by the **Next.js marketing surface** (public route group, dark/branded), **not** the Worker — keeping the Worker scan-path untouched and avoiding KV bloat. The page is `force-dynamic`, fetches `GET /api/public/v1/reports/<token>` (public, no Bearer), and renders.
2. The backend verifies the token (HMAC + DB lookup), checks `revoked_at IS NULL`, resolves scope (single QR vs folder), pulls the **same aggregates the in-app analytics use**, applies the workspace's `analytics_retention_days` clamp, and returns a non-PII JSON payload plus a `branding` block (logo/color/footer if `white_labeling`, else Qravio defaults).
3. The page renders: header (branded logo + report title + date range), stat cards (total scans, unique visitors, scans today/period), a daily area chart, device donut, top-countries list, and (for campaign reports) a per-QR breakdown table. Footer: white-label footer (Agency) **or** "Powered by Qravio — Create your free dynamic QR" linking to `/` (Pro).
4. Each load increments `view_count` (throttled, fire-and-forget) so the owner sees engagement. No scan event is recorded — this is not a QR scan.

**C. Revocation / lifecycle**
- Revoked or unknown tokens render a clean branded "This report is no longer available" page (200, not a stack trace).
- If the workspace **downgrades below Pro**, the report endpoint returns the same "no longer available" page (gate re-checked at read time — defense against stale links after churn).

## 7. Scope

**In scope (v1)**
- `report_links` table + `shareable_reports` flag (migration 0017, flip Pro/Agency).
- Backend: report CRUD (`POST`/`GET list`/`DELETE` under `/workspaces/{ws}/reports`, JWT-gated) + **public read** (`GET /api/public/v1/reports/{token}`, no auth, token-verified).
- Two report scopes: **single QR** and **campaign = folder**.
- Non-PII aggregate payload reusing existing scan-counter aggregates + retention clamp.
- White-label branding (Agency) vs "Powered by Qravio" (Pro) in the rendered page.
- Public Next.js route `app/(marketing)/r/[token]/page.tsx` + `ShareReportModal` + gate.
- Revocation + view count.

**Out of scope / Future**
- PDF/CSV export of the report (future task; keep placeholder buttons).
- Scheduled / emailed reports (needs lifecycle-email system).
- Password/expiry on report links (future — token + revoke is v1).
- Custom-domain-served reports (`reports.client.com`).
- Lead-form conversion funnel in the report (lead data is PII-adjacent — explicitly excluded v1).
- Cross-workspace / multi-campaign rollups.

## 8. Pricing & Packaging

| Tier | Shareable reports? | Branding on report |
|---|---|---|
| Free | ❌ (upgrade gate) | — |
| Starter | ❌ (upgrade gate) | — |
| **Pro** | ✅ un-branded ("Powered by Qravio") | Qravio footer/logo |
| **Agency** | ✅ branded | Workspace logo + brand color + custom footer |

- **New flag:** `shareable_reports` (bool) in `plans.features` JSONB — added to the plan seed in migration 0017, added to `FEATURE_ENFORCEMENT` (status `inert`), then flipped to `enforced` in the same PR. Coverage test (`test_feature_gate_coverage`) must stay green.
- **Branding** does **not** get a new flag — it rides the existing `white_labeling` (Agency) flag. The report endpoint calls the existing `build_entitlements(workspace_id)` and uses its `brand` block when present.
- **Upsell angle:** This is the headline "show your client *your* brand" Agency upsell. Pro users who share Qravio-branded reports are nudged to upgrade via an in-modal "Remove Qravio branding — upgrade to Agency" line. Sales gets a concrete demo: paste a branded report URL into a deck.
- **Growth loop:** Pro reports carry a "Powered by Qravio · Create your free dynamic QR" footer linking to `/`, turning every shared report into a top-of-funnel impression in front of the agency's clients (our exact ICP).

## 9. Success Metrics & KPIs

- **Activation:** ≥ 30% of Agency workspaces create ≥ 1 report link within 30 days of GA; ≥ 12% of Pro workspaces.
- **Adoption depth:** median active Agency workspace maintains ≥ 5 live report links (one per client) within 60 days.
- **Engagement:** ≥ 40% of created report links accrue ≥ 1 external view; median views/link ≥ 8/month (signals real client usage, not just creation).
- **Revenue / retention:**
  - **Pro→Agency upgrade lift:** ≥ 8% relative increase in Pro→Agency upgrades among workspaces that created ≥ 1 report link vs. those that didn't (the "remove Qravio branding" upsell).
  - **Agency retention:** report-creating Agency workspaces show ≥ 5pp lower 90-day churn than non-creators (reporting = client switching cost).
- **Growth loop:** ≥ 1.5% click-through from "Powered by Qravio" report footers to `/`; track signups attributed to `utm_source=report` ≥ 50/month by 90 days post-GA.
- **Trust/quality:** zero PII-exposure incidents; < 0.1% of report loads error; revoke takes effect in < 5s.

## 10. Rollout Plan

- **Phase 0 — Migration & flag (inert).** Ship migration 0017 (`report_links` table + `shareable_reports` seeded false everywhere, then flipped true for Pro/Agency). Add `shareable_reports` to `FEATURE_ENFORCEMENT` as `inert`. No UI yet. User applies 0017 to Supabase.
- **Phase 1 — MVP (single-QR + campaign, internal beta behind a build flag).**
  - Backend: report CRUD + public read endpoint + token signing/verification + non-PII payload assembly (reuse scan-counter reads, apply retention clamp). Flip `shareable_reports` `inert→enforced`.
  - Frontend: `ShareReportModal`, gate, public `r/[token]` page, branding/Qravio-footer branch.
  - **Acceptance criteria:**
    1. A Pro workspace creates a single-QR report link; opening it (incognito, no session) renders aggregates with a "Powered by Qravio" footer.
    2. An Agency workspace's report renders its `workspace_branding` logo + color + custom footer, no Qravio mark.
    3. The payload contains **no** raw scan rows, IPs, `ip_hash`, `session_id`, lead data, or member info (assert in test).
    4. Revoking a link → the URL renders "no longer available" within 5s.
    5. A Free/Starter workspace sees the upgrade gate and cannot create a link; the public endpoint refuses to serve a report whose workspace is below Pro at read time.
    6. Campaign (folder) report aggregates all QRs in the folder with a per-QR breakdown.
  - Dogfood with 3–5 friendly Agency accounts; verify branding fidelity and view-count accuracy.
- **Phase 2 — GA.** Remove build flag; announce as an Agency-tier headline ("White-label client reports"). Wire the in-modal upgrade nudge for Pro. Add the report link to the analytics page header (replacing the dead export CTA).
- **Phase 3 — Future.** PDF export, scheduled/emailed reports, password/expiry on links, custom-domain-served reports.

## 11. Risks, Edge Cases & Open Questions

**Risks & mitigations**
- **Public exposure of analytics (highest risk).** Mitigated by: (1) opt-in per report — nothing is public by default; (2) unguessable HMAC-signed token (≥ 128 bits entropy) + DB row, not a guessable QR id; (3) **aggregate-only payload** — a hard allowlist of fields, with a test asserting no PII keys; (4) instant revocation; (5) `analytics_retention_days` clamp honored so a report never shows beyond the plan's window.
- **Stale gate after downgrade.** A churned agency's links must stop working. Mitigation: re-check `check_feature(ws, 'shareable_reports')` at **read time**, not just create time (`resolve_plan()`'s 30s cache makes this cheap — a downgrade takes effect within 30s). Revocation is a separate, immediate path (`revoked_at` read fresh on every load).
- **Token enumeration / scraping.** Tokens are random (160-bit) + revocable. A leaked/shared token's blast radius is bounded by a **60s server-side aggregate cache** + a **Cloudflare rate-limit rule** on the public path (eng-review), not a per-instance in-process counter (which can't share state across Render instances).
- **View-count write amplification.** Throttle `view_count` increments (in-process or via a `increment_report_views` RPC mirroring `increment_api_usage`) to avoid read-modify-write loss; this is cosmetic data, so eventual consistency is fine.
- **Branding spoofing.** Branding comes only from the report's own `workspace_branding` via `build_entitlements` — never from query params — so a viewer cannot inject a logo.

**Edge cases**
- QR/folder deleted after a link is created → render "no longer available."
- Folder with zero QRs or zero scans → render an empty-but-branded report, not an error.
- Workspace has `white_labeling` but no uploaded logo → fall back to brand color + workspace name, never Qravio mark for Agency.
- Retention shorter than the requested range → clamp silently to the allowed window.

**Open Questions**
1. **Route owner: Next.js vs Worker?** Recommend the **Next.js marketing surface** (`/r/[token]`) — keeps the Worker scan-path and KV untouched, gives us the dark/branded marketing layout for free, and avoids Worker template-parity overhead. Confirm with eng.
2. **Token = standalone HMAC or DB-row id?** Recommend a **random opaque token stored in a DB row** (simplest revocation: delete/flag the row) rather than a self-describing HMAC payload. The HMAC pattern is the *precedent*, not necessarily the literal mechanism.
3. **Should campaign = folder, or a new "campaign/tag" concept?** v1 = **folder** (exists today). The strategic gap notes tags don't exist yet; don't block on building them.
4. **Lead-form QRs:** show scan counts only (not submission data) in v1? Recommend **yes** — exclude all lead data to stay strictly non-PII.
5. **Rate limit / abuse threshold** for the public endpoint — what RPS per token before throttling? Defer exact number to eng.

## 12. Dependencies

- **Already-shipped primitives (reused):** `workspace_branding` (migration 0011) + `build_entitlements().brand`; the password-gate HMAC pattern (`getPwToken`, `HMAC(INTERNAL_SECRET, …)`); the scan-counter aggregates (`qr_scan_counters`: `scans_by_device/country/date/hour`) and the analytics read path (`scan.py`, `useAnalytics`/`useQRAnalytics`); the public-API router family (`/api/public/v1`, already excluded from `BearerTokenAuthMiddleware`); folders (`folders` table + `get_folder_tree`).
- **Must be applied first:** migration 0011 (white_labeling) confirmed deployed to Supabase prod — branding is inert until it is.
- **New work:** migration 0017; `reports.py` route module (added to `endpoints.py`); `shareable_reports` in `FEATURE_ENFORCEMENT`; the public `r/[token]` Next.js page + `ShareReportModal`; `plan-features.ts` flag; optional `increment_report_views` RPC.
- **No dependency on:** the Worker (scan path untouched), the consent gate (no cookies/pixels on reports), lifecycle emails, or the lead-capture system.

### Appendix — Key Files

| Concern | File |
|---|---|
| Migration (table + flag flip) | `qr_backend/migrations/0017_report_links.sql` |
| Report CRUD + public read route | `qr_backend/src/api/routes/reports.py` (new), `qr_backend/src/api/endpoints.py` |
| Aggregate reuse + retention clamp | `qr_backend/src/api/routes/scan.py`, `qr_scan_counters` reads |
| Branding snapshot | `qr_backend/src/utilities/cloudflare_kv.py` (`build_entitlements`), `workspace_branding` |
| Gating (BE) | `qr_backend/src/api/routes/subscription.py` (`FEATURE_ENFORCEMENT`, `check_feature`) |
| Public router exclusion | `qr_backend/src/main.py` (`BearerTokenAuthMiddleware` excluded prefixes) |
| Public report page | `qr_frontend/src/app/(marketing)/r/[token]/page.tsx` (new) |
| Share modal + gate | `qr_frontend/src/components/org/reports/ShareReportModal.tsx`, `ReportsUpgradeGate.tsx` (new) |
| In-app entry points | `qr_frontend/src/app/org/[slug]/(dash)/qrs/[id]/`, `.../analytics/page.tsx` |
| Gating (FE) | `qr_frontend/src/lib/plan-features.ts` (`canAccessFeature`, `shareable_reports`) |
