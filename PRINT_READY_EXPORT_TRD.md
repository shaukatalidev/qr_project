# TRD — Print-Ready QR Asset & Poster Export

**Status:** Draft · **Author:** Staff Eng · **Date:** 2026-06-24
**Priority:** Revenue — medium-leverage, medium-effort. Print is Qravio's largest QR distribution channel and the one surface where we currently lose the hand-off to Canva/Illustrator.
**Tiers:** Single print-ready PDF + poster templates gate at **Pro+** via a new `print_export` flag. Multi-QR N-up sheets additionally gate at **Agency** via the existing `bulk_generation` flag. White-label removal of the "Made with Qravio" mark rides the existing `white_labeling`/`brand` entitlement.
**Plan flags:** `print_export` (bool) — new; seeded `false` everywhere by migration `0025`, flipped `true` for `pro` + `agency`. Registered in `FEATURE_ENFORCEMENT` as `inert` → `enforced` in the same PR. **N-up sheets get no new flag** — they check `print_export` AND `bulk_generation` (note: the real flag key is `bulk_generation`, not `bulk`).
**Migration slot:** reserved **0025** — used (a one-line flag-flip seed; no schema/tables).
**Services touched:** `qr_backend` (new route + render utility + 1 dependency + gate flip), `qr_frontend` (modals/gates/entry points + 1 PlanFeatures key). **`qr_cf_code`: NO change** (no KV write, no scan-path change, no template parity, no cron).
**Split from:** None. Adjacent to `SCHEDULED_REPORTS_ALERTS` (shares the WeasyPrint HTML/CSS→PDF path) and the bulk surface.

**Rev (2026-06-24, post eng-review):** Verified against the live tree — `bulk_generation`/`white_labeling` are `enforced` in `subscription.py` `FEATURE_ENFORCEMENT`; `_fetch_workspace_brand`/`build_entitlements` exist in `cloudflare_kv.py`; `qr_codes` table + `short_code` (qr.py:815) + `custom_domain_id` (qr.py:818) + `QRCodeDesign` (qr.py:148) confirmed; slot **0025** is free (0014–0024 are reserved/used by other backlog specs, no collision); the no-Worker/no-email/no-cron/no-AI posture is correct. Five substantive fixes: **(P1) scan-URL must honor custom domains** — a `custom_domain_id`-bound QR must encode `https://<custom-hostname>/<short_code>`, not an assumed primary host (the backend has **no** `PRIMARY_HOSTNAME` config — that's a Worker var; add `SCAN_BASE_HOST` + the custom-domain join), else Agency clients on custom domains print dead/mis-routed tents; golden test now asserts both host cases. **(P2) in-tenant DoS** — synchronous CPU-heavy WeasyPrint renders need a per-process render **semaphore** + a per-workspace export rate limit in v1 (auth/role alone don't stop a single editor saturating the pool); async queue stays the Phase-3 *throughput* path. **(P2) timeout mechanics** — WeasyPrint isn't asyncio-cooperative, so the render must run in `asyncio.to_thread` with `wait_for` around *that* future for the 504 to fire and the loop to stay unblocked. **(P2) custom-page validation** — `Literal page` + `Optional confloat` don't enforce "custom ⟺ both dims present"; added a `model_validator`. **(P2) WeasyPrint `@page bleed/marks` is load-bearing** — verify on the pinned version before Phase 1, with an absolute-positioned-trim-marks fallback. **(P3) `segno` exotic-style parity** scope-bound to standard-module fidelity in v1 (see §12.5).

---

## 1. Overview & Architecture

This feature is a **pure server-side render endpoint plus a thin export UI**. It touches **two** of the three services. The Worker is entirely uninvolved: export is artwork generation, not a scan, so there is **no KV write, no `build_kv_content`/`build_entitlements` mutation, no `recordScan`, no template, no cron**.

- **`qr_backend`** gains: a new `print` route module (`src/api/routes/print.py`) with two POST endpoints (`/workspaces/{ws}/print/asset` single, Pro+; `/workspaces/{ws}/print/sheet` N-up, Agency), both JWT-gated + `require_can_read` + request-time `check_feature`; a render utility `src/utilities/print_pdf.py` (HTML/CSS imposition + WeasyPrint render); a backend QR-vector builder `src/utilities/qr_svg.py` (Python `segno`-based, mirrors the geometry of the FE `qr-svg-generator.ts`); two new pinned dependencies (`weasyprint`, `segno`); a `FEATURE_ENFORCEMENT` entry; and registration in `endpoints.py`.
- **`qr_frontend`** gains: `PrintExportModal`, `PrintSheetModal`, `PrintExportUpgradeGate`; entry-point buttons in builder Step 4 (`DownloadOptions.tsx`), QR detail, the bulk page, and folder view; `print_export` added to the `PlanFeatures` interface; a small TanStack-Query-adjacent blob-download helper on `authApi`.
- **`qr_cf_code`** — **explicitly unchanged.**

