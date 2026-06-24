# PRD — Print-Ready QR Asset & Poster Export

**Status:** Draft · **Author:** Engineering · **Date:** 2026-06-24
**Priority:** Revenue — medium-leverage, medium-effort. Print is Qravio's single largest QR distribution channel (table tents, posters, packaging, flyers) yet the product ships only a single client-side PNG/SVG/JPEG/WEBP per QR with no bleed, no crop marks, no DPI guarantee, and no multi-up sheet. This closes a concrete "we lose to the print-shop hand-off" gap and pairs naturally with bulk generation for the Agency ICP.
**Tiers:** Pro+ unlocks print-ready PDF export (single asset with bleed/crop marks + poster templates). Agency adds multi-QR sheet layout (N-up imposition) and white-label removal of the Qravio mark on the asset. New `print_export` flag.
**Plan flags:** `print_export` (bool) — new; seeded `false` everywhere by this feature's migration, then flipped `true` for Pro + Agency. Multi-QR sheet imposition is additionally gated on Agency via the existing `bulk_generation` flag (already `enforced` — note: the real registry key is `bulk_generation`, not `bulk`). Removing the Qravio footer/mark on the printed asset rides the existing `white_labeling`/`brand` (Agency) entitlement.
**Split from:** None. Adjacent to `SCHEDULED_REPORTS_ALERTS` (shares the WeasyPrint HTML/CSS→PDF path) and the bulk-generation surface (`org/[slug]/(dash)/bulk/page.tsx`).

**Rev (2026-06-24, post eng-review):** (1) the N-up gate flag is the real registry key **`bulk_generation`**, not `bulk` — corrected in every PRD reference (verified against `subscription.py` `FEATURE_ENFORCEMENT`, where `bulk_generation`/`white_labeling` are already `enforced`); (2) added a non-goal making explicit that v1 ships **scan-correct standard-module fidelity** via the backend `segno` re-render and does **not** chase exact print-side parity for *exotic* on-screen QR styles (deferred to Phase-3) — this prevents v1 sinking into pixel-matching a second QR engine. WeasyPrint reuse from `SCHEDULED_REPORTS` is confirmed real (that TRD committed WeasyPrint + the `libpango`/`libcairo`/`libgdk-pixbuf` Render-image prerequisite); the no-email/no-cron/no-Worker posture is correct (no DMARC gate, no prod-worker-deploy gate). Deeper correctness/abuse fixes (scan-URL must honor custom domains; per-process render semaphore + rate limit; sync-render timeout mechanics; pydantic custom-page cross-field validation) are detailed in the TRD.

---

## 1. TL;DR / Summary

Today Qravio's QR builder downloads exactly one QR image at a time — `downloadQRByFormat()` in `DownloadOptions.tsx` produces PNG/SVG/JPEG/WEBP (and a thin single-QR "PDF" wrapper) entirely **client-side** from the `qrcode`-based `qr-svg-generator.ts`. A marketer who needs to send artwork to a print shop gets a screen-resolution raster with no bleed, no crop marks, no trim guidance, and no way to lay out 24 unique table-tent QRs on one A4 sheet. They re-do that work in Canva or Illustrator — outside Qravio.

This PRD adds a **server-rendered, print-ready PDF export** built on the same **WeasyPrint HTML/CSS→PDF** path already committed for `SCHEDULED_REPORTS`. Three v1 deliverables: (1) **single print-ready asset** — one QR centered on a chosen page size with **≥300 DPI** raster embedding, **3 mm bleed**, **crop/trim marks**, and an optional caption; (2) **poster templates** — a small set of ready-to-print layouts ("Scan to view menu", "Scan to pay", "Scan for Wi-Fi", a blank centered poster) with the QR, a headline, and a sub-line; (3) **multi-QR N-up sheets** (Agency) — impose many QRs from a folder/bulk batch onto Avery-style label grids or an A4/Letter sheet with crop marks, one PDF for the whole batch. Output is **RGB** (WeasyPrint/browser limitation) and we are explicit about that — CMYK is a documented future/print-shop caveat, not a v1 promise. Effort is medium: the QR vector geometry, the design tokens, and the WeasyPrint dependency all already exist; the new work is an HTML/CSS imposition layer, a render endpoint, and a small export UI.

## 2. Problem & Motivation

**Print is the primary distribution channel for dynamic QR codes, and we have no print-ready output.** Every other surface (analytics, branding, lead capture) assumes the QR is already in the wild — but the moment of "get this onto a physical poster/menu/label" is the one we currently hand to a third-party tool.

