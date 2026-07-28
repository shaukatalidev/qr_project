# TRD — UPI Payment QR (Static)

**Status:** Draft · **Author:** Engineering (Staff) · **Date:** 2026-07-25
**Priority:** Quick win, `S`. A third instance of an already-executed pattern (`bitcoin`, `paypal`) — no new architecture. Engineering risk is concentrated in exactly two places: **URI encoding correctness** (a mis-encoded payment link costs a real user real money) and **VPA input validation** (a payment-QR generator is a phishing primitive if it accepts arbitrary text).
**Tiers:** **All plans, ungated — structurally, not by choice.** The plan-type gate in `qr.py` (~L1546–1567) is wrapped in `if category == "dynamic"`; no static type has ever consulted `plans.features`.
**Plan flags (NEW):** **None.** No `FEATURE_ENFORCEMENT` entry, no `_QUOTA_SPEC` entry, no `plans.features` seed, **no `test_feature_gate_coverage` surface**. The migration contains no `UPDATE plans` statement.
**Migration slot:** **`0034`** (`0034_qr_upi_details.sql`) — **provisional. Re-verify against `qr_backend/migrations/` at build time.** Highest on disk today is `0032_lemonsqueezy_variant_backfill.sql`; **`0033` is claimed by QR Expiry + Campaign Scheduling** (`QR_EXPIRY_SCHEDULING_TRD.md`). If expiry lands first, this is `0034`; if it does not, do **not** silently take `0033` — the repo has a commit fixing stale slot numbers, and this header is not authoritative.
**Services touched:** `qr_backend` (one Pydantic model, one type-`Literal` entry, one detail table, VPA validation, content round-trip) · `qr_frontend` (one content form, one encoder `case`, type-registry wiring, two SEO pages). **`qr_cf_code` — no change** (verified in §4). **No AI, no email, no cron, no new internal endpoint, no new env var, no secret, no external service.**
**Implements PRD:** UPI Payment QR (Static). **Mirrors** the `bitcoin` static-type recipe end-to-end (`BitcoinContent` model → `qr_bitcoin_details` → `BitcoinContent.tsx` → `generateStaticQRContent` case).

**Rev (2026-07-25, post eng-review):** Reviewed via `/plan-eng-review`; **ships as-drafted** (no architecture change). Decisions: the **"static isn't tracked" disclosure is `upi`-only in v1** (no retrofit to `bitcoin`/`paypal`/`wifi`); the pre-existing scheme-only-URI mangling in `_normalize_web_url`/`_SCHEME_RE` (§1 aside / §12 R5) is a **separate ticket**, not this PR — `test_upi_scheme_not_mangled` still lands. Internal resolutions unchanged: `qr_upi_details` table over URI-parse (§2), NPCI param-name columns (§2), conservative `_VPA_RE` + `encodeURIComponent`-everything (§3.1/§5.1), no-KV/no-gating asserted by test (§10).

---

## 1. Overview & Architecture

`upi` is a **static** QR type. The entire payload — `upi://pay?pa=…&pn=…&am=…&cu=INR&tn=…` — is composed **client-side** by `generateStaticQRContent` (`qr_frontend/src/lib/qr-generator.ts` ~L132) and encoded **directly into the QR pixels**. The backend's only jobs are to (a) validate the VPA, (b) persist a `qr_upi_details` row so the builder can round-trip the values into the detail view, and (c) persist the composed URI as the QR's `qr_destinations.target_url`, exactly as `bitcoin`/`paypal`/`wifi` already do.

**Nothing reaches the edge.** A scan of this QR opens the payer's UPI app directly from the encoded URI — it never resolves a short code, never hits the Worker, never produces a scan event. This is not a limitation we are working around; it is what "static" means, and it is why the feature is `S`-sized.

**Services touched**

| Service | Change |
|---|---|
| `qr_backend` | `UpiContent` Pydantic model + `upiContent` on `QRContent`; `"upi"` added to the QR type `Literal` (~L860); `qr_upi_details(*)` appended to `SELECT_WITH_RELATIONS` (~L998); detail insert in the create handler (~L2001 pattern); `upi` params threaded through `_build_content_from_db_rows` (~L1071/~L1211) and the row→response mapper (~L1399/~L1427); `QRUpiDetailsResponse`; **VPA field validator**. Migration `0034` (one `CREATE TABLE`). **No** gating, RPC, internal endpoint, cron, or KV code. |
| `qr_frontend` | `case 'upi'` in `generateStaticQRContent`; `UPIContent.tsx` (NEW, mirrors `BitcoinContent.tsx`); two dispatch cases (`QRContent.tsx` ~L534, `content-editor-dispatch.tsx` ~L187); type-registry entries (`qr-types.ts`, `qr-type-icons.ts`, `qr-recommendations.ts`, `template-swatch-colors.ts`, `BuilderSidebar.tsx`); `UpiContent` TS interface; `PublicQRBuilder` `hasContent` case; `TYPE_PAGES` + `tool-faqs.ts` entries (two SEO pages, auto-routed); `api-docs-objects.ts`. |
| `qr_cf_code` | **No change.** No KV entry, no `build_kv_content` branch, no `handleQRCode` case, no `src/pages/*` template, no `recordScan` field. The worker↔React template-mirroring house rule does not apply (nothing to mirror). **`npm run deploy:prod` is NOT required.** |

**Data flow — create**