**Data flow — single print-ready asset:**
```
User clicks "Print-ready export" in builder Step 4 / QR detail
  → canAccessFeature(sub,'print_export') ? open PrintExportModal : PrintExportUpgradeGate
  → POST /api/v1/workspaces/{ws}/print/asset {qr_id, layout, page, headline, sub, crop, bleed}
  → print.py: require_can_read + await check_feature(ws,'print_export') (403 if false)
  → resolve QR (workspace-scoped) → read stored qr_designs + short_code
  → qr_svg.py: render QR to inline SVG at print scale (vector → crisp at any DPI)
  → print_pdf.py: build HTML (page box + 3mm bleed + crop marks + headline) → WeasyPrint → PDF bytes
  → mark: build_entitlements(ws).brand present? → workspace logo, no Qravio mark; else "Made with Qravio" footer
  → 200 application/pdf (Content-Disposition: attachment)  [no scan event, no KV write]
```

**Data flow — N-up sheet (Agency):**
```
Bulk/folder page → "Export print sheet" (Agency-gated) → PrintSheetModal
  → POST /api/v1/workspaces/{ws}/print/sheet {qr_ids[], preset, caption, crop}
  → print.py: require_can_read + check_feature(ws,'print_export') AND check_feature(ws,'bulk_generation')
  → validate batch cap (≤250 QRs / ≤20 sheets) → 422 over-cap; 422 on empty list
  → for each qr_id (workspace-scoped): render SVG → impose onto CSS grid preset → paginate
  → WeasyPrint → single multi-page PDF → 200 application/pdf attachment
```

---

## 2. Data Model & Migrations

**No tables, columns, indexes, or RLS policies are added.** The only DB change is a **plan-flag flip** so the feature is enforced through the registered-flag path (preferred over implicit tier logic for clean `FEATURE_ENFORCEMENT` parity). All Supabase access uses the **service-role key, which bypasses RLS** — tenant isolation is enforced in application code via explicit `workspace_id` filters and `require_*` deps, never RLS.

The migration ships **only** this phase's change (the flag flip) and follows the **house flag-flip convention** (coalesce NULL features, idiomatic key-absence guard, `lower(name)`, `is_custom` guard — never a bare case-sensitive `WHERE name IN (...)`).

```sql
-- qr_backend/migrations/0025_print_export.sql
-- Print-Ready QR Asset & Poster Export — flag flip only. No schema.
-- Apply by hand in the Supabase SQL editor. Idempotent; BEGIN/COMMIT-wrapped.
BEGIN;

-- 1) Seed print_export=false on every standard plan that doesn't already have the key.
UPDATE plans
   SET features = jsonb_set(coalesce(features, '{}'::jsonb), '{print_export}', 'false'::jsonb, true)
 WHERE NOT (coalesce(features, '{}'::jsonb) ? 'print_export')
   AND coalesce(is_custom, false) = false;

-- 2) Flip print_export=true for Pro + Agency (case-insensitive; never touches custom/enterprise).
UPDATE plans
   SET features = jsonb_set(coalesce(features, '{}'::jsonb), '{print_export}', 'true'::jsonb, true)
 WHERE lower(name) IN ('pro', 'agency')
   AND coalesce(is_custom, false) = false;

COMMIT;
```

Current DB highest applied is `0013_retargeting_pixels.sql`. Reserved slots across the backlog now extend past 0018 (0014 AI-analyst, 0015 routing, 0016 funnel, 0017 report-links, 0018 scheduled-reports, 0019 deep-audience-phase2, 0021 google-review, 0022 campaign-tags, 0024 OCR); **0025** is this feature's reserved slot and does not collide with any of them. The migration is idempotent (the absence-guarded seed + an idempotent value flip), so re-running is a no-op. The user applies it in the Supabase SQL editor.

---

## 3. Backend Design

### 3.1 New router — `src/api/routes/print.py`

Registered in `src/api/endpoints.py`:
```python
from src.api.routes.print import router as print_router
router.include_router(router=print_router)
```
Prefix `/workspaces/{workspace_id}`; under `API_PREFIX` (`/api/v1`) so both endpoints pass through `BearerTokenAuthMiddleware` (Supabase JWT). Neither is a public/internal route — no `excluded_routes` change, no `x-internal-secret` (the Worker never calls these).

