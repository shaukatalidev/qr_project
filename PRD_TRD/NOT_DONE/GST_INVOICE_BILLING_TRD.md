# TRD — GST Invoice on Your Own Billing (v1: GSTIN + Billing-Details Capture)

**Status:** Draft · **Author:** Engineering (Staff) · **Date:** 2026-07-25
**Priority:** Conversion enabler for GST-registered INR buyers (Scanova/QRCodeChimp both capture a GSTIN). One table, one owner-only GET/PUT pair, one billing-page card. The only genuinely hard part is the GSTIN **check character** — everything else is a copy of the `workspace_branding` settings-resource pattern.
**Tiers:** **All plans, ungated.** No plan flag, no gate, no `plans.features` key.
**Plan flags (NEW):** **None.** No `FEATURE_ENFORCEMENT` entry, no `_QUOTA_SPEC` entry, **no `test_feature_gate_coverage` surface at all** — the migration creates a table and seeds no feature keys, so the coverage test is untouched by construction.
**Migration slot:** **`0039`** (`0039_gst_billing_profile.sql`) — **provisional.** Verified against disk: highest existing = `0032_lemonsqueezy_variant_backfill.sql`; `0033` is reserved by `QR_EXPIRY_SCHEDULING_TRD`; `0034`–`0038` are provisionally claimed by the concurrent spec batch (UPI/Location/Phone QR types, GA4 relabel, email-signature embed, WhatsApp reminders). **Re-run `ls qr_backend/migrations/` immediately before applying and renumber to the lowest free slot** — the repo already carries a commit fixing stale slot numbers, and `AI_BUSINESS_CARD_OCR` shipped as `0026` after its reserved `0024` was taken.
**Services touched:** `qr_backend` (one table, one new router, one validator utility, two `notes` dicts in `razorpay_routes.py`) · `qr_frontend` (billing-details card + form + hook + GSTIN/state constants). **`qr_cf_code` — no change** (no KV, no entitlement, no template, no cron, no scan-path touch). **No AI, no email, no new external service, no new env var or secret.**
**Implements PRD:** GST Invoice on Your Own Billing (v1: GSTIN + Billing-Details Capture). **Mirrors** the per-workspace settings-resource pattern of white-label branding (`workspace_branding` / `0011` / `branding.py` / `useBranding.ts`) — same 1:1 table keyed on `workspace_id`, same GET/PUT pair, same upsert-then-read-back, same hook shape.

**Rev (2026-07-25, post eng-review):** Reviewed via `/plan-eng-review`; ships as-drafted. **GSTIN validation = format + mod-36 checksum only** (defer live GSTN-API verification to the invoice-engine phase). The **checksum utility (`gstin.py`) must be tested against known-good + one-char-mutated vectors** — the one genuinely hard part; a wrong impl silently rejects valid GSTINs or accepts invalid ones. Keyed on `workspace_id` (inherited resolved via `billing_workspace_id`); warn-not-block on GSTIN-state ↔ address-state mismatch; non-blocking upgrade prompt; capture company/address on the USD rail too. **`workspace_billing_profile` must be added to the account-deletion cascade fix** (business PII). Razorpay `notes` stay a best-effort mirror (DB row authoritative); confirm the 2 added keys stay within Razorpay's 15-key/256-char `notes` cap (§ R9).

## 1. Overview & Architecture

A workspace owner saves a **billing profile** — legal name, GSTIN, billing address, billing email — from the
billing page. It is stored in a new `workspace_billing_profile` table keyed 1:1 on `workspace_id`, read and
written through an owner-only `GET`/`PUT` pair, and mirrored into the Razorpay subscription `notes` at
checkout so finance can read the buyer's GSTIN straight off the payment record.

**No invoice is generated, computed, numbered, or emailed.** v1 is data capture plus one non-trivial
validator. That is the entire feature, and the deliberate smallness is the point: sequential per-financial-
year numbering and the CGST/SGST-vs-IGST place-of-supply split are compliance artifacts with an unforgiving
correctness bar, and shipping them half-right is worse than shipping nothing (PRD §3, §10 Phase 3).

**Two architectural facts do real work here:**