```
Builder → UPIContent.tsx (react-hook-form + zod; VPA grammar validated client-side)
  → build/page.tsx ~L282: targetUrl = generateStaticQRContent('upi', content)
                          → "upi://pay?pa=…&pn=…&am=…&cu=INR&tn=…"
  → ~L336: destinationsPayload = [{ target_url: targetUrl }]
  → authApi POST /workspaces/{id}/qrs { type:'upi', category:'static',
                                        content:{ upiContent:{pa,pn,am,tn} },
                                        destinations:[…], design }
  → qr.py create:
      • category == "static"  ⇒ max_qr gate SKIPPED (~L1495) and
                                dynamic_qr_types gate SKIPPED (~L1548)
      • UpiContent field validators: VPA grammar, amount format, length caps → 422
      • INSERT qr_codes → INSERT qr_destinations (target_url verbatim, ~L1650)
                        → INSERT qr_upi_details
      • category != "dynamic" ⇒ NO build_kv_content, NO write_to_kv  (~L2252)
  → 201 QRCodeResponse (content.upiContent round-tripped from the detail row)
```

**Data flow — scan (there is no server in it)**

```
Payer opens GPay / PhonePe / Paytm / BHIM → scans the printed code
  → device reads "upi://pay?pa=…" straight out of the QR pixels
  → UPI app opens its send screen, prefilled
  → payment settles on the NPCI rails, bank to bank
  ── Qravio is not in this path. No KV read, no Worker, no scan event, no analytics. ──
```

**The one place the URI touches a backend surface:** the public preview SVG endpoint (`api_public.py` ~L1099–1140) re-encodes `qr_destinations.target_url` for `category == "static"`. `upi://…` survives `_normalize_web_url` (`qr.py` ~L74–93) intact because `_SCHEME_RE` (~L71, `^[a-zA-Z][a-zA-Z0-9+.-]*://`) matches a `://` scheme. *(Aside, verified while checking this: `bitcoin:bc1q…` and `WIFI:T:…` have **no** `//`, so today they are coerced to `https://bitcoin:bc1q…` in `target_url` — the printed pixels are fine because they are generated client-side, but the public preview SVG for those two types is wrong. Pre-existing, out of scope, worth a follow-up ticket. `upi://` dodges it.)*

---

## 2. Data Model & Migrations

One new detail table, `qr_upi_details`, mirroring `qr_bitcoin_details` (shape inferred from `QRBitcoinDetailsResponse`, `qr.py` ~L624–635: `id`, `qr_id`, `workspace_id`, the content columns, `created_at`, `updated_at`). The base per-type detail tables predate the `migrations/` folder, so there is no in-repo `CREATE TABLE` to copy verbatim — the column set below is the response-model shape plus the standard FK/timestamp columns.

**Column naming — decided (PRD R7/Open Q1):** columns are the **NPCI parameter names** `pa` / `pn` / `am` / `tn`, not semantic names. They map 1:1 onto the URI they build, so a reader diffing this table against the UPI deep-link spec sees the correspondence immediately. Each carries a SQL comment. UI labels remain human.

**RLS note:** the backend uses the Supabase **service-role** REST client, which **bypasses RLS**. We `ENABLE ROW LEVEL SECURITY` with **no policies**, matching the `0026`/`0022` convention — the anon/authenticated roles can never read the table, and tenant isolation is enforced in code via the explicit `workspace_id` filters the QR handlers already apply. RLS is defence-in-depth here, not the boundary.

**`qr_backend/migrations/0034_qr_upi_details.sql`** — BEGIN/COMMIT-wrapped, idempotent (`IF NOT EXISTS`), applied by hand in the Supabase SQL editor.

```sql
-- Migration 0034: UPI payment QR (STATIC type `upi`).
-- One detail table, mirroring qr_bitcoin_details / qr_paypal_details. Static types
-- are structurally ungated (the dynamic_qr_types check in qr.py runs only when
-- category == "dynamic"), so there is deliberately NO `UPDATE plans` here: no flag,
-- no limit, no plans.features seed, and therefore NO test_feature_gate_coverage
-- surface. If you find yourself adding an UPDATE plans statement to this file,
-- stop — gating a static type is a new mechanism, not a seed.
--
-- Columns use the NPCI UPI deep-link parameter names (pa/pn/am/tn) so the row maps
-- 1:1 onto the `upi://pay?…` URI the frontend composes.
--
-- SLOT: 0032 is the highest on disk; 0033 is claimed by QR expiry + scheduling.
-- Re-confirm the highest APPLIED migration in the DB before running.
-- Idempotent; safe to re-run.
BEGIN;