Evidence and reused seams:

- **The current export is screen-grade, not print-grade.** `DownloadOptions.tsx` offers `png | svg | jpeg | webp | pdf`, all produced by `downloadQRByFormat(dataUrl, …)` from a canvas/SVG `dataUrl`. There is no DPI control, no bleed, no crop marks, and the "pdf" option is a single-QR convenience wrapper, not an imposition engine. A print shop asks for "300 DPI with 3 mm bleed and trim marks" and the customer can't produce it from Qravio.
- **No multi-up sheet anywhere.** The bulk surface (`org/[slug]/(dash)/bulk/page.tsx`) creates many QRs but the only way to physically print them is one-PNG-at-a-time. Agencies producing 50 unique table-tent codes per venue have no batch artifact.
- **The WeasyPrint path already exists.** `SCHEDULED_REPORTS_ALERTS_TRD` committed WeasyPrint (HTML/CSS→PDF) as the backend PDF renderer, pinned in `requirements.txt`, with `libpango`/`libcairo`/`libgdk-pixbuf` confirmed as a Render-image prerequisite. We reuse that exact toolchain — no new PDF library.
- **The QR geometry already exists.** `qr-svg-generator.ts` produces a clean vector QR (custom module shapes, eyes, logo). We render the QR to **SVG at print scale** and embed it in the WeasyPrint HTML, so the QR stays crisp at any DPI (vector, not an upscaled raster).
- **Category table stakes.** Uniqode, QR Tiger, and Bitly all ship print/poster export and bulk sheet PDFs on their paid tiers. We're below the bar.
- **Pairs with the Agency ICP.** The agency that bought bulk generation and white-label branding is exactly the buyer who prints at volume. This is the missing "last mile" of the bulk → brand → print workflow.

## 3. Goals & Non-Goals

**Goals**
- A **server-rendered print-ready PDF** for a single QR: chosen page size (A4/Letter/A5/custom), **≥300 DPI** effective resolution, **3 mm bleed**, **crop/trim marks**, optional caption/headline.
- A small library of **poster templates** (centered poster, "scan to view menu", "scan to pay", "scan for Wi-Fi") rendered with the workspace's brand color.
- **Multi-QR N-up sheets** (Agency): impose many QRs (from a folder or a bulk batch) onto a label/sheet grid (Avery-style + plain A4/Letter), with per-cell crop marks, as one PDF.
- Honor existing **white-label/brand** entitlement: Agency assets carry the workspace logo and **no** "Made with Qravio" mark; non-white-label assets carry a small footer mark.
- Gate the whole feature behind `print_export` (Pro+); gate N-up sheets behind Agency (`bulk_generation`).
- Be **explicit and honest about color space** — output is RGB; surface a one-line "RGB output; ask your printer about CMYK conversion" note.

**Non-Goals**
- **True CMYK / Pantone / ICC color-managed output** (WeasyPrint/browser render RGB — documented future caveat, not v1).
- **Spot UV / die-cut / foil / print-finish marks** beyond crop + bleed.
- **An in-app drag-and-drop poster designer** (v1 = fixed templates with brand color + headline text fields, not a freeform canvas).
- **Direct-to-printer / print-on-demand fulfillment** (no integration with a physical print vendor in v1).
- **Editing the QR design here** — the QR style/colors/logo come from the existing builder; export consumes them.
- **Exact print-side parity for *exotic* QR module/eye styles** — the print PDF re-renders the QR backend-side with a different library (`segno`), which reproduces scan-correct standard modules + logo + brand color but not every exotic on-screen style 1:1. Exotic styles render as the nearest supported style (the QR always scans); exact exotic-style parity is Phase-3. This deliberately avoids pixel-matching a second QR engine in v1.
- **Mailing the PDF** (no email send → no DMARC dependency for v1).

## 4. Target Users & Personas

- **Priya — Agency Owner (primary, Agency).** Produces print artwork for ~25 SMB clients. Needs one PDF with 48 unique table-tent QRs imposed on A4 with crop marks, branded with her logo, to send straight to her print shop. Today she rebuilds this in Illustrator.
- **Raj — Restaurant Owner (Pro).** Wants a single "Scan to view our menu" poster, A4, with his brand color and a 300 DPI QR he can hand to a local printer or print himself. Doesn't know what "bleed" is — the export must do the right thing by default.
- **Dev — Freelance Marketer (Pro).** Needs an A5 flyer-ready single QR with crop marks for a client campaign; values that the output "just works" at the print shop.
- **Maya — The Print Shop (downstream, no account).** Receives the PDF. Expects 3 mm bleed, crop marks, and a high-res mark. If the file is screen-res or has no bleed, she bounces it back — the failure we're eliminating.
- **Internal: Sales/Success.** Uses "print-ready bulk sheets with crop marks" as a concrete Agency upsell against Uniqode.