| Method | Path | Gate | Returns |
|---|---|---|---|
| `POST` | `/workspaces/{ws}/print/asset` | `print_export` (Pro+) | `application/pdf` |
| `POST` | `/workspaces/{ws}/print/sheet` | `print_export` **AND** `bulk_generation` (Agency) | `application/pdf` |

Both depend on `require_can_read` (from `src/api/dependencies/permissions.py`) — export is a read of existing artwork, not a mutation. Request-time gating (defends against a stale UI after downgrade):

```python
from src.api.routes.subscription import check_feature  # async

@router.post("/workspaces/{workspace_id}/print/asset")
async def export_print_asset(
    workspace_id: uuid.UUID,
    body: PrintAssetRequest,
    member: dict = Depends(require_can_read),
    db: Client = Depends(get_supabase),
):
    if not await check_feature(str(workspace_id), "print_export", db):
        raise HTTPException(status_code=403, detail="print_export required")
    qr = _resolve_qr(str(workspace_id), str(body.qr_id), db)  # 404 if not in this ws
    ...
```

**`_resolve_qr`** runs `db.table("qr_codes").select("short_code, custom_domain_id, ...").eq("id", qr_id).eq("workspace_id", workspace_id).maybe_single().execute()` (table confirmed `qr_codes`; `short_code` at `qr.py:815`, `custom_domain_id` at `qr.py:818`) — the explicit `.eq("workspace_id", …)` is the tenant-isolation boundary because service-role bypasses RLS. The QR's stored `qr_designs` row (shape/dots/eyes/logo/ECC, the `QRCodeDesign` schema at `qr.py:148`) and `short_code` are read.

**Scan-URL construction (correctness — P1).** The printed QR must encode the QR's **actual live scan URL**, not an assumed primary host: if `custom_domain_id` is set, resolve `custom_domains.hostname` and build `https://<hostname>/<short_code>`; otherwise use the platform scan base. The backend has **no existing `PRIMARY_HOSTNAME` config** (that env var lives only in the Worker) — add a single `SCAN_BASE_HOST` (or reuse the configured public scan domain) to `config/manager.py` and resolve the custom-domain join when present. Encoding the wrong host would silently print 48 dead/mis-routed table tents for a custom-domain Agency client. The URL is server-controlled, **never** client-supplied — resolves Open Q2 in favor of backend re-render. A render test asserts the decoded QR equals the QR's live scan URL for both the primary-host and custom-domain cases.

**Request models (pydantic):**
```python
class PrintAssetRequest(BaseModel):
    qr_id: uuid.UUID
    layout: Literal["centered","scan_menu","scan_pay","scan_wifi"] = "centered"
    page: Literal["a4","letter","a5","custom"] = "a4"
    page_w_mm: Optional[confloat(ge=40, le=1000)] = None   # required+validated when page=custom
    page_h_mm: Optional[confloat(ge=40, le=1000)] = None
    headline: Optional[constr(max_length=80)] = None
    sub_line: Optional[constr(max_length=160)] = None
    crop_marks: bool = True
    bleed: bool = True

class PrintSheetRequest(BaseModel):
    qr_ids: conlist(uuid.UUID, min_length=1, max_length=250)
    preset: Literal["a4_grid","letter_grid","avery_l7160","avery_5160"] = "a4_grid"
    caption: Literal["name","short_url","none"] = "name"
    crop_marks: bool = True
```
Custom page bounds are clamped/validated (too small for QR+bleed → 422; absurdly large → 422) per the PRD edge cases. **Cross-field validation:** `page="custom"` with a missing `page_w_mm`/`page_h_mm` must 422 — pydantic does **not** infer the conditional-required relationship from the `Literal` + `Optional[confloat]` shapes alone, so a `model_validator(mode="after")` enforces "custom ⟺ both dims present and in bounds" (and rejects dims supplied with a non-custom `page`). The sheet `max_length=250` plus a computed `≤20 sheets` check yields a **422 "batch too large; split into multiple requests"** rather than risking WeasyPrint OOM/timeout. Empty/all-missing `qr_ids` → 422 "nothing to export" (never a blank PDF). Both endpoints run under a hard render timeout. **Note (P2):** WeasyPrint renders synchronously and is **not** asyncio-cooperative, so `asyncio.wait_for` around a bare call cannot interrupt an in-flight render. Run the render in a worker thread (`asyncio.to_thread` / `run_in_executor`) and wrap *that* future in `wait_for`, so the timeout actually fires and the event loop is never blocked → clean 504 rather than a hung worker.

### 3.2 Render utility — `src/utilities/print_pdf.py`