CREATE TABLE IF NOT EXISTS qr_upi_details (
    id           uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    qr_id        uuid        NOT NULL REFERENCES qr_codes(id)   ON DELETE CASCADE,
    workspace_id uuid        NOT NULL REFERENCES workspaces(id) ON DELETE CASCADE,
    pa           text        NOT NULL,   -- Payee VPA, e.g. name@bank. Format-validated
                                         -- backend-side; ownership is NOT verifiable.
    pn           text,                   -- Payee name shown to the payer. UNVERIFIED free
                                         -- text — this is not a merchant-verified QR.
    am           text,                   -- Suggested amount, "1000.00" style. A PREFILL
                                         -- HINT ONLY: every payer app lets the user edit
                                         -- it. Never describe this as a locked amount.
    tn           text,                   -- Transaction note / reference shown to the payer.
    created_at   timestamptz NOT NULL DEFAULT now(),
    updated_at   timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE  qr_upi_details    IS 'Per-QR UPI payment fields for the static `upi` type; composes upi://pay?…';
COMMENT ON COLUMN qr_upi_details.am IS 'Prefill hint only — the payer can change the amount. Not a lock.';

-- One detail row per QR (matches the *_details 1:1 read pattern:
-- raw_upi[0] in _build_content_from_db_rows).
CREATE UNIQUE INDEX IF NOT EXISTS idx_qr_upi_details_qr_id ON qr_upi_details (qr_id);
-- Workspace-scoped reads/cleanup.
CREATE INDEX IF NOT EXISTS idx_qr_upi_details_workspace_id ON qr_upi_details (workspace_id);

ALTER TABLE qr_upi_details ENABLE ROW LEVEL SECURITY;
-- No policies → only the service role (which bypasses RLS) can read/write.
-- Tenant isolation is enforced in code by the workspace_id filters in qr.py.

COMMIT;

-- Sanity:
--   SELECT q.short_code, u.pa, u.pn, u.am
--     FROM qr_upi_details u JOIN qr_codes q ON q.id = u.qr_id LIMIT 20;
--   -- and confirm NO plans row changed:
--   SELECT name, features ? 'upi' FROM plans;   -- expect false everywhere
```

**The no-migration alternative (PRD Open Q2), and why we rejected it.** The `upi://` URI is already persisted verbatim in `qr_destinations.target_url` and is fully self-describing — parsing it back would repopulate the form with no new table and no migration at all. We rejected it because it breaks the uniformity of `_build_content_from_db_rows` (every other content type reads a detail row; `upi` would be the sole URI-parsing special case), and because a stored parse-target is a fragile source of truth once `_normalize_web_url` or the encoder changes. **The table costs one `CREATE TABLE` and buys symmetry — take it.** Recorded so the trade-off is visible if someone later wants to drop it.

**No change** to `qr_codes`, `qr_destinations`, `qr_designs`, `qr_scan_events`, `qr_scan_counters`, or any other detail table. **No change to `plans`.**

---

## 3. Backend Design

### 3.1 Content model + VPA validation — `qr_backend/src/api/routes/qr.py`

Add `UpiContent` beside `BitcoinContent` (~L449) / `PaypalContent` (~L470):

```python
# NPCI UPI deep-link parameters. `cu` is not a field — the encoder hardcodes INR.
class UpiContent(pydantic.BaseModel):
    pa: str                            # payee VPA, e.g. "name@okhdfcbank"
    pn: Optional[str] = None           # payee name (UNVERIFIED display string)
    am: Optional[str] = None           # suggested amount — a prefill hint, NOT a lock
    tn: Optional[str] = None           # transaction note
```

Register it on `QRContent` (~L529–556) as `upiContent: Optional[UpiContent] = None`, and add `"upi"` to the `type` `Literal` in `QRCodeCreate` (~L840–864, beside `"bitcoin"` ~L860 / `"paypal"` ~L861). Adding it to that `Literal` also opens the type on the **public developer API** (`api_public.py` reuses the same create model), which is intended.

**VPA validation** — the security-critical piece (PRD R2). Follow the precedent set by `_validate_google_review_url` (~L513): a **write-time, backend-side guard** against becoming a redirect/phishing vector, applied as a Pydantic field validator so it fires on every write path (builder, public API, and any future bulk path) rather than in a single handler.

```python
# VPA grammar: <local>@<handle>. Deliberately conservative — a payment QR that
# accepts arbitrary text is a phishing primitive. Rejects whitespace, control
# chars, a second '@', an empty side, an embedded scheme, and '&'/'?'/'#'
# (which would let a crafted VPA inject extra URI parameters downstream).
_VPA_RE = re.compile(r"^[A-Za-z0-9._-]{2,64}@[A-Za-z][A-Za-z0-9.-]{1,63}$")
```

- `pa` → strip, lowercase the handle, match `_VPA_RE`, else `422 "pa must be a valid UPI ID (e.g. name@bank)."`
- `am` → optional; if present must parse as a **positive decimal with ≤2 places**; normalise (strip `₹`, thousands separators, whitespace) and re-emit as a plain `"1000.00"` string; else `422`. (PRD R8 — payer apps mishandle `1,000` / `1000.005`.)
- `pn`, `tn` → trim; length-cap (`pn` ≤ 99, `tn` ≤ 99 — UPI apps truncate long values); strip control characters and newlines.

**Explicit limit, stated in the docstring:** this validates **format, never ownership**. We cannot confirm a VPA belongs to the person entering it — NPCI VPA-validation APIs require PSP membership we do not have. Product copy must not imply otherwise (PRD §3 Non-Goals).

### 3.2 Persistence — create handler (`qr.py`)

Mirror the `bitcoin` block (~L2001–2013) verbatim in shape:

```python
# 7f. Create UPI details (if provided)
upi_details_response: Optional[QRUpiDetailsResponse] = None
if payload.content.upiContent:
    upi_data = payload.content.upiContent.model_dump(exclude_none=True)
    upi_data["qr_id"] = str(qr_id)
    upi_data["workspace_id"] = str(workspace_id)
    upi_result = db.table("qr_upi_details").insert(upi_data).execute()
    …  # 500 "QR code created but failed to insert UPI details." on empty result
    upi_details_response = QRUpiDetailsResponse(**upi_result.data[0])
```

Add `QRUpiDetailsResponse` beside `QRBitcoinDetailsResponse` (~L624–635) with the table's columns and `model_config = pydantic.ConfigDict(from_attributes=True)`, and thread `upi=upi_details_response.model_dump() if upi_details_response else None` into the response construction (~L2304 pattern).

**No `_normalize_web_url` change is needed** — `upi://pay?…` already passes through `QRDestinationCreate._normalize_target_url` (~L106–110) untouched, because `_SCHEME_RE` matches it. **Add a test pinning this**, since a regex tweak there would silently corrupt every stored UPI destination (§10).

### 3.3 Read path — content round-trip (`qr.py`)

Three coordinated edits, each a one-line mirror of the `bitcoin` handling:

1. `_build_content_from_db_rows` (~L1063): add the `upi: Optional[dict] = None` parameter (beside `bitcoin` ~L1071), add `upi` to the `any([...])` early-return guard (~L1102), and add the mapping block beside the `bitcoin` one (~L1211):
   ```python
   if upi:
       kwargs["upiContent"] = UpiContent(
           pa=upi.get("pa") or "",
           pn=upi.get("pn"),
           am=upi.get("am"),
           tn=upi.get("tn"),
       )
   ```
2. Row→response mapper (~L1390–1440): `raw_upi: list = row.pop("qr_upi_details", None) or []` beside `raw_bitcoin` (~L1399), and pass `upi=raw_upi[0] if raw_upi else None` into the call (~L1427).
3. `SELECT_WITH_RELATIONS` (~L998): append `, qr_upi_details(*)`.

**Miss any one of these three and the QR detail view silently shows an empty UPI form** — the read path fails soft, not loud. All three are covered by one round-trip test (§10).

### 3.4 Gating, KV, internal endpoints, cron

**None — and each is a positive verification, not an omission:**
- **Gating:** the `dynamic_qr_types` check (~L1546–1567) sits inside `if category == "dynamic"`; a static QR never reaches it. The `max_qr` limit check (~L1495) is likewise dynamic-only. No `FEATURE_ENFORCEMENT` row, no `_QUOTA_SPEC` entry, no `check_feature` call. `test_feature_gate_coverage` is untouched because the migration seeds nothing into `plans`.
- **KV:** the create handler's KV block is `if category == "dynamic":` (~L2252). A static `upi` QR gets no `build_kv_content` call and no `write_to_kv`. **Assert this in a test** (§10) rather than trusting the read.
- **Update:** unchanged. `qr.py` (~L2790) already restricts static QRs to name-only updates with `403 "Static QR codes can only have their name updated."` — so there is no UPI update path, no re-encode path, and no KV-resync path to write. (PRD R6.)
- **Bulk import:** unchanged — it accepts `website` only (~L2424–2433).
- **Internal endpoints / cron:** none. There is no `/internal/upi/*` because the Worker never asks for anything.

---

## 4. Cloudflare Worker / Edge Design

**No change — verified, not assumed.** Four independent checks:

1. **No KV entry is ever written.** The create handler gates the entire `build_kv_content` + `write_to_kv` block on `category == "dynamic"` (`qr.py` ~L2252). A static QR has no KV key, so `GET /:shortCode` for one would 404 at the KV lookup — which is precisely why `api_public.py` (~L1122–1127) encodes `qr_destinations.target_url` instead of a short link for static QRs.
2. **`build_kv_content` has no static branches.** Its type dispatch (`qr_backend/src/utilities/cloudflare_kv.py` ~L219–451) covers `website`, `apps`, `business`, `list_links`, `social_media`, `event`, `coupon`, `landing_page`, `lead_form`, `review_funnel` — all dynamic. `bitcoin`/`paypal`/`wifi` appear nowhere in that file, and neither will `upi`.
3. **The QR pixels carry the payload.** `generateStaticQRContent` (`qr-generator.ts` ~L132) produces the `upi://` URI and the client encodes it directly — the short code is never in the printed code for a static QR.
4. **Nothing to mirror.** There is no scan page, so the "every React template must be mirrored by a Worker template" house rule does not apply. No `handlers/qrRouter.js` case, no `src/pages/upiPage.js`, no `recordScan` field, no `wrangler.toml` change.

**Consequence: `npm run deploy:prod` is NOT a gate for this feature.** The edge scan hot path is byte-for-byte unchanged.

---

## 5. Frontend Design

### 5.1 URI encoder — `qr_frontend/src/lib/qr-generator.ts`

The single highest-risk function in the feature. Add one `case` to `generateStaticQRContent` (~L132), beside `bitcoin` (~L176) and `paypal` (~L187):

```ts
case 'upi': {
  const upiData = data.upiContent;
  const pa = String(upiData?.pa || '').trim();
  if (!pa) return '';
  // Every value is percent-encoded so a note containing "&" or "=" cannot
  // inject an extra UPI parameter (e.g. "&am=99999") into the link.
  const params = [`pa=${encodeURIComponent(pa)}`];
  if (upiData?.pn) params.push(`pn=${encodeURIComponent(String(upiData.pn))}`);
  if (upiData?.am) params.push(`am=${encodeURIComponent(String(upiData.am))}`);
  params.push('cu=INR');                    // UPI is INR-only in practice
  if (upiData?.tn) params.push(`tn=${encodeURIComponent(String(upiData.tn))}`);
  return `upi://pay?${params.join('&')}`;
}
```

Notes that are load-bearing: **`encodeURIComponent` on every value** (parameter-injection guard, PRD R2); **omit empty optionals** rather than emitting `&pn=`; **`cu=INR` always present**; **return `''` when `pa` is empty** so the builder's existing "content missing" guard (`build/page.tsx` ~L284) fires. Returning `''` also keeps `PublicQRBuilder`'s empty-content check honest.

Adding this one case lights up the live preview (`QRPreview.tsx` ~L65), the phone-frame preview (`MobilePreview.tsx` ~L68), `useQRPreview.ts` (~L32), and all four export formats — no further work.

### 5.2 Content form — `qr_frontend/src/components/qr-generator/content-types/UPIContent.tsx` (NEW)

A direct structural copy of `BitcoinContent.tsx` (190 lines — comfortably under the 200-line limit): `useForm` + `zodResolver`, `useStandaloneFormSync(form, vals => onChange({ upiContent: vals }))`, `onNext`/`onComplete` with `form.trigger()`, the same card shell and `NavButton`. shadcn `Form`/`Input`/`Textarea` only — no raw HTML inputs, no inline styles, Tailwind tokens only, one export, kebab-case-adjacent naming matching its siblings.

```ts
const upiSchema = z.object({
  pa: z.string().regex(/^[A-Za-z0-9._-]{2,64}@[A-Za-z][A-Za-z0-9.-]{1,63}$/,
                       'Enter a valid UPI ID, e.g. name@okhdfcbank'),
  pn: z.string().max(99).optional(),
  am: z.string()
       .refine(v => !v || /^\d+(\.\d{1,2})?$/.test(v), 'Enter an amount like 250 or 250.50')
       .optional(),
  tn: z.string().max(99).optional(),
});
```

**Copy is part of the spec, not decoration** (PRD §6.2 / R1 / R3):
- `am` helper text — **"Suggested amount — the payer can change it before paying."** Never "lock", "fixed", or "exact".
- Inline note — *"This creates a plain UPI link, not a verified merchant QR. Your payer's app won't show a verified business name."*
- Preview/download note — *"Static QR codes aren't tracked — scans and payments won't appear in your dashboard."*
- Placeholder — `yourname@okhdfcbank`. **Never a real, working VPA** (PRD Open Q4): a live payment target sitting on an indexed page is a standing donation to whoever owns it.

### 5.3 Types + registry wiring

- `qr_frontend/src/lib/types/qr.ts`: `UpiContent` interface beside `BitcoinContent` (~L379); `upiContent?: UpiContent` on `QRContent` (~L446); icon map entry (~L865).
- `qr_frontend/src/lib/constants/qr-types.ts`: `{ id: 'upi', name: 'UPI', description: 'Accept a UPI payment', icon: …, category: 'static' }` in the static block (~L118, beside `bitcoin`); `UPI: 'upi'` in `QR_TYPES` (~L208); `TYPE_ICONS.upi` (~L239).
- `qr-type-icons.ts` (~L38), `qr-recommendations.ts` (~L51), `template-swatch-colors.ts` (~L34), `BuilderSidebar.tsx` (~L54) — one entry each, matching `bitcoin`.
- Dispatch: `case 'upi'` in `QRContent.tsx` (~L534) and `content-editor-dispatch.tsx` (~L187). **Both** — the second is the QR-detail editor, and omitting it renders the *"Content editor not available for type upi"* fallback.
- `api-docs-objects.ts`: append `'upi'` to `STATIC_TYPES` (~L100) and a row to the field table (~L116): `{ type: 'upi', field: 'content.upiContent', keyFields: 'pa*, pn, am, tn' }`.

### 5.4 SEO pages (the actual deliverable)

One `TYPE_PAGES` entry in `qr_frontend/src/lib/constants/qr-type-pages.ts` with `slug: 'upi'`, `name: 'UPI'`, `category: 'static'`, **`isStaticTool: true`** yields **both** pages with no routing work: the `(marketing)/[slug]` dispatcher's `generateStaticParams` emits `/upi-qr-code` and `/upi-qr-code-generator`, and `sitemap.ts` (~L42–52) picks both up. Fill every copy field (`metaTitle`, `metaDesc`, `h1`, `answerFirst`, `howItWorks`, `useCases`, `benefits`, `faqs`, `toolMetaTitle`, `toolMetaDesc`, `toolH1`, `toolIntro`, `toolHowTo`) with **unique** prose — the file header states the anti-thin-content rule explicitly.

Also: a `upi` entry in `tool-faqs.ts` (~L144, beside `bitcoin`), the footer link in `LandingFooter.tsx` (~L20), and the `PublicQRBuilder.tsx` `hasContent` case (~L44): `case 'upi': return !!content.upiContent?.pa?.trim();`.

**Copy constraints are release gates, not style notes** (PRD §9): no fixed/locked-amount claim anywhere; no verified-merchant implication; no analytics implication; "scan with any UPI app," never "point your camera."

---

## 6. External-Service Integration

**None.** No AI/Anthropic call, no Resend/email, no Razorpay or Lemon Squeezy interaction (this feature does not process a payment — it prints a link that a payer's own app acts on), no NPCI or PSP API, no PDF/WeasyPrint, no new environment variable, no new secret, no new `requirements.txt` or `package.json` dependency.

Two clarifications worth stating plainly because "payment QR" invites the wrong assumption:
- **We are not in the payment path.** Money moves bank-to-bank over NPCI rails between the payer's app and the payee's VPA. Qravio composes a string. There is no callback, no webhook, no settlement, no PCI/PA-DSS surface, and no RBI payment-aggregator exposure — which is exactly why the dynamic/settlement variant sits in the Skip column.
- **We cannot verify a VPA.** NPCI's VPA-validation endpoints require PSP membership. §3.1 validates grammar only.

`_dmarc.qravio.app` is **not** a gate (no email). `ANTHROPIC_API_KEY` is irrelevant (no AI).

---

## 7. API Contracts

No new route. `upi` rides the existing QR create endpoint (and, by virtue of the shared create model, the public developer API at `/api/public/v1/qrs`).

```jsonc
// POST /api/v1/workspaces/{workspace_id}/qrs
{
  "name": "Studio invoice QR",
  "type": "upi",
  "category": "static",
  "content": {
    "upiContent": {
      "pa": "nikhil@okhdfcbank",     // required — VPA grammar enforced
      "pn": "Nikhil Design Studio",  // optional — UNVERIFIED display string
      "am": "2500.00",               // optional — PREFILL HINT, payer can edit
      "tn": "Invoice 2026-114"       // optional
    }
  },
  "destinations": [
    { "target_url": "upi://pay?pa=nikhil%40okhdfcbank&pn=Nikhil%20Design%20Studio&am=2500.00&cu=INR&tn=Invoice%202026-114" }
  ],
  "design": { /* … */ }
}