## 5. User Stories

- As a **Pro user**, I want to export my QR as a print-ready A4 PDF with crop marks and bleed, so my print shop accepts it without rework.
- As a **Pro user**, I want a "Scan to view menu" poster with my brand color and headline, so I can print signage without a designer.
- As an **Agency owner**, I want to impose 48 unique QRs from a folder onto Avery label sheets as one PDF, so I can print a whole venue's table tents in one run.
- As an **Agency owner**, I want the printed asset to carry **my** logo and no Qravio mark, so it looks like my own deliverable.
- As any **exporter**, I want a clear note that the output is RGB, so I'm not surprised by color shift at the printer.
- As a **Free/Starter user**, I want to see exactly what I'd unlock, so I have a reason to upgrade (the export button shows an upgrade gate).

## 6. UX / Product Flow

**A. Single-asset / poster export (builder + QR detail)**
1. In the **QR builder Step 4** (`build/page.tsx`, the `DownloadOptions` cluster) and on the **QR detail page** (`qrs/[id]`), add a **"Print-ready export"** button beside the existing format buttons. When `canAccessFeature(sub, 'print_export')` is true it opens a `PrintExportModal`; otherwise it renders a `PrintExportUpgradeGate` (same paywall pattern as the analytics/branding gates).
2. In `PrintExportModal` the user picks: **layout** (Centered poster / Scan-to-menu / Scan-to-pay / Scan-for-Wi-Fi), **page size** (A4 / Letter / A5 / custom mm), **headline + sub-line** text (for poster templates), and toggles **crop marks** and **bleed** (both on by default). A live preview thumbnail renders the layout (re-uses the existing React template/preview discipline). An always-visible note reads: *"Output is high-resolution RGB (300 DPI, 3 mm bleed, crop marks). For exact ink color, ask your printer about CMYK conversion."*
3. **Generate** calls `POST /workspaces/{ws}/print/asset` with the QR id + layout options. The backend re-derives the QR **SVG at print scale**, builds an HTML/CSS document, and renders it with **WeasyPrint** → returns `application/pdf` (`Content-Disposition: attachment`). The QR vector embedded keeps it crisp; any logo/photo is embedded at the source resolution.
4. The PDF footer carries a small "Made with Qravio" mark **unless** the workspace has `white_labeling`/`brand`, in which case the workspace logo is used and the Qravio mark is omitted.

