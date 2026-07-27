# TRD — Email-Signature Embed for vCard Plus

**Status:** Draft · **Author:** Engineering (Staff) · **Date:** 2026-07-25
**Priority:** Quick win on the shipped `vcard_plus` type (Uniqode/QRCodeChimp parity). Almost all of it is a pure string builder + a copy panel; the only real engineering is (a) getting a **hosted absolute image URL** for a renderer that is currently canvas-only, and (b) HTML that survives Outlook's Word engine.
**Tiers:** **All plans, ungated.** `vcard_plus` is creatable on every non-custom plan (`0009` seed; `0027_open_all_qr_types.sql`), so gating its distribution surface would be incoherent. The only entitlement read is the **existing** `white_labeling` flag (attribution suppression).
**Plan flags (NEW):** **None.** No `FEATURE_ENFORCEMENT` entry, no plan seed, no `_QUOTA_SPEC` entry, no `test_feature_gate_coverage` surface. The house guardrail is satisfied by *not adding a flag*, not by classifying one.
**Migration slot:** **None — no migration.** No new column, table, RPC, RLS policy, or plan-features key. The only persisted artifact is a **Supabase Storage object** (upsert at a deterministic path), which is not schema. The next free slot (`0033`, currently claimed by QR_EXPIRY_SCHEDULING) is **untouched by this feature**.
**Services touched:** `qr_backend` (one ~40-line router: publish the signature PNG to the existing public bucket) · `qr_frontend` (pure snippet builder + detail-page panel + one mutation hook). **`qr_cf_code` — no change** (no KV key, no template, no `handleQRCode` case, no `recordScan` field, no cron ⇒ **`npm run deploy:prod` is NOT required**).
**Implements PRD:** Email-Signature Embed for vCard Plus. **Mirrors** `storage.py::upload_avatar` (public-bucket upsert → `get_public_url`) and `EmbedSnippet.tsx` (copy panel with `<pre>` fallback). **Explicitly carries no NFC dependency of any kind.**

**Rev (2026-07-25, post eng-review):** Reviewed via `/plan-eng-review`; ships as-drafted. No migration/no Worker confirmed. Decision (Open Q4 / R6): **add a best-effort delete of the published signature PNG to the QR-delete path in this PR** — don't ship a second uncascaded public artifact. The publish endpoint **must** keep `upload_avatar`'s guards (PNG magic-byte + size validation + workspace-scoped deterministic path — it writes to a public bucket; do not trust client bytes blindly). Outlook-desktop table/inline-HTML rendering is the named release gate; field escaping + sandboxed `srcdoc` preview (R5) are required. Ship Card + Compact, vCard-only, publish-on-open per PRD.

## 1. Overview & Architecture

A saved `vcard_plus`/`vcard` QR gains an **"Email signature"** card on its detail page. The card renders the
QR PNG **client-side using the QR's own saved design** (the existing `useQRPreview` pipeline), uploads those
bytes **once** to the existing public Supabase Storage bucket at a deterministic, workspace-scoped path, and
then builds an **inline-styled HTML block** referencing that permanent public URL. The user copies the block
(as `text/html` where the clipboard supports it) and pastes it into their mail client's signature settings.

**The architecture is dictated by one constraint:** email clients strip external CSS, `<script>`, `<svg>`,
web fonts and `data:` URIs, and Outlook desktop renders through Word (no flexbox/grid, ignores CSS image
sizing). Our QR images exist **only** as canvas `dataUrl`s today (`qr-generator.ts` uses `qr-code-styling`,
browser-only — `generateQRCode` returns `{ dataUrl: '' }` when `window` is undefined). So the feature needs a
**hosted PNG**, and that upload is the entire backend surface.

**Why the client renders and the backend only hosts.** A server-side renderer would need a new Python QR
dependency and would reproduce none of the logo / gradient / eye-shape / frame work in
`designToGeneratorOptions` + `FrameTemplates` — the signature QR would visibly differ from the one the user
designed and downloaded, and the two renderers would drift permanently. We keep **one** renderer and add
**one** upload.

**Services touched**

| Service | Change |
|---|---|
| `qr_backend` | **NEW** router `src/api/routes/qr_signature.py`: `POST /workspaces/{workspace_id}/qrs/{qr_id}/signature-image` — accepts one PNG, verifies the QR belongs to the workspace, upserts to the public bucket at `qr-signatures/{workspace_id}/{qr_id}.png`, returns `get_public_url(path)`. Mounted in `endpoints.py`. **No migration, no gating registry entry, no KV/entitlement change, no cron.** |
| `qr_frontend` | **NEW** pure builder `src/lib/email-signature.ts` (inline-styled HTML + field escaping); **NEW** `email-signature-card.tsx` (+ sandboxed preview child) on the QR detail overview tab; **NEW** `useSignatureImage.ts` TanStack mutation. Reuses `useQRPreview`'s render path and `canAccessFeature(…, 'white_labeling')`. |
| `qr_cf_code` | **No change.** The snippet points at the short URL the Worker already serves (`GET /:shortCode`); the image is served by Supabase Storage's CDN, not the Worker. No new KV top-level key, no `src/pages/*` template, no `qrRouter.js` case, no `recordScan` field. The **worker↔React template-mirroring house rule does not apply** (nothing to mirror), and there is **no prod-worker-deploy gate**. |