- `build_qr_svg(design, scan_url)` (in `src/utilities/qr_svg.py`, using **`segno`**) emits the QR as **inline SVG** honoring the stored module/eye/logo design. Vector → crisp at any DPI, sidestepping raster upscaling entirely (the highest-risk fidelity mitigation). Mirrors `qr-svg-generator.ts` geometry; a golden-file test asserts module count/eye placement parity for a fixed payload.
- `render_asset_pdf(svg, layout, page, headline, sub, crop, bleed, brand)` builds an HTML document with **CSS `@page { size: <Wmm> <Hmm>; bleed: 3mm; marks: crop; }`**. WeasyPrint is one of the few engines that implements the `bleed`/`marks` `@page` properties, but this is **load-bearing and must be verified on the pinned WeasyPrint version before Phase 1** (alongside the system-libs check): if `marks: crop` is unsupported on the pinned version, fall back to **drawing trim/crop marks as absolutely-positioned elements in the bleed area** (an explicit, version-independent path the golden test already asserts via "trim-mark element present"). Centers the QR with a guaranteed quiet zone, places headline/sub-line in the poster template, embeds any logo/photo at the source resolution and sizes it so **effective resolution ≥ 300 DPI** at the placed dimensions (warn if the source is too small — still produce the PDF, since the QR stays vector-crisp). The footer carries the **Qravio mark** unless `brand` is present (then the workspace logo, no Qravio mark). Renders with **WeasyPrint** → `pdf_bytes`. Returned via `Response(content=pdf_bytes, media_type="application/pdf", headers={"Content-Disposition": 'attachment; filename="qravio-print-<scope>.pdf"'})`.
- `render_sheet_pdf(items, preset, caption, crop)` lays the per-cell QRs onto a **CSS grid** sized to the preset (A4/Letter plain grid + Avery L7160 3×8 / 5160), adds per-cell crop marks, paginates with `break-inside: avoid` + page rules, leaves trailing cells blank with crop marks (never repeats QRs), and renders a single multi-page PDF.

WeasyPrint and `segno` are pinned in `requirements.txt`. **WeasyPrint system libs (`libpango`, `libcairo`, `libgdk-pixbuf`) must be present in the backend Render image** — the same prerequisite `SCHEDULED_REPORTS` flagged; it is a **GA gate** (§12). The renderer module is shared with scheduled-reports so it's exercised on one path. Output is **RGB only** (WeasyPrint limitation) — surfaced as a permanent UI caveat; CMYK is a documented Phase-3 path.

### 3.3 Gating registry + KV

`FEATURE_ENFORCEMENT` (`subscription.py:428`) gains `"print_export": "enforced"` in the same PR as the build (registered `inert` in the spec, shipped `enforced`). `test_feature_gate_coverage` asserts registry↔plan-seed parity, so the `0025` seed + this entry must land together to keep it green. **No KV / `build_entitlements` / `build_pixels` / `build_kv_content` change** — the export reads the brand snapshot directly server-side via the existing `_fetch_workspace_brand(ws, db)` (the same `workspace_branding` read `build_entitlements` uses), never from request params (anti-spoofing). **No `dynamic_qr_types` change** (no new QR type) — the edge contract is untouched.

---

## 4. Cloudflare Worker / Edge Design

**No Worker change of any kind.** Print export is invisible to the scan-time `fetch` path:

- **No KV write** — `write_to_kv` / `build_kv_content` are not called; the ~11 top-level KV keys (`qr_id`, `type`, `destination`, `destinations`, `is_password_protected`, `status`, `workspace_id`, `page_design`, `content`, `entitlements`, `pixels`) are unchanged.
- **No scan event** — no `recordScan`, no `qr_scan_events` row, no `qr_scan_counters` increment. An export is artwork generation, not a scan; the 17-field scan payload (`country_code`/`session_id`/`device_type`/`scanned_at`/`variant_key`/…) is irrelevant.
- **No new QR type** → no `src/pages/<type>/` page, no template, no React-mirror obligation (the 7-step new-type checklist does not apply).
- **No `scheduled()` cron** → no `wrangler.toml` trigger, so **no prod-worker-deploy gate**. The only deploy prerequisite for this feature is the WeasyPrint system libs in the backend image.
- **No consent-gate interaction** — `consent.js` fires only at scan time when `hasMarketingTags`; export never reaches the edge.

---

## 5. Frontend Design

### 5.1 Gating + types