**B. Multi-QR sheet / N-up imposition (Agency, bulk surface)**
1. On the **bulk page** (`org/[slug]/(dash)/bulk/page.tsx`) and on a **folder view**, add **"Export print sheet"** (Agency-gated). It opens `PrintSheetModal`: choose **sheet preset** (A4 plain grid, Letter grid, Avery L7160/3×8, Avery 5160), **per-cell caption** (QR name / short URL / none), and **crop marks** (on).
2. **Generate** calls `POST /workspaces/{ws}/print/sheet` with a list of QR ids (the folder's QRs or the bulk batch). The backend renders each QR to SVG, imposes them onto the chosen grid via CSS grid/page rules, paginates across multiple sheets, and returns one multi-page `application/pdf`. The batch size is **capped** (e.g. ≤250 QRs / ≤20 sheets per request) to bound WeasyPrint latency and memory; over-cap returns a clear 422 telling the user to split the batch.
3. Generation is **synchronous** for small batches and shows a spinner; the endpoint enforces a hard timeout. (Async job queue for very large batches is a documented Phase-3 path, not v1.)

**C. Lifecycle / gating**
- Export options are **read-time gated**: the endpoint re-checks `check_feature(ws, 'print_export')` (and Agency for sheets) so a downgraded workspace stops exporting even if it kept the UI open. `resolve_plan()`'s 30s cache makes this cheap.
- No QR scan event is recorded by an export — this is artwork generation, not a scan. No KV write, no Worker involvement.

## 7. Scope — In (v1) vs Out / Future

**In scope (v1)**
- New `print_export` flag (migration: seed `false` everywhere → flip Pro/Agency `true`); register in `FEATURE_ENFORCEMENT` `inert` → flip `enforced` in the same PR.
- Backend: `print.py` route module (added to `endpoints.py`) with `POST /workspaces/{ws}/print/asset` (single, Pro+) and `POST /workspaces/{ws}/print/sheet` (N-up, Agency). Both JWT-gated, `require_can_read`, return `application/pdf`.
- `src/utilities/print_pdf.py` — builds print HTML/CSS (page size, **3 mm bleed**, **crop marks**, **≥300 DPI** raster sizing) and renders with **WeasyPrint**; embeds the QR as inline SVG at print scale.
- A small fixed set of poster templates + N-up sheet presets (A4/Letter plain grid + 2–4 Avery presets).
- Brand/white-label honored via the existing `build_entitlements().brand` snapshot; Qravio mark vs workspace logo.
- Frontend: `PrintExportModal` + `PrintSheetModal` + `PrintExportUpgradeGate` + entry points in builder Step 4, QR detail, bulk page, folder view; `print_export` added to `plan-features.ts`.
- Batch caps + RGB caveat copy.

**Out of scope / Future**
- **CMYK / ICC / Pantone** color-managed PDFs (print-shop-grade) — biggest future ask; needs a non-WeasyPrint pipeline (e.g. Ghostscript post-convert) and is a separate spec.
- Freeform drag-and-drop poster designer.
- Async job queue + emailed/download-link delivery for very large (1000+) batches.
- Direct print-on-demand fulfillment integration.
- Additional finishes (die-cut, foil, spot UV), variable-data merge beyond QR + caption.
- Saved/reusable poster brand presets.

## 8. Pricing & Packaging

| Tier | Single print-ready PDF (bleed/crop/300 DPI) | Poster templates | Multi-QR N-up sheets | Qravio mark |
|---|---|---|---|---|
| Free | ❌ (upgrade gate) | ❌ | ❌ | — |
| Starter | ❌ (upgrade gate) | ❌ | ❌ | — |
| **Pro** | ✅ | ✅ | ❌ | "Made with Qravio" footer mark |
| **Agency** | ✅ | ✅ | ✅ | Workspace logo, no Qravio mark |

- **New flag:** `print_export` (bool) in `plans.features` JSONB. Seeded `false` everywhere, flipped `true` for Pro + Agency by this feature's migration using the **house flag-flip convention** (`jsonb_set` + `coalesce(features,'{}')` + `coalesce(is_custom,false)=false` + `lower(name) IN (...)` — never a bare case-sensitive `WHERE name IN (...)`). Added to `FEATURE_ENFORCEMENT` as `inert`, flipped to `enforced` in the same PR; `test_feature_gate_coverage` must stay green.
- **N-up sheets** do **not** get a separate flag — they ride the existing **`bulk_generation`** entitlement (already Agency, already `enforced` per `subscription.py` `FEATURE_ENFORCEMENT`), so the sheet endpoints check `print_export` AND `bulk_generation`.
- **White-label** removal of the Qravio mark rides the existing **`white_labeling`/`brand`** entitlement — no new flag.
- **Upsell angle:** Pro gets professional single-poster export ("hand this straight to your printer"); Agency gets the volume artifact ("48 table tents on one branded sheet"). The Pro→Agency nudge lives in `PrintExportModal` ("Need to print a whole batch on one sheet? Upgrade to Agency"). The non-white-label "Made with Qravio" mark on every Pro-printed poster is a passive print-channel growth impression.

## 9. Success Metrics & KPIs

- **Adoption:** ≥ 18% of Pro workspaces and ≥ 35% of Agency workspaces generate ≥ 1 print-ready PDF within 30 days of GA.
- **Depth (Agency):** ≥ 25% of Agency workspaces generate ≥ 1 **N-up sheet** within 60 days; median ≥ 3 sheet exports/active Agency workspace/month.
- **Quality / fidelity:** < 1% of print exports error; **0** exports ship below 300 DPI effective resolution or without the requested bleed/crop marks (asserted by a render test that measures the embedded QR raster size + checks for trim-mark elements).
- **Latency:** single-asset export p95 < 4 s; 48-QR sheet p95 < 12 s; no request exceeds the hard timeout without a clean 422/504.
- **Revenue/retention:** ≥ 5% relative Pro→Agency upgrade lift among workspaces that hit the "N-up is Agency" gate; export-using Agency workspaces show measurably lower 90-day churn than non-users (print = a recurring operational dependency = switching cost).
- **Growth loop:** track scans on QRs whose first artifact was a Pro print export (proxy for the "Made with Qravio" print impression reaching new audiences).

## 10. Risks, Edge Cases & Open Questions

**Risks & mitigations**
- **Print fidelity is fiddly (highest risk).** Bleed, DPI, and trim marks are easy to get subtly wrong. Mitigation: be **explicit and defaulted** — **3 mm bleed**, **crop marks on by default**, and the QR embedded as **inline SVG at print scale** (vector → crisp at any DPI, sidestepping raster-upscaling blur entirely). For any raster element (logo/photo) the HTML sizes it so effective resolution is **≥300 DPI** at the placed size, and we down-rank/ warn if the source is too small. A golden-file render test asserts page dimensions, bleed box, and presence of trim-mark elements.
- **RGB vs CMYK.** WeasyPrint/browsers render **RGB only** — we will never silently imply CMYK. Mitigation: a permanent UI caveat ("RGB output; ask your printer about CMYK") and a documented Phase-3 CMYK path. This is a stated limitation, not a hidden bug.
- **WeasyPrint system deps / cold render.** WeasyPrint needs `libpango`, `libcairo`, `libgdk-pixbuf` in the Render image (same prerequisite `SCHEDULED_REPORTS` flagged). Mitigation: confirm the buildpack/Dockerfile includes them **before Phase 1**; share the renderer module with scheduled-reports so it's exercised on one path.
- **Large-batch latency / OOM.** A 500-QR sheet could exhaust WeasyPrint memory or hit the request timeout. Mitigation: a hard **batch cap** (≤250 QRs / ≤20 sheets) returning a 422 to split; render with a hard timeout; async queue is explicitly deferred to Phase 3.
- **Stale gate after downgrade.** Re-check `check_feature` at **request time** on both endpoints (not just in the UI) so a churned workspace cannot keep exporting.
- **Brand spoofing.** Logo/footer come only from the workspace's own `build_entitlements().brand` snapshot — never from request params — so an exporter can't inject another brand's mark.

**Edge cases**
- QR with a heavy embedded logo at low source resolution → warn that the logo may print soft; still produce the PDF (QR itself stays vector-crisp).
- Folder/batch with 0 QRs → 422 "nothing to export," not a blank PDF.
- Custom page size out of sane bounds (too small for QR + bleed, absurdly large) → clamp/validate with a clear error.
- Poster headline too long → CSS truncates/wraps within the template; never overlaps the QR quiet zone.
- N-up grid larger than the QR set → leave trailing cells blank with crop marks, don't repeat QRs.

**Open Questions**
1. **Avery preset list** — which exact label SKUs ship in v1 (L7160 / 5160 + plain A4/Letter)? Defer the final list to the bulk/agency users.
2. **QR re-render parity** — render the QR SVG **backend-side from stored design** (consistent, server-controlled) vs accept a client-supplied SVG? Recommend **backend re-render** from the QR's stored design for fidelity and to avoid trusting client geometry.
3. **Bleed/crop default for posters meant to be printed at home** (no trim) — keep crop marks toggle-off for "home print" presets? Recommend a simple **"professional print" vs "home print"** toggle that flips bleed+marks together.
4. **Sync vs async cutoff** for sheets — what batch size flips to a queued job? Defer threshold to eng load-testing.

## 11. Rollout Plan

- **Phase 0 — Migration & flag (inert).** Ship the migration (reserved slot **0025** if a flag flip is needed; this feature otherwise requires **no schema** — it is a render endpoint + FE). The migration does **only** the `print_export` flag-flip via the house convention (seed `false` everywhere, flip Pro/Agency `true`). Add `print_export` to `FEATURE_ENFORCEMENT` as `inert`. No UI yet. User applies the migration in the Supabase SQL editor (BEGIN/COMMIT, idempotent). **If we decide no flag is needed and print export is implicitly Pro+ via existing tier logic, state: "No migration required" and gate purely on tier — but the registered-flag path is preferred for clean enforcement parity.**
- **Phase 1 — Single-asset + posters (Pro), behind a build flag.**
  - Backend: `print_pdf.py` (WeasyPrint render, bleed/crop/300 DPI, SVG embed) + `POST /workspaces/{ws}/print/asset`. Flip `print_export` `inert → enforced`.
  - Frontend: `PrintExportModal`, gate, builder + QR-detail entry points, RGB caveat copy.
  - **Acceptance:** (1) a Pro workspace exports an A4 poster with verifiable 3 mm bleed + crop marks + ≥300 DPI QR; (2) the QR scans correctly from the printed PDF; (3) a non-white-label asset shows the Qravio mark, an Agency/white-label asset shows the workspace logo and no Qravio mark; (4) a Free/Starter workspace sees the upgrade gate and the endpoint refuses below Pro at request time; (5) the render test asserts page box, bleed, and trim-mark elements.
  - Dogfood with 3–5 print-heavy accounts; physically print one sample at a real print shop and confirm acceptance.
- **Phase 2 — N-up sheets (Agency) + GA.** Add `POST /workspaces/{ws}/print/sheet`, Avery/A4 presets, `PrintSheetModal` on bulk + folder views (Agency-gated via `print_export` AND `bulk_generation`), batch cap + 422. Remove build flag, announce as an Agency print headline. **GA gate:** WeasyPrint system libs confirmed in the Render image; one physical print-shop validation passed.
- **Phase 3 — Future.** CMYK/ICC color-managed output (separate pipeline), async job queue for very large batches, freeform poster designer, saved brand presets, print-on-demand fulfillment.

*Note: this feature sends **no email** (no DMARC gate) and adds **no Worker cron** (no prod-worker-deploy gate) — both are explicitly out of scope. The only deploy prerequisite is the WeasyPrint system libraries in the backend image.*

## 12. Dependencies + Appendix

**Dependencies**
- **Already-shipped primitives (reused):** the **WeasyPrint** HTML/CSS→PDF path committed in `SCHEDULED_REPORTS_ALERTS_TRD` (`requirements.txt` pin + `libpango`/`libcairo`/`libgdk-pixbuf` in the Render image); the QR vector engine (`qr-svg-generator.ts` / `qr-generator.ts`); the existing `DownloadOptions.tsx` export surface; the brand snapshot (`build_entitlements().brand` from `workspace_branding`, migration 0011); the bulk surface (`bulk/page.tsx`) and `bulk_generation` entitlement; folders (`folders` table); the feature-gate machinery (`FEATURE_ENFORCEMENT`, `check_feature`, `resolve_plan`, `plan-features.ts`).
- **Must be confirmed before Phase 1:** WeasyPrint system libraries present in the backend Render image (shared prerequisite with scheduled reports).
- **New work:** the `print_export` flag-flip migration (or "no migration" decision); `print.py` route + `print_pdf.py` utility; `PrintExportModal` / `PrintSheetModal` / `PrintExportUpgradeGate`; `print_export` in `plan-features.ts` + `PlanFeatures` interface; render/golden-file tests.
- **No dependency on:** the Cloudflare Worker (no KV write, no scan-path change, no template parity), the consent gate, lifecycle emails / DMARC, or any AI model (export is deterministic layout — **no Claude/Anthropic call** is in scope).

### Appendix — Key Files

| Concern | File |
|---|---|
| Migration (flag flip, if used; reserved slot) | `qr_backend/migrations/0025_print_export.sql` |
| Print render endpoints | `qr_backend/src/api/routes/print.py` (new), `qr_backend/src/api/endpoints.py` |
| WeasyPrint render + imposition | `qr_backend/src/utilities/print_pdf.py` (new) |
| QR SVG geometry (re-rendered backend-side) | `qr_frontend/src/lib/qr-svg-generator.ts` (reference geometry), backend SVG builder |
| Brand snapshot / white-label mark | `qr_backend/src/utilities/cloudflare_kv.py` (`build_entitlements`), `workspace_branding` |
| Gating (BE) | `qr_backend/src/api/routes/subscription.py` (`FEATURE_ENFORCEMENT`, `check_feature`) |
| Permissions | `qr_backend/src/api/dependencies/permissions.py` (`require_can_read`) |
| Existing export UI (entry point) | `qr_frontend/src/components/qr-generator/DownloadOptions.tsx` |
| Print export modals + gate | `qr_frontend/src/components/org/print/PrintExportModal.tsx`, `PrintSheetModal.tsx`, `PrintExportUpgradeGate.tsx` (new) |
| In-app entry points | `qr_frontend/src/app/org/[slug]/(builder)/build/page.tsx`, `.../(dash)/qrs/[id]/`, `.../(dash)/bulk/page.tsx` |
| Gating (FE) | `qr_frontend/src/lib/plan-features.ts` (`canAccessFeature`, `print_export`), `qr_frontend/src/hooks/useSubscription.ts` (`PlanFeatures`) |