**Data flow — publish + copy**

```
Detail page, vcard_plus QR → EmailSignatureCard mounts
  → render PNG client-side (same path as useQRPreview):
      generateDynamicQRContent(short_code, customHostname)        // the encoded URL
      → designToGeneratorOptions(qr.design.qr_design) → generateQRCode(…, width = 2 × displayPx)
      → optional generateWithFrame(…)                              // frame fidelity
      → canvas dataURL → Blob (image/png)
  → useSignatureImage.mutate(blob)
      → authApi.post(/workspaces/{ws}/qrs/{qr_id}/signature-image, multipart)
      → BearerTokenAuthMiddleware → get_workspace_role → require_can_update (editor+)
      → qr_signature.py: assert qr_id ∈ workspace; validate PNG magic bytes + size cap
        → bucket.upload(path=qr-signatures/{ws}/{qr_id}.png, upsert=true, cache-control)
        → get_public_url(path)  →  { "image_url": "https://…/qr-signatures/…png" }
  → buildEmailSignature({ imageUrl, cardUrl, vcard, layout, sizePx, showAttribution })
      → inline-styled <table> HTML string (escaped fields)
  → preview: <iframe srcdoc={html} sandbox>   (style isolation + script neutralization)
  → copy:  navigator.clipboard.write([ClipboardItem{ text/html, text/plain }])
           ‖ fallback: writeText(html) + selectable <pre>
```

**Data flow — the recipient (no code of ours runs)**

```
Recipient opens the email
  → mail client fetches https://…/qr-signatures/{ws}/{qr_id}.png   (Supabase CDN; we never read these logs)
  → recipient scans QR (or clicks the link)
  → GET https://{QR_DYNAMIC_URL}/{short_code}  →  existing Worker path, unchanged
  → KV lookup → handleQRCode('vcard_plus') → existing vCard landing page → recordScan (unchanged)
```

---

## 2. Data Model & Migrations

**No migration. This is a deliberate, defensible "none", not an omission.**