1. **Only the Razorpay/INR rail can produce a Qravio GST invoice.** Lemon Squeezy is the **merchant of
   record** for USD (`qr_backend/src/integrations/mor/base.py:4-5` — *"handles rest-of-world USD billing AS
   the merchant of record: it collects global sales tax / VAT"*). LS is the seller; it issues its own
   invoice. Rendering a GSTIN field to an LS customer would promise an invoice we cannot legally issue, so
   the GSTIN input is conditioned on the INR rail (§5.3).
2. **Owner-scoped billing means the profile that counts lives on the *billing* workspace.** One owner can
   hold up to 5 workspaces (migration `0030`) that inherit a single subscription.
   `get_current_subscription` already returns `is_inherited` + `billing_workspace_id`
   (`razorpay_routes.py:172-193`, `:708-782`), and `CurrentPlanCard` already renders the plan read-only in
   that case. The billing profile follows the identical rule — read-through to the billing workspace, write
   only there (§3.2).

**Services touched**

| Service | Change |
|---|---|
| `qr_backend` | Migration `0039` (one 1:1 table, RLS-enabled with no policies); **new** `src/api/routes/billing_profile.py` (owner-only `GET`/`PUT /workspaces/{id}/billing-profile`, mirrors `branding.py`), registered in `endpoints.py`; **new** `src/utilities/gstin.py` (layout + state-code + PAN + mod-36 check character); two 3-line additions to the existing `notes` dicts in `razorpay_routes.py` (`:301` create, `:618` upgrade). **No** gating, RPC, cron, internal endpoint, or KV touch. |
| `qr_frontend` | Billing-details card + RHF/zod form composed by the billing **page** (not `BillingPlans.tsx`, already 677 lines); `useBillingProfile` + `useUpdateBillingProfile` hooks mirroring `useBranding.ts`; shared `lib/gstin.ts` validator + `lib/constants/gst-states.ts`; INR-vs-USD rail copy off the existing `CurrencyProvider`. |
| `qr_cf_code` | **No change.** The billing profile is not an entitlement, never enters `build_entitlements` or `build_kv_content`, and never reaches the edge. No `npm run deploy:prod` gate. |

**Data flow — saving a billing profile**

```
Billing page → BillingDetailsCard → BillingDetailsForm (react-hook-form + zod)
  → client-side: uppercase + strip whitespace on GSTIN; zod refine = layout + checksum (lib/gstin.ts)
  → useUpdateBillingProfile → authApi.put(/workspaces/{id}/billing-profile, {...})
  → BearerTokenAuthMiddleware (attaches user_id)
  → require_workspace_role(["owner"])            [403 for editor/viewer/non-member]
  → billing_profile.py:
      1. resolve billing workspace (resolve_plan → billing_workspace_id); reject write on an inherited ws  [409]
      2. gstin.validate(value) → normalize or 422   (layout + state code + PAN + 'Z' + check char)
      3. upsert workspace_billing_profile ON CONFLICT (workspace_id)
      4. read back → response
  → onSuccess: setQueryData(billingProfileKey(wsId), data) + toast
```

**Data flow — profile → payment record**

```
Upgrade/checkout → POST /razorpay/subscriptions/create  (or /upgrade)
  → razorpay_routes.py loads the plan, then reads workspace_billing_profile (best-effort, never fatal)
  → rz.subscription.create({ ..., notes: { workspace_id, plan_id, billing_cycle,
                                           gstin?, legal_name? } })
  → notes ride the Razorpay payment; finance reads the GSTIN off the dashboard
  → the DB row remains AUTHORITATIVE (notes are written at subscription-create only)
```

---

## 2. Data Model & Migrations

One new table, 1:1 with `workspaces`, keyed on `workspace_id` — a direct copy of the `workspace_branding`
shape from `0011_white_label_branding.sql` (`workspace_id uuid PRIMARY KEY REFERENCES workspaces(id) ON
DELETE CASCADE` + nullable value columns + `updated_at`). No columns on `subscriptions` (a subscription row
is per-purchase: it does not exist before the first checkout — exactly when we most want the profile — and
it is replaced on upgrade and abandoned on cancel, so a profile living there would be lost). No columns on
`workspaces` (that table is read on every permission and plan resolve; adding buyer PII to the hottest row
in the schema for a once-a-year write is the wrong trade).

**RLS note:** the backend uses the Supabase **service-role** REST client, which **bypasses RLS**. Following
the `0014`/`0017`/`0018`/`0026` convention we `ENABLE ROW LEVEL SECURITY` with **no policies**, so the anon
and authenticated roles can never read the table even if a key leaks into a client. This is stricter than
`workspace_branding` (`0011` predates the convention and enables no RLS) and is warranted: the branding row
is public-by-design (it renders on scan pages), whereas this row holds buyer PII. Tenant isolation is
enforced in code by `require_workspace_role(["owner"])` plus an explicit `workspace_id` filter — never by RLS.

**`qr_backend/migrations/0039_gst_billing_profile.sql`** — BEGIN/COMMIT-wrapped, idempotent
(`IF NOT EXISTS`), applied by hand in the Supabase SQL editor. **No plan-flag seed** (ungated — the whole
`plans.features` / `test_feature_gate_coverage` surface is untouched).

```sql
-- Migration 0039: GST billing profile (v1 = capture only, no invoice generation)
--
-- Stores the billing identity a tax invoice must be issued TO: legal name, GSTIN,
-- billing address. 1:1 with workspaces, mirroring workspace_branding (0011).
--
-- v1 GENERATES NOTHING. No invoice number, no CGST/SGST/IGST split, no PDF. Those
-- are deferred (see TRD §12 / PRD §10 Phase 3) because a wrong number series or a
-- wrong tax split is a compliance defect, not a hotfixable UI bug.
--
-- Meaningful on the RAZORPAY/INR rail only: Lemon Squeezy is the merchant of record
-- for USD and issues its own invoice (src/integrations/mor/base.py:4).
--
-- Apply in the Supabase SQL Editor (or psql). No automated runner — see README.
-- Idempotent (safe to re-run).

BEGIN;

CREATE TABLE IF NOT EXISTS workspace_billing_profile (
    workspace_id   uuid        PRIMARY KEY REFERENCES workspaces(id) ON DELETE CASCADE,

    -- Invoice "Bill To" identity
    legal_name     text,        -- registered legal/company name, as it must appear on the invoice
    billing_email  text,        -- where the invoice goes; defaults to the owner's account email in the UI

    -- Tax identity. NULLABLE BY DESIGN: unregistered proprietors are a large share
    -- of Indian SMBs and must be able to save a complete profile with no GSTIN.
    -- Validated at write time (layout + state code + PAN + literal 'Z' + mod-36 check
    -- character) in src/utilities/gstin.py; stored uppercased and whitespace-stripped.
    gstin          text,
    tax_id_type    text        NOT NULL DEFAULT 'gstin',  -- forward room for vat/abn/ein; v1 writes only 'gstin'

    -- Billing address
    address_line1  text,
    address_line2  text,
    city           text,
    state_code     text,        -- 2-char GST state code ('27' = Maharashtra, ...). See §3.3.
    postal_code    text,
    country_code   text        NOT NULL DEFAULT 'IN',     -- ISO-3166-1 alpha-2

    created_at     timestamptz NOT NULL DEFAULT now(),
    updated_at     timestamptz NOT NULL DEFAULT now()
);

-- Defense in depth: the service-role client bypasses RLS, and no other role should
-- ever reach this row. Enabled with NO policies (the 0014/0017/0018/0026 convention).
ALTER TABLE workspace_billing_profile ENABLE ROW LEVEL SECURITY;

-- Cheap correctness net for the ONE field with a hard format. Belt-and-braces behind
-- src/utilities/gstin.py: this catches shape, the Python validator catches the check
-- character (a mod-36 computation not worth expressing in a CHECK constraint).
-- NULL passes (unregistered buyers) — NOT VALID so the DDL cannot fail on legacy rows.
ALTER TABLE workspace_billing_profile
  DROP CONSTRAINT IF EXISTS workspace_billing_profile_gstin_shape;
ALTER TABLE workspace_billing_profile
  ADD CONSTRAINT workspace_billing_profile_gstin_shape
  CHECK (gstin IS NULL OR gstin ~ '^[0-9]{2}[A-Z]{5}[0-9]{4}[A-Z][0-9A-Z]Z[0-9A-Z]$')
  NOT VALID;

COMMIT;

-- Sanity (after COMMIT):
--   SELECT workspace_id, legal_name, gstin, state_code, country_code
--     FROM workspace_billing_profile ORDER BY updated_at DESC LIMIT 20;
--   -- must return 0 rows: every stored GSTIN passes the shape check
--   SELECT count(*) FROM workspace_billing_profile
--    WHERE gstin IS NOT NULL
--      AND gstin !~ '^[0-9]{2}[A-Z]{5}[0-9]{4}[A-Z][0-9A-Z]Z[0-9A-Z]$';
```

No change to `subscriptions`, `plans`, `workspaces`, or any `qr_*` table. **No `plans.features` write**, so
`test_feature_gate_coverage._seed_feature_keys()` is unaffected — the blob-vs-`jsonb_set` seed hazard that
dominates gated-feature migrations simply does not apply here.

---

## 3. Backend Design

### 3.1 GSTIN validator — `qr_backend/src/utilities/gstin.py` (NEW)

A pure module (no HTTP, no DB) so it is trivially unit-testable and so the frontend mirror
(`qr_frontend/src/lib/gstin.ts`, §5.1) has one authoritative reference to match.

A GSTIN is 15 characters: `SS PPPPP NNNN P E Z C`
- `[0:2]` **state code** — 2 digits. Valid set: `01`–`38` (states/UTs), plus `97` (Other Territory) and `99`
  (UIN / OIDAR non-resident). Anything else is rejected.
- `[2:12]` **PAN** — `[A-Z]{5}[0-9]{4}[A-Z]`.
- `[12]` **entity/registration number** — `[0-9A-Z]`.
- `[13]` — literal **`Z`**.
- `[14]` — **check character**, base-36.

```python
_ALPHABET = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ"   # base-36, index == value
_LAYOUT   = re.compile(r"^[0-9]{2}[A-Z]{5}[0-9]{4}[A-Z][0-9A-Z]Z[0-9A-Z]$")
_VALID_STATE_CODES = {f"{n:02d}" for n in range(1, 39)} | {"97", "99"}

def checksum_char(first14: str) -> str:
    """Mod-36 check character. Weights alternate 1,2,1,2,... across the first 14
    chars; each product is folded as (product // 36) + (product % 36) — the fold is
    the step naive implementations drop, and dropping it still passes ~1 in 36 bad
    GSTINs. Check char = ALPHABET[(36 - (total % 36)) % 36]."""
    total = 0
    for i, ch in enumerate(first14):
        product = _ALPHABET.index(ch) * (1 if i % 2 == 0 else 2)
        total += product // 36 + product % 36
    return _ALPHABET[(36 - total % 36) % 36]

def normalize(raw: str | None) -> str | None:
    """Uppercase, strip all whitespace/hyphens. Empty/blank → None (unregistered)."""

def validate(raw: str | None) -> str | None:
    """Return the normalized GSTIN, or None for empty input (VALID — GSTIN is
    optional). Raise GstinError with a SPECIFIC reason otherwise: bad length,
    bad layout, unknown state code, or check-character mismatch."""

def state_code(gstin: str) -> str:
    """First two characters — the registered state, canonical place-of-supply
    signal when it disagrees with the typed address state (§3.3, PRD Open Q2)."""
```

**`GstinError` carries a reason code** (`gstin_length`, `gstin_layout`, `gstin_state_code`,
`gstin_checksum`) so the route can return a message the user can act on, not a generic "invalid" (PRD §6.1).
`validate(None)` / `validate("")` returning `None` is the load-bearing case: an unregistered proprietor must
be able to save a complete profile, so the empty path is a success path, never a 422.

### 3.2 Router — `qr_backend/src/api/routes/billing_profile.py` (NEW)

A new module rather than an addition to `razorpay_routes.py` (already 1293 lines) — and rail-agnostic, since
the profile is not Razorpay-specific. `router = fastapi.APIRouter(prefix="/workspaces", tags=["Billing"])`,
registered in `src/api/endpoints.py` beside `branding_router` (`endpoints.py:50`) so
`BearerTokenAuthMiddleware` runs and `get_current_user_id` is populated.

```
GET /api/v1/workspaces/{workspace_id}/billing-profile
PUT /api/v1/workspaces/{workspace_id}/billing-profile
```

Both depend on `member = Depends(require_workspace_role(["owner"]))`
(`qr_backend/src/api/dependencies/deps.py:95`, already used by `update_workspace` at `workspace.py:757`) —
**owner-only on both verbs**, including the read. This is billing data: an editor who can build QRs has no
business reading the company's GSTIN and address. That dependency resolves `get_workspace_role`, which
validates membership and the UUID; it is the tenant-isolation boundary, and every query additionally carries
an explicit `workspace_id` filter because the service-role client bypasses RLS.

**GET — read-through for inherited workspaces.** Resolve the billing workspace exactly as the plan does:

```python
resolved = resolve_plan(workspace_id, db)                       # subscription.py:283
billing_ws = str(resolved.get("billing_workspace_id") or workspace_id)
is_inherited = billing_ws != workspace_id
row = (db.table("workspace_billing_profile").select("*")
         .eq("workspace_id", billing_ws).maybe_single().execute())
return BillingProfileResponse(**(row.data or {}),
                              billing_workspace_id=billing_ws,
                              is_inherited=is_inherited,
                              editable=not is_inherited)
```

A workspace on an inherited plan therefore **sees the profile it will actually be invoiced under**, which is
the whole point (PRD R5) — and mirrors how `get_current_subscription` (`razorpay_routes.py:708-782`) already
resolves the displayed plan through `resolve_plan`. A missing row returns all-null fields, not a 404 (the
`branding.py:114` `BrandingResponse(**(res.data or {}))` convention).

**PUT — write only on the billing workspace.** Reject a write to a workspace whose plan is inherited with
**409** `{"code": "billing_profile_inherited", "billing_workspace_id": "..."}` — one billing identity per
paying owner, never five divergent GSTINs (PRD R5). Then:

```python
gstin = gstin_util.validate(payload.gstin)          # → normalized or None; GstinError → 422
row = {
    "workspace_id": workspace_id,
    "legal_name":   _clean(payload.legal_name, 200),
    "billing_email": _clean_email(payload.billing_email),
    "gstin":        gstin,
    "tax_id_type":  "gstin",
    "address_line1": _clean(payload.address_line1, 200),
    "address_line2": _clean(payload.address_line2, 200),
    "city":         _clean(payload.city, 100),
    "state_code":   _clean_state(payload.state_code),   # must be in the valid set, or None
    "postal_code":  _clean(payload.postal_code, 12),
    "country_code": (payload.country_code or "IN").upper()[:2],
    "updated_at":   "now()",
}
db.table("workspace_billing_profile").upsert(row, on_conflict="workspace_id").execute()
```

Upsert-then-read-back, exactly like `update_branding` (`branding.py:128-138`). All strings trimmed and
length-capped; every field except `country_code`/`tax_id_type` is nullable, so a partial profile is valid and
clearing a field is a normal write (send `null`).

**State mismatch is a warning, not an error** (PRD Open Q2): if both `gstin` and `state_code` are present and
`gstin[:2] != state_code`, persist both and return `warnings: ["state_code_mismatch"]` in the response. v1
computes no tax, so a mismatch is at worst stale data; blocking would punish the legitimate
registered-in-Maharashtra / billing-address-in-Karnataka case. The GSTIN's state code is treated as canonical
whenever both exist.

**No `check_feature` call anywhere in this router** — ungated by design (PRD §8).

### 3.3 Razorpay `notes` pass-through — `qr_backend/src/api/routes/razorpay_routes.py`

Both subscription-create paths already build a `notes` dict:
`create_razorpay_subscription` (`:296-307`, notes at `:301-305`) and `upgrade_subscription`
(`:612-625`, notes at `:618`). Add the profile to both:

```python
_profile = _billing_notes(db, str(payload.workspace_id))   # {} on any error
notes = {"workspace_id": ..., "plan_id": ..., "billing_cycle": ..., **_profile}
```

`_billing_notes()` selects `gstin, legal_name` for the workspace and returns at most
`{"gstin": ..., "legal_name": <≤200 chars>}`, **swallowing every exception** — a missing profile or a
transient DB blip must never fail a checkout. Razorpay caps `notes` at 15 key/value pairs with ≤256-char
values; we go from 3 keys to 5, comfortably inside.

`notes` are written **only at subscription-create**, so a profile saved afterwards will not retroactively
appear on an existing subscription (PRD R9). The DB row is authoritative; `notes` are a convenience that
makes the common case (details entered before upgrading) a zero-lookup for finance. No change to the webhook
handler — `notes` are read back at `:882` for workspace resolution and the extra keys are inert there.

### 3.4 Gating, KV, entitlements, internal endpoints, cron

**None.** No `FEATURE_ENFORCEMENT` entry, no `_QUOTA_SPEC` entry, no `plans.features` key, no seed — so
`test_feature_gate_coverage` has nothing to classify and stays green by construction. No
`build_entitlements` / `build_kv_content` / `write_to_kv` change (the profile is a billing record, not a
per-QR rendering entitlement — adding it to the KV snapshot would be pure dead weight and would leak buyer
PII to the edge). No `/internal/*` endpoint, no `x-internal-secret` consumer, no `scheduled()` cron.

---

## 4. Cloudflare Worker / Edge Design

**No worker change.** This feature adds no QR type, no KV top-level key, no `src/pages/*` template, no
`handlers/` dispatch case, no `recordScan` field, and no `scheduled()` cron. Because there is no new scan
page or template, the **worker↔React template-mirroring house rule does not apply** (nothing to mirror), and
**`npm run deploy:prod` is not required** for this feature. The edge scan hot path is byte-for-byte
unchanged.

The billing profile is deliberately kept **out of the KV snapshot**: it is buyer PII with no rendering role,
and every KV value is readable by the Worker on every scan. Nothing about a GSTIN belongs at the edge.

---

## 5. Frontend Design

### 5.1 Shared validator + constants — `src/lib/gstin.ts`, `src/lib/constants/gst-states.ts` (NEW)

`gstin.ts` is a pure module mirroring §3.1 one-for-one — same alphabet, same alternating 1/2 weights, same
`(product // 36) + (product % 36)` fold, same state-code set — exporting `normalizeGstin`,
`checksumChar`, and `validateGstin(raw): { ok: true; value: string | null } | { ok: false; reason: GstinReason }`.
Client-side validation exists for feedback speed only; **the server re-validates unconditionally** (§3.2).
The two implementations must agree, which is what the shared-vector test (§10) enforces.

`gst-states.ts` exports the 37 Indian states/UTs as `{ code, name }` (`'27' → 'Maharashtra'`, …) for the
select and for the `state_code` round-trip. One export per file, kebab-case names, no `any`.

### 5.2 Hook — `src/hooks/useBillingProfile.ts` (NEW)

TanStack Query via `authApi` (never `useEffect + fetch`), a direct copy of `useBranding.ts`:

```ts
export interface BillingProfile {
  legal_name: string | null;  billing_email: string | null;
  gstin: string | null;       tax_id_type: string;
  address_line1: string | null; address_line2: string | null;
  city: string | null;        state_code: string | null;
  postal_code: string | null; country_code: string;
  billing_workspace_id: string; is_inherited: boolean; editable: boolean;
  warnings?: string[];
}

const billingProfileKey = (workspaceId: string) => ['billing-profile', workspaceId] as const;

export function useBillingProfile(workspaceId: string) { /* useQuery, enabled: !!workspaceId, staleTime 60_000 */ }
export function useUpdateBillingProfile(workspaceId: string) {
  // useMutation → authApi.put(`/workspaces/${workspaceId}/billing-profile`, body)
  // onSuccess: queryClient.setQueryData(billingProfileKey(workspaceId), data) + toast
  // onError:   toast(getErrorMessage(err))   // 403 non-owner · 409 inherited · 422 bad GSTIN
}
```

`workspaceId` comes from `useWorkspaceStore((s) => s.currentWorkspace)?.id` per house rule. The query is
**enabled only for owners** — gate the card on the existing role from the workspace store / `usePermissions`
so a viewer never fires a request that would 403.

### 5.3 Billing-details card + form — `src/components/org/billing/`

Two new kebab-case, one-export components, each ≤200 lines:

- **`billing-details-card.tsx`** — the card shell. Renders the empty state (*"Add your GST and billing
  details so your invoices are issued correctly"* + an **Add billing details** button), the filled read-back,
  and the inherited read-only state (*"Managed on &lt;workspace&gt; — edit it there"*, from
  `is_inherited` / `billing_workspace_id`). Hidden entirely for non-owners.
- **`billing-details-form.tsx`** — react-hook-form + zod only (no uncontrolled inputs), shadcn primitives
  from `src/components/ui/` (`form-input.tsx`, `form-select.tsx`, `Button.tsx`, `card.tsx`) — never raw
  `<input>`/`<button>`, no `style={{}}`, Tailwind tokens only, `cn()` for conditionals. The GSTIN input
  uppercases and strips whitespace on change and validates on blur via `validateGstin`, surfacing the
  specific reason (*"That GSTIN's check character doesn't match — please re-check"*) rather than a generic
  message.

**Composed by the page, not by `BillingPlans`.** `qr_frontend/src/app/[slug]/(dash)/billing/page.tsx` is 29
lines and already a pure composition of `<BillingPlans />`; the card is added there. `BillingPlans.tsx` is
677 lines and must not grow. Export the card from `src/components/org/index.ts` beside
`CurrentPlanCard` (`index.ts:16-17`).

**Rail conditioning (§1, PRD R4).** The card reads `useCurrency()` from the billing-scoped `CurrencyProvider`
seeded server-side in `billing/layout.tsx`:
- `currency === 'INR'` → GST copy + the GSTIN field + the state select.
- `currency === 'USD'` → **no GSTIN field**; instead a short note: *"Your invoice is issued by Lemon
  Squeezy, our merchant of record, and is emailed to you after each payment."* Legal name and address are
  still captured (PRD Open Q4).

### 5.4 Upgrade-path nudge — `src/app/[slug]/(dash)/billing/upgrade/page.tsx`

A single non-blocking inline link — *"Add GST details for your invoice"* — shown on the INR rail when no
profile exists. **It must never block or gate checkout** (PRD Open Q3): a required step ahead of payment
costs conversions to collect data that is optional for most buyers.

### 5.5 Help copy — `src/components/marketing/HelpContent.tsx`

Update the existing GST answer (`:130-131`) from *"email `billing@qravio.app` with your details after
purchase"* to *"add your GSTIN under Billing → Billing details, then email `billing@qravio.app` and we'll
issue your tax invoice against it."* **Do not touch `src/app/(marketing)/terms/page.tsx:127-131`** — it
already promises invoices, that promise is honoured by the manual process, and editing it risks reading as a
claim of *automated* invoicing that v1 does not deliver (PRD R1).

---

## 6. External-Service Integration

**No new service.** The only touch point is the **existing** Razorpay subscription-create call, where two
extra keys ride the `notes` dict already sent at `razorpay_routes.py:301` and `:618` (§3.3) — no new SDK
call, no new endpoint, no new credential.

- **No AI / Anthropic call.** No email / Resend → the unpublished `_dmarc.qravio.app` record is **not** a
  gate for v1 (an emailed invoice in the deferred phase would make it one). No PDF / WeasyPrint. No GSTN
  government API (format+checksum only — live verification is deferred, PRD §7).
- **No new environment variable or secret.** No `.env.example` change, no `src/config/manager.py` change.
- **Lemon Squeezy is untouched.** It is the merchant of record for USD and issues its own tax invoice
  (`src/integrations/mor/base.py:4-5`); `mor_routes.py` is not modified and no GSTIN is sent to it.

---

## 7. API Contracts

Two new routes; no change to any existing contract (the Razorpay `notes` addition is internal to the
provider call and invisible to our API surface).

```jsonc
// GET /api/v1/workspaces/{workspace_id}/billing-profile        (owner only)
// 200 — all fields null when no profile has been saved yet (never 404)
{
  "legal_name": "Northwind Logistics Private Limited",
  "billing_email": "accounts@northwind.co.in",
  "gstin": "27AAPFU0939F1ZV",
  "tax_id_type": "gstin",
  "address_line1": "3rd Floor, Prabhat Chambers",
  "address_line2": null,
  "city": "Pune",
  "state_code": "27",
  "postal_code": "411001",
  "country_code": "IN",
  "billing_workspace_id": "3f1c…",   // where the subscription lives
  "is_inherited": false,             // true ⇒ this workspace inherits its plan
  "editable": true                   // false ⇒ edit it on billing_workspace_id
}

// PUT /api/v1/workspaces/{workspace_id}/billing-profile        (owner only)
// Body: the same field set minus billing_workspace_id/is_inherited/editable.
// Every field nullable; `gstin: null` is VALID (unregistered buyer).
// 200 — the re-read row, plus optional warnings
{ /* …as above… */, "warnings": ["state_code_mismatch"] }

// 403 — caller is not the workspace owner
{ "detail": "Insufficient permissions for this workspace." }

// 409 — this workspace inherits its plan; the profile lives elsewhere
{ "detail": { "code": "billing_profile_inherited", "billing_workspace_id": "3f1c…" } }

// 422 — GSTIN rejected (reason is specific, never a generic "invalid")
{ "detail": { "code": "gstin_checksum",
              "message": "That GSTIN's check character doesn't match — please re-check." } }
// other codes: gstin_length · gstin_layout · gstin_state_code
```

`GET` returns an all-null payload rather than a 404 when nothing is saved, matching
`branding.py:114`'s `BrandingResponse(**(res.data or {}))`.

---

## 8. Security, Privacy & Abuse

- **Auth:** both routes sit under `/api/v1` → Bearer JWT middleware. Not in `excluded_routes`, not an
  `/internal/*` route, no `x-internal-secret`.
- **Authorization:** `require_workspace_role(["owner"])` on **both verbs, including GET**. Billing identity
  is not editor-readable. This is stricter than `branding.py`, whose GET allows viewers (`:110`) — a
  deliberate divergence because branding is public-by-design and this is not.
- **Tenant isolation:** `get_workspace_role` validates membership and the UUID; every query additionally
  carries an explicit `workspace_id` filter because the service-role client **bypasses RLS**. The table has
  RLS enabled with **no policies**, so anon/authenticated roles can never read it even on a key leak.
- **PII (PRD R7):** GSTIN, legal name, address, and billing email are business-identifying and, for a sole
  proprietorship, arguably personal. They **never enter KV, never reach the Worker, never appear in an
  entitlements snapshot**, and are **never logged in full** — log the *presence* of a GSTIN and the reason
  code on a validation failure, never the value or the address. The FK's `ON DELETE CASCADE` clears the row
  when the workspace is deleted; **this table must be added to the separately-tracked account-deletion
  cascade fix**, not worked around here.
- **Retention:** India's statutory ~6-year record-retention obligation attaches to *issued invoices*. v1
  issues none, so there is no retention-vs-deletion conflict to resolve; the deferred invoice phase must
  resolve it explicitly before it ships.
- **Injection / SSRF:** no user-supplied URL is fetched; no value is interpolated into HTML (the profile has
  no rendering surface); all fields are trimmed and length-capped before the upsert. The GSTIN is
  regex-constrained at both the API and the DB (`CHECK`).
- **Abuse:** no per-use cost, no unauthenticated surface, no fan-out. The write is an owner-only upsert of a
  single row — nothing to rate-limit beyond the existing auth boundary.
- **No new secret, no new env var, no new outbound destination** (the Razorpay `notes` go to a provider we
  already send the workspace and plan IDs to).

---

## 9. Performance, Scale & Cost

- **Write path:** one `upsert` of one row, on a human action that happens roughly once per customer lifetime.
  The `GET` adds one `resolve_plan` (already 30s-cached, `subscription.py:283`) plus one primary-key lookup.
- **Checkout path:** one extra primary-key `SELECT` of two columns before `rz.subscription.create`, inside a
  request that already makes a network round-trip to Razorpay. Wrapped in a swallow-all `try` so it can never
  fail or slow a checkout beyond that single lookup (§3.3).
- **DB:** one narrow table with at most one row per workspace and a primary-key-only access pattern — no
  extra index needed, no join added to any hot query. `workspaces`, `subscriptions`, and every `qr_*` table
  are untouched, so no existing query plan changes.
- **Edge:** zero. Nothing is added to the KV value, so the scan hot path and KV storage are unchanged.
- **Cost:** no per-use COGS, no AI call, no email, no third-party API. The only recurring cost is the manual
  invoice issuance that already happens today — which this feature makes *faster*, not more frequent.

---

## 10. Testing Strategy

**Backend (pytest, `qr_backend/tests/`):**
- `test_gstin_checksum` — **the release gate.** Two assertions doing two different jobs:
  (a) **Known-good vectors** across several state codes must verify to their stated check character. This is
  what catches a missing `(product // 36) + (product % 36)` fold: for `27AAPFU0939F1ZV` (a real, valid
  layout — **verified**) the folded algorithm yields `V` and a fold-less one yields `W`, so a single correct
  vector already fails a fold-less implementation.
  (b) **Mutation sweep:** every single-character mutation of the first 14 characters must produce a
  *different* check character — i.e. the check character actually detects typos, which is the only reason it
  exists. Verified against the spec'd algorithm: **0 of 490** single-character mutations of that vector
  collide.
- `test_gstin_validate` — lowercase and spaced input normalizes (`" 27aapfu0939f1zv "` → `27AAPFU0939F1ZV`);
  14/16-char input → `gstin_length`; `'00'`/`'39'`/`'96'` state codes → `gstin_state_code`; a missing literal
  `Z` at index 13 → `gstin_layout`; a wrong check character → `gstin_checksum`; **`None` and `""` → `None`
  with no error** (the unregistered-buyer success path).
- `test_billing_profile_permissions` — owner GET/PUT 200; **editor and viewer 403 on both verbs**; a
  non-member 403; a member of a *different* workspace cannot read this workspace's row.
- `test_billing_profile_inherited` — a workspace whose plan is inherited: GET returns the **billing
  workspace's** row with `is_inherited=true`/`editable=false`; PUT → 409 with `billing_workspace_id`.
- `test_billing_profile_upsert` — first PUT inserts, second updates (one row, `updated_at` advanced);
  sending `gstin: null` clears a previously-saved GSTIN; a partial profile (name + address, no GSTIN) is a
  200; strings are trimmed and length-capped.
- `test_billing_profile_state_mismatch` — `gstin[:2] != state_code` persists both and returns
  `warnings: ["state_code_mismatch"]` (a warning, **not** a 422).
- `test_razorpay_notes_carry_gstin` (Razorpay SDK **mocked**) — with a profile, `subscription.create` is
  called with `notes` containing `gstin` + `legal_name` on **both** the create and upgrade paths; **without**
  a profile, or when the profile read raises, `notes` keeps its original 3 keys and **checkout still
  succeeds** (the never-fail-a-checkout invariant).
- **No `test_feature_gate_coverage` interaction** — the migration seeds no `plans.features` keys and the
  feature registers no flag, so the coverage test is untouched by construction.

**Frontend (Vitest):**
- **Shared-vector parity:** `src/lib/gstin.ts` and `src/utilities/gstin.py` must agree on the same fixture
  list (good + mutated). Any divergence is a release blocker — a client that accepts what the server rejects
  is a confusing 422; the reverse is a silently-bad stored value avoided only by the server check.
- `useBillingProfile` success / 403 / 409 / 422 with a mocked `authApi`; `setQueryData` is called on success.
- The card is hidden for a non-owner; an inherited workspace renders read-only with the billing-workspace
  pointer; the **USD rail shows no GSTIN field** and shows the Lemon Squeezy note (PRD R4 regression guard);
  the INR rail shows both.
- Form: an invalid checksum surfaces the *specific* message (not "invalid"); submitting with an empty GSTIN
  succeeds; the GSTIN input uppercases and strips whitespace as you type.
- **Note the ~29 pre-existing FE test failures baseline** — only net-new failures in `billing-details*` /
  `gstin` / `useBillingProfile` files are regressions.

**Worker:** none — no worker change in this feature.

**Manual:** save a profile on a Free workspace, upgrade on the INR rail, and confirm the GSTIN appears in the
subscription `notes` in the Razorpay dashboard; run the `§2` sanity `SELECT` and confirm the invalid-GSTIN
count is 0.

---

## 11. Observability & Rollout

**Phase 0 — Schema + endpoint (internal).** Apply migration `0039` (**re-verify the slot against
`ls qr_backend/migrations/` first**); build `gstin.py` + `billing_profile.py`; register the router in
`endpoints.py`. Run the checksum gate and the permission tests. No UI.

**Phase 1 — Billing-details card.** Card + form + hook + `lib/gstin.ts` + `gst-states.ts`; inherited
read-only state; INR/USD rail copy; Razorpay `notes` pass-through on create **and** upgrade; `HelpContent.tsx`
copy update. **Acceptance:** a valid GSTIN persists and reads back; a checksum-mutated GSTIN is rejected with
a specific message; a profile with **no** GSTIN saves; an editor sees no card; an inherited workspace is
read-only and points at the billing workspace; a USD-rail user sees the Lemon Squeezy note and no GSTIN
field; a subsequent Razorpay subscription carries `gstin` in `notes`; **checkout is never blocked**.

**Phase 2 — GA + measurement.** Open to all workspaces. Finance's manual invoice now reads from the profile
(or from the Razorpay payment `notes`). **Watch the GSTIN-on-file rate for 90 days** — that number, not
intuition, is the gate on whether the deferred invoice engine gets built (PRD §9, §10).

**Phase 3 — DEFERRED (separate PRD/TRD).** Invoice generation: per-financial-year sequential numbering,
CGST/SGST-vs-IGST place-of-supply computation, PDF, invoice history, email delivery, credit notes. Do not
start it from this spec.

**Deploy order:** apply migration `0039` → deploy backend (the router reads the table) → deploy frontend.
**No worker deploy** (no worker change, no cron). **No DMARC gate** (no email). **No env/secret provisioning.**

**Metrics / logs:** GSTIN-on-file rate among paying INR workspaces (the Phase-3 gate); pre-purchase capture
rate (profiles saved before the first subscription); count of PUTs rejected per reason code
(`gstin_checksum` dominating would mean the client-side mirror has drifted from the server); a periodic
`SELECT` sweep asserting zero stored GSTINs fail the shape regex. Structured log per write: `workspace_id`,
`has_gstin` (bool), reason code on failure — **never the GSTIN, name, or address** (§8). No new dashboard
infra.

---

## 12. Open Technical Questions & Risks

1. **Key on `workspace_id` vs the owning `user_id` (PRD Open Q1)** — resolved: **`workspace_id`**. It mirrors
   `workspace_branding` exactly, matches the workspace-scoped billing page and `subscriptions.workspace_id`,
   and reuses `require_workspace_role(["owner"])` verbatim. The "five divergent GSTINs" concern is fully
   handled by resolving reads through `billing_workspace_id` and 409-ing writes on inherited workspaces
   (§3.2). An owner-keyed table is arguably the truer tax identity but needs a new permission path and a new
   resolver for zero user-visible gain in v1 — revisit if/when the invoice engine ships.
2. **Checksum implemented twice (Python + TypeScript)** — accepted, with the shared-vector parity test (§10)
   as the guard. The alternative (a server round-trip per keystroke) is worse UX for a field typed once. The
   **server check is authoritative**; the client copy is feedback only.
3. **`notes` are best-effort (PRD R9)** — confirmed: written only at subscription-create, wrapped in a
   swallow-all `try`, never able to fail a checkout. The DB row is the record of truth. Verify at build that
   **both** `razorpay_routes.py:301` and `:618` are updated — updating only the create path would silently
   drop the GSTIN for every upgrade, which is the more common paid transition.
4. **State-code mismatch: warn, don't block (PRD Open Q2)** — resolved: persist both, return
   `warnings: ["state_code_mismatch"]`, treat the GSTIN's state code as canonical. v1 computes no tax so a
   mismatch is inert; the deferred place-of-supply engine must make this a hard decision, not inherit a
   warning.
5. **Owner-only GET diverges from `branding.py`'s viewer-readable GET** — deliberate (§8). Confirm with
   product that an editor is never expected to manage billing details; if that changes, the fix is a
   one-line dependency change, not a redesign.
6. **The `CHECK` constraint is `NOT VALID`** — it applies to new/updated rows without validating a
   (currently empty) table, so the DDL cannot fail. If the table is ever backfilled from another source, run
   `VALIDATE CONSTRAINT` explicitly. The Python validator remains the real gate; the constraint is a net.
7. **Migration slot `0039` is provisional** — five concurrent specs are drafting against `0034`–`0038`.
   `ls qr_backend/migrations/` immediately before applying; `AI_BUSINESS_CARD_OCR` already had to move from
   its reserved `0024` to `0026` for exactly this reason.
8. **GST-inclusive pricing (PRD R3)** — recorded here as a trap for the deferred phase: the displayed ₹ price
   *contains* the tax, so an invoice line is `X × 100/118` + `X × 18/118`, **not** `X + 18%`. v1 computes
   nothing, which is why it is safe; do not let an "ex-GST display" slip in as a small follow-on.

### Appendix — Key Files

| Concern | File |
|---|---|
| Billing-profile table | `qr_backend/migrations/0039_gst_billing_profile.sql` (NEW — `workspace_billing_profile`; mirrors `0011_white_label_branding.sql`; slot **provisional**) |
| GSTIN validator | `qr_backend/src/utilities/gstin.py` (NEW — layout + state code + PAN + literal `Z` + mod-36 check character) |
| Endpoints | `qr_backend/src/api/routes/billing_profile.py` (NEW — owner-only GET/PUT; mirrors `branding.py:107`/`:117`), registered in `qr_backend/src/api/endpoints.py` (beside `branding_router`, `:50`) |
| Permission boundary | `qr_backend/src/api/dependencies/deps.py` (`require_workspace_role` `:95`; precedent `workspace.py:757`) |
| Inherited-plan resolution | `qr_backend/src/api/routes/subscription.py` (`resolve_plan` `:283`); `razorpay_routes.py` (`is_inherited`/`billing_workspace_id` `:172-193`, `get_current_subscription` `:708`) |
| Razorpay `notes` pass-through | `qr_backend/src/api/routes/razorpay_routes.py` (create notes `:301`, upgrade notes `:618`) |
| MoR / rail boundary | `qr_backend/src/integrations/mor/base.py:4-5` (Lemon Squeezy = merchant of record for USD — **no** GSTIN on that rail) |
| Billing-details UI | `qr_frontend/src/components/org/billing/billing-details-card.tsx` + `billing-details-form.tsx` (NEW, ≤200 lines each), exported from `src/components/org/index.ts` |
| Page composition | `qr_frontend/src/app/[slug]/(dash)/billing/page.tsx` (29 lines — add the card here; **do not** grow `BillingPlans.tsx`, 677 lines) |
| Hook | `qr_frontend/src/hooks/useBillingProfile.ts` (NEW — mirrors `qr_frontend/src/hooks/useBranding.ts`) |
| FE validator + constants | `qr_frontend/src/lib/gstin.ts`, `qr_frontend/src/lib/constants/gst-states.ts` (NEW) |
| Rail detection | `qr_frontend/src/lib/geo.ts` (`currencyForCountry`), `qr_frontend/src/app/[slug]/(dash)/billing/layout.tsx` (`CurrencyProvider`) |
| Upgrade nudge | `qr_frontend/src/app/[slug]/(dash)/billing/upgrade/page.tsx` (non-blocking link only) |
| Copy | `qr_frontend/src/components/marketing/HelpContent.tsx:130-131` (update); `qr_frontend/src/app/(marketing)/terms/page.tsx:127-131` (**do not touch**) |
| Worker | **No change** (no KV, no type, no template, no cron; no `npm run deploy:prod` gate) |
| Gating | **None** — no `FEATURE_ENFORCEMENT`, no `_QUOTA_SPEC`, no `plans.features` key, no `test_feature_gate_coverage` surface |