// 201 — content.upiContent round-trips from qr_upi_details
{ "id": "…", "type": "upi", "category": "static", "short_code": "…",
  "content": { "upiContent": { "pa": "nikhil@okhdfcbank", "pn": "Nikhil Design Studio",
                               "am": "2500.00", "tn": "Invoice 2026-114" } },
  "destinations": [ { "target_url": "upi://pay?…" } ] }

// 422 — malformed VPA
{ "detail": "pa must be a valid UPI ID (e.g. name@bank)." }

// 422 — malformed amount
{ "detail": "am must be a positive amount with at most 2 decimal places." }

// 403 — any post-create edit beyond `name` (existing static-QR behaviour, qr.py ~L2790)
{ "detail": "Static QR codes can only have their name updated." }
```

**No KV payload** — a static QR has no KV entry (§4). **No new Worker contract.** The public preview SVG (`GET /api/public/v1/preview/{short_code}.svg`) renders the stored `upi://` URI for this type; no change to that endpoint is required.

---

## 8. Security, Privacy & Abuse

- **This is a phishing-adjacent surface, and we treat it as one.** A payment-QR generator points strangers' money at an account of the creator's choosing. `_VPA_RE` (§3.1) is deliberately conservative — no whitespace, no control characters, no second `@`, no `&`/`?`/`#`/`:`/`/`, no embedded scheme — so a crafted `pa` cannot inject additional URI parameters or smuggle a different scheme. Every field is `encodeURIComponent`-escaped at compose time (§5.1), so a note containing `&am=99999` becomes literal text, not a parameter.
- **Format validation is not ownership verification, and we say so.** A well-formed VPA can belong to a fraudster. We cannot check (NPCI VPA validation is PSP-gated), so the product states plainly that this is **not a verified merchant QR**. No free generator on the market solves this; claiming we do would be the actual security failure.
- **Auth + tenant isolation:** create rides the existing Bearer-authed, `require_can_create`-gated QR endpoint. `qr_upi_details` rows carry an explicit `workspace_id`; reads go through `SELECT_WITH_RELATIONS` scoped by the handler's existing workspace filter. The service-role client bypasses RLS, so — as everywhere else — isolation is the code filter, and RLS-with-no-policies is defence-in-depth.
- **No SSRF, no redirect surface:** the backend never fetches the VPA or the URI, and — unlike a `website` QR — the Worker never 302s to it, because the Worker is not in this path at all. The URI exists only in the QR pixels, the DB, and the public preview SVG.
- **Sensitive-data posture:** `pa`/`pn` are payment-identifying data the user knowingly enters about themselves and then **prints on a poster**. It is not secret by nature. We store no bank account number, no card data, no credential — consistent with the privacy-page claim that we never store UPI credentials. **Do not** log `pa` values in application logs.
- **Abuse:** no per-use cost, no unauthenticated backend write (the free tool at `/upi-qr-code-generator` is **100% client-side** and makes no API call at all), no metering needed. The free tool's placeholder must be a non-working example VPA (§5.2).
- **Consent gate / retargeting:** unaffected. Static QRs have no landing page, so no pixels fire and no scan-side tags exist.