Add `print_export: boolean;` to the **boolean feature flags** block of the `PlanFeatures` interface (`src/hooks/useSubscription.ts:40`, beside `bulk_generation`/`white_labeling`). Gate UI with `canAccessFeature(subscription, 'print_export')` and `canAccessFeature(subscription, 'bulk_generation')` from `src/lib/plan-features.ts` (no signature change — `feature` is already `keyof PlanFeatures`). `subscription` comes from the existing `useCurrentSubscription(workspaceId)` hook.

### 5.2 Components (shadcn/ui only; <200 lines; kebab-case; one export)

- **`src/components/org/print/print-export-modal.tsx`** — `Dialog` + react-hook-form + zod: `layout` (Centered / Scan-to-menu / Scan-to-pay / Scan-for-Wi-Fi `Select`), `page` (A4/Letter/A5/Custom; custom reveals zod-validated mm inputs), `headline` + `sub_line` (`Input`/`Textarea`), `crop_marks` + `bleed` `Switch`es (default on). A live preview thumbnail re-uses the existing React template/preview discipline (renders the chosen layout in a phone/page frame). Always-visible caveat copy: *"Output is high-resolution RGB (300 DPI, 3 mm bleed, crop marks). For exact ink color, ask your printer about CMYK conversion."* A Pro→Agency nudge ("Need to print a whole batch on one sheet? Upgrade to Agency") shown when `!canAccessFeature(sub,'bulk_generation')`.
- **`src/components/org/print/print-sheet-modal.tsx`** — Agency-gated. `Select` for sheet preset (A4 grid / Letter grid / Avery L7160 / Avery 5160), `caption` (QR name / short URL / none), `crop_marks` switch. Shows the resolved QR count and warns if it exceeds the cap before submit.
- **`src/components/org/print/print-export-upgrade-gate.tsx`** — same paywall pattern as the analytics/branding gates; renders when `!canAccessFeature(sub,'print_export')`.

### 5.3 Hooks + entry points

- **`src/hooks/usePrintExport.ts`** — two `useMutation`s (`useExportAsset`, `useExportSheet`) calling `authApi.post('/workspaces/{ws}/print/asset' | '/sheet', body, { responseType: 'blob' })`, then a browser object-URL download (mirrors the existing `downloadLeadsCsv` helper). No query-key invalidation (export creates no server state); `toast()` on success/error per the house mutation pattern. A 422 over-cap surfaces a clear "split your batch" toast; a 403 surfaces the upgrade copy.
- **`src/components/qr-generator/DownloadOptions.tsx`** — add a shadcn **`<Button>` "Print-ready export"** beside the existing `png|svg|jpeg|webp|pdf` buttons (`DownloadFormat` at line 16). It opens `PrintExportModal` when entitled, else `PrintExportUpgradeGate`. Used by builder Step 4 (`build/page.tsx`) and the QR detail page (`qrs/[id]`).
- **`src/app/org/[slug]/(dash)/bulk/page.tsx`** and the folder view — add an Agency-gated **"Export print sheet"** button opening `PrintSheetModal`, passing the batch/folder's `qr_ids`.

**Design tokens:** `primary`/`primary-container` (indigo `#4648d4`), `tertiary` (cyan), `surface-container-*`, `on-surface-variant` from `tailwind.config.cjs`; no inline styles; `cn()` for conditional classes. Instrument the export buttons with the existing Mixpanel `ELEMENT_CLICKED` via `data-track-id` so adoption KPIs are measurable.

---

## 6. AI / External-Service Integration

**No Claude / Anthropic model is used.** Export is deterministic layout — no NL generation, summarization, or classification — so there is no `claude-*` call, no token metering, no confirm-before-save, no ANTHROPIC_API_KEY usage on this path. **No email** (no Resend) → **no DMARC gate** (`_dmarc.qravio.app` publishing is irrelevant to v1; the PDF is downloaded, not mailed). The only external/system dependency is **WeasyPrint** (local HTML/CSS→PDF, no network) and **`segno`** (local QR vector generation). Both are pinned in `requirements.txt`; WeasyPrint's system libs are the sole deploy prerequisite.

---

## 7. API Contracts

**Single asset (Pro+):**
```
POST /api/v1/workspaces/{workspace_id}/print/asset
{ "qr_id":"<uuid>", "layout":"scan_menu", "page":"a4",
  "headline":"Scan to view our menu", "sub_line":"Fresh daily specials",
  "crop_marks":true, "bleed":true }
→ 200 application/pdf  (Content-Disposition: attachment; filename="qravio-print-<qr>.pdf")
→ 403 { "detail":"print_export required" }            (Free/Starter, or downgraded ws)
→ 404 { "detail":"qr not found in workspace" }
→ 422 { "detail":"custom page too small for QR + 3mm bleed" }
→ 504 { "detail":"render timed out" }
```