- **No new column / table / RPC / index.** Everything the snippet renders already exists: `qr_codes.short_code`
  and `qr_codes.name`, the vCard fields in `qr_vcard_details` (already returned by `SELECT_WITH_RELATIONS`
  and already in the FE's `qr.content`), and `qr_designs` (already in `qr.design.qr_design`).
- **No new plan-features key** ⇒ nothing to seed, nothing to classify in `FEATURE_ENFORCEMENT`, no
  `'{...}'::jsonb` blob, and `test_feature_gate_coverage` is untouched. The only entitlement consulted is
  `white_labeling`, which is already seeded and already `enforced`.
- **No RLS change.** The published PNG is a **Storage object**, not a row. It lives in the same public bucket
  as user avatars (`storage.py::upload_avatar`, L132–149) and workspace branding logos (`branding.py` L174),
  whose public-read semantics are already documented in `qr.py::_public_url_from_path` (L1008–1021).

**Storage layout (the only persisted artifact)**

```
{SUPABASE_STORAGE_BUCKET}/qr-signatures/{workspace_id}/{qr_id}.png
```

Deterministic and idempotent by construction: `upsert: "true"` means re-publishing after a design edit
**overwrites in place**, so the URL a user already pasted into their signature never changes and eventually
serves the new design. Both path segments are UUIDs — the object is public-by-necessity but not enumerable.
Upload sets an explicit `cache-control` (recommend `3600`) so an overwrite propagates within an hour rather
than the bucket default; this is the R3 trade, and the panel copy states it.

**Not a `qr_files` row.** We deliberately do **not** register the object in `qr_files` / the media-confirm
path (`storage.py` L347–470): that table drives user-facing file attachments with versioning and quota, and a
derived render artifact does not belong there. It would also make the object count against `max_file_size_mb`
semantics that have nothing to do with it.

**Cleanup (Open Q4 / PRD R6):** the QR delete path should best-effort `bucket.remove([path])` for the
signature object, mirroring the swallow-and-log posture of `_public_url_from_path`. This is a few lines and
avoids adding a *second* uncascaded public artifact while the account-deletion cascade is already a known
liability. Resolve before build.

---

## 3. Backend Design

### 3.1 New router — `qr_backend/src/api/routes/qr_signature.py`

Split out of `qr.py` for the same reason `vcard_ocr.py` was (`qr.py` is already ~2900 lines and CLAUDE.md
flags it). Mounted in `src/api/endpoints.py` beside `vcard_ocr_router` (L59), under the standard JWT prefix,
so `BearerTokenAuthMiddleware` runs and `get_current_user_id` is populated from `request.state`.

```python
router = fastapi.APIRouter(prefix="/workspaces/{workspace_id}/qrs/{qr_id}", tags=["QR Signature"])

@router.post("/signature-image", status_code=200,
             summary="Publish the rendered QR image for an email-signature embed")
async def publish_signature_image(
    workspace_id: uuid.UUID,
    qr_id: uuid.UUID,
    image: UploadFile = File(...),
    member: dict = Depends(require_can_update),   # editor+ — this mutates a workspace-owned artifact
    user_id: str = Depends(get_current_user_id),
    db: Client = Depends(get_supabase),
) -> SignatureImageResponse:
```

`require_can_update` resolves `get_workspace_role(workspace_id)`, which enforces membership and validates the
UUID — that is the tenant boundary (identical to every other workspace-scoped route).

**Handler steps (order matters):**

1. **Tenant cross-check — do not skip.** `require_can_update` proves the caller belongs to `workspace_id`; it
   does **not** prove `qr_id` belongs to that workspace. Without an explicit check a member of workspace A
   could publish arbitrary bytes at `qr-signatures/{A}/{some-other-workspace's-qr}.png` — harmless-ish, but
   it's a path-forgery hole and it corrupts the deterministic-path invariant.
   ```python
   row = (db.table("qr_codes").select("id,type,category")
            .eq("id", str(qr_id)).eq("workspace_id", str(workspace_id))
            .maybe_single().execute())
   if not (row and row.data):
       raise HTTPException(404, detail="QR not found in this workspace.")
   ```
2. **Type + category guard.** Reject anything that isn't a **dynamic** `vcard` / `vcard_plus` → `422`. Keeps
   the endpoint from becoming a general-purpose public-image uploader (PRD §7 scope; relax if Open Q3 opens
   the panel to other types).
3. **Content validation — never trust `content_type`.** Require `image/png`, cap at **512 KB** (a 240 px QR
   PNG is ~10–20 KB; the cap exists to bound abuse, not to accommodate anything real), and **verify the PNG
   magic bytes** `\x89PNG\r\n\x1a\n` on the decoded body. Failures → `415` / `413`, never `500`. We do **not**
   re-decode with Pillow: unlike the OCR path we are not resizing, so there is no decompression-bomb surface
   to open — a byte cap plus a magic-byte check is the right amount of paranoia here.
4. **Upsert to the public bucket** — mirrors `upload_avatar` (L144–148) exactly:
   ```python
   path = f"qr-signatures/{workspace_id}/{qr_id}.png"
   bucket = db.storage.from_(settings.SUPABASE_STORAGE_BUCKET)
   bucket.upload(path=path, file=content,
                 file_options={"content-type": "image/png", "upsert": "true",
                               "cache-control": "3600"})
   return SignatureImageResponse(image_url=bucket.get_public_url(path))
   ```
   `get_public_url` yields a permanent URL because the bucket is public — the property
   `_public_url_from_path` (L1008–1021) already relies on and documents.

**No DB write.** Nothing about the publish is persisted as a row; the object's existence *is* the state, and
the path is derivable from `(workspace_id, qr_id)`. A re-publish is therefore trivially idempotent and there
is no row to get out of sync.

### 3.2 Gating

**None.** No `check_feature`, no `get_limit`, no `FEATURE_ENFORCEMENT` entry, no `_QUOTA_SPEC` entry. The
endpoint's only authorization is workspace membership at editor+ (`require_can_update`) — the same bar as
editing the QR whose image this is. `white_labeling` is read **frontend-side only**, purely to decide whether
the attribution line appears in a string the user copies; there is no server-side behavior to gate.

*(Deliberate divergence from the OCR feature, which needed a flag because it spends money per call. This
spends ~15 KB of storage per card, once.)*

### 3.3 KV / entitlements / internal endpoints / cron

**None of the above.** We do **not** thread anything into `build_kv_content` or `build_entitlements`
(`cloudflare_kv.py` L140–169) — that snapshot governs per-QR *edge rendering*, and the signature never
renders at the edge. No `/internal/*` endpoint, no `x-internal-secret` consumer, no `scheduled()` ping, no
`write_to_kv`/`sync_qr_to_kv` change.

---

## 4. Cloudflare Worker / Edge Design

**No worker change.** Concretely, this feature adds:

- no new QR type and no `handleQRCode` case in `src/handlers/qrRouter.js`;
- no `src/pages/*` template or `templateId` (so the **worker↔React template-mirroring rule does not apply**);
- no new KV top-level key and no `build_kv_content` branch;
- no `recordScan` field, no `ScanEventPayload` field, no consent-gate change;
- no `wrangler.toml` change (no route, no cron, no KV namespace).

The snippet's link and QR payload are both `https://{QR_DYNAMIC_URL}/{short_code}` (or the bound custom
hostname), produced by `generateDynamicQRContent` (`qr-generator.ts` L243–256) — the **same string the QR
already encodes today**. A scan from an email signature therefore traverses the existing
`GET /:shortCode` → KV lookup → `handleQRCode` → `recordScan` path byte-for-byte unchanged.

