# TRD — Phone / Call Static QR

**Status:** Draft · **Author:** Engineering (Staff) · **Date:** 2026-07-25
**Priority:** Quick win (gap-analysis **#9**, S effort). Hours of work — an additive clone of the `sms` static type plus one programmatic SEO entry. Zero new infrastructure; the only genuine risk is real-device `tel:` behavior and irreversible printed output (PRD R2).
**Tiers:** **All plans, ungated**, including logged-out. Static types have never been plan-gated: the `dynamic_qr_types` check is scoped by `if category == "dynamic":` (`qr_backend/src/api/routes/qr.py:1548`), and `0027_open_all_qr_types.sql` rewrites only that array.
**Plan flags (NEW):** **None.** No `FEATURE_ENFORCEMENT` entry, no `_QUOTA_SPEC` entry, no `plans.features` seed. `test_feature_gate_coverage` is untouched (it diffs seeded JSONB keys against the registry — we add neither).
**Migration slot:** **None — no migration required.** The `phone` payload is a single scalar persisted as `qr_destinations[0].target_url = "tel:<number>"`, the same row every static type already writes (`qr.py:1634–1656`, fed by `build/page.tsx:282` → `:332`). No new table, no new column, no `plans.features` change, no RLS change. *(If eng-review overrides this and demands a `qr_phone_details` table to mirror `sms` exactly, use provisional slot **`0036`** — **re-verify against `qr_backend/migrations/` at build time**: highest on disk today is `0032_lemonsqueezy_variant_backfill.sql`, and `0033` is claimed by the QR-expiry TRD, so `0036` is a reservation, not a fact. See §2 and §12 Q1 for why we recommend against it.)*
**Services touched:** `qr_backend` (one `Literal` member, one Pydantic model, one read-back branch) · `qr_frontend` (type constants, `tel:` encoder case, one form component, dispatch cases, one `TYPE_PAGES` + one `TOOL_FAQS` entry, API-docs constants). **`qr_cf_code` — no change; `npm run deploy:prod` is NOT required.**
**Implements PRD:** Phone / Call Static QR. **Mirrors** the `sms` static-type recipe end to end (`SMSContent` model `qr.py:432` → `generateStaticQRContent` `case 'sms'` `qr-generator.ts:151` → `SMSContent.tsx` → `TYPE_PAGES` `sms` entry `qr-type-pages.ts:1143`), **minus** the detail table (§2).

**Rev (2026-07-25, post eng-review):** Reviewed via `/plan-eng-review`; ships as-drafted. The §2 / §12-Q1 "no table (flag for eng-review)" question is **resolved: NO `qr_phone_details` table, NO migration.** Phone reconstructs `phoneContent` from the `tel:` destination in `_build_content_from_db_rows` (like `url`/`text`, `qr.py:1182`). The contingency slot-`0036` table is **not** taken — a deliberate, reviewed divergence from `sms`'s detail table (phone = one scalar; UPI got `qr_upi_details` only because it has four structured fields). Consume the vestigial `phoneSchema` (R6), don't duplicate; no-separator-stripping stands (R2). The real-device iOS+Android `tel:` scan check remains the one blocking acceptance gate.

---

## 1. Overview & Architecture

A new **`phone` static QR type** encodes a `tel:` URI directly into the QR pixels. The user supplies one
phone number; the frontend renders `tel:+919876543210` via `generateStaticQRContent`; the same string is
sent as the QR's single destination and encoded into the downloadable image. Scanning it hands the URI to
the OS, which opens the dialer. **Nothing in this feature runs at scan time** — there is no server, no
edge, and no network hop between the camera and the dialer.

That is the architectural fact that shapes every other decision here: **static QRs never write to
Cloudflare KV.** The KV write in the create handler is fenced behind `if category == "dynamic":`
(`qr.py:2250–2262`), so `build_kv_content()` / `write_to_kv()` are never reached for a static QR, no
`shortCode` key is ever created, the Worker never sees a scan, and `recordScan` never fires. Therefore:
**no Worker change, no KV model change, no template, no `build_kv_content` branch, no
`npm run deploy:prod` gate — and no scan analytics, permanently** (PRD §3, R1).

The second shaping fact: **static QRs are name-only editable.** `update_qr` returns `403 "Static QR codes
can only have their name updated."` for any field beyond `name` (`qr.py:2790–2796`). So there is no
content-edit round-trip to support, which is a large part of why the detail table is unnecessary (§2).

**Services touched**

| Service | Change |
|---|---|
| `qr_backend` | Add `"phone"` to the `QRCodeCreate.type` `Literal` union (`qr.py:838–863`); add a `PhoneContent` Pydantic model beside `SMSContent` (`qr.py:432`) and a `phoneContent` field on `QRContent` (`qr.py:~540`); add a `qr_type == "phone"` branch to `_build_content_from_db_rows` (`qr.py:1062`) that reconstructs `phoneContent` from the `tel:` destination. **No migration, no detail table, no `SELECT_WITH_RELATIONS` change, no KV code, no gating, no new route.** `api_public.py` inherits the type for free — it reuses `qr_routes.QRCodeCreate` (`api_public.py:313`). |
| `qr_frontend` | `ALL_TYPES` / `QR_TYPES` / `TYPE_ICONS` entries (`qr-types.ts`); `case 'phone'` in `generateStaticQRContent` (`qr-generator.ts`); NEW `PhoneContent.tsx` (≤200 lines, one export) + barrel + `QRContent.tsx` dispatch case + `content-editor-dispatch.tsx` case; `isStaticContentComplete` case (`PublicQRBuilder.tsx`); `phoneContent` on the `QRContent` TS interface (`types/qr.ts`); `qr-type-icons.ts` + `qr-recommendations.ts` entries; NEW `TYPE_PAGES` entry (`isStaticTool: true`) + `TOOL_FAQS.phone`; `STATIC_TYPES` + `CONTENT_BY_TYPE` in `api-docs-objects.ts`. |
| `qr_cf_code` | **No change.** No KV key, no `handleQRCode` case, no `src/pages/*` module, no `recordScan` field, no `wrangler.toml` change. The Worker↔React template-mirroring house rule does not apply — a static type has no scan page to mirror. |

**Data flow — create (logged-in builder)**

```
PhoneContent.tsx (one field, zod phoneSchema: /^\+?\d{10,15}$/)
  → qrData.content.phoneContent = { number: "+919876543210" }
  → build/page.tsx:282  targetUrl = generateStaticQRContent('phone', content)  →  "tel:+919876543210"
  → build/page.tsx:332  destinationsPayload = [{ target_url: targetUrl }]
  → authApi POST /workspaces/{id}/qrs { type:"phone", category:"static", content, destinations }
  → qr.py: type Literal accepts "phone"
      · dynamic_qr_types gate SKIPPED (guarded by `category == "dynamic"`, L1548)
      · qr_codes row inserted; a short_code is minted unconditionally (L1615) but is inert for static
      · qr_destinations row: target_url = "tel:+919876543210"           ← the ONLY persistence
      · NO detail-table insert; NO build_kv_content / write_to_kv (fenced at L2250)
  → response: content reconstructed by _build_content_from_db_rows (qr_type="phone" branch)
```

**Data flow — scan (there isn't one)**

```
Camera scans the printed code
  → OS parses "tel:+919876543210"
  → native dialer opens, pre-filled; user taps to call
  (no Qravio request, no Worker, no KV, no recordScan, no analytics row — ever)
```

**Data flow — free tool (logged out)**

```
/phone-qr-code-generator  → QrToolPageContent → PublicQRBuilder
     initialType="phone" initialCategory="static" initialStep={2}   (QrToolPageContent.tsx:52–57)
  → isStaticContentComplete('phone', content) → !!content.phoneContent?.number?.trim()
  → generateStaticQRContent → tel: URI → client-side render + download (no backend call at all)
  → "Save to account" → savePendingQR({category:'static', qrType:'phone', ...}) → /signup
```

---

## 2. Data Model & Migrations

### **No migration is required.** Reasoning, stated plainly:

A `phone` QR carries exactly **one scalar** — a phone number — and static QR content is **write-once**
(`qr.py:2790–2796` blocks every non-`name` update). The existing static-QR persistence path already
stores that scalar losslessly: the builder writes `generateStaticQRContent(...)` output into
`destinations[0].target_url` (`build/page.tsx:282` → `:332`), which lands in the **existing**
`qr_destinations` table (`qr.py:1634–1656`). For `phone` that value is `tel:+919876543210` — the complete,
canonical, round-trippable payload. There is nothing left to store.

**Why `sms` has a table and `phone` doesn't.** `qr_sms_details` exists because `sms` carries **two**
fields, and the encoded form (`sms:<number>?body=<urlencoded>`, `qr-generator.ts:151–155`) is **not**
safely reversible — a message body can itself contain `?`, `&`, and `%`-sequences, so parsing the URI
back into `{number, message}` is lossy in the general case. A table is the correct answer there. `tel:`
has no such problem: strip the four-character `tel:` prefix and you have the number back, exactly.
Adding a table for one reversible scalar would mean a migration to apply by hand, a new
`SELECT_WITH_RELATIONS` join on the **hottest query in the codebase** (`qr.py:998` — one string that
already embeds 19 related tables and is used by both the single-QR and list endpoints), a
`QRPhoneDetailsResponse` model, an insert branch, a `_row_to_response` pop, and a `_build_content_*`
parameter — **six touch-points and a permanent join cost, to store a substring of a column we already
write.**

**This is not a shortcut — it's the pattern the read stack already assumes.** `_build_content_from_db_rows`
already falls back to `kwargs["url"] = destinations[0].target_url` when a static type has no detail row
(`qr.py:1180–1181`), and the public preview endpoint **explicitly** renders
`qr_destinations[0].target_url` for `category == "static"` rather than the short link
(`api_public.py:1124–1127`). Storing the `tel:` URI in the destination is what makes the preview SVG
encode the right thing with zero new code (PRD R7).

**Existing tables touched:** `qr_codes` (one new value in the `type` text column — no constraint change;
the union is enforced in Pydantic, not the DB) and `qr_destinations` (one ordinary row). **No new table,
no new column, no index, no RLS change, no `plans.features` write.**

**Verification checklist before build** (do not trust this header blind):
```sql
-- 1) Confirm `qr_codes.type` is unconstrained text (no CHECK / no enum) — if a CHECK
--    constraint or a Postgres enum exists, 'phone' WILL fail on insert and a real
--    migration IS required. Verified-by-inspection: the union lives only in Pydantic
--    (qr.py:838-863). CONFIRM AGAINST THE LIVE DB before merging.
SELECT conname, pg_get_constraintdef(oid)
  FROM pg_constraint
 WHERE conrelid = 'qr_codes'::regclass AND contype = 'c';

SELECT column_name, data_type, udt_name
  FROM information_schema.columns
 WHERE table_name = 'qr_codes' AND column_name = 'type';
```
If — and only if — that query reveals a `CHECK (type IN (...))` or an enum type, the feature needs a
one-line migration in the next free slot (provisional **`0036`**; re-verify against
`qr_backend/migrations/`, where the highest on disk is `0032_lemonsqueezy_variant_backfill.sql` and
`0033` is reserved by the QR-expiry TRD):
```sql
BEGIN;
-- ONLY if qr_codes.type is constrained. Extends the allowed set with 'phone';
-- does NOT touch plans.features (static types are ungated by design — the
-- dynamic_qr_types gate is scoped to `category == "dynamic"`, qr.py:1548).
ALTER TABLE qr_codes DROP CONSTRAINT IF EXISTS qr_codes_type_check;
ALTER TABLE qr_codes ADD  CONSTRAINT qr_codes_type_check
  CHECK (type IN ( /* …existing 24 values…, */ 'phone' ));
COMMIT;
-- Sanity: SELECT DISTINCT type FROM qr_codes ORDER BY 1;
```
**RLS note:** unchanged and not applicable — no new table is created, and the backend uses the Supabase
**service-role** client which bypasses RLS on `qr_codes`/`qr_destinations` regardless. Tenant isolation
stays where it already is: the explicit `.eq("workspace_id", …)` filters plus `require_can_create` /
`get_workspace_role`.

---

## 3. Backend Design

### 3.1 Type union — `qr_backend/src/api/routes/qr.py` (~L838–863)
Add one member to `QRCodeCreate.type`'s `Literal`, next to `"sms"` (L859):
```python
        "sms",
        "phone",          # static tel: URI — no KV, no worker, no analytics
```
This single line is what unlocks the type across **both** APIs: `api_public.py:313` types its create
handler as `payload: qr_routes.QRCodeCreate`, so the Public API accepts `phone` with no further change.
`QRCodeUpdate.type` is a bare `Optional[str]` (L887) — nothing to add there, and static updates are
`403`-blocked anyway (§1).

### 3.2 Content model — `qr_backend/src/api/routes/qr.py` (~L432, ~L540)
Mirror `SMSContent` exactly, minus the message:
```python
class PhoneContent(pydantic.BaseModel):
    number: str
```
and register it on `QRContent` beside `smsContent` (~L540):
```python
    phoneContent: Optional[PhoneContent] = None
```
**This field is required for the API contract to be real.** `QRContent` uses Pydantic's default
`extra="ignore"`, so an un-modeled `phoneContent` in the request body would be **silently dropped** —
the QR would still be created correctly (the payload rides `destinations[0].target_url`), but the
create response would echo no `phoneContent`, and the Public API's documented content object would be a
lie. Add the model.

**No `QRPhoneDetailsResponse`, no insert branch.** Unlike `sms` (`qr.py:1987–1999`), there is no
`db.table("qr_phone_details").insert(...)` step — §2. Do not add one.

### 3.3 Read-back reconstruction — `_build_content_from_db_rows` (`qr.py:1062`)
The helper **already receives `qr_type`** (`qr.py:1064`), so the branch is three lines. Place it beside
the existing destination fallback (`qr.py:1180–1181`):
```python
    if destinations:
        kwargs["url"] = destinations[0].target_url        # existing, unchanged
        if qr_type == "phone":                            # NEW
            _tel = destinations[0].target_url or ""
            kwargs["phoneContent"] = PhoneContent(
                number=_tel[4:] if _tel[:4].lower() == "tel:" else _tel
            )
```
Notes for the implementer:
- `destinations` here is a list of `QRDestinationResponse` **objects**, not dicts — use attribute access
  (`.target_url`), matching the existing line above it. Getting this wrong is the one plausible way to
  500 the QR **list** endpoint, which calls the same helper via `_row_to_response` (`qr.py:1420`).
- Keep `kwargs["url"]` populated as well. Every static type today surfaces its raw payload in
  `content.url`; dropping it for `phone` would be a gratuitous asymmetry, and the FE preview path reads
  it.
- The `any([...])` early-return guard at `qr.py:1094–1114` already includes `destinations`, so a phone QR
  (destination-only, no detail rows) passes it. **No change needed there** — but re-read it at build
  time to confirm, because an early `return None` would blank the whole `content` object.
- `_row_to_response` (`qr.py:1390–1432`) needs **no change**: there is no `qr_phone_details` list to pop
  and no new kwarg to thread.

### 3.4 What deliberately does NOT change
- **`SELECT_WITH_RELATIONS` (`qr.py:998`)** — no new embed. This is the hot query for both the single-QR
  and list endpoints; keeping it untouched is a stated goal of the no-table decision (§2).
- **KV (`qr.py:2250–2262`, `src/utilities/cloudflare_kv.py`)** — `build_kv_content()` gets **no `phone`
  branch**. The "adding a new QR type" checklist in `CLAUDE.md` assumes a *dynamic* type; steps 1–3 of it
  (Worker dispatch case, `build_kv_content` branch, page module) are **N/A** for a static type. If a
  reviewer asks why `build_kv_content` wasn't touched, the answer is `qr.py:2250`.
- **Gating (`subscription.py`)** — no `FEATURE_ENFORCEMENT` key, no `_QUOTA_SPEC` key, no `check_feature`
  call. The `dynamic_qr_types` gate at `qr.py:1548–1567` is inside `if category == "dynamic":` and must
  **not** be widened. Do **not** add `"phone"` to any `dynamic_qr_types` array — `0027`'s header warns
  that array is set wholesale and that an empty list fails **open**.
- **`internal.py`** — no `/internal/phone/{qr_id}` endpoint. Nothing at the edge will ever ask for it.
- **Bulk create (`qr.py:2424–2433`)** — the CSV importer is hard-limited to `website` QRs
  (`if _it.type != "website" …` → `400`). `phone` is intentionally **not** bulk-importable in v1; adding
  it would mean per-row `tel:` validation and is out of scope.

---

## 4. Cloudflare Worker / Edge Design

**No worker change. `npm run deploy:prod` is NOT required.**

A static QR never produces a KV entry: the create handler's KV block is guarded by
`if category == "dynamic":` (`qr.py:2250`), so `build_kv_content()` and `write_to_kv()` are unreachable
for `phone`. Consequently the Worker gains **no** `handleQRCode` dispatch case
(`qr_cf_code/src/handlers/qrRouter.js`), **no** `src/pages/phonePage.js`, **no** template module, **no**
`recordScan` field, and **no** `wrangler.toml` change. The **Worker↔React template-mirroring house rule
does not apply** — there is no scan page to mirror, because there is no scan.

Two consequences worth writing down so nobody "fixes" them later:

1. **The minted `short_code` is inert.** `_generate_short_code()` runs unconditionally in the create path
   (`qr.py:1615`), so a phone QR *has* a short code — but no KV key exists for it, so
   `https://<QR_DYNAMIC_URL>/<short_code>` will hit the Worker's KV miss path and serve the error page.
   This is **pre-existing behavior shared by all 9 static types**, not a `phone` regression. Do not
   "fix" it by writing static QRs to KV — that would silently convert every static code into a
   network-dependent one and break the core promise of the type.
2. **`preview_url` is still correct.** `QRCodeResponse._derive_preview_url` (`qr.py:959–964`) builds
   `…/api/public/v1/preview/{short_code}.svg` for every QR including static ones, but that endpoint
   branches on category and renders `qr_destinations[0].target_url` for static QRs
   (`api_public.py:1124–1127`). Because we persist the full `tel:` URI there (§2), the preview SVG
   encodes the dialable number, not the dead short link. **Add a test that asserts this** (§10) — it is
   the single load-bearing consequence of the no-table decision.

---

## 5. Frontend Design

All new files: kebab-case, one export, ≤200 lines, shadcn primitives only, no inline styles, no `any`,
react-hook-form + zod, TanStack for server state (none needed here).

### 5.1 Validation — reuse, do not redefine (`src/lib/validations/qr-schemas.ts`)
`phoneSchema` **already exists** at ~L130–135 and is currently referenced by **nothing**:
```ts
export const phoneSchema = z
  .string()
  .min(1, 'Phone number is required')
  .regex(/^\+?\d{10,15}$/, 'Please enter a valid phone number with country code');
```
Consume it. Do **not** author a parallel inline schema in the component the way `SMSContent.tsx:21–24`
does (that file's local `smsSchema` already diverges from the canonical `smsSchema` in `qr-schemas.ts:117`
— a real, pre-existing two-sources-of-truth wart we should not replicate). Wrap it for the form:
```ts
const phoneFormSchema = z.object({ number: phoneSchema });
```
The `/^\+?\d{10,15}$/` rule **rejects spaces, hyphens and parentheses outright** rather than stripping
them. That is deliberate and matches `sms`/`whatsapp` (PRD R2): silent normalization — as `whatsapp` does
at `qr-generator.ts:159` with `.replace(/[^0-9]/g,'')` — would mask a typo in output that gets **printed
and can never be edited** (`qr.py:2790`).

Also grep before adding anything: `QR_TYPE_LABELS.phone = 'Phone'` already exists
(`src/app/[slug]/(builder)/build/page.tsx:77`) and `QR_LOGO_COLORS.phone` already exists
(`qr-types.ts`). Both are vestigial from an abandoned attempt (PRD R6) — reuse, don't duplicate.

### 5.2 Type constants — `src/lib/constants/qr-types.ts`
Three additions:
```ts
// ALL_TYPES, static block (~L111–120), after the `sms` entry:
{ id: 'phone', name: 'Phone', description: 'Start a phone call · no tracking',
  icon: FiPhone, category: 'static' },

QR_TYPES.PHONE = 'phone',          // ~L207
TYPE_ICONS.phone = 'call',         // ~L238 (Material Symbols name used by the form header)
```
`FiPhone` must be added to the existing `react-icons/fi` import. The `description` carries the
"no tracking" qualifier per PRD §6.4 placement 1 — it is product copy, not filler.

Mirror the duplicate `TYPE_ICONS` map in `src/lib/types/qr.ts:~864` (the two maps have drifted apart
historically; add `phone: 'call'` to both). Add `phone` to `qr-type-icons.ts` (`TYPE_ICON_INNER`, ~L34 —
an inline SVG path for the QR-center logo) and to `qr-recommendations.ts` (~L46, under the
"Utility / messaging" group: `phone: ['minimal', 'corporate', 'colorful']`). Both are plain map entries;
omitting them is non-fatal (`hasTypeIcon()` and `DEFAULT_PROFILE` fall back) but leaves the type looking
second-class.

### 5.3 `tel:` encoder — `src/lib/qr-generator.ts` (`generateStaticQRContent`, `case 'sms'` at ~L151)
```ts
    case 'phone': {
      const number = String(data.phoneContent?.number || '').trim();
      return number ? `tel:${number}` : '';
    }
```
Returning `''` on an empty number is load-bearing: `build/page.tsx:281–310` treats a falsy `targetUrl` as
"content missing" for every type not in its content-QR allowlist (`phone` is correctly absent from that
list), so an empty phone number surfaces the standard "Please fill in the required content" toast instead
of creating a QR encoding the literal string `tel:`. `PublicQRBuilder.tsx:28–31` documents the same
concern for the logged-out path.

### 5.4 Content form — NEW `src/components/qr-generator/content-types/PhoneContent.tsx`
A near-verbatim clone of `SMSContent.tsx` (157 lines) with the message `Textarea` removed — well under
the 200-line limit. Keep: the `useForm` + `zodResolver` + `mode:'onChange'` setup (`:53–60`), the
`useStandaloneFormSync(form, vals => onChange({ phoneContent: vals }))` bridge (`:63`), the
`onNext`/`onComplete` `form.trigger()` guards (`:65–80`), the card chrome with `TYPE_ICONS[qrType]`
(`:86–104`), and `NavButton` (`:140–148`). The `qrCategory === 'dynamic'` badge branch (`:99–103`) is
dead code for `phone` — drop it rather than carry it.

Add the two PRD §6.4 copy elements the `sms` form doesn't have:
- helper text under the input — *"Include the country code (e.g. +91) so the code works for scanners
  anywhere"*;
- a muted static-limitation note with the dynamic-alternative link (PRD §6.4 placement 2);
- **(Open Q3, recommended)** a live echo of the resolved target — *"Will dial: `tel:+919876543210`"* —
  reading straight from `generateStaticQRContent('phone', …)` so what the user verifies is byte-identical
  to what gets encoded.

Export from the barrel (`content-types/index.ts`, beside `SMSContent`).

### 5.5 Dispatch — `src/components/qr-generator/QRContent.tsx`
Add the `dynamicImport` block (mirroring `:102–108`, same `loading` skeleton + `ssr: false`) and the
`case 'phone':` render block (mirroring `:402–414`, passing `{...contentProps}` plus the step/nav props).

`src/components/org/qrs/details/content-editor-dispatch.tsx` (the QR-detail edit surface) gets the same
pair (`:56–59`, `:168`) **for consistency only** — a static phone QR can never actually reach a content
save, since `PATCH` rejects it with `403` (`qr.py:2790`). Either wire it identically to `sms` or leave
`phone` unhandled; do not build a special read-only variant.

### 5.6 Free-tool completeness — `src/components/marketing/PublicQRBuilder.tsx` (~L33–52)
```ts
    case 'phone':
      return !!content.phoneContent?.number?.trim();
```
Without this, `isStaticContentComplete` hits the `default: return true` branch and the wizard would let a
visitor advance with an empty number (the file's own header comment at `:28–31` explains exactly this
failure class). `/create?type=phone` needs **no** code change — `parseCreateParams` derives its allowlist
from `ALL_TYPES.filter(t => t.category === 'static')` (`src/lib/create-params.ts:6–8`), so adding the
`ALL_TYPES` entry is sufficient.

### 5.7 Types — `src/lib/types/qr.ts`
```ts
export interface PhoneContent { number: string }        // beside SMSContent (~L365)
// on the QRContent interface (~L442, beside smsContent):
  phoneContent?: PhoneContent
```

### 5.8 SEO pages — one entry, three URLs
Add a `phone` object to `TYPE_PAGES` (`src/lib/constants/qr-type-pages.ts`, modeled on the `sms` entry at
~L1143) with `category: 'static'`, `isStaticTool: true`, and **all** copy fields populated
(`metaTitle`/`metaDesc`/`h1`/`answerFirst`/`howItWorks`/`useCases`/`benefits`/`faqs` +
`toolMetaTitle`/`toolMetaDesc`/`toolH1`/`toolIntro`/`toolHowTo` — the interface at `:22–39`). Add a
**separate** `TOOL_FAQS.phone` block (`src/lib/constants/tool-faqs.ts`, `sms` at ~L126) — `QrToolPageContent`
falls back to `page.faqs` when the key is missing (`:19`), and its own comment records that shared FAQs
previously made the two URLs near-duplicates (PRD R4).

Everything downstream is automatic, no routing code:
- `/phone-qr-code` — `(marketing)/[slug]/page.tsx` `generateStaticParams` + `resolveTypeSlug` (`:21`, `:37`)
- `/phone-qr-code-generator` — same dispatcher (`:21`), rendered by `QrToolPageContent`, which mounts
  `PublicQRBuilder initialType={slugToBuilderType('phone')} initialCategory="static" initialStep={2}`
  (`:52–57`). `slugToBuilderType` is `slug.replace(/-/g,'_')` (`qr-type-pages.ts:44`) → `'phone'`. ✅
- `/embed/phone` — `embed/[type]/page.tsx:16` maps over `STATIC_TOOL_PAGES()`
- 2 sitemap rows — `sitemap.ts:42–47` (info, priority 0.8) and `:48–54` (tool, priority 0.85)

### 5.9 API reference constants — `src/lib/constants/api-docs-objects.ts`
`STATIC_TYPES` (~L100) gains `'phone'`; `CONTENT_BY_TYPE` (~L113) gains
`{ type: 'phone', field: 'content.phoneContent', keyFields: 'number*' }`. These drive the public
`/docs` page; skipping them ships an undocumented API capability.

---

## 6. External-Service Integration

**None.** No AI/Anthropic call, no Resend email, no Razorpay, no Supabase Storage, no PDF/WeasyPrint, no
Cloudflare API call (no KV write ⇒ `CF_API_TOKEN` is never exercised by this path). No new environment
variable, secret, or config key. The `_dmarc.qravio.app` record is **not** a gate (no email). The
`ANTHROPIC_API_KEY` provisioning item that blocks other specs is irrelevant here.

The only "integration" is the **scanner's operating system**, which resolves `tel:` natively per
RFC 3966 — and that is precisely why §10 requires a real-device check rather than a unit test.

---

## 7. API Contracts

No new route. `phone` rides the existing QR create/read endpoints on **both** the internal API
(`/api/v1/workspaces/{id}/qrs`) and the Public API (`/api/public/v1/qrs`, which reuses the same
`QRCodeCreate` model — `api_public.py:313`).

```jsonc
// POST /api/v1/workspaces/{workspace_id}/qrs
{
  "name": "Shop line — Call",
  "type": "phone",
  "category": "static",
  "content": { "phoneContent": { "number": "+919876543210" } },
  "destinations": [ { "target_url": "tel:+919876543210" } ]   // the FE always sends this;
                                                              // it is the sole persistence
}
```
```jsonc
// 201 — response (content reconstructed by _build_content_from_db_rows, §3.3)
{
  "id": "…", "type": "phone", "category": "static",
  "short_code": "Ab3X9z",                       // minted but INERT — no KV key exists (§4)
  "preview_url": "https://api.qravio.app/api/public/v1/preview/Ab3X9z.svg",
                                                // renders the tel: URI, not the short link
                                                // (api_public.py:1124-1127)
  "total_scans": 0,                             // and will remain 0 forever (§1)
  "destinations": [ { "target_url": "tel:+919876543210", "is_active": true, … } ],
  "content": { "url": "tel:+919876543210", "phoneContent": { "number": "+919876543210" } }
}
```
```jsonc
// 422 — backend deployed BEFORE the frontend? No. Frontend deployed FIRST would produce this:
{ "detail": [ { "loc": ["body","type"], "msg": "Input should be 'website', … or 'paypal'" } ] }
// → hence the deploy order in §11.

// 403 — attempting to change the number after create (existing static-QR behavior, qr.py:2790)
{ "detail": "Static QR codes can only have their name updated." }
```

**KV payload:** **none.** No key is written for this QR (§4). The Worker's KV data model documented in
`CLAUDE.md` is untouched.

---

## 8. Security, Privacy & Abuse

- **Auth / tenant isolation — unchanged.** Creation rides the existing Bearer-authed, workspace-scoped
  QR endpoints (`BearerTokenAuthMiddleware` → `get_workspace_role` → `require_can_create`). No new route,
  no `/internal/*` surface, no `x-internal-secret` consumer, no route added to `excluded_routes` in
  `auth_bearer.py`.
- **No injection surface.** The phone number is never interpolated into HTML (there is no landing page —
  §4), never into SQL (PostgREST parameterizes), and never into a shell. `escapeHTML()` is irrelevant
  here because no Worker template renders this type. The number *is* interpolated into a `tel:` URI
  string, and `phoneSchema`'s `/^\+?\d{10,15}$/` restricts it to digits and an optional leading `+` —
  which structurally forecloses `tel:`-parameter injection (`;`, `,`, `*`, `#` are all rejected).
- **No SSRF.** No user-supplied value is ever fetched server-side. The `tel:` URI is data we encode into
  an image, never a request target.
- **Privacy — the number is public by construction.** Anyone who scans a printed Call QR reads the
  number; that is the feature. Worth stating in the tool-page FAQ so a user doesn't print their personal
  mobile on a public hoarding without thinking about it. Nothing new is *retained*: the number lives in
  `qr_destinations.target_url` under the workspace's existing data handling, and the logged-out generator
  never sends it to us at all (client-side render + download only, §1).
- **Abuse — negligible and unchanged.** No per-use COGS, no AI spend, no email, no outbound call is ever
  placed by us (the *scanner's* device dials, from the scanner's own SIM, after the scanner taps). The
  logged-out generator adds no new server surface: it performs **zero** backend requests. A bad actor
  could print a QR dialing a premium-rate number — but they could equally print the number itself, and
  every competitor's Call QR has the identical property. No new mitigation warranted.
- **Consent gate / retargeting pixels:** unaffected. Pixels fire on Worker-rendered landing pages; a
  static type has none.

---

## 9. Performance, Scale & Cost

- **Scan path: zero.** No request reaches us — the OS handles `tel:` locally. This type is literally
  free to serve at any scale, forever. It is the cheapest thing in the product.
- **Create path:** one `qr_codes` insert + one `qr_destinations` insert, and **one fewer** network call
  than a dynamic QR (no `write_to_kv` round-trip to the Cloudflare API, no `build_kv_content` fan-out of
  per-type detail SELECTs). Strictly cheaper than the existing dynamic create.
- **Read path: unchanged.** `SELECT_WITH_RELATIONS` (`qr.py:998`) gains **no** embed — the no-table
  decision (§2) means the list endpoint's join count is identical before and after this feature. The
  `_build_content_from_db_rows` addition is a string-slice on an already-loaded field: nanoseconds.
- **Frontend bundle:** one lazily-`dynamicImport`ed component (`ssr: false`), so it costs nothing until a
  user selects the type. The `TYPE_PAGES` entry adds ~2–3 KB to a constants module already carrying 27
  entries.
- **No cron, no jobs, no fan-out, no queue, no per-use COGS, nothing to throttle.**

---

## 10. Testing Strategy

**Backend (pytest, `qr_backend/tests/`):**
- `test_phone_create`: `POST` with `type:"phone", category:"static"` → `201`; the `qr_destinations` row
  holds `tel:+919876543210`; **assert no `qr_phone_details` table is touched** and **assert
  `write_to_kv` is NOT called** (mock it and assert `call_count == 0`) — the latter is the invariant that
  keeps the Worker out of scope.
- `test_phone_content_roundtrip`: `GET` the created QR → `content.phoneContent.number == "+919876543210"`
  and `content.url == "tel:+919876543210"`; a legacy/unprefixed destination falls through the `tel:`
  strip without raising (`_tel[:4].lower() == "tel:"` guard, §3.3).
- `test_phone_list_endpoint`: the **list** endpoint (which shares `_row_to_response` →
  `_build_content_from_db_rows`) returns a phone QR without error — this is the regression the
  attribute-vs-dict mistake in §3.3 would cause.
- `test_phone_ungated`: a **Free**-plan workspace creates a phone QR successfully; assert the
  `dynamic_qr_types` gate is not consulted (it is skipped by `category == "dynamic"`, `qr.py:1548`).
- `test_phone_static_update_blocked`: `PATCH` `content` on a phone QR → `403`; `PATCH` `name` → `200`
  (inherits existing static behavior, `qr.py:2790`).
- `test_phone_preview_svg`: `GET /api/public/v1/preview/{short_code}.svg` for a static phone QR encodes
  `tel:+919876543210` (not the short link) — the load-bearing consequence of §2 / §4 note 2.
- `test_phone_bulk_rejected`: bulk create with `type:"phone"` → `400` (the importer is website-only,
  `qr.py:2430`) — asserts the deliberate scope line, not a bug.
- **Untouched-guardrail:** `test_feature_gate_coverage` must stay green **with no changes** — we add
  neither a `FEATURE_ENFORCEMENT` key nor a `plans.features` seed.

**Frontend (Vitest):**
- `generateStaticQRContent('phone', {phoneContent:{number:'+919876543210'}})` → `'tel:+919876543210'`;
  empty/whitespace number → `''` (the create-guard contract, §5.3).
- `phoneFormSchema`: accepts `+919876543210` and `9876543210`; **rejects** `98765 43210`,
  `(98) 765-43210`, `abc`, `12345` (too short), and a 16-digit number.
- `isStaticContentComplete('phone', …)` → `false` for an empty number, `true` otherwise
  (`PublicQRBuilder.tsx`).
- `parseCreateParams({type:'phone'})` → `{ initialType:'phone', initialStep:2 }` — proves the
  `ALL_TYPES`-derived allowlist picked the new type up with no code change.
- `TYPE_PAGES` invariants: exactly one `phone` entry; `isStaticTool === true`;
  `slugToBuilderType('phone') === 'phone'`; every copy field non-empty; `TOOL_FAQS.phone` exists and is
  **not** deep-equal to `TYPE_PAGES.phone.faqs` (the anti-thin-content guard, PRD R4).
- **Baseline note:** the FE suite carries ~29 pre-existing failures. Only net-new failures in
  `phone`/`qr-generator`/`qr-type-pages` files are regressions.

**Worker:** **none — no worker change.** (Positively asserted by the `write_to_kv` call-count assertion
above rather than by absence.)

**Manual / real-device (the only irreplaceable test):** generate a phone QR, download the PNG, print it
*and* display it on screen, then scan with **iOS Camera, Android (Google Camera + a third-party scanner
app)**. The dialer must open pre-filled with the exact number. Repeat with and without the `+` country
code. This cannot be unit-tested and is where the actual risk lives (PRD R2/R3) — it is a merge gate.

---

## 11. Observability & Rollout

**Single phase, single PR.** No migration to apply, no flag to flip, no beta cohort, no Worker deploy,
no cron. The change is purely additive: no existing type's create, read, update, KV, or scan path is
modified.

**Deploy order — backend first, and it matters.** The frontend will POST `type: "phone"`; a backend
without the extended `Literal` (§3.1) rejects that with a **`422` on every attempt** (§7). Deploying
frontend-first therefore ships a visibly broken type. Deploying backend-first ships a type nothing
references yet — inert and safe. So: **`qr_backend` → `qr_frontend`.** No third step; `qr_cf_code` is not
deployed at all.

**Rollback:** revert the FE (the type vanishes from the picker). Backend can stay — an unreferenced
`Literal` member and an unused Pydantic model are inert. Already-created phone QRs keep working:
they are printed `tel:` codes that never call our infrastructure. **This feature cannot be broken by a
rollback**, which is another way of saying it carries essentially no operational risk.

**Metrics / logs — no new instrumentation.** There is nothing at the edge to log (§4). Track from
existing sources:
- **Adoption:** count of `qr_codes` rows with `type='phone'` (plain SQL, no dashboard needed).
- **SEO:** Search Console coverage + queries for `/phone-qr-code` and `/phone-qr-code-generator`;
  compare to the median of the 9 existing static tool pages at day 30 / day 90 (PRD §9).
- **Funnel:** the existing `savePendingQR` → `/signup` conversion on the tool page, segmented by
  `qrType`.
- **The metric that matters:** support tickets containing "call QR" + "scans". Target ≈ 0. A nonzero
  count means the §6.4 copy placement failed — the fix is copy, never analytics (PRD R1).

**Post-ship doc updates (same PR):** flip "Phone / Call QR" ✗ → ✓ in the comparison matrix and on
`/beaconstac-alternative`; add `phone` to the `/docs` static-type list (§5.9); mark gap-analysis item
**#9** done in `docs-internal/competitive-feature-gap-analysis.md`.

---

## 12. Open Technical Questions & Risks

1. **No table vs `qr_phone_details` — recommend NO TABLE (resolved, but flag for eng-review).** One
   reversible scalar + write-once static content (`qr.py:2790`) + an existing destination row that the
   read stack and the public preview endpoint already key off (`qr.py:1180`, `api_public.py:1124–1127`).
   A table would cost a hand-applied migration, a 20th embed on the hot `SELECT_WITH_RELATIONS` string
   (`qr.py:998`), and five more touch-points — for zero capability. **Counter-argument to weigh:**
   strict symmetry with `sms` makes the diff more mechanical and future-proofs a v2 that adds fields
   (an extension, a label). If eng-review prefers symmetry, use provisional slot **`0036`** and
   re-verify against `qr_backend/migrations/` (highest on disk `0032`; `0033` reserved by QR-expiry).
2. **`qr_codes.type` constraint — MUST be verified against the live DB before merging.** The whole
   "no migration" claim rests on `type` being unconstrained text with the union enforced only in
   Pydantic (`qr.py:838–863`). Run the two queries in §2. A `CHECK` constraint or Postgres enum turns
   this into a one-line migration; discovering it *after* deploy means every phone-QR create 500s.
   **This is the single highest-value pre-build check in this document.**
3. **`_build_content_from_db_rows` early-return guard.** The `any([...])` at `qr.py:1094–1114` gates
   whether `content` is built at all. It includes `destinations`, so a destination-only phone QR should
   pass — **confirm by reading it at build time.** A miss returns `None` and blanks `content` for every
   phone QR (and the bug would look like "the API silently drops phoneContent").
4. **`destinations` element type in the new branch.** `QRDestinationResponse` objects, not dicts —
   attribute access. Getting it wrong 500s the **list** endpoint, not just the detail one (§3.3, §10).
5. **Number normalization: reject vs strip — resolved as REJECT.** `/^\+?\d{10,15}$/` refuses spaces
   and hyphens rather than stripping them like `whatsapp` does (`qr-generator.ts:159`). Static output is
   printed and uneditable; a silent strip could mask a transposition the user would have caught. Accept
   the marginally higher input friction.
6. **No scan analytics — accepted, not mitigated.** Structural (§1, §4). The only engineering-adjacent
   obligation is that the §6.4 copy actually ships in all three placements; treat it as a merge
   requirement, not a nice-to-have. Do **not** entertain "just write static QRs to KV so we can count
   them" — that would convert every static code in the product into a network-dependent redirect and
   break the type's core promise.
7. **Vestigial `phone` symbols.** `phoneSchema`/`PhoneContent` (`qr-schemas.ts:130–135`),
   `QR_TYPE_LABELS.phone` (`build/page.tsx:77`), `QR_LOGO_COLORS.phone` — all currently unreferenced.
   Consume them; do not create parallel definitions. (Note `SMSContent.tsx:21–24` already re-declares a
   local `smsSchema` that has drifted from the canonical one at `qr-schemas.ts:117` — replicating that
   pattern is how the drift spreads.)
8. **Real-device `tel:` behavior is the only untestable risk.** Scanner apps vary in whether they
   auto-open the dialer, prompt, or ignore the scheme entirely on desktop. Covered by the §10 manual
   gate and the tool-page FAQ; no code mitigation exists or is warranted.

### Appendix — Key Files

| Concern | File |
|---|---|
| Type union (`"phone"`) | `qr_backend/src/api/routes/qr.py` (`QRCodeCreate.type` Literal ~L838–863; `"sms"` at L859) |
| Content model | `qr_backend/src/api/routes/qr.py` (NEW `PhoneContent` beside `SMSContent` ~L432; `phoneContent` on `QRContent` ~L540) |
| Read-back branch | `qr_backend/src/api/routes/qr.py` (`_build_content_from_db_rows` ~L1062, `qr_type` param L1064, destination fallback ~L1180, `any([...])` guard ~L1094) |
| Persistence (no table) | `qr_backend/src/api/routes/qr.py` (`qr_destinations` insert ~L1634; KV fenced by `if category == "dynamic"` ~L2250; static update `403` ~L2790) |
| Hot query — **untouched** | `qr_backend/src/api/routes/qr.py` (`SELECT_WITH_RELATIONS` ~L998 — no new embed) |
| Public API + static preview | `qr_backend/src/api/routes/api_public.py` (reuses `QRCodeCreate` ~L313; static preview renders `target_url` ~L1124–1127) |
| Gating — **untouched** | `qr_backend/src/api/routes/subscription.py` (no `FEATURE_ENFORCEMENT`/`_QUOTA_SPEC` entry); `migrations/0027_open_all_qr_types.sql` (dynamic-only, do not edit) |
| Migration | **None** — see §2 (verify `qr_codes.type` has no CHECK/enum first; fallback slot `0036`, re-verify) |
| Type constants | `qr_frontend/src/lib/constants/qr-types.ts` (`ALL_TYPES` ~L111–120, `QR_TYPES` ~L207, `TYPE_ICONS` ~L238) + `src/lib/types/qr.ts` (~L365 interface, ~L442 field, ~L864 icon map) |
| `tel:` encoder | `qr_frontend/src/lib/qr-generator.ts` (`generateStaticQRContent`, after `case 'sms'` ~L151) |
| Validation (reuse, don't redefine) | `qr_frontend/src/lib/validations/qr-schemas.ts` (`phoneSchema` ~L130–135 — **exists, unused**) |
| Builder form | `qr_frontend/src/components/qr-generator/content-types/PhoneContent.tsx` (NEW ≤200 lines; clone `SMSContent.tsx`) + `content-types/index.ts` barrel |
| Builder dispatch | `qr_frontend/src/components/qr-generator/QRContent.tsx` (import ~L102, case ~L402); `src/components/org/qrs/details/content-editor-dispatch.tsx` (~L56, ~L168) |
| Free-tool completeness | `qr_frontend/src/components/marketing/PublicQRBuilder.tsx` (`isStaticContentComplete` ~L33–52) |
| SEO — 1 entry → 3 URLs | `qr_frontend/src/lib/constants/qr-type-pages.ts` (NEW `phone`, `isStaticTool: true`; `sms` ~L1143; `slugToBuilderType` L44; `STATIC_TOOL_PAGES` L1395) + `src/lib/constants/tool-faqs.ts` (NEW `phone`; `sms` ~L126) |
| SEO — auto-wired consumers | `qr_frontend/src/app/sitemap.ts:42–54`, `src/app/(marketing)/[slug]/page.tsx:21`, `src/app/embed/[type]/page.tsx:16`, `src/components/marketing/QrToolPageContent.tsx:52–57` |
| Cosmetic maps | `qr_frontend/src/lib/constants/qr-type-icons.ts` (~L34), `src/lib/constants/qr-recommendations.ts` (~L46) |
| API reference | `qr_frontend/src/lib/constants/api-docs-objects.ts` (`STATIC_TYPES` ~L100, `CONTENT_BY_TYPE` ~L113) |
| Worker | **No change** — no KV key, no dispatch case, no template, no `deploy:prod` |