---

## 9. Performance, Scale & Cost

- **Edge:** zero impact. No KV read, no Worker CPU, no new route — a static UPI QR never reaches Cloudflare.
- **Backend:** one extra `INSERT` on create and one extra embedded relation in `SELECT_WITH_RELATIONS`. The latter widens *every* QR read by one join — the same marginal cost each of the ~20 existing embedded detail tables already imposes, and PostgREST resolves it as one round-trip. Negligible, but it is the only line in this feature that touches a hot read path, so it belongs in the list.
- **DB:** one narrow table, one unique index on `qr_id`, one index on `workspace_id`. Row count is bounded by the number of UPI QRs created.
- **Frontend:** the encoder `case` is a handful of string operations inside a function already called on every preview render.
- **Cost:** **zero marginal COGS.** No AI tokens, no external API calls, no storage, no cron, no fan-out. Nothing to throttle.
- **SEO pages:** two more statically-generated routes in an already-static `generateStaticParams` set — a negligible build-time addition.

---

## 10. Testing Strategy

**Frontend (Vitest) — the encoder is the critical unit.** `generateStaticQRContent('upi', …)` is where a bug costs a user real money, so test it exhaustively:
- **Exact-string assertions** for: `pa` only; `pa`+`pn`; `pa`+`pn`+`am`; all four fields. Assert the full URI, not a substring.
- **`cu=INR` is always present**, in every combination.
- **Empty optionals are omitted**, not emitted as `&pn=`.
- **Encoding:** `pa` containing `@` → `%40`; a `pn`/`tn` containing spaces, `&`, `=`, `#`, and Devanagari characters round-trips correctly through `decodeURIComponent`.
- **Parameter-injection guard:** `tn = "note&am=99999"` must produce a single literal `tn` value — parsing the result must yield exactly one `am`, equal to the user's amount (or none).
- **Empty `pa` returns `''`** so the builder's content-missing guard fires.
- Zod schema: valid/invalid VPAs, `250` and `250.50` accepted, `250.505` / `1,000` / `₹250` rejected.
- `PublicQRBuilder` `hasContent('upi')` and the two dispatch sites render `UPIContent`.
- **Note the ~29 pre-existing FE test failures baseline** — only net-new failures in `upi`/`qr-generator` files are regressions.