**N-up sheet (Agency):**
```
POST /api/v1/workspaces/{workspace_id}/print/sheet
{ "qr_ids":["<uuid>", "...", "<uuid>"], "preset":"avery_l7160",
  "caption":"name", "crop_marks":true }
→ 200 application/pdf  (multi-page; attachment)
→ 403 { "detail":"print_export required" }   |   { "detail":"bulk_generation required" }
→ 422 { "detail":"batch too large (max 250 QRs / 20 sheets); split into multiple requests" }
→ 422 { "detail":"nothing to export" }       (empty / all-missing qr_ids)
```

Custom page example body adds `"page":"custom","page_w_mm":210,"page_h_mm":297`.

---

## 8. Security, Privacy & Abuse

- **Auth:** both routes pass through `BearerTokenAuthMiddleware` (Supabase JWT) + `require_can_read`. No new `excluded_routes` (these are not public/internal — the Worker never calls them), so no Bearer-middleware change and no `x-internal-secret` surface.
- **Tenant isolation:** service-role bypasses RLS, so every read is explicitly `workspace_id`-scoped. `_resolve_qr` filters `.eq("workspace_id", workspace_id)`; for sheets, **each** `qr_id` is validated to belong to the resolved workspace (a single `in_("id", qr_ids).eq("workspace_id", ws)` query — any id not returned is rejected), preventing cross-tenant QR exfiltration via a crafted `qr_ids[]`.
- **Brand spoofing:** the logo/footer mark comes **only** from the workspace's own brand snapshot (`_fetch_workspace_brand(ws, db)` reading `workspace_branding`), never from request params — an exporter cannot inject another brand's mark or remove the Qravio mark without the `white_labeling` entitlement.
- **Stale-gate after downgrade:** `check_feature` is re-evaluated at **request time** on both endpoints (cheap — `resolve_plan` has a 30s cache), so a churned/downgraded workspace stops exporting even with the modal still open.
- **No SSRF surface:** no webhook, no outbound URL fetch; WeasyPrint renders local HTML with embedded SVG/data-URI assets only (no remote `<img src>` fetch is permitted in the template — logos are read from our own Storage and inlined). This eliminates WeasyPrint's known remote-fetch SSRF vector.
- **PII / consent:** the PDF contains only the workspace's own QR artwork + operator-typed headline. **No scan data, no IP/`ip_hash`/`session_id`, no `qr_scan_events` rows** are read or emitted. The edge consent gate is irrelevant (export never runs at scan time).
- **Abuse / DoS (P2 — tighten in v1, not Phase-3):** the batch cap (≤250 QRs / ≤20 sheets → 422) and the hard render timeout (→ 504) bound a *single* request, but WeasyPrint renders are CPU/RAM-heavy and **synchronous**, so an authenticated editor can fire many concurrent at-cap `/print/sheet` requests and saturate the backend (an in-tenant DoS that auth/role checks do **not** stop). v1 must add a cheap guard: a small **per-process render semaphore** (bound concurrent WeasyPrint renders so the pool can't be exhausted; excess requests get a fast 429/503 "render busy, retry") **and** a lightweight per-workspace export rate limit (e.g. token-bucket in the existing limit machinery). The async job queue remains the Phase-3 path for *throughput*; the semaphore + rate limit are the v1 *safety* floor.

---

## 9. Performance, Scale & Cost

- **Single asset:** one `qr_codes`+`qr_designs` read, one `segno` SVG build, one WeasyPrint render. Target p95 **< 4 s**; dominated by WeasyPrint cold-render (mitigated by the shared, already-warm renderer module).
- **N-up sheet:** N small SVG builds + one multi-page render. A 48-QR sheet targets p95 **< 12 s**; the ≤250/≤20-sheet cap bounds the worst case. Rendering is **synchronous** in v1 (spinner UX); an **async job queue** for very large batches is an explicit Phase-3 deferral.
- **Memory:** SVG-embed (vector) keeps the HTML small versus embedding 300-DPI rasters; logos/photos are the only rasters and are bounded by source size. The cap is the OOM guard.
- **Cost:** zero external-API cost (no AI, no email). Compute is backend CPU only; WeasyPrint renders are the dominant cost and are bounded by the cap + timeout + a **per-process render semaphore** (§8) so concurrent renders can't exhaust the worker pool. Each render runs in a worker thread (`asyncio.to_thread`) so the event loop stays responsive and the `wait_for` timeout can actually fire.
- **Reads:** counter tables untouched; no scan-event scans. The sheet's `in_("id", qr_ids)` is a single indexed batch read.

---

## 10. Testing Strategy

**Backend (pytest):**
- **Gate:** Free/Starter `POST /print/asset` → 403; Pro → 200 `application/pdf`. Sheet on Pro (no `bulk_generation`) → 403; Agency → 200. A workspace downgraded mid-session → 403 at request time.
- **Tenant isolation:** a `qr_id` from another workspace → 404; a `qr_ids[]` mixing a foreign id → 422/404 (foreign id rejected, never rendered).
- **Golden-file render test (the headline fidelity assertion):** parse the produced PDF and assert (1) page box matches the requested size (A4 = 210×297 mm + 2×3 mm bleed), (2) a `bleed`/trim-mark element is present when `crop_marks=true`, (3) the embedded QR SVG's module raster size implies **≥300 DPI** effective resolution, (4) the rendered QR **decodes back to the QR's live scan URL** — `https://<scan-base>/<short_code>` for a primary-host QR **and** `https://<custom-hostname>/<short_code>` for a custom-domain-bound QR (decode round-trip, both cases), (5) a non-white-label asset contains the "Made with Qravio" mark and an Agency/white-label asset contains the workspace logo and **no** Qravio mark.
- **Caps/edges:** 251 QRs → 422; empty list → 422; custom page too small → 422; headline overflow wraps without overlapping the QR quiet zone.
- **`test_feature_gate_coverage` stays green:** `print_export` present in both `FEATURE_ENFORCEMENT` and the `0025` plan seed.

**Frontend (Vitest + Playwright):** modal zod validation (custom mm bounds, headline length); blob-download helper builds the right URL + triggers download; gating hides the modal and shows `PrintExportUpgradeGate` for Free; sheet button hidden for non-Agency. **Baseline:** the FE suite has **~29 pre-existing failures (documented baseline, not regressions)** — assert new tests pass and the failure count does not increase.

**Worker:** **no Worker tests** — the Worker is unchanged.

---

## 11. Observability & Rollout

**Phased deploy (2 services; correct order):**
1. **Phase 0 — migration & flag (inert in spec).** Apply `0025_print_export.sql` in the Supabase SQL editor (flag flip only). Add `print_export` to `FEATURE_ENFORCEMENT`. No UI yet.
2. **Phase 1 — single asset + posters (Pro), behind a build flag.** Deploy `qr_backend` (`print.py`, `print_pdf.py`, `qr_svg.py`, `weasyprint`+`segno` pins; flip `print_export` `inert→enforced` in the **same PR**). Deploy `qr_frontend` (`PrintExportModal`, gate, builder + QR-detail entry points, RGB caveat). **Acceptance:** Pro exports an A4 poster with verifiable 3 mm bleed + crop marks + ≥300 DPI QR that scans; non-white-label shows the Qravio mark, Agency/white-label shows the workspace logo with no Qravio mark; Free/Starter sees the gate and the endpoint refuses below Pro at request time; the golden-file render test passes. Dogfood with 3–5 print-heavy accounts; **physically print one sample at a real print shop and confirm acceptance.**
3. **Phase 2 — N-up sheets (Agency) + GA.** Add `/print/sheet`, Avery/A4 presets, `PrintSheetModal` on bulk + folder views (gated on `print_export` AND `bulk_generation`), batch cap + 422. Remove the build flag; announce as an Agency print headline.
4. **Phase 3 — future.** CMYK/ICC color-managed pipeline (separate spec), async job queue for very large batches, freeform poster designer, saved brand presets, print-on-demand.

**No prod-Worker deploy** is required (no cron, no KV) and **no DMARC gate** (no email). The **only GA gate** is: WeasyPrint system libs (`libpango`/`libcairo`/`libgdk-pixbuf`) confirmed in the backend Render image **before Phase 1**, plus one passed physical print-shop validation.

**Metrics:** Mixpanel `ELEMENT_CLICKED` on the export buttons; export-success rate (target < 1% error); ≥18% of Pro and ≥35% of Agency workspaces export ≥1 PDF in 30d; ≥25% of Agency generate ≥1 N-up sheet in 60d; single-asset p95 < 4 s and 48-QR sheet p95 < 12 s (no request exceeds the hard timeout without a clean 422/504); Pro→Agency upgrade lift among workspaces that hit the "N-up is Agency" gate. Backend logs render duration + cap-reject counts.

---

## 12. Open Technical Questions & Risks

1. **WeasyPrint system deps — hard GA gate.** `libpango`/`libcairo`/`libgdk-pixbuf` must be in the Render image (shared with scheduled-reports). Confirm the buildpack/Dockerfile before Phase 1. Without them the renderer import fails at boot.
2. **RGB vs CMYK — stated limitation, not a bug.** WeasyPrint renders RGB only. Mitigation: a permanent UI caveat and a Phase-3 CMYK pipeline (Ghostscript post-convert). We never silently imply CMYK.
3. **Print fidelity (highest risk).** Mitigated by 3 mm bleed + crop-on-by-default + the QR as **inline SVG at print scale** (vector → crisp at any DPI) and a golden-file render test asserting page box, bleed, and trim-mark elements. Raster logos are sized for ≥300 DPI and warned if the source is too small.
4. **QR re-render parity — RESOLVED:** render the QR SVG **backend-side from stored `qr_designs`** (server-controlled, consistent) via `segno`, **never** trusting a client-supplied SVG. A parity golden test pins module/eye geometry against the FE generator for a fixed payload.
5. **`segno` design-feature parity (largest accidental-complexity item — scope-bound it).** The FE QR engine (`qr-svg-generator.ts`, `qrcode`-based) supports custom module shapes, custom eyes, and logo overlay; `segno` is a *different* library and will **not** 1:1 reproduce every exotic FE module/eye style. Chasing pixel-parity across two QR engines is the deepest hole in v1. **Decision (scope-bound):** v1 ships **scan-correct, standard-module fidelity** — correct payload/ECC/quiet-zone/logo-overlay/brand-color — and renders any **exotic** module/eye style as the nearest supported style with a logged note (the QR always scans; visual style may differ slightly from the on-screen preview for exotic styles only). Exact exotic-style parity is an explicit Phase-3 item, not a v1 promise; the golden test pins payload + module count + eye placement for the **standard** style only. This keeps v1 from sinking into matching a second rendering library.
6. **Sync vs async cutoff for sheets.** Fixed synchronous + ≤250/≤20 cap **plus a per-process render semaphore + per-workspace rate limit** in v1 (the v1 safety floor, §8/§9); the queued-job threshold for *throughput* is deferred to eng load-testing (Phase 3).
7. **Avery preset list.** Ship L7160 / 5160 + plain A4/Letter in v1; defer the final SKU list to bulk/agency users.
8. **"Professional print" vs "home print" toggle.** Recommended single toggle that flips bleed+crop together (home print = no trim); deferred to a Phase-1 UX call.

## 13. Appendix — Key Files

| Concern | File |
|---|---|
| Migration (flag flip only; reserved slot) | `qr_backend/migrations/0025_print_export.sql` |
| Print render endpoints (new) | `qr_backend/src/api/routes/print.py` |
| Router registration | `qr_backend/src/api/endpoints.py` |
| WeasyPrint render + imposition (new) | `qr_backend/src/utilities/print_pdf.py` |
| Backend QR-SVG builder (new, `segno`) | `qr_backend/src/utilities/qr_svg.py` |
| Brand snapshot / white-label mark (reused) | `qr_backend/src/utilities/cloudflare_kv.py` (`_fetch_workspace_brand`, `build_entitlements`) |
| Gating registry flip (`inert→enforced`) | `qr_backend/src/api/routes/subscription.py` (`FEATURE_ENFORCEMENT`, line 428; `check_feature` line 505) |
| Permissions | `qr_backend/src/api/dependencies/permissions.py` (`require_can_read`, line 43) |
| QR design schema (re-rendered backend-side) | `qr_backend/src/api/routes/qr.py` (`QRCodeDesign`, line 149; `short_code`) |
| Dependency pins (new) | `qr_backend/requirements.txt` (`weasyprint`, `segno`) |
| Gate coverage test (stays green) | `qr_backend/tests/unit_tests/test_feature_gate_coverage.py` |
| Existing export UI (entry point) | `qr_frontend/src/components/qr-generator/DownloadOptions.tsx` |
| QR vector reference geometry | `qr_frontend/src/lib/qr-svg-generator.ts` |
| Print modals + gate (new) | `qr_frontend/src/components/org/print/{print-export-modal,print-sheet-modal,print-export-upgrade-gate}.tsx` |
| Export mutation hook (new) | `qr_frontend/src/hooks/usePrintExport.ts` |
| In-app entry points | `qr_frontend/src/app/org/[slug]/(builder)/build/page.tsx`, `.../(dash)/qrs/[id]/`, `.../(dash)/bulk/page.tsx` |
| Gating (FE) | `qr_frontend/src/lib/plan-features.ts` (`canAccessFeature`), `qr_frontend/src/hooks/useSubscription.ts` (`PlanFeatures` — add `print_export`) |
| Cloudflare Worker | **No change** |