**Consequence: `npm run deploy:prod` is not a gate for this feature.**

**The one thing we consciously did NOT do at the edge:** appending `?src=email_signature` to the snippet's
link would give us source attribution, but the Worker ignores scan-time query parameters (`src/index.js`
comments the stored-URL-only posture explicitly) and `ScanEventPayload` (`internal.py` L326–347) has no
`utm_*` field — so it would require a Worker change *and* a `qr_scan_events` column *and* a migration, for a
signal that a phone-camera scan can't carry anyway. Deferred wholesale (PRD §7).

---

## 5. Frontend Design

### 5.1 The pure builder — `qr_frontend/src/lib/email-signature.ts`

One exported function, no React, no DOM, fully unit-testable:

```ts
export type SignatureLayout = 'card' | 'compact';

export interface EmailSignatureInput {
  imageUrl: string;      // absolute https:// PNG (published)
  cardUrl: string;       // absolute https:// short URL (generateDynamicQRContent)
  displayName: string;   // "First Last"
  jobTitle?: string;
  company?: string;
  layout: SignatureLayout;
  sizePx: 96 | 120;      // rendered size; the hosted PNG is 2× this
  showAttribution: boolean;  // false when white_labeling
}

export function buildEmailSignature(input: EmailSignatureInput): string;
```

**Hard output rules (each one exists because a specific client breaks without it):**

| Rule | Why |
|---|---|
| `<table role="presentation" border="0" cellpadding="0" cellspacing="0">` layout | Outlook desktop (Word engine) has **no** flexbox/grid |
| `width`/`height` as **HTML attributes** on `<img>`, not only CSS | Outlook ignores CSS sizing on images |
| Every style **inline on the element** (`style="…"`) | `<style>` blocks and classes are stripped by Gmail |
| Absolute `https://` `src` — **never** a `data:` URI | Gmail/Outlook.com strip `data:` images; Word blocks them |
| PNG only — **no `<svg>`** | SVG in email is unsupported in Outlook and inconsistent elsewhere |
| Hex colors only (no `rgba()`, `oklch()`, CSS vars) | Word/older clients drop modern color syntax |
| System font stack (`Arial, Helvetica, sans-serif`) — no web fonts | Web fonts don't load in most clients |
| `alt` on the image; **always** a text `<a>` beside it | Remote images are blocked by default in many clients (R4) |
| `<a>` carries inline `color` + `text-decoration` + `target="_blank"` | Clients reset link styling |
| **No `<script>`**, no event attributes | Universally stripped; also our own XSS bar |
| Escape `& < > " '` on every interpolated field | R5 — user text goes into markup we also render |

Escaping is a small local helper (the frontend counterpart of the Worker's `escapeHTML` in
`qr_cf_code/src/utils/html.js`; the FE is a separate service and cannot import it). Total output is ~0.8–1.2
KB — far under Gmail's 102 KB message-clipping threshold, which is precisely why we host the image instead of
base64-inlining it.

### 5.2 The panel — `email-signature-card.tsx`

A kebab-case, one-export component (≤200 lines) under
`qr_frontend/src/components/org/qrs/details/`, mounted in `overview-tab.tsx` beneath `qr-preview-card.tsx`,
rendered only when `qr.category === 'dynamic' && (qr.type === 'vcard_plus' || qr.type === 'vcard')`.

- **On mount:** render the PNG using the *exact* `useQRPreview` pipeline (§1 data flow) at `2 × sizePx`, convert
  the canvas dataURL to a `Blob`, and fire `useSignatureImage`. Show a spinner in the preview slot until
  `image_url` returns (PRD Open Q5: publish eagerly — a preview showing a *different* image than the copied
  block would be dishonest).
- **Controls:** shadcn `Tabs`/toggle for layout (Card / Compact) and size (S 96 / M 120). No raw `<button>`
  where a shadcn primitive exists, no inline styles **in the component** (the inline styles live inside the
  generated string, which is data, not JSX), Tailwind tokens only.
- **Preview:** `<iframe srcdoc={html} sandbox className="…" title="Email signature preview" />`. The sandbox
  gives style isolation (our Tailwind/reset cannot leak in and flatter the block) **and** script
  neutralization (R5 belt-and-braces). Height is fixed to the block's known height per layout.