**Backend (pytest, `qr_backend/tests/`):**
- `test_upi_create_persists`: create → `qr_upi_details` row written with `qr_id`+`workspace_id`; `qr_destinations.target_url` holds the `upi://` URI **verbatim**.
- `test_upi_scheme_not_mangled`: **pin `_normalize_web_url("upi://pay?pa=a@b") == "upi://pay?pa=a@b"`.** A future tweak to `_SCHEME_RE` (~L71) would otherwise silently corrupt every stored UPI destination. (This test would also have caught the pre-existing `bitcoin:`/`WIFI:` mangling noted in §1.)
- `test_upi_content_round_trip`: `GET /qrs/{id}` returns `content.upiContent` with the entered values — covers **all three** read-path edits in §3.3 at once (a miss there fails soft).
- `test_upi_vpa_validation`: `no-at-sign`, `two@@ats`, `has space@bank`, `a@b&am=1`, `http://x@y`, empty local/handle → **422**; `name@okhdfcbank`, `9876543210@ybl`, `a.b_c-d@paytm` → accepted.
- `test_upi_amount_validation`: `250`, `250.5`, `250.50` accepted; `250.505`, `-1`, `1,000`, `₹250`, `abc` → 422; normalisation output asserted.
- `test_upi_no_kv_write`: creating a static `upi` QR calls **neither** `build_kv_content` **nor** `write_to_kv` (assert with a mock — §4's whole premise).
- `test_upi_no_gating`: a **Free**-plan workspace creates a `upi` QR successfully — no `dynamic_qr_types` 403, no `max_qr` consumption.
- `test_upi_static_update_blocked`: `PATCH` with `content` → 403 *"Static QR codes can only have their name updated."*; `PATCH` with only `name` → 200 (existing behaviour, pinned).
- **`test_feature_gate_coverage` must stay green untouched** — this feature adds no flag; if it goes red, someone added a `plans` seed to `0034` that does not belong there.

**Real-device verification (manual GA gate, §11 Phase 1 — not automatable, not skippable):** scan generated codes with **GPay, PhonePe, Paytm, and BHIM** on real hardware across the four field combinations plus a note with special/Devanagari characters. Confirm the recipient resolves, the amount prefills, and the note appears. Unit tests prove we emit the string we intended; only a real payer app proves the string is right.

**Copy audit (GA gate):** grep the diff for `lock`, `fixed`, `exact amount`, `verified`, `track`/`analytics` across `UPIContent.tsx`, `qr-type-pages.ts`, `tool-faqs.ts`, and meta descriptions. Binary and auditable (PRD §9).

**Worker:** none — no worker change.

---

## 11. Observability & Rollout

**Phase 0 — Type + encoder (internal).** Apply `0034`. Backend: `UpiContent` + validators, `Literal` entry, `SELECT_WITH_RELATIONS`, detail insert, `QRUpiDetailsResponse`, the three read-path edits. Frontend: encoder `case`, `UPIContent.tsx`, TS types, registry entries, both dispatch sites. Full unit suite green.
- **Acceptance:** create a `upi` QR on a **Free** workspace → the encoded value matches the expected URI exactly → the detail row persists and round-trips into the QR detail view → a malformed VPA 422s → **no KV write** (asserted) → post-create content edit 403s.

**Phase 1 — Real-device verification (blocking GA gate).** The four-app, five-combination matrix in §10. **Do not ship on unit tests alone** — a mis-encoded payment URI is the single failure mode that costs a real user real money.

**Phase 2 — GA + SEO.** `TYPE_PAGES` entry (both page copies), `tool-faqs.ts`, `PublicQRBuilder` case, footer link, `api-docs-objects.ts`. Verify both routes build statically, appear in the sitemap, and carry correct canonicals. **Run the copy audit.** Submit to Search Console; track impressions/position for the head terms.

**Deploy order:** apply `0034` → deploy backend (the detail insert needs the table) → deploy frontend. **No Worker deploy** (§4). **No DMARC gate** (no email). **No cron gate.**

**Metrics / logs:** Search Console impressions + position for `/upi-qr-code` and `/upi-qr-code-generator`; tool-page → signup conversion benchmarked against the existing static tool pages (`bitcoin`, `wifi`, `whatsapp`); `upi` share of newly created static QRs; count of 422s on `pa` (a high rate means the client-side hint is failing, not that users are wrong). **Log 422 *reasons*, never `pa` values.** No new dashboard infrastructure. **There are, and can be, no scan or payment metrics** — a dashboard implying otherwise for this type is a bug.

---

## 12. Open Technical Questions & Risks

1. **Migration slot** — `0034` is **provisional**. `0032` is the highest on disk; `0033` is claimed by QR Expiry + Campaign Scheduling. **Re-verify against `qr_backend/migrations/` and the applied-migration state in the DB before running.** Do not trust this header.
2. **Detail table vs URI-parse (no migration)** — resolved: **ship the table.** Symmetry with every other static type and a uniform `_build_content_from_db_rows` beat saving one `CREATE TABLE`. Trade-off recorded in §2 in case a future reader wants to revisit.
3. **`pa`/`pn`/`am`/`tn` vs semantic column names** — resolved: **spec names**, with SQL comments and human UI labels. They map 1:1 onto the URI. Divergence from `bitcoin`'s semantic naming is deliberate and documented (PRD R7).
4. **The three read-path edits fail soft** — `SELECT_WITH_RELATIONS`, the `row.pop`, and the `_build_content_from_db_rows` mapping must **all** land or the detail view shows an empty form with no error. One round-trip test covers all three; it is the highest-value backend test here.
5. **`_SCHEME_RE` fragility** — `upi://` survives `_normalize_web_url` only because it carries `//`. This is load-bearing and untested today; §10 adds the pin. **Related pre-existing bug, out of scope, worth a ticket:** `bitcoin:` and `WIFI:` (no `//`) are currently mangled to `https://bitcoin:…` in `qr_destinations.target_url`, which corrupts the public preview SVG for those two types (printed pixels are unaffected — they are generated client-side).
6. **Amount normalisation must be shared in spirit, duplicated in fact** — the zod refine (FE) and the Pydantic validator (BE) enforce the same rule in two languages. They **will** drift. Keep both rules stated in one place in the code comments (cross-reference each other) and cover both with tests.
7. **No verification is possible, and the copy must carry that weight** — grammar validation is the entire ceiling. The honesty affordances in §5.2 are not polish; they are the mitigation. Treat the copy audit as a real gate.
8. **Do not "fix" the analytics gap with a redirect** — the tempting follow-up is a dynamic `upi` type routing through a Qravio interstitial. It would produce scan data and a materially worse, more suspicious payment experience. If it is ever proposed, it needs its own PRD and a real argument (PRD R5).

### Appendix — Key Files

| Concern | File |
|---|---|
| Detail table | `qr_backend/migrations/0034_qr_upi_details.sql` (NEW — `qr_upi_details`; **verify slot**, `0033` = QR expiry; **no `UPDATE plans`**) |
| Content model + VPA/amount validation | `qr_backend/src/api/routes/qr.py` (`UpiContent` beside `BitcoinContent` ~L449; `upiContent` on `QRContent` ~L544; `_VPA_RE` validator, precedent `_validate_google_review_url` ~L513) |
| Type registration | `qr_backend/src/api/routes/qr.py` (`"upi"` in the `QRCodeCreate` type `Literal` ~L860 — also opens it on the public API) |
| Persist + read round-trip | `qr_backend/src/api/routes/qr.py` (`SELECT_WITH_RELATIONS` ~L998; `_build_content_from_db_rows` param ~L1071 / guard ~L1102 / mapping ~L1211; `row.pop` ~L1399 + call ~L1427; detail insert ~L2001 pattern; `QRUpiDetailsResponse` ~L624; response wiring ~L2304) |
| Static-QR invariants (unchanged, pinned by tests) | `qr.py` — dynamic-only `max_qr` gate ~L1495, dynamic-only type gate ~L1548, dynamic-only KV write ~L2252, name-only static update ~L2790; `_normalize_web_url` ~L74 / `_SCHEME_RE` ~L71 |
| URI encoder | `qr_frontend/src/lib/qr-generator.ts` (`generateStaticQRContent` ~L132; `case 'upi'` beside `bitcoin` ~L176) |
| Builder form | `qr_frontend/src/components/qr-generator/content-types/UPIContent.tsx` (NEW — mirrors `BitcoinContent.tsx`, ≤200 lines, shadcn only) |
| Dispatch (both required) | `qr_frontend/src/components/qr-generator/QRContent.tsx` (~L534) · `qr_frontend/src/components/org/qrs/details/content-editor-dispatch.tsx` (~L187) |
| FE types | `qr_frontend/src/lib/types/qr.ts` (`UpiContent` ~L379; `upiContent` ~L446; icon map ~L865) |
| Type registry | `qr_frontend/src/lib/constants/qr-types.ts` (~L118/~L208/~L239) · `qr-type-icons.ts` ~L38 · `qr-recommendations.ts` ~L51 · `template-swatch-colors.ts` ~L34 · `BuilderSidebar.tsx` ~L54 |
| SEO pages (auto-routed) | `qr_frontend/src/lib/constants/qr-type-pages.ts` (NEW `slug: 'upi'`, `isStaticTool: true`) → `src/app/(marketing)/[slug]/page.tsx` + `src/app/sitemap.ts` (~L42–52) |
| SEO copy + free tool | `qr_frontend/src/lib/constants/tool-faqs.ts` (~L144) · `src/components/landing/LandingFooter.tsx` (~L20) · `src/components/marketing/PublicQRBuilder.tsx` (~L44) |
| API docs | `qr_frontend/src/lib/constants/api-docs-objects.ts` (`STATIC_TYPES` ~L100; field table ~L116) |
| Public preview SVG (encodes the stored URI) | `qr_backend/src/api/routes/api_public.py` (~L1099–1140 — no change needed) |
| Gating | **None** — `subscription.py` untouched; `test_feature_gate_coverage` must stay green with no new keys |
| Worker | **No change** — no KV entry (`qr.py` ~L2252), no `build_kv_content` branch (`cloudflare_kv.py` ~L219–451), no template, no cron. **`npm run deploy:prod` not required.** |