- **Copy:**
  ```ts
  const rich = typeof ClipboardItem !== 'undefined' && !!navigator.clipboard?.write;
  // primary (rich): write both flavours so a WYSIWYG signature box gets the RENDERED block
  await navigator.clipboard.write([new ClipboardItem({
    'text/html':  new Blob([html], { type: 'text/html' }),
    'text/plain': new Blob([plainFallback], { type: 'text/plain' }),
  })]);
  // secondary (always): navigator.clipboard.writeText(html)  → "Copy HTML source"
  ```
  When `rich` is false (Firefox), the primary button is **hidden** — never shown-but-broken (R8). A selectable
  `<pre>` is always rendered as the last-resort path, exactly as `EmbedSnippet.tsx` (L112–125) does.
- **Attribution:** `showAttribution = !canAccessFeature(subscription, 'white_labeling')`, read from
  `useCurrentSubscription(workspaceId)` which `QRDetails.tsx` already calls (L94, L107).
- **Instructions:** three one-line client hints (Gmail / Outlook / Apple Mail) in a shadcn `Accordion` or
  muted paragraph. Copy only.

If the component exceeds 200 lines, split the preview + instructions into
`email-signature-preview.tsx` — one export per file, kebab-case, per the house rules.

### 5.3 The hook — `qr_frontend/src/hooks/useSignatureImage.ts`

TanStack **mutation** via `authApi` (never `useEffect + fetch`), following the domain key-factory convention:

```ts
export const signatureKeys = {
  all: ['qr-signature'] as const,
  image: (qrId: string) => [...signatureKeys.all, 'image', qrId] as const,
};

export function useSignatureImage(workspaceId: string, qrId: string) {
  return useMutation({
    mutationFn: async (png: Blob) => {
      const fd = new FormData();
      fd.append('image', png, 'signature.png');
      const { data } = await authApi.post<{ image_url: string }>(
        `/workspaces/${workspaceId}/qrs/${qrId}/signature-image`, fd,
        { headers: { 'Content-Type': 'multipart/form-data' } });
      return data;
    },
    onError: (e) => toast.error(asErrorMessage(e)),
  });
}
```

`workspaceId` comes from `useWorkspaceStore((s) => s.currentWorkspace)?.id` (house rule — never URL params),
which `QRDetails.tsx` already resolves (L88–89). No new query key on the read side: the panel holds the
returned `image_url` in local state for the session and re-publishes on remount, which is idempotent.

### 5.4 Types

No change to `QRCode`. The panel reads `qr.short_code`, `qr.custom_domain_id`, `qr.design.qr_design`, and the
vCard fields already present in `qr.content` (populated from `qr_vcard_details` via `SELECT_WITH_RELATIONS`).

---

## 6. External-Service Integration

**None.** No AI/Anthropic call, no Resend/email send, no payment provider, no PDF renderer, no new SDK, no new
environment variable or secret. The only "integration" is the **existing** Supabase Storage client already
used by `upload_avatar` and `branding.py`, through the already-configured
`settings.SUPABASE_STORAGE_BUCKET`.

**Not gates for this feature (stated explicitly so nobody re-litigates them):** the unpublished
`_dmarc.qravio.app` record (**no email is sent** — we generate text the user pastes into their own client),
`ANTHROPIC_API_KEY`, and the prod Worker deploy.

**And — deliberately — no NFC.** No tag encoder, no NDEF library, no hardware vendor, no fulfilment surface.
The competitive analysis's Skips section rejects in-house NFC; this feature is bundled with it in
competitors' marketing and must not inherit the dependency. Nothing in this design references a physical tag.

---

## 7. API Contracts

One new route. Everything else the panel needs is already on the QR read response.

**POST** `/api/v1/workspaces/{workspace_id}/qrs/{qr_id}/signature-image` — `multipart/form-data`, field
`image` (one PNG).

```jsonc
// 200 OK — permanent public URL; identical on every re-publish (deterministic path + upsert)
{ "image_url": "https://<project>.supabase.co/storage/v1/object/public/<bucket>/qr-signatures/<ws>/<qr>.png" }

// 403 — caller is not an editor+ member of the workspace (require_can_update)
{ "detail": "Insufficient permissions." }

// 404 — qr_id does not belong to workspace_id (explicit cross-check, §3.1 step 1)
{ "detail": "QR not found in this workspace." }

// 422 — not a dynamic vcard/vcard_plus QR
{ "detail": "Email-signature images are only available for vCard QR codes." }

// 413 image too large (>512 KB) · 415 not a PNG (magic-byte check, content_type is advisory)
{ "detail": "Signature image must be a PNG under 512 KB." }
```

**The generated snippet (the real contract with the outside world).** Card layout, abridged — note every
constraint from §5.1 is visible in it:

```html
<table role="presentation" border="0" cellpadding="0" cellspacing="0"
       style="border-collapse:collapse;font-family:Arial,Helvetica,sans-serif">
  <tr>
    <td style="padding:0 12px 0 0;vertical-align:middle">
      <a href="https://qr.qravio.app/AbC123" target="_blank" style="text-decoration:none">
        <img src="https://…/qr-signatures/…png" width="120" height="120"
             alt="Scan to save Sana Iqbal's contact card"
             style="display:block;border:0;outline:none;width:120px;height:120px" />
      </a>
    </td>
    <td style="vertical-align:middle">
      <div style="font-size:15px;font-weight:bold;color:#111827">Sana Iqbal</div>
      <div style="font-size:13px;color:#4b5563">Regional Sales Lead · Northwind Logistics</div>
      <div style="font-size:13px;margin-top:4px">
        <a href="https://qr.qravio.app/AbC123" target="_blank"
           style="color:#4648d4;text-decoration:underline">View my contact card</a>
      </div>
      <!-- omitted entirely when white_labeling is true -->
      <div style="font-size:11px;color:#9ca3af;margin-top:6px">Contact card by Qravio</div>
    </td>
  </tr>
</table>
```

---

## 8. Security, Privacy & Abuse

- **Auth / tenancy:** the endpoint sits under `/api/v1` → Bearer JWT middleware + `require_can_update`
  (editor+). It is **not** in `excluded_routes`, **not** an `/internal/*` route, and consumes no
  `x-internal-secret`. Because the service-role client bypasses RLS, tenancy is enforced in code — and the
  **explicit `qr_id ∈ workspace_id` cross-check (§3.1 step 1) is load-bearing**, not decorative: without it
  the storage path is caller-forgeable.
- **Upload abuse:** PNG-only by **magic bytes** (not the advisory `content_type`), 512 KB cap, and a
  **deterministic path** — a caller cannot choose the filename, so the endpoint cannot be used to stash
  arbitrary objects or to overwrite avatars/branding logos in the shared bucket. One QR = at most one object,
  overwritten in place; there is no unbounded-growth vector.
- **No decode surface:** we store bytes verbatim (no resize/transcode), so there is no Pillow decompression-
  bomb path to guard — unlike `card_ocr.downscale()`. Deliberate: the smallest safe amount of processing.
- **Public-by-necessity object:** the PNG must be publicly fetchable or email clients cannot render it. It
  encodes **only** the short URL, which is already public by definition (it's printed on QR codes). Path is
  two UUIDs → not enumerable. No PII in the object or its path.
- **We do not turn signatures into tracking pixels.** The hosted image will be fetched by every recipient's
  mail client. Deriving open/read analytics from those fetches would be unconsented recipient tracking
  (DPDP/GDPR). We make no such read, ship no such metric, and say so in help-center copy. **This is a product
  commitment, and the absence of a metric is the enforcement.**
- **XSS in our own dashboard (R5):** vCard fields are interpolated into an HTML string that we render. Two
  independent defenses: (1) escape `& < > " '` on every field in the builder; (2) render the preview in
  `<iframe srcdoc sandbox>` so nothing executes in our origin even if (1) regresses. The generated snippet
  contains **no** `<script>` by construction, and a unit test asserts it.
- **SSRF:** none — no user-supplied URL is fetched server-side. The `imageUrl` and `cardUrl` are both
  constructed by us from our own config; the vCard `website` field is data we escape and (in v1) don't even
  render.
- **Consent gate / scan path:** unaffected. No edge change, no new client capture, no marketing tag.

---

## 9. Performance, Scale & Cost

- **Backend:** one multipart upload of ~10–20 KB and one `get_public_url` per publish. One `qr_codes` SELECT
  for the tenancy cross-check. No DB write, no RPC, no `resolve_plan`. Negligible.
- **Frontend:** one extra `generateQRCode` call at 2× display size (the same canvas work
  `useQRPreview` already does on this page — tens of ms) plus one upload. Publishing is fire-once per panel
  mount, not per keystroke; the layout/size toggles rebuild the **string** only, and a size change re-publishes
  only if the 2× target changes.
- **Storage:** ≤ ~20 KB per published card, capped at one object per QR by the deterministic path. Even at
  100k published cards that is ~2 GB — and the overwrite semantics mean it never grows per re-publish.
- **CDN:** recipient fetches are served by Supabase Storage's CDN and never touch our backend or the Worker.
  This is the reason a signature that goes out to thousands of recipients costs us nothing at request time.
- **Cost:** no per-use COGS. No AI, no metered third party, no compute per scan. Nothing to throttle, so no
  quota, so no counter, so no migration — the chain of "no"s is self-consistent.

---

## 10. Testing Strategy

**Frontend (Vitest) — the builder is where the value and the risk both live.** `src/lib/email-signature.ts`
is pure, so these are fast and deterministic:
- **Portability invariants** (assert on the output string, per §5.1): contains no `<script`, no `class=`, no
  `<style`, no `data:` URI, no `<svg`, no `rgba(`/`var(--`, no `display:flex`/`grid`; the `<img>` has an
  absolute `https://` `src`, **both** `width`/`height` attributes, and a non-empty `alt`; the table carries
  `role="presentation"` + `border="0"`.
- **Escaping (R5):** a company of `Ben & Jerry's <b>` and a name containing `"` produce escaped entities and
  no raw tag; a field containing `<script>alert(1)</script>` appears inert and escaped in the output.
- **White-label:** `showAttribution: false` → the "Contact card by Qravio" line is absent; `true` → present.
- **Layouts + sizes:** `card` and `compact` both produce well-formed, balanced tables; `sizePx` appears in
  the attributes **and** the inline style; a snapshot per (layout × size) catches accidental drift.
- **Degradation (R4):** the text `<a href>` to `cardUrl` is present in **every** variant, so an images-off
  client still shows a working link.
- **Panel/hook:** `useSignatureImage` success/403/413 with mocked `authApi`; the panel renders for
  `vcard_plus`/`vcard` and **not** for other types; the rich-copy button is hidden when `ClipboardItem` is
  undefined. *(Note the ~29 pre-existing FE test failures baseline — only net-new failures in
  `email-signature*` files are regressions.)*

**Backend (pytest, `qr_backend/tests/`):**
- `test_signature_image_tenancy`: a `qr_id` from another workspace → **404** (the §3.1 step-1 cross-check);
  a viewer-role member → 403; a non-member → 403.
- `test_signature_image_validation`: non-PNG bytes sent as `image/png` → **415** (magic-byte check beats the
  advisory header); > 512 KB → 413; a `website` QR → 422.
- `test_signature_image_idempotent`: two publishes for the same `(workspace_id, qr_id)` write the **same**
  path with `upsert` and return the **same** URL (the property already-pasted signatures depend on).
- No feature-gate tests — there is no flag. `test_feature_gate_coverage` must remain green **unchanged**;
  if this feature causes it to move, something was added that shouldn't have been.

**Worker:** none — no worker change.

**Manual client matrix — the release gate (automation cannot cover this).** Paste the copied block into each
and verify layout, image render, link click, and a phone scan of the on-screen QR at the **S (96 px)** size:

| Client | Why it's in the matrix |
|---|---|
| **Outlook desktop (Windows)** | **The gate.** Word rendering engine — no flexbox, ignores CSS image sizing |
| Gmail web | Highest volume; strips `<style>`/classes |
| Gmail iOS + Android | Mobile reflow of the two-column table |
| Outlook 365 web | Different engine from desktop Outlook; sanitizes differently |
| Apple Mail macOS + iOS | Most permissive — the sanity baseline |

Plus: images-blocked mode in at least one client (R4), and a **rich-paste check** — pasting into Gmail's
signature WYSIWYG must land the *rendered block*, not visible markup.

---

## 11. Observability & Rollout

**Phase 0 — Builder + endpoint (internal, no UI).** Ship `email-signature.ts` with its full invariant test
suite and `qr_signature.py`. Verify the published URL is fetchable **with no auth from a clean session** (the
whole feature depends on this) and that the tenancy cross-check rejects a foreign `qr_id`. No migration to
apply — confirm none was introduced.

**Phase 1 — Panel behind a FE flag (closed).** Mount `email-signature-card.tsx` on the detail overview tab for
internal + a few design-partner workspaces (`NEXT_PUBLIC_EMAIL_SIGNATURE_BETA`). **Run the full client
matrix; Outlook desktop is the gate.**
- **Acceptance:** publish → copy → paste in Gmail **and** Outlook desktop → block renders → on-screen QR
  scans from a phone at S size → link resolves to the card → images-off still shows a working link → an
  Agency workspace shows no attribution → a design edit + re-copy overwrites the **same** URL.

**Phase 2 — GA.** Remove the FE flag; help-center entry; comparison-matrix cell; vCard SEO-page mention;
optional one-time in-app nudge on existing `vcard_plus` QRs. Resolve Open Q4 (delete-cascade) before GA.

**Deploy order:** backend (endpoint) **before** frontend — the panel calls it on mount and a 404 would make
the preview permanently spin. **No migration step. No worker deploy. No DMARC gate. No cron.**

**Metrics / logs:** structured log per publish (`workspace_id`, `qr_id`, byte size, outcome — no PII, no image
bytes). Product metrics per PRD §9: publish rate among `vcard_plus`-owning workspaces, panel-open →
copy-success rate, and the **cohort** scan comparison (published vs not) explicitly labeled as a cohort
comparison, not attribution. **Explicitly not instrumented:** image-fetch counts (§8).

---

## 12. Open Technical Questions & Risks

1. **Client-render + host vs server-side render — resolved: client renders, backend hosts.** A Python
   renderer would need a new dependency and would reproduce none of `designToGeneratorOptions` /
   `FrameTemplates`, shipping a signature QR that doesn't match the user's downloaded one and drifting
   forever. One renderer, one upload.
2. **No migration — confirm at build.** The claim rests on: no new column/table/RPC, no plan-features key,
   Storage objects aren't schema. **If review decides the panel needs a persisted `signature_image_url` or a
   published-at timestamp, that becomes a migration and this header is wrong** — re-verify the next free slot
   at that point (the repo has a commit fixing stale slot numbers, and `0033` is claimed by
   QR_EXPIRY_SCHEDULING).
3. **Delete cascade for the published object (PRD Open Q4 / R6)** — recommend a best-effort
   `bucket.remove([...])` in the QR delete path, in this PR. Adding a second uncascaded public artifact while
   the account-deletion cascade is a known open liability is the wrong default. Decide before build.
4. **CDN cache TTL on overwrite** — `cache-control: 3600` is the recommendation: short enough that a design
   edit propagates the same day, long enough that a widely-distributed signature isn't re-fetching
   constantly. Confirm the bucket-level default doesn't override the per-object header.
5. **Rich clipboard (`text/html`) coverage** — Chromium/Safari solid, Firefox weak. Feature-detect and hide
   rather than degrade silently (R8). Confirm the shipped detection also covers the case where
   `ClipboardItem` exists but `write` rejects (permissions) — that must fall through to source-copy, not to a
   dead button.
6. **Type scope (PRD Open Q3)** — v1 restricts the endpoint *and* the panel to dynamic `vcard`/`vcard_plus`.
   Note that the endpoint's 422 type-guard is what stops it becoming a general public-image uploader; if the
   panel is later opened to other types, the guard must widen deliberately, not be deleted.
7. **Outlook desktop is a manual gate, not a CI gate** — accepted. There is no headless Word engine to test
   against. The mitigation is the rule table in §5.1 encoded as *string* assertions in Vitest (which catch
   regressions like "someone added a flexbox div") plus the human matrix per release that touches the builder.
8. **No source attribution (PRD §7)** — accepted and documented. Adding it means a Worker query-param capture
   **plus** a `qr_scan_events` column **plus** a migration, for a signal a camera scan cannot carry. Do not
   half-ship it (e.g. a `?src=` param that nothing reads) — that reads as a working feature and isn't one.

### Appendix — Key Files

| Concern | File |
|---|---|
| Snippet builder (pure, unit-tested) | `qr_frontend/src/lib/email-signature.ts` (**NEW**) |
| Builder tests | `qr_frontend/src/lib/__tests__/email-signature.test.ts` (**NEW** — portability invariants + escaping + snapshots) |
| Signature panel | `qr_frontend/src/components/org/qrs/details/email-signature-card.tsx` (**NEW**, ≤200 lines; split preview into `email-signature-preview.tsx` if over) |
| Panel mount | `qr_frontend/src/components/org/qrs/details/overview-tab.tsx` (below `qr-preview-card.tsx`) |
| Copy-panel precedent | `qr_frontend/src/components/marketing/EmbedSnippet.tsx` (copy + `<pre>` fallback, L50–58 / L112–125) |
| QR render pipeline (reused verbatim) | `qr_frontend/src/hooks/useQRPreview.ts` (L27–57); `qr_frontend/src/lib/qr-generator.ts` (`generateQRCode` L64, `generateDynamicQRContent` L243–256); `qr_frontend/src/components/qr-generator/FrameTemplates.ts` |
| Publish hook | `qr_frontend/src/hooks/useSignatureImage.ts` (**NEW** — TanStack mutation via `authApi`) |
| White-label read | `qr_frontend/src/lib/plan-features.ts` `canAccessFeature` (L14–21); subscription already fetched in `QRDetails.tsx` (L94/L107) |
| Publish endpoint | `qr_backend/src/api/routes/qr_signature.py` (**NEW**), mounted in `qr_backend/src/api/endpoints.py` (beside `vcard_ocr_router`, L59) |
| Upload pattern mirrored | `qr_backend/src/api/routes/storage.py` `upload_avatar` (L121–149 — public-bucket upsert → `get_public_url`) |
| Public-URL semantics | `qr_backend/src/api/routes/qr.py` `_public_url_from_path` (L1008–1021 — bucket is public, URL permanent) |
| Permission dep | `qr_backend/src/api/dependencies/permissions.py` `require_can_update` (L23) |
| Ungated rationale | `qr_backend/migrations/0009_pricing_v3_4tier_collapse.sql` (L98 — Free has `vcard_plus`); `0027_open_all_qr_types.sql` |
| Gating registry | `qr_backend/src/api/routes/subscription.py` `FEATURE_ENFORCEMENT` (L525–560) — **no entry added; must stay unchanged** |
| Why no attribution metric | `qr_backend/src/api/routes/internal.py` `ScanEventPayload` (L326–347 — no `utm_*`); `qr_cf_code/src/utils/scan.js` `recordScan` (referer only) |
| Migration | **None** — no column, table, RPC, RLS policy, or plan-features key |
| Worker | **No change** — no KV key, no template, no `qrRouter.js` case, no cron ⇒ **no `npm run deploy:prod`** |
